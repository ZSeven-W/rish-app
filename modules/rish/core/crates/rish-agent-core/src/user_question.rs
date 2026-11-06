//! Durable user questions use the existing prepared tool row and tool receipt.
//! A question has no native execution phase: a validated human response settles
//! its intent and appends its transcript feedback in one ledger transaction.

use crate::canonical::{canonical_json, hash_json};
use crate::schema::{canonical_sha256, exact_keys};
use crate::store::StoreError;
use serde_json::{json, Value};

pub const NAME: &str = "ask_user";
pub const MAX_ANSWER_BYTES: usize = 4000;

fn text(value: &Value, maximum: usize) -> bool {
    value.as_str().is_some_and(|text| {
        !text.trim().is_empty() && text.len() <= maximum && !text.contains('\0')
    })
}

pub fn arguments_valid(value: &Value) -> bool {
    if exact_keys(Some(value), &["question", "input_mode", "options"]).is_none()
        || !text(&value["question"], 2000)
    {
        return false;
    }
    let Some(options) = value["options"].as_array() else {
        return false;
    };
    match value["input_mode"].as_str() {
        Some("free_text") => options.is_empty(),
        Some("options") => {
            if !(2..=8).contains(&options.len()) {
                return false;
            }
            let mut ids = std::collections::BTreeSet::new();
            options.iter().all(|option| {
                let Some(id) = option["id"].as_str() else {
                    return false;
                };
                exact_keys(Some(option), &["id", "label"]).is_some()
                    && !id.is_empty()
                    && id.len() <= 64
                    && id
                        .bytes()
                        .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
                    && ids.insert(id)
                    && text(&option["label"], 200)
            })
        }
        _ => false,
    }
}

pub fn descriptor() -> Value {
    json!({"schema_version":1,"name":NAME,"required_capability":"file_read",
      "effect":"read","safe_summary_key":"agent.ask_user",
      "parameters":{"type":"object","additionalProperties":false,
        "properties":{
          "question":{"type":"string","max_utf8_bytes":2000},
          "input_mode":{"type":"string","enum":["options","free_text"]},
          "options":{"type":"array","maxItems":8,"items":{"type":"object","additionalProperties":false,
            "properties":{"id":{"type":"string","max_utf8_bytes":64},"label":{"type":"string","max_utf8_bytes":200}},
            "required":["id","label"]}}},"required":["question","input_mode","options"]}})
}

pub fn prepared(arguments: &Value) -> Option<Value> {
    arguments_valid(arguments).then(|| {
        json!({
          "precondition":{"schema_version":1,"kind":NAME,"question":arguments},
          "approval_preview":{"schema_version":1,"kind":NAME,"question":arguments},
          "reserved_write_bytes":0,
        })
    })
}

pub fn question_shape(value: Option<&Value>) -> bool {
    let Some(value) = value else { return false };
    exact_keys(Some(value), &["schema_version", "kind", "question"]).is_some()
        && value["schema_version"] == 1
        && value["kind"] == NAME
        && arguments_valid(&value["question"])
}

/// A cancelled answer is explicit and never manufactures answer text.
pub fn response_shape(response: &Value) -> bool {
    if exact_keys(Some(response), &["status", "answer"]).is_none() {
        return false;
    }
    match response["status"].as_str() {
        Some("answered") => text(&response["answer"], MAX_ANSWER_BYTES),
        Some("cancelled") => response["answer"].is_null(),
        _ => false,
    }
}

pub fn response_valid(arguments: &Value, response: &Value) -> bool {
    arguments_valid(arguments)
        && response_shape(response)
        && (response["status"] == "cancelled"
            || arguments["input_mode"] == "free_text"
            || arguments["options"].as_array().is_some_and(|options| {
                options
                    .iter()
                    .any(|option| option["id"] == response["answer"])
            }))
}

pub fn facts_shape(value: Option<&Value>) -> bool {
    let Some(value) = value else { return false };
    exact_keys(Some(value), &["schema_version", "kind", "response_sha256"]).is_some()
        && value["schema_version"] == 1
        && value["kind"] == NAME
        && canonical_sha256(value.get("response_sha256"))
}

pub fn facts_match(row: &Value, feedback: &Value, facts: &Value) -> bool {
    let question = &row["precondition"]["question"];
    let payload = &feedback["payload"];
    if !question_shape(row.get("precondition"))
        || !facts_shape(Some(facts))
        || exact_keys(Some(payload), &["schema_version", "question", "response"]).is_none()
        || payload["schema_version"] != 1
        || payload["question"] != *question
        || !response_valid(question, &payload["response"])
    {
        return false;
    }
    hash_json("agent-user-response", &payload["response"]).as_deref()
        == facts["response_sha256"].as_str()
}

pub fn effect(arguments: &Value, response: &Value) -> Result<Value, StoreError> {
    if !response_valid(arguments, response) {
        return Err(StoreError::InvalidArgument);
    }
    let feedback = json!({"schema_version":1,"name":NAME,"outcome":"ok",
        "payload":{"schema_version":1,"question":arguments,"response":response}});
    let bytes = canonical_json(&feedback).map_err(|_| StoreError::InvalidArgument)?;
    Ok(json!({"schema_version":1,"status":"completed",
      "feedback":String::from_utf8(bytes).map_err(|_| StoreError::InvalidArgument)?,
      "settled_facts":{"schema_version":1,"kind":NAME,
        "response_sha256":hash_json("agent-user-response", response).ok_or(StoreError::InvalidArgument)?},
      "truncated":false,"effect_may_have_occurred":false}))
}

pub fn settlement(
    request: &Value,
    row: &Value,
    arguments: &Value,
    request_sha: &Value,
) -> Result<Value, StoreError> {
    crate::tool_execution::execute_request(request)?;
    if request["name"] != NAME
        || row["name"] != NAME
        || row["state"] != "intent"
        || row["row_revision"] != request["expected_execution_revision"]
        || !question_shape(row.get("precondition"))
        || row["precondition"]["question"] != *arguments
        || !canonical_sha256(Some(request_sha))
    {
        return Err(StoreError::Conflict);
    }
    for key in [
        "task_id",
        "attempt_id",
        "round_id",
        "round_index",
        "call_index",
        "call_id",
        "idempotency_key",
    ] {
        if row["locator"][key] != request[key] {
            return Err(StoreError::Conflict);
        }
    }
    if row["arguments_sha256"] != request["arguments_sha256"] {
        return Err(StoreError::Conflict);
    }
    let effect = effect(arguments, &request["user_response"])?;
    crate::tool_execution::settlement_plan(request, row, &effect, Some(request_sha), 0)
}

#[cfg(test)]
#[path = "user_question_tests.rs"]
mod tests;
