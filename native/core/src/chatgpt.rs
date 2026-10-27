//! ChatGPT/Codex wire adaptation only. Credentials and HTTP stay in the native
//! host, outside vault snapshots, model tools, recovery exports and sync.
use serde_json::{Value, json};

use crate::{Error, Result};

const DEFAULT_MODEL: &str = "gpt-6.1-sol";

pub fn models() -> Value {
    // Pi's legacy openai-codex catalog, b3a29f1. Not account entitlements.
    json!({"defaultModel":DEFAULT_MODEL,"models":[
        {"id":"gpt-6.1-sol","name":"GPT-6.1 Sol"},
        {"id":"gpt-6.1-terra","name":"GPT-6.1 Terra"},
        {"id":"gpt-6-astra","name":"GPT-6 Astra"},
        {"id":"gpt-6-sol","name":"GPT-6 Sol"},
        {"id":"gpt-6-luna","name":"GPT-6 Luna"},
        {"id":"gpt-5.6-luna","name":"GPT-5.6 Luna"},
        {"id":"gpt-5.6-sol","name":"GPT-5.6 Sol"},
        {"id":"gpt-5.6-terra","name":"GPT-5.6 Terra"}
    ]})
}

pub fn validate_model(model: &str) -> Result<()> {
    // Keep safe opaque IDs so preferences from newer clients remain readable.
    if model.is_empty()
        || model.len() > 100
        || !model
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b))
    {
        return Err(Error::invalid("Choose a valid model."));
    }
    Ok(())
}

pub fn request(mut body: Value, model: Option<&str>) -> Result<Value> {
    let model = model.unwrap_or(DEFAULT_MODEL);
    validate_model(model)?;
    let body = body
        .as_object_mut()
        .ok_or_else(|| Error::invalid("Invalid ChatGPT request."))?;
    body.remove("max_output_tokens"); // Not accepted by the Codex endpoint.
    body.insert("model".into(), json!(model));
    body.insert("reasoning".into(), json!({"effort":"medium"}));
    body.insert("include".into(), json!(["reasoning.encrypted_content"]));
    body.insert("store".into(), json!(false));
    body.insert("stream".into(), json!(true));
    Ok(json!({"body":body}))
}

pub fn response(stream: &str) -> Result<Value> {
    if stream.len() > 2 * 1024 * 1024 {
        return Err(Error::invalid("The ChatGPT response is too large."));
    }
    // Only a terminal completed response can enter the existing agent loop.
    // Partial deltas must never execute tools or become a successful reply.
    let normalized = stream.replace("\r\n", "\n");
    let mut completed = None;
    for frame in normalized.split("\n\n") {
        let data = frame
            .lines()
            .filter_map(|line| line.strip_prefix("data:").map(str::trim_start))
            .collect::<Vec<_>>()
            .join("\n");
        if data.is_empty() || data == "[DONE]" {
            continue;
        }
        let event: Value = serde_json::from_str(&data)?;
        match event["type"].as_str() {
            Some("response.completed" | "response.done") => {
                if event["response"]["status"] != "completed" || completed.is_some() {
                    return Err(Error::invalid("ChatGPT did not finish this reply."));
                }
                completed = Some(event["response"].clone());
            }
            Some("error" | "response.failed" | "response.incomplete") => {
                return Err(Error::invalid(
                    "ChatGPT could not finish this reply. Try again.",
                ));
            }
            _ => {}
        }
    }
    let response = completed
        .ok_or_else(|| Error::invalid("ChatGPT disconnected before finishing this reply."))?;
    if serde_json::to_vec(&response)?.len() > 128 * 1024 {
        return Err(Error::invalid("The ChatGPT reply is too large."));
    }
    Ok(json!({"response":response}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn model_selection_reaches_the_outbound_request_instead_of_the_body_default() {
        for (model, expected) in [
            (Value::Null, "gpt-6.1-sol"),
            (json!("gpt-6-luna"), "gpt-6-luna"),
            (json!("future-model-v2"), "future-model-v2"),
        ] {
            let command = json!({"operation":"chatgpt_request","model":model,
                "body":{"model":"ignored-host-default","input":[],"max_output_tokens":6000}});
            let result: Value =
                serde_json::from_str(&crate::execute(&command.to_string())).unwrap();
            assert_eq!(result["ok"]["body"]["model"], expected);
            assert_eq!(result["ok"]["body"]["reasoning"]["effort"], "medium");
        }
    }

    #[test]
    fn chatgpt_streams_preserve_tool_calls_and_fail_closed_on_partial_or_failed_replies() {
        let call = |operation: &str, key: &str, value: Value| -> Value {
            let mut command = json!({"operation":operation});
            command[key] = value;
            serde_json::from_str(&crate::execute(&command.to_string())).unwrap()
        };
        let prepared = call(
            "chatgpt_request",
            "body",
            json!({"max_output_tokens":6000,
            "input":[{"role":"user","content":"Hello"}],"tools":[],"store":true}),
        );
        assert_eq!(prepared["ok"]["body"]["stream"], true);
        assert_eq!(prepared["ok"]["body"]["store"], false);
        assert!(prepared["ok"]["body"].get("max_output_tokens").is_none());
        let output = json!({"status":"completed","output":[{"type":"function_call",
            "call_id":"kit-1","name":"list_kits","arguments":"{}"}]});
        let terminal = format!(
            "data: {}\r\n\r\n",
            json!({"type":"response.completed","response":output})
        );
        let parsed = call(
            "chatgpt_response",
            "stream",
            json!(format!(
                "data: {{\"type\":\"response.output_text.delta\",\"delta\":\"ignored\"}}\n\n{terminal}data: [DONE]\n\n"
            )),
        );
        assert_eq!(parsed["ok"]["response"], output);
        assert_eq!(
            crate::agent::response(parsed["ok"]["response"].clone()).unwrap()["tool"]["name"],
            "list_kits"
        );
        for stream in [
            "data: [DONE]\n\n".to_string(),
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n".to_string(),
            format!("{terminal}data: {{\"type\":\"error\",\"message\":\"PRIVATE\"}}\n\n"),
            "data: {\"type\":\"response.done\",\"response\":{\"status\":\"incomplete\"}}\n\n"
                .to_string(),
        ] {
            let result = call("chatgpt_response", "stream", json!(stream));
            assert!(result["error"].is_object());
            assert!(!result.to_string().contains("PRIVATE"));
        }
    }
}
