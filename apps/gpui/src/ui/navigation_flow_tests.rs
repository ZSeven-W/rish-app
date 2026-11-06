//! User navigation waits for owned reads, preserves drafts, and never replays effects.
use super::navigation_flow::NavigationAction;
use super::*;
use crate::assistant_runtime::{RunnerSnapshot, test_fixture};
use gpui::{TestAppContext, VisualTestContext, WindowHandle, size};
use rish_shell_core::assistant_store::{AssistantProfile, AssistantSnapshot};

const OTHER: &str = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const DRAFT: &str = "测试后看看余额\n这条消息还没有发送";

struct Fixture {
    window: WindowHandle<Shell>,
    cx: VisualTestContext,
}
impl Fixture {
    fn new() -> Self {
        let mut app = TestAppContext::single();
        let window = app.open_window(size(px(390.), px(844.)), |_, cx| Shell::new(cx));
        let cx = VisualTestContext::from_window(window.into(), &app);
        let mut fixture = Self { window, cx };
        fixture.update(|s, cx| {
            s.locale = Locale::Zh;
            s.loading = false;
            s.state = test_fixture::loaded();
            s.page = Page::Assistant;
            s.assistant.directory_ui.hub_open = true;
            let store = AssistantSnapshot {
                conversation_id: Some(test_fixture::CHAT.into()),
                profile: AssistantProfile {
                    name: "Original Bot".into(),
                    ..Default::default()
                },
                ..Default::default()
            };
            s.assistant.snapshot = RunnerSnapshot {
                directory: Some(store.clone()),
                store: Some(store),
                ..Default::default()
            };
            s.bind_assistant_chat_snapshot();
            s.sync_conversation_workspace(cx);
            s.notice = None;
            s.composer
                .update(cx, |input, cx| input.set_text(DRAFT.into(), cx));
            s.test_align_inline_session(true, cx);
        });
        fixture.draw();
        fixture
    }
    fn update<R>(&mut self, f: impl FnOnce(&mut Shell, &mut Context<Shell>) -> R) -> R {
        self.window
            .update(&mut self.cx, |s, _, cx| f(s, cx))
            .unwrap()
    }
    fn draw(&mut self) {
        self.cx.run_until_parked();
        self.cx.update(|window, cx| window.draw(cx).clear(cx));
    }
}

#[test]
fn restored_composer_draft_does_not_block_ordinary_chat_admission() {
    let mut f = Fixture::new();
    f.update(|s, cx| {
        let before = s.state.raw_session().clone();
        assert!(!s.defer_navigation(NavigationAction::Create, cx));
        assert!(s.navigation_flow.pending.is_none());
        assert!(s.navigation_flow.feedback.is_none());
        assert!(s.notice.is_none());
        assert_eq!(s.composer.read(cx).text(), DRAFT);
        assert_eq!(s.state.raw_session(), &before);
        // Publish the same native CAS boundary used by real creation. The old
        // Bot draft stays keyed to its conversation; a new chat begins empty.
        let create = s
            .state
            .create_conversation(OTHER, test_fixture::NOW, "deepseek-v4-flash")
            .unwrap();
        test_fixture::persist(&mut s.state, create);
        s.page = Page::Chat;
        s.test_align_inline_session(true, cx);
        assert!(s.composer.read(cx).text().is_empty());
        let select = s.state.select_conversation(test_fixture::CHAT).unwrap();
        test_fixture::persist(&mut s.state, select);
        s.test_align_inline_session(true, cx);
        assert_eq!(s.composer.read(cx).text(), DRAFT);
    });
}

#[test]
fn owned_folder_read_finishes_then_deferred_create_runs_once() {
    let mut f = Fixture::new();
    let reply = f.update(|s, cx| {
        let reply = Reply::Files(s.browser.generation, "".into());
        s.browser_pending = browser_requests::BrowserReadRequest::from_reply(&reply);
        s.aux_busy = true;
        s.create(cx);
        assert!(s.navigation_flow.pending.is_some());
        assert!(s.page == Page::Assistant);
        assert_eq!(s.composer.read(cx).text(), DRAFT);
        assert!(s.notice.is_none());
        reply
    });
    f.update(|s, cx| {
        let root = s.browser.root.clone().unwrap();
        s.accept(
            reply,
            Ok(json!({"schema_version":1,"root":root,"path":"","entries":[]})),
            cx,
        );
    });
    f.draw();
    f.update(|s, cx| {
        assert!(s.page == Page::Chat);
        assert!(s.navigation_flow.pending.is_none());
        assert!(!s.aux_busy);
        assert!(s.notice.is_none());
        s.composer.update(cx, |input, cx| {
            input.set_text("After the first navigation".into(), cx)
        });
        s.resume_deferred_navigation(cx);
        s.resume_deferred_navigation(cx);
        assert_eq!(s.composer.read(cx).text(), "After the first navigation");
    });
}

#[test]
fn default_workspace_reply_cannot_revive_a_superseded_cold_create_or_send() {
    for old_intent in [
        conversation_workspace::WorkspaceIntent::Create,
        conversation_workspace::WorkspaceIntent::Send,
    ] {
        let mut f = Fixture::new();
        f.update(|s, cx| {
            s.state = ShellState::new();
            s.state
                .load_snapshot(json!({"schema_version":1,"status":"missing"}))
                .unwrap();
            s.page = Page::Chat;
            s.aux_busy = true;
            s.conversation_workspace.ensuring = true;
            s.conversation_workspace.intent = Some(old_intent);
            s.send_after_create = true;
            assert!(s.defer_navigation(NavigationAction::BotHub, cx));
            assert!(s.conversation_workspace.intent.is_none());
            assert!(!s.send_after_create);
            let descriptor = test_fixture::loaded().default_workspace().unwrap().clone();
            s.accept(Reply::DefaultWorkspace, Ok(descriptor), cx);
        });
        f.draw();
        f.update(|s, cx| {
            assert!(
                s.assistant_hub_visible(),
                "The most recent Bot request must win after ensureDefault"
            );
            assert!(s.navigation_flow.pending.is_none());
            assert!(
                s.state.conversations().is_empty(),
                "Superseded creation must not allocate a hidden conversation"
            );
            assert!(!s.state.is_busy());
            assert!(!s.state.has_agent_task());
            assert!(s.agent_requests.is_empty());
            assert_eq!(s.composer.read(cx).text(), DRAFT);
        });
    }
}

#[test]
fn provider_reload_callback_immediately_resumes_waiting_navigation() {
    let mut f = Fixture::new();
    f.update(|s, cx| {
        s.page = Page::Settings;
        s.test_begin_custom_provider_reload();
        assert!(s.custom_providers.request_pending());
        assert!(s.defer_navigation(NavigationAction::BotHub, cx));
        assert!(s.page == Page::Settings);
        s.test_complete_custom_provider_reload(
            json!({"schema_version":1,"revision":0,"providers":[]}),
            cx,
        );
    });
    // No clock advancement: the actual provider completion must schedule this.
    f.draw();
    f.update(|s, cx| {
        assert!(s.assistant_hub_visible());
        assert!(!s.custom_providers.request_pending());
        assert!(s.navigation_flow.pending.is_none());
        assert!(!s.state.is_busy());
        assert!(s.agent_requests.is_empty());
        assert_eq!(s.composer.read(cx).text(), DRAFT);
    });
}

#[test]
fn queued_navigation_and_creating_keep_the_session_writer_out_of_due_task_handoff() {
    for guard in ["queued_navigation", "creating", "selecting_bot"] {
        let mut f = Fixture::new();
        let (handle, mut commands) =
            crate::assistant_runtime::RunnerHandle::test_client(RunnerSnapshot::default());
        f.update(|s, cx| {
            // Isolate the navigation guards from the independent unsaved-draft
            // writer barrier. A real CAS receipt preserves the fixture text.
            let save = s.state.persist_composer_drafts().unwrap().unwrap();
            test_fixture::persist(&mut s.state, save);
            s.assistant_runner = Some(handle);
            s.assistant.snapshot.foreground = true;
            s.assistant_handoff = Some("task-waiting-for-writer".into());
            match guard {
                "queued_navigation" => {
                    s.loading = true;
                    assert!(s.defer_navigation(NavigationAction::Create, cx));
                    s.loading = false;
                }
                "creating" => s.navigation_flow.creating = true,
                "selecting_bot" => s.assistant.directory_ui.pending_bot_id = Some("next-bot".into()),
                _ => unreachable!(),
            }
            s.try_assistant_handoff(cx);
            assert!(!s.assistant_writer_lease, "Due work stole the writer during {guard}");
            assert!(commands.try_recv().is_err());
            assert_eq!(s.composer.read(cx).text(), DRAFT);
            s.cancel_deferred_navigation(cx);
            s.navigation_flow.creating = false;
            s.assistant.directory_ui.pending_bot_id = None;
            s.try_assistant_handoff(cx);
            assert!(s.assistant_writer_lease, "The fixture must permit handoff after removing {guard}");
            assert!(matches!(commands.try_recv(), Ok(crate::assistant_runtime::RunnerCommand::Grant { task_id, .. }) if task_id == "task-waiting-for-writer"));
        });
    }
}

#[test]
fn unsaved_composer_draft_keeps_writer_until_its_native_receipt_arrives() {
    let mut f = Fixture::new();
    let (handle, mut commands) =
        crate::assistant_runtime::RunnerHandle::test_client(RunnerSnapshot::default());
    f.update(|s, cx| {
        s.assistant_runner = Some(handle);
        s.assistant.snapshot.foreground = true;
        s.assistant_handoff = Some("task-waiting-for-draft".into());
        s.try_assistant_handoff(cx);
        assert!(!s.assistant_writer_lease);
        assert!(commands.try_recv().is_err());
        let save = s.state.persist_composer_drafts().unwrap().unwrap();
        s.try_assistant_handoff(cx);
        assert!(!s.assistant_writer_lease, "A dispatched save is not a receipt");
        test_fixture::persist(&mut s.state, save);
        s.try_assistant_handoff(cx);
        assert!(s.assistant_writer_lease);
        assert!(matches!(commands.try_recv(), Ok(crate::assistant_runtime::RunnerCommand::Grant { state, .. }) if state.saved_composer_draft(test_fixture::CHAT) == DRAFT));
        assert_eq!(s.composer.read(cx).text(), DRAFT);
    });
}

#[test]
fn newest_waiting_navigation_wins_and_cancel_prevents_later_dispatch() {
    let mut f = Fixture::new();
    f.update(|s, cx| {
        s.loading = true;
        assert!(s.defer_navigation(NavigationAction::Create, cx));
        assert!(s.defer_navigation(NavigationAction::BotHub, cx));
        s.loading = false;
        s.page = Page::Chat;
        s.resume_deferred_navigation(cx);
        assert!(s.assistant_hub_visible());
        assert!(s.navigation_flow.pending.is_none());
        assert_eq!(
            s.composer.read(cx).text(),
            DRAFT,
            "Superseded creation must not clear the draft"
        );

        s.loading = true;
        assert!(s.defer_navigation(NavigationAction::Create, cx));
        s.cancel_deferred_navigation(cx);
        s.cancel_deferred_navigation(cx);
        s.loading = false;
        s.resume_deferred_navigation(cx);
        assert!(s.assistant_hub_visible());
        assert!(s.navigation_flow.pending.is_none());
        assert_eq!(s.composer.read(cx).text(), DRAFT);
    });
}

#[test]
fn stale_wait_timeout_cannot_expire_a_newer_intent_or_change_any_draft() {
    let mut f = Fixture::new();
    f.update(|s, cx| {
        s.loading = true;
        assert!(s.defer_navigation(NavigationAction::Create, cx));
    });
    f.draw();
    f.cx.executor()
        .advance_clock(std::time::Duration::from_secs(10));
    f.update(|s, cx| {
        assert!(s.defer_navigation(NavigationAction::BotHub, cx));
    });
    f.draw();
    f.cx.executor()
        .advance_clock(std::time::Duration::from_secs(5));
    f.draw();
    f.update(|s, cx| {
        assert!(matches!(
            s.navigation_flow.pending.as_ref().map(|p| &p.action),
            Some(NavigationAction::BotHub)
        ));
        assert_eq!(s.composer.read(cx).text(), DRAFT);
        assert!(s.notice.is_none());
    });
    f.cx.executor()
        .advance_clock(std::time::Duration::from_secs(10));
    f.draw();
    f.update(|s, cx| {
        assert!(s.navigation_flow.pending.is_none());
        assert!(
            s.navigation_flow
                .feedback
                .as_deref()
                .is_some_and(|message| message.contains("草稿已保留"))
        );
        assert!(s.notice.is_none());
        assert_eq!(s.composer.read(cx).text(), DRAFT);
        s.loading = false;
        s.page = Page::Settings;
        s.resume_deferred_navigation(cx);
        assert!(
            s.page == Page::Settings,
            "An expired request must not navigate later"
        );
    });
}

#[test]
fn repeated_create_during_its_own_pending_save_does_not_queue_an_extra_chat() {
    let mut f = Fixture::new();
    f.update(|s, cx| {
        s.navigation_flow.creating = true;
        s.loading = true;
        assert!(s.defer_navigation(NavigationAction::Select(OTHER.into()), cx));
        assert!(s.navigation_flow.pending.is_some());
        assert!(s.defer_navigation(NavigationAction::Create, cx));
        assert!(s.defer_navigation(NavigationAction::Create, cx));
        assert!(s.navigation_flow.pending.is_none());
        assert_eq!(s.composer.read(cx).text(), DRAFT);
        assert!(s.notice.is_none());
        s.loading = false;
        s.resume_deferred_navigation(cx);
        assert!(!s.navigation_flow.creating);
        assert!(s.navigation_flow.feedback.is_none());
        assert!(s.page == Page::Assistant);
    });
}

#[test]
fn mutations_file_drafts_writer_and_native_forms_never_queue_navigation() {
    for boundary in [
        "writer",
        "agent",
        "conflict",
        "file_draft",
        "native_form",
        "git_write",
    ] {
        let mut f = Fixture::new();
        f.update(|s, cx| {
            match boundary {
                "writer" => s.assistant_writer_lease = true,
                "agent" => {
                    let _ = s
                        .state
                        .prepare_agent_send(
                            "Do not switch this running Agent",
                            &TurnIds::new(),
                            test_fixture::NOW,
                        )
                        .unwrap();
                    assert!(s.state.has_agent_task());
                }
                "conflict" => {
                    let prepare = s
                        .state
                        .prepare_send(
                            "Preserve unresolved result",
                            &TurnIds::new(),
                            test_fixture::NOW,
                        )
                        .unwrap();
                    test_fixture::persist(&mut s.state, prepare);
                    s.state.fail_send("E_TEST", test_fixture::NOW).unwrap();
                    assert!(
                        s.state
                            .accept_persist(json!({"schema_version":1,"status":"conflict"}))
                            .is_err()
                    );
                    assert!(s.state.pending_conflict().is_some());
                }
                "file_draft" => {
                    s.browser.edit.draft = Some(workspace_edit::FileDraft {
                        target: workspace_edit::EditTarget {
                            root: s.browser.root.clone().unwrap(),
                            path: "notes.md".into(),
                            folder: "".into(),
                            generation: s.browser.generation,
                        },
                        content: "Unsaved file".into(),
                        expected_revision: Some("a".repeat(64)),
                        create_only: false,
                        failed: false,
                    });
                }
                "native_form" => s.native_form_active = true,
                "git_write" => {
                    s.aux_busy = true;
                    s.browser.git_actions.pending = Some(git_operations::GitActionRequest {
                        generation: s.browser.generation,
                        root: s.browser.root.clone().unwrap(),
                        action: git_operations::GitAction::Commit,
                        step: git_operations::GitStep::Commit,
                        id: uuid::Uuid::new_v4().to_string(),
                        head: json!("a".repeat(40)),
                        branch: json!("main"),
                        host: Value::Null,
                        origin: Value::Null,
                        fields: json!({"message":"Existing commit"}),
                        receipts: vec![],
                        acknowledged: false,
                    });
                }
                _ => unreachable!(),
            }
            let before = s.state.raw_session().clone();
            assert!(
                s.defer_navigation(NavigationAction::Create, cx),
                "{boundary}"
            );
            assert!(
                s.navigation_flow.pending.is_none(),
                "A hard boundary must not create a delayed mutation: {boundary}"
            );
            assert!(
                s.navigation_flow.feedback.is_some(),
                "Explain the concrete boundary: {boundary}"
            );
            assert!(
                s.notice.is_none(),
                "Do not show a misleading workspace error: {boundary}"
            );
            assert_eq!(s.state.raw_session(), &before);
            assert_eq!(s.composer.read(cx).text(), DRAFT);
        });
    }
}

#[test]
fn successful_bot_hub_navigation_clears_only_the_stale_generic_warning() {
    let mut f = Fixture::new();
    f.update(|s, cx| {
        s.page = Page::Chat;
        s.notice = Some(s.locale.text(Text::FinishWorkspaceOperation).into());
        s.assistant_open_hub(cx);
        assert!(s.assistant_hub_visible());
        assert!(s.notice.is_none());
        assert!(s.navigation_flow.feedback.is_none());
        assert_eq!(s.composer.read(cx).text(), DRAFT);
        s.notice = Some("E_PROVIDER_AUTH".into());
        s.clear_navigation_feedback();
        assert_eq!(
            s.notice.as_deref(),
            Some("E_PROVIDER_AUTH"),
            "Unrelated real failures must remain visible"
        );
    });
}

#[test]
fn cancelled_notice_dismisses_without_bootstrap_while_real_errors_keep_retry() {
    let mut f = Fixture::new();
    let before = f.update(|s, cx| {
        s.notice = Some(s.locale.text(Text::Cancelled).into());
        assert!(s.informational_notice());
        cx.notify();
        s.state.raw_session().clone()
    });
    f.draw();
    assert!(f.cx.debug_bounds("retry").is_none());
    let dismiss =
        f.cx.debug_bounds("dismiss-notice")
            .expect("informational dismissal");
    f.cx.simulate_click(dismiss.center(), gpui::Modifiers::none());
    f.draw();
    f.update(|s, cx| {
        assert!(s.notice.is_none());
        assert!(
            !s.loading,
            "Dismiss must not bootstrap or reload the session"
        );
        assert_eq!(s.state.raw_session(), &before);
        assert_eq!(s.composer.read(cx).text(), DRAFT);
        s.notice = Some("E_PROVIDER_AUTH".into());
        assert!(!s.informational_notice());
        cx.notify();
    });
    f.draw();
    assert!(
        f.cx.debug_bounds("retry").is_some(),
        "A real unresolved error keeps its recovery action"
    );
    assert!(f.cx.debug_bounds("dismiss-notice").is_none());
}

#[test]
fn restored_bot_identity_cannot_hijack_loading_or_new_chat_navigation() {
    for boundary in ["loading", "pending_cas", "queued_create"] {
        let mut f = Fixture::new();
        f.update(|s, cx| {
            s.page = Page::Chat;
            match boundary {
                "loading" => s.loading = true,
                "pending_cas" => {
                    s.state
                        .create_conversation(OTHER, test_fixture::NOW, "deepseek-v4-flash")
                        .unwrap();
                }
                "queued_create" => {
                    s.loading = true;
                    assert!(s.defer_navigation(NavigationAction::Create, cx));
                    s.loading = false;
                }
                _ => unreachable!(),
            }
            s.restore_registered_assistant_page(cx);
            assert!(s.page == Page::Chat, "Bot restoration hijacked {boundary}");
        });
    }
}
