//! The provider round service's pure half, ported from
//! `AgentProviderRoundServiceInternals.mm`: request and result shapes, the
//! controller CAS and checkpoint relations, the round locator and ledger
//! CAS, the native-to-provider message conversion, the public receipt, the
//! recovered round projection, the project-context bundle, the failure-code
//! mapping, the selector requests, and the tool descriptions the model is
//! shown. The host keeps the transport, credentials, the tool registry's
//! native descriptors, the root projection validator, and the two provider
//! digests — those use `NSJSONSerialization` with sorted keys, a different
//! byte protocol from this crate's canonical JSON, and are passed in as
//! host facts rather than recomputed here.

use crate::canonical::{canonical_json, sha256_hex};
use crate::execution_ledger::{as_str, get};
use crate::schema::{
    bounded_utf8, canonical_sha256, canonical_timestamp, canonical_uuid, exact_keys,
    exact_keys_with_optional, safe_integer, MAX_TRANSCRIPT_BYTES,
};
use crate::session_schema::Env;
use crate::store::StoreError;
use crate::strict_json::parse_arguments;
use serde_json::{json, Value};

const MAX_SAFE_INTEGER: u64 = 9_007_199_254_740_991;
/// `DSHCompletionV2MaxArgumentsBytes`.
const MAX_ARGUMENTS_BYTES: usize = 32_768;
/// The project-context budget one round may carry.
const MAX_CONTEXT_BYTES: u64 = 256 * 1024;

fn equal(left: Option<&Value>, right: Option<&Value>) -> bool {
    matches!((left, right), (Some(l), Some(r)) if l == r)
}

fn string_eq(value: Option<&Value>, expected: &str) -> bool {
    as_str(value) == Some(expected)
}

fn is_null(value: Option<&Value>) -> bool {
    matches!(value, Some(Value::Null))
}

fn present(value: Option<&Value>) -> Option<&Value> {
    value.filter(|v| !v.is_null())
}

fn array(value: Option<&Value>) -> &[Value] {
    match value {
        Some(Value::Array(items)) => items,
        _ => &[],
    }
}

fn or_null(value: Option<&Value>) -> Value {
    value.cloned().unwrap_or(Value::Null)
}

/// `DSHProviderSchema`: a safe non-zero integer equal to `schema`.
fn schema(value: Option<&Value>, expected: u64) -> bool {
    safe_integer(value, expected, false) == Some(expected)
}

fn nullable_digest(value: Option<&Value>) -> bool {
    is_null(value) || canonical_sha256(value)
}

/// `DSHProviderReference`: the transcript handle a round carries.
pub fn reference(value: Option<&Value>) -> bool {
    let Some(reference) = exact_keys(
        value,
        &[
            "schema_version",
            "transcript_ref",
            "generation",
            "transcript_sha256",
            "transcript_bytes",
        ],
    ) else {
        return false;
    };
    schema(reference.get("schema_version"), 1)
        && canonical_uuid(reference.get("transcript_ref"))
        && safe_integer(reference.get("generation"), MAX_SAFE_INTEGER, true).is_some()
        && canonical_sha256(reference.get("transcript_sha256"))
        && safe_integer(
            reference.get("transcript_bytes"),
            MAX_TRANSCRIPT_BYTES,
            true,
        )
        .is_some()
}

/// `DSHProviderOpaqueId`: 1..=128 bytes of `[A-Za-z0-9._:-]`.
pub fn opaque_id(value: Option<&Value>) -> bool {
    match bounded_utf8(value, 128, false) {
        Some(text) => text
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b':' | b'-')),
        None => false,
    }
}

/// `DSHProviderControllerCAS`, bound to the round's identities.
pub fn controller_cas(
    cas: Option<&Value>,
    conversation_id: Option<&Value>,
    task_id: Option<&Value>,
    attempt_id: Option<&Value>,
) -> bool {
    let Some(cas) = exact_keys(
        cas,
        &[
            "schema_version",
            "conversation_id",
            "task_id",
            "attempt_id",
            "expected_controller_generation",
            "expected_journal_revision",
            "expected_session_generation",
            "expected_session_sha256",
        ],
    ) else {
        return false;
    };
    schema(cas.get("schema_version"), 1)
        && canonical_uuid(cas.get("conversation_id"))
        && canonical_uuid(cas.get("task_id"))
        && canonical_uuid(cas.get("attempt_id"))
        && equal(cas.get("conversation_id"), conversation_id)
        && equal(cas.get("task_id"), task_id)
        && equal(cas.get("attempt_id"), attempt_id)
        && safe_integer(
            cas.get("expected_controller_generation"),
            MAX_SAFE_INTEGER,
            true,
        )
        .is_some()
        && safe_integer(cas.get("expected_journal_revision"), MAX_SAFE_INTEGER, true).is_some()
        && safe_integer(
            cas.get("expected_session_generation"),
            MAX_SAFE_INTEGER,
            true,
        )
        .is_some()
        && canonical_sha256(cas.get("expected_session_sha256"))
}

/// `DSHProviderCheckpoint`.
pub fn checkpoint(value: Option<&Value>) -> bool {
    let Some(checkpoint) = exact_keys(
        value,
        &[
            "schema_version",
            "journal_revision",
            "session_generation",
            "session_sha256",
        ],
    ) else {
        return false;
    };
    schema(checkpoint.get("schema_version"), 1)
        && safe_integer(checkpoint.get("journal_revision"), MAX_SAFE_INTEGER, true).is_some()
        && safe_integer(checkpoint.get("session_generation"), MAX_SAFE_INTEGER, true).is_some()
        && canonical_sha256(checkpoint.get("session_sha256"))
}

// MARK: - provider result

fn finish_reason_known(value: Option<&Value>) -> bool {
    matches!(
        as_str(value),
        Some("stop" | "tool_calls" | "length" | "content_filter")
    )
}

/// `DSHProviderResultShape`: the transport's result as the round accepts it.
/// A provider binding on the record is stripped through [`Env`] first.
pub fn result_shape(result: &Value, env: &Env) -> bool {
    if !result.is_object() {
        return false;
    }
    let Some((stripped, _)) = env.record_without_configuration(result) else {
        return false;
    };
    let result = stripped.as_ref();
    let keys = [
        "provider_request_id",
        "provider_response_id",
        "requested_model",
        "model",
        "thinking_mode",
        "text",
        "reasoning",
        "tool_calls",
        "finish_reason",
        "latency_ms",
        "visible_history_sha256",
        "model_input_sha256",
        "request_body_sha256",
    ];
    let r = |key: &str| get(result, key);
    if exact_keys_with_optional(Some(result), &keys, &["harness_id"]).is_none()
        || !opaque_id(r("provider_request_id"))
        || !opaque_id(r("provider_response_id"))
        || bounded_utf8(r("requested_model"), 128, false).is_none()
        || bounded_utf8(r("model"), 128, false).is_none()
        || bounded_utf8(r("thinking_mode"), 32, false).is_none()
        || bounded_utf8(r("text"), MAX_TRANSCRIPT_BYTES as usize, true).is_none()
        || bounded_utf8(r("reasoning"), MAX_TRANSCRIPT_BYTES as usize, true).is_none()
        || !r("tool_calls").is_some_and(Value::is_array)
        || array(r("tool_calls")).len() > 16
        || bounded_utf8(r("finish_reason"), 32, false).is_none()
        || safe_integer(r("latency_ms"), 24 * 60 * 60 * 1000, true).is_none()
        || !canonical_sha256(r("visible_history_sha256"))
        || !canonical_sha256(r("model_input_sha256"))
        || !canonical_sha256(r("request_body_sha256"))
        || !finish_reason_known(r("finish_reason"))
    {
        return false;
    }
    if r("harness_id").is_some() && as_str(r("harness_id")) != env.harness_for_model(r("model")) {
        return false;
    }
    let calls = array(r("tool_calls")).len();
    env.supported_model(r("requested_model"))
        && env.supported_model(r("model"))
        && equal(r("requested_model"), r("model"))
        && if string_eq(r("finish_reason"), "tool_calls") {
            calls > 0
        } else {
            calls == 0
        }
}

/// `DSHProviderResultMatchesRequest`.
pub fn result_matches_request(
    result: &Value,
    request: &Value,
    provider_request_id: Option<&Value>,
    env: &Env,
) -> bool {
    result_shape(result, env)
        && equal(get(result, "provider_request_id"), provider_request_id)
        && equal(get(result, "requested_model"), get(request, "model"))
        && equal(get(result, "model"), get(request, "model"))
        && equal(get(result, "thinking_mode"), get(request, "thinking_mode"))
}

// MARK: - request

/// `DSHProviderRoundRequestCopy`'s validation. The root projection is a host
/// fact (`root_ok`) because it resolves live workspace state.
pub fn round_request_valid(request: &Value, root_ok: bool, env: &Env) -> bool {
    let keys = [
        "schema_version",
        "operation_id",
        "controller_cas",
        "committed_checkpoint",
        "task_id",
        "conversation_id",
        "attempt_id",
        "round_id",
        "round_index",
        "launch_attempt",
        "expected_round_revision",
        "transport_schema_version",
        "model",
        "thinking_mode",
        "visible_history_sha256",
        "visible_message_count",
        "project_context_sha256",
        "transcript",
        "root",
        "registry_version",
        "toolset_sha256",
    ];
    let r = |key: &str| get(request, key);
    let cas = r("controller_cas");
    let checkpoint_value = r("committed_checkpoint");
    let c = |key: &str| cas.and_then(|c| get(c, key));
    let k = |key: &str| checkpoint_value.and_then(|c| get(c, key));
    let transport_3 = r("transport_schema_version") == Some(&json!(3));
    let transport_2 = r("transport_schema_version") == Some(&json!(2));
    exact_keys_with_optional(Some(request), &keys, &["harness_id"]).is_some()
        && (r("harness_id").is_none()
            || as_str(r("harness_id")) == env.harness_for_model(r("model")))
        && schema(r("schema_version"), 2)
        && canonical_uuid(r("operation_id"))
        && canonical_uuid(r("task_id"))
        && canonical_uuid(r("conversation_id"))
        && canonical_uuid(r("attempt_id"))
        && canonical_uuid(r("round_id"))
        && controller_cas(cas, r("conversation_id"), r("task_id"), r("attempt_id"))
        && checkpoint(checkpoint_value)
        && equal(c("expected_journal_revision"), k("journal_revision"))
        && equal(c("expected_session_generation"), k("session_generation"))
        && equal(c("expected_session_sha256"), k("session_sha256"))
        && safe_integer(r("round_index"), 7, true).is_some()
        && safe_integer(r("launch_attempt"), 8, false).is_some()
        && safe_integer(r("expected_round_revision"), MAX_SAFE_INTEGER, true).is_some()
        && (transport_2 || transport_3)
        && bounded_utf8(r("model"), 128, false).is_some()
        && bounded_utf8(r("thinking_mode"), 32, false).is_some()
        && canonical_sha256(r("visible_history_sha256"))
        && safe_integer(r("visible_message_count"), 96, true).is_some()
        && nullable_digest(r("project_context_sha256"))
        && !(transport_3 && is_null(r("project_context_sha256")))
        && (!transport_2 || is_null(r("project_context_sha256")))
        && reference(r("transcript"))
        && r("root").is_some_and(Value::is_object)
        && root_ok
        && crate::runtime_tools::registry_version(r("registry_version"))
        && canonical_sha256(r("toolset_sha256"))
}

/// `DSHProviderRoundLocator`.
pub fn round_locator(request: &Value) -> Value {
    json!({
        "schema_version": 1,
        "task_id": get(request, "task_id"),
        "attempt_id": get(request, "attempt_id"),
        "round_id": get(request, "round_id"),
        "round_index": get(request, "round_index"),
    })
}

/// `DSHProviderLocatorKey`: the canonical JSON text of a locator, used as an
/// in-memory key.
pub fn locator_key(locator: &Value) -> Option<String> {
    String::from_utf8(canonical_json(locator).ok()?).ok()
}

/// `DSHProviderRoundCASForRow`.
pub fn round_cas_for_row(row: &Value) -> Value {
    let owner = present(get(row, "owner"));
    json!({
        "schema_version": 2,
        "locator": get(row, "locator"),
        "expected_row_revision": get(row, "row_revision"),
        "expected_state": get(row, "state"),
        "expected_owner_generation": or_null(owner.and_then(|o| get(o, "owner_generation"))),
        "expected_launch_id": or_null(owner.and_then(|o| get(o, "launch_id"))),
        "expected_native_task_id": or_null(owner.and_then(|o| get(o, "native_task_id"))),
        "expected_transcript_generation": get(row, "transcript_before").and_then(|t| get(t, "generation")),
        "expected_transcript_sha256": get(row, "transcript_before").and_then(|t| get(t, "transcript_sha256")),
        "expected_root_fingerprint_sha256": get(row, "root_fingerprint_sha256"),
        "expected_binding_revision": get(row, "binding_revision"),
    })
}

/// `DSHProviderNativeToCompletionMessage`: the assistant message a round
/// appends, with each call's arguments re-parsed as a strict JSON object.
pub fn native_to_completion_message(message: &Value) -> Option<Value> {
    if !message.is_object()
        || !string_eq(get(message, "role"), "assistant")
        || !get(message, "content").is_some_and(Value::is_string)
        || !get(message, "reasoning_content").is_some_and(Value::is_string)
        || !get(message, "tool_calls").is_some_and(Value::is_array)
    {
        return None;
    }
    let mut calls = Vec::new();
    for call in array(get(message, "tool_calls")) {
        let arguments = get(call, "arguments");
        if bounded_utf8(get(call, "call_id"), 128, false).is_none()
            || bounded_utf8(get(call, "name"), 64, false).is_none()
            || bounded_utf8(arguments, MAX_ARGUMENTS_BYTES, false).is_none()
            || as_str(arguments).and_then(parse_arguments).is_none()
        {
            return None;
        }
        calls.push(json!({
            "schema_version": 1,
            "call_id": get(call, "call_id"),
            "name": get(call, "name"),
            "arguments_json": arguments,
        }));
    }
    Some(json!({
        "schema_version": 1,
        "role": "assistant",
        "round_index": get(message, "round_index"),
        "content": get(message, "content"),
        "reasoning_content": get(message, "reasoning_content"),
        "tool_calls": calls,
    }))
}

/// `DSHProviderPublicReceipt`: the redacted receipt a completed round
/// publishes.
pub fn public_receipt(
    provider: &Value,
    request: &Value,
    provider_request_id: Option<&Value>,
    context_receipt: Option<&Value>,
) -> Value {
    let harness = as_str(get(provider, "harness_id"))
        .or_else(|| as_str(get(request, "harness_id")))
        .unwrap_or("dsh");
    let mut receipt = json!({
        "schema_version": 2,
        "transport_schema_version": get(request, "transport_schema_version"),
        "turn_id": get(request, "task_id"),
        "task_id": get(request, "task_id"),
        "attempt_id": get(request, "attempt_id"),
        "round_id": get(request, "round_id"),
        "round_index": get(request, "round_index"),
        "provider_request_id": provider_request_id,
        "provider_response_id": get(provider, "provider_response_id"),
        "harness_id": harness,
        "requested_model": get(request, "model"),
        "model": get(request, "model"),
        "thinking_mode": get(request, "thinking_mode"),
        "finish_reason": get(provider, "finish_reason"),
        "latency_ms": get(provider, "latency_ms"),
        "visible_history_sha256": get(provider, "visible_history_sha256"),
        "model_input_sha256": get(provider, "model_input_sha256"),
        "request_body_sha256": get(provider, "request_body_sha256"),
        "project_context_receipt": or_null(context_receipt),
    });
    if let (Value::Object(map), Some(binding)) =
        (&mut receipt, get(provider, "provider_configuration"))
    {
        map.insert("provider_configuration".into(), binding.clone());
    }
    receipt
}

/// `DSHProviderRecoveredRoundProjection`: what a completed row plus its
/// stored assistant message project as. `Err(Conflict)` when the row, the
/// request and the transcript do not agree.
pub fn recovered_round_projection(
    row: &Value,
    request: &Value,
    native_messages: &[Value],
) -> Result<Value, StoreError> {
    let locator = get(row, "locator");
    let l = |key: &str| locator.and_then(|l| get(l, key));
    if !row.is_object()
        || !request.is_object()
        || !string_eq(get(row, "state"), "completed")
        || !equal(l("task_id"), get(request, "task_id"))
        || !equal(l("attempt_id"), get(request, "attempt_id"))
        || !equal(l("round_id"), get(request, "round_id"))
        || !equal(l("round_index"), get(request, "round_index"))
        || !get(row, "transcript_after").is_some_and(Value::is_object)
        || !get(row, "completion_receipt").is_some_and(Value::is_object)
    {
        return Err(StoreError::Conflict);
    }
    let assistant = native_messages.iter().rfind(|message| {
        message.is_object()
            && string_eq(get(message, "role"), "assistant")
            && equal(get(message, "round_index"), get(request, "round_index"))
    });
    let Some(assistant) = assistant else {
        return Err(StoreError::Conflict);
    };
    let text = bounded_utf8(
        get(assistant, "content"),
        MAX_TRANSCRIPT_BYTES as usize,
        true,
    );
    let reasoning = bounded_utf8(
        get(assistant, "reasoning_content"),
        MAX_TRANSCRIPT_BYTES as usize,
        true,
    );
    let (Some(text), Some(reasoning)) = (text, reasoning) else {
        return Err(StoreError::Conflict);
    };
    if !get(assistant, "tool_calls").is_some_and(Value::is_array) {
        return Err(StoreError::Conflict);
    }
    let native_receipt = get(row, "completion_receipt").expect("checked");
    // Selector/recovery requests intentionally carry only the round locator,
    // root, and transcript handle. Bind optional receipt fields to the
    // persisted native receipt when those selectors omit them; a full
    // complete-agent-round request still supplies and is checked against the
    // same values below.
    let mut receipt_request = request.as_object().cloned().unwrap_or_default();
    for key in ["transport_schema_version", "model", "thinking_mode"] {
        if !receipt_request.contains_key(key) {
            if let Some(value) = get(native_receipt, key) {
                receipt_request.insert(key.to_string(), value.clone());
            }
        }
    }
    let receipt_request = Value::Object(receipt_request);
    let expected_transport = get(&receipt_request, "transport_schema_version");
    let provider_request_id = get(native_receipt, "provider_request_id");
    if !opaque_id(provider_request_id)
        || !equal(
            get(native_receipt, "transport_schema_version"),
            expected_transport,
        )
        || !equal(
            get(native_receipt, "requested_model"),
            get(&receipt_request, "model"),
        )
        || !equal(get(native_receipt, "model"), get(&receipt_request, "model"))
        || !equal(
            get(native_receipt, "thinking_mode"),
            get(&receipt_request, "thinking_mode"),
        )
    {
        return Err(StoreError::Conflict);
    }
    let context_receipt = present(get(native_receipt, "project_context_receipt"));
    let transport_3 = expected_transport == Some(&json!(3));
    let transport_2 = expected_transport == Some(&json!(2));
    if (transport_3 && context_receipt.is_none()) || (transport_2 && context_receipt.is_some()) {
        return Err(StoreError::Conflict);
    }
    let receipt = public_receipt(
        native_receipt,
        &receipt_request,
        provider_request_id,
        context_receipt,
    );
    let finish_reason = as_str(get(native_receipt, "finish_reason")).unwrap_or_default();
    if !matches!(
        finish_reason,
        "stop" | "tool_calls" | "length" | "content_filter"
    ) {
        return Err(StoreError::Conflict);
    }
    let calls = array(get(assistant, "tool_calls")).len();
    let mut projection = json!({
        "schema_version": 2,
        "task_id": get(request, "task_id"),
        "attempt_id": get(request, "attempt_id"),
        "round_id": get(request, "round_id"),
        "round_index": get(request, "round_index"),
        "launch_attempt": get(row, "launch_attempt"),
        "result_round_revision": get(row, "row_revision"),
        "transcript": get(row, "transcript_after"),
        "completion_receipt": receipt,
        "text": text,
        "reasoning": reasoning,
        "assistant_text_sha256": sha256_hex(text.as_bytes()),
        "reasoning_text_sha256": sha256_hex(reasoning.as_bytes()),
    });
    let Value::Object(map) = &mut projection else {
        unreachable!()
    };
    match finish_reason {
        "stop" => {
            if calls != 0 {
                return Err(StoreError::Conflict);
            }
            map.insert("kind".into(), json!("final"));
            map.insert("finish_reason".into(), json!("stop"));
        }
        "tool_calls" => {
            let row_calls = array(get(row, "calls"));
            if row_calls.is_empty()
                || !get(row, "batch_class").is_some_and(Value::is_string)
                || calls != row_calls.len()
            {
                return Err(StoreError::Conflict);
            }
            map.insert("kind".into(), json!("tool_batch"));
            map.insert("finish_reason".into(), json!("tool_calls"));
            map.insert("calls".into(), or_null(get(row, "calls")));
            map.insert("batch_class".into(), or_null(get(row, "batch_class")));
            map.insert(
                "executable_call_count".into(),
                or_null(get(row, "executable_call_count")),
            );
            map.insert(
                "denied_call_count".into(),
                or_null(get(row, "denied_call_count")),
            );
        }
        _ => {
            if calls != 0 {
                return Err(StoreError::Conflict);
            }
            map.insert("kind".into(), json!("blocked"));
            map.insert("finish_reason".into(), json!(finish_reason));
            map.insert(
                "failure_code".into(),
                json!(if finish_reason == "length" {
                    "E_COMPLETION_LENGTH"
                } else {
                    "E_COMPLETION_CONTENT_FILTER"
                }),
            );
        }
    }
    Ok(projection)
}

// MARK: - project context

/// `DSHProviderContextReceipt`.
pub fn context_receipt(value: Option<&Value>) -> bool {
    let Some(receipt) = exact_keys(
        value,
        &[
            "schema_version",
            "snapshot_id",
            "snapshot_sha256",
            "source_fingerprint",
            "context_bytes",
            "verified_at",
        ],
    ) else {
        return false;
    };
    schema(receipt.get("schema_version"), 1)
        && canonical_uuid(receipt.get("snapshot_id"))
        && canonical_sha256(receipt.get("snapshot_sha256"))
        && canonical_sha256(receipt.get("source_fingerprint"))
        && safe_integer(receipt.get("context_bytes"), 32 * 1024 * 1024, true).is_some()
        && canonical_timestamp(receipt.get("verified_at"))
}

/// `DSHProviderContextBundle`: the schema-3 context the host's callback
/// produced. Returns the receipt and the system messages to prepend.
pub fn context_bundle(
    bundle: Option<&Value>,
    expected_digest: Option<&Value>,
) -> Result<(Value, Vec<Value>), StoreError> {
    let messages = bundle.map(|b| array(get(b, "messages"))).unwrap_or(&[]);
    if exact_keys(bundle, &["project_context_sha256", "receipt", "messages"]).is_none()
        || !canonical_sha256(bundle.and_then(|b| get(b, "project_context_sha256")))
        || !context_receipt(bundle.and_then(|b| get(b, "receipt")))
        || !bundle
            .and_then(|b| get(b, "messages"))
            .is_some_and(Value::is_array)
        || messages.is_empty()
        || messages.len() > 32
    {
        return Err(StoreError::InvalidArgument);
    }
    let bundle = bundle.expect("checked");
    if !equal(get(bundle, "project_context_sha256"), expected_digest) {
        return Err(StoreError::Conflict);
    }
    let mut kept = Vec::with_capacity(messages.len());
    let mut context_bytes: u64 = 0;
    for message in messages {
        let content = bounded_utf8(get(message, "content"), MAX_CONTEXT_BYTES as usize, false);
        if exact_keys(Some(message), &["role", "content", "attachments"]).is_none()
            || !string_eq(get(message, "role"), "system")
            || content.is_none()
            || !get(message, "attachments").is_some_and(Value::is_array)
            || !array(get(message, "attachments")).is_empty()
        {
            return Err(StoreError::InvalidArgument);
        }
        let message_bytes = content.expect("checked").len() as u64;
        if message_bytes > MAX_CONTEXT_BYTES - context_bytes {
            return Err(StoreError::Capacity);
        }
        context_bytes += message_bytes;
        kept.push(message.clone());
    }
    if get(bundle, "receipt")
        .and_then(|r| get(r, "context_bytes"))
        .and_then(Value::as_u64)
        != Some(context_bytes)
    {
        return Err(StoreError::Conflict);
    }
    Ok((get(bundle, "receipt").cloned().unwrap_or(Value::Null), kept))
}

// MARK: - results

/// `DSHProviderConflictResult`.
pub fn conflict_result(
    operation_id: Option<&Value>,
    failure_code: &str,
    request: &Value,
    actual_round_revision: Option<&Value>,
    actual_round_status: Option<&str>,
    actual_transcript: Option<&Value>,
) -> Value {
    json!({
        "schema_version": 2,
        "status": "conflict",
        "operation_id": operation_id,
        "failure_code": failure_code,
        "expected_round_revision": get(request, "expected_round_revision"),
        "actual_round_revision": actual_round_revision.cloned().unwrap_or(json!(0)),
        "actual_round_status": actual_round_status.unwrap_or("in_flight"),
        "actual_transcript": actual_transcript.cloned().unwrap_or_else(|| or_null(get(request, "transcript"))),
    })
}

/// `DSHProviderUnknownResult`.
pub fn unknown_result(request: &Value, status: &str, revision: u64, failure_code: &str) -> Value {
    json!({
        "schema_version": 2,
        "status": status,
        "operation_id": get(request, "operation_id"),
        "task_id": get(request, "task_id"),
        "attempt_id": get(request, "attempt_id"),
        "round_id": get(request, "round_id"),
        "round_index": get(request, "round_index"),
        "launch_attempt": get(request, "launch_attempt"),
        "result_round_revision": revision,
        "transcript": get(request, "transcript"),
        "failure_code": failure_code,
    })
}

fn row_transcript(row: &Value) -> Value {
    match present(get(row, "transcript_after")) {
        Some(after) => after.clone(),
        None => or_null(get(row, "transcript_before")),
    }
}

/// `DSHProviderRoundResultForRow`.
pub fn round_result_for_row(
    request: &Value,
    row: &Value,
    status: &str,
    failure_code: &str,
) -> Value {
    let revision = get(row, "row_revision")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let mut result = unknown_result(request, status, revision, failure_code);
    if let Value::Object(map) = &mut result {
        map.insert("transcript".into(), row_transcript(row));
    }
    result
}

/// `DSHProviderQueryResultForRow`.
pub fn query_result_for_row(
    request: &Value,
    row: &Value,
    status: &str,
    failure_code: Option<&str>,
) -> Value {
    let mut result = json!({
        "schema_version": 2,
        "status": status,
        "task_id": get(request, "task_id"),
        "attempt_id": get(request, "attempt_id"),
        "round_id": get(request, "round_id"),
        "round_index": get(request, "round_index"),
        "result_round_revision": get(row, "row_revision").cloned().unwrap_or(json!(0)),
        "transcript": row_transcript(row),
    });
    if let (Value::Object(map), Some(code)) = (&mut result, failure_code) {
        map.insert("failure_code".into(), json!(code));
    }
    result
}

/// `DSHProviderSelectorConflict`.
pub fn selector_conflict(request: &Value, row: &Value, failure_code: &str) -> Value {
    json!({
        "schema_version": 2,
        "status": "conflict",
        "failure_code": failure_code,
        "expected_round_revision": get(request, "expected_round_revision"),
        "actual_round_revision": get(row, "row_revision").cloned().unwrap_or(json!(0)),
        "actual_round_status": get(row, "state").cloned().unwrap_or(json!("unknown")),
        "actual_transcript": row_transcript(row),
    })
}

/// `DSHProviderSelectorRequest`: the locator-only request a query, recovery
/// or cancellation carries. The root projection is a host fact.
pub fn selector_request_valid(
    request: &Value,
    cancellation: bool,
    allow_zero_revision: bool,
    root_ok: bool,
) -> bool {
    let mut keys = vec![
        "schema_version",
        "task_id",
        "attempt_id",
        "round_id",
        "round_index",
        "expected_round_revision",
        "transcript",
        "root",
    ];
    if cancellation {
        keys.push("cancel_token");
    }
    let r = |key: &str| get(request, key);
    exact_keys(Some(request), &keys).is_some()
        && schema(r("schema_version"), 2)
        && canonical_uuid(r("task_id"))
        && canonical_uuid(r("attempt_id"))
        && canonical_uuid(r("round_id"))
        && safe_integer(r("round_index"), 7, true).is_some()
        && safe_integer(
            r("expected_round_revision"),
            MAX_SAFE_INTEGER,
            allow_zero_revision,
        )
        .is_some()
        && reference(r("transcript"))
        && r("root").is_some_and(Value::is_object)
        && root_ok
        && (!cancellation || canonical_uuid(r("cancel_token")))
}

/// `DSHProviderSelectorMatchesRow`.
pub fn selector_matches_row(request: &Value, row: &Value) -> bool {
    let root = get(request, "root");
    equal(
        get(row, "row_revision"),
        get(request, "expected_round_revision"),
    ) && equal(
        get(row, "root_fingerprint_sha256"),
        root.and_then(|r| get(r, "root_fingerprint_sha256")),
    ) && equal(
        get(row, "binding_revision"),
        root.and_then(|r| get(r, "workspace_binding_revision")),
    ) && equal(get(row, "transcript_before"), get(request, "transcript"))
}

/// `DSHProviderFailureCode`: the transport's error code as the round's.
pub fn failure_code(provider_error_code: Option<&str>, digest_mismatch: bool) -> &'static str {
    if digest_mismatch {
        return "E_AGENT_TRANSCRIPT";
    }
    match provider_error_code.unwrap_or_default() {
        "E_COMPLETION_LENGTH" => "E_COMPLETION_LENGTH",
        "E_AGENT_CANCELLED" => "E_AGENT_CANCELLED",
        "E_COMPLETION_REDIRECT" => "E_AGENT_CONFLICT",
        "E_COMPLETION_HTTP_STATUS" | "E_COMPLETION_HTTP_429" => "E_AGENT_TOOL_FAILED",
        "E_COMPLETION_RESPONSE_MODEL"
        | "E_COMPLETION_MODEL_MISMATCH"
        | "E_COMPLETION_PROVIDER_RESPONSE_ID"
        | "E_COMPLETION_RESPONSE_JSON"
        | "E_COMPLETION_EMPTY_RESPONSE"
        | "E_COMPLETION_TOOL_CALL_INVALID"
        | "E_COMPLETION_FINISH_RELATION" => "E_AGENT_TRANSCRIPT",
        "E_COMPLETION_CREDENTIAL_CHANGED" => "E_AGENT_PERSISTENCE",
        // Refusals the transport raises while *building* the request: an
        // attachment it cannot carry, a dialect that cannot express a round
        // transcript, a body past a limit, a model or a thinking mode it does
        // not know. None of them depend on the provider, so none of them are
        // ambiguous -- the request never left the device -- and none of them
        // will succeed unchanged. Saying `E_AGENT_ROUND_AMBIGUOUS` here told
        // a person their turn might have happened and offered them a retry
        // that could only fail again.
        "E_COMPLETION_CONTEXT_UNSUPPORTED"
        | "E_COMPLETION_CONTEXT_INVALID"
        | "E_COMPLETION_BODY_TOO_LARGE"
        | "E_COMPLETION_HISTORY"
        | "E_COMPLETION_TOOLS"
        | "E_COMPLETION_THINKING"
        | "E_COMPLETION_MODEL" => "E_AGENT_CAPABILITY",
        _ => "E_AGENT_ROUND_AMBIGUOUS",
    }
}

/// `DSHProviderOperationSafeResult`.
pub fn operation_safe_result(result: &Value) -> Value {
    json!({ "schema_version": 2, "result_kind": "complete_agent_round_v2", "result": result })
}

// MARK: - model input

/// `DSHProviderToolDescription`: what the model is told about each tool.
/// Every path argument is relative to the workspace root exactly as
/// list_dir/read_file use it; the round batch rejects absolute or
/// normalised paths, so the description has to say so instead of leaving
/// the model to guess a mount point. Every entry must fit
/// `DSHCompletionV2MaxToolDescriptionLength` (1024): one oversized enabled
/// tool prevents the entire Agent request dispatch.
pub fn tool_description(name: &str) -> Option<&'static str> {
    Some(match name {
        "list_dir" => "List a directory of the workspace. path is relative to the workspace root (\"\" or \".\" for the root itself, e.g. \"src\"); never an absolute path.",
        "read_file" => "Read a UTF-8 file of the workspace. path is relative to the workspace root exactly as list_dir shows it (e.g. \"index.html\", \"src/app.js\"); never an absolute path. The result carries the file's revision and sha256.",
        "write_file" => "Write literal UTF-8 content, using real line breaks instead of escaped backslash-n text. path is relative to the workspace root. To create a NEW file, omit expected_revision or pass JSON null; this asserts the file does not exist. Missing parent directories are created only after approval. To update an EXISTING file, first read_file and pass its exact revision string. Never pass the string null.",
        "git_status" => "Report the workspace's git status: branch, staged and unstaged changes.",
        "git_commit" => "Commit the workspace's current changes with the given message.",
        "git_push" => "Push the workspace's committed changes to its remote.",
        "start_guest_cgi" => "Start a local HTTP preview from self-contained HTML (inline CSS/JS, at most 32 KiB) and a BusyBox /bin/sh backend (at most 8 KiB). This legacy tool runs only BusyBox shell CGI. Use start_runtime_service for actual Node, Bun, Python, Java, Go or Rust HTTP applications. GET / serves HTML; POST /api runs backend.sh with the request-body file as $1 and mutable data file as $2, returning stdout as JSON. For static previews, backend.sh can print {}. Use workspace-relative paths exactly as read_file does, e.g. index.html and backend.sh, never /workspace prefixes. Each sha256 must come from read_file. Without seed data, pass null for both initial_data_path and initial_data_sha256. Return the URL only after success. The service is device-local, temporary, and may stop in the background.",
        "stop_guest_cgi" => "Stop the local demo service identified by service_id (the id start_guest_cgi returned).",
        "list_runtime_environments" => "List installed language environments and bundled packages available for installation. Call this before running code or starting a language application. If the requested environment is missing and available, install it with install_runtime_environment, then run/start it. Installed custom imported environments may also run.",
        "install_runtime_environment" => "Install a bundled language environment by environment_id from list_runtime_environments. Use this when execution is requested and the matching available environment is missing. Only catalog IDs are accepted; never supply a download URL. Installation is idempotent and needs conversation approval.",
        "run_program" => "Run a program to completion in an installed Python, Java, Go, Rust, Bun or Node environment. First list environments and install the needed catalog environment if missing. Write all source files before running. entry_path is workspace-relative; args is an array of literal strings, never shell text. Each run uses a temporary workspace copy: generated files and dependency installations are discarded afterwards, so needed dependency setup must happen within the same entry. Returns actual stdout, stderr and exit status; failures preserve compiler/runtime diagnostics.",
        "start_runtime_service" => "Start the actual program HTTP server in an installed language environment. First list environments, install a missing available environment, and write all source files. entry_path is workspace-relative; args is an array of literal arguments. The program must bind the requested port (1024..65535); PORT and HOST=127.0.0.1 are provided. Include any dependency setup in this entry because the workspace copy is temporary. Serve bounded HTTP/1.1 responses (at most 1 MiB within 30 seconds), not WebSockets or indefinite streams. Return only the actual loopback URL from successful feedback. The service is device-local and stops in the background.",
        "stop_runtime_service" => "Stop the runtime HTTP service identified by the service_id returned by start_runtime_service. Only a service owned by this conversation and workspace root can be stopped.",
        _ => return None,
    })
}

/// The provider-shaped transcript of a round, before the transport's own
/// schema validation. `Err(Corrupt)` for a message that is neither an
/// assistant nor a tool message.
pub fn transcript_for_body(native_messages: &[Value]) -> Result<Vec<Value>, StoreError> {
    let mut provider = Vec::with_capacity(native_messages.len());
    for message in native_messages {
        match as_str(get(message, "role")) {
            Some("assistant") => {
                let calls: Vec<Value> = array(get(message, "tool_calls"))
                    .iter()
                    .map(|call| {
                        json!({
                            "id": get(call, "call_id"),
                            "type": "function",
                            "function": { "name": get(call, "name"), "arguments": get(call, "arguments_json") },
                        })
                    })
                    .collect();
                provider.push(json!({
                    "role": "assistant",
                    "content": get(message, "content"),
                    "reasoning_content": get(message, "reasoning_content"),
                    "tool_calls": calls,
                }));
            }
            Some("tool") => provider.push(json!({
                "role": "tool",
                "tool_call_id": get(message, "call_id"),
                "content": get(message, "content"),
            })),
            _ => return Err(StoreError::Corrupt),
        }
    }
    Ok(provider)
}

// MARK: - JSON envelope

// MARK: - the service's own answers

/// `commitStartedOperationForRequest:`: which reference a round operation's
/// own result points at, and the result itself. A conflict never carries a
/// revision; a row that exists names its own.
pub fn started_operation_commit(
    request: &Value,
    request_sha256: &str,
    row: Option<&Value>,
    status: &str,
    failure_code: Option<&str>,
) -> Value {
    let row = row.filter(|row| row.is_object());
    let (result, result_ref, revision) = if status == "conflict" {
        let actual_transcript = match row {
            Some(row) => match row.get("transcript_after") {
                Some(after) if !after.is_null() => after.clone(),
                _ => row.get("transcript_before").cloned().unwrap_or(Value::Null),
            },
            None => request.get("transcript").cloned().unwrap_or(Value::Null),
        };
        let revision = match row {
            Some(row) => row.get("row_revision").cloned().unwrap_or(json!(0)),
            None => request
                .get("expected_round_revision")
                .cloned()
                .unwrap_or(Value::Null),
        };
        let state = match row.and_then(|row| row.get("state")).and_then(Value::as_str) {
            Some(state) => state,
            None if row.is_some() => "unknown",
            None => "in_flight",
        };
        let result = conflict_result(
            request.get("operation_id"),
            failure_code.unwrap_or("E_AGENT_CONFLICT"),
            request,
            Some(&revision),
            Some(state),
            Some(&actual_transcript),
        );
        (
            result,
            json!({ "schema_version": 2, "kind": "none" }),
            Value::Null,
        )
    } else if let Some(row) = row {
        let revision = row.get("row_revision").cloned().unwrap_or(json!(0));
        let result = round_result_for_row(request, row, status, failure_code.unwrap_or_default());
        let result_ref = json!({
            "schema_version": 2, "kind": "round",
            "task_id": request.get("task_id"),
            "attempt_id": request.get("attempt_id"),
            "round_id": request.get("round_id"),
            "round_index": request.get("round_index"),
            "round_revision": revision,
        });
        (result, result_ref, revision)
    } else {
        let result = unknown_result(
            request,
            status,
            request
                .get("expected_round_revision")
                .and_then(Value::as_u64)
                .unwrap_or(0),
            failure_code.unwrap_or_default(),
        );
        (
            result,
            json!({ "schema_version": 2, "kind": "none" }),
            Value::Null,
        )
    };
    json!({
        "operation_id": request.get("operation_id"),
        "request_sha256": request_sha256,
        "task_id": request.get("task_id"),
        "attempt_id": request.get("attempt_id"),
        "terminal_state": status,
        "result_status": status,
        "result_ref": result_ref,
        "result_revision": revision,
        "safe_result": operation_safe_result(&result),
    })
}

/// `publicResultForCompletedRow:`: the outcome a completed round hands the
/// controller, shaped by what the round turned out to be.
pub fn public_result_for_completed_row(request: &Value, row: &Value, round: &Value) -> Value {
    let receipt = round.get("completion_receipt");
    let transcript = round.get("transcript");
    let outcome = match round.get("kind").and_then(Value::as_str) {
        Some("final") => json!({
            "schema_version": 3,
            "kind": "final",
            "finish_reason": "stop",
            "completion_receipt": receipt,
            "transcript": transcript,
            "text": round.get("text"),
            "reasoning": round.get("reasoning"),
        }),
        Some("tool_batch") => json!({
            "schema_version": 3,
            "kind": "tool_batch",
            "finish_reason": "tool_calls",
            "completion_receipt": receipt,
            "transcript": transcript,
            "calls": round.get("calls"),
            "batch_class": round.get("batch_class"),
            "executable_call_count": round.get("executable_call_count"),
            "denied_call_count": round.get("denied_call_count"),
            "reasoning": round.get("reasoning"),
        }),
        _ => json!({
            "schema_version": 3,
            "kind": "blocked",
            "finish_reason": round.get("finish_reason"),
            "completion_receipt": receipt,
            "transcript": transcript,
            "failure_code": round.get("failure_code"),
        }),
    };
    json!({
        "schema_version": 2,
        "status": "completed",
        "operation_id": request.get("operation_id"),
        "task_id": request.get("task_id"),
        "attempt_id": request.get("attempt_id"),
        "round_id": request.get("round_id"),
        "round_index": request.get("round_index"),
        "launch_attempt": row.get("launch_attempt"),
        "result_round_revision": row.get("row_revision"),
        "transcript": row.get("transcript_after"),
        "outcome": outcome,
    })
}

/// The failure code a query reports for a row it found, by the row's state.
pub fn query_failure_code(state: &str) -> Option<&'static str> {
    match state {
        "ambiguous" => Some("E_AGENT_ROUND_AMBIGUOUS"),
        "unknown" => Some("E_AGENT_PERSISTENCE"),
        _ => None,
    }
}

/// Whether a round whose writer has provably released it is in a state
/// recovery can report directly, and the failure code that goes with it.
pub fn recovered_ownerless_state(state: &str) -> Option<Option<&'static str>> {
    match state {
        "completed" => Some(None),
        "cancelled" => Some(Some("E_AGENT_CANCELLED")),
        "ambiguous" => Some(Some("E_AGENT_ROUND_AMBIGUOUS")),
        "unknown" | "failed_retryable" => Some(Some("E_AGENT_PERSISTENCE")),
        _ => None,
    }
}

/// The failure code recovery reports after reconciling a dead writer's round:
/// a retryable row is a persistence failure, anything else is ambiguous.
pub fn reconciled_failure_code(state: &str) -> &'static str {
    if state == "failed_retryable" {
        "E_AGENT_PERSISTENCE"
    } else {
        "E_AGENT_ROUND_AMBIGUOUS"
    }
}

/// The cause a row recorded, when it is worth more than the generic answer
/// its state alone would give.
///
/// Three rules, and each one is load-bearing:
/// - an **ambiguous** round answers with its ambiguity whatever the row
///   says, because no recorded cause can establish that a dispatched
///   request was not acted on;
/// - a recorded `E_AGENT_PERSISTENCE` is the fallback itself, so it adds
///   nothing and is ignored;
/// - anything outside the closed failure-code union is not read at all.
fn recorded_cause<'a>(envelope: &'a Value, state: &str) -> Option<&'a str> {
    if state == "ambiguous" {
        return None;
    }
    let value = get(envelope, "recorded");
    if !crate::schema::failure_code(value) {
        return None;
    }
    as_str(value).filter(|code| {
        *code != "E_AGENT_PERSISTENCE" && *code != "E_AGENT_ROUND_AMBIGUOUS"
    })
}

/// The failure code a cancellation reports for the row it left behind.
pub fn cancelled_failure_code(state: &str) -> Option<&'static str> {
    if state == "cancelled" {
        Some("E_AGENT_CANCELLED")
    } else {
        None
    }
}

/// `{"op","request",...}` in; `{"ok":true,...}` or `{"ok":false,"error":<code>}` out.
pub fn reduce_json(input: &str) -> String {
    let value = match reduce_json_inner(input) {
        Ok(output) => {
            let mut object = output.as_object().cloned().unwrap_or_default();
            object.insert("ok".to_string(), Value::Bool(true));
            Value::Object(object)
        }
        Err(error) => json!({ "ok": false, "error": error.code() }),
    };
    value.to_string()
}

fn env_of(envelope: &Value) -> Env {
    crate::session_schema::env_from_json(get(envelope, "env"))
}

fn reduce_json_inner(input: &str) -> Result<Value, StoreError> {
    let envelope: Value = serde_json::from_str(input).map_err(|_| StoreError::Corrupt)?;
    let op = as_str(get(&envelope, "op")).ok_or(StoreError::Corrupt)?;
    let field = |key: &str| get(&envelope, key).ok_or(StoreError::InvalidArgument);
    let flag = |key: &str| get(&envelope, key) == Some(&Value::Bool(true));
    let messages = || match get(&envelope, "messages") {
        Some(Value::Array(items)) => items.as_slice(),
        _ => &[][..],
    };
    match op {
        "round_request" => {
            if !round_request_valid(field("request")?, flag("root_ok"), &env_of(&envelope)) {
                return Err(StoreError::InvalidArgument);
            }
            Ok(json!({ "locator": round_locator(field("request")?) }))
        }
        "selector_request" => {
            if !selector_request_valid(
                field("request")?,
                flag("cancellation"),
                flag("allow_zero_revision"),
                flag("root_ok"),
            ) {
                return Err(StoreError::InvalidArgument);
            }
            Ok(json!({ "locator": round_locator(field("request")?) }))
        }
        "selector_matches" => {
            Ok(json!({ "matches": selector_matches_row(field("request")?, field("row")?) }))
        }
        "result_only_shape" => {
            Ok(json!({ "matches": result_shape(field("result")?, &env_of(&envelope)) }))
        }
        "result_shape" => Ok(json!({ "matches": result_matches_request(
            field("result")?,
            field("request")?,
            get(&envelope, "provider_request_id"),
            &env_of(&envelope),
        )})),
        "round_cas" => Ok(json!({ "cas": round_cas_for_row(field("row")?) })),
        "locator_key" => Ok(json!({ "key": locator_key(field("locator")?) })),
        "assistant_message" => {
            Ok(json!({ "message": native_to_completion_message(field("message")?) }))
        }
        "public_receipt" => Ok(json!({ "receipt": public_receipt(
            field("provider")?,
            field("request")?,
            get(&envelope, "provider_request_id"),
            get(&envelope, "context_receipt").filter(|v| !v.is_null()),
        )})),
        "recovered_projection" => Ok(
            json!({ "projection": recovered_round_projection(field("row")?, field("request")?, messages())? }),
        ),
        "context_bundle" => {
            let (receipt, messages) = context_bundle(
                get(&envelope, "bundle").filter(|v| !v.is_null()),
                get(&envelope, "expected_digest"),
            )?;
            Ok(json!({ "receipt": receipt, "messages": messages }))
        }
        "conflict" => Ok(json!({ "result": conflict_result(
            get(&envelope, "operation_id"),
            as_str(get(&envelope, "failure_code")).ok_or(StoreError::InvalidArgument)?,
            field("request")?,
            get(&envelope, "actual_round_revision"),
            as_str(get(&envelope, "actual_round_status")),
            get(&envelope, "actual_transcript").filter(|v| !v.is_null()),
        )})),
        "unknown_result" => Ok(json!({ "result": unknown_result(
            field("request")?,
            as_str(get(&envelope, "status")).ok_or(StoreError::InvalidArgument)?,
            get(&envelope, "revision").and_then(Value::as_u64).unwrap_or(0),
            as_str(get(&envelope, "failure_code")).ok_or(StoreError::InvalidArgument)?,
        )})),
        "round_result" => Ok(json!({ "result": round_result_for_row(
            field("request")?,
            field("row")?,
            as_str(get(&envelope, "status")).ok_or(StoreError::InvalidArgument)?,
            as_str(get(&envelope, "failure_code")).ok_or(StoreError::InvalidArgument)?,
        )})),
        "query_result" => Ok(json!({ "result": query_result_for_row(
            field("request")?,
            field("row")?,
            as_str(get(&envelope, "status")).ok_or(StoreError::InvalidArgument)?,
            as_str(get(&envelope, "failure_code")),
        )})),
        "selector_conflict" => Ok(json!({ "result": selector_conflict(
            field("request")?,
            field("row")?,
            as_str(get(&envelope, "failure_code")).ok_or(StoreError::InvalidArgument)?,
        )})),
        "failure_code" => Ok(
            json!({ "code": failure_code(as_str(get(&envelope, "provider_error_code")), flag("digest_mismatch")) }),
        ),
        "safe_result" => Ok(json!({ "safe": operation_safe_result(field("result")?) })),
        "started_operation_commit" => Ok(json!({ "commit": started_operation_commit(
            field("request")?,
            as_str(get(&envelope, "request_sha256")).ok_or(StoreError::InvalidArgument)?,
            get(&envelope, "row"),
            as_str(get(&envelope, "status")).ok_or(StoreError::InvalidArgument)?,
            as_str(get(&envelope, "failure_code")),
        )})),
        "public_result" => Ok(json!({ "output": public_result_for_completed_row(
            field("request")?, field("row")?, field("round")?,
        )})),
        "round_failure_code" => {
            let state = as_str(get(&envelope, "state")).unwrap_or_default();
            // What the row itself recorded, when it recorded anything more
            // than the generic fallback. A round settled with a known local
            // cause keeps it in the row precisely so a reader after a
            // restart has something better than "could not be saved" to
            // say. `recorded_cause` refuses to soften an ambiguity, so this
            // can only ever make an answer more specific, never less honest.
            let recorded = recorded_cause(&envelope, state);
            Ok(match as_str(get(&envelope, "kind")) {
                Some("query") => json!({
                    "code": recorded.or_else(|| query_failure_code(state)),
                }),
                Some("reconciled") => json!({
                    "code": recorded.unwrap_or_else(|| reconciled_failure_code(state)),
                }),
                Some("cancelled") => json!({ "code": cancelled_failure_code(state) }),
                Some("ownerless") => match recovered_ownerless_state(state) {
                    Some(code) => json!({ "reportable": true, "code": recorded.or(code) }),
                    None => json!({ "reportable": false, "code": Value::Null }),
                },
                _ => return Err(StoreError::InvalidArgument),
            })
        }
        "tool_description" => Ok(json!({ "description": tool_description(
            as_str(get(&envelope, "name")).ok_or(StoreError::InvalidArgument)?,
        )})),
        "transcript_body" => Ok(json!({ "messages": transcript_for_body(messages())? })),
        _ => Err(StoreError::InvalidArgument),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env() -> Env {
        let mut harness = std::collections::BTreeMap::new();
        harness.insert("deepseek-v4-flash".to_string(), "dsh".to_string());
        Env {
            supported_models: vec!["deepseek-v4-flash".into()],
            harness_by_model: harness,
            ..Env::default()
        }
    }

    fn provider_result(finish: &str, calls: usize) -> Value {
        json!({
            "provider_request_id": "req-1", "provider_response_id": "resp-1",
            "requested_model": "deepseek-v4-flash", "model": "deepseek-v4-flash",
            "thinking_mode": "off", "text": "hi", "reasoning": "",
            "tool_calls": vec![json!({}); calls],
            "finish_reason": finish, "latency_ms": 12,
            "visible_history_sha256": "a".repeat(64),
            "model_input_sha256": "b".repeat(64),
            "request_body_sha256": "c".repeat(64),
        })
    }

    #[test]
    fn result_shape_binds_finish_reason_to_calls() {
        assert!(result_shape(&provider_result("stop", 0), &env()));
        assert!(!result_shape(&provider_result("stop", 1), &env()));
        assert!(result_shape(&provider_result("tool_calls", 1), &env()));
        assert!(!result_shape(&provider_result("tool_calls", 0), &env()));
        assert!(!result_shape(&provider_result("other", 0), &env()));
        assert!(!result_shape(&provider_result("stop", 0), &Env::default()));
    }

    #[test]
    fn failure_codes_map_the_transport() {
        assert_eq!(
            failure_code(Some("E_COMPLETION_HTTP_429"), false),
            "E_AGENT_TOOL_FAILED"
        );
        assert_eq!(
            failure_code(Some("E_COMPLETION_REDIRECT"), false),
            "E_AGENT_CONFLICT"
        );
        assert_eq!(
            failure_code(Some("E_COMPLETION_LENGTH"), true),
            "E_AGENT_TRANSCRIPT"
        );
        assert_eq!(failure_code(None, false), "E_AGENT_ROUND_AMBIGUOUS");
    }

    #[test]
    fn context_bundle_checks_the_byte_budget() {
        let digest = json!("d".repeat(64));
        let bundle = json!({
            "project_context_sha256": digest,
            "receipt": {
                "schema_version": 1, "snapshot_id": "0f0e3b1a-4c7d-4e2f-9a1b-2c3d4e5f6a7b",
                "snapshot_sha256": "e".repeat(64), "source_fingerprint": "f".repeat(64),
                "context_bytes": 5, "verified_at": "2026-09-15T00:00:00.000Z",
            },
            "messages": [{ "role": "system", "content": "hello", "attachments": [] }],
        });
        let (_, messages) = context_bundle(Some(&bundle), Some(&digest)).unwrap();
        assert_eq!(messages.len(), 1);
        let mut wrong = bundle.clone();
        wrong["receipt"]["context_bytes"] = json!(6);
        assert_eq!(
            context_bundle(Some(&wrong), Some(&digest)),
            Err(StoreError::Conflict)
        );
    }

    /// A refusal raised while the request was being built is not an
    /// ambiguity. Nothing was sent, so nothing may have happened, and
    /// nothing will change on a retry. Saying `E_AGENT_ROUND_AMBIGUOUS`
    /// here told a person their turn might have gone through and offered
    /// them a retry that could only fail the same way.
    #[test]
    fn a_refusal_raised_before_anything_was_sent_is_not_an_ambiguity() {
        for local in [
            "E_COMPLETION_CONTEXT_UNSUPPORTED",
            "E_COMPLETION_CONTEXT_INVALID",
            "E_COMPLETION_BODY_TOO_LARGE",
            "E_COMPLETION_HISTORY",
            "E_COMPLETION_TOOLS",
            "E_COMPLETION_THINKING",
            "E_COMPLETION_MODEL",
        ] {
            assert_eq!(failure_code(Some(local), false), "E_AGENT_CAPABILITY", "{local}");
        }
        // A silence from the provider still is one: the request went, and
        // what became of it is genuinely unknown.
        for remote in ["E_COMPLETION_TIMEOUT", "E_COMPLETION_TRANSPORT", ""] {
            assert_eq!(
                failure_code(Some(remote), false),
                "E_AGENT_ROUND_AMBIGUOUS",
                "{remote}",
            );
        }
        // And a digest mismatch outranks everything, as it always has.
        assert_eq!(
            failure_code(Some("E_COMPLETION_CONTEXT_UNSUPPORTED"), true),
            "E_AGENT_TRANSCRIPT",
        );
    }

    /// A reader after a restart gets the cause the row recorded, not the
    /// generic answer the state alone would give -- except over an
    /// ambiguity, which no recorded cause may soften.
    #[test]
    fn a_recorded_cause_outranks_the_generic_answer_but_never_an_ambiguity() {
        let answer = |kind: &str, state: &str, recorded: Value| {
            let envelope = json!({
                "op": "round_failure_code",
                "kind": kind,
                "state": state,
                "recorded": recorded,
            });
            let reply: Value = serde_json::from_str(&reduce_json(&envelope.to_string()))
                .expect("the query answers JSON");
            assert_eq!(reply["ok"], json!(true), "{reply}");
            reply
        };
        assert_eq!(
            answer("reconciled", "failed_retryable", json!("E_AGENT_CAPABILITY"))["code"],
            json!("E_AGENT_CAPABILITY"),
        );
        assert_eq!(
            answer("ownerless", "failed_retryable", json!("E_AGENT_CAPABILITY"))["code"],
            json!("E_AGENT_CAPABILITY"),
        );
        assert_eq!(
            answer("query", "unknown", json!("E_AGENT_CAPABILITY"))["code"],
            json!("E_AGENT_CAPABILITY"),
        );
        // Nothing recorded, and the generic answers stand.
        assert_eq!(
            answer("reconciled", "failed_retryable", Value::Null)["code"],
            json!("E_AGENT_PERSISTENCE"),
        );
        // An ambiguous round answers with its ambiguity whatever the row
        // says: a recorded cause cannot establish that a dispatched request
        // was not acted on.
        for kind in ["reconciled", "query", "ownerless"] {
            assert_eq!(
                answer(kind, "ambiguous", json!("E_AGENT_CAPABILITY"))["code"],
                json!("E_AGENT_ROUND_AMBIGUOUS"),
                "{kind}",
            );
        }
        // And a value outside the closed union is not read at all.
        assert_eq!(
            answer("reconciled", "failed_retryable", json!("nonsense"))["code"],
            json!("E_AGENT_PERSISTENCE"),
        );
    }
}
