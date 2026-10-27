// Simulator-only, opt-in inference. Claude returns guest commands as data;
// it cannot run host tools. Never send private entries to this endpoint.
import { execFile } from "node:child_process";
import { randomBytes, timingSafeEqual } from "node:crypto";
import { createServer } from "node:http";
import { mkdir, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../../..", import.meta.url));
const coding = process.argv.includes("--coding");
const port = coding ? 8085 : 8084;
const scratch = resolve(root, coding ? ".amp/in/tinyarm-coding" : ".amp/in/tinyarm-sim");
await mkdir(scratch, { recursive: true });
const token = randomBytes(32).toString("hex");
await writeFile(resolve(scratch, "bridge.json"), JSON.stringify({ token }), { mode: 0o600 });
const schema = {
  type: "object", additionalProperties: false, required: ["kind", "argv", "stdin", "reply"],
  properties: {
    kind: { type: "string", enum: ["exec", "reply"] },
    argv: { type: "array", maxItems: 32, items: { type: "string" } },
    stdin: { type: "string" }, reply: { type: "string" },
  },
};
let active = false;
let sequence = coding ? Date.now() : 0;
const server = createServer(async (request, response) => {
  response.setHeader("content-type", "application/json");
  response.setHeader("cache-control", "no-store");
  const reject = (status, error) => { response.writeHead(status); response.end(JSON.stringify({ error })); };
  const expected = Buffer.from(`Bearer ${token}`);
  const supplied = Buffer.from(request.headers.authorization ?? "");
  if (request.headers.origin || expected.length !== supplied.length || !timingSafeEqual(expected, supplied)) return reject(403, "Development authorization required");
  if (request.method !== "POST" || request.url !== "/step" || request.headers["content-type"] !== "application/json") return reject(404, "Not found");
  if (active) return reject(429, "Inference already running");
  active = true;
  const abort = new AbortController();
  response.on("close", () => { if (!response.writableEnded) abort.abort(); });
  try {
    const parts = [];
    let size = 0;
    for await (const part of request) {
      size += part.length;
      if (size > 384 * 1024) return reject(413, "Request too large");
      parts.push(part);
    }
    const body = JSON.parse(Buffer.concat(parts));
    if (typeof body.instructions !== "string" || body.instructions.length > 16000 || !Array.isArray(body.history)) return reject(400, "Invalid coding conversation");
    const number = ++sequence;
    // Synthetic coding conversations only. Local audit files intentionally make
    // the model disclosure inspectable; the installed Kit never calls this API.
    await writeFile(resolve(scratch, `inference-${number}-request.json`), JSON.stringify({ time: new Date().toISOString(), ...body }, null, 2), { mode: 0o600 });
    const result = await new Promise((resolve, reject) => {
      const child = execFile("claude", [
        "--print", "--safe-mode", "--tools", "", "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
        "--disable-slash-commands", "--no-session-persistence", "--no-chrome", "--permission-mode", "dontAsk",
        "--output-format", "json", "--json-schema", JSON.stringify(schema), "--system-prompt", body.instructions, "--effort", "low",
      ], { signal: abort.signal, timeout: 90000, killSignal: "SIGKILL", maxBuffer: 256 * 1024, cwd: scratch }, (error, stdout) => {
        if (error) return reject(new Error("Inference failed or cancelled"));
        try {
          const answer = JSON.parse(stdout);
          if (answer.is_error || !answer.structured_output) throw new Error();
          console.log(`Step ${number}: ${answer.duration_ms} ms · ${Object.keys(answer.modelUsage ?? {}).join(", ")}`);
          resolve(answer.structured_output);
        } catch { reject(new Error("No structured model output")); }
      });
      child.stdin.on("error", () => {});
      child.stdin.end(JSON.stringify({ history: body.history }));
    });
    await writeFile(resolve(scratch, `inference-${number}-response.json`), JSON.stringify(result, null, 2), { mode: 0o600 });
    response.end(JSON.stringify(result));
  } catch (error) {
    console.error(error.message);
    if (!response.headersSent && !response.destroyed) reject(502, "Development inference failed");
  } finally { active = false; }
});
server.requestTimeout = 110000;
server.listen(port, "127.0.0.1", () => console.log(`TinyARM Lab inference on loopback${port}. Coding conversation goes to the model provider; use synthetic information.`));
