//! Pure policy entry points used by both native shells and the Rust UI.
use super::{input, output};
use std::os::raw::c_char;

/// Validate and project display-only round archives; never grants authority.
///
/// # Safety
/// `pointer` must reference `length` readable bytes or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_round_presentation_reduce(
    pointer: *const c_char,
    length: usize,
) -> *mut c_char {
    let Some(text) = input(pointer, length) else {
        return std::ptr::null_mut();
    };
    output(rish_agent_core::round_presentation::reduce_json(text))
}

/// Normalize and validate a completed workspace or conversation name.
///
/// # Safety
/// `pointer` must reference `length` readable bytes or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_name_policy_reduce(
    pointer: *const c_char,
    length: usize,
) -> *mut c_char {
    let Some(text) = input(pointer, length) else {
        return std::ptr::null_mut();
    };
    output(rish_agent_core::name_policy::reduce_json(text))
}

/// Validate a Git remote and return its transport and credential identities.
///
/// # Safety
/// `pointer` must reference `length` readable bytes or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_git_remote_policy_reduce(
    pointer: *const c_char,
    length: usize,
) -> *mut c_char {
    let Some(text) = input(pointer, length) else {
        return std::ptr::null_mut();
    };
    output(rish_agent_core::git_remote_policy::reduce_json(text))
}

/// Validate, evolve or query the persisted model directory without doing IO.
///
/// # Safety
/// `pointer` must reference `length` readable bytes or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_model_catalog_reduce(
    pointer: *const c_char,
    length: usize,
) -> *mut c_char {
    let Some(text) = input(pointer, length) else {
        return std::ptr::null_mut();
    };
    output(rish_agent_core::model_catalog::reduce_json(text))
}

/// Apply provider rules while the host owns URL codecs and credential storage.
///
/// # Safety
/// `pointer` must reference `length` readable bytes or be null.
#[no_mangle]
pub unsafe extern "C" fn rish_agent_provider_policy_reduce(
    pointer: *const c_char,
    length: usize,
) -> *mut c_char {
    let Some(text) = input(pointer, length) else {
        return std::ptr::null_mut();
    };
    output(rish_agent_core::provider_policy::reduce_json(text))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rish_agent_string_free;
    use std::ffi::CStr;

    type Reducer = unsafe extern "C" fn(*const c_char, usize) -> *mut c_char;

    unsafe fn invoke(reducer: Reducer, input: &[u8]) -> Option<serde_json::Value> {
        let reply = reducer(input.as_ptr().cast(), input.len());
        if reply.is_null() {
            return None;
        }
        let result = serde_json::from_slice(CStr::from_ptr(reply).to_bytes()).unwrap();
        rish_agent_string_free(reply);
        Some(result)
    }

    #[test]
    fn native_name_abi_preserves_unicode_and_reports_the_persistence_limit() {
        unsafe {
            let request =
                serde_json::json!({"kind":"conversation","text":"  Cafe\u{301}  "}).to_string();
            let reply = invoke(rish_agent_name_policy_reduce, request.as_bytes()).unwrap();
            assert_eq!(reply["value"]["text"], "Café");
            assert!(reply["value"]["issue"].is_null());
            let request =
                serde_json::json!({"kind":"conversation","text":"中".repeat(41)}).to_string();
            let reply = invoke(rish_agent_name_policy_reduce, request.as_bytes()).unwrap();
            assert_eq!(reply["value"]["issue"], "too_long");
        }
    }

    #[test]
    fn native_policy_abi_rejects_null_invalid_utf8_and_duplicate_keys() {
        for reducer in [
            rish_agent_name_policy_reduce as Reducer,
            rish_agent_git_remote_policy_reduce,
            rish_agent_model_catalog_reduce,
            rish_agent_provider_policy_reduce,
            rish_agent_round_presentation_reduce,
        ] {
            unsafe {
                assert!(reducer(std::ptr::null(), 0).is_null());
                assert!(invoke(reducer, &[0xff]).is_none());
                assert_eq!(
                    invoke(reducer, br#"{"url":"a","url":"b"}"#).unwrap()["ok"],
                    false
                );
            }
        }
    }

    #[test]
    fn native_git_abi_uses_the_shared_remote_policy() {
        unsafe {
            let reply = invoke(
                rish_agent_git_remote_policy_reduce,
                br#"{"url":"https://github.com/example/repo.git"}"#,
            )
            .unwrap();
            assert_eq!(reply["ok"], true);
            assert_eq!(reply["value"]["host"], "github.com");
            let reply = invoke(
                rish_agent_git_remote_policy_reduce,
                br#"{"url":"https://8.8.8.8/example/repo.git"}"#,
            )
            .unwrap();
            assert_eq!(reply["ok"], false);
        }
    }

    #[test]
    fn native_catalog_abi_preserves_history_when_active_models_change() {
        unsafe {
            let current = invoke(rish_agent_model_catalog_reduce, br#"{"op":"default"}"#).unwrap();
            let request = serde_json::json!({"op":"save","catalog":current["value"],
                "request":{"schema_version":1,"models":[{"id":"team-chat","name":"团队模型","supports_images":false}]}}).to_string();
            let reply = invoke(rish_agent_model_catalog_reduce, request.as_bytes()).unwrap();
            assert_eq!(reply["ok"], true);
            assert_eq!(reply["value"]["models"][0]["id"], "team-chat");
            assert_eq!(
                reply["value"]["retired_models"].as_array().unwrap().len(),
                3
            );
        }
    }

    #[test]
    fn native_provider_abi_keeps_official_credential_accounts() {
        unsafe {
            let defaults = invoke(
                rish_agent_provider_policy_reduce,
                br#"{"op":"defaults","harness_id":"codex"}"#,
            )
            .unwrap();
            let request = serde_json::json!({"op":"credential_account","slot":"OPENAI_API_KEY",
                "configuration":defaults["value"]})
            .to_string();
            let reply = invoke(rish_agent_provider_policy_reduce, request.as_bytes()).unwrap();
            assert_eq!(reply["ok"], true);
            assert_eq!(reply["value"], "OPENAI_API_KEY");
        }
    }

    #[test]
    fn native_provider_model_directory_has_no_implicit_choices_and_retains_ownership() {
        unsafe {
            let empty = invoke(
                rish_agent_model_catalog_reduce,
                br#"{"op":"provider_read","registry":null}"#,
            )
            .unwrap();
            assert_eq!(empty["ok"], true);
            assert!(empty["value"]["providers"]
                .as_array()
                .unwrap()
                .iter()
                .all(|provider| provider["models"].as_array().unwrap().is_empty()));
            let command = serde_json::json!({"op":"provider_save","registry":empty["value"],
                "request":{"schema_version":1,"expected_revision":0,"harness_id":"glm",
                "models":[{"id":"glm-native-fetched","name":"Fetched model","supports_images":true}]}}).to_string();
            let saved = invoke(rish_agent_model_catalog_reduce, command.as_bytes()).unwrap();
            assert_eq!(saved["ok"], true);
            let query = serde_json::json!({"op":"provider_harness","registry":saved["value"],
                "model":"glm-native-fetched"})
            .to_string();
            assert_eq!(
                invoke(rish_agent_model_catalog_reduce, query.as_bytes()).unwrap()["value"],
                "glm"
            );
            let collision = serde_json::json!({"op":"provider_save","registry":saved["value"],
                "request":{"schema_version":1,"expected_revision":1,"harness_id":"dsh",
                "models":[{"id":"glm-native-fetched","name":"Other","supports_images":false}]}})
            .to_string();
            assert_eq!(
                invoke(rish_agent_model_catalog_reduce, collision.as_bytes()).unwrap()["ok"],
                false
            );
        }
    }
}
