//! A room is a canonical transcript; participant session envelopes stay private.
use super::{assistant_copy::copy, transcript::DisplaySpeaker, *};
use crate::assistant_runtime::RunnerCommand;
use rish_shell_core::assistant_store::{AssistantGroup, AssistantRunStatus};

impl Shell {
    pub(super) fn assistant_current_group(&self) -> Option<&AssistantGroup> {
        let id = self.assistant.directory_ui.group_id.as_deref()?;
        self.assistant
            .directory()?
            .groups
            .iter()
            .find(|group| group.id == id)
    }
    pub(super) fn assistant_group_busy(&self) -> bool {
        self.assistant
            .directory_ui
            .submit
            .as_ref()
            .is_some_and(|s| s.sending)
            || self.assistant_current_group().is_some_and(|group| {
                self.assistant.snapshot.active_group_id.as_deref() == Some(&group.id)
                    || group.rounds.iter().any(|round| round.is_pending())
            })
    }
    pub(super) fn assistant_group_model(&self) -> String {
        let Some(group) = self.assistant_current_group() else {
            return String::new();
        };
        self.assistant
            .directory_ui
            .models
            .get(&group.id)
            .cloned()
            .or_else(|| group.rounds.last().map(|r| r.model_id.clone()))
            .or_else(|| self.state.configured_default_model().map(str::to_owned))
            .or_else(|| self.state.models().first().map(|m| m.id.clone()))
            .unwrap_or_default()
    }
    pub(super) fn assistant_group_workspace(&self) -> Option<Value> {
        let group = self.assistant_current_group()?;
        group
            .rounds
            .first()
            .map(|r| r.workspace_descriptor.clone())
            .or_else(|| {
                self.assistant
                    .directory_ui
                    .workspaces
                    .get(&group.id)
                    .cloned()
            })
            .or_else(|| self.state.default_workspace().cloned())
    }
    pub(super) fn assistant_send_group(&mut self, cx: &mut Context<Self>) {
        if self.assistant.snapshot.active_group_id.as_deref()
            == self.assistant.directory_ui.group_id.as_deref()
            && let Some(question) = self.state.agent_view().and_then(|v| v.question)
        {
            self.send_agent_answer(question.id, cx);
            return;
        }
        if self.preflight_inline_action(inline_composer::InlineAction::Send, cx) {
            return;
        }
        if !self.runtime.is_native()
            || self.assistant_writer_lease
            || self.loading
            || self.aux_busy
            || self.state.is_busy()
            || self.model_picker
            || self.custom_providers.request_pending()
            || self.provider_models.request_pending()
        {
            return;
        }
        let Some(group) = self.assistant_current_group() else {
            return;
        };
        if group.rounds.iter().any(|r| r.is_pending()) {
            return;
        }
        let group_id = group.id.clone();
        let text = self.inline_text_for_send(cx);
        if text.trim().is_empty() {
            self.cancel_inline_send_intent();
            return;
        }
        if text.len() > rish_shell_core::assistant_store::MAX_GROUP_INPUT_BYTES {
            self.assistant.error = Some(
                copy(
                    self.locale,
                    "This message is too long (8 KiB maximum).",
                    "这条消息太长，请缩短到 8 KiB 以内。",
                )
                .into(),
            );
            self.cancel_inline_send_intent();
            cx.notify();
            return;
        }
        let model_id = self.assistant_group_model();
        if !self.state.model_is_configured(&model_id) {
            self.cancel_inline_send_intent();
            self.choose_configured_model(cx);
            return;
        }
        let Some(workspace_descriptor) = self.assistant_group_workspace() else {
            self.ensure_conversation_workspace(None, cx);
            self.assistant.error = Some(
                copy(
                    self.locale,
                    "Preparing the default workspace. Send again when it is ready.",
                    "正在准备默认空间，就绪后可以发送。",
                )
                .into(),
            );
            cx.notify();
            return;
        };
        let turn_id = if let Some(submit) = &self.assistant.directory_ui.submit {
            if submit.sending {
                return;
            }
            if submit.group_id != group_id || submit.text != text {
                self.assistant.error = Some(
                    copy(
                        self.locale,
                        "Check the previous message before changing its draft.",
                        "请先核对上一条消息的保存结果，再修改草稿。",
                    )
                    .into(),
                );
                self.assistant_command(RunnerCommand::RefreshStore, cx);
                return;
            }
            submit.turn_id.clone()
        } else {
            uuid::Uuid::new_v4().to_string()
        };
        self.assistant.directory_ui.submit = Some(super::assistant_directory::GroupSubmission {
            group_id: group_id.clone(),
            turn_id: turn_id.clone(),
            text: text.clone(),
            sending: true,
        });
        self.inline_will_send(&text);
        self.assistant.error = None;
        self.assistant_command(
            RunnerCommand::SendGroup {
                group_id,
                turn_id,
                target_bot_id: self.assistant.directory_ui.target_bot_id.clone(),
                text,
                model_id,
                workspace_descriptor,
            },
            cx,
        );
    }
    pub(super) fn assistant_accept_group_submission(&mut self, cx: &mut Context<Self>) {
        let Some(submit) = &self.assistant.directory_ui.submit else {
            return;
        };
        let committed = self.assistant.directory().is_some_and(|d| {
            d.groups
                .iter()
                .find(|g| g.id == submit.group_id)
                .is_some_and(|g| {
                    g.rounds
                        .iter()
                        .any(|r| r.id == submit.turn_id && r.text == submit.text)
                })
        });
        if committed {
            self.clear_sent_inline_draft(cx);
            self.assistant.directory_ui.submit = None;
        }
    }
    pub(super) fn sync_assistant_group_transcript(&mut self, cx: &mut Context<Self>) {
        let Some(group) = self.assistant_current_group() else {
            return;
        };
        let directory = self.assistant.directory().unwrap();
        let mut messages = Vec::new();
        for round in &group.rounds {
            messages.push(DisplayMessage {
                id: round.user_message_id.clone(),
                role: "user".into(),
                text: round.text.clone(),
                reasoning: String::new(),
                speaker: None,
            });
            for reply in &round.replies {
                let Some(run) = &reply.run else {
                    continue;
                };
                let speaker = Some(DisplaySpeaker {
                    id: reply.bot_id.clone(),
                    name: run.snapshot.name.clone(),
                    avatar: directory
                        .bot_profile(&reply.bot_id)
                        .and_then(|p| p.avatar.clone()),
                    directory: self.assistant_storage_directory.clone(),
                });
                if run.status == AssistantRunStatus::Completed {
                    if let Some(text) = &reply.text {
                        messages.push(DisplayMessage {
                            id: run.ids.assistant_message_id.clone(),
                            role: "assistant".into(),
                            text: text.clone(),
                            reasoning: String::new(),
                            speaker,
                        });
                    }
                } else if self.assistant.snapshot.active_group_id.as_deref() == Some(&group.id)
                    && self.assistant.snapshot.active_task_id.as_deref() == Some(&reply.id)
                    && self.state.active_conversation_id() == Some(&reply.conversation_id)
                    && let Some(view) = self.state.agent_view()
                    && (!view.preview_text.is_empty() || !view.preview_reasoning.is_empty())
                {
                    messages.push(DisplayMessage {
                        id: format!("group-preview-{}", run.run_id),
                        role: "assistant".into(),
                        text: view.preview_text,
                        reasoning: view.preview_reasoning,
                        speaker,
                    });
                }
            }
        }
        self.transcript
            .update(cx, |t, cx| t.sync(messages, self.locale, cx));
    }
    pub(super) fn assistant_edit_group(&mut self, cx: &mut Context<Self>) {
        if self.assistant_group_busy() {
            return;
        }
        let Some(group) = self.assistant_current_group() else {
            return;
        };
        self.assistant.directory_ui.editor = Some(super::assistant_directory::DirectoryEditor {
            id: group.id.clone(),
            name: group.name.clone(),
            members: Some(group.active_bot_ids.clone()),
            editing: true,
            saving: false,
            request: None,
        });
        cx.notify();
    }
}
