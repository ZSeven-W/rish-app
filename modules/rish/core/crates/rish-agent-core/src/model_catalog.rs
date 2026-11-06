//! Shared DSH model metadata policy. Native hosts own reading and atomically
//! writing their preferences; this module never performs IO or repairs storage.

use std::collections::{BTreeMap, BTreeSet, HashSet};

use serde_json::{json, Map, Value};

use crate::{strict_json, workspace_tool::path_control_or_format};

pub const MAX_ACTIVE_MODELS: usize = 32;
pub const MAX_RETIRED_MODELS: usize = 256;

/// Immutable provider identities. Custom DSH entries may replace DSH metadata,
/// but may not take another harness's built-in model identifier.
pub const BUILTIN_MODELS: &[(&str, &str)] = &[
    ("deepseek-v4-flash", "dsh"),
    ("deepseek-v4-pro", "dsh"),
    ("deepseek-v4-flash-vision-exp", "dsh"),
    ("claude-sonnet-5", "claude-code"),
    ("claude-opus-5", "claude-code"),
    ("claude-haiku-4-5-20251001", "claude-code"),
    ("claude-fable-5-1", "claude-code"),
    ("gpt-5.6", "codex"),
    ("gpt-5.6-mini", "codex"),
    ("gpt-5.6-nano", "codex"),
    ("GLM-5.3", "glm"),
    ("GLM-5.3-Flash", "glm"),
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CatalogError;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ModelEntry {
    pub id: String,
    pub name: String,
    pub supports_images: bool,
}

impl ModelEntry {
    pub fn to_json(&self) -> Value {
        json!({"id": self.id, "name": self.name, "supports_images": self.supports_images})
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ModelCatalog {
    models: Vec<ModelEntry>,
    retired_models: Vec<ModelEntry>,
}

impl ModelCatalog {
    pub fn to_json(&self) -> Value {
        json!({
            "schema_version": 1,
            "models": self.models.iter().map(ModelEntry::to_json).collect::<Vec<_>>(),
            "retired_models": self.retired_models.iter().map(ModelEntry::to_json).collect::<Vec<_>>(),
        })
    }

    pub fn models(&self) -> &[ModelEntry] {
        &self.models
    }

    pub fn retired_models(&self) -> &[ModelEntry] {
        &self.retired_models
    }

    /// Active metadata wins over retired metadata. A built-in DSH model stays
    /// recognizable when loading an older catalog that omitted it altogether.
    pub fn lookup(&self, model: &str) -> Option<ModelEntry> {
        self.models
            .iter()
            .chain(self.retired_models.iter())
            .find(|entry| entry.id == model)
            .cloned()
            .or_else(|| default_models().into_iter().find(|entry| entry.id == model))
    }

    pub fn is_known(&self, model: &str) -> bool {
        self.lookup(model).is_some()
    }

    pub fn supports_images(&self, model: &str) -> bool {
        self.lookup(model)
            .is_some_and(|entry| entry.supports_images)
    }
}

pub fn builtin_harness(model: &str) -> Option<&'static str> {
    BUILTIN_MODELS
        .iter()
        .find_map(|(id, harness)| (*id == model).then_some(*harness))
}

/// A JSON object keyed by harness, containing its immutable model identifiers.
pub fn builtin_models() -> Value {
    let mut result = Map::new();
    for (model, harness) in BUILTIN_MODELS {
        result
            .entry(harness.to_string())
            .or_insert_with(|| Value::Array(Vec::new()))
            .as_array_mut()
            .expect("array inserted above")
            .push(Value::String(model.to_string()));
    }
    Value::Object(result)
}

/// Discovery remains owned by the host. It cannot change the immutable
/// provider identity of a built-in or custom catalog entry.
pub fn model_harness(
    catalog: &ModelCatalog,
    model: &str,
    discovered_models: &[String],
) -> Option<&'static str> {
    // Old opaque DSH IDs stay readable, but an exact independent-provider
    // namespace can only be routed by its registry, including on collision.
    if crate::custom_provider_registry::provider_id_for_model(model).is_some() {
        return None;
    }
    builtin_harness(model)
        .or_else(|| catalog.is_known(model).then_some("dsh"))
        .or_else(|| {
            discovered_models
                .iter()
                .any(|id| id == model && valid_codex_discovery_id(id))
                .then_some("codex")
        })
}

/// Complete identity set for session validation, including retired choices.
/// The caller must provide a valid catalog; incomplete storage never produces
/// an apparently complete set. Ordering is deterministic across both hosts.
pub fn supported_models(catalog: &ModelCatalog, discovered_models: &[String]) -> Vec<String> {
    BUILTIN_MODELS
        .iter()
        .map(|(model, _)| model.to_string())
        .chain(catalog.models.iter().map(|entry| entry.id.clone()))
        .chain(catalog.retired_models.iter().map(|entry| entry.id.clone()))
        .chain(
            discovered_models
                .iter()
                .filter(|id| valid_codex_discovery_id(id))
                .cloned(),
        )
        .filter(|model| crate::custom_provider_registry::provider_id_for_model(model).is_none())
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect()
}

fn default_models() -> Vec<ModelEntry> {
    [
        ("deepseek-v4-flash", "V4 Flash", true),
        ("deepseek-v4-pro", "V4 Pro", false),
        ("deepseek-v4-flash-vision-exp", "Flash Exp", true),
    ]
    .into_iter()
    .map(|(id, name, supports_images)| ModelEntry {
        id: id.into(),
        name: name.into(),
        supports_images,
    })
    .collect()
}

pub fn default_catalog() -> ModelCatalog {
    ModelCatalog {
        models: Vec::new(),
        retired_models: Vec::new(),
    }
}

fn exact_keys(value: &Map<String, Value>, expected: &[&str]) -> bool {
    value.len() == expected.len() && expected.iter().all(|key| value.contains_key(*key))
}

fn schema_one(value: Option<&Value>) -> bool {
    // Do not accept true, 1.0 or "1" as schema versions. This is the existing
    // Android persistence contract and avoids Objective-C NSNumber coercion.
    value.and_then(Value::as_u64) == Some(1)
}

fn model_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value.as_bytes()[0].is_ascii_alphanumeric()
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"._:/-".contains(&byte))
}

pub fn valid_codex_discovery_id(value: &str) -> bool {
    if value.is_empty() || value.len() > 80 {
        return false;
    }
    let suffix = if let Some(suffix) = value
        .strip_prefix("gpt-")
        .or_else(|| value.strip_prefix("codex-"))
    {
        if !suffix
            .as_bytes()
            .first()
            .is_some_and(u8::is_ascii_alphanumeric)
        {
            return false;
        }
        suffix
    } else if value.starts_with('o') && value.as_bytes().get(1).is_some_and(u8::is_ascii_digit) {
        &value[1..]
    } else {
        return false;
    };
    suffix
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(&byte))
}

fn discovered_models(value: &Value) -> Result<Vec<String>, CatalogError> {
    let values = value.as_array().ok_or(CatalogError)?;
    if values.len() > 256 {
        return Err(CatalogError);
    }
    values
        .iter()
        .map(|value| {
            value
                .as_str()
                .filter(|id| valid_codex_discovery_id(id))
                .map(str::to_owned)
                .ok_or(CatalogError)
        })
        .collect()
}

/// Validate and trim labels without changing model identities. Limits use
/// UTF-16 units to match both native stores, rather than UTF-8 bytes or scalars.
pub fn validate_models(value: &Value, retired: bool) -> Result<Vec<ModelEntry>, CatalogError> {
    validate_models_for(value, retired, LabelMode::NewInput, "dsh", &[])
}

/// Shared row validation for explicitly configured built-in providers.
pub(crate) fn validate_provider_models(
    value: &Value,
    harness: &str,
    retired: bool,
    stored: bool,
) -> Result<Vec<ModelEntry>, CatalogError> {
    if !crate::provider_model_catalog::HARNESSES.contains(&harness) {
        return Err(CatalogError);
    }
    validate_models_for(
        value,
        retired,
        if stored {
            LabelMode::Stored
        } else {
            LabelMode::NewInput
        },
        harness,
        &[],
    )
}

pub(crate) fn validate_provider_save_models(
    value: &Value,
    harness: &str,
    existing: &[ModelEntry],
) -> Result<Vec<ModelEntry>, CatalogError> {
    if !crate::provider_model_catalog::HARNESSES.contains(&harness) {
        return Err(CatalogError);
    }
    validate_models_for(value, false, LabelMode::NewInput, harness, existing)
}

#[derive(Clone, Copy)]
enum LabelMode {
    NewInput,
    Stored,
}

fn validate_models_for(
    value: &Value,
    retired: bool,
    mode: LabelMode,
    harness: &str,
    existing: &[ModelEntry],
) -> Result<Vec<ModelEntry>, CatalogError> {
    let rows = value.as_array().ok_or(CatalogError)?;
    let maximum = if retired {
        MAX_RETIRED_MODELS
    } else {
        MAX_ACTIVE_MODELS
    };
    if rows.len() > maximum {
        return Err(CatalogError);
    }
    let mut seen = HashSet::new();
    rows.iter()
        .map(|value| {
            let row = value.as_object().ok_or(CatalogError)?;
            if !exact_keys(row, &["id", "name", "supports_images"]) {
                return Err(CatalogError);
            }
            let id = row.get("id").and_then(Value::as_str).ok_or(CatalogError)?;
            let raw_name = row
                .get("name")
                .and_then(Value::as_str)
                .ok_or(CatalogError)?;
            let previous = existing.iter().find(|entry| entry.id == id);
            // Existing opaque IDs retain ownership, and unchanged legacy
            // labels keep their original Unicode spelling. Edited/new labels
            // still obey today's input rules.
            let label_mode = if previous.is_some_and(|entry| entry.name == raw_name) {
                LabelMode::Stored
            } else {
                mode
            };
            let name = match label_mode {
                LabelMode::NewInput => raw_name.trim(),
                // Older Android catalogs accepted Cf, including ZWJ in emoji.
                // Preserve that metadata verbatim when reading or retiring it;
                // compatibility never relaxes the rules for new input.
                LabelMode::Stored => raw_name,
            };
            let invalid_character = match label_mode {
                LabelMode::NewInput => name.chars().any(path_control_or_format),
                LabelMode::Stored => name.chars().any(char::is_control),
            };
            let images = row
                .get("supports_images")
                .and_then(Value::as_bool)
                .ok_or(CatalogError)?;
            if !model_id(id)
                || (matches!(mode, LabelMode::NewInput)
                    && id.starts_with("custom:")
                    && previous.is_none())
                || !seen.insert(id)
                || builtin_harness(id).is_some_and(|owner| owner != harness)
                || name.trim().is_empty()
                || name.encode_utf16().count() > 80
                || invalid_character
            {
                return Err(CatalogError);
            }
            Ok(ModelEntry {
                id: id.into(),
                name: name.into(),
                supports_images: images,
            })
        })
        .collect()
}

/// Only an absent preference (JSON null) selects an empty active catalog. Invalid persisted
/// data is an error, including when the caller only wants a capability lookup.
pub fn read_catalog(value: &Value) -> Result<ModelCatalog, CatalogError> {
    if value.is_null() {
        return Ok(default_catalog());
    }
    let object = value.as_object().ok_or(CatalogError)?;
    if !exact_keys(object, &["schema_version", "models", "retired_models"])
        || !schema_one(object.get("schema_version"))
    {
        return Err(CatalogError);
    }
    Ok(ModelCatalog {
        models: validate_models_for(&object["models"], false, LabelMode::Stored, "dsh", &[])?,
        retired_models: validate_models_for(
            &object["retired_models"],
            true,
            LabelMode::Stored,
            "dsh",
            &[],
        )?,
    })
}

/// Merge active metadata into a catalog without losing identities referenced
/// by historical sessions. No input is mutated if validation or limits fail.
pub fn save_catalog(old: &Value, request: &Value) -> Result<ModelCatalog, CatalogError> {
    let object = request.as_object().ok_or(CatalogError)?;
    if !exact_keys(object, &["schema_version", "models"])
        || !schema_one(object.get("schema_version"))
    {
        return Err(CatalogError);
    }
    let models = validate_models(&object["models"], false)?;
    let old = read_catalog(old)?;
    let mut known = BTreeMap::new();
    for entry in default_models()
        .into_iter()
        .chain(old.retired_models)
        .chain(old.models)
    {
        known.insert(entry.id.clone(), entry);
    }
    for entry in &models {
        known.remove(&entry.id);
    }
    if known.len() > MAX_RETIRED_MODELS {
        return Err(CatalogError);
    }
    Ok(ModelCatalog {
        models,
        retired_models: known.into_values().collect(),
    })
}

/// JSON policy entry point. Every operation has exact keys and returns the
/// usual `{ok,value}` or a static error with no caller-controlled error text.
pub fn reduce_json(input: &str) -> String {
    let result = (|| {
        let request = strict_json::parse_arguments_bounded(
            input,
            crate::provider_model_catalog::MAX_PROVIDER_ARGUMENT_BYTES,
        )
        .ok_or(CatalogError)?;
        let operation = request
            .get("op")
            .and_then(Value::as_str)
            .ok_or(CatalogError)?;
        if operation.starts_with("provider_") {
            return crate::provider_model_catalog::reduce(&request);
        }
        if input.len() > strict_json::MAX_ARGUMENTS_BYTES {
            return Err(CatalogError);
        }
        match operation {
            "default" | "builtin_models" if exact_keys(&request, &["op"]) => {
                Ok(if operation == "default" {
                    default_catalog().to_json()
                } else {
                    builtin_models()
                })
            }
            "validate_models" if exact_keys(&request, &["op", "models", "retired"]) => {
                let retired = request["retired"].as_bool().ok_or(CatalogError)?;
                Ok(Value::Array(
                    validate_models(&request["models"], retired)?
                        .iter()
                        .map(ModelEntry::to_json)
                        .collect(),
                ))
            }
            "read" if exact_keys(&request, &["op", "catalog"]) => {
                Ok(read_catalog(&request["catalog"])?.to_json())
            }
            "save" if exact_keys(&request, &["op", "catalog", "request"]) => {
                Ok(save_catalog(&request["catalog"], &request["request"])?.to_json())
            }
            "supported_models" if exact_keys(&request, &["op", "catalog", "discovered_models"]) => {
                let discovered = discovered_models(&request["discovered_models"])?;
                let catalog = read_catalog(&request["catalog"])?;
                Ok(json!(supported_models(&catalog, &discovered)))
            }
            "lookup" | "is_known" | "supports_images"
                if exact_keys(&request, &["op", "catalog", "model"]) =>
            {
                let catalog = read_catalog(&request["catalog"])?;
                let model = request["model"].as_str().ok_or(CatalogError)?;
                Ok(match operation {
                    "lookup" => catalog
                        .lookup(model)
                        .map(|entry| entry.to_json())
                        .unwrap_or(Value::Null),
                    "is_known" => Value::Bool(catalog.is_known(model)),
                    _ => Value::Bool(catalog.supports_images(model)),
                })
            }
            "harness_for_model"
                if exact_keys(&request, &["op", "catalog", "model", "discovered_models"]) =>
            {
                let model = request["model"].as_str().ok_or(CatalogError)?;
                let discovered = discovered_models(&request["discovered_models"])?;
                // Immutable identities do not depend on mutable DSH metadata.
                // Dynamic discovery must still read the catalog: the same ID
                // could already be a custom DSH model in damaged storage.
                if let Some(harness) = builtin_harness(model) {
                    return Ok(Value::String(harness.into()));
                }
                let catalog = read_catalog(&request["catalog"])?;
                Ok(model_harness(&catalog, model, &discovered)
                    .map(|harness| Value::String(harness.into()))
                    .unwrap_or(Value::Null))
            }
            _ => Err(CatalogError),
        }
    })();
    match result {
        Ok(value) => json!({"ok": true, "value": value}).to_string(),
        Err(CatalogError) => json!({"ok": false, "error": "E_MODEL_CATALOG_INVALID"}).to_string(),
    }
}

#[cfg(test)]
#[path = "model_catalog_tests.rs"]
mod tests;
