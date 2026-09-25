//! What the Git tools decide: which staged paths a commit may contain, the
//! exact bytes of the commit object, and therefore its object id before
//! libgit2 has written anything.
//!
//! Ported from `AgentGitToolExecutor.mm`. libgit2 is the capability and stays
//! with the host; these are the parts that must be identical everywhere,
//! because the precondition a commit is approved against carries
//! `expected_commit_oid` — the id the commit *will* have. Predicting it is what
//! makes a crash between "libgit2 wrote the object" and "the ledger recorded
//! it" recoverable: the host can look for that exact id afterwards. Two
//! implementations of the payload encoding would predict two different ids and
//! the recovery would silently find nothing.

use serde_json::{json, Value};
use unicode_normalization::UnicodeNormalization;

use crate::canonical::{hash_bytes, hash_json};
use crate::schema::bounded_utf8;
use crate::store::StoreError;

/// Git's own blob modes. Anything else in a staged index — a symlink, a
/// gitlink to a submodule, a directory — is refused rather than committed.
const FILEMODE_BLOB: u64 = 0o100_644;
const FILEMODE_BLOB_EXECUTABLE: u64 = 0o100_755;

/// The value-free tokens a `git_push` failure may carry next to its stable
/// failure code, so the model can tell a non-fast-forward from a moved remote
/// or a rejected credential without ever seeing server text.
pub const PUSH_REASONS: &[&str] = &[
    "origin_unsafe",
    "credential_missing",
    "remote_moved",
    "non_fast_forward",
    "rejected",
    "auth_failed",
    "ambiguous",
    // A push whose network phase outran its deadline. The host reports this
    // one as ambiguous because the server may already have it, so refusing
    // the token discards the very case the caller must not retry blind.
    "timeout",
    "cancelled",
    "transport",
    // The person's HTTPS proxy refused the tunnel or could not reach the
    // remote: named apart so the model points at the proxy, not the remote.
    "proxy",
];

/// SHA-1, needed only to reproduce Git's object id.
///
/// It is written out here rather than pulled in as a dependency: the core has
/// no SHA-1 today, and this is not a security primitive — Git's object format
/// specifies SHA-1 and nothing here relies on it being hard to forge. The
/// tests pin it against the standard vectors and against a real commit id.
fn sha1_hex(bytes: &[u8]) -> String {
    let mut h: [u32; 5] = [
        0x6745_2301,
        0xEFCD_AB89,
        0x98BA_DCFE,
        0x1032_5476,
        0xC3D2_E1F0,
    ];
    let mut message = bytes.to_vec();
    let bit_length = (bytes.len() as u64).wrapping_mul(8);
    message.push(0x80);
    while message.len() % 64 != 56 {
        message.push(0);
    }
    message.extend_from_slice(&bit_length.to_be_bytes());
    for chunk in message.chunks_exact(64) {
        let mut w = [0u32; 80];
        for (index, word) in chunk.chunks_exact(4).enumerate() {
            w[index] = u32::from_be_bytes([word[0], word[1], word[2], word[3]]);
        }
        for index in 16..80 {
            w[index] = (w[index - 3] ^ w[index - 8] ^ w[index - 14] ^ w[index - 16]).rotate_left(1);
        }
        let (mut a, mut b, mut c, mut d, mut e) = (h[0], h[1], h[2], h[3], h[4]);
        for (index, word) in w.iter().enumerate() {
            let (f, k) = match index {
                0..=19 => ((b & c) | (!b & d), 0x5A82_7999),
                20..=39 => (b ^ c ^ d, 0x6ED9_EBA1),
                40..=59 => ((b & c) | (b & d) | (c & d), 0x8F1B_BCDC),
                _ => (b ^ c ^ d, 0xCA62_C1D6),
            };
            let temp = a
                .rotate_left(5)
                .wrapping_add(f)
                .wrapping_add(e)
                .wrapping_add(k)
                .wrapping_add(*word);
            e = d;
            d = c;
            c = b.rotate_left(30);
            b = a;
            a = temp;
        }
        h[0] = h[0].wrapping_add(a);
        h[1] = h[1].wrapping_add(b);
        h[2] = h[2].wrapping_add(c);
        h[3] = h[3].wrapping_add(d);
        h[4] = h[4].wrapping_add(e);
    }
    h.iter().map(|word| format!("{word:08x}")).collect()
}

/// `DSHAgentGitTimezoneString`: `+HHMM` / `-HHMM`, as Git writes it.
pub fn timezone_string(minutes: i64) -> String {
    let sign = if minutes < 0 { '-' } else { '+' };
    let absolute = minutes.unsigned_abs();
    format!("{sign}{:02}{:02}", absolute / 60, absolute % 60)
}

/// The inverse. A value that is not `±HHMM` has no offset.
pub fn timezone_minutes(value: &str) -> Option<i64> {
    let bytes = value.as_bytes();
    if bytes.len() != 5 || !matches!(bytes[0], b'+' | b'-') {
        return None;
    }
    if !bytes[1..].iter().all(u8::is_ascii_digit) {
        return None;
    }
    let hours: i64 = value[1..3].parse().ok()?;
    let minutes: i64 = value[3..5].parse().ok()?;
    let total = hours * 60 + minutes;
    Some(if bytes[0] == b'-' { -total } else { total })
}

fn is_oid(value: &str) -> bool {
    (value.len() == 40 || value.len() == 64)
        && value
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
}

/// `DSHAgentGitCommitPayload`: the commit object's body, byte for byte. The
/// author and the committer are the same fixed identity — an agent commit is
/// never attributed to the person — and the encoding header is always UTF-8.
pub fn commit_payload(
    tree: &str,
    parents: &[String],
    timestamp_seconds: &str,
    timezone_offset: &str,
    message: &str,
) -> Result<Vec<u8>, StoreError> {
    if !is_oid(tree)
        || !parents.iter().all(|parent| is_oid(parent))
        || !timestamp_seconds.bytes().all(|b| b.is_ascii_digit())
        || timestamp_seconds.is_empty()
        || timezone_minutes(timezone_offset).is_none()
    {
        return Err(StoreError::InvalidArgument);
    }
    let mut payload = format!("tree {tree}\n");
    for parent in parents {
        payload.push_str(&format!("parent {parent}\n"));
    }
    let person = format!("Rish Agent <agent@rish.local> {timestamp_seconds} {timezone_offset}");
    payload.push_str(&format!(
        "author {person}\ncommitter {person}\nencoding UTF-8\n\n{message}"
    ));
    Ok(payload.into_bytes())
}

/// `DSHAgentGitExpectedSHA1`: the id the commit object will have once it is
/// written — `sha1("commit " || length || NUL || payload)`.
pub fn expected_commit_oid(payload: &[u8]) -> String {
    let mut object = format!("commit {}", payload.len()).into_bytes();
    object.push(0);
    object.extend_from_slice(payload);
    sha1_hex(&object)
}

/// `DSHAgentGitIndexDigest`: what a staged index must look like before it may
/// be committed, and the digest the precondition is taken over.
///
/// A path that escapes the repository, names Git's own metadata, or is not the
/// canonical spelling of itself is a conflict rather than a bad request: the
/// call was well formed, the working tree is not in a state this tool commits.
pub fn index_digest(entries: &[Value]) -> Result<String, StoreError> {
    let mut rows: Vec<Value> = Vec::with_capacity(entries.len());
    for entry in entries {
        let path = bounded_utf8(entry.get("path"), 4096, false).ok_or(StoreError::Corrupt)?;
        let mode = entry
            .get("mode")
            .and_then(Value::as_u64)
            .ok_or(StoreError::Corrupt)?;
        let oid = entry
            .get("oid")
            .and_then(Value::as_str)
            .filter(|oid| is_oid(oid))
            .ok_or(StoreError::Corrupt)?;
        let stage = entry
            .get("stage")
            .and_then(Value::as_u64)
            .ok_or(StoreError::Corrupt)?;
        let safe_mode = mode == FILEMODE_BLOB || mode == FILEMODE_BLOB_EXECUTABLE;
        if !safe_mode
            || path.nfc().ne(path.chars())
            || path.starts_with('/')
            || path.contains('\\')
            // .gitmodules would let a commit introduce a submodule, which is a
            // second repository this engine never audited.
            || path == ".gitmodules"
            || path.split('/').any(|component| {
                component.is_empty() || matches!(component, "." | ".." | ".git")
            })
        {
            return Err(StoreError::Conflict);
        }
        rows.push(json!({
            "path_sha256": hash_bytes("relative-path", path.as_bytes())
                .ok_or(StoreError::InvalidArgument)?,
            "mode": mode,
            "oid": oid,
            "stage": stage,
        }));
    }
    hash_json("git-index", &json!({ "entries": rows })).ok_or(StoreError::InvalidArgument)
}

/// The failure result a Git tool reports. `reason` is the value-free token; a
/// token outside the closed set would leak server text into the transcript.
pub fn failure_result(
    name: &str,
    code: &str,
    reason: Option<&str>,
    ambiguous: bool,
) -> Result<Value, StoreError> {
    let outcome = if ambiguous { "ambiguous" } else { "failed" };
    let payload = match reason {
        None => json!({ "schema_version": 1, "failure_code": code }),
        Some(reason) => {
            if !PUSH_REASONS.contains(&reason) {
                return Err(StoreError::InvalidArgument);
            }
            json!({ "schema_version": 1, "failure_code": code, "reason": reason })
        }
    };
    let feedback = json!({
        "schema_version": 1, "name": name, "outcome": outcome, "payload": payload,
    });
    let bytes =
        crate::canonical::canonical_json(&feedback).map_err(|_| StoreError::InvalidArgument)?;
    let text = String::from_utf8(bytes).map_err(|_| StoreError::InvalidArgument)?;
    crate::execution_ledger::feedback_string_valid(&text)?;
    Ok(json!({
        "schema_version": 1,
        "status": outcome,
        "feedback": text,
        "settled_facts": Value::Null,
        "truncated": false,
        "effect_may_have_occurred": ambiguous,
    }))
}

/// One envelope in, one reply out; see `rish_agent_git_tool_reduce`.
pub fn reduce_json(input: &str) -> String {
    let value = match reduce_json_inner(input) {
        Ok(output) => {
            let mut object = output.as_object().cloned().unwrap_or_default();
            object.insert("ok".to_string(), Value::Bool(true));
            Value::Object(object)
        }
        Err(error) => json!({ "ok": false, "error": error.code() }),
    };
    value.to_string()
}

fn reduce_json_inner(input: &str) -> Result<Value, StoreError> {
    let envelope: Value = serde_json::from_str(input).map_err(|_| StoreError::Corrupt)?;
    let op = envelope
        .get("op")
        .and_then(Value::as_str)
        .ok_or(StoreError::Corrupt)?;
    let text = |key: &str| {
        envelope
            .get(key)
            .and_then(Value::as_str)
            .ok_or(StoreError::InvalidArgument)
    };
    match op {
        "timezone_string" => {
            let minutes = envelope
                .get("minutes")
                .and_then(Value::as_i64)
                .ok_or(StoreError::InvalidArgument)?;
            Ok(json!({ "timezone_offset": timezone_string(minutes) }))
        }
        "timezone_minutes" => Ok(json!({
            "minutes": timezone_minutes(text("timezone_offset")?)
                .ok_or(StoreError::InvalidArgument)?
        })),
        "index_digest" => {
            let Some(Value::Array(entries)) = envelope.get("entries") else {
                return Err(StoreError::InvalidArgument);
            };
            Ok(json!({ "staged_index_sha256": index_digest(entries)? }))
        }
        // The payload, its digest and the id it predicts are one answer: a
        // caller that could take them separately could mix two payloads.
        "commit_identity" => {
            let parents: Vec<String> = match envelope.get("parents") {
                Some(Value::Array(items)) => items
                    .iter()
                    .map(|item| {
                        item.as_str()
                            .map(str::to_string)
                            .ok_or(StoreError::InvalidArgument)
                    })
                    .collect::<Result<_, _>>()?,
                _ => return Err(StoreError::InvalidArgument),
            };
            let payload = commit_payload(
                text("tree_oid")?,
                &parents,
                text("timestamp_seconds")?,
                text("timezone_offset")?,
                text("message")?,
            )?;
            Ok(json!({
                "commit_payload_sha256": hash_bytes("git-commit-payload", &payload)
                    .ok_or(StoreError::InvalidArgument)?,
                "expected_commit_oid": expected_commit_oid(&payload),
                "payload_bytes": payload.len(),
            }))
        }
        "failure_result" => Ok(json!({
            "result": failure_result(
                text("name")?,
                text("failure_code")?,
                envelope.get("reason").and_then(Value::as_str),
                envelope.get("ambiguous") == Some(&Value::Bool(true)))?
        })),
        _ => Err(StoreError::InvalidArgument),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Every token AgentGitToolExecutor.mm can hand to a push failure. The set
    // is closed to keep server text out of the transcript, so a token the host
    // emits and this set omits turns a real outcome into a malformed request.
    #[test]
    fn every_push_reason_the_host_emits_is_accepted() {
        for (reason, ambiguous) in [
            ("origin_unsafe", false),
            ("credential_missing", false),
            ("remote_moved", false),
            ("non_fast_forward", false),
            ("rejected", false),
            ("auth_failed", false),
            ("timeout", true),
            ("cancelled", true),
            ("transport", true),
            ("proxy", false),
            ("proxy", true),
        ] {
            let result = failure_result("git_push", "E_AGENT_TOOL_FAILED", Some(reason), ambiguous)
                .unwrap_or_else(|_| panic!("host reason {reason} was refused"));
            assert!(result["feedback"].as_str().unwrap().contains(reason));
            // The point of the timeout token: the caller must not retry blind.
            assert_eq!(result["effect_may_have_occurred"], json!(ambiguous));
        }
        // The closed set still holds: unknown text cannot reach a transcript.
        assert_eq!(
            failure_result("git_push", "E_AGENT_TOOL_FAILED", Some("fatal: repo not found"), false),
            Err(StoreError::InvalidArgument)
        );
    }

    #[test]
    fn sha1_matches_the_standard_vectors() {
        assert_eq!(sha1_hex(b""), "da39a3ee5e6b4b0d3255bfef95601890afd80709");
        assert_eq!(sha1_hex(b"abc"), "a9993e364706816aba3e25717850c26c9cd0d89d");
        assert_eq!(
            sha1_hex(b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
            "84983e441c3bd26ebaae4aa1f95129e5e54670f1"
        );
        // Multi-block, and long enough that the length padding spills.
        assert_eq!(
            sha1_hex(&b"a".repeat(1_000_000)),
            "34aa973cd4c4daa4f61eeb2bdbad27316534016f"
        );
    }

    /// The id the precondition promises is the id Git will give the object,
    /// so this is checked against a commit produced outside this code.
    #[test]
    fn a_commit_object_gets_the_id_git_would_give_it() {
        // These bytes and this id come from `git hash-object -t commit` over
        // the payload, not from this implementation: 179 bytes ->
        // 03eebf1a25096a81d8fb33ec0c5de1a9f9258d30.
        let payload = b"tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904\n\
author Rish Agent <agent@rish.local> 1700000000 +0000\n\
committer Rish Agent <agent@rish.local> 1700000000 +0000\n\
encoding UTF-8\n\n\
first\n";
        let built = commit_payload(
            "4b825dc642cb6eb9a060e54bf8d69288fbee4904",
            &[],
            "1700000000",
            "+0000",
            "first\n",
        )
        .expect("payload");
        assert_eq!(built, payload);
        assert_eq!(built.len(), 179);
        assert_eq!(
            expected_commit_oid(&built),
            "03eebf1a25096a81d8fb33ec0c5de1a9f9258d30"
        );
    }

    #[test]
    fn a_parent_is_written_in_order_between_the_tree_and_the_author() {
        let payload = commit_payload(
            &"a".repeat(40),
            &["b".repeat(40), "c".repeat(40)],
            "1",
            "-0830",
            "m",
        )
        .expect("payload");
        let text = String::from_utf8(payload).expect("utf8");
        assert!(text.starts_with(&format!(
            "tree {}\nparent {}\nparent {}\nauthor ",
            "a".repeat(40),
            "b".repeat(40),
            "c".repeat(40)
        )));
        assert!(text.ends_with("encoding UTF-8\n\nm"));
    }

    #[test]
    fn the_timezone_offset_round_trips() {
        for minutes in [0i64, 60, -60, 330, -510, 840, -720] {
            let text = timezone_string(minutes);
            assert_eq!(timezone_minutes(&text), Some(minutes), "{minutes}");
        }
        assert_eq!(timezone_string(-510), "-0830");
        assert_eq!(timezone_string(330), "+0530");
        for bad in ["", "0000", "+00000", "+0a00", "Z", "+12:0"] {
            assert_eq!(timezone_minutes(bad), None, "{bad}");
        }
    }

    #[test]
    fn a_commit_refuses_an_identity_it_cannot_spell() {
        assert!(commit_payload("nottree", &[], "1", "+0000", "m").is_err());
        assert!(commit_payload(&"a".repeat(40), &["short".into()], "1", "+0000", "m").is_err());
        assert!(commit_payload(&"a".repeat(40), &[], "", "+0000", "m").is_err());
        assert!(commit_payload(&"a".repeat(40), &[], "-1", "+0000", "m").is_err());
        assert!(commit_payload(&"a".repeat(40), &[], "1", "0000", "m").is_err());
    }

    fn entry(path: &str, mode: u64) -> Value {
        json!({ "path": path, "mode": mode, "oid": "a".repeat(40), "stage": 0 })
    }

    #[test]
    fn a_staged_path_that_escapes_or_names_git_is_a_conflict() {
        for path in [
            "../outside",
            "a/../../b",
            ".git/config",
            "a/.git/x",
            ".gitmodules",
            "/abs",
            "a\\b",
            "a//b",
        ] {
            assert_eq!(
                index_digest(&[entry(path, FILEMODE_BLOB)]),
                Err(StoreError::Conflict),
                "{path}"
            );
        }
        // A decomposed name is a different file from the one that was read.
        assert_eq!(
            index_digest(&[entry("cafe\u{301}.md", FILEMODE_BLOB)]),
            Err(StoreError::Conflict)
        );
    }

    #[test]
    fn only_a_plain_or_executable_blob_may_be_committed() {
        assert!(index_digest(&[entry("a.md", FILEMODE_BLOB)]).is_ok());
        assert!(index_digest(&[entry("a.sh", FILEMODE_BLOB_EXECUTABLE)]).is_ok());
        for mode in [0o120_000u64, 0o160_000, 0o040_000, 0o100_000] {
            assert_eq!(
                index_digest(&[entry("a.md", mode)]),
                Err(StoreError::Conflict),
                "{mode:o}"
            );
        }
    }

    #[test]
    fn the_index_digest_depends_on_every_field_and_the_order() {
        let base =
            index_digest(&[entry("a", FILEMODE_BLOB), entry("b", FILEMODE_BLOB)]).expect("digest");
        let swapped =
            index_digest(&[entry("b", FILEMODE_BLOB), entry("a", FILEMODE_BLOB)]).expect("digest");
        assert_ne!(base, swapped);
        let remode = index_digest(&[
            entry("a", FILEMODE_BLOB_EXECUTABLE),
            entry("b", FILEMODE_BLOB),
        ])
        .expect("digest");
        assert_ne!(base, remode);
    }

    #[test]
    fn a_push_reason_outside_the_closed_set_cannot_be_reported() {
        assert!(
            failure_result("git_push", "E_AGENT_CONFLICT", Some("remote_moved"), false).is_ok()
        );
        assert!(failure_result("git_commit", "E_AGENT_TOOL_FAILED", None, false).is_ok());
        assert!(failure_result(
            "git_push",
            "E_AGENT_TOOL_FAILED",
            Some("remote hung up unexpectedly"),
            false
        )
        .is_err());
    }

    #[test]
    fn an_ambiguous_failure_says_the_effect_may_have_happened() {
        let result = failure_result(
            "git_push",
            "E_AGENT_EXECUTION_AMBIGUOUS",
            Some("ambiguous"),
            true,
        )
        .expect("result");
        assert_eq!(result["status"], json!("ambiguous"));
        assert_eq!(result["effect_may_have_occurred"], json!(true));
    }
}
