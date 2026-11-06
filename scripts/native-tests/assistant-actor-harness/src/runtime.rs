//! Test transport only. Every request is fulfilled by the real iOS facade.
use futures::channel::oneshot;
use rish_shell_core::RuntimeCommand;
use serde_json::Value;
use std::collections::VecDeque;
use std::sync::{
    Mutex, OnceLock,
    atomic::{AtomicU64, Ordering},
};

pub struct Request {
    pub id: u64,
    pub command: RuntimeCommand,
    pub reply: oneshot::Sender<Result<Value, String>>,
}
static QUEUE: OnceLock<Mutex<VecDeque<Request>>> = OnceLock::new();
static NEXT: AtomicU64 = AtomicU64::new(1);
fn queue() -> &'static Mutex<VecDeque<Request>> {
    QUEUE.get_or_init(Mutex::default)
}
pub fn take() -> Option<Request> {
    queue().lock().unwrap().pop_front()
}

#[cfg(test)]
pub(crate) fn receive_event(name: String, payload: Value) {
    // Retain the actor's existing unit-test ingress; this headless adapter has
    // no GPUI display queue and does not purport to test that queue.
    crate::assistant_runtime::receive_native_event(&name, &payload);
}

#[derive(Clone, Default)]
pub struct Runtime;
impl Runtime {
    pub async fn call(&self, module: &str, method: &str, args: Value) -> Result<Value, String> {
        let (reply, receiver) = oneshot::channel();
        queue().lock().unwrap().push_back(Request {
            id: NEXT.fetch_add(1, Ordering::Relaxed),
            command: RuntimeCommand::new(
                module,
                method,
                args.as_array().ok_or("Expected arguments array")?.clone(),
            ),
            reply,
        });
        receiver
            .await
            .map_err(|_| "Native test reply disconnected".to_owned())?
    }
}
