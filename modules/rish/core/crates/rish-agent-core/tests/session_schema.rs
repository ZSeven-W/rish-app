//! Parity with the Objective-C++ SessionSnapshotStore validators.
//! `session-golden.json` was written by `AgentCoreGoldenTests.mm` from
//! `session-corpus.json` while the native validators still existed; this test
//! expands the corpus with the same deterministic mutation walk and compares
//! every answer (candidate acceptance and digest, lenient digest, legacy root,
//! envelope, tombstones) with the frozen oracle.

use rish_agent_core::canonical::canonical_json;
use rish_agent_core::session_schema::{
    candidate_digest, env_from_json, legacy_root_bytes, validate_candidate, validate_envelope,
    validate_tombstones, Env, Envelope,
};
use serde_json::{Map, Value};
use std::cmp::Ordering;
use std::path::PathBuf;

fn fixture(name: &str) -> Value {
    let path: PathBuf = [env!("CARGO_MANIFEST_DIR"), "..", "..", "fixtures", name]
        .iter()
        .collect();
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("read {}: {error}", path.display()));
    serde_json::from_str(&text).unwrap_or_else(|error| panic!("parse {}: {error}", path.display()))
}

fn hex_to_bytes(hex: &str) -> Vec<u8> {
    (0..hex.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).expect("hex"))
        .collect()
}

#[derive(Clone, Debug)]
enum Step {
    Key(String),
    Index(usize),
}

fn utf16_order(a: &str, b: &str) -> Ordering {
    a.encode_utf16().cmp(b.encode_utf16())
}

fn collect_paths(node: &Value, path: &[Step], paths: &mut Vec<Vec<Step>>) {
    match node {
        Value::Object(map) => {
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort_by(|a, b| utf16_order(a, b));
            for key in keys {
                let mut child = path.to_vec();
                child.push(Step::Key(key.clone()));
                paths.push(child.clone());
                collect_paths(&map[key], &child, paths);
            }
        }
        Value::Array(items) => {
            for (index, item) in items.iter().enumerate() {
                let mut child = path.to_vec();
                child.push(Step::Index(index));
                paths.push(child.clone());
                collect_paths(item, &child, paths);
            }
        }
        _ => {}
    }
}

/// op: remove | null | string | zero | empty_array | set
fn apply(root: &mut Value, path: &[Step], op: &str, value: Option<&Value>) -> bool {
    let Some((last, parents)) = path.split_last() else {
        return false;
    };
    let mut parent = root;
    for step in parents {
        parent = match (parent, step) {
            (Value::Object(map), Step::Key(key)) => match map.get_mut(key) {
                Some(child) => child,
                None => return false,
            },
            (Value::Array(items), Step::Index(index)) => match items.get_mut(*index) {
                Some(child) => child,
                None => return false,
            },
            _ => return false,
        };
    }
    let replacement = match op {
        "remove" => None,
        "null" => Some(Value::Null),
        "string" => Some(Value::from("x")),
        "zero" => Some(Value::from(0)),
        "empty_array" => Some(Value::Array(Vec::new())),
        "set" => Some(value.cloned().unwrap_or(Value::Null)),
        _ => return false,
    };
    match (parent, last) {
        (Value::Object(map), Step::Key(key)) => {
            match replacement {
                Some(value) => {
                    map.insert(key.clone(), value);
                }
                None => {
                    map.remove(key);
                }
            }
            true
        }
        (Value::Array(items), Step::Index(index)) if *index < items.len() => {
            match replacement {
                Some(value) => items[*index] = value,
                None => {
                    items.remove(*index);
                }
            }
            true
        }
        _ => false,
    }
}

fn steps(path: &Value) -> Vec<Step> {
    path.as_array()
        .expect("path array")
        .iter()
        .map(|step| match step {
            Value::String(key) => Step::Key(key.clone()),
            other => Step::Index(other.as_u64().expect("index") as usize),
        })
        .collect()
}

fn lenient_tree(bytes: &[u8]) -> Option<Value> {
    let value: Value = serde_json::from_slice(bytes).ok()?;
    value.is_object().then_some(value)
}

fn case_bytes(item: &Map<String, Value>, section: &[Value]) -> Vec<u8> {
    if let Some(hex) = item.get("bytes_hex").and_then(Value::as_str) {
        return hex_to_bytes(hex);
    }
    if let Some(text) = item.get("text").and_then(Value::as_str) {
        return text.as_bytes().to_vec();
    }
    let base_name = item["base"].as_str().expect("base");
    let base = section
        .iter()
        .find(|candidate| candidate["name"].as_str() == Some(base_name))
        .unwrap_or_else(|| panic!("unknown base {base_name}"));
    let mut tree = lenient_tree(&case_bytes(base.as_object().expect("case"), section))
        .unwrap_or_else(|| panic!("base {base_name} does not parse"));
    for edit in item["edits"].as_array().expect("edits") {
        assert!(
            apply(
                &mut tree,
                &steps(&edit["path"]),
                edit["op"].as_str().expect("op"),
                edit.get("value")
            ),
            "{} edit failed",
            item["name"]
        );
    }
    canonical_json(&tree).expect("canonical")
}

const OPS: &[&str] = &["remove", "null", "string", "zero", "empty_array"];

/// "!" in the golden records an Objective-C exception: the native validator
/// crashed on that input (a provider binding whose endpoint_url is not a
/// string reaches `[NSURL URLWithString:]`). The shared core must refuse such
/// input instead; every other answer must match exactly.
fn matches(got: &str, expected: Option<&str>) -> bool {
    match expected {
        Some("!") => got == "-" || got == "0" || got.starts_with("-|"),
        Some(expected) => got == expected,
        None => false,
    }
}

/// Documented divergences of the golden's own oracle harness, keyed by
/// `section/name` with the answer the shared core must give instead.
/// `lexical-bom`: the harness fed `+candidateDigestForSessionJSON:` an
/// NSString decoded from the bytes, and that decoding drops the leading
/// U+FEFF, so the ObjC lenient digest saw no BOM. The production path hands
/// the core the caller's exact UTF-8 bytes, where a BOM is refused.
const DIVERGENCES: &[(&str, &str)] = &[("candidates/lexical-bom", "-|-")];

fn compare_section(
    corpus: &Value,
    golden: &Value,
    section: &str,
    oracle: &dyn Fn(&[u8], &Env) -> String,
    mutation_oracle: &dyn Fn(&[u8], &Env) -> String,
    mismatches: &mut Vec<String>,
) {
    let cases = corpus[section].as_array().expect("section");
    let expected = golden[section].as_object().expect("golden section");
    assert_eq!(
        cases.len(),
        expected.len(),
        "{section}: case count differs from the golden"
    );
    for case in cases {
        let item = case.as_object().expect("case");
        let name = item["name"].as_str().expect("name");
        let entry = expected
            .get(name)
            .unwrap_or_else(|| panic!("{section}/{name} missing from the frozen golden (it cannot be regenerated; add new cases as a separate fixture)"));
        let env = env_from_json(entry.get("env"));
        let bytes = case_bytes(item, cases);
        let got = oracle(&bytes, &env);
        let divergence = DIVERGENCES
            .iter()
            .find(|(key, _)| *key == format!("{section}/{name}"))
            .map(|(_, answer)| *answer);
        if let Some(answer) = divergence {
            if got != answer {
                mismatches.push(format!(
                    "{section}/{name}: divergence got {got} want {answer}"
                ));
            }
        } else if !matches(&got, entry["base"].as_str()) {
            mismatches.push(format!(
                "{section}/{name}: base got {got} want {}",
                entry["base"]
            ));
        }
        if item.get("mutate") != Some(&Value::Bool(true)) {
            continue;
        }
        let tree = lenient_tree(&bytes).unwrap_or_else(|| panic!("{section}/{name} must parse"));
        let mut paths = Vec::new();
        collect_paths(&tree, &[], &mut paths);
        let cap = item.get("cap").and_then(Value::as_u64).unwrap_or(0) as usize;
        let kept: Vec<Vec<Step>> = if cap > 0 && paths.len() > cap {
            (0..cap)
                .map(|i| paths[(i * paths.len()) / cap].clone())
                .collect()
        } else {
            paths
        };
        let expected_mutations = entry["mutations"].as_array().expect("mutations");
        assert_eq!(
            expected_mutations.len(),
            kept.len() * OPS.len(),
            "{section}/{name}: mutation count differs from the golden"
        );
        let mut index = 0;
        for path in &kept {
            for op in OPS {
                let mut mutated = tree.clone();
                assert!(
                    apply(&mut mutated, path, op, None),
                    "{section}/{name}: mutation failed"
                );
                let got = match canonical_json(&mutated) {
                    Ok(input) => mutation_oracle(&input, &env),
                    Err(_) => "-".to_string(),
                };
                // The frozen ObjC schema required a preselected model. The
                // shared schema-9 contract now explicitly permits an unset
                // default/provider preference; conversations and execution
                // records retain their model checks. Keep the old oracle
                // file frozen and isolate exactly these two null mutations.
                let unconfigured_preference = section == "candidates"
                    && tree["schema_version"] == 9
                    && *op == "null"
                    && matches!(path.as_slice(), [Step::Key(parent), Step::Key(field)]
                        if parent == "preferences" && matches!(field.as_str(), "default_model" | "selected_harness_id"))
                    && expected_mutations[index] == "-"
                    && entry["base"]
                        .as_str()
                        .is_some_and(|base| !base.starts_with('-'));
                let expanded = unconfigured_preference.then(|| {
                    candidate_digest(&canonical_json(&mutated).expect("valid mutation JSON"))
                        .expect("unconfigured preference still has a valid digest")
                });
                let expected = expanded
                    .as_deref()
                    .or_else(|| expected_mutations[index].as_str());
                if !matches(&got, expected) {
                    mismatches.push(format!(
                        "{section}/{name}: mutation #{index} {path:?} {op} got {got} want {}",
                        expected_mutations[index]
                    ));
                }
                index += 1;
            }
        }
    }
}

#[test]
fn session_validators_match_the_objc_engine() {
    let corpus = fixture("session-corpus.json");
    let golden = fixture("session-golden.json");
    let mut mismatches = Vec::new();
    let strict = |bytes: &[u8], env: &Env| {
        validate_candidate(bytes, env)
            .map(|c| c.digest)
            .unwrap_or_else(|_| "-".into())
    };
    let candidate = |bytes: &[u8], env: &Env| {
        let lenient = candidate_digest(bytes).unwrap_or_else(|| "-".into());
        format!("{}|{lenient}", strict(bytes, env))
    };
    let legacy = |bytes: &[u8], env: &Env| {
        if legacy_root_bytes(bytes, env) {
            "1".to_string()
        } else {
            "0".to_string()
        }
    };
    let envelope = |bytes: &[u8], env: &Env| match validate_envelope(bytes, env) {
        Ok(Envelope::Legacy {
            writer_launch_instance_id,
            legacy_bytes_sha256,
        }) => format!("2|{writer_launch_instance_id}|{legacy_bytes_sha256}"),
        Ok(Envelope::Current {
            writer_launch_instance_id,
            generation,
            session_sha256,
            recent_commits,
        }) => {
            let first = recent_commits
                .first()
                .and_then(|c| c["operation_id"].as_str())
                .unwrap_or_default();
            format!(
                "3|{writer_launch_instance_id}|{generation}|{session_sha256}|{}|{first}",
                recent_commits.len()
            )
        }
        Err(_) => "-".into(),
    };
    let tombstones = |bytes: &[u8], _: &Env| match validate_tombstones(bytes) {
        Some((generation, mut ids)) => {
            ids.sort_by(|a, b| utf16_order(a, b));
            format!("{generation}|{}", ids.join(","))
        }
        None => "-".into(),
    };
    compare_section(
        &corpus,
        &golden,
        "candidates",
        &candidate,
        &strict,
        &mut mismatches,
    );
    compare_section(
        &corpus,
        &golden,
        "legacy_roots",
        &legacy,
        &legacy,
        &mut mismatches,
    );
    compare_section(
        &corpus,
        &golden,
        "envelopes",
        &envelope,
        &envelope,
        &mut mismatches,
    );
    compare_section(
        &corpus,
        &golden,
        "tombstones",
        &tombstones,
        &tombstones,
        &mut mismatches,
    );
    assert!(
        mismatches.is_empty(),
        "{} divergences from the ObjC oracle; first ones:\n{}",
        mismatches.len(),
        mismatches
            .iter()
            .take(60)
            .cloned()
            .collect::<Vec<_>>()
            .join("\n")
    );
}

#[test]
fn tombstones_preserve_input_order_and_reject_nonadjacent_duplicates() {
    let ids = [
        "ffffffff-ffff-4fff-8fff-ffffffffffff",
        "11111111-1111-4111-8111-111111111111",
        "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    ];
    let raw = serde_json::to_vec(&serde_json::json!({
        "schema_version": 1, "generation": 7, "operation_ids": ids,
    }))
    .unwrap();
    assert_eq!(
        validate_tombstones(&raw),
        Some((7, ids.iter().map(|id| (*id).to_owned()).collect()))
    );
    let duplicate = serde_json::to_vec(&serde_json::json!({
        "schema_version": 1, "generation": 7, "operation_ids": [ids[0], ids[1], ids[2], ids[0]],
    }))
    .unwrap();
    assert!(validate_tombstones(&duplicate).is_none());
}
