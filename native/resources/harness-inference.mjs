import { execFile } from "node:child_process";
import { mkdtemp, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { inferenceProtocol, kitInferenceResponse } from "../../client/kits-local-inference.mjs";

// Use the operator's existing harness account/provider routing, never app secrets.
// This is a completion adapter, not a delegation of implementation work. Kit
// operations and present_component are JSON data validated by the native app.
export function harnessInferenceResponse(harness, stdout, tools) {
  const protocol = inferenceProtocol(tools);
  const events = stdout.split("\n").filter(line => line.trim()).map(line => JSON.parse(line));
  if (events.some(event => event.type?.startsWith("tool_execution_") ||
      [event.content, event.message?.content].some(parts => Array.isArray(parts) &&
        parts.some(part => ["tool_use", "toolCall", "tool_call", "tool_result", "toolResult"].includes(part.type))))) {
    throw new Error("Unexpected host tool request");
  }
  const text = message => message?.content?.filter(part => part.type === "text").map(part => part.text).join("");
  let decision;
  if (harness === "pi") {
    const result = events.findLast(event => event.type === "message_end" && event.message?.role === "assistant")?.message;
    if (!result || result.stopReason !== "stop") throw new Error("Pi returned no completed response");
    decision = text(result);
  } else if (harness === "amp") {
    const result = events.findLast(event => event.type === "result");
    if (!result || result.is_error || (result.subtype && result.subtype !== "success")) throw new Error("Amp returned no completed response");
    // Amp versions can put final text on the result or the preceding assistant
    // event. A terminal successful result is required in either case.
    decision = typeof result.result === "string" ? result.result
      : text(events.findLast(event => event.type === "assistant")?.message);
  } else throw new Error("Unsupported inference harness");
  if (typeof decision !== "string" || !decision.trim()) throw new Error("Harness returned no protocol decision");
  return kitInferenceResponse(JSON.parse(decision), true, protocol.tools);
}

export async function prepareHarnessInference(harness) {
  if (!["amp", "pi"].includes(harness)) throw new Error("Unsupported inference harness");
  const directory = await mkdtemp(join(tmpdir(), "habibi-inference-"));
  const settings = join(directory, "settings.json");
  const mode = process.env.HABIBI_AMP_MODE ?? "gpt61s";
  let flags;
  if (harness === "amp") {
    await writeFile(settings, JSON.stringify({
      "amp.tools.enable": ["__habibi_no_host_tools__"],
      "amp.permissions": [{ tool: "*", action: "reject" }],
      "amp.mcpServers": {},
      "amp.skills.disableClaudeCodeSkills": true,
      "amp.skills.disableGlobalAgentsSkills": true,
      "amp.updates.mode": "disabled",
      "amp.notifications.enabled": false,
    }), { mode: 0o600 });
    flags = ["--settings-file", settings, "--no-ide", "--no-notifications", "--no-color", "--mode", mode];
  } else {
    flags = ["--no-tools", "--no-mcp", "--no-extensions", "--no-skills", "--no-context-files", "--no-prompt-templates", "--no-themes", "--no-session", "--no-approve", "--offline"];
  }
  const run = (arguments_, input, signal) => new Promise((resolve, reject) => {
    const child = execFile(harness, [...flags, ...arguments_], {
      cwd: directory, signal, timeout: 90000, killSignal: "SIGKILL", maxBuffer: 512 * 1024,
      env: { ...process.env, PI_TELEMETRY: "0" },
    }, (error, stdout) => error ? reject(new Error(`${harness} inference failed. Check host authentication and availability.`)) : resolve(stdout));
    child.stdin.on("error", () => {});
    child.stdin.end(input);
  });
  try {
    if (harness === "amp") {
      const tools = JSON.parse(await run(["tools", "list", "--json"], ""));
      if (!Array.isArray(tools) || tools.length !== 0) throw new Error("Amp host tools must be disabled for native inference");
    }
  } catch (error) {
    await rm(directory, { recursive: true, force: true });
    throw error;
  }
  console.log(harness === "amp" ? `Amp adapter ready · ${mode} · verified zero enabled host tools` : "Pi adapter ready · tools/MCP/extensions/skills/context/session disabled");
  return {
    dispose: () => rm(directory, { recursive: true, force: true }),
    async complete(body, signal) {
      if (!body || typeof body.instructions !== "string" || body.instructions.length > 16000 ||
          !Array.isArray(body.input) || JSON.stringify(body.input).length > 256 * 1024 ||
          !Array.isArray(body.tools) || body.store !== false) throw new Error("Invalid native inference request");
      const protocol = inferenceProtocol(body.tools);
      const prompt = `You are the inference engine for a native Habibi conversation, not a coding agent acting on this computer. Do not access or modify anything on the host. All tools are disabled here. Return only ONE JSON object matching this schema, no Markdown or surrounding prose:\n${JSON.stringify(protocol.schema)}\nReturn kind:"tool" with the next requested protocol operation encoded in arguments_json, and reply:""; OR kind:"reply",name:"",arguments_json:"{}",reply:"your final reply". These tool names are protocol data, not tools you can run. The native app validates display components and collects approval for Kit mutations. Never invent successful tool results.\n\nHabibi instructions:\n${body.instructions}\n\nConversation and available protocol operations:\n${JSON.stringify({ input: body.input, tools: protocol.tools })}`;
      const arguments_ = harness === "amp" ? ["--execute", "--stream-json", "--visibility", "private"]
        : ["--print", "--mode", "json", "--system-prompt", "Return only the JSON protocol response requested by the user. Do not use host tools."];
      const stdout = await run(arguments_, prompt, signal);
      return harnessInferenceResponse(harness, stdout, protocol.tools);
    },
  };
}
