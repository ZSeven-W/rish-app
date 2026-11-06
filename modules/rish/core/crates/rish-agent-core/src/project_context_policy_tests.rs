use super::*;

/// Folds the way Foundation would for the ASCII cases these tests use, so a
/// test reads as a path rather than as three parallel strings. Real folding
/// stays with the host; this is only a fixture.
fn folded(component: &str) -> (String, String, String) {
    let lowered = component.to_lowercase();
    let (stem, extension) = match lowered.rfind('.') {
        // Foundation treats a leading dot as part of the name, not as an
        // extension marker, and a trailing dot as no extension.
        Some(index) if index > 0 && index + 1 < lowered.len() => (
            lowered[..index].to_string(),
            lowered[index + 1..].to_string(),
        ),
        _ => (lowered.clone(), String::new()),
    };
    (lowered, extension, stem)
}

struct Owned {
    folded: String,
    extension: String,
    stem: String,
}

fn parts(path: &str) -> (Vec<Owned>, Owned, String) {
    let components: Vec<Owned> = path
        .split('/')
        .map(|component| {
            let (folded, extension, stem) = folded(component);
            Owned {
                folded,
                extension,
                stem,
            }
        })
        .collect();
    let last = path.split('/').next_back().unwrap_or_default();
    let (folded_name, extension, stem) = folded(last);
    let filename = Owned {
        folded: folded_name,
        extension: extension.clone(),
        stem,
    };
    (components, filename, extension)
}

fn decide(path: &str) -> Decision {
    let normalized = normalize(path);
    let (components, filename, extension) = parts(&normalized);
    let borrowed: Vec<Folded> = components
        .iter()
        .map(|c| Folded {
            folded: &c.folded,
            extension: &c.extension,
            stem: &c.stem,
        })
        .collect();
    path_decision(
        path,
        &normalized,
        &borrowed,
        &Folded {
            folded: &filename.folded,
            extension: &filename.extension,
            stem: &filename.stem,
        },
        &extension,
    )
}

fn reason(path: &str) -> Option<&'static str> {
    decide(path).omission_reason
}

#[test]
fn ordinary_source_and_prose_are_sent() {
    for path in [
        "src/main.rs",
        "apps/gpui/src/lib.rs",
        "README.md",
        "docs/design.md",
        "LICENSE",
        "Dockerfile",
        "Makefile",
        "Cargo.toml",
        "package.json",
        ".gitignore",
    ] {
        let decision = decide(path);
        assert!(
            decision.eligible,
            "{path} -> {:?}",
            decision.omission_reason
        );
    }
}

/// A secret directory anywhere on the way excludes the file, whatever the file
/// itself is called — this is the clause that keeps `.ssh/README.md` out.
#[test]
fn a_secret_directory_anywhere_on_the_path_excludes_the_file() {
    for path in [
        ".ssh/README.md",
        "a/.aws/config.json",
        "deep/nested/.gnupg/notes.txt",
        "secrets/plan.md",
        "secret/plan.md",
        ".git/config",
        "a/.kube/kubeconfig.yaml",
        "a/.docker/config.json",
        "a/.m2/settings.xml",
    ] {
        assert_eq!(reason(path), Some(REASON_SECRET_PATH), "{path}");
    }
}

#[test]
fn credential_shaped_names_are_secret_however_they_are_spelled() {
    for path in [
        "credentials",
        "a/credential",
        "app/secrets.json",
        "app/credentials.yaml",
        "a/id_rsa",
        "a/id_ed25519",
        "a/id_rsa.pub",
        ".env",
        ".env.local",
        "config/.env.production",
        "certs/server.pem",
        "certs/server.key",
        "signing/app.p12",
        "signing/app.mobileprovision",
    ] {
        assert_eq!(reason(path), Some(REASON_SECRET_PATH), "{path}");
    }
}

#[test]
fn case_does_not_hide_a_secret() {
    for path in [
        "A/.SSH/config",
        "SECRETS/plan.md",
        "certs/SERVER.PEM",
        ".ENV",
    ] {
        assert_eq!(reason(path), Some(REASON_SECRET_PATH), "{path}");
    }
}

#[test]
fn generated_output_is_omitted_as_generated_not_as_a_secret() {
    for path in [
        "node_modules/left-pad/index.js",
        "build/app.js",
        "dist/main.css",
        "target/debug/notes.txt",
        "a/.gradle/state.md",
        "coverage/report.html",
        "tmp/scratch.md",
    ] {
        assert_eq!(reason(path), Some(REASON_GENERATED), "{path}");
    }
}

/// The reason reported is the first one met walking the path from the root,
/// not the most serious one on it. `node_modules/.ssh/id_rsa` is omitted as
/// generated even though a secret directory sits below — the file is excluded
/// either way, and the reason names where the walk stopped. Within a single
/// component, secret is checked before generated.
#[test]
fn the_reason_is_the_first_one_met_walking_the_path() {
    assert_eq!(reason("node_modules/.ssh/id_rsa"), Some(REASON_GENERATED));
    assert_eq!(reason(".ssh/node_modules/a.md"), Some(REASON_SECRET_PATH));
    // `.env` is both a sensitive directory name and a generated-looking one;
    // sensitive wins because it is tested first.
    assert_eq!(reason(".env/notes.md"), Some(REASON_SECRET_PATH));
}

#[test]
fn lockfiles_and_build_products_have_their_own_reasons() {
    for path in [
        "package-lock.json",
        "yarn.lock",
        "Cargo.lock",
        "pnpm-lock.yaml",
        "uv.lock",
        "bun.lockb",
    ] {
        assert_eq!(reason(path), Some(REASON_LOCKFILE), "{path}");
    }
    for path in [
        "a/app.png",
        "a/archive.zip",
        "a/lib.dylib",
        "a/app.min.js",
        "a/main.bundle.js",
        "a/main.bundle.css",
        "a/main.js.map",
    ] {
        assert_eq!(reason(path), Some(REASON_BINARY), "{path}");
    }
}

#[test]
fn an_unrecognised_kind_is_omitted_by_policy_rather_than_guessed_at() {
    for path in ["a/notes.unknownext", "a/binaryblob", "a/data.xyz"] {
        assert_eq!(reason(path), Some(REASON_POLICY), "{path}");
    }
}

/// Everything that is not a path inside this project is refused before any
/// table is consulted.
#[test]
fn a_path_that_leaves_the_project_is_refused_by_structure() {
    for path in [
        "",
        "/etc/passwd",
        "~/notes.md",
        "C:/Users/a.md",
        "C:\\Users\\a.md",
        "a\\b.md",
        "../outside.md",
        "a/../b.md",
        "a//b.md",
        "./a.md",
        "a/./b.md",
    ] {
        assert_eq!(reason(path), Some(REASON_POLICY), "{path}");
    }
    // A control or format scalar is not a filename.
    assert_eq!(reason("a/b\u{0}.md"), Some(REASON_POLICY));
    assert_eq!(reason("a/b\u{200b}.md"), Some(REASON_POLICY));
    assert_eq!(reason("a/b\u{202e}.md"), Some(REASON_POLICY));
}

#[test]
fn the_depth_and_length_bounds_hold() {
    let deep: String = std::iter::repeat_n("d", MAX_DEPTH)
        .collect::<Vec<_>>()
        .join("/")
        + "/a.md";
    assert_eq!(reason(&deep), Some(REASON_POLICY), "past the depth bound");
    let shallow: String = std::iter::repeat_n("d", MAX_DEPTH - 1)
        .collect::<Vec<_>>()
        .join("/")
        + "/a.md";
    assert!(decide(&shallow).eligible, "at the depth bound");
    let long = format!("{}.md", "a".repeat(MAX_RELATIVE_PATH_UNITS));
    assert_eq!(reason(&long), Some(REASON_POLICY), "past the length bound");
}

/// The normalized spelling travels with the decision, so a caller records the
/// path the policy actually judged rather than the one it was handed.
#[test]
fn the_decision_carries_the_normalized_path() {
    let decision = decide("a/cafe\u{301}.md");
    assert_eq!(decision.normalized, "a/caf\u{e9}.md");
    assert!(decision.eligible);
    // A refusal before normalization has nothing to report.
    assert_eq!(decide("").normalized, "");
}

#[test]
fn the_reducer_answers_its_ops() {
    let reply: Value = serde_json::from_str(&reduce_json(
        &json!({ "op": "normalize", "path": "cafe\u{301}.md" }).to_string(),
        b"",
    ))
    .expect("reply");
    assert_eq!(reply["normalized"], json!("caf\u{e9}.md"));
    let reply: Value = serde_json::from_str(&reduce_json(
        &json!({
            "op": "path_decision", "path": "a/id_rsa", "normalized": "a/id_rsa",
            "components": [
                { "folded": "a", "extension": "", "stem": "a" },
                { "folded": "id_rsa", "extension": "", "stem": "id_rsa" },
            ],
            "filename": { "folded": "id_rsa", "extension": "", "stem": "id_rsa" },
            "filename_extension": "",
        })
        .to_string(),
        b"",
    ))
    .expect("reply");
    assert_eq!(reply["eligible"], json!(false));
    assert_eq!(reply["omission_reason"], json!(REASON_SECRET_PATH));
    let reply: Value = serde_json::from_str(&reduce_json(
        &json!({ "op": "content_decision" }).to_string(),
        b"hello\n",
    ))
    .expect("reply");
    assert_eq!(reply["eligible"], json!(true));
    assert_eq!(
        serde_json::from_str::<Value>(&reduce_json(&json!({ "op": "teleport" }).to_string(), b""))
            .expect("reply")["ok"],
        json!(false)
    );
}

/// The order is the rule: over budget is refused before the bytes are looked
/// at, a NUL makes it binary before it is decoded, and only then does encoding
/// matter. A file that is all three must report the first.
#[test]
fn content_is_judged_in_a_fixed_order() {
    assert_eq!(content_decision(b"hello\n"), (true, None));
    assert_eq!(content_decision(b""), (true, None));
    assert_eq!(content_decision(b"a\0b"), (false, Some(REASON_BINARY)));
    // Invalid UTF-8 with no NUL.
    assert_eq!(
        content_decision(&[0x66, 0xff, 0x66]),
        (false, Some(REASON_INVALID_ENCODING))
    );
    let mut over = vec![b'a'; MAX_FILE_BYTES + 1];
    assert_eq!(
        content_decision(&over),
        (false, Some(REASON_BUDGET_EXCEEDED))
    );
    // Over budget wins over a NUL and over bad encoding.
    over[0] = 0;
    over[1] = 0xff;
    assert_eq!(
        content_decision(&over),
        (false, Some(REASON_BUDGET_EXCEEDED))
    );
    // At the budget it is judged normally.
    assert_eq!(content_decision(&vec![b'a'; MAX_FILE_BYTES]), (true, None));
    // A NUL wins over bad encoding.
    assert_eq!(
        content_decision(&[0x66, 0xff, 0x00]),
        (false, Some(REASON_BINARY))
    );
}

/// Tab, newline, carriage return and form feed are ordinary text; the other
/// controls make a file binary. The scan walks UTF-16 code units, so a format
/// character outside the BMP arrives as two surrogates and passes — which is
/// what the original did, not an oversight to be tidied up.
#[test]
fn only_four_control_characters_belong_in_text() {
    for allowed in ["a\tb", "a\nb", "a\rb", "a\u{c}b"] {
        assert_eq!(
            content_decision(allowed.as_bytes()),
            (true, None),
            "{allowed:?}"
        );
    }
    for binary in [
        "a\u{1}b",
        "a\u{7f}b",
        "a\u{9f}b",
        "a\u{ad}b",
        "a\u{200b}b",
        "a\u{feff}b",
    ] {
        assert_eq!(
            content_decision(binary.as_bytes()),
            (false, Some(REASON_BINARY)),
            "{binary:?}"
        );
    }
    // U+E0001 LANGUAGE TAG is a format character, but outside the BMP.
    assert_eq!(content_decision("a\u{e0001}b".as_bytes()), (true, None));
    // An ordinary astral character is text.
    assert_eq!(content_decision("a\u{1f600}b".as_bytes()), (true, None));
}
