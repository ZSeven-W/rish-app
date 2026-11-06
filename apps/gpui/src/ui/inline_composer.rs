//! Native editor transport stays outside the Shell auxiliary-operation lane.
use super::inline_composer_state::{
    InlineComposerState, InputGeometry, Snapshot, SnapshotAcceptance, SnapshotStatus,
};
use super::{Reply, Shell, Text, name_prompt};
use gpui::{Context, IntoElement};
#[path = "inline_composer_actions.rs"]
mod actions;
#[path = "inline_composer_view.rs"]
mod view;
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};

#[derive(Clone, Debug, PartialEq)]
pub(super) enum InlineAction {
    Send,
    AnswerQuestion(String),
    Create,
    Assistant,
    AssistantHub,
    AssistantBot(String),
    AssistantGroup(String),
    Select(String),
    Bind(Value),
}
impl InlineAction {
    fn is_navigation(&self) -> bool {
        matches!(
            self,
            Self::Create
                | Self::Select(_)
                | Self::Assistant
                | Self::AssistantHub
                | Self::AssistantBot(_)
                | Self::AssistantGroup(_)
        )
    }
    fn is_submission(&self) -> bool {
        matches!(self, Self::Send | Self::AnswerQuestion(_))
    }
}
#[derive(Clone, Debug)]
struct ActionRequest {
    id: String,
    action: InlineAction,
    session: String,
    text_revision: u64,
    conversation: String,
}
#[derive(Clone, Debug)]
struct Draft {
    text: String,
    session: String,
    text_revision: u64,
    native_revision: u64,
}
#[derive(Clone, Debug)]
struct SyncRequest {
    id: String,
    payload: Value,
    key: Value,
    foreground_epoch: u64,
}
#[derive(Clone, Debug)]
struct SentDraft {
    session: String,
    text_revision: u64,
    native_revision: u64,
    text: String,
}

#[derive(Default)]
pub(super) struct InlineComposer {
    state: InlineComposerState,
    viewport: [f32; 2],
    scale: f32,
    rect: [f32; 4],
    visible: bool,
    focus: Option<bool>,
    desired: Option<Value>,
    last_key: Option<Value>,
    failed_key: Option<Value>,
    foreground_epoch: u64,
    sync: Option<SyncRequest>,
    wait: Option<String>,
    wait_cursor: u64,
    native_session: Option<String>,
    attached_session: Option<String>,
    // A dispatched request may attach before its reply fails or is rejected.
    // Lack of an ACK is not proof that the native text view is absent.
    attachment_unknown: Option<String>,
    scheduled: bool,
    closing: Vec<String>,
    closing_inflight: HashSet<String>,
    drafts: HashMap<String, Draft>,
    action: Option<ActionRequest>,
    action_inflight: bool,
    permit: Option<InlineAction>,
    sent: Option<SentDraft>,
    queued_send: Option<String>,
    clear_inflight: bool,
}

impl InlineComposer {
    fn fallback_visible(&self) -> bool {
        self.attached_session.is_none()
            && self.attachment_unknown.is_none()
            && self.sync.is_none()
            && (self.failed_key.is_some() || self.state.is_closed())
    }
    fn confirm_closed(&mut self, snapshot: &Snapshot) -> bool {
        if snapshot.status != SnapshotStatus::Closed {
            return false;
        }
        let mut changed = false;
        if self.attached_session.as_deref() == Some(&snapshot.session_id) {
            self.attached_session = None;
            changed = true;
        }
        if self.attachment_unknown.as_deref() == Some(&snapshot.session_id) {
            self.attachment_unknown = None;
            changed = true;
        }
        changed
    }
}

impl Shell {
    pub(super) fn cancel_pending_inline_navigation(&mut self) {
        if self
            .inline_composer
            .action
            .as_ref()
            .is_some_and(|r| r.action.is_navigation())
        {
            self.inline_composer.action = None;
            self.inline_composer.action_inflight = false;
        }
        if self
            .inline_composer
            .permit
            .as_ref()
            .is_some_and(InlineAction::is_navigation)
        {
            self.inline_composer.permit = None;
        }
    }
    pub(super) fn resume_inline_after_foreground(&mut self, cx: &mut Context<Self>) {
        self.inline_composer.foreground_epoch =
            self.inline_composer.foreground_epoch.wrapping_add(1);
        self.inline_composer.failed_key = None;
        // Normal reconciliation owns pending snapshots, closed receipts, text
        // revisions and actions. A lifecycle event changes none of them.
        self.defer_inline_update(cx);
    }

    pub(super) fn inline_allows_assistant_handoff(&self) -> bool {
        self.inline_composer.action.is_none()
            && !self.inline_composer.action_inflight
            && !self.inline_composer.clear_inflight
            && self.inline_composer.closing_inflight.is_empty()
            && !self.inline_composer.state.composing()
    }
    pub(super) fn prepare_inline_composer(
        &mut self,
        visible: bool,
        viewport: [f32; 2],
        scale: f32,
        cx: &mut Context<Self>,
    ) {
        if !self.runtime.is_native() {
            return;
        }
        self.inline_composer.visible = visible;
        self.inline_composer.viewport = viewport;
        self.inline_composer.scale = scale;
        self.inline_composer.state.set_viewport_height(viewport[1]);
        self.defer_inline_update(cx);
    }
    pub(super) fn inline_keyboard_bottom(&self) -> f32 {
        if self.inline_composer.visible
            && !self.native_form_active
            && self.inline_composer.state.focused()
            && self.inline_composer.state.current_conversation_key()
                == Some(self.inline_conversation_key().as_str())
        {
            self.inline_composer.state.bottom_inset(0.)
        } else {
            0.
        }
    }
    #[cfg_attr(not(any(target_os = "ios", target_os = "android")), allow(dead_code))]
    pub(super) fn inline_composer_element(
        &self,
        max_height: f32,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        view::element(self, max_height, cx)
    }
    fn defer_inline_update(&mut self, cx: &mut Context<Self>) {
        if self.inline_composer.scheduled {
            return;
        }
        self.inline_composer.scheduled = true;
        let weak = cx.weak_entity();
        cx.defer(move |cx| {
            let _ = weak.update(cx, |this, cx| {
                this.inline_composer.scheduled = false;
                this.update_inline_composer(cx);
            });
        });
    }
    pub(super) fn inline_conversation_key(&self) -> String {
        if self.assistant_group_visible() {
            return format!(
                "assistant-group-{}",
                self.assistant.directory_ui.group_id.as_deref().unwrap()
            );
        }
        self.state
            .active_conversation_id()
            .unwrap_or("new-draft")
            .to_owned()
    }
    #[cfg(test)]
    pub(super) fn test_inline_identity(&self) -> (Option<String>, Option<String>) {
        (
            self.inline_composer.state.session_id().map(str::to_owned),
            self.inline_composer
                .state
                .current_conversation_key()
                .map(str::to_owned),
        )
    }
    #[cfg(test)]
    pub(super) fn test_align_inline_session(&mut self, force: bool, cx: &mut Context<Self>) {
        self.align_inline_session(force, cx);
    }
    pub(super) fn align_inline_session(&mut self, force: bool, cx: &mut Context<Self>) {
        let key = self.inline_conversation_key();
        let personal = self.assistant_group_visible()
            || self.state.assistant_conversation_id() == Some(key.as_str());
        let current = self
            .inline_composer
            .state
            .current_conversation_key()
            .map(str::to_owned);
        let entity_text = self.composer.read(cx).text();
        let from_snapshot = self.composer_drafts.restoring_snapshot;
        let restoring = self.state.is_loaded() && (!self.composer_drafts.hydrated || from_snapshot);
        if restoring {
            // Initial empty transport state is not an intentional deletion.
            // Input typed while loading stays attached to its original key.
            if !from_snapshot && !entity_text.is_empty() {
                let old = current.as_deref().unwrap_or(&key);
                self.record_composer_draft(old, &entity_text, cx);
            }
            self.composer_drafts.hydrated = true;
            self.composer_drafts.restoring_snapshot = false;
        }
        if self.composer_drafts.rejected_text && current.as_deref() != Some(&key) {
            // A load may discover another active chat before an oversized
            // early input has a durable home. Keep its original editor/key.
            if current.is_none() {
                self.inline_composer.state.begin_session(&key, &entity_text);
            }
            self.inline_composer
                .state
                .observe_external_text(&entity_text);
            self.remember_inline_draft(cx);
            if self.composer_drafts.rejected_text {
                return;
            }
        }
        if !restoring
            && current.as_deref() == Some("new-draft")
            && key != "new-draft"
            && !personal
            && (!self.state.is_loaded()
                || (self.state.composer_draft("new-draft").is_empty()
                    && self.state.composer_draft(&key) == entity_text))
            && !self.inline_composer.state.is_closed()
        {
            self.inline_composer
                .state
                .observe_external_text(&entity_text);
            if self.inline_composer.state.adopt_initial_conversation(&key) {
                self.inline_composer.drafts.remove("new-draft");
                self.remember_inline_draft(cx);
                return;
            }
        }
        if self.inline_composer.state.is_closed() && !self.inline_composer.visible && !force {
            return;
        }
        let awaiting_clear = self.inline_composer.sent.as_ref().is_some_and(|sent| {
            Some(sent.session.as_str()) == self.inline_composer.state.session_id()
                && sent.text_revision == self.inline_composer.state.text_revision()
                && sent.text == entity_text
        });
        if (!restoring
            || entity_text == self.state.composer_draft(&key)
            || awaiting_clear
            || self.composer_drafts.rejected_text)
            && current.as_deref() == Some(&key)
            && !self.inline_composer.state.is_closed()
        {
            self.inline_composer
                .state
                .observe_external_text(&entity_text);
            self.remember_inline_draft(cx);
            return;
        }
        if restoring && current.as_deref() == Some(&key) && !self.inline_composer.state.is_closed()
        {
            let text = if key.starts_with("assistant-group-") {
                entity_text
            } else {
                self.state.composer_draft(&key).to_owned()
            };
            self.inline_composer.state.observe_external_text(&text);
            self.composer
                .update(cx, |input, cx| input.set_text(text, cx));
            self.remember_inline_draft(cx);
            return;
        }
        let mut text = entity_text;
        if current.as_deref() == Some(&key)
            && self.inline_composer.state.is_closed()
            && awaiting_clear
            && self.state.composer_draft(&key).is_empty()
        {
            // A terminal editor may be replaced after its sent text was
            // consumed durably, even if the earlier clear reply was lost.
            text.clear();
        }
        if let Some(old) = current.as_ref() {
            if !restoring {
                self.inline_composer.state.observe_external_text(&text);
                self.remember_inline_draft(cx);
            }
            if restoring || old != &key {
                text = if self.state.is_loaded() && !key.starts_with("assistant-group-") {
                    self.state.composer_draft(&key).to_owned()
                } else {
                    self.inline_composer
                        .drafts
                        .get(&key)
                        .map(|d| d.text.clone())
                        .unwrap_or_default()
                };
            }
            if let Some(session) = self.inline_composer.state.session_id() {
                self.inline_composer.closing.push(session.to_owned());
            }
        } else if restoring && !key.starts_with("assistant-group-") {
            text = self.state.composer_draft(&key).to_owned();
        }
        self.inline_composer.state.begin_session(&key, &text);
        self.inline_composer.wait_cursor = 0;
        self.inline_composer.last_key = None;
        self.inline_composer.native_session = None;
        self.inline_composer.failed_key = None;
        self.inline_composer.action = None;
        self.inline_composer.action_inflight = false;
        self.inline_composer.permit = None;
        if current.as_deref() != Some("new-draft") || personal {
            self.inline_composer.queued_send = None;
        }
        self.inline_composer.focus = None;
        if self.composer.read(cx).text() != text {
            self.composer
                .update(cx, |input, cx| input.set_text(text, cx));
        }
        self.remember_inline_draft(cx);
    }
    fn remember_inline_draft(&mut self, cx: &mut Context<Self>) {
        let state = &self.inline_composer.state;
        if let (Some(key), Some(session)) = (state.current_conversation_key(), state.session_id()) {
            let key = key.to_owned();
            let text = state.text().to_owned();
            let awaiting_clear = self.inline_composer.sent.as_ref().is_some_and(|sent| {
                sent.session == session
                    && sent.text_revision == state.text_revision()
                    && sent.text == text
            });
            if self.inline_composer.sent.as_ref().is_some_and(|sent| {
                sent.session == session
                    && (sent.text_revision != state.text_revision() || sent.text != text)
            }) {
                self.inline_composer.sent = None;
            }
            self.inline_composer.drafts.insert(
                key.clone(),
                Draft {
                    text: state.text().into(),
                    session: session.into(),
                    text_revision: state.text_revision(),
                    native_revision: state.native_revision(),
                },
            );
            if !awaiting_clear {
                self.record_composer_draft(&key, &text, cx);
            }
            self.schedule_composer_draft_save(cx);
        }
    }
    fn update_inline_composer(&mut self, cx: &mut Context<Self>) {
        self.align_inline_session(false, cx);
        if !self.runtime.is_native() {
            return;
        }
        let geometry = InputGeometry::new(
            self.inline_composer.rect,
            self.inline_composer.viewport,
            self.inline_composer.scale,
        );
        let visible = self.inline_composer.visible && !self.native_form_active;
        self.inline_composer.desired = self.inline_composer.state.sync_payload(
            geometry,
            visible,
            self.inline_composer.focus,
            name_prompt::appearance(cx),
            self.composer_placeholder(),
        );
        self.pump_inline(cx);
    }
    fn pump_inline(&mut self, cx: &mut Context<Self>) {
        for session in std::mem::take(&mut self.inline_composer.closing) {
            self.inline_composer
                .closing_inflight
                .insert(session.clone());
            let runtime = self.runtime.clone();
            cx.spawn(async move |this, cx| {
                let result = runtime
                    .call("ShellInput", "inlineClose", json!([{"session_id":session}]))
                    .await;
                let _ = this.update(cx, |this, cx| {
                    this.inline_composer.closing_inflight.remove(&session);
                    if let Ok(value) = result
                        && let Ok(snapshot) = Snapshot::parse(&value)
                        && snapshot.session_id == session
                    {
                        if this.inline_composer.confirm_closed(&snapshot) {
                            cx.notify();
                        }
                        this.remember_closed_inline(snapshot, cx);
                    }
                    this.start_inline_action(cx);
                    this.schedule_composer_draft_save(cx);
                });
            })
            .detach();
        }
        if !self.inline_composer.clear_inflight
            && self.inline_composer.sync.is_none()
            && let Some(payload) = self.inline_composer.desired.clone()
        {
            let key = sync_key(&payload);
            if self.inline_composer.last_key.as_ref() != Some(&key)
                && self.inline_composer.failed_key.as_ref() != Some(&key)
            {
                let request = SyncRequest {
                    id: uuid::Uuid::new_v4().to_string(),
                    payload: payload.clone(),
                    key,
                    foreground_epoch: self.inline_composer.foreground_epoch,
                };
                self.inline_composer.sync = Some(request.clone());
                self.inline_composer.attachment_unknown =
                    payload["session_id"].as_str().map(str::to_owned);
                let runtime = self.runtime.clone();
                cx.spawn(async move |this, cx| {
                    let result = runtime
                        .call("ShellInput", "inlineSync", json!([payload]))
                        .await;
                    let _ =
                        this.update(cx, |this, cx| this.accept_inline_sync(request, result, cx));
                })
                .detach();
            }
        }
        self.start_inline_wait(cx);
        self.start_inline_action(cx);
    }
    fn accept_inline_sync(
        &mut self,
        request: SyncRequest,
        result: Result<Value, String>,
        cx: &mut Context<Self>,
    ) {
        if self.inline_composer.sync.as_ref().map(|r| r.id.as_str()) != Some(&request.id) {
            return;
        }
        self.inline_composer.sync = None;
        let paused_reply = result.as_ref().err().is_some_and(|error| {
            error.contains("E_INLINE_COMPOSER_UNAVAILABLE")
                && request.foreground_epoch != self.inline_composer.foreground_epoch
        });
        let parsed = result.and_then(|value| {
            self.apply_inline_snapshot(&value, cx)
                .map_err(|_| "E_INLINE_COMPOSER_INVALID".to_owned())
        });
        match parsed {
            Ok(_) => {
                self.inline_composer.last_key = Some(request.key);
                if request.payload["session_id"].as_str() == self.inline_composer.state.session_id()
                    && !self.inline_composer.state.is_closed()
                {
                    self.inline_composer.native_session =
                        self.inline_composer.state.session_id().map(str::to_owned);
                    self.inline_composer.attached_session =
                        self.inline_composer.native_session.clone();
                    if self.inline_composer.attachment_unknown
                        == self.inline_composer.native_session
                    {
                        self.inline_composer.attachment_unknown = None;
                    }
                    if request.payload["focus"].is_boolean() {
                        self.inline_composer.focus = None;
                    }
                    if self.notice.as_deref() == Some(self.locale.text(Text::InlineUnavailable)) {
                        self.notice = None;
                    }
                }
            }
            Err(_) if paused_reply => {
                // A pre-resume refusal may arrive after the foreground event.
                // Retry only through the current, normally reconciled payload.
                self.inline_composer.failed_key = None;
            }
            Err(_) => {
                self.inline_composer.failed_key = Some(request.key);
                if request.payload["session_id"].as_str() == self.inline_composer.state.session_id()
                {
                    self.inline_composer.action = None;
                    self.inline_composer.action_inflight = false;
                    self.inline_error(cx);
                }
            }
        }
        if !self.inline_composer.state.is_closed() {
            self.update_inline_composer(cx);
        }
    }
    fn start_inline_wait(&mut self, cx: &mut Context<Self>) {
        if self.inline_composer.wait.is_some() || self.inline_composer.state.is_closed() {
            return;
        }
        let Some(session) = self
            .inline_composer
            .native_session
            .clone()
            .filter(|s| Some(s.as_str()) == self.inline_composer.state.session_id())
        else {
            return;
        };
        let after = self.inline_composer.wait_cursor;
        self.inline_composer.wait = Some(session.clone());
        let runtime = self.runtime.clone();
        cx.spawn(async move |this, cx| {
            let result = runtime
                .call(
                    "ShellInput",
                    "inlineWait",
                    json!([{"session_id":session,"after_revision":after}]),
                )
                .await;
            let _ = this.update(cx, |this, cx| this.accept_inline_wait(session, result, cx));
        })
        .detach();
    }
    fn accept_inline_wait(
        &mut self,
        session: String,
        result: Result<Value, String>,
        cx: &mut Context<Self>,
    ) {
        if self.inline_composer.wait.as_deref() != Some(&session) {
            return;
        }
        self.inline_composer.wait = None;
        let invalid = match result {
            Ok(value) => self.apply_inline_snapshot(&value, cx).is_err(),
            Err(_) => true,
        };
        if invalid && self.inline_composer.state.session_id() == Some(&session) {
            self.inline_composer.native_session = None;
            self.inline_composer.last_key = None;
            self.inline_composer.failed_key = self.inline_composer.desired.as_ref().map(sync_key);
            self.inline_error(cx);
        }
        if !self.inline_composer.state.is_closed() {
            self.start_inline_wait(cx);
            self.start_inline_action(cx);
        }
    }
    fn apply_inline_snapshot(
        &mut self,
        value: &Value,
        cx: &mut Context<Self>,
    ) -> Result<SnapshotAcceptance, ()> {
        let snapshot = Snapshot::parse(value).map_err(|_| ())?;
        if self.inline_composer.state.current_conversation_key()
            != Some(self.inline_conversation_key().as_str())
        {
            self.align_inline_session(false, cx);
            self.remember_closed_inline(snapshot, cx);
            return Ok(SnapshotAcceptance::StaleSession);
        }
        if self.inline_composer.state.is_closed() {
            self.remember_closed_inline(snapshot, cx);
            return Ok(SnapshotAcceptance::SessionClosed);
        }
        self.inline_composer
            .state
            .observe_external_text(&self.composer.read(cx).text());
        if self.inline_composer.state.session_id() == Some(&snapshot.session_id) {
            self.inline_composer.wait_cursor =
                self.inline_composer.wait_cursor.max(snapshot.revision);
        }
        let closed = snapshot.status == SnapshotStatus::Closed;
        let session = snapshot.session_id.clone();
        let outcome = self.inline_composer.state.accept(snapshot.clone());
        if self.inline_composer.confirm_closed(&snapshot) {
            cx.notify();
        }
        if closed && self.inline_composer.state.session_id() == Some(&session) {
            self.inline_composer.state.mark_closed(&session);
            self.inline_composer.native_session = None;
            cx.notify();
        }
        if outcome.is_accepted() {
            let text = self.inline_composer.state.text().to_owned();
            if self.composer.read(cx).text() != text {
                self.composer
                    .update(cx, |input, cx| input.set_text(text, cx));
            }
            self.remember_inline_draft(cx);
            if outcome != SnapshotAcceptance::Unchanged {
                cx.notify();
            }
        } else if outcome == SnapshotAcceptance::StaleSession {
            self.remember_closed_inline(snapshot, cx);
        }
        Ok(outcome)
    }
    pub(super) fn inline_text_for_send(&self, cx: &gpui::App) -> String {
        self.inline_composer
            .queued_send
            .clone()
            .unwrap_or_else(|| self.composer.read(cx).text())
    }
    pub(super) fn freeze_inline_send(&mut self, text: String) {
        self.inline_composer.queued_send = Some(text);
    }
    pub(super) fn cancel_inline_send_intent(&mut self) {
        self.inline_composer.queued_send = None;
    }
    pub(super) fn inline_will_send(&mut self, text: &str) {
        self.inline_composer.queued_send = None;
        if let Some(session) = self.inline_composer.state.session_id() {
            self.inline_composer.sent = Some(SentDraft {
                session: session.into(),
                text_revision: self.inline_composer.state.text_revision(),
                native_revision: self.inline_composer.state.native_revision(),
                text: text.into(),
            });
        }
    }
    pub(super) fn clear_sent_inline_draft(&mut self, cx: &mut Context<Self>) {
        if !self.runtime.is_native() {
            self.inline_composer.state.observe_external_text("");
            self.remember_inline_draft(cx);
            self.composer
                .update(cx, |input, cx| input.set_text(String::new(), cx));
            return;
        }
        let Some(sent) = self.inline_composer.sent.clone() else {
            return;
        };
        if self.inline_composer.clear_inflight {
            return;
        }
        self.inline_composer
            .state
            .observe_external_text(&self.composer.read(cx).text());
        if self.inline_composer.state.session_id() != Some(&sent.session)
            || self.inline_composer.state.text_revision() != sent.text_revision
            || self.inline_composer.state.text() != sent.text
        {
            self.inline_composer.sent = None;
            return;
        }
        let Some(reserved) = self.inline_composer.state.reserve_text_revision() else {
            return;
        };
        self.inline_composer.clear_inflight = true;
        let runtime = self.runtime.clone();
        cx.spawn(async move|this,cx| {
            let result=runtime.call("ShellInput","inlineClearIfUnchanged",json!([{"session_id":sent.session,"expected_revision":sent.native_revision,"text_revision":reserved}])).await;
            let _=this.update(cx,|this,cx|this.accept_inline_send_clear(sent,reserved,result,cx));
        }).detach();
    }
    fn accept_inline_send_clear(
        &mut self,
        sent: SentDraft,
        reserved: u64,
        result: Result<Value, String>,
        cx: &mut Context<Self>,
    ) {
        self.inline_composer.clear_inflight = false;
        self.inline_composer
            .state
            .observe_external_text(&self.composer.read(cx).text());
        if self.inline_composer.state.session_id() != Some(&sent.session) {
            self.update_inline_composer(cx);
            return;
        }
        let Ok(value) = result else {
            self.inline_error(cx);
            self.update_inline_composer(cx);
            return;
        };
        let Some(cleared) = value["cleared"].as_bool() else {
            self.inline_error(cx);
            return;
        };
        let Ok(snapshot) = Snapshot::parse(&value["snapshot"]) else {
            self.inline_error(cx);
            return;
        };
        let outcome = self.inline_composer.state.accept_reserved_clear(
            snapshot.clone(),
            reserved,
            sent.text_revision,
            cleared,
        );
        if outcome.is_accepted() {
            self.inline_composer.sent = None;
            self.inline_composer.wait_cursor =
                self.inline_composer.wait_cursor.max(snapshot.revision);
            let text = self.inline_composer.state.text().to_owned();
            if self.composer.read(cx).text() != text {
                self.composer
                    .update(cx, |input, cx| input.set_text(text, cx));
            }
            self.remember_inline_draft(cx);
            cx.notify();
        }
        self.update_inline_composer(cx);
    }
    fn inline_error(&mut self, cx: &mut Context<Self>) {
        self.notice = Some(self.locale.text(Text::InlineUnavailable).into());
        cx.notify();
    }
    pub(super) fn set_inline_native_form(&mut self, active: bool, cx: &mut Context<Self>) {
        self.native_form_active = active;
        if self.runtime.is_native() {
            self.defer_inline_update(cx);
        }
    }
}
fn sync_key(payload: &Value) -> Value {
    let mut key = payload.clone();
    if let Some(map) = key.as_object_mut() {
        map.remove("text");
    }
    key
}
pub(super) fn native_form_reply(reply: &Reply) -> bool {
    match reply {
        Reply::EntryName(_) | Reply::FileEditor(_) => true,
        Reply::GitAction(r) => matches!(
            r.step,
            super::git_operations::GitStep::Form | super::git_operations::GitStep::PromptCredential
        ),
        #[cfg(any(target_os = "ios", target_os = "android"))]
        Reply::Rename | Reply::WorkspaceName => true,
        _ => false,
    }
}

#[cfg(all(test, not(any(target_os = "ios", target_os = "android"))))]
#[path = "inline_composer_tests.rs"]
mod tests;

#[cfg(all(test, not(any(target_os = "ios", target_os = "android"))))]
#[path = "composer_drafts_tests.rs"]
mod draft_tests;
