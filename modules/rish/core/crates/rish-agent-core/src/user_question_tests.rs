use super::*;
use crate::canonical::{hash_bytes, hash_json};
use crate::ledger_ops::{self, Change, Env, View};
use crate::schema::idempotency_key_for_locator;

const TASK: &str = "11111111-1111-4111-8111-111111111111";
const ATTEMPT: &str = "22222222-2222-4222-8222-222222222222";
const ROUND: &str = "33333333-3333-4333-8333-333333333333";
const CONVERSATION: &str = "44444444-4444-4444-8444-444444444444";
const NOW: &str = "2026-10-16T00:00:00.000Z";

fn question() -> Value {
    json!({"question":"选择目标平台","input_mode":"options","options":[
        {"id":"ios","label":"iPhone 和 iPad"},{"id":"android","label":"Android"}]})
}

#[test]
fn strict_questions_and_structured_answers() {
    let q = question();
    assert!(arguments_valid(&q));
    assert!(response_valid(
        &q,
        &json!({"status":"answered","answer":"ios"})
    ));
    assert!(!response_valid(
        &q,
        &json!({"status":"answered","answer":"unknown"})
    ));
    assert!(!response_valid(
        &q,
        &json!({"status":"cancelled","answer":"ios"})
    ));
    assert!(response_valid(
        &q,
        &json!({"status":"cancelled","answer":null})
    ));
    let free = json!({"question":"说明需求","input_mode":"free_text","options":[]});
    assert!(response_valid(
        &free,
        &json!({"status":"answered","answer":"中文\n第二行"})
    ));
    assert!(!response_valid(
        &free,
        &json!({"status":"answered","answer":"界".repeat(1334)})
    ));
    assert!(!response_valid(
        &free,
        &json!({"status":"answered","answer":"   "})
    ));
    for key in ["question", "input_mode", "options"] {
        let mut malformed = q.clone();
        malformed.as_object_mut().unwrap().remove(key);
        assert!(!arguments_valid(&malformed));
    }
    let mut duplicate = q.clone();
    duplicate["options"][1]["id"] = json!("ios");
    assert!(!arguments_valid(&duplicate));
    let mut extra = q.clone();
    extra["tool"] = json!("read_file");
    assert!(!arguments_valid(&extra));
}

fn fixture() -> (Value, Value, Value) {
    let q = question();
    let args_sha =
        crate::schema::arguments_sha256(Some(&json!(NAME)), Some(&json!(q.to_string()))).unwrap();
    let digest = "a".repeat(64);
    let messages = json!([{ "schema_version":1,"role":"assistant","round_index":0,"content":"",
        "tool_calls":[{"call_id":"question_0","name":NAME,"arguments_json":q.to_string()}]}]);
    let canonical = json!({"schema_version":1,"transcript_ref":CONVERSATION,"attempt_id":ATTEMPT,
        "root_fingerprint_sha256":digest,"generation":1,"messages":messages});
    let bytes = canonical_json(&canonical).unwrap().len();
    let transcript_sha = hash_json("agent-transcript", &canonical).unwrap();
    let transcript = json!({"schema_version":1,"transcript_ref":CONVERSATION,"attempt_id":ATTEMPT,
        "root_fingerprint_sha256":digest,"generation":1,"messages":messages,"state":"open",
        "transcript_sha256":transcript_sha,"transcript_bytes":bytes,"created_at":NOW,"updated_at":NOW});
    let reference = json!({"schema_version":1,"transcript_ref":CONVERSATION,"generation":1,
        "transcript_sha256":transcript_sha,"transcript_bytes":bytes});
    let mut locator = json!({"schema_version":2,"task_id":TASK,"attempt_id":ATTEMPT,"round_id":ROUND,
        "round_index":0,"call_index":0,"call_id":"question_0","idempotency_key":"0".repeat(64)});
    locator["idempotency_key"] = json!(idempotency_key_for_locator(
        Some(&locator),
        Some(&json!(digest)),
        Some(&json!(args_sha))
    )
    .unwrap());
    let row = json!({"schema_version":2,"locator":locator,"row_revision":1,"root_fingerprint_sha256":digest,
        "binding_revision":1,"transcript_before":reference,"name":NAME,"arguments_sha256":args_sha,
        "precondition":prepared(&q).unwrap()["precondition"],"reserved_write_bytes":0,
        "state":"intent","owner":null,"settled_facts":null,"transcript_after":null,"receipt":null,
        "created_at":NOW,"updated_at":NOW});
    let request = json!({"schema_version":2,"operation_id":"55555555-5555-4555-8555-555555555555",
      "controller_cas":{"schema_version":1,"task_id":TASK,"conversation_id":CONVERSATION,"attempt_id":ATTEMPT,
        "expected_controller_generation":1,"expected_journal_revision":1,"expected_session_generation":1,"expected_session_sha256":digest},
      "committed_checkpoint":{"schema_version":1,"journal_revision":1,"session_generation":1,"session_sha256":digest},
      "task_id":TASK,"conversation_id":CONVERSATION,"attempt_id":ATTEMPT,"round_id":ROUND,"round_index":0,
      "batch_kind":"read_only_batch","manifest_sha256":null,"expected_batch_revision":1,
      "call_index":0,"call_id":"question_0","name":NAME,"arguments_sha256":args_sha,
      "idempotency_key":locator["idempotency_key"],"expected_execution_revision":1,"transcript":reference,
      "root":{"schema_version":1,"kind":"workspace","workspace_id":TASK,"workspace_binding_revision":1,
        "project_id":null,"root_fingerprint_sha256":digest,"capabilities":["file_read","file_write"]},
      "approval_reference":null,"user_response":{"status":"answered","answer":"ios"}});
    (request, row, transcript)
}

#[test]
fn stale_responses_and_tampered_questions_never_settle() {
    let (request, row, _) = fixture();
    let sha = json!("b".repeat(64));
    assert!(settlement(&request, &row, &question(), &sha).is_ok());
    for key in ["call_id", "attempt_id", "round_id", "idempotency_key"] {
        let mut stale = request.clone();
        stale[key] = json!("different");
        assert!(settlement(&stale, &row, &question(), &sha).is_err());
    }
    let mut stale = request.clone();
    stale["expected_execution_revision"] = json!(2);
    assert!(settlement(&stale, &row, &question(), &sha).is_err());
    let mut changed = question();
    changed["question"] = json!("换了一个问题");
    assert!(settlement(&request, &row, &changed, &sha).is_err());
}

#[test]
fn answer_and_cancellation_atomically_commit_existing_receipt_and_transcript() {
    for response in [
        json!({"status":"answered","answer":"ios"}),
        json!({"status":"cancelled","answer":null}),
    ] {
        let (mut request, row, transcript) = fixture();
        request["user_response"] = response.clone();
        assert!(crate::execution_ledger::ledger_row(&row));
        let plan = settlement(&request, &row, &question(), &json!("b".repeat(64))).unwrap();
        assert_eq!(plan["cas"]["expected_state"], "intent");
        let view = View {
            row: Some(row.clone()),
            transcript: Some(transcript),
            dispatch: vec![
                json!({"schema_version":1,"kind":"execution","locator":row["locator"],"dispatch_state":"not_dispatched"}),
            ],
            ..View::default()
        };
        let env = Env {
            launch_id: TASK.into(),
            now: NOW.into(),
            attempt_row_count: 1,
        };
        let result = ledger_ops::reduce("settle", plan.as_object().unwrap(), &env, &view).unwrap();
        assert!(result.commit);
        assert!(result.commit_operation.is_some());
        let settled = result
            .changes
            .iter()
            .find_map(|change| match change {
                Change::ReplaceLedgerRow(row) => Some(row),
                _ => None,
            })
            .unwrap();
        let transcript = result
            .changes
            .iter()
            .find_map(|change| match change {
                Change::ReplaceTranscript(row) => Some(row),
                _ => None,
            })
            .unwrap();
        assert_eq!(settled["state"], "settled");
        assert!(settled["owner"].is_null());
        assert_eq!(settled["receipt"]["outcome"], "ok");
        let feedback: Value = serde_json::from_str(
            transcript["messages"].as_array().unwrap().last().unwrap()["content"]
                .as_str()
                .unwrap(),
        )
        .unwrap();
        assert_eq!(feedback["payload"]["response"], response);
        assert_eq!(
            settled["receipt"]["result_sha256"],
            json!(hash_bytes("tool-result", &canonical_json(&feedback).unwrap()).unwrap())
        );
        // Recovery reads the existing receipt; trying to apply the answer again
        // cannot append another tool message or replace the first response.
        let replay_view = View {
            row: Some(settled.clone()),
            transcript: Some(transcript.clone()),
            ..view
        };
        assert!(
            ledger_ops::reduce("settle", plan.as_object().unwrap(), &env, &replay_view).is_err()
        );
        assert_eq!(
            crate::tool_execution::safe_result(&request, settled)["status"],
            "completed"
        );
    }
}
