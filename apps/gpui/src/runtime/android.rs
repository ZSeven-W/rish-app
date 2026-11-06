use gpui_mobile::android::jni as mobile_jni;
use jni::objects::{JObject, JValue};
use std::ffi::c_void;

pub(super) fn dispatch(id: u64, module: &str, method: &str, args: &str) -> Result<(), String> {
    mobile_jni::with_env(|env| {
        let class = mobile_jni::find_app_class(env, "tech.zseven.rish.gpui.RishGpuiBridge")?;
        let module = env.new_string(module).map_err(|e| e.to_string())?;
        let method = env.new_string(method).map_err(|e| e.to_string())?;
        let args = env.new_string(args).map_err(|e| e.to_string())?;
        env.call_static_method(
            class,
            jni::jni_str!("dispatch"),
            jni::jni_sig!("(JLjava/lang/String;Ljava/lang/String;Ljava/lang/String;)V"),
            &[
                JValue::Long(id as i64),
                JValue::Object(&module),
                JValue::Object(&method),
                JValue::Object(&args),
            ],
        )
        .map_err(|_| {
            let _ = env.exception_clear();
            "Android runtime dispatch failed".to_string()
        })?;
        Ok(())
    })
}

/// # Safety
/// Called only by the JVM with a borrowed Java String and valid JNI call frame.
#[unsafe(no_mangle)]
pub unsafe extern "system" fn Java_tech_zseven_rish_gpui_RishGpuiBridge_reply(
    _env: *mut c_void,
    _class: *mut c_void,
    id: i64,
    json: *mut c_void,
    rejected: u8,
) {
    let result = mobile_jni::with_env(|env| {
        let value = unsafe { JObject::from_raw(env, json as jni::sys::jobject) };
        let text = mobile_jni::get_string(env, &value);
        super::decode_reply(id as u64, &text, rejected != 0);
        Ok(())
    });
    if result.is_err() {
        super::receive_reply(id as u64, Err("Android reply could not be decoded".into()));
    }
}

/// # Safety
/// Called only by the JVM with two borrowed Java Strings in a valid call frame.
#[unsafe(no_mangle)]
pub unsafe extern "system" fn Java_tech_zseven_rish_gpui_RishGpuiBridge_event(
    _env: *mut c_void,
    _class: *mut c_void,
    name: *mut c_void,
    json: *mut c_void,
) {
    let _ = mobile_jni::with_env(|env| {
        let name = unsafe { JObject::from_raw(env, name as jni::sys::jobject) };
        let json = unsafe { JObject::from_raw(env, json as jni::sys::jobject) };
        let name = mobile_jni::get_string(env, &name);
        let json = mobile_jni::get_string(env, &json);
        if let Ok(payload) = serde_json::from_str(&json) {
            super::receive_event(name, payload);
        }
        Ok(())
    });
}
