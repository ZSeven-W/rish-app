//! Every frozen request, rebuilt here.
//!
//! These read the fixtures the hosts read, rather than a copy of them: if
//! this implementation and the recorded bodies ever disagree, the test that
//! says so is the same one both hosts are held to. The digest is recomputed
//! too, under the encoding a receipt binds -- sorted keys with a forward
//! slash escaped -- so a body that is right in shape but wrong in bytes is
//! still caught.

use super::*;
use sha2::{Digest, Sha256};

const FIXTURES: [(&str, &str); 3] = [
    ("deepseek-request-cases.json", "chat-completions"),
    ("anthropic-request-cases.json", "messages"),
    ("openai-request-cases.json", "responses"),
];

fn fixture(name: &str) -> Value {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../../../apps/mobile/ios/RishTests/Fixtures/"
    );
    let text = std::fs::read_to_string(format!("{path}{name}"))
        .unwrap_or_else(|error| panic!("{name}: {error}"));
    serde_json::from_str(&text).expect("the fixture is JSON")
}

/// Sorted keys, compact, and a forward slash escaped.
fn receipt_encoding(value: &Value) -> String {
    match value {
        Value::Null => "null".to_owned(),
        Value::Bool(_) | Value::Number(_) => value.to_string(),
        Value::String(text) => Value::String(text.clone()).to_string().replace('/', "\\/"),
        Value::Array(items) => {
            let inner: Vec<String> = items.iter().map(receipt_encoding).collect();
            format!("[{}]", inner.join(","))
        }
        Value::Object(map) => {
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort();
            let inner: Vec<String> = keys
                .into_iter()
                .map(|key| {
                    format!(
                        "{}:{}",
                        receipt_encoding(&Value::String(key.clone())),
                        receipt_encoding(&map[key])
                    )
                })
                .collect();
            format!("{{{}}}", inner.join(","))
        }
    }
}

fn digest_of(value: &Value) -> String {
    let mut hasher = Sha256::new();
    hasher.update(receipt_encoding(value).as_bytes());
    hasher
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

/// The whole point: every recorded body, rebuilt from its recorded inputs.
#[test]
fn every_frozen_request_is_rebuilt_byte_for_byte() {
    let mut total = 0;
    for (file, dialect) in FIXTURES {
        let recorded = fixture(file);
        let cases = recorded["cases"].as_array().expect("cases");
        assert!(cases.len() > 3, "{file} records too little");
        for case in cases {
            let name = case["name"].as_str().expect("a name");
            let answer = request_body(&json!({
                "op": "request_body",
                "dialect": dialect,
                "model": case["model"],
                "thinking_mode": case["thinking_mode"],
                "streaming": case["streaming"],
                "messages": case["messages"],
                "tools": case["tools"],
            }));
            assert_eq!(answer["ok"], json!(true), "{file}/{name}: {answer}");
            assert_eq!(answer["body"], case["body"], "{file}/{name} body");
            assert_eq!(
                digest_of(&answer["body"]),
                case["body_sha256"].as_str().expect("a digest"),
                "{file}/{name} digest",
            );
            total += 1;
        }
    }
    assert_eq!(total, 25, "every recorded case is rebuilt");
}

/// The four ceilings of a chat round, stated rather than inferred from the
/// fixture, so that removing a case cannot quietly remove the rule.
#[test]
fn a_chat_rounds_ceiling_follows_its_shape() {
    let ceiling = |tools: bool, mode: &str| {
        let answer = request_body(&json!({
            "dialect": "chat-completions",
            "model": "deepseek-v4-flash",
            "thinking_mode": mode,
            "streaming": true,
            "messages": [{ "role": "user", "content": "x" }],
            "tools": if tools {
                json!([{ "function": { "name": "t", "parameters": {} } }])
            } else {
                json!([])
            },
        }));
        answer["body"]["max_tokens"].clone()
    };
    assert_eq!(ceiling(false, "off"), json!(1024));
    assert_eq!(ceiling(false, "high"), json!(4096));
    assert_eq!(ceiling(true, "off"), json!(8192));
    assert_eq!(ceiling(true, "high"), json!(16384));
}

/// A continuation round on the budget family runs unthinking, because the
/// API rejects a replayed tool_use turn with thinking on.
#[test]
fn a_budget_continuation_round_asks_for_no_thinking() {
    let round = |last: Value| {
        request_body(&json!({
            "dialect": "messages",
            "model": "claude-haiku-4-5-20251001",
            "thinking_mode": "high",
            "streaming": true,
            "messages": [{ "role": "user", "content": "x" }, last],
            "tools": [],
        }))["body"]
            .clone()
    };
    let plain = round(json!({ "role": "assistant", "content": "hello" }));
    assert_eq!(plain["thinking"], json!({ "type": "enabled", "budget_tokens": 4096 }));
    assert_eq!(plain["max_tokens"], json!(4096 + 8192));

    let continuation = round(json!({
        "role": "assistant",
        "content": "",
        "tool_calls": [{
            "id": "c", "type": "function",
            "function": { "name": "t", "arguments": "{}" },
        }],
    }));
    assert_eq!(continuation.get("thinking"), None);
    assert_eq!(continuation["max_tokens"], json!(8192));
}

/// The families are told apart by the model, and only the budget one takes
/// a budget. Getting this wrong sends Anthropic vocabulary to GLM.
#[test]
fn the_thinking_vocabulary_follows_the_family() {
    let spoken = |model: &str, mode: &str| {
        request_body(&json!({
            "dialect": "messages",
            "model": model,
            "thinking_mode": mode,
            "streaming": true,
            "messages": [{ "role": "user", "content": "x" }],
            "tools": [],
        }))["body"]
            .clone()
    };
    for budget in ["claude-haiku-4-5-20251001", "GLM-5.3"] {
        assert_eq!(spoken(budget, "high")["thinking"]["type"], json!("enabled"));
        assert_eq!(spoken(budget, "off").get("thinking"), None);
        assert_eq!(spoken(budget, "off").get("output_config"), None);
    }
    assert_eq!(spoken("claude-sonnet-5", "high")["thinking"]["display"], json!("summarized"));
    assert_eq!(spoken("claude-sonnet-5", "off")["thinking"], json!({ "type": "disabled" }));
    // The always-on family cannot say disabled, so it asks for little.
    let fable_off = spoken("claude-fable-5-1", "off");
    assert_eq!(fable_off.get("thinking"), None);
    assert_eq!(fable_off["output_config"], json!({ "effort": "low" }));
}

/// A turn this cannot place is a broken transcript, not a turn to skip: a
/// round assembled without it would ask the model about work it cannot see.
#[test]
fn a_turn_that_cannot_be_placed_fails_the_body() {
    let refused = |message: Value| {
        request_body(&json!({
            "dialect": "responses",
            "model": "gpt-5.6",
            "thinking_mode": "off",
            "streaming": true,
            "messages": [message],
            "tools": [],
        }))
    };
    let broken = json!({ "role": "developer", "content": "x" });
    assert_eq!(refused(broken)["failure_code"], json!("E_COMPLETION_TRANSCRIPT"));
    // An assistant turn whose call has no id cannot be answered later.
    let unanswerable = json!({
        "role": "assistant",
        "content": "",
        "tool_calls": [{ "function": { "name": "t", "arguments": "{}" } }],
    });
    assert_eq!(
        refused(unanswerable)["failure_code"],
        json!("E_COMPLETION_TRANSCRIPT"),
    );
    // And a tool result with nothing to attach it to.
    let orphan = json!({ "role": "tool", "content": "done" });
    assert_eq!(refused(orphan)["failure_code"], json!("E_COMPLETION_TRANSCRIPT"));
}

/// A tool this cannot read is refused rather than dropped, because a round
/// that silently lost a tool would be answered as if it never had one.
#[test]
fn a_tool_that_cannot_be_read_fails_the_body() {
    for dialect in ["messages", "responses"] {
        for broken in [
            json!([{ "function": { "parameters": {} } }]),
            json!([{ "function": { "name": "t" } }]),
            json!([{ "function": { "name": "t", "parameters": "not an object" } }]),
            json!([{ "name": "t" }]),
        ] {
            let answer = request_body(&json!({
                "dialect": dialect,
                "model": if dialect == "messages" { "claude-sonnet-5" } else { "gpt-5.6" },
                "thinking_mode": "off",
                "streaming": true,
                "messages": [{ "role": "user", "content": "x" }],
                "tools": broken,
            }));
            assert_eq!(answer["failure_code"], json!("E_COMPLETION_TOOLS"), "{dialect}");
        }
    }
}

/// An envelope this cannot read at all.
#[test]
fn a_request_this_cannot_read_is_refused() {
    for envelope in [
        json!({ "dialect": "chat-completions", "thinking_mode": "off", "messages": [] }),
        json!({ "dialect": "chat-completions", "model": "m", "messages": [] }),
        json!({ "dialect": "chat-completions", "model": "m", "thinking_mode": "off" }),
        json!({ "dialect": "nonesuch", "model": "m", "thinking_mode": "off", "messages": [] }),
    ] {
        assert_eq!(
            request_body(&envelope)["failure_code"],
            json!("E_COMPLETION_BODY_INVALID"),
            "{envelope}",
        );
    }
}

/// A tool call and its result have no string form on the Anthropic wire, so
/// the turns are rewritten into blocks here -- and every result of one
/// assistant turn is answered in a single user turn, because the API refuses
/// them spread across several.
#[test]
fn anthropic_turns_become_blocks_and_results_are_answered_together() {
    let body = request_body(&json!({
        "dialect": "messages",
        "model": "claude-sonnet-5",
        "thinking_mode": "off",
        "streaming": true,
        "messages": [
            { "role": "user", "content": "do both" },
            { "role": "assistant", "content": "on it", "tool_calls": [
                { "id": "a", "function": { "name": "t", "arguments": "{\"n\":1}" } },
                { "id": "b", "function": { "name": "t", "arguments": "{\"n\":2}" } },
            ] },
            { "role": "tool", "tool_call_id": "a", "content": "first" },
            { "role": "tool", "tool_call_id": "b", "content": "second" },
        ],
        "tools": [],
    }))["body"]
        .clone();
    assert_eq!(
        body["messages"],
        json!([
            { "role": "user", "content": [{ "type": "text", "text": "do both" }] },
            { "role": "assistant", "content": [
                { "type": "text", "text": "on it" },
                { "type": "tool_use", "id": "a", "name": "t", "input": { "n": 1 } },
                { "type": "tool_use", "id": "b", "name": "t", "input": { "n": 2 } },
            ] },
            // One user turn, both results.
            { "role": "user", "content": [
                { "type": "tool_result", "tool_use_id": "a", "content": "first" },
                { "type": "tool_result", "tool_use_id": "b", "content": "second" },
            ] },
        ]),
    );
}

/// An assistant turn that carried only reasoning still holds its place in
/// the alternation, because an empty content array is refused.
#[test]
fn an_assistant_turn_with_nothing_to_show_still_says_something() {
    let body = request_body(&json!({
        "dialect": "messages",
        "model": "claude-sonnet-5",
        "thinking_mode": "off",
        "streaming": true,
        "messages": [
            { "role": "user", "content": "x" },
            { "role": "assistant", "content": "" },
        ],
        "tools": [],
    }))["body"]
        .clone();
    assert_eq!(
        body["messages"][1]["content"],
        json!([{ "type": "text", "text": "(no visible output)" }]),
    );
}

/// Tool arguments are an object on this wire, not a string of JSON, so a
/// call whose arguments do not parse is a turn that cannot be sent at all.
#[test]
fn anthropic_refuses_arguments_that_are_not_an_object() {
    for arguments in ["not json", "[1,2]", "\"text\""] {
        let answer = request_body(&json!({
            "dialect": "messages",
            "model": "claude-sonnet-5",
            "thinking_mode": "off",
            "streaming": true,
            "messages": [{
                "role": "assistant", "content": "",
                "tool_calls": [{ "id": "a", "function": { "name": "t", "arguments": arguments } }],
            }],
            "tools": [],
        }));
        assert_eq!(
            answer["failure_code"],
            json!("E_COMPLETION_TRANSCRIPT"),
            "{arguments}",
        );
    }
}

/// A picture reaches every dialect, each in its own spelling.
///
/// Two of the three used to read a turn's content with `text()`, which
/// answers `None` for an array, so a message carrying a picture arrived at
/// the provider as an empty string. The model then answered a question about
/// an image it had never been shown, which is worse than a refusal.
#[test]
fn a_picture_reaches_every_dialect_in_its_own_spelling() {
    let turn = json!({
        "role": "user",
        "content": [
            { "type": "text", "text": "what is this" },
            { "type": "image", "mime_type": "image/png", "data": "QUJD" },
        ],
    });
    let body = |dialect: &str, model: &str| {
        let answer = request_body(&json!({
            "dialect": dialect,
            "model": model,
            "thinking_mode": "off",
            "streaming": false,
            "messages": [turn.clone()],
            "tools": [],
        }));
        assert_eq!(answer["ok"], json!(true), "{dialect}: {answer}");
        answer["body"].clone()
    };

    assert_eq!(
        body("chat-completions", "deepseek-v4-flash")["messages"][0]["content"],
        json!([
            { "type": "text", "text": "what is this" },
            { "type": "image_url", "image_url": { "url": "data:image/png;base64,QUJD" } },
        ]),
    );
    assert_eq!(
        body("messages", "claude-sonnet-5")["messages"][0]["content"],
        json!([
            { "type": "text", "text": "what is this" },
            {
                "type": "image",
                "source": { "type": "base64", "media_type": "image/png", "data": "QUJD" },
            },
        ]),
    );
    assert_eq!(
        body("responses", "gpt-5")["input"][0]["content"],
        json!([
            { "type": "input_text", "text": "what is this" },
            { "type": "input_image", "image_url": "data:image/png;base64,QUJD" },
        ]),
    );
}

/// A turn of plain words keeps the shape it has always had, in every
/// dialect, so the frozen bodies cannot move underneath the new path.
#[test]
fn plain_words_are_untouched_by_the_parts_path() {
    for (dialect, model) in [
        ("chat-completions", "deepseek-v4-flash"),
        ("messages", "claude-sonnet-5"),
        ("responses", "gpt-5"),
    ] {
        let answer = request_body(&json!({
            "dialect": dialect,
            "model": model,
            "thinking_mode": "off",
            "streaming": false,
            "messages": [{ "role": "user", "content": "hello" }],
            "tools": [],
        }));
        assert_eq!(answer["ok"], json!(true), "{dialect}");
        let content = if dialect == "chat-completions" {
            answer["body"]["messages"][0]["content"].clone()
        } else if dialect == "messages" {
            answer["body"]["messages"][0]["content"].clone()
        } else {
            answer["body"]["input"][0]["content"].clone()
        };
        let expected = match dialect {
            "chat-completions" => json!("hello"),
            "messages" => json!([{ "type": "text", "text": "hello" }]),
            _ => json!([{ "type": "input_text", "text": "hello" }]),
        };
        assert_eq!(content, expected, "{dialect}");
    }
}

/// What a request carrying parts is refused for. Each of these used to be
/// either dropped silently or sent on to the provider to reject opaquely.
#[test]
fn a_malformed_or_misplaced_part_fails_the_round() {
    let refusal = |dialect: &str, messages: Value| {
        let answer = request_body(&json!({
            "dialect": dialect,
            "model": if dialect == "messages" { "claude-sonnet-5" } else { "deepseek-v4-flash" },
            "thinking_mode": "off",
            "streaming": false,
            "messages": messages,
            "tools": [],
        }));
        assert_eq!(answer["ok"], json!(false), "{dialect}: {answer}");
        answer["failure_code"].as_str().unwrap_or_default().to_owned()
    };
    let picture = json!({ "type": "image", "mime_type": "image/png", "data": "QUJD" });

    for dialect in ["chat-completions", "messages", "responses"] {
        // A format no provider in the catalog takes.
        assert_eq!(
            refusal(
                dialect,
                json!([{
                    "role": "user",
                    "content": [{ "type": "image", "mime_type": "image/tiff", "data": "QUJD" }],
                }]),
            ),
            "E_COMPLETION_CONTEXT_UNSUPPORTED",
            "{dialect} tiff",
        );
        // A picture with no bytes, and a part of an unknown kind.
        assert_eq!(
            refusal(
                dialect,
                json!([{
                    "role": "user",
                    "content": [{ "type": "image", "mime_type": "image/png", "data": "" }],
                }]),
            ),
            "E_COMPLETION_TRANSCRIPT",
            "{dialect} empty picture",
        );
        assert_eq!(
            refusal(
                dialect,
                json!([{ "role": "user", "content": [{ "type": "audio", "data": "QUJD" }] }]),
            ),
            "E_COMPLETION_TRANSCRIPT",
            "{dialect} unknown part",
        );
        // An empty array is not a message; it would reach the provider as a
        // turn with nothing in it.
        assert_eq!(
            refusal(dialect, json!([{ "role": "user", "content": [] }])),
            "E_COMPLETION_TRANSCRIPT",
            "{dialect} empty parts",
        );
        // Only the person's turn may carry parts. An assistant turn whose
        // content is an array is a transcript this code cannot read, and
        // reading it as an empty answer is how a reply disappears.
        assert_eq!(
            refusal(
                dialect,
                json!([
                    { "role": "user", "content": "hi" },
                    { "role": "assistant", "content": [picture.clone()] },
                    { "role": "user", "content": "and now" },
                ]),
            ),
            "E_COMPLETION_TRANSCRIPT",
            "{dialect} assistant parts",
        );
    }
}



/// The older spelling iOS still sends reaches every dialect the same way.
///
/// iOS has built `image_url` parts with an inlined data URL since before this
/// file knew what a picture was. Under the first version of the parts path it
/// was an unknown part and failed the round, which broke a shipped iOS
/// feature; the full iOS suite is what said so. Reading it back into the
/// neutral form has to give byte-for-byte what the neutral form gives, or
/// there are two contracts instead of one.
#[test]
fn the_older_image_url_spelling_gives_the_same_body() {
    let neutral = json!({
        "role": "user",
        "content": [
            { "type": "text", "text": "what is this" },
            { "type": "image", "mime_type": "image/png", "data": "QUJD" },
        ],
    });
    let legacy = json!({
        "role": "user",
        "content": [
            { "type": "text", "text": "what is this" },
            { "type": "image_url", "image_url": { "url": "data:image/png;base64,QUJD" } },
        ],
    });
    for (dialect, model) in [
        ("chat-completions", "deepseek-v4-flash"),
        ("messages", "claude-sonnet-5"),
        ("responses", "gpt-5.6"),
    ] {
        let body = |turn: &Value| {
            let answer = request_body(&json!({
                "dialect": dialect,
                "model": model,
                "thinking_mode": "off",
                "streaming": false,
                "messages": [turn],
                "tools": [],
            }));
            assert_eq!(answer["ok"], json!(true), "{dialect}: {answer}");
            answer["body"].clone()
        };
        assert_eq!(body(&neutral), body(&legacy), "{dialect}");
    }
}

/// What an older-spelling picture is refused for. A remote URL is not
/// something this app can vouch for, and a format outside the catalog is
/// refused on both spellings alike.
#[test]
fn an_image_url_that_is_not_an_inlined_picture_is_refused() {
    let refusal = |url: Value| {
        let answer = request_body(&json!({
            "dialect": "chat-completions",
            "model": "deepseek-v4-flash",
            "thinking_mode": "off",
            "streaming": false,
            "messages": [{
                "role": "user",
                "content": [{ "type": "image_url", "image_url": { "url": url } }],
            }],
            "tools": [],
        }));
        assert_eq!(answer["ok"], json!(false), "{answer}");
        answer["failure_code"].as_str().unwrap_or_default().to_owned()
    };
    assert_eq!(
        refusal(json!("https://example.com/cat.png")),
        "E_COMPLETION_CONTEXT_UNSUPPORTED",
    );
    assert_eq!(
        refusal(json!("data:image/tiff;base64,QUJD")),
        "E_COMPLETION_CONTEXT_UNSUPPORTED",
    );
    assert_eq!(refusal(json!("data:image/png;base64,")), "E_COMPLETION_TRANSCRIPT");
    assert_eq!(refusal(json!("data:image/png,QUJD")), "E_COMPLETION_CONTEXT_UNSUPPORTED");
}
