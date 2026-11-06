use super::*;
use serde_json::json;

const KERNEL: &str = "1e6bf9027720c75c3ed0d79171f21b5791ee40ca9795d07c7c6e04dc5ea2ae90";

fn manifest() -> Value {
    json!({
        "schema_version": 1,
        "environment_id": "python-3-13",
        "family": "python",
        "display_name": "Python 3.13",
        "version": "3.13.1",
        "architecture": "x86_64",
        "kernel_sha256": KERNEL,
        "disk_sha256": "0".repeat(64),
        "disk_bytes": 64 * 1024 * 1024u64,
        "minimum_memory_mib": 512,
    })
}

fn with(key: &str, value: Value) -> Value {
    let mut map = manifest();
    map[key] = value;
    map
}

fn ok(value: &Value) -> bool {
    validate_manifest(Some(value), KERNEL)
}

#[test]
fn it_accepts_a_whole_manifest() {
    assert!(ok(&manifest()));
}

#[test]
fn every_field_is_load_bearing() {
    // Each of these is the one difference from an accepted manifest, so a
    // check that stopped being made would show up here and nowhere else.
    assert!(!ok(&with("schema_version", json!(2))));
    assert!(!ok(&with("environment_id", json!("Python"))));
    assert!(!ok(&with("family", json!("perl"))));
    assert!(!ok(&with("display_name", json!(""))));
    assert!(!ok(&with("version", json!(""))));
    assert!(!ok(&with("architecture", json!("arm64"))));
    assert!(!ok(&with("kernel_sha256", json!("0".repeat(64)))));
    assert!(!ok(&with("disk_sha256", json!("nothex"))));
    assert!(!ok(&with("disk_bytes", json!(1024))));
    assert!(!ok(&with("minimum_memory_mib", json!(128))));
}

#[test]
fn the_key_set_is_exact() {
    let mut extra = manifest();
    extra["extra"] = json!(1);
    assert!(!ok(&extra));

    let mut missing = manifest();
    missing.as_object_mut().unwrap().remove("version");
    assert!(!ok(&missing));
}

/// Foundation reads these bounds through `doubleValue` and asks
/// `floor(n) == n`, so a manifest written with a trailing `.0` is accepted.
/// `schema::safe_integer` would refuse it, which is why this module does not
/// use it. Deleting `integral_in_range`'s float arm turns this red.
#[test]
fn an_integral_float_is_an_integer_here() {
    assert!(ok(&with("disk_bytes", json!(67_108_864.0))));
    assert!(ok(&with("minimum_memory_mib", json!(512.0))));
    assert!(ok(&with("schema_version", json!(1.0))));
    // Still a number, still bounded, still whole.
    assert!(!ok(&with("minimum_memory_mib", json!(512.5))));
    assert!(!ok(&with("minimum_memory_mib", json!(-512.0))));
}

/// A boolean is not a number. serde keeps `true` out of `Value::Number`
/// entirely, so the CFBoolean guard the ObjC needs has nothing to do here --
/// but the behaviour still has to hold.
#[test]
fn a_boolean_is_not_a_size() {
    assert!(!ok(&with("schema_version", json!(true))));
    assert!(!ok(&with("disk_bytes", json!(true))));
}

/// The disk is addressed in 512-byte sectors.
#[test]
fn a_disk_length_must_be_whole_sectors() {
    assert!(ok(&with("disk_bytes", json!(1024 * 1024))));
    assert!(!ok(&with("disk_bytes", json!(1024 * 1024 + 1))));
    assert!(!ok(&with("disk_bytes", json!(1024 * 1024 + 256))));
}

#[test]
fn sizes_are_bounded_at_both_ends() {
    assert!(ok(&with("disk_bytes", json!(1024 * 1024))));
    assert!(!ok(&with("disk_bytes", json!(1024 * 1024 - 512))));
    assert!(ok(&with("disk_bytes", json!(4u64 * 1024 * 1024 * 1024))));
    assert!(!ok(&with(
        "disk_bytes",
        json!(4u64 * 1024 * 1024 * 1024 + 512)
    )));
    assert!(ok(&with("minimum_memory_mib", json!(256))));
    assert!(ok(&with("minimum_memory_mib", json!(1024))));
    assert!(!ok(&with("minimum_memory_mib", json!(255))));
    assert!(!ok(&with("minimum_memory_mib", json!(1025))));
}

#[test]
fn every_family_the_catalog_ships_is_accepted() {
    for family in FAMILIES {
        assert!(ok(&with("family", json!(family))), "{family}");
    }
    assert_eq!(FAMILIES.len(), 6);
}

#[test]
fn an_environment_id_is_anchored() {
    for good in ["a", "0", "python-3-13", "x", &"a".repeat(96)] {
        assert!(valid_environment_id(Some(&json!(good))), "{good}");
    }
    for bad in [
        "",             // empty
        "-python",      // a leading dash is the anchored rule's whole point
        "-",            //
        "Python",       // upper case
        "py_thon",      // underscore
        "py thon",      // space
        "py.thon",      // dot
        "python\u{e9}", // outside ASCII
    ] {
        assert!(!valid_environment_id(Some(&json!(bad))), "{bad:?}");
    }
    assert!(!valid_environment_id(Some(&json!("a".repeat(97)))));
    assert!(!valid_environment_id(Some(&json!(1))));
    assert!(!valid_environment_id(None));
}

/// The program side is looser, and this pins the difference rather than
/// hiding it. If the two rules are ever unified on purpose, this test is where
/// that decision becomes visible.
#[test]
fn the_program_side_accepts_ids_the_catalog_never_could() {
    for loose in ["-python", "-", "---", "-0"] {
        assert!(valid_program_environment_id(Some(&json!(loose))), "{loose}");
        assert!(
            !valid_environment_id(Some(&json!(loose))),
            "{loose} must stay refused by the anchored rule"
        );
    }
    // Where they agree, they agree.
    for shared in ["python-3-13", "a", "0"] {
        assert!(valid_program_environment_id(Some(&json!(shared))));
        assert!(valid_environment_id(Some(&json!(shared))));
    }
    for bad in ["", "Python", "py_thon"] {
        assert!(!valid_program_environment_id(Some(&json!(bad))), "{bad:?}");
    }
}

/// `Text()` bounds `NSString.length`, which counts UTF-16 code units. Bounding
/// UTF-8 bytes instead would refuse a name the app accepts today: swap
/// `encode_utf16().count()` for `len()` and this goes red.
#[test]
fn display_text_is_bounded_in_utf16_units_not_bytes() {
    // 80 CJK characters: 80 UTF-16 units, 240 UTF-8 bytes.
    let cjk = "\u{4e2d}".repeat(80);
    assert_eq!(cjk.encode_utf16().count(), 80);
    assert_eq!(cjk.len(), 240);
    assert!(ok(&with("display_name", json!(cjk))));
    assert!(!ok(&with("display_name", json!("\u{4e2d}".repeat(81)))));

    // An astral character is two units, so forty of them fill eighty.
    let astral = "\u{1f600}".repeat(40);
    assert_eq!(astral.encode_utf16().count(), 80);
    assert!(ok(&with("display_name", json!(astral))));
    assert!(!ok(&with("display_name", json!("\u{1f600}".repeat(41)))));
}

/// `controlCharacterSet` is Cc **and** Cf. Rust's `is_control` is Cc alone, so
/// a format character has to be refused explicitly.
#[test]
fn display_text_refuses_control_and_format_characters() {
    assert!(!ok(&with("display_name", json!("Python\u{1}3"))));
    assert!(!ok(&with("display_name", json!("Python\n3"))));
    // Cf, which is_control does not cover.
    assert!(!ok(&with("display_name", json!("Python\u{200b}3"))));
    assert!(!ok(&with("display_name", json!("Python\u{feff}3"))));
    assert!(!ok(&with("display_name", json!("Python\u{ad}3"))));
    // A plain name with punctuation and spaces is fine.
    assert!(ok(&with("display_name", json!("Python 3.13 (stable)"))));
}

/// Foundation tests one `unichar` at a time, so a format character outside the
/// BMP arrives as two surrogates and neither is a member: the string passes.
/// Scanning scalars would refuse it. This is a loophole, reproduced on purpose.
#[test]
fn a_format_character_outside_the_bmp_passes_as_it_does_on_ios() {
    // U+1D173 MUSICAL SYMBOL BEGIN BEAM is Cf, and outside the BMP.
    let astral_format = "Py\u{1d173}thon";
    assert!(path_control_or_format('\u{1d173}'), "still Cf as a scalar");
    assert!(ok(&with("display_name", json!(astral_format))));
}

#[test]
fn a_workspace_id_is_a_canonical_uuid() {
    assert!(valid_workspace_id(Some(&json!(
        "3f2504e0-4f89-41d3-9a0c-0305e82c3301"
    ))));
    assert!(!valid_workspace_id(Some(&json!(
        "3F2504E0-4F89-41D3-9A0C-0305E82C3301"
    ))));
    assert!(!valid_workspace_id(Some(&json!("not-a-uuid"))));
    assert!(!valid_workspace_id(None));
}

fn url(text: &str) -> Value {
    json!({
        "text": text, "parsed": true, "scheme": "https", "host": "example.com",
        "has_user": false, "has_password": false, "has_fragment": false,
    })
}

#[test]
fn an_https_url_needs_every_part_to_agree() {
    assert!(valid_https_url(Some(&url("https://example.com/a.img"))));

    let mut http = url("http://example.com/a.img");
    http["scheme"] = json!("http");
    assert!(!valid_https_url(Some(&http)));

    for key in ["has_user", "has_password", "has_fragment"] {
        let mut bad = url("https://example.com/a.img");
        bad[key] = json!(true);
        assert!(!valid_https_url(Some(&bad)), "{key}");
    }

    let mut unparsed = url("https://example.com/a.img");
    unparsed["parsed"] = json!(false);
    assert!(!valid_https_url(Some(&unparsed)));

    // An absent host and an empty host are both refused.
    for host in [json!(null), json!("")] {
        let mut bad = url("https://example.com/a.img");
        bad["host"] = host.clone();
        assert!(!valid_https_url(Some(&bad)), "{host}");
    }
}

/// The string is bounded and scanned before anything is parsed, so these
/// refusals never depended on the host's parser.
#[test]
fn a_url_is_refused_on_its_own_bytes_first() {
    let long = format!("https://example.com/{}", "a".repeat(4096));
    assert!(!valid_https_url(Some(&url(&long))));
    assert!(!valid_https_url(Some(&url("https://example.com/\u{1}"))));
    assert!(!valid_https_url(Some(&url("https://example.com/\u{200b}"))));
}

#[test]
fn the_url_projection_shape_is_exact() {
    let mut extra = url("https://example.com/a.img");
    extra["port"] = json!(443);
    assert!(!valid_https_url(Some(&extra)));

    let mut missing = url("https://example.com/a.img");
    missing.as_object_mut().unwrap().remove("has_fragment");
    assert!(!valid_https_url(Some(&missing)));
}

#[test]
fn the_envelope_answers_each_operation() {
    let reply =
        reduce_json(&json!({"op": "valid_environment_id", "value": "python-3-13"}).to_string());
    assert_eq!(reply, json!({"ok": true, "valid": true}).to_string());

    let reply = reduce_json(
        &json!({"op": "validate_manifest", "value": manifest(), "kernel_sha256": KERNEL})
            .to_string(),
    );
    assert_eq!(reply, json!({"ok": true, "valid": true}).to_string());

    // A manifest pinned to a different kernel is not this build's manifest.
    let reply = reduce_json(
        &json!({"op": "validate_manifest", "value": manifest(), "kernel_sha256": "0".repeat(64)})
            .to_string(),
    );
    assert_eq!(reply, json!({"ok": true, "valid": false}).to_string());
}

#[test]
fn an_unusable_envelope_fails_closed() {
    for bad in [
        r#"{"op":"unknown"}"#,
        r#"{"value":"x"}"#,
        r#"{"op":"validate_manifest","value":{}}"#, // no kernel_sha256
        r#"[]"#,
        r#"not json"#,
        r#""#,
    ] {
        assert_eq!(
            reduce_json(bad),
            json!({"ok": false}).to_string(),
            "{bad:?}"
        );
    }
}
