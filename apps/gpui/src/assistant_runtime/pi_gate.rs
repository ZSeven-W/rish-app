//! Pi owns scheduling; the shared native controller alone owns effects. Only
//! committed public journal entries cross this boundary, never preview data.
use super::*;
use rish_pi_runtime::{Admission, Intent, NativeCall, PiRuntime};
use serde_json::json;

pub(super) struct PiGate {
    engine: PiRuntime,
}

impl PiGate {
    #[cfg(test)]
    pub(super) fn state(&self) -> rish_pi_runtime::RuntimeState {
        self.engine.state().unwrap()
    }
    fn new(claim: &AssistantClaim, attempt: &Value) -> Result<Self, String> {
        let journal = &attempt["agent"];
        let index = journal["round_index"].as_u64().unwrap_or(0);
        check_frontier(claim, attempt)?;
        // Old batches are intentionally not public. Restart at the proven
        // current round, with the authoritative native transcript reference.
        // This resumes a real Pi loop without inventing historical tool data.
        let context = format!(
            "{}/{}/{}",
            claim.conversation_id,
            claim.run.ids.attempt_id,
            journal["transcript"]["transcript_ref"]
                .as_str()
                .unwrap_or("pending")
        );
        Ok(Self {
            engine: PiRuntime::new(
                claim
                    .run
                    .snapshot
                    .runtime
                    .clone()
                    .ok_or("E_ASSISTANT_RUNTIME_LEGACY")?,
                index,
                &claim.run.snapshot.model_id,
                &context,
                claim.run.started_at_ms,
            )?,
        })
    }

    fn sync(
        &mut self,
        claim: &AssistantClaim,
        conversation: &Value,
        attempt: &Value,
    ) -> Result<(), String> {
        check_frontier(claim, attempt)?;
        if attempt["status"] == "cancelled" {
            return self.engine.abort();
        }
        let journal = &attempt["agent"];
        let Some(index) = journal["round_index"].as_u64() else {
            return Ok(());
        };
        for _ in 0..18 {
            let state = self.engine.state()?;
            if state.done && matches!(attempt["status"].as_str(), Some("completed" | "failed")) {
                return Ok(());
            }
            if let Some(error) = state.error {
                return Err(error);
            }
            match state.intent {
                Some(Intent::Model { round_index }) if round_index == index => {
                    let receipt = rows(attempt, "rounds")
                        .iter()
                        .find(|r| r["round_index"] == index);
                    let Some(receipt) = receipt else {
                        // A failed preflight has no provider completion receipt.
                        if attempt["status"] == "failed" {
                            self.engine.abort()?;
                        }
                        return Ok(());
                    };
                    if receipt["finish_reason"] == "tool_calls" {
                        if rows(attempt, "rounds").len() != index as usize + 1
                            || journal["round_lineage"]["status"] != "completed"
                        {
                            return Err("E_ASSISTANT_RUNTIME_FRONTIER".into());
                        }
                        let batch = rows(journal, "batch");
                        if batch.is_empty() {
                            return Ok(());
                        } // Freeze CAS still pending.
                        let calls = batch
                            .iter()
                            .map(|c| native_call(journal, c))
                            .collect::<Result<Vec<_>, _>>()?;
                        self.engine
                            .model_result(index, "tool_batch", None, &calls, None)?;
                    } else if attempt["status"] == "completed" {
                        let message = rows(conversation, "messages")
                            .iter()
                            .find(|m| {
                                m["id"] == attempt["assistant_message_id"]
                                    && m["role"] == "assistant"
                            })
                            .and_then(|m| m["text"].as_str())
                            .ok_or("E_ASSISTANT_RUNTIME_FINAL")?;
                        self.engine
                            .model_result(index, "final", Some(message), &[], None)?;
                    } else if attempt["status"] == "failed" {
                        self.engine.model_result(
                            index,
                            "blocked",
                            None,
                            &[],
                            attempt["failure_code"].as_str(),
                        )?;
                        return Ok(());
                    } else {
                        return Err("E_ASSISTANT_RUNTIME_FRONTIER".into());
                    }
                }
                Some(intent @ Intent::Tool { .. }) => {
                    let call = intent.call().unwrap();
                    let entry = rows(journal, "batch")
                        .iter()
                        .find(|c| c["call_id"] == call.call_id)
                        .ok_or("E_ASSISTANT_RUNTIME_CALL_MISSING")?;
                    if native_call(journal, entry)? != call {
                        return Err("E_ASSISTANT_RUNTIME_CALL_IDENTITY".into());
                    }
                    if entry["receipt"].is_null() {
                        return Ok(());
                    }
                    self.engine.tool_result(&call, &entry["receipt"])?;
                }
                Some(Intent::Model { round_index }) if round_index == index + 1 => return Ok(()),
                None if state.done => return Ok(()),
                _ => return Err("E_ASSISTANT_RUNTIME_SEQUENCE".into()),
            }
        }
        Err("E_ASSISTANT_RUNTIME_REPLAY_LIMIT".into())
    }

    fn admit(
        &mut self,
        claim: &AssistantClaim,
        attempt: &Value,
        command: &RuntimeCommand,
    ) -> Result<Admission, String> {
        let q = command.args.first().ok_or("E_ASSISTANT_RUNTIME_COMMAND")?;
        let j = &attempt["agent"];
        if q["conversation_id"] != claim.conversation_id
            || q["attempt_id"] != claim.run.ids.attempt_id
            || q["task_id"] != claim.run.ids.turn_id
            || q["round_id"] != j["round_lineage"]["round_id"]
            || q["round_index"] != j["round_index"]
        {
            return Err("E_ASSISTANT_RUNTIME_COMMAND_IDENTITY".into());
        }
        let mut context = json!({"model_id":claim.run.snapshot.model_id,
            "provider_id":attempt["harness_id"], "round_index":q["round_index"],
            "round_id":q["round_id"], "attempt_id":claim.run.ids.attempt_id});
        if command.method == "complete_agent_round_v2" {
            if q["round_index"].as_u64() != Some(rows(attempt, "rounds").len() as u64)
                || j["round_lineage"]["status"] != "active"
            {
                return Err("E_ASSISTANT_RUNTIME_FRONTIER".into());
            }
            if q["model"] != claim.run.snapshot.model_id || q["harness_id"] != attempt["harness_id"]
            {
                return Err("E_ASSISTANT_RUNTIME_MODEL_IDENTITY".into());
            }
            self.engine.admit_model(
                q["round_index"]
                    .as_u64()
                    .ok_or("E_ASSISTANT_RUNTIME_ROUND")?,
                &context,
            )
        } else {
            let entry = rows(j, "batch")
                .get(
                    q["call_index"]
                        .as_u64()
                        .ok_or("E_ASSISTANT_RUNTIME_CALL_INDEX")? as usize,
                )
                .ok_or("E_ASSISTANT_RUNTIME_CALL_INDEX")?;
            let call = native_call(j, entry)?;
            for key in ["call_id", "name", "arguments_sha256"] {
                if q[key] != entry[key] {
                    return Err("E_ASSISTANT_RUNTIME_CALL_IDENTITY".into());
                }
                context[key] = entry[key].clone();
            }
            context["access"] = entry["access"].clone();
            context["approval_decision"] = entry["approval_decision"].clone();
            self.engine.admit_tool(&call, &context)
        }
    }
}

fn rows<'a>(value: &'a Value, key: &str) -> &'a [Value] {
    value[key].as_array().map(Vec::as_slice).unwrap_or(&[])
}
fn native_call(journal: &Value, call: &Value) -> Result<NativeCall, String> {
    serde_json::from_value(json!({"round_id":journal["round_lineage"]["round_id"],
        "round_index":journal["round_index"], "call_id":call["call_id"],
        "name":call["name"], "arguments_sha256":call["arguments_sha256"]}))
    .map_err(|_| "E_ASSISTANT_RUNTIME_CALL".into())
}
fn check_frontier(claim: &AssistantClaim, attempt: &Value) -> Result<(), String> {
    if attempt["attempt_id"] != claim.run.ids.attempt_id
        || attempt["turn_id"] != claim.run.ids.turn_id
        || attempt["model_id"] != claim.run.snapshot.model_id
    {
        return Err("E_ASSISTANT_RUNTIME_CLAIM".into());
    }
    let j = &attempt["agent"];
    let index = j["round_index"]
        .as_u64()
        .ok_or("E_ASSISTANT_RUNTIME_ROUND")?;
    if index >= 8 {
        return Err("E_ASSISTANT_RUNTIME_ROUND".into());
    }
    let rounds = rows(attempt, "rounds");
    if rounds.len() < index as usize || rounds.len() > index as usize + 1 {
        return Err("E_ASSISTANT_RUNTIME_HISTORY".into());
    }
    for (i, round) in rounds.iter().enumerate() {
        if round["round_index"] != i
            || round["attempt_id"] != claim.run.ids.attempt_id
            || round["turn_id"] != claim.run.ids.turn_id
            || round["model"] != claim.run.snapshot.model_id
            || (i < index as usize && round["finish_reason"] != "tool_calls")
            || (i == index as usize && round["round_id"] != j["round_lineage"]["round_id"])
        {
            return Err("E_ASSISTANT_RUNTIME_HISTORY".into());
        }
    }
    Ok(())
}

impl driver::Driver {
    /// Called before dispatch and after every validated CAS. Hydration has no
    /// access to Transport; it can only satisfy Pi with committed receipts.
    pub(super) fn sync_pi(
        &mut self,
        command: Option<&RuntimeCommand>,
    ) -> Result<Admission, String> {
        let active = self.active.as_ref().ok_or("Missing assistant claim")?;
        let effect = command.is_some_and(|c| {
            matches!(
                c.method.as_str(),
                "complete_agent_round_v2" | "execute_agent_tool"
            )
        });
        if active.stopped {
            return if effect {
                Err("E_ASSISTANT_RUNTIME_CANCELLED".into())
            } else {
                Ok(Admission::Allow)
            };
        }
        if active.claim.run.snapshot.runtime.is_none() {
            return Ok(Admission::Allow);
        }
        let state = self.state.as_ref().ok_or("Missing assistant writer")?;
        let Some(conversation) = rows(state.raw_session(), "conversations")
            .iter()
            .find(|c| c["id"] == active.claim.conversation_id)
        else {
            return if effect {
                Err("E_ASSISTANT_RUNTIME_CLAIM".into())
            } else {
                Ok(Admission::Allow)
            };
        };
        let Some(attempt) = rows(conversation, "attempts")
            .iter()
            .find(|a| a["attempt_id"] == active.claim.run.ids.attempt_id)
        else {
            return if effect {
                Err("E_ASSISTANT_RUNTIME_CLAIM".into())
            } else {
                Ok(Admission::Allow)
            };
        };
        if attempt["agent"].is_null() {
            return if effect {
                Err("E_ASSISTANT_RUNTIME_CLAIM".into())
            } else {
                Ok(Admission::Allow)
            };
        }
        if self.pi.is_none() {
            self.pi = Some(PiGate::new(&active.claim, attempt)?);
        }
        let pi = self.pi.as_mut().unwrap();
        pi.sync(&active.claim, conversation, attempt)?;
        if let Some(command) = command.filter(|c| {
            matches!(
                c.method.as_str(),
                "complete_agent_round_v2" | "execute_agent_tool"
            )
        }) {
            pi.admit(&active.claim, attempt, command)
        } else {
            Ok(Admission::Allow)
        }
    }

    pub(super) fn stop_runtime(&mut self, code: &str, message: &str) -> Result<(), String> {
        self.runtime_failure = Some(code.into());
        if let Some(pi) = self.pi.as_mut() {
            let _ = pi.engine.abort();
        }
        // Persist stop intent first, then use the existing cancel CAS/WAL path.
        // A command rejected above has never reached native transport.
        self.stop(false)?;
        self.error(message.into());
        Ok(())
    }

    pub(super) fn abort_pi(&mut self) {
        if let Some(pi) = self.pi.as_mut() {
            let _ = pi.engine.abort();
        }
    }
}
