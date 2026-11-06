//! Existing workspace C exports; shared ownership helpers remain in lib.rs.
use super::{input, output};
use rish_agent_core::workspace_authority::reduce_json as workspace_authority_reduce_json;
use rish_agent_core::workspace_clearance::reduce_json as workspace_clearance_reduce_json;
use rish_agent_core::workspace_directory_name::reduce_json as workspace_directory_name_reduce_json;
use rish_agent_core::workspace_error::reduce_json as workspace_error_reduce_json;
use rish_agent_core::workspace_fingerprint::reduce_json as workspace_fingerprint_reduce_json;
use rish_agent_core::workspace_grants::reduce_json as workspace_grants_reduce_json;
use rish_agent_core::workspace_journal::reduce_json as workspace_journal_reduce_json;
use rish_agent_core::workspace_json::bounded_exact_structure;
use rish_agent_core::workspace_read_tools::reduce_json as workspace_read_tools_reduce_json;
use rish_agent_core::workspace_receipt::reduce_json as workspace_receipt_reduce_json;
use rish_agent_core::workspace_record::reduce_json as workspace_record_reduce_json;
use rish_agent_core::workspace_tool::reduce_json as workspace_tool_reduce_json;
use std::os::raw::c_char;

/// Runs one workspace-clearance decision over the JSON envelope documented on
/// `rish_agent_core::workspace_clearance::reduce_json` — what a destructive
/// operation and its consent receipt look like, and whether a receipt
/// authorises the operation in front of it.
///
/// # Safety
/// `pointer` must reference `length` readable bytes or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_workspace_clearance_reduce(
    pointer: *const c_char,
    length: usize,
) -> *mut c_char {
    let Some(text) = input(pointer, length) else {
        return std::ptr::null_mut();
    };
    output(workspace_clearance_reduce_json(text))
}

/// Runs one workspace-error decision over the JSON envelope documented on
/// `rish_agent_core::workspace_error::reduce_json` — which public code and
/// message a workspace failure is reported as. The mapping is contract: a
/// caller branches on the code, so both platforms have to answer alike.
///
/// # Safety
/// `pointer` must reference `length` readable bytes or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_workspace_error_reduce(
    pointer: *const c_char,
    length: usize,
) -> *mut c_char {
    let Some(text) = input(pointer, length) else {
        return std::ptr::null_mut();
    };
    output(workspace_error_reduce_json(text))
}

/// Whether stored workspace bytes are JSON this engine will look at:
/// `rish_agent_core::workspace_json::bounded_exact_structure`. Unlike the
/// other reducers this takes the raw bytes rather than an envelope, because
/// the whole question is about bytes that may not be JSON at all. Returns 1
/// for acceptable, 0 otherwise.
///
/// # Safety
/// `pointer` must reference `length` readable bytes or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_workspace_json_bounded(
    pointer: *const c_char,
    length: usize,
) -> u8 {
    if pointer.is_null() {
        return 0;
    }
    let bytes = std::slice::from_raw_parts(pointer as *const u8, length);
    u8::from(bounded_exact_structure(bytes))
}

/// Runs one workspace-journal decision over the JSON envelope documented on
/// `rish_agent_core::workspace_journal::reduce_json` — what an operation
/// journal looks like mid-flight, and how its recorded identity relates to
/// what is on disk. Statting stays with the host, which passes the four
/// identifiers it read as the canonical strings the journal holds.
///
/// # Safety
/// `pointer` must reference `length` readable bytes or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_workspace_journal_reduce(
    pointer: *const c_char,
    length: usize,
) -> *mut c_char {
    let Some(text) = input(pointer, length) else {
        return std::ptr::null_mut();
    };
    output(workspace_journal_reduce_json(text))
}

/// Runs one workspace read-tool decision over the JSON envelope documented on
/// `rish_agent_core::workspace_read_tools::reduce_json` — which readers a
/// workspace exposes and what their options may be. The list is closed, and an
/// option key the rule does not recognise is refused rather than ignored.
///
/// # Safety
/// `pointer` must reference `length` readable bytes or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_workspace_read_tools_reduce(
    pointer: *const c_char,
    length: usize,
) -> *mut c_char {
    let Some(text) = input(pointer, length) else {
        return std::ptr::null_mut();
    };
    output(workspace_read_tools_reduce_json(text))
}

/// Runs one workspace-receipt decision over the JSON envelope documented on
/// `rish_agent_core::workspace_receipt::reduce_json` — what a stored operation
/// receipt looks like, what a caller is shown of one, and whether one has
/// outlived its retry window. Parsing the timestamp stays with the host: it
/// passes the age it measured.
///
/// # Safety
/// `pointer` must reference `length` readable bytes or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_workspace_receipt_reduce(
    pointer: *const c_char,
    length: usize,
) -> *mut c_char {
    let Some(text) = input(pointer, length) else {
        return std::ptr::null_mut();
    };
    output(workspace_receipt_reduce_json(text))
}

/// Runs one workspace-record decision over the JSON envelope documented on
/// `rish_agent_core::workspace_record::reduce_json` — what a stored registry
/// record looks like. Case-and-diacritic folding stays with the host.
///
/// # Safety
/// `pointer` must reference `length` readable bytes or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_workspace_record_reduce(
    pointer: *const c_char,
    length: usize,
) -> *mut c_char {
    let Some(text) = input(pointer, length) else {
        return std::ptr::null_mut();
    };
    output(workspace_record_reduce_json(text))
}

/// Runs one workspace-authority decision over the JSON envelope documented on
/// `rish_agent_core::workspace_authority::reduce_json` — what a stored
/// authority looks like and how it is tied to its record. Base64 decoding
/// stays with the host; the decoded bookmark's length and digest come in as
/// facts.
///
/// # Safety
/// `pointer` must reference `length` readable bytes or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_workspace_authority_reduce(
    pointer: *const c_char,
    length: usize,
) -> *mut c_char {
    let Some(text) = input(pointer, length) else {
        return std::ptr::null_mut();
    };
    output(workspace_authority_reduce_json(text))
}

/// Runs one workspace directory-name decision over the JSON envelope
/// documented on `rish_agent_core::workspace_directory_name::reduce_json` —
/// what a registry-owned path component may be, and what an occupied display
/// name is called at each ordinal. Folding and grapheme segmentation stay with
/// the host; where the cut falls does not.
///
/// # Safety
/// `pointer` must reference `length` readable bytes or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_workspace_directory_name_reduce(
    pointer: *const c_char,
    length: usize,
) -> *mut c_char {
    let Some(text) = input(pointer, length) else {
        return std::ptr::null_mut();
    };
    output(workspace_directory_name_reduce_json(text))
}

/// Runs one workspace-grant decision over the JSON envelope documented on
/// `rish_agent_core::workspace_grants::reduce_json` — what a stored record is
/// allowed to do, and how that is shown.
///
/// # Safety
/// `pointer` must reference `length` readable bytes or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_workspace_grants_reduce(
    pointer: *const c_char,
    length: usize,
) -> *mut c_char {
    let Some(text) = input(pointer, length) else {
        return std::ptr::null_mut();
    };
    output(workspace_grants_reduce_json(text))
}

/// Runs one workspace root-fingerprint decision over the JSON envelope
/// documented on `rish_agent_core::workspace_fingerprint::reduce_json` — what
/// binds a workspace authority to a physical directory.
///
/// # Safety
/// `pointer` must reference `length` readable bytes or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_workspace_fingerprint_reduce(
    pointer: *const c_char,
    length: usize,
) -> *mut c_char {
    let Some(text) = input(pointer, length) else {
        return std::ptr::null_mut();
    };
    output(workspace_fingerprint_reduce_json(text))
}

/// Runs one workspace-tool decision over the JSON envelope documented on
/// `rish_agent_core::workspace_tool::reduce_json`.
///
/// # Safety
/// `pointer` must reference `length` readable bytes or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_workspace_tool_reduce(
    pointer: *const c_char,
    length: usize,
) -> *mut c_char {
    let Some(text) = input(pointer, length) else {
        return std::ptr::null_mut();
    };
    output(workspace_tool_reduce_json(text))
}
