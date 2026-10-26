import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";
import { readTheme, themeCSS } from "../server/marketing/theme.mjs";
import { localKitInference } from "./kits-local-inference.mjs";

const root = fileURLToPath(new URL("../", import.meta.url));
const port = Number(process.env.KITS_PORT || 8081);
const localInference = process.argv.includes("--local-claude");
if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error("Invalid KITS_PORT");
const result = await build({
  absWorkingDir: root,
  entryPoints: ["client/kits-workbench.mjs", "client/kits-worker.mjs"],
  bundle: true, format: "esm", platform: "browser", target: "es2022",
  outdir: "/habibi-kits", outExtension: { ".js": ".js" }, write: false,
  logLevel: "warning",
});
const routes = new Map(result.outputFiles.map(file => [`/${file.path.split("/").at(-1)}`, ["text/javascript; charset=utf-8", file.contents]]));
for (const [path, file, type] of [
  ["/", "client/kits.html", "text/html; charset=utf-8"],
  ["/kits.css", "client/kits.css", "text/css; charset=utf-8"],
  ["/assets/fonts/dm-sans-latin-wght-normal.woff2", "server/marketing/site/assets/fonts/dm-sans-latin-wght-normal.woff2", "font/woff2"],
]) routes.set(path, [type, await readFile(new URL(file, new URL("../", import.meta.url)))]);
routes.set("/theme.css", ["text/css; charset=utf-8", themeCSS(readTheme())]);
routes.set("/inference-config.json", ["application/json", JSON.stringify({ provider: localInference ? "claude-code" : "openai" })]);

let inferenceBusy = false;
createServer(async (request, response) => {
  const allowedHosts = new Set([`127.0.0.1:${port}`, `localhost:${port}`]);
  if (!allowedHosts.has(request.headers.host)) { response.writeHead(403); response.end(); return; }
  const route = routes.get(request.url);
  response.setHeader("Cache-Control", "no-store");
  response.setHeader("X-Content-Type-Options", "nosniff");
  response.setHeader("Referrer-Policy", "no-referrer");
  response.setHeader("Cross-Origin-Resource-Policy", "same-origin");
  response.setHeader("Content-Security-Policy", "default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; worker-src 'self'; style-src 'self'; font-src 'self'; connect-src 'self' https://api.openai.com; img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'");
  if (localInference && request.url === "/inference") {
    if (request.method !== "POST") { response.writeHead(405, { Allow: "POST" }); response.end(); return; }
    if (request.headers.origin !== `http://${request.headers.host}` || request.headers["content-type"]?.split(";")[0] !== "application/json") {
      response.writeHead(403); response.end(); return;
    }
    if (inferenceBusy) { response.writeHead(429); response.end(); return; }
    inferenceBusy = true;
    const controller = new AbortController();
    response.on("close", () => { if (!response.writableEnded) controller.abort(); });
    try {
      const chunks = [];
      let bytes = 0;
      for await (const chunk of request) {
        bytes += chunk.length;
        if (bytes > 320 * 1024) throw new Error("Local inference request is too large");
        chunks.push(chunk);
      }
      const result = await localKitInference(JSON.parse(Buffer.concat(chunks).toString("utf8")), controller.signal);
      response.writeHead(200, { "Content-Type": "application/json" });
      response.end(JSON.stringify(result));
    } catch {
      if (!response.destroyed) {
        response.writeHead(502, { "Content-Type": "application/json" });
        response.end(JSON.stringify({ error: "Local inference failed or was cancelled. Check Claude Code authentication and availability." }));
      }
    } finally { inferenceBusy = false; }
    return;
  }
  if (request.method !== "GET" && request.method !== "HEAD") {
    response.writeHead(405, { Allow: "GET, HEAD" }); response.end(); return;
  }
  if (!route) { response.writeHead(404); response.end("Not found"); return; }
  response.writeHead(200, { "Content-Type": route[0] });
  response.end(request.method === "HEAD" ? undefined : route[1]);
}).listen(port, "127.0.0.1", () => {
  console.log(`Habibi Kits reference workbench listening on loopback port ${port}. Restart after source edits.`);
  if (localInference) console.log("Development inference: local Claude Code CLI (cloud model). No native tools, hooks, MCP or session persistence.");
});
