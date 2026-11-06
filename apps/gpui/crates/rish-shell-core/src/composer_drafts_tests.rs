use super::*;

const NOW: &str = "2026-11-06T00:00:00.000Z";
const A: &str = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const B: &str = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";

fn ready() -> ShellState {
    let mut state = ShellState::with_test_models();
    state
        .load_snapshot(json!({"schema_version":1,"status":"missing"}))
        .unwrap();
    state
        .set_default_workspace(json!({"schema_version":2,"workspace_id":model::id(),
        "binding_revision":1,"display_name":"Default","status":"ok",
        "capabilities":{"read":true,"write":true,"git":true}}))
        .unwrap();
    state
}

fn ack(state: &mut ShellState) -> Option<RuntimeCommand> {
    let pending = state.pending.as_ref().unwrap();
    let proof = json!({"schema_version":1,"status":"committed","snapshot":{
        "schema_version":1,"generation":state.authority["snapshot"]["generation"].as_u64().unwrap_or(0)+1,
        "session_sha256":pending.digest}});
    state.accept_persist(proof).unwrap()
}

fn envelope(session: &Value) -> Value {
    let raw = session.to_string();
    json!({"schema_version":1,"status":"present","session_json":raw,"snapshot":{
        "schema_version":1,"generation":7,
        "session_sha256":session_schema::candidate_digest(raw.as_bytes()).unwrap()}})
}

fn restart(state: &ShellState) -> ShellState {
    let mut restored = ready();
    restored
        .load_snapshot(envelope(state.raw_session()))
        .unwrap();
    restored
}

fn chat() -> ShellState {
    let mut state = ready();
    state
        .create_conversation(A, NOW, "deepseek-v4-flash")
        .unwrap();
    ack(&mut state);
    state
}

fn save(state: &mut ShellState, key: &str, text: &str) {
    state.stage_composer_draft(key, text).unwrap();
    state.persist_composer_drafts().unwrap().unwrap();
    ack(state);
}

#[test]
fn composer_drafts_restart_empty_session_and_legacy_load_is_read_only() {
    let mut state = ready();
    assert_eq!(state.raw_session()["schema_version"], 9);
    assert!(state.persist_composer_drafts().unwrap().is_none());
    assert_eq!(restart(&state).raw_session(), state.raw_session());
    save(&mut state, "new-draft", "  未发送 🌏\n");
    assert_eq!(state.raw_session()["schema_version"], 10);
    assert!(state.conversations().is_empty());
    assert_eq!(restart(&state).composer_draft("new-draft"), "  未发送 🌏\n");
    save(&mut state, "new-draft", "");
    let restored = restart(&state);
    assert_eq!(restored.composer_draft("new-draft"), "");
    assert_eq!(restored.raw_session()["composer_drafts"], json!({}));
    assert_eq!(restored.raw_session()["schema_version"], 10);
}

#[test]
fn composer_drafts_multiple_conversations_and_model_edits_keep_exact_text() {
    let mut state = chat();
    save(&mut state, A, "A draft");
    state
        .create_conversation(B, NOW, "deepseek-v4-flash")
        .unwrap();
    ack(&mut state);
    state.stage_composer_draft(B, "B draft").unwrap();
    state
        .set_chat_configuration("deepseek-v4-pro", "off")
        .unwrap();
    ack(&mut state);
    state.select_conversation(A).unwrap();
    ack(&mut state);
    let restored = restart(&state);
    assert_eq!(restored.active_conversation_id(), Some(A));
    assert_eq!(restored.composer_draft(A), "A draft");
    assert_eq!(restored.composer_draft(B), "B draft");
    assert_eq!(
        restored.raw_session()["conversations"][1]["model_id"],
        "deepseek-v4-pro"
    );
}

#[test]
fn composer_drafts_ack_keeps_newer_typing_and_an_erase_during_save() {
    for newer in ["newer text", ""] {
        let mut state = ready();
        state
            .stage_composer_draft("new-draft", "first text")
            .unwrap();
        state.persist_composer_drafts().unwrap().unwrap();
        state.stage_composer_draft("new-draft", newer).unwrap();
        ack(&mut state);
        assert_eq!(state.composer_draft("new-draft"), newer);
        assert!(state.has_unsaved_composer_drafts());
        assert_eq!(state.saved_composer_draft("new-draft"), "first text");
        state.persist_composer_drafts().unwrap().unwrap();
        ack(&mut state);
        assert_eq!(restart(&state).composer_draft("new-draft"), newer);
    }
}

#[test]
fn composer_drafts_initial_adoption_is_atomic_and_keeps_newer_typing() {
    for newer in [None, Some("typed during create"), Some("")] {
        let mut state = ready();
        save(&mut state, "new-draft", "before create");
        state
            .create_conversation_from_draft(A, NOW, "deepseek-v4-flash", "high")
            .unwrap();
        if let Some(text) = newer {
            state.stage_composer_draft("new-draft", text).unwrap();
        }
        assert_eq!(state.saved_composer_draft("new-draft"), "before create");
        ack(&mut state);
        assert_eq!(state.composer_draft("new-draft"), "");
        assert_eq!(state.composer_draft(A), newer.unwrap_or("before create"));
        if newer.is_some() {
            state.persist_composer_drafts().unwrap().unwrap();
            ack(&mut state);
        }
        assert_eq!(
            restart(&state).composer_draft(A),
            newer.unwrap_or("before create")
        );
        assert_eq!(restart(&state).composer_draft("new-draft"), "");
    }
}

#[test]
fn composer_drafts_newer_draft_started_while_empty_chat_creation_is_pending() {
    let mut state = ready();
    state
        .create_conversation_from_draft(A, NOW, "deepseek-v4-flash", "high")
        .unwrap();
    state
        .stage_composer_draft("new-draft", "late start")
        .unwrap();
    ack(&mut state);
    assert_eq!(state.composer_draft(A), "late start");
    assert_eq!(state.composer_draft("new-draft"), "");
    state.persist_composer_drafts().unwrap().unwrap();
    ack(&mut state);
    assert_eq!(restart(&state).composer_draft(A), "late start");
}

#[test]
fn composer_drafts_implicit_assistant_creation_and_second_chat_do_not_adopt() {
    let mut state = ready();
    save(&mut state, "new-draft", "ordinary chat");
    state
        .create_task_conversation(A, NOW, "deepseek-v4-flash", "Assistant task")
        .unwrap();
    ack(&mut state);
    assert_eq!(state.composer_draft("new-draft"), "ordinary chat");
    save(&mut state, A, "existing chat");
    state
        .create_conversation_from_draft(B, NOW, "deepseek-v4-flash", "high")
        .unwrap();
    ack(&mut state);
    assert_eq!(state.composer_draft(A), "existing chat");
    assert_eq!(state.composer_draft(B), "");
    assert_eq!(state.composer_draft("new-draft"), "ordinary chat");
}

#[test]
fn composer_drafts_send_consumes_only_the_committed_text() {
    for agent in [false, true] {
        for newer in [None, Some("next thought"), Some("")] {
            let mut state = chat();
            save(&mut state, A, "send this");
            let before = state.raw_session().clone();
            if agent {
                state
                    .prepare_agent_send("send this", &TurnIds::new(), NOW)
                    .unwrap();
            } else {
                state
                    .prepare_send("send this", &TurnIds::new(), NOW)
                    .unwrap();
            }
            assert_eq!(state.raw_session(), &before);
            assert_eq!(state.composer_draft(A), "send this");
            if let Some(text) = newer {
                state.stage_composer_draft(A, text).unwrap();
            }
            ack(&mut state);
            assert_eq!(state.saved_composer_draft(A), "");
            assert_eq!(restart(&state).composer_draft(A), "");
            assert_eq!(state.composer_draft(A), newer.unwrap_or(""));
            assert_eq!(
                state.has_unsaved_composer_drafts(),
                newer.is_some_and(|s| !s.is_empty())
            );
        }
    }
}

#[test]
fn composer_drafts_send_preserves_a_newer_staged_draft_before_dispatch() {
    let mut state = chat();
    save(&mut state, A, "sent snapshot");
    state.stage_composer_draft(A, "next message").unwrap();
    state
        .prepare_agent_send("sent snapshot", &TurnIds::new(), NOW)
        .unwrap();
    ack(&mut state);
    assert_eq!(restart(&state).composer_draft(A), "next message");
    assert_eq!(state.messages()[0].text, "sent snapshot");
}

#[test]
fn composer_drafts_failed_and_unknown_saves_retain_text_and_exact_cas() {
    for status in ["not_committed", "not_started", "unknown"] {
        let mut state = chat();
        state.stage_composer_draft(A, "keep me").unwrap();
        let command = state.persist_composer_drafts().unwrap().unwrap();
        assert!(state
            .accept_persist(json!({"schema_version":1,"status":status}))
            .is_err());
        assert_eq!(state.composer_draft(A), "keep me");
        assert_eq!(state.saved_composer_draft(A), "");
        assert!(state.has_unsaved_composer_drafts());
        if status == "unknown" {
            let query = state.query_pending_commit().unwrap();
            assert_eq!(
                query.args[0]["operation_id"],
                command.args[0]["operation_id"]
            );
            assert!(state.persist_composer_drafts().is_err());
            ack(&mut state);
        } else {
            state.persist_composer_drafts().unwrap().unwrap();
            ack(&mut state);
        }
        assert_eq!(restart(&state).composer_draft(A), "keep me");
    }
}

#[test]
fn composer_drafts_conflict_reload_retains_both_versions_and_requires_choice() {
    for keep_local in [true, false] {
        let mut state = chat();
        save(&mut state, A, "base");
        let mut remote = restart(&state);
        save(&mut remote, A, "other saved text");
        state.stage_composer_draft(A, "local unsent text").unwrap();
        state.persist_composer_drafts().unwrap().unwrap();
        assert!(state.accept_persist(json!({"status":"conflict"})).is_err());
        state.load_snapshot(envelope(remote.raw_session())).unwrap();
        assert_eq!(state.composer_draft(A), "local unsent text");
        assert_eq!(state.saved_composer_draft(A), "other saved text");
        assert_eq!(state.composer_draft_conflicts(), vec![A]);
        assert_eq!(
            state.persist_composer_drafts().unwrap_err(),
            "E_COMPOSER_DRAFT_CONFLICT"
        );
        // A draft conflict cannot prevent unrelated receipt/config commits.
        state.set_thinking("off").unwrap();
        ack(&mut state);
        assert_eq!(state.saved_composer_draft(A), "other saved text");
        assert_eq!(state.composer_draft(A), "local unsent text");
        state
            .resolve_composer_draft_conflict(A, keep_local)
            .unwrap();
        if keep_local {
            state.persist_composer_drafts().unwrap().unwrap();
            ack(&mut state);
        }
        assert_eq!(
            restart(&state).composer_draft(A),
            if keep_local {
                "local unsent text"
            } else {
                "other saved text"
            }
        );
    }
}

#[test]
fn composer_drafts_overlay_survives_actor_return_without_replacing_authority() {
    let mut ui = chat();
    save(&mut ui, A, "base");
    let mut actor = ui.clone();
    ui.stage_composer_draft(A, "typed while actor owns writer")
        .unwrap();
    actor.rename_conversation(A, "actor title").unwrap();
    ack(&mut actor);
    let authority = actor.authority.clone();
    actor.retain_composer_drafts_from(&ui);
    assert_eq!(actor.authority, authority);
    assert_eq!(actor.conversations()[0].title, "actor title");
    assert_eq!(actor.composer_draft(A), "typed while actor owns writer");
    actor.persist_composer_drafts().unwrap().unwrap();
    ack(&mut actor);
    assert_eq!(
        restart(&actor).composer_draft(A),
        "typed while actor owns writer"
    );
}

#[test]
fn composer_drafts_invalid_bounds_and_failed_load_never_wipe_staged_text() {
    let mut state = ready();
    state.stage_composer_draft("new-draft", "retain").unwrap();
    assert!(state
        .stage_composer_draft("new-draft", &"x".repeat(1024 * 1024 + 1))
        .is_err());
    assert!(state.stage_composer_draft(" ", "invalid key").is_err());
    assert!(state.load_snapshot(json!({"schema_version":99})).is_err());
    assert_eq!(state.composer_draft("new-draft"), "retain");
    for i in 0..255 {
        state
            .stage_composer_draft(&format!("key-{i}"), "x")
            .unwrap();
    }
    assert!(state.stage_composer_draft("overflow", "x").is_err());
    assert_eq!(state.composer_draft("new-draft"), "retain");
    assert_eq!(state.composer_draft("overflow"), "x");
    assert_eq!(
        state.persist_composer_drafts().unwrap_err(),
        "E_COMPOSER_DRAFT_BOUNDS"
    );
}

#[test]
fn composer_drafts_typing_before_bootstrap_is_not_overwritten_by_saved_text() {
    let mut old = ready();
    save(&mut old, "new-draft", "saved before launch");
    let mut state = ShellState::with_test_models();
    state
        .stage_composer_draft("new-draft", "typed before load")
        .unwrap();
    state.load_snapshot(envelope(old.raw_session())).unwrap();
    assert_eq!(state.composer_draft("new-draft"), "typed before load");
    assert_eq!(
        state.saved_composer_draft("new-draft"),
        "saved before launch"
    );
    assert_eq!(state.composer_draft_conflicts(), vec!["new-draft"]);
}

#[test]
fn composer_drafts_actor_capacity_change_cannot_block_an_unrelated_checkpoint() {
    let mut ui = chat();
    let mut actor = ui.clone();
    ui.stage_composer_draft(A, "local pending text").unwrap();
    for key in ["remote-1", "remote-2", "remote-3", "remote-4"] {
        actor
            .stage_composer_draft(key, &"x".repeat(1024 * 1024))
            .unwrap();
    }
    actor.persist_composer_drafts().unwrap().unwrap();
    ack(&mut actor);
    actor.retain_composer_drafts_from(&ui);
    assert_eq!(
        actor.persist_composer_drafts().unwrap_err(),
        "E_COMPOSER_DRAFT_BOUNDS"
    );
    actor.rename_conversation(A, "safe checkpoint").unwrap();
    ack(&mut actor);
    assert_eq!(actor.composer_draft(A), "local pending text");
    assert_eq!(actor.saved_composer_draft(A), "");
    assert!(actor.has_unsaved_composer_drafts());
    assert_eq!(actor.conversations()[0].title, "safe checkpoint");
    actor.stage_composer_draft("remote-1", "").unwrap();
    actor.persist_composer_drafts().unwrap().unwrap();
    ack(&mut actor);
    assert_eq!(restart(&actor).composer_draft(A), "local pending text");
}

#[test]
fn composer_drafts_conflicting_new_draft_cannot_be_adopted_or_silently_rebased() {
    let mut state = ready();
    save(&mut state, "new-draft", "base");
    let mut remote = restart(&state);
    save(&mut remote, "new-draft", "remote text");
    state
        .stage_composer_draft("new-draft", "local text")
        .unwrap();
    state.load_snapshot(envelope(remote.raw_session())).unwrap();
    let before = state.raw_session().clone();
    assert_eq!(
        state
            .create_conversation_from_draft(A, NOW, "deepseek-v4-flash", "high")
            .unwrap_err(),
        "E_COMPOSER_DRAFT_CONFLICT"
    );
    assert_eq!(state.raw_session(), &before);
    assert!(state.pending.is_none());
    assert_eq!(state.composer_draft("new-draft"), "local text");
    assert_eq!(state.saved_composer_draft("new-draft"), "remote text");
    assert_eq!(state.composer_draft_conflicts(), vec!["new-draft"]);
    state
        .resolve_composer_draft_conflict("new-draft", true)
        .unwrap();
    state
        .create_conversation_from_draft(A, NOW, "deepseek-v4-flash", "high")
        .unwrap();
    ack(&mut state);
    assert_eq!(restart(&state).composer_draft(A), "local text");
}
