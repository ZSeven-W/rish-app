//! The cases a line-reading stream parser cannot be asked about.
//!
//! Every test here drives the reducer the way the host does -- bytes in,
//! state carried between calls -- so the chunk boundaries are part of what is
//! under test. `served` splits a transcript at every possible boundary and
//! insists the answer never depends on where the socket happened to break.

use super::*;

const HOST: &str = "chatcmpl-1";

fn envelope_chunk(state: &Value, bytes: &[u8]) -> Value {
    let answer = stream_chunk(&json!({
        "op": "stream_chunk",
        "state": state.clone(),
        "chunk_base64": encode_base64(bytes),
    }));
    assert_eq!(answer["ok"], json!(true), "the chunk was refused: {answer}");
    answer
}

/// The code and the reason of a refusal, so a test can name both.
fn refusal(answer: &Value) -> (&str, &str) {
    assert_eq!(answer["ok"], json!(false), "this was not refused: {answer}");
    (
        answer["failure_code"].as_str().expect("a failure code"),
        answer["reason"].as_str().expect("a reason"),
    )
}

/// Feeds `pieces` in order and answers `(state, previews)`.
fn feed(pieces: &[&[u8]]) -> (Value, Vec<Value>) {
    let mut state = Value::Null;
    let mut previews = Vec::new();
    for piece in pieces {
        let answer = envelope_chunk(&state, piece);
        state = answer["state"].clone();
        previews.extend(answer["previews"].as_array().expect("previews").clone());
    }
    (state, previews)
}

fn assembled(state: &Value) -> Value {
    let answer = stream_finish(&json!({ "op": "stream_finish", "state": state.clone() }));
    assert_eq!(
        answer["ok"],
        json!(true),
        "the stream did not assemble: {answer}"
    );
    answer["response"].clone()
}

fn message(response: &Value) -> Value {
    response["choices"][0]["message"].clone()
}

/// The transcript every test that does not care about framing uses.
fn transcript() -> String {
    [
        format!(
            "data: {{\"id\":\"{HOST}\",\"model\":\"deepseek-chat\",\
             \"choices\":[{{\"index\":0,\"delta\":{{\"content\":\"Hello\"}}}}]}}\n\n"
        ),
        format!(
            "data: {{\"id\":\"{HOST}\",\"model\":\"deepseek-chat\",\
             \"choices\":[{{\"index\":0,\"delta\":{{\"content\":\" world\"}},\
             \"finish_reason\":\"stop\"}}]}}\n\n"
        ),
        "data: [DONE]\n\n".to_owned(),
    ]
    .concat()
}

/// The whole transcript in one piece, and the reply it describes.
#[test]
fn a_stream_becomes_the_reply_a_whole_response_would_be() {
    let (state, previews) = feed(&[transcript().as_bytes()]);
    assert_eq!(previews.len(), 2);
    assert_eq!(previews[0], json!({ "text": "Hello" }));
    assert_eq!(
        previews[1],
        json!({ "text": " world", "finish_reason": "stop" })
    );

    let response = assembled(&state);
    assert_eq!(response["id"], json!(HOST));
    assert_eq!(response["model"], json!("deepseek-chat"));
    assert_eq!(response["choices"][0]["finish_reason"], json!("stop"));
    assert_eq!(response["object"], json!("chat.completion"));
    // A turn that did not ask to think, and got none, says nothing about it.
    assert_eq!(
        message(&response),
        json!({ "role": "assistant", "content": "Hello world" }),
    );
}

/// The reason this takes bytes: the same transcript cut at every offset --
/// mid-line, mid-token, mid-character -- has to give the same reply.
#[test]
fn where_the_socket_breaks_cannot_change_the_answer() {
    let bytes = transcript().into_bytes();
    let whole = assembled(&feed(&[&bytes]).0);
    for split in 1..bytes.len() {
        let (state, _) = feed(&[&bytes[..split], &bytes[split..]]);
        assert_eq!(
            assembled(&state),
            whole,
            "a split at {split} changed the reply"
        );
    }
}

/// A character split across a chunk boundary is one character, not two
/// replacement marks -- the bug a platform line reader hides.
#[test]
fn a_character_split_between_chunks_survives() {
    let line = format!(
        "data: {{\"id\":\"{HOST}\",\"model\":\"m\",\"choices\":[{{\"delta\":\
         {{\"content\":\"你好\"}},\"finish_reason\":\"stop\"}}]}}\n\n"
    );
    let bytes = line.as_bytes();
    // "你" is three bytes; break inside it.
    let inside = line.find("你").expect("the character is there") + 1;
    let (state, previews) = feed(&[&bytes[..inside], &bytes[inside..]]);
    assert_eq!(previews[0]["text"], json!("你好"));
    assert_eq!(message(&assembled(&state))["content"], json!("你好"));
}

/// Several events in one chunk are several events.
#[test]
fn a_chunk_carrying_three_events_previews_three_times() {
    let mut wire = String::new();
    for piece in ["a", "b", "c"] {
        wire.push_str(&format!(
            "data: {{\"id\":\"{HOST}\",\"model\":\"m\",\"choices\":[{{\"delta\":\
             {{\"content\":\"{piece}\"}}}}]}}\n\n"
        ));
    }
    let (_, previews) = feed(&[wire.as_bytes()]);
    assert_eq!(previews.len(), 3);
    assert_eq!(previews[2], json!({ "text": "c" }));
}

/// Arguments arrive a few characters at a time and are one string at the end.
#[test]
fn half_an_argument_is_not_an_argument_until_it_is_whole() {
    let mut wire = format!(
        "data: {{\"id\":\"{HOST}\",\"model\":\"m\",\"choices\":[{{\"delta\":{{\"tool_calls\":\
         [{{\"index\":0,\"id\":\"call_1\",\"function\":{{\"name\":\"read_file\",\
         \"arguments\":\"\"}}}}]}}}}]}}\n\n"
    );
    for piece in ["{\\\"path\\\"", ":\\\"a.txt", "\\\"}"] {
        wire.push_str(&format!(
            "data: {{\"id\":\"{HOST}\",\"model\":\"m\",\"choices\":[{{\"delta\":{{\"tool_calls\":\
             [{{\"index\":0,\"function\":{{\"arguments\":\"{piece}\"}}}}]}}}}]}}\n\n"
        ));
    }
    wire.push_str(&format!(
        "data: {{\"id\":\"{HOST}\",\"model\":\"m\",\"choices\":[{{\"delta\":{{}},\
         \"finish_reason\":\"tool_calls\"}}]}}\n\ndata: [DONE]\n\n"
    ));

    let (state, previews) = feed(&[wire.as_bytes()]);
    // The first preview names the call; the ones after it carry only the
    // fragment that arrived, never the accumulation.
    assert_eq!(previews[0]["tool_calls"][0]["name"], json!("read_file"));
    assert_eq!(
        previews[1]["tool_calls"][0]["arguments"],
        json!("{\"path\"")
    );
    assert!(previews[1]["tool_calls"][0].get("name").is_none());

    let calls = message(&assembled(&state))["tool_calls"].clone();
    assert_eq!(
        calls,
        json!([{
            "id": "call_1",
            "type": "function",
            "function": { "name": "read_file", "arguments": "{\"path\":\"a.txt\"}" },
        }]),
    );
}

/// Two calls whose fragments interleave stay two calls, in index order, even
/// though the wire put the second one first.
#[test]
fn interleaved_tool_calls_are_kept_apart_and_ordered() {
    let mut wire = String::new();
    for (slot, identifier, name, piece) in [
        (1, "call_b", "write_file", "{\"b\""),
        (0, "call_a", "read_file", "{\"a\""),
        (1, "", "", ":2}"),
        (0, "", "", ":1}"),
    ] {
        let function = if name.is_empty() {
            format!("{{\"arguments\":\"{}\"}}", piece.replace('"', "\\\""))
        } else {
            format!(
                "{{\"name\":\"{name}\",\"arguments\":\"{}\"}}",
                piece.replace('"', "\\\"")
            )
        };
        let identifier = if identifier.is_empty() {
            String::new()
        } else {
            format!("\"id\":\"{identifier}\",")
        };
        wire.push_str(&format!(
            "data: {{\"id\":\"{HOST}\",\"model\":\"m\",\"choices\":[{{\"delta\":{{\"tool_calls\":\
             [{{\"index\":{slot},{identifier}\"function\":{function}}}]}}}}]}}\n\n"
        ));
    }
    wire.push_str(&format!(
        "data: {{\"id\":\"{HOST}\",\"model\":\"m\",\"choices\":[{{\"delta\":{{}},\
         \"finish_reason\":\"tool_calls\"}}]}}\n\n"
    ));

    let (state, _) = feed(&[wire.as_bytes()]);
    let calls = message(&assembled(&state))["tool_calls"].clone();
    assert_eq!(calls.as_array().expect("two calls").len(), 2);
    assert_eq!(calls[0]["id"], json!("call_a"));
    assert_eq!(calls[0]["function"]["arguments"], json!("{\"a\":1}"));
    assert_eq!(calls[1]["id"], json!("call_b"));
    assert_eq!(calls[1]["function"]["arguments"], json!("{\"b\":2}"));
}

/// A tool-call fragment this cannot place is the end of the stream, not a
/// fragment to skip: what it describes is a call a person would approve.
#[test]
fn an_unplaceable_tool_call_fragment_ends_the_stream() {
    let refused = |fragments: &str| -> Value {
        let wire = format!(
            "data: {{\"id\":\"{HOST}\",\"model\":\"m\",\"choices\":[{{\"delta\":\
             {{\"tool_calls\":{fragments}}}}}]}}\n\n"
        );
        stream_chunk(&json!({
            "state": Value::Null,
            "chunk_base64": encode_base64(wire.as_bytes()),
        }))
    };
    let placed = ("E_COMPLETION_RESPONSE_JSON", "tool_fragment");
    // No index at all: nothing says which of two interleaved calls this is.
    assert_eq!(
        refusal(&refused("[{\"id\":\"a\",\"function\":{\"name\":\"one\"}}]")),
        placed,
    );
    // An index no reply could have, and one that is not a whole number.
    assert_eq!(refusal(&refused("[{\"index\":16}]")), placed);
    assert_eq!(refusal(&refused("[{\"index\":-1}]")), placed);
    assert_eq!(refusal(&refused("[{\"index\":\"0\"}]")), placed);
    // A fragment that is not an object, and a list that is not one either.
    assert_eq!(refusal(&refused("[7]")), placed);
    assert_eq!(refusal(&refused("{\"index\":0}")), placed);
    // More calls than a reply may ask for.
    let many: Vec<String> = (0..17)
        .map(|slot| format!("{{\"index\":{slot}}}"))
        .collect();
    assert_eq!(refusal(&refused(&format!("[{}]", many.join(",")))), placed);
    // A null list is a provider saying there are none, which is not a fault.
    assert_eq!(refused("null")["ok"], json!(true));
}

/// One line may not grow without end either, whether or not the stream has.
#[test]
fn a_line_past_the_line_cap_is_refused() {
    let mut line = b"data: ".to_vec();
    line.extend(std::iter::repeat_n(b'x', 256 * 1024));
    assert_eq!(
        refusal(&stream_chunk(&json!({
            "state": Value::Null,
            "chunk_base64": encode_base64(&line),
        }))),
        ("E_COMPLETION_RESPONSE_SIZE", "line_too_long"),
    );
}

/// Reasoning is kept apart from the answer, both while it streams and after.
#[test]
fn reasoning_is_its_own_channel() {
    let wire = format!(
        "data: {{\"id\":\"{HOST}\",\"model\":\"m\",\"choices\":[{{\"delta\":\
         {{\"reasoning_content\":\"think\"}}}}]}}\n\n\
         data: {{\"id\":\"{HOST}\",\"model\":\"m\",\"choices\":[{{\"delta\":\
         {{\"content\":\"say\"}},\"finish_reason\":\"stop\"}}]}}\n\n"
    );
    let (state, previews) = feed(&[wire.as_bytes()]);
    assert_eq!(previews[0], json!({ "reasoning": "think" }));
    assert_eq!(
        message(&assembled(&state)),
        json!({ "role": "assistant", "content": "say", "reasoning_content": "think" }),
    );
}

/// A turn that asked to think reports the reasoning it got, even when that
/// is none: an empty string says the model returned none, and saying nothing
/// would say the turn never asked.
#[test]
fn a_thinking_turn_reports_reasoning_it_never_got() {
    let (state, _) = feed(&[transcript().as_bytes()]);
    let response =
        stream_finish(&json!({ "state": state, "thinking_mode": "high" }))["response"].clone();
    assert_eq!(message(&response)["reasoning_content"], json!(""));
}

/// A tool-only turn carries null content, which is what the provider sends
/// when it does not stream -- and a call it never named keeps the key absent
/// rather than empty, so the response parser refuses it the same way.
#[test]
fn a_tool_only_turn_carries_null_content() {
    let wire = format!(
        "data: {{\"id\":\"{HOST}\",\"model\":\"m\",\"choices\":[{{\"delta\":\
         {{\"tool_calls\":[{{\"index\":0,\"function\":{{\"arguments\":\"{{}}\"}}}}]}},\
         \"finish_reason\":\"tool_calls\"}}]}}\n\n"
    );
    let (state, _) = feed(&[wire.as_bytes()]);
    let message = message(&assembled(&state));
    assert_eq!(message["content"], Value::Null);
    assert_eq!(
        message["tool_calls"],
        json!([{ "type": "function", "function": { "arguments": "{}" } }]),
    );
}

/// The host may ask for the nulls instead of the failure, so that a reply
/// that never said what it was is refused by the response parser, with the
/// code that names what was missing.
#[test]
fn a_host_may_take_the_nulls_instead_of_the_failure() {
    let wire = format!(
        "data: {{\"id\":\"{HOST}\",\"model\":\"m\",\"choices\":[{{\"delta\":\
         {{\"content\":\"half\"}}}}]}}\n\n"
    );
    let (state, _) = feed(&[wire.as_bytes()]);
    assert_eq!(
        refusal(&stream_finish(&json!({ "state": state.clone() }))),
        ("E_COMPLETION_RESPONSE_JSON", "incomplete"),
    );
    let response =
        stream_finish(&json!({ "state": state, "require_identity": false }))["response"].clone();
    assert_eq!(response["choices"][0]["finish_reason"], Value::Null);
    assert_eq!(response["id"], json!(HOST));
}

/// What the reply *says* is budgeted, and the budget is checked as the
/// stream runs rather than once it is over.
#[test]
fn a_reply_past_its_budget_is_refused_where_it_happens() {
    let say = |piece: &str| {
        format!(
            "data: {{\"id\":\"{HOST}\",\"model\":\"m\",\"choices\":[{{\"delta\":\
             {{\"content\":\"{piece}\"}}}}]}}\n\n"
        )
    };
    let budgeted = |state: Value, wire: &str| {
        stream_chunk(&json!({
            "state": state,
            "chunk_base64": encode_base64(wire.as_bytes()),
            "maximum_bytes": 8,
        }))
    };
    let state = budgeted(Value::Null, &say("12345678"))["state"].clone();
    assert_eq!(
        refusal(&budgeted(state, &say("9"))),
        ("E_COMPLETION_RESPONSE_SIZE", "over_budget"),
    );
}

/// Framing this parser must step over: comments, keep-alives, blank data,
/// event names, CRLF line ends, and a chunk that says nothing to show.
#[test]
fn framing_that_is_not_an_event_shows_nothing() {
    let wire = format!(
        ": ping\r\n\
         event: message\r\n\
         data:\r\n\
         data: {{\"id\":\"{HOST}\",\"model\":\"m\",\"usage\":{{\"total_tokens\":3}},\
         \"choices\":[{{\"delta\":{{}}}}]}}\r\n\r\n\
         data: {{\"id\":\"{HOST}\",\"model\":\"m\",\"choices\":[{{\"delta\":\
         {{\"content\":\"x\"}},\"finish_reason\":\"stop\"}}]}}\r\n\r\n"
    );
    let (state, previews) = feed(&[wire.as_bytes()]);
    assert_eq!(
        previews.len(),
        1,
        "only the chunk with something in it: {previews:?}"
    );
    assert_eq!(previews[0], json!({ "text": "x", "finish_reason": "stop" }));
    assert_eq!(message(&assembled(&state))["content"], json!("x"));
}

/// A finish reason spelled as the string "null" is a provider saying "not
/// yet", and a stream that only ever said that has not finished.
#[test]
fn a_finish_reason_of_null_is_not_a_reason() {
    let wire = format!(
        "data: {{\"id\":\"{HOST}\",\"model\":\"m\",\"choices\":[{{\"delta\":\
         {{\"content\":\"x\"}},\"finish_reason\":\"null\"}}]}}\n\n"
    );
    let (state, previews) = feed(&[wire.as_bytes()]);
    assert_eq!(previews[0], json!({ "text": "x" }));
    assert_eq!(
        refusal(&stream_finish(&json!({ "state": state }))),
        ("E_COMPLETION_RESPONSE_JSON", "incomplete"),
    );
}

/// Everything after the terminator is noise, and saying it twice is not an
/// error -- but neither may it add to the reply.
#[test]
fn a_repeated_terminator_adds_nothing() {
    let wire = format!(
        "data: {{\"id\":\"{HOST}\",\"model\":\"m\",\"choices\":[{{\"delta\":\
         {{\"content\":\"x\"}},\"finish_reason\":\"stop\"}}]}}\n\n\
         data: [DONE]\n\n\
         data: {{\"id\":\"{HOST}\",\"model\":\"m\",\"choices\":[{{\"delta\":\
         {{\"content\":\"after\"}}}}]}}\n\n\
         data: [DONE]\n\n"
    );
    let (state, previews) = feed(&[wire.as_bytes()]);
    assert_eq!(previews.len(), 1);
    assert_eq!(message(&assembled(&state))["content"], json!("x"));
}

/// A stream that stops in the middle of a line is a stream that did not say
/// what it was: the half-line is never parsed, and there is no reply.
#[test]
fn a_stream_cut_short_has_no_reply() {
    let wire = format!(
        "data: {{\"id\":\"{HOST}\",\"model\":\"m\",\"choices\":[{{\"delta\":\
         {{\"content\":\"x\"}}}}]}}\n\n\
         data: {{\"id\":\"{HOST}\",\"model\":\"m\",\"choi"
    );
    let (state, previews) = feed(&[wire.as_bytes()]);
    assert_eq!(previews.len(), 1);
    assert_eq!(
        refusal(&stream_finish(&json!({ "state": state }))),
        ("E_COMPLETION_RESPONSE_JSON", "incomplete"),
    );
}

/// A `data:` line that is not JSON is the reply being unreadable, not an
/// event to skip.
#[test]
fn a_data_line_that_is_not_json_fails_the_stream() {
    let answer = stream_chunk(&json!({
        "state": Value::Null,
        "chunk_base64": encode_base64(b"data: {not json}\n\n"),
    }));
    assert_eq!(refusal(&answer), ("E_COMPLETION_RESPONSE_JSON", "not_json"));
    // JSON that is not an object is a different fault, and says so.
    let answer = stream_chunk(&json!({
        "state": Value::Null,
        "chunk_base64": encode_base64(b"data: [1,2]\n\n"),
    }));
    assert_eq!(
        refusal(&answer),
        ("E_COMPLETION_RESPONSE_JSON", "not_an_object")
    );
    // And bytes that are not UTF-8 are never mistaken for a blank line.
    let answer = stream_chunk(&json!({
        "state": Value::Null,
        "chunk_base64": encode_base64(&[b'd', b'a', b't', b'a', b':', 0xff, b'\n']),
    }));
    assert_eq!(refusal(&answer), ("E_COMPLETION_RESPONSE_JSON", "not_utf8"));
}

/// Past four mebibytes a stream is not a reply, counted across chunks even
/// when every line in it was short enough on its own.
#[test]
fn a_stream_past_the_cap_is_refused() {
    let mut state = Value::Null;
    // Comment lines: read and discarded, so nothing accumulates but the count.
    let filler: Vec<u8> = ": keep-alive\n".repeat(32 * 1024).into_bytes();
    let mut sent = 0u64;
    while sent + filler.len() as u64 <= 4 * 1024 * 1024 {
        state = envelope_chunk(&state, &filler)["state"].clone();
        sent += filler.len() as u64;
    }
    // Whatever is left under the cap, and then one byte past it.
    let remainder = vec![b'\n'; (4 * 1024 * 1024 - sent) as usize];
    state = envelope_chunk(&state, &remainder)["state"].clone();
    assert_eq!(
        refusal(&stream_chunk(
            &json!({ "state": state, "chunk_base64": encode_base64(b"x") })
        )),
        ("E_COMPLETION_RESPONSE_SIZE", "stream_too_long"),
    );
}

/// A line that never ends is refused rather than carried without limit, and
/// it is refused on the chunk that passes the cap, not at the end.
#[test]
fn a_line_that_never_ends_is_refused() {
    let mut state = Value::Null;
    let filler = vec![b'x'; 64 * 1024];
    for _ in 0..8 {
        let answer = stream_chunk(&json!({
            "state": state.clone(),
            "chunk_base64": encode_base64(&filler),
        }));
        if answer["ok"] == json!(false) {
            assert_eq!(
                refusal(&answer),
                ("E_COMPLETION_RESPONSE_SIZE", "line_too_long")
            );
            return;
        }
        state = answer["state"].clone();
    }
    panic!("an unbounded line was carried");
}

/// The state crosses the bridge as JSON, so what comes back has to be what
/// went out -- including a carry that is half a character.
#[test]
fn the_carried_state_survives_a_round_trip_through_json() {
    let bytes = transcript().into_bytes();
    let head = transcript().find("world").expect("mid-line") + 2;
    let mut state = envelope_chunk(&Value::Null, &bytes[..head])["state"].clone();
    let text = serde_json::to_string(&state).expect("the state is JSON");
    state = serde_json::from_str(&text).expect("and reads back");
    let state = envelope_chunk(&state, &bytes[head..])["state"].clone();
    assert_eq!(message(&assembled(&state))["content"], json!("Hello world"));
}

/// The op the host calls, refused the way the dispatcher refuses.
#[test]
fn a_chunk_without_bytes_is_a_bad_request() {
    let asked = ("E_COMPLETION_RESPONSE_JSON", "bad_request");
    assert_eq!(
        refusal(&stream_chunk(&json!({ "op": "stream_chunk" }))),
        asked
    );
    assert_eq!(
        refusal(&stream_chunk(
            &json!({ "op": "stream_chunk", "chunk_base64": "not base64!" })
        )),
        asked,
    );
    assert_eq!(
        refusal(&stream_chunk(
            &json!({ "op": "stream_chunk", "state": 7, "chunk_base64": "" })
        )),
        asked,
    );
}

/// The base64 that carries the bytes, over the cases that break a hand-rolled
/// one: every length modulo three, and every byte value.
#[test]
fn base64_round_trips_every_byte_and_every_length() {
    for length in 0..=48usize {
        let bytes: Vec<u8> = (0..length).map(|index| (index * 7 % 256) as u8).collect();
        let text = encode_base64(&bytes);
        assert_eq!(text.len() % 4, 0, "length {length} is not padded");
        assert_eq!(decode_base64(&text).as_deref(), Some(bytes.as_slice()));
    }
    let every: Vec<u8> = (0..=255u8).collect();
    assert_eq!(
        decode_base64(&encode_base64(&every)).as_deref(),
        Some(every.as_slice())
    );
    assert_eq!(decode_base64("!!!!"), None);
    // Padding bits that are not zero are not a base64 text this wrote.
    assert_eq!(decode_base64("AB"), None);
}

/// SSE lets one event be spelled across several `data:` lines, joined by
/// newlines and ended by a blank line. No provider here sends one, but iOS
/// read them, so this does too -- and a comment in the middle of one does
/// not split it.
#[test]
fn an_event_spelled_across_several_data_lines_is_one_event() {
    let wire = format!(
        "data: {{\"id\":\"{HOST}\",\"model\":\"m\",\n\
         : still the same event\n\
         data: \"choices\":[{{\"delta\":{{\"content\":\"split\"}},\n\
         data: \"finish_reason\":\"stop\"}}]}}\n\
         \n\
         data: [DONE]\n\n"
    );
    let (state, previews) = feed(&[wire.as_bytes()]);
    assert_eq!(
        previews,
        vec![json!({ "text": "split", "finish_reason": "stop" })]
    );
    assert_eq!(message(&assembled(&state))["content"], json!("split"));
}

/// Lines that never add up to an event are refused rather than accumulated
/// until the stream cap: the failure says the reply was unreadable, which is
/// what happened, not that it was too big.
#[test]
fn lines_that_never_become_an_event_are_refused() {
    let wire = "data: {\n".repeat(65);
    assert_eq!(
        refusal(&stream_chunk(&json!({
            "state": Value::Null,
            "chunk_base64": encode_base64(wire.as_bytes()),
        }))),
        ("E_COMPLETION_RESPONSE_JSON", "too_many_lines"),
    );
}

/// SSE strips one space after the colon and no more, so a payload that
/// begins with whitespace keeps the rest of it.
#[test]
fn only_the_first_space_after_the_colon_is_framing() {
    let wire = format!(
        "data:{{\"id\":\"{HOST}\",\"model\":\"m\",\"choices\":[{{\"delta\":\
         {{\"content\":\" indented\"}},\"finish_reason\":\"stop\"}}]}}\n\n"
    );
    let (state, _) = feed(&[wire.as_bytes()]);
    assert_eq!(message(&assembled(&state))["content"], json!(" indented"));
}

/// A socket that stopped without its last newline still said what it said:
/// the trailing line is read at the end rather than dropped.
#[test]
fn a_final_line_without_its_newline_is_still_read() {
    let mut wire = transcript();
    // Take away the newline that ends the last event, and the terminator.
    wire.truncate(wire.find("data: [DONE]").expect("a terminator"));
    let wire = wire.trim_end().to_owned();
    let cut = wire.rfind("data:").expect("a last event");
    let bytes = wire.as_bytes();
    let (state, previews) = feed(&[&bytes[..cut], &bytes[cut..]]);
    // Nothing was said about the last event while it was still arriving.
    assert_eq!(previews.len(), 1);

    let flushed = stream_flush(&json!({ "op": "stream_flush", "state": state }));
    assert_eq!(flushed["ok"], json!(true), "{flushed}");
    assert_eq!(
        flushed["previews"],
        json!([{ "text": " world", "finish_reason": "stop" }]),
    );
    assert_eq!(
        message(&assembled(&flushed["state"]))["content"],
        json!("Hello world"),
    );
}

/// Flushing a stream that ended cleanly says nothing more, and flushing one
/// that ended mid-token is the reply being unreadable.
#[test]
fn flushing_says_only_what_is_left() {
    let (state, _) = feed(&[transcript().as_bytes()]);
    let flushed = stream_flush(&json!({ "state": state }));
    assert_eq!(flushed["previews"], json!([]));
    assert_eq!(flushed["done"], json!(true));

    let (half, _) = feed(&[b"data: {\"id\":\"x\",\"choi"]);
    assert_eq!(
        refusal(&stream_flush(&json!({ "state": half }))),
        ("E_COMPLETION_RESPONSE_JSON", "not_json"),
    );
}

/// A preview says what its own event said. A provider that reports the
/// finish reason before the last of the text does not make every event after
/// it claim to be the end.
#[test]
fn a_finish_reason_is_previewed_once() {
    let wire = format!(
        "data: {{\"id\":\"{HOST}\",\"model\":\"m\",\"choices\":[{{\"delta\":\
         {{\"content\":\"a\"}},\"finish_reason\":\"stop\"}}]}}\n\n\
         data: {{\"id\":\"{HOST}\",\"model\":\"m\",\"choices\":[{{\"delta\":\
         {{\"content\":\"b\"}}}}]}}\n\n"
    );
    let (state, previews) = feed(&[wire.as_bytes()]);
    assert_eq!(previews[0], json!({ "text": "a", "finish_reason": "stop" }));
    assert_eq!(previews[1], json!({ "text": "b" }));
    // And the reply still ends the way the provider said it did.
    assert_eq!(
        assembled(&state)["choices"][0]["finish_reason"],
        json!("stop")
    );
}

/// A delta from a dialect this core does not parse accumulates exactly as a
/// parsed chunk does. Codex and Anthropic reduce their own wire to this
/// vocabulary, and the reply they get is assembled by the same code.
fn delta(state: Value, delta: Value) -> Value {
    let answer = assemble_delta(&json!({
        "op": "assemble_delta",
        "state": state,
        "delta": delta,
        "id": "resp-1",
        "model": "some-model",
    }));
    assert_eq!(answer["ok"], json!(true), "the delta was refused: {answer}");
    answer
}

#[test]
fn a_hosts_own_delta_accumulates_like_a_parsed_chunk() {
    let mut state = Value::Null;
    let mut previews = Vec::new();
    for one in [
        json!({ "type": "delta", "reasoning": "thinking" }),
        json!({ "type": "delta", "content": "half " }),
        json!({ "type": "delta", "content": "and half" }),
        json!({ "type": "delta", "tool_calls": [
            { "index": 0, "id": "call_a", "name": "read_file", "arguments": "{\"a\"" }
        ] }),
        json!({ "type": "delta", "tool_calls": [{ "index": 0, "arguments": ":1}" }] }),
        json!({ "type": "delta", "finish_reason": "tool_calls" }),
        // Framing, which says nothing.
        json!({ "type": "done" }),
    ] {
        let answer = delta(state, one);
        state = answer["state"].clone();
        previews.extend(answer["previews"].as_array().expect("previews").clone());
    }
    assert_eq!(previews.len(), 6);
    let message = message(&assembled(&state));
    assert_eq!(message["content"], json!("half and half"));
    assert_eq!(message["reasoning_content"], json!("thinking"));
    assert_eq!(
        message["tool_calls"][0]["function"],
        json!({ "name": "read_file", "arguments": "{\"a\":1}" }),
    );
}

/// The same refusals apply to a delta as to a chunk: a fragment that cannot
/// be placed ends the stream, and so does going past the budget.
#[test]
fn a_delta_is_refused_on_the_same_terms() {
    let unplaceable = assemble_delta(&json!({
        "state": Value::Null,
        "delta": { "type": "delta", "tool_calls": [{ "name": "no_index" }] },
    }));
    assert_eq!(
        refusal(&unplaceable),
        ("E_COMPLETION_RESPONSE_JSON", "tool_fragment"),
    );
    let over = assemble_delta(&json!({
        "state": Value::Null,
        "delta": { "type": "delta", "content": "123456789" },
        "maximum_bytes": 8,
    }));
    assert_eq!(
        refusal(&over),
        ("E_COMPLETION_RESPONSE_SIZE", "over_budget")
    );
}

/// One accumulated stream, three wire shapes, because three providers say a
/// reply three ways and the round is settled by the parser for each.
fn spoken_turn() -> Value {
    let wire = format!(
        "data: {{\"id\":\"{HOST}\",\"model\":\"m\",\"choices\":[{{\"delta\":\
         {{\"reasoning_content\":\"why\",\"content\":\"here it is\",\"tool_calls\":\
         [{{\"index\":0,\"id\":\"c1\",\"function\":{{\"name\":\"read_file\",\
         \"arguments\":\"{{\\\"path\\\":\\\"a.txt\\\"}}\"}}}}]}},\
         \"finish_reason\":\"tool_calls\"}}]}}\n\n"
    );
    feed(&[wire.as_bytes()]).0
}

fn shaped(state: &Value, dialect: &str) -> Value {
    let answer = stream_finish(&json!({ "state": state.clone(), "dialect": dialect }));
    assert_eq!(answer["ok"], json!(true), "{answer}");
    answer["response"].clone()
}

#[test]
fn the_responses_dialect_answers_in_output_items() {
    let response = shaped(&spoken_turn(), "responses");
    assert_eq!(response["object"], json!("response"));
    assert_eq!(response["status"], json!("completed"));
    assert_eq!(
        response["output"],
        json!([
            { "type": "reasoning", "summary": [{ "type": "summary_text", "text": "why" }] },
            { "type": "message", "role": "assistant",
              "content": [{ "type": "output_text", "text": "here it is" }] },
            { "type": "function_call", "call_id": "c1", "name": "read_file",
              "arguments": "{\"path\":\"a.txt\"}" },
        ]),
    );
}

#[test]
fn the_messages_dialect_answers_in_content_blocks() {
    let response = shaped(&spoken_turn(), "messages");
    assert_eq!(response["type"], json!("message"));
    assert_eq!(response["stop_reason"], json!("tool_use"));
    assert_eq!(
        response["content"],
        json!([
            { "type": "thinking", "thinking": "why" },
            { "type": "text", "text": "here it is" },
            // The arguments become an object here, because that is what
            // Anthropic sends when it does not stream.
            { "type": "tool_use", "id": "c1", "name": "read_file",
              "input": { "path": "a.txt" } },
        ]),
    );
}

/// A stream that stopped before it said how it ended must be refused by each
/// dialect's own parser, so each says so in its own vocabulary rather than
/// defaulting to a turn that ended normally.
#[test]
fn a_turn_that_never_ended_says_so_in_every_dialect() {
    let wire = format!(
        "data: {{\"id\":\"{HOST}\",\"model\":\"m\",\"choices\":[{{\"delta\":\
         {{\"content\":\"half\"}}}}]}}\n\n"
    );
    let (state, _) = feed(&[wire.as_bytes()]);
    let loosely = |dialect: &str| {
        stream_finish(&json!({
            "state": state.clone(),
            "dialect": dialect,
            "require_identity": false,
        }))["response"]
            .clone()
    };
    assert_eq!(loosely("responses")["status"], json!("in_progress"));
    assert_eq!(
        loosely("messages")["stop_reason"],
        json!("stream_incomplete")
    );
    assert_eq!(
        loosely("chat-completions")["choices"][0]["finish_reason"],
        Value::Null,
    );
    // A length stop is incomplete rather than merely unfinished.
    assert_eq!(
        shaped(&spoken_turn(), "responses")["incomplete_details"],
        Value::Null,
    );
}

/// A call is identified and named once. A second answer for the same index
/// contradicts the first, and the fragments in between were adding to the
/// first -- so that is the one the reply keeps.
#[test]
fn a_call_keeps_the_first_name_it_was_given() {
    let fragment = |body: &str| {
        format!(
            "data: {{\"id\":\"{HOST}\",\"model\":\"m\",\"choices\":[{{\"delta\":\
             {{\"tool_calls\":[{body}]}}}}]}}\n\n"
        )
    };
    let mut wire = fragment(
        "{\"index\":0,\"id\":\"call_a\",\"function\":{\"name\":\"read_file\",\
         \"arguments\":\"{\\\"a\\\"\"}}",
    );
    wire.push_str(&fragment(
        "{\"index\":0,\"id\":\"call_z\",\"function\":{\"name\":\"write_file\",\
         \"arguments\":\":1}\"}}",
    ));
    wire.push_str(&format!(
        "data: {{\"id\":\"{HOST}\",\"model\":\"m\",\"choices\":[{{\"delta\":{{}},\
         \"finish_reason\":\"tool_calls\"}}]}}\n\n"
    ));
    let (state, previews) = feed(&[wire.as_bytes()]);
    // The preview still reports what the wire said, because that is what the
    // wire said; only what is kept is the first answer.
    assert_eq!(previews[1]["tool_calls"][0]["id"], json!("call_z"));
    assert_eq!(
        message(&assembled(&state))["tool_calls"][0],
        json!({
            "id": "call_a",
            "type": "function",
            "function": { "name": "read_file", "arguments": "{\"a\":1}" },
        }),
    );
}

/// Reads a stream off one of the other two wires.
fn wired(wire: &str, pieces: &[&[u8]]) -> (Value, Vec<Value>) {
    let mut state = Value::Null;
    let mut previews = Vec::new();
    for piece in pieces {
        let answer = stream_chunk(&json!({
            "state": state,
            "wire": wire,
            "chunk_base64": encode_base64(piece),
        }));
        assert_eq!(answer["ok"], json!(true), "the chunk was refused: {answer}");
        state = answer["state"].clone();
        previews.extend(answer["previews"].as_array().expect("previews").clone());
    }
    (state, previews)
}

/// Codex's responses wire: the output index is the tool-call index, the
/// identity arrives on `response.created`, and the finish reason is read off
/// the terminal response object rather than stated.
#[test]
fn the_responses_wire_reads_a_whole_round() {
    let wire = concat!(
        "event: response.created\n",
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_1\",\"model\":\"gpt-x\"}}\n\n",
        "event: response.reasoning_summary_text.delta\n",
        "data: {\"type\":\"response.reasoning_summary_text.delta\",\"delta\":\"why\"}\n\n",
        "event: response.output_text.delta\n",
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"here\"}\n\n",
        "event: response.output_item.added\n",
        "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\
         \"item\":{\"type\":\"function_call\",\"call_id\":\"c1\",\"name\":\"read_file\"}}\n\n",
        "data: {\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\
         \"delta\":\"{\\\"path\\\"\"}\n\n",
        "data: {\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\
         \"delta\":\":\\\"a.txt\\\"}\"}\n\n",
        "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\
         \"model\":\"gpt-x\",\"status\":\"completed\",\
         \"output\":[{\"type\":\"function_call\"}]}}\n\n",
    );
    let (state, previews) = wired("responses", &[wire.as_bytes()]);
    assert_eq!(previews[0], json!({ "reasoning": "why" }));
    assert_eq!(previews[1], json!({ "text": "here" }));
    assert_eq!(
        previews[2]["tool_calls"][0],
        json!({ "index": 0, "id": "c1", "name": "read_file" }),
    );

    // And it assembles back into the shape Codex sends when it does not
    // stream, which is what settles the round.
    let response = shaped(&state, "responses");
    assert_eq!(response["id"], json!("resp_1"));
    assert_eq!(response["status"], json!("completed"));
    assert_eq!(
        response["output"].as_array().expect("output").last(),
        Some(
            &json!({ "type": "function_call", "call_id": "c1", "name": "read_file",
                      "arguments": "{\"path\":\"a.txt\"}" })
        ),
    );
}

/// Anthropic's messages wire: the block index is the tool-call index, the
/// arguments arrive as partial JSON, and the stop reason is translated.
#[test]
fn the_messages_wire_reads_a_whole_round() {
    let wire = concat!(
        "event: message_start\n",
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"model\":\"claude-x\"}}\n\n",
        "data: {\"type\":\"content_block_delta\",\"index\":0,\
         \"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"why\"}}\n\n",
        "data: {\"type\":\"content_block_delta\",\"index\":0,\
         \"delta\":{\"type\":\"text_delta\",\"text\":\"here\"}}\n\n",
        "data: {\"type\":\"content_block_start\",\"index\":1,\
         \"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_1\",\"name\":\"read_file\"}}\n\n",
        "data: {\"type\":\"content_block_delta\",\"index\":1,\
         \"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"path\\\"\"}}\n\n",
        "data: {\"type\":\"content_block_delta\",\"index\":1,\
         \"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\":\\\"a.txt\\\"}\"}}\n\n",
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"}}\n\n",
    );
    let (state, previews) = wired("messages", &[wire.as_bytes()]);
    assert_eq!(previews[0], json!({ "reasoning": "why" }));
    assert_eq!(previews[1], json!({ "text": "here" }));
    assert_eq!(previews[2]["tool_calls"][0]["name"], json!("read_file"));
    assert_eq!(
        previews.last().expect("a last event")["finish_reason"],
        json!("tool_calls")
    );

    let response = shaped(&state, "messages");
    assert_eq!(response["id"], json!("msg_1"));
    assert_eq!(response["stop_reason"], json!("tool_use"));
    assert_eq!(
        response["content"].as_array().expect("content").last(),
        Some(
            &json!({ "type": "tool_use", "id": "tu_1", "name": "read_file",
                      "input": { "path": "a.txt" } })
        ),
    );
}

/// What each of the other two wires refuses, and in its own word for it.
#[test]
fn the_other_wires_refuse_what_they_cannot_read() {
    let sent = |wire: &str, event: &str| {
        stream_chunk(&json!({
            "state": Value::Null,
            "wire": wire,
            "chunk_base64": encode_base64(format!("data: {event}\n\n").as_bytes()),
        }))
    };
    // A provider that says in the stream that the round failed.
    assert_eq!(
        refusal(&sent("responses", "{\"type\":\"response.failed\"}")),
        ("E_COMPLETION_RESPONSE_JSON", "stream_error"),
    );
    assert_eq!(
        refusal(&sent(
            "messages",
            "{\"type\":\"error\",\"error\":{\"type\":\"overloaded\"}}"
        )),
        ("E_COMPLETION_RESPONSE_JSON", "stream_error"),
    );
    // A status or stop reason neither knows how to read. Defaulting either
    // to a turn that ended normally would settle a round on a guess.
    assert_eq!(
        refusal(&sent(
            "responses",
            "{\"type\":\"response.completed\",\"response\":{\"status\":\"cancelled\"}}",
        )),
        ("E_COMPLETION_RESPONSE_JSON", "unknown_status"),
    );
    assert_eq!(
        refusal(&sent(
            "messages",
            "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"who_knows\"}}",
        )),
        ("E_COMPLETION_RESPONSE_JSON", "unknown_status"),
    );
    // An item that names a call but cannot be placed.
    assert_eq!(
        refusal(&sent(
            "responses",
            "{\"type\":\"response.output_item.added\",\
             \"item\":{\"type\":\"function_call\",\"call_id\":\"c\",\"name\":\"n\"}}",
        )),
        ("E_COMPLETION_RESPONSE_JSON", "unusable_item"),
    );
    assert_eq!(
        refusal(&sent(
            "messages",
            "{\"type\":\"content_block_start\",\"index\":99,\
             \"content_block\":{\"type\":\"tool_use\",\"id\":\"t\",\"name\":\"n\"}}",
        )),
        ("E_COMPLETION_RESPONSE_JSON", "unusable_item"),
    );
}

/// The `event:` line is a fallback, not the authority: a payload that names
/// itself an error is an error even when the event line says otherwise.
#[test]
fn the_payloads_own_type_wins_over_the_event_line() {
    let wire = "event: response.output_text.delta\n\
                data: {\"type\":\"response.failed\"}\n\n";
    assert_eq!(
        refusal(&stream_chunk(&json!({
            "state": Value::Null,
            "wire": "responses",
            "chunk_base64": encode_base64(wire.as_bytes()),
        }))),
        ("E_COMPLETION_RESPONSE_JSON", "stream_error"),
    );
    // And with no type at all the event line is what there is to go on.
    let named = "event: response.output_text.delta\ndata: {\"delta\":\"x\"}\n\n";
    let (_, previews) = wired("responses", &[named.as_bytes()]);
    assert_eq!(previews, vec![json!({ "text": "x" })]);
}

/// The wire is named once and carried, so a chunk boundary between the
/// `event:` line and its `data:` line changes nothing.
#[test]
fn the_wire_and_the_event_name_survive_a_chunk_boundary() {
    let wire = "event: response.output_text.delta\ndata: {\"delta\":\"split\"}\n\n";
    let bytes = wire.as_bytes();
    let cut = wire.find("data:").expect("a data line");
    let mut state = stream_chunk(&json!({
        "state": Value::Null,
        "wire": "responses",
        "chunk_base64": encode_base64(&bytes[..cut]),
    }));
    assert_eq!(state["previews"], json!([]));
    // The second chunk does not name the wire again.
    let answer = stream_chunk(&json!({
        "state": state["state"].clone(),
        "chunk_base64": encode_base64(&bytes[cut..]),
    }));
    state = answer;
    assert_eq!(state["previews"], json!([{ "text": "split" }]));
}

/// Each wire says a stream is over in its own way, and the host is told the
/// same thing either way: chat completions send `[DONE]`, Anthropic sends
/// `message_stop`, and Codex sends a terminal response event.
#[test]
fn every_wire_says_when_it_is_over() {
    let over = |wire: &str, event: &str| {
        let answer = stream_chunk(&json!({
            "state": Value::Null,
            "wire": wire,
            "chunk_base64": encode_base64(format!("data: {event}\n\n").as_bytes()),
        }));
        assert_eq!(answer["ok"], json!(true), "{answer}");
        answer["done"].clone()
    };
    assert_eq!(over("chat-completions", "[DONE]"), json!(true));
    assert_eq!(over("messages", "{\"type\":\"message_stop\"}"), json!(true));
    assert_eq!(
        over("responses", "{\"type\":\"response.completed\"}"),
        json!(true)
    );
    // And an event that is not the end does not claim to be one.
    assert_eq!(
        over("messages", "{\"type\":\"content_block_stop\",\"index\":0}"),
        json!(false)
    );
}
