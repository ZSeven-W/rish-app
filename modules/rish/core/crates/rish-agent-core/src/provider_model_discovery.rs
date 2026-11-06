//! Read-only model discovery policy. Native hosts own HTTP, credentials,
//! same-origin URL serialization, pagination and cancellation. This module
//! never writes the provider registry or follows server-supplied URLs.

use std::collections::BTreeSet;

use serde_json::{json, Map, Value};

use crate::{strict_json, workspace_tool::path_control_or_format};

pub const MAX_RESPONSE_BYTES: usize = 1024 * 1024;
pub const MAX_MODELS: usize = 512;
pub const MAX_PAGES: usize = 8;
pub const MAX_DISPLAY_NAME_BYTES: usize = 80;
// A JSON string may double its raw response's quote/backslash bytes.
pub(crate) const MAX_ENVELOPE_BYTES: usize = 2 * MAX_RESPONSE_BYTES + 4096;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DiscoveryError {
    Invalid,
    Unsupported,
    Limit,
}

impl DiscoveryError {
    pub fn code(self) -> &'static str {
        match self {
            Self::Invalid => "E_PROVIDER_MODEL_DISCOVERY_INVALID",
            Self::Unsupported => "E_PROVIDER_MODEL_DISCOVERY_UNSUPPORTED",
            Self::Limit => "E_PROVIDER_MODEL_DISCOVERY_LIMIT",
        }
    }
}

type Result<T> = std::result::Result<T, DiscoveryError>;

fn exact(value: &Map<String, Value>, keys: &[&str]) -> bool {
    value.len() == keys.len() && keys.iter().all(|key| value.contains_key(*key))
}

fn protocol(value: &Value) -> Result<&str> {
    value
        .as_str()
        .filter(|value| matches!(*value, "messages" | "responses" | "chat-completions"))
        .ok_or(DiscoveryError::Invalid)
}

fn wire_id(value: &Value) -> Result<&str> {
    value
        .as_str()
        .filter(|id| {
            !id.is_empty()
                && id.len() <= 128
                && !id
                    .chars()
                    .any(|c| c.is_whitespace() || path_control_or_format(c))
        })
        .ok_or(DiscoveryError::Invalid)
}

fn label(value: Option<&Value>) -> Option<&str> {
    value?.as_str().filter(|name| {
        !name.trim().is_empty()
            && name.len() <= MAX_DISPLAY_NAME_BYTES
            && !name.chars().any(path_control_or_format)
    })
}

fn fallback_label(id: &str) -> String {
    if id.len() <= MAX_DISPLAY_NAME_BYTES {
        return id.to_owned();
    }
    let mut end = MAX_DISPLAY_NAME_BYTES - "…".len();
    while !id.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}…", &id[..end])
}

fn endpoint_path(request: &Map<String, Value>) -> Result<Value> {
    if !exact(request, &["op", "path", "protocol"]) {
        return Err(DiscoveryError::Invalid);
    }
    protocol(&request["protocol"])?;
    let path = request["path"]
        .as_str()
        .filter(|path| {
            path.starts_with('/') && path.len() <= 2048 && !path.chars().any(path_control_or_format)
        })
        .ok_or(DiscoveryError::Invalid)?;
    let path = path.trim_end_matches('/');
    for suffix in ["/chat/completions", "/responses", "/messages"] {
        if let Some(prefix) = path.strip_suffix(suffix) {
            return Ok(json!(format!("{prefix}/models")));
        }
    }
    Err(DiscoveryError::Unsupported)
}

fn capabilities(row: &Map<String, Value>) -> Result<bool> {
    let explicit = row.get("supports_images").or_else(|| {
        row.get("capabilities")?
            .get("image_input")?
            .get("supported")
    });
    match explicit {
        None => Ok(false),
        Some(value) => value.as_bool().ok_or(DiscoveryError::Invalid),
    }
}

/// Validate the native discovery result before a user explicitly selects
/// candidates to import. Unknown fields are rejected, not copied to storage.
pub fn validate_candidates(value: &Value) -> Result<Value> {
    let rows = value.as_array().ok_or(DiscoveryError::Invalid)?;
    if rows.len() > MAX_MODELS {
        return Err(DiscoveryError::Limit);
    }
    let mut seen = BTreeSet::new();
    for value in rows {
        let row = value.as_object().ok_or(DiscoveryError::Invalid)?;
        if !exact(row, &["wire_model", "name", "supports_images"])
            || !seen.insert(wire_id(&row["wire_model"])?)
            || label(row.get("name")).is_none()
            || row["supports_images"].as_bool().is_none()
        {
            return Err(DiscoveryError::Invalid);
        }
    }
    Ok(value.clone())
}

fn parse_page(request: &Map<String, Value>) -> Result<Value> {
    if !exact(request, &["op", "protocol", "response_body"]) {
        return Err(DiscoveryError::Invalid);
    }
    let protocol = protocol(&request["protocol"])?;
    let body = request["response_body"]
        .as_str()
        .ok_or(DiscoveryError::Invalid)?;
    if body.len() > MAX_RESPONSE_BYTES {
        return Err(DiscoveryError::Limit);
    }
    let page = strict_json::parse_arguments_bounded(body, MAX_RESPONSE_BYTES)
        .ok_or(DiscoveryError::Invalid)?;
    let rows = page
        .get("data")
        .and_then(Value::as_array)
        .ok_or(DiscoveryError::Invalid)?;
    if rows.len() > MAX_MODELS {
        return Err(DiscoveryError::Limit);
    }
    let mut models = Vec::with_capacity(rows.len());
    let mut seen = BTreeSet::new();
    let mut last_row_id = None;
    for value in rows {
        let row = value.as_object().ok_or(DiscoveryError::Invalid)?;
        let id = wire_id(row.get("id").ok_or(DiscoveryError::Invalid)?)?;
        if !seen.insert(id) {
            return Err(DiscoveryError::Invalid);
        }
        last_row_id = Some(id);
        if row.get("lifecycle").and_then(Value::as_str) == Some("retired") {
            continue;
        }
        let name = label(row.get("display_name"))
            .or_else(|| label(row.get("name")))
            .map(str::to_owned)
            .unwrap_or_else(|| fallback_label(id));
        models.push(json!({"wire_model":id,"name":name,"supports_images":capabilities(row)?}));
    }
    let has_more = if protocol == "messages" {
        page.get("has_more")
            .map(|value| value.as_bool().ok_or(DiscoveryError::Invalid))
            .transpose()?
            .unwrap_or(false)
    } else {
        false
    };
    let last_id = if has_more {
        let id = wire_id(page.get("last_id").ok_or(DiscoveryError::Invalid)?)?;
        // Pagination refers to the server's last raw row, including a retired
        // row omitted from import choices. Never follow a remote next URL.
        if last_row_id != Some(id) {
            return Err(DiscoveryError::Invalid);
        }
        json!(id)
    } else {
        Value::Null
    };
    Ok(json!({"models":models,"has_more":has_more,"last_id":last_id}))
}

pub(crate) fn reduce(request: &Map<String, Value>) -> Result<Value> {
    match request.get("op").and_then(Value::as_str) {
        Some("models_endpoint_path") => endpoint_path(request),
        Some("models_parse_page") => parse_page(request),
        _ => Err(DiscoveryError::Invalid),
    }
}

#[cfg(test)]
#[path = "provider_model_discovery_tests.rs"]
mod tests;
