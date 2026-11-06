//! Bot and room navigation is display state. Authority remains in the private store.
use super::*;
use crate::assistant_runtime::RunnerCommand;
use rish_shell_core::assistant_store::{AssistantProfile, AssistantSnapshot, DEFAULT_BOT_ID};

#[derive(Default)]
pub(super) struct AssistantDirectoryUi {
    pub hub_open: bool,
    pub add_menu_open: bool,
    pub add_menu_focus: Option<gpui::FocusHandle>,
    pub add_menu_previous_focus: Option<gpui::FocusHandle>,
    pub preview_bot_id: Option<String>,
    pub search: String,
    pub search_request: Option<String>,
    pub pending_destination: Option<(String, DirectoryDestination)>,
    pub group_id: Option<String>,
    pub target_bot_id: Option<String>,
    pub target_picker: bool,
    pub pending_bot_id: Option<String>,
    pub editor: Option<DirectoryEditor>,
    pub submit: Option<GroupSubmission>,
    pub models: std::collections::HashMap<String, String>,
    pub workspaces: std::collections::HashMap<String, Value>,
    pub workspace_picker: bool,
    pub nickname_request: Option<String>,
    pub nickname_draft: Option<String>,
    pub scroll: gpui::ScrollHandle,
}

#[derive(Clone, Copy)]
pub(super) enum DirectoryDestination {
    Chat,
    Soul,
    Memory,
    Tasks,
}

pub(super) struct DirectoryEditor {
    pub id: String,
    pub name: String,
    pub members: Option<Vec<String>>,
    pub editing: bool,
    pub saving: bool,
    pub request: Option<String>,
}

pub(super) struct GroupSubmission {
    pub group_id: String,
    pub turn_id: String,
    pub text: String,
    pub sending: bool,
}

impl assistant_forms::AssistantUi {
    pub(super) fn directory(&self) -> Option<&AssistantSnapshot> {
        self.snapshot
            .directory
            .as_ref()
            .or(self.snapshot.store.as_ref())
    }
    pub(super) fn selected_bot_id(&self) -> &str {
        if self.snapshot.selected_bot_id.is_empty() {
            DEFAULT_BOT_ID
        } else {
            &self.snapshot.selected_bot_id
        }
    }
}

impl Shell {
    pub(super) fn assistant_hub_visible(&self) -> bool {
        self.page == Page::Assistant && self.assistant.directory_ui.hub_open
    }
    pub(super) fn assistant_group_visible(&self) -> bool {
        self.page == Page::Assistant
            && !self.assistant.directory_ui.hub_open
            && self.assistant.directory_ui.group_id.is_some()
    }
    fn assistant_directory_navigation_allowed(&mut self, cx: &mut Context<Self>) -> bool {
        if self.assistant.form_busy()
            || self.assistant.profile_draft.is_some()
            || self.assistant.editor.is_some()
            || self.assistant.memory.editor.is_some()
            || self.assistant.directory_ui.editor.is_some()
            || self.native_form_active
        {
            self.assistant.error = Some(
                assistant_copy::copy(
                    self.locale,
                    "Save or cancel the current edit before switching.",
                    "请先保存或取消当前编辑，再切换。",
                )
                .into(),
            );
            cx.notify();
            return false;
        }
        if self.assistant_writer_lease || self.assistant.directory_ui.submit.is_some() {
            self.assistant.error = Some(
                assistant_copy::copy(
                    self.locale,
                    "Finish or stop the current reply before switching.",
                    "请先等待回复完成或停止，再切换。",
                )
                .into(),
            );
            cx.notify();
            return false;
        }
        !self.conversation_switch_blocked(true, cx)
    }
    pub(super) fn assistant_open_hub(&mut self, cx: &mut Context<Self>) {
        if self.preflight_inline_action(inline_composer::InlineAction::AssistantHub, cx)
            || self.defer_navigation(navigation_flow::NavigationAction::BotHub, cx)
            || !self.assistant_directory_navigation_allowed(cx)
        {
            return;
        }
        self.page = Page::Assistant;
        self.assistant.directory_ui.hub_open = true;
        self.assistant.directory_ui.pending_destination = None;
        self.assistant.directory_ui.add_menu_open = false;
        self.assistant.directory_ui.target_picker = false;
        self.assistant.tasks_open = false;
        self.assistant.profile_menu_open = false;
        self.initialize_assistant(cx);
        cx.notify();
    }
    pub(super) fn assistant_open_bot(&mut self, id: String, cx: &mut Context<Self>) {
        if self.preflight_inline_action(inline_composer::InlineAction::AssistantBot(id.clone()), cx)
            || self.defer_navigation(navigation_flow::NavigationAction::Bot(id.clone()), cx)
            || !self.assistant_directory_navigation_allowed(cx)
        {
            return;
        }
        if self
            .assistant
            .directory()
            .and_then(|d| d.bot_profile(&id))
            .is_none()
        {
            return;
        }
        self.assistant.directory_ui.hub_open = false;
        self.assistant.directory_ui.add_menu_open = false;
        self.assistant.directory_ui.group_id = None;
        self.assistant.directory_ui.target_bot_id = None;
        self.assistant.directory_ui.pending_bot_id = Some(id.clone());
        self.assistant.selected_task_id = None;
        self.assistant.tasks_open = false;
        self.assistant.profile_menu_open = false;
        self.assistant_chat_ensure_revision = None;
        self.page = Page::Assistant;
        if self.runtime.is_native() || self.assistant_runner.is_some() {
            self.assistant_command(RunnerCommand::SelectBot { bot_id: id }, cx);
        } else {
            if let Some(projected) = self.assistant.directory().and_then(|d| d.bot_snapshot(&id)) {
                self.assistant.snapshot.store = Some(projected);
                self.assistant.snapshot.selected_bot_id = id;
                self.assistant.directory_ui.pending_bot_id = None;
                self.bind_assistant_chat_snapshot();
            }
        }
        self.sync_transcript(cx);
        cx.notify();
    }
    pub(super) fn assistant_open_group(&mut self, id: String, cx: &mut Context<Self>) {
        if self.preflight_inline_action(
            inline_composer::InlineAction::AssistantGroup(id.clone()),
            cx,
        ) || self.defer_navigation(navigation_flow::NavigationAction::Group(id.clone()), cx)
            || !self.assistant_directory_navigation_allowed(cx)
        {
            return;
        }
        if !self
            .assistant
            .directory()
            .is_some_and(|d| d.groups.iter().any(|g| g.id == id))
        {
            return;
        }
        self.page = Page::Assistant;
        self.assistant.directory_ui.hub_open = false;
        self.assistant.directory_ui.add_menu_open = false;
        self.assistant.directory_ui.group_id = Some(id);
        self.assistant.directory_ui.pending_destination = None;
        self.assistant.directory_ui.target_bot_id = None;
        self.assistant.directory_ui.target_picker = false;
        self.assistant.directory_ui.pending_bot_id = None;
        self.assistant.tasks_open = false;
        self.assistant.profile_menu_open = false;
        self.update_placeholders(cx);
        self.sync_transcript(cx);
        cx.notify();
    }
    pub(super) fn assistant_begin_directory_editor(&mut self, group: bool, cx: &mut Context<Self>) {
        if self.assistant.directory_ui.editor.is_some() || self.assistant.form_busy() {
            return;
        }
        self.assistant.directory_ui.add_menu_open = false;
        self.assistant.directory_ui.editor = Some(DirectoryEditor {
            id: uuid::Uuid::new_v4().to_string(),
            name: assistant_copy::copy(
                self.locale,
                if group { "New group" } else { "New Bot" },
                if group { "新群聊" } else { "新 Bot" },
            )
            .into(),
            members: group.then(Vec::new),
            editing: false,
            saving: false,
            request: None,
        });
        self.assistant.error = None;
        cx.notify();
    }
    pub(super) fn assistant_directory_edit_name(&mut self, cx: &mut Context<Self>) {
        let Some(editor) = &mut self.assistant.directory_ui.editor else {
            return;
        };
        if editor.saving || editor.request.is_some() || self.native_form_active {
            return;
        }
        let token = uuid::Uuid::new_v4().to_string();
        editor.request = Some(token.clone());
        let command = assistant_copy::field_command(
            assistant_copy::copy(self.locale, "Name", "名称"),
            &editor.name,
            false,
            self.locale,
            cx,
        );
        let runtime = self.runtime.clone();
        self.set_inline_native_form(true, cx);
        cx.spawn(async move |this, cx| {
            let result = runtime
                .call(&command.module, &command.method, Value::Array(command.args))
                .await;
            let _ = this.update(cx, |this, cx| {
                this.set_inline_native_form(false, cx);
                let Some(editor) = &mut this.assistant.directory_ui.editor else {
                    return;
                };
                if editor.request.as_ref() != Some(&token) {
                    return;
                }
                editor.request = None;
                match result {
                    Ok(Value::String(name)) => editor.name = name,
                    Ok(Value::Null) => {}
                    _ => {
                        this.assistant.error = Some(
                            assistant_copy::copy(
                                this.locale,
                                "Could not edit the name. Your draft is kept.",
                                "名称编辑失败，草稿已保留。",
                            )
                            .into(),
                        )
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }
    pub(super) fn assistant_save_directory_editor(&mut self, cx: &mut Context<Self>) {
        let Some(revision) = self.assistant.directory().map(|d| d.revision) else {
            return;
        };
        let Some(editor) = &mut self.assistant.directory_ui.editor else {
            return;
        };
        if editor.saving || editor.request.is_some() {
            return;
        }
        let name = editor.name.trim().to_owned();
        if name.is_empty() || name.len() > 240 {
            self.assistant.error = Some(
                assistant_copy::copy(
                    self.locale,
                    "Enter a name of up to 240 bytes.",
                    "请输入名称，长度不超过 240 字节。",
                )
                .into(),
            );
            cx.notify();
            return;
        }
        let command = if let Some(members) = &editor.members {
            if !(2..=8).contains(&members.len()) {
                self.assistant.error = Some(
                    assistant_copy::copy(
                        self.locale,
                        "Choose 2–8 assistants for this group.",
                        "请选择 2–8 个助手加入群聊。",
                    )
                    .into(),
                );
                cx.notify();
                return;
            }
            if editor.editing {
                RunnerCommand::UpdateGroup {
                    expected_revision: revision,
                    group_id: editor.id.clone(),
                    name,
                    bot_ids: members.clone(),
                }
            } else {
                RunnerCommand::CreateGroup {
                    expected_revision: revision,
                    group_id: editor.id.clone(),
                    name,
                    bot_ids: members.clone(),
                }
            }
        } else {
            RunnerCommand::CreateBot {
                expected_revision: revision,
                bot_id: editor.id.clone(),
                profile: AssistantProfile {
                    name,
                    ..Default::default()
                },
            }
        };
        editor.saving = true;
        self.assistant.error = None;
        self.assistant_command(command, cx);
    }
    pub(super) fn assistant_directory_snapshot_changed(&mut self, cx: &mut Context<Self>) {
        if self
            .assistant
            .directory_ui
            .nickname_draft
            .as_deref()
            .is_some_and(|draft| {
                self.assistant
                    .directory()
                    .and_then(|d| d.user_nickname.as_deref())
                    == Some(draft)
            })
        {
            self.assistant.directory_ui.nickname_draft = None;
        }
        if self.assistant.directory_ui.pending_bot_id.as_deref()
            == Some(self.assistant.selected_bot_id())
        {
            self.assistant.directory_ui.pending_bot_id = None;
        }
        let saved = self
            .assistant
            .directory_ui
            .editor
            .as_ref()
            .filter(|e| e.saving)
            .and_then(|e| {
                let directory = self.assistant.directory()?;
                let exists = if e.members.is_some() {
                    directory.groups.iter().any(|g| {
                        g.id == e.id
                            && g.name == e.name.trim()
                            && e.members.as_ref() == Some(&g.active_bot_ids)
                    })
                } else {
                    directory
                        .bot_profile(&e.id)
                        .is_some_and(|p| p.name == e.name.trim())
                };
                exists.then(|| (e.id.clone(), e.members.is_some()))
            });
        if let Some((id, group)) = saved {
            self.assistant.directory_ui.editor = None;
            self.assistant.error = None;
            if group {
                self.assistant_open_group(id, cx);
            } else {
                self.assistant_open_bot(id, cx);
            }
        }
        self.assistant_directory_apply_destination(cx);
        self.assistant_accept_group_submission(cx);
    }
}
