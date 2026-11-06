//! UI-independent GPUI state and native session transactions.
//!
//! The native snapshot remains the source of truth. Mutations clone its JSON
//! tree, preserve all unrelated journals, and publish only after native CAS.
mod agent_commands;
mod agent_controller;
mod agent_lifecycle;
mod agent_presentations;
mod agent_preview;
mod agent_results;
mod agent_types;
mod assistant_chat;
pub mod assistant_store;
mod composer_drafts;
#[cfg(test)]
mod composer_drafts_tests;
mod controller;
mod custom_provider_catalog;
mod provider_catalog;
pub use agent_types::{
    AgentApprovalView, AgentPresentation, AgentQuestionView, AgentToolView, AgentView,
};
pub use rish_agent_core::custom_provider_registry;
pub use rish_agent_core::provider_model_catalog;
pub use rish_agent_core::provider_model_discovery;
mod model;
mod subscription_models;
mod workspace;
pub use workspace::workspace_binding;
#[cfg(test)]
mod agent_tests;
#[cfg(test)]
mod tests;
#[cfg(test)]
mod workspace_tests;
use model::*;
pub use model::{
    ConflictKind, ConversationSummary, Message, Model, PendingConflict, Result, RuntimeCommand,
    TurnIds,
};
use rish_agent_core::{name_policy, session_schema};
use serde_json::{json, Value};

#[derive(Clone, Debug)]
pub(crate) struct PendingCommit {
    candidate: Value,
    digest: String,
    operation_id: String,
    next: Option<RuntimeCommand>,
    finish_turn: bool,
    retryable: bool,
    drafts: composer_drafts::DraftCommit,
}
#[derive(Clone, Debug)]
pub(crate) struct Sending {
    conversation_id: String,
    ids: TurnIds,
    request: Value,
}
#[derive(Clone, Debug)]
struct ConflictedAnswer {
    conversation_id: String,
    attempt_id: String,
    before: Value,
    after: Value,
}
#[derive(Clone, Debug)]
pub struct ShellState {
    pub(crate) session: Value,
    pub(crate) authority: Value,
    pub(crate) catalog: Vec<Model>,
    pub(crate) provider_catalog_snapshot: Value,
    pub(crate) codex_subscription_catalog: Option<Vec<Model>>,
    pub(crate) environment: session_schema::Env,
    pub(crate) custom_registry: Value,
    pub(crate) custom_provider_names: std::collections::BTreeMap<String, String>,
    pub(crate) custom_model_names: std::collections::BTreeMap<String, String>,
    pub(crate) pending: Option<PendingCommit>,
    pub(crate) sending: Option<Sending>,
    pub(crate) agent_run: Option<agent_types::AgentRun>,
    pub(crate) agent_presentations: std::collections::HashMap<String, Vec<AgentPresentation>>,
    pub(crate) agent_presentation_versions: std::collections::HashMap<String, usize>,
    pub(crate) error: Option<String>,
    pub(crate) loaded: bool,
    pub(crate) default_workspace: Option<Value>,
    pub(crate) stale_writer: bool,
    pub(crate) assistant_conversation: Option<String>,
    pub(crate) assistant_profile: Option<assistant_store::AssistantProfile>,
    conflicted_answer: Option<ConflictedAnswer>,
    composer_drafts: composer_drafts::DraftState,
}
impl Default for ShellState {
    fn default() -> Self {
        Self::new()
    }
}
impl ShellState {
    pub fn new() -> Self {
        let catalog = Vec::new();
        Self {
            session: empty_session(),
            authority: json!({"schema_version":1,"kind":"missing"}),
            environment: env(&historical_models()),
            provider_catalog_snapshot: Value::Null,
            codex_subscription_catalog: None,
            custom_registry: json!({"schema_version":1,"revision":0,"providers":[]}),
            custom_provider_names: Default::default(),
            custom_model_names: Default::default(),
            catalog,
            pending: None,
            sending: None,
            agent_run: None,
            agent_presentations: Default::default(),
            agent_presentation_versions: Default::default(),
            error: None,
            loaded: false,
            default_workspace: None,
            stale_writer: false,
            assistant_conversation: None,
            assistant_profile: None,
            conflicted_answer: None,
            composer_drafts: Default::default(),
        }
    }
    /// Tests which need provider choices must opt in to an explicit fixture.
    /// Production construction and empty-catalog tests always use `new()`.
    #[cfg(any(test, feature = "test-support"))]
    pub fn with_test_models() -> Self {
        let mut state = Self::new();
        let models = historical_models();
        let providers: Vec<Value> = ["dsh", "claude-code", "codex", "glm"].iter().map(|h| json!({
            "harness_id":h,"models":models.iter().filter(|m| m.harness == *h).map(|m| json!({
                "id":m.id,"name":m.name,"supports_images":false
            })).collect::<Vec<_>>(),"retired_models":[]
        })).collect();
        state
            .apply_provider_catalog(json!({"schema_version":1,"revision":0,"providers":providers}))
            .expect("explicit test provider catalog");
        state
    }
    pub fn bootstrap_command(&self) -> RuntimeCommand {
        RuntimeCommand::new("LocalRuntime", "listProviderModels", vec![])
    }
    pub fn load_command(&self) -> RuntimeCommand {
        RuntimeCommand::new("SessionSnapshots", "loadSessionSnapshot", vec![])
    }
    pub fn load_snapshot(&mut self, value: Value) -> Result<()> {
        if self.pending.is_some() || self.sending.is_some() || self.agent_run.is_some() {
            return Err("Resolve the pending native transaction before reloading".into());
        }
        let v = decode(value)?;
        if v["schema_version"] != 1 {
            return Err("Unsupported native snapshot envelope".into());
        }
        let (session, authority) = match text(&v, "status") {
            "missing" => {
                let mut session = empty_session();
                if let Some(model) = self.catalog.first() {
                    session["preferences"]["default_model"] = json!(model.id);
                    session["preferences"]["selected_harness_id"] = json!(model.harness);
                }
                (session, json!({"schema_version":1,"kind":"missing"}))
            }
            "present" => {
                let raw = v["session_json"]
                    .as_str()
                    .ok_or("Missing native session bytes")?;
                let s: Value =
                    serde_json::from_str(raw).map_err(|_| "Invalid native session JSON")?;
                if s["schema_version"] != 9 && s["schema_version"] != 10 {
                    return Err(
                        "This session requires migration by the existing mobile application".into(),
                    );
                }
                let digest = session_schema::candidate_digest(raw.as_bytes())
                    .ok_or("Invalid native session digest")?;
                if text(&v["snapshot"], "session_sha256") != digest
                    || v["snapshot"]["generation"].as_u64().unwrap_or(0) == 0
                {
                    return Err("Native session authority does not match its content".into());
                }
                custom_provider_catalog::validate_native_bindings(&s, &self.environment)?;
                native_binding_facts(&s, &mut self.environment);
                (
                    s,
                    json!({"schema_version":1,"kind":"present","snapshot":v["snapshot"]}),
                )
            }
            "legacy_present" => {
                return Err(
                    "Open this session once in the existing mobile app to migrate it safely".into(),
                )
            }
            _ => return Err("Native session could not be loaded".into()),
        };
        self.stale_writer = v["writer_launch_instance_id"].is_string()
            && v["current_launch_instance_id"].is_string()
            && v["writer_launch_instance_id"] != v["current_launch_instance_id"];
        self.session = session;
        self.authority = authority;
        self.loaded = true;
        self.error = None;
        Ok(())
    }
    pub fn is_loaded(&self) -> bool {
        self.loaded
    }
    pub fn is_busy(&self) -> bool {
        self.pending.is_some()
            || self.sending.is_some()
            || self.agent_run.is_some()
            || self.conflicted_answer.is_some()
    }
    /// A retained conflict needs a fresh native snapshot, but a native write
    /// with an unresolved outcome or a running provider must settle first.
    pub fn can_reload(&self) -> bool {
        self.pending.is_none() && self.sending.is_none() && self.agent_run.is_none()
    }
    pub fn last_error(&self) -> Option<&str> {
        self.error.as_deref()
    }
    pub fn raw_session(&self) -> &Value {
        &self.session
    }
    pub fn preferences(&self) -> &Value {
        &self.session["preferences"]
    }
    pub fn active_conversation_id(&self) -> Option<&str> {
        self.session["active_conversation_id"].as_str()
    }
    pub fn selected_model(&self) -> &str {
        self.selected()
            .map(|c| text(c, "model_id"))
            .unwrap_or_else(|| self.preferences()["default_model"].as_str().unwrap_or(""))
    }
    pub fn selected_thinking(&self) -> &str {
        self.selected()
            .map(|c| text(c, "thinking_mode"))
            .unwrap_or("high")
    }
    pub fn models(&self) -> Vec<Model> {
        self.catalog.clone()
    }
    pub fn conversations(&self) -> Vec<ConversationSummary> {
        let mut list: Vec<_> = rows(&self.session, "conversations")
            .iter()
            .map(|c| ConversationSummary {
                id: text(c, "id").into(),
                title: text(c, "title").into(),
                model: text(c, "model_id").into(),
                thinking: text(c, "thinking_mode").into(),
                updated_at: text(c, "updated_at").into(),
                has_active_attempt: active(c),
            })
            .collect();
        list.sort_by(|a, b| b.updated_at.cmp(&a.updated_at));
        list
    }
    pub fn messages(&self) -> Vec<Message> {
        self.selected()
            .map(|c| rows(c, "messages"))
            .unwrap_or(&[])
            .iter()
            .map(|m| Message {
                id: text(m, "id").into(),
                role: text(m, "role").into(),
                text: text(m, "text").into(),
                reasoning: text(&m["metadata"], "reasoning").into(),
            })
            .collect()
    }
    pub(crate) fn selected(&self) -> Option<&Value> {
        let id = self.active_conversation_id()?;
        rows(&self.session, "conversations")
            .iter()
            .find(|c| text(c, "id") == id)
    }
    pub(crate) fn ready(&self) -> Result<()> {
        if !self.loaded {
            Err("Load the native session first".into())
        } else if self.is_busy() {
            Err("A native operation is still in progress".into())
        } else {
            Ok(())
        }
    }
    pub fn create_conversation(
        &mut self,
        id: &str,
        now: &str,
        model: &str,
    ) -> Result<RuntimeCommand> {
        self.create_conversation_configured(id, now, model, "high")
    }

    pub fn select_conversation(&mut self, id: &str) -> Result<RuntimeCommand> {
        self.ready()?;
        if !rows(&self.session, "conversations")
            .iter()
            .any(|c| text(c, "id") == id)
        {
            return Err("Conversation not found".into());
        }
        let mut next = self.session.clone();
        next["active_conversation_id"] = json!(id);
        self.commit(next, None, false)
    }
    pub fn rename_conversation(&mut self, id: &str, title: &str) -> Result<RuntimeCommand> {
        self.ready()?;
        let title = name_policy::normalize(name_policy::NameKind::Conversation, title)
            .map_err(|issue| format!("Invalid conversation title: {}", issue.as_str()))?;
        let mut next = self.session.clone();
        let c = conversation_mut(&mut next, id)?;
        c["title"] = json!(title);
        c["title_source"] = json!("manual");
        self.commit(next, None, false)
    }
    pub fn set_model(&mut self, model: &str) -> Result<RuntimeCommand> {
        self.ready()?;
        if !self.catalog.iter().any(|m| m.id == model) {
            return Err("Choose a current model".into());
        }
        let mut next = self.session.clone();
        let c = selected_mut(&mut next)?;
        if active(c) || !c["project_context"].is_null() {
            return Err(
                "Finish the active task and reconfirm project context before switching models"
                    .into(),
            );
        }
        c["model_id"] = json!(model);
        self.commit(next, None, false)
    }
    /// Change the model used by future chats without altering existing
    /// conversation choices or the independently selected execution runtime.
    pub fn set_default_model(&mut self, model: &str) -> Result<RuntimeCommand> {
        self.ready()?;
        if !self.catalog.iter().any(|entry| entry.id == model) {
            return Err("Choose a current model".into());
        }
        let mut next = self.session.clone();
        next["preferences"]["default_model"] = json!(model);
        self.commit(next, None, false)
    }
    pub fn set_thinking(&mut self, mode: &str) -> Result<RuntimeCommand> {
        self.ready()?;
        if !["off", "high", "max"].contains(&mode) {
            return Err("Invalid thinking mode".into());
        }
        let mut next = self.session.clone();
        let c = selected_mut(&mut next)?;
        if active(c) {
            return Err("Finish the active task before changing its settings".into());
        }
        c["thinking_mode"] = json!(mode);
        self.commit(next, None, false)
    }

    /// Commit the configuration card atomically without changing active tasks
    /// or silently reusing project consent for a different model.
    pub fn set_chat_configuration(
        &mut self,
        model: &str,
        thinking: &str,
    ) -> Result<RuntimeCommand> {
        self.ready()?;
        if !["off", "high", "max"].contains(&thinking) {
            return Err("Invalid thinking mode".into());
        }
        let mut next = self.session.clone();
        let c = selected_mut(&mut next)?;
        let changing_model = text(c, "model_id") != model;
        if changing_model && !self.catalog.iter().any(|m| m.id == model) {
            return Err("Choose a current model".into());
        }
        if active(c) {
            return Err("Finish the active task before changing its settings".into());
        }
        if changing_model && !c["project_context"].is_null() {
            return Err("Reconfirm project context before switching models".into());
        }
        c["model_id"] = json!(model);
        c["thinking_mode"] = json!(thinking);
        self.commit(next, None, false)
    }
    pub fn set_preference(&mut self, key: &str, value: Value) -> Result<RuntimeCommand> {
        self.ready()?;
        if ![
            "theme_mode",
            "locale",
            "show_reasoning",
            "auto_expand_tools",
            "confirm_destructive_file_actions",
        ]
        .contains(&key)
        {
            return Err("This preference requires its native configuration workflow".into());
        }
        let mut next = self.session.clone();
        next["preferences"][key] = value;
        self.commit(next, None, false)
    }
    pub(crate) fn commit(
        &mut self,
        candidate: Value,
        next: Option<RuntimeCommand>,
        finish_turn: bool,
    ) -> Result<RuntimeCommand> {
        self.commit_with_draft_effect(candidate, next, finish_turn, Default::default())
    }
    pub(crate) fn commit_with_draft_effect(
        &mut self,
        mut candidate: Value,
        next: Option<RuntimeCommand>,
        finish_turn: bool,
        draft_effect: composer_drafts::DraftEffect,
    ) -> Result<RuntimeCommand> {
        if self.pending.is_some() {
            return Err("A session commit is already pending".into());
        }
        let drafts = self.merge_composer_drafts(&mut candidate, draft_effect)?;
        candidate["messages"] = candidate["active_conversation_id"]
            .as_str()
            .and_then(|id| {
                rows(&candidate, "conversations")
                    .iter()
                    .find(|c| text(c, "id") == id)
            })
            .map(|c| c["messages"].clone())
            .unwrap_or(json!([]));
        let bytes = serde_json::to_vec(&candidate).map_err(|_| "Cannot encode the session")?;
        let validated =
            session_schema::validate_candidate(&bytes, &self.environment).map_err(|_| {
                "The shared native schema rejected this change; the saved session is unchanged"
            })?;
        let operation_id = id();
        let command = RuntimeCommand::new(
            "SessionSnapshots",
            "casPersistSession",
            vec![json!({
                "schema_version":1,"operation_id":operation_id,"expected":self.authority,"candidate_json":String::from_utf8(bytes).map_err(|_|"Invalid session encoding")?
            })],
        );
        self.pending = Some(PendingCommit {
            candidate,
            digest: validated.digest,
            operation_id,
            next,
            finish_turn,
            retryable: false,
            drafts,
        });
        self.error = None;
        Ok(command)
    }
    pub fn accept_persist(&mut self, value: Value) -> Result<Option<RuntimeCommand>> {
        let v = decode(value)?;
        let p = self
            .pending
            .as_ref()
            .ok_or("No session commit is pending")?;
        match text(&v, "status") {
            "committed" => {
                let previous = self.authority["snapshot"]["generation"]
                    .as_u64()
                    .unwrap_or(0);
                if v["snapshot"]["schema_version"] != 1
                    || text(&v["snapshot"], "session_sha256") != p.digest
                    || v["snapshot"]["generation"].as_u64() != Some(previous + 1)
                {
                    return Err("Native commit proof does not match the pending session".into());
                }
                let p = self.pending.take().unwrap();
                self.acknowledge_composer_drafts(&p.candidate, &p.drafts);
                self.session = p.candidate;
                self.authority =
                    json!({"schema_version":1,"kind":"present","snapshot":v["snapshot"]});
                if p.finish_turn {
                    self.sending = None;
                    self.conflicted_answer = None;
                }
                self.error = None;
                if p.next.as_ref().is_some_and(|n| n.module == "ShellAgent") {
                    self.advance_agent()
                } else {
                    if p.finish_turn {
                        self.agent_run = None;
                    }
                    Ok(p.next)
                }
            }
            "not_committed" | "not_started" => {
                let p = self.pending.as_mut().unwrap();
                if p.finish_turn || self.agent_run.is_some() {
                    p.retryable = true;
                    self.error = Some(
                        "The answer is ready but was not saved. Retry the same session write."
                            .into(),
                    );
                } else {
                    let p = self.pending.take().unwrap();
                    if p.next.is_some() {
                        self.sending = None;
                    }
                    self.error=Some("The session write did not commit. The saved session is unchanged; retry the action.".into());
                }
                Err(self.error.clone().unwrap())
            }
            "conflict" => {
                if let (Some(p), Some(send)) = (&self.pending, &self.sending) {
                    if p.finish_turn {
                        let before = rows(&self.session, "conversations")
                            .iter()
                            .find(|c| text(c, "id") == send.conversation_id)
                            .cloned();
                        let after = rows(&p.candidate, "conversations")
                            .iter()
                            .find(|c| text(c, "id") == send.conversation_id)
                            .cloned();
                        if let (Some(before), Some(after)) = (before, after) {
                            self.conflicted_answer = Some(ConflictedAnswer {
                                conversation_id: send.conversation_id.clone(),
                                attempt_id: send.ids.attempt_id.clone(),
                                before,
                                after,
                            });
                        }
                    }
                }
                self.pending = None;
                self.sending = None;
                self.agent_run = None;
                self.error = Some(
                    "The session changed in another operation. Reload it before retrying.".into(),
                );
                self.loaded = false;
                Err(self.error.clone().unwrap())
            }
            _ => {
                self.error=Some("The native commit outcome is unresolved. Check the transaction before retrying.".into());
                Err(self.error.clone().unwrap())
            }
        }
    }
    pub fn retry_pending_commit(&mut self) -> Option<RuntimeCommand> {
        let p = self.pending.as_mut()?;
        if !p.retryable {
            return None;
        }
        p.retryable = false;
        Some(RuntimeCommand::new(
            "SessionSnapshots",
            "casPersistSession",
            vec![json!({
                "schema_version":1,"operation_id":p.operation_id,"expected":self.authority,"candidate_json":p.candidate.to_string()
            })],
        ))
    }
    /// Reconcile only text attempts whose native envelope proves the writer
    /// process is gone. Agent journals require the native Agent recovery path.
    pub fn recovery_command(&mut self, now: &str) -> Result<Option<RuntimeCommand>> {
        if !self.loaded
            || self.pending.is_some()
            || self.sending.is_some()
            || self.agent_run.is_some()
        {
            return Err("Load the native session before recovery".into());
        }
        if !self.stale_writer && self.conflicted_answer.is_none() {
            return Ok(None);
        }
        let mut candidate = self.session.clone();
        let mut changed = false;
        let reconciling = self.conflicted_answer.is_some();
        if let Some(answer) = &self.conflicted_answer {
            // Catalog refresh precedes snapshot reload. The first response
            // from a configured provider may be present only in this retained
            // native-attested result, so restore its validator facts here.
            native_binding_facts(&answer.after, &mut self.environment);
            let current = conversation_mut(&mut candidate, &answer.conversation_id)?;
            let settled = rows(&answer.after, "attempts")
                .iter()
                .find(|a| text(a, "attempt_id") == answer.attempt_id)
                .ok_or("Missing retained attempt")?;
            if matches!(text(settled, "status"), "failed" | "cancelled") {
                let before = rows(&answer.before, "attempts")
                    .iter()
                    .find(|a| text(a, "attempt_id") == answer.attempt_id)
                    .ok_or("Missing original attempt")?;
                let target = current["attempts"]
                    .as_array_mut()
                    .ok_or("Missing attempts")?
                    .iter_mut()
                    .find(|a| text(a, "attempt_id") == answer.attempt_id)
                    .ok_or("The settled attempt no longer exists; review the retained conflict")?;
                if !before["agent"].is_null() || target != before {
                    return Err("The attempt changed while saving its outcome. Review the retained conflict before discarding it.".into());
                }
                // A known native failure/cancellation settles only its exact
                // original attempt; unrelated title/context/messages survive.
                *target = settled.clone();
            } else {
                if current != &answer.before {
                    return Err("The conversation changed while saving the answer. The unsaved answer is retained for review; it has not been resent.".into());
                }
                *current = answer.after.clone();
            }
            changed = true;
        }
        for c in candidate["conversations"]
            .as_array_mut()
            .ok_or("Missing conversations")?
        {
            for a in c["attempts"].as_array_mut().ok_or("Missing attempts")? {
                if self.stale_writer
                    && a["agent"].is_null()
                    && matches!(text(a, "status"), "prepared" | "sending")
                    // A bound prepared attempt is the initial Agent user
                    // checkpoint. Native preparation is idempotent and must
                    // recover it before any provider round is dispatched.
                    && !(a["status"] == "prepared" && a["workspace_id"].is_string())
                {
                    a["status"] = json!("failed");
                    a["failure_code"] = json!("E_ATTEMPT_INTERRUPTED");
                    a["active_round"] = Value::Null;
                    if now > text(a, "updated_at") {
                        a["updated_at"] = json!(now);
                    }
                    changed = true;
                }
            }
        }
        if changed {
            self.commit(candidate, None, reconciling).map(Some)
        } else {
            Ok(None)
        }
    }
    pub fn unsaved_answer(&self) -> Option<Message> {
        let answer = self.conflicted_answer.as_ref()?;
        let attempt = rows(&answer.after, "attempts")
            .iter()
            .find(|a| text(a, "attempt_id") == answer.attempt_id)?;
        if attempt["status"] != "completed" {
            return None;
        }
        let message = rows(&answer.after, "messages")
            .iter()
            .find(|message| message["id"] == attempt["assistant_message_id"])?;
        Some(Message {
            id: text(message, "id").into(),
            role: "assistant".into(),
            text: text(message, "text").into(),
            reasoning: text(&message["metadata"], "reasoning").into(),
        })
    }
    pub fn pending_conflict(&self) -> Option<PendingConflict> {
        let retained = self.conflicted_answer.as_ref()?;
        let attempt = rows(&retained.after, "attempts")
            .iter()
            .find(|a| text(a, "attempt_id") == retained.attempt_id)?;
        let kind = match text(attempt, "status") {
            "failed" => ConflictKind::Failed,
            "cancelled" => ConflictKind::Cancelled,
            _ => ConflictKind::Answer,
        };
        Some(PendingConflict {
            conversation_id: retained.conversation_id.clone(),
            attempt_id: retained.attempt_id.clone(),
            kind,
            answer: self.unsaved_answer(),
        })
    }
    pub fn discard_pending_conflict(&mut self) -> Result<()> {
        if !self.can_reload() {
            return Err("Resolve the native write first".into());
        }
        self.conflicted_answer = None;
        Ok(())
    }
    /// Explicit UI action after the person has reviewed/copied the unsaved
    /// answer. This only drops the in-memory result, never saved native data.
    pub fn discard_unsaved_answer(&mut self) -> Result<()> {
        self.discard_pending_conflict()
    }
    pub fn query_pending_commit(&self) -> Option<RuntimeCommand> {
        self.pending.as_ref().map(|p| {
            RuntimeCommand::new(
                "SessionSnapshots",
                "querySessionCommit",
                vec![json!({"schema_version":1,"operation_id":p.operation_id})],
            )
        })
    }
    /// Keep unresolved native transactions intact. A bridge exception does not
    /// prove that the write failed and must never permit a duplicate send.
    pub fn record_error(&mut self, message: impl Into<String>) {
        self.error = Some(message.into());
    }
}
pub(crate) fn conversation_mut<'a>(s: &'a mut Value, id: &str) -> Result<&'a mut Value> {
    s["conversations"]
        .as_array_mut()
        .ok_or("Missing conversations")?
        .iter_mut()
        .find(|c| text(c, "id") == id)
        .ok_or_else(|| "Conversation not found".into())
}
pub(crate) fn selected_mut(s: &mut Value) -> Result<&mut Value> {
    let id = text(s, "active_conversation_id").to_owned();
    conversation_mut(s, &id)
}
