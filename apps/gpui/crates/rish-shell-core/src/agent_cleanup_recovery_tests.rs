use super::*;
use rish_agent_core::{ledger_ops::Slotted, runtime_coordinator as native, transcript_store};

fn apply_native(state: &mut Value, settlement: native::Settlement) -> Value {
    let native::Settlement::Settle {
        changes, output, ..
    } = settlement
    else {
        panic!("Expected a proven native settlement")
    };
    for (key, value) in changes {
        state[key] = value;
    }
    output
}

fn terminal_cleanup() -> (ShellState, RuntimeCommand, Value) {
    let mut shell = chat();
    let round = start(&mut shell);
    shell
        .accept_agent_result(&round, final_result(&round.args[0]), NOW)
        .unwrap();
    let finalize = persist(&mut shell).unwrap();
    let q = &finalize.args[0];
    let state = json!({
        "authorities":[{"task_id":q["task_id"],"attempt_id":q["attempt_id"],
            "conversation_id":q["conversation_id"],"state":"prepared",
            "root":q["root"],"transcript":q["transcript"],"authority_revision":1}],
        "transcripts":[{"attempt_id":q["attempt_id"],"transcript_ref":q["transcript"]["transcript_ref"],
            "transcript_sha256":q["transcript"]["transcript_sha256"],"state":"open"}],
        "cleanup":[],"rounds":[],"ledger":[],"operations":[],"operation_results":[]
    });
    (shell, finalize, state)
}

fn restart(shell: &ShellState) -> ShellState {
    let mut restarted = ShellState::with_test_models();
    restarted
        .load_snapshot(json!({"schema_version":1,"status":"present",
        "session_json":shell.raw_session().to_string(),"snapshot":shell.authority["snapshot"]}))
        .unwrap();
    restarted
}

fn finalize_native(state: &mut Value, command: &RuntimeCommand) -> Value {
    let result = native::finalize_transaction(
        state,
        &command.args[0],
        &json!({"request_sha256":"e".repeat(64),"record":{"authority_revision":1}}),
        NOW,
        NOW,
    );
    apply_native(state, result)
}

fn query_native(state: &Value, query: &RuntimeCommand) -> Value {
    assert_eq!(query.method, "query_agent_cleanup");
    assert_eq!(query.args[0].as_object().unwrap().len(), 2);
    let view = transcript_store::View {
        cleanup: model::rows(state, "cleanup")
            .iter()
            .enumerate()
            .filter(|(_, row)| row["cleanup_id"] == query.args[0]["cleanup_id"])
            .map(|(slot, row)| Slotted {
                slot: slot as u64,
                record: row.clone(),
            })
            .collect(),
        ..Default::default()
    };
    let answer = transcript_store::reduce(
        "query_cleanup",
        &json!({"schema_version":1,"cleanup_id":query.args[0]["cleanup_id"]}),
        &Default::default(),
        &view,
    )
    .unwrap();
    assert!(!answer.commit);
    json!({"schema_version":2,"cleanup_id":query.args[0]["cleanup_id"],"status":answer.output["status"]})
}

#[test]
fn lost_discard_reply_recovers_from_native_receipt_without_refinalizing_absent_authority() {
    let (mut shell, finalize, mut native_state) = terminal_cleanup();
    let result = finalize_native(&mut native_state, &finalize);
    let discard = shell
        .accept_agent_result(&finalize, result, NOW)
        .unwrap()
        .unwrap();
    assert_eq!(discard.method, "discard_agent_attempt");
    assert_eq!(
        native::settle_authority_state(&native_state, &discard.args[0], "discard")["settles"],
        true
    );
    let discarded = native::residue_discard(
        &native_state,
        &discard.args[0],
        "discard_agent_attempt",
        &json!([]),
        &json!({"request_sha256":"f".repeat(64)}),
        NOW,
    );
    let _lost_reply = apply_native(&mut native_state, discarded);
    assert!(model::rows(&native_state, "authorities").is_empty());
    assert_eq!(native_state["cleanup"][0]["status"], "discarded");
    assert!(
        matches!(
            native::finalize_transaction(
                &native_state,
                &finalize.args[0],
                &json!({"record":{"authority_revision":1}}),
                NOW,
                NOW
            ),
            native::Settlement::Error(_)
        ),
        "The old re-finalize route has no remaining authority to validate"
    );

    // The renderer dies after the native transaction, before its reply and
    // before the session CAS that acknowledges cleanup.
    let mut recovered = restart(&shell);
    let query = recovered.recover_agent(NOW).unwrap().unwrap();
    let answer = query_native(&native_state, &query);
    let retry = recovered
        .accept_agent_result(&query, answer, NOW)
        .unwrap()
        .unwrap();
    assert_eq!(retry.method, "discard_agent_attempt");
    for key in [
        "cleanup_id",
        "task_id",
        "attempt_id",
        "conversation_id",
        "transcript_ref",
        "transcript_sha256",
    ] {
        assert_eq!(retry.args[0][key], discard.args[0][key]);
    }
    assert_ne!(
        retry.args[0]["operation_id"],
        discard.args[0]["operation_id"]
    );
    assert!(native::exact_discarded_cleanup(
        &native_state,
        &retry.args[0]
    ));
    assert!(native::cleanup_outbox_proof(
        recovered.raw_session(),
        &retry.args[0]
    ));
    // This is the same already-missing receipt that both native hosts issue
    // only after verifying the two preceding ownership proofs.
    let answer = native::already_missing_commit(
        &retry.args[0],
        &json!({"request_sha256":"a".repeat(64)}),
        "discard_agent_attempt",
    )["output"]
        .clone();
    let save = recovered
        .accept_agent_result(&retry, answer, NOW)
        .unwrap()
        .unwrap();
    assert_eq!(save.method, "casPersistSession");
    assert_eq!(
        model::rows(recovered.raw_session(), "agent_transcript_cleanup_outbox").len(),
        1
    );
    assert!(persist(&mut recovered).is_none());
    assert!(model::rows(recovered.raw_session(), "agent_transcript_cleanup_outbox").is_empty());
    assert!(!recovered.is_busy());
    assert!(!recovered.has_agent_task());
    assert_eq!(recovered.messages().len(), 2);
    assert!(recovered
        .prepare_agent_send("继续工作", &TurnIds::new(), NOW)
        .is_ok());
}

#[test]
fn pending_or_missing_cleanup_still_finalizes_with_the_original_root_guard() {
    for status in ["pending", "unknown"] {
        let (shell, finalize, mut native_state) = terminal_cleanup();
        if status == "pending" {
            finalize_native(&mut native_state, &finalize);
        }
        let mut recovered = restart(&shell);
        let query = recovered.recover_agent(NOW).unwrap().unwrap();
        let answer = query_native(&native_state, &query);
        assert_eq!(answer["status"], status);
        let retry = recovered
            .accept_agent_result(&query, answer, NOW)
            .unwrap()
            .unwrap();
        assert_eq!(retry.method, "finalize_agent_attempt");
        assert_eq!(retry.args[0]["root"], finalize.args[0]["root"]);
        assert!(recovered.pending.is_none());
        let mut wrong_root = retry.args[0].clone();
        wrong_root["root"]["root_fingerprint_sha256"] = json!("0".repeat(64));
        let revision = native_state["authorities"][0]["authority_revision"].clone();
        assert!(matches!(
            native::finalize_transaction(
                &native_state,
                &wrong_root,
                &json!({"record":{"authority_revision":revision}}),
                NOW,
                NOW
            ),
            native::Settlement::Error(_)
        ));
    }
}

#[test]
fn cleanup_query_does_not_treat_a_hint_or_mismatched_reply_as_cleanup_authority() {
    for fault in [
        "wrong_id",
        "missing_id",
        "wrong_schema",
        "invalid_status",
        "discarded_hint",
    ] {
        let (shell, _, _) = terminal_cleanup();
        let mut recovered = restart(&shell);
        let before = recovered.raw_session().clone();
        let query = recovered.recover_agent(NOW).unwrap().unwrap();
        let mut answer = json!({"schema_version":2,"cleanup_id":query.args[0]["cleanup_id"],"status":"discarded"});
        match fault {
            "wrong_id" => answer["cleanup_id"] = json!(model::id()),
            "missing_id" => {
                answer.as_object_mut().unwrap().remove("cleanup_id");
            }
            "wrong_schema" => answer["schema_version"] = json!(1),
            "invalid_status" => answer["status"] = json!("already_missing"),
            _ => {}
        }
        let result = recovered.accept_agent_result(&query, answer, NOW);
        if fault == "discarded_hint" {
            let discard = result.unwrap().unwrap();
            assert_eq!(discard.method, "discard_agent_attempt");
            // A discarded hint alone cannot replace the native settlement.
            assert!(!native::exact_discarded_cleanup(
                &json!({}),
                &discard.args[0]
            ));
            recovered
                .fail_agent_command(&discard, "E_AGENT_CONFLICT", NOW)
                .unwrap();
        } else {
            assert!(result.is_err(), "{fault}");
        }
        assert_eq!(recovered.raw_session(), &before, "{fault}");
        assert!(recovered.pending.is_none(), "{fault}");
        assert!(recovered.agent_view().unwrap().recoverable, "{fault}");
    }
}

#[test]
fn already_missing_requires_exact_discarded_ownership_and_current_outbox() {
    let (mut shell, finalize, mut native_state) = terminal_cleanup();
    let result = finalize_native(&mut native_state, &finalize);
    let discard = shell
        .accept_agent_result(&finalize, result, NOW)
        .unwrap()
        .unwrap();
    let settlement = native::residue_discard(
        &native_state,
        &discard.args[0],
        "discard_agent_attempt",
        &json!([]),
        &json!({"request_sha256":"f".repeat(64)}),
        NOW,
    );
    apply_native(&mut native_state, settlement);
    let proves = |state: &Value, session: &Value, request: &Value| {
        native::exact_discarded_cleanup(state, request)
            && native::cleanup_outbox_proof(session, request)
    };
    assert!(proves(&native_state, shell.raw_session(), &discard.args[0]));
    for key in [
        "cleanup_id",
        "task_id",
        "attempt_id",
        "conversation_id",
        "transcript_ref",
        "transcript_sha256",
    ] {
        let mut wrong = discard.args[0].clone();
        wrong[key] = json!(if key == "transcript_sha256" {
            "0".repeat(64)
        } else {
            model::id()
        });
        assert!(
            !proves(&native_state, shell.raw_session(), &wrong),
            "wrong {key}"
        );
    }
    for fault in ["missing", "duplicate", "changed"] {
        let mut session = shell.raw_session().clone();
        let outbox = session["agent_transcript_cleanup_outbox"]
            .as_array_mut()
            .unwrap();
        match fault {
            "missing" => outbox.clear(),
            "duplicate" => outbox.push(outbox[0].clone()),
            _ => outbox[0]["attempt_id"] = json!(model::id()),
        }
        assert!(
            !proves(&native_state, &session, &discard.args[0]),
            "{fault} outbox"
        );
    }
    native_state["cleanup"][0]["status"] = json!("pending");
    assert!(!proves(
        &native_state,
        shell.raw_session(),
        &discard.args[0]
    ));
}
