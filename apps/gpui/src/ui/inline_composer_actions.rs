//! Native IME snapshots fence navigation and submission across Bot and room drafts.
use super::*;

impl Shell {
    pub(super) fn remember_closed_inline(&mut self, snapshot: Snapshot, cx: &mut Context<Self>) {
        let mut changed = None;
        for (key, draft) in &mut self.inline_composer.drafts {
            if draft.session == snapshot.session_id
                && draft.text_revision == snapshot.applied_text_revision
                && snapshot.revision >= draft.native_revision
            {
                draft.text = snapshot.text.clone();
                draft.native_revision = snapshot.revision;
                changed = Some((key.clone(), draft.text.clone()));
                break;
            }
        }
        if let Some((key, text)) = changed {
            let awaiting_clear = self.inline_composer.sent.as_ref().is_some_and(|sent| {
                sent.session == snapshot.session_id
                    && sent.text_revision == snapshot.applied_text_revision
                    && sent.text == text
            });
            if !awaiting_clear {
                self.record_composer_draft(&key, &text, cx);
            }
        }
    }

    pub(in crate::ui) fn retain_composer_drafts(
        &mut self,
        mut state: rish_shell_core::ShellState,
        cx: &mut Context<Self>,
    ) {
        // TextInput notifications may be queued behind the actor snapshot.
        // Capture the live entity before replacing the old authority; only an
        // established transport key, not the incoming actor, scopes that edit.
        let text = self.composer.read(cx).text();
        if let Some(key) = self
            .inline_composer
            .state
            .current_conversation_key()
            .map(str::to_owned)
        {
            if self.inline_composer.state.is_closed() && self.inline_composer.state.text() != text {
                // A prompt tile may replace TextInput after native closed but
                // before its observer runs. Closed state rejects replacements;
                // retire that old receipt slot so late close replies cannot
                // overwrite this explicit preset.
                self.inline_composer.drafts.remove(&key);
                self.record_composer_draft(&key, &text, cx);
            } else {
                self.inline_composer.state.observe_external_text(&text);
                self.remember_inline_draft(cx);
            }
        } else if !text.is_empty() {
            let key = self
                .state
                .active_conversation_id()
                .or_else(|| state.active_conversation_id())
                .unwrap_or("new-draft")
                .to_owned();
            self.record_composer_draft(&key, &text, cx);
        }
        state.retain_composer_drafts_from(&self.state);
        self.state = state;
        self.composer_drafts.restoring_snapshot = true;
    }

    pub(in crate::ui) fn acknowledge_actor_sent_draft(&mut self) {
        let Some(sent) = self.inline_composer.sent.as_ref() else {
            return;
        };
        let key = self.inline_composer.drafts.iter().find_map(|(key, draft)| {
            (draft.session == sent.session
                && draft.text_revision == sent.text_revision
                && draft.text == sent.text)
                .then_some(key.clone())
        });
        if let Some(key) = key {
            if self.state.composer_draft(&key) == sent.text {
                let _ = self.state.stage_composer_draft(&key, "");
            }
        }
    }

    pub(in crate::ui) fn preflight_inline_action(
        &mut self,
        action: InlineAction,
        cx: &mut Context<Self>,
    ) -> bool {
        if !self.runtime.is_native() {
            return false;
        }
        if self.inline_composer.permit.as_ref() == Some(&action) {
            self.inline_composer.permit = None;
            return false;
        }
        if action.is_navigation()
            && self
                .inline_composer
                .action
                .as_ref()
                .is_some_and(|pending| pending.action.is_navigation() && pending.action != action)
        {
            self.cancel_pending_inline_navigation();
        }
        if self.inline_composer.action.is_some() {
            return true;
        }
        self.align_inline_session(true, cx);
        // A never-attached editor has no native IME state to snapshot. Keep
        // the local draft above, then allow navigation even before first paint.
        // Unknown attachment or in-flight sync must still use the full fence.
        if self.inline_composer.native_session.is_none()
            && self.inline_composer.attached_session.is_none()
            && self.inline_composer.attachment_unknown.is_none()
            && self.inline_composer.sync.is_none()
            && self.inline_composer.closing_inflight.is_empty()
        {
            return false;
        }
        let Some(session) = self.inline_composer.state.session_id().map(str::to_owned) else {
            return false;
        };
        self.inline_composer.failed_key = None;
        self.inline_composer.action = Some(ActionRequest {
            id: uuid::Uuid::new_v4().to_string(),
            action,
            session,
            text_revision: self.inline_composer.state.text_revision(),
            conversation: self.inline_conversation_key(),
        });
        self.update_inline_composer(cx);
        true
    }
    pub(super) fn start_inline_action(&mut self, cx: &mut Context<Self>) {
        if self.inline_composer.clear_inflight
            || !self.inline_composer.closing_inflight.is_empty()
            || self.inline_composer.wait.as_ref().is_some_and(|session| {
                Some(session.as_str()) != self.inline_composer.state.session_id()
            })
            || self.inline_composer.action_inflight
            || self.inline_composer.sync.is_some()
        {
            return;
        }
        let Some(request) = self.inline_composer.action.clone() else {
            return;
        };
        if self.inline_composer.native_session.as_deref() != Some(&request.session) {
            return;
        }
        if self.inline_composer.state.text_revision() != request.text_revision
            || self.inline_conversation_key() != request.conversation
        {
            self.inline_composer.action = None;
            return;
        }
        self.inline_composer.action_inflight = true;
        let runtime = self.runtime.clone();
        cx.spawn(async move |this, cx| {
            let result = runtime
                .call(
                    "ShellInput",
                    "inlineSnapshot",
                    json!([{"session_id":request.session}]),
                )
                .await;
            let _ = this.update(cx, |this, cx| {
                this.accept_inline_action(request, result, cx)
            });
        })
        .detach();
    }
    pub(super) fn accept_inline_action(
        &mut self,
        request: ActionRequest,
        result: Result<Value, String>,
        cx: &mut Context<Self>,
    ) {
        if self.inline_composer.action.as_ref().map(|r| r.id.as_str()) != Some(&request.id) {
            return;
        }
        self.inline_composer.action = None;
        self.inline_composer.action_inflight = false;
        let Ok(value) = result else {
            if request.action.is_submission() {
                self.cancel_inline_send_intent();
            }
            self.inline_error(cx);
            return;
        };
        let accepted = self
            .apply_inline_snapshot(&value, cx)
            .is_ok_and(SnapshotAcceptance::is_accepted);
        if !accepted
            || self.inline_composer.state.is_closed()
            || self.inline_composer.state.session_id() != Some(&request.session)
            || self.inline_composer.state.text_revision() != request.text_revision
            || self.inline_conversation_key() != request.conversation
        {
            if request.action.is_submission() {
                self.cancel_inline_send_intent();
            }
            return;
        }
        if self.inline_composer.state.composing() {
            if request.action.is_submission() {
                self.inline_composer.queued_send = None;
            }
            self.notice = Some(self.locale.text(Text::InlineComposing).into());
            cx.notify();
            return;
        }
        if request.action == InlineAction::Send
            && self.inline_composer.queued_send.is_none()
            && !self.loading
            && !self.aux_busy
            && !self.model_picker
            && !self.state.is_busy()
        {
            self.inline_composer.queued_send = Some(self.inline_composer.state.text().to_owned());
        }
        self.inline_composer.permit = Some(request.action.clone());
        match request.action {
            InlineAction::Send => self.send(cx),
            InlineAction::AnswerQuestion(id) => self.send_agent_answer(id, cx),
            InlineAction::Create => self.create(cx),
            InlineAction::Assistant => self.navigate(super::super::Page::Assistant, cx),
            InlineAction::AssistantHub => self.assistant_open_hub(cx),
            InlineAction::AssistantBot(id) => self.assistant_open_bot(id, cx),
            InlineAction::AssistantGroup(id) => self.assistant_open_group(id, cx),
            InlineAction::Select(id) => self.select(id, cx),
            InlineAction::Bind(workspace) => self.bind_conversation_workspace(workspace, cx),
        }
    }
}
