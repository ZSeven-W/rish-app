//! Every frozen reply, read here.
//!
//! Same arrangement as the request side: these read the fixture files the
//! hosts read, so the implementation and the recording cannot drift apart.

use super::*;

const FIXTURES: [(&str, &str); 2] = [
    ("anthropic-response-cases.json", "messages"),
    ("openai-response-cases.json", "responses"),
];

fn fixture(name: &str) -> Value {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../../ios/Tests/Fixtures/");
    let text = std::fs::read_to_string(format!("{path}{name}"))
        .unwrap_or_else(|error| panic!("{name}: {error}"));
    serde_json::from_str(&text).expect("the fixture is JSON")
}

fn read(dialect: &str, case: &Value) -> Value {
    read_reply(&json!({
        "op": "read_reply",
        "dialect": dialect,
        "requested_model": case["requested_model"],
        "response": case["response"],
    }))
}

/// The whole point: every recorded reply, read or refused as recorded.
#[test]
fn every_frozen_reply_is_read_the_recorded_way() {
    let mut total = 0;
    for (file, dialect) in FIXTURES {
        let recorded = fixture(file);
        let cases = recorded["cases"].as_array().expect("cases");
        assert!(cases.len() > 3, "{file} records too little");
        for case in cases {
            let name = case["name"].as_str().expect("a name");
            let answer = read(dialect, case);
            match case.get("failure_code").and_then(Value::as_str) {
                Some(expected) => {
                    assert_eq!(answer["ok"], json!(false), "{file}/{name} should refuse");
                    assert_eq!(answer["failure_code"], json!(expected), "{file}/{name}");
                }
                None => {
                    assert_eq!(answer["ok"], json!(true), "{file}/{name}: {answer}");
                    assert_eq!(answer["reply"], case["parsed"], "{file}/{name}");
                }
            }
            total += 1;
        }
    }
    assert_eq!(total, 13, "every recorded case is read");
}

/// A reply with no identity cannot be matched to the round that asked for
/// it, whatever else it says.
#[test]
fn a_reply_without_an_identity_is_refused() {
    for response in [
        json!({ "content": [{ "type": "text", "text": "x" }], "stop_reason": "end_turn" }),
        json!({ "id": "", "content": [{ "type": "text", "text": "x" }] }),
        json!({ "id": "x".repeat(257), "content": [{ "type": "text", "text": "x" }] }),
    ] {
        let answer = read_reply(&json!({
            "dialect": "messages",
            "requested_model": "claude-sonnet-5",
            "response": response,
        }));
        assert_eq!(
            answer["failure_code"],
            json!("E_COMPLETION_PROVIDER_RESPONSE_ID"),
            "{response}",
        );
    }
}

/// A block this cannot read is a tool call that cannot be run; a block that
/// carries nothing to show is neither, and is stepped over. Telling the two
/// apart is the difference between losing a call and refusing a reply.
#[test]
fn an_unreadable_call_is_refused_and_a_silent_block_is_not() {
    let answer = |block: Value| {
        read_reply(&json!({
            "dialect": "messages",
            "requested_model": "claude-sonnet-5",
            "response": {
                "id": "m", "stop_reason": "end_turn",
                "content": [{ "type": "text", "text": "said" }, block],
            },
        }))
    };
    for broken in [
        json!({ "type": "tool_use", "name": "n", "input": {} }),
        json!({ "type": "tool_use", "id": "t", "input": {} }),
        json!({ "type": "tool_use", "id": "t", "name": "n" }),
        json!({ "type": "tool_use", "id": "t", "name": "n", "input": "not an object" }),
    ] {
        assert_eq!(
            answer(broken.clone())["failure_code"],
            json!("E_COMPLETION_TOOL_CALL_INVALID"),
            "{broken}",
        );
    }
    // A kind this does not know says nothing, and the reply is still read.
    for quiet in [
        json!({ "type": "redacted_thinking", "data": "opaque" }),
        json!({ "type": "something_new" }),
    ] {
        let read = answer(quiet.clone());
        assert_eq!(read["ok"], json!(true), "{quiet}");
        assert_eq!(read["reply"]["text"], json!("said"));
    }
}

/// Anthropic sends a tool's input as an object and everything downstream
/// takes a string, so the conversion happens once, here -- with the keys in
/// a fixed order.
///
/// That order is new. iOS wrote the object back out through
/// NSJSONSerialization, whose key order for an NSDictionary is unspecified,
/// so the same reply could produce different argument bytes on different
/// runs. Those bytes are what a person is shown before approving the call
/// and what the transcript keeps, so an order is better than no order.
#[test]
fn anthropic_tool_input_becomes_the_string_the_round_carries() {
    let reply = read_reply(&json!({
        "dialect": "messages",
        "requested_model": "claude-sonnet-5",
        "response": {
            "id": "m", "stop_reason": "tool_use",
            "content": [{
                "type": "tool_use", "id": "t", "name": "write_file",
                "input": { "path": "a/b.txt", "mode": 420 },
            }],
        },
    }))["reply"]
        .clone();
    assert_eq!(
        reply["tool_calls"],
        json!([{
            "id": "t", "name": "write_file",
            "arguments": "{\"mode\":420,\"path\":\"a/b.txt\"}",
        }]),
    );
    assert_eq!(reply["finish_reason"], json!("tool_calls"));
}

/// The finish reason and the calls have to agree in both directions: a round
/// branches on the one and runs the other.
#[test]
fn a_finish_reason_that_disagrees_with_the_calls_is_refused() {
    let disagreeing = |stop: &str, content: Value| {
        read_reply(&json!({
            "dialect": "messages",
            "requested_model": "claude-sonnet-5",
            "response": { "id": "m", "stop_reason": stop, "content": content },
        }))["failure_code"]
            .clone()
    };
    // Asked for a tool without saying so.
    assert_eq!(
        disagreeing(
            "end_turn",
            json!([{ "type": "tool_use", "id": "t", "name": "n", "input": {} }])
        ),
        json!("E_COMPLETION_FINISH_RELATION"),
    );
    // Said so without asking.
    assert_eq!(
        disagreeing("tool_use", json!([{ "type": "text", "text": "x" }])),
        json!("E_COMPLETION_FINISH_RELATION"),
    );
}

/// A responses round that has not finished is not a reply, and one that
/// stopped for a reason this does not know is not one either.
#[test]
fn an_unfinished_responses_round_is_refused() {
    let status = |status: &str, details: Value| {
        let mut response = json!({
            "id": "r",
            "status": status,
            "output": [{
                "type": "message", "role": "assistant",
                "content": [{ "type": "output_text", "text": "x" }],
            }],
        });
        if !details.is_null() {
            response["incomplete_details"] = details;
        }
        read_reply(&json!({
            "dialect": "responses",
            "requested_model": "gpt-5.6",
            "response": response,
        }))
    };
    assert_eq!(
        status("in_progress", Value::Null)["failure_code"],
        json!("E_COMPLETION_FINISH_RELATION")
    );
    assert_eq!(
        status("failed", Value::Null)["failure_code"],
        json!("E_COMPLETION_FINISH_RELATION")
    );
    assert_eq!(
        status("incomplete", Value::Null)["failure_code"],
        json!("E_COMPLETION_FINISH_RELATION")
    );
    assert_eq!(
        status("incomplete", json!({ "reason": "content_filter" }))["reply"]["finish_reason"],
        json!("content_filter"),
    );
}

/// An empty reply went wrong -- except a refusal, which is the provider
/// answering that it will not.
#[test]
fn an_empty_reply_is_refused_unless_it_is_a_refusal() {
    let empty = |stop: &str| {
        read_reply(&json!({
            "dialect": "messages",
            "requested_model": "claude-sonnet-5",
            "response": { "id": "m", "stop_reason": stop, "content": [] },
        }))
    };
    assert_eq!(
        empty("end_turn")["failure_code"],
        json!("E_COMPLETION_EMPTY_RESPONSE")
    );
    assert_eq!(
        empty("max_tokens")["failure_code"],
        json!("E_COMPLETION_EMPTY_RESPONSE")
    );
    assert_eq!(
        empty("refusal")["reply"]["finish_reason"],
        json!("content_filter")
    );
}
