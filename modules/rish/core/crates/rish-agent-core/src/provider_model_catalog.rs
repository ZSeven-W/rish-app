//! Provider-owned model choices. Historical routing and active choices are
//! separate: fixed legacy identities never manufacture selectable model rows.
use crate::model_catalog::{self, CatalogError, ModelEntry};
use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, HashSet};

pub const HARNESSES: [&str; 4] = ["dsh", "claude-code", "codex", "glm"];
pub const MAX_RETIRED_MODELS: usize = 256;
/// Includes both the registry and explicit legacy migration context.
pub const MAX_PROVIDER_ARGUMENT_BYTES: usize = 512 * 1024;

#[derive(Clone)]
struct Provider {
    harness: String,
    models: Vec<ModelEntry>,
    retired: Vec<ModelEntry>,
}
impl Provider {
    fn json(&self) -> Value {
        json!({"harness_id":self.harness,"models":self.models.iter().map(ModelEntry::to_json).collect::<Vec<_>>(),
            "retired_models":self.retired.iter().map(ModelEntry::to_json).collect::<Vec<_>>()})
    }
}
struct Registry {
    revision: u64,
    providers: Vec<Provider>,
}
impl Registry {
    fn json(&self) -> Value {
        json!({"schema_version":1,"revision":self.revision,
            "providers":self.providers.iter().map(Provider::json).collect::<Vec<_>>()})
    }
}
fn exact(value: &Map<String, Value>, keys: &[&str]) -> bool {
    value.len() == keys.len() && keys.iter().all(|key| value.contains_key(*key))
}
fn revision(value: &Value) -> Result<u64, CatalogError> {
    value
        .as_u64()
        .filter(|v| *v <= crate::schema::MAX_SAFE_INTEGER)
        .ok_or(CatalogError)
}
fn known_owner(
    legacy: &model_catalog::ModelCatalog,
    model: &str,
    discovered: &[String],
) -> Option<String> {
    model_catalog::model_harness(legacy, model, discovered).map(str::to_owned)
}
fn parse(raw: &Value, legacy_raw: &Value, discovered: &[String]) -> Result<Registry, CatalogError> {
    if discovered.len() > 256
        || discovered
            .iter()
            .any(|id| !model_catalog::valid_codex_discovery_id(id))
    {
        return Err(CatalogError);
    }
    let legacy = model_catalog::read_catalog(legacy_raw)?;
    let mut entries = BTreeMap::<String, Provider>::new();
    let version = if raw.is_null() {
        0
    } else {
        let object = raw.as_object().ok_or(CatalogError)?;
        if !exact(object, &["schema_version", "revision", "providers"])
            || object["schema_version"].as_u64() != Some(1)
        {
            return Err(CatalogError);
        }
        let rows = object["providers"]
            .as_array()
            .filter(|rows| rows.len() <= HARNESSES.len())
            .ok_or(CatalogError)?;
        for row in rows {
            let row = row.as_object().ok_or(CatalogError)?;
            if !exact(row, &["harness_id", "models", "retired_models"]) {
                return Err(CatalogError);
            }
            let harness = row["harness_id"]
                .as_str()
                .filter(|h| HARNESSES.contains(h))
                .ok_or(CatalogError)?;
            if entries.contains_key(harness) {
                return Err(CatalogError);
            }
            entries.insert(
                harness.into(),
                Provider {
                    harness: harness.into(),
                    models: model_catalog::validate_provider_models(
                        &row["models"],
                        harness,
                        false,
                        true,
                    )?,
                    retired: model_catalog::validate_provider_models(
                        &row["retired_models"],
                        harness,
                        true,
                        true,
                    )?,
                },
            );
        }
        revision(&object["revision"])?
    };
    // Migration is a read projection. Only explicitly saved legacy rows are
    // copied; a missing legacy preference is empty and never injects defaults.
    // Exact independent-provider IDs in very old opaque DSH catalogs cannot
    // claim that namespace, but must not hide unrelated legacy records.
    entries.entry("dsh".into()).or_insert_with(|| Provider {
        harness: "dsh".into(),
        models: legacy
            .models()
            .iter()
            .filter(|m| crate::custom_provider_registry::provider_id_for_model(&m.id).is_none())
            .cloned()
            .collect(),
        retired: legacy
            .retired_models()
            .iter()
            .filter(|m| {
                crate::custom_provider_registry::provider_id_for_model(&m.id).is_none()
                    && !legacy.models().iter().any(|active| active.id == m.id)
            })
            .cloned()
            .collect(),
    });
    let providers: Vec<_> = HARNESSES
        .iter()
        .map(|harness| {
            entries.remove(*harness).unwrap_or_else(|| Provider {
                harness: (*harness).into(),
                models: Vec::new(),
                retired: Vec::new(),
            })
        })
        .collect();
    let mut seen = HashSet::new();
    let mut retired = 0;
    for provider in &providers {
        retired += provider.retired.len();
        for model in provider.models.iter().chain(&provider.retired) {
            if !seen.insert(&model.id)
                || crate::custom_provider_registry::provider_id_for_model(&model.id).is_some()
                || known_owner(&legacy, &model.id, &[])
                    .is_some_and(|owner| owner != provider.harness)
            {
                return Err(CatalogError);
            }
        }
    }
    if retired > MAX_RETIRED_MODELS {
        return Err(CatalogError);
    }
    Ok(Registry {
        revision: version,
        providers,
    })
}

/// Read without writing or selecting a model. All four provider rows are
/// returned in stable order, including providers with no configured models.
pub fn read_registry(
    raw: &Value,
    legacy: &Value,
    discovered: &[String],
) -> Result<Value, CatalogError> {
    Ok(parse(raw, legacy, discovered)?.json())
}

/// The caller persists this value atomically while holding its native lock.
/// Exact retries return the latest registry without reviving removed models.
pub fn save_registry(
    raw: &Value,
    request: &Value,
    legacy: &Value,
    discovered: &[String],
) -> Result<Value, CatalogError> {
    let request = request.as_object().ok_or(CatalogError)?;
    if !exact(
        request,
        &[
            "schema_version",
            "expected_revision",
            "harness_id",
            "models",
        ],
    ) || request["schema_version"].as_u64() != Some(1)
    {
        return Err(CatalogError);
    }
    let expected = revision(&request["expected_revision"])?;
    let harness = request["harness_id"]
        .as_str()
        .filter(|h| HARNESSES.contains(h))
        .ok_or(CatalogError)?;
    let mut registry = parse(raw, legacy, discovered)?;
    let target = registry
        .providers
        .iter()
        .position(|provider| provider.harness == harness)
        .ok_or(CatalogError)?;
    let prior: Vec<ModelEntry> = registry.providers[target]
        .models
        .iter()
        .chain(&registry.providers[target].retired)
        .cloned()
        .collect();
    let models = model_catalog::validate_provider_save_models(&request["models"], harness, &prior)?;
    if expected > registry.revision {
        return Err(CatalogError);
    }
    let legacy_catalog = model_catalog::read_catalog(legacy)?;
    for model in &models {
        let registered = registry.providers.iter().find(|provider| {
            provider
                .models
                .iter()
                .chain(&provider.retired)
                .any(|entry| entry.id == model.id)
        });
        if registered.is_some_and(|provider| provider.harness != harness)
            || (registered.is_none()
                && known_owner(&legacy_catalog, &model.id, discovered)
                    .is_some_and(|owner| owner != harness))
        {
            return Err(CatalogError);
        }
    }
    if registry.providers[target].models == models {
        return Ok(registry.json());
    }
    if expected != registry.revision || registry.revision >= crate::schema::MAX_SAFE_INTEGER {
        return Err(CatalogError);
    }
    let provider = &mut registry.providers[target];
    let mut retired: BTreeMap<_, _> = provider
        .retired
        .iter()
        .chain(&provider.models)
        .map(|entry| (entry.id.clone(), entry.clone()))
        .collect();
    for model in &models {
        retired.remove(&model.id);
    }
    provider.models = models;
    provider.retired = retired.into_values().collect();
    registry.revision += 1;
    // Validate the resulting whole registry. In particular, an ID retained in
    // another provider's history cannot be reassigned by a new active row.
    Ok(parse(&registry.json(), legacy, discovered)?.json())
}

pub fn models(
    raw: &Value,
    legacy: &Value,
    discovered: &[String],
    include_retired: bool,
) -> Result<Value, CatalogError> {
    let registry = parse(raw, legacy, discovered)?;
    let mut rows = Vec::new();
    for provider in registry.providers {
        for (active, entries) in [(true, provider.models), (false, provider.retired)] {
            if !active && !include_retired {
                continue;
            }
            for model in entries {
                let mut row = model.to_json();
                row["harness_id"] = json!(provider.harness);
                row["active"] = json!(active);
                rows.push(row);
            }
        }
    }
    Ok(json!(rows))
}

/// Historical routing only. New requests must separately require an active
/// row; recognizing an old receipt does not publish a selectable model.
pub fn harness(
    raw: &Value,
    legacy: &Value,
    discovered: &[String],
    model: &str,
) -> Result<Option<String>, CatalogError> {
    let registry = parse(raw, legacy, discovered)?;
    if crate::custom_provider_registry::provider_id_for_model(model).is_some() {
        return Ok(None);
    }
    for provider in registry.providers {
        if provider
            .models
            .iter()
            .chain(&provider.retired)
            .any(|entry| entry.id == model)
        {
            return Ok(Some(provider.harness));
        }
    }
    Ok(known_owner(
        &model_catalog::read_catalog(legacy)?,
        model,
        discovered,
    ))
}

pub(crate) fn reduce(request: &Map<String, Value>) -> Result<Value, CatalogError> {
    let op = request
        .get("op")
        .and_then(Value::as_str)
        .ok_or(CatalogError)?;
    let additional = match op {
        "provider_read" => &[][..],
        "provider_save" => &["request"][..],
        "provider_models" => &["include_retired"][..],
        "provider_harness" => &["model"][..],
        _ => return Err(CatalogError),
    };
    if !request.contains_key("registry")
        || additional.iter().any(|key| !request.contains_key(*key))
        || request.keys().any(|key| {
            !["op", "registry", "legacy_dsh_catalog", "discovered_models"].contains(&key.as_str())
                && !additional.contains(&key.as_str())
        })
    {
        return Err(CatalogError);
    }
    let legacy = request.get("legacy_dsh_catalog").unwrap_or(&Value::Null);
    let discovered: Vec<String> = match request.get("discovered_models") {
        None => Vec::new(),
        Some(value) => value
            .as_array()
            .ok_or(CatalogError)?
            .iter()
            .map(|v| v.as_str().map(str::to_owned).ok_or(CatalogError))
            .collect::<Result<_, _>>()?,
    };
    let raw = &request["registry"];
    match op {
        "provider_read" => read_registry(raw, legacy, &discovered),
        "provider_save" => save_registry(raw, &request["request"], legacy, &discovered),
        "provider_models" => models(
            raw,
            legacy,
            &discovered,
            request["include_retired"].as_bool().ok_or(CatalogError)?,
        ),
        "provider_harness" => Ok(harness(
            raw,
            legacy,
            &discovered,
            request["model"].as_str().ok_or(CatalogError)?,
        )?
        .map(Value::String)
        .unwrap_or(Value::Null)),
        _ => Err(CatalogError),
    }
}

#[cfg(test)]
#[path = "provider_model_catalog_tests.rs"]
mod tests;
