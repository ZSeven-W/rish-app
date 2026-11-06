// C ABI of the shared Rish agent core (modules/rish/core, crate rish-agent-ffi).
//
// Every string-returning function hands back a NUL-terminated UTF-8 buffer
// owned by the library; release it with rish_agent_string_free. Inputs are
// UTF-8 with explicit lengths and are never retained. All functions are safe
// to call from any thread and never unwind across the boundary.
#ifndef RISH_AGENT_CORE_H
#define RISH_AGENT_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// JSON protocol version implemented by the library (see PROTOCOL_VERSION).
uint32_t rish_agent_protocol_version(void);

/// Releases a string returned by any function below. NULL is ignored.
void rish_agent_string_free(char *value);

/// Canonical JSON of a JSON text, or NULL when it is not JSON or cannot be
/// canonicalised (non-finite, negative zero, unsafe integer, depth > 64).
char *rish_agent_canonical_json(const char *json, size_t json_length);

/// DSHAgentHJ: SHA-256("rish.<tag>.v1\0" || canonical JSON), lowercase hex.
char *rish_agent_hash_json(const char *tag, size_t tag_length,
                           const char *json, size_t json_length);

/// DSHAgentHB: SHA-256("rish.<tag>.v1\0" || u64 big-endian length || bytes).
char *rish_agent_hash_bytes(const char *tag, size_t tag_length,
                            const uint8_t *bytes, size_t length);

/// Canonical form of tool arguments when the strict parser accepts them.
char *rish_agent_parse_arguments(const char *json, size_t json_length);

/// Shared name normalization and validation: {kind:workspace|conversation,text}.
/// Returns {ok:true,value:{text,issue:null|empty|invalid|too_long}}.
char *rish_agent_name_policy_reduce(const char *json, size_t json_length);

/// Shared Git remote URL policy: {url}. Returns {ok:true,value:{url,
/// canonical_url,scheme,host,port,username,path,scp}} or a static error.
char *rish_agent_git_remote_policy_reduce(const char *json, size_t json_length);

/// Shared model directory validation, retirement and capability lookup.
/// Exact {op,...} requests return {ok:true,value:...} or a static error.
char *rish_agent_model_catalog_reduce(const char *json, size_t json_length);

/// Shared provider fields, endpoint plans, bindings and credential identities.
/// Native URL parsing/serialization and storage remain with the host.
char *rish_agent_provider_policy_reduce(const char *json, size_t json_length);

/// Display-only round archives: schema_version=1 identity/decode/upsert/project.
/// Returns {ok:true,value:...} or {ok:false,error:store_error_code}.
/// Hosts retain ownership checks, bounded file IO and encoded file-size limits.
char *rish_agent_round_presentation_reduce(const char *json, size_t json_length);

/// One schema-3 round-journal operation over a JSON envelope
/// {"op","args","env","view"}; returns {"ok":true,...} or
/// {"ok":false,"error":<DSHAgentNativeStoreErrorCode>}. NULL only when the
/// input is not UTF-8.
char *rish_agent_round_reduce(const char *json, size_t json_length);

/// One execution-ledger row operation over a JSON envelope
/// {"op","args","env","view"}; returns {"ok":true,...} with the change list
/// and optional operation commit, or {"ok":false,"error":<code>}. NULL only
/// when the input is not UTF-8.
char *rish_agent_ledger_reduce(const char *json, size_t json_length);

/// One batch-level ledger operation (prepare_tool_batch / open_effect_gate)
/// over {"op","request","env","view"}; same reply shape as the row reducer.
char *rish_agent_ledger_batch_reduce(const char *json, size_t json_length);

/// One transcript-store operation over {"op","request","env","view"}.
char *rish_agent_transcript_reduce(const char *json, size_t json_length);

/// One session-schema operation: `request` is {"op","env"} JSON, `input` the
/// operation's raw bytes (candidate JSON, stored envelope, tombstone file; any
/// bytes, empty allowed). Ops: candidate (validation + digest),
/// candidate_digest (lenient), envelope, tombstones, legacy_root. Same reply
/// shape as the reducers.
char *rish_agent_session_reduce(const char *request, size_t request_length,
                                const uint8_t *input, size_t input_length);

/// One tool-batch-service decision over {"op","request",...}: prepare_request,
/// prepare_gate, prepare_calls, prepare_finish, prepare_final,
/// prepare_ledger_failure, bind_request, bind_check.
char *rish_agent_tool_batch_reduce(const char *json, size_t json_length);

/// One tool-execution-service decision over {"op","request",...}: request,
/// session_matches, row, precheck, conflict, arguments, recover_arguments,
/// effect_gate, execution_cas, active_result, safe_result, generic_failure,
/// ambiguous_effect, settlement, settle_failed, recover.
char *rish_agent_tool_execution_reduce(const char *json, size_t json_length);

/// One prepared-attempt-store decision over {"op","request",...}: request,
/// session (takes the committed session's exact JSON bytes), observed,
/// conflict, session_matches, projection, transaction.
char *rish_agent_prepared_attempt_reduce(const char *json, size_t json_length,
                                         const uint8_t *session, size_t session_length);

/// Validates one stored WAL row over {"op","value","env"?}: reference,
/// message, reservation, cleanup, dispatch, write_prior, policy, registry,
/// authority, result_reference, snapshot_reference, operation,
/// operation_result, opaque_call_id, tool_feedback.
char *rish_agent_wal_state_reduce(const char *json, size_t json_length);

/// One WAL operation-relation decision over
/// {"op","state","arguments","timestamp"?,"snapshot"?}: start, start_target,
/// query, commit_prepare, commit_apply, prepare_authority, record_batch,
/// record_denied_call. The reply is {"result":"commit"|"replay"|"proceed"|
/// "error", ...}; the host applies "changes" only once it has written and
/// confirmed the transaction.
char *rish_agent_wal_operation_reduce(const char *json, size_t json_length);

/// One storage root's resident WAL state. rish_agent_wal_open adopts a state
/// the host has read and validated and returns an opaque handle;
/// rish_agent_wal_snapshot reads the committed state back;
/// rish_agent_wal_begin takes a candidate and returns the exact bytes to
/// write; rish_agent_wal_confirm resolves it with "committed",
/// "not_committed" or "unknown". An unknown confirmation is never downgraded
/// to not-committed: it invalidates the handle, snapshot then returns NULL,
/// and only a fresh read from disk can make a new one. Close with
/// rish_agent_wal_close.
void *rish_agent_wal_open(const char *json, size_t json_length);
char *rish_agent_wal_snapshot(void *handle);
char *rish_agent_wal_begin(void *handle, const char *json, size_t json_length);
char *rish_agent_wal_confirm(void *handle, const char *outcome, size_t outcome_length);
void rish_agent_wal_close(void *handle);

/// The frozen tool table over {"op","guest_cgi"?,"root"?,"name"?,"registry"?}:
/// toolset_sha256, registry, policy, descriptor, native_descriptor,
/// registry_shape. Whether this build has the guest CGI tools is the host's
/// to say and changes the toolset digest.
char *rish_agent_tool_registry_reduce(const char *json, size_t json_length);

/// One agent-policy decision over {"op",...}: request_shape, budget_shape,
/// root_matches_request, projection. The projection is handed to the UI, so
/// its keys are enumerated rather than copied: no path, no descriptor table,
/// no arguments, nothing that could be mistaken for an authority handle.
char *rish_agent_policy_reduce(const char *json, size_t json_length);

/// One chat-read-v1 project-context policy decision over {"op",...}:
/// normalize, path_decision, content_decision. Which of a repository may be
/// sent to a model is decided here; case folding stays with the host, because
/// Foundation folds with CFStringFold and the core carries no folding table.
/// `content` carries a file's raw bytes for content_decision (any bytes, empty
/// allowed) and may be NULL for the other ops.
char *rish_agent_project_context_reduce(const char *json, size_t json_length,
                                        const uint8_t *content, size_t content_length);

/// Parses one provider completion response over
/// {"op":"parse","response","requested_model","model_supported","thinking_mode",
/// "fallback_call_id"}. This is where untrusted model output becomes something
/// executable. The reply is {"ok":true,"parsed":{...}} or
/// {"ok":false,"failure_code":"E_COMPLETION_..."} — a failure code, not a store
/// error code, because a provider reply is not a store operation.
char *rish_agent_completion_response_reduce(const char *json, size_t json_length);

/// One Git-tool decision over {"op",...}: timezone_string, timezone_minutes,
/// index_digest,
/// commit_identity, failure_result. libgit2 stays with the host; which staged
/// paths may be committed, the exact bytes of the commit object and therefore
/// the id it will have are decided here — predicting that id is what makes a
/// crash between writing the object and recording it recoverable.
char *rish_agent_git_tool_reduce(const char *json, size_t json_length);

/// One project-module decision over {"op",...}: canonical_oid,
/// canonical_operation_id, bounded_string, clip_utf8, stable_error_code.
/// JavaScript branches on the stable code, so the mapping from an internal
/// failure in one of three domains is contract; an unrecognised failure is
/// E_PROJECT_NATIVE rather than a guess.
char *rish_agent_project_module_reduce(const char *json, size_t json_length);

/// One runtime-environment decision over {"op",...}: valid_environment_id,
/// valid_program_environment_id, valid_workspace_id, valid_https_url,
/// validate_manifest. The host still creates directories, measures capacity,
/// protects files, hashes and streams a package; what an identity or a
/// manifest has to be is decided here.
///
/// The download URL arrives already parsed, as
/// {"text","parsed","scheme","host","has_user","has_password","has_fragment"}:
/// NSURLComponents is what decides today what counts as a host or a fragment,
/// and substituting another parser would change which downloads are accepted
/// without anything saying so. An absent component is null, never "".
char *rish_agent_runtime_environment_reduce(const char *json, size_t json_length);

/// One project-context-bridge decision over {"op",...}: safe_relative_path,
/// bounded_string. A reported path stays inside the project: no leading slash,
/// no backslash, no NUL, no control or format characters, and every component
/// a real name. This is not the agent's tool-argument path rule; the two have
/// different bounds and are deliberately kept apart.
char *rish_agent_project_context_bridge_reduce(const char *json, size_t json_length);

/// One project-context-service decision over {"op",...}: reference_id,
/// roots_equal, canonical_digest, bounded_string. The reference id is derived
/// from the whole authority tuple rather than chosen, so two workspaces using
/// one conversation id cannot evict or authorise one another's snapshot.
char *rish_agent_project_context_service_reduce(const char *json, size_t json_length);

/// One project-context-store decision over {"op",...}: canonical_snapshot_id,
/// safe_reference_key, hex_digest, settable_reference_key,
/// prepare_transaction_key, recover_references. A reference is a name pointing
/// at a snapshot; only retry: keys may be set by a caller, and a txn:prepare:
/// key still present at launch means the process died mid-swap.
char *rish_agent_project_context_store_reduce(const char *json, size_t json_length);

/// One container-anchor decision over {"op",...}: anchor_segment_count,
/// last_app_container_index, canonical_uuid_text. Where a path stops being the
/// app's own container: the innermost Containers/Data/Application/<UUID> tail
/// wins, a root carrying anything after its UUID is not a root, and traversal
/// is refused before an anchor is derived. Splitting the path stays with the
/// host.
char *rish_agent_container_anchor_reduce(const char *json, size_t json_length);

/// One project-access decision over {"op",...}: root_ref_valid,
/// canonical_root_ref, binding_valid, binding_digest, stored_metadata_valid,
/// legacy_display_name. A binding restates its root reference's identity and
/// the root fingerprint, so it cannot be read as belonging to a root it was
/// not written for. Its digest leaves out the private git directory path,
/// which differs between installs of one project.
char *rish_agent_project_access_reduce(const char *json, size_t json_length);

/// One workspace-clearance decision over {"op",...}: operation_shape,
/// receipt_shape, session_reference_valid, receipt_authorises. A clearance is
/// the proof that a destructive workspace operation was authorised against a
/// specific committed session, so its receipt names that session's generation
/// and digest. Its bounds are the workspace receipt store's, not a second set.
char *rish_agent_workspace_clearance_reduce(const char *json, size_t json_length);

/// One workspace-error decision over {"op",...}: projection, codes. Which
/// public code and message a workspace failure is reported as. A caller
/// branches on the code and a person's retry depends on it, so the mapping is
/// contract rather than a lookup table. A number this engine does not define
/// projects to null; no code is invented for it.
char *rish_agent_workspace_error_reduce(const char *json, size_t json_length);

/// Whether stored workspace bytes are JSON this engine will look at: one
/// complete value, at most 64 levels and 100,000 nodes, no duplicate keys in
/// any object, no negative zero, and nothing after it. Takes the raw bytes
/// rather than an envelope, because the question is about bytes that may not
/// be JSON. Returns 1 for acceptable, 0 otherwise.
unsigned char rish_agent_workspace_json_bounded(const char *bytes, size_t length);

/// One workspace-journal decision over {"op",...}: journal_shape,
/// legacy_journal_shape, readable_journal, identity_present, identity_matches,
/// owned_authority_matches, create_request_sha256, bootstrap_request_sha256.
/// A journal binds itself to its own request, a phase says which digests exist
/// yet, and physical identity is recorded in fours. Statting stays with the
/// host: it passes st_dev/st_ino/st_uid/st_gid as the canonical decimal
/// strings the journal holds.
char *rish_agent_workspace_journal_reduce(const char *json, size_t json_length);

/// One workspace read-tool decision over {"op",...}: tool_name_valid,
/// tool_options_valid, output_length_valid, tools. The tool list is closed —
/// six named readers over a folder a person granted — and an option key the
/// rule does not recognise is refused rather than ignored.
char *rish_agent_workspace_read_tools_reduce(const char *json, size_t json_length);

/// One workspace-receipt decision over {"op",...}: receipt_shape,
/// legacy_receipt_shape, readable_receipt, store_shape, public_receipt,
/// expired. The public projection withholds request_sha256, which is how a
/// retry is recognised. Parsing the committed timestamp stays with the host;
/// it passes the age it measured, and an unreadable one counts as expired.
char *rish_agent_workspace_receipt_reduce(const char *json, size_t json_length);

/// One workspace-record decision over {"op",...}: record_shape, display_name,
/// capabilities_array, binding_revision_advance. The origin fixes the locator
/// kind, the location class and which optional identity is present; folding
/// stays with the host, because Foundation folds case and diacritics together
/// under en_US_POSIX.
char *rish_agent_workspace_record_reduce(const char *json, size_t json_length);

/// One workspace-authority decision over {"op",...}: owned, bookmark, granted,
/// legacy, their three migrations, legacy_physical_identity, legacy_evidence,
/// capabilities_set, legacy_identity_matches_authority and
/// ordered_capabilities. Each shape restates its record's identity and ends in
/// the fingerprint. Base64 decoding stays with the host: the decoded
/// bookmark's length and SHA-256 come in as facts, the cap and the match stay
/// in the core. A migration answers with an authority, or null when the one it
/// was given cannot be upgraded.
char *rish_agent_workspace_authority_reduce(const char *json, size_t json_length);

/// One workspace directory-name decision over {"op",...}: internal_component,
/// candidate. The host walks ordinals and folds each candidate, because
/// folding is host-specific; what each ordinal is called, and where a name is
/// cut to make room for its suffix, are the rule. Truncation is a projection:
/// the host supplies the display name's grapheme clusters, the core picks the
/// cut, so a cluster is never split.
char *rish_agent_workspace_directory_name_reduce(const char *json, size_t json_length);

/// One workspace-grant decision over {"op",...}: operational_grants,
/// descriptor. Which grants a locator kind implies and how they are shown;
/// deriving the status itself stays with the host, because it resolves a
/// bookmark and stats a directory.
char *rish_agent_workspace_grants_reduce(const char *json, size_t json_length);

/// One workspace root-fingerprint decision over {"op",...}: fingerprint,
/// authority_digest, fingerprint_input, fingerprint_valid. This is what binds
/// a workspace authority to a physical directory, so an authority written by
/// one platform must validate on the other.
char *rish_agent_workspace_fingerprint_reduce(const char *json, size_t json_length);

/// One workspace-tool decision over {"op",...}: bounds, path_components,
/// revision, directory_entry_decision, directory_listing, diff_preview,
/// write_expected_prior, feedback, failure_result. The host owns the descriptors and the bytes; which paths it
/// may touch, what a listing looks like and what a person is shown before
/// approving a write are decided here.
char *rish_agent_workspace_tool_reduce(const char *json, size_t json_length);

/// The frozen root projection over {"op",...}: projection_shape, capabilities,
/// grants, resolve_request, workspace_projection, project_projection, root_ref,
/// operation_mode, final_proof_request, matches. Resolving a root is the
/// host's job; every judgement it makes on the way is decided here.
char *rish_agent_root_reduce(const char *json, size_t json_length);

/// One runtime-coordinator decision over
/// {"op","request","state"?,"session"?,"facts"?,"proof"?,"base"?,"queried"?}:
/// query_tool_request, query_attempt_request, presentations_request,
/// session_proof, session_owns_attempt, query_tool_session_conflict,
/// query_tool_ledger_conflict, query_tool_result,
/// query_attempt_session_conflict, query_attempt_base_conflict,
/// query_attempt_projection, tool_projection, latest_batch_calls,
/// cleanup_outbox_proof, cancel_source_proof, child_operation_id.
char *rish_agent_runtime_reduce(const char *json, size_t json_length);

/// One provider-round decision over {"op","request",...}: round_request,
/// selector_request, selector_matches, result_shape, round_cas, locator_key,
/// assistant_message, public_receipt, recovered_projection, context_bundle,
/// conflict, unknown_result, round_result, query_result, selector_conflict,
/// failure_code, safe_result, tool_description, transcript_body,
/// started_operation_commit, public_result, round_failure_code.
char *rish_agent_provider_round_reduce(const char *json, size_t json_length);

/// "rish-agent-core <version> <git sha>" of the linked build; free with
/// rish_agent_string_free.
char *rish_agent_build_id(void);

#ifdef __cplusplus
}
#endif

#endif
