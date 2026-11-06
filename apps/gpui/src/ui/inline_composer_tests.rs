use super::*;
use gpui::{TestAppContext, px, size};
use rish_shell_core::{RuntimeCommand, ShellState};
const CHAT: &str = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const OTHER: &str = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
fn with_shell(test: impl FnOnce(&mut Shell, &mut Context<Shell>)) {
    let mut cx = TestAppContext::single();
    let window = cx.open_window(size(px(390.), px(844.)), |_, cx| Shell::new(cx));
    window
        .update(&mut cx, |shell, _, cx| {
            // Native editing never paints the desktop single-line TextInput.
            // Keep that unrelated desktop renderer out of these protocol tests.
            shell.page = crate::ui::Page::Settings;
            shell.inline_composer.visible = true;
            shell.inline_composer.viewport = [390., 844.];
            shell.inline_composer.scale = 3.;
            shell.inline_composer.rect = [20., 400., 350., 80.];
            shell.inline_composer.state.set_viewport_height(844.);
            shell.align_inline_session(false, cx);
            test(shell, cx);
        })
        .unwrap();
}
fn snapshot(shell: &Shell, revision: u64, text: &str) -> Value {
    json!({"session_id":shell.inline_composer.state.session_id().unwrap(),"status":"ready","revision":revision,"applied_text_revision":shell.inline_composer.state.text_revision(),"text":text,"composing":false,"focused":true,"keyboard_bottom":300.,"content_height":80.})
}
fn command_payload(shell: &Shell) -> Value {
    shell
        .inline_composer
        .state
        .sync_payload(
            InputGeometry::new(
                shell.inline_composer.rect,
                shell.inline_composer.viewport,
                3.,
            ),
            true,
            None,
            "light",
            "Message",
        )
        .unwrap()
}
fn commit(state: &mut ShellState, command: RuntimeCommand, generation: u64) {
    let raw = command.args[0]["candidate_json"].as_str().unwrap();
    state.accept_persist(json!({"status":"committed","snapshot":{"schema_version":1,"generation":generation,"session_sha256":rish_agent_core::session_schema::candidate_digest(raw.as_bytes()).unwrap()}})).unwrap();
}
fn install_chats(shell: &mut Shell) {
    shell.state = ShellState::with_test_models();
    shell
        .state
        .load_snapshot(json!({"schema_version":1,"status":"missing"}))
        .unwrap();
    shell.state.set_default_workspace(json!({"schema_version":2,"workspace_id":"845d980b-8acd-4710-a54c-7975b6839024","binding_revision":1,"display_name":"Default","status":"ok","capabilities":{"read":true,"write":true,"git":true}})).unwrap();
    for (index, id) in [OTHER, CHAT].into_iter().enumerate() {
        let c = shell
            .state
            .create_conversation(id, "2026-10-15T00:00:00.000Z", "deepseek-v4-flash")
            .unwrap();
        commit(&mut shell.state, c, (index + 1) as u64);
    }
}
fn action(shell: &Shell, kind: InlineAction) -> ActionRequest {
    ActionRequest {
        id: uuid::Uuid::new_v4().to_string(),
        action: kind,
        session: shell.inline_composer.state.session_id().unwrap().into(),
        text_revision: shell.inline_composer.state.text_revision(),
        conversation: shell.inline_conversation_key(),
    }
}
fn sent(shell: &Shell) -> SentDraft {
    SentDraft {
        session: shell.inline_composer.state.session_id().unwrap().into(),
        text_revision: shell.inline_composer.state.text_revision(),
        native_revision: shell.inline_composer.state.native_revision(),
        text: shell.inline_composer.state.text().into(),
    }
}

#[test]
fn native_typing_updates_entity_without_creating_an_external_replacement() {
    with_shell(|shell, cx| {
        let rev = shell.inline_composer.state.text_revision();
        shell
            .apply_inline_snapshot(&snapshot(shell, 2, "你好\n世界"), cx)
            .unwrap();
        assert_eq!(shell.composer.read(cx).text(), "你好\n世界");
        shell.align_inline_session(false, cx);
        assert_eq!(shell.inline_composer.state.text_revision(), rev);
    });
}

#[test]
fn entering_personal_chat_keeps_an_unsent_new_chat_draft_in_its_own_session() {
    with_shell(|shell, cx| {
        shell
            .apply_inline_snapshot(&snapshot(shell, 2, "普通对话的草稿"), cx)
            .unwrap();
        install_chats(shell);
        let store = rish_shell_core::assistant_store::AssistantSnapshot {
            conversation_id: Some(CHAT.into()),
            ..Default::default()
        };
        shell.state.bind_assistant_snapshot(&store);
        shell.assistant.snapshot.store = Some(store);
        shell.align_inline_session(true, cx);
        assert_eq!(
            shell.inline_composer.state.current_conversation_key(),
            Some(CHAT)
        );
        assert!(shell.composer.read(cx).text().is_empty());
        assert_eq!(
            shell.inline_composer.drafts["new-draft"].text,
            "普通对话的草稿"
        );
        let mut session = shell.state.raw_session().clone();
        session["active_conversation_id"] = Value::Null;
        let bytes = session.to_string();
        shell.state.load_snapshot(json!({"schema_version":1,"status":"present","session_json":bytes,
            "snapshot":{"schema_version":1,"generation":3,
            "session_sha256":rish_agent_core::session_schema::candidate_digest(bytes.as_bytes()).unwrap()}})).unwrap();
        shell.align_inline_session(true, cx);
        assert_eq!(shell.composer.read(cx).text(), "普通对话的草稿");
    });
}

#[test]
fn personal_chat_submit_cannot_answer_another_tasks_hidden_question() {
    with_shell(|shell, cx| {
        shell.state = crate::assistant_runtime::test_fixture::question();
        shell.assistant.snapshot.store =
            Some(rish_shell_core::assistant_store::AssistantSnapshot {
                conversation_id: Some(OTHER.into()),
                ..Default::default()
            });
        shell.page = crate::ui::Page::Assistant;
        shell.composer.update(cx, |input, cx| {
            input.set_text("给私人助手的草稿".into(), cx)
        });
        assert!(shell.state.query_pending_commit().is_none());
        shell.send(cx);
        assert!(shell.state.query_pending_commit().is_none());
        assert!(shell.state.agent_view().unwrap().question.is_some());
        assert_eq!(shell.composer.read(cx).text(), "给私人助手的草稿");
    });
}
#[test]
fn native_text_only_changes_do_not_trigger_a_layout_sync_or_reset_ime() {
    with_shell(|shell, cx| {
        let before = command_payload(shell);
        let mut v = snapshot(shell, 3, "拼音候选");
        v["composing"] = json!(true);
        shell.apply_inline_snapshot(&v, cx).unwrap();
        let after = command_payload(shell);
        assert_eq!(sync_key(&before), sync_key(&after));
        assert_ne!(before["text"], after["text"]);
        assert!(shell.inline_composer.state.composing());
    });
}
#[test]
fn late_native_text_cannot_overwrite_an_external_preset_even_before_render() {
    with_shell(|shell, cx| {
        let old = snapshot(shell, 8, "old native");
        shell
            .composer
            .update(cx, |input, cx| input.set_text("preset".into(), cx));
        assert_eq!(
            shell.apply_inline_snapshot(&old, cx),
            Ok(SnapshotAcceptance::StaleTextRevision)
        );
        assert_eq!(shell.composer.read(cx).text(), "preset");
        assert_eq!(shell.inline_composer.state.text(), "preset");
    });
}
#[test]
fn one_pending_sync_coalesces_later_geometry_without_occupying_aux_busy() {
    with_shell(|shell, cx| {
        shell.inline_composer.desired = Some(command_payload(shell));
        shell.pump_inline(cx);
        let first = shell.inline_composer.sync.clone().unwrap();
        shell.inline_composer.rect = [30., 440., 320., 110.];
        shell.inline_composer.desired = Some(command_payload(shell));
        shell.pump_inline(cx);
        assert_eq!(shell.inline_composer.sync.as_ref().unwrap().id, first.id);
        assert!(!shell.aux_busy);
        shell.accept_inline_sync(first, Ok(snapshot(shell, 1, "")), cx);
        shell.pump_inline(cx);
        let next = shell.inline_composer.sync.as_ref().unwrap();
        assert_eq!(next.payload["rect"], json!([30., 440., 320., 110.]));
        assert!(!shell.aux_busy);
    });
}
#[test]
fn ime_snapshot_blocks_send_without_synthesizing_a_message_or_clearing_draft() {
    with_shell(|shell, cx| {
        let request = action(shell, InlineAction::Send);
        shell.inline_composer.action = Some(request.clone());
        shell.inline_composer.action_inflight = true;
        let mut v = snapshot(shell, 2, "尚未确认");
        v["composing"] = json!(true);
        shell.accept_inline_action(request, Ok(v), cx);
        assert!(shell.state.messages().is_empty());
        assert_eq!(shell.composer.read(cx).text(), "尚未确认");
        assert!(shell.inline_composer.permit.is_none());
        assert!(shell.notice.is_some());
    });
}
#[test]
fn conditional_clear_failure_preserves_text_typed_after_send() {
    with_shell(|shell, cx| {
        shell
            .apply_inline_snapshot(&snapshot(shell, 2, "sent"), cx)
            .unwrap();
        let sent = sent(shell);
        let reserved = shell.inline_composer.state.reserve_text_revision().unwrap();
        shell.inline_composer.clear_inflight = true;
        let later = snapshot(shell, 3, "sent plus a new draft");
        shell.accept_inline_send_clear(
            sent,
            reserved,
            Ok(json!({"cleared":false,"snapshot":later})),
            cx,
        );
        assert_eq!(shell.composer.read(cx).text(), "sent plus a new draft");
        assert_eq!(shell.inline_composer.state.text(), "sent plus a new draft");
        assert!(!shell.inline_composer.clear_inflight);
    });
}
#[test]
fn native_atomic_clear_ack_is_the_only_event_that_removes_sent_text() {
    with_shell(|shell, cx| {
        shell
            .apply_inline_snapshot(&snapshot(shell, 2, "sent"), cx)
            .unwrap();
        let sent = sent(shell);
        let reserved = shell.inline_composer.state.reserve_text_revision().unwrap();
        assert_eq!(shell.composer.read(cx).text(), "sent");
        let mut cleared = snapshot(shell, 3, "");
        cleared["applied_text_revision"] = json!(reserved);
        shell.accept_inline_send_clear(
            sent,
            reserved,
            Ok(json!({"cleared":true,"snapshot":cleared})),
            cx,
        );
        assert!(shell.composer.read(cx).text().is_empty());
        assert_eq!(shell.inline_composer.state.text_revision(), reserved);
    });
}
#[test]
fn preset_while_native_clear_is_inflight_wins_over_late_clear_ack() {
    with_shell(|shell, cx| {
        shell
            .apply_inline_snapshot(&snapshot(shell, 2, "sent"), cx)
            .unwrap();
        let sent = sent(shell);
        let reserved = shell.inline_composer.state.reserve_text_revision().unwrap();
        let mut ack = snapshot(shell, 3, "");
        ack["applied_text_revision"] = json!(reserved);
        shell
            .composer
            .update(cx, |input, cx| input.set_text("new preset".into(), cx));
        shell.accept_inline_send_clear(
            sent,
            reserved,
            Ok(json!({"cleared":true,"snapshot":ack})),
            cx,
        );
        assert_eq!(shell.composer.read(cx).text(), "new preset");
        assert!(shell.inline_composer.state.text_revision() > reserved);
    });
}
#[test]
fn late_old_conversation_text_is_kept_in_its_slot_and_never_written_to_new_entity() {
    with_shell(|shell, cx| {
        install_chats(shell);
        shell.align_inline_session(false, cx);
        shell
            .apply_inline_snapshot(&snapshot(shell, 2, ""), cx)
            .unwrap();
        let old = snapshot(shell, 3, "typed during selection CAS");
        let command = shell.state.select_conversation(OTHER).unwrap();
        commit(&mut shell.state, command, 3);
        shell.apply_inline_snapshot(&old, cx).unwrap();
        assert!(shell.composer.read(cx).text().is_empty());
        assert_eq!(
            shell.inline_composer.drafts[CHAT].text,
            "typed during selection CAS"
        );
        assert_eq!(
            shell.inline_composer.state.current_conversation_key(),
            Some(OTHER)
        );
        let command = shell.state.select_conversation(CHAT).unwrap();
        commit(&mut shell.state, command, 4);
        shell.align_inline_session(false, cx);
        assert_eq!(shell.composer.read(cx).text(), "typed during selection CAS");
    });
}
#[test]
fn old_session_closed_callback_cannot_disable_a_newer_live_editor() {
    with_shell(|shell, cx| {
        install_chats(shell);
        shell.align_inline_session(false, cx);
        let mut closed = snapshot(shell, 4, "old");
        closed["status"] = json!("closed");
        let command = shell.state.select_conversation(OTHER).unwrap();
        commit(&mut shell.state, command, 3);
        shell.align_inline_session(false, cx);
        let current = shell.inline_composer.state.session_id().unwrap().to_owned();
        shell.inline_composer.native_session = Some(current.clone());
        shell.apply_inline_snapshot(&closed, cx).unwrap();
        assert_eq!(shell.inline_composer.native_session, Some(current));
        assert!(!shell.inline_composer.state.is_closed());
    });
}
#[test]
fn first_conversation_adopts_live_unsaved_editor_without_losing_ime_or_uuid() {
    with_shell(|shell, cx| {
        let session = shell.inline_composer.state.session_id().unwrap().to_owned();
        let mut composing = snapshot(shell, 2, "创建中输入");
        composing["composing"] = json!(true);
        shell.apply_inline_snapshot(&composing, cx).unwrap();
        install_chats(shell);
        shell.align_inline_session(false, cx);
        assert_eq!(
            shell.inline_composer.state.session_id(),
            Some(session.as_str())
        );
        assert_eq!(shell.composer.read(cx).text(), "创建中输入");
        assert!(shell.inline_composer.state.composing());
    });
}
#[test]
fn stale_action_callback_cannot_consume_a_newer_preflight_request() {
    with_shell(|shell, cx| {
        let old = action(shell, InlineAction::Send);
        let new = action(shell, InlineAction::Select(OTHER.into()));
        shell.inline_composer.action = Some(new.clone());
        shell.inline_composer.action_inflight = true;
        shell.accept_inline_action(old, Ok(snapshot(shell, 2, "old")), cx);
        assert_eq!(shell.inline_composer.action.as_ref().unwrap().id, new.id);
        assert!(shell.inline_composer.action_inflight);
        assert!(shell.composer.read(cx).text().is_empty());
    });
}
#[test]
fn invalid_sync_reply_is_latched_instead_of_spinning_native_requests_each_frame() {
    with_shell(|shell, cx| {
        let payload = command_payload(shell);
        let request = SyncRequest {
            id: "sync".into(),
            key: sync_key(&payload),
            payload: payload.clone(),
            foreground_epoch: shell.inline_composer.foreground_epoch,
        };
        shell.inline_composer.desired = Some(payload);
        shell.inline_composer.sync = Some(request.clone());
        shell.accept_inline_sync(request, Ok(json!({"invalid":true})), cx);
        assert!(shell.inline_composer.sync.is_none());
        shell.pump_inline(cx);
        assert!(shell.inline_composer.sync.is_none());
        assert!(shell.inline_composer.failed_key.is_some());
    });
}

#[test]
fn foreground_retry_preserves_acknowledged_draft_and_inflight_actions() {
    with_shell(|shell, cx| {
        shell
            .apply_inline_snapshot(&snapshot(shell, 7, "中文输入\n第二行"), cx)
            .unwrap();
        let session = shell.inline_composer.state.session_id().unwrap().to_owned();
        let revision = shell.inline_composer.state.text_revision();
        shell.inline_composer.failed_key = Some(sync_key(&command_payload(shell)));
        shell.inline_composer.clear_inflight = true;
        shell.inline_composer.action = Some(ActionRequest {
            id: "already-dispatched".into(),
            action: InlineAction::Send,
            session: session.clone(),
            text_revision: revision,
            conversation: shell.inline_conversation_key(),
        });
        shell.inline_composer.action_inflight = true;
        shell.resume_inline_after_foreground(cx);
        assert!(shell.inline_composer.failed_key.is_none());
        assert_eq!(
            shell.inline_composer.state.session_id(),
            Some(session.as_str())
        );
        assert_eq!(shell.inline_composer.state.text_revision(), revision);
        assert_eq!(shell.inline_composer.state.native_revision(), 7);
        assert_eq!(shell.composer.read(cx).text(), "中文输入\n第二行");
        assert!(shell.inline_composer.clear_inflight && shell.inline_composer.action_inflight);
        assert_eq!(
            shell.inline_composer.action.as_ref().unwrap().id,
            "already-dispatched"
        );
    });
}

#[test]
fn late_background_refusal_cannot_relatch_failure_after_foreground() {
    with_shell(|shell, cx| {
        shell
            .apply_inline_snapshot(&snapshot(shell, 4, "保留草稿"), cx)
            .unwrap();
        let payload = command_payload(shell);
        let request = SyncRequest {
            id: "pre-resume".into(),
            key: sync_key(&payload),
            payload,
            foreground_epoch: shell.inline_composer.foreground_epoch,
        };
        shell.inline_composer.sync = Some(request.clone());
        shell.resume_inline_after_foreground(cx);
        shell.accept_inline_sync(request, Err("E_INLINE_COMPOSER_UNAVAILABLE".into()), cx);
        assert!(shell.inline_composer.failed_key.is_none());
        assert_eq!(shell.composer.read(cx).text(), "保留草稿");
        assert!(shell.inline_composer.action.is_none());
        assert!(shell.inline_composer.sent.is_none());
    });
}
#[test]
fn background_close_with_stale_text_ack_preserves_new_preset_for_next_uuid() {
    with_shell(|shell, cx| {
        let mut closed = snapshot(shell, 4, "old");
        closed["status"] = json!("closed");
        shell
            .composer
            .update(cx, |input, cx| input.set_text("new preset".into(), cx));
        let old = shell.inline_composer.state.session_id().unwrap().to_owned();
        shell.apply_inline_snapshot(&closed, cx).unwrap();
        assert!(shell.inline_composer.state.is_closed());
        assert_eq!(shell.composer.read(cx).text(), "new preset");
        shell.inline_composer.visible = false;
        shell.align_inline_session(false, cx);
        assert_eq!(shell.inline_composer.state.session_id(), Some(old.as_str()));
        shell.inline_composer.visible = true;
        shell.align_inline_session(false, cx);
        assert_ne!(shell.inline_composer.state.session_id(), Some(old.as_str()));
        assert_eq!(shell.composer.read(cx).text(), "new preset");
    });
}

#[test]
fn send_text_is_frozen_across_workspace_setup_while_later_native_typing_stays_draft() {
    with_shell(|shell, cx| {
        install_chats(shell);
        shell.align_inline_session(false, cx);
        let request = action(shell, InlineAction::Send);
        shell.inline_composer.action = Some(request.clone());
        shell.inline_composer.action_inflight = true;
        shell.accept_inline_action(request, Ok(snapshot(shell, 2, "clicked send")), cx);
        assert_eq!(
            shell.inline_composer.queued_send.as_deref(),
            Some("clicked send")
        );
        shell
            .apply_inline_snapshot(&snapshot(shell, 3, "clicked send plus later text"), cx)
            .unwrap();
        assert_eq!(shell.inline_text_for_send(cx), "clicked send");
        assert_eq!(
            shell.composer.read(cx).text(),
            "clicked send plus later text"
        );
        shell.cancel_inline_send_intent();
        assert_eq!(
            shell.inline_text_for_send(cx),
            "clicked send plus later text"
        );
    });
}

#[test]
fn duplicate_terminal_reply_cannot_erase_a_preset_entered_while_the_editor_is_closed() {
    with_shell(|shell, cx| {
        let mut closed = snapshot(shell, 2, "old draft");
        closed["status"] = json!("closed");
        shell.apply_inline_snapshot(&closed, cx).unwrap();
        shell.composer.update(cx, |input, cx| {
            input.set_text("preset after close".into(), cx)
        });
        assert_eq!(
            shell.apply_inline_snapshot(&closed, cx),
            Ok(SnapshotAcceptance::SessionClosed)
        );
        assert_eq!(shell.composer.read(cx).text(), "preset after close");
        shell.align_inline_session(true, cx);
        assert_eq!(shell.inline_composer.state.text(), "preset after close");
    });
}

#[test]
fn objc_numeric_boolean_wire_failure_does_not_claim_the_created_native_view_is_absent() {
    with_shell(|shell, cx| {
        shell.inline_composer.desired = Some(command_payload(shell));
        shell.pump_inline(cx);
        let request = shell.inline_composer.sync.clone().unwrap();
        let session = shell.inline_composer.state.session_id().unwrap().to_owned();
        let mut native_wire = snapshot(shell, 1, "");
        // Objective-C @(comparison) / @(logical expression) box C int, not BOOL.
        // Native may have attached the editor before this malformed ACK arrives.
        native_wire["composing"] = json!(0);
        native_wire["focused"] = json!(1);
        let wire: Value = serde_json::from_str(&native_wire.to_string()).unwrap();
        assert!(Snapshot::parse(&wire).is_err());
        shell.accept_inline_sync(request, Ok(wire), cx);
        assert!(shell.inline_composer.attached_session.is_none());
        assert_eq!(
            shell.inline_composer.attachment_unknown.as_deref(),
            Some(session.as_str())
        );
        assert!(shell.inline_composer.failed_key.is_some());
        assert!(
            !shell.inline_composer.fallback_visible(),
            "Do not paint a second placeholder over a native view that may exist"
        );
        // A later valid ACK restores both text synchronization and attachment
        // knowledge without replacing text already entered in that same editor.
        shell.inline_composer.failed_key = None;
        shell.pump_inline(cx);
        let retry = shell.inline_composer.sync.clone().unwrap();
        shell.accept_inline_sync(retry, Ok(snapshot(shell, 2, "native draft")), cx);
        assert_eq!(shell.composer.read(cx).text(), "native draft");
        assert_eq!(
            shell.inline_composer.attached_session.as_deref(),
            Some(session.as_str())
        );
        assert!(shell.inline_composer.attachment_unknown.is_none());
        assert!(!shell.inline_composer.fallback_visible());
    });
}
#[test]
fn only_a_matching_closed_snapshot_can_authorize_the_absent_editor_fallback() {
    with_shell(|shell, _cx| {
        let session = shell.inline_composer.state.session_id().unwrap().to_owned();
        shell.inline_composer.attachment_unknown = Some(session.clone());
        shell.inline_composer.failed_key = Some(json!({"failed":true}));
        let ready = Snapshot::parse(&snapshot(shell, 1, "")).unwrap();
        assert!(!shell.inline_composer.confirm_closed(&ready));
        assert!(!shell.inline_composer.fallback_visible());
        let mut foreign = ready.clone();
        foreign.status = SnapshotStatus::Closed;
        foreign.session_id = uuid::Uuid::new_v4().to_string();
        assert!(!shell.inline_composer.confirm_closed(&foreign));
        assert!(!shell.inline_composer.fallback_visible());
        let closed = Snapshot {
            status: SnapshotStatus::Closed,
            ..ready
        };
        assert!(shell.inline_composer.confirm_closed(&closed));
        assert!(shell.inline_composer.attachment_unknown.is_none());
        assert!(shell.inline_composer.fallback_visible());
    });
}

#[test]
fn late_create_input_snapshot_cannot_leave_settings_or_replace_the_kept_draft() {
    with_shell(|shell, cx| {
        install_chats(shell);
        shell.align_inline_session(true, cx);
        shell
            .apply_inline_snapshot(&snapshot(shell, 2, "未发送的原始草稿"), cx)
            .unwrap();
        shell.page = crate::ui::Page::Chat;
        let before = shell.state.raw_session().clone();
        let old = action(shell, InlineAction::Create);
        shell.inline_composer.action = Some(old.clone());
        shell.inline_composer.action_inflight = true;
        shell.navigate(crate::ui::Page::Settings, cx);
        assert!(shell.inline_composer.action.is_none());
        assert!(!shell.inline_composer.action_inflight);
        let stale = snapshot(shell, 3, "Old native callback must not replace the draft");
        shell.accept_inline_action(old, Ok(stale), cx);
        assert!(shell.page == crate::ui::Page::Settings);
        assert_eq!(shell.composer.read(cx).text(), "未发送的原始草稿");
        assert_eq!(shell.state.raw_session(), &before);
        assert!(!shell.state.is_busy());
    });
}

#[test]
fn cancelling_navigation_keeps_send_answer_and_workspace_binding_fences() {
    for kind in [
        InlineAction::Send,
        InlineAction::AnswerQuestion("pending-question".into()),
        InlineAction::Bind(json!({"workspace_id":"existing-workspace"})),
    ] {
        with_shell(|shell, cx| {
            let request = action(shell, kind.clone());
            shell.inline_composer.action = Some(request.clone());
            shell.inline_composer.action_inflight = true;
            shell.inline_composer.permit = Some(kind.clone());
            shell.cancel_deferred_navigation(cx);
            assert_eq!(
                shell.inline_composer.action.as_ref().map(|r| &r.id),
                Some(&request.id)
            );
            assert!(shell.inline_composer.action_inflight);
            assert_eq!(shell.inline_composer.permit, Some(kind));
        });
    }
}
