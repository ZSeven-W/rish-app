use super::{Env, Validator};
use serde_json::{json, Value};

const ID: &str = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const TIME: &str = "2026-10-16T00:00:00.000Z";

fn call(access: &str, summary: &str) -> Value {
    json!({"schema_version":3,"call_id":"question_1","call_index":0,
        "name":"ask_user","arguments_sha256":"a".repeat(64),
        "safe_summary_key":summary,"access":access,
        "approval_decision":if access=="durable_deny" {"denied"} else {"pending"},
        "approval_token":null,"approval_reference":null,"idempotency_key":null,
        "native_row_revision":null,"receipt":null})
}

fn journal(version: u64, call: Value) -> Value {
    json!({"schema_version":3,"phase":"batch_frozen","controller_generation":0,
      "policy":{"schema_version":1,"policy_version":"agent-v1","max_single_write_bytes":32768,"max_batch_write_bytes":524288,"max_attempt_write_bytes":4194304},
      "root":{"schema_version":1,"kind":"workspace","workspace_id":ID,"workspace_binding_revision":1,"project_id":null,"root_fingerprint_sha256":"a".repeat(64),"capabilities":["file_read"]},
      "tool_registry_version":version,"toolset_sha256":"b".repeat(64),
      "transcript":{"schema_version":1,"transcript_ref":ID,"generation":0,"transcript_sha256":"a".repeat(64),"transcript_bytes":2},
      "round_index":0,"round_lineage":{"schema_version":2,"round_id":ID,"round_index":0,"launch_attempt":1,"status":"completed","native_row_revision":1},
      "call_index":null,"batch":[call],"frozen_grant_ids":[],"reserved_write_bytes":0,"updated_at":TIME})
}

#[test]
fn ask_user_call_accepts_only_current_auto_or_historical_unknown_denial() {
    let env = Env::default();
    let validator = Validator { env: &env };
    assert!(validator.agent_call(&call("auto", "agent.ask_user")));
    assert!(validator.agent_call(&call("durable_deny", "agent.unknown")));
    assert!(!validator.agent_call(&call("auto", "agent.unknown")));
    assert!(!validator.agent_call(&call("durable_deny", "agent.ask_user")));
    assert!(!validator.agent_call(&call("conversation_confirm", "agent.ask_user")));
}

#[test]
fn ask_user_journal_never_upgrades_pre_v4_denials() {
    let env = Env::default();
    let validator = Validator { env: &env };
    for version in 1..=5 {
        assert!(
            validator.agent_journal(&journal(version, call("durable_deny", "agent.unknown"))),
            "v{version}"
        );
        assert_eq!(
            validator.agent_journal(&journal(version, call("auto", "agent.ask_user"))),
            matches!(version, 4 | 5),
            "v{version}"
        );
        assert!(
            !validator.agent_journal(&journal(version, call("auto", "agent.unknown"))),
            "v{version}"
        );
    }
    assert!(!validator.agent_journal(&journal(6, call("auto", "agent.ask_user"))));
}

#[test]
fn v4_and_v5_conversation_grants_preserve_existing_tool_families() {
    let env = Env::default();
    let validator = Validator { env: &env };
    for family in ["file_write", "git_commit", "git_push", "guest_service"] {
        let mut grant = json!({"schema_version":2,"grant_id":ID,"conversation_id":ID,
          "workspace_id":ID,"project_id":ID,"binding_revision":1,"root_fingerprint_sha256":"a".repeat(64),
          "tool_family":family,"registry_version":4,"policy_version":"agent-v1",
          "issued_for":{"schema_version":1,"task_id":ID,"attempt_id":ID},"created_at":TIME});
        assert!(validator.agent_grant(&grant), "{family}");
        grant["registry_version"] = json!(5);
        assert!(validator.agent_grant(&grant), "{family}");
        grant["registry_version"] = json!(6);
        assert!(!validator.agent_grant(&grant), "{family}");
        grant["registry_version"] = json!(1);
        assert_eq!(
            validator.agent_grant(&grant),
            family != "guest_service",
            "{family}"
        );
    }
}
