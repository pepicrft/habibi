import { test } from "node:test";
import assert from "node:assert/strict";
import { validateKit, validateEntry, validateSummary, generateKit, openKitVault, restoreKitVault, exampleKits } from "./kits.mjs";
import { runKit } from "./kits-runtime.mjs";

const passphrase = "disposable kit test passphrase";
const meal = { day: "2026-10-25", meal: "PRIVATE lunch 🥗", calories: 315 };

function memoryStorage(initial = null) {
  let record = structuredClone(initial);
  return {
    failWrites: false,
    async read() { return structuredClone(record); },
    async write(expectedRevision, next) {
      if (this.failWrites) throw new Error("Storage unavailable");
      if ((record?.revision ?? 0) !== expectedRevision) throw new Error("Stale vault revision");
      record = structuredClone(next);
    },
  };
}

test("the Kit contract accepts declared fields and rejects extra capabilities and ambiguous schemas", () => {
  assert.deepEqual(validateKit(exampleKits.calories), exampleKits.calories);
  const invalid = [
    { ...exampleKits.calories, apiVersion: 2 },
    { ...exampleKits.calories, permissions: ["network"] },
    { ...exampleKits.calories, name: " " },
    { ...exampleKits.calories, description: "x".repeat(301) },
    { ...exampleKits.calories, source: `//${"é".repeat(12 * 1024)}` },
    { ...exampleKits.calories, fields: [] },
    { ...exampleKits.calories, fields: [exampleKits.calories.fields[0], exampleKits.calories.fields[0]] },
    ...["__proto__", "constructor", "prototype", "Uppercase"].map(key => ({
      ...exampleKits.calories, fields: [{ ...exampleKits.calories.fields[0], key }],
    })),
    ...[
      { type: "html" }, { min: 1 }, { max: 1 }, { optional: true },
      { type: "number", min: 4, max: 3 }, { type: "number", max: Infinity },
    ].map(change => ({ ...exampleKits.calories, fields: [{ ...exampleKits.calories.fields[0], ...change }] })),
  ];
  for (const value of invalid) assert.throws(() => validateKit(value));
});

test("entries validate real dates, exact fields, finite numbers and inclusive ranges", () => {
  const kit = validateKit(exampleKits.calories);
  for (const calories of [0, 135.5, 20000]) assert.equal(validateEntry(kit, { ...meal, calories }).calories, calories);
  assert.equal(validateEntry(kit, { ...meal, day: "2024-02-29" }).day, "2024-02-29");
  assert.equal(validateEntry(kit, { ...meal, meal: "x".repeat(500) }).meal.length, 500);
  for (const values of [
    { ...meal, calories: -0.1 }, { ...meal, calories: 20000.1 },
    { ...meal, calories: Infinity }, { ...meal, calories: NaN }, { ...meal, calories: "315" },
    { ...meal, day: "2025-02-29" }, { ...meal, day: "2026-02-30" }, { ...meal, day: "2026-13-01" },
    { ...meal, day: "2026-1-01" }, { ...meal, meal: " " }, { ...meal, meal: "x".repeat(501) },
    { ...meal, extra: "not declared" }, { day: meal.day, meal: meal.meal },
  ]) assert.throws(() => validateEntry(kit, values));
  assert.deepEqual(validateSummary({ metrics: [{ label: "Total", value: "450", unit: "kcal" }] }), [{ label: "Total", value: "450", unit: "kcal" }]);
  for (const result of [
    { metrics: [{ label: "Total", value: 450, unit: "kcal" }] },
    { metrics: [], html: "<script>" },
    { metrics: [{ label: "Total", value: "450", unit: "kcal", href: "https://example.invalid" }] },
    { metrics: Array(9).fill({ label: "Total", value: "450", unit: "kcal" }) },
  ]) assert.throws(() => validateSummary(result));
});

test("encrypted Kits reopen and restore with independent namespaces and detached reads", async () => {
  const storage = memoryStorage();
  const session = await openKitVault(storage, passphrase);
  const first = await session.install(exampleKits.calories);
  const second = await session.install(exampleKits.calories);
  assert.notEqual(first, second);
  await session.addEntry(first, meal);
  await session.addEntry(second, { ...meal, meal: "Second Kit", calories: 135 });
  const saved = session.list();
  assert.equal(saved[0].entries[0].values.calories, 315);
  assert.equal(saved[1].entries[0].values.calories, 135);
  const detached = session.list();
  detached[0].entries[0].values.calories = 999;
  assert.deepEqual(session.list(), saved);

  const backup = session.backup();
  for (const plaintext of [meal.meal, "Daily Fuel", "summarize", passphrase]) assert.equal(backup.includes(plaintext), false);
  assert.deepEqual(Object.keys(JSON.parse(backup)).sort(), ["version", "revision", "vaultId", "recordId", "salt", "envelope"].sort());
  session.lock();
  assert.throws(() => session.list(), /locked/);
  assert.throws(() => session.backup(), /locked/);
  await assert.rejects(session.addEntry(first, meal), /locked/);
  const reopened = await openKitVault(storage, passphrase);
  assert.deepEqual(reopened.list(), saved);
  reopened.lock();

  const destination = memoryStorage();
  await restoreKitVault(destination, backup, passphrase);
  const restored = await openKitVault(destination, passphrase);
  assert.deepEqual(restored.list(), saved);
  await assert.rejects(restoreKitVault(destination, backup, passphrase), /empty workbench/);
  await restored.removeEntry(first, saved[0].entries[0].id);
  assert.equal(restored.list()[0].entries.length, 0);
  assert.equal(restored.list()[1].entries[0].values.calories, 135);
  restored.lock();
});

test("wrong keys, tampered identities and corrupt backups fail without rewriting stored data", async () => {
  const storage = memoryStorage();
  const session = await openKitVault(storage, passphrase);
  await session.install(exampleKits.workouts);
  const record = await storage.read();
  const backup = session.backup();
  session.lock();
  await assert.rejects(openKitVault(storage, "the wrong test passphrase"), /Cannot unlock/);
  assert.deepEqual(await storage.read(), record);

  const bytes = Uint8Array.from(atob(record.envelope), char => char.charCodeAt(0));
  bytes[bytes.length - 1] ^= 1;
  const tampered = btoa(String.fromCharCode(...bytes));
  for (const changed of [
    { ...record, envelope: tampered }, { ...record, recordId: crypto.randomUUID() },
    { ...record, vaultId: crypto.randomUUID() },
  ]) {
    const destination = memoryStorage();
    await assert.rejects(restoreKitVault(destination, JSON.stringify(changed), passphrase), /Cannot unlock/);
    assert.equal(await destination.read(), null);
  }
  for (const envelope of [undefined, "", null]) {
    const corrupt = JSON.parse(backup);
    if (envelope === undefined) delete corrupt.envelope; else corrupt.envelope = envelope;
    const corruptStorage = memoryStorage(corrupt);
    await assert.rejects(openKitVault(corruptStorage, passphrase));
    assert.deepEqual(await corruptStorage.read(), corrupt);
  }
});

test("failed writes and stale tabs preserve both durable and in-memory state", async () => {
  const storage = memoryStorage();
  const first = await openKitVault(storage, passphrase);
  const id = await first.install(exampleKits.calories);
  const second = await openKitVault(storage, passphrase);
  const before = first.list();
  const durable = await storage.read();
  storage.failWrites = true;
  await assert.rejects(first.addEntry(id, meal), /Storage unavailable/);
  assert.deepEqual(first.list(), before);
  assert.deepEqual(await storage.read(), durable);
  storage.failWrites = false;
  await first.addEntry(id, meal);
  const saved = await storage.read();
  await assert.rejects(second.addEntry(id, { ...meal, calories: 999 }), /Stale vault/);
  assert.deepEqual(second.list(), before);
  assert.deepEqual(await storage.read(), saved);
  await assert.rejects(first.addEntry(id, { ...meal, calories: -1 }), /allowed range/);
  assert.deepEqual(await storage.read(), saved);
  first.lock();
  second.lock();
});

test("actual example JavaScript uses the entered day, not UTC creation time, for totals", async () => {
  const today = "2026-10-25";
  const entries = [
    { id: "a", createdAt: "2026-10-24T23:30:00Z", values: { ...meal, calories: 135, reps: 3, weight: 7 } },
    { id: "b", createdAt: "2026-10-25T12:30:00Z", values: { ...meal, calories: 315, reps: 8, weight: 11 } },
    { id: "c", createdAt: "2026-10-25T11:30:00Z", values: { ...meal, day: "2026-10-24", calories: 999, reps: 20, weight: 50 } },
  ];
  assert.deepEqual(validateSummary(await runKit(exampleKits.calories.source, { entries, today })), [
    { label: "Calories today", value: "450", unit: "kcal" },
    { label: "Meals today", value: "2", unit: "meals" },
  ]);
  assert.deepEqual(validateSummary(await runKit(exampleKits.workouts.source, { entries, today })), [
    { label: "Sets today", value: "2", unit: "sets" },
    { label: "Reps today", value: "11", unit: "reps" },
    { label: "Training volume", value: "109", unit: "kg × reps" },
  ]);
  for (const kit of Object.values(exampleKits)) {
    const empty = validateSummary(await runKit(kit.source, { entries: [], today }));
    assert.ok(empty.every(metric => metric.value === "0"));
  }
});

function providerResult(content) {
  return new Response(JSON.stringify({ status: "completed", output: [{ type: "message", content }] }));
}

test("generation validates real source and discloses only the explicit prompt and draft", async () => {
  let calls = 0;
  const controller = new AbortController();
  const draft = { ...exampleKits.calories, name: "My fuel" };
  const generated = await generateKit("Track my workouts", { apiKey: "TEST key", model: "test-model", draft, signal: controller.signal }, async (url, options) => {
    calls += 1;
    assert.equal(url, "https://api.openai.com/v1/responses");
    assert.equal(options.signal, controller.signal);
    assert.equal(options.credentials, "omit");
    assert.equal(options.redirect, "error");
    const body = JSON.parse(options.body);
    assert.equal(body.store, false);
    assert.equal(body.model, "test-model");
    assert.equal(body.text.format.type, "json_schema");
    assert.equal(body.text.format.strict, true);
    assert.equal(body.input.length, 2);
    assert.equal(body.input[1].content, "Track my workouts");
    assert.ok(body.input[0].content.includes(JSON.stringify(draft)));
    assert.equal(options.body.includes("TEST key"), false);
    return providerResult([{ type: "output_text", text: JSON.stringify(exampleKits.workouts) }]);
  });
  assert.equal(calls, 1);
  assert.deepEqual(generated, exampleKits.workouts);
  const settings = { apiKey: "TEST key", model: "test-model" };
  for (const [prompt, changed] of [["", {}], ["x".repeat(4001), {}], ["Track meals", { apiKey: "" }], ["Track meals", { model: "" }]]) {
    await assert.rejects(generateKit(prompt, { ...settings, ...changed }, () => { throw new Error("MUST NOT SEND"); }), error => !error.message.includes("MUST NOT SEND"));
  }
});

test("provider refusals, incomplete results, invalid definitions, errors and cancellation never become Kits", async () => {
  const settings = { apiKey: "TEST key", model: "test-model" };
  const responses = [
    new Response("PRIVATE provider details", { status: 401 }),
    new Response(JSON.stringify({ status: "incomplete", output: [] })),
    providerResult([{ type: "refusal", refusal: "Declined" }]),
    providerResult([]),
    providerResult([{ type: "output_text", text: JSON.stringify({ ...exampleKits.calories, permissions: ["network"] }) }]),
  ];
  for (const response of responses) {
    await assert.rejects(generateKit("Track meals", settings, async () => response), error => !error.message.includes("PRIVATE"));
  }
  const controller = new AbortController();
  controller.abort();
  await assert.rejects(generateKit("Track meals", { ...settings, signal: controller.signal }, async (_, { signal }) => {
    signal.throwIfAborted();
  }), { name: "AbortError" });
});
