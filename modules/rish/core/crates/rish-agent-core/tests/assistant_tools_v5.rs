use rish_agent_core::{
    assistant_tools as assistant,
    canonical::{canonical_json, hash_json},
    execution_ledger::{
        feedback_string_valid, precondition_shape, raw_arguments_bind_intent,
        settled_facts_match_feedback,
    },
    ledger_batch::{approval_preview, write_manifest_call_shape},
    ledger_ops::write_manifest_call_for_intent,
    provider_round::tool_description,
    schema::arguments_sha256,
    tool_batch::{prepare_calls, prepare_finish, tool_arguments_accepted},
    tool_execution::{needs_effect_gate, recover_plan, settlement_plan},
    tool_registry::registry_for_root_version,
    wal_state,
};
use serde_json::{json, Value};
const ID: &str = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const OTHER: &str = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
fn args(name: &str) -> Value {
    match name {
        "list_assistant_tasks" | "search_assistant_memory" => json!({}),
        "remember_assistant_memory" => {
            json!({"title":"Style","content":"Use concise Chinese replies.","kind":"preference"})
        }
        "forget_assistant_memory" => json!({"memory_id":ID}),
        "create_assistant_task" => {
            json!({"title":"Review inbox", "instructions":"Summarize unread messages when asked."})
        }
        _ => json!({"task_id":ID,"paused":true}),
    }
}
fn root() -> Value {
    json!({"schema_version":1,"kind":"workspace","workspace_id":ID,"workspace_binding_revision":1,"project_id":null,"root_fingerprint_sha256":"a".repeat(64),"capabilities":["file_read","file_write"]})
}
fn row(name: &str) -> Value {
    let digest =
        arguments_sha256(Some(&json!(name)), Some(&json!(args(name).to_string()))).unwrap();
    json!({"name":name,"arguments_sha256":digest,"state":"running","row_revision":3,
        "locator":{"schema_version":2,"task_id":ID,"attempt_id":ID,"round_id":ID,"round_index":0,"call_index":0,"call_id":"call_1","idempotency_key":"c".repeat(64)},
        "precondition":{"schema_version":1,"kind":name,"conversation_id":ID,"arguments_sha256":digest,"expected_store_revision":7}})
}
fn effect(row: &Value) -> Value {
    let name = row["name"].as_str().unwrap();
    let revision = if assistant::is_mutation(name) { 8 } else { 7 };
    let payload = if matches!(
        name,
        "remember_assistant_memory" | "forget_assistant_memory"
    ) {
        json!({"schema_version":1,"memory_id":ID,"store_revision":revision})
    } else if name == "search_assistant_memory" {
        json!({"schema_version":1,"store_revision":revision,"memories":[{"memory_id":ID,"title":"Style","content":"Use concise Chinese replies.","kind":"preference","created_at_ms":1,"updated_at_ms":1}],"truncated":false})
    } else if assistant::is_mutation(name) {
        json!({"schema_version":1,"task_id":ID,"store_revision":revision})
    } else {
        json!({"schema_version":1,"store_revision":revision,"tasks":[{"task_id":ID,"title":"Review inbox","paused":false,"follow_up_minutes":null,"pending_manual":false}],"truncated":false})
    };
    json!({"schema_version":1,"status":"ok","feedback":assistant::feedback_string(name,payload.clone()).unwrap(),
        "settled_facts":{"schema_version":1,"kind":name,"conversation_id":ID,"arguments_sha256":row["arguments_sha256"],
            "locator_sha256":hash_json("assistant-tool-locator", &row["locator"]).unwrap(),"store_revision":revision,
            "payload_sha256":hash_json("assistant-tool-payload", &payload).unwrap()},
        "truncated":false,"effect_may_have_occurred":assistant::is_mutation(name)})
}

#[test]
fn exact_model_arguments_reject_authority_fields_and_bad_schedules() {
    for name in assistant::NAMES {
        let input = args(name);
        assert!(tool_arguments_accepted(Some(&json!(name)), input.as_object().unwrap()).is_ok());
        assert!(tool_description(name).unwrap().len() <= 1024);
        for key in [
            "model_id",
            "workspace",
            "workspace_binding",
            "auth_profile",
            "runtime",
            "path",
            "data_root",
            "run_now",
            "delete",
            "profile",
            "state",
        ] {
            let mut forged = input.clone();
            forged[key] = json!("injected");
            assert!(
                !assistant::arguments_valid(name, forged.as_object().unwrap()),
                "{name}: {key}"
            );
        }
    }
    let mut create = args("create_assistant_task");
    for invalid in [
        json!(0),
        json!(14),
        json!(15.5),
        json!(true),
        json!(u64::from(u32::MAX) + 1),
    ] {
        create["follow_up_minutes"] = invalid;
        assert!(!assistant::arguments_valid(
            "create_assistant_task",
            create.as_object().unwrap()
        ));
    }
    for valid in [Value::Null, json!(15), json!(u32::MAX)] {
        create["follow_up_minutes"] = valid;
        assert!(assistant::arguments_valid(
            "create_assistant_task",
            create.as_object().unwrap()
        ));
    }
    assert!(!assistant::arguments_valid(
        "update_assistant_task",
        json!({"task_id":ID}).as_object().unwrap()
    ));
    for bad_title in [
        " ".to_string(),
        "x".repeat(121),
        "line\nline".into(),
        " leading".into(),
        "e\u{301}".into(),
    ] {
        create["title"] = json!(bad_title);
        assert!(!assistant::arguments_valid(
            "create_assistant_task",
            create.as_object().unwrap()
        ));
    }
}

#[test]
fn routing_preserves_approval_and_redacts_task_content() {
    for name in assistant::NAMES {
        let row = row(name);
        let request = json!({"round_index":0,"conversation_id":ID,"root":root()});
        let messages = [
            json!({"role":"assistant","round_index":0,"tool_calls":[{"call_id":"call_1","name":name,"arguments_json":args(name).to_string()}]}),
        ];
        let round = json!({"calls":[{"call_index":0,"call_id":"call_1","name":name,"arguments_sha256":row["arguments_sha256"]}]});
        let authority = json!({"registry":registry_for_root_version(&root(),false,5).unwrap()});
        let calls = prepare_calls(&request, &round, Some(&messages), &authority, &[]);
        assert_eq!(calls["calls"][0]["executor"], "assistant");
        assert_eq!(calls["mutation_batch"], assistant::is_mutation(name));
        assert_eq!(
            calls["calls"][0]["access"],
            if assistant::is_mutation(name) {
                "conversation_confirm"
            } else {
                "auto"
            }
        );
        let prepared = prepare_finish(
            &request,
            calls["calls"].as_array().unwrap(),
            &[json!({"prepared":{"precondition":row["precondition"],"reserved_write_bytes":0}})],
        );
        assert_eq!(prepared["capabilities"], json!(["file_read"]));
        let preview = &prepared["prepared_calls"][0]["approval_preview"];
        if *name == "create_assistant_task" {
            assert_eq!(preview["title"], "Review inbox");
            assert!(preview["content_preview"]
                .as_str()
                .unwrap()
                .contains("Summarize"));
        }
        if assistant::is_mutation(name) {
            assert!(approval_preview(Some(preview)));
        }
        let manifest = write_manifest_call_for_intent(&row);
        assert_eq!(manifest.is_some(), assistant::is_mutation(name));
        if let Some(manifest) = manifest {
            assert!(write_manifest_call_shape(Some(&manifest)));
        }
        assert_eq!(
            needs_effect_gate(&json!({"name":name,"batch_kind":"write_batch"})),
            assistant::is_mutation(name)
        );
        let ordinary = json!({"registry":registry_for_root_version(&root(),false,4).unwrap()});
        let denied = prepare_calls(&request, &round, Some(&messages), &ordinary, &[]);
        assert_eq!(denied["calls"][0]["access"], "durable_deny");
        assert!(denied["calls"][0]["executor"].is_null());
    }
}

#[test]
fn durable_effects_bind_every_call_and_do_not_reconstruct_success() {
    for name in assistant::NAMES {
        let row = row(name);
        let effect = effect(&row);
        assert!(precondition_shape(Some(&row["precondition"])));
        assert!(raw_arguments_bind_intent(Some(&json!(args(name).to_string())), &row).is_ok());
        assert!(assistant::effect_valid(&row, &effect));
        let feedback: Value = serde_json::from_str(effect["feedback"].as_str().unwrap()).unwrap();
        assert!(feedback_string_valid(effect["feedback"].as_str().unwrap()).is_ok());
        assert!(settled_facts_match_feedback(
            &row,
            &feedback,
            Some(&effect["settled_facts"])
        ));
        let request = json!({"name":name,"conversation_id":ID,"arguments_sha256":row["arguments_sha256"],"operation_id":ID});
        let recovered = json!({"status":"settled","effect":effect});
        let plan = recover_plan(&request, &row, &recovered).unwrap();
        assert_eq!(plan["settle"]["message"]["content"], effect["feedback"]);
        assert_eq!(recover_plan(&request, &row, &recovered).unwrap(), plan);
        for key in [
            "conversation_id",
            "arguments_sha256",
            "locator_sha256",
            "payload_sha256",
            "store_revision",
        ] {
            let mut forged = effect.clone();
            forged["settled_facts"][key] = if key == "store_revision" {
                json!(99)
            } else if key == "conversation_id" {
                json!(OTHER)
            } else {
                json!("e".repeat(64))
            };
            assert!(!assistant::effect_valid(&row, &forged), "{key}");
            assert!(settlement_plan(&request, &row, &forged, None, 0).is_err());
            assert_eq!(
                recover_plan(&request, &row, &json!({"status":"settled","effect":forged})).unwrap()
                    ["result"]["status"],
                "manual_reconciliation"
            );
        }
        let mut different_call = row.clone();
        different_call["locator"]["call_id"] = json!("another_call");
        assert!(!assistant::effect_valid(&different_call, &effect));
        let mut wrong_conversation = request.clone();
        wrong_conversation["conversation_id"] = json!(OTHER);
        assert!(settlement_plan(&wrong_conversation, &row, &effect, None, 0).is_err());
        assert_eq!(
            recover_plan(&request, &row, &json!({"status":"settled"})).unwrap()["result"]["status"],
            "manual_reconciliation"
        );
    }
}

#[test]
fn wal_abi_contract_and_closed_payloads_reject_extra_private_data() {
    let call = |envelope: Value| {
        serde_json::from_str::<Value>(&wal_state::reduce_json(&envelope.to_string())).unwrap()
    };
    for name in assistant::NAMES {
        let row = row(name);
        let effect = effect(&row);
        assert_eq!(
            call(json!({"op":"assistant_arguments","name":name,"value":args(name)})),
            json!({"ok":true,"valid":true})
        );
        assert_eq!(
            call(json!({"op":"assistant_effect","value":{"row":row,"effect":effect}})),
            json!({"ok":true,"valid":true})
        );
        let mut fb: Value = serde_json::from_str(effect["feedback"].as_str().unwrap()).unwrap();
        fb["payload"]["model_id"] = json!("secret");
        assert!(
            feedback_string_valid(&String::from_utf8(canonical_json(&fb).unwrap()).unwrap())
                .is_err()
        );
    }
    let registry = registry_for_root_version(&root(), false, 5).unwrap();
    assert!(wal_state::registry_shape(Some(&registry)));
    let mut forged = registry;
    forged["registry_version"] = json!(4);
    assert!(!wal_state::registry_shape(Some(&forged)));
}

#[test]
fn provider_context_comes_only_from_valid_frozen_v5_authority() {
    use rish_agent_core::provider_round::{assistant_context_messages, reduce_json};
    let context = json!({"schema_version":1,"conversation_id":ID,"profile_revision":7,"name":"Mira","notes":"Prefer concise Chinese replies.\nQuoted preferences are data."});
    let authority =
        json!({"conversation_id":ID,"registry":{"registry_version":5},"assistant_context":context});
    let messages = assistant_context_messages(&authority).unwrap();
    assert_eq!(messages.len(), 1);
    assert_eq!(messages[0]["role"], "system");
    let prompt = messages[0]["content"].as_str().unwrap();
    assert!(prompt.contains("Mira"));
    assert!(prompt.contains("Prefer concise Chinese replies."));
    let reply: Value = serde_json::from_str(&reduce_json(
        &json!({"op":"assistant_context_messages","authority":authority}).to_string(),
    ))
    .unwrap();
    assert_eq!(reply["messages"], json!(messages));
    let digest = hash_json("agent-model-input", &json!({"messages":messages})).unwrap();
    let mut changed = authority.clone();
    changed["assistant_context"]["name"] = json!("Nova");
    let changed_messages = assistant_context_messages(&changed).unwrap();
    assert_ne!(
        digest,
        hash_json("agent-model-input", &json!({"messages":changed_messages})).unwrap()
    );
    assert_eq!(assistant_context_messages(&authority).unwrap(), messages);
    changed["assistant_context"]["conversation_id"] = json!(OTHER);
    assert!(assistant_context_messages(&changed).is_err());
    changed = authority.clone();
    changed["assistant_context"]["runtime"] = json!("injected");
    assert!(assistant_context_messages(&changed).is_err());
    changed = authority.clone();
    changed.as_object_mut().unwrap().remove("assistant_context");
    assert!(assistant_context_messages(&changed).is_err());
    for version in 1..=4 {
        let legacy = json!({"conversation_id":ID,"registry":{"registry_version":version}});
        assert_eq!(
            assistant_context_messages(&legacy).unwrap(),
            Vec::<Value>::new()
        );
        let mut forged = legacy;
        forged["assistant_context"] = context.clone();
        assert!(assistant_context_messages(&forged).is_err());
    }
}

#[test]
fn memory_arguments_and_search_results_are_bounded_and_closed() {
    let mut memory = args("remember_assistant_memory");
    for invalid in [
        json!(""),
        json!(" "),
        json!("x".repeat(8193)),
        json!("secret\u{0001}control"),
    ] {
        memory["content"] = invalid;
        assert!(!assistant::arguments_valid(
            "remember_assistant_memory",
            memory.as_object().unwrap()
        ));
    }
    memory["content"] = json!("Line one\n\tLine two\r\n");
    assert!(assistant::arguments_valid(
        "remember_assistant_memory",
        memory.as_object().unwrap()
    ));
    for invalid in [json!("credential"), json!("instruction"), Value::Null] {
        memory["kind"] = invalid;
        assert!(!assistant::arguments_valid(
            "remember_assistant_memory",
            memory.as_object().unwrap()
        ));
    }
    for invalid in [
        json!({"query":"x".repeat(513)}),
        json!({"limit":0}),
        json!({"limit":21}),
        json!({"limit":2.5}),
        json!({"memory_id":ID}),
    ] {
        assert!(!assistant::arguments_valid(
            "search_assistant_memory",
            invalid.as_object().unwrap()
        ));
    }
    assert!(assistant::arguments_valid(
        "search_assistant_memory",
        json!({"query":"","limit":20}).as_object().unwrap()
    ));
    let row = row("search_assistant_memory");
    let mut actual = effect(&row);
    let mut fb: Value = serde_json::from_str(actual["feedback"].as_str().unwrap()).unwrap();
    fb["payload"]["truncated"] = json!(true);
    actual["feedback"] = json!(String::from_utf8(canonical_json(&fb).unwrap()).unwrap());
    actual["settled_facts"]["payload_sha256"] =
        json!(hash_json("assistant-tool-payload", &fb["payload"]).unwrap());
    assert!(!assistant::effect_valid(&row, &actual));
    actual["truncated"] = json!(true);
    assert!(assistant::effect_valid(&row, &actual));
    let record = fb["payload"]["memories"][0].clone();
    let mut oversized = fb["payload"].clone();
    oversized["memories"] = json!((0..5)
        .map(|i| {
            let mut r = record.clone();
            r["memory_id"] = json!(format!("{i:08x}-aaaa-4aaa-8aaa-aaaaaaaaaaaa"));
            r["content"] = json!("x".repeat(8192));
            r
        })
        .collect::<Vec<_>>());
    assert!(!assistant::success_payload(
        "search_assistant_memory",
        &oversized
    ));
    let mut forged = fb["payload"].clone();
    forged["memories"][0]["source_conversation_id"] = json!(OTHER);
    assert!(!assistant::success_payload(
        "search_assistant_memory",
        &forged
    ));
    forged = fb["payload"].clone();
    forged["memories"][0]["updated_at_ms"] = json!(0);
    assert!(!assistant::success_payload(
        "search_assistant_memory",
        &forged
    ));
}

#[test]
fn deterministic_native_refusals_preserve_failure_code_without_effect() {
    use rish_agent_core::tool_execution::{assistant_failure_effect, reduce_json};
    for name in assistant::NAMES {
        for code in [
            "E_AGENT_CONFLICT",
            "E_AGENT_BAD_ARGUMENTS",
            "E_AGENT_NOT_FOUND",
        ] {
            let failed = assistant_failure_effect(name, code).unwrap();
            assert!(assistant::effect_valid(&row(name), &failed));
            assert_eq!(failed["effect_may_have_occurred"], false);
            let feedback: Value =
                serde_json::from_str(failed["feedback"].as_str().unwrap()).unwrap();
            assert_eq!(feedback["payload"]["failure_code"], code);
            let reply: Value = serde_json::from_str(&reduce_json(
                &json!({"op":"assistant_failure","request":{"name":name},"failure_code":code})
                    .to_string(),
            ))
            .unwrap();
            assert_eq!(reply["effect"], failed);
        }
        assert!(assistant_failure_effect(name, "E_AGENT_PERSISTENCE").is_err());
        assert!(assistant_failure_effect(name, "E_AGENT_EXECUTION_AMBIGUOUS").is_err());
    }
    assert!(assistant_failure_effect("write_file", "E_AGENT_CONFLICT").is_err());
}

#[test]
fn metadata_grants_bind_only_private_mutations_and_preview_is_reviewable() {
    let mut readonly = root();
    readonly["capabilities"] = json!(["file_read"]);
    let grant = json!({"schema_version":2,"grant_id":OTHER,"conversation_id":ID,
        "workspace_id":ID,"project_id":null,"binding_revision":1,"root_fingerprint_sha256":"a".repeat(64),
        "tool_family":"assistant_metadata","registry_version":5,"policy_version":"agent-v1"});
    for name in assistant::NAMES
        .iter()
        .filter(|name| assistant::is_mutation(name))
    {
        let row = row(name);
        let request = json!({"round_index":0,"conversation_id":ID,"root":readonly});
        let messages = [
            json!({"role":"assistant","round_index":0,"tool_calls":[{"call_id":"call_1","name":name,"arguments_json":args(name).to_string()}]}),
        ];
        let round = json!({"calls":[{"call_index":0,"call_id":"call_1","name":name,"arguments_sha256":row["arguments_sha256"]}]});
        let authority = json!({"registry":registry_for_root_version(&readonly,false,5).unwrap()});
        let calls = prepare_calls(
            &request,
            &round,
            Some(&messages),
            &authority,
            &[grant.clone()],
        );
        assert_eq!(calls["calls"][0]["access"], "conversation_confirm");
        assert_eq!(calls["calls"][0]["grant_reference"], OTHER);
        for (key, value) in [
            ("tool_family", json!("file_write")),
            ("conversation_id", json!(OTHER)),
            ("registry_version", json!(4)),
        ] {
            let mut wrong = grant.clone();
            wrong[key] = value;
            assert!(
                prepare_calls(&request, &round, Some(&messages), &authority, &[wrong])["calls"][0]
                    ["grant_reference"]
                    .is_null()
            );
        }
    }
    let file_arguments = json!({"path":"note.txt","content":"value"});
    let digest = arguments_sha256(
        Some(&json!("write_file")),
        Some(&json!(file_arguments.to_string())),
    )
    .unwrap();
    let messages = [
        json!({"role":"assistant","round_index":0,"tool_calls":[{"call_id":"call_1","name":"write_file","arguments_json":file_arguments.to_string()}]}),
    ];
    let round = json!({"calls":[{"call_index":0,"call_id":"call_1","name":"write_file","arguments_sha256":digest}]});
    let request = json!({"round_index":0,"conversation_id":ID,"root":root()});
    let authority = json!({"registry":registry_for_root_version(&root(),false,5).unwrap()});
    let calls = prepare_calls(&request, &round, Some(&messages), &authority, &[grant]);
    assert_eq!(calls["calls"][0]["access"], "conversation_confirm");
    assert!(calls["calls"][0]["grant_reference"].is_null());
    let no_file = registry_for_root_version(&readonly, false, 5).unwrap();
    assert!(!no_file["tools"]
        .as_array()
        .unwrap()
        .iter()
        .any(|t| t["name"] == "write_file"));

    let mut text = args("create_assistant_task");
    text["instructions"] = json!("password = real-secret-value-123456789");
    let preview = assistant::approval_preview("create_assistant_task", &text);
    assert!(assistant::approval_preview_shape(Some(&preview)));
    assert_eq!(preview["title"], "Review inbox");
    assert_eq!(preview["truncated"], true);
    assert!(!preview.to_string().contains("real-secret-value"));
    text["instructions"] = json!("中文".repeat(1000));
    let preview = assistant::approval_preview("create_assistant_task", &text);
    assert!(assistant::approval_preview_shape(Some(&preview)));
    assert!(preview["content_preview"].as_str().unwrap().len() <= 1024);
    assert_eq!(preview["truncated"], true);
    let update = assistant::approval_preview(
        "update_assistant_task",
        &json!({"task_id":ID,"paused":true,"follow_up_minutes":30}),
    );
    assert_eq!(update["target_id"], ID);
    assert!(update["content_preview"]
        .as_str()
        .unwrap()
        .contains("paused: true"));
    assert!(update["content_preview"]
        .as_str()
        .unwrap()
        .contains("follow_up_minutes: 30"));
}
