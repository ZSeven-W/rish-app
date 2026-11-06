use super::*;
const NOW: &str = "2026-10-12T01:00:00.000Z";
const LATER: &str = "2026-10-12T01:00:01.000Z";
const CONVERSATION: &str = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
fn missing() -> Value {
    json!({"schema_version":1,"status":"missing","snapshot":null,"session_json":null,"writer_launch_instance_id":null,"current_launch_instance_id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"})
}
fn ready() -> ShellState {
    let mut s = ShellState::with_test_models();
    s.load_snapshot(missing()).unwrap();
    s.set_default_workspace(json!({"schema_version":2,"workspace_id":"845d980b-8acd-4710-a54c-7975b6839024","binding_revision":1,"display_name":"Default","status":"ok","capabilities":{"read":true,"write":true,"git":true}})).unwrap();
    s
}
fn commit(s: &mut ShellState) -> Option<RuntimeCommand> {
    let p = s.pending.as_ref().unwrap();
    let result = json!({"schema_version":1,"status":"committed","snapshot":{"schema_version":1,"generation":s.authority["snapshot"]["generation"].as_u64().unwrap_or(0)+1,"session_sha256":p.digest}});
    s.accept_persist(result).unwrap()
}
fn chat() -> ShellState {
    let mut s = ready();
    s.create_conversation(CONVERSATION, NOW, "deepseek-v4-flash")
        .unwrap();
    commit(&mut s);
    s
}
fn snapshot(session: &Value) -> Value {
    let raw = session.to_string();
    let digest = session_schema::candidate_digest(raw.as_bytes()).unwrap();
    json!({"schema_version":1,"status":"present","session_json":raw,"snapshot":{"schema_version":1,"generation":4,"session_sha256":digest},"writer_launch_instance_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","current_launch_instance_id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"})
}
fn reply(command: &RuntimeCommand) -> Value {
    let request: Value = serde_json::from_str(command.args[0].as_str().unwrap()).unwrap();
    let mut result = json!({"schema_version":2,"harness_id":"dsh","round_index":0,"provider_request_id":model::id(),"provider_response_id":"response-1","requested_model":"deepseek-v4-flash","model":"deepseek-v4-flash","thinking_mode":"high","text":"收到，世界 🌏","reasoning":"思考完成","tool_calls":[],"finish_reason":"stop","latency_ms":12,"visible_history_sha256":"a".repeat(64),"model_input_sha256":"b".repeat(64),"request_body_sha256":"c".repeat(64),"project_context_receipt":null});
    for key in ["turn_id", "attempt_id", "round_id"] {
        result[key] = request[key].clone();
    }
    result
}
#[test]
fn empty_and_new_conversation_use_real_schema9() {
    let mut s = ready();
    let command = s
        .create_conversation(CONVERSATION, NOW, "deepseek-v4-flash")
        .unwrap();
    assert_eq!(command.module, "SessionSnapshots");
    assert_eq!(command.method, "casPersistSession");
    assert_eq!(command.args[0]["expected"]["kind"], "missing");
    assert!(
        s.conversations().is_empty(),
        "only native commits become visible"
    );
    commit(&mut s);
    assert_eq!(s.conversations().len(), 1);
    assert_eq!(s.raw_session()["schema_version"], 9);
}

#[test]
fn unconfigured_conversation_has_no_model_and_cannot_dispatch_a_provider() {
    let mut state = ShellState::new();
    assert!(state.models().is_empty());
    state.load_snapshot(missing()).unwrap();
    assert!(state.preferences()["default_model"].is_null());
    assert_eq!(state.selected_model(), "");
    state.set_default_workspace(json!({"schema_version":2,
        "workspace_id":"845d980b-8acd-4710-a54c-7975b6839024","binding_revision":1,
        "display_name":"Default","status":"ok","capabilities":{"read":true,"write":true,"git":true}})).unwrap();
    state.create_conversation(CONVERSATION, NOW, "").unwrap();
    commit(&mut state);
    assert!(state.raw_session()["conversations"][0]["model_id"].is_null());
    let before = state.raw_session().clone();
    assert!(state
        .prepare_agent_send("Keep this draft", &TurnIds::new(), NOW)
        .is_err());
    assert!(state
        .prepare_send("Keep this draft", &TurnIds::new(), NOW)
        .is_err());
    assert_eq!(state.raw_session(), &before);
    assert!(!state.is_busy());
    assert!(state.query_pending_commit().is_none());
}

#[test]
fn explicit_test_catalog_does_not_populate_later_production_instances() {
    let fixture = ShellState::with_test_models();
    assert!(!fixture.models().is_empty());
    let mut production = ShellState::new();
    production.load_snapshot(missing()).unwrap();
    assert!(production.models().is_empty());
    assert!(production.preferences()["default_model"].is_null());
}
#[test]
fn non_ascii_turn_waits_for_cas_then_commits_native_receipt() {
    let mut s = chat();
    let ids = TurnIds::new();
    let command = s.prepare_send("你好，世界 🌏", &ids, NOW).unwrap();
    assert_eq!(command.method, "casPersistSession");
    assert!(s.messages().is_empty());
    let request = commit(&mut s).unwrap();
    assert_eq!(request.method, "completeV2");
    assert_eq!(s.messages()[0].text, "你好，世界 🌏");
    let envelope: Value = serde_json::from_str(request.args[0].as_str().unwrap()).unwrap();
    assert_eq!(envelope["tools"], json!([]));
    assert_eq!(envelope["schema_version"], 2);
    s.accept_completion(reply(&request), LATER).unwrap();
    commit(&mut s);
    assert!(!s.is_busy());
    assert_eq!(s.messages()[1].text, "收到，世界 🌏");
    assert_eq!(s.messages()[1].reasoning, "思考完成");
    assert_eq!(
        s.raw_session()["messages"],
        s.raw_session()["conversations"][0]["messages"]
    );
    assert_eq!(
        s.raw_session()["conversations"][0]["attempts"][0]["status"],
        "completed"
    );
}
#[test]
fn conflict_never_dispatches_provider_and_requires_reload() {
    let mut s = chat();
    let before = s.raw_session().clone();
    s.prepare_send("hello", &TurnIds::new(), NOW).unwrap();
    assert!(s.accept_persist(json!({"schema_version":1,"status":"conflict","current":{"schema_version":1,"kind":"missing"}})).is_err());
    assert_eq!(s.raw_session(), &before);
    assert!(!s.is_loaded());
    assert!(s.prepare_send("retry", &TurnIds::new(), NOW).is_err());
}
#[test]
fn ambiguous_write_keeps_operation_for_query_and_does_not_resend() {
    let mut s = chat();
    s.prepare_send("hello", &TurnIds::new(), NOW).unwrap();
    let query = s.query_pending_commit().unwrap();
    assert!(s
        .accept_persist(json!({"schema_version":1,"status":"unknown"}))
        .is_err());
    assert_eq!(s.query_pending_commit(), Some(query));
    assert!(s.prepare_send("again", &TurnIds::new(), NOW).is_err());
    assert!(commit(&mut s).is_some());
}
#[test]
fn wrong_commit_digest_never_mutates_state() {
    let mut s = chat();
    let old = s.raw_session().clone();
    s.rename_conversation(CONVERSATION, "另一标题").unwrap();
    assert!(s.accept_persist(json!({"schema_version":1,"status":"committed","snapshot":{"schema_version":1,"generation":2,"session_sha256":"f".repeat(64)}})).is_err());
    assert_eq!(s.raw_session(), &old);
    assert!(s.query_pending_commit().is_some());
}
#[test]
fn existing_ios_agent_journal_survives_unrelated_chat_and_selection() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../../modules/rish/ios/Tests/Fixtures/agent-begin-round-session.json"
    ))
    .unwrap();
    let mut s = ShellState::with_test_models();
    s.load_snapshot(snapshot(&fixture)).unwrap();
    assert!(s.conversations()[0].has_active_attempt);
    assert_eq!(s.messages()[0].text, "write and commit");
    assert!(s.prepare_send("not allowed", &TurnIds::new(), NOW).is_err());
    s.set_default_workspace(json!({"schema_version":2,"workspace_id":"845d980b-8acd-4710-a54c-7975b6839024","binding_revision":1,"display_name":"Default","status":"ok","capabilities":{"read":true,"write":true,"git":true}})).unwrap();
    s.create_conversation(CONVERSATION, NOW, "deepseek-v4-flash")
        .unwrap();
    commit(&mut s);
    assert_eq!(
        s.raw_session()["conversations"][0],
        fixture["conversations"][0]
    );
    assert_eq!(s.raw_session()["session_events"], fixture["session_events"]);
    let original = fixture["active_conversation_id"].as_str().unwrap();
    s.select_conversation(original).unwrap();
    commit(&mut s);
    assert_eq!(s.raw_session()["messages"], fixture["messages"]);
}
#[test]
fn unknown_future_fields_are_not_silently_stripped() {
    let mut fixture = empty_session();
    fixture["future_authority"] = json!({"opaque":"must survive"});
    let mut s = ready();
    s.load_snapshot(snapshot(&fixture)).unwrap();
    assert!(s
        .create_conversation(CONVERSATION, NOW, "deepseek-v4-flash")
        .is_err());
    assert_eq!(
        s.raw_session()["future_authority"],
        json!({"opaque":"must survive"})
    );
    assert!(!s.is_busy());
}
#[test]
fn model_catalog_installs_retired_identities_before_loading() {
    let mut s = ready();
    let command=s.apply_catalog(json!({"schema_version":1,"models":[{"id":"deepseek-new","name":"新模型","supports_images":true}],"retired_models":[{"id":"deepseek-old","name":"旧模型","supports_images":false}]})).unwrap();
    assert_eq!(command.method, "loadSessionSnapshot");
    assert!(s
        .environment
        .supported_models
        .contains(&"deepseek-old".to_owned()));
    assert!(!s.models().iter().any(|m| m.id == "deepseek-old"));
    s.create_conversation(CONVERSATION, NOW, "deepseek-new")
        .unwrap();
    commit(&mut s);
    assert_eq!(s.selected_model(), "deepseek-new");
}
#[test]
fn refuses_uncorrelated_results_and_unrequested_tools() {
    let mut s = chat();
    s.prepare_send("hello", &TurnIds::new(), NOW).unwrap();
    let command = commit(&mut s).unwrap();
    let valid = reply(&command);
    let mut changed = valid.clone();
    changed["round_id"] = json!(model::id());
    assert!(s.accept_completion(changed, LATER).is_err());
    let mut changed = valid;
    changed["tool_calls"] = json!([{"id":"a","name":"write_file","arguments":"{}"}]);
    assert!(s.accept_completion(changed, LATER).is_err());
    assert_eq!(s.messages().len(), 1);
    s.fail_send("E_COMPLETION_NATIVE", LATER).unwrap();
    commit(&mut s);
    assert!(!s.is_busy());
}
#[test]
fn cancelled_attempt_rejects_late_result() {
    let mut s = chat();
    s.prepare_send("hello", &TurnIds::new(), NOW).unwrap();
    let command = commit(&mut s).unwrap();
    assert_eq!(s.cancel_command().unwrap().method, "cancelCompletion");
    s.fail_send("E_COMPLETION_CANCELLED", LATER).unwrap();
    commit(&mut s);
    assert!(s.accept_completion(reply(&command), LATER).is_err());
    assert_eq!(
        s.raw_session()["conversations"][0]["attempts"][0]["status"],
        "cancelled"
    );
}

#[test]
fn definitive_no_write_unblocks_prepared_send_without_dispatching_provider() {
    for status in ["not_committed", "not_started"] {
        let mut s = chat();
        s.prepare_send("hello", &TurnIds::new(), NOW).unwrap();
        assert!(s
            .accept_persist(json!({"schema_version":1,"status":status}))
            .is_err());
        assert!(!s.is_busy());
        assert!(s.messages().is_empty());
        assert!(s.prepare_send("retry", &TurnIds::new(), NOW).is_ok());
    }
}
#[test]
fn definitive_answer_save_failure_retries_identical_write_without_provider() {
    let mut s = chat();
    s.prepare_send("hello", &TurnIds::new(), NOW).unwrap();
    let command = commit(&mut s).unwrap();
    let save = s.accept_completion(reply(&command), LATER).unwrap();
    assert!(s
        .accept_persist(json!({"schema_version":1,"status":"not_committed"}))
        .is_err());
    let retry = s.retry_pending_commit().unwrap();
    assert_eq!(retry, save);
    assert!(s.retry_pending_commit().is_none());
    assert!(commit(&mut s).is_none());
    assert_eq!(s.messages().len(), 2);
    assert!(!s.is_busy());
}
#[test]
fn old_writer_plain_chat_recovery_preserves_message_and_cannot_replay_request() {
    let mut s = chat();
    s.prepare_send("survive restart", &TurnIds::new(), NOW)
        .unwrap();
    commit(&mut s);
    let mut restored = ShellState::with_test_models();
    restored.load_snapshot(snapshot(s.raw_session())).unwrap();
    assert!(restored.recovery_command(LATER).unwrap().is_some());
    assert!(commit(&mut restored).is_none());
    assert_eq!(restored.messages()[0].text, "survive restart");
    assert_eq!(
        restored.raw_session()["conversations"][0]["attempts"][0]["failure_code"],
        "E_ATTEMPT_INTERRUPTED"
    );
    assert!(restored
        .prepare_send("continue", &TurnIds::new(), LATER)
        .is_ok());
}
#[test]
fn current_writer_cannot_be_interrupted_by_bootstrap_recovery() {
    let mut s = chat();
    s.prepare_send("still running", &TurnIds::new(), NOW)
        .unwrap();
    commit(&mut s);
    let mut envelope = snapshot(s.raw_session());
    envelope["writer_launch_instance_id"] = envelope["current_launch_instance_id"].clone();
    let mut restored = ShellState::with_test_models();
    restored.load_snapshot(envelope).unwrap();
    assert!(restored.recovery_command(LATER).unwrap().is_none());
    assert!(restored
        .prepare_send("overlap", &TurnIds::new(), LATER)
        .is_err());
}

#[test]
fn consented_project_chat_uses_schema3_and_keeps_frozen_receipt() {
    let mut fixture: Value = serde_json::from_str(include_str!(
        "../../../../../modules/rish/ios/Tests/Fixtures/agent-begin-round-session.json"
    ))
    .unwrap();
    fixture["conversations"][0]["attempts"] = json!([]);
    fixture["conversations"][0]["turns"] = json!([]);
    fixture["session_events"] = json!([]);
    let mut s = ShellState::with_test_models();
    s.load_snapshot(snapshot(&fixture)).unwrap();
    let manifest = fixture["conversations"][0]["project_context"]["manifest"].clone();
    s.prepare_send("读取项目上下文", &TurnIds::new(), NOW)
        .unwrap();
    let command = commit(&mut s).unwrap();
    let request: Value = serde_json::from_str(command.args[0].as_str().unwrap()).unwrap();
    assert_eq!(request["schema_version"], 3);
    assert_eq!(
        request["project_context"]["snapshot_id"],
        manifest["snapshot_id"]
    );
    let mut response = reply(&command);
    response["schema_version"] = json!(3);
    response["project_context_receipt"] = json!({"schema_version":1,"snapshot_id":manifest["snapshot_id"],"snapshot_sha256":manifest["snapshot_sha256"],"source_fingerprint":manifest["source_fingerprint"],"context_bytes":manifest["context_bytes"],"verified_at":NOW});
    s.accept_completion(response, LATER).unwrap();
    commit(&mut s);
    let attempt = &s.raw_session()["conversations"][0]["attempts"][0];
    assert_eq!(attempt["context_disposition"], "verified");
    assert_eq!(attempt["rounds"][0]["transport_schema_version"], 3);
}

#[test]
fn completed_answer_rebases_only_over_unchanged_conversation_without_resend() {
    let mut s = chat();
    s.prepare_send("hello", &TurnIds::new(), NOW).unwrap();
    let command = commit(&mut s).unwrap();
    let mut fresh = s.raw_session().clone();
    s.accept_completion(reply(&command), LATER).unwrap();
    assert!(s
        .accept_persist(json!({"schema_version":1,"status":"conflict"}))
        .is_err());
    assert_eq!(s.unsaved_answer().unwrap().text, "收到，世界 🌏");
    fresh["preferences"]["locale"] = json!("zh-CN");
    s.load_snapshot(snapshot(&fresh)).unwrap();
    let recovery = s.recovery_command(LATER).unwrap().unwrap();
    assert_eq!(recovery.method, "casPersistSession");
    assert!(commit(&mut s).is_none());
    assert_eq!(s.messages().len(), 2);
    assert_eq!(s.preferences()["locale"], "zh-CN");
    assert!(s.unsaved_answer().is_none());
    assert!(!s.is_busy());
}
#[test]
fn completed_answer_conflict_never_overwrites_changed_target_conversation() {
    let mut s = chat();
    s.prepare_send("hello", &TurnIds::new(), NOW).unwrap();
    let command = commit(&mut s).unwrap();
    let mut fresh = s.raw_session().clone();
    s.accept_completion(reply(&command), LATER).unwrap();
    assert!(s
        .accept_persist(json!({"schema_version":1,"status":"conflict"}))
        .is_err());
    fresh["conversations"][0]["title"] = json!("Renamed by another operation");
    s.load_snapshot(snapshot(&fresh)).unwrap();
    assert!(s.recovery_command(LATER).is_err());
    assert_eq!(s.raw_session(), &fresh);
    assert_eq!(s.unsaved_answer().unwrap().text, "收到，世界 🌏");
    assert!(s.is_busy());
}

#[test]
fn failed_and_cancelled_turn_conflicts_reload_and_settle_only_unchanged_attempt() {
    for (code, kind, status) in [
        ("E_COMPLETION_NATIVE", ConflictKind::Failed, "failed"),
        (
            "E_COMPLETION_CANCELLED",
            ConflictKind::Cancelled,
            "cancelled",
        ),
    ] {
        let mut s = chat();
        assert!(s.can_reload());
        s.prepare_send("hello", &TurnIds::new(), NOW).unwrap();
        assert!(!s.can_reload());
        commit(&mut s);
        assert!(!s.can_reload());
        let mut fresh = s.raw_session().clone();
        s.fail_send(code, LATER).unwrap();
        assert!(s
            .accept_persist(json!({"schema_version":1,"status":"conflict"}))
            .is_err());
        assert!(s.can_reload());
        assert!(s.is_busy());
        assert!(s.unsaved_answer().is_none());
        let pending = s.pending_conflict().unwrap();
        assert_eq!(pending.kind, kind);
        assert!(pending.answer.is_none());
        fresh["conversations"][0]["title"] = json!("Edited elsewhere");
        fresh["preferences"]["locale"] = json!("zh-CN");
        let mut load = snapshot(&fresh);
        load["writer_launch_instance_id"] = load["current_launch_instance_id"].clone();
        s.load_snapshot(load).unwrap();
        assert!(s.recovery_command(LATER).unwrap().is_some());
        assert!(commit(&mut s).is_none());
        assert_eq!(s.conversations()[0].title, "Edited elsewhere");
        assert_eq!(s.preferences()["locale"], "zh-CN");
        assert_eq!(
            s.raw_session()["conversations"][0]["attempts"][0]["status"],
            status
        );
        assert!(s.pending_conflict().is_none());
        assert!(!s.is_busy());
        assert!(s.prepare_send("continue", &TurnIds::new(), LATER).is_ok());
    }
}
#[test]
fn changed_failed_attempt_conflict_is_explicit_and_discardable_without_answer() {
    let mut s = chat();
    s.prepare_send("hello", &TurnIds::new(), NOW).unwrap();
    commit(&mut s);
    let mut fresh = s.raw_session().clone();
    s.fail_send("E_COMPLETION_NATIVE", LATER).unwrap();
    assert!(s
        .accept_persist(json!({"schema_version":1,"status":"conflict"}))
        .is_err());
    fresh["conversations"][0]["attempts"][0]["updated_at"] = json!(LATER);
    let mut load = snapshot(&fresh);
    load["writer_launch_instance_id"] = load["current_launch_instance_id"].clone();
    s.load_snapshot(load).unwrap();
    assert!(s.recovery_command(LATER).is_err());
    assert_eq!(s.raw_session(), &fresh);
    assert_eq!(s.pending_conflict().unwrap().kind, ConflictKind::Failed);
    assert!(s.unsaved_answer().is_none());
    assert!(s.can_reload());
    s.discard_pending_conflict().unwrap();
    assert!(!s.is_busy());
    assert_eq!(s.raw_session(), &fresh);
}

#[test]
fn first_configured_response_conflict_keeps_native_binding_across_catalog_refresh() {
    let mut s = chat();
    s.prepare_send("hello", &TurnIds::new(), NOW).unwrap();
    let command = commit(&mut s).unwrap();
    let mut fresh = s.raw_session().clone();
    let mut response = reply(&command);
    let binding = json!({"schema_version":1,"harness_id":"dsh","endpoint_url":"https://models.example.test/v1/chat/completions","protocol":"chat-completions","auth_type":"bearer","send_reasoning":true,"model_id":"deepseek-provider-alias","profile_id":"d".repeat(64)});
    response["provider_configuration"] = binding.clone();
    s.accept_completion(response, LATER).unwrap();
    assert!(s
        .accept_persist(json!({"schema_version":1,"status":"conflict"}))
        .is_err());
    s.apply_catalog(json!({"schema_version":1,"models":[{"id":"deepseek-v4-flash","name":"Flash","supports_images":true}],"retired_models":[]})).unwrap();
    fresh["preferences"]["locale"] = json!("zh-CN");
    s.load_snapshot(snapshot(&fresh)).unwrap();
    assert!(s.recovery_command(LATER).unwrap().is_some());
    commit(&mut s);
    assert_eq!(
        s.raw_session()["conversations"][0]["attempts"][0]["rounds"][0]["provider_configuration"],
        binding
    );
    assert_eq!(s.messages().len(), 2);
    assert_eq!(s.preferences()["locale"], "zh-CN");
}

#[test]
fn configuration_choices_are_published_together_only_after_native_commit() {
    let mut s = chat();
    let original = s.raw_session().clone();
    let command = s.set_chat_configuration("deepseek-v4-pro", "max").unwrap();
    assert_eq!(command.method, "casPersistSession");
    assert_eq!(s.raw_session(), &original);
    let candidate: Value =
        serde_json::from_str(command.args[0]["candidate_json"].as_str().unwrap()).unwrap();
    assert_eq!(candidate["conversations"][0]["model_id"], "deepseek-v4-pro");
    assert_eq!(candidate["conversations"][0]["thinking_mode"], "max");
    assert!(s
        .set_chat_configuration("deepseek-v4-flash", "off")
        .is_err());
    assert!(commit(&mut s).is_none());
    assert_eq!(s.selected_model(), "deepseek-v4-pro");
    assert_eq!(s.selected_thinking(), "max");
}

#[test]
fn configured_creation_is_one_validated_transaction_and_invalid_choices_do_not_start_it() {
    let mut s = ready();
    assert!(s
        .create_conversation_configured(CONVERSATION, NOW, "deepseek-v4-pro", "fast")
        .is_err());
    assert!(s
        .create_conversation_configured(CONVERSATION, NOW, "unknown-model", "off")
        .is_err());
    assert!(!s.is_busy());
    s.create_conversation_configured(CONVERSATION, NOW, "deepseek-v4-pro", "off")
        .unwrap();
    assert!(s.conversations().is_empty());
    commit(&mut s);
    assert_eq!(s.conversations().len(), 1);
    assert_eq!(s.selected_model(), "deepseek-v4-pro");
    assert_eq!(s.selected_thinking(), "off");
    assert!(s.set_chat_configuration("unknown-model", "max").is_err());
    assert!(!s.is_busy());
}

#[test]
fn default_model_commits_only_the_preference_without_changing_existing_chats() {
    let mut s = chat();
    s.create_conversation_configured(
        "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
        LATER,
        "claude-sonnet-5",
        "off",
    )
    .unwrap();
    commit(&mut s);
    let before = s.raw_session().clone();
    let mut expected = before.clone();
    expected["preferences"]["default_model"] = json!("gpt-5.6");
    let command = s.set_default_model("gpt-5.6").unwrap();
    assert_eq!(command.module, "SessionSnapshots");
    assert_eq!(command.method, "casPersistSession");
    assert_eq!(command.args[0]["expected"], s.authority);
    let candidate: Value =
        serde_json::from_str(command.args[0]["candidate_json"].as_str().unwrap()).unwrap();
    assert_eq!(candidate, expected);
    assert_eq!(s.raw_session(), &before);
    assert!(commit(&mut s).is_none());
    assert_eq!(s.raw_session(), &expected);
    assert_eq!(s.selected_model(), "claude-sonnet-5");
    assert_eq!(s.preferences()["selected_harness_id"], "dsh");
}

#[test]
fn default_model_accepts_only_current_catalog_and_keeps_generic_preference_gate_closed() {
    let mut s = chat();
    s.apply_catalog(json!({"schema_version":1,
        "models":[{"id":"deepseek-current","name":"Current","supports_images":false}],
        "retired_models":[{"id":"deepseek-v4-flash","name":"Retired","supports_images":false}]}))
        .unwrap();
    let before = s.raw_session().clone();
    for invalid in ["unknown-model", "deepseek-v4-flash", "pi", ""] {
        assert_eq!(
            s.set_default_model(invalid).unwrap_err(),
            "Choose a current model"
        );
        assert_eq!(s.raw_session(), &before);
        assert!(!s.is_busy());
    }
    assert!(s
        .set_preference("default_model", json!("deepseek-current"))
        .is_err());
    assert_eq!(s.raw_session(), &before);
    s.set_default_model("deepseek-current").unwrap();
    commit(&mut s);
    assert_eq!(s.preferences()["default_model"], "deepseek-current");
    assert_eq!(s.selected_model(), "deepseek-v4-flash");
}

#[test]
fn default_model_requires_loaded_idle_writer_and_retries_on_fresh_cas_authority() {
    let mut unloaded = ShellState::new();
    let before = unloaded.raw_session().clone();
    assert_eq!(
        unloaded.set_default_model("gpt-5.6").unwrap_err(),
        "Load the native session first"
    );
    assert_eq!(unloaded.raw_session(), &before);
    assert!(!unloaded.is_busy());

    let mut s = chat();
    let original = s.raw_session().clone();
    s.set_preference("locale", json!("zh-CN")).unwrap();
    let pending = s.query_pending_commit().unwrap();
    assert_eq!(
        s.set_default_model("gpt-5.6").unwrap_err(),
        "A native operation is still in progress"
    );
    assert_eq!(s.query_pending_commit().unwrap(), pending);
    assert_eq!(s.raw_session(), &original);
    assert!(s
        .accept_persist(json!({"schema_version":1,"status":"conflict"}))
        .is_err());
    assert!(s.set_default_model("gpt-5.6").is_err());
    let mut latest = original;
    latest["preferences"]["locale"] = json!("en-US");
    latest["preferences"]["show_reasoning"] = json!(true);
    s.load_snapshot(snapshot(&latest)).unwrap();
    let command = s.set_default_model("gpt-5.6").unwrap();
    assert_eq!(command.args[0]["expected"]["snapshot"]["generation"], 4);
    latest["preferences"]["default_model"] = json!("gpt-5.6");
    commit(&mut s);
    assert_eq!(s.raw_session(), &latest);

    let mut running = chat();
    running
        .prepare_agent_send("检查项目", &TurnIds::new(), NOW)
        .unwrap();
    let agent_command = commit(&mut running).unwrap();
    let before = running.raw_session().clone();
    assert!(running.set_default_model("gpt-5.6").is_err());
    assert_eq!(running.raw_session(), &before);
    assert!(running.owns_agent_command(&agent_command));
}

#[test]
fn configuration_does_not_bypass_active_attempts_or_project_consent() {
    let mut s = chat();
    s.prepare_send("hello", &TurnIds::new(), NOW).unwrap();
    commit(&mut s);
    let original = s.raw_session().clone();
    assert!(s.set_chat_configuration("deepseek-v4-pro", "off").is_err());
    assert_eq!(s.raw_session(), &original);

    let mut s = chat();
    // This is a refusal-path fixture: an existing consent must not be replaced
    // or cleared as a side effect of changing the model in the settings card.
    s.session["conversations"][0]["project_context"] = json!({"status":"ready"});
    let original = s.raw_session().clone();
    assert!(s.set_chat_configuration("deepseek-v4-pro", "max").is_err());
    assert_eq!(s.raw_session(), &original);
    assert!(!s.is_busy());
}

#[test]
fn title_rename_uses_shared_normalization_and_persisted_byte_budget() {
    let mut s = chat();
    s.rename_conversation(CONVERSATION, "\u{0085} Cafe\u{301}\u{3000}")
        .unwrap();
    assert_eq!(s.conversations()[0].title, "New chat");
    commit(&mut s);
    assert_eq!(s.conversations()[0].title, "Café");

    s.rename_conversation(CONVERSATION, &"中".repeat(40))
        .unwrap();
    commit(&mut s);
    assert_eq!(s.conversations()[0].title, "中".repeat(40));

    let before = s.raw_session().clone();
    for invalid in ["中".repeat(41), "two\nlines".into(), " \t ".into()] {
        assert!(s.rename_conversation(CONVERSATION, &invalid).is_err());
        assert_eq!(s.raw_session(), &before);
        assert!(
            !s.is_busy(),
            "a refused title must not prepare a native write"
        );
    }
}

#[test]
fn long_chinese_first_message_commits_its_title_without_truncating_the_body() {
    let mut s = chat();
    let body = format!("{}\n保留第二行。", "中".repeat(60));
    s.prepare_send(&body, &TurnIds::new(), NOW).unwrap();
    let request = commit(&mut s).unwrap();
    assert_eq!(s.conversations()[0].title, "中".repeat(40));
    assert_eq!(s.messages()[0].text, body);
    let envelope: Value = serde_json::from_str(request.args[0].as_str().unwrap()).unwrap();
    assert_eq!(envelope["visible_history"][0]["content"], body);
    s.accept_completion(reply(&request), LATER).unwrap();
    commit(&mut s);
    assert_eq!(s.messages()[0].text, body);
    assert!(!s.is_busy());
}

#[test]
fn emoji_and_multiline_first_messages_get_single_line_persistable_titles() {
    for (body, title) in [
        ("🌏".repeat(60), "🌏".repeat(30)),
        ("  规划\n项目\t下一步  ".into(), "规划 项目 下一步".into()),
        ("a".repeat(80), "a".repeat(60)),
    ] {
        let mut s = chat();
        s.prepare_send(&body, &TurnIds::new(), NOW).unwrap();
        commit(&mut s);
        assert_eq!(s.conversations()[0].title, title);
        assert_eq!(s.messages()[0].text, body);
    }
}
