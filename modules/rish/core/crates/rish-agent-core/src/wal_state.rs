//! The WAL's stored row shapes, ported from `AgentNativeWAL.mm`. These are
//! the load-time re-validation of `agent-native-wal-v1.json`: every row the
//! store keeps must still hold its shape after a restart, an upgrade, or a
//! partially written file. This first cut covers the bookkeeping rows —
//! transcript references and messages, reservations, cleanup, dispatch
//! markers, the attempt authority, and the operation relation with its
//! result snapshots. The file, the locks and the transaction stay native.

use crate::canonical::{canonical_json, hash_json};
use crate::execution_ledger::{as_str, feedback_string_valid, get, write_prior};
use crate::schema::{
    bounded_utf8, canonical_sha256, canonical_timestamp, canonical_uuid, exact_keys,
    opaque_identifier, root_full, safe_integer, MAX_TRANSCRIPT_BYTES,
};
use crate::session_schema::Env;
use serde_json::{json, Value};

const MAX_SAFE_INTEGER: u64 = 9_007_199_254_740_991;
/// `DSHAgentNativeWALMaxSingleWriteBytes`.
pub const MAX_SINGLE_WRITE_BYTES: u64 = 32 * 1024;
/// `DSHAgentNativeWALMaxBatchWriteBytes`.
pub const MAX_BATCH_WRITE_BYTES: u64 = 512 * 1024;
/// `DSHAgentNativeWALMaxAttemptWriteBytes`.
pub const MAX_ATTEMPT_WRITE_BYTES: u64 = 4 * 1024 * 1024;
/// `DSHAgentNativeWALMaxOperationResultBytes`.
pub const MAX_OPERATION_RESULT_BYTES: u64 = 768 * 1024;

fn equal(left: Option<&Value>, right: Option<&Value>) -> bool {
    matches!((left, right), (Some(l), Some(r)) if l == r)
}

fn string_eq(value: Option<&Value>, expected: &str) -> bool {
    as_str(value) == Some(expected)
}

fn is_null(value: Option<&Value>) -> bool {
    matches!(value, Some(Value::Null))
}

fn array(value: Option<&Value>) -> &[Value] {
    match value {
        Some(Value::Array(items)) => items,
        _ => &[],
    }
}

fn is_boolean(value: Option<&Value>) -> bool {
    matches!(value, Some(Value::Bool(_)))
}

fn u64_of(value: Option<&Value>) -> u64 {
    value.and_then(Value::as_u64).unwrap_or(0)
}

/// `DSHAgentSafeInteger(value, 1, NO)` plus an exact comparison: the row's
/// own schema tag.
fn schema(value: Option<&Value>, expected: u64) -> bool {
    safe_integer(value, expected, false) == Some(expected)
}

/// `DSHAgentWALReferenceShape`.
pub fn reference_shape(value: Option<&Value>) -> bool {
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

/// `DSHAgentWALCanonicalFeedbackString`: the stored tool content must be the
/// canonical encoding of itself.
fn canonical_feedback_string(value: Option<&Value>) -> bool {
    let Some(text) = as_str(value) else {
        return false;
    };
    if text.len() as u64 > MAX_TRANSCRIPT_BYTES {
        return false;
    }
    let Ok(parsed) = serde_json::from_str::<Value>(text) else {
        return false;
    };
    matches!(canonical_json(&parsed), Ok(bytes) if bytes == text.as_bytes())
}

/// `DSHAgentWALOpaqueCallID`: 1..=128 bytes of `[A-Za-z0-9._:-]`.
pub fn opaque_call_id(value: Option<&Value>) -> bool {
    opaque_identifier(value)
}

fn tool_name_charset(value: Option<&Value>) -> bool {
    match bounded_utf8(value, 64, false) {
        Some(text) => text
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-')),
        None => false,
    }
}

/// `DSHAgentWALMessageShape`: one stored transcript message.
pub fn message_shape(message: &Value) -> bool {
    if !message.is_object()
        || !schema(get(message, "schema_version"), 1)
        || safe_integer(get(message, "round_index"), 7, true).is_none()
        || !get(message, "role").is_some_and(Value::is_string)
    {
        return false;
    }
    match as_str(get(message, "role")) {
        Some("assistant") => {
            let calls = array(get(message, "tool_calls"));
            if exact_keys(
                Some(message),
                &[
                    "schema_version",
                    "role",
                    "round_index",
                    "content",
                    "reasoning_content",
                    "tool_calls",
                ],
            )
            .is_none()
                || bounded_utf8(get(message, "content"), MAX_TRANSCRIPT_BYTES as usize, true)
                    .is_none()
                || bounded_utf8(
                    get(message, "reasoning_content"),
                    MAX_TRANSCRIPT_BYTES as usize,
                    true,
                )
                .is_none()
                || !get(message, "tool_calls").is_some_and(Value::is_array)
                || calls.len() > 16
            {
                return false;
            }
            calls.iter().all(|call| {
                exact_keys(
                    Some(call),
                    &["schema_version", "call_id", "name", "arguments_json"],
                )
                .is_some()
                    && schema(get(call, "schema_version"), 1)
                    && opaque_call_id(get(call, "call_id"))
                    && tool_name_charset(get(call, "name"))
                    && as_str(get(call, "arguments_json"))
                        .and_then(crate::strict_json::parse_arguments)
                        .is_some()
            })
        }
        Some("tool") => {
            exact_keys(
                Some(message),
                &[
                    "schema_version",
                    "role",
                    "round_index",
                    "call_id",
                    "content",
                    "truncated",
                ],
            )
            .is_some()
                && opaque_call_id(get(message, "call_id"))
                && bounded_utf8(get(message, "content"), MAX_TRANSCRIPT_BYTES as usize, true)
                    .is_some()
                && canonical_feedback_string(get(message, "content"))
                && as_str(get(message, "content"))
                    .is_some_and(|text| feedback_string_valid(text).is_ok())
                && is_boolean(get(message, "truncated"))
        }
        _ => false,
    }
}

/// `DSHAgentWALReservationShape`: the write reservation and its key ledger.
pub fn reservation_shape(reservation: &Value) -> bool {
    let keys = [
        "schema_version",
        "task_id",
        "attempt_id",
        "root_fingerprint_sha256",
        "binding_revision",
        "policy",
        "reserved_write_bytes",
        "reservation_version",
        "keys",
    ];
    let r = |key: &str| get(reservation, key);
    if exact_keys(Some(reservation), &keys).is_none()
        || !schema(r("schema_version"), 1)
        || !canonical_uuid(r("task_id"))
        || !canonical_uuid(r("attempt_id"))
        || !canonical_sha256(r("root_fingerprint_sha256"))
        || safe_integer(r("binding_revision"), MAX_SAFE_INTEGER, false).is_none()
        || !r("policy").is_some_and(Value::is_object)
        || safe_integer(r("reserved_write_bytes"), MAX_ATTEMPT_WRITE_BYTES, true).is_none()
        || safe_integer(r("reservation_version"), MAX_SAFE_INTEGER, true).is_none()
        || !r("keys").is_some_and(Value::is_array)
        || array(r("keys")).len() > 128
    {
        return false;
    }
    // The reservation carries its own policy copy; it is bounded like the
    // authority's but only requires a non-empty version string.
    let policy = r("policy").expect("checked");
    let p = |key: &str| get(policy, key);
    if exact_keys(
        Some(policy),
        &[
            "schema_version",
            "policy_version",
            "max_single_write_bytes",
            "max_batch_write_bytes",
            "max_attempt_write_bytes",
        ],
    )
    .is_none()
        || !schema(p("schema_version"), 1)
        || bounded_utf8(p("policy_version"), 128, false).is_none()
        || safe_integer(p("max_single_write_bytes"), MAX_SINGLE_WRITE_BYTES, false)
            != Some(MAX_SINGLE_WRITE_BYTES)
        || safe_integer(p("max_batch_write_bytes"), MAX_BATCH_WRITE_BYTES, false).is_none()
        || u64_of(p("max_batch_write_bytes")) < MAX_SINGLE_WRITE_BYTES
        || safe_integer(p("max_attempt_write_bytes"), MAX_ATTEMPT_WRITE_BYTES, false).is_none()
        || u64_of(p("max_attempt_write_bytes")) < u64_of(p("max_batch_write_bytes"))
    {
        return false;
    }
    let mut seen: Vec<&str> = Vec::new();
    let mut active_bytes: u64 = 0;
    for key in array(r("keys")) {
        let k = |name: &str| get(key, name);
        let idempotency = as_str(k("idempotency_key")).unwrap_or_default();
        if exact_keys(
            Some(key),
            &[
                "idempotency_key",
                "relative_path_sha256",
                "content_sha256",
                "content_bytes",
                "state",
            ],
        )
        .is_none()
            || !canonical_sha256(k("idempotency_key"))
            || !canonical_sha256(k("relative_path_sha256"))
            || !canonical_sha256(k("content_sha256"))
            || safe_integer(k("content_bytes"), MAX_SINGLE_WRITE_BYTES, true).is_none()
            || !matches!(as_str(k("state")), Some("active" | "released"))
            || seen.contains(&idempotency)
        {
            return false;
        }
        seen.push(idempotency);
        if string_eq(k("state"), "active") {
            let bytes = u64_of(k("content_bytes"));
            if active_bytes > MAX_ATTEMPT_WRITE_BYTES - bytes {
                return false;
            }
            active_bytes += bytes;
        }
    }
    active_bytes == u64_of(r("reserved_write_bytes"))
}

/// `DSHAgentWALCleanupShape`.
pub fn cleanup_shape(cleanup: &Value) -> bool {
    let keys = [
        "schema_version",
        "cleanup_id",
        "attempt_id",
        "transcript_ref",
        "transcript_sha256",
        "cleanup_owner",
        "reason",
        "created_at",
        "status",
    ];
    let c = |key: &str| get(cleanup, key);
    exact_keys(Some(cleanup), &keys).is_some()
        && schema(c("schema_version"), 1)
        && canonical_uuid(c("cleanup_id"))
        && canonical_uuid(c("attempt_id"))
        && canonical_uuid(c("transcript_ref"))
        && canonical_sha256(c("transcript_sha256"))
        && canonical_uuid(c("cleanup_owner"))
        && canonical_timestamp(c("created_at"))
        && matches!(
            as_str(c("reason")),
            Some("completed" | "cancelled" | "failed" | "conversation_deleted")
        )
        && matches!(as_str(c("status")), Some("pending" | "discarded"))
}

/// `DSHAgentWALDispatchShape`: the round or execution dispatch marker.
pub fn dispatch_shape(dispatch: &Value) -> bool {
    let d = |key: &str| get(dispatch, key);
    if exact_keys(
        Some(dispatch),
        &["schema_version", "kind", "locator", "dispatch_state"],
    )
    .is_none()
        || !schema(d("schema_version"), 1)
        || !matches!(as_str(d("kind")), Some("round" | "execution"))
        || !d("locator").is_some_and(Value::is_object)
        || !matches!(
            as_str(d("dispatch_state")),
            Some("not_dispatched" | "dispatched")
        )
    {
        return false;
    }
    let locator = d("locator").expect("checked");
    let l = |key: &str| get(locator, key);
    if string_eq(d("kind"), "round") {
        return exact_keys(
            Some(locator),
            &[
                "schema_version",
                "task_id",
                "attempt_id",
                "round_id",
                "round_index",
            ],
        )
        .is_some()
            && l("schema_version") == Some(&json!(1))
            && canonical_uuid(l("task_id"))
            && canonical_uuid(l("attempt_id"))
            && canonical_uuid(l("round_id"))
            && safe_integer(l("round_index"), 7, true).is_some();
    }
    let keys = [
        "schema_version",
        "task_id",
        "attempt_id",
        "round_id",
        "round_index",
        "call_index",
        "call_id",
        "idempotency_key",
    ];
    exact_keys(Some(locator), &keys).is_some()
        && l("schema_version") == Some(&json!(2))
        && canonical_uuid(l("task_id"))
        && canonical_uuid(l("attempt_id"))
        && canonical_uuid(l("round_id"))
        && safe_integer(l("round_index"), 7, true).is_some()
        && safe_integer(l("call_index"), 15, true).is_some()
        && bounded_utf8(l("call_id"), 128, false).is_some()
        && canonical_sha256(l("idempotency_key"))
}

/// `DSHAgentWALWritePriorShape`.
pub fn write_prior_shape(prior: Option<&Value>) -> bool {
    write_prior(prior)
}

/// `DSHAgentWALPolicyShape`: the authority's frozen policy.
pub fn policy_shape(policy: Option<&Value>) -> bool {
    let p = |key: &str| policy.and_then(|p| get(p, key));
    exact_keys(
        policy,
        &[
            "schema_version",
            "policy_version",
            "max_single_write_bytes",
            "max_batch_write_bytes",
            "max_attempt_write_bytes",
        ],
    )
    .is_some()
        && p("schema_version") == Some(&json!(1))
        && string_eq(p("policy_version"), "agent-v1")
        && p("max_single_write_bytes") == Some(&json!(MAX_SINGLE_WRITE_BYTES))
        && safe_integer(p("max_batch_write_bytes"), MAX_BATCH_WRITE_BYTES, false).is_some()
        && u64_of(p("max_batch_write_bytes")) >= MAX_SINGLE_WRITE_BYTES
        && safe_integer(p("max_attempt_write_bytes"), MAX_ATTEMPT_WRITE_BYTES, false).is_some()
        && u64_of(p("max_attempt_write_bytes")) >= u64_of(p("max_batch_write_bytes"))
}

/// `DSHAgentWALRegistryShape`: the frozen tool registry, names in ascending
/// literal order.
pub fn registry_shape(registry: Option<&Value>) -> bool {
    let r = |key: &str| registry.and_then(|r| get(r, key));
    if exact_keys(
        registry,
        &[
            "schema_version",
            "registry_version",
            "toolset_sha256",
            "tools",
        ],
    )
    .is_none()
        || r("schema_version") != Some(&json!(2))
        || !crate::runtime_tools::registry_version(r("registry_version"))
        || !canonical_sha256(r("toolset_sha256"))
        || !r("tools").is_some_and(Value::is_array)
        || array(r("tools")).len()
            > if r("registry_version") == Some(&json!(5)) {
                20
            } else if r("registry_version") == Some(&json!(4)) {
                14
            } else if r("registry_version") == Some(&json!(3)) {
                13
            } else {
                8
            }
    {
        return false;
    }
    const NAMES: &[&str] = &[
        "ask_user",
        "list_dir",
        "read_file",
        "write_file",
        "git_status",
        "git_commit",
        "git_push",
        "start_guest_cgi",
        "stop_guest_cgi",
        "list_runtime_environments",
        "install_runtime_environment",
        "run_program",
        "start_runtime_service",
        "stop_runtime_service",
        "list_assistant_tasks",
        "create_assistant_task",
        "update_assistant_task",
        "search_assistant_memory",
        "remember_assistant_memory",
        "forget_assistant_memory",
    ];
    let mut seen: Vec<&str> = Vec::new();
    let mut previous: Option<&str> = None;
    for tool in array(r("tools")) {
        let name = as_str(get(tool, "name")).unwrap_or_default();
        if exact_keys(
            Some(tool),
            &["schema_version", "name", "safe_summary_key", "access"],
        )
        .is_none()
            || get(tool, "schema_version") != Some(&json!(2))
            || !NAMES.contains(&name)
            || (crate::runtime_tools::is_runtime(name)
                && !matches!(r("registry_version").and_then(Value::as_u64), Some(3..=5)))
            || (name == "ask_user"
                && !matches!(r("registry_version").and_then(Value::as_u64), Some(4 | 5)))
            || (crate::assistant_tools::is_assistant(name)
                && r("registry_version") != Some(&json!(5)))
            || (crate::assistant_tools::is_assistant(name)
                && (get(tool, "safe_summary_key") != Some(&json!(format!("agent.{name}")))
                    || as_str(get(tool, "access"))
                        != Some(if crate::assistant_tools::is_mutation(name) {
                            "conversation_confirm"
                        } else {
                            "auto"
                        })))
            || seen.contains(&name)
            || bounded_utf8(get(tool, "safe_summary_key"), 128, false).is_none()
            || !matches!(
                as_str(get(tool, "access")),
                Some("auto" | "conversation_confirm" | "confirm_once" | "durable_deny")
            )
            || previous.is_some_and(|previous| previous >= name)
        {
            return false;
        }
        previous = Some(name);
        seen.push(name);
    }
    true
}

/// `DSHAgentWALAuthorityShape`: the attempt authority, including the exact
/// tool set its root capabilities imply.
pub fn authority_shape(authority: &Value, env: &Env) -> bool {
    let mut keys = vec![
        "schema_version",
        "task_id",
        "conversation_id",
        "attempt_id",
        "root",
        "policy",
        "registry",
        "transport_schema_version",
        "model",
        "thinking_mode",
        "visible_message_ids",
        "visible_history_sha256",
        "visible_message_count",
        "project_context_sha256",
        "transcript",
        "reserved_write_bytes",
        "authority_revision",
        "state",
        "cleanup_id",
        "created_at",
        "updated_at",
    ];
    if authority["registry"]["registry_version"] == 5 {
        keys.push("assistant_context");
    }
    if !crate::assistant_context::authority_valid(authority) {
        return false;
    }
    let a = |key: &str| get(authority, key);
    let visible = array(a("visible_message_ids"));
    if exact_keys(Some(authority), &keys).is_none()
        || a("schema_version") != Some(&json!(2))
        || !canonical_uuid(a("task_id"))
        || !canonical_uuid(a("conversation_id"))
        || !canonical_uuid(a("attempt_id"))
        || !root_full(a("root"))
        || !policy_shape(a("policy"))
        || !registry_shape(a("registry"))
        || !(a("transport_schema_version") == Some(&json!(2))
            || a("transport_schema_version") == Some(&json!(3)))
        || bounded_utf8(a("model"), 128, false).is_none()
        || bounded_utf8(a("thinking_mode"), 32, false).is_none()
        || !a("visible_message_ids").is_some_and(Value::is_array)
        || visible.len() > 96
        || !canonical_sha256(a("visible_history_sha256"))
        || safe_integer(a("visible_message_count"), 96, true).is_none()
        || visible.len() as u64 != u64_of(a("visible_message_count"))
        || !(is_null(a("project_context_sha256")) || canonical_sha256(a("project_context_sha256")))
        || !reference_shape(a("transcript"))
        || safe_integer(a("reserved_write_bytes"), MAX_ATTEMPT_WRITE_BYTES, true).is_none()
        || safe_integer(a("authority_revision"), MAX_SAFE_INTEGER, false).is_none()
        || !canonical_timestamp(a("created_at"))
        || !canonical_timestamp(a("updated_at"))
        || !env.supported_model(a("model"))
        || !matches!(as_str(a("thinking_mode")), Some("off" | "high" | "max"))
    {
        return false;
    }
    let root = a("root").expect("checked");
    let project = string_eq(get(root, "kind"), "project");
    let registry = a("registry").expect("checked");
    if matches!(
        get(registry, "registry_version").and_then(Value::as_u64),
        Some(4 | 5)
    ) {
        // V4 freezes whether this host offers runtime/guest tools in its table
        // digest. Android's no-runtime identity is as valid as iOS's full one.
        if ![false, true]
            .into_iter()
            .any(|guest| crate::tool_registry::registry_shape(registry, root, guest))
        {
            return false;
        }
    } else {
        let capabilities: Vec<&str> = array(get(root, "capabilities"))
            .iter()
            .filter_map(|c| as_str(Some(c)))
            .collect();
        let has = |name: &str| capabilities.contains(&name);
        let runtime_registry =
            get(a("registry").expect("checked"), "registry_version") == Some(&json!(3));
        let mut expected: Vec<(&str, &str)> = Vec::new();
        if has("file_read") {
            expected.push(("list_dir", "auto"));
            expected.push(("read_file", "auto"));
            if runtime_registry {
                expected.push(("list_runtime_environments", "auto"));
            }
        }
        if has("file_write") {
            expected.push(("write_file", "conversation_confirm"));
        }
        if project && has("git_status") {
            expected.push(("git_status", "auto"));
        }
        if project && has("git_commit") {
            expected.push(("git_commit", "conversation_confirm"));
        }
        if project && has("git_push") {
            // git_push follows the git_commit pattern (see AgentToolRegistry).
            expected.push(("git_push", "conversation_confirm"));
        }
        if has("guest_service") {
            if !runtime_registry
                && get(a("registry").expect("checked"), "registry_version") != Some(&json!(2))
            {
                return false;
            }
            expected.push(("start_guest_cgi", "conversation_confirm"));
            expected.push(("stop_guest_cgi", "conversation_confirm"));
            if runtime_registry {
                expected.extend(
                    crate::runtime_tools::MUTATIONS
                        .iter()
                        .map(|name| (*name, "conversation_confirm")),
                );
            }
        }
        let tools = array(get(a("registry").expect("checked"), "tools"));
        if expected.len() != tools.len() {
            return false;
        }
        for tool in tools {
            let name = as_str(get(tool, "name")).unwrap_or_default();
            let access = as_str(get(tool, "access")).unwrap_or_default();
            if expected.iter().any(|(n, a)| *n == name && *a == access) {
                continue;
            }
            // Authorities prepared by builds that registered git_push as once-only
            // stay readable; the pulled device evidence fixtures carry that shape.
            if name == "git_push" && access == "confirm_once" {
                continue;
            }
            return false;
        }
    }
    if a("transport_schema_version") == Some(&json!(3)) {
        if !project
            || is_null(get(root, "project_id"))
            || !canonical_sha256(a("project_context_sha256"))
        {
            return false;
        }
    } else if !is_null(a("project_context_sha256")) {
        return false;
    }
    let mut ids: Vec<&str> = Vec::new();
    for id in visible {
        let text = as_str(Some(id)).unwrap_or_default();
        if !canonical_uuid(Some(id)) || ids.contains(&text) {
            return false;
        }
        ids.push(text);
    }
    match as_str(a("state")) {
        Some("prepared" | "terminal") if is_null(a("cleanup_id")) => true,
        Some("cleanup_pending") => canonical_uuid(a("cleanup_id")),
        _ => false,
    }
}

// MARK: - operations

/// `DSHAgentWALOperationKinds`.
pub const OPERATION_KINDS: &[&str] = &[
    "prepare_agent_attempt",
    "complete_agent_round_v2",
    "prepare_agent_tool_batch",
    "bind_agent_approval",
    "execute_agent_tool",
    "cancel_agent_attempt",
    "recover_agent_attempt",
    "finalize_agent_attempt",
    "discard_agent_attempt",
    "interrupt_agent_attempt",
];

/// `DSHAgentWALOperationResultStatuses`.
const RESULT_STATUSES: &[&str] = &[
    "prepared",
    "already_prepared",
    "not_agent",
    "completed",
    "in_flight",
    "failed_retryable",
    "failed",
    "cancel_requested",
    "cancelled",
    "unknown",
    "ambiguous",
    "rejected",
    "bound",
    "already_bound",
    "running",
    "denied",
    "retryable",
    "resumed",
    "manual_reconciliation",
    "terminal",
    "discarded",
    "already_missing",
    "pending",
    "conflict",
];

/// `DSHAgentWALKnownOperationResultStatus`: the closed set, plus the two
/// statuses that belong to exactly one operation kind.
pub fn known_result_status(status: Option<&Value>) -> bool {
    matches!(
        status.and_then(Value::as_str),
        Some("settled" | "already_terminal")
    ) || status
        .and_then(Value::as_str)
        .is_some_and(|status| RESULT_STATUSES.contains(&status))
}

/// `DSHAgentWALOperationResultStatusAllowed`: two statuses belong to exactly
/// one operation kind.
pub fn result_status_allowed(operation_kind: Option<&str>, status: Option<&str>) -> bool {
    match status {
        Some("settled") => operation_kind == Some("cancel_agent_attempt"),
        Some("already_terminal") => operation_kind == Some("finalize_agent_attempt"),
        Some(status) => RESULT_STATUSES.contains(&status),
        None => false,
    }
}

/// `DSHAgentWALResultReferenceShape`: what an operation's result points at.
pub fn result_reference_shape(reference: Option<&Value>) -> bool {
    let Some(reference) = reference.filter(|r| r.is_object()) else {
        return false;
    };
    let r = |key: &str| get(reference, key);
    if r("schema_version") != Some(&json!(2)) || !r("kind").is_some_and(Value::is_string) {
        return false;
    }
    let kind = as_str(r("kind")).unwrap_or_default();
    if kind == "none" {
        return exact_keys(Some(reference), &["schema_version", "kind"]).is_some();
    }
    if kind == "cleanup" {
        return exact_keys(Some(reference), &["schema_version", "kind", "cleanup_id"]).is_some()
            && canonical_uuid(r("cleanup_id"));
    }
    let mut keys = vec!["schema_version", "kind", "task_id", "attempt_id"];
    if !canonical_uuid(r("task_id")) || !canonical_uuid(r("attempt_id")) {
        return false;
    }
    if kind == "authority" {
        keys.push("authority_revision");
        return exact_keys(Some(reference), &keys).is_some()
            && safe_integer(r("authority_revision"), MAX_SAFE_INTEGER, false).is_some();
    }
    keys.push("round_id");
    keys.push("round_index");
    if !canonical_uuid(r("round_id")) || safe_integer(r("round_index"), 7, true).is_none() {
        return false;
    }
    if kind == "round" || kind == "batch" {
        let revision = if kind == "round" {
            "round_revision"
        } else {
            "batch_revision"
        };
        keys.push(revision);
        return exact_keys(Some(reference), &keys).is_some()
            && safe_integer(r(revision), MAX_SAFE_INTEGER, false).is_some();
    }
    if !matches!(kind, "approval" | "tool" | "denied_call") {
        return false;
    }
    keys.push("call_index");
    keys.push("call_id");
    if safe_integer(r("call_index"), 15, true).is_none() || !opaque_call_id(r("call_id")) {
        return false;
    }
    let revision = match kind {
        "approval" => "batch_revision",
        "tool" => "execution_revision",
        _ => "native_row_revision",
    };
    keys.push(revision);
    exact_keys(Some(reference), &keys).is_some()
        && safe_integer(r(revision), MAX_SAFE_INTEGER, false).is_some()
}

/// `DSHAgentWALSnapshotReferenceShape`.
pub fn snapshot_reference_shape(reference: Option<&Value>) -> bool {
    let r = |key: &str| reference.and_then(|r| get(r, key));
    exact_keys(
        reference,
        &[
            "schema_version",
            "operation_id",
            "result_sha256",
            "result_bytes",
        ],
    )
    .is_some()
        && r("schema_version") == Some(&json!(2))
        && canonical_uuid(r("operation_id"))
        && canonical_sha256(r("result_sha256"))
        && safe_integer(r("result_bytes"), MAX_OPERATION_RESULT_BYTES, false).is_some()
}

/// `DSHAgentWALContainsForbiddenSafeKey`: a published result must never
/// carry raw arguments, content, paths or native envelopes.
pub fn contains_forbidden_safe_key(value: &Value) -> bool {
    const FORBIDDEN: &[&str] = &[
        "arguments",
        "content",
        "path",
        "raw_arguments",
        "raw_result",
        "tool_feedback",
        "messages",
        "native_envelope",
        "precondition",
        "settled_facts",
        "patch",
        "owner",
        "arguments_json",
    ];
    match value {
        Value::Object(map) => map.iter().any(|(key, child)| {
            FORBIDDEN.contains(&key.as_str()) || contains_forbidden_safe_key(child)
        }),
        Value::Array(items) => items.iter().any(contains_forbidden_safe_key),
        _ => false,
    }
}

/// `DSHAgentWALSafeResultShape`.
pub fn safe_result_shape(
    safe_result: Option<&Value>,
    operation_kind: Option<&Value>,
    operation_id: Option<&Value>,
    result_status: Option<&Value>,
) -> bool {
    let Some(safe_result) = safe_result.filter(|s| s.is_object()) else {
        return false;
    };
    if exact_keys(
        Some(safe_result),
        &["schema_version", "result_kind", "result"],
    )
    .is_none()
        || get(safe_result, "schema_version") != Some(&json!(2))
        || !equal(get(safe_result, "result_kind"), operation_kind)
        || !get(safe_result, "result").is_some_and(Value::is_object)
        || contains_forbidden_safe_key(safe_result)
    {
        return false;
    }
    let result = get(safe_result, "result").expect("checked");
    get(result, "schema_version") == Some(&json!(2))
        && equal(get(result, "operation_id"), operation_id)
        && equal(get(result, "status"), result_status)
        && canonical_uuid(get(result, "operation_id"))
}

/// `DSHAgentWALOperationShape`: the operation relation row and the state
/// machine its result reference must agree with.
pub fn operation_shape(operation: &Value) -> bool {
    let keys = [
        "schema_version",
        "operation_id",
        "operation_kind",
        "request_sha256",
        "task_id",
        "attempt_id",
        "result_ref",
        "state",
        "result_status",
        "result_revision",
        "result_snapshot_ref",
        "authority_revision",
        "created_at",
        "updated_at",
    ];
    let o = |key: &str| get(operation, key);
    if exact_keys(Some(operation), &keys).is_none()
        || o("schema_version") != Some(&json!(2))
        || !canonical_uuid(o("operation_id"))
        || !as_str(o("operation_kind")).is_some_and(|kind| OPERATION_KINDS.contains(&kind))
        || !canonical_sha256(o("request_sha256"))
        || !canonical_uuid(o("task_id"))
        || !canonical_uuid(o("attempt_id"))
        || !result_reference_shape(o("result_ref"))
        || !result_status_allowed(as_str(o("operation_kind")), as_str(o("result_status")))
        || !(is_null(o("result_revision"))
            || safe_integer(o("result_revision"), MAX_SAFE_INTEGER, false).is_some())
        || !(is_null(o("result_snapshot_ref"))
            || snapshot_reference_shape(o("result_snapshot_ref")))
        || safe_integer(o("authority_revision"), MAX_SAFE_INTEGER, true).is_none()
        || !canonical_timestamp(o("created_at"))
        || !canonical_timestamp(o("updated_at"))
    {
        return false;
    }
    let result_ref = o("result_ref").expect("checked");
    if get(result_ref, "task_id").is_some()
        && (!equal(get(result_ref, "task_id"), o("task_id"))
            || !equal(get(result_ref, "attempt_id"), o("attempt_id")))
    {
        return false;
    }
    if !is_null(o("result_snapshot_ref"))
        && !equal(
            o("result_snapshot_ref").and_then(|s| get(s, "operation_id")),
            o("operation_id"),
        )
    {
        return false;
    }
    let none = string_eq(get(result_ref, "kind"), "none");
    let null_revision = is_null(o("result_revision"));
    let null_snapshot = is_null(o("result_snapshot_ref"));
    match as_str(o("state")) {
        Some("started") => {
            none && null_revision && null_snapshot && string_eq(o("result_status"), "pending")
        }
        Some("committed") => !none && !null_revision && !null_snapshot,
        Some("rejected" | "conflict") => none && null_revision && !null_snapshot,
        Some("unknown" | "ambiguous") => (none == null_revision) && !null_snapshot,
        _ => false,
    }
}

/// `DSHAgentWALOperationResultShape`: the stored result snapshot, including
/// its own byte length and domain-separated digest.
pub fn operation_result_shape(snapshot: &Value) -> bool {
    let keys = [
        "schema_version",
        "operation_id",
        "operation_kind",
        "result_status",
        "result_sha256",
        "result_bytes",
        "result",
        "created_at",
    ];
    let s = |key: &str| get(snapshot, key);
    if exact_keys(Some(snapshot), &keys).is_none()
        || s("schema_version") != Some(&json!(2))
        || !canonical_uuid(s("operation_id"))
        || !as_str(s("operation_kind")).is_some_and(|kind| OPERATION_KINDS.contains(&kind))
        || !result_status_allowed(as_str(s("operation_kind")), as_str(s("result_status")))
        || !canonical_sha256(s("result_sha256"))
        || safe_integer(s("result_bytes"), MAX_OPERATION_RESULT_BYTES, false).is_none()
        || !canonical_timestamp(s("created_at"))
        || !safe_result_shape(
            s("result"),
            s("operation_kind"),
            s("operation_id"),
            s("result_status"),
        )
    {
        return false;
    }
    let Ok(bytes) = canonical_json(s("result").expect("checked")) else {
        return false;
    };
    let digest = hash_json(
        "agent-operation-result",
        &json!({ "operation_kind": s("operation_kind"), "result_status": s("result_status"), "result": s("result") }),
    );
    !bytes.is_empty()
        && bytes.len() as u64 <= MAX_OPERATION_RESULT_BYTES
        && u64_of(s("result_bytes")) == bytes.len() as u64
        && as_str(s("result_sha256")) == digest.as_deref()
}

// MARK: - JSON envelope

/// `{"op","value",...}` in; `{"ok":true,...}` or `{"ok":false,"error":<code>}` out.
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

fn reduce_json_inner(input: &str) -> Result<Value, crate::store::StoreError> {
    use crate::store::StoreError;
    let envelope: Value = serde_json::from_str(input).map_err(|_| StoreError::Corrupt)?;
    let op = as_str(get(&envelope, "op")).ok_or(StoreError::Corrupt)?;
    let value = get(&envelope, "value").ok_or(StoreError::InvalidArgument)?;
    if let Some(result) = crate::assistant_tools::reduce_contract(op, value, get(&envelope, "name"))
    {
        return Ok(result);
    }
    if let Some(result) = crate::runtime_tools::reduce_contract(op, value, get(&envelope, "name")) {
        return Ok(result);
    }
    // What a tool is allowed to report. The rule is `feedback_string_valid`,
    // which the ledger already applies to every stored row; this op is how a
    // host reaches it, so an executor and a stored row cannot disagree about
    // what a result may say. It answers through the error code rather than a
    // `valid` flag because an oversized report is a capacity refusal, which a
    // caller recovers from differently than a malformed one.
    if op == "tool_feedback" {
        let text = value.as_str().ok_or(StoreError::InvalidArgument)?;
        crate::execution_ledger::feedback_string_valid(text)?;
        return Ok(json!({ "valid": true }));
    }
    let valid = match op {
        "question_arguments" => crate::user_question::arguments_valid(value),
        "question_precondition" => crate::user_question::question_shape(Some(value)),
        "question_facts" => crate::user_question::facts_shape(Some(value)),
        "reference" => reference_shape(Some(value)),
        "root" => root_full(Some(value)),
        "message" => message_shape(value),
        "reservation" => reservation_shape(value),
        "cleanup" => cleanup_shape(value),
        "dispatch" => dispatch_shape(value),
        "write_prior" => write_prior_shape(Some(value)),
        "policy" => policy_shape(Some(value)),
        "registry" => registry_shape(Some(value)),
        "authority" => authority_shape(
            value,
            &crate::session_schema::env_from_json(get(&envelope, "env")),
        ),
        "result_reference" => result_reference_shape(Some(value)),
        "snapshot_reference" => snapshot_reference_shape(Some(value)),
        "operation" => operation_shape(value),
        "operation_result" => operation_result_shape(value),
        "opaque_call_id" => opaque_call_id(Some(value)),
        "batch_v1" => batch_shape_v1(value),
        "batch_v2" => batch_shape_v2(value),
        "tool_receipt" => tool_receipt_shape(Some(value)),
        "denied_call" => denied_call_shape(value),
        "round_v3_valid" => {
            // A V3 projection proves its conversion shape only. Persistent
            // readers need the complete journal invariant, including the
            // host's model membership and captured provider binding verdict.
            let supplied = get(&envelope, "env")
                .filter(|env| env.is_object())
                .ok_or(StoreError::InvalidArgument)?;
            let env = crate::round_journal::Env {
                supported_models: crate::session_schema::env_from_json(Some(supplied))
                    .supported_models,
                receipt_harness_id: as_str(get(supplied, "receipt_harness_id")).map(str::to_owned),
                receipt_binding_valid: get(supplied, "receipt_binding_valid")
                    == Some(&Value::Bool(true)),
                ..Default::default()
            };
            crate::round_journal::round_v3_row(value, &env)
        }
        "round_v3" => {
            // The caller still puts the returned schema-2 projection through
            // the round journal's own V2 entry validator.
            return Ok(match round_v3_projection(value) {
                Some(v2) => json!({ "valid": true, "v2": v2 }),
                None => json!({ "valid": false, "v2": Value::Null }),
            });
        }
        "migrate_round" => {
            return Ok(match migrate_round_v2_to_v3(value) {
                Some((row, v2)) => json!({ "valid": true, "row": row, "v2": v2 }),
                None => json!({ "valid": false, "row": Value::Null, "v2": Value::Null }),
            });
        }
        "migrate_batch" => {
            return Ok(match migrate_batch_v1_to_v2(value) {
                Some(batch) => json!({ "valid": true, "batch": batch }),
                None => json!({ "valid": false, "batch": Value::Null }),
            });
        }
        "state_basic" => {
            let env = crate::session_schema::env_from_json(get(&envelope, "env"));
            let flags = |key: &str| {
                get(&envelope, "env")
                    .and_then(|env| get(env, key))
                    .map(|value| {
                        array(Some(value))
                            .iter()
                            .map(|flag| flag == &json!(true))
                            .collect()
                    })
                    .unwrap_or_default()
            };
            let round_valid: Vec<bool> = flags("round_valid");
            let ledger_valid: Vec<bool> = flags("ledger_valid");
            return Ok(
                match state_basic_validation(value, &env, &round_valid, &ledger_valid) {
                    StateVerdict::Valid => json!({ "valid": true }),
                    StateVerdict::Corrupt => json!({ "valid": false, "error_kind": "corrupt" }),
                    StateVerdict::Capacity => json!({ "valid": false, "error_kind": "capacity" }),
                    StateVerdict::Ledger(index) => {
                        json!({ "valid": false, "error_kind": "ledger", "index": index })
                    }
                },
            );
        }
        _ => return Err(StoreError::InvalidArgument),
    };
    Ok(json!({ "valid": valid }))
}

// MARK: - batches, receipts, denied calls and rounds

const KNOWN_TOOL_NAMES: &[&str] = &[
    "ask_user",
    "list_dir",
    "read_file",
    "write_file",
    "git_status",
    "git_commit",
    "git_push",
    "start_guest_cgi",
    "stop_guest_cgi",
    "list_runtime_environments",
    "install_runtime_environment",
    "run_program",
    "start_runtime_service",
    "stop_runtime_service",
    "list_assistant_tasks",
    "create_assistant_task",
    "update_assistant_task",
    "search_assistant_memory",
    "remember_assistant_memory",
    "forget_assistant_memory",
];

/// `DSHAgentCanonicalIdentityKey`: the canonical bytes of a locator, used to
/// prove two manifest calls are not the same call.
fn identity_key(value: &Value) -> Option<Vec<u8>> {
    canonical_json(value).ok()
}

fn manifest_locator_shape(locator: Option<&Value>) -> bool {
    let keys = [
        "schema_version",
        "task_id",
        "attempt_id",
        "round_id",
        "round_index",
        "call_index",
        "call_id",
        "idempotency_key",
    ];
    let l = |key: &str| locator.and_then(|l| get(l, key));
    exact_keys(locator, &keys).is_some()
        && l("schema_version") == Some(&json!(2))
        && canonical_uuid(l("task_id"))
        && canonical_uuid(l("attempt_id"))
        && canonical_uuid(l("round_id"))
        && safe_integer(l("round_index"), 7, true).is_some()
        && safe_integer(l("call_index"), 15, true).is_some()
        && opaque_call_id(l("call_id"))
        && canonical_sha256(l("idempotency_key"))
}

/// `DSHAgentWALBatchShapeV1`: the pre-schema-2 write batch still readable on
/// disk. Its manifest is one ascending run of write_file calls in a single
/// round, and `write_keys` is exactly their idempotency keys in order.
pub fn batch_shape_v1(batch: &Value) -> bool {
    let keys = [
        "schema_version",
        "task_id",
        "attempt_id",
        "root_fingerprint_sha256",
        "binding_revision",
        "manifest_sha256",
        "manifest_calls",
        "write_keys",
        "reserved_write_bytes",
        "reservation_delta_bytes",
        "attempt_reserved_write_bytes",
        "reservation_version",
        "effect_gate",
        "created_at",
        "updated_at",
    ];
    let b = |key: &str| get(batch, key);
    let calls = array(b("manifest_calls"));
    if exact_keys(Some(batch), &keys).is_none()
        || !schema(b("schema_version"), 1)
        || !canonical_uuid(b("task_id"))
        || !canonical_uuid(b("attempt_id"))
        || !canonical_sha256(b("root_fingerprint_sha256"))
        || safe_integer(b("binding_revision"), MAX_SAFE_INTEGER, false).is_none()
        || !canonical_sha256(b("manifest_sha256"))
        || !b("manifest_calls").is_some_and(Value::is_array)
        || calls.is_empty()
        || calls.len() > 16
        || !b("write_keys").is_some_and(Value::is_array)
        || array(b("write_keys")).len() > 16
        || safe_integer(b("reserved_write_bytes"), MAX_ATTEMPT_WRITE_BYTES, true).is_none()
        || safe_integer(b("reservation_delta_bytes"), MAX_BATCH_WRITE_BYTES, true).is_none()
        || safe_integer(
            b("attempt_reserved_write_bytes"),
            MAX_ATTEMPT_WRITE_BYTES,
            true,
        )
        .is_none()
        || safe_integer(b("reservation_version"), MAX_SAFE_INTEGER, false).is_none()
        || u64_of(b("reserved_write_bytes")) > u64_of(b("attempt_reserved_write_bytes"))
        || u64_of(b("reservation_delta_bytes")) > u64_of(b("attempt_reserved_write_bytes"))
        || !matches!(
            as_str(b("effect_gate")),
            Some("closed" | "open" | "settled" | "released")
        )
        || !canonical_timestamp(b("created_at"))
        || !canonical_timestamp(b("updated_at"))
    {
        return false;
    }
    let mut seen_keys: Vec<&str> = Vec::new();
    for key in array(b("write_keys")) {
        let text = as_str(Some(key)).unwrap_or_default();
        if !canonical_sha256(Some(key)) || seen_keys.contains(&text) {
            return false;
        }
        seen_keys.push(text);
    }
    let mut manifest_keys: Vec<Value> = Vec::with_capacity(calls.len());
    let mut locators: Vec<Vec<u8>> = Vec::with_capacity(calls.len());
    let mut previous_index: Option<u64> = None;
    let mut round_id: Option<&Value> = None;
    let mut round_index: Option<&Value> = None;
    for call in calls {
        let locator = get(call, "locator");
        if exact_keys(
            Some(call),
            &[
                "locator",
                "relative_path_sha256",
                "prior",
                "content_sha256",
                "content_bytes",
            ],
        )
        .is_none()
            || !manifest_locator_shape(locator)
            || !equal(locator.and_then(|l| get(l, "task_id")), b("task_id"))
            || !equal(locator.and_then(|l| get(l, "attempt_id")), b("attempt_id"))
            || !canonical_sha256(get(call, "relative_path_sha256"))
            || !canonical_sha256(get(call, "content_sha256"))
            || safe_integer(get(call, "content_bytes"), MAX_SINGLE_WRITE_BYTES, true).is_none()
            || !write_prior_shape(get(call, "prior"))
        {
            return false;
        }
        let locator = locator.expect("checked");
        let Some(key) = identity_key(locator) else {
            return false;
        };
        if locators.contains(&key) {
            return false;
        }
        let call_index = u64_of(get(locator, "call_index"));
        if previous_index.is_some_and(|previous| call_index <= previous)
            || round_id.is_some_and(|id| Some(id) != get(locator, "round_id"))
            || round_index.is_some_and(|index| Some(index) != get(locator, "round_index"))
        {
            return false;
        }
        previous_index = Some(call_index);
        round_id = get(locator, "round_id");
        round_index = get(locator, "round_index");
        locators.push(key);
        manifest_keys.push(
            get(locator, "idempotency_key")
                .cloned()
                .unwrap_or(Value::Null),
        );
    }
    let manifest = hash_json("write-manifest", &json!({ "calls": b("manifest_calls") }));
    as_str(b("manifest_sha256")) == manifest.as_deref()
        && b("write_keys") == Some(&Value::Array(manifest_keys))
}

/// `DSHAgentWALManifestCallShapeV2`.
fn manifest_call_shape_v2(
    call: &Value,
    batch: &Value,
    locators: &mut Vec<Vec<u8>>,
    previous_index: &mut Option<u64>,
) -> bool {
    let locator = get(call, "locator");
    let l = |key: &str| locator.and_then(|l| get(l, key));
    if !call.is_object()
        || get(call, "schema_version") != Some(&json!(2))
        || !get(call, "mutation_kind").is_some_and(Value::is_string)
        || !manifest_locator_shape(locator)
        || !equal(l("task_id"), get(batch, "task_id"))
        || !equal(l("attempt_id"), get(batch, "attempt_id"))
        || !equal(l("round_id"), get(batch, "round_id"))
        || !equal(l("round_index"), get(batch, "round_index"))
        || !canonical_sha256(get(call, "precondition_sha256"))
    {
        return false;
    }
    match as_str(get(call, "mutation_kind")) {
        Some("file_write") => {
            let keys = [
                "schema_version",
                "mutation_kind",
                "locator",
                "precondition_sha256",
                "relative_path_sha256",
                "prior",
                "content_sha256",
                "content_bytes",
            ];
            if exact_keys(Some(call), &keys).is_none()
                || !canonical_sha256(get(call, "relative_path_sha256"))
                || !write_prior_shape(get(call, "prior"))
                || !canonical_sha256(get(call, "content_sha256"))
                || safe_integer(get(call, "content_bytes"), MAX_SINGLE_WRITE_BYTES, true).is_none()
            {
                return false;
            }
        }
        Some(
            "git_commit"
            | "git_push"
            | "start_guest_cgi"
            | "stop_guest_cgi"
            | "install_runtime_environment"
            | "run_program"
            | "start_runtime_service"
            | "stop_runtime_service"
            | "create_assistant_task"
            | "update_assistant_task"
            | "remember_assistant_memory"
            | "forget_assistant_memory",
        ) => {
            if exact_keys(
                Some(call),
                &[
                    "schema_version",
                    "mutation_kind",
                    "locator",
                    "precondition_sha256",
                    "content_bytes",
                ],
            )
            .is_none()
                || get(call, "content_bytes") != Some(&json!(0))
            {
                return false;
            }
        }
        _ => return false,
    }
    let Some(key) = identity_key(locator.expect("checked")) else {
        return false;
    };
    let call_index = u64_of(l("call_index"));
    if locators.contains(&key) || previous_index.is_some_and(|previous| call_index <= previous) {
        return false;
    }
    locators.push(key);
    *previous_index = Some(call_index);
    true
}

/// `DSHAgentWALBatchShapeV2`: the read-only batch carries no manifest at all;
/// the write batch's manifest digest and write keys must match its calls.
pub fn batch_shape_v2(batch: &Value) -> bool {
    let b = |key: &str| get(batch, key);
    if !batch.is_object()
        || b("schema_version") != Some(&json!(2))
        || !b("kind").is_some_and(Value::is_string)
        || !canonical_uuid(b("task_id"))
        || !canonical_uuid(b("attempt_id"))
        || !canonical_uuid(b("round_id"))
        || safe_integer(b("round_index"), 7, true).is_none()
        || safe_integer(b("batch_revision"), MAX_SAFE_INTEGER, false).is_none()
        || !canonical_timestamp(b("created_at"))
        || !canonical_timestamp(b("updated_at"))
    {
        return false;
    }
    if string_eq(b("kind"), "read_only_batch") {
        let keys = [
            "schema_version",
            "kind",
            "task_id",
            "attempt_id",
            "round_id",
            "round_index",
            "batch_revision",
            "manifest_sha256",
            "reservation_delta_bytes",
            "reserved_write_bytes",
            "attempt_reserved_write_bytes",
            "effect_gate",
            "created_at",
            "updated_at",
        ];
        return exact_keys(Some(batch), &keys).is_some()
            && is_null(b("manifest_sha256"))
            && b("reservation_delta_bytes") == Some(&json!(0))
            && b("reserved_write_bytes") == Some(&json!(0))
            && safe_integer(
                b("attempt_reserved_write_bytes"),
                MAX_ATTEMPT_WRITE_BYTES,
                true,
            )
            .is_some()
            && string_eq(b("effect_gate"), "not_applicable");
    }
    let keys = [
        "schema_version",
        "kind",
        "task_id",
        "attempt_id",
        "round_id",
        "round_index",
        "batch_revision",
        "root_fingerprint_sha256",
        "binding_revision",
        "manifest_sha256",
        "manifest_calls",
        "write_keys",
        "reservation_delta_bytes",
        "reserved_write_bytes",
        "attempt_reserved_write_bytes",
        "effect_gate",
        "created_at",
        "updated_at",
    ];
    let calls = array(b("manifest_calls"));
    if !string_eq(b("kind"), "write_batch")
        || exact_keys(Some(batch), &keys).is_none()
        || !canonical_sha256(b("root_fingerprint_sha256"))
        || safe_integer(b("binding_revision"), MAX_SAFE_INTEGER, false).is_none()
        || !canonical_sha256(b("manifest_sha256"))
        || !b("manifest_calls").is_some_and(Value::is_array)
        || calls.is_empty()
        || calls.len() > 16
        || !b("write_keys").is_some_and(Value::is_array)
        || array(b("write_keys")).len() != calls.len()
        || safe_integer(b("reservation_delta_bytes"), MAX_BATCH_WRITE_BYTES, true).is_none()
        || safe_integer(b("reserved_write_bytes"), MAX_ATTEMPT_WRITE_BYTES, true).is_none()
        || safe_integer(
            b("attempt_reserved_write_bytes"),
            MAX_ATTEMPT_WRITE_BYTES,
            true,
        )
        .is_none()
        || u64_of(b("reserved_write_bytes")) > u64_of(b("attempt_reserved_write_bytes"))
        || u64_of(b("reservation_delta_bytes")) > u64_of(b("attempt_reserved_write_bytes"))
        || !matches!(
            as_str(b("effect_gate")),
            Some("closed" | "open" | "released")
        )
    {
        return false;
    }
    let mut locators: Vec<Vec<u8>> = Vec::with_capacity(calls.len());
    let mut previous_index: Option<u64> = None;
    let mut manifest_keys: Vec<Value> = Vec::with_capacity(calls.len());
    for call in calls {
        if !manifest_call_shape_v2(call, batch, &mut locators, &mut previous_index) {
            return false;
        }
        manifest_keys.push(
            get(call, "locator")
                .and_then(|l| get(l, "idempotency_key"))
                .cloned()
                .unwrap_or(Value::Null),
        );
    }
    let mut seen: Vec<&str> = Vec::new();
    for key in array(b("write_keys")) {
        let text = as_str(Some(key)).unwrap_or_default();
        if !canonical_sha256(Some(key)) || seen.contains(&text) {
            return false;
        }
        seen.push(text);
    }
    let manifest = hash_json("write-manifest", &json!({ "calls": b("manifest_calls") }));
    b("write_keys") == Some(&Value::Array(manifest_keys))
        && as_str(b("manifest_sha256")) == manifest.as_deref()
}

/// `DSHAgentWALToolReceiptShape`.
pub fn tool_receipt_shape(receipt: Option<&Value>) -> bool {
    let keys = [
        "schema_version",
        "call_id",
        "name",
        "arguments_sha256",
        "result_sha256",
        "result_bytes",
        "truncated",
        "duration_ms",
        "outcome",
        "failure_code",
        "approval_reference",
    ];
    let r = |key: &str| receipt.and_then(|r| get(r, key));
    if exact_keys(receipt, &keys).is_none()
        || r("schema_version") != Some(&json!(1))
        || !opaque_call_id(r("call_id"))
        || bounded_utf8(r("name"), 64, false).is_none()
        || !canonical_sha256(r("arguments_sha256"))
        || !canonical_sha256(r("result_sha256"))
        || safe_integer(r("result_bytes"), 32 * 1024 * 1024, true).is_none()
        || !is_boolean(r("truncated"))
        || safe_integer(r("duration_ms"), 24 * 60 * 60 * 1000, true).is_none()
        || !(is_null(r("approval_reference")) || canonical_uuid(r("approval_reference")))
    {
        return false;
    }
    let outcome = as_str(r("outcome")).unwrap_or_default();
    if !matches!(
        outcome,
        "ok" | "failed" | "denied" | "cancelled" | "ambiguous"
    ) {
        return false;
    }
    if outcome == "ok" {
        return is_null(r("failure_code"));
    }
    if !crate::schema::failure_code(r("failure_code")) {
        return false;
    }
    outcome != "ambiguous" || string_eq(r("failure_code"), "E_AGENT_EXECUTION_AMBIGUOUS")
}

/// `DSHAgentWALDeniedCallShape`: a durable denial or an argument refusal,
/// settled at preparation with its own receipt and canonical feedback.
pub fn denied_call_shape(row: &Value) -> bool {
    let keys = [
        "schema_version",
        "task_id",
        "attempt_id",
        "round_id",
        "round_index",
        "call_index",
        "call_id",
        "name",
        "arguments_sha256",
        "root_fingerprint_sha256",
        "binding_revision",
        "transcript_before",
        "state",
        "row_revision",
        "feedback",
        "transcript_after",
        "receipt",
        "created_at",
        "updated_at",
    ];
    let r = |key: &str| get(row, key);
    if exact_keys(Some(row), &keys).is_none()
        || r("schema_version") != Some(&json!(1))
        || !canonical_uuid(r("task_id"))
        || !canonical_uuid(r("attempt_id"))
        || !canonical_uuid(r("round_id"))
        || safe_integer(r("round_index"), 7, true).is_none()
        || safe_integer(r("call_index"), 15, true).is_none()
        || !opaque_call_id(r("call_id"))
        || bounded_utf8(r("name"), 64, false).is_none()
        || !canonical_sha256(r("arguments_sha256"))
        || !canonical_sha256(r("root_fingerprint_sha256"))
        || safe_integer(r("binding_revision"), MAX_SAFE_INTEGER, false).is_none()
        || !reference_shape(r("transcript_before"))
        || !matches!(as_str(r("state")), Some("denied" | "rejected"))
        || r("row_revision") != Some(&json!(1))
        || !reference_shape(r("transcript_after"))
        || !tool_receipt_shape(r("receipt"))
        || !canonical_timestamp(r("created_at"))
        || !canonical_timestamp(r("updated_at"))
    {
        return false;
    }
    let feedback = r("feedback");
    let payload = feedback.and_then(|f| get(f, "payload"));
    let p = |key: &str| payload.and_then(|p| get(p, key));
    // `denied` rows are durable denials (unknown tool / capability); `rejected`
    // rows are argument refusals settled at preparation as failed results with
    // a value-free reason token.
    let rejected = string_eq(r("state"), "rejected");
    let expected_outcome = if rejected { "failed" } else { "denied" };
    let payload_shape = if rejected {
        exact_keys(payload, &["schema_version", "failure_code", "reason"]).is_some()
            && bounded_utf8(p("reason"), 64, false)
                .is_some_and(|reason| reason.bytes().all(|b| b.is_ascii_lowercase() || b == b'_'))
            && (matches!(
                as_str(p("failure_code")),
                Some("E_AGENT_BAD_ARGUMENTS" | "E_AGENT_BAD_PATH")
            ) || (as_str(r("name")).is_some_and(|name| {
                crate::runtime_tools::is_runtime(name) || crate::assistant_tools::is_assistant(name)
            }) && matches!(
                as_str(p("failure_code")),
                Some("E_AGENT_CAPABILITY" | "E_AGENT_TOOL_FAILED")
            )))
    } else {
        exact_keys(payload, &["schema_version", "failure_code"]).is_some()
            && matches!(
                as_str(p("failure_code")),
                Some("E_AGENT_UNKNOWN_TOOL" | "E_AGENT_CAPABILITY")
            )
    };
    if exact_keys(feedback, &["schema_version", "name", "outcome", "payload"]).is_none()
        || feedback.and_then(|f| get(f, "schema_version")) != Some(&json!(1))
        || !equal(feedback.and_then(|f| get(f, "name")), r("name"))
        || !string_eq(feedback.and_then(|f| get(f, "outcome")), expected_outcome)
        || !payload_shape
        || p("schema_version") != Some(&json!(1))
    {
        return false;
    }
    let Ok(bytes) = canonical_json(feedback.expect("checked")) else {
        return false;
    };
    let Some(result_sha) = crate::canonical::hash_bytes("tool-result", &bytes) else {
        return false;
    };
    let receipt = r("receipt");
    let c = |key: &str| receipt.and_then(|r| get(r, key));
    bytes.len() <= 8 * 1024
        && equal(c("call_id"), r("call_id"))
        && equal(c("name"), r("name"))
        && equal(c("arguments_sha256"), r("arguments_sha256"))
        && as_str(c("result_sha256")) == Some(result_sha.as_str())
        && u64_of(c("result_bytes")) == bytes.len() as u64
        && string_eq(c("outcome"), expected_outcome)
        && equal(c("failure_code"), p("failure_code"))
}

/// `DSHAgentWALRoundCallV3Shape`; `Some(true)` when the call is a durable
/// denial.
fn round_call_v3_shape(call: &Value, expected_index: usize) -> Option<bool> {
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
    let c = |key: &str| get(call, key);
    if exact_keys(Some(call), &keys).is_none()
        || c("schema_version") != Some(&json!(3))
        || c("call_index") != Some(&json!(expected_index))
        || !opaque_call_id(c("call_id"))
        || bounded_utf8(c("name"), 64, false).is_none()
        || !canonical_sha256(c("arguments_sha256"))
        || bounded_utf8(c("safe_summary_key"), 128, false).is_none()
    {
        return None;
    }
    let access = as_str(c("access")).unwrap_or_default();
    let durable = access == "durable_deny";
    let known = as_str(c("name")).is_some_and(|name| KNOWN_TOOL_NAMES.contains(&name));
    let approval = if durable {
        string_eq(c("approval_state"), "durable_denied")
    } else {
        matches!(access, "auto" | "conversation_confirm" | "confirm_once")
            && string_eq(c("approval_state"), "deferred")
    };
    // An unknown tool can only appear as a durable denial, under the one
    // summary key that carries no arguments.
    if !approval
        || (!known && (!durable || !string_eq(c("safe_summary_key"), "agent.unknown")))
        || (string_eq(c("name"), "ask_user")
            && !((durable && string_eq(c("safe_summary_key"), "agent.unknown"))
                || (access == "auto" && string_eq(c("safe_summary_key"), "agent.ask_user"))))
    {
        return None;
    }
    let name = as_str(c("name")).unwrap_or_default();
    if crate::assistant_tools::is_assistant(name)
        && !((durable && string_eq(c("safe_summary_key"), "agent.unknown"))
            || (access
                == if crate::assistant_tools::is_mutation(name) {
                    "conversation_confirm"
                } else {
                    "auto"
                }
                && c("safe_summary_key") == Some(&json!(format!("agent.{name}")))))
    {
        return None;
    }
    Some(durable)
}

/// `DSHAgentWALRoundV3Shape`'s own half: every V3 rule, and the schema-2
/// projection the caller still puts through the round journal's V2 entry
/// validator. `None` when a V3 rule fails.
pub fn round_v3_projection(row: &Value) -> Option<Value> {
    let r = |key: &str| get(row, key);
    let keys = [
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
    let calls = array(r("calls"));
    if exact_keys(Some(row), &keys).is_none()
        || r("schema_version") != Some(&json!(3))
        || !r("calls").is_some_and(Value::is_array)
        || calls.len() > 16
        || safe_integer(r("executable_call_count"), 16, true).is_none()
        || safe_integer(r("denied_call_count"), 16, true).is_none()
    {
        return None;
    }
    let mut executable = 0usize;
    let mut denied_count = 0usize;
    let mut v2_calls = Vec::with_capacity(calls.len());
    for (index, call) in calls.iter().enumerate() {
        let denied = round_call_v3_shape(call, index)?;
        if denied {
            denied_count += 1;
        } else {
            executable += 1;
        }
        v2_calls.push(json!({
            "schema_version": 1,
            "call_id": get(call, "call_id"),
            "name": get(call, "name"),
            "arguments_sha256": get(call, "arguments_sha256"),
            "safe_summary_key": get(call, "safe_summary_key"),
            // The V2 shape has no durable-deny access; a denied call projects
            // back to the access it would have had.
            "access": if denied { json!("auto") } else { get(call, "access").cloned().unwrap_or(Value::Null) },
        }));
    }
    if r("executable_call_count") != Some(&json!(executable))
        || r("denied_call_count") != Some(&json!(denied_count))
    {
        return None;
    }
    if calls.is_empty() {
        if !is_null(r("batch_class")) || executable != 0 || denied_count != 0 {
            return None;
        }
    } else {
        let expected = if denied_count == 0 {
            "executable"
        } else if executable == 0 {
            "denied_only"
        } else {
            "mixed"
        };
        if !string_eq(r("batch_class"), expected) {
            return None;
        }
    }
    if string_eq(r("state"), "completed") {
        let terminal = as_str(r("terminal_kind")).unwrap_or_default();
        if (terminal == "tool_batch" && calls.is_empty())
            || (matches!(terminal, "final" | "blocked") && !calls.is_empty())
        {
            return None;
        }
    }
    let mut v2 = row.as_object()?.clone();
    v2.insert("schema_version".into(), json!(2));
    v2.insert("calls".into(), Value::Array(v2_calls));
    v2.remove("batch_class");
    v2.remove("executable_call_count");
    v2.remove("denied_call_count");
    Some(Value::Object(v2))
}

// MARK: - migrations

/// `DSHAgentWALMigrateRoundV2ToV3` after the caller has proved the row is a
/// valid schema-2 round entry. Returns the migrated row and its own schema-2
/// projection, which the caller still puts through the V2 entry validator.
pub fn migrate_round_v2_to_v3(row: &Value) -> Option<(Value, Value)> {
    if get(row, "schema_version") != Some(&json!(2)) {
        return None;
    }
    let mut calls = Vec::new();
    let mut executable = 0usize;
    let mut denied = 0usize;
    for (index, call) in array(get(row, "calls")).iter().enumerate() {
        // Schema-2 rounds predate ask_user. Its formerly unknown name must
        // remain denied even though the current registry recognizes it.
        let known = as_str(get(call, "name"))
            .is_some_and(|name| name != "ask_user" && KNOWN_TOOL_NAMES.contains(&name));
        calls.push(json!({
            "schema_version": 3,
            "call_index": index,
            "call_id": get(call, "call_id"),
            "name": get(call, "name"),
            "arguments_sha256": get(call, "arguments_sha256"),
            "safe_summary_key": if known { get(call, "safe_summary_key").cloned().unwrap_or(Value::Null) } else { json!("agent.unknown") },
            "access": if known { get(call, "access").cloned().unwrap_or(Value::Null) } else { json!("durable_deny") },
            "approval_state": if known { "deferred" } else { "durable_denied" },
        }));
        if known {
            executable += 1;
        } else {
            denied += 1;
        }
    }
    if string_eq(get(row, "terminal_kind"), "tool_batch") && calls.is_empty() {
        return None;
    }
    let mut migrated = row.as_object()?.clone();
    migrated.insert("schema_version".into(), json!(3));
    let batch_class = if calls.is_empty() {
        Value::Null
    } else if denied == 0 {
        json!("executable")
    } else if executable == 0 {
        json!("denied_only")
    } else {
        json!("mixed")
    };
    migrated.insert("calls".into(), Value::Array(calls));
    migrated.insert("batch_class".into(), batch_class);
    migrated.insert("executable_call_count".into(), json!(executable));
    migrated.insert("denied_call_count".into(), json!(denied));
    let migrated = Value::Object(migrated);
    let v2 = round_v3_projection(&migrated)?;
    Some((migrated, v2))
}

/// `DSHAgentWALMigrateBatchV1ToV2`: every legacy call becomes a file_write
/// mutation with the precondition digest the ledger now stores.
pub fn migrate_batch_v1_to_v2(batch: &Value) -> Option<Value> {
    if !batch_shape_v1(batch) {
        return None;
    }
    let calls = array(get(batch, "manifest_calls"));
    let first = get(calls.first()?, "locator")?;
    let round_id = get(first, "round_id")?.clone();
    let round_index = get(first, "round_index")?.clone();
    let mut manifest_calls = Vec::with_capacity(calls.len());
    for call in calls {
        let locator = get(call, "locator")?;
        if get(locator, "round_id") != Some(&round_id)
            || get(locator, "round_index") != Some(&round_index)
        {
            return None;
        }
        let precondition = json!({
            "schema_version": 2, "kind": "write_file",
            "relative_path_sha256": get(call, "relative_path_sha256"),
            "prior": get(call, "prior"), "content_sha256": get(call, "content_sha256"),
            "content_bytes": get(call, "content_bytes"),
        });
        let digest = hash_json(
            "tool-precondition",
            &json!({ "schema_version": 1, "name": "write_file", "precondition": precondition }),
        )?;
        manifest_calls.push(json!({
            "schema_version": 2, "mutation_kind": "file_write",
            "locator": locator, "precondition_sha256": digest,
            "relative_path_sha256": get(call, "relative_path_sha256"),
            "prior": get(call, "prior"), "content_sha256": get(call, "content_sha256"),
            "content_bytes": get(call, "content_bytes"),
        }));
    }
    let manifest_calls = Value::Array(manifest_calls);
    let manifest = hash_json("write-manifest", &json!({ "calls": manifest_calls }))?;
    let mut migrated = batch.as_object()?.clone();
    migrated.insert("schema_version".into(), json!(2));
    migrated.insert("kind".into(), json!("write_batch"));
    migrated.insert("round_id".into(), round_id);
    migrated.insert("round_index".into(), round_index);
    migrated.insert(
        "batch_revision".into(),
        get(batch, "reservation_version")?.clone(),
    );
    migrated.insert("manifest_calls".into(), manifest_calls);
    migrated.insert("manifest_sha256".into(), json!(manifest));
    migrated.remove("reservation_version");
    let migrated = Value::Object(migrated);
    batch_shape_v2(&migrated).then_some(migrated)
}

// MARK: - the whole stored state

const MAX_TRANSCRIPT_COUNT: usize = 128;
const MAX_LEDGER_ROWS_PER_ATTEMPT: usize = 128;
const MAX_ROUND_ROWS_PER_ATTEMPT: usize = 8;
const MAX_STORE_BYTES: usize = 64 * 1024 * 1024;
pub const MAX_AUTHORITIES: usize = 128;
pub const MAX_OPERATIONS_PER_ATTEMPT: usize = 256;
pub const MAX_OPERATIONS: usize = 2048;
pub const MAX_OPERATION_RECORD_BYTES: usize = 16 * 1024;
pub const MAX_BATCHES_PER_ATTEMPT: usize = 128;
pub const MAX_DENIED_CALLS_PER_ATTEMPT: usize = 128;
pub const MAX_DENIED_CALLS: usize = 2048;

const V1_KEYS: &[&str] = &[
    "schema_version",
    "generation",
    "transcripts",
    "rounds",
    "ledger",
    "reservations",
    "cleanup",
    "dispatch",
    "batches",
];

const V2_KEYS: &[&str] = &[
    "schema_version",
    "generation",
    "authorities",
    "operations",
    "operation_results",
    "transcripts",
    "rounds",
    "ledger",
    "reservations",
    "cleanup",
    "dispatch",
    "batches",
    "denied_calls",
];

/// Why the loader refuses a stored state, or which typed row it wants the
/// host's own validator to judge.
pub enum StateVerdict {
    Valid,
    /// The state is not the shape the loader accepts.
    Corrupt,
    /// The state is well-formed but over one of the WAL's capacities.
    Capacity,
    /// Everything up to this ledger row holds; the host's execution-ledger
    /// entry validator refused it and owns the error it reports.
    Ledger(usize),
}

fn bool_at(verdicts: &[bool], index: usize) -> bool {
    verdicts.get(index).copied().unwrap_or(false)
}

fn attempt_count(rows: &[Value], attempt_id: Option<&Value>) -> usize {
    rows.iter()
        .filter(|row| get(row, "locator").and_then(|l| get(l, "attempt_id")) == attempt_id)
        .count()
}

/// `DSHAgentFindDispatchState`.
fn dispatch_state<'a>(rows: &'a [Value], kind: &str, locator: Option<&Value>) -> Option<&'a str> {
    rows.iter()
        .find(|row| string_eq(get(row, "kind"), kind) && get(row, "locator") == locator)
        .and_then(|row| as_str(get(row, "dispatch_state")))
}

/// `DSHAgentWALTranscriptBound`: the transcript a row names must still be the
/// one it was written against, or a later generation of it.
fn transcript_bound(state: &Value, row: &Value) -> bool {
    let Some(state_name) = as_str(get(row, "state")) else {
        return false;
    };
    let mut before = get(row, "transcript_before");
    if !before.is_some_and(Value::is_object) {
        return false;
    }
    let after = get(row, "transcript_after");
    if matches!(
        state_name,
        "completed" | "settled" | "cancelled" | "ambiguous"
    ) && !is_null(after)
    {
        before = after;
    }
    let before = before.expect("checked");
    let locator = get(row, "locator");
    array(get(state, "transcripts")).iter().any(|transcript| {
        get(transcript, "transcript_ref") == get(before, "transcript_ref")
            && get(transcript, "attempt_id") == locator.and_then(|l| get(l, "attempt_id"))
            && get(transcript, "root_fingerprint_sha256") == get(row, "root_fingerprint_sha256")
            && ((get(transcript, "generation") == get(before, "generation")
                && get(transcript, "transcript_sha256") == get(before, "transcript_sha256")
                && get(transcript, "transcript_bytes") == get(before, "transcript_bytes"))
                || u64_of(get(transcript, "generation")) > u64_of(get(before, "generation"))
                || (is_null(after)
                    && !matches!(
                        state_name,
                        "intent" | "running" | "in_flight" | "cancel_requested"
                    )))
    })
}

fn transcripts_shape(state: &Value) -> StateVerdict {
    let keys = [
        "schema_version",
        "transcript_ref",
        "attempt_id",
        "root_fingerprint_sha256",
        "generation",
        "messages",
        "transcript_sha256",
        "transcript_bytes",
        "state",
        "retention_until",
        "created_at",
        "updated_at",
    ];
    let mut refs: Vec<&Value> = Vec::new();
    let mut attempts: Vec<&Value> = Vec::new();
    for transcript in array(get(state, "transcripts")) {
        let t = |key: &str| get(transcript, key);
        let messages = array(t("messages"));
        if !transcript.is_object()
            || exact_keys(Some(transcript), &keys).is_none()
            || !schema(t("schema_version"), 1)
            || !canonical_uuid(t("transcript_ref"))
            || !canonical_uuid(t("attempt_id"))
            || !canonical_sha256(t("root_fingerprint_sha256"))
            || safe_integer(t("generation"), MAX_SAFE_INTEGER, true).is_none()
            || !t("messages").is_some_and(Value::is_array)
            || messages.len() > 1024
            || !canonical_sha256(t("transcript_sha256"))
            || safe_integer(t("transcript_bytes"), MAX_TRANSCRIPT_BYTES, true).is_none()
            || !matches!(
                as_str(t("state")),
                Some("open" | "terminal" | "cleanup_pending")
            )
            || !(is_null(t("retention_until")) || canonical_timestamp(t("retention_until")))
            || !canonical_timestamp(t("created_at"))
            || !canonical_timestamp(t("updated_at"))
        {
            return StateVerdict::Corrupt;
        }
        let reference = t("transcript_ref").expect("checked");
        if refs.contains(&reference) || attempts.contains(&t("attempt_id").expect("checked")) {
            return StateVerdict::Corrupt;
        }
        refs.push(reference);
        attempts.push(t("attempt_id").expect("checked"));
        if messages.iter().any(|message| !message_shape(message))
            || canonical_json(transcript).is_err()
        {
            return StateVerdict::Corrupt;
        }
        let digest_input = json!({
            "schema_version": 1,
            "transcript_ref": t("transcript_ref"),
            "attempt_id": t("attempt_id"),
            "root_fingerprint_sha256": t("root_fingerprint_sha256"),
            "generation": t("generation"),
            "messages": t("messages"),
        });
        let (Some(digest), Ok(bytes)) = (
            hash_json("agent-transcript", &digest_input),
            canonical_json(&digest_input),
        ) else {
            return StateVerdict::Corrupt;
        };
        if u64_of(t("transcript_bytes")) != bytes.len() as u64
            || as_str(t("transcript_sha256")) != Some(digest.as_str())
        {
            return StateVerdict::Corrupt;
        }
    }
    StateVerdict::Valid
}

fn authorities_and_operations(state: &Value, env: &Env) -> StateVerdict {
    let transcripts = array(get(state, "transcripts"));
    let authorities = array(get(state, "authorities"));
    if authorities.len() > MAX_AUTHORITIES {
        return StateVerdict::Capacity;
    }
    let mut authority_keys: Vec<(Option<&Value>, Option<&Value>)> = Vec::new();
    for authority in authorities {
        if !authority_shape(authority, env) {
            return StateVerdict::Corrupt;
        }
        let key = (get(authority, "task_id"), get(authority, "attempt_id"));
        if authority_keys.contains(&key) {
            return StateVerdict::Corrupt;
        }
        authority_keys.push(key);
        let reference = get(authority, "transcript").and_then(|t| get(t, "transcript_ref"));
        let mut matches = 0usize;
        for transcript in transcripts {
            if get(transcript, "transcript_ref") != reference {
                continue;
            }
            matches += 1;
            if get(transcript, "attempt_id") != get(authority, "attempt_id")
                || get(transcript, "root_fingerprint_sha256")
                    != get(authority, "root").and_then(|r| get(r, "root_fingerprint_sha256"))
            {
                return StateVerdict::Corrupt;
            }
        }
        if matches != 1 {
            return StateVerdict::Corrupt;
        }
    }
    let snapshots = array(get(state, "operation_results"));
    if snapshots.len() > MAX_OPERATIONS {
        return StateVerdict::Capacity;
    }
    let mut by_id: Vec<(Option<&Value>, &Value)> = Vec::new();
    for snapshot in snapshots {
        let id = get(snapshot, "operation_id");
        if !operation_result_shape(snapshot) || by_id.iter().any(|(other, _)| *other == id) {
            return StateVerdict::Corrupt;
        }
        by_id.push((id, snapshot));
    }
    let operations = array(get(state, "operations"));
    if operations.len() > MAX_OPERATIONS {
        return StateVerdict::Capacity;
    }
    let mut ids: Vec<Option<&Value>> = Vec::new();
    let mut counts: Vec<(Option<&Value>, usize)> = Vec::new();
    for operation in operations {
        let id = get(operation, "operation_id");
        let record = canonical_json(operation);
        if !operation_shape(operation)
            || record
                .as_ref()
                .is_ok_and(|bytes| bytes.len() > MAX_OPERATION_RECORD_BYTES)
            || record.is_err()
            || ids.contains(&id)
        {
            return StateVerdict::Corrupt;
        }
        ids.push(id);
        let attempt = get(operation, "attempt_id");
        let count = counts
            .iter()
            .find(|(other, _)| *other == attempt)
            .map_or(0, |(_, count)| *count)
            + 1;
        if count > MAX_OPERATIONS_PER_ATTEMPT {
            return StateVerdict::Capacity;
        }
        counts.retain(|(other, _)| *other != attempt);
        counts.push((attempt, count));
        let snapshot = by_id
            .iter()
            .find(|(other, _)| *other == id)
            .map(|(_, snapshot)| *snapshot);
        let reference = get(operation, "result_snapshot_ref");
        if is_null(reference) {
            if snapshot.is_some() {
                return StateVerdict::Corrupt;
            }
            continue;
        }
        let Some(snapshot) = snapshot else {
            return StateVerdict::Corrupt;
        };
        if get(snapshot, "operation_kind") != get(operation, "operation_kind")
            || get(snapshot, "result_status") != get(operation, "result_status")
            || get(snapshot, "result_sha256") != reference.and_then(|r| get(r, "result_sha256"))
            || get(snapshot, "result_bytes") != reference.and_then(|r| get(r, "result_bytes"))
        {
            return StateVerdict::Corrupt;
        }
    }
    if by_id.iter().any(|(id, _)| !ids.contains(id)) {
        return StateVerdict::Corrupt;
    }
    StateVerdict::Valid
}

fn ledger_rows(state: &Value, ledger_valid: &[bool]) -> StateVerdict {
    let row_keys = [
        "schema_version",
        "locator",
        "row_revision",
        "root_fingerprint_sha256",
        "binding_revision",
        "transcript_before",
        "name",
        "arguments_sha256",
        "precondition",
        "reserved_write_bytes",
        "state",
        "owner",
        "settled_facts",
        "transcript_after",
        "receipt",
        "created_at",
        "updated_at",
    ];
    let locator_keys = [
        "schema_version",
        "task_id",
        "attempt_id",
        "round_id",
        "round_index",
        "call_index",
        "call_id",
        "idempotency_key",
    ];
    let mut locators: Vec<&Value> = Vec::new();
    for (index, ledger) in array(get(state, "ledger")).iter().enumerate() {
        let locator = get(ledger, "locator");
        let l = |key: &str| locator.and_then(|l| get(l, key));
        let r = |key: &str| get(ledger, key);
        if !ledger.is_object()
            || exact_keys(Some(ledger), &row_keys).is_none()
            || r("schema_version") != Some(&json!(2))
            || exact_keys(locator, &locator_keys).is_none()
            || l("schema_version") != Some(&json!(2))
            || !canonical_uuid(l("task_id"))
            || !canonical_uuid(l("attempt_id"))
            || !canonical_uuid(l("round_id"))
            || safe_integer(l("round_index"), 7, true).is_none()
            || safe_integer(l("call_index"), 15, true).is_none()
            || !canonical_sha256(l("idempotency_key"))
            || bounded_utf8(l("call_id"), 128, false).is_none()
            || safe_integer(r("row_revision"), MAX_SAFE_INTEGER, false).is_none()
            || !canonical_sha256(r("root_fingerprint_sha256"))
            || safe_integer(r("binding_revision"), MAX_SAFE_INTEGER, false).is_none()
            || !reference_shape(r("transcript_before"))
            || bounded_utf8(r("name"), 64, false).is_none()
            || !canonical_sha256(r("arguments_sha256"))
            || safe_integer(r("reserved_write_bytes"), MAX_SINGLE_WRITE_BYTES, true).is_none()
            || !matches!(
                as_str(r("state")),
                Some(
                    "intent"
                        | "running"
                        | "cancel_requested"
                        | "settled"
                        | "cancelled"
                        | "unknown"
                        | "ambiguous"
                )
            )
            || !canonical_timestamp(r("created_at"))
            || !canonical_timestamp(r("updated_at"))
        {
            return StateVerdict::Corrupt;
        }
        let locator = locator.expect("checked");
        if locators.contains(&locator) {
            return StateVerdict::Corrupt;
        }
        locators.push(locator);
        if !bool_at(ledger_valid, index) {
            return StateVerdict::Ledger(index);
        }
        if !transcript_bound(state, ledger) {
            return StateVerdict::Corrupt;
        }
    }
    StateVerdict::Valid
}

fn batches(state: &Value, schema_v2: bool) -> StateVerdict {
    let reservations = array(get(state, "reservations"));
    let ledger = array(get(state, "ledger"));
    let mut identities: Vec<String> = Vec::new();
    let mut counts: Vec<(Option<&Value>, usize)> = Vec::new();
    for batch in array(get(state, "batches")) {
        let b = |key: &str| get(batch, key);
        let valid = if schema_v2 {
            batch_shape_v2(batch)
        } else {
            batch_shape_v1(batch)
        };
        if !valid {
            return StateVerdict::Corrupt;
        }
        let text = |key: &str| match b(key) {
            Some(Value::String(value)) => value.clone(),
            Some(value) => value.to_string(),
            None => String::new(),
        };
        let identity = if schema_v2 {
            format!(
                "{}:{}:{}:{}:{}",
                text("task_id"),
                text("attempt_id"),
                text("round_id"),
                text("round_index"),
                text("batch_revision")
            )
        } else {
            format!(
                "{}:{}:{}",
                text("task_id"),
                text("attempt_id"),
                text("manifest_sha256")
            )
        };
        if identities.contains(&identity) {
            return StateVerdict::Corrupt;
        }
        identities.push(identity);
        let attempt = b("attempt_id");
        let count = counts
            .iter()
            .find(|(other, _)| *other == attempt)
            .map_or(0, |(_, count)| *count)
            + 1;
        if schema_v2 && count > MAX_BATCHES_PER_ATTEMPT {
            return StateVerdict::Capacity;
        }
        counts.retain(|(other, _)| *other != attempt);
        counts.push((attempt, count));
        if schema_v2 && string_eq(b("kind"), "read_only_batch") {
            continue;
        }
        let mut reservation: Option<&Value> = None;
        for candidate in reservations {
            if get(candidate, "task_id") != b("task_id")
                || get(candidate, "attempt_id") != b("attempt_id")
            {
                continue;
            }
            let version = if schema_v2 {
                b("batch_revision")
            } else {
                b("reservation_version")
            };
            if reservation.is_some()
                || get(candidate, "root_fingerprint_sha256") != b("root_fingerprint_sha256")
                || get(candidate, "binding_revision") != b("binding_revision")
                || u64_of(b("reservation_delta_bytes"))
                    > u64_of(get(candidate, "policy").and_then(|p| get(p, "max_batch_write_bytes")))
                || u64_of(version) > u64_of(get(candidate, "reservation_version"))
            {
                return StateVerdict::Corrupt;
            }
            reservation = Some(candidate);
        }
        let Some(reservation) = reservation else {
            return StateVerdict::Corrupt;
        };
        for call in array(b("manifest_calls")) {
            let call_locator = get(call, "locator");
            let mut matching = 0usize;
            for row in ledger {
                if get(row, "locator") != call_locator {
                    continue;
                }
                matching += 1;
                // Schema-one batches predate the mutation discriminator and
                // contain file-write calls only.
                let mutation_kind = if schema_v2 {
                    as_str(get(call, "mutation_kind")).unwrap_or_default()
                } else {
                    "file_write"
                };
                let expected_name = if mutation_kind == "file_write" {
                    "write_file"
                } else {
                    mutation_kind
                };
                let precondition = get(row, "precondition");
                let digest = hash_json(
                    "tool-precondition",
                    &json!({
                        "schema_version": 1,
                        "name": get(row, "name"),
                        "precondition": precondition,
                    }),
                );
                let released = array(get(reservation, "keys")).iter().any(|key| {
                    get(key, "idempotency_key")
                        == call_locator.and_then(|l| get(l, "idempotency_key"))
                        && string_eq(get(key, "state"), "released")
                });
                if get(row, "locator").and_then(|l| get(l, "task_id")) != b("task_id")
                    || get(row, "locator").and_then(|l| get(l, "attempt_id")) != b("attempt_id")
                    || get(row, "root_fingerprint_sha256") != b("root_fingerprint_sha256")
                    || get(row, "binding_revision") != b("binding_revision")
                    || !string_eq(get(row, "name"), expected_name)
                    || digest.is_none()
                    || (schema_v2 && digest.as_deref() != as_str(get(call, "precondition_sha256")))
                {
                    return StateVerdict::Corrupt;
                }
                let p = |key: &str| precondition.and_then(|p| get(p, key));
                if mutation_kind == "file_write" {
                    let reserved_matches = get(row, "reserved_write_bytes")
                        == get(call, "content_bytes")
                        || (matches!(as_str(get(row, "state")), Some("intent" | "cancelled"))
                            && get(row, "reserved_write_bytes") == Some(&json!(0))
                            && released);
                    if p("relative_path_sha256") != get(call, "relative_path_sha256")
                        || p("prior") != get(call, "prior")
                        || p("content_sha256") != get(call, "content_sha256")
                        || p("content_bytes") != get(call, "content_bytes")
                        || !reserved_matches
                    {
                        return StateVerdict::Corrupt;
                    }
                } else if get(row, "reserved_write_bytes") != Some(&json!(0)) || released {
                    return StateVerdict::Corrupt;
                }
            }
            if matching != 1 {
                return StateVerdict::Corrupt;
            }
        }
    }
    StateVerdict::Valid
}

fn denied_calls(state: &Value) -> StateVerdict {
    let rows = array(get(state, "denied_calls"));
    if rows.len() > MAX_DENIED_CALLS {
        return StateVerdict::Capacity;
    }
    let mut keys: Vec<Vec<u8>> = Vec::new();
    let mut counts: Vec<(Option<&Value>, usize)> = Vec::new();
    for row in rows {
        let r = |key: &str| get(row, key);
        let Ok(bytes) = canonical_json(row) else {
            return StateVerdict::Corrupt;
        };
        if !denied_call_shape(row) || bytes.len() > 8 * 1024 {
            return StateVerdict::Corrupt;
        }
        let identity = json!([
            r("task_id"),
            r("attempt_id"),
            r("round_id"),
            r("round_index"),
            r("call_index"),
            r("call_id"),
            r("arguments_sha256"),
        ]);
        let Ok(key) = canonical_json(&identity) else {
            return StateVerdict::Corrupt;
        };
        if keys.contains(&key) {
            return StateVerdict::Corrupt;
        }
        keys.push(key);
        let attempt = r("attempt_id");
        let count = counts
            .iter()
            .find(|(other, _)| *other == attempt)
            .map_or(0, |(_, count)| *count)
            + 1;
        if count > MAX_DENIED_CALLS_PER_ATTEMPT {
            return StateVerdict::Capacity;
        }
        counts.retain(|(other, _)| *other != attempt);
        counts.push((attempt, count));
        let after = r("transcript_after");
        let mut matches = 0usize;
        for transcript in array(get(state, "transcripts")) {
            if get(transcript, "transcript_ref") != after.and_then(|a| get(a, "transcript_ref")) {
                continue;
            }
            if get(transcript, "attempt_id") != r("attempt_id")
                || get(transcript, "root_fingerprint_sha256") != r("root_fingerprint_sha256")
                || u64_of(get(transcript, "generation"))
                    < u64_of(after.and_then(|a| get(a, "generation")))
            {
                return StateVerdict::Corrupt;
            }
            matches += 1;
        }
        if matches != 1 {
            return StateVerdict::Corrupt;
        }
    }
    StateVerdict::Valid
}

#[path = "wal_question.rs"]
mod question;

/// The dispatch relation: every round and ledger row needs its marker, the
/// marker's state has to agree with the row's own state, and no marker may
/// outlive its row — an orphan could otherwise be mistaken for proof about a
/// reused locator.
fn dispatch_relation(state: &Value) -> StateVerdict {
    let markers = array(get(state, "dispatch"));
    for round in array(get(state, "rounds")) {
        let Some(marker) = dispatch_state(markers, "round", get(round, "locator")) else {
            return StateVerdict::Corrupt;
        };
        let round_state = as_str(get(round, "state")).unwrap_or_default();
        if (matches!(round_state, "failed_retryable" | "cancelled" | "unknown")
            && marker != "not_dispatched")
            || (round_state == "completed" && marker != "dispatched")
        {
            return StateVerdict::Corrupt;
        }
    }
    for ledger in array(get(state, "ledger")) {
        let Some(marker) = dispatch_state(markers, "execution", get(ledger, "locator")) else {
            return StateVerdict::Corrupt;
        };
        let row_state = as_str(get(ledger, "state")).unwrap_or_default();
        if matches!(row_state, "cancelled" | "intent" | "unknown") && marker != "not_dispatched" {
            return StateVerdict::Corrupt;
        }
        if row_state == "ambiguous" && marker != "dispatched" {
            return StateVerdict::Corrupt;
        }
        if row_state == "settled" && marker != "dispatched" {
            // A user denial has no settled facts or approval reference. An
            // answered question is also undispatched, but needs its exact
            // protected response, receipt and settled-facts binding.
            let receipt = get(ledger, "receipt").filter(|receipt| receipt.is_object());
            let user_denial = marker == "not_dispatched"
                && receipt.is_some_and(|receipt| {
                    string_eq(get(receipt, "outcome"), "denied")
                        && string_eq(get(receipt, "failure_code"), "E_AGENT_DENIED_BY_USER")
                        && is_null(get(receipt, "approval_reference"))
                })
                && is_null(get(ledger, "settled_facts"))
                && is_null(get(ledger, "owner"));
            let user_response =
                marker == "not_dispatched" && question::undispatched_settlement(state, ledger);
            if !user_denial && !user_response {
                return StateVerdict::Corrupt;
            }
        }
    }
    for marker in markers {
        let rows = if string_eq(get(marker, "kind"), "round") {
            array(get(state, "rounds"))
        } else {
            array(get(state, "ledger"))
        };
        if !rows
            .iter()
            .any(|row| get(row, "locator") == get(marker, "locator"))
        {
            return StateVerdict::Corrupt;
        }
    }
    StateVerdict::Valid
}

/// `DSHAgentWALRowsShape`: the loader rejects malformed rows before a typed
/// view can accidentally use them. The host's own round and ledger entry
/// validators are mandatory here and reach this through `round_valid` and
/// `ledger_valid`; these checks additionally cover the shared envelope, the
/// cross-store bindings and the uniqueness relations.
pub fn rows_shape(
    state: &Value,
    env: &Env,
    round_valid: &[bool],
    ledger_valid: &[bool],
) -> StateVerdict {
    let schema_v2 = get(state, "schema_version") == Some(&json!(2));
    if let verdict @ (StateVerdict::Corrupt | StateVerdict::Capacity) = transcripts_shape(state) {
        return verdict;
    }
    if schema_v2 {
        if let verdict @ (StateVerdict::Corrupt | StateVerdict::Capacity) =
            authorities_and_operations(state, env)
        {
            return verdict;
        }
    }
    let mut locators: Vec<&Value> = Vec::new();
    for (index, round) in array(get(state, "rounds")).iter().enumerate() {
        if !round.is_object() || !bool_at(round_valid, index) {
            return StateVerdict::Corrupt;
        }
        let Some(locator) = get(round, "locator") else {
            return StateVerdict::Corrupt;
        };
        if locators.contains(&locator) || !transcript_bound(state, round) {
            return StateVerdict::Corrupt;
        }
        locators.push(locator);
    }
    let mut counts: Vec<(Option<&Value>, usize)> = Vec::new();
    for round in array(get(state, "rounds")) {
        let attempt = get(round, "locator").and_then(|l| get(l, "attempt_id"));
        let count = counts
            .iter()
            .find(|(other, _)| *other == attempt)
            .map_or(0, |(_, count)| *count);
        if count >= MAX_ROUND_ROWS_PER_ATTEMPT {
            return StateVerdict::Capacity;
        }
        counts.retain(|(other, _)| *other != attempt);
        counts.push((attempt, count + 1));
    }
    match ledger_rows(state, ledger_valid) {
        StateVerdict::Valid => {}
        verdict => return verdict,
    }
    let mut reservation_keys: Vec<(Option<&Value>, Option<&Value>)> = Vec::new();
    for reservation in array(get(state, "reservations")) {
        let key = (get(reservation, "task_id"), get(reservation, "attempt_id"));
        if !reservation_shape(reservation) || reservation_keys.contains(&key) {
            return StateVerdict::Corrupt;
        }
        reservation_keys.push(key);
    }
    let mut cleanup_ids: Vec<Option<&Value>> = Vec::new();
    for cleanup in array(get(state, "cleanup")) {
        let id = get(cleanup, "cleanup_id");
        if !cleanup_shape(cleanup) || cleanup_ids.contains(&id) {
            return StateVerdict::Corrupt;
        }
        cleanup_ids.push(id);
        let mut matches = 0usize;
        for transcript in array(get(state, "transcripts")) {
            if get(transcript, "transcript_ref") != get(cleanup, "transcript_ref") {
                continue;
            }
            matches += 1;
            if get(transcript, "attempt_id") != get(cleanup, "attempt_id")
                || get(transcript, "transcript_sha256") != get(cleanup, "transcript_sha256")
            {
                return StateVerdict::Corrupt;
            }
        }
        let status = as_str(get(cleanup, "status")).unwrap_or_default();
        if (status == "pending" && matches != 1) || (status == "discarded" && matches != 0) {
            return StateVerdict::Corrupt;
        }
    }
    let mut dispatch_keys: Vec<String> = Vec::new();
    for marker in array(get(state, "dispatch")) {
        if !dispatch_shape(marker) {
            return StateVerdict::Corrupt;
        }
        let locator =
            canonical_json(get(marker, "locator").unwrap_or(&Value::Null)).unwrap_or_default();
        let key = format!(
            "{}:{}",
            as_str(get(marker, "kind")).unwrap_or_default(),
            String::from_utf8_lossy(&locator)
        );
        if dispatch_keys.contains(&key) {
            return StateVerdict::Corrupt;
        }
        dispatch_keys.push(key);
    }
    match batches(state, schema_v2) {
        StateVerdict::Valid => {}
        verdict => return verdict,
    }
    if schema_v2 {
        match denied_calls(state) {
            StateVerdict::Valid => {}
            verdict => return verdict,
        }
    }
    dispatch_relation(state)
}

/// `DSHAgentWALStateBasicValidation`: the root keys, the per-attempt
/// capacities, every row relation and the stored file's own byte ceiling.
pub fn state_basic_validation(
    state: &Value,
    env: &Env,
    round_valid: &[bool],
    ledger_valid: &[bool],
) -> StateVerdict {
    let schema_v1 = get(state, "schema_version") == Some(&json!(1));
    let schema_v2 = get(state, "schema_version") == Some(&json!(2));
    let root_keys = if schema_v1 { V1_KEYS } else { V2_KEYS };
    let is_array = |key: &str| get(state, key).is_some_and(Value::is_array);
    if (!schema_v1 && !schema_v2)
        || exact_keys(Some(state), root_keys).is_none()
        || safe_integer(get(state, "generation"), MAX_SAFE_INTEGER, true).is_none()
        || (schema_v2
            && !(is_array("authorities")
                && is_array("operations")
                && is_array("operation_results")
                && is_array("denied_calls")))
        || !is_array("transcripts")
        || !is_array("rounds")
        || !is_array("ledger")
        || !is_array("reservations")
        || !is_array("cleanup")
        || !is_array("dispatch")
        || !is_array("batches")
    {
        return StateVerdict::Corrupt;
    }
    if array(get(state, "transcripts")).len() > MAX_TRANSCRIPT_COUNT {
        return StateVerdict::Capacity;
    }
    let ledger = array(get(state, "ledger"));
    if ledger.len() > MAX_TRANSCRIPT_COUNT * MAX_LEDGER_ROWS_PER_ATTEMPT
        || array(get(state, "rounds")).len() > MAX_TRANSCRIPT_COUNT * MAX_ROUND_ROWS_PER_ATTEMPT
    {
        return StateVerdict::Capacity;
    }
    let mut attempts: Vec<Option<&Value>> = Vec::new();
    for row in ledger {
        let locator = get(row, "locator");
        if !row.is_object()
            || !locator.is_some_and(Value::is_object)
            || bounded_utf8(locator.and_then(|l| get(l, "attempt_id")), 128, false).is_none()
        {
            return StateVerdict::Corrupt;
        }
        let attempt = locator.and_then(|l| get(l, "attempt_id"));
        if !attempts.contains(&attempt) {
            attempts.push(attempt);
        }
    }
    if attempts
        .iter()
        .any(|attempt| attempt_count(ledger, *attempt) > MAX_LEDGER_ROWS_PER_ATTEMPT)
    {
        return StateVerdict::Capacity;
    }
    match rows_shape(state, env, round_valid, ledger_valid) {
        StateVerdict::Valid => {}
        verdict => return verdict,
    }
    match canonical_json(state) {
        Err(_) => StateVerdict::Corrupt,
        Ok(bytes) if bytes.len() > MAX_STORE_BYTES => StateVerdict::Capacity,
        Ok(_) => StateVerdict::Valid,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dispatch_markers_are_bound_to_their_kind() {
        let round = json!({
            "schema_version": 1, "kind": "round", "dispatch_state": "dispatched",
            "locator": { "schema_version": 1, "task_id": "0f0e3b1a-4c7d-4e2f-9a1b-2c3d4e5f6a7b",
                         "attempt_id": "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d",
                         "round_id": "9b8a7c6d-5e4f-4321-8765-43210fedcba9", "round_index": 0 },
        });
        assert!(dispatch_shape(&round));
        let mut execution = round.clone();
        execution["kind"] = json!("execution");
        assert!(
            !dispatch_shape(&execution),
            "an execution marker needs the call locator"
        );
    }

    #[test]
    fn safe_results_refuse_raw_payload_keys() {
        let kind = json!("execute_agent_tool");
        let id = json!("0f0e3b1a-4c7d-4e2f-9a1b-2c3d4e5f6a7b");
        let status = json!("completed");
        let safe = json!({
            "schema_version": 2, "result_kind": "execute_agent_tool",
            "result": { "schema_version": 2, "operation_id": id, "status": "completed" },
        });
        assert!(safe_result_shape(
            Some(&safe),
            Some(&kind),
            Some(&id),
            Some(&status)
        ));
        let mut leaked = safe.clone();
        leaked["result"]["arguments_json"] = json!("{}");
        assert!(!safe_result_shape(
            Some(&leaked),
            Some(&kind),
            Some(&id),
            Some(&status)
        ));
    }

    #[test]
    fn registry_tools_must_be_ordered_and_unique() {
        let tool = |name: &str| json!({ "schema_version": 2, "name": name, "safe_summary_key": "agent.x", "access": "auto" });
        let registry = json!({
            "schema_version": 2, "registry_version": 2, "toolset_sha256": "a".repeat(64),
            "tools": [tool("list_dir"), tool("read_file")],
        });
        assert!(registry_shape(Some(&registry)));
        let unordered = json!({
            "schema_version": 2, "registry_version": 2, "toolset_sha256": "a".repeat(64),
            "tools": [tool("read_file"), tool("list_dir")],
        });
        assert!(!registry_shape(Some(&unordered)));
    }
}
