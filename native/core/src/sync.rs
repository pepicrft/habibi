//! Host-only, immutable full-state snapshots. The server sees HAB1 ciphertext
//! and its existing record metadata, never the local document or content key.
//!
//! Persist each returned document before the next action. Retry pending PUTs
//! before scanning; ingest every sequence (including our own PUT) and drain
//! pages before preparing/adopting/resolving. An empty/truncated server response
//! is not proof of freshness: this protocol does not provide anti-rollback.
use std::collections::HashSet;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use zeroize::Zeroizing;

use crate::{
    Error, Result,
    crypto::{self, Document, Identity},
    kits::State,
};

const MAX_BYTES: usize = 1024 * 1024;
const MAX_HEADS: usize = 128;
// Matches the server's record quota. Retaining IDs detects duplicate IDs and
// forward/unknown parents without keeping old ciphertext or plaintext.
const MAX_RECORDS: usize = 10_000;

#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub(crate) struct Reference {
    pub id: String,
    pub sha256: String,
    pub bytes: usize,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Pending {
    id: String,
    envelope: String,
    sha256: String,
    bytes: usize,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Base {
    id: String,
    state_sha256: String,
    sequence: u64,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Metadata {
    version: u32,
    origin: String,
    cursor: u64,
    heads: Vec<Reference>,
    seen: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    base: Option<Base>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pending: Option<Pending>,
    // Local-only keyed digest, not an anti-rollback counter.
    authentication: String,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Snapshot<S = State> {
    version: u32,
    kind: String,
    parents: Vec<String>,
    state: S,
}

pub(crate) struct Incoming {
    pub reference: Reference,
    pub envelope: String,
    pub sequence: u64,
}

fn invalid() -> Error {
    Error::invalid("Invalid or unsupported sync data. Your saved vault has not been changed.")
}

fn digest(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn valid_digest(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn fingerprint(state: &State) -> Result<String> {
    // Typed field order, sorted JSON object keys and the validated State's
    // optional-field rules are shared by every native host.
    Ok(digest(&Zeroizing::new(serde_json::to_vec(state)?)))
}

fn valid_reference(reference: &Reference) -> bool {
    crypto::valid_id(&reference.id)
        && valid_digest(&reference.sha256)
        && (64..=MAX_BYTES).contains(&reference.bytes)
}

fn reference(id: &str, envelope: &str) -> Result<Reference> {
    if !crypto::valid_id(id) || envelope.len() > MAX_BYTES.div_ceil(3) * 4 {
        return Err(invalid());
    }
    let bytes = crypto::decode(envelope)?;
    if !(64..=MAX_BYTES).contains(&bytes.len()) || &bytes[..4] != b"HAB1" {
        return Err(invalid());
    }
    Ok(Reference {
        id: id.to_owned(),
        sha256: digest(&bytes),
        bytes: bytes.len(),
    })
}

// Deliberately narrower than a browser URL parser: no userinfo, path
// normalization, escaped authorities, query, fragment, implicit HTTP or IDNA.
fn canonical_origin(input: &str) -> Result<String> {
    if input.len() > 2048 || !input.is_ascii() || input.bytes().any(|b| b.is_ascii_whitespace()) {
        return Err(invalid());
    }
    let (scheme, authority) = input.split_once("://").ok_or_else(invalid)?;
    if !["https", "http"].contains(&scheme) {
        return Err(invalid());
    }
    let authority = authority.strip_suffix('/').unwrap_or(authority);
    if authority.is_empty() || authority.contains(['/', '?', '#', '@', '%', '\\']) {
        return Err(invalid());
    }
    let (host, port) = if let Some(ipv6) = authority.strip_prefix('[') {
        let (address, suffix) = ipv6.split_once(']').ok_or_else(invalid)?;
        let address = address
            .parse::<std::net::Ipv6Addr>()
            .map_err(|_| invalid())?;
        let port = if suffix.is_empty() {
            None
        } else {
            Some(suffix.strip_prefix(':').ok_or_else(invalid)?)
        };
        (format!("[{address}]"), port)
    } else {
        let (host, port) = match authority.split_once(':') {
            Some((host, port)) => (host, Some(port)),
            None => (authority, None),
        };
        if host.len() > 253
            || host.split('.').any(|label| {
                label.is_empty()
                    || label.len() > 63
                    || !label.as_bytes()[0].is_ascii_alphanumeric()
                    || !label.as_bytes()[label.len() - 1].is_ascii_alphanumeric()
                    || !label
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b == b'-')
            })
        {
            return Err(invalid());
        }
        if host.bytes().all(|b| b.is_ascii_digit() || b == b'.')
            && host.parse::<std::net::Ipv4Addr>().is_err()
        {
            return Err(invalid());
        }
        (host.to_ascii_lowercase(), port)
    };
    if scheme == "http" && !["localhost", "127.0.0.1", "10.0.2.2"].contains(&host.as_str()) {
        return Err(invalid());
    }
    let port = port
        .map(|value| {
            if value.is_empty() || !value.bytes().all(|b| b.is_ascii_digit()) {
                return Err(invalid());
            }
            value
                .parse::<u16>()
                .ok()
                .filter(|p| *p != 0)
                .ok_or_else(invalid)
        })
        .transpose()?;
    let suffix = match port {
        Some(443) if scheme == "https" => String::new(),
        Some(80) if scheme == "http" => String::new(),
        Some(port) => format!(":{port}"),
        None => String::new(),
    };
    Ok(format!("{scheme}://{host}{suffix}"))
}

fn open_snapshot(identity: &Identity, id: &str, envelope: &str) -> Result<Snapshot> {
    reference(id, envelope)?;
    let document = Document {
        version: 1,
        vault_id: identity.vault_id.clone(),
        record_id: id.to_owned(),
        envelope: envelope.to_owned(),
        sync: None,
    };
    let plaintext = identity.open_document(&document)?;
    let mut snapshot: Snapshot = serde_json::from_slice(&plaintext)?;
    if snapshot.version != 1
        || snapshot.kind != "habibi.snapshot"
        || snapshot.parents.len() > MAX_HEADS
    {
        return Err(invalid());
    }
    let mut parents = HashSet::new();
    for parent in &snapshot.parents {
        if parent == id || !crypto::valid_id(parent) || !parents.insert(parent) {
            return Err(invalid());
        }
    }
    snapshot.state.validate()?;
    Ok(snapshot)
}

fn tag(identity: &Identity, document: &Document, metadata: &Metadata) -> Result<String> {
    let mut unsigned = metadata.clone();
    unsigned.authentication.clear();
    identity.sync_tag(&serde_json::to_vec(&json!({
        "version":document.version,"vaultId":document.vault_id,"recordId":document.record_id,
        "envelopeSha256":digest(document.envelope.as_bytes()),"sync":unsigned
    }))?)
}

pub(crate) fn attach(
    identity: &Identity,
    document: &mut Document,
    metadata: Option<Metadata>,
) -> Result<()> {
    document.sync = metadata;
    if let Some(metadata) = &document.sync {
        let authentication = tag(identity, document, metadata)?;
        document.sync.as_mut().unwrap().authentication = authentication;
    }
    Ok(())
}

pub(crate) fn validate(identity: &Identity, document: &Document) -> Result<()> {
    let Some(metadata) = &document.sync else {
        return Ok(());
    };
    let expected = tag(identity, document, metadata)?;
    let supplied = &metadata.authentication;
    if expected.len() != supplied.len()
        || expected
            .bytes()
            .zip(supplied.bytes())
            .fold(0, |diff, (a, b)| diff | (a ^ b))
            != 0
        || metadata.version != 1
        || canonical_origin(&metadata.origin)? != metadata.origin
        || metadata.cursor > MAX_RECORDS as u64
        || metadata.seen.len() != metadata.cursor as usize
        || metadata.heads.len() > MAX_HEADS
    {
        return Err(invalid());
    }
    let mut seen = HashSet::new();
    for id in &metadata.seen {
        if !crypto::valid_id(id) || id == &document.record_id || !seen.insert(id) {
            return Err(invalid());
        }
    }
    if let Some(base) = &metadata.base
        && (!crypto::valid_id(&base.id)
            || base.id == document.record_id
            || !valid_digest(&base.state_sha256)
            || base.sequence == 0
            || base.sequence > MAX_RECORDS as u64
            || (base.sequence <= metadata.cursor
                && metadata.seen[base.sequence as usize - 1] != base.id))
    {
        return Err(invalid());
    }
    let mut heads = HashSet::new();
    for head in &metadata.heads {
        if !valid_reference(head)
            || head.id == document.record_id
            || !heads.insert(&head.id)
            || (!seen.contains(&head.id)
                && !metadata
                    .base
                    .as_ref()
                    .is_some_and(|base| base.id == head.id && base.sequence > metadata.cursor))
        {
            return Err(invalid());
        }
    }
    if metadata.cursor > 0 && metadata.heads.is_empty() {
        return Err(invalid());
    }
    if let Some(pending) = &metadata.pending {
        if pending.id == document.record_id
            || seen.contains(&pending.id)
            || heads.contains(&pending.id)
        {
            return Err(invalid());
        }
        let actual = reference(&pending.id, &pending.envelope)?;
        if actual.sha256 != pending.sha256 || actual.bytes != pending.bytes {
            return Err(invalid());
        }
        let snapshot = open_snapshot(identity, &pending.id, &pending.envelope)?;
        let parents = snapshot.parents.iter().collect::<HashSet<_>>();
        if parents != heads {
            return Err(invalid());
        }
    }
    Ok(())
}

fn context(identity: &Identity, document: &Document, origin: &str) -> Result<(State, Metadata)> {
    let state = State::open(identity, document)?;
    let origin = canonical_origin(origin)?;
    let mut metadata = document.sync.clone().unwrap_or_else(|| Metadata {
        version: 1,
        origin: origin.clone(),
        cursor: 0,
        heads: vec![],
        seen: vec![],
        base: None,
        pending: None,
        authentication: String::new(),
    });
    if metadata.origin != origin {
        if metadata.cursor != 0
            || !metadata.heads.is_empty()
            || metadata.base.is_some()
            || metadata.pending.is_some()
        {
            return Err(Error::invalid(
                "This vault's sync progress belongs to a different server origin.",
            ));
        }
        metadata.origin = origin;
    }
    Ok((state, metadata))
}

fn dirty(state: &State, metadata: &Metadata) -> Result<bool> {
    Ok(match &metadata.base {
        Some(base) => fingerprint(state)? != base.state_sha256,
        None => true,
    })
}

fn conflict(dirty: bool, metadata: &Metadata) -> bool {
    metadata.heads.len() > 1
        || (dirty
            && metadata
                .heads
                .first()
                .is_some_and(|head| metadata.base.as_ref().is_none_or(|base| base.id != head.id)))
}

fn output(identity: &Identity, state: &State, metadata: &Metadata) -> Result<Value> {
    let dirty = dirty(state, metadata)?;
    let mut result = json!({"vaultId":identity.vault_id,"token":identity.token,
        "cursor":metadata.cursor,"heads":metadata.heads,"dirty":dirty,"conflict":conflict(dirty, metadata)});
    if let Some(pending) = &metadata.pending {
        result["pending"] = serde_json::to_value(pending)?;
    }
    Ok(result)
}

fn publish(
    identity: &Identity,
    mut document: Document,
    state: &State,
    metadata: Metadata,
    include_state: bool,
) -> Result<Value> {
    attach(identity, &mut document, Some(metadata.clone()))?;
    // All outputs obey the same metadata invariants as the next bridge input.
    validate(identity, &document)?;
    let mut result = output(identity, state, &metadata)?;
    result["document"] = serde_json::to_value(document)?;
    if include_state {
        result["state"] = serde_json::to_value(state)?;
    }
    Ok(result)
}

pub(crate) fn status(identity: &Identity, document: &Document, origin: &str) -> Result<Value> {
    let (state, metadata) = context(identity, document, origin)?;
    output(identity, &state, &metadata)
}

fn prepare_snapshot(identity: &Identity, state: &State, metadata: &mut Metadata) -> Result<()> {
    let snapshot = Snapshot {
        version: 1,
        kind: "habibi.snapshot".to_owned(),
        parents: metadata.heads.iter().map(|head| head.id.clone()).collect(),
        state,
    };
    let plaintext = Zeroizing::new(serde_json::to_vec(&snapshot)?);
    // HAB1 and the server retain the existing 1 MiB limit. Full state plus
    // ancestry must fit; never truncate conversations, Kits or parent heads.
    let sealed = identity.seal_document(&crypto::id()?, &plaintext)?;
    let reference = reference(&sealed.record_id, &sealed.envelope)?;
    metadata.pending = Some(Pending {
        id: reference.id,
        envelope: sealed.envelope,
        sha256: reference.sha256,
        bytes: reference.bytes,
    });
    Ok(())
}

pub(crate) fn prepare(identity: &Identity, document: Document, origin: &str) -> Result<Value> {
    let (state, mut metadata) = context(identity, &document, origin)?;
    // A resolution's pending envelope is already host-confirmed, even while
    // multiple scanned heads remain. Retrying must never regenerate it.
    if metadata.pending.is_none() {
        let changed = dirty(&state, &metadata)?;
        if conflict(changed, &metadata) {
            return Err(Error::invalid(
                "Resolve the sync conflict before preparing another snapshot.",
            ));
        }
        if changed {
            if metadata.cursor >= MAX_RECORDS as u64 {
                return Err(Error::invalid(
                    "This vault has reached its sync record limit.",
                ));
            }
            prepare_snapshot(identity, &state, &mut metadata)?;
        }
    }
    publish(identity, document, &state, metadata, false)
}

pub(crate) fn ingest(
    identity: &Identity,
    document: Document,
    origin: &str,
    incoming: Incoming,
) -> Result<Value> {
    let (state, mut metadata) = context(identity, &document, origin)?;
    if metadata.pending.is_some() {
        return Err(Error::invalid(
            "Retry the durable pending upload before scanning remote records.",
        ));
    }
    let Incoming {
        reference: supplied,
        envelope,
        sequence,
    } = incoming;
    if sequence != metadata.cursor + 1
        || sequence > MAX_RECORDS as u64
        || !valid_reference(&supplied)
        || supplied.id == document.record_id
        || metadata.seen.contains(&supplied.id)
        || reference(&supplied.id, &envelope)? != supplied
    {
        return Err(invalid());
    }
    let snapshot = open_snapshot(identity, &supplied.id, &envelope)?;
    if snapshot
        .parents
        .iter()
        .any(|id| !metadata.seen.contains(id))
    {
        return Err(Error::invalid(
            "A snapshot references unscanned parents. Sync cannot skip records.",
        ));
    }
    if let Some(existing) = metadata.heads.iter().find(|head| head.id == supplied.id)
        && (existing != &supplied
            || !metadata
                .base
                .as_ref()
                .is_some_and(|base| base.id == supplied.id && base.sequence == sequence))
    {
        return Err(invalid());
    }
    metadata
        .heads
        .retain(|head| !snapshot.parents.contains(&head.id) && head.id != supplied.id);
    if metadata.heads.len() >= MAX_HEADS {
        return Err(Error::invalid(
            "Too many independent sync heads. No branches have been discarded.",
        ));
    }
    metadata.heads.push(supplied.clone());
    metadata.heads.sort_by(|a, b| a.id.cmp(&b.id));
    metadata.seen.push(supplied.id);
    metadata.cursor = sequence;
    // Scanning authenticates lineage only; the local state is never adopted.
    publish(identity, document, &state, metadata, false)
}

pub(crate) fn complete(
    identity: &Identity,
    document: Document,
    origin: &str,
    supplied: Reference,
    sequence: u64,
) -> Result<Value> {
    let (state, mut metadata) = context(identity, &document, origin)?;
    let pending = metadata
        .pending
        .as_ref()
        .ok_or_else(|| Error::invalid("There is no pending sync upload to acknowledge."))?;
    if supplied.id != pending.id
        || supplied.sha256 != pending.sha256
        || supplied.bytes != pending.bytes
        || sequence <= metadata.cursor
        || sequence > MAX_RECORDS as u64
    {
        return Err(invalid());
    }
    let snapshot = open_snapshot(identity, &pending.id, &pending.envelope)?;
    metadata.base = Some(Base {
        id: supplied.id.clone(),
        state_sha256: fingerprint(&snapshot.state)?,
        sequence,
    });
    metadata
        .heads
        .retain(|head| !snapshot.parents.contains(&head.id));
    metadata.heads.push(supplied);
    metadata.heads.sort_by(|a, b| a.id.cmp(&b.id));
    metadata.pending = None;
    // Never skip records that other devices appended before our PUT, and never
    // mark edits made after prepare as uploaded.
    publish(identity, document, &state, metadata, false)
}

fn selected(
    identity: &Identity,
    metadata: &Metadata,
    id: &str,
    envelope: &str,
) -> Result<Snapshot> {
    let head = metadata
        .heads
        .iter()
        .find(|head| head.id == id)
        .ok_or_else(|| Error::invalid("The selected snapshot is not a known remote head."))?;
    if reference(id, envelope)? != *head {
        return Err(invalid());
    }
    open_snapshot(identity, id, envelope)
}

pub(crate) fn adopt(
    identity: &Identity,
    document: Document,
    origin: &str,
    id: &str,
    envelope: &str,
) -> Result<Value> {
    let (state, mut metadata) = context(identity, &document, origin)?;
    if metadata.pending.is_some() || metadata.heads.len() != 1 || dirty(&state, &metadata)? {
        return Err(Error::invalid(
            "Remote adoption requires one head, a clean local vault and no pending upload.",
        ));
    }
    let snapshot = selected(identity, &metadata, id, envelope)?;
    let sequence = metadata
        .seen
        .iter()
        .position(|seen| seen == id)
        .map(|n| n as u64 + 1)
        .ok_or_else(invalid)?;
    metadata.base = Some(Base {
        id: id.to_owned(),
        state_sha256: fingerprint(&snapshot.state)?,
        sequence,
    });
    let sealed: Document = serde_json::from_value(
        snapshot.state.sealed(identity, Some(&document))?["document"].clone(),
    )?;
    publish(identity, sealed, &snapshot.state, metadata, true)
}

pub(crate) fn resolve(
    identity: &Identity,
    document: Document,
    origin: &str,
    choice: &str,
    id: Option<&str>,
    envelope: Option<&str>,
) -> Result<Value> {
    let (local, mut metadata) = context(identity, &document, origin)?;
    if metadata.pending.is_some() {
        return Err(Error::invalid(
            "Retry the durable pending upload before resolving a conflict.",
        ));
    }
    if !conflict(dirty(&local, &metadata)?, &metadata) || metadata.cursor >= MAX_RECORDS as u64 {
        return Err(Error::invalid(
            "There is no resolvable sync conflict, or the sync record limit has been reached.",
        ));
    }
    let state = match choice {
        "local" if id.is_none() && envelope.is_none() => local,
        "remote" => {
            selected(
                identity,
                &metadata,
                id.ok_or_else(invalid)?,
                envelope.ok_or_else(invalid)?,
            )?
            .state
        }
        _ => return Err(invalid()),
    };
    let sealed = if choice == "remote" {
        serde_json::from_value(state.sealed(identity, Some(&document))?["document"].clone())?
    } else {
        document
    };
    prepare_snapshot(identity, &state, &mut metadata)?;
    publish(identity, sealed, &state, metadata, true)
}

#[cfg(test)]
mod tests {
    use super::*;

    const ORIGIN: &str = "https://sync.example.com";

    fn call(command: Value) -> Value {
        serde_json::from_str(&crate::execute(&command.to_string())).unwrap()
    }

    fn ok(command: Value) -> Value {
        let result = call(command);
        assert!(result.get("error").is_none(), "{result}");
        result["ok"].clone()
    }

    #[derive(Clone)]
    struct Device {
        identity: Value,
        document: Value,
    }

    impl Device {
        fn new() -> Self {
            let created = ok(json!({"operation":"create","profile":{
                "name":"Noor","goals":["health"],"style":"warm"}}));
            Self {
                identity: created["identity"].clone(),
                document: created["document"].clone(),
            }
        }

        fn command(&self, operation: &str, extra: Value) -> Value {
            let mut command =
                json!({"operation":operation,"identity":self.identity,"document":self.document});
            if operation.starts_with("sync_") {
                command["origin"] = json!(ORIGIN);
            }
            command
                .as_object_mut()
                .unwrap()
                .extend(extra.as_object().unwrap().clone());
            command
        }

        fn read(&self, operation: &str, extra: Value) -> Value {
            ok(self.command(operation, extra))
        }

        fn write(&mut self, operation: &str, extra: Value) -> Value {
            let output = self.read(operation, extra);
            assert!(output["document"].is_object());
            // Simulate durable host publication and process restart, not a
            // shared object or any Rust-only in-memory sync session.
            self.document = serde_json::from_str(&output["document"].to_string()).unwrap();
            output
        }

        fn name(&mut self, name: &str) {
            self.write(
                "profile",
                json!({"profile":{"name":name,"goals":["health"],"style":"warm"}}),
            );
        }

        fn state(&self) -> Value {
            self.read("restore", json!({}))["state"].clone()
        }

        fn status(&self) -> Value {
            self.read("sync_status", json!({}))
        }

        fn prepare(&mut self) -> Value {
            self.write("sync_prepare", json!({}))["pending"].clone()
        }

        fn ingest(&mut self, record: &Value, sequence: u64) -> Value {
            self.write("sync_ingest", ingest_args(record, sequence))
        }

        fn complete(&mut self, record: &Value, sequence: u64) -> Value {
            self.write(
                "sync_complete",
                json!({"recordId":record["id"],"sequence":sequence,
                "sha256":record["sha256"],"bytes":record["bytes"]}),
            )
        }

        fn adopt(&mut self, record: &Value) -> Value {
            self.write(
                "sync_adopt",
                json!({"recordId":record["id"],"envelope":record["envelope"]}),
            )
        }
    }

    fn ingest_args(record: &Value, sequence: u64) -> Value {
        json!({"recordId":record["id"],"envelope":record["envelope"],"sequence":sequence,
            "sha256":record["sha256"],"bytes":record["bytes"]})
    }

    fn initialize(device: &mut Device) -> Value {
        let record = device.prepare();
        let complete = device.complete(&record, 1);
        assert_eq!(complete["cursor"], 0);
        device.ingest(&record, 1);
        assert_eq!(device.status()["dirty"], false);
        record
    }

    // Fixture encryption deliberately bypasses validation to exercise the
    // public bridge's handling of authenticated but unsupported remote data.
    fn fixture(device: &Device, snapshot: Value) -> Value {
        let identity: Identity = serde_json::from_value(device.identity.clone()).unwrap();
        let sealed = identity
            .seal_document(
                &crypto::id().unwrap(),
                &serde_json::to_vec(&snapshot).unwrap(),
            )
            .unwrap();
        let reference = reference(&sealed.record_id, &sealed.envelope).unwrap();
        json!({"id":reference.id,"envelope":sealed.envelope,"sha256":reference.sha256,"bytes":reference.bytes})
    }

    fn assert_rejected(device: &Device, operation: &str, extra: Value) {
        let before = device.document.clone();
        let state = device.state();
        let result = call(device.command(operation, extra));
        assert_eq!(result["error"]["kind"], "invalid", "{result}");
        assert!(result.get("ok").is_none());
        assert_eq!(before, device.document);
        assert_eq!(state, device.state());
    }

    #[test]
    fn pending_is_exact_after_restart_edits_response_loss_and_recovery() {
        let mut device = Device::new();
        let original_record = device.document["recordId"].clone();
        let first = device.prepare();
        assert_ne!(first["id"], original_record);
        assert_eq!(device.document["recordId"], original_record);
        let initial_state = device.state();
        device.name("Later offline edit");
        assert_eq!(device.status()["pending"], first);
        assert_eq!(device.prepare(), first);
        let backup = device.read("export_recovery", json!({}));
        assert!(
            !backup["backup"]
                .to_string()
                .contains(device.identity["key"].as_str().unwrap())
        );
        let recovered = ok(
            json!({"operation":"recover","backup":backup["backup"],"recoveryKey":backup["recoveryKey"]}),
        );
        let mut restarted = Device {
            identity: recovered["identity"].clone(),
            document: recovered["document"].clone(),
        };
        assert_eq!(restarted.prepare(), first);
        assert_rejected(&restarted, "sync_resolve", json!({"choice":"local"}));
        assert_rejected(&restarted, "sync_ingest", ingest_args(&first, 1));
        for (key, value) in [
            ("recordId", json!(crypto::id().unwrap())),
            ("sequence", json!(0)),
            ("sha256", json!("a".repeat(64))),
            ("bytes", json!(65)),
        ] {
            let mut args = json!({"recordId":first["id"],"sequence":1,"sha256":first["sha256"],"bytes":first["bytes"]});
            args[key] = value;
            assert_rejected(&restarted, "sync_complete", args);
        }
        // Server already stored the first PUT, but its response was lost. A
        // byte-identical retry gets the same immutable record and sequence.
        let stored = first.clone();
        assert_eq!(restarted.prepare(), stored);
        let completed = restarted.complete(&stored, 1);
        assert_eq!(completed["cursor"], 0);
        assert_eq!(completed["dirty"], true);
        assert_eq!(completed["conflict"], false);
        assert!(completed.get("pending").is_none());
        assert_eq!(restarted.state()["profile"]["name"], "Later offline edit");
        let identity: Identity = serde_json::from_value(restarted.identity.clone()).unwrap();
        let snapshot = open_snapshot(
            &identity,
            stored["id"].as_str().unwrap(),
            stored["envelope"].as_str().unwrap(),
        )
        .unwrap();
        assert_eq!(
            serde_json::to_value(&snapshot.state).unwrap(),
            initial_state
        );
        assert_eq!(
            restarted.document["sync"]["base"]["stateSha256"],
            fingerprint(&snapshot.state).unwrap()
        );
        restarted.ingest(&stored, 1);
        let next = restarted.prepare();
        assert_ne!(next["id"], stored["id"]);
        let next_snapshot = open_snapshot(
            &identity,
            next["id"].as_str().unwrap(),
            next["envelope"].as_str().unwrap(),
        )
        .unwrap();
        assert_eq!(next_snapshot.parents, [stored["id"].as_str().unwrap()]);
        assert_eq!(next_snapshot.state.profile.name, "Later offline edit");
        assert!(
            !serde_json::to_value(next_snapshot).unwrap()["state"]
                .as_object()
                .unwrap()
                .contains_key("sync")
        );
        assert!(
            !completed
                .to_string()
                .contains(restarted.identity["key"].as_str().unwrap())
        );
        assert_eq!(completed["token"], restarted.identity["token"]);
    }

    #[test]
    fn concurrent_offline_branches_require_explicit_resolution_and_converge() {
        for choice in ["local", "remote"] {
            let mut a = Device::new();
            initialize(&mut a);
            let mut b = a.clone();
            a.name("Device A");
            b.name("Device B");
            let a_record = a.prepare();
            let b_record = b.prepare();
            a.complete(&a_record, 2);
            // Another device appended before B's PUT. Acknowledging B must not
            // advance its cursor past A's previously unseen branch.
            b.complete(&b_record, 3);
            assert_eq!(b.status()["cursor"], 1);
            for device in [&mut a, &mut b] {
                device.ingest(&a_record, 2);
                let scanned = device.ingest(&b_record, 3);
                assert_eq!(scanned["heads"].as_array().unwrap().len(), 2);
                assert_eq!(scanned["conflict"], true);
                assert!(scanned.get("state").is_none());
                assert_rejected(device, "sync_prepare", json!({}));
                assert_rejected(
                    device,
                    "sync_adopt",
                    json!({"recordId":a_record["id"],"envelope":a_record["envelope"]}),
                );
            }
            assert_eq!(a.state()["profile"]["name"], "Device A");
            assert_eq!(b.state()["profile"]["name"], "Device B");
            let args = if choice == "local" {
                json!({"choice":"local"})
            } else {
                json!({"choice":"remote","recordId":b_record["id"],"envelope":b_record["envelope"]})
            };
            let resolved = a.write("sync_resolve", args);
            let pending = resolved["pending"].clone();
            assert_eq!(resolved["heads"].as_array().unwrap().len(), 2);
            assert_eq!(a.prepare(), pending);
            let identity: Identity = serde_json::from_value(a.identity.clone()).unwrap();
            let snapshot = open_snapshot(
                &identity,
                pending["id"].as_str().unwrap(),
                pending["envelope"].as_str().unwrap(),
            )
            .unwrap();
            assert_eq!(snapshot.parents.len(), 2);
            assert!(
                snapshot
                    .parents
                    .contains(&a_record["id"].as_str().unwrap().to_owned())
            );
            assert!(
                snapshot
                    .parents
                    .contains(&b_record["id"].as_str().unwrap().to_owned())
            );
            a.complete(&pending, 4);
            a.ingest(&pending, 4);
            let scanned = b.ingest(&pending, 4);
            assert_eq!(scanned["heads"].as_array().unwrap().len(), 1);
            assert_eq!(scanned["dirty"], false);
            b.adopt(&pending);
            assert_eq!(a.state(), b.state());
            assert_eq!(
                a.state()["profile"]["name"],
                if choice == "local" {
                    "Device A"
                } else {
                    "Device B"
                }
            );
            assert!(a.prepare().is_null());
            assert!(b.prepare().is_null());
            // A later unseen root branch remains an explicit conflict. A
            // resolution only supersedes the parents it authenticated.
            let extra = fixture(
                &a,
                json!({"version":1,"kind":"habibi.snapshot","parents":[],"state":a.state()}),
            );
            assert_eq!(a.ingest(&extra, 5)["conflict"], true);
            assert_eq!(a.status()["heads"].as_array().unwrap().len(), 2);
        }
    }

    #[test]
    fn dirty_single_remote_head_conflicts_but_clean_device_can_fast_forward_full_state() {
        let mut source = Device::new();
        let initial = initialize(&mut source);
        assert!(source.state()["profile"].get("theme").is_none());
        assert!(source.state()["profile"].get("appearance").is_none());
        let mut clean = source.clone();
        let mut dirty = source.clone();
        dirty.name("Unsynced changes");
        source.write(
            "profile",
            json!({"profile":{"name":"Synchronized profile","goals":["health"],"style":"warm",
                "theme":"future-catalog-v3","appearance":"dark"}}),
        );
        let definition = json!({"apiVersion":1,"name":"Walks","description":"Walking journal","fields":[
            {"key":"minutes","label":"Minutes","type":"number","unit":"min","min":0,"max":600}],
            "source":"function summarize(s){return JSON.stringify({metrics:[]})}"});
        let mut review = source.read(
            "kit_tool",
            json!({"name":"save_kit","arguments":{"definition":definition},"today":"2026-10-26"}),
        )["review"]
            .clone();
        // If opening/ingesting/adopting executes saved code, this fixture fails
        // immediately. Sync must preserve source as data, not evaluate it.
        review["definition"]["source"] = json!("throw new Error('sync must not run Kit code');");
        let installed = source.write("commit_kit", json!({"review":review}));
        source.write(
            "add_entry",
            json!({"id":installed["result"]["id"],"values":{"minutes":25}}),
        );
        source.write(
            "connect_kit",
            json!({"connection":{"kitId":"github","clientId":"fictional-client",
                "account":"noor-dev","accessToken":"private-synced-github-token","scope":"read:user"}}),
        );
        let conversations = json!([{"id":crypto::id().unwrap(),"createdAt":"2026-10-26T10:00:00Z","composer":"Private draft 🏃",
            "draft":definition,"messages":[{"id":crypto::id().unwrap(),"createdAt":"2026-10-26T10:01:00Z","kind":"assistant","text":"25 min",
            "component":{"type":"result_table","version":1,"data":{"title":"Walking plan","columns":["Minutes"],"rows":[["25"]]},
            "actions":[{"id":"show_source","label":"View data"}],"fallback":"25 minutes"}}]}]);
        source.write("save_conversations", json!({"conversations":conversations}));
        let expected = source.state();
        assert_eq!(expected["profile"]["theme"], "future-catalog-v3");
        assert_eq!(expected["profile"]["appearance"], "dark");
        let record = source.prepare();
        assert!(!record.to_string().contains("future-catalog-v3"));
        assert!(!record.to_string().contains("private-synced-github-token"));
        assert!(!record.to_string().contains("noor-dev"));
        assert!(record.get("theme").is_none());
        assert!(record.get("appearance").is_none());
        source.complete(&record, 2);
        source.ingest(&record, 2);
        let scanned = clean.ingest(&record, 2);
        assert_eq!(scanned["dirty"], false);
        assert_eq!(scanned["conflict"], false);
        assert_eq!(clean.state()["profile"]["name"], "Noor");
        assert_rejected(
            &clean,
            "sync_adopt",
            json!({"recordId":initial["id"],"envelope":initial["envelope"]}),
        );
        let mut wrong = record.clone();
        wrong["envelope"] = initial["envelope"].clone();
        assert_rejected(
            &clean,
            "sync_adopt",
            json!({"recordId":wrong["id"],"envelope":wrong["envelope"]}),
        );
        let adopted = clean.adopt(&record);
        assert_eq!(adopted["state"], expected);
        assert_eq!(clean.state(), expected);
        assert_eq!(adopted["cursor"], 2);
        assert_eq!(adopted["heads"], scanned["heads"]);
        assert_eq!(adopted["dirty"], false);
        assert_eq!(
            clean.read("connection_request", json!({"id":"github"}))["headers"]["Authorization"],
            "Bearer private-synced-github-token"
        );
        // Disconnect is a new encrypted snapshot, not a server-side token
        // revocation or deletion of old immutable snapshots and backups.
        source.write("disconnect_kit", json!({"id":"github"}));
        let removed = source.prepare();
        source.complete(&removed, 3);
        source.ingest(&removed, 3);
        clean.ingest(&removed, 3);
        clean.adopt(&removed);
        assert!(clean.state().get("connections").is_none());
        assert_rejected(&clean, "connection_request", json!({"id":"github"}));
        let conflicted = dirty.ingest(&record, 2);
        assert_eq!(conflicted["heads"].as_array().unwrap().len(), 1);
        assert_eq!(conflicted["conflict"], true);
        assert_rejected(&dirty, "sync_prepare", json!({}));
        assert_rejected(
            &dirty,
            "sync_adopt",
            json!({"recordId":record["id"],"envelope":record["envelope"]}),
        );
        assert_rejected(
            &dirty,
            "sync_resolve",
            json!({"choice":"remote","recordId":initial["id"],"envelope":initial["envelope"]}),
        );
        let chosen = dirty.write(
            "sync_resolve",
            json!({"choice":"remote","recordId":record["id"],"envelope":record["envelope"]}),
        );
        assert_eq!(chosen["state"], expected);
        assert!(chosen["pending"].is_object());
    }

    #[test]
    fn malformed_authenticated_and_unauthenticated_records_fail_without_publication() {
        let mut source = Device::new();
        let mut device = source.clone();
        let valid = source.prepare();
        let snapshot =
            json!({"version":1,"kind":"habibi.snapshot","parents":[],"state":device.state()});
        for (field, value) in [
            ("version", json!(2)),
            ("kind", json!("future.snapshot")),
            ("extra", json!(true)),
            ("parents", json!([crypto::id().unwrap()])),
        ] {
            let mut malformed = snapshot.clone();
            malformed[field] = value;
            let record = fixture(&device, malformed);
            assert_rejected(&device, "sync_ingest", ingest_args(&record, 1));
        }
        for (pointer, value) in [
            ("/state/version", json!(2)),
            ("/state/profile/style", json!("unknown")),
            (
                "/state/kits",
                json!([{"id":crypto::id().unwrap(),"definition":{},"entries":[]}]),
            ),
        ] {
            let mut malformed = snapshot.clone();
            *malformed.pointer_mut(pointer).unwrap() = value;
            assert_rejected(
                &device,
                "sync_ingest",
                ingest_args(&fixture(&device, malformed), 1),
            );
        }
        for (field, value) in [("theme", json!("../unsafe")), ("appearance", json!("auto"))] {
            let mut malformed = snapshot.clone();
            malformed["state"]["profile"][field] = value;
            assert_rejected(
                &device,
                "sync_ingest",
                ingest_args(&fixture(&device, malformed), 1),
            );
        }
        let mut recursive = snapshot.clone();
        recursive["state"]["sync"] = json!({});
        assert_rejected(
            &device,
            "sync_ingest",
            ingest_args(&fixture(&device, recursive), 1),
        );
        for (field, value) in [
            ("recordId", json!(crypto::id().unwrap())),
            ("sha256", json!("a".repeat(64))),
            (
                "sha256",
                json!(valid["sha256"].as_str().unwrap().to_uppercase()),
            ),
            ("bytes", json!(65)),
            ("sequence", json!(0)),
            ("sequence", json!(2)),
            ("sequence", json!(u64::MAX)),
            ("envelope", json!("SEFCMg")),
        ] {
            let mut args = ingest_args(&valid, 1);
            args[field] = value;
            assert_rejected(&device, "sync_ingest", args);
        }
        let mut other = Device::new();
        let foreign = other.prepare();
        assert_rejected(&device, "sync_ingest", ingest_args(&foreign, 1));
        let mut wrong_key: Identity = serde_json::from_value(device.identity.clone()).unwrap();
        wrong_key.key = other.identity["key"].as_str().unwrap().to_owned();
        let sealed = wrong_key
            .seal_document(
                &crypto::id().unwrap(),
                &serde_json::to_vec(&snapshot).unwrap(),
            )
            .unwrap();
        let reference = reference(&sealed.record_id, &sealed.envelope).unwrap();
        assert_rejected(
            &device,
            "sync_ingest",
            json!({"recordId":sealed.record_id,"envelope":sealed.envelope,"sequence":1,"sha256":reference.sha256,"bytes":reference.bytes}),
        );
        let good = fixture(&device, snapshot);
        device.ingest(&good, 1);
        assert_rejected(&device, "sync_ingest", ingest_args(&good, 1));
        assert_rejected(&device, "sync_ingest", ingest_args(&good, 2));
    }

    #[test]
    fn canonical_origins_bind_progress_and_corrupt_local_metadata_is_rejected() {
        let original = Device::new();
        assert!(original.document.get("sync").is_none());
        assert_eq!(
            original.status(),
            json!({"vaultId":original.identity["vaultId"],"token":original.identity["token"],"cursor":0,"heads":[],"dirty":true,"conflict":false})
        );
        for (origin, expected) in [
            ("https://SYNC.example.com:443/", ORIGIN),
            ("http://localhost:4000/", "http://localhost:4000"),
            ("http://127.0.0.1:80", "http://127.0.0.1"),
            ("http://10.0.2.2:4000", "http://10.0.2.2:4000"),
            ("https://[2001:db8::1]:443/", "https://[2001:db8::1]"),
        ] {
            let prepared = original.read("sync_prepare", json!({"origin":origin}));
            assert_eq!(prepared["document"]["sync"]["origin"], expected);
        }
        for origin in [
            "http://example.com",
            "http://127.1",
            "http://[::1]",
            "ftp://example.com",
            "https://user@example.com",
            "https://example.com/x/..",
            "https://example.com//",
            "https://example.com?x",
            "https://example.com#x",
            "https://example.com:0",
            "https://example.com:65536",
            "https://example.com\\@localhost",
            "https://example.com\n",
            "https://%65xample.com",
            "https://-invalid.example.com",
            "https://example.com.",
        ] {
            assert_rejected(&original, "sync_status", json!({"origin":origin}));
        }
        let mut device = original.clone();
        device.prepare();
        assert_rejected(
            &device,
            "sync_status",
            json!({"origin":"https://other.example.com"}),
        );
        assert_eq!(
            device.read(
                "sync_status",
                json!({"origin":"https://SYNC.example.com:443/"})
            ),
            device.status()
        );
        for (pointer, value) in [
            ("/sync/cursor", json!(1)),
            ("/sync/origin", json!("https://other.example.com")),
            ("/sync/pending/envelope", json!("corrupted")),
            ("/sync/pending/sha256", json!("f".repeat(64))),
            ("/sync/authentication", json!("bad")),
            ("/sync/version", json!(2)),
        ] {
            let mut corrupt = device.clone();
            *corrupt.document.pointer_mut(pointer).unwrap() = value;
            let response = call(corrupt.command("restore", json!({})));
            assert_eq!(
                response["error"]["kind"], "invalid",
                "{pointer}: {response}"
            );
        }
        let old_document = device.document.clone();
        device.name("Changed local encryption");
        let mut swapped = device.clone();
        swapped.document["sync"] = old_document["sync"].clone();
        assert!(call(swapped.command("restore", json!({})))["error"].is_object());
        // Both pre-sync documents and their existing version-1 backups remain
        // readable, with no format migration and no metadata injected on open.
        assert_eq!(original.state()["profile"]["name"], "Noor");
        let backup = original.read("export_recovery", json!({}));
        let recovered = ok(
            json!({"operation":"recover","backup":backup["backup"],"recoveryKey":backup["recoveryKey"]}),
        );
        assert_eq!(recovered["document"], original.document);
        assert!(recovered["document"].get("sync").is_none());
    }

    #[test]
    fn head_limit_fails_closed_and_explicit_resolution_retains_every_parent() {
        let mut device = Device::new();
        let state = device.state();
        for sequence in 1..=MAX_HEADS as u64 {
            let record = fixture(
                &device,
                json!({"version":1,"kind":"habibi.snapshot","parents":[],"state":state}),
            );
            device.ingest(&record, sequence);
        }
        let next = fixture(
            &device,
            json!({"version":1,"kind":"habibi.snapshot","parents":[],"state":state}),
        );
        assert_rejected(
            &device,
            "sync_ingest",
            ingest_args(&next, MAX_HEADS as u64 + 1),
        );
        assert_eq!(device.status()["cursor"], MAX_HEADS);
        assert_eq!(
            device.status()["heads"].as_array().unwrap().len(),
            MAX_HEADS
        );
        let resolved = device.write("sync_resolve", json!({"choice":"local"}));
        let identity: Identity = serde_json::from_value(device.identity.clone()).unwrap();
        let pending = &resolved["pending"];
        let snapshot = open_snapshot(
            &identity,
            pending["id"].as_str().unwrap(),
            pending["envelope"].as_str().unwrap(),
        )
        .unwrap();
        assert_eq!(snapshot.parents.len(), MAX_HEADS);
    }

    fn large_conversations() -> Value {
        json!([{"id":crypto::id().unwrap(),"createdAt":"2026-10-26T00:00:00Z","composer":"",
            "messages":(0..17).map(|_| json!({"id":crypto::id().unwrap(),"createdAt":"2026-10-26T00:00:00Z",
                "kind":"user","text":"x".repeat(60 * 1024)})).collect::<Vec<_>>()}])
    }

    #[test]
    fn current_and_pending_capacity_is_bounded_without_truncation() {
        let mut device = Device::new();
        let mut state = device.state();
        state["conversations"] = large_conversations();
        let size = serde_json::to_vec(&state).unwrap().len();
        let target = MAX_BYTES - 64 - 100;
        let text_len = state["conversations"][0]["messages"][0]["text"]
            .as_str()
            .unwrap()
            .len();
        assert!(target >= size && text_len + target - size <= 64 * 1024);
        state["conversations"][0]["messages"][0]["text"] =
            json!("x".repeat(text_len + target - size));
        let conversations = state["conversations"].clone();
        let saved = device.write("save_conversations", json!({"conversations":conversations}));
        assert_eq!(saved["state"]["conversations"], conversations);
        let record = device.prepare();
        let request = device.command("sync_prepare", json!({})).to_string();
        assert!(request.len() > 2 * MAX_BYTES);
        assert!(request.len() < 8 * MAX_BYTES);
        let repeated: Value = serde_json::from_str(&crate::execute(&request)).unwrap();
        assert_eq!(repeated["ok"]["pending"], record);
        device.name("Large local edit");
        assert_eq!(device.status()["pending"], record);
        // The full current record + pending + incoming ciphertext exceed 4 MiB
        // but fit the host budget. Refusal here is ordering, not request size.
        let incoming = device.command("sync_ingest", ingest_args(&record, 1));
        assert!(incoming.to_string().len() > 4 * MAX_BYTES);
        let refused = call(incoming);
        assert!(
            refused["error"]["message"]
                .as_str()
                .unwrap()
                .contains("pending")
        );
        device.complete(&record, 1);
        device.ingest(&record, 1);
        assert_eq!(device.state()["conversations"], conversations);
        let document_before_reseal = device.document.clone();
        device.name("Noor");
        assert_ne!(
            device.document["envelope"],
            document_before_reseal["envelope"]
        );
        assert_eq!(device.status()["dirty"], false);
        assert!(device.prepare().is_null());
        let request = device.command("restore", json!({})).to_string();
        let at_limit = format!("{request}{}", " ".repeat(8 * MAX_BYTES - request.len()));
        let allowed: Value = serde_json::from_str(&crate::execute(&at_limit)).unwrap();
        assert!(allowed["ok"].is_object());
        let too_large: Value = serde_json::from_str(&crate::execute(&(at_limit + " "))).unwrap();
        assert!(
            too_large["error"]["message"]
                .as_str()
                .unwrap()
                .contains("too large")
        );

        // A valid legacy local state may consume its entire existing record
        // budget. Snapshot overhead then fails explicitly, not by shortening
        // transcripts, dropping heads, or changing the saved local document.
        let mut full = Device::new();
        let mut state = full.state();
        state["conversations"] = large_conversations();
        let size = serde_json::to_vec(&state).unwrap().len();
        let target = MAX_BYTES - 64;
        let text = state["conversations"][0]["messages"][0]["text"]
            .as_str()
            .unwrap();
        assert!(target >= size && text.len() + target - size <= 64 * 1024);
        state["conversations"][0]["messages"][0]["text"] =
            json!("x".repeat(text.len() + target - size));
        assert_eq!(serde_json::to_vec(&state).unwrap().len(), target);
        full.write(
            "save_conversations",
            json!({"conversations":state["conversations"]}),
        );
        assert_rejected(&full, "sync_prepare", json!({}));
        assert_eq!(full.state(), state);
    }

    #[test]
    fn sync_commands_are_never_exposed_as_model_tools() {
        let request = ok(
            json!({"operation":"agent_request","history":[{"role":"user","content":"Hello"}],"today":"2026-10-26"}),
        );
        for name in [
            "sync_status",
            "sync_prepare",
            "sync_ingest",
            "sync_complete",
            "sync_adopt",
            "sync_resolve",
        ] {
            assert!(!request["body"]["tools"].to_string().contains(name));
            let response = call(
                json!({"operation":"agent_response","response":{"status":"completed","output":[{
                "type":"function_call","call_id":"host-only","name":name,"arguments":"{}"}]}}),
            );
            assert_eq!(response["error"]["kind"], "invalid");
            let device = Device::new();
            assert_rejected(
                &device,
                "kit_tool",
                json!({"name":name,"arguments":{},"today":"2026-10-26"}),
            );
        }
    }
}
