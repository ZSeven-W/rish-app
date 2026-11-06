//! The view only dispatches shared-controller commands. Native checkpoints,
//! decisions, cancellation fences and recovery all live in rish-shell-core.
use super::*;

impl Shell {
    pub(super) fn agent_request_in_flight(&self) -> bool {
        self.agent_requests
            .iter()
            .any(|request| self.state.owns_agent_command(request))
    }
    pub(super) fn composer_placeholder(&self) -> &'static str {
        if self
            .state
            .agent_view()
            .and_then(|view| view.question)
            .is_some_and(|question| question.input_mode == "free_text")
        {
            agent_copy::copy(self.locale, "Type your answer…", "请输入你的回答…")
        } else if self.page == Page::Assistant {
            assistant_copy::copy(
                self.locale,
                "Tell me what you have in mind…",
                "想聊什么，或者有什么想交给我？",
            )
        } else {
            self.locale.text(Text::Composer)
        }
    }
    pub(super) fn refresh_agent_presentations(&mut self, cx: &mut Context<Self>) {
        if !self.runtime.is_native() {
            return;
        }
        if self.agent_presentation_pending.is_some() {
            self.agent_presentation_refresh = true;
            return;
        }
        self.agent_presentation_queue = self.state.read_agent_presentations_commands().into();
        self.agent_presentation_refresh = false;
        self.read_next_agent_presentation(cx);
    }

    fn read_next_agent_presentation(&mut self, cx: &mut Context<Self>) {
        let Some(command) = self.agent_presentation_queue.pop_front() else {
            return;
        };
        self.agent_presentation_pending = Some(command.clone());
        let runtime = self.runtime.clone();
        cx.spawn(async move |this, cx| {
            let result = runtime
                .call(
                    &command.module,
                    &command.method,
                    Value::Array(command.args.clone()),
                )
                .await;
            let _ = this.update(cx, |this, cx| {
                this.accept(Reply::AgentPresentations(command), result, cx)
            });
        })
        .detach();
    }

    pub(super) fn accept_agent_presentation_reply(
        &mut self,
        command: RuntimeCommand,
        result: Result<Value, String>,
        cx: &mut Context<Self>,
    ) {
        if self.agent_presentation_pending.as_ref() != Some(&command) {
            return;
        }
        self.agent_presentation_pending = None;
        if let Ok(value) = result {
            // Optional display cache failure must not interrupt an Agent or
            // replace its authoritative saved answer with unverified text.
            if self
                .state
                .accept_agent_presentations(&command, value)
                .is_ok()
            {
                self.sync_transcript(cx);
                cx.notify();
            }
        }
        if self.agent_presentation_refresh {
            self.refresh_agent_presentations(cx);
        } else {
            self.read_next_agent_presentation(cx);
        }
    }

    pub(super) fn start_agent_events(&mut self, cx: &mut Context<Self>) {
        let runtime = self.runtime.clone();
        self._agent_events = Some(cx.spawn(async move |this, cx| {
            loop {
                let events = runtime.next_events().await;
                if this
                    .update(cx, |this, cx| {
                        let mut changed = false;
                        for event in events {
                            if event.name == "agentRoundPreview" && !this.assistant_writer_lease {
                                changed |= this.state.accept_agent_preview(event.payload);
                            } else if event.name == "taskExperienceLifecycle" {
                                this.subscription_lifecycle(&event.payload, cx);
                                if event.payload["schema_version"] == 1
                                    && event.payload["foreground"].as_bool() == Some(true)
                                {
                                    this.resume_inline_after_foreground(cx);
                                }
                                this.load_assistant_platform(cx);
                            }
                        }
                        if changed {
                            this.sync_transcript(cx);
                            cx.notify();
                        }
                    })
                    .is_err()
                {
                    break;
                }
            }
        }));
    }

    pub(super) fn dispatch_continuation(
        &mut self,
        command: RuntimeCommand,
        cx: &mut Context<Self>,
    ) {
        if self.assistant_writer_lease {
            return;
        }
        if command.module == "SessionSnapshots" {
            self.run(Reply::Persist, command, cx);
        } else if self.state.owns_agent_command(&command) {
            if self.agent_requests.contains(&command) {
                return;
            }
            self.agent_requests.push(command.clone());
            let runtime = self.runtime.clone();
            cx.spawn(async move |this, cx| {
                let result = runtime
                    .call(
                        &command.module,
                        &command.method,
                        Value::Array(command.args.clone()),
                    )
                    .await;
                let _ = this.update(cx, |this, cx| {
                    this.accept(Reply::Agent(command), result, cx)
                });
            })
            .detach();
            cx.notify();
        } else if command.module == "LocalRuntime"
            && matches!(command.method.as_str(), "completeV2" | "completeV2Stream")
        {
            // Legacy text attempts may still finish after an app upgrade.
            self.run(Reply::Completion, command, cx);
        } else {
            self.notice = Some(
                agent_copy::copy(
                    self.locale,
                    "This task changed. Check its saved progress before continuing.",
                    "任务状态已改变，请先核对已保存的进度。",
                )
                .into(),
            );
            cx.notify();
        }
    }

    pub(super) fn accept_agent_reply(
        &mut self,
        command: RuntimeCommand,
        result: Result<Value, String>,
        cx: &mut Context<Self>,
    ) {
        self.agent_requests.retain(|pending| pending != &command);
        if self.assistant_writer_lease {
            return;
        }
        // A cancelled round can settle after its replacement or recovery. It
        // must not clear that request's progress, notices, or draft.
        if !self.state.owns_agent_command(&command) {
            cx.notify();
            return;
        }
        let next = match result {
            Ok(value) => self.state.accept_agent_result(&command, value, &now()),
            Err(error) => self.state.fail_agent_command(&command, &error, &now()),
        };
        self.apply_agent_step(next, cx);
    }

    pub(super) fn apply_agent_step(
        &mut self,
        next: Result<Option<RuntimeCommand>, String>,
        cx: &mut Context<Self>,
    ) {
        match next {
            Ok(Some(command)) => self.dispatch_continuation(command, cx),
            Ok(None) => {}
            Err(error) => self.notice = Some(error),
        }
        self.sync_transcript(cx);
        cx.notify();
    }

    pub(super) fn resume_agent_or_workspace(&mut self, cx: &mut Context<Self>) {
        if self.assistant_writer_lease {
            return;
        }
        self.try_assistant_handoff(cx);
        if self.assistant_writer_lease || self.assistant_blocks_session_recovery() {
            return;
        }
        if self.loading || self.agent_request_in_flight() {
            return;
        }
        // Startup queries reconcile durable evidence; this never retries a
        // possibly executed side effect merely because a UI promise was lost.
        let next = self.state.recover_agent(&now());
        match next {
            Ok(Some(command)) => self.dispatch_continuation(command, cx),
            Err(error) => self.notice = Some(error),
            Ok(None) => self.ensure_conversation_workspace(None, cx),
        }
    }

    pub(super) fn recover_visible_agent(&mut self, cx: &mut Context<Self>) {
        if self.assistant_writer_lease {
            if self.state.agent_view().is_some_and(|view| view.recoverable)
                && let Some(task_id) = self.assistant.snapshot.active_task_id.clone()
            {
                self.assistant_command(
                    crate::assistant_runtime::RunnerCommand::Recover { task_id },
                    cx,
                );
            }
        } else {
            self.resume_agent_or_workspace(cx);
        }
    }

    pub(super) fn stop_agent_or_completion(&mut self, cx: &mut Context<Self>) {
        if self.assistant_group_visible() {
            if self.assistant.snapshot.active_group_id.as_deref()
                == self.assistant.directory_ui.group_id.as_deref()
                && let Some(question) = self
                    .state
                    .agent_view()
                    .and_then(|v| v.question)
                    .filter(|q| q.input_mode == "free_text")
            {
                self.send_agent_answer(question.id, cx);
            } else if self.assistant_group_busy() {
                if let Some(group_id) = self.assistant.directory_ui.group_id.clone() {
                    self.assistant_command(
                        crate::assistant_runtime::RunnerCommand::StopGroup { group_id },
                        cx,
                    );
                }
            } else {
                self.send(cx);
            }
            return;
        }
        if let Some(question) = self
            .state
            .agent_view()
            .and_then(|view| view.question)
            .filter(|question| question.input_mode == "free_text")
        {
            self.send_agent_answer(question.id, cx);
        } else if self.state.has_agent_task() {
            self.stop_agent_task(cx);
        } else if let Some(command) = self.state.cancel_command() {
            self.run(Reply::Cancel, command, cx);
        } else if !self.state.is_busy() {
            self.send(cx);
        }
    }

    pub(super) fn stop_agent_task(&mut self, cx: &mut Context<Self>) {
        if self.assistant_writer_lease {
            self.assistant_command(crate::assistant_runtime::RunnerCommand::Stop, cx);
        } else {
            let next = self.state.cancel_agent(&now());
            self.apply_agent_step(next, cx);
        }
    }

    pub(super) fn decide_agent(
        &mut self,
        approval_id: &str,
        decision: &str,
        cx: &mut Context<Self>,
    ) {
        if self.assistant_writer_lease {
            self.assistant_command(
                crate::assistant_runtime::RunnerCommand::Approval {
                    approval_id: approval_id.into(),
                    decision: decision.into(),
                },
                cx,
            );
            return;
        }
        if self.loading || self.agent_request_in_flight() {
            return;
        }
        if self
            .state
            .agent_view()
            .and_then(|view| view.approval)
            .is_none_or(|approval| approval.approval_id != approval_id)
        {
            return;
        }
        let next = self
            .state
            .decide_agent_approval(decision, None, &now())
            .map(Some);
        self.apply_agent_step(next, cx);
    }

    pub(super) fn answer_agent(
        &mut self,
        call_id: &str,
        answer: Option<&str>,
        cx: &mut Context<Self>,
    ) {
        if self.assistant_writer_lease {
            self.assistant_command(
                crate::assistant_runtime::RunnerCommand::Answer {
                    call_id: call_id.into(),
                    answer: answer.map(str::to_owned),
                },
                cx,
            );
            return;
        }
        if self.loading || self.agent_request_in_flight() {
            return;
        }
        let next = self.state.answer_agent_question(call_id, answer, &now());
        self.apply_agent_step(next, cx);
    }

    pub(super) fn send_agent_answer(&mut self, call_id: String, cx: &mut Context<Self>) {
        if self.preflight_inline_action(
            inline_composer::InlineAction::AnswerQuestion(call_id.clone()),
            cx,
        ) {
            return;
        }
        if self.loading || self.agent_request_in_flight() {
            return;
        }
        let Some(question) = self.state.agent_view().and_then(|view| view.question) else {
            return;
        };
        if question.id != call_id || question.input_mode != "free_text" {
            return;
        }
        let answer = self.composer.read(cx).text();
        if self.assistant_writer_lease {
            if !self.mark_assistant_answer(&question) {
                return;
            }
            self.inline_will_send(&answer);
            self.assistant_command(
                crate::assistant_runtime::RunnerCommand::Answer {
                    call_id,
                    answer: Some(answer),
                },
                cx,
            );
            return;
        }
        let next = self
            .state
            .answer_agent_question(&call_id, Some(&answer), &now());
        if next.is_ok() {
            self.inline_will_send(&answer);
        }
        self.apply_agent_step(next, cx);
    }
}
