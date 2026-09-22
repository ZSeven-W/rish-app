use super::*;

const WORKSPACE_DOMAIN: &str = "dev.zseven.rish.local-workspace-access";
const PROJECT_DOMAIN: &str = "dev.zseven.rish.local-project-access";

/// JavaScript branches on these, so the mapping is contract. Every number the
/// module defines is pinned, not just a sample.
#[test]
fn every_module_failure_maps_to_its_stable_code() {
    for (code, name) in [
        (3003, "E_PROJECT_REQUEST_INVALID"),
        (3101, "E_PROJECT_REQUEST_INVALID"),
        (3104, "E_PROJECT_STORAGE_UNSAFE"),
        (3105, "E_PROJECT_BUSY"),
        (3106, "E_PROJECT_BUSY"),
        (3107, "E_PROJECT_STORAGE_UNSAFE"),
        (3110, "E_PROJECT_CONFLICT"),
        (3111, "E_PROJECT_UNAVAILABLE"),
        (3112, "E_WORKSPACE_CONFIRMATION"),
        (3195, "E_PROJECT_CANCELLED"),
        (3196, "E_PROJECT_NON_FAST_FORWARD"),
        (3180, "E_PROJECT_MERGE_UNSUPPORTED"),
        (3181, "E_PROJECT_RECOVERY_REQUIRED"),
        (3197, "E_PROJECT_CREDENTIAL"),
        (3198, "E_PROJECT_TIMEOUT"),
    ] {
        assert_eq!(stable_error_code("LocalProjects", code), name, "{code}");
    }
    // An unrecognised number is native, not guessed at.
    for code in [0, 1, 3100, 3199, 9999, -1] {
        assert_eq!(
            stable_error_code("LocalProjects", code),
            NATIVE_FAILURE,
            "{code}"
        );
    }
    // An unrecognised domain is native too.
    assert_eq!(stable_error_code("SomethingElse", 3003), NATIVE_FAILURE);
    assert_eq!(stable_error_code("", 1), NATIVE_FAILURE);
}

/// The workspace codes are the workspace rule's. This module re-reports them
/// rather than keeping a second spelling, so the two can never drift.
#[test]
fn workspace_failures_are_reported_with_the_workspace_rules_own_names() {
    for code in [1u64, 2, 6, 9, 13, 14, 17, 18, 19] {
        assert_eq!(
            stable_error_code(WORKSPACE_DOMAIN, code as i64),
            crate::workspace_error::public_code(Some(code)).expect("name"),
            "{code}"
        );
    }
    // A busy picker is busy as far as a project operation cares, which is the
    // one place the two tables deliberately differ.
    assert_eq!(stable_error_code(WORKSPACE_DOMAIN, 4), "E_WORKSPACE_BUSY");
    assert_eq!(
        crate::workspace_error::public_code(Some(4)),
        Some("E_WORKSPACE_PICKER_BUSY")
    );
    // Everything else a project operation cannot say more about.
    for code in [5, 7, 8, 10, 11, 12, 15, 16, 20, 99] {
        assert_eq!(
            stable_error_code(WORKSPACE_DOMAIN, code),
            "E_WORKSPACE_UNAVAILABLE",
            "{code}"
        );
    }
}

#[test]
fn project_access_failures_distinguish_only_three() {
    assert_eq!(
        stable_error_code(PROJECT_DOMAIN, 1),
        "E_PROJECT_REQUEST_INVALID"
    );
    assert_eq!(
        stable_error_code(PROJECT_DOMAIN, 3),
        "E_PROJECT_STORAGE_UNSAFE"
    );
    assert_eq!(stable_error_code(PROJECT_DOMAIN, 6), "E_PROJECT_BUSY");
    for code in [0, 2, 4, 5, 7, 99] {
        assert_eq!(
            stable_error_code(PROJECT_DOMAIN, code),
            "E_PROJECT_UNAVAILABLE",
            "{code}"
        );
    }
}

#[test]
fn an_oid_is_forty_lowercase_hex_characters() {
    assert!(canonical_oid(Some(&json!("a".repeat(40))), false));
    assert!(canonical_oid(
        Some(&json!("0123456789abcdef0123456789abcdef01234567")),
        false
    ));
    for bad in [
        json!("A".repeat(40)),
        json!("a".repeat(39)),
        json!("a".repeat(41)),
        json!("a".repeat(64)),
        json!("g".repeat(40)),
        json!(1),
    ] {
        assert!(!canonical_oid(Some(&bad), false), "{bad}");
    }
    // Null only when the caller allows it.
    assert!(canonical_oid(Some(&Value::Null), true));
    assert!(!canonical_oid(Some(&Value::Null), false));
    assert!(!canonical_oid(None, true));
}

/// An operation id may be the nil UUID, unlike a snapshot id: it is the
/// caller's to choose and nothing reads a sentinel out of it.
#[test]
fn an_operation_id_may_be_the_nil_uuid() {
    let nil = "00000000-0000-0000-0000-000000000000";
    assert!(canonical_operation_id(Some(&json!(nil))));
    assert!(!crate::project_context_store::canonical_snapshot_id(nil));
    assert!(canonical_operation_id(Some(&json!(
        "a1b2c3d4-1111-4111-8111-1111abcd1111"
    ))));
    for bad in [
        json!("A1B2C3D4-1111-4111-8111-1111ABCD1111"),
        json!("a1b2c3d4-1111-4111-8111-1111abcd111"),
        json!("a1b2c3d41111411181111111abcd1111"),
        json!(Value::Null),
        json!(1),
    ] {
        assert!(!canonical_operation_id(Some(&bad)), "{bad}");
    }
    assert!(!canonical_operation_id(None));
}

/// Cutting at the byte bound would split a multi-byte character and produce a
/// string no consumer could read, so the clip backs off to a boundary.
#[test]
fn clipping_never_splits_a_character() {
    assert_eq!(clip_utf8("hello", 16), ("hello".to_string(), false));
    assert_eq!(clip_utf8("hello", 5), ("hello".to_string(), false));
    assert_eq!(clip_utf8("hello", 3), ("hel".to_string(), true));
    // Three bytes each: a bound of 7 keeps two and drops the partial third.
    let wide = "中中中";
    assert_eq!(wide.len(), 9);
    let (clipped, truncated) = clip_utf8(wide, 7);
    assert_eq!(clipped, "中中");
    assert!(truncated);
    assert_eq!(clipped.len(), 6);
    // A bound smaller than the first character yields nothing rather than half
    // of it.
    assert_eq!(clip_utf8(wide, 2), (String::new(), true));
    assert_eq!(clip_utf8(wide, 0), (String::new(), true));
    assert_eq!(clip_utf8("", 0), (String::new(), false));
    // Whatever comes out is still valid UTF-8 — which is the whole point.
    for bound in 0..12 {
        let (clipped, _) = clip_utf8(wide, bound);
        assert!(wide.starts_with(&clipped), "{bound}");
    }
}

#[test]
fn a_bounded_string_is_bounded_and_free_of_control_characters() {
    assert!(bounded_string(Some(&json!("hi")), 4, false));
    assert!(bounded_string(Some(&json!("")), 4, true));
    assert!(!bounded_string(Some(&json!("")), 4, false));
    assert!(!bounded_string(Some(&json!("hello")), 4, false));
    for bad in ["a\u{1}b", "a\nb", "a\u{7f}b", "a\u{200e}b"] {
        assert!(!bounded_string(Some(&json!(bad)), 8, false), "{bad:?}");
    }
    assert!(!bounded_string(Some(&json!(1)), 4, false));
    assert!(!bounded_string(None, 4, false));
}

#[test]
fn the_reducer_answers_every_op_it_claims_to() {
    let run = |value: Value| -> Value {
        serde_json::from_str(&reduce_json(&value.to_string())).expect("reply")
    };
    assert_eq!(
        run(json!({ "op": "stable_error_code", "domain": "LocalProjects", "code": 3110 })),
        json!({ "ok": true, "code": "E_PROJECT_CONFLICT" })
    );
    assert_eq!(
        run(json!({ "op": "canonical_oid", "value": "a".repeat(40) })),
        json!({ "ok": true, "valid": true })
    );
    assert_eq!(
        run(
            json!({ "op": "canonical_operation_id", "value": "a1b2c3d4-1111-4111-8111-1111abcd1111" })
        ),
        json!({ "ok": true, "valid": true })
    );
    assert_eq!(
        run(json!({ "op": "clip_utf8", "value": "中中中", "maximum_bytes": 7 })),
        json!({ "ok": true, "value": "中中", "truncated": true })
    );
    assert_eq!(
        run(json!({ "op": "bounded_string", "value": "hi", "maximum_bytes": 4 })),
        json!({ "ok": true, "valid": true })
    );
    for input in [
        json!({ "op": "unknown" }).to_string(),
        json!({ "op": "stable_error_code", "domain": "LocalProjects" }).to_string(),
        json!({ "op": "clip_utf8", "value": "x" }).to_string(),
        json!({ "op": "bounded_string", "value": "x" }).to_string(),
        "not json".to_string(),
    ] {
        assert_eq!(reduce_json(&input), r#"{"ok":false}"#, "{input}");
    }
}
