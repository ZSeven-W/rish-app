//! The schema-3 provider-round journal (`DSHAgentRoundJournal`'s `…V3…`
//! selectors) as a pure reducer.
//!
//! The Objective-C facade owns the WAL transaction: it locates the round row,
//! its dispatch marker and (for completion) the bound transcript row, answers
//! the two liveness questions, and hands everything here as a [`View`]. The
//! reducer validates the arguments exactly as the ObjC implementation did,
//! decides the transition, and returns an [`Effect`] the facade applies
//! verbatim. Nothing here reads a clock, a file, or a task registry.
//!
//! Error codes are the `DSHAgentNativeStoreErrorCode` values; the order of
//! checks is kept identical to the ObjC methods so callers see the same code
//! for the same input.

use crate::canonical::{canonical_json, hash_json};
use crate::schema::*;
pub use crate::store::StoreError;
use crate::strict_json::parse_arguments;
use serde_json::{json, Map, Value};

/// `DSHAgentNativeWALMaxTranscriptBytes`.
pub const MAX_TRANSCRIPT_BYTES: usize = 2 * 1024 * 1024;
/// `DSHAgentNativeWALMaxTranscriptCount * DSHAgentNativeWALMaxRoundRowsPerAttempt`.
pub const MAX_ROUND_ROWS: u64 = 128 * 8;
const MAX_LAUNCH_ATTEMPTS: u64 = 8;
const MAX_ROUND_INDEX: u64 = 7;
const MAX_CALLS: usize = 16;
const MAX_TRANSCRIPT_MESSAGES: usize = 1024;

/// Host facts the reducer cannot derive: the process launch, the injected
/// clock, and the provider catalogue answers for the receipt being committed.
#[derive(Debug, Clone, Default)]
pub struct Env {
    pub launch_id: String,
    /// `[wal currentTimestamp]`, already canonical.
    pub now: String,
    /// Number of round rows currently in the WAL (capacity check on create).
    pub round_count: u64,
    /// `DSHHarnessSupportedModels()`.
    pub supported_models: Vec<String>,
    /// `DSHHarnessIdForModel(receipt.model)` for the receipt argument, if any.
    pub receipt_harness_id: Option<String>,
    /// `DSHValidateProviderBinding(receipt.provider_configuration, model)`
    /// when the receipt carries a binding; ignored otherwise.
    pub receipt_binding_valid: bool,
}

/// What the facade found in the WAL state for the locator at hand.
#[derive(Debug, Clone, Default)]
pub struct View {
    pub row: Option<Value>,
    /// The `kind == "round"` dispatch marker's state, when a marker exists.
    pub dispatch_state: Option<String>,
    /// The transcript row `row.transcript_before.transcript_ref` names.
    pub transcript: Option<Value>,
    /// `[wal isNativeTaskAlive:…]` for the owner passed as an argument.
    pub arg_owner_alive: bool,
    /// `[wal isNativeTaskAlive:…]` for the owner recorded on `row`.
    pub row_owner_alive: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DispatchEffect {
    /// Append a `not_dispatched` marker for the row's locator.
    InsertNotDispatched,
    /// Set the existing marker to `dispatched`.
    MarkDispatched,
}

/// The decided transition. `commit == false` with an `output` reproduces the
/// ObjC paths that answer without mutating (`already_present`,
/// `already_dispatched`, `query`).
#[derive(Debug, Clone, Default)]
pub struct Effect {
    pub commit: bool,
    pub output: Value,
    pub row: Option<Value>,
    pub dispatch: Option<DispatchEffect>,
    pub transcript: Option<Value>,
}

fn get<'a>(value: &'a Value, key: &str) -> Option<&'a Value> {
    value.get(key)
}

fn string_eq(value: Option<&Value>, expected: &str) -> bool {
    matches!(value, Some(Value::String(text)) if text == expected)
}

fn as_str(value: Option<&Value>) -> Option<&str> {
    match value {
        Some(Value::String(text)) => Some(text.as_str()),
        _ => None,
    }
}

fn set(row: &mut Map<String, Value>, key: &str, value: Value) {
    row.insert(key.to_string(), value);
}

// MARK: - Validators (DSHAgentRound* statics)

const LOCATOR_KEYS: &[&str] = &[
    "schema_version",
    "task_id",
    "attempt_id",
    "round_id",
    "round_index",
];

pub fn round_locator(value: Option<&Value>) -> bool {
    let Some(map) = exact_keys(value, LOCATOR_KEYS) else {
        return false;
    };
    safe_integer(map.get("schema_version"), 1, false).is_some()
        && canonical_uuid(map.get("task_id"))
        && canonical_uuid(map.get("attempt_id"))
        && canonical_uuid(map.get("round_id"))
        && safe_integer(map.get("round_index"), MAX_ROUND_INDEX, true).is_some()
}

fn round_insert_cas(value: Option<&Value>) -> bool {
    let keys = [
        "schema_version",
        "locator",
        "expected_absent",
        "expected_transcript_generation",
        "expected_transcript_sha256",
        "expected_root_fingerprint_sha256",
        "expected_binding_revision",
    ];
    let Some(map) = exact_keys(value, &keys) else {
        return false;
    };
    safe_integer(map.get("schema_version"), 1, false).is_some()
        && round_locator(map.get("locator"))
        && map.get("expected_absent") == Some(&Value::Bool(true))
        && safe_integer(
            map.get("expected_transcript_generation"),
            MAX_SAFE_INTEGER,
            true,
        )
        .is_some()
        && canonical_sha256(map.get("expected_transcript_sha256"))
        && canonical_sha256(map.get("expected_root_fingerprint_sha256"))
        && safe_integer(
            map.get("expected_binding_revision"),
            MAX_SAFE_INTEGER,
            false,
        )
        .is_some()
}

const ROUND_STATES: &[&str] = &[
    "in_flight",
    "cancel_requested",
    "failed_retryable",
    "completed",
    "cancelled",
    "unknown",
    "ambiguous",
];

fn round_v3_cas(value: Option<&Value>) -> bool {
    let keys = [
        "schema_version",
        "locator",
        "expected_row_revision",
        "expected_state",
        "expected_owner_generation",
        "expected_launch_id",
        "expected_native_task_id",
        "expected_transcript_generation",
        "expected_transcript_sha256",
        "expected_root_fingerprint_sha256",
        "expected_binding_revision",
    ];
    let Some(map) = exact_keys(value, &keys) else {
        return false;
    };
    let nullable = |key: &str, check: &dyn Fn(Option<&Value>) -> bool| -> bool {
        let field = map.get(key);
        is_null(field) || check(field)
    };
    safe_integer(map.get("schema_version"), 2, false) == Some(2)
        && round_locator(map.get("locator"))
        && safe_integer(map.get("expected_row_revision"), MAX_SAFE_INTEGER, false).is_some()
        && as_str(map.get("expected_state")).is_some_and(|state| ROUND_STATES.contains(&state))
        && nullable("expected_owner_generation", &|value| {
            safe_integer(value, MAX_SAFE_INTEGER, false).is_some()
        })
        && nullable("expected_launch_id", &canonical_uuid)
        && nullable("expected_native_task_id", &canonical_uuid)
        && safe_integer(
            map.get("expected_transcript_generation"),
            MAX_SAFE_INTEGER,
            true,
        )
        .is_some()
        && canonical_sha256(map.get("expected_transcript_sha256"))
        && canonical_sha256(map.get("expected_root_fingerprint_sha256"))
        && safe_integer(
            map.get("expected_binding_revision"),
            MAX_SAFE_INTEGER,
            false,
        )
        .is_some()
}

fn round_v3_cas_matches_row(row: &Value, cas: &Value) -> bool {
    let before = get(row, "transcript_before").unwrap_or(&Value::Null);
    if !round_v3_cas(Some(cas))
        || get(row, "locator") != get(cas, "locator")
        || get(row, "row_revision") != get(cas, "expected_row_revision")
        || get(row, "state") != get(cas, "expected_state")
        || get(before, "generation") != get(cas, "expected_transcript_generation")
        || get(before, "transcript_sha256") != get(cas, "expected_transcript_sha256")
        || get(row, "root_fingerprint_sha256") != get(cas, "expected_root_fingerprint_sha256")
        || get(row, "binding_revision") != get(cas, "expected_binding_revision")
    {
        return false;
    }
    let expected_generation = get(cas, "expected_owner_generation");
    let owner = get(row, "owner");
    if is_null(expected_generation) {
        return is_null(owner);
    }
    let Some(owner) = owner else { return false };
    owner_shape(Some(owner))
        && get(owner, "owner_generation") == expected_generation
        && get(owner, "launch_id") == get(cas, "expected_launch_id")
        && get(owner, "native_task_id") == get(cas, "expected_native_task_id")
}

fn round_v3_call(call: &Value, expected_index: u64) -> bool {
    let keys = [
        "schema_version",
        "call_index",
        "call_id",
        "name",
        "arguments_sha256",
        "safe_summary_key",
        "access",
        "approval_state",
    ];
    let Some(map) = exact_keys(Some(call), &keys) else {
        return false;
    };
    if safe_integer(map.get("schema_version"), 3, false) != Some(3)
        || safe_integer(map.get("call_index"), MAX_SAFE_INTEGER, true) != Some(expected_index)
        || !opaque_identifier(map.get("call_id"))
        || bounded_utf8(map.get("name"), 64, false).is_none()
        || !canonical_sha256(map.get("arguments_sha256"))
        || bounded_utf8(map.get("safe_summary_key"), 128, false).is_none()
    {
        return false;
    }
    let access = as_str(map.get("access"));
    let approval = as_str(map.get("approval_state"));
    if access == Some("durable_deny") {
        return approval == Some("durable_denied")
            && as_str(map.get("safe_summary_key")) == Some("agent.unknown");
    }
    let expected_summary = format!("agent.{}", as_str(map.get("name")).unwrap_or_default());
    matches!(
        access,
        Some("auto" | "conversation_confirm" | "confirm_once")
    ) && approval == Some("deferred")
        && as_str(map.get("safe_summary_key")) == Some(expected_summary.as_str())
}

fn completion_receipt(receipt: Option<&Value>, locator: &Value, env: &Env) -> bool {
    let Some(Value::Object(original)) = receipt else {
        return false;
    };
    // DSHProviderRecordWithoutConfiguration: a provider binding is validated
    // by the host against the receipt's model and then hidden from the exact
    // key check.
    let stripped: Map<String, Value>;
    let map = if original.contains_key("provider_configuration") {
        if !env.receipt_binding_valid {
            return false;
        }
        stripped = original
            .iter()
            .filter(|(key, _)| key.as_str() != "provider_configuration")
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect();
        &stripped
    } else {
        original
    };
    let value = Value::Object(map.clone());
    let keys = [
        "schema_version",
        "transport_schema_version",
        "turn_id",
        "attempt_id",
        "round_id",
        "round_index",
        "provider_request_id",
        "provider_response_id",
        "requested_model",
        "model",
        "thinking_mode",
        "finish_reason",
        "latency_ms",
        "visible_history_sha256",
        "model_input_sha256",
        "request_body_sha256",
        "project_context_receipt",
    ];
    let Some(map) = exact_keys_with_optional(Some(&value), &keys, &["harness_id"]) else {
        return false;
    };
    if safe_integer(map.get("schema_version"), 1, false).is_none()
        || !matches!(
            safe_integer(map.get("transport_schema_version"), 3, false),
            Some(2 | 3)
        )
        || !canonical_uuid(map.get("turn_id"))
        || !canonical_uuid(map.get("attempt_id"))
        || !canonical_uuid(map.get("round_id"))
        || map.get("turn_id") != get(locator, "task_id")
        || map.get("attempt_id") != get(locator, "attempt_id")
        || map.get("round_id") != get(locator, "round_id")
        || safe_integer(map.get("round_index"), MAX_ROUND_INDEX, true).is_none()
        || map.get("round_index") != get(locator, "round_index")
        || !opaque_identifier(map.get("provider_request_id"))
        || !opaque_identifier(map.get("provider_response_id"))
        || bounded_utf8(map.get("requested_model"), 128, false).is_none()
        || bounded_utf8(map.get("model"), 128, false).is_none()
        || bounded_utf8(map.get("thinking_mode"), 32, false).is_none()
        || bounded_utf8(map.get("finish_reason"), 32, false).is_none()
        || safe_integer(map.get("latency_ms"), 24 * 60 * 60 * 1000, true).is_none()
        || !canonical_sha256(map.get("visible_history_sha256"))
        || !canonical_sha256(map.get("model_input_sha256"))
        || !canonical_sha256(map.get("request_body_sha256"))
    {
        return false;
    }
    if let Some(harness) = map.get("harness_id") {
        if as_str(Some(harness)) != env.receipt_harness_id.as_deref() {
            return false;
        }
    }
    let requested = as_str(map.get("requested_model")).unwrap_or_default();
    let model = as_str(map.get("model")).unwrap_or_default();
    let supported = |candidate: &str| env.supported_models.iter().any(|entry| entry == candidate);
    if !supported(requested)
        || !supported(model)
        || requested != model
        || !matches!(
            as_str(map.get("thinking_mode")),
            Some("off" | "high" | "max")
        )
        || !matches!(
            as_str(map.get("finish_reason")),
            Some("stop" | "tool_calls" | "length" | "content_filter")
        )
    {
        return false;
    }
    let context = map.get("project_context_receipt");
    if is_null(context) {
        return true;
    }
    let context_keys = [
        "schema_version",
        "snapshot_id",
        "snapshot_sha256",
        "source_fingerprint",
        "context_bytes",
        "verified_at",
    ];
    let Some(context) = exact_keys(context, &context_keys) else {
        return false;
    };
    safe_integer(context.get("schema_version"), 1, false).is_some()
        && canonical_uuid(context.get("snapshot_id"))
        && canonical_sha256(context.get("snapshot_sha256"))
        && canonical_sha256(context.get("source_fingerprint"))
        && safe_integer(context.get("context_bytes"), 32 * 1024 * 1024, true).is_some()
        && canonical_timestamp(context.get("verified_at"))
}

const ROW_KEYS: &[&str] = &[
    "schema_version",
    "locator",
    "row_revision",
    "root_fingerprint_sha256",
    "binding_revision",
    "request_sha256",
    "transcript_before",
    "launch_attempt",
    "state",
    "owner",
    "failure_code",
    "completion_receipt",
    "transcript_after",
    "calls",
    "batch_class",
    "executable_call_count",
    "denied_call_count",
    "terminal_kind",
    "created_at",
    "updated_at",
];

/// `DSHAgentRoundV3Row`: the full persisted-row invariant.
pub fn round_v3_row(row: &Value, env: &Env) -> bool {
    let Some(map) = exact_keys(Some(row), ROW_KEYS) else {
        return false;
    };
    let Some(Value::Array(calls)) = map.get("calls") else {
        return false;
    };
    if safe_integer(map.get("schema_version"), 3, false) != Some(3)
        || !round_locator(map.get("locator"))
        || safe_integer(map.get("row_revision"), MAX_SAFE_INTEGER, false).is_none()
        || !canonical_sha256(map.get("root_fingerprint_sha256"))
        || safe_integer(map.get("binding_revision"), MAX_SAFE_INTEGER, false).is_none()
        || !canonical_sha256(map.get("request_sha256"))
        || !transcript_reference(map.get("transcript_before"))
        || safe_integer(map.get("launch_attempt"), MAX_LAUNCH_ATTEMPTS, false).is_none()
        || calls.len() > MAX_CALLS
        || safe_integer(map.get("executable_call_count"), MAX_CALLS as u64, true).is_none()
        || safe_integer(map.get("denied_call_count"), MAX_CALLS as u64, true).is_none()
        || !canonical_timestamp(map.get("created_at"))
        || !canonical_timestamp(map.get("updated_at"))
    {
        return false;
    }
    let Some(state) = as_str(map.get("state")) else {
        return false;
    };
    if !ROUND_STATES.contains(&state) {
        return false;
    }
    let locator = map.get("locator").expect("validated");
    let owner = map.get("owner");
    let owner_null = is_null(owner);
    if !owner_null
        && (!owner_shape(owner) || owner.and_then(|o| get(o, "task_id")) != get(locator, "task_id"))
    {
        return false;
    }
    let failure = map.get("failure_code");
    let failure_null = is_null(failure);
    if !failure_null && !failure_code(failure) {
        return false;
    }
    let receipt = map.get("completion_receipt");
    let receipt_null = is_null(receipt);
    if !receipt_null && !completion_receipt(receipt, locator, env) {
        return false;
    }
    let after = map.get("transcript_after");
    let after_null = is_null(after);
    if !after_null && !transcript_reference(after) {
        return false;
    }
    let batch_class = map.get("batch_class");
    let batch_null = is_null(batch_class);
    if !batch_null
        && !matches!(
            as_str(batch_class),
            Some("executable" | "mixed" | "denied_only")
        )
    {
        return false;
    }
    let mut executable = 0u64;
    let mut denied = 0u64;
    for (index, call) in calls.iter().enumerate() {
        if !round_v3_call(call, index as u64) {
            return false;
        }
        if string_eq(get(call, "access"), "durable_deny") {
            denied += 1;
        } else {
            executable += 1;
        }
    }
    if Some(executable) != safe_integer(map.get("executable_call_count"), MAX_CALLS as u64, true)
        || Some(denied) != safe_integer(map.get("denied_call_count"), MAX_CALLS as u64, true)
    {
        return false;
    }
    match as_str(batch_class) {
        None => {
            if !calls.is_empty() || executable != 0 || denied != 0 {
                return false;
            }
        }
        Some("executable") if executable == 0 || denied != 0 => return false,
        Some("mixed") if executable == 0 || denied == 0 => return false,
        Some("denied_only") if executable != 0 || denied == 0 => return false,
        _ => {}
    }
    let terminal = map.get("terminal_kind");
    let terminal_null = is_null(terminal);
    if !terminal_null && !matches!(as_str(terminal), Some("final" | "tool_batch" | "blocked")) {
        return false;
    }
    match state {
        "in_flight" | "cancel_requested" => {
            if owner_null || !receipt_null || !terminal_null {
                return false;
            }
        }
        "completed" => {
            if !owner_null || receipt_null || after_null || terminal_null || !failure_null {
                return false;
            }
            let finish = receipt.and_then(|r| as_str(get(r, "finish_reason")));
            let terminal = as_str(terminal);
            match finish {
                Some("stop") if terminal != Some("final") || !calls.is_empty() => return false,
                Some("tool_calls") if terminal != Some("tool_batch") || calls.is_empty() => {
                    return false
                }
                Some("length" | "content_filter")
                    if terminal != Some("blocked") || !calls.is_empty() =>
                {
                    return false
                }
                _ => {}
            }
        }
        "cancelled" => {
            if !owner_null
                || !receipt_null
                || after_null
                || as_str(terminal) != Some("blocked")
                || as_str(failure) != Some("E_AGENT_CANCELLED")
                || after != map.get("transcript_before")
            {
                return false;
            }
        }
        "failed_retryable" => {
            if !owner_null || !receipt_null || !after_null || !terminal_null || failure_null {
                return false;
            }
        }
        "unknown" | "ambiguous" => {
            if !owner_null || !receipt_null || !terminal_null || failure_null {
                return false;
            }
            if state == "unknown" && as_str(failure) != Some("E_AGENT_PERSISTENCE") {
                return false;
            }
            if state == "ambiguous" && as_str(failure) != Some("E_AGENT_ROUND_AMBIGUOUS") {
                return false;
            }
        }
        _ => {}
    }
    true
}

/// `DSHAgentRoundV3MessagesMatchCalls`: every assistant message's tool calls,
/// in order, must be presented by `calls` with matching identity digests.
fn round_v3_messages_match_calls(
    messages: &Value,
    calls: &Value,
    round_index: u64,
) -> Result<(), StoreError> {
    let (Value::Array(messages), Value::Array(calls)) = (messages, calls) else {
        return Err(StoreError::InvalidArgument);
    };
    if messages.is_empty() || messages.len() > MAX_CALLS || calls.len() > MAX_CALLS {
        return Err(StoreError::InvalidArgument);
    }
    let message_keys = [
        "schema_version",
        "role",
        "round_index",
        "content",
        "reasoning_content",
        "tool_calls",
    ];
    let tool_call_keys = ["schema_version", "call_id", "name", "arguments_json"];
    let mut call_index = 0usize;
    for message in messages {
        let Some(map) = exact_keys(Some(message), &message_keys) else {
            return Err(StoreError::InvalidArgument);
        };
        let Some(Value::Array(tool_calls)) = map.get("tool_calls") else {
            return Err(StoreError::InvalidArgument);
        };
        if safe_integer(map.get("schema_version"), 1, false).is_none()
            || as_str(map.get("role")) != Some("assistant")
            || safe_integer(map.get("round_index"), MAX_SAFE_INTEGER, true) != Some(round_index)
            || bounded_utf8(map.get("content"), MAX_TRANSCRIPT_BYTES, true).is_none()
            || bounded_utf8(map.get("reasoning_content"), MAX_TRANSCRIPT_BYTES, true).is_none()
            || tool_calls.len() > MAX_CALLS
        {
            return Err(StoreError::InvalidArgument);
        }
        for tool_call in tool_calls {
            let Some(tool) = exact_keys(Some(tool_call), &tool_call_keys) else {
                return Err(StoreError::InvalidArgument);
            };
            let arguments_ok = as_str(tool.get("arguments_json"))
                .and_then(parse_arguments)
                .is_some();
            if safe_integer(tool.get("schema_version"), 1, false).is_none()
                || !opaque_identifier(tool.get("call_id"))
                || bounded_utf8(tool.get("name"), 64, false).is_none()
                || !arguments_ok
                || call_index >= calls.len()
            {
                return Err(StoreError::InvalidArgument);
            }
            let call = &calls[call_index];
            let digest = arguments_sha256(tool.get("name"), tool.get("arguments_json"));
            if !round_v3_call(call, call_index as u64)
                || get(call, "call_id") != tool.get("call_id")
                || get(call, "name") != tool.get("name")
                || as_str(get(call, "arguments_sha256")) != digest.as_deref()
            {
                return Err(StoreError::Conflict);
            }
            call_index += 1;
        }
    }
    if call_index != calls.len() {
        return Err(StoreError::Conflict);
    }
    Ok(())
}

fn round_v3_output(row: &Value, status: &str) -> Value {
    json!({ "schema_version": 3, "status": status, "row": row })
}

fn bump_revision(row: &mut Map<String, Value>) -> Result<(), StoreError> {
    let revision =
        safe_integer(row.get("row_revision"), MAX_SAFE_INTEGER, false).unwrap_or(MAX_SAFE_INTEGER);
    if revision >= MAX_SAFE_INTEGER {
        return Err(StoreError::Capacity);
    }
    set(row, "row_revision", Value::from(revision + 1));
    Ok(())
}

fn reset_batch(row: &mut Map<String, Value>) {
    set(row, "calls", Value::Array(Vec::new()));
    set(row, "batch_class", Value::Null);
    set(row, "executable_call_count", Value::from(0u64));
    set(row, "denied_call_count", Value::from(0u64));
}

fn row_map(row: &Value) -> Map<String, Value> {
    match row {
        Value::Object(map) => map.clone(),
        _ => Map::new(),
    }
}

// MARK: - Operations

fn create(args: &Map<String, Value>, env: &Env, view: &View) -> Result<Effect, StoreError> {
    let insert_cas = args.get("insert_cas").unwrap_or(&Value::Null);
    let round = args.get("round").unwrap_or(&Value::Null);
    let before = get(round, "transcript_before").unwrap_or(&Value::Null);
    if !round_insert_cas(Some(insert_cas))
        || !round_v3_row(round, env)
        || get(round, "locator") != get(insert_cas, "locator")
        || get(before, "generation") != get(insert_cas, "expected_transcript_generation")
        || get(before, "transcript_sha256") != get(insert_cas, "expected_transcript_sha256")
        || get(round, "root_fingerprint_sha256")
            != get(insert_cas, "expected_root_fingerprint_sha256")
        || get(round, "binding_revision") != get(insert_cas, "expected_binding_revision")
    {
        return Err(StoreError::InvalidArgument);
    }
    let owner = get(round, "owner");
    if is_null(owner)
        || as_str(owner.and_then(|o| get(o, "launch_id"))) != Some(env.launch_id.as_str())
        || !view.arg_owner_alive
    {
        return Err(StoreError::OwnerLost);
    }
    if let Some(existing) = &view.row {
        if existing != round {
            return Err(StoreError::Conflict);
        }
        return Ok(Effect {
            commit: false,
            output: round_v3_output(existing, "already_present"),
            ..Default::default()
        });
    }
    if env.round_count >= MAX_ROUND_ROWS {
        return Err(StoreError::Capacity);
    }
    Ok(Effect {
        commit: true,
        output: round_v3_output(round, "inserted"),
        row: Some(round.clone()),
        dispatch: Some(DispatchEffect::InsertNotDispatched),
        transcript: None,
    })
}

fn claim(args: &Map<String, Value>, env: &Env, view: &View) -> Result<Effect, StoreError> {
    let locator = args.get("locator").unwrap_or(&Value::Null);
    let revision = args.get("expected_row_revision");
    let owner = args.get("owner").unwrap_or(&Value::Null);
    if !round_locator(Some(locator))
        || safe_integer(revision, MAX_SAFE_INTEGER, false).is_none()
        || !owner_shape(Some(owner))
        || get(owner, "task_id") != get(locator, "task_id")
        || as_str(get(owner, "launch_id")) != Some(env.launch_id.as_str())
        || !view.arg_owner_alive
    {
        return Err(StoreError::OwnerLost);
    }
    let Some(existing) = &view.row else {
        return Err(StoreError::NotFound);
    };
    if !round_v3_row(existing, env)
        || get(existing, "row_revision") != revision
        || !string_eq(get(existing, "state"), "failed_retryable")
        || !is_null(get(existing, "owner"))
    {
        return Err(StoreError::Conflict);
    }
    if view.dispatch_state.as_deref() != Some("not_dispatched") {
        return Err(StoreError::Conflict);
    }
    let mut row = row_map(existing);
    set(&mut row, "owner", owner.clone());
    set(&mut row, "state", Value::from("in_flight"));
    let launch_attempt = safe_integer(row.get("launch_attempt"), MAX_SAFE_INTEGER, true)
        .unwrap_or(MAX_LAUNCH_ATTEMPTS);
    if launch_attempt >= MAX_LAUNCH_ATTEMPTS {
        return Err(StoreError::Capacity);
    }
    set(&mut row, "launch_attempt", Value::from(launch_attempt + 1));
    set(&mut row, "failure_code", Value::Null);
    reset_batch(&mut row);
    set(&mut row, "terminal_kind", Value::Null);
    bump_revision(&mut row)?;
    set(&mut row, "updated_at", Value::from(env.now.as_str()));
    let row = Value::Object(row);
    if !round_v3_row(&row, env) {
        return Err(StoreError::Corrupt);
    }
    Ok(Effect {
        commit: true,
        output: round_v3_output(&row, "claimed"),
        row: Some(row),
        ..Default::default()
    })
}

fn mark_dispatched(
    args: &Map<String, Value>,
    env: &Env,
    view: &View,
) -> Result<Effect, StoreError> {
    let cas = args.get("cas").unwrap_or(&Value::Null);
    if !round_v3_cas(Some(cas)) {
        return Err(StoreError::InvalidArgument);
    }
    let Some(existing) = &view.row else {
        return Err(StoreError::NotFound);
    };
    let state = as_str(get(existing, "state"));
    if !round_v3_cas_matches_row(existing, cas)
        || !matches!(state, Some("in_flight" | "cancel_requested"))
        || is_null(get(existing, "owner"))
        || !view.row_owner_alive
    {
        return Err(StoreError::Conflict);
    }
    match view.dispatch_state.as_deref() {
        None => return Err(StoreError::Corrupt),
        Some("dispatched") => {
            return Ok(Effect {
                commit: false,
                output: round_v3_output(existing, "already_dispatched"),
                ..Default::default()
            });
        }
        Some("not_dispatched") => {}
        Some(_) => return Err(StoreError::Corrupt),
    }
    let mut row = row_map(existing);
    bump_revision(&mut row)?;
    set(&mut row, "updated_at", Value::from(env.now.as_str()));
    let row = Value::Object(row);
    if !round_v3_row(&row, env) {
        return Err(StoreError::Corrupt);
    }
    Ok(Effect {
        commit: true,
        output: round_v3_output(&row, "dispatched"),
        row: Some(row),
        dispatch: Some(DispatchEffect::MarkDispatched),
        transcript: None,
    })
}

fn complete(args: &Map<String, Value>, env: &Env, view: &View) -> Result<Effect, StoreError> {
    let null = Value::Null;
    let locator = args.get("locator").unwrap_or(&null);
    let cas = args.get("cas").unwrap_or(&null);
    let messages = args.get("messages").unwrap_or(&null);
    let receipt = args.get("receipt");
    let terminal_kind = as_str(args.get("terminal_kind"));
    let calls = args.get("calls").unwrap_or(&null);
    let root = args.get("root");
    if !round_locator(Some(locator))
        || !round_v3_cas(Some(cas))
        || get(cas, "locator") != Some(locator)
        || !root_full(root)
        || !completion_receipt(receipt, locator, env)
        || !matches!(terminal_kind, Some("final" | "tool_batch" | "blocked"))
    {
        return Err(StoreError::InvalidArgument);
    }
    let round_index =
        safe_integer(get(locator, "round_index"), MAX_ROUND_INDEX, true).expect("validated");
    round_v3_messages_match_calls(messages, calls, round_index)?;
    let calls_array = calls.as_array().expect("validated");
    let terminal_kind = terminal_kind.expect("validated");
    if (terminal_kind == "tool_batch") == calls_array.is_empty() {
        return Err(StoreError::InvalidArgument);
    }
    let messages_array = messages.as_array().expect("validated");

    let Some(existing) = &view.row else {
        return Err(StoreError::Conflict);
    };
    if !round_v3_cas_matches_row(existing, cas)
        || !matches!(
            as_str(get(existing, "state")),
            Some("in_flight" | "cancel_requested")
        )
        || view.dispatch_state.as_deref() != Some("dispatched")
    {
        return Err(StoreError::Conflict);
    }
    let before = get(existing, "transcript_before").unwrap_or(&null);
    let Some(transcript_row) = &view.transcript else {
        return Err(StoreError::Conflict);
    };
    if get(transcript_row, "transcript_ref") != get(before, "transcript_ref")
        || !string_eq(get(transcript_row, "state"), "open")
        || get(transcript_row, "generation") != get(before, "generation")
        || get(transcript_row, "transcript_sha256") != get(before, "transcript_sha256")
        || get(transcript_row, "transcript_bytes") != get(before, "transcript_bytes")
        || get(transcript_row, "root_fingerprint_sha256")
            != get(existing, "root_fingerprint_sha256")
    {
        return Err(StoreError::Conflict);
    }
    let mut message_rows = match get(transcript_row, "messages") {
        Some(Value::Array(rows)) => rows.clone(),
        _ => return Err(StoreError::Corrupt),
    };
    let generation = safe_integer(get(transcript_row, "generation"), MAX_SAFE_INTEGER, true)
        .unwrap_or(MAX_SAFE_INTEGER);
    let added = messages_array.len() as u64;
    if generation > MAX_SAFE_INTEGER - added
        || message_rows.len() + messages_array.len() > MAX_TRANSCRIPT_MESSAGES
    {
        return Err(StoreError::Capacity);
    }
    message_rows.extend(messages_array.iter().cloned());
    let generation = generation + added;
    let digest_input = json!({
        "schema_version": 1,
        "transcript_ref": get(transcript_row, "transcript_ref"),
        "attempt_id": get(transcript_row, "attempt_id"),
        "root_fingerprint_sha256": get(transcript_row, "root_fingerprint_sha256"),
        "generation": generation,
        "messages": message_rows,
    });
    let Ok(digest_bytes) = canonical_json(&digest_input) else {
        return Err(StoreError::Corrupt);
    };
    let Some(digest) = hash_json("agent-transcript", &digest_input) else {
        return Err(StoreError::Corrupt);
    };
    if digest_bytes.len() > MAX_TRANSCRIPT_BYTES {
        return Err(StoreError::Capacity);
    }
    let mut transcript = row_map(transcript_row);
    set(
        &mut transcript,
        "messages",
        digest_input["messages"].clone(),
    );
    set(&mut transcript, "generation", Value::from(generation));
    set(
        &mut transcript,
        "transcript_sha256",
        Value::from(digest.as_str()),
    );
    set(
        &mut transcript,
        "transcript_bytes",
        Value::from(digest_bytes.len() as u64),
    );
    set(&mut transcript, "updated_at", Value::from(env.now.as_str()));
    let after = json!({
        "schema_version": 1,
        "transcript_ref": get(transcript_row, "transcript_ref"),
        "generation": generation,
        "transcript_sha256": digest,
        "transcript_bytes": digest_bytes.len() as u64,
    });

    let mut row = row_map(existing);
    // The revision check precedes the field writes in ObjC too; the row is
    // discarded on failure either way.
    if safe_integer(row.get("row_revision"), MAX_SAFE_INTEGER, false).unwrap_or(MAX_SAFE_INTEGER)
        >= MAX_SAFE_INTEGER
    {
        return Err(StoreError::Capacity);
    }
    let denied = calls_array
        .iter()
        .filter(|call| string_eq(get(call, "access"), "durable_deny"))
        .count() as u64;
    let executable = calls_array.len() as u64 - denied;
    set(&mut row, "state", Value::from("completed"));
    set(&mut row, "owner", Value::Null);
    set(&mut row, "failure_code", Value::Null);
    set(
        &mut row,
        "completion_receipt",
        receipt.cloned().unwrap_or(Value::Null),
    );
    set(&mut row, "transcript_after", after.clone());
    set(&mut row, "terminal_kind", Value::from(terminal_kind));
    set(&mut row, "calls", calls.clone());
    let batch_class = if calls_array.is_empty() {
        Value::Null
    } else if denied == 0 {
        Value::from("executable")
    } else if executable == 0 {
        Value::from("denied_only")
    } else {
        Value::from("mixed")
    };
    set(&mut row, "batch_class", batch_class);
    set(&mut row, "executable_call_count", Value::from(executable));
    set(&mut row, "denied_call_count", Value::from(denied));
    bump_revision(&mut row)?;
    set(&mut row, "updated_at", Value::from(env.now.as_str()));
    let row = Value::Object(row);
    if !round_v3_row(&row, env) {
        return Err(StoreError::Corrupt);
    }
    Ok(Effect {
        commit: true,
        output: json!({ "schema_version": 3, "status": "completed", "row": row, "transcript": after }),
        row: Some(row),
        dispatch: None,
        transcript: Some(Value::Object(transcript)),
    })
}

fn cancel(args: &Map<String, Value>, env: &Env, view: &View) -> Result<Effect, StoreError> {
    let cas = args.get("cas").unwrap_or(&Value::Null);
    if !round_v3_cas(Some(cas)) {
        return Err(StoreError::InvalidArgument);
    }
    let Some(existing) = &view.row else {
        return Err(StoreError::NotFound);
    };
    if !round_v3_cas_matches_row(existing, cas) {
        return Err(StoreError::Conflict);
    }
    let Some(dispatch_state) = view.dispatch_state.as_deref() else {
        return Err(StoreError::Corrupt);
    };
    let mut row = row_map(existing);
    let state = as_str(get(existing, "state"));
    if state == Some("in_flight") {
        set(&mut row, "state", Value::from("cancel_requested"));
        set(&mut row, "updated_at", Value::from(env.now.as_str()));
    } else if state == Some("cancel_requested") && dispatch_state == "not_dispatched" {
        set(&mut row, "state", Value::from("cancelled"));
        set(&mut row, "owner", Value::Null);
        set(&mut row, "failure_code", Value::from("E_AGENT_CANCELLED"));
        set(&mut row, "completion_receipt", Value::Null);
        let before = row.get("transcript_before").cloned().unwrap_or(Value::Null);
        set(&mut row, "transcript_after", before);
        set(&mut row, "terminal_kind", Value::from("blocked"));
        reset_batch(&mut row);
        set(&mut row, "updated_at", Value::from(env.now.as_str()));
    } else {
        return Err(StoreError::Conflict);
    }
    bump_revision(&mut row)?;
    let row = Value::Object(row);
    if !round_v3_row(&row, env) {
        return Err(StoreError::Corrupt);
    }
    let status = if string_eq(get(&row, "state"), "cancelled") {
        "cancelled"
    } else {
        "cancel_requested"
    };
    Ok(Effect {
        commit: true,
        output: round_v3_output(&row, status),
        row: Some(row),
        ..Default::default()
    })
}

fn reconcile(args: &Map<String, Value>, env: &Env, view: &View) -> Result<Effect, StoreError> {
    let locator = args.get("locator").unwrap_or(&Value::Null);
    let cas = args.get("cas").unwrap_or(&Value::Null);
    if !round_locator(Some(locator))
        || !round_v3_cas(Some(cas))
        || get(cas, "locator") != Some(locator)
    {
        return Err(StoreError::InvalidArgument);
    }
    let Some(existing) = &view.row else {
        return Err(StoreError::NotFound);
    };
    let state = as_str(get(existing, "state"));
    if !round_v3_cas_matches_row(existing, cas)
        || !matches!(state, Some("in_flight" | "cancel_requested"))
        || is_null(get(existing, "owner"))
        || view.row_owner_alive
    {
        return Err(StoreError::Conflict);
    }
    let Some(dispatch_state) = view.dispatch_state.as_deref() else {
        return Err(StoreError::Corrupt);
    };
    let not_dispatched = dispatch_state == "not_dispatched";
    let cancel_before_dispatch = state == Some("cancel_requested") && not_dispatched;
    let mut row = row_map(existing);
    let next_state = if cancel_before_dispatch {
        "cancelled"
    } else if not_dispatched {
        "failed_retryable"
    } else {
        "ambiguous"
    };
    // The cause, when the caller knows one and the round provably never
    // left the device.
    //
    // A refusal raised while the request was being built -- an attachment
    // the transport cannot carry, a dialect that cannot express a round
    // transcript -- is the only account of why the turn ended, and it dies
    // here unless the row keeps it: every later reader takes the row's code,
    // and recovery after a restart has nothing else to read.
    //
    // It is honoured **only** for a round that was never dispatched. A
    // dispatched round whose answer never came is ambiguous no matter what
    // its writer believes, and letting a caller name a confident cause there
    // would turn an ambiguity into false certainty -- the one thing this
    // whole marker exists to prevent.
    let stated = as_str(args.get("failure_code"))
        .filter(|_| not_dispatched && !cancel_before_dispatch)
        .filter(|code| crate::schema::failure_code(args.get("failure_code")) && *code != "E_AGENT_ROUND_AMBIGUOUS");
    let failure = if cancel_before_dispatch {
        "E_AGENT_CANCELLED"
    } else if not_dispatched {
        stated.unwrap_or("E_AGENT_PERSISTENCE")
    } else {
        "E_AGENT_ROUND_AMBIGUOUS"
    };
    set(&mut row, "state", Value::from(next_state));
    set(&mut row, "owner", Value::Null);
    set(&mut row, "failure_code", Value::from(failure));
    set(&mut row, "completion_receipt", Value::Null);
    let after = if cancel_before_dispatch {
        row.get("transcript_before").cloned().unwrap_or(Value::Null)
    } else {
        Value::Null
    };
    set(&mut row, "transcript_after", after);
    set(
        &mut row,
        "terminal_kind",
        if cancel_before_dispatch {
            Value::from("blocked")
        } else {
            Value::Null
        },
    );
    if cancel_before_dispatch {
        reset_batch(&mut row);
    }
    bump_revision(&mut row)?;
    set(&mut row, "updated_at", Value::from(env.now.as_str()));
    let row = Value::Object(row);
    if !round_v3_row(&row, env) {
        return Err(StoreError::Corrupt);
    }
    Ok(Effect {
        commit: true,
        output: round_v3_output(&row, next_state),
        row: Some(row),
        ..Default::default()
    })
}

fn query(args: &Map<String, Value>, view: &View) -> Result<Effect, StoreError> {
    let locator = args.get("locator").unwrap_or(&Value::Null);
    if !round_locator(Some(locator)) {
        return Err(StoreError::InvalidArgument);
    }
    let output = match &view.row {
        Some(row) => round_v3_output(row, as_str(get(row, "state")).unwrap_or_default()),
        None => json!({ "schema_version": 3, "status": "not_started" }),
    };
    Ok(Effect {
        commit: false,
        output,
        ..Default::default()
    })
}

/// Runs one journal operation. `op` is one of `create`, `claim`,
/// `mark_dispatched`, `complete`, `cancel`, `reconcile`, `query`; `args`
/// carries that operation's named arguments.
pub fn reduce(
    op: &str,
    args: &Map<String, Value>,
    env: &Env,
    view: &View,
) -> Result<Effect, StoreError> {
    match op {
        "create" => create(args, env, view),
        "claim" => claim(args, env, view),
        "mark_dispatched" => mark_dispatched(args, env, view),
        "complete" => complete(args, env, view),
        "cancel" => cancel(args, env, view),
        "reconcile" => reconcile(args, env, view),
        "query" => query(args, view),
        _ => Err(StoreError::InvalidArgument),
    }
}

/// JSON envelope for the FFI: `{"op","args","env","view"}` in,
/// `{"ok":true,"commit","output","row","dispatch","transcript"}` or
/// `{"ok":false,"error":<code>}` out. A malformed envelope is a host bug and
/// reports as `Corrupt`.
pub fn reduce_json(input: &str) -> String {
    let result = reduce_json_inner(input);
    let value = match result {
        Ok(effect) => json!({
            "ok": true,
            "commit": effect.commit,
            "output": effect.output,
            "row": effect.row,
            "dispatch": effect.dispatch.map(|d| match d {
                DispatchEffect::InsertNotDispatched => "insert_not_dispatched",
                DispatchEffect::MarkDispatched => "mark_dispatched",
            }),
            "transcript": effect.transcript,
        }),
        Err(error) => json!({ "ok": false, "error": error.code() }),
    };
    value.to_string()
}

fn reduce_json_inner(input: &str) -> Result<Effect, StoreError> {
    let envelope: Value = serde_json::from_str(input).map_err(|_| StoreError::Corrupt)?;
    let op = as_str(get(&envelope, "op")).ok_or(StoreError::Corrupt)?;
    let args = match get(&envelope, "args") {
        Some(Value::Object(map)) => map,
        _ => return Err(StoreError::Corrupt),
    };
    let env_value = get(&envelope, "env").ok_or(StoreError::Corrupt)?;
    let view_value = get(&envelope, "view").ok_or(StoreError::Corrupt)?;
    let string_list = |value: Option<&Value>| -> Vec<String> {
        match value {
            Some(Value::Array(items)) => items
                .iter()
                .filter_map(|item| as_str(Some(item)).map(str::to_owned))
                .collect(),
            _ => Vec::new(),
        }
    };
    let env = Env {
        launch_id: as_str(get(env_value, "launch_id"))
            .ok_or(StoreError::Corrupt)?
            .to_owned(),
        now: as_str(get(env_value, "now"))
            .ok_or(StoreError::Corrupt)?
            .to_owned(),
        round_count: get(env_value, "round_count")
            .and_then(Value::as_u64)
            .ok_or(StoreError::Corrupt)?,
        supported_models: string_list(get(env_value, "supported_models")),
        receipt_harness_id: as_str(get(env_value, "receipt_harness_id")).map(str::to_owned),
        receipt_binding_valid: get(env_value, "receipt_binding_valid") == Some(&Value::Bool(true)),
    };
    let optional = |value: Option<&Value>| -> Option<Value> {
        match value {
            None | Some(Value::Null) => None,
            Some(other) => Some(other.clone()),
        }
    };
    let view = View {
        row: optional(get(view_value, "row")),
        dispatch_state: as_str(get(view_value, "dispatch_state")).map(str::to_owned),
        transcript: optional(get(view_value, "transcript")),
        arg_owner_alive: get(view_value, "arg_owner_alive") == Some(&Value::Bool(true)),
        row_owner_alive: get(view_value, "row_owner_alive") == Some(&Value::Bool(true)),
    };
    reduce(op, args, &env, &view)
}
