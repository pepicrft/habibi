//! Bundled, reviewed host capabilities. Agent tools receive bounded provider
//! results, never credentials. Guest JavaScript has no connection capabilities.
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use time::OffsetDateTime;
use zeroize::{Zeroize, ZeroizeOnDrop};

use crate::{Error, Result};

#[derive(Serialize, Deserialize, Zeroize, ZeroizeOnDrop)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Connection {
    pub kit_id: String,
    client_id: String,
    account: String,
    access_token: String,
    scope: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    expires_at: Option<i64>,
}

fn invalid() -> Error {
    Error::invalid("Invalid or unsupported Kit connection. Your saved vault has not been changed.")
}

pub fn catalog() -> Value {
    let github: Value = serde_json::from_str(include_str!("../assets/github-kit.json"))
        .expect("Bundled GitHub Kit must be valid JSON");
    json!({"kits":[github]})
}

pub fn tools() -> Vec<Value> {
    catalog()["kits"][0]["tools"]
        .as_array()
        .expect("Bundled GitHub Kit must declare tools")
        .clone()
}

pub fn is_tool(name: &str) -> bool {
    matches!(name, "github_get_profile" | "github_list_repositories")
}

impl Connection {
    pub fn validate(&self) -> Result<()> {
        if self.kit_id != "github"
            || self.client_id.is_empty()
            || self.client_id.len() > 128
            || !self
                .client_id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
            || self.account.is_empty()
            || self.account.len() > 39
            || !self.account.as_bytes()[0].is_ascii_alphanumeric()
            || !self.account.as_bytes()[self.account.len() - 1].is_ascii_alphanumeric()
            || !self
                .account
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-')
            || self.access_token.is_empty()
            || self.access_token.len() > 4096
            || !self
                .access_token
                .bytes()
                .all(|b| (0x21..=0x7e).contains(&b))
            || !["", "read:user"].contains(&self.scope.as_str())
            || self
                .expires_at
                .is_some_and(|expiry| !(1..=253_402_300_799).contains(&expiry))
        {
            return Err(invalid());
        }
        Ok(())
    }

    pub fn require_current(&self) -> Result<()> {
        if self
            .expires_at
            .is_some_and(|expiry| expiry <= OffsetDateTime::now_utc().unix_timestamp())
        {
            return Err(Error::invalid(
                "Your GitHub connection expired. Reconnect this Kit; your vault is unchanged.",
            ));
        }
        Ok(())
    }

    pub fn request(&self, name: &str, arguments: &Value) -> Result<Value> {
        self.require_current()?;
        if !arguments.as_object().is_some_and(|args| args.is_empty()) {
            return Err(Error::invalid("This GitHub tool takes no arguments."));
        }
        let url = match name {
            "github_get_profile" => "https://api.github.com/user",
            "github_list_repositories" => {
                "https://api.github.com/user/repos?visibility=public&affiliation=owner&sort=updated&per_page=10"
            }
            _ => return Err(Error::invalid("Unknown GitHub tool.")),
        };
        // The caller cannot supply a URL, method, path or headers. Adding an
        // operation requires reviewing a new host capability, not editing a Kit.
        Ok(json!({"url":url,"method":"GET","headers":{
            "Authorization":format!("Bearer {}", self.access_token),
            "Accept":"application/vnd.github+json","X-GitHub-Api-Version":"2022-11-28"}}))
    }
}

// A provider response is untrusted data. Only these reviewed fields may reach
// inference or the encrypted transcript; never forward an arbitrary JSON body.
pub fn tool_result(name: &str, response: Value) -> Result<Value> {
    if serde_json::to_vec(&response)?.len() > 256 * 1024 {
        return Err(Error::invalid("The GitHub result was too large."));
    }
    let result = match name {
        "github_get_profile" => {
            let login = response["login"].as_str().ok_or_else(invalid)?;
            if login.is_empty()
                || login.len() > 39
                || !login
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'-')
            {
                return Err(invalid());
            }
            json!({"login":login,"name":text(&response, "name")?,
                "bio":text(&response, "bio")?,
                "publicRepositories":count(&response, "public_repos")?,
                "followers":count(&response, "followers")?})
        }
        "github_list_repositories" => {
            let repositories = response
                .as_array()
                .filter(|items| items.len() <= 10)
                .ok_or_else(invalid)?;
            let mut results = Vec::with_capacity(repositories.len());
            for repository in repositories {
                let name = repository["name"].as_str().ok_or_else(invalid)?;
                let full_name = repository["full_name"].as_str().ok_or_else(invalid)?;
                if repository["private"] != false
                    || name.is_empty()
                    || name.len() > 100
                    || full_name.len() > 140
                    || !full_name.ends_with(&format!("/{name}"))
                    || !full_name
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b"/._-".contains(&b))
                {
                    return Err(invalid());
                }
                results.push(json!({"name":name,"fullName":full_name,
                    "description":text(repository,"description")?,
                    "language":text(repository,"language")?,
                    "stars":count(repository,"stargazers_count")?}));
            }
            json!({"repositories":results,"limit":10})
        }
        _ => return Err(Error::invalid("Unknown GitHub tool.")),
    };
    Ok(json!({"result":result}))
}

fn text(value: &Value, key: &str) -> Result<Value> {
    match value.get(key) {
        None | Some(Value::Null) => Ok(Value::Null),
        Some(Value::String(text)) => Ok(json!(text.chars().take(500).collect::<String>())),
        _ => Err(invalid()),
    }
}

fn count(value: &Value, key: &str) -> Result<u64> {
    value[key]
        .as_u64()
        .filter(|count| *count <= 9_007_199_254_740_991)
        .ok_or_else(invalid)
}

pub fn validate(connections: &[Connection]) -> Result<()> {
    // One account per bundled Kit; only GitHub ships in this first slice.
    if connections.len() > 1 {
        return Err(invalid());
    }
    for connection in connections {
        connection.validate()?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call(command: Value) -> Value {
        serde_json::from_str(&crate::execute(&command.to_string())).unwrap()
    }

    fn connection() -> Value {
        json!({"kitId":"github","clientId":"Ov23.fictional-client","account":"noor-dev",
            "accessToken":"fictional-private-github-token","scope":"read:user"})
    }

    #[test]
    fn bundled_connection_survives_restart_and_recovery_without_plaintext_storage() {
        let catalog = call(json!({"operation":"bundled_kits"}));
        assert_eq!(catalog["ok"]["kits"][0]["id"], "github");
        assert_eq!(
            catalog["ok"]["kits"][0]["permissions"],
            json!(["read:user"])
        );
        let created = call(json!({"operation":"create","profile":{
            "name":"Noor","goals":["planning"],"style":"warm"}}));
        let identity = &created["ok"]["identity"];
        let saved = call(json!({"operation":"connect_kit","identity":identity,
            "document":created["ok"]["document"],"connection":connection()}));
        assert_eq!(saved["ok"]["state"]["connections"], json!([connection()]));
        let document = &saved["ok"]["document"];
        for secret in [
            "fictional-private-github-token",
            "noor-dev",
            "Ov23.fictional-client",
        ] {
            assert!(!document.to_string().contains(secret));
        }
        let restored = call(json!({"operation":"restore","identity":identity,"document":document}));
        assert_eq!(restored["ok"]["state"], saved["ok"]["state"]);
        let request = call(json!({"operation":"connection_request","identity":identity,
            "document":document,"id":"github"}));
        assert_eq!(request["ok"]["url"], "https://api.github.com/user");
        assert_eq!(request["ok"]["method"], "GET");
        assert_eq!(
            request["ok"]["headers"]["Authorization"],
            "Bearer fictional-private-github-token"
        );
        let recovery =
            call(json!({"operation":"export_recovery","identity":identity,"document":document}));
        assert!(
            !recovery["ok"]["backup"]
                .to_string()
                .contains("fictional-private-github-token")
        );
        let recovered = call(
            json!({"operation":"recover","backup":recovery["ok"]["backup"],
            "recoveryKey":recovery["ok"]["recoveryKey"]}),
        );
        assert_eq!(recovered["ok"]["state"], saved["ok"]["state"]);
        let removed = call(json!({"operation":"disconnect_kit","identity":identity,
            "document":document,"id":"github"}));
        assert!(removed["ok"]["state"].get("connections").is_none());
        assert_eq!(
            removed["ok"]["state"]["profile"],
            saved["ok"]["state"]["profile"]
        );
        assert!(
            call(json!({"operation":"connection_request","identity":identity,
            "document":removed["ok"]["document"],"id":"github"}))["error"]
                .is_object()
        );
    }

    #[test]
    fn agent_can_use_connected_kit_tools_without_receiving_credentials_or_raw_provider_bodies() {
        let created = call(json!({"operation":"create","profile":{
            "name":"Noor","goals":["planning"],"style":"warm"}}));
        let identity = &created["ok"]["identity"];
        let saved = call(json!({"operation":"connect_kit","identity":identity,
            "document":created["ok"]["document"],"connection":connection()}));
        let document = &saved["ok"]["document"];
        for (connections, expected) in [(json!([]), 0), (json!(["github"]), 2)] {
            let request = call(
                json!({"operation":"agent_request","connections":connections,
                "history":[{"role":"user","content":"Show my GitHub repositories"}],"today":"2026-10-27"}),
            );
            let tools = request["ok"]["body"]["tools"].as_array().unwrap();
            assert_eq!(
                tools
                    .iter()
                    .filter(|tool| tool["name"].as_str().unwrap().starts_with("github_"))
                    .count(),
                expected
            );
            assert!(
                !request
                    .to_string()
                    .contains("fictional-private-github-token")
            );
        }
        for (name, url) in [
            ("github_get_profile", "https://api.github.com/user"),
            (
                "github_list_repositories",
                "https://api.github.com/user/repos?visibility=public&affiliation=owner&sort=updated&per_page=10",
            ),
        ] {
            let parsed = call(
                json!({"operation":"agent_response","response":{"status":"completed",
                "output":[{"type":"function_call","call_id":"github-read","name":name,"arguments":"{}"}]}}),
            );
            assert_eq!(parsed["ok"]["tool"]["name"], name);
            let request = call(json!({"operation":"connection_request","identity":identity,
                "document":document,"id":"github","name":name,"arguments":{}}));
            assert_eq!(request["ok"]["url"], url);
            assert_eq!(request["ok"]["method"], "GET");
            for arguments in [
                json!({"url":"https://attacker.invalid"}),
                json!({"token":"injected"}),
                json!([]),
            ] {
                let rejected = call(json!({"operation":"connection_request","identity":identity,
                    "document":document,"id":"github","name":name,"arguments":arguments}));
                assert!(rejected["error"].is_object());
                let rejected = call(
                    json!({"operation":"agent_response","response":{"status":"completed",
                    "output":[{"type":"function_call","call_id":"bad","name":name,"arguments":arguments.to_string()}]}}),
                );
                assert!(rejected["error"].is_object());
            }
            let disconnected = call(json!({"operation":"connection_request","identity":identity,
                "document":created["ok"]["document"],"id":"github","name":name,"arguments":{}}));
            assert!(disconnected["error"].is_object());
        }
        let profile = call(
            json!({"operation":"connection_result","name":"github_get_profile",
            "response":{"login":"noor-dev","name":"Noor","bio":"I build things","public_repos":7,"followers":19,
                "access_token":"fictional-private-github-token","extra":{"Authorization":"Bearer secret"}}}),
        );
        assert_eq!(
            profile["ok"]["result"],
            json!({"login":"noor-dev","name":"Noor","bio":"I build things",
            "publicRepositories":7,"followers":19})
        );
        let repositories = json!([
            {"name":"garden","full_name":"noor-dev/garden","private":false,"description":"Plants","language":"Swift","stargazers_count":7,
                "token":"fictional-private-github-token","permissions":{"admin":true}},
            {"name":"journal","full_name":"noor-dev/journal","private":false,"description":null,"language":"Kotlin","stargazers_count":19}
        ]);
        let projected = call(
            json!({"operation":"connection_result","name":"github_list_repositories","response":repositories}),
        );
        assert_eq!(
            projected["ok"]["result"],
            json!({"limit":10,"repositories":[
                {"name":"garden","fullName":"noor-dev/garden","description":"Plants","language":"Swift","stars":7},
                {"name":"journal","fullName":"noor-dev/journal","description":null,"language":"Kotlin","stars":19}
            ]})
        );
        for response in [
            json!({}),
            json!([{"private":true}]),
            json!(vec![repositories[0].clone(); 11]),
        ] {
            assert!(call(json!({"operation":"connection_result","name":"github_list_repositories","response":response}))["error"].is_object());
        }
        let manifest = call(json!({"operation":"bundled_kits"}));
        assert!(manifest["ok"]["kits"][0]["clientId"].is_string());
        assert_eq!(
            manifest["ok"]["kits"][0]["tools"].as_array().unwrap().len(),
            2
        );
    }

    #[test]
    fn unsupported_capabilities_and_credentials_fail_closed_without_exposing_secrets() {
        let created = call(json!({"operation":"create","profile":{
            "name":"Noor","goals":["planning"],"style":"warm"}}));
        let identity = &created["ok"]["identity"];
        let document = &created["ok"]["document"];
        for (key, value) in [
            ("kitId", json!("slack")),
            ("clientId", json!("https://attacker.example")),
            ("account", json!("noor\nInjected")),
            ("accessToken", json!("secret\r\nInjected: header")),
            ("accessToken", json!("")),
            ("scope", json!("read:user,repo")),
            ("scope", json!("user")),
            ("expiresAt", json!(0)),
            ("expiresAt", json!(1)),
            ("expiresAt", json!(1.5)),
            ("url", json!("https://attacker.example")),
            ("refreshToken", json!("never-store-rotating-tokens")),
        ] {
            let mut invalid = connection();
            invalid[key] = value;
            let result = call(json!({"operation":"connect_kit","identity":identity,
                "document":document,"connection":invalid}));
            assert!(result["error"].is_object(), "{result}");
            assert!(
                !result
                    .to_string()
                    .contains("fictional-private-github-token")
            );
        }
        for name in [
            "bundled_kits",
            "connect_kit",
            "disconnect_kit",
            "connection_request",
        ] {
            let result = call(json!({"operation":"kit_tool","identity":identity,
                "document":document,"name":name,"arguments":{},"today":"2026-10-26"}));
            assert!(result["error"].is_object());
            let result = call(
                json!({"operation":"agent_response","response":{"status":"completed",
                "output":[{"type":"function_call","call_id":"a","name":name,"arguments":"{}"}]}}),
            );
            assert!(result["error"].is_object());
        }
        let request = call(
            json!({"operation":"agent_request","history":[{"role":"user","content":"Hi"}],"today":"2026-10-26"}),
        );
        for tool in request["ok"]["body"]["tools"].as_array().unwrap() {
            assert!(!tool["name"].as_str().unwrap().contains("connection"));
        }
        assert_eq!(
            call(json!({"operation":"restore","identity":identity,"document":document}))["ok"]["state"],
            created["ok"]["state"]
        );
        // Authenticated remote data is still untrusted. Restore must reject
        // unknown capabilities and duplicates, but keep an expired connection
        // readable so the user can reconnect without losing the rest of a vault.
        let native_identity: crate::crypto::Identity =
            serde_json::from_value(identity.clone()).unwrap();
        let mut expired = connection();
        expired["expiresAt"] = json!(1);
        let mut unsupported = connection();
        unsupported["kitId"] = json!("slack");
        for (connections, accepted) in [
            (json!([expired]), true),
            (json!([unsupported]), false),
            (json!([connection(), connection()]), false),
        ] {
            let mut state = created["ok"]["state"].clone();
            state["connections"] = connections;
            let sealed = native_identity
                .seal_document(
                    document["recordId"].as_str().unwrap(),
                    &serde_json::to_vec(&state).unwrap(),
                )
                .unwrap();
            let restored =
                call(json!({"operation":"restore","identity":identity,"document":sealed}));
            assert_eq!(restored["ok"].is_object(), accepted);
            let request = call(json!({"operation":"connection_request","identity":identity,
                "document":sealed,"id":"github"}));
            assert!(request["error"].is_object());
            assert!(
                !request
                    .to_string()
                    .contains("fictional-private-github-token")
            );
        }
    }
}
