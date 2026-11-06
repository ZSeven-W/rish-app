//! Process-owned assistant execution. GPUI and native task surfaces are clients;
//! only this actor owns its handed-off session writer.
#[cfg(test)]
mod answer_tests;
mod bot_commands;
mod commands;
#[cfg(test)]
mod creation_tests;
mod driver;
mod flow;
mod group_flow;
mod group_transition;
#[cfg(test)]
mod handoff_tests;
mod native_events;
mod pi_gate;
#[cfg(test)]
pub(crate) mod test_fixture;
#[cfg(test)]
mod tests;

use crate::runtime::Runtime;
use futures::{FutureExt, StreamExt, channel::mpsc, future::BoxFuture, stream::FuturesUnordered};
use rish_shell_core::assistant_store::*;
use rish_shell_core::{RuntimeCommand, ShellState};
use serde_json::Value;
use std::{
    path::PathBuf,
    sync::{Arc, Mutex, OnceLock},
};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RunnerStatus {
    Idle,
    WaitingForForeground,
    Running,
    NeedsAttention,
}

#[derive(Clone, Debug)]
pub struct RunnerSnapshot {
    pub directory: Option<AssistantSnapshot>,
    pub selected_bot_id: String,
    pub active_bot_id: Option<String>,
    pub active_group_id: Option<String>,
    pub store: Option<AssistantSnapshot>,
    /// Display-only while owns_writer is true. Returned transfers authority.
    pub state: Option<ShellState>,
    pub active_task_id: Option<String>,
    pub owns_writer: bool,
    pub foreground: bool,
    pub status: RunnerStatus,
    pub message: Option<String>,
}
impl Default for RunnerSnapshot {
    fn default() -> Self {
        Self {
            directory: None,
            selected_bot_id: DEFAULT_BOT_ID.into(),
            active_bot_id: None,
            active_group_id: None,
            store: None,
            state: None,
            active_task_id: None,
            owns_writer: false,
            foreground: false,
            status: RunnerStatus::Idle,
            message: None,
        }
    }
}

#[derive(Clone, Debug)]
pub enum RunnerEvent {
    Snapshot(RunnerSnapshot),
    HandoffNeeded {
        task_id: String,
    },
    HandoffRejected {
        task_id: String,
        message: String,
    },
    Returned {
        state: ShellState,
    },
    /// The actor accepted this exact question, before attempting persistence.
    /// This is an intake acknowledgement, never proof the answer was saved.
    AnswerAccepted {
        task_id: String,
        run_id: String,
        call_id: String,
    },
    OpenConversation {
        conversation_id: String,
    },
    Error(String),
}

#[derive(Clone, Debug)]
// Grant moves the writer as a single value; all control variants stay simple
// to send from native ingress and UI clients.
#[allow(clippy::large_enum_variant)]
pub enum RunnerCommand {
    SelectBot {
        bot_id: String,
    },
    ForBot {
        bot_id: String,
        command: Box<RunnerCommand>,
    },
    CreateBot {
        expected_revision: u64,
        bot_id: String,
        profile: AssistantProfile,
    },
    CreateGroup {
        expected_revision: u64,
        group_id: String,
        name: String,
        bot_ids: Vec<String>,
    },
    UpdateGroup {
        expected_revision: u64,
        group_id: String,
        name: String,
        bot_ids: Vec<String>,
    },
    SendGroup {
        group_id: String,
        turn_id: String,
        target_bot_id: Option<String>,
        text: String,
        model_id: String,
        workspace_descriptor: Value,
    },
    RecoverGroup {
        group_id: String,
    },
    StopGroup {
        group_id: String,
    },
    Initialize {
        directory: PathBuf,
    },
    /// UI must atomically stop *all* session writers before sending this.
    Grant {
        task_id: String,
        state: ShellState,
        foreground: bool,
    },
    RunNow {
        task_id: String,
    },
    Recover {
        task_id: String,
    },
    PollDue,
    RevokeForeground,
    Stop,
    Approval {
        approval_id: String,
        decision: String,
    },
    Answer {
        call_id: String,
        answer: Option<String>,
    },
    Release,
    RefreshStore,
    SetUserNickname {
        expected_revision: u64,
        nickname: String,
    },
    EnsureConversation {
        expected_revision: u64,
    },
    CreateMemory {
        expected_revision: u64,
        memory_id: String,
        title: String,
        content: String,
        kind: AssistantMemoryKind,
    },
    RememberMemory {
        expected_revision: u64,
        memory_id: Option<String>,
        title: String,
        content: String,
        kind: AssistantMemoryKind,
    },
    ForgetMemory {
        expected_revision: u64,
        memory_id: String,
    },
    SetProfile {
        expected_revision: u64,
        profile: AssistantProfile,
    },
    CreateTask {
        expected_revision: u64,
        task_id: String,
        config: AssistantTaskConfig,
    },
    UpdateTask {
        expected_revision: u64,
        task_id: String,
        config: AssistantTaskConfig,
    },
    RemoveTask {
        expected_revision: u64,
        task_id: String,
    },
    SetEnabled {
        expected_revision: u64,
        task_id: String,
        enabled: bool,
    },
    #[doc(hidden)]
    NativeEvent {
        name: String,
        payload: Value,
    },
}

type Subscribers = Arc<Mutex<Vec<mpsc::UnboundedSender<RunnerEvent>>>>;
#[derive(Clone)]
pub struct RunnerHandle {
    commands: mpsc::UnboundedSender<RunnerCommand>,
    snapshot: Arc<Mutex<RunnerSnapshot>>,
    subscribers: Subscribers,
}
static PROCESS: OnceLock<RunnerHandle> = OnceLock::new();
impl RunnerHandle {
    pub fn process() -> Self {
        PROCESS
            .get_or_init(|| Self::spawn(Arc::new(Runtime)))
            .clone()
    }
    fn spawn(transport: Arc<dyn Transport>) -> Self {
        let (commands, receiver) = mpsc::unbounded();
        let handle = Self {
            commands,
            snapshot: Arc::new(Mutex::new(RunnerSnapshot::default())),
            subscribers: Arc::new(Mutex::new(Vec::new())),
        };
        let owned = handle.clone();
        std::thread::Builder::new()
            .name("rish-assistant".into())
            .spawn(move || {
                futures::executor::block_on(run_loop(owned, receiver, transport));
            })
            .expect("start assistant actor");
        handle
    }
    #[cfg(test)]
    pub(crate) fn test_client(
        snapshot: RunnerSnapshot,
    ) -> (Self, mpsc::UnboundedReceiver<RunnerCommand>) {
        let (commands, receiver) = mpsc::unbounded();
        (
            Self {
                commands,
                snapshot: Arc::new(Mutex::new(snapshot)),
                subscribers: Arc::new(Mutex::new(Vec::new())),
            },
            receiver,
        )
    }
    pub fn send(&self, command: RunnerCommand) -> Result<(), String> {
        self.commands
            .unbounded_send(command)
            .map_err(|_| "Assistant actor disconnected".into())
    }
    pub fn snapshot(&self) -> RunnerSnapshot {
        self.snapshot
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
    }
    pub fn subscribe(&self) -> mpsc::UnboundedReceiver<RunnerEvent> {
        let (sender, receiver) = mpsc::unbounded();
        // Serialize initial snapshot and subscription against publish.
        let mut subscribers = self.subscribers.lock().unwrap_or_else(|e| e.into_inner());
        let _ = sender.unbounded_send(RunnerEvent::Snapshot(self.snapshot()));
        subscribers.push(sender);
        // Reattach clients receive any outstanding handoff again. This only
        // republishes the pending identity; it does not claim or start work.
        let _ = self.send(RunnerCommand::PollDue);
        receiver
    }
    fn publish(&self, event: RunnerEvent) {
        let mut subscribers = self.subscribers.lock().unwrap_or_else(|e| e.into_inner());
        if let RunnerEvent::Snapshot(snapshot) = &event {
            *self.snapshot.lock().unwrap_or_else(|e| e.into_inner()) = snapshot.clone();
        }
        subscribers.retain(|subscriber| subscriber.unbounded_send(event.clone()).is_ok());
    }
}

/// Native ingress never starts an actor/background service by itself.
#[cfg(any(target_os = "ios", target_os = "android", test))]
pub(crate) fn receive_native_event(name: &str, payload: &Value) {
    if matches!(
        name,
        "taskExperienceAction" | "taskExperienceLifecycle" | "agentRoundPreview"
    ) && let Some(handle) = PROCESS.get()
    {
        let _ = handle.send(RunnerCommand::NativeEvent {
            name: name.into(),
            payload: payload.clone(),
        });
    }
}

trait Transport: Send + Sync + 'static {
    fn call(&self, command: RuntimeCommand) -> BoxFuture<'static, Result<Value, String>>;
}
impl Transport for Runtime {
    fn call(&self, command: RuntimeCommand) -> BoxFuture<'static, Result<Value, String>> {
        let runtime = self.clone();
        async move {
            runtime
                .call(&command.module, &command.method, Value::Array(command.args))
                .await
        }
        .boxed()
    }
}

async fn run_loop(
    handle: RunnerHandle,
    mut commands: mpsc::UnboundedReceiver<RunnerCommand>,
    transport: Arc<dyn Transport>,
) {
    let mut driver = driver::Driver::new();
    let mut requests = FuturesUnordered::new();
    loop {
        for operation in driver.outbox.drain(..) {
            let future = transport.call(operation.command.clone());
            requests.push(async move { (operation, future.await) }.boxed());
        }
        for event in driver.events.drain(..) {
            handle.publish(event);
        }
        handle.publish(RunnerEvent::Snapshot(driver.snapshot()));
        // Keep command intake live while provider/tool futures are unresolved.
        if requests.is_empty() {
            let Some(command) = commands.next().await else {
                break;
            };
            driver.command(command);
        } else {
            futures::select_biased! {
                command = commands.next().fuse() => match command {
                    Some(command) => driver.command(command), None => break,
                },
                result = requests.next().fuse() => if let Some((operation, result)) = result {
                    driver.reply(operation, result);
                },
            }
        }
    }
}

fn now_ms() -> u64 {
    chrono::Utc::now().timestamp_millis().max(0) as u64
}
fn now() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}
