import { runKit } from "./kits-runtime.mjs";

const errors = new Set([
  "Kit source exceeds 24 KiB",
  "Kit input exceeds 256 KiB",
  "Kit output exceeds 16 KiB",
  "Kit budget exceeded",
  "Kit runtime failed",
]);

// One invocation per worker. The parent also terminates the worker on its
// wall-clock deadline, including engine startup and non-interruptible work.
self.addEventListener("message", async ({ data }) => {
  try {
    const result = await runKit(data?.source, data?.input);
    self.postMessage({ ok: true, result });
  } catch (error) {
    self.postMessage({ ok: false, error: errors.has(error?.message) ? error.message : "Kit runtime failed" });
  } finally {
    self.close();
  }
}, { once: true });
