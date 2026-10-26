//! Exercise the host-only entry path through the same JSON bridge as both apps.
use serde_json::{Value, json};

const CONVERSATION: &str = "7b9efe67-c157-44d2-b5eb-d78057dc6e22";
const MESSAGE: &str = "326c2270-a709-46a4-a3b5-5fecb59a7cc6";
const UNKNOWN: &str = "1fdce3f4-e43b-4690-a8cf-d963e65a0059";
const ORIGIN: &str = "https://habibi.example.test";

fn call(command: Value) -> Value {
    serde_json::from_str(&crate::execute(&command.to_string())).unwrap()
}

fn ok(command: Value) -> Value {
    let result = call(command);
    assert!(result["ok"].is_object(), "{result}");
    result["ok"].clone()
}

struct Vault {
    identity: Value,
    document: Value,
}

impl Vault {
    fn command(&self, operation: &str, arguments: Value) -> Value {
        let mut command =
            json!({"operation":operation,"identity":self.identity,"document":self.document});
        command
            .as_object_mut()
            .unwrap()
            .extend(arguments.as_object().unwrap().clone());
        command
    }

    fn read(&self, operation: &str, arguments: Value) -> Value {
        ok(self.command(operation, arguments))
    }

    fn write(&mut self, operation: &str, arguments: Value) -> Value {
        let saved = self.read(operation, arguments);
        assert!(saved["document"].is_object());
        // Publish only returned encrypted documents. Each next operation opens
        // serialized bytes afresh, with no in-memory session or receipt cache.
        self.document = serde_json::from_str(&saved["document"].to_string()).unwrap();
        saved
    }

    fn state(&self) -> Value {
        self.read("restore", json!({}))["state"].clone()
    }

    fn reject(&self, operation: &str, arguments: Value) {
        let before = self.state();
        let result = call(self.command(operation, arguments));
        assert_eq!(result["error"]["kind"], "invalid", "{result}");
        assert!(result.get("ok").is_none());
        assert_eq!(self.state(), before);
    }

    fn archive(&mut self, component: Value) -> Value {
        self.write(
            "save_conversations",
            json!({"conversations":transcript(component)}),
        )
    }
}

fn installed() -> (Vault, String) {
    let created = ok(json!({"operation":"create",
        "profile":{"name":"Noor","goals":["health"],"style":"warm"}}));
    let mut vault = Vault {
        identity: created["identity"].clone(),
        document: created["document"].clone(),
    };
    let definition = json!({"apiVersion":1,"name":"Reps","description":"A private training journal.",
        "fields":[
            {"key":"exercise","label":"Exercise","type":"text","unit":"","min":null,"max":null},
            {"key":"reps","label":"Reps","type":"number","unit":"reps","min":1,"max":100},
            {"key":"day","label":"Day","type":"date","unit":"","min":null,"max":null}],
        "source":"function summarize(s){return JSON.stringify({metrics:[]})}"});
    let mut review = vault.read(
        "kit_tool",
        json!({"name":"save_kit",
        "arguments":{"definition":definition},"today":"2026-10-26"}),
    )["review"]
        .clone();
    // Saving an entry, restoring, recovering and syncing must never execute
    // installed Kit code, even if that code cannot currently produce a summary.
    review["definition"]["source"] = json!("throw new Error('entry submission must not execute');");
    let saved = vault.write("commit_kit", json!({"review":review}));
    let id = saved["result"]["id"].as_str().unwrap().to_owned();
    (vault, id)
}

fn card(id: &str) -> Value {
    json!({"type":"kit_entry","version":1,
        "data":{"title":"Log a set","kitId":id,"prefill":[{"key":"exercise","value":"Squat"}]},
        "actions":[{"id":"save_entry","label":"Save entry"}],"fallback":"Log a set in your Reps Kit."})
}

fn transcript(component: Value) -> Value {
    json!([{"id":CONVERSATION,"createdAt":"2026-10-26T12:00:00Z","composer":"",
        "messages":[{"id":MESSAGE,"createdAt":"2026-10-26T12:00:01Z","kind":"assistant",
            "text":"Log a set.","component":component}]}])
}

fn values() -> Value {
    json!({"exercise":"Private squat 🏋️","reps":7,"day":"2026-10-26"})
}

fn submission(values: Value) -> Value {
    json!({"conversationId":CONVERSATION,"messageId":MESSAGE,"values":values})
}

fn model_call(name: &str, arguments: Value) -> Value {
    json!({"operation":"agent_response","response":{"status":"completed","output":[
        {"type":"function_call","name":name,"call_id":"display-1","arguments":arguments.to_string()}]}})
}

#[test]
fn kit_entry_protocol_is_bounded_strict_and_display_only_for_the_model() {
    let component = card(UNKNOWN);
    assert_eq!(
        ok(json!({"operation":"validate_component","component":component}))["component"],
        component
    );
    let response = ok(model_call(
        "present_component",
        json!({"component":component}),
    ));
    assert_eq!(response["component"], component);
    assert_eq!(response["tool"]["name"], "present_component");
    assert_eq!(
        response["tool"]["arguments"],
        json!({"component":component})
    );
    assert!(response.get("state").is_none());
    assert!(response.get("document").is_none());
    assert!(response.get("result").is_none());
    for name in ["submit_kit_entry", "add_entry"] {
        assert!(call(model_call(name, submission(values())))["error"].is_object());
    }
    let request = ok(json!({"operation":"agent_request","today":"2026-10-26",
        "history":[{"role":"user","content":"Let me log reps here"}]}));
    let names: Vec<_> = request["body"]["tools"]
        .as_array()
        .unwrap()
        .iter()
        .map(|tool| tool["name"].as_str().unwrap())
        .collect();
    assert_eq!(
        names,
        [
            "list_kits",
            "read_kit",
            "write_kit",
            "evaluate_kit",
            "save_kit",
            "update_kit",
            "remove_kit",
            "present_component"
        ]
    );
    let instructions = request["body"]["instructions"].as_str().unwrap();
    assert!(instructions.contains("array of {key,value}"));
    assert!(instructions.contains("immediately returns displayed:true"));
    assert!(instructions.contains("handles later user submission privately outside model tools"));

    for (path, value) in [
        ("/type", json!("entry_form")),
        ("/version", json!(2)),
        ("/data/title", json!(" ")),
        ("/data/title", json!("é".repeat(61))),
        ("/data/kitId", json!("Reps")),
        ("/data/kitId", json!(UNKNOWN.to_uppercase())),
        ("/data/prefill", json!({"exercise":"Squat"})),
        ("/data/prefill", json!(null)),
        (
            "/data/prefill",
            json!([{"key":"exercise","value":"Squat"},{"key":"exercise","value":"Press"}]),
        ),
        (
            "/data/prefill",
            json!(
                (0..13)
                    .map(|index| json!({"key":format!("field_{index}"),"value":0}))
                    .collect::<Vec<_>>()
            ),
        ),
        ("/data/prefill/0/key", json!("constructor")),
        ("/data/prefill/0/key", json!("prototype")),
        ("/data/prefill/0/key", json!("__proto__")),
        ("/data/prefill/0/key", json!("Uppercase")),
        ("/data/prefill/0/key", json!("field-key")),
        ("/data/prefill/0/key", json!("1field")),
        ("/data/prefill/0/key", json!("x".repeat(33))),
        ("/data/prefill/0/key", json!("")),
        ("/data/prefill/0/value", json!("🏋".repeat(501))),
        ("/data/prefill/0/value", json!(1_000_000_001)),
        ("/data/prefill/0/value", json!(-1_000_000_001)),
        ("/data/prefill/0/value", json!(true)),
        ("/data/prefill/0/value", json!(null)),
        ("/data/prefill/0/value", json!([])),
        ("/data/prefill/0/value", json!({"code":"save()"})),
        ("/actions", json!([])),
        (
            "/actions",
            json!([{"id":"save_entry","label":"Save"},{"id":"save_entry","label":"Again"}]),
        ),
        ("/actions/0/id", json!("show_source")),
        ("/actions/0/id", json!("open_url")),
        ("/actions/0/label", json!(" ")),
        ("/actions/0/label", json!("é".repeat(41))),
        ("/fallback", json!("")),
        ("/fallback", json!("x".repeat(4001))),
    ] {
        let mut invalid = component.clone();
        *invalid.pointer_mut(path).unwrap() = value;
        assert!(
            call(json!({"operation":"validate_component","component":invalid}))["error"]
                .is_object(),
            "{path}"
        );
        assert!(
            call(model_call(
                "present_component",
                json!({"component":invalid})
            ))["error"]
                .is_object(),
            "{path}"
        );
    }
    for (path, key) in [
        ("", "capabilities"),
        ("/data", "fields"),
        ("/actions/0", "url"),
        ("/data/prefill/0", "code"),
    ] {
        let mut invalid = component.clone();
        invalid
            .pointer_mut(path)
            .unwrap()
            .as_object_mut()
            .unwrap()
            .insert(key.into(), json!("forbidden"));
        assert!(
            call(json!({"operation":"validate_component","component":invalid}))["error"]
                .is_object()
        );
    }
    for prefill in [
        json!([]),
        json!([{"key":"reps","value":-1e9}]),
        json!([{"key":"reps","value":1e9}]),
        json!(
            (0..12)
                .map(|index| json!({"key":format!("field_{index}"),"value":"🏋".repeat(500)}))
                .collect::<Vec<_>>()
        ),
    ] {
        let mut valid = component.clone();
        valid["data"]["prefill"] = prefill;
        valid["data"]["title"] = json!("é".repeat(60));
        valid["actions"][0]["label"] = json!("é".repeat(40));
        valid["fallback"] = json!("x".repeat(4000));
        ok(json!({"operation":"validate_component","component":valid}));
    }
    let mut oversized = component;
    oversized["data"]["prefill"] = json!(
        (0..12)
            .map(|index| json!({"key":format!("field_{index}"),"value":"\0".repeat(500)}))
            .collect::<Vec<_>>()
    );
    assert!(
        call(json!({"operation":"validate_component","component":oversized}))["error"].is_object()
    );
}

#[test]
fn atomic_receipt_and_entry_survive_restart_recovery_and_stale_transcript_refreshes() {
    let (mut vault, kit_id) = installed();
    let archived = vault.archive(card(&kit_id));
    assert!(
        archived["state"]["conversations"][0]["messages"][0]
            .get("entryId")
            .is_none()
    );
    let saved = vault.write("submit_kit_entry", submission(values()));
    let entry_id = saved["result"]["entryId"].as_str().unwrap();
    assert!(crate::crypto::valid_id(entry_id));
    assert_eq!(
        saved["state"]["kits"][0]["entries"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(saved["state"]["kits"][0]["entries"][0]["id"], entry_id);
    assert_eq!(saved["state"]["kits"][0]["entries"][0]["values"], values());
    assert_eq!(
        saved["state"]["conversations"][0]["messages"][0]["entryId"],
        entry_id
    );
    assert_eq!(
        saved["document"]["recordId"],
        archived["document"]["recordId"]
    );
    for secret in [entry_id, "Private squat", "kit_entry", "entryId"] {
        assert!(!vault.document.to_string().contains(secret));
    }
    assert_eq!(vault.state(), saved["state"]);
    let retry_values = json!({"exercise":"Different valid retry","reps":11,"day":"2026-10-27"});
    let retry = vault.write("submit_kit_entry", submission(retry_values));
    assert_eq!(retry, saved);

    let recovery = vault.read("export_recovery", json!({}));
    assert!(!recovery["backup"].to_string().contains(entry_id));
    let recovered = ok(
        json!({"operation":"recover","backup":recovery["backup"],"recoveryKey":recovery["recoveryKey"]}),
    );
    assert_eq!(recovered["state"], saved["state"]);
    let mut restarted = Vault {
        identity: recovered["identity"].clone(),
        document: recovered["document"].clone(),
    };
    assert_eq!(
        restarted.write("submit_kit_entry", submission(values())),
        saved
    );
    restarted.write(
        "profile",
        json!({"profile":{"name":"Nour","goals":["health"],"style":"direct"}}),
    );
    let refreshed = restarted.write(
        "save_conversations",
        json!({"conversations":archived["state"]["conversations"]}),
    );
    assert_eq!(
        refreshed["state"]["conversations"],
        saved["state"]["conversations"]
    );
    let retry = restarted.write("submit_kit_entry", submission(values()));
    assert_eq!(retry["result"]["entryId"], entry_id);
    assert_eq!(retry["document"], refreshed["document"]);
    assert_eq!(
        retry["state"]["kits"][0]["entries"],
        saved["state"]["kits"][0]["entries"]
    );
}

#[test]
fn submissions_require_an_archived_kit_card_installed_schema_and_complete_valid_values() {
    let (mut vault, kit_id) = installed();
    // Even a valid card returned by the model is not authorization to save an
    // invented/unarchived message, and the bridge accepts no caller-supplied card.
    ok(model_call(
        "present_component",
        json!({"component":card(&kit_id)}),
    ));
    vault.reject("submit_kit_entry", submission(values()));
    vault.archive(card(&kit_id));
    for extra in [
        json!({"component":card(&kit_id)}),
        json!({"kitId":kit_id}),
        json!({"entryId":UNKNOWN}),
    ] {
        let mut arguments = submission(values());
        arguments
            .as_object_mut()
            .unwrap()
            .extend(extra.as_object().unwrap().clone());
        vault.reject("submit_kit_entry", arguments);
    }
    for (key, id) in [
        ("conversationId", UNKNOWN),
        ("messageId", UNKNOWN),
        ("messageId", "not-a-uuid"),
    ] {
        let mut arguments = submission(values());
        arguments[key] = json!(id);
        vault.reject("submit_kit_entry", arguments);
    }
    for invalid in [
        Value::Null,
        json!([]),
        json!("values"),
        json!({}),
        json!({"exercise":"Squat","reps":7}),
        json!({"exercise":"Squat","reps":7,"day":"2026-10-26","extra":1}),
        json!({"exercise":"Squat","reps":"7","day":"2026-10-26"}),
        json!({"exercise":"Squat","reps":0,"day":"2026-10-26"}),
        json!({"exercise":"Squat","reps":101,"day":"2026-10-26"}),
        json!({"exercise":"Squat","reps":1e10,"day":"2026-10-26"}),
        json!({"exercise":false,"reps":7,"day":"2026-10-26"}),
        json!({"exercise":" ","reps":7,"day":"2026-10-26"}),
        json!({"exercise":"x".repeat(501),"reps":7,"day":"2026-10-26"}),
        json!({"exercise":"Squat","reps":7,"day":"2026-02-29"}),
    ] {
        vault.reject("submit_kit_entry", submission(invalid));
    }
    for prefill in [
        json!([{"key":"unknown","value":"x"}]),
        json!([{"key":"reps","value":"7"}]),
        json!([{"key":"reps","value":101}]),
        json!([{"key":"day","value":"2026-02-29"}]),
        json!([{"key":"exercise","value":3}]),
        json!([{"key":"exercise","value":" "}]),
    ] {
        let mut invalid = card(&kit_id);
        invalid["data"]["prefill"] = prefill;
        vault.archive(invalid);
        vault.reject("submit_kit_entry", submission(values()));
    }
    vault.archive(card(UNKNOWN));
    vault.reject("submit_kit_entry", submission(values()));
    let table = json!({"type":"result_table","version":1,"data":{"title":"Reps","columns":["Reps"],"rows":[["7"]]},
        "actions":[],"fallback":"7 reps"});
    vault.archive(table);
    vault.reject("submit_kit_entry", submission(values()));
    let mut no_card = transcript(card(&kit_id));
    no_card[0]["messages"][0]
        .as_object_mut()
        .unwrap()
        .remove("component");
    no_card[0]["messages"][0]["kind"] = json!("user");
    vault.write("save_conversations", json!({"conversations":no_card}));
    vault.reject("submit_kit_entry", submission(values()));
    let mut empty_prefill = card(&kit_id);
    empty_prefill["data"]["prefill"] = json!([]);
    vault.archive(empty_prefill);
    let saved = vault.write("submit_kit_entry", submission(values()));
    assert_eq!(
        saved["state"]["kits"][0]["entries"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    vault.reject("submit_kit_entry", submission(json!({})));
    vault.reject(
        "kit_tool",
        json!({"name":"submit_kit_entry","arguments":submission(values()),"today":"2026-10-26"}),
    );
    let review = vault.read(
        "kit_tool",
        json!({"name":"remove_kit","arguments":{"id":kit_id},"today":"2026-10-26"}),
    );
    let removed = vault.write("commit_kit", json!({"review":review["review"]}));
    assert!(removed["state"]["kits"].as_array().unwrap().is_empty());
    assert_eq!(
        vault.state()["conversations"],
        saved["state"]["conversations"]
    );
    vault.reject("submit_kit_entry", submission(values()));
}

#[test]
fn receipt_metadata_is_canonical_card_only_and_cannot_be_forged_or_reassigned() {
    let (mut vault, kit_id) = installed();
    vault.archive(card(&kit_id));
    for receipt in [json!(UNKNOWN), json!("NOT-A-UUID"), json!(7)] {
        let mut conversations = transcript(card(&kit_id));
        conversations[0]["messages"][0]["entryId"] = receipt;
        vault.reject("save_conversations", json!({"conversations":conversations}));
    }
    let saved = vault.write("submit_kit_entry", submission(values()));
    for change in ["receipt", "component", "kind"] {
        let mut conversations = saved["state"]["conversations"].clone();
        let message = &mut conversations[0]["messages"][0];
        match change {
            "receipt" => message["entryId"] = json!(UNKNOWN),
            "component" => message["component"]["data"]["kitId"] = json!(UNKNOWN),
            _ => {
                message["kind"] = json!("user");
                message.as_object_mut().unwrap().remove("component");
            }
        }
        vault.reject("save_conversations", json!({"conversations":conversations}));
    }
    // Authenticated stored snapshots still validate receipt shape on opening,
    // including restore/recovery, independently of the transcript write guard.
    let identity: crate::crypto::Identity = serde_json::from_value(vault.identity.clone()).unwrap();
    let recovery = vault.read("export_recovery", json!({}));
    for change in ["uppercase", "missing", "table", "user", "number"] {
        let mut state = saved["state"].clone();
        let message = &mut state["conversations"][0]["messages"][0];
        match change {
            "uppercase" => message["entryId"] = json!(UNKNOWN.to_uppercase()),
            "missing" => {
                message.as_object_mut().unwrap().remove("component");
            }
            "table" => {
                message["component"] = json!({"type":"result_table","version":1,
                "data":{"title":"Reps","columns":["Reps"],"rows":[]},"actions":[],"fallback":"Reps"})
            }
            "user" => message["kind"] = json!("user"),
            _ => message["entryId"] = json!(7),
        }
        let document = identity
            .seal_document(
                vault.document["recordId"].as_str().unwrap(),
                &serde_json::to_vec(&state).unwrap(),
            )
            .unwrap();
        let mut backup = recovery["backup"].clone();
        backup["document"] = serde_json::to_value(&document).unwrap();
        for command in [
            json!({"operation":"restore","identity":vault.identity,"document":document}),
            json!({"operation":"recover","backup":backup,"recoveryKey":recovery["recoveryKey"]}),
        ] {
            assert!(call(command)["error"].is_object(), "{change}");
        }
    }
    assert_eq!(vault.state(), saved["state"]);
}

#[test]
fn seal_capacity_failure_publishes_neither_entry_nor_receipt_and_can_be_retried() {
    let (mut vault, kit_id) = installed();
    let mut conversations = transcript(card(&kit_id));
    for _ in 0..17 {
        conversations[0]["messages"].as_array_mut().unwrap().push(json!({
            "id":crate::crypto::id().unwrap(),"createdAt":"2026-10-26T12:00:00Z","kind":"user","text":"x".repeat(60 * 1024)}));
    }
    let mut state = vault.state();
    state["conversations"] = conversations;
    let target = 1024 * 1024 - 64;
    let size = serde_json::to_vec(&state).unwrap().len();
    let text = state["conversations"][0]["messages"][1]["text"]
        .as_str()
        .unwrap();
    let length = text.len() + target - size;
    assert!(length <= 64 * 1024);
    state["conversations"][0]["messages"][1]["text"] = json!("x".repeat(length));
    let full = vault.write(
        "save_conversations",
        json!({"conversations":state["conversations"]}),
    );
    assert_eq!(serde_json::to_vec(&full["state"]).unwrap().len(), target);
    vault.reject("submit_kit_entry", submission(values()));
    assert!(
        vault.state()["kits"][0]["entries"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    assert!(
        vault.state()["conversations"][0]["messages"][0]
            .get("entryId")
            .is_none()
    );
    vault.archive(card(&kit_id));
    let saved = vault.write("submit_kit_entry", submission(values()));
    assert_eq!(
        saved["state"]["kits"][0]["entries"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
}

#[test]
fn entry_commit_keeps_durable_sync_pending_and_next_snapshot_contains_the_receipt() {
    let (mut vault, kit_id) = installed();
    vault.archive(card(&kit_id));
    let pending = vault.write("sync_prepare", json!({"origin":ORIGIN}))["pending"].clone();
    let saved = vault.write("submit_kit_entry", submission(values()));
    assert_eq!(
        vault.read("sync_status", json!({"origin":ORIGIN}))["pending"],
        pending
    );
    let retry = vault.write("submit_kit_entry", submission(values()));
    assert_eq!(retry, saved);
    for (sequence, record) in [(1, pending), (2, Value::Null)] {
        let record = if record.is_null() {
            vault.write("sync_prepare", json!({"origin":ORIGIN}))["pending"].clone()
        } else {
            record
        };
        vault.write(
            "sync_complete",
            json!({"origin":ORIGIN,"recordId":record["id"],"sequence":sequence,
            "sha256":record["sha256"],"bytes":record["bytes"]}),
        );
        vault.write(
            "sync_ingest",
            json!({"origin":ORIGIN,"recordId":record["id"],"sequence":sequence,
            "sha256":record["sha256"],"bytes":record["bytes"],"envelope":record["envelope"]}),
        );
        assert_eq!(vault.state(), saved["state"]);
        assert_eq!(
            vault.read("sync_status", json!({"origin":ORIGIN}))["dirty"],
            sequence == 1
        );
    }
    let before = vault.document.clone();
    let retried = vault.write("submit_kit_entry", submission(values()));
    assert_eq!(retried["document"], before);
    assert_eq!(retried["result"], saved["result"]);
}
