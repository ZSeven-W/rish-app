//! Install the native provider registry without changing conversation state.
//! Current choices and durable historical identities have separate lifetimes.

use std::collections::BTreeMap;

use crate::{custom_provider_registry as registry, model::decode, Model, Result, ShellState};
use rish_agent_core::{provider_policy, session_schema::Env};
use serde_json::{json, Value};

type Names = BTreeMap<String, String>;

impl ShellState {
    /// Bootstrap may install identities before loading a native snapshot.
    /// Refresh is atomic and never changes the selected model or conversation.
    pub fn apply_custom_providers(&mut self, value: Value) -> Result<()> {
        if self.pending.is_some() || self.sending.is_some() || self.agent_run.is_some() {
            return Err("Resolve the pending native transaction before changing providers".into());
        }
        let registry =
            registry::read_registry(&decode(value)?).map_err(|error| error.code().to_owned())?;
        validate_refresh(&self.custom_registry, &registry)?;
        let (catalog, environment, providers, names) =
            merge(&registry, self.catalog.clone(), self.environment.clone())?;
        self.catalog = catalog;
        self.environment = environment;
        self.custom_registry = registry;
        self.custom_provider_names = providers;
        self.custom_model_names = names;
        Ok(())
    }

    /// Custom labels are registry metadata; they do not infer a provider from
    /// arbitrary model strings or change built-in display-name policy.
    pub fn provider_display_name(&self, harness: &str) -> Option<&str> {
        self.custom_provider_names.get(harness).map(String::as_str)
    }

    pub fn custom_model_display_name(&self, model: &str) -> Option<&str> {
        self.custom_model_names.get(model).map(String::as_str)
    }
}

fn routes(value: &Value) -> Result<Vec<Value>> {
    registry::model_routes(value, true).map_err(|error| error.code().to_owned())
}

fn validate_refresh(previous: &Value, next: &Value) -> Result<()> {
    if next["revision"].as_u64() < previous["revision"].as_u64()
        || (next["revision"] == previous["revision"] && next != previous)
    {
        return Err("Custom provider registry revision conflicts with the loaded registry".into());
    }
    for old in previous["providers"]
        .as_array()
        .ok_or("Invalid loaded provider registry")?
    {
        let new = next["providers"]
            .as_array()
            .and_then(|providers| {
                providers
                    .iter()
                    .find(|provider| provider["id"] == old["id"])
            })
            .ok_or("Custom provider registry lost a historical provider identity")?;
        if old["active"] == false && new["active"] != false {
            return Err("Custom provider registry reactivated a retired provider identity".into());
        }
    }
    let current = routes(next)?;
    for old in routes(previous)? {
        let Some(new) = current.iter().find(|row| row["id"] == old["id"]) else {
            return Err("Custom provider registry lost a historical identity".into());
        };
        if new["wire_model"] != old["wire_model"]
            || (old["active"] == false && new["active"] != false)
        {
            return Err("Custom provider registry changed an immutable model identity".into());
        }
    }
    Ok(())
}

/// Reused after a DSH catalog refresh so its environment rebuild cannot erase
/// the independent registry's active or retired model/provider identities.
pub(crate) fn merge(
    registry: &Value,
    mut catalog: Vec<Model>,
    mut environment: Env,
) -> Result<(Vec<Model>, Env, Names, Names)> {
    let routes = routes(registry)?;
    catalog.retain(|model| registry::provider_id_for_harness(&model.harness).is_none());
    let old_custom: Vec<_> = environment
        .harness_by_model
        .iter()
        .filter(|(_, harness)| registry::provider_id_for_harness(harness).is_some())
        .map(|(id, _)| id.clone())
        .collect();
    for id in old_custom {
        environment.supported_models.retain(|model| *model != id);
        environment.harness_by_model.remove(&id);
        environment.host_by_model.remove(&id);
    }
    environment
        .provider_ids
        .retain(|id| registry::provider_id_for_harness(id).is_none());
    let mut providers = Names::new();
    let mut names = Names::new();
    for provider in registry["providers"]
        .as_array()
        .ok_or("Invalid native provider registry")?
    {
        let configuration = &provider["configuration"];
        endpoint_host(&configuration["endpoint_url"]).ok_or("Invalid custom provider endpoint")?;
        let harness = configuration["harness_id"]
            .as_str()
            .ok_or("Missing custom provider identity")?;
        let name = configuration["name"]
            .as_str()
            .ok_or("Missing custom provider label")?;
        providers.insert(harness.into(), name.into());
        environment.provider_ids.push(harness.into());
    }
    for row in routes {
        let id = row["id"].as_str().ok_or("Missing custom model identity")?;
        let harness = row["harness_id"]
            .as_str()
            .ok_or("Missing custom provider identity")?;
        let name = row["name"].as_str().ok_or("Missing custom model label")?;
        let provider = row["provider_name"]
            .as_str()
            .ok_or("Missing custom provider label")?;
        let host = endpoint_host(&row["configuration"]["endpoint_url"])
            .ok_or("Invalid custom provider endpoint")?;
        if catalog.iter().any(|model| model.id == id)
            || environment.harness_by_model.contains_key(id)
            || environment.supported_models.iter().any(|model| model == id)
        {
            return Err("Custom provider model conflicts with an existing identity".into());
        }
        environment.supported_models.push(id.into());
        environment
            .harness_by_model
            .insert(id.into(), harness.into());
        environment.host_by_model.insert(id.into(), host);
        if !environment
            .provider_ids
            .iter()
            .any(|known| known == harness)
        {
            environment.provider_ids.push(harness.into());
        }
        providers.insert(harness.into(), provider.into());
        names.insert(id.into(), name.into());
        if row["active"] == true {
            catalog.push(Model {
                id: id.into(),
                name: name.into(),
                harness: harness.into(),
            });
        }
    }
    Ok((catalog, environment, providers, names))
}

fn endpoint_host(value: &Value) -> Option<String> {
    let endpoint = value.as_str()?;
    if endpoint.len() > 2048 {
        return None;
    }
    let url = url::Url::parse(endpoint).ok()?;
    let host = url.host_str()?.trim_matches(['[', ']']).to_lowercase();
    let local = matches!(host.as_str(), "localhost" | "127.0.0.1" | "::1");
    if (url.scheme() != "https" && !(url.scheme() == "http" && local))
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
        || url.port() == Some(0)
    {
        return None;
    }
    Some(host)
}

/// Built-in bindings retain their native-attested compatibility contract.
/// Independent bindings additionally require an explicitly registered logical
/// model and self-consistent captured v1 identity, including historical URLs.
pub(crate) fn binding_valid(record: &Value, environment: &Env) -> Option<bool> {
    let binding = record.get("provider_configuration")?;
    let model = record.get("model").and_then(Value::as_str);
    let harness = binding.get("harness_id").and_then(Value::as_str);
    let custom = model.is_some_and(|model| registry::provider_id_for_model(model).is_some())
        || harness.is_some_and(|harness| harness.starts_with("custom-"));
    if !custom {
        return None;
    }
    let (Some(model), Some(harness)) = (model, harness) else {
        return Some(false);
    };
    if environment.harness_by_model.get(model).map(String::as_str) != Some(harness)
        || !environment
            .supported_models
            .iter()
            .any(|known| known == model)
        || registry::provider_id_for_harness(harness)
            .is_none_or(|id| !registry::model_belongs_to(model, id))
        || endpoint_host(&binding["endpoint_url"]).is_none()
    {
        return Some(false);
    }
    let answer: Value = serde_json::from_str(&provider_policy::reduce_json(
        &json!({
            "op":"validate_binding", "binding":binding, "logical_model":model,
            "model_harness":harness, "endpoint_is_canonical":true
        })
        .to_string(),
    ))
    .ok()?;
    Some(answer["ok"] == true && answer["value"] == true)
}

pub(crate) fn validate_native_bindings(value: &Value, environment: &Env) -> Result<()> {
    if binding_valid(value, environment) == Some(false) {
        return Err("Native snapshot has an unknown or invalid custom provider binding".into());
    }
    match value {
        Value::Array(values) => {
            for value in values {
                validate_native_bindings(value, environment)?;
            }
        }
        Value::Object(values) => {
            for value in values.values() {
                validate_native_bindings(value, environment)?;
            }
        }
        _ => {}
    }
    Ok(())
}

#[cfg(test)]
#[path = "custom_provider_catalog_tests.rs"]
mod tests;
