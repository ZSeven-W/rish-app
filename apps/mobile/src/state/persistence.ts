import { agentAmbiguityCode } from '../agent/AgentAmbiguity';
import { hasFrozenConversationGrant, hasLiveConversationGrant, isConversationGrantBoundCall } from '../agent/agent-conversation-grants';
import { ALL_AGENT_TOOL_NAMES, ALL_AGENT_AUTO_TOOLS, agentToolRegistryCompatible } from '../agent/tool-registry';
import { parseProviderBinding } from '../providers/configuration';
import {
  ATTACHMENT_CHAT_STATE_SCHEMA_VERSION,
  AGENT_ATTEMPT_JOURNAL_SCHEMA_VERSION,
  AGENT_ATTEMPT_JOURNAL_SCHEMA_VERSION_V3,
  AGENT_CALL_JOURNAL_SCHEMA_VERSION,
  AGENT_CALL_JOURNAL_SCHEMA_VERSION_V3,
  AGENT_CLEANUP_SCHEMA_VERSION,
  AGENT_FAILURE_CODES,
  AGENT_GRANT_SCHEMA_VERSION,
  AGENT_ROOT_SCHEMA_VERSION,
  AGENT_SAFE_SUMMARY_KEYS,
  AGENT_ROUND_LINEAGE_SCHEMA_VERSION,
  AGENT_TRANSCRIPT_REFERENCE_SCHEMA_VERSION,
  AGENT_WRITE_POLICY_SCHEMA_VERSION,
  CHAT_STATE_SCHEMA_VERSION_V8,
  MAX_AGENT_ATTEMPT_WRITE_BYTES,
  MAX_AGENT_BATCH_WRITE_BYTES,
  MAX_AGENT_CALLS_PER_BATCH,
  MAX_AGENT_CLEANUP_OUTBOX_ENTRIES,
  MAX_AGENT_GRANTS_PER_CONVERSATION,
  MAX_AGENT_ROUNDS,
  MAX_AGENT_SINGLE_WRITE_BYTES,
  MAX_AGENT_RESULT_BYTES,
  MAX_AGENT_SUMMARY_KEY_LENGTH,
  MAX_AGENT_DURATION_MS,
  MAX_AGENT_TRANSCRIPT_BYTES,
  MAX_SESSION_EVENT_ROWS,
  PERSISTED_TURN_ATTEMPT_SCHEMA_VERSION,
  SESSION_EVENT_V2_SCHEMA_VERSION,
  PERSISTED_TURN_ATTEMPT_SCHEMA_VERSION_V3,
  ATTEMPT_CONTEXT_DISPOSITIONS,
  ATTEMPT_PROJECT_CONTEXT_SCHEMA_VERSION,
  ATTACHMENT_DESCRIPTOR_SCHEMA_VERSION,
  CHAT_STATE_SCHEMA_VERSION,
  CONVERSATION_WORKSPACE_BINDING_SCHEMA_VERSION,
  CONVERSATION_WORKSPACE_BOOTSTRAP_STATES,
  COMPLETION_FINISH_REASONS,
  COMPLETION_ROUND_RECEIPT_SCHEMA_VERSION,
  CONVERSATION_TURN_SCHEMA_VERSION,
  LEGACY_CHAT_STATE_SCHEMA_VERSION,
  OLDER_CHAT_STATE_SCHEMA_VERSION,
  PREVIOUS_CHAT_STATE_SCHEMA_VERSION,
  PROJECT_CONTEXT_CHAT_STATE_SCHEMA_VERSION,
  WORKSPACE_CHAT_STATE_SCHEMA_VERSION,
  PROJECT_CONTEXT_DESTRUCTIVE_ACTIONS,
  PROJECT_CONTEXT_DESTRUCTIVE_PHASES,
  PROJECT_CONTEXT_DESTRUCTIVE_TRANSITION_SCHEMA_VERSION,
  WORKSPACE_AUTHORITY_OUTBOX_SCHEMA_VERSION,
  TURN_ATTEMPT_SCHEMA_VERSION,
  TURN_ATTEMPT_STATUSES,
  ChatStateValidationError,
  type ChatAttachment,
  type ChatMessage,
  type ChatMessageMetadata,
  type ChatState,
  type AgentAccess,
  type AgentCapability,
  type AgentRegistryVersion,
  type AgentConversationGrantV2,
  type AgentApprovalTokenV1,
  type AgentApprovalBindingTokenV2,
  type AgentApprovalTokenMigrationV3,
  type AgentControllerCASV1,
  type AgentApprovalDecision,
  type AgentFailureCode,
  type AgentToolReceiptV1,
  type AgentWritePolicyV1,
  type AgentTranscriptCleanupV1,
  type AgentTranscriptReferenceV1,
  type FrozenAgentRootV1,
  type PersistedAgentAttemptJournalV3,
  type PersistedAgentCallJournalV3,
  type PersistedAgentRoundLineageV2,
  type SessionEventV2,
  type CompletionRoundReceiptV1,
  type Conversation,
  type ConversationTurnV1,
  type HydrationResult,
  type PersistedChatAttachmentV1,
  type PersistedChatMessageV4,
  type PersistedChatStateV8,
  type PersistedSessionSnapshotV9,
  type PersistedTurnAttemptV3,
  type PersistedSessionEventV3,
  type AgentCancelEventV2,
  type PersistedConversationWorkspaceBindingV1,
  type PersistedWorkspaceAuthorityOutboxV1,
  type PersistedCompletionRoundReceiptV1,
  type PersistedConversationTurnV1,
  type TurnAttemptStatus,
  type AttemptContextDisposition,
  type TurnAttemptV1,
  type ProjectContextDestructiveTransitionV1,
  type ConversationWorkspaceBindingV1,
  type ConversationWorkspaceBootstrapState,
  type WorkspaceAuthorityOutboxV1,
  isAgentPhaseLineageValid,
} from './types';
import {
  DEFAULT_THINKING_MODE,
  MAX_ATTACHMENT_ID_LENGTH,
  MAX_ATTACHMENT_NAME_LENGTH,
  MAX_ATTACHMENTS_PER_MESSAGE,
  MAX_TOTAL_ATTACHMENT_SIZE,
  MAX_ATTEMPT_VISIBLE_MESSAGES,
  MAX_ATTEMPT_ATTACHMENT_IDS,
  MAX_PROJECT_CONTEXT_RECEIPT_BYTES,
  MAX_COMPLETION_ROUNDS,
  isAttemptFailureCode,
  isCanonicalTimestamp,
  isCanonicalLifecycleId,
  isAttachmentMimeType,
  isAttachmentSize,
  isChatAttachmentKind,
  isConversationThinkingMode,
  isModelId,
  isProjectId,
  isSha256Digest,
  isWorkspaceId,
  orderConversationIds,
  selectActiveMessages,
  hasProjectContextDestructiveReferences,
  hasWorkspaceAuthorityReferences,
  MAX_WORKSPACE_AUTHORITY_OUTBOX_ENTRIES,
} from './reducer';
import {
  createProjectContextState,
  isProjectContextSendable,
} from '../project-context/reducer';
import {
  hydrateProjectContextState,
  serializeProjectContextState,
} from '../project-context/persistence';
import type { ProjectContextState } from '../project-context/types';
import { DEFAULT_APP_PREFERENCES } from '../preferences/reducer';
import { isHarnessId, isProviderId, type ProviderId } from '../harness/types';
import {
  hydrateAppPreferences,
  serializeAppPreferences,
} from '../preferences/persistence';
import type { PersistedAppPreferencesV1 } from '../preferences/types';

const MAX_CONVERSATIONS = 10_000;
const MAX_MESSAGES_PER_CONVERSATION = 100_000;
const MAX_ID_LENGTH = 256;
const MAX_TITLE_LENGTH = 120;
const MAX_MESSAGE_LENGTH = 1_000_000;
const MAX_TURNS_PER_CONVERSATION = 100_000;
const MAX_ATTEMPTS_PER_CONVERSATION = 100_000;
const MAX_ATTEMPT_MESSAGE_REFERENCES = 1_000_000;
const MAX_OPAQUE_ID_LENGTH = 128;
const finishReasons: ReadonlySet<string> = new Set(COMPLETION_FINISH_REASONS);
const attemptStatuses: ReadonlySet<string> = new Set(TURN_ATTEMPT_STATUSES);
const contextDispositions: ReadonlySet<string> = new Set(
  ATTEMPT_CONTEXT_DISPOSITIONS,
);
const destructiveActions: ReadonlySet<string> = new Set(
  PROJECT_CONTEXT_DESTRUCTIVE_ACTIONS,
);
const destructivePhases: ReadonlySet<string> = new Set(
  PROJECT_CONTEXT_DESTRUCTIVE_PHASES,
);
const opaqueIdPattern = /^[A-Za-z0-9._:-]+$/u;

type PersistedSchemaVersion =
  | typeof LEGACY_CHAT_STATE_SCHEMA_VERSION
  | typeof OLDER_CHAT_STATE_SCHEMA_VERSION
  | typeof ATTACHMENT_CHAT_STATE_SCHEMA_VERSION
  | typeof WORKSPACE_CHAT_STATE_SCHEMA_VERSION
  | typeof PROJECT_CONTEXT_CHAT_STATE_SCHEMA_VERSION
  | typeof PREVIOUS_CHAT_STATE_SCHEMA_VERSION
  | typeof CHAT_STATE_SCHEMA_VERSION_V8
  | typeof CHAT_STATE_SCHEMA_VERSION;

export type AgentHydrationAuthorityV1 = {
  readonly schema_version: 1;
  readonly generation: number;
  readonly session_sha256: string;
};

export type AgentHydrationNativeEnvelopeV1 = {
  readonly schema_version: 1;
  readonly journal_revision: number;
  readonly session_generation: number;
  readonly session_sha256: string;
};

export type ChatHydrationOptionsV1 = {
  /** Native session authority used to verify legacy approval CAS bindings. */
  readonly sessionAuthority?: AgentHydrationAuthorityV1;
  /** Committed checkpoint envelope used by production root hydration. */
  readonly nativeEnvelope?: AgentHydrationNativeEnvelopeV1;
  /**
   * True when the persisted envelope was written by a previous process
   * launch.  Every non-terminal attempt then belongs to a dead writer and
   * is interrupted deterministically at hydration: marked failed with
   * E_ATTEMPT_INTERRUPTED (its Agent journal is retained as evidence but
   * can never be resumed) and, for journaled attempts, a transcript-cleanup
   * outbox entry is enqueued for native discard while outbox capacity
   * remains.  Defaults to false so existing hydration semantics hold.
   */
  readonly staleWriterLaunch?: boolean;
};

type NormalizedChatHydrationOptions = {
  readonly sessionAuthority?: AgentHydrationAuthorityV1;
  readonly nativeJournalRevision?: number;
  readonly staleWriterLaunch: boolean;
};

function parseHydrationAuthority(
  value: unknown,
): AgentHydrationAuthorityV1 {
  const raw = exactRecord(value, '$.session_authority', [
    'schema_version',
    'generation',
    'session_sha256',
  ]);
  if (raw.schema_version !== 1) {
    return invalid('$.session_authority.schema_version', 'must equal 1');
  }
  const generation = lifecycleEpoch(
    raw.generation,
    '$.session_authority.generation',
    false,
  );
  if (generation >= Number.MAX_SAFE_INTEGER) {
    return invalid(
      '$.session_authority.generation',
      'must leave room for the next generation',
    );
  }
  return {
    schema_version: 1,
    generation,
    session_sha256: sha256(
      raw.session_sha256,
      '$.session_authority.session_sha256',
    ),
  };
}

function parseHydrationNativeEnvelope(
  value: unknown,
): AgentHydrationNativeEnvelopeV1 {
  const raw = exactRecord(value, '$.native_envelope', [
    'schema_version',
    'journal_revision',
    'session_generation',
    'session_sha256',
  ]);
  if (raw.schema_version !== 1) {
    return invalid('$.native_envelope.schema_version', 'must equal 1');
  }
  const journalRevision = nonNegativeSafeInteger(
    raw.journal_revision,
    '$.native_envelope.journal_revision',
  );
  if (journalRevision >= Number.MAX_SAFE_INTEGER) {
    return invalid(
      '$.native_envelope.journal_revision',
      'must leave room for the next revision',
    );
  }
  const sessionGeneration = lifecycleEpoch(
    raw.session_generation,
    '$.native_envelope.session_generation',
    false,
  );
  if (sessionGeneration >= Number.MAX_SAFE_INTEGER) {
    return invalid(
      '$.native_envelope.session_generation',
      'must leave room for the next generation',
    );
  }
  return {
    schema_version: 1,
    journal_revision: journalRevision,
    session_generation: sessionGeneration,
    session_sha256: sha256(
      raw.session_sha256,
      '$.native_envelope.session_sha256',
    ),
  };
}

function hasWorkspaceShape(schemaVersion: PersistedSchemaVersion): boolean {
  return (
    schemaVersion === WORKSPACE_CHAT_STATE_SCHEMA_VERSION ||
    schemaVersion === PROJECT_CONTEXT_CHAT_STATE_SCHEMA_VERSION ||
    schemaVersion === PREVIOUS_CHAT_STATE_SCHEMA_VERSION ||
    schemaVersion === CHAT_STATE_SCHEMA_VERSION_V8 ||
    schemaVersion === CHAT_STATE_SCHEMA_VERSION
  );
}

function hasProjectContextShape(
  schemaVersion: PersistedSchemaVersion,
): boolean {
  return (
    schemaVersion === PREVIOUS_CHAT_STATE_SCHEMA_VERSION ||
    schemaVersion === PROJECT_CONTEXT_CHAT_STATE_SCHEMA_VERSION ||
    schemaVersion === CHAT_STATE_SCHEMA_VERSION_V8 ||
    schemaVersion === CHAT_STATE_SCHEMA_VERSION
  );
}

function hasWorkspaceRoutingShape(
  schemaVersion: PersistedSchemaVersion,
): boolean {
  return (
    schemaVersion === CHAT_STATE_SCHEMA_VERSION_V8 ||
    schemaVersion === CHAT_STATE_SCHEMA_VERSION
  );
}

function hasDestructiveJournalShape(
  schemaVersion: PersistedSchemaVersion,
): boolean {
  return (
    schemaVersion === PREVIOUS_CHAT_STATE_SCHEMA_VERSION ||
    schemaVersion === CHAT_STATE_SCHEMA_VERSION_V8 ||
    schemaVersion === CHAT_STATE_SCHEMA_VERSION
  );
}

function hasAgentSchema(schemaVersion: PersistedSchemaVersion): boolean {
  return schemaVersion === CHAT_STATE_SCHEMA_VERSION;
}

type UnknownRecord = Record<string, unknown>;

function invalid(path: string, message: string): never {
  throw new ChatStateValidationError(path, message);
}

function record(value: unknown, path: string): UnknownRecord {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    return invalid(path, 'must be an object');
  }
  return value as UnknownRecord;
}

function exactRecord(
  value: unknown,
  path: string,
  keys: readonly string[],
  optionalKeys: readonly string[] = [],
): UnknownRecord {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    return invalid(path, 'must be an object');
  }
  const prototype = Object.getPrototypeOf(value);
  if (prototype !== Object.prototype && prototype !== null) {
    return invalid(path, 'must be a plain record');
  }
  if (Object.getOwnPropertySymbols(value).length > 0) {
    return invalid(path, 'must not contain symbol properties');
  }
  const allowed = new Set([...keys, ...optionalKeys]);
  const optional = new Set(optionalKeys);
  Object.getOwnPropertyNames(value).forEach(key => {
    if (!allowed.has(key)) invalid(`${path}.${key}`, 'is not recognized');
  });
  const raw = Object.create(null) as UnknownRecord;
  allowed.forEach(key => {
    const descriptor = Object.getOwnPropertyDescriptor(value, key);
    if (descriptor === undefined) {
      if (optional.has(key)) return;
      invalid(`${path}.${key}`, 'is required');
    }
    if (
      !Object.prototype.hasOwnProperty.call(descriptor, 'value') ||
      descriptor.enumerable !== true
    ) {
      invalid(`${path}.${key}`, 'must be an own data property');
    }
    raw[key] = descriptor.value;
  });
  return raw;
}

function array(value: unknown, path: string, maximumLength: number): unknown[] {
  if (
    !Array.isArray(value) ||
    Object.getPrototypeOf(value) !== Array.prototype
  ) {
    return invalid(path, 'must be an array');
  }
  const lengthDescriptor = Object.getOwnPropertyDescriptor(value, 'length');
  if (
    lengthDescriptor === undefined ||
    !Object.prototype.hasOwnProperty.call(lengthDescriptor, 'value') ||
    !Number.isSafeInteger(lengthDescriptor.value) ||
    lengthDescriptor.value < 0 ||
    lengthDescriptor.value > maximumLength
  ) {
    return invalid(path, 'exceeds the array limit');
  }
  const length = lengthDescriptor.value as number;
  if (Object.getOwnPropertySymbols(value).length > 0) {
    return invalid(path, 'must not contain symbol properties');
  }
  const names = Object.getOwnPropertyNames(value);
  const allowed = new Set<string>(['length']);
  const result: unknown[] = [];
  for (let index = 0; index < length; index += 1) {
    const key = String(index);
    allowed.add(key);
    const descriptor = Object.getOwnPropertyDescriptor(value, key);
    if (
      descriptor === undefined ||
      !Object.prototype.hasOwnProperty.call(descriptor, 'value') ||
      descriptor.enumerable !== true
    ) {
      return invalid(`${path}[${index}]`, 'must be a dense data array');
    }
    result[index] = descriptor.value;
  }
  names.forEach(name => {
    if (!allowed.has(name)) invalid(`${path}.${name}`, 'is not recognized');
  });
  return result;
}

function boundedString(
  value: unknown,
  path: string,
  maximumLength: number,
  allowEmpty = false,
): string {
  if (typeof value !== 'string') {
    return invalid(path, 'must be a string');
  }
  if (
    (!allowEmpty && value.trim().length === 0) ||
    value.length > maximumLength
  ) {
    return invalid(
      path,
      `must contain ${
        allowEmpty ? 'at most' : 'between 1 and'
      } ${maximumLength} characters`,
    );
  }
  return value;
}

function timestamp(value: unknown, path: string): string {
  if (!isCanonicalTimestamp(value)) {
    return invalid(path, 'must be a canonical ISO-8601 timestamp');
  }
  return value;
}

function canonicalLifecycleId(value: unknown, path: string): string {
  if (!isCanonicalLifecycleId(value)) {
    return invalid(path, 'must be a canonical lowercase UUID');
  }
  return value;
}

/**
 * Deterministic cleanup identity for an interrupted attempt.  The derived id
 * is a canonical lowercase UUID that differs from the source attempt id in
 * its version and variant nibbles, so repeated hydration of the same
 * persisted session enqueues byte-identical entries and the identity can
 * never collide with the attempt id it belongs to.  Attempt ids are always
 * generated with version nibble '4' and variant nibble in 8-b, while this
 * derivation pins 'd' and 'c', so a derived id can never equal any generated
 * attempt id.
 */
function interruptedCleanupIdForAttempt(attemptId: string): string {
  const versionNibble = attemptId.charAt(14);
  const variantNibble = attemptId.charAt(19);
  const version = versionNibble === 'd' ? '4' : 'd';
  const variant = variantNibble === 'c' ? '8' : 'c';
  return (
    attemptId.slice(0, 14) +
    version +
    attemptId.slice(15, 19) +
    variant +
    attemptId.slice(20)
  );
}

function sha256(value: unknown, path: string): string {
  if (!isSha256Digest(value)) {
    return invalid(path, 'must be a lowercase SHA-256 digest');
  }
  return value;
}

function nonNegativeSafeInteger(value: unknown, path: string): number {
  if (
    typeof value !== 'number' ||
    !Number.isSafeInteger(value) ||
    Object.is(value, -0) ||
    value < 0
  ) {
    return invalid(path, 'must be a non-negative safe integer');
  }
  return value;
}

function lifecycleEpoch(
  value: unknown,
  path: string,
  allowZero: boolean,
): number {
  if (
    typeof value !== 'number' ||
    !Number.isSafeInteger(value) ||
    Object.is(value, -0) ||
    value < (allowZero ? 0 : 1)
  ) {
    return invalid(
      path,
      allowZero
        ? 'must be a non-negative safe integer without negative zero'
        : 'must be a positive safe integer',
    );
  }
  return value;
}

function parseDestructiveTransition(
  value: unknown,
  path: string,
): ProjectContextDestructiveTransitionV1 {
  const raw = exactRecord(value, path, [
    'schema_version',
    'lifecycle_id',
    'epoch',
    'action',
    'phase',
    'conversation_id',
    'source_project_id',
    'source_runtime_context_id',
    'source_model_id',
    'snapshot_id',
    'snapshot_sha256',
    'consent_receipt_id',
    'target_project_id',
    'created_at',
    'updated_at',
  ]);
  if (
    raw.schema_version !== PROJECT_CONTEXT_DESTRUCTIVE_TRANSITION_SCHEMA_VERSION
  ) {
    return invalid(`${path}.schema_version`, 'must equal 1');
  }
  if (typeof raw.action !== 'string' || !destructiveActions.has(raw.action)) {
    return invalid(`${path}.action`, 'is not a supported destructive action');
  }
  if (typeof raw.phase !== 'string' || !destructivePhases.has(raw.phase)) {
    return invalid(`${path}.phase`, 'is not a supported lifecycle phase');
  }
  if (!isProjectId(raw.source_project_id)) {
    return invalid(`${path}.source_project_id`, 'must be a valid project id');
  }
  if (!isModelId(raw.source_model_id)) {
    return invalid(`${path}.source_model_id`, 'must be a supported model');
  }
  const sourceRuntimeContextId =
    raw.source_runtime_context_id === null
      ? null
      : canonicalLifecycleId(
          raw.source_runtime_context_id,
          `${path}.source_runtime_context_id`,
        );
  const consentReceiptId =
    raw.consent_receipt_id === null
      ? null
      : canonicalLifecycleId(
          raw.consent_receipt_id,
          `${path}.consent_receipt_id`,
        );
  const targetProjectId =
    raw.target_project_id === null ? null : raw.target_project_id;
  if (targetProjectId !== null && !isProjectId(targetProjectId)) {
    return invalid(
      `${path}.target_project_id`,
      'must be a valid project id or null',
    );
  }
  if (
    (raw.action === 'rebind') !== (targetProjectId !== null) ||
    (raw.action === 'rebind' && targetProjectId === raw.source_project_id)
  ) {
    return invalid(
      `${path}.target_project_id`,
      'must be a distinct project only for rebind',
    );
  }
  const createdAt = timestamp(raw.created_at, `${path}.created_at`);
  const updatedAt = timestamp(raw.updated_at, `${path}.updated_at`);
  if (Date.parse(updatedAt) < Date.parse(createdAt)) {
    return invalid(`${path}.updated_at`, 'must not precede created_at');
  }
  return {
    schemaVersion: PROJECT_CONTEXT_DESTRUCTIVE_TRANSITION_SCHEMA_VERSION,
    lifecycleId: canonicalLifecycleId(raw.lifecycle_id, `${path}.lifecycle_id`),
    epoch: lifecycleEpoch(raw.epoch, `${path}.epoch`, false),
    action: raw.action as ProjectContextDestructiveTransitionV1['action'],
    phase: raw.phase as ProjectContextDestructiveTransitionV1['phase'],
    conversationId: boundedString(
      raw.conversation_id,
      `${path}.conversation_id`,
      MAX_ID_LENGTH,
    ),
    sourceProjectId: raw.source_project_id,
    sourceRuntimeContextId,
    sourceModelId: raw.source_model_id,
    snapshotId: canonicalLifecycleId(raw.snapshot_id, `${path}.snapshot_id`),
    snapshotSha256: sha256(raw.snapshot_sha256, `${path}.snapshot_sha256`),
    consentReceiptId,
    targetProjectId: targetProjectId as string | null,
    createdAt,
    updatedAt,
  };
}

function parseWorkspaceBinding(
  value: unknown,
  path: string,
): ConversationWorkspaceBindingV1 {
  const raw = exactRecord(value, path, [
    'schema_version',
    'workspace_id',
    'binding_revision',
    'project_id',
  ]);
  if (raw.schema_version !== CONVERSATION_WORKSPACE_BINDING_SCHEMA_VERSION) {
    return invalid(`${path}.schema_version`, 'must equal 1');
  }
  if (!isCanonicalLifecycleId(raw.workspace_id)) {
    return invalid(`${path}.workspace_id`, 'must be a canonical workspace id');
  }
  const bindingRevision = lifecycleEpoch(
    raw.binding_revision,
    `${path}.binding_revision`,
    false,
  );
  if (bindingRevision >= Number.MAX_SAFE_INTEGER) {
    return invalid(
      `${path}.binding_revision`,
      'must be less than Number.MAX_SAFE_INTEGER',
    );
  }
  if (raw.project_id !== null && !isProjectId(raw.project_id)) {
    return invalid(`${path}.project_id`, 'must be a valid project id or null');
  }
  return {
    schemaVersion: CONVERSATION_WORKSPACE_BINDING_SCHEMA_VERSION,
    workspaceId: raw.workspace_id as string,
    bindingRevision,
    projectId: raw.project_id as string | null,
  };
}

function parseWorkspaceBootstrapState(
  value: unknown,
  path: string,
): ConversationWorkspaceBootstrapState {
  if (
    typeof value !== 'string' ||
    !CONVERSATION_WORKSPACE_BOOTSTRAP_STATES.includes(
      value as ConversationWorkspaceBootstrapState,
    )
  ) {
    return invalid(path, 'must be a supported workspace bootstrap state');
  }
  return value as ConversationWorkspaceBootstrapState;
}

function migratedLegacyWorkspaceState(
  value: unknown,
  projectId: string | null,
  path: string,
): {
  readonly workspaceId: string | null;
  readonly workspaceBinding: null;
  readonly workspaceBootstrapState: ConversationWorkspaceBootstrapState;
} {
  if (value === undefined || value === null) {
    return {
      workspaceId: null,
      workspaceBinding: null,
      workspaceBootstrapState:
        projectId === null ? 'none' : 'pending_legacy_project',
    };
  }
  if (typeof value !== 'string') {
    return invalid(path, 'must be a string or null');
  }
  if (!isWorkspaceId(value) || !isCanonicalLifecycleId(value)) {
    return {
      workspaceId: null,
      workspaceBinding: null,
      workspaceBootstrapState: 'blocked_invalid_legacy_id',
    };
  }
  return {
    workspaceId: null,
    workspaceBinding: null,
    workspaceBootstrapState:
      projectId === null
        ? 'pending_registry_resolution'
        : 'pending_legacy_project',
  };
}

function parseWorkspaceOutboxEntry(
  value: unknown,
  path: string,
): WorkspaceAuthorityOutboxV1 {
  const raw = exactRecord(value, path, [
    'schema_version',
    'operation_id',
    'action',
    'workspace_id',
    'binding_revision',
    'clearance_receipt_id',
    'created_at',
  ]);
  if (raw.schema_version !== WORKSPACE_AUTHORITY_OUTBOX_SCHEMA_VERSION) {
    return invalid(`${path}.schema_version`, 'must equal 1');
  }
  if (raw.action !== 'forget' && raw.action !== 'delete_owned') {
    return invalid(`${path}.action`, 'must be forget or delete_owned');
  }
  const bindingRevision = lifecycleEpoch(
    raw.binding_revision,
    `${path}.binding_revision`,
    false,
  );
  if (bindingRevision >= Number.MAX_SAFE_INTEGER) {
    return invalid(
      `${path}.binding_revision`,
      'must be less than Number.MAX_SAFE_INTEGER',
    );
  }
  return {
    schemaVersion: WORKSPACE_AUTHORITY_OUTBOX_SCHEMA_VERSION,
    operationId: canonicalLifecycleId(raw.operation_id, `${path}.operation_id`),
    action: raw.action,
    workspaceId: canonicalLifecycleId(raw.workspace_id, `${path}.workspace_id`),
    bindingRevision,
    clearanceReceiptId: canonicalLifecycleId(
      raw.clearance_receipt_id,
      `${path}.clearance_receipt_id`,
    ),
    createdAt: timestamp(raw.created_at, `${path}.created_at`),
  };
}

function opaqueProviderId(value: unknown, path: string): string {
  if (
    typeof value !== 'string' ||
    value.length === 0 ||
    value.length > MAX_OPAQUE_ID_LENGTH ||
    !opaqueIdPattern.test(value)
  ) {
    return invalid(path, 'must be a bounded opaque provider identifier');
  }
  return value;
}

function agentIdentifier(value: unknown, path: string): string {
  if (
    typeof value !== 'string' ||
    value.length === 0 ||
    value.length > MAX_ID_LENGTH ||
    !opaqueIdPattern.test(value)
  ) {
    return invalid(path, 'must be a bounded Agent identifier');
  }
  return value;
}

function boundedIdentifier(
  value: unknown,
  path: string,
  maximumBytes = MAX_ID_LENGTH,
): string {
  const result = boundedString(value, path, maximumBytes);
  const bytes = utf8ByteLength(result);
  if (bytes === null || bytes > maximumBytes) {
    return invalid(path, `must contain at most ${maximumBytes} UTF-8 bytes`);
  }
  return result;
}

function uniqueStringArray(
  value: unknown,
  path: string,
  maximum: number,
  canonicalIds = false,
): string[] {
  const raw = array(value, path, maximum);
  if (raw.length > maximum) {
    return invalid(path, `must contain no more than ${maximum} entries`);
  }
  const seen = new Set<string>();
  return raw.map((entry, index) => {
    const entryPath = `${path}[${index}]`;
    const parsed = canonicalIds
      ? canonicalLifecycleId(entry, entryPath)
      : boundedString(entry, entryPath, MAX_ID_LENGTH);
    if (seen.has(parsed)) return invalid(entryPath, 'must be unique');
    seen.add(parsed);
    return parsed;
  });
}

function utf8ByteLength(value: string): number | null {
  let bytes = 0;
  for (let index = 0; index < value.length; index += 1) {
    const unit = value.charCodeAt(index);
    if (unit <= 0x7f) {
      bytes += 1;
    } else if (unit <= 0x7ff) {
      bytes += 2;
    } else if (unit >= 0xd800 && unit <= 0xdbff) {
      const low = value.charCodeAt(index + 1);
      if (low < 0xdc00 || low > 0xdfff) return null;
      bytes += 4;
      index += 1;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      return null;
    } else {
      bytes += 3;
    }
  }
  return bytes;
}

function boundedUtf8(value: string, maximum: number): boolean {
  const bytes = utf8ByteLength(value);
  return bytes !== null && bytes > 0 && bytes <= maximum;
}

function hasControlCharacter(value: string, includeSpace = false): boolean {
  for (let index = 0; index < value.length; index += 1) {
    const unit = value.charCodeAt(index);
    if (
      unit <= (includeSpace ? 0x20 : 0x1f) ||
      (unit >= 0x7f && unit <= 0x9f)
    ) {
      return true;
    }
  }
  return false;
}

function safeProjectPath(value: string): boolean {
  if (
    !boundedUtf8(value, 4096) ||
    value.startsWith('/') ||
    value.includes('\\') ||
    hasControlCharacter(value)
  ) {
    return false;
  }
  return !value
    .split('/')
    .some(
      component => component === '' || component === '.' || component === '..',
    );
}

function safeProjectName(value: string): boolean {
  return (
    boundedUtf8(value, 120) &&
    value.trim() === value &&
    !hasControlCharacter(value) &&
    !value.includes('/') &&
    !value.includes('\\') &&
    value !== '.' &&
    value !== '..'
  );
}

function safeGitBranch(value: string | null): boolean {
  if (value === null) return true;
  return (
    boundedUtf8(value, 1024) &&
    value !== '@' &&
    !hasControlCharacter(value, true) &&
    !['~', '^', ':', '?', '*', '[', '\\'].some(character =>
      value.includes(character),
    ) &&
    !value.includes('..') &&
    !value.includes('@{') &&
    !value.startsWith('/') &&
    !value.endsWith('/') &&
    !value.startsWith('.') &&
    !value.endsWith('.') &&
    !value
      .split('/')
      .some(
        component =>
          component === '' ||
          component.startsWith('.') ||
          component.endsWith('.lock'),
      )
  );
}

function strictProjectTimestamp(value: string): boolean {
  return (
    boundedUtf8(value, 64) &&
    /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/u.test(
      value,
    ) &&
    Number.isFinite(Date.parse(value))
  );
}

function strictNonNegativeInteger(value: number, maximum: number): boolean {
  return (
    Number.isSafeInteger(value) &&
    !Object.is(value, -0) &&
    value >= 0 &&
    value <= maximum
  );
}

function preflightArrayCap(
  value: unknown,
  maximum: number,
  path: string,
): void {
  if (!Array.isArray(value)) {
    invalid(path, 'must be an array');
  }
  const length = Object.getOwnPropertyDescriptor(value, 'length')?.value;
  if (
    typeof length !== 'number' ||
    !Number.isSafeInteger(length) ||
    length < 0 ||
    length > maximum
  ) {
    invalid(path, 'exceeds the array limit');
  }
}

function ownDataValue(value: object, key: string, path: string): unknown {
  const descriptor = Object.getOwnPropertyDescriptor(value, key);
  if (
    descriptor === undefined ||
    !Object.prototype.hasOwnProperty.call(descriptor, 'value') ||
    descriptor.enumerable !== true
  ) {
    return invalid(path, 'must be an enumerable own data property');
  }
  return descriptor.value;
}

function preflightV6ProjectContext(
  persistedValue: unknown,
  path: string,
): void {
  const persisted = record(persistedValue, path);
  preflightArrayCap(
    ownDataValue(persisted, 'selected_paths', `${path}.selected_paths`),
    5000,
    `${path}.selected_paths`,
  );
  const manifestValue = ownDataValue(persisted, 'manifest', `${path}.manifest`);
  if (manifestValue === null) return;
  const manifest = record(manifestValue, `${path}.manifest`);
  preflightArrayCap(
    ownDataValue(manifest, 'included', `${path}.manifest.included`),
    32,
    `${path}.manifest.included`,
  );
  preflightArrayCap(
    ownDataValue(manifest, 'omitted', `${path}.manifest.omitted`),
    5000,
    `${path}.manifest.omitted`,
  );
}

function validateV6ProjectContext(
  state: ProjectContextState,
  persistedValue: unknown,
  path: string,
): ProjectContextState {
  const persisted = record(persistedValue, path);
  const selected = array(
    ownDataValue(persisted, 'selected_paths', `${path}.selected_paths`),
    `${path}.selected_paths`,
    5000,
  );
  if (selected.length > 5000) {
    return invalid(`${path}.selected_paths`, 'exceeds the path limit');
  }
  const selectedPaths: string[] = [];
  selected.forEach((entry, index) => {
    if (typeof entry !== 'string' || !safeProjectPath(entry)) {
      invalid(`${path}.selected_paths[${index}]`, 'is not a safe path');
    }
    if (index > 0 && selectedPaths[index - 1]! >= entry) {
      invalid(
        `${path}.selected_paths[${index}]`,
        'must be strictly ordered and unique',
      );
    }
    selectedPaths[index] = entry;
  });
  if (
    state.selectedPaths.length !== selectedPaths.length ||
    !state.selectedPaths.every(
      (selectedPath, index) => selectedPath === selectedPaths[index],
    )
  ) {
    return invalid(`${path}.selected_paths`, 'must be canonical');
  }

  const manifest = state.snapshot;
  if (manifest === null) return state;
  if (
    !isCanonicalLifecycleId(state.projectId) ||
    !isCanonicalLifecycleId(manifest.snapshot_id) ||
    manifest.project_id !== state.projectId ||
    !safeProjectName(manifest.project_name) ||
    !safeGitBranch(manifest.branch) ||
    (manifest.clean && manifest.conflicted) ||
    !strictProjectTimestamp(manifest.captured_at) ||
    manifest.policy_version !== 'chat-read-v1.0.0' ||
    manifest.included.length > 32 ||
    manifest.omitted.length > 5000 ||
    !strictNonNegativeInteger(manifest.context_bytes, 256 * 1024) ||
    manifest.context_bytes < 1 ||
    !strictNonNegativeInteger(manifest.estimated_tokens, 65_536) ||
    manifest.estimated_tokens !== Math.floor((manifest.context_bytes + 3) / 4)
  ) {
    return invalid(`${path}.manifest`, 'violates the v6 context contract');
  }
  const includedIdentities = new Set<string>();
  manifest.included.forEach((item, index) => {
    const identity = `${item.path}\n${item.source}`;
    if (
      !safeProjectPath(item.path) ||
      !strictNonNegativeInteger(item.bytes, 256 * 1024) ||
      !isSha256Digest(item.sha256) ||
      includedIdentities.has(identity)
    ) {
      invalid(
        `${path}.manifest.included[${index}]`,
        'violates the included-item contract',
      );
    }
    includedIdentities.add(identity);
  });
  const omittedIdentities = new Set<string>();
  manifest.omitted.forEach((item, index) => {
    const identity = `${item.path}\n${item.reason}`;
    if (!safeProjectPath(item.path) || omittedIdentities.has(identity)) {
      invalid(
        `${path}.manifest.omitted[${index}]`,
        'violates the omitted-item contract',
      );
    }
    omittedIdentities.add(identity);
  });
  const consent = state.consent;
  if (
    consent !== null &&
    (!isCanonicalLifecycleId(consent.consent_receipt_id) ||
      !isCanonicalLifecycleId(consent.snapshot_id) ||
      consent.snapshot_id !== manifest.snapshot_id ||
      consent.snapshot_sha256 !== manifest.snapshot_sha256 ||
      !strictProjectTimestamp(consent.confirmed_at) ||
      Date.parse(consent.confirmed_at) < Date.parse(manifest.captured_at))
  ) {
    return invalid(`${path}.consent`, 'violates the consent contract');
  }
  return state;
}

function parseMetadata(
  value: unknown,
  path: string,
  _strict = false,
): ChatMessageMetadata {
  const raw = exactRecord(
    value,
    path,
    ['model_id', 'latency_ms', 'finish_reason', 'reasoning'],
    ['model_id', 'latency_ms', 'finish_reason', 'reasoning'],
  );
  const metadata: {
    modelId?: ChatMessageMetadata['modelId'];
    latencyMs?: number;
    finishReason?: string;
    reasoning?: string;
  } = {};

  if (raw.model_id !== undefined) {
    if (!isModelId(raw.model_id)) {
      return invalid(`${path}.model_id`, 'is not a supported model');
    }
    metadata.modelId = raw.model_id;
  }
  if (raw.latency_ms !== undefined) {
    if (
      typeof raw.latency_ms !== 'number' ||
      !Number.isSafeInteger(raw.latency_ms) ||
      Object.is(raw.latency_ms, -0) ||
      raw.latency_ms < 0
    ) {
      return invalid(
        `${path}.latency_ms`,
        'must be a non-negative finite number',
      );
    }
    metadata.latencyMs = raw.latency_ms;
  }
  if (raw.finish_reason !== undefined) {
    metadata.finishReason = boundedString(
      raw.finish_reason,
      `${path}.finish_reason`,
      256,
    );
  }
  if (raw.reasoning !== undefined) {
    metadata.reasoning = boundedString(
      raw.reasoning,
      `${path}.reasoning`,
      MAX_MESSAGE_LENGTH,
    );
  }
  return metadata;
}

function parseAttachment(
  value: unknown,
  path: string,
  strict = false,
): ChatAttachment {
  const raw = strict
    ? exactRecord(value, path, [
        'schema_version',
        'id',
        'kind',
        'name',
        'mime_type',
        'size',
      ])
    : record(value, path);
  if (raw.schema_version !== ATTACHMENT_DESCRIPTOR_SCHEMA_VERSION) {
    return invalid(`${path}.schema_version`, 'must equal 1');
  }
  if (!isChatAttachmentKind(raw.kind)) {
    return invalid(`${path}.kind`, 'must be image, text, or pdf');
  }
  const id = boundedString(raw.id, `${path}.id`, MAX_ATTACHMENT_ID_LENGTH);
  const name = boundedString(
    raw.name,
    `${path}.name`,
    MAX_ATTACHMENT_NAME_LENGTH,
  );
  if (name.includes('\0')) {
    return invalid(`${path}.name`, 'must not contain null characters');
  }
  if (!isAttachmentMimeType(raw.mime_type, raw.kind)) {
    return invalid(
      `${path}.mime_type`,
      'must be a valid MIME type matching the attachment kind',
    );
  }
  if (!isAttachmentSize(raw.size, raw.kind)) {
    return invalid(
      `${path}.size`,
      'must be a positive safe integer within the attachment size limit',
    );
  }
  if (raw.thumbnail_data_url !== undefined) {
    return invalid(
      `${path}.thumbnail_data_url`,
      'must not be persisted in chat state',
    );
  }
  return {
    schema_version: ATTACHMENT_DESCRIPTOR_SCHEMA_VERSION,
    id,
    kind: raw.kind,
    name,
    mime_type: raw.mime_type,
    size: raw.size,
  };
}

function parseAttachments(
  value: unknown,
  path: string,
  strict = false,
): ChatAttachment[] {
  const raw = array(value, path, MAX_ATTACHMENTS_PER_MESSAGE);
  if (raw.length > MAX_ATTACHMENTS_PER_MESSAGE) {
    return invalid(
      path,
      `must contain no more than ${MAX_ATTACHMENTS_PER_MESSAGE} attachments`,
    );
  }

  const ids = new Set<string>();
  let totalSize = 0;
  return raw.map((entry, index) => {
    const attachment = parseAttachment(entry, `${path}[${index}]`, strict);
    if (ids.has(attachment.id)) {
      return invalid(
        `${path}[${index}].id`,
        'must be unique within the message',
      );
    }
    ids.add(attachment.id);
    totalSize += attachment.size;
    if (totalSize > MAX_TOTAL_ATTACHMENT_SIZE) {
      return invalid(path, 'exceeds the total attachment size limit');
    }
    return attachment;
  });
}

function parseMessage(
  value: unknown,
  path: string,
  schemaVersion: PersistedSchemaVersion,
): ChatMessage {
  const hasAttachments =
    schemaVersion !== LEGACY_CHAT_STATE_SCHEMA_VERSION &&
    schemaVersion !== OLDER_CHAT_STATE_SCHEMA_VERSION;
  const raw = exactRecord(
    value,
    path,
    hasAttachments
      ? ['id', 'role', 'text', 'created_at', 'attachments', 'metadata']
      : ['id', 'role', 'text', 'created_at', 'metadata'],
    ['metadata'],
  );
  const role = raw.role;
  if (role !== 'user' && role !== 'assistant') {
    return invalid(`${path}.role`, 'must be user or assistant');
  }

  const metadata =
    raw.metadata === undefined
      ? undefined
      : parseMetadata(raw.metadata, `${path}.metadata`);
  const attachments =
    schemaVersion === LEGACY_CHAT_STATE_SCHEMA_VERSION ||
    schemaVersion === OLDER_CHAT_STATE_SCHEMA_VERSION
      ? []
      : parseAttachments(raw.attachments, `${path}.attachments`, true);
  const text = boundedString(
    raw.text,
    `${path}.text`,
    MAX_MESSAGE_LENGTH,
    true,
  );
  if (
    text.trim().length === 0 &&
    (role === 'assistant' || attachments.length === 0)
  ) {
    return invalid(
      `${path}.text`,
      role === 'assistant'
        ? 'must not be empty for assistant messages'
        : 'must not be empty when the user message has no attachments',
    );
  }
  return {
    id: boundedString(raw.id, `${path}.id`, MAX_ID_LENGTH),
    role,
    text,
    createdAt: timestamp(raw.created_at, `${path}.created_at`),
    attachments,
    ...(metadata === undefined ? {} : { metadata }),
  };
}

function parseMessages(
  value: unknown,
  path: string,
  schemaVersion: PersistedSchemaVersion,
): ChatMessage[] {
  const raw = array(value, path, MAX_MESSAGES_PER_CONVERSATION);
  if (raw.length > MAX_MESSAGES_PER_CONVERSATION) {
    return invalid(
      path,
      `must contain no more than ${MAX_MESSAGES_PER_CONVERSATION} messages`,
    );
  }

  const ids = new Set<string>();
  return raw.map((entry, index) => {
    const message = parseMessage(entry, `${path}[${index}]`, schemaVersion);
    if (ids.has(message.id)) {
      return invalid(
        `${path}[${index}].id`,
        'must be unique within the conversation',
      );
    }
    ids.add(message.id);
    return message;
  });
}

function parseAttemptProjectContext(
  value: unknown,
  path: string,
): TurnAttemptV1['projectContext'] {
  if (value === null) return null;
  const raw = exactRecord(value, path, [
    'schema_version',
    'runtime_context_id',
    'project_id',
    'snapshot_id',
    'snapshot_sha256',
    'source_fingerprint',
    'context_bytes',
    'consent_receipt_id',
    'provider',
    'policy',
    'policy_version',
  ]);
  if (raw.schema_version !== ATTEMPT_PROJECT_CONTEXT_SCHEMA_VERSION) {
    return invalid(`${path}.schema_version`, 'must equal 1');
  }
  if (!isProviderId(raw.provider)) {
    return invalid(`${path}.provider`, 'must be a supported provider');
  }
  if (raw.policy !== 'chat-read-v1') {
    return invalid(`${path}.policy`, 'must equal chat-read-v1');
  }
  if (raw.policy_version !== 'chat-read-v1.0.0') {
    return invalid(`${path}.policy_version`, 'must equal chat-read-v1.0.0');
  }
  if (!isProjectId(raw.project_id)) {
    return invalid(`${path}.project_id`, 'must be a valid project id');
  }
  return {
    schemaVersion: ATTEMPT_PROJECT_CONTEXT_SCHEMA_VERSION,
    runtimeContextId: canonicalLifecycleId(
      raw.runtime_context_id,
      `${path}.runtime_context_id`,
    ),
    projectId: raw.project_id,
    snapshotId: canonicalLifecycleId(raw.snapshot_id, `${path}.snapshot_id`),
    snapshotSha256: sha256(raw.snapshot_sha256, `${path}.snapshot_sha256`),
    sourceFingerprint: sha256(
      raw.source_fingerprint,
      `${path}.source_fingerprint`,
    ),
    contextBytes: (() => {
      const contextBytes = nonNegativeSafeInteger(
        raw.context_bytes,
        `${path}.context_bytes`,
      );
      if (
        contextBytes < 1 ||
        contextBytes > MAX_PROJECT_CONTEXT_RECEIPT_BYTES
      ) {
        return invalid(
          `${path}.context_bytes`,
          'must be between 1 and 262144 bytes',
        );
      }
      return contextBytes;
    })(),
    consentReceiptId: canonicalLifecycleId(
      raw.consent_receipt_id,
      `${path}.consent_receipt_id`,
    ),
    provider: raw.provider as ProviderId,
    policy: 'chat-read-v1',
    policyVersion: 'chat-read-v1.0.0',
  };
}

function parseProjectContextReceipt(
  value: unknown,
  path: string,
): CompletionRoundReceiptV1['projectContextReceipt'] {
  if (value === null) return null;
  const raw = exactRecord(value, path, [
    'schema_version',
    'snapshot_id',
    'snapshot_sha256',
    'source_fingerprint',
    'context_bytes',
    'verified_at',
  ]);
  if (raw.schema_version !== 1) {
    return invalid(`${path}.schema_version`, 'must equal 1');
  }
  return {
    schema_version: 1,
    snapshot_id: canonicalLifecycleId(raw.snapshot_id, `${path}.snapshot_id`),
    snapshot_sha256: sha256(raw.snapshot_sha256, `${path}.snapshot_sha256`),
    source_fingerprint: sha256(
      raw.source_fingerprint,
      `${path}.source_fingerprint`,
    ),
    context_bytes: (() => {
      const contextBytes = nonNegativeSafeInteger(
        raw.context_bytes,
        `${path}.context_bytes`,
      );
      if (
        contextBytes < 1 ||
        contextBytes > MAX_PROJECT_CONTEXT_RECEIPT_BYTES
      ) {
        return invalid(
          `${path}.context_bytes`,
          'must be between 1 and 262144 bytes',
        );
      }
      return contextBytes;
    })(),
    verified_at: timestamp(raw.verified_at, `${path}.verified_at`),
  };
}

function parseRoundReceipt(
  value: unknown,
  path: string,
): CompletionRoundReceiptV1 {
  const raw = exactRecord(
    value,
    path,
    [
      'schema_version',
      'transport_schema_version',
      'turn_id',
      'attempt_id',
      'round_id',
      'round_index',
      'provider_request_id',
      'provider_response_id',
      'requested_model',
      'model',
      'thinking_mode',
      'finish_reason',
      'latency_ms',
      'visible_history_sha256',
      'model_input_sha256',
      'request_body_sha256',
      'project_context_receipt',
    ],
    ['harness_id', 'provider_configuration'],
  );
  const harnessId =
    raw.harness_id === undefined
      ? 'dsh'
      : isHarnessId(raw.harness_id)
      ? raw.harness_id
      : invalid(path + '.harness_id', 'must be a supported harness');
  if (raw.schema_version !== COMPLETION_ROUND_RECEIPT_SCHEMA_VERSION) {
    return invalid(`${path}.schema_version`, 'must equal 1');
  }
  if (
    raw.transport_schema_version !== 2 &&
    raw.transport_schema_version !== 3
  ) {
    return invalid(`${path}.transport_schema_version`, 'must equal 2 or 3');
  }
  if (!isModelId(raw.requested_model) || !isModelId(raw.model)) {
    return invalid(`${path}.model`, 'must contain supported models');
  }
  if (!isConversationThinkingMode(raw.thinking_mode)) {
    return invalid(`${path}.thinking_mode`, 'must be supported');
  }
  if (
    typeof raw.finish_reason !== 'string' ||
    !finishReasons.has(raw.finish_reason)
  ) {
    return invalid(`${path}.finish_reason`, 'must be supported');
  }
  const roundIndex = nonNegativeSafeInteger(
    raw.round_index,
    `${path}.round_index`,
  );
  if (roundIndex >= MAX_COMPLETION_ROUNDS) {
    return invalid(`${path}.round_index`, 'must be less than 8');
  }
  const providerConfiguration = raw.provider_configuration === undefined ? undefined : parseProviderBinding(raw.provider_configuration, raw.model);
  if (providerConfiguration === null) return invalid(path + '.provider_configuration', 'invalid provider binding');
  return {
    ...(providerConfiguration === undefined ? {} : { providerConfiguration }),
    schemaVersion: COMPLETION_ROUND_RECEIPT_SCHEMA_VERSION,
    transportSchemaVersion: raw.transport_schema_version,
    harnessId,
    turnId: canonicalLifecycleId(raw.turn_id, `${path}.turn_id`),
    attemptId: canonicalLifecycleId(raw.attempt_id, `${path}.attempt_id`),
    roundId: canonicalLifecycleId(raw.round_id, `${path}.round_id`),
    roundIndex,
    providerRequestId: opaqueProviderId(
      raw.provider_request_id,
      `${path}.provider_request_id`,
    ),
    providerResponseId: opaqueProviderId(
      raw.provider_response_id,
      `${path}.provider_response_id`,
    ),
    requestedModel: raw.requested_model,
    model: raw.model,
    thinkingMode: raw.thinking_mode,
    finishReason: raw.finish_reason as CompletionRoundReceiptV1['finishReason'],
    latencyMs: nonNegativeSafeInteger(raw.latency_ms, `${path}.latency_ms`),
    visibleHistorySha256: sha256(
      raw.visible_history_sha256,
      `${path}.visible_history_sha256`,
    ),
    modelInputSha256: sha256(
      raw.model_input_sha256,
      `${path}.model_input_sha256`,
    ),
    requestBodySha256: sha256(
      raw.request_body_sha256,
      `${path}.request_body_sha256`,
    ),
    projectContextReceipt: parseProjectContextReceipt(
      raw.project_context_receipt,
      `${path}.project_context_receipt`,
    ),
  };
}

const agentPhases = new Set([
  'ready_for_round',
  'round_in_flight',
  'batch_frozen',
  'approval_pending',
  'execution_intent',
  'tool_result_pending',
  'final_response',
  'cancelled',
  'failed',
  'unknown',
  'ambiguous',
]);
const agentLineageStatuses = new Set([
  'ready',
  'active',
  'failed_retryable',
  'completed',
  'cancel_requested',
  'cancelled',
  'unknown',
  'ambiguous',
]);
const agentAccesses = new Set<AgentAccess>([
  'auto',
  'conversation_confirm',
  'confirm_once',
  'durable_deny',
]);
const agentApprovalDecisions = new Set([
  'pending',
  'denied',
  'allow_once',
  'allow_conversation',
  'cancelled',
]);
const agentCapabilities = new Set([
  'file_read',
  'file_write',
  'git_status',
  'git_commit',
  'git_push',
  'guest_service',
]);
const isAgentRegistryVersion = (value: unknown): value is AgentRegistryVersion =>
  value === 1 || value === 2 || value === 3;
const sessionEventKinds = new Set([
  'round',
  'tool_call',
  'tool_result',
  'approval',
  'terminal',
  'cancel',
]);
const sessionEventStatuses = new Set([
  'waiting',
  'approval',
  'running',
  'ok',
  'failed',
  'denied',
  'cancelled',
  'unknown',
  'ambiguous',
]);
const autoAgentTools = new Set<string>(ALL_AGENT_AUTO_TOOLS);
const safeSummaryKeys = new Set<string>(AGENT_SAFE_SUMMARY_KEYS);

function agentFailureCode(
  value: unknown,
  path: string,
): AgentFailureCode | null {
  if (value === null) return null;
  if (
    typeof value !== 'string' ||
    !AGENT_FAILURE_CODES.includes(value as AgentFailureCode)
  ) {
    return invalid(`${path}`, 'must be a stable Agent failure code or null');
  }
  return value as AgentFailureCode;
}

function parseAgentRoot(value: unknown, path: string): FrozenAgentRootV1 {
  const raw = exactRecord(value, path, [
    'schema_version',
    'kind',
    'workspace_id',
    'workspace_binding_revision',
    'project_id',
    'root_fingerprint_sha256',
    'capabilities',
  ]);
  if (raw.schema_version !== AGENT_ROOT_SCHEMA_VERSION) {
    return invalid(`${path}.schema_version`, 'must equal 1');
  }
  if (raw.kind !== 'project' && raw.kind !== 'workspace') {
    return invalid(`${path}.kind`, 'must be project or workspace');
  }
  const workspaceId = canonicalLifecycleId(
    raw.workspace_id,
    `${path}.workspace_id`,
  );
  const bindingRevision = lifecycleEpoch(
    raw.workspace_binding_revision,
    `${path}.workspace_binding_revision`,
    false,
  );
  if (bindingRevision >= Number.MAX_SAFE_INTEGER) {
    return invalid(
      `${path}.workspace_binding_revision`,
      'must be less than Number.MAX_SAFE_INTEGER',
    );
  }
  const projectId =
    raw.project_id === null
      ? null
      : canonicalLifecycleId(raw.project_id, `${path}.project_id`);
  if ((raw.kind === 'project') !== (projectId !== null)) {
    return invalid(`${path}.project_id`, 'must match root kind');
  }
  const capabilitiesRaw = array(
    raw.capabilities,
    `${path}.capabilities`,
    agentCapabilities.size,
  );
  const capabilities: FrozenAgentRootV1['capabilities'] = [];
  const seen = new Set<string>();
  capabilitiesRaw.forEach((entry, index) => {
    if (typeof entry !== 'string' || !agentCapabilities.has(entry)) {
      invalid(
        `${path}.capabilities[${index}]`,
        'is not a supported capability',
      );
    }
    if (seen.has(entry))
      invalid(`${path}.capabilities[${index}]`, 'must be unique');
    seen.add(entry);
    if (raw.kind === 'workspace' && entry.startsWith('git_')) {
      invalid(
        `${path}.capabilities[${index}]`,
        'workspace roots cannot expose Git',
      );
    }
    (capabilities as AgentCapability[]).push(entry as AgentCapability);
  });
  return {
    schema_version: AGENT_ROOT_SCHEMA_VERSION,
    kind: raw.kind,
    workspace_id: workspaceId,
    workspace_binding_revision: bindingRevision,
    project_id: projectId,
    root_fingerprint_sha256: sha256(
      raw.root_fingerprint_sha256,
      `${path}.root_fingerprint_sha256`,
    ),
    capabilities,
  };
}

function parseAgentPolicy(value: unknown, path: string): AgentWritePolicyV1 {
  const raw = exactRecord(value, path, [
    'schema_version',
    'policy_version',
    'max_single_write_bytes',
    'max_batch_write_bytes',
    'max_attempt_write_bytes',
  ]);
  if (raw.schema_version !== AGENT_WRITE_POLICY_SCHEMA_VERSION) {
    return invalid(`${path}.schema_version`, 'must equal 1');
  }
  const policyVersion = boundedIdentifier(
    raw.policy_version,
    `${path}.policy_version`,
    256,
  );
  const single = nonNegativeSafeInteger(
    raw.max_single_write_bytes,
    `${path}.max_single_write_bytes`,
  );
  const batch = nonNegativeSafeInteger(
    raw.max_batch_write_bytes,
    `${path}.max_batch_write_bytes`,
  );
  const attempt = nonNegativeSafeInteger(
    raw.max_attempt_write_bytes,
    `${path}.max_attempt_write_bytes`,
  );
  if (
    single !== MAX_AGENT_SINGLE_WRITE_BYTES ||
    batch < MAX_AGENT_SINGLE_WRITE_BYTES ||
    batch > MAX_AGENT_BATCH_WRITE_BYTES ||
    attempt < batch ||
    attempt > MAX_AGENT_ATTEMPT_WRITE_BYTES
  ) {
    return invalid(`${path}`, 'violates the Agent write policy bounds');
  }
  return {
    schema_version: AGENT_WRITE_POLICY_SCHEMA_VERSION,
    policy_version: policyVersion,
    max_single_write_bytes: MAX_AGENT_SINGLE_WRITE_BYTES,
    max_batch_write_bytes: batch,
    max_attempt_write_bytes: attempt,
  };
}

function parseTranscriptReference(
  value: unknown,
  path: string,
): AgentTranscriptReferenceV1 {
  const raw = exactRecord(value, path, [
    'schema_version',
    'transcript_ref',
    'generation',
    'transcript_sha256',
    'transcript_bytes',
  ]);
  if (raw.schema_version !== AGENT_TRANSCRIPT_REFERENCE_SCHEMA_VERSION) {
    return invalid(`${path}.schema_version`, 'must equal 1');
  }
  return {
    schema_version: AGENT_TRANSCRIPT_REFERENCE_SCHEMA_VERSION,
    transcript_ref: canonicalLifecycleId(
      raw.transcript_ref,
      `${path}.transcript_ref`,
    ),
    generation: nonNegativeSafeInteger(raw.generation, `${path}.generation`),
    transcript_sha256: sha256(
      raw.transcript_sha256,
      `${path}.transcript_sha256`,
    ),
    transcript_bytes: (() => {
      const bytes = nonNegativeSafeInteger(
        raw.transcript_bytes,
        `${path}.transcript_bytes`,
      );
      return bytes > MAX_AGENT_TRANSCRIPT_BYTES
        ? invalid(`${path}.transcript_bytes`, 'exceeds the transcript limit')
        : bytes;
    })(),
  };
}

function parseAgentReceipt(value: unknown, path: string): AgentToolReceiptV1 {
  const raw = exactRecord(value, path, [
    'schema_version',
    'call_id',
    'name',
    'arguments_sha256',
    'result_sha256',
    'result_bytes',
    'truncated',
    'duration_ms',
    'outcome',
    'failure_code',
    'approval_reference',
  ]);
  if (raw.schema_version !== 1)
    return invalid(`${path}.schema_version`, 'must equal 1');
  const callId = opaqueProviderId(raw.call_id, `${path}.call_id`);
  const name = boundedString(raw.name, `${path}.name`, 64);
  if (!/^[\x21-\x7e]+$/u.test(name))
    return invalid(`${path}.name`, 'must be ASCII');
  if (typeof raw.truncated !== 'boolean')
    return invalid(`${path}.truncated`, 'must be a boolean');
  const resultBytes = nonNegativeSafeInteger(
    raw.result_bytes,
    `${path}.result_bytes`,
  );
  if (resultBytes > MAX_AGENT_RESULT_BYTES)
    return invalid(`${path}.result_bytes`, 'exceeds the result limit');
  const durationMs = nonNegativeSafeInteger(
    raw.duration_ms,
    `${path}.duration_ms`,
  );
  if (durationMs > MAX_AGENT_DURATION_MS)
    return invalid(`${path}.duration_ms`, 'exceeds the duration limit');
  const outcome = raw.outcome;
  if (
    outcome !== 'ok' &&
    outcome !== 'failed' &&
    outcome !== 'denied' &&
    outcome !== 'cancelled' &&
    outcome !== 'ambiguous'
  )
    return invalid(`${path}.outcome`, 'must be a supported receipt outcome');
  const failureCode = agentFailureCode(
    raw.failure_code,
    `${path}.failure_code`,
  );
  const approvalReference =
    raw.approval_reference === null
      ? null
      : agentIdentifier(raw.approval_reference, `${path}.approval_reference`);
  if (outcome === 'ok' && failureCode !== null) {
    return invalid(
      `${path}.failure_code`,
      'successful receipts cannot carry a failure code',
    );
  }
  if (
    outcome === 'ambiguous' &&
    failureCode !== 'E_AGENT_EXECUTION_AMBIGUOUS'
  ) {
    return invalid(
      `${path}.failure_code`,
      'ambiguous receipts require the stable ambiguity code',
    );
  }
  if (
    (outcome === 'ok' || outcome === 'failed' || outcome === 'denied') &&
    failureCode === 'E_AGENT_EXECUTION_AMBIGUOUS'
  )
    return invalid(
      `${path}.failure_code`,
      'ambiguous code requires ambiguous outcome',
    );
  return {
    schema_version: 1,
    call_id: callId,
    name,
    arguments_sha256: sha256(raw.arguments_sha256, `${path}.arguments_sha256`),
    result_sha256: sha256(raw.result_sha256, `${path}.result_sha256`),
    result_bytes: resultBytes,
    truncated: raw.truncated,
    duration_ms: durationMs,
    outcome,
    failure_code: failureCode,
    approval_reference: approvalReference,
  };
}

function parseAgentControllerCAS(
  value: unknown,
  path: string,
): AgentControllerCASV1 {
  const raw = exactRecord(value, path, [
    'schema_version',
    'conversation_id',
    'task_id',
    'attempt_id',
    'expected_controller_generation',
    'expected_journal_revision',
    'expected_session_generation',
    'expected_session_sha256',
  ]);
  if (raw.schema_version !== 1)
    return invalid(`${path}.schema_version`, 'must equal 1');
  const controllerGeneration = nonNegativeSafeInteger(
    raw.expected_controller_generation,
    `${path}.expected_controller_generation`,
  );
  const journalRevision = nonNegativeSafeInteger(
    raw.expected_journal_revision,
    `${path}.expected_journal_revision`,
  );
  const sessionGeneration = lifecycleEpoch(
    raw.expected_session_generation,
    `${path}.expected_session_generation`,
    false,
  );
  if (
    controllerGeneration >= Number.MAX_SAFE_INTEGER ||
    journalRevision >= Number.MAX_SAFE_INTEGER ||
    sessionGeneration >= Number.MAX_SAFE_INTEGER
  )
    return invalid(
      path,
      'CAS generations must leave room for the next transition',
    );
  return {
    schema_version: 1,
    conversation_id: boundedIdentifier(
      raw.conversation_id,
      `${path}.conversation_id`,
      MAX_ID_LENGTH,
    ),
    task_id: canonicalLifecycleId(raw.task_id, `${path}.task_id`),
    attempt_id: canonicalLifecycleId(raw.attempt_id, `${path}.attempt_id`),
    expected_controller_generation: controllerGeneration,
    expected_journal_revision: journalRevision,
    expected_session_generation: sessionGeneration,
    expected_session_sha256: sha256(
      raw.expected_session_sha256,
      `${path}.expected_session_sha256`,
    ),
  };
}

function parseAgentApprovalToken(
  value: unknown,
  path: string,
): AgentApprovalTokenV1 {
  const raw = exactRecord(value, path, [
    'schema_version',
    'controller_cas',
    'round_id',
    'round_index',
    'batch_call_ids',
    'batch_arguments_sha256',
    'call_index',
    'call_id',
    'name',
    'access',
    'arguments_sha256',
    'root_fingerprint_sha256',
    'binding_revision',
    'policy_version',
    'registry_version',
    'allowed_decisions',
  ]);
  if (raw.schema_version !== 1)
    return invalid(`${path}.schema_version`, 'must equal 1');
  const batchCallIds = array(
    raw.batch_call_ids,
    `${path}.batch_call_ids`,
    MAX_AGENT_CALLS_PER_BATCH,
  ).map((entry, index) =>
    opaqueProviderId(entry, `${path}.batch_call_ids[${index}]`),
  );
  const batchArguments = array(
    raw.batch_arguments_sha256,
    `${path}.batch_arguments_sha256`,
    MAX_AGENT_CALLS_PER_BATCH,
  ).map((entry, index) =>
    sha256(entry, `${path}.batch_arguments_sha256[${index}]`),
  );
  if (
    batchCallIds.length < 1 ||
    batchCallIds.length !== batchArguments.length ||
    new Set(batchCallIds).size !== batchCallIds.length
  )
    return invalid(path, 'must contain a unique complete batch binding');
  const callId = opaqueProviderId(raw.call_id, `${path}.call_id`);
  const callIndex = nonNegativeSafeInteger(
    raw.call_index,
    `${path}.call_index`,
  );
  const argumentsSha256 = sha256(
    raw.arguments_sha256,
    `${path}.arguments_sha256`,
  );
  if (
    callIndex >= batchCallIds.length ||
    batchCallIds[callIndex] !== callId ||
    batchArguments[callIndex] !== argumentsSha256
  ) {
    return invalid(path, 'call identity must match its complete batch binding');
  }
  const allowedDecisions = array(
    raw.allowed_decisions,
    `${path}.allowed_decisions`,
    4,
  ).map((entry, index) => {
    if (
      entry !== 'denied' &&
      entry !== 'allow_once' &&
      entry !== 'allow_conversation' &&
      entry !== 'cancelled'
    )
      return invalid(
        `${path}.allowed_decisions[${index}]`,
        'is not a decision',
      );
    return entry as Exclude<AgentApprovalDecision, 'pending'>;
  });
  if (allowedDecisions.length < 1) {
    return invalid(`${path}.allowed_decisions`, 'must not be empty');
  }
  if (new Set(allowedDecisions).size !== allowedDecisions.length) {
    return invalid(`${path}.allowed_decisions`, 'must be unique');
  }
  if (!agentAccesses.has(raw.access as AgentAccess)) {
    return invalid(`${path}.access`, 'must be a supported access policy');
  }
  const expectedDecisions =
    raw.access === 'conversation_confirm'
      ? ['denied', 'allow_once', 'allow_conversation', 'cancelled']
      : raw.access === 'confirm_once'
      ? ['denied', 'allow_once', 'cancelled']
      : null;
  if (
    expectedDecisions !== null &&
    (allowedDecisions.length !== expectedDecisions.length ||
      allowedDecisions.some(
        (entry, index) => entry !== expectedDecisions[index],
      ))
  ) {
    return invalid(`${path}.allowed_decisions`, 'does not match access policy');
  }
  return {
    schema_version: 1,
    controller_cas: parseAgentControllerCAS(
      raw.controller_cas,
      `${path}.controller_cas`,
    ),
    round_id: canonicalLifecycleId(raw.round_id, `${path}.round_id`),
    round_index: (() => {
      const index = nonNegativeSafeInteger(
        raw.round_index,
        `${path}.round_index`,
      );
      return index >= MAX_AGENT_ROUNDS
        ? invalid(`${path}.round_index`, 'must be less than 8')
        : index;
    })(),
    batch_call_ids: batchCallIds,
    batch_arguments_sha256: batchArguments,
    call_index: callIndex,
    call_id: callId,
    name: (() => {
      const name = boundedString(raw.name, `${path}.name`, 64);
      return /^[\x21-\x7e]+$/u.test(name)
        ? name
        : invalid(`${path}.name`, 'must be ASCII');
    })(),
    access: (() => {
      if (!agentAccesses.has(raw.access as AgentAccess)) {
        return invalid(`${path}.access`, 'must be a supported access policy');
      }
      return raw.access as AgentAccess;
    })(),
    arguments_sha256: argumentsSha256,
    root_fingerprint_sha256: sha256(
      raw.root_fingerprint_sha256,
      `${path}.root_fingerprint_sha256`,
    ),
    binding_revision: (() => {
      const revision = lifecycleEpoch(
        raw.binding_revision,
        `${path}.binding_revision`,
        false,
      );
      return revision >= Number.MAX_SAFE_INTEGER
        ? invalid(
            `${path}.binding_revision`,
            'must be less than Number.MAX_SAFE_INTEGER',
          )
        : revision;
    })(),
    policy_version: boundedIdentifier(
      raw.policy_version,
      `${path}.policy_version`,
      MAX_ID_LENGTH,
    ),
    registry_version:
      raw.registry_version === 1
        ? 1
        : invalid(`${path}.registry_version`, 'must equal 1'),
    allowed_decisions: allowedDecisions,
  };
}

/**
 * Parses the closed, final schema-9 call projection.  This parser is kept
 * separate from the V2 parser above on purpose: a structured legacy approval
 * object is a migration input, never a valid V3 persisted value.
 */
export function parsePersistedAgentCallJournalV3(
  value: unknown,
  path = '$',
  registryVersion: AgentRegistryVersion = 1,
): PersistedAgentCallJournalV3 {
  const raw = exactRecord(value, path, [
    'schema_version',
    'call_id',
    'call_index',
    'name',
    'arguments_sha256',
    'safe_summary_key',
    'access',
    'approval_token',
    'approval_decision',
    'approval_reference',
    'idempotency_key',
    'native_row_revision',
    'receipt',
  ]);
  if (raw.schema_version !== AGENT_CALL_JOURNAL_SCHEMA_VERSION_V3) {
    return invalid(`${path}.schema_version`, 'must equal 3');
  }
  const callId = opaqueProviderId(raw.call_id, `${path}.call_id`);
  const callIndex = nonNegativeSafeInteger(
    raw.call_index,
    `${path}.call_index`,
  );
  const name = boundedString(raw.name, `${path}.name`, 64);
  if (!/^[\x21-\x7e]+$/u.test(name)) {
    return invalid(`${path}.name`, 'must be ASCII');
  }
  if (
    typeof raw.access !== 'string' ||
    !agentAccesses.has(raw.access as AgentAccess)
  ) {
    return invalid(`${path}.access`, 'must be a supported access policy');
  }
  const access = raw.access as AgentAccess;
  if (
    typeof raw.approval_decision !== 'string' ||
    !agentApprovalDecisions.has(raw.approval_decision)
  ) {
    return invalid(
      `${path}.approval_decision`,
      'must be a supported approval decision',
    );
  }
  const decision = raw.approval_decision as AgentApprovalDecision;
  const approvalToken =
    raw.approval_token === null
      ? null
      : opaqueProviderId(raw.approval_token, `${path}.approval_token`);
  const approvalReference =
    raw.approval_reference === null
      ? null
      : agentIdentifier(raw.approval_reference, `${path}.approval_reference`);
  const idempotencyKey =
    raw.idempotency_key === null
      ? null
      : sha256(raw.idempotency_key, `${path}.idempotency_key`);
  const nativeRowRevision =
    raw.native_row_revision === null
      ? null
      : (() => {
          const revision = nonNegativeSafeInteger(
            raw.native_row_revision,
            `${path}.native_row_revision`,
          );
          return revision < 1
            ? invalid(`${path}.native_row_revision`, 'must be positive')
            : revision;
        })();
  const receipt =
    raw.receipt === null
      ? null
      : parseAgentReceipt(raw.receipt, `${path}.receipt`);
  const knownTool = (ALL_AGENT_TOOL_NAMES as readonly string[]).includes(name) && agentToolRegistryCompatible(name, registryVersion);
  const expectedAccess = knownTool
    ? autoAgentTools.has(name)
      ? 'auto'
      : 'conversation_confirm'
    : 'durable_deny';
  if (access !== expectedAccess) {
    return invalid(
      `${path}.access`,
      'does not match the registered tool policy',
    );
  }
  const expectedSummaryKey = knownTool ? `agent.${name}` : 'agent.unknown';
  const safeSummaryKey = boundedString(
    raw.safe_summary_key,
    `${path}.safe_summary_key`,
    MAX_AGENT_SUMMARY_KEY_LENGTH,
  );
  if (
    !safeSummaryKeys.has(safeSummaryKey) ||
    safeSummaryKey !== expectedSummaryKey
  ) {
    return invalid(
      `${path}.safe_summary_key`,
      'must be the registered value-free summary key',
    );
  }
  const argumentsSha256 = sha256(
    raw.arguments_sha256,
    `${path}.arguments_sha256`,
  );
  if (
    access === 'auto' &&
    (approvalToken !== null || approvalReference !== null)
  ) {
    return invalid(path, 'auto calls cannot carry approval references');
  }
  if (
    access === 'durable_deny' &&
    (approvalToken !== null ||
      approvalReference !== null ||
      idempotencyKey !== null)
  ) {
    return invalid(
      path,
      'durable deny cannot carry approval or execution fields',
    );
  }
  if (access === 'durable_deny' && decision !== 'denied') {
    return invalid(`${path}.approval_decision`, 'durable deny must be denied');
  }
  if (decision === 'pending' && approvalReference !== null) {
    return invalid(
      `${path}.approval_reference`,
      'pending approvals cannot carry a decision reference',
    );
  }
  const gated = access === 'conversation_confirm';
  if (
    gated &&
    (decision === 'pending' ||
      decision === 'allow_once' ||
      decision === 'allow_conversation')
  ) {
    if (approvalToken === null && !isConversationGrantBoundCall({ name, access, approval_decision: decision,
      approval_token: approvalToken, approval_reference: approvalReference, idempotency_key: idempotencyKey, native_row_revision: nativeRowRevision })) {
      return invalid(
        `${path}.approval_token`,
        'gated decisions require an opaque approval token or a bound conversation grant',
      );
    }
  }
  if (decision === 'denied' || decision === 'cancelled') {
    if (approvalToken !== null || approvalReference !== null) {
      return invalid(
        path,
        'terminal approval decisions cannot carry authority',
      );
    }
  }
  if (
    receipt !== null &&
    (receipt.call_id !== callId ||
      receipt.name !== name ||
      receipt.arguments_sha256 !== argumentsSha256 ||
      receipt.approval_reference !== approvalReference)
  ) {
    return invalid(`${path}.receipt`, 'must match its call');
  }
  if (receipt !== null && nativeRowRevision === null) {
    return invalid(
      `${path}.native_row_revision`,
      'settled receipts require a native row revision',
    );
  }
  // A gated call the user denied can only settle as the exact user-denial
  // receipt: denied outcome, E_AGENT_DENIED_BY_USER, no approval reference.
  if (
    receipt !== null &&
    access !== 'durable_deny' &&
    decision === 'denied' &&
    (receipt.outcome !== 'denied' ||
      receipt.failure_code !== 'E_AGENT_DENIED_BY_USER' ||
      receipt.approval_reference !== null)
  ) {
    return invalid(`${path}.receipt`, 'a user denial settles only as a denied-by-user receipt');
  }
  return {
    schema_version: AGENT_CALL_JOURNAL_SCHEMA_VERSION_V3,
    call_id: callId,
    call_index: callIndex,
    name,
    arguments_sha256: argumentsSha256,
    safe_summary_key: safeSummaryKey,
    access,
    approval_token: approvalToken,
    approval_decision: decision,
    approval_reference: approvalReference,
    idempotency_key: idempotencyKey,
    native_row_revision: nativeRowRevision,
    receipt,
  };
}

function parseAgentApprovalBindingTokenV2(
  value: unknown,
  path: string,
): AgentApprovalBindingTokenV2 {
  const raw = exactRecord(value, path, [
    'schema_version',
    'token',
    'controller_cas',
    'task_id',
    'attempt_id',
    'round_id',
    'round_index',
    'batch_call_ids',
    'batch_arguments_sha256',
    'batch_revision',
    'manifest_sha256',
    'call_index',
    'call_id',
    'name',
    'arguments_sha256',
    'idempotency_key',
    'root_fingerprint_sha256',
    'binding_revision',
    'policy_version',
    'registry_version',
    'access',
    'allowed_decisions',
  ]);
  if (raw.schema_version !== 2) {
    return invalid(`${path}.schema_version`, 'must equal 2');
  }
  const controllerCas = parseAgentControllerCAS(
    raw.controller_cas,
    `${path}.controller_cas`,
  );
  const taskId = canonicalLifecycleId(raw.task_id, `${path}.task_id`);
  const attemptId = canonicalLifecycleId(raw.attempt_id, `${path}.attempt_id`);
  const roundId = canonicalLifecycleId(raw.round_id, `${path}.round_id`);
  const roundIndex = nonNegativeSafeInteger(
    raw.round_index,
    `${path}.round_index`,
  );
  if (roundIndex >= MAX_AGENT_ROUNDS) {
    return invalid(`${path}.round_index`, 'must be less than 8');
  }
  if (
    controllerCas.task_id !== taskId ||
    controllerCas.attempt_id !== attemptId
  ) {
    return invalid(`${path}.controller_cas`, 'must match the token attempt');
  }
  const batchCallIds = array(
    raw.batch_call_ids,
    `${path}.batch_call_ids`,
    MAX_AGENT_CALLS_PER_BATCH,
  ).map((entry, index) =>
    opaqueProviderId(entry, `${path}.batch_call_ids[${index}]`),
  );
  const batchArguments = array(
    raw.batch_arguments_sha256,
    `${path}.batch_arguments_sha256`,
    MAX_AGENT_CALLS_PER_BATCH,
  ).map((entry, index) =>
    sha256(entry, `${path}.batch_arguments_sha256[${index}]`),
  );
  if (
    batchCallIds.length < 1 ||
    batchCallIds.length !== batchArguments.length ||
    new Set(batchCallIds).size !== batchCallIds.length
  ) {
    return invalid(path, 'must contain a unique complete batch binding');
  }
  const callIndex = nonNegativeSafeInteger(
    raw.call_index,
    `${path}.call_index`,
  );
  if (callIndex >= batchCallIds.length) {
    return invalid(`${path}.call_index`, 'must reference a batch call');
  }
  const access = raw.access;
  if (access !== 'conversation_confirm' && access !== 'confirm_once') {
    return invalid(`${path}.access`, 'must be a gated access policy');
  }
  const allowedDecisions = array(
    raw.allowed_decisions,
    `${path}.allowed_decisions`,
    4,
  ).map((entry, index) => {
    if (
      entry !== 'denied' &&
      entry !== 'allow_once' &&
      entry !== 'allow_conversation' &&
      entry !== 'cancelled'
    ) {
      return invalid(
        `${path}.allowed_decisions[${index}]`,
        'is not a decision',
      );
    }
    return entry as AgentApprovalBindingTokenV2['allowed_decisions'][number];
  });
  const expectedDecisions =
    access === 'conversation_confirm'
      ? ['denied', 'allow_once', 'allow_conversation', 'cancelled']
      : ['denied', 'allow_once', 'cancelled'];
  if (
    allowedDecisions.length !== expectedDecisions.length ||
    allowedDecisions.some((entry, index) => entry !== expectedDecisions[index])
  ) {
    return invalid(`${path}.allowed_decisions`, 'does not match access policy');
  }
  const name = boundedString(raw.name, `${path}.name`, 64);
  if (!/^[\x21-\x7e]+$/u.test(name))
    return invalid(`${path}.name`, 'must be ASCII');
  return {
    schema_version: 2,
    token: canonicalLifecycleId(raw.token, `${path}.token`),
    controller_cas: controllerCas,
    task_id: taskId,
    attempt_id: attemptId,
    round_id: roundId,
    round_index: roundIndex,
    batch_call_ids: batchCallIds,
    batch_arguments_sha256: batchArguments,
    batch_revision: (() => {
      const revision = lifecycleEpoch(
        raw.batch_revision,
        `${path}.batch_revision`,
        false,
      );
      return revision >= Number.MAX_SAFE_INTEGER
        ? invalid(
            `${path}.batch_revision`,
            'must leave room for the next revision',
          )
        : revision;
    })(),
    manifest_sha256: sha256(raw.manifest_sha256, `${path}.manifest_sha256`),
    call_index: callIndex,
    call_id: opaqueProviderId(raw.call_id, `${path}.call_id`),
    name,
    arguments_sha256: sha256(raw.arguments_sha256, `${path}.arguments_sha256`),
    idempotency_key: sha256(raw.idempotency_key, `${path}.idempotency_key`),
    root_fingerprint_sha256: sha256(
      raw.root_fingerprint_sha256,
      `${path}.root_fingerprint_sha256`,
    ),
    binding_revision: (() => {
      const revision = lifecycleEpoch(
        raw.binding_revision,
        `${path}.binding_revision`,
        false,
      );
      return revision >= Number.MAX_SAFE_INTEGER
        ? invalid(
            `${path}.binding_revision`,
            'must leave room for the next revision',
          )
        : revision;
    })(),
    policy_version:
      raw.policy_version === 'agent-v1'
        ? 'agent-v1'
        : invalid(`${path}.policy_version`, 'must equal agent-v1'),
    registry_version:
      raw.registry_version === 1
        ? 1
        : invalid(`${path}.registry_version`, 'must equal 1'),
    access,
    allowed_decisions: allowedDecisions,
  };
}

function sameApprovalTokenCall(
  token: Pick<
    AgentApprovalTokenV1,
    | 'call_id'
    | 'call_index'
    | 'name'
    | 'access'
    | 'arguments_sha256'
    | 'batch_call_ids'
    | 'batch_arguments_sha256'
  >,
  call: Pick<
    PersistedAgentCallJournalV3,
    'call_id' | 'call_index' | 'name' | 'access' | 'arguments_sha256'
  >,
): boolean {
  return (
    token.call_id === call.call_id &&
    token.call_index === call.call_index &&
    token.name === call.name &&
    token.access === call.access &&
    token.arguments_sha256 === call.arguments_sha256 &&
    token.batch_call_ids[token.call_index] === call.call_id &&
    token.batch_arguments_sha256[token.call_index] === call.arguments_sha256
  );
}

function validateLegacyApprovalTokenRelations(
  token: AgentApprovalTokenV1,
  call: PersistedAgentCallJournalV3,
  batch: readonly PersistedAgentCallJournalV3[],
  lineage: PersistedAgentRoundLineageV2 | null,
  roundIndex: number,
  root: FrozenAgentRootV1,
  policy: AgentWritePolicyV1,
  controllerGeneration: number,
  path: string,
  expectedIdentity?: { readonly taskId: string; readonly attemptId: string },
  expectedControllerCAS?: AgentControllerCASV1,
): void {
  if (
    lineage === null ||
    token.round_id !== lineage.round_id ||
    token.round_index !== roundIndex ||
    token.controller_cas.expected_controller_generation !==
      Math.max(0, controllerGeneration - 1) ||
    (expectedIdentity !== undefined &&
      (token.controller_cas.task_id !== expectedIdentity.taskId ||
        token.controller_cas.attempt_id !== expectedIdentity.attemptId)) ||
    (expectedControllerCAS !== undefined &&
      (token.controller_cas.schema_version !== expectedControllerCAS.schema_version ||
        token.controller_cas.conversation_id !== expectedControllerCAS.conversation_id ||
        token.controller_cas.task_id !== expectedControllerCAS.task_id ||
        token.controller_cas.attempt_id !== expectedControllerCAS.attempt_id ||
        token.controller_cas.expected_controller_generation !==
          expectedControllerCAS.expected_controller_generation ||
        token.controller_cas.expected_journal_revision !==
          expectedControllerCAS.expected_journal_revision ||
        token.controller_cas.expected_session_generation !==
          expectedControllerCAS.expected_session_generation ||
        token.controller_cas.expected_session_sha256 !==
          expectedControllerCAS.expected_session_sha256)) ||
    token.root_fingerprint_sha256 !== root.root_fingerprint_sha256 ||
    token.binding_revision !== root.workspace_binding_revision ||
    token.policy_version !== policy.policy_version ||
    token.registry_version !== 1 ||
    !sameApprovalTokenCall(token, call) ||
    token.batch_call_ids.length !== batch.length ||
    token.batch_arguments_sha256.length !== batch.length ||
    token.batch_call_ids.some(
      (callId, index) => callId !== batch[index]?.call_id,
    ) ||
    token.batch_arguments_sha256.some(
      (digest, index) => digest !== batch[index]?.arguments_sha256,
    )
  ) {
    return invalid(
      `${path}.approval_token`,
      'legacy approval binding must match the complete journal authority',
    );
  }
}

/**
 * Classifies one pre-V3 token without ever upgrading a legacy object by
 * guessing fields.  Call/journal relations are checked by the caller when
 * the surrounding row is available; this function only returns safe audit
 * metadata and the final token/decision pair.
 */
export function migrateAgentApprovalTokenV3(
  value: unknown,
  decision: AgentApprovalDecision,
  call?: Pick<
    PersistedAgentCallJournalV3,
    'call_id' | 'call_index' | 'name' | 'access' | 'arguments_sha256'
  >,
  expectedControllerCAS?: AgentControllerCASV1,
): AgentApprovalTokenMigrationV3 {
  const sourceBase = <T extends AgentApprovalTokenMigrationV3['source']>(
    source: T,
  ): T => source;
  if (value === null) {
    if (
      call !== undefined &&
      (call.access === 'conversation_confirm' ||
        call.access === 'confirm_once') &&
      (decision === 'pending' ||
        decision === 'allow_once' ||
        decision === 'allow_conversation')
    ) {
      return {
        schema_version: 3,
        source_schema_version: 2,
        source: sourceBase({
          schema_version: 2,
          source_kind: 'approved_opaque_string',
          approval_token: null,
        }),
        status: 'needs_reprepare',
        approval_token: null,
        decision: 'cancelled',
        historical_decision: decision,
        failure_code: 'E_AGENT_APPROVAL',
      };
    }
    return {
      schema_version: 3,
      source_schema_version: 2,
      source: sourceBase({
        schema_version: 2,
        source_kind: 'approved_opaque_string',
        approval_token: null,
      }),
      status: 'preserved',
      approval_token: null,
      decision,
      historical_decision: null,
      failure_code: null,
    };
  }
  if (typeof value === 'string') {
    const token = opaqueProviderId(value, '$.approval_token');
    const source = sourceBase({
      schema_version: 2,
      source_kind: 'approved_opaque_string',
      approval_token: token,
    });
    if (
      decision === 'denied' ||
      decision === 'cancelled' ||
      (call !== undefined &&
        call.access !== 'conversation_confirm' &&
        call.access !== 'confirm_once')
    ) {
      return {
        schema_version: 3,
        source_schema_version: 2,
        source,
        status: 'cancelled',
        approval_token: null,
        decision: decision === 'denied' ? 'denied' : 'cancelled',
        historical_decision: decision,
        failure_code: 'E_AGENT_APPROVAL',
      };
    }
    return {
      schema_version: 3,
      source_schema_version: 2,
      source,
      status: 'preserved',
      approval_token: token,
      decision,
      historical_decision: null,
      failure_code: null,
    };
  }
  const raw = record(value, '$.approval_token');
  const schemaDescriptor = Object.getOwnPropertyDescriptor(raw, 'schema_version');
  if (
    schemaDescriptor === undefined ||
    !Object.prototype.hasOwnProperty.call(schemaDescriptor, 'value') ||
    schemaDescriptor.enumerable !== true
  ) {
    return invalid(
      '$.approval_token.schema_version',
      'must be an enumerable own data property',
    );
  }
  const schemaVersion = schemaDescriptor.value;
  if (schemaVersion === 1) {
    const legacy = parseAgentApprovalToken(value, '$.approval_token');
    const source = sourceBase({
      schema_version: 2,
      source_kind: 'current_object_legacy',
      approval_token: legacy,
    });
    if (
      expectedControllerCAS !== undefined &&
      (legacy.controller_cas.schema_version !== expectedControllerCAS.schema_version ||
        legacy.controller_cas.conversation_id !== expectedControllerCAS.conversation_id ||
        legacy.controller_cas.task_id !== expectedControllerCAS.task_id ||
        legacy.controller_cas.attempt_id !== expectedControllerCAS.attempt_id ||
        legacy.controller_cas.expected_controller_generation !==
          expectedControllerCAS.expected_controller_generation ||
        legacy.controller_cas.expected_journal_revision !==
          expectedControllerCAS.expected_journal_revision ||
        legacy.controller_cas.expected_session_generation !==
          expectedControllerCAS.expected_session_generation ||
        legacy.controller_cas.expected_session_sha256 !==
          expectedControllerCAS.expected_session_sha256)
    ) {
      return invalid(
        '$.approval_token.controller_cas',
        'must match the complete containing controller CAS',
      );
    }
    if (
      call !== undefined &&
      (legacy.call_id !== call.call_id ||
        legacy.call_index !== call.call_index ||
        legacy.name !== call.name ||
        legacy.access !== call.access ||
        legacy.arguments_sha256 !== call.arguments_sha256)
    ) {
      return {
        schema_version: 3,
        source_schema_version: 2,
        source,
        status: 'needs_reprepare',
        approval_token: null,
        decision: 'cancelled',
        historical_decision: decision,
        failure_code: 'E_AGENT_CONFLICT',
      };
    }
    return {
      schema_version: 3,
      source_schema_version: 2,
      source,
      status:
        decision === 'denied' || decision === 'cancelled'
          ? 'cancelled'
          : 'needs_reprepare',
      approval_token: null,
      decision: decision === 'denied' ? 'denied' : 'cancelled',
      historical_decision: decision,
      failure_code:
        decision === 'denied' || decision === 'cancelled'
          ? 'E_AGENT_APPROVAL'
          : 'E_AGENT_APPROVAL',
    };
  }
  if (schemaVersion === 2) {
    const runtime = parseAgentApprovalBindingTokenV2(value, '$.approval_token');
    const source = sourceBase({
      schema_version: 2,
      source_kind: 'runtime_object_v2',
      approval_token: runtime,
    });
    // Runtime V2 is a native-issued authority envelope.  Hydration cannot
    // prove its native binding, so it is never flattened into a V3 token.
    // Terminal decisions retain their terminal meaning; live decisions are
    // made inert and require a fresh native prepare/bind operation.
    return {
      schema_version: 3,
      source_schema_version: 2,
      source,
      status: 'needs_reprepare',
      approval_token: null,
      decision: decision === 'denied' ? 'denied' : 'cancelled',
      historical_decision: decision,
      failure_code: 'E_AGENT_APPROVAL',
    };
  }
  return invalid(
    '$.approval_token',
    'must be null, an opaque token, or a supported migration object',
  );
}

function parseAgentCallForFinal(
  value: unknown,
  path: string,
  registryVersion: AgentRegistryVersion,
): PersistedAgentCallJournalV3 {
  const raw = exactRecord(value, path, [
    'schema_version',
    'call_id',
    'call_index',
    'name',
    'arguments_sha256',
    'safe_summary_key',
    'access',
    'approval_token',
    'approval_decision',
    'approval_reference',
    'idempotency_key',
    'native_row_revision',
    'receipt',
  ]);
  if (raw.schema_version === AGENT_CALL_JOURNAL_SCHEMA_VERSION_V3) {
    return parsePersistedAgentCallJournalV3(value, path, registryVersion);
  }
  if (raw.schema_version !== AGENT_CALL_JOURNAL_SCHEMA_VERSION) {
    return invalid(`${path}.schema_version`, 'must equal 2 or 3');
  }
  const callStub = {
    call_id: opaqueProviderId(raw.call_id, `${path}.call_id`),
    call_index: nonNegativeSafeInteger(raw.call_index, `${path}.call_index`),
    name: boundedString(raw.name, `${path}.name`, 64),
    access: raw.access as AgentAccess,
    arguments_sha256: sha256(raw.arguments_sha256, `${path}.arguments_sha256`),
  } as const;
  // A native-issued runtime V2 envelope is authority, not a migration input.
  // Pure session hydration has no native revalidation capability, so it must
  // reject the object instead of flattening `runtime.token` into V3 storage.
  if (
    typeof raw.approval_token === 'object' &&
    raw.approval_token !== null &&
    !Array.isArray(raw.approval_token)
  ) {
    const tokenSchemaDescriptor = Object.getOwnPropertyDescriptor(
      raw.approval_token,
      'schema_version',
    );
    if (
      tokenSchemaDescriptor === undefined ||
      !Object.prototype.hasOwnProperty.call(tokenSchemaDescriptor, 'value') ||
      tokenSchemaDescriptor.enumerable !== true
    ) {
      return invalid(
        `${path}.approval_token`,
        'approval bindings must be plain data records',
      );
    }
    if (tokenSchemaDescriptor.value === 2) {
      return invalid(
        `${path}.approval_token`,
        'runtime approval bindings require native revalidation before hydration',
      );
    }
  }
  const decision = raw.approval_decision;
  if (!agentApprovalDecisions.has(decision as string)) {
    return invalid(
      `${path}.approval_decision`,
      'must be a supported approval decision',
    );
  }
  const migration = migrateAgentApprovalTokenV3(
    raw.approval_token,
    decision as AgentApprovalDecision,
    callStub,
  );
  const migrated = {
    ...raw,
    schema_version: AGENT_CALL_JOURNAL_SCHEMA_VERSION_V3,
    approval_token: migration.approval_token,
    approval_decision: migration.decision,
  };
  // `exactRecord` above already established the source key set.  The final
  // parser performs all field, policy, receipt, and terminal-authority checks.
  return parsePersistedAgentCallJournalV3(migrated, path, registryVersion);
}

/** Parses final V3 journals and atomically classifies early schema-9 journals. */
export function parsePersistedAgentAttemptJournalV3(
  value: unknown,
  path = '$',
  expectedIdentity?: {
    readonly taskId: string;
    readonly attemptId: string;
    readonly controllerCAS?: AgentControllerCASV1;
  },
): PersistedAgentAttemptJournalV3 {
  const raw = exactRecord(value, path, [
    'schema_version',
    'phase',
    'controller_generation',
    'policy',
    'root',
    'tool_registry_version',
    'toolset_sha256',
    'transcript',
    'round_index',
    'round_lineage',
    'call_index',
    'batch',
    'frozen_grant_ids',
    'reserved_write_bytes',
    'updated_at',
  ]);
  if (
    raw.schema_version !== AGENT_ATTEMPT_JOURNAL_SCHEMA_VERSION &&
    raw.schema_version !== AGENT_ATTEMPT_JOURNAL_SCHEMA_VERSION_V3
  ) {
    return invalid(`${path}.schema_version`, 'must equal 2 or 3');
  }
  if (typeof raw.phase !== 'string' || !agentPhases.has(raw.phase)) {
    return invalid(`${path}.phase`, 'must be a supported Agent phase');
  }
  const controllerGeneration = nonNegativeSafeInteger(
    raw.controller_generation,
    `${path}.controller_generation`,
  );
  if (controllerGeneration >= Number.MAX_SAFE_INTEGER) {
    return invalid(
      `${path}.controller_generation`,
      'must leave room for the next transition',
    );
  }
  const policy = parseAgentPolicy(raw.policy, `${path}.policy`);
  const root = parseAgentRoot(raw.root, `${path}.root`);
  if (!isAgentRegistryVersion(raw.tool_registry_version)) {
    return invalid(`${path}.tool_registry_version`, 'must equal 1, 2, or 3');
  }
  const toolsetSha256 = sha256(raw.toolset_sha256, `${path}.toolset_sha256`);
  const transcript = parseTranscriptReference(
    raw.transcript,
    `${path}.transcript`,
  );
  const roundIndex = nonNegativeSafeInteger(
    raw.round_index,
    `${path}.round_index`,
  );
  if (roundIndex >= MAX_AGENT_ROUNDS) {
    return invalid(`${path}.round_index`, 'must be less than 8');
  }
  const lineage =
    raw.round_lineage === null
      ? null
      : (() => {
          const line = exactRecord(raw.round_lineage, `${path}.round_lineage`, [
            'schema_version',
            'round_id',
            'round_index',
            'launch_attempt',
            'status',
            'native_row_revision',
          ]);
          if (line.schema_version !== AGENT_ROUND_LINEAGE_SCHEMA_VERSION) {
            return invalid(
              `${path}.round_lineage.schema_version`,
              'must equal 2',
            );
          }
          const lineRoundIndex = nonNegativeSafeInteger(
            line.round_index,
            `${path}.round_lineage.round_index`,
          );
          if (
            lineRoundIndex !== roundIndex ||
            lineRoundIndex >= MAX_AGENT_ROUNDS
          ) {
            return invalid(
              `${path}.round_lineage.round_index`,
              'must match the journal round',
            );
          }
          const launchAttempt = nonNegativeSafeInteger(
            line.launch_attempt,
            `${path}.round_lineage.launch_attempt`,
          );
          if (launchAttempt < 1 || launchAttempt > MAX_AGENT_ROUNDS) {
            return invalid(
              `${path}.round_lineage.launch_attempt`,
              'must be between 1 and 8',
            );
          }
          if (!agentLineageStatuses.has(line.status as string)) {
            return invalid(
              `${path}.round_lineage.status`,
              'must be a supported lineage status',
            );
          }
          const nativeRowRevision =
            line.native_row_revision === null
              ? null
              : (() => {
                  const revision = nonNegativeSafeInteger(
                    line.native_row_revision,
                    `${path}.round_lineage.native_row_revision`,
                  );
                  return revision < 1
                    ? invalid(
                        `${path}.round_lineage.native_row_revision`,
                        'must be positive',
                      )
                    : revision;
                })();
          return {
            schema_version: AGENT_ROUND_LINEAGE_SCHEMA_VERSION,
            round_id: canonicalLifecycleId(
              line.round_id,
              `${path}.round_lineage.round_id`,
            ),
            round_index: lineRoundIndex,
            launch_attempt: launchAttempt,
            status: line.status as PersistedAgentRoundLineageV2['status'],
            native_row_revision: nativeRowRevision,
          };
        })();
  const callIndex =
    raw.call_index === null
      ? null
      : nonNegativeSafeInteger(raw.call_index, `${path}.call_index`);
  const batchRaw = array(raw.batch, `${path}.batch`, MAX_AGENT_CALLS_PER_BATCH);
  const batch = batchRaw.map((entry, index) =>
    parseAgentCallForFinal(entry, `${path}.batch[${index}]`, raw.tool_registry_version as AgentRegistryVersion),
  );
  batchRaw.forEach((entry, index) => {
    if (
      typeof entry !== 'object' ||
      entry === null ||
      Array.isArray(entry)
    ) return;
    const approvalTokenDescriptor = Object.getOwnPropertyDescriptor(
      entry,
      'approval_token',
    );
    const approvalToken = approvalTokenDescriptor !== undefined &&
      Object.prototype.hasOwnProperty.call(approvalTokenDescriptor, 'value')
      ? approvalTokenDescriptor.value
      : undefined;
    if (
      typeof approvalToken !== 'object' ||
      approvalToken === null ||
      Array.isArray(approvalToken) ||
      Object.getOwnPropertyDescriptor(approvalToken, 'schema_version')?.value !== 1
    ) return;
    const token = parseAgentApprovalToken(
      approvalToken,
      `${path}.batch[${index}].approval_token`,
    );
    const call = batch[index];
    if (call === undefined) {
      return invalid(
        `${path}.batch[${index}].approval_token`,
        'must reference a containing call',
      );
    }
    validateLegacyApprovalTokenRelations(
      token,
      call,
      batch,
      lineage,
      roundIndex,
      root,
      policy,
      controllerGeneration,
      `${path}.batch[${index}]`,
      expectedIdentity,
      expectedIdentity?.controllerCAS,
    );
  });
  const runtimeTokens = batchRaw.map((entry, index) => {
    if (typeof entry !== 'object' || entry === null || Array.isArray(entry)) {
      return null;
    }
    const tokenValue = (entry as Record<string, unknown>).approval_token;
    if (
      typeof tokenValue !== 'object' ||
      tokenValue === null ||
      Array.isArray(tokenValue) ||
      (tokenValue as Record<string, unknown>).schema_version !== 2
    ) {
      return null;
    }
    return parseAgentApprovalBindingTokenV2(
      tokenValue,
      `${path}.batch[${index}].approval_token`,
    );
  });
  const callIds = new Set<string>();
  batch.forEach((call, index) => {
    if (call.call_index !== index) {
      invalid(`${path}.batch[${index}].call_index`, 'must be contiguous');
    }
    if (callIds.has(call.call_id)) {
      invalid(
        `${path}.batch[${index}].call_id`,
        'must be unique within the batch',
      );
    }
    callIds.add(call.call_id);
  });
  runtimeTokens.forEach((token, index) => {
    if (token === null) return;
    const call = batch[index];
    if (
      call === undefined ||
      lineage === null ||
      token.round_id !== lineage.round_id ||
      token.round_index !== roundIndex ||
      token.root_fingerprint_sha256 !== root.root_fingerprint_sha256 ||
      token.binding_revision !== root.workspace_binding_revision ||
      token.policy_version !== policy.policy_version ||
      !isAgentRegistryVersion(token.registry_version) ||
      token.batch_call_ids.length !== batch.length ||
      token.batch_arguments_sha256.length !== batch.length ||
      token.batch_call_ids.some(
        (callId, batchIndex) => callId !== batch[batchIndex]?.call_id,
      ) ||
      token.batch_arguments_sha256.some(
        (digest, batchIndex) => digest !== batch[batchIndex]?.arguments_sha256,
      ) ||
      !sameApprovalTokenCall(token, call)
    ) {
      invalid(
        `${path}.batch[${index}].approval_token`,
        'runtime approval binding must match the complete containing batch',
      );
    }
  });
  if (callIndex !== null && callIndex >= batch.length) {
    return invalid(`${path}.call_index`, 'must reference a batch call');
  }
  const frozenGrantIds = uniqueStringArray(
    raw.frozen_grant_ids,
    `${path}.frozen_grant_ids`,
    MAX_AGENT_GRANTS_PER_CONVERSATION,
    true,
  );
  const reservedWriteBytes = nonNegativeSafeInteger(
    raw.reserved_write_bytes,
    `${path}.reserved_write_bytes`,
  );
  if (reservedWriteBytes > policy.max_attempt_write_bytes) {
    return invalid(
      `${path}.reserved_write_bytes`,
      'exceeds the attempt write budget',
    );
  }
  const migratedStaleCall =
    raw.schema_version === AGENT_ATTEMPT_JOURNAL_SCHEMA_VERSION &&
    batch.some((call, index) => {
      const source = batchRaw[index];
      if (
        typeof source !== 'object' ||
        source === null ||
        Array.isArray(source)
      ) {
        return false;
      }
      const sourceRecord = source as Record<string, unknown>;
      const sourceDecision = sourceRecord.approval_decision;
      const sourceAccess = sourceRecord.access;
      return (
        (sourceAccess === 'conversation_confirm' ||
          sourceAccess === 'confirm_once') &&
        (sourceDecision === 'pending' ||
          sourceDecision === 'allow_once' ||
          sourceDecision === 'allow_conversation') &&
        call.approval_decision === 'cancelled'
      );
    });
  // A legacy live approval is made inert at the call boundary only.  Hydration
  // must not invent a cancelled outer journal phase or mutate its native
  // round lineage; the controller will explicitly reprepare the attempt.
  const sourcePhase = raw.phase as PersistedAgentAttemptJournalV3['phase'];
  const effectiveLineage = lineage;
  const effectiveCallIndex = callIndex;
  const effectiveBatch = batch;
  const allMigratedCallsInert =
    effectiveBatch.length > 0 &&
    effectiveBatch.every(
      call =>
        call.approval_decision === 'denied' ||
        call.approval_decision === 'cancelled',
    );
  // A legacy live approval is converted to a cancelled call with no token.
  // If that conversion consumes the whole batch, retaining the outer
  // `approval_pending` phase would create an impossible V3 journal that can
  // never round-trip.  Promote only this fully inert migration result to the
  // terminal cancelled phase; mixed batches retain approval_pending because a
  // surviving pending call still explains that phase.
  const phase =
    raw.schema_version === AGENT_ATTEMPT_JOURNAL_SCHEMA_VERSION &&
    sourcePhase === 'approval_pending' &&
    migratedStaleCall &&
    allMigratedCallsInert
      ? 'cancelled'
      : sourcePhase;
  if (!isAgentPhaseLineageValid(phase, effectiveLineage?.status ?? null)) {
    return invalid(
      `${path}.phase`,
      'does not match the closed phase-lineage matrix',
    );
  }
  if (phase === 'cancelled' && effectiveLineage === null &&
      (raw.round_index !== 0 || effectiveBatch.length !== 0 ||
       raw.call_index !== null || raw.reserved_write_bytes !== 0)) {
    return invalid(`${path}.phase`, 'an unstarted cancelled attempt cannot contain round effects');
  }
  if (
    phase === 'approval_pending' &&
    !effectiveBatch.some(
      call =>
        call.access !== 'auto' &&
        call.access !== 'durable_deny' &&
        call.approval_decision === 'pending',
    ) &&
    !migratedStaleCall
  ) {
    return invalid(
      `${path}.phase`,
      'approval_pending requires a pending gated call',
    );
  }
  if (phase === 'execution_intent') {
    const call =
      effectiveCallIndex === null
        ? undefined
        : effectiveBatch[effectiveCallIndex];
    if (
      call === undefined ||
      call.idempotency_key === null ||
      (call.access !== 'auto' &&
        call.approval_decision !== 'allow_once' &&
        call.approval_decision !== 'allow_conversation')
    ) {
      return invalid(
        `${path}.phase`,
        'execution_intent requires an approved call and idempotency key',
      );
    }
  }
  if (phase === 'tool_result_pending') {
    const call =
      effectiveCallIndex === null
        ? undefined
        : effectiveBatch[effectiveCallIndex];
    if (
      call === undefined ||
      call.receipt === null ||
      (call.receipt.outcome !== 'ok' &&
        call.receipt.outcome !== 'failed' &&
        call.receipt.outcome !== 'denied')
    ) {
      return invalid(
        `${path}.phase`,
        'tool_result_pending requires a settled receipt',
      );
    }
  }
  if (
    phase === 'final_response' &&
    (effectiveCallIndex !== null || effectiveBatch.length !== 0)
  ) {
    return invalid(
      `${path}.phase`,
      'final response cannot retain a call batch',
    );
  }
  if (
    phase === 'cancelled' &&
    effectiveBatch.some(
      call =>
        call.receipt === null &&
        call.approval_decision !== 'denied' &&
        call.approval_decision !== 'cancelled',
    )
  ) {
    return invalid(
      `${path}.phase`,
      'cancelled requires all unsettled calls to be inert',
    );
  }
  for (const [index, call] of effectiveBatch.entries()) {
    if (!hasFrozenConversationGrant(call, { root, policy, tool_registry_version: raw.tool_registry_version, frozen_grant_ids: frozenGrantIds }))
      invalid(`${path}.batch[${index}].approval_reference`, 'must reference a frozen grant for this tool family');
  }
  return {
    schema_version: AGENT_ATTEMPT_JOURNAL_SCHEMA_VERSION_V3,
    phase,
    controller_generation: controllerGeneration,
    policy,
    root,
    tool_registry_version: raw.tool_registry_version,
    toolset_sha256: toolsetSha256,
    transcript,
    round_index: roundIndex,
    round_lineage: effectiveLineage,
    call_index: effectiveCallIndex,
    batch: effectiveBatch,
    frozen_grant_ids: frozenGrantIds,
    reserved_write_bytes: reservedWriteBytes,
    updated_at: timestamp(raw.updated_at, `${path}.updated_at`),
  };
}

function parseAgentGrant(
  value: unknown,
  path: string,
): AgentConversationGrantV2 {
  const raw = exactRecord(value, path, [
    'schema_version',
    'grant_id',
    'conversation_id',
    'workspace_id',
    'project_id',
    'binding_revision',
    'root_fingerprint_sha256',
    'tool_family',
    'registry_version',
    'policy_version',
    'issued_for',
    'created_at',
  ]);
  if (raw.schema_version !== AGENT_GRANT_SCHEMA_VERSION)
    return invalid(`${path}.schema_version`, 'must equal 2');
  if (
    raw.tool_family !== 'file_write' &&
    raw.tool_family !== 'git_commit' &&
    raw.tool_family !== 'git_push' &&
    raw.tool_family !== 'guest_service'
  )
    return invalid(
      `${path}.tool_family`,
      'must be file_write, git_commit, git_push, or guest_service',
    );
  if (!isAgentRegistryVersion(raw.registry_version))
    return invalid(`${path}.registry_version`, 'must equal 1, 2, or 3');
  if (raw.tool_family === 'guest_service' && raw.registry_version === 1)
    return invalid(`${path}.registry_version`, 'guest_service requires registry version 2 or 3');
  const projectId =
    raw.project_id === null
      ? null
      : canonicalLifecycleId(raw.project_id, `${path}.project_id`);
  if (raw.tool_family !== 'file_write' && raw.tool_family !== 'guest_service' && projectId === null)
    return invalid(`${path}.project_id`, 'Git grants require a project');
  const issued = exactRecord(raw.issued_for, `${path}.issued_for`, [
    'schema_version',
    'task_id',
    'attempt_id',
  ]);
  if (issued.schema_version !== 1)
    return invalid(`${path}.issued_for.schema_version`, 'must equal 1');
  return {
    schema_version: AGENT_GRANT_SCHEMA_VERSION,
    grant_id: canonicalLifecycleId(raw.grant_id, `${path}.grant_id`),
    conversation_id: boundedIdentifier(
      raw.conversation_id,
      `${path}.conversation_id`,
      MAX_ID_LENGTH,
    ),
    workspace_id: canonicalLifecycleId(
      raw.workspace_id,
      `${path}.workspace_id`,
    ),
    project_id: projectId,
    binding_revision: (() => {
      const revision = lifecycleEpoch(
        raw.binding_revision,
        `${path}.binding_revision`,
        false,
      );
      return revision >= Number.MAX_SAFE_INTEGER
        ? invalid(
            `${path}.binding_revision`,
            'must be less than Number.MAX_SAFE_INTEGER',
          )
        : revision;
    })(),
    root_fingerprint_sha256: sha256(
      raw.root_fingerprint_sha256,
      `${path}.root_fingerprint_sha256`,
    ),
    tool_family: raw.tool_family,
    registry_version: raw.registry_version,
    policy_version: boundedIdentifier(
      raw.policy_version,
      `${path}.policy_version`,
      256,
    ),
    issued_for: {
      schema_version: 1,
      task_id: canonicalLifecycleId(
        issued.task_id,
        `${path}.issued_for.task_id`,
      ),
      attempt_id: canonicalLifecycleId(
        issued.attempt_id,
        `${path}.issued_for.attempt_id`,
      ),
    },
    created_at: timestamp(raw.created_at, `${path}.created_at`),
  };
}

function parseCleanupEntry(
  value: unknown,
  path: string,
): AgentTranscriptCleanupV1 {
  const raw = exactRecord(value, path, [
    'schema_version',
    'cleanup_id',
    'conversation_id',
    'task_id',
    'attempt_id',
    'transcript_ref',
    'transcript_sha256',
    'reason',
    'created_at',
  ]);
  if (raw.schema_version !== AGENT_CLEANUP_SCHEMA_VERSION)
    return invalid(`${path}.schema_version`, 'must equal 1');
  if (
    raw.reason !== 'completed' &&
    raw.reason !== 'cancelled' &&
    raw.reason !== 'failed' &&
    raw.reason !== 'conversation_deleted'
  )
    return invalid(`${path}.reason`, 'must be a supported cleanup reason');
  return {
    schema_version: AGENT_CLEANUP_SCHEMA_VERSION,
    cleanup_id: canonicalLifecycleId(raw.cleanup_id, `${path}.cleanup_id`),
    conversation_id: boundedIdentifier(
      raw.conversation_id,
      `${path}.conversation_id`,
      MAX_ID_LENGTH,
    ),
    task_id: canonicalLifecycleId(raw.task_id, `${path}.task_id`),
    attempt_id: canonicalLifecycleId(raw.attempt_id, `${path}.attempt_id`),
    transcript_ref: canonicalLifecycleId(
      raw.transcript_ref,
      `${path}.transcript_ref`,
    ),
    transcript_sha256: sha256(
      raw.transcript_sha256,
      `${path}.transcript_sha256`,
    ),
    reason: raw.reason,
    created_at: timestamp(raw.created_at, `${path}.created_at`),
  };
}

function parseSessionEvent(
  value: unknown,
  path: string,
): PersistedSessionEventV3 {
  const raw = exactRecord(value, path, [
    'schema_version',
    'event_id',
    'attempt_id',
    'seq',
    'kind',
    'round_index',
    'call_id',
    'status',
    'safe_summary_key',
    'arguments_sha256',
    'result_sha256',
    'approval_reference',
    'failure_code',
    'created_at',
  ]);
  if (raw.schema_version !== SESSION_EVENT_V2_SCHEMA_VERSION)
    return invalid(`${path}.schema_version`, 'must equal 2');
  if (typeof raw.kind !== 'string' || !sessionEventKinds.has(raw.kind))
    return invalid(`${path}.kind`, 'must be a supported event kind');
  const eventId = canonicalLifecycleId(raw.event_id, `${path}.event_id`);
  const attemptId = canonicalLifecycleId(raw.attempt_id, `${path}.attempt_id`);
  const seq = nonNegativeSafeInteger(raw.seq, `${path}.seq`);
  if (typeof raw.status !== 'string' || !sessionEventStatuses.has(raw.status))
    return invalid(`${path}.status`, 'must be a supported event status');
  const roundIndex =
    raw.round_index === null
      ? null
      : nonNegativeSafeInteger(raw.round_index, `${path}.round_index`);
  if (roundIndex !== null && roundIndex >= MAX_AGENT_ROUNDS)
    return invalid(`${path}.round_index`, 'must be less than 8');
  const callId =
    raw.call_id === null
      ? null
      : opaqueProviderId(raw.call_id, `${path}.call_id`);
  const safeSummaryKey =
    raw.safe_summary_key === null
      ? null
      : boundedString(
          raw.safe_summary_key,
          `${path}.safe_summary_key`,
          MAX_AGENT_SUMMARY_KEY_LENGTH,
        );
  if (safeSummaryKey !== null && !safeSummaryKeys.has(safeSummaryKey))
    return invalid(
      `${path}.safe_summary_key`,
      'must be a registered summary key',
    );
  const argumentsSha =
    raw.arguments_sha256 === null
      ? null
      : sha256(raw.arguments_sha256, `${path}.arguments_sha256`);
  const resultSha =
    raw.result_sha256 === null
      ? null
      : sha256(raw.result_sha256, `${path}.result_sha256`);
  const approvalReference =
    raw.approval_reference === null
      ? null
      : boundedIdentifier(
          raw.approval_reference,
          `${path}.approval_reference`,
          MAX_ID_LENGTH,
        );
  if (raw.kind === 'cancel') {
    if (
      raw.status !== 'cancelled' ||
      safeSummaryKey !== null ||
      resultSha !== null ||
      approvalReference !== eventId ||
      (raw.failure_code !== 'E_AGENT_CANCELLED' &&
        raw.failure_code !== 'E_AGENT_ROOT_STALE' &&
        raw.failure_code !== 'E_AGENT_PERSISTENCE')
    ) {
      return invalid(
        path,
        'cancel events must carry the exact cancellation envelope',
      );
    }
    const attemptCancel =
      roundIndex === null && callId === null && argumentsSha === null;
    const roundCancel =
      roundIndex !== null && callId === null && argumentsSha === null;
    const callCancel =
      roundIndex !== null && callId !== null && argumentsSha !== null;
    if (!attemptCancel && !roundCancel && !callCancel) {
      return invalid(path, 'cancel target coordinates are invalid');
    }
    return {
      schema_version: SESSION_EVENT_V2_SCHEMA_VERSION,
      event_id: eventId,
      attempt_id: attemptId,
      seq,
      kind: 'cancel',
      round_index: roundIndex,
      call_id: callId,
      status: 'cancelled',
      safe_summary_key: null,
      arguments_sha256: argumentsSha,
      result_sha256: null,
      approval_reference: approvalReference as string,
      failure_code: raw.failure_code,
      created_at: timestamp(raw.created_at, `${path}.created_at`),
    } as AgentCancelEventV2;
  }
  return {
    schema_version: SESSION_EVENT_V2_SCHEMA_VERSION,
    event_id: eventId,
    attempt_id: attemptId,
    seq,
    kind: raw.kind as SessionEventV2['kind'],
    round_index: roundIndex,
    call_id: callId,
    status: raw.status as SessionEventV2['status'],
    safe_summary_key: safeSummaryKey,
    arguments_sha256: argumentsSha,
    result_sha256: resultSha,
    approval_reference: approvalReference,
    failure_code: agentFailureCode(raw.failure_code, `${path}.failure_code`),
    created_at: timestamp(raw.created_at, `${path}.created_at`),
  };
}

function validateSessionEventCorrelations(
  events: readonly PersistedSessionEventV3[],
  conversations: Readonly<Record<string, Conversation>>,
): void {
  const eventCalls = new Map<
    string,
    {
      readonly attemptId: string;
      readonly roundIndex: number | null;
      readonly name?: string;
      readonly safeSummaryKey?: string;
      readonly argumentsSha256?: string;
      readonly approvalReference?: string | null;
      readonly resultSha256?: string;
      readonly failureCode?: AgentFailureCode | null;
    }
  >();
  const attempts = new Map<string, TurnAttemptV1>();
  Object.values(conversations).forEach(conversation => {
    conversation.attempts.forEach(attempt =>
      attempts.set(attempt.attemptId, attempt),
    );
  });
  events.forEach((event, index) => {
    const path = `$.session_events[${index}]`;
    const attempt = attempts.get(event.attempt_id);
    if (attempt === undefined) {
      invalid(`${path}.attempt_id`, 'must reference an existing attempt');
    }
    if (event.kind === 'cancel') {
      // Cancellation is a source-authority event, not a settled receipt.  Its
      // exact coordinates and event-id reference were checked by parseSessionEvent.
      if (
        event.approval_reference !== event.event_id ||
        event.status !== 'cancelled'
      ) {
        invalid(path, 'cancel events must retain their source event authority');
      }
      if (event.round_index !== null) {
        const roundKnown =
          event.round_index < (attempt?.rounds.length ?? 0) ||
          event.round_index === attempt?.agent?.round_index;
        if (!roundKnown) {
          invalid(
            `${path}.round_index`,
            'must reference a known attempt round',
          );
        }
        if (event.call_id !== null) {
          const call = attempt?.agent?.batch.find(
            candidate => candidate.call_id === event.call_id,
          );
          if (
            call === undefined ||
            call.arguments_sha256 !== event.arguments_sha256
          ) {
            invalid(
              `${path}.call_id`,
              'must reference the matching journal call',
            );
          }
        }
      }
      return;
    }
    const journalCall = attempt?.agent?.batch.find(
      call => call.call_id === event.call_id,
    );
    const eventCallKey =
      event.call_id === null ? null : `${event.attempt_id}\0${event.call_id}`;
    const previous =
      eventCallKey === null ? undefined : eventCalls.get(eventCallKey);
    if (
      event.round_index !== null &&
      event.round_index >= (attempt?.rounds.length ?? 0) &&
      event.round_index !== attempt?.agent?.round_index
    ) {
      invalid(`${path}.round_index`, 'must reference a known attempt round');
    }
    if (event.kind === 'round') {
      if (
        event.call_id !== null ||
        event.arguments_sha256 !== null ||
        event.result_sha256 !== null ||
        event.approval_reference !== null ||
        event.safe_summary_key !== null
      )
        invalid(path, 'round events cannot carry call fields');
      return;
    }
    if (event.kind === 'terminal') {
      const expectedTerminalStatus =
        attempt?.agent?.phase === 'final_response'
          ? 'ok'
          : attempt?.agent?.phase === 'cancelled'
          ? 'cancelled'
          : attempt?.agent?.phase === 'failed'
          ? 'failed'
          : attempt?.agent?.phase === 'unknown'
          ? 'unknown'
          : attempt?.agent?.phase === 'ambiguous'
          ? 'ambiguous'
          : null;
      if (
        event.call_id !== null ||
        event.arguments_sha256 !== null ||
        event.result_sha256 !== null ||
        event.approval_reference !== null ||
        event.safe_summary_key !== null
      )
        invalid(path, 'terminal events cannot carry call fields');
      if (
        expectedTerminalStatus !== null &&
        event.status !== expectedTerminalStatus
      )
        invalid(`${path}.status`, 'must match the terminal journal phase');
      return;
    }
    if (event.call_id === null) {
      invalid(`${path}.call_id`, 'call events require a call id');
    }
    const historicalEvent =
      journalCall === undefined &&
      previous === undefined &&
      event.round_index !== null &&
      attempt?.agent?.schema_version === 3 &&
      event.round_index < attempt.agent.round_index &&
      attempt.rounds.some(round => round.roundIndex === event.round_index);
    if (journalCall === undefined && previous === undefined && !historicalEvent) {
      invalid(`${path}.call_id`, 'must reference a journal call');
    }
    if (
      journalCall !== undefined &&
      event.round_index !== attempt?.agent?.round_index
    ) {
      invalid(`${path}.round_index`, 'must match the journal round');
    }
    if (previous !== undefined && previous.roundIndex !== event.round_index) {
      invalid(`${path}.round_index`, 'must match the previous call event');
    }
    const knownArguments =
      journalCall?.arguments_sha256 ?? previous?.argumentsSha256;
    const knownSummary =
      journalCall?.safe_summary_key ?? previous?.safeSummaryKey;
    const knownApproval =
      journalCall !== undefined
        ? journalCall.approval_reference
        : previous?.approvalReference;
    if (
      event.arguments_sha256 !== null &&
      knownArguments !== undefined &&
      event.arguments_sha256 !== knownArguments
    )
      invalid(`${path}.arguments_sha256`, 'must match the journal call');
    if (
      event.safe_summary_key !== null &&
      knownSummary !== undefined &&
      event.safe_summary_key !== knownSummary
    )
      invalid(`${path}.safe_summary_key`, 'must match the journal call');
    // A denied/cancelled decision persists a null approval reference; its
    // durable marker is the decide_approval preflight event whose reference
    // equals its own event id (the bind operation id).  Accept that marker
    // against the null-reference call it closed.
    const denialMarker =
      journalCall !== undefined &&
      event.kind === 'approval' &&
      event.approval_reference === event.event_id &&
      journalCall.approval_reference === null &&
      (journalCall.approval_decision === 'denied' ||
        journalCall.approval_decision === 'cancelled');
    if (
      journalCall !== undefined &&
      event.kind !== 'tool_call' &&
      !denialMarker &&
      !(event.kind === 'approval' && event.approval_reference === null) &&
      event.approval_reference !== knownApproval
    )
      invalid(`${path}.approval_reference`, 'must match the journal call');
    // A user denial settles with a null approval reference after its
    // decide_approval marker; the exact denied receipt shape identifies it
    // once the journal batch has been cleared for the next round.
    const historicalUserDenial =
      journalCall === undefined &&
      previous !== undefined &&
      event.kind === 'tool_result' &&
      event.status === 'denied' &&
      event.failure_code === 'E_AGENT_DENIED_BY_USER' &&
      event.approval_reference === null;
    if (
      journalCall === undefined &&
      previous !== undefined &&
      event.kind !== 'tool_call' &&
      !historicalUserDenial &&
      event.approval_reference !== knownApproval
    ) {
      invalid(
        `${path}.approval_reference`,
        'must match the previous call event',
      );
    }
    if (event.kind === 'tool_call') {
      if (
        event.arguments_sha256 === null ||
        event.safe_summary_key === null ||
        event.result_sha256 !== null ||
        event.approval_reference !== null ||
        (event.status !== 'waiting' &&
          event.status !== 'approval' &&
          event.status !== 'running')
      )
        invalid(
          path,
          'tool_call events must carry only call presentation fields',
        );
      eventCalls.set(eventCallKey!, {
        ...(previous ?? {
          attemptId: event.attempt_id,
          roundIndex: event.round_index,
        }),
        name: journalCall?.name ?? previous?.name,
        safeSummaryKey: event.safe_summary_key,
        argumentsSha256: event.arguments_sha256,
        // The event itself remains presentation-only/null; do not erase the
        // approval authority already established for this call.
        approvalReference:
          previous?.approvalReference ??
          journalCall?.approval_reference ??
          null,
      });
      return;
    }
    if (event.kind === 'approval') {
      if (
        event.arguments_sha256 === null ||
        event.safe_summary_key === null ||
        event.status !== 'approval'
      )
        invalid(path, 'approval events must carry the call presentation');
      const priorCall = eventCalls.get(eventCallKey!);
      eventCalls.set(eventCallKey!, {
        ...(priorCall ?? {
          attemptId: event.attempt_id,
          roundIndex: event.round_index,
        }),
        safeSummaryKey: event.safe_summary_key,
        argumentsSha256: event.arguments_sha256,
        approvalReference: event.approval_reference,
      });
      return;
    }
    const unknownWithoutReceipt =
      event.status === 'unknown' &&
      event.result_sha256 === null &&
      event.failure_code === 'E_AGENT_CONFLICT' &&
      attempt?.agent?.phase === 'unknown' &&
      attempt.agent.round_lineage?.status === 'unknown' &&
      journalCall !== undefined &&
      journalCall.native_row_revision !== null;
    if (
      event.arguments_sha256 === null ||
      event.safe_summary_key === null ||
      (!unknownWithoutReceipt && event.result_sha256 === null) ||
      (event.status !== 'ok' &&
        event.status !== 'failed' &&
        event.status !== 'denied' &&
        event.status !== 'cancelled' &&
        event.status !== 'unknown' &&
        event.status !== 'ambiguous')
    )
      invalid(path, 'tool_result events must carry a settled call result');
    const receipt = journalCall?.receipt;
    if (
      journalCall !== undefined &&
      receipt === null &&
      !unknownWithoutReceipt
    ) {
      invalid(`${path}.call_id`, 'tool_result requires a journal receipt');
    }
    if (receipt !== undefined && receipt !== null) {
      const expectedStatus = receipt.outcome;
      if (event.status !== expectedStatus) {
        invalid(`${path}.status`, 'must match the journal receipt outcome');
      }
      if (
        event.result_sha256 !== receipt.result_sha256 ||
        event.arguments_sha256 !== receipt.arguments_sha256 ||
        event.approval_reference !== receipt.approval_reference ||
        event.failure_code !== receipt.failure_code
      )
        invalid(path, 'must match the journal receipt');
    }
    const priorCall = eventCalls.get(eventCallKey!);
    if (
      receipt === undefined &&
      priorCall?.resultSha256 !== undefined &&
      (priorCall.resultSha256 !== event.result_sha256 ||
        priorCall.failureCode !== event.failure_code)
    ) {
      invalid(path, 'must match the previous call receipt');
    }
    eventCalls.set(eventCallKey!, {
      ...(priorCall ?? {
        attemptId: event.attempt_id,
        roundIndex: event.round_index,
      }),
      argumentsSha256: event.arguments_sha256,
      ...(event.result_sha256 === null
        ? {}
        : { resultSha256: event.result_sha256 }),
      approvalReference: event.approval_reference,
      failureCode: event.failure_code,
    });
  });
}

function parseTurn(value: unknown, path: string): ConversationTurnV1 {
  const raw = exactRecord(value, path, [
    'schema_version',
    'turn_id',
    'user_message_id',
    'attempt_ids',
    'created_at',
  ]);
  if (raw.schema_version !== CONVERSATION_TURN_SCHEMA_VERSION) {
    return invalid(`${path}.schema_version`, 'must equal 1');
  }
  const attemptIds = uniqueStringArray(
    raw.attempt_ids,
    `${path}.attempt_ids`,
    MAX_ATTEMPTS_PER_CONVERSATION,
    true,
  );
  if (attemptIds.length === 0) {
    return invalid(`${path}.attempt_ids`, 'must not be empty');
  }
  return {
    schemaVersion: CONVERSATION_TURN_SCHEMA_VERSION,
    turnId: canonicalLifecycleId(raw.turn_id, `${path}.turn_id`),
    userMessageId: boundedString(
      raw.user_message_id,
      `${path}.user_message_id`,
      MAX_ID_LENGTH,
    ),
    attemptIds,
    createdAt: timestamp(raw.created_at, `${path}.created_at`),
  };
}

function parseAttempt(
  value: unknown,
  path: string,
  schemaVersion: PersistedSchemaVersion,
  conversationId: string,
  hydrationOptions?: NormalizedChatHydrationOptions,
): TurnAttemptV1 {
  const agentSchema = hasAgentSchema(schemaVersion);
  const attemptKeys = [
    'schema_version',
    'attempt_id',
    'turn_id',
    'status',
    'visible_message_ids',
    'visible_history_sha256',
    'attachment_ids',
    'model_id',
    'thinking_mode',
    'context_disposition',
    'context_project_id',
    ...(hasWorkspaceRoutingShape(schemaVersion)
      ? ['workspace_id', 'workspace_binding_revision']
      : []),
    'project_context',
    'active_round',
    'rounds',
    'assistant_message_id',
    'failure_code',
    'created_at',
    'updated_at',
    ...(agentSchema ? ['journal_revision', 'agent'] : []),
  ] as const;
  const raw = exactRecord(value, path, attemptKeys, ['harness_id']);
  const harnessId =
    raw.harness_id === undefined
      ? 'dsh'
      : isHarnessId(raw.harness_id)
      ? raw.harness_id
      : invalid(path + '.harness_id', 'must be a supported harness');
  if (
    agentSchema
      ? raw.schema_version !== PERSISTED_TURN_ATTEMPT_SCHEMA_VERSION &&
        raw.schema_version !== PERSISTED_TURN_ATTEMPT_SCHEMA_VERSION_V3
      : raw.schema_version !== TURN_ATTEMPT_SCHEMA_VERSION
  ) {
    return invalid(
      `${path}.schema_version`,
      `must equal ${
        agentSchema
          ? `${PERSISTED_TURN_ATTEMPT_SCHEMA_VERSION} or ${PERSISTED_TURN_ATTEMPT_SCHEMA_VERSION_V3}`
          : TURN_ATTEMPT_SCHEMA_VERSION
      }`,
    );
  }
  if (typeof raw.status !== 'string' || !attemptStatuses.has(raw.status)) {
    return invalid(`${path}.status`, 'must be a supported attempt status');
  }
  if (!isModelId(raw.model_id)) {
    return invalid(`${path}.model_id`, 'must be a supported model');
  }
  if (!isConversationThinkingMode(raw.thinking_mode)) {
    return invalid(`${path}.thinking_mode`, 'must be supported');
  }
  if (
    typeof raw.context_disposition !== 'string' ||
    !contextDispositions.has(raw.context_disposition)
  ) {
    return invalid(
      `${path}.context_disposition`,
      'must be a supported context disposition',
    );
  }
  const roundsRaw = array(raw.rounds, `${path}.rounds`, MAX_COMPLETION_ROUNDS);
  if (roundsRaw.length > MAX_COMPLETION_ROUNDS) {
    return invalid(`${path}.rounds`, 'must contain no more than 8 rounds');
  }
  const rounds = roundsRaw.map((entry, index) =>
    parseRoundReceipt(entry, `${path}.rounds[${index}]`),
  );
  const activeRound =
    raw.active_round === null
      ? null
      : (() => {
          const active = exactRecord(raw.active_round, `${path}.active_round`, [
            'round_id',
            'round_index',
          ]);
          const roundIndex = nonNegativeSafeInteger(
            active.round_index,
            `${path}.active_round.round_index`,
          );
          if (roundIndex >= MAX_COMPLETION_ROUNDS) {
            return invalid(
              `${path}.active_round.round_index`,
              'must be less than 8',
            );
          }
          return {
            roundId: canonicalLifecycleId(
              active.round_id,
              `${path}.active_round.round_id`,
            ),
            roundIndex,
          };
        })();
  const failureCode =
    raw.failure_code === null
      ? null
      : isAttemptFailureCode(raw.failure_code)
      ? raw.failure_code
      : invalid(`${path}.failure_code`, 'must be a stable error code');
  const createdAt = timestamp(raw.created_at, `${path}.created_at`);
  const updatedAt = timestamp(raw.updated_at, `${path}.updated_at`);
  if (Date.parse(updatedAt) < Date.parse(createdAt)) {
    return invalid(`${path}.updated_at`, 'must not precede created_at');
  }
  let workspaceId: string | null = null;
  let workspaceBindingRevision: number | null = null;
  if (hasWorkspaceRoutingShape(schemaVersion)) {
    workspaceId =
      raw.workspace_id === null
        ? null
        : canonicalLifecycleId(raw.workspace_id, `${path}.workspace_id`);
    workspaceBindingRevision =
      raw.workspace_binding_revision === null
        ? null
        : lifecycleEpoch(
            raw.workspace_binding_revision,
            `${path}.workspace_binding_revision`,
            false,
          );
    if (
      (workspaceId === null) !== (workspaceBindingRevision === null) ||
      (workspaceBindingRevision !== null &&
        workspaceBindingRevision >= Number.MAX_SAFE_INTEGER)
    ) {
      return invalid(
        `${path}.workspace_binding_revision`,
        'workspace id and binding revision must be both null or both present',
      );
    }
  }
  const attemptId = canonicalLifecycleId(
    raw.attempt_id,
    `${path}.attempt_id`,
  );
  const turnId = canonicalLifecycleId(raw.turn_id, `${path}.turn_id`);
  const parsedAgent =
        agentSchema && raw.agent !== null
      ? (() => {
          const authority = hydrationOptions?.sessionAuthority;
          const nativeJournalRevision = hydrationOptions?.nativeJournalRevision;
          const controllerCAS =
            authority === undefined
              ? undefined
              : (() => {
                  const agentRecord = record(raw.agent, `${path}.agent`);
                  const controllerGeneration = nonNegativeSafeInteger(
                    ownDataValue(
                      agentRecord,
                      'controller_generation',
                      `${path}.agent.controller_generation`,
                    ),
                    `${path}.agent.controller_generation`,
                  );
                  const journalRevision = nonNegativeSafeInteger(
                    raw.journal_revision,
                    `${path}.journal_revision`,
                  );
                  if (
                    nativeJournalRevision !== undefined &&
                    journalRevision !==
                      nativeJournalRevision + 1
                  ) {
                    return invalid(
                      `${path}.journal_revision`,
                      'must match the native committed checkpoint',
                    );
                  }
                  return {
                    schema_version: 1 as const,
                    conversation_id: conversationId,
                    task_id: turnId,
                    attempt_id: attemptId,
                    expected_controller_generation: Math.max(
                      0,
                      controllerGeneration - 1,
                    ),
                    expected_journal_revision:
                      nativeJournalRevision ??
                      Math.max(0, journalRevision - 1),
                    expected_session_generation: authority.generation,
                    expected_session_sha256: authority.session_sha256,
                  };
                })();
          return parsePersistedAgentAttemptJournalV3(raw.agent, `${path}.agent`, {
            taskId: turnId,
            attemptId,
            controllerCAS,
          });
        })()
      : null;
  const migratedCancelled = parsedAgent?.phase === 'cancelled';
  const attempt: TurnAttemptV1 = {
    schemaVersion: TURN_ATTEMPT_SCHEMA_VERSION,
    attemptId,
    turnId,
    status: migratedCancelled ? 'cancelled' : (raw.status as TurnAttemptStatus),
    visibleMessageIds: uniqueStringArray(
      raw.visible_message_ids,
      `${path}.visible_message_ids`,
      MAX_ATTEMPT_VISIBLE_MESSAGES,
    ),
    visibleHistorySha256:
      raw.visible_history_sha256 === null
        ? null
        : sha256(raw.visible_history_sha256, `${path}.visible_history_sha256`),
    attachmentIds: uniqueStringArray(
      raw.attachment_ids,
      `${path}.attachment_ids`,
      MAX_ATTEMPT_ATTACHMENT_IDS,
    ),
    harnessId,
    modelId: raw.model_id,
    thinkingMode: raw.thinking_mode,
    contextDisposition: raw.context_disposition as AttemptContextDisposition,
    contextProjectId:
      raw.context_project_id === null
        ? null
        : isProjectId(raw.context_project_id)
        ? raw.context_project_id
        : invalid(
            `${path}.context_project_id`,
            'must be a valid project id or null',
          ),
    workspaceId,
    workspaceBindingRevision,
    projectContext: parseAttemptProjectContext(
      raw.project_context,
      `${path}.project_context`,
    ),
    activeRound: migratedCancelled ? null : activeRound,
    rounds,
    assistantMessageId:
      migratedCancelled || raw.assistant_message_id === null
        ? null
        : boundedString(
            raw.assistant_message_id,
            `${path}.assistant_message_id`,
            MAX_ID_LENGTH,
          ),
    failureCode: migratedCancelled ? null : failureCode,
    createdAt,
    updatedAt,
    journalRevision: agentSchema
      ? nonNegativeSafeInteger(raw.journal_revision, `${path}.journal_revision`)
      : 0,
    agent: parsedAgent,
  };
  if (
    attempt.journalRevision !== undefined &&
    attempt.agent !== null &&
    attempt.journalRevision < 1
  ) {
    return invalid(
      `${path}.journal_revision`,
      'a non-null Agent journal requires revision at least one',
    );
  }
  if (
    attempt.journalRevision !== undefined &&
    attempt.journalRevision >= Number.MAX_SAFE_INTEGER
  ) {
    return invalid(`${path}.journal_revision`, 'must be a safe integer');
  }
  if (
    (attempt.status === 'sending') !== (attempt.activeRound !== null) ||
    (attempt.status === 'completed') !==
      (attempt.assistantMessageId !== null) ||
    (attempt.status === 'failed') !== (attempt.failureCode !== null) ||
    (attempt.status === 'cancelled' && attempt.failureCode !== null) ||
    (attempt.status !== 'completed' && attempt.assistantMessageId !== null) ||
    ((attempt.status === 'prepared' || attempt.status === 'sending') &&
      attempt.failureCode !== null) ||
    (attempt.rounds.length > 0 && attempt.visibleHistorySha256 === null)
  ) {
    return invalid(path, 'contains an invalid attempt status combination');
  }
  if (
    (attempt.contextDisposition === 'verified') !==
      (attempt.projectContext !== null) ||
    (attempt.contextDisposition === 'unbound' &&
      (attempt.projectContext !== null || attempt.contextProjectId !== null)) ||
    (attempt.contextDisposition === 'explicit_without_context' &&
      (attempt.projectContext !== null || attempt.contextProjectId === null)) ||
    (attempt.contextDisposition === 'verified' &&
      attempt.contextProjectId !== attempt.projectContext?.projectId)
  ) {
    return invalid(
      `${path}.context_disposition`,
      'does not match project_context',
    );
  }
  if (
    attempt.activeRound !== null &&
    attempt.activeRound.roundIndex !== attempt.rounds.length
  ) {
    return invalid(
      `${path}.active_round.round_index`,
      'must equal the completed round count',
    );
  }
  return attempt;
}

function sameStringSequence(
  left: readonly string[],
  right: readonly string[],
): boolean {
  return (
    left.length === right.length &&
    left.every((value, index) => value === right[index])
  );
}

function samePersistedAttemptBinding(
  left: TurnAttemptV1['projectContext'],
  right: TurnAttemptV1['projectContext'],
): boolean {
  return (
    (left === null && right === null) ||
    (left !== null &&
      right !== null &&
      left.schemaVersion === right.schemaVersion &&
      left.runtimeContextId === right.runtimeContextId &&
      left.projectId === right.projectId &&
      left.snapshotId === right.snapshotId &&
      left.snapshotSha256 === right.snapshotSha256 &&
      left.sourceFingerprint === right.sourceFingerprint &&
      left.contextBytes === right.contextBytes &&
      left.consentReceiptId === right.consentReceiptId &&
      left.provider === right.provider &&
      left.policy === right.policy &&
      left.policyVersion === right.policyVersion)
  );
}

function sameFrozenAttempt(left: TurnAttemptV1, right: TurnAttemptV1): boolean {
  return (
    sameStringSequence(left.visibleMessageIds, right.visibleMessageIds) &&
    sameStringSequence(left.attachmentIds, right.attachmentIds) &&
    left.modelId === right.modelId &&
    left.thinkingMode === right.thinkingMode &&
    left.contextDisposition === right.contextDisposition &&
    left.contextProjectId === right.contextProjectId &&
    left.workspaceId === right.workspaceId &&
    left.workspaceBindingRevision === right.workspaceBindingRevision &&
    samePersistedAttemptBinding(left.projectContext, right.projectContext)
  );
}

function legacyConversationRecord(
  value: unknown,
  path: string,
  schemaVersion: PersistedSchemaVersion,
): UnknownRecord {
  if (schemaVersion === LEGACY_CHAT_STATE_SCHEMA_VERSION) {
    return exactRecord(
      value,
      path,
      [
        'id',
        'title',
        'title_source',
        'model_id',
        'thinking_mode',
        'messages',
        'created_at',
        'updated_at',
      ],
      ['thinking_mode'],
    );
  }
  if (
    schemaVersion === OLDER_CHAT_STATE_SCHEMA_VERSION ||
    schemaVersion === ATTACHMENT_CHAT_STATE_SCHEMA_VERSION
  ) {
    return exactRecord(value, path, [
      'id',
      'project_id',
      'title',
      'title_source',
      'model_id',
      'thinking_mode',
      'messages',
      'created_at',
      'updated_at',
    ]);
  }
  if (schemaVersion === WORKSPACE_CHAT_STATE_SCHEMA_VERSION) {
    return exactRecord(value, path, [
      'id',
      'project_id',
      'workspace_id',
      'title',
      'title_source',
      'model_id',
      'thinking_mode',
      'messages',
      'created_at',
      'updated_at',
    ]);
  }
  return exactRecord(value, path, [
    'id',
    'project_id',
    'workspace_id',
    'runtime_context_id',
    'project_context',
    ...(hasWorkspaceRoutingShape(schemaVersion)
      ? ['workspace_binding', 'workspace_bootstrap_state']
      : []),
    ...(hasAgentSchema(schemaVersion) ? ['agent_grants'] : []),
    'title',
    'title_source',
    'model_id',
    'thinking_mode',
    'messages',
    'turns',
    'attempts',
    'created_at',
    'updated_at',
  ]);
}

function parseConversation(
  value: unknown,
  path: string,
  schemaVersion: PersistedSchemaVersion,
  hydrationOptions?: NormalizedChatHydrationOptions,
): Conversation {
  const raw = legacyConversationRecord(value, path, schemaVersion);
  if (raw.title_source !== 'auto' && raw.title_source !== 'manual') {
    return invalid(`${path}.title_source`, 'must be auto or manual');
  }
  if (!isModelId(raw.model_id)) {
    return invalid(`${path}.model_id`, 'is not a supported model');
  }
  const thinkingMode =
    raw.thinking_mode === undefined ? DEFAULT_THINKING_MODE : raw.thinking_mode;
  if (!isConversationThinkingMode(thinkingMode)) {
    return invalid(`${path}.thinking_mode`, 'is not a supported thinking mode');
  }
  const projectId: string | null =
    schemaVersion === LEGACY_CHAT_STATE_SCHEMA_VERSION
      ? null
      : (raw.project_id as string | null);
  if (projectId !== null && !isProjectId(projectId)) {
    return invalid(`${path}.project_id`, 'must be a valid project id or null');
  }
  const legacyWorkspace = hasWorkspaceShape(schemaVersion)
    ? migratedLegacyWorkspaceState(
        raw.workspace_id,
        projectId as string | null,
        `${path}.workspace_id`,
      )
    : {
        workspaceId: null,
        workspaceBinding: null,
        workspaceBootstrapState: 'none' as ConversationWorkspaceBootstrapState,
      };
  const workspaceId = hasWorkspaceRoutingShape(schemaVersion)
    ? raw.workspace_id === null
      ? null
      : typeof raw.workspace_id === 'string'
      ? raw.workspace_id
      : invalid(`${path}.workspace_id`, 'must be a string or null')
    : legacyWorkspace.workspaceId;
  if (
    workspaceId !== null &&
    (!isWorkspaceId(workspaceId) ||
      (hasWorkspaceRoutingShape(schemaVersion) &&
        raw.workspace_binding === null &&
        raw.workspace_bootstrap_state === 'none'))
  ) {
    return invalid(
      `${path}.workspace_id`,
      'must be a valid workspace id or null',
    );
  }
  const workspaceBinding = hasWorkspaceRoutingShape(schemaVersion)
    ? raw.workspace_binding === null
      ? null
      : parseWorkspaceBinding(
          raw.workspace_binding,
          `${path}.workspace_binding`,
        )
    : legacyWorkspace.workspaceBinding;
  const workspaceBootstrapState = hasWorkspaceRoutingShape(schemaVersion)
    ? parseWorkspaceBootstrapState(
        raw.workspace_bootstrap_state,
        `${path}.workspace_bootstrap_state`,
      )
    : legacyWorkspace.workspaceBootstrapState;
  if (
    workspaceBinding !== null &&
    (workspaceId !== workspaceBinding.workspaceId ||
      projectId !== workspaceBinding.projectId ||
      workspaceBootstrapState !== 'none')
  ) {
    return invalid(
      `${path}.workspace_binding`,
      'must match workspace_id/project_id and completed bootstrap state',
    );
  }
  if (
    workspaceBinding === null &&
    workspaceId !== null &&
    workspaceBootstrapState === 'none'
  ) {
    return invalid(
      `${path}.workspace_bootstrap_state`,
      'legacy workspace ids require a pending bootstrap state',
    );
  }

  const createdAt = timestamp(raw.created_at, `${path}.created_at`);
  const updatedAt = timestamp(raw.updated_at, `${path}.updated_at`);
  if (Date.parse(updatedAt) < Date.parse(createdAt)) {
    return invalid(`${path}.updated_at`, 'must not be earlier than created_at');
  }
  const messages = parseMessages(
    raw.messages,
    `${path}.messages`,
    schemaVersion,
  );
  const messageAfterUpdate = messages.find(
    message => Date.parse(message.createdAt) > Date.parse(updatedAt),
  );
  if (messageAfterUpdate !== undefined) {
    return invalid(
      `${path}.updated_at`,
      `must not be earlier than message ${messageAfterUpdate.id}`,
    );
  }

  const runtimeContextId = hasProjectContextShape(schemaVersion)
    ? raw.runtime_context_id === null
      ? null
      : canonicalLifecycleId(
          raw.runtime_context_id,
          `${path}.runtime_context_id`,
        )
    : null;
  const projectContext = hasProjectContextShape(schemaVersion)
    ? raw.project_context === null
      ? null
      : (() => {
          try {
            preflightV6ProjectContext(
              raw.project_context,
              `${path}.project_context`,
            );
            return validateV6ProjectContext(
              hydrateProjectContextState(raw.project_context),
              raw.project_context,
              `${path}.project_context`,
            );
          } catch {
            return invalid(
              `${path}.project_context`,
              'violates the v6 context contract',
            );
          }
        })()
    : projectId === null
    ? null
    : createProjectContextState(projectId as string);
  if (
    (projectId === null) !== (projectContext === null) ||
    (projectContext !== null && projectContext.projectId !== projectId)
  ) {
    return invalid(
      `${path}.project_context`,
      'must correspond exactly to project_id',
    );
  }
  if (
    projectContext !== null &&
    isProjectContextSendable(projectContext) &&
    (runtimeContextId === null ||
      projectContext.snapshot?.model !== raw.model_id)
  ) {
    return invalid(
      `${path}.project_context`,
      'a sendable context must match runtime_context_id and model_id',
    );
  }
  const turnsRaw = hasProjectContextShape(schemaVersion)
    ? array(raw.turns, `${path}.turns`, MAX_TURNS_PER_CONVERSATION)
    : [];
  if (turnsRaw.length > MAX_TURNS_PER_CONVERSATION) {
    return invalid(`${path}.turns`, 'contains too many turns');
  }
  const turns = turnsRaw.map((entry, index) =>
    parseTurn(entry, `${path}.turns[${index}]`),
  );
  const conversationId = boundedString(raw.id, `${path}.id`, MAX_ID_LENGTH);
  const attemptsRaw = hasProjectContextShape(schemaVersion)
    ? array(raw.attempts, `${path}.attempts`, MAX_ATTEMPTS_PER_CONVERSATION)
    : [];
  if (attemptsRaw.length > MAX_ATTEMPTS_PER_CONVERSATION) {
    return invalid(`${path}.attempts`, 'contains too many attempts');
  }
  const attempts = attemptsRaw.map((entry, index) =>
    parseAttempt(
      entry,
      `${path}.attempts[${index}]`,
      schemaVersion,
      conversationId,
      hydrationOptions,
    ),
  );
  const agentGrants = hasAgentSchema(schemaVersion)
    ? array(
        raw.agent_grants,
        `${path}.agent_grants`,
        MAX_AGENT_GRANTS_PER_CONVERSATION,
      ).map((entry, index) =>
        parseAgentGrant(entry, `${path}.agent_grants[${index}]`),
      )
    : [];
  const grantIds = new Set<string>();
  agentGrants.forEach((grant, index) => {
    if (grantIds.has(grant.grant_id)) {
      invalid(`${path}.agent_grants[${index}].grant_id`, 'must be unique');
    }
    grantIds.add(grant.grant_id);
    if (grant.conversation_id !== raw.id) {
      invalid(
        `${path}.agent_grants[${index}].conversation_id`,
        'must match the containing conversation',
      );
    }
    if (grant.project_id !== raw.project_id) {
      invalid(
        `${path}.agent_grants[${index}].project_id`,
        'must match the containing project',
      );
    }
    if (
      workspaceBinding === null ||
      grant.workspace_id !== workspaceId ||
      grant.binding_revision !== workspaceBinding.bindingRevision ||
      grant.project_id !== projectId
    ) {
      invalid(
        `${path}.agent_grants[${index}]`,
        'must match the containing workspace binding',
      );
    }
    if (
      !attempts.some(
        attempt =>
          attempt.attemptId === grant.issued_for.attempt_id &&
          attempt.turnId === grant.issued_for.task_id,
      )
    ) {
      invalid(
        `${path}.agent_grants[${index}].issued_for`,
        'must reference an attempt for this conversation turn',
      );
    }
  });
  if (hasAgentSchema(schemaVersion)) {
    const grantsById = new Map(
      agentGrants.map(grant => [grant.grant_id, grant]),
    );
    attempts.forEach((attempt, index) => {
      const journal = attempt.agent;
      const revision = attempt.journalRevision ?? 0;
      if (journal === null || journal === undefined) {
        if (revision !== 0) {
          invalid(
            `${path}.attempts[${index}].journal_revision`,
            'agent:null requires journal_revision zero',
          );
        }
        return;
      }
      if (
        revision < 1 ||
        journal.root.workspace_id !== workspaceId ||
        journal.root.workspace_binding_revision !==
          (workspaceBinding?.bindingRevision ?? null) ||
        journal.root.project_id !== projectId ||
        journal.round_index > attempt.rounds.length ||
        journal.round_index < Math.max(0, attempt.rounds.length - 1)
      ) {
        invalid(
          `${path}.attempts[${index}].agent`,
          'must match the containing attempt workspace/root and rounds',
        );
      }
      if (
        attempt.status === 'failed' &&
        attempt.failureCode === 'E_ATTEMPT_INTERRUPTED'
      ) {
        // A stale attempt interrupted at hydration keeps its journal phase as
        // forensic evidence of where its dead writer stopped.  The phase can
        // no longer be interpreted as a live authority, so the phase/status
        // cross-checks below apply only to live or normally terminalized
        // attempts.
        return;
      }
      const lineage = journal.round_lineage;
      if (
        journal.phase === 'round_in_flight' &&
        (attempt.activeRound === null ||
          lineage === null ||
          attempt.activeRound.roundId !== lineage.round_id ||
          attempt.activeRound.roundIndex !== lineage.round_index)
      ) {
        invalid(
          `${path}.attempts[${index}].agent`,
          'round_in_flight must match the outer active round',
        );
      }
      if (journal.phase !== 'round_in_flight' && attempt.activeRound !== null) {
        invalid(
          `${path}.attempts[${index}].agent`,
          'non-in-flight Agent phases cannot retain an active round',
        );
      }
      if (journal.phase === 'round_in_flight' && attempt.status !== 'sending') {
        invalid(
          `${path}.attempts[${index}].status`,
          'round_in_flight Agent journals require a sending attempt',
        );
      }
      if (journal.phase === 'cancelled' && attempt.status !== 'cancelled') {
        invalid(
          `${path}.attempts[${index}].status`,
          'cancelled Agent journals require a cancelled attempt',
        );
      }
      if (
        (journal.phase === 'failed' ||
          journal.phase === 'unknown' ||
          journal.phase === 'ambiguous') &&
        attempt.status !== 'failed'
      ) {
        invalid(
          `${path}.attempts[${index}].status`,
          'failed Agent journals require a failed attempt',
        );
      }
      // A failed journal may now carry the cause the round itself reported,
      // so this no longer names the handful of codes JavaScript used to
      // invent. What it still holds is the part that means something: the
      // two completion codes stay coupled to the finish reason that proves
      // them, and the codes belonging to the other two failed phases are
      // refused, so `failed`, `unknown` and `ambiguous` stay tellable apart
      // on the way back in.
      if (
        journal.phase === 'failed' &&
        (attempt.failureCode === null ||
          attempt.failureCode === 'E_AGENT_CONFLICT' ||
          attempt.failureCode === 'E_AGENT_EXECUTION_AMBIGUOUS' ||
          (attempt.failureCode === 'E_COMPLETION_LENGTH' &&
            attempt.rounds.at(-1)?.finishReason !== 'length') ||
          (attempt.failureCode === 'E_COMPLETION_CONTENT_FILTER' &&
            attempt.rounds.at(-1)?.finishReason !== 'content_filter'))
      ) {
        invalid(
          `${path}.attempts[${index}].failure_code`,
          'failed Agent journals require a cause that is not another phase\'s',
        );
      }
      if (
        journal.phase === 'unknown' &&
        attempt.failureCode !== 'E_AGENT_CONFLICT'
      ) {
        invalid(
          `${path}.attempts[${index}].failure_code`,
          'unknown Agent journals require the conflict failure code',
        );
      }
      // An ambiguous journal carries whichever uncertainty it actually has --
      // a round that may have reached the service, or a tool that may have
      // run -- and `agentAmbiguityCode` says which from the batch. Sessions
      // written before that distinction existed recorded every ambiguity as
      // an execution one, and they stay readable: that older code is still
      // accepted here. The reverse is not: a journal whose batch holds an
      // ambiguous receipt must keep saying a tool may have run, because that
      // is the warning that sends the person to check their files.
      if (
        journal.phase === 'ambiguous' &&
        attempt.failureCode !== 'E_AGENT_EXECUTION_AMBIGUOUS' &&
        attempt.failureCode !== agentAmbiguityCode(journal)
      ) {
        invalid(
          `${path}.attempts[${index}].failure_code`,
          'ambiguous Agent journals require the ambiguity failure code',
        );
      }
      if (
        journal.phase !== 'round_in_flight' &&
        journal.phase !== 'cancelled' &&
        journal.phase !== 'failed' &&
        journal.phase !== 'unknown' &&
        journal.phase !== 'ambiguous' &&
        attempt.status !== 'prepared' &&
        attempt.status !== 'completed'
      ) {
        invalid(
          `${path}.attempts[${index}].status`,
          'active Agent checkpoints require a prepared or completed attempt',
        );
      }
      journal.batch.forEach((call, callIndex) => {
        if (!hasLiveConversationGrant(call, journal, conversationId, agentGrants))
          invalid(`${path}.attempts[${index}].agent.batch[${callIndex}].approval_reference`, 'must reference a matching live grant for this tool family');
      });
      journal.frozen_grant_ids.forEach((grantId, grantIndex) => {
        const grant = grantsById.get(grantId);
        if (
          grant === undefined ||
          grant.workspace_id !== journal.root.workspace_id ||
          grant.project_id !== journal.root.project_id ||
          grant.binding_revision !== journal.root.workspace_binding_revision ||
          grant.registry_version !== journal.tool_registry_version ||
          grant.policy_version !== journal.policy.policy_version ||
          grant.root_fingerprint_sha256 !==
            journal.root.root_fingerprint_sha256 ||
          !journal.root.capabilities.includes(grant.tool_family)
        ) {
          invalid(
            `${path}.attempts[${index}].agent.frozen_grant_ids[${grantIndex}]`,
            'must reference a matching live grant',
          );
        }
      });
    });
  }
  if (
    workspaceBootstrapState === 'none' &&
    projectContext !== null &&
    isProjectContextSendable(projectContext) &&
    workspaceBinding === null
  ) {
    return invalid(
      `${path}.workspace_binding`,
      'a sendable project context requires a workspace binding',
    );
  }
  for (const [attemptIndexValue, attempt] of attempts.entries()) {
    const hasWorkspace =
      attempt.workspaceId !== null || attempt.workspaceBindingRevision !== null;
    if (
      (attempt.status === 'prepared' || attempt.status === 'sending') &&
      workspaceBootstrapState === 'none' &&
      projectId !== null &&
      (workspaceBinding === null ||
        !hasWorkspace ||
        attempt.workspaceId !== workspaceBinding.workspaceId ||
        attempt.workspaceBindingRevision !== workspaceBinding.bindingRevision ||
        attempt.contextProjectId !== workspaceBinding.projectId)
    ) {
      return invalid(
        `${path}.attempts[${attemptIndexValue}].workspace_binding_revision`,
        'a live attempt must freeze the conversation workspace binding',
      );
    }
    if (
      hasWorkspace &&
      (workspaceBinding === null ||
        attempt.workspaceId !== workspaceBinding.workspaceId ||
        attempt.workspaceBindingRevision !== workspaceBinding.bindingRevision)
    ) {
      return invalid(
        `${path}.attempts[${attemptIndexValue}].workspace_id`,
        'must match the conversation workspace binding',
      );
    }
  }
  const messageById = new Map(messages.map(message => [message.id, message]));
  const messageIndexById = new Map(
    messages.map((message, index) => [message.id, index]),
  );
  const attemptById = new Map<string, TurnAttemptV1>();
  const attemptIndexById = new Map<string, number>();
  const referencedAttempts = new Set<string>();
  const assistantAttemptReferences = new Set<string>();
  const turnIds = new Set<string>();
  let turnAttemptReferences = 0;
  let previousTurnMessageIndex = -1;
  let attemptMessageReferences = 0;
  attempts.forEach((attempt, index) => {
    attemptMessageReferences += attempt.visibleMessageIds.length;
    if (attemptMessageReferences > MAX_ATTEMPT_MESSAGE_REFERENCES) {
      invalid(
        `${path}.attempts[${index}].visible_message_ids`,
        'exceeds the aggregate visible-message reference limit',
      );
    }
    if (attemptById.has(attempt.attemptId)) {
      invalid(`${path}.attempts[${index}].attempt_id`, 'must be unique');
    }
    attemptById.set(attempt.attemptId, attempt);
    attemptIndexById.set(attempt.attemptId, index);
  });
  if (
    attempts.filter(
      attempt => attempt.status === 'prepared' || attempt.status === 'sending',
    ).length > 1
  ) {
    return invalid(`${path}.attempts`, 'must contain at most one live attempt');
  }
  turns.forEach((turn, index) => {
    if (turnIds.has(turn.turnId)) {
      invalid(`${path}.turns[${index}].turn_id`, 'must be unique');
    }
    turnIds.add(turn.turnId);
    const userMessage = messageById.get(turn.userMessageId);
    const turnMessageIndex = messageIndexById.get(turn.userMessageId);
    if (userMessage?.role !== 'user') {
      invalid(
        `${path}.turns[${index}].user_message_id`,
        'must reference a user message',
      );
    }
    if (
      turnMessageIndex === undefined ||
      turnMessageIndex <= previousTurnMessageIndex
    ) {
      invalid(
        `${path}.turns[${index}].user_message_id`,
        'turns must follow visible message order',
      );
    }
    previousTurnMessageIndex = turnMessageIndex;
    if (turn.createdAt !== userMessage.createdAt) {
      invalid(
        `${path}.turns[${index}].created_at`,
        'must match the user message timestamp',
      );
    }
    let completedAttempts = 0;
    let knownVisibleHistorySha256: string | null = null;
    turn.attemptIds.forEach((attemptId, attemptIndexValue) => {
      turnAttemptReferences += 1;
      if (turnAttemptReferences > MAX_ATTEMPTS_PER_CONVERSATION) {
        invalid(
          `${path}.turns[${index}].attempt_ids`,
          'exceeds the aggregate attempt reference limit',
        );
      }
      const attempt = attemptById.get(attemptId);
      const persistedAttemptIndex = attemptIndexById.get(attemptId);
      if (
        attempt === undefined ||
        persistedAttemptIndex === undefined ||
        attempt.turnId !== turn.turnId
      ) {
        invalid(
          `${path}.turns[${index}].attempt_ids[${attemptIndexValue}]`,
          'must reference an attempt for this turn',
        );
      }
      if (referencedAttempts.has(attemptId)) {
        invalid(
          `${path}.turns[${index}].attempt_ids[${attemptIndexValue}]`,
          'must be referenced exactly once',
        );
      }
      referencedAttempts.add(attemptId);
      if (attemptIndexValue === 0 && attempt.createdAt !== turn.createdAt) {
        invalid(
          `${path}.turns[${index}].attempt_ids[0]`,
          'the initial attempt timestamp must match the turn',
        );
      }
      if (
        attemptIndexValue < turn.attemptIds.length - 1 &&
        attempt.status !== 'failed' &&
        attempt.status !== 'cancelled'
      ) {
        invalid(
          `${path}.turns[${index}].attempt_ids[${attemptIndexValue}]`,
          'non-final attempts must be retryable terminal states',
        );
      }
      const firstAttempt = attemptById.get(turn.attemptIds[0]!);
      if (
        attemptIndexValue > 0 &&
        (firstAttempt === undefined ||
          !sameFrozenAttempt(firstAttempt, attempt))
      ) {
        invalid(
          `${path}.turns[${index}].attempt_ids[${attemptIndexValue}]`,
          'retry attempts must preserve the frozen request',
        );
      }
      if (attempt.visibleHistorySha256 === null) {
        if (knownVisibleHistorySha256 !== null) {
          invalid(
            `${path}.attempts[${persistedAttemptIndex}].visible_history_sha256`,
            'must retain the first verified visible-history digest',
          );
        }
      } else if (knownVisibleHistorySha256 === null) {
        knownVisibleHistorySha256 = attempt.visibleHistorySha256;
      } else if (attempt.visibleHistorySha256 !== knownVisibleHistorySha256) {
        invalid(
          `${path}.attempts[${persistedAttemptIndex}].visible_history_sha256`,
          'must match the first verified visible-history digest',
        );
      }
      if (
        attempt.rounds.length === 0 &&
        attempt.visibleHistorySha256 !== null &&
        (attempt.agent === undefined || attempt.agent === null)
      ) {
        const hasDigestProvenance =
          attemptIndexValue > 0 &&
          turn.attemptIds
            .slice(0, attemptIndexValue)
            .some(previousAttemptId => {
              const previous = attemptById.get(previousAttemptId);
              return (
                previous !== undefined &&
                // An agent attempt's rounds live in its journal, not in
                // `rounds`: the lineage there is the same receipt this rule
                // asks for. Without it a turn could never be asked again
                // after an agent attempt that had started a round, because
                // the digest it froze would have no provenance.
                (previous.rounds.length > 0 ||
                  (previous.agent !== undefined &&
                    previous.agent !== null &&
                    previous.agent.round_lineage !== null)) &&
                previous.visibleHistorySha256 ===
                  attempt.visibleHistorySha256 &&
                sameFrozenAttempt(previous, attempt)
              );
            });
        if (!hasDigestProvenance) {
          invalid(
            `${path}.attempts[${persistedAttemptIndex}].visible_history_sha256`,
            'requires an earlier correlated round receipt',
          );
        }
      }
      if (attempt.status === 'completed') {
        completedAttempts += 1;
        if (
          completedAttempts > 1 ||
          attempt.assistantMessageId === null ||
          assistantAttemptReferences.has(attempt.assistantMessageId)
        ) {
          invalid(
            `${path}.turns[${index}].attempt_ids[${attemptIndexValue}]`,
            'must have at most one uniquely referenced completion',
          );
        }
        assistantAttemptReferences.add(attempt.assistantMessageId);
      }
      const userIndex = messageIndexById.get(turn.userMessageId);
      if (userIndex === undefined) {
        invalid(
          `${path}.turns[${index}].user_message_id`,
          'must reference a visible message',
        );
      }
      const expectedWindowStart = Math.max(
        0,
        userIndex + 1 - MAX_ATTEMPT_VISIBLE_MESSAGES,
      );
      const expectedWindowLength = userIndex + 1 - expectedWindowStart;
      if (
        attempt.visibleMessageIds.length !== expectedWindowLength ||
        !attempt.visibleMessageIds.every(
          (messageId, visibleIndex) =>
            messageId === messages[expectedWindowStart + visibleIndex]?.id,
        )
      ) {
        invalid(
          `${path}.attempts[${persistedAttemptIndex}].visible_message_ids`,
          'must freeze the contiguous visible-message window',
        );
      }
      const expectedAttachments: string[] = [];
      const seenAttachmentIds = new Set<string>();
      let visibleAttachmentCount = 0;
      let visibleAttachmentBytes = 0;
      attempt.visibleMessageIds.forEach(messageId => {
        messageById.get(messageId)?.attachments.forEach(attachment => {
          visibleAttachmentCount += 1;
          visibleAttachmentBytes += attachment.size;
          if (seenAttachmentIds.has(attachment.id)) return;
          seenAttachmentIds.add(attachment.id);
          expectedAttachments.push(attachment.id);
        });
      });
      if (
        visibleAttachmentCount > MAX_ATTEMPT_ATTACHMENT_IDS ||
        visibleAttachmentBytes > MAX_TOTAL_ATTACHMENT_SIZE ||
        attempt.attachmentIds.length !== expectedAttachments.length ||
        !attempt.attachmentIds.every(
          (attachmentId, attachmentIndex) =>
            attachmentId === expectedAttachments[attachmentIndex],
        )
      ) {
        invalid(
          `${path}.attempts[${persistedAttemptIndex}].attachment_ids`,
          'must match the user message attachments',
        );
      }
    });
  });
  if (referencedAttempts.size !== attempts.length) {
    return invalid(`${path}.attempts`, 'every attempt must belong to one turn');
  }
  attempts.forEach((attempt, index) => {
    attempt.rounds.forEach((receipt, roundIndex) => {
      const binding = attempt.projectContext;
      const projectReceipt = receipt.projectContextReceipt;
      if (
        receipt.turnId !== attempt.turnId ||
        receipt.attemptId !== attempt.attemptId ||
        receipt.roundIndex !== roundIndex ||
        receipt.requestedModel !== attempt.modelId ||
        receipt.model !== attempt.modelId ||
        receipt.thinkingMode !== attempt.thinkingMode ||
        ((attempt.agent === undefined || attempt.agent === null) &&
          receipt.visibleHistorySha256 !== attempt.visibleHistorySha256) ||
        (binding === null
          ? receipt.transportSchemaVersion !== 2 || projectReceipt !== null
          : receipt.transportSchemaVersion !== 3 ||
            projectReceipt === null ||
            projectReceipt.snapshot_id !== binding.snapshotId ||
            projectReceipt.snapshot_sha256 !== binding.snapshotSha256 ||
            projectReceipt.source_fingerprint !== binding.sourceFingerprint ||
            projectReceipt.context_bytes !== binding.contextBytes)
      ) {
        invalid(
          `${path}.attempts[${index}].rounds[${roundIndex}]`,
          'does not correlate with its attempt',
        );
      }
      if (
        roundIndex < attempt.rounds.length - 1 &&
        receipt.finishReason !== 'tool_calls'
      ) {
        invalid(
          `${path}.attempts[${index}].rounds[${roundIndex}].finish_reason`,
          'only tool_calls may be followed by another round',
        );
      }
    });
    if (
      attempt.status === 'completed' &&
      (attempt.rounds.length === 0 ||
        attempt.rounds[attempt.rounds.length - 1]?.finishReason ===
          'tool_calls')
    ) {
      invalid(
        `${path}.attempts[${index}].status`,
        'completed requires a terminal round receipt',
      );
    }
    if (
      attempt.projectContext !== null &&
      (runtimeContextId === null ||
        attempt.projectContext.runtimeContextId !== runtimeContextId)
    ) {
      invalid(
        `${path}.attempts[${index}].project_context.runtime_context_id`,
        'must match the conversation runtime context',
      );
    }
    if (
      (attempt.status === 'prepared' || attempt.status === 'sending') &&
      attempt.contextProjectId !== projectId
    ) {
      invalid(
        `${path}.attempts[${index}].context_project_id`,
        'a live attempt must match the conversation project binding',
      );
    }
    if (attempt.assistantMessageId !== null) {
      const assistant = messageById.get(attempt.assistantMessageId);
      const attemptTurn = turns.find(turn => turn.turnId === attempt.turnId);
      const userMessageIndex =
        attemptTurn === undefined
          ? undefined
          : messageIndexById.get(attemptTurn.userMessageId);
      const assistantMessageIndex = messageIndexById.get(
        attempt.assistantMessageId,
      );
      if (assistant?.role !== 'assistant') {
        invalid(
          `${path}.attempts[${index}].assistant_message_id`,
          'must reference an assistant message',
        );
      }
      if (
        userMessageIndex === undefined ||
        assistantMessageIndex === undefined ||
        assistantMessageIndex <= userMessageIndex ||
        Date.parse(assistant.createdAt) < Date.parse(attempt.createdAt)
      ) {
        invalid(
          `${path}.attempts[${index}].assistant_message_id`,
          'must follow the user turn',
        );
      }
      const lastReceipt = attempt.rounds[attempt.rounds.length - 1];
      if (
        lastReceipt === undefined ||
        assistant.metadata?.modelId !== lastReceipt.model ||
        assistant.metadata.latencyMs !== lastReceipt.latencyMs ||
        assistant.metadata.finishReason !== lastReceipt.finishReason
      ) {
        invalid(
          `${path}.attempts[${index}].assistant_message_id`,
          'assistant metadata must match the terminal round receipt',
        );
      }
    }
  });

  return {
    id: conversationId,
    projectId: projectId as string | null,
    workspaceId,
    workspaceBinding,
    workspaceBootstrapState,
    runtimeContextId,
    projectContext,
    title: boundedString(raw.title, `${path}.title`, MAX_TITLE_LENGTH),
    titleSource: raw.title_source,
    modelId: raw.model_id,
    thinkingMode,
    messages,
    turns,
    attempts,
    createdAt,
    updatedAt,
    agentGrants,
  };
}

function messageMetadataEqual(
  left: ChatMessageMetadata | undefined,
  right: ChatMessageMetadata | undefined,
): boolean {
  return (
    left?.modelId === right?.modelId &&
    left?.latencyMs === right?.latencyMs &&
    left?.finishReason === right?.finishReason &&
    left?.reasoning === right?.reasoning
  );
}

function attachmentsEqual(
  left: readonly ChatAttachment[],
  right: readonly ChatAttachment[],
): boolean {
  return (
    left.length === right.length &&
    left.every((attachment, index) => {
      const candidate = right[index];
      return (
        candidate !== undefined &&
        attachment.schema_version === candidate.schema_version &&
        attachment.id === candidate.id &&
        attachment.kind === candidate.kind &&
        attachment.name === candidate.name &&
        attachment.mime_type === candidate.mime_type &&
        attachment.size === candidate.size
      );
    })
  );
}

function messagesEqual(
  left: readonly ChatMessage[],
  right: readonly ChatMessage[],
): boolean {
  return (
    left.length === right.length &&
    left.every((message, index) => {
      const candidate = right[index];
      return (
        candidate !== undefined &&
        message.id === candidate.id &&
        message.role === candidate.role &&
        message.text === candidate.text &&
        message.createdAt === candidate.createdAt &&
        attachmentsEqual(message.attachments, candidate.attachments) &&
        messageMetadataEqual(message.metadata, candidate.metadata)
      );
    })
  );
}

function toPersistedAttachment(
  attachment: ChatAttachment,
): PersistedChatAttachmentV1 {
  return {
    schema_version: attachment.schema_version,
    id: attachment.id,
    kind: attachment.kind,
    name: attachment.name,
    mime_type: attachment.mime_type,
    size: attachment.size,
  };
}

function toPersistedMessage(message: ChatMessage): PersistedChatMessageV4 {
  const sourceMetadata = message.metadata;
  const metadata =
    sourceMetadata === undefined
      ? undefined
      : {
          ...(sourceMetadata.modelId === undefined
            ? {}
            : { model_id: sourceMetadata.modelId }),
          ...(sourceMetadata.latencyMs === undefined
            ? {}
            : { latency_ms: sourceMetadata.latencyMs }),
          ...(sourceMetadata.finishReason === undefined
            ? {}
            : { finish_reason: sourceMetadata.finishReason }),
          ...(sourceMetadata.reasoning === undefined
            ? {}
            : { reasoning: sourceMetadata.reasoning }),
        };
  return {
    id: message.id,
    role: message.role,
    text: message.text,
    created_at: message.createdAt,
    attachments: message.attachments.map(toPersistedAttachment),
    ...(metadata === undefined ? {} : { metadata }),
  };
}

function toPersistedTurn(
  turn: ConversationTurnV1,
): PersistedConversationTurnV1 {
  return {
    schema_version: turn.schemaVersion,
    turn_id: turn.turnId,
    user_message_id: turn.userMessageId,
    attempt_ids: [...turn.attemptIds],
    created_at: turn.createdAt,
  };
}

function toPersistedRoundReceipt(
  receipt: CompletionRoundReceiptV1,
): PersistedCompletionRoundReceiptV1 {
  return {
    schema_version: receipt.schemaVersion,
    transport_schema_version: receipt.transportSchemaVersion,
    harness_id: receipt.harnessId,
    ...(receipt.providerConfiguration === undefined ? {} : { provider_configuration: receipt.providerConfiguration }),
    turn_id: receipt.turnId,
    attempt_id: receipt.attemptId,
    round_id: receipt.roundId,
    round_index: receipt.roundIndex,
    provider_request_id: receipt.providerRequestId,
    provider_response_id: receipt.providerResponseId,
    requested_model: receipt.requestedModel,
    model: receipt.model,
    thinking_mode: receipt.thinkingMode,
    finish_reason: receipt.finishReason,
    latency_ms: receipt.latencyMs,
    visible_history_sha256: receipt.visibleHistorySha256,
    model_input_sha256: receipt.modelInputSha256,
    request_body_sha256: receipt.requestBodySha256,
    project_context_receipt: receipt.projectContextReceipt,
  };
}

function toPersistedAgentJournalV3(
  journal: PersistedAgentAttemptJournalV3,
): PersistedAgentAttemptJournalV3 {
  if (journal.schema_version !== AGENT_ATTEMPT_JOURNAL_SCHEMA_VERSION_V3) {
    throw new ChatStateValidationError(
      '$.conversations.attempts.agent',
      'schema-2 Agent journals require bootstrap hydration before serialization',
    );
  }
  return {
    schema_version: AGENT_ATTEMPT_JOURNAL_SCHEMA_VERSION_V3,
    phase: journal.phase,
    controller_generation: journal.controller_generation,
    policy: { ...journal.policy },
    root: { ...journal.root, capabilities: [...journal.root.capabilities] },
    tool_registry_version: journal.tool_registry_version,
    toolset_sha256: journal.toolset_sha256,
    transcript: { ...journal.transcript },
    round_index: journal.round_index,
    round_lineage:
      journal.round_lineage === null ? null : { ...journal.round_lineage },
    call_index: journal.call_index,
    batch: journal.batch.map(call => {
      if (call.schema_version !== AGENT_CALL_JOURNAL_SCHEMA_VERSION_V3) {
        throw new ChatStateValidationError(
          '$.conversations.attempts.agent.batch',
          'schema-2 Agent calls require bootstrap hydration before serialization',
        );
      }
      return {
        ...call,
        receipt: call.receipt === null ? null : { ...call.receipt },
      };
    }),
    frozen_grant_ids: [...journal.frozen_grant_ids],
    reserved_write_bytes: journal.reserved_write_bytes,
    updated_at: journal.updated_at,
  };
}

function toPersistedAttempt(attempt: TurnAttemptV1): PersistedTurnAttemptV3 {
  const hasAgentJournal = attempt.agent !== undefined && attempt.agent !== null;
  const journalRevision = attempt.journalRevision ?? 0;
  if (
    !Number.isSafeInteger(journalRevision) ||
    Object.is(journalRevision, -0) ||
    journalRevision < (hasAgentJournal ? 1 : 0) ||
    (hasAgentJournal && journalRevision >= Number.MAX_SAFE_INTEGER) ||
    (!hasAgentJournal && journalRevision !== 0)
  ) {
    throw new ChatStateValidationError(
      '$.conversations.attempts.journal_revision',
      'invalid journal revision cannot be promoted during serialization',
    );
  }
  const agent =
    attempt.agent === undefined || attempt.agent === null
      ? null
      : toPersistedAgentJournalV3(attempt.agent);
  return {
    schema_version: PERSISTED_TURN_ATTEMPT_SCHEMA_VERSION_V3,
    attempt_id: attempt.attemptId,
    turn_id: attempt.turnId,
    status: attempt.status,
    harness_id: attempt.harnessId,
    visible_message_ids: [...attempt.visibleMessageIds],
    visible_history_sha256: attempt.visibleHistorySha256,
    attachment_ids: [...attempt.attachmentIds],
    model_id: attempt.modelId,
    thinking_mode: attempt.thinkingMode,
    context_disposition: attempt.contextDisposition,
    context_project_id: attempt.contextProjectId,
    workspace_id: attempt.workspaceId,
    workspace_binding_revision: attempt.workspaceBindingRevision,
    project_context:
      attempt.projectContext === null
        ? null
        : {
            schema_version: attempt.projectContext.schemaVersion,
            runtime_context_id: attempt.projectContext.runtimeContextId,
            project_id: attempt.projectContext.projectId,
            snapshot_id: attempt.projectContext.snapshotId,
            snapshot_sha256: attempt.projectContext.snapshotSha256,
            source_fingerprint: attempt.projectContext.sourceFingerprint,
            context_bytes: attempt.projectContext.contextBytes,
            consent_receipt_id: attempt.projectContext.consentReceiptId,
            provider: attempt.projectContext.provider,
            policy: attempt.projectContext.policy,
            policy_version: attempt.projectContext.policyVersion,
          },
    active_round:
      attempt.activeRound === null
        ? null
        : {
            round_id: attempt.activeRound.roundId,
            round_index: attempt.activeRound.roundIndex,
          },
    rounds: attempt.rounds.map(toPersistedRoundReceipt),
    assistant_message_id: attempt.assistantMessageId,
    failure_code: attempt.failureCode,
    created_at: attempt.createdAt,
    updated_at: attempt.updatedAt,
    journal_revision: hasAgentJournal ? journalRevision : 0,
    agent,
  };
}

function toPersistedDestructiveTransition(
  transition: ProjectContextDestructiveTransitionV1,
): NonNullable<PersistedChatStateV8['project_context_destructive_transition']> {
  return {
    schema_version: transition.schemaVersion,
    lifecycle_id: transition.lifecycleId,
    epoch: transition.epoch,
    action: transition.action,
    phase: transition.phase,
    conversation_id: transition.conversationId,
    source_project_id: transition.sourceProjectId,
    source_runtime_context_id: transition.sourceRuntimeContextId,
    source_model_id: transition.sourceModelId,
    snapshot_id: transition.snapshotId,
    snapshot_sha256: transition.snapshotSha256,
    consent_receipt_id: transition.consentReceiptId,
    target_project_id: transition.targetProjectId,
    created_at: transition.createdAt,
    updated_at: transition.updatedAt,
  };
}

function toPersistedWorkspaceBinding(
  binding: ConversationWorkspaceBindingV1 | null,
): PersistedConversationWorkspaceBindingV1 | null {
  return binding === null
    ? null
    : {
        schema_version: binding.schemaVersion,
        workspace_id: binding.workspaceId,
        binding_revision: binding.bindingRevision,
        project_id: binding.projectId,
      };
}

function toPersistedWorkspaceOutboxEntry(
  entry: WorkspaceAuthorityOutboxV1,
): PersistedWorkspaceAuthorityOutboxV1 {
  return {
    schema_version: entry.schemaVersion,
    operation_id: entry.operationId,
    action: entry.action,
    workspace_id: entry.workspaceId,
    binding_revision: entry.bindingRevision,
    clearance_receipt_id: entry.clearanceReceiptId,
    created_at: entry.createdAt,
  };
}

function toPersistedAgentGrant(
  grant: AgentConversationGrantV2,
): AgentConversationGrantV2 {
  return {
    schema_version: grant.schema_version,
    grant_id: grant.grant_id,
    conversation_id: grant.conversation_id,
    workspace_id: grant.workspace_id,
    project_id: grant.project_id,
    binding_revision: grant.binding_revision,
    root_fingerprint_sha256: grant.root_fingerprint_sha256,
    tool_family: grant.tool_family,
    registry_version: grant.registry_version,
    policy_version: grant.policy_version,
    issued_for: { ...grant.issued_for },
    created_at: grant.created_at,
  };
}

function toPersistedCleanupEntry(
  entry: AgentTranscriptCleanupV1,
): AgentTranscriptCleanupV1 {
  return { ...entry };
}

function defaultPersistedPreferences(): PersistedAppPreferencesV1 {
  return JSON.parse(
    serializeAppPreferences(DEFAULT_APP_PREFERENCES),
  ) as PersistedAppPreferencesV1;
}

function canonicalPersistedPreferences(
  value: PersistedAppPreferencesV1 | undefined,
): PersistedAppPreferencesV1 {
  if (value === undefined) return defaultPersistedPreferences();
  const parsed = hydrateAppPreferences(value);
  return JSON.parse(
    serializeAppPreferences(parsed),
  ) as PersistedAppPreferencesV1;
}

function toPersistedState(state: ChatState): PersistedSessionSnapshotV9 {
  const conversationOrder = orderConversationIds(state.conversations);
  const conversations = conversationOrder.map(id => {
    const conversation = state.conversations[id];
    if (conversation === undefined) {
      return invalid(`state.conversations.${id}`, 'is missing');
    }
    return {
      id: conversation.id,
      project_id: conversation.projectId,
      workspace_id: conversation.workspaceId,
      workspace_binding: toPersistedWorkspaceBinding(
        conversation.workspaceBinding ?? null,
      ),
      workspace_bootstrap_state: conversation.workspaceBootstrapState ?? 'none',
      runtime_context_id: conversation.runtimeContextId,
      project_context:
        conversation.projectContext === null
          ? null
          : (JSON.parse(
              serializeProjectContextState(conversation.projectContext),
            ) as PersistedChatStateV8['conversations'][number]['project_context']),
      title: conversation.title,
      title_source: conversation.titleSource,
      model_id: conversation.modelId,
      thinking_mode: conversation.thinkingMode,
      messages: conversation.messages.map(toPersistedMessage),
      turns: conversation.turns.map(toPersistedTurn),
      attempts: conversation.attempts.map(toPersistedAttempt),
      created_at: conversation.createdAt,
      updated_at: conversation.updatedAt,
      agent_grants: (
        conversation.agentGrants ??
        conversation.agent_grants ??
        []
      ).map(toPersistedAgentGrant),
    };
  });
  return {
    schema_version: CHAT_STATE_SCHEMA_VERSION,
    workspace_authority_outbox: (state.workspaceAuthorityOutbox ?? []).map(
      toPersistedWorkspaceOutboxEntry,
    ),
    agent_transcript_cleanup_outbox: (
      state.agentTranscriptCleanupOutbox ?? []
    ).map(toPersistedCleanupEntry),
    project_context_destructive_epoch: state.projectContextDestructiveEpoch,
    project_context_destructive_transition:
      state.projectContextDestructiveTransition === null
        ? null
        : toPersistedDestructiveTransition(
            state.projectContextDestructiveTransition,
          ),
    active_conversation_id: state.selectedConversationId,
    conversations,
    messages: selectActiveMessages(state).map(toPersistedMessage),
    session_events: (state.sessionEvents ?? []).map(event => ({ ...event })),
    preferences: canonicalPersistedPreferences(state.preferences),
  };
}

/**
 * JSON.parse accepts duplicate object keys and silently turns -0 into a
 * number.  Schema-9 is an authority boundary, so scan the bytes first and
 * reject those forms (and unsafe integer literals) before allocation.
 */
function strictJSONInput(value: string): unknown {
  let index = 0;
  const length = value.length;
  const whitespace = () => {
    while (
      index < length &&
      (value[index] === ' ' ||
        value[index] === '\n' ||
        value[index] === '\r' ||
        value[index] === '\t')
    )
      index += 1;
  };
  const parseString = (): string => {
    if (value[index] !== '"') throw new Error('string');
    index += 1;
    let result = '';
    let escaped = false;
    while (index < length) {
      const character = value[index]!;
      if (escaped) {
        escaped = false;
        if (character === 'u') {
          const digits = value.slice(index + 1, index + 5);
          if (!/^[0-9a-fA-F]{4}$/u.test(digits)) throw new Error('escape');
          result += String.fromCharCode(Number.parseInt(digits, 16));
          index += 4;
        } else {
          const escapedCharacter: Record<string, string> = {
            '"': '"',
            '\\': '\\',
            '/': '/',
            b: '\b',
            f: '\f',
            n: '\n',
            r: '\r',
            t: '\t',
          };
          const replacement = escapedCharacter[character];
          if (replacement === undefined) throw new Error('escape');
          result += replacement;
        }
        index += 1;
        continue;
      }
      if (character === '\\') {
        escaped = true;
        index += 1;
        continue;
      }
      if (character === '"') {
        index += 1;
        if (utf8ByteLength(result) === null) throw new Error('utf8');
        return result;
      }
      if (character < ' ' || character === '\u007f') throw new Error('control');
      result += character;
      index += 1;
    }
    throw new Error('unterminated string');
  };
  const parseValue = (depth: number): void => {
    if (depth > 64) throw new Error('depth');
    whitespace();
    const character = value[index];
    if (character === '"') {
      parseString();
      return;
    }
    if (character === '{') {
      index += 1;
      whitespace();
      const keys = new Set<string>();
      if (value[index] === '}') {
        index += 1;
        return;
      }
      while (index < length) {
        whitespace();
        const key = parseString();
        if (keys.has(key)) throw new Error('duplicate key');
        keys.add(key);
        whitespace();
        if (value[index] !== ':') throw new Error('colon');
        index += 1;
        parseValue(depth + 1);
        whitespace();
        if (value[index] === '}') {
          index += 1;
          return;
        }
        if (value[index] !== ',') throw new Error('object');
        index += 1;
      }
      throw new Error('object');
    }
    if (character === '[') {
      index += 1;
      whitespace();
      if (value[index] === ']') {
        index += 1;
        return;
      }
      while (index < length) {
        parseValue(depth + 1);
        whitespace();
        if (value[index] === ']') {
          index += 1;
          return;
        }
        if (value[index] !== ',') throw new Error('array');
        index += 1;
      }
      throw new Error('array');
    }
    if (value.startsWith('true', index)) {
      index += 4;
      return;
    }
    if (value.startsWith('false', index)) {
      index += 5;
      return;
    }
    if (value.startsWith('null', index)) {
      index += 4;
      return;
    }
    const number = value
      .slice(index)
      .match(/^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/u)?.[0];
    if (number === undefined) throw new Error('value');
    const parsedNumber = Number(number);
    if (
      !Number.isFinite(parsedNumber) ||
      (Number.isInteger(parsedNumber) && !Number.isSafeInteger(parsedNumber)) ||
      Object.is(parsedNumber, -0)
    )
      throw new Error('number');
    index += number.length;
  };
  parseValue(0);
  whitespace();
  if (index !== length) throw new Error('trailing');
  return JSON.parse(value) as unknown;
}

function plainDataTree(value: unknown, depth = 0): boolean {
  if (depth > 16 || value === null) return true;
  if (typeof value !== 'object') {
    return (
      typeof value === 'string' ||
      typeof value === 'boolean' ||
      (typeof value === 'number' &&
        Number.isFinite(value) &&
        !Object.is(value, -0))
    );
  }
  if (Array.isArray(value)) {
    if (Object.getPrototypeOf(value) !== Array.prototype) return false;
    const descriptor = Object.getOwnPropertyDescriptor(value, 'length');
    if (
      descriptor === undefined ||
      !Object.prototype.hasOwnProperty.call(descriptor, 'value')
    )
      return false;
    for (let index = 0; index < value.length; index += 1) {
      const item = Object.getOwnPropertyDescriptor(value, String(index));
      if (
        item === undefined ||
        !Object.prototype.hasOwnProperty.call(item, 'value') ||
        item.enumerable !== true ||
        !plainDataTree(item.value, depth + 1)
      )
        return false;
    }
    return Object.getOwnPropertyNames(value).every(
      name => name === 'length' || /^(?:0|[1-9][0-9]*)$/u.test(name),
    );
  }
  const prototype = Object.getPrototypeOf(value);
  if (prototype !== Object.prototype && prototype !== null) return false;
  if (Object.getOwnPropertySymbols(value).length > 0) return false;
  return Object.getOwnPropertyNames(value).every(name => {
    const descriptor = Object.getOwnPropertyDescriptor(value, name);
    return (
      descriptor !== undefined &&
      Object.prototype.hasOwnProperty.call(descriptor, 'value') &&
      descriptor.enumerable === true &&
      plainDataTree(descriptor.value, depth + 1)
    );
  });
}

/** Shared strict JSON gate for the session CAS coordinator. */
export function parseStrictJSON(value: string): unknown {
  return strictJSONInput(value);
}

export function hydrateChatState(
  input: unknown,
  options: ChatHydrationOptionsV1 = {},
): ChatState {
  const explicitAuthority =
    options.sessionAuthority === undefined
      ? undefined
      : parseHydrationAuthority(options.sessionAuthority);
  const nativeEnvelope =
    options.nativeEnvelope === undefined
      ? undefined
      : parseHydrationNativeEnvelope(options.nativeEnvelope);
  if (
    explicitAuthority !== undefined &&
    nativeEnvelope !== undefined &&
    (explicitAuthority.generation !== nativeEnvelope.session_generation ||
      explicitAuthority.session_sha256 !== nativeEnvelope.session_sha256)
  ) {
    return invalid(
      '$.native_envelope',
      'must match the supplied session authority',
    );
  }
  const hydrationOptions: NormalizedChatHydrationOptions = {
    staleWriterLaunch: options.staleWriterLaunch === true,
    ...(explicitAuthority === undefined && nativeEnvelope === undefined
      ? {}
      : {
          sessionAuthority:
            explicitAuthority ?? {
              schema_version: 1,
              generation: nativeEnvelope!.session_generation,
              session_sha256: nativeEnvelope!.session_sha256,
            },
        }),
    ...(nativeEnvelope === undefined
      ? {}
      : { nativeJournalRevision: nativeEnvelope.journal_revision }),
  };
  let decoded: unknown = input;
  if (typeof input === 'string') {
    try {
      decoded = strictJSONInput(input);
    } catch {
      return invalid('$', 'must be valid JSON');
    }
  }

  let raw = record(decoded, '$');
  const decodedSchemaVersion = ownDataValue(
    raw,
    'schema_version',
    '$.schema_version',
  );
  if (
    decodedSchemaVersion !== LEGACY_CHAT_STATE_SCHEMA_VERSION &&
    decodedSchemaVersion !== OLDER_CHAT_STATE_SCHEMA_VERSION &&
    decodedSchemaVersion !== ATTACHMENT_CHAT_STATE_SCHEMA_VERSION &&
    decodedSchemaVersion !== WORKSPACE_CHAT_STATE_SCHEMA_VERSION &&
    decodedSchemaVersion !== PROJECT_CONTEXT_CHAT_STATE_SCHEMA_VERSION &&
    decodedSchemaVersion !== PREVIOUS_CHAT_STATE_SCHEMA_VERSION &&
    decodedSchemaVersion !== CHAT_STATE_SCHEMA_VERSION_V8 &&
    decodedSchemaVersion !== CHAT_STATE_SCHEMA_VERSION
  ) {
    return invalid(
      '$.schema_version',
      `must equal ${LEGACY_CHAT_STATE_SCHEMA_VERSION}, ${OLDER_CHAT_STATE_SCHEMA_VERSION}, ${ATTACHMENT_CHAT_STATE_SCHEMA_VERSION}, ${WORKSPACE_CHAT_STATE_SCHEMA_VERSION}, ${PROJECT_CONTEXT_CHAT_STATE_SCHEMA_VERSION}, ${PREVIOUS_CHAT_STATE_SCHEMA_VERSION}, ${CHAT_STATE_SCHEMA_VERSION_V8}, or ${CHAT_STATE_SCHEMA_VERSION}`,
    );
  }
  const schemaVersion = decodedSchemaVersion;
  if (schemaVersion === CHAT_STATE_SCHEMA_VERSION) {
    raw = exactRecord(decoded, '$', [
      'schema_version',
      'workspace_authority_outbox',
      'agent_transcript_cleanup_outbox',
      'project_context_destructive_epoch',
      'project_context_destructive_transition',
      'active_conversation_id',
      'conversations',
      'messages',
      'session_events',
      'preferences',
    ]);
    try {
      if (!plainDataTree(raw.preferences)) throw new Error('preferences');
      hydrateAppPreferences(raw.preferences);
    } catch {
      return invalid('$.preferences', 'violates the preferences contract');
    }
  } else if (hasProjectContextShape(schemaVersion)) {
    // App persistence deliberately co-locates the independently validated
    // preferences envelope at the root.
    raw = exactRecord(
      decoded,
      '$',
      hasDestructiveJournalShape(schemaVersion)
        ? [
            'schema_version',
            ...(hasWorkspaceRoutingShape(schemaVersion)
              ? ['workspace_authority_outbox']
              : []),
            'project_context_destructive_epoch',
            'project_context_destructive_transition',
            'active_conversation_id',
            'conversations',
            'messages',
            'preferences',
            'session_events',
          ]
        : [
            'schema_version',
            'active_conversation_id',
            'conversations',
            'messages',
            'preferences',
            'session_events',
          ],
      ['preferences', 'session_events'],
    );
  } else {
    raw = exactRecord(
      decoded,
      '$',
      [
        'schema_version',
        'active_conversation_id',
        'conversations',
        'messages',
        'preferences',
        'session_events',
      ],
      ['preferences', 'session_events'],
    );
  }
  const hasLegacyPreferences = Object.prototype.hasOwnProperty.call(
    raw,
    'preferences',
  );
  const hasLegacySessionEvents = Object.prototype.hasOwnProperty.call(
    raw,
    'session_events',
  );
  if (
    !hasAgentSchema(schemaVersion) &&
    ((hasLegacyPreferences && raw.preferences === undefined) ||
      (hasLegacySessionEvents && raw.session_events === undefined))
  ) {
    return invalid(
      hasLegacyPreferences && raw.preferences === undefined
        ? '$.preferences'
        : '$.session_events',
      'must not be undefined when present',
    );
  }
  if (
    !hasAgentSchema(schemaVersion) &&
    hasLegacySessionEvents &&
    (!Array.isArray(raw.session_events) ||
      Object.getPrototypeOf(raw.session_events) !== Array.prototype)
  ) {
    return invalid('$.session_events', 'must be an array');
  }
  if (
    raw.active_conversation_id !== null &&
    typeof raw.active_conversation_id !== 'string'
  ) {
    return invalid('$.active_conversation_id', 'must be a string or null');
  }

  const destructiveEpoch = hasDestructiveJournalShape(schemaVersion)
    ? lifecycleEpoch(
        raw.project_context_destructive_epoch,
        '$.project_context_destructive_epoch',
        true,
      )
    : 0;
  const workspaceAuthorityOutbox = hasWorkspaceRoutingShape(schemaVersion)
    ? array(
        raw.workspace_authority_outbox,
        '$.workspace_authority_outbox',
        MAX_WORKSPACE_AUTHORITY_OUTBOX_ENTRIES,
      ).map((entry, index) =>
        parseWorkspaceOutboxEntry(
          entry,
          `$.workspace_authority_outbox[${index}]`,
        ),
      )
    : [];
  const workspaceOperationIds = new Set<string>();
  workspaceAuthorityOutbox.forEach((entry, index) => {
    if (workspaceOperationIds.has(entry.operationId)) {
      invalid(
        `$.workspace_authority_outbox[${index}].operation_id`,
        'must be globally unique',
      );
    }
    workspaceOperationIds.add(entry.operationId);
  });
  let agentTranscriptCleanupOutbox = hasAgentSchema(schemaVersion)
    ? array(
        raw.agent_transcript_cleanup_outbox,
        '$.agent_transcript_cleanup_outbox',
        MAX_AGENT_CLEANUP_OUTBOX_ENTRIES,
      ).map((entry, index) =>
        parseCleanupEntry(entry, `$.agent_transcript_cleanup_outbox[${index}]`),
      )
    : [];
  const cleanupIds = new Set<string>();
  agentTranscriptCleanupOutbox.forEach((entry, index) => {
    if (cleanupIds.has(entry.cleanup_id)) {
      invalid(
        `$.agent_transcript_cleanup_outbox[${index}].cleanup_id`,
        'must be globally unique',
      );
    }
    cleanupIds.add(entry.cleanup_id);
  });
  const sessionEvents = hasAgentSchema(schemaVersion)
    ? array(raw.session_events, '$.session_events', MAX_SESSION_EVENT_ROWS).map(
        (entry, index) =>
          parseSessionEvent(entry, `$.session_events[${index}]`),
      )
    : [];
  const eventIds = new Set<string>();
  const eventSequences = new Map<string, number>();
  sessionEvents.forEach((event, index) => {
    if (eventIds.has(event.event_id)) {
      invalid(`$.session_events[${index}].event_id`, 'must be globally unique');
    }
    eventIds.add(event.event_id);
    const previous = eventSequences.get(event.attempt_id);
    if (previous !== undefined && event.seq <= previous) {
      invalid(
        `$.session_events[${index}].seq`,
        'must strictly increase for the attempt',
      );
    }
    eventSequences.set(event.attempt_id, event.seq);
  });
  const hydratedPreferences = (() => {
    try {
      if (raw.preferences === undefined && hasAgentSchema(schemaVersion)) {
        // A schema-9 root always serializes the canonical default envelope,
        // but preserve the historical in-memory omission when the caller
        // supplied no preference projection at all.
        return undefined;
      }
      const parsed =
        raw.preferences === undefined
          ? DEFAULT_APP_PREFERENCES
          : (() => {
              if (!plainDataTree(raw.preferences))
                throw new Error('preferences');
              return hydrateAppPreferences(raw.preferences);
            })();
      // Always carry the canonical schema-1 preference envelope in the
      // migrated schema-9 projection.  In particular, never silently omit a
      // defaulted legacy value: the diagnostic below records that boundary.
      return JSON.parse(
        serializeAppPreferences(parsed),
      ) as PersistedAppPreferencesV1;
    } catch {
      return invalid('$.preferences', 'violates the preferences contract');
    }
  })();
  const migrationDiagnostics: {
    defaulted_legacy_preferences?: true;
    dropped_legacy_session_events?: true;
  } = {};
  if (!hasAgentSchema(schemaVersion) && !hasLegacyPreferences) {
    migrationDiagnostics.defaulted_legacy_preferences = true;
  }
  if (!hasAgentSchema(schemaVersion) && hasLegacySessionEvents) {
    migrationDiagnostics.dropped_legacy_session_events = true;
  }
  const destructiveTransition =
    hasDestructiveJournalShape(schemaVersion) &&
    raw.project_context_destructive_transition !== null
      ? parseDestructiveTransition(
          raw.project_context_destructive_transition,
          '$.project_context_destructive_transition',
        )
      : null;
  if (
    destructiveTransition !== null &&
    destructiveTransition.epoch !== destructiveEpoch
  ) {
    return invalid(
      '$.project_context_destructive_transition.epoch',
      'must match the root destructive epoch',
    );
  }

  const rawConversations = array(
    raw.conversations,
    '$.conversations',
    MAX_CONVERSATIONS,
  );
  if (rawConversations.length > MAX_CONVERSATIONS) {
    return invalid(
      '$.conversations',
      `must contain no more than ${MAX_CONVERSATIONS} conversations`,
    );
  }

  const conversations: Record<string, Conversation> = {};
  rawConversations.forEach((entry, index) => {
    const conversation = parseConversation(
      entry,
      `$.conversations[${index}]`,
      schemaVersion,
      hydrationOptions,
    );
    if (conversations[conversation.id] !== undefined) {
      return invalid(`$.conversations[${index}].id`, 'must be unique');
    }
    conversations[conversation.id] = conversation;
  });
  if (hasAgentSchema(schemaVersion)) {
    validateSessionEventCorrelations(sessionEvents, conversations);
  }

  if (hasAgentSchema(schemaVersion)) {
    agentTranscriptCleanupOutbox.forEach((cleanup, index) => {
      const conversation = conversations[cleanup.conversation_id];
      const attempt = conversation?.attempts.find(
        candidate => candidate.attemptId === cleanup.attempt_id,
      );
      if (
        (conversation === undefined || attempt === undefined) &&
        !(
          cleanup.reason === 'conversation_deleted' &&
          conversation === undefined
        )
      ) {
        invalid(
          `$.agent_transcript_cleanup_outbox[${index}]`,
          'must reference an existing attempt',
        );
      }
      if (conversation === undefined) {
        if (cleanup.reason !== 'conversation_deleted') {
          invalid(
            `$.agent_transcript_cleanup_outbox[${index}]`,
            'detached cleanup must be conversation_deleted',
          );
        }
        return;
      }
      if (attempt === undefined)
        return invalid(
          `$.agent_transcript_cleanup_outbox[${index}]`,
          'must reference an existing attempt',
        );
      if (
        attempt.status === 'failed' &&
        attempt.failureCode === 'E_ATTEMPT_INTERRUPTED' &&
        cleanup.reason === 'failed' &&
        cleanup.task_id === attempt.turnId
      ) {
        // Interruption recovery keeps the journal as round evidence but the
        // attempt phase is no longer a terminal-phase reason; the transcript
        // must still match the entry exactly.
        const transcript = attempt.agent?.transcript;
        if (
          transcript === undefined ||
          transcript === null ||
          transcript.transcript_ref !== cleanup.transcript_ref ||
          transcript.transcript_sha256 !== cleanup.transcript_sha256
        ) {
          invalid(
            `$.agent_transcript_cleanup_outbox[${index}]`,
            'must match the attempt transcript',
          );
        }
        return;
      }
      const transcript = attempt.agent?.transcript;
      const expectedReason =
        attempt.agent?.phase === 'final_response'
          ? 'completed'
          : attempt.agent?.phase === 'cancelled'
            ? 'cancelled'
            : attempt.agent?.phase === 'failed'
              ? 'failed'
              : null;
      if (expectedReason === null || cleanup.reason !== expectedReason) {
        invalid(
          `$.agent_transcript_cleanup_outbox[${index}].reason`,
          'must match the terminal attempt phase',
        );
      }
      if (
        transcript === undefined ||
        transcript === null ||
        cleanup.task_id !== attempt.turnId ||
        transcript.transcript_ref !== cleanup.transcript_ref ||
        transcript.transcript_sha256 !== cleanup.transcript_sha256
      ) {
        invalid(
          `$.agent_transcript_cleanup_outbox[${index}]`,
          'must match the attempt transcript',
        );
      }
    });
    sessionEvents.forEach((event, index) => {
      if (
        !Object.values(conversations).some(conversation =>
          conversation.attempts.some(
            attempt => attempt.attemptId === event.attempt_id,
          ),
        )
      ) {
        invalid(
          `$.session_events[${index}].attempt_id`,
          'must reference an existing attempt',
        );
      }
    });
  }

  const lifecycleIds = new Set<string>();
  const providerRequestIds = new Set<string>();
  const providerResponseIds = new Set<string>();
  const claimLifecycleId = (value: string, path: string) => {
    if (lifecycleIds.has(value)) invalid(path, 'must be globally unique');
    lifecycleIds.add(value);
  };
  workspaceAuthorityOutbox.forEach((entry, index) => {
    claimLifecycleId(
      entry.operationId,
      `$.workspace_authority_outbox[${index}].operation_id`,
    );
    claimLifecycleId(
      entry.clearanceReceiptId,
      `$.workspace_authority_outbox[${index}].clearance_receipt_id`,
    );
  });
  Object.values(conversations).forEach((conversation, conversationIndex) => {
    conversation.agentGrants?.forEach((grant, grantIndex) =>
      claimLifecycleId(
        grant.grant_id,
        `$.conversations[${conversationIndex}].agent_grants[${grantIndex}].grant_id`,
      ),
    );
    if (conversation.runtimeContextId !== null) {
      claimLifecycleId(
        conversation.runtimeContextId,
        `$.conversations[${conversationIndex}].runtime_context_id`,
      );
    }
    conversation.turns.forEach((turn, turnIndex) =>
      claimLifecycleId(
        turn.turnId,
        `$.conversations[${conversationIndex}].turns[${turnIndex}].turn_id`,
      ),
    );
    conversation.attempts.forEach((attempt, attemptIndexValue) => {
      claimLifecycleId(
        attempt.attemptId,
        `$.conversations[${conversationIndex}].attempts[${attemptIndexValue}].attempt_id`,
      );
      attempt.rounds.forEach((round, roundIndex) => {
        const roundPath = `$.conversations[${conversationIndex}].attempts[${attemptIndexValue}].rounds[${roundIndex}]`;
        claimLifecycleId(round.roundId, `${roundPath}.round_id`);
        if (providerRequestIds.has(round.providerRequestId)) {
          invalid(
            `${roundPath}.provider_request_id`,
            'must be globally unique',
          );
        }
        providerRequestIds.add(round.providerRequestId);
        if (providerResponseIds.has(round.providerResponseId)) {
          invalid(
            `${roundPath}.provider_response_id`,
            'must be globally unique',
          );
        }
        providerResponseIds.add(round.providerResponseId);
      });
      if (attempt.activeRound !== null) {
        claimLifecycleId(
          attempt.activeRound.roundId,
          `$.conversations[${conversationIndex}].attempts[${attemptIndexValue}].active_round.round_id`,
        );
      }
      if (
        attempt.agent?.round_lineage !== null &&
        attempt.agent?.round_lineage !== undefined &&
        attempt.activeRound?.roundId !== attempt.agent.round_lineage.round_id &&
        !attempt.rounds.some(
          round => round.roundId === attempt.agent?.round_lineage?.round_id,
        )
      ) {
        claimLifecycleId(
          attempt.agent.round_lineage.round_id,
          `$.conversations[${conversationIndex}].attempts[${attemptIndexValue}].agent.round_lineage.round_id`,
        );
      }
      if (attempt.agent?.transcript !== undefined) {
        claimLifecycleId(
          attempt.agent.transcript.transcript_ref,
          `$.conversations[${conversationIndex}].attempts[${attemptIndexValue}].agent.transcript.transcript_ref`,
        );
      }
    });
  });
  agentTranscriptCleanupOutbox.forEach((entry, index) =>
    claimLifecycleId(
      entry.cleanup_id,
      `$.agent_transcript_cleanup_outbox[${index}].cleanup_id`,
    ),
  );
  sessionEvents.forEach((event, index) =>
    claimLifecycleId(event.event_id, `$.session_events[${index}].event_id`),
  );
  if (destructiveTransition !== null) {
    claimLifecycleId(
      destructiveTransition.lifecycleId,
      '$.project_context_destructive_transition.lifecycle_id',
    );
  }

  // Interruption recovery is deterministic at hydration time.  A non-terminal
  // attempt persisted by a previous process launch can never be resumed:
  // its writer is dead, its provider round can no longer complete, and its
  // native reservation/authority residue must be discarded, never replayed.
  // Marking it failed with E_ATTEMPT_INTERRUPTED routes every later Retry
  // through the legacy retry path (a fresh attempt in the same turn) instead
  // of native recovery of the stale one.  A journaled attempt additionally
  // needs a cleanup outbox entry so the native residue is discarded; the
  // outbox is bounded, so journaled zombies beyond the remaining capacity
  // stay untouched this launch and are interrupted, in the same file order,
  // by a later hydration once the outbox has drained.  Attempts without a
  // journal own no native residue and are always interrupted.
  const interruptedCleanupEntries: AgentTranscriptCleanupV1[] = [];
  const interruptibleJournaled = new Set<string>();
  if (hydrationOptions.staleWriterLaunch) {
    const budget = Math.max(
      0,
      MAX_AGENT_CLEANUP_OUTBOX_ENTRIES - agentTranscriptCleanupOutbox.length,
    );
    Object.values(conversations).forEach(conversation => {
      conversation.attempts.forEach(attempt => {
        if (
          (attempt.status === 'sending' || attempt.status === 'prepared') &&
          attempt.agent !== undefined &&
          attempt.agent !== null &&
          interruptibleJournaled.size < budget
        ) {
          interruptibleJournaled.add(attempt.attemptId);
        }
      });
    });
  }
  const hydratedConversations: Record<string, Conversation> = {};
  Object.values(conversations).forEach(conversation => {
    hydratedConversations[conversation.id] = {
      ...conversation,
      attempts: conversation.attempts.map(attempt => {
        const nonTerminal =
          attempt.status === 'sending' || attempt.status === 'prepared';
        const journaled = attempt.agent !== undefined && attempt.agent !== null;
        if (
          hydrationOptions.staleWriterLaunch &&
          nonTerminal &&
          (!journaled || interruptibleJournaled.has(attempt.attemptId))
        ) {
          if (journaled) {
            // The journal stays as the round/transcript audit evidence, but
            // the attempt itself is terminal: its writer launch is dead, so
            // neither the provider round nor any tool effect may continue.
            // The cleanup entry retains the transcript identity for the
            // native discard proof.
            interruptedCleanupEntries.push({
              schema_version: AGENT_CLEANUP_SCHEMA_VERSION,
              cleanup_id: interruptedCleanupIdForAttempt(attempt.attemptId),
              conversation_id: conversation.id,
              task_id: attempt.turnId,
              attempt_id: attempt.attemptId,
              transcript_ref: attempt.agent.transcript.transcript_ref,
              transcript_sha256: attempt.agent.transcript.transcript_sha256,
              reason: 'failed',
              created_at: attempt.updatedAt,
            });
          }
          return {
            ...attempt,
            status: 'failed' as const,
            activeRound: null,
            failureCode: 'E_ATTEMPT_INTERRUPTED' as const,
          };
        }
        return (!hasAgentSchema(schemaVersion) || attempt.agent === null) &&
          (attempt.status === 'sending' ||
            (attempt.status === 'prepared' && attempt.rounds.length > 0))
          ? {
              ...attempt,
              status: 'failed' as const,
              activeRound: null,
              failureCode: 'E_ATTEMPT_INTERRUPTED' as const,
            }
          : attempt;
      }),
    };
  });
  if (interruptedCleanupEntries.length > 0) {
    interruptedCleanupEntries.forEach(entry => {
      if (
        agentTranscriptCleanupOutbox.some(
          existing => existing.cleanup_id === entry.cleanup_id,
        ) ||
        lifecycleIds.has(entry.cleanup_id)
      ) {
        invalid(
          '$.agent_transcript_cleanup_outbox',
          'interrupted cleanup identity must be globally unique',
        );
      }
      claimLifecycleId(
        entry.cleanup_id,
        '$.agent_transcript_cleanup_outbox[interrupted]',
      );
    });
    agentTranscriptCleanupOutbox = [
      ...agentTranscriptCleanupOutbox,
      ...interruptedCleanupEntries,
    ];
  }

  if (workspaceAuthorityOutbox.length > 0) {
    const outboxReferenceState: ChatState = {
      schemaVersion: CHAT_STATE_SCHEMA_VERSION,
      workspaceAuthorityOutbox,
      projectContextDestructiveEpoch: destructiveEpoch,
      projectContextDestructiveTransition: destructiveTransition,
      conversations: hydratedConversations,
      conversationOrder: orderConversationIds(hydratedConversations),
      selectedConversationId:
        typeof raw.active_conversation_id === 'string'
          ? raw.active_conversation_id
          : null,
    };
    workspaceAuthorityOutbox.forEach((entry, index) => {
      if (
        hasWorkspaceAuthorityReferences(outboxReferenceState, entry.workspaceId)
      ) {
        invalid(
          `$.workspace_authority_outbox[${index}].workspace_id`,
          'must not be referenced by a conversation, context, or attempt',
        );
      }
    });
  }

  if (destructiveTransition !== null) {
    const conversation =
      hydratedConversations[destructiveTransition.conversationId];
    if (conversation === undefined) {
      return invalid(
        '$.project_context_destructive_transition.conversation_id',
        'must reference an existing conversation',
      );
    }
    if (
      conversation.projectId !== destructiveTransition.sourceProjectId ||
      conversation.runtimeContextId !==
        destructiveTransition.sourceRuntimeContextId ||
      conversation.modelId !== destructiveTransition.sourceModelId ||
      conversation.projectContext === null
    ) {
      return invalid(
        '$.project_context_destructive_transition',
        'must match the frozen conversation owner',
      );
    }
    const context = conversation.projectContext;
    if (destructiveTransition.phase === 'intent') {
      if (
        destructiveTransition.updatedAt !== destructiveTransition.createdAt ||
        Date.parse(conversation.updatedAt) >
          Date.parse(destructiveTransition.createdAt) ||
        context.activePreparationId !== null ||
        context.snapshot?.snapshot_id !== destructiveTransition.snapshotId ||
        context.snapshot?.snapshot_sha256 !==
          destructiveTransition.snapshotSha256 ||
        (context.consent?.consent_receipt_id ?? null) !==
          destructiveTransition.consentReceiptId
      ) {
        return invalid(
          '$.project_context_destructive_transition',
          'must match the exact source snapshot and consent',
        );
      }
    } else {
      if (
        context.status !== 'setup_required' ||
        context.selectedPaths.length !== 0 ||
        context.activePreparationId !== null ||
        context.snapshot !== null ||
        context.consent !== null ||
        context.staleReason !== null ||
        context.errorCode !== null
      ) {
        return invalid(
          '$.project_context_destructive_transition.phase',
          'requires the exact disabled project context',
        );
      }
      if (
        (destructiveTransition.phase === 'cleanup_pending' &&
          conversation.updatedAt !== destructiveTransition.updatedAt) ||
        (destructiveTransition.phase === 'ready_to_finalize' &&
          Date.parse(conversation.updatedAt) >
            Date.parse(destructiveTransition.updatedAt))
      ) {
        return invalid(
          '$.project_context_destructive_transition.updated_at',
          'must match its reachable phase checkpoint',
        );
      }
    }
    const referenceState: ChatState = {
      schemaVersion: CHAT_STATE_SCHEMA_VERSION,
      workspaceAuthorityOutbox,
      projectContextDestructiveEpoch: destructiveEpoch,
      projectContextDestructiveTransition: destructiveTransition,
      conversations: hydratedConversations,
      conversationOrder: orderConversationIds(hydratedConversations),
      selectedConversationId:
        typeof raw.active_conversation_id === 'string'
          ? raw.active_conversation_id
          : null,
    };
    if (
      hasProjectContextDestructiveReferences(
        referenceState,
        destructiveTransition,
      )
    ) {
      return invalid(
        '$.project_context_destructive_transition.snapshot_id',
        'must not be referenced by an attempt',
      );
    }
  }

  const activeConversationId =
    raw.active_conversation_id === null
      ? null
      : boundedString(
          raw.active_conversation_id,
          '$.active_conversation_id',
          MAX_ID_LENGTH,
        );
  if (
    activeConversationId !== null &&
    hydratedConversations[activeConversationId] === undefined
  ) {
    return invalid(
      '$.active_conversation_id',
      'must reference an existing conversation',
    );
  }

  const projectedMessages = parseMessages(
    raw.messages,
    '$.messages',
    schemaVersion,
  );
  const activeMessages =
    activeConversationId === null
      ? []
      : hydratedConversations[activeConversationId]?.messages ?? [];
  if (!messagesEqual(projectedMessages, activeMessages)) {
    return invalid(
      '$.messages',
      'must exactly mirror the active conversation messages',
    );
  }

  const hydratedState: ChatState = {
    schemaVersion: CHAT_STATE_SCHEMA_VERSION,
    workspaceAuthorityOutbox,
    projectContextDestructiveEpoch: destructiveEpoch,
    projectContextDestructiveTransition: destructiveTransition,
    conversations: hydratedConversations,
    conversationOrder: orderConversationIds(hydratedConversations),
    selectedConversationId: activeConversationId,
    agentTranscriptCleanupOutbox,
    sessionEvents,
    ...(hydratedPreferences === undefined
      ? {}
      : { preferences: hydratedPreferences }),
  };
  if (Object.keys(migrationDiagnostics).length > 0) {
    Object.defineProperty(hydratedState, 'migrationDiagnostics', {
      value: Object.freeze({ ...migrationDiagnostics }),
      enumerable: false,
      writable: false,
      configurable: false,
    });
  }
  return hydratedState;
}

export function safeHydrateChatState(
  input: unknown,
  options: ChatHydrationOptionsV1 = {},
): HydrationResult {
  try {
    return { ok: true, state: hydrateChatState(input, options) };
  } catch (error) {
    return {
      ok: false,
      error:
        error instanceof ChatStateValidationError
          ? error
          : new ChatStateValidationError('$', 'could not hydrate chat state'),
    };
  }
}

// Every distinct candidate string is validated once; a checkpoint serialises
// and re-validates the same session several times, so remember the last few
// strings that passed. Validation stays fail-closed: nothing is trusted
// until hydrateChatState has accepted exactly that text.
const VALIDATED_CANDIDATE_ENTRIES = 4;
const validatedCandidates: string[] = [];

function rememberValidatedCandidate(json: string): void {
  if (validatedCandidates.length >= VALIDATED_CANDIDATE_ENTRIES) {
    validatedCandidates.shift();
  }
  validatedCandidates.push(json);
}

function isValidatedCandidate(json: string): boolean {
  for (let index = 0; index < validatedCandidates.length; index += 1) {
    if (validatedCandidates[index] === json) return true;
  }
  return false;
}

/**
 * True when `json` is a session candidate hydrateChatState accepts. Repeats
 * of a string that already passed are answered from memory.
 */
export function sessionCandidateIsValid(json: string): boolean {
  if (typeof json !== 'string' || json.length === 0) return false;
  if (isValidatedCandidate(json)) return true;
  if (!safeHydrateChatState(json).ok) return false;
  rememberValidatedCandidate(json);
  return true;
}

export function serializeChatState(state: ChatState): string {
  try {
    const persisted = toPersistedState(state);
    const json = JSON.stringify(persisted);
    if (typeof json !== 'string') {
      throw new ChatStateValidationError('$', 'could not serialize chat state');
    }
    if (!isValidatedCandidate(json)) {
      // Validate the text that will be persisted, not the in-memory object:
      // that is exactly what the native store and every later reader see.
      hydrateChatState(JSON.parse(json));
      rememberValidatedCandidate(json);
    }
    return json;
  } catch (error) {
    if (error instanceof ChatStateValidationError) throw error;
    throw new ChatStateValidationError('$', 'could not serialize chat state');
  }
}
