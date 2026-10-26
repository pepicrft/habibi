import { encryptRecord, decryptRecord } from "./vault.mjs";

const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });
const maxSourceBytes = 24 * 1024;
const maxBackupBytes = 1500 * 1024;
const unsafeKeys = new Set(["constructor", "prototype", "__proto__"]);

function object(value, keys) {
  if (!value || typeof value !== "object" || Array.isArray(value) ||
      Object.keys(value).some(key => !keys.includes(key)) || keys.some(key => !Object.hasOwn(value, key))) {
    throw new Error("Unexpected or missing Kit fields");
  }
}

function text(value, limit, label) {
  if (typeof value !== "string" || !value.trim() || value.length > limit) {
    throw new Error(`${label} must contain 1–${limit} characters`);
  }
  return value.trim();
}

// A deliberately small declarative schema, not arbitrary JSON Schema or HTML.
export function validateKit(value) {
  object(value, ["apiVersion", "name", "description", "fields", "source"]);
  if (value.apiVersion !== 1) throw new Error("Unsupported Kit API version");
  if (!Array.isArray(value.fields) || value.fields.length < 1 || value.fields.length > 12) {
    throw new Error("A Kit needs 1–12 fields");
  }
  const seen = new Set();
  const fields = value.fields.map(field => {
    object(field, ["key", "label", "type", "unit", "min", "max"]);
    if (typeof field.key !== "string" || !/^[a-z][a-z0-9_]{0,31}$/.test(field.key) ||
        unsafeKeys.has(field.key) || seen.has(field.key)) throw new Error("Invalid or duplicate field key");
    seen.add(field.key);
    if (!["text", "number", "date"].includes(field.type)) throw new Error("Unsupported field type");
    if (typeof field.unit !== "string" || field.unit.length > 16) throw new Error("Invalid field unit");
    for (const bound of [field.min, field.max]) {
      if (bound !== null && (field.type !== "number" || !Number.isFinite(bound) || Math.abs(bound) > 1e9)) {
        throw new Error("Invalid numeric field bounds");
      }
    }
    if (field.min !== null && field.max !== null && field.min > field.max) throw new Error("Invalid field range");
    return { ...field, label: text(field.label, 60, "Field label") };
  });
  if (typeof value.source !== "string" || !value.source.trim() || encoder.encode(value.source).length > maxSourceBytes) {
    throw new Error("Kit JavaScript must contain at most 24 KiB");
  }
  return {
    apiVersion: 1,
    name: text(value.name, 60, "Name"),
    description: text(value.description, 300, "Description"),
    fields,
    source: value.source,
  };
}

export function validateEntry(kit, values) {
  object(values, kit.fields.map(field => field.key));
  return Object.fromEntries(kit.fields.map(field => {
    const value = values[field.key];
    if (field.type === "number") {
      if (typeof value !== "number" || !Number.isFinite(value) || Math.abs(value) > 1e9 ||
          (field.min !== null && value < field.min) || (field.max !== null && value > field.max)) {
        throw new Error(`${field.label} is outside its allowed range`);
      }
    } else if (field.type === "date") {
      if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value) ||
          !Number.isFinite(Date.parse(value)) || new Date(value).toISOString().slice(0, 10) !== value) {
        throw new Error(`${field.label} needs a valid calendar date`);
      }
    } else {
      text(value, 500, field.label);
    }
    return [field.key, value];
  }));
}

export function validateSummary(result) {
  object(result, ["metrics"]);
  if (!Array.isArray(result.metrics) || result.metrics.length > 8) throw new Error("Invalid Kit summary");
  return result.metrics.map(metric => {
    object(metric, ["label", "value", "unit"]);
    if (typeof metric.value !== "string" || metric.value.length > 80 ||
        typeof metric.unit !== "string" || metric.unit.length > 16) throw new Error("Invalid Kit metric");
    return { label: text(metric.label, 60, "Metric label"), value: metric.value, unit: metric.unit };
  });
}

export const kitGenerationSchema = {
  type: "object",
  additionalProperties: false,
  required: ["apiVersion", "name", "description", "fields", "source"],
  properties: {
    apiVersion: { type: "integer", enum: [1] },
    name: { type: "string" },
    description: { type: "string" },
    fields: {
      type: "array",
      items: {
        type: "object", additionalProperties: false,
        required: ["key", "label", "type", "unit", "min", "max"],
        properties: {
          key: { type: "string" }, label: { type: "string" },
          type: { type: "string", enum: ["text", "number", "date"] },
          unit: { type: "string" }, min: { type: ["number", "null"] }, max: { type: ["number", "null"] },
        },
      },
    },
    source: { type: "string" },
  },
};

const instructions = `Create a Habibi Kit: a small personal tracker with a useful name (max60 chars) and description (max300 chars).
Return apiVersion:1, fields (1–12), and actual JavaScript source (max24KiB). All fields are required.
Field keys are unique lowercase identifiers, never constructor/prototype/__proto__. Labels max60 chars, units max16 chars.
Types: text (max500 chars), date (YYYY-MM-DD), number (finite, abs<=1e9). min/max are nullable number bounds; both null for non-number fields.
Source must declare a synchronous function summarize(inputJson). Input is a JSON STRING containing {entries:[{id,createdAt,values:{...field values}}],today:'YYYY-MM-DD'}.
Return a primitive JSON STRING: JSON.stringify({metrics:[{label:'...',value:String(number),unit:'...'}]}).
At most8 metrics, labels max60 chars, values max80 chars, units max16 chars. Handle an empty entries array.
Use input.today and an explicit date field for daily summaries; do not assume UTC createdAt is the user's calendar date.
There is NO Node, DOM, fetch, filesystem, module loader, imports, async, timers, network, host access or writes. No console. No export syntax.
The host renders fields and saves entries; JavaScript only calculates a read-only summary of this Kit's entries.
Do not include real personal data or dependencies. This is a tracker, not medical advice. Names and descriptions must explain what is actually implemented.`;

// Generation sends only the explicit prompt and draft, never saved entries or vault keys.
export async function generateKit(prompt, { apiKey, model, endpoint = "https://api.openai.com/v1/responses", draft, signal }, request = fetch) {
  text(prompt, 4000, "Prompt");
  text(apiKey, 512, "API key");
  text(model, 100, "Model");
  const input = [{ role: "user", content: prompt }];
  if (draft) input.unshift({ role: "user", content: `Revise this draft, keeping only the requested behavior:\n${JSON.stringify(validateKit(draft))}` });
  const response = await request(endpoint, {
    method: "POST", signal, credentials: "omit", redirect: "error", referrerPolicy: "no-referrer", cache: "no-store",
    headers: { authorization: `Bearer ${apiKey}`, "content-type": "application/json" },
    body: JSON.stringify({
      model, instructions, input, store: false, max_output_tokens: 6000,
      text: { format: { type: "json_schema", name: "habibi_kit", strict: true, schema: kitGenerationSchema } },
    }),
  });
  if (!response.ok) throw new Error(`Generation failed (HTTP ${response.status}). Check your provider settings.`);
  const body = await response.text();
  if (body.length > 128 * 1024) throw new Error("Provider response was too large");
  const result = JSON.parse(body);
  if (result.status !== "completed") throw new Error("Generation did not finish. Try again or shorten your request.");
  const parts = (result.output ?? []).filter(item => item.type === "message").flatMap(item => item.content ?? []);
  if (parts.some(part => part.type === "refusal")) throw new Error("The provider declined this request.");
  const output = parts.filter(part => part.type === "output_text").map(part => part.text).join("");
  if (!output) throw new Error("The provider returned no Kit");
  return validateKit(JSON.parse(output));
}

function encode(bytes) {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 8192) binary += String.fromCharCode(...bytes.subarray(i, i + 8192));
  return btoa(binary);
}

function decode(value) {
  if (typeof value !== "string" || value.length > maxBackupBytes) throw new Error("Invalid encrypted backup");
  return Uint8Array.from(atob(value), char => char.charCodeAt(0));
}

async function passwordKey(passphrase, salt) {
  const material = await crypto.subtle.importKey("raw", encoder.encode(passphrase), "PBKDF2", false, ["deriveBits"]);
  return new Uint8Array(await crypto.subtle.deriveBits({ name: "PBKDF2", hash: "SHA-256", salt, iterations: 600_000 }, material, 256));
}

function validateState(state) {
  object(state, ["version", "kits"]);
  if (state.version !== 1 || !Array.isArray(state.kits) || state.kits.length > 12) throw new Error("Unsupported Kit storage version");
  const ids = new Set();
  for (const kit of state.kits) {
    object(kit, ["id", "definition", "entries"]);
    if (typeof kit.id !== "string" || ids.has(kit.id)) throw new Error("Invalid Kit identity");
    ids.add(kit.id);
    kit.definition = validateKit(kit.definition);
    if (!Array.isArray(kit.entries) || kit.entries.length > 250) throw new Error("Invalid Kit entries");
    const entries = new Set();
    for (const entry of kit.entries) {
      object(entry, ["id", "createdAt", "values"]);
      if (typeof entry.id !== "string" || entries.has(entry.id) || typeof entry.createdAt !== "string" ||
          !Number.isFinite(Date.parse(entry.createdAt))) throw new Error("Invalid Kit entry identity");
      entries.add(entry.id);
      entry.values = validateEntry(kit.definition, entry.values);
    }
  }
  return state;
}

// Storage implements read() and compare-and-swap write(expectedRevision, record).
// The workbench persists only this encrypted snapshot. No server receives it.
export async function openKitVault(storage, passphrase) {
  text(passphrase, 1024, "Passphrase");
  if (passphrase.length < 12) throw new Error("Use a passphrase of at least 12 characters");
  let record = await storage.read();
  const existing = record !== null && record !== undefined;
  if (!existing) {
    record = { version: 1, revision: 0, vaultId: crypto.randomUUID(), recordId: crypto.randomUUID(), salt: encode(crypto.getRandomValues(new Uint8Array(32))) };
  } else {
    object(record, ["version", "revision", "vaultId", "recordId", "salt", "envelope"]);
    if (typeof record.envelope !== "string" || !record.envelope) throw new Error("Vault has no encrypted contents");
  }
  if (record.version !== 1 || !Number.isSafeInteger(record.revision) || record.revision < 0) throw new Error("Unsupported encrypted vault");
  const salt = decode(record.salt);
  if (salt.length !== 32) throw new Error("Invalid vault salt");
  const key = await passwordKey(passphrase, salt);
  let state;
  try {
    state = existing
      ? validateState(JSON.parse(decoder.decode(await decryptRecord(key, record.vaultId, record.recordId, decode(record.envelope)))))
      : { version: 1, kits: [] };
  } catch {
    key.fill(0);
    throw new Error("Cannot unlock this vault. Check the passphrase and backup version.");
  }
  let locked = false;
  let saving = false;
  const assertUnlocked = () => { if (locked) throw new Error("Vault is locked"); };
  async function change(update) {
    assertUnlocked();
    if (saving) throw new Error("Another save is in progress");
    saving = true;
    try {
      const next = structuredClone(state);
      const result = update(next);
      validateState(next);
      const prepared = {
        ...record, revision: record.revision + 1,
        envelope: encode(await encryptRecord(key, record.vaultId, record.recordId, encoder.encode(JSON.stringify(next)))),
      };
      assertUnlocked();
      await storage.write(record.revision, prepared);
      if (!locked) { record = prepared; state = next; }
      return result;
    } finally {
      saving = false;
    }
  }
  if (!existing) {
    try { await change(() => {}); } catch (error) { key.fill(0); throw error; }
  }
  return {
    list() { assertUnlocked(); return structuredClone(state.kits); },
    install(definition) {
      const validated = validateKit(definition);
      return change(next => {
        if (next.kits.length >= 12) throw new Error("This reference vault supports at most 12 Kits");
        const id = crypto.randomUUID();
        next.kits.push({ id, definition: validated, entries: [] });
        return id;
      });
    },
    update(kitId, definition) {
      const validated = validateKit(definition);
      return change(next => {
        const kit = next.kits.find(item => item.id === kitId);
        if (!kit) throw new Error("Kit not found");
        const keys = ["key", "label", "type", "unit", "min", "max"];
        if (validated.fields.length !== kit.definition.fields.length || validated.fields.some((field, index) =>
          keys.some(key => field[key] !== kit.definition.fields[index][key]))) {
          throw new Error("Updating fields requires a migration, which this workbench does not support. Create a new Kit instead.");
        }
        kit.definition = validated;
      });
    },
    remove(kitId) {
      return change(next => {
        if (!next.kits.some(kit => kit.id === kitId)) throw new Error("Kit not found");
        next.kits = next.kits.filter(kit => kit.id !== kitId);
      });
    },
    addEntry(kitId, values) {
      return change(next => {
        const kit = next.kits.find(item => item.id === kitId);
        if (!kit) throw new Error("Kit not found");
        if (kit.entries.length >= 250) throw new Error("This reference Kit supports at most 250 entries");
        kit.entries.push({ id: crypto.randomUUID(), createdAt: new Date().toISOString(), values: validateEntry(kit.definition, values) });
      });
    },
    removeEntry(kitId, entryId) {
      return change(next => {
        const kit = next.kits.find(item => item.id === kitId);
        if (!kit || !kit.entries.some(entry => entry.id === entryId)) throw new Error("Entry not found");
        kit.entries = kit.entries.filter(entry => entry.id !== entryId);
      });
    },
    backup() { assertUnlocked(); return JSON.stringify(record); },
    lock() { locked = true; key.fill(0); state = null; },
  };
}

export async function restoreKitVault(storage, backup, passphrase) {
  if (typeof backup !== "string" || encoder.encode(backup).length > maxBackupBytes) throw new Error("Backup is too large");
  if (await storage.read()) throw new Error("Restore requires an empty workbench; use a separate browser profile to keep existing data");
  const record = JSON.parse(backup);
  if (!record.envelope) throw new Error("Backup has no encrypted contents");
  const session = await openKitVault({ read: async () => record }, passphrase);
  session.lock();
  await storage.write(0, record);
}

export const exampleKits = {
  calories: {
    apiVersion: 1, name: "Daily Fuel", description: "Log meals and calories, with a daily total. Your food journal stays in this private Kit.",
    fields: [
      { key: "day", label: "Day", type: "date", unit: "", min: null, max: null },
      { key: "meal", label: "Meal", type: "text", unit: "", min: null, max: null },
      { key: "calories", label: "Calories", type: "number", unit: "kcal", min: 0, max: 20000 },
    ],
    source: `function summarize(inputJson) {
  const { entries, today } = JSON.parse(inputJson);
  const meals = entries.filter(entry => entry.values.day === today);
  const calories = meals.reduce((sum, entry) => sum + entry.values.calories, 0);
  return JSON.stringify({ metrics: [
    { label: "Calories today", value: String(calories), unit: "kcal" },
    { label: "Meals today", value: String(meals.length), unit: "meals" }
  ] });
}`,
  },
  workouts: {
    apiVersion: 1, name: "Rep Log", description: "Keep a simple training log: exercise, reps, and weight for each set, with daily totals.",
    fields: [
      { key: "day", label: "Day", type: "date", unit: "", min: null, max: null },
      { key: "exercise", label: "Exercise", type: "text", unit: "", min: null, max: null },
      { key: "reps", label: "Reps", type: "number", unit: "reps", min: 1, max: 1000 },
      { key: "weight", label: "Weight", type: "number", unit: "kg", min: 0, max: 1500 },
    ],
    source: `function summarize(inputJson) {
  const { entries, today } = JSON.parse(inputJson);
  const sets = entries.filter(entry => entry.values.day === today);
  const reps = sets.reduce((sum, entry) => sum + entry.values.reps, 0);
  const volume = sets.reduce((sum, entry) => sum + entry.values.reps * entry.values.weight, 0);
  return JSON.stringify({ metrics: [
    { label: "Sets today", value: String(sets.length), unit: "sets" },
    { label: "Reps today", value: String(reps), unit: "reps" },
    { label: "Training volume", value: String(volume), unit: "kg × reps" }
  ] });
}`,
  },
};
