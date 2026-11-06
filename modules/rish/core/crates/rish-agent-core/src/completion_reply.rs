//! Reading a provider's reply into the one vocabulary a round settles on.
//!
//! Three dialects say the same four things -- what was said, what was
//! thought, what tools were asked for, and why the turn ended -- in three
//! shapes. Reducing them is where a host loses a tool call or mislabels a
//! refusal, and whatever comes out is what the round is settled on, so the
//! reductions that refuse are as important as the ones that read.
//!
//! What stays with the host: whether the model that answered is the model
//! that was asked, because only the host knows a provider's aliases. The
//! `model` here is the requested one, which is what a receipt records.
//!
//! The cases are `modules/rish/ios/Tests/Fixtures/*-response-cases.json`
//! and the tests read those files rather than a copy.

use serde_json::{json, Map, Value};

/// From the non-streaming parser: more calls than this is not a reply.
const MAX_TOOL_CALLS: usize = 16;

const RESPONSE_JSON: &str = "E_COMPLETION_RESPONSE_JSON";
const RESPONSE_ID: &str = "E_COMPLETION_PROVIDER_RESPONSE_ID";
const TOOL_CALL_INVALID: &str = "E_COMPLETION_TOOL_CALL_INVALID";
const FINISH_RELATION: &str = "E_COMPLETION_FINISH_RELATION";
const EMPTY_RESPONSE: &str = "E_COMPLETION_EMPTY_RESPONSE";

/// `{"op":"read_reply","dialect":"...","requested_model":"...","response":{...}}`
pub fn read_reply(envelope: &Value) -> Value {
    match reduced(envelope) {
        Ok(reply) => json!({ "ok": true, "reply": reply }),
        Err(code) => json!({ "ok": false, "failure_code": code }),
    }
}

/// What every dialect reduces to.
struct Said {
    text: String,
    reasoning: String,
    calls: Vec<Value>,
    finish: String,
}

fn reduced(envelope: &Value) -> Result<Value, &'static str> {
    let requested = text_of(envelope.get("requested_model")).ok_or(RESPONSE_JSON)?;
    let response = envelope
        .get("response")
        .and_then(Value::as_object)
        .ok_or(RESPONSE_JSON)?;
    let identifier = text_of(response.get("id")).ok_or(RESPONSE_ID)?;
    if identifier.len() > 256 {
        return Err(RESPONSE_ID);
    }
    let said = match envelope.get("dialect").and_then(Value::as_str) {
        Some("messages") => messages_reply(response)?,
        Some("responses") => responses_reply(response)?,
        _ => return Err(RESPONSE_JSON),
    };
    if said.calls.len() > MAX_TOOL_CALLS {
        return Err(TOOL_CALL_INVALID);
    }
    // A turn that asked for a tool has to say so, and a turn that said so has
    // to have asked: the round branches on one and runs the other.
    if (said.finish == "tool_calls") == said.calls.is_empty() {
        return Err(FINISH_RELATION);
    }
    // A reply with nothing in it is a reply that went wrong -- unless the
    // provider is saying it declined, which is the one empty answer that is
    // an answer.
    if said.text.is_empty()
        && said.reasoning.is_empty()
        && said.calls.is_empty()
        && said.finish != "content_filter"
    {
        return Err(EMPTY_RESPONSE);
    }
    Ok(json!({
        "provider_response_id": identifier,
        "model": requested,
        "text": said.text,
        "reasoning": said.reasoning,
        "tool_calls": said.calls,
        "finish_reason": said.finish,
    }))
}

/// Anthropic's content blocks.
fn messages_reply(response: &Map<String, Value>) -> Result<Said, &'static str> {
    let mut text = String::new();
    let mut reasoning = String::new();
    let mut calls = Vec::new();
    let empty = Vec::new();
    let content = response
        .get("content")
        .and_then(Value::as_array)
        .unwrap_or(&empty);
    for block in content {
        let Some(block) = block.as_object() else {
            return Err(RESPONSE_JSON);
        };
        match block.get("type").and_then(Value::as_str) {
            Some("text") => text.push_str(&text_of(block.get("text")).unwrap_or_default()),
            Some("thinking") => {
                reasoning.push_str(&text_of(block.get("thinking")).unwrap_or_default());
            }
            Some("tool_use") => {
                let (Some(id), Some(name), Some(input)) = (
                    text_of(block.get("id")),
                    text_of(block.get("name")),
                    block.get("input").filter(|input| input.is_object()),
                ) else {
                    return Err(TOOL_CALL_INVALID);
                };
                // The arguments travel as a string everywhere else, so the
                // object becomes one here rather than at every later step --
                // and in a fixed key order, which iOS did not have: it wrote
                // the object back out through NSJSONSerialization, whose key
                // order for a dictionary is unspecified. Those bytes are
                // what a person approves and what the transcript keeps.
                calls.push(json!({
                    "id": id,
                    "name": name,
                    "arguments": serde_json::to_string(input).map_err(|_| TOOL_CALL_INVALID)?,
                }));
            }
            // redacted_thinking and anything newer carry nothing to show,
            // which is not the same as being unreadable.
            _ => {}
        }
    }
    let stop = text_of(response.get("stop_reason")).unwrap_or_else(|| "end_turn".to_owned());
    Ok(Said {
        text,
        reasoning,
        calls,
        // A stop reason this does not know is not guessed at: mislabelling
        // one settles the round on the wrong ending.
        finish: match stop.as_str() {
            "end_turn" | "stop_sequence" | "pause_turn" => "stop",
            "tool_use" => "tool_calls",
            "max_tokens" => "length",
            "refusal" => "content_filter",
            _ => return Err(FINISH_RELATION),
        }
        .to_owned(),
    })
}

/// OpenAI's output items.
fn responses_reply(response: &Map<String, Value>) -> Result<Said, &'static str> {
    let mut text = String::new();
    let mut reasoning = String::new();
    let mut calls = Vec::new();
    let empty = Vec::new();
    let output = response
        .get("output")
        .and_then(Value::as_array)
        .unwrap_or(&empty);
    for item in output {
        let Some(item) = item.as_object() else {
            return Err(RESPONSE_JSON);
        };
        match item.get("type").and_then(Value::as_str) {
            Some("message") => {
                for block in item
                    .get("content")
                    .and_then(Value::as_array)
                    .unwrap_or(&empty)
                {
                    if block.get("type").and_then(Value::as_str) == Some("output_text") {
                        text.push_str(&text_of(block.get("text")).unwrap_or_default());
                    }
                }
            }
            Some("reasoning") => {
                for block in item
                    .get("summary")
                    .and_then(Value::as_array)
                    .unwrap_or(&empty)
                {
                    if block.get("type").and_then(Value::as_str) == Some("summary_text") {
                        reasoning.push_str(&text_of(block.get("text")).unwrap_or_default());
                    }
                }
            }
            Some("function_call") => {
                let (Some(id), Some(name), Some(arguments)) = (
                    text_of(item.get("call_id")),
                    text_of(item.get("name")),
                    item.get("arguments").and_then(Value::as_str),
                ) else {
                    return Err(TOOL_CALL_INVALID);
                };
                calls.push(json!({ "id": id, "name": name, "arguments": arguments }));
            }
            _ => {}
        }
    }
    let status = text_of(response.get("status")).unwrap_or_else(|| "completed".to_owned());
    let finish = match status.as_str() {
        "completed" => {
            if calls.is_empty() {
                "stop"
            } else {
                "tool_calls"
            }
        }
        "incomplete" => {
            match response
                .get("incomplete_details")
                .and_then(Value::as_object)
                .and_then(|details| text_of(details.get("reason")))
                .as_deref()
            {
                Some("max_output_tokens") => "length",
                Some("content_filter") => "content_filter",
                // Incomplete for a reason this does not know.
                _ => return Err(FINISH_RELATION),
            }
        }
        // A round still in progress is not a reply to settle on.
        _ => return Err(FINISH_RELATION),
    };
    Ok(Said {
        text,
        reasoning,
        calls,
        finish: finish.to_owned(),
    })
}

fn text_of(value: Option<&Value>) -> Option<String> {
    match value.and_then(Value::as_str) {
        Some(text) if !text.is_empty() => Some(text.to_owned()),
        _ => None,
    }
}

#[cfg(test)]
#[path = "completion_reply_tests.rs"]
mod tests;
