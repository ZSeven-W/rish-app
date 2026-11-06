use crate::{conversation_mut, model::*, selected_mut, Sending, ShellState};
use rish_agent_core::name_policy;
use serde_json::{json, Value};

impl ShellState {
    /// Prepare one native no-tool chat round. Native Agent journals and tool
    /// authorities are never synthesized by this text-chat controller.
    pub fn prepare_send(&mut self, body: &str, ids: &TurnIds, now: &str) -> Result<RuntimeCommand> {
        self.ready()?;
        if self.active_workspace_binding().is_none() {
            return Err("E_CONVERSATION_WORKSPACE_REQUIRED".into());
        }
        if body.trim().is_empty() {
            return Err("Enter a message".into());
        }
        if body.len() > 1_000_000 {
            return Err("Message is too large".into());
        }
        let mut next = self.session.clone();
        let c = selected_mut(&mut next)?;
        if active(c) {
            return Err("This conversation has an unresolved task. Recover it before sending another message.".into());
        }
        let conversation_id = text(c, "id").to_owned();
        let model = text(c, "model_id").to_owned();
        if !self.catalog.iter().any(|entry| entry.id == model) {
            return Err("E_MODEL_NOT_CONFIGURED".into());
        }
        let thinking = text(c, "thinking_mode").to_owned();
        let harness = self
            .environment
            .harness_by_model
            .get(&model)
            .cloned()
            .ok_or("Unknown model")?;
        let (attempt_context, request_context) = context(c, &harness)?;
        let message = json!({"id":ids.user_message_id,"role":"user","text":body,"created_at":now,"attachments":[]});
        c["messages"]
            .as_array_mut()
            .ok_or("Missing message list")?
            .push(message);
        let visible: Vec<Value> = rows(c, "messages")
            .iter()
            .rev()
            .take(200)
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .cloned()
            .collect();
        let history: Vec<Value> = visible
            .iter()
            .map(|m| json!({"role":m["role"],"content":m["text"],"attachments":m["attachments"]}))
            .collect();
        let mut attachment_ids = Vec::new();
        for m in &visible {
            for a in rows(m, "attachments") {
                if !attachment_ids.contains(&a["id"]) {
                    attachment_ids.push(a["id"].clone());
                }
            }
        }
        let project = c["project_id"].clone();
        let request = json!({"schema_version":if request_context.is_null(){2}else{3},"harness_id":harness,
            "turn_id":ids.turn_id,"attempt_id":ids.attempt_id,"round_id":ids.round_id,"round_index":0,
            "model":model,"thinking_mode":thinking,"visible_history":history,"round_transcript":[],"tools":[],"project_context":request_context});
        let attempt = json!({"schema_version":3,"attempt_id":ids.attempt_id,"turn_id":ids.turn_id,"status":"sending","harness_id":harness,
            "visible_message_ids":visible.iter().map(|m|m["id"].clone()).collect::<Vec<_>>(),"visible_history_sha256":null,
            "attachment_ids":attachment_ids,"model_id":model,"thinking_mode":thinking,"context_disposition":if project.is_null(){"unbound"}else{"verified"},
            "context_project_id":project,"workspace_id":c["workspace_id"],"workspace_binding_revision":c["workspace_binding"]["binding_revision"],
            "project_context":attempt_context,"active_round":{"round_id":ids.round_id,"round_index":0},"rounds":[],
            "assistant_message_id":null,"failure_code":null,"created_at":now,"updated_at":now,"journal_revision":0,"agent":null});
        c["turns"].as_array_mut().ok_or("Missing turns")?.push(json!({"schema_version":1,"turn_id":ids.turn_id,"user_message_id":ids.user_message_id,"attempt_ids":[ids.attempt_id],"created_at":now}));
        c["attempts"]
            .as_array_mut()
            .ok_or("Missing attempts")?
            .push(attempt);
        c["updated_at"] = json!(now);
        if text(c, "title_source") == "auto" && rows(c, "turns").len() == 1 {
            c["title"] = json!(name_policy::automatic_title(body));
            c["title_source"] = json!("auto");
        }
        let completion = RuntimeCommand::new(
            "LocalRuntime",
            "completeV2",
            vec![json!(request.to_string())],
        );
        let command = self.commit(next, Some(completion), false)?;
        self.sending = Some(Sending {
            conversation_id,
            ids: ids.clone(),
            request,
        });
        Ok(command)
    }
    pub fn accept_completion(&mut self, value: Value, now: &str) -> Result<RuntimeCommand> {
        if self.pending.is_some() {
            return Err("The user turn has not been committed yet".into());
        }
        let response = decode(value)?;
        let send = self.sending.clone().ok_or("No chat request is active")?;
        for key in [
            "schema_version",
            "harness_id",
            "turn_id",
            "attempt_id",
            "round_id",
            "round_index",
            "thinking_mode",
        ] {
            if response[key] != send.request[key]
                && !(key == "harness_id" && response[key].is_null() && send.request[key] == "dsh")
            {
                return Err(format!("Native completion correlation mismatch: {key}"));
            }
        }
        if response["model"] != send.request["model"]
            || response["requested_model"] != send.request["model"]
        {
            return Err("Native completion returned a different model".into());
        }
        if !response["tool_calls"].is_array() || !rows(&response, "tool_calls").is_empty() {
            return Err("A text-only request returned tools; no tool has been executed".into());
        }
        if !["stop", "length", "content_filter"].contains(&text(&response, "finish_reason"))
            || !response["text"].is_string()
            || !response["reasoning"].is_string()
        {
            return Err("Invalid native completion result".into());
        }
        if text(&response, "finish_reason") != "content_filter"
            && text(&response, "text").trim().is_empty()
        {
            return Err("Native completion returned an empty answer".into());
        }
        let mut receipt = response.clone();
        let object = receipt
            .as_object_mut()
            .ok_or("Invalid native completion receipt")?;
        object.remove("text");
        object.remove("reasoning");
        object.remove("tool_calls");
        object.insert("schema_version".into(), json!(1));
        object.insert(
            "transport_schema_version".into(),
            response["schema_version"].clone(),
        );
        if response["harness_id"].is_null() {
            object.insert("harness_id".into(), send.request["harness_id"].clone());
        }
        let mut environment = self.environment.clone();
        native_binding_facts(&receipt, &mut environment);
        let mut next = self.session.clone();
        let c = conversation_mut(&mut next, &send.conversation_id)?;
        let a = c["attempts"]
            .as_array_mut()
            .ok_or("Missing attempts")?
            .iter_mut()
            .find(|a| text(a, "attempt_id") == send.ids.attempt_id)
            .ok_or("Attempt not found")?;
        if a["status"] != "sending" || a["active_round"]["round_id"] != send.ids.round_id {
            return Err("The completion belongs to a stopped or replaced attempt".into());
        }
        a["status"] = json!("completed");
        a["active_round"] = Value::Null;
        a["assistant_message_id"] = json!(send.ids.assistant_message_id);
        a["visible_history_sha256"] = response["visible_history_sha256"].clone();
        a["rounds"] = json!([receipt]);
        a["updated_at"] = json!(now);
        let mut message = json!({"id":send.ids.assistant_message_id,"role":"assistant","text":response["text"],"created_at":now,"attachments":[],
            "metadata":{"model_id":response["model"],"latency_ms":response["latency_ms"],"finish_reason":response["finish_reason"],"reasoning":response["reasoning"]}});
        if text(&response, "reasoning").is_empty() {
            message["metadata"]
                .as_object_mut()
                .unwrap()
                .remove("reasoning");
        }
        c["messages"]
            .as_array_mut()
            .ok_or("Missing messages")?
            .push(message);
        c["updated_at"] = json!(now);
        // The binding came from the trusted native completion facade, whose
        // validator—not the model—is responsible for provider identity.
        self.environment = environment;
        self.commit(next, None, true)
    }
    pub fn cancel_command(&self) -> Option<RuntimeCommand> {
        if self.pending.is_some() {
            return None;
        }
        self.sending.as_ref().map(|s| {
            RuntimeCommand::new(
                "LocalRuntime",
                "cancelCompletion",
                vec![json!(s.ids.round_id)],
            )
        })
    }
    /// Call only once the native completion promise has failed or cancellation
    /// has settled. Persist failure instead of erasing a durable user turn.
    pub fn fail_send(&mut self, code: &str, now: &str) -> Result<RuntimeCommand> {
        if self.pending.is_some() {
            return Err("Resolve the pending session write before settling the request".into());
        }
        let s = self.sending.as_ref().ok_or("No chat request is active")?;
        let mut next = self.session.clone();
        let c = conversation_mut(&mut next, &s.conversation_id)?;
        let a = c["attempts"]
            .as_array_mut()
            .ok_or("Missing attempts")?
            .iter_mut()
            .find(|a| text(a, "attempt_id") == s.ids.attempt_id)
            .ok_or("Attempt not found")?;
        let cancelled = code == "E_COMPLETION_CANCELLED";
        let valid = rish_agent_core::session_schema::valid_attempt_failure_code(Some(&json!(code)));
        a["status"] = json!(if cancelled { "cancelled" } else { "failed" });
        a["active_round"] = Value::Null;
        a["failure_code"] = if cancelled {
            Value::Null
        } else {
            json!(if valid { code } else { "E_COMPLETION_NATIVE" })
        };
        a["updated_at"] = json!(now);
        self.commit(next, None, true)
    }
}

/// Existing project consent is reused only when complete and bound to this
/// conversation's native identity. Native completeV2 validates freshness again.
fn context(c: &Value, harness: &str) -> Result<(Value, Value)> {
    if c["project_id"].is_null() {
        return Ok((Value::Null, Value::Null));
    }
    let p = &c["project_context"];
    let m = &p["manifest"];
    let consent = &p["consent"];
    if p["status"] != "ready"
        || m["snapshot_id"] != consent["snapshot_id"]
        || m["snapshot_sha256"] != consent["snapshot_sha256"]
        || m["model"] != c["model_id"]
        || !c["runtime_context_id"].is_string()
    {
        return Err("Confirm project context before sending from this project conversation".into());
    }
    let provider = match harness {
        "claude-code" => "anthropic",
        "codex" => "openai",
        "glm" => "bigmodel",
        harness if crate::custom_provider_registry::provider_id_for_harness(harness).is_some() => {
            harness
        }
        _ => "deepseek",
    };
    let attempt = json!({"schema_version":1,"runtime_context_id":c["runtime_context_id"],"project_id":c["project_id"],
        "snapshot_id":m["snapshot_id"],"snapshot_sha256":m["snapshot_sha256"],"source_fingerprint":m["source_fingerprint"],
        "context_bytes":m["context_bytes"],"consent_receipt_id":consent["consent_receipt_id"],"provider":provider,"policy":"chat-read-v1","policy_version":"chat-read-v1.0.0"});
    let request = json!({"schema_version":1,"snapshot_id":m["snapshot_id"],"consent_receipt_id":consent["consent_receipt_id"],
        "conversation_id":c["runtime_context_id"],"project_id":c["project_id"],"provider":provider,"policy":"chat-read-v1"});
    Ok((attempt, request))
}
