use std::ffi::{CStr, CString, c_char};

unsafe extern "C" {
    fn rish_gpui_host_request(
        id: u64,
        module: *const c_char,
        method: *const c_char,
        args: *const c_char,
    );
}

pub(super) fn dispatch(id: u64, module: &str, method: &str, args: &str) -> Result<(), String> {
    let strings: Result<Vec<_>, _> = [module, method, args]
        .into_iter()
        .map(CString::new)
        .collect();
    let strings = strings.map_err(|_| "Invalid native request string".to_string())?;
    // The host copies all strings synchronously before enqueuing work.
    unsafe {
        rish_gpui_host_request(
            id,
            strings[0].as_ptr(),
            strings[1].as_ptr(),
            strings[2].as_ptr(),
        );
    }
    Ok(())
}

/// # Safety
/// The host lends a valid NUL-terminated UTF-8 JSON buffer for this call only.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rish_gpui_host_reply(id: u64, json: *const c_char, rejected: bool) {
    if json.is_null() {
        super::receive_reply(id, Err("Native reply was missing".into()));
        return;
    }
    match unsafe { CStr::from_ptr(json) }.to_str() {
        Ok(json) => super::decode_reply(id, json, rejected),
        Err(_) => super::receive_reply(id, Err("Native reply was not UTF-8".into())),
    }
}

/// # Safety
/// Both arguments must remain valid NUL-terminated UTF-8 strings during this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rish_gpui_host_event(name: *const c_char, json: *const c_char) {
    if name.is_null() || json.is_null() {
        return;
    }
    let name = unsafe { CStr::from_ptr(name) }.to_str();
    let json = unsafe { CStr::from_ptr(json) }.to_str();
    if let (Ok(name), Ok(json)) = (name, json) {
        if let Ok(payload) = serde_json::from_str(json) {
            super::receive_event(name.to_owned(), payload);
        }
    }
}
