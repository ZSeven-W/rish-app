//! What a project operation's arguments have to be, and which code a failure
//! is reported to JavaScript as.
//!
//! Ported from `LPV2CanonicalOID`, `LPV2CanonicalOperationId`,
//! `LPV2BoundedString`, `LPV2ClipUTF8` and `LPV2StableErrorCode` in
//! `LocalProjectsModule.mm`.
//!
//! **The error code is the contract, not the message.** JavaScript branches on
//! it, so the mapping from an internal failure in one of three domains to a
//! stable `E_…` string is a rule both platforms have to answer alike. An
//! unrecognised failure maps to `E_PROJECT_NATIVE` rather than being guessed
//! at: a caller must not be able to branch on a failure that does not exist.

use serde_json::{json, Map, Value};

use crate::workspace_error::public_code;
use crate::workspace_tool::path_control_or_format;

/// The fallback for a failure this engine does not recognise.
pub const NATIVE_FAILURE: &str = "E_PROJECT_NATIVE";

/// `LocalProjects`' own error numbers, in the order the switch lists them.
const MODULE_FAILURES: &[(i64, &str)] = &[
    (3003, "E_PROJECT_REQUEST_INVALID"),
    (3101, "E_PROJECT_REQUEST_INVALID"),
    (3105, "E_PROJECT_BUSY"),
    (3106, "E_PROJECT_BUSY"),
    (3104, "E_PROJECT_STORAGE_UNSAFE"),
    (3107, "E_PROJECT_STORAGE_UNSAFE"),
    (3110, "E_PROJECT_CONFLICT"),
    (3111, "E_PROJECT_UNAVAILABLE"),
    (3112, "E_WORKSPACE_CONFIRMATION"),
    (3195, "E_PROJECT_CANCELLED"),
    (3196, "E_PROJECT_NON_FAST_FORWARD"),
    (3197, "E_PROJECT_CREDENTIAL"),
    (3198, "E_PROJECT_TIMEOUT"),
    // A merge after divergence that this build does not carry out: a
    // shallow clone, unrelated histories, a submodule, a filter or merge
    // driver, a path this filesystem cannot hold.
    (3180, "E_PROJECT_MERGE_UNSUPPORTED"),
    // An interrupted merge whose repository state recovery cannot settle on
    // its own; the state is kept, never reset.
    (3181, "E_PROJECT_RECOVERY_REQUIRED"),
];

/// The workspace failures this module re-reports, and as what. The rest become
/// `E_WORKSPACE_UNAVAILABLE`: a project operation that could not reach its
/// workspace has nothing more specific to say about it.
const WORKSPACE_FAILURES: &[i64] = &[1, 2, 6, 9, 13, 14, 17, 18, 19];

/// `DSHLocalProjectAccessError…`: only three are distinguished.
const PROJECT_ACCESS_FAILURES: &[(i64, &str)] = &[
    (1, "E_PROJECT_REQUEST_INVALID"),
    (3, "E_PROJECT_STORAGE_UNSAFE"),
    (6, "E_PROJECT_BUSY"),
];

/// `LPV2CanonicalOID`: forty lowercase hex characters, or null when allowed.
pub fn canonical_oid(value: Option<&Value>, allow_null: bool) -> bool {
    if allow_null && matches!(value, Some(Value::Null)) {
        return true;
    }
    value.and_then(Value::as_str).is_some_and(|oid| {
        oid.len() == 40
            && oid
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    })
}

/// `LPV2CanonicalOperationId`: a lowercase canonical UUID. Unlike a snapshot
/// id this one *may* be the nil UUID — an operation id is the caller's to
/// choose, and nothing reads a sentinel out of it.
pub fn canonical_operation_id(value: Option<&Value>) -> bool {
    value.and_then(Value::as_str).is_some_and(|text| {
        text.len() == 36
            && text.bytes().enumerate().all(|(index, byte)| {
                if matches!(index, 8 | 13 | 18 | 23) {
                    byte == b'-'
                } else {
                    byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)
                }
            })
    })
}

/// `LPV2BoundedString`.
pub fn bounded_string(value: Option<&Value>, maximum_bytes: usize, allow_empty: bool) -> bool {
    value.and_then(Value::as_str).is_some_and(|text| {
        text.len() <= maximum_bytes
            && (allow_empty || !text.is_empty())
            && !text.chars().any(path_control_or_format)
    })
}

/// `LPV2ClipUTF8`: the longest prefix within the byte bound that is still
/// valid UTF-8, and whether anything was dropped.
///
/// The ObjC backs off a byte at a time until the prefix decodes; taking the
/// bound literally would cut a multi-byte character in half and produce a
/// string no consumer could read.
pub fn clip_utf8(value: &str, maximum_bytes: usize) -> (String, bool) {
    if value.len() <= maximum_bytes {
        return (value.to_string(), false);
    }
    let mut take = maximum_bytes;
    while take > 0 && !value.is_char_boundary(take) {
        take -= 1;
    }
    (value[..take].to_string(), true)
}

/// `LPV2StableErrorCode`. `domain` is the error's domain and `code` its number.
pub fn stable_error_code(domain: &str, code: i64) -> &'static str {
    match domain {
        "LocalProjects" => MODULE_FAILURES
            .iter()
            .find(|(number, _)| *number == code)
            .map_or(NATIVE_FAILURE, |(_, name)| *name),
        "dev.zseven.rish.local-workspace-access" => {
            if WORKSPACE_FAILURES.contains(&code) {
                // The workspace codes are the workspace rule's; this module
                // re-reports them rather than keeping a second spelling.
                public_code(Some(code as u64)).unwrap_or("E_WORKSPACE_UNAVAILABLE")
            } else if code == 4 {
                // A busy picker is busy, as far as a project operation cares.
                "E_WORKSPACE_BUSY"
            } else {
                "E_WORKSPACE_UNAVAILABLE"
            }
        }
        "dev.zseven.rish.local-project-access" => PROJECT_ACCESS_FAILURES
            .iter()
            .find(|(number, _)| *number == code)
            .map_or("E_PROJECT_UNAVAILABLE", |(_, name)| *name),
        _ => NATIVE_FAILURE,
    }
}

fn text<'a>(envelope: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    envelope.get(key).and_then(Value::as_str)
}

/// One envelope in, one reply out; see `rish_agent_project_module_reduce`.
pub fn reduce_json(input: &str) -> String {
    match reduce_json_inner(input) {
        Some(value) => value.to_string(),
        None => json!({ "ok": false }).to_string(),
    }
}

fn reduce_json_inner(input: &str) -> Option<Value> {
    let parsed: Value = serde_json::from_str(input).ok()?;
    let envelope = parsed.as_object()?;
    Some(match text(envelope, "op")? {
        "canonical_oid" => json!({
            "ok": true,
            "valid": canonical_oid(
                envelope.get("value"),
                envelope.get("allow_null") == Some(&json!(true)),
            ),
        }),
        "canonical_operation_id" => json!({
            "ok": true, "valid": canonical_operation_id(envelope.get("value"))
        }),
        "bounded_string" => json!({
            "ok": true,
            "valid": bounded_string(
                envelope.get("value"),
                envelope.get("maximum_bytes").and_then(Value::as_u64)? as usize,
                envelope.get("allow_empty") == Some(&json!(true)),
            ),
        }),
        "clip_utf8" => {
            let (clipped, truncated) = clip_utf8(
                text(envelope, "value")?,
                envelope.get("maximum_bytes").and_then(Value::as_u64)? as usize,
            );
            json!({ "ok": true, "value": clipped, "truncated": truncated })
        }
        "stable_error_code" => json!({
            "ok": true,
            "code": stable_error_code(
                text(envelope, "domain")?,
                envelope.get("code").and_then(Value::as_i64)?,
            ),
        }),
        _ => return None,
    })
}

#[cfg(test)]
#[path = "project_module_tests.rs"]
mod tests;
