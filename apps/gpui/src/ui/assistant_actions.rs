use super::{assistant_copy as words, assistant_forms::*, assistant_view::Action, *};
use crate::{assistant_runtime::RunnerCommand, icons::Icon};
use gpui::AnyElement;

impl Shell {
    pub(super) fn assistant_action(&mut self, action: Action, cx: &mut Context<Self>) {
        if self.assistant.deletion.is_some()
            && !matches!(action, Action::ConfirmDelete | Action::CancelDelete)
        {
            return;
        }
        if matches!(
            &action,
            Action::Back | Action::Edit(_) | Action::Delete(_) | Action::Select(_) | Action::New
        ) {
            self.assistant.task_menu_open = false;
            self.assistant.tasks_open = true;
            self.assistant.panel = super::assistant_memory_state::AssistantPanel::Tasks;
        }
        match action {
            Action::Memory(action) => {
                if matches!(action, super::assistant_memory_state::MemoryAction::Open) {
                    self.navigate(Page::Assistant, cx);
                }
                self.assistant_memory_action(action, cx);
            }
            Action::ToggleTasks => self.assistant.tasks_open = !self.assistant.tasks_open,
            Action::CloseTasks => {
                self.assistant.tasks_open = false;
                self.enter_assistant_conversation(cx);
            }
            Action::ChooseAvatar => self.assistant_choose_avatar(cx),
            Action::RestoreAvatar => self.assistant_restore_avatar(cx),
            Action::ToggleTaskMenu => {
                self.assistant.task_menu_open = !self.assistant.task_menu_open
            }
            Action::ToggleSettings => self.assistant.settings_open = !self.assistant.settings_open,
            Action::New => self.assistant_begin_task(None, cx),
            Action::Edit(id) => self.assistant_begin_task(Some(id), cx),
            Action::Select(id) => self.assistant_select_task(id, cx),
            Action::Back => {
                self.assistant.selected_task_id = None;
                self.assistant.detail_scroll = Default::default();
            }
            Action::Cancel => {
                if !self.assistant.form_busy() {
                    self.assistant.editor = None;
                    self.assistant.error = None;
                }
            }
            Action::Save => self.assistant_save_task(cx),
            Action::SaveProfile => self.assistant_save_profile(cx),
            Action::DiscardProfile => {
                self.assistant.profile_draft = None;
                self.assistant.error = None;
            }
            Action::Overwrite => {
                if let (Some(editor), Some(store)) =
                    (&mut self.assistant.editor, &self.assistant.snapshot.store)
                {
                    let id = editor.task_id.as_ref().unwrap_or(&editor.id);
                    if let Some(task) = store.tasks.iter().find(|task| &task.id == id) {
                        editor.task_id = Some(task.id.clone());
                        editor.base_config = Some(task.config());
                    }
                }
                self.assistant_save_task(cx);
            }
            Action::Field(field) => self.assistant_edit_field(field, cx),
            Action::Run(task_id) => {
                self.assistant.tasks_open = false;
                self.assistant_command(RunnerCommand::RunNow { task_id }, cx);
            }
            Action::Recover(task_id) => {
                self.assistant_command(RunnerCommand::Recover { task_id }, cx)
            }
            Action::Enabled(task_id, enabled) => {
                if let Some(store) = &self.assistant.snapshot.store {
                    self.assistant_command(
                        RunnerCommand::SetEnabled {
                            expected_revision: store.revision,
                            task_id,
                            enabled,
                        },
                        cx,
                    );
                }
            }
            Action::Open(id) => self.assistant_open_conversation(id, cx),
            Action::Pick(picker) => self.assistant_pick(picker, cx),
            Action::Workspace(descriptor) => self.assistant_choose_workspace(descriptor, cx),
            Action::Model(model) => {
                if let Some(editor) = &mut self.assistant.editor
                    && !editor.saving
                {
                    editor.config.model_id = model;
                    editor.picker = None;
                }
            }
            Action::Interval(interval) => {
                if let Some(editor) = &mut self.assistant.editor
                    && !editor.saving
                {
                    editor.config.interval_minutes = interval;
                    editor.picker = None;
                }
            }
            Action::Delete(task_id) => {
                if self.runtime.is_native()
                    && let Err(error) = self.assistant.begin_deletion(&task_id, self.locale)
                {
                    self.assistant.accept_error(&error);
                }
            }
            Action::ConfirmDelete => {
                if self.runtime.is_native()
                    && self.assistant.deletion.as_ref().is_some_and(|d| !d.saving)
                {
                    match self.assistant.prepare_deletion(self.locale) {
                        Ok(command) => self.assistant_command(command, cx),
                        Err(error) => self.assistant.accept_error(&error),
                    }
                }
            }
            Action::CancelDelete => {
                if self.assistant.deletion.as_ref().is_some_and(|d| !d.saving) {
                    self.assistant.deletion = None;
                    self.assistant.error = None;
                }
            }
        }
        cx.notify();
    }

    pub(super) fn assistant_delete_confirmation(&self, cx: &mut Context<Self>) -> AnyElement {
        let deletion = self.assistant.deletion.as_ref().unwrap();
        let p = Palette::get(cx);
        let enabled = self.runtime.is_native() && !deletion.saving;
        div()
            .id("assistant-delete-confirmation")
            .debug_selector(|| "assistant-delete-confirmation".into())
            .p_3()
            .rounded(px(14.))
            .bg(p.surface)
            .flex_shrink_0()
            .flex()
            .flex_col()
            .gap_3()
            .child(div().text_size(px(14.)).whitespace_normal().child(format!(
                "{}{}", words::copy(self.locale, "Delete task: ", "删除任务："), deletion.title
            )))
            .child(div().text_size(px(12.)).line_height(px(19.)).text_color(p.muted)
                .whitespace_normal().child(words::copy(self.locale,
                    "This removes the saved task and future follow-ups. Its conversation and messages are kept.",
                    "将删除此任务及后续跟进安排，关联会话和消息会保留。")))
            .child(div().flex().flex_wrap().gap_2()
                .child(self.assistant_button("assistant-delete-cancel", words::copy(self.locale, "Keep task", "保留任务"),
                    Icon::X, enabled, Action::CancelDelete, cx))
                .child(self.assistant_button("assistant-delete-confirm", words::copy(self.locale,
                    if deletion.saving { "Deleting…" } else { "Delete task" },
                    if deletion.saving { "删除中…" } else { "删除任务" }),
                    Icon::Trash2, enabled, Action::ConfirmDelete, cx)))
            .into_any_element()
    }
}

impl AssistantUi {
    pub(super) fn begin_deletion(&mut self, task_id: &str, locale: Locale) -> Result<(), String> {
        if self.form_busy() || self.editor.is_some() {
            return Err(words::copy(
                locale,
                "Finish the current edit first.",
                "请先完成当前编辑。",
            )
            .into());
        }
        let store = self.snapshot.store.as_ref().ok_or_else(|| {
            words::copy(
                locale,
                "Task data is not available yet.",
                "任务数据尚未就绪。",
            )
            .to_owned()
        })?;
        let task = store
            .tasks
            .iter()
            .find(|task| task.id == task_id)
            .ok_or_else(|| {
                words::copy(locale, "This task no longer exists.", "此任务已不存在。").to_owned()
            })?;
        if task.is_running() {
            return Err(words::copy(
                locale,
                "Check or stop the current run before deleting this task.",
                "请先核对或停止当前运行，再删除任务。",
            )
            .into());
        }
        self.deletion = Some(TaskDeletion {
            task_id: task.id.clone(),
            title: task.title.clone(),
            expected_revision: store.revision,
            saving: false,
        });
        self.error = None;
        Ok(())
    }

    pub(super) fn prepare_deletion(&mut self, locale: Locale) -> Result<RunnerCommand, String> {
        let deletion = self.deletion.as_mut().ok_or_else(|| {
            words::copy(
                locale,
                "Open the delete confirmation first.",
                "请先打开删除确认。",
            )
            .to_owned()
        })?;
        if deletion.saving {
            return Err(words::copy(
                locale,
                "Deletion is still being saved.",
                "正在保存删除结果。",
            )
            .into());
        }
        let store = self.snapshot.store.as_ref().ok_or_else(|| {
            words::copy(
                locale,
                "Task data is not available yet.",
                "任务数据尚未就绪。",
            )
            .to_owned()
        })?;
        if store.revision != deletion.expected_revision {
            return Err(words::copy(
                locale,
                "Task data changed. Keep the task, then reopen this confirmation to review it.",
                "任务数据已变更。请先保留任务，再重新打开删除确认并核对。",
            )
            .into());
        }
        let task = store
            .tasks
            .iter()
            .find(|task| task.id == deletion.task_id)
            .ok_or_else(|| {
                words::copy(locale, "This task no longer exists.", "此任务已不存在。").to_owned()
            })?;
        if task.is_running() {
            return Err(words::copy(
                locale,
                "Check or stop the current run before deleting this task.",
                "请先核对或停止当前运行，再删除任务。",
            )
            .into());
        }
        deletion.saving = true;
        self.error = None;
        Ok(RunnerCommand::RemoveTask {
            expected_revision: deletion.expected_revision,
            task_id: deletion.task_id.clone(),
        })
    }
}
