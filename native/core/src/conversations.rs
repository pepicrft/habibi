//! Local encrypted transcripts, not executable provider sessions or approvals.
use std::collections::HashSet;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::{
    Error, Result, components, crypto,
    kits::{Definition, State},
};

#[derive(Serialize, Deserialize)]
pub enum Reaction {
    #[serde(rename = "👍")]
    Like,
    #[serde(rename = "❤️")]
    Love,
    #[serde(rename = "😂")]
    Laugh,
    #[serde(rename = "🎉")]
    Celebrate,
    #[serde(rename = "😮")]
    Surprised,
    #[serde(rename = "😢")]
    Sad,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Conversation {
    pub id: String,
    pub created_at: String,
    messages: Vec<Message>,
    pub composer: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub composer_clock: Option<std::collections::BTreeMap<String, u64>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    draft: Option<Definition>,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Message {
    id: String,
    created_at: String,
    kind: String,
    text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    component: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    detail: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    entry_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    reaction: Option<Reaction>,
}

pub fn validate(conversations: &mut [Conversation]) -> Result<()> {
    let mut ids = HashSet::new();
    let valid_date = |value: &str| {
        value.len() <= 40
            && time::OffsetDateTime::parse(value, &time::format_description::well_known::Rfc3339)
                .is_ok()
    };
    for conversation in conversations {
        if !crypto::valid_id(&conversation.id)
            || !ids.insert(&conversation.id)
            || !valid_date(&conversation.created_at)
            || conversation.composer.len() > 64 * 1024
            || conversation.composer_clock.as_ref().is_some_and(|clock| {
                clock.len() > 32
                    || clock.iter().any(|(id, count)| {
                        !crypto::valid_id(id) || *count == 0 || *count > 9_007_199_254_740_991
                    })
            })
        {
            return Err(Error::invalid("Invalid saved conversation."));
        }
        let mut messages = HashSet::new();
        for message in &mut conversation.messages {
            if !crypto::valid_id(&message.id)
                || !messages.insert(&message.id)
                || !valid_date(&message.created_at)
                || !["user", "assistant", "tool"].contains(&message.kind.as_str())
                || message.text.len() > 64 * 1024
                || message
                    .detail
                    .as_ref()
                    .is_some_and(|value| value.len() > 256 * 1024)
                || (message.component.is_some() && message.kind != "assistant")
                || (message.reaction.is_some() && message.kind != "user")
            {
                return Err(Error::invalid("Invalid saved conversation message."));
            }
            if let Some(component) = message.component.take() {
                message.component = Some(components::validate(component)?);
            }
            if let Some(entry_id) = &message.entry_id
                && (!crypto::valid_id(entry_id)
                    || message.kind != "assistant"
                    || message
                        .component
                        .as_ref()
                        .is_none_or(|component| component["type"] != "kit_entry"))
            {
                return Err(Error::invalid("Invalid saved Kit entry receipt."));
            }
        }
        if let Some(draft) = &mut conversation.draft {
            draft.validate()?;
        }
    }
    Ok(())
}

// A transcript refresh from a host with stale UI state must not erase a durable
// receipt, forge one, or attach it to a different card using the same IDs.
pub fn preserve_receipts(previous: &[Conversation], incoming: &mut [Conversation]) -> Result<()> {
    for conversation in incoming {
        let saved = previous.iter().find(|item| item.id == conversation.id);
        for message in &mut conversation.messages {
            let old = saved.and_then(|item| item.messages.iter().find(|old| old.id == message.id));
            let receipt = old.and_then(|old| old.entry_id.as_ref());
            if message
                .entry_id
                .as_ref()
                .is_some_and(|id| Some(id) != receipt)
                || (receipt.is_some()
                    && old.is_some_and(|old| {
                        old.component != message.component || old.kind != message.kind
                    }))
            {
                return Err(Error::invalid(
                    "Saved Kit entry receipts cannot be changed.",
                ));
            }
            message.entry_id = receipt.cloned();
        }
    }
    Ok(())
}

impl State {
    pub fn submit_kit_entry(
        &mut self,
        conversation_id: &str,
        message_id: &str,
        values: Value,
    ) -> Result<(String, bool)> {
        let conversation = self
            .conversations
            .iter()
            .position(|item| item.id == conversation_id)
            .ok_or_else(|| Error::invalid("Saved conversation not found."))?;
        let message = self.conversations[conversation]
            .messages
            .iter()
            .position(|item| item.id == message_id)
            .ok_or_else(|| Error::invalid("Saved conversation message not found."))?;
        let archived = &self.conversations[conversation].messages[message];
        let component = components::kit_entry(
            archived
                .component
                .as_ref()
                .ok_or_else(|| Error::invalid("This message is not a Kit entry card."))?,
        )?;
        let kit = self.kit(&component.kit_id)?;
        let prefill = component
            .prefill
            .into_iter()
            .map(|item| (item.key, item.value))
            .collect();
        kit.definition.validate_prefill(&prefill)?;
        // Even retries must reference an installed Kit and valid values. A
        // different valid retry payload cannot overwrite the original entry.
        kit.definition.validate_values(&values)?;
        if let Some(entry_id) = &archived.entry_id {
            return Ok((entry_id.clone(), false));
        }
        let entry_id = self.add_entry(&component.kit_id, values)?;
        self.conversations[conversation].messages[message].entry_id = Some(entry_id.clone());
        Ok((entry_id, true))
    }
}
