//! Provider rules shared by the mobile hosts. URL parsing/serialization and
//! credential/storage IO remain native; an endpoint is never re-encoded here.
//! Existing profile and credential identities retain their exact v1 hash domain.

use serde_json::{json, Map, Value};

use crate::{
    canonical::hash_json, custom_provider_registry, strict_json,
    workspace_tool::path_control_or_format,
};

const HARNESSES: [&str; 4] = ["claude-code", "codex", "dsh", "glm"];
const CONFIG_KEYS: [&str; 8] = [
    "schema_version",
    "harness_id",
    "name",
    "endpoint_url",
    "protocol",
    "auth_type",
    "model_mappings",
    "send_reasoning",
];
const BINDING_KEYS: [&str; 8] = [
    "schema_version",
    "harness_id",
    "endpoint_url",
    "protocol",
    "auth_type",
    "send_reasoning",
    "model_id",
    "profile_id",
];

fn exact(object: &Map<String, Value>, keys: &[&str]) -> bool {
    object.len() == keys.len() && keys.iter().all(|key| object.contains_key(*key))
}

fn text(value: &Value, maximum: usize) -> Option<&str> {
    let text = value.as_str()?;
    (!text.is_empty() && text.len() <= maximum && !text.chars().any(path_control_or_format))
        .then_some(text)
}

fn wire_model(value: &Value) -> Option<&str> {
    text(value, 128).filter(|value| !value.chars().any(char::is_whitespace))
}

fn display_name(value: &Value) -> Option<&str> {
    let name = value.as_str()?;
    // A human label is never part of a provider or credential identity. Keep
    // existing Android labels usable, including ZWJ emoji, without applying
    // URL/model identifier restrictions to their Unicode format characters.
    (!name.is_empty() && name.len() <= 80 && !name.chars().any(char::is_control)).then_some(name)
}

fn supported(value: &str) -> bool {
    HARNESSES.contains(&value) || custom_provider_registry::provider_id_for_harness(value).is_some()
}

fn protocol(value: &str) -> bool {
    matches!(value, "messages" | "responses" | "chat-completions")
}

fn auth(value: &str, harness: &str) -> bool {
    matches!(value, "bearer" | "x-api-key" | "api-key")
        || (value == "none" && custom_provider_registry::provider_id_for_harness(harness).is_some())
}

fn harness_for_slot(slot: &str) -> Option<String> {
    match slot {
        "ANTHROPIC_API_KEY" => Some("claude-code".into()),
        "OPENAI_API_KEY" => Some("codex".into()),
        "DEEPSEEK_API_KEY" => Some("dsh".into()),
        "BIGMODEL_API_KEY" => Some("glm".into()),
        _ => slot
            .strip_prefix("CUSTOM_API_KEY_")
            .filter(|id| custom_provider_registry::valid_uuid(id))
            .map(|id| format!("custom-{id}")),
    }
}

fn slot_for_harness(harness: &str) -> Option<String> {
    match harness {
        "claude-code" => Some("ANTHROPIC_API_KEY".into()),
        "codex" => Some("OPENAI_API_KEY".into()),
        "dsh" => Some("DEEPSEEK_API_KEY".into()),
        "glm" => Some("BIGMODEL_API_KEY".into()),
        _ => custom_provider_registry::provider_id_for_harness(harness)
            .map(|id| format!("CUSTOM_API_KEY_{id}")),
    }
}

fn defaults(harness: &str) -> Option<Value> {
    let (endpoint, protocol, auth) = match harness {
        "claude-code" => (
            "https://api.anthropic.com/v1/messages",
            "messages",
            "x-api-key",
        ),
        "codex" => ("https://api.openai.com/v1/responses", "responses", "bearer"),
        "dsh" => (
            "https://api.deepseek.com/chat/completions",
            "chat-completions",
            "bearer",
        ),
        "glm" => (
            "https://open.bigmodel.cn/api/anthropic/v1/messages",
            "messages",
            "x-api-key",
        ),
        _ => return None,
    };
    Some(
        json!({"schema_version": 1, "harness_id": harness, "name": "",
        "endpoint_url": endpoint, "protocol": protocol, "auth_type": auth,
        "model_mappings": {}, "send_reasoning": true, "official": true}),
    )
}

/// The host supplies components produced by its existing URL parser. `path`
/// deliberately means Foundation's decoded path or OkHttp's encoded path;
/// suffix policy is shared while the existing endpoint bytes stay compatible.
fn endpoint_plan(request: &Map<String, Value>) -> Option<Value> {
    if !exact(
        request,
        &["op", "codec", "raw", "protocol", "full_url", "parts"],
    ) {
        return None;
    }
    let foundation = match request.get("codec")?.as_str()? {
        "foundation" => true,
        "okhttp" => false,
        _ => return None,
    };
    text(request.get("raw")?, 2048)?;
    let dialect = request.get("protocol")?.as_str()?;
    if !protocol(dialect) {
        return None;
    }
    let full_url = request.get("full_url")?.as_bool()?;
    let parts = request.get("parts")?.as_object()?;
    if !exact(
        parts,
        &[
            "scheme",
            "host",
            "port",
            "has_user",
            "has_password",
            "has_query",
            "has_fragment",
            "path",
        ],
    ) {
        return None;
    }
    let scheme = parts.get("scheme")?.as_str()?.to_lowercase();
    let host = text(parts.get("host")?, 2048)?.to_lowercase();
    if host.chars().any(char::is_whitespace) {
        return None;
    }
    let local = matches!(host.as_str(), "localhost" | "127.0.0.1" | "::1" | "[::1]");
    if scheme != "https" && !(scheme == "http" && local) {
        return None;
    }
    if !parts.get("port")?.is_null() {
        let port = parts.get("port")?.as_u64()?;
        if !(1..=65535).contains(&port) {
            return None;
        }
    }
    for key in ["has_user", "has_password", "has_query", "has_fragment"] {
        if parts.get(key)?.as_bool()? {
            return None;
        }
    }
    let mut path = parts.get("path")?.as_str()?.to_owned();
    if !path.is_empty() && !path.starts_with('/') {
        return None;
    }
    if !full_url {
        path.truncate(path.trim_end_matches('/').len());
        let mut known_endpoint = false;
        for suffix in ["/chat/completions", "/responses", "/messages"] {
            if path.ends_with(suffix) {
                path.truncate(path.len() - suffix.len());
                known_endpoint = true;
                break;
            }
        }
        let suffix = match dialect {
            "messages" => "/messages",
            "responses" => "/responses",
            _ => "/chat/completions",
        };
        // Foundation's old configuration reader skipped an append when the
        // remaining path already ended in the desired suffix. OkHttp appended
        // unconditionally. Keep that compatibility rule here: changing an
        // existing endpoint changes its persisted credential-account digest.
        if !(foundation && path.ends_with(suffix)) {
            if !known_endpoint && !path.ends_with("/v1") {
                path.push_str("/v1");
            }
            path.push_str(suffix);
        }
    }
    Some(json!({"scheme": scheme, "host": host, "path": path}))
}

/// Validate fields without normalizing endpoint bytes. The host must first
/// apply endpoint_plan and serialize with its established platform URL codec.
pub(crate) fn configuration(raw: &Value) -> Option<Value> {
    let object = raw.as_object()?;
    if !CONFIG_KEYS.iter().all(|key| object.contains_key(*key))
        || object
            .keys()
            .any(|key| !CONFIG_KEYS.contains(&key.as_str()) && key != "full_url")
        || object.get("schema_version")?.as_u64()? != 1
        || !supported(object.get("harness_id")?.as_str()?)
        || !protocol(object.get("protocol")?.as_str()?)
        || !auth(
            object.get("auth_type")?.as_str()?,
            object.get("harness_id")?.as_str()?,
        )
    {
        return None;
    }
    display_name(object.get("name")?)?;
    text(object.get("endpoint_url")?, 2048)?;
    object.get("send_reasoning")?.as_bool()?;
    let full_url = match object.get("full_url") {
        Some(value) => value.as_bool()?,
        None => false,
    };
    let mappings = object.get("model_mappings")?.as_object()?;
    let custom =
        custom_provider_registry::provider_id_for_harness(object.get("harness_id")?.as_str()?);
    if mappings.len() > 32
        || mappings.iter().any(|(model, wire)| {
            model.is_empty()
                || wire_model(wire).is_none()
                || custom.is_some_and(|id| !custom_provider_registry::model_belongs_to(model, id))
        })
    {
        return None;
    }
    let mut normalized = object.clone();
    normalized.insert("full_url".into(), Value::Bool(full_url));
    Some(Value::Object(normalized))
}

fn validate_configuration(request: &Map<String, Value>) -> Option<Value> {
    if !exact(request, &["op", "configuration", "harness_by_model"]) {
        return None;
    }
    let normalized = configuration(request.get("configuration")?)?;
    let model_harnesses = request.get("harness_by_model")?.as_object()?;
    let harness = normalized.get("harness_id")?;
    for model in normalized.get("model_mappings")?.as_object()?.keys() {
        if model_harnesses.get(model) != Some(harness) {
            return None;
        }
    }
    Some(normalized)
}

fn official(raw: &Value) -> bool {
    raw.get("harness_id")
        .and_then(Value::as_str)
        .and_then(defaults)
        .as_ref()
        == Some(raw)
}

fn digest(identity: &Value) -> Option<String> {
    identity.as_object()?;
    // The tag itself ends in -v1; hash_json appends the historical .v1\0.
    hash_json("provider-configuration-v1", identity)
}

fn binding(request: &Map<String, Value>) -> Option<Value> {
    if !exact(
        request,
        &["op", "configuration", "logical_model", "model_harness"],
    ) {
        return None;
    }
    let model = request.get("logical_model")?.as_str()?;
    let harness = request.get("model_harness")?.as_str()?;
    let raw = request.get("configuration")?;
    if raw.get("harness_id")?.as_str()? != harness || !supported(harness) || model.is_empty() {
        return None;
    }
    if official(raw) {
        return Some(Value::Null);
    }
    let profile = configuration(raw)?;
    let custom = custom_provider_registry::provider_id_for_harness(harness);
    if custom.is_some_and(|id| !custom_provider_registry::model_belongs_to(model, id)) {
        return None;
    }
    let mapping = profile.get("model_mappings")?.get(model);
    let wire = if custom.is_some() {
        mapping?
    } else {
        mapping.unwrap_or(request.get("logical_model")?)
    };
    wire_model(wire)?;
    let mut identity = json!({"schema_version": 1, "harness_id": harness,
        "endpoint_url": profile["endpoint_url"], "protocol": profile["protocol"],
        "auth_type": profile["auth_type"], "send_reasoning": profile["send_reasoning"], "model_id": wire});
    identity["profile_id"] = Value::String(digest(&identity)?);
    Some(identity)
}

fn binding_valid(request: &Map<String, Value>) -> Option<bool> {
    let raw = request.get("binding")?.as_object()?;
    if !exact(raw, &BINDING_KEYS) || raw.get("schema_version")?.as_u64()? != 1 {
        return None;
    }
    let logical = request.get("logical_model")?.as_str()?;
    if logical.is_empty() || request.get("endpoint_is_canonical")?.as_bool()? != true {
        return None;
    }
    let harness = raw.get("harness_id")?.as_str()?;
    if !supported(harness)
        || request.get("model_harness")?.as_str()? != harness
        || !protocol(raw.get("protocol")?.as_str()?)
        || !auth(raw.get("auth_type")?.as_str()?, harness)
        || custom_provider_registry::provider_id_for_harness(harness)
            .is_some_and(|id| !custom_provider_registry::model_belongs_to(logical, id))
    {
        return None;
    }
    text(raw.get("endpoint_url")?, 2048)?;
    wire_model(raw.get("model_id")?)?;
    raw.get("send_reasoning")?.as_bool()?;
    let mut identity = raw.clone();
    let profile_id = identity.remove("profile_id")?;
    Some(profile_id.as_str()? == digest(&Value::Object(identity))?)
}

fn credential_account(request: &Map<String, Value>) -> Option<Value> {
    if !exact(request, &["op", "slot", "configuration"]) {
        return None;
    }
    let slot = request.get("slot")?.as_str()?;
    let Some(harness) = harness_for_slot(slot) else {
        if slot.starts_with("CUSTOM_API_KEY_") {
            return None;
        }
        return Some(Value::String(slot.to_owned()));
    };
    let raw = request.get("configuration")?;
    if raw.is_null() {
        return Some(Value::Null);
    }
    if raw.get("harness_id")?.as_str()? != harness {
        return None;
    }
    if official(raw) {
        return Some(Value::String(slot.to_owned()));
    }
    let profile = configuration(raw)?;
    if profile["auth_type"] == "none" {
        return Some(Value::Null);
    }
    let identity = json!({"harness_id": harness, "endpoint_url": profile["endpoint_url"],
        "auth_type": profile["auth_type"], "protocol": profile["protocol"]});
    Some(Value::String(format!(
        "CUSTOM_PROVIDER_{harness}_{}",
        digest(&identity)?
    )))
}

fn reduce(request: &Map<String, Value>) -> Option<Value> {
    match request.get("op")?.as_str()? {
        "harnesses" if exact(request, &["op"]) => Some(json!(HARNESSES)),
        "is_custom_model" if exact(request, &["op", "model_id"]) => Some(Value::Bool(
            custom_provider_registry::provider_id_for_model(request.get("model_id")?.as_str()?)
                .is_some(),
        )),
        "defaults" if exact(request, &["op", "harness_id"]) => {
            defaults(request.get("harness_id")?.as_str()?)
        }
        "harness_for_slot" if exact(request, &["op", "slot"]) => {
            Some(json!(harness_for_slot(request.get("slot")?.as_str()?)))
        }
        "slot_for_harness" if exact(request, &["op", "harness_id"]) => Some(json!(
            slot_for_harness(request.get("harness_id")?.as_str()?)
        )),
        "endpoint_plan" => endpoint_plan(request),
        "validate_configuration" => validate_configuration(request),
        "binding" => binding(request),
        "validate_binding"
            if exact(
                request,
                &[
                    "op",
                    "binding",
                    "logical_model",
                    "model_harness",
                    "endpoint_is_canonical",
                ],
            ) =>
        {
            Some(Value::Bool(binding_valid(request).unwrap_or(false)))
        }
        "credential_account" => credential_account(request),
        "credential_required" if exact(request, &["op", "configuration"]) => {
            let raw = request.get("configuration")?;
            let profile = if official(raw) {
                raw.clone()
            } else {
                configuration(raw)?
            };
            Some(Value::Bool(profile["auth_type"] != "none"))
        }
        "profile_digest" if exact(request, &["op", "identity"]) => {
            Some(Value::String(digest(request.get("identity")?)?))
        }
        _ => None,
    }
}

/// Exact operation envelopes; failures never include configuration or secrets.
/// Native URL fact extraction is trusted host input, not an untrusted API.
pub fn reduce_json(input: &str) -> String {
    let request = strict_json::parse_arguments(input).or_else(|| {
        // Discovery bodies are bounded independently at 1 MiB. Only this
        // read-only operation may use a larger envelope; ordinary policy and
        // registry operations keep their historical 256 KiB input boundary.
        let request = strict_json::parse_arguments_bounded(
            input,
            crate::provider_model_discovery::MAX_ENVELOPE_BYTES,
        )?;
        (request.get("op").and_then(Value::as_str) == Some("models_parse_page")).then_some(request)
    });
    if let Some(request) = &request {
        if request
            .get("op")
            .and_then(Value::as_str)
            .is_some_and(|op| op.starts_with("models_"))
        {
            return match crate::provider_model_discovery::reduce(request) {
                Ok(value) => json!({"ok":true,"value":value}).to_string(),
                Err(error) => json!({"ok":false,"error":error.code()}).to_string(),
            };
        }
        if request
            .get("op")
            .and_then(Value::as_str)
            .is_some_and(|op| op.starts_with("registry_"))
        {
            return match custom_provider_registry::reduce(request) {
                Ok(value) => json!({"ok": true, "value": value}).to_string(),
                Err(error) => json!({"ok": false, "error": error.code()}).to_string(),
            };
        }
    }
    match request.and_then(|request| reduce(&request)) {
        Some(value) => json!({"ok": true, "value": value}).to_string(),
        None => json!({"ok": false, "error": "E_PROVIDER_CONFIGURATION"}).to_string(),
    }
}

#[cfg(test)]
#[path = "provider_policy_tests.rs"]
mod tests;
