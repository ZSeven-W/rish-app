//! Receipt-first assistant mutation recovery after the native process dies.

use rish_agent_core::canonical::{canonical_json, hash_json};
use rish_agent_core::ledger_ops::{reduce, Change, Env, View};
use rish_agent_core::schema::{arguments_sha256, idempotency_key_for_locator};
use rish_agent_core::store::StoreError;
use serde_json::{json, Map, Value};

const TASK: &str = "11111111-1111-4111-8111-111111111111";
const ATTEMPT: &str = "22222222-2222-4222-8222-222222222222";
const ROUND: &str = "33333333-3333-4333-8333-333333333333";
const LAUNCH: &str = "44444444-4444-4444-8444-444444444444";
const NATIVE: &str = "55555555-5555-4555-8555-555555555555";
const TRANSCRIPT_REF: &str = "88888888-8888-4888-8888-888888888888";
const ROOT_DIGEST: &str = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1";
const NOW: &str = "2023-11-14T22:13:20.000Z";
const LATER: &str = "2023-11-14T22:13:21.000Z";
const READ_ARGUMENTS: &str = "{\"path\":\"README.md\"}";

fn env() -> Env {
    Env {
        launch_id: LAUNCH.to_string(),
        now: LATER.to_string(),
        attempt_row_count: 0,
    }
}

fn owner() -> Value {
    json!({
        "schema_version": 1, "task_id": TASK, "launch_id": LAUNCH, "native_task_id": NATIVE,
        "owner_generation": 1, "heartbeat_at": NOW,
    })
}

fn transcript_state(messages: Vec<Value>, generation: u64) -> Value {
    let input = json!({
        "schema_version": 1, "transcript_ref": TRANSCRIPT_REF, "attempt_id": ATTEMPT,
        "root_fingerprint_sha256": ROOT_DIGEST, "generation": generation, "messages": messages,
    });
    let bytes = canonical_json(&input).unwrap().len() as u64;
    let digest = hash_json("agent-transcript", &input).unwrap();
    json!({
        "schema_version": 1, "transcript_ref": TRANSCRIPT_REF, "attempt_id": ATTEMPT, "state": "open",
        "root_fingerprint_sha256": ROOT_DIGEST, "generation": generation, "transcript_sha256": digest,
        "transcript_bytes": bytes, "messages": input["messages"], "created_at": NOW, "updated_at": NOW,
    })
}

fn reference_of(transcript: &Value) -> Value {
    json!({
        "schema_version": 1, "transcript_ref": TRANSCRIPT_REF, "generation": transcript["generation"],
        "transcript_sha256": transcript["transcript_sha256"], "transcript_bytes": transcript["transcript_bytes"],
    })
}

fn locator(call_index: u64, call_id: &str, arguments_digest: &str) -> Value {
    let mut locator = json!({
        "schema_version": 2, "task_id": TASK, "attempt_id": ATTEMPT, "round_id": ROUND, "round_index": 0,
        "call_index": call_index, "call_id": call_id, "idempotency_key": "0".repeat(64),
    });
    let key = idempotency_key_for_locator(
        Some(&locator),
        Some(&json!(ROOT_DIGEST)),
        Some(&json!(arguments_digest)),
    )
    .unwrap();
    locator["idempotency_key"] = json!(key);
    locator
}

fn read_intent(transcript: &Value) -> Value {
    let digest = arguments_sha256(Some(&json!("read_file")), Some(&json!(READ_ARGUMENTS))).unwrap();
    json!({
        "schema_version": 2, "locator": locator(0, "call_0", &digest), "row_revision": 1,
        "root_fingerprint_sha256": ROOT_DIGEST, "binding_revision": 7, "transcript_before": reference_of(transcript),
        "name": "read_file", "arguments_sha256": digest,
        "precondition": { "schema_version": 1, "kind": "read_file", "source_revision": "rev-1" },
        "reserved_write_bytes": 0, "state": "intent", "owner": null, "settled_facts": null,
        "transcript_after": null, "receipt": null, "created_at": NOW, "updated_at": NOW,
    })
}

fn marker(row: &Value, state: &str) -> Value {
    json!({ "schema_version": 1, "kind": "execution", "locator": row["locator"], "dispatch_state": state })
}

fn args(pairs: Value) -> Map<String, Value> {
    pairs.as_object().unwrap().clone()
}

fn view(row: Option<Value>, dispatch: Vec<Value>, transcript: Option<Value>) -> View {
    View {
        row,
        dispatch,
        transcript,
        authorities: None,
        arg_owner_alive: true,
        row_owner_alive: true,
        ..Default::default()
    }
}

fn replaced_row(effect: &rish_agent_core::ledger_ops::Effect) -> Value {
    effect
        .changes
        .iter()
        .find_map(|change| match change {
            Change::ReplaceLedgerRow(row) | Change::InsertLedgerRow(row) => Some(row.clone()),
            _ => None,
        })
        .expect("row change")
}

#[test]
fn orphaned_assistant_mutation_settles_from_receipt_once_without_live_owner() {
    use rish_agent_core::{
        assistant_tools, execution_ledger::ledger_row, tool_execution::recover_plan,
    };
    for name in [
        "create_assistant_task",
        "update_assistant_task",
        "remember_assistant_memory",
        "forget_assistant_memory",
    ] {
        for status in ["running", "cancel_requested"] {
            let transcript = transcript_state(vec![], 0);
            let arguments = if name == "create_assistant_task" {
                json!({"title":"Review","instructions":"Review the requested notes."})
            } else if name == "remember_assistant_memory" {
                json!({"title":"Style","content":"Prefer concise replies.","kind":"preference"})
            } else if name == "forget_assistant_memory" {
                json!({"memory_id":TASK})
            } else {
                json!({"task_id":TASK,"paused":true})
            };
            let digest =
                arguments_sha256(Some(&json!(name)), Some(&json!(arguments.to_string()))).unwrap();
            let mut row = read_intent(&transcript);
            row["name"] = json!(name);
            row["arguments_sha256"] = json!(digest);
            row["locator"] = locator(0, "assistant_call", &digest);
            row["state"] = json!(status);
            row["owner"] = owner();
            row["precondition"] = json!({"schema_version":1,"kind":name,"conversation_id":NATIVE,"arguments_sha256":digest,"expected_store_revision":7});
            assert!(ledger_row(&row));
            let payload = if name.ends_with("_memory") {
                json!({"schema_version":1,"memory_id":TASK,"store_revision":8})
            } else {
                json!({"schema_version":1,"task_id":TASK,"store_revision":8})
            };
            let effect = json!({"schema_version":1,"status":"ok","feedback":assistant_tools::feedback_string(name,payload.clone()).unwrap(),
                "settled_facts":{"schema_version":1,"kind":name,"conversation_id":NATIVE,"arguments_sha256":digest,
                    "locator_sha256":hash_json("assistant-tool-locator",&row["locator"]).unwrap(),"store_revision":8,
                    "payload_sha256":hash_json("assistant-tool-payload",&payload).unwrap()},"truncated":false,"effect_may_have_occurred":true});
            let request = json!({"operation_id":NATIVE,"task_id":TASK,"attempt_id":ATTEMPT,"round_id":ROUND,"round_index":0,
                "call_index":0,"call_id":"assistant_call","idempotency_key":row["locator"]["idempotency_key"],"name":name,
                "conversation_id":NATIVE,"arguments_sha256":digest,"approval_reference":TASK});
            let plan =
                recover_plan(&request, &row, &json!({"status":"settled","effect":effect})).unwrap();
            assert_eq!(plan["settle"]["cas"]["expected_launch_id"], LAUNCH);
            let mut current = view(
                Some(row.clone()),
                vec![marker(&row, "dispatched")],
                Some(transcript),
            );
            current.row_owner_alive = false;
            current.arg_owner_alive = false;
            let settled =
                reduce("settle", &args(plan["settle"].clone()), &env(), &current).unwrap();
            let final_row = replaced_row(&settled);
            assert!(ledger_row(&final_row));
            assert_eq!(final_row["receipt"]["outcome"], "ok");
            assert_eq!(final_row["settled_facts"], effect["settled_facts"]);
            let next_transcript = settled
                .changes
                .iter()
                .find_map(|change| match change {
                    Change::ReplaceTranscript(value) => Some(value.clone()),
                    _ => None,
                })
                .unwrap();
            assert_eq!(next_transcript["messages"].as_array().unwrap().len(), 1);
            assert_eq!(
                next_transcript["messages"][0]["content"],
                effect["feedback"]
            );
            current.row = Some(final_row);
            current.transcript = Some(next_transcript);
            assert_eq!(
                reduce("settle", &args(plan["settle"].clone()), &env(), &current).unwrap_err(),
                StoreError::Conflict
            );
        }
    }
}

#[test]
fn native_wal_assistant_row_gate_uses_complete_core_ledger_validation() {
    let transcript = transcript_state(vec![], 0);
    let mut row = read_intent(&transcript);
    let name = "create_assistant_task";
    let digest = arguments_sha256(
        Some(&json!(name)),
        Some(&json!(
            "{\"title\":\"Review\",\"instructions\":\"Review notes.\"}"
        )),
    )
    .unwrap();
    row["name"] = json!(name);
    row["arguments_sha256"] = json!(digest);
    row["locator"] = locator(0, "assistant_call", &digest);
    row["precondition"] = json!({"schema_version":1,"kind":name,"conversation_id":NATIVE,"arguments_sha256":digest,"expected_store_revision":0});
    let valid = |row: &Value| {
        let output: Value = serde_json::from_str(&rish_agent_core::wal_state::reduce_json(
            &json!({"op":"assistant_ledger_row","value":row}).to_string(),
        ))
        .unwrap();
        assert_eq!(output["ok"], true);
        output["valid"] == true
    };
    assert!(valid(&row));
    assert!(!valid(&read_intent(&transcript)));
    let mut forged = row.clone();
    forged["precondition"]["extra"] = json!(true);
    assert!(!valid(&forged));
    forged = row.clone();
    forged["arguments_sha256"] = json!("f".repeat(64));
    assert!(!valid(&forged));
    forged = row.clone();
    forged["state"] = json!("settled");
    assert!(!valid(&forged));
    forged = row;
    forged["locator"]["call_id"] = json!("different_call");
    assert!(!valid(&forged));
}
