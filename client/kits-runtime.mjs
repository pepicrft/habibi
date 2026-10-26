import variant from "@jitl/quickjs-singlefile-browser-release-sync";
import { newQuickJSWASMModuleFromVariant, Scope } from "quickjs-emscripten-core";

const text = new TextEncoder();
const sourceLimit = 24 * 1024;
const inputLimit = 256 * 1024;
const outputLimit = 16 * 1024;

// Only strings cross the Wasm boundary. No host functions, module loader, or
// job runner are installed. The caller validates the returned JSON's schema.
export async function runKit(source, input) {
  let failure = "Kit runtime failed";
  let deadline = Infinity;
  let interrupted = false;
  const overBudget = () => interrupted || performance.now() >= deadline;

  try {
    if (typeof source !== "string") throw new Error();
    if (source.length > sourceLimit || text.encode(source).length > sourceLimit) {
      failure = "Kit source exceeds 24 KiB";
      throw new Error();
    }

    const inputJson = JSON.stringify(input);
    if (typeof inputJson !== "string") throw new Error();
    if (inputJson.length > inputLimit || text.encode(inputJson).length > inputLimit) {
      failure = "Kit input exceeds 256 KiB";
      throw new Error();
    }

    // A fresh instance also means fresh Wasm memory, not just fresh JS globals.
    // QuickJSWASMModule has no public dispose API: retain no module references
    // after disposing its context/runtime so its Wasm memory can be collected.
    const engine = await newQuickJSWASMModuleFromVariant(variant);
    // Cold host-engine compilation is covered by the parent's worker watchdog,
    // not the guest's execution budget. All guest initialization is timed below.
    deadline = performance.now() + 100;
    return Scope.withScope(scope => {
      const runtime = scope.manage(engine.newRuntime({
        memoryLimitBytes: 8 * 1024 * 1024,
        maxStackSizeBytes: 256 * 1024,
        interruptHandler: () => {
          interrupted = overBudget();
          return interrupted;
        },
      }));
      if (overBudget()) throw new Error();
      const context = scope.manage(runtime.newContext());
      const evaluated = scope.manage(context.evalCode(`${source}\n;summarize`, "kit.js", { type: "global" }));
      if (evaluated.error || context.typeof(evaluated.value) !== "function") throw new Error();
      const argument = scope.manage(context.newString(inputJson));
      const returned = scope.manage(context.callFunction(evaluated.value, context.undefined, argument));
      if (returned.error || overBudget()) throw new Error();

      // Do not coerce objects, inspect errors, await promises, or run jobs.
      if (context.typeof(returned.value) !== "string") throw new Error();
      // getLength only supports objects in this variant. A primitive string's
      // own, immutable length cannot invoke a poisoned prototype getter.
      const lengthHandle = scope.manage(context.getProp(returned.value, "length"));
      if (context.typeof(lengthHandle) !== "number") throw new Error();
      const length = context.getNumber(lengthHandle);
      if (length > outputLimit) {
        failure = "Kit output exceeds 16 KiB";
        throw new Error();
      }
      // The UTF-16 length bounds getString's allocation before copying. The
      // exact UTF-8 byte check follows; at worst the copy is 3 * outputLimit.
      const output = context.getString(returned.value);
      if (output.length !== length) throw new Error(); // Reject C-string NUL truncation.
      if (text.encode(output).length > outputLimit) {
        failure = "Kit output exceeds 16 KiB";
        throw new Error();
      }
      if (overBudget()) throw new Error();
      const result = JSON.parse(output);
      if (overBudget()) throw new Error();
      return result;
    });
  } catch {
    throw new Error(overBudget() ? "Kit budget exceeded" : failure);
  }
}
