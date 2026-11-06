use crate::{
    agent_controller::{agent_marker, append_events, event, increment},
    conversation_mut,
    model::*,
    ShellState,
};
use serde_json::{json, Value};
impl ShellState {
    pub fn accept_agent_result(
        &mut self,
        command: &RuntimeCommand,
        value: Value,
        now: &str,
    ) -> Result<Option<RuntimeCommand>> {
        if !self.owns_agent_command(command) {
            return Err("Stale Agent callback ignored".into());
        }
        let result = decode(value).and_then(|v| self.apply_agent_result(command, v, now));
        if result.is_err() {
            if let Some(r) = self.agent_run.as_mut() {
                r.in_flight = None;
                r.recoverable = true
            }
            self.error = result.as_ref().err().cloned();
        }
        result
    }
    fn apply_agent_result(
        &mut self,
        command: &RuntimeCommand,
        v: Value,
        now: &str,
    ) -> Result<Option<RuntimeCommand>> {
        let q = &command.args[0];
        if v["schema_version"] != 2 {
            return Err("Invalid Agent result version".into());
        }
        for key in [
            "operation_id",
            "task_id",
            "attempt_id",
            "round_id",
            "round_index",
            "call_index",
            "call_id",
            "name",
            "idempotency_key",
        ] {
            if let Some(actual) = v.get(key) {
                if let Some(expected) = q.get(key) {
                    if actual != expected {
                        return Err(format!("Agent correlation mismatch: {key}"));
                    }
                }
            }
        }
        if q.get("operation_id").is_some() && v["operation_id"] != q["operation_id"] {
            return Err("Agent operation identity is missing".into());
        }
        if let Some(checkpoint) = v.get("observed_checkpoint") {
            if checkpoint != &q["committed_checkpoint"] {
                return Err("Agent observed a different checkpoint".into());
            }
        }
        if (v["status"] == "manual_reconciliation" && command.method != "recover_agent_attempt")
            || (v["status"] == "unknown" && command.method != "query_agent_cleanup")
            || matches!(text(&v, "status"), "conflict" | "ambiguous" | "rejected")
        {
            return Err(format!(
                "{}: {}",
                text(&v, "failure_code"),
                text(&v, "status")
            ));
        }
        self.agent_run.as_mut().unwrap().in_flight = None;
        let a = self.agent_attempt()?.clone();
        let mut j = a["agent"].clone();
        match command.method.as_str() {
            "prepare_agent_attempt" => {
                if !matches!(text(&v, "status"), "prepared" | "already_prepared") {
                    return Err("Native Agent could not prepare the bound workspace".into());
                }
                let p = &v["attempt"];
                self.check_agent_projection(p)?;
                if p["registry"]["registry_version"] != q["registry_version"] {
                    return Err("Agent registry mismatch".into());
                }
                if p["phase"] != "ready_for_round"
                    || p["round_index"] != 0
                    || !p["round_id"].is_null()
                    || !rows(p, "batch").is_empty()
                {
                    return Err("Prepared Agent is not fresh; reconcile it".into());
                }
                let mut journal = journal_from_projection(p, now);
                journal["controller_generation"] = json!(
                    p["controller_generation"]
                        .as_u64()
                        .ok_or("Missing generation")?
                        + 1
                );
                self.agent_run.as_mut().unwrap().operation_id = id();
                self.checkpoint_agent(journal, vec![], "begin_round", now)
            }
            "complete_agent_round_v2" => {
                for key in [
                    "task_id",
                    "attempt_id",
                    "round_id",
                    "round_index",
                    "launch_attempt",
                ] {
                    if v[key] != q[key] {
                        return Err(format!("Agent round correlation mismatch: {key}"));
                    }
                }
                let revision = v["result_round_revision"]
                    .as_u64()
                    .filter(|n| *n > q["expected_round_revision"].as_u64().unwrap_or(0))
                    .ok_or("Invalid round revision")?;
                check_transcript(&q["transcript"], &v["transcript"])?;
                increment(&mut j, now);
                j["transcript"] = v["transcript"].clone();
                j["round_lineage"]["native_row_revision"] = json!(revision);
                if v["status"] != "completed" {
                    match text(&v, "status") {
                        "failed_retryable" => {
                            j["round_lineage"]["status"] = json!("failed_retryable");
                            self.replace_agent_journal_in_memory_for_terminal(j);
                            return self.terminal_agent(
                                "failed",
                                Some(text(&v, "failure_code")),
                                None,
                                now,
                            );
                        }
                        "cancelled" => {
                            j["round_lineage"]["status"] = json!("cancelled");
                            self.replace_agent_journal_in_memory_for_terminal(j);
                            return self.terminal_agent(
                                "cancelled",
                                Some("E_AGENT_CANCELLED"),
                                None,
                                now,
                            );
                        }
                        "in_flight" => {
                            self.agent_run.as_mut().unwrap().recoverable = true;
                            return Ok(None);
                        }
                        _ => return Err("Unrecognized Agent round status".into()),
                    }
                }
                let outcome = &v["outcome"];
                if outcome["schema_version"] != 3 || outcome["transcript"] != v["transcript"] {
                    return Err("Invalid Agent outcome".into());
                }
                let receipt = &outcome["completion_receipt"];
                for (left, right) in [
                    ("turn_id", "task_id"),
                    ("task_id", "task_id"),
                    ("attempt_id", "attempt_id"),
                    ("round_id", "round_id"),
                    ("round_index", "round_index"),
                    ("model", "model"),
                    ("requested_model", "model"),
                    ("thinking_mode", "thinking_mode"),
                ] {
                    if receipt[left] != q[right] {
                        return Err(format!("Agent receipt mismatch: {left}"));
                    }
                }
                if receipt["visible_history_sha256"] != self.agent_transport_digest()? {
                    return Err("Agent transport history receipt mismatch".into());
                }
                if receipt["harness_id"].as_str().unwrap_or("dsh") != text(q, "harness_id") {
                    return Err("Agent provider mismatch".into());
                }
                if receipt["transport_schema_version"] != q["transport_schema_version"] {
                    return Err("Agent transport mismatch".into());
                }
                if a["project_context"].is_null() {
                    if !receipt["project_context_receipt"].is_null() {
                        return Err("Unexpected project context".into());
                    }
                } else {
                    for key in [
                        "snapshot_id",
                        "snapshot_sha256",
                        "source_fingerprint",
                        "context_bytes",
                    ] {
                        if receipt["project_context_receipt"][key] != a["project_context"][key] {
                            return Err("Agent context receipt mismatch".into());
                        }
                    }
                }
                j["round_lineage"]["status"] = json!("completed");
                // Agent receipts stay in the native transcript, but schema 9
                // retains correlation-only round receipts for audit/recovery.
                let mut candidate = self.session.clone();
                let run = self.agent_run.as_ref().unwrap().clone();
                let c = conversation_mut(&mut candidate, &run.conversation_id)?;
                let target = c["attempts"]
                    .as_array_mut()
                    .unwrap()
                    .iter_mut()
                    .find(|a| a["attempt_id"] == q["attempt_id"])
                    .unwrap();
                let mut stored = receipt.clone();
                stored
                    .as_object_mut()
                    .ok_or("Invalid receipt")?
                    .remove("task_id");
                stored["schema_version"] = json!(1);
                let existing = rows(target, "rounds");
                if existing.len() != q["round_index"].as_u64().unwrap() as usize {
                    return Err("Agent round receipt order mismatch".into());
                }
                target["rounds"].as_array_mut().unwrap().push(stored);
                native_binding_facts(receipt, &mut self.environment);
                // Stage only inside a candidate; no session state is published
                // until the final checkpoint confirms its digest.
                match text(outcome, "kind") {
                    "tool_batch" => {
                        if receipt["finish_reason"] != "tool_calls"
                            || outcome["finish_reason"] != "tool_calls"
                            || rows(outcome, "calls").is_empty()
                        {
                            return Err("Invalid tool round receipt".into());
                        }
                        j["phase"] = json!("batch_frozen");
                        j["batch"] = json!([]);
                        j["call_index"] = Value::Null;
                        self.commit_agent_candidate(
                            candidate,
                            j,
                            vec![event(&a, &id(), "round", "running", None, now)],
                            "batch",
                            now,
                        )
                    }
                    "final" | "blocked" => {
                        self.agent_run.as_mut().unwrap().decision =
                            json!({"terminal_candidate":candidate,"terminal_journal":j});
                        if outcome["kind"] == "final" {
                            if receipt["finish_reason"] != "stop"
                                || text(outcome, "text").trim().is_empty()
                            {
                                return Err("Invalid final Agent answer".into());
                            }
                            self.terminal_agent("completed", None, Some(outcome.clone()), now)
                        } else {
                            self.terminal_agent(
                                "failed",
                                Some(text(outcome, "failure_code")),
                                None,
                                now,
                            )
                        }
                    }
                    _ => Err("Unrecognized Agent outcome".into()),
                }
            }
            "prepare_agent_tool_batch" => {
                if !matches!(text(&v, "status"), "prepared" | "already_prepared") {
                    return Err("Agent batch preparation failed".into());
                }
                let b = &v["receipt"];
                for key in ["task_id", "attempt_id", "round_id", "round_index"] {
                    if b[key] != q[key] {
                        return Err("Agent batch identity mismatch".into());
                    }
                }
                if b["batch_revision"].as_u64().unwrap_or(0)
                    <= q["expected_batch_revision"].as_u64().unwrap_or(0)
                    || rows(b, "calls").is_empty()
                    || rows(b, "calls").len() > 16
                {
                    return Err("Invalid Agent batch revision or call count".into());
                }
                check_transcript(&q["transcript"], &b["transcript"])?;
                let calls = rows(b, "calls")
                    .iter()
                    .enumerate()
                    .map(|(i, c)| {
                        if c["call_index"] != json!(i) {
                            return Err("Invalid Agent call order".into());
                        }
                        if !c["approval_token"].is_null()
                            && !rish_agent_core::tool_batch::approval_token(Some(
                                &c["approval_token"],
                            ))
                        {
                            return Err("Invalid native approval envelope".into());
                        }
                        Ok(call_from_projection(c))
                    })
                    .collect::<Result<Vec<_>>>()?;
                increment(&mut j, now);
                j["transcript"] = b["transcript"].clone();
                j["reserved_write_bytes"] = b["reserved_write_bytes"].clone();
                let mut frozen = Vec::new();
                for call in &calls {
                    if call["approval_decision"] == "allow_conversation"
                        && call["approval_token"].is_null()
                        && !frozen.contains(&call["approval_reference"])
                    {
                        frozen.push(call["approval_reference"].clone());
                    }
                }
                j["frozen_grant_ids"] = json!(frozen);
                j["batch"] = json!(calls);
                set_batch_phase(&mut j);
                self.agent_run.as_mut().unwrap().batch = b.clone();
                self.agent_run.as_mut().unwrap().operation_id = id();
                self.checkpoint_agent(j, vec![], "schedule", now)
            }
            "bind_agent_approval" => {
                if !matches!(text(&v, "status"), "bound" | "already_bound")
                    || v["decision"] != q["decision"]
                    || v["call_id"] != q["call_id"]
                {
                    return Err("Agent approval binding mismatch".into());
                }
                let i = q["call_index"].as_u64().unwrap() as usize;
                if j["batch"][i]["call_id"] != q["call_id"]
                    || j["batch"][i]["approval_decision"] != q["decision"]
                {
                    return Err("Approval no longer belongs to this call".into());
                }
                increment(&mut j, now);
                if q["decision"] == "denied" {
                    check_transcript(&j["transcript"], &v["transcript"])?;
                    check_receipt(&j["batch"][i], &v["receipt"])?;
                    j["transcript"] = v["transcript"].clone();
                    j["batch"][i]["receipt"] = v["receipt"].clone();
                    j["batch"][i]["native_row_revision"] = json!(2);
                } else if q["decision"] == "allow_once" {
                    if v["approval_reference"] != j["batch"][i]["approval_reference"] {
                        return Err("Approval reference mismatch".into());
                    }
                } else {
                    return Err("Unsupported approval decision".into());
                }
                self.agent_run.as_mut().unwrap().batch["batch_revision"] =
                    v["result_batch_revision"].clone();
                set_batch_phase(&mut j);
                let events = if q["decision"] == "denied" {
                    vec![event(
                        &a,
                        &id(),
                        "tool_result",
                        "denied",
                        Some(&j["batch"][i]),
                        now,
                    )]
                } else {
                    vec![]
                };
                self.checkpoint_agent(j, events, "schedule", now)
            }
            "execute_agent_tool" => {
                for key in [
                    "task_id",
                    "attempt_id",
                    "round_id",
                    "round_index",
                    "call_index",
                    "call_id",
                    "name",
                    "idempotency_key",
                ] {
                    if v[key] != q[key] {
                        return Err("Agent execution correlation mismatch".into());
                    }
                }
                if !matches!(
                    text(&v, "status"),
                    "completed" | "failed" | "denied" | "cancelled"
                ) {
                    self.agent_run.as_mut().unwrap().recoverable = true;
                    return Ok(None);
                }
                check_transcript(&q["transcript"], &v["transcript"])?;
                let index = q["call_index"].as_u64().unwrap() as usize;
                check_receipt(&j["batch"][index], &v["receipt"])?;
                if v["result_execution_revision"].as_u64().unwrap_or(0)
                    <= q["expected_execution_revision"].as_u64().unwrap_or(0)
                {
                    return Err("Execution revision did not advance".into());
                }
                increment(&mut j, now);
                j["transcript"] = v["transcript"].clone();
                j["batch"][index]["receipt"] = v["receipt"].clone();
                j["batch"][index]["native_row_revision"] = v["result_execution_revision"].clone();
                j["phase"] = json!("tool_result_pending");
                j["call_index"] = json!(index);
                let e = event(
                    &a,
                    &id(),
                    "tool_result",
                    text(&v["receipt"], "outcome"),
                    Some(&j["batch"][index]),
                    now,
                );
                if v["status"] == "cancelled" {
                    self.replace_agent_journal_in_memory_for_terminal(j);
                    return self.terminal_agent("cancelled", Some("E_AGENT_CANCELLED"), None, now);
                }
                self.checkpoint_agent(j, vec![e], "schedule", now)
            }
            "query_agent_attempt" | "recover_agent_attempt" => {
                self.accept_agent_recovery(command, &v, now)
            }
            "cancel_agent_attempt" => self.accept_agent_cancel(command, &v, now),
            "query_agent_cleanup" => {
                if v["cleanup_id"] != q["cleanup_id"]
                    || !matches!(text(&v, "status"), "pending" | "discarded" | "unknown")
                {
                    return Err("Invalid Agent cleanup query result".into());
                }
                let r = self.agent_run.as_mut().unwrap();
                // A query is only a routing hint. Native discard must still
                // prove the exact discarded receipt AND committed outbox
                // before already_missing can authorize the cleanup CAS.
                r.action = if v["status"] == "discarded" {
                    "discard"
                } else {
                    "finalize"
                }
                .into();
                r.operation_id = id();
                self.advance_agent()
            }
            "finalize_agent_attempt" => {
                if !matches!(text(&v, "status"), "terminal" | "already_terminal")
                    || v["cleanup_id"] != q["cleanup_id"]
                    || v["transcript"] != q["transcript"]
                {
                    return Err("Invalid Agent finalization proof".into());
                }
                let r = self.agent_run.as_mut().unwrap();
                r.action = "discard".into();
                r.operation_id = id();
                self.advance_agent()
            }
            "discard_agent_attempt" | "interrupt_agent_attempt" => {
                if !matches!(text(&v, "status"), "discarded" | "already_missing")
                    || v["cleanup_id"] != q["cleanup_id"]
                {
                    return Err("Agent transcript cleanup remains pending".into());
                }
                let mut next = self.session.clone();
                next["agent_transcript_cleanup_outbox"]
                    .as_array_mut()
                    .unwrap()
                    .retain(|e| e["cleanup_id"] != q["cleanup_id"]);
                self.agent_run.as_mut().unwrap().action = "done".into();
                self.commit(next, Some(agent_marker()), false).map(Some)
            }
            _ => Err("Unknown Agent result method".into()),
        }
    }
    pub(crate) fn commit_agent_candidate(
        &mut self,
        mut candidate: Value,
        journal: Value,
        events: Vec<Value>,
        action: &str,
        now: &str,
    ) -> Result<Option<RuntimeCommand>> {
        let r = self.agent_run.as_ref().unwrap();
        let c = conversation_mut(&mut candidate, &r.conversation_id)?;
        let a = c["attempts"]
            .as_array_mut()
            .unwrap()
            .iter_mut()
            .find(|a| text(a, "attempt_id") == r.attempt_id)
            .unwrap();
        a["journal_revision"] = json!(a["journal_revision"].as_u64().unwrap() + 1);
        a["updated_at"] = json!(now);
        a["agent"] = journal;
        a["active_round"] = Value::Null;
        a["status"] = json!("prepared");
        c["updated_at"] = json!(now);
        append_events(&mut candidate, events);
        let command = self.commit(candidate, Some(agent_marker()), false)?;
        let r = self.agent_run.as_mut().unwrap();
        r.action = action.into();
        r.operation_id = id();
        Ok(Some(command))
    }
    pub(crate) fn replace_agent_journal_in_memory_for_terminal(&mut self, j: Value) {
        self.agent_run.as_mut().unwrap().decision = json!({"terminal_journal":j});
    }
    pub(crate) fn check_agent_projection(&self, p: &Value) -> Result<()> {
        let a = self.agent_attempt()?;
        let r = self.agent_run.as_ref().unwrap();
        if p["schema_version"] != 2
            || p["task_id"] != a["turn_id"]
            || p["attempt_id"] != a["attempt_id"]
            || p["conversation_id"] != r.conversation_id
            || p["root"]["workspace_id"] != a["workspace_id"]
            || p["root"]["project_id"] != a["context_project_id"]
            || p["root"]["workspace_binding_revision"] != a["workspace_binding_revision"]
            || !rish_agent_core::tool_batch::batch_root(Some(&p["root"]))
            || !rish_agent_core::tool_batch::batch_transcript(Some(&p["transcript"]))
        {
            return Err("Agent projection does not match this workspace attempt".into());
        }
        Ok(())
    }
}
pub(crate) fn check_transcript(before: &Value, after: &Value) -> Result<()> {
    if !rish_agent_core::tool_batch::transcript_can_advance(Some(before), Some(after)) {
        Err("Agent transcript regressed or changed identity".into())
    } else {
        Ok(())
    }
}
pub(crate) fn check_receipt(call: &Value, receipt: &Value) -> Result<()> {
    if receipt["schema_version"] != 1
        || ["call_id", "name", "arguments_sha256"]
            .iter()
            .any(|k| receipt[*k] != call[*k])
    {
        return Err("Agent tool receipt mismatch".into());
    }
    Ok(())
}
pub(crate) fn call_from_projection(p: &Value) -> Value {
    json!({"schema_version":3,"call_id":p["call_id"],"call_index":p["call_index"],"name":p["name"],"arguments_sha256":p["arguments_sha256"],"safe_summary_key":p["safe_summary_key"],"access":p["access"],"approval_token":p["approval_token"]["token"],"approval_decision":match text(p,"approval_state"){"denied"=>"denied","cancelled"=>"cancelled","bound"=>if p["approval_token"].is_null(){"allow_conversation"}else{"allow_once"},_=>"pending"},"approval_reference":p["approval_reference"],"idempotency_key":p["idempotency_key"],"native_row_revision":p["native_row_revision"],"receipt":p["receipt"]})
}
pub(crate) fn journal_from_projection(p: &Value, now: &str) -> Value {
    json!({"schema_version":3,"phase":p["phase"],"controller_generation":p["controller_generation"],"policy":p["policy"],"root":p["root"],"tool_registry_version":p["registry"]["registry_version"],"toolset_sha256":p["registry"]["toolset_sha256"],"transcript":p["transcript"],"round_index":p["round_index"],"round_lineage":if p["round_id"].is_null(){Value::Null}else{json!({"schema_version":2,"round_id":p["round_id"],"round_index":p["round_index"],"launch_attempt":1,"status":p["round_status"],"native_row_revision":p["round_revision"]})},"call_index":p["call_index"],"batch":rows(p,"batch").iter().map(call_from_projection).collect::<Vec<_>>(),"frozen_grant_ids":p["frozen_grant_ids"],"reserved_write_bytes":p["reserved_write_bytes"],"updated_at":now})
}
pub(crate) fn set_batch_phase(j: &mut Value) {
    let b = rows(j, "batch");
    let pending = b.iter().any(|c| {
        c["receipt"].is_null()
            && c["approval_decision"] == "pending"
            && matches!(text(c, "access"), "conversation_confirm" | "confirm_once")
    });
    let all = b.iter().all(|c| !c["receipt"].is_null());
    let i = if all {
        b.len().checked_sub(1)
    } else {
        b.iter().position(|c| c["receipt"].is_null())
    };
    j["phase"] = json!(if pending {
        "approval_pending"
    } else if all {
        "tool_result_pending"
    } else {
        "batch_frozen"
    });
    j["call_index"] = json!(i);
}
