use super::{Page, Reply, Shell, i18n::Text};
use gpui::Context;
use rish_shell_core::{RuntimeCommand, workspace_binding};
use serde_json::{Value, json};

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct WorkspaceResolution {
    pub conversation_id: String,
    pub binding: Value,
}
#[derive(Clone, Copy)]
pub(super) enum WorkspaceIntent {
    Create,
    Assistant,
    Send,
    Open(Page),
    Choose,
}
#[derive(Default)]
pub(super) struct ConversationWorkspace {
    pub active_id: Option<String>,
    pub binding: Option<Value>,
    pub descriptor: Option<Value>,
    pub selector: bool,
    pub selector_scroll: gpui::ScrollHandle,
    pub ensuring: bool,
    pub resolving: Option<WorkspaceResolution>,
    pub intent: Option<WorkspaceIntent>,
}

impl Shell {
    pub(super) fn conversation_workspace_name(&self) -> String {
        self.conversation_workspace
            .descriptor
            .as_ref()
            .or_else(|| {
                self.state
                    .default_workspace()
                    .filter(|_| self.state.active_conversation_id().is_none())
            })
            .and_then(|v| v["display_name"].as_str())
            .unwrap_or(
                self.locale
                    .text(if self.state.active_conversation_id().is_none() {
                        Text::DefaultWorkspace
                    } else {
                        Text::WorkspaceUnavailable
                    }),
            )
            .to_owned()
    }

    pub(super) fn conversation_switch_blocked(
        &mut self,
        allow_composer: bool,
        cx: &mut Context<Self>,
    ) -> bool {
        let blocked = self.loading
            || self.assistant_writer_lease
            || self.state.is_busy()
            || self.aux_busy
            || self.has_file_draft()
            || (!allow_composer && !self.composer.read(cx).text().trim().is_empty());
        if blocked {
            self.notice = Some(self.locale.text(Text::FinishWorkspaceOperation).into());
            cx.notify();
        }
        blocked
    }

    pub(super) fn ensure_conversation_workspace(
        &mut self,
        intent: Option<WorkspaceIntent>,
        cx: &mut Context<Self>,
    ) {
        if intent.is_some() {
            self.conversation_workspace.intent = intent;
        }
        if !self.runtime.is_native()
            || self.loading
            || self.state.is_busy()
            || self.aux_busy
            || self.conversation_workspace.ensuring
        {
            return;
        }
        if self.state.default_workspace().is_none() {
            self.conversation_workspace.ensuring = true;
            self.run(
                Reply::DefaultWorkspace,
                RuntimeCommand::new(
                    "ShellWorkspace",
                    "ensureDefault",
                    vec![json!({"display_name":self.locale.text(Text::DefaultWorkspace)})],
                ),
                cx,
            );
        } else {
            self.continue_workspace_lifecycle(cx);
        }
    }

    pub(super) fn accept_default_workspace(
        &mut self,
        result: Result<Value, String>,
        cx: &mut Context<Self>,
    ) {
        if !self.conversation_workspace.ensuring {
            return;
        }
        self.conversation_workspace.ensuring = false;
        self.aux_busy = false;
        match result.and_then(|v| self.state.set_default_workspace(v)) {
            Ok(()) => self.continue_workspace_lifecycle(cx),
            Err(error) => {
                self.conversation_workspace.intent = None;
                self.send_after_create = false;
                self.workspace_error(&error, cx);
            }
        }
        cx.notify();
    }

    pub(super) fn continue_workspace_lifecycle(&mut self, cx: &mut Context<Self>) {
        if !self.state.is_loaded() || self.loading || self.state.is_busy() {
            return;
        }
        if self.state.default_workspace().is_none() {
            self.ensure_conversation_workspace(None, cx);
            return;
        }
        if self.state.has_unbound_workspaces() {
            match self.state.migrate_unbound_workspaces() {
                Ok(Some(command)) => {
                    self.run(Reply::Persist, command, cx);
                    return;
                }
                Ok(None) => {}
                Err(error) => {
                    self.workspace_error(&error, cx);
                    return;
                }
            }
        }
        self.sync_conversation_workspace(cx);
        if self.state.active_conversation_id().is_some()
            && self.state.active_workspace_binding().is_none()
        {
            self.conversation_workspace.intent = None;
            self.send_after_create = false;
            self.workspace_error("E_CONVERSATION_WORKSPACE_UNAVAILABLE", cx);
            return;
        }
        if self.aux_busy || self.loading || self.state.is_busy() {
            return;
        }
        if let Some(intent) = self.conversation_workspace.intent.take() {
            match intent {
                WorkspaceIntent::Create => self.create(cx),
                WorkspaceIntent::Assistant => self.enter_assistant_conversation(cx),
                WorkspaceIntent::Send => self.send(cx),
                WorkspaceIntent::Open(page) => self.open_conversation_workspace(page, cx),
                WorkspaceIntent::Choose => self.choose_conversation_workspace(cx),
            }
        }
    }

    pub(super) fn sync_conversation_workspace(&mut self, cx: &mut Context<Self>) {
        let id = self.state.active_conversation_id().map(str::to_owned);
        let binding = self.state.active_workspace_binding().cloned();
        if self.conversation_workspace.active_id == id
            && self.conversation_workspace.binding == binding
        {
            return;
        }
        self.conversation_workspace.active_id = id.clone();
        self.conversation_workspace.binding = binding.clone();
        self.conversation_workspace.descriptor = None;
        self.conversation_workspace.selector = false;
        self.conversation_workspace.resolving = None;
        self.workspace_focus = false;
        self.clear_conversation_browser();
        let (Some(conversation_id), Some(binding)) = (id, binding) else {
            cx.notify();
            return;
        };
        if let Some(descriptor) = self
            .state
            .default_workspace()
            .filter(|v| workspace_binding(v).ok().as_ref() == Some(&binding))
            .cloned()
        {
            self.mount_conversation_workspace(descriptor, cx);
        } else if self.runtime.is_native() && !self.aux_busy {
            self.resolve_conversation_workspace(
                WorkspaceResolution {
                    conversation_id,
                    binding,
                },
                cx,
            );
        } else if !self.runtime.is_native() {
            // Headless/desktop previews preserve saved authority without claiming
            // that a mobile filesystem was opened.
            self.browser.root = Some(binding);
        }
        cx.notify();
    }

    fn clear_conversation_browser(&mut self) {
        self.workspace_panel_files_scroll
            .set_offset(gpui::point(gpui::px(0.), gpui::px(0.)));
        self.workspace_panel_git_scroll
            .set_offset(gpui::point(gpui::px(0.), gpui::px(0.)));
        self.browser.generation += 1;
        self.browser.root = None;
        self.browser.name.clear();
        self.browser.path.clear();
        self.browser.entries.clear();
        self.browser.file = None;
        self.browser.capabilities = Value::Null;
        self.browser.files_directory_scroll = gpui::ScrollHandle::new();
        self.browser.files_document_scroll = gpui::ScrollHandle::new();
        self.browser.git_diff_scroll = gpui::ScrollHandle::new();
        self.browser.git = Default::default();
        self.browser.git_actions.metadata_root = None;
        self.browser.git_actions.remote = None;
        self.browser.git_actions.credential = None;
        self.browser.git_actions.diff = None;
        self.browser.git_actions.feedback = None;
        // Keep draft, push ambiguity and cancellation fences under captured roots.
    }

    pub(super) fn resolve_active_workspace(&mut self, cx: &mut Context<Self>) {
        if let (Some(id), Some(binding)) = (
            self.state.active_conversation_id(),
            self.state.active_workspace_binding(),
        ) {
            self.resolve_conversation_workspace(
                WorkspaceResolution {
                    conversation_id: id.into(),
                    binding: binding.clone(),
                },
                cx,
            );
        }
    }

    fn resolve_conversation_workspace(
        &mut self,
        request: WorkspaceResolution,
        cx: &mut Context<Self>,
    ) {
        self.conversation_workspace.resolving = Some(request.clone());
        self.run(Reply::ConversationWorkspace(request.clone()),RuntimeCommand::new("LocalWorkspaces","resolve",vec![json!({
            "schema_version":1,"workspace_id":request.binding["workspace_id"],"expected_binding_revision":request.binding["binding_revision"],"required_capabilities":["read"]
        })]),cx);
    }

    pub(super) fn accept_conversation_workspace(
        &mut self,
        request: WorkspaceResolution,
        result: Result<Value, String>,
        cx: &mut Context<Self>,
    ) {
        if self.conversation_workspace.resolving.as_ref() != Some(&request) {
            return;
        }
        self.conversation_workspace.resolving = None;
        self.aux_busy = false;
        if self.state.active_conversation_id() != Some(&request.conversation_id)
            || self.state.active_workspace_binding() != Some(&request.binding)
        {
            cx.notify();
            return;
        }
        let result = result.and_then(|v| {
            if v["schema_version"] != 1 {
                return Err("E_CONVERSATION_WORKSPACE_UNAVAILABLE".into());
            }
            let descriptor = v["workspace"].clone();
            let actual = workspace_binding(&descriptor)?;
            if actual["workspace_id"] != request.binding["workspace_id"]
                || actual["binding_revision"] != request.binding["binding_revision"]
            {
                return Err("E_CONVERSATION_WORKSPACE_UNAVAILABLE".into());
            }
            Ok(descriptor)
        });
        match result {
            Ok(descriptor) => {
                self.mount_conversation_workspace(descriptor, cx);
                self.continue_workspace_lifecycle(cx);
            }
            Err(error) => {
                self.conversation_workspace.intent = None;
                self.workspace_error(&error, cx);
            }
        }
        self.enter_assistant_conversation(cx);
        cx.notify();
    }

    fn mount_conversation_workspace(&mut self, descriptor: Value, _cx: &mut Context<Self>) {
        let Some(binding) = self.state.active_workspace_binding().cloned() else {
            return;
        };
        self.browser
            .workspaces
            .retain(|v| v["workspace_id"] != descriptor["workspace_id"]);
        self.browser.workspaces.push(descriptor.clone());
        self.browser.root = Some(binding);
        self.browser.name = descriptor["display_name"].as_str().unwrap_or("").to_owned();
        self.browser.capabilities = descriptor["capabilities"].clone();
        self.conversation_workspace.descriptor = Some(descriptor);
        self.conversation_workspace.selector = false;
    }

    fn load_conversation_workspace_page(&mut self, cx: &mut Context<Self>) {
        if self.page == Page::Git {
            self.load_git(cx);
        } else {
            self.load_folder(self.browser.path.clone(), cx);
        }
    }

    pub(super) fn open_conversation_workspace(&mut self, page: Page, cx: &mut Context<Self>) {
        if !matches!(page, Page::Files | Page::Git) {
            return;
        }
        if self.loading || self.state.is_busy() || self.aux_busy {
            return;
        }
        if self.state.active_conversation_id().is_none() {
            self.conversation_workspace.intent = Some(WorkspaceIntent::Open(page));
            self.create(cx);
            return;
        }
        self.page = page;
        self.conversation_workspace.selector = false;
        if self.state.active_workspace_binding().is_none() {
            self.ensure_conversation_workspace(Some(WorkspaceIntent::Open(page)), cx);
            return;
        }
        if let Some(descriptor) = self.conversation_workspace.descriptor.clone() {
            // Leaving the selector restores the saved conversation binding,
            // never the last workspace that happened to be browsed.
            self.browser.root = self.state.active_workspace_binding().cloned();
            self.browser.name = descriptor["display_name"].as_str().unwrap_or("").to_owned();
            self.load_conversation_workspace_page(cx);
        } else if self.runtime.is_native() {
            self.conversation_workspace.intent = Some(WorkspaceIntent::Open(page));
            self.resolve_conversation_workspace(
                WorkspaceResolution {
                    conversation_id: self.state.active_conversation_id().unwrap().into(),
                    binding: self.state.active_workspace_binding().unwrap().clone(),
                },
                cx,
            );
        }
        cx.notify();
    }

    pub(super) fn choose_conversation_workspace(&mut self, cx: &mut Context<Self>) {
        if self.conversation_workspace.selector {
            self.cancel_conversation_workspace_selection(cx);
            return;
        }
        if self.conversation_switch_blocked(true, cx) {
            return;
        }
        if self.state.active_conversation_id().is_none() {
            self.conversation_workspace.intent = Some(WorkspaceIntent::Choose);
            self.create(cx);
            return;
        }
        self.conversation_workspace.selector = true;
        self.conversation_workspace.selector_scroll = gpui::ScrollHandle::new();
        self.page = Page::Files;
        self.browser.generation += 1;
        self.browser.root = None;
        if self.runtime.is_native() {
            self.run(
                Reply::Workspaces,
                RuntimeCommand::new("LocalWorkspaces", "list", vec![]),
                cx,
            );
        }
        if !self.state.messages().is_empty() {
            self.notice = Some(self.locale.text(Text::ConversationWorkspaceLocked).into());
        }
        cx.notify();
    }

    pub(super) fn cancel_conversation_workspace_selection(&mut self, cx: &mut Context<Self>) {
        if !self.conversation_workspace.selector {
            return;
        }
        self.conversation_workspace.selector = false;
        self.browser.root = self
            .conversation_workspace
            .descriptor
            .as_ref()
            .and(self.state.active_workspace_binding().cloned());
        cx.notify();
    }

    pub(super) fn bind_conversation_workspace(
        &mut self,
        descriptor: Value,
        cx: &mut Context<Self>,
    ) {
        if self.preflight_inline_action(
            super::inline_composer::InlineAction::Bind(descriptor.clone()),
            cx,
        ) {
            return;
        }
        if self.conversation_switch_blocked(true, cx) {
            return;
        }
        match self.state.bind_active_workspace(&descriptor) {
            Ok(command) => {
                self.conversation_workspace.intent =
                    Some(WorkspaceIntent::Open(if self.page == Page::Git {
                        Page::Git
                    } else {
                        Page::Files
                    }));
                self.run(Reply::Persist, command, cx);
            }
            Err(error) => self.workspace_error(&error, cx),
        }
    }

    pub(super) fn workspace_error(&mut self, error: &str, cx: &mut Context<Self>) {
        self.cancel_inline_send_intent();
        let text = match error {
            "E_CONVERSATION_WORKSPACE_LOCKED" => Text::ConversationWorkspaceLocked,
            "E_CONVERSATION_WORKSPACE_REQUIRED" => Text::WorkspacePreparing,
            _ => Text::ConversationWorkspaceUnavailable,
        };
        self.notice = Some(self.locale.text(text).into());
        cx.notify();
    }
}
