//! Ephemeral native stream display. Never changes authority or durable data.
use crate::{model::text, ShellState};
use serde_json::Value;
impl ShellState {
    pub fn accept_agent_preview(&mut self, value: Value) -> bool {
        let Some(r) = self.agent_run.as_mut() else {
            return false;
        };
        let Some(c) = &r.in_flight else { return false };
        let q = &c.args[0];
        if c.method != "complete_agent_round_v2" || value["schema_version"] != 1 || r.preview_ended
        {
            return false;
        }
        for key in [
            "task_id",
            "attempt_id",
            "round_id",
            "round_index",
            "operation_id",
            "harness_id",
        ] {
            if value[key] != q[key] {
                return false;
            }
        }
        let provider = text(&value, "provider_request_id");
        if provider.is_empty()
            || provider.len() > 256
            || r.preview_provider.as_ref().is_some_and(|p| p != provider)
        {
            return false;
        }
        let Some(seq) = value["seq"].as_u64().filter(|s| *s > r.preview_seq) else {
            return false;
        };
        let kind = text(&value, "kind");
        if kind == "delta" {
            for key in ["text", "reasoning"] {
                if let Some(v) = value.get(key) {
                    if !v.is_string() || v.as_str().unwrap().len() > 262144 {
                        return false;
                    }
                }
            }
            if let Some(calls) = value.get("tool_calls") {
                let Some(calls) = calls.as_array().filter(|a| !a.is_empty() && a.len() <= 16)
                else {
                    return false;
                };
                for call in calls {
                    let Some(o) = call.as_object() else {
                        return false;
                    };
                    if o.keys()
                        .any(|k| !matches!(k.as_str(), "index" | "id" | "name" | "arguments"))
                        || call["index"].as_u64().is_none_or(|i| i > 15)
                    {
                        return false;
                    }
                    for (key, max) in [("id", 128), ("name", 64), ("arguments", 262144)] {
                        if let Some(v) = call.get(key) {
                            if !v.is_string() || v.as_str().unwrap().len() > max {
                                return false;
                            }
                        }
                    }
                }
            }
            if let Some(f) = value.get("finish_reason") {
                if !matches!(
                    f.as_str(),
                    Some("stop" | "tool_calls" | "length" | "content_filter")
                ) {
                    return false;
                }
            }
            if !["text", "reasoning", "tool_calls", "finish_reason"]
                .iter()
                .any(|k| value.get(k).is_some())
            {
                return false;
            }
            for (target, key) in [
                (&mut r.preview_text, "text"),
                (&mut r.preview_reasoning, "reasoning"),
            ] {
                let delta = text(&value, key);
                if target.len() + delta.len() <= 262144 {
                    target.push_str(delta)
                } else {
                    r.preview_incomplete = true
                }
            }
        } else if kind == "end" {
            if !matches!(text(&value, "status"), "validated" | "failed")
                || !value["truncated"].is_boolean()
            {
                return false;
            }
            if let Some(code) = value.get("failure_code") {
                if code.as_str().is_none_or(|s| s.is_empty() || s.len() > 64) {
                    return false;
                }
            }
            if let Some(http) = value.get("http_status") {
                if http.as_u64().is_none_or(|n| !(100..=599).contains(&n)) {
                    return false;
                }
            }
            r.preview_ended = true;
            r.preview_incomplete |= value["truncated"] == true || value["status"] == "failed";
        } else {
            return false;
        }
        r.preview_incomplete |= seq != r.preview_seq + 1;
        r.preview_provider = Some(provider.into());
        r.preview_seq = seq;
        true
    }
}
