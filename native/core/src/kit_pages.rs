//! Reviewed Kit-owned NSH pages. Loading a page needs no vault or connection.
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::{Error, Result, connections};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Presentation {
    version: u32,
    entry: String,
    sha256: String,
    fallback: String,
}

pub fn page(id: &str) -> Result<Value> {
    let catalog = connections::catalog();
    let kit = catalog["kits"]
        .as_array()
        .and_then(|kits| kits.iter().find(|kit| kit["id"] == id))
        .ok_or_else(|| Error::invalid("This Kit page is unavailable."))?;
    let declaration: Presentation = serde_json::from_value(kit["presentation"].clone())?;
    // No paths, URLs or guest-supplied code are resolved here. Adding a bundle
    // requires shipping and reviewing that package, independently of its tools.
    let source = match declaration.entry.as_str() {
        "github-page.js" => include_str!("../assets/github-page.js"),
        _ => return Err(Error::invalid("This Kit page is unavailable.")),
    };
    if declaration.version != 1
        || declaration.sha256 != format!("{:x}", Sha256::digest(source.as_bytes()))
        || source.len() > 256 * 1024
        || declaration.fallback.trim().is_empty()
        || declaration.fallback.len() > 4000
    {
        return Err(Error::invalid("This Kit page could not be verified."));
    }
    Ok(
        json!({"version":1,"source":source,"fallback":declaration.fallback,
        "kit":{"id":kit["id"],"name":kit["name"],"description":kit["description"]}}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call(command: Value) -> Value {
        serde_json::from_str(&crate::execute(&command.to_string())).unwrap()
    }

    #[test]
    fn public_page_is_the_pinned_kit_bundle_not_a_credential_or_tool_capability() {
        let page = call(json!({"operation":"kit_page","id":"github"}));
        let page = &page["ok"];
        assert_eq!(page["version"], 1);
        assert_eq!(
            page["kit"],
            json!({"id":"github","name":"GitHub",
            "description":connections::catalog()["kits"][0]["description"]})
        );
        assert_eq!(
            format!("{:x}", Sha256::digest(page["source"].as_str().unwrap())),
            connections::catalog()["kits"][0]["presentation"]["sha256"]
                .as_str()
                .unwrap()
        );
        assert!(page["source"].as_str().unwrap().contains("habibi.kit-page"));
        assert!(
            page["fallback"]
                .as_str()
                .unwrap()
                .contains("public repositories")
        );
        assert!(page["kit"].get("clientId").is_none());
        assert!(page["kit"].get("tools").is_none());
        for id in [
            "../github-page.js",
            "https://example.com/page.js",
            "slack",
            "",
        ] {
            assert!(call(json!({"operation":"kit_page","id":id}))["error"].is_object());
        }
        for key in ["source", "identity", "document", "capabilities", "approved"] {
            let mut command = json!({"operation":"kit_page","id":"github"});
            command[key] = json!({});
            assert!(call(command)["error"].is_object());
        }
        let agent = call(
            json!({"operation":"agent_response","response":{"status":"completed",
            "output":[{"type":"function_call","call_id":"page","name":"kit_page","arguments":"{\"id\":\"github\"}"}]}}),
        );
        assert!(agent["error"].is_object());
    }
}
