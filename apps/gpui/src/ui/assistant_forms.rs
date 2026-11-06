use super::{Shell, assistant_copy::copy};
use crate::assistant_runtime::{RunnerCommand, RunnerSnapshot};
use gpui::Context;
use rish_shell_core::{RuntimeCommand, assistant_store::*, workspace_binding};
use serde_json::Value;

#[derive(Default)]
pub(super) struct AssistantUi {
    pub snapshot: RunnerSnapshot,
    pub directory_ui: super::assistant_directory::AssistantDirectoryUi,
    pub selected_task_id: Option<String>,
    pub editor: Option<TaskEditor>,
    pub list_scroll: gpui::ScrollHandle,
    pub detail_scroll: gpui::ScrollHandle,
    pub form_request: Option<String>,
    pub error: Option<String>,
    pub profile_draft: Option<ProfileDraft>,
    pub deletion: Option<TaskDeletion>,
    pub settings_open: bool,
    pub tasks_open: bool,
    pub panel: super::assistant_memory_state::AssistantPanel,
    pub memory: super::assistant_memory_state::MemoryUi,
    pub task_menu_open: bool,
    pub profile_menu_open: bool,
    pub profile_menu_focus: Option<gpui::FocusHandle>,
    pub profile_previous_focus: Option<gpui::FocusHandle>,
}

pub(super) struct TaskDeletion {
    pub task_id: String,
    pub title: String,
    pub expected_revision: u64,
    pub saving: bool,
}

pub(super) struct ProfileDraft {
    pub baseline: AssistantProfile,
    pub profile: AssistantProfile,
    pub expected_revision: u64,
    pub saving: bool,
}

impl ProfileDraft {
    /// Preserve every field the user did not edit, including the execution
    /// runtime. Profile JSON is never treated as an arbitrary merge patch.
    pub(super) fn merged_profile(&self, latest: &AssistantProfile) -> AssistantProfile {
        let mut merged = latest.clone();
        if self.profile.name != self.baseline.name {
            merged.name = self.profile.name.clone();
        }
        if self.profile.notes != self.baseline.notes {
            merged.notes = self.profile.notes.clone();
        }
        if self.profile.soul != self.baseline.soul {
            merged.soul = self.profile.soul.clone();
        }
        if self.profile.avatar != self.baseline.avatar {
            merged.avatar = self.profile.avatar.clone();
        }
        if self.profile.runtime != self.baseline.runtime {
            merged.runtime = self.profile.runtime.clone();
        }
        merged
    }
    pub(super) fn rebase(&mut self, latest: &AssistantProfile) {
        self.profile = self.merged_profile(latest);
        self.baseline = latest.clone();
    }
}

pub(super) fn prepare_profile_save(
    draft: &mut ProfileDraft,
    store: &AssistantSnapshot,
) -> RunnerCommand {
    draft.rebase(&store.profile);
    draft.expected_revision = store.revision;
    draft.saving = true;
    RunnerCommand::SetProfile {
        expected_revision: store.revision,
        profile: draft.profile.clone(),
    }
}

#[derive(Clone)]
pub(super) struct TaskEditor {
    pub id: String,
    pub task_id: Option<String>,
    pub expected_revision: u64,
    pub config: AssistantTaskConfig,
    pub picker: Option<Picker>,
    pub saving: bool,
    pub base_config: Option<AssistantTaskConfig>,
    pub conflicted: bool,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum Picker {
    Workspace,
    Model,
    Schedule,
}

#[derive(Clone, Copy)]
pub(super) enum Field {
    ProfileName,
    ProfileNotes,
    ProfileSoul,
    Title,
    Instructions,
    Interval,
}

impl AssistantUi {
    pub fn apply_snapshot(&mut self, snapshot: RunnerSnapshot) {
        if let Some(store) = &snapshot.store {
            let edited = self.memory.editor.is_some();
            let deleted = self.memory.deletion.is_some();
            self.memory.apply_snapshot(store);
            if (edited && self.memory.editor.is_none())
                || (deleted && self.memory.deletion.is_none())
            {
                self.error = None;
            }
        }
        if let (Some(deletion), Some(store)) = (&self.deletion, &snapshot.store)
            && store.revision > deletion.expected_revision
            && !store.tasks.iter().any(|task| task.id == deletion.task_id)
        {
            if self.selected_task_id.as_ref() == Some(&deletion.task_id) {
                self.selected_task_id = None;
            }
            self.deletion = None;
            self.error = None;
        }
        if let (Some(editor), Some(store)) = (&mut self.editor, &snapshot.store)
            && editor.task_id.is_none()
            && store
                .tasks
                .iter()
                .any(|task| task.id == editor.id && task.config() != editor.config)
        {
            editor.conflicted = true;
        }
        if let (Some(draft), Some(store)) = (&self.profile_draft, &snapshot.store)
            && draft.saving
            && store.revision > draft.expected_revision
        {
            if draft.profile == store.profile {
                self.profile_draft = None;
                self.error = None;
            } else if let Some(draft) = &mut self.profile_draft {
                draft.saving = false;
            }
        }
        if let (Some(draft), Some(store)) = (&mut self.profile_draft, &snapshot.store)
            && store.revision >= draft.expected_revision
        {
            draft.rebase(&store.profile);
        }
        if let (Some(editor), Some(store)) = (&self.editor, &snapshot.store)
            && editor.saving
            && (store.revision > editor.expected_revision
                || (editor.task_id.is_none() && store.revision == editor.expected_revision))
        {
            let id = editor.task_id.as_ref().unwrap_or(&editor.id);
            let saved = store.tasks.iter().find(|task| &task.id == id);
            if let Some(task) = saved.filter(|task| task.config() == editor.config) {
                self.selected_task_id = Some(task.id.clone());
                self.editor = None;
                self.error = None;
                self.detail_scroll = Default::default();
            } else if (saved.is_some() || store.revision > editor.expected_revision)
                && let Some(editor) = &mut self.editor
            {
                // Keep the user's draft when another write wins the CAS.
                editor.saving = false;
                editor.conflicted = saved.is_some();
            }
        }
        self.snapshot = snapshot;
        if self.workspace_locked()
            && let Some(editor) = &mut self.editor
            && editor.picker == Some(Picker::Workspace)
        {
            editor.picker = None;
        }
    }

    pub fn accept_error(&mut self, message: &str) {
        if let Some(editor) = &mut self.directory_ui.editor {
            editor.saving = false;
        }
        self.memory.accept_error();
        self.error = Some(message.to_owned());
        if let Some(editor) = &mut self.editor {
            editor.saving = false;
        }
        if let Some(draft) = &mut self.profile_draft {
            draft.saving = false;
        }
        if let Some(deletion) = &mut self.deletion {
            deletion.saving = false;
        }
    }

    pub fn selected_task(&self) -> Option<&AssistantTask> {
        let store = self.snapshot.store.as_ref()?;
        store
            .tasks
            .iter()
            .find(|task| self.selected_task_id.as_deref() == Some(&task.id))
    }

    pub fn form_busy(&self) -> bool {
        if self.directory_ui.pending_bot_id.is_some() {
            return true;
        }
        self.form_request.is_some()
            || self.memory.busy()
            || self.editor.as_ref().is_some_and(|e| e.saving)
            || self.deletion.is_some()
            || self
                .profile_draft
                .as_ref()
                .is_some_and(|draft| draft.saving)
    }

    pub fn workspace_locked(&self) -> bool {
        let Some(editor) = &self.editor else {
            return false;
        };
        let id = editor.task_id.as_ref().unwrap_or(&editor.id);
        self.snapshot.store.as_ref().is_some_and(|store| {
            store
                .tasks
                .iter()
                .any(|task| &task.id == id && task.last_run.is_some())
        })
    }
}

impl Shell {
    pub(super) fn assistant_new_task_config(&self) -> Option<AssistantTaskConfig> {
        let catalog = self.state.models();
        let model = catalog
            .iter()
            .find(|model| model.id == self.settings_default_model_id())
            .or_else(|| catalog.first())?;
        let descriptor = self
            .conversation_workspace
            .descriptor
            .clone()
            .or_else(|| self.state.default_workspace().cloned())
            .unwrap_or(Value::Null);
        let binding = workspace_binding(&descriptor).unwrap_or(Value::Null);
        Some(AssistantTaskConfig::manual(
            "", "", &model.id, binding, descriptor,
        ))
    }

    pub(super) fn assistant_begin_task(&mut self, task_id: Option<String>, cx: &mut Context<Self>) {
        if !self.runtime.is_native()
            || self.assistant.form_busy()
            || self.assistant.deletion.is_some()
        {
            return;
        }
        let Some(store) = self.assistant.snapshot.store.as_ref() else {
            return;
        };
        let config = if let Some(id) = &task_id {
            let Some(task) = store.tasks.iter().find(|task| &task.id == id) else {
                return;
            };
            if task.is_running() {
                return;
            }
            task.config()
        } else {
            let Some(config) = self.assistant_new_task_config() else {
                self.assistant.error = None;
                self.choose_configured_model(cx);
                return;
            };
            config
        };
        self.assistant.editor = Some(TaskEditor {
            id: uuid::Uuid::new_v4().to_string(),
            base_config: task_id.as_ref().map(|_| config.clone()),
            conflicted: false,
            task_id,
            expected_revision: store.revision,
            config,
            picker: None,
            saving: false,
        });
        self.assistant.error = None;
        self.assistant.detail_scroll = Default::default();
        cx.notify();
    }

    pub(super) fn assistant_select_task(&mut self, id: String, cx: &mut Context<Self>) {
        if self.assistant.editor.is_some()
            || self.assistant.form_busy()
            || self.assistant.deletion.is_some()
        {
            return;
        }
        self.assistant.selected_task_id = Some(id);
        self.assistant.detail_scroll = Default::default();
        cx.notify();
    }

    pub(super) fn assistant_save_task(&mut self, cx: &mut Context<Self>) {
        if !self.runtime.is_native() || self.assistant.form_busy() {
            return;
        }
        let Some(store) = self.assistant.snapshot.store.as_ref() else {
            return;
        };
        let Some(editor) = self.assistant.editor.as_mut() else {
            return;
        };
        editor.config.title = editor.config.title.trim().to_owned();
        let command = match prepare_task_save(editor, store, self.locale) {
            Ok(command) => command,
            Err(error) => {
                self.assistant.error = Some(error);
                cx.notify();
                return;
            }
        };
        editor.saving = true;
        self.assistant.error = None;
        self.assistant_command(command, cx);
        cx.notify();
    }

    pub(super) fn assistant_pick(&mut self, picker: Picker, cx: &mut Context<Self>) {
        if self.assistant.form_busy()
            || (picker == Picker::Workspace && self.assistant.workspace_locked())
        {
            return;
        }
        if let Some(editor) = &mut self.assistant.editor {
            editor.picker = if editor.picker == Some(picker) {
                None
            } else {
                Some(picker)
            };
        }
        if picker == Picker::Workspace
            && self.runtime.is_native()
            && !self.browser.workspaces_loaded
        {
            self.run(
                super::Reply::Workspaces,
                RuntimeCommand::new("LocalWorkspaces", "list", vec![]),
                cx,
            );
        }
        cx.notify();
    }

    pub(super) fn assistant_choose_workspace(&mut self, descriptor: Value, cx: &mut Context<Self>) {
        if self.assistant.form_busy() || self.assistant.workspace_locked() {
            return;
        }
        match workspace_binding(&descriptor) {
            Ok(binding) => {
                if let Some(editor) = &mut self.assistant.editor {
                    editor.config.workspace_binding = binding;
                    editor.config.workspace_descriptor = descriptor;
                    editor.picker = None;
                }
            }
            Err(error) => self.assistant.error = Some(error),
        }
        cx.notify();
    }

    pub(super) fn assistant_edit_field(&mut self, field: Field, cx: &mut Context<Self>) {
        if !self.runtime.is_native() || self.assistant.form_busy() || self.native_form_active {
            return;
        }
        let Some(store) = self.assistant.snapshot.store.as_ref() else {
            return;
        };
        let selected_bot_id = self.assistant.selected_bot_id().to_owned();
        let baseline_profile = store.profile.clone();
        let had_profile_draft = self.assistant.profile_draft.is_some();
        let draft_baseline = self
            .assistant
            .profile_draft
            .as_ref()
            .map(|draft| draft.baseline.clone())
            .unwrap_or_else(|| baseline_profile.clone());
        let mut profile = self
            .assistant
            .profile_draft
            .as_ref()
            .map(|draft| draft.profile.clone())
            .unwrap_or_else(|| baseline_profile.clone());
        let editor_id = self.assistant.editor.as_ref().map(|e| e.id.clone());
        let (title, initial, multiline) = match field {
            Field::ProfileName => (
                copy(self.locale, "Assistant name", "助手名称"),
                profile.name.clone(),
                false,
            ),
            Field::ProfileNotes => (
                copy(self.locale, "Your long-term notes", "你的长期备注"),
                profile.notes.clone(),
                true,
            ),
            Field::ProfileSoul => (
                copy(
                    self.locale,
                    "Soul · personality and principles",
                    "Soul · 性格与原则",
                ),
                profile.soul.clone(),
                true,
            ),
            Field::Title | Field::Instructions | Field::Interval => {
                let Some(editor) = &self.assistant.editor else {
                    return;
                };
                match field {
                    Field::Title => (
                        copy(self.locale, "Task title", "任务名称"),
                        editor.config.title.clone(),
                        false,
                    ),
                    Field::Instructions => (
                        copy(self.locale, "Task instructions", "任务要求"),
                        editor.config.instructions.clone(),
                        true,
                    ),
                    _ => (
                        copy(
                            self.locale,
                            "Follow-up interval (minutes)",
                            "跟进间隔（分钟）",
                        ),
                        editor
                            .config
                            .interval_minutes
                            .map(|n| n.to_string())
                            .unwrap_or_default(),
                        false,
                    ),
                }
            }
        };
        let token = uuid::Uuid::new_v4().to_string();
        self.assistant.form_request = Some(token.clone());
        self.assistant.error = None;
        self.set_inline_native_form(true, cx);
        let command = field_command(title, &initial, multiline, self.locale, cx);
        let runtime = self.runtime.clone();
        cx.spawn(async move |this, cx| {
            let result = runtime.call(&command.module, &command.method, Value::Array(command.args)).await;
            let _ = this.update(cx, |this, cx| {
                if this.assistant.form_request.as_ref() != Some(&token) { return; }
                this.assistant.form_request = None;
                this.set_inline_native_form(false, cx);
                if this.assistant.selected_bot_id() != selected_bot_id {
                    this.assistant.accept_error(copy(this.locale,
                        "The selected Bot changed. This edit was not applied to another Bot.",
                        "当前 Bot 已切换，此次编辑未应用到其他 Bot。"));
                    cx.notify(); return;
                }
                let text = match result {
                    Ok(Value::String(text)) => text,
                    Ok(Value::Null) => { cx.notify(); return; },
                    Ok(_) => { this.assistant.accept_error(copy(this.locale, "Unrecognized input result. Your draft was kept.", "无法识别输入结果，已保留草稿。")); cx.notify(); return; },
                    Err(error) => { this.assistant.accept_error(&error); cx.notify(); return; },
                };
                if text.len() > MAX_TEXT_BYTES || text.contains('\0') {
                    this.assistant.accept_error(copy(this.locale, "Text is too long or contains an invalid character.", "文字过长或包含无效字符。"));
                    cx.notify(); return;
                }
                match field {
                    Field::ProfileName | Field::ProfileNotes | Field::ProfileSoul => {
                        match field { Field::ProfileName => profile.name = text.trim().into(), Field::ProfileSoul => profile.soul = text, _ => profile.notes = text }
                        let Some(store) = &this.assistant.snapshot.store else { return; };
                        let unchanged = store.profile == baseline_profile;
                        let mut draft = ProfileDraft { baseline: draft_baseline.clone(), profile, expected_revision: store.revision, saving: false };
                        draft.rebase(&store.profile);
                        this.assistant.profile_draft = Some(draft);
                        if unchanged && !had_profile_draft { this.assistant_save_profile(cx); }
                        else { this.assistant.accept_error(copy(this.locale, "The profile changed or has an unsaved draft. Review your changes before saving.", "资料已变更或存在未保存草稿。请核对后保存资料。")); }
                    },
                    _ => if let Some(editor) = this.assistant.editor.as_mut().filter(|e| Some(&e.id) == editor_id.as_ref()) {
                        match field {
                            Field::Title => editor.config.title = text,
                            Field::Instructions => editor.config.instructions = text,
                            Field::Interval => match parse_interval(&text) {
                                Ok(minutes) => { editor.config.interval_minutes = minutes; editor.picker = None; },
                                Err(()) => this.assistant.error = Some(copy(this.locale, "Enter at least 15 minutes, or leave blank for manual runs.", "请输入至少 15 分钟；留空表示仅手动运行。").into()),
                            },
                            _ => {},
                        }
                    },
                }
                cx.notify();
            });
        }).detach();
        cx.notify();
    }

    pub(super) fn assistant_save_profile(&mut self, cx: &mut Context<Self>) {
        if !self.runtime.is_native() || self.assistant.form_busy() {
            return;
        }
        let Some(store) = &self.assistant.snapshot.store else {
            return;
        };
        let Some(draft) = &mut self.assistant.profile_draft else {
            return;
        };
        let command = prepare_profile_save(draft, store);
        self.assistant_command(command, cx);
        cx.notify();
    }
}

pub(super) fn prepare_task_save(
    editor: &mut TaskEditor,
    store: &AssistantSnapshot,
    locale: super::Locale,
) -> Result<RunnerCommand, String> {
    validate_draft(&editor.config, locale)?;
    if let Some(task_id) = &editor.task_id {
        let current = store.tasks.iter().find(|task| &task.id == task_id);
        if current.is_some_and(|task| {
            task.last_run.is_some() && task.workspace_binding != editor.config.workspace_binding
        }) {
            return Err(copy(
                locale,
                "This task has already run. Create a new task to use another workspace.",
                "此任务已运行。要使用其他工作空间，请新建任务。",
            )
            .into());
        }
        if current.is_none()
            || current.map(AssistantTask::config).as_ref() != editor.base_config.as_ref()
        {
            editor.conflicted = true;
            return Err(copy(locale, "This task changed while you edited. Your draft is kept. Review before saving your version.", "编辑期间任务已变更，已保留草稿。请核对后再保存你的版本。").into());
        }
    } else if store
        .tasks
        .iter()
        .any(|task| task.id == editor.id && task.config() != editor.config)
    {
        editor.conflicted = true;
        return Err(copy(locale, "This task was already saved with different content. Your draft is kept; save your version to update that task.", "此任务已保存，内容与你的草稿不同。已保留草稿；保存你的版本会更新该任务。").into());
    }
    editor.expected_revision = store.revision;
    editor.conflicted = false;
    Ok(match &editor.task_id {
        Some(task_id) => RunnerCommand::UpdateTask {
            expected_revision: store.revision,
            task_id: task_id.clone(),
            config: editor.config.clone(),
        },
        None => RunnerCommand::CreateTask {
            expected_revision: store.revision,
            task_id: editor.id.clone(),
            config: editor.config.clone(),
        },
    })
}

use super::assistant_copy::field_command;
pub(super) use super::assistant_copy::{parse_interval, validate_draft};
