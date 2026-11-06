//! Non-secret API model catalogs. Native code owns credentials and discovery.
use super::{assistant_copy::copy, *};
use serde_json::json;
use std::collections::BTreeSet;

#[path = "provider_models_actions.rs"]
mod actions;
#[cfg(all(test, not(any(target_os = "ios", target_os = "android"))))]
#[path = "provider_models_tests.rs"]
mod tests;
#[path = "provider_models_view.rs"]
mod view;

pub(super) const HARNESSES: [&str; 4] = ["dsh", "claude-code", "codex", "glm"];
pub(super) fn provider_label(harness: &str) -> &'static str {
    match harness {
        "dsh" => "DeepSeek",
        "claude-code" => "Anthropic",
        "codex" => "OpenAI",
        "glm" => "Z.AI",
        _ => "",
    }
}
pub(super) fn provider_harness(provider: crate::providers::ApiProvider) -> &'static str {
    use crate::providers::ApiProvider::*;
    match provider {
        DeepSeek => "dsh",
        Anthropic => "claude-code",
        OpenAi => "codex",
        Zai => "glm",
    }
}
fn credential_slot(harness: &str) -> Option<&'static str> {
    Some(match harness {
        "dsh" => "DEEPSEEK_API_KEY",
        "claude-code" => "ANTHROPIC_API_KEY",
        "codex" => "OPENAI_API_KEY",
        "glm" => "BIGMODEL_API_KEY",
        _ => return None,
    })
}

#[derive(Clone, Debug, PartialEq)]
pub(super) struct ModelRow {
    id: String,
    name: String,
    images: bool,
}
impl ModelRow {
    fn value(&self) -> Value {
        json!({"id":self.id,"name":self.name,"supports_images":self.images})
    }
}

#[derive(Clone)]
pub(super) struct ProviderModelEditor {
    token: String,
    harness: String,
    revision: u64,
    models: Vec<ModelRow>,
    baseline: Vec<ModelRow>,
    candidates: Vec<ModelRow>,
    selected: BTreeSet<String>,
    query: String,
    discovered: bool,
    truncated: bool,
    notice: Option<String>,
    needs_reload: bool,
    field_request: Option<String>,
    scroll: gpui::ScrollHandle,
}
impl ProviderModelEditor {
    fn new(harness: &str, revision: u64, models: Vec<ModelRow>) -> Self {
        Self {
            token: uuid::Uuid::new_v4().to_string(),
            harness: harness.into(),
            revision,
            baseline: models.clone(),
            models,
            candidates: Vec::new(),
            selected: BTreeSet::new(),
            query: String::new(),
            discovered: false,
            truncated: false,
            notice: None,
            needs_reload: false,
            field_request: None,
            scroll: Default::default(),
        }
    }
    fn model_text(&self) -> String {
        self.models
            .iter()
            .map(|m| {
                if m.name == m.id {
                    m.id.clone()
                } else {
                    format!("{} | {}", m.id, m.name)
                }
            })
            .collect::<Vec<_>>()
            .join("\n")
    }
    fn set_models(&mut self, text: &str) -> Result<(), ()> {
        let mut next = Vec::new();
        let mut ids = BTreeSet::new();
        for line in text.lines().map(str::trim).filter(|s| !s.is_empty()) {
            let (id, name) = line
                .split_once('|')
                .map(|(id, name)| (id.trim(), name.trim().to_owned()))
                .unwrap_or_else(|| (line, line.chars().take(80).collect()));
            let existing = self
                .models
                .iter()
                .chain(self.baseline.iter())
                .any(|model| model.id == id);
            if !valid_id(id)
                || (id.starts_with("custom:") && !existing)
                || !valid_name(&name)
                || !ids.insert(id.to_owned())
            {
                return Err(());
            }
            let images = self
                .models
                .iter()
                .chain(self.baseline.iter())
                .find(|m| m.id == id)
                .is_some_and(|m| m.images);
            next.push(ModelRow {
                id: id.into(),
                name,
                images,
            });
        }
        if next.len() > 32 {
            return Err(());
        }
        self.models = next;
        self.selected.retain(|id| !ids.contains(id));
        Ok(())
    }
    fn visible_candidates(&self) -> impl Iterator<Item = &ModelRow> {
        let query = self.query.to_lowercase();
        self.candidates.iter().filter(move |m| {
            query.is_empty()
                || m.id.to_lowercase().contains(&query)
                || m.name.to_lowercase().contains(&query)
        })
    }
    fn has_model(&self, id: &str) -> bool {
        self.models.iter().any(|m| m.id == id)
    }
    fn import_selected(&mut self) -> Result<usize, ()> {
        let additions: Vec<_> = self
            .candidates
            .iter()
            .filter(|m| self.selected.contains(&m.id) && !self.has_model(&m.id))
            .cloned()
            .collect();
        if self.models.len() + additions.len() > 32 {
            return Err(());
        }
        let count = additions.len();
        self.models.extend(additions);
        self.selected.clear();
        Ok(count)
    }
}
fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 128
        && id.as_bytes()[0].is_ascii_alphanumeric()
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"._:/-".contains(&b))
}
fn valid_name(name: &str) -> bool {
    !name.is_empty() && name.encode_utf16().count() <= 80 && !name.chars().any(char::is_control)
}
fn rows_for(value: &Value, harness: &str) -> Vec<ModelRow> {
    value["providers"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|p| p["harness_id"] == harness)
        .and_then(|p| p["models"].as_array())
        .into_iter()
        .flatten()
        .map(|m| ModelRow {
            id: m["id"].as_str().unwrap_or_default().into(),
            name: m["name"].as_str().unwrap_or_default().into(),
            images: m["supports_images"].as_bool().unwrap_or(false),
        })
        .collect()
}
fn validated_registry(value: &Value) -> Result<Value, ()> {
    rish_shell_core::provider_model_catalog::read_registry(value, &Value::Null, &[]).map_err(|_| ())
}

#[derive(Clone, Debug)]
enum Operation {
    Reload,
    ProfileForDiscovery,
    Discover { profile: Value },
    Save { models: Vec<Value>, revision: u64 },
    Credential,
}
#[derive(Clone, Debug)]
pub(super) struct Request {
    token: String,
    editor: String,
    harness: String,
    operation: Operation,
}
#[derive(Clone, Debug)]
struct CancelRequest {
    token: String,
    editor: String,
    operation_id: String,
    harness: String,
}

#[derive(Default)]
pub(super) struct ProviderModelsUi {
    snapshot: Option<Value>,
    pub editor: Option<ProviderModelEditor>,
    request: Option<Request>,
    cancel: Option<CancelRequest>,
}
impl ProviderModelsUi {
    pub(super) fn install_snapshot(&mut self, value: Value) -> Result<(), ()> {
        let value = validated_registry(&value)?;
        if self
            .snapshot
            .as_ref()
            .is_some_and(|old| old["revision"].as_u64() > value["revision"].as_u64())
        {
            return Err(());
        }
        self.snapshot = Some(value);
        Ok(())
    }
    pub(super) fn request_pending(&self) -> bool {
        self.request.is_some()
            || self.cancel.is_some()
            || self
                .editor
                .as_ref()
                .is_some_and(|e| e.field_request.is_some())
    }
    pub(super) fn model_count(&self, harness: &str) -> usize {
        self.snapshot
            .as_ref()
            .map(|v| rows_for(v, harness).len())
            .unwrap_or(0)
    }
    fn revision(&self) -> u64 {
        self.snapshot
            .as_ref()
            .and_then(|v| v["revision"].as_u64())
            .unwrap_or(0)
    }
    fn current_editor(&mut self, request: &Request) -> Option<&mut ProviderModelEditor> {
        self.editor
            .as_mut()
            .filter(|e| e.token == request.editor && e.harness == request.harness)
    }
}

#[derive(Clone)]
pub(super) enum Action {
    Close,
    Reload,
    Credential,
    Fetch,
    CancelFetch,
    EditModels,
    EditFilter,
    ClearFilter,
    ToggleCandidate(String),
    Import,
    ToggleImages(String),
    Save,
}
