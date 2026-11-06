use super::*;

fn chooser(fixture: &mut Fixture) -> &'static str {
    if fixture
        .cx
        .debug_bounds("workspace-panel-workspace")
        .is_some()
    {
        "workspace-panel-workspace"
    } else {
        "conversation-workspace"
    }
}

fn choices(shell: &Shell) -> Vec<Value> {
    (0..16)
        .map(|index| {
            let mut descriptor = shell.state.default_workspace().unwrap().clone();
            descriptor["workspace_id"] = json!(format!("845d980b-8acd-4710-a54c-{index:012}"));
            descriptor["display_name"] = json!(format!("Workspace {index}"));
            descriptor
        })
        .collect()
}

fn commit_at_generation(state: &mut ShellState, command: RuntimeCommand, generation: u64) {
    let raw = command.args[0]["candidate_json"].as_str().unwrap();
    let digest = rish_agent_core::session_schema::candidate_digest(raw.as_bytes()).unwrap();
    state
        .accept_persist(json!({"schema_version":1,"status":"committed", "snapshot":{
            "schema_version":1,"generation":generation,"session_sha256":digest
        }}))
        .unwrap();
}

#[test]
fn chooser_starts_at_visible_first_choice_after_document_scroll_with_unsent_text() {
    for width in [393., 1194.] {
        let mut fixture = Fixture::new(width, 852., Page::Files, Locale::Zh);
        fixture.update(|shell, _, cx| {
            shell
                .composer
                .update(cx, |input, cx| input.set_text("测试后看看余额".into(), cx));
            shell.browser.file.as_mut().unwrap().content = "// A long document\n".repeat(200);
            shell.browser.workspaces = choices(shell);
            shell.browser.workspaces_loaded = true;
            shell
                .workspace_panel_files_scroll
                .set_offset(point(px(0.), px(-300.)));
            cx.notify();
        });
        let session = fixture.read(|shell, _| shell.state.raw_session().clone());
        let selector = chooser(&mut fixture);
        fixture.click(selector);
        let body = fixture.bounds("workspace-content");
        let first = fixture.bounds("workspace-choice-0");
        assert!(
            first.top() >= body.top() && first.bottom() <= body.bottom(),
            "first choice must be visible after opening: first={first:?}, body={body:?}"
        );
        fixture.update(|shell, _, cx| {
            shell.aux_busy = true;
            let mut refreshed = choices(shell);
            refreshed[0]["display_name"] = json!("Refreshed workspace");
            shell.accept(
                Reply::Workspaces,
                Ok(json!({
                    "schema_version":1,"workspaces":refreshed
                })),
                cx,
            );
        });
        let first = fixture.bounds("workspace-choice-0");
        assert!(
            fixture
                .bounds("workspace-content")
                .contains(&first.center())
        );
        fixture.read(|shell, cx| {
            assert!(shell.conversation_workspace.selector);
            assert!(shell.browser.root.is_none());
            assert_eq!(
                shell.browser.workspaces[0]["display_name"],
                "Refreshed workspace"
            );
            assert_eq!(shell.composer.read(cx).text(), "测试后看看余额");
            assert_eq!(shell.state.raw_session(), &session);
        });
    }
}

#[test]
fn chooser_cancel_toggle_and_close_preserve_draft_binding_and_document_scroll() {
    for width in [393., 1194.] {
        let mut fixture = Fixture::new(width, 852., Page::Files, Locale::Zh);
        fixture.update(|shell, _, cx| {
            shell
                .composer
                .update(cx, |input, cx| input.set_text("测试后看看余额".into(), cx));
            shell.browser.file.as_mut().unwrap().content = "// Long document\n".repeat(200);
            shell
                .workspace_panel_files_scroll
                .set_offset(point(px(0.), px(-200.)));
            cx.notify();
        });
        let session = fixture.read(|shell, _| shell.state.raw_session().clone());
        let root = fixture.read(|shell, _| shell.browser.root.clone());
        let scroll = fixture.read(|shell, _| shell.workspace_panel_files_scroll.offset());
        let selector = chooser(&mut fixture);
        fixture.click(selector);
        fixture.update(|shell, _, cx| {
            shell.aux_busy = true;
            cx.notify();
        });
        fixture.click("cancel-workspace-selection");
        fixture.read(|shell, cx| {
            assert!(!shell.conversation_workspace.selector);
            assert!(
                shell.aux_busy,
                "cancel must leave the pending listing request intact"
            );
            assert_eq!(shell.browser.root, root);
            assert_eq!(shell.workspace_panel_files_scroll.offset(), scroll);
            assert_eq!(shell.composer.read(cx).text(), "测试后看看余额");
            assert_eq!(shell.state.raw_session(), &session);
        });
        fixture.update(|shell, _, cx| {
            let refreshed = choices(shell);
            shell.accept(
                Reply::Workspaces,
                Ok(json!({"schema_version":1,"workspaces":refreshed})),
                cx,
            );
        });
        assert_eq!(fixture.read(|shell, _| shell.browser.root.clone()), root);
        fixture.click(selector);
        fixture.click(selector);
        assert!(!fixture.read(|shell, _| shell.conversation_workspace.selector));
        assert!(fixture.cx.debug_bounds("workspace-choices").is_none());
        fixture.click(selector);
        fixture.click("workspace-panel-close");
        fixture.read(|shell, cx| {
            assert!(!shell.conversation_workspace.selector);
            assert_eq!(shell.browser.root, root);
            assert_eq!(shell.composer.read(cx).text(), "测试后看看余额");
            assert_eq!(shell.state.raw_session(), &session);
        });
    }
}

#[test]
fn chooser_busy_and_unavailable_errors_are_visible_inside_the_panel() {
    for width in [393., 1194.] {
        let mut fixture = Fixture::new(width, 852., Page::Files, Locale::Zh);
        let selector = chooser(&mut fixture);
        fixture.update(|shell, _, cx| {
            shell.aux_busy = true;
            cx.notify();
        });
        fixture.click(selector);
        let notice = fixture.bounds("workspace-panel-notice");
        assert!(fixture.viewport().contains(&notice.center()));
        fixture.read(|shell, _| {
            assert!(!shell.conversation_workspace.selector);
            assert_eq!(
                shell.notice.as_deref(),
                Some(shell.locale.text(Text::FinishWorkspaceOperation))
            );
        });
        fixture.update(|shell, _, cx| {
            shell.aux_busy = false;
            shell.notice = None;
            shell.browser.workspaces = choices(shell);
            shell.browser.workspaces[0]["capabilities"]["read"] = json!(false);
            cx.notify();
        });
        let session = fixture.read(|shell, _| shell.state.raw_session().clone());
        fixture.click(selector);
        let unavailable = fixture.bounds("workspace-choice-unavailable-0");
        assert!(
            fixture
                .bounds("workspace-content")
                .contains(&unavailable.center())
        );
        fixture.click("workspace-choice-0");
        fixture.bounds("workspace-panel-notice");
        fixture.read(|shell, _| {
            assert_eq!(shell.state.raw_session(), &session);
            assert!(shell.conversation_workspace.selector);
            assert_eq!(
                shell.notice.as_deref(),
                Some(shell.locale.text(Text::ConversationWorkspaceUnavailable))
            );
        });
    }
}

#[test]
fn sent_conversation_shows_lock_reason_and_rejects_rebinding_from_visible_choice() {
    for width in [393., 1194.] {
        let mut fixture = Fixture::new(width, 852., Page::Files, Locale::Zh);
        fixture.update(|shell, _, cx| {
            let command = shell
                .state
                .prepare_send(
                    "Already sent",
                    &rish_shell_core::TurnIds::new(),
                    "2026-10-15T01:00:00.000Z",
                )
                .unwrap();
            commit_at_generation(&mut shell.state, command, 2);
            let command = shell
                .state
                .fail_send("E_TEST", "2026-10-15T01:00:01.000Z")
                .unwrap();
            commit_at_generation(&mut shell.state, command, 3);
            shell.browser.workspaces = choices(shell);
            cx.notify();
        });
        let session = fixture.read(|shell, _| shell.state.raw_session().clone());
        let selector = chooser(&mut fixture);
        fixture.click(selector);
        fixture.bounds("workspace-panel-notice");
        fixture.click("workspace-choice-0");
        fixture.read(|shell, _| {
            assert_eq!(shell.state.raw_session(), &session);
            assert!(shell.conversation_workspace.selector);
            assert_eq!(
                shell.notice.as_deref(),
                Some(shell.locale.text(Text::ConversationWorkspaceLocked))
            );
        });
    }
}

#[test]
fn opening_chooser_immediately_shows_current_workspace_before_native_reply() {
    for width in [393., 1194.] {
        let mut fixture = Fixture::new(width, 852., Page::Files, Locale::Zh);
        let selector = chooser(&mut fixture);
        fixture.click(selector);
        fixture.bounds("workspace-choices");
        let first = fixture.bounds("workspace-choice-0");
        assert!(
            fixture
                .bounds("workspace-content")
                .contains(&first.center())
        );
    }
}

#[test]
fn closing_personal_workspace_returns_to_the_same_assistant_and_draft() {
    for width in [393., 1194.] {
        let mut fixture = Fixture::new(width, 852., Page::Files, Locale::Zh);
        fixture.update(|shell, _, cx| {
            shell.assistant.snapshot.store =
                Some(rish_shell_core::assistant_store::AssistantSnapshot {
                    conversation_id: shell.state.active_conversation_id().map(str::to_owned),
                    ..Default::default()
                });
            shell.bind_assistant_chat_snapshot();
            shell
                .composer
                .update(cx, |input, cx| input.set_text("测试后看看余额".into(), cx));
            cx.notify();
        });
        let session = fixture.read(|shell, _| shell.state.raw_session().clone());
        let selector = chooser(&mut fixture);
        fixture.click(selector);
        fixture.click("workspace-panel-close");
        fixture.bounds("assistant-page");
        fixture.read(|shell, cx| {
            assert!(shell.page == Page::Assistant);
            assert!(!shell.conversation_workspace.selector);
            assert_eq!(
                shell.state.active_conversation_id(),
                shell.state.assistant_conversation_id()
            );
            assert_eq!(shell.state.raw_session(), &session);
            assert_eq!(shell.composer.read(cx).text(), "测试后看看余额");
        });
    }
}
