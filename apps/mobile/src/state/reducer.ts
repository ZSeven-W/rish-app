import { agentAmbiguityCode } from '../agent/AgentAmbiguity';
import { conversationGrantIdsForBatch, hasFrozenConversationGrant, hasLiveConversationGrant, isConversationGrantBoundCall } from '../agent/agent-conversation-grants';
import { ALL_AGENT_TOOL_NAMES, ALL_AGENT_AUTO_TOOLS, agentToolRegistryCompatible, isGuestServiceAgentTool } from '../agent/tool-registry';
import { isHarnessModelId } from '../harness/types';
import { providerHostMatches, parseProviderBinding } from '../providers/configuration';
import {
  AGENT_FAILURE_CODES,
  ATTEMPT_PROJECT_CONTEXT_SCHEMA_VERSION,
  ATTEMPT_FAILURE_CODES,
  ATTACHMENT_DESCRIPTOR_SCHEMA_VERSION,
  ATTACHMENT_KINDS,
  CHAT_STATE_SCHEMA_VERSION,
  CONVERSATION_WORKSPACE_BINDING_SCHEMA_VERSION,
  CONVERSATION_WORKSPACE_BOOTSTRAP_STATES,
  COMPLETION_FINISH_REASONS,
  COMPLETION_ROUND_RECEIPT_SCHEMA_VERSION,
  CONVERSATION_THINKING_MODES,
  CONVERSATION_TURN_SCHEMA_VERSION,
  TURN_ATTEMPT_STATUSES,
  TURN_ATTEMPT_SCHEMA_VERSION,
  PROJECT_CONTEXT_DESTRUCTIVE_TRANSITION_SCHEMA_VERSION,
  WORKSPACE_AUTHORITY_OUTBOX_SCHEMA_VERSION,
  MAX_AGENT_ATTEMPT_WRITE_BYTES,
  MAX_AGENT_BATCH_WRITE_BYTES,
  MAX_AGENT_CALLS_PER_BATCH,
  MAX_AGENT_CLEANUP_OUTBOX_ENTRIES,
  MAX_AGENT_GRANTS_PER_CONVERSATION,
  MAX_AGENT_ROUNDS,
  MAX_AGENT_SINGLE_WRITE_BYTES,
  MAX_SESSION_EVENT_ROWS,
  MAX_AGENT_RESULT_BYTES,
  MAX_AGENT_TRANSCRIPT_BYTES,
  MAX_AGENT_SUMMARY_KEY_LENGTH,
  MAX_AGENT_DURATION_MS,
  AGENT_SAFE_SUMMARY_KEYS,
  isAgentPhaseLineageValid,
  type ChatAction,
  type ChatAttachment,
  type ChatAttachmentKind,
  type ChatMessage,
  type ChatState,
  type AttemptFailureCode,
  type Conversation,
  type ConversationThinkingMode,
  type CompletionRoundReceiptV1,
  type ModelId,
  type ProjectContextMutationScope,
  type ProjectContextDestructiveAdvanceScope,
  type ProjectContextDestructiveTransitionV1,
  type ConversationWorkspaceBindingV1,
  type ConversationWorkspaceBootstrapState,
  type WorkspaceAuthorityOutboxV1,
  type TurnAttemptV1,
  type AgentAccess,
  type AgentApprovalDecision,
  type AgentFailureCode,
  type AgentToolReceiptV1,
  type AgentTranscriptCleanupV1,
  type AgentTranscriptReferenceV1,
  type PersistedAgentAttemptJournalV2,
  type PersistedAgentAttemptJournalV3,
  type PersistedAgentCallJournalV2,
  type PersistedAgentCallJournalV3,
  type FrozenAgentRootV1,
  type AgentWritePolicyV1,
  type AgentConversationGrantV2,
  type AgentRegistryVersion,
  type AgentApprovalTokenV1,
  type AgentControllerCASV1,
  type AgentCheckpointEvidence,
  type AgentControllerPreflightV1,
  type SessionEventV2,
  type PersistedSessionEventV3,
  type AgentAttemptPhase,
} from './types';
import {
  harnessForModel,
  isHarnessId,
  isProviderId,
  providerForModel,
} from '../harness/types';
import {
  validateAgentStoreTransition,
  type AgentStoreTransitionEvidence,
} from '../agent/AgentStoreTransitions';
import { validateAgentControllerPreflight } from '../agent/AgentControllerPreflight';
import {
  createProjectContextState,
  isProjectContextSendable,
  projectContextReducer,
} from '../project-context/reducer';
import { canonicalizeDurableProjectContextState } from '../project-context/persistence';
import type {
  ProjectContextConsentV1,
  ProjectContextManifestV1,
  ProjectContextState,
} from '../project-context/types';
import { DEFAULT_APP_PREFERENCES } from '../preferences/reducer';
import { serializeAppPreferences } from '../preferences/persistence';

export const DEFAULT_CONVERSATION_TITLE = 'New chat';
export const DEFAULT_MODEL_ID: ModelId = 'deepseek-v4-flash';
export const DEFAULT_THINKING_MODE: ConversationThinkingMode = 'high';
export const AUTO_TITLE_MAX_LENGTH = 48;
export const MANUAL_TITLE_MAX_LENGTH = 120;
export const MAX_CHAT_MESSAGE_LENGTH = 1_000_000;
export const PROJECT_ID_MAX_LENGTH = 256;
export const MAX_ATTACHMENTS_PER_MESSAGE = 6;
export const MAX_ATTACHMENT_ID_LENGTH = 256;
export const MAX_ATTACHMENT_NAME_LENGTH = 256;
export const MAX_ATTACHMENT_MIME_TYPE_LENGTH = 256;
export const MAX_TEXT_ATTACHMENT_SIZE = 1024 * 1024;
export const MAX_BINARY_ATTACHMENT_SIZE = 8 * 1024 * 1024;
export const MAX_TOTAL_ATTACHMENT_SIZE = 24 * 1024 * 1024;
export const MAX_COMPLETION_ROUNDS = 8;
export const MAX_ATTEMPT_VISIBLE_MESSAGES = 200;
export const MAX_ATTEMPT_ATTACHMENT_IDS = 24;
export const MAX_PROJECT_CONTEXT_RECEIPT_BYTES = 256 * 1024;
export const MAX_PROJECT_CONTEXT_SNAPSHOT_REFERENCE_ROWS = 1024;
export const MAX_WORKSPACE_AUTHORITY_OUTBOX_ENTRIES = 16;
const MAX_PROJECT_CONTEXT_SNAPSHOT_REFERENCE_SCAN = 100_000;

const thinkingModes: ReadonlySet<string> = new Set(CONVERSATION_THINKING_MODES);
const attachmentKinds: ReadonlySet<string> = new Set(ATTACHMENT_KINDS);
const finishReasons: ReadonlySet<string> = new Set(COMPLETION_FINISH_REASONS);
// An Agent round settles its attempt with the Agent's own failure code, so
// every code the Agent can raise is also a valid attempt failure code. Keeping
// them out made a real Agent failure unpersistable, which surfaced as a
// durability error instead of the cause.
const attemptFailureCodes: ReadonlySet<string> = new Set<string>([
  ...ATTEMPT_FAILURE_CODES,
  ...AGENT_FAILURE_CODES,
]);
const attemptStatuses: ReadonlySet<string> = new Set(TURN_ATTEMPT_STATUSES);
const workspaceBootstrapStates: ReadonlySet<string> = new Set(
  CONVERSATION_WORKSPACE_BOOTSTRAP_STATES,
);
const mimeTypePattern = /^[A-Za-z0-9!#$&^_.+-]+\/[A-Za-z0-9!#$&^_.+-]+$/u;
const canonicalUuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u;
const sha256Pattern = /^[0-9a-f]{64}$/u;
const opaqueIdPattern = /^[A-Za-z0-9._:-]+$/u;
const attemptBindingKeys = [
  'schemaVersion',
  'runtimeContextId',
  'projectId',
  'snapshotId',
  'snapshotSha256',
  'sourceFingerprint',
  'contextBytes',
  'consentReceiptId',
  'provider',
  'policy',
  'policyVersion',
] as const;
const workspaceBindingKeys = [
  'schemaVersion',
  'workspaceId',
  'bindingRevision',
  'projectId',
] as const;
const workspaceOutboxKeys = [
  'schemaVersion',
  'operationId',
  'action',
  'workspaceId',
  'bindingRevision',
  'clearanceReceiptId',
  'createdAt',
] as const;
const workspaceBindingOwnerKeys = [
  'conversationId',
  'expectedConversation',
  'expectedProjectContext',
  'expectedDestructiveEpoch',
] as const;
const workspaceBindingActionKeys = ['owner', 'binding', 'at'] as const;
const roundReceiptKeys = [
  'schemaVersion',
  'transportSchemaVersion',
  'harnessId',
  'turnId',
  'attemptId',
  'roundId',
  'roundIndex',
  'providerRequestId',
  'providerResponseId',
  'requestedModel',
  'model',
  'thinkingMode',
  'finishReason',
  'latencyMs',
  'visibleHistorySha256',
  'modelInputSha256',
  'requestBodySha256',
  'projectContextReceipt',
] as const;
const projectReceiptKeys = [
  'schema_version',
  'snapshot_id',
  'snapshot_sha256',
  'source_fingerprint',
  'context_bytes',
  'verified_at',
] as const;
const activeRoundKeys = ['roundId', 'roundIndex'] as const;
const attemptReferenceProjectionKeys = [
  'schemaVersion',
  'attemptId',
  'turnId',
  'status',
  'harnessId',
  'visibleMessageIds',
  'visibleHistorySha256',
  'attachmentIds',
  'modelId',
  'thinkingMode',
  'contextDisposition',
  'contextProjectId',
  'workspaceId',
  'workspaceBindingRevision',
  'projectContext',
  'activeRound',
  'rounds',
  'assistantMessageId',
  'failureCode',
  'createdAt',
  'updatedAt',
] as const;

function isAttemptReferenceProjection(value: unknown): boolean {
  if (isExactDataRecord(value, attemptReferenceProjectionKeys)) return true;
  if (
    typeof value !== 'object' ||
    value === null ||
    Array.isArray(value) ||
    Object.getOwnPropertySymbols(value).length > 0
  ) return false;
  const names = Object.getOwnPropertyNames(value);
  const allowed = new Set<string>([
    ...attemptReferenceProjectionKeys,
    'journalRevision',
    'agent',
  ]);
  if (names.some(name => !allowed.has(name))) return false;
  return attemptReferenceProjectionKeys.every(key => {
    const descriptor = Object.getOwnPropertyDescriptor(value, key);
    return (
      descriptor !== undefined &&
      Object.prototype.hasOwnProperty.call(descriptor, 'value') &&
      descriptor.enumerable === true
    );
  });
}
const projectContextScopeKeys = [
  'conversationId',
  'projectId',
  'runtimeContextId',
  'modelId',
  'expectedContext',
] as const;
const replacePreparedContextKeys = [
  'scope',
  'preparationId',
  'selectedPaths',
  'manifest',
  'at',
] as const;
const replaceConfirmedContextKeys = [
  ...replacePreparedContextKeys,
  'consent',
] as const;
const disableContextKeys = ['scope', 'at'] as const;
const destructiveOwnerKeys = [
  'conversationId',
  'projectId',
  'runtimeContextId',
  'modelId',
  'expectedUpdatedAt',
  'expectedContext',
] as const;
const destructiveBeginKeys = [
  'lifecycleId',
  'action',
  'targetProjectId',
  'owner',
  'at',
] as const;
const destructiveAdvanceKeys = ['scope', 'at'] as const;
const destructiveAdvanceScopeKeys = [
  'lifecycleId',
  'epoch',
  'action',
  'targetProjectId',
  'expectedTransition',
] as const;
const destructiveTransitionKeys = [
  'schemaVersion',
  'lifecycleId',
  'epoch',
  'action',
  'phase',
  'conversationId',
  'sourceProjectId',
  'sourceRuntimeContextId',
  'sourceModelId',
  'snapshotId',
  'snapshotSha256',
  'consentReceiptId',
  'targetProjectId',
  'createdAt',
  'updatedAt',
] as const;

function isExactDataRecord(
  value: unknown,
  keys: readonly string[],
): value is Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    return false;
  }
  const prototype = Object.getPrototypeOf(value);
  if (prototype !== Object.prototype && prototype !== null) return false;
  if (Object.getOwnPropertySymbols(value).length > 0) return false;
  const names = Object.getOwnPropertyNames(value);
  if (
    names.length !== keys.length ||
    names.some(name => !keys.includes(name))
  ) {
    return false;
  }
  return keys.every(key => {
    const descriptor = Object.getOwnPropertyDescriptor(value, key);
    return (
      descriptor !== undefined &&
      Object.prototype.hasOwnProperty.call(descriptor, 'value') &&
      descriptor.enumerable === true
    );
  });
}

function isExactDataRecordWithOptional(
  value: unknown,
  keys: readonly string[],
  optionalKeys: readonly string[],
): value is Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return false;
  const prototype = Object.getPrototypeOf(value);
  if (prototype !== Object.prototype && prototype !== null) return false;
  if (Object.getOwnPropertySymbols(value).length > 0) return false;
  const allowed = new Set([...keys, ...optionalKeys]);
  const names = Object.getOwnPropertyNames(value);
  if (names.some(name => !allowed.has(name))) return false;
  return keys.every(key => {
    const descriptor = Object.getOwnPropertyDescriptor(value, key);
    return (
      descriptor !== undefined &&
      Object.prototype.hasOwnProperty.call(descriptor, 'value') &&
      descriptor.enumerable === true
    );
  }) && optionalKeys.every(key => {
    const descriptor = Object.getOwnPropertyDescriptor(value, key);
    return (
      descriptor === undefined ||
      (Object.prototype.hasOwnProperty.call(descriptor, 'value') &&
        descriptor.enumerable === true)
    );
  });
}

function isExactDataArray(value: unknown, maximum: number): value is unknown[] {
  if (
    !Array.isArray(value) ||
    Object.getPrototypeOf(value) !== Array.prototype ||
    Object.getOwnPropertySymbols(value).length > 0
  ) return false;
  const lengthDescriptor = Object.getOwnPropertyDescriptor(value, 'length');
  if (
    lengthDescriptor === undefined ||
    !Object.prototype.hasOwnProperty.call(lengthDescriptor, 'value') ||
    typeof lengthDescriptor.value !== 'number' ||
    !Number.isSafeInteger(lengthDescriptor.value) ||
    Object.is(lengthDescriptor.value, -0) ||
    lengthDescriptor.value < 0 ||
    lengthDescriptor.value > maximum
  ) return false;
  const length = lengthDescriptor.value;
  const names = Object.getOwnPropertyNames(value);
  if (names.length !== length + 1) return false;
  for (let index = 0; index < length; index += 1) {
    const descriptor = Object.getOwnPropertyDescriptor(value, String(index));
    if (
      descriptor === undefined ||
      !Object.prototype.hasOwnProperty.call(descriptor, 'value') ||
      descriptor.enumerable !== true
    ) return false;
  }
  return names.every(
    name => name === 'length' || /^(?:0|[1-9][0-9]*)$/u.test(name),
  );
}

function workspaceBindingIsValid(
  value: unknown,
): value is ConversationWorkspaceBindingV1 {
  if (!isExactDataRecord(value, workspaceBindingKeys)) return false;
  const binding = value as ConversationWorkspaceBindingV1;
  return (
    binding.schemaVersion === CONVERSATION_WORKSPACE_BINDING_SCHEMA_VERSION &&
    isCanonicalLifecycleId(binding.workspaceId) &&
    Number.isSafeInteger(binding.bindingRevision) &&
    !Object.is(binding.bindingRevision, -0) &&
    binding.bindingRevision > 0 &&
    binding.bindingRevision < Number.MAX_SAFE_INTEGER &&
    (binding.projectId === null || isProjectId(binding.projectId))
  );
}

export function isConversationWorkspaceBootstrapState(
  value: unknown,
): value is ConversationWorkspaceBootstrapState {
  return typeof value === 'string' && workspaceBootstrapStates.has(value);
}

export function isWorkspaceAuthorityOutboxEntry(
  value: unknown,
): value is WorkspaceAuthorityOutboxV1 {
  if (!isExactDataRecord(value, workspaceOutboxKeys)) return false;
  const entry = value as WorkspaceAuthorityOutboxV1;
  return (
    entry.schemaVersion === WORKSPACE_AUTHORITY_OUTBOX_SCHEMA_VERSION &&
    isCanonicalLifecycleId(entry.operationId) &&
    (entry.action === 'forget' || entry.action === 'delete_owned') &&
    isCanonicalLifecycleId(entry.workspaceId) &&
    Number.isSafeInteger(entry.bindingRevision) &&
    !Object.is(entry.bindingRevision, -0) &&
    entry.bindingRevision > 0 &&
    entry.bindingRevision < Number.MAX_SAFE_INTEGER &&
    isCanonicalLifecycleId(entry.clearanceReceiptId) &&
    isCanonicalTimestamp(entry.createdAt)
  );
}

function copyWorkspaceBinding(
  binding: ConversationWorkspaceBindingV1 | null,
): ConversationWorkspaceBindingV1 | null {
  return binding === null
    ? null
    : {
        schemaVersion: binding.schemaVersion,
        workspaceId: binding.workspaceId,
        bindingRevision: binding.bindingRevision,
        projectId: binding.projectId,
      };
}


export function createEmptyChatState(): ChatState {
  const preferences = JSON.parse(
    serializeAppPreferences(DEFAULT_APP_PREFERENCES),
  ) as ChatState['preferences'];
  return {
    schemaVersion: CHAT_STATE_SCHEMA_VERSION,
    workspaceAuthorityOutbox: [],
    agentTranscriptCleanupOutbox: [],
    sessionEvents: [],
    projectContextDestructiveEpoch: 0,
    projectContextDestructiveTransition: null,
    conversations: {},
    conversationOrder: [],
    selectedConversationId: null,
    preferences,
  };
}

export function isModelId(value: unknown): value is ModelId {
  return typeof value === 'string' && isHarnessModelId(value);
}

export function isConversationThinkingMode(
  value: unknown,
): value is ConversationThinkingMode {
  return typeof value === 'string' && thinkingModes.has(value);
}

export function isChatAttachmentKind(
  value: unknown,
): value is ChatAttachmentKind {
  return typeof value === 'string' && attachmentKinds.has(value);
}

export function isAttachmentMimeType(
  value: unknown,
  kind: ChatAttachmentKind,
): value is string {
  if (
    typeof value !== 'string' ||
    value.length === 0 ||
    value.length > MAX_ATTACHMENT_MIME_TYPE_LENGTH ||
    !mimeTypePattern.test(value)
  ) {
    return false;
  }

  const normalized = value.toLowerCase();
  switch (kind) {
    case 'image':
      return normalized.startsWith('image/');
    case 'text':
      return normalized.startsWith('text/');
    case 'pdf':
      return normalized === 'application/pdf';
  }
}

export function isAttachmentSize(
  value: unknown,
  kind: ChatAttachmentKind,
): value is number {
  const maximum =
    kind === 'text' ? MAX_TEXT_ATTACHMENT_SIZE : MAX_BINARY_ATTACHMENT_SIZE;
  return (
    typeof value === 'number' &&
    Number.isSafeInteger(value) &&
    value > 0 &&
    value <= maximum
  );
}

export function isChatAttachment(value: unknown): value is ChatAttachment {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    return false;
  }
  const attachment = value as Partial<ChatAttachment>;
  return (
    attachment.schema_version === ATTACHMENT_DESCRIPTOR_SCHEMA_VERSION &&
    typeof attachment.id === 'string' &&
    validIdentifier(attachment.id) &&
    attachment.id.length <= MAX_ATTACHMENT_ID_LENGTH &&
    isChatAttachmentKind(attachment.kind) &&
    typeof attachment.name === 'string' &&
    attachment.name.trim().length > 0 &&
    attachment.name.length <= MAX_ATTACHMENT_NAME_LENGTH &&
    !attachment.name.includes('\0') &&
    isAttachmentMimeType(attachment.mime_type, attachment.kind) &&
    isAttachmentSize(attachment.size, attachment.kind) &&
    (attachment.thumbnail_data_url === undefined ||
      typeof attachment.thumbnail_data_url === 'string')
  );
}

export function areValidChatAttachments(
  value: unknown,
): value is readonly ChatAttachment[] {
  if (!Array.isArray(value) || value.length > MAX_ATTACHMENTS_PER_MESSAGE) {
    return false;
  }

  const ids = new Set<string>();
  let totalSize = 0;
  for (const attachment of value) {
    if (!isChatAttachment(attachment) || ids.has(attachment.id)) {
      return false;
    }
    ids.add(attachment.id);
    totalSize += attachment.size;
    if (totalSize > MAX_TOTAL_ATTACHMENT_SIZE) {
      return false;
    }
  }
  return true;
}

export function isCanonicalTimestamp(value: unknown): value is string {
  if (typeof value !== 'string') {
    return false;
  }
  const milliseconds = Date.parse(value);
  return (
    Number.isFinite(milliseconds) &&
    new Date(milliseconds).toISOString() === value
  );
}

export function isCanonicalLifecycleId(value: unknown): value is string {
  return typeof value === 'string' && canonicalUuidPattern.test(value);
}

export function isSha256Digest(value: unknown): value is string {
  return typeof value === 'string' && sha256Pattern.test(value);
}

export function isAttemptFailureCode(
  value: unknown,
): value is AttemptFailureCode {
  return typeof value === 'string' && attemptFailureCodes.has(value);
}

function isOpaqueProviderId(value: unknown): value is string {
  return (
    typeof value === 'string' &&
    value.length > 0 &&
    value.length <= 128 &&
    opaqueIdPattern.test(value)
  );
}

function hasSameStrings(
  left: readonly string[],
  right: readonly string[],
): boolean {
  return (
    left.length === right.length &&
    left.every((value, index) => value === right[index])
  );
}

function visibleAttachmentSummary(messages: readonly ChatMessage[]): {
  readonly ids: readonly string[];
  readonly occurrences: number;
  readonly bytes: number;
} {
  const ids: string[] = [];
  const seen = new Set<string>();
  let occurrences = 0;
  let bytes = 0;
  messages.forEach(message => {
    message.attachments.forEach(attachment => {
      occurrences += 1;
      bytes += attachment.size;
      if (seen.has(attachment.id)) return;
      seen.add(attachment.id);
      ids.push(attachment.id);
    });
  });
  return { ids, occurrences, bytes };
}

function hasLiveAttempt(conversation: Conversation): boolean {
  return conversation.attempts.some(
    attempt => attempt.status === 'prepared' || attempt.status === 'sending',
  );
}

function hasAgentRecoveryOwner(conversation: Conversation): boolean {
  return conversation.attempts.some(
    attempt => attempt.agent !== undefined && attempt.agent !== null,
  );
}

function hasAgentJournalOrReceipt(attempt: TurnAttemptV1): boolean {
  return attempt.agent !== undefined && attempt.agent !== null;
}

function conversationWorkspaceStateIsValid(
  conversation: Conversation,
): boolean {
  const binding = conversation.workspaceBinding ?? null;
  const bootstrapState = conversation.workspaceBootstrapState ?? 'none';
  if (!isConversationWorkspaceBootstrapState(bootstrapState)) {
    return false;
  }
  if (binding === null) {
    return (
      conversation.workspaceId === null ||
      bootstrapState !== 'none'
    );
  }
  return (
    workspaceBindingIsValid(binding) &&
    bootstrapState === 'none' &&
    conversation.workspaceId === binding.workspaceId &&
    conversation.projectId === binding.projectId
  );
}

function attemptWorkspaceBindingIsValid(
  conversation: Conversation,
  attempt: TurnAttemptV1,
): boolean {
  const conversationBinding = conversation.workspaceBinding ?? null;
  if (
    attempt.workspaceId === null ||
    attempt.workspaceBindingRevision === null
  ) {
    return (
      attempt.workspaceId === null &&
      attempt.workspaceBindingRevision === null &&
      (conversationBinding === null ||
        (attempt.status !== 'prepared' && attempt.status !== 'sending'))
    );
  }
  return (
    conversationBinding !== null &&
    conversationWorkspaceStateIsValid(conversation) &&
    attempt.workspaceId === conversationBinding.workspaceId &&
    attempt.workspaceBindingRevision === conversationBinding.bindingRevision &&
    attempt.contextProjectId === conversationBinding.projectId
  );
}

function attemptBindingIsValid(
  conversation: Conversation,
  attempt: TurnAttemptV1,
): boolean {
  if (
    (typeof conversation.workspaceBootstrapState === 'string' &&
      conversation.workspaceBootstrapState.startsWith('blocked_')) ||
    !conversationWorkspaceStateIsValid(conversation) ||
    !attemptWorkspaceBindingIsValid(conversation, attempt)
  ) {
    return false;
  }
  const binding = attempt.projectContext;
  if (binding !== null && !isExactDataRecord(binding, attemptBindingKeys)) {
    return false;
  }
  if (attempt.contextDisposition === 'unbound') {
    return (
      conversation.projectId === null &&
      attempt.contextProjectId === null &&
      binding === null
    );
  }
  if (attempt.contextDisposition === 'explicit_without_context') {
    return (
      conversation.projectId !== null &&
      attempt.contextProjectId === conversation.projectId &&
      binding === null
    );
  }
  if (attempt.contextDisposition !== 'verified') {
    return false;
  }
  const context = conversation.projectContext;
  return (
    conversation.projectId !== null &&
    attempt.contextProjectId === conversation.projectId &&
    binding !== null &&
    context !== null &&
    isProjectContextSendable(context) &&
    conversation.runtimeContextId !== null &&
    binding.schemaVersion === ATTEMPT_PROJECT_CONTEXT_SCHEMA_VERSION &&
    binding.runtimeContextId === conversation.runtimeContextId &&
    binding.projectId === conversation.projectId &&
    binding.snapshotId === context.snapshot?.snapshot_id &&
    binding.snapshotSha256 === context.snapshot?.snapshot_sha256 &&
    binding.sourceFingerprint === context.snapshot?.source_fingerprint &&
    binding.contextBytes === context.snapshot?.context_bytes &&
    binding.consentReceiptId === context.consent?.consent_receipt_id &&
    context.snapshot !== null &&
    binding.provider === providerForModel(context.snapshot.model) &&
    binding.policy === 'chat-read-v1' &&
    binding.policyVersion === 'chat-read-v1.0.0' &&
    binding.policyVersion === context.snapshot?.policy_version &&
    isCanonicalLifecycleId(binding.runtimeContextId) &&
    isCanonicalLifecycleId(binding.snapshotId) &&
    isCanonicalLifecycleId(binding.consentReceiptId) &&
    isSha256Digest(binding.snapshotSha256) &&
    isSha256Digest(binding.sourceFingerprint) &&
    Number.isSafeInteger(binding.contextBytes) &&
    binding.contextBytes > 0 &&
    binding.contextBytes <= MAX_PROJECT_CONTEXT_RECEIPT_BYTES
  );
}

function preparedAttemptIsApplicable(
  conversation: Conversation,
  attempt: TurnAttemptV1,
): boolean {
  const visible = conversation.messages.slice(-MAX_ATTEMPT_VISIBLE_MESSAGES);
  const attachments = visibleAttachmentSummary(visible);
  return (
    attempt.modelId === conversation.modelId &&
    attempt.thinkingMode === conversation.thinkingMode &&
    hasSameStrings(
      attempt.visibleMessageIds,
      visible.map(message => message.id),
    ) &&
    hasSameStrings(attempt.attachmentIds, attachments.ids) &&
    attachments.occurrences <= MAX_ATTEMPT_ATTACHMENT_IDS &&
    attachments.bytes <= MAX_TOTAL_ATTACHMENT_SIZE &&
    attemptBindingIsValid(conversation, attempt)
  );
}

function sameAttemptBinding(
  left: TurnAttemptV1['projectContext'],
  right: TurnAttemptV1['projectContext'],
): boolean {
  if (
    (left !== null && !isExactDataRecord(left, attemptBindingKeys)) ||
    (right !== null && !isExactDataRecord(right, attemptBindingKeys))
  ) {
    return false;
  }
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

function copyAttemptBinding(
  binding: TurnAttemptV1['projectContext'],
): TurnAttemptV1['projectContext'] {
  return binding === null
    ? null
    : {
        schemaVersion: binding.schemaVersion,
        runtimeContextId: binding.runtimeContextId,
        projectId: binding.projectId,
        snapshotId: binding.snapshotId,
        snapshotSha256: binding.snapshotSha256,
        sourceFingerprint: binding.sourceFingerprint,
        contextBytes: binding.contextBytes,
        consentReceiptId: binding.consentReceiptId,
        provider: binding.provider,
        policy: binding.policy,
        policyVersion: binding.policyVersion,
      };
}

function copyRoundReceipt(
  receipt: CompletionRoundReceiptV1,
): CompletionRoundReceiptV1 {
  const projectContextReceipt =
    receipt.projectContextReceipt === null
      ? null
      : {
          schema_version: receipt.projectContextReceipt.schema_version,
          snapshot_id: receipt.projectContextReceipt.snapshot_id,
          snapshot_sha256: receipt.projectContextReceipt.snapshot_sha256,
          source_fingerprint:
            receipt.projectContextReceipt.source_fingerprint,
          context_bytes: receipt.projectContextReceipt.context_bytes,
          verified_at: receipt.projectContextReceipt.verified_at,
        };
  return {
    schemaVersion: receipt.schemaVersion,
    transportSchemaVersion: receipt.transportSchemaVersion,
    turnId: receipt.turnId,
    attemptId: receipt.attemptId,
    roundId: receipt.roundId,
    roundIndex: receipt.roundIndex,
    providerRequestId: receipt.providerRequestId,
    providerResponseId: receipt.providerResponseId,
    harnessId: receipt.harnessId,
    ...(receipt.providerConfiguration === undefined ? {} : { providerConfiguration: { ...receipt.providerConfiguration } }),
    requestedModel: receipt.requestedModel,
    model: receipt.model,
    thinkingMode: receipt.thinkingMode,
    finishReason: receipt.finishReason,
    latencyMs: receipt.latencyMs,
    visibleHistorySha256: receipt.visibleHistorySha256,
    modelInputSha256: receipt.modelInputSha256,
    requestBodySha256: receipt.requestBodySha256,
    projectContextReceipt,
  };
}

function copyAttempt(attempt: TurnAttemptV1): TurnAttemptV1 {
  return {
    schemaVersion: attempt.schemaVersion,
    attemptId: attempt.attemptId,
    turnId: attempt.turnId,
    status: attempt.status,
    harnessId: attempt.harnessId,
    visibleMessageIds: [...attempt.visibleMessageIds],
    visibleHistorySha256: attempt.visibleHistorySha256,
    attachmentIds: [...attempt.attachmentIds],
    modelId: attempt.modelId,
    thinkingMode: attempt.thinkingMode,
    contextDisposition: attempt.contextDisposition,
    contextProjectId: attempt.contextProjectId,
    workspaceId: attempt.workspaceId,
    workspaceBindingRevision: attempt.workspaceBindingRevision,
    projectContext: copyAttemptBinding(attempt.projectContext),
    activeRound:
      attempt.activeRound === null
        ? null
        : {
            roundId: attempt.activeRound.roundId,
            roundIndex: attempt.activeRound.roundIndex,
          },
    rounds: attempt.rounds.map(copyRoundReceipt),
    assistantMessageId: attempt.assistantMessageId,
    failureCode: attempt.failureCode,
    createdAt: attempt.createdAt,
    updatedAt: attempt.updatedAt,
    ...(attempt.journalRevision === undefined
      ? {}
      : { journalRevision: attempt.journalRevision }),
    ...(attempt.agent === undefined
      ? {}
      : {
          agent:
            attempt.agent === null ? null : copyAgentJournalV3(attempt.agent),
        }),
  };
}

// eslint-disable-next-line @typescript-eslint/no-unused-vars
function copyAgentJournal(
  journal: PersistedAgentAttemptJournalV2,
): PersistedAgentAttemptJournalV2 {
  return {
    schema_version: journal.schema_version,
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
    batch: journal.batch.map(call => ({
      ...call,
      receipt: call.receipt === null ? null : { ...call.receipt },
    })),
    frozen_grant_ids: [...journal.frozen_grant_ids],
    reserved_write_bytes: journal.reserved_write_bytes,
    updated_at: journal.updated_at,
  };
}

function copyAgentJournalV3(
  journal: PersistedAgentAttemptJournalV3,
): PersistedAgentAttemptJournalV3 {
  return {
    schema_version: journal.schema_version,
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
    batch: journal.batch.map(call => ({
      ...call,
      receipt: call.receipt === null ? null : { ...call.receipt },
    })),
    frozen_grant_ids: [...journal.frozen_grant_ids],
    reserved_write_bytes: journal.reserved_write_bytes,
    updated_at: journal.updated_at,
  };
}

function retryBindingIsApplicable(
  conversation: Conversation,
  source: TurnAttemptV1,
): boolean {
  if (
    typeof conversation.workspaceBootstrapState === 'string' &&
    conversation.workspaceBootstrapState.startsWith('blocked_')
  ) {
    return false;
  }
  if (!attemptWorkspaceBindingIsValid(conversation, source)) return false;
  const binding = source.projectContext;
  if (source.contextDisposition === 'unbound') {
    return (
      conversation.projectId === null &&
      source.contextProjectId === null &&
      binding === null
    );
  }
  if (source.contextDisposition === 'explicit_without_context') {
    return (
      conversation.projectId === source.contextProjectId &&
      source.contextProjectId !== null &&
      binding === null
    );
  }
  return (
    source.contextDisposition === 'verified' &&
    binding !== null &&
    source.contextProjectId === binding.projectId &&
    conversation.projectId === binding.projectId &&
    conversation.runtimeContextId === binding.runtimeContextId &&
    conversation.projectContext !== null &&
    isProjectContextSendable(conversation.projectContext) &&
    conversation.projectContext.snapshot?.snapshot_id === binding.snapshotId &&
    conversation.projectContext.snapshot?.snapshot_sha256 ===
      binding.snapshotSha256 &&
    conversation.projectContext.snapshot?.source_fingerprint ===
      binding.sourceFingerprint &&
    conversation.projectContext.snapshot?.context_bytes ===
      binding.contextBytes &&
    conversation.projectContext.snapshot?.policy_version ===
      binding.policyVersion &&
    conversation.projectContext.consent?.consent_receipt_id ===
      binding.consentReceiptId
  );
}

function attemptSupportsExactProjectContextRetry(
  conversation: Conversation,
  attempt: TurnAttemptV1,
  visibleMessageIds: readonly string[],
): boolean {
  return (
    (attempt.status === 'failed' || attempt.status === 'cancelled') &&
    attempt.contextDisposition === 'verified' &&
    attempt.projectContext !== null &&
    hasSameStrings(attempt.visibleMessageIds, visibleMessageIds) &&
    retryBindingIsApplicable(conversation, attempt)
  );
}

function hasContextMutationBlocker(conversation: Conversation): boolean {
  if (hasLiveAttempt(conversation)) return true;
  const visibleMessageIds = conversation.messages
    .slice(-MAX_ATTEMPT_VISIBLE_MESSAGES)
    .map(message => message.id);
  return conversation.attempts.some(
    attempt =>
      attemptSupportsExactProjectContextRetry(
        conversation,
        attempt,
        visibleMessageIds,
      ),
  );
}

function copiedSelectedPaths(value: unknown): string[] | null {
  if (
    !Array.isArray(value) ||
    Object.getPrototypeOf(value) !== Array.prototype ||
    value.length > 5000 ||
    Object.getOwnPropertySymbols(value).length > 0
  ) {
    return null;
  }
  const names = Object.getOwnPropertyNames(value);
  if (
    names.length !== value.length + 1 ||
    names.some(
      name =>
        name !== 'length' &&
        (!/^(?:0|[1-9][0-9]*)$/u.test(name) || Number(name) >= value.length),
    )
  ) {
    return null;
  }
  const copied: string[] = [];
  for (let index = 0; index < value.length; index += 1) {
    const descriptor = Object.getOwnPropertyDescriptor(value, String(index));
    if (
      descriptor === undefined ||
      !Object.prototype.hasOwnProperty.call(descriptor, 'value') ||
      descriptor.enumerable !== true ||
      typeof descriptor.value !== 'string' ||
      descriptor.value.length === 0
    ) {
      return null;
    }
    copied[index] = descriptor.value;
  }
  return copied;
}

function strictProjectContextState(
  candidate: ProjectContextState,
): ProjectContextState | null {
  try {
    return canonicalizeDurableProjectContextState(candidate);
  } catch {
    return null;
  }
}

function normalizedPreparedProjectContext(
  projectId: string,
  preparationId: string,
  selectedPathsValue: unknown,
  manifest: ProjectContextManifestV1,
): ProjectContextState | null {
  const selectedPaths = copiedSelectedPaths(selectedPathsValue);
  if (selectedPaths === null) return null;
  for (const status of ['setup_required', 'partial'] as const) {
    const normalized = strictProjectContextState({
      schemaVersion: 1,
      projectId,
      status,
      selectedPaths,
      activePreparationId: preparationId,
      snapshot: manifest,
      consent: null,
      staleReason: null,
      errorCode: null,
    });
    if (normalized !== null) return normalized;
  }
  return null;
}

function normalizedConfirmedProjectContext(
  projectId: string,
  selectedPathsValue: unknown,
  manifest: ProjectContextManifestV1,
  consent: ProjectContextConsentV1,
): ProjectContextState | null {
  const selectedPaths = copiedSelectedPaths(selectedPathsValue);
  if (selectedPaths === null) return null;
  for (const status of ['ready', 'partial'] as const) {
    const normalized = strictProjectContextState({
      schemaVersion: 1,
      projectId,
      status,
      selectedPaths,
      activePreparationId: null,
      snapshot: manifest,
      consent,
      staleReason: null,
      errorCode: null,
    });
    if (normalized !== null) return normalized;
  }
  return null;
}

function scopedContextConversation(
  state: ChatState,
  scopeValue: unknown,
): Conversation | null {
  if (!isExactDataRecord(scopeValue, projectContextScopeKeys)) return null;
  const scope = scopeValue as ProjectContextMutationScope;
  if (
    typeof scope.conversationId !== 'string' ||
    !validIdentifier(scope.conversationId)
  ) {
    return null;
  }
  const conversation = state.conversations[scope.conversationId];
  if (
    conversation === undefined ||
    conversation.projectId === null ||
    conversation.projectContext === null ||
    !isCanonicalLifecycleId(conversation.projectId) ||
    !isCanonicalLifecycleId(scope.projectId) ||
    !isCanonicalLifecycleId(scope.runtimeContextId) ||
    !isModelId(scope.modelId) ||
    conversation.projectId !== scope.projectId ||
    conversation.runtimeContextId !== scope.runtimeContextId ||
    conversation.modelId !== scope.modelId ||
    conversation.projectContext !== scope.expectedContext ||
    hasContextMutationBlocker(conversation)
  ) {
    return null;
  }
  return conversation;
}

function contextAuthorityMatches(
  conversation: Conversation,
  context: ProjectContextState,
  preparationId: string,
  confirmed: boolean,
): boolean {
  const snapshot = context.snapshot;
  const consent = context.consent;
  return (
    isCanonicalLifecycleId(preparationId) &&
    snapshot !== null &&
    context.projectId === conversation.projectId &&
    snapshot.project_id === conversation.projectId &&
    snapshot.model === conversation.modelId &&
    providerHostMatches(snapshot.model, snapshot.provider_host, snapshot.provider_configuration) &&
    snapshot.policy_version === 'chat-read-v1.0.0' &&
    isCanonicalLifecycleId(snapshot.snapshot_id) &&
    (confirmed
      ? context.activePreparationId === null &&
        consent !== null &&
        isCanonicalLifecycleId(consent.consent_receipt_id) &&
        consent.snapshot_id === snapshot.snapshot_id &&
        consent.snapshot_sha256 === snapshot.snapshot_sha256
      : context.activePreparationId === preparationId && consent === null)
  );
}

function receiptIsValid(
  attempt: TurnAttemptV1,
  receipt: CompletionRoundReceiptV1,
): boolean {
  if (!isExactDataRecordWithOptional(receipt, roundReceiptKeys, ['providerConfiguration'])) return false;
  if (receipt.providerConfiguration !== undefined && parseProviderBinding(receipt.providerConfiguration, receipt.model) === null) return false;
  const binding = attempt.projectContext;
  const projectReceipt = receipt.projectContextReceipt;
  if (
    projectReceipt !== null &&
    !isExactDataRecord(projectReceipt, projectReceiptKeys)
  ) {
    return false;
  }
  const contextMatches =
    attempt.contextDisposition !== 'verified'
      ? receipt.transportSchemaVersion === 2 && projectReceipt === null
      : binding !== null &&
        receipt.transportSchemaVersion === 3 &&
        projectReceipt !== null &&
        projectReceipt.schema_version === 1 &&
        projectReceipt.snapshot_id === binding.snapshotId &&
        projectReceipt.snapshot_sha256 === binding.snapshotSha256 &&
        projectReceipt.source_fingerprint === binding.sourceFingerprint &&
        Number.isSafeInteger(projectReceipt.context_bytes) &&
        projectReceipt.context_bytes > 0 &&
        projectReceipt.context_bytes <= MAX_PROJECT_CONTEXT_RECEIPT_BYTES &&
        projectReceipt.context_bytes === binding.contextBytes &&
        isCanonicalTimestamp(projectReceipt.verified_at);
  return (
    receipt.schemaVersion === COMPLETION_ROUND_RECEIPT_SCHEMA_VERSION &&
    receipt.turnId === attempt.turnId &&
    receipt.attemptId === attempt.attemptId &&
    isCanonicalLifecycleId(receipt.roundId) &&
    Number.isSafeInteger(receipt.roundIndex) &&
    receipt.roundIndex >= 0 &&
    receipt.roundIndex < MAX_COMPLETION_ROUNDS &&
    isOpaqueProviderId(receipt.providerRequestId) &&
    isOpaqueProviderId(receipt.providerResponseId) &&
    receipt.requestedModel === attempt.modelId &&
    receipt.model === attempt.modelId &&
    receipt.thinkingMode === attempt.thinkingMode &&
    finishReasons.has(receipt.finishReason) &&
    Number.isSafeInteger(receipt.latencyMs) &&
    !Object.is(receipt.latencyMs, -0) &&
    receipt.latencyMs >= 0 &&
    isSha256Digest(receipt.visibleHistorySha256) &&
    isSha256Digest(receipt.modelInputSha256) &&
    isSha256Digest(receipt.requestBodySha256) &&
    ((attempt.agent !== undefined && attempt.agent !== null) ||
      attempt.visibleHistorySha256 === null ||
      attempt.visibleHistorySha256 === receipt.visibleHistorySha256) &&
    contextMatches
  );
}

export function deriveAutoTitle(
  text: string,
  maxLength = AUTO_TITLE_MAX_LENGTH,
): string {
  const normalized = text
    .replace(/^\s*#{1,6}\s+/, '')
    .replace(/\s+/gu, ' ')
    .trim();
  if (normalized.length === 0) {
    return DEFAULT_CONVERSATION_TITLE;
  }

  const characters = Array.from(normalized);
  if (characters.length <= maxLength) {
    return normalized;
  }

  const visibleLength = Math.max(1, maxLength - 1);
  return `${characters.slice(0, visibleLength).join('').trimEnd()}…`;
}

export function orderConversationIds(
  conversations: Readonly<Record<string, Conversation>>,
): string[] {
  return Object.values(conversations)
    .sort((left, right) => {
      const updatedDifference =
        Date.parse(right.updatedAt) - Date.parse(left.updatedAt);
      if (updatedDifference !== 0) {
        return updatedDifference;
      }

      const createdDifference =
        Date.parse(right.createdAt) - Date.parse(left.createdAt);
      if (createdDifference !== 0) {
        return createdDifference;
      }

      return left.id < right.id ? -1 : left.id > right.id ? 1 : 0;
    })
    .map(conversation => conversation.id);
}

export function selectConversationById(
  state: ChatState,
  id: string,
): Conversation | null {
  return state.conversations[id] ?? null;
}

export function selectOrderedConversations(state: ChatState): Conversation[] {
  return state.conversationOrder.flatMap(id => {
    const conversation = state.conversations[id];
    return conversation === undefined ? [] : [conversation];
  });
}

export function selectActiveConversation(
  state: ChatState,
): Conversation | null {
  return state.selectedConversationId === null
    ? null
    : selectConversationById(state, state.selectedConversationId);
}

export function selectActiveMessages(state: ChatState): readonly ChatMessage[] {
  return selectActiveConversation(state)?.messages ?? [];
}

export type ProjectContextSnapshotReference = {
  readonly conversationId: string;
  readonly attemptId: string;
  readonly kind: 'prepared' | 'sending' | 'retryable';
};

function verifiedAttemptSnapshotId(attempt: TurnAttemptV1): string | null {
  const binding = attempt.projectContext;
  if (
    attempt.contextDisposition !== 'verified' ||
    binding === null ||
    !isExactDataRecord(binding, attemptBindingKeys) ||
    binding.schemaVersion !== ATTEMPT_PROJECT_CONTEXT_SCHEMA_VERSION ||
    !isCanonicalLifecycleId(binding.runtimeContextId) ||
    !isCanonicalLifecycleId(binding.projectId) ||
    !isCanonicalLifecycleId(binding.snapshotId) ||
    !isSha256Digest(binding.snapshotSha256) ||
    !isSha256Digest(binding.sourceFingerprint) ||
    !Number.isSafeInteger(binding.contextBytes) ||
    binding.contextBytes < 1 ||
    binding.contextBytes > MAX_PROJECT_CONTEXT_RECEIPT_BYTES ||
    !isCanonicalLifecycleId(binding.consentReceiptId) ||
    !isProviderId(binding.provider) ||
    binding.policy !== 'chat-read-v1' ||
    binding.policyVersion !== 'chat-read-v1.0.0'
  ) {
    return null;
  }
  return binding.snapshotId;
}

/**
 * Metadata-only references used to guard snapshot replacement and cleanup.
 * Invalid external state or identifiers return no projected rows and never
 * expose the frozen binding itself.
 */
export function selectProjectContextSnapshotReferences(
  state: ChatState,
  conversationId: string,
  snapshotId?: string,
): readonly ProjectContextSnapshotReference[] {
  if (
    typeof conversationId !== 'string' ||
    !validIdentifier(conversationId) ||
    (snapshotId !== undefined &&
      (typeof snapshotId !== 'string' ||
        !isCanonicalLifecycleId(snapshotId)))
  ) {
    return [];
  }
  try {
    if (typeof state !== 'object' || state === null) return [];
    const conversation = state.conversations[conversationId];
    if (
      conversation === undefined ||
      conversation.id !== conversationId ||
      !Array.isArray(conversation.attempts) ||
      Object.getPrototypeOf(conversation.attempts) !== Array.prototype ||
      conversation.attempts.length >
        MAX_PROJECT_CONTEXT_SNAPSHOT_REFERENCE_SCAN ||
      Object.getOwnPropertySymbols(conversation.attempts).length > 0
    ) {
      return [];
    }
    const visibleMessageIds = conversation.messages
      .slice(-MAX_ATTEMPT_VISIBLE_MESSAGES)
      .map(message => message.id);
    const rows: ProjectContextSnapshotReference[] = [];
    for (
      let index = 0;
      index < conversation.attempts.length;
      index += 1
    ) {
      const descriptor = Object.getOwnPropertyDescriptor(
        conversation.attempts,
        String(index),
      );
      if (
        descriptor === undefined ||
        !Object.prototype.hasOwnProperty.call(descriptor, 'value') ||
        descriptor.enumerable !== true ||
        !isAttemptReferenceProjection(descriptor.value)
      ) {
        return [];
      }
      const attempt = descriptor.value as TurnAttemptV1;
      if (!isCanonicalLifecycleId(attempt.attemptId)) return [];
      const bindingSnapshotId = verifiedAttemptSnapshotId(attempt);
      if (
        bindingSnapshotId === null ||
        (snapshotId !== undefined && bindingSnapshotId !== snapshotId)
      ) {
        continue;
      }
      const kind =
        attempt.status === 'prepared'
          ? 'prepared'
          : attempt.status === 'sending'
            ? 'sending'
            : attemptSupportsExactProjectContextRetry(
                  conversation,
                  attempt,
                  visibleMessageIds,
                )
              ? 'retryable'
              : null;
      if (
        kind !== null &&
        rows.length < MAX_PROJECT_CONTEXT_SNAPSHOT_REFERENCE_ROWS
      ) {
        rows.push({ conversationId, attemptId: attempt.attemptId, kind });
      }
    }
    return rows;
  } catch {
    return [];
  }
}

export function hasProjectContextDestructiveReferences(
  state: ChatState,
  transition: ProjectContextDestructiveTransitionV1,
): boolean {
  try {
    const conversation = state.conversations[transition.conversationId];
    if (
      conversation === undefined ||
      !Array.isArray(conversation.attempts) ||
      Object.getPrototypeOf(conversation.attempts) !== Array.prototype ||
      conversation.attempts.length >
        MAX_PROJECT_CONTEXT_SNAPSHOT_REFERENCE_SCAN ||
      Object.getOwnPropertySymbols(conversation.attempts).length > 0
    ) {
      return true;
    }
    const visibleMessageIds = conversation.messages
      .slice(-MAX_ATTEMPT_VISIBLE_MESSAGES)
      .map(message => message.id);
    for (let index = 0; index < conversation.attempts.length; index += 1) {
      const descriptor = Object.getOwnPropertyDescriptor(
        conversation.attempts,
        String(index),
      );
      if (
        descriptor === undefined ||
        !Object.prototype.hasOwnProperty.call(descriptor, 'value') ||
        descriptor.enumerable !== true ||
        !isAttemptReferenceProjection(descriptor.value)
      ) {
        return true;
      }
      const attempt = descriptor.value as TurnAttemptV1;
      if (!attemptStatuses.has(attempt.status)) return true;
      if (attempt.contextDisposition === 'unbound') {
        if (
          attempt.contextProjectId !== null ||
          attempt.projectContext !== null
        ) {
          return true;
        }
        continue;
      }
      if (attempt.contextDisposition === 'explicit_without_context') {
        if (
          attempt.contextProjectId === null ||
          attempt.contextProjectId !== conversation.projectId ||
          attempt.projectContext !== null
        ) {
          return true;
        }
        continue;
      }
      if (attempt.contextDisposition !== 'verified') return true;
      if (
        attempt.projectContext === null ||
        !isExactDataRecord(attempt.projectContext, attemptBindingKeys) ||
        verifiedAttemptSnapshotId(attempt) === null
      ) {
        return true;
      }
      if (attempt.projectContext.snapshotId !== transition.snapshotId) continue;
      if (attempt.status === 'prepared' || attempt.status === 'sending') {
        return true;
      }
      if (
        (attempt.status === 'failed' || attempt.status === 'cancelled') &&
        hasSameStrings(attempt.visibleMessageIds, visibleMessageIds)
      ) {
        return true;
      }
    }
    return false;
  } catch {
    return true;
  }
}

/**
 * Returns true when any durable chat-owned row still names a workspace. The
 * authority outbox is only safe once this is false; callers use it before
 * handing a clearance receipt to native code.
 */
export function hasWorkspaceAuthorityReferences(
  state: ChatState,
  workspaceId: string,
): boolean {
  try {
    if (!isCanonicalLifecycleId(workspaceId)) return true;
    return Object.values(state.conversations).some(conversation => {
      if (
        conversation.workspaceId === workspaceId ||
        conversation.workspaceBinding?.workspaceId === workspaceId
      ) {
        return true;
      }
      return conversation.attempts.some(
        attempt => attempt.workspaceId === workspaceId,
      );
    });
  } catch {
    return true;
  }
}

function hasWorkspaceAuthorityOutboxEntry(
  state: ChatState,
  workspaceId: string | null | undefined,
): boolean {
  return (
    workspaceId !== null &&
    workspaceId !== undefined &&
    (state.workspaceAuthorityOutbox ?? []).some(
      entry => entry.workspaceId === workspaceId,
    )
  );
}

function validIdentifier(value: unknown): value is string {
  return (
    typeof value === 'string' &&
    value.trim().length > 0 &&
    value.length <= 256
  );
}

const agentPhaseValues = new Set<PersistedAgentAttemptJournalV2['phase']>([
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
const agentAccessValues = new Set<AgentAccess>([
  'auto',
  'conversation_confirm',
  'confirm_once',
  'durable_deny',
]);
const agentDecisionValues = new Set<AgentApprovalDecision>([
  'pending',
  'denied',
  'allow_once',
  'allow_conversation',
  'cancelled',
]);
const agentStatusValues = new Set<SessionEventV2['status']>([
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
const safeSummaryKeys = new Set<string>(AGENT_SAFE_SUMMARY_KEYS);
const isAgentRegistryVersion = (value: unknown): value is AgentRegistryVersion =>
  value === 1 || value === 2 || value === 3;

export function isAgentFailureCode(value: unknown): value is AgentFailureCode {
  return (
    typeof value === 'string' &&
    [
      'E_AGENT_UNKNOWN_TOOL',
      'E_AGENT_BAD_ARGUMENTS',
      'E_AGENT_BAD_PATH',
      'E_AGENT_NO_ROOT',
      'E_AGENT_ROOT_STALE',
      'E_AGENT_CAPABILITY',
      'E_AGENT_APPROVAL',
      'E_AGENT_TRANSCRIPT',
      'E_AGENT_LEDGER',
      'E_AGENT_ROUND_AMBIGUOUS',
      'E_AGENT_EXECUTION_AMBIGUOUS',
      'E_AGENT_RETRY_LINEAGE',
      'E_AGENT_PERSISTENCE',
      'E_AGENT_CONFLICT',
      'E_AGENT_ROUND_LIMIT',
      'E_AGENT_CANCELLED',
      'E_AGENT_TOOL_FAILED',
      'E_AGENT_DENIED_BY_USER',
      'E_COMPLETION_LENGTH',
      'E_COMPLETION_CONTENT_FILTER',
    ].includes(value)
  );
}

function agentRootIsValid(value: unknown): value is FrozenAgentRootV1 {
  if (!isExactDataRecord(value, [
    'schema_version',
    'kind',
    'workspace_id',
    'workspace_binding_revision',
    'project_id',
    'root_fingerprint_sha256',
    'capabilities',
  ])) return false;
  const root = value as FrozenAgentRootV1;
  if (
    root.schema_version !== 1 ||
    (root.kind !== 'project' && root.kind !== 'workspace') ||
    !isCanonicalLifecycleId(root.workspace_id) ||
    !Number.isSafeInteger(root.workspace_binding_revision) ||
    Object.is(root.workspace_binding_revision, -0) ||
    root.workspace_binding_revision < 1 ||
    root.workspace_binding_revision >= Number.MAX_SAFE_INTEGER ||
    !isSha256Digest(root.root_fingerprint_sha256) ||
    (root.kind === 'project') !== (root.project_id !== null) ||
    (root.project_id !== null && !isCanonicalLifecycleId(root.project_id)) ||
    !isExactDataArray(root.capabilities, 6)
  ) return false;
  const capabilities = new Set<string>();
  for (const capability of root.capabilities) {
    if (
      typeof capability !== 'string' ||
      ![
        'file_read',
        'file_write',
        'git_status',
        'git_commit',
        'git_push',
        'guest_service',
      ].includes(capability) ||
      capabilities.has(capability) ||
      (root.kind === 'workspace' && capability.startsWith('git_'))
    ) return false;
    capabilities.add(capability);
  }
  return true;
}

export const isFrozenAgentRoot = agentRootIsValid;

function agentPolicyIsValid(value: unknown): value is AgentWritePolicyV1 {
  if (!isExactDataRecord(value, [
    'schema_version',
    'policy_version',
    'max_single_write_bytes',
    'max_batch_write_bytes',
    'max_attempt_write_bytes',
  ])) return false;
  const policy = value as AgentWritePolicyV1;
  return (
    policy.schema_version === 1 &&
    validIdentifier(policy.policy_version) &&
    policy.max_single_write_bytes === MAX_AGENT_SINGLE_WRITE_BYTES &&
    Number.isSafeInteger(policy.max_batch_write_bytes) &&
    !Object.is(policy.max_batch_write_bytes, -0) &&
    policy.max_batch_write_bytes >= MAX_AGENT_SINGLE_WRITE_BYTES &&
    policy.max_batch_write_bytes <= MAX_AGENT_BATCH_WRITE_BYTES &&
    Number.isSafeInteger(policy.max_attempt_write_bytes) &&
    !Object.is(policy.max_attempt_write_bytes, -0) &&
    policy.max_attempt_write_bytes >= policy.max_batch_write_bytes &&
    policy.max_attempt_write_bytes <= MAX_AGENT_ATTEMPT_WRITE_BYTES
  );
}

export const isAgentWritePolicy = agentPolicyIsValid;

function agentTranscriptIsValid(value: unknown): value is AgentTranscriptReferenceV1 {
  if (!isExactDataRecord(value, [
    'schema_version',
    'transcript_ref',
    'generation',
    'transcript_sha256',
    'transcript_bytes',
  ])) return false;
  const transcript = value as AgentTranscriptReferenceV1;
  return (
    transcript.schema_version === 1 &&
    isCanonicalLifecycleId(transcript.transcript_ref) &&
    Number.isSafeInteger(transcript.generation) &&
    !Object.is(transcript.generation, -0) &&
    transcript.generation >= 0 &&
    isSha256Digest(transcript.transcript_sha256) &&
    Number.isSafeInteger(transcript.transcript_bytes) &&
    !Object.is(transcript.transcript_bytes, -0) &&
    transcript.transcript_bytes >= 0
    && transcript.transcript_bytes <= MAX_AGENT_TRANSCRIPT_BYTES
  );
}

export const isAgentTranscriptReference = agentTranscriptIsValid;

function agentReceiptIsValid(value: unknown): value is AgentToolReceiptV1 {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return false;
  if (!isExactDataRecord(value, [
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
  ])) return false;
  const receipt = value as AgentToolReceiptV1;
  return (
    receipt.schema_version === 1 &&
    isOpaqueProviderId(receipt.call_id) &&
    typeof receipt.name === 'string' &&
    receipt.name.length > 0 &&
    receipt.name.length <= 64 &&
    /^[\x21-\x7e]+$/u.test(receipt.name) &&
    isSha256Digest(receipt.arguments_sha256) &&
    isSha256Digest(receipt.result_sha256) &&
    Number.isSafeInteger(receipt.result_bytes) &&
    !Object.is(receipt.result_bytes, -0) &&
    receipt.result_bytes >= 0 &&
    receipt.result_bytes <= MAX_AGENT_RESULT_BYTES &&
    typeof receipt.truncated === 'boolean' &&
    Number.isSafeInteger(receipt.duration_ms) &&
    !Object.is(receipt.duration_ms, -0) &&
    receipt.duration_ms >= 0 &&
    receipt.duration_ms <= MAX_AGENT_DURATION_MS &&
    (receipt.outcome === 'ok' ||
      receipt.outcome === 'failed' ||
      receipt.outcome === 'denied' ||
      receipt.outcome === 'cancelled' ||
      receipt.outcome === 'ambiguous') &&
    (receipt.failure_code === null || isAgentFailureCode(receipt.failure_code)) &&
    (receipt.approval_reference === null || validIdentifier(receipt.approval_reference)) &&
    (receipt.outcome !== 'ok' || receipt.failure_code === null) &&
    (receipt.outcome !== 'ambiguous' || receipt.failure_code === 'E_AGENT_EXECUTION_AMBIGUOUS')
  );
}

export const isAgentToolReceipt = agentReceiptIsValid;

function agentApprovalTokenIsValid(
  value: unknown,
  call: Pick<
    PersistedAgentCallJournalV2,
    'call_id' | 'name' | 'arguments_sha256' | 'access'
  >,
  index: number,
  journal?: PersistedAgentAttemptJournalV2,
): value is AgentApprovalTokenV1 {
  if (!isExactDataRecord(value, [
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
  ])) return false;
  const token = value as unknown as AgentApprovalTokenV1;
  const allowed =
    call.access === 'conversation_confirm'
      ? ['denied', 'allow_once', 'allow_conversation', 'cancelled']
      : call.access === 'confirm_once'
        ? ['denied', 'allow_once', 'cancelled']
        : null;
  if (
    allowed === null ||
    token.schema_version !== 1 ||
    !agentControllerCASIsValid(token.controller_cas) ||
    !isCanonicalLifecycleId(token.round_id) ||
    !Number.isSafeInteger(token.round_index) ||
    Object.is(token.round_index, -0) ||
    token.round_index < 0 ||
    token.round_index >= MAX_AGENT_ROUNDS ||
    !isExactDataArray(token.batch_call_ids, MAX_AGENT_CALLS_PER_BATCH) ||
    !isExactDataArray(token.batch_arguments_sha256, MAX_AGENT_CALLS_PER_BATCH) ||
    token.batch_call_ids.length < 1 ||
    token.batch_call_ids.length !== token.batch_arguments_sha256.length ||
    !Number.isSafeInteger(token.call_index) ||
    Object.is(token.call_index, -0) ||
    token.call_index !== index ||
    token.call_index >= token.batch_call_ids.length ||
    token.call_id !== call.call_id ||
    token.name !== call.name ||
    token.access !== call.access ||
    token.arguments_sha256 !== call.arguments_sha256 ||
    !isSha256Digest(token.arguments_sha256) ||
    !isSha256Digest(token.root_fingerprint_sha256) ||
    !Number.isSafeInteger(token.binding_revision) ||
    Object.is(token.binding_revision, -0) ||
    token.binding_revision < 1 ||
    token.binding_revision >= Number.MAX_SAFE_INTEGER ||
    !validIdentifier(token.policy_version) ||
    token.registry_version !== 1 ||
    !isExactDataArray(token.allowed_decisions, 4) ||
    token.allowed_decisions.length !== allowed.length ||
    token.allowed_decisions.some(
      (decision, decisionIndex) => decision !== allowed[decisionIndex],
    ) ||
    token.batch_call_ids.some(
      (callId, callIndex) =>
        !isOpaqueProviderId(callId) ||
        !isSha256Digest(token.batch_arguments_sha256[callIndex]),
    ) ||
    token.batch_call_ids[token.call_index] !== token.call_id
  ) return false;
  if (
    journal !== undefined &&
    (token.round_id !== journal.round_lineage?.round_id ||
      token.round_index !== journal.round_index ||
      token.root_fingerprint_sha256 !== journal.root.root_fingerprint_sha256 ||
      token.binding_revision !== journal.root.workspace_binding_revision ||
      token.policy_version !== journal.policy.policy_version ||
      token.registry_version !== journal.tool_registry_version ||
      token.batch_call_ids.length !== journal.batch.length ||
      token.batch_arguments_sha256.length !== journal.batch.length ||
      token.batch_call_ids.some((callId, callIndex) =>
        callId !== journal.batch[callIndex]?.call_id,
      ) ||
      token.batch_arguments_sha256.some((digest, callIndex) =>
        digest !== journal.batch[callIndex]?.arguments_sha256,
      ))
  ) return false;
  return true;
}

function agentCallIsValid(value: unknown): value is PersistedAgentCallJournalV2 {
  if (!isExactDataRecord(value, [
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
  ])) return false;
  const call = value as PersistedAgentCallJournalV2;
  if (
    call.schema_version !== 2 ||
    !isOpaqueProviderId(call.call_id) ||
    !Number.isSafeInteger(call.call_index) ||
    Object.is(call.call_index, -0) ||
    call.call_index < 0 ||
    typeof call.name !== 'string' ||
    call.name.length === 0 ||
    call.name.length > 64 ||
    !/^[\x21-\x7e]+$/u.test(call.name) ||
    !isSha256Digest(call.arguments_sha256) ||
    typeof call.safe_summary_key !== 'string' ||
    call.safe_summary_key.length === 0 ||
    call.safe_summary_key.length > MAX_AGENT_SUMMARY_KEY_LENGTH ||
    !safeSummaryKeys.has(call.safe_summary_key) ||
    call.safe_summary_key !==
      ((ALL_AGENT_TOOL_NAMES as readonly string[]).includes(call.name)
        ? `agent.${call.name}`
        : 'agent.unknown') ||
    ((ALL_AGENT_AUTO_TOOLS as readonly string[]).includes(call.name) &&
      call.access !== 'auto') ||
    (['write_file', 'git_commit'].includes(call.name) &&
      call.access !== 'conversation_confirm') ||
    (call.name === 'git_push' && call.access !== 'conversation_confirm') ||
    (isGuestServiceAgentTool(call.name) && call.access !== 'conversation_confirm') ||
    (!(ALL_AGENT_TOOL_NAMES as readonly string[]).includes(call.name) &&
      call.access !== 'durable_deny') ||
    !agentAccessValues.has(call.access) ||
    !agentDecisionValues.has(call.approval_decision) ||
    (call.approval_token !== null &&
      !agentApprovalTokenIsValid(call.approval_token, call, call.call_index)) ||
    (call.approval_reference !== null && !isOpaqueProviderId(call.approval_reference)) ||
    (call.idempotency_key !== null && !isSha256Digest(call.idempotency_key)) ||
    (call.native_row_revision !== null &&
      (!Number.isSafeInteger(call.native_row_revision) ||
        Object.is(call.native_row_revision, -0) ||
        call.native_row_revision < 1)) ||
    (call.receipt !== null && call.native_row_revision === null) ||
    (call.receipt !== null && !agentReceiptIsValid(call.receipt)) ||
    (call.receipt !== null &&
      (call.receipt.call_id !== call.call_id ||
        call.receipt.name !== call.name ||
        call.receipt.arguments_sha256 !== call.arguments_sha256 ||
        call.receipt.approval_reference !== call.approval_reference ||
        (call.receipt.outcome === 'ok' && call.receipt.failure_code !== null) ||
        (call.receipt.outcome === 'ambiguous' &&
          call.receipt.failure_code !== 'E_AGENT_EXECUTION_AMBIGUOUS') ||
        ((call.receipt.outcome === 'failed' ||
          call.receipt.outcome === 'denied' ||
          call.receipt.outcome === 'cancelled') &&
          call.receipt.failure_code === 'E_AGENT_EXECUTION_AMBIGUOUS')))
  ) return false;
  if (call.access === 'auto' && (call.approval_token !== null || call.approval_reference !== null)) return false;
  if (
    call.access === 'durable_deny' &&
    (call.approval_token !== null || call.approval_reference !== null)
  ) return false;
  if (call.access === 'durable_deny' && call.idempotency_key !== null) {
    return false;
  }
  if (call.approval_decision === 'pending' && call.approval_reference !== null) {
    return false;
  }
  if (
    call.access === 'durable_deny' &&
    call.receipt !== null &&
    call.receipt.outcome !== 'denied'
  ) return false;
  if (call.access === 'durable_deny' && call.approval_decision !== 'denied') return false;
  if (
    (call.access === 'conversation_confirm' || call.access === 'confirm_once') &&
    call.approval_token === null
  ) return false;
  return true;
}

export function isAgentAttemptJournal(
  value: unknown,
): value is PersistedAgentAttemptJournalV2 {
  if (!isExactDataRecord(value, [
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
  ])) return false;
  const journal = value as PersistedAgentAttemptJournalV2;
  if (
    journal.schema_version !== 2 ||
    !agentPhaseValues.has(journal.phase) ||
    !Number.isSafeInteger(journal.controller_generation) ||
    Object.is(journal.controller_generation, -0) ||
    journal.controller_generation < 0 ||
    journal.controller_generation >= Number.MAX_SAFE_INTEGER ||
    !agentPolicyIsValid(journal.policy) ||
    !agentRootIsValid(journal.root) ||
    !isAgentRegistryVersion(journal.tool_registry_version) ||
    !isSha256Digest(journal.toolset_sha256) ||
    !agentTranscriptIsValid(journal.transcript) ||
    !Number.isSafeInteger(journal.round_index) ||
    Object.is(journal.round_index, -0) ||
    journal.round_index < 0 ||
    journal.round_index >= MAX_AGENT_ROUNDS ||
    !isExactDataArray(journal.batch, MAX_AGENT_CALLS_PER_BATCH) ||
    !isExactDataArray(
      journal.frozen_grant_ids,
      MAX_AGENT_GRANTS_PER_CONVERSATION,
    ) ||
    !Number.isSafeInteger(journal.reserved_write_bytes) ||
    Object.is(journal.reserved_write_bytes, -0) ||
    journal.reserved_write_bytes < 0 ||
    journal.reserved_write_bytes > journal.policy.max_attempt_write_bytes ||
    !isCanonicalTimestamp(journal.updated_at)
  ) return false;
  const seenCallIds = new Set<string>();
  for (let index = 0; index < journal.batch.length; index += 1) {
    const call = journal.batch[index];
    if (
      !agentCallIsValid(call) ||
      !agentToolRegistryCompatible(call.name, journal.tool_registry_version) ||
      call.call_index !== index ||
      seenCallIds.has(call.call_id)
    ) return false;
    seenCallIds.add(call.call_id);
  }
  if (
    journal.call_index !== null &&
    (!Number.isSafeInteger(journal.call_index) ||
      Object.is(journal.call_index, -0) ||
      journal.call_index < 0 ||
      journal.call_index >= journal.batch.length)
  ) return false;
  if (journal.round_lineage !== null) {
    const lineage = journal.round_lineage;
    if (
      !isExactDataRecord(lineage, [
        'schema_version',
        'round_id',
        'round_index',
        'launch_attempt',
        'status',
        'native_row_revision',
      ]) ||
      lineage.schema_version !== 2 ||
      !isCanonicalLifecycleId(lineage.round_id) ||
      lineage.round_index !== journal.round_index ||
      !Number.isSafeInteger(lineage.launch_attempt) ||
      Object.is(lineage.launch_attempt, -0) ||
      lineage.launch_attempt < 1 ||
      lineage.launch_attempt > MAX_AGENT_ROUNDS ||
      (lineage.native_row_revision !== null &&
        (!Number.isSafeInteger(lineage.native_row_revision) ||
          Object.is(lineage.native_row_revision, -0) ||
          lineage.native_row_revision < 1))
    ) return false;
  }
  if (
    journal.phase === 'ready_for_round' &&
    (journal.call_index !== null ||
      journal.batch.length !== 0 ||
      (journal.round_lineage !== null && journal.round_lineage.status !== 'ready'))
  ) return false;
  if (
    !isAgentPhaseLineageValid(
      journal.phase,
      journal.round_lineage?.status ?? null,
    )
  ) return false;
  if (journal.phase === 'cancelled' && journal.round_lineage === null &&
      (journal.round_index !== 0 || journal.batch.length !== 0 ||
       journal.call_index !== null || journal.reserved_write_bytes !== 0)) return false;
  if (journal.phase === 'approval_pending' && !journal.batch.some(call => call.approval_decision === 'pending')) return false;
  if (journal.phase === 'execution_intent') {
    const call = journal.call_index === null ? undefined : journal.batch[journal.call_index];
    if (
      call === undefined ||
      call.idempotency_key === null ||
      (call.access !== 'auto' &&
        call.approval_decision !== 'allow_once' &&
        call.approval_decision !== 'allow_conversation')
    ) return false;
  }
  if (journal.phase === 'tool_result_pending') {
    const call = journal.call_index === null ? undefined : journal.batch[journal.call_index];
    if (
      call === undefined ||
      call.receipt === null ||
      (call.receipt.outcome !== 'ok' &&
        call.receipt.outcome !== 'failed' &&
        call.receipt.outcome !== 'denied')
    ) return false;
  }
  for (let index = 0; index < journal.batch.length; index += 1) {
    const call = journal.batch[index]!;
    if (
      call.approval_token !== null &&
      !agentApprovalTokenIsValid(call.approval_token, call, index, journal)
    ) return false;
  }
  if (
    journal.phase === 'cancelled' &&
    journal.batch.some(
      call =>
        call.receipt === null &&
        call.approval_decision !== 'denied' &&
        call.approval_decision !== 'cancelled',
    )
  ) return false;
  const grantIds = new Set<string>();
  for (const grantId of journal.frozen_grant_ids) {
    if (!isCanonicalLifecycleId(grantId) || grantIds.has(grantId)) return false;
    grantIds.add(grantId);
  }
  return true;
}

export function validateAgentAttemptJournal(
  value: unknown,
): PersistedAgentAttemptJournalV2 {
  if (!isAgentAttemptJournal(value)) {
    throw new Error('invalid Agent attempt journal');
  }
  return value;
}

function agentCallV3IsValid(value: unknown): value is PersistedAgentCallJournalV3 {
  if (!isExactDataRecord(value, [
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
  ])) return false;
  const call = value as PersistedAgentCallJournalV3;
  const knownTool =
    (ALL_AGENT_TOOL_NAMES as readonly string[]).includes(call.name);
  const expectedAccess = knownTool
    ? (ALL_AGENT_AUTO_TOOLS as readonly string[]).includes(call.name)
      ? 'auto'
      : 'conversation_confirm'
    : 'durable_deny';
  const gated = call.access === 'conversation_confirm' || call.access === 'confirm_once';
  return (
    call.schema_version === 3 &&
    isOpaqueProviderId(call.call_id) &&
    Number.isSafeInteger(call.call_index) &&
    !Object.is(call.call_index, -0) &&
    call.call_index >= 0 &&
    typeof call.name === 'string' &&
    call.name.length > 0 &&
    call.name.length <= 64 &&
    /^[\x21-\x7e]+$/u.test(call.name) &&
    isSha256Digest(call.arguments_sha256) &&
    typeof call.safe_summary_key === 'string' &&
    safeSummaryKeys.has(call.safe_summary_key) &&
    call.safe_summary_key === (knownTool ? `agent.${call.name}` : 'agent.unknown') &&
    call.access === expectedAccess &&
    (call.approval_token === null || isOpaqueProviderId(call.approval_token)) &&
    agentDecisionValues.has(call.approval_decision) &&
    (call.approval_reference === null || isOpaqueProviderId(call.approval_reference)) &&
    (call.idempotency_key === null || isSha256Digest(call.idempotency_key)) &&
    (call.native_row_revision === null ||
      (Number.isSafeInteger(call.native_row_revision) &&
        !Object.is(call.native_row_revision, -0) &&
        call.native_row_revision >= 1)) &&
    (call.receipt === null ||
      (call.native_row_revision !== null &&
        agentReceiptIsValid(call.receipt) &&
        call.receipt.call_id === call.call_id &&
        call.receipt.name === call.name &&
        call.receipt.arguments_sha256 === call.arguments_sha256 &&
        call.receipt.approval_reference === call.approval_reference)) &&
    (call.access !== 'auto' ||
      (call.approval_token === null && call.approval_reference === null)) &&
    (call.access !== 'durable_deny' ||
      (call.approval_token === null &&
        call.approval_reference === null &&
        call.idempotency_key === null &&
        call.approval_decision === 'denied' &&
        (call.receipt === null || call.receipt.outcome === 'denied'))) &&
    (!gated ||
      (call.approval_decision === 'denied' || call.approval_decision === 'cancelled'
        ? call.approval_token === null && call.approval_reference === null
        : call.approval_token !== null || isConversationGrantBoundCall(call)))
  );
}

export const isAgentCallJournalV3 = agentCallV3IsValid;

export function isAgentAttemptJournalV3(
  value: unknown,
): value is PersistedAgentAttemptJournalV3 {
  if (!isExactDataRecord(value, [
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
  ])) return false;
  const journal = value as PersistedAgentAttemptJournalV3;
  if (
    journal.schema_version !== 3 ||
    !agentPhaseValues.has(journal.phase) ||
    !Number.isSafeInteger(journal.controller_generation) ||
    Object.is(journal.controller_generation, -0) ||
    journal.controller_generation < 0 ||
    journal.controller_generation >= Number.MAX_SAFE_INTEGER ||
    !agentPolicyIsValid(journal.policy) ||
    !agentRootIsValid(journal.root) ||
    !isAgentRegistryVersion(journal.tool_registry_version) ||
    !isSha256Digest(journal.toolset_sha256) ||
    !agentTranscriptIsValid(journal.transcript) ||
    !Number.isSafeInteger(journal.round_index) ||
    Object.is(journal.round_index, -0) ||
    journal.round_index < 0 ||
    journal.round_index >= MAX_AGENT_ROUNDS ||
    !isExactDataArray(journal.batch, MAX_AGENT_CALLS_PER_BATCH) ||
    !isExactDataArray(journal.frozen_grant_ids, MAX_AGENT_GRANTS_PER_CONVERSATION) ||
    !Number.isSafeInteger(journal.reserved_write_bytes) ||
    Object.is(journal.reserved_write_bytes, -0) ||
    journal.reserved_write_bytes < 0 ||
    journal.reserved_write_bytes > journal.policy.max_attempt_write_bytes ||
    !isCanonicalTimestamp(journal.updated_at)
  ) return false;
  const ids = new Set<string>();
  for (let index = 0; index < journal.batch.length; index += 1) {
    const call = journal.batch[index];
    if (!agentCallV3IsValid(call) || !hasFrozenConversationGrant(call, journal) ||
        !agentToolRegistryCompatible(call.name, journal.tool_registry_version) ||
        call.call_index !== index || ids.has(call.call_id)) return false;
    ids.add(call.call_id);
  }
  if (
    journal.call_index !== null &&
    (!Number.isSafeInteger(journal.call_index) ||
      Object.is(journal.call_index, -0) ||
      journal.call_index < 0 ||
      journal.call_index >= journal.batch.length)
  ) return false;
  if (journal.round_lineage !== null) {
    const lineage = journal.round_lineage;
    if (
      !isExactDataRecord(lineage, [
        'schema_version',
        'round_id',
        'round_index',
        'launch_attempt',
        'status',
        'native_row_revision',
      ]) ||
      lineage.schema_version !== 2 ||
      !isCanonicalLifecycleId(lineage.round_id) ||
      lineage.round_index !== journal.round_index ||
      !Number.isSafeInteger(lineage.launch_attempt) ||
      Object.is(lineage.launch_attempt, -0) ||
      lineage.launch_attempt < 1 ||
      lineage.launch_attempt > MAX_AGENT_ROUNDS ||
      (lineage.native_row_revision !== null &&
        (!Number.isSafeInteger(lineage.native_row_revision) ||
          Object.is(lineage.native_row_revision, -0) ||
          lineage.native_row_revision < 1))
    ) return false;
  }
  if (
    journal.phase === 'ready_for_round' &&
    (journal.call_index !== null || journal.batch.length !== 0 ||
      (journal.round_lineage !== null && journal.round_lineage.status !== 'ready'))
  ) return false;
  if (
    !isAgentPhaseLineageValid(
      journal.phase,
      journal.round_lineage?.status ?? null,
    )
  ) return false;
  if (journal.phase === 'approval_pending' && !journal.batch.some(call =>
    call.access !== 'auto' && call.access !== 'durable_deny' && call.approval_decision === 'pending')) return false;
  if (journal.phase === 'execution_intent') {
    const call = journal.call_index === null ? undefined : journal.batch[journal.call_index];
    if (call === undefined || call.idempotency_key === null ||
      (call.access !== 'auto' && call.approval_decision !== 'allow_once' && call.approval_decision !== 'allow_conversation')) return false;
  }
  if (journal.phase === 'tool_result_pending') {
    const call = journal.call_index === null ? undefined : journal.batch[journal.call_index];
    if (call === undefined || call.receipt === null ||
      (call.receipt.outcome !== 'ok' && call.receipt.outcome !== 'failed' && call.receipt.outcome !== 'denied')) return false;
  }
  if (
    journal.phase === 'final_response' &&
    (journal.call_index !== null || journal.batch.length !== 0)
  ) return false;
  if (journal.phase === 'cancelled' && journal.batch.some(call =>
    call.receipt === null && call.approval_decision !== 'denied' && call.approval_decision !== 'cancelled')) return false;
  return true;
}

export function isAgentAttemptJournalAny(
  value: unknown,
): value is PersistedAgentAttemptJournalV2 | PersistedAgentAttemptJournalV3 {
  return isAgentAttemptJournal(value) || isAgentAttemptJournalV3(value);
}

function agentGrantIsValid(value: unknown): value is AgentConversationGrantV2 {
  if (!isExactDataRecord(value, [
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
  ])) return false;
  const grant = value as AgentConversationGrantV2;
  return (
    grant.schema_version === 2 &&
    isCanonicalLifecycleId(grant.grant_id) &&
    validIdentifier(grant.conversation_id) &&
    isCanonicalLifecycleId(grant.workspace_id) &&
    (grant.project_id === null || isCanonicalLifecycleId(grant.project_id)) &&
    Number.isSafeInteger(grant.binding_revision) &&
    grant.binding_revision > 0 &&
    grant.binding_revision < Number.MAX_SAFE_INTEGER &&
    isSha256Digest(grant.root_fingerprint_sha256) &&
    (grant.tool_family === 'file_write' ||
      grant.tool_family === 'git_commit' ||
      grant.tool_family === 'git_push' ||
      grant.tool_family === 'guest_service') &&
    (grant.tool_family === 'file_write' || grant.tool_family === 'guest_service' || grant.project_id !== null) &&
    isAgentRegistryVersion(grant.registry_version) &&
    (grant.tool_family !== 'guest_service' || grant.registry_version >= 2) &&
    validIdentifier(grant.policy_version) &&
    isExactDataRecord(grant.issued_for, ['schema_version', 'task_id', 'attempt_id']) &&
    grant.issued_for.schema_version === 1 &&
    isCanonicalLifecycleId(grant.issued_for.task_id) &&
    isCanonicalLifecycleId(grant.issued_for.attempt_id) &&
    isCanonicalTimestamp(grant.created_at)
  );
}

export const isAgentConversationGrant = agentGrantIsValid;

function agentJournalMatchesConversation(
  conversation: Conversation,
  journal: PersistedAgentAttemptJournalV2 | PersistedAgentAttemptJournalV3,
): boolean {
  const binding = conversation.workspaceBinding ?? null;
  if (
    binding === null ||
    journal.root.workspace_id !== binding.workspaceId ||
    journal.root.workspace_binding_revision !== binding.bindingRevision ||
    journal.root.project_id !== conversation.projectId
  ) return false;
  const grants = new Map(
    (conversation.agentGrants ?? []).map(grant => [grant.grant_id, grant]),
  );
  return journal.batch.every(call => hasLiveConversationGrant(call as PersistedAgentCallJournalV3, journal, conversation.id, [...grants.values()])) && journal.frozen_grant_ids.every(grantId => {
    const grant = grants.get(grantId);
    return (
      grant !== undefined &&
      grant.workspace_id === journal.root.workspace_id &&
      grant.binding_revision === journal.root.workspace_binding_revision &&
      grant.project_id === journal.root.project_id &&
      grant.registry_version === journal.tool_registry_version &&
      grant.policy_version === journal.policy.policy_version &&
      grant.root_fingerprint_sha256 === journal.root.root_fingerprint_sha256 &&
      journal.root.capabilities.includes(grant.tool_family)
    );
  });
}

function agentPhaseTransitionIsLegalAny(
  current: PersistedAgentAttemptJournalV2 | PersistedAgentAttemptJournalV3,
  next: PersistedAgentAttemptJournalV2 | PersistedAgentAttemptJournalV3,
): boolean {
  const allowed: Readonly<Record<AgentAttemptPhase, readonly AgentAttemptPhase[]>> = {
    ready_for_round: ['ready_for_round', 'round_in_flight', 'cancelled'],
    round_in_flight: [
      'round_in_flight',
      'ready_for_round',
      'batch_frozen',
      'approval_pending',
      'final_response',
      'cancelled',
      'failed',
      'unknown',
      'ambiguous',
    ],
    batch_frozen: [
      'batch_frozen',
      'approval_pending',
      'execution_intent',
      'tool_result_pending',
      'cancelled',
      'failed',
      'unknown',
      'ambiguous',
    ],
    approval_pending: [
      'approval_pending',
      'batch_frozen',
      'tool_result_pending',
      'cancelled',
      'failed',
      'unknown',
      'ambiguous',
    ],
    execution_intent: [
      'execution_intent',
      'tool_result_pending',
      'cancelled',
      'unknown',
      'ambiguous',
    ],
    tool_result_pending: [
      'tool_result_pending',
      'batch_frozen',
      'approval_pending',
      'ready_for_round',
      'cancelled',
      'failed',
      'unknown',
      'ambiguous',
    ],
    final_response: ['final_response'],
    cancelled: ['cancelled'],
    failed: ['failed', 'round_in_flight'],
    unknown: ['unknown'],
    ambiguous: ['ambiguous'],
  };
  return allowed[current.phase]?.includes(next.phase) ?? false;
}

function sameAgentRoundLineage(
  left: PersistedAgentAttemptJournalV3['round_lineage'],
  right: PersistedAgentAttemptJournalV3['round_lineage'],
): boolean {
  return left === null
    ? right === null
    : right !== null &&
        left.schema_version === right.schema_version &&
        left.round_id === right.round_id &&
        left.round_index === right.round_index &&
        left.launch_attempt === right.launch_attempt &&
        left.status === right.status &&
        left.native_row_revision === right.native_row_revision;
}

function agentCallHasTerminalDisposition(
  call: PersistedAgentCallJournalV3,
): boolean {
  return (
    (call.receipt !== null &&
      (call.receipt.outcome === 'ok' ||
        call.receipt.outcome === 'failed' ||
        call.receipt.outcome === 'denied' ||
        call.receipt.outcome === 'cancelled')) ||
    (call.receipt === null &&
      (call.approval_decision === 'denied' ||
        call.approval_decision === 'cancelled'))
  );
}

function applyAgentCallAdvance(
  state: ChatState,
  payload: Extract<ChatAction, { readonly type: 'attempt/agent-advance-call' }>['payload'],
): ChatState {
  if (
    !isExactDataRecordWithOptional(
      payload,
      ['cas', 'conversationId', 'attemptId', 'expectedAttempt', 'journal', 'at'],
      ['journalRevision'],
    ) ||
    !isCanonicalTimestamp(payload.at) ||
    !isAgentAttemptJournalV3(payload.journal)
  ) return state;
  const conversation = state.conversations[payload.conversationId];
  const index =
    conversation === undefined ? -1 : attemptIndex(conversation, payload.attemptId);
  const attempt = conversation?.attempts[index];
  const current = attempt?.agent;
  if (
    conversation === undefined ||
    attempt === undefined ||
    payload.expectedAttempt !== attempt ||
    !agentControllerCASMatchesAttempt(payload.cas, conversation, attempt) ||
    current === null ||
    current === undefined ||
    !isAgentAttemptJournalV3(current) ||
    current.phase !== 'tool_result_pending' ||
    current.call_index === null ||
    (payload.journalRevision !== undefined &&
      payload.journalRevision !== (attempt.journalRevision ?? 0) + 1)
  ) return state;
  const currentCall = current.batch[current.call_index];
  if (
    currentCall === undefined ||
    currentCall.receipt === null ||
    !agentCallHasTerminalDisposition(currentCall)
  ) return state;

  let nextCallIndex = current.call_index + 1;
  while (
    nextCallIndex < current.batch.length &&
    agentCallHasTerminalDisposition(current.batch[nextCallIndex]!)
  ) {
    nextCallIndex += 1;
  }
  const nextCall = current.batch[nextCallIndex];
  if (nextCall === undefined || nextCall.access === 'durable_deny') return state;
  const nextPhase =
    nextCall.access !== 'auto' &&
    nextCall.approval_decision === 'pending' &&
    nextCall.approval_token !== null
      ? 'approval_pending'
      : 'batch_frozen';
  const next = payload.journal;
  if (
    next.phase !== nextPhase ||
    next.call_index !== nextCallIndex ||
    next.controller_generation !== current.controller_generation + 1 ||
    next.updated_at !== payload.at ||
    next.schema_version !== current.schema_version ||
    !sameAgentPolicy(current.policy, next.policy) ||
    !sameAgentRoot(current.root, next.root) ||
    current.tool_registry_version !== next.tool_registry_version ||
    current.toolset_sha256 !== next.toolset_sha256 ||
    !sameAgentTranscript(current.transcript, next.transcript) ||
    current.round_index !== next.round_index ||
    !sameAgentRoundLineage(current.round_lineage, next.round_lineage) ||
    current.batch.length !== next.batch.length ||
    !current.batch.every((call, callIndex) =>
      sameAgentCallJournal(call, next.batch[callIndex]!),
    ) ||
    !sameAgentStringArray(current.frozen_grant_ids, next.frozen_grant_ids) ||
    current.reserved_write_bytes !== next.reserved_write_bytes ||
    !agentJournalMatchesConversation(conversation, next)
  ) return state;
  const nextAgentAttempt = agentOuterAttemptCheckpoint(
    attempt,
    next,
    undefined,
    payload.at,
  );
  if (nextAgentAttempt === null) return state;
  const nextAttempt: TurnAttemptV1 = {
    ...nextAgentAttempt,
    journalRevision: (attempt.journalRevision ?? 0) + 1,
    agent: copyAgentJournalV3(next),
  };
  const nextConversation = replaceAttempt(conversation, index, nextAttempt);
  const conversations = {
    ...state.conversations,
    [conversation.id]: nextConversation,
  };
  return {
    ...state,
    conversations,
    conversationOrder: orderConversationIds(conversations),
  };
}

function finalAgentCheckpointTransitionIsSafe(
  current: PersistedAgentAttemptJournalV3 | null | undefined,
  next: PersistedAgentAttemptJournalV3,
  evidence: AgentCheckpointEvidence | undefined,
  cas: AgentControllerCASV1,
): boolean {
  if (!isAgentAttemptJournalV3(next) || evidence === undefined) return false;
  if (isControllerPreflight(evidence)) {
    return preflightEventMatchesJournal(current, next, evidence, cas);
  }
  return highLevelEvidenceSupportsTransition(current, next, evidence, cas);
}

function applyFinalAgentCheckpoint(
  state: ChatState,
  payload: Extract<ChatAction, { readonly type: 'attempt/agent-checkpoint' }>['payload'],
  allowFirstTerminal = false,
  /**
   * Grants carried by the same approval checkpoint. A conversation-scoped
   * decision freezes the new grant id in the journal before the grant is
   * recorded on the conversation, so the frozen-grant check must see both.
   */
  pendingGrants: readonly AgentConversationGrantV2[] | null = null,
): ChatState {
  if (
    payload.journal === null ||
    !isAgentAttemptJournalV3(payload.journal) ||
    !isExactDataRecordWithOptional(
      payload,
      ['cas', 'conversationId', 'attemptId', 'expectedAttempt', 'journal', 'events', 'at'],
      ['journalRevision', 'evidence', 'cleanup'],
    ) ||
    !isCanonicalTimestamp(payload.at)
  ) return state;
  const evidence = closedCheckpointEvidence(payload.evidence);
  if (
    evidence === null ||
    !agentCheckpointEvidenceMatchesControllerCAS(evidence, payload.cas)
  ) return state;
  if (payload.cleanup !== undefined) {
    const expectedReason = cleanupReasonForTerminalPhase(payload.journal.phase);
    const outbox = state.agentTranscriptCleanupOutbox ?? [];
    if (
      expectedReason === null ||
      !cleanupEntryIsValid(payload.cleanup) ||
      payload.cleanup.conversation_id !== payload.conversationId ||
      payload.cleanup.attempt_id !== payload.attemptId ||
      payload.cleanup.transcript_ref !== payload.journal.transcript.transcript_ref ||
      payload.cleanup.transcript_sha256 !== payload.journal.transcript.transcript_sha256 ||
      payload.cleanup.reason !== expectedReason ||
      outbox.length >= MAX_AGENT_CLEANUP_OUTBOX_ENTRIES ||
      outbox.some(entry => entry.cleanup_id === payload.cleanup!.cleanup_id)
    ) return state;
  }
  const conversation = state.conversations[payload.conversationId];
  const index =
    conversation === undefined
      ? -1
      : attemptIndex(conversation, payload.attemptId);
  const attempt = conversation?.attempts[index];
  const current = attempt?.agent;
  const currentPhase =
    current?.schema_version === 3 ? current.phase : null;
  const nextIsTerminal =
    payload.journal.phase === 'final_response' ||
    payload.journal.phase === 'cancelled' ||
    payload.journal.phase === 'failed';
  const currentIsTerminal =
    currentPhase === 'final_response' ||
    currentPhase === 'cancelled' ||
    currentPhase === 'failed';

  if (nextIsTerminal && (!allowFirstTerminal || currentIsTerminal)) {
    return state;
  }

  if (
    payload.cleanup !== undefined &&
    (attempt === undefined || payload.cleanup.task_id !== attempt.turnId)
  ) return state;
  if (
    conversation === undefined ||
    attempt === undefined ||
    payload.expectedAttempt !== attempt ||
    !agentControllerCASMatchesAttempt(payload.cas, conversation, attempt) ||
    (current !== null && current !== undefined && current.schema_version !== 3) ||
    !agentJournalMatchesConversation(
      pendingGrants === null
        ? conversation
        : { ...conversation, agentGrants: pendingGrants },
      payload.journal,
    ) ||
    (payload.journalRevision !== undefined &&
      payload.journalRevision !== (attempt.journalRevision ?? 0) + 1) ||
    payload.journal.controller_generation !==
      (current?.schema_version === 3
        ? current.controller_generation + 1
        : 0) ||
    !sessionEventsAreValid(payload.events) ||
    payload.events.length === 0 ||
    !payload.events.some(
      event => !(state.sessionEvents ?? []).some(candidate =>
        candidate.event_id === event.event_id,
      ),
    ) ||
    payload.events.some(event => {
      const existing = (state.sessionEvents ?? []).find(
        candidate => candidate.event_id === event.event_id,
      );
      return existing !== undefined && !sameSessionEvent(existing, event);
    }) ||
    !sessionEventsMatchState(payload.events, state, {
      conversationId: payload.conversationId,
      attemptId: payload.attemptId,
      journal: payload.journal,
    }) ||
    (isControllerPreflight(evidence) &&
      evidence.kind === 'begin_round' &&
      current?.schema_version === 3 &&
      ((current.phase === 'tool_result_pending' &&
        (attempt.visibleHistorySha256 === null ||
          attempt.visibleHistorySha256 !== evidence.visible_history_sha256 ||
          attempt.visibleMessageIds.length !== evidence.visible_message_count ||
          (attempt.projectContext?.snapshotSha256 ?? null) !==
            evidence.project_context_sha256)) ||
        (current.phase === 'ready_for_round' &&
          current.round_lineage === null &&
          (attempt.visibleMessageIds.length !== evidence.visible_message_count ||
            (attempt.projectContext?.snapshotSha256 ?? null) !==
              evidence.project_context_sha256)))) ||
    (isControllerPreflight(evidence)
      ? !preflightEventMatchesPayload(
          evidence,
          payload.events,
          current?.schema_version === 3 ? current : null,
          payload.attemptId,
      )
      : !(allowFirstTerminal && evidence.kind === 'recover_agent_attempt') &&
        !postEvidenceOrderingIsValid(
          state,
          evidence,
          payload.attemptId,
          payload.events,
          allowFirstTerminal,
        )) ||
    !finalAgentCheckpointTransitionIsSafe(
      current?.schema_version === 3 ? current : null,
      payload.journal,
      evidence,
      payload.cas,
    )
  ) return state;
  if (nextIsTerminal && !currentIsTerminal && payload.cleanup === undefined) {
    return state;
  }
  const nextAgentAttempt = agentOuterAttemptCheckpoint(
    attempt,
    payload.journal,
    evidenceRoundReceiptFor(evidence),
    payload.at,
    evidence.kind === 'recover_agent_attempt' && evidence.result.status === 'resumed' && evidence.result.next_action === 'persist_batch',
    evidenceRoundCauseFor(evidence),
  );
  if (nextAgentAttempt === null) return state;
  const nextAttempt: TurnAttemptV1 = {
    ...nextAgentAttempt,
    visibleHistorySha256:
      isControllerPreflight(evidence) && evidence.kind === 'begin_round'
        ? (attempt.visibleHistorySha256 ?? evidence.visible_history_sha256)
        : attempt.visibleHistorySha256,
    journalRevision: (attempt.journalRevision ?? 0) + 1,
    agent: copyAgentJournalV3(payload.journal),
  };
  const nextConversation = replaceAttempt(conversation, index, nextAttempt);
  const conversations = { ...state.conversations, [conversation.id]: nextConversation };
  const sessionEvents = [...(state.sessionEvents ?? [])];
  for (const event of payload.events) {
    if (!(state.sessionEvents ?? []).some(candidate => candidate.event_id === event.event_id)) {
      sessionEvents.push({ ...event });
    }
  }
  return {
    ...state,
    conversations,
    conversationOrder: orderConversationIds(conversations),
    sessionEvents,
    ...(payload.cleanup === undefined
      ? {}
      : {
          agentTranscriptCleanupOutbox: [
            ...(state.agentTranscriptCleanupOutbox ?? []),
            { ...payload.cleanup },
          ],
        }),
  };
}

type AgentFinalMaterial = {
  readonly receipt: CompletionRoundReceiptV1 | undefined;
  readonly text: string | null;
  readonly reasoning: string | null;
  readonly eventStatus: 'ok' | 'failed' | 'cancelled';
  readonly failureCode: AgentFailureCode | null;
};

function agentFinalMaterial(
  evidence: AgentStoreTransitionEvidence,
  journal: PersistedAgentAttemptJournalV3,
): AgentFinalMaterial | null {
  let text: string | null = null;
  let reasoning: string | null = null;
  if (evidence.kind === 'complete_agent_round_v2') {
    const result = evidence.result;
    if (result.status === 'completed') {
      if (result.outcome.kind === 'tool_batch') return null;
      if (result.outcome.kind === 'final') {
        if (journal.phase !== 'final_response') return null;
        text = result.outcome.text;
        reasoning = result.outcome.reasoning;
      } else if (journal.phase !== 'failed') {
        return null;
      }
    } else if (result.status === 'cancelled') {
      if (journal.phase !== 'cancelled') return null;
    } else if (result.status === 'failed_retryable') {
      if (journal.phase !== 'failed') return null;
    } else {
      return null;
    }
  } else if (evidence.kind === 'cancel_agent_attempt') {
    const result = evidence.result;
    const settledCancellation =
      result.status === 'settled' && result.receipt?.outcome === 'cancelled';
    if (
      journal.phase !== 'cancelled' ||
      (result.status !== 'cancelled' &&
        result.status !== 'already_cancelled' &&
        !settledCancellation)
    ) return null;
  } else if (evidence.kind === 'execute_agent_tool') {
    if (
      journal.phase !== 'cancelled' ||
      evidence.result.status !== 'cancelled' ||
      evidence.result.receipt === null ||
      evidence.result.receipt.outcome !== 'cancelled' ||
      evidence.result.receipt.failure_code !== 'E_AGENT_CANCELLED' ||
      evidence.result.effect_may_have_occurred !== false
    ) return null;
  } else if (evidence.kind === 'recover_agent_attempt') {
    const recovered = evidence.result.completed_round;
    if (journal.phase === 'final_response') {
      if (recovered === null || recovered.kind !== 'final') return null;
      text = recovered.text;
      reasoning = recovered.reasoning;
    } else if (recovered !== null && recovered.kind === 'final') {
      return null;
    }
  } else {
    return null;
  }
  const receipt = evidenceRoundReceiptFor(evidence);
  if (journal.phase === 'final_response') {
    return receipt === undefined || text === null || reasoning === null
      ? null
      : {
          receipt,
          text,
          reasoning,
          eventStatus: 'ok',
          failureCode: null,
        };
  }
  if (journal.phase === 'cancelled') {
    const cancellationFailure =
      evidence.kind === 'cancel_agent_attempt'
        ? evidence.request.cancel_token.reason_code
        : evidence.kind === 'execute_agent_tool'
          ? 'E_AGENT_CANCELLED'
        : 'E_AGENT_CANCELLED';
    return {
      receipt,
      text: null,
      reasoning: null,
      eventStatus: 'cancelled',
      failureCode: cancellationFailure,
    };
  }
  if (journal.phase !== 'failed') return null;
  const failureCode: AgentFailureCode =
    receipt?.finishReason === 'length'
      ? 'E_COMPLETION_LENGTH'
      : receipt?.finishReason === 'content_filter'
        ? 'E_COMPLETION_CONTENT_FILTER'
        : journal.round_index >= MAX_AGENT_ROUNDS - 1 &&
            journal.round_lineage?.status === 'completed'
          ? 'E_AGENT_ROUND_LIMIT'
          : (evidenceRoundCauseFor(evidence) ?? 'E_AGENT_PERSISTENCE');
  return {
    receipt,
    text: null,
    reasoning: null,
    eventStatus: 'failed',
    failureCode,
  };
}

function exactFinalAssistantMessage(
  conversation: Conversation,
  value: ChatMessage | null,
  material: AgentFinalMaterial,
): ChatMessage | null {
  if (material.text === null || material.reasoning === null) {
    return null;
  }
  const hasReasoning = material.reasoning.trim().length > 0;
  const metadataKeys =
    !hasReasoning
      ? ['modelId', 'latencyMs', 'finishReason'] as const
      : ['modelId', 'latencyMs', 'finishReason', 'reasoning'] as const;
  if (
    value === null ||
    !isExactDataRecordWithOptional(
      value,
      ['id', 'role', 'text', 'createdAt', 'attachments'],
      ['metadata'],
    ) ||
    value.role !== 'assistant' ||
    value.text !== material.text ||
    !isExactDataArray(value.attachments, 0) ||
    !isExactDataRecord(value.metadata, metadataKeys) ||
    material.receipt === undefined ||
    value.metadata.modelId !== material.receipt.model ||
    value.metadata.latencyMs !== material.receipt.latencyMs ||
    value.metadata.finishReason !== material.receipt.finishReason ||
    (hasReasoning && value.metadata.reasoning !== material.reasoning)
  ) return null;
  return normalizedMessage(conversation, value);
}

function atomicTerminalEventMatches(
  state: ChatState,
  payload: Extract<
    ChatAction,
    { readonly type: 'attempt/agent-final-checkpoint' }
  >['payload'],
  material: AgentFinalMaterial,
  evidence: AgentStoreTransitionEvidence,
): boolean {
  const previous = state.sessionEvents ?? [];
  const fresh = payload.events.filter(
    event =>
      !previous.some(candidate => candidate.event_id === event.event_id),
  );
  const latestSeq = previous
    .filter(candidate => candidate.attempt_id === payload.attemptId)
    .reduce((value, candidate) => Math.max(value, candidate.seq), -1);
  const terminalMatches = (
    event: PersistedSessionEventV3,
    seq: number,
  ) =>
    event.attempt_id === payload.attemptId &&
    event.seq === seq &&
    event.kind === 'terminal' &&
    event.round_index === null &&
    event.call_id === null &&
    event.status === material.eventStatus &&
    event.safe_summary_key === null &&
    event.arguments_sha256 === null &&
    event.result_sha256 === null &&
    event.approval_reference === null &&
    event.failure_code === material.failureCode &&
    event.created_at === payload.cleanup.created_at;
  if (evidence.kind === 'execute_agent_tool') {
    if (
      evidence.result.status !== 'cancelled' ||
      evidence.result.receipt === null ||
      fresh.length !== 2
    ) return false;
    const resultEvent = fresh[0]!;
    const terminalEvent = fresh[1]!;
    const receipt = evidence.result.receipt;
    return (
      resultEvent.event_id !== evidence.operation_id &&
      terminalEvent.event_id !== evidence.operation_id &&
      resultEvent.event_id !== terminalEvent.event_id &&
      resultEvent.attempt_id === payload.attemptId &&
      resultEvent.seq === latestSeq + 1 &&
      resultEvent.kind === 'tool_result' &&
      resultEvent.round_index === evidence.request.round_index &&
      resultEvent.call_id === evidence.request.call_id &&
      resultEvent.status === 'cancelled' &&
      resultEvent.safe_summary_key === `agent.${evidence.request.name}` &&
      resultEvent.arguments_sha256 === evidence.request.arguments_sha256 &&
      resultEvent.result_sha256 === receipt.result_sha256 &&
      resultEvent.approval_reference === receipt.approval_reference &&
      resultEvent.failure_code === receipt.failure_code &&
      terminalMatches(terminalEvent, latestSeq + 2)
    );
  }
  if (fresh.length !== 1) return false;
  const event = fresh[0]!;
  return (
    event.event_id !== evidence.operation_id &&
    terminalMatches(event, latestSeq + 1)
  );
}

function applyAtomicAgentFinalCheckpoint(
  state: ChatState,
  payload: Extract<
    ChatAction,
    { readonly type: 'attempt/agent-final-checkpoint' }
  >['payload'],
): ChatState {
  if (
    !isExactDataRecordWithOptional(
      payload,
      [
        'cas',
        'conversationId',
        'attemptId',
        'expectedAttempt',
        'journal',
        'events',
        'evidence',
        'assistantMessage',
        'cleanup',
        'at',
      ],
      ['journalRevision'],
    ) ||
    !isAgentAttemptJournalV3(payload.journal) ||
    (payload.journal.phase !== 'final_response' &&
      payload.journal.phase !== 'failed' &&
      payload.journal.phase !== 'cancelled')
  ) return state;
  const evidence = closedAgentEvidence(payload.evidence);
  const conversation = state.conversations[payload.conversationId];
  const attempt = conversation?.attempts.find(
    candidate => candidate.attemptId === payload.attemptId,
  );
  if (
    evidence === null ||
    conversation === undefined ||
    attempt === undefined ||
    attempt !== payload.expectedAttempt ||
    attempt.assistantMessageId !== null ||
    attempt.status === 'completed' ||
    attempt.agent === null ||
    attempt.agent === undefined ||
    attempt.agent.phase === 'final_response' ||
    attempt.agent.phase === 'failed' ||
    attempt.agent.phase === 'cancelled'
  ) return state;
  const material = agentFinalMaterial(evidence, payload.journal);
  if (
    material === null ||
    !atomicTerminalEventMatches(state, payload, material, evidence) ||
    (material.receipt !== undefined &&
      hasProviderReceiptId(state, material.receipt))
  ) return state;
  const assistant = exactFinalAssistantMessage(
    conversation,
    payload.assistantMessage,
    material,
  );
  if (
    (payload.journal.phase === 'final_response' && assistant === null) ||
    (payload.journal.phase !== 'final_response' &&
      payload.assistantMessage !== null)
  ) return state;
  const checkpointed = applyFinalAgentCheckpoint(
    state,
    {
      cas: payload.cas,
      conversationId: payload.conversationId,
      attemptId: payload.attemptId,
      expectedAttempt: payload.expectedAttempt,
      journal: payload.journal,
      events: payload.events,
      evidence,
      cleanup: payload.cleanup,
      ...(payload.journalRevision === undefined
        ? {}
        : { journalRevision: payload.journalRevision }),
      at: payload.at,
    },
    true,
  );
  if (checkpointed === state || assistant === null) return checkpointed;
  const checkpointedConversation =
    checkpointed.conversations[payload.conversationId];
  if (checkpointedConversation === undefined) return state;
  const index = attemptIndex(checkpointedConversation, payload.attemptId);
  const checkpointedAttempt = checkpointedConversation.attempts[index];
  if (checkpointedAttempt === undefined) return state;
  const completedAttempt: TurnAttemptV1 = {
    ...checkpointedAttempt,
    status: 'completed',
    assistantMessageId: assistant.id,
    failureCode: null,
    updatedAt: laterTimestamp(checkpointedAttempt.updatedAt, assistant.createdAt),
  };
  return withConversation(checkpointed, {
    ...replaceAttempt(checkpointedConversation, index, completedAttempt),
    messages: [...checkpointedConversation.messages, assistant],
    updatedAt: laterTimestamp(
      checkpointedConversation.updatedAt,
      assistant.createdAt,
    ),
  });
}

function sameAgentStringArray(
  left: readonly string[],
  right: readonly string[],
): boolean {
  return left.length === right.length && left.every((value, index) => value === right[index]);
}

function sameAgentGrant(
  left: AgentConversationGrantV2,
  right: AgentConversationGrantV2,
): boolean {
  return (
    left.schema_version === right.schema_version &&
    left.grant_id === right.grant_id &&
    left.conversation_id === right.conversation_id &&
    left.workspace_id === right.workspace_id &&
    left.project_id === right.project_id &&
    left.binding_revision === right.binding_revision &&
    left.root_fingerprint_sha256 === right.root_fingerprint_sha256 &&
    left.tool_family === right.tool_family &&
    left.registry_version === right.registry_version &&
    left.policy_version === right.policy_version &&
    left.issued_for.schema_version === right.issued_for.schema_version &&
    left.issued_for.task_id === right.issued_for.task_id &&
    left.issued_for.attempt_id === right.issued_for.attempt_id &&
    left.created_at === right.created_at
  );
}

function sameAgentGrants(
  left: readonly AgentConversationGrantV2[],
  right: readonly AgentConversationGrantV2[],
): boolean {
  return (
    left.length === right.length &&
    left.every((grant, index) => sameAgentGrant(grant, right[index]!))
  );
}

function sameAgentRoot(
  left: FrozenAgentRootV1,
  right: FrozenAgentRootV1,
): boolean {
  return (
    left.schema_version === right.schema_version &&
    left.kind === right.kind &&
    left.workspace_id === right.workspace_id &&
    left.workspace_binding_revision === right.workspace_binding_revision &&
    left.project_id === right.project_id &&
    left.root_fingerprint_sha256 === right.root_fingerprint_sha256 &&
    sameAgentStringArray(left.capabilities, right.capabilities)
  );
}

function sameAgentPolicy(
  left: AgentWritePolicyV1,
  right: AgentWritePolicyV1,
): boolean {
  return (
    left.schema_version === right.schema_version &&
    left.policy_version === right.policy_version &&
    left.max_single_write_bytes === right.max_single_write_bytes &&
    left.max_batch_write_bytes === right.max_batch_write_bytes &&
    left.max_attempt_write_bytes === right.max_attempt_write_bytes
  );
}

function sameAgentTranscript(
  left: AgentTranscriptReferenceV1,
  right: AgentTranscriptReferenceV1,
): boolean {
  return (
    left.schema_version === right.schema_version &&
    left.transcript_ref === right.transcript_ref &&
    left.generation === right.generation &&
    left.transcript_sha256 === right.transcript_sha256 &&
    left.transcript_bytes === right.transcript_bytes
  );
}


/**
 * Re-validate the already-mapped evidence at the reducer boundary.  Store
 * callers are not trusted merely because they received a typed value: a
 * caller can still construct an object with the same TypeScript shape.
 */
function closedAgentEvidence(value: unknown): AgentStoreTransitionEvidence | null {
  try {
    if (!isExactDataRecord(value, ['kind', 'operation_id', 'request', 'result'])) {
      return null;
    }
    const kind = value.kind;
    const operations = new Set([
      'prepare_agent_attempt',
      'complete_agent_round_v2',
      'prepare_agent_tool_batch',
      'bind_agent_approval',
      'execute_agent_tool',
      'cancel_agent_attempt',
      'recover_agent_attempt',
    ]);
    if (typeof kind !== 'string' || !operations.has(kind)) return null;
    const mapped = validateAgentStoreTransition({
      operation: kind,
      request: value.request,
      result: value.result,
    });
    return mapped !== null && mapped.operation_id === value.operation_id
      ? mapped
      : null;
  } catch {
    return null;
  }
}

function closedControllerPreflight(
  value: unknown,
): AgentControllerPreflightV1 | null {
  try {
    return validateAgentControllerPreflight(value);
  } catch {
    return null;
  }
}

function closedCheckpointEvidence(
  value: unknown,
): AgentCheckpointEvidence | null {
  return closedControllerPreflight(value) ?? closedAgentEvidence(value);
}

function agentEvidenceMatchesControllerCAS(
  evidence: AgentStoreTransitionEvidence,
  cas: AgentControllerCASV1,
): boolean {
  const request = evidence.request;
  const requestCas = request.controller_cas;
  const checkpoint = request.committed_checkpoint;
  const target = 'target' in request ? request.target : null;
  return (
    requestCas.schema_version === cas.schema_version &&
    requestCas.conversation_id === cas.conversation_id &&
    requestCas.task_id === cas.task_id &&
    requestCas.attempt_id === cas.attempt_id &&
    requestCas.expected_controller_generation === cas.expected_controller_generation &&
    requestCas.expected_journal_revision === cas.expected_journal_revision &&
    requestCas.expected_session_generation === cas.expected_session_generation &&
    requestCas.expected_session_sha256 === cas.expected_session_sha256 &&
    checkpoint.schema_version === 1 &&
    checkpoint.journal_revision === cas.expected_journal_revision &&
    checkpoint.session_generation === cas.expected_session_generation &&
    checkpoint.session_sha256 === cas.expected_session_sha256 &&
    ('task_id' in request
      ? request.task_id === cas.task_id &&
        request.conversation_id === cas.conversation_id &&
        request.attempt_id === cas.attempt_id
      : target !== null &&
        target.task_id === cas.task_id &&
        target.attempt_id === cas.attempt_id)
  );
}

function agentCheckpointEvidenceMatchesControllerCAS(
  evidence: AgentCheckpointEvidence,
  cas: AgentControllerCASV1,
): boolean {
  if (isControllerPreflight(evidence)) {
    const base = evidence.base_cas;
    return (
      base.schema_version === cas.schema_version &&
      base.conversation_id === cas.conversation_id &&
      base.task_id === cas.task_id &&
      base.attempt_id === cas.attempt_id &&
      base.expected_controller_generation === cas.expected_controller_generation &&
      base.expected_journal_revision === cas.expected_journal_revision &&
      base.expected_session_generation === cas.expected_session_generation &&
      base.expected_session_sha256 === cas.expected_session_sha256 &&
      evidence.conversation_id === cas.conversation_id &&
      evidence.task_id === cas.task_id &&
      evidence.attempt_id === cas.attempt_id
    );
  }
  return agentEvidenceMatchesControllerCAS(evidence, cas);
}

function isControllerPreflight(
  value: AgentCheckpointEvidence,
): value is AgentControllerPreflightV1 {
  return (
    value.kind === 'begin_round' ||
    value.kind === 'decide_approval' ||
    value.kind === 'begin_execution' ||
    value.kind === 'request_cancel'
  );
}

function sameAgentCallJournal(
  left: PersistedAgentCallJournalV3,
  right: PersistedAgentCallJournalV3,
): boolean {
  return (
    left.schema_version === right.schema_version &&
    left.call_id === right.call_id &&
    left.call_index === right.call_index &&
    left.name === right.name &&
    left.arguments_sha256 === right.arguments_sha256 &&
    left.safe_summary_key === right.safe_summary_key &&
    left.access === right.access &&
    left.approval_token === right.approval_token &&
    left.approval_decision === right.approval_decision &&
    left.approval_reference === right.approval_reference &&
    left.idempotency_key === right.idempotency_key &&
    left.native_row_revision === right.native_row_revision &&
    (left.receipt === null
      ? right.receipt === null
      : right.receipt !== null && sameAgentReceipt(left.receipt, right.receipt))
  );
}

function preflightEventMatchesJournal(
  current: PersistedAgentAttemptJournalV3 | null | undefined,
  next: PersistedAgentAttemptJournalV3,
  evidence: AgentControllerPreflightV1,
  cas: AgentControllerCASV1,
): boolean {
  // A controller intent cannot bootstrap an Agent attempt.  The first live
  // authority must come from the committed native prepare result so the
  // preflight seed is always anchored to a persisted ready journal.
  if (current === null || current === undefined) return false;
  if (
    evidence.kind === 'begin_round' &&
    current.phase === 'ready_for_round' &&
    current.round_lineage === null
  ) {
    if (
      !isAgentAttemptJournalV3(current) ||
      !isAgentAttemptJournalV3(next) ||
      !agentCheckpointEvidenceMatchesControllerCAS(evidence, cas) ||
      next.round_lineage === null
    ) return false;
    return (
      current.round_index === 0 &&
      current.batch.length === 0 &&
      current.call_index === null &&
      next.phase === 'round_in_flight' &&
      next.controller_generation === current.controller_generation + 1 &&
      evidence.round_index === 0 &&
      evidence.launch_attempt === 1 &&
      evidence.expected_round_revision === 0 &&
      next.round_index === 0 &&
      next.round_lineage.round_id === evidence.round_id &&
      next.round_lineage.round_index === 0 &&
      next.round_lineage.launch_attempt === 1 &&
      next.round_lineage.status === 'active' &&
      next.round_lineage.native_row_revision === null &&
      next.batch.length === 0 &&
      next.call_index === null &&
      next.reserved_write_bytes === current.reserved_write_bytes &&
      sameAgentRoot(current.root, evidence.root) &&
      sameAgentRoot(next.root, evidence.root) &&
      sameAgentTranscript(current.transcript, evidence.transcript) &&
      sameAgentTranscript(next.transcript, evidence.transcript) &&
      current.toolset_sha256 === evidence.toolset_sha256 &&
      next.toolset_sha256 === evidence.toolset_sha256 &&
      current.tool_registry_version === evidence.registry_version &&
      next.tool_registry_version === evidence.registry_version &&
      sameAgentPolicy(current.policy, next.policy) &&
      sameAgentStringArray(current.frozen_grant_ids, next.frozen_grant_ids)
    );
  }
  if (evidence.kind === 'begin_round' && current.phase === 'tool_result_pending') {
    if (
      !isAgentAttemptJournalV3(current) ||
      !isAgentAttemptJournalV3(next) ||
      !agentCheckpointEvidenceMatchesControllerCAS(evidence, cas) ||
      current.round_lineage === null ||
      next.round_lineage === null ||
      current.batch.length === 0 ||
      // The cursor rests on the last call that settled by execution; calls
      // after it may already carry a user-denial receipt settled at decision
      // time, so the whole batch (checked below) rather than the cursor
      // position proves completion.
      current.call_index === null ||
      current.call_index < 0 ||
      current.call_index >= current.batch.length ||
      current.batch.some(call =>
        call.receipt === null ||
        (call.receipt.outcome !== 'ok' &&
          call.receipt.outcome !== 'failed' &&
          call.receipt.outcome !== 'denied' &&
          call.receipt.outcome !== 'cancelled'),
      )
    ) return false;
    return (
      next.phase === 'round_in_flight' &&
      next.controller_generation === current.controller_generation + 1 &&
      evidence.round_index === current.round_index + 1 &&
      evidence.round_index < MAX_AGENT_ROUNDS &&
      evidence.round_id !== current.round_lineage.round_id &&
      evidence.launch_attempt === 1 &&
      evidence.expected_round_revision === 0 &&
      next.round_index === evidence.round_index &&
      next.round_lineage.round_id === evidence.round_id &&
      next.round_lineage.round_index === evidence.round_index &&
      next.round_lineage.launch_attempt === 1 &&
      next.round_lineage.status === 'active' &&
      next.round_lineage.native_row_revision === null &&
      next.batch.length === 0 &&
      next.call_index === null &&
      next.reserved_write_bytes === current.reserved_write_bytes &&
      sameAgentRoot(current.root, evidence.root) &&
      sameAgentRoot(next.root, evidence.root) &&
      sameAgentTranscript(current.transcript, evidence.transcript) &&
      sameAgentTranscript(next.transcript, evidence.transcript) &&
      current.toolset_sha256 === evidence.toolset_sha256 &&
      next.toolset_sha256 === evidence.toolset_sha256 &&
      current.tool_registry_version === evidence.registry_version &&
      next.tool_registry_version === evidence.registry_version &&
      sameAgentPolicy(current.policy, next.policy) &&
      sameAgentStringArray(current.frozen_grant_ids, next.frozen_grant_ids)
    );
  }
  if (
    !isAgentAttemptJournalV3(current) ||
    !isAgentAttemptJournalV3(next) ||
    !agentCheckpointEvidenceMatchesControllerCAS(evidence, cas) ||
    !agentPhaseTransitionIsLegalAny(current, next) ||
    next.controller_generation !== current.controller_generation + 1
  ) return false;
  if (evidence.kind === 'begin_round') {
    const retrying = current.phase === 'failed';
    return (
      (current.phase === 'ready_for_round' ||
        (retrying && current.round_lineage?.status === 'failed_retryable')) &&
      next.phase === 'round_in_flight' &&
      current.round_index === evidence.round_index &&
      current.round_lineage?.round_id === evidence.round_id &&
      next.round_lineage?.round_id === evidence.round_id &&
      next.round_lineage?.round_index === evidence.round_index &&
      next.round_lineage?.launch_attempt === evidence.launch_attempt &&
      (!retrying || evidence.launch_attempt === current.round_lineage!.launch_attempt + 1) &&
      evidence.expected_round_revision ===
        (current.round_lineage?.native_row_revision ?? 0) &&
      next.round_lineage?.status === 'active' &&
      next.round_lineage.native_row_revision === null &&
      sameAgentRoot(current.root, evidence.root) &&
      sameAgentRoot(next.root, evidence.root) &&
      sameAgentTranscript(current.transcript, evidence.transcript) &&
      sameAgentTranscript(next.transcript, evidence.transcript) &&
      current.toolset_sha256 === evidence.toolset_sha256 &&
      next.toolset_sha256 === evidence.toolset_sha256 &&
      current.tool_registry_version === evidence.registry_version &&
      next.tool_registry_version === evidence.registry_version &&
      sameAgentPolicy(current.policy, next.policy) &&
      current.batch.length === 0 &&
      next.batch.length === 0 &&
      next.call_index === null
    );
  }
  if (evidence.kind === 'decide_approval') {
    const beforeCall = current.batch[evidence.call_index];
    const afterCall = next.batch[evidence.call_index];
    if (
      (current.phase !== 'approval_pending' && current.phase !== 'batch_frozen') ||
      beforeCall === undefined ||
      afterCall === undefined ||
      current.round_lineage?.round_id !== evidence.round_id ||
      current.round_index !== evidence.round_index ||
      beforeCall.call_id !== evidence.call_id ||
      beforeCall.name !== evidence.name ||
      beforeCall.arguments_sha256 !== evidence.arguments_sha256 ||
      beforeCall.approval_token !== evidence.approval_token ||
      beforeCall.access !== evidence.access ||
      current.root.workspace_id !== evidence.workspace_id ||
      current.root.project_id !== evidence.project_id ||
      current.root.workspace_binding_revision !== evidence.binding_revision ||
      current.root.root_fingerprint_sha256 !== evidence.root_fingerprint_sha256 ||
      current.policy.policy_version !== evidence.policy_version ||
      !sameAgentTranscript(current.transcript, next.transcript) ||
      !sameAgentRoot(current.root, next.root) ||
      !sameAgentPolicy(current.policy, next.policy) ||
      current.tool_registry_version !== evidence.registry_version ||
      next.tool_registry_version !== evidence.registry_version ||
      current.toolset_sha256 !== next.toolset_sha256
    ) return false;
    const expectedDecision = evidence.decision;
    const expectedToken =
      expectedDecision === 'denied' || expectedDecision === 'cancelled'
        ? null
        : evidence.approval_token;
    const expectedReference =
      expectedDecision === 'denied' || expectedDecision === 'cancelled'
        ? null
        : evidence.operation_id;
    return (
      afterCall.approval_decision === expectedDecision &&
      afterCall.approval_token === expectedToken &&
      afterCall.approval_reference === expectedReference &&
      sameAgentStringArray(
        next.frozen_grant_ids,
        evidence.grant === null
          ? current.frozen_grant_ids
          : [...current.frozen_grant_ids, evidence.grant.grant_id],
      ) &&
      next.batch.every((call, index) => index === evidence.call_index || sameAgentCallJournal(call, current.batch[index]!))
    );
  }
  if (evidence.kind === 'begin_execution') {
    const beforeCall = current.batch[evidence.call_index];
    const afterCall = next.batch[evidence.call_index];
    return (
      current.phase === 'batch_frozen' &&
      next.phase === 'execution_intent' &&
      beforeCall !== undefined &&
      afterCall !== undefined &&
      current.round_lineage?.round_id === evidence.round_id &&
      current.round_index === evidence.round_index &&
      beforeCall.call_id === evidence.call_id &&
      beforeCall.name === evidence.name &&
      beforeCall.arguments_sha256 === evidence.arguments_sha256 &&
      beforeCall.access === evidence.access &&
      current.call_index === evidence.call_index &&
      evidence.approval_state ===
        (beforeCall.access === 'auto' ? 'not_required' : 'bound') &&
      (beforeCall.access === 'auto' ||
        beforeCall.approval_decision === 'allow_once' ||
        beforeCall.approval_decision === 'allow_conversation') &&
      beforeCall.approval_reference === evidence.approval_reference &&
      beforeCall.native_row_revision === evidence.expected_execution_revision &&
      afterCall.idempotency_key === evidence.idempotency_key &&
      afterCall.call_id === beforeCall.call_id &&
      afterCall.name === beforeCall.name &&
      afterCall.arguments_sha256 === beforeCall.arguments_sha256 &&
      afterCall.approval_token === beforeCall.approval_token &&
      afterCall.approval_decision === beforeCall.approval_decision &&
      afterCall.approval_reference === beforeCall.approval_reference &&
      afterCall.native_row_revision === evidence.expected_execution_revision &&
      beforeCall.receipt === null &&
      afterCall.receipt === null &&
      sameAgentRoot(current.root, evidence.root) &&
      sameAgentRoot(next.root, evidence.root) &&
      sameAgentTranscript(current.transcript, evidence.transcript) &&
      sameAgentTranscript(next.transcript, evidence.transcript) &&
      current.tool_registry_version === next.tool_registry_version &&
      current.toolset_sha256 === next.toolset_sha256 &&
      sameAgentPolicy(current.policy, next.policy) &&
      next.batch.every((call, index) => index === evidence.call_index || sameAgentCallJournal(call, current.batch[index]!))
    );
  }
  const target = evidence.target;
  if (evidence.kind === 'request_cancel') {
    if (
      target.task_id !== cas.task_id ||
      target.attempt_id !== cas.attempt_id ||
      !sameAgentRoot(current.root, evidence.root) ||
      !sameAgentRoot(next.root, evidence.root) ||
      !sameAgentPolicy(current.policy, next.policy) ||
      !sameAgentTranscript(current.transcript, next.transcript) ||
      current.tool_registry_version !== next.tool_registry_version ||
      current.toolset_sha256 !== next.toolset_sha256
    ) return false;
    if (target.kind === 'round' && current.round_lineage?.round_id !== target.round_id) return false;
    if (target.kind === 'tool') {
      const call = current.batch[target.call_index];
      if (call === undefined || call.call_id !== target.call_id || call.idempotency_key !== target.idempotency_key) return false;
    }
    const unchanged = current.batch.every((call, index) => sameAgentCallJournal(call, next.batch[index]!));
    if (next.phase === current.phase && unchanged) {
      return target.kind === 'attempt' ||
        (target.kind === 'round' && next.round_lineage?.status === 'cancel_requested') ||
        (target.kind === 'tool' && next.round_lineage?.status === 'cancel_requested');
    }
    if (next.phase !== 'cancelled') return false;
    return next.batch.every((call, index) => {
      const before = current.batch[index]!;
      return call.receipt !== null
        ? sameAgentCallJournal(call, before)
        : call.approval_decision === 'cancelled' &&
            call.approval_token === null &&
            call.approval_reference === null &&
            before.call_id === call.call_id &&
            before.name === call.name &&
            before.arguments_sha256 === call.arguments_sha256;
    });
  }
  return false;
}

function preflightEventMatchesPayload(
  evidence: AgentControllerPreflightV1,
  events: readonly PersistedSessionEventV3[],
  current: PersistedAgentAttemptJournalV3 | null | undefined,
  attemptId: string,
): boolean {
  const event = events.find(candidate => candidate.event_id === evidence.operation_id);
  if (event === undefined || event.attempt_id !== attemptId) {
    return false;
  }
  if (evidence.kind === 'begin_round') {
    return (
      event.kind === 'round' &&
      event.round_index === evidence.round_index &&
      event.call_id === null &&
      event.status === 'running' &&
      event.safe_summary_key === null &&
      event.arguments_sha256 === null &&
      event.result_sha256 === null &&
      event.failure_code === null
    );
  }
  if (evidence.kind === 'decide_approval') {
    return (
      event.kind === 'approval' &&
      event.round_index === evidence.round_index &&
      event.call_id === evidence.call_id &&
      event.status === 'approval' &&
      event.safe_summary_key === `agent.${evidence.name}` &&
      event.arguments_sha256 === evidence.arguments_sha256 &&
      event.result_sha256 === null &&
      event.approval_reference === evidence.operation_id &&
      event.failure_code === null
    );
  }
  if (evidence.kind === 'begin_execution') {
    return (
      event.kind === 'tool_call' &&
      event.round_index === evidence.round_index &&
      event.call_id === evidence.call_id &&
      event.status === 'running' &&
      event.safe_summary_key === `agent.${evidence.name}` &&
      event.arguments_sha256 === evidence.arguments_sha256 &&
      event.result_sha256 === null &&
      event.approval_reference === null &&
      event.failure_code === null
    );
  }
  const target = evidence.target;
  if (event.kind !== 'cancel' || event.status !== 'cancelled' || event.safe_summary_key !== null || event.result_sha256 !== null || event.failure_code !== evidence.cancel_token.reason_code) return false;
  if (target.kind === 'attempt') return event.round_index === null && event.call_id === null && event.arguments_sha256 === null;
  if (target.kind === 'round') return event.round_index === target.round_index && event.call_id === null && event.arguments_sha256 === null;
  const call = current?.batch[target.call_index];
  return call !== undefined && event.round_index === target.round_index && event.call_id === target.call_id && event.arguments_sha256 === call.arguments_sha256;
}

function postEvidenceOrderingIsValid(
  state: ChatState,
  evidence: AgentStoreTransitionEvidence,
  attemptId: string,
  candidateEvents?: readonly PersistedSessionEventV3[],
  acceptDurablePreflightOnly = false,
): boolean {
  const events = state.sessionEvents ?? [];
  if (evidence.kind === 'prepare_agent_attempt') return true;
  const has = (
    predicate: (event: PersistedSessionEventV3) => boolean,
  ): boolean => events.some(event => event.attempt_id === attemptId && predicate(event));
  const hasCandidate = (
    predicate: (event: PersistedSessionEventV3) => boolean,
  ): boolean => candidateEvents?.some(
    event => event.attempt_id === attemptId && event.event_id === evidence.operation_id && predicate(event),
  ) === true;
  if (evidence.kind === 'complete_agent_round_v2') {
    return has(event => event.kind === 'round' && event.round_index === evidence.request.round_index && event.status === 'running');
  }
  if (evidence.kind === 'prepare_agent_tool_batch') {
    return (
      hasCandidate(
        event =>
          event.kind === 'round' &&
          event.round_index === evidence.request.round_index &&
          event.status === 'running',
      ) &&
      has(
        event =>
          event.kind === 'round' &&
          event.round_index === evidence.request.round_index &&
          event.status === 'running',
      )
    );
  }
  if (evidence.kind === 'bind_agent_approval') {
    const request = evidence.request;
    const result = evidence.result;
    const preflight = events.find(
      event =>
        event.attempt_id === attemptId &&
        event.event_id === evidence.operation_id,
    );
    if (
      preflight === undefined ||
      preflight.kind !== 'approval' ||
      preflight.round_index !== request.round_index ||
      preflight.call_id !== request.call_id ||
      preflight.status !== 'approval' ||
      preflight.safe_summary_key !== `agent.${request.token.name}` ||
      preflight.arguments_sha256 !== request.token.arguments_sha256 ||
      preflight.result_sha256 !== null ||
      preflight.approval_reference !== evidence.operation_id ||
      preflight.failure_code !== null
    ) return false;
    const fresh = (candidateEvents ?? []).filter(
      event =>
        event.attempt_id === attemptId &&
        !events.some(existing => existing.event_id === event.event_id),
    );
    if (fresh.length !== 1 ||
        fresh[0]!.event_id === evidence.operation_id ||
        fresh[0]!.round_index !== request.round_index ||
        fresh[0]!.call_id !== request.call_id ||
        fresh[0]!.safe_summary_key !== `agent.${request.token.name}` ||
        fresh[0]!.arguments_sha256 !== request.token.arguments_sha256) {
      return false;
    }
    if (request.decision === 'denied') {
      // A user denial settles as a structured denied tool result.
      return (
        fresh[0]!.kind === 'tool_result' &&
        fresh[0]!.status === 'denied' &&
        result.receipt !== null &&
        fresh[0]!.result_sha256 === result.receipt.result_sha256 &&
        fresh[0]!.approval_reference === null &&
        fresh[0]!.failure_code === 'E_AGENT_DENIED_BY_USER'
      );
    }
    return (
      fresh[0]!.kind === 'approval' &&
      fresh[0]!.status === 'approval' &&
      fresh[0]!.result_sha256 === null &&
      fresh[0]!.approval_reference === result.approval_reference &&
      fresh[0]!.failure_code === null
    );
  }
  if (evidence.kind === 'execute_agent_tool') {
    const matchesExecution = (event: PersistedSessionEventV3) =>
      event.kind === 'tool_call' &&
      event.event_id === evidence.operation_id &&
      event.round_index === evidence.request.round_index &&
      event.call_id === evidence.request.call_id &&
      event.status === 'running';
    return (
      has(matchesExecution) &&
      (acceptDurablePreflightOnly || hasCandidate(matchesExecution))
    );
  }
  if (evidence.kind === 'cancel_agent_attempt') {
    const target = evidence.request.target;
    return has(event => event.kind === 'cancel' && event.approval_reference === event.event_id && (target.kind === 'attempt' ? event.round_index === null && event.call_id === null : target.kind === 'round' ? event.round_index === target.round_index && event.call_id === null : event.round_index === target.round_index && event.call_id === target.call_id));
  }
  return has(event => event.kind === 'round' || event.kind === 'tool_call' || event.kind === 'approval');
}

type AgentEvidenceTranscript = {
  readonly schema_version: 1;
  readonly transcript_ref: string;
  readonly generation: number;
  readonly transcript_sha256: string;
  readonly transcript_bytes: number;
};

function evidenceTranscript(value: unknown): AgentEvidenceTranscript | null {
  if (!isExactDataRecord(value, [
    'schema_version',
    'transcript_ref',
    'generation',
    'transcript_sha256',
    'transcript_bytes',
  ])) return null;
  return value as AgentEvidenceTranscript;
}

function evidenceRoundReceipt(value: unknown): CompletionRoundReceiptV1 | null {
  if (!isExactDataRecordWithOptional(value, [
    'schema_version',
    'transport_schema_version',
    'turn_id',
    'task_id',
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
  ], ['harness_id', 'provider_configuration'])) return null;
  if (value.harness_id !== undefined && !isHarnessId(value.harness_id)) {
    return null;
  }
  const receipt = value as unknown as {
    readonly schema_version: number;
    readonly transport_schema_version: 2 | 3;
    readonly turn_id: string;
    readonly task_id: string;
    readonly attempt_id: string;
    readonly round_id: string;
    readonly round_index: number;
    readonly provider_request_id: string;
    readonly provider_response_id: string;
    readonly harness_id?: CompletionRoundReceiptV1['harnessId'];
    readonly provider_configuration?: import('../providers/configuration').ProviderBinding;
    readonly requested_model: CompletionRoundReceiptV1['requestedModel'];
    readonly model: CompletionRoundReceiptV1['model'];
    readonly thinking_mode: CompletionRoundReceiptV1['thinkingMode'];
    readonly finish_reason: CompletionRoundReceiptV1['finishReason'];
    readonly latency_ms: number;
    readonly visible_history_sha256: string;
    readonly model_input_sha256: string;
    readonly request_body_sha256: string;
    readonly project_context_receipt: CompletionRoundReceiptV1['projectContextReceipt'];
  };
  if (receipt.schema_version !== 2) return null;
  return {
    schemaVersion: 1,
    transportSchemaVersion: receipt.transport_schema_version,
    harnessId: receipt.harness_id ?? 'dsh',
    ...(receipt.provider_configuration === undefined ? {} : { providerConfiguration: receipt.provider_configuration }),
    turnId: receipt.turn_id,
    attemptId: receipt.attempt_id,
    roundId: receipt.round_id,
    roundIndex: receipt.round_index,
    providerRequestId: receipt.provider_request_id,
    providerResponseId: receipt.provider_response_id,
    requestedModel: receipt.requested_model,
    model: receipt.model,
    thinkingMode: receipt.thinking_mode,
    finishReason: receipt.finish_reason,
    latencyMs: receipt.latency_ms,
    visibleHistorySha256: receipt.visible_history_sha256,
    modelInputSha256: receipt.model_input_sha256,
    requestBodySha256: receipt.request_body_sha256,
    projectContextReceipt: receipt.project_context_receipt,
  };
}

/**
 * A gated call refused for its arguments: native settled it as a failed
 * result before any approval was issued, so its approval is `cancelled`
 * with no token and it never became a write intent.
 */
function agentCallSettledBeforeApproval(call: PersistedAgentCallJournalV3): boolean {
  return call.access !== 'auto' && call.access !== 'durable_deny' &&
    call.approval_decision === 'cancelled' && call.approval_token === null &&
    call.receipt !== null && call.receipt.outcome === 'failed';
}

function projectionCallMatchesJournal(
  projection: Record<string, unknown>,
  call: PersistedAgentCallJournalV3,
  stage: 'attempt_projection' | 'prepared_batch' = 'attempt_projection',
): boolean {
  if (
    projection.call_index !== call.call_index ||
    projection.call_id !== call.call_id ||
    projection.name !== call.name ||
    projection.arguments_sha256 !== call.arguments_sha256 ||
    projection.idempotency_key !== call.idempotency_key ||
    projection.safe_summary_key !== call.safe_summary_key ||
    projection.access !== call.access ||
    projection.approval_reference !== call.approval_reference
  ) return false;
  const approvalState =
    call.access === 'auto'
      ? 'not_required'
      : call.access === 'durable_deny'
        ? 'denied'
        : call.approval_decision === 'pending'
          ? 'pending'
          : call.approval_decision === 'denied'
            ? 'denied'
            : call.approval_decision === 'cancelled'
              ? 'cancelled'
              : 'bound';
  if (projection.approval_state !== approvalState) return false;
  const token = projection.approval_token;
  if (call.approval_token === null) {
    if (token !== null) return false;
  } else if (
    !isExactDataRecord(token, [
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
    ]) ||
    token.token !== call.approval_token ||
    token.call_index !== call.call_index ||
    token.call_id !== call.call_id ||
    token.name !== call.name ||
    token.arguments_sha256 !== call.arguments_sha256 ||
    token.idempotency_key !== call.idempotency_key ||
    token.access !== call.access
  ) return false;
  if (stage === 'prepared_batch') {
    if (call.access === 'durable_deny') {
      if (
        call.approval_decision !== 'denied' ||
        call.idempotency_key !== null ||
        call.native_row_revision === null ||
        call.receipt === null ||
        call.receipt.outcome !== 'denied' ||
        projection.execution_status !== 'denied' ||
        projection.execution_revision !== null
      ) return false;
    } else if (call.receipt !== null) {
      // Refused arguments: native settled the call while preparing the batch
      // as a failed result the model can correct; it never got a token, and
      // a gated call's approval is cancelled rather than pending.
      if (
        call.receipt.outcome !== 'failed' ||
        (call.receipt.failure_code !== 'E_AGENT_BAD_ARGUMENTS' &&
          call.receipt.failure_code !== 'E_AGENT_BAD_PATH') ||
        call.idempotency_key === null ||
        call.approval_decision !== (call.access === 'auto' ? 'pending' : 'cancelled') ||
        call.approval_token !== null ||
        call.approval_reference !== null ||
        projection.execution_status !== 'failed' ||
        projection.execution_revision !== call.native_row_revision
      ) return false;
    } else if (
      call.idempotency_key === null ||
      projection.execution_status !== 'intent' ||
      projection.execution_revision !== 1 ||
      (call.access === 'auto'
        ? call.approval_decision !== 'pending'
        : isConversationGrantBoundCall(call)
          ? false
          : call.approval_decision !== 'pending' ||
          call.approval_token === null ||
          call.approval_reference !== null)
    ) return false;
    return projection.native_row_revision === call.native_row_revision &&
      (call.receipt === null
        ? projection.receipt === null
        : JSON.stringify(projection.receipt) === JSON.stringify(call.receipt));
  }
  const expectedExecutionStatus =
    call.receipt === null
      ? call.idempotency_key === null
        ? 'not_started'
        : call.approval_decision === 'denied'
          ? 'denied'
          : call.approval_decision === 'cancelled'
            ? 'cancelled'
            // A call that already has a ledger row is an open intent, which
            // is what native calls it -- the `prepared_batch` stage below
            // expects exactly that for the same shape. Demanding
            // `not_started` here meant no attempt waiting on an approval
            // could ever be recovered: its projection and its journal
            // described the same call in two different words.
            : call.native_row_revision === null
              ? 'not_started'
              : 'intent'
      : call.receipt.outcome === 'ok'
        ? 'completed'
        : call.receipt.outcome;
  if (projection.execution_status !== expectedExecutionStatus) return false;
  // The revision of the ledger row this call owns, which an open intent has
  // as surely as a settled result does.
  if (projection.execution_revision !== call.native_row_revision) return false;
  return projection.native_row_revision === call.native_row_revision &&
    (call.receipt === null
      ? projection.receipt === null
      : JSON.stringify(projection.receipt) === JSON.stringify(call.receipt));
}

function evidenceAttemptProjectionMatchesJournal(
  projection: unknown,
  journal: PersistedAgentAttemptJournalV3,
  identity?: {
    readonly taskId: string;
    readonly conversationId: string;
    readonly attemptId: string;
  },
  stage: 'attempt_projection' | 'prepared_batch' = 'attempt_projection',
): boolean {
  if (!isExactDataRecord(projection, [
    'schema_version',
    'task_id',
    'conversation_id',
    'attempt_id',
    'phase',
    'controller_generation',
    'journal_revision',
    'authority_revision',
    'root',
    'policy',
    'registry',
    'transcript',
    'round_index',
    'round_id',
    'round_revision',
    'round_status',
    'batch_kind',
    'batch_revision',
    'manifest_sha256',
    'call_index',
    'batch',
    'frozen_grant_ids',
    'reserved_write_bytes',
    'cancel_source_event_id',
    'cleanup_id',
  ])) return false;
  const value = projection;
  // Native opens a write manifest only for calls that became executable
  // intents: durable denials and calls refused for their arguments never
  // reach it, so a batch of only those (plus reads) is read-only.
  const expectedBatchKind =
    journal.batch.length === 0
      ? null
      : journal.batch.every(call =>
        call.access === 'auto' ||
        call.access === 'durable_deny' ||
        agentCallSettledBeforeApproval(call))
        ? 'read_only_batch'
        : 'write_batch';
  if (
    value.schema_version !== 2 ||
    (identity !== undefined &&
      (value.task_id !== identity.taskId ||
        value.conversation_id !== identity.conversationId ||
        value.attempt_id !== identity.attemptId)) ||
    value.phase !== journal.phase ||
    value.controller_generation !== journal.controller_generation ||
    typeof value.journal_revision !== 'number' ||
    !Number.isSafeInteger(value.journal_revision) ||
    value.journal_revision < 0 ||
    value.round_index !== journal.round_index ||
    value.round_id !== (journal.round_lineage?.round_id ?? null) ||
    value.round_revision !== (journal.round_lineage?.native_row_revision ?? null) ||
    value.round_status !== (journal.round_lineage?.status ?? null) ||
    value.call_index !== journal.call_index ||
    value.batch_kind !== expectedBatchKind ||
    (expectedBatchKind === null
      ? value.batch_revision !== null || value.manifest_sha256 !== null
      : value.batch_revision === null ||
        (expectedBatchKind === 'read_only_batch'
          ? value.manifest_sha256 !== null
          : value.manifest_sha256 === null)) ||
    value.reserved_write_bytes !== journal.reserved_write_bytes ||
    !Array.isArray(value.frozen_grant_ids) ||
    value.root === null ||
    value.policy === null ||
    value.transcript === null ||
    !sameAgentStringArray(value.frozen_grant_ids as string[], journal.frozen_grant_ids) ||
    !sameAgentRoot(value.root as FrozenAgentRootV1, journal.root) ||
    !sameAgentPolicy(value.policy as AgentWritePolicyV1, journal.policy) ||
    !sameAgentTranscript(value.transcript as AgentTranscriptReferenceV1, journal.transcript)
  ) return false;
  if (!Array.isArray(value.batch)) return false;
  if (value.batch.length !== journal.batch.length) return false;
  return value.batch.every((call, index) =>
    isExactDataRecord(call, [
      'schema_version',
      'call_index',
      'call_id',
      'name',
      'arguments_sha256',
      'idempotency_key',
      'safe_summary_key',
      'approval_preview',
      'access',
      'approval_state',
      'approval_token',
      'approval_reference',
      'execution_status',
      'execution_revision',
      'native_row_revision',
      'receipt',
    ]) && projectionCallMatchesJournal(call, journal.batch[index]!, stage),
  );
}

/**
 * Why a round ended, when the round said so.
 *
 * A round that failed retryably carries the code native derived from what
 * the provider -- or the transport, before the request ever reached one --
 * reported. It is the only account of why the turn ended, and both the
 * attempt and the terminal event are derived from this one answer so the two
 * can never disagree about it.
 *
 * The codes that belong to other phases are refused here: the conflict code
 * is what an `unknown` journal means and the execution ambiguity is what an
 * `ambiguous` one means, and a `failed` journal wearing either would make
 * the three indistinguishable on the way back in.
 */
function evidenceRoundCauseFor(
  evidence: AgentCheckpointEvidence,
): AgentFailureCode | null {
  if (isControllerPreflight(evidence)) return null;
  if (
    evidence.kind !== 'complete_agent_round_v2' ||
    evidence.result.status !== 'failed_retryable'
  ) return null;
  const code = evidence.result.failure_code;
  if (!isAgentFailureCode(code)) return null;
  return code === 'E_AGENT_CONFLICT' || code === 'E_AGENT_EXECUTION_AMBIGUOUS'
    ? null
    : code;
}

function evidenceRoundReceiptFor(
  evidence: AgentCheckpointEvidence,
): CompletionRoundReceiptV1 | undefined {
  if (isControllerPreflight(evidence)) return undefined;
  let raw: unknown = null;
  if (evidence.kind === 'complete_agent_round_v2' && evidence.result.status === 'completed') {
    raw = evidence.result.outcome.completion_receipt;
  } else if (evidence.kind === 'recover_agent_attempt' && evidence.result.completed_round !== null) {
    raw = evidence.result.completed_round.completion_receipt;
  }
  const receipt = evidenceRoundReceipt(raw);
  return receipt === null ? undefined : receipt;
}

function approvalEvidenceGrantsMatch(
  evidence: AgentCheckpointEvidence,
  grants: readonly AgentConversationGrantV2[],
  currentGrants: readonly AgentConversationGrantV2[],
): boolean {
  try {
    const grant = isControllerPreflight(evidence)
      ? evidence.kind === 'decide_approval'
        ? evidence.grant
        : null
      : evidence.kind === 'bind_agent_approval'
        ? evidence.result.grant
        : null;
    if (
      (!isControllerPreflight(evidence) && evidence.kind !== 'bind_agent_approval') ||
      (isControllerPreflight(evidence) && evidence.kind !== 'decide_approval')
    ) return false;
    if (!isControllerPreflight(evidence)) {
      return (
        sameAgentGrants(grants, currentGrants) &&
        (grant === null ||
          grants.some(candidate => sameAgentGrant(candidate, grant)))
      );
    }
    if (grant === null) return sameAgentGrants(grants, currentGrants);
    const existing = currentGrants.find(
      candidate => candidate.grant_id === grant.grant_id,
    );
    if (existing !== undefined) {
      return sameAgentGrant(existing, grant) && sameAgentGrants(grants, currentGrants);
    }
    return (
      grants.length === currentGrants.length + 1 &&
      currentGrants.every((candidate, index) =>
        sameAgentGrant(candidate, grants[index]!),
      ) &&
      sameAgentGrant(grants[grants.length - 1]!, grant)
    );
  } catch {
    return false;
  }
}

function highLevelEvidenceSupportsTransition(
  current: PersistedAgentAttemptJournalV3 | null | undefined,
  next: PersistedAgentAttemptJournalV3,
  evidence: AgentStoreTransitionEvidence,
  cas: AgentControllerCASV1,
): boolean {
  if (!agentEvidenceMatchesControllerCAS(evidence, cas)) return false;
  const result = evidence.result as unknown as Record<string, unknown>;
  const nextLineage = next.round_lineage;
  if (current === undefined || current === null) {
    if (evidence.kind !== 'prepare_agent_attempt' ||
      (result.status !== 'prepared' && result.status !== 'already_prepared') ||
      !evidenceAttemptProjectionMatchesJournal(result.attempt, next, {
        taskId: evidence.request.controller_cas.task_id,
        conversationId: evidence.request.controller_cas.conversation_id,
        attemptId: evidence.request.controller_cas.attempt_id,
      })) return false;
    return next.phase === 'ready_for_round' && next.batch.length === 0 && next.call_index === null;
  }
  if (!isAgentAttemptJournalV3(current) || !agentPhaseTransitionIsLegalAny(current, next)) return false;
  const importsPreparedGrantReferences = evidence.kind === 'prepare_agent_tool_batch' ||
    (evidence.kind === 'recover_agent_attempt' && evidence.result.status === 'resumed' &&
      evidence.result.next_action === 'persist_batch' && evidence.result.completed_round?.kind === 'tool_batch' && current.batch.length === 0);
  if (!sameAgentRoot(current.root, next.root) || !sameAgentPolicy(current.policy, next.policy) ||
    current.tool_registry_version !== next.tool_registry_version ||
    current.toolset_sha256 !== next.toolset_sha256 ||
    !sameAgentStringArray(importsPreparedGrantReferences ? conversationGrantIdsForBatch(current, next.batch) : current.frozen_grant_ids, next.frozen_grant_ids) ||
    next.controller_generation !== current.controller_generation + 1) return false;
  const requestCas = evidence.request.controller_cas;
  if (requestCas.expected_controller_generation !== current.controller_generation) return false;
  if (evidence.kind === 'prepare_agent_attempt') {
    if (evidence.result.status !== 'prepared' && evidence.result.status !== 'already_prepared') return false;
    return evidenceAttemptProjectionMatchesJournal(evidence.result.attempt, next, {
      taskId: requestCas.task_id,
      conversationId: requestCas.conversation_id,
      attemptId: requestCas.attempt_id,
    });
  }
  if (evidence.kind === 'complete_agent_round_v2') {
    const roundRequest = evidence.request;
    const roundResult = evidence.result;
    if (current.round_lineage === null ||
      roundRequest.round_id !== current.round_lineage.round_id ||
      roundRequest.round_index !== current.round_lineage.round_index ||
      roundResult.round_id !== roundRequest.round_id ||
      roundResult.round_index !== roundRequest.round_index) return false;
    const transcript = evidenceTranscript(roundResult.transcript);
    if (transcript === null || !sameAgentTranscript(transcript, next.transcript)) return false;
    if (roundResult.status === 'completed') {
      const outcome = roundResult.outcome;
      const expectedPhase = outcome.kind === 'final' ? 'final_response' : outcome.kind === 'blocked' ? 'failed' :
        next.batch.some(call => call.access !== 'auto' && call.access !== 'durable_deny' && call.approval_decision === 'pending')
          ? 'approval_pending' : 'batch_frozen';
      if (next.phase !== expectedPhase || nextLineage?.status !== 'completed' ||
        nextLineage.native_row_revision !== roundResult.result_round_revision ||
        !sameAgentTranscript(outcome.transcript, next.transcript)) return false;
      const mappedReceipt = evidenceRoundReceiptFor(evidence);
      return mappedReceipt !== undefined &&
        mappedReceipt.roundId === nextLineage.round_id &&
        mappedReceipt.roundIndex === nextLineage.round_index;
    }
    if (roundResult.status === 'in_flight') {
      return next.phase === 'round_in_flight' && nextLineage?.status === 'active' &&
        nextLineage.native_row_revision === roundResult.result_round_revision;
    }
    if (roundResult.status === 'failed_retryable') {
      return next.phase === 'failed' && nextLineage?.status === 'failed_retryable' &&
        nextLineage.native_row_revision === roundResult.result_round_revision;
    }
    if (roundResult.status === 'cancelled') {
      return next.phase === 'cancelled' && nextLineage?.status === 'cancelled' &&
        nextLineage.native_row_revision === roundResult.result_round_revision;
    }
    if (roundResult.status === 'unknown') {
      return next.phase === 'unknown' && nextLineage?.status === 'unknown' &&
        nextLineage.native_row_revision === roundResult.result_round_revision;
    }
    return next.phase === 'ambiguous' && nextLineage?.status === 'ambiguous' &&
      nextLineage.native_row_revision === roundResult.result_round_revision;
  }
  if (evidence.kind === 'prepare_agent_tool_batch') {
    const request = evidence.request;
    const batchResult = evidence.result;
    if (batchResult.status === 'rejected') return false;
    const receipt = batchResult.receipt;
    const firstUnsettledCall = next.batch.findIndex(call => call.receipt === null);
    const batchSettled = next.batch.length > 0 && firstUnsettledCall < 0;
    const expectedPhase = next.batch.some(call =>
      call.receipt === null &&
      call.access !== 'auto' &&
      call.access !== 'durable_deny' &&
      call.approval_decision === 'pending')
      ? 'approval_pending'
      : batchSettled
        ? 'tool_result_pending'
        : 'batch_frozen';
    if (current.phase !== 'batch_frozen' || current.batch.length !== 0 ||
      current.call_index !== null || current.round_lineage === null ||
      current.round_lineage.status !== 'completed' ||
      request.round_id !== current.round_lineage.round_id ||
      request.round_index !== current.round_index ||
      request.expected_round_revision !== current.round_lineage.native_row_revision ||
      !sameAgentTranscript(request.transcript, current.transcript) ||
      !sameAgentRoot(request.root, current.root) ||
      request.expected_reserved_write_bytes !== current.reserved_write_bytes ||
      nextLineage === null || !sameAgentRoundLineage(current.round_lineage, nextLineage) ||
      next.phase !== expectedPhase ||
      next.call_index !== (batchSettled ? next.batch.length - 1 : firstUnsettledCall < 0 ? null : firstUnsettledCall) ||
      receipt.task_id !== requestCas.task_id || receipt.attempt_id !== requestCas.attempt_id ||
      receipt.round_id !== nextLineage?.round_id || receipt.round_index !== next.round_index ||
      !sameAgentTranscript(receipt.transcript, next.transcript) ||
      receipt.reserved_write_bytes !== next.reserved_write_bytes ||
      receipt.calls.length !== next.batch.length ||
      !receipt.calls.every((call, index) =>
        projectionCallMatchesJournal(
          call as unknown as Record<string, unknown>,
          next.batch[index]!,
          'prepared_batch',
        ),
      )) return false;
    return true;
  }
  if (evidence.kind === 'bind_agent_approval') {
    const request = evidence.request;
    const bind = evidence.result;
    const token = request.token;
    const beforeCall = current.batch[request.call_index];
    const afterCall = next.batch[request.call_index];
    const firstUnsettledCall = current.batch.findIndex(
      call => call.receipt === null,
    );
    const allowedDecision =
      request.decision === 'allow_once' ||
      request.decision === 'allow_conversation';
    if (request.decision === 'denied') {
      // A user denial is a settled tool result: the native bind appended the
      // protected denial feedback, settled the intent row with a denied
      // receipt, and returned the exact settlement for persistence. The next
      // journal carries that receipt and transcript; execution of this call
      // is impossible and the remaining batch may continue.
      const remainingPending = next.batch.some(
        call =>
          call.access !== 'auto' &&
          call.access !== 'durable_deny' &&
          call.approval_decision === 'pending',
      );
      const allSettled = next.batch.every(call => call.receipt !== null);
      const expectedNextPhase = remainingPending
        ? 'approval_pending'
        : allSettled
          ? 'tool_result_pending'
          : 'batch_frozen';
      const expectedNextCallIndex = allSettled
        ? request.call_index
        : next.batch.findIndex(call => call.receipt === null);
      if (
        (current.phase !== 'batch_frozen' &&
          current.phase !== 'approval_pending') ||
        next.phase !== expectedNextPhase ||
        bind.task_id !== requestCas.task_id ||
        bind.attempt_id !== requestCas.attempt_id ||
        bind.round_id !== request.round_id ||
        current.round_lineage === null ||
        next.round_lineage === null ||
        current.round_lineage.round_id !== request.round_id ||
        next.round_lineage.round_id !== request.round_id ||
        current.round_lineage.round_index !== request.round_index ||
        next.round_lineage.round_index !== request.round_index ||
        current.round_lineage.launch_attempt !== next.round_lineage.launch_attempt ||
        current.round_lineage.status !== next.round_lineage.status ||
        current.round_lineage.native_row_revision !== next.round_lineage.native_row_revision ||
        current.round_index !== request.round_index ||
        next.round_index !== request.round_index ||
        firstUnsettledCall < 0 ||
        current.call_index !== firstUnsettledCall ||
        beforeCall === undefined ||
        afterCall === undefined ||
        beforeCall.call_id !== request.call_id ||
        beforeCall.call_id !== bind.call_id ||
        beforeCall.name !== token.name ||
        beforeCall.arguments_sha256 !== token.arguments_sha256 ||
        beforeCall.access !== token.access ||
        // The denial preflight already dropped the executable token.
        beforeCall.approval_token !== null ||
        beforeCall.approval_decision !== 'denied' ||
        beforeCall.approval_reference !== null ||
        beforeCall.receipt !== null ||
        bind.approval_reference !== null ||
        bind.receipt === null ||
        bind.transcript === null ||
        bind.receipt.call_id !== request.call_id ||
        bind.receipt.name !== token.name ||
        bind.receipt.arguments_sha256 !== token.arguments_sha256 ||
        bind.receipt.outcome !== 'denied' ||
        bind.receipt.failure_code !== 'E_AGENT_DENIED_BY_USER' ||
        bind.receipt.approval_reference !== null ||
        !sameAgentTranscript(bind.transcript, next.transcript) ||
        afterCall.approval_decision !== 'denied' ||
        afterCall.approval_token !== null ||
        afterCall.approval_reference !== null ||
        afterCall.native_row_revision !== 2 ||
        afterCall.receipt === null ||
        !sameAgentReceipt(
          afterCall.receipt,
          bind.receipt as unknown as AgentToolReceiptV1,
        ) ||
        next.call_index !== expectedNextCallIndex ||
        request.batch_revision !== token.batch_revision ||
        bind.result_batch_revision !== request.batch_revision ||
        token.round_id !== request.round_id ||
        token.round_index !== request.round_index ||
        token.call_index !== request.call_index ||
        token.call_id !== request.call_id ||
        token.batch_call_ids.length !== current.batch.length ||
        token.batch_arguments_sha256.length !== current.batch.length ||
        !current.batch.every(
          (call, index) =>
            token.batch_call_ids[index] === call.call_id &&
            token.batch_arguments_sha256[index] === call.arguments_sha256,
        ) ||
        token.root_fingerprint_sha256 !== current.root.root_fingerprint_sha256 ||
        token.binding_revision !== current.root.workspace_binding_revision ||
        token.policy_version !== current.policy.policy_version ||
        token.registry_version !== current.tool_registry_version ||
        current.batch.length !== next.batch.length ||
        !current.batch.every((call, index) =>
          index === request.call_index ||
          sameAgentCallJournal(call, next.batch[index]!),
        ) ||
        current.reserved_write_bytes !== next.reserved_write_bytes
      ) {
        return false;
      }
      return true;
    }
    if (
      !allowedDecision ||
      (current.phase !== 'batch_frozen' && current.phase !== 'approval_pending') ||
      next.phase !== current.phase ||
      bind.task_id !== requestCas.task_id ||
      bind.attempt_id !== requestCas.attempt_id ||
      bind.round_id !== request.round_id ||
      current.round_lineage === null ||
      next.round_lineage === null ||
      current.round_lineage.round_id !== request.round_id ||
      next.round_lineage.round_id !== request.round_id ||
      current.round_lineage.round_index !== request.round_index ||
      next.round_lineage.round_index !== request.round_index ||
      current.round_lineage.launch_attempt !== next.round_lineage.launch_attempt ||
      current.round_lineage.status !== next.round_lineage.status ||
      current.round_lineage.native_row_revision !== next.round_lineage.native_row_revision ||
      current.round_index !== request.round_index ||
      next.round_index !== request.round_index ||
      firstUnsettledCall < 0 ||
      current.call_index !== firstUnsettledCall ||
      next.call_index !== current.call_index ||
      beforeCall === undefined ||
      afterCall === undefined ||
      beforeCall.call_id !== request.call_id ||
      beforeCall.call_id !== bind.call_id ||
      beforeCall.call_index !== request.call_index ||
      beforeCall.name !== token.name ||
      beforeCall.arguments_sha256 !== token.arguments_sha256 ||
      beforeCall.access !== token.access ||
      beforeCall.approval_token !== token.token ||
      beforeCall.approval_decision !== request.decision ||
      beforeCall.approval_reference !== evidence.operation_id ||
      beforeCall.approval_reference !== bind.approval_reference ||
      beforeCall.receipt !== null ||
      request.batch_revision !== token.batch_revision ||
      bind.result_batch_revision !== request.batch_revision ||
      token.round_id !== request.round_id ||
      token.round_index !== request.round_index ||
      token.call_index !== request.call_index ||
      token.call_id !== request.call_id ||
      token.batch_call_ids.length !== current.batch.length ||
      token.batch_arguments_sha256.length !== current.batch.length ||
      !current.batch.every(
        (call, index) =>
          token.batch_call_ids[index] === call.call_id &&
          token.batch_arguments_sha256[index] === call.arguments_sha256,
      ) ||
      token.root_fingerprint_sha256 !== current.root.root_fingerprint_sha256 ||
      token.binding_revision !== current.root.workspace_binding_revision ||
      token.policy_version !== current.policy.policy_version ||
      token.registry_version !== current.tool_registry_version ||
      current.batch.length !== next.batch.length ||
      !current.batch.every((call, index) =>
        sameAgentCallJournal(call, next.batch[index]!),
      ) ||
      current.reserved_write_bytes !== next.reserved_write_bytes
    ) return false;
    const grant = bind.grant;
    return grant === null
      ? request.decision === 'allow_once'
      : request.decision === 'allow_conversation' &&
          current.frozen_grant_ids.includes(grant.grant_id) &&
          next.frozen_grant_ids.includes(grant.grant_id);
  }
  if (evidence.kind === 'execute_agent_tool') {
    const execution = evidence.result;
    if (execution.task_id !== requestCas.task_id || execution.attempt_id !== requestCas.attempt_id ||
      next.round_lineage?.round_id !== execution.round_id || next.round_index !== execution.round_index ||
      next.call_index !== execution.call_index) return false;
    const call = next.batch[execution.call_index];
    if (call === undefined || call.call_id !== execution.call_id || call.name !== execution.name ||
      call.idempotency_key !== execution.idempotency_key || !sameAgentTranscript(execution.transcript, next.transcript)) return false;
    if (execution.status === 'running' || execution.status === 'cancel_requested') {
      return next.phase === 'execution_intent' && execution.receipt === null && call.receipt === null &&
        call.native_row_revision === execution.result_execution_revision;
    }
    if (execution.status === 'unknown' || execution.status === 'ambiguous') {
      return next.phase === execution.status && execution.receipt === null && call.receipt === null &&
        call.native_row_revision === execution.result_execution_revision;
    }
    if (execution.status === 'cancelled') {
      if (execution.receipt === null || call.receipt === null ||
        !sameAgentReceipt(call.receipt, execution.receipt as unknown as AgentToolReceiptV1)) return false;
      return next.phase === 'cancelled' && call.native_row_revision === execution.result_execution_revision;
    }
    if (execution.receipt === null || call.receipt === null ||
      !sameAgentReceipt(call.receipt, execution.receipt as unknown as AgentToolReceiptV1)) return false;
    return next.phase === 'tool_result_pending' && call.native_row_revision === execution.result_execution_revision;
  }
  if (evidence.kind === 'cancel_agent_attempt') {
    const cancellation = evidence.result;
    const target = evidence.request.target;
    const resultTarget = cancellation.target;
    const targetsMatch =
      resultTarget.schema_version === target.schema_version &&
      resultTarget.kind === target.kind &&
      resultTarget.task_id === target.task_id &&
      resultTarget.attempt_id === target.attempt_id &&
      (target.kind === 'attempt'
        ? resultTarget.kind === 'attempt'
        : target.kind === 'round'
          ? resultTarget.kind === 'round' &&
            resultTarget.round_id === target.round_id &&
            resultTarget.round_index === target.round_index
          : resultTarget.kind === 'tool' &&
            resultTarget.round_id === target.round_id &&
            resultTarget.round_index === target.round_index &&
            resultTarget.call_index === target.call_index &&
            resultTarget.call_id === target.call_id &&
            resultTarget.idempotency_key === target.idempotency_key);
    const revisionsMatch =
      target.kind === 'attempt'
        ? cancellation.result_round_revision === null && cancellation.result_execution_revision === null
        : target.kind === 'round'
          ? cancellation.result_round_revision === nextLineage?.native_row_revision &&
            cancellation.result_execution_revision === null
          : cancellation.result_round_revision === null &&
            cancellation.result_execution_revision === next.batch[target.call_index]?.native_row_revision;
    if (!targetsMatch || !revisionsMatch) return false;
    if (!sameAgentTranscript(cancellation.transcript, next.transcript)) return false;
    const nextCall =
      target.kind === 'tool' ? next.batch[target.call_index] : undefined;
    if (
      cancellation.receipt === null
        ? target.kind === 'tool' &&
          (cancellation.status === 'cancelled' ||
            cancellation.status === 'already_cancelled' ||
            cancellation.status === 'settled')
        : target.kind !== 'tool' ||
          nextCall?.receipt === null ||
          nextCall?.receipt === undefined ||
          !sameAgentReceipt(
            nextCall.receipt,
            cancellation.receipt as unknown as AgentToolReceiptV1,
          )
    ) return false;
    if (cancellation.status === 'cancel_requested') return next.phase === current.phase;
    if (cancellation.status === 'cancelled' || cancellation.status === 'already_cancelled') return next.phase === 'cancelled';
    if (cancellation.status === 'unknown') return next.phase === 'unknown';
    if (cancellation.status === 'ambiguous') return next.phase === 'ambiguous';
    if (cancellation.receipt?.outcome === 'cancelled') {
      return next.phase === 'cancelled';
    }
    if (cancellation.receipt?.outcome === 'ambiguous') {
      return next.phase === 'ambiguous';
    }
    return next.phase === 'tool_result_pending';
  }
  const recovery = evidence.result;
  const rebasedRecoveryProjection = {
    ...recovery.attempt,
    controller_generation: next.controller_generation,
  };
  if (!evidenceAttemptProjectionMatchesJournal(rebasedRecoveryProjection, next, {
    taskId: requestCas.task_id,
    conversationId: requestCas.conversation_id,
    attemptId: requestCas.attempt_id,
  }, recovery.status === 'resumed' && recovery.next_action === 'persist_batch' ? 'prepared_batch' : 'attempt_projection')) return false;
  if (recovery.status === 'retryable') return next.phase === 'round_in_flight' || next.phase === 'failed';
  if (recovery.status === 'manual_reconciliation') return next.phase === 'unknown' || next.phase === 'ambiguous';
  if (recovery.status === 'terminal') return next.phase === 'final_response' || next.phase === 'cancelled' || next.phase === 'failed';
  if (
    recovery.status === 'resumed' &&
    recovery.next_action === 'none' &&
    evidence.request.target.kind === 'attempt' &&
    recovery.completed_round === null
  ) {
    // A round that never reached native at all is reset to the start.
    if (
      current.phase === 'round_in_flight' &&
      current.round_lineage?.native_row_revision === null
    ) {
      return next.phase === 'ready_for_round' &&
        next.round_lineage === null &&
        next.batch.length === 0 &&
        next.call_index === null;
    }
    // Otherwise the attempt is simply standing still -- waiting on an
    // approval, or between rounds -- and there is nothing to reconcile.
    // Native said where it stands, the projection check above already bound
    // `next` to that answer, so the only transition this can be is the one
    // that leaves it there. Without this the reducer refused every recovery
    // of a turn that was waiting for a person, and the question never came
    // back on screen.
    return next.phase === current.phase;
  }
  switch (recovery.next_action) {
    case 'persist_round':
      return next.phase === 'round_in_flight';
    case 'persist_batch':
      return next.phase === 'batch_frozen' || next.phase === 'approval_pending';
    case 'persist_approval':
      return next.phase === 'approval_pending' || next.phase === 'batch_frozen';
    case 'persist_tool_result':
      return next.phase === 'tool_result_pending' || next.phase === 'cancelled';
    case 'persist_final':
      return next.phase === 'final_response' || next.phase === 'failed';
    case 'none':
      return next.phase === 'final_response' || next.phase === 'cancelled' || next.phase === 'failed';
  }
}

// eslint-disable-next-line @typescript-eslint/no-unused-vars
function agentCheckpointEventMatchesTransition(
  state: ChatState,
  attemptId: string,
  current: PersistedAgentAttemptJournalV2 | null | undefined,
  next: PersistedAgentAttemptJournalV2,
  events: readonly PersistedSessionEventV3[],
  roundReceipt?: CompletionRoundReceiptV1,
): boolean {
  const previous = state.sessionEvents ?? [];
  const fresh = events.filter(
    event => !previous.some(existing => existing.event_id === event.event_id),
  );
  if (fresh.length === 0 || fresh.some(event => event.attempt_id !== attemptId)) {
    return false;
  }
  if (
    next.phase === 'cancelled' &&
    fresh.some(
      event =>
        event.kind === 'cancel' &&
        event.status === 'cancelled' &&
        event.approval_reference === event.event_id,
    )
  ) {
    return true;
  }
  const expected = (() => {
    switch (next.phase) {
      case 'ready_for_round':
        return { kind: 'round' as const, status: 'waiting' as const };
      case 'round_in_flight':
        return { kind: 'round' as const, status: 'running' as const };
      case 'approval_pending':
        return { kind: 'approval' as const, status: 'approval' as const };
      case 'batch_frozen':
        if (current?.phase === 'approval_pending') {
          return { kind: 'approval' as const, status: 'approval' as const };
        }
        return next.batch.some(
          call =>
            call.access !== 'auto' &&
            call.access !== 'durable_deny' &&
            call.approval_decision === 'pending',
        )
          ? { kind: 'approval' as const, status: 'approval' as const }
          : { kind: 'tool_call' as const, status: 'waiting' as const };
      case 'execution_intent':
        return { kind: 'tool_call' as const, status: 'running' as const };
      case 'tool_result_pending': {
        const call =
          next.call_index === null ? undefined : next.batch[next.call_index];
        const outcome = call?.receipt?.outcome;
        return outcome === undefined || outcome === 'ambiguous'
          ? null
          : { kind: 'tool_result' as const, status: outcome };
      }
      case 'final_response':
        return { kind: 'terminal' as const, status: 'ok' as const };
      case 'cancelled':
        return { kind: 'terminal' as const, status: 'cancelled' as const };
      case 'failed':
        return { kind: 'terminal' as const, status: 'failed' as const };
      case 'unknown':
        return { kind: 'terminal' as const, status: 'unknown' as const };
      case 'ambiguous':
        return { kind: 'terminal' as const, status: 'ambiguous' as const };
    }
  })();
  if (expected === null) return false;
  const expectedFailureCode =
    next.phase === 'failed' &&
    current?.phase === 'round_in_flight' &&
    roundReceipt?.finishReason === 'length'
      ? 'E_COMPLETION_LENGTH'
      : next.phase === 'failed' &&
          current?.phase === 'round_in_flight' &&
          roundReceipt?.finishReason === 'content_filter'
        ? 'E_COMPLETION_CONTENT_FILTER'
        : undefined;
  return fresh.some(
    event =>
      event.kind === expected.kind &&
      event.status === expected.status &&
      (expectedFailureCode === undefined ||
        event.failure_code === expectedFailureCode) &&
      (expected.kind === 'round'
        ? event.round_index === next.round_index
        : expected.kind === 'terminal'
          ? event.round_index === null && event.call_id === null
          : event.round_index === next.round_index),
  );
}

function sameAgentReceipt(
  left: AgentToolReceiptV1,
  right: AgentToolReceiptV1,
): boolean {
  return (
    left.schema_version === right.schema_version &&
    left.call_id === right.call_id &&
    left.name === right.name &&
    left.arguments_sha256 === right.arguments_sha256 &&
    left.result_sha256 === right.result_sha256 &&
    left.result_bytes === right.result_bytes &&
    left.truncated === right.truncated &&
    left.duration_ms === right.duration_ms &&
    left.outcome === right.outcome &&
    left.failure_code === right.failure_code &&
    left.approval_reference === right.approval_reference
  );
}

function agentOuterAttemptCheckpoint(
  attempt: TurnAttemptV1,
  journal: PersistedAgentAttemptJournalV2 | PersistedAgentAttemptJournalV3,
  roundReceipt: CompletionRoundReceiptV1 | undefined,
  at: string,
  allowRecordedRound = false,
  // Why the round ended, from the same evidence the terminal event reads. A
  // checkpoint with no evidence to read passes nothing and the generic
  // answer stands, which is what a journal-only checkpoint has always done.
  cause: AgentFailureCode | null = null,
): TurnAttemptV1 | null {
  if (
    attempt.status === 'completed' ||
    attempt.assistantMessageId !== null
  ) return null;
  if (
    attempt.agent?.phase === 'round_in_flight' &&
    journal.phase !== 'round_in_flight' &&
    journal.phase !== 'failed' &&
    journal.phase !== 'unknown' &&
    journal.phase !== 'ambiguous' &&
    journal.phase !== 'cancelled' &&
    roundReceipt === undefined &&
    !(
      attempt.agent.round_lineage?.native_row_revision === null &&
      journal.phase === 'ready_for_round' &&
      journal.round_lineage === null
    )
  ) return null;
  let rounds = attempt.rounds;
  if (roundReceipt !== undefined) {
    const recorded = attempt.rounds[roundReceipt.roundIndex];
    const alreadyRecorded = allowRecordedRound && recorded !== undefined &&
      JSON.stringify(copyRoundReceipt(recorded)) === JSON.stringify(copyRoundReceipt(roundReceipt));
    if (
      !receiptIsValid(attempt, roundReceipt) ||
      (!alreadyRecorded && roundReceipt.roundIndex !== attempt.rounds.length) ||
      journal.round_lineage === null ||
      journal.round_lineage.round_id !== roundReceipt.roundId ||
      journal.round_lineage.round_index !== roundReceipt.roundIndex ||
      journal.round_lineage.status !== 'completed' ||
      (!alreadyRecorded && attempt.rounds.some(round => round.roundId === roundReceipt.roundId))
    ) return null;
    if (!alreadyRecorded) rounds = [...attempt.rounds, copyRoundReceipt(roundReceipt)];
  }
  const activeRound =
    journal.phase === 'round_in_flight' && journal.round_lineage !== null
      ? {
          roundId: journal.round_lineage.round_id,
          roundIndex: journal.round_lineage.round_index,
        }
      : null;
  const status: TurnAttemptV1['status'] =
    journal.phase === 'round_in_flight'
      ? 'sending'
      : journal.phase === 'cancelled'
        ? 'cancelled'
        : journal.phase === 'failed' ||
            journal.phase === 'unknown' ||
            journal.phase === 'ambiguous'
          ? 'failed'
          : 'prepared';
  const failureCode: TurnAttemptV1['failureCode'] =
    status !== 'failed'
      ? null
      // Which uncertainty this is decides what the person is told: a round
      // that may have reached the service, or a tool that may already have
      // changed their files. `agentAmbiguityCode` reads it off the batch.
      : journal.phase === 'ambiguous'
        ? agentAmbiguityCode(journal)
        : journal.phase === 'unknown'
          ? 'E_AGENT_CONFLICT'
          : journal.phase === 'failed' &&
              roundReceipt?.finishReason === 'length'
            ? 'E_COMPLETION_LENGTH'
          : journal.phase === 'failed' &&
              roundReceipt?.finishReason === 'content_filter'
            ? 'E_COMPLETION_CONTENT_FILTER'
          : journal.round_index >= MAX_AGENT_ROUNDS - 1 &&
              journal.round_lineage?.status === 'completed'
            ? 'E_AGENT_ROUND_LIMIT'
          : journal.phase === 'failed' && cause !== null
            ? cause
          : 'E_AGENT_PERSISTENCE';
  return {
    ...attempt,
    status,
    activeRound,
    rounds,
    // Agent attempts freeze the controller's HJ(visible-history) at the first
    // begin-round checkpoint. Provider receipts carry a distinct transport
    // body digest and must never replace that controller authority.
    visibleHistorySha256: attempt.visibleHistorySha256,
    assistantMessageId: null,
    failureCode,
    updatedAt: laterTimestamp(attempt.updatedAt, at),
  };
}

function cleanupEntryIsValid(value: unknown): value is AgentTranscriptCleanupV1 {
  if (!isExactDataRecord(value, [
    'schema_version',
    'cleanup_id',
    'conversation_id',
    'task_id',
    'attempt_id',
    'transcript_ref',
    'transcript_sha256',
    'reason',
    'created_at',
  ])) return false;
  const cleanup = value as AgentTranscriptCleanupV1;
  return (
    cleanup.schema_version === 1 &&
    isCanonicalLifecycleId(cleanup.cleanup_id) &&
    validIdentifier(cleanup.conversation_id) &&
    isCanonicalLifecycleId(cleanup.task_id) &&
    isCanonicalLifecycleId(cleanup.attempt_id) &&
    isCanonicalLifecycleId(cleanup.transcript_ref) &&
    isSha256Digest(cleanup.transcript_sha256) &&
    (cleanup.reason === 'completed' ||
      cleanup.reason === 'cancelled' ||
      cleanup.reason === 'failed' ||
      cleanup.reason === 'conversation_deleted') &&
    isCanonicalTimestamp(cleanup.created_at)
  );
}

function cleanupReasonForTerminalPhase(
  phase: AgentAttemptPhase,
): Exclude<AgentTranscriptCleanupV1['reason'], 'conversation_deleted'> | null {
  return phase === 'final_response'
    ? 'completed'
    : phase === 'cancelled'
      ? 'cancelled'
      : phase === 'failed'
        ? 'failed'
        : null;
}

function sessionEventIsValid(value: unknown): value is PersistedSessionEventV3 {
  if (!isExactDataRecord(value, [
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
  ])) return false;
  const event = value as PersistedSessionEventV3;
  if (event.kind === 'cancel') {
    return (
      event.schema_version === 2 &&
      isCanonicalLifecycleId(event.event_id) &&
      isCanonicalLifecycleId(event.attempt_id) &&
      Number.isSafeInteger(event.seq) &&
      !Object.is(event.seq, -0) &&
      event.seq >= 0 &&
      (event.round_index === null ||
        (Number.isSafeInteger(event.round_index) &&
          !Object.is(event.round_index, -0) &&
          event.round_index >= 0 &&
          event.round_index < MAX_AGENT_ROUNDS)) &&
      (event.call_id === null || isOpaqueProviderId(event.call_id)) &&
      event.status === 'cancelled' &&
      event.safe_summary_key === null &&
      event.result_sha256 === null &&
      ((event.round_index === null &&
        event.call_id === null &&
        event.arguments_sha256 === null) ||
        (event.round_index !== null &&
          event.call_id === null &&
          event.arguments_sha256 === null) ||
        (event.round_index !== null &&
          event.call_id !== null &&
          isSha256Digest(event.arguments_sha256))) &&
      isCanonicalLifecycleId(event.approval_reference) &&
      event.approval_reference === event.event_id &&
      (event.failure_code === 'E_AGENT_CANCELLED' ||
        event.failure_code === 'E_AGENT_ROOT_STALE' ||
        event.failure_code === 'E_AGENT_PERSISTENCE') &&
      isCanonicalTimestamp(event.created_at)
    );
  }
  return (
    event.schema_version === 2 &&
    isCanonicalLifecycleId(event.event_id) &&
    isCanonicalLifecycleId(event.attempt_id) &&
    Number.isSafeInteger(event.seq) &&
    !Object.is(event.seq, -0) &&
    event.seq >= 0 &&
    (event.kind === 'round' ||
      event.kind === 'tool_call' ||
      event.kind === 'tool_result' ||
      event.kind === 'approval' ||
      event.kind === 'terminal') &&
    (event.round_index === null ||
      (Number.isSafeInteger(event.round_index) &&
        !Object.is(event.round_index, -0) &&
        event.round_index >= 0 &&
        event.round_index < MAX_AGENT_ROUNDS)) &&
    (event.call_id === null || isOpaqueProviderId(event.call_id)) &&
    (event.safe_summary_key === null ||
      (typeof event.safe_summary_key === 'string' &&
        event.safe_summary_key.length > 0 &&
        event.safe_summary_key.length <= MAX_AGENT_SUMMARY_KEY_LENGTH &&
        safeSummaryKeys.has(event.safe_summary_key))) &&
    (event.arguments_sha256 === null || isSha256Digest(event.arguments_sha256)) &&
    (event.result_sha256 === null || isSha256Digest(event.result_sha256)) &&
    (event.approval_reference === null || validIdentifier(event.approval_reference)) &&
    (event.failure_code === null || isAgentFailureCode(event.failure_code)) &&
    agentStatusValues.has(event.status) &&
    isCanonicalTimestamp(event.created_at)
  );
}

function sameSessionEvent(
  left: PersistedSessionEventV3,
  right: PersistedSessionEventV3,
): boolean {
  return (
    left.schema_version === right.schema_version &&
    left.event_id === right.event_id &&
    left.attempt_id === right.attempt_id &&
    left.seq === right.seq &&
    left.kind === right.kind &&
    left.round_index === right.round_index &&
    left.call_id === right.call_id &&
    left.status === right.status &&
    left.safe_summary_key === right.safe_summary_key &&
    left.arguments_sha256 === right.arguments_sha256 &&
    left.result_sha256 === right.result_sha256 &&
    left.approval_reference === right.approval_reference &&
    left.failure_code === right.failure_code &&
    left.created_at === right.created_at
  );
}

function sessionEventsAreValid(events: readonly PersistedSessionEventV3[]): boolean {
  if (!isExactDataArray(events, MAX_SESSION_EVENT_ROWS)) return false;
  const ids = new Set<string>();
  const previousSeq = new Map<string, number>();
  for (const event of events) {
    if (!sessionEventIsValid(event) || ids.has(event.event_id)) return false;
    ids.add(event.event_id);
    const previous = previousSeq.get(event.attempt_id);
    if (previous !== undefined && event.seq <= previous) return false;
    previousSeq.set(event.attempt_id, event.seq);
    if (event.kind === 'cancel') {
      // The source event itself is the only cancellation authority.  It never
      // represents a settled tool result or a rollback claim.
      if (!sessionEventIsValid(event)) return false;
    } else if (event.kind === 'round' || event.kind === 'terminal') {
      if (
        event.call_id !== null ||
        event.safe_summary_key !== null ||
        event.arguments_sha256 !== null ||
        event.result_sha256 !== null ||
        event.approval_reference !== null
      ) return false;
    } else if (event.kind === 'tool_call') {
      if (
        event.call_id === null ||
        event.safe_summary_key === null ||
        event.arguments_sha256 === null ||
        event.result_sha256 !== null ||
        event.approval_reference !== null ||
        (event.status !== 'waiting' &&
          event.status !== 'approval' &&
          event.status !== 'running')
      ) return false;
    } else if (event.kind === 'approval') {
      if (
        event.call_id === null ||
        event.safe_summary_key === null ||
        event.arguments_sha256 === null ||
        event.result_sha256 !== null ||
        event.status !== 'approval'
      ) return false;
    } else if (
      event.call_id === null ||
      event.safe_summary_key === null ||
      event.arguments_sha256 === null ||
      (event.status === 'unknown'
        ? event.result_sha256 !== null ||
          event.failure_code !== 'E_AGENT_CONFLICT'
        : event.result_sha256 === null) ||
      (event.status !== 'ok' &&
        event.status !== 'failed' &&
        event.status !== 'denied' &&
        event.status !== 'cancelled' &&
        event.status !== 'unknown' &&
        event.status !== 'ambiguous')
    ) {
      return false;
    }
  }
  return true;
}

function sessionEventsMatchState(
  events: readonly PersistedSessionEventV3[],
  state: ChatState,
  candidate?: {
    readonly conversationId: string;
    readonly attemptId: string;
    readonly journal: PersistedAgentAttemptJournalV3;
  },
): boolean {
  const attempts = new Map<string, TurnAttemptV1>();
  Object.values(state.conversations).forEach(conversation => {
    conversation.attempts.forEach(attempt => attempts.set(attempt.attemptId, attempt));
  });
  if (candidate !== undefined) {
    const candidateConversation = state.conversations[candidate.conversationId];
    const current = attempts.get(candidate.attemptId);
    if (
      candidateConversation === undefined ||
      current === undefined ||
      !candidateConversation.attempts.includes(current)
    ) return false;
    attempts.set(candidate.attemptId, {
      ...current,
      agent: candidate.journal,
    });
  }
  const calls = new Map<
    string,
    {
      readonly attemptId: string;
      readonly roundIndex: number | null;
      readonly safeSummaryKey: string;
      readonly argumentsSha256: string;
      readonly approvalReference: string | null;
      readonly resultSha256?: string;
      readonly failureCode?: AgentFailureCode | null;
      readonly receiptStatus?: PersistedSessionEventV3['status'];
    }
  >();
  for (const event of events) {
    const attempt = attempts.get(event.attempt_id);
    if (attempt === undefined) return false;
    if (
      event.round_index !== null &&
      event.round_index >= attempt.rounds.length &&
      event.round_index !== attempt.agent?.round_index
    ) return false;
    if (event.kind === 'cancel') {
      if (event.approval_reference !== event.event_id || event.status !== 'cancelled') {
        return false;
      }
      if (event.round_index === null) {
        if (event.call_id !== null || event.arguments_sha256 !== null) return false;
      } else if (event.call_id === null) {
        if (event.arguments_sha256 !== null) return false;
      } else {
        const journal = isAgentAttemptJournalAny(attempt.agent)
          ? attempt.agent
          : undefined;
        const call = journal?.batch.find(candidateCall => candidateCall.call_id === event.call_id);
        if (call === undefined || call.arguments_sha256 !== event.arguments_sha256) return false;
        if (event.round_index !== journal?.round_index) return false;
      }
      continue;
    }
    if (event.kind === 'round') continue;
    if (event.kind === 'terminal') {
      const expectedStatus =
        attempt.agent?.phase === 'final_response'
          ? 'ok'
          : attempt.agent?.phase === 'cancelled'
            ? 'cancelled'
            : attempt.agent?.phase === 'failed'
              ? 'failed'
              : attempt.agent?.phase === 'unknown'
                ? 'unknown'
                : attempt.agent?.phase === 'ambiguous'
                  ? 'ambiguous'
                  : null;
      if (expectedStatus !== null && event.status !== expectedStatus) return false;
      continue;
    }
    if (event.call_id === null) return false;
    const key = `${event.attempt_id}\0${event.call_id}`;
    const journal = isAgentAttemptJournalAny(attempt.agent)
      ? attempt.agent
      : undefined;
    const journalCall = journal?.batch.find(
      call => call.call_id === event.call_id,
    );
    const previous = calls.get(key);
    const historicalEvent =
      journalCall === undefined &&
      previous === undefined &&
      event.round_index !== null &&
      isAgentAttemptJournalV3(attempt.agent) &&
      event.round_index < attempt.agent.round_index &&
      attempt.rounds.some(round => round.roundIndex === event.round_index) &&
      (state.sessionEvents ?? []).some(existing =>
        existing.event_id === event.event_id && sameSessionEvent(existing, event),
      );
    if (journalCall === undefined && previous === undefined && !historicalEvent) {
      return false;
    }
    if (
      journalCall !== undefined &&
      event.round_index !== journal!.round_index
    ) return false;
    if (
      previous !== undefined &&
      previous.roundIndex !== event.round_index
    ) return false;
    const expectedArgs = journalCall?.arguments_sha256 ?? previous?.argumentsSha256;
    const expectedSummary = journalCall?.safe_summary_key ?? previous?.safeSummaryKey;
    const expectedApproval =
      journalCall !== undefined
        ? journalCall.approval_reference
        : previous?.approvalReference;
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
      event.arguments_sha256 !== null &&
      expectedArgs !== undefined &&
      event.arguments_sha256 !== expectedArgs
    ) return false;
    if (
      event.safe_summary_key !== null &&
      expectedSummary !== undefined &&
      event.safe_summary_key !== expectedSummary
    ) return false;
    if (
      journalCall !== undefined &&
      event.kind !== 'tool_call' &&
      !denialMarker &&
      !(event.kind === 'approval' && event.approval_reference === null) &&
      event.approval_reference !== expectedApproval
    ) return false;
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
      event.approval_reference !== expectedApproval
    ) return false;
    if (event.kind === 'tool_call') {
      calls.set(key, {
        ...(previous ?? {
          attemptId: event.attempt_id,
          roundIndex: event.round_index,
        }),
        safeSummaryKey: event.safe_summary_key!,
        argumentsSha256: event.arguments_sha256!,
        approvalReference:
          previous?.approvalReference ??
          journalCall?.approval_reference ??
          null,
      });
      continue;
    }
    if (event.kind === 'approval') {
      calls.set(key, {
        ...(previous ?? {
          attemptId: event.attempt_id,
          roundIndex: event.round_index,
          safeSummaryKey: event.safe_summary_key!,
          argumentsSha256: event.arguments_sha256!,
          approvalReference: null,
        }),
        safeSummaryKey: event.safe_summary_key!,
        argumentsSha256: event.arguments_sha256!,
        approvalReference: event.approval_reference,
      });
      continue;
    }
    const receipt = journalCall?.receipt;
    const unknownWithoutReceipt =
      event.status === 'unknown' &&
      event.result_sha256 === null &&
      event.failure_code === 'E_AGENT_CONFLICT' &&
      journal !== undefined &&
      journal.phase === 'unknown' &&
      journal.round_lineage?.status === 'unknown' &&
      journalCall !== undefined &&
      journalCall.native_row_revision !== null;
    if (journalCall !== undefined && receipt === null && !unknownWithoutReceipt) {
      return false;
    }
    if (receipt !== undefined && receipt !== null) {
      if (
        event.status !== receipt.outcome ||
        event.result_sha256 !== receipt.result_sha256 ||
        event.arguments_sha256 !== receipt.arguments_sha256 ||
        event.approval_reference !== receipt.approval_reference ||
        event.failure_code !== receipt.failure_code
      ) return false;
    } else if (
      !unknownWithoutReceipt &&
      previous?.resultSha256 !== undefined &&
      (event.result_sha256 !== previous.resultSha256 ||
        event.status !== previous.receiptStatus ||
        event.failure_code !== previous.failureCode)
    ) return false;
    calls.set(key, {
      ...(previous ?? {
        attemptId: event.attempt_id,
        roundIndex: event.round_index,
        safeSummaryKey: event.safe_summary_key!,
        argumentsSha256: event.arguments_sha256!,
        approvalReference: event.approval_reference,
      }),
      argumentsSha256: event.arguments_sha256!,
      ...(event.result_sha256 === null
        ? {}
        : { resultSha256: event.result_sha256 }),
      approvalReference: event.approval_reference,
      failureCode: event.failure_code,
      receiptStatus: event.status,
    });
  }
  return true;
}

function agentControllerCASIsValid(value: unknown): value is AgentControllerCASV1 {
  if (!isExactDataRecord(value, [
      'schema_version',
      'conversation_id',
      'task_id',
      'attempt_id',
      'expected_controller_generation',
      'expected_journal_revision',
      'expected_session_generation',
      'expected_session_sha256',
    ])) return false;
  const cas = value as unknown as AgentControllerCASV1;
  return (
    cas.schema_version === 1 &&
    validIdentifier(cas.conversation_id) &&
    isCanonicalLifecycleId(cas.task_id) &&
    isCanonicalLifecycleId(cas.attempt_id) &&
    Number.isSafeInteger(cas.expected_controller_generation) &&
    !Object.is(cas.expected_controller_generation, -0) &&
    cas.expected_controller_generation >= 0 &&
    cas.expected_controller_generation < Number.MAX_SAFE_INTEGER &&
    Number.isSafeInteger(cas.expected_journal_revision) &&
    !Object.is(cas.expected_journal_revision, -0) &&
    cas.expected_journal_revision >= 0 &&
    cas.expected_journal_revision < Number.MAX_SAFE_INTEGER &&
    Number.isSafeInteger(cas.expected_session_generation) &&
    !Object.is(cas.expected_session_generation, -0) &&
    cas.expected_session_generation >= 1 &&
    cas.expected_session_generation < Number.MAX_SAFE_INTEGER &&
    isSha256Digest(cas.expected_session_sha256)
  );
}

function agentControllerCASMatchesAttempt(
  value: unknown,
  conversation: Conversation,
  attempt: TurnAttemptV1,
): value is AgentControllerCASV1 {
  return (
    agentControllerCASIsValid(value) &&
    value.conversation_id === conversation.id &&
    value.task_id === attempt.turnId &&
    value.attempt_id === attempt.attemptId &&
    value.expected_controller_generation ===
      (attempt.agent?.controller_generation ?? 0) &&
    value.expected_journal_revision === (attempt.journalRevision ?? 0)
  );
}

export function isProjectId(value: unknown): value is string {
  return (
    typeof value === 'string' &&
    value.trim().length > 0 &&
    value.length <= PROJECT_ID_MAX_LENGTH
  );
}

export const WORKSPACE_ID_MAX_LENGTH = 256;

export function isWorkspaceId(value: unknown): value is string {
  return (
    typeof value === 'string' &&
    value.trim().length > 0 &&
    value.length <= WORKSPACE_ID_MAX_LENGTH
  );
}

function normalizeManualTitle(value: string): string | null {
  const normalized = value.replace(/\s+/gu, ' ').trim();
  if (normalized.length === 0) {
    return null;
  }
  return Array.from(normalized).slice(0, MANUAL_TITLE_MAX_LENGTH).join('');
}

function laterTimestamp(left: string, right: string): string {
  return Date.parse(right) > Date.parse(left) ? right : left;
}

function withConversation(
  state: ChatState,
  conversation: Conversation,
): ChatState {
  const conversations = {
    ...state.conversations,
    [conversation.id]: conversation,
  };
  return {
    ...state,
    conversations,
    conversationOrder: orderConversationIds(conversations),
  };
}

function hasMessageId(conversation: Conversation, messageId: string): boolean {
  return conversation.messages.some(message => message.id === messageId);
}

function shouldAutoTitle(conversation: Conversation): boolean {
  return (
    conversation.titleSource === 'auto' &&
    !conversation.messages.some(message => message.role === 'user')
  );
}

function normalizedMessage(
  conversation: Conversation,
  message: ChatMessage,
): ChatMessage | null {
  const text = message.text;
  const nonBlankText = text.trim();
  if (
    !validIdentifier(message.id) ||
    !isCanonicalTimestamp(message.createdAt) ||
    (message.role !== 'user' && message.role !== 'assistant') ||
    text.length > MAX_CHAT_MESSAGE_LENGTH ||
    !areValidChatAttachments(message.attachments) ||
    (nonBlankText.length === 0 &&
      (message.role === 'assistant' || message.attachments.length === 0)) ||
    hasMessageId(conversation, message.id)
  ) {
    return null;
  }
  return {
    ...message,
    text,
    attachments: message.attachments.map(attachment => ({ ...attachment })),
  };
}

function hasLifecycleId(state: ChatState, id: string): boolean {
  return (
    state.projectContextDestructiveTransition?.lifecycleId === id ||
    (state.agentTranscriptCleanupOutbox ?? []).some(
      entry => entry.cleanup_id === id,
    ) ||
    (state.workspaceAuthorityOutbox ?? []).some(
      entry => entry.operationId === id || entry.clearanceReceiptId === id,
    ) ||
    (state.sessionEvents ?? []).some(event => event.event_id === id) ||
    Object.values(state.conversations).some(
    conversation =>
      conversation.runtimeContextId === id ||
      (conversation.agentGrants ?? []).some(grant => grant.grant_id === id) ||
      conversation.turns.some(turn => turn.turnId === id) ||
      conversation.attempts.some(
        attempt =>
          attempt.attemptId === id ||
          attempt.activeRound?.roundId === id ||
          attempt.rounds.some(round => round.roundId === id) ||
          attempt.agent?.transcript.transcript_ref === id ||
          attempt.agent?.round_lineage?.round_id === id,
      ),
    )
  );
}

function hasProviderReceiptId(
  state: ChatState,
  receipt: CompletionRoundReceiptV1,
): boolean {
  return Object.values(state.conversations).some(conversation =>
    conversation.attempts.some(attempt =>
      attempt.rounds.some(
        round =>
          round.providerRequestId === receipt.providerRequestId ||
          round.providerResponseId === receipt.providerResponseId,
      ),
    ),
  );
}

function attemptIndex(
  conversation: Conversation,
  attemptId: string,
): number {
  return conversation.attempts.findIndex(
    attempt => attempt.attemptId === attemptId,
  );
}

function replaceAttempt(
  conversation: Conversation,
  index: number,
  attempt: TurnAttemptV1,
): Conversation {
  const attempts = [...conversation.attempts];
  attempts[index] = attempt;
  return { ...conversation, attempts };
}

function deleteConversationState(state: ChatState, id: string): ChatState {
  const deleted = state.conversations[id];
  if (deleted === undefined) return state;
  const conversations = { ...state.conversations };
  delete conversations[id];
  const conversationOrder = orderConversationIds(conversations);
  const deletedAttemptIds = new Set(
    deleted.attempts.map(attempt => attempt.attemptId),
  );
  const next = {
    ...state,
    conversations,
    conversationOrder,
    selectedConversationId:
      state.selectedConversationId === id
        ? conversationOrder[0] ?? null
        : state.selectedConversationId,
  };
  return state.sessionEvents === undefined
    ? next
    : {
        ...next,
        sessionEvents: state.sessionEvents.filter(
          event => !deletedAttemptIds.has(event.attempt_id),
        ),
      };
}

function requiresDestructiveLifecycle(conversation: Conversation): boolean {
  const context = conversation.projectContext;
  return (
    context !== null &&
    (context.snapshot !== null || context.activePreparationId !== null)
  );
}

function isExactDisabledContext(
  conversation: Conversation,
  transition: ProjectContextDestructiveTransitionV1,
): boolean {
  const context = conversation.projectContext;
  return (
    conversation.projectId === transition.sourceProjectId &&
    conversation.runtimeContextId === transition.sourceRuntimeContextId &&
    conversation.modelId === transition.sourceModelId &&
    context !== null &&
    context.projectId === transition.sourceProjectId &&
    context.status === 'setup_required' &&
    context.selectedPaths.length === 0 &&
    context.activePreparationId === null &&
    context.snapshot === null &&
    context.consent === null &&
    context.staleReason === null &&
    context.errorCode === null
  );
}

function isValidDestructiveTransition(
  value: unknown,
): value is ProjectContextDestructiveTransitionV1 {
  try {
    if (!isExactDataRecord(value, destructiveTransitionKeys)) return false;
    const transition = value as ProjectContextDestructiveTransitionV1;
    return (
      transition.schemaVersion ===
        PROJECT_CONTEXT_DESTRUCTIVE_TRANSITION_SCHEMA_VERSION &&
      isCanonicalLifecycleId(transition.lifecycleId) &&
      Number.isSafeInteger(transition.epoch) &&
      !Object.is(transition.epoch, -0) &&
      transition.epoch > 0 &&
      (transition.action === 'unbind' ||
        transition.action === 'delete' ||
        transition.action === 'rebind') &&
      (transition.phase === 'intent' ||
        transition.phase === 'cleanup_pending' ||
        transition.phase === 'ready_to_finalize') &&
      validIdentifier(transition.conversationId) &&
      isProjectId(transition.sourceProjectId) &&
      (transition.sourceRuntimeContextId === null ||
        isCanonicalLifecycleId(transition.sourceRuntimeContextId)) &&
      isModelId(transition.sourceModelId) &&
      isCanonicalLifecycleId(transition.snapshotId) &&
      isSha256Digest(transition.snapshotSha256) &&
      (transition.consentReceiptId === null ||
        isCanonicalLifecycleId(transition.consentReceiptId)) &&
      ((transition.action === 'rebind' &&
        transition.targetProjectId !== null &&
        isProjectId(transition.targetProjectId) &&
        transition.targetProjectId !== transition.sourceProjectId) ||
        (transition.action !== 'rebind' &&
          transition.targetProjectId === null)) &&
      isCanonicalTimestamp(transition.createdAt) &&
      isCanonicalTimestamp(transition.updatedAt) &&
      Date.parse(transition.updatedAt) >= Date.parse(transition.createdAt)
    );
  } catch {
    return false;
  }
}

function destructiveAdvanceScopeMatches(
  scope: unknown,
  transition: ProjectContextDestructiveTransitionV1 | null,
): scope is ProjectContextDestructiveAdvanceScope {
  try {
    if (
      transition === null ||
      !isExactDataRecord(scope, destructiveAdvanceScopeKeys) ||
      !isValidDestructiveTransition(scope.expectedTransition) ||
      scope.expectedTransition !== transition
    ) {
      return false;
    }
    return (
      scope.lifecycleId === transition.lifecycleId &&
      scope.epoch === transition.epoch &&
      scope.action === transition.action &&
      scope.targetProjectId === transition.targetProjectId
    );
  } catch {
    return false;
  }
}

function isExactIntentContext(
  conversation: Conversation,
  transition: ProjectContextDestructiveTransitionV1,
): boolean {
  const context = conversation.projectContext;
  return (
    conversation.projectId === transition.sourceProjectId &&
    conversation.runtimeContextId === transition.sourceRuntimeContextId &&
    conversation.modelId === transition.sourceModelId &&
    context !== null &&
    context.activePreparationId === null &&
    context.snapshot?.snapshot_id === transition.snapshotId &&
    context.snapshot.snapshot_sha256 === transition.snapshotSha256 &&
    (context.consent?.consent_receipt_id ?? null) ===
      transition.consentReceiptId
  );
}

function destructiveTransitionConversation(
  state: ChatState,
  scope: unknown,
  phase: ProjectContextDestructiveTransitionV1['phase'],
): {
  transition: ProjectContextDestructiveTransitionV1;
  conversation: Conversation;
} | null {
  const transition = state.projectContextDestructiveTransition;
  if (
    transition === null ||
    !destructiveAdvanceScopeMatches(scope, transition) ||
    transition.phase !== phase ||
    state.projectContextDestructiveEpoch !== transition.epoch
  ) {
    return null;
  }
  const conversation = state.conversations[transition.conversationId];
  if (
    conversation === undefined ||
    !isExactDisabledContext(conversation, transition) ||
    hasProjectContextDestructiveReferences(state, transition)
  ) {
    return null;
  }
  return { transition, conversation };
}

function destructiveTargetConversationId(action: ChatAction): string | null {
  switch (action.type) {
    case 'conversation/rename':
    case 'conversation/auto-title':
    case 'conversation/delete':
    case 'conversation/set-model':
    case 'conversation/set-thinking':
    case 'conversation/bind-project':
    case 'conversation/unbind-project':
    case 'conversation/bind-workspace':
    case 'conversation/unbind-workspace':
    case 'conversation/ensure-runtime-context':
      return action.payload.id;
    case 'conversation/delete-with-agent-cleanup':
      return action.payload.conversationId;
    case 'conversation/apply-workspace-binding':
      {
        const descriptor =
          typeof action.payload.owner === 'object' &&
          action.payload.owner !== null
            ? Object.getOwnPropertyDescriptor(
                action.payload.owner,
                'conversationId',
              )
            : undefined;
        return descriptor !== undefined &&
          Object.prototype.hasOwnProperty.call(descriptor, 'value') &&
          typeof descriptor.value === 'string'
          ? descriptor.value
          : null;
      }
    case 'project-context/apply':
      return action.payload.conversationId;
    case 'project-context/replace-prepared':
    case 'project-context/replace-confirmed':
    case 'project-context/disable':
      return typeof action.payload.scope === 'object' &&
        action.payload.scope !== null &&
        'conversationId' in action.payload.scope &&
        typeof action.payload.scope.conversationId === 'string'
        ? action.payload.scope.conversationId
        : null;
    case 'message/append':
    case 'turn/prepare':
    case 'attempt/start-round':
    case 'attempt/record-round':
    case 'attempt/complete':
    case 'attempt/fail':
    case 'attempt/cancel':
    case 'attempt/retry':
      return action.payload.conversationId;
    case 'attempt/agent-checkpoint':
    case 'attempt/agent-advance-call':
    case 'attempt/agent-final-checkpoint':
    case 'agent/cleanup-enqueue':
    case 'agent/abandon-unresolved':
      return action.payload.conversationId;
    case 'conversation/agent-grants':
      return action.payload.conversationId;
    case 'agent/approval-checkpoint':
      return action.payload.conversationId;
    case 'conversation/create':
    case 'conversation/select':
    case 'project-context-destructive/begin':
    case 'project-context-destructive/tombstone':
    case 'project-context-destructive/cleanup-complete':
    case 'project-context-destructive/finalize':
      return null;
    case 'agent/cleanup-ack':
      return null;
  }
}

export function chatReducer(state: ChatState, action: ChatAction): ChatState {
  const lifecycleTarget = state.projectContextDestructiveTransition;
  if (
    lifecycleTarget !== null &&
    destructiveTargetConversationId(action) === lifecycleTarget.conversationId
  ) {
    return state;
  }
  switch (action.type) {
    case 'conversation/create': {
      const {
        id,
        at,
        modelId = DEFAULT_MODEL_ID,
        thinkingMode = DEFAULT_THINKING_MODE,
        projectId = null,
        workspaceId = null,
        select = true,
      } = action.payload;
      if (
        !validIdentifier(id) ||
        !isCanonicalTimestamp(at) ||
        !isModelId(modelId) ||
        !isConversationThinkingMode(thinkingMode) ||
        (projectId !== null && !isProjectId(projectId)) ||
        (workspaceId !== null && !isWorkspaceId(workspaceId)) ||
        hasWorkspaceAuthorityOutboxEntry(state, workspaceId) ||
        state.conversations[id] !== undefined
      ) {
        return state;
      }

      const suppliedTitle =
        action.payload.title === undefined
          ? null
          : normalizeManualTitle(action.payload.title);
      const conversation: Conversation = {
        id,
        projectId,
        workspaceId,
        workspaceBinding: null,
        workspaceBootstrapState:
          workspaceId !== null
            ? projectId === null
              ? 'pending_registry_resolution'
              : 'pending_legacy_project'
            : projectId === null
              ? 'none'
              : 'pending_legacy_project',
        runtimeContextId: null,
        projectContext:
          projectId === null ? null : createProjectContextState(projectId),
        title: suppliedTitle ?? DEFAULT_CONVERSATION_TITLE,
        titleSource: suppliedTitle === null ? 'auto' : 'manual',
        modelId,
        thinkingMode,
        messages: [],
        turns: [],
        attempts: [],
        createdAt: at,
        updatedAt: at,
        agentGrants: [],
      };
      const next = withConversation(state, conversation);
      return select ? { ...next, selectedConversationId: id } : next;
    }

    case 'conversation/rename': {
      const conversation = state.conversations[action.payload.id];
      const title = normalizeManualTitle(action.payload.title);
      if (
        conversation === undefined ||
        title === null ||
        !isCanonicalTimestamp(action.payload.at)
      ) {
        return state;
      }
      if (
        conversation.title === title &&
        conversation.titleSource === 'manual'
      ) {
        return state;
      }
      return withConversation(state, {
        ...conversation,
        title,
        titleSource: 'manual',
        updatedAt: laterTimestamp(conversation.updatedAt, action.payload.at),
      });
    }

    case 'conversation/auto-title': {
      const conversation = state.conversations[action.payload.id];
      if (
        conversation === undefined ||
        conversation.titleSource === 'manual' ||
        !isCanonicalTimestamp(action.payload.at)
      ) {
        return state;
      }
      const title = deriveAutoTitle(action.payload.text);
      if (title === conversation.title) {
        return state;
      }
      return withConversation(state, {
        ...conversation,
        title,
        updatedAt: laterTimestamp(conversation.updatedAt, action.payload.at),
      });
    }

    case 'conversation/select': {
      const { id } = action.payload;
      if (
        state.selectedConversationId === id ||
        (id !== null && state.conversations[id] === undefined)
      ) {
        return state;
      }
      return { ...state, selectedConversationId: id };
    }

    case 'conversation/delete': {
      const { id } = action.payload;
      const conversation = state.conversations[id];
      if (
        conversation === undefined ||
        hasLiveAttempt(conversation) ||
        hasAgentRecoveryOwner(conversation) ||
        requiresDestructiveLifecycle(conversation)
      ) {
        return state;
      }
      return deleteConversationState(state, id);
    }

    case 'conversation/delete-with-agent-cleanup': {
      const payload = action.payload;
      const conversation = state.conversations[payload.conversationId];
      if (
        conversation === undefined ||
        payload.expectedConversation !== conversation ||
        !Array.isArray(payload.cleanup) ||
        requiresDestructiveLifecycle(conversation) ||
        conversation.attempts.some(
          attempt =>
            (attempt.status === 'prepared' || attempt.status === 'sending') &&
            (attempt.agent === undefined ||
              attempt.agent === null ||
              (attempt.agent.phase !== 'final_response' &&
                attempt.agent.phase !== 'cancelled' &&
                attempt.agent.phase !== 'failed')),
        )
      ) return state;
      const ownedAttempts = conversation.attempts.filter(
        attempt => attempt.agent !== undefined && attempt.agent !== null,
      );
      // A deletion is allowed to release only terminal transcript owners. An
      // unknown/ambiguous or in-flight Agent journal remains a recovery owner
      // until native reconciliation has produced terminal evidence.
      if (
        ownedAttempts.some(
          attempt =>
            attempt.agent === undefined ||
            attempt.agent === null ||
            (attempt.agent.phase !== 'final_response' &&
              attempt.agent.phase !== 'cancelled' &&
              attempt.agent.phase !== 'failed'),
        ) ||
        payload.cleanup.length +
          (state.agentTranscriptCleanupOutbox ?? []).length >
          MAX_AGENT_CLEANUP_OUTBOX_ENTRIES
      ) return state;
      const existingCleanupIds = new Set(
        (state.agentTranscriptCleanupOutbox ?? []).map(
          entry => entry.cleanup_id,
        ),
      );
      const existingCleanupForAttempt = new Set(
        (state.agentTranscriptCleanupOutbox ?? [])
          .filter(entry => entry.conversation_id === conversation.id)
          .map(
            entry =>
              `${entry.attempt_id}\0${entry.transcript_ref}\0${entry.transcript_sha256}`,
          ),
      );
      if (
        (state.agentTranscriptCleanupOutbox ?? []).some(entry => {
          if (entry.conversation_id !== conversation.id) return false;
          const attempt = ownedAttempts.find(
            candidate => candidate.attemptId === entry.attempt_id,
          );
          return (
            attempt?.agent?.transcript.transcript_ref === entry.transcript_ref &&
            attempt.agent.transcript.transcript_sha256 === entry.transcript_sha256 &&
            entry.reason !== 'conversation_deleted'
          );
        })
      ) return state;
      const requiredCleanupCount = ownedAttempts.filter(attempt => {
        const transcript = attempt.agent?.transcript;
        return (
          transcript !== undefined &&
          !existingCleanupForAttempt.has(
            `${attempt.attemptId}\0${transcript.transcript_ref}\0${transcript.transcript_sha256}`,
          )
        );
      }).length;
      const cleanupIds = new Set<string>();
      for (const cleanup of payload.cleanup) {
        if (
          !cleanupEntryIsValid(cleanup) ||
          cleanup.conversation_id !== conversation.id ||
          cleanup.reason !== 'conversation_deleted' ||
          cleanupIds.has(cleanup.cleanup_id) ||
          existingCleanupIds.has(cleanup.cleanup_id)
        ) return state;
        const attempt = ownedAttempts.find(
          candidate => candidate.attemptId === cleanup.attempt_id,
        );
        if (
          attempt === undefined ||
          attempt.agent === undefined ||
          attempt.agent === null ||
          attempt.turnId !== cleanup.task_id ||
          attempt.agent.transcript.transcript_ref !== cleanup.transcript_ref ||
          attempt.agent.transcript.transcript_sha256 !== cleanup.transcript_sha256 ||
          existingCleanupForAttempt.has(
            `${cleanup.attempt_id}\0${cleanup.transcript_ref}\0${cleanup.transcript_sha256}`,
          )
        ) return state;
        cleanupIds.add(cleanup.cleanup_id);
      }
      if (payload.cleanup.length !== requiredCleanupCount) return state;
      const next = deleteConversationState(state, conversation.id);
      return {
        ...next,
        agentTranscriptCleanupOutbox: [
          ...(state.agentTranscriptCleanupOutbox ?? []),
          ...payload.cleanup.map(cleanup => ({ ...cleanup })),
        ],
      };
    }

    case 'conversation/set-model': {
      const conversation = state.conversations[action.payload.id];
      if (
        conversation === undefined ||
        hasLiveAttempt(conversation) ||
        !isModelId(action.payload.modelId) ||
        !isCanonicalTimestamp(action.payload.at) ||
        conversation.modelId === action.payload.modelId
      ) {
        return state;
      }
      const projectContext =
        conversation.projectContext === null
          ? null
          : projectContextReducer(conversation.projectContext, {
              type: 'model_changed',
              model: action.payload.modelId,
            });
      return withConversation(state, {
        ...conversation,
        modelId: action.payload.modelId,
        projectContext,
        updatedAt: laterTimestamp(conversation.updatedAt, action.payload.at),
      });
    }

    case 'conversation/set-thinking': {
      const conversation = state.conversations[action.payload.id];
      if (
        conversation === undefined ||
        hasLiveAttempt(conversation) ||
        !isConversationThinkingMode(action.payload.thinkingMode) ||
        !isCanonicalTimestamp(action.payload.at) ||
        conversation.thinkingMode === action.payload.thinkingMode
      ) {
        return state;
      }
      return withConversation(state, {
        ...conversation,
        thinkingMode: action.payload.thinkingMode,
        updatedAt: laterTimestamp(conversation.updatedAt, action.payload.at),
      });
    }

    case 'conversation/bind-project': {
      const conversation = state.conversations[action.payload.id];
      if (
        conversation === undefined ||
        !isProjectId(action.payload.projectId) ||
        !isCanonicalTimestamp(action.payload.at) ||
        hasLiveAttempt(conversation) ||
        hasAgentRecoveryOwner(conversation) ||
        requiresDestructiveLifecycle(conversation) ||
        conversation.workspaceBinding !== null ||
        conversation.workspaceId !== null ||
        conversation.projectId === action.payload.projectId
      ) {
        return state;
      }
      return withConversation(state, {
        ...conversation,
        projectId: action.payload.projectId,
        workspaceBootstrapState: 'pending_legacy_project',
        projectContext: createProjectContextState(action.payload.projectId),
        agentGrants: [],
        updatedAt: laterTimestamp(conversation.updatedAt, action.payload.at),
      });
    }

    case 'conversation/unbind-project': {
      const conversation = state.conversations[action.payload.id];
      if (
        conversation === undefined ||
        conversation.projectId === null ||
        hasLiveAttempt(conversation) ||
        hasAgentRecoveryOwner(conversation) ||
        requiresDestructiveLifecycle(conversation) ||
        conversation.workspaceBinding !== null ||
        conversation.workspaceId !== null ||
        !isCanonicalTimestamp(action.payload.at)
      ) {
        return state;
      }
      return withConversation(state, {
        ...conversation,
        projectId: null,
        workspaceBootstrapState: 'none',
        projectContext: null,
        agentGrants: [],
        updatedAt: laterTimestamp(conversation.updatedAt, action.payload.at),
      });
    }

    case 'conversation/bind-workspace': {
      const conversation = state.conversations[action.payload.id];
      if (
        conversation === undefined ||
        !isWorkspaceId(action.payload.workspaceId) ||
        !isCanonicalTimestamp(action.payload.at) ||
        hasLiveAttempt(conversation) ||
        hasAgentRecoveryOwner(conversation) ||
        hasWorkspaceAuthorityOutboxEntry(state, action.payload.workspaceId) ||
        conversation.workspaceBinding !== null ||
        conversation.workspaceId === action.payload.workspaceId
      ) {
        return state;
      }
      return withConversation(state, {
        ...conversation,
        workspaceId: action.payload.workspaceId,
        workspaceBootstrapState:
          conversation.projectId === null
            ? 'pending_registry_resolution'
            : 'pending_legacy_project',
        agentGrants: [],
        updatedAt: laterTimestamp(conversation.updatedAt, action.payload.at),
      });
    }

    case 'conversation/unbind-workspace': {
      const conversation = state.conversations[action.payload.id];
      if (
        conversation === undefined ||
        conversation.workspaceId === null ||
        hasLiveAttempt(conversation) ||
        hasAgentRecoveryOwner(conversation) ||
        hasWorkspaceAuthorityOutboxEntry(state, conversation.workspaceId) ||
        conversation.workspaceBinding !== null ||
        !isCanonicalTimestamp(action.payload.at)
      ) {
        return state;
      }
      return withConversation(state, {
        ...conversation,
        workspaceId: null,
        workspaceBootstrapState:
          conversation.projectId === null ? 'none' : 'pending_legacy_project',
        agentGrants: [],
        updatedAt: laterTimestamp(conversation.updatedAt, action.payload.at),
      });
    }

    case 'conversation/apply-workspace-binding': {
      const payload = action.payload;
      if (
        !isExactDataRecord(payload, workspaceBindingActionKeys) ||
        !isExactDataRecord(payload.owner, workspaceBindingOwnerKeys) ||
        !isCanonicalTimestamp(payload.at)
      ) {
        return state;
      }
      const owner = payload.owner;
      if (
        typeof owner.conversationId !== 'string' ||
        !validIdentifier(owner.conversationId) ||
        !Number.isSafeInteger(owner.expectedDestructiveEpoch) ||
        Object.is(owner.expectedDestructiveEpoch, -0) ||
        owner.expectedDestructiveEpoch < 0 ||
        owner.expectedDestructiveEpoch >= Number.MAX_SAFE_INTEGER ||
        owner.expectedDestructiveEpoch !== state.projectContextDestructiveEpoch ||
        state.projectContextDestructiveTransition !== null
      ) {
        return state;
      }
      const conversation = state.conversations[owner.conversationId];
      if (
        conversation === undefined ||
        owner.expectedConversation !== conversation ||
        owner.expectedProjectContext !== conversation.projectContext ||
        !conversationWorkspaceStateIsValid(conversation) ||
        hasLiveAttempt(conversation) ||
        hasAgentRecoveryOwner(conversation) ||
        requiresDestructiveLifecycle(conversation)
      ) {
        return state;
      }
      const binding = payload.binding;
      const conversationBinding = conversation.workspaceBinding ?? null;
      if (binding !== null && !workspaceBindingIsValid(binding)) return state;
      const currentWorkspaceId =
        conversationBinding?.workspaceId ?? conversation.workspaceId;
      const targetWorkspaceId = binding?.workspaceId ?? currentWorkspaceId;
      if (
        binding !== null &&
        binding.workspaceId === conversation.workspaceId &&
        binding.projectId === conversation.projectId &&
        conversationBinding !== null &&
        binding.bindingRevision === conversationBinding.bindingRevision
      ) {
        return state;
      }
      if (
        conversation.attempts.length > 0 ||
        (binding !== null &&
          conversationBinding !== null &&
          binding.bindingRevision <= conversationBinding.bindingRevision)
      ) {
        return state;
      }
      if (
        hasWorkspaceAuthorityOutboxEntry(state, currentWorkspaceId) ||
        hasWorkspaceAuthorityOutboxEntry(state, targetWorkspaceId)
      ) {
        return state;
      }
      // A null workspace binding clears only workspace authority. The
      // existing project may remain attached while native bootstrap/detach is
      // retried; a non-null binding carries the complete project relation.
      const targetProjectId =
        binding === null ? conversation.projectId : binding.projectId;
      const nextProjectContext =
        targetProjectId === null
          ? null
          : conversation.projectId === targetProjectId &&
              conversation.projectContext !== null
            ? conversation.projectContext
            : createProjectContextState(targetProjectId);
      const nextRuntimeContextId =
        targetProjectId === conversation.projectId
          ? conversation.runtimeContextId
          : null;
      return withConversation(state, {
        ...conversation,
        projectId: targetProjectId,
        workspaceId: binding?.workspaceId ?? null,
        workspaceBinding: copyWorkspaceBinding(binding),
        workspaceBootstrapState: binding === null ?
          targetProjectId === null ? 'none' : 'pending_legacy_project' : 'none',
        runtimeContextId: nextRuntimeContextId,
        projectContext: nextProjectContext,
        agentGrants: [],
        updatedAt: laterTimestamp(conversation.updatedAt, payload.at),
      });
    }

    case 'conversation/ensure-runtime-context': {
      const conversation = state.conversations[action.payload.id];
      if (
        conversation === undefined ||
        conversation.projectId === null ||
        conversation.projectContext === null ||
        conversation.runtimeContextId !== null ||
        !isCanonicalLifecycleId(action.payload.runtimeContextId) ||
        !isCanonicalTimestamp(action.payload.at) ||
        hasLifecycleId(state, action.payload.runtimeContextId)
      ) {
        return state;
      }
      return withConversation(state, {
        ...conversation,
        runtimeContextId: action.payload.runtimeContextId,
        updatedAt: laterTimestamp(conversation.updatedAt, action.payload.at),
      });
    }

    case 'project-context/apply': {
      const conversation =
        state.conversations[action.payload.conversationId];
      if (
        action.payload.action.type === 'checking' ||
        action.payload.action.type === 'prepared' ||
        action.payload.action.type === 'confirmed' ||
        action.payload.action.type === 'selection_changed' ||
        action.payload.action.type === 'disabled'
      ) {
        return state;
      }
      if (
        conversation === undefined ||
        conversation.projectContext === null ||
        !isCanonicalTimestamp(action.payload.at)
      ) {
        return state;
      }
      if (
        action.payload.action.type === 'unavailable' &&
        conversation.projectContext.snapshot !== null
      ) {
        return state;
      }
      const projectContext = projectContextReducer(
        conversation.projectContext,
        action.payload.action,
      );
      if (projectContext === conversation.projectContext) {
        return state;
      }
      return withConversation(state, {
        ...conversation,
        projectContext,
        updatedAt: laterTimestamp(conversation.updatedAt, action.payload.at),
      });
    }

    case 'project-context/replace-prepared': {
      const payload = action.payload;
      if (
        !isExactDataRecord(payload, replacePreparedContextKeys) ||
        !isCanonicalTimestamp(payload.at) ||
        !isCanonicalLifecycleId(payload.preparationId)
      ) {
        return state;
      }
      const conversation = scopedContextConversation(state, payload.scope);
      if (
        conversation === null ||
        conversation.projectContext === null ||
        isProjectContextSendable(conversation.projectContext)
      ) {
        return state;
      }
      const projectContext = normalizedPreparedProjectContext(
        conversation.projectId!,
        payload.preparationId,
        payload.selectedPaths,
        payload.manifest,
      );
      if (
        projectContext === null ||
        !contextAuthorityMatches(
          conversation,
          projectContext,
          payload.preparationId,
          false,
        )
      ) {
        return state;
      }
      return withConversation(state, {
        ...conversation,
        projectContext,
        updatedAt: laterTimestamp(conversation.updatedAt, payload.at),
      });
    }

    case 'project-context/replace-confirmed': {
      const payload = action.payload;
      if (
        !isExactDataRecord(payload, replaceConfirmedContextKeys) ||
        !isCanonicalTimestamp(payload.at) ||
        !isCanonicalLifecycleId(payload.preparationId)
      ) {
        return state;
      }
      const conversation = scopedContextConversation(state, payload.scope);
      if (conversation === null || conversation.projectContext === null) {
        return state;
      }
      const desired = normalizedConfirmedProjectContext(
        conversation.projectId!,
        payload.selectedPaths,
        payload.manifest,
        payload.consent,
      );
      if (
        desired === null ||
        !contextAuthorityMatches(
          conversation,
          desired,
          payload.preparationId,
          true,
        )
      ) {
        return state;
      }

      let projectContext = desired;
      if (!isProjectContextSendable(conversation.projectContext)) {
        if (
          !hasSameStrings(
            conversation.projectContext.selectedPaths,
            desired.selectedPaths,
          ) ||
          desired.snapshot === null ||
          desired.consent === null
        ) {
          return state;
        }
        const confirmed = projectContextReducer(conversation.projectContext, {
          type: 'confirmed',
          preparationId: payload.preparationId,
          manifest: desired.snapshot,
          consent: desired.consent,
        });
        if (confirmed === conversation.projectContext) return state;
        const normalized = strictProjectContextState(confirmed);
        if (normalized === null || !isProjectContextSendable(normalized)) {
          return state;
        }
        projectContext = normalized;
      }

      return withConversation(state, {
        ...conversation,
        projectContext,
        updatedAt: laterTimestamp(conversation.updatedAt, payload.at),
      });
    }

    case 'project-context/disable': {
      const payload = action.payload;
      if (
        !isExactDataRecord(payload, disableContextKeys) ||
        !isCanonicalTimestamp(payload.at)
      ) {
        return state;
      }
      const conversation = scopedContextConversation(state, payload.scope);
      if (conversation === null || conversation.projectContext === null) {
        return state;
      }
      const current = conversation.projectContext;
      if (
        current.status === 'setup_required' &&
        current.selectedPaths.length === 0 &&
        current.activePreparationId === null &&
        current.snapshot === null &&
        current.consent === null &&
        current.staleReason === null &&
        current.errorCode === null
      ) {
        return state;
      }
      return withConversation(state, {
        ...conversation,
        projectContext: createProjectContextState(conversation.projectId!),
        updatedAt: laterTimestamp(conversation.updatedAt, payload.at),
      });
    }

    case 'project-context-destructive/begin': {
      const payload = action.payload;
      if (
        !isExactDataRecord(payload, destructiveBeginKeys) ||
        !isExactDataRecord(payload.owner, destructiveOwnerKeys) ||
        state.projectContextDestructiveTransition !== null ||
        state.projectContextDestructiveEpoch >= Number.MAX_SAFE_INTEGER ||
        !isCanonicalLifecycleId(payload.lifecycleId) ||
        hasLifecycleId(state, payload.lifecycleId) ||
        !isCanonicalTimestamp(payload.at) ||
        (payload.action !== 'unbind' &&
          payload.action !== 'delete' &&
          payload.action !== 'rebind') ||
        ((payload.action === 'rebind') !==
          (payload.targetProjectId !== null)) ||
        (payload.targetProjectId !== null &&
          (!isProjectId(payload.targetProjectId) ||
            payload.targetProjectId === payload.owner.projectId))
      ) {
        return state;
      }
      const owner = payload.owner;
      if (
        typeof owner.conversationId !== 'string' ||
        !validIdentifier(owner.conversationId) ||
        !isProjectId(owner.projectId) ||
        (owner.runtimeContextId !== null &&
          !isCanonicalLifecycleId(owner.runtimeContextId)) ||
        !isModelId(owner.modelId) ||
        !isCanonicalTimestamp(owner.expectedUpdatedAt)
      ) {
        return state;
      }
      const conversation = state.conversations[owner.conversationId];
      const context = conversation?.projectContext;
      const strictContext =
        context === null || context === undefined
          ? null
          : strictProjectContextState(context);
      const snapshot = strictContext?.snapshot;
      if (
        conversation === undefined ||
        conversation.projectId !== owner.projectId ||
        conversation.runtimeContextId !== owner.runtimeContextId ||
        conversation.modelId !== owner.modelId ||
        conversation.updatedAt !== owner.expectedUpdatedAt ||
        Date.parse(payload.at) < Date.parse(owner.expectedUpdatedAt) ||
        context === null ||
        context === undefined ||
        strictContext === null ||
        context !== owner.expectedContext ||
        strictContext.activePreparationId !== null ||
        snapshot === null ||
        snapshot === undefined ||
        !isCanonicalLifecycleId(snapshot.snapshot_id) ||
        !isSha256Digest(snapshot.snapshot_sha256)
      ) {
        return state;
      }
      const consentReceiptId =
        strictContext.consent?.consent_receipt_id ?? null;
      if (
        consentReceiptId !== null &&
        !isCanonicalLifecycleId(consentReceiptId)
      ) {
        return state;
      }
      const epoch = state.projectContextDestructiveEpoch + 1;
      const transition: ProjectContextDestructiveTransitionV1 = {
        schemaVersion:
          PROJECT_CONTEXT_DESTRUCTIVE_TRANSITION_SCHEMA_VERSION,
        lifecycleId: payload.lifecycleId,
        epoch,
        action: payload.action,
        phase: 'intent',
        conversationId: conversation.id,
        sourceProjectId: owner.projectId,
        sourceRuntimeContextId: owner.runtimeContextId,
        sourceModelId: owner.modelId,
        snapshotId: snapshot.snapshot_id,
        snapshotSha256: snapshot.snapshot_sha256,
        consentReceiptId,
        targetProjectId: payload.targetProjectId,
        createdAt: payload.at,
        updatedAt: payload.at,
      };
      if (hasProjectContextDestructiveReferences(state, transition)) {
        return state;
      }
      return {
        ...state,
        projectContextDestructiveEpoch: epoch,
        projectContextDestructiveTransition: transition,
      };
    }

    case 'project-context-destructive/tombstone': {
      const payload = action.payload;
      const transition = state.projectContextDestructiveTransition;
      if (
        !isExactDataRecord(payload, destructiveAdvanceKeys) ||
        transition === null ||
        !destructiveAdvanceScopeMatches(payload.scope, transition) ||
        !isCanonicalTimestamp(payload.at) ||
        transition.phase !== 'intent' ||
        Date.parse(payload.at) < Date.parse(transition.updatedAt) ||
        state.projectContextDestructiveEpoch !== transition.epoch
      ) {
        return state;
      }
      const conversation = state.conversations[transition.conversationId];
      if (
        conversation === undefined ||
        !isExactIntentContext(conversation, transition) ||
        hasProjectContextDestructiveReferences(state, transition)
      ) {
        return state;
      }
      return withConversation(
        {
          ...state,
          projectContextDestructiveTransition: {
            ...transition,
            phase: 'cleanup_pending',
            updatedAt: payload.at,
          },
        },
        {
          ...conversation,
          projectContext: createProjectContextState(
            transition.sourceProjectId,
          ),
          updatedAt: laterTimestamp(conversation.updatedAt, payload.at),
        },
      );
    }

    case 'project-context-destructive/cleanup-complete': {
      const payload = action.payload;
      if (
        !isExactDataRecord(payload, destructiveAdvanceKeys) ||
        !isCanonicalTimestamp(payload.at)
      ) {
        return state;
      }
      const owned = destructiveTransitionConversation(
        state,
        payload.scope,
        'cleanup_pending',
      );
      if (
        owned === null ||
        Date.parse(payload.at) < Date.parse(owned.transition.updatedAt)
      ) {
        return state;
      }
      return {
        ...state,
        projectContextDestructiveTransition: {
          ...owned.transition,
          phase: 'ready_to_finalize',
          updatedAt: payload.at,
        },
      };
    }

    case 'project-context-destructive/finalize': {
      const payload = action.payload;
      if (
        !isExactDataRecord(payload, destructiveAdvanceKeys) ||
        !isCanonicalTimestamp(payload.at)
      ) {
        return state;
      }
      const owned = destructiveTransitionConversation(
        state,
        payload.scope,
        'ready_to_finalize',
      );
      if (
        owned === null ||
        Date.parse(payload.at) < Date.parse(owned.transition.updatedAt)
      ) {
        return state;
      }
      const transition = owned.transition;
      const withoutJournal: ChatState = {
        ...state,
        projectContextDestructiveTransition: null,
      };
      if (transition.action === 'delete') {
        return deleteConversationState(
          withoutJournal,
          transition.conversationId,
        );
      }
      return withConversation(withoutJournal, {
        ...owned.conversation,
        projectId:
          transition.action === 'rebind'
            ? transition.targetProjectId
            : null,
        workspaceId: null,
        workspaceBinding: null,
        workspaceBootstrapState: 'none',
        projectContext:
          transition.action === 'rebind'
            ? createProjectContextState(transition.targetProjectId!)
            : null,
        updatedAt: laterTimestamp(owned.conversation.updatedAt, payload.at),
      });
    }

    case 'message/append': {
      const { conversationId, message } = action.payload;
      const conversation = state.conversations[conversationId];
      if (conversation === undefined) {
        return state;
      }
      const normalized = normalizedMessage(conversation, message);
      if (normalized === null) return state;
      const text = normalized.text;
      const autoTitleSource =
        text.trim().length > 0
          ? text
          : normalized.attachments[0]?.name ?? '';
      const autoTitle =
        normalized.role === 'user' && shouldAutoTitle(conversation)
          ? deriveAutoTitle(autoTitleSource)
          : conversation.title;
      return withConversation(state, {
        ...conversation,
        title: autoTitle,
        messages: [...conversation.messages, normalized],
        updatedAt: laterTimestamp(conversation.updatedAt, normalized.createdAt),
      });
    }

    case 'turn/prepare': {
      const { conversationId, message, turn, attempt } = action.payload;
      const conversation = state.conversations[conversationId];
      if (conversation === undefined) return state;
      const normalized = normalizedMessage(conversation, message);
      if (normalized === null || normalized.role !== 'user') return state;
      const visibleMessageRows = [...conversation.messages, normalized].slice(
        -MAX_ATTEMPT_VISIBLE_MESSAGES,
      );
      const visibleMessages = visibleMessageRows.map(item => item.id);
      const attachmentIds: string[] = [];
      const seenAttachmentIds = new Set<string>();
      let visibleAttachmentCount = 0;
      let visibleAttachmentBytes = 0;
      visibleMessageRows.forEach(visibleMessage => {
        visibleMessage.attachments.forEach(attachment => {
          visibleAttachmentCount += 1;
          visibleAttachmentBytes += attachment.size;
          if (seenAttachmentIds.has(attachment.id)) return;
          seenAttachmentIds.add(attachment.id);
          attachmentIds.push(attachment.id);
        });
      });
      const hasPendingAttempt = conversation.attempts.some(
        item => item.status === 'prepared' || item.status === 'sending',
      );
      if (
        hasPendingAttempt ||
        turn.schemaVersion !== CONVERSATION_TURN_SCHEMA_VERSION ||
        !isCanonicalLifecycleId(turn.turnId) ||
        hasLifecycleId(state, turn.turnId) ||
        turn.userMessageId !== normalized.id ||
        !hasSameStrings(turn.attemptIds, [attempt.attemptId]) ||
        turn.createdAt !== normalized.createdAt ||
        turn.turnId === attempt.attemptId ||
        attempt.schemaVersion !== TURN_ATTEMPT_SCHEMA_VERSION ||
        !isCanonicalLifecycleId(attempt.attemptId) ||
        hasLifecycleId(state, attempt.attemptId) ||
        attempt.turnId !== turn.turnId ||
        attempt.status !== 'prepared' ||
        !hasSameStrings(attempt.visibleMessageIds, visibleMessages) ||
        attempt.visibleHistorySha256 !== null ||
        !hasSameStrings(attempt.attachmentIds, attachmentIds) ||
        visibleAttachmentCount > MAX_ATTEMPT_ATTACHMENT_IDS ||
        visibleAttachmentBytes > MAX_TOTAL_ATTACHMENT_SIZE ||
        attempt.modelId !== conversation.modelId ||
        attempt.thinkingMode !== conversation.thinkingMode ||
        !attemptBindingIsValid(conversation, attempt) ||
        attempt.activeRound !== null ||
        attempt.rounds.length !== 0 ||
        attempt.assistantMessageId !== null ||
        attempt.failureCode !== null ||
        attempt.createdAt !== normalized.createdAt ||
        attempt.updatedAt !== normalized.createdAt
      ) {
        return state;
      }
      const autoTitleSource =
        normalized.text.trim().length > 0
          ? normalized.text
          : normalized.attachments[0]?.name ?? '';
      return withConversation(state, {
        ...conversation,
        title: shouldAutoTitle(conversation)
          ? deriveAutoTitle(autoTitleSource)
          : conversation.title,
        messages: [...conversation.messages, normalized],
        turns: [
          ...conversation.turns,
          {
            schemaVersion: turn.schemaVersion,
            turnId: turn.turnId,
            userMessageId: turn.userMessageId,
            attemptIds: [...turn.attemptIds],
            createdAt: turn.createdAt,
          },
        ],
        attempts: [...conversation.attempts, copyAttempt(attempt)],
        updatedAt: laterTimestamp(conversation.updatedAt, normalized.createdAt),
      });
    }

    case 'attempt/start-round': {
      const conversation =
        state.conversations[action.payload.conversationId];
      if (
        conversation === undefined ||
        !isCanonicalTimestamp(action.payload.at) ||
        !isExactDataRecord(action.payload.round, activeRoundKeys) ||
        !isCanonicalLifecycleId(action.payload.round.roundId) ||
        hasLifecycleId(state, action.payload.round.roundId)
      ) {
        return state;
      }
      const index = attemptIndex(conversation, action.payload.attemptId);
      const attempt = conversation.attempts[index];
      if (
        attempt === undefined ||
        (attempt.agent !== undefined && attempt.agent !== null) ||
        attempt.status !== 'prepared' ||
        !preparedAttemptIsApplicable(conversation, attempt) ||
        attempt.activeRound !== null ||
        attempt.rounds.length >= MAX_COMPLETION_ROUNDS ||
        (attempt.rounds.length > 0 &&
          attempt.rounds[attempt.rounds.length - 1]?.finishReason !==
            'tool_calls') ||
        action.payload.round.roundIndex !== attempt.rounds.length
      ) {
        return state;
      }
      return withConversation(
        state,
        replaceAttempt(conversation, index, {
          ...attempt,
          status: 'sending',
          activeRound: {
            roundId: action.payload.round.roundId,
            roundIndex: action.payload.round.roundIndex,
          },
          updatedAt: laterTimestamp(attempt.updatedAt, action.payload.at),
        }),
      );
    }

    case 'attempt/record-round': {
      const conversation =
        state.conversations[action.payload.conversationId];
      if (
        conversation === undefined ||
        !isCanonicalTimestamp(action.payload.at)
      ) {
        return state;
      }
      const index = attemptIndex(conversation, action.payload.attemptId);
      const attempt = conversation.attempts[index];
      const receipt = action.payload.receipt;
      if (
        attempt === undefined ||
        (attempt.agent !== undefined && attempt.agent !== null) ||
        attempt.status !== 'sending' ||
        attempt.activeRound === null ||
        !receiptIsValid(attempt, receipt) ||
        attempt.activeRound.roundId !== receipt.roundId ||
        attempt.activeRound.roundIndex !== receipt.roundIndex ||
        receipt.roundIndex !== attempt.rounds.length ||
        hasProviderReceiptId(state, receipt)
      ) {
        return state;
      }
      return withConversation(
        state,
        replaceAttempt(conversation, index, {
          ...attempt,
          status: 'prepared',
          visibleHistorySha256: receipt.visibleHistorySha256,
          activeRound: null,
          rounds: [...attempt.rounds, copyRoundReceipt(receipt)],
          updatedAt: laterTimestamp(attempt.updatedAt, action.payload.at),
        }),
      );
    }

    case 'attempt/complete': {
      const conversation =
        state.conversations[action.payload.conversationId];
      if (conversation === undefined) return state;
      const index = attemptIndex(conversation, action.payload.attemptId);
      const attempt = conversation.attempts[index];
      const lastReceipt = attempt?.rounds[attempt.rounds.length - 1];
      const normalized = normalizedMessage(conversation, action.payload.message);
      if (
        attempt === undefined ||
        (attempt.agent !== undefined &&
          attempt.agent !== null &&
          attempt.agent.phase !== 'final_response') ||
        attempt.status !== 'prepared' ||
        attempt.activeRound !== null ||
        lastReceipt === undefined ||
        lastReceipt.finishReason === 'tool_calls' ||
        normalized === null ||
        normalized.role !== 'assistant' ||
        normalized.metadata?.modelId !== lastReceipt.model ||
        normalized.metadata.latencyMs !== lastReceipt.latencyMs ||
        normalized.metadata.finishReason !== lastReceipt.finishReason
      ) {
        return state;
      }
      const nextConversation = replaceAttempt(conversation, index, {
        ...attempt,
        status: 'completed',
        assistantMessageId: normalized.id,
        failureCode: null,
        updatedAt: laterTimestamp(attempt.updatedAt, normalized.createdAt),
      });
      return withConversation(state, {
        ...nextConversation,
        messages: [...conversation.messages, normalized],
        updatedAt: laterTimestamp(conversation.updatedAt, normalized.createdAt),
      });
    }

    case 'attempt/fail': {
      const conversation =
        state.conversations[action.payload.conversationId];
      if (
        conversation === undefined ||
        !isCanonicalTimestamp(action.payload.at) ||
        !isAttemptFailureCode(action.payload.failureCode)
      ) {
        return state;
      }
      const index = attemptIndex(conversation, action.payload.attemptId);
      const attempt = conversation.attempts[index];
      if (
        attempt === undefined ||
        (attempt.agent !== undefined && attempt.agent !== null) ||
        (attempt.status !== 'prepared' && attempt.status !== 'sending')
      ) {
        return state;
      }
      return withConversation(
        state,
        replaceAttempt(conversation, index, {
          ...attempt,
          status: 'failed',
          activeRound: null,
          failureCode: action.payload.failureCode,
          updatedAt: laterTimestamp(attempt.updatedAt, action.payload.at),
        }),
      );
    }

    case 'attempt/cancel': {
      const conversation =
        state.conversations[action.payload.conversationId];
      if (
        conversation === undefined ||
        !isCanonicalTimestamp(action.payload.at)
      ) {
        return state;
      }
      const index = attemptIndex(conversation, action.payload.attemptId);
      const attempt = conversation.attempts[index];
      if (
        attempt === undefined ||
        (attempt.agent !== undefined && attempt.agent !== null) ||
        (attempt.status !== 'prepared' && attempt.status !== 'sending')
      ) {
        return state;
      }
      return withConversation(
        state,
        replaceAttempt(conversation, index, {
          ...attempt,
          status: 'cancelled',
          activeRound: null,
          failureCode: null,
          updatedAt: laterTimestamp(attempt.updatedAt, action.payload.at),
        }),
      );
    }

    case 'attempt/retry': {
      const conversation =
        state.conversations[action.payload.conversationId];
      if (conversation === undefined) return state;
      const source = conversation.attempts.find(
        item => item.attemptId === action.payload.sourceAttemptId,
      );
      const attempt = action.payload.attempt;
      const turnIndex = conversation.turns.findIndex(
        turn => turn.turnId === source?.turnId,
      );
      const turn = conversation.turns[turnIndex];
      const hasPendingAttempt = conversation.attempts.some(
        item => item.status === 'prepared' || item.status === 'sending',
      );
      const sourceIsCurrentVisibleHistory =
        source !== undefined &&
        hasSameStrings(
          source.visibleMessageIds,
          conversation.messages
            .slice(-MAX_ATTEMPT_VISIBLE_MESSAGES)
            .map(message => message.id),
        );
      if (
        source === undefined ||
        (source.status !== 'failed' && source.status !== 'cancelled') ||
        (source !== undefined &&
          hasAgentJournalOrReceipt(source) &&
          source.failureCode !== 'E_ATTEMPT_INTERRUPTED') ||
        turn === undefined ||
        hasPendingAttempt ||
        !sourceIsCurrentVisibleHistory ||
        (source !== undefined &&
          !retryBindingIsApplicable(conversation, source)) ||
        attempt.schemaVersion !== TURN_ATTEMPT_SCHEMA_VERSION ||
        !isCanonicalLifecycleId(attempt.attemptId) ||
        hasLifecycleId(state, attempt.attemptId) ||
        attempt.turnId !== source.turnId ||
        attempt.status !== 'prepared' ||
        !hasSameStrings(attempt.visibleMessageIds, source.visibleMessageIds) ||
        attempt.visibleHistorySha256 !== source.visibleHistorySha256 ||
        !hasSameStrings(attempt.attachmentIds, source.attachmentIds) ||
        attempt.modelId !== conversation.modelId ||
        attempt.thinkingMode !== conversation.thinkingMode ||
        attempt.harnessId !== harnessForModel(conversation.modelId) ||
        attempt.contextDisposition !== source.contextDisposition ||
        attempt.contextProjectId !== source.contextProjectId ||
        attempt.workspaceId !== source.workspaceId ||
        attempt.workspaceBindingRevision !== source.workspaceBindingRevision ||
        !sameAttemptBinding(attempt.projectContext, source.projectContext) ||
        attempt.activeRound !== null ||
        attempt.rounds.length !== 0 ||
        attempt.assistantMessageId !== null ||
        attempt.failureCode !== null ||
        !isCanonicalTimestamp(attempt.createdAt) ||
        attempt.updatedAt !== attempt.createdAt
      ) {
        return state;
      }
      const attempts = [...conversation.attempts, copyAttempt(attempt)];
      const turns = [...conversation.turns];
      turns[turnIndex] = {
        ...turn,
        attemptIds: [...turn.attemptIds, attempt.attemptId],
      };
      return withConversation(state, {
        ...conversation,
        turns,
        attempts,
        updatedAt: laterTimestamp(conversation.updatedAt, attempt.createdAt),
      });
    }

    case 'attempt/agent-checkpoint': {
      const payload = action.payload;
      // The reducer is a final-schema authority boundary.  Schema-2 journals
      // are accepted only by persistence bootstrap/migration and must never
      // be applied as a live state action.
      if (payload.journal === null || !isAgentAttemptJournalV3(payload.journal)) {
        return state;
      }
      return applyFinalAgentCheckpoint(state, payload);
    }

    case 'attempt/agent-advance-call':
      return applyAgentCallAdvance(state, action.payload);

    case 'attempt/agent-final-checkpoint':
      return applyAtomicAgentFinalCheckpoint(state, action.payload);

    case 'conversation/agent-grants': {
      const payload = action.payload;
      const conversation = state.conversations[payload.conversationId];
      if (
        conversation === undefined ||
        payload.expectedConversation !== conversation ||
        !isCanonicalTimestamp(payload.at) ||
        !isExactDataArray(payload.grants, MAX_AGENT_GRANTS_PER_CONVERSATION) ||
        payload.grants.some(grant => !agentGrantIsValid(grant))
      ) return state;
      const grants = payload.grants.map(grant => ({
        ...grant,
        issued_for: { ...grant.issued_for },
      }));
      const conversationBinding = conversation.workspaceBinding ?? null;
      const ids = new Set<string>();
      const currentGrantIds = new Set(
        (conversation.agentGrants ?? []).map(grant => grant.grant_id),
      );
      if (
        grants.some(grant => {
          if (ids.has(grant.grant_id)) return true;
          ids.add(grant.grant_id);
          return (
            (hasLifecycleId(state, grant.grant_id) &&
              !currentGrantIds.has(grant.grant_id)) ||
            grant.conversation_id !== conversation.id ||
            grant.project_id !== conversation.projectId ||
            conversationBinding === null ||
            grant.workspace_id !== conversationBinding.workspaceId ||
            grant.binding_revision !== conversationBinding.bindingRevision ||
            grant.root_fingerprint_sha256.length !== 64 ||
            !conversation.attempts.some(
              attempt =>
                attempt.attemptId === grant.issued_for.attempt_id &&
                attempt.turnId === grant.issued_for.task_id,
            )
          );
        })
      ) return state;
      const grantIdsAfter = new Set(grants.map(grant => grant.grant_id));
      if (
        conversation.attempts.some(attempt =>
          attempt.agent?.frozen_grant_ids.some(
            grantId => !grantIdsAfter.has(grantId),
          ),
        )
      ) return state;
      const conversations = {
        ...state.conversations,
        [conversation.id]: {
          ...conversation,
          agentGrants: grants,
          updatedAt: laterTimestamp(conversation.updatedAt, payload.at),
        },
      };
      return {
        ...state,
        conversations,
        conversationOrder: orderConversationIds(conversations),
      };
    }

    case 'agent/approval-checkpoint': {
      const payload = action.payload;
      const conversation = state.conversations[payload.conversationId];
      const evidence = closedCheckpointEvidence(payload.evidence);
      if (
        conversation === undefined ||
        payload.expectedConversation !== conversation ||
        !isAgentAttemptJournalV3(payload.journal) ||
        evidence === null ||
        !approvalEvidenceGrantsMatch(
          evidence,
          payload.grants,
          conversation.agentGrants ?? conversation.agent_grants ?? [],
        )
      ) return state;
      const withJournal = applyFinalAgentCheckpoint(state, {
        cas: payload.cas,
        conversationId: payload.conversationId,
        attemptId: payload.attemptId,
        expectedAttempt: payload.expectedAttempt,
        journal: payload.journal,
        events: payload.events,
        evidence: payload.evidence,
        ...(payload.cleanup === undefined
          ? {}
          : { cleanup: payload.cleanup }),
        ...(payload.journalRevision === undefined
          ? {}
          : { journalRevision: payload.journalRevision }),
        at: payload.at,
      }, false, payload.grants);
      if (withJournal === state) return state;
      const nextConversation = withJournal.conversations[payload.conversationId];
      return nextConversation === undefined
        ? state
        : chatReducer(withJournal, {
            type: 'conversation/agent-grants',
            payload: {
              conversationId: payload.conversationId,
              expectedConversation: nextConversation,
              grants: payload.grants,
              at: payload.at,
            },
          });
    }

    case 'agent/cleanup-enqueue': {
      const payload = action.payload;
      const conversation = state.conversations[payload.conversationId];
      const ownedAttempt = conversation?.attempts.find(
        attempt => attempt.attemptId === payload.attemptId,
      );
      const liveCleanupReason =
        ownedAttempt?.agent === undefined || ownedAttempt.agent === null
          ? null
          : cleanupReasonForTerminalPhase(ownedAttempt.agent.phase);
      const detachedDeletedCleanup =
        conversation === undefined &&
        typeof payload.cleanup === 'object' &&
        payload.cleanup !== null &&
        payload.cleanup.reason === 'conversation_deleted' &&
        typeof payload.expectedAttempt === 'object' &&
        payload.expectedAttempt !== null &&
        payload.expectedAttempt.attemptId === payload.attemptId &&
        payload.expectedAttempt.agent !== undefined &&
        payload.expectedAttempt.agent !== null &&
        isAgentAttemptJournalV3(payload.expectedAttempt.agent) &&
        (payload.expectedAttempt.agent.phase === 'final_response' ||
          payload.expectedAttempt.agent.phase === 'cancelled' ||
          payload.expectedAttempt.agent.phase === 'failed') &&
        !Object.values(state.conversations).some(candidate =>
          candidate.attempts.some(attempt => attempt.attemptId === payload.attemptId),
        );
      if (
        (!detachedDeletedCleanup &&
          (conversation === undefined ||
            ownedAttempt === undefined ||
            payload.expectedAttempt !== ownedAttempt)) ||
        typeof payload.expectedAttempt !== 'object' ||
        payload.expectedAttempt === null ||
        !isCanonicalTimestamp(payload.at) ||
        typeof payload.cleanup !== 'object' ||
        payload.cleanup === null ||
        !cleanupEntryIsValid(payload.cleanup) ||
        (!detachedDeletedCleanup &&
          (liveCleanupReason === null ||
            payload.cleanup.reason !== liveCleanupReason)) ||
        (payload.expectedAttempt.agent !== undefined &&
          payload.expectedAttempt.agent !== null &&
          !isAgentAttemptJournalV3(payload.expectedAttempt.agent)) ||
        payload.cleanup.conversation_id !== payload.conversationId ||
        payload.cleanup.task_id !== payload.expectedAttempt.turnId ||
        payload.cleanup.attempt_id !== payload.attemptId ||
        payload.expectedAttempt.agent?.transcript.transcript_ref !==
          payload.cleanup.transcript_ref ||
        payload.expectedAttempt.agent?.transcript.transcript_sha256 !==
          payload.cleanup.transcript_sha256
      ) return state;
      const outbox = state.agentTranscriptCleanupOutbox ?? [];
      if (
        outbox.length >= MAX_AGENT_CLEANUP_OUTBOX_ENTRIES ||
        outbox.some(entry => entry.cleanup_id === payload.cleanup.cleanup_id)
      ) return state;
      return {
        ...state,
        agentTranscriptCleanupOutbox: [
          ...outbox,
          { ...payload.cleanup },
        ],
      };
    }

    case 'agent/abandon-unresolved': {
      const payload = action.payload;
      const conversation = state.conversations[payload.conversationId];
      const index =
        conversation === undefined
          ? -1
          : attemptIndex(conversation, payload.attemptId);
      const attempt = conversation?.attempts[index];
      const journal = attempt?.agent;
      const outbox = state.agentTranscriptCleanupOutbox ?? [];
      if (
        conversation === undefined ||
        attempt === undefined ||
        payload.expectedAttempt !== attempt ||
        journal === undefined ||
        journal === null ||
        !isAgentAttemptJournalV3(journal) ||
        // Only the two answers the device cannot resolve by itself. A
        // resumable attempt is resumed, and a terminal one is already over.
        (journal.phase !== 'ambiguous' && journal.phase !== 'unknown') ||
        attempt.failureCode === 'E_ATTEMPT_INTERRUPTED' ||
        attempt.assistantMessageId !== null ||
        !isCanonicalTimestamp(payload.at) ||
        !cleanupEntryIsValid(payload.cleanup) ||
        payload.cleanup.reason !== 'failed' ||
        payload.cleanup.conversation_id !== payload.conversationId ||
        payload.cleanup.task_id !== attempt.turnId ||
        payload.cleanup.attempt_id !== payload.attemptId ||
        payload.cleanup.transcript_ref !== journal.transcript.transcript_ref ||
        payload.cleanup.transcript_sha256 !==
          journal.transcript.transcript_sha256 ||
        outbox.length >= MAX_AGENT_CLEANUP_OUTBOX_ENTRIES ||
        outbox.some(entry => entry.cleanup_id === payload.cleanup.cleanup_id)
      ) return state;
      // Recorded exactly as hydration records a dead writer's attempt: the
      // journal stays as the round and transcript evidence, and the failure
      // code is the one the retry reducer accepts a journal with.
      const abandoned: TurnAttemptV1 = {
        ...attempt,
        status: 'failed',
        activeRound: null,
        failureCode: 'E_ATTEMPT_INTERRUPTED',
        updatedAt: payload.at,
      };
      return {
        ...withConversation(
          state,
          replaceAttempt(conversation, index, abandoned),
        ),
        agentTranscriptCleanupOutbox: [...outbox, { ...payload.cleanup }],
      };
    }

    case 'agent/cleanup-ack': {
      const payload = action.payload;
      const outbox = state.agentTranscriptCleanupOutbox ?? [];
      const index = outbox.findIndex(
        entry => entry.cleanup_id === payload.cleanupId,
      );
      if (
        index < 0 ||
        !cleanupEntryIsValid(payload.expectedCleanup) ||
        outbox[index] !== payload.expectedCleanup
      ) return state;
      return {
        ...state,
        agentTranscriptCleanupOutbox: outbox.filter(
          (_entry, entryIndex) => entryIndex !== index,
        ),
      };
    }

  }
}
