use super::conversation_workspace::WorkspaceResolution;
use super::*;
use gpui::{TestAppContext, px, size};
use rish_shell_core::workspace_binding;
const A: &str = "845d980b-8acd-4710-a54c-7975b6839024";
const B: &str = "e8ab9203-333e-4eb4-82a1-6423e90dc042";
const CHAT: &str = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const CHAT2: &str = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const NOW: &str = "2026-10-15T01:00:00.000Z";
fn descriptor(id: &str) -> Value {
    json!({"schema_version":2,"workspace_id":id,"binding_revision":1,"display_name":id,"status":"ok","capabilities":{"read":true,"write":true,"git":true}})
}
fn commit(state: &mut ShellState, command: RuntimeCommand, generation: u64) {
    let raw = command.args[0]["candidate_json"].as_str().unwrap();
    state.accept_persist(json!({"status":"committed","snapshot":{"schema_version":1,"generation":generation,"session_sha256":rish_agent_core::session_schema::candidate_digest(raw.as_bytes()).unwrap()}})).unwrap();
}
fn with_shell(test: impl FnOnce(&mut Shell, &mut Context<Shell>)) {
    let mut cx = TestAppContext::single();
    let window = cx.open_window(size(px(390.), px(844.)), |_, cx| Shell::new(cx));
    window
        .update(&mut cx, |shell, _, cx| {
            shell.state = ShellState::with_test_models();
            shell
                .state
                .load_snapshot(json!({"schema_version":1,"status":"missing"}))
                .unwrap();
            shell.state.set_default_workspace(descriptor(A)).unwrap();
            let c = shell
                .state
                .create_conversation(CHAT, NOW, "deepseek-v4-flash")
                .unwrap();
            commit(&mut shell.state, c, 1);
            shell.sync_conversation_workspace(cx);
            test(shell, cx);
        })
        .unwrap();
}
#[test]
fn changing_conversation_clears_files_git_diff_and_git_browser_identity_after_commit() {
    with_shell(|shell, cx| {
        let old_generation = shell.browser.generation;
        shell.browser.entries = vec![json!({"path":"old.txt"})];
        shell.browser.path = "old".into();
        shell.browser.root.as_mut().unwrap()["project_id"] = json!(CHAT);
        shell.browser.git_actions.diff = Some(json!({"patch":"old diff"}));
        shell.workspace_focus = true;
        let command = shell
            .state
            .create_conversation(CHAT2, NOW, "deepseek-v4-flash")
            .unwrap();
        shell.sync_conversation_workspace(cx);
        assert_eq!(shell.browser.path, "old");
        commit(&mut shell.state, command, 2);
        shell.sync_conversation_workspace(cx);
        assert!(shell.browser.generation > old_generation);
        assert!(shell.browser.entries.is_empty());
        assert!(shell.browser.path.is_empty());
        assert!(shell.browser.git_actions.diff.is_none());
        assert!(shell.browser.root.as_ref().unwrap()["project_id"].is_null());
        assert!(!shell.workspace_focus);
    });
}
#[test]
fn failed_binding_cas_does_not_mount_the_requested_workspace() {
    with_shell(|shell, cx| {
        let root = shell.browser.root.clone();
        shell.state.bind_active_workspace(&descriptor(B)).unwrap();
        shell
            .state
            .accept_persist(json!({"status":"not_committed"}))
            .unwrap_err();
        shell.sync_conversation_workspace(cx);
        assert_eq!(shell.browser.root, root);
        assert_eq!(shell.conversation_workspace_name(), A);
    });
}
#[test]
fn stale_workspace_resolution_cannot_replace_a_new_conversation_or_clear_new_busy_state() {
    with_shell(|shell, cx| {
        let old = WorkspaceResolution {
            conversation_id: CHAT.into(),
            binding: workspace_binding(&descriptor(A)).unwrap(),
        };
        let newer = WorkspaceResolution {
            conversation_id: CHAT2.into(),
            binding: workspace_binding(&descriptor(B)).unwrap(),
        };
        shell.conversation_workspace.resolving = Some(newer.clone());
        shell.aux_busy = true;
        let before = shell.browser.root.clone();
        shell.accept_conversation_workspace(
            old,
            Ok(json!({"schema_version":1,"workspace":descriptor(A)})),
            cx,
        );
        assert_eq!(shell.conversation_workspace.resolving, Some(newer));
        assert!(shell.aux_busy);
        assert_eq!(shell.browser.root, before);
    });
}
#[test]
fn unavailable_bound_workspace_does_not_fall_back_to_the_default() {
    with_shell(|shell, cx| {
        let c = shell.state.bind_active_workspace(&descriptor(B)).unwrap();
        commit(&mut shell.state, c, 2);
        shell.sync_conversation_workspace(cx);
        shell.browser.root = None;
        let request = WorkspaceResolution {
            conversation_id: CHAT.into(),
            binding: workspace_binding(&descriptor(B)).unwrap(),
        };
        shell.conversation_workspace.resolving = Some(request.clone());
        shell.aux_busy = true;
        shell.accept_conversation_workspace(request, Err("E_WORKSPACE_NOT_FOUND".into()), cx);
        assert!(shell.browser.root.is_none());
        assert!(shell.conversation_workspace.descriptor.is_none());
        assert_eq!(
            shell.state.active_workspace_binding().unwrap()["workspace_id"],
            B
        );
        assert!(shell.notice.is_some());
        assert!(!shell.aux_busy);
    });
}
#[test]
fn selector_keeps_authoritative_conversation_binding_and_cancelling_restores_it() {
    with_shell(|shell, cx| {
        shell.choose_conversation_workspace(cx);
        assert!(shell.conversation_workspace.selector);
        assert!(shell.browser.root.is_none());
        assert_eq!(
            shell.state.active_workspace_binding().unwrap()["workspace_id"],
            A
        );
        shell.open_conversation_workspace(Page::Files, cx);
        assert_eq!(
            shell.browser.root,
            Some(workspace_binding(&descriptor(A)).unwrap())
        );
        assert!(!shell.conversation_workspace.selector);
    });
}
#[test]
fn unsent_text_is_preserved_while_switches_dispatch_or_wait_for_auxiliary_reads() {
    with_shell(|shell, cx| {
        let command = shell
            .state
            .create_conversation(CHAT2, NOW, "deepseek-v4-flash")
            .unwrap();
        commit(&mut shell.state, command, 2);
        let command = shell.state.select_conversation(CHAT).unwrap();
        commit(&mut shell.state, command, 3);
        shell
            .composer
            .update(cx, |i, cx| i.set_text("unsent".into(), cx));
        let before = shell.state.raw_session().clone();
        shell.select(CHAT2.into(), cx);
        // Native metadata CAS is pending; no message or draft is discarded.
        assert_eq!(shell.state.raw_session(), &before);
        assert!(shell.state.is_busy());
        assert!(shell.loading);
        assert_eq!(shell.composer.read(cx).text(), "unsent");
        assert!(shell.notice.is_none());
        assert!(shell.navigation_flow.pending.is_none());
    });
    with_shell(|shell, cx| {
        let command = shell
            .state
            .create_conversation(CHAT2, NOW, "deepseek-v4-flash")
            .unwrap();
        commit(&mut shell.state, command, 2);
        let command = shell.state.select_conversation(CHAT).unwrap();
        commit(&mut shell.state, command, 3);
        shell
            .composer
            .update(cx, |i, cx| i.set_text("unsent".into(), cx));
        let before = shell.state.raw_session().clone();
        shell.aux_busy = true;
        shell.select(CHAT2.into(), cx);
        assert!(!shell.state.is_busy());
        assert_eq!(shell.state.raw_session(), &before);
        assert!(
            matches!(shell.navigation_flow.pending.as_ref().map(|p| &p.action),
            Some(navigation_flow::NavigationAction::Select(id)) if id == CHAT2)
        );
        assert_eq!(shell.composer.read(cx).text(), "unsent");
        assert!(shell.notice.is_none());
        shell.aux_busy = false;
        shell.resume_deferred_navigation(cx);
        assert!(shell.state.is_busy());
        assert!(shell.navigation_flow.pending.is_none());
        assert_eq!(shell.composer.read(cx).text(), "unsent");
    });
}
#[test]
fn wrong_revision_resolution_never_mounts_a_different_root() {
    with_shell(|shell, cx| {
        let request = WorkspaceResolution {
            conversation_id: CHAT.into(),
            binding: workspace_binding(&descriptor(A)).unwrap(),
        };
        shell.conversation_workspace.resolving = Some(request.clone());
        shell.conversation_workspace.descriptor = None;
        shell.browser.root = None;
        let mut wrong = descriptor(A);
        wrong["binding_revision"] = json!(2);
        shell.accept_conversation_workspace(
            request,
            Ok(json!({"schema_version":1,"workspace":wrong})),
            cx,
        );
        assert!(shell.browser.root.is_none());
        assert!(shell.conversation_workspace.descriptor.is_none());
        assert!(shell.notice.is_some());
    });
}

#[test]
fn an_unresolved_inactive_legacy_conversation_does_not_block_the_active_workspace() {
    with_shell(|shell, cx| {
        let command = shell
            .state
            .create_conversation(CHAT2, NOW, "deepseek-v4-flash")
            .unwrap();
        commit(&mut shell.state, command, 2);
        let mut raw = shell.state.raw_session().clone();
        raw["conversations"][0]["workspace_binding"] = Value::Null;
        raw["conversations"][0]["workspace_bootstrap_state"] = json!("pending_registry_resolution");
        let bytes = raw.to_string();
        shell.state.load_snapshot(json!({"schema_version":1,"status":"present","session_json":bytes,"snapshot":{"schema_version":1,"generation":3,"session_sha256":rish_agent_core::session_schema::candidate_digest(bytes.as_bytes()).unwrap()}})).unwrap();
        shell.continue_workspace_lifecycle(cx);
        assert_eq!(
            shell.conversation_workspace.active_id.as_deref(),
            Some(CHAT2)
        );
        assert_eq!(
            shell.browser.root,
            Some(workspace_binding(&descriptor(A)).unwrap())
        );
        assert!(shell.notice.is_none());
        assert!(!shell.state.is_busy());
    });
}
#[test]
fn an_unsaved_file_draft_blocks_conversation_selection_and_keeps_its_original_target() {
    with_shell(|shell, cx| {
        let root = shell.browser.root.clone().unwrap();
        shell.browser.edit.draft = Some(workspace_edit::FileDraft {
            target: workspace_edit::EditTarget {
                root: root.clone(),
                path: "notes.md".into(),
                folder: String::new(),
                generation: shell.browser.generation,
            },
            content: "unsaved".into(),
            expected_revision: Some("a".repeat(64)),
            create_only: false,
            failed: true,
        });
        shell.select(CHAT2.into(), cx);
        assert_eq!(shell.state.active_conversation_id(), Some(CHAT));
        assert_eq!(shell.browser.edit.draft.as_ref().unwrap().target.root, root);
        assert_eq!(
            shell.browser.edit.draft.as_ref().unwrap().content,
            "unsaved"
        );
        assert!(!shell.state.is_busy());
        assert!(shell.notice.is_none());
        assert!(shell.navigation_flow.pending.is_none());
        assert!(
            shell
                .navigation_flow
                .feedback
                .as_deref()
                .is_some_and(
                    |message| message.contains("file changes") || message.contains("文件修改")
                )
        );
    });
}
