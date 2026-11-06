//! Additive runtime grant tests. The pre-v3 native oracle stays frozen; these
//! derive a separate valid history and serialize every live authorization step.
use rish_agent_core::canonical::canonical_json;
use rish_agent_core::session_schema::{env_from_json, validate_candidate, validate_envelope, Env};
use serde_json::{json, Value};
const CASE: &str = "agent-git-push-conversation-session";
const NEXT_ATTEMPT: &str = "41414141-4141-4141-8141-414141414141";
const NEXT_ROUND: &str = "42424242-4242-4242-8242-424242424242";
const DIFFERENT: &str = "43434343-4343-4343-8343-434343434343";
fn fixture(name: &str) -> Value {
    serde_json::from_str(
        &std::fs::read_to_string(
            std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../fixtures")
                .join(name),
        )
        .unwrap(),
    )
    .unwrap()
}
fn installed_consent() -> (Value, Env) {
    let corpus = fixture("session-corpus.json");
    let case = corpus["candidates"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["name"] == CASE)
        .unwrap();
    let mut session: Value = serde_json::from_str(case["text"].as_str().unwrap()).unwrap();
    let env = env_from_json(Some(
        &fixture("session-golden.json")["candidates"][CASE]["env"],
    ));
    assert!(validate_candidate(&canonical_json(&session).unwrap(), &env).is_ok());
    // The original token-backed approval event remains the receipt reference
    // for the install call; the newly issued grant has its independent ID.
    let encoded = session
        .to_string()
        .replace("git_push", "install_runtime_environment")
        .replace("push-call", "install-call");
    session = serde_json::from_str(&encoded).unwrap();
    let conversation = &mut session["conversations"][0];
    let journal = &mut conversation["attempts"][0]["agent"];
    journal["root"]["capabilities"] = json!(["file_read", "file_write", "guest_service"]);
    journal["tool_registry_version"] = json!(3);
    journal["reserved_write_bytes"] = json!(0);
    conversation["agent_grants"][0]["tool_family"] = json!("guest_service");
    conversation["agent_grants"][0]["registry_version"] = json!(3);
    (session, env)
}
fn reused(name: &str) -> (Value, Env) {
    let (mut session, env) = installed_consent();
    assert!(
        validate_candidate(&canonical_json(&session).unwrap(), &env).is_ok(),
        "install approval snapshot"
    );
    let conversation = &mut session["conversations"][0];
    let grant_id = conversation["agent_grants"][0]["grant_id"].clone();
    let mut next = conversation["attempts"][0].clone();
    // Cancellation after the successful install leaves its approval history
    // intact. The next attempt may reuse that conversation-level grant.
    conversation["attempts"][0]["status"] = json!("cancelled");
    conversation["attempts"][0]["agent"]["phase"] = json!("cancelled");
    next["attempt_id"] = json!(NEXT_ATTEMPT);
    next["rounds"][0]["attempt_id"] = json!(NEXT_ATTEMPT);
    next["rounds"][0]["round_id"] = json!(NEXT_ROUND);
    next["rounds"][0]["provider_request_id"] = json!(DIFFERENT);
    next["rounds"][0]["provider_response_id"] = json!("runtime-response-0");
    let journal = &mut next["agent"];
    journal["phase"] = json!("batch_frozen");
    journal["call_index"] = Value::Null;
    journal["round_lineage"]["round_id"] = json!(NEXT_ROUND);
    journal["transcript"]["transcript_ref"] = json!(DIFFERENT);
    let call = &mut journal["batch"][0];
    call["name"] = json!(name);
    call["call_id"] = json!(format!("{name}-call"));
    call["safe_summary_key"] = json!(format!("agent.{name}"));
    call["arguments_sha256"] = json!("a".repeat(64));
    call["idempotency_key"] = json!("b".repeat(64));
    call["approval_token"] = Value::Null;
    call["approval_reference"] = grant_id;
    call["native_row_revision"] = json!(1);
    call["receipt"] = Value::Null;
    conversation["attempts"].as_array_mut().unwrap().push(next);
    conversation["turns"][0]["attempt_ids"]
        .as_array_mut()
        .unwrap()
        .push(json!(NEXT_ATTEMPT));
    (session, env)
}
fn round_trip(session: &Value, env: &Env) -> bool {
    let Ok(candidate) = validate_candidate(&canonical_json(session).unwrap(), env) else {
        return false;
    };
    let digest = candidate.digest;
    let envelope = json!({"schema_version":3,"writer_launch_instance_id":DIFFERENT,"generation":1,
        "session_sha256":digest,"session":candidate.session,
        "recent_commits":[{"schema_version":1,"operation_id":DIFFERENT,"generation":1,"session_sha256":digest}],
        "proof_run_id":null,"proof_request_id":null});
    validate_envelope(&canonical_json(&envelope).unwrap(), env).is_ok()
}
#[test]
fn install_consent_reuses_live_grant_for_run_and_start_in_a_later_attempt() {
    let (install, env) = installed_consent();
    assert!(round_trip(&install, &env));
    for name in ["run_program", "start_runtime_service"] {
        let (session, env) = reused(name);
        assert!(
            round_trip(&session, &env),
            "{name} bound tokenless checkpoint must survive disk serialization"
        );
        let grant = &session["conversations"][0]["agent_grants"][0];
        assert_ne!(grant["issued_for"]["attempt_id"], NEXT_ATTEMPT);
    }
}
#[test]
fn live_tokenless_call_refuses_missing_and_misbound_conversation_grants() {
    let (valid, env) = reused("run_program");
    assert!(round_trip(&valid, &env));
    for (field, bad) in [
        ("grant_id", json!(DIFFERENT)),
        ("conversation_id", json!(DIFFERENT)),
        ("workspace_id", json!(DIFFERENT)),
        ("project_id", json!(DIFFERENT)),
        ("binding_revision", json!(2)),
        ("root_fingerprint_sha256", json!("d".repeat(64))),
        ("registry_version", json!(2)),
        ("policy_version", json!("another-policy")),
        ("tool_family", json!("file_write")),
    ] {
        let mut changed = valid.clone();
        changed["conversations"][0]["agent_grants"][0][field] = bad;
        assert!(
            !round_trip(&changed, &env),
            "grant mismatch must reject: {field}"
        );
    }
    let mut revoked = valid.clone();
    revoked["conversations"][0]["agent_grants"] = json!([]);
    assert!(!round_trip(&revoked, &env));
    let mut unfrozen = valid.clone();
    unfrozen["conversations"][0]["attempts"][1]["agent"]["frozen_grant_ids"] = json!([]);
    assert!(!round_trip(&unfrozen, &env));
    let mut no_capability = valid.clone();
    no_capability["conversations"][0]["attempts"][1]["agent"]["root"]["capabilities"] =
        json!(["file_read", "file_write"]);
    assert!(!round_trip(&no_capability, &env));
    for (field, bad) in [
        ("approval_decision", json!("allow_once")),
        ("approval_reference", Value::Null),
        ("approval_reference", json!("not-a-grant-id")),
        ("idempotency_key", Value::Null),
        ("native_row_revision", Value::Null),
        ("access", json!("confirm_once")),
    ] {
        let mut changed = valid.clone();
        changed["conversations"][0]["attempts"][1]["agent"]["batch"][0][field] = bad;
        assert!(
            !round_trip(&changed, &env),
            "tokenless call must reject: {field}"
        );
    }
}

#[test]
fn reopened_attempt_projects_current_committed_frozen_grants_and_bound_wal_calls() {
    let (session, env) = reused("start_runtime_service");
    assert!(round_trip(&session, &env));
    let conversation = &session["conversations"][0];
    let journal = &conversation["attempts"][1]["agent"];
    let request = json!({"conversation_id":conversation["id"],"task_id":conversation["attempts"][1]["turn_id"],"attempt_id":NEXT_ATTEMPT});
    let base = json!({"frozen_grant_ids":[],"root":journal["root"],"policy":journal["policy"],"registry":{"registry_version":3}});
    let call = &journal["batch"][0];
    let native_call = json!({"call_index":0,"call_id":call["call_id"],"name":call["name"],"arguments_sha256":call["arguments_sha256"],
        "approval_state":"bound","approval_token":null,"approval_reference":call["approval_reference"],"receipt":null});
    let batch = json!({"task_id":request["task_id"],"attempt_id":NEXT_ATTEMPT,"round_id":NEXT_ROUND,"round_index":0,"batch_revision":1,"kind":"write_batch","manifest_sha256":"d".repeat(64)});
    let mut receipt = batch.clone();
    receipt["calls"] = json!([native_call]);
    let state = json!({"batches":[batch],"operation_results":[{"result":{"result_kind":"prepare_agent_tool_batch","result":{"receipt":receipt}}}]});
    let state: Value = serde_json::from_slice(&canonical_json(&state).unwrap()).unwrap();
    let proof =
        json!({"matches":true,"controller_generation":7,"journal_revision":8,"session":session});
    let output = rish_agent_core::runtime_coordinator::query_attempt_projection(
        &state, &base, &proof, &request,
    );
    assert_eq!(
        output["attempt"]["frozen_grant_ids"],
        journal["frozen_grant_ids"]
    );
    assert_eq!(output["attempt"]["batch"][0]["approval_state"], "bound");
    assert!(output["attempt"]["batch"][0]["approval_token"].is_null());
    assert_eq!(
        output["attempt"]["batch"][0]["approval_reference"],
        call["approval_reference"]
    );
    let mut stale = proof.clone();
    stale["matches"] = json!(false);
    assert_eq!(
        rish_agent_core::runtime_coordinator::query_attempt_projection(
            &state, &base, &stale, &request
        )["attempt"]["frozen_grant_ids"],
        json!([])
    );
    let mut wrong_root = base.clone();
    wrong_root["root"]["root_fingerprint_sha256"] = json!("e".repeat(64));
    assert_eq!(
        rish_agent_core::runtime_coordinator::query_attempt_projection(
            &state,
            &wrong_root,
            &proof,
            &request
        )["attempt"]["frozen_grant_ids"],
        json!([])
    );
}

#[test]
fn settled_reused_receipt_keeps_the_exact_grant_reference() {
    for name in ["run_program", "start_runtime_service"] {
        let (mut session, env) = reused(name);
        let journal = &mut session["conversations"][0]["attempts"][1]["agent"];
        journal["phase"] = json!("tool_result_pending");
        journal["call_index"] = json!(0);
        let call = &mut journal["batch"][0];
        call["native_row_revision"] = json!(4);
        call["receipt"] = json!({"schema_version":1,"call_id":call["call_id"],"name":name,"arguments_sha256":call["arguments_sha256"],
            "result_sha256":"f".repeat(64),"result_bytes":200,"truncated":false,"duration_ms":1,"outcome":"ok","failure_code":null,"approval_reference":call["approval_reference"]});
        assert!(round_trip(&session, &env));
        session["conversations"][0]["attempts"][1]["agent"]["batch"][0]["receipt"]
            ["approval_reference"] = json!(DIFFERENT);
        assert!(!round_trip(&session, &env));
    }
}

#[test]
fn reuse_approval_audit_preserves_grant_history_after_the_next_round_clears_batch() {
    let (mut session, env) = reused("run_program");
    let call = session["conversations"][0]["attempts"][1]["agent"]["batch"][0].clone();
    let time = session["conversations"][0]["attempts"][1]["created_at"].clone();
    let ids = [
        "51515151-5151-4151-8151-515151515151",
        "52525252-5252-4252-8252-525252525252",
        "53535353-5353-4353-8353-535353535353",
    ];
    for (index, kind) in ["approval", "tool_call", "tool_result"].iter().enumerate() {
        session["session_events"].as_array_mut().unwrap().push(json!({"schema_version":2,"event_id":ids[index],"attempt_id":NEXT_ATTEMPT,
            "seq":index,"kind":kind,"round_index":0,"call_id":call["call_id"],"status":match *kind {"approval"=>"approval","tool_call"=>"running",_=>"ok"},
            "safe_summary_key":call["safe_summary_key"],"arguments_sha256":call["arguments_sha256"],
            "result_sha256":if *kind=="tool_result" {json!("f".repeat(64))} else {Value::Null},
            "approval_reference":if *kind=="tool_call" {Value::Null} else {call["approval_reference"].clone()},"failure_code":null,"created_at":time}));
    }
    let attempt = &mut session["conversations"][0]["attempts"][1];
    let mut next_round = attempt["rounds"][0].clone();
    next_round["round_id"] = json!("54545454-5454-4454-8454-545454545454");
    next_round["round_index"] = json!(1);
    next_round["provider_request_id"] = json!("55555555-5555-4555-8555-555555555555");
    next_round["provider_response_id"] = json!("runtime-response-1");
    attempt["rounds"]
        .as_array_mut()
        .unwrap()
        .push(next_round.clone());
    attempt["agent"]["round_index"] = json!(1);
    attempt["agent"]["round_lineage"]["round_index"] = json!(1);
    attempt["agent"]["round_lineage"]["round_id"] = next_round["round_id"].clone();
    attempt["agent"]["batch"] = json!([]);
    attempt["agent"]["call_index"] = Value::Null;
    assert!(
        round_trip(&session, &env),
        "approval audit must preserve the grant reference after call projection is gone"
    );
    // No unknown historical-grant relaxation: dropping the existing approval
    // audit must still refuse an unexplained tool-result authorization change.
    session["session_events"]
        .as_array_mut()
        .unwrap()
        .retain(|e| e["event_id"] != ids[0]);
    for event in session["session_events"]
        .as_array_mut()
        .unwrap()
        .iter_mut()
        .filter(|e| e["attempt_id"] == NEXT_ATTEMPT)
    {
        event["seq"] = json!(event["seq"].as_u64().unwrap() - 1);
    }
    assert!(!round_trip(&session, &env));
}

fn committed_prepare_with_lost_reply(name: &str) -> (Value, Value, Value, Value, Env) {
    use rish_agent_core::{
        canonical::hash_json, ledger_batch, ledger_ops::Change, schema::arguments_sha256,
    };
    let (mut session, env) = reused(name);
    let conversation_id = session["conversations"][0]["id"].clone();
    let task = session["conversations"][0]["attempts"][1]["turn_id"].clone();
    let grants = session["conversations"][0]["agent_grants"]
        .as_array()
        .unwrap()
        .clone();
    let journal = &mut session["conversations"][0]["attempts"][1]["agent"];
    journal["batch"] = json!([]);
    journal["frozen_grant_ids"] = json!([]);
    let root = journal["root"].clone();
    let policy = journal["policy"].clone();
    let time = journal["updated_at"].clone();
    let identity = json!({"schema_version":1,"transcript_ref":journal["transcript"]["transcript_ref"],"attempt_id":NEXT_ATTEMPT,
        "root_fingerprint_sha256":root["root_fingerprint_sha256"],"generation":0,"messages":[]});
    let digest = hash_json("agent-transcript", &identity).unwrap();
    let bytes = canonical_json(&identity).unwrap().len();
    let transcript = json!({"schema_version":1,"transcript_ref":identity["transcript_ref"],"attempt_id":NEXT_ATTEMPT,"state":"open",
        "root_fingerprint_sha256":root["root_fingerprint_sha256"],"generation":0,"transcript_sha256":digest,"transcript_bytes":bytes,
        "messages":[],"created_at":time,"updated_at":time});
    let reference = json!({"schema_version":1,"transcript_ref":identity["transcript_ref"],"generation":0,"transcript_sha256":digest,"transcript_bytes":bytes});
    journal["transcript"] = reference.clone();
    let base = json!({"schema_version":2,"conversation_id":conversation_id,"task_id":task,"attempt_id":NEXT_ATTEMPT,"root":root,"policy":policy,
        "registry":{"schema_version":2,"registry_version":3,"toolset_sha256":journal["toolset_sha256"],
            "tools":[{"schema_version":2,"name":name,"safe_summary_key":format!("agent.{name}"),"access":"conversation_confirm"}]},"frozen_grant_ids":[]});
    let query = json!({"conversation_id":conversation_id,"task_id":task,"attempt_id":NEXT_ATTEMPT});
    let mut arguments = json!({"environment_id":"node-22","entry_path":"server.js","args":[]});
    if name == "start_runtime_service" {
        arguments["port"] = json!(8080);
    }
    let arguments_text = arguments.to_string();
    let arguments_sha = arguments_sha256(Some(&json!(name)), Some(&json!(arguments_text))).unwrap();
    let round = json!({"calls":[{"call_index":0,"call_id":"lost-reply-call","name":name,"arguments_sha256":arguments_sha}]});
    let messages = vec![
        json!({"role":"assistant","round_index":0,"tool_calls":[{"call_id":"lost-reply-call","name":name,"arguments_json":arguments_text}]}),
    ];
    let prepare = json!({"conversation_id":conversation_id,"root":root,"round_index":0});
    let selected = rish_agent_core::tool_batch::prepare_calls(
        &prepare,
        &round,
        Some(&messages),
        &base,
        &grants,
    );
    assert_eq!(
        selected["calls"][0]["grant_reference"],
        grants[0]["grant_id"]
    );
    let precondition = json!({"schema_version":1,"kind":name,"arguments_sha256":arguments_sha,"snapshot_sha256":"a".repeat(64),"environment_sha256":"b".repeat(64)});
    let prepared = rish_agent_core::tool_batch::prepare_finish(
        &prepare,
        selected["calls"].as_array().unwrap(),
        &[json!({"prepared":{"precondition":precondition,"reserved_write_bytes":0}})],
    );
    let request = json!({"schema_version":2,"task_id":task,"attempt_id":NEXT_ATTEMPT,"round_id":NEXT_ROUND,"round_index":0,"round_revision":1,
        "root":root,"transcript":reference,"policy":policy,"expected_batch_revision":0,"expected_reserved_write_bytes":0,"calls":prepared["prepared_calls"],
        "operation_id":DIFFERENT,"operation_request_sha256":"c".repeat(64),"conversation_id":conversation_id,
        "controller_cas":{"schema_version":1},"observed_checkpoint":{"schema_version":1}});
    let view = ledger_batch::View {
        tables_present: true,
        transcript: Some(transcript.clone()),
        transcript_summaries: vec![transcript],
        rounds: vec![
            json!({"locator":{"schema_version":1,"task_id":task,"attempt_id":NEXT_ATTEMPT,"round_id":NEXT_ROUND,"round_index":0},
            "state":"completed","row_revision":1,"transcript_after":reference,"terminal_kind":"tool_batch"}),
        ],
        ..Default::default()
    };
    let effect = ledger_batch::reduce(
        "prepare_tool_batch",
        &request,
        &ledger_batch::Env {
            launch_id: DIFFERENT.into(),
            now: time.as_str().unwrap().into(),
            approval_tokens: vec![],
        },
        &view,
    )
    .unwrap();
    let mut state = json!({"batches":[],"ledger":[],"dispatch":[],"operation_results":[{"result":effect.commit_operation.as_ref().unwrap()["safe_result"]}]});
    for change in effect.changes {
        let (key, record) = match change {
            Change::InsertBatch(v) => ("batches", v),
            Change::InsertLedgerRow(v) => ("ledger", v),
            Change::InsertDispatchMarker(v) => ("dispatch", v),
            _ => continue,
        };
        state[key].as_array_mut().unwrap().push(record);
    }
    assert!(rish_agent_core::wal_state::batch_shape_v2(
        &state["batches"][0]
    ));
    assert!(rish_agent_core::execution_ledger::ledger_row(
        &state["ledger"][0]
    ));
    assert!(round_trip(&session, &env));
    let state: Value = serde_json::from_slice(&canonical_json(&state).unwrap()).unwrap();
    let proof =
        json!({"matches":true,"controller_generation":7,"journal_revision":8,"session":session});
    (state, proof, base, query, env)
}

#[test]
fn lost_prepare_reply_recovers_only_from_committed_wal_and_current_live_grant() {
    use rish_agent_core::runtime_coordinator::query_attempt_projection;
    for name in ["run_program", "start_runtime_service"] {
        let (state, proof, base, request, env) = committed_prepare_with_lost_reply(name);
        assert_eq!(
            proof["session"]["conversations"][0]["attempts"][1]["agent"]["frozen_grant_ids"],
            json!([])
        );
        let output = query_attempt_projection(&state, &base, &proof, &request);
        let grant = proof["session"]["conversations"][0]["agent_grants"][0]["grant_id"].clone();
        assert_eq!(output["attempt"]["frozen_grant_ids"], json!([grant]));
        let native = &output["attempt"]["batch"][0];
        assert_eq!(native["approval_state"], "bound");
        assert!(native["approval_token"].is_null());
        let mut resumed = proof["session"].clone();
        let journal = &mut resumed["conversations"][0]["attempts"][1]["agent"];
        journal["frozen_grant_ids"] = output["attempt"]["frozen_grant_ids"].clone();
        journal["batch"] = json!([{"schema_version":3,"call_id":native["call_id"],"call_index":native["call_index"],"name":native["name"],
            "arguments_sha256":native["arguments_sha256"],"safe_summary_key":native["safe_summary_key"],"access":native["access"],
            "approval_token":null,"approval_decision":"allow_conversation","approval_reference":native["approval_reference"],
            "idempotency_key":native["idempotency_key"],"native_row_revision":native["native_row_revision"],"receipt":null}]);
        assert!(round_trip(&resumed, &env));
        for (field, bad) in [
            ("conversation_id", json!(DIFFERENT)),
            ("workspace_id", json!(DIFFERENT)),
            ("project_id", Value::Null),
            ("binding_revision", json!(2)),
            ("root_fingerprint_sha256", json!("f".repeat(64))),
            ("registry_version", json!(2)),
            ("policy_version", json!("changed")),
            ("tool_family", json!("file_write")),
        ] {
            let mut invalid = proof.clone();
            invalid["session"]["conversations"][0]["agent_grants"][0][field] = bad;
            assert_eq!(
                query_attempt_projection(&state, &base, &invalid, &request)["attempt"]
                    ["frozen_grant_ids"],
                json!([]),
                "{name} wrong {field}"
            );
        }
        let mut revoked = proof.clone();
        revoked["session"]["conversations"][0]["agent_grants"] = json!([]);
        assert_eq!(
            query_attempt_projection(&state, &base, &revoked, &request)["attempt"]
                ["frozen_grant_ids"],
            json!([])
        );
        for field in ["arguments_sha256", "idempotency_key", "approval_reference"] {
            let mut invalid = state.clone();
            invalid["operation_results"][0]["result"]["result"]["receipt"]["calls"][0][field] =
                json!("e".repeat(64));
            assert_eq!(
                query_attempt_projection(&invalid, &base, &proof, &request)["attempt"]
                    ["frozen_grant_ids"],
                json!([]),
                "forged WAL {field}"
            );
        }
        for table in ["ledger", "dispatch", "operation_results"] {
            let mut invalid = state.clone();
            invalid[table] = json!([]);
            assert_eq!(
                query_attempt_projection(&invalid, &base, &proof, &request)["attempt"]
                    ["frozen_grant_ids"],
                json!([]),
                "missing {table}"
            );
        }
        let mut bad_manifest = state.clone();
        bad_manifest["batches"][0]["manifest_sha256"] = json!("e".repeat(64));
        assert_eq!(
            query_attempt_projection(&bad_manifest, &base, &proof, &request)["attempt"]
                ["frozen_grant_ids"],
            json!([])
        );
        let mut missing_registry = base.clone();
        missing_registry["registry"]["tools"] = json!([]);
        assert_eq!(
            query_attempt_projection(&state, &missing_registry, &proof, &request)["attempt"]
                ["frozen_grant_ids"],
            json!([])
        );
    }
}

fn assistant_metadata_reused(name: &str) -> (Value, Env) {
    let (session, env) = reused(name);
    let encoded = session
        .to_string()
        .replace("install_runtime_environment", "create_assistant_task")
        .replace("install-call", "assistant-create-call");
    let mut session: Value = serde_json::from_str(&encoded).unwrap();
    let conversation = &mut session["conversations"][0];
    for attempt in conversation["attempts"].as_array_mut().unwrap() {
        attempt["agent"]["tool_registry_version"] = json!(5);
        attempt["agent"]["root"]["capabilities"] = json!(["file_read"]);
    }
    conversation["agent_grants"][0]["tool_family"] = json!("assistant_metadata");
    conversation["agent_grants"][0]["registry_version"] = json!(5);
    (session, env)
}

#[test]
fn assistant_metadata_conversation_grant_survives_persisted_session_with_read_only_root() {
    for name in [
        "create_assistant_task",
        "update_assistant_task",
        "remember_assistant_memory",
        "forget_assistant_memory",
    ] {
        let (session, env) = assistant_metadata_reused(name);
        assert!(
            round_trip(&session, &env),
            "{name} must survive persisted tokenless approval"
        );
        let conversation = &session["conversations"][0];
        let grant = &conversation["agent_grants"][0];
        let next = &conversation["attempts"][1];
        assert_eq!(grant["tool_family"], "assistant_metadata");
        assert_ne!(grant["issued_for"]["attempt_id"], next["attempt_id"]);
        assert_eq!(next["agent"]["root"]["capabilities"], json!(["file_read"]));
        assert_eq!(
            next["agent"]["batch"][0]["approval_decision"],
            "allow_conversation"
        );
        assert!(next["agent"]["batch"][0]["approval_token"].is_null());
    }
}

#[test]
fn assistant_metadata_grant_cannot_cross_families_versions_or_conversations() {
    let (session, env) = assistant_metadata_reused("remember_assistant_memory");
    assert!(round_trip(&session, &env));
    for (field, value) in [
        ("tool_family", json!("file_write")),
        ("tool_family", json!("guest_service")),
        ("tool_family", json!("git_commit")),
        ("conversation_id", json!(DIFFERENT)),
        ("workspace_id", json!(DIFFERENT)),
        ("binding_revision", json!(2)),
        ("registry_version", json!(4)),
    ] {
        let mut changed = session.clone();
        changed["conversations"][0]["agent_grants"][0][field] = value;
        if field == "tool_family" {
            // Give the forged family its own root capability too: rejection
            // must come from family isolation, not a missing workspace grant.
            for attempt in changed["conversations"][0]["attempts"]
                .as_array_mut()
                .unwrap()
            {
                attempt["agent"]["root"]["capabilities"] = json!([
                    "file_read",
                    "file_write",
                    "git_commit",
                    "git_push",
                    "guest_service"
                ]);
            }
        }
        assert!(
            !round_trip(&changed, &env),
            "metadata grant mismatch: {field}"
        );
    }
    let mut v4 = session.clone();
    v4["conversations"][0]["agent_grants"][0]["registry_version"] = json!(4);
    for attempt in v4["conversations"][0]["attempts"].as_array_mut().unwrap() {
        attempt["agent"]["tool_registry_version"] = json!(4);
    }
    assert!(
        !round_trip(&v4, &env),
        "metadata family itself requires registry v5"
    );

    for (name, capability) in [
        ("write_file", "file_write"),
        ("git_commit", "git_commit"),
        ("git_push", "git_push"),
        ("run_program", "guest_service"),
    ] {
        let mut changed = session.clone();
        let next = &mut changed["conversations"][0]["attempts"][1];
        next["agent"]["root"]["capabilities"] = json!(["file_read", capability]);
        next["agent"]["batch"][0]["name"] = json!(name);
        next["agent"]["batch"][0]["safe_summary_key"] = json!(format!("agent.{name}"));
        assert!(
            !round_trip(&changed, &env),
            "metadata grant must not authorize {name}"
        );
    }
    for name in ["list_assistant_tasks", "search_assistant_memory"] {
        let mut changed = session.clone();
        let call = &mut changed["conversations"][0]["attempts"][1]["agent"]["batch"][0];
        call["name"] = json!(name);
        call["safe_summary_key"] = json!(format!("agent.{name}"));
        assert!(
            !round_trip(&changed, &env),
            "read tools cannot use metadata mutation approval"
        );
    }
    let mut no_read = session.clone();
    no_read["conversations"][0]["attempts"][1]["agent"]["root"]["capabilities"] =
        json!(["file_write"]);
    assert!(
        !round_trip(&no_read, &env),
        "metadata grant requires the assistant readable root binding"
    );
}
