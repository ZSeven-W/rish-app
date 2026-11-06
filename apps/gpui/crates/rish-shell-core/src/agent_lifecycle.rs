use crate::{
    agent_controller::{agent_marker, append_events, event, increment},
    agent_results::{check_transcript, journal_from_projection},
    agent_types::AgentRun,
    conversation_mut,
    model::*,
    ShellState,
};
use serde_json::{json, Value};
impl ShellState {
    pub fn answer_agent_question(
        &mut self,
        call_id: &str,
        answer: Option<&str>,
        now: &str,
    ) -> Result<Option<RuntimeCommand>> {
        if self.pending.is_some()
            || self
                .agent_run
                .as_ref()
                .is_none_or(|r| r.in_flight.is_some() || r.recoverable)
        {
            return Err("Question is not ready".into());
        }
        let view = self
            .agent_view()
            .and_then(|v| v.question)
            .ok_or("No pending Agent question")?;
        if view.id != call_id {
            return Err("This question is no longer active".into());
        }
        if let Some(answer) = answer {
            if answer.trim().is_empty()
                || answer.len() > 4000
                || answer.contains('\0')
                || (view.input_mode == "options" && !view.options.iter().any(|o| o.0 == answer))
            {
                return Err("Invalid question answer".into());
            }
        }
        let a = self.agent_attempt()?.clone();
        let mut j = a["agent"].clone();
        let index = rows(&j, "batch")
            .iter()
            .position(|c| {
                c["call_id"] == view.call_id && c["name"] == "ask_user" && c["receipt"].is_null()
            })
            .ok_or("Question was already answered")?;
        let operation = id();
        let call = j["batch"][index].clone();
        increment(&mut j, now);
        j["phase"] = json!("execution_intent");
        j["call_index"] = json!(index);
        let r = self.agent_run.as_mut().unwrap();
        r.operation_id = operation.clone();
        r.answer_draft_pending = true;
        r.decision = json!({"user_response":{"status":if answer.is_some(){"answered"}else{"cancelled"},"answer":answer}});
        self.checkpoint_agent(
            j,
            vec![event(
                &a,
                &operation,
                "tool_call",
                "running",
                Some(&call),
                now,
            )],
            "execute",
            now,
        )
    }
    pub fn decide_agent_approval(
        &mut self,
        decision: &str,
        deny_message: Option<&str>,
        now: &str,
    ) -> Result<RuntimeCommand> {
        if self.pending.is_some()
            || self
                .agent_run
                .as_ref()
                .is_none_or(|r| r.in_flight.is_some() || r.recoverable)
        {
            return Err("The Agent approval is not ready".into());
        }
        if decision == "cancelled" {
            return self
                .cancel_agent(now)?
                .ok_or("Cancellation is already pending".into());
        }
        if !matches!(decision, "allow_once" | "denied") {
            return Err("Choose allow once or deny".into());
        }
        let a = self.agent_attempt()?.clone();
        let mut j = a["agent"].clone();
        let index = rows(&j, "batch")
            .iter()
            .position(|c| {
                c["receipt"].is_null()
                    && c["approval_decision"] == "pending"
                    && matches!(text(c, "access"), "conversation_confirm" | "confirm_once")
            })
            .ok_or("No pending approval")?;
        let p = rows(&self.agent_run.as_ref().unwrap().batch, "calls")
            .iter()
            .find(|c| c["call_id"] == j["batch"][index]["call_id"])
            .ok_or("Native approval token missing; recover first")?
            .clone();
        let token = &p["approval_token"];
        if token["token"] != j["batch"][index]["approval_token"]
            || !rows(token, "allowed_decisions")
                .iter()
                .any(|d| d == decision)
        {
            return Err("Approval token does not allow this decision".into());
        }
        let message = deny_message.filter(|m| !m.trim().is_empty());
        if message.is_some_and(|s| s.len() > 4096 || s.contains('\0')) {
            return Err("Denial message is too long or invalid".into());
        }
        let operation = id();
        increment(&mut j, now);
        j["phase"] = json!("batch_frozen");
        j["batch"][index]["approval_decision"] = json!(decision);
        j["batch"][index]["approval_reference"] = if decision == "denied" {
            Value::Null
        } else {
            json!(operation)
        };
        if decision == "denied" {
            j["batch"][index]["approval_token"] = Value::Null;
        }
        let mut e = event(
            &a,
            &operation,
            "approval",
            "approval",
            Some(&j["batch"][index]),
            now,
        );
        e["approval_reference"] = json!(operation);
        let r = self.agent_run.as_mut().unwrap();
        r.operation_id = operation;
        r.decision = json!({"token":token,"decision":decision,"deny_message":if decision=="denied"{json!(message)}else{Value::Null}});
        self.checkpoint_agent(j, vec![e], "bind", now)?
            .ok_or("Missing approval checkpoint".into())
    }
    pub fn cancel_agent(&mut self, now: &str) -> Result<Option<RuntimeCommand>> {
        let r = self.agent_run.as_mut().ok_or("No Agent task")?;
        if matches!(
            r.action.as_str(),
            "cleanup_query" | "finalize" | "discard" | "done"
        ) {
            return Ok(None);
        }
        r.cancel_requested = true;
        if self.pending.is_some() {
            return Ok(None);
        }
        // The cancel CAS is serialized before the native cancellation. A late
        // provider reply cannot publish a competing checkpoint while it runs.
        if let Some(inflight) = r.in_flight.as_ref() {
            if !matches!(
                inflight.method.as_str(),
                "complete_agent_round_v2" | "execute_agent_tool"
            ) {
                return Ok(None);
            }
        }
        self.prepare_agent_cancel(now)
    }
    pub(crate) fn prepare_agent_cancel(&mut self, now: &str) -> Result<Option<RuntimeCommand>> {
        let a = self.agent_attempt()?.clone();
        let mut j = a["agent"].clone();
        if j.is_null() {
            return Ok(None);
        }
        if matches!(text(&j, "phase"), "final_response" | "cancelled" | "failed") {
            return self.advance_agent();
        }
        let target = self.agent_target()?;
        let source = id();
        let token = json!({"schema_version":2,"issuer":"completion_controller","source_event_id":source,"token":source,"task_id":a["turn_id"],"attempt_id":a["attempt_id"],"expected_phase":j["phase"],"reason_code":"E_AGENT_CANCELLED"});
        let mut e = event(&a, &source, "cancel", "cancelled", None, now);
        e["round_index"] = target["round_index"].clone();
        e["call_id"] = target["call_id"].clone();
        e["arguments_sha256"] = target["call_index"]
            .as_u64()
            .map(|i| j["batch"][i as usize]["arguments_sha256"].clone())
            .unwrap_or(Value::Null);
        e["approval_reference"] = json!(source);
        e["failure_code"] = json!("E_AGENT_CANCELLED");
        increment(&mut j, now);
        let r = self.agent_run.as_mut().unwrap();
        r.in_flight = None;
        r.operation_id = id();
        r.decision = token;
        self.checkpoint_agent(j, vec![e], "cancel", now)
    }
    pub(crate) fn agent_target(&self) -> Result<Value> {
        let a = self.agent_attempt()?;
        let j = &a["agent"];
        let mut target = json!({"schema_version":2,"kind":"attempt","task_id":a["turn_id"],"attempt_id":a["attempt_id"]});
        if matches!(
            text(j, "phase"),
            "execution_intent" | "unknown" | "ambiguous"
        ) && !j["call_index"].is_null()
        {
            let c = &j["batch"][j["call_index"].as_u64().unwrap() as usize];
            target["kind"] = json!("tool");
            for key in ["call_index", "call_id", "idempotency_key"] {
                target[key] = c[key].clone()
            }
        } else if !j["round_lineage"].is_null() && j["round_lineage"]["status"] != "completed" {
            target["kind"] = json!("round")
        }
        if target["kind"] != "attempt" {
            target["round_id"] = j["round_lineage"]["round_id"].clone();
            target["round_index"] = j["round_index"].clone();
        }
        Ok(target)
    }
    pub fn recover_agent(&mut self, now: &str) -> Result<Option<RuntimeCommand>> {
        if self.pending.is_some() {
            return Err("Resolve the pending checkpoint first".into());
        }
        if self.agent_run.as_ref().is_some_and(|r| !r.recoverable) {
            return Ok(None);
        }
        if self.agent_run.is_none() {
            let Some(c) = self.selected() else {
                return Ok(None);
            };
            let cleanup = rows(&self.session, "agent_transcript_cleanup_outbox")
                .iter()
                .find(|e| e["conversation_id"] == c["id"])
                .cloned()
                .unwrap_or(Value::Null);
            let Some(a) = rows(c, "attempts").iter().rev().find(|a| {
                a["attempt_id"] == cleanup["attempt_id"]
                    || (matches!(text(a, "status"), "prepared" | "sending")
                        && (!a["agent"].is_null() || a["status"] == "prepared"))
            }) else {
                return Ok(None);
            };
            let cancel_requested = rows(&self.session, "session_events")
                .iter()
                .any(|event| event["attempt_id"] == a["attempt_id"] && event["kind"] == "cancel");
            self.agent_run = Some(AgentRun {
                conversation_id: text(c, "id").into(),
                attempt_id: text(a, "attempt_id").into(),
                assistant_message_id: id(),
                action: "query".into(),
                operation_id: id(),
                in_flight: None,
                batch: Value::Null,
                decision: Value::Null,
                cleanup,
                cancel_requested,
                answer_draft_pending: false,
                recoverable: false,
                preview_text: String::new(),
                preview_reasoning: String::new(),
                preview_seq: 0,
                preview_provider: None,
                preview_ended: false,
                preview_incomplete: false,
            });
        }
        let a = self.agent_attempt()?;
        if a["agent"].is_null() {
            self.agent_run.as_mut().unwrap().action = "prepare".into();
        } else if self.agent_run.as_ref().unwrap().cleanup.is_object() {
            // Native may have committed discard before its reply was lost.
            // Inspect the durable cleanup receipt before finalizing authority
            // that that discard has already removed.
            self.agent_run.as_mut().unwrap().action = "cleanup_query".into();
        } else {
            self.agent_run.as_mut().unwrap().action = "query".into();
        }
        let _ = now;
        self.agent_run.as_mut().unwrap().operation_id = id();
        self.advance_agent()
    }
    pub(crate) fn accept_agent_cancel(
        &mut self,
        command: &RuntimeCommand,
        v: &Value,
        now: &str,
    ) -> Result<Option<RuntimeCommand>> {
        if v["target"] != command.args[0]["target"] {
            return Err("Agent cancellation target mismatch".into());
        }
        let a = self.agent_attempt()?.clone();
        let mut j = a["agent"].clone();
        check_transcript(&j["transcript"], &v["transcript"])?;
        j["transcript"] = v["transcript"].clone();
        match text(v, "status") {
            "cancelled" | "already_cancelled" => {
                if !j["round_lineage"].is_null() {
                    j["round_lineage"]["status"] = json!("cancelled");
                    if !v["result_round_revision"].is_null() {
                        j["round_lineage"]["native_row_revision"] =
                            v["result_round_revision"].clone();
                    }
                }
                for c in j["batch"].as_array_mut().unwrap() {
                    if c["receipt"].is_null() {
                        c["approval_decision"] = json!("cancelled");
                        c["approval_token"] = Value::Null;
                        c["approval_reference"] = Value::Null;
                    }
                }
                self.replace_agent_journal_in_memory_for_terminal(j);
                self.terminal_agent("cancelled", Some("E_AGENT_CANCELLED"), None, now)
            }
            "cancel_requested" | "settled" => {
                let r = self.agent_run.as_mut().unwrap();
                r.action = "query".into();
                r.operation_id = id();
                self.advance_agent()
            }
            _ => Err("Cancellation needs native reconciliation".into()),
        }
    }
    pub(crate) fn accept_agent_recovery(
        &mut self,
        command: &RuntimeCommand,
        v: &Value,
        now: &str,
    ) -> Result<Option<RuntimeCommand>> {
        if command.method == "query_agent_attempt" {
            if !matches!(text(v, "status"), "active" | "terminal") {
                return Err("Native Agent task could not be found".into());
            }
            self.check_agent_projection(&v["attempt"])?;
            // Query does not authorize replay. Native reconcile inspects the
            // provider/tool WAL and decides whether the work already settled.
            let p = &v["attempt"];
            let r = self.agent_run.as_mut().unwrap();
            r.batch = json!({"batch_kind":p["batch_kind"],"batch_revision":p["batch_revision"],"manifest_sha256":p["manifest_sha256"],"calls":p["batch"],"round_id":p["round_id"],"round_revision":p["round_revision"]});
            r.action = "recover".into();
            r.operation_id = id();
            return self.advance_agent();
        }
        if !matches!(
            text(v, "status"),
            "resumed" | "terminal" | "retryable" | "manual_reconciliation"
        ) {
            return Err("Native Agent requires manual reconciliation".into());
        }
        self.check_agent_projection(&v["attempt"])?;
        let p = &v["attempt"];
        let a = self.agent_attempt()?.clone();
        check_transcript(&a["agent"]["transcript"], &p["transcript"])?;
        let completed = &v["completed_round"];
        let lineage = &a["agent"]["round_lineage"];
        let same_round = p["round_id"] == lineage["round_id"]
            && p["round_index"] == lineage["round_index"]
            && p["round_revision"].as_u64().is_some_and(|revision| {
                revision > 0 && revision >= lineage["native_row_revision"].as_u64().unwrap_or(0)
            });
        let durable_stop = self.agent_run.as_ref().unwrap().cancel_requested
            && rows(&self.session, "session_events")
                .iter()
                .any(|event| event["attempt_id"] == a["attempt_id"] && event["kind"] == "cancel");
        if v["status"] == "manual_reconciliation" {
            // Native reports ambiguous provider rounds only after releasing
            // their owner. Stop abandons local response consumption, not the
            // unknown remote outcome. Keep that ambiguity in the journal and
            // use the existing interruption proof for cleanup after the CAS.
            // A tool target or any unresolved batch remains non-terminal.
            if !durable_stop
                || command.args[0]["target"]["kind"] != "round"
                || v["next_action"] != "inspect_native_state"
                || p["phase"] != "ambiguous"
                || p["round_status"] != "ambiguous"
                || !same_round
                || !completed.is_null()
                || !p["call_index"].is_null()
                || !rows(p, "batch").is_empty()
                || !a["agent"]["call_index"].is_null()
                || !rows(&a["agent"], "batch").is_empty()
            {
                return Err("Native Agent requires manual reconciliation".into());
            }
            let mut journal = journal_from_projection(p, now);
            journal["controller_generation"] = a["agent"]["controller_generation"].clone();
            self.replace_agent_journal_in_memory_for_terminal(journal);
            return self.terminal_agent("cancelled", Some("E_AGENT_CANCELLED"), None, now);
        }
        if v["status"] == "retryable" || v["next_action"] == "retry_same_round" {
            // A reconciled failed round is not a fresh provider round. Native
            // uses ready_for_round for this projection, while the committed
            // session schema deliberately forbids a failed_retryable lineage
            // in that phase. Never turn it into a new round or retry it here.
            if v["status"] != "retryable"
                || v["next_action"] != "retry_same_round"
                || p["phase"] != "ready_for_round"
                || p["round_status"] != "failed_retryable"
                || !same_round
                || !rows(p, "batch").is_empty()
                || !completed.is_null()
            {
                return Err("Recovered retryable round does not match the saved round".into());
            }
            let mut journal = journal_from_projection(p, now);
            journal["controller_generation"] = a["agent"]["controller_generation"].clone();
            self.replace_agent_journal_in_memory_for_terminal(journal);
            if durable_stop {
                // Failed-retryable is already settled and not dispatched.
                // A fresh native cancel cannot change that terminal row;
                // persist the user's Stop and finish normal cleanup instead.
                return self.terminal_agent("cancelled", Some("E_AGENT_CANCELLED"), None, now);
            }
            let failure = v
                .get("failure_code")
                .filter(|code| {
                    rish_agent_core::session_schema::valid_attempt_failure_code(Some(code))
                })
                .and_then(Value::as_str)
                .unwrap_or("E_AGENT_PERSISTENCE");
            return self.terminal_agent("failed", Some(failure), None, now);
        }
        if !completed.is_null()
            && (completed["assistant_text_sha256"]
                != rish_agent_core::canonical::sha256_hex(text(completed, "text").as_bytes())
                || completed["reasoning_text_sha256"]
                    != rish_agent_core::canonical::sha256_hex(
                        text(completed, "reasoning").as_bytes(),
                    ))
        {
            return Err("Recovered Agent round digest mismatch".into());
        }
        if !completed.is_null()
            && !rows(&a, "rounds").iter().any(|r| {
                r["round_id"] == completed["round_id"]
                    && r["round_index"] == completed["round_index"]
            })
        {
            let run = self.agent_run.as_ref().unwrap();
            let mut q = self.agent_request()?;
            for key in ["round_id", "round_index", "launch_attempt"] {
                q[key] = completed[key].clone()
            }
            q["expected_round_revision"] = json!(0);
            q["transcript"] = a["agent"]["transcript"].clone();
            q["model"] = a["model_id"].clone();
            q["thinking_mode"] = a["thinking_mode"].clone();
            q["harness_id"] = a["harness_id"].clone();
            q["visible_history_sha256"] = a["visible_history_sha256"].clone();
            q["transport_schema_version"] =
                json!(if a["project_context"].is_null() { 2 } else { 3 });
            let mut o = completed.clone();
            o["schema_version"] = json!(3);
            o["finish_reason"] = completed["completion_receipt"]["finish_reason"].clone();
            let response = json!({"schema_version":2,"status":"completed","operation_id":run.operation_id,"task_id":a["turn_id"],"attempt_id":a["attempt_id"],"round_id":completed["round_id"],"round_index":completed["round_index"],"launch_attempt":completed["launch_attempt"],"result_round_revision":completed["result_round_revision"],"transcript":completed["transcript"],"outcome":o});
            let command = RuntimeCommand::new("AgentRuntime", "complete_agent_round_v2", vec![q]);
            self.agent_run.as_mut().unwrap().in_flight = Some(command.clone());
            return self.accept_agent_result(&command, response, now);
        }
        let mut j = journal_from_projection(p, now);
        let mut recovered_events = Vec::new();
        if matches!(
            text(&j, "phase"),
            "batch_frozen" | "approval_pending" | "tool_result_pending"
        ) && !rows(&j, "batch").is_empty()
        {
            if j["phase"] == "tool_result_pending"
                && rows(&j, "batch")
                    .iter()
                    .any(|call| call["receipt"].is_null())
            {
                return Err("Recovered settled batch is missing its receipt".into());
            }
            crate::agent_results::set_batch_phase(&mut j);
            for call in rows(&j, "batch") {
                if call["receipt"].is_null() {
                    continue;
                }
                crate::agent_results::check_receipt(call, &call["receipt"])?;
                let already_recorded = rows(&self.session, "session_events").iter().any(|e| {
                    e["attempt_id"] == a["attempt_id"]
                        && e["round_index"] == j["round_index"]
                        && e["call_id"] == call["call_id"]
                        && e["kind"] == "tool_result"
                        && e["result_sha256"] == call["receipt"]["result_sha256"]
                });
                if already_recorded {
                    continue;
                }
                let call_recorded = rows(&self.session, "session_events").iter().any(|e| {
                    e["attempt_id"] == a["attempt_id"]
                        && e["round_index"] == j["round_index"]
                        && e["call_id"] == call["call_id"]
                        && e["kind"] == "tool_call"
                });
                if !call_recorded {
                    let mut e = event(&a, &id(), "tool_call", "waiting", Some(call), now);
                    e["round_index"] = j["round_index"].clone();
                    e["result_sha256"] = Value::Null;
                    e["failure_code"] = Value::Null;
                    recovered_events.push(e);
                }
                let mut e = event(
                    &a,
                    &id(),
                    "tool_result",
                    text(&call["receipt"], "outcome"),
                    Some(call),
                    now,
                );
                e["round_index"] = j["round_index"].clone();
                recovered_events.push(e);
            }
        }
        j["controller_generation"] = a["agent"]["controller_generation"].clone();
        increment(&mut j, now);
        let r = self.agent_run.as_mut().unwrap();
        r.batch = json!({"batch_kind":p["batch_kind"],"batch_revision":p["batch_revision"],"manifest_sha256":p["manifest_sha256"],"calls":p["batch"]});
        r.operation_id = id();
        match text(&j, "phase") {
            "ready_for_round" => self.checkpoint_agent(j, vec![], "begin_round", now),
            "batch_frozen" | "approval_pending" | "tool_result_pending" => {
                let action = if rows(&j, "batch").is_empty() {
                    "batch"
                } else {
                    "schedule"
                };
                self.checkpoint_agent(j, recovered_events, action, now)
            }
            "cancelled" | "failed" => {
                let status = text(&j, "phase").to_owned();
                self.replace_agent_journal_in_memory_for_terminal(j);
                self.terminal_agent(
                    &status,
                    Some(if status == "cancelled" {
                        "E_AGENT_CANCELLED"
                    } else {
                        "E_AGENT_TOOL_FAILED"
                    }),
                    None,
                    now,
                )
            }
            _ => {
                self.agent_run.as_mut().unwrap().recoverable = true;
                Ok(None)
            }
        }
    }
    pub(crate) fn terminal_agent(
        &mut self,
        status: &str,
        failure: Option<&str>,
        outcome: Option<Value>,
        now: &str,
    ) -> Result<Option<RuntimeCommand>> {
        let r = self.agent_run.as_ref().unwrap().clone();
        let original = self.agent_attempt()?.clone();
        let mut next = if r.decision["terminal_candidate"].is_object() {
            r.decision["terminal_candidate"].clone()
        } else {
            self.session.clone()
        };
        let mut j = if r.decision["terminal_journal"].is_object() {
            r.decision["terminal_journal"].clone()
        } else {
            original["agent"].clone()
        };
        increment(&mut j, now);
        j["phase"] = json!(if status == "completed" {
            "final_response"
        } else {
            status
        });
        if status == "completed" {
            j["batch"] = json!([]);
            j["call_index"] = Value::Null;
        }
        let c = conversation_mut(&mut next, &r.conversation_id)?;
        let a = c["attempts"]
            .as_array_mut()
            .unwrap()
            .iter_mut()
            .find(|a| text(a, "attempt_id") == r.attempt_id)
            .unwrap();
        a["agent"] = j.clone();
        a["journal_revision"] = json!(a["journal_revision"].as_u64().unwrap() + 1);
        a["status"] = json!(status);
        a["failure_code"] = if status == "failed" {
            json!(failure
                .filter(
                    |f| rish_agent_core::session_schema::valid_attempt_failure_code(Some(&json!(
                        f
                    )))
                )
                .unwrap_or("E_AGENT_PERSISTENCE"))
        } else {
            Value::Null
        };
        a["active_round"] = Value::Null;
        a["updated_at"] = json!(now);
        if let Some(outcome) = outcome {
            let receipt = &outcome["completion_receipt"];
            a["assistant_message_id"] = json!(r.assistant_message_id);
            c["messages"].as_array_mut().unwrap().push(json!({"id":r.assistant_message_id,"role":"assistant","text":outcome["text"],"created_at":now,"attachments":[],"metadata":{"model_id":receipt["model"],"latency_ms":receipt["latency_ms"],"finish_reason":receipt["finish_reason"],"reasoning":outcome["reasoning"]}}));
            if text(&outcome, "reasoning").trim().is_empty() {
                c["messages"].as_array_mut().unwrap().last_mut().unwrap()["metadata"]
                    .as_object_mut()
                    .unwrap()
                    .remove("reasoning");
            }
        }
        c["updated_at"] = json!(now);
        let cleanup = json!({"schema_version":1,"cleanup_id":id(),"conversation_id":r.conversation_id,"task_id":original["turn_id"],"attempt_id":r.attempt_id,"transcript_ref":j["transcript"]["transcript_ref"],"transcript_sha256":j["transcript"]["transcript_sha256"],"reason":status,"created_at":now});
        next["agent_transcript_cleanup_outbox"]
            .as_array_mut()
            .unwrap()
            .push(cleanup.clone());
        let mut e = event(
            &original,
            &id(),
            "terminal",
            if status == "completed" { "ok" } else { status },
            None,
            now,
        );
        e["failure_code"] = json!(failure);
        append_events(&mut next, vec![e]);
        let command = self.commit(next, Some(agent_marker()), false)?;
        let r = self.agent_run.as_mut().unwrap();
        r.cleanup = cleanup;
        r.action = "finalize".into();
        r.operation_id = id();
        Ok(Some(command))
    }
}
