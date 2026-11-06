use rish_agent_core::runtime_coordinator::{cancel_idle_attempt_result, cancel_plan};
use serde_json::{json, Value};
fn state() -> Value {
    json!({"authorities":[{"task_id":"task","attempt_id":"attempt","state":"prepared","root":{"identity":"root"},"transcript":{"generation":2}}],"rounds":[{"locator":{"task_id":"task","attempt_id":"attempt","round_id":"round","round_index":0},"state":"completed","row_revision":2}],"ledger":[{"locator":{"task_id":"task","attempt_id":"attempt","call_id":"write"},"state":"intent"}]})
}
fn request() -> Value {
    json!({"schema_version":2,"operation_id":"cancel","target":{"kind":"attempt","task_id":"task","attempt_id":"attempt"},"cancel_token":{"expected_phase":"approval_pending"},"root":{"identity":"root"},"expected_transcript":{"generation":2},"committed_checkpoint":{"schema_version":1}})
}
#[test]
fn paused_approval_cancels_attempt_without_selecting_completed_provider() {
    let q = request();
    let plan = cancel_plan(&state(), &q);
    assert_eq!(plan["plan"], "idle_attempt");
    let result = cancel_idle_attempt_result(&q, &plan);
    assert_eq!(result["status"], "cancelled");
    assert_eq!(result["transcript"], q["expected_transcript"]);
    assert_eq!(result["effect_may_have_occurred"], false);
    assert!(result["result_round_revision"].is_null());
}
#[test]
fn previously_settled_tools_are_not_claimed_undone() {
    let mut s = state();
    s["ledger"][0]["state"] = json!("settled");
    let plan = cancel_plan(&s, &request());
    assert_eq!(plan["plan"], "idle_attempt");
    assert_eq!(
        cancel_idle_attempt_result(&request(), &plan)["effect_may_have_occurred"],
        true
    );
}
#[test]
fn active_or_uncertain_tools_roots_and_transcripts_never_use_idle_plan() {
    for status in ["running", "cancel_requested", "unknown", "ambiguous"] {
        let mut s = state();
        s["ledger"][0]["state"] = json!(status);
        assert_ne!(
            cancel_plan(&s, &request())["plan"],
            "idle_attempt",
            "{status}"
        );
    }
    let mut q = request();
    q["expected_transcript"]["generation"] = json!(1);
    assert_ne!(cancel_plan(&state(), &q)["plan"], "idle_attempt");
    q = request();
    q["root"]["identity"] = json!("other");
    assert_ne!(cancel_plan(&state(), &q)["plan"], "idle_attempt");
    q = request();
    q["cancel_token"]["expected_phase"] = json!("execution_intent");
    assert_ne!(cancel_plan(&state(), &q)["plan"], "idle_attempt");
    let mut s = state();
    s["rounds"][0]["state"] = json!("in_flight");
    assert_ne!(cancel_plan(&s, &request())["plan"], "idle_attempt");
}
#[test]
fn idle_cancellation_returns_the_feedback_transcript_for_final_checkpoint() {
    let mut q = request();
    let before = json!({"schema_version":1,"transcript_ref":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","generation":2,"transcript_sha256":"a".repeat(64),"transcript_bytes":200});
    q["expected_transcript"] = before.clone();
    let mut after = before.clone();
    after["generation"] = json!(3);
    after["transcript_sha256"] = json!("b".repeat(64));
    after["transcript_bytes"] = json!(300);
    let result = cancel_idle_attempt_result(
        &q,
        &json!({"transcript":after,"effect_may_have_occurred":false}),
    );
    assert_eq!(result["status"], "cancelled");
    assert_eq!(result["transcript"], after);
    let mut wrong = after;
    wrong["transcript_ref"] = json!("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb");
    assert_eq!(
        cancel_idle_attempt_result(&q, &json!({"transcript":wrong}))["status"],
        "unknown"
    );
}
