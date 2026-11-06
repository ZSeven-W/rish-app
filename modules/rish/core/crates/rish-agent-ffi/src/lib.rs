//! C ABI over `rish-agent-core`, in the same style as the rish runtime's
//! `rish-ffi`: UTF-8 JSON in with an explicit length, Rust-owned UTF-8 out,
//! released with [`rish_agent_string_free`]. Every entry point is safe to
//! call from any thread and never panics across the boundary.

use rish_agent_core::agent_policy::reduce_json as agent_policy_reduce_json;
use rish_agent_core::canonical::{canonical_json, hash_bytes, hash_json};
use rish_agent_core::completion_response::reduce_json as completion_response_reduce_json;
use rish_agent_core::container_anchor::reduce_json as container_anchor_reduce_json;
use rish_agent_core::git_tool::reduce_json as git_tool_reduce_json;
use rish_agent_core::ledger_batch::reduce_json as ledger_batch_reduce_json;
use rish_agent_core::ledger_ops::reduce_json as ledger_reduce_json;
use rish_agent_core::prepared_attempt::reduce_json as prepared_attempt_reduce_json;
use rish_agent_core::project_access::reduce_json as project_access_reduce_json;
use rish_agent_core::project_context_bridge::reduce_json as project_context_bridge_reduce_json;
use rish_agent_core::project_context_policy::reduce_json as project_context_reduce_json;
use rish_agent_core::project_context_service::reduce_json as project_context_service_reduce_json;
use rish_agent_core::project_context_store::reduce_json as project_context_store_reduce_json;
use rish_agent_core::project_module::reduce_json as project_module_reduce_json;
use rish_agent_core::provider_round::reduce_json as provider_round_reduce_json;
use rish_agent_core::root_projection::reduce_json as root_reduce_json;
use rish_agent_core::round_journal::reduce_json;
use rish_agent_core::runtime_coordinator::reduce_json as runtime_reduce_json;
use rish_agent_core::runtime_environment::reduce_json as runtime_environment_reduce_json;
use rish_agent_core::session_schema::reduce_json as session_reduce_json;
use rish_agent_core::strict_json::parse_arguments;
use rish_agent_core::tool_batch::reduce_json as tool_batch_reduce_json;
use rish_agent_core::tool_execution::reduce_json as tool_execution_reduce_json;
use rish_agent_core::tool_registry::reduce_json as tool_registry_reduce_json;
use rish_agent_core::transcript_store::reduce_json as transcript_reduce_json;
use rish_agent_core::wal_operations::reduce_json as wal_operation_reduce_json;
use rish_agent_core::wal_resident::{Confirmation, Resident};
use rish_agent_core::wal_state::reduce_json as wal_state_reduce_json;
mod shared_policies;
mod workspace;
pub use shared_policies::*;
pub use workspace::*;

use std::ffi::CString;
use std::os::raw::c_char;
use std::slice;

/// Returns the JSON protocol version implemented by this library.
#[no_mangle]
pub extern "C" fn rish_agent_protocol_version() -> u32 {
    rish_agent_core::PROTOCOL_VERSION
}

/// Releases a string returned by any operation in this library.
///
/// # Safety
/// `value` must be null or a pointer previously returned by this library and
/// not yet freed.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_string_free(value: *mut c_char) {
    if !value.is_null() {
        drop(CString::from_raw(value));
    }
}

unsafe fn input(pointer: *const c_char, length: usize) -> Option<&'static str> {
    if pointer.is_null() {
        return None;
    }
    std::str::from_utf8(slice::from_raw_parts(pointer.cast::<u8>(), length)).ok()
}

fn output(text: String) -> *mut c_char {
    CString::new(text)
        .map(CString::into_raw)
        .unwrap_or(std::ptr::null_mut())
}

/// Canonical JSON of the JSON text `input` (any JSON value). Returns null when
/// the text is not JSON or the value cannot be canonicalised.
///
/// # Safety
/// `pointer` must reference `length` readable bytes or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_canonical_json(
    pointer: *const c_char,
    length: usize,
) -> *mut c_char {
    let Some(text) = input(pointer, length) else {
        return std::ptr::null_mut();
    };
    let Ok(value) = serde_json::from_str::<serde_json::Value>(text) else {
        return std::ptr::null_mut();
    };
    match canonical_json(&value) {
        Ok(bytes) => output(String::from_utf8(bytes).unwrap_or_default()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// `DSHAgentHJ`: domain-separated SHA-256 of the canonical form of a JSON text.
///
/// # Safety
/// Both pointers must reference their stated lengths or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_hash_json(
    tag: *const c_char,
    tag_length: usize,
    pointer: *const c_char,
    length: usize,
) -> *mut c_char {
    let (Some(tag), Some(text)) = (input(tag, tag_length), input(pointer, length)) else {
        return std::ptr::null_mut();
    };
    let Ok(value) = serde_json::from_str::<serde_json::Value>(text) else {
        return std::ptr::null_mut();
    };
    hash_json(tag, &value)
        .map(output)
        .unwrap_or(std::ptr::null_mut())
}

/// `DSHAgentHB`: domain-separated SHA-256 of raw bytes.
///
/// # Safety
/// Both pointers must reference their stated lengths or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_hash_bytes(
    tag: *const c_char,
    tag_length: usize,
    pointer: *const u8,
    length: usize,
) -> *mut c_char {
    let Some(tag) = input(tag, tag_length) else {
        return std::ptr::null_mut();
    };
    if pointer.is_null() && length != 0 {
        return std::ptr::null_mut();
    }
    let bytes = if length == 0 {
        &[][..]
    } else {
        slice::from_raw_parts(pointer, length)
    };
    hash_bytes(tag, bytes)
        .map(output)
        .unwrap_or(std::ptr::null_mut())
}

/// Returns the canonical form of tool arguments when the strict parser
/// accepts them, null otherwise (`DSHAgentParseArgumentsJSON`).
///
/// # Safety
/// `pointer` must reference `length` readable bytes or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_parse_arguments(
    pointer: *const c_char,
    length: usize,
) -> *mut c_char {
    let Some(text) = input(pointer, length) else {
        return std::ptr::null_mut();
    };
    let Some(object) = parse_arguments(text) else {
        return std::ptr::null_mut();
    };
    match canonical_json(&serde_json::Value::Object(object)) {
        Ok(bytes) => output(String::from_utf8(bytes).unwrap_or_default()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Runs one schema-3 round-journal operation over the JSON envelope
/// documented on `rish_agent_core::round_journal::reduce_json`. Always returns
/// a JSON object (`ok` true or false); null only when `input` is not UTF-8.
///
/// # Safety
/// `pointer` must reference `length` readable bytes or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_round_reduce(
    pointer: *const c_char,
    length: usize,
) -> *mut c_char {
    let Some(text) = input(pointer, length) else {
        return std::ptr::null_mut();
    };
    output(reduce_json(text))
}

/// Runs one execution-ledger row operation over the JSON envelope documented
/// on `rish_agent_core::ledger_ops::reduce_json`. Always returns a JSON object
/// (`ok` true or false); null only when `input` is not UTF-8.
///
/// # Safety
/// `pointer` must reference `length` readable bytes or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_ledger_reduce(
    pointer: *const c_char,
    length: usize,
) -> *mut c_char {
    let Some(text) = input(pointer, length) else {
        return std::ptr::null_mut();
    };
    output(ledger_reduce_json(text))
}

/// Runs one batch-level ledger operation (`prepare_tool_batch` or
/// `open_effect_gate`) over the JSON envelope documented on
/// `rish_agent_core::ledger_batch::reduce_json`.
///
/// # Safety
/// `pointer` must reference `length` readable bytes or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_ledger_batch_reduce(
    pointer: *const c_char,
    length: usize,
) -> *mut c_char {
    let Some(text) = input(pointer, length) else {
        return std::ptr::null_mut();
    };
    output(ledger_batch_reduce_json(text))
}

/// Runs one transcript-store operation over the JSON envelope documented on
/// `rish_agent_core::transcript_store::reduce_json`.
///
/// # Safety
/// `pointer` must reference `length` readable bytes or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_transcript_reduce(
    pointer: *const c_char,
    length: usize,
) -> *mut c_char {
    let Some(text) = input(pointer, length) else {
        return std::ptr::null_mut();
    };
    output(transcript_reduce_json(text))
}

/// Runs one session-schema operation (candidate validation and digest,
/// envelope and tombstone validation, legacy root validation): `request`
/// is the `{"op","env"}` JSON documented on
/// `rish_agent_core::session_schema::reduce_json`, `input` the operation's
/// raw bytes (they need not be UTF-8; an empty input is a valid, empty file).
///
/// # Safety
/// `request` must reference `request_length` readable bytes or be null;
/// `input` must reference `input_length` readable bytes or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_session_reduce(
    request: *const c_char,
    request_length: usize,
    input: *const u8,
    input_length: usize,
) -> *mut c_char {
    let Some(text) = self::input(request, request_length) else {
        return std::ptr::null_mut();
    };
    let bytes: &[u8] = if input.is_null() {
        &[]
    } else {
        slice::from_raw_parts(input, input_length)
    };
    output(session_reduce_json(text, bytes))
}

/// Runs one tool-batch-service decision over the JSON envelope documented on
/// `rish_agent_core::tool_batch::reduce_json`.
///
/// # Safety
/// `pointer` must reference `length` readable bytes or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_tool_batch_reduce(
    pointer: *const c_char,
    length: usize,
) -> *mut c_char {
    let Some(text) = input(pointer, length) else {
        return std::ptr::null_mut();
    };
    output(tool_batch_reduce_json(text))
}

/// Answers one tool-registry question over the JSON envelope documented on
/// `rish_agent_core::tool_registry::reduce_json`.
///
/// # Safety
/// `pointer` must reference `length` readable bytes or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_tool_registry_reduce(
    pointer: *const c_char,
    length: usize,
) -> *mut c_char {
    let Some(text) = input(pointer, length) else {
        return std::ptr::null_mut();
    };
    output(tool_registry_reduce_json(text))
}

/// Runs one root-projection decision over the JSON envelope documented on
/// `rish_agent_core::root_projection::reduce_json`.
///
/// # Safety
/// `pointer` must reference `length` readable bytes or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_root_reduce(
    pointer: *const c_char,
    length: usize,
) -> *mut c_char {
    let Some(text) = input(pointer, length) else {
        return std::ptr::null_mut();
    };
    output(root_reduce_json(text))
}

/// Runs one agent-policy decision over the JSON envelope documented on
/// `rish_agent_core::agent_policy::reduce_json` — the safe projection a person
/// is shown about what the agent may do.
///
/// # Safety
/// `pointer` must reference `length` readable bytes or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_policy_reduce(
    pointer: *const c_char,
    length: usize,
) -> *mut c_char {
    let Some(text) = input(pointer, length) else {
        return std::ptr::null_mut();
    };
    output(agent_policy_reduce_json(text))
}

/// Runs one chat-read-v1 project-context policy decision over the JSON
/// envelope documented on
/// `rish_agent_core::project_context_policy::reduce_json`; `content` carries a
/// file's raw bytes for the `content_decision` op and may be null for the
/// others. Case folding stays with the host; which folded names are sensitive
/// is decided here.
///
/// # Safety
/// `pointer` must reference `length` readable bytes or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_project_context_reduce(
    pointer: *const c_char,
    length: usize,
    content: *const u8,
    content_length: usize,
) -> *mut c_char {
    let Some(text) = input(pointer, length) else {
        return std::ptr::null_mut();
    };
    let bytes = if content.is_null() || content_length == 0 {
        &[][..]
    } else {
        std::slice::from_raw_parts(content, content_length)
    };
    output(project_context_reduce_json(text, bytes))
}

/// Parses one provider completion response over the JSON envelope documented
/// on `rish_agent_core::completion_response::reduce_json`. Unlike the store
/// reducers this answers with a `failure_code`, not a store error code: a
/// provider reply is not a store operation.
///
/// # Safety
/// `pointer` must reference `length` readable bytes or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_completion_response_reduce(
    pointer: *const c_char,
    length: usize,
) -> *mut c_char {
    let Some(text) = input(pointer, length) else {
        return std::ptr::null_mut();
    };
    output(completion_response_reduce_json(text))
}

/// Runs one Git-tool decision over the JSON envelope documented on
/// `rish_agent_core::git_tool::reduce_json`.
///
/// # Safety
/// `pointer` must reference `length` readable bytes or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_git_tool_reduce(
    pointer: *const c_char,
    length: usize,
) -> *mut c_char {
    let Some(text) = input(pointer, length) else {
        return std::ptr::null_mut();
    };
    output(git_tool_reduce_json(text))
}

/// Runs one runtime-environment decision over the JSON envelope documented on
/// `rish_agent_core::runtime_environment::reduce_json` -- what an environment
/// identity, a download URL and a package manifest have to be.
///
/// The URL arrives already parsed by the host: `NSURLComponents` is what
/// decides today what counts as a host or a fragment, and this keeps that
/// answer where it is rather than substituting another parser's.
///
/// # Safety
/// `pointer` must reference `length` readable bytes or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_runtime_environment_reduce(
    pointer: *const c_char,
    length: usize,
) -> *mut c_char {
    let Some(text) = input(pointer, length) else {
        return std::ptr::null_mut();
    };
    output(runtime_environment_reduce_json(text))
}

/// Runs one project-module decision over the JSON envelope documented on
/// `rish_agent_core::project_module::reduce_json` — what a project operation's
/// arguments have to be, and which stable code a failure is reported to
/// JavaScript as.
///
/// # Safety
/// `pointer` must reference `length` readable bytes or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_project_module_reduce(
    pointer: *const c_char,
    length: usize,
) -> *mut c_char {
    let Some(text) = input(pointer, length) else {
        return std::ptr::null_mut();
    };
    output(project_module_reduce_json(text))
}

/// Runs one project-context-bridge decision over the JSON envelope documented
/// on `rish_agent_core::project_context_bridge::reduce_json` — what a
/// project-context result may say at the boundary to JavaScript.
///
/// # Safety
/// `pointer` must reference `length` readable bytes or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_project_context_bridge_reduce(
    pointer: *const c_char,
    length: usize,
) -> *mut c_char {
    let Some(text) = input(pointer, length) else {
        return std::ptr::null_mut();
    };
    output(project_context_bridge_reduce_json(text))
}

/// Runs one project-context-service decision over the JSON envelope documented
/// on `rish_agent_core::project_context_service::reduce_json` — how a snapshot
/// reference is named, and what a caller's v2 arguments have to be.
///
/// # Safety
/// `pointer` must reference `length` readable bytes or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_project_context_service_reduce(
    pointer: *const c_char,
    length: usize,
) -> *mut c_char {
    let Some(text) = input(pointer, length) else {
        return std::ptr::null_mut();
    };
    output(project_context_service_reduce_json(text))
}

/// Runs one project-context-store decision over the JSON envelope documented
/// on `rish_agent_core::project_context_store::reduce_json` — how the store
/// names what it keeps, and what an interrupted prepare transaction resolves
/// to on the next launch.
///
/// # Safety
/// `pointer` must reference `length` readable bytes or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_project_context_store_reduce(
    pointer: *const c_char,
    length: usize,
) -> *mut c_char {
    let Some(text) = input(pointer, length) else {
        return std::ptr::null_mut();
    };
    output(project_context_store_reduce_json(text))
}

/// Runs one container-anchor decision over the JSON envelope documented on
/// `rish_agent_core::container_anchor::reduce_json` — where a path stops being
/// the app's own container and starts being a place inside it. Splitting a
/// path into components stays with the host, because `pathComponents` is
/// Foundation's and keeps a leading "/" a naive split would not.
///
/// # Safety
/// `pointer` must reference `length` readable bytes or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_container_anchor_reduce(
    pointer: *const c_char,
    length: usize,
) -> *mut c_char {
    let Some(text) = input(pointer, length) else {
        return std::ptr::null_mut();
    };
    output(container_anchor_reduce_json(text))
}

/// Runs one project-access decision over the JSON envelope documented on
/// `rish_agent_core::project_access::reduce_json` — what a project binding,
/// its root reference and its stored metadata look like. The git directory
/// crosses as a path and a flag rather than an `NSURL`, and Foundation's
/// trimming crosses as the trimmed spelling.
///
/// # Safety
/// `pointer` must reference `length` readable bytes or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_project_access_reduce(
    pointer: *const c_char,
    length: usize,
) -> *mut c_char {
    let Some(text) = input(pointer, length) else {
        return std::ptr::null_mut();
    };
    output(project_access_reduce_json(text))
}

/// Runs one tool-execution-service decision over the JSON envelope
/// documented on `rish_agent_core::tool_execution::reduce_json`.
///
/// # Safety
/// `pointer` must reference `length` readable bytes or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_tool_execution_reduce(
    pointer: *const c_char,
    length: usize,
) -> *mut c_char {
    let Some(text) = input(pointer, length) else {
        return std::ptr::null_mut();
    };
    output(tool_execution_reduce_json(text))
}

/// Runs one prepared-attempt-store decision over the JSON envelope
/// documented on `rish_agent_core::prepared_attempt::reduce_json`;
/// `session` carries the committed session's exact JSON bytes for the
/// `session` op (may be null/empty for the others).
///
/// # Safety
/// `pointer` must reference `length` readable bytes or be null; `session`
/// must reference `session_length` readable bytes or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_prepared_attempt_reduce(
    pointer: *const c_char,
    length: usize,
    session: *const u8,
    session_length: usize,
) -> *mut c_char {
    let Some(text) = input(pointer, length) else {
        return std::ptr::null_mut();
    };
    let bytes: &[u8] = if session.is_null() {
        &[]
    } else {
        slice::from_raw_parts(session, session_length)
    };
    output(prepared_attempt_reduce_json(text, bytes))
}

/// The build identity of the linked core: crate version plus the git
/// revision the packaging script recorded, so a test can prove which
/// build it exercises.
#[no_mangle]
pub extern "C" fn rish_agent_build_id() -> *mut c_char {
    output(format!(
        "rish-agent-core {} {}",
        env!("CARGO_PKG_VERSION"),
        option_env!("RISH_AGENT_CORE_GIT_SHA").unwrap_or("unknown")
    ))
}

/// Runs one provider-round decision over the JSON envelope documented on
/// `rish_agent_core::provider_round::reduce_json`.
///
/// # Safety
/// `pointer` must reference `length` readable bytes or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_provider_round_reduce(
    pointer: *const c_char,
    length: usize,
) -> *mut c_char {
    let Some(text) = input(pointer, length) else {
        return std::ptr::null_mut();
    };
    output(provider_round_reduce_json(text))
}

/// Validates one stored WAL row over the JSON envelope documented on
/// `rish_agent_core::wal_state::reduce_json`.
///
/// # Safety
/// `pointer` must reference `length` readable bytes or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_wal_state_reduce(
    pointer: *const c_char,
    length: usize,
) -> *mut c_char {
    let Some(text) = input(pointer, length) else {
        return std::ptr::null_mut();
    };
    output(wal_state_reduce_json(text))
}

/// Decides one WAL operation-relation command over the JSON envelope
/// documented on `rish_agent_core::wal_operations::reduce_json`.
///
/// # Safety
/// `pointer` must reference `length` readable bytes or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_wal_operation_reduce(
    pointer: *const c_char,
    length: usize,
) -> *mut c_char {
    let Some(text) = input(pointer, length) else {
        return std::ptr::null_mut();
    };
    output(wal_operation_reduce_json(text))
}

/// One storage root's resident WAL state. The host holds the root lock, so
/// contention is not expected; the mutex is here so a handle can never be torn
/// by a caller that forgets.
struct WalHandle(std::sync::Mutex<Resident>);

fn wal_handle<'a>(pointer: *mut std::ffi::c_void) -> Option<&'a WalHandle> {
    if pointer.is_null() {
        return None;
    }
    // Safety: the pointer came from rish_agent_wal_open and has not been freed.
    Some(unsafe { &*(pointer.cast::<WalHandle>()) })
}

/// Adopts a committed WAL state the host has just read and validated, and
/// returns an opaque handle. Returns null when the state is not JSON. Release
/// it with `rish_agent_wal_close`.
///
/// # Safety
/// `pointer` must reference `length` readable bytes or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_wal_open(
    pointer: *const c_char,
    length: usize,
) -> *mut std::ffi::c_void {
    let Some(text) = input(pointer, length) else {
        return std::ptr::null_mut();
    };
    let Ok(state) = serde_json::from_str(text) else {
        return std::ptr::null_mut();
    };
    let handle = Box::new(WalHandle(std::sync::Mutex::new(Resident::open(state))));
    Box::into_raw(handle).cast::<std::ffi::c_void>()
}

/// The committed state as JSON, or null once the handle has been invalidated
/// by an unknown confirmation — then only a fresh read can say what is on disk.
///
/// # Safety
/// `handle` must come from `rish_agent_wal_open` and not have been closed.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_wal_snapshot(handle: *mut std::ffi::c_void) -> *mut c_char {
    let Some(handle) = wal_handle(handle) else {
        return std::ptr::null_mut();
    };
    let Ok(resident) = handle.0.lock() else {
        return std::ptr::null_mut();
    };
    match resident.snapshot() {
        Some(state) => output(state.to_string()),
        None => std::ptr::null_mut(),
    }
}

/// Takes the candidate state and returns the exact bytes the host must write,
/// or null when the handle is invalid or already holds a candidate.
///
/// # Safety
/// `handle` must come from `rish_agent_wal_open`; `pointer` must reference
/// `length` readable bytes or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_wal_begin(
    handle: *mut std::ffi::c_void,
    pointer: *const c_char,
    length: usize,
) -> *mut c_char {
    let (Some(handle), Some(text)) = (wal_handle(handle), input(pointer, length)) else {
        return std::ptr::null_mut();
    };
    let (Ok(candidate), Ok(mut resident)) = (serde_json::from_str(text), handle.0.lock()) else {
        return std::ptr::null_mut();
    };
    match resident.begin(candidate) {
        Ok(bytes) => match String::from_utf8(bytes) {
            Ok(text) => output(text),
            Err(_) => std::ptr::null_mut(),
        },
        Err(_) => std::ptr::null_mut(),
    }
}

/// Resolves the outstanding candidate. `outcome` is "committed",
/// "not_committed" or "unknown"; the reply is
/// `{"ok":true,"published":<bool>}` or `{"ok":false,"error":<code>}`. An
/// unknown outcome invalidates the handle rather than assuming either way.
///
/// # Safety
/// `handle` must come from `rish_agent_wal_open`; `pointer` must reference
/// `length` readable bytes or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_wal_confirm(
    handle: *mut std::ffi::c_void,
    pointer: *const c_char,
    length: usize,
) -> *mut c_char {
    let (Some(handle), Some(text)) = (wal_handle(handle), input(pointer, length)) else {
        return std::ptr::null_mut();
    };
    let (Some(confirmation), Ok(mut resident)) = (Confirmation::parse(text), handle.0.lock())
    else {
        return std::ptr::null_mut();
    };
    output(
        match resident.confirm(confirmation) {
            Ok(published) => serde_json::json!({ "ok": true, "published": published }),
            Err(error) => serde_json::json!({ "ok": false, "error": error.code() }),
        }
        .to_string(),
    )
}

/// Releases a handle. Null is ignored.
///
/// # Safety
/// `handle` must come from `rish_agent_wal_open` and must not be used again.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_wal_close(handle: *mut std::ffi::c_void) {
    if handle.is_null() {
        return;
    }
    drop(unsafe { Box::from_raw(handle.cast::<WalHandle>()) });
}

/// Decides one runtime-coordinator step over the JSON envelope documented on
/// `rish_agent_core::runtime_coordinator::reduce_json`.
///
/// # Safety
/// `pointer` must reference `length` readable bytes or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_runtime_reduce(
    pointer: *const c_char,
    length: usize,
) -> *mut c_char {
    let Some(text) = input(pointer, length) else {
        return std::ptr::null_mut();
    };
    output(runtime_reduce_json(text))
}
