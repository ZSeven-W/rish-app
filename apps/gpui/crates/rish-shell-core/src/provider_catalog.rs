//! Selectable rows come only from persisted provider metadata or discovery.
use crate::{
    custom_provider_catalog, model::*, provider_model_catalog as registry, Model, Result,
    RuntimeCommand, ShellState,
};
use serde_json::{json, Value};

impl ShellState {
    pub fn apply_catalog(&mut self, value: Value) -> Result<RuntimeCommand> {
        let value = decode(value)?;
        if value.get("providers").is_some() {
            self.apply_provider_catalog(value)?;
        } else {
            // Compatibility with older native DSH metadata replies. This
            // imports explicit rows only; it never supplies other providers.
            let catalog = rish_agent_core::model_catalog::read_catalog(&value)
                .map_err(|_| "Invalid native model catalog")?;
            let mut next =
                registry::read_registry(&self.provider_catalog_snapshot, &Value::Null, &[])
                    .map_err(|_| "Invalid provider catalog")?;
            let row = next["providers"]
                .as_array_mut()
                .unwrap()
                .iter_mut()
                .find(|row| row["harness_id"] == "dsh")
                .unwrap();
            let previous: Vec<Value> = ["models", "retired_models"]
                .iter()
                .flat_map(|key| row[*key].as_array().cloned().unwrap_or_default())
                .collect();
            row["models"] = json!(catalog
                .models()
                .iter()
                .filter(|m| crate::custom_provider_registry::provider_id_for_model(&m.id).is_none())
                .map(|m| m.to_json())
                .collect::<Vec<_>>());
            row["retired_models"] = json!(catalog
                .retired_models()
                .iter()
                .filter(|m| crate::custom_provider_registry::provider_id_for_model(&m.id).is_none())
                .map(|m| m.to_json())
                .collect::<Vec<_>>());
            for old in previous {
                if !["models", "retired_models"].iter().any(|key| {
                    row[*key]
                        .as_array()
                        .unwrap()
                        .iter()
                        .any(|m| m["id"] == old["id"])
                }) {
                    row["retired_models"].as_array_mut().unwrap().push(old);
                }
            }
            next["revision"] = json!(next["revision"].as_u64().unwrap_or(0).saturating_add(1));
            self.apply_provider_catalog(next)?;
        }
        Ok(self.load_command())
    }

    /// Refresh choices without changing a default, conversation, or writer.
    pub fn apply_provider_catalog(&mut self, value: Value) -> Result<()> {
        if self.pending.is_some() || self.sending.is_some() || self.agent_run.is_some() {
            return Err(
                "Resolve the pending native transaction before changing the catalog".into(),
            );
        }
        let next = registry::read_registry(&decode(value)?, &Value::Null, &[])
            .map_err(|_| "Invalid native provider model catalog")?;
        if !self.provider_catalog_snapshot.is_null() {
            if next["revision"].as_u64() < self.provider_catalog_snapshot["revision"].as_u64()
                || (next["revision"] == self.provider_catalog_snapshot["revision"]
                    && next != self.provider_catalog_snapshot)
            {
                return Err("Provider model catalog revision changed".into());
            }
            let old_rows =
                registry::models(&self.provider_catalog_snapshot, &Value::Null, &[], true)
                    .map_err(|_| "Invalid previous provider model catalog")?;
            let new_rows = registry::models(&next, &Value::Null, &[], true)
                .map_err(|_| "Invalid provider model catalog")?;
            for old in old_rows.as_array().unwrap() {
                if !new_rows
                    .as_array()
                    .unwrap()
                    .iter()
                    .any(|row| row["id"] == old["id"] && row["harness_id"] == old["harness_id"])
                {
                    return Err("Provider catalog lost a historical model identity".into());
                }
            }
        }
        let all = registry::models(&next, &Value::Null, &[], true)
            .map_err(|_| "Invalid provider model catalog")?;
        let mut environment = self.environment.clone();
        let mut models = Vec::new();
        for row in all.as_array().unwrap() {
            let model = Model {
                id: text(row, "id").into(),
                name: text(row, "name").into(),
                harness: text(row, "harness_id").into(),
            };
            if environment
                .harness_by_model
                .get(&model.id)
                .is_some_and(|h| h != &model.harness)
            {
                return Err("Provider model identity belongs to another provider".into());
            }
            let facts = env(std::slice::from_ref(&model));
            if !environment.supported_models.contains(&model.id) {
                environment.supported_models.push(model.id.clone());
            }
            environment
                .harness_by_model
                .insert(model.id.clone(), model.harness.clone());
            if let Some(host) = facts.host_by_model.get(&model.id) {
                environment
                    .host_by_model
                    .insert(model.id.clone(), host.clone());
            }
            if row["active"] == true {
                models.push(model);
            }
        }
        if let Some(subscription) = &self.codex_subscription_catalog {
            models.retain(|m| m.harness != "codex");
            models.extend(subscription.iter().cloned());
        }
        let (models, environment, providers, names) =
            custom_provider_catalog::merge(&self.custom_registry, models, environment)?;
        self.provider_catalog_snapshot = next;
        self.catalog = models;
        self.environment = environment;
        self.custom_provider_names = providers;
        self.custom_model_names = names;
        Ok(())
    }
    pub fn model_is_configured(&self, model: &str) -> bool {
        !model.is_empty() && self.catalog.iter().any(|m| m.id == model)
    }
    pub fn configured_default_model(&self) -> Option<&str> {
        self.preferences()["default_model"]
            .as_str()
            .filter(|id| self.model_is_configured(id))
            .or_else(|| self.catalog.first().map(|m| m.id.as_str()))
    }
    pub fn stored_model_display_name(&self, model: &str) -> Option<&str> {
        self.custom_model_names
            .get(model)
            .map(String::as_str)
            .or_else(|| {
                self.provider_catalog_snapshot["providers"]
                    .as_array()?
                    .iter()
                    .find_map(|provider| {
                        ["models", "retired_models"].iter().find_map(|key| {
                            provider[*key]
                                .as_array()?
                                .iter()
                                .find(|m| m["id"] == model)?["name"]
                                .as_str()
                        })
                    })
            })
    }
}
