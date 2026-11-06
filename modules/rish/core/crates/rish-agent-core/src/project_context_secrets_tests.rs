use super::*;
use serde_json::Value;

/// The recorded decisions, from the same file the hosts' tests read.
fn fixture() -> Value {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../ios/Tests/Fixtures/project-secret-decisions.json"
    );
    let text = std::fs::read_to_string(path).expect("the secret fixture is beside the iOS tests");
    serde_json::from_str(&text).expect("the fixture is JSON")
}

/// Every frozen text is decided the way the shipped host decided it. A case
/// still `PENDING` prints what this port decided, so the two can be compared
/// before the fixture is filled in; it does not pass.
#[test]
fn every_frozen_text_is_decided_the_same_way() {
    let recorded = fixture();
    assert_eq!(recorded["schema_version"], 1);
    let mut pending = 0;
    let mut mismatches = Vec::new();
    for case in recorded["cases"].as_array().expect("cases") {
        let name = case["name"].as_str().expect("name");
        let text = case["text"].as_str().expect("text");
        let suspected = suspected_secret(text.as_bytes());
        let actual = serde_json::json!({
            "suspected_secret": suspected,
            "omission_reason": if suspected { Some(REASON_SUSPECTED_SECRET) } else { None },
        });
        if case["decision"] == "PENDING" {
            pending += 1;
            println!(
                "RECORD {}",
                serde_json::json!({ "name": name, "decision": actual })
            );
            continue;
        }
        if case["decision"] != actual {
            mismatches.push(format!(
                "{name}: expected {} got {actual}",
                case["decision"]
            ));
        }
    }
    assert!(mismatches.is_empty(), "{}", mismatches.join("\n"));
    assert_eq!(
        pending, 0,
        "{pending} cases are still PENDING; record them from the shipped host"
    );
}

/// The scan reads no further than the file budget: a key entirely past it is
/// not seen, and a character cut in two at the edge is trimmed rather than
/// making the text undecodable.
#[test]
fn the_scan_stops_at_the_file_budget_and_trims_a_split_character() {
    let mut beyond = vec![0u8; MAX_SCAN_BYTES];
    beyond.extend_from_slice(b"-----BEGIN PRIVATE KEY-----");
    assert!(!suspected_secret(&beyond));

    let head = b"-----BEGIN PRIVATE KEY-----\n";
    let mut split = head.to_vec();
    split.extend(std::iter::repeat(b'a').take(MAX_SCAN_BYTES - head.len() - 1));
    split.extend_from_slice("é".as_bytes());
    assert_eq!(split.len(), MAX_SCAN_BYTES + 1);
    assert!(suspected_secret(&split));

    // Undecodable within the budget, and not because of the cut: not scanned.
    assert!(!suspected_secret(&[
        0xff, 0xfe, b'p', b'a', b's', b's', b'w', b'o', b'r', b'd', b'=', b'x'
    ]));
}

/// The adversarial inputs the iOS tests time: they must decide "no" and
/// finish, which is the linear-progress property in the form a test can hold.
#[test]
fn adversarial_maximum_inputs_decide_no_and_finish() {
    let malformed = "<password".repeat(7281);
    assert_eq!(malformed.len(), 65529);
    assert!(!suspected_secret(malformed.as_bytes()));

    let scoped = "a.".repeat(MAX_SCAN_BYTES / 2);
    assert!(!suspected_secret(scoped.as_bytes()));

    let brackets = "[".repeat(MAX_SCAN_BYTES);
    assert!(!suspected_secret(brackets.as_bytes()));

    let fixture_line = format!("\"pwd\":null{},", "}".repeat(24));
    let mut line = fixture_line.repeat(1560);
    line.pop();
    while line.len() < MAX_SCAN_BYTES {
        line.push(' ');
    }
    assert!(!suspected_secret(line.as_bytes()));
}
