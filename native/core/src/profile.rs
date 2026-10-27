use serde::{Deserialize, Serialize};
use std::collections::HashSet;

use crate::{Error, Result};

#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Profile {
    pub name: String,
    pub goals: Vec<String>,
    pub style: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub theme: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub appearance: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default_model: Option<String>,
}

impl Profile {
    pub fn validate(&mut self) -> Result<()> {
        self.name = self.name.trim().to_owned();
        if self.name.is_empty()
            || self.name.chars().count() > 60
            || self.name.chars().any(char::is_control)
        {
            return Err(Error::invalid("Enter a name with 1–60 characters."));
        }
        let allowed = ["health", "learning", "planning", "creativity", "wellbeing"];
        let unique = self.goals.iter().collect::<HashSet<_>>();
        if self.goals.is_empty()
            || self.goals.len() > allowed.len()
            || unique.len() != self.goals.len()
            || self
                .goals
                .iter()
                .any(|goal| !allowed.contains(&goal.as_str()))
        {
            return Err(Error::invalid(
                "Choose at least one of the available interests.",
            ));
        }
        if !["warm", "direct"].contains(&self.style.as_str()) {
            return Err(Error::invalid("Choose a conversation style."));
        }
        // Catalog membership belongs to the server. Persist any safe opaque ID.
        if let Some(theme) = &self.theme
            && (theme.is_empty()
                || theme.len() > 40
                || !theme.as_bytes()[0].is_ascii_lowercase()
                || !theme
                    .bytes()
                    .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-'))
        {
            return Err(Error::invalid("Choose a valid theme ID."));
        }
        if self
            .appearance
            .as_deref()
            .is_some_and(|appearance| !["system", "light", "dark"].contains(&appearance))
        {
            return Err(Error::invalid("Choose system, light or dark appearance."));
        }
        if let Some(model) = &self.default_model {
            crate::chatgpt::validate_model(model)?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_personalization_without_silently_replacing_choices() {
        let mut profile = Profile {
            name: "  Noor  ".into(),
            goals: vec!["health".into(), "learning".into()],
            style: "direct".into(),
            theme: None,
            appearance: None,
            default_model: None,
        };
        profile.validate().unwrap();
        assert_eq!(profile.name, "Noor");
        assert_eq!(profile.goals, ["health", "learning"]);
        profile.goals.push("health".into());
        assert!(profile.validate().is_err());
        profile.goals = vec!["unknown".into()];
        assert!(profile.validate().is_err());
        profile.goals = vec!["health".into()];
        profile.name = "\n".into();
        assert!(profile.validate().is_err());
    }
}
