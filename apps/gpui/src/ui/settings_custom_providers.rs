//! Only non-secret provider metadata enters the UI. Native secure prompts own keys.
use super::{assistant_copy::copy, *};
use rish_shell_core::custom_provider_registry as registry;
use serde_json::{Map, json};
use std::collections::{BTreeMap, BTreeSet};

#[path = "settings_custom_provider_actions.rs"]
mod actions;
#[path = "settings_custom_provider_discovery.rs"]
mod discovery;
#[cfg(all(test, not(any(target_os = "ios", target_os = "android"))))]
#[path = "settings_custom_provider_discovery_tests.rs"]
mod discovery_tests;
#[path = "settings_custom_provider_discovery_view.rs"]
mod discovery_view;
use discovery::{DiscoveryAction, ModelDiscovery};
#[cfg(all(test, not(any(target_os = "ios", target_os = "android"))))]
#[path = "settings_custom_provider_tests.rs"]
mod tests;
#[path = "settings_custom_provider_view.rs"]
mod view;

fn bounded_model_name(name: &str) -> String {
    let mut bytes = 0;
    name.chars()
        .take_while(|character| {
            bytes += character.len_utf8();
            bytes <= 80
        })
        .collect()
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum CredentialPhase {
    Unknown,
    Configured,
    Missing,
    NotRequired,
}
impl CredentialPhase {
    pub fn label(self, locale: Locale) -> &'static str {
        match self {
            Self::Unknown => copy(locale, "Key status not checked", "尚未检查密钥状态"),
            Self::Configured => copy(
                locale,
                "Key saved · not connection tested",
                "密钥已保存 · 未测试连接",
            ),
            Self::Missing => copy(locale, "Key not configured", "未设置密钥"),
            Self::NotRequired => copy(
                locale,
                "No key required · not connection tested",
                "无需密钥 · 未测试连接",
            ),
        }
    }
}

#[derive(Clone)]
pub(super) struct ProviderEditor {
    token: String,
    id: String,
    baseline: Option<Value>,
    revision: u64,
    name: String,
    endpoint: String,
    protocol: String,
    auth: String,
    full_url: bool,
    send_reasoning: bool,
    models: Vec<Value>,
    error: Option<&'static str>,
    remove_confirm: bool,
    discovery: ModelDiscovery,
}
impl ProviderEditor {
    fn new(revision: u64, provider: Option<&Value>) -> Self {
        let mut editor = Self {
            token: uuid::Uuid::new_v4().to_string(),
            id: uuid::Uuid::new_v4().to_string(),
            baseline: provider.cloned(),
            revision,
            name: String::new(),
            endpoint: String::new(),
            protocol: "chat-completions".into(),
            auth: "bearer".into(),
            full_url: false,
            send_reasoning: false,
            models: Vec::new(),
            error: None,
            remove_confirm: false,
            discovery: ModelDiscovery::default(),
        };
        if let Some(provider) = provider {
            let config = &provider["configuration"];
            editor.id = provider["id"].as_str().unwrap_or_default().into();
            editor.name = config["name"].as_str().unwrap_or_default().into();
            editor.endpoint = config["endpoint_url"].as_str().unwrap_or_default().into();
            editor.protocol = config["protocol"].as_str().unwrap_or_default().into();
            editor.auth = config["auth_type"].as_str().unwrap_or_default().into();
            editor.full_url = config["full_url"].as_bool().unwrap_or(false);
            editor.send_reasoning = config["send_reasoning"].as_bool().unwrap_or(false);
            editor.models = provider["models"]
                .as_array()
                .into_iter()
                .flatten()
                .filter(|model| model["active"] == true)
                .cloned()
                .collect();
        }
        editor
    }
    fn model_text(&self) -> String {
        self.models
            .iter()
            .map(|model| {
                let wire = model["wire_model"].as_str().unwrap_or_default();
                let name = model["name"].as_str().unwrap_or(wire);
                if name == wire {
                    wire.to_owned()
                } else {
                    format!("{wire} | {name}")
                }
            })
            .collect::<Vec<_>>()
            .join("\n")
    }
    fn set_models(&mut self, text: &str) -> Result<(), ()> {
        let mut models = Vec::new();
        let mut wires = BTreeSet::new();
        for line in text.lines().map(str::trim).filter(|line| !line.is_empty()) {
            let (wire, name) = line
                .split_once('|')
                .map(|(w, n)| (w.trim(), n.trim().to_owned()))
                .unwrap_or_else(|| (line, bounded_model_name(line)));
            if wire.is_empty()
                || wire.len() > 128
                || wire.chars().any(char::is_whitespace)
                || name.is_empty()
                || name.len() > 80
                || name.chars().any(char::is_control)
                || !wires.insert(wire.to_owned())
            {
                return Err(());
            }
            let previous = self
                .models
                .iter()
                .find(|model| model["wire_model"] == wire)
                .or_else(|| {
                    self.baseline
                        .as_ref()
                        .and_then(|p| p["models"].as_array())
                        .and_then(|models| {
                            models
                                .iter()
                                .find(|m| m["active"] == true && m["wire_model"] == wire)
                        })
                });
            let id = previous
                .and_then(|m| m["id"].as_str())
                .map(str::to_owned)
                .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
            models.push(
                json!({"id":id,"name":name,"wire_model":wire,"supports_images":previous
                .and_then(|m|m["supports_images"].as_bool()).unwrap_or(false),"active":true}),
            );
        }
        if models.len() > registry::MAX_ACTIVE_MODELS_PER_PROVIDER {
            return Err(());
        }
        self.models = models;
        Ok(())
    }
    fn review_snapshot(&mut self, revision: u64, current: Option<Value>) -> bool {
        self.revision = revision;
        let removed = self.baseline.is_some() && current.is_none();
        if let Some(current) = current {
            // A concurrent save may have retired an earlier model identity.
            // Keep draft text/capabilities while binding unchanged wires to the
            // current active identities; new wires receive new identities.
            for model in &mut self.models {
                let active = current["models"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .find(|saved| {
                        saved["active"] == true && saved["wire_model"] == model["wire_model"]
                    });
                model["id"] = active
                    .map(|saved| saved["id"].clone())
                    .unwrap_or_else(|| json!(uuid::Uuid::new_v4().to_string()));
            }
            self.baseline = Some(current);
        }
        removed
    }
    fn payload(&self) -> Result<Value, ()> {
        // URL normalization and protocol-specific URL validation remain native.
        if self.name.trim().is_empty()
            || self.name.len() > 80
            || self.name.chars().any(char::is_control)
            || self.endpoint.trim().is_empty()
        {
            return Err(());
        }
        let mappings: Map<String, Value> = self
            .models
            .iter()
            .map(|model| {
                (
                    registry::logical_model_id(&self.id, model["id"].as_str().unwrap_or_default()),
                    model["wire_model"].clone(),
                )
            })
            .collect();
        Ok(
            json!({"id":self.id,"active":true,"models":self.models,"configuration":{
            "schema_version":1,"harness_id":format!("custom-{}",self.id),"name":self.name.trim(),
            "endpoint_url":self.endpoint.trim(),"protocol":self.protocol,"auth_type":self.auth,
            "send_reasoning":self.send_reasoning,"model_mappings":mappings,"full_url":self.full_url}}),
        )
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Field {
    Name,
    Endpoint,
    Models,
}
#[derive(Clone)]
enum Action {
    Add,
    Edit(String),
    Field(Field),
    Protocol(&'static str),
    Auth(&'static str),
    FullUrl,
    Reasoning,
    Images(String),
    Save(bool),
    Cancel,
    Reload,
    Remove,
    ConfirmRemove,
    SetKey,
    ClearKey,
    Discovery(DiscoveryAction),
}
#[derive(Clone)]
enum Operation {
    Reload,
    Discover {
        id: String,
        editor: String,
        generation: u64,
        profile: Value,
    },
    CancelDiscovery {
        id: String,
        operation_id: String,
        editor: String,
        generation: u64,
    },
    Save {
        editor: String,
        provider: Value,
        key: bool,
    },
    Remove(String),
    Status {
        id: String,
        profile: Value,
    },
    Key {
        id: String,
        profile: Value,
        clear: bool,
    },
}
#[derive(Clone)]
struct ProviderRequest {
    token: String,
    revision: u64,
    operation: Operation,
}

#[cfg(all(test, not(any(target_os = "ios", target_os = "android"))))]
impl Shell {
    pub(super) fn test_begin_custom_provider_reload(&mut self) {
        self.custom_providers.request = Some(ProviderRequest {
            token: uuid::Uuid::new_v4().to_string(),
            revision: self.custom_providers.revision(),
            operation: Operation::Reload,
        });
    }
    pub(super) fn test_complete_custom_provider_reload(
        &mut self,
        value: Value,
        cx: &mut Context<Self>,
    ) {
        let request = self
            .custom_providers
            .request
            .clone()
            .expect("pending provider reload");
        self.complete_custom_provider_request(request, Ok(value), cx);
    }
}

pub(super) struct CustomProvidersUi {
    registry: Value,
    pub(super) loaded: bool,
    editor: Option<ProviderEditor>,
    request: Option<ProviderRequest>,
    status: BTreeMap<String, CredentialPhase>,
    needs_reload: bool,
    error: Option<&'static str>,
}
impl Default for CustomProvidersUi {
    fn default() -> Self {
        Self {
            registry: json!({"schema_version":1,"revision":0,"providers":[]}),
            loaded: false,
            editor: None,
            request: None,
            status: BTreeMap::new(),
            needs_reload: false,
            error: None,
        }
    }
}
impl CustomProvidersUi {
    pub(super) fn request_pending(&self) -> bool {
        self.request.is_some()
    }
    pub(super) fn install_snapshot(&mut self, value: Value) -> Result<(), String> {
        if value["schema_version"] != 1 {
            return Err("E_CUSTOM_PROVIDER_REGISTRY_INVALID".into());
        }
        let registry = registry::read_registry(&value).map_err(|error| error.code().to_owned())?;
        if self.loaded
            && (registry["revision"].as_u64() < self.registry["revision"].as_u64()
                || (registry["revision"] == self.registry["revision"] && registry != self.registry))
        {
            return Err("E_CUSTOM_PROVIDER_REGISTRY_STALE".into());
        }
        let previous = &self.registry;
        self.status.retain(|id, _| {
            let before = previous["providers"]
                .as_array()
                .unwrap()
                .iter()
                .find(|provider| provider["id"] == id.as_str() && provider["active"] == true);
            let after = registry["providers"]
                .as_array()
                .unwrap()
                .iter()
                .find(|provider| provider["id"] == id.as_str() && provider["active"] == true);
            before.map(|p| &p["configuration"]) == after.map(|p| &p["configuration"])
        });
        self.registry = registry;
        let discovery_stale = self.editor.as_ref().is_some_and(|editor| {
            editor.discovery.profile.as_ref().is_some_and(|profile| {
                self.provider(&editor.id)
                    .is_none_or(|provider| provider["configuration"] != *profile)
            })
        });
        if discovery_stale {
            self.editor.as_mut().unwrap().invalidate_discovery();
        }
        self.loaded = true;
        self.needs_reload = false;
        Ok(())
    }
    fn revision(&self) -> u64 {
        self.registry["revision"].as_u64().unwrap_or(0)
    }
    fn providers(&self) -> impl Iterator<Item = &Value> {
        self.registry["providers"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|p| p["active"] == true)
    }
    fn provider(&self, id: &str) -> Option<&Value> {
        self.providers().find(|p| p["id"] == id)
    }
    pub(super) fn model_detail(&self, logical: &str) -> Option<String> {
        self.providers().find_map(|provider| {
            provider["models"]
                .as_array()?
                .iter()
                .filter(|model| model["active"] == true)
                .find(|model| {
                    registry::logical_model_id(
                        provider["id"].as_str().unwrap(),
                        model["id"].as_str().unwrap(),
                    ) == logical
                })
                .map(|model| {
                    format!(
                        "{} · {}",
                        provider["configuration"]["name"].as_str().unwrap(),
                        model["wire_model"].as_str().unwrap()
                    )
                })
        })
    }
    fn phase(&self, id: &str) -> CredentialPhase {
        if self
            .provider(id)
            .is_some_and(|p| p["configuration"]["auth_type"] == "none")
        {
            CredentialPhase::NotRequired
        } else {
            self.status
                .get(id)
                .copied()
                .unwrap_or(CredentialPhase::Unknown)
        }
    }
    fn current(&self, request: &ProviderRequest) -> bool {
        self.request
            .as_ref()
            .is_some_and(|pending| pending.token == request.token)
            && self.revision() == request.revision
            && match &request.operation {
                Operation::Save { editor, .. } => self
                    .editor
                    .as_ref()
                    .is_some_and(|draft| &draft.token == editor),
                Operation::Status { id, profile } | Operation::Key { id, profile, .. } => self
                    .provider(id)
                    .is_some_and(|p| p["configuration"] == *profile),
                _ => true,
            }
    }
}
