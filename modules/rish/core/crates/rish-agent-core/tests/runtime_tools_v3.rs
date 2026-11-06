//! New v3 contracts are independent of the frozen pre-v3 native oracle.
use rish_agent_core::{
    canonical::{canonical_json, hash_json},
    execution_ledger::{
        feedback_string_valid, precondition_shape, raw_arguments_bind_intent,
        settled_facts_match_feedback,
    },
    ledger_ops::write_manifest_call_for_intent,
    provider_round::tool_description,
    runtime_tools,
    schema::arguments_sha256,
    session_schema::Env,
    tool_batch::{prepare_calls, prepare_finish, tool_arguments_accepted},
    wal_state::{authority_shape, registry_shape},
};
use serde_json::{json, Value};
const ID: &str = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";

fn args(name: &str) -> Value {
    match name {
        "list_runtime_environments" => json!({}),
        "install_runtime_environment" => json!({"environment_id":"node-22"}),
        "run_program" => json!({"environment_id":"node-22","entry_path":"src/main.js","args":[]}),
        "start_runtime_service" => {
            json!({"environment_id":"node-22","entry_path":"src/server.js","args":["--port","8080"],"port":8080})
        }
        _ => json!({"service_id":ID}),
    }
}
fn precondition(name: &str) -> Value {
    json!({"schema_version":1,"kind":name,
        "arguments_sha256":arguments_sha256(Some(&json!(name)),Some(&json!(args(name).to_string()))).unwrap(),
        "snapshot_sha256": if matches!(name,"run_program"|"start_runtime_service") {json!("b".repeat(64))} else {Value::Null},
        "environment_sha256":if matches!(name,"list_runtime_environments"|"stop_runtime_service") {Value::Null} else {json!("c".repeat(64))}})
}
fn payload(name: &str) -> Value {
    match name {
        "list_runtime_environments" => {
            json!({"schema_version":1,"environments":[{"environment_id":"node-22","family":"node","version":"22","installed":false,"available":true,"package_bytes":42}],"truncated":false})
        }
        "install_runtime_environment" => {
            json!({"schema_version":1,"environment_id":"node-22","status":"installed"})
        }
        "run_program" => {
            json!({"schema_version":1,"environment_id":"node-22","exit_code":0,"stdout":"actual output\n","stderr":"","truncated":false})
        }
        "start_runtime_service" => {
            json!({"schema_version":1,"environment_id":"node-22","status":"running","service_id":ID,"url":"http://127.0.0.1:8080/"})
        }
        _ => json!({"schema_version":1,"status":"stopped","service_id":ID}),
    }
}
fn feedback(name: &str, outcome: &str, payload: Value) -> Value {
    json!({"schema_version":1,"name":name,"outcome":outcome,"payload":payload})
}
fn valid_feedback(value: &Value) -> bool {
    feedback_string_valid(&String::from_utf8(canonical_json(value).unwrap()).unwrap()).is_ok()
}
fn registry(version: u64, names: &[&str]) -> Value {
    let mut names = names.to_vec();
    names.sort();
    json!({"schema_version":2,"registry_version":version,"toolset_sha256":"d".repeat(64),"tools":names.into_iter().map(|name|json!({"schema_version":2,"name":name,"safe_summary_key":format!("agent.{name}"),"access":if matches!(name,"list_dir"|"read_file"|"list_runtime_environments"|"git_status") {"auto"} else {"conversation_confirm"}})).collect::<Vec<_>>()})
}
const OLD: &[&str] = &[
    "list_dir",
    "read_file",
    "write_file",
    "git_status",
    "git_commit",
    "git_push",
    "start_guest_cgi",
    "stop_guest_cgi",
];

#[test]
fn registry_is_additive_bounded_and_versioned() {
    for version in [1, 2] {
        assert!(registry_shape(Some(&registry(version, OLD))));
    }
    let mut names = OLD.to_vec();
    names.extend(runtime_tools::NAMES);
    let current = registry(3, &names);
    assert!(registry_shape(Some(&current)));
    let mut duplicate = current.clone();
    duplicate["tools"]
        .as_array_mut()
        .unwrap()
        .push(current["tools"][0].clone());
    assert!(!registry_shape(Some(&duplicate)));
    for version in [1, 2, 6] {
        let mut wrong = current.clone();
        wrong["registry_version"] = json!(version);
        assert!(!registry_shape(Some(&wrong)));
    }
    for name in runtime_tools::NAMES {
        assert!(tool_description(name).unwrap().len() <= 1024);
        assert!(!runtime_tools::grant_supports_tool(Some(&json!(2)), name));
        assert!(runtime_tools::grant_supports_tool(Some(&json!(3)), name));
    }
    assert!(!tool_description("start_guest_cgi")
        .unwrap()
        .contains("servers and arbitrary long-running processes are unsupported"));
}

#[test]
fn live_arguments_reject_injection_shapes_and_enforce_native_bounds() {
    for name in runtime_tools::NAMES {
        let input = args(name);
        assert!(tool_arguments_accepted(Some(&json!(name)), input.as_object().unwrap()).is_ok());
        let mut extra = input;
        extra["shell"] = json!("echo bad");
        assert!(!runtime_tools::arguments_valid(
            name,
            extra.as_object().unwrap()
        ));
    }
    let mut input = args("run_program");
    for path in [
        "/workspace/app.js",
        "a/../app.js",
        "a//b",
        "a/./b",
        "a\\b",
        "a\0b",
    ] {
        input["entry_path"] = json!(path);
        assert!(
            !runtime_tools::arguments_valid("run_program", input.as_object().unwrap()),
            "{path:?}"
        );
    }
    input = args("run_program");
    input["args"] = json!(["$(literal)", "a;b", "two words"]);
    assert!(runtime_tools::arguments_valid(
        "run_program",
        input.as_object().unwrap()
    ));
    for invalid in [
        json!(["a\0b"]),
        json!(vec![""; 65]),
        json!(["字".repeat(1366)]),
        json!(vec!["x".repeat(4096); 17]),
    ] {
        input["args"] = invalid;
        assert!(!runtime_tools::arguments_valid(
            "run_program",
            input.as_object().unwrap()
        ));
    }
    input = args("start_runtime_service");
    for invalid in [json!(1023), json!(65536), json!(8080.5), json!(true)] {
        input["port"] = invalid;
        assert!(!runtime_tools::arguments_valid(
            "start_runtime_service",
            input.as_object().unwrap()
        ));
    }
    input = args("install_runtime_environment");
    for invalid in ["Node-22", "https://host/image", "", "custom_env"] {
        input["environment_id"] = json!(invalid);
        assert!(!runtime_tools::arguments_valid(
            "install_runtime_environment",
            input.as_object().unwrap()
        ));
    }
}

#[test]
fn precondition_and_actual_payload_hashes_bind_every_runtime_tool() {
    for name in runtime_tools::NAMES {
        let pre = precondition(name);
        assert!(precondition_shape(Some(&pre)));
        let row =
            json!({"name":name,"arguments_sha256":pre["arguments_sha256"],"precondition":pre});
        assert!(raw_arguments_bind_intent(Some(&json!(args(name).to_string())), &row).is_ok());
        let protected = feedback(name, "ok", payload(name));
        assert!(valid_feedback(&protected));
        let facts = json!({"schema_version":1,"kind":name,"arguments_sha256":pre["arguments_sha256"],"payload_sha256":hash_json("runtime-tool-payload", &protected["payload"]).unwrap()});
        assert!(settled_facts_match_feedback(&row, &protected, Some(&facts)));
        let mut changed = protected.clone();
        changed["payload"]["schema_version"] = json!(2);
        assert!(!settled_facts_match_feedback(&row, &changed, Some(&facts)));
        let mut changed = facts.clone();
        changed["arguments_sha256"] = json!("e".repeat(64));
        assert!(!settled_facts_match_feedback(
            &row,
            &protected,
            Some(&changed)
        ));
        let mut changed = row.clone();
        changed["precondition"]["arguments_sha256"] = json!("e".repeat(64));
        assert!(raw_arguments_bind_intent(Some(&json!(args(name).to_string())), &changed).is_err());
        assert_eq!(
            write_manifest_call_for_intent(&row).is_some(),
            runtime_tools::is_mutation(name)
        );
    }
    let mut no_snapshot = precondition("run_program");
    no_snapshot["snapshot_sha256"] = Value::Null;
    assert!(!precondition_shape(Some(&no_snapshot)));
    let mut no_environment = precondition("install_runtime_environment");
    no_environment["environment_sha256"] = Value::Null;
    assert!(!precondition_shape(Some(&no_environment)));
}

#[test]
fn protected_feedback_preserves_actual_diagnostics_with_exact_limits() {
    let failure = json!({"schema_version":1,"failure_code":"E_AGENT_TOOL_FAILED","reason":"program_exited_nonzero","stdout":"真实输出\n","stderr":"SyntaxError\n","truncated":false,"exit_code":1});
    for name in ["run_program", "start_runtime_service"] {
        assert!(valid_feedback(&feedback(name, "failed", failure.clone())));
    }
    assert!(!valid_feedback(&feedback(
        "install_runtime_environment",
        "failed",
        failure.clone()
    )));
    let mut oversized = failure.clone();
    oversized["stderr"] = json!("x".repeat(8193));
    assert!(!valid_feedback(&feedback(
        "run_program",
        "failed",
        oversized
    )));
    let mut escaped = failure;
    escaped["stdout"] = json!("\u{0001}".repeat(16384));
    assert!(!valid_feedback(&feedback("run_program", "failed", escaped)));
    let mut dishonest = payload("run_program");
    dishonest["exit_code"] = json!(1);
    assert!(!valid_feedback(&feedback("run_program", "ok", dishonest)));
    for url in [
        "http://localhost:8080/",
        "http://127.0.0.1:80/",
        "http://127.0.0.1:08080/",
        "http://127.0.0.1:8080/path",
    ] {
        let mut p = payload("start_runtime_service");
        p["url"] = json!(url);
        assert!(!valid_feedback(&feedback("start_runtime_service", "ok", p)));
    }
    let mut list = payload("list_runtime_environments");
    list["environments"][0]["installed"] = json!(1);
    assert!(!valid_feedback(&feedback(
        "list_runtime_environments",
        "ok",
        list
    )));
}

#[test]
fn native_runtime_routes_and_missing_environment_are_repairable_feedback() {
    for name in runtime_tools::NAMES {
        let digest = precondition(name)["arguments_sha256"].clone();
        let call = json!({"call_index":0,"call_id":"c","name":name,"arguments_sha256":digest});
        let round = json!({"calls":[call]});
        let request = json!({"round_index":0});
        let messages = vec![
            json!({"role":"assistant","round_index":0,"tool_calls":[{"call_id":"c","name":name,"arguments_json":args(name).to_string()}]}),
        ];
        let authority = json!({"registry":registry(3,&[name])});
        let calls = prepare_calls(&request, &round, Some(&messages), &authority, &[]);
        assert_eq!(calls["calls"][0]["executor"], "runtime");
        assert_eq!(calls["mutation_batch"], runtime_tools::is_mutation(name));
        let finish = prepare_finish(
            &request,
            calls["calls"].as_array().unwrap(),
            &[json!({"prepared":{"precondition":precondition(name),"reserved_write_bytes":0}})],
        );
        assert_eq!(
            finish["capabilities"],
            json!([if name == &"list_runtime_environments" {
                "file_read"
            } else {
                "guest_service"
            }])
        );
        let missing = prepare_finish(
            &request,
            calls["calls"].as_array().unwrap(),
            &[
                json!({"rejection":{"failure_code":"E_AGENT_CAPABILITY","reason":"install_environment_before_running"}}),
            ],
        );
        assert!(missing.get("reject").is_none());
        assert_eq!(
            missing["prepared_calls"][0]["rejection"]["reason"],
            "install_environment_before_running"
        );
        assert!(missing["prepared_calls"][0]["precondition"].is_null());
    }
}

#[test]
fn v3_authority_requires_capability_implied_tools_and_preserves_v2() {
    let time = "2026-09-15T00:00:00.000Z";
    let mut authority = json!({"schema_version":2,"task_id":ID,"conversation_id":ID,"attempt_id":ID,
      "root":{"schema_version":1,"kind":"workspace","workspace_id":ID,"workspace_binding_revision":1,"project_id":null,"root_fingerprint_sha256":"a".repeat(64),"capabilities":["file_read","guest_service"]},
      "policy":{"schema_version":1,"policy_version":"agent-v1","max_single_write_bytes":32768,"max_batch_write_bytes":524288,"max_attempt_write_bytes":4194304},
      "registry":registry(2,&["list_dir","read_file","start_guest_cgi","stop_guest_cgi"]),"transport_schema_version":2,"model":"test-model","thinking_mode":"off","visible_message_ids":[],"visible_history_sha256":"a".repeat(64),"visible_message_count":0,"project_context_sha256":null,
      "transcript":{"schema_version":1,"transcript_ref":ID,"generation":0,"transcript_sha256":"a".repeat(64),"transcript_bytes":2},
      "reserved_write_bytes":0,"authority_revision":1,"state":"prepared","cleanup_id":null,"created_at":time,"updated_at":time});
    let env = Env {
        supported_models: vec!["test-model".into()],
        ..Default::default()
    };
    assert!(authority_shape(&authority, &env));
    authority["registry"]["registry_version"] = json!(3);
    assert!(!authority_shape(&authority, &env));
    let mut names = vec!["list_dir", "read_file", "start_guest_cgi", "stop_guest_cgi"];
    names.extend(runtime_tools::NAMES);
    authority["registry"] = registry(3, &names);
    assert!(authority_shape(&authority, &env));
    authority["root"]["capabilities"] = json!(["file_read"]);
    assert!(!authority_shape(&authority, &env));
}

#[test]
fn existing_wal_c_abi_exposes_runtime_contract_decisions() {
    let call = |envelope: Value| {
        serde_json::from_str::<Value>(&rish_agent_core::wal_state::reduce_json(
            &envelope.to_string(),
        ))
        .unwrap()
    };
    for name in runtime_tools::NAMES {
        assert_eq!(
            call(json!({"op":"runtime_arguments","name":name,"value":args(name)})),
            json!({"ok":true,"valid":true,"failure_code":null,"reason":null})
        );
        assert_eq!(
            call(json!({"op":"runtime_precondition","value":precondition(name)})),
            json!({"ok":true,"valid":true})
        );
        let fb = String::from_utf8(canonical_json(&feedback(name, "ok", payload(name))).unwrap())
            .unwrap();
        assert_eq!(
            call(json!({"op":"runtime_feedback","value":fb})),
            json!({"ok":true,"valid":true})
        );
    }
    assert_eq!(
        call(json!({"op":"runtime_arguments","name":"run_program","value":{"shell":"bad"}})),
        json!({"ok":true,"valid":false,"failure_code":"E_AGENT_BAD_ARGUMENTS","reason":"arguments_do_not_match_tool_schema"})
    );
    assert_eq!(
        call(json!({"op":"runtime_facts","value":{}})),
        json!({"ok":true,"valid":false})
    );
}

#[test]
fn runtime_recovery_reuses_protected_receipts_and_refuses_reconstructed_success() {
    use rish_agent_core::tool_execution::recover_plan;
    for name in runtime_tools::NAMES {
        let pre = precondition(name);
        let row = json!({"name":name,"arguments_sha256":pre["arguments_sha256"],"precondition":pre,"state":"running","row_revision":3});
        let request =
            json!({"name":name,"arguments_sha256":pre["arguments_sha256"],"operation_id":ID});
        let protected = feedback(name, "ok", payload(name));
        let effect = json!({"schema_version":1,"status":"ok","feedback":String::from_utf8(canonical_json(&protected).unwrap()).unwrap(),"settled_facts":{"schema_version":1,"kind":name,"arguments_sha256":pre["arguments_sha256"],"payload_sha256":hash_json("runtime-tool-payload",&protected["payload"]).unwrap()},"truncated":false,"effect_may_have_occurred":true});
        let mut recovered = json!({"schema_version":1,"status":"settled","effect":effect});
        let plan = recover_plan(&request, &row, &recovered).unwrap();
        assert_eq!(plan["settle"]["patch"]["state"], "settled");
        assert_eq!(plan["settle"]["message"]["content"], effect["feedback"]);
        recovered["effect"]["settled_facts"]["payload_sha256"] = json!("e".repeat(64));
        assert_eq!(
            recover_plan(&request, &row, &recovered).unwrap()["result"]["status"],
            "manual_reconciliation"
        );
        assert_eq!(
            recover_plan(
                &request,
                &row,
                &json!({"schema_version":1,"status":"ambiguous"})
            )
            .unwrap()["result"]["status"],
            "ambiguous"
        );
        assert_eq!(
            recover_plan(
                &request,
                &row,
                &json!({"schema_version":1,"status":"settled"})
            )
            .unwrap()["result"]["status"],
            "manual_reconciliation"
        );
    }
}
