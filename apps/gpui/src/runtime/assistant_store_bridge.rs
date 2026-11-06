//! Native effect adapters call the shared store only after their ledger gate.
//! The native host supplies its private directory; model arguments never do.
use rish_shell_core::assistant_store::{AssistantStore, AssistantStoreError};
use serde_json::{Value, json};
use std::path::Path;

const MAX_REQUEST_BYTES: usize = 128 * 1024;
const MAX_REPLY_BYTES: usize = 256 * 1024;

fn failure(code: &str) -> String {
    json!({"ok": false, "error": code}).to_string()
}

fn error_code(error: AssistantStoreError) -> &'static str {
    match error {
        AssistantStoreError::Conflict { .. }
        | AssistantStoreError::Running
        | AssistantStoreError::StaleClaim
        | AssistantStoreError::NotDue => "E_AGENT_CONFLICT",
        AssistantStoreError::NotFound => "E_AGENT_NOT_FOUND",
        AssistantStoreError::Invalid(_) => "E_AGENT_BAD_ARGUMENTS",
        AssistantStoreError::Corrupt
        | AssistantStoreError::UnsafePath
        | AssistantStoreError::Io(_) => "E_AGENT_PERSISTENCE",
    }
}

pub(super) fn call(directory: &str, request: &str) -> String {
    if directory.len() > 4096
        || directory.contains('\0')
        || !Path::new(directory).is_absolute()
        || request.len() > MAX_REQUEST_BYTES
    {
        return failure("E_AGENT_BAD_ARGUMENTS");
    }
    let result = std::panic::catch_unwind(|| {
        let request: Value = serde_json::from_str(request).map_err(|_| "E_AGENT_BAD_ARGUMENTS")?;
        if !request.is_object() {
            return Err("E_AGENT_BAD_ARGUMENTS");
        }
        let store = AssistantStore::open(directory).map_err(error_code)?;
        let result = store.task_tool(&request).map_err(error_code)?;
        if matches!(request["action"].as_str(), Some("apply" | "recover")) && !result.is_null() {
            // A read-model refresh grants no session writer. PollDue still
            // waits for the UI's normal exclusive-writer handoff.
            let _ = crate::assistant_runtime::RunnerHandle::process()
                .send(crate::assistant_runtime::RunnerCommand::RefreshStore);
        }
        Ok::<_, &'static str>(json!({"ok": true, "result": result}).to_string())
    });
    match result {
        Ok(Ok(reply)) if reply.len() <= MAX_REPLY_BYTES => reply,
        Ok(Err(code)) => failure(code),
        // Persist may already have committed. Native must recover its exact
        // receipt instead of treating a missing reply as a no-effect failure.
        _ => failure("E_AGENT_PERSISTENCE"),
    }
}

#[cfg(target_os = "ios")]
mod ios {
    use std::ffi::{CStr, CString, c_char};

    /// # Safety
    /// `directory` is a valid NUL-terminated host path and `request` lends
    /// `length` readable bytes for this call. The caller frees the result once.
    #[unsafe(no_mangle)]
    pub unsafe extern "C" fn rish_gpui_assistant_store_json(
        directory: *const c_char,
        request: *const u8,
        length: usize,
    ) -> *mut c_char {
        let reply = if directory.is_null() || request.is_null() || length > super::MAX_REQUEST_BYTES
        {
            super::failure("E_AGENT_BAD_ARGUMENTS")
        } else {
            let directory = unsafe { CStr::from_ptr(directory) }.to_str();
            let request =
                std::str::from_utf8(unsafe { std::slice::from_raw_parts(request, length) });
            match (directory, request) {
                (Ok(directory), Ok(request)) => super::call(directory, request),
                _ => super::failure("E_AGENT_BAD_ARGUMENTS"),
            }
        };
        // JSON serialization escapes NULs; none of the fixed errors contains one.
        CString::new(reply).expect("JSON without NUL").into_raw()
    }

    /// # Safety
    /// `reply` is null or an unfreed pointer returned by the matching function.
    #[unsafe(no_mangle)]
    pub unsafe extern "C" fn rish_gpui_assistant_store_free(reply: *mut c_char) {
        if !reply.is_null() {
            drop(unsafe { CString::from_raw(reply) });
        }
    }
}

#[cfg(target_os = "android")]
mod android {
    use jni::{
        EnvUnowned,
        objects::{JClass, JString},
    };

    #[unsafe(no_mangle)]
    pub extern "system" fn Java_tech_zseven_rish_runtime_RishAssistantStoreNative_call<'caller>(
        mut environment: EnvUnowned<'caller>,
        _class: JClass<'caller>,
        directory: JString<'caller>,
        request: JString<'caller>,
    ) -> JString<'caller> {
        environment
            .with_env(|env| -> jni::errors::Result<_> {
                let directory = directory.to_string();
                let request = request.to_string();
                JString::from_str(env, super::call(&directory, &request))
            })
            .resolve::<jni::errors::ThrowRuntimeExAndDefault>()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn malformed_requests_never_expose_input_or_native_paths() {
        for (directory, request) in [
            ("relative", "{}".to_string()),
            (
                "/private/does-not-exist",
                "secret malformed request".to_string(),
            ),
            ("/private/does-not-exist", "x".repeat(MAX_REQUEST_BYTES + 1)),
            ("/private/does-not-exist", "[]".to_string()),
        ] {
            let reply: Value = serde_json::from_str(&call(directory, &request)).unwrap();
            assert_eq!(reply, json!({"ok":false,"error":"E_AGENT_BAD_ARGUMENTS"}));
        }
    }
}
