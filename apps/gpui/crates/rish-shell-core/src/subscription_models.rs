use crate::{model::decode, Model, Result, ShellState};
use serde_json::Value;
use std::collections::HashSet;

impl ShellState {
    /// Publish the native subscription model discovery result after the native
    /// source has been confirmed. This changes selection choices only: catalog
    /// membership does not attest API-key access or change saved chat settings.
    pub fn apply_codex_subscription_models(&mut self, value: Value) -> Result<()> {
        self.ready()?;
        let value = decode(value)?;
        let rows = value
            .as_array()
            .filter(|rows| rows.len() <= 64)
            .ok_or("Invalid Codex subscription model catalog")?;
        let mut seen = HashSet::new();
        let mut models = Vec::with_capacity(rows.len());
        for row in rows {
            let row = row
                .as_object()
                .filter(|row| row.len() == 2)
                .ok_or("Invalid Codex subscription model entry")?;
            let id = row
                .get("id")
                .and_then(Value::as_str)
                .filter(|id| valid_model_id(id))
                .ok_or("Invalid Codex subscription model identity")?;
            let name = row
                .get("name")
                .and_then(Value::as_str)
                .filter(|name| {
                    !name.trim().is_empty()
                        && name.len() <= 256
                        && !name.chars().any(char::is_control)
                })
                .ok_or("Invalid Codex subscription model name")?;
            if !seen.insert(id) {
                return Err("Duplicate Codex subscription model identity".into());
            }
            models.push(Model {
                id: id.into(),
                name: name.into(),
                harness: "codex".into(),
            });
        }
        self.replace_codex_models(models.clone())?;
        self.codex_subscription_catalog = Some(models);
        Ok(())
    }

    /// Restore API-key selection choices without invalidating subscription
    /// identities or provider bindings already used by durable chat history.
    pub fn reset_codex_subscription_models(&mut self) -> Result<()> {
        self.ready()?;
        let models = self.provider_catalog_snapshot["providers"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|p| p["harness_id"] == "codex")
            .flat_map(|p| p["models"].as_array().into_iter().flatten())
            .map(|m| Model {
                id: m["id"].as_str().unwrap_or_default().into(),
                name: m["name"].as_str().unwrap_or_default().into(),
                harness: "codex".into(),
            })
            .collect();
        self.replace_codex_models(models)?;
        self.codex_subscription_catalog = None;
        Ok(())
    }

    fn replace_codex_models(&mut self, models: Vec<Model>) -> Result<()> {
        let mut environment = self.environment.clone();
        for model in &models {
            let harness = environment.harness_by_model.get(&model.id);
            if self
                .catalog
                .iter()
                .any(|entry| entry.id == model.id && entry.harness != "codex")
                || harness.is_some_and(|harness| harness != "codex")
                || (environment.supported_models.contains(&model.id) && harness.is_none())
            {
                return Err("Codex subscription model conflicts with an existing identity".into());
            }
            if !environment.supported_models.contains(&model.id) {
                environment.supported_models.push(model.id.clone());
            }
            environment
                .harness_by_model
                .entry(model.id.clone())
                .or_insert_with(|| "codex".into());
            environment
                .host_by_model
                .entry(model.id.clone())
                .or_insert_with(|| "api.openai.com".into());
        }
        let insertion = self
            .catalog
            .iter()
            .position(|model| model.harness == "codex")
            .unwrap_or(self.catalog.len());
        let mut catalog = self.catalog.clone();
        catalog.retain(|model| model.harness != "codex");
        catalog.splice(insertion..insertion, models);
        self.environment = environment;
        self.catalog = catalog;
        Ok(())
    }
}

/// Match the native DSHCodexDiscoveryID contract exactly, including the first
/// alphanumeric character after gpt-/codex- and its 80-character ASCII bound.
fn valid_model_id(id: &str) -> bool {
    if id.len() > 80
        || !id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
    {
        return false;
    }
    if let Some(suffix) = id
        .strip_prefix("gpt-")
        .or_else(|| id.strip_prefix("codex-"))
    {
        suffix
            .as_bytes()
            .first()
            .is_some_and(u8::is_ascii_alphanumeric)
    } else {
        id.starts_with('o') && id.as_bytes().get(1).is_some_and(u8::is_ascii_digit)
    }
}

#[cfg(test)]
#[path = "subscription_models_tests.rs"]
mod tests;
