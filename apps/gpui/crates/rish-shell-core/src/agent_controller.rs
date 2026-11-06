use crate::{agent_types::*, conversation_mut, model::*, ShellState};
use rish_agent_core::canonical::hash_json;
use serde_json::{json, Value};

impl ShellState {
    /// Agent effects always follow a confirmed session CAS. The initial user
    /// message uses the same transaction safety as text chat, then native owns
    /// root resolution, provider requests, tool arguments and execution.
    pub fn prepare_agent_send(
        &mut self,
        body: &str,
        ids: &TurnIds,
        now: &str,
    ) -> Result<RuntimeCommand> {
        if body.len() > 256 * 1024 {
            return Err("Message exceeds the Agent input limit".into());
        }
        self.prepare_send(body, ids, now)?;
        let pending = self.pending.take().ok_or("Missing user checkpoint")?;
        let mut candidate = pending.candidate;
        let sending = self.sending.take().ok_or("Missing prepared turn")?;
        let c = conversation_mut(&mut candidate, &sending.conversation_id)?;
        let visible: Vec<Value> = rows(c, "messages")
            .iter()
            .rev()
            .take(96)
            .cloned()
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .collect();
        let history: Vec<Value> = visible.iter().map(|m| json!({"role":m["role"],"content":m["text"],"attachments":rows(m,"attachments").iter().map(|v| { let mut a=v.clone(); a.as_object_mut().map(|m|m.remove("thumbnail_data_url")); a }).collect::<Vec<_>>()})).collect();
        let digest = hash_json("visible-history", &json!({"messages":history}))
            .ok_or("Invalid visible history")?;
        let a = c["attempts"].as_array_mut().unwrap().last_mut().unwrap();
        a["visible_message_ids"] =
            json!(visible.iter().map(|m| m["id"].clone()).collect::<Vec<_>>());
        a["attachment_ids"] = json!(visible
            .iter()
            .flat_map(|m| rows(m, "attachments"))
            .map(|a| a["id"].clone())
            .collect::<Vec<_>>());
        let _ = digest;
        a["visible_history_sha256"] = Value::Null;
        a["status"] = json!("prepared");
        a["active_round"] = Value::Null;
        self.agent_run = Some(AgentRun {
            conversation_id: sending.conversation_id,
            attempt_id: ids.attempt_id.clone(),
            assistant_message_id: ids.assistant_message_id.clone(),
            action: "prepare".into(),
            operation_id: id(),
            in_flight: None,
            batch: Value::Null,
            decision: Value::Null,
            cleanup: Value::Null,
            cancel_requested: false,
            answer_draft_pending: false,
            recoverable: false,
            preview_text: String::new(),
            preview_reasoning: String::new(),
            preview_seq: 0,
            preview_provider: None,
            preview_ended: false,
            preview_incomplete: false,
        });
        match self.commit_with_draft_effect(
            candidate,
            Some(agent_marker()),
            false,
            pending.drafts.effect,
        ) {
            Ok(c) => Ok(c),
            Err(e) => {
                self.agent_run = None;
                Err(e)
            }
        }
    }
    /// A question's intent checkpoint contains only redacted identifiers. Its
    /// typed answer becomes durable only when native execution settles and the
    /// corresponding receipt checkpoint commits. Keep the native editor draft
    /// until then, including across a lost reply and recovery.
    pub fn may_clear_sent_draft(&self) -> bool {
        self.agent_run.as_ref().is_none_or(|run| {
            !run.answer_draft_pending
                || self.agent_attempt().ok().is_some_and(|a| {
                    let index = a["agent"]["call_index"].as_u64();
                    index.is_some_and(|i| !a["agent"]["batch"][i as usize]["receipt"].is_null())
                        || a["agent"]["phase"] == "round_in_flight"
                        || a["status"] == "completed"
                })
        })
    }
    /// Historical activity remains visible after completion; only a retained
    /// driver represents a task that can receive a cancellation request.
    pub fn has_agent_task(&self) -> bool {
        self.agent_run.is_some()
    }
    pub fn owns_agent_command(&self, command: &RuntimeCommand) -> bool {
        command.module == "AgentRuntime"
            && self.agent_run.as_ref().and_then(|r| r.in_flight.as_ref()) == Some(command)
    }
    pub(crate) fn agent_attempt(&self) -> Result<&Value> {
        let run = self.agent_run.as_ref().ok_or("No Agent task")?;
        let c = rows(&self.session, "conversations")
            .iter()
            .find(|c| text(c, "id") == run.conversation_id)
            .ok_or("Conversation missing")?;
        rows(c, "attempts")
            .iter()
            .find(|a| text(a, "attempt_id") == run.attempt_id)
            .ok_or("Attempt missing".into())
    }
    pub(crate) fn agent_visible_history(&self) -> Result<Vec<Value>> {
        let a = self.agent_attempt()?;
        let r = self.agent_run.as_ref().unwrap();
        let c = rows(&self.session, "conversations")
            .iter()
            .find(|c| text(c, "id") == r.conversation_id)
            .ok_or("Conversation missing")?;
        let history=rows(a,"visible_message_ids").iter().map(|id| rows(c,"messages").iter().find(|m|&m["id"]==id).map(|m|json!({"role":m["role"],"content":m["text"],"attachments":rows(m,"attachments").iter().map(|v|{let mut a=v.clone();a.as_object_mut().map(|m|m.remove("thumbnail_data_url"));a}).collect::<Vec<_>>()})).ok_or("Missing visible message".to_string())).collect::<Result<Vec<_>>>()?;
        Ok(history)
    }
    pub(crate) fn agent_visible_digest(&self) -> Result<String> {
        hash_json(
            "visible-history",
            &json!({"messages":self.agent_visible_history()?}),
        )
        .ok_or("Invalid visible history".into())
    }
    pub(crate) fn agent_transport_digest(&self) -> Result<String> {
        let bytes =
            rish_agent_core::canonical::canonical_json(&json!(self.agent_visible_history()?))
                .map_err(|_| "Invalid transport history")?;
        Ok(rish_agent_core::canonical::sha256_hex(&bytes))
    }
    pub(crate) fn agent_cas(&self) -> Result<Value> {
        let a = self.agent_attempt()?;
        let r = self.agent_run.as_ref().unwrap();
        Ok(
            json!({"schema_version":1,"conversation_id":r.conversation_id,"task_id":a["turn_id"],"attempt_id":a["attempt_id"],"expected_controller_generation":a["agent"]["controller_generation"].as_u64().unwrap_or(0),"expected_journal_revision":a["journal_revision"],"expected_session_generation":self.authority["snapshot"]["generation"],"expected_session_sha256":self.authority["snapshot"]["session_sha256"]}),
        )
    }
    pub(crate) fn agent_checkpoint(&self) -> Result<Value> {
        Ok(
            json!({"schema_version":1,"journal_revision":self.agent_attempt()?["journal_revision"],"session_generation":self.authority["snapshot"]["generation"],"session_sha256":self.authority["snapshot"]["session_sha256"]}),
        )
    }
    pub(crate) fn agent_request(&self) -> Result<Value> {
        let a = self.agent_attempt()?;
        let r = self.agent_run.as_ref().unwrap();
        Ok(
            json!({"schema_version":2,"operation_id":r.operation_id,"controller_cas":self.agent_cas()?,"committed_checkpoint":self.agent_checkpoint()?,"task_id":a["turn_id"],"conversation_id":r.conversation_id,"attempt_id":a["attempt_id"]}),
        )
    }
    pub(crate) fn dispatch_agent(
        &mut self,
        method: &str,
        request: Value,
    ) -> Result<Option<RuntimeCommand>> {
        let command = RuntimeCommand::new("AgentRuntime", method, vec![request]);
        let run = self.agent_run.as_mut().ok_or("No Agent task")?;
        if run.in_flight.is_some() {
            return Err("An Agent operation is still unresolved".into());
        }
        run.in_flight = Some(command.clone());
        run.recoverable = false;
        Ok(Some(command))
    }
    pub(crate) fn checkpoint_agent(
        &mut self,
        journal: Value,
        events: Vec<Value>,
        action: &str,
        now: &str,
    ) -> Result<Option<RuntimeCommand>> {
        let run = self.agent_run.as_ref().ok_or("No Agent task")?.clone();
        let draft_effect = journal["call_index"]
            .as_u64()
            .and_then(|index| journal["batch"].as_array()?.get(index as usize))
            .filter(|call| {
                run.answer_draft_pending
                    && call["name"] == "ask_user"
                    && call["receipt"]["outcome"] == "ok"
                    && run.decision["user_response"]["status"] == "answered"
            })
            .and_then(|_| run.decision["user_response"]["answer"].as_str())
            .map(
                |answer| crate::composer_drafts::DraftEffect::ConsumeAnswer {
                    key: run.conversation_id.clone(),
                    text: answer.to_owned(),
                },
            )
            .unwrap_or_default();
        let mut candidate = self.session.clone();
        let c = conversation_mut(&mut candidate, &run.conversation_id)?;
        let a = c["attempts"]
            .as_array_mut()
            .unwrap()
            .iter_mut()
            .find(|a| text(a, "attempt_id") == run.attempt_id)
            .ok_or("Missing Agent attempt")?;
        a["journal_revision"] = json!(a["journal_revision"].as_u64().unwrap_or(0) + 1);
        a["updated_at"] = json!(now);
        a["active_round"] = if journal["phase"] == "round_in_flight" {
            json!({"round_id":journal["round_lineage"]["round_id"],"round_index":journal["round_index"]})
        } else {
            Value::Null
        };
        a["status"] = json!(if a["active_round"].is_null() {
            "prepared"
        } else {
            "sending"
        });
        if a["visible_history_sha256"].is_null() {
            a["visible_history_sha256"] = json!(self.agent_visible_digest()?);
        }
        a["agent"] = journal;
        c["updated_at"] = json!(now);
        append_events(&mut candidate, events);
        let command =
            self.commit_with_draft_effect(candidate, Some(agent_marker()), false, draft_effect)?;
        self.agent_run.as_mut().unwrap().action = action.into();
        Ok(Some(command))
    }
    pub fn agent_view(&self) -> Option<AgentView> {
        let run = self.agent_run.as_ref();
        let attempt = if run.is_some() {
            self.agent_attempt().ok()
        } else {
            self.selected().and_then(|c| {
                rows(c, "attempts")
                    .iter()
                    .rev()
                    .find(|a| !a["agent"].is_null())
            })
        }?;
        let j = &attempt["agent"];
        let phase = if run.is_some_and(|r| r.recoverable) {
            "recovery_required"
        } else if run.is_some_and(|r| r.cancel_requested)
            && matches!(text(attempt, "status"), "prepared" | "sending")
        {
            "cancelling"
        } else if j.is_null() {
            "preparing"
        } else {
            text(j, "phase")
        };
        let calls = run.map(|r| rows(&r.batch, "calls")).unwrap_or(&[]);
        let mut tools: Vec<AgentToolView> = rows(j, "batch")
            .iter()
            .map(|c| AgentToolView {
                round_index: j["round_index"].as_u64().unwrap_or(0),
                call_id: text(c, "call_id").into(),
                name: text(c, "name").into(),
                status: if !c["receipt"].is_null() {
                    text(&c["receipt"], "outcome")
                } else if c["approval_decision"] == "pending" && c["access"] != "auto" {
                    "approval_pending"
                } else {
                    phase
                }
                .into(),
                preview: calls
                    .iter()
                    .find(|p| p["call_id"] == c["call_id"])
                    .map(|p| p["approval_preview"].clone())
                    .unwrap_or(Value::Null),
            })
            .collect();
        // Session events outlive native transcript cleanup and reconstruct
        // safe tool activity after launch, without retaining raw arguments.
        for e in rows(&self.session, "session_events")
            .iter()
            .filter(|e| e["attempt_id"] == attempt["attempt_id"] && !e["call_id"].is_null())
        {
            let call_id = text(e, "call_id");
            if rows(j, "batch")
                .iter()
                .any(|c| text(c, "call_id") == call_id && e["round_index"] == j["round_index"])
            {
                continue;
            }
            if let Some(t) = tools
                .iter_mut()
                .find(|t| t.call_id == call_id && Some(t.round_index) == e["round_index"].as_u64())
            {
                t.status = text(e, "status").into();
            } else if let Some(name) = text(e, "safe_summary_key").strip_prefix("agent.") {
                tools.push(AgentToolView {
                    round_index: e["round_index"].as_u64().unwrap_or(0),
                    call_id: call_id.into(),
                    name: name.into(),
                    status: text(e, "status").into(),
                    preview: Value::Null,
                });
            }
        }
        tools.sort_by_key(|tool| tool.round_index);
        let approval = if run.is_some_and(|r| r.in_flight.is_none() && !r.recoverable)
            && self.pending.is_none()
        {
            rows(j, "batch")
                .iter()
                .find(|c| {
                    c["receipt"].is_null()
                        && c["approval_decision"] == "pending"
                        && matches!(text(c, "access"), "conversation_confirm" | "confirm_once")
                })
                .and_then(|c| {
                    calls
                        .iter()
                        .find(|p| p["call_id"] == c["call_id"])
                        .map(|p| AgentApprovalView {
                            approval_id: text(&p["approval_token"], "token").into(),
                            call_id: text(c, "call_id").into(),
                            name: text(c, "name").into(),
                            preview: p["approval_preview"].clone(),
                            allowed_decisions: rows(&p["approval_token"], "allowed_decisions")
                                .iter()
                                .filter_map(Value::as_str)
                                .filter(|d| *d != "allow_conversation")
                                .map(String::from)
                                .collect(),
                        })
                })
        } else {
            None
        };
        Some(AgentView {
            phase: phase.into(),
            failure_code: attempt["failure_code"].as_str().map(str::to_owned),
            round: j["round_index"].as_u64().unwrap_or(0),
            tools,
            approval,
            question: if self.pending.is_none()
                && run.is_some_and(|r| r.in_flight.is_none() && !r.recoverable)
            {
                rows(j, "batch")
                    .iter()
                    .find(|c| c["name"] == "ask_user" && c["receipt"].is_null())
                    .and_then(|c| {
                        calls
                            .iter()
                            .find(|p| p["call_id"] == c["call_id"])
                            .map(|p| {
                                let q = &p["approval_preview"]["question"];
                                AgentQuestionView {
                                    id: format!(
                                        "{}:{}:{}:{}",
                                        text(attempt, "attempt_id"),
                                        text(&j["round_lineage"], "round_id"),
                                        text(c, "call_id"),
                                        c["native_row_revision"]
                                    ),
                                    call_id: text(c, "call_id").into(),
                                    question: text(q, "question").into(),
                                    input_mode: text(q, "input_mode").into(),
                                    options: rows(q, "options")
                                        .iter()
                                        .map(|o| (text(o, "id").into(), text(o, "label").into()))
                                        .collect(),
                                }
                            })
                    })
            } else {
                None
            },
            preview_text: if attempt["assistant_message_id"].is_null() {
                run.map(|r| r.preview_text.clone()).unwrap_or_default()
            } else {
                String::new()
            },
            preview_reasoning: if attempt["assistant_message_id"].is_null() {
                run.map(|r| r.preview_reasoning.clone()).unwrap_or_default()
            } else {
                String::new()
            },
            preview_incomplete: run.is_some_and(|r| r.preview_incomplete),
            recoverable: run
                .map(|r| r.recoverable)
                .unwrap_or(matches!(text(attempt, "status"), "prepared" | "sending")),
        })
    }
    pub fn fail_agent_command(
        &mut self,
        command: &RuntimeCommand,
        error: &str,
        _now: &str,
    ) -> Result<Option<RuntimeCommand>> {
        if !self.owns_agent_command(command) {
            return Err("Stale Agent callback ignored".into());
        }
        let r = self.agent_run.as_mut().unwrap();
        r.in_flight = None;
        r.recoverable = true;
        self.error = Some(format!(
            "{error}; Agent outcome must be reconciled before another action"
        ));
        Ok(None)
    }
}
pub(crate) fn agent_marker() -> RuntimeCommand {
    RuntimeCommand::new("ShellAgent", "advance", vec![])
}
pub(crate) fn increment(j: &mut Value, now: &str) {
    j["controller_generation"] = json!(j["controller_generation"].as_u64().unwrap_or(0) + 1);
    j["updated_at"] = json!(now);
}
pub(crate) fn append_events(session: &mut Value, events: Vec<Value>) {
    for mut e in events {
        let seq = rows(session, "session_events")
            .iter()
            .filter(|r| r["attempt_id"] == e["attempt_id"])
            .filter_map(|r| r["seq"].as_u64())
            .max()
            .map(|n| n + 1)
            .unwrap_or(0);
        e["seq"] = json!(seq);
        session["session_events"].as_array_mut().unwrap().push(e);
    }
}
pub(crate) fn event(
    attempt: &Value,
    operation: &str,
    kind: &str,
    status: &str,
    call: Option<&Value>,
    now: &str,
) -> Value {
    let null = Value::Null;
    let c = call.unwrap_or(&null);
    json!({"schema_version":2,"event_id":operation,"attempt_id":attempt["attempt_id"],"seq":0,"kind":kind,"round_index":if kind=="terminal"{Value::Null}else{attempt["agent"]["round_index"].clone()},"call_id":c["call_id"],"status":status,"safe_summary_key":c["safe_summary_key"],"arguments_sha256":c["arguments_sha256"],"result_sha256":c["receipt"]["result_sha256"],"approval_reference":if kind=="tool_call"{Value::Null}else{c["approval_reference"].clone()},"failure_code":c["receipt"]["failure_code"],"created_at":now})
}
