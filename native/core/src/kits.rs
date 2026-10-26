use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use time::{OffsetDateTime, format_description::well_known::Rfc3339};

use crate::{
    Error, Result,
    crypto::{self, Document, Identity},
    profile::Profile,
};

#[derive(Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Field {
    key: String,
    label: String,
    #[serde(rename = "type")]
    kind: String,
    unit: String,
    min: Option<f64>,
    max: Option<f64>,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Definition {
    api_version: u32,
    pub name: String,
    description: String,
    fields: Vec<Field>,
    source: String,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Entry {
    id: String,
    created_at: String,
    values: Value,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Kit {
    pub id: String,
    pub definition: Definition,
    pub entries: Vec<Entry>,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct State {
    version: u32,
    pub profile: Profile,
    pub kits: Vec<Kit>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub conversations: Vec<crate::conversations::Conversation>,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Review {
    pub operation: String,
    pub id: Option<String>,
    pub definition: Definition,
    pub entry_count: usize,
    pub revision: String,
}

fn valid_text(value: &str, max: usize) -> bool {
    !value.trim().is_empty()
        && value.chars().count() <= max
        && !value.chars().any(|ch| ch.is_control() && ch != '\n')
}

pub(crate) fn valid_field_key(key: &str) -> bool {
    !key.is_empty()
        && key.len() <= 32
        && key.as_bytes()[0].is_ascii_lowercase()
        && key
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_')
        && !["constructor", "prototype", "__proto__"].contains(&key)
}

pub fn valid_day(day: &str) -> bool {
    if day.len() != 10
        || !day.bytes().enumerate().all(|(i, b)| {
            if i == 4 || i == 7 {
                b == b'-'
            } else {
                b.is_ascii_digit()
            }
        })
    {
        return false;
    }
    let year = day[..4].parse::<u32>().unwrap_or(0);
    let month = day[5..7].parse::<usize>().unwrap_or(0);
    let date = day[8..].parse::<u32>().unwrap_or(0);
    let leap = year.is_multiple_of(4) && (!year.is_multiple_of(100) || year.is_multiple_of(400));
    let days = [
        0,
        31,
        if leap { 29 } else { 28 },
        31,
        30,
        31,
        30,
        31,
        31,
        30,
        31,
        30,
        31,
    ];
    year > 0 && month > 0 && month <= 12 && date > 0 && date <= days[month]
}

impl Definition {
    pub fn validate(&mut self) -> Result<()> {
        self.name = self.name.trim().to_owned();
        self.description = self.description.trim().to_owned();
        if self.api_version != 1
            || !valid_text(&self.name, 60)
            || !valid_text(&self.description, 300)
            || self.fields.is_empty()
            || self.fields.len() > 12
            || self.source.trim().is_empty()
            || self.source.len() > 24 * 1024
        {
            return Err(Error::invalid(
                "A Kit needs a name, description, 1–12 fields and at most 24 KiB of JavaScript.",
            ));
        }
        let mut seen = HashSet::new();
        for field in &mut self.fields {
            field.label = field.label.trim().to_owned();
            if !valid_field_key(&field.key)
                || !seen.insert(field.key.clone())
                || !valid_text(&field.label, 60)
                || field.unit.chars().count() > 16
                || !["text", "number", "date"].contains(&field.kind.as_str())
            {
                return Err(Error::invalid("Invalid or duplicate Kit field."));
            }
            if [field.min, field.max]
                .into_iter()
                .flatten()
                .any(|number| field.kind != "number" || !number.is_finite() || number.abs() > 1e9)
                || matches!((field.min, field.max), (Some(min), Some(max)) if min > max)
            {
                return Err(Error::invalid("Invalid Kit field range."));
            }
        }
        Ok(())
    }

    pub(crate) fn validate_values(&self, values: &Value) -> Result<()> {
        let map = values
            .as_object()
            .ok_or_else(|| Error::invalid("Kit values must be an object."))?;
        if map.len() != self.fields.len() {
            return Err(Error::invalid("Fill in every Kit field."));
        }
        for field in &self.fields {
            if !map.contains_key(&field.key) {
                return Err(Error::invalid("Fill in every Kit field."));
            }
        }
        self.validate_prefill(map)
    }

    pub(crate) fn validate_prefill(&self, map: &serde_json::Map<String, Value>) -> Result<()> {
        for (key, value) in map {
            let field = self
                .fields
                .iter()
                .find(|field| &field.key == key)
                .ok_or_else(|| Error::invalid("Unknown Kit field."))?;
            let valid = match field.kind.as_str() {
                "text" => value.as_str().is_some_and(|text| valid_text(text, 500)),
                "date" => value.as_str().is_some_and(valid_day),
                "number" => value.as_f64().is_some_and(|number| {
                    number.is_finite()
                        && number.abs() <= 1e9
                        && field.min.is_none_or(|min| number >= min)
                        && field.max.is_none_or(|max| number <= max)
                }),
                _ => false,
            };
            if !valid {
                return Err(Error::invalid(format!(
                    "Check the value for {}.",
                    field.label
                )));
            }
        }
        Ok(())
    }

    fn summarize(&self, entries: &[Entry], today: &str) -> Result<Value> {
        if !valid_day(today) {
            return Err(Error::invalid("Invalid local calendar date."));
        }
        let summary =
            crate::runtime::summarize(&self.source, &json!({"entries":entries,"today":today}))
                .map_err(Error::invalid)?;
        let map = summary
            .as_object()
            .ok_or_else(|| Error::invalid("Invalid Kit summary."))?;
        let metrics = map
            .get("metrics")
            .and_then(Value::as_array)
            .ok_or_else(|| Error::invalid("Invalid Kit metrics."))?;
        if map.len() != 1 || metrics.len() > 8 {
            return Err(Error::invalid("A Kit can return at most eight metrics."));
        }
        for metric in metrics {
            let item = metric
                .as_object()
                .ok_or_else(|| Error::invalid("Invalid Kit metric."))?;
            if item.len() != 3
                || !item
                    .get("label")
                    .and_then(Value::as_str)
                    .is_some_and(|v| valid_text(v, 60))
                || item
                    .get("value")
                    .and_then(Value::as_str)
                    .is_none_or(|v| v.chars().count() > 80)
                || item
                    .get("unit")
                    .and_then(Value::as_str)
                    .is_none_or(|v| v.chars().count() > 16)
            {
                return Err(Error::invalid("Invalid Kit metric."));
            }
        }
        Ok(summary)
    }
}

impl State {
    pub fn new(mut profile: Profile) -> Result<Self> {
        profile.validate()?;
        Ok(Self {
            version: 1,
            profile,
            kits: vec![],
            conversations: vec![],
        })
    }

    pub fn open(identity: &Identity, document: &Document) -> Result<Self> {
        let plaintext = identity.open_document(document)?;
        let mut state: Self = serde_json::from_slice(&plaintext)?;
        state.validate()?;
        crate::sync::validate(identity, document)?;
        Ok(state)
    }

    // Structural validation only. Opening a snapshot must never execute Kit
    // JavaScript, run a migration, or discard unsupported saved data.
    pub(crate) fn validate(&mut self) -> Result<()> {
        self.profile.validate()?;
        if self.version != 1 || self.kits.len() > 12 {
            return Err(Error::invalid("Unsupported vault storage version."));
        }
        let mut ids = HashSet::new();
        for kit in &mut self.kits {
            if !crypto::valid_id(&kit.id) || !ids.insert(kit.id.clone()) || kit.entries.len() > 250
            {
                return Err(Error::invalid("Invalid Kit storage."));
            }
            kit.definition.validate()?;
            let mut entry_ids = HashSet::new();
            for entry in &kit.entries {
                if !crypto::valid_id(&entry.id)
                    || !entry_ids.insert(&entry.id)
                    || entry.created_at.len() > 40
                {
                    return Err(Error::invalid("Invalid Kit entry."));
                }
                kit.definition.validate_values(&entry.values)?;
            }
        }
        crate::conversations::validate(&mut self.conversations)?;
        Ok(())
    }

    pub fn sealed(&self, identity: &Identity, document: Option<&Document>) -> Result<Value> {
        let record = match document {
            Some(saved) => saved.record_id.clone(),
            None => crypto::id()?,
        };
        let plaintext = zeroize::Zeroizing::new(serde_json::to_vec(self)?);
        let mut sealed = identity.seal_document(&record, &plaintext)?;
        if let Some(saved) = document {
            crate::sync::validate(identity, saved)?;
            crate::sync::attach(identity, &mut sealed, saved.sync.clone())?;
        }
        Ok(json!({"document": sealed, "state":self}))
    }

    pub fn kit(&self, id: &str) -> Result<&Kit> {
        self.kits
            .iter()
            .find(|kit| kit.id == id)
            .ok_or_else(|| Error::invalid("Kit not found."))
    }

    pub fn summary(&self, id: &str, today: &str) -> Result<Value> {
        let kit = self.kit(id)?;
        kit.definition.summarize(&kit.entries, today)
    }

    pub fn add_entry(&mut self, id: &str, values: Value) -> Result<String> {
        let kit = self
            .kits
            .iter_mut()
            .find(|kit| kit.id == id)
            .ok_or_else(|| Error::invalid("Kit not found."))?;
        if kit.entries.len() >= 250 {
            return Err(Error::invalid("This Kit has reached its 250-entry limit."));
        }
        kit.definition.validate_values(&values)?;
        let created_at = OffsetDateTime::now_utc()
            .format(&Rfc3339)
            .map_err(|_| Error::storage("Device clock is unavailable."))?;
        let entry_id = crypto::id()?;
        kit.entries.push(Entry {
            id: entry_id.clone(),
            created_at,
            values,
        });
        // Include JSON escaping, metadata and the fixed-width local-day wrapper.
        // Accepted entries must still fit the same budget used by every summary.
        if serde_json::to_vec(&json!({"entries":kit.entries,"today":"2000-01-01"}))?.len()
            > crate::runtime::INPUT_LIMIT
        {
            kit.entries.pop();
            return Err(Error::invalid(
                "This Kit has reached its local data-size limit. The new entry was not saved.",
            ));
        }
        Ok(entry_id)
    }

    pub fn tool(
        &self,
        document: &Document,
        name: &str,
        arguments: Value,
        today: &str,
    ) -> Result<Value> {
        let keys: &[&str] = match name {
            "list_kits" => &[],
            "read_kit" | "remove_kit" => &["id"],
            "write_kit" | "save_kit" => &["definition"],
            "update_kit" => &["id", "definition"],
            "evaluate_kit" => &["definition", "entries_json"],
            _ => return Err(Error::invalid("Unknown Kit tool.")),
        };
        let args = arguments
            .as_object()
            .ok_or_else(|| Error::invalid("Invalid tool arguments."))?;
        if args.len() != keys.len() || keys.iter().any(|key| !args.contains_key(*key)) {
            return Err(Error::invalid("Invalid tool arguments."));
        }
        if name == "list_kits" {
            return Ok(
                json!({"result":self.kits.iter().map(|kit| json!({"id":kit.id,"name":kit.definition.name,"description":kit.definition.description})).collect::<Vec<_>>()}),
            );
        }
        let existing = args
            .get("id")
            .map(|value| self.kit(value.as_str().unwrap_or("")))
            .transpose()?;
        if name == "read_kit" {
            return Ok(
                json!({"result":{"id":existing.unwrap().id,"definition":existing.unwrap().definition}}),
            );
        }
        let mut definition = if name == "remove_kit" {
            existing.unwrap().definition.clone()
        } else {
            serde_json::from_value(args["definition"].clone())?
        };
        definition.validate()?;
        if name == "write_kit" {
            return Ok(json!({"draft":definition,"result":{"staged":true,"persisted":false}}));
        }
        if name == "evaluate_kit" {
            let input = args["entries_json"]
                .as_str()
                .filter(|input| input.len() <= 32 * 1024)
                .ok_or_else(|| Error::invalid("Synthetic test data is too large."))?;
            let values: Vec<Value> = serde_json::from_str(input)?;
            if values.len() > 20 {
                return Err(Error::invalid("Use at most 20 synthetic entries."));
            }
            let entries = values
                .into_iter()
                .enumerate()
                .map(|(index, values)| {
                    definition.validate_values(&values)?;
                    Ok(Entry {
                        id: format!("test-{index}"),
                        created_at: format!("{today}T12:00:00Z"),
                        values,
                    })
                })
                .collect::<Result<Vec<_>>>()?;
            let summary = definition.summarize(&entries, today)?;
            return Ok(
                json!({"result":{"metrics":summary["metrics"],"data":"Synthetic values only. Saved entries were not read."}}),
            );
        }
        if name != "remove_kit" {
            definition.summarize(&[], today)?;
        }
        if name == "update_kit" && existing.unwrap().definition.fields != definition.fields {
            return Err(Error::invalid(
                "Field schemas cannot change. Create a new Kit instead; migrations are not supported yet.",
            ));
        }
        if name == "save_kit" && self.kits.len() >= 12 {
            return Err(Error::invalid("Your vault has reached its 12-Kit limit."));
        }
        Ok(
            json!({"review":Review { operation: name.to_owned(), id: existing.map(|kit| kit.id.clone()), definition,
            entry_count: existing.map_or(0, |kit| kit.entries.len()), revision: revision(document) }, "result":{"approvalRequired":true}}),
        )
    }

    pub fn commit(&mut self, document: &Document, mut review: Review) -> Result<Value> {
        if review.revision != revision(document) {
            return Err(Error::invalid("Your vault changed. Review this Kit again."));
        }
        review.definition.validate()?;
        match review.operation.as_str() {
            "save_kit" if review.id.is_none() && self.kits.len() < 12 => {
                let id = crypto::id()?;
                self.kits.push(Kit {
                    id: id.clone(),
                    definition: review.definition,
                    entries: vec![],
                });
                Ok(json!({"approved":true,"id":id,"changed":true}))
            }
            "update_kit" | "remove_kit" => {
                let id = review
                    .id
                    .as_deref()
                    .ok_or_else(|| Error::invalid("Missing Kit identity."))?;
                let index = self
                    .kits
                    .iter()
                    .position(|kit| kit.id == id)
                    .ok_or_else(|| Error::invalid("Kit not found."))?;
                if self.kits[index].entries.len() != review.entry_count {
                    return Err(Error::invalid("Kit entries changed. Review again."));
                }
                if review.operation == "update_kit" {
                    if self.kits[index].definition.fields != review.definition.fields {
                        return Err(Error::invalid("Kit schema migrations are not supported."));
                    }
                    self.kits[index].definition = review.definition;
                } else {
                    self.kits.remove(index);
                }
                Ok(json!({"approved":true,"id":id,"changed":true}))
            }
            _ => Err(Error::invalid("Invalid Kit approval.")),
        }
    }
}

fn revision(document: &Document) -> String {
    crypto::encode(&Sha256::digest(document.envelope.as_bytes()))
}

#[cfg(test)]
mod tests {
    use super::*;

    pub fn definition() -> Value {
        json!({"apiVersion":1,"name":"Strength journal","description":"Count your training reps.","fields":[
            {"key":"sets","label":"Sets","type":"number","unit":"sets","min":1,"max":100},
            {"key":"reps","label":"Reps","type":"number","unit":"reps","min":1,"max":100}],
            "source":"function summarize(s){const x=JSON.parse(s);return JSON.stringify({metrics:[{label:'Reps',value:String(x.entries.reduce((n,e)=>n+e.values.sets*e.values.reps,0)),unit:'reps'}]})}"})
    }

    #[test]
    fn native_tools_require_approval_preserve_entries_and_reject_stale_reviews() {
        let identity = Identity::create().unwrap();
        let mut state = State::new(Profile {
            name: "Noor".into(),
            goals: vec!["health".into()],
            style: "warm".into(),
            theme: None,
            appearance: None,
        })
        .unwrap();
        let initial = state.sealed(&identity, None).unwrap();
        let mut document: Document = serde_json::from_value(initial["document"].clone()).unwrap();
        let args = json!({"definition":definition()});
        let staged = state
            .tool(&document, "write_kit", args.clone(), "2026-10-25")
            .unwrap();
        assert_eq!(staged["result"]["persisted"], false);
        assert!(state.kits.is_empty());
        let pending = state
            .tool(&document, "save_kit", args, "2026-10-25")
            .unwrap();
        assert!(state.kits.is_empty());
        let result = state
            .commit(
                &document,
                serde_json::from_value(pending["review"].clone()).unwrap(),
            )
            .unwrap();
        let id = result["id"].as_str().unwrap();
        state.add_entry(id, json!({"sets":3,"reps":7})).unwrap();
        state.add_entry(id, json!({"sets":8,"reps":11})).unwrap();
        assert_eq!(
            state.summary(id, "2026-10-25").unwrap()["metrics"][0]["value"],
            "109"
        );
        // Real and synthetic timestamps must both be parseable as ISO dates.
        let dates = "function summarize(s){const x=JSON.parse(s);return JSON.stringify({metrics:[{label:'Dates',value:String(x.entries.every(e=>Number.isFinite(Date.parse(e.createdAt)))),unit:''}]})}";
        assert_eq!(
            crate::runtime::summarize(
                dates,
                &json!({"entries":state.kits[0].entries,"today":"2026-10-25"})
            )
            .unwrap()["metrics"][0]["value"],
            "true"
        );
        document = serde_json::from_value(
            state.sealed(&identity, Some(&document)).unwrap()["document"].clone(),
        )
        .unwrap();
        let mut updated = definition();
        updated["name"] = json!("My workouts");
        let pending = state
            .tool(
                &document,
                "update_kit",
                json!({"id":id,"definition":updated}),
                "2026-10-25",
            )
            .unwrap();
        state
            .commit(
                &document,
                serde_json::from_value(pending["review"].clone()).unwrap(),
            )
            .unwrap();
        assert_eq!(state.kits[0].entries.len(), 2);
        let new_document: Document = serde_json::from_value(
            state.sealed(&identity, Some(&document)).unwrap()["document"].clone(),
        )
        .unwrap();
        assert!(
            state
                .commit(
                    &new_document,
                    serde_json::from_value(pending["review"].clone()).unwrap()
                )
                .is_err()
        );
        let list = state
            .tool(&new_document, "list_kits", json!({}), "2026-10-25")
            .unwrap()
            .to_string();
        assert!(!list.contains("entries"));
        let restored = State::open(&identity, &new_document).unwrap();
        assert_eq!(restored.kits[0].definition.name, "My workouts");
        assert_eq!(
            restored.summary(id, "2026-10-25").unwrap()["metrics"][0]["value"],
            "109"
        );
        let mut incompatible = definition();
        incompatible["fields"][0]["min"] = json!(0);
        assert!(
            state
                .tool(
                    &new_document,
                    "update_kit",
                    json!({"id":id,"definition":incompatible}),
                    "2026-10-25"
                )
                .is_err()
        );
    }

    #[test]
    fn accepted_entries_remain_summarizable_at_the_input_capacity_boundary() {
        let mut definition = definition();
        definition["fields"] = json!([{ "key":"notes", "label":"Notes", "type":"text", "unit":"", "min":null, "max":null }]);
        definition["source"] = json!(
            "function summarize(s){const x=JSON.parse(s);return JSON.stringify({metrics:[{label:'Entries',value:String(x.entries.length),unit:''}]})}"
        );
        let kit = Kit {
            id: crypto::id().unwrap(),
            definition: serde_json::from_value(definition).unwrap(),
            entries: vec![],
        };
        let id = kit.id.clone();
        let mut state = State::new(Profile {
            name: "Noor".into(),
            goals: vec!["health".into()],
            style: "warm".into(),
            theme: None,
            appearance: None,
        })
        .unwrap();
        state.kits.push(kit);
        // Quotes exercise JSON expansion: 500 characters occupy 1,000 bytes.
        for _ in 0..230 {
            state
                .add_entry(&id, json!({"notes":"\"".repeat(500)}))
                .unwrap();
        }
        let mut accepted = 230;
        while state
            .add_entry(&id, json!({"notes":"\"".repeat(500)}))
            .is_ok()
        {
            accepted += 1;
        }
        assert!(accepted > 230 && accepted < 250);
        assert_eq!(state.kits[0].entries.len(), accepted);
        assert_eq!(
            state.summary(&id, "2026-10-25").unwrap()["metrics"][0]["value"],
            accepted.to_string()
        );
        assert!(
            state
                .add_entry(&id, json!({"notes":"\"".repeat(500)}))
                .is_err()
        );
        assert_eq!(state.kits[0].entries.len(), accepted);
    }

    #[test]
    fn rejects_impossible_calendar_dates_and_out_of_range_entries() {
        assert!(valid_day("2024-02-29"));
        for day in [
            "2025-02-29",
            "2026-04-31",
            "2026-00-01",
            "0000-01-01",
            "2026-10-00",
            "é2026-1",
        ] {
            assert!(!valid_day(day));
        }
        let mut kit: Definition = serde_json::from_value(definition()).unwrap();
        kit.validate().unwrap();
        assert!(kit.validate_values(&json!({"sets":0,"reps":7})).is_err());
        assert!(kit.validate_values(&json!({"sets":3,"reps":101})).is_err());
        assert!(
            kit.validate_values(&json!({"sets":3,"reps":7,"extra":1}))
                .is_err()
        );
    }
}
