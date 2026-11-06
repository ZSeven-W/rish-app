//! Durable personal-chat identity and the existing single session writer.
use super::*;
use crate::assistant_runtime::RunnerCommand;

impl Shell {
    /// A resumed participant lane is an implementation detail, never a normal
    /// chat containing the model's delivery envelope. Wait for the directory
    /// before projecting restored native history.
    pub(super) fn restore_registered_assistant_page(&mut self, cx: &mut Context<Self>) {
        if self.page != Page::Chat
            || self.assistant_writer_lease
            || !self.state.is_loaded()
            || self.loading
            || self.state.is_busy()
            || self.navigation_flow.creating
            || self.navigation_flow.pending.is_some()
        {
            return;
        }
        let Some(id) = self.state.active_conversation_id() else {
            return;
        };
        let Some(directory) = self.assistant.directory() else {
            return;
        };
        if let Some(group) = directory
            .groups
            .iter()
            .find(|g| g.members.iter().any(|m| m.conversation_id == id))
        {
            self.assistant.directory_ui.group_id = Some(group.id.clone());
            self.assistant.directory_ui.hub_open = false;
            self.assistant.tasks_open = false;
            self.page = Page::Assistant;
        } else if let Some(bot) = directory.conversation_bot_id(id).map(str::to_owned) {
            self.page = Page::Assistant;
            self.assistant.directory_ui.hub_open = false;
            self.assistant.directory_ui.group_id = None;
            if self.assistant.selected_bot_id() != bot {
                self.assistant.directory_ui.pending_bot_id = Some(bot.clone());
                self.assistant_command(RunnerCommand::SelectBot { bot_id: bot }, cx);
            }
        }
    }
    pub(super) fn bind_assistant_chat_snapshot(&mut self) {
        if let Some(store) = &self.assistant.snapshot.store {
            self.state.bind_assistant_snapshot(store);
            if store.conversation_id.is_some() {
                self.assistant_chat_ensure_revision = None;
            }
        }
    }

    pub(super) fn page_for_conversation(&self, id: &str) -> Page {
        if self
            .assistant
            .directory()
            .is_some_and(|d| d.conversation_bot_id(id).is_some())
        {
            Page::Assistant
        } else {
            Page::Chat
        }
    }

    pub(super) fn enter_assistant_conversation(&mut self, cx: &mut Context<Self>) {
        self.bind_assistant_chat_snapshot();
        if self.page != Page::Assistant
            || self.assistant.directory_ui.hub_open
            || self.assistant.directory_ui.group_id.is_some()
            || self.assistant.directory_ui.pending_bot_id.is_some()
            || !self.runtime.is_native()
            || self.assistant_writer_lease
            || self.loading
            || self.aux_busy
            || self.state.is_busy()
            || self.native_form_active
            || self.has_file_draft()
        {
            return;
        }
        if !self.state.is_loaded() {
            self.bootstrap(cx);
            return;
        }
        let Some(store) = self.assistant.snapshot.store.as_ref() else {
            self.initialize_assistant(cx);
            return;
        };
        let Some(id) = store.conversation_id.clone() else {
            let revision = store.revision;
            if self.assistant_chat_ensure_revision != Some(revision) {
                self.assistant_chat_ensure_revision = Some(revision);
                self.assistant_command(
                    RunnerCommand::EnsureConversation {
                        expected_revision: revision,
                    },
                    cx,
                );
            }
            return;
        };
        if self.state.active_conversation_id() == Some(id.as_str()) {
            self.update_placeholders(cx);
            return;
        }
        if self.state.default_workspace().is_none() {
            self.ensure_conversation_workspace(
                Some(conversation_workspace::WorkspaceIntent::Assistant),
                cx,
            );
            return;
        }
        // Navigation was fenced against IME composition before changing page.
        // Existing native draft sessions keep each conversation's text separate.
        let command = if self.state.conversations().iter().any(|chat| chat.id == id) {
            self.state.select_conversation(&id)
        } else {
            let models = self.state.models();
            let preferred = self.state.preferences()["default_model"]
                .as_str()
                .unwrap_or("");
            let model = models
                .iter()
                .find(|model| model.id == preferred)
                .or_else(|| models.first())
                .map(|model| model.id.clone())
                .unwrap_or_default();
            self.state.create_conversation(&id, &now(), &model)
        };
        self.commit(command, cx);
    }
}
