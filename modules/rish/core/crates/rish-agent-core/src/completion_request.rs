//! Building the request body a provider round sends.
//!
//! Three dialects, and until now each host wrote its own copy of all three.
//! The differences between them are not stylistic: they are a token ceiling
//! that follows the shape of the round, a thinking vocabulary that follows
//! the model family, and a handful of single words -- `store`, `strict`,
//! `display` -- that appear nowhere else and change what the provider does.
//! One host had four of those wrong, which is what the frozen fixtures found.
//!
//! The bodies here are the ones in
//! `apps/mobile/ios/RishTests/Fixtures/*-request-cases.json`, which were
//! recorded from the host whose receipts have shipped. The tests read those
//! files directly, so this cannot drift from them without saying so.

use serde_json::{json, Map, Value};

/// Room for a whole file inside a tool's arguments, and for reasoning on
/// top of it. Four numbers because a round has four shapes.
const CHAT_PLAIN: i64 = 1024;
const CHAT_PLAIN_THINKING: i64 = 4096;
const CHAT_TOOLS: i64 = 8192;
const CHAT_TOOLS_THINKING: i64 = 16384;

const MESSAGES_PLAIN: i64 = 8192;
const MESSAGES_THINKING: i64 = 16384;
const HAIKU_BUDGET_HIGH: i64 = 4096;
const HAIKU_BUDGET_MAX: i64 = 16000;

const RESPONSES_PLAIN: i64 = 8192;
const RESPONSES_THINKING: i64 = 16384;

const BODY_INVALID: &str = "E_COMPLETION_BODY_INVALID";
const TRANSCRIPT: &str = "E_COMPLETION_TRANSCRIPT";
const TOOLS: &str = "E_COMPLETION_TOOLS";
const CONTEXT_UNSUPPORTED: &str = "E_COMPLETION_CONTEXT_UNSUPPORTED";

/// `{"op":"request_body","dialect":"...","model":"...","thinking_mode":"...",
/// "streaming":true,"messages":[...],"tools":[...]}`
pub fn request_body(envelope: &Value) -> Value {
    match built(envelope) {
        Ok(body) => json!({ "ok": true, "body": body }),
        Err(code) => json!({ "ok": false, "failure_code": code }),
    }
}

fn built(envelope: &Value) -> Result<Value, &'static str> {
    let model = text(envelope.get("model")).ok_or(BODY_INVALID)?;
    let mode = text(envelope.get("thinking_mode")).ok_or(BODY_INVALID)?;
    let streaming = envelope.get("streaming") == Some(&Value::Bool(true));
    let empty = Vec::new();
    let messages = envelope
        .get("messages")
        .and_then(Value::as_array)
        .ok_or(BODY_INVALID)?;
    let tools = envelope
        .get("tools")
        .and_then(Value::as_array)
        .unwrap_or(&empty);
    let thinking = mode != "off";
    match envelope.get("dialect").and_then(Value::as_str) {
        Some("messages") => messages_body(&model, &mode, thinking, streaming, messages, tools),
        Some("responses") => responses_body(&model, &mode, thinking, streaming, messages, tools),
        Some("chat-completions") | None => {
            chat_body(&model, &mode, thinking, streaming, messages, tools)
        }
        Some(_) => Err(BODY_INVALID),
    }
}

/// OpenAI chat completions: DeepSeek and GLM. The turns go as they are.
fn chat_body(
    model: &str,
    mode: &str,
    thinking: bool,
    streaming: bool,
    messages: &[Value],
    tools: &[Value],
) -> Result<Value, &'static str> {
    let mut body = Map::new();
    body.insert("model".into(), json!(model));
    body.insert("stream".into(), json!(streaming));
    body.insert(
        "thinking".into(),
        json!({ "type": if thinking { "enabled" } else { "disabled" } }),
    );
    body.insert(
        "max_tokens".into(),
        json!(match (!tools.is_empty(), thinking) {
            (true, true) => CHAT_TOOLS_THINKING,
            (true, false) => CHAT_TOOLS,
            (false, true) => CHAT_PLAIN_THINKING,
            (false, false) => CHAT_PLAIN,
        }),
    );
    // Every turn goes as it is, except one that carries parts: the host
    // hands those over in the app's own shape, and this is where they become
    // OpenAI's. A turn of plain words is passed through untouched, so the
    // frozen bodies do not move.
    let mut wire = Vec::with_capacity(messages.len());
    for message in messages {
        let role = message.get("role").and_then(Value::as_str);
        match parts_of(message, role)? {
            None => wire.push(message.clone()),
            Some(parts) => {
                let mut turn = message.as_object().cloned().ok_or(TRANSCRIPT)?;
                turn.insert("content".into(), chat_parts(&parts));
                wire.push(Value::Object(turn));
            }
        }
    }
    body.insert("messages".into(), json!(wire));
    if thinking {
        body.insert("reasoning_effort".into(), json!(mode));
    }
    if !tools.is_empty() {
        body.insert("tools".into(), json!(tools));
    }
    Ok(Value::Object(body))
}

/// Which thinking vocabulary a model takes.
enum Family {
    /// `thinking` with a token budget: Haiku, and GLM over the
    /// Anthropic-compatible endpoint. The adaptive words are Anthropic's own.
    Budget,
    /// `adaptive` with a summarized display, and `disabled` when off.
    Adaptive,
    /// Same as adaptive, except thinking cannot be turned off at all.
    AlwaysOn,
}

fn family_of(model: &str) -> Family {
    if model.starts_with("claude-haiku-4-5") || model.starts_with("GLM-") {
        Family::Budget
    } else if model.starts_with("claude-fable-") {
        Family::AlwaysOn
    } else {
        Family::Adaptive
    }
}

/// Anthropic messages: Claude, and GLM over the compatible endpoint.
///
/// The turns arrive in the shape the transcript keeps them and are rewritten
/// here into content blocks, because the rewriting is part of what the
/// dialect is: a tool call and its result have no other form on this wire.
fn messages_body(
    model: &str,
    mode: &str,
    thinking: bool,
    streaming: bool,
    messages: &[Value],
    tools: &[Value],
) -> Result<Value, &'static str> {
    let mut system: Vec<Value> = Vec::new();
    let mut turns: Vec<Value> = Vec::new();
    for message in messages {
        let role = message.get("role").and_then(Value::as_str);
        if role == Some("system") {
            if let Some(text) = text(message.get("content")) {
                system.push(json!({ "type": "text", "text": text }));
            }
            continue;
        }
        append_block(&mut turns, message, role)?;
    }
    let mut body = Map::new();
    body.insert("model".into(), json!(model));
    body.insert("stream".into(), json!(streaming));
    body.insert("messages".into(), Value::Array(turns.clone()));
    let maximal = mode == "max";
    let effort = if maximal { "max" } else { "high" };
    let mut ceiling = MESSAGES_PLAIN;
    match family_of(model) {
        Family::Budget => {
            // A continuation round replays a tool_use turn whose thinking
            // blocks are not in the closed transcript, and the budget API
            // rejects that -- so such a round runs unthinking.
            if thinking && !last_assistant_uses_tools(&turns) {
                let budget = if maximal { HAIKU_BUDGET_MAX } else { HAIKU_BUDGET_HIGH };
                body.insert(
                    "thinking".into(),
                    json!({ "type": "enabled", "budget_tokens": budget }),
                );
                ceiling = budget + MESSAGES_PLAIN;
            }
        }
        Family::Adaptive => {
            if thinking {
                body.insert(
                    "thinking".into(),
                    json!({ "type": "adaptive", "display": "summarized" }),
                );
                body.insert("output_config".into(), json!({ "effort": effort }));
                ceiling = MESSAGES_THINKING;
            } else {
                body.insert("thinking".into(), json!({ "type": "disabled" }));
            }
        }
        Family::AlwaysOn => {
            if thinking {
                body.insert(
                    "thinking".into(),
                    json!({ "type": "adaptive", "display": "summarized" }),
                );
                body.insert("output_config".into(), json!({ "effort": effort }));
                ceiling = MESSAGES_THINKING;
            } else {
                // Thinking cannot be disabled here; omitting the display
                // keeps the reasoning empty and low effort keeps it short.
                body.insert("output_config".into(), json!({ "effort": "low" }));
            }
        }
    }
    body.insert("max_tokens".into(), json!(ceiling));
    if !system.is_empty() {
        body.insert("system".into(), Value::Array(system));
    }
    if !tools.is_empty() {
        body.insert("tools".into(), Value::Array(anthropic_tools(tools)?));
    }
    Ok(Value::Object(body))
}

/// One turn as the content blocks this dialect takes.
/// A turn that is not the person's may not carry parts. `parts_of` says so,
/// and both dialect writers ask it before they read a turn's content as a
/// string, so an array there fails the round rather than being read as an
/// empty answer.
fn append_block(
    turns: &mut Vec<Value>,
    message: &Value,
    role: Option<&str>,
) -> Result<(), &'static str> {
    let parts = parts_of(message, role)?;
    match role {
        Some("assistant") => {
            let mut blocks: Vec<Value> = Vec::new();
            if let Some(content) = text(message.get("content")) {
                blocks.push(json!({ "type": "text", "text": content }));
            }
            let empty = Vec::new();
            for call in message
                .get("tool_calls")
                .and_then(Value::as_array)
                .unwrap_or(&empty)
            {
                let function = call
                    .get("function")
                    .and_then(Value::as_object)
                    .ok_or(TRANSCRIPT)?;
                let (Some(id), Some(name), Some(arguments)) = (
                    text(call.get("id")),
                    text(function.get("name")),
                    function.get("arguments").and_then(Value::as_str),
                ) else {
                    return Err(TRANSCRIPT);
                };
                // The arguments are an object on this wire, not a string of
                // JSON, so one that does not parse is a turn this cannot send.
                let input: Value = serde_json::from_str(arguments).map_err(|_| TRANSCRIPT)?;
                if !input.is_object() {
                    return Err(TRANSCRIPT);
                }
                blocks.push(json!({
                    "type": "tool_use", "id": id, "name": name, "input": input,
                }));
            }
            if blocks.is_empty() {
                // A turn that carried only reasoning still holds its place in
                // the alternation, and an empty content array is refused.
                blocks.push(json!({ "type": "text", "text": "(no visible output)" }));
            }
            turns.push(json!({ "role": "assistant", "content": blocks }));
            Ok(())
        }
        Some("tool") => {
            let id = text(message.get("tool_call_id")).ok_or(TRANSCRIPT)?;
            let block = json!({
                "type": "tool_result",
                "tool_use_id": id,
                "content": text(message.get("content")).unwrap_or_default(),
            });
            // Every result of one assistant turn is answered in a single user
            // turn, so an open one is extended rather than followed.
            let open = turns.last().is_some_and(|last| {
                last.get("role").and_then(Value::as_str) == Some("user")
                    && last
                        .get("content")
                        .and_then(Value::as_array)
                        .and_then(|blocks| blocks.first())
                        .and_then(|first| first.get("type"))
                        .and_then(Value::as_str)
                        == Some("tool_result")
            });
            if open {
                let last = turns.last_mut().expect("checked above");
                last["content"]
                    .as_array_mut()
                    .expect("checked above")
                    .push(block);
            } else {
                turns.push(json!({ "role": "user", "content": [block] }));
            }
            Ok(())
        }
        Some("user") => {
            let blocks = match parts {
                Some(parts) => anthropic_parts(&parts),
                None => vec![json!({
                    "type": "text",
                    "text": text(message.get("content")).unwrap_or_default(),
                })],
            };
            turns.push(json!({ "role": "user", "content": blocks }));
            Ok(())
        }
        _ => Err(TRANSCRIPT),
    }
}

/// Whether the last assistant turn asked for a tool, which is what makes a
/// round a continuation.
fn last_assistant_uses_tools(messages: &[Value]) -> bool {
    messages
        .iter()
        .rev()
        .find(|message| message.get("role").and_then(Value::as_str) == Some("assistant"))
        .and_then(|message| message.get("content"))
        .and_then(Value::as_array)
        .is_some_and(|blocks| {
            blocks
                .iter()
                .any(|block| block.get("type").and_then(Value::as_str) == Some("tool_use"))
        })
}

/// The OpenAI tool shape into Anthropic's.
fn anthropic_tools(tools: &[Value]) -> Result<Vec<Value>, &'static str> {
    tools
        .iter()
        .map(|tool| {
            let function = tool.get("function").and_then(Value::as_object).ok_or(TOOLS)?;
            let name = text(function.get("name")).ok_or(TOOLS)?;
            let parameters = function.get("parameters").ok_or(TOOLS)?;
            if !parameters.is_object() {
                return Err(TOOLS);
            }
            let mut entry = Map::new();
            entry.insert("name".into(), json!(name));
            entry.insert("input_schema".into(), parameters.clone());
            if let Some(description) = text(function.get("description")) {
                entry.insert("description".into(), json!(description));
            }
            Ok(Value::Object(entry))
        })
        .collect()
}

/// OpenAI responses: Codex.
///
/// A system turn becomes top-level `instructions` and the turns become flat
/// input items, so a tool round is four items rather than three turns.
fn responses_body(
    model: &str,
    mode: &str,
    thinking: bool,
    streaming: bool,
    messages: &[Value],
    tools: &[Value],
) -> Result<Value, &'static str> {
    let mut instructions: Vec<String> = Vec::new();
    let mut input: Vec<Value> = Vec::new();
    for message in messages {
        let role = message.get("role").and_then(Value::as_str);
        if role == Some("system") {
            if let Some(text) = text(message.get("content")) {
                instructions.push(text);
            }
            continue;
        }
        append_input(&mut input, message, role)?;
    }
    let mut body = Map::new();
    body.insert("model".into(), json!(model));
    body.insert("stream".into(), json!(streaming));
    // A round is not kept on the provider's servers.
    body.insert("store".into(), json!(false));
    body.insert(
        "max_output_tokens".into(),
        json!(if thinking { RESPONSES_THINKING } else { RESPONSES_PLAIN }),
    );
    body.insert("input".into(), Value::Array(input));
    if !instructions.is_empty() {
        body.insert("instructions".into(), json!(instructions.join("\n\n")));
    }
    if !tools.is_empty() {
        body.insert("tools".into(), Value::Array(responses_tools(tools)?));
    }
    if thinking {
        // The effort is always high here; the summary is what carries the
        // mode the person asked for.
        body.insert(
            "reasoning".into(),
            json!({
                "effort": "high",
                "summary": if mode == "max" { "detailed" } else { "auto" },
            }),
        );
    }
    Ok(Value::Object(body))
}

/// One turn as the flat items this dialect takes.
fn append_input(
    input: &mut Vec<Value>,
    message: &Value,
    role: Option<&str>,
) -> Result<(), &'static str> {
    let parts = parts_of(message, role)?;
    match role {
        Some("assistant") => {
            if let Some(content) = text(message.get("content")) {
                input.push(json!({
                    "type": "message",
                    "role": "assistant",
                    "content": [{ "type": "output_text", "text": content }],
                }));
            }
            let empty = Vec::new();
            let calls = message
                .get("tool_calls")
                .and_then(Value::as_array)
                .unwrap_or(&empty);
            for call in calls {
                let function = call
                    .get("function")
                    .and_then(Value::as_object)
                    .ok_or(TRANSCRIPT)?;
                let (Some(id), Some(name), Some(arguments)) = (
                    text(call.get("id")),
                    text(function.get("name")),
                    // Empty arguments are a call with no parameters, which
                    // is a call; only a missing string is a broken turn.
                    function.get("arguments").and_then(Value::as_str).map(str::to_owned),
                ) else {
                    return Err(TRANSCRIPT);
                };
                input.push(json!({
                    "type": "function_call",
                    "call_id": id,
                    "name": name,
                    "arguments": arguments,
                }));
            }
            Ok(())
        }
        Some("tool") => {
            let id = text(message.get("tool_call_id")).ok_or(TRANSCRIPT)?;
            input.push(json!({
                "type": "function_call_output",
                "call_id": id,
                "output": text(message.get("content")).unwrap_or_default(),
            }));
            Ok(())
        }
        Some("user") => {
            let blocks = match parts {
                Some(parts) => responses_parts(&parts),
                None => vec![json!({
                    "type": "input_text",
                    "text": text(message.get("content")).unwrap_or_default(),
                })],
            };
            input.push(json!({ "type": "message", "role": "user", "content": blocks }));
            Ok(())
        }
        _ => Err(TRANSCRIPT),
    }
}

/// The OpenAI chat tool shape into the responses one.
///
/// `strict` is written out rather than left to the default: the registry
/// schemas keep optional parameters, and strict mode demands every property
/// be required.
fn responses_tools(tools: &[Value]) -> Result<Vec<Value>, &'static str> {
    tools
        .iter()
        .map(|tool| {
            let function = tool.get("function").and_then(Value::as_object).ok_or(TOOLS)?;
            let name = text(function.get("name")).ok_or(TOOLS)?;
            let parameters = function.get("parameters").ok_or(TOOLS)?;
            if !parameters.is_object() {
                return Err(TOOLS);
            }
            let mut entry = Map::new();
            entry.insert("type".into(), json!("function"));
            entry.insert("name".into(), json!(name));
            entry.insert("parameters".into(), parameters.clone());
            entry.insert("strict".into(), json!(false));
            if let Some(description) = text(function.get("description")) {
                entry.insert("description".into(), json!(description));
            }
            Ok(Value::Object(entry))
        })
        .collect()
}

/// One piece of what a person said: words, or a picture.
///
/// A message's `content` is a string when it is only words, which is nearly
/// always, and an array of these when it also carries a picture. The shape
/// here is the app's own, not any provider's: each dialect spells a picture
/// differently, and choosing one provider's spelling upstream would make the
/// other two parse a foreign shape. The host produces this; the three
/// functions below are the only places that know what a wire calls it.
enum Part {
    Words(String),
    Picture { mime: String, data: String },
}

/// The picture formats every provider in the catalog accepts. A format
/// outside this list is refused rather than sent: a provider that rejects the
/// body answers with an opaque HTTP failure, and the person is left with a
/// turn that failed for no stated reason.
const PICTURE_MIMES: [&str; 4] = ["image/png", "image/jpeg", "image/gif", "image/webp"];

/// The parts of a message, or `None` when its content is plain words.
///
/// Only a user turn may carry parts. An assistant turn's content is its
/// answer and a tool turn's is a result; an array there is a transcript this
/// code does not understand, and guessing at it would put something in front
/// of a model that nobody wrote.
fn parts_of(message: &Value, role: Option<&str>) -> Result<Option<Vec<Part>>, &'static str> {
    let Some(raw) = message.get("content").and_then(Value::as_array) else {
        return Ok(None);
    };
    if role != Some("user") {
        return Err(TRANSCRIPT);
    }
    let mut parts = Vec::with_capacity(raw.len());
    for part in raw {
        match part.get("type").and_then(Value::as_str) {
            Some("text") => {
                // Empty words are not a part. They would become an empty
                // block, which some providers refuse outright.
                let Some(words) = text(part.get("text")) else {
                    return Err(TRANSCRIPT);
                };
                parts.push(Part::Words(words));
            }
            Some("image") => {
                let (Some(mime), Some(data)) =
                    (text(part.get("mime_type")), text(part.get("data")))
                else {
                    return Err(TRANSCRIPT);
                };
                if !PICTURE_MIMES.contains(&mime.as_str()) {
                    return Err(CONTEXT_UNSUPPORTED);
                }
                parts.push(Part::Picture { mime, data });
            }
            // The shape iOS has shipped since before this file spelled
            // pictures at all: OpenAI's own, inlined as a data URL. It is
            // read back into the neutral form rather than refused, because
            // refusing it would break a path people are using today, and
            // rather than passed through, because only one of the three
            // dialects understands it. A host writing new code should send
            // `image`; this is the older spelling, not a second contract.
            Some("image_url") => {
                let Some(url) = part
                    .get("image_url")
                    .and_then(|value| value.get("url"))
                    .and_then(Value::as_str)
                else {
                    return Err(TRANSCRIPT);
                };
                let (mime, data) = data_url_parts(url)?;
                parts.push(Part::Picture { mime, data });
            }
            _ => return Err(TRANSCRIPT),
        }
    }
    if parts.is_empty() {
        return Err(TRANSCRIPT);
    }
    Ok(Some(parts))
}

/// `data:image/png;base64,...`, which is how two of the three dialects carry
/// a picture that has no URL of its own.
fn data_url(mime: &str, data: &str) -> String {
    format!("data:{mime};base64,{data}")
}

/// The format and the bytes back out of a data URL.
///
/// Strict on purpose: a remote URL is not a picture this app can vouch for,
/// and a format outside the catalog is refused here exactly as it is on the
/// neutral path, so the two spellings cannot disagree about what is allowed.
fn data_url_parts(url: &str) -> Result<(String, String), &'static str> {
    let Some(rest) = url.strip_prefix("data:") else {
        return Err(CONTEXT_UNSUPPORTED);
    };
    let Some((mime, data)) = rest.split_once(";base64,") else {
        return Err(CONTEXT_UNSUPPORTED);
    };
    if !PICTURE_MIMES.contains(&mime) {
        return Err(CONTEXT_UNSUPPORTED);
    }
    if data.is_empty() {
        return Err(TRANSCRIPT);
    }
    Ok((mime.to_owned(), data.to_owned()))
}

/// OpenAI chat completions.
fn chat_parts(parts: &[Part]) -> Value {
    json!(parts
        .iter()
        .map(|part| match part {
            Part::Words(words) => json!({ "type": "text", "text": words }),
            Part::Picture { mime, data } => json!({
                "type": "image_url",
                "image_url": { "url": data_url(mime, data) },
            }),
        })
        .collect::<Vec<Value>>())
}

/// Anthropic messages, which names the format rather than inlining a URL.
fn anthropic_parts(parts: &[Part]) -> Vec<Value> {
    parts
        .iter()
        .map(|part| match part {
            Part::Words(words) => json!({ "type": "text", "text": words }),
            Part::Picture { mime, data } => json!({
                "type": "image",
                "source": { "type": "base64", "media_type": mime, "data": data },
            }),
        })
        .collect()
}

/// OpenAI responses, whose input blocks are spelled apart from its output
/// ones and whose picture block takes the URL unwrapped.
fn responses_parts(parts: &[Part]) -> Vec<Value> {
    parts
        .iter()
        .map(|part| match part {
            Part::Words(words) => json!({ "type": "input_text", "text": words }),
            Part::Picture { mime, data } => json!({
                "type": "input_image",
                "image_url": data_url(mime, data),
            }),
        })
        .collect()
}

fn text(value: Option<&Value>) -> Option<String> {
    match value.and_then(Value::as_str) {
        Some(text) if !text.is_empty() => Some(text.to_owned()),
        _ => None,
    }
}

#[cfg(test)]
#[path = "completion_request_tests.rs"]
mod tests;
