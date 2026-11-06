//! `DSHSession*` primitive validators. These follow Foundation's readings:
//! lengths in UTF-16 units where the original used `NSString.length`, bytes
//! where it used UTF-8 data, `doubleValue` semantics for numbers, and the
//! Unicode whitespace / control categories `NSCharacterSet` exposes.

use crate::execution_ledger::as_str;
use serde_json::Value;

/// `DSHSessionSnapshotMaximumSafeInteger`.
pub const MAX_SAFE_INTEGER: u64 = 9_007_199_254_740_991;
pub const MAX_ID_BYTES: usize = 256;
pub const MAX_OPAQUE_ID_BYTES: usize = 128;

pub fn is_null(value: Option<&Value>) -> bool {
    matches!(value, Some(Value::Null))
}

pub fn is_boolean(value: Option<&Value>) -> bool {
    matches!(value, Some(Value::Bool(_)))
}

pub fn utf16_len(text: &str) -> usize {
    text.encode_utf16().count()
}

/// `NSCharacterSet.whitespaceAndNewlineCharacterSet` (Zs plus the newline
/// characters), which is exactly Unicode `White_Space`.
pub fn is_whitespace_or_newline(c: char) -> bool {
    c.is_whitespace()
}

/// `NSCharacterSet.controlCharacterSet`: Unicode general categories Cc and Cf.
pub fn is_control(c: char) -> bool {
    if c.is_control() {
        return true;
    }
    let code = c as u32;
    matches!(
        code,
        0x00AD
            | 0x0600..=0x0605
            | 0x061C
            | 0x06DD
            | 0x070F
            | 0x0890..=0x0891
            | 0x08E2
            | 0x180E
            | 0x200B..=0x200F
            | 0x202A..=0x202E
            | 0x2060..=0x2064
            | 0x2066..=0x206F
            | 0xFEFF
            | 0xFFF9..=0xFFFB
            | 0x110BD
            | 0x110CD
            | 0x13430..=0x1343F
            | 0x1BCA0..=0x1BCA3
            | 0x1D173..=0x1D17A
            | 0xE0001
            | 0xE0020..=0xE007F
    )
}

pub fn trimmed_is_empty(text: &str) -> bool {
    text.chars().all(is_whitespace_or_newline)
}

pub fn trimmed_equals_self(text: &str) -> bool {
    text.trim_matches(is_whitespace_or_newline) == text
}

/// `DSHSessionSafeInteger`: a non-boolean number whose double value is a
/// finite non-negative integer within 2^53 - 1; zero only when allowed.
pub fn safe_integer(value: Option<&Value>, allow_zero: bool) -> Option<u64> {
    let Some(Value::Number(number)) = value else {
        return None;
    };
    let x = number.as_f64()?;
    if !x.is_finite()
        || x.floor() != x
        || x < 0.0
        || x > MAX_SAFE_INTEGER as f64
        || (x == 0.0 && x.is_sign_negative())
        || (!allow_zero && x == 0.0)
    {
        return None;
    }
    Some(x as u64)
}

/// `DSHSessionFiniteNumber`: a finite integral number within ±(2^53 - 1),
/// never negative zero.
pub fn finite_number(value: Option<&Value>) -> bool {
    let Some(Value::Number(number)) = value else {
        return false;
    };
    let Some(x) = number.as_f64() else {
        return false;
    };
    x.is_finite()
        && x.floor() == x
        && !(x == 0.0 && x.is_sign_negative())
        && x.abs() <= MAX_SAFE_INTEGER as f64
}

pub fn exact_schema(value: Option<&Value>, schema: u64) -> bool {
    safe_integer(value, true) == Some(schema)
}

pub fn exact_keys(value: &Value, keys: &[&str]) -> bool {
    let Value::Object(map) = value else {
        return false;
    };
    map.len() == keys.len() && map.keys().all(|key| keys.contains(&key.as_str()))
}

pub fn exact_keys_with_optional(value: &Value, keys: &[&str], optional: &[&str]) -> bool {
    let Value::Object(map) = value else {
        return false;
    };
    map.keys()
        .all(|key| keys.contains(&key.as_str()) || optional.contains(&key.as_str()))
        && keys.iter().all(|key| map.contains_key(*key))
}

pub fn optional_pair_keys(value: &Value, base: &[&str], pair: &[&str]) -> bool {
    if exact_keys(value, base) {
        return true;
    }
    let mut all: Vec<&str> = base.to_vec();
    all.extend_from_slice(pair);
    exact_keys(value, &all)
}

/// `DSHSessionKeys`: every required key present, no key outside
/// required ∪ optional.
pub fn keys(value: &Value, required: &[&str], optional: &[&str]) -> bool {
    exact_keys_with_optional(value, required, optional)
}

/// `DSHSessionCanonicalUUID`: 36 UTF-16 units, equal to its lowercase form,
/// and a parseable 8-4-4-4-12 hex UUID.
pub fn canonical_uuid(value: Option<&Value>) -> bool {
    let Some(text) = as_str(value) else {
        return false;
    };
    if utf16_len(text) != 36 || text.to_lowercase() != text {
        return false;
    }
    let bytes = text.as_bytes();
    bytes.len() == 36
        && bytes.iter().enumerate().all(|(index, byte)| match index {
            8 | 13 | 18 | 23 => *byte == b'-',
            _ => byte.is_ascii_hexdigit(),
        })
}

/// `DSHSessionCanonicalDigest`: 64 lowercase hex characters.
pub fn canonical_digest(value: Option<&Value>) -> bool {
    let Some(text) = as_str(value) else {
        return false;
    };
    utf16_len(text) == 64
        && text.to_lowercase() == text
        && text.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

pub fn canonical_operation_id(value: Option<&Value>) -> bool {
    canonical_uuid(value)
}

/// `DSHSessionCanonicalTimestamp`: 24 units and 24 bytes of
/// `YYYY-MM-DDTHH:MM:SS.mmmZ` naming a real instant.
pub fn canonical_timestamp(value: Option<&Value>) -> bool {
    let Some(text) = as_str(value) else {
        return false;
    };
    utf16_len(text) == 24 && text.len() == 24 && crate::schema::canonical_timestamp(value)
}

/// `DSHSessionValidAgentFailureCode`: null or one of the agent codes.
pub fn valid_agent_failure_code(value: Option<&Value>) -> bool {
    if is_null(value) {
        return true;
    }
    const CODES: &[&str] = &[
        "E_AGENT_UNKNOWN_TOOL",
        "E_AGENT_BAD_ARGUMENTS",
        "E_AGENT_BAD_PATH",
        "E_AGENT_NO_ROOT",
        "E_AGENT_ROOT_STALE",
        "E_AGENT_CAPABILITY",
        "E_AGENT_APPROVAL",
        "E_AGENT_TRANSCRIPT",
        "E_AGENT_LEDGER",
        "E_AGENT_ROUND_AMBIGUOUS",
        "E_AGENT_EXECUTION_AMBIGUOUS",
        "E_AGENT_RETRY_LINEAGE",
        "E_AGENT_PERSISTENCE",
        "E_AGENT_CONFLICT",
        "E_AGENT_NOT_FOUND",
        "E_AGENT_EVENT_CAPACITY",
        "E_AGENT_ROUND_LIMIT",
        "E_AGENT_CANCELLED",
        "E_AGENT_TOOL_FAILED",
        "E_AGENT_DENIED_BY_USER",
        "E_AGENT_PROVIDER_CREDENTIAL",
        "E_AGENT_PROVIDER_FORBIDDEN",
        "E_AGENT_PROVIDER_NOT_FOUND",
        "E_AGENT_PROVIDER_RATE_LIMITED",
        "E_AGENT_PROVIDER_REFUSED",
    ];
    let Some(text) = as_str(value) else {
        return false;
    };
    let units = utf16_len(text);
    units > 0 && units <= 128 && CODES.contains(&text)
}

/// `DSHSessionBoundedText`: a string of at most `maximum_bytes` UTF-8 bytes.
pub fn bounded_text(
    value: Option<&Value>,
    maximum_bytes: usize,
    allow_empty: bool,
) -> Option<&str> {
    let text = as_str(value)?;
    (text.len() <= maximum_bytes && (allow_empty || !text.is_empty())).then_some(text)
}

pub fn string_or_null(value: Option<&Value>) -> bool {
    is_null(value) || as_str(value).is_some()
}

/// Whether every character is an ASCII URL character (`NSURL URLWithString:`
/// returns nil for anything else).
fn url_safe(text: &str) -> bool {
    text.bytes().all(|b| (0x21..=0x7e).contains(&b))
}

/// A minimal parse of `scheme://[userinfo@]host[:port][/path][?query][#fragment]`.
struct ParsedUrl<'a> {
    scheme: &'a str,
    userinfo: Option<&'a str>,
    host: &'a str,
    port: Option<&'a str>,
    path: &'a str,
    query: Option<&'a str>,
    fragment: Option<&'a str>,
}

fn parse_url(text: &str) -> Option<ParsedUrl<'_>> {
    if !url_safe(text) {
        return None;
    }
    let (scheme, rest) = text.split_once("://")?;
    if scheme.is_empty()
        || !scheme
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'+' | b'-' | b'.'))
        || !scheme.as_bytes()[0].is_ascii_alphabetic()
    {
        return None;
    }
    let (rest, fragment) = match rest.split_once('#') {
        Some((r, f)) => (r, Some(f)),
        None => (rest, None),
    };
    let (rest, query) = match rest.split_once('?') {
        Some((r, q)) => (r, Some(q)),
        None => (rest, None),
    };
    let (authority, path) = match rest.find('/') {
        Some(index) => (&rest[..index], &rest[index..]),
        None => (rest, ""),
    };
    let (userinfo, hostport) = match authority.rsplit_once('@') {
        Some((u, h)) => (Some(u), h),
        None => (None, authority),
    };
    let (host, port) = if let Some(rest) = hostport.strip_prefix('[') {
        let end = rest.find(']')?;
        let host = &hostport[..end + 2];
        let after = &rest[end + 1..];
        match after.strip_prefix(':') {
            Some(port) => (host, Some(port)),
            None if after.is_empty() => (host, None),
            None => return None,
        }
    } else {
        match hostport.rsplit_once(':') {
            Some((h, p)) if p.bytes().all(|b| b.is_ascii_digit()) => (h, Some(p)),
            Some(_) => return None,
            None => (hostport, None),
        }
    };
    Some(ParsedUrl {
        scheme,
        userinfo,
        host,
        port,
        path,
        query,
        fragment,
    })
}

/// `DSHSessionSafeMirrorURL`.
pub fn safe_mirror_url(value: Option<&Value>) -> bool {
    let Some(text) = bounded_text(value, 2048, false) else {
        return false;
    };
    if !trimmed_equals_self(text) || text.chars().any(is_control) {
        return false;
    }
    let Some(url) = parse_url(text) else {
        return false;
    };
    url.scheme.eq_ignore_ascii_case("https")
        && !url.host.is_empty()
        && url.userinfo.is_none_or(str::is_empty)
        && url.query.is_none_or(str::is_empty)
        && url.fragment.is_none_or(str::is_empty)
}

/// `DSHSessionSafeProxyURL`: `^https?://(\[[^\]]+\]|[^@:/?#]+):([0-9]{1,5})/?$`
/// plus the URL checks.
pub fn safe_proxy_url(value: Option<&Value>) -> bool {
    let Some(text) = bounded_text(value, 2048, false) else {
        return false;
    };
    if !trimmed_equals_self(text) || text.chars().any(is_control) {
        return false;
    }
    let lower = text.to_ascii_lowercase();
    let rest = lower
        .strip_prefix("https://")
        .or_else(|| lower.strip_prefix("http://"));
    let Some(rest) = rest else { return false };
    let rest = rest.strip_suffix('/').unwrap_or(rest);
    let Some((host, port)) = rest.rsplit_once(':') else {
        return false;
    };
    let host_ok = if let Some(inner) = host.strip_prefix('[') {
        inner
            .strip_suffix(']')
            .is_some_and(|h| !h.is_empty() && !h.contains(']'))
    } else {
        !host.is_empty()
            && !host
                .bytes()
                .any(|b| matches!(b, b'@' | b':' | b'/' | b'?' | b'#'))
    };
    if !host_ok || port.is_empty() || port.len() > 5 || !port.bytes().all(|b| b.is_ascii_digit()) {
        return false;
    }
    let Some(url) = parse_url(text) else {
        return false;
    };
    let port: u32 = port.parse().unwrap_or(0);
    (1..=65535).contains(&port)
        && !url.host.is_empty()
        && url.userinfo.is_none_or(str::is_empty)
        && url.query.is_none_or(str::is_empty)
        && url.fragment.is_none_or(str::is_empty)
        && (url.path.is_empty() || url.path == "/")
        && url.port.is_some()
}

/// `DSHSessionValidIdentifier`: bounded, non-empty after trimming.
pub fn valid_identifier(value: Option<&Value>, maximum_bytes: usize) -> bool {
    bounded_text(value, maximum_bytes, false).is_some_and(|text| !trimmed_is_empty(text))
}

/// `DSHSessionValidOpaqueIdentifier`: an identifier of `[A-Za-z0-9._:-]`.
pub fn valid_opaque_identifier(value: Option<&Value>) -> bool {
    valid_identifier(value, MAX_OPAQUE_ID_BYTES)
        && as_str(value).is_some_and(|text| {
            text.bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b':' | b'-'))
        })
}

pub fn valid_thinking_mode(value: Option<&Value>) -> bool {
    matches!(as_str(value), Some("off" | "high" | "max"))
}

pub fn valid_timestamp_pair(created: Option<&Value>, updated: Option<&Value>) -> bool {
    canonical_timestamp(created)
        && canonical_timestamp(updated)
        && as_str(created) <= as_str(updated)
}

/// `DSHSessionValidProjectPath`.
pub fn valid_project_path(value: Option<&Value>) -> bool {
    let Some(path) = bounded_text(value, 4096, false) else {
        return false;
    };
    if path.starts_with('/') || path.contains('\\') {
        return false;
    }
    path.split('/').all(|component| {
        !component.is_empty()
            && component != "."
            && component != ".."
            && !component.chars().any(is_control)
    })
}

/// `DSHSessionValidProjectName`.
pub fn valid_project_name(value: Option<&Value>) -> bool {
    let Some(name) = bounded_text(value, 120, false) else {
        return false;
    };
    trimmed_equals_self(name)
        && !name.contains('/')
        && !name.contains('\\')
        && name != "."
        && name != ".."
        && !name.chars().any(is_control)
}

/// `DSHSessionValidGitBranch`: null or a reference name git accepts.
pub fn valid_git_branch(value: Option<&Value>) -> bool {
    if is_null(value) {
        return true;
    }
    let Some(branch) = bounded_text(value, 1024, false) else {
        return false;
    };
    if branch == "@"
        || branch.starts_with('/')
        || branch.ends_with('/')
        || branch.starts_with('.')
        || branch.ends_with('.')
        || branch.contains("..")
        || branch.contains("@{")
        || branch
            .chars()
            .any(|c| matches!(c, '~' | '^' | ':' | '?' | '*' | '['))
        || branch.contains('\\')
        || branch.chars().any(is_control)
    {
        return false;
    }
    branch.split('/').all(|component| {
        !component.is_empty() && !component.starts_with('.') && !component.ends_with(".lock")
    })
}

/// `DSHSessionValidGitObjectId`: null or 40 lowercase hex characters.
pub fn valid_git_object_id(value: Option<&Value>) -> bool {
    if is_null(value) {
        return true;
    }
    let Some(text) = as_str(value) else {
        return false;
    };
    utf16_len(text) == 40 && text.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

/// `DSHSessionValidHarnessId`: `^[a-z0-9](?:[a-z0-9._-]{0,62}[a-z0-9])?$`.
pub fn valid_harness_id(value: Option<&Value>) -> bool {
    let Some(text) = bounded_text(value, 64, false) else {
        return false;
    };
    let bytes = text.as_bytes();
    let inner =
        |b: &u8| b.is_ascii_lowercase() || b.is_ascii_digit() || matches!(b, b'.' | b'_' | b'-');
    let edge = |b: &u8| b.is_ascii_lowercase() || b.is_ascii_digit();
    match bytes.len() {
        0 => false,
        1 => edge(&bytes[0]),
        n if n <= 64 => edge(&bytes[0]) && edge(&bytes[n - 1]) && bytes[1..n - 1].iter().all(inner),
        _ => false,
    }
}

pub fn valid_project_context_error_code(value: Option<&Value>) -> bool {
    if is_null(value) {
        return true;
    }
    const CODES: &[&str] = &[
        "E_PROJECT_ID_INVALID",
        "E_PROJECT_NOT_FOUND",
        "E_PROJECT_STORAGE_UNSAFE",
        "E_REPOSITORY_UNSUPPORTED",
        "E_CONTEXT_CHANGED",
        "E_CONTEXT_BUDGET",
        "E_CONTEXT_SECRET",
        "E_CONTEXT_ENCODING",
        "E_CONTEXT_TIMEOUT",
        "E_CONTEXT_CANCELLED",
        "E_CONTEXT_CONSENT_INVALID",
        "E_CONTEXT_SNAPSHOT_MISSING",
    ];
    as_str(value).is_some_and(|text| CODES.contains(&text))
}

pub const REGISTERED_TOOLS: &[&str] = &[
    "list_assistant_tasks",
    "create_assistant_task",
    "update_assistant_task",
    "search_assistant_memory",
    "remember_assistant_memory",
    "forget_assistant_memory",
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
];

pub fn valid_agent_summary_key(value: Option<&Value>) -> bool {
    const KEYS: &[&str] = &[
        "agent.list_assistant_tasks",
        "agent.create_assistant_task",
        "agent.update_assistant_task",
        "agent.search_assistant_memory",
        "agent.remember_assistant_memory",
        "agent.forget_assistant_memory",
        "agent.ask_user",
        "agent.list_dir",
        "agent.read_file",
        "agent.write_file",
        "agent.git_status",
        "agent.git_commit",
        "agent.git_push",
        "agent.start_guest_cgi",
        "agent.stop_guest_cgi",
        "agent.list_runtime_environments",
        "agent.install_runtime_environment",
        "agent.run_program",
        "agent.start_runtime_service",
        "agent.stop_runtime_service",
        "agent.unknown",
    ];
    bounded_text(value, 128, false).is_some_and(|text| KEYS.contains(&text))
}

pub fn agent_summary_matches_name(summary: Option<&Value>, name: Option<&Value>) -> bool {
    if !valid_agent_summary_key(summary) {
        return false;
    }
    let (Some(summary), Some(name)) = (as_str(summary), as_str(name)) else {
        return false;
    };
    if (matches!(name, "ask_user" | "start_guest_cgi" | "stop_guest_cgi")
        || crate::runtime_tools::is_runtime(name)
        || crate::assistant_tools::is_assistant(name))
        && summary == "agent.unknown"
    {
        return true;
    }
    let expected = if REGISTERED_TOOLS.contains(&name) {
        format!("agent.{name}")
    } else {
        "agent.unknown".to_string()
    };
    summary == expected
}

pub fn valid_attempt_failure_code(value: Option<&Value>) -> bool {
    if is_null(value) {
        return true;
    }
    const CODES: &[&str] = &[
        "E_ATTEMPT_INTERRUPTED",
        "E_ATTEMPT_PERSISTENCE",
        "E_ATTEMPT_CONTEXT_REQUIRED",
        "E_COMPLETION_RESULT_KEYS",
        "E_COMPLETION_RESULT_TYPE",
        "E_COMPLETION_RESULT_IDENTIFIER",
        "E_COMPLETION_RESULT_BOUNDS",
        "E_COMPLETION_RESULT_ENUM",
        "E_COMPLETION_RESULT_DIGEST",
        "E_COMPLETION_RESULT_RELATION",
        "E_COMPLETION_RESULT_CORRELATION",
        "E_COMPLETION_NATIVE",
        "E_COMPLETION_SCHEMA",
        "E_COMPLETION_IDENTIFIER",
        "E_COMPLETION_ROUND",
        "E_COMPLETION_MODEL",
        "E_COMPLETION_THINKING",
        "E_COMPLETION_HISTORY",
        "E_COMPLETION_TRANSCRIPT",
        "E_COMPLETION_TOOLS",
        "E_COMPLETION_CONTEXT_INVALID",
        "E_COMPLETION_CONTEXT_UNSUPPORTED",
        "E_COMPLETION_CREDENTIAL_UNAVAILABLE",
        "E_COMPLETION_CREDENTIAL_CHANGED",
        "E_COMPLETION_BODY_INVALID",
        "E_COMPLETION_BODY_TOO_LARGE",
        "E_COMPLETION_BUSY",
        "E_COMPLETION_CANCELLED",
        "E_COMPLETION_REDIRECT",
        "E_COMPLETION_TIMEOUT",
        "E_COMPLETION_TRANSPORT",
        "E_COMPLETION_HTTP_STATUS",
        "E_COMPLETION_HTTP_429",
        "E_COMPLETION_RESPONSE_SIZE",
        "E_COMPLETION_RESPONSE_JSON",
        "E_COMPLETION_PROVIDER_REQUEST_ID",
        "E_COMPLETION_PROVIDER_RESPONSE_ID",
        "E_COMPLETION_RESPONSE_MODEL",
        "E_COMPLETION_MODEL_MISMATCH",
        "E_COMPLETION_FINISH_RELATION",
        "E_COMPLETION_TOOL_CALL_INVALID",
        "E_COMPLETION_EMPTY_RESPONSE",
        "E_PROJECT_ID_INVALID",
        "E_PROJECT_NOT_FOUND",
        "E_PROJECT_STORAGE_UNSAFE",
        "E_REPOSITORY_UNSUPPORTED",
        "E_CONTEXT_CHANGED",
        "E_CONTEXT_BUDGET",
        "E_CONTEXT_SECRET",
        "E_CONTEXT_ENCODING",
        "E_CONTEXT_TIMEOUT",
        "E_CONTEXT_CANCELLED",
        "E_CONTEXT_CONSENT_INVALID",
        "E_CONTEXT_SNAPSHOT_MISSING",
        "E_CONTEXT_REQUEST_INVALID",
        "E_CONTEXT_RESULT_INVALID",
        "E_CONTEXT_STORAGE",
        "E_CONTEXT_INTEGRITY",
        "E_CONTEXT_BUSY",
        "E_CONTEXT_NATIVE",
        "E_WORKSPACE_REVOKED",
    ];
    as_str(value).is_some_and(|text| CODES.contains(&text)) || valid_agent_failure_code(value)
}

/// `DSHSessionValidASCIIName`: bounded and every unit in 0x21..=0x7E.
pub fn valid_ascii_name(value: Option<&Value>, maximum_bytes: usize) -> bool {
    bounded_text(value, maximum_bytes, false)
        .is_some_and(|text| text.bytes().all(|b| (0x21..=0x7e).contains(&b)))
}

/// NSString `compare:` ordering, taken as UTF-16 unit order.
pub fn string_compare(left: &str, right: &str) -> std::cmp::Ordering {
    left.encode_utf16().cmp(right.encode_utf16())
}
