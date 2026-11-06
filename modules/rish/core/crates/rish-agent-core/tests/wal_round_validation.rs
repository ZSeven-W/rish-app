//! Stored V3 rows need the complete receipt invariant, not only a V2 projection.
use rish_agent_core::wal_state::reduce_json;
use serde_json::{json, Value};

const TASK: &str = "11111111-1111-4111-8111-111111111111";
const ATTEMPT: &str = "22222222-2222-4222-8222-222222222222";
const ROUND: &str = "33333333-3333-4333-8333-333333333333";
const PROVIDER: &str = "44444444-4444-4444-8444-444444444444";
const MODEL: &str = "55555555-5555-4555-8555-555555555555";

fn fixture() -> (Value, Value) {
    let model = format!("custom:{PROVIDER}:{MODEL}");
    let harness = format!("custom-{PROVIDER}");
    let reference = json!({"schema_version":1,"transcript_ref":TASK,"generation":1,
        "transcript_sha256":"a".repeat(64),"transcript_bytes":20});
    let row = json!({
        "schema_version":3,
        "locator":{"schema_version":1,"task_id":TASK,"attempt_id":ATTEMPT,"round_id":ROUND,"round_index":0},
        "row_revision":3,"root_fingerprint_sha256":"a".repeat(64),"binding_revision":1,
        "request_sha256":"b".repeat(64),"transcript_before":reference,"launch_attempt":1,
        "state":"completed","owner":null,"failure_code":null,
        "completion_receipt":{"schema_version":1,"transport_schema_version":3,
            "turn_id":TASK,"attempt_id":ATTEMPT,"round_id":ROUND,"round_index":0,
            "provider_request_id":"request-1","provider_response_id":"response-1",
            "requested_model":model,"model":model,"harness_id":harness,"thinking_mode":"off",
            "finish_reason":"stop","latency_ms":1,"visible_history_sha256":"c".repeat(64),
            "model_input_sha256":"d".repeat(64),"request_body_sha256":"e".repeat(64),
            "project_context_receipt":null,"provider_configuration":{"host_validated":true}},
        "transcript_after":reference,"calls":[],"batch_class":null,
        "executable_call_count":0,"denied_call_count":0,"terminal_kind":"final",
        "created_at":"2026-10-29T00:00:00.000Z","updated_at":"2026-10-29T00:00:01.000Z"
    });
    let env = json!({"supported_models":[model],"receipt_harness_id":harness,"receipt_binding_valid":true});
    (row, env)
}

fn valid(row: &Value, env: &Value) -> bool {
    let reply: Value = serde_json::from_str(&reduce_json(
        &json!({
            "op":"round_v3_valid","value":row,"env":env
        })
        .to_string(),
    ))
    .unwrap();
    reply["ok"] == true && reply["valid"] == true
}

#[test]
fn complete_rows_require_historical_membership_and_a_valid_captured_binding() {
    let (row, env) = fixture();
    assert!(valid(&row, &env));
    let mut rejected_binding = env.clone();
    rejected_binding["receipt_binding_valid"] = json!(false);
    assert!(!valid(&row, &rejected_binding));
    let mut unknown_model = env.clone();
    unknown_model["supported_models"] = json!([]);
    assert!(!valid(&row, &unknown_model));
    let mut wrong_harness = env.clone();
    wrong_harness["receipt_harness_id"] = json!("codex");
    assert!(!valid(&row, &wrong_harness));
}

#[test]
fn projection_is_insufficient_for_a_tampered_receipt() {
    let (mut row, env) = fixture();
    row["completion_receipt"]["requested_model"] = json!("forged-model");
    let projection: Value = serde_json::from_str(&reduce_json(
        &json!({
            "op":"round_v3","value":row
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(projection["valid"], true);
    assert!(!valid(&row, &env));
    row["completion_receipt"]["requested_model"] = row["completion_receipt"]["model"].clone();
    row["completion_receipt"]
        .as_object_mut()
        .unwrap()
        .remove("provider_configuration");
    assert!(!valid(&row, &env));
    let mut no_harness = env.clone();
    no_harness
        .as_object_mut()
        .unwrap()
        .remove("receipt_harness_id");
    row["completion_receipt"]
        .as_object_mut()
        .unwrap()
        .remove("harness_id");
    assert!(!valid(&row, &no_harness));
}
