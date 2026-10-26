import { test } from "node:test";
import assert from "node:assert/strict";
import { Worker, isMainThread, parentPort, workerData } from "node:worker_threads";
import { runKit } from "./kits-runtime.mjs";

const input = {
  today: "2026-10-25",
  entries: [
    { id: "a", createdAt: "2026-10-25T08:00:00Z", values: { calories: 135, reps: 3, kg: 7, note: "الأحد 🏋️" } },
    { id: "b", createdAt: "2026-10-25T18:00:00Z", values: { calories: 315, reps: 8, kg: 11, note: 'not code: "); fetch("host")' } },
    { id: "c", createdAt: "2026-10-24T18:00:00Z", values: { calories: 999, reps: 20, kg: 50, note: "yesterday" } },
  ],
};
const healthy = 'function summarize() { return \'{"metrics":[{"label":"Ready","value":"1","unit":""}]}\'; }';
const healthyResult = { metrics: [{ label: "Ready", value: "1", unit: "" }] };

// A real parent-enforced timeout catches regressions in synchronous interrupt
// handling without leaving the test runner stuck inside a broken guest VM.
function isolated(sources, timeout = 5000) {
  return new Promise((resolve, reject) => {
    const worker = new Worker(new URL(import.meta.url), { workerData: { sources, input } });
    let received = false;
    const timer = setTimeout(() => {
      void worker.terminate();
      reject(new Error("Kit test worker exceeded its wall-clock limit"));
    }, timeout);
    worker.once("message", results => {
      received = true;
      clearTimeout(timer);
      void worker.terminate();
      resolve(results);
    });
    worker.once("error", error => {
      clearTimeout(timer);
      reject(error);
    });
    worker.once("exit", code => {
      clearTimeout(timer);
      if (!received) reject(new Error(`Kit test worker exited without results (code ${code})`));
    });
  });
}

if (!isMainThread) {
  const results = [];
  for (const source of workerData.sources) {
    try {
      results.push({ ok: true, result: await runKit(source, workerData.input) });
    } catch (error) {
      results.push({ ok: false, error: error.message });
    }
  }
  parentPort.postMessage(results);
} else {
  test("summaries compute asymmetric calories and workouts using Unicode and today's entries only", async () => {
    const result = await runKit(`
      function summarize(inputJson) {
        const { entries, today } = JSON.parse(inputJson);
        const todayEntries = entries.filter(entry => entry.createdAt.slice(0, 10) === today);
        return JSON.stringify({ metrics: [
          { label: 'Calories today', value: String(todayEntries.reduce((sum, e) => sum + e.values.calories, 0)), unit: 'kcal' },
          { label: 'حجم التدريب 🏋️', value: String(todayEntries.reduce((sum, e) => sum + e.values.reps * e.values.kg, 0)), unit: 'kg' },
          { label: todayEntries[0].values.note, value: String(todayEntries.length), unit: '' }
        ] });
      }
    `, input);
    assert.deepEqual(result, { metrics: [
      { label: "Calories today", value: "450", unit: "kcal" },
      { label: "حجم التدريب 🏋️", value: "109", unit: "kg" },
      { label: "الأحد 🏋️", value: "2", unit: "" },
    ] });
  });

  test("guest mutation and poisoned globals cannot change host input or later invocations", async () => {
    const before = structuredClone(input);
    globalThis.__kitHostSentinel = "host-only";
    try {
      assert.deepEqual(await runKit(`
        function summarize(inputJson) {
          const data = JSON.parse(inputJson);
          data.entries[0].values.calories = 99999;
          globalThis.__kitHostSentinel = 'guest-only';
          Object.prototype.poison = true;
          Array.prototype.map = () => { throw 'poison'; };
          JSON.stringify = () => { throw 'poison'; };
          return '{"mutated":true}';
        }
      `, input), { mutated: true });
      assert.deepEqual(input, before);
      assert.equal(globalThis.__kitHostSentinel, "host-only");
      assert.deepEqual(await runKit(`
        function summarize(inputJson) {
          return JSON.stringify({
            sentinel: typeof globalThis.__kitHostSentinel,
            poison: typeof ({}).poison,
            value: [JSON.parse(inputJson).entries[0].values.calories].map(x => x + 1)[0]
          });
        }
      `, input), { sentinel: "undefined", poison: "undefined", value: 136 });
    } finally {
      delete globalThis.__kitHostSentinel;
    }
  });

  test("imports, constructor chains and browser/Node globals have no host capabilities", async () => {
    const originalFetch = globalThis.fetch;
    let effects = 0;
    globalThis.fetch = () => { effects += 1; throw new Error("host fetch executed"); };
    globalThis.__kitHostEffect = () => { effects += 1; };
    try {
      const result = await runKit(`
        function summarize() {
          const names = ['fetch', 'process', 'require', 'console', 'window', 'document', 'self',
            'postMessage', 'XMLHttpRequest', 'WebSocket', 'WebAssembly', 'Worker', 'Deno', 'Bun',
            'setTimeout', 'queueMicrotask', 'navigator', 'localStorage', '__kitHostEffect'];
          const globals = names.map(name => typeof globalThis[name]);
          const attempts = [];
          for (const attempt of [
            () => fetch('https://example.invalid/kit-side-effect'),
            () => process.env,
            () => require('node:fs'),
            () => globalThis.__kitHostEffect(),
            () => ({}).constructor.constructor('return process')(),
            () => (() => {}).constructor('return fetch')()
          ]) {
            try { attempt(); attempts.push('escaped'); } catch { attempts.push('blocked'); }
          }
          // Dynamic imports cannot load anything. Its handlers must never run:
          // there is no module loader and the host never drains pending jobs.
          import('node:fs').then(() => { for (;;) {} }, () => { for (;;) {} });
          return JSON.stringify({ globals, attempts });
        }
      `, input);
      assert.deepEqual(result, { globals: Array(19).fill("undefined"), attempts: Array(6).fill("blocked") });
      await assert.rejects(runKit('import fs from "node:fs"; function summarize() {}', input), { message: "Kit runtime failed" });
      assert.equal(effects, 0);
    } finally {
      globalThis.fetch = originalFetch;
      delete globalThis.__kitHostEffect;
    }
  });

  test("the deadline covers top-level code, initializers, function bodies and guest serialization", async () => {
    const results = await isolated([
      "while (true) {} function summarize() {}",
      "const init = (() => { for (;;) {} })(); function summarize() {}",
      "function summarize() { while (true) {} }",
      "function summarize() { return JSON.stringify({ get value() { for (;;) {} } }); }",
      healthy,
    ]);
    assert.deepEqual(results, [
      ...Array.from({ length: 4 }, () => ({ ok: false, error: "Kit budget exceeded" })),
      { ok: true, result: healthyResult },
    ]);
  });

  test("non-string results are rejected without coercion, getters, toJSON, awaiting or jobs", async () => {
    const expressions = [
      "({ toJSON() { for (;;) {} }, toString() { for (;;) {} } })",
      "Object.defineProperty({}, 'then', { get() { for (;;) {} } })",
      "Object.defineProperty({}, 'length', { get() { for (;;) {} } })",
      "new Proxy({}, { get() { for (;;) {} } })",
      "new String('{}')",
      "function () { for (;;) {} }",
      "Promise.resolve('{}').then(() => { for (;;) {} })",
      "17", "null", "undefined", "Symbol('private')",
    ];
    const results = await isolated([
      ...expressions.map(expression => `function summarize() { return ${expression}; }`),
      `function summarize() { Promise.resolve().then(() => { for (;;) {} }); return '{"sync":true}'; }`,
      healthy,
    ]);
    assert.deepEqual(results, [
      ...expressions.map(() => ({ ok: false, error: "Kit runtime failed" })),
      { ok: true, result: { sync: true } },
      { ok: true, result: healthyResult },
    ]);
  });

  test("UTF-8 source, serialized input and copied output enforce their exact size bounds", async () => {
    const source = `${healthy}\n//`;
    assert.deepEqual(await runKit(source.padEnd(24 * 1024, "x"), input), healthyResult);
    for (const oversized of [source.padEnd(24 * 1024 + 1, "x"), `${source}${"é".repeat(12 * 1024)}`]) {
      await assert.rejects(runKit(oversized, input), { message: "Kit source exceeds 24 KiB" });
    }

    const padded = { entries: [], today: input.today, padding: "" };
    padded.padding = "x".repeat(256 * 1024 - JSON.stringify(padded).length);
    assert.deepEqual(await runKit(healthy, padded), healthyResult);
    await assert.rejects(runKit(healthy, { ...padded, padding: `${padded.padding}x` }), { message: "Kit input exceeds 256 KiB" });
    await assert.rejects(runKit(healthy, { ...padded, padding: "é".repeat(128 * 1024) }), { message: "Kit input exceeds 256 KiB" });

    assert.equal((await runKit('function summarize() { return JSON.stringify("x".repeat(16382)); }', input)).length, 16382);
    assert.equal((await runKit('function summarize() { return JSON.stringify("é".repeat(8191)); }', input)).length, 8191);
    for (const expression of ['JSON.stringify("x".repeat(16383))', 'JSON.stringify("é".repeat(8192))', '"x".repeat(1024 * 1024)']) {
      await assert.rejects(runKit(`function summarize() { return ${expression}; }`, input), { message: "Kit output exceeds 16 KiB" });
    }
  });

  test("memory/stack controls and hostile traps fail generically without poisoning the next run", async () => {
    const results = await isolated([
      `function summarize() {
        let denied = false;
        try { new ArrayBuffer(12 * 1024 * 1024); } catch { denied = true; }
        return JSON.stringify({ denied });
      }`,
      "function summarize() { return summarize(); }",
      "function summarize( {",
      "function summarize() { throw new Proxy({}, { get() { for (;;) {} } }); }",
      'function summarize() { throw new Error("PRIVATE GUEST DATA"); }',
      'function summarize() { return "not JSON: PRIVATE GUEST DATA"; }',
      'function summarize() { return \'{"truncated":true}\\0not-json\'; }',
      healthy,
    ]);
    assert.deepEqual(results, [
      { ok: true, result: { denied: true } },
      ...Array.from({ length: 6 }, () => ({ ok: false, error: "Kit runtime failed" })),
      { ok: true, result: healthyResult },
    ]);
  });
}
