//! Scenario tests for the batch-level ledger reducer: tool-batch preparation
//! (read-only, write, denial, replay, compound tokens) and effect-gate
//! opening.

use rish_agent_core::canonical::{canonical_json, hash_bytes, hash_json};
use rish_agent_core::ledger_batch::{reduce, reduce_json, Env, View};
use rish_agent_core::ledger_ops::{Change, Slotted};
use rish_agent_core::schema::arguments_sha256;
use rish_agent_core::store::StoreError;
use serde_json::{json, Value};

const TASK: &str = "11111111-1111-4111-8111-111111111111";
const ATTEMPT: &str = "22222222-2222-4222-8222-222222222222";
const ROUND: &str = "33333333-3333-4333-8333-333333333333";
const LAUNCH: &str = "44444444-4444-4444-8444-444444444444";
const TRANSCRIPT_REF: &str = "88888888-8888-4888-8888-888888888888";
const ROOT_DIGEST: &str = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1";
const NOW: &str = "2023-11-14T22:13:20.000Z";
const TOKEN: &str = "99999999-9999-4999-8999-999999999999";
const OPERATION: &str = "66666666-6666-4666-8666-666666666666";
const READ_ARGUMENTS: &str = "{\"path\":\"README.md\"}";
const WRITE_ARGUMENTS: &str =
    "{\"path\":\"notes.md\",\"content\":\"hello\",\"expected_revision\":null}";

fn env() -> Env {
    Env {
        launch_id: LAUNCH.to_string(),
        now: NOW.to_string(),
        approval_tokens: vec![TOKEN.to_string()],
    }
}

fn transcript_state() -> Value {
    let input = json!({
        "schema_version": 1, "transcript_ref": TRANSCRIPT_REF, "attempt_id": ATTEMPT,
        "root_fingerprint_sha256": ROOT_DIGEST, "generation": 0, "messages": [],
    });
    let bytes = canonical_json(&input).unwrap().len() as u64;
    let digest = hash_json("agent-transcript", &input).unwrap();
    json!({
        "schema_version": 1, "transcript_ref": TRANSCRIPT_REF, "attempt_id": ATTEMPT, "state": "open",
        "root_fingerprint_sha256": ROOT_DIGEST, "generation": 0, "transcript_sha256": digest,
        "transcript_bytes": bytes, "messages": [], "created_at": NOW, "updated_at": NOW,
    })
}

fn reference_of(transcript: &Value) -> Value {
    json!({
        "schema_version": 1, "transcript_ref": TRANSCRIPT_REF, "generation": transcript["generation"],
        "transcript_sha256": transcript["transcript_sha256"], "transcript_bytes": transcript["transcript_bytes"],
    })
}

fn root() -> Value {
    json!({
        "schema_version": 1, "kind": "workspace", "workspace_id": "77777777-7777-4777-8777-777777777777",
        "workspace_binding_revision": 7, "project_id": null, "root_fingerprint_sha256": ROOT_DIGEST,
        "capabilities": ["file_read", "file_write"],
    })
}

fn policy() -> Value {
    json!({ "schema_version": 1, "policy_version": "v1", "max_single_write_bytes": 32768, "max_batch_write_bytes": 524288, "max_attempt_write_bytes": 4194304 })
}

fn read_call(index: u64) -> Value {
    json!({
        "call_index": index, "call_id": format!("call_{index}"), "name": "read_file", "arguments_json": READ_ARGUMENTS,
        "arguments_sha256": arguments_sha256(Some(&json!("read_file")), Some(&json!(READ_ARGUMENTS))).unwrap(),
        "safe_summary_key": "agent.read_file", "access": "auto",
        "precondition": { "schema_version": 1, "kind": "read_file", "source_revision": "rev-1" },
        "reserved_write_bytes": 0,
    })
}

fn write_call(index: u64, access: &str) -> Value {
    json!({
        "call_index": index, "call_id": format!("call_{index}"), "name": "write_file", "arguments_json": WRITE_ARGUMENTS,
        "arguments_sha256": arguments_sha256(Some(&json!("write_file")), Some(&json!(WRITE_ARGUMENTS))).unwrap(),
        "safe_summary_key": "agent.write_file", "access": access,
        "precondition": {
            "schema_version": 2, "kind": "write_file",
            "relative_path_sha256": hash_bytes("relative-path", b"notes.md").unwrap(),
            "prior": { "schema_version": 1, "kind": "absent" },
            "content_sha256": hash_bytes("file-content", b"hello").unwrap(), "content_bytes": 5,
        },
        "reserved_write_bytes": 5,
    })
}

fn request(calls: Vec<Value>, transcript: &Value, compound: bool) -> Value {
    let mut request = json!({
        "schema_version": 2, "task_id": TASK, "attempt_id": ATTEMPT, "round_id": ROUND, "round_index": 0,
        "round_revision": 3, "root": root(), "transcript": reference_of(transcript), "policy": policy(),
        "expected_batch_revision": 0, "expected_reserved_write_bytes": 0, "calls": calls,
    });
    if compound {
        request["operation_id"] = json!(OPERATION);
        request["operation_request_sha256"] = json!("b".repeat(64));
        request["conversation_id"] = json!("55555555-5555-4555-8555-555555555555");
        request["controller_cas"] = json!({ "schema_version": 1 });
        request["observed_checkpoint"] = json!({ "schema_version": 1 });
    }
    request
}

fn view(transcript: &Value) -> View {
    View {
        tables_present: true,
        transcript: Some(transcript.clone()),
        transcript_summaries: vec![transcript.clone()],
        ..Default::default()
    }
}

fn changes_of(
    effect: &rish_agent_core::ledger_batch::Effect,
    kind: fn(&Change) -> Option<&Value>,
) -> Vec<&Value> {
    effect.changes.iter().filter_map(kind).collect()
}

#[test]
fn read_only_batch_uses_round_revision_and_no_reservation() {
    let transcript = transcript_state();
    let effect = reduce(
        "prepare_tool_batch",
        &request(vec![read_call(0)], &transcript, false),
        &env(),
        &view(&transcript),
    )
    .unwrap();
    assert!(effect.commit);
    assert_eq!(effect.output["batch_kind"], "read_only_batch");
    assert_eq!(effect.output["batch_revision"], json!(3));
    assert_eq!(effect.output["effect_gate"], "not_applicable");
    assert_eq!(effect.output["calls"][0]["approval_state"], "not_required");
    let inserted = changes_of(&effect, |c| match c {
        Change::InsertLedgerRow(row) => Some(row),
        _ => None,
    });
    assert_eq!(inserted.len(), 1);
    assert_eq!(inserted[0]["state"], "intent");
    assert!(!effect
        .changes
        .iter()
        .any(|c| matches!(c, Change::InsertReservation(_))));
    assert!(effect
        .changes
        .iter()
        .any(|c| matches!(c, Change::InsertBatch(_))));
    assert!(effect.commit_operation.is_none());
}

#[test]
fn write_batch_reserves_and_issues_approval_tokens_when_compound() {
    let transcript = transcript_state();
    let effect = reduce(
        "prepare_tool_batch",
        &{
            let mut request = request(vec![write_call(0, "confirm_once")], &transcript, true);
            request["calls"][0]["grant_reference"] = Value::Null;
            request
        },
        &env(),
        &{
            let mut compound_view = view(&transcript);
            compound_view.rounds = vec![json!({
                "locator": { "schema_version": 1, "task_id": TASK, "attempt_id": ATTEMPT, "round_id": ROUND, "round_index": 0 },
                "state": "completed", "row_revision": 3, "transcript_after": reference_of(&transcript), "terminal_kind": "tool_batch",
            })];
            compound_view
        },
    )
    .unwrap();
    assert_eq!(effect.output["batch_kind"], "write_batch");
    assert_eq!(effect.output["batch_revision"], json!(1));
    assert_eq!(effect.output["reserved_write_bytes"], json!(5));
    assert_eq!(effect.output["effect_gate"], "closed");
    let reservation = changes_of(&effect, |c| match c {
        Change::InsertReservation(record) => Some(record),
        _ => None,
    });
    assert_eq!(reservation[0]["reserved_write_bytes"], json!(5));
    assert_eq!(reservation[0]["keys"][0]["state"], "active");
    let call = &effect.output["calls"][0];
    assert_eq!(call["approval_state"], "pending");
    assert_eq!(call["approval_token"]["token"], TOKEN);
    assert_eq!(
        call["approval_token"]["allowed_decisions"],
        json!(["denied", "allow_once", "cancelled"])
    );
    let commit = effect.commit_operation.unwrap();
    assert_eq!(commit["result_status"], "prepared");
    assert_eq!(commit["result_ref"]["kind"], "batch");
    assert_eq!(
        commit["safe_result"]["result"]["receipt"]["calls"][0]["approval_token"]["token"],
        TOKEN
    );
    // The output itself never carries the operation result; the facade fills it.
    assert!(effect.output["operation_result"].is_null());
}

#[test]
fn durable_deny_settles_at_preparation_and_appends_feedback() {
    let transcript = transcript_state();
    let mut denied = read_call(0);
    denied["name"] = json!("unknown_tool");
    denied["access"] = json!("durable_deny");
    denied["precondition"] = Value::Null;
    denied["safe_summary_key"] = json!("agent.unknown");
    let effect = reduce(
        "prepare_tool_batch",
        &request(vec![denied, read_call(1)], &transcript, false),
        &env(),
        &view(&transcript),
    )
    .unwrap();
    let denied_rows = changes_of(&effect, |c| match c {
        Change::InsertDeniedCall(row) => Some(row),
        _ => None,
    });
    assert_eq!(denied_rows.len(), 1);
    assert_eq!(
        denied_rows[0]["receipt"]["failure_code"],
        "E_AGENT_UNKNOWN_TOOL"
    );
    assert_eq!(denied_rows[0]["state"], "denied");
    let transcript_change = changes_of(&effect, |c| match c {
        Change::ReplaceTranscript(row) => Some(row),
        _ => None,
    });
    assert_eq!(transcript_change[0]["generation"], json!(1));
    assert_eq!(effect.output["transcript"]["generation"], json!(1));
    assert_eq!(effect.output["calls"][0]["execution_status"], "denied");
    assert_eq!(effect.output["calls"][0]["receipt"]["outcome"], "denied");
    assert_eq!(effect.output["calls"][1]["execution_status"], "intent");
}

#[test]
fn replay_answers_already_prepared_without_committing() {
    let transcript = transcript_state();
    let first = reduce(
        "prepare_tool_batch",
        &request(vec![read_call(0)], &transcript, false),
        &env(),
        &view(&transcript),
    )
    .unwrap();
    let batch = changes_of(&first, |c| match c {
        Change::InsertBatch(record) => Some(record),
        _ => None,
    })[0]
        .clone();
    let mut replayed = view(&transcript);
    replayed.batches = vec![Slotted {
        slot: 0,
        record: batch,
    }];
    let effect = reduce(
        "prepare_tool_batch",
        &request(vec![read_call(0)], &transcript, false),
        &env(),
        &replayed,
    )
    .unwrap();
    assert!(!effect.commit);
    assert_eq!(effect.output["status"], "already_prepared");
    assert_eq!(effect.output["batch_revision"], json!(3));

    // A stale batch revision expectation is a conflict on a fresh round.
    let mut other_round = request(vec![read_call(0)], &transcript, false);
    other_round["round_id"] = json!("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa");
    assert_eq!(
        reduce("prepare_tool_batch", &other_round, &env(), &replayed).unwrap_err(),
        StoreError::Conflict
    );
}

#[test]
fn effect_gate_opens_only_over_a_revalidated_manifest() {
    let transcript = transcript_state();
    let prepared = reduce(
        "prepare_tool_batch",
        &request(vec![write_call(0, "auto")], &transcript, false),
        &env(),
        &view(&transcript),
    )
    .unwrap();
    let batch = changes_of(&prepared, |c| match c {
        Change::InsertBatch(record) => Some(record),
        _ => None,
    })[0]
        .clone();
    let reservation = changes_of(&prepared, |c| match c {
        Change::InsertReservation(record) => Some(record),
        _ => None,
    })[0]
        .clone();
    let row = changes_of(&prepared, |c| match c {
        Change::InsertLedgerRow(record) => Some(record),
        _ => None,
    })[0]
        .clone();
    let marker = changes_of(&prepared, |c| match c {
        Change::InsertDispatchMarker(record) => Some(record),
        _ => None,
    })[0]
        .clone();
    let gate_request = json!({
        "schema_version": 2, "task_id": TASK, "attempt_id": ATTEMPT, "round_id": ROUND, "round_index": 0,
        "expected_batch_revision": batch["batch_revision"], "manifest_sha256": batch["manifest_sha256"],
        "expected_effect_gate": "closed",
    });
    let mut gate_view = view(&transcript);
    gate_view.batches = vec![Slotted {
        slot: 2,
        record: batch.clone(),
    }];
    gate_view.reservations = vec![Slotted {
        slot: 0,
        record: reservation,
    }];
    gate_view.ledger_rows = vec![row.clone()];
    gate_view.dispatch = vec![marker];
    let opened = reduce("open_effect_gate", &gate_request, &env(), &gate_view).unwrap();
    assert!(opened.commit);
    assert_eq!(opened.output["status"], "open");
    assert!(
        matches!(&opened.changes[0], Change::ReplaceBatch { slot: 2, record } if record["effect_gate"] == "open")
    );

    // A dispatched row can no longer open its gate.
    let mut dispatched = gate_view.clone();
    dispatched.dispatch = vec![
        json!({ "schema_version": 1, "kind": "execution", "locator": row["locator"], "dispatch_state": "dispatched" }),
    ];
    assert_eq!(
        reduce("open_effect_gate", &gate_request, &env(), &dispatched).unwrap_err(),
        StoreError::Conflict
    );

    // With authorities recorded, approvals must be bound through operation results.
    let mut guarded = gate_view.clone();
    guarded.authorities_present = true;
    assert_eq!(
        reduce("open_effect_gate", &gate_request, &env(), &guarded).unwrap_err(),
        StoreError::Conflict
    );

    let mut missing = gate_view.clone();
    missing.batches = vec![];
    assert_eq!(
        reduce("open_effect_gate", &gate_request, &env(), &missing).unwrap_err(),
        StoreError::NotFound
    );
}

#[test]
fn json_envelope_round_trips() {
    let transcript = transcript_state();
    let envelope = json!({
        "op": "prepare_tool_batch",
        "request": request(vec![read_call(0)], &transcript, false),
        "env": { "launch_id": LAUNCH, "now": NOW, "approval_tokens": [] },
        "view": { "tables_present": true, "transcript": transcript, "transcript_summaries": [transcript], "authorities": null },
    });
    let output: Value = serde_json::from_str(&reduce_json(&envelope.to_string())).unwrap();
    assert_eq!(output["ok"], true);
    assert_eq!(output["commit"], true);
    let kinds: Vec<&str> = output["changes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["kind"].as_str().unwrap())
        .collect();
    assert_eq!(
        kinds,
        vec![
            "insert_ledger_row",
            "insert_dispatch_marker",
            "insert_batch"
        ]
    );
}

#[test]
fn runtime_mutations_freeze_zero_byte_manifests_under_conversation_approval() {
    use rish_agent_core::runtime_tools;
    for name in runtime_tools::NAMES {
        let arguments = match *name {
            "list_runtime_environments" => json!({}),
            "install_runtime_environment" => json!({"environment_id":"node-22"}),
            "run_program" => json!({"environment_id":"node-22","entry_path":"main.js","args":[]}),
            "start_runtime_service" => {
                json!({"environment_id":"node-22","entry_path":"server.js","args":[],"port":8080})
            }
            _ => json!({"service_id":TASK}),
        };
        let digest =
            arguments_sha256(Some(&json!(name)), Some(&json!(arguments.to_string()))).unwrap();
        let mutation = runtime_tools::is_mutation(name);
        let precondition = json!({"schema_version":1,"kind":name,"arguments_sha256":digest,
            "snapshot_sha256":if matches!(*name,"run_program"|"start_runtime_service") {json!("b".repeat(64))} else {Value::Null},
            "environment_sha256":if matches!(*name,"list_runtime_environments"|"stop_runtime_service") {Value::Null} else {json!("c".repeat(64))}});
        let call = json!({"call_index":0,"call_id":"runtime_call","name":name,"arguments_json":arguments.to_string(),"arguments_sha256":digest,
            "safe_summary_key":format!("agent.{name}"),"access":if mutation {"conversation_confirm"} else {"auto"},
            "precondition":precondition,"reserved_write_bytes":0});
        let transcript = transcript_state();
        let mut request = request(vec![call], &transcript, false);
        request["root"]["capabilities"] = json!(["file_read", "guest_service"]);
        let effect = reduce("prepare_tool_batch", &request, &env(), &view(&transcript)).unwrap();
        assert_eq!(effect.output["reserved_write_bytes"], 0);
        assert_eq!(
            effect.output["effect_gate"],
            if mutation { "closed" } else { "not_applicable" }
        );
        assert_eq!(
            effect.output["calls"][0]["approval_state"],
            if mutation { "pending" } else { "not_required" }
        );
        let batch = changes_of(&effect, |c| match c {
            Change::InsertBatch(record) => Some(record),
            _ => None,
        })[0];
        assert!(rish_agent_core::wal_state::batch_shape_v2(batch));
        if mutation {
            assert_eq!(batch["manifest_calls"][0]["mutation_kind"], *name);
            assert_eq!(batch["manifest_calls"][0]["content_bytes"], 0);
            assert!(rish_agent_core::ledger_batch::write_manifest_call_shape(
                Some(&batch["manifest_calls"][0])
            ));
        }
    }
}

#[test]
fn installed_conversation_grant_freezes_runtime_calls_without_new_tokens() {
    use rish_agent_core::tool_batch::{prepare_calls, prepare_finish};
    const GRANT: &str = "abababab-abab-4bab-8bab-abababababab";
    const CONVERSATION: &str = "55555555-5555-4555-8555-555555555555";
    let mut runtime_root = root();
    runtime_root["capabilities"] = json!(["file_read", "guest_service"]);
    let grant = json!({"schema_version":2,"grant_id":GRANT,"conversation_id":CONVERSATION,
        "workspace_id":runtime_root["workspace_id"],"project_id":null,"binding_revision":7,
        "root_fingerprint_sha256":ROOT_DIGEST,"tool_family":"guest_service","registry_version":3,"policy_version":"agent-v1",
        "issued_for":{"schema_version":1,"task_id":TASK,"attempt_id":"abababab-abab-4bab-8bab-babababababa"},"created_at":NOW});
    for name in [
        "install_runtime_environment",
        "run_program",
        "start_runtime_service",
    ] {
        let mut arguments = json!({"environment_id":"node-22"});
        if name != "install_runtime_environment" {
            arguments["entry_path"] = json!("main.js");
            arguments["args"] = json!([]);
        }
        if name == "start_runtime_service" {
            arguments["port"] = json!(8080);
        }
        let digest =
            arguments_sha256(Some(&json!(name)), Some(&json!(arguments.to_string()))).unwrap();
        let raw =
            json!({"call_id":"runtime-call","name":name,"arguments_json":arguments.to_string()});
        let messages = vec![json!({"role":"assistant","round_index":0,"tool_calls":[raw]})];
        let presentation = json!({"calls":[{"call_index":0,"call_id":"runtime-call","name":name,"arguments_sha256":digest}]});
        let authority = json!({"registry":{"tools":[{"schema_version":2,"name":name,"safe_summary_key":format!("agent.{name}"),"access":"conversation_confirm"}]}});
        let prepare_request =
            json!({"conversation_id":CONVERSATION,"root":runtime_root,"round_index":0});
        let grants = if name == "install_runtime_environment" {
            vec![]
        } else {
            vec![grant.clone()]
        };
        let analysis = prepare_calls(
            &prepare_request,
            &presentation,
            Some(&messages),
            &authority,
            &grants,
        );
        let precondition = json!({"schema_version":1,"kind":name,"arguments_sha256":digest,
            "snapshot_sha256":if name=="install_runtime_environment" {Value::Null} else {json!("c".repeat(64))},"environment_sha256":"d".repeat(64)});
        let finished = prepare_finish(
            &prepare_request,
            analysis["calls"].as_array().unwrap(),
            &[json!({"prepared":{"precondition":precondition,"reserved_write_bytes":0}})],
        );
        let transcript = transcript_state();
        let mut request = request(
            finished["prepared_calls"].as_array().unwrap().clone(),
            &transcript,
            true,
        );
        request["root"] = runtime_root.clone();
        let mut snapshot = view(&transcript);
        snapshot.rounds = vec![
            json!({"locator":{"schema_version":1,"task_id":TASK,"attempt_id":ATTEMPT,"round_id":ROUND,"round_index":0},
            "state":"completed","row_revision":3,"transcript_after":reference_of(&transcript),"terminal_kind":"tool_batch"}),
        ];
        let mut environment = env();
        if name != "install_runtime_environment" {
            environment.approval_tokens.clear();
        }
        let result = reduce("prepare_tool_batch", &request, &environment, &snapshot).unwrap();
        let public = &result.output["calls"][0];
        if name == "install_runtime_environment" {
            assert_eq!(public["approval_state"], "pending");
            assert!(public["approval_token"]["allowed_decisions"]
                .as_array()
                .unwrap()
                .contains(&json!("allow_conversation")));
        } else {
            assert_eq!(public["approval_state"], "bound");
            assert!(public["approval_token"].is_null());
            assert_eq!(public["approval_reference"], GRANT);
        }
        let batch = changes_of(&result, |c| match c {
            Change::InsertBatch(record) => Some(record),
            _ => None,
        })[0];
        let reloaded: Value = serde_json::from_slice(&canonical_json(batch).unwrap()).unwrap();
        assert!(rish_agent_core::wal_state::batch_shape_v2(&reloaded));
        for field in [
            "conversation_id",
            "workspace_id",
            "project_id",
            "binding_revision",
            "root_fingerprint_sha256",
            "tool_family",
            "registry_version",
            "policy_version",
        ] {
            let mut wrong = grant.clone();
            wrong[field] = if field == "registry_version" || field == "binding_revision" {
                json!(99)
            } else {
                json!("wrong")
            };
            let refused = prepare_calls(
                &prepare_request,
                &presentation,
                Some(&messages),
                &authority,
                &[wrong],
            );
            assert!(
                refused["calls"][0]["grant_reference"].is_null(),
                "{field} must require fresh approval"
            );
        }
        assert!(prepare_calls(
            &prepare_request,
            &presentation,
            Some(&messages),
            &authority,
            &[]
        )["calls"][0]["grant_reference"]
            .is_null());
    }
}

#[test]
fn assistant_tasks_require_v5_authority_and_freeze_real_approval_manifests() {
    use rish_agent_core::{assistant_tools, tool_registry};
    const CONVERSATION: &str = "55555555-5555-4555-8555-555555555555";
    for name in assistant_tools::NAMES {
        let arguments = match *name {
            "list_assistant_tasks" | "search_assistant_memory" => json!({}),
            "remember_assistant_memory" => {
                json!({"title":"Style","content":"Use concise Chinese replies.","kind":"preference"})
            }
            "forget_assistant_memory" => json!({"memory_id":TASK}),
            "create_assistant_task" => {
                json!({"title":"Daily review","instructions":"Review the requested notes."})
            }
            _ => json!({"task_id":TASK,"paused":true}),
        };
        let digest =
            arguments_sha256(Some(&json!(name)), Some(&json!(arguments.to_string()))).unwrap();
        let mutation = assistant_tools::is_mutation(name);
        let call = json!({"call_index":0,"call_id":"assistant_call","name":name,"arguments_json":arguments.to_string(),
            "arguments_sha256":digest,"safe_summary_key":format!("agent.{name}"),"access":if mutation {"conversation_confirm"} else {"auto"},
            "precondition":{"schema_version":1,"kind":name,"conversation_id":CONVERSATION,"arguments_sha256":digest,"expected_store_revision":0},
            "reserved_write_bytes":0,"grant_reference":null,"approval_preview":assistant_tools::approval_preview(name,&arguments)});
        let transcript = transcript_state();
        let mut request = request(vec![call], &transcript, true);
        let mut assistant_root = root();
        assistant_root["capabilities"] = json!(["file_read"]);
        request["root"] = assistant_root.clone();
        let mut current = view(&transcript);
        current.rounds = vec![
            json!({"locator":{"schema_version":1,"task_id":TASK,"attempt_id":ATTEMPT,"round_id":ROUND,"round_index":0},
            "state":"completed","row_revision":3,"transcript_after":reference_of(&transcript),"terminal_kind":"tool_batch"}),
        ];
        let authority = json!({"task_id":TASK,"attempt_id":ATTEMPT,"conversation_id":CONVERSATION,"root":assistant_root,
            "registry":tool_registry::registry_for_root_version(&assistant_root,false,5).unwrap(),"state":"prepared",
            "assistant_context":{"schema_version":1,"conversation_id":CONVERSATION,"profile_revision":0,"name":"Rish","notes":""},
            "policy":policy(),"reserved_write_bytes":0,"authority_revision":1,"transcript":reference_of(&transcript)});
        assert_eq!(
            reduce("prepare_tool_batch", &request, &env(), &current).unwrap_err(),
            StoreError::Conflict
        );
        current.authorities = Some(vec![Slotted {
            slot: 0,
            record: authority,
        }]);
        current.authorities_present = true;
        let prepared = reduce("prepare_tool_batch", &request, &env(), &current).unwrap();
        let public = &prepared.output["calls"][0];
        assert_eq!(
            prepared.output["batch_kind"],
            if mutation {
                "write_batch"
            } else {
                "read_only_batch"
            }
        );
        assert_eq!(prepared.output["reserved_write_bytes"], 0);
        assert_eq!(
            prepared.output["effect_gate"],
            if mutation { "closed" } else { "not_applicable" }
        );
        assert_eq!(
            public["approval_state"],
            if mutation { "pending" } else { "not_required" }
        );
        if mutation {
            assert_eq!(public["approval_token"]["registry_version"], 5);
            assert_eq!(
                public["approval_token"]["allowed_decisions"],
                json!(["denied", "allow_once", "allow_conversation", "cancelled"])
            );
            let batch = changes_of(&prepared, |change| match change {
                Change::InsertBatch(value) => Some(value),
                _ => None,
            })[0];
            assert!(rish_agent_core::wal_state::batch_shape_v2(batch));
            assert_eq!(batch["manifest_calls"][0]["mutation_kind"], *name);
            let row = changes_of(&prepared, |change| match change {
                Change::InsertLedgerRow(value) => Some(value),
                _ => None,
            })[0];
            let marker = changes_of(&prepared, |change| match change {
                Change::InsertDispatchMarker(value) => Some(value),
                _ => None,
            })[0];
            let mut gate_view = current.clone();
            gate_view.batches = vec![Slotted {
                slot: 0,
                record: batch.clone(),
            }];
            gate_view.ledger_rows = vec![row.clone()];
            gate_view.dispatch = vec![marker.clone()];
            let gate = json!({"schema_version":2,"task_id":TASK,"attempt_id":ATTEMPT,"round_id":ROUND,"round_index":0,
                "expected_batch_revision":batch["batch_revision"],"manifest_sha256":batch["manifest_sha256"],"expected_effect_gate":"closed"});
            assert_eq!(
                reduce("open_effect_gate", &gate, &env(), &gate_view).unwrap_err(),
                StoreError::Conflict
            );
        }
        let mut wrong_version = current.clone();
        wrong_version.authorities.as_mut().unwrap()[0].record["registry"]["registry_version"] =
            json!(4);
        assert_eq!(
            reduce("prepare_tool_batch", &request, &env(), &wrong_version).unwrap_err(),
            StoreError::Conflict
        );
        let mut wrong_scope = request.clone();
        wrong_scope["calls"][0]["precondition"]["conversation_id"] = json!(TASK);
        assert_eq!(
            reduce("prepare_tool_batch", &wrong_scope, &env(), &current).unwrap_err(),
            StoreError::Conflict
        );
        if mutation {
            let mut bypass = request.clone();
            bypass["calls"][0]["access"] = json!("auto");
            assert_eq!(
                reduce("prepare_tool_batch", &bypass, &env(), &current).unwrap_err(),
                StoreError::Conflict
            );
        }
    }
}
