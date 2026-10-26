// Opt-in development bridge only. Neither the app nor this bridge receives a
// vault key. The selected harness returns tool requests as data, never executes
// them. Requests contain messages, Kit definitions and synthetic tests.
import { createServer } from "node:http";
import { randomBytes, timingSafeEqual } from "node:crypto";
import { mkdir, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { localKitInference } from "../../client/kits-local-inference.mjs";
import { prepareHarnessInference } from "./harness-inference.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const tokenFile = resolve(root, ".amp/in/native-inference-token");
const token = randomBytes(32).toString("hex");
const harness = process.argv[2] ?? "amp";
if (!["amp", "claude", "pi"].includes(harness)) throw new Error("Usage: node native/resources/inference.mjs [amp|claude|pi]");
const adapter = harness === "claude" ? null : await prepareHarnessInference(harness);
const infer = adapter ? (body, signal) => adapter.complete(body, signal) : localKitInference;
let active = false;

const server = createServer(async (request, response) => {
  response.setHeader("Content-Type", "application/json");
  response.setHeader("Cache-Control", "no-store");
  const reject = (status, message) => { response.writeHead(status); response.end(JSON.stringify({ error: message })); };
  const supplied = Buffer.from(request.headers.authorization ?? "");
  const expected = Buffer.from(`Bearer ${token}`);
  if (request.headers.origin || supplied.length !== expected.length || !timingSafeEqual(supplied, expected)) {
    reject(403, "Native development authorization required"); return;
  }
  if (request.method !== "POST" || request.url !== "/inference" || request.headers["content-type"] !== "application/json") {
    reject(404, "Not found"); return;
  }
  if (active) { reject(429, "An inference request is already running"); return; }
  active = true;
  const abort = new AbortController();
  response.on("close", () => { if (!response.writableEnded) abort.abort(); });
  try {
    const parts = [];
    let size = 0;
    for await (const part of request) {
      size += part.length;
      if (size > 384 * 1024) { reject(413, "Request too large"); return; }
      parts.push(part);
    }
    const body = JSON.parse(Buffer.concat(parts).toString("utf8"));
    const result = await infer(body, abort.signal);
    response.end(JSON.stringify(result));
  } catch (error) {
    console.error(`Native ${harness} inference: ${error.message}`);
    if (!response.destroyed && !response.headersSent) reject(502, "Development inference failed. Check host authentication and the bridge log.");
  } finally { active = false; }
});
server.requestTimeout = 120_000;
server.headersTimeout = 10_000;
server.listen(8083, "127.0.0.1", async () => {
  await mkdir(dirname(tokenFile), { recursive: true });
  await writeFile(tokenFile, token, { mode: 0o600 });
  console.log(`Native development inference listening on loopback port 8083 · ${harness}.`);
  console.log(`Simulator bearer token saved privately to ${tokenFile}.`);
  console.log("Host/cloud provider terms and retention apply. Use fictional demo data.");
});
for (const signal of ["SIGINT", "SIGTERM"]) process.once(signal, () => {
  server.close();
  Promise.resolve(adapter?.dispose()).finally(() => process.exit(0));
});
