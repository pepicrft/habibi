// Run from any directory after npm ci. This extracts, rather than recompiles,
// the exact browser engine used by client/kits-runtime.mjs.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { createRequire } from "node:module";
import { readFile, mkdir, writeFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";
import variant from "@jitl/quickjs-singlefile-browser-release-sync";

const require = createRequire(import.meta.url);
const packagePath = require.resolve("@jitl/quickjs-singlefile-browser-release-sync/package.json");
const pkg = JSON.parse(await readFile(packagePath, "utf8"));
assert.equal(pkg.version, "0.32.0", "Review the native ABI before updating QuickJS");

const instantiate = WebAssembly.instantiate;
const Module = WebAssembly.Module;
let binary;
let instance;
function capture(bytes) {
  if (bytes instanceof Module) return;
  const copy = Buffer.from(bytes instanceof ArrayBuffer
    ? new Uint8Array(bytes)
    : new Uint8Array(bytes.buffer, bytes.byteOffset, bytes.byteLength));
  if (binary) assert.deepEqual(copy, binary);
  binary = copy;
}
try {
  WebAssembly.Module = new Proxy(Module, {
    construct(target, args) {
      capture(args[0]);
      return Reflect.construct(target, args);
    },
  });
  WebAssembly.instantiate = async (bytes, imports) => {
    capture(bytes);
    const result = await instantiate(bytes, imports);
    instance = result.instance ?? result;
    return result;
  };
  const loader = await variant.importModuleLoader();
  const engine = await loader(); // This is already a function, not { default }.
  // Minified export names are part of the pinned runtime.rs ABI.
  for (const [name, symbol] of Object.entries({
    malloc: "v", QTS_NewRuntime: "K", QTS_NewContext: "N",
    QTS_RuntimeSetMemoryLimit: "y", QTS_RuntimeSetMaxStackSize: "D",
    QTS_GetUndefined: "E", QTS_NewString: "_", QTS_GetString: "$",
    QTS_GetFloat64: "Z", QTS_GetProp: "ha", QTS_Call: "ma",
    QTS_ResolveException: "na", QTS_Eval: "pa", QTS_Typeof: "ra",
  })) assert.equal(engine[`_${name}`], instance.exports[symbol], name);
} finally {
  WebAssembly.instantiate = instantiate;
  WebAssembly.Module = Module;
}
assert.ok(binary, "The loader did not provide a Wasm module");
const digest = createHash("sha256").update(binary).digest("hex");
// Pin bytes as well as package version: the minified import/export ABI is private.
const expected = "105c3bed22d457e43e3d1c3c1c6959fda62a8fe06f0fc8a985303c3a2be72232";
assert.equal(digest, expected, "QuickJS Wasm changed; review native runtime ABI");
const assets = new URL("../core/assets/", import.meta.url);
await mkdir(assets, { recursive: true });
await writeFile(new URL("quickjs.wasm", assets), binary);
await writeFile(new URL("quickjs.LICENSE", assets), await readFile(new URL("LICENSE", pathToFileURL(packagePath))));
console.log(`QuickJS ${pkg.version}: ${binary.length} bytes, sha256 ${digest}`);
