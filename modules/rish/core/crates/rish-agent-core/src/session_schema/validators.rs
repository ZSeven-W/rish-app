//! The schema-9 acceptance graph and the legacy (2..=8) root validator,
//! ported function for function from `SessionSnapshotStore.mm`. Every
//! function mirrors the ObjC check order so the same input is refused at the
//! same place; catalogue answers come from [`Env`].

use super::primitives::*;
use super::Env;
use crate::execution_ledger::{as_str, get};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};

const MAX_EVENTS: usize = 8192;
const MAX_OUTBOX: usize = 16;
const MAX_CLEANUP: usize = 64;
const MAX_MESSAGE_BYTES: usize = 1_000_000;
const MAX_TITLE_BYTES: usize = 120;
const MAX_TURNS: usize = 100_000;
const MAX_ATTEMPTS: usize = 100_000;
const MAX_ATTACHMENTS: usize = 6;
const MAX_ATTACHMENT_BYTES: u64 = 8 * 1024 * 1024 + 6 * 1024 * 1024;
const MAX_TEXT_ATTACHMENT_BYTES: u64 = 1024 * 1024;
const MAX_BINARY_ATTACHMENT_BYTES: u64 = 8 * 1024 * 1024;
const MAX_VISIBLE_MESSAGES: usize = 200;
const MAX_VISIBLE_ATTACHMENTS: usize = 24;
const MAX_CONTEXT_BYTES: u64 = 256 * 1024;
const MAX_RESULT_BYTES: u64 = 32 * 1024 * 1024;
const MAX_TRANSCRIPT_BYTES: u64 = 2 * 1024 * 1024;

pub(super) struct Validator<'a> {
    pub env: &'a Env,
}

fn is_dict(value: Option<&Value>) -> bool {
    value.is_some_and(Value::is_object)
}

fn is_array(value: Option<&Value>) -> bool {
    value.is_some_and(Value::is_array)
}

fn array(value: Option<&Value>) -> &[Value] {
    match value {
        Some(Value::Array(items)) => items,
        _ => &[],
    }
}

fn len(value: Option<&Value>) -> usize {
    array(value).len()
}

fn string_in(value: Option<&Value>, set: &[&str]) -> bool {
    as_str(value).is_some_and(|text| set.contains(&text))
}

fn uint(value: Option<&Value>) -> u64 {
    safe_integer(value, true).unwrap_or(0)
}

/// `[a isEqual:b]` between two optional values; a missing key is `nil`,
/// which equals nothing.
fn equal(left: Option<&Value>, right: Option<&Value>) -> bool {
    match (left, right) {
        (Some(l), Some(r)) => l == r,
        _ => false,
    }
}

/// `[a isEqual:(b ?: NSNull.null)]`.
fn equal_or_null(left: Option<&Value>, right: Option<&Value>) -> bool {
    let null = Value::Null;
    equal(left, Some(right.unwrap_or(&null)))
}

fn nested<'a>(value: Option<&'a Value>, key: &str) -> Option<&'a Value> {
    value.and_then(|v| get(v, key))
}

fn present(value: Option<&Value>) -> Option<&Value> {
    value.filter(|v| !v.is_null())
}

impl Validator<'_> {
    fn valid_model(&self, value: Option<&Value>) -> bool {
        self.env.supported_model(value)
    }

    // MARK: preferences / events / attachments / messages

    fn preferences(&self, preferences: Option<&Value>) -> bool {
        let Some(preferences) = preferences.filter(|p| p.is_object()) else {
            return false;
        };
        let field = |key: &str| get(preferences, key);
        if !exact_schema(field("schema_version"), 1)
            || as_str(field("theme_mode")).is_none()
            || as_str(field("locale")).is_none()
            || as_str(field("default_model")).is_none()
            || as_str(field("thinking_mode")).is_none()
            || as_str(field("tool_permission")).is_none()
            || !is_boolean(field("show_reasoning"))
            || !is_boolean(field("auto_expand_tools"))
            || !is_boolean(field("confirm_destructive_file_actions"))
        {
            return false;
        }
        if !string_in(field("theme_mode"), &["system", "light", "dark"])
            || !string_in(field("locale"), &["system", "zh-CN", "en-US"])
            || !self.valid_model(field("default_model"))
            || !string_in(field("thinking_mode"), &["off", "high", "max"])
            || !string_in(field("tool_permission"), &["read-only", "workspace-write"])
        {
            return false;
        }
        const KNOWN: &[&str] = &[
            "schema_version",
            "theme_mode",
            "locale",
            "default_model",
            "selected_harness_id",
            "thinking_mode",
            "tool_permission",
            "show_reasoning",
            "auto_expand_tools",
            "confirm_destructive_file_actions",
            "git_https_proxy_url",
            "mirrors",
        ];
        let map = preferences.as_object().expect("object");
        if !map.keys().all(|key| KNOWN.contains(&key.as_str())) {
            return false;
        }
        if field("selected_harness_id").is_some() && !valid_harness_id(field("selected_harness_id"))
        {
            return false;
        }
        if let Some(proxy) = field("git_https_proxy_url") {
            if !proxy.is_null() && !safe_proxy_url(Some(proxy)) {
                return false;
            }
        }
        if let Some(mirrors) = field("mirrors") {
            if !mirrors.is_object() || !exact_keys(mirrors, &["alpine", "pip", "npm"]) {
                return false;
            }
            for category in ["alpine", "pip", "npm"] {
                let entry = get(mirrors, category);
                let Some(entry) = entry.filter(|e| e.is_object()) else {
                    return false;
                };
                if !exact_keys(entry, &["enabled", "base_url"])
                    || !is_boolean(get(entry, "enabled"))
                    || !safe_mirror_url(get(entry, "base_url"))
                {
                    return false;
                }
            }
        }
        true
    }

    fn event(&self, event: &Value) -> bool {
        let keys = [
            "schema_version",
            "event_id",
            "attempt_id",
            "seq",
            "kind",
            "round_index",
            "call_id",
            "status",
            "safe_summary_key",
            "arguments_sha256",
            "result_sha256",
            "approval_reference",
            "failure_code",
            "created_at",
        ];
        let f = |key: &str| get(event, key);
        if !exact_keys(event, &keys)
            || !exact_schema(f("schema_version"), 2)
            || !canonical_uuid(f("event_id"))
            || !canonical_uuid(f("attempt_id"))
            || safe_integer(f("seq"), true).is_none()
            || as_str(f("kind")).is_none()
            || !(is_null(f("round_index"))
                || safe_integer(f("round_index"), true).is_some_and(|i| i < 8))
            || !(is_null(f("call_id")) || valid_opaque_identifier(f("call_id")))
            || as_str(f("status")).is_none()
            || !string_in(
                f("status"),
                &[
                    "waiting",
                    "approval",
                    "running",
                    "ok",
                    "failed",
                    "denied",
                    "cancelled",
                    "unknown",
                    "ambiguous",
                ],
            )
            || !(is_null(f("safe_summary_key")) || valid_agent_summary_key(f("safe_summary_key")))
            || !(is_null(f("arguments_sha256")) || canonical_digest(f("arguments_sha256")))
            || !(is_null(f("result_sha256")) || canonical_digest(f("result_sha256")))
            || !(is_null(f("approval_reference")) || valid_identifier(f("approval_reference"), 256))
            || !valid_agent_failure_code(f("failure_code"))
            || !canonical_timestamp(f("created_at"))
        {
            return false;
        }
        let kind = as_str(f("kind")).unwrap_or_default();
        if kind == "cancel" {
            if as_str(f("status")) != Some("cancelled")
                || !is_null(f("safe_summary_key"))
                || !is_null(f("result_sha256"))
                || !equal(f("approval_reference"), f("event_id"))
                || !string_in(
                    f("failure_code"),
                    &[
                        "E_AGENT_CANCELLED",
                        "E_AGENT_ROOT_STALE",
                        "E_AGENT_PERSISTENCE",
                    ],
                )
            {
                return false;
            }
            let attempt_target = is_null(f("round_index"))
                && is_null(f("call_id"))
                && is_null(f("arguments_sha256"));
            let round_target = !is_null(f("round_index"))
                && is_null(f("call_id"))
                && is_null(f("arguments_sha256"));
            let tool_target = !is_null(f("round_index"))
                && !is_null(f("call_id"))
                && !is_null(f("arguments_sha256"));
            return attempt_target || round_target || tool_target;
        }
        matches!(
            kind,
            "round" | "tool_call" | "tool_result" | "approval" | "terminal"
        )
    }

    fn attachment(&self, attachment: &Value) -> bool {
        let f = |key: &str| get(attachment, key);
        if !exact_keys(
            attachment,
            &["schema_version", "id", "kind", "name", "mime_type", "size"],
        ) || !exact_schema(f("schema_version"), 1)
            || !valid_identifier(f("id"), MAX_ID_BYTES)
            || !string_in(f("kind"), &["image", "text", "pdf"])
            || bounded_text(f("name"), MAX_ID_BYTES, false).is_none()
            || as_str(f("name")).is_some_and(|n| n.contains('\0'))
            || bounded_text(f("mime_type"), 256, false).is_none()
            || safe_integer(f("size"), true).is_none()
        {
            return false;
        }
        let kind = as_str(f("kind")).unwrap_or_default();
        let mime_raw = as_str(f("mime_type")).unwrap_or_default();
        let mime = mime_raw.to_lowercase();
        let mime_ok = (kind == "image" && mime.starts_with("image/"))
            || (kind == "text" && mime.starts_with("text/"))
            || (kind == "pdf" && mime == "application/pdf");
        let token = |b: &u8| {
            b.is_ascii_alphanumeric()
                || matches!(
                    b,
                    b'!' | b'#' | b'$' | b'&' | b'^' | b'_' | b'.' | b'+' | b'-'
                )
        };
        let shape_ok = match mime_raw.split_once('/') {
            Some((left, right)) => {
                !left.is_empty()
                    && !right.is_empty()
                    && left.bytes().all(|b| token(&b))
                    && right.bytes().all(|b| token(&b))
            }
            None => false,
        };
        let maximum = if kind == "text" {
            MAX_TEXT_ATTACHMENT_BYTES
        } else {
            MAX_BINARY_ATTACHMENT_BYTES
        };
        let size = uint(f("size"));
        mime_ok && shape_ok && size > 0 && size <= maximum
    }

    fn metadata(&self, metadata: &Value) -> bool {
        if !keys(
            metadata,
            &[],
            &["model_id", "latency_ms", "finish_reason", "reasoning"],
        ) {
            return false;
        }
        let f = |key: &str| get(metadata, key);
        if f("model_id").is_some() && !self.valid_model(f("model_id")) {
            return false;
        }
        if f("latency_ms").is_some() && safe_integer(f("latency_ms"), true).is_none() {
            return false;
        }
        if f("finish_reason").is_some() && bounded_text(f("finish_reason"), 256, false).is_none() {
            return false;
        }
        f("reasoning").is_none() || bounded_text(f("reasoning"), MAX_MESSAGE_BYTES, false).is_some()
    }

    fn message(&self, message: &Value, schema_version: u64) -> bool {
        let required: &[&str] = if schema_version >= 4 {
            &["id", "role", "text", "created_at", "attachments"]
        } else {
            &["id", "role", "text", "created_at"]
        };
        let f = |key: &str| get(message, key);
        if !keys(message, required, &["metadata"])
            || !valid_identifier(f("id"), MAX_ID_BYTES)
            || !string_in(f("role"), &["user", "assistant"])
            || bounded_text(f("text"), MAX_MESSAGE_BYTES, true).is_none()
            || !canonical_timestamp(f("created_at"))
        {
            return false;
        }
        let mut attachment_count = 0usize;
        if schema_version >= 4 {
            let attachments = f("attachments");
            if !is_array(attachments) || len(attachments) > MAX_ATTACHMENTS {
                return false;
            }
            let mut ids: BTreeSet<&str> = BTreeSet::new();
            let mut total = 0u64;
            for attachment in array(attachments) {
                let id = as_str(get(attachment, "id")).unwrap_or_default();
                if !self.attachment(attachment) || ids.contains(id) {
                    return false;
                }
                ids.insert(id);
                total += uint(get(attachment, "size"));
                if total > MAX_ATTACHMENT_BYTES {
                    return false;
                }
            }
            attachment_count = len(attachments);
        }
        if let Some(metadata) = f("metadata") {
            if !self.metadata(metadata) {
                return false;
            }
        }
        let text = as_str(f("text")).unwrap_or_default();
        !(trimmed_is_empty(text)
            && (as_str(f("role")) == Some("assistant") || attachment_count == 0))
    }

    fn messages<'v>(
        &self,
        messages: Option<&'v Value>,
        schema_version: u64,
    ) -> Option<BTreeMap<&'v str, &'v Value>> {
        if !is_array(messages) || len(messages) > MAX_ATTEMPTS {
            return None;
        }
        let mut by_id: BTreeMap<&str, &Value> = BTreeMap::new();
        for message in array(messages) {
            let id = as_str(get(message, "id")).unwrap_or_default();
            if !self.message(message, schema_version) || by_id.contains_key(id) {
                return None;
            }
            by_id.insert(id, message);
        }
        Some(by_id)
    }

    // MARK: project context

    fn project_context_manifest(&self, manifest: &Value, project_id: Option<&Value>) -> bool {
        if !manifest.is_object() {
            return false;
        }
        let Some((manifest_view, binding)) = self.env.record_without_configuration(manifest) else {
            return false;
        };
        let manifest = manifest_view.as_ref();
        let expected_host: Option<&str> = match binding {
            Some(entry) => entry.host.as_deref(),
            None => self.env.host_for_model(get(manifest, "model")),
        };
        let keys = [
            "schema_version",
            "snapshot_id",
            "project_id",
            "project_name",
            "branch",
            "head_oid",
            "clean",
            "conflicted",
            "captured_at",
            "policy_version",
            "provider_host",
            "model",
            "included",
            "omitted",
            "context_bytes",
            "estimated_tokens",
            "snapshot_sha256",
            "source_fingerprint",
        ];
        let f = |key: &str| get(manifest, key);
        let context_bytes = uint(f("context_bytes"));
        if !exact_keys(manifest, &keys)
            || !exact_schema(f("schema_version"), 1)
            || !canonical_uuid(f("snapshot_id"))
            || !canonical_uuid(f("project_id"))
            || !equal(f("project_id"), project_id)
            || !valid_project_name(f("project_name"))
            || !valid_git_branch(f("branch"))
            || !valid_git_object_id(f("head_oid"))
            || !is_boolean(f("clean"))
            || !is_boolean(f("conflicted"))
            || (f("clean") == Some(&Value::Bool(true))
                && f("conflicted") == Some(&Value::Bool(true)))
            || !canonical_timestamp(f("captured_at"))
            || as_str(f("policy_version")) != Some("chat-read-v1.0.0")
            || as_str(f("provider_host")) != expected_host
            || f("provider_host").is_none()
            || !self.valid_model(f("model"))
            || !is_array(f("included"))
            || len(f("included")) > 32
            || !is_array(f("omitted"))
            || len(f("omitted")) > 5000
            || safe_integer(f("context_bytes"), true).is_none()
            || context_bytes == 0
            || context_bytes > MAX_CONTEXT_BYTES
            || safe_integer(f("estimated_tokens"), true).is_none()
            || uint(f("estimated_tokens")) != context_bytes.div_ceil(4)
            || !canonical_digest(f("snapshot_sha256"))
            || !canonical_digest(f("source_fingerprint"))
        {
            return false;
        }
        let mut included: BTreeSet<String> = BTreeSet::new();
        for item in array(f("included")) {
            let key = format!(
                "{}\n{}",
                as_str(get(item, "path")).unwrap_or_default(),
                as_str(get(item, "source")).unwrap_or_default()
            );
            if !exact_keys(item, &["path", "source", "bytes", "sha256"])
                || !valid_project_path(get(item, "path"))
                || !string_in(
                    get(item, "source"),
                    &["tracked_file", "staged_diff", "worktree_diff"],
                )
                || safe_integer(get(item, "bytes"), true).is_none()
                || uint(get(item, "bytes")) > MAX_CONTEXT_BYTES
                || !canonical_digest(get(item, "sha256"))
                || included.contains(&key)
            {
                return false;
            }
            included.insert(key);
        }
        const REASONS: &[&str] = &[
            "secret_path",
            "generated",
            "lockfile",
            "suspected_secret",
            "binary",
            "invalid_encoding",
            "not_tracked",
            "budget_exceeded",
            "policy",
        ];
        let mut omitted: BTreeSet<String> = BTreeSet::new();
        for item in array(f("omitted")) {
            let key = format!(
                "{}\n{}",
                as_str(get(item, "path")).unwrap_or_default(),
                as_str(get(item, "reason")).unwrap_or_default()
            );
            if !exact_keys(item, &["path", "reason"])
                || !valid_project_path(get(item, "path"))
                || !string_in(get(item, "reason"), REASONS)
                || omitted.contains(&key)
            {
                return false;
            }
            omitted.insert(key);
        }
        true
    }

    fn project_context(&self, context: &Value, project_id: Option<&Value>) -> bool {
        let keys = [
            "schema_version",
            "project_id",
            "status",
            "selected_paths",
            "active_preparation_id",
            "manifest",
            "consent",
            "stale_reason",
            "error_code",
        ];
        let f = |key: &str| get(context, key);
        if !exact_keys(context, &keys)
            || !exact_schema(f("schema_version"), 1)
            || !valid_identifier(project_id, MAX_ID_BYTES)
            || !equal(f("project_id"), project_id)
            || !string_in(
                f("status"),
                &[
                    "setup_required",
                    "checking",
                    "ready",
                    "stale",
                    "partial",
                    "error",
                    "unavailable",
                ],
            )
            || !is_array(f("selected_paths"))
            || len(f("selected_paths")) > 5000
            || !(is_null(f("active_preparation_id"))
                || valid_identifier(f("active_preparation_id"), MAX_ID_BYTES))
            || !(is_null(f("manifest")) || is_dict(f("manifest")))
            || !(is_null(f("consent")) || is_dict(f("consent")))
            || !(is_null(f("stale_reason"))
                || string_in(
                    f("stale_reason"),
                    &[
                        "project_changed",
                        "selection_changed",
                        "model_changed",
                        "provider_changed",
                        "policy_changed",
                        "snapshot_missing",
                    ],
                ))
            || !(is_null(f("error_code")) || valid_project_context_error_code(f("error_code")))
        {
            return false;
        }
        let mut previous: Option<&str> = None;
        for path in array(f("selected_paths")) {
            let Some(text) = as_str(Some(path)) else {
                return false;
            };
            if !valid_project_path(Some(path))
                || previous.is_some_and(|p| string_compare(p, text) != std::cmp::Ordering::Less)
            {
                return false;
            }
            previous = Some(text);
        }
        let manifest = present(f("manifest"));
        let consent = present(f("consent"));
        match manifest {
            None => {
                if consent.is_some() {
                    return false;
                }
            }
            Some(manifest) => {
                if !self.project_context_manifest(manifest, project_id) {
                    return false;
                }
            }
        }
        if let Some(consent) = consent {
            let c = |key: &str| get(consent, key);
            if !exact_keys(
                consent,
                &[
                    "schema_version",
                    "consent_receipt_id",
                    "snapshot_id",
                    "snapshot_sha256",
                    "confirmed_at",
                ],
            ) || !exact_schema(c("schema_version"), 1)
                || !canonical_uuid(c("consent_receipt_id"))
                || !canonical_uuid(c("snapshot_id"))
                || !canonical_digest(c("snapshot_sha256"))
                || !canonical_timestamp(c("confirmed_at"))
                || !equal(c("snapshot_id"), nested(manifest, "snapshot_id"))
                || !equal(c("snapshot_sha256"), nested(manifest, "snapshot_sha256"))
                || as_str(c("confirmed_at")) < as_str(nested(manifest, "captured_at"))
            {
                return false;
            }
        }
        let status = as_str(f("status")).unwrap_or_default();
        let preparation_null = is_null(f("active_preparation_id"));
        let stale_null = is_null(f("stale_reason"));
        let error_null = is_null(f("error_code"));
        let omitted_empty = manifest.is_some_and(|m| len(get(m, "omitted")) == 0);
        let initial_setup = preparation_null && manifest.is_none() && consent.is_none();
        let prepared_setup =
            !preparation_null && manifest.is_some() && omitted_empty && consent.is_none();
        let consent_matches = manifest.is_some()
            && consent.is_some()
            && equal(
                nested(consent, "snapshot_id"),
                nested(manifest, "snapshot_id"),
            )
            && equal(
                nested(consent, "snapshot_sha256"),
                nested(manifest, "snapshot_sha256"),
            );
        match status {
            "checking" => {
                !preparation_null
                    && manifest.is_none()
                    && consent.is_none()
                    && stale_null
                    && error_null
            }
            "setup_required" => stale_null && error_null && (initial_setup || prepared_setup),
            "ready" => {
                preparation_null
                    && manifest.is_some()
                    && omitted_empty
                    && consent_matches
                    && stale_null
                    && error_null
            }
            "partial" => {
                let partial_manifest = manifest.is_some_and(|m| len(get(m, "omitted")) > 0)
                    && stale_null
                    && error_null;
                let partial_prepared = !preparation_null && consent.is_none();
                let partial_confirmed = preparation_null && consent_matches;
                partial_manifest && (partial_prepared || partial_confirmed)
            }
            "stale" => !stale_null && consent.is_none() && preparation_null && error_null,
            "error" => !error_null && consent.is_none() && preparation_null && stale_null,
            "unavailable" => {
                manifest.is_none()
                    && consent.is_none()
                    && preparation_null
                    && stale_null
                    && error_null
            }
            _ => false,
        }
    }

    // MARK: agent journal

    fn agent_root(&self, root: &Value) -> bool {
        let keys = [
            "schema_version",
            "kind",
            "workspace_id",
            "workspace_binding_revision",
            "project_id",
            "root_fingerprint_sha256",
            "capabilities",
        ];
        let f = |key: &str| get(root, key);
        if !exact_keys(root, &keys)
            || !exact_schema(f("schema_version"), 1)
            || !string_in(f("kind"), &["project", "workspace"])
            || !canonical_uuid(f("workspace_id"))
            || safe_integer(f("workspace_binding_revision"), false).is_none()
            || uint(f("workspace_binding_revision")) >= MAX_SAFE_INTEGER
            || !(is_null(f("project_id")) || canonical_uuid(f("project_id")))
            || !canonical_digest(f("root_fingerprint_sha256"))
            || !is_array(f("capabilities"))
            || len(f("capabilities")) > 6
        {
            return false;
        }
        let project = !is_null(f("project_id"));
        if (as_str(f("kind")) == Some("project")) != project {
            return false;
        }
        const ALLOWED: &[&str] = &[
            "file_read",
            "file_write",
            "git_status",
            "git_commit",
            "git_push",
            "guest_service",
        ];
        let mut seen: BTreeSet<&str> = BTreeSet::new();
        for capability in array(f("capabilities")) {
            let Some(name) = as_str(Some(capability)) else {
                return false;
            };
            if !ALLOWED.contains(&name)
                || seen.contains(name)
                || (as_str(f("kind")) == Some("workspace") && name.starts_with("git_"))
            {
                return false;
            }
            seen.insert(name);
        }
        true
    }

    fn agent_policy(&self, policy: &Value) -> bool {
        let f = |key: &str| get(policy, key);
        if !exact_keys(
            policy,
            &[
                "schema_version",
                "policy_version",
                "max_single_write_bytes",
                "max_batch_write_bytes",
                "max_attempt_write_bytes",
            ],
        ) || !exact_schema(f("schema_version"), 1)
            || bounded_text(f("policy_version"), 256, false).is_none()
            || safe_integer(f("max_single_write_bytes"), true).is_none()
            || safe_integer(f("max_batch_write_bytes"), true).is_none()
            || safe_integer(f("max_attempt_write_bytes"), true).is_none()
        {
            return false;
        }
        let single = uint(f("max_single_write_bytes"));
        let batch = uint(f("max_batch_write_bytes"));
        let attempt = uint(f("max_attempt_write_bytes"));
        single == 32768
            && (32768..=524_288).contains(&batch)
            && attempt >= batch
            && attempt <= 4_194_304
    }

    fn transcript_reference(&self, reference: &Value) -> bool {
        let f = |key: &str| get(reference, key);
        exact_keys(
            reference,
            &[
                "schema_version",
                "transcript_ref",
                "generation",
                "transcript_sha256",
                "transcript_bytes",
            ],
        ) && exact_schema(f("schema_version"), 1)
            && canonical_uuid(f("transcript_ref"))
            && safe_integer(f("generation"), true).is_some()
            && canonical_digest(f("transcript_sha256"))
            && safe_integer(f("transcript_bytes"), true).is_some()
            && uint(f("transcript_bytes")) <= MAX_TRANSCRIPT_BYTES
    }

    fn agent_receipt(&self, receipt: &Value) -> bool {
        let keys = [
            "schema_version",
            "call_id",
            "name",
            "arguments_sha256",
            "result_sha256",
            "result_bytes",
            "truncated",
            "duration_ms",
            "outcome",
            "failure_code",
            "approval_reference",
        ];
        let f = |key: &str| get(receipt, key);
        if !exact_keys(receipt, &keys)
            || !exact_schema(f("schema_version"), 1)
            || !valid_opaque_identifier(f("call_id"))
            || !valid_ascii_name(f("name"), 64)
            || !canonical_digest(f("arguments_sha256"))
            || !canonical_digest(f("result_sha256"))
            || safe_integer(f("result_bytes"), true).is_none()
            || uint(f("result_bytes")) > MAX_RESULT_BYTES
            || !is_boolean(f("truncated"))
            || safe_integer(f("duration_ms"), true).is_none()
            || uint(f("duration_ms")) > 24 * 60 * 60 * 1000
            || !string_in(
                f("outcome"),
                &["ok", "failed", "denied", "cancelled", "ambiguous"],
            )
            || !valid_agent_failure_code(f("failure_code"))
            || !(is_null(f("approval_reference"))
                || valid_identifier(f("approval_reference"), MAX_ID_BYTES))
        {
            return false;
        }
        let outcome = as_str(f("outcome")).unwrap_or_default();
        let ambiguous_code = as_str(f("failure_code")) == Some("E_AGENT_EXECUTION_AMBIGUOUS");
        if outcome == "ok" && !is_null(f("failure_code")) {
            return false;
        }
        if matches!(outcome, "failed" | "denied" | "cancelled") && ambiguous_code {
            return false;
        }
        outcome != "ambiguous" || ambiguous_code
    }

    fn agent_call(&self, call: &Value) -> bool {
        let keys = [
            "schema_version",
            "call_id",
            "call_index",
            "name",
            "arguments_sha256",
            "safe_summary_key",
            "access",
            "approval_token",
            "approval_decision",
            "approval_reference",
            "idempotency_key",
            "native_row_revision",
            "receipt",
        ];
        let f = |key: &str| get(call, key);
        if !exact_keys(call, &keys)
            || !exact_schema(f("schema_version"), 3)
            || !valid_opaque_identifier(f("call_id"))
            || safe_integer(f("call_index"), true).is_none()
            || !valid_ascii_name(f("name"), 64)
            || !canonical_digest(f("arguments_sha256"))
            || !valid_agent_summary_key(f("safe_summary_key"))
            || !string_in(
                f("access"),
                &[
                    "auto",
                    "conversation_confirm",
                    "confirm_once",
                    "durable_deny",
                ],
            )
            || !string_in(
                f("approval_decision"),
                &[
                    "pending",
                    "denied",
                    "allow_once",
                    "allow_conversation",
                    "cancelled",
                ],
            )
            || !(is_null(f("approval_token"))
                || valid_identifier(f("approval_token"), MAX_ID_BYTES))
            || !(is_null(f("approval_reference"))
                || valid_identifier(f("approval_reference"), MAX_ID_BYTES))
            || !(is_null(f("idempotency_key")) || canonical_digest(f("idempotency_key")))
            || !(is_null(f("native_row_revision"))
                || safe_integer(f("native_row_revision"), false).is_some())
            || !(is_null(f("receipt")) || is_dict(f("receipt")))
        {
            return false;
        }
        let receipt = present(f("receipt"));
        if receipt.is_some() && is_null(f("native_row_revision")) {
            return false;
        }
        if let Some(receipt) = receipt {
            if !self.agent_receipt(receipt) {
                return false;
            }
            if !equal(get(receipt, "call_id"), f("call_id"))
                || !equal(get(receipt, "name"), f("name"))
                || !equal(get(receipt, "arguments_sha256"), f("arguments_sha256"))
            {
                return false;
            }
            let outcome = as_str(get(receipt, "outcome")).unwrap_or_default();
            let ambiguous_code =
                as_str(get(receipt, "failure_code")) == Some("E_AGENT_EXECUTION_AMBIGUOUS");
            if (outcome == "ok" && !is_null(get(receipt, "failure_code")))
                || (outcome == "ambiguous" && !ambiguous_code)
                || (matches!(outcome, "failed" | "denied" | "cancelled") && ambiguous_code)
            {
                return false;
            }
        }
        let name = as_str(f("name")).unwrap_or_default();
        let access = as_str(f("access")).unwrap_or_default();
        let decision = as_str(f("approval_decision")).unwrap_or_default();
        const AUTO: &[&str] = &[
            "list_dir",
            "read_file",
            "git_status",
            "list_runtime_environments",
        ];
        const CONVERSATION: &[&str] = &[
            "write_file",
            "git_commit",
            "git_push",
            "start_guest_cgi",
            "stop_guest_cgi",
            "install_runtime_environment",
            "run_program",
            "start_runtime_service",
            "stop_runtime_service",
        ];
        if !agent_summary_matches_name(f("safe_summary_key"), f("name")) {
            return false;
        }
        if !REGISTERED_TOOLS.contains(&name) && access != "durable_deny" {
            return false;
        }
        if AUTO.contains(&name)
            && access != "auto"
            && !(name == "list_runtime_environments" && access == "durable_deny")
        {
            return false;
        }
        let guest = crate::runtime_tools::is_guest(name);
        if CONVERSATION.contains(&name)
            && access != "conversation_confirm"
            && !(guest && access == "durable_deny")
        {
            return false;
        }
        let token_null = is_null(f("approval_token"));
        let reference_null = is_null(f("approval_reference"));
        if access == "durable_deny" && (decision != "denied" || !token_null || !reference_null) {
            return false;
        }
        if access == "auto" && (!token_null || !reference_null) {
            return false;
        }
        let gated = matches!(access, "conversation_confirm" | "confirm_once");
        let terminal = matches!(decision, "denied" | "cancelled");
        if gated && token_null && !terminal && !super::grant_reuse::call_shape(call) {
            return false;
        }
        if gated && terminal && (!token_null || !reference_null) {
            return false;
        }
        let Some(receipt) = receipt else { return true };
        if !(self.agent_receipt(receipt)
            && equal(get(receipt, "call_id"), f("call_id"))
            && equal(get(receipt, "name"), f("name"))
            && equal(get(receipt, "arguments_sha256"), f("arguments_sha256")))
        {
            return false;
        }
        !(access != "durable_deny"
            && decision == "denied"
            && (as_str(get(receipt, "outcome")) != Some("denied")
                || as_str(get(receipt, "failure_code")) != Some("E_AGENT_DENIED_BY_USER")
                || !is_null(get(receipt, "approval_reference"))))
    }

    fn agent_journal(&self, journal: &Value) -> bool {
        let keys = [
            "schema_version",
            "phase",
            "controller_generation",
            "policy",
            "root",
            "tool_registry_version",
            "toolset_sha256",
            "transcript",
            "round_index",
            "round_lineage",
            "call_index",
            "batch",
            "frozen_grant_ids",
            "reserved_write_bytes",
            "updated_at",
        ];
        let f = |key: &str| get(journal, key);
        const PHASES: &[&str] = &[
            "ready_for_round",
            "round_in_flight",
            "batch_frozen",
            "approval_pending",
            "execution_intent",
            "tool_result_pending",
            "final_response",
            "cancelled",
            "failed",
            "unknown",
            "ambiguous",
        ];
        if !exact_keys(journal, &keys)
            || !exact_schema(f("schema_version"), 3)
            || !string_in(f("phase"), PHASES)
            || safe_integer(f("controller_generation"), true).is_none()
            || !is_dict(f("policy"))
            || !self.agent_policy(f("policy").expect("checked"))
            || !is_dict(f("root"))
            || !self.agent_root(f("root").expect("checked"))
            || (!exact_schema(f("tool_registry_version"), 1)
                && !exact_schema(f("tool_registry_version"), 2)
                && !exact_schema(f("tool_registry_version"), 3))
            || !canonical_digest(f("toolset_sha256"))
            || !is_dict(f("transcript"))
            || !self.transcript_reference(f("transcript").expect("checked"))
            || safe_integer(f("round_index"), true).is_none()
            || uint(f("round_index")) >= 8
            || !(is_null(f("round_lineage")) || is_dict(f("round_lineage")))
            || !(is_null(f("call_index")) || safe_integer(f("call_index"), true).is_some())
            || !is_array(f("batch"))
            || len(f("batch")) > 16
            || !is_array(f("frozen_grant_ids"))
            || len(f("frozen_grant_ids")) > 2
            || safe_integer(f("reserved_write_bytes"), true).is_none()
            || uint(f("reserved_write_bytes"))
                > uint(nested(f("policy"), "max_attempt_write_bytes"))
            || !canonical_timestamp(f("updated_at"))
        {
            return false;
        }
        let batch = array(f("batch"));
        let mut call_ids: BTreeSet<&str> = BTreeSet::new();
        for (index, call) in batch.iter().enumerate() {
            let call_id = as_str(get(call, "call_id")).unwrap_or_default();
            if !self.agent_call(call)
                || uint(get(call, "call_index")) != index as u64
                || call_ids.contains(call_id)
                || (super::grant_reuse::call_shape(call)
                    && !super::grant_reuse::journal_call_bound(call, journal))
            {
                return false;
            }
            call_ids.insert(call_id);
        }
        if !is_null(f("call_index")) && uint(f("call_index")) >= batch.len() as u64 {
            return false;
        }
        let mut grant_ids: BTreeSet<&str> = BTreeSet::new();
        for grant_id in array(f("frozen_grant_ids")) {
            let text = as_str(Some(grant_id)).unwrap_or_default();
            if !canonical_uuid(Some(grant_id)) || grant_ids.contains(text) {
                return false;
            }
            grant_ids.insert(text);
        }
        let lineage = present(f("round_lineage"));
        if let Some(lineage) = lineage {
            let l = |key: &str| get(lineage, key);
            if !exact_keys(
                lineage,
                &[
                    "schema_version",
                    "round_id",
                    "round_index",
                    "launch_attempt",
                    "status",
                    "native_row_revision",
                ],
            ) || !exact_schema(l("schema_version"), 2)
                || !canonical_uuid(l("round_id"))
                || safe_integer(l("round_index"), true).is_none()
                || uint(l("round_index")) != uint(f("round_index"))
                || safe_integer(l("launch_attempt"), false).is_none()
                || uint(l("launch_attempt")) > 8
                || !string_in(
                    l("status"),
                    &[
                        "ready",
                        "active",
                        "failed_retryable",
                        "completed",
                        "cancel_requested",
                        "cancelled",
                        "unknown",
                        "ambiguous",
                    ],
                )
                || !(is_null(l("native_row_revision"))
                    || safe_integer(l("native_row_revision"), false).is_some())
            {
                return false;
            }
        }
        let phase = as_str(f("phase")).unwrap_or_default();
        let lineage_status = as_str(nested(lineage, "status"));
        let call_index_null = is_null(f("call_index"));
        if phase == "ready_for_round"
            && (!call_index_null
                || !batch.is_empty()
                || (lineage.is_some() && lineage_status != Some("ready")))
        {
            return false;
        }
        if phase == "round_in_flight"
            && (lineage.is_none() || !matches!(lineage_status, Some("active" | "cancel_requested")))
        {
            return false;
        }
        if matches!(
            phase,
            "batch_frozen" | "approval_pending" | "tool_result_pending"
        ) && (lineage.is_none() || lineage_status != Some("completed"))
        {
            return false;
        }
        if phase == "approval_pending" {
            let pending = batch.iter().any(|call| {
                !matches!(as_str(get(call, "access")), Some("auto" | "durable_deny"))
                    && as_str(get(call, "approval_decision")) == Some("pending")
            });
            if !pending {
                return false;
            }
        }
        if phase == "execution_intent" {
            if lineage.is_none()
                || !matches!(lineage_status, Some("completed" | "cancel_requested"))
                || call_index_null
            {
                return false;
            }
            let Some(call) = batch.get(uint(f("call_index")) as usize) else {
                return false;
            };
            if is_null(get(call, "idempotency_key"))
                || (as_str(get(call, "access")) != Some("auto")
                    && !matches!(
                        as_str(get(call, "approval_decision")),
                        Some("allow_once" | "allow_conversation")
                    ))
            {
                return false;
            }
        }
        if phase == "tool_result_pending" {
            if call_index_null {
                return false;
            }
            let Some(call) = batch.get(uint(f("call_index")) as usize) else {
                return false;
            };
            let outcome = as_str(nested(get(call, "receipt"), "outcome"));
            if is_null(get(call, "receipt")) || !matches!(outcome, Some("ok" | "failed" | "denied"))
            {
                return false;
            }
        }
        if phase == "cancelled" {
            if lineage.is_none()
                && (uint(f("round_index")) != 0
                    || !batch.is_empty()
                    || !call_index_null
                    || uint(f("reserved_write_bytes")) != 0)
            {
                return false;
            }
            for call in batch {
                if is_null(get(call, "receipt"))
                    && !matches!(
                        as_str(get(call, "approval_decision")),
                        Some("denied" | "cancelled")
                    )
                {
                    return false;
                }
            }
        }
        true
    }

    fn agent_grant(&self, grant: &Value) -> bool {
        let keys = [
            "schema_version",
            "grant_id",
            "conversation_id",
            "workspace_id",
            "project_id",
            "binding_revision",
            "root_fingerprint_sha256",
            "tool_family",
            "registry_version",
            "policy_version",
            "issued_for",
            "created_at",
        ];
        let f = |key: &str| get(grant, key);
        let family = as_str(f("tool_family")).unwrap_or_default();
        let issued = f("issued_for");
        !(!exact_keys(grant, &keys)
            || !exact_schema(f("schema_version"), 2)
            || !canonical_uuid(f("grant_id"))
            || !valid_identifier(f("conversation_id"), MAX_ID_BYTES)
            || !canonical_uuid(f("workspace_id"))
            || !(is_null(f("project_id")) || canonical_uuid(f("project_id")))
            || safe_integer(f("binding_revision"), false).is_none()
            || uint(f("binding_revision")) >= MAX_SAFE_INTEGER
            || !canonical_digest(f("root_fingerprint_sha256"))
            || !string_in(
                f("tool_family"),
                &["file_write", "git_commit", "git_push", "guest_service"],
            )
            || (matches!(family, "git_commit" | "git_push") && is_null(f("project_id")))
            || (!exact_schema(f("registry_version"), 1)
                && !exact_schema(f("registry_version"), 2)
                && !exact_schema(f("registry_version"), 3))
            || (family == "guest_service"
                && !exact_schema(f("registry_version"), 2)
                && !exact_schema(f("registry_version"), 3))
            || bounded_text(f("policy_version"), 256, false).is_none()
            || !is_dict(issued)
            || !exact_keys(
                issued.expect("checked"),
                &["schema_version", "task_id", "attempt_id"],
            )
            || !exact_schema(nested(issued, "schema_version"), 1)
            || !canonical_uuid(nested(issued, "task_id"))
            || !canonical_uuid(nested(issued, "attempt_id"))
            || !canonical_timestamp(f("created_at")))
    }

    fn cleanup(&self, cleanup: &Value) -> bool {
        let f = |key: &str| get(cleanup, key);
        exact_keys(
            cleanup,
            &[
                "schema_version",
                "cleanup_id",
                "conversation_id",
                "task_id",
                "attempt_id",
                "transcript_ref",
                "transcript_sha256",
                "reason",
                "created_at",
            ],
        ) && exact_schema(f("schema_version"), 1)
            && canonical_uuid(f("cleanup_id"))
            && valid_identifier(f("conversation_id"), MAX_ID_BYTES)
            && canonical_uuid(f("task_id"))
            && canonical_uuid(f("attempt_id"))
            && canonical_uuid(f("transcript_ref"))
            && canonical_digest(f("transcript_sha256"))
            && string_in(
                f("reason"),
                &["completed", "cancelled", "failed", "conversation_deleted"],
            )
            && canonical_timestamp(f("created_at"))
    }

    fn project_context_receipt(&self, receipt: Option<&Value>) -> bool {
        if is_null(receipt) {
            return true;
        }
        let Some(receipt) = receipt else { return false };
        let f = |key: &str| get(receipt, key);
        exact_keys(
            receipt,
            &[
                "schema_version",
                "snapshot_id",
                "snapshot_sha256",
                "source_fingerprint",
                "context_bytes",
                "verified_at",
            ],
        ) && exact_schema(f("schema_version"), 1)
            && canonical_uuid(f("snapshot_id"))
            && canonical_digest(f("snapshot_sha256"))
            && canonical_digest(f("source_fingerprint"))
            && safe_integer(f("context_bytes"), true).is_some()
            && uint(f("context_bytes")) > 0
            && uint(f("context_bytes")) <= MAX_CONTEXT_BYTES
            && canonical_timestamp(f("verified_at"))
    }

    fn attempt_project_context(&self, context: &Value) -> bool {
        let f = |key: &str| get(context, key);
        exact_keys(
            context,
            &[
                "schema_version",
                "runtime_context_id",
                "project_id",
                "snapshot_id",
                "snapshot_sha256",
                "source_fingerprint",
                "context_bytes",
                "consent_receipt_id",
                "provider",
                "policy",
                "policy_version",
            ],
        ) && exact_schema(f("schema_version"), 1)
            && canonical_uuid(f("runtime_context_id"))
            && valid_identifier(f("project_id"), MAX_ID_BYTES)
            && canonical_uuid(f("snapshot_id"))
            && canonical_digest(f("snapshot_sha256"))
            && canonical_digest(f("source_fingerprint"))
            && safe_integer(f("context_bytes"), true).is_some()
            && uint(f("context_bytes")) > 0
            && uint(f("context_bytes")) <= MAX_CONTEXT_BYTES
            && canonical_uuid(f("consent_receipt_id"))
            && self.env.provider_id(f("provider"))
            && as_str(f("policy")) == Some("chat-read-v1")
            && as_str(f("policy_version")) == Some("chat-read-v1.0.0")
    }

    fn round_receipt(&self, receipt: &Value) -> bool {
        if !receipt.is_object() {
            return false;
        }
        let Some((receipt_view, _)) = self.env.record_without_configuration(receipt) else {
            return false;
        };
        let receipt = receipt_view.as_ref();
        let keys = [
            "schema_version",
            "transport_schema_version",
            "turn_id",
            "attempt_id",
            "round_id",
            "round_index",
            "provider_request_id",
            "provider_response_id",
            "requested_model",
            "model",
            "thinking_mode",
            "finish_reason",
            "latency_ms",
            "visible_history_sha256",
            "model_input_sha256",
            "request_body_sha256",
            "project_context_receipt",
        ];
        let f = |key: &str| get(receipt, key);
        !(!exact_keys_with_optional(receipt, &keys, &["harness_id"])
            || (f("harness_id").is_some()
                && as_str(f("harness_id")) != self.env.harness_for_model(f("model")))
            || !exact_schema(f("schema_version"), 1)
            || safe_integer(f("transport_schema_version"), false).is_none()
            || !matches!(
                safe_integer(f("transport_schema_version"), false),
                Some(2 | 3)
            )
            || !canonical_uuid(f("turn_id"))
            || !canonical_uuid(f("attempt_id"))
            || !canonical_uuid(f("round_id"))
            || safe_integer(f("round_index"), true).is_none()
            || uint(f("round_index")) >= 8
            || !canonical_uuid(f("provider_request_id"))
            || !valid_opaque_identifier(f("provider_response_id"))
            || !self.valid_model(f("requested_model"))
            || !self.valid_model(f("model"))
            || !valid_thinking_mode(f("thinking_mode"))
            || !string_in(
                f("finish_reason"),
                &["stop", "tool_calls", "length", "content_filter"],
            )
            || safe_integer(f("latency_ms"), true).is_none()
            || !canonical_digest(f("visible_history_sha256"))
            || !canonical_digest(f("model_input_sha256"))
            || !canonical_digest(f("request_body_sha256"))
            || !(is_null(f("project_context_receipt")) || is_dict(f("project_context_receipt")))
            || !self.project_context_receipt(f("project_context_receipt")))
    }

    fn turn(&self, turn: &Value) -> bool {
        let f = |key: &str| get(turn, key);
        if !exact_keys(
            turn,
            &[
                "schema_version",
                "turn_id",
                "user_message_id",
                "attempt_ids",
                "created_at",
            ],
        ) || !exact_schema(f("schema_version"), 1)
            || !canonical_uuid(f("turn_id"))
            || !valid_identifier(f("user_message_id"), MAX_ID_BYTES)
            || !is_array(f("attempt_ids"))
            || len(f("attempt_ids")) == 0
            || len(f("attempt_ids")) > MAX_ATTEMPTS
            || !canonical_timestamp(f("created_at"))
        {
            return false;
        }
        let mut ids: BTreeSet<&str> = BTreeSet::new();
        for attempt_id in array(f("attempt_ids")) {
            let text = as_str(Some(attempt_id)).unwrap_or_default();
            if !canonical_uuid(Some(attempt_id)) || ids.contains(text) {
                return false;
            }
            ids.insert(text);
        }
        true
    }

    fn attempt(&self, attempt: &Value, schema_version: u64) -> bool {
        let workspace_routing = schema_version >= 8;
        let agent_schema = schema_version >= 9;
        let mut keys: Vec<&str> = vec![
            "schema_version",
            "attempt_id",
            "turn_id",
            "status",
            "visible_message_ids",
            "visible_history_sha256",
            "attachment_ids",
            "model_id",
            "thinking_mode",
            "context_disposition",
            "context_project_id",
            "project_context",
            "active_round",
            "rounds",
            "assistant_message_id",
            "failure_code",
            "created_at",
            "updated_at",
        ];
        if workspace_routing {
            keys.extend(["workspace_id", "workspace_binding_revision"]);
        }
        if agent_schema {
            keys.extend(["journal_revision", "agent"]);
        }
        let f = |key: &str| get(attempt, key);
        if !exact_keys_with_optional(attempt, &keys, &["harness_id"])
            || (f("harness_id").is_some()
                && as_str(f("harness_id")) != self.env.harness_for_model(f("model_id")))
            || !exact_schema(f("schema_version"), if agent_schema { 3 } else { 1 })
            || !canonical_uuid(f("attempt_id"))
            || !canonical_uuid(f("turn_id"))
            || !string_in(
                f("status"),
                &["prepared", "sending", "completed", "failed", "cancelled"],
            )
            || !is_array(f("visible_message_ids"))
            || len(f("visible_message_ids")) > MAX_VISIBLE_MESSAGES
            || !is_array(f("attachment_ids"))
            || len(f("attachment_ids")) > MAX_VISIBLE_ATTACHMENTS
            || !self.valid_model(f("model_id"))
            || !valid_thinking_mode(f("thinking_mode"))
            || !string_in(
                f("context_disposition"),
                &["unbound", "verified", "explicit_without_context"],
            )
            || !(is_null(f("context_project_id"))
                || valid_identifier(f("context_project_id"), MAX_ID_BYTES))
            || !(is_null(f("project_context")) || is_dict(f("project_context")))
            || !(is_null(f("active_round")) || is_dict(f("active_round")))
            || !is_array(f("rounds"))
            || len(f("rounds")) > 8
            || !(is_null(f("assistant_message_id"))
                || valid_identifier(f("assistant_message_id"), MAX_ID_BYTES))
            || !valid_attempt_failure_code(f("failure_code"))
            || !canonical_timestamp(f("created_at"))
            || !canonical_timestamp(f("updated_at"))
            || as_str(f("created_at")) > as_str(f("updated_at"))
        {
            return false;
        }
        let mut visible: BTreeSet<&str> = BTreeSet::new();
        for message_id in array(f("visible_message_ids")) {
            let text = as_str(Some(message_id)).unwrap_or_default();
            if !valid_identifier(Some(message_id), MAX_ID_BYTES) || visible.contains(text) {
                return false;
            }
            visible.insert(text);
        }
        let mut attachments: BTreeSet<&str> = BTreeSet::new();
        for attachment_id in array(f("attachment_ids")) {
            let text = as_str(Some(attachment_id)).unwrap_or_default();
            if !valid_identifier(Some(attachment_id), MAX_ID_BYTES) || attachments.contains(text) {
                return false;
            }
            attachments.insert(text);
        }
        if !is_null(f("visible_history_sha256")) && !canonical_digest(f("visible_history_sha256")) {
            return false;
        }
        if workspace_routing {
            let has_workspace = !is_null(f("workspace_id"));
            let has_revision = !is_null(f("workspace_binding_revision"));
            if has_workspace != has_revision
                || (has_workspace && !canonical_uuid(f("workspace_id")))
                || (has_revision && safe_integer(f("workspace_binding_revision"), false).is_none())
            {
                return false;
            }
        }
        let context = present(f("project_context"));
        let disposition = as_str(f("context_disposition")).unwrap_or_default();
        let verified = disposition == "verified";
        if context.is_some() != verified
            || (disposition == "unbound"
                && (context.is_some() || !is_null(f("context_project_id"))))
            || (disposition == "explicit_without_context"
                && (context.is_some() || is_null(f("context_project_id"))))
            || (verified
                && (is_null(f("context_project_id"))
                    || !equal(nested(context, "project_id"), f("context_project_id"))))
        {
            return false;
        }
        if let Some(context) = context {
            if !self.attempt_project_context(context)
                || !equal(get(context, "project_id"), f("context_project_id"))
            {
                return false;
            }
        }
        for round in array(f("rounds")) {
            if !self.round_receipt(round) {
                return false;
            }
        }
        if let Some(active) = present(f("active_round")) {
            if !exact_keys(active, &["round_id", "round_index"])
                || !canonical_uuid(get(active, "round_id"))
                || safe_integer(get(active, "round_index"), true).is_none()
                || uint(get(active, "round_index")) >= 8
                || uint(get(active, "round_index")) != len(f("rounds")) as u64
            {
                return false;
            }
        }
        let status = as_str(f("status")).unwrap_or_default();
        let sending = status == "sending";
        if sending == is_null(f("active_round"))
            || (status == "completed") == is_null(f("assistant_message_id"))
            || (status == "failed") == is_null(f("failure_code"))
            || (status == "cancelled" && !is_null(f("failure_code")))
            || (status != "completed" && !is_null(f("assistant_message_id")))
            || (matches!(status, "prepared" | "sending") && !is_null(f("failure_code")))
            || (len(f("rounds")) > 0 && is_null(f("visible_history_sha256")))
        {
            return false;
        }
        if agent_schema {
            let revision_ok = safe_integer(f("journal_revision"), true).is_some();
            if !revision_ok || (!is_dict(f("agent")) && !is_null(f("agent"))) {
                return false;
            }
            if is_null(f("agent")) {
                if uint(f("journal_revision")) != 0 {
                    return false;
                }
            } else if uint(f("journal_revision")) < 1
                || !self.agent_journal(f("agent").expect("checked"))
            {
                return false;
            }
        }
        true
    }

    fn frozen_attempt_equal(&self, left: &Value, right: &Value) -> bool {
        [
            "visible_message_ids",
            "attachment_ids",
            "model_id",
            "thinking_mode",
            "context_disposition",
            "context_project_id",
            "workspace_id",
            "workspace_binding_revision",
            "project_context",
        ]
        .iter()
        .all(|key| equal(get(left, key), get(right, key)))
    }

    // MARK: conversation

    #[allow(clippy::too_many_lines)]
    fn conversation<'v>(
        &self,
        conversation: &'v Value,
        schema_version: u64,
    ) -> Option<BTreeMap<&'v str, &'v Value>> {
        let project_context_shape = schema_version >= 6;
        let workspace_routing = schema_version >= 8;
        let agent_schema = schema_version >= 9;
        let required: Vec<&str>;
        let mut optional: Vec<&str> = Vec::new();
        if schema_version <= 2 {
            required = vec![
                "id",
                "title",
                "title_source",
                "model_id",
                "messages",
                "created_at",
                "updated_at",
            ];
            optional.push("thinking_mode");
        } else if schema_version <= 4 {
            required = vec![
                "id",
                "project_id",
                "title",
                "title_source",
                "model_id",
                "thinking_mode",
                "messages",
                "created_at",
                "updated_at",
            ];
        } else if schema_version == 5 {
            required = vec![
                "id",
                "project_id",
                "workspace_id",
                "title",
                "title_source",
                "model_id",
                "thinking_mode",
                "messages",
                "created_at",
                "updated_at",
            ];
        } else {
            let mut base = vec![
                "id",
                "project_id",
                "workspace_id",
                "runtime_context_id",
                "project_context",
                "title",
                "title_source",
                "model_id",
                "thinking_mode",
                "messages",
                "turns",
                "attempts",
                "created_at",
                "updated_at",
            ];
            if workspace_routing {
                base.extend(["workspace_binding", "workspace_bootstrap_state"]);
            }
            if agent_schema {
                base.push("agent_grants");
            }
            required = base;
        }
        let f = |key: &str| get(conversation, key);
        if !keys(conversation, &required, &optional)
            || !valid_identifier(f("id"), MAX_ID_BYTES)
            || bounded_text(f("title"), MAX_TITLE_BYTES, false).is_none()
            || !string_in(f("title_source"), &["auto", "manual"])
            || !self.valid_model(f("model_id"))
            || (f("thinking_mode").is_some() && !valid_thinking_mode(f("thinking_mode")))
            || !is_array(f("messages"))
            || !valid_timestamp_pair(f("created_at"), f("updated_at"))
        {
            return None;
        }
        let mut project_id: Option<&Value> = None;
        if schema_version > 2 && !is_null(f("project_id")) {
            if !valid_identifier(f("project_id"), MAX_ID_BYTES) {
                return None;
            }
            project_id = f("project_id");
        }
        if project_context_shape
            && !is_null(f("runtime_context_id"))
            && !canonical_uuid(f("runtime_context_id"))
        {
            return None;
        }
        if project_context_shape
            && !(is_null(f("project_context")) || is_dict(f("project_context")))
        {
            return None;
        }
        let context = if project_context_shape {
            present(f("project_context"))
        } else {
            None
        };
        if project_id.is_none() != context.is_none() {
            return None;
        }
        if let Some(context) = context {
            if !self.project_context(context, project_id) {
                return None;
            }
        }
        let context_sendable =
            context.is_some_and(|c| matches!(as_str(get(c, "status")), Some("ready" | "partial")));
        if context_sendable {
            let manifest = present(nested(context, "manifest"));
            if is_null(f("runtime_context_id"))
                || manifest.is_none()
                || !equal(nested(manifest, "model"), f("model_id"))
            {
                return None;
            }
        }
        if workspace_routing {
            let workspace_id = f("workspace_id");
            if !is_null(workspace_id) && !valid_identifier(workspace_id, MAX_ID_BYTES) {
                return None;
            }
            if !string_in(
                f("workspace_bootstrap_state"),
                &[
                    "none",
                    "pending_legacy_project",
                    "pending_registry_resolution",
                    "blocked_invalid_legacy_id",
                    "blocked_missing_legacy_workspace",
                ],
            ) {
                return None;
            }
            let binding = f("workspace_binding");
            if !is_null(binding) {
                let binding = binding.filter(|b| b.is_object())?;
                let b = |key: &str| get(binding, key);
                if !exact_keys(
                    binding,
                    &[
                        "schema_version",
                        "workspace_id",
                        "binding_revision",
                        "project_id",
                    ],
                ) || !exact_schema(b("schema_version"), 1)
                    || !canonical_uuid(b("workspace_id"))
                    || safe_integer(b("binding_revision"), false).is_none()
                    || uint(b("binding_revision")) >= MAX_SAFE_INTEGER
                    || !(is_null(b("project_id"))
                        || valid_identifier(b("project_id"), MAX_ID_BYTES))
                    || !equal(b("workspace_id"), workspace_id)
                    || !equal_or_null(b("project_id"), project_id)
                    || as_str(f("workspace_bootstrap_state")) != Some("none")
                {
                    return None;
                }
            } else if !is_null(workspace_id)
                && as_str(f("workspace_bootstrap_state")) == Some("none")
            {
                return None;
            }
        } else if schema_version >= 5 && !string_or_null(f("workspace_id")) {
            return None;
        }
        if context_sendable
            && workspace_routing
            && as_str(f("workspace_bootstrap_state")) == Some("none")
            && is_null(f("workspace_binding"))
        {
            return None;
        }

        let messages_by_id = self.messages(f("messages"), schema_version)?;
        if messages_by_id
            .values()
            .any(|message| as_str(get(message, "created_at")) > as_str(f("updated_at")))
        {
            return None;
        }
        let mut attempts_by_id: BTreeMap<&str, &Value> = BTreeMap::new();
        let mut turn_ids: BTreeSet<&str> = BTreeSet::new();
        let mut referenced_attempts: BTreeSet<&str> = BTreeSet::new();
        let mut message_indexes: BTreeMap<&str, usize> = BTreeMap::new();
        let mut attempt_message_references = 0usize;
        let mut turn_attempt_references = 0usize;
        let messages = array(f("messages"));
        for (index, message) in messages.iter().enumerate() {
            message_indexes.insert(as_str(get(message, "id")).unwrap_or_default(), index);
        }
        let turns: &[Value] = if project_context_shape {
            array(f("turns"))
        } else {
            &[]
        };
        let attempts: &[Value] = if project_context_shape {
            array(f("attempts"))
        } else {
            &[]
        };
        if project_context_shape
            && (!is_array(f("turns"))
                || len(f("turns")) > MAX_TURNS
                || !is_array(f("attempts"))
                || len(f("attempts")) > MAX_ATTEMPTS)
        {
            return None;
        }
        for turn in turns {
            let turn_id = as_str(get(turn, "turn_id")).unwrap_or_default();
            if !self.turn(turn) || turn_ids.contains(turn_id) {
                return None;
            }
            turn_ids.insert(turn_id);
            let user_id = as_str(get(turn, "user_message_id")).unwrap_or_default();
            let user_message = messages_by_id.get(user_id)?;
            if as_str(get(user_message, "role")) != Some("user")
                || !equal(get(user_message, "created_at"), get(turn, "created_at"))
            {
                return None;
            }
        }
        let mut previous_user_index: Option<usize> = None;
        for turn in turns {
            let user_index = message_indexes
                .get(as_str(get(turn, "user_message_id")).unwrap_or_default())
                .copied()
                .unwrap_or(0);
            if previous_user_index.is_some_and(|previous| user_index <= previous) {
                return None;
            }
            previous_user_index = Some(user_index);
        }
        for attempt in attempts {
            let attempt_id = as_str(get(attempt, "attempt_id")).unwrap_or_default();
            if !self.attempt(attempt, schema_version)
                || attempts_by_id.contains_key(attempt_id)
                || !turn_ids.contains(as_str(get(attempt, "turn_id")).unwrap_or_default())
            {
                return None;
            }
            let agent_attempt = agent_schema && is_dict(get(attempt, "agent"));
            attempt_message_references += len(get(attempt, "visible_message_ids"));
            if attempt_message_references > 1_000_000 {
                return None;
            }
            for message_id in array(get(attempt, "visible_message_ids")) {
                if !messages_by_id.contains_key(as_str(Some(message_id)).unwrap_or_default()) {
                    return None;
                }
            }
            let attempt_turn = turns.iter().find(|turn| {
                array(get(turn, "attempt_ids"))
                    .iter()
                    .any(|id| id == get(attempt, "attempt_id").unwrap_or(&Value::Null))
            });
            let attempt_turn = attempt_turn?;
            let user_index = message_indexes
                .get(as_str(get(attempt_turn, "user_message_id")).unwrap_or_default())
                .copied()
                .unwrap_or(0);
            let expected_start = (user_index + 1).saturating_sub(MAX_VISIBLE_MESSAGES);
            let expected_length = user_index + 1 - expected_start;
            let visible = array(get(attempt, "visible_message_ids"));
            if visible.len() != expected_length {
                return None;
            }
            for (index, visible_id) in visible.iter().enumerate() {
                let expected_id = messages
                    .get(expected_start + index)
                    .and_then(|m| get(m, "id"));
                if !equal(expected_id, Some(visible_id)) {
                    return None;
                }
            }
            let mut expected_attachment_ids: Vec<&Value> = Vec::new();
            let mut seen_attachment_ids: BTreeSet<&str> = BTreeSet::new();
            let mut attachment_occurrences = 0usize;
            let mut attachment_bytes = 0u64;
            for message_id in visible {
                let message = messages_by_id
                    .get(as_str(Some(message_id)).unwrap_or_default())
                    .copied();
                for attachment in array(nested(message, "attachments")) {
                    attachment_occurrences += 1;
                    attachment_bytes += uint(get(attachment, "size"));
                    let id = as_str(get(attachment, "id")).unwrap_or_default();
                    if !seen_attachment_ids.contains(id) {
                        seen_attachment_ids.insert(id);
                        if let Some(value) = get(attachment, "id") {
                            expected_attachment_ids.push(value);
                        }
                    }
                }
            }
            let expected_ids: Vec<Value> = expected_attachment_ids.into_iter().cloned().collect();
            if attachment_occurrences > MAX_VISIBLE_ATTACHMENTS
                || attachment_bytes > MAX_ATTACHMENT_BYTES
                || get(attempt, "attachment_ids") != Some(&Value::Array(expected_ids))
            {
                return None;
            }
            let rounds = array(get(attempt, "rounds"));
            for (round_index, round) in rounds.iter().enumerate() {
                if !equal(get(round, "turn_id"), get(attempt, "turn_id"))
                    || !equal(get(round, "attempt_id"), get(attempt, "attempt_id"))
                    || uint(get(round, "round_index")) != round_index as u64
                    || !equal(get(round, "requested_model"), get(attempt, "model_id"))
                    || !equal(get(round, "model"), get(attempt, "model_id"))
                    || !equal(get(round, "thinking_mode"), get(attempt, "thinking_mode"))
                    || (!agent_attempt
                        && !equal(
                            get(round, "visible_history_sha256"),
                            get(attempt, "visible_history_sha256"),
                        ))
                {
                    return None;
                }
                if round_index + 1 < rounds.len()
                    && as_str(get(round, "finish_reason")) != Some("tool_calls")
                {
                    return None;
                }
                let attempt_context = present(get(attempt, "project_context"));
                let has_context = attempt_context.is_some();
                let transport = safe_integer(get(round, "transport_schema_version"), false);
                if (has_context
                    && (transport != Some(3) || is_null(get(round, "project_context_receipt"))))
                    || (!has_context
                        && (transport != Some(2)
                            || !is_null(get(round, "project_context_receipt"))))
                {
                    return None;
                }
                if let Some(attempt_context) = attempt_context {
                    let receipt = get(round, "project_context_receipt");
                    if !equal(
                        nested(receipt, "snapshot_id"),
                        get(attempt_context, "snapshot_id"),
                    ) || !equal(
                        nested(receipt, "snapshot_sha256"),
                        get(attempt_context, "snapshot_sha256"),
                    ) || !equal(
                        nested(receipt, "source_fingerprint"),
                        get(attempt_context, "source_fingerprint"),
                    ) || !equal(
                        nested(receipt, "context_bytes"),
                        get(attempt_context, "context_bytes"),
                    ) {
                        return None;
                    }
                }
            }
            attempts_by_id.insert(attempt_id, attempt);
        }
        let conversation_binding = if workspace_routing {
            present(f("workspace_binding"))
        } else {
            None
        };
        for attempt in attempts {
            let has_workspace = !is_null(get(attempt, "workspace_id"));
            let has_revision = !is_null(get(attempt, "workspace_binding_revision"));
            let status = as_str(get(attempt, "status")).unwrap_or_default();
            if workspace_routing {
                if has_workspace != has_revision {
                    return None;
                }
                if has_workspace
                    && (conversation_binding.is_none()
                        || !equal(
                            get(attempt, "workspace_id"),
                            nested(conversation_binding, "workspace_id"),
                        )
                        || !equal(
                            get(attempt, "workspace_binding_revision"),
                            nested(conversation_binding, "binding_revision"),
                        ))
                {
                    return None;
                }
                if matches!(status, "prepared" | "sending")
                    && as_str(f("workspace_bootstrap_state")) == Some("none")
                    && project_id.is_some()
                    && (conversation_binding.is_none()
                        || !has_workspace
                        || !equal(
                            get(attempt, "context_project_id"),
                            nested(conversation_binding, "project_id"),
                        ))
                {
                    return None;
                }
            }
            if !is_null(get(attempt, "project_context"))
                && !equal(
                    nested(get(attempt, "project_context"), "runtime_context_id"),
                    f("runtime_context_id"),
                )
            {
                return None;
            }
            if !is_null(get(attempt, "project_context"))
                && (project_id.is_none()
                    || !equal(
                        nested(get(attempt, "project_context"), "project_id"),
                        project_id,
                    ))
            {
                return None;
            }
            if matches!(status, "prepared" | "sending")
                && !equal_or_null(get(attempt, "context_project_id"), project_id)
            {
                return None;
            }
        }
        let mut assistant_references: BTreeSet<&str> = BTreeSet::new();
        for turn in turns {
            let mut known_visible_history: Option<&str> = None;
            let mut completed_attempts = 0usize;
            let turn_attempt_ids = array(get(turn, "attempt_ids"));
            for (attempt_index, attempt_id_value) in turn_attempt_ids.iter().enumerate() {
                let attempt_id = as_str(Some(attempt_id_value)).unwrap_or_default();
                turn_attempt_references += 1;
                if turn_attempt_references > MAX_ATTEMPTS {
                    return None;
                }
                let attempt = attempts_by_id.get(attempt_id).copied()?;
                if !equal(get(attempt, "turn_id"), get(turn, "turn_id"))
                    || referenced_attempts.contains(attempt_id)
                {
                    return None;
                }
                referenced_attempts.insert(attempt_id);
                if attempt_index == 0 && !equal(get(attempt, "created_at"), get(turn, "created_at"))
                {
                    return None;
                }
                let status = as_str(get(attempt, "status")).unwrap_or_default();
                if attempt_index + 1 < turn_attempt_ids.len()
                    && !matches!(status, "failed" | "cancelled")
                {
                    return None;
                }
                if attempt_index > 0 {
                    let first = turn_attempt_ids.first().and_then(|id| {
                        attempts_by_id
                            .get(as_str(Some(id)).unwrap_or_default())
                            .copied()
                    });
                    let first = first?;
                    if !self.frozen_attempt_equal(first, attempt) {
                        return None;
                    }
                }
                let visible_history = as_str(present(get(attempt, "visible_history_sha256")));
                match (visible_history, known_visible_history) {
                    (None, Some(_)) => return None,
                    (Some(history), None) => known_visible_history = Some(history),
                    (Some(history), Some(known)) if history != known => return None,
                    _ => {}
                }
                let agent_attempt = agent_schema && is_dict(get(attempt, "agent"));
                if !agent_attempt && len(get(attempt, "rounds")) == 0 && visible_history.is_some() {
                    let provenance = turn_attempt_ids[..attempt_index].iter().any(|prior_id| {
                        attempts_by_id
                            .get(as_str(Some(prior_id)).unwrap_or_default())
                            .copied()
                            .is_some_and(|prior| {
                                // An agent attempt's rounds live in its
                                // journal rather than in `rounds`: the lineage
                                // there is the same receipt this rule asks
                                // for. Without it a turn could never be asked
                                // again after an agent attempt that had
                                // started a round, because the digest the new
                                // attempt freezes would have no provenance.
                                (len(get(prior, "rounds")) > 0
                                    || !is_null(
                                        get(prior, "agent")
                                            .and_then(|agent| get(agent, "round_lineage")),
                                    ))
                                    && as_str(get(prior, "visible_history_sha256"))
                                        == visible_history
                                    && self.frozen_attempt_equal(prior, attempt)
                            })
                    });
                    if !provenance {
                        return None;
                    }
                }
                if status == "completed" {
                    completed_attempts += 1;
                    let assistant_id = as_str(present(get(attempt, "assistant_message_id")));
                    let assistant_id = assistant_id?;
                    if completed_attempts > 1 || assistant_references.contains(assistant_id) {
                        return None;
                    }
                    assistant_references.insert(assistant_id);
                }
            }
        }
        if referenced_attempts.len() != attempts_by_id.len() {
            return None;
        }
        let mut live_attempts = 0usize;
        for attempt in attempts {
            let status = as_str(get(attempt, "status")).unwrap_or_default();
            if matches!(status, "prepared" | "sending") {
                live_attempts += 1;
            }
            if live_attempts > 1 {
                return None;
            }
            if !is_null(get(attempt, "assistant_message_id")) {
                let assistant_id = as_str(get(attempt, "assistant_message_id")).unwrap_or_default();
                let assistant = messages_by_id.get(assistant_id).copied()?;
                if as_str(get(assistant, "role")) != Some("assistant") {
                    return None;
                }
                let attempt_turn = turns.iter().find(|turn| {
                    array(get(turn, "attempt_ids"))
                        .iter()
                        .any(|id| id == get(attempt, "attempt_id").unwrap_or(&Value::Null))
                });
                let user_index = attempt_turn.and_then(|turn| {
                    message_indexes
                        .get(as_str(get(turn, "user_message_id")).unwrap_or_default())
                        .copied()
                });
                let assistant_index = message_indexes.get(assistant_id).copied();
                let (Some(_), Some(user_index), Some(assistant_index)) =
                    (attempt_turn, user_index, assistant_index)
                else {
                    return None;
                };
                if assistant_index <= user_index
                    || as_str(get(assistant, "created_at")) < as_str(get(attempt, "created_at"))
                {
                    return None;
                }
                let last_round = array(get(attempt, "rounds")).last();
                let metadata = get(assistant, "metadata");
                let (Some(last_round), Some(metadata)) = (last_round, metadata) else {
                    return None;
                };
                if !equal(get(metadata, "model_id"), get(last_round, "model"))
                    || !equal(get(metadata, "latency_ms"), get(last_round, "latency_ms"))
                    || !equal(
                        get(metadata, "finish_reason"),
                        get(last_round, "finish_reason"),
                    )
                {
                    return None;
                }
            }
            if status == "completed"
                && (len(get(attempt, "rounds")) == 0
                    || as_str(nested(
                        array(get(attempt, "rounds")).last(),
                        "finish_reason",
                    )) == Some("tool_calls"))
            {
                return None;
            }
        }
        if agent_schema {
            if !is_array(f("agent_grants")) || len(f("agent_grants")) > 2 {
                return None;
            }
            let mut grant_ids: BTreeSet<&str> = BTreeSet::new();
            for grant in array(f("agent_grants")) {
                let grant_id = as_str(get(grant, "grant_id")).unwrap_or_default();
                if !self.agent_grant(grant)
                    || grant_ids.contains(grant_id)
                    || !equal(get(grant, "conversation_id"), f("id"))
                {
                    return None;
                }
                if !is_null(get(grant, "project_id"))
                    && (project_id.is_none() || !equal(get(grant, "project_id"), project_id))
                {
                    return None;
                }
                let binding = f("workspace_binding");
                if is_null(binding)
                    || !equal(get(grant, "workspace_id"), nested(binding, "workspace_id"))
                    || !equal(
                        get(grant, "binding_revision"),
                        nested(binding, "binding_revision"),
                    )
                    || !equal_or_null(get(grant, "project_id"), project_id)
                {
                    return None;
                }
                let issued = get(grant, "issued_for");
                let attempt = attempts_by_id
                    .get(as_str(nested(issued, "attempt_id")).unwrap_or_default())
                    .copied();
                let attempt = attempt?;
                if !equal(get(attempt, "turn_id"), nested(issued, "task_id")) {
                    return None;
                }
                grant_ids.insert(grant_id);
            }
            for attempt in attempts {
                let Some(journal) = present(get(attempt, "agent")) else {
                    continue;
                };
                if !super::grant_reuse::conversation_bound(journal, conversation) {
                    return None;
                }
                let binding = f("workspace_binding");
                let root = get(journal, "root");
                if is_null(binding)
                    || !equal(
                        nested(root, "workspace_id"),
                        nested(binding, "workspace_id"),
                    )
                    || !equal(
                        nested(root, "workspace_binding_revision"),
                        nested(binding, "binding_revision"),
                    )
                    || !equal_or_null(nested(root, "project_id"), project_id)
                    || uint(get(journal, "round_index")) > len(get(attempt, "rounds")) as u64
                {
                    return None;
                }
                let lineage = present(get(journal, "round_lineage"));
                let interrupted = as_str(get(attempt, "status")) == Some("failed")
                    && as_str(get(attempt, "failure_code")) == Some("E_ATTEMPT_INTERRUPTED");
                let active_round = present(get(attempt, "active_round"));
                if !interrupted {
                    let phase = as_str(get(journal, "phase"));
                    if phase == Some("round_in_flight")
                        && (active_round.is_none()
                            || lineage.is_none()
                            || !equal(
                                nested(active_round, "round_id"),
                                nested(lineage, "round_id"),
                            )
                            || !equal(
                                nested(active_round, "round_index"),
                                nested(lineage, "round_index"),
                            ))
                    {
                        return None;
                    }
                    if phase != Some("round_in_flight") && active_round.is_some() {
                        return None;
                    }
                }
                for grant_id in array(get(journal, "frozen_grant_ids")) {
                    let grant = array(f("agent_grants"))
                        .iter()
                        .find(|candidate| equal(get(candidate, "grant_id"), Some(grant_id)));
                    let grant = grant?;
                    if !equal(get(grant, "workspace_id"), nested(root, "workspace_id"))
                        || !equal(
                            get(grant, "binding_revision"),
                            nested(root, "workspace_binding_revision"),
                        )
                        || !equal(get(grant, "project_id"), nested(root, "project_id"))
                        || !equal(
                            get(grant, "registry_version"),
                            get(journal, "tool_registry_version"),
                        )
                        || !equal(
                            get(grant, "policy_version"),
                            nested(get(journal, "policy"), "policy_version"),
                        )
                    {
                        return None;
                    }
                    let family = as_str(get(grant, "tool_family")).unwrap_or_default();
                    let required_capability = match family {
                        "file_write" => "file_write",
                        "guest_service" => "guest_service",
                        "git_commit" => "git_commit",
                        _ => "git_push",
                    };
                    if !array(nested(root, "capabilities"))
                        .iter()
                        .any(|c| as_str(Some(c)) == Some(required_capability))
                    {
                        return None;
                    }
                }
            }
        }
        Some(attempts_by_id)
    }

    // MARK: event correlations

    #[allow(clippy::too_many_lines)]
    fn event_correlations(
        &self,
        events: &[Value],
        attempts_by_id: &BTreeMap<&str, &Value>,
    ) -> bool {
        let mut event_calls: BTreeMap<String, BTreeMap<String, Value>> = BTreeMap::new();
        for event in events {
            let e = |key: &str| get(event, key);
            let attempt_id = as_str(e("attempt_id")).unwrap_or_default();
            let Some(attempt) = attempts_by_id.get(attempt_id).copied() else {
                return false;
            };
            let journal = present(get(attempt, "agent"));
            let journal_call = if journal.is_some() && !is_null(e("call_id")) {
                array(nested(journal, "batch"))
                    .iter()
                    .find(|call| equal(get(call, "call_id"), e("call_id")))
            } else {
                None
            };
            let event_call_key = if is_null(e("call_id")) {
                None
            } else {
                Some(format!(
                    "{attempt_id}\0{}",
                    as_str(e("call_id")).unwrap_or_default()
                ))
            };
            let previous = event_call_key
                .as_ref()
                .and_then(|key| event_calls.get(key))
                .cloned();
            let round_index = present(e("round_index")).map(|v| uint(Some(v)));
            let round_count = len(get(attempt, "rounds")) as u64;
            let journal_round_index = journal.map(|j| uint(get(j, "round_index")));
            if let Some(round_index) = round_index {
                if round_index >= round_count
                    && (journal_round_index.is_none() || Some(round_index) != journal_round_index)
                {
                    return false;
                }
            }
            let kind = as_str(e("kind")).unwrap_or_default();
            if kind == "cancel" {
                if journal.is_none() {
                    return false;
                }
                if round_index.is_none() {
                    if !is_null(e("call_id")) || !is_null(e("arguments_sha256")) {
                        return false;
                    }
                    continue;
                }
                if is_null(e("call_id")) {
                    if !is_null(e("arguments_sha256")) {
                        return false;
                    }
                    continue;
                }
                if journal_call.is_none()
                    || journal_round_index.is_none()
                    || round_index != journal_round_index
                    || !equal(
                        e("arguments_sha256"),
                        nested(journal_call, "arguments_sha256"),
                    )
                {
                    return false;
                }
                continue;
            }
            if matches!(kind, "round" | "terminal") {
                if !is_null(e("call_id"))
                    || !is_null(e("arguments_sha256"))
                    || !is_null(e("result_sha256"))
                    || !is_null(e("approval_reference"))
                    || !is_null(e("safe_summary_key"))
                {
                    return false;
                }
                continue;
            }
            if is_null(e("call_id")) {
                return false;
            }
            let mut historical_event = false;
            if journal_call.is_none()
                && previous.is_none()
                && round_index.is_some()
                && journal.is_some_and(|j| exact_schema(get(j, "schema_version"), 3))
                && journal_round_index.is_some()
                && round_index < journal_round_index
            {
                historical_event = array(get(attempt, "rounds"))
                    .iter()
                    .any(|round| equal(get(round, "round_index"), e("round_index")));
            }
            if journal_call.is_none() && previous.is_none() && !historical_event {
                return false;
            }
            if journal_call.is_some()
                && journal_round_index.is_some()
                && (round_index.is_none() || round_index != journal_round_index)
            {
                return false;
            }
            if let Some(previous) = &previous {
                if !equal(previous.get("round_index"), e("round_index")) {
                    return false;
                }
            }
            let known_arguments: Option<&Value> = match journal_call {
                Some(call) => get(call, "arguments_sha256"),
                None => previous.as_ref().and_then(|p| p.get("arguments_sha256")),
            };
            let known_summary: Option<&Value> = match journal_call {
                Some(call) => get(call, "safe_summary_key"),
                None => previous.as_ref().and_then(|p| p.get("safe_summary_key")),
            };
            let known_approval: Option<&Value> = match journal_call {
                Some(call) => get(call, "approval_reference"),
                None => previous.as_ref().and_then(|p| p.get("approval_reference")),
            };
            if !is_null(e("arguments_sha256"))
                && known_arguments.is_some()
                && !equal(e("arguments_sha256"), known_arguments)
            {
                return false;
            }
            if !is_null(e("safe_summary_key"))
                && known_summary.is_some()
                && !equal(e("safe_summary_key"), known_summary)
            {
                return false;
            }
            let denial_marker = journal_call.is_some_and(|call| {
                kind == "approval"
                    && equal(e("approval_reference"), e("event_id"))
                    && is_null(get(call, "approval_reference"))
                    && matches!(
                        as_str(get(call, "approval_decision")),
                        Some("denied" | "cancelled")
                    )
            });
            if journal_call.is_some()
                && kind != "tool_call"
                && !denial_marker
                && !(kind == "approval" && is_null(e("approval_reference")))
                && !equal(e("approval_reference"), known_approval)
            {
                return false;
            }
            let historical_user_denial = journal_call.is_none()
                && previous.is_some()
                && kind == "tool_result"
                && as_str(e("status")) == Some("denied")
                && as_str(e("failure_code")) == Some("E_AGENT_DENIED_BY_USER")
                && is_null(e("approval_reference"));
            if journal_call.is_none()
                && previous.is_some()
                && kind != "tool_call"
                && !historical_user_denial
                && !equal(e("approval_reference"), known_approval)
            {
                return false;
            }
            let mut row: BTreeMap<String, Value> = match &previous {
                Some(previous) => previous.clone(),
                None => {
                    let mut fresh = BTreeMap::new();
                    fresh.insert("attempt_id".to_string(), Value::from(attempt_id));
                    fresh.insert(
                        "round_index".to_string(),
                        e("round_index").cloned().unwrap_or(Value::Null),
                    );
                    fresh
                }
            };
            let key = event_call_key.clone().expect("call id present");
            if kind == "tool_call" {
                if is_null(e("arguments_sha256"))
                    || is_null(e("safe_summary_key"))
                    || !is_null(e("result_sha256"))
                    || !is_null(e("approval_reference"))
                    || !matches!(
                        as_str(e("status")),
                        Some("waiting" | "approval" | "running")
                    )
                {
                    return false;
                }
                row.insert(
                    "safe_summary_key".to_string(),
                    e("safe_summary_key").cloned().unwrap_or(Value::Null),
                );
                row.insert(
                    "arguments_sha256".to_string(),
                    e("arguments_sha256").cloned().unwrap_or(Value::Null),
                );
                let mut authority = previous
                    .as_ref()
                    .and_then(|p| p.get("approval_reference"))
                    .filter(|v| !v.is_null())
                    .cloned();
                if authority.is_none() {
                    authority = journal_call
                        .and_then(|call| get(call, "approval_reference"))
                        .cloned();
                }
                row.insert(
                    "approval_reference".to_string(),
                    authority.unwrap_or(Value::Null),
                );
                event_calls.insert(key, row);
                continue;
            }
            if kind == "approval" {
                if is_null(e("arguments_sha256"))
                    || is_null(e("safe_summary_key"))
                    || as_str(e("status")) != Some("approval")
                {
                    return false;
                }
                row.insert(
                    "safe_summary_key".to_string(),
                    e("safe_summary_key").cloned().unwrap_or(Value::Null),
                );
                row.insert(
                    "arguments_sha256".to_string(),
                    e("arguments_sha256").cloned().unwrap_or(Value::Null),
                );
                row.insert(
                    "approval_reference".to_string(),
                    e("approval_reference").cloned().unwrap_or(Value::Null),
                );
                event_calls.insert(key, row);
                continue;
            }
            if kind != "tool_result"
                || is_null(e("arguments_sha256"))
                || is_null(e("result_sha256"))
                || !matches!(
                    as_str(e("status")),
                    Some("ok" | "failed" | "denied" | "cancelled" | "unknown" | "ambiguous")
                )
            {
                return false;
            }
            let receipt = journal_call.and_then(|call| present(get(call, "receipt")));
            if journal_call.is_some() && receipt.is_none() {
                return false;
            }
            if let Some(receipt) = receipt {
                if !equal(e("status"), get(receipt, "outcome"))
                    || !equal(e("result_sha256"), get(receipt, "result_sha256"))
                    || !equal(e("arguments_sha256"), get(receipt, "arguments_sha256"))
                    || !equal(e("approval_reference"), get(receipt, "approval_reference"))
                    || !equal(e("failure_code"), get(receipt, "failure_code"))
                {
                    return false;
                }
            }
            if receipt.is_none() {
                if let Some(previous) = &previous {
                    if previous.get("result_sha256").is_some()
                        && (!equal(previous.get("result_sha256"), e("result_sha256"))
                            || !equal(previous.get("receipt_status"), e("status"))
                            || !equal(previous.get("failure_code"), e("failure_code")))
                    {
                        return false;
                    }
                }
            }
            row.insert(
                "arguments_sha256".to_string(),
                e("arguments_sha256").cloned().unwrap_or(Value::Null),
            );
            row.insert(
                "result_sha256".to_string(),
                e("result_sha256").cloned().unwrap_or(Value::Null),
            );
            row.insert(
                "approval_reference".to_string(),
                e("approval_reference").cloned().unwrap_or(Value::Null),
            );
            row.insert(
                "failure_code".to_string(),
                e("failure_code").cloned().unwrap_or(Value::Null),
            );
            row.insert(
                "receipt_status".to_string(),
                e("status").cloned().unwrap_or(Value::Null),
            );
            event_calls.insert(key, row);
        }
        true
    }

    // MARK: outbox / transitions

    fn workspace_outbox_entry(&self, entry: &Value) -> bool {
        let f = |key: &str| get(entry, key);
        exact_keys(
            entry,
            &[
                "schema_version",
                "operation_id",
                "action",
                "workspace_id",
                "binding_revision",
                "clearance_receipt_id",
                "created_at",
            ],
        ) && exact_schema(f("schema_version"), 1)
            && canonical_uuid(f("operation_id"))
            && string_in(f("action"), &["forget", "delete_owned"])
            && canonical_uuid(f("workspace_id"))
            && safe_integer(f("binding_revision"), false).is_some()
            && uint(f("binding_revision")) < MAX_SAFE_INTEGER
            && canonical_uuid(f("clearance_receipt_id"))
            && canonical_timestamp(f("created_at"))
    }

    fn destructive_transition(&self, transition: &Value) -> bool {
        let keys = [
            "schema_version",
            "lifecycle_id",
            "epoch",
            "action",
            "phase",
            "conversation_id",
            "source_project_id",
            "source_runtime_context_id",
            "source_model_id",
            "snapshot_id",
            "snapshot_sha256",
            "consent_receipt_id",
            "target_project_id",
            "created_at",
            "updated_at",
        ];
        let f = |key: &str| get(transition, key);
        if !exact_keys(transition, &keys)
            || !exact_schema(f("schema_version"), 1)
            || !canonical_uuid(f("lifecycle_id"))
            || safe_integer(f("epoch"), false).is_none()
            || !string_in(f("action"), &["unbind", "delete", "rebind"])
            || !string_in(
                f("phase"),
                &["intent", "cleanup_pending", "ready_to_finalize"],
            )
            || !valid_identifier(f("conversation_id"), MAX_ID_BYTES)
            || !valid_identifier(f("source_project_id"), MAX_ID_BYTES)
            || !(is_null(f("source_runtime_context_id"))
                || canonical_uuid(f("source_runtime_context_id")))
            || !self.valid_model(f("source_model_id"))
            || !canonical_uuid(f("snapshot_id"))
            || !canonical_digest(f("snapshot_sha256"))
            || !(is_null(f("consent_receipt_id")) || canonical_uuid(f("consent_receipt_id")))
            || !(is_null(f("target_project_id"))
                || valid_identifier(f("target_project_id"), MAX_ID_BYTES))
            || !canonical_timestamp(f("created_at"))
            || !canonical_timestamp(f("updated_at"))
            || as_str(f("created_at")) > as_str(f("updated_at"))
        {
            return false;
        }
        let rebind = as_str(f("action")) == Some("rebind");
        let has_target = !is_null(f("target_project_id"));
        rebind == has_target && (!rebind || !equal(f("target_project_id"), f("source_project_id")))
    }

    fn transition_has_references(&self, conversation: &Value, transition: &Value) -> bool {
        let messages = array(get(conversation, "messages"));
        let visible_start = messages.len().saturating_sub(MAX_VISIBLE_MESSAGES);
        let visible_window: Vec<Value> = messages[visible_start..].to_vec();
        for attempt in array(get(conversation, "attempts")) {
            let disposition = as_str(get(attempt, "context_disposition")).unwrap_or_default();
            let attempt_context = present(get(attempt, "project_context"));
            if disposition == "unbound" {
                if attempt_context.is_some() || !is_null(get(attempt, "context_project_id")) {
                    return true;
                }
                continue;
            }
            if disposition == "explicit_without_context" {
                if attempt_context.is_some()
                    || is_null(get(attempt, "context_project_id"))
                    || !equal(
                        get(attempt, "context_project_id"),
                        get(conversation, "project_id"),
                    )
                {
                    return true;
                }
                continue;
            }
            if disposition != "verified" || attempt_context.is_none() {
                return true;
            }
            if !equal(
                nested(attempt_context, "snapshot_id"),
                get(transition, "snapshot_id"),
            ) {
                continue;
            }
            let status = as_str(get(attempt, "status")).unwrap_or_default();
            if matches!(status, "prepared" | "sending") {
                return true;
            }
            if matches!(status, "failed" | "cancelled")
                && get(attempt, "visible_message_ids")
                    != Some(&Value::Array(visible_window.clone()))
            {
                return true;
            }
        }
        false
    }

    fn transition_consistent(
        &self,
        transition: &Value,
        conversation: &Value,
        context: &Value,
    ) -> bool {
        let phase = as_str(get(transition, "phase")).unwrap_or_default();
        if phase == "intent" {
            let manifest = present(get(context, "manifest"));
            let consent = present(get(context, "consent"));
            if !equal(get(transition, "created_at"), get(transition, "updated_at"))
                || !is_null(get(context, "active_preparation_id"))
                || as_str(get(conversation, "updated_at")) > as_str(get(transition, "created_at"))
                || manifest.is_none()
                || !equal(
                    nested(manifest, "snapshot_id"),
                    get(transition, "snapshot_id"),
                )
                || !equal(
                    nested(manifest, "snapshot_sha256"),
                    get(transition, "snapshot_sha256"),
                )
                || !equal_or_null(
                    nested(consent, "consent_receipt_id"),
                    get(transition, "consent_receipt_id"),
                )
                || self.transition_has_references(conversation, transition)
            {
                return false;
            }
        } else if as_str(get(context, "status")) != Some("setup_required")
            || len(get(context, "selected_paths")) != 0
            || !is_null(get(context, "active_preparation_id"))
            || !is_null(get(context, "manifest"))
            || !is_null(get(context, "consent"))
            || !is_null(get(context, "stale_reason"))
            || !is_null(get(context, "error_code"))
            || self.transition_has_references(conversation, transition)
        {
            return false;
        }
        if phase == "cleanup_pending"
            && !equal(
                get(conversation, "updated_at"),
                get(transition, "updated_at"),
            )
        {
            return false;
        }
        !(phase == "ready_to_finalize"
            && as_str(get(conversation, "updated_at")) > as_str(get(transition, "updated_at")))
    }

    // MARK: roots

    #[allow(clippy::too_many_lines)]
    pub(super) fn schema9_root(&self, session: &Value) -> bool {
        let keys = [
            "schema_version",
            "workspace_authority_outbox",
            "agent_transcript_cleanup_outbox",
            "project_context_destructive_epoch",
            "project_context_destructive_transition",
            "active_conversation_id",
            "conversations",
            "messages",
            "session_events",
            "preferences",
        ];
        let f = |key: &str| get(session, key);
        if !exact_keys(session, &keys)
            || !exact_schema(f("schema_version"), 9)
            || !is_array(f("workspace_authority_outbox"))
            || len(f("workspace_authority_outbox")) > MAX_OUTBOX
            || !is_array(f("agent_transcript_cleanup_outbox"))
            || len(f("agent_transcript_cleanup_outbox")) > MAX_CLEANUP
            || safe_integer(f("project_context_destructive_epoch"), true).is_none()
            || !(is_null(f("project_context_destructive_transition"))
                || is_dict(f("project_context_destructive_transition")))
            || !string_or_null(f("active_conversation_id"))
            || !is_array(f("conversations"))
            || len(f("conversations")) > 10_000
            || !is_array(f("messages"))
            || !is_array(f("session_events"))
            || len(f("session_events")) > MAX_EVENTS
            || !self.preferences(f("preferences"))
        {
            return false;
        }
        if !is_null(f("active_conversation_id"))
            && bounded_text(f("active_conversation_id"), 256, false).is_none()
        {
            return false;
        }
        let mut workspace_operation_ids: BTreeSet<&str> = BTreeSet::new();
        for item in array(f("workspace_authority_outbox")) {
            let id = as_str(get(item, "operation_id")).unwrap_or_default();
            if !self.workspace_outbox_entry(item) || workspace_operation_ids.contains(id) {
                return false;
            }
            workspace_operation_ids.insert(id);
        }
        let mut conversations: BTreeMap<&str, &Value> = BTreeMap::new();
        let mut attempts: BTreeMap<&str, &Value> = BTreeMap::new();
        for item in array(f("conversations")) {
            let id = as_str(get(item, "id")).unwrap_or_default();
            let Some(conversation_attempts) = self.conversation(item, 9) else {
                return false;
            };
            if conversations.contains_key(id) {
                return false;
            }
            conversations.insert(id, item);
            for (attempt_id, attempt) in conversation_attempts {
                if attempts.contains_key(attempt_id) {
                    return false;
                }
                attempts.insert(attempt_id, attempt);
            }
        }
        for entry in array(f("workspace_authority_outbox")) {
            let workspace_id = get(entry, "workspace_id");
            for conversation in array(f("conversations")) {
                if !is_null(get(conversation, "workspace_id"))
                    && equal(get(conversation, "workspace_id"), workspace_id)
                {
                    return false;
                }
                if let Some(binding) = present(get(conversation, "workspace_binding")) {
                    if equal(get(binding, "workspace_id"), workspace_id) {
                        return false;
                    }
                }
                for attempt in array(get(conversation, "attempts")) {
                    if !is_null(get(attempt, "workspace_id"))
                        && equal(get(attempt, "workspace_id"), workspace_id)
                    {
                        return false;
                    }
                }
            }
        }
        let Some(root_messages) = self.messages(f("messages"), 9) else {
            return false;
        };
        let active_id = f("active_conversation_id");
        let active_conversation =
            as_str(present(active_id)).and_then(|id| conversations.get(id).copied());
        if (!is_null(active_id) && active_conversation.is_none())
            || (active_conversation.is_none() && !root_messages.is_empty())
            || active_conversation.is_some_and(|c| f("messages") != get(c, "messages"))
        {
            return false;
        }
        let mut lifecycle_ids: BTreeSet<String> = BTreeSet::new();
        let mut provider_request_ids: BTreeSet<String> = BTreeSet::new();
        let text_of =
            |value: Option<&Value>| -> String { as_str(value).unwrap_or_default().to_string() };
        for conversation in array(f("conversations")) {
            for grant in array(get(conversation, "agent_grants")) {
                if !lifecycle_ids.insert(text_of(get(grant, "grant_id"))) {
                    return false;
                }
            }
            if !is_null(get(conversation, "runtime_context_id"))
                && !lifecycle_ids.insert(text_of(get(conversation, "runtime_context_id")))
            {
                return false;
            }
            for turn in array(get(conversation, "turns")) {
                if !lifecycle_ids.insert(text_of(get(turn, "turn_id"))) {
                    return false;
                }
            }
            for attempt in array(get(conversation, "attempts")) {
                if !lifecycle_ids.insert(text_of(get(attempt, "attempt_id"))) {
                    return false;
                }
                for round in array(get(attempt, "rounds")) {
                    let round_id = text_of(get(round, "round_id"));
                    let request_id = text_of(get(round, "provider_request_id"));
                    // The response id is the provider's, and relays reuse
                    // one; only the request id, which is ours, is unique.
                    if lifecycle_ids.contains(&round_id) || provider_request_ids.contains(&request_id) {
                        return false;
                    }
                    lifecycle_ids.insert(round_id);
                    provider_request_ids.insert(request_id);
                }
                let active_round = present(get(attempt, "active_round"));
                if let Some(active_round) = active_round {
                    if !lifecycle_ids.insert(text_of(get(active_round, "round_id"))) {
                        return false;
                    }
                }
                let journal = present(get(attempt, "agent"));
                if let Some(lineage) = present(nested(journal, "round_lineage")) {
                    let round_id = get(lineage, "round_id");
                    let represented = active_round
                        .is_some_and(|a| equal(get(a, "round_id"), round_id))
                        || array(get(attempt, "rounds"))
                            .iter()
                            .any(|round| equal(get(round, "round_id"), round_id));
                    if !represented && !lifecycle_ids.insert(text_of(round_id)) {
                        return false;
                    }
                }
                if journal.is_some()
                    && !lifecycle_ids.insert(text_of(nested(
                        nested(journal, "transcript"),
                        "transcript_ref",
                    )))
                {
                    return false;
                }
            }
        }
        let mut cleanup_ids: BTreeSet<String> = BTreeSet::new();
        for item in array(f("agent_transcript_cleanup_outbox")) {
            let cleanup_id = text_of(get(item, "cleanup_id"));
            if !self.cleanup(item)
                || cleanup_ids.contains(&cleanup_id)
                || lifecycle_ids.contains(&cleanup_id)
            {
                return false;
            }
            let conversation = conversations
                .get(as_str(get(item, "conversation_id")).unwrap_or_default())
                .copied();
            let attempt = attempts
                .get(as_str(get(item, "attempt_id")).unwrap_or_default())
                .copied();
            let Some(conversation) = conversation else {
                if as_str(get(item, "reason")) != Some("conversation_deleted") {
                    return false;
                }
                cleanup_ids.insert(cleanup_id.clone());
                lifecycle_ids.insert(cleanup_id);
                continue;
            };
            let Some(attempt) = attempt else { return false };
            if !array(get(conversation, "attempts"))
                .iter()
                .any(|candidate| candidate == attempt)
                || !equal(get(attempt, "turn_id"), get(item, "task_id"))
            {
                return false;
            }
            if is_null(get(attempt, "agent")) {
                if as_str(get(attempt, "status")) != Some("failed")
                    || as_str(get(attempt, "failure_code")) != Some("E_ATTEMPT_INTERRUPTED")
                    || as_str(get(item, "reason")) != Some("failed")
                {
                    return false;
                }
            } else {
                let transcript = nested(get(attempt, "agent"), "transcript");
                if !equal(
                    nested(transcript, "transcript_ref"),
                    get(item, "transcript_ref"),
                ) || !equal(
                    nested(transcript, "transcript_sha256"),
                    get(item, "transcript_sha256"),
                ) {
                    return false;
                }
            }
            cleanup_ids.insert(cleanup_id.clone());
            lifecycle_ids.insert(cleanup_id);
        }
        let mut last_seq_by_attempt: BTreeMap<&str, u64> = BTreeMap::new();
        let mut event_ids: BTreeSet<String> = BTreeSet::new();
        for event in array(f("session_events")) {
            let event_id = text_of(get(event, "event_id"));
            if !self.event(event)
                || event_ids.contains(&event_id)
                || !attempts.contains_key(as_str(get(event, "attempt_id")).unwrap_or_default())
                || lifecycle_ids.contains(&event_id)
            {
                return false;
            }
            event_ids.insert(event_id.clone());
            lifecycle_ids.insert(event_id);
            let attempt_id = as_str(get(event, "attempt_id")).unwrap_or_default();
            let seq = uint(get(event, "seq"));
            if last_seq_by_attempt
                .get(attempt_id)
                .is_some_and(|previous| seq <= *previous)
            {
                return false;
            }
            last_seq_by_attempt.insert(attempt_id, seq);
        }
        if !self.event_correlations(array(f("session_events")), &attempts) {
            return false;
        }
        if let Some(transition) = present(f("project_context_destructive_transition")) {
            let conversation = conversations
                .get(as_str(get(transition, "conversation_id")).unwrap_or_default())
                .copied();
            if !self.destructive_transition(transition)
                || !equal(
                    get(transition, "epoch"),
                    f("project_context_destructive_epoch"),
                )
                || conversation.is_none()
                || lifecycle_ids.contains(&text_of(get(transition, "lifecycle_id")))
            {
                return false;
            }
            lifecycle_ids.insert(text_of(get(transition, "lifecycle_id")));
            let conversation = conversation.expect("checked");
            let context = present(get(conversation, "project_context"));
            if !equal(
                get(conversation, "project_id"),
                get(transition, "source_project_id"),
            ) || !equal(
                get(conversation, "runtime_context_id"),
                get(transition, "source_runtime_context_id"),
            ) || !equal(
                get(conversation, "model_id"),
                get(transition, "source_model_id"),
            ) || context.is_none()
            {
                return false;
            }
            if !self.transition_consistent(transition, conversation, context.expect("checked")) {
                return false;
            }
        }
        true
    }

    #[allow(clippy::too_many_lines)]
    pub(super) fn legacy_root(&self, session: &Value) -> bool {
        let f = |key: &str| get(session, key);
        if !session.is_object() || safe_integer(f("schema_version"), true).is_none() {
            return false;
        }
        let version = uint(f("schema_version"));
        if !(2..=8).contains(&version) {
            return false;
        }
        let base: &[&str] = match version {
            2..=6 => &[
                "schema_version",
                "active_conversation_id",
                "conversations",
                "messages",
            ],
            7 => &[
                "schema_version",
                "project_context_destructive_epoch",
                "project_context_destructive_transition",
                "active_conversation_id",
                "conversations",
                "messages",
            ],
            _ => &[
                "schema_version",
                "workspace_authority_outbox",
                "project_context_destructive_epoch",
                "project_context_destructive_transition",
                "active_conversation_id",
                "conversations",
                "messages",
            ],
        };
        let mut allowed: Vec<&str> = base.to_vec();
        allowed.extend(["preferences", "session_events"]);
        let map = session.as_object().expect("object");
        if map.len() < base.len()
            || map.len() > allowed.len()
            || !map.keys().all(|key| allowed.contains(&key.as_str()))
            || !base.iter().all(|key| map.contains_key(*key))
        {
            return false;
        }
        if !string_or_null(f("active_conversation_id"))
            || !is_array(f("conversations"))
            || !is_array(f("messages"))
        {
            return false;
        }
        if version >= 7
            && (safe_integer(f("project_context_destructive_epoch"), true).is_none()
                || !(is_null(f("project_context_destructive_transition"))
                    || is_dict(f("project_context_destructive_transition"))))
        {
            return false;
        }
        if version == 8 && !is_array(f("workspace_authority_outbox")) {
            return false;
        }
        if f("preferences").is_some() && !self.preferences(f("preferences")) {
            return false;
        }
        if f("session_events").is_some() && !is_array(f("session_events")) {
            return false;
        }
        let Some(root_messages) = self.messages(f("messages"), version) else {
            return false;
        };
        let mut conversations: BTreeMap<&str, &Value> = BTreeMap::new();
        for conversation in array(f("conversations")) {
            let id = as_str(get(conversation, "id")).unwrap_or_default();
            if self.conversation(conversation, version).is_none() || conversations.contains_key(id)
            {
                return false;
            }
            conversations.insert(id, conversation);
        }
        let active_id = f("active_conversation_id");
        let active_conversation =
            as_str(present(active_id)).and_then(|id| conversations.get(id).copied());
        if (!is_null(active_id) && active_conversation.is_none())
            || (active_conversation.is_none() && !root_messages.is_empty())
            || active_conversation.is_some_and(|c| f("messages") != get(c, "messages"))
        {
            return false;
        }
        let transition = if version >= 7 {
            present(f("project_context_destructive_transition"))
        } else {
            None
        };
        if let Some(transition) = transition {
            let conversation = conversations
                .get(as_str(get(transition, "conversation_id")).unwrap_or_default())
                .copied();
            if !self.destructive_transition(transition)
                || !equal(
                    get(transition, "epoch"),
                    f("project_context_destructive_epoch"),
                )
                || conversation.is_none()
            {
                return false;
            }
            let conversation = conversation.expect("checked");
            let context = present(get(conversation, "project_context"));
            if context.is_none()
                || !equal(
                    get(conversation, "project_id"),
                    get(transition, "source_project_id"),
                )
                || !equal(
                    get(conversation, "runtime_context_id"),
                    get(transition, "source_runtime_context_id"),
                )
                || !equal(
                    get(conversation, "model_id"),
                    get(transition, "source_model_id"),
                )
            {
                return false;
            }
            if !self.transition_consistent(transition, conversation, context.expect("checked")) {
                return false;
            }
        }
        if version == 8 {
            let mut operation_ids: BTreeSet<&str> = BTreeSet::new();
            for entry in array(f("workspace_authority_outbox")) {
                let id = as_str(get(entry, "operation_id")).unwrap_or_default();
                if !self.workspace_outbox_entry(entry) || operation_ids.contains(id) {
                    return false;
                }
                operation_ids.insert(id);
            }
            for entry in array(f("workspace_authority_outbox")) {
                let workspace_id = get(entry, "workspace_id");
                for conversation in array(f("conversations")) {
                    let binding = get(conversation, "workspace_binding");
                    if (!is_null(get(conversation, "workspace_id"))
                        && equal(get(conversation, "workspace_id"), workspace_id))
                        || (binding.is_some()
                            && !is_null(binding)
                            && equal(nested(binding, "workspace_id"), workspace_id))
                    {
                        return false;
                    }
                    for attempt in array(get(conversation, "attempts")) {
                        if !is_null(get(attempt, "workspace_id"))
                            && equal(get(attempt, "workspace_id"), workspace_id)
                        {
                            return false;
                        }
                    }
                }
            }
        }
        let mut lifecycle_ids: BTreeSet<String> = BTreeSet::new();
        let mut provider_request_ids: BTreeSet<String> = BTreeSet::new();
        let text_of =
            |value: Option<&Value>| -> String { as_str(value).unwrap_or_default().to_string() };
        for conversation in array(f("conversations")) {
            if let Some(runtime) = get(conversation, "runtime_context_id") {
                if !runtime.is_null() && !lifecycle_ids.insert(text_of(Some(runtime))) {
                    return false;
                }
            }
            for turn in array(get(conversation, "turns")) {
                if !lifecycle_ids.insert(text_of(get(turn, "turn_id"))) {
                    return false;
                }
            }
            for attempt in array(get(conversation, "attempts")) {
                if !lifecycle_ids.insert(text_of(get(attempt, "attempt_id"))) {
                    return false;
                }
                for round in array(get(attempt, "rounds")) {
                    let round_id = text_of(get(round, "round_id"));
                    let request_id = text_of(get(round, "provider_request_id"));
                    // The response id is the provider's, and relays reuse
                    // one; only the request id, which is ours, is unique.
                    if lifecycle_ids.contains(&round_id) || provider_request_ids.contains(&request_id) {
                        return false;
                    }
                    lifecycle_ids.insert(round_id);
                    provider_request_ids.insert(request_id);
                }
                if let Some(active_round) = present(get(attempt, "active_round")) {
                    if !lifecycle_ids.insert(text_of(get(active_round, "round_id"))) {
                        return false;
                    }
                }
            }
        }
        if let Some(transition) = transition {
            if lifecycle_ids.contains(&text_of(get(transition, "lifecycle_id"))) {
                return false;
            }
        }
        true
    }
}
