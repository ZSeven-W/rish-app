use super::*;

const RECOVERY_NOW: &str = "2026-10-16T08:00:00.000Z";
fn recovered_preflight_cancel(cancel_requested: bool) -> (ShellState, RuntimeCommand, Value) {
    // Actual isolated iOS session/WAL captured after the old controller lost
    // a pre-dispatch failure and its later Stop request could not settle.
    let mut fixture: Value = serde_json::from_str(include_str!(
        "../tests/fixtures/recovered-preflight-cancel.json"
    ))
    .unwrap();
    if !cancel_requested {
        fixture["session"]["session_events"]
            .as_array_mut()
            .unwrap()
            .retain(|event| event["kind"] != "cancel");
    }
    let raw = fixture["session"].to_string();
    let digest = session_schema::candidate_digest(raw.as_bytes()).unwrap();
    let mut s = ShellState::with_test_models();
    s.load_snapshot(json!({"schema_version":1,"status":"present","session_json":raw,"snapshot":{"schema_version":1,"generation":5,"session_sha256":digest}})).unwrap();
    let query = s.recover_agent(RECOVERY_NOW).unwrap().unwrap();
    assert_eq!(query.method, "query_agent_attempt");
    let recover = s
        .accept_agent_result(
            &query,
            json!({"schema_version":2,"status":"active","attempt":fixture["result"]["attempt"]}),
            RECOVERY_NOW,
        )
        .unwrap()
        .unwrap();
    assert_eq!(recover.method, "recover_agent_attempt");
    assert_eq!(recover.args[0]["action"], "reconcile");
    assert_eq!(recover.args[0]["expected_round_revision"], 3);
    let mut result = fixture["result"].clone();
    result["operation_id"] = recover.args[0]["operation_id"].clone();
    (s, recover, result)
}

#[test]
fn recovered_retryable_round_honors_durable_stop_without_resending() {
    let (mut s, recover, result) = recovered_preflight_cancel(true);
    let round_id = result["attempt"]["round_id"].clone();
    assert!(s.agent_run.as_ref().unwrap().cancel_requested);
    let save = s
        .accept_agent_result(&recover, result, RECOVERY_NOW)
        .unwrap()
        .unwrap();
    assert_eq!(save.method, "casPersistSession");
    let finalize = persist(&mut s).unwrap();
    assert_eq!(finalize.method, "finalize_agent_attempt");
    assert_eq!(s.agent_attempt().unwrap()["status"], "cancelled");
    assert_eq!(
        s.agent_attempt().unwrap()["agent"]["round_lineage"]["round_id"],
        round_id
    );
    assert_eq!(
        s.agent_attempt().unwrap()["agent"]["round_lineage"]["native_row_revision"],
        3
    );
    assert_eq!(s.messages().len(), 1);
    let q = &finalize.args[0];
    let discard = s.accept_agent_result(&finalize, json!({"schema_version":2,"status":"terminal",
        "operation_id":q["operation_id"],"cleanup_id":q["cleanup_id"],"transcript":q["transcript"]}), RECOVERY_NOW).unwrap().unwrap();
    assert_eq!(discard.method, "discard_agent_attempt");
    let q = &discard.args[0];
    s.accept_agent_result(
        &discard,
        json!({"schema_version":2,"status":"discarded",
        "operation_id":q["operation_id"],"cleanup_id":q["cleanup_id"]}),
        RECOVERY_NOW,
    )
    .unwrap();
    assert!(persist(&mut s).is_none());
    assert!(!s.is_busy());
    assert!(!s.has_agent_task());
    assert!(model::rows(s.raw_session(), "agent_transcript_cleanup_outbox").is_empty());
}

fn ambiguous_provider_result(result: &mut Value) {
    result["status"] = json!("manual_reconciliation");
    result["next_action"] = json!("inspect_native_state");
    result["attempt"]["phase"] = json!("ambiguous");
    result["attempt"]["round_status"] = json!("ambiguous");
    result["attempt"]["round_revision"] = json!(4);
}

#[test]
fn durable_stop_interrupts_only_the_abandoned_provider_after_its_terminal_cas() {
    let (mut s, recover, mut result) = recovered_preflight_cancel(true);
    ambiguous_provider_result(&mut result);
    let save = s
        .accept_agent_result(&recover, result, RECOVERY_NOW)
        .unwrap()
        .unwrap();
    assert_eq!(save.method, "casPersistSession");
    assert_eq!(s.agent_attempt().unwrap()["status"], "sending");
    let interrupt = persist(&mut s).unwrap();
    assert_eq!(interrupt.method, "interrupt_agent_attempt");
    assert_eq!(s.agent_attempt().unwrap()["status"], "cancelled");
    assert_eq!(
        s.agent_attempt().unwrap()["agent"]["round_lineage"]["status"],
        "ambiguous"
    );
    assert_eq!(s.messages().len(), 1);
    let q = &interrupt.args[0];
    let facts = json!({"session_generation":s.authority["snapshot"]["generation"],
        "session_sha256":s.authority["snapshot"]["session_sha256"]});
    assert!(rish_agent_core::runtime_coordinator::interruption_proof(
        s.raw_session(),
        &facts,
        q
    ));
    // A crash between terminal CAS and cleanup keeps the same cleanup proof
    // and resumes interruption, instead of trying ordinary finalization.
    let mut restarted = ShellState::with_test_models();
    restarted
        .load_snapshot(json!({"schema_version":1,"status":"present",
        "session_json":s.raw_session().to_string(),"snapshot":s.authority["snapshot"]}))
        .unwrap();
    let query = restarted.recover_agent(RECOVERY_NOW).unwrap().unwrap();
    assert_eq!(query.method, "query_agent_cleanup");
    let retry = restarted
        .accept_agent_result(
            &query,
            json!({"schema_version":2,"cleanup_id":query.args[0]["cleanup_id"],"status":"unknown"}),
            RECOVERY_NOW,
        )
        .unwrap()
        .unwrap();
    assert_eq!(retry.method, "interrupt_agent_attempt");
    assert_eq!(retry.args[0]["cleanup_id"], q["cleanup_id"]);
    let q = &retry.args[0];
    restarted
        .accept_agent_result(
            &retry,
            json!({"schema_version":2,"status":"discarded",
        "operation_id":q["operation_id"],"cleanup_id":q["cleanup_id"]}),
            RECOVERY_NOW,
        )
        .unwrap();
    assert!(persist(&mut restarted).is_none());
    assert!(!restarted.is_busy());
    assert!(!restarted.has_agent_task());
    assert!(model::rows(restarted.raw_session(), "agent_transcript_cleanup_outbox").is_empty());
}

#[test]
fn provider_interruption_refuses_missing_stop_live_rounds_and_tool_uncertainty() {
    for fault in [
        "no_stop",
        "transient_stop",
        "live_owner",
        "tool_batch",
        "tool_target",
        "wrong_round",
    ] {
        let (mut s, mut recover, mut result) =
            recovered_preflight_cancel(!matches!(fault, "no_stop" | "transient_stop"));
        ambiguous_provider_result(&mut result);
        match fault {
            "transient_stop" => s.agent_run.as_mut().unwrap().cancel_requested = true,
            "live_owner" => {
                result["attempt"]["phase"] = json!("round_in_flight");
                result["attempt"]["round_status"] = json!("active");
            }
            "tool_batch" => result["attempt"]["batch"] = json!([{"execution_state":"unknown"}]),
            "tool_target" => {
                recover.args[0]["target"]["kind"] = json!("tool");
                s.agent_run.as_mut().unwrap().in_flight = Some(recover.clone());
            }
            "wrong_round" => result["attempt"]["round_id"] = json!(model::id()),
            _ => {}
        }
        let before = s.raw_session().clone();
        assert!(
            s.accept_agent_result(&recover, result, RECOVERY_NOW)
                .is_err(),
            "{fault}"
        );
        assert_eq!(s.raw_session(), &before, "{fault}");
        assert!(s.pending.is_none(), "{fault}");
        assert!(s.agent_view().unwrap().recoverable, "{fault}");
    }
}

#[test]
fn recovered_retryable_round_without_stop_terminates_instead_of_starting_another_round() {
    let (mut s, recover, result) = recovered_preflight_cancel(false);
    // Same native facts, but no user cancellation. The native reconcile is
    // evidence of a retryable failure, not permission to resend a request.
    assert!(!s.agent_run.as_ref().unwrap().cancel_requested);
    let save = s
        .accept_agent_result(&recover, result.clone(), RECOVERY_NOW)
        .unwrap()
        .unwrap();
    assert_eq!(save.method, "casPersistSession");
    let finalize = persist(&mut s).unwrap();
    assert_eq!(finalize.method, "finalize_agent_attempt");
    assert_eq!(s.agent_attempt().unwrap()["status"], "failed");
    assert_eq!(
        s.agent_attempt().unwrap()["failure_code"],
        "E_AGENT_PERSISTENCE"
    );
    assert_eq!(
        s.agent_attempt().unwrap()["agent"]["round_lineage"]["round_id"],
        result["attempt"]["round_id"]
    );
    assert_eq!(
        s.agent_attempt().unwrap()["agent"]["round_lineage"]["native_row_revision"],
        3
    );
    assert_eq!(s.messages().len(), 1);
}

#[test]
fn recovered_retryable_native_projection_cannot_be_checkpointed_as_a_fresh_round() {
    let (mut s, _, result) = recovered_preflight_cancel(true);
    let before = s.raw_session().clone();
    let mut journal =
        crate::agent_results::journal_from_projection(&result["attempt"], RECOVERY_NOW);
    crate::agent_controller::increment(&mut journal, RECOVERY_NOW);
    // This is the old recovery route with the actual native projection. Keep
    // its schema rejection explicit so it cannot become an automatic resend.
    assert!(s
        .checkpoint_agent(journal, vec![], "begin_round", RECOVERY_NOW)
        .is_err());
    assert_eq!(s.raw_session(), &before);
    assert!(s.pending.is_none());
}

#[test]
fn recovered_retryable_round_identity_mismatch_remains_unresolved() {
    let (mut s, recover, mut result) = recovered_preflight_cancel(true);
    let before = s.raw_session().clone();
    result["attempt"]["round_id"] = json!(model::id());
    assert!(s
        .accept_agent_result(&recover, result, RECOVERY_NOW)
        .is_err());
    assert_eq!(s.raw_session(), &before);
    assert!(s.pending.is_none());
    assert!(s.agent_view().unwrap().recoverable);
    assert_eq!(
        s.recover_agent(RECOVERY_NOW).unwrap().unwrap().method,
        "query_agent_attempt"
    );
}
