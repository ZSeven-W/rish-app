//! Versioned shared tool-table identities, including pre-v2 native schemas.
//! Values were independently reproduced from ff3303e, 8698427, 101f570 and
//! the pre-merge v3 iOS table; no frozen native oracle file is changed.
use rish_agent_core::{assistant_tools, canonical::hash_json, runtime_tools, tool_registry::*};
use serde_json::{json, Value};
const V1: &str = "89e677a4e537ca45b7f4ac300cb0ba110d9ca9717e872d522e1b0c2036fc00cb";
const V1_REQUIRED: &str = "6ac56c1bdcf7619b062a4d93eac9886cd68dc352a36cd8573e35ba749edde5b9";
const V1_NULLABLE: &str = "e12ce6ea32bb3f634151a2c886deb5b409362c773893e8a29c27923f578a7098";
const V2: &str = "62e426ffac0cc058b8affcbc8744549eeb91bc9a99923bb1982ec42c47e8a60c";
const V2_GUEST: &str = "bbdeb99de07223175703fb9748e16444f1f89e0b072283d030be9017c2fdebd4";
const V3: &str = "b47dd1ef4105f73053420487a9b668475c59ed5a91d9db966229c94e5d09afb0";
const V3_GUEST: &str = "03b653d7002f9558de63efaa8dd031003c957c77411604629d3e8afcbffbcec1";
fn root(capabilities: Value) -> Value {
    json!({"schema_version":1,"kind":"project","workspace_id":"11111111-1111-4111-8111-111111111111",
        "project_id":"22222222-2222-4222-8222-222222222222","root_fingerprint_sha256":"a".repeat(64),
        "workspace_binding_revision":1,"capabilities":capabilities})
}
fn all_root() -> Value {
    root(json!([
        "file_read",
        "file_write",
        "git_status",
        "git_commit",
        "git_push",
        "guest_service"
    ]))
}
fn reduce(value: Value) -> Value {
    serde_json::from_str(&reduce_json(&value.to_string())).unwrap()
}

#[test]
fn exact_v1_through_v4_hashes_are_preserved() {
    for (version, guest, digest) in [
        (1, false, V1),
        (2, false, V2),
        (2, true, V2_GUEST),
        (3, false, V3),
        (3, true, V3_GUEST),
        (
            4,
            false,
            "6ca3dac1e252b649e009723b05141fa0ef6797b08242cf0d80b05070a3387482",
        ),
        (
            4,
            true,
            "71c368c136f97df524a9e51dd5768fd3d4d677406377e5168a4d7d6786f2c0b1",
        ),
    ] {
        assert_eq!(
            toolset_sha256_for_version(version, guest).as_deref(),
            Some(digest)
        );
        let table = descriptors_for_version(version, guest).unwrap();
        assert_eq!(
            hash_json(
                "agent-toolset",
                &json!({"registry_version":version,"tools":table})
            )
            .as_deref(),
            Some(digest)
        );
        let registry = registry_for_root_version(&all_root(), guest, version).unwrap();
        assert!(registry_shape(&registry, &all_root(), guest));
        assert!(toolset_digest_valid(&json!(digest), version.max(3), guest));
    }
}

#[test]
fn historical_digest_selects_its_original_write_schema_and_access() {
    for (digest, nullable, required) in [
        (V1, false, false),
        (V1_REQUIRED, false, true),
        (V1_NULLABLE, true, true),
        (V2, false, false),
        (V2_GUEST, false, false),
    ] {
        let version = if digest == V2 || digest == V2_GUEST {
            2
        } else {
            1
        };
        let response = reduce(
            json!({"op":"descriptors","registry_version":version,"guest_cgi":true,"toolset_sha256":digest}),
        );
        assert_eq!(response["ok"], true);
        let table = &response["descriptors"];
        assert_eq!(
            hash_json(
                "agent-toolset",
                &json!({"registry_version":version,"tools":table})
            )
            .as_deref(),
            Some(digest)
        );
        assert!(table
            .as_array()
            .unwrap()
            .iter()
            .all(|d| !runtime_tools::is_runtime(d["name"].as_str().unwrap())));
        let descriptor =
            native_descriptor_for_identity("write_file", true, version, Some(&json!(digest)))
                .unwrap();
        assert_eq!(
            descriptor["parameters"]["properties"]["expected_revision"]["type"],
            if nullable {
                json!(["string", "null"])
            } else {
                json!("string")
            }
        );
        assert_eq!(
            descriptor["parameters"]["required"]
                .as_array()
                .unwrap()
                .contains(&json!("expected_revision")),
            required
        );
        let mut registry =
            registry_for_root_version(&all_root(), digest == V2_GUEST, version).unwrap();
        registry["toolset_sha256"] = json!(digest);
        registry["tools"]
            .as_array_mut()
            .unwrap()
            .iter_mut()
            .find(|t| t["name"] == "git_push")
            .unwrap()["access"] = json!("confirm_once");
        assert!(registry_shape(&registry, &all_root(), true));
        assert_eq!(
            descriptor_for_frozen_registry("git_push", &registry, &all_root(), true).unwrap()
                ["access"],
            "confirm_once"
        );
        assert_eq!(
            descriptor_for_frozen_registry("run_program", &registry, &all_root(), true).unwrap()
                ["access"],
            "durable_deny"
        );
    }
}

#[test]
fn android_default_stays_v2_and_ios_must_explicitly_opt_into_v3() {
    let default = reduce(json!({"op":"registry","guest_cgi":false,"root":all_root()}));
    assert_eq!(default["registry"]["registry_version"], 2);
    assert_eq!(default["registry"]["toolset_sha256"], V2);
    assert_eq!(default["registry"]["tools"].as_array().unwrap().len(), 6);
    for name in runtime_tools::NAMES {
        assert_eq!(
            reduce(json!({"op":"descriptor","guest_cgi":false,"name":name,"root":all_root()}))
                ["descriptor"]["access"],
            "durable_deny"
        );
        assert_eq!(
            reduce(json!({"op":"native_descriptor","guest_cgi":false,"name":name}))["ok"],
            false
        );
    }
    let ios =
        reduce(json!({"op":"registry","guest_cgi":true,"registry_version":3,"root":all_root()}));
    assert_eq!(ios["registry"]["toolset_sha256"], V3_GUEST);
    assert_eq!(ios["registry"]["tools"].as_array().unwrap().len(), 13);
    let write = reduce(
        json!({"op":"native_descriptor","registry_version":3,"guest_cgi":true,"name":"write_file"}),
    );
    assert_eq!(
        write["descriptor"]["parameters"]["properties"]["expected_revision"]["type"],
        json!(["string", "null"])
    );
    assert_eq!(runtime_descriptors().len(), 5);
}

#[test]
fn v3_capability_filter_and_closed_projection_are_exact() {
    for (caps, count) in [
        (json!(["file_read"]), 3),
        (json!(["file_write"]), 1),
        (json!(["guest_service"]), 6),
        (
            json!([
                "file_read",
                "file_write",
                "git_status",
                "git_commit",
                "git_push"
            ]),
            7,
        ),
    ] {
        let root = root(caps);
        let registry = registry_for_root_version(&root, true, 3).unwrap();
        assert_eq!(registry["tools"].as_array().unwrap().len(), count);
        assert!(registry_shape(&registry, &root, true));
        let mut subset = registry.clone();
        subset["tools"].as_array_mut().unwrap().pop();
        assert!(!registry_shape(&subset, &root, true));
        let mut fake_summary = registry.clone();
        fake_summary["tools"][0]["safe_summary_key"] = json!("agent.unknown");
        assert!(!registry_shape(&fake_summary, &root, true));
    }
    let registry = registry_for_root_version(&all_root(), true, 3).unwrap();
    for version in [1, 2] {
        let mut forged = registry.clone();
        forged["registry_version"] = json!(version);
        assert!(!registry_shape(&forged, &all_root(), true));
    }
    for (version, digest) in [(1, V3_GUEST), (2, V1), (3, V2_GUEST)] {
        assert_eq!(
            reduce(
                json!({"op":"native_descriptor","registry_version":version,"guest_cgi":true,"toolset_sha256":digest,"name":"write_file"})
            )["ok"],
            false
        );
    }
    for bad in [
        json!({"op":"descriptors","registry_version":true}),
        json!({"op":"descriptors","registry_version":6}),
        json!({"op":"descriptors","guest_cgi":"true"}),
        json!({"op":"descriptors","runtime":true}),
    ] {
        assert_eq!(reduce(bad)["ok"], false);
    }
}

#[test]
fn assistant_tools_require_v5_and_separate_metadata_approval() {
    for guest in [false, true] {
        for version in 1..=4 {
            for name in assistant_tools::NAMES {
                assert_eq!(
                    descriptor_for_tool_version(name, &all_root(), guest, version).unwrap()
                        ["access"],
                    "durable_deny"
                );
                assert!(native_descriptor_for_version(name, guest, version).is_err());
                assert!(!runtime_tools::grant_supports_tool(
                    Some(&json!(version)),
                    name
                ));
            }
        }
        let registry = registry_for_root_version(&all_root(), guest, 5).unwrap();
        assert!(registry_shape(&registry, &all_root(), guest));
        assert_eq!(
            registry["tools"].as_array().unwrap().len(),
            if guest { 20 } else { 18 }
        );
        for name in assistant_tools::NAMES {
            let descriptor =
                descriptor_for_frozen_registry(name, &registry, &all_root(), guest).unwrap();
            let mutation = assistant_tools::is_mutation(name);
            assert_eq!(
                descriptor["access"],
                if mutation {
                    "conversation_confirm"
                } else {
                    "auto"
                }
            );
            assert_eq!(descriptor["safe_summary_key"], format!("agent.{name}"));
            assert_eq!(descriptor.as_object().unwrap().len(), 4);
            assert!(runtime_tools::grant_supports_tool(Some(&json!(5)), name));
            assert_eq!(
                descriptor_for_tool_version(name, &root(json!(["file_read"])), guest, 5).unwrap()
                    ["access"],
                if mutation {
                    "conversation_confirm"
                } else {
                    "auto"
                }
            );
        }
        let mut forged = registry.clone();
        forged["registry_version"] = json!(4);
        assert!(!registry_shape(&forged, &all_root(), guest));
        let mut bypass = registry.clone();
        bypass["tools"]
            .as_array_mut()
            .unwrap()
            .iter_mut()
            .find(|tool| tool["name"] == "create_assistant_task")
            .unwrap()["access"] = json!("auto");
        assert!(!registry_shape(&bypass, &all_root(), guest));
    }
}

#[test]
fn v5_runtime_filtered_identity_keeps_assistant_tools_and_questions() {
    for guest in [false, true] {
        let response = reduce(json!({"op":"registry","root":all_root(),
            "guest_cgi":guest,"registry_version":5,"runtime_tools":false}));
        assert_eq!(response["ok"], true);
        let registry = &response["registry"];
        assert_eq!(
            registry["tools"].as_array().unwrap().len(),
            if guest { 15 } else { 13 }
        );
        assert!(registry_shape(registry, &all_root(), guest));
        for name in assistant_tools::NAMES.iter().copied().chain(["ask_user"]) {
            assert_ne!(
                descriptor_for_frozen_registry(name, registry, &all_root(), guest).unwrap()
                    ["access"],
                "durable_deny"
            );
            assert_eq!(
                reduce(json!({"op":"native_descriptor","name":name,
                "guest_cgi":guest,"registry_version":5,
                "toolset_sha256":registry["toolset_sha256"]}))["ok"],
                true
            );
        }
        for name in runtime_tools::NAMES {
            assert_eq!(
                descriptor_for_frozen_registry(name, registry, &all_root(), guest).unwrap()
                    ["access"],
                "durable_deny"
            );
        }
        let full = registry_for_root_version(&all_root(), guest, 5).unwrap();
        assert_ne!(full["toolset_sha256"], registry["toolset_sha256"]);
        assert_eq!(
            reduce(
                json!({"op":"native_descriptor","name":"create_assistant_task",
            "guest_cgi":guest,"registry_version":4,
            "toolset_sha256":registry["toolset_sha256"]})
            )["ok"],
            false
        );
    }
}

#[test]
fn v5_only_adds_assistant_descriptors_and_safe_summary_names() {
    for guest in [false, true] {
        let mut existing = descriptors_for_version(5, guest).unwrap();
        existing.retain(|tool| !assistant_tools::is_assistant(tool["name"].as_str().unwrap()));
        assert_eq!(existing, descriptors_for_version(4, guest).unwrap());
    }
    for name in assistant_tools::NAMES {
        let summary = json!(format!("agent.{name}"));
        assert!(rish_agent_core::session_schema::agent_summary_matches_name(
            Some(&summary),
            Some(&json!(name))
        ));
        assert!(rish_agent_core::session_schema::agent_summary_matches_name(
            Some(&json!("agent.unknown")),
            Some(&json!(name))
        ));
        assert!(
            !rish_agent_core::session_schema::agent_summary_matches_name(
                Some(&summary),
                Some(&json!("write_file"))
            )
        );
    }
    assert!(!rish_agent_core::session_schema::valid_agent_summary_key(
        Some(&json!("agent.create_assistant_task.secret instructions"))
    ));
}
