import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { openKitVault, exampleKits, validateSummary } from "./kits.mjs";
import { runKit } from "./kits-runtime.mjs";
import { executeKitTool, converseWithKits, kitTools } from "./kits-agent.mjs";
import { decisionSchema, nativeDecisionSchema, nativeKitTools, inferenceProtocol, kitInferenceResponse } from "./kits-local-inference.mjs";
import { harnessInferenceResponse } from "../native/resources/harness-inference.mjs";

const today = "2026-10-25";
const meal = { day: today, meal: "PRIVATE SAVED JOURNAL", calories: 951 };
const evaluate = async (definition, entries) => validateSummary(await runKit(definition.source, { entries, today }));

async function vault() {
  let record = null;
  return openKitVault({
    read: async () => record,
    write: async (expected, next) => {
      assert.equal(record?.revision ?? 0, expected);
      record = next;
    },
  }, "disposable test passphrase");
}

test("Kit tools stage and evaluate real JavaScript without reading saved entries or implicitly installing", async () => {
  const session = await vault();
  const id = await session.install(exampleKits.calories);
  await session.addEntry(id, meal);
  const before = session.backup();
  let staged;
  const options = { evaluate, today, writeDraft: async definition => { staged = definition; }, review: async () => false };
  const call = (name, args) => executeKitTool(session, name, args, options);
  assert.equal((await call("write_kit", { definition: exampleKits.workouts })).persisted, false);
  assert.deepEqual(staged, exampleKits.workouts);
  const result = await call("evaluate_kit", { definition: exampleKits.calories, entries_json: JSON.stringify([
    { ...meal, meal: "Synthetic A", calories: 135 }, { ...meal, meal: "Synthetic B", calories: 315 },
  ]) });
  assert.equal(result.metrics[0].value, "450");
  for (const output of [await call("list_kits", {}), await call("read_kit", { id }), result]) {
    assert.equal(JSON.stringify(output).includes(meal.meal), false);
    assert.equal(JSON.stringify(output).includes('"951"'), false);
  }
  assert.deepEqual(await call("save_kit", { definition: exampleKits.workouts }), { approved: false, changed: false });
  assert.equal(session.backup(), before);
  for (const [name, args] of [["delete_vault", {}], ["save_kit", { definition: exampleKits.workouts, approved: true }], ["read_kit", { id: "missing" }], ["evaluate_kit", { definition: exampleKits.calories, entries_json: "[{\"calories\":3}]" }]]) {
    await assert.rejects(call(name, args));
  }
  session.lock();
});

test("approved updates preserve entries; schema migrations, denied changes and revoked approvals do not mutate Kits", async () => {
  const session = await vault();
  const options = { evaluate, today, writeDraft: async () => {}, review: async () => true };
  const call = (name, args, extra = {}) => executeKitTool(session, name, args, { ...options, ...extra });
  const { id } = await call("save_kit", { definition: exampleKits.calories });
  await session.addEntry(id, meal);
  const entries = session.list()[0].entries;
  const changed = { ...exampleKits.calories, name: "My Fuel", description: "My daily food journal.", source: exampleKits.calories.source.replace("Calories today", "Daily energy") };
  await call("update_kit", { id, definition: changed });
  assert.equal(session.list()[0].definition.name, "My Fuel");
  assert.deepEqual(session.list()[0].entries, entries);
  for (const fields of [
    changed.fields.toReversed(), changed.fields.slice(1),
    changed.fields.map(field => field.key === "calories" ? { ...field, unit: "kJ" } : field),
    changed.fields.map(field => field.key === "calories" ? { ...field, min: 1 } : field),
  ]) await assert.rejects(call("update_kit", { id, definition: { ...changed, fields } }), /migration/);
  const before = session.backup();
  await call("remove_kit", { id }, { review: async () => false });
  assert.equal(session.backup(), before);
  const controller = new AbortController();
  await assert.rejects(call("remove_kit", { id }, { signal: controller.signal, review: async () => { controller.abort(); return true; } }), { name: "AbortError" });
  assert.equal(session.backup(), before);
  await assert.rejects(call("remove_kit", { id }, { review: async () => { await session.addEntry(id, { ...meal, calories: 135 }); return true; } }), /changed while awaiting approval/);
  assert.equal(session.list()[0].entries.length, 2);
  await call("remove_kit", { id });
  assert.deepEqual(session.list(), []);
  session.lock();
});

test("the stateless Responses tool protocol continues with actual local results and no saved entry disclosure", async () => {
  const session = await vault();
  const id = await session.install(exampleKits.calories);
  await session.addEntry(id, meal);
  const outputs = [];
  const requests = [];
  const calls = [
    { name: "list_kits", args: {} },
    { name: "read_kit", args: { id } },
    { name: "evaluate_kit", args: { definition: exampleKits.calories, entries_json: JSON.stringify([{ ...meal, meal: "Synthetic", calories: 135 }]) } },
    { name: "update_kit", args: { id, definition: { ...exampleKits.calories, name: "My Fuel" } } },
  ];
  const result = await converseWithKits("Rename my calorie journal and test the calculation", {
    apiKey: "TEST-KEY", model: "test-model", today,
    execute: async (name, args) => {
      const result = await executeKitTool(session, name, args, { evaluate, today, review: async () => true, writeDraft: async () => {} });
      outputs.push(result);
      return result;
    },
  }, async (url, options) => {
    assert.equal(url, "https://api.openai.com/v1/responses");
    const body = JSON.parse(options.body);
    requests.push(body);
    assert.equal(body.store, false);
    assert.equal(body.parallel_tool_calls, false);
    assert.equal(body.tools.length, 7);
    assert.equal(options.body.includes(meal.meal), false);
    const index = requests.length - 1;
    if (index > 0) assert.deepEqual(JSON.parse(body.input.at(-1).output), outputs[index - 1]);
    if (index === 1) assert.ok(body.input.some(item => item.type === "reasoning" && item.encrypted_content === "OPAQUE"));
    const call = calls[index];
    return new Response(JSON.stringify({ status: "completed", output: call ? [
      { type: "reasoning", id: `reason-${index}`, summary: [], encrypted_content: "OPAQUE" },
      { type: "function_call", call_id: `call-${index}`, name: call.name, arguments: JSON.stringify(call.args) },
    ] : [{ type: "message", role: "assistant", content: [{ type: "output_text", text: "Renamed after your approval. Test total: 135 kcal." }] }] }));
  });
  assert.equal(result.answer, "Renamed after your approval. Test total: 135 kcal.");
  assert.equal(requests.length, 5);
  assert.equal(session.list()[0].definition.name, "My Fuel");
  assert.equal(session.list()[0].entries[0].values.meal, meal.meal);
  assert.equal(JSON.stringify(result.history).includes(meal.meal), false);
  session.lock();
});

test("unknown calls, provider failures, cancellation and excessive tool loops fail closed", async () => {
  const settings = { apiKey: "TEST-KEY", model: "test-model", today, execute: async () => { throw new Error("UNEXPECTED EXECUTION"); } };
  for (const response of [
    new Response("PRIVATE PROVIDER DETAILS", { status: 401 }),
    new Response(JSON.stringify({ status: "incomplete", output: [] })),
    new Response(JSON.stringify({ status: "completed", output: [{ type: "function_call", call_id: "bad", name: "http_fetch", arguments: "{}" }] })),
  ]) await assert.rejects(converseWithKits("Make a Kit", settings, async () => response), error => !/PRIVATE|UNEXPECTED/.test(error.message));
  const controller = new AbortController();
  controller.abort();
  await assert.rejects(converseWithKits("Make a Kit", { ...settings, signal: controller.signal }, async () => { throw new Error("UNEXPECTED REQUEST"); }), { name: "AbortError" });
  let calls = 0;
  await assert.rejects(converseWithKits("List my Kits", { ...settings, execute: async () => [] }, async () => {
    calls += 1;
    return new Response(JSON.stringify({ status: "completed", output: [{ type: "function_call", call_id: `call-${calls}`, name: "list_kits", arguments: "{}" }] }));
  }), /tool limit/);
  assert.equal(calls, 8);
});

test("native display tools are opt-in protocol data; the browser retains only seven Kit tools", async () => {
  assert.equal(kitTools.length, 7);
  assert.equal(nativeKitTools.length, 8);
  assert.equal(decisionSchema.properties.name.enum.includes("present_component"), false);
  assert.equal(nativeDecisionSchema.properties.name.enum.includes("present_component"), true);
  assert.deepEqual(JSON.parse(await readFile(new URL("../native/core/assets/kit-tools.json", import.meta.url), "utf8")), nativeKitTools);
  const card = { type: "result_table", version: 1, data: { title: "Test", columns: ["Value"], rows: [["7"]] }, actions: [{ id: "show_source", label: "View data" }], fallback: "Value: 7" };
  const decision = { kind: "tool", name: "present_component", arguments_json: JSON.stringify({ component: card }), reply: "" };
  assert.throws(() => kitInferenceResponse(decision));
  const result = kitInferenceResponse(decision, true, nativeKitTools);
  assert.equal(result.status, "completed");
  assert.equal(result.output[0].name, "present_component");
  assert.deepEqual(JSON.parse(result.output[0].arguments), { component: card });
  assert.equal(typeof result.output[0].call_id, "string");
  for (const name of ["read_file", "shell_command", "commit_kit", "http_fetch"]) {
    assert.throws(() => kitInferenceResponse({ ...decision, name }, true, nativeKitTools));
  }
  for (const malformed of [null, [], {}, { ...decision, extra: true }, { ...decision, reply: "also reply" },
    ...["{", "null", "[]", "true", '"string"'].map(arguments_json => ({ ...decision, arguments_json }))]) {
    assert.throws(() => kitInferenceResponse(malformed, true, nativeKitTools));
  }
  // Canonicalize definitions, and reject unknown names, duplicates and subsets.
  const supplied = nativeKitTools.map(tool => ({ name: tool.name, description: "untrusted", parameters: {} }));
  assert.equal(inferenceProtocol(supplied).tools, nativeKitTools);
  for (const tools of [[], [nativeKitTools.at(-1)], [...kitTools, { name: "read_file" }], [...kitTools, kitTools[0]]]) {
    assert.throws(() => inferenceProtocol(tools));
  }
});

test("Amp and Pi terminal result adapters accept native component requests but reject host execution and incomplete replies", () => {
  const decision = { kind: "tool", name: "present_component", arguments_json: '{"component":{}}', reply: "" };
  // Schema/content validation is deliberately deferred to Rust, never to the renderer.
  const text = JSON.stringify(decision);
  const streams = {
    amp: [{ type: "result", subtype: "success", is_error: false, result: text }],
    pi: [{ type: "message_end", message: { role: "assistant", stopReason: "stop", content: [{ type: "text", text }] } }],
  };
  const encode = events => events.map(event => JSON.stringify(event)).join("\n");
  for (const [harness, events] of Object.entries(streams)) {
    const result = harnessInferenceResponse(harness, encode(events), nativeKitTools);
    assert.equal(result.output[0].name, "present_component");
    assert.throws(() => harnessInferenceResponse(harness, encode(events), kitTools));
    for (const event of [{ type: "tool_execution_start" },
      { type: "assistant", message: { content: [{ type: "tool_use", name: "shell_command" }] } },
      { type: "message_end", message: { content: [{ type: "toolCall", name: "read_file" }] } }]) {
      assert.throws(() => harnessInferenceResponse(harness, encode([event, ...events]), nativeKitTools), /host tool/);
    }
  }
  const ampAssistant = { type: "assistant", message: { content: [{ type: "text", text }] } };
  assert.equal(harnessInferenceResponse("amp", encode([ampAssistant, { type: "result", subtype: "success", is_error: false }]), nativeKitTools).output[0].name, "present_component");
  for (const [harness, events] of [["amp", [ampAssistant]], ["amp", [{ type: "result", is_error: true, result: text }]],
    ["amp", [{ type: "result", subtype: "error_max_turns", result: text }]],
    ["pi", [{ type: "message_end", message: { role: "assistant", stopReason: "length", content: [{ type: "text", text }] } }]]]) {
    assert.throws(() => harnessInferenceResponse(harness, encode(events), nativeKitTools));
  }
});
