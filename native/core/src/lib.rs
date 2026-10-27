mod agent;
mod bridge;
mod components;
mod connections;
mod conversations;
mod crypto;
mod drafts;
mod kit_pages;
mod kits;
mod profile;
mod runtime;
mod sync;

#[cfg(test)]
mod kit_entry_tests;

use crypto::{Document, Identity, RecoveryBundle};
use kits::{Review, State};
use profile::Profile;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

type Result<T> = std::result::Result<T, Error>;

#[derive(Debug, Serialize)]
struct Error {
    kind: &'static str,
    message: String,
}

impl Error {
    fn invalid(message: impl Into<String>) -> Self {
        Self {
            kind: "invalid",
            message: message.into(),
        }
    }
    fn storage(message: impl Into<String>) -> Self {
        Self {
            kind: "storage",
            message: message.into(),
        }
    }
}

impl From<serde_json::Error> for Error {
    fn from(_: serde_json::Error) -> Self {
        Self::invalid("Invalid or unsupported data. Your saved vault has not been changed.")
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Backup {
    version: u32,
    bundle: RecoveryBundle,
    document: Document,
}

#[derive(Deserialize)]
#[serde(tag = "operation", rename_all = "snake_case", deny_unknown_fields)]
enum Command {
    Create {
        profile: Profile,
    },
    BundledKits,
    KitPage {
        id: String,
    },
    ConnectKit {
        identity: Identity,
        document: Document,
        connection: connections::Connection,
    },
    DisconnectKit {
        identity: Identity,
        document: Document,
        id: String,
    },
    ConnectionRequest {
        identity: Identity,
        document: Document,
        id: String,
        name: Option<String>,
        arguments: Option<Value>,
    },
    ConnectionResult {
        name: String,
        response: Value,
    },
    Restore {
        identity: Identity,
        document: Document,
    },
    Profile {
        identity: Identity,
        document: Document,
        profile: Profile,
    },
    SaveConversations {
        identity: Identity,
        document: Document,
        conversations: Vec<conversations::Conversation>,
        #[serde(rename = "deviceId")]
        device_id: Option<String>,
    },
    SyncDrafts {
        identity: Identity,
        document: Document,
        #[serde(rename = "deviceId")]
        device_id: String,
        envelope: Option<String>,
    },
    KitTool {
        identity: Identity,
        document: Document,
        name: String,
        arguments: Value,
        today: String,
    },
    CommitKit {
        identity: Identity,
        document: Document,
        review: Review,
    },
    AddEntry {
        identity: Identity,
        document: Document,
        id: String,
        values: Value,
    },
    SubmitKitEntry {
        identity: Identity,
        document: Document,
        #[serde(rename = "conversationId")]
        conversation_id: String,
        #[serde(rename = "messageId")]
        message_id: String,
        values: Value,
    },
    Summary {
        identity: Identity,
        document: Document,
        id: String,
        today: String,
    },
    ExportRecovery {
        identity: Identity,
        document: Document,
    },
    Recover {
        backup: Backup,
        #[serde(rename = "recoveryKey")]
        recovery_key: String,
    },
    SyncStatus {
        identity: Identity,
        document: Document,
        origin: String,
    },
    SyncPrepare {
        identity: Identity,
        document: Document,
        origin: String,
    },
    SyncIngest {
        identity: Identity,
        document: Document,
        origin: String,
        #[serde(rename = "recordId")]
        record_id: String,
        envelope: String,
        sequence: u64,
        sha256: String,
        bytes: usize,
    },
    SyncComplete {
        identity: Identity,
        document: Document,
        origin: String,
        #[serde(rename = "recordId")]
        record_id: String,
        sequence: u64,
        sha256: String,
        bytes: usize,
    },
    SyncAdopt {
        identity: Identity,
        document: Document,
        origin: String,
        #[serde(rename = "recordId")]
        record_id: String,
        envelope: String,
    },
    SyncResolve {
        identity: Identity,
        document: Document,
        origin: String,
        choice: String,
        #[serde(rename = "recordId")]
        record_id: Option<String>,
        envelope: Option<String>,
    },
    AgentRequest {
        history: Vec<Value>,
        today: String,
        #[serde(default)]
        connections: Vec<String>,
        #[serde(default, rename = "reactionTargets")]
        reaction_targets: Vec<agent::ReactionTarget>,
    },
    AgentResponse {
        response: Value,
    },
    ValidateComponent {
        component: Value,
    },
}

fn dispatch(command: Command) -> Result<Value> {
    match command {
        Command::Create { profile } => {
            let state = State::new(profile)?;
            let identity = Identity::create()?;
            let mut result = state.sealed(&identity, None)?;
            result["identity"] = serde_json::to_value(&identity)?;
            Ok(result)
        }
        Command::BundledKits => Ok(connections::catalog()),
        Command::KitPage { id } => kit_pages::page(&id),
        Command::ConnectKit {
            identity,
            document,
            connection,
        } => {
            connection.validate()?;
            connection.require_current()?;
            let mut state = State::open(&identity, &document)?;
            state
                .connections
                .retain(|item| item.kit_id != connection.kit_id);
            state.connections.push(connection);
            state.sealed(&identity, Some(&document))
        }
        Command::DisconnectKit {
            identity,
            document,
            id,
        } => {
            if id != "github" {
                return Err(Error::invalid("Unknown bundled Kit."));
            }
            let mut state = State::open(&identity, &document)?;
            state.connections.retain(|item| item.kit_id != id);
            state.sealed(&identity, Some(&document))
        }
        Command::ConnectionRequest {
            identity,
            document,
            id,
            name,
            arguments,
        } => {
            let state = State::open(&identity, &document)?;
            state
                .connections
                .iter()
                .find(|item| item.kit_id == id)
                .ok_or_else(|| Error::invalid("Connect this Kit first."))?
                .request(
                    name.as_deref().unwrap_or("github_get_profile"),
                    &arguments.unwrap_or(json!({})),
                )
        }
        Command::ConnectionResult { name, response } => connections::tool_result(&name, response),
        Command::Restore { identity, document } => {
            Ok(json!({"state":State::open(&identity, &document)?}))
        }
        Command::Profile {
            identity,
            document,
            mut profile,
        } => {
            profile.validate()?;
            let mut state = State::open(&identity, &document)?;
            state.profile = profile;
            state.sealed(&identity, Some(&document))
        }
        Command::SaveConversations {
            identity,
            document,
            mut conversations,
            device_id,
        } => {
            conversations::validate(&mut conversations)?;
            let mut state = State::open(&identity, &document)?;
            conversations::preserve_receipts(&state.conversations, &mut conversations)?;
            if let Some(device) = device_id {
                drafts::capture(
                    &mut state.drafts,
                    &state.conversations,
                    &conversations,
                    &device,
                )?;
                for conversation in &mut conversations {
                    conversation.composer_clock = state
                        .drafts
                        .iter()
                        .find(|draft| draft.id == conversation.id)
                        .and_then(|draft| {
                            draft
                                .versions
                                .iter()
                                .find(|version| version.text == conversation.composer)
                        })
                        .map(|version| version.clock.clone());
                }
            }
            state.conversations = conversations;
            state.sealed(&identity, Some(&document))
        }
        Command::SyncDrafts {
            identity,
            document,
            device_id,
            envelope,
        } => drafts::synchronize(&identity, &document, &device_id, envelope.as_deref()),
        Command::KitTool {
            identity,
            document,
            name,
            arguments,
            today,
        } => State::open(&identity, &document)?.tool(&document, &name, arguments, &today),
        Command::CommitKit {
            identity,
            document,
            review,
        } => {
            let mut state = State::open(&identity, &document)?;
            let result = state.commit(&document, review)?;
            let mut saved = state.sealed(&identity, Some(&document))?;
            saved["result"] = result;
            Ok(saved)
        }
        Command::AddEntry {
            identity,
            document,
            id,
            values,
        } => {
            let mut state = State::open(&identity, &document)?;
            state.add_entry(&id, values)?;
            state.sealed(&identity, Some(&document))
        }
        Command::SubmitKitEntry {
            identity,
            document,
            conversation_id,
            message_id,
            values,
        } => {
            let mut state = State::open(&identity, &document)?;
            let (entry_id, changed) =
                state.submit_kit_entry(&conversation_id, &message_id, values)?;
            // One sealed snapshot commits both the entry and its receipt. An
            // idempotent retry returns the exact existing document, without a write.
            let mut saved = if changed {
                state.sealed(&identity, Some(&document))?
            } else {
                json!({"document":document,"state":state})
            };
            saved["result"] = json!({"entryId":entry_id});
            Ok(saved)
        }
        Command::Summary {
            identity,
            document,
            id,
            today,
        } => State::open(&identity, &document)?.summary(&id, &today),
        Command::ExportRecovery { identity, document } => {
            State::open(&identity, &document)?;
            let (bundle, recovery_key) = identity.recovery()?;
            Ok(
                json!({"backup":{"version":1,"bundle":bundle,"document":document},"recoveryKey":recovery_key}),
            )
        }
        Command::Recover {
            backup,
            recovery_key,
        } => {
            if backup.version != 1 {
                return Err(Error::invalid("Unsupported backup version."));
            }
            let identity = Identity::recover(&backup.bundle, &recovery_key)?;
            let state = State::open(&identity, &backup.document)?;
            Ok(json!({"identity":identity,"document":backup.document,"state":state}))
        }
        Command::SyncStatus {
            identity,
            document,
            origin,
        } => sync::status(&identity, &document, &origin),
        Command::SyncPrepare {
            identity,
            document,
            origin,
        } => sync::prepare(&identity, document, &origin),
        Command::SyncIngest {
            identity,
            document,
            origin,
            record_id,
            envelope,
            sequence,
            sha256,
            bytes,
        } => sync::ingest(
            &identity,
            document,
            &origin,
            sync::Incoming {
                reference: sync::Reference {
                    id: record_id,
                    sha256,
                    bytes,
                },
                envelope,
                sequence,
            },
        ),
        Command::SyncComplete {
            identity,
            document,
            origin,
            record_id,
            sequence,
            sha256,
            bytes,
        } => sync::complete(
            &identity,
            document,
            &origin,
            sync::Reference {
                id: record_id,
                sha256,
                bytes,
            },
            sequence,
        ),
        Command::SyncAdopt {
            identity,
            document,
            origin,
            record_id,
            envelope,
        } => sync::adopt(&identity, document, &origin, &record_id, &envelope),
        Command::SyncResolve {
            identity,
            document,
            origin,
            choice,
            record_id,
            envelope,
        } => sync::resolve(
            &identity,
            document,
            &origin,
            &choice,
            record_id.as_deref(),
            envelope.as_deref(),
        ),
        Command::AgentRequest {
            history,
            today,
            connections,
            reaction_targets,
        } => agent::request(history, &today, &connections, reaction_targets),
        Command::AgentResponse { response } => agent::response(response),
        Command::ValidateComponent { component } => {
            Ok(json!({"component":components::validate(component)?}))
        }
    }
}

pub fn execute(input: &str) -> String {
    let result = std::panic::catch_unwind(|| -> Result<Value> {
        // A current local record, durable pending snapshot and incoming remote
        // record can coexist. Guest execution budgets remain unchanged.
        if input.len() > 8 * 1024 * 1024 {
            return Err(Error::invalid("This request is too large."));
        }
        dispatch(serde_json::from_str(input)?)
    })
    .unwrap_or_else(|_| {
        Err(Error::invalid(
            "The operation failed. Your saved data has not been changed.",
        ))
    });
    match result {
        Ok(value) => json!({"ok":value}).to_string(),
        Err(error) => json!({"error":error}).to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call(command: Value) -> Value {
        serde_json::from_str::<Value>(&execute(&command.to_string())).unwrap()
    }

    #[test]
    fn onboarding_restore_and_separate_recovery_artifacts_use_the_public_bridge() {
        let profile = json!({"name":" Noor ","goals":["health","planning"],"style":"warm"});
        let created = call(json!({"operation":"create","profile":profile}));
        assert_eq!(created["ok"]["state"]["profile"]["name"], "Noor");
        assert_eq!(
            created["ok"]["state"]["profile"],
            json!({"name":"Noor","goals":["health","planning"],"style":"warm"})
        );
        assert!(!created["ok"]["document"].to_string().contains("Noor"));
        let identity = &created["ok"]["identity"];
        let document = &created["ok"]["document"];
        let restored = call(json!({"operation":"restore","identity":identity,"document":document}));
        assert_eq!(restored["ok"]["state"], created["ok"]["state"]);
        let recovery =
            call(json!({"operation":"export_recovery","identity":identity,"document":document}));
        assert!(
            !recovery["ok"]["backup"]
                .to_string()
                .contains(identity["key"].as_str().unwrap())
        );
        let recovered = call(
            json!({"operation":"recover","backup":recovery["ok"]["backup"],"recoveryKey":recovery["ok"]["recoveryKey"]}),
        );
        assert_eq!(recovered["ok"]["state"], created["ok"]["state"]);
        assert_eq!(&recovered["ok"]["identity"], identity);
        assert!(call(json!({"operation":"create","profile":{"name":"","goals":[],"style":"warm"}}))["error"].is_object());
    }

    #[test]
    fn theme_preferences_round_trip_with_encrypted_profile_conversations_and_recovery() {
        let mut profile = json!({"name":"Noor","goals":["health"],"style":"warm",
            "theme":"future-catalog-v3","appearance":"system"});
        let created = call(json!({"operation":"create","profile":profile}));
        assert_eq!(created["ok"]["state"]["profile"], profile);
        let identity = &created["ok"]["identity"];
        let mut document = created["ok"]["document"].clone();
        for (theme, appearance) in [
            (json!("a"), json!("system")),
            (json!("a".repeat(40)), json!("light")),
            (json!("future--catalog-v3-"), json!("dark")),
            (Value::Null, json!("dark")),
            (json!("future-catalog-v3"), Value::Null),
            (Value::Null, Value::Null),
        ] {
            profile["theme"] = theme;
            profile["appearance"] = appearance;
            let saved = call(json!({"operation":"profile","identity":identity,
                "document":document,"profile":profile}));
            let mut expected = profile.clone();
            expected
                .as_object_mut()
                .unwrap()
                .retain(|_, value| !value.is_null());
            assert_eq!(saved["ok"]["state"]["profile"], expected);
            let conversations = call(json!({"operation":"save_conversations","identity":identity,
                "document":saved["ok"]["document"],"conversations":transcript()}));
            assert_eq!(conversations["ok"]["state"]["profile"], expected);
            document = conversations["ok"]["document"].clone();
            assert_eq!(document["recordId"], created["ok"]["document"]["recordId"]);
            assert!(document.get("theme").is_none());
            assert!(document.get("appearance").is_none());
            assert!(!document.to_string().contains("future-catalog"));
            let restored =
                call(json!({"operation":"restore","identity":identity,"document":document}));
            assert_eq!(restored["ok"]["state"]["profile"], expected);
            assert_eq!(restored["ok"]["state"]["conversations"], transcript());
            let recovery = call(
                json!({"operation":"export_recovery","identity":identity,"document":document}),
            );
            assert!(
                !recovery["ok"]["backup"]
                    .to_string()
                    .contains("future-catalog")
            );
            let recovered = call(
                json!({"operation":"recover","backup":recovery["ok"]["backup"],
                "recoveryKey":recovery["ok"]["recoveryKey"]}),
            );
            assert_eq!(recovered["ok"]["state"], restored["ok"]["state"]);
        }
        // The ordinary profile operation remains a replacement, not a patch:
        // old clients can still save profiles with both preferences absent.
        profile.as_object_mut().unwrap().remove("theme");
        profile.as_object_mut().unwrap().remove("appearance");
        let saved = call(json!({"operation":"profile","identity":identity,
            "document":document,"profile":profile}));
        assert_eq!(saved["ok"]["state"]["profile"], profile);
        assert_eq!(saved["ok"]["state"]["conversations"], transcript());
    }

    #[test]
    fn invalid_theme_preferences_fail_create_save_restore_and_recovery_without_vault_changes() {
        let profile = json!({"name":"Noor","goals":["health"],"style":"warm",
            "theme":"future-catalog-v3","appearance":"dark"});
        let created = call(json!({"operation":"create","profile":profile}));
        let identity = &created["ok"]["identity"];
        let document = &created["ok"]["document"];
        let native_identity: Identity = serde_json::from_value(identity.clone()).unwrap();
        let recovery =
            call(json!({"operation":"export_recovery","identity":identity,"document":document}));
        for (field, value) in [
            ("theme", json!("")),
            ("theme", json!("a".repeat(41))),
            ("theme", json!("Uppercase")),
            ("theme", json!("lowerCase")),
            ("theme", json!("1theme")),
            ("theme", json!("-theme")),
            ("theme", json!("theme_name")),
            ("theme", json!("theme.name")),
            ("theme", json!("../theme")),
            ("theme", json!(" theme")),
            ("theme", json!("theme ")),
            ("theme", json!("theme\n")),
            ("theme", json!("thème")),
            ("theme", json!(7)),
            ("appearance", json!("")),
            ("appearance", json!("auto")),
            ("appearance", json!("Dark")),
            ("appearance", json!(" dark")),
            ("appearance", json!("dark ")),
            ("appearance", json!("dark\n")),
            ("appearance", json!(false)),
        ] {
            let mut invalid = profile.clone();
            invalid[field] = value.clone();
            for command in [
                json!({"operation":"create","profile":invalid}),
                json!({"operation":"profile","identity":identity,"document":document,"profile":invalid}),
            ] {
                let result = call(command);
                assert_eq!(
                    result["error"]["kind"], "invalid",
                    "{field}: {value}: {result}"
                );
                assert!(result.get("ok").is_none());
            }
            // Authenticated old or remote data still goes through validation.
            let mut state = created["ok"]["state"].clone();
            state["profile"] = invalid;
            let malformed = native_identity
                .seal_document(
                    document["recordId"].as_str().unwrap(),
                    &serde_json::to_vec(&state).unwrap(),
                )
                .unwrap();
            let mut backup = recovery["ok"]["backup"].clone();
            backup["document"] = serde_json::to_value(&malformed).unwrap();
            for command in [
                json!({"operation":"restore","identity":identity,"document":malformed}),
                json!({"operation":"recover","backup":backup,"recoveryKey":recovery["ok"]["recoveryKey"]}),
            ] {
                let result = call(command);
                assert_eq!(
                    result["error"]["kind"], "invalid",
                    "{field}: {value}: {result}"
                );
                assert!(result.get("ok").is_none());
            }
        }
        let restored = call(json!({"operation":"restore","identity":identity,"document":document}));
        assert_eq!(restored["ok"]["state"], created["ok"]["state"]);
    }

    fn transcript() -> Value {
        json!([{"id":"7b9efe67-c157-44d2-b5eb-d78057dc6e22","createdAt":"2026-10-26T13:01:02.123456789Z",
        "composer":"Tomorrow: caminata 🏃🏽‍♀️","messages":[
            {"id":"1fdce3f4-e43b-4690-a8cf-d963e65a0059","createdAt":"2026-10-26T13:01:02Z","kind":"user","text":"Private walking journal","reaction":"👍"},
            {"id":"c087bd67-efca-493b-8abc-34245d7ca8a4","createdAt":"2026-10-26T13:01:03Z","kind":"tool","text":"evaluate_kit finished","detail":"{\"synthetic\":true}"},
            {"id":"326c2270-a709-46a4-a3b5-5fecb59a7cc6","createdAt":"2026-10-26T13:01:04Z","kind":"assistant","text":"Tuesday: 25 minutes",
             "component":{"type":"result_table","version":1,"data":{"title":"Walking plan","columns":["Day","Minutes"],"rows":[["Tuesday","25"]]},"actions":[{"id":"show_source","label":"View data"}],"fallback":"Tuesday: 25 minutes"}}
        ]}])
    }

    #[test]
    fn conversations_are_encrypted_recoverable_and_preserved_by_other_vault_writes() {
        let created = call(
            json!({"operation":"create","profile":{"name":"Noor","goals":["health"],"style":"warm"}}),
        );
        let identity = &created["ok"]["identity"];
        let legacy = &created["ok"]["document"];
        assert!(created["ok"]["state"].get("conversations").is_none());
        assert!(
            call(json!({"operation":"restore","identity":identity,"document":legacy}))["ok"]
                .is_object()
        );
        let definition = json!({"apiVersion":1,"name":"Walks","description":"Track walking minutes.","fields":[{"key":"minutes","label":"Minutes","type":"number","unit":"min","min":0.5,"max":600.5}],"source":"function summarize(s){return JSON.stringify({metrics:[]})}"});
        let review = call(
            json!({"operation":"kit_tool","identity":identity,"document":legacy,"name":"save_kit","arguments":{"definition":definition},"today":"2026-10-26"}),
        );
        let installed = call(
            json!({"operation":"commit_kit","identity":identity,"document":legacy,"review":review["ok"]["review"]}),
        );
        let mut conversations = transcript();
        conversations[0]["draft"] = definition;
        conversations.as_array_mut().unwrap().push(json!({"id":"3aad16ab-0c87-4119-95ca-f67006bb3938","createdAt":"2026-10-26T15:00:00Z","messages":[],"composer":"Independent draft"}));
        let saved = call(
            json!({"operation":"save_conversations","identity":identity,"document":installed["ok"]["document"],"conversations":conversations}),
        );
        assert_eq!(saved["ok"]["state"]["conversations"], conversations);
        assert_eq!(
            saved["ok"]["state"]["kits"],
            installed["ok"]["state"]["kits"]
        );
        assert!(
            !saved["ok"]["document"]
                .to_string()
                .contains("Private walking journal")
        );
        assert_eq!(saved["ok"]["document"]["recordId"], legacy["recordId"]);
        let changed = call(
            json!({"operation":"profile","identity":identity,"document":saved["ok"]["document"],"profile":{"name":"Nour","goals":["learning"],"style":"direct"}}),
        );
        let restored = call(
            json!({"operation":"restore","identity":identity,"document":changed["ok"]["document"]}),
        );
        assert_eq!(restored["ok"]["state"]["conversations"], conversations);
        assert_eq!(restored["ok"]["state"]["profile"]["name"], "Nour");
        let recovery = call(
            json!({"operation":"export_recovery","identity":identity,"document":changed["ok"]["document"]}),
        );
        assert!(!recovery["ok"]["backup"].to_string().contains("caminata"));
        let recovered = call(
            json!({"operation":"recover","backup":recovery["ok"]["backup"],"recoveryKey":recovery["ok"]["recoveryKey"]}),
        );
        assert_eq!(recovered["ok"]["state"], restored["ok"]["state"]);
    }

    #[test]
    fn invalid_or_overfull_conversations_fail_without_replacing_the_saved_vault() {
        let created = call(
            json!({"operation":"create","profile":{"name":"Noor","goals":["health"],"style":"warm"}}),
        );
        let identity = &created["ok"]["identity"];
        let saved = call(
            json!({"operation":"save_conversations","identity":identity,"document":created["ok"]["document"],"conversations":transcript()}),
        );
        let document = &saved["ok"]["document"];
        for (path, value) in [
            (
                "/0/history",
                json!([{"type":"function_call","name":"save_kit"}]),
            ),
            ("/0/approval", json!({"approved":true})),
            ("/0/createdAt", json!("not a date")),
            ("/0/messages/0/kind", json!("system")),
            ("/0/messages/0/kind", json!("assistant")),
            ("/0/messages/0/kind", json!("tool")),
            ("/0/messages/0/reaction", json!("not an emoji")),
            ("/0/messages/2/component/actions/0/id", json!("delete")),
        ] {
            let mut invalid = transcript();
            if path == "/0/history" {
                invalid[0]["history"] = value;
            } else if path == "/0/approval" {
                invalid[0]["approval"] = value;
            } else {
                *invalid.pointer_mut(path).unwrap() = value;
            }
            assert!(call(json!({"operation":"save_conversations","identity":identity,"document":document,"conversations":invalid}))["error"].is_object(), "{path}");
        }
        let mut full = transcript();
        full[0]["messages"] = json!((0..18).map(|_| json!({"id":crypto::id().unwrap(),"createdAt":"2026-10-26T00:00:00Z","kind":"assistant","text":"x".repeat(60 * 1024)})).collect::<Vec<_>>());
        assert!(call(json!({"operation":"save_conversations","identity":identity,"document":document,"conversations":full}))["error"].is_object());
        let other = call(
            json!({"operation":"create","profile":{"name":"Other","goals":["health"],"style":"warm"}}),
        );
        assert!(call(json!({"operation":"restore","identity":other["ok"]["identity"],"document":document}))["error"].is_object());
        let restored = call(json!({"operation":"restore","identity":identity,"document":document}));
        assert_eq!(restored["ok"]["state"]["conversations"], transcript());
    }
}
