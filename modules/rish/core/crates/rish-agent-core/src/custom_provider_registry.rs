//! Independently named API providers. Native hosts own URL normalization,
//! secure credentials and the atomic compare-and-swap storage transaction.
//! Retired identities are permanent; malformed storage is never reset here.

use std::collections::BTreeMap;

use serde_json::{json, Map, Value};

use crate::{canonical::MAX_SAFE_INTEGER, provider_policy, workspace_tool::path_control_or_format};

pub const MAX_ACTIVE_PROVIDERS: usize = 16;
pub const MAX_PROVIDERS: usize = 32;
pub const MAX_ACTIVE_MODELS_PER_PROVIDER: usize = 32;
pub const MAX_KNOWN_MODELS: usize = 256;
// Leave room in the strict 256 KiB ABI envelope for a complete replacement
// provider plus CAS metadata. A successful save must remain readable/editable.
pub const MAX_REGISTRY_BYTES: usize = 192 * 1024;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RegistryError {
    Invalid,
    Conflict,
    Capacity,
}

impl RegistryError {
    pub fn code(self) -> &'static str {
        match self {
            Self::Invalid => "E_CUSTOM_PROVIDER_REGISTRY_INVALID",
            Self::Conflict => "E_CUSTOM_PROVIDER_REGISTRY_CONFLICT",
            Self::Capacity => "E_CUSTOM_PROVIDER_REGISTRY_CAPACITY",
        }
    }
}

type Result<T> = std::result::Result<T, RegistryError>;

/// Lowercase canonical UUID spelling, without accepting arbitrary custom
/// harnesses. UUID versions are deliberately not tied to a host UUID codec.
pub fn valid_uuid(id: &str) -> bool {
    id.len() == 36
        && id.bytes().enumerate().all(|(index, byte)| {
            if [8, 13, 18, 23].contains(&index) {
                byte == b'-'
            } else {
                byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)
            }
        })
}

pub fn provider_id_for_harness(harness: &str) -> Option<&str> {
    harness.strip_prefix("custom-").filter(|id| valid_uuid(id))
}

pub fn logical_model_id(provider_id: &str, model_id: &str) -> String {
    format!("custom:{provider_id}:{model_id}")
}

pub fn provider_id_for_model(model: &str) -> Option<&str> {
    let (provider, model) = model.strip_prefix("custom:")?.split_once(':')?;
    (valid_uuid(provider) && valid_uuid(model)).then_some(provider)
}

pub fn model_belongs_to(model: &str, provider_id: &str) -> bool {
    provider_id_for_model(model) == Some(provider_id)
}

fn exact(object: &Map<String, Value>, fields: &[&str]) -> bool {
    object.len() == fields.len() && fields.iter().all(|field| object.contains_key(*field))
}

fn object(value: &Value) -> Result<&Map<String, Value>> {
    value.as_object().ok_or(RegistryError::Invalid)
}

fn string(value: &Value) -> Result<&str> {
    value.as_str().ok_or(RegistryError::Invalid)
}

fn revision(value: &Value) -> Result<u64> {
    value
        .as_u64()
        .filter(|revision| *revision <= MAX_SAFE_INTEGER as u64)
        .ok_or(RegistryError::Invalid)
}

fn model(value: &Value, saving: bool) -> Result<Value> {
    let row = object(value)?;
    if !exact(
        row,
        &["id", "name", "wire_model", "supports_images", "active"],
    ) || !valid_uuid(string(&row["id"])?)
    {
        return Err(RegistryError::Invalid);
    }
    let name = string(&row["name"])?;
    let wire = string(&row["wire_model"])?;
    let active = row["active"].as_bool().ok_or(RegistryError::Invalid)?;
    if name.trim().is_empty()
        || name.encode_utf16().count() > 80
        || name.chars().any(char::is_control)
        || wire.is_empty()
        || wire.len() > 128
        || wire
            .chars()
            .any(|c| c.is_whitespace() || path_control_or_format(c))
        || row["supports_images"].as_bool().is_none()
        || (saving && !active)
    {
        return Err(RegistryError::Invalid);
    }
    Ok(value.clone())
}

fn provider(value: &Value, saving: bool) -> Result<Value> {
    let row = object(value)?;
    if !exact(row, &["id", "configuration", "models", "active"]) || !valid_uuid(string(&row["id"])?)
    {
        return Err(RegistryError::Invalid);
    }
    let id = string(&row["id"])?;
    let active = row["active"].as_bool().ok_or(RegistryError::Invalid)?;
    let config =
        provider_policy::configuration(&row["configuration"]).ok_or(RegistryError::Invalid)?;
    if config["harness_id"] != format!("custom-{id}")
        || string(&config["name"])?.trim().is_empty()
        || (saving && !active)
    {
        return Err(RegistryError::Invalid);
    }
    let rows = row["models"].as_array().ok_or(RegistryError::Invalid)?;
    if rows.len() > MAX_KNOWN_MODELS {
        return Err(RegistryError::Capacity);
    }
    let mut models = BTreeMap::new();
    let mut mappings = Map::new();
    for raw in rows {
        let model = model(raw, saving)?;
        let model_id = string(&model["id"])?;
        if model["active"] == true {
            if !active {
                return Err(RegistryError::Invalid);
            }
            mappings.insert(logical_model_id(id, model_id), model["wire_model"].clone());
        }
        if models.insert(model_id.to_owned(), model).is_some() {
            return Err(RegistryError::Invalid);
        }
    }
    if mappings.len() > MAX_ACTIVE_MODELS_PER_PROVIDER {
        return Err(RegistryError::Capacity);
    }
    if config["model_mappings"] != Value::Object(mappings) {
        return Err(RegistryError::Invalid);
    }
    Ok(json!({"id": id, "configuration": config,
        "models": models.into_values().collect::<Vec<_>>(), "active": active}))
}

fn capacity(providers: &[Value]) -> Result<()> {
    if providers.len() > MAX_PROVIDERS
        || providers.iter().filter(|p| p["active"] == true).count() > MAX_ACTIVE_PROVIDERS
        || providers
            .iter()
            .map(|p| p["models"].as_array().map_or(0, Vec::len))
            .sum::<usize>()
            > MAX_KNOWN_MODELS
    {
        return Err(RegistryError::Capacity);
    }
    Ok(())
}

pub fn read_registry(value: &Value) -> Result<Value> {
    if value.is_null() {
        return Ok(json!({"schema_version": 1, "revision": 0, "providers": []}));
    }
    let row = object(value)?;
    if !exact(row, &["schema_version", "revision", "providers"])
        || row["schema_version"].as_u64() != Some(1)
    {
        return Err(RegistryError::Invalid);
    }
    let revision = revision(&row["revision"])?;
    let rows = row["providers"].as_array().ok_or(RegistryError::Invalid)?;
    if rows.len() > MAX_PROVIDERS {
        return Err(RegistryError::Capacity);
    }
    let mut providers = BTreeMap::new();
    for raw in rows {
        let provider = provider(raw, false)?;
        if providers
            .insert(string(&provider["id"])?.to_owned(), provider)
            .is_some()
        {
            return Err(RegistryError::Invalid);
        }
    }
    let providers = providers.into_values().collect::<Vec<_>>();
    capacity(&providers)?;
    bounded_registry(json!({"schema_version": 1, "revision": revision, "providers": providers}))
}

fn active_payload(provider: &Value) -> Value {
    let mut result = provider.clone();
    result["models"] = json!(provider["models"]
        .as_array()
        .expect("validated models")
        .iter()
        .filter(|row| row["active"] == true)
        .cloned()
        .collect::<Vec<_>>());
    result
}

fn save(registry: &Value, expected: u64, raw: &Value) -> Result<Value> {
    let registry = read_registry(registry)?;
    let mut new = provider(raw, true)?;
    let current = revision(&registry["revision"])?;
    let mut providers = registry["providers"]
        .as_array()
        .ok_or(RegistryError::Invalid)?
        .clone();
    let index = providers.iter().position(|row| row["id"] == new["id"]);
    if expected != current {
        // A lost native reply can be retried only with the same identity and
        // complete active payload, and at exactly the immediately next revision.
        if expected.checked_add(1) == Some(current)
            && index.is_some_and(|index| active_payload(&providers[index]) == new)
        {
            return Ok(registry);
        }
        return Err(RegistryError::Conflict);
    }
    if let Some(index) = index {
        let previous = &providers[index];
        if previous["active"] != true {
            return Err(RegistryError::Invalid);
        }
        let mut models = new["models"]
            .as_array()
            .ok_or(RegistryError::Invalid)?
            .clone();
        for old in previous["models"]
            .as_array()
            .ok_or(RegistryError::Invalid)?
        {
            if let Some(found) = models.iter().find(|row| row["id"] == old["id"]) {
                if old["active"] != true || old["wire_model"] != found["wire_model"] {
                    return Err(RegistryError::Invalid);
                }
            } else {
                let mut retired = old.clone();
                retired["active"] = json!(false);
                models.push(retired);
            }
        }
        models.sort_by(|a, b| a["id"].as_str().cmp(&b["id"].as_str()));
        new["models"] = json!(models);
        providers[index] = new;
    } else {
        providers.push(new);
    }
    finish(current, providers)
}

fn remove(registry: &Value, expected: u64, provider_id: &str) -> Result<Value> {
    if !valid_uuid(provider_id) {
        return Err(RegistryError::Invalid);
    }
    let registry = read_registry(registry)?;
    let current = revision(&registry["revision"])?;
    let mut providers = registry["providers"]
        .as_array()
        .ok_or(RegistryError::Invalid)?
        .clone();
    let index = providers
        .iter()
        .position(|row| row["id"] == provider_id)
        .ok_or(RegistryError::Invalid)?;
    if expected != current {
        if expected.checked_add(1) == Some(current) && providers[index]["active"] == false {
            return Ok(registry);
        }
        return Err(RegistryError::Conflict);
    }
    if providers[index]["active"] != true {
        return Err(RegistryError::Invalid);
    }
    providers[index]["active"] = json!(false);
    providers[index]["configuration"]["model_mappings"] = json!({});
    for model in providers[index]["models"]
        .as_array_mut()
        .ok_or(RegistryError::Invalid)?
    {
        model["active"] = json!(false);
    }
    finish(current, providers)
}

fn finish(current: u64, mut providers: Vec<Value>) -> Result<Value> {
    capacity(&providers)?;
    let revision = current
        .checked_add(1)
        .filter(|r| *r <= MAX_SAFE_INTEGER as u64)
        .ok_or(RegistryError::Capacity)?;
    providers.sort_by(|a, b| a["id"].as_str().cmp(&b["id"].as_str()));
    bounded_registry(json!({"schema_version": 1, "revision": revision, "providers": providers}))
}

fn bounded_registry(value: Value) -> Result<Value> {
    if value.to_string().len() > MAX_REGISTRY_BYTES {
        return Err(RegistryError::Capacity);
    }
    Ok(value)
}

/// Both active and retired rows can populate host session-validation facts.
/// Dispatch uses require_active=true and must still compare captured bindings.
pub fn model_routes(registry: &Value, include_retired: bool) -> Result<Vec<Value>> {
    let registry = read_registry(registry)?;
    let mut result = Vec::new();
    for provider in registry["providers"]
        .as_array()
        .ok_or(RegistryError::Invalid)?
    {
        let id = string(&provider["id"])?;
        let config = &provider["configuration"];
        for model in provider["models"]
            .as_array()
            .ok_or(RegistryError::Invalid)?
        {
            let active = provider["active"] == true && model["active"] == true;
            if active || include_retired {
                result.push(json!({"id": logical_model_id(id, string(&model["id"])?),
                    "provider_id": config["harness_id"], "harness_id": config["harness_id"],
                    "provider_name": config["name"], "name": model["name"],
                    "wire_model": model["wire_model"], "supports_images": model["supports_images"],
                    "active": active, "configuration": config}));
            }
        }
    }
    Ok(result)
}

/// Exact non-secret envelopes, exposed through the existing provider-policy ABI.
pub fn reduce(request: &Map<String, Value>) -> Result<Value> {
    match request.get("op").and_then(Value::as_str) {
        Some("registry_read") if exact(request, &["op", "registry"]) => {
            read_registry(&request["registry"])
        }
        Some("registry_save")
            if exact(
                request,
                &["op", "registry", "expected_revision", "provider"],
            ) =>
        {
            save(
                &request["registry"],
                revision(&request["expected_revision"])?,
                &request["provider"],
            )
        }
        Some("registry_remove")
            if exact(
                request,
                &["op", "registry", "expected_revision", "provider_id"],
            ) =>
        {
            remove(
                &request["registry"],
                revision(&request["expected_revision"])?,
                string(&request["provider_id"])?,
            )
        }
        Some("registry_models") if exact(request, &["op", "registry", "include_retired"]) => {
            Ok(json!(model_routes(
                &request["registry"],
                request["include_retired"]
                    .as_bool()
                    .ok_or(RegistryError::Invalid)?
            )?))
        }
        Some("registry_route")
            if exact(request, &["op", "registry", "model_id", "require_active"]) =>
        {
            let id = string(&request["model_id"])?;
            let active = request["require_active"]
                .as_bool()
                .ok_or(RegistryError::Invalid)?;
            Ok(model_routes(&request["registry"], !active)?
                .into_iter()
                .find(|model| model["id"] == id)
                .unwrap_or(Value::Null))
        }
        _ => Err(RegistryError::Invalid),
    }
}

#[cfg(test)]
#[path = "custom_provider_registry_tests.rs"]
mod tests;
