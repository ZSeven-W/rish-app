use super::Case;
use serde_json::{json, Value};

/// Deterministic provider only. The actual native transport creates/parses the
/// HTTP envelope, and its tool executor must supply the second round feedback.
pub(super) fn respond(case: &mut Case, body: &Value) -> Result<Value, String> {
    if body["model"] != "deepseek-v4-flash" {
        return Err("Unexpected provider model".into());
    }
    if body["stream"] == true {
        return Err("This gate expects final JSON transport".into());
    }
    let messages = body["messages"]
        .as_array()
        .ok_or("Provider messages missing")?;
    let tools = body["tools"]
        .as_array()
        .ok_or("Agent tool definitions missing")?;
    let first = case.provider_calls == 0;
    case.provider_calls += 1;
    if case.scenario == "cancel-provider" {
        if !first {
            return Err("Cancelled provider request was sent again".into());
        }
        return Ok(
            json!({"id":"contract-delayed-final","model":"deepseek-v4-flash","choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"取消后的迟到回答不能保存。","reasoning_content":""}}]}),
        );
    }
    if !first {
        let tool_messages: Vec<_> = messages.iter().filter(|m| m["role"] == "tool").collect();
        if tool_messages.is_empty() {
            return Err("No real tool feedback reached next round".into());
        }
        let combined = tool_messages
            .iter()
            .filter_map(|m| m["content"].as_str())
            .collect::<Vec<_>>()
            .join("\n");
        let expected = match case.scenario.as_str() {
            "read" => "shell-native-contract-marker",
            "deny" => "denied",
            "question" => "blue",
            _ => "ok",
        };
        if !combined.contains(expected) {
            return Err(format!(
                "Tool feedback lacks expected fixture evidence for {}",
                case.scenario
            ));
        }
        case.feedback_seen = true;
        return Ok(
            json!({"id":"contract-final","model":"deepseek-v4-flash","choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"共享 Rust 与原生 Agent 契约验证完成。","reasoning_content":""}}]}),
        );
    }
    let (name, args) = match case.scenario.as_str() {
        "read" => ("read_file", json!({"path":"notes.txt"})),
        "write" | "deny" | "cancel" | "recover" => (
            "write_file",
            json!({"path":"created.txt","content":"来自共享 Rust 控制器\n","expected_prior":{"schema_version":1,"kind":"absent"}}),
        ),
        "question" => (
            "ask_user",
            json!({"question":"选择测试颜色","input_mode":"options","options":[{"id":"blue","label":"蓝色"},{"id":"green","label":"绿色"}]}),
        ),
        _ => return Err("Unknown fixture scenario".into()),
    };
    if !tools.iter().any(|t| t["function"]["name"] == name) {
        return Err(format!("Native registry did not advertise {name}"));
    }
    Ok(
        json!({"id":"contract-tools","model":"deepseek-v4-flash","choices":[{"finish_reason":"tool_calls","message":{"role":"assistant","content":null,"reasoning_content":"","tool_calls":[{"id":"contract-call-1","type":"function","function":{"name":name,"arguments":args.to_string()}}]}}]}),
    )
}
