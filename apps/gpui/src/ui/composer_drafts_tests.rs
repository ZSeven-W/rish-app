use super::{tests::*, *};
use crate::ui::{composer_drafts::ComposerDrafts, i18n::Locale};
use rish_shell_core::{ShellState, TurnIds};

fn envelope(state: &ShellState, generation: u64) -> Value {
    let raw = state.raw_session().to_string();
    json!({"schema_version":1,"status":"present","session_json":raw,
        "snapshot":{"schema_version":1,"generation":generation,
        "session_sha256":rish_agent_core::session_schema::candidate_digest(raw.as_bytes()).unwrap()}})
}

#[test]
fn committed_empty_chat_and_existing_chat_drafts_restore_before_empty_input_can_wipe_them() {
    for existing in [false, true] {
        with_shell(|shell, cx| {
            if existing {
                install_chats(shell);
            } else {
                shell.state = ShellState::with_test_models();
                shell
                    .state
                    .load_snapshot(json!({"schema_version":1,"status":"missing"}))
                    .unwrap();
            }
            shell.align_inline_session(true, cx);
            shell
                .apply_inline_snapshot(&snapshot(shell, 2, "未发送\n20261106"), cx)
                .unwrap();
            let generation = if existing { 3 } else { 1 };
            let command = shell.state.persist_composer_drafts().unwrap().unwrap();
            commit(&mut shell.state, command, generation);
            let saved = envelope(&shell.state, generation);

            shell.inline_composer = InlineComposer::default();
            shell.composer_drafts = ComposerDrafts::default();
            shell
                .composer
                .update(cx, |input, cx| input.set_text(String::new(), cx));
            shell.state = ShellState::with_test_models();
            shell.state.load_snapshot(saved).unwrap();
            shell.align_inline_session(true, cx);
            assert_eq!(shell.composer.read(cx).text(), "未发送\n20261106");
            assert!(!shell.state.has_unsaved_composer_drafts());
            // A delayed observer notification from the initial empty widget
            // reads the hydrated entity, never an old captured empty string.
            shell.composer_text_changed(cx);
            assert_eq!(shell.inline_composer.state.text(), "未发送\n20261106");
            assert!(!shell.state.has_unsaved_composer_drafts());
        });
    }
}

#[test]
fn accepted_input_survives_switch_configuration_and_restart_in_separate_slots() {
    with_shell(|shell, cx| {
        install_chats(shell);
        shell.align_inline_session(true, cx);
        shell
            .apply_inline_snapshot(&snapshot(shell, 2, "A草稿"), cx)
            .unwrap();
        let command = shell.state.select_conversation(OTHER).unwrap();
        commit(&mut shell.state, command, 3);
        shell.align_inline_session(true, cx);
        assert!(shell.composer.read(cx).text().is_empty());
        shell
            .apply_inline_snapshot(&snapshot(shell, 2, "B草稿"), cx)
            .unwrap();
        let command = shell
            .state
            .set_chat_configuration("deepseek-v4-pro", "off")
            .unwrap();
        commit(&mut shell.state, command, 4);
        let command = shell.state.select_conversation(CHAT).unwrap();
        commit(&mut shell.state, command, 5);
        shell.align_inline_session(true, cx);
        assert_eq!(shell.composer.read(cx).text(), "A草稿");
        let mut restarted = ShellState::with_test_models();
        restarted.load_snapshot(envelope(&shell.state, 5)).unwrap();
        assert_eq!(restarted.composer_draft(CHAT), "A草稿");
        assert_eq!(restarted.composer_draft(OTHER), "B草稿");
        assert_eq!(
            restarted.raw_session()["conversations"][0]["thinking_mode"],
            "off"
        );
    });
}

#[test]
fn newer_native_typing_is_pending_after_older_save_receipt() {
    with_shell(|shell, cx| {
        install_chats(shell);
        shell.align_inline_session(true, cx);
        shell
            .apply_inline_snapshot(&snapshot(shell, 2, "first"), cx)
            .unwrap();
        let command = shell.state.persist_composer_drafts().unwrap().unwrap();
        shell
            .apply_inline_snapshot(&snapshot(shell, 3, "first plus newer"), cx)
            .unwrap();
        commit(&mut shell.state, command, 3);
        shell.align_inline_session(true, cx);
        assert_eq!(shell.state.saved_composer_draft(CHAT), "first");
        assert_eq!(shell.composer.read(cx).text(), "first plus newer");
        assert!(shell.state.has_unsaved_composer_drafts());
        assert!(shell.composer_draft_status().is_some());
    });
}

#[test]
fn failed_native_clear_cannot_resurrect_a_durably_sent_draft() {
    with_shell(|shell, cx| {
        install_chats(shell);
        shell.align_inline_session(true, cx);
        shell
            .apply_inline_snapshot(&snapshot(shell, 2, "sent"), cx)
            .unwrap();
        shell.inline_will_send("sent");
        let sent = sent(shell);
        let command = shell
            .state
            .prepare_send("sent", &TurnIds::new(), "2026-11-06T00:00:00.000Z")
            .unwrap();
        commit(&mut shell.state, command, 3);
        assert!(shell.state.saved_composer_draft(CHAT).is_empty());
        let reserved = shell.inline_composer.state.reserve_text_revision().unwrap();
        shell.accept_inline_send_clear(sent, reserved, Err("transport lost".into()), cx);
        shell.composer_text_changed(cx);
        // Selection/focus observations can increment the native revision with
        // unchanged text; that is not a new unsent draft.
        shell
            .apply_inline_snapshot(&snapshot(shell, 3, "sent"), cx)
            .unwrap();
        assert!(shell.state.composer_draft(CHAT).is_empty());
        assert!(!shell.state.has_unsaved_composer_drafts());
        assert_eq!(shell.composer.read(cx).text(), "sent");
        shell
            .apply_inline_snapshot(&snapshot(shell, 4, "new typing"), cx)
            .unwrap();
        assert_eq!(shell.state.composer_draft(CHAT), "new typing");
        assert!(shell.state.has_unsaved_composer_drafts());
    });
}

#[test]
fn writer_snapshots_and_return_keep_local_overlay_without_claiming_it_saved() {
    with_shell(|shell, cx| {
        install_chats(shell);
        shell.align_inline_session(true, cx);
        let authoritative = shell.state.clone();
        shell.assistant_writer_lease = true;
        shell
            .apply_inline_snapshot(&snapshot(shell, 2, "typed while task owns writer"), cx)
            .unwrap();
        shell.save_composer_drafts(cx);
        assert!(shell.state.query_pending_commit().is_none());
        for _ in 0..3 {
            shell.retain_composer_drafts(authoritative.clone(), cx);
            assert_eq!(
                shell.state.composer_draft(CHAT),
                "typed while task owns writer"
            );
            assert!(shell.state.saved_composer_draft(CHAT).is_empty());
        }
        for locale in [Locale::En, Locale::Zh] {
            shell.locale = locale;
            assert!(shell.composer_draft_status().is_some());
        }
        shell.assistant_writer_lease = false;
        shell.retain_composer_drafts(authoritative, cx);
        let command = shell.state.persist_composer_drafts().unwrap().unwrap();
        commit(&mut shell.state, command, 3);
        assert_eq!(
            shell.state.saved_composer_draft(CHAT),
            "typed while task owns writer"
        );
        assert!(shell.composer_draft_status().is_none());
    });
}

#[test]
fn unknown_native_save_keeps_text_transaction_and_visible_retry_feedback() {
    with_shell(|shell, cx| {
        install_chats(shell);
        shell.align_inline_session(true, cx);
        shell
            .apply_inline_snapshot(&snapshot(shell, 2, "retain on failure"), cx)
            .unwrap();
        shell.state.persist_composer_drafts().unwrap().unwrap();
        let query = shell.state.query_pending_commit().unwrap();
        shell.composer_drafts.saving = true;
        shell.accept(Reply::Persist, Err("lost reply".into()), cx);
        assert_eq!(shell.composer.read(cx).text(), "retain on failure");
        assert_eq!(shell.state.query_pending_commit().unwrap().args, query.args);
        assert!(shell.composer_drafts.error.is_some());
        assert!(!shell.composer_drafts.saving);
        assert!(shell.composer_draft_status().is_some());
    });
}

#[test]
fn configuration_creating_first_chat_adopts_the_live_draft_and_restart_restores_it() {
    with_shell(|shell, cx| {
        shell.state = ShellState::with_test_models();
        shell
            .state
            .load_snapshot(json!({"schema_version":1,"status":"missing"}))
            .unwrap();
        shell.state.set_default_workspace(json!({"schema_version":2,"workspace_id":"845d980b-8acd-4710-a54c-7975b6839024","binding_revision":1,"display_name":"Default","status":"ok","capabilities":{"read":true,"write":true,"git":true}})).unwrap();
        shell.align_inline_session(true, cx);
        shell
            .apply_inline_snapshot(&snapshot(shell, 2, "configuration draft"), cx)
            .unwrap();
        let draft = crate::ui::model_picker::ConfigurationDraft {
            model: "deepseek-v4-pro".into(),
            thinking: "off".into(),
            error: None,
        };
        let command = shell.prepare_configuration_commit(&draft).unwrap();
        commit(&mut shell.state, command, 1);
        shell.align_inline_session(true, cx);
        let id = shell.state.active_conversation_id().unwrap().to_owned();
        assert_eq!(shell.composer.read(cx).text(), "configuration draft");
        assert!(shell.state.composer_draft("new-draft").is_empty());
        let mut restarted = ShellState::with_test_models();
        restarted.load_snapshot(envelope(&shell.state, 1)).unwrap();
        assert_eq!(restarted.composer_draft(&id), "configuration draft");
        assert_eq!(restarted.selected_thinking(), "off");
    });
}

#[test]
fn authoritative_reload_refreshes_clean_input_but_keeps_dirty_input() {
    for dirty in [false, true] {
        with_shell(|shell, cx| {
            install_chats(shell);
            shell.align_inline_session(true, cx);
            shell
                .apply_inline_snapshot(&snapshot(shell, 2, "old saved"), cx)
                .unwrap();
            let command = shell.state.persist_composer_drafts().unwrap().unwrap();
            commit(&mut shell.state, command, 3);
            if dirty {
                shell
                    .apply_inline_snapshot(&snapshot(shell, 3, "local change"), cx)
                    .unwrap();
            }
            let mut remote = ShellState::with_test_models();
            remote.load_snapshot(envelope(&shell.state, 3)).unwrap();
            remote.stage_composer_draft(CHAT, "remote change").unwrap();
            let command = remote.persist_composer_drafts().unwrap().unwrap();
            commit(&mut remote, command, 4);
            shell.state.load_snapshot(envelope(&remote, 4)).unwrap();
            shell.composer_drafts.restoring_snapshot = true;
            shell.align_inline_session(true, cx);
            assert_eq!(
                shell.composer.read(cx).text(),
                if dirty {
                    "local change"
                } else {
                    "remote change"
                }
            );
            assert_eq!(shell.state.composer_draft_conflicts().is_empty(), !dirty);
            assert_eq!(
                shell.state.has_unsaved_composer_drafts(),
                dirty,
                "saved={:?}, chat={}, new={}",
                shell.state.raw_session()["composer_drafts"],
                shell.state.composer_draft(CHAT),
                shell.state.composer_draft("new-draft")
            );
        });
    }
}

#[test]
fn actor_receipt_consumes_only_its_exact_local_submission_overlay() {
    for newer in [false, true] {
        with_shell(|shell, cx| {
            install_chats(shell);
            shell.align_inline_session(true, cx);
            let returned = shell.state.clone();
            shell
                .apply_inline_snapshot(&snapshot(shell, 2, "submitted answer"), cx)
                .unwrap();
            shell.inline_will_send("submitted answer");
            if newer {
                shell
                    .apply_inline_snapshot(&snapshot(shell, 3, "next answer"), cx)
                    .unwrap();
            }
            shell.acknowledge_actor_sent_draft();
            shell.retain_composer_drafts(returned, cx);
            shell.align_inline_session(true, cx);
            assert_eq!(
                shell.state.composer_draft(CHAT),
                if newer { "next answer" } else { "" }
            );
            // Until native conditional clear confirms, its old editor remains
            // visible but must not be staged again into the session.
            assert_eq!(
                shell.composer.read(cx).text(),
                if newer {
                    "next answer"
                } else {
                    "submitted answer"
                }
            );
            shell.composer_text_changed(cx);
            assert_eq!(
                shell.state.composer_draft(CHAT),
                if newer { "next answer" } else { "" }
            );
        });
    }
}

#[test]
fn group_drafts_remain_in_memory_and_are_explicitly_not_session_persisted() {
    with_shell(|shell, cx| {
        install_chats(shell);
        shell.align_inline_session(true, cx);
        shell.page = crate::ui::Page::Assistant;
        shell.assistant.directory_ui.hub_open = false;
        shell.assistant.directory_ui.group_id = Some("room-1".into());
        shell.align_inline_session(true, cx);
        shell
            .apply_inline_snapshot(&snapshot(shell, 2, "room draft"), cx)
            .unwrap();
        assert!(!shell.state.has_unsaved_composer_drafts());
        assert!(
            shell
                .state
                .composer_draft("assistant-group-room-1")
                .is_empty()
        );
        assert!(shell.composer_draft_status().is_some());
        shell.page = crate::ui::Page::Chat;
        shell.align_inline_session(true, cx);
        shell.page = crate::ui::Page::Assistant;
        shell.align_inline_session(true, cx);
        assert_eq!(shell.composer.read(cx).text(), "room draft");
    });
}

#[test]
fn refused_fallback_input_cannot_silently_leave_the_visible_editor() {
    with_shell(|shell, cx| {
        install_chats(shell);
        shell.align_inline_session(true, cx);
        let text = "x".repeat(1024 * 1024 + 1);
        shell
            .composer
            .update(cx, |input, cx| input.set_text(text.clone(), cx));
        shell.composer_text_changed(cx);
        assert!(shell.composer_drafts.rejected_text);
        assert!(shell.navigation_block_reason().is_some());
        assert_eq!(shell.composer.read(cx).text(), text);
        shell
            .composer
            .update(cx, |input, cx| input.set_text("shortened".into(), cx));
        shell.composer_text_changed(cx);
        assert!(!shell.composer_drafts.rejected_text);
        assert!(shell.navigation_block_reason().is_none());
        assert_eq!(shell.state.composer_draft(CHAT), "shortened");
    });
}

#[test]
fn aggregate_limit_refused_text_survives_switching_away_and_back() {
    with_shell(|shell, cx| {
        install_chats(shell);
        shell.align_inline_session(true, cx);
        for key in ["full-1", "full-2", "full-3", "full-4"] {
            shell
                .state
                .stage_composer_draft(key, &"x".repeat(1024 * 1024))
                .unwrap();
        }
        let command = shell.state.persist_composer_drafts().unwrap().unwrap();
        commit(&mut shell.state, command, 3);
        shell
            .apply_inline_snapshot(&snapshot(shell, 2, "one more character"), cx)
            .unwrap();
        assert!(shell.composer_drafts.error.is_some());
        assert_eq!(shell.state.composer_draft(CHAT), "one more character");
        let command = shell.state.select_conversation(OTHER).unwrap();
        commit(&mut shell.state, command, 4);
        shell.align_inline_session(true, cx);
        let command = shell.state.select_conversation(CHAT).unwrap();
        commit(&mut shell.state, command, 5);
        shell.align_inline_session(true, cx);
        assert_eq!(shell.composer.read(cx).text(), "one more character");
        assert!(shell.state.saved_composer_draft(CHAT).is_empty());
        assert!(shell.state.has_unsaved_composer_drafts());
    });
}

#[test]
fn closed_editor_after_lost_clear_does_not_restore_already_submitted_text() {
    with_shell(|shell, cx| {
        install_chats(shell);
        shell.align_inline_session(true, cx);
        shell
            .apply_inline_snapshot(&snapshot(shell, 2, "sent"), cx)
            .unwrap();
        shell.inline_will_send("sent");
        let command = shell
            .state
            .prepare_send("sent", &TurnIds::new(), "2026-11-06T00:00:00.000Z")
            .unwrap();
        commit(&mut shell.state, command, 3);
        let sent = sent(shell);
        let reserved = shell.inline_composer.state.reserve_text_revision().unwrap();
        shell.accept_inline_send_clear(sent, reserved, Err("lost clear".into()), cx);
        let mut closed = snapshot(shell, 3, "sent");
        closed["status"] = json!("closed");
        shell.apply_inline_snapshot(&closed, cx).unwrap();
        shell.align_inline_session(true, cx);
        assert!(shell.composer.read(cx).text().is_empty());
        assert!(shell.state.composer_draft(CHAT).is_empty());
        assert!(!shell.state.has_unsaved_composer_drafts());
    });
}

#[test]
fn first_fallback_observation_uses_the_visible_conversation_identity() {
    with_shell(|shell, cx| {
        install_chats(shell);
        shell.inline_composer = InlineComposer::default();
        shell.composer_drafts = ComposerDrafts::default();
        shell.composer.update(cx, |input, cx| {
            input.set_text("early fallback input".into(), cx)
        });
        shell.composer_text_changed(cx);
        assert_eq!(shell.composer.read(cx).text(), "early fallback input");
        assert_eq!(shell.state.composer_draft(CHAT), "early fallback input");
        assert!(shell.state.composer_draft("new-draft").is_empty());
    });
}

#[test]
fn actor_snapshot_captures_entity_changes_before_queued_input_observation() {
    with_shell(|shell, cx| {
        install_chats(shell);
        shell.align_inline_session(true, cx);
        let incoming = shell.state.clone();
        shell.composer.update(cx, |input, cx| {
            input.set_text("not observed yet".into(), cx)
        });
        assert!(shell.state.composer_draft(CHAT).is_empty());
        shell.retain_composer_drafts(incoming, cx);
        shell.align_inline_session(true, cx);
        assert_eq!(shell.composer.read(cx).text(), "not observed yet");
        assert_eq!(shell.state.composer_draft(CHAT), "not observed yet");
    });
}

#[test]
fn another_conversations_conflict_is_scoped_and_resolves_without_replacing_current_input() {
    for locale in [Locale::En, Locale::Zh] {
        with_shell(|shell, cx| {
            install_chats(shell);
            shell.locale = locale;
            shell.align_inline_session(true, cx);
            let save = shell
                .state
                .rename_conversation(OTHER, "Separate work")
                .unwrap();
            commit(&mut shell.state, save, 3);
            let mut remote = shell.state.clone();
            shell
                .state
                .stage_composer_draft(OTHER, "other local text")
                .unwrap();
            remote
                .stage_composer_draft(OTHER, "other saved text")
                .unwrap();
            let save = remote.persist_composer_drafts().unwrap().unwrap();
            commit(&mut remote, save, 4);
            shell.retain_composer_drafts(remote, cx);
            shell.align_inline_session(true, cx);
            shell
                .apply_inline_snapshot(&snapshot(shell, 2, "current conversation input"), cx)
                .unwrap();
            assert_eq!(shell.state.composer_draft_conflicts(), vec![OTHER]);
            assert!(
                shell
                    .composer_draft_conflict_scope(OTHER)
                    .contains("Separate work")
            );
            assert_ne!(
                shell.composer_draft_conflict_scope(OTHER),
                shell.composer_draft_conflict_scope(CHAT)
            );
            shell.resolve_composer_draft(OTHER, false, cx);
            assert_eq!(shell.state.composer_draft(OTHER), "other saved text");
            assert_eq!(shell.composer.read(cx).text(), "current conversation input");
        });
    }
}

#[test]
fn cold_load_preserves_early_input_identity_and_restores_saved_text_when_empty() {
    for established in [false, true] {
        for early in ["", "before load"] {
            with_shell(|shell, cx| {
                install_chats(shell);
                shell
                    .state
                    .stage_composer_draft(CHAT, "saved chat")
                    .unwrap();
                let save = shell.state.persist_composer_drafts().unwrap().unwrap();
                commit(&mut shell.state, save, 3);
                let incoming = envelope(&shell.state, 3);
                shell.state = ShellState::with_test_models();
                shell.inline_composer = InlineComposer::default();
                shell.composer_drafts = ComposerDrafts::default();
                if established {
                    shell.align_inline_session(true, cx);
                }
                shell
                    .composer
                    .update(cx, |input, cx| input.set_text(early.into(), cx));
                shell
                    .load_snapshot_preserving_composer(incoming, cx)
                    .unwrap();
                if early.is_empty() {
                    assert_eq!(shell.composer.read(cx).text(), "saved chat");
                    assert!(!shell.state.has_unsaved_composer_drafts());
                } else if established {
                    assert_eq!(shell.composer.read(cx).text(), "saved chat");
                    assert_eq!(shell.state.composer_draft("new-draft"), "before load");
                    assert_eq!(shell.state.composer_draft(CHAT), "saved chat");
                } else {
                    assert_eq!(shell.composer.read(cx).text(), "before load");
                    assert_eq!(shell.state.saved_composer_draft(CHAT), "saved chat");
                    assert_eq!(shell.state.composer_draft_conflicts(), vec![CHAT]);
                }
            });
        }
    }
}

#[test]
fn oversized_first_input_survives_hydration_with_or_without_a_transport_key() {
    for incoming_load in [false, true] {
        for established in [false, true] {
            with_shell(|shell, cx| {
                install_chats(shell);
                let incoming = envelope(&shell.state, 2);
                shell.inline_composer = InlineComposer::default();
                shell.composer_drafts = ComposerDrafts::default();
                if incoming_load {
                    shell.state = ShellState::with_test_models();
                }
                if established {
                    shell.align_inline_session(true, cx);
                }
                let text = "x".repeat(1024 * 1024 + 1);
                shell
                    .composer
                    .update(cx, |input, cx| input.set_text(text.clone(), cx));
                if incoming_load {
                    shell
                        .load_snapshot_preserving_composer(incoming, cx)
                        .unwrap();
                } else {
                    shell.composer_text_changed(cx);
                }
                assert_eq!(shell.composer.read(cx).text(), text);
                assert!(shell.composer_drafts.rejected_text);
                assert!(shell.navigation_block_reason().is_some());
                assert_eq!(
                    shell.inline_composer.state.current_conversation_key(),
                    Some(if incoming_load && established {
                        "new-draft"
                    } else {
                        CHAT
                    })
                );
            });
        }
    }
}

#[test]
fn closed_editor_preset_survives_actor_or_load_before_its_entity_observer() {
    for load in [false, true] {
        with_shell(|shell, cx| {
            install_chats(shell);
            shell.align_inline_session(true, cx);
            shell
                .apply_inline_snapshot(&snapshot(shell, 2, "old editor text"), cx)
                .unwrap();
            let save = shell.state.persist_composer_drafts().unwrap().unwrap();
            commit(&mut shell.state, save, 3);
            let incoming = shell.state.clone();
            let mut closed = snapshot(shell, 3, "old editor text");
            closed["status"] = json!("closed");
            shell.apply_inline_snapshot(&closed, cx).unwrap();
            // Prompt tiles call set_text directly, before the queued observer.
            shell.composer.update(cx, |input, cx| {
                input.set_text("new prompt preset".into(), cx)
            });
            if load {
                shell
                    .load_snapshot_preserving_composer(envelope(&incoming, 3), cx)
                    .unwrap();
            } else {
                shell.retain_composer_drafts(incoming, cx);
                shell.align_inline_session(true, cx);
            }
            closed["revision"] = json!(4);
            shell.apply_inline_snapshot(&closed, cx).unwrap();
            assert_eq!(shell.composer.read(cx).text(), "new prompt preset");
            assert_eq!(shell.state.composer_draft(CHAT), "new prompt preset");
        });
    }
}
