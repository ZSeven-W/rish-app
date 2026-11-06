mod adaptive;
mod agent;
mod agent_copy;
mod agent_view;
#[cfg(all(test, not(any(target_os = "ios", target_os = "android"))))]
mod agent_view_tests;
mod assistant;
mod assistant_actions;
mod assistant_avatar;
mod assistant_chat_session;
mod assistant_chat_view;
mod assistant_copy;
mod assistant_detail_view;
mod assistant_directory;
#[cfg(all(test, not(any(target_os = "ios", target_os = "android"))))]
mod assistant_directory_tests;
mod assistant_directory_view;
mod assistant_editor_view;
mod assistant_forms;
mod assistant_group_chat;
mod assistant_group_view;
#[cfg(all(test, not(any(target_os = "ios", target_os = "android"))))]
mod assistant_management_tests;
mod assistant_memory_actions;
mod assistant_memory_state;
#[cfg(all(test, not(any(target_os = "ios", target_os = "android"))))]
mod assistant_memory_tests;
mod assistant_memory_view;
mod assistant_platform;
mod assistant_primitives;
#[cfg(all(test, not(any(target_os = "ios", target_os = "android"))))]
mod assistant_shell_layout_tests;
mod assistant_task_panel;
mod assistant_view;
#[cfg(all(test, not(any(target_os = "ios", target_os = "android"))))]
mod assistant_view_tests;
mod browser_requests;
mod composer;
mod composer_drafts;
mod conversation_titles;
mod conversation_workbench;
#[cfg(all(test, not(any(target_os = "ios", target_os = "android"))))]
mod conversation_workbench_tests;
mod conversation_workspace;
mod conversation_workspace_panel;
#[cfg(all(test, not(any(target_os = "ios", target_os = "android"))))]
mod conversation_workspace_tests;
mod drawer;
#[cfg(all(test, not(any(target_os = "ios", target_os = "android"))))]
mod drawer_tests;
mod git_commands;
mod git_controls;
#[cfg(all(test, not(any(target_os = "ios", target_os = "android"))))]
mod git_controls_tests;
mod git_diff_view;
mod git_forms;
mod git_operations;
#[cfg(test)]
mod git_operations_tests;
mod i18n;
mod inline_composer;
mod inline_composer_state;
mod input;
mod layout;
mod model_picker;
mod model_picker_options;
mod model_required;
mod model_setup;
mod navigation_flow;
#[cfg(all(test, not(any(target_os = "ios", target_os = "android"))))]
mod navigation_flow_tests;
mod operations;
mod provider_models;
mod user_identity;
// Keep native prompt copy typechecked by desktop builds without exposing a
// desktop host service that does not exist.
#[cfg(all(test, not(any(target_os = "ios", target_os = "android"))))]
mod model_picker_tests;
#[cfg_attr(not(any(target_os = "ios", target_os = "android")), allow(dead_code))]
mod name_prompt;
mod screens;
mod settings;
mod settings_custom_providers;
#[cfg(all(test, not(any(target_os = "ios", target_os = "android"))))]
mod settings_layout_tests;
mod settings_runtime;
mod settings_runtime_engines;
mod settings_subscription_actions;
mod settings_subscription_view;
mod settings_subscriptions;
mod theme;
mod transcript;
mod view;
mod visuals;
mod workspace_actions;
mod workspace_edit;
mod workspace_git;
#[cfg(test)]
mod workspace_git_tests;
mod workspace_git_view;
mod workspace_inspector;
#[cfg(all(test, not(any(target_os = "ios", target_os = "android"))))]
mod workspace_responsive_tests;
mod workspace_split;
mod workspace_view;

use crate::runtime::Runtime;
use chrono::{SecondsFormat, Utc};
use gpui::{
    App, AppContext, Context, Entity, FocusHandle, IntoElement, Render, Subscription, Window,
    WindowOptions, div, prelude::*, px,
};
use i18n::{Locale, Text};
use input::{Submitted, TextInput};
use rish_shell_core::{RuntimeCommand, ShellState, TurnIds};
use screens::Browser;
use serde_json::Value;
#[cfg(test)]
use serde_json::json;
use theme::{HIT_TARGET, Palette};
use transcript::{DisplayMessage, Transcript};

#[derive(Clone, Copy, PartialEq)]
enum Page {
    Chat,
    Assistant,
    Files,
    Git,
    Settings,
}
#[derive(Clone)]
enum Reply {
    Catalog,
    CustomProviderCatalog,
    Load,
    Persist,
    Completion,
    Cancel,
    Agent(RuntimeCommand),
    AgentPresentations(RuntimeCommand),
    Workspaces,
    DefaultWorkspace,
    ConversationWorkspace(conversation_workspace::WorkspaceResolution),
    Files(u64, String),
    Read(u64, String),
    Git(workspace_git::GitRequest),
    GitAction(git_operations::GitActionRequest),
    #[cfg(any(target_os = "ios", target_os = "android"))]
    Rename,
    #[cfg(any(target_os = "ios", target_os = "android"))]
    WorkspaceName,
    CreatedWorkspace,
    EntryName(workspace_edit::EntryRequest),
    FileEditor(workspace_edit::FileEditRequest),
    FileWritten(workspace_edit::FileEditRequest),
    ResumeDraftFolder(workspace_edit::FileEditRequest),
    DirectoryCreated(workspace_edit::EntryRequest),
}

pub fn open(cx: &mut App) {
    input::bind_keys(cx);
    let options = WindowOptions::default();
    #[cfg(not(any(target_os = "ios", target_os = "android")))]
    let options = WindowOptions {
        window_bounds: Some(gpui::WindowBounds::Windowed(gpui::Bounds::centered(
            None,
            gpui::size(px(1100.), px(780.)),
            cx,
        ))),
        titlebar: Some(gpui::TitlebarOptions {
            title: Some("Rish".into()),
            ..Default::default()
        }),
        ..options
    };
    if let Err(error) = cx.open_window(options, |_, cx| cx.new(Shell::new)) {
        log::error!("Cannot open the Rish window: {error}");
    }
    #[cfg(not(any(target_os = "ios", target_os = "android")))]
    cx.activate(true);
}

struct Shell {
    runtime: Runtime,
    assistant: assistant_forms::AssistantUi,
    assistant_runner: Option<crate::assistant_runtime::RunnerHandle>,
    assistant_writer_lease: bool,
    assistant_handoff_state: Option<ShellState>,
    assistant_answer: Option<assistant::AnswerSubmission>,
    assistant_handoff: Option<String>,
    assistant_storage_loading: bool,
    assistant_storage_directory: Option<std::path::PathBuf>,
    assistant_chat_ensure_revision: Option<u64>,
    assistant_platform: Option<Value>,
    assistant_platform_pending: bool,
    settings_expanded: Option<settings::PreferenceGroup>,
    settings_return_page: Page,
    runtime_editor: Option<settings_runtime::RuntimeEditor>,
    runtime_engines: settings_runtime_engines::RuntimeEnginesUi,
    runtime_subscriptions: settings_subscriptions::RuntimeSubscriptionsUi,
    custom_providers: settings_custom_providers::CustomProvidersUi,
    provider_models: provider_models::ProviderModelsUi,
    assistant_visible_signature: Option<assistant_platform::VisibilitySignature>,
    _assistant_events: Option<gpui::Task<()>>,
    _assistant_tick: Option<gpui::Task<()>>,
    state: ShellState,
    navigation_flow: navigation_flow::NavigationFlow,
    locale: Locale,
    page: Page,
    workspace_focus: bool,
    workspace_panel_modal: bool,
    workspace_panel_focus: FocusHandle,
    workspace_panel_previous_focus: Option<FocusHandle>,
    workspace_panel_files_scroll: gpui::ScrollHandle,
    workspace_panel_git_scroll: gpui::ScrollHandle,
    conversation_workspace: conversation_workspace::ConversationWorkspace,
    composer: Entity<TextInput>,
    inline_composer: inline_composer::InlineComposer,
    composer_drafts: composer_drafts::ComposerDrafts,
    native_form_active: bool,
    title_input: Entity<TextInput>,
    transcript: Entity<Transcript>,
    agent_requests: Vec<RuntimeCommand>,
    agent_presentation_pending: Option<RuntimeCommand>,
    agent_presentation_queue: std::collections::VecDeque<RuntimeCommand>,
    agent_presentation_refresh: bool,
    agent_scroll: gpui::ScrollHandle,
    _agent_events: Option<gpui::Task<()>>,
    drawer_open: bool,
    drawer_focus: FocusHandle,
    drawer_previous_focus: Option<FocusHandle>,
    sidebar_scroll: gpui::ScrollHandle,
    conversation_scroll: gpui::ScrollHandle,
    model_picker: bool,
    model_picker_focus: FocusHandle,
    model_picker_previous_focus: Option<FocusHandle>,
    model_picker_focus_pending: bool,
    model_picker_scroll: gpui::ScrollHandle,
    config_draft: Option<model_picker::ConfigurationDraft>,
    config_page: model_picker::ConfigurationPage,
    rename_open: bool,
    workspace_name_open: bool,
    loading: bool,
    aux_busy: bool,
    git_pending: Option<workspace_git::GitRequest>,
    browser_pending: Option<browser_requests::BrowserReadRequest>,
    send_after_create: bool,
    notice: Option<String>,
    browser: Browser,
    _subscriptions: Vec<Subscription>,
}
impl Shell {
    fn new(cx: &mut Context<Self>) -> Self {
        cx.set_global(theme::ThemeState::default());
        let locale = Locale::detect();
        let composer = cx.new(|cx| TextInput::new(locale.text(Text::Composer), cx));
        let title_input = cx.new(|cx| TextInput::new(locale.text(Text::Title), cx));
        let submitted = cx.subscribe(&composer, |this, _, _: &Submitted, cx| this.send(cx));
        let draft_changed = cx.observe(&composer, |this, _, cx| this.composer_text_changed(cx));
        let title_submitted = cx.subscribe(&title_input, |this, _, _: &Submitted, cx| {
            if this.workspace_name_open {
                let name = this.title_input.read(cx).text();
                this.create_workspace(name, cx);
            } else {
                this.save_title(cx);
            }
        });
        let runtime = Runtime::default();
        let mut shell = Self {
            runtime,
            assistant: Default::default(),
            assistant_runner: None,
            assistant_writer_lease: false,
            assistant_handoff_state: None,
            assistant_answer: None,
            assistant_handoff: None,
            assistant_storage_loading: false,
            assistant_storage_directory: None,
            assistant_chat_ensure_revision: None,
            assistant_platform: None,
            assistant_platform_pending: false,
            settings_expanded: None,
            settings_return_page: Page::Chat,
            runtime_editor: None,
            runtime_engines: Default::default(),
            runtime_subscriptions: Default::default(),
            custom_providers: Default::default(),
            provider_models: Default::default(),
            assistant_visible_signature: None,
            _assistant_events: None,
            _assistant_tick: None,
            state: ShellState::new(),
            navigation_flow: Default::default(),
            locale,
            page: Page::Chat,
            workspace_focus: false,
            workspace_panel_modal: false,
            workspace_panel_focus: cx.focus_handle(),
            workspace_panel_previous_focus: None,
            workspace_panel_files_scroll: gpui::ScrollHandle::new(),
            workspace_panel_git_scroll: gpui::ScrollHandle::new(),
            conversation_workspace: Default::default(),
            composer,
            inline_composer: Default::default(),
            composer_drafts: Default::default(),
            native_form_active: false,
            title_input,
            transcript: cx.new(|_| Transcript::new(locale)),
            agent_requests: Vec::new(),
            agent_presentation_pending: None,
            agent_presentation_queue: Default::default(),
            agent_presentation_refresh: false,
            agent_scroll: gpui::ScrollHandle::new(),
            _agent_events: None,
            drawer_open: false,
            drawer_focus: cx.focus_handle(),
            drawer_previous_focus: None,
            sidebar_scroll: gpui::ScrollHandle::new(),
            conversation_scroll: gpui::ScrollHandle::new(),
            model_picker: false,
            model_picker_focus: cx.focus_handle(),
            model_picker_previous_focus: None,
            model_picker_focus_pending: false,
            model_picker_scroll: gpui::ScrollHandle::new(),
            config_draft: None,
            config_page: model_picker::ConfigurationPage::Configure,
            rename_open: false,
            workspace_name_open: false,
            loading: false,
            aux_busy: false,
            git_pending: None,
            browser_pending: None,
            send_after_create: false,
            notice: None,
            browser: Browser::default(),
            _subscriptions: vec![submitted, title_submitted, draft_changed],
        };
        if shell.runtime.is_native() {
            shell.start_agent_events(cx);
            shell.initialize_assistant(cx);
            if !shell.assistant_writer_lease {
                shell.bootstrap(cx);
            }
        }
        shell
    }
    fn bootstrap(&mut self, cx: &mut Context<Self>) {
        if self.assistant_writer_lease {
            self.recover_visible_agent(cx);
            return;
        }
        if self.loading {
            return;
        }
        if let Some(command) = self
            .state
            .retry_pending_commit()
            .or_else(|| self.state.query_pending_commit())
        {
            self.run(Reply::Persist, command, cx);
        } else if self.state.agent_view().is_some_and(|view| view.recoverable) {
            self.resume_agent_or_workspace(cx);
        } else if self.state.can_reload() {
            self.run(Reply::Catalog, self.state.bootstrap_command(), cx);
        }
    }
    fn settle_failure(&mut self, error: &str, cx: &mut Context<Self>) {
        let code = error
            .split(|c: char| c == ':' || c.is_whitespace())
            .next()
            .filter(|s| s.starts_with("E_"))
            .unwrap_or("E_COMPLETION_NATIVE");
        match self.state.fail_send(code, &now()) {
            Ok(command) => self.run(Reply::Persist, command, cx),
            Err(message) => self.state.record_error(message),
        }
    }
    fn sync_transcript(&mut self, cx: &mut Context<Self>) {
        self.restore_registered_assistant_page(cx);
        if self.runtime.is_native() && self.assistant.directory().is_none() {
            self.transcript
                .update(cx, |t, cx| t.sync(Vec::new(), self.locale, cx));
            return;
        }
        if self.assistant_group_visible() {
            self.sync_assistant_group_transcript(cx);
            return;
        }
        let presentations = self.state.agent_presentations();
        let mut rows = Vec::new();
        for m in self.state.messages() {
            let anchor = m.id.clone();
            rows.push(DisplayMessage {
                id: m.id,
                role: m.role,
                text: m.text,
                reasoning: m.reasoning,
                speaker: None,
            });
            for round in presentations
                .iter()
                .filter(|round| round.user_message_id == anchor)
            {
                if !round.text.is_empty() || !round.reasoning.is_empty() {
                    rows.push(DisplayMessage {
                        id: format!("agent-round-{}", round.round_id),
                        role: "assistant".into(),
                        text: round.text.clone(),
                        reasoning: round.reasoning.clone(),
                        speaker: None,
                    });
                }
            }
        }
        if let Some(agent) = self.state.agent_view() {
            if !agent.preview_text.is_empty() || !agent.preview_reasoning.is_empty() {
                rows.push(DisplayMessage {
                    id: format!(
                        "agent-preview-{}",
                        self.state.active_conversation_id().unwrap_or_default()
                    ),
                    role: "assistant".into(),
                    text: agent.preview_text,
                    reasoning: agent.preview_reasoning,
                    speaker: None,
                });
            }
        }
        self.transcript
            .update(cx, |transcript, cx| transcript.sync(rows, self.locale, cx));
    }
    fn update_placeholders(&mut self, cx: &mut Context<Self>) {
        if self.state.is_loaded() {
            let mode = self.state.preferences()["theme_mode"]
                .as_str()
                .unwrap_or("system");
            theme::set_mode(theme::ThemeMode::from_code(mode), cx);
        }
        if let Some(locale) = self.state.preferences()["locale"].as_str() {
            match locale {
                "zh-CN" => self.locale = Locale::Zh,
                "en-US" => self.locale = Locale::En,
                _ => {}
            }
        }
        self.composer.update(cx, |input, cx| {
            input.set_placeholder(self.composer_placeholder(), cx)
        });
        self.title_input.update(cx, |input, cx| {
            input.set_placeholder(self.locale.text(Text::Title), cx)
        });
    }
    fn commit(&mut self, command: Result<RuntimeCommand, String>, cx: &mut Context<Self>) {
        if self.assistant_writer_lease {
            self.restore_assistant_read_model(cx);
            return;
        }
        match command {
            Ok(c) => self.run(Reply::Persist, c, cx),
            Err(e) => {
                self.notice = Some(e);
                cx.notify();
            }
        }
    }
    fn create(&mut self, cx: &mut Context<Self>) {
        if self.preflight_inline_action(inline_composer::InlineAction::Create, cx) {
            return;
        }
        if self.defer_navigation(navigation_flow::NavigationAction::Create, cx) {
            return;
        }
        if !self.runtime.is_native() {
            self.page = Page::Chat;
            self.notice = None;
            self.model_picker = false;
            self.config_draft = None;
            self.config_page = model_picker::ConfigurationPage::Configure;
            self.rename_open = false;
            self.composer
                .update(cx, |input, cx| input.set_text(String::new(), cx));
            cx.notify();
            return;
        }
        if self.conversation_switch_blocked(true, cx) {
            return;
        }
        if !self.state.is_loaded() {
            self.conversation_workspace.intent = self
                .conversation_workspace
                .intent
                .or(Some(conversation_workspace::WorkspaceIntent::Create));
            self.bootstrap(cx);
            return;
        }
        if self.state.default_workspace().is_none() {
            let intent = self
                .conversation_workspace
                .intent
                .or(Some(conversation_workspace::WorkspaceIntent::Create));
            self.ensure_conversation_workspace(intent, cx);
            return;
        }
        let model = self
            .state
            .configured_default_model()
            .unwrap_or("")
            .to_owned();
        let command = self.state.create_conversation_from_draft(
            &uuid::Uuid::new_v4().to_string(),
            &now(),
            &model,
            "high",
        );
        if command.is_err() {
            self.send_after_create = false;
        }
        self.navigation_flow.creating = command.is_ok();
        self.page = Page::Chat;
        self.assistant.directory_ui.add_menu_open = false;
        self.clear_navigation_feedback();
        self.commit(command, cx);
    }
    fn send(&mut self, cx: &mut Context<Self>) {
        if self.navigation_flow.pending.is_some() {
            self.cancel_deferred_navigation(cx);
        }
        if self.runtime.is_native() && self.assistant.directory().is_none() {
            return;
        }
        if self.assistant_group_visible() {
            self.assistant_send_group(cx);
            return;
        }
        // The runner may currently own a different task conversation. A
        // personal-chat submit must not become that hidden task's answer.
        if self.page == Page::Assistant && !self.assistant_personal_chat_ready() {
            self.cancel_inline_send_intent();
            return;
        }
        if let Some(question) = self.state.agent_view().and_then(|view| view.question) {
            self.send_agent_answer(question.id, cx);
            return;
        }
        if self.assistant_writer_lease {
            return;
        }
        if self.preflight_inline_action(inline_composer::InlineAction::Send, cx) {
            return;
        }
        if self.model_picker || !self.runtime.is_native() || self.aux_busy {
            return;
        }
        if self.composer_drafts.saving {
            self.composer_drafts.send_after_save = Some((
                self.inline_conversation_key(),
                self.inline_text_for_send(cx),
            ));
            return;
        }
        if self.custom_providers.request_pending() || self.provider_models.request_pending() {
            self.cancel_inline_send_intent();
            self.navigation_flow.feedback = Some(
                assistant_copy::copy(
                    self.locale,
                    "Updating provider models. Your draft is kept.",
                    "正在更新服务商模型，草稿已保留。",
                )
                .into(),
            );
            cx.notify();
            return;
        }
        if self.loading || self.state.is_busy() {
            return;
        }
        let text = self.inline_text_for_send(cx);
        if text.trim().is_empty() {
            self.cancel_inline_send_intent();
            return;
        }
        if self.state.active_conversation_id().is_none() {
            self.send_after_create = true;
            self.create(cx);
            return;
        }
        if self.state.active_workspace_binding().is_none() {
            self.ensure_conversation_workspace(
                Some(conversation_workspace::WorkspaceIntent::Send),
                cx,
            );
            return;
        }
        if self.conversation_workspace.descriptor.is_none() {
            self.conversation_workspace.intent =
                Some(conversation_workspace::WorkspaceIntent::Send);
            self.resolve_active_workspace(cx);
            return;
        }
        if !self.state.model_is_configured(self.state.selected_model()) {
            self.cancel_inline_send_intent();
            self.choose_configured_model(cx);
            return;
        }
        let command = self
            .state
            .prepare_agent_send(&text, &TurnIds::new(), &now());
        if command.is_ok() {
            self.inline_will_send(&text);
        } else {
            self.cancel_inline_send_intent();
        }
        self.commit(command, cx);
    }
    fn select(&mut self, id: String, cx: &mut Context<Self>) {
        if self.preflight_inline_action(inline_composer::InlineAction::Select(id.clone()), cx) {
            return;
        }
        if self.defer_navigation(navigation_flow::NavigationAction::Select(id.clone()), cx) {
            return;
        }
        if self.state.active_conversation_id() == Some(&id) {
            self.page = self.page_for_conversation(&id);
            self.workspace_focus = false;
            cx.notify();
            return;
        }
        if self.conversation_switch_blocked(true, cx) {
            return;
        }
        let command = self.state.select_conversation(&id);
        self.page = self.page_for_conversation(&id);
        self.commit(command, cx);
    }
    fn save_title(&mut self, cx: &mut Context<Self>) {
        if self.loading || self.state.is_busy() {
            return;
        }
        let Some(id) = self.state.active_conversation_id().map(str::to_owned) else {
            return;
        };
        let title = self.title_input.read(cx).text();
        let command = self.state.rename_conversation(&id, &title);
        self.rename_open = false;
        self.commit(command, cx);
    }
    fn begin_rename(&mut self, cx: &mut Context<Self>) {
        let Some(chat) = self
            .state
            .conversations()
            .into_iter()
            .find(|c| Some(c.id.as_str()) == self.state.active_conversation_id())
        else {
            return;
        };
        self.title_input
            .update(cx, |input, cx| input.set_text(chat.title.clone(), cx));
        #[cfg(any(target_os = "ios", target_os = "android"))]
        self.run(
            Reply::Rename,
            name_prompt::command(
                name_prompt::NameKind::Conversation,
                &chat.title,
                self.locale,
                cx,
            ),
            cx,
        );
        #[cfg(not(any(target_os = "ios", target_os = "android")))]
        {
            self.rename_open = true;
            cx.notify();
        }
    }
    fn navigate(&mut self, page: Page, cx: &mut Context<Self>) {
        if page != Page::Assistant {
            self.cancel_deferred_navigation(cx);
        }
        if page == Page::Assistant && self.page != Page::Assistant && !self.assistant_writer_lease {
            if self.preflight_inline_action(inline_composer::InlineAction::Assistant, cx) {
                return;
            }
            if self.defer_navigation(navigation_flow::NavigationAction::Assistant, cx) {
                return;
            }
            self.assistant_chat_ensure_revision = None;
        }
        if matches!(page, Page::Files | Page::Git) {
            self.open_conversation_workspace(page, cx);
            return;
        }
        if page == Page::Settings && self.page != Page::Settings {
            self.settings_return_page = self.page;
        }
        if page == Page::Assistant && self.page != Page::Assistant && self.page != Page::Settings {
            self.assistant.directory_ui.hub_open = true;
        }
        self.page = page;
        if page == Page::Chat {
            self.workspace_focus = false;
        }
        self.model_picker = false;
        self.config_draft = None;
        self.config_page = model_picker::ConfigurationPage::Configure;
        self.rename_open = false;
        self.notice = None;
        if page == Page::Assistant {
            self.initialize_assistant(cx);
            self.enter_assistant_conversation(cx);
            self.assistant_command(crate::assistant_runtime::RunnerCommand::PollDue, cx);
            if self.runtime.is_native() && !self.browser.workspaces_loaded && !self.aux_busy {
                self.run(
                    Reply::Workspaces,
                    RuntimeCommand::new("LocalWorkspaces", "list", vec![]),
                    cx,
                );
            }
        }
        cx.notify();
    }
}

fn now() -> String {
    Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true)
}
