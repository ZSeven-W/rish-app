//! Actual process actor + durable host BotStore, driven by real iOS native replies.
//! No successful CAS/Agent result is fabricated. This is not phone-store proof.
#![allow(dead_code)]
#[path = "../../../../apps/gpui/src/assistant_runtime/mod.rs"]
mod assistant_runtime;
#[path = "../../shell-agent-harness/src/provider.rs"]
mod provider;
mod runtime;

use assistant_runtime::{RunnerCommand, RunnerEvent, RunnerHandle};
use rish_shell_core::{ShellState, assistant_store::*, workspace_binding};
use serde_json::{Value, json};
use std::{
    io::{Read, Write},
    net::{Ipv4Addr, TcpListener, TcpStream},
    path::PathBuf,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

struct Case {
    handle: RunnerHandle,
    events: futures::channel::mpsc::UnboundedReceiver<RunnerEvent>,
    directory: PathBuf,
    workspace: Value,
    task_id: String,
    scenario: String,
    provider_calls: u64,
    feedback_seen: bool,
    pending: Option<runtime::Request>,
    returned: Option<ShellState>,
    errors: Vec<String>,
    commands: Vec<String>,
}

fn wait_for(mut condition: impl FnMut() -> bool) -> Result<(), String> {
    let deadline = Instant::now() + Duration::from_secs(3);
    while !condition() {
        if Instant::now() >= deadline {
            return Err("Actor state did not settle".into());
        }
        std::thread::sleep(Duration::from_millis(2));
    }
    Ok(())
}
impl Case {
    fn new(input: &Value) -> Result<Self, String> {
        let directory =
            std::env::temp_dir().join(format!("rish-actor-native-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&directory).map_err(|e| e.to_string())?;
        let directory = std::fs::canonicalize(directory).map_err(|e| e.to_string())?;
        let handle = RunnerHandle::process();
        let events = handle.subscribe();
        handle.send(RunnerCommand::Initialize {
            directory: directory.clone(),
        })?;
        wait_for(|| handle.snapshot().store.is_some())?;
        handle.send(RunnerCommand::SetProfile {
            expected_revision: 0,
            profile: AssistantProfile {
                name: "本机契约助手".into(),
                notes: "本机契约备注必须进入模型上下文。".into(),
                ..Default::default()
            },
        })?;
        wait_for(|| {
            handle
                .snapshot()
                .store
                .as_ref()
                .is_some_and(|s| s.revision == 1)
        })?;
        Ok(Self {
            handle,
            events,
            directory,
            workspace: input["workspace"].clone(),
            task_id: String::new(),
            scenario: "read".into(),
            provider_calls: 0,
            feedback_seen: false,
            pending: None,
            returned: None,
            errors: vec![],
            commands: vec![],
        })
    }
    fn step(&mut self, input: &Value) -> Result<Value, String> {
        match input["action"].as_str().ok_or("Missing action")? {
            "poll" => {}
            "create" => {
                self.scenario = input["scenario"].as_str().ok_or("Missing scenario")?.into();
                self.provider_calls = 0;
                self.feedback_seen = false;
                self.returned = None;
                self.commands.clear();
                self.task_id = uuid::Uuid::new_v4().to_string();
                let revision = self.handle.snapshot().store.ok_or("No store")?.revision;
                self.handle.send(RunnerCommand::CreateTask {
                    expected_revision: revision,
                    task_id: self.task_id.clone(),
                    config: AssistantTaskConfig::manual(
                        "本机 Agent 契约验证",
                        "读取 notes.txt 并回复内容。",
                        "deepseek-v4-flash",
                        workspace_binding(&self.workspace)?,
                        self.workspace.clone(),
                    ),
                })?;
                wait_for(|| {
                    self.handle
                        .snapshot()
                        .store
                        .as_ref()
                        .is_some_and(|s| s.tasks.iter().any(|t| t.id == self.task_id))
                })?;
            }
            "run" => {
                self.handle.send(RunnerCommand::RunNow {
                    task_id: self.task_id.clone(),
                })?;
                wait_for(|| {
                    self.handle.snapshot().store.as_ref().is_some_and(|s| {
                        s.tasks
                            .iter()
                            .any(|t| t.id == self.task_id && t.pending_manual)
                    })
                })?;
            }
            "grant" => {
                let mut state = ShellState::new();
                state.apply_catalog(json!({"schema_version":1,"models":[{"id":"deepseek-v4-flash","name":"Explicit native fixture","supports_images":false}],"retired_models":[]}))?;
                state.load_snapshot(input["snapshot"].clone())?;
                state.set_default_workspace(self.workspace.clone())?;
                self.handle.send(RunnerCommand::Grant {
                    task_id: self.task_id.clone(),
                    state,
                    foreground: true,
                })?;
            }
            "reply" => {
                let pending = self
                    .pending
                    .take()
                    .ok_or("No native request awaiting reply")?;
                if input["request_id"].as_u64() != Some(pending.id) {
                    return Err("Native reply identity mismatch".into());
                }
                let result = if let Some(error) = input["failure"].as_str() {
                    Err(error.to_owned())
                } else {
                    Ok(input["value"].clone())
                };
                pending
                    .reply
                    .send(result)
                    .map_err(|_| "Actor dropped its native request")?;
            }
            "capture_native_failure" => self
                .errors
                .push(format!("Native facade rejected {}", input["code"])),
            "inspect" => {}
            _ => return Err("Unknown actor test action".into()),
        }
        self.view()
    }
    fn view(&mut self) -> Result<Value, String> {
        // One bounded pump lets the production actor process the preceding reply.
        let until = Instant::now() + Duration::from_millis(40);
        while self.pending.is_none() && Instant::now() < until {
            self.pending = runtime::take();
            if self.pending.is_none() {
                std::thread::sleep(Duration::from_millis(2));
            }
        }
        while let Ok(event) = self.events.try_recv() {
            match event {
                RunnerEvent::Returned { state } => self.returned = Some(state),
                RunnerEvent::Error(error) => self.errors.push(error),
                _ => {}
            }
        }
        if let Some(pending) = &self.pending {
            let label = format!(
                "{}.{}#{}",
                pending.command.module, pending.command.method, pending.id
            );
            if self.commands.last() != Some(&label) {
                self.commands.push(label);
            }
        }
        let snapshot = self.handle.snapshot();
        let durable = AssistantStore::open(&self.directory)
            .map_err(|e| e.to_string())?
            .load()
            .map_err(|e| e.to_string())?;
        let state = snapshot.state.as_ref().or(self.returned.as_ref());
        let view = state.and_then(|s| s.agent_view());
        Ok(
            json!({"ok":true,"task_id":self.task_id,"scenario":self.scenario,
            "command":self.pending.as_ref().map(|p| json!({"module":p.command.module,"method":p.command.method,"args":p.command.args})),
            "request_id":self.pending.as_ref().map(|p|p.id),"store":snapshot.store,"durable_store":durable,
            "host_store_directory":self.directory,"session":state.map(|s|s.raw_session()),
            "status":format!("{:?}",snapshot.status),"owns_writer":snapshot.owns_writer,
            "view":view.map(|v|json!({"phase":v.phase,"recoverable":v.recoverable})),
            "errors":self.errors,"commands":self.commands,"provider_calls":self.provider_calls,"feedback_seen":self.feedback_seen}),
        )
    }
}

fn read_request(stream: &mut TcpStream) -> Result<(String, Value), String> {
    stream
        .set_read_timeout(Some(Duration::from_secs(10)))
        .map_err(|e| e.to_string())?;
    let mut all = Vec::new();
    let mut buffer = [0; 8192];
    let end = loop {
        let n = stream.read(&mut buffer).map_err(|e| e.to_string())?;
        if n == 0 {
            return Err("Unexpected EOF".into());
        }
        all.extend_from_slice(&buffer[..n]);
        if let Some(i) = all.windows(4).position(|w| w == b"\r\n\r\n") {
            break i + 4;
        }
        if all.len() > 32768 {
            return Err("Headers too large".into());
        }
    };
    let headers = std::str::from_utf8(&all[..end]).map_err(|_| "Invalid header")?;
    let first: Vec<_> = headers
        .lines()
        .next()
        .unwrap_or("")
        .split_whitespace()
        .collect();
    if first.len() != 3 || first[0] != "POST" {
        return Err("POST required".into());
    }
    let path = first[1].to_owned();
    let lengths: Vec<_> = headers
        .lines()
        .filter_map(|l| l.split_once(':'))
        .filter(|(k, _)| k.eq_ignore_ascii_case("content-length"))
        .collect();
    if lengths.len() != 1 || headers.to_ascii_lowercase().contains("transfer-encoding:") {
        return Err("One Content-Length required".into());
    }
    let length: usize = lengths[0].1.trim().parse().map_err(|_| "Invalid length")?;
    if length > 8 * 1024 * 1024 {
        return Err("Body too large".into());
    }
    while all.len() < end + length {
        let n = stream.read(&mut buffer).map_err(|e| e.to_string())?;
        if n == 0 {
            return Err("Incomplete body".into());
        }
        all.extend_from_slice(&buffer[..n]);
    }
    Ok((
        path,
        serde_json::from_slice(&all[end..end + length]).map_err(|e| e.to_string())?,
    ))
}
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0))?;
    println!("http://{}", listener.local_addr()?);
    std::io::stdout().flush()?;
    let state = Arc::new(Mutex::new(None::<(String, Case)>));
    for incoming in listener.incoming() {
        let mut stream = incoming?;
        let state = state.clone();
        std::thread::spawn(move || {
            let result = (|| -> Result<Value, String> {
                let (path, input) = read_request(&mut stream)?;
                let parts: Vec<_> = path.trim_matches('/').split('/').collect();
                if parts.len() != 2 || uuid::Uuid::parse_str(parts[0]).is_err() {
                    return Err("Invalid fixture route".into());
                }
                let mut state = state.lock().map_err(|_| "Fixture mutex poisoned")?;
                if parts[1] == "step" && input["action"] == "reset" {
                    if state.is_some() {
                        return Err("Only one process actor fixture per run".into());
                    }
                    *state = Some((parts[0].into(), Case::new(&input)?));
                }
                let (id, case) = state.as_mut().ok_or("Fixture not initialized")?;
                if id != parts[0] {
                    return Err("Foreign fixture".into());
                }
                let result = match parts[1] {
                    "step" if input["action"] == "reset" => case.view(),
                    "step" => case.step(&input),
                    "provider" => {
                        if !input["messages"]
                            .to_string()
                            .contains("本机契约备注必须进入模型上下文")
                        {
                            return Err(
                                "Durable profile context did not reach native provider".into()
                            );
                        }
                        provider::respond(case, &input)
                    }
                    _ => Err("Unknown route".into()),
                };
                if let Some(directory) = std::env::var_os("RISH_ASSISTANT_ACTOR_OUTPUT") {
                    if parts[1] == "step" {
                        let data = json!({"request":input,"result":result.as_ref().ok(),"error":result.as_ref().err()});
                        let _ = std::fs::write(
                            PathBuf::from(directory).join("latest-step.json"),
                            serde_json::to_vec_pretty(&data).unwrap(),
                        );
                    }
                }
                result
            })();
            let (status, value) = match result {
                Ok(v) => (200, v),
                Err(e) => (400, json!({"ok":false,"error":e})),
            };
            let body = value.to_string();
            let head = format!(
                "HTTP/1.1 {status} Test\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            );
            let _ = stream
                .write_all(head.as_bytes())
                .and_then(|_| stream.write_all(body.as_bytes()));
        });
    }
    Ok(())
}
