//! A human response has no native effect to dispatch. Its durable evidence is
//! still the exact receipt and protected transcript feedback from settlement.
use super::*;

pub(super) fn undispatched_settlement(state: &Value, row: &Value) -> bool {
    let Some(receipt) = get(row, "receipt") else {
        return false;
    };
    if !string_eq(get(row, "name"), "ask_user")
        || !is_null(get(row, "owner"))
        || get(row, "reserved_write_bytes") != Some(&json!(0))
        || !crate::user_question::question_shape(get(row, "precondition"))
        || !crate::user_question::facts_shape(get(row, "settled_facts"))
        || !string_eq(get(receipt, "name"), "ask_user")
        || !string_eq(get(receipt, "outcome"), "ok")
        || !is_null(get(receipt, "failure_code"))
        || !is_null(get(receipt, "approval_reference"))
        || get(receipt, "truncated") != Some(&json!(false))
    {
        return false;
    }
    let Some(locator) = get(row, "locator") else {
        return false;
    };
    let Some(after) = get(row, "transcript_after") else {
        return false;
    };
    if get(receipt, "call_id") != get(locator, "call_id")
        || get(receipt, "arguments_sha256") != get(row, "arguments_sha256")
    {
        return false;
    }
    let mut transcripts = array(get(state, "transcripts"))
        .iter()
        .filter(|transcript| {
            get(transcript, "transcript_ref") == get(after, "transcript_ref")
                && get(transcript, "attempt_id") == get(locator, "attempt_id")
                && get(transcript, "root_fingerprint_sha256") == get(row, "root_fingerprint_sha256")
        });
    let Some(transcript) = transcripts.next() else {
        return false;
    };
    if transcripts.next().is_some() {
        return false;
    }
    let mut messages = array(get(transcript, "messages")).iter().filter(|message| {
        string_eq(get(message, "role"), "tool")
            && get(message, "call_id") == get(locator, "call_id")
            && get(message, "round_index") == get(locator, "round_index")
    });
    let Some(message) = messages.next() else {
        return false;
    };
    if messages.next().is_some() || get(message, "truncated") != Some(&json!(false)) {
        return false;
    }
    let Some(bytes) = crate::execution_ledger::canonical_feedback_bytes(Some(message)) else {
        return false;
    };
    if get(receipt, "result_bytes") != Some(&json!(bytes.len()))
        || crate::canonical::hash_bytes("tool-result", &bytes).as_deref()
            != as_str(get(receipt, "result_sha256"))
    {
        return false;
    }
    let Ok(feedback) = serde_json::from_slice::<Value>(&bytes) else {
        return false;
    };
    string_eq(get(&feedback, "name"), "ask_user")
        && string_eq(get(&feedback, "outcome"), "ok")
        && as_str(get(message, "content")).is_some_and(|text| feedback_string_valid(text).is_ok())
        && crate::user_question::facts_match(row, &feedback, &row["settled_facts"])
}
