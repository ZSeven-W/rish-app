//! The session snapshot schema: the strict node-limited JSON scanner, the
//! schema-9/10 candidate validator with every sub-validator, the legacy (2..=8)
//! root validator, the v2/v3 envelope and tombstone validators, and the
//! `chat-session` digest — ported from the pure half of
//! `SessionSnapshotStore.mm`. File protection, pinned descriptors, atomic
//! writes, locks and the CAS decision stay native.
//!
//! Catalogue answers the validators need (supported models, harness ids,
//! provider hosts, provider-binding validity) are host facts passed in
//! through [`Env`]. Numbers follow Foundation's `doubleValue` reading: a
//! lexeme such as `1.0` is an integer here, `-0` is refused at the scanner.

pub mod cas;
mod composer_drafts;
mod grant_recovery;
mod grant_reuse;
pub(crate) use grant_recovery::frozen_ids_after_lost_prepare;
pub(crate) use grant_reuse::frozen_ids_for_projection;
mod primitives;
// `pub(crate)` so `workspace_json` can assert, in its own tests, that the two
// scanners really do differ rather than saying so only in a comment.
pub(crate) mod scanner;
mod validators;

pub use composer_drafts::{
    validate_composer_drafts, MAX_COMPOSER_DRAFTS, MAX_COMPOSER_DRAFT_BYTES,
    MAX_COMPOSER_DRAFT_TOTAL_BYTES,
};
pub use primitives::*;
pub use scanner::{parse_object, MAX_JSON_NODES, MAX_TOMBSTONE_JSON_NODES};

use crate::canonical::{canonical_json, hash_bytes, hash_json};
use crate::execution_ledger::{as_str, get};
use serde_json::{json, Value};
use std::collections::{BTreeMap, HashSet};

/// `DSHSessionSnapshotMaximumBytes`.
pub const MAX_BYTES: usize = 16 * 1024 * 1024;
/// `DSHSessionSnapshotMaximumCanonicalBytes`.
pub const MAX_CANONICAL_BYTES: usize = 16 * 1024 * 1024;
/// `DSHSessionSnapshotMaximumRecentCommits`.
pub const MAX_RECENT_COMMITS: usize = 64;
/// `DSHSessionSnapshotMaximumTombstones`.
pub const MAX_TOMBSTONES: usize = 400_000;

/// `DSHSessionSnapshotStoreErrorCode` values the pure half can produce.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionError {
    InvalidArgument = 1,
    Corrupt = 2,
    Bounds = 5,
    Conflict = 6,
}

impl SessionError {
    pub fn code(self) -> u8 {
        self as u8
    }
}

/// A provider binding the host has already judged for one logical model,
/// keyed by [`binding_key`] (the SHA-256 of the canonical JSON of
/// `{"binding": …, "model": …}`) so the validator can find it inside the
/// candidate. Validity depends on the model because the binding's harness
/// must be the model's harness.
#[derive(Debug, Clone, Default)]
pub struct ProviderBinding {
    pub canonical_sha256: String,
    pub valid: bool,
    /// The endpoint URL's host (`[NSURL URLWithString:].host`), if any.
    pub host: Option<String>,
}

#[derive(Debug, Clone, Default)]
pub struct Env {
    /// `DSHHarnessIsSupportedModel`.
    pub supported_models: Vec<String>,
    /// `DSHHarnessIdForModel`.
    pub harness_by_model: BTreeMap<String, String>,
    /// `DSHHarnessIsProviderId`.
    pub provider_ids: Vec<String>,
    /// `DSHProviderHostForModel`.
    pub host_by_model: BTreeMap<String, String>,
    /// `DSHValidateProviderBinding` answers for every binding in the input.
    pub provider_bindings: Vec<ProviderBinding>,
}

impl Env {
    pub fn supported_model(&self, value: Option<&Value>) -> bool {
        as_str(value).is_some_and(|model| self.supported_models.iter().any(|m| m == model))
    }

    pub fn harness_for_model(&self, value: Option<&Value>) -> Option<&str> {
        as_str(value).and_then(|model| self.harness_by_model.get(model).map(String::as_str))
    }

    pub fn provider_id(&self, value: Option<&Value>) -> bool {
        as_str(value).is_some_and(|id| self.provider_ids.iter().any(|p| p == id))
    }

    pub fn host_for_model(&self, value: Option<&Value>) -> Option<&str> {
        as_str(value).and_then(|model| self.host_by_model.get(model).map(String::as_str))
    }

    /// `DSHProviderRecordWithoutConfiguration`: strips a valid binding,
    /// returns `None` for an invalid one. Independent providers always need a
    /// captured binding; built-in records retain their existing optional form.
    pub fn record_without_configuration<'a>(
        &self,
        record: &'a Value,
    ) -> Option<(std::borrow::Cow<'a, Value>, Option<&ProviderBinding>)> {
        let Some(binding) = get(record, "provider_configuration") else {
            if get(record, "model")
                .and_then(Value::as_str)
                .is_some_and(|model| {
                    crate::custom_provider_registry::provider_id_for_model(model).is_some()
                })
                || self
                    .harness_for_model(get(record, "model"))
                    .is_some_and(|harness| {
                        crate::custom_provider_registry::provider_id_for_harness(harness).is_some()
                    })
            {
                return None;
            }
            return Some((std::borrow::Cow::Borrowed(record), None));
        };
        let entry = self.binding_for(binding, get(record, "model"))?;
        if !entry.valid {
            return None;
        }
        let mut stripped = match record {
            Value::Object(map) => map.clone(),
            _ => return None,
        };
        stripped.remove("provider_configuration");
        Some((
            std::borrow::Cow::Owned(Value::Object(stripped)),
            Some(entry),
        ))
    }

    fn binding_for(&self, binding: &Value, model: Option<&Value>) -> Option<&ProviderBinding> {
        let digest = binding_key(binding, model)?;
        self.provider_bindings
            .iter()
            .find(|entry| entry.canonical_sha256 == digest)
    }
}

/// SHA-256 of the canonical JSON of `{"binding": binding, "model": model}`
/// (a missing model is `null`), the key the host uses when reporting
/// provider-binding answers.
pub fn binding_key(binding: &Value, model: Option<&Value>) -> Option<String> {
    let keyed = json!({ "binding": binding, "model": model.cloned().unwrap_or(Value::Null) });
    canonical_json(&keyed)
        .ok()
        .map(|bytes| crate::canonical::sha256_hex(&bytes))
}

/// `DSHSessionHashObject(@"chat-session", …)`: refuses empty or oversized
/// canonical bytes.
pub fn session_digest(session: &Value) -> Option<String> {
    let canonical = canonical_json(session).ok()?;
    if canonical.is_empty() || canonical.len() > MAX_CANONICAL_BYTES {
        return None;
    }
    hash_json("chat-session", session)
}

/// A validated current session candidate (schema 9 or 10).
#[derive(Debug, Clone, PartialEq)]
pub struct Candidate {
    pub session: Value,
    pub digest: String,
}

/// The CAS path's candidate acceptance: UTF-8 bounds, strict parse,
/// supported session root, canonical digest. Reading never migrates a session.
pub fn validate_candidate(bytes: &[u8], env: &Env) -> Result<Candidate, SessionError> {
    if bytes.is_empty() || bytes.len() > MAX_BYTES {
        return Err(SessionError::Bounds);
    }
    let session = parse_object(bytes, MAX_JSON_NODES).ok_or(SessionError::InvalidArgument)?;
    if !(validators::Validator { env }).session_root(&session) {
        return Err(SessionError::InvalidArgument);
    }
    let digest = session_digest(&session).ok_or(SessionError::InvalidArgument)?;
    Ok(Candidate { session, digest })
}

/// `+candidateDigestForSessionJSON:`: the lenient JS-facing digest — a
/// parseable object with a supported schema version and that canonicalises.
pub fn candidate_digest(bytes: &[u8]) -> Option<String> {
    if bytes.is_empty() || bytes.len() > MAX_BYTES {
        return None;
    }
    let session = parse_object(bytes, MAX_JSON_NODES)?;
    if !supported_session_version(get(&session, "schema_version")) {
        return None;
    }
    session_digest(&session)
}

/// `DSHSessionValidateLegacyRoot` over an already parsed session.
pub fn validate_legacy_root(session: &Value, env: &Env) -> bool {
    (validators::Validator { env }).legacy_root(session)
}

/// Strict parse (`DSHSessionParseObject`) followed by the legacy root
/// validator, as the v2 envelope path applies them.
pub fn legacy_root_bytes(bytes: &[u8], env: &Env) -> bool {
    if bytes.is_empty() || bytes.len() > MAX_BYTES {
        return false;
    }
    parse_object(bytes, MAX_JSON_NODES).is_some_and(|session| validate_legacy_root(&session, env))
}

/// `DSHSessionValidateSchema9Root` over an already parsed session.
pub fn validate_schema9_root(session: &Value, env: &Env) -> bool {
    exact_schema(get(session, "schema_version"), 9) && validate_session_root(session, env)
}

/// Current readers accept schema 9 unchanged and schema 10 with its required
/// draft map. Unknown versions are never treated as an empty session.
pub fn supported_session_version(version: Option<&Value>) -> bool {
    exact_schema(version, 9) || exact_schema(version, 10)
}

pub fn validate_session_root(session: &Value, env: &Env) -> bool {
    (validators::Validator { env }).session_root(session)
}

/// What `readStateWithError:` learns from a stored envelope.
#[derive(Debug, Clone, PartialEq)]
pub enum Envelope {
    Legacy {
        writer_launch_instance_id: String,
        legacy_bytes_sha256: String,
    },
    Current {
        writer_launch_instance_id: String,
        generation: u64,
        session_sha256: String,
        recent_commits: Vec<Value>,
    },
}

/// `validateV2Envelope:` / `validateV3Envelope:` over the raw stored bytes,
/// including the legacy bytes digest the v2 path mints.
pub fn validate_envelope(raw: &[u8], env: &Env) -> Result<Envelope, SessionError> {
    if raw.is_empty() || raw.len() > MAX_BYTES {
        return Err(SessionError::Corrupt);
    }
    let envelope = parse_object(raw, MAX_JSON_NODES).ok_or(SessionError::Corrupt)?;
    let validator = validators::Validator { env };
    let schema = get(&envelope, "schema_version");
    if exact_schema(schema, 2) {
        let base = ["schema_version", "writer_launch_instance_id", "session"];
        let pair = ["proof_run_id", "proof_request_id"];
        let session = get(&envelope, "session");
        if !optional_pair_keys(&envelope, &base, &pair)
            || !canonical_uuid(get(&envelope, "writer_launch_instance_id"))
            || !session.is_some_and(Value::is_object)
            || !validator.legacy_root(session.expect("checked"))
        {
            return Err(SessionError::Corrupt);
        }
        if envelope.as_object().map(|m| m.len()) == Some(5) {
            let both_null = is_null(get(&envelope, "proof_run_id"))
                && is_null(get(&envelope, "proof_request_id"));
            let both_ids = canonical_uuid(get(&envelope, "proof_run_id"))
                && canonical_uuid(get(&envelope, "proof_request_id"));
            if !both_null && !both_ids {
                return Err(SessionError::Corrupt);
            }
        }
        let digest = hash_bytes("legacy-session-json", raw).ok_or(SessionError::Corrupt)?;
        return Ok(Envelope::Legacy {
            writer_launch_instance_id: as_str(get(&envelope, "writer_launch_instance_id"))
                .unwrap_or_default()
                .to_string(),
            legacy_bytes_sha256: digest,
        });
    }
    if exact_schema(schema, 3) {
        let keys = [
            "schema_version",
            "writer_launch_instance_id",
            "generation",
            "session_sha256",
            "session",
            "recent_commits",
            "proof_run_id",
            "proof_request_id",
        ];
        let session = get(&envelope, "session");
        let commits = match get(&envelope, "recent_commits") {
            Some(Value::Array(commits)) => commits,
            _ => return Err(SessionError::Corrupt),
        };
        if !exact_keys(&envelope, &keys)
            || !canonical_uuid(get(&envelope, "writer_launch_instance_id"))
            || safe_integer(get(&envelope, "generation"), false).is_none()
            || !canonical_digest(get(&envelope, "session_sha256"))
            || !session.is_some_and(Value::is_object)
            || !validator.session_root(session.expect("checked"))
            || commits.is_empty()
            || commits.len() > MAX_RECENT_COMMITS
            || !(is_null(get(&envelope, "proof_run_id"))
                || canonical_uuid(get(&envelope, "proof_run_id")))
            || !(is_null(get(&envelope, "proof_request_id"))
                || canonical_uuid(get(&envelope, "proof_request_id")))
        {
            return Err(SessionError::Corrupt);
        }
        let run_null = is_null(get(&envelope, "proof_run_id"));
        let request_null = is_null(get(&envelope, "proof_request_id"));
        if run_null != request_null {
            return Err(SessionError::Corrupt);
        }
        let computed = session_digest(session.expect("checked")).ok_or(SessionError::Corrupt)?;
        if as_str(get(&envelope, "session_sha256")) != Some(computed.as_str()) {
            return Err(SessionError::Corrupt);
        }
        let generation = safe_integer(get(&envelope, "generation"), false).expect("checked");
        let mut seen: Vec<&str> = Vec::new();
        let mut previous = 0u64;
        for (index, commit) in commits.iter().enumerate() {
            let commit_keys = [
                "schema_version",
                "operation_id",
                "generation",
                "session_sha256",
            ];
            let operation_id = as_str(get(commit, "operation_id")).unwrap_or_default();
            if !exact_keys(commit, &commit_keys)
                || !exact_schema(get(commit, "schema_version"), 1)
                || !canonical_uuid(get(commit, "operation_id"))
                || safe_integer(get(commit, "generation"), false).is_none()
                || !canonical_digest(get(commit, "session_sha256"))
                || seen.contains(&operation_id)
            {
                return Err(SessionError::Corrupt);
            }
            let commit_generation =
                safe_integer(get(commit, "generation"), false).expect("checked");
            if index > 0 && commit_generation <= previous {
                return Err(SessionError::Corrupt);
            }
            seen.push(operation_id);
            previous = commit_generation;
        }
        let last = commits.last().expect("non-empty");
        let first = commits.first().expect("non-empty");
        if safe_integer(get(last, "generation"), false) != Some(generation)
            || as_str(get(last, "session_sha256")) != as_str(get(&envelope, "session_sha256"))
            || commits.len() as u64 > generation
            || safe_integer(get(first, "generation"), false)
                != Some(generation - commits.len() as u64 + 1)
        {
            return Err(SessionError::Corrupt);
        }
        return Ok(Envelope::Current {
            writer_launch_instance_id: as_str(get(&envelope, "writer_launch_instance_id"))
                .unwrap_or_default()
                .to_string(),
            generation,
            session_sha256: computed,
            recent_commits: commits.clone(),
        });
    }
    Err(SessionError::Corrupt)
}

/// `DSHSessionValidateTombstoneEnvelope` over the raw tombstone bytes.
pub fn validate_tombstones(raw: &[u8]) -> Option<(u64, Vec<String>)> {
    if raw.is_empty() || raw.len() > MAX_BYTES {
        return None;
    }
    let envelope = parse_object(raw, MAX_TOMBSTONE_JSON_NODES)?;
    let Some(Value::Array(ids)) = get(&envelope, "operation_ids") else {
        return None;
    };
    if !exact_keys(
        &envelope,
        &["schema_version", "generation", "operation_ids"],
    ) || !exact_schema(get(&envelope, "schema_version"), 1)
        || safe_integer(get(&envelope, "generation"), true).is_none()
        || ids.len() > MAX_TOMBSTONES
    {
        return None;
    }
    // Borrow the parsed IDs for membership, cloning only into the ordered
    // result. A linear scan here makes a full 400,000-entry ledger quadratic.
    let mut seen = HashSet::with_capacity(ids.len());
    let mut ordered = Vec::with_capacity(ids.len());
    for id in ids {
        if !canonical_uuid(Some(id)) {
            return None;
        }
        let text = as_str(Some(id)).expect("uuid");
        if !seen.insert(text) {
            return None;
        }
        ordered.push(text.to_owned());
    }
    Some((
        safe_integer(get(&envelope, "generation"), true).expect("checked"),
        ordered,
    ))
}

// MARK: - JSON envelope for the FFI

/// Builds an [`Env`] from the JSON shape the host sends (`supported_models`,
/// `harness_by_model`, `provider_ids`, `host_by_model`, `provider_bindings`).
pub fn env_from_json(value: Option<&Value>) -> Env {
    let value = value.unwrap_or(&Value::Null);
    let list = |key: &str| -> Vec<String> {
        match get(value, key) {
            Some(Value::Array(items)) => items
                .iter()
                .filter_map(|i| as_str(Some(i)).map(str::to_owned))
                .collect(),
            _ => Vec::new(),
        }
    };
    let map = |key: &str| -> BTreeMap<String, String> {
        match get(value, key) {
            Some(Value::Object(entries)) => entries
                .iter()
                .filter_map(|(k, v)| as_str(Some(v)).map(|v| (k.clone(), v.to_owned())))
                .collect(),
            _ => BTreeMap::new(),
        }
    };
    let bindings = match get(value, "provider_bindings") {
        Some(Value::Array(items)) => items
            .iter()
            .map(|item| ProviderBinding {
                canonical_sha256: as_str(get(item, "canonical_sha256"))
                    .unwrap_or_default()
                    .to_string(),
                valid: get(item, "valid") == Some(&Value::Bool(true)),
                host: as_str(get(item, "host")).map(str::to_owned),
            })
            .collect(),
        _ => Vec::new(),
    };
    Env {
        supported_models: list("supported_models"),
        harness_by_model: map("harness_by_model"),
        provider_ids: list("provider_ids"),
        host_by_model: map("host_by_model"),
        provider_bindings: bindings,
    }
}

/// `{"op","env"}` as the request, the operation's raw bytes (candidate
/// JSON, stored envelope, tombstone file) as `input`; `{"ok":true,...}` or
/// `{"ok":false,"error":<code>}` out. Ops: `candidate` → `{digest}`;
/// `candidate_digest` → `{digest|null}`; `envelope` → `{kind:2|3,
/// writer_launch_instance_id, generation?, session_sha256?, recent_commits?,
/// legacy_bytes_sha256?}`; `tombstones` → `{generation, operation_ids}`;
/// `legacy_root` → `{valid}`.
pub fn reduce_json(request: &str, input: &[u8]) -> String {
    let value = match reduce_json_inner(request, input) {
        Ok(output) => {
            let mut object = output.as_object().cloned().unwrap_or_default();
            object.insert("ok".to_string(), Value::Bool(true));
            Value::Object(object)
        }
        Err(error) => json!({ "ok": false, "error": error.code() }),
    };
    value.to_string()
}

fn reduce_json_inner(request: &str, input: &[u8]) -> Result<Value, SessionError> {
    let envelope: Value = serde_json::from_str(request).map_err(|_| SessionError::Corrupt)?;
    let op = as_str(get(&envelope, "op")).ok_or(SessionError::Corrupt)?;
    let env = env_from_json(get(&envelope, "env"));
    match op {
        "candidate" => {
            let candidate = validate_candidate(input, &env)?;
            Ok(json!({ "digest": candidate.digest }))
        }
        "candidate_digest" => Ok(json!({ "digest": candidate_digest(input) })),
        "envelope" => match validate_envelope(input, &env)? {
            Envelope::Legacy {
                writer_launch_instance_id,
                legacy_bytes_sha256,
            } => Ok(
                json!({ "kind": 2, "writer_launch_instance_id": writer_launch_instance_id, "legacy_bytes_sha256": legacy_bytes_sha256 }),
            ),
            Envelope::Current {
                writer_launch_instance_id,
                generation,
                session_sha256,
                recent_commits,
            } => Ok(json!({
                "kind": 3, "writer_launch_instance_id": writer_launch_instance_id, "generation": generation,
                "session_sha256": session_sha256, "recent_commits": recent_commits,
            })),
        },
        "tombstones" => {
            let (generation, ids) = validate_tombstones(input).ok_or(SessionError::Corrupt)?;
            Ok(json!({ "generation": generation, "operation_ids": ids }))
        }
        "legacy_root" => Ok(json!({ "valid": legacy_root_bytes(input, &env) })),
        _ => cas::reduce(op, &envelope, input, &env),
    }
}
