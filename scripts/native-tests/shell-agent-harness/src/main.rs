//! Test-only loopback driver. Native tests return real facade/store replies;
//! this process never manufactures a native receipt or edits a session journal.
mod provider;
use rish_shell_core::{RuntimeCommand, ShellState, TurnIds};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{Ipv4Addr, TcpListener, TcpStream};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

struct Case {
    shell: ShellState,
    pending: Option<RuntimeCommand>,
    scenario: String,
    provider_calls: u64,
    commands: Vec<String>,
    feedback_seen: bool,
    late_command: Option<RuntimeCommand>,
    ignored_late_replies: u64,
    provider_gate: Arc<ProviderGate>,
}

#[derive(Default)]
struct ProviderGate {
    // The provider waits independently of the shell-state mutex. A separate
    // connection can prove dispatch, commit cancellation and release its reply.
    state: Mutex<(bool, bool)>,
    changed: Condvar,
}
impl ProviderGate {
    fn enter(&self) {
        self.state.lock().unwrap().0 = true;
        self.changed.notify_all();
    }
    fn release(&self) {
        self.state.lock().unwrap().1 = true;
        self.changed.notify_all();
    }
    fn wait(&self, released: bool) -> Result<(), String> {
        let (state, _) = self
            .changed
            .wait_timeout_while(
                self.state.lock().map_err(|_| "Provider gate poisoned")?,
                Duration::from_secs(20),
                |state| if released { !state.1 } else { !state.0 },
            )
            .map_err(|_| "Provider gate poisoned")?;
        if if released { state.1 } else { state.0 } {
            Ok(())
        } else {
            Err("Provider handshake timed out".into())
        }
    }
}

fn now() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}
fn required<'a>(v: &'a Value, name: &str) -> Result<&'a str, String> {
    v[name].as_str().ok_or_else(|| format!("Missing {name}"))
}
fn command(c: &RuntimeCommand) -> Value {
    json!({"module": c.module,"method": c.method,"args":c.args})
}
impl Case {
    fn new(v: &Value) -> Result<Self, String> {
        let mut shell = ShellState::new();
        shell.apply_catalog(json!({"schema_version":1,"models":[{"id":"deepseek-v4-flash","name":"Explicit native fixture","supports_images":false}],"retired_models":[]}))?;
        shell.load_snapshot(v["snapshot"].clone())?;
        shell.set_default_workspace(v["workspace"].clone())?;
        let pending = shell.create_conversation(
            &uuid::Uuid::new_v4().to_string(),
            &now(),
            "deepseek-v4-flash",
        )?;
        Ok(Self {
            shell,
            pending: Some(pending),
            scenario: required(v, "scenario")?.into(),
            provider_calls: 0,
            commands: vec![],
            feedback_seen: false,
            late_command: None,
            ignored_late_replies: 0,
            provider_gate: Arc::default(),
        })
    }
    fn step(&mut self, v: &Value) -> Result<Value, String> {
        let action = required(v, "action")?;
        let at = now();
        let next = match action {
            "inspect" => return Ok(self.view()),
            "release_provider" => {
                if self.scenario != "cancel-provider" {
                    return Err("This scenario has no held provider reply".into());
                }
                self.provider_gate.release();
                return Ok(self.view());
            }
            "capture_native_failure" => {
                if let Some(directory) = std::env::var_os("RISH_SHELL_AGENT_DIAGNOSTICS_DIR") {
                    let path = std::path::PathBuf::from(directory)
                        .join(format!("native-failure-{}.json", uuid::Uuid::new_v4()));
                    std::fs::write(
                        path,
                        serde_json::to_vec_pretty(v).map_err(|e| e.to_string())?,
                    )
                    .map_err(|e| e.to_string())?;
                }
                return Ok(self.view());
            }
            "reply" => {
                let pending = self.pending.as_ref().ok_or("No pending command")?.clone();
                if v["command"] != command(&pending) {
                    return Err("Reply command mismatch".into());
                }
                if pending.module == "SessionSnapshots" {
                    self.shell.accept_persist(v["value"].clone())?
                } else {
                    self.shell
                        .accept_agent_result(&pending, v["value"].clone(), &at)?
                }
            }
            "failure" => {
                let pending = self.pending.as_ref().ok_or("No pending command")?.clone();
                self.shell
                    .fail_agent_command(&pending, required(v, "code")?, &at)?
            }
            "lose_cas_reply" => {
                let pending = self.pending.as_ref().ok_or("No pending checkpoint")?;
                if pending.module != "SessionSnapshots" || pending.method != "casPersistSession" {
                    return Err("Only a committed checkpoint reply may be lost here".into());
                }
                if self
                    .shell
                    .accept_persist(json!({"schema_version":1,"status":"unknown"}))
                    .is_ok()
                {
                    return Err("Unknown checkpoint unexpectedly advanced the controller".into());
                }
                Some(
                    self.shell
                        .query_pending_commit()
                        .ok_or("Lost checkpoint was not retained")?,
                )
            }
            "send" => {
                self.idle()?;
                Some(
                    self.shell
                        .prepare_agent_send(required(v, "text")?, &TurnIds::new(), &at)?,
                )
            }
            "approve" => {
                self.idle()?;
                Some(self.shell.decide_agent_approval(
                    required(v, "decision")?,
                    v["message"].as_str(),
                    &at,
                )?)
            }
            "answer" => {
                self.idle()?;
                self.shell.answer_agent_question(
                    required(v, "call_id")?,
                    v["answer"].as_str(),
                    &at,
                )?
            }
            "cancel" => {
                if let Some(inflight) = &self.pending {
                    if inflight.module != "AgentRuntime"
                        || inflight.method != "complete_agent_round_v2"
                    {
                        return Err("This fault case only cancels an active provider round".into());
                    }
                    self.late_command = Some(inflight.clone());
                }
                self.shell.cancel_agent(&at)?
            }
            "late_reply" => {
                let old = self
                    .late_command
                    .clone()
                    .ok_or("No cancelled provider callback")?;
                if v["command"] != command(&old) {
                    return Err("Wrong late callback".into());
                }
                let before = self.view();
                let result = if let Some(error) = v["failure"].as_str() {
                    self.shell.fail_agent_command(&old, error, &at)
                } else {
                    self.shell
                        .accept_agent_result(&old, v["value"].clone(), &at)
                };
                if !result.is_err_and(|error| error.contains("Stale Agent callback"))
                    || self.view() != before
                {
                    return Err("Late provider callback changed the cancelled session".into());
                }
                self.late_command = None;
                self.ignored_late_replies += 1;
                return Ok(self.view());
            }
            "recover" => {
                self.idle()?;
                self.shell.recover_agent(&at)?
            }
            "restart" => {
                self.shell = ShellState::new();
                self.shell.apply_catalog(json!({"schema_version":1,"models":[{"id":"deepseek-v4-flash","name":"Explicit native fixture","supports_images":false}],"retired_models":[]}))?;
                self.shell.load_snapshot(v["snapshot"].clone())?;
                self.shell.recover_agent(&at)?
            }
            _ => return Err("Unknown action".into()),
        };
        self.pending = next;
        if let Some(c) = &self.pending {
            self.commands.push(format!("{}.{}", c.module, c.method));
        }
        Ok(self.view())
    }
    fn idle(&self) -> Result<(), String> {
        if self.pending.is_some() {
            Err("Native command must settle before UI action".into())
        } else {
            Ok(())
        }
    }
    fn view(&self) -> Value {
        let view = self.shell.agent_view();
        json!({"ok":true,"command":self.pending.as_ref().map(command),"session":self.shell.raw_session(),
            "view":view.map(|v|json!({"phase":v.phase,"recoverable":v.recoverable,
                "approval":v.approval.map(|a|json!({"call_id":a.call_id,"name":a.name,"allowed_decisions":a.allowed_decisions,"preview":a.preview})),
                "question":v.question.map(|q|json!({"call_id":q.id,"question":q.question,"input_mode":q.input_mode,"options":q.options})),
                "tools":v.tools.iter().map(|t|json!({"call_id":t.call_id,"name":t.name,"status":t.status})).collect::<Vec<_>>()})),
            "provider_calls":self.provider_calls,"feedback_seen":self.feedback_seen,"commands":self.commands,
            "ignored_late_replies":self.ignored_late_replies})
    }
}

fn request(stream: &mut TcpStream) -> Result<(String, Value), String> {
    stream
        .set_read_timeout(Some(Duration::from_secs(10)))
        .map_err(|e| e.to_string())?;
    let mut all = Vec::new();
    let mut buf = [0; 8192];
    let end = loop {
        let n = stream.read(&mut buf).map_err(|e| e.to_string())?;
        if n == 0 {
            return Err("Unexpected EOF".into());
        }
        all.extend_from_slice(&buf[..n]);
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
    if lengths.len() != 1 {
        return Err("Exactly one Content-Length required".into());
    }
    if headers.to_ascii_lowercase().contains("transfer-encoding:") {
        return Err("Chunked requests not accepted".into());
    }
    let length: usize = lengths[0].1.trim().parse().map_err(|_| "Invalid length")?;
    if length > 8 * 1024 * 1024 {
        return Err("Body too large".into());
    }
    while all.len() < end + length {
        let n = stream.read(&mut buf).map_err(|e| e.to_string())?;
        if n == 0 {
            return Err("Incomplete body".into());
        }
        all.extend_from_slice(&buf[..n]);
    }
    let body = serde_json::from_slice(&all[end..end + length]).map_err(|e| e.to_string())?;
    Ok((path, body))
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0))?;
    println!("http://{}", listener.local_addr()?);
    std::io::stdout().flush()?;
    let cases = Arc::new(Mutex::new(HashMap::<String, Case>::new()));
    for incoming in listener.incoming() {
        let mut stream = incoming?;
        let cases = Arc::clone(&cases);
        std::thread::spawn(move || {
            let mut held_provider = None;
            let reply = (|| -> Result<Value, String> {
                let (path, v) = request(&mut stream)?;
                let mut state = cases.lock().map_err(|_| "Test state lock poisoned")?;
                let parts: Vec<_> = path.trim_matches('/').split('/').collect();
                if parts.len() != 2 || uuid::Uuid::parse_str(parts[0]).is_err() {
                    return Err("Invalid test route".into());
                }
                if parts[1] == "step" && v["action"] == "reset" {
                    state.insert(parts[0].into(), Case::new(&v)?);
                    return Ok(state[parts[0]].view());
                }
                if parts[1] == "step" && v["action"] == "wait_for_provider" {
                    let gate = Arc::clone(
                        &state
                            .get(parts[0])
                            .ok_or("Missing test case")?
                            .provider_gate,
                    );
                    drop(state);
                    gate.wait(false)?;
                    let state = cases.lock().map_err(|_| "Test state lock poisoned")?;
                    return Ok(state.get(parts[0]).ok_or("Missing test case")?.view());
                }
                let case = state.get_mut(parts[0]).ok_or("Missing test case")?;
                if parts[1] == "provider" && case.scenario == "cancel-provider" {
                    held_provider = Some(Arc::clone(&case.provider_gate));
                }
                let result = match parts[1] {
                    "step" => case.step(&v),
                    "provider" => provider::respond(case, &v),
                    _ => Err("Unknown route".into()),
                };
                if let (Err(error), Some(directory)) = (
                    &result,
                    std::env::var_os("RISH_SHELL_AGENT_DIAGNOSTICS_DIR"),
                ) {
                    // All material belongs to the synthetic isolated case. Keep
                    // protocol failures reviewable without logging credentials.
                    let path = std::path::PathBuf::from(directory)
                        .join(format!("failure-{}.json", parts[0]));
                    let data = json!({"error":error,"request":v,"shell":case.view()});
                    let _ =
                        std::fs::write(path, serde_json::to_vec_pretty(&data).unwrap_or_default());
                }
                result
            })();
            // The provider is waiting on its own socket, never holding the shell
            // state lock; cancellation uses an independent HTTP connection.
            let reply = if let Some(gate) = held_provider {
                gate.enter();
                gate.wait(true).and(reply)
            } else {
                reply
            };
            let (status, value) = match reply {
                Ok(v) => (200, v),
                Err(e) => (400, json!({"ok":false,"error":e})),
            };
            let body = value.to_string();
            let head=format!("HTTP/1.1 {status} Test\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",body.len());
            let _ = stream
                .write_all(head.as_bytes())
                .and_then(|_| stream.write_all(body.as_bytes()));
        });
    }
    Ok(())
}
