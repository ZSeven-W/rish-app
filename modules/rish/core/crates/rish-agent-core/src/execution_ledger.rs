//! The schema-2 execution ledger (`DSHAgentExecutionLedger`): the exact row,
//! precondition, settled-fact, receipt and protected-feedback invariants,
//! ported from `AgentExecutionLedger.mm` and the feedback validator in
//! `AgentNativeWAL.mm`. The row-level operations are built on these in the
//! same view/effect shape as [`crate::round_journal`].

use crate::canonical::{canonical_json, hash_bytes, hash_json};
use crate::schema::*;
use crate::store::StoreError;
use crate::strict_json::parse_arguments;
use serde_json::{json, Map, Value};
use unicode_normalization::UnicodeNormalization;

/// `DSHAgentNativeWALMaxSingleWriteBytes`.
pub const MAX_SINGLE_WRITE_BYTES: u64 = 32 * 1024;
/// `DSHAgentNativeWALMaxBatchWriteBytes`.
pub const MAX_BATCH_WRITE_BYTES: u64 = 512 * 1024;
/// `DSHAgentNativeWALMaxAttemptWriteBytes`.
pub const MAX_ATTEMPT_WRITE_BYTES: u64 = 4 * 1024 * 1024;
/// `DSHAgentNativeWALMaxLedgerRowsPerAttempt`.
pub const MAX_LEDGER_ROWS_PER_ATTEMPT: usize = 128;
const MAX_ROUND_INDEX: u64 = 7;
const MAX_CALL_INDEX: u64 = 15;
const MAX_FEEDBACK_ENCODED_BYTES: usize = 64 * 1024;

pub(crate) fn get<'a>(value: &'a Value, key: &str) -> Option<&'a Value> {
    value.get(key)
}

pub(crate) fn as_str(value: Option<&Value>) -> Option<&str> {
    match value {
        Some(Value::String(text)) => Some(text.as_str()),
        _ => None,
    }
}

fn string_eq(value: Option<&Value>, expected: &str) -> bool {
    as_str(value) == Some(expected)
}

fn is_bool(value: Option<&Value>) -> bool {
    matches!(value, Some(Value::Bool(_)))
}

fn number_eq(value: Option<&Value>, expected: u64) -> bool {
    value.and_then(Value::as_u64) == Some(expected)
}

// MARK: - Shapes

pub const LOCATOR_KEYS: &[&str] = &[
    "schema_version",
    "task_id",
    "attempt_id",
    "round_id",
    "round_index",
    "call_index",
    "call_id",
    "idempotency_key",
];

pub const ROW_KEYS: &[&str] = &[
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

const CAS_KEYS: &[&str] = &[
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

pub const LEDGER_STATES: &[&str] = &[
    "intent",
    "running",
    "cancel_requested",
    "settled",
    "cancelled",
    "unknown",
    "ambiguous",
];

/// `DSHAgentLedgerLocator`: the complete schema-2 execution locator.
pub fn ledger_locator(value: Option<&Value>) -> bool {
    let Some(map) = exact_keys(value, LOCATOR_KEYS) else {
        return false;
    };
    safe_integer(map.get("schema_version"), 2, false) == Some(2)
        && canonical_uuid(map.get("task_id"))
        && canonical_uuid(map.get("attempt_id"))
        && canonical_uuid(map.get("round_id"))
        && safe_integer(map.get("round_index"), MAX_ROUND_INDEX, true).is_some()
        && safe_integer(map.get("call_index"), MAX_CALL_INDEX, true).is_some()
        && opaque_identifier(map.get("call_id"))
        && canonical_sha256(map.get("idempotency_key"))
}

/// `DSHAgentLedgerCAS`.
pub fn ledger_cas(value: Option<&Value>) -> bool {
    let Some(map) = exact_keys(value, CAS_KEYS) else {
        return false;
    };
    let nullable = |key: &str, check: &dyn Fn(Option<&Value>) -> bool| -> bool {
        let field = map.get(key);
        is_null(field) || check(field)
    };
    safe_integer(map.get("schema_version"), 2, false) == Some(2)
        && ledger_locator(map.get("locator"))
        && safe_integer(map.get("expected_row_revision"), MAX_SAFE_INTEGER, false).is_some()
        && bounded_utf8(map.get("expected_state"), 32, false).is_some()
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

/// `DSHAgentLedgerInsertCAS`.
pub fn ledger_insert_cas(value: Option<&Value>) -> bool {
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
        && ledger_locator(map.get("locator"))
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

/// `DSHAgentReceipt`: the exact redacted execution receipt.
pub fn receipt_shape(value: Option<&Value>) -> bool {
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
    let Some(map) = exact_keys(value, &keys) else {
        return false;
    };
    if safe_integer(map.get("schema_version"), 1, false).is_none()
        || bounded_utf8(map.get("call_id"), 128, false).is_none()
        || bounded_utf8(map.get("name"), 64, false).is_none()
        || !canonical_sha256(map.get("arguments_sha256"))
        || !canonical_sha256(map.get("result_sha256"))
        || safe_integer(map.get("result_bytes"), 32 * 1024 * 1024, true).is_none()
        || safe_integer(map.get("duration_ms"), 24 * 60 * 60 * 1000, true).is_none()
        || !is_bool(map.get("truncated"))
    {
        return false;
    }
    let Some(outcome) = as_str(map.get("outcome")) else {
        return false;
    };
    if !matches!(
        outcome,
        "ok" | "failed" | "denied" | "cancelled" | "ambiguous"
    ) {
        return false;
    }
    let failure = map.get("failure_code");
    let approval = map.get("approval_reference");
    if !(is_null(failure) || failure_code(failure))
        || !(is_null(approval) || bounded_utf8(approval, 256, false).is_some())
    {
        return false;
    }
    (outcome == "ok") == is_null(failure)
}

/// `DSHAgentCanonicalFeedbackBytes`: the exact protected tool message whose
/// content is canonical JSON byte for byte. Returns the content bytes.
pub fn canonical_feedback_bytes(message: Option<&Value>) -> Option<Vec<u8>> {
    let keys = [
        "schema_version",
        "role",
        "round_index",
        "call_id",
        "content",
        "truncated",
    ];
    let map = exact_keys(message, &keys)?;
    if safe_integer(map.get("schema_version"), 1, false).is_none()
        || as_str(map.get("role")) != Some("tool")
        || safe_integer(map.get("round_index"), MAX_ROUND_INDEX, true).is_none()
        || bounded_utf8(map.get("call_id"), 128, false).is_none()
        || bounded_utf8(map.get("content"), MAX_TRANSCRIPT_BYTES as usize, true).is_none()
        || !is_bool(map.get("truncated"))
    {
        return None;
    }
    let content = as_str(map.get("content"))?;
    let object: Value = serde_json::from_str(content).ok()?;
    if !matches!(object, Value::Object(_) | Value::Array(_)) {
        return None;
    }
    let canonical = canonical_json(&object).ok()?;
    (canonical == content.as_bytes()).then_some(canonical)
}

/// `DSHAgentWritePrior`.
pub fn write_prior(value: Option<&Value>) -> bool {
    let Some(Value::Object(map)) = value else {
        return false;
    };
    match as_str(map.get("kind")) {
        Some("absent") => {
            exact_keys(value, &["schema_version", "kind"]).is_some()
                && safe_integer(map.get("schema_version"), 1, false).is_some()
        }
        Some("known") => {
            exact_keys(value, &["schema_version", "kind", "revision"]).is_some()
                && safe_integer(map.get("schema_version"), 1, false).is_some()
                && bounded_utf8(map.get("revision"), 256, false).is_some()
        }
        Some("unknown") => {
            exact_keys(value, &["schema_version", "kind", "failure_code"]).is_some()
                && safe_integer(map.get("schema_version"), 1, false).is_some()
                && failure_code(map.get("failure_code"))
        }
        _ => false,
    }
}

/// `DSHAgentRelativePathArgument`: a bounded, NFC, workspace-relative path
/// without `..`, empty components, backslashes or NUL. Returns the path.
pub fn relative_path_argument(value: Option<&Value>, allow_empty: bool) -> Option<&str> {
    let path = bounded_utf8(value, 512, allow_empty)?;
    if path.starts_with('/')
        || path.contains('\\')
        || path.contains('\0')
        || path.nfc().ne(path.chars())
    {
        return None;
    }
    for component in path.split('/') {
        if component == ".." || (component.is_empty() && !(allow_empty && path.is_empty())) {
            return None;
        }
    }
    Some(path)
}

/// `DSHAgentRawArgumentsBindIntent`: recomputes operation-specific digests
/// from the raw arguments and checks them against the intent's precondition.
pub fn raw_arguments_bind_intent(
    arguments_json: Option<&Value>,
    intent: &Value,
) -> Result<(), StoreError> {
    if !intent.is_object() {
        return Err(StoreError::InvalidArgument);
    }
    let arguments = as_str(arguments_json)
        .and_then(parse_arguments)
        .ok_or(StoreError::InvalidArgument)?;
    let arguments_value = Value::Object(arguments.clone());
    let Some(name) = as_str(get(intent, "name")) else {
        return Err(StoreError::InvalidArgument);
    };
    let Some(precondition) = get(intent, "precondition").filter(|p| p.is_object()) else {
        return Err(StoreError::InvalidArgument);
    };
    let Some(kind) = as_str(get(precondition, "kind")) else {
        return Err(StoreError::InvalidArgument);
    };
    if name == crate::user_question::NAME {
        return if crate::user_question::question_shape(Some(precondition))
            && precondition["question"] == arguments_value
        {
            Ok(())
        } else {
            Err(StoreError::Conflict)
        };
    }
    if crate::assistant_tools::is_assistant(name) {
        if !crate::assistant_tools::arguments_valid(name, &arguments)
            || !crate::assistant_tools::precondition_shape(Some(precondition))
            || kind != name
        {
            return Err(StoreError::InvalidArgument);
        }
        return if crate::schema::arguments_sha256(get(intent, "name"), arguments_json).as_deref()
            == as_str(get(precondition, "arguments_sha256"))
        {
            Ok(())
        } else {
            Err(StoreError::Conflict)
        };
    }
    if crate::runtime_tools::is_runtime(name) {
        if !crate::runtime_tools::arguments_valid(name, &arguments)
            || !crate::runtime_tools::precondition_shape(Some(precondition))
            || kind != name
        {
            return Err(StoreError::InvalidArgument);
        }
        return if crate::schema::arguments_sha256(get(intent, "name"), arguments_json).as_deref()
            == as_str(get(precondition, "arguments_sha256"))
        {
            Ok(())
        } else {
            Err(StoreError::Conflict)
        };
    }
    match name {
        "write_file" => {
            let by_revision = exact_keys(
                Some(&arguments_value),
                &["path", "content", "expected_revision"],
            )
            .is_some();
            let by_prior = exact_keys(
                Some(&arguments_value),
                &["path", "content", "expected_prior"],
            )
            .is_some();
            // The third shape `write_expected_prior` documents: a call that
            // names neither expectation asserts the file is absent. Only this
            // reading of a write had held out for one of the other two, so a
            // model's plain {path, content} write was refused as invalid here
            // after the tool had already accepted and previewed it.
            let bare = exact_keys(Some(&arguments_value), &["path", "content"]).is_some();
            let Some(content) = as_str(arguments.get("content")) else {
                return Err(StoreError::InvalidArgument);
            };
            if (!by_revision && !by_prior && !bare) || kind != "write_file" {
                return Err(StoreError::InvalidArgument);
            }
            let argument_prior = if bare {
                json!({ "schema_version": 1, "kind": "absent" })
            } else if let Some(revision) = arguments.get("expected_revision") {
                if revision.is_null() {
                    json!({ "schema_version": 1, "kind": "absent" })
                } else if let Some(text) = bounded_utf8(Some(revision), 256, false) {
                    json!({ "schema_version": 1, "kind": "known", "revision": text })
                } else {
                    return Err(StoreError::InvalidArgument);
                }
            } else {
                let prior = arguments.get("expected_prior");
                if !write_prior(prior) {
                    return Err(StoreError::InvalidArgument);
                }
                prior.cloned().unwrap_or(Value::Null)
            };
            let Some(path) = relative_path_argument(arguments.get("path"), false) else {
                return Err(StoreError::InvalidArgument);
            };
            if content.len() as u64 > MAX_SINGLE_WRITE_BYTES {
                return Err(StoreError::InvalidArgument);
            }
            let path_digest = hash_bytes("relative-path", path.as_bytes());
            let content_digest = hash_bytes("file-content", content.as_bytes());
            if path_digest.as_deref() != as_str(get(precondition, "relative_path_sha256"))
                || content_digest.as_deref() != as_str(get(precondition, "content_sha256"))
                || !number_eq(get(precondition, "content_bytes"), content.len() as u64)
                || get(precondition, "prior") != Some(&argument_prior)
            {
                return Err(StoreError::Conflict);
            }
            Ok(())
        }
        "start_guest_cgi" | "stop_guest_cgi" => {
            let mut expected = arguments.clone();
            expected.insert("schema_version".to_string(), Value::from(1u64));
            expected.insert("kind".to_string(), Value::from(name));
            if Value::Object(expected) != *precondition {
                return Err(StoreError::Conflict);
            }
            Ok(())
        }
        "git_commit" => {
            if exact_keys(Some(&arguments_value), &["message"]).is_none() || kind != "git_commit" {
                return Err(StoreError::InvalidArgument);
            }
            let Some(message) = as_str(arguments.get("message")) else {
                return Err(StoreError::InvalidArgument);
            };
            if message.is_empty() || message.len() > 500 {
                return Err(StoreError::InvalidArgument);
            }
            let digest = hash_bytes("commit-message", message.as_bytes());
            if digest.as_deref() != as_str(get(precondition, "message_sha256"))
                || !number_eq(get(precondition, "message_bytes"), message.len() as u64)
            {
                return Err(StoreError::Conflict);
            }
            Ok(())
        }
        "read_file" => {
            if exact_keys(Some(&arguments_value), &["path"]).is_none()
                || relative_path_argument(arguments.get("path"), false).is_none()
            {
                return Err(StoreError::InvalidArgument);
            }
            Ok(())
        }
        "list_dir" => {
            let empty = Value::from("");
            let path = if arguments.is_empty() {
                Some(&empty)
            } else {
                arguments.get("path")
            };
            if (!arguments.is_empty() && exact_keys(Some(&arguments_value), &["path"]).is_none())
                || relative_path_argument(path, true).is_none()
            {
                return Err(StoreError::InvalidArgument);
            }
            Ok(())
        }
        "git_push" | "git_status" => {
            if !arguments.is_empty() || kind != name {
                return Err(StoreError::InvalidArgument);
            }
            Ok(())
        }
        _ => Ok(()),
    }
}

fn git_identity(value: Option<&Value>) -> bool {
    let Some(map) = exact_keys(
        value,
        &[
            "schema_version",
            "name",
            "email",
            "timestamp_seconds",
            "timezone_offset",
        ],
    ) else {
        return false;
    };
    let offset = as_str(map.get("timezone_offset")).unwrap_or_default();
    safe_integer(map.get("schema_version"), 1, false).is_some()
        && as_str(map.get("name")) == Some("Rish Agent")
        && as_str(map.get("email")) == Some("agent@rish.local")
        && safe_integer(map.get("timestamp_seconds"), MAX_SAFE_INTEGER, true).is_some()
        && offset.len() == 5
        && (offset.starts_with('+') || offset.starts_with('-'))
        && offset[1..].bytes().all(|b| b.is_ascii_digit())
}

fn hex_object_id(value: Option<&Value>, length: usize) -> bool {
    match as_str(value) {
        Some(text) => {
            text.len() == length && text.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
        }
        None => false,
    }
}

/// `DSHAgentPrecondition`: the closed per-tool precondition union.
pub fn precondition_shape(value: Option<&Value>) -> bool {
    if value.is_some_and(|value| value["kind"] == crate::user_question::NAME) {
        return crate::user_question::question_shape(value);
    }
    let Some(Value::Object(map)) = value else {
        return false;
    };
    let Some(kind) = as_str(map.get("kind")) else {
        return false;
    };
    let schema1 = || safe_integer(map.get("schema_version"), 1, false).is_some();
    if crate::assistant_tools::is_assistant(kind) {
        return crate::assistant_tools::precondition_shape(value);
    }
    if crate::runtime_tools::is_runtime(kind) {
        return crate::runtime_tools::precondition_shape(value);
    }
    match kind {
        "read_file" => {
            exact_keys(value, &["schema_version", "kind", "source_revision"]).is_some()
                && schema1()
                && bounded_utf8(map.get("source_revision"), 256, false).is_some()
        }
        "list_dir" => {
            exact_keys(
                value,
                &["schema_version", "kind", "directory_fingerprint_sha256"],
            )
            .is_some()
                && schema1()
                && canonical_sha256(map.get("directory_fingerprint_sha256"))
        }
        "write_file" => {
            let mut keys = vec![
                "schema_version",
                "kind",
                "relative_path_sha256",
                "prior",
                "content_sha256",
                "content_bytes",
            ];
            let schema3 = safe_integer(map.get("schema_version"), 3, false) == Some(3);
            if schema3 {
                keys.push("parent_plan");
            }
            exact_keys(value, &keys).is_some()
                && (safe_integer(map.get("schema_version"), 2, false) == Some(2)
                    || (schema3
                        && crate::write_parent_plan::valid(map.get("parent_plan"))
                        && map.get("prior").and_then(|p| p.get("kind")) == Some(&json!("absent"))))
                && canonical_sha256(map.get("relative_path_sha256"))
                && write_prior(map.get("prior"))
                && canonical_sha256(map.get("content_sha256"))
                && safe_integer(map.get("content_bytes"), MAX_SINGLE_WRITE_BYTES, true).is_some()
        }
        "git_commit" => {
            let keys = [
                "schema_version",
                "kind",
                "object_format",
                "pre_head_oid",
                "ordered_parent_oids",
                "staged_index_sha256",
                "tree_oid",
                "author",
                "committer",
                "message_blob_ref",
                "message_sha256",
                "message_bytes",
                "encoding_header",
                "signature_policy",
                "extra_headers",
                "stage_all",
                "commit_payload_sha256",
                "expected_commit_oid",
            ];
            let Some(Value::Array(parents)) = map.get("ordered_parent_oids") else {
                return false;
            };
            let Some(Value::Array(extra_headers)) = map.get("extra_headers") else {
                return false;
            };
            let format = as_str(map.get("object_format"));
            let pre_head = map.get("pre_head_oid");
            let encoding = map.get("encoding_header");
            if exact_keys(value, &keys).is_none()
                || safe_integer(map.get("schema_version"), 2, false) != Some(2)
                || !matches!(format, Some("sha1" | "sha256"))
                || !(is_null(pre_head) || bounded_utf8(pre_head, 128, false).is_some())
                || parents.len() > 1
                || !canonical_sha256(map.get("staged_index_sha256"))
                || !git_identity(map.get("author"))
                || !git_identity(map.get("committer"))
                || bounded_utf8(map.get("message_blob_ref"), 256, false).is_none()
                || !canonical_sha256(map.get("message_sha256"))
                || safe_integer(map.get("message_bytes"), 500, false).is_none()
                || !(is_null(encoding) || as_str(encoding) == Some("UTF-8"))
                || as_str(map.get("signature_policy")) != Some("unsigned")
                || !extra_headers.is_empty()
                || map.get("stage_all") != Some(&Value::Bool(true))
                || !canonical_sha256(map.get("commit_payload_sha256"))
                || bounded_utf8(map.get("expected_commit_oid"), 128, false).is_none()
            {
                return false;
            }
            let oid_length = if format == Some("sha1") { 40 } else { 64 };
            if !parents
                .iter()
                .all(|parent| hex_object_id(Some(parent), oid_length))
            {
                return false;
            }
            if is_null(pre_head) {
                if !parents.is_empty() {
                    return false;
                }
            } else if !hex_object_id(pre_head, oid_length)
                || parents.len() != 1
                || parents.first() != pre_head
            {
                return false;
            }
            hex_object_id(map.get("tree_oid"), oid_length)
                && hex_object_id(map.get("expected_commit_oid"), oid_length)
        }
        "git_push" => {
            let pre_remote = map.get("pre_remote_oid");
            exact_keys(
                value,
                &[
                    "schema_version",
                    "kind",
                    "remote",
                    "remote_ref",
                    "pre_remote_oid",
                    "target_oid",
                ],
            )
            .is_some()
                && schema1()
                && as_str(map.get("remote")) == Some("origin")
                && bounded_utf8(map.get("remote_ref"), 256, false).is_some()
                && (is_null(pre_remote) || bounded_utf8(pre_remote, 128, false).is_some())
                && bounded_utf8(map.get("target_oid"), 128, false).is_some()
        }
        "git_status" => {
            let head = map.get("head_oid");
            exact_keys(value, &["schema_version", "kind", "head_oid"]).is_some()
                && schema1()
                && (is_null(head) || bounded_utf8(head, 128, false).is_some())
        }
        "start_guest_cgi" => {
            let keys = [
                "schema_version",
                "kind",
                "index_path",
                "index_sha256",
                "backend_path",
                "backend_sha256",
                "initial_data_path",
                "initial_data_sha256",
            ];
            let initial_path = map.get("initial_data_path");
            let initial_sha = map.get("initial_data_sha256");
            exact_keys(value, &keys).is_some()
                && safe_integer(map.get("schema_version"), 1, false) == Some(1)
                && bounded_utf8(map.get("index_path"), 1024, false).is_some()
                && canonical_sha256(map.get("index_sha256"))
                && bounded_utf8(map.get("backend_path"), 1024, false).is_some()
                && canonical_sha256(map.get("backend_sha256"))
                && ((is_null(initial_path) && is_null(initial_sha))
                    || (bounded_utf8(initial_path, 1024, false).is_some()
                        && canonical_sha256(initial_sha)))
        }
        "stop_guest_cgi" => {
            exact_keys(value, &["schema_version", "kind", "service_id"]).is_some()
                && safe_integer(map.get("schema_version"), 1, false) == Some(1)
                && canonical_uuid(map.get("service_id"))
        }
        _ => false,
    }
}

/// `DSHAgentSettledFacts`.
pub fn settled_facts_shape(value: Option<&Value>) -> bool {
    if value.is_some_and(|value| value["kind"] == crate::user_question::NAME) {
        return crate::user_question::facts_shape(value);
    }
    let Some(Value::Object(map)) = value else {
        return false;
    };
    let Some(kind) = as_str(map.get("kind")) else {
        return false;
    };
    let schema1 = || safe_integer(map.get("schema_version"), 1, false).is_some();
    if crate::assistant_tools::is_assistant(kind) {
        return crate::assistant_tools::settled_facts_shape(value);
    }
    if crate::runtime_tools::is_runtime(kind) {
        return crate::runtime_tools::settled_facts_shape(value);
    }
    match kind {
        "start_guest_cgi" | "stop_guest_cgi" => {
            let expected_status = if kind == "start_guest_cgi" {
                "running"
            } else {
                "stopped"
            };
            exact_keys(value, &["schema_version", "kind", "service_id", "status"]).is_some()
                && safe_integer(map.get("schema_version"), 1, false) == Some(1)
                && canonical_uuid(map.get("service_id"))
                && as_str(map.get("status")) == Some(expected_status)
        }
        "read_file" => {
            exact_keys(value, &["schema_version", "kind", "source_revision"]).is_some()
                && schema1()
                && bounded_utf8(map.get("source_revision"), 256, false).is_some()
        }
        "list_dir" => {
            exact_keys(
                value,
                &["schema_version", "kind", "directory_fingerprint_sha256"],
            )
            .is_some()
                && schema1()
                && canonical_sha256(map.get("directory_fingerprint_sha256"))
        }
        "write_file" => {
            exact_keys(
                value,
                &[
                    "schema_version",
                    "kind",
                    "actual_revision",
                    "content_sha256",
                ],
            )
            .is_some()
                && schema1()
                && bounded_utf8(map.get("actual_revision"), 256, false).is_some()
                && canonical_sha256(map.get("content_sha256"))
        }
        "git_commit" => {
            exact_keys(value, &["schema_version", "kind", "actual_commit_oid"]).is_some()
                && schema1()
                && bounded_utf8(map.get("actual_commit_oid"), 128, false).is_some()
        }
        "git_push" => {
            exact_keys(value, &["schema_version", "kind", "actual_remote_oid"]).is_some()
                && schema1()
                && bounded_utf8(map.get("actual_remote_oid"), 128, false).is_some()
        }
        "git_status" => {
            let head = map.get("head_oid");
            exact_keys(value, &["schema_version", "kind", "head_oid"]).is_some()
                && schema1()
                && (is_null(head) || bounded_utf8(head, 128, false).is_some())
        }
        _ => false,
    }
}

/// `DSHAgentSettledFactsMatchFeedback`: the settled facts a caller supplies
/// must restate what the protected feedback payload reports.
pub fn settled_facts_match_feedback(row: &Value, feedback: &Value, facts: Option<&Value>) -> bool {
    if row["name"] == crate::user_question::NAME && feedback["outcome"] == "ok" {
        return facts.is_some_and(|facts| crate::user_question::facts_match(row, feedback, facts));
    }
    let outcome = as_str(get(feedback, "outcome"));
    if outcome != Some("ok") {
        return is_null(facts);
    }
    let Some(facts) = facts.filter(|f| !f.is_null()) else {
        return false;
    };
    let null = Value::Null;
    let payload = get(feedback, "payload").unwrap_or(&null);
    let precondition = get(row, "precondition").unwrap_or(&null);
    let kind = as_str(get(precondition, "kind"));
    let name = as_str(get(row, "name"));
    if name.is_some_and(crate::assistant_tools::is_assistant) {
        return crate::assistant_tools::facts_match_feedback(row, feedback, facts);
    }
    if name.is_some_and(crate::runtime_tools::is_runtime) {
        return crate::runtime_tools::facts_match_feedback(row, feedback, facts);
    }
    match (kind, name) {
        (Some("read_file"), Some("read_file")) => {
            get(facts, "source_revision") == get(payload, "revision")
        }
        (Some("write_file"), Some("write_file")) => {
            get(facts, "actual_revision") == get(payload, "revision")
                && get(payload, "bytes") == get(precondition, "content_bytes")
        }
        (Some("git_commit"), Some("git_commit")) => {
            get(facts, "actual_commit_oid") == get(payload, "commit_oid")
                && get(payload, "tree_oid") == get(precondition, "tree_oid")
        }
        (Some("git_push"), Some("git_push")) => {
            get(facts, "actual_remote_oid") == get(payload, "pushed_oid")
                && get(payload, "remote_ref") == get(precondition, "remote_ref")
        }
        (Some("git_status"), Some("git_status")) => {
            get(facts, "head_oid") == get(payload, "head_oid")
        }
        (Some("start_guest_cgi" | "stop_guest_cgi"), _) => {
            get(facts, "service_id") == get(payload, "service_id")
                && get(facts, "status") == get(payload, "status")
        }
        _ => true,
    }
}

/// `DSHAgentLedgerRow`: the full persisted-row invariant.
pub fn ledger_row(row: &Value) -> bool {
    let Some(map) = exact_keys(Some(row), ROW_KEYS) else {
        return false;
    };
    let null = Value::Null;
    let locator = map.get("locator").unwrap_or(&null);
    let precondition = map.get("precondition").unwrap_or(&null);
    if safe_integer(map.get("schema_version"), 2, false) != Some(2)
        || !ledger_locator(Some(locator))
        || safe_integer(map.get("row_revision"), MAX_SAFE_INTEGER, false).is_none()
        || !canonical_sha256(map.get("root_fingerprint_sha256"))
        || safe_integer(map.get("binding_revision"), MAX_SAFE_INTEGER, false).is_none()
        || !transcript_reference(map.get("transcript_before"))
        || tool_name_well_formed(map.get("name")).is_none()
        || !canonical_sha256(map.get("arguments_sha256"))
        || !precondition_shape(Some(precondition))
        || map.get("name") != get(precondition, "kind")
        || safe_integer(
            map.get("reserved_write_bytes"),
            MAX_SINGLE_WRITE_BYTES,
            true,
        )
        .is_none()
        || !canonical_timestamp(map.get("created_at"))
        || !canonical_timestamp(map.get("updated_at"))
    {
        return false;
    }
    let expected_key = idempotency_key_for_locator(
        Some(locator),
        map.get("root_fingerprint_sha256"),
        map.get("arguments_sha256"),
    );
    if expected_key.as_deref() != as_str(get(locator, "idempotency_key")) {
        return false;
    }
    let kind = as_str(get(precondition, "kind")).unwrap_or_default();
    if (crate::runtime_tools::is_runtime(kind) || crate::assistant_tools::is_assistant(kind))
        && map.get("arguments_sha256") != get(precondition, "arguments_sha256")
    {
        return false;
    }
    let state = as_str(map.get("state")).unwrap_or_default();
    let reserved = map.get("reserved_write_bytes");
    if kind == "write_file"
        && reserved != get(precondition, "content_bytes")
        && !((state == "intent" || state == "cancelled") && number_eq(reserved, 0))
    {
        return false;
    }
    if kind != "write_file" && !number_eq(reserved, 0) {
        return false;
    }
    if !LEDGER_STATES.contains(&state) {
        return false;
    }
    if kind == "write_file"
        && as_str(get(precondition, "prior").and_then(|p| get(p, "kind"))) == Some("unknown")
        && !matches!(state, "intent" | "cancelled" | "unknown")
    {
        return false;
    }
    let owner = map.get("owner");
    let facts = map.get("settled_facts");
    let after = map.get("transcript_after");
    let receipt = map.get("receipt");
    let (owner_null, facts_null, after_null, receipt_null) = (
        is_null(owner),
        is_null(facts),
        is_null(after),
        is_null(receipt),
    );
    if !owner_null
        && (!owner_shape(owner) || owner.and_then(|o| get(o, "task_id")) != get(locator, "task_id"))
    {
        return false;
    }
    if !facts_null && !settled_facts_shape(facts) {
        return false;
    }
    if !after_null && !transcript_reference(after) {
        return false;
    }
    if !receipt_null && !receipt_shape(receipt) {
        return false;
    }
    let receipt_binds_row = || {
        let receipt = receipt.unwrap_or(&null);
        get(receipt, "call_id") == get(locator, "call_id")
            && get(receipt, "name") == map.get("name")
            && get(receipt, "arguments_sha256") == map.get("arguments_sha256")
    };
    match state {
        "intent" => owner_null && facts_null && after_null && receipt_null,
        "running" | "cancel_requested" => !owner_null && facts_null && after_null && receipt_null,
        "settled" => {
            if !owner_null || after_null || receipt_null || !receipt_binds_row() {
                return false;
            }
            let receipt = receipt.unwrap_or(&null);
            let outcome = as_str(get(receipt, "outcome"));
            if !matches!(outcome, Some("ok" | "failed" | "denied")) {
                return false;
            }
            if outcome != Some("ok") {
                return facts_null;
            }
            let Some(facts) = facts.filter(|f| !f.is_null()) else {
                return false;
            };
            if get(facts, "kind") != get(precondition, "kind") {
                return false;
            }
            if crate::assistant_tools::is_assistant(kind) {
                return crate::assistant_tools::facts_bind_row(row, facts);
            }
            if crate::runtime_tools::is_runtime(kind) {
                return get(facts, "arguments_sha256") == get(precondition, "arguments_sha256");
            }
            match kind {
                "write_file" => {
                    get(facts, "content_sha256") == get(precondition, "content_sha256")
                        && bounded_utf8(get(facts, "actual_revision"), 256, false).is_some()
                }
                "git_commit" => {
                    get(facts, "actual_commit_oid") == get(precondition, "expected_commit_oid")
                }
                "git_push" => get(facts, "actual_remote_oid") == get(precondition, "target_oid"),
                "stop_guest_cgi" => get(facts, "service_id") == get(precondition, "service_id"),
                "read_file" => {
                    get(facts, "source_revision") == get(precondition, "source_revision")
                }
                "list_dir" => {
                    get(facts, "directory_fingerprint_sha256")
                        == get(precondition, "directory_fingerprint_sha256")
                }
                _ => true,
            }
        }
        "cancelled" => {
            owner_null
                && facts_null
                && !after_null
                && !receipt_null
                && string_eq(get(receipt.unwrap_or(&null), "outcome"), "cancelled")
                && receipt_binds_row()
                && string_eq(
                    get(receipt.unwrap_or(&null), "failure_code"),
                    "E_AGENT_CANCELLED",
                )
        }
        "unknown" => owner_null && facts_null && receipt_null,
        _ => {
            owner_null
                && facts_null
                && !after_null
                && !receipt_null
                && string_eq(get(receipt.unwrap_or(&null), "outcome"), "ambiguous")
                && receipt_binds_row()
                && string_eq(
                    get(receipt.unwrap_or(&null), "failure_code"),
                    "E_AGENT_EXECUTION_AMBIGUOUS",
                )
        }
    }
}

/// `DSHAgentLedgerRowExecutable`.
pub fn ledger_row_executable(row: &Value) -> bool {
    let null = Value::Null;
    let precondition = get(row, "precondition").unwrap_or(&null);
    if as_str(get(precondition, "kind")) == Some("write_file") {
        if as_str(get(precondition, "prior").and_then(|p| get(p, "kind"))) == Some("unknown") {
            return false;
        }
        if get(row, "reserved_write_bytes") != get(precondition, "content_bytes") {
            return false;
        }
    }
    true
}

/// `DSHAgentLedgerTranscriptBound`: the row's `transcript_before` must name
/// a transcript row of the same attempt and root that has not moved
/// backwards. `transcript` is the row the facade found by `transcript_ref`.
pub fn transcript_bound(transcript: Option<&Value>, row: &Value) -> Result<(), StoreError> {
    let null = Value::Null;
    let before = get(row, "transcript_before").unwrap_or(&null);
    let locator = get(row, "locator").unwrap_or(&null);
    let Some(transcript) =
        transcript.filter(|t| get(t, "transcript_ref") == get(before, "transcript_ref"))
    else {
        return Err(StoreError::NotFound);
    };
    let generation = get(transcript, "generation")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let before_generation = get(before, "generation")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    if get(transcript, "attempt_id") != get(locator, "attempt_id")
        || get(transcript, "root_fingerprint_sha256") != get(row, "root_fingerprint_sha256")
        || generation < before_generation
        || (get(transcript, "generation") == get(before, "generation")
            && (get(transcript, "transcript_sha256") != get(before, "transcript_sha256")
                || get(transcript, "transcript_bytes") != get(before, "transcript_bytes")))
    {
        return Err(StoreError::Conflict);
    }
    Ok(())
}

/// `DSHAgentCASMatchesRow` (ledger flavour).
pub fn cas_matches_row(row: &Value, cas: &Value) -> bool {
    let null = Value::Null;
    let before = get(row, "transcript_before").unwrap_or(&null);
    if !ledger_cas(Some(cas))
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

/// `DSHAgentLedgerTransitionAllowed`.
pub fn transition_allowed(from: Option<&str>, to: Option<&str>, allow_reconcile: bool) -> bool {
    let (Some(from), Some(to)) = (from, to) else {
        return false;
    };
    if from == to {
        return true;
    }
    let reconcile_target = allow_reconcile && matches!(to, "unknown" | "ambiguous");
    match from {
        "intent" => matches!(to, "running" | "cancelled"),
        "running" => reconcile_target || matches!(to, "cancel_requested" | "settled"),
        "cancel_requested" => reconcile_target || matches!(to, "settled" | "cancelled"),
        "settled" | "cancelled" | "unknown" | "ambiguous" => {
            allow_reconcile && matches!(to, "settled" | "cancelled" | "unknown" | "ambiguous")
        }
        _ => false,
    }
}

/// `DSHAgentLedgerPatchKeysAllowed`.
pub fn patch_keys_allowed(patch: &Value) -> bool {
    match patch {
        Value::Object(map) => map.keys().all(|key| {
            matches!(
                key.as_str(),
                "state" | "owner" | "settled_facts" | "transcript_after" | "receipt"
            )
        }),
        _ => false,
    }
}

// MARK: - Protected tool feedback (DSHAgentValidateNativeToolFeedbackString)

fn guest_service_url(value: Option<&Value>) -> bool {
    let Some(text) = bounded_utf8(value, 128, false) else {
        return false;
    };
    let Some(rest) = text.strip_prefix("http://127.0.0.1:") else {
        return false;
    };
    let Some(port) = rest.strip_suffix('/') else {
        return false;
    };
    if port.is_empty() || !port.bytes().all(|b| b.is_ascii_digit()) {
        return false;
    }
    matches!(port.parse::<u32>(), Ok(1..=65535))
}

/// `DSHAgentValidateNativeToolFeedbackString`: the closed redacted
/// NativeAgentToolFeedbackV1 union as canonical JSON text.
pub fn feedback_string_valid(text: &str) -> Result<(), StoreError> {
    if text.len() as u64 > MAX_TRANSCRIPT_BYTES {
        return Err(StoreError::InvalidArgument);
    }
    let object: Value = serde_json::from_str(text).map_err(|_| StoreError::InvalidArgument)?;
    let canonical = canonical_json(&object).map_err(|_| StoreError::InvalidArgument)?;
    let Some(map) = exact_keys(
        Some(&object),
        &["schema_version", "name", "outcome", "payload"],
    ) else {
        return Err(StoreError::InvalidArgument);
    };
    let Some(Value::Object(payload_map)) = map.get("payload") else {
        return Err(StoreError::InvalidArgument);
    };
    let payload = map.get("payload").expect("checked");
    if canonical != text.as_bytes()
        || safe_integer(map.get("schema_version"), 1, false).is_none()
        || bounded_utf8(map.get("name"), 64, false).is_none()
    {
        return Err(StoreError::InvalidArgument);
    }
    let name = as_str(map.get("name")).expect("checked");
    let outcome = as_str(map.get("outcome"));
    if (name == "list_dir"
        || crate::runtime_tools::is_runtime(name)
        || crate::assistant_tools::is_assistant(name))
        && text.len() > MAX_FEEDBACK_ENCODED_BYTES
    {
        return Err(StoreError::Capacity);
    }
    if !name
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-'))
    {
        return Err(StoreError::InvalidArgument);
    }
    if matches!(
        outcome,
        Some("failed" | "denied" | "cancelled" | "ambiguous")
    ) {
        let reason = payload_map.get("reason");
        let reason_ok = reason.is_none()
            || (exact_keys(Some(payload), &["schema_version", "failure_code", "reason"]).is_some()
                && bounded_utf8(reason, 64, false)
                    .is_some_and(|r| r.bytes().all(|b| b.is_ascii_lowercase() || b == b'_')));
        let shape_ok = if reason.is_some() {
            reason_ok
        } else {
            exact_keys(Some(payload), &["schema_version", "failure_code"]).is_some()
        };
        let mut valid_failure = shape_ok
            && safe_integer(payload_map.get("schema_version"), 1, false).is_some()
            && failure_code(payload_map.get("failure_code"));
        if !valid_failure
            && outcome == Some("denied")
            && as_str(payload_map.get("failure_code")) == Some("E_AGENT_DENIED_BY_USER")
        {
            let user_message = payload_map.get("user_message");
            valid_failure = exact_keys(
                Some(payload),
                &["schema_version", "failure_code", "user_message"],
            )
            .is_some()
                && safe_integer(payload_map.get("schema_version"), 1, false).is_some()
                && (is_null(user_message) || bounded_utf8(user_message, 2000, true).is_some());
        }
        valid_failure = valid_failure
            || (outcome == Some("failed")
                && crate::runtime_tools::diagnostic_failure(name, payload));
        return if valid_failure {
            Ok(())
        } else {
            Err(StoreError::InvalidArgument)
        };
    }
    if outcome != Some("ok") || safe_integer(payload_map.get("schema_version"), 1, false).is_none()
    {
        return Err(StoreError::InvalidArgument);
    }
    let ok = match name {
        crate::user_question::NAME => {
            exact_keys(Some(payload), &["schema_version", "question", "response"]).is_some()
                && crate::user_question::response_valid(&payload["question"], &payload["response"])
        }
        name if crate::assistant_tools::is_assistant(name) => {
            crate::assistant_tools::success_payload(name, payload)
        }
        name if crate::runtime_tools::is_runtime(name) => {
            crate::runtime_tools::success_payload(name, payload)
        }
        "list_dir" => {
            let Some(Value::Array(entries)) = payload_map.get("entries") else {
                return Err(StoreError::InvalidArgument);
            };
            if exact_keys(Some(payload), &["schema_version", "entries", "truncated"]).is_none()
                || entries.len() > 1000
                || !is_bool(payload_map.get("truncated"))
            {
                return Err(StoreError::InvalidArgument);
            }
            entries.iter().all(|entry| {
                exact_keys(Some(entry), &["schema_version", "name", "type", "revision"]).is_some()
                    && safe_integer(get(entry, "schema_version"), 1, false).is_some()
                    && bounded_utf8(get(entry, "name"), 4096, false).is_some()
                    && matches!(as_str(get(entry, "type")), Some("file" | "directory"))
                    && bounded_utf8(get(entry, "revision"), 256, false).is_some()
            })
        }
        "read_file" => {
            if text.len() > MAX_FEEDBACK_ENCODED_BYTES {
                return Err(StoreError::Capacity);
            }
            let sha = payload_map.get("sha256");
            let keys: &[&str] = if sha.is_none() {
                &["schema_version", "content", "revision", "truncated"]
            } else {
                &[
                    "schema_version",
                    "content",
                    "revision",
                    "truncated",
                    "sha256",
                ]
            };
            exact_keys(Some(payload), keys).is_some()
                && (sha.is_none()
                    || (canonical_sha256(sha)
                        && payload_map.get("truncated") != Some(&Value::Bool(true))))
                && bounded_utf8(payload_map.get("content"), MAX_FEEDBACK_ENCODED_BYTES, true)
                    .is_some()
                && bounded_utf8(payload_map.get("revision"), 256, false).is_some()
                && is_bool(payload_map.get("truncated"))
        }
        "write_file" => {
            let sha = payload_map.get("sha256");
            let keys: &[&str] = if sha.is_none() {
                &["schema_version", "bytes", "revision"]
            } else {
                &["schema_version", "bytes", "revision", "sha256"]
            };
            exact_keys(Some(payload), keys).is_some()
                && (sha.is_none() || canonical_sha256(sha))
                && safe_integer(payload_map.get("bytes"), MAX_SINGLE_WRITE_BYTES, true).is_some()
                && bounded_utf8(payload_map.get("revision"), 256, false).is_some()
        }
        "start_guest_cgi" | "stop_guest_cgi" => {
            let start = name == "start_guest_cgi";
            let keys: &[&str] = if start {
                &["schema_version", "status", "service_id", "url"]
            } else {
                &["schema_version", "status", "service_id"]
            };
            if exact_keys(Some(payload), keys).is_none()
                || !canonical_uuid(payload_map.get("service_id"))
                || as_str(payload_map.get("status"))
                    != Some(if start { "running" } else { "stopped" })
            {
                // The ObjC validator returns NO here without setting a code;
                // callers map that to the argument error they were given.
                return Err(StoreError::InvalidArgument);
            }
            !start || guest_service_url(payload_map.get("url"))
        }
        "git_status" => {
            let branch = payload_map.get("branch");
            let head = payload_map.get("head_oid");
            exact_keys(
                Some(payload),
                &[
                    "schema_version",
                    "branch",
                    "head_oid",
                    "clean",
                    "has_conflicts",
                    "entry_count",
                ],
            )
            .is_some()
                && (is_null(branch) || bounded_utf8(branch, 1024, false).is_some())
                && (is_null(head) || bounded_utf8(head, 128, false).is_some())
                && is_bool(payload_map.get("clean"))
                && is_bool(payload_map.get("has_conflicts"))
                && safe_integer(payload_map.get("entry_count"), 1_000_000, true).is_some()
        }
        "git_commit" => {
            exact_keys(Some(payload), &["schema_version", "commit_oid", "tree_oid"]).is_some()
                && bounded_utf8(payload_map.get("commit_oid"), 128, false).is_some()
                && bounded_utf8(payload_map.get("tree_oid"), 128, false).is_some()
        }
        "git_push" => {
            let remote_oid = payload_map.get("remote_oid");
            let exact = if remote_oid.is_none() {
                exact_keys(
                    Some(payload),
                    &["schema_version", "remote", "remote_ref", "pushed_oid"],
                )
                .is_some()
            } else {
                exact_keys(
                    Some(payload),
                    &[
                        "schema_version",
                        "remote",
                        "remote_ref",
                        "pushed_oid",
                        "remote_oid",
                    ],
                )
                .is_some()
                    && bounded_utf8(remote_oid, 128, false).is_some()
            };
            exact
                && as_str(payload_map.get("remote")) == Some("origin")
                && bounded_utf8(payload_map.get("remote_ref"), 256, false).is_some()
                && bounded_utf8(payload_map.get("pushed_oid"), 128, false).is_some()
        }
        _ => false,
    };
    if ok {
        Ok(())
    } else {
        Err(StoreError::InvalidArgument)
    }
}

/// `DSHAgentHJ(@"agent-transcript", …)` over an appended message list:
/// returns the new reference `{generation, sha256, bytes}` or `Capacity`
/// when the canonical transcript exceeds the WAL bound.
pub fn transcript_digest(
    transcript: &Value,
    messages: &[Value],
    generation: u64,
) -> Result<(String, u64), StoreError> {
    let input = json!({
        "schema_version": 1,
        "transcript_ref": get(transcript, "transcript_ref"),
        "attempt_id": get(transcript, "attempt_id"),
        "root_fingerprint_sha256": get(transcript, "root_fingerprint_sha256"),
        "generation": generation,
        "messages": messages,
    });
    let bytes = canonical_json(&input).map_err(|_| StoreError::InvalidArgument)?;
    let digest = hash_json("agent-transcript", &input).ok_or(StoreError::InvalidArgument)?;
    if bytes.len() as u64 > MAX_TRANSCRIPT_BYTES {
        return Err(StoreError::Capacity);
    }
    Ok((digest, bytes.len() as u64))
}

/// Builds a transcript reference from its parts.
pub fn transcript_reference_value(
    transcript_ref: Option<&Value>,
    generation: u64,
    digest: &str,
    bytes: u64,
) -> Value {
    json!({
        "schema_version": 1,
        "transcript_ref": transcript_ref,
        "generation": generation,
        "transcript_sha256": digest,
        "transcript_bytes": bytes,
    })
}

/// Convenience: a `Map` clone of an object value (empty for non-objects).
pub(crate) fn object_map(value: &Value) -> Map<String, Value> {
    match value {
        Value::Object(map) => map.clone(),
        _ => Map::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn relative_paths_are_nfc_and_bounded() {
        assert_eq!(
            relative_path_argument(Some(&json!("docs/readme.md")), false),
            Some("docs/readme.md")
        );
        assert_eq!(relative_path_argument(Some(&json!("")), true), Some(""));
        assert_eq!(relative_path_argument(Some(&json!("")), false), None);
        assert_eq!(relative_path_argument(Some(&json!("/abs")), false), None);
        assert_eq!(relative_path_argument(Some(&json!("a/../b")), false), None);
        assert_eq!(relative_path_argument(Some(&json!("a//b")), false), None);
        assert_eq!(relative_path_argument(Some(&json!("a/")), false), None);
        assert_eq!(
            relative_path_argument(Some(&json!("e\u{301}.md")), false),
            None
        );
        assert_eq!(
            relative_path_argument(Some(&json!("\u{e9}.md")), false),
            Some("\u{e9}.md")
        );
    }

    #[test]
    fn feedback_union_is_closed() {
        assert_eq!(
            feedback_string_valid(
                r#"{"name":"read_file","outcome":"ok","payload":{"content":"x","revision":"r1","schema_version":1,"truncated":false},"schema_version":1}"#
            ),
            Ok(())
        );
        // Non-canonical spelling (key order) is refused.
        assert_eq!(
            feedback_string_valid(
                r#"{"schema_version":1,"name":"read_file","outcome":"ok","payload":{"content":"x","revision":"r1","schema_version":1,"truncated":false}}"#
            ),
            Err(StoreError::InvalidArgument)
        );
        assert_eq!(
            feedback_string_valid(
                r#"{"name":"write_file","outcome":"failed","payload":{"failure_code":"E_AGENT_BAD_PATH","reason":"outside_root","schema_version":1},"schema_version":1}"#
            ),
            Ok(())
        );
        assert_eq!(
            feedback_string_valid(
                r#"{"name":"write_file","outcome":"failed","payload":{"failure_code":"E_AGENT_BAD_PATH","reason":"Outside","schema_version":1},"schema_version":1}"#
            ),
            Err(StoreError::InvalidArgument)
        );
        assert_eq!(
            feedback_string_valid(
                r#"{"name":"start_guest_cgi","outcome":"ok","payload":{"schema_version":1,"service_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","status":"running","url":"http://127.0.0.1:8080/"},"schema_version":1}"#
            ),
            Ok(())
        );
        assert_eq!(
            feedback_string_valid(
                r#"{"name":"start_guest_cgi","outcome":"ok","payload":{"schema_version":1,"service_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","status":"running","url":"http://localhost:8080/"},"schema_version":1}"#
            ),
            Err(StoreError::InvalidArgument)
        );
        assert!(guest_service_url(Some(&json!("http://127.0.0.1:1/"))));
        assert!(!guest_service_url(Some(&json!("http://127.0.0.1:0/"))));
        assert!(!guest_service_url(Some(&json!("http://127.0.0.1:8080/x"))));
    }

    #[test]
    fn raw_arguments_bind_write_intents() {
        let path_digest = hash_bytes("relative-path", b"notes.md").unwrap();
        let content_digest = hash_bytes("file-content", b"hello").unwrap();
        let intent = json!({
            "name": "write_file",
            "precondition": {
                "schema_version": 2, "kind": "write_file", "relative_path_sha256": path_digest,
                "prior": { "schema_version": 1, "kind": "absent" }, "content_sha256": content_digest, "content_bytes": 5,
            },
        });
        let ok = json!(r#"{"path":"notes.md","content":"hello","expected_revision":null}"#);
        assert_eq!(raw_arguments_bind_intent(Some(&ok), &intent), Ok(()));
        let by_prior = json!(
            r#"{"path":"notes.md","content":"hello","expected_prior":{"schema_version":1,"kind":"absent"}}"#
        );
        assert_eq!(raw_arguments_bind_intent(Some(&by_prior), &intent), Ok(()));
        // The third shape: a write naming neither expectation asserts the file
        // is absent, and binds to the same precondition the other two do.
        let bare = json!(r#"{"path":"notes.md","content":"hello"}"#);
        assert_eq!(raw_arguments_bind_intent(Some(&bare), &intent), Ok(()));
        let known = json!({
            "name": "write_file",
            "precondition": {
                "schema_version": 2, "kind": "write_file", "relative_path_sha256": path_digest,
                "prior": { "schema_version": 1, "kind": "known", "revision": "1:2:3:4:5" },
                "content_sha256": content_digest, "content_bytes": 5,
            },
        });
        assert_eq!(
            raw_arguments_bind_intent(Some(&bare), &known),
            Err(StoreError::Conflict)
        );
        let other_content =
            json!(r#"{"path":"notes.md","content":"hellp","expected_revision":null}"#);
        assert_eq!(
            raw_arguments_bind_intent(Some(&other_content), &intent),
            Err(StoreError::Conflict)
        );
        let bad_path =
            json!(r#"{"path":"../notes.md","content":"hello","expected_revision":null}"#);
        assert_eq!(
            raw_arguments_bind_intent(Some(&bad_path), &intent),
            Err(StoreError::InvalidArgument)
        );
        let status = json!({ "name": "git_status", "precondition": { "schema_version": 1, "kind": "git_status", "head_oid": null } });
        assert_eq!(
            raw_arguments_bind_intent(Some(&json!("{}")), &status),
            Ok(())
        );
        assert_eq!(
            raw_arguments_bind_intent(Some(&json!(r#"{"x":1}"#)), &status),
            Err(StoreError::InvalidArgument)
        );
    }
}
