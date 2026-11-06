use super::*;

fn reply(input: Value) -> Value {
    serde_json::from_str(&reduce_json(&input.to_string())).unwrap()
}

#[test]
fn shared_native_remote_policy_fixture() {
    let fixture: Value =
        serde_json::from_str(include_str!("../../../fixtures/git-remote-policy.json")).unwrap();
    for case in fixture["cases"].as_array().unwrap() {
        let got = reply(json!({"url": case["url"]}));
        let expected = if case["value"].is_null() {
            json!({"ok": false, "error": "E_PROJECT_INVALID"})
        } else {
            json!({"ok": true, "value": case["value"]})
        };
        assert_eq!(got, expected, "fixture {}", case["id"]);
    }
}

#[test]
fn request_is_strict_and_never_echoes_invalid_values() {
    for input in ["", "null", "[]", "{}", "{\"url\":null}", "{\"url\":17}",
        "{\"url\":\"https://example.com/repo.git\",\"token\":\"secret\"}",
        "{\"url\":\"https://example.com/repo.git\",\"url\":\"https://example.com/other.git\"}",
        "{\"url\":\"https://example.com/repo.git\",\"\\u0075rl\":\"https://example.com/other.git\"}",
        "{\"url\":\"https://secret@example.com/repo.git\"}"] {
        assert_eq!(reduce_json(input), "{\"error\":\"E_PROJECT_INVALID\",\"ok\":false}");
    }
}

#[test]
fn bounds_cover_url_path_host_and_username() {
    assert_eq!(
        reply(json!({"url": format!("https://example.com/{}", "x".repeat(2047))}))["ok"],
        true
    );
    for input in [
        format!("https://example.com/{}", "x".repeat(2048)),
        format!("ssh://{}@example.com/r.git", "x".repeat(256)),
        format!("https://{}.com/r.git", "x".repeat(64)),
        format!("https://{}.com/r.git", vec!["x".repeat(63); 4].join(".")),
        format!("https://example.com/{}", "%61".repeat(2047)),
        format!("https://example.com/{}", "😀".repeat(1024)),
    ] {
        assert_eq!(reply(json!({"url": input}))["ok"], false);
    }
    assert_eq!(
        reply(json!({"url": format!("ssh://{}@example.com/r.git", "x".repeat(255))}))["ok"],
        true
    );
    assert_eq!(
        reduce_json(&" ".repeat(32 * 1024 + 1)),
        "{\"error\":\"E_PROJECT_INVALID\",\"ok\":false}"
    );
}

#[test]
fn invalid_control_and_format_characters_are_rejected_before_native_io() {
    for character in [
        '\0', '\n', '\r', '\u{7f}', '\u{85}', '\u{ad}', '\u{200b}', '\u{202e}',
    ] {
        assert_eq!(
            reply(json!({"url": format!("https://example.com/a{character}.git")}))["ok"],
            false
        );
    }
}

#[test]
fn canonical_http_output_is_idempotent_without_losing_origin_spelling() {
    for origin in [
        "HTTPS://GitHub.com:443/Org/repo%2egit",
        "http://[FD00::1]:8000/repo.git",
        "https://example.com:00443/repo%20name.git",
        "https://example.com/中文.git",
        "HTTPS://EXAMPLE.COM:443/%e4%b8%ad文%2egit",
    ] {
        let first = reply(json!({"url": origin}));
        assert_eq!(first["ok"], true);
        let second = reply(json!({"url": first["value"]["url"]}));
        assert_eq!(first, second);
    }
}

#[test]
fn scp_origin_and_canonical_identity_remain_distinct() {
    let scp = reply(json!({"url": "git@GitHub.COM:Org/repo.git"}));
    let url = reply(json!({"url": "ssh://git@github.com/Org/repo.git"}));
    assert_eq!(scp["value"]["url"], "git@GitHub.COM:Org/repo.git");
    assert_ne!(scp["value"]["url"], url["value"]["url"]);
    assert_eq!(scp["value"]["canonical_url"], url["value"]["canonical_url"]);
}

#[test]
fn form_boundary_is_explicit_and_does_not_change_persisted_origin_rules() {
    let url = "\u{2003}\nHTTPS://GitHub.com/Org/repo.git\t ";
    assert_eq!(reply(json!({"url": url}))["ok"], false);
    assert_eq!(
        reply(json!({"url": url, "form": true}))["value"]["url"],
        "https://github.com/Org/repo.git"
    );
    for form in [json!(false), json!(null), json!(1), json!("true")] {
        assert_eq!(
            reply(json!({"url": "https://example.com/x.git", "form": form}))["ok"],
            false
        );
    }
    let prefix = "https://example.com/";
    let at_limit = format!("{prefix}{}", "x".repeat(2048 - prefix.len()));
    assert_eq!(reply(json!({"url": at_limit, "form": true}))["ok"], true);
    let over = at_limit + "x";
    assert_eq!(reply(json!({"url": over, "form": true}))["ok"], false);
    assert_eq!(reply(json!({"url": over}))["ok"], true);
    let unicode = format!("{prefix}{}", "中".repeat(700));
    assert_eq!(reply(json!({"url": unicode, "form": true}))["ok"], false);
    assert_eq!(reply(json!({"url": unicode}))["ok"], false);
}

#[test]
fn canonical_output_must_fit_the_persisted_origin_limit() {
    // This fits the form's raw UTF-8 budget, but percent encoding would make
    // an origin that cannot subsequently be read by the transport validator.
    let raw = format!("https://example.com/{}.git", "中".repeat(600));
    assert!(raw.len() <= 2048);
    for form in [true, false] {
        let request = if form {
            json!({"url": raw, "form": true})
        } else {
            json!({"url": raw})
        };
        let normalized = reply(request);
        if let Some(url) = normalized["value"]["url"].as_str() {
            let replay = reply(json!({"url": url}));
            eprintln!(
                "form={form} raw_bytes={} canonical_units={} replay_ok={}",
                raw.len(),
                url.encode_utf16().count(),
                replay["ok"]
            );
            assert_eq!(
                replay["ok"], true,
                "accepted origin must survive transport validation"
            );
        }
        assert_eq!(
            normalized["ok"], false,
            "reject an over-budget canonical origin before saving"
        );
    }
}

#[test]
fn maximum_encoded_form_output_roundtrips_and_the_next_byte_is_refused() {
    for prefix in ["https://example.com/", "http://[::1]:8418/"] {
        for (raw_char, escaped) in [("中", "%E4%B8%AD"), ("😀", "%F0%9F%98%80"), ("|", "%7C")] {
            let budget = MAX_URL_UNITS - prefix.len();
            let count = budget / escaped.len();
            let tail = "a".repeat(budget % escaped.len());
            let raw = format!("{prefix}{}{tail}", raw_char.repeat(count));
            let canonical = format!("{prefix}{}{tail}", escaped.repeat(count));
            assert!(
                raw.len() <= 2048,
                "fixture must fit the existing form limit"
            );
            assert_eq!(canonical.len(), 4096);
            let from_form = reply(json!({"url": raw, "form": true}));
            assert_eq!(from_form["ok"], true);
            assert_eq!(from_form["value"]["url"], canonical);
            assert_eq!(from_form, reply(json!({"url": from_form["value"]["url"]})));
            let too_long = raw + "a";
            assert_eq!(reply(json!({"url": too_long, "form": true}))["ok"], false);
            assert_eq!(reply(json!({"url": too_long}))["ok"], false);
        }
    }
}
