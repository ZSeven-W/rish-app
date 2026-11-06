//! Asynchronous, bounded transport to the existing native JSON contracts.
//! Credentials never enter this transport: the hosts present their own editors.
use futures::channel::oneshot;
use futures::task::AtomicWaker;
use serde_json::Value;
use std::collections::{HashMap, VecDeque};
use std::sync::{
    Mutex, OnceLock,
    atomic::{AtomicU64, Ordering},
};

#[cfg(any(test, target_os = "ios", target_os = "android"))]
mod assistant_store_bridge;

#[cfg(target_os = "android")]
mod android;
#[cfg(target_os = "ios")]
mod ios;

type Reply = Result<Value, String>;
type Pending = HashMap<u64, oneshot::Sender<Reply>>;
static NEXT_REQUEST: AtomicU64 = AtomicU64::new(1);
static PENDING: OnceLock<Mutex<Pending>> = OnceLock::new();
static EVENTS: OnceLock<Mutex<VecDeque<RuntimeEvent>>> = OnceLock::new();
static EVENT_WAKER: AtomicWaker = AtomicWaker::new();

#[derive(Clone, Debug)]
pub struct RuntimeEvent {
    pub name: String,
    pub payload: Value,
}

#[derive(Clone, Default)]
pub struct Runtime;

impl Runtime {
    pub async fn call(&self, module: &str, method: &str, args: Value) -> Reply {
        if !args.is_array() {
            return Err("Native arguments must be a JSON array".into());
        }
        let id = NEXT_REQUEST.fetch_add(1, Ordering::Relaxed);
        let (sender, receiver) = oneshot::channel();
        {
            let mut pending = pending().lock().unwrap_or_else(|e| e.into_inner());
            if pending.len() >= 256 {
                return Err("Too many native operations are in progress".into());
            }
            pending.insert(id, sender);
        }
        // Dropping an abandoned view/future cannot leak its reply sender. This
        // does not cancel native effects: cancellation uses the native protocol.
        let _guard = RequestGuard(id);
        if let Err(error) = dispatch(id, module, method, &args.to_string()) {
            receive_reply(id, Err(error));
        }
        receiver
            .await
            .unwrap_or_else(|_| Err("Native operation disconnected".into()))
    }

    pub fn drain_events(&self) -> Vec<RuntimeEvent> {
        events()
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .drain(..)
            .collect()
    }

    /// The shell's single event consumer sleeps between native notifications.
    /// Register before draining so an event arriving during polling cannot be
    /// stranded until another event happens. This queue remains display-only;
    /// task control is already forwarded directly to the process actor.
    pub async fn next_events(&self) -> Vec<RuntimeEvent> {
        futures::future::poll_fn(|cx| {
            EVENT_WAKER.register(cx.waker());
            let batch = self.drain_events();
            if batch.is_empty() {
                std::task::Poll::Pending
            } else {
                std::task::Poll::Ready(batch)
            }
        })
        .await
    }

    pub fn is_native(&self) -> bool {
        cfg!(any(target_os = "ios", target_os = "android"))
    }
}

fn pending() -> &'static Mutex<Pending> {
    PENDING.get_or_init(Mutex::default)
}
fn events() -> &'static Mutex<VecDeque<RuntimeEvent>> {
    EVENTS.get_or_init(Mutex::default)
}

struct RequestGuard(u64);
impl Drop for RequestGuard {
    fn drop(&mut self) {
        pending()
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(&self.0);
    }
}

fn receive_reply(id: u64, result: Reply) {
    let sender = pending()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .remove(&id);
    if let Some(sender) = sender {
        let _ = sender.send(result);
    }
}

#[cfg(any(target_os = "ios", target_os = "android", test))]
fn decode_reply(id: u64, json: &str, rejected: bool) {
    let result = serde_json::from_str::<Value>(json)
        .map_err(|_| "The native host returned invalid JSON".to_string())
        .and_then(|value| {
            if rejected {
                // Native hosts already redact errors; never expose complete
                // request/response payloads as diagnostics.
                let message = value
                    .get("message")
                    .and_then(Value::as_str)
                    .unwrap_or("Native operation failed");
                let code = value.get("code").and_then(Value::as_str).unwrap_or("");
                if code.starts_with("E_")
                    && code.len() <= 100
                    && code
                        .bytes()
                        .all(|b| b.is_ascii_uppercase() || b.is_ascii_digit() || b == b'_')
                {
                    let message = message.trim();
                    if message.is_empty() || message == code {
                        Err(code.to_owned())
                    } else if let Some(detail) = message.strip_prefix(code).filter(|detail| {
                        detail.starts_with(':') || detail.starts_with(char::is_whitespace)
                    }) {
                        let detail =
                            detail.trim_start_matches(|c: char| c == ':' || c.is_whitespace());
                        if detail.is_empty() {
                            Err(code.to_owned())
                        } else {
                            Err(format!("{code}: {detail}"))
                        }
                    } else {
                        Err(format!("{code}: {message}"))
                    }
                } else {
                    Err(message.to_string())
                }
            } else {
                Ok(value)
            }
        });
    receive_reply(id, result);
}

#[cfg(any(target_os = "ios", target_os = "android", test))]
pub(crate) fn receive_event(name: String, payload: Value) {
    // Control is delivered directly to the process actor before the display
    // queue. A suspended or destroyed GPUI view cannot strand native Stop.
    crate::assistant_runtime::receive_native_event(&name, &payload);
    let mut queue = events().lock().unwrap_or_else(|e| e.into_inner());
    // Stream events are display-only previews; authoritative state arrives in
    // replies and committed snapshots. Keep the latest preview for a request.
    if name == "completionPreview"
        && payload.get("text").is_some()
        && payload.get("delta").is_none()
    {
        if let Some(request) = payload.get("request_id") {
            queue.retain(|old| old.name != name || old.payload.get("request_id") != Some(request));
        }
    }
    if queue.len() >= 256 {
        queue.pop_front();
    }
    queue.push_back(RuntimeEvent { name, payload });
    drop(queue);
    EVENT_WAKER.wake();
}

fn dispatch(id: u64, module: &str, method: &str, args: &str) -> Result<(), String> {
    #[cfg(target_os = "ios")]
    {
        ios::dispatch(id, module, method, args)
    }
    #[cfg(target_os = "android")]
    {
        android::dispatch(id, module, method, args)
    }
    #[cfg(not(any(target_os = "ios", target_os = "android")))]
    {
        let _ = (id, module, method, args);
        Err("The desktop preview has no mobile runtime. Run the iOS or Android app to connect models and open native workspaces.".into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    static EVENT_TEST_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn replies_route_by_id_and_dropped_receivers_are_safe() {
        let id = NEXT_REQUEST.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = oneshot::channel();
        pending().lock().unwrap().insert(id, tx);
        decode_reply(id, r#"{"text":"你好 👋"}"#, false);
        let value = futures::executor::block_on(rx).unwrap().unwrap();
        assert_eq!(value["text"], "你好 👋");
        decode_reply(id, "null", false);
        assert!(!pending().lock().unwrap().contains_key(&id));
    }

    #[test]
    fn malformed_native_reply_fails_closed() {
        let id = NEXT_REQUEST.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = oneshot::channel();
        pending().lock().unwrap().insert(id, tx);
        decode_reply(id, "not json", false);
        assert!(futures::executor::block_on(rx).unwrap().is_err());
    }

    #[test]
    fn native_errors_preserve_details_without_repeating_codes() {
        for (message, expected) in [
            ("E_PROJECT_NATIVE", "E_PROJECT_NATIVE"),
            ("  ", "E_PROJECT_NATIVE"),
            ("Git is unavailable", "E_PROJECT_NATIVE: Git is unavailable"),
            (
                "E_PROJECT_NATIVE: Git is unavailable",
                "E_PROJECT_NATIVE: Git is unavailable",
            ),
            (
                "E_PROJECT_NATIVE\noperation=read kind=unavailable",
                "E_PROJECT_NATIVE: operation=read kind=unavailable",
            ),
        ] {
            let id = NEXT_REQUEST.fetch_add(1, Ordering::Relaxed);
            let (tx, rx) = oneshot::channel();
            pending().lock().unwrap().insert(id, tx);
            let payload = serde_json::json!({"code":"E_PROJECT_NATIVE","message":message});
            decode_reply(id, &payload.to_string(), true);
            assert_eq!(
                futures::executor::block_on(rx).unwrap().unwrap_err(),
                expected
            );
        }
    }

    #[test]
    fn previews_are_coalesced_without_dropping_other_requests() {
        let _guard = EVENT_TEST_LOCK.lock().unwrap();
        let suffix = NEXT_REQUEST.fetch_add(1, Ordering::Relaxed).to_string();
        for i in 0..1000 {
            receive_event(
                "completionPreview".into(),
                serde_json::json!({"request_id":suffix,"text":i}),
            );
        }
        let queue = events().lock().unwrap();
        let matching: Vec<_> = queue
            .iter()
            .filter(|e| e.payload["request_id"] == suffix)
            .collect();
        assert_eq!(matching.len(), 1);
        assert_eq!(matching[0].payload["text"], 999);
    }

    #[test]
    fn event_consumer_wakes_and_drains_events_that_arrive_after_polling() {
        use std::{future::Future, pin::pin, sync::Arc, task::Context};
        struct WakeCount(std::sync::atomic::AtomicUsize);
        impl futures::task::ArcWake for WakeCount {
            fn wake_by_ref(this: &Arc<Self>) {
                this.0.fetch_add(1, Ordering::Relaxed);
            }
        }
        let _guard = EVENT_TEST_LOCK.lock().unwrap();
        let runtime = Runtime;
        runtime.drain_events();
        let wake = Arc::new(WakeCount(std::sync::atomic::AtomicUsize::new(0)));
        let waker = futures::task::waker_ref(&wake);
        let mut cx = Context::from_waker(&waker);
        let mut future = pin!(runtime.next_events());
        assert!(future.as_mut().poll(&mut cx).is_pending());
        receive_event("agentRoundPreview".into(), serde_json::json!({"seq":1}));
        assert_eq!(wake.0.load(Ordering::Relaxed), 1);
        let batch = match future.as_mut().poll(&mut cx) {
            std::task::Poll::Ready(batch) => batch,
            _ => panic!("native event did not wake the shell"),
        };
        assert_eq!(batch.len(), 1);
        assert_eq!(batch[0].name, "agentRoundPreview");
        assert_eq!(batch[0].payload["seq"], 1);
        assert!(runtime.drain_events().is_empty());
    }
}
