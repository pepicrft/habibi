//! Reviewed native card data. Never accepts bundles, capabilities or executable actions.
use std::collections::HashSet;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::{Error, Result, crypto, kits};

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Component {
    #[serde(rename = "type")]
    kind: String,
    version: u32,
    data: Value,
    actions: Vec<Action>,
    fallback: String,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Table {
    title: String,
    columns: Vec<String>,
    rows: Vec<Vec<String>>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct KitEntry {
    title: String,
    pub kit_id: String,
    pub prefill: Vec<Prefill>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Prefill {
    pub key: String,
    pub value: Value,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Action {
    id: String,
    label: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Arguments {
    component: Value,
}

pub fn arguments(value: Value) -> Result<Value> {
    validate(serde_json::from_value::<Arguments>(value)?.component)
}

pub fn validate(value: Value) -> Result<Value> {
    if serde_json::to_vec(&value)?.len() > 32 * 1024 {
        return Err(Error::invalid("This conversation component is too large."));
    }
    let card: Component = serde_json::from_value(value)?;
    let text = |value: &str, max: usize| !value.trim().is_empty() && value.len() <= max;
    let valid_data =
        match card.kind.as_str() {
            "result_table" => {
                let table: Table = serde_json::from_value(card.data.clone())?;
                let columns = table.columns.len();
                // At most 120 cells keeps the reviewed renderer below its 512-node limit.
                text(&table.title, 120)
                    && (1..=8).contains(&columns)
                    && table.columns.iter().all(|value| text(value, 60))
                    && table.rows.len() <= 20
                    && table.rows.len() * columns <= 120
                    && table.rows.iter().all(|row| {
                        row.len() == columns && row.iter().all(|value| value.len() <= 500)
                    })
                    && card.actions.len() <= 1
                    && card.actions.iter().all(|action| action.id == "show_source")
            }
            "kit_entry" => {
                let entry: KitEntry = serde_json::from_value(card.data.clone())?;
                let mut keys = HashSet::new();
                text(&entry.title, 120)
                    && crypto::valid_id(&entry.kit_id)
                    && entry.prefill.len() <= 12
                    && entry.prefill.iter().all(|item| {
                        kits::valid_field_key(&item.key)
                            && keys.insert(&item.key)
                            && (item
                                .value
                                .as_str()
                                .is_some_and(|text| text.chars().count() <= 500)
                                || item.value.as_f64().is_some_and(|number| {
                                    number.is_finite() && number.abs() <= 1e9
                                }))
                    })
                    && card.actions.len() == 1
                    && card.actions[0].id == "save_entry"
            }
            _ => false,
        };
    if card.version != 1
        || !valid_data
        || !text(&card.fallback, 4000)
        || card.actions.iter().any(|action| !text(&action.label, 80))
    {
        return Err(Error::invalid(
            "Invalid or unsupported conversation component.",
        ));
    }
    Ok(serde_json::to_value(card)?)
}

pub(crate) fn kit_entry(value: &Value) -> Result<KitEntry> {
    let component = validate(value.clone())?;
    if component["type"] != "kit_entry" {
        return Err(Error::invalid("This message is not a Kit entry card."));
    }
    Ok(serde_json::from_value(component["data"].clone())?)
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn card() -> Value {
        json!({"type":"result_table","version":1,
            "data":{"title":"Synthetic workout","columns":["Exercise","Repetitions"],"rows":[["Squat","7"],["Press","11"]]},
            "actions":[{"id":"show_source","label":"View data"}],"fallback":"Squat: 7. Press: 11."})
    }

    fn call(command: Value) -> Value {
        serde_json::from_str(&crate::execute(&command.to_string())).unwrap()
    }

    fn response(arguments: Value) -> Value {
        call(
            json!({"operation":"agent_response","response":{"status":"completed","output":[
                {"type":"function_call","name":"present_component","call_id":"display-1","arguments":arguments.to_string()}
            ]}}),
        )
    }

    fn rejected(component: Value) {
        let validation = call(json!({"operation":"validate_component","component":component}));
        assert!(validation["error"].is_object(), "{validation}");
        let step = response(json!({"component":component}));
        assert!(step["error"].is_object(), "{step}");
        assert!(step["ok"]["component"].is_null());
    }

    #[test]
    fn public_validation_and_agent_response_return_only_validated_display_data() {
        let component = card();
        assert_eq!(
            call(json!({"operation":"validate_component","component":component}))["ok"]["component"],
            component
        );
        let step = response(json!({"component":component}));
        assert_eq!(step["ok"]["component"], component);
        assert_eq!(step["ok"]["tool"]["name"], "present_component");
        assert_eq!(
            step["ok"]["tool"]["arguments"],
            json!({"component":component})
        );
        assert_eq!(step["ok"]["tool"]["callId"], "display-1");
        assert_eq!(step["ok"]["output"][0]["name"], "present_component");
        let mut empty = card();
        empty["data"]["rows"] = json!([]);
        empty["actions"] = json!([]);
        assert!(
            call(json!({"operation":"validate_component","component":empty}))["ok"].is_object()
        );
        let request = call(
            json!({"operation":"agent_request","today":"2026-10-25","history":[{"role":"user","content":"Show a table"}]}),
        );
        let tools = request["ok"]["body"]["tools"].as_array().unwrap();
        assert_eq!(tools.len(), 8);
        assert_eq!(tools.last().unwrap()["name"], "present_component");
    }

    #[test]
    fn unknown_fields_versions_types_and_actions_fail_closed() {
        for (path, value) in [
            ("/type", json!("metric_card")),
            ("/version", json!(2)),
            ("/version", json!(-1)),
            ("/version", json!(1.5)),
            ("/actions/0/id", json!("open_url")),
            ("/actions/0/id", json!("save_kit")),
            ("/actions/0/label", json!("")),
            ("/data/title", json!(" ")),
            ("/data/columns", json!([])),
            ("/data/rows/0", json!(["short"])),
        ] {
            let mut component = card();
            *component.pointer_mut(path).unwrap() = value;
            rejected(component);
        }
        for (path, key) in [
            ("", "capabilities"),
            ("/data", "source"),
            ("/actions/0", "url"),
        ] {
            let mut component = card();
            component
                .pointer_mut(path)
                .unwrap()
                .as_object_mut()
                .unwrap()
                .insert(key.into(), json!("forbidden"));
            rejected(component);
        }
        let duplicate = card()["actions"][0].clone();
        let mut component = card();
        component["actions"].as_array_mut().unwrap().push(duplicate);
        rejected(component);
        assert!(response(json!({"component":card(),"approved":true}))["error"].is_object());
        assert!(call(json!({"operation":"validate_component","component":card(),"approved":true}))["error"].is_object());
    }

    #[test]
    fn field_collection_node_and_total_byte_limits_are_enforced() {
        for (path, value) in [
            ("/data/title", json!("x".repeat(121))),
            ("/data/columns/0", json!("x".repeat(61))),
            ("/data/rows/0/0", json!("x".repeat(501))),
            ("/fallback", json!("x".repeat(4001))),
            ("/actions/0/label", json!("x".repeat(81))),
            ("/data/columns", json!(vec!["column"; 9])),
            ("/data/rows", json!(vec![vec!["cell"; 2]; 21])),
        ] {
            let mut component = card();
            *component.pointer_mut(path).unwrap() = value;
            rejected(component);
        }
        let mut cells = card();
        cells["data"]["columns"] = json!(vec!["column"; 8]);
        cells["data"]["rows"] = json!(vec![vec!["cell"; 8]; 16]);
        rejected(cells);
        let mut bytes = card();
        bytes["data"]["columns"] = json!(vec!["column"; 8]);
        bytes["data"]["rows"] = json!(vec![vec!["x".repeat(500); 8]; 10]);
        rejected(bytes);
    }

    #[test]
    fn malformed_json_types_never_panic_or_become_renderable() {
        let malformed = [
            Value::Null,
            json!(true),
            json!(0),
            json!("text"),
            json!([]),
            json!({}),
        ];
        for value in &malformed {
            rejected(value.clone());
            assert!(response(value.clone())["error"].is_object());
            for path in [
                "/type",
                "/version",
                "/data",
                "/data/title",
                "/data/columns",
                "/data/rows",
                "/data/rows/0/0",
                "/actions",
                "/actions/0",
                "/actions/0/id",
                "/fallback",
            ] {
                let mut component = card();
                *component.pointer_mut(path).unwrap() = value.clone();
                let valid_text = value.is_string()
                    && matches!(path, "/data/title" | "/data/rows/0/0" | "/fallback");
                let valid_empty = value == &json!([]) && matches!(path, "/data/rows" | "/actions");
                if valid_text || valid_empty {
                    assert!(
                        call(json!({"operation":"validate_component","component":component}))["ok"]
                            .is_object()
                    );
                } else {
                    rejected(component);
                }
            }
        }
        for text in ["{", "null", "[]", "true"] {
            assert!(call(json!({"operation":"agent_response","response":{"status":"completed","output":[
                {"type":"function_call","name":"present_component","call_id":"a","arguments":text}
            ]}}))["error"].is_object());
        }
        // Components outside the explicit tool protocol are never promoted to cards.
        assert!(call(json!({"operation":"agent_response","response":{"status":"completed","output":[],"component":card()}}))["error"].is_object());
    }
}
