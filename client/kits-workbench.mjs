import { openKitVault, restoreKitVault, generateKit, validateKit, validateSummary, exampleKits } from "./kits.mjs";
import { converseWithKits, executeKitTool } from "./kits-agent.mjs";

const $ = id => document.getElementById(id);
const element = (tag, content, className) => {
  const node = document.createElement(tag);
  if (content !== undefined) node.textContent = content;
  if (className) node.className = className;
  return node;
};
const today = () => {
  const date = new Date();
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
};
function status(message, error = false) {
  $("status").textContent = message;
  $("status").dataset.error = String(error);
}

const configuration = await fetch("/inference-config.json", { cache: "no-store" }).then(response => response.json());
const localInference = configuration.provider === "claude-code";
const providerName = localInference ? "Claude Code" : "OpenAI";
const connection = () => ({
  apiKey: localInference ? "local-harness" : $("api-key").value,
  model: localInference ? "local-harness" : $("model").value,
  endpoint: localInference ? "/inference" : "https://api.openai.com/v1/responses",
});
if (localInference) {
  $("api-controls").hidden = true;
  $("provider-summary").textContent = "Claude Code · development harness · cloud inference";
  $("provider-disclosure").textContent = "Send my messages, requested Kit definitions, and synthetic test results through local Claude Code to Anthropic. Saved entries stay local unless I paste them myself.";
  $("provider-note").textContent = "Uses the local CLI’s existing authentication and default model. Native tools, hooks, skills, MCP, and session persistence are disabled. This is not an on-device model.";
}

// One record, with revision comparison inside the IndexedDB write transaction.
const db = await new Promise((resolve, reject) => {
  const request = indexedDB.open("habibi-kits", 1);
  request.onupgradeneeded = () => request.result.createObjectStore("vault");
  request.onsuccess = () => resolve(request.result);
  request.onerror = () => reject(new Error("Cannot open local storage"));
});
const storage = {
  read() {
    return new Promise((resolve, reject) => {
      const request = db.transaction("vault").objectStore("vault").get("current");
      request.onsuccess = () => resolve(request.result ?? null);
      request.onerror = () => reject(new Error("Cannot read local storage"));
    });
  },
  write(expectedRevision, record) {
    return new Promise((resolve, reject) => {
      const transaction = db.transaction("vault", "readwrite");
      const store = transaction.objectStore("vault");
      const request = store.get("current");
      let stale = false;
      request.onsuccess = () => {
        if ((request.result?.revision ?? 0) !== expectedRevision) {
          stale = true;
          transaction.abort();
        } else store.put(record, "current");
      };
      transaction.oncomplete = () => resolve();
      transaction.onabort = transaction.onerror = () => reject(new Error(stale
        ? "Another tab changed the vault. Lock and unlock before saving again."
        : "Could not save. Your previous encrypted data is unchanged."));
    });
  },
};

let vault = null;
let draft = null;
let selected = null;
let epoch = 0;
let renderVersion = 0;
let generation = null;
let chatGeneration = null;
let chatHistory = [];
const workers = new Set();

async function perform(button, work) {
  const start = epoch;
  button.disabled = true;
  button.setAttribute("aria-busy", "true");
  try {
    await work();
  } catch (error) {
    if (epoch === start) status(error.name === "AbortError" ? "Request stopped. Previously approved changes are kept; check your Kits." : error.message, true);
  } finally {
    button.disabled = false;
    button.removeAttribute("aria-busy");
  }
}

function runSummary(definition, entries) {
  return new Promise((resolve, reject) => {
    const worker = new Worker("/kits-worker.js", { type: "module" });
    let timer;
    const task = { cancel: () => finish(new Error("Kit calculation cancelled")) };
    const finish = (error, result) => {
      clearTimeout(timer);
      worker.terminate();
      workers.delete(task);
      if (error) reject(error); else {
        try { resolve(validateSummary(result)); } catch { reject(new Error("Kit returned an invalid summary")); }
      }
    };
    workers.add(task);
    timer = setTimeout(() => finish(new Error("Kit calculation exceeded its time limit")), 2000);
    worker.onmessage = ({ data }) => data.ok ? finish(null, data.result) : finish(new Error(data.error));
    worker.onerror = event => { event.preventDefault(); finish(new Error("Kit calculation failed")); };
    worker.postMessage({ source: definition.source, input: { entries, today: today() } });
  });
}

function metrics(container, items) {
  container.replaceChildren();
  for (const metric of items) {
    const card = element("div", undefined, "metric");
    card.append(element("span", metric.label, "metric-label"), element("span", metric.value, "metric-value"), element("span", metric.unit, "metric-unit"));
    container.append(card);
  }
}

function download(name, contents) {
  const url = URL.createObjectURL(new Blob([contents], { type: "application/json" }));
  const link = element("a");
  link.href = url;
  link.download = name;
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

function readDraft() {
  if (!draft) throw new Error("Create a draft first");
  return validateKit({ ...draft, name: $("kit-name").value, description: $("kit-description").value, source: $("kit-source").value });
}

function navigate(view) {
  if (!vault) return;
  if (!["/conversation", "/profile", "/profile/kits"].includes(view)) view = "/conversation";
  location.hash = view;
  $("conversation").hidden = view !== "/conversation";
  $("profile").hidden = view !== "/profile";
  $("workspace").hidden = view !== "/profile/kits";
  $("nav-chat").setAttribute("aria-current", String(view === "/conversation"));
  $("nav-profile").setAttribute("aria-current", String(view.startsWith("/profile")));
}

function reviewTool(name, change, signal) {
  signal.throwIfAborted();
  const panel = $("tool-approval");
  const action = { save_kit: "Install", update_kit: "Update", remove_kit: "Remove" }[name];
  panel.replaceChildren(element("p", "Your approval is required", "eyebrow"), element("h2", `${action} ${change.definition.name}?`));
  panel.append(element("p", change.definition.description));
  if (name === "remove_kit") {
    panel.append(element("p", `This deletes the Kit and ${change.entries} saved ${change.entries === 1 ? "entry" : "entries"} from this vault. It cannot be undone here. Older backups are unaffected.`));
  } else {
    panel.append(element("p", name === "save_kit"
      ? "Installs a new Kit with its own empty data. The model cannot approve this for you."
      : `Updates ${change.previous.name}. All ${change.entries} saved entries are kept. Field/schema changes are not supported.`));
    panel.append(element("ul", undefined, "field-list"));
    for (const field of change.definition.fields) panel.lastChild.append(element("li", `${field.label} · ${field.type}`));
    for (const [label, definition] of [["Current JavaScript", change.previous], ["Proposed JavaScript", change.definition]]) {
      if (!definition) continue;
      const details = element("details");
      const code = element("textarea", undefined, "code");
      code.value = definition.source;
      code.readOnly = true;
      code.rows = 10;
      code.setAttribute("aria-label", label);
      details.append(element("summary", label), code);
      panel.append(details);
    }
  }
  const buttons = element("div", undefined, "toolbar");
  const allow = element("button", `Allow ${action.toLowerCase()}`, "button-primary");
  const deny = element("button", "Deny");
  allow.type = deny.type = "button";
  allow.id = "approve-tool";
  deny.id = "deny-tool";
  buttons.append(allow, deny);
  panel.append(buttons);
  panel.hidden = false;
  panel.scrollIntoView({ block: "center" });
  return new Promise(resolve => {
    const finish = approved => {
      signal.removeEventListener("abort", abort);
      panel.hidden = true;
      panel.replaceChildren();
      resolve(approved);
    };
    const abort = () => finish(false);
    allow.addEventListener("click", () => finish(true), { once: true });
    deny.addEventListener("click", () => finish(false), { once: true });
    signal.addEventListener("abort", abort, { once: true });
  });
}

async function showDraft(value) {
  const version = ++renderVersion;
  const active = epoch;
  draft = validateKit(value);
  $("kit-name").value = draft.name;
  $("kit-description").value = draft.description;
  $("kit-source").value = draft.source;
  $("draft-fields").replaceChildren(...draft.fields.map(field => element("li", `${field.label} · ${field.type}${field.unit ? ` · ${field.unit}` : ""}`)));
  $("draft").hidden = false;
  $("creator").hidden = false;
  $("kit-detail").hidden = true;
  $("generate").textContent = "Refine draft";
  selected = null;
  renderList();
  $("draft-preview").replaceChildren(element("p", "Checking empty-data summary…", "small"));
  try {
    const result = await runSummary(draft, []);
    if (epoch === active && version === renderVersion) metrics($("draft-preview"), result);
  } catch (error) {
    if (epoch === active && version === renderVersion) $("draft-preview").replaceChildren(element("p", error.message, "small"));
  }
}

function renderList() {
  const kits = vault.list();
  $("kit-list").replaceChildren();
  if (!kits.length) $("kit-list").append(element("p", "No Kits yet. Start with something small.", "empty-list"));
  for (const kit of kits) {
    const button = element("button", undefined, "kit-link");
    button.type = "button";
    button.setAttribute("aria-current", String(kit.id === selected));
    button.append(element("strong", kit.definition.name), element("span", `${kit.entries.length} ${kit.entries.length === 1 ? "entry" : "entries"}`));
    button.addEventListener("click", () => perform(button, () => showKit(kit.id)));
    $("kit-list").append(button);
  }
}

async function showKit(id) {
  const version = ++renderVersion;
  const active = epoch;
  const session = vault;
  const kit = session.list().find(item => item.id === id);
  if (!kit) throw new Error("Kit not found");
  selected = id;
  $("creator").hidden = true;
  $("draft").hidden = true;
  $("kit-detail").hidden = false;
  renderList();
  const detail = $("kit-detail");
  detail.replaceChildren();
  const heading = element("div", undefined, "detail-heading");
  const title = element("div");
  title.append(element("h2", kit.definition.name), element("p", kit.definition.description));
  heading.append(title, element("span", "Private Kit", "badge"));
  const summary = element("div", undefined, "metrics");
  summary.setAttribute("aria-label", "Kit summary");
  summary.append(element("p", "Calculating locally in Wasm…", "small"));
  detail.append(heading, summary, element("p", "Kit-generated calculations · only this Kit’s entries · not medical advice", "small"), element("h3", "Add an entry"));
  const form = element("form");
  const fields = element("div", undefined, "entry-fields");
  for (const field of kit.definition.fields) {
    const wrapper = element("div");
    const label = element("label", `${field.label}${field.unit ? ` (${field.unit})` : ""}`);
    const input = element("input");
    input.id = `entry-${field.key}`;
    input.name = field.key;
    input.type = field.type;
    input.required = true;
    label.htmlFor = input.id;
    if (field.type === "date") input.value = today();
    if (field.type === "number") {
      input.step = "any";
      if (field.min !== null) input.min = String(field.min);
      if (field.max !== null) input.max = String(field.max);
    } else if (field.type === "text") input.maxLength = 500;
    wrapper.append(label, input);
    fields.append(wrapper);
  }
  const save = element("button", "Save entry", "button-primary");
  form.append(fields, save);
  form.addEventListener("submit", event => {
    event.preventDefault();
    perform(save, async () => {
      const values = Object.fromEntries(kit.definition.fields.map(field => {
        const input = form.elements.namedItem(field.key);
        return [field.key, field.type === "number" ? input.valueAsNumber : input.value];
      }));
      await session.addEntry(id, values);
      if (epoch !== active) return;
      status("Entry saved locally and encrypted. Nothing was sent to a model.");
      await showKit(id);
    });
  });
  detail.append(form, element("h3", `Entries · ${kit.entries.length}`));
  if (kit.entries.length) {
    const wrap = element("div", undefined, "table-wrap");
    wrap.tabIndex = 0;
    wrap.setAttribute("role", "region");
    wrap.setAttribute("aria-label", "Saved entries; scroll horizontally for more columns");
    const table = element("table");
    const head = element("thead");
    const headers = element("tr");
    for (const field of kit.definition.fields) headers.append(element("th", `${field.label}${field.unit ? ` (${field.unit})` : ""}`));
    headers.append(element("th", "Action"));
    head.append(headers);
    const body = element("tbody");
    for (const entry of kit.entries.toReversed()) {
      const row = element("tr");
      for (const field of kit.definition.fields) row.append(element("td", String(entry.values[field.key])));
      const cell = element("td");
      const remove = element("button", "Delete");
      remove.type = "button";
      remove.setAttribute("aria-label", `Delete entry ${entry.id}`);
      remove.addEventListener("click", () => perform(remove, async () => {
        if (!confirm("Delete this entry from your local Kit? Older backups can still contain it.")) return;
        await session.removeEntry(id, entry.id);
        if (epoch === active) { status("Entry deleted locally."); await showKit(id); }
      }));
      cell.append(remove);
      row.append(cell);
      body.append(row);
    }
    table.append(head, body);
    wrap.append(table);
    detail.append(wrap);
  } else detail.append(element("p", "Your first entry starts here.", "small"));
  const exportButton = element("button", "Export Kit definition", "quiet");
  exportButton.type = "button";
  exportButton.addEventListener("click", () => download("habibi-kit.json", JSON.stringify(kit.definition, null, 2)));
  detail.append(exportButton, element("p", "Exports code and field definitions only, never saved entries. Review before sharing.", "small"));
  try {
    const result = await runSummary(kit.definition, kit.entries);
    if (epoch === active && version === renderVersion) metrics(summary, result);
  } catch (error) {
    if (epoch === active && version === renderVersion) summary.replaceChildren(element("p", `${error.message}. Your saved entries are still available.`, "small"));
  }
}

function startCreating() {
  renderVersion += 1;
  selected = null;
  $("kit-detail").hidden = true;
  $("creator").hidden = false;
  $("draft").hidden = !draft;
  renderList();
  $("prompt").focus();
}

async function lockedCopy() {
  const exists = Boolean(await storage.read());
  $("unlock-title").textContent = exists ? "Welcome back." : "Create a local vault";
  $("unlock-copy").textContent = exists
    ? "Unlock your Kits with your vault passphrase. Your key stays in memory only while this workbench is open."
    : "Choose a passphrase to encrypt your Kits and entries in this browser. It cannot be reset. Keep encrypted backups somewhere safe.";
}

$("unlock-form").addEventListener("submit", event => {
  event.preventDefault();
  perform($("unlock-button"), async () => {
    vault = await openKitVault(storage, $("passphrase").value);
    $("passphrase").value = "";
    document.body.dataset.unlocked = "true";
    $("locked").hidden = true;
    $("app-navigation").hidden = false;
    $("provider-panel").hidden = false;
    $("vault-actions").hidden = false;
    status("");
    const kits = vault.list();
    if (kits.length) await showKit(kits[0].id); else startCreating();
    navigate(location.hash.slice(1));
  });
});

$("lock").addEventListener("click", () => {
  epoch += 1;
  renderVersion += 1;
  generation?.abort();
  generation = null;
  chatGeneration?.abort();
  chatGeneration = null;
  chatHistory = [];
  for (const task of workers) task.cancel();
  vault?.lock();
  vault = null;
  draft = null;
  selected = null;
  delete document.body.dataset.unlocked;
  for (const id of ["prompt", "chat-message", "api-key", "kit-name", "kit-description", "kit-source"]) $(id).value = "";
  $("provider-consent").checked = false;
  $("generate").textContent = "Generate draft";
  for (const id of ["kit-list", "kit-detail", "draft-fields", "draft-preview", "chat-transcript", "tool-log"]) $(id).replaceChildren();
  for (const id of ["workspace", "draft", "vault-actions", "conversation", "profile", "app-navigation", "provider-panel"]) $(id).hidden = true;
  $("locked").hidden = false;
  status("Vault locked. Decrypted state and provider credentials were cleared from the workbench.");
  lockedCopy().catch(() => status("Cannot read local storage", true));
});

$("create-form").addEventListener("submit", event => {
  event.preventDefault();
  perform($("generate"), async () => {
    if (!$("provider-consent").checked || !connection().apiKey.trim()) {
      $("provider-settings").open = true;
      throw new Error(localInference ? "Approve sending the prompt and draft through Claude Code first." : "Add your OpenAI API key and approve sending the prompt and draft first.");
    }
    const active = epoch;
    const version = renderVersion;
    const controller = new AbortController();
    generation = controller;
    const timer = setTimeout(() => controller.abort(), 90000);
    $("stop-generation").hidden = false;
    status(`Generating a draft with ${providerName}. No saved entries are included. Nothing is installed yet.`);
    try {
      const result = await generateKit($("prompt").value, {
        ...connection(),
        draft: draft ? readDraft() : undefined, signal: controller.signal,
      });
      if (epoch !== active || controller.signal.aborted) return;
      if (version !== renderVersion) {
        status("Generation finished, but the draft or selection changed. The result was discarded.");
        return;
      }
      await showDraft(result);
      if (epoch === active) status("Draft ready. Review its name, description, fields, and JavaScript before installing.");
    } finally {
      clearTimeout(timer);
      if (generation === controller) generation = null;
      $("stop-generation").hidden = true;
    }
  });
});

$("stop-generation").addEventListener("click", () => generation?.abort());
for (const id of ["kit-name", "kit-description", "kit-source"]) {
  $(id).addEventListener("input", () => { renderVersion += 1; });
}
$("new-kit").addEventListener("click", startCreating);
for (const [id, example] of [["example-calories", "calories"], ["example-workouts", "workouts"]]) {
  $(id).addEventListener("click", () => perform($(id), async () => {
    await showDraft(exampleKits[example]);
    status("Example template loaded, not generated by AI. Edit it before installing if you like.");
  }));
}
$("discard-draft").addEventListener("click", () => {
  draft = null;
  renderVersion += 1;
  $("draft").hidden = true;
  $("generate").textContent = "Generate draft";
  status("Draft discarded. Installed Kits are unchanged.");
});
$("install-kit").addEventListener("click", () => perform($("install-kit"), async () => {
  const definition = readDraft();
  const active = epoch;
  const session = vault;
  const preview = await runSummary(definition, []);
  if (epoch !== active) return;
  // The checked definition is staged once; never reread the editable controls here.
  const id = await session.install(definition);
  if (epoch !== active) return;
  metrics($("draft-preview"), preview);
  draft = null;
  $("generate").textContent = "Generate draft";
  status(`${definition.name} installed. Its data starts empty and stays separate from other Kits.`);
  await showKit(id);
}));
$("export-definition").addEventListener("click", () => perform($("export-definition"), async () => {
  download("habibi-kit.json", JSON.stringify(readDraft(), null, 2));
}));
$("backup").addEventListener("click", () => perform($("backup"), async () => {
  download("habibi-kits-encrypted.json", vault.backup());
  status("Encrypted backup downloaded. You need your vault passphrase to restore it.");
}));
$("import-button").addEventListener("click", () => $("import-file").click());
$("import-file").addEventListener("change", () => perform($("import-button"), async () => {
  const file = $("import-file").files[0];
  const active = epoch;
  if (!file) return;
  // JSON escaping can expand a valid 24 KiB source by up to six times.
  if (file.size > 160 * 1024) throw new Error("Kit definition is too large");
  const definition = JSON.parse(await file.text());
  $("import-file").value = "";
  if (epoch !== active) return;
  await showDraft(definition);
  status("Imported as a draft, not installed. Review the code and fields first.");
}));
$("restore-file").addEventListener("change", () => perform($("unlock-button"), async () => {
  const file = $("restore-file").files[0];
  if (!file) return;
  if (file.size > 1500 * 1024) throw new Error("Backup is too large");
  await restoreKitVault(storage, await file.text(), $("passphrase").value);
  $("restore-file").value = "";
  await lockedCopy();
  status("Backup restored. Open the workbench with its passphrase.");
}));

$("nav-chat").addEventListener("click", () => navigate("/conversation"));
$("nav-profile").addEventListener("click", () => navigate("/profile"));
$("kits-back").addEventListener("click", () => navigate("/profile"));
for (const id of ["profile-kits", "chat-open-kits"]) $(id).addEventListener("click", () => navigate("/profile/kits"));
window.addEventListener("hashchange", () => navigate(location.hash.slice(1)));

function chatMessage(role, message) {
  const item = element("div", undefined, "chat-message");
  item.dataset.role = role;
  item.append(element("strong", role === "user" ? "You" : "Habibi"), element("p", message));
  $("chat-transcript").append(item);
}

$("chat-form").addEventListener("submit", event => {
  event.preventDefault();
  perform($("chat-send"), async () => {
    if (!$("provider-consent").checked || !connection().apiKey.trim()) {
      $("provider-settings").open = true;
      throw new Error(localInference ? "Approve conversation disclosure through Claude Code first." : "Add your OpenAI API key and approve conversation disclosure first.");
    }
    const active = epoch;
    const session = vault;
    const controller = new AbortController();
    chatGeneration = controller;
    const timer = setTimeout(() => controller.abort(), 180000);
    $("chat-stop").hidden = false;
    $("chat-clear").disabled = true;
    const message = $("chat-message").value;
    $("chat-message").value = "";
    chatMessage("user", message);
    status(`Talking to ${providerName}. Kit tools run locally; saved entries are not sent.`);
    try {
      const result = await converseWithKits(message, {
        ...connection(), history: chatHistory,
        today: today(), signal: controller.signal,
        onTool: name => $("tool-log").append(element("li", `${name} · running locally`)),
        execute: async (name, args) => {
          const result = await executeKitTool(session, name, args, {
            evaluate: runSummary, today: today(), signal: controller.signal,
            writeDraft: showDraft, review: (action, change) => reviewTool(action, change, controller.signal),
          });
          if (epoch !== active) return result;
          if (result.approved === true) {
            if (name === "remove_kit") { draft = null; startCreating(); }
            else { draft = null; $("generate").textContent = "Generate draft"; await showKit(result.id); }
            $("tool-log").append(element("li", `${name} · approved and saved locally`));
          } else if (result.approved === false) $("tool-log").append(element("li", `${name} · denied; nothing changed`));
          if (name === "evaluate_kit") $("tool-log").append(element("li", `Synthetic test: ${result.metrics.map(metric => `${metric.label}: ${metric.value} ${metric.unit}`).join(" · ")}`));
          return result;
        },
      });
      if (epoch !== active || controller.signal.aborted) return;
      chatHistory = result.history;
      chatMessage("assistant", result.answer);
      status("Reply ready. Review your saved Kits under Profile → Kits.");
    } finally {
      clearTimeout(timer);
      if (chatGeneration === controller) chatGeneration = null;
      $("chat-stop").hidden = true;
      $("chat-clear").disabled = false;
    }
  });
});
$("chat-stop").addEventListener("click", () => chatGeneration?.abort());
$("chat-clear").addEventListener("click", () => {
  chatHistory = [];
  $("chat-transcript").replaceChildren();
  $("tool-log").replaceChildren();
  status("Conversation cleared from the workbench. Saved Kits are unchanged.");
});

await lockedCopy();
