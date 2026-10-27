import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import { kitTools } from "./kits-agent.mjs";
import { kitGenerationSchema, validateKit } from "./kits.mjs";
import githubKit from "../native/core/assets/github-kit.json" with { type: "json" };

// Native-only display protocol. The browser reference still has seven Kit tools.
// The host validates the complete component in Rust before rendering it.
export const nativeKitTools = [...kitTools, {
  type: "function", name: "present_component", strict: true,
  description: "Display a result_table v1 or a native kit_entry v1 card inside the conversation. Read the installed Kit definition before presenting its entry card; the host derives inputs from its actual fields. Optional prefill items are proposed values from this conversation, never saved entries. The user edits and explicitly saves locally; the model receives only displayed:true, not entered values. Never claim an entry was saved. No arbitrary UI, code, URLs or capabilities. Maximum32KiB; all string limits UTF-8 bytes. result_table:8 columns,20 rows,120 cells, exact row widths; show_source only reveals supplied data locally.",
  parameters: {
    type: "object", additionalProperties: false, required: ["component"],
    properties: { component: { anyOf: [{
      type: "object", additionalProperties: false,
      required: ["type", "version", "data", "actions", "fallback"],
      properties: {
        type: { type: "string", enum: ["result_table"] }, version: { type: "integer", enum: [1] },
        data: {
          type: "object", additionalProperties: false, required: ["title", "columns", "rows"],
          properties: {
            title: { type: "string", minLength: 1, maxLength: 120 },
            columns: { type: "array", minItems: 1, maxItems: 8, items: { type: "string", minLength: 1, maxLength: 60 } },
            rows: { type: "array", maxItems: 20, items: { type: "array", minItems: 1, maxItems: 8, items: { type: "string", maxLength: 500 } } },
          },
        },
        actions: {
          type: "array", maxItems: 1, items: {
            type: "object", additionalProperties: false, required: ["id", "label"],
            properties: { id: { type: "string", enum: ["show_source"] }, label: { type: "string", minLength: 1, maxLength: 80 } },
          },
        },
        fallback: { type: "string", minLength: 1, maxLength: 4000 },
      },
    }, {
      type: "object", additionalProperties: false,
      required: ["type", "version", "data", "actions", "fallback"],
      properties: {
        type: { type: "string", enum: ["kit_entry"] }, version: { type: "integer", enum: [1] },
        data: {
          type: "object", additionalProperties: false, required: ["title", "kitId", "prefill"],
          properties: {
            title: { type: "string", minLength: 1, maxLength: 120 },
            kitId: { type: "string", description: "Exact installed Kit UUID returned by list_kits or save_kit." },
            prefill: {
              type: "array", maxItems: 12, description: "Unique declared field keys only. Leave fields absent for the user to enter.",
              items: {
                type: "object", additionalProperties: false, required: ["key", "value"],
                properties: {
                  key: { type: "string", pattern: "^[a-z][a-z0-9_]{0,31}$" },
                  value: { anyOf: [{ type: "string", maxLength: 500 }, { type: "number", minimum: -1e9, maximum: 1e9 }] },
                },
              },
            },
          },
        },
        actions: {
          type: "array", minItems: 1, maxItems: 1,
          items: {
            type: "object", additionalProperties: false, required: ["id", "label"],
            properties: { id: { type: "string", enum: ["save_entry"] }, label: { type: "string", minLength: 1, maxLength: 80 } },
          },
        },
        fallback: { type: "string", minLength: 1, maxLength: 4000 },
      },
    }] } },
  },
}];

export const decisionSchema = {
  type: "object", additionalProperties: false,
  required: ["kind", "name", "arguments_json", "reply"],
  properties: {
    kind: { type: "string", enum: ["tool", "reply"] },
    name: { type: "string", enum: ["", ...kitTools.map(tool => tool.name)] },
    arguments_json: { type: "string" }, reply: { type: "string" },
  },
};

export const nativeDecisionSchema = {
  ...decisionSchema,
  properties: { ...decisionSchema.properties, name: { type: "string", enum: ["", ...nativeKitTools.map(tool => tool.name)] } },
};

// The host advertises these only after the user connects the bundled Kit.
// Import the reviewed schemas, never the credentials or caller-supplied tools.
export const connectedGitHubTools = [...nativeKitTools, ...githubKit.tools];
const connectedGitHubSchema = {
  ...decisionSchema,
  properties: { ...decisionSchema.properties, name: { type: "string", enum: ["", ...connectedGitHubTools.map(tool => tool.name)] } },
};

export function inferenceProtocol(requested = kitTools) {
  // Only canonical, complete protocols are accepted. Never forward caller-supplied
  // tool definitions to a harness, or turn a protocol name into a host tool.
  for (const [tools, schema] of [[kitTools, decisionSchema], [nativeKitTools, nativeDecisionSchema], [connectedGitHubTools, connectedGitHubSchema]]) {
    if (Array.isArray(requested) && requested.length === tools.length &&
        requested.every((tool, index) => tool?.name === tools[index].name)) return { tools, schema };
  }
  throw new Error("Unsupported inference tool protocol");
}

// Development-only inference. Claude's native tools, MCP, skills, hooks and
// session persistence are disabled. Protocol calls are DATA returned to the
// requesting client, where validation and approval boundaries still apply.
export async function localKitInference(body, signal) {
  if (!body || typeof body.instructions !== "string" || body.instructions.length > 16000 ||
      !Array.isArray(body.input) || JSON.stringify(body.input).length > 256 * 1024 || body.store !== false) {
    throw new Error("Invalid local inference request");
  }
  const conversation = Array.isArray(body.tools);
  const protocol = conversation ? inferenceProtocol(body.tools) : null;
  const system = `${body.instructions}\n${conversation
    ? "Produce the NEXT assistant step for the supplied conversation. Return kind:'tool', the tool name and arguments_json (a JSON object encoded as a string), with reply:''; OR kind:'reply', name:'', arguments_json:'{}', and your final reply. Never claim a tool succeeded without a successful result in the history. Do not run any tools yourself. The requesting client validates display data and asks for approval before any Kit mutation."
    : "Return only the requested Kit definition using the required JSON schema."}`;
  const result = await new Promise((resolve, reject) => {
    const child = execFile("claude", [
      "--print", "--safe-mode", "--tools", "", "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
      "--disable-slash-commands", "--no-session-persistence", "--no-chrome", "--permission-mode", "dontAsk",
      "--output-format", "json", "--json-schema", JSON.stringify(protocol?.schema ?? kitGenerationSchema),
      "--system-prompt", system, "--effort", "low",
    ], { signal, timeout: 90000, killSignal: "SIGKILL", maxBuffer: 512 * 1024 }, (error, stdout) => {
      if (error) { reject(new Error(signal?.aborted ? "Local inference cancelled" : "Local inference failed. Check Claude Code authentication and availability.")); return; }
      try {
        const response = JSON.parse(stdout);
        if (response.is_error || !response.structured_output) throw new Error();
        console.log(`Local Kit inference: ${Object.keys(response.modelUsage ?? {}).join(", ")} · ${response.duration_ms} ms`);
        resolve(response.structured_output);
      } catch { reject(new Error("Local inference returned no valid structured result")); }
    });
    child.stdin.on("error", () => {}); // The child may fail before consuming stdin.
    child.stdin.end(JSON.stringify({ input: body.input, ...(protocol ? { tools: protocol.tools } : {}) }));
  });
  return kitInferenceResponse(result, conversation, protocol?.tools);
}

export function kitInferenceResponse(result, conversation = true, tools = kitTools) {
  let output;
  if (!conversation) {
    output = [{ type: "message", role: "assistant", content: [{ type: "output_text", text: JSON.stringify(validateKit(result)) }] }];
  } else if (result && typeof result === "object" && !Array.isArray(result) &&
      Object.keys(result).length === 4 && ["kind", "name", "arguments_json", "reply"].every(key => Object.hasOwn(result, key))) {
    const allowed = inferenceProtocol(tools).tools;
    if (result.kind === "tool" && result.reply === "" && allowed.some(tool => tool.name === result.name) &&
      typeof result.arguments_json === "string" && result.arguments_json.length <= 64 * 1024) {
      let arguments_;
      try { arguments_ = JSON.parse(result.arguments_json); } catch { throw new Error("Invalid tool argument JSON"); }
      if (!arguments_ || typeof arguments_ !== "object" || Array.isArray(arguments_)) throw new Error("Invalid tool argument object");
      if (githubKit.tools.some(tool => tool.name === result.name) && Object.keys(arguments_).length) {
        throw new Error("GitHub tools take no arguments");
      }
      output = [{ type: "function_call", call_id: randomUUID(), name: result.name, arguments: result.arguments_json }];
    } else if (result.kind === "reply" && result.name === "" && result.arguments_json === "{}" &&
        typeof result.reply === "string" && result.reply.trim() && result.reply.length <= 16000) {
      output = [{ type: "message", role: "assistant", content: [{ type: "output_text", text: result.reply }] }];
    }
  }
  if (!output) throw new Error("Local inference returned an invalid conversation operation");
  return { status: "completed", output };
}
