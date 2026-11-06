//! Turning a streamed completion into the reply a non-streamed one would be.
//!
//! Both hosts had their own copy of this: iOS in `DSHStreamEvents.mm`,
//! Android in `AndroidModelTransport`. Android's leaned on a platform line
//! reader, which hid the cases that actually break a stream parser -- a
//! multi-byte character split across two chunks, a `data:` line arriving in
//! three pieces, two events in one read.
//!
//! So this takes bytes, not lines. The host hands over whatever the socket
//! gave it and carries an opaque state between calls; only complete lines are
//! decoded, so a chunk boundary can fall anywhere, including inside a
//! character. What comes out at the end is the *non-streaming* response
//! shape, which means everything downstream -- the validation in
//! [`crate::completion_response::parse`], the digests, the receipt -- is the
//! same code for a streamed reply as for a whole one.
//!
//! Where the two hosts disagreed, this keeps the stricter rule, so that
//! adopting it can only narrow what a provider gets away with: iOS's caps on
//! a line and on a tool-call fragment, and Android's refusal to read the
//! literal string `"null"` as a finish reason.
//!
//! The two hosts also framed events differently, and this keeps both. SSE
//! lets one event carry several `data:` lines joined by newlines, ended by a
//! blank line, which is what iOS read; every provider this app speaks to puts
//! one event on one line and Android read that. So a `data:` line is
//! dispatched the moment what has accumulated is a complete event, and
//! otherwise held for the next one. Per-line streams behave exactly as they
//! did, and a split event is joined rather than misread.

use serde_json::{json, Map, Value};

/// Beyond this a stream is not a reply any more.
const MAX_STREAM_BYTES: u64 = 4 * 1024 * 1024;
/// One line of it, from `DSHStreamMaxLineBytes`.
const MAX_LINE_BYTES: usize = 256 * 1024;
/// How many calls one reply may ask for, from the non-streaming parser.
const MAX_TOOL_CALLS: usize = 16;
/// `data:` lines one event may be spelled across, from
/// `DSHStreamMaxBufferedLines`. Reaching it means what is accumulating never
/// was an event.
const MAX_EVENT_LINES: usize = 64;

const RESPONSE_JSON: &str = "E_COMPLETION_RESPONSE_JSON";
const RESPONSE_SIZE: &str = "E_COMPLETION_RESPONSE_SIZE";

/// Why a stream was refused, beside the code the host reports.
///
/// The code is what the round records; the reason is what the host needs to
/// say the same thing its own vocabulary said before it asked the core --
/// iOS distinguishes six of these and its tests name them, so a single code
/// for "unreadable" would lose what the move was supposed to preserve.
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub struct Failure {
    pub code: &'static str,
    pub reason: &'static str,
}

const fn unreadable(reason: &'static str) -> Failure {
    Failure {
        code: RESPONSE_JSON,
        reason,
    }
}

const fn oversized(reason: &'static str) -> Failure {
    Failure {
        code: RESPONSE_SIZE,
        reason,
    }
}

/// A line, or trailing bytes, that are not valid UTF-8.
const NOT_UTF8: Failure = unreadable("not_utf8");
/// A `data:` payload that is not JSON at all.
const NOT_JSON: Failure = unreadable("not_json");
/// JSON that is not an object, which no chunk is.
const NOT_AN_OBJECT: Failure = unreadable("not_an_object");
/// A tool-call fragment that cannot be placed or read.
const TOOL_FRAGMENT: Failure = unreadable("tool_fragment");
/// Lines that never added up to an event.
const TOO_MANY_LINES: Failure = unreadable("too_many_lines");
/// A stream that stopped before it said what it was.
const INCOMPLETE: Failure = unreadable("incomplete");
/// An envelope this cannot read at all.
const BAD_REQUEST: Failure = unreadable("bad_request");
/// The provider said, in the stream, that the round failed.
const STREAM_ERROR: Failure = unreadable("stream_error");
/// A status or stop reason this does not know how to read.
const UNKNOWN_STATUS: Failure = unreadable("unknown_status");
/// An output item or content block that cannot be placed or read.
const UNUSABLE_ITEM: Failure = unreadable("unusable_item");
/// One line longer than a line may be.
const LINE_TOO_LONG: Failure = oversized("line_too_long");
/// More bytes than a reply may be.
const STREAM_TOO_LONG: Failure = oversized("stream_too_long");
/// More than the host budgeted for what the reply says.
const OVER_BUDGET: Failure = oversized("over_budget");

/// The wire a stream is read from.
///
/// The framing is the same for all three -- lines, `event:` and `data:`
/// fields, a blank line ending an event -- so only what one event *means*
/// differs, and that is all this chooses.
#[derive(PartialEq, Eq, Clone, Copy)]
enum Wire {
    /// OpenAI chat completions: DeepSeek, GLM.
    ChatCompletions,
    /// OpenAI responses: Codex.
    Responses,
    /// Anthropic messages: Claude.
    Messages,
}

impl Wire {
    fn named(name: Option<&str>) -> Self {
        match name {
            Some("responses") => Wire::Responses,
            Some("messages") => Wire::Messages,
            _ => Wire::ChatCompletions,
        }
    }

    fn name(self) -> &'static str {
        match self {
            Wire::ChatCompletions => "chat-completions",
            Wire::Responses => "responses",
            Wire::Messages => "messages",
        }
    }
}

/// The state the host carries between chunks. Opaque to it; plain JSON here
/// so a stuck stream can be read in a log.
struct Stream {
    carry: Vec<u8>,
    event: Vec<String>,
    /// The `event:` line naming what is accumulating, for the dialects that
    /// send one. The payload's own `type` wins where both are present, so a
    /// missing `event:` line can never hide an error.
    event_name: Option<String>,
    wire: Wire,
    id: Option<String>,
    model: Option<String>,
    finish: Option<String>,
    text: String,
    reasoning: String,
    calls: Vec<Call>,
    done: bool,
    bytes: u64,
}

struct Call {
    index: i64,
    id: String,
    name: String,
    arguments: String,
}

impl Stream {
    fn new() -> Self {
        Stream {
            carry: Vec::new(),
            event: Vec::new(),
            event_name: None,
            wire: Wire::ChatCompletions,
            id: None,
            model: None,
            finish: None,
            text: String::new(),
            reasoning: String::new(),
            calls: Vec::new(),
            done: false,
            bytes: 0,
        }
    }

    fn from_value(value: Option<&Value>) -> Result<Self, Failure> {
        let Some(value) = value else {
            return Ok(Stream::new());
        };
        if value.is_null() {
            return Ok(Stream::new());
        }
        let map = value.as_object().ok_or(BAD_REQUEST)?;
        let text_at = |key: &str| -> Option<String> {
            map.get(key).and_then(Value::as_str).map(str::to_owned)
        };
        let calls = match map.get("calls") {
            None | Some(Value::Null) => Vec::new(),
            Some(Value::Array(items)) => items
                .iter()
                .map(|item| {
                    Ok(Call {
                        index: item
                            .get("index")
                            .and_then(Value::as_i64)
                            .ok_or(BAD_REQUEST)?,
                        id: item
                            .get("id")
                            .and_then(Value::as_str)
                            .unwrap_or_default()
                            .to_owned(),
                        name: item
                            .get("name")
                            .and_then(Value::as_str)
                            .unwrap_or_default()
                            .to_owned(),
                        arguments: item
                            .get("arguments")
                            .and_then(Value::as_str)
                            .unwrap_or_default()
                            .to_owned(),
                    })
                })
                .collect::<Result<Vec<Call>, Failure>>()?,
            Some(_) => return Err(BAD_REQUEST),
        };
        let event = match map.get("event") {
            None | Some(Value::Null) => Vec::new(),
            Some(Value::Array(lines)) => lines
                .iter()
                .map(|line| line.as_str().map(str::to_owned).ok_or(BAD_REQUEST))
                .collect::<Result<Vec<String>, Failure>>()?,
            Some(_) => return Err(BAD_REQUEST),
        };
        Ok(Stream {
            carry: decode_base64(
                map.get("carry_base64")
                    .and_then(Value::as_str)
                    .unwrap_or(""),
            )
            .ok_or(BAD_REQUEST)?,
            event,
            event_name: text_at("event_name"),
            wire: Wire::named(map.get("wire").and_then(Value::as_str)),
            id: text_at("id"),
            model: text_at("model"),
            finish: text_at("finish_reason"),
            text: text_at("text").unwrap_or_default(),
            reasoning: text_at("reasoning").unwrap_or_default(),
            calls,
            done: map.get("done") == Some(&Value::Bool(true)),
            bytes: map.get("bytes").and_then(Value::as_u64).unwrap_or(0),
        })
    }

    fn to_value(&self) -> Value {
        json!({
            "schema_version": 1,
            "carry_base64": encode_base64(&self.carry),
            "event": self.event,
            "event_name": self.event_name,
            "wire": self.wire.name(),
            "id": self.id,
            "model": self.model,
            "finish_reason": self.finish,
            "text": self.text,
            "reasoning": self.reasoning,
            "calls": self.calls.iter().map(|call| json!({
                "index": call.index,
                "id": call.id,
                "name": call.name,
                "arguments": call.arguments,
            })).collect::<Vec<Value>>(),
            "done": self.done,
            "bytes": self.bytes,
        })
    }

    /// Bytes of what the reply says: text, reasoning and tool arguments.
    fn spoken(&self) -> u64 {
        (self.text.len() + self.reasoning.len()) as u64
            + self
                .calls
                .iter()
                .map(|call| call.arguments.len() as u64)
                .sum::<u64>()
    }

    fn call_at(&mut self, index: i64) -> &mut Call {
        if let Some(position) = self.calls.iter().position(|call| call.index == index) {
            return &mut self.calls[position];
        }
        self.calls.push(Call {
            index,
            id: String::new(),
            name: String::new(),
            arguments: String::new(),
        });
        let last = self.calls.len() - 1;
        &mut self.calls[last]
    }
}

/// Feeds one chunk in and answers the previews it produced.
fn chunk(state: &mut Stream, bytes: &[u8]) -> Result<Vec<Value>, Failure> {
    // The cap is on the whole stream, which is also what bounds the carry: a
    // line that never ends is carried undecoded, and reaches this first.
    state.bytes = state.bytes.saturating_add(bytes.len() as u64);
    if state.bytes > MAX_STREAM_BYTES {
        return Err(STREAM_TOO_LONG);
    }
    state.carry.extend_from_slice(bytes);
    let mut previews = Vec::new();
    loop {
        let Some(position) = state.carry.iter().position(|byte| *byte == b'\n') else {
            // A line that is still arriving is bounded too: it is carried
            // undecoded, and a provider with no newline in a quarter of a
            // mebibyte is not sending events.
            if state.carry.len() > MAX_LINE_BYTES {
                return Err(LINE_TOO_LONG);
            }
            break;
        };
        if position > MAX_LINE_BYTES {
            return Err(LINE_TOO_LONG);
        }
        let line: Vec<u8> = state.carry.drain(..=position).collect();
        // The newline, and a carriage return before it, belong to the framing
        // rather than to the payload.
        let mut end = line.len() - 1;
        if end > 0 && line[end - 1] == b'\r' {
            end -= 1;
        }
        if let Some(event) = line_read(state, &line[..end])? {
            previews.push(event);
        }
    }
    Ok(previews)
}

/// One complete line of framing: a comment, a field this does not read, a
/// blank line ending an event, or another `data:` line of one.
fn line_read(state: &mut Stream, line: &[u8]) -> Result<Option<Value>, Failure> {
    // Anything that is not valid UTF-8 cannot be a line this reads, and must
    // not be mistaken for a blank one.
    let Ok(line) = std::str::from_utf8(line) else {
        return Err(NOT_UTF8);
    };
    if line.is_empty() {
        // A blank line ends whatever was accumulating, complete or not.
        return settle(state);
    }
    if line.starts_with(':') {
        // A comment or a keep-alive, which ends nothing.
        return Ok(None);
    }
    if let Some(name) = line.strip_prefix("event:") {
        // Names what is about to arrive; it ends nothing.
        state.event_name = Some(name.strip_prefix(' ').unwrap_or(name).to_owned());
        return Ok(None);
    }
    let Some(payload) = line.strip_prefix("data:") else {
        // `id:`, `retry:` and anything else: not read, not an end.
        return Ok(None);
    };
    // SSE strips one space after the colon, and no more: the rest is payload.
    state
        .event
        .push(payload.strip_prefix(' ').unwrap_or(payload).to_owned());
    // An event is usually one line, and this is where that is noticed: what
    // has accumulated goes out the moment it is a whole event, so a per-line
    // stream never waits for the blank line that ends it.
    if whole(&state.event) {
        return settle(state);
    }
    if state.event.len() > MAX_EVENT_LINES {
        // Whatever this is, it stopped being an event some lines ago.
        return Err(TOO_MANY_LINES);
    }
    Ok(None)
}

/// Whether the accumulated lines already say everything an event says.
fn whole(lines: &[String]) -> bool {
    let joined = lines.join("\n");
    let trimmed = joined.trim();
    trimmed.is_empty()
        || trimmed == "[DONE]"
        || serde_json::from_str::<Value>(trimmed).is_ok_and(|value| value.is_object())
}

/// Reads whatever has accumulated as one event and starts the next.
fn settle(state: &mut Stream) -> Result<Option<Value>, Failure> {
    if state.event.is_empty() {
        return Ok(None);
    }
    let payload = state.event.join("\n");
    state.event.clear();
    let payload = payload.trim();
    // A bare `data:` keep-alive carries nothing, which is not a failure.
    if payload.is_empty() {
        return Ok(None);
    }
    if payload == "[DONE]" {
        state.done = true;
        return Ok(None);
    }
    // Everything after the terminator is noise, not a continuation.
    if state.done {
        return Ok(None);
    }
    let decoded: Value = serde_json::from_str(payload).map_err(|_| NOT_JSON)?;
    let Some(object) = decoded.as_object() else {
        return Err(NOT_AN_OBJECT);
    };
    let named = state.event_name.take();
    match state.wire {
        Wire::ChatCompletions => chat_completions_event(state, object),
        Wire::Responses => responses_event(state, object, named.as_deref()),
        Wire::Messages => messages_event(state, object, named.as_deref()),
    }
}

/// One OpenAI chat-completions chunk: DeepSeek and GLM.
fn chat_completions_event(
    state: &mut Stream,
    object: &Map<String, Value>,
) -> Result<Option<Value>, Failure> {
    if state.id.is_none() {
        state.id = non_empty(object.get("id"));
    }
    if state.model.is_none() {
        state.model = non_empty(object.get("model"));
    }
    let Some(choice) = object
        .get("choices")
        .and_then(Value::as_array)
        .and_then(|choices| choices.first())
        .and_then(Value::as_object)
    else {
        return Ok(None);
    };
    let empty = Map::new();
    let delta = choice
        .get("delta")
        .and_then(Value::as_object)
        .unwrap_or(&empty);
    let said = Said {
        text: non_empty(delta.get("content")),
        reasoning: non_empty(delta.get("reasoning_content")),
        // A finish reason spelled as the string "null" is how some providers
        // say "not yet"; it is not a reason.
        finish: non_empty(choice.get("finish_reason")).filter(|reason| reason != "null"),
        fragments: fragments_of(delta.get("tool_calls"), "function")?,
    };
    apply(state, said)
}

/// One OpenAI responses event: Codex.
///
/// The output index doubles as the tool-call index, so two calls stay apart
/// by where the provider put them in its output.
fn responses_event(
    state: &mut Stream,
    object: &Map<String, Value>,
    named: Option<&str>,
) -> Result<Option<Value>, Failure> {
    // The payload's own type is authoritative; the `event:` line is a
    // fallback, so a missing one cannot hide an error.
    let kind = non_empty(object.get("type"))
        .or_else(|| named.map(str::to_owned))
        .unwrap_or_default();
    let response = object.get("response").and_then(Value::as_object);
    if matches!(
        kind.as_str(),
        "response.created" | "response.completed" | "response.incomplete"
    ) {
        if let Some(response) = response {
            if state.id.is_none() {
                state.id = non_empty(response.get("id"));
            }
            if state.model.is_none() {
                state.model = non_empty(response.get("model"));
            }
        }
    }
    let said = match kind.as_str() {
        "response.failed" | "error" => return Err(STREAM_ERROR),
        "response.output_text.delta" => Said {
            text: non_empty(object.get("delta")),
            ..Said::nothing()
        },
        "response.reasoning_summary_text.delta" => Said {
            reasoning: non_empty(object.get("delta")),
            ..Said::nothing()
        },
        "response.completed" | "response.incomplete" => {
            let Some(response) = response else {
                // Terminal but with nothing to read: the round is over, and
                // that it is over is the whole of what this event says.
                state.done = true;
                return Ok(None);
            };
            Said {
                finish: Some(responses_finish(response).ok_or(UNKNOWN_STATUS)?),
                ..Said::nothing()
            }
        }
        "response.output_item.added" => {
            let item = object.get("item").and_then(Value::as_object);
            if item.and_then(|item| non_empty(item.get("type"))).as_deref() != Some("function_call")
            {
                return Ok(None);
            }
            let item = item.expect("checked above");
            let (Some(index), Some(id), Some(name)) = (
                output_index(object.get("output_index")),
                non_empty(item.get("call_id")),
                non_empty(item.get("name")),
            ) else {
                return Err(UNUSABLE_ITEM);
            };
            Said {
                fragments: vec![Fragment {
                    index,
                    id: Some(id),
                    name: Some(name),
                    arguments: None,
                }],
                ..Said::nothing()
            }
        }
        "response.function_call_arguments.delta" => {
            let index = output_index(object.get("output_index")).ok_or(UNUSABLE_ITEM)?;
            match non_empty(object.get("delta")) {
                None => return Ok(None),
                Some(arguments) => Said {
                    fragments: vec![Fragment {
                        index,
                        id: None,
                        name: None,
                        arguments: Some(arguments),
                    }],
                    ..Said::nothing()
                },
            }
        }
        // response.created, in_progress, content_part.*, arguments.done and
        // reasoning_summary_part.* carry nothing to show.
        _ => return Ok(None),
    };
    apply(state, said)
}

/// What a finished responses object says the reason was.
fn responses_finish(response: &Map<String, Value>) -> Option<String> {
    let has_call = response
        .get("output")
        .and_then(Value::as_array)
        .is_some_and(|items| {
            items
                .iter()
                .any(|item| item.get("type").and_then(Value::as_str) == Some("function_call"))
        });
    match non_empty(response.get("status"))
        .unwrap_or_else(|| "completed".to_owned())
        .as_str()
    {
        "completed" => Some(if has_call { "tool_calls" } else { "stop" }.to_owned()),
        "incomplete" => Some(
            if response
                .get("incomplete_details")
                .and_then(Value::as_object)
                .and_then(|details| non_empty(details.get("reason")))
                .as_deref()
                == Some("content_filter")
            {
                "content_filter"
            } else {
                "length"
            }
            .to_owned(),
        ),
        _ => None,
    }
}

/// One Anthropic messages event: Claude.
///
/// The content-block index doubles as the tool-call index.
fn messages_event(
    state: &mut Stream,
    object: &Map<String, Value>,
    named: Option<&str>,
) -> Result<Option<Value>, Failure> {
    let kind = non_empty(object.get("type"))
        .or_else(|| named.map(str::to_owned))
        .unwrap_or_default();
    if let Some(message) = object.get("message").and_then(Value::as_object) {
        if state.id.is_none() {
            state.id = non_empty(message.get("id"));
        }
        if state.model.is_none() {
            state.model = non_empty(message.get("model"));
        }
    }
    let empty = Map::new();
    let said = match kind.as_str() {
        "error" => return Err(STREAM_ERROR),
        "content_block_delta" => {
            let delta = object
                .get("delta")
                .and_then(Value::as_object)
                .unwrap_or(&empty);
            match non_empty(delta.get("type")).unwrap_or_default().as_str() {
                "text_delta" => Said {
                    text: non_empty(delta.get("text")),
                    ..Said::nothing()
                },
                "thinking_delta" => Said {
                    reasoning: non_empty(delta.get("thinking")),
                    ..Said::nothing()
                },
                "input_json_delta" => {
                    let index = output_index(object.get("index")).ok_or(UNUSABLE_ITEM)?;
                    match non_empty(delta.get("partial_json")) {
                        None => return Ok(None),
                        Some(arguments) => Said {
                            fragments: vec![Fragment {
                                index,
                                id: None,
                                name: None,
                                arguments: Some(arguments),
                            }],
                            ..Said::nothing()
                        },
                    }
                }
                // signature_delta carries nothing to show.
                _ => return Ok(None),
            }
        }
        "content_block_start" => {
            let block = object.get("content_block").and_then(Value::as_object);
            if block
                .and_then(|block| non_empty(block.get("type")))
                .as_deref()
                != Some("tool_use")
            {
                return Ok(None);
            }
            let block = block.expect("checked above");
            let (Some(index), Some(id), Some(name)) = (
                output_index(object.get("index")),
                non_empty(block.get("id")),
                non_empty(block.get("name")),
            ) else {
                return Err(UNUSABLE_ITEM);
            };
            Said {
                fragments: vec![Fragment {
                    index,
                    id: Some(id),
                    name: Some(name),
                    arguments: None,
                }],
                ..Said::nothing()
            }
        }
        "message_stop" => {
            // Anthropic ends a stream by saying so rather than with `[DONE]`.
            state.done = true;
            return Ok(None);
        }
        "message_delta" => {
            let stop = object
                .get("delta")
                .and_then(Value::as_object)
                .and_then(|delta| non_empty(delta.get("stop_reason")));
            let Some(stop) = stop else { return Ok(None) };
            Said {
                finish: Some(messages_finish(&stop).ok_or(UNKNOWN_STATUS)?),
                ..Said::nothing()
            }
        }
        _ => return Ok(None),
    };
    apply(state, said)
}

/// Anthropic's stop reasons in the one vocabulary the app accumulates.
fn messages_finish(stop: &str) -> Option<String> {
    Some(
        match stop {
            "end_turn" | "stop_sequence" | "pause_turn" => "stop",
            "tool_use" => "tool_calls",
            "max_tokens" => "length",
            "refusal" => "content_filter",
            _ => return None,
        }
        .to_owned(),
    )
}

/// An output or block index, which is also a tool-call index.
fn output_index(value: Option<&Value>) -> Option<i64> {
    value
        .filter(|value| !value.is_boolean())
        .and_then(Value::as_i64)
        .filter(|index| (0..MAX_TOOL_CALLS as i64).contains(index))
}

/// One chunk's worth of what a reply said, in neither host's spelling.
///
/// A chat-completions chunk and a host's own delta describe the same thing
/// differently, so both are read into this and accumulated by one piece of
/// code. That is the point of the type: a reply assembled from a provider
/// this core parses and one assembled from a dialect it does not cannot
/// drift apart.
struct Said {
    text: Option<String>,
    reasoning: Option<String>,
    finish: Option<String>,
    fragments: Vec<Fragment>,
}

impl Said {
    /// Nothing said, for the events that fill in one field of it.
    fn nothing() -> Self {
        Said {
            text: None,
            reasoning: None,
            finish: None,
            fragments: Vec::new(),
        }
    }
}

struct Fragment {
    index: i64,
    id: Option<String>,
    name: Option<String>,
    arguments: Option<String>,
}

/// Tool-call fragments, from a list that may not be one.
///
/// `nested` names the key holding the name and the arguments: a provider
/// chunk puts them under `function`, a host's own delta puts them beside the
/// index. A fragment this cannot read is not one to skip -- what it
/// describes is a call a person would be asked to approve -- so an unusable
/// one ends the stream.
fn fragments_of(value: Option<&Value>, nested: &str) -> Result<Vec<Fragment>, Failure> {
    let listed = match value {
        None | Some(Value::Null) => return Ok(Vec::new()),
        Some(Value::Array(listed)) if listed.len() <= MAX_TOOL_CALLS => listed,
        Some(_) => return Err(TOOL_FRAGMENT),
    };
    let mut fragments = Vec::with_capacity(listed.len());
    for fragment in listed {
        let Some(fragment) = fragment.as_object() else {
            return Err(TOOL_FRAGMENT);
        };
        // The index is what keeps two interleaved calls apart, so a fragment
        // without a usable one cannot be placed at all.
        let index = match fragment.get("index").and_then(Value::as_i64) {
            Some(index) if (0..MAX_TOOL_CALLS as i64).contains(&index) => index,
            _ => return Err(TOOL_FRAGMENT),
        };
        let inner = fragment.get(nested).and_then(Value::as_object);
        let at = |key: &str| -> Option<String> {
            match inner {
                Some(inner) => non_empty(inner.get(key)),
                None if nested.is_empty() => non_empty(fragment.get(key)),
                None => None,
            }
        };
        fragments.push(Fragment {
            index,
            id: non_empty(fragment.get("id")),
            name: at("name"),
            arguments: at("arguments"),
        });
    }
    Ok(fragments)
}

/// Accumulates what was said and answers what to show for it.
fn apply(state: &mut Stream, said: Said) -> Result<Option<Value>, Failure> {
    let mut event = Map::new();
    if let Some(piece) = said.text {
        state.text.push_str(&piece);
        event.insert("text".into(), Value::String(piece));
    }
    if let Some(piece) = said.reasoning {
        state.reasoning.push_str(&piece);
        event.insert("reasoning".into(), Value::String(piece));
    }
    let mut previewed = Vec::new();
    for fragment in said.fragments {
        let mut preview = Map::new();
        preview.insert("index".into(), json!(fragment.index));
        let call = state.call_at(fragment.index);
        // A call is identified and named once. A provider that says either
        // twice for the same index is contradicting itself, and the first
        // answer is the one the fragments after it were adding to.
        if let Some(identifier) = fragment.id {
            if call.id.is_empty() {
                call.id = identifier.clone();
            }
            preview.insert("id".into(), Value::String(identifier));
        }
        if let Some(name) = fragment.name {
            if call.name.is_empty() {
                call.name = name.clone();
            }
            preview.insert("name".into(), Value::String(name));
        }
        if let Some(arguments) = fragment.arguments {
            call.arguments.push_str(&arguments);
            preview.insert("arguments".into(), Value::String(arguments));
        }
        previewed.push(Value::Object(preview));
    }
    if !previewed.is_empty() {
        event.insert("tool_calls".into(), Value::Array(previewed));
    }
    // What a preview reports is what *this* event said, so a reason is
    // carried once, by the event that gave it, rather than repeated on
    // everything that follows.
    if let Some(reason) = said.finish {
        state.finish = Some(reason.clone());
        event.insert("finish_reason".into(), Value::String(reason));
    }
    // A keep-alive, or a chunk carrying only usage, is nothing to show.
    Ok(if event.is_empty() {
        None
    } else {
        Some(Value::Object(event))
    })
}

/// The wire shape a reply is assembled into.
///
/// A round is settled by the same parser that reads a whole response, so a
/// streamed reply has to look like one the provider sent in one piece --
/// which means three shapes, because three providers say it three ways.
#[derive(PartialEq, Eq, Clone, Copy)]
enum Dialect {
    /// OpenAI `chat.completion`: DeepSeek, GLM.
    ChatCompletions,
    /// OpenAI responses: Codex.
    Responses,
    /// Anthropic messages: Claude.
    Messages,
}

impl Dialect {
    fn named(name: Option<&str>) -> Self {
        match name {
            Some("responses") => Dialect::Responses,
            Some("messages") => Dialect::Messages,
            _ => Dialect::ChatCompletions,
        }
    }
}

/// What the host wants of the assembled reply, where the two differ.
struct Assembly {
    /// `off`, `high` or `max`; a turn that asked to think says so in the
    /// reply even when the model sent no reasoning.
    thinking_mode: String,
    /// Whether a stream that never said what it was fails here, or is
    /// answered with nulls for the response parser to reject.
    require_identity: bool,
    /// The shape to answer in.
    dialect: Dialect,
}

impl Assembly {
    fn from_envelope(envelope: &Value) -> Self {
        Assembly {
            thinking_mode: envelope
                .get("thinking_mode")
                .and_then(Value::as_str)
                .unwrap_or("off")
                .to_owned(),
            require_identity: envelope.get("require_identity") != Some(&Value::Bool(false)),
            dialect: Dialect::named(envelope.get("dialect").and_then(Value::as_str)),
        }
    }
}

/// The reply the stream described, in the shape a whole response arrives in.
fn finish(state: &Stream, want: &Assembly) -> Result<Value, Failure> {
    if want.require_identity
        && (state.id.is_none() || state.model.is_none() || state.finish.is_none())
    {
        // A stream that stopped before it said what it was is not a reply.
        return Err(INCOMPLETE);
    }
    // The wire may interleave fragments; the batch is ordered by index,
    // because that is the order the model asked for.
    let mut calls: Vec<&Call> = state.calls.iter().collect();
    calls.sort_by_key(|call| call.index);
    // A turn that asked to think reports the reasoning it got, even when
    // that is none; a turn that never asked says nothing about it.
    let spoke_reasoning = !state.reasoning.is_empty() || want.thinking_mode != "off";
    Ok(match want.dialect {
        Dialect::ChatCompletions => chat_completion(state, &calls, spoke_reasoning),
        Dialect::Responses => response_output(state, &calls, spoke_reasoning),
        Dialect::Messages => message_content(state, &calls, spoke_reasoning),
    })
}

/// OpenAI's `chat.completion`, which DeepSeek and GLM answer in.
fn chat_completion(state: &Stream, calls: &[&Call], reasoning: bool) -> Value {
    let mut message = Map::new();
    message.insert("role".into(), json!("assistant"));
    if !calls.is_empty() {
        message.insert(
            "tool_calls".into(),
            Value::Array(
                calls
                    .iter()
                    .map(|call| {
                        let mut function = Map::new();
                        if !call.name.is_empty() {
                            function.insert("name".into(), json!(call.name));
                        }
                        function.insert("arguments".into(), json!(call.arguments));
                        let mut entry = Map::new();
                        if !call.id.is_empty() {
                            entry.insert("id".into(), json!(call.id));
                        }
                        entry.insert("type".into(), json!("function"));
                        entry.insert("function".into(), Value::Object(function));
                        // A call the provider never named or identified keeps
                        // the key absent rather than empty, so the response
                        // parser refuses it exactly as it refuses a malformed
                        // one that arrived whole.
                        Value::Object(entry)
                    })
                    .collect(),
            ),
        );
    }
    // A tool-only turn carries null content, which is what the provider sends
    // when it does not stream.
    message.insert(
        "content".into(),
        if state.text.is_empty() && !calls.is_empty() {
            Value::Null
        } else {
            Value::String(state.text.clone())
        },
    );
    if reasoning {
        message.insert(
            "reasoning_content".into(),
            Value::String(state.reasoning.clone()),
        );
    }
    json!({
        "id": state.id,
        "object": "chat.completion",
        "model": state.model,
        "choices": [{
            "index": 0,
            "message": Value::Object(message),
            "finish_reason": state.finish,
        }],
    })
}

/// OpenAI's responses shape, which Codex answers in: a list of output items
/// rather than one message, and a status rather than a finish reason.
fn response_output(state: &Stream, calls: &[&Call], reasoning: bool) -> Value {
    let mut output = Vec::new();
    if reasoning {
        output.push(json!({
            "type": "reasoning",
            "summary": [{ "type": "summary_text", "text": state.reasoning }],
        }));
    }
    if !state.text.is_empty() {
        output.push(json!({
            "type": "message",
            "role": "assistant",
            "content": [{ "type": "output_text", "text": state.text }],
        }));
    }
    for call in calls {
        let mut item = Map::new();
        item.insert("type".into(), json!("function_call"));
        if !call.id.is_empty() {
            item.insert("call_id".into(), json!(call.id));
        }
        if !call.name.is_empty() {
            item.insert("name".into(), json!(call.name));
        }
        item.insert("arguments".into(), json!(call.arguments));
        output.push(Value::Object(item));
    }
    let mut object = Map::new();
    object.insert("object".into(), json!("response"));
    if let Some(id) = &state.id {
        object.insert("id".into(), json!(id));
    }
    if let Some(model) = &state.model {
        object.insert("model".into(), json!(model));
    }
    object.insert("output".into(), Value::Array(output));
    // A stream that stopped short is in progress, not complete: the status
    // is what this dialect's parser reads to decide that.
    match state.finish.as_deref() {
        Some("stop") | Some("tool_calls") => {
            object.insert("status".into(), json!("completed"));
        }
        Some(reason @ ("length" | "content_filter")) => {
            object.insert("status".into(), json!("incomplete"));
            object.insert(
                "incomplete_details".into(),
                json!({ "reason": if reason == "length" {
                    "max_output_tokens"
                } else {
                    "content_filter"
                } }),
            );
        }
        _ => {
            object.insert("status".into(), json!("in_progress"));
        }
    }
    Value::Object(object)
}

/// Anthropic's messages shape, which Claude answers in: content blocks, and
/// tool input as an object rather than a string of JSON.
fn message_content(state: &Stream, calls: &[&Call], reasoning: bool) -> Value {
    let mut content = Vec::new();
    if reasoning {
        content.push(json!({ "type": "thinking", "thinking": state.reasoning }));
    }
    if !state.text.is_empty() {
        content.push(json!({ "type": "text", "text": state.text }));
    }
    for call in calls {
        let mut block = Map::new();
        block.insert("type".into(), json!("tool_use"));
        if !call.id.is_empty() {
            block.insert("id".into(), json!(call.id));
        }
        if !call.name.is_empty() {
            block.insert("name".into(), json!(call.name));
        }
        // Anthropic sends an empty input as "" or "{}"; anything that is not
        // an object stays null, for the response parser to refuse.
        block.insert(
            "input".into(),
            if call.arguments.is_empty() {
                json!({})
            } else {
                serde_json::from_str::<Value>(&call.arguments)
                    .ok()
                    .filter(Value::is_object)
                    .unwrap_or(Value::Null)
            },
        );
        content.push(Value::Object(block));
    }
    let mut object = Map::new();
    object.insert("type".into(), json!("message"));
    object.insert("role".into(), json!("assistant"));
    if let Some(id) = &state.id {
        object.insert("id".into(), json!(id));
    }
    if let Some(model) = &state.model {
        object.insert("model".into(), json!(model));
    }
    object.insert("content".into(), Value::Array(content));
    // A stream that never delivered message_delta is incomplete: an unknown
    // stop reason makes the parser reject it rather than default to a turn
    // that ended normally.
    object.insert(
        "stop_reason".into(),
        json!(match state.finish.as_deref() {
            Some("stop") => "end_turn",
            Some("tool_calls") => "tool_use",
            Some("length") => "max_tokens",
            Some("content_filter") => "refusal",
            _ => "stream_incomplete",
        }),
    );
    Value::Object(object)
}

fn non_empty(value: Option<&Value>) -> Option<String> {
    match value.and_then(Value::as_str) {
        Some(text) if !text.is_empty() => Some(text.to_owned()),
        _ => None,
    }
}

/// `{"op":"stream_chunk","state":<state|null>,"chunk_base64":"...",
/// "maximum_bytes":N}`
pub fn stream_chunk(envelope: &Value) -> Value {
    refused_or(chunked(envelope))
}

fn chunked(envelope: &Value) -> Result<Value, Failure> {
    let mut state = Stream::from_value(envelope.get("state"))?;
    // Named once, on the first chunk, and carried from there.
    if let Some(wire) = envelope.get("wire").and_then(Value::as_str) {
        state.wire = Wire::named(Some(wire));
    }
    let bytes = decode_base64(
        envelope
            .get("chunk_base64")
            .and_then(Value::as_str)
            .ok_or(BAD_REQUEST)?,
    )
    .ok_or(BAD_REQUEST)?;
    let previews = chunk(&mut state, &bytes)?;
    // The budget is on what the reply *says*, not on what crossed the wire,
    // and it is checked as the stream runs so a runaway one is stopped where
    // it happens rather than at the end.
    if let Some(budget) = envelope.get("maximum_bytes").and_then(Value::as_u64) {
        if state.spoken() > budget {
            return Err(OVER_BUDGET);
        }
    }
    Ok(json!({
        "ok": true,
        "state": state.to_value(),
        "previews": previews,
        // `[DONE]` is not a preview -- there is nothing to show -- but the
        // host needs to know the provider said it.
        "done": state.done,
    }))
}

/// `{"op":"assemble_delta","state":<state|null>,"delta":{...},"id":"...",
/// "model":"...","maximum_bytes":N}`
///
/// For a dialect this core does not parse. Codex and Anthropic speak their
/// own wire and their hosts reduce it to one delta vocabulary; this takes
/// that vocabulary and accumulates it exactly as a parsed chunk is
/// accumulated, so all three dialects assemble through one piece of code.
pub fn assemble_delta(envelope: &Value) -> Value {
    refused_or(assembled(envelope))
}

fn assembled(envelope: &Value) -> Result<Value, Failure> {
    let mut state = Stream::from_value(envelope.get("state"))?;
    // The identity is observed on the wire, not in the delta, so the host
    // hands it over beside one. The first non-empty answer wins.
    if state.id.is_none() {
        state.id = non_empty(envelope.get("id"));
    }
    if state.model.is_none() {
        state.model = non_empty(envelope.get("model"));
    }
    let empty = Map::new();
    let delta = envelope
        .get("delta")
        .and_then(Value::as_object)
        .unwrap_or(&empty);
    // Only a delta says anything; `done` and the rest are framing.
    let preview = if delta.get("type") == Some(&json!("delta")) {
        apply(
            &mut state,
            Said {
                text: non_empty(delta.get("content")),
                reasoning: non_empty(delta.get("reasoning")),
                finish: non_empty(delta.get("finish_reason")),
                // This vocabulary puts the name and the arguments beside the
                // index rather than under a `function`.
                fragments: fragments_of(delta.get("tool_calls"), "")?,
            },
        )?
    } else {
        None
    };
    if let Some(budget) = envelope.get("maximum_bytes").and_then(Value::as_u64) {
        if state.spoken() > budget {
            return Err(OVER_BUDGET);
        }
    }
    Ok(json!({
        "ok": true,
        "state": state.to_value(),
        "previews": preview.map(|one| vec![one]).unwrap_or_default(),
        "done": state.done,
    }))
}

/// `{"op":"stream_flush","state":<state>}`
///
/// The end of the socket, which is not the end of a line. Whatever is still
/// carried is read as a final line and whatever that leaves accumulated is
/// read as a final event, so a provider that stopped without its last
/// newline is understood rather than dropped.
pub fn stream_flush(envelope: &Value) -> Value {
    refused_or(flushed(envelope))
}

fn flushed(envelope: &Value) -> Result<Value, Failure> {
    let mut state = Stream::from_value(envelope.get("state"))?;
    let mut previews = Vec::new();
    if !state.carry.is_empty() {
        let line = std::mem::take(&mut state.carry);
        let end = if line.last() == Some(&b'\r') {
            line.len() - 1
        } else {
            line.len()
        };
        if let Some(preview) = line_read(&mut state, &line[..end])? {
            previews.push(preview);
        }
    }
    if let Some(preview) = settle(&mut state)? {
        previews.push(preview);
    }
    Ok(json!({
        "ok": true,
        "state": state.to_value(),
        "previews": previews,
        "done": state.done,
    }))
}

/// `{"op":"stream_finish","state":<state>,"thinking_mode":"off",
/// "require_identity":true,"dialect":"chat-completions"}`
pub fn stream_finish(envelope: &Value) -> Value {
    refused_or(finished(envelope))
}

fn finished(envelope: &Value) -> Result<Value, Failure> {
    let state = Stream::from_value(envelope.get("state"))?;
    let want = Assembly::from_envelope(envelope);
    Ok(json!({ "ok": true, "response": finish(&state, &want)? }))
}

/// The answer, or the refusal written out for the host to translate.
fn refused_or(answer: Result<Value, Failure>) -> Value {
    answer.unwrap_or_else(
        |failure| json!({ "ok": false, "failure_code": failure.code, "reason": failure.reason }),
    )
}

const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// Base64 without a dependency: chunks cross this boundary as text, and this
/// is the whole of what that costs.
fn encode_base64(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for group in bytes.chunks(3) {
        let b0 = group[0] as u32;
        let b1 = *group.get(1).unwrap_or(&0) as u32;
        let b2 = *group.get(2).unwrap_or(&0) as u32;
        let triple = (b0 << 16) | (b1 << 8) | b2;
        out.push(ALPHABET[(triple >> 18) as usize & 63] as char);
        out.push(ALPHABET[(triple >> 12) as usize & 63] as char);
        out.push(if group.len() > 1 {
            ALPHABET[(triple >> 6) as usize & 63] as char
        } else {
            '='
        });
        out.push(if group.len() > 2 {
            ALPHABET[triple as usize & 63] as char
        } else {
            '='
        });
    }
    out
}

fn decode_base64(text: &str) -> Option<Vec<u8>> {
    let trimmed = text.trim_end_matches('=');
    let mut out = Vec::with_capacity(trimmed.len() / 4 * 3);
    let mut accumulator: u32 = 0;
    let mut held = 0;
    for byte in trimmed.bytes() {
        let value = ALPHABET.iter().position(|candidate| *candidate == byte)? as u32;
        accumulator = (accumulator << 6) | value;
        held += 6;
        if held >= 8 {
            held -= 8;
            out.push(((accumulator >> held) & 0xff) as u8);
        }
    }
    // Whatever is left over must be padding bits, and padding is zero.
    if accumulator & ((1 << held) - 1) != 0 {
        return None;
    }
    Some(out)
}

#[cfg(test)]
#[path = "completion_stream_tests.rs"]
mod tests;
