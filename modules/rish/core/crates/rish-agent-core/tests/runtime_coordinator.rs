//! Parity with the Objective-C++ coordinator's settle path.
//! `runtime-coordinator-golden.json` was recorded from
//! `AgentRuntimeCoordinator.mm` by running the whole native suite with
//! finalize, discard and interrupt instrumented, while they still decided
//! everything themselves. Each step is one command against one committed WAL
//! state, with the facts the typed stores answered with and the timestamps the
//! coordinator's own clock handed out.

use rish_agent_core::runtime_coordinator::{
    already_missing_commit, cleanup_outbox_proof, exact_discarded_cleanup,
    finalize_conflict_commit, finalize_transaction, interruption_proof, residue_discard,
    settle_authority_state, Settlement,
};
use serde_json::{json, Map, Value};
use std::path::PathBuf;

/// The arrays finalize and the residue discard rewrite.
const OWNED: &[&str] = &[
    "authorities",
    "transcripts",
    "cleanup",
    "rounds",
    "ledger",
    "reservations",
    "batches",
    "denied_calls",
    "dispatch",
    "operations",
    "operation_results",
];

const POOLED: &[&str] = &[
    "authorities",
    "operations",
    "operation_results",
    "transcripts",
    "rounds",
    "ledger",
    "reservations",
    "cleanup",
    "dispatch",
    "batches",
    "denied_calls",
];

struct Golden {
    values: Vec<Value>,
    states: Vec<Value>,
    steps: Vec<Value>,
}

fn load() -> Golden {
    let path: PathBuf = [
        env!("CARGO_MANIFEST_DIR"),
        "..",
        "..",
        "fixtures",
        "runtime-coordinator-golden.json",
    ]
    .iter()
    .collect();
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("read {}: {error}", path.display()));
    let document: Value = serde_json::from_str(&text).expect("parse golden");
    Golden {
        values: document["values"].as_array().expect("values").clone(),
        states: document["states"].as_array().expect("states").clone(),
        steps: document["steps"].as_array().expect("steps").clone(),
    }
}

impl Golden {
    fn value(&self, index: &Value) -> Value {
        self.values[index.as_u64().expect("value index") as usize].clone()
    }

    fn state(&self, index: &Value) -> Option<Value> {
        let index = index.as_u64()? as usize;
        let encoded = self.states[index].as_object().expect("state object");
        let mut state = Map::new();
        for (key, value) in encoded {
            if POOLED.contains(&key.as_str()) {
                let rows: Vec<Value> = value
                    .as_array()
                    .expect("row indices")
                    .iter()
                    .map(|index| self.value(index))
                    .collect();
                state.insert(key.clone(), Value::Array(rows));
            } else {
                state.insert(key.clone(), value.clone());
            }
        }
        Some(Value::Object(state))
    }

    fn fact(&self, step: &Value, key: &str) -> Option<Value> {
        step["facts"].get(key).map(|index| self.value(index))
    }
}

fn timestamp(step: &Value, index: usize) -> String {
    step["timestamps"]
        .as_array()
        .and_then(|stamps| stamps.get(index))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
}

fn owned(state: &Value) -> Value {
    let mut map = Map::new();
    for key in OWNED {
        map.insert(
            (*key).to_string(),
            state.get(*key).cloned().unwrap_or(Value::Null),
        );
    }
    Value::Object(map)
}

/// The committed state the host would be left with, ignoring the operation
/// relation's own rows: those are the WAL commit's business and the WAL
/// transaction golden already locks them.
fn applied(before: &Value, changes: &Map<String, Value>) -> Value {
    let mut state = before.as_object().cloned().expect("state");
    for (key, value) in changes {
        state.insert(key.clone(), value.clone());
    }
    Value::Object(state)
}

fn without_operations(state: &Value) -> Value {
    let mut map = state.as_object().cloned().expect("state");
    map.remove("operations");
    map.remove("operation_results");
    Value::Object(map)
}

#[test]
fn every_recorded_settlement_decides_exactly_as_the_native_coordinator_did() {
    let golden = load();
    assert!(golden.steps.len() >= 29, "the golden lost steps");
    let mut replayed = 0usize;
    for (index, step) in golden.steps.iter().enumerate() {
        let command = step["command"].as_str().expect("command");
        let request = golden.value(&step["request"]);
        let Some(before) = golden.state(&step["before"]) else {
            continue;
        };
        let after = golden.state(&step["after"]).expect("after");
        let Some(started) = golden.fact(step, "started") else {
            // The step never reached its transaction: a proof or an authority
            // check refused it first, and nothing was written.
            // The operation relation may still have started this command's own
            // operation row; the WAL transaction golden locks that.
            assert_eq!(
                without_operations(&owned(&before)),
                without_operations(&owned(&after)),
                "step {index} ({command}): refused before the transaction, so nothing may change"
            );
            replayed += 1;
            continue;
        };
        // Both residue commands re-prove the authority inside the transaction
        // before they discard anything, and an attempt whose authority is
        // already gone is closed as already_missing instead.
        if matches!(command, "discardAgentAttempt" | "interruptAgentAttempt") {
            let kind = if command == "discardAgentAttempt" {
                "discard"
            } else {
                "interrupt"
            };
            let authority = settle_authority_state(&before, &request, kind);
            if authority["authority"].is_null() {
                let outbox_proves = golden
                    .fact(step, "cleanup_outbox_session")
                    .is_none_or(|session| cleanup_outbox_proof(&session, &request));
                let closes = exact_discarded_cleanup(&before, &request) && outbox_proves;
                if closes {
                    let operation_kind = if kind == "discard" {
                        "discard_agent_attempt"
                    } else {
                        "interrupt_agent_attempt"
                    };
                    assert_eq!(
                        step["error"],
                        Value::Null,
                        "step {index} ({command}): closed"
                    );
                    assert_eq!(
                        already_missing_commit(&request, &started, operation_kind)["output"],
                        golden.value(&step["output"]),
                        "step {index} ({command}): already-missing output"
                    );
                } else {
                    assert_eq!(
                        step["error"],
                        json!(3),
                        "step {index} ({command}): nothing left to close is a conflict"
                    );
                }
                assert_eq!(
                    without_operations(&owned(&before)),
                    without_operations(&owned(&after)),
                    "step {index} ({command}): closing writes no rows"
                );
                replayed += 1;
                continue;
            }
            if authority["settles"] != json!(true) {
                assert_eq!(
                    step["error"],
                    json!(3),
                    "step {index} ({command}): an unsettleable authority is a conflict"
                );
                assert_eq!(
                    without_operations(&owned(&before)),
                    without_operations(&owned(&after)),
                    "step {index} ({command}): a refused settlement writes nothing"
                );
                replayed += 1;
                continue;
            }
        }
        let settlement = match command {
            "finalizeAgentAttempt" => finalize_transaction(
                &before,
                &request,
                &started,
                &timestamp(step, 0),
                &timestamp(step, 1),
            ),
            "discardAgentAttempt" => residue_discard(
                &before,
                &request,
                "discard_agent_attempt",
                &json!([]),
                &started,
                &timestamp(step, 0),
            ),
            "interruptAgentAttempt" => residue_discard(
                &before,
                &request,
                "interrupt_agent_attempt",
                &json!([
                    "undispatched_intents",
                    "create_cleanup_row",
                    "unsettled_rounds"
                ]),
                &started,
                &timestamp(step, 0),
            ),
            other => panic!("step {index}: unknown command {other}"),
        };
        match settlement {
            Settlement::Settle {
                changes, output, ..
            } => {
                assert_eq!(
                    step["error"],
                    Value::Null,
                    "step {index} ({command}): settled where the native refused"
                );
                assert_eq!(
                    output,
                    golden.value(&step["output"]),
                    "step {index} ({command}): output"
                );
                assert_eq!(
                    without_operations(&owned(&applied(&before, &changes))),
                    without_operations(&owned(&after)),
                    "step {index} ({command}): committed rows"
                );
            }
            Settlement::Error(error) => {
                // A refused finalize does not fail the call: it commits the
                // conflict as this operation's result, so a retry sees the
                // same answer instead of racing again.
                let recorded = golden.value(&step["output"]);
                if command == "finalizeAgentAttempt" && recorded["status"] == json!("conflict") {
                    assert_eq!(
                        finalize_conflict_commit(&request, &started, "E_AGENT_CONFLICT")["output"],
                        recorded,
                        "step {index}: committed conflict"
                    );
                } else {
                    assert_eq!(
                        step["error"],
                        json!(u64::from(error.code())),
                        "step {index} ({command}): error"
                    );
                }
                assert_eq!(
                    without_operations(&owned(&before)),
                    without_operations(&owned(&after)),
                    "step {index} ({command}): a refused settlement writes nothing"
                );
            }
        }
        replayed += 1;
    }
    assert_eq!(replayed, golden.steps.len(), "every step must replay");
}

#[test]
fn a_recorded_interruption_proof_answers_as_it_did() {
    let golden = load();
    let mut checked = 0usize;
    for step in &golden.steps {
        if step["command"] != json!("interruptAgentAttempt") {
            continue;
        }
        let (Some(session), Some(facts)) = (
            golden.fact(step, "session"),
            golden.fact(step, "session_facts"),
        ) else {
            continue;
        };
        let request = golden.value(&step["request"]);
        // A step that got as far as its transaction had a session that proved
        // the interruption.
        if golden.fact(step, "started").is_some() {
            assert!(interruption_proof(&session, &facts, &request));
            let mut with_drafts = session.clone();
            with_drafts["schema_version"] = json!(10);
            with_drafts["composer_drafts"] = json!({"new-draft":"unsent"});
            assert!(interruption_proof(&with_drafts, &facts, &request));
            with_drafts["schema_version"] = json!(11);
            assert!(!interruption_proof(&with_drafts, &facts, &request));
            checked += 1;
        }
    }
    assert!(checked > 0, "no interruption proof was exercised");
}

#[test]
fn a_cleanup_row_only_closes_an_operation_when_it_is_discarded_and_exact() {
    let state = json!({ "cleanup": [{
        "cleanup_id": "c1", "status": "discarded", "attempt_id": "a1",
        "transcript_ref": "t1", "transcript_sha256": "s1", "cleanup_owner": "k1",
    }]});
    let request = json!({
        "cleanup_id": "c1", "attempt_id": "a1", "transcript_ref": "t1",
        "transcript_sha256": "s1", "task_id": "k1",
    });
    assert!(exact_discarded_cleanup(&state, &request));
    let pending = json!({ "cleanup": [{
        "cleanup_id": "c1", "status": "pending", "attempt_id": "a1",
        "transcript_ref": "t1", "transcript_sha256": "s1", "cleanup_owner": "k1",
    }]});
    assert!(!exact_discarded_cleanup(&pending, &request));
}

#[test]
fn a_discard_only_settles_a_cleanup_pending_authority() {
    let state = json!({ "authorities": [{
        "task_id": "k1", "attempt_id": "a1", "conversation_id": "c1",
        "state": "prepared", "cleanup_id": Value::Null,
    }]});
    let request =
        json!({ "task_id": "k1", "attempt_id": "a1", "conversation_id": "c1", "cleanup_id": "x1" });
    assert_eq!(
        settle_authority_state(&state, &request, "discard")["settles"],
        json!(false)
    );
    // An interrupt is exactly the command that may clear a still-prepared
    // authority whose writer died.
    assert_eq!(
        settle_authority_state(&state, &request, "interrupt")["settles"],
        json!(true)
    );
}

#[test]
fn query_accepts_settled_tool_transcript_only_with_committed_old_handle() {
    use rish_agent_core::runtime_coordinator::query_attempt_base_conflict;
    let old = json!({"schema_version":1,"transcript_ref":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","generation":1,"transcript_sha256":"a".repeat(64),"transcript_bytes":100});
    let mut newer = old.clone();
    newer["generation"] = json!(2);
    newer["transcript_sha256"] = json!("b".repeat(64));
    newer["transcript_bytes"] = json!(200);
    let request = json!({"conversation_id":"conversation","expected_transcript":old,"expected_root_fingerprint_sha256":"c".repeat(64),"expected_workspace_binding_revision":1});
    let base = json!({"conversation_id":"conversation","transcript":newer,"root":{"root_fingerprint_sha256":"c".repeat(64),"workspace_binding_revision":1}});
    let proof = json!({"journal_transcript":old});
    assert!(
        query_attempt_base_conflict(&base, &request, &proof).is_some(),
        "Committed provenance alone cannot replace the native WAL ancestry proof"
    );
    assert!(
        query_attempt_base_conflict(&base, &request, &json!({})).is_some(),
        "No committed provenance cannot admit a stale handle"
    );
    let mut forged = request.clone();
    forged["expected_transcript"]["transcript_sha256"] = json!("d".repeat(64));
    assert!(query_attempt_base_conflict(&base, &forged, &proof).is_some());
    let mut mismatch = base.clone();
    mismatch["transcript"]["generation"] = json!(1);
    assert!(
        query_attempt_base_conflict(&mismatch, &request, &proof).is_some(),
        "same generation with another digest is not advancement"
    );
    mismatch = base.clone();
    mismatch["transcript"]["transcript_ref"] = json!("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb");
    assert!(query_attempt_base_conflict(&mismatch, &request, &proof).is_some());
    mismatch = base.clone();
    mismatch["root"]["workspace_binding_revision"] = json!(2);
    assert!(query_attempt_base_conflict(&mismatch, &request, &proof).is_some());
}
