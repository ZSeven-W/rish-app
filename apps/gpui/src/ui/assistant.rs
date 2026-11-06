//! UI client of the process-owned local assistant. A snapshot is never a
//! second session writer; only Returned transfers the writer back to this view.
use super::*;
use crate::assistant_runtime::{RunnerCommand, RunnerEvent, RunnerHandle};
use futures::StreamExt;
use gpui::AnyElement;
use serde_json::json;
use std::{path::PathBuf, time::Duration};

#[cfg(all(test, not(any(target_os = "ios", target_os = "android"))))]
#[path = "assistant_writer_tests.rs"]
mod tests;

pub(super) struct AnswerSubmission {
    task_id: String,
    run_id: String,
    question_id: String,
    tool_call_id: String,
    round: u64,
    accepted: bool,
}

impl AnswerSubmission {
    fn is_committed(&self, snapshot: &crate::assistant_runtime::RunnerSnapshot) -> bool {
        self.accepted
            && snapshot.active_task_id.as_deref() == Some(&self.task_id)
            && runner_active_run(snapshot).is_some_and(|run| run.run_id == self.run_id)
            && snapshot
                .state
                .as_ref()
                .and_then(|state| state.agent_view())
                .is_some_and(|view| {
                    // Tool status comes from the committed session, including its
                    // retained events after moving to the next round. Intake and
                    // a redacted execution intent cannot satisfy this receipt.
                    view.tools.iter().any(|tool| {
                        tool.round_index == self.round
                            && tool.call_id == self.tool_call_id
                            && tool.name == "ask_user"
                            && tool.status == "ok"
                    })
                })
    }
}

impl Shell {
    pub(super) fn initialize_assistant(&mut self, cx: &mut Context<Self>) {
        if !self.runtime.is_native() || self.assistant_storage_loading {
            return;
        }
        let handle = self
            .assistant_runner
            .get_or_insert_with(RunnerHandle::process)
            .clone();
        if self._assistant_events.is_none() {
            let initial = handle.snapshot();
            if initial.owns_writer {
                self.assistant_writer_lease = true;
                if let Some(state) = &initial.state {
                    self.retain_composer_drafts(state.clone(), cx);
                    self.assistant_handoff_state = Some(state.clone());
                }
            }
            self.assistant.apply_snapshot(initial);
            self.bind_assistant_chat_snapshot();
            let mut events = handle.subscribe();
            self._assistant_events = Some(cx.spawn(async move |this, cx| {
                while let Some(event) = events.next().await {
                    if this
                        .update(cx, |this, cx| this.accept_assistant_event(event, cx))
                        .is_err()
                    {
                        break;
                    }
                }
            }));
            self._assistant_tick = Some(cx.spawn(async move |this, cx| {
                loop {
                    cx.background_executor()
                        .timer(Duration::from_secs(30))
                        .await;
                    if this
                        .update(cx, |this, cx| {
                            this.assistant_command(RunnerCommand::PollDue, cx);
                            this.try_assistant_handoff(cx);
                        })
                        .is_err()
                    {
                        break;
                    }
                }
            }));
        }
        if self.assistant.snapshot.store.is_some() && self.assistant_storage_directory.is_some() {
            return;
        }
        self.assistant_storage_loading = true;
        let runtime = self.runtime.clone();
        cx.spawn(async move |this, cx| {
            let result = runtime.call("ShellAssistant", "storage", json!([])).await;
            let _ = this.update(cx, |this, cx| {
                this.assistant_storage_loading = false;
                let path = result.and_then(|v| {
                    if v["schema_version"] != 1
                        || !matches!(v["platform"].as_str(), Some("ios" | "android"))
                    {
                        return Err("Invalid local assistant storage response".into());
                    }
                    let path = PathBuf::from(
                        v["directory"]
                            .as_str()
                            .ok_or("Missing assistant directory")?,
                    );
                    if !path.is_absolute() {
                        return Err("Assistant storage is not an absolute path".into());
                    }
                    Ok(path)
                });
                match path {
                    Ok(directory) => {
                        this.assistant_storage_directory = Some(directory.clone());
                        this.assistant_command(RunnerCommand::Initialize { directory }, cx)
                    }
                    Err(error) => this.assistant.accept_error(&error),
                }
                this.load_assistant_platform(cx);
                cx.notify();
            });
        })
        .detach();
    }

    pub(super) fn assistant_command(&mut self, command: RunnerCommand, cx: &mut Context<Self>) {
        let command = match command {
            command @ (RunnerCommand::EnsureConversation { .. }
            | RunnerCommand::CreateMemory { .. }
            | RunnerCommand::RememberMemory { .. }
            | RunnerCommand::ForgetMemory { .. }
            | RunnerCommand::SetProfile { .. }
            | RunnerCommand::CreateTask { .. }
            | RunnerCommand::UpdateTask { .. }
            | RunnerCommand::RemoveTask { .. }
            | RunnerCommand::SetEnabled { .. }) => RunnerCommand::ForBot {
                bot_id: self.assistant.selected_bot_id().to_owned(),
                command: Box::new(command),
            },
            command => command,
        };
        if matches!(command, RunnerCommand::RefreshStore) {
            self.assistant_chat_ensure_revision = None;
        }
        if !self.runtime.is_native() && self.assistant_runner.is_none() {
            return;
        }
        if matches!(
            command,
            RunnerCommand::RunNow { .. } | RunnerCommand::Recover { .. }
        ) {
            self.page = Page::Assistant;
        }
        if let Some(handle) = &self.assistant_runner {
            if let Err(error) = handle.send(command) {
                self.assistant.accept_error(&error);
            }
        } else {
            self.initialize_assistant(cx);
        }
        cx.notify();
    }

    fn accept_assistant_event(&mut self, event: RunnerEvent, cx: &mut Context<Self>) {
        self.schedule_navigation_resume(cx);
        match event {
            RunnerEvent::Snapshot(snapshot) => {
                if snapshot.owns_writer {
                    self.assistant_writer_lease = true;
                    if let Some(state) = &snapshot.state {
                        let answer_committed = self
                            .assistant_answer
                            .as_ref()
                            .is_some_and(|answer| answer.is_committed(&snapshot));
                        if answer_committed {
                            self.acknowledge_actor_sent_draft();
                        }
                        self.retain_composer_drafts(state.clone(), cx);
                        self.assistant_handoff_state = Some(state.clone());
                        if answer_committed {
                            self.clear_sent_inline_draft(cx);
                            self.assistant_answer = None;
                        }
                    }
                }
                // A false snapshot cannot release a just-granted writer. It
                // can have been queued before the actor accepted the handoff.
                self.assistant.apply_snapshot(snapshot);
                self.assistant_directory_snapshot_changed(cx);
                self.bind_assistant_chat_snapshot();
                self.enter_assistant_conversation(cx);
                self.try_assistant_handoff(cx);
                if !self.assistant_writer_lease && self.state.is_loaded() && !self.loading {
                    self.resume_agent_or_workspace(cx);
                }
            }
            RunnerEvent::AnswerAccepted {
                task_id,
                run_id,
                call_id,
            } => {
                if let Some(answer) = &mut self.assistant_answer
                    && answer.task_id == task_id
                    && answer.run_id == run_id
                    && answer.question_id == call_id
                {
                    answer.accepted = true;
                }
            }
            RunnerEvent::HandoffNeeded { task_id } => {
                self.assistant_handoff = Some(task_id);
                self.try_assistant_handoff(cx);
            }
            RunnerEvent::Returned { state } => {
                self.retain_composer_drafts(state, cx);
                self.bind_assistant_chat_snapshot();
                self.assistant_writer_lease = false;
                self.assistant_handoff_state = None;
                // Returning a cancelled/failed task does not prove an answer
                // was saved. Preserve its editor draft for the user.
                self.assistant_answer = None;
                self.assistant_handoff = None;
                self.loading = false;
                self.conversation_workspace.descriptor = None;
                self.update_placeholders(cx);
                self.refresh_agent_presentations(cx);
                self.resolve_active_workspace(cx);
                self.enter_assistant_conversation(cx);
            }
            RunnerEvent::HandoffRejected { task_id, message } => {
                if self.assistant_handoff.as_deref() == Some(&task_id) {
                    self.assistant_handoff = None;
                }
                // Rejection means the process still owns another writer.
                self.restore_assistant_read_model(cx);
                self.assistant.accept_error(&message);
            }
            RunnerEvent::OpenConversation { conversation_id } => {
                self.assistant_open_conversation(conversation_id, cx);
            }
            RunnerEvent::Error(error) => {
                self.assistant.accept_error(&error);
                if let Some(editor) = &mut self.assistant.directory_ui.editor {
                    editor.saving = false;
                }
                if let Some(submit) = &mut self.assistant.directory_ui.submit {
                    submit.sending = false;
                }
                if (error.starts_with("Assistant state changed")
                    || error.contains("task identity already exists with different settings"))
                    && let Some(handle) = &self.assistant_runner
                {
                    let _ = handle.send(RunnerCommand::RefreshStore);
                }
            }
        }
        self.align_inline_session(true, cx);
        self.schedule_composer_draft_save(cx);
        self.sync_transcript(cx);
        cx.notify();
    }

    pub(super) fn try_assistant_handoff(&mut self, cx: &mut Context<Self>) {
        if self.assistant_writer_lease
            || self.navigation_flow.pending.is_some()
            || self.navigation_flow.creating
            || self.assistant.directory_ui.pending_bot_id.is_some()
            || self.loading
            || self.aux_busy
            || self.custom_providers.request_pending()
            || self.provider_models.request_pending()
            || self.send_after_create
            || self.conversation_workspace.intent.is_some()
            || !self.state.is_loaded()
            || self.state.is_busy()
            || self.state.has_unsaved_composer_drafts()
            || self.composer_drafts.rejected_text
            || self.native_form_active
            || self.has_file_draft()
            || !self.inline_allows_assistant_handoff()
            || !self.assistant.snapshot.foreground
        {
            return;
        }
        let Some(task_id) = self.assistant_handoff.clone() else {
            return;
        };
        let Some(handle) = &self.assistant_runner else {
            return;
        };
        // Freeze the UI writer synchronously, before enqueueing the actor's
        // command. All subsequent session callbacks are display-only here.
        self.assistant_writer_lease = true;
        self.assistant_handoff_state = Some(self.state.clone());
        if let Err(error) = handle.send(RunnerCommand::Grant {
            task_id,
            state: self.state.clone(),
            foreground: true,
        }) {
            self.assistant_writer_lease = false;
            self.assistant_handoff_state = None;
            self.assistant.accept_error(&error);
        }
        cx.notify();
    }

    pub(super) fn assistant_blocks_session_recovery(&self) -> bool {
        if !self.runtime.is_native() && self.assistant_runner.is_none() {
            return false;
        }
        if self.assistant_storage_loading {
            return true;
        }
        let Some(store) = self.assistant.directory() else {
            // Do not run past an unexamined durable stop intent in BotStore.
            return self.assistant_runner.is_some();
        };
        let session = self.state.raw_session();
        if store
            .groups
            .iter()
            .any(|g| g.rounds.iter().any(|r| r.is_pending()))
        {
            return true;
        }
        store
            .all_tasks()
            .iter()
            .filter(|task| task.is_running())
            .any(|task| {
                session["conversations"]
                    .as_array()
                    .is_some_and(|conversations| {
                        conversations.iter().any(|c| {
                            c["id"] == task.conversation_id
                                && c["attempts"].as_array().is_some_and(|attempts| {
                                    attempts.iter().any(|a| {
                                        task.last_run.as_ref().is_some_and(|run| {
                                            a["attempt_id"] == run.ids.attempt_id
                                        })
                                    })
                                })
                        })
                    })
            })
    }

    pub(super) fn restore_assistant_read_model(&mut self, cx: &mut Context<Self>) {
        if let Some(state) = self
            .assistant_runner
            .as_ref()
            .and_then(|runner| runner.snapshot().state)
            .or_else(|| self.assistant_handoff_state.clone())
        {
            self.retain_composer_drafts(state, cx);
            self.sync_transcript(cx);
        }
        cx.notify();
    }

    pub(super) fn mark_assistant_answer(
        &mut self,
        question: &rish_shell_core::AgentQuestionView,
    ) -> bool {
        let snapshot = &self.assistant.snapshot;
        let Some(task_id) = &snapshot.active_task_id else {
            return false;
        };
        let Some(run) = runner_active_run(snapshot) else {
            return false;
        };
        let Some(view) = snapshot.state.as_ref().and_then(|state| state.agent_view()) else {
            return false;
        };
        if view.question.as_ref().map(|q| &q.id) != Some(&question.id) {
            return false;
        }
        self.assistant_answer = Some(AnswerSubmission {
            task_id: task_id.clone(),
            run_id: run.run_id.clone(),
            question_id: question.id.clone(),
            tool_call_id: question.call_id.clone(),
            round: view.round,
            accepted: false,
        });
        true
    }

    pub(super) fn assistant_open_conversation(&mut self, id: String, cx: &mut Context<Self>) {
        let group = self
            .assistant
            .directory()
            .and_then(|d| {
                d.groups
                    .iter()
                    .find(|g| g.id == id || g.members.iter().any(|m| m.conversation_id == id))
            })
            .map(|g| g.id.clone());
        if let Some(group_id) = group {
            if self.assistant.snapshot.active_group_id.as_deref() == Some(&group_id) {
                self.page = Page::Assistant;
                self.assistant.directory_ui.hub_open = false;
                self.assistant.directory_ui.group_id = Some(group_id);
                self.sync_transcript(cx);
                cx.notify();
            } else {
                self.assistant_open_group(group_id, cx);
            }
            return;
        }
        if self.assistant_writer_lease {
            if self.state.active_conversation_id() == Some(&id) {
                self.page = Page::Chat;
            } else {
                self.assistant.accept_error(assistant_copy::copy(
                    self.locale,
                    "Finish or stop the current task before switching conversations.",
                    "请先完成或停止当前任务，再切换对话。",
                ));
            }
            cx.notify();
        } else {
            self.select(id, cx);
        }
    }

    pub(super) fn assistant_active_panel(
        &self,
        height: f32,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let view = self.assistant.snapshot.state.as_ref()?.agent_view()?;
        let question = view
            .question
            .as_ref()
            .filter(|q| q.input_mode == "free_text")
            .map(|q| q.id.clone());
        let mut panel = div()
            .flex()
            .flex_col()
            .child(self.agent_panel(view, height, cx));
        if let Some(id) = question {
            let p = Palette::get(cx);
            panel = panel.child(
                div()
                    .id("assistant-answer-question")
                    .role(gpui::Role::Button)
                    .min_h(px(HIT_TARGET.max(44.)))
                    .mx_5()
                    .mb_2()
                    .px_3()
                    .rounded(px(10.))
                    .bg(p.accent)
                    .text_color(p.on_accent)
                    .flex()
                    .items_center()
                    .justify_center()
                    .cursor_pointer()
                    .child(assistant_copy::copy(
                        self.locale,
                        "Answer question",
                        "填写回答",
                    ))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.assistant_answer_form(id.clone(), cx)
                    })),
            );
        }
        Some(panel.into_any_element())
    }

    fn assistant_answer_form(&mut self, question_id: String, cx: &mut Context<Self>) {
        if self.native_form_active || !self.assistant_writer_lease {
            return;
        }
        let title = assistant_copy::copy(self.locale, "Answer question", "填写回答");
        let mut command = assistant_copy::field_command(title, "", true, self.locale, cx);
        command.args[0]["max_bytes"] = json!(4000);
        let runtime = self.runtime.clone();
        self.set_inline_native_form(true, cx);
        cx.spawn(async move |this, cx| {
            let response = runtime
                .call(&command.module, &command.method, Value::Array(command.args))
                .await;
            let _ = this.update(cx, |this, cx| {
                this.set_inline_native_form(false, cx);
                let current = this
                    .assistant
                    .snapshot
                    .state
                    .as_ref()
                    .and_then(|s| s.agent_view())
                    .and_then(|v| v.question);
                if current.as_ref().map(|q| q.id.as_str()) != Some(question_id.as_str()) {
                    return;
                }
                match response {
                    Ok(Value::String(answer)) => this.assistant_command(
                        RunnerCommand::Answer {
                            call_id: question_id,
                            answer: Some(answer),
                        },
                        cx,
                    ),
                    Ok(Value::Null) => {}
                    Ok(_) => this
                        .assistant
                        .accept_error("Invalid answer editor response"),
                    Err(error) => this.assistant.accept_error(&error),
                }
                cx.notify();
            });
        })
        .detach();
    }
}

fn runner_active_run(
    snapshot: &crate::assistant_runtime::RunnerSnapshot,
) -> Option<&rish_shell_core::assistant_store::AssistantRun> {
    let id = snapshot.active_task_id.as_deref()?;
    let directory = snapshot.directory.as_ref().or(snapshot.store.as_ref())?;
    directory
        .all_tasks()
        .into_iter()
        .find(|t| t.id == id)
        .and_then(|t| t.last_run.as_ref())
        .or_else(|| {
            directory
                .groups
                .iter()
                .flat_map(|g| &g.rounds)
                .flat_map(|r| &r.replies)
                .find(|r| r.id == id)
                .and_then(|r| r.run.as_ref())
        })
}
