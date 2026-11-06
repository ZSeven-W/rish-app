//! `rish-agent-core` is the platform-independent half of the Rish agent
//! engine. The iOS app currently implements the engine in Objective-C++
//! (`modules/rish/ios/Sources/Agent*.mm`); this crate takes it over one
//! component at a time behind the existing native interfaces, with the ObjC
//! test suites as the oracle. See the plan in the document centre
//! (`rish-app/plans/2026-09-14-shared-agent-core-astra.md`).
//!
//! Phase 0: canonical JSON, domain-separated hashing, and the strict argument
//! parser, pinned byte for byte to the ObjC engine by
//! `fixtures/canonical-golden.json`.
//!
//! Phase 1: the schema-3 round journal as a pure reducer
//! ([`round_journal`]), driven by the ObjC facade that still owns the WAL
//! transaction, and the bounded primitive validators it needs ([`schema`]).

pub mod agent_policy;
pub mod assistant_context;
pub mod assistant_tools;
pub mod canonical;
pub mod completion_reply;
pub mod completion_request;
pub mod completion_response;
pub mod completion_stream;
pub mod container_anchor;
pub mod custom_provider_registry;
pub mod execution_ledger;
pub mod git_remote_policy;
pub mod git_tool;
pub mod ledger_batch;
pub mod ledger_ops;
pub mod model_catalog;
pub mod name_policy;
pub mod prepared_attempt;
pub mod project_access;
pub mod project_context_bridge;
pub mod project_context_policy;
pub mod project_context_secrets;
pub mod project_context_service;
pub mod project_context_store;
pub mod project_module;
pub mod provider_model_catalog;
pub mod provider_model_discovery;
pub mod provider_policy;
pub mod provider_round;
pub mod root_projection;
pub mod round_journal;
pub mod round_presentation;
pub mod runtime_coordinator;
pub mod runtime_environment;
pub mod runtime_tools;
pub mod schema;
pub mod session_schema;
pub mod store;
pub mod strict_json;
pub mod tool_batch;
pub mod tool_execution;
pub mod tool_registry;
pub mod transcript_store;
pub mod user_question;
pub mod wal_operations;
pub mod wal_resident;
pub mod wal_state;
pub mod workspace_authority;
pub mod workspace_clearance;
pub mod workspace_directory_name;
pub mod workspace_error;
pub mod workspace_fingerprint;
pub mod workspace_grants;
pub mod workspace_journal;
pub mod workspace_json;
pub mod workspace_read_tools;
pub mod workspace_receipt;
pub mod workspace_record;
pub mod workspace_tool;
mod write_parent_plan;

/// Protocol version reported over the C ABI. Bumped when the JSON contract
/// of any exported operation changes incompatibly.
pub const PROTOCOL_VERSION: u32 = 1;
