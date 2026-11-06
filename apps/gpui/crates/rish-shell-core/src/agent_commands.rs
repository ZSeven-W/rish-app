use crate::{
    agent_controller::{event, increment},
    model::*,
    ShellState,
};
use serde_json::{json, Value};
impl ShellState {
    pub(crate) fn advance_agent(&mut self) -> Result<Option<RuntimeCommand>> {
        let result = self.advance_agent_inner();
        if let Err(error) = &result {
            if let Some(run) = self
                .agent_run
                .as_mut()
                .filter(|run| run.in_flight.is_none())
            {
                run.recoverable = true;
            }
            self.error = Some(error.clone());
        }
        result
    }
    fn advance_agent_inner(&mut self) -> Result<Option<RuntimeCommand>> {
        if self.pending.is_some() {
            return Err("Checkpoint is not committed".into());
        }
        let r = self.agent_run.as_ref().ok_or("No Agent task")?.clone();
        if r.in_flight.is_some() {
            return Err("Agent operation is unresolved".into());
        }
        let a = self.agent_attempt()?.clone();
        let mut j = a["agent"].clone();
        let now = text(&a, "updated_at").to_owned();
        if r.cancel_requested
            && !matches!(
                r.action.as_str(),
                "cancel" | "query" | "recover" | "cleanup_query" | "finalize" | "discard" | "done"
            )
            && !j.is_null()
        {
            return self.prepare_agent_cancel(&now);
        }
        let mut q = self.agent_request()?;
        let method = match r.action.as_str() {
            "prepare" => {
                q["workspace_id"] = a["workspace_id"].clone();
                q["project_id"] = a["context_project_id"].clone();
                q["workspace_binding_revision"] = a["workspace_binding_revision"].clone();
                add_model(&mut q, &a);
                q["visible_history_sha256"] = json!(self.agent_visible_digest()?);
                q["visible_message_ids"] = a["visible_message_ids"].clone();
                q["registry_version"] = json!(if self.assistant_conversation_id()
                    == self.active_conversation_id()
                    && self.assistant_conversation_id().is_some()
                {
                    5
                } else {
                    4
                });
                q["expected_policy_version"] = Value::Null;
                q["expected_transcript"] = Value::Null;
                "prepare_agent_attempt"
            }
            "begin_round" => {
                let index = if j["round_lineage"].is_null() {
                    0
                } else {
                    j["round_index"].as_u64().unwrap() + 1
                };
                if index >= 8 {
                    return self.terminal_agent("failed", Some("E_AGENT_ROUND_LIMIT"), None, &now);
                }
                let operation = id();
                let round = id();
                increment(&mut j, &now);
                j["phase"] = json!("round_in_flight");
                j["round_index"] = json!(index);
                j["round_lineage"] = json!({"schema_version":2,"round_id":round,"round_index":index,"launch_attempt":1,"status":"active","native_row_revision":null});
                j["batch"] = json!([]);
                j["call_index"] = Value::Null;
                j["frozen_grant_ids"] = json!([]);
                let mut e = event(&a, &operation, "round", "running", None, &now);
                e["round_index"] = json!(index);
                self.agent_run.as_mut().unwrap().operation_id = operation;
                let r = self.agent_run.as_mut().unwrap();
                r.preview_seq = 0;
                r.preview_provider = None;
                r.preview_ended = false;
                r.preview_incomplete = false;
                r.preview_text.clear();
                r.preview_reasoning.clear();
                return self.checkpoint_agent(j, vec![e], "round", &now);
            }
            "round" => {
                add_model(&mut q, &a);
                q["round_id"] = j["round_lineage"]["round_id"].clone();
                q["round_index"] = j["round_index"].clone();
                q["launch_attempt"] = j["round_lineage"]["launch_attempt"].clone();
                q["expected_round_revision"] = json!(0);
                add_root(&mut q, &j);
                "complete_agent_round_v2"
            }
            "batch" => {
                add_round(&mut q, &j);
                add_root(&mut q, &j);
                q["expected_round_revision"] = j["round_lineage"]["native_row_revision"].clone();
                q["policy_version"] = j["policy"]["policy_version"].clone();
                q["expected_batch_revision"] =
                    json!(r.batch["batch_revision"].as_u64().unwrap_or(0));
                q["expected_reserved_write_bytes"] = j["reserved_write_bytes"].clone();
                "prepare_agent_tool_batch"
            }
            "schedule" => {
                if rows(&j, "batch").iter().any(|c| {
                    c["receipt"].is_null()
                        && c["approval_decision"] == "pending"
                        && matches!(text(c, "access"), "conversation_confirm" | "confirm_once")
                }) {
                    return Ok(None);
                }
                if let Some(index) = rows(&j, "batch").iter().position(|c| {
                    c["receipt"].is_null()
                        && (c["access"] == "auto"
                            || matches!(
                                text(c, "approval_decision"),
                                "allow_once" | "allow_conversation"
                            ))
                }) {
                    let operation = id();
                    let call = j["batch"][index].clone();
                    if call["name"] == "ask_user" {
                        return Ok(None);
                    }
                    increment(&mut j, &now);
                    j["phase"] = json!("execution_intent");
                    j["call_index"] = json!(index);
                    let e = event(&a, &operation, "tool_call", "running", Some(&call), &now);
                    self.agent_run.as_mut().unwrap().operation_id = operation;
                    return self.checkpoint_agent(j, vec![e], "execute", &now);
                }
                if rows(&j, "batch").iter().all(|c| !c["receipt"].is_null()) {
                    self.agent_run.as_mut().unwrap().action = "begin_round".into();
                    return self.advance_agent();
                }
                return Err("Agent batch has an unresolved execution".into());
            }
            "bind" => {
                let d = &r.decision;
                let token = &d["token"];
                for key in [
                    "round_id",
                    "round_index",
                    "manifest_sha256",
                    "batch_revision",
                    "call_index",
                    "call_id",
                ] {
                    q[key] = token[key].clone()
                }
                q["token"] = token.clone();
                q["decision"] = d["decision"].clone();
                q["deny_message"] = d["deny_message"].clone();
                "bind_agent_approval"
            }
            "execute" => {
                add_round(&mut q, &j);
                let c = &j["batch"][j["call_index"].as_u64().ok_or("Missing call index")? as usize];
                for key in [
                    "call_index",
                    "call_id",
                    "name",
                    "arguments_sha256",
                    "idempotency_key",
                    "approval_reference",
                ] {
                    q[key] = c[key].clone()
                }
                if c["name"] == "ask_user" {
                    q["user_response"] = r.decision["user_response"].clone();
                }
                q["expected_execution_revision"] = c["native_row_revision"].clone();
                q["batch_kind"] = r.batch["batch_kind"].clone();
                q["manifest_sha256"] = r.batch["manifest_sha256"].clone();
                q["expected_batch_revision"] = r.batch["batch_revision"].clone();
                q["transcript"] = j["transcript"].clone();
                q["root"] = j["root"].clone();
                "execute_agent_tool"
            }
            "query" => {
                q.as_object_mut().unwrap().remove("operation_id");
                q.as_object_mut().unwrap().remove("committed_checkpoint");
                q["expected_journal_revision"] = a["journal_revision"].clone();
                q["expected_session_generation"] = self.authority["snapshot"]["generation"].clone();
                q["expected_session_sha256"] = self.authority["snapshot"]["session_sha256"].clone();
                q["expected_transcript"] = j["transcript"].clone();
                q["expected_root_fingerprint_sha256"] =
                    j["root"]["root_fingerprint_sha256"].clone();
                q["expected_workspace_binding_revision"] =
                    j["root"]["workspace_binding_revision"].clone();
                "query_agent_attempt"
            }
            "recover" | "cancel" => {
                for key in ["task_id", "conversation_id", "attempt_id"] {
                    q.as_object_mut().unwrap().remove(key);
                }
                q["target"] = self.agent_target()?;
                q["expected_round_revision"] = if r.action == "recover"
                    && r.batch["round_id"] == j["round_lineage"]["round_id"]
                    && !r.batch["round_revision"].is_null()
                {
                    r.batch["round_revision"].clone()
                } else {
                    j["round_lineage"]["native_row_revision"].clone()
                };
                q["expected_execution_revision"] = j["call_index"]
                    .as_u64()
                    .map(|i| j["batch"][i as usize]["native_row_revision"].clone())
                    .unwrap_or(Value::Null);
                if q["target"]["kind"] != "round" {
                    q["expected_round_revision"] = Value::Null;
                } else if q["expected_round_revision"].is_null() {
                    // Before the provider reply arrives the durable journal
                    // has no row revision yet. Zero asks native to inspect
                    // the exact owned round; null means no round target.
                    q["expected_round_revision"] = json!(0);
                }
                if q["target"]["kind"] != "tool" {
                    q["expected_execution_revision"] = Value::Null;
                }
                q["expected_transcript"] = j["transcript"].clone();
                q["root"] = j["root"].clone();
                if r.action == "cancel" {
                    q["cancel_token"] = r.decision.clone();
                    "cancel_agent_attempt"
                } else {
                    q["action"] = json!("reconcile");
                    "recover_agent_attempt"
                }
            }
            "cleanup_query" => {
                q = json!({"schema_version":2,"cleanup_id":r.cleanup["cleanup_id"]});
                "query_agent_cleanup"
            }
            "finalize" => {
                if a["status"] == "cancelled"
                    && j["round_lineage"]["status"] == "ambiguous"
                    && rows(&j, "batch").is_empty()
                    && j["call_index"].is_null()
                {
                    // Cancellation retains the provider's unknown outcome.
                    // Native interruption checks the committed terminal CAS,
                    // released round owner and every tool ledger row before
                    // it may discard the abandoned response's transcript.
                    q.as_object_mut().unwrap().remove("controller_cas");
                    q.as_object_mut().unwrap().remove("committed_checkpoint");
                    q["cleanup_id"] = r.cleanup["cleanup_id"].clone();
                    q["transcript_ref"] = r.cleanup["transcript_ref"].clone();
                    q["transcript_sha256"] = r.cleanup["transcript_sha256"].clone();
                    q["reason"] = r.cleanup["reason"].clone();
                    q["expected_session_generation"] =
                        self.authority["snapshot"]["generation"].clone();
                    q["expected_session_sha256"] =
                        self.authority["snapshot"]["session_sha256"].clone();
                    return self.dispatch_agent("interrupt_agent_attempt", q);
                }
                q["terminal_reason"] = r.cleanup["reason"].clone();
                q["cleanup_id"] = r.cleanup["cleanup_id"].clone();
                q["transcript"] = j["transcript"].clone();
                q["root"] = j["root"].clone();
                "finalize_agent_attempt"
            }
            "discard" => {
                q.as_object_mut().unwrap().remove("controller_cas");
                q.as_object_mut().unwrap().remove("committed_checkpoint");
                q["cleanup_id"] = r.cleanup["cleanup_id"].clone();
                q["transcript_ref"] = r.cleanup["transcript_ref"].clone();
                q["transcript_sha256"] = r.cleanup["transcript_sha256"].clone();
                "discard_agent_attempt"
            }
            "done" => {
                self.agent_run = None;
                return Ok(None);
            }
            _ => return Err("Unknown Agent driver phase".into()),
        };
        self.dispatch_agent(method, q)
    }
}
fn add_model(q: &mut Value, a: &Value) {
    q["transport_schema_version"] = json!(if a["project_context"].is_null() { 2 } else { 3 });
    q["harness_id"] = a["harness_id"].clone();
    q["model"] = a["model_id"].clone();
    q["thinking_mode"] = a["thinking_mode"].clone();
    q["visible_history_sha256"] = a["visible_history_sha256"].clone();
    q["visible_message_count"] = json!(rows(a, "visible_message_ids").len());
    q["project_context_sha256"] = a["project_context"]["snapshot_sha256"].clone();
}
fn add_root(q: &mut Value, j: &Value) {
    q["transcript"] = j["transcript"].clone();
    q["root"] = j["root"].clone();
    q["registry_version"] = j["tool_registry_version"].clone();
    q["toolset_sha256"] = j["toolset_sha256"].clone();
}
fn add_round(q: &mut Value, j: &Value) {
    q["round_id"] = j["round_lineage"]["round_id"].clone();
    q["round_index"] = j["round_index"].clone();
}
