use super::*;

fn saved_after_restart(state: &ShellState, key: &str) -> String {
    let raw = state.raw_session().to_string();
    let mut restored = ShellState::with_test_models();
    restored
        .load_snapshot(
            json!({"schema_version":1,"status":"present","session_json":raw,
        "snapshot":{"schema_version":1,"generation":7,
            "session_sha256":session_schema::candidate_digest(raw.as_bytes()).unwrap()}}),
        )
        .unwrap();
    restored.composer_draft(key).into()
}

#[test]
fn composer_drafts_question_receipt_consumes_atomically_and_preserves_newer_typing() {
    for newer in [None, Some("next thought"), Some("")] {
        let mut state = chat();
        let key = state.active_conversation_id().unwrap().to_owned();
        let round = start(&mut state);
        let batch = tool_round(&mut state, &round, "ask_user");
        state
            .accept_agent_result(&batch, batch_result(&batch.args[0], "ask_user"), NOW)
            .unwrap();
        persist(&mut state);
        state.stage_composer_draft(&key, "b").unwrap();
        let question = state.agent_view().unwrap().question.unwrap();
        state
            .answer_agent_question(&question.id, Some("b"), NOW)
            .unwrap();
        let execute = persist(&mut state).unwrap();
        assert_eq!(
            saved_after_restart(&state, &key),
            "b",
            "intent retains unsent answer"
        );
        state
            .accept_agent_result(&execute, executed(&execute.args[0], "ok"), NOW)
            .unwrap();
        assert_eq!(
            saved_after_restart(&state, &key),
            "b",
            "no clear without CAS proof"
        );
        if let Some(text) = newer {
            state.stage_composer_draft(&key, text).unwrap();
        }
        persist(&mut state);
        assert_eq!(
            saved_after_restart(&state, &key),
            "",
            "receipt and clear share one CAS"
        );
        assert_eq!(state.composer_draft(&key), newer.unwrap_or(""));
        assert!(!state.agent_run.as_ref().unwrap().answer_draft_pending);
        // Later checkpoints must not consume a new draft repeating the answer.
        state.stage_composer_draft(&key, "b").unwrap();
        persist(&mut state);
        assert_eq!(state.composer_draft(&key), "b");
    }
}

#[test]
fn composer_drafts_question_lost_native_result_and_unknown_cas_retain_draft() {
    for lost_native in [true, false] {
        let mut state = chat();
        let key = state.active_conversation_id().unwrap().to_owned();
        let round = start(&mut state);
        let batch = tool_round(&mut state, &round, "ask_user");
        state
            .accept_agent_result(&batch, batch_result(&batch.args[0], "ask_user"), NOW)
            .unwrap();
        persist(&mut state);
        state.stage_composer_draft(&key, "b").unwrap();
        let question = state.agent_view().unwrap().question.unwrap();
        state
            .answer_agent_question(&question.id, Some("b"), NOW)
            .unwrap();
        let execute = persist(&mut state).unwrap();
        if lost_native {
            state
                .fail_agent_command(&execute, "lost reply", NOW)
                .unwrap();
        } else {
            state
                .accept_agent_result(&execute, executed(&execute.args[0], "ok"), NOW)
                .unwrap();
            assert!(state.accept_persist(json!({"status":"unknown"})).is_err());
        }
        assert_eq!(saved_after_restart(&state, &key), "b");
        assert_eq!(state.composer_draft(&key), "b");
        assert!(!state.may_clear_sent_draft());
    }
}
