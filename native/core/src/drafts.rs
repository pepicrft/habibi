//! A client-encrypted, multi-value register. Vector clocks distinguish a later
//! edit from an offline fork; wall clocks and server arrival order never win.
use std::collections::{BTreeMap, HashSet};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use zeroize::Zeroizing;

use crate::{
    Error, Result,
    conversations::Conversation,
    crypto::{self, Document, Identity},
    kits::State,
};

#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Version {
    pub text: String,
    pub clock: BTreeMap<String, u64>,
}

#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Draft {
    pub id: String,
    pub created_at: String,
    pub versions: Vec<Version>,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Payload {
    version: u32,
    drafts: Vec<Draft>,
}

fn invalid() -> Error {
    Error::invalid("Unsupported or oversized encrypted drafts. All saved versions have been kept.")
}

fn covers(a: &Version, b: &Version) -> bool {
    b.clock
        .iter()
        .all(|(id, count)| a.clock.get(id).unwrap_or(&0) >= count)
}

pub fn validate(drafts: &[Draft]) -> Result<()> {
    let mut ids = HashSet::new();
    if drafts.len() > 128 {
        return Err(invalid());
    }
    for draft in drafts {
        if !crypto::valid_id(&draft.id)
            || !ids.insert(&draft.id)
            || draft.created_at.len() > 40
            || time::OffsetDateTime::parse(
                &draft.created_at,
                &time::format_description::well_known::Rfc3339,
            )
            .is_err()
            || draft.versions.is_empty()
            || draft.versions.len() > 16
        {
            return Err(invalid());
        }
        for (index, version) in draft.versions.iter().enumerate() {
            if version.text.len() > 64 * 1024
                || version.clock.is_empty()
                || version.clock.len() > 32
                || version.clock.iter().any(|(id, count)| {
                    !crypto::valid_id(id) || *count == 0 || *count > 9_007_199_254_740_991
                })
                || draft.versions[..index]
                    .iter()
                    .any(|other| covers(other, version) || covers(version, other))
            {
                return Err(invalid());
            }
        }
    }
    Ok(())
}

// The host supplies a stable, device-local random UUID, not an account or key.
// Editing one branch does not acknowledge/discard its concurrent alternatives.
pub fn capture(
    drafts: &mut Vec<Draft>,
    previous: &[Conversation],
    incoming: &[Conversation],
    device: &str,
) -> Result<()> {
    if !crypto::valid_id(device) {
        return Err(invalid());
    }
    for conversation in incoming {
        let existing = drafts.iter().position(|draft| draft.id == conversation.id);
        if existing.is_none() && conversation.composer.is_empty() {
            continue;
        }
        let index = match existing {
            Some(index) => index,
            None => {
                drafts.push(Draft {
                    id: conversation.id.clone(),
                    created_at: conversation.created_at.clone(),
                    versions: vec![],
                });
                drafts.len() - 1
            }
        };
        let draft = &mut drafts[index];
        let old = previous
            .iter()
            .find(|old| old.id == conversation.id)
            .map(|old| old.composer.as_str());
        if draft.versions.iter().any(|version| {
            version.text == conversation.composer
                && (old == Some(conversation.composer.as_str())
                    || conversation.composer_clock.as_ref() == Some(&version.clock))
        }) {
            continue;
        }
        let mut clock = conversation
            .composer_clock
            .clone()
            .or_else(|| {
                draft
                    .versions
                    .iter()
                    .find(|version| Some(version.text.as_str()) == old)
                    .map(|version| version.clock.clone())
            })
            .unwrap_or_default();
        let count = draft
            .versions
            .iter()
            .filter_map(|version| version.clock.get(device))
            .max()
            .copied()
            .unwrap_or(0);
        clock.insert(device.to_owned(), count.checked_add(1).ok_or_else(invalid)?);
        let version = Version {
            text: conversation.composer.clone(),
            clock,
        };
        draft.versions.retain(|old| !covers(&version, old));
        draft.versions.push(version);
    }
    validate(drafts)
}

pub fn synchronize(
    identity: &Identity,
    document: &Document,
    device: &str,
    envelope: Option<&str>,
) -> Result<Value> {
    let mut state = State::open(identity, document)?;
    let previous = Zeroizing::new(serde_json::to_vec(&state)?);
    capture(
        &mut state.drafts,
        &state.conversations,
        &state.conversations,
        device,
    )?;
    let mut remote_drafts = vec![];
    if let Some(envelope) = envelope {
        let plaintext = identity.open_drafts(envelope)?;
        let payload: Payload = serde_json::from_slice(&plaintext)?;
        if payload.version != 1 {
            return Err(invalid());
        }
        validate(&payload.drafts)?;
        remote_drafts = payload.drafts.clone();
        for remote in payload.drafts {
            if let Some(local) = state.drafts.iter_mut().find(|draft| draft.id == remote.id) {
                if local.created_at != remote.created_at {
                    return Err(invalid());
                }
                for version in remote.versions {
                    if local
                        .versions
                        .iter()
                        .any(|old| old.clock == version.clock && old.text != version.text)
                    {
                        return Err(invalid());
                    }
                    if local.versions.iter().any(|old| covers(old, &version)) {
                        continue;
                    }
                    local.versions.retain(|old| !covers(&version, old));
                    local.versions.push(version);
                }
            } else {
                state.drafts.push(remote);
            }
        }
    }
    state.drafts.sort_by(|a, b| a.id.cmp(&b.id));
    for draft in &mut state.drafts {
        draft.versions.sort_by(|a, b| a.clock.cmp(&b.clock));
        let conversation = match state
            .conversations
            .iter_mut()
            .find(|conversation| conversation.id == draft.id)
        {
            Some(conversation) => conversation,
            None => {
                state.conversations.push(serde_json::from_value(
                    json!({"id":draft.id,"createdAt":draft.created_at,"composer":"","messages":[]}),
                )?);
                state.conversations.last_mut().unwrap()
            }
        };
        if !draft
            .versions
            .iter()
            .any(|version| version.text == conversation.composer)
        {
            conversation.composer = draft.versions.last().ok_or_else(invalid)?.text.clone();
        }
        conversation.composer_clock = draft
            .versions
            .iter()
            .find(|version| version.text == conversation.composer)
            .map(|version| version.clock.clone());
    }
    state.validate()?;
    let payload = Zeroizing::new(serde_json::to_vec(&Payload {
        version: 1,
        drafts: state.drafts.clone(),
    })?);
    let mut result = state.sealed(identity, Some(document))?;
    result["envelope"] = json!(identity.seal_drafts(&payload)?);
    result["upload"] = json!(state.drafts != remote_drafts);
    result["changed"] = json!(*previous != *Zeroizing::new(serde_json::to_vec(&state)?));
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Device {
        identity: Value,
        document: Value,
        id: String,
    }
    impl Device {
        fn call(&mut self, operation: &str, args: Value) -> Value {
            let mut command = args;
            command["operation"] = json!(operation);
            command["identity"] = self.identity.clone();
            command["document"] = self.document.clone();
            command["deviceId"] = json!(self.id);
            // Only draft operations accept deviceId.
            if !["save_conversations", "sync_drafts"].contains(&operation) {
                command.as_object_mut().unwrap().remove("deviceId");
            }
            let result: Value =
                serde_json::from_str(&crate::execute(&command.to_string())).unwrap();
            assert!(result.get("error").is_none(), "{result}");
            let result = result["ok"].clone();
            if !result["document"].is_null() {
                self.document = result["document"].clone();
            }
            result
        }
        fn state(&mut self) -> Value {
            self.call("restore", json!({}))["state"].clone()
        }
        fn edit(&mut self, text: &str) {
            let mut conversations = self.state()["conversations"].clone();
            conversations[0]["composer"] = json!(text);
            self.call("save_conversations", json!({"conversations":conversations}));
        }
        fn sync(&mut self, envelope: Option<&Value>) -> Value {
            self.call("sync_drafts", json!({"envelope":envelope}))
        }
    }

    fn devices() -> (Device, Device) {
        let created: Value = serde_json::from_str(&crate::execute(
            &json!({"operation":"create",
            "profile":{"name":"Noor","goals":["learning"],"style":"warm"}})
            .to_string(),
        ))
        .unwrap();
        let mut a = Device {
            identity: created["ok"]["identity"].clone(),
            document: created["ok"]["document"].clone(),
            id: crypto::id().unwrap(),
        };
        a.call("save_conversations", json!({"conversations":[{"id":crypto::id().unwrap(),"createdAt":"2026-10-27T12:00:00Z","messages":[],"composer":"Start 🏃"}]}));
        let b = Device {
            identity: a.identity.clone(),
            document: a.document.clone(),
            id: crypto::id().unwrap(),
        };
        (a, b)
    }

    #[test]
    fn encrypted_handoff_offline_forks_clears_and_stale_retries_preserve_versions() {
        let (mut a, mut b) = devices();
        a.edit("Phone draft");
        let first = a.sync(None);
        assert!(!first["envelope"].as_str().unwrap().contains("Phone draft"));
        b.sync(Some(&first["envelope"]));
        assert_eq!(b.state()["conversations"][0]["composer"], "Phone draft");
        assert_eq!(b.sync(Some(&first["envelope"]))["upload"], false);
        assert_eq!(b.sync(Some(&first["envelope"]))["changed"], false);

        a.edit("Phone offline");
        b.edit("Tablet offline");
        let phone = a.sync(None);
        let tablet = b.sync(None);
        let merged = a.sync(Some(&tablet["envelope"]));
        b.sync(Some(&merged["envelope"]));
        for device in [&mut a, &mut b] {
            let state = device.state();
            let texts: HashSet<_> = state["drafts"][0]["versions"]
                .as_array()
                .unwrap()
                .iter()
                .map(|v| v["text"].as_str().unwrap())
                .collect();
            assert_eq!(texts, HashSet::from(["Phone offline", "Tablet offline"]));
        }
        assert_eq!(a.state()["conversations"][0]["composer"], "Phone offline");
        assert_eq!(b.state()["conversations"][0]["composer"], "Tablet offline");
        a.edit(""); // Sending/clearing this branch must not erase the other.
        let cleared = a.sync(Some(&tablet["envelope"]));
        b.sync(Some(&cleared["envelope"]));
        let before = b.state()["drafts"].clone();
        b.sync(Some(&phone["envelope"])); // An old retry cannot resurrect sent text.
        assert_eq!(b.state()["drafts"], before);
        assert_eq!(before[0]["versions"].as_array().unwrap().len(), 2);
        assert!(
            before[0]["versions"]
                .as_array()
                .unwrap()
                .iter()
                .any(|v| v["text"] == "Tablet offline")
        );
        b.edit(""); // The other branch may already have an empty marker.
        let both_cleared = b.sync(Some(&cleared["envelope"]));
        a.sync(Some(&both_cleared["envelope"]));
        a.sync(Some(&tablet["envelope"]));
        assert!(
            a.state()["drafts"][0]["versions"]
                .as_array()
                .unwrap()
                .iter()
                .all(|v| v["text"] == "")
        );
    }

    #[test]
    fn typing_while_a_download_is_committed_keeps_its_unseen_base() {
        let (mut a, mut b) = devices();
        let mut typing = b.state()["conversations"].clone();
        typing[0]["composer"] = json!("Typed while merging");
        a.edit("Remote update");
        let remote = a.sync(None);
        b.sync(Some(&remote["envelope"]));
        // The host retains both the in-flight text and the clock the editor saw.
        b.call("save_conversations", json!({"conversations":typing}));
        let merged = b.sync(Some(&remote["envelope"]));
        let state = &merged["state"];
        assert_eq!(state["conversations"][0]["composer"], "Typed while merging");
        let texts: HashSet<_> = state["drafts"][0]["versions"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v["text"].as_str().unwrap())
            .collect();
        assert_eq!(
            texts,
            HashSet::from(["Typed while merging", "Remote update"])
        );
    }

    #[test]
    fn fresh_editing_replicas_preserve_restored_and_selected_branches() {
        let (mut a, _) = devices();
        let backup = a.call("export_recovery", json!({}));
        a.edit("Newer phone draft");
        let newer = a.sync(None);
        let recovered: Value = serde_json::from_str(&crate::execute(
            &json!({"operation":"recover","backup":backup["backup"],"recoveryKey":backup["recoveryKey"]}).to_string(),
        )).unwrap();
        assert!(recovered.get("error").is_none());
        a.document = recovered["ok"]["document"].clone();
        // Recovery starts a fresh replica, even on the same physical device.
        a.id = crypto::id().unwrap();
        a.edit("Edited older backup");
        a.sync(Some(&newer["envelope"]));
        let state = a.state();
        assert_eq!(state["drafts"][0]["versions"].as_array().unwrap().len(), 2);

        // Switching versions starts another branch; subsequent typing must not
        // remove the branch we just left, including its own-device counters.
        a.id = crypto::id().unwrap();
        let mut conversations = state["conversations"].clone();
        conversations[0]["composer"] = json!("Newer phone draft");
        conversations[0]["composerClock"] = state["drafts"][0]["versions"]
            .as_array()
            .unwrap()
            .iter()
            .find(|v| v["text"] == "Newer phone draft")
            .unwrap()["clock"]
            .clone();
        a.call("save_conversations", json!({"conversations":conversations}));
        a.edit("Continued newer draft");
        let merged = a.sync(Some(&newer["envelope"]));
        let texts: HashSet<_> = merged["state"]["drafts"][0]["versions"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v["text"].as_str().unwrap())
            .collect();
        assert_eq!(
            texts,
            HashSet::from(["Edited older backup", "Continued newer draft"])
        );
    }

    #[test]
    fn drafts_are_vault_and_domain_bound_and_create_only_empty_transcript_stubs() {
        let (mut a, mut b) = devices();
        // A device recovered before this conversation existed still sees its draft.
        b.call("save_conversations", json!({"conversations":[]}));
        let remote = a.sync(None);
        b.sync(Some(&remote["envelope"]));
        assert_eq!(b.state()["conversations"][0]["composer"], "Start 🏃");
        assert_eq!(b.state()["conversations"][0]["messages"], json!([]));
        let identity: Identity = serde_json::from_value(a.identity.clone()).unwrap();
        let envelope = remote["envelope"].as_str().unwrap();
        assert!(Identity::create().unwrap().open_drafts(envelope).is_err());
        let mut document: Document = serde_json::from_value(a.document.clone()).unwrap();
        document.envelope = envelope.to_owned();
        assert!(identity.open_document(&document).is_err());
        assert!(identity.open_drafts("invalid").is_err());
        let request = json!({"operation":"sync_drafts","identity":a.identity,"document":a.document,"deviceId":a.id,"envelope":"invalid"});
        let rejected: Value = serde_json::from_str(&crate::execute(&request.to_string())).unwrap();
        assert!(rejected.get("error").is_some());
        assert!(rejected.get("ok").is_none());
    }
}
