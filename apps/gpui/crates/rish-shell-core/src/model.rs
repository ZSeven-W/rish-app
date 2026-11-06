use rish_agent_core::session_schema::{self, Env, ProviderBinding};
use serde_json::{json, Value};

pub type Result<T> = std::result::Result<T, String>;

#[derive(Clone, Debug, PartialEq)]
pub struct RuntimeCommand {
    pub module: String,
    pub method: String,
    pub args: Vec<Value>,
}
impl RuntimeCommand {
    pub fn new(module: &str, method: &str, args: Vec<Value>) -> Self {
        Self {
            module: module.into(),
            method: method.into(),
            args,
        }
    }
}
#[derive(Clone, Debug, PartialEq)]
pub struct Model {
    pub id: String,
    pub name: String,
    pub harness: String,
}
#[derive(Clone, Debug, PartialEq)]
pub struct ConversationSummary {
    pub id: String,
    pub title: String,
    pub model: String,
    pub thinking: String,
    pub updated_at: String,
    pub has_active_attempt: bool,
}
#[derive(Clone, Debug, PartialEq)]
pub struct Message {
    pub id: String,
    pub role: String,
    pub text: String,
    pub reasoning: String,
}
#[derive(Clone, Debug, PartialEq)]
pub enum ConflictKind {
    Answer,
    Failed,
    Cancelled,
}
#[derive(Clone, Debug, PartialEq)]
pub struct PendingConflict {
    pub conversation_id: String,
    pub attempt_id: String,
    pub kind: ConflictKind,
    pub answer: Option<Message>,
}
#[derive(Clone, Debug, PartialEq)]
pub struct TurnIds {
    pub turn_id: String,
    pub attempt_id: String,
    pub round_id: String,
    pub user_message_id: String,
    pub assistant_message_id: String,
}
impl Default for TurnIds {
    fn default() -> Self {
        Self::new()
    }
}
impl TurnIds {
    pub fn new() -> Self {
        Self {
            turn_id: id(),
            attempt_id: id(),
            round_id: id(),
            user_message_id: id(),
            assistant_message_id: id(),
        }
    }
}
pub(crate) fn id() -> String {
    uuid::Uuid::new_v4().to_string()
}
pub(crate) fn text<'a>(v: &'a Value, key: &str) -> &'a str {
    v[key].as_str().unwrap_or("")
}
pub(crate) fn rows<'a>(v: &'a Value, key: &str) -> &'a [Value] {
    v[key].as_array().map(Vec::as_slice).unwrap_or(&[])
}
pub(crate) fn decode(value: Value) -> Result<Value> {
    match value {
        Value::String(s) => serde_json::from_str(&s).map_err(|_| "Invalid native JSON".into()),
        v => Ok(v),
    }
}
pub(crate) fn active(v: &Value) -> bool {
    rows(v, "attempts")
        .iter()
        .any(|a| matches!(text(a, "status"), "prepared" | "sending"))
}
/// Historical identities retained for validating saved sessions and receipts.
/// These rows must never populate the active provider catalog.
pub(crate) fn historical_models() -> Vec<Model> {
    [
        ("deepseek-v4-flash", "V4 Flash", "dsh"),
        ("deepseek-v4-pro", "V4 Pro", "dsh"),
        ("deepseek-v4-flash-vision-exp", "Flash Exp", "dsh"),
        ("claude-sonnet-5", "Sonnet 5", "claude-code"),
        ("claude-opus-5", "Opus 5", "claude-code"),
        ("claude-haiku-4-5-20251001", "Haiku 4.5", "claude-code"),
        ("claude-fable-5-1", "Fable 5.1", "claude-code"),
        ("gpt-5.6", "GPT-5.6", "codex"),
        ("gpt-5.6-mini", "GPT-5.6 Mini", "codex"),
        ("gpt-5.6-nano", "GPT-5.6 Nano", "codex"),
        ("GLM-5.3", "GLM-5.3", "glm"),
        ("GLM-5.3-Flash", "GLM-5.3 Flash", "glm"),
    ]
    .map(|(id, name, harness)| Model {
        id: id.into(),
        name: name.into(),
        harness: harness.into(),
    })
    .to_vec()
}
pub(crate) fn env(models: &[Model]) -> Env {
    let mut env = Env {
        provider_ids: ["deepseek", "anthropic", "openai", "bigmodel"]
            .map(String::from)
            .to_vec(),
        ..Default::default()
    };
    for m in models {
        env.supported_models.push(m.id.clone());
        env.harness_by_model.insert(m.id.clone(), m.harness.clone());
        let host = match m.harness.as_str() {
            "claude-code" => "api.anthropic.com",
            "codex" => "api.openai.com",
            "glm" => "open.bigmodel.cn",
            _ => "api.deepseek.com",
        };
        env.host_by_model.insert(m.id.clone(), host.into());
    }
    env
}
/// A native loaded snapshot or completion is already attested by the native
/// provider validator. Carry its binding facts into the same shared validator;
/// never infer a new binding from user text or a model response body.
pub(crate) fn native_binding_facts(value: &Value, env: &mut Env) {
    for key in ["model", "model_id", "requested_model"] {
        if let Some(model) = value.get(key).and_then(Value::as_str) {
            let codex = model.len() <= 80
                && model
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
                && (model.starts_with("gpt-")
                    || model.starts_with("codex-")
                    || (model.starts_with('o')
                        && model.as_bytes().get(1).is_some_and(u8::is_ascii_digit)));
            if codex && !env.supported_models.iter().any(|m| m == model) {
                env.supported_models.push(model.into());
                env.harness_by_model.insert(model.into(), "codex".into());
                env.host_by_model
                    .insert(model.into(), "api.openai.com".into());
            }
        }
    }
    if let Some(binding) = value.get("provider_configuration") {
        if let Some(key) = session_schema::binding_key(binding, value.get("model")) {
            if !env
                .provider_bindings
                .iter()
                .any(|b| b.canonical_sha256 == key)
            {
                env.provider_bindings.push(ProviderBinding {
                    canonical_sha256: key,
                    valid: crate::custom_provider_catalog::binding_valid(value, env)
                        .unwrap_or(true),
                    host: binding["endpoint_url"]
                        .as_str()
                        .and_then(|raw| url::Url::parse(raw).ok())
                        .and_then(|url| {
                            url.host_str()
                                .map(|host| host.trim_matches(['[', ']']).to_lowercase())
                        }),
                });
            }
        }
    }
    match value {
        Value::Array(items) => {
            for item in items {
                native_binding_facts(item, env);
            }
        }
        Value::Object(items) => {
            for item in items.values() {
                native_binding_facts(item, env);
            }
        }
        _ => {}
    }
}
pub(crate) fn empty_session() -> Value {
    json!({
        "schema_version":9,"workspace_authority_outbox":[],"agent_transcript_cleanup_outbox":[],
        "project_context_destructive_epoch":0,"project_context_destructive_transition":null,
        "active_conversation_id":null,"conversations":[],"messages":[],"session_events":[],
        "preferences": {
            "schema_version":1,"theme_mode":"system","locale":"system","default_model":null,
            "selected_harness_id":null,"thinking_mode":"high","tool_permission":"read-only",
            "show_reasoning":false,"auto_expand_tools":false,"confirm_destructive_file_actions":true,"git_https_proxy_url":null,
            "mirrors":{"alpine":{"enabled":false,"base_url":"https://dl-cdn.alpinelinux.org/alpine/"},
                "pip":{"enabled":false,"base_url":"https://pypi.org/simple/"},"npm":{"enabled":false,"base_url":"https://registry.npmjs.org/"}}
        }
    })
}
