use crate::RuntimeSpec;
use rquickjs::{Context, Function, Runtime, function::Func};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

const MAX_JSON_BYTES: usize = 4 * 1024 * 1024;
const MAX_JOBS: usize = 8192;
const BUNDLE: &str = include_str!("../vendor/pi-agent-core-1.4.0.js");
const PLATFORM: &str = include_str!("../js/platform.js");
const BRIDGE: &str = include_str!("../js/bridge.js");

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NativeCall {
    pub round_id: String,
    pub round_index: u64,
    pub call_id: String,
    pub name: String,
    pub arguments_sha256: String,
}
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Intent {
    Model {
        round_index: u64,
    },
    Tool {
        round_id: String,
        round_index: u64,
        call_id: String,
        name: String,
        arguments_sha256: String,
    },
}
impl Intent {
    pub fn call(&self) -> Option<NativeCall> {
        match self {
            Self::Tool {
                round_id,
                round_index,
                call_id,
                name,
                arguments_sha256,
            } => Some(NativeCall {
                round_id: round_id.clone(),
                round_index: *round_index,
                call_id: call_id.clone(),
                name: name.clone(),
                arguments_sha256: arguments_sha256.clone(),
            }),
            _ => None,
        }
    }
}
#[derive(Clone, Debug, Deserialize)]
pub struct RuntimeState {
    pub done: bool,
    pub error: Option<String>,
    pub intent: Option<Intent>,
    pub events: Vec<String>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Admission {
    Allow,
    Stop(String),
}

/// Own this on the assistant actor thread. Neither Context nor Runtime is
/// marked Send/Sync, and no JS object leaves it. The hook realm is isolated.
pub struct PiRuntime {
    context: Context,
    runtime: Runtime,
    deadline: Arc<Mutex<Instant>>,
    spec: RuntimeSpec,
}
impl PiRuntime {
    pub fn new(
        spec: RuntimeSpec,
        round_index: u64,
        model: &str,
        context_ref: &str,
        timestamp: u64,
    ) -> Result<Self, String> {
        spec.validate_supported()?;
        if round_index >= 8 || model.is_empty() || model.len() > 256 || context_ref.len() > 1024 {
            return Err("E_ASSISTANT_RUNTIME_CONTEXT".into());
        }
        let runtime = Runtime::new().map_err(js_error)?;
        runtime.set_memory_limit(64 * 1024 * 1024);
        runtime.set_max_stack_size(512 * 1024);
        let deadline = Arc::new(Mutex::new(Instant::now() + Duration::from_secs(3)));
        let interrupt = deadline.clone();
        runtime.set_interrupt_handler(Some(Box::new(move || {
            Instant::now() >= *interrupt.lock().unwrap_or_else(|e| e.into_inner())
        })));
        let context = Context::full(&runtime).map_err(js_error)?;
        context.with(|ctx| {
            // Pure URL parsing for the upstream TypeBox validator. It performs
            // no IO and is never made available to user script hooks.
            ctx.globals().set("__rishUrl", Func::from(|value:String, base:String| {
                let url = if base.is_empty() { url::Url::parse(&value) } else { url::Url::parse(&base).and_then(|b|b.join(&value)) };
                match url { Ok(url) => json!({"href":url.as_str(),"hash":url.fragment().map(|s|format!("#{s}")).unwrap_or_default()}).to_string(), Err(_) => "null".into() }
            })).map_err(js_error)?;
            for source in [PLATFORM, BUNDLE, BRIDGE] { ctx.eval::<(),_>(source).map_err(|_| exception(&ctx))?; }
            Ok::<_,String>(())
        })?;
        let mut engine = Self {
            context,
            runtime,
            deadline,
            spec,
        };
        engine.call("start", json!({"round_index":round_index,"model":model,"context_ref":context_ref,"timestamp":timestamp}))?;
        engine.pump()?;
        // Validate shape/syntax even before the first native model effect.
        engine.check_hook_shape()?;
        Ok(engine)
    }
    fn budget(&self, duration: Duration) {
        *self.deadline.lock().unwrap_or_else(|e| e.into_inner()) = Instant::now() + duration;
    }
    fn call(&mut self, method: &str, value: Value) -> Result<(), String> {
        let input = serde_json::to_string(&value).map_err(|_| "E_ASSISTANT_RUNTIME_JSON")?;
        if input.len() > MAX_JSON_BYTES {
            return Err("E_ASSISTANT_RUNTIME_LIMIT".into());
        }
        self.budget(Duration::from_millis(500));
        self.context.with(|ctx| {
            let api: rquickjs::Object = ctx.globals().get("__rishPi").map_err(js_error)?;
            let function: Function = api.get(method).map_err(js_error)?;
            function
                .call::<_, ()>((input,))
                .map_err(|_| exception(&ctx))
        })
    }
    fn pump(&mut self) -> Result<(), String> {
        self.budget(Duration::from_millis(500));
        for _ in 0..MAX_JOBS {
            match self.runtime.execute_pending_job() {
                Ok(false) => return Ok(()),
                Ok(true) => {}
                Err(error) => return Err(error.0.with(|ctx| exception(&ctx))),
            }
        }
        Err("E_ASSISTANT_RUNTIME_JOB_LIMIT".into())
    }
    pub fn state(&self) -> Result<RuntimeState, String> {
        self.budget(Duration::from_millis(100));
        self.context.with(|ctx| {
            let api: rquickjs::Object = ctx.globals().get("__rishPi").map_err(js_error)?;
            let function: Function = api.get("snapshot").map_err(js_error)?;
            let text: String = function.call(()).map_err(|_| exception(&ctx))?;
            if text.len() > MAX_JSON_BYTES {
                return Err("E_ASSISTANT_RUNTIME_LIMIT".into());
            }
            serde_json::from_str(&text).map_err(|_| "E_ASSISTANT_RUNTIME_PROTOCOL".into())
        })
    }
    pub fn admit_model(&mut self, round_index: u64, context: &Value) -> Result<Admission, String> {
        if self.state()?.intent != Some(Intent::Model { round_index }) {
            return Err("E_ASSISTANT_RUNTIME_SEQUENCE".into());
        }
        self.policy("beforeModel", context)
    }
    pub fn admit_tool(&mut self, call: &NativeCall, context: &Value) -> Result<Admission, String> {
        if self
            .state()?
            .intent
            .as_ref()
            .and_then(Intent::call)
            .as_ref()
            != Some(call)
        {
            return Err("E_ASSISTANT_RUNTIME_SEQUENCE".into());
        }
        self.policy("beforeTool", context)
    }
    /// Only call after the shared native contract has validated this outcome.
    pub fn model_result(
        &mut self,
        round_index: u64,
        kind: &str,
        text: Option<&str>,
        calls: &[NativeCall],
        failure: Option<&str>,
    ) -> Result<(), String> {
        if !matches!(kind, "final" | "tool_batch" | "blocked")
            || calls.len() > 16
            || calls.iter().any(|c| c.round_index != round_index)
        {
            return Err("E_ASSISTANT_RUNTIME_PROTOCOL".into());
        }
        let mut value = json!({"round_index":round_index,"kind":kind,"calls":calls});
        if let Some(text) = text {
            value["text"] = json!(text);
        }
        if let Some(failure) = failure {
            value["failure_code"] = json!(failure);
        }
        self.call("modelReply", value)?;
        self.pump()
    }
    /// This content is a real receipt. Private tool output is never invented
    /// or read out of the native journal into a custom script.
    pub fn tool_result(&mut self, call: &NativeCall, receipt: &Value) -> Result<(), String> {
        for key in ["call_id", "name", "arguments_sha256"] {
            if receipt[key] != serde_json::to_value(call).unwrap()[key] {
                return Err("E_ASSISTANT_RUNTIME_RECEIPT".into());
            }
        }
        self.call("toolReply", json!({"call":call,"receipt":receipt}))?;
        self.pump()
    }
    pub fn abort(&mut self) -> Result<(), String> {
        self.call("abort", Value::Null)?;
        self.pump()
    }
    pub fn memory_bytes(&self) -> i64 {
        self.runtime.memory_usage().memory_used_size
    }
    fn check_hook_shape(&mut self) -> Result<(), String> {
        self.run_policy(None, &Value::Null).map(|_| ())
    }
    fn policy(&mut self, method: &str, context: &Value) -> Result<Admission, String> {
        self.run_policy(Some(method), context)
    }
    fn run_policy(&mut self, method: Option<&str>, context: &Value) -> Result<Admission, String> {
        let Some(source) = self.spec.source() else {
            return Ok(Admission::Allow);
        };
        if self.runtime.is_job_pending() {
            return Err("E_ASSISTANT_RUNTIME_PENDING_JOB".into());
        }
        // A fresh realm for each synchronous hook prevents hidden mutable state
        // and prototype changes from leaking into Pi or restart recovery.
        self.budget(Duration::from_millis(100));
        let realm = Context::full(&self.runtime).map_err(js_error)?;
        let result=realm.with(|ctx| {
            ctx.globals().set("__rish_context",context.to_string()).map_err(js_error)?;
            let script=format!("const hooks=({source}); if(!hooks||typeof hooks!=='object'||Object.keys(hooks).some(k=>!['beforeModel','beforeTool'].includes(k))||Object.values(hooks).some(v=>typeof v!=='function')) throw new Error('Invalid hooks'); JSON.stringify({})", match method {Some(name)=>format!("hooks.{name} ? hooks.{name}(Object.freeze(JSON.parse(__rish_context))) : {{allow:true}}"), None=>"({allow:true})".into()});
            let text:String=ctx.eval(script).map_err(|_| exception(&ctx))?;
            if text.len()>1024 { return Err("E_ASSISTANT_RUNTIME_SCRIPT_RESULT".into()); }
            let result:Value=serde_json::from_str(&text).map_err(|_|"E_ASSISTANT_RUNTIME_SCRIPT_RESULT")?;
            if result==json!({"allow":true}) { Ok(Admission::Allow) }
            else if result.as_object().is_some_and(|o|o.len()==1) && result["stop"].as_str().is_some_and(|s|!s.trim().is_empty()&&s.len()<=512&&!s.contains('\0')) { Ok(Admission::Stop(result["stop"].as_str().unwrap().to_owned())) }
            else { Err("E_ASSISTANT_RUNTIME_SCRIPT_RESULT".into()) }
        });
        if self.runtime.is_job_pending() {
            return Err("E_ASSISTANT_RUNTIME_ASYNC_HOOK".into());
        }
        result
    }
}
fn js_error(error: rquickjs::Error) -> String {
    format!("E_ASSISTANT_RUNTIME_JS: {error}")
}
fn exception(ctx: &rquickjs::Ctx<'_>) -> String {
    let value = ctx.catch();
    let text = value
        .as_exception()
        .and_then(|e| e.message())
        .unwrap_or_else(|| "JavaScript execution stopped".into());
    format!(
        "E_ASSISTANT_RUNTIME_JS: {}",
        text.chars().take(320).collect::<String>()
    )
}

#[cfg(test)]
#[path = "tests.rs"]
mod tests;
