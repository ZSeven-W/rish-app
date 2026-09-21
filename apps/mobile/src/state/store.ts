import { hydrateAppPreferences, serializeAppPreferences } from '../preferences/persistence';
import {
  chatReducer,
  createEmptyChatState,
  isCanonicalLifecycleId,
  MAX_ATTEMPT_VISIBLE_MESSAGES,
  MAX_WORKSPACE_AUTHORITY_OUTBOX_ENTRIES,
  orderConversationIds,
  isWorkspaceAuthorityOutboxEntry,
  hasWorkspaceAuthorityReferences,
  isAgentAttemptJournalV3,
  isAgentToolReceipt,
} from './reducer';
import {
  hydrateChatState,
  serializeChatState,
} from './persistence';
import {
  sessionSnapshotSHA256,
  type SessionCASPersistResultV1,
  type SessionSnapshotRefV1,
} from '../completion/SessionPersistence';
import type {
  DiscardAgentAttemptResultV2,
  InterruptAgentAttemptResultV2,
} from '../native/AgentRuntime';
import type {
  ChatAction,
  ChatAttachment,
  ChatMessage,
  ChatMessageMetadata,
  ChatState,
  CompletionRoundReceiptV1,
  Conversation,
  ConversationThinkingMode,
  ModelId,
  ProjectContextDestructiveAction,
  ProjectContextDestructiveAdvanceScope,
  ProjectContextDestructiveOwner,
  ProjectContextMutationScope,
  TurnAttemptV1,
  ApplyWorkspaceBindingInputV1,
  ConversationWorkspaceBindingV1,
  WorkspaceAuthorityMutationInputV1,
  WorkspaceAuthorityOutboxV1,
  WorkspaceBindingOwnerV1,
  AgentConversationGrantV2,
  AgentTranscriptCleanupV1,
  PersistedAgentAttemptJournalV3,
  AgentToolReceiptV1,
  AgentControllerCASV1,
  AgentConversationDeleteWithCleanupInput,
  AgentCheckpointEvidence,
  AgentStoreTransitionEvidence,
  PersistedSessionEventV3,
} from './types';
import {
  validateAgentStoreTransition,
  type AgentStoreOperation,
} from '../agent/AgentStoreTransitions';
import {
  validateAgentControllerPreflight,
  type AgentControllerPreflightV1,
} from '../agent/AgentControllerPreflight';
import { projectAgentVisibleHistory } from '../agent/AgentVisibleHistory';
import { isProjectContextSendable } from '../project-context/reducer';
import { harnessForModel, isHarnessId, providerForModel } from '../harness/types';
import type {
  ProjectContextAction,
  ProjectContextConsentV1,
  ProjectContextManifestV1,
} from '../project-context/types';

export type ChatStoreIdKind = 'conversation' | 'message';
export type ChatStoreLifecycleIdKind =
  | 'runtimeContext'
  | 'turn'
  | 'attempt'
  | 'round';
export type ChatStoreListener = (state: ChatState) => void;

export type ChatStoreOptions = {
  readonly initialState?: ChatState;
  readonly now?: () => Date | number | string;
  readonly createId?: (kind: ChatStoreIdKind) => string;
  /**
   * Generates canonical UUID identities for distinct durable lifecycle
   * entities. The kind is semantic and must not be silently rerouted.
   */
  readonly createLifecycleId?: (kind: ChatStoreLifecycleIdKind) => string;
  /** Latest native session reference used by Agent controller CAS guards. */
  readonly sessionAuthority?: SessionAuthority;
  /** Optional live authority accessor for callers coordinating native CAS. */
  readonly getSessionAuthority?: () => SessionAuthority | null;
};

export type SessionAuthority = {
  readonly generation: number;
  readonly sessionSha256: string;
};

/**
 * The only proof that settles an Agent session candidate. This is deliberately
 * the committed branch (or exact committed snapshot ref) of the native CAS
 * result; Store never derives a next generation from its local authority.
 */
export type NativeSessionCommitProofV1 =
  | Extract<
      SessionCASPersistResultV1,
      { readonly status: 'committed' }
    >
  | SessionSnapshotRefV1;

/**
 * Native discard success plus the complete request identity it settled.  The
 * native result itself echoes only operation/cleanup IDs, so the controller
 * must carry the request binding into this closed proof envelope.
 */
export type NativeAgentDiscardProofV1 = Extract<
  DiscardAgentAttemptResultV2 | InterruptAgentAttemptResultV2,
  { readonly status: 'discarded' | 'already_missing' }
> & {
  readonly task_id: string;
  readonly conversation_id: string;
  readonly attempt_id: string;
  readonly transcript_ref: string;
  readonly transcript_sha256: string;
};

export type CreateConversationOptions = {
  readonly modelId?: ModelId;
  readonly thinkingMode?: ConversationThinkingMode;
  readonly projectId?: string | null;
  readonly workspaceId?: string | null;
  readonly title?: string;
  readonly select?: boolean;
};

export type AppendMessageOptions = {
  readonly metadata?: ChatMessageMetadata;
  readonly attachments?: readonly ChatAttachment[];
};

export type PrepareTurnAttemptOptions = AppendMessageOptions & {
  /** Explicit user choice to send a project-bound turn without local context. */
  readonly sendWithoutProjectContext?: boolean;
  /** Harness that owns this attempt; omitted by legacy callers and dsh. */
  readonly harnessId?: string;
};

export type PreparedTurnAttempt = {
  readonly turnId: string;
  readonly attemptId: string;
  readonly userMessageId: string;
};

export type PreparedTurnTransaction = PreparedTurnAttempt & {
  /** Disarms rollback after the prepared state is durably accepted. */
  commit(): boolean;
  /** Restores the exact prior root only while no later state won the race. */
  rollback(): boolean;
};

export type OneShotChatTransaction = {
  /** Settles only while the exact candidate remains the current row. */
  commit(): boolean;
  /** Restores the exact target row while preserving unrelated state changes. */
  rollback(): boolean;
};

export type AgentCheckpointInput = {
  readonly cas: AgentControllerCASV1;
  readonly conversationId?: string;
  readonly attemptId?: string;
  readonly expectedAttempt: TurnAttemptV1;
  /** V3 is the only Store/runtime journal. V2 is accepted by hydration only. */
  readonly journal: PersistedAgentAttemptJournalV3 | null;
  readonly journalRevision?: number;
  readonly events: readonly PersistedSessionEventV3[];
  readonly evidence: AgentCheckpointEvidence;
  /** Optional terminal cleanup ownership persisted in this same candidate. */
  readonly cleanup?: AgentTranscriptCleanupV1;
};

/**
 * One first-terminal Agent candidate. `assistantMessage` is required only for
 * `final_response`; failed and cancelled checkpoints must carry `null`.
 */
export type AgentFinalCheckpointInput = Omit<
  AgentCheckpointInput,
  'journal' | 'evidence' | 'cleanup'
> & {
  readonly journal: PersistedAgentAttemptJournalV3;
  readonly evidence: AgentStoreTransitionEvidence;
  readonly assistantMessage: ChatMessage | null;
  readonly cleanup: AgentTranscriptCleanupV1;
};

type NormalizedAgentCheckpointInput = Omit<
  AgentCheckpointInput,
  'conversationId' | 'attemptId'
> & {
  readonly conversationId: string;
  readonly attemptId: string;
};
export type AgentApprovalCheckpointInput = Omit<AgentCheckpointInput, 'journal'> & {
  readonly expectedConversation: Conversation;
  readonly journal: PersistedAgentAttemptJournalV3;
  readonly grants: readonly AgentConversationGrantV2[];
};

export type RevokeAgentGrantInput = {
  readonly conversationId: string;
  readonly grantId: string;
  readonly expectedConversation: Conversation;
};

export type AgentExecutionIntentInput = AgentCheckpointInput & {
  readonly callIndex: number;
};

export type AgentToolResultInput = AgentCheckpointInput & {
  readonly callIndex: number;
  readonly receipt: AgentToolReceiptV1;
};

/** One evidence-free cursor advance inside an already-frozen native batch. */
export type AgentNextCallCheckpointInput = {
  readonly cas: AgentControllerCASV1;
  readonly conversationId?: string;
  readonly attemptId?: string;
  readonly expectedAttempt: TurnAttemptV1;
  readonly journal: PersistedAgentAttemptJournalV3;
  readonly journalRevision?: number;
};

/**
 * One durable checkpoint carrying three consecutive transitions of a tool
 * batch: the terminal result of call k, the cursor advance to call k+1, and
 * the execution intent (launch marker) of call k+1. Each transition is
 * validated by its own reducer against the intermediate state, exactly as
 * three separate checkpoints would be; only the persistence is shared. The
 * caller supplies the intermediate CAS for the launch marker (journal
 * revision +2, controller generation +2, same session authority) because
 * the preflight evidence binds to it.
 */
/**
 * One durable checkpoint carrying the accepted batch receipt and the
 * execution intent of its first executable call. Used only when no call in
 * the batch still needs an approval decision.
 */
export type AgentBatchAndFirstIntentInput = {
  readonly batch: AgentCheckpointInput;
  readonly next: {
    readonly cas: AgentControllerCASV1;
    readonly journal: PersistedAgentAttemptJournalV3;
    readonly callIndex: number;
    readonly events: readonly PersistedSessionEventV3[];
    readonly evidence: AgentCheckpointEvidence;
  };
};

export type AgentToolResultAndNextIntentInput = {
  readonly result: AgentToolResultInput;
  readonly advance: { readonly journal: PersistedAgentAttemptJournalV3 };
  readonly next: {
    readonly cas: AgentControllerCASV1;
    readonly journal: PersistedAgentAttemptJournalV3;
    readonly callIndex: number;
    readonly events: readonly PersistedSessionEventV3[];
    readonly evidence: AgentCheckpointEvidence;
  };
};

export type AgentCleanupInput = {
  readonly conversationId: string;
  readonly attemptId: string;
  readonly expectedAttempt: TurnAttemptV1;
  readonly cleanup: AgentTranscriptCleanupV1;
};

export type AgentCheckpointTransaction = Omit<OneShotChatTransaction, 'commit'> & {
  readonly conversationId: string;
  readonly attemptId: string;
  readonly journalRevision: number;
  /** Native `casPersistSession` committed result for this exact candidate. */
  commit(proof: NativeSessionCommitProofV1): boolean;
};

/** Session-CAS transaction used by cleanup/delete candidates as well. */
export type AgentSessionTransaction = Omit<OneShotChatTransaction, 'commit'> & {
  commit(proof?: NativeSessionCommitProofV1): boolean;
};

export type AgentCleanupAcknowledgementTransaction = Omit<
  OneShotChatTransaction,
  'commit'
> & {
  commit(
    proof: NativeSessionCommitProofV1,
    discardProof: NativeAgentDiscardProofV1,
  ): boolean;
};

export type AgentCASCheckpointInput = {
  readonly cas: AgentControllerCASV1;
  readonly conversationId?: string;
  readonly attemptId?: string;
  readonly expectedAttempt: TurnAttemptV1;
  readonly journal: PersistedAgentAttemptJournalV3 | null;
  readonly journalRevision?: number;
  readonly events: readonly PersistedSessionEventV3[];
  readonly evidence: AgentCheckpointEvidence;
  /** Optional terminal cleanup ownership persisted in this same candidate. */
  readonly cleanup?: AgentTranscriptCleanupV1;
};

export type WorkspaceAuthorityMutationTransaction = OneShotChatTransaction & {
  readonly operationId: string;
  readonly workspaceId: string;
  readonly bindingRevision: number;
  readonly action: WorkspaceAuthorityOutboxV1['action'];
  readonly outboxEntry: WorkspaceAuthorityOutboxV1;
};

export type ReplaceProjectContextPreparedInput = {
  readonly preparationId: string;
  readonly selectedPaths: readonly string[];
  readonly manifest: ProjectContextManifestV1;
};

export type ReplaceProjectContextConfirmedInput =
  ReplaceProjectContextPreparedInput & {
    readonly consent: ProjectContextConsentV1;
  };

export type ScopedProjectContextTransaction = {
  readonly conversationId: string;
  readonly previousSnapshotId: string | null;
  readonly nextSnapshotId: string | null;
  /** Settles only while the target conversation still equals the applied row. */
  commit(): boolean;
  /** Restores only the target conversation, preserving unrelated root changes. */
  rollback(): boolean;
};

export type DisableProjectContextTransaction =
  ScopedProjectContextTransaction & {
    readonly cleanupSnapshotId: string | null;
  };

export type BeginProjectContextDestructiveInput = {
  readonly lifecycleId: string;
  readonly action: ProjectContextDestructiveAction;
  readonly targetProjectId: string | null;
  readonly owner: ProjectContextDestructiveOwner;
};

export type ProjectContextDestructiveTransaction = {
  readonly lifecycleId: string;
  readonly epoch: number;
  commit(): boolean;
  rollback(): boolean;
};

export type SnapshotFreeProjectMutationInput = {
  readonly action: 'unbind' | 'delete' | 'rebind';
  readonly conversationId: string;
  readonly targetProjectId: string | null;
  readonly expectedConversation: Conversation;
};

export type SnapshotFreeProjectMutationTransaction = {
  readonly conversationId: string;
  readonly action: SnapshotFreeProjectMutationInput['action'];
  readonly targetProjectId: string | null;
  commit(): boolean;
  rollback(): boolean;
};

export type ChatStore = {
  getState(): ChatState;
  dispatch(action: ChatAction): ChatState;
  subscribe(listener: ChatStoreListener): () => void;
  createConversation(options?: CreateConversationOptions): string;
  renameConversation(id: string, title: string): void;
  autoTitleConversation(id: string, sourceText: string): void;
  selectConversation(id: string | null): void;
  appendUserMessage(
    conversationId: string,
    text: string,
    options?: AppendMessageOptions,
  ): string;
  appendAssistantMessage(
    conversationId: string,
    text: string,
    options?: AppendMessageOptions,
  ): string;
  deleteConversation(id: string): void;
  setModel(id: string, modelId: ModelId): void;
  setThinkingMode(id: string, thinkingMode: ConversationThinkingMode): void;
  bindConversationToProject(id: string, projectId: string): void;
  unbindConversationFromProject(id: string): void;
  bindConversationToWorkspace(id: string, workspaceId: string): void;
  unbindConversationFromWorkspace(id: string): void;
  ensureRuntimeContextId(conversationId: string): string | null;
  applyProjectContextAction(
    conversationId: string,
    action: ProjectContextAction,
  ): boolean;
  replaceProjectContextPrepared(
    scope: ProjectContextMutationScope,
    input: ReplaceProjectContextPreparedInput,
  ): ScopedProjectContextTransaction | null;
  replaceProjectContextConfirmed(
    scope: ProjectContextMutationScope,
    input: ReplaceProjectContextConfirmedInput,
  ): ScopedProjectContextTransaction | null;
  disableProjectContext(
    scope: ProjectContextMutationScope,
  ): DisableProjectContextTransaction | null;
  beginProjectContextDestructiveTransition(
    input: BeginProjectContextDestructiveInput,
  ): ProjectContextDestructiveTransaction | null;
  tombstoneProjectContextDestructiveTransition(
    scope: ProjectContextDestructiveAdvanceScope,
  ): ProjectContextDestructiveTransaction | null;
  markProjectContextDestructiveCleanupComplete(
    scope: ProjectContextDestructiveAdvanceScope,
  ): ProjectContextDestructiveTransaction | null;
  finalizeProjectContextDestructiveTransition(
    scope: ProjectContextDestructiveAdvanceScope,
  ): ProjectContextDestructiveTransaction | null;
  applySnapshotFreeProjectMutation(
    input: SnapshotFreeProjectMutationInput,
  ): SnapshotFreeProjectMutationTransaction | null;
  applyConversationWorkspaceBinding(
    input: ApplyWorkspaceBindingInputV1,
  ): OneShotChatTransaction | null;
  /** Persisted-checkpoint grant revocation: removes one conversation grant
   * with an exact expected-conversation guard. Returns null on any mismatch
   * (including a grant frozen into a live attempt) so the caller fails
   * closed; the caller must CAS-persist and roll back on failure. */
  revokeAgentGrant(input: RevokeAgentGrantInput): OneShotChatTransaction | null;
  applyWorkspaceAuthorityMutation(
    input: WorkspaceAuthorityMutationInputV1,
  ): WorkspaceAuthorityMutationTransaction | null;
  acknowledgeWorkspaceAuthorityMutation(
    operationId: string,
    expectedEntry?: WorkspaceAuthorityOutboxV1,
  ): boolean;
  prepareTurnAttempt(
    conversationId: string,
    text: string,
    options?: PrepareTurnAttemptOptions,
  ): PreparedTurnTransaction | null;
  startAttemptRound(
    conversationId: string,
    attemptId: string,
    roundId: string,
    roundIndex: number,
  ): boolean;
  recordAttemptRound(
    conversationId: string,
    attemptId: string,
    receipt: CompletionRoundReceiptV1,
  ): boolean;
  completeAttempt(
    conversationId: string,
    attemptId: string,
    text: string,
    options?: AppendMessageOptions,
  ): string | null;
  failAttempt(
    conversationId: string,
    attemptId: string,
    failureCode: string,
  ): boolean;
  cancelAttempt(conversationId: string, attemptId: string): boolean;
  retryAttempt(
    conversationId: string,
    sourceAttemptId: string,
  ): PreparedTurnTransaction | null;
  /**
   * Applies one immutable schema-9 Agent journal candidate.  The candidate is
   * visible immediately to subscribers, but its transaction must be settled
   * by the caller after the corresponding session checkpoint result is known.
   */
  checkpointAgentAttempt(
    input: AgentCheckpointInput,
  ): AgentCheckpointTransaction | null;
  checkpointAgentAttemptCAS(
    input: AgentCASCheckpointInput,
  ): AgentCheckpointTransaction | null;
  getSessionAuthority(): SessionAuthority | null;
  setSessionAuthority(authority: SessionAuthority | null): boolean;
  /** Validate only preferences; preserve conversation owners and native CAS authority. */
  setPreferences(input: unknown): boolean;
  checkpointAgentApproval(
    input: AgentApprovalCheckpointInput,
  ): AgentCheckpointTransaction | null;
  decideAgentApproval(
    input: AgentApprovalCheckpointInput,
  ): AgentCheckpointTransaction | null;
  checkpointAgentRound(
    input: AgentCheckpointInput,
  ): AgentCheckpointTransaction | null;
  initializeAgentAttempt(
    input: AgentCheckpointInput,
  ): AgentCheckpointTransaction | null;
  setAgentJournal(
    input: AgentCheckpointInput,
  ): AgentCheckpointTransaction | null;
  insertAgentExecutionIntent(
    input: AgentExecutionIntentInput,
  ): AgentCheckpointTransaction | null;
  recordAgentToolResult(
    input: AgentToolResultInput,
  ): AgentCheckpointTransaction | null;
  advanceAgentCall(
    input: AgentNextCallCheckpointInput,
  ): AgentCheckpointTransaction | null;
  recordAgentToolResultAndBeginNext(
    input: AgentToolResultAndNextIntentInput,
  ): AgentCheckpointTransaction | null;
  checkpointAgentBatchAndBeginFirst(
    input: AgentBatchAndFirstIntentInput,
  ): AgentCheckpointTransaction | null;
  advanceAgentRound(
    input: AgentCheckpointInput,
  ): AgentCheckpointTransaction | null;
  cancelAgentAttempt(
    input: AgentCheckpointInput,
  ): AgentCheckpointTransaction | null;
  failAgentAttempt(
    input: AgentCheckpointInput,
  ): AgentCheckpointTransaction | null;
  completeAgentAttempt(
    input: AgentFinalCheckpointInput,
  ): AgentCheckpointTransaction | null;
  enqueueAgentTranscriptCleanup(
    input: AgentCleanupInput,
  ): AgentCheckpointTransaction | null;
  /**
   * Record an attempt whose round the device can never resolve as given up
   * on, and enqueue the cleanup that settles its native residue. See the
   * `agent/abandon-unresolved` action for what that means and why the two
   * happen together.
   */
  abandonUnresolvedAgentAttempt(
    input: AgentCleanupInput,
  ): AgentCheckpointTransaction | null;
  acknowledgeAgentTranscriptCleanup(
    cleanupId: string,
    expectedCleanup: AgentTranscriptCleanupV1,
    proof: NativeSessionCommitProofV1,
    discardProof: NativeAgentDiscardProofV1,
  ): boolean;
  acknowledgeAgentTranscriptCleanupTransaction(
    cleanupId: string,
    expectedCleanup: AgentTranscriptCleanupV1,
  ): AgentCleanupAcknowledgementTransaction | null;
  deleteConversationWithAgentCleanup(
    input: AgentConversationDeleteWithCleanupInput,
  ): AgentSessionTransaction | null;
  serialize(): string;
  hydrate(input: unknown): ChatState;
};

let defaultIdCounter = 0;

function defaultCreateId(kind: ChatStoreIdKind): string {
  defaultIdCounter += 1;
  const entropy = Math.floor(Math.random() * 0x1_0000_0000)
    .toString(36)
    .padStart(7, '0');
  return `${kind}-${Date.now().toString(36)}-${defaultIdCounter.toString(
    36,
  )}-${entropy}`;
}

/** RFC-4122-shaped random identity for identity only, never for security. */
function defaultCreateLifecycleId(_kind: ChatStoreLifecycleIdKind): string {
  let value = '';
  for (let index = 0; index < 32; index += 1) {
    const random = Math.floor(Math.random() * 16);
    const nibble =
      index === 12 ? 4 : index === 16 ? 8 + (random % 4) : random;
    value += nibble.toString(16);
  }
  return `${value.slice(0, 8)}-${value.slice(8, 12)}-${value.slice(
    12,
    16,
  )}-${value.slice(16, 20)}-${value.slice(20)}`;
}

function canonicalNow(now: () => Date | number | string): string {
  const value = now();
  const date = value instanceof Date ? value : new Date(value);
  if (!Number.isFinite(date.getTime())) {
    throw new Error('ChatStore now() returned an invalid timestamp');
  }
  return date.toISOString();
}

/**
 * Whether an attempt that ran in the workspace still holds it: live, waiting
 * for its transcript to be swept, or carrying an agent journal that has not
 * ended. A finished attempt does not: when the workspace is forgotten its
 * frozen tuple is cleared with the conversation's binding (the schema keeps
 * the two equal), and the messages it produced stay as they are.
 */
function hasAttemptHoldingWorkspace(
  state: ChatState,
  conversation: Conversation,
  workspaceId: string,
): boolean {
  const pendingCleanup = new Set(
    (state.agentTranscriptCleanupOutbox ?? []).map(entry => entry.attempt_id),
  );
  return conversation.attempts.some(attempt => {
    if (attempt.workspaceId !== workspaceId) return false;
    if (attempt.status === 'prepared' || attempt.status === 'sending') return true;
    if (pendingCleanup.has(attempt.attemptId)) return true;
    const phase = attempt.agent?.phase;
    return (
      phase !== undefined &&
      phase !== 'final_response' &&
      phase !== 'cancelled' &&
      phase !== 'failed'
    );
  });
}

function hasLiveAttemptForWorkspace(
  conversation: Conversation,
  workspaceId: string,
): boolean {
  return conversation.attempts.some(
    attempt =>
      attempt.workspaceId === workspaceId &&
      (attempt.status === 'prepared' || attempt.status === 'sending'),
  );
}

function exactDataProjection(
  value: unknown,
  keys: readonly string[],
): Record<string, unknown> | null {
  try {
    if (typeof value !== 'object' || value === null || Array.isArray(value)) {
      return null;
    }
    const prototype = Object.getPrototypeOf(value);
    if (prototype !== Object.prototype && prototype !== null) return null;
    if (Object.getOwnPropertySymbols(value).length > 0) return null;
    const names = Object.getOwnPropertyNames(value);
    if (
      names.length !== keys.length ||
      names.some(name => !keys.includes(name))
    ) {
      return null;
    }
    const projected = Object.create(null) as Record<string, unknown>;
    for (const key of keys) {
      const descriptor = Object.getOwnPropertyDescriptor(value, key);
      if (
        descriptor === undefined ||
        !Object.prototype.hasOwnProperty.call(descriptor, 'value') ||
        descriptor.enumerable !== true
      ) {
        return null;
      }
      projected[key] = descriptor.value;
    }
    return projected;
  } catch {
    return null;
  }
}

function exactDataProjectionOptional(
  value: unknown,
  required: readonly string[],
  optional: readonly string[],
): Record<string, unknown> | null {
  if (
    typeof value !== 'object' ||
    value === null ||
    Array.isArray(value)
  ) return null;
  const prototype = Object.getPrototypeOf(value);
  if (prototype !== Object.prototype && prototype !== null) return null;
  if (Object.getOwnPropertySymbols(value).length > 0) return null;
  const names = Object.getOwnPropertyNames(value);
  const allowed = new Set([...required, ...optional]);
  if (names.some(name => !allowed.has(name))) return null;
  const result = Object.create(null) as Record<string, unknown>;
  for (const key of required) {
    const descriptor = Object.getOwnPropertyDescriptor(value, key);
    if (
      descriptor === undefined ||
      !Object.prototype.hasOwnProperty.call(descriptor, 'value') ||
      descriptor.enumerable !== true
    ) return null;
    result[key] = descriptor.value;
  }
  for (const key of optional) {
    const descriptor = Object.getOwnPropertyDescriptor(value, key);
    if (descriptor === undefined) continue;
    if (
      !Object.prototype.hasOwnProperty.call(descriptor, 'value') ||
      descriptor.enumerable !== true
    ) return null;
    result[key] = descriptor.value;
  }
  return result;
}

function normalizeAgentCheckpointInput(
  value: unknown,
): NormalizedAgentCheckpointInput | null {
  const projected = exactDataProjectionOptional(
    value,
    ['cas', 'expectedAttempt', 'journal', 'events'],
    [
      'conversationId',
      'attemptId',
      'journalRevision',
      'events',
      'evidence',
      'cleanup',
    ],
  );
  const cas = projected === null ? null : normalizeAgentControllerCAS(projected.cas);
  if (
    projected === null ||
    cas === null ||
    projected.expectedAttempt === undefined ||
    (projected.journal !== null && !isAgentAttemptJournalV3(projected.journal))
  ) return null;
  const conversationId: unknown =
    projected.conversationId === undefined
      ? cas.conversation_id
      : projected.conversationId;
  const attemptId: unknown =
    projected.attemptId === undefined ? cas.attempt_id : projected.attemptId;
  if (
    typeof conversationId !== 'string' ||
    typeof attemptId !== 'string' ||
    conversationId !== cas.conversation_id ||
    attemptId !== cas.attempt_id
  ) return null;
  const evidence = normalizeAgentCheckpointEvidence(projected.evidence);
  if (evidence === null || !agentEvidenceMatchesControllerCAS(evidence, cas)) {
    return null;
  }
  return {
    cas,
    conversationId: conversationId as string,
    attemptId: attemptId as string,
    expectedAttempt: projected.expectedAttempt as TurnAttemptV1,
    journal: projected.journal as PersistedAgentAttemptJournalV3 | null,
    journalRevision:
      projected.journalRevision === undefined
        ? undefined
        : projected.journalRevision as number,
    events: projected.events as PersistedSessionEventV3[],
    evidence,
    cleanup:
      projected.cleanup === undefined
        ? undefined
        : projected.cleanup as AgentTranscriptCleanupV1,
  };
}

type NormalizedAgentNextCallCheckpointInput = Omit<
  AgentNextCallCheckpointInput,
  'conversationId' | 'attemptId'
> & {
  readonly conversationId: string;
  readonly attemptId: string;
};

function normalizeAgentNextCallCheckpointInput(
  value: unknown,
): NormalizedAgentNextCallCheckpointInput | null {
  const projected = exactDataProjectionOptional(
    value,
    ['cas', 'expectedAttempt', 'journal'],
    ['conversationId', 'attemptId', 'journalRevision'],
  );
  const cas = projected === null ? null : normalizeAgentControllerCAS(projected.cas);
  if (
    projected === null ||
    cas === null ||
    projected.expectedAttempt === undefined ||
    !isAgentAttemptJournalV3(projected.journal) ||
    (projected.journalRevision !== undefined &&
      (typeof projected.journalRevision !== 'number' ||
        !Number.isSafeInteger(projected.journalRevision) ||
        Object.is(projected.journalRevision, -0) ||
        projected.journalRevision < 1))
  ) return null;
  const conversationId = projected.conversationId ?? cas.conversation_id;
  const attemptId = projected.attemptId ?? cas.attempt_id;
  if (
    typeof conversationId !== 'string' ||
    typeof attemptId !== 'string' ||
    conversationId !== cas.conversation_id ||
    attemptId !== cas.attempt_id
  ) return null;
  return {
    cas,
    conversationId,
    attemptId,
    expectedAttempt: projected.expectedAttempt as TurnAttemptV1,
    journal: projected.journal,
    ...(projected.journalRevision === undefined
      ? {}
      : { journalRevision: projected.journalRevision as number }),
  };
}

type NormalizedAgentFinalCheckpointInput = Omit<
  NormalizedAgentCheckpointInput,
  'journal' | 'evidence' | 'cleanup'
> & {
  readonly journal: PersistedAgentAttemptJournalV3;
  readonly evidence: AgentStoreTransitionEvidence;
  readonly assistantMessage: ChatMessage | null;
  readonly cleanup: AgentTranscriptCleanupV1;
};

function normalizeAgentFinalCheckpointInput(
  value: unknown,
): NormalizedAgentFinalCheckpointInput | null {
  const projected = exactDataProjectionOptional(
    value,
    [
      'cas',
      'expectedAttempt',
      'journal',
      'events',
      'evidence',
      'assistantMessage',
      'cleanup',
    ],
    ['conversationId', 'attemptId', 'journalRevision'],
  );
  if (projected === null) return null;
  const normalized = normalizeAgentCheckpointInput({
    cas: projected.cas,
    expectedAttempt: projected.expectedAttempt,
    journal: projected.journal,
    events: projected.events,
    evidence: projected.evidence,
    cleanup: projected.cleanup,
    ...(projected.conversationId === undefined
      ? {}
      : { conversationId: projected.conversationId }),
    ...(projected.attemptId === undefined
      ? {}
      : { attemptId: projected.attemptId }),
    ...(projected.journalRevision === undefined
      ? {}
      : { journalRevision: projected.journalRevision }),
  });
  if (
    normalized === null ||
    normalized.journal === null ||
    (normalized.journal.phase !== 'final_response' &&
      normalized.journal.phase !== 'failed' &&
      normalized.journal.phase !== 'cancelled') ||
    (normalized.evidence.kind !== 'complete_agent_round_v2' &&
      normalized.evidence.kind !== 'recover_agent_attempt' &&
      normalized.evidence.kind !== 'cancel_agent_attempt' &&
      normalized.evidence.kind !== 'execute_agent_tool') ||
    (projected.assistantMessage !== null &&
      (typeof projected.assistantMessage !== 'object' ||
        Array.isArray(projected.assistantMessage))) ||
    normalized.cleanup === undefined
  ) return null;
  return {
    ...normalized,
    journal: normalized.journal,
    evidence: normalized.evidence,
    assistantMessage: projected.assistantMessage as ChatMessage | null,
    cleanup: normalized.cleanup,
  };
}

function normalizeAgentExecutionInput(
  value: unknown,
  requireReceipt: boolean,
): NormalizedAgentCheckpointInput | null {
  const projected = exactDataProjectionOptional(
    value,
    ['cas', 'expectedAttempt', 'journal', 'callIndex', 'events'],
    [
      'conversationId',
      'attemptId',
      'journalRevision',
      'events',
      'receipt',
      'evidence',
    ],
  );
  if (
    projected === null ||
    typeof projected.callIndex !== 'number' ||
    !Number.isSafeInteger(projected.callIndex) ||
    Object.is(projected.callIndex, -0) ||
    projected.callIndex < 0
  ) return null;
  const callIndex = projected.callIndex as number;
  const journal = projected.journal;
  if (
    !isAgentAttemptJournalV3(journal) ||
    journal.call_index !== callIndex ||
    journal.phase !== (requireReceipt ? 'tool_result_pending' : 'execution_intent') ||
    journal.batch[callIndex] === undefined
  ) return null;
  if (requireReceipt) {
    if (!isAgentToolReceipt(projected.receipt)) return null;
    const journalReceipt = journal.batch[callIndex]?.receipt;
    if (
      journalReceipt === null ||
      journalReceipt.call_id !== projected.receipt.call_id ||
      journalReceipt.name !== projected.receipt.name ||
      journalReceipt.arguments_sha256 !== projected.receipt.arguments_sha256 ||
      journalReceipt.result_sha256 !== projected.receipt.result_sha256 ||
      journalReceipt.result_bytes !== projected.receipt.result_bytes ||
      journalReceipt.truncated !== projected.receipt.truncated ||
      journalReceipt.duration_ms !== projected.receipt.duration_ms ||
      journalReceipt.outcome !== projected.receipt.outcome ||
      journalReceipt.failure_code !== projected.receipt.failure_code ||
      journalReceipt.approval_reference !== projected.receipt.approval_reference
    ) return null;
  } else if (projected.receipt !== undefined) {
    return null;
  } else if (journal.batch[callIndex]?.idempotency_key === null) {
    return null;
  }
  return normalizeAgentCheckpointInput({
    conversationId: projected.conversationId,
    attemptId: projected.attemptId,
    cas: projected.cas,
    expectedAttempt: projected.expectedAttempt,
    journal: projected.journal,
    ...(projected.journalRevision === undefined
      ? {}
      : { journalRevision: projected.journalRevision }),
    events: projected.events,
    evidence: projected.evidence,
  });
}

function normalizeAgentControllerCAS(
  value: unknown,
): AgentControllerCASV1 | null {
  const projected = exactDataProjection(value, [
    'schema_version',
    'conversation_id',
    'task_id',
    'attempt_id',
    'expected_controller_generation',
    'expected_journal_revision',
    'expected_session_generation',
    'expected_session_sha256',
  ]);
  if (
    projected === null ||
    projected.schema_version !== 1 ||
    typeof projected.conversation_id !== 'string' ||
    typeof projected.task_id !== 'string' ||
    typeof projected.attempt_id !== 'string' ||
    typeof projected.expected_controller_generation !== 'number' ||
    typeof projected.expected_journal_revision !== 'number' ||
    typeof projected.expected_session_generation !== 'number' ||
    typeof projected.expected_session_sha256 !== 'string'
  ) return null;
  return projected as unknown as AgentControllerCASV1;
}

function normalizeAgentStoreEvidence(
  value: unknown,
): AgentStoreTransitionEvidence | null {
  const projected = exactDataProjection(value, [
    'kind',
    'operation_id',
    'request',
    'result',
  ]);
  if (projected === null || typeof projected.kind !== 'string') return null;
  const operations = new Set([
    'prepare_agent_attempt',
    'complete_agent_round_v2',
    'prepare_agent_tool_batch',
    'bind_agent_approval',
    'execute_agent_tool',
    'cancel_agent_attempt',
    'recover_agent_attempt',
  ]);
  if (!operations.has(projected.kind)) return null;
  const mapped = validateAgentStoreTransition({
    operation: projected.kind,
    request: projected.request,
    result: projected.result,
  });
  return mapped !== null && mapped.operation_id === projected.operation_id
    ? mapped
    : null;
}

function normalizeAgentCheckpointEvidence(
  value: unknown,
): AgentCheckpointEvidence | null {
  const preflight = validateAgentControllerPreflight(value);
  return preflight ?? normalizeAgentStoreEvidence(value);
}

function agentEvidenceMatchesControllerCAS(
  value: AgentCheckpointEvidence,
  cas: AgentControllerCASV1,
): boolean {
  if (isControllerPreflight(value)) {
    const base = value.base_cas;
    return (
      base.schema_version === cas.schema_version &&
      base.conversation_id === cas.conversation_id &&
      base.task_id === cas.task_id &&
      base.attempt_id === cas.attempt_id &&
      base.expected_controller_generation === cas.expected_controller_generation &&
      base.expected_journal_revision === cas.expected_journal_revision &&
      base.expected_session_generation === cas.expected_session_generation &&
      base.expected_session_sha256 === cas.expected_session_sha256 &&
      value.conversation_id === cas.conversation_id &&
      value.task_id === cas.task_id &&
      value.attempt_id === cas.attempt_id
    );
  }
  const request = value.request;
  const requestCas = request.controller_cas;
  const checkpoint = request.committed_checkpoint;
  const target = 'target' in request ? request.target : null;
  return (
    requestCas.schema_version === cas.schema_version &&
    requestCas.conversation_id === cas.conversation_id &&
    requestCas.task_id === cas.task_id &&
    requestCas.attempt_id === cas.attempt_id &&
    requestCas.expected_controller_generation ===
      cas.expected_controller_generation &&
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

function approvalEvidenceGrantsMatch(
  evidence: AgentCheckpointEvidence | undefined,
  grants: readonly AgentConversationGrantV2[],
  currentGrants: readonly AgentConversationGrantV2[],
): boolean {
  try {
    if (evidence === undefined) return false;
    const grant = isControllerPreflight(evidence)
      ? evidence.kind === 'decide_approval'
        ? evidence.grant
        : null
      : evidence.kind === 'bind_agent_approval'
        ? evidence.result.grant
        : null;
    if (
      !isControllerPreflight(evidence) &&
      evidence.kind !== 'bind_agent_approval'
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

function validSessionAuthority(value: unknown): value is SessionAuthority {
  try {
    if (
      typeof value !== 'object' ||
      value === null ||
      Array.isArray(value) ||
      Object.getPrototypeOf(value) !== Object.prototype ||
      Object.getOwnPropertySymbols(value).length !== 0
    ) return false;
    const names = Object.getOwnPropertyNames(value);
    if (
      names.length !== 2 ||
      !names.includes('generation') ||
      !names.includes('sessionSha256')
    ) return false;
    for (const name of names) {
      const descriptor = Object.getOwnPropertyDescriptor(value, name);
      if (
        descriptor === undefined ||
        !Object.prototype.hasOwnProperty.call(descriptor, 'value') ||
        descriptor.enumerable !== true
      ) return false;
    }
    const generation = (value as { generation?: unknown }).generation;
    const sessionSha256 = (value as { sessionSha256?: unknown }).sessionSha256;
    return (
      typeof generation === 'number' &&
      Number.isSafeInteger(generation) &&
      !Object.is(generation, -0) &&
      generation >= 1 &&
      generation < Number.MAX_SAFE_INTEGER &&
      typeof sessionSha256 === 'string' &&
      /^[0-9a-f]{64}$/u.test(sessionSha256)
    );
  } catch {
    return false;
  }
}

function nativeSessionCommitProofMatchesCandidate(
  value: unknown,
  candidateSha256: string,
  capturedAuthority: SessionAuthority | null,
): SessionAuthority | null {
  if (
    capturedAuthority === null ||
    capturedAuthority.generation >= Number.MAX_SAFE_INTEGER - 1
  ) return null;
  const result = exactDataProjection(value, [
    'schema_version',
    'status',
    'snapshot',
  ]);
  const snapshot =
    result !== null &&
    result.schema_version === 1 &&
    result.status === 'committed'
      ? exactDataProjection(result.snapshot, [
          'schema_version',
          'generation',
          'session_sha256',
        ])
      : exactDataProjection(value, [
          'schema_version',
          'generation',
          'session_sha256',
        ]);
  if (
    snapshot === null ||
    snapshot.schema_version !== 1 ||
    typeof snapshot.generation !== 'number' ||
    !Number.isSafeInteger(snapshot.generation) ||
    Object.is(snapshot.generation, -0) ||
    snapshot.generation < 1 ||
    snapshot.generation >= Number.MAX_SAFE_INTEGER ||
    snapshot.generation !== capturedAuthority.generation + 1 ||
    typeof snapshot.session_sha256 !== 'string' ||
    !/^[0-9a-f]{64}$/u.test(snapshot.session_sha256) ||
    snapshot.session_sha256 !== candidateSha256
  ) return null;
  return {
    generation: snapshot.generation,
    sessionSha256: snapshot.session_sha256,
  };
}

function sessionDigestForCandidate(value: ChatState): string | null {
  try {
    return sessionSnapshotSHA256(serializeChatState(value));
  } catch {
    return null;
  }
}

function latestSessionEventSeq(
  state: ChatState,
  attemptId: string,
): number {
  return (state.sessionEvents ?? [])
    .filter(event => event.attempt_id === attemptId)
    .reduce((latest, event) => Math.max(latest, event.seq), -1);
}

function preflightEventFor(
  state: ChatState,
  evidence: AgentControllerPreflightV1,
  expectedAttempt: TurnAttemptV1,
  at: string,
): PersistedSessionEventV3 | null {
  const existing = (state.sessionEvents ?? []).find(
    event => event.event_id === evidence.operation_id,
  );
  if (existing !== undefined) return existing;
  const seq = latestSessionEventSeq(state, expectedAttempt.attemptId) + 1;
  if (evidence.kind === 'begin_round') {
    return {
      schema_version: 2,
      event_id: evidence.operation_id,
      attempt_id: expectedAttempt.attemptId,
      seq,
      kind: 'round',
      round_index: evidence.round_index,
      call_id: null,
      status: 'running',
      safe_summary_key: null,
      arguments_sha256: null,
      result_sha256: null,
      approval_reference: null,
      failure_code: null,
      created_at: at,
    };
  }
  if (evidence.kind === 'decide_approval') {
    return {
      schema_version: 2,
      event_id: evidence.operation_id,
      attempt_id: expectedAttempt.attemptId,
      seq,
      kind: 'approval',
      round_index: evidence.round_index,
      call_id: evidence.call_id,
      status: 'approval',
      safe_summary_key: `agent.${evidence.name}`,
      arguments_sha256: evidence.arguments_sha256,
      result_sha256: null,
      approval_reference: evidence.operation_id,
      failure_code: null,
      created_at: at,
    };
  }
  if (evidence.kind === 'begin_execution') {
    return {
      schema_version: 2,
      event_id: evidence.operation_id,
      attempt_id: expectedAttempt.attemptId,
      seq,
      kind: 'tool_call',
      round_index: evidence.round_index,
      call_id: evidence.call_id,
      status: 'running',
      safe_summary_key: `agent.${evidence.name}`,
      arguments_sha256: evidence.arguments_sha256,
      result_sha256: null,
      approval_reference: null,
      failure_code: null,
      created_at: at,
    };
  }
  const target = evidence.target;
  const call =
    target.kind === 'tool'
      ? expectedAttempt.agent?.batch[target.call_index]
      : undefined;
  if (target.kind === 'tool' &&
    (call === undefined || call.call_id !== target.call_id ||
      call.arguments_sha256.length !== 64)) return null;
  const common = {
    schema_version: 2 as const,
    event_id: evidence.operation_id,
    attempt_id: expectedAttempt.attemptId,
    seq,
    kind: 'cancel' as const,
    status: 'cancelled' as const,
    safe_summary_key: null,
    result_sha256: null,
    approval_reference: evidence.operation_id,
    failure_code: evidence.cancel_token.reason_code,
    created_at: at,
  };
  if (target.kind === 'attempt') {
    return {
      ...common,
      round_index: null,
      call_id: null,
      arguments_sha256: null,
    };
  }
  if (target.kind === 'round') {
    return {
      ...common,
      round_index: target.round_index,
      call_id: null,
      arguments_sha256: null,
    };
  }
  return {
    ...common,
    round_index: target.round_index,
    call_id: target.call_id,
    arguments_sha256: call!.arguments_sha256,
  };
}

function eventsForAgentCheckpoint(
  state: ChatState,
  evidence: AgentCheckpointEvidence,
  expectedAttempt: TurnAttemptV1,
  events: readonly PersistedSessionEventV3[],
  at: string,
): PersistedSessionEventV3[] | null {
  const candidateEvents = [...events];
  if (!isControllerPreflight(evidence)) return candidateEvents;
  const preflightEvent = preflightEventFor(state, evidence, expectedAttempt, at);
  if (preflightEvent === null) return null;
  if (!candidateEvents.some(event => event.event_id === preflightEvent.event_id)) {
    candidateEvents.push(preflightEvent);
  }
  return candidateEvents;
}

function nativeAgentDiscardProofMatchesCleanup(
  value: unknown,
  cleanup: AgentTranscriptCleanupV1,
  taskId: string,
): boolean {
  const proof = exactDataProjection(value, [
    'schema_version',
    'status',
    'operation_id',
    'cleanup_id',
    'task_id',
    'conversation_id',
    'attempt_id',
    'transcript_ref',
    'transcript_sha256',
  ]);
  return (
    proof !== null &&
    proof.schema_version === 2 &&
    (proof.status === 'discarded' || proof.status === 'already_missing') &&
    typeof proof.operation_id === 'string' &&
    isCanonicalLifecycleId(proof.operation_id) &&
    proof.cleanup_id === cleanup.cleanup_id &&
    typeof proof.task_id === 'string' &&
    isCanonicalLifecycleId(proof.task_id) &&
    proof.task_id === taskId &&
    cleanup.task_id === taskId &&
    proof.conversation_id === cleanup.conversation_id &&
    proof.attempt_id === cleanup.attempt_id &&
    proof.transcript_ref === cleanup.transcript_ref &&
    typeof proof.transcript_sha256 === 'string' &&
    /^[0-9a-f]{64}$/u.test(proof.transcript_sha256) &&
    proof.transcript_sha256 === cleanup.transcript_sha256
  );
}

const workspaceBindingInputKeys = ['schemaVersion', 'owner', 'binding'] as const;
const workspaceBindingInputWireKeys = ['schema_version', 'owner', 'binding'] as const;
const workspaceBindingOwnerInputKeys = [
  'conversationId',
  'expectedConversation',
  'expectedProjectContext',
  'expectedDestructiveEpoch',
] as const;
const workspaceBindingOwnerWireKeys = [
  'conversation_id',
  'expected_conversation',
  'expected_project_context',
  'expected_destructive_epoch',
] as const;
const workspaceBindingInputResultKeys = [
  'schemaVersion',
  'workspaceId',
  'bindingRevision',
  'projectId',
] as const;
const workspaceBindingInputResultWireKeys = [
  'schema_version',
  'workspace_id',
  'binding_revision',
  'project_id',
] as const;

type NormalizedWorkspaceBindingInput = {
  readonly schemaVersion: 1;
  readonly owner: WorkspaceBindingOwnerV1;
  readonly binding: ConversationWorkspaceBindingV1 | null;
};

function normalizeWorkspaceBindingInput(
  input: unknown,
): NormalizedWorkspaceBindingInput | null {
  const camel = exactDataProjection(input, workspaceBindingInputKeys);
  const wire = camel === null
    ? exactDataProjection(input, workspaceBindingInputWireKeys)
    : null;
  const projected = camel ?? wire;
  if (projected === null) return null;
  const schemaVersion = Object.prototype.hasOwnProperty.call(
    projected,
    'schemaVersion',
  )
    ? projected.schemaVersion
    : projected.schema_version;
  if (schemaVersion !== 1) return null;
  const rawOwner = projected.owner;
  const ownerCamel = exactDataProjection(
    rawOwner,
    workspaceBindingOwnerInputKeys,
  );
  const ownerWire = ownerCamel === null
    ? exactDataProjection(rawOwner, workspaceBindingOwnerWireKeys)
    : null;
  const owner = ownerCamel ?? ownerWire;
  if (owner === null) return null;
  const conversationId = Object.prototype.hasOwnProperty.call(
    owner,
    'conversationId',
  )
    ? owner.conversationId
    : owner.conversation_id;
  const expectedConversation = Object.prototype.hasOwnProperty.call(
    owner,
    'expectedConversation',
  )
    ? owner.expectedConversation
    : owner.expected_conversation;
  const expectedProjectContext = Object.prototype.hasOwnProperty.call(
    owner,
    'expectedProjectContext',
  )
    ? owner.expectedProjectContext
    : owner.expected_project_context;
  const expectedDestructiveEpoch = Object.prototype.hasOwnProperty.call(
    owner,
    'expectedDestructiveEpoch',
  )
    ? owner.expectedDestructiveEpoch
    : owner.expected_destructive_epoch;
  if (
    typeof conversationId !== 'string' ||
    typeof expectedDestructiveEpoch !== 'number'
  ) {
    return null;
  }
  const rawBinding = projected.binding;
  let binding: ConversationWorkspaceBindingV1 | null = null;
  if (rawBinding !== null) {
    const bindingCamel = exactDataProjection(
      rawBinding,
      workspaceBindingInputResultKeys,
    );
    const bindingWire = bindingCamel === null
      ? exactDataProjection(rawBinding, workspaceBindingInputResultWireKeys)
      : null;
    const projectedBinding = bindingCamel ?? bindingWire;
    if (projectedBinding === null) return null;
    const schema = Object.prototype.hasOwnProperty.call(
      projectedBinding,
      'schemaVersion',
    )
      ? projectedBinding.schemaVersion
      : projectedBinding.schema_version;
    const workspaceId = Object.prototype.hasOwnProperty.call(
      projectedBinding,
      'workspaceId',
    )
      ? projectedBinding.workspaceId
      : projectedBinding.workspace_id;
    const bindingRevision = Object.prototype.hasOwnProperty.call(
      projectedBinding,
      'bindingRevision',
    )
      ? projectedBinding.bindingRevision
      : projectedBinding.binding_revision;
    const projectId = Object.prototype.hasOwnProperty.call(
      projectedBinding,
      'projectId',
    )
      ? projectedBinding.projectId
      : projectedBinding.project_id;
    if (
      schema !== 1 ||
      typeof workspaceId !== 'string' ||
      typeof bindingRevision !== 'number' ||
      (projectId !== null && typeof projectId !== 'string')
    ) {
      return null;
    }
    binding = {
      schemaVersion: 1,
      workspaceId: workspaceId as string,
      bindingRevision: bindingRevision as number,
      projectId: projectId as string | null,
    };
  }
  return {
    schemaVersion: 1,
    owner: {
      conversationId,
      expectedConversation: expectedConversation as Conversation,
      expectedProjectContext: expectedProjectContext as Conversation['projectContext'],
      expectedDestructiveEpoch,
    },
    binding,
  };
}

function normalizeInitialChatState(value: ChatState): ChatState {
  const workspaceAuthorityOutbox = value.workspaceAuthorityOutbox ?? [];
  const cleanupOutbox = value.agentTranscriptCleanupOutbox ?? [];
  const sessionEvents = value.sessionEvents ?? [];
  const preferences = value.preferences ?? createChatStoreDefaultPreferences();
  let changed =
    value.workspaceAuthorityOutbox === undefined ||
    value.agentTranscriptCleanupOutbox === undefined ||
    value.sessionEvents === undefined ||
    value.preferences === undefined;
  const conversations: Record<string, Conversation> = {};
  Object.entries(value.conversations).forEach(([id, conversation]) => {
    const workspaceBinding = conversation.workspaceBinding ?? null;
    const workspaceBootstrapState =
      conversation.workspaceBootstrapState ??
      (conversation.workspaceId === null ? 'none' : 'pending_registry_resolution');
    const agentGrants = conversation.agentGrants ?? conversation.agent_grants ?? [];
    let attemptsChanged = false;
    const attempts = conversation.attempts.map(attempt => {
      if (
        attempt.agent !== undefined &&
        attempt.agent !== null &&
        !isAgentAttemptJournalV3(attempt.agent)
      ) {
        // A caller must hydrate the exact persisted root before constructing a
        // Store. Never promote a V2 journal by casting or field copying.
        throw new Error('schema-2 Agent journals require bootstrap hydration');
      }
      if (
        attempt.agent !== undefined &&
        attempt.journalRevision !== undefined
      ) {
        return attempt;
      }
      attemptsChanged = true;
      changed = true;
      return {
        ...attempt,
        journalRevision: attempt.journalRevision ?? 0,
        agent: attempt.agent ?? null,
      };
    });
    if (
      conversation.workspaceBinding === undefined ||
      conversation.workspaceBootstrapState === undefined ||
      conversation.agentGrants === undefined ||
      attemptsChanged
    ) {
      changed = true;
      conversations[id] = {
        ...conversation,
        workspaceBinding,
        workspaceBootstrapState,
        agentGrants,
        attempts,
      };
    } else {
      conversations[id] = conversation;
    }
  });
  if (!changed) return value;
  const normalized: ChatState = {
    ...value,
    conversations,
    workspaceAuthorityOutbox,
    agentTranscriptCleanupOutbox: cleanupOutbox,
    sessionEvents,
    preferences,
  };
  if (value.migrationDiagnostics !== undefined) {
    Object.defineProperty(normalized, 'migrationDiagnostics', {
      value: value.migrationDiagnostics,
      enumerable: false,
      writable: false,
      configurable: false,
    });
  }
  return normalized;
}

function createChatStoreDefaultPreferences(): NonNullable<ChatState['preferences']> {
  const preferences = createEmptyChatState().preferences;
  if (preferences === undefined) {
    throw new Error('chat defaults must include schema-1 preferences');
  }
  return preferences;
}

function frozenProjectContext(
  conversation: Conversation,
  sendWithoutProjectContext: boolean,
):
  | Pick<
      TurnAttemptV1,
      | 'contextDisposition'
      | 'contextProjectId'
      | 'workspaceId'
      | 'workspaceBindingRevision'
      | 'projectContext'
    >
  | undefined {
  if (
    typeof conversation.workspaceBootstrapState === 'string' &&
    conversation.workspaceBootstrapState.startsWith('blocked_')
  ) {
    return undefined;
  }
  const workspaceBinding = conversation.workspaceBinding ?? null;
  if (
    workspaceBinding !== null &&
    (conversation.workspaceId !== workspaceBinding.workspaceId ||
      conversation.projectId !== workspaceBinding.projectId)
  ) {
    return undefined;
  }
  const workspace = {
    workspaceId: workspaceBinding?.workspaceId ?? null,
    workspaceBindingRevision: workspaceBinding?.bindingRevision ?? null,
  } as const;
  if (conversation.projectId === null) {
    return {
      contextDisposition: 'unbound',
      contextProjectId: null,
      ...workspace,
      projectContext: null,
    };
  }
  if (sendWithoutProjectContext) {
    return {
      contextDisposition: 'explicit_without_context',
      contextProjectId: conversation.projectId,
      ...workspace,
      projectContext: null,
    };
  }
  const context = conversation.projectContext;
  if (
    context === null ||
    conversation.runtimeContextId === null ||
    !isProjectContextSendable(context) ||
    context.snapshot === null ||
    context.consent === null ||
    !isCanonicalLifecycleId(conversation.runtimeContextId) ||
    !isCanonicalLifecycleId(context.snapshot.snapshot_id) ||
    !isCanonicalLifecycleId(context.consent.consent_receipt_id)
  ) {
    return undefined;
  }
  return {
      contextDisposition: 'verified',
      contextProjectId: conversation.projectId,
      ...workspace,
      projectContext: {
      schemaVersion: 1,
      runtimeContextId: conversation.runtimeContextId,
      projectId: conversation.projectId,
      snapshotId: context.snapshot.snapshot_id,
      snapshotSha256: context.snapshot.snapshot_sha256,
      sourceFingerprint: context.snapshot.source_fingerprint,
      contextBytes: context.snapshot.context_bytes,
      consentReceiptId: context.consent.consent_receipt_id,
      provider: providerForModel(context.snapshot.model),
      policy: 'chat-read-v1',
      policyVersion: 'chat-read-v1.0.0',
    },
  };
}

export function createChatStore(options: ChatStoreOptions = {}): ChatStore {
  const now = options.now ?? (() => new Date());
  const createId = options.createId ?? defaultCreateId;
  const createLifecycleId =
    options.createLifecycleId ?? defaultCreateLifecycleId;
  let state = normalizeInitialChatState(
    options.initialState ?? createEmptyChatState(),
  );
  let sessionAuthority: SessionAuthority | null = validSessionAuthority(
    options.sessionAuthority,
  )
    ? { ...options.sessionAuthority }
    : null;
  const readSessionAuthority = (): SessionAuthority | null => {
    try {
      const live = options.getSessionAuthority?.();
      if (live !== undefined) {
        return validSessionAuthority(live) ? { ...live } : null;
      }
    } catch {
      return null;
    }
    return sessionAuthority === null ? null : { ...sessionAuthority };
  };
  const controllerCASMatchesCurrent = (
    value: unknown,
    expectedAttempt: TurnAttemptV1,
  ): AgentControllerCASV1 | null => {
    const cas = normalizeAgentControllerCAS(value);
    if (cas === null) return null;
    const conversation = state.conversations[cas.conversation_id];
    const currentAttempt = conversation?.attempts.find(
      attempt => attempt.attemptId === cas.attempt_id,
    );
    const authority = readSessionAuthority();
    const currentGeneration = currentAttempt?.agent?.controller_generation ?? 0;
    if (
      conversation === undefined ||
      currentAttempt === undefined ||
      expectedAttempt !== currentAttempt ||
      cas.schema_version !== 1 ||
      !isCanonicalLifecycleId(cas.task_id) ||
      !isCanonicalLifecycleId(cas.attempt_id) ||
      cas.task_id !== currentAttempt.turnId ||
      cas.expected_controller_generation !== currentGeneration ||
      !Number.isSafeInteger(cas.expected_controller_generation) ||
      Object.is(cas.expected_controller_generation, -0) ||
      cas.expected_controller_generation >= Number.MAX_SAFE_INTEGER ||
      !Number.isSafeInteger(cas.expected_journal_revision) ||
      Object.is(cas.expected_journal_revision, -0) ||
      cas.expected_journal_revision >= Number.MAX_SAFE_INTEGER ||
      cas.expected_journal_revision !== (currentAttempt.journalRevision ?? 0) ||
      !Number.isSafeInteger(cas.expected_session_generation) ||
      Object.is(cas.expected_session_generation, -0) ||
      cas.expected_session_generation < 1 ||
      cas.expected_session_generation >= Number.MAX_SAFE_INTEGER ||
      !/^[0-9a-f]{64}$/u.test(cas.expected_session_sha256) ||
      authority === null ||
      authority.generation !== cas.expected_session_generation ||
      authority.sessionSha256 !== cas.expected_session_sha256
    ) return null;
    return cas;
  };
  const listeners = new Set<ChatStoreListener>();
  let notificationDepth = 0;

  const notifyListeners = () => {
    notificationDepth += 1;
    try {
      listeners.forEach(listener => {
        try {
          listener(state);
        } catch {
          // A UI subscriber must never strand an already-applied state mutation.
        }
      });
    } finally {
      notificationDepth -= 1;
    }
  };

  type AppliedAction = {
    readonly before: ChatState;
    readonly next: ChatState;
    readonly changed: boolean;
  };

  const applyAction = (action: ChatAction): AppliedAction => {
    const before = state;
    const next = chatReducer(before, action);
    if (next !== before) {
      state = next;
      notifyListeners();
    }
    return { before, next, changed: next !== before };
  };

  const dispatch = (action: ChatAction): ChatState => {
    if (
      action.type === 'attempt/agent-checkpoint' ||
      action.type === 'attempt/agent-advance-call' ||
      action.type === 'attempt/agent-final-checkpoint' ||
      action.type === 'agent/approval-checkpoint' ||
      action.type === 'conversation/agent-grants' ||
      action.type === 'agent/cleanup-enqueue' ||
      action.type === 'agent/abandon-unresolved' ||
      action.type === 'agent/cleanup-ack' ||
      action.type === 'conversation/delete-with-agent-cleanup'
    ) {
      // Agent mutations are exposed only through the CAS-bound store methods
      // below. A raw ChatAction cannot carry native session/discard evidence
      // and therefore must never become a durable mutation bypass.
      return state;
    }
    if (
      notificationDepth > 0 &&
      (action.type === 'project-context-destructive/begin' ||
        action.type === 'project-context-destructive/tombstone' ||
        action.type === 'project-context-destructive/cleanup-complete' ||
        action.type === 'project-context-destructive/finalize')
    ) {
      return state;
    }
    applyAction(action);
    return state;
  };

  const preparedTransaction = (
    applied: AppliedAction,
    prepared: PreparedTurnAttempt,
  ): PreparedTurnTransaction | null => {
    if (!applied.changed) return null;
    let settled = false;
    return {
      ...prepared,
      commit: () => {
        if (settled) return false;
        settled = true;
        return true;
      },
      rollback: () => {
        if (settled) return false;
        settled = true;
        if (state !== applied.next) return false;
        state = applied.before;
        notifyListeners();
        return true;
      },
    };
  };

  const agentCheckpointTransaction = (
    applied: AppliedAction,
    conversationId: string,
    attemptId: string,
    capturedAuthority: SessionAuthority | null,
  ): AgentCheckpointTransaction | null => {
    if (!applied.changed) return null;
    const beforeConversation = applied.before.conversations[conversationId];
    const nextConversation = applied.next.conversations[conversationId];
    if (beforeConversation === undefined || nextConversation === undefined) {
      return null;
    }
    const beforeAttempt = beforeConversation.attempts.find(
      attempt => attempt.attemptId === attemptId,
    );
    const nextAttempt = nextConversation.attempts.find(
      attempt => attempt.attemptId === attemptId,
    );
    if (beforeAttempt === undefined || nextAttempt === undefined) return null;
    const journalRevision = nextAttempt.journalRevision ?? 0;
    const beforeOutbox = applied.before.agentTranscriptCleanupOutbox ?? [];
    const nextOutbox = applied.next.agentTranscriptCleanupOutbox ?? [];
    const beforeEvents = applied.before.sessionEvents ?? [];
    const nextEvents = applied.next.sessionEvents ?? [];
    const messagesChanged =
      beforeConversation.messages !== nextConversation.messages;
    const outboxChanged = beforeOutbox !== nextOutbox;
    const eventsChanged = beforeEvents !== nextEvents;
    const grantsChanged =
      beforeConversation.agentGrants !== nextConversation.agentGrants ||
      beforeConversation.agent_grants !== nextConversation.agent_grants;
    const nextSessionSha256 = sessionDigestForCandidate(applied.next);
    if (nextSessionSha256 === null) {
      // A reducer candidate that cannot cross the schema-9 serializer is not
      // a valid transaction. Restore only while the reducer result still owns
      // the root, then report the rejected mutation.
      if (state === applied.next) {
        state = applied.before;
        notifyListeners();
      }
      return null;
    }
    let settled = false;
    const nextStillOwned = () =>
      state.conversations[conversationId] === nextConversation &&
      state.conversations[conversationId]?.attempts.find(
        attempt => attempt.attemptId === attemptId,
      ) === nextAttempt;
    const targetStillOwned = () => {
      const conversation = state.conversations[conversationId];
      return (
        conversation !== undefined &&
        conversation.attempts.find(attempt => attempt.attemptId === attemptId) ===
          nextAttempt &&
        (!messagesChanged || conversation.messages === nextConversation.messages) &&
        (!outboxChanged || state.agentTranscriptCleanupOutbox === nextOutbox) &&
        (!eventsChanged || state.sessionEvents === nextEvents)
      );
    };
    return {
      conversationId,
      attemptId,
      journalRevision,
      commit: proof => {
        if (settled || !nextStillOwned() || nextSessionSha256 === null) {
          if (!nextStillOwned()) settled = true;
          return false;
        }
        const committedAuthority =
          nativeSessionCommitProofMatchesCandidate(
            proof,
            nextSessionSha256,
            capturedAuthority,
          );
        if (committedAuthority === null) return false;
        const liveAuthority = readSessionAuthority();
        if (
          options.getSessionAuthority !== undefined &&
          (liveAuthority === null ||
            liveAuthority.generation !== committedAuthority.generation ||
            liveAuthority.sessionSha256 !== committedAuthority.sessionSha256)
        ) return false;
        settled = true;
        // This is a direct copy of the native committed ref.  In particular,
        // never synthesize `generation + 1` in JS.
        sessionAuthority = committedAuthority;
        return true;
      },
      rollback: () => {
        if (settled) return false;
        settled = true;
        if (!targetStillOwned()) return false;
        const currentConversation = state.conversations[conversationId];
        if (currentConversation === undefined) return false;
        const currentAttemptIndex = currentConversation.attempts.findIndex(
          attempt => attempt.attemptId === attemptId,
        );
        if (currentAttemptIndex < 0) return false;
        const attempts = [...currentConversation.attempts];
        attempts[currentAttemptIndex] = beforeAttempt;
        const ownsNextGrants =
          !grantsChanged ||
          (currentConversation.agentGrants === nextConversation.agentGrants &&
            currentConversation.agent_grants === nextConversation.agent_grants);
        const restoredConversation: Conversation = {
          ...currentConversation,
          attempts,
          ...(messagesChanged
            ? { messages: beforeConversation.messages }
            : {}),
          ...(ownsNextGrants && grantsChanged
            ? {
                agentGrants: beforeConversation.agentGrants,
                ...(beforeConversation.agent_grants === undefined
                  ? {}
                  : { agent_grants: beforeConversation.agent_grants }),
              }
            : {}),
          ...(currentConversation.updatedAt === nextConversation.updatedAt
            ? { updatedAt: beforeConversation.updatedAt }
            : {}),
        };
        const conversations = {
          ...state.conversations,
          [conversationId]: restoredConversation,
        };
        state = {
          ...state,
          conversations,
          conversationOrder: orderConversationIds(conversations),
          agentTranscriptCleanupOutbox:
            outboxChanged
              ? beforeOutbox
              : state.agentTranscriptCleanupOutbox,
          sessionEvents:
            eventsChanged ? beforeEvents : state.sessionEvents,
        };
        notifyListeners();
        return true;
      },
    };
  };

  /** One validated checkpoint transition applied to the live state (no transaction yet). */
  const applyNormalizedCheckpoint = (
    normalized: NormalizedAgentCheckpointInput,
    allowedOperations?: readonly (
      | AgentStoreOperation
      | AgentControllerPreflightV1['kind']
    )[],
  ): AppliedAction | null => {
    if (
      allowedOperations !== undefined &&
      !allowedOperations.includes(normalized.evidence.kind)
    ) return null;
    if (
      controllerCASMatchesCurrent(normalized.cas, normalized.expectedAttempt) ===
      null
    ) return null;
    if (
      isControllerPreflight(normalized.evidence) &&
      normalized.evidence.kind === 'begin_round' &&
      normalized.expectedAttempt.agent?.phase === 'ready_for_round' &&
      normalized.expectedAttempt.agent.round_lineage === null
    ) {
      const conversation = state.conversations[normalized.conversationId];
      const history =
        conversation === undefined
          ? null
          : projectAgentVisibleHistory(
              conversation,
              normalized.expectedAttempt,
            );
      if (
        history === null ||
        history.digest !== normalized.evidence.visible_history_sha256 ||
        history.count !== normalized.evidence.visible_message_count
      ) return null;
    }
    const candidateEvents = eventsForAgentCheckpoint(
      state,
      normalized.evidence,
      normalized.expectedAttempt,
      normalized.events,
      canonicalNow(now),
    );
    if (candidateEvents === null) return null;
    return applyAction({
      type: 'attempt/agent-checkpoint',
      payload: {
        cas: normalized.cas,
        conversationId: normalized.conversationId,
        attemptId: normalized.attemptId,
        expectedAttempt: normalized.expectedAttempt,
        journal: normalized.journal,
        events: candidateEvents,
        ...(normalized.journalRevision === undefined
          ? {}
          : { journalRevision: normalized.journalRevision }),
        evidence: normalized.evidence,
        ...(normalized.cleanup === undefined
          ? {}
          : { cleanup: normalized.cleanup }),
        at: canonicalNow(now),
      },
    });
  };

  const applyAgentControllerCheckpoint = (
    input: unknown,
    allowedOperations?: readonly (
      | AgentStoreOperation
      | AgentControllerPreflightV1['kind']
    )[],
  ): AgentCheckpointTransaction | null => {
    if (notificationDepth > 0) return null;
    const capturedAuthority = readSessionAuthority();
    const normalized = normalizeAgentCheckpointInput(input);
    if (normalized === null) return null;
    const applied = applyNormalizedCheckpoint(normalized, allowedOperations);
    if (applied === null) return null;
    return agentCheckpointTransaction(
      applied,
      normalized.conversationId,
      normalized.attemptId,
      capturedAuthority,
    );
  };

  const scopedProjectContextTransaction = (
    applied: AppliedAction,
    conversationId: string,
  ): ScopedProjectContextTransaction | null => {
    const beforeConversation = applied.before.conversations[conversationId];
    const nextConversation = applied.next.conversations[conversationId];
    if (
      !applied.changed ||
      beforeConversation === undefined ||
      nextConversation === undefined ||
      beforeConversation === nextConversation
    ) {
      return null;
    }
    let settled = false;
    return {
      conversationId,
      previousSnapshotId:
        beforeConversation.projectContext?.snapshot?.snapshot_id ?? null,
      nextSnapshotId:
        nextConversation.projectContext?.snapshot?.snapshot_id ?? null,
      commit: () => {
        if (settled) return false;
        settled = true;
        return state.conversations[conversationId] === nextConversation;
      },
      rollback: () => {
        if (settled) return false;
        settled = true;
        if (state.conversations[conversationId] !== nextConversation) {
          return false;
        }
        const conversations = {
          ...state.conversations,
          [conversationId]: beforeConversation,
        };
        state = {
          ...state,
          conversations,
          conversationOrder: orderConversationIds(conversations),
        };
        notifyListeners();
        return true;
      },
    };
  };

  const workspaceBindingTransaction = (
    applied: AppliedAction,
    conversationId: string,
  ): OneShotChatTransaction | null => {
    const beforeConversation = applied.before.conversations[conversationId];
    const nextConversation = applied.next.conversations[conversationId];
    if (
      !applied.changed ||
      beforeConversation === undefined ||
      nextConversation === undefined ||
      beforeConversation === nextConversation
    ) {
      return null;
    }
    let settled = false;
    const nextStillOwned = () =>
      state.conversations[conversationId] === nextConversation;
    return {
      commit: () => {
        if (settled) return false;
        settled = true;
        return nextStillOwned();
      },
      rollback: () => {
        if (settled) return false;
        settled = true;
        if (!nextStillOwned()) return false;
        const conversations = {
          ...state.conversations,
          [conversationId]: beforeConversation,
        };
        state = {
          ...state,
          conversations,
          conversationOrder: orderConversationIds(conversations),
        };
        notifyListeners();
        return true;
      },
    };
  };

  const workspaceAuthorityTransaction = (
    applied: AppliedAction,
    entry: WorkspaceAuthorityOutboxV1,
    conversationIds: readonly string[],
  ): WorkspaceAuthorityMutationTransaction | null => {
    if (!applied.changed) return null;
    const nextStillOwned = () =>
      conversationIds.every(
        conversationId =>
          state.conversations[conversationId] ===
          applied.next.conversations[conversationId],
      ) &&
      state.workspaceAuthorityOutbox === applied.next.workspaceAuthorityOutbox;
    let settled = false;
    return {
      operationId: entry.operationId,
      workspaceId: entry.workspaceId,
      bindingRevision: entry.bindingRevision,
      action: entry.action,
      outboxEntry: entry,
      commit: () => {
        if (settled) return false;
        settled = true;
        return nextStillOwned();
      },
      rollback: () => {
        if (settled) return false;
        settled = true;
        if (!nextStillOwned()) return false;
        const conversations = { ...state.conversations };
        conversationIds.forEach(conversationId => {
          const before = applied.before.conversations[conversationId];
          if (before === undefined) delete conversations[conversationId];
          else conversations[conversationId] = before;
        });
        state = {
          ...state,
          conversations,
          conversationOrder: orderConversationIds(conversations),
          workspaceAuthorityOutbox: applied.before.workspaceAuthorityOutbox ?? [],
        };
        notifyListeners();
        return true;
      },
    };
  };

  const destructiveTransaction = (
    applied: AppliedAction,
    conversationId: string,
  ): ProjectContextDestructiveTransaction | null => {
    if (!applied.changed) return null;
    const beforeTransition =
      applied.before.projectContextDestructiveTransition;
    const nextTransition = applied.next.projectContextDestructiveTransition;
    const lifecycleId =
      nextTransition?.lifecycleId ?? beforeTransition?.lifecycleId;
    const epoch = nextTransition?.epoch ?? beforeTransition?.epoch;
    if (lifecycleId === undefined || epoch === undefined) return null;
    const beforeConversation = applied.before.conversations[conversationId];
    const nextConversation = applied.next.conversations[conversationId];
    const selectionChanged =
      applied.before.selectedConversationId !==
      applied.next.selectedConversationId;
    let settled = false;
    const nextStillOwned = () =>
      state.projectContextDestructiveEpoch ===
        applied.next.projectContextDestructiveEpoch &&
      state.projectContextDestructiveTransition === nextTransition &&
      state.conversations[conversationId] === nextConversation;
    return {
      lifecycleId,
      epoch,
      commit: () => {
        if (settled) return false;
        settled = true;
        return nextStillOwned();
      },
      rollback: () => {
        if (settled) return false;
        settled = true;
        if (!nextStillOwned()) return false;
        const conversations = { ...state.conversations };
        if (beforeConversation === undefined) {
          delete conversations[conversationId];
        } else {
          conversations[conversationId] = beforeConversation;
        }
        state = {
          ...state,
          projectContextDestructiveEpoch:
            applied.before.projectContextDestructiveEpoch,
          projectContextDestructiveTransition: beforeTransition,
          conversations,
          conversationOrder: orderConversationIds(conversations),
          selectedConversationId:
            selectionChanged &&
            state.selectedConversationId ===
              applied.next.selectedConversationId
              ? applied.before.selectedConversationId
              : state.selectedConversationId,
        };
        notifyListeners();
        return true;
      },
    };
  };

  const snapshotFreeProjectTransaction = (
    applied: AppliedAction,
    conversationId: string,
    action: SnapshotFreeProjectMutationInput['action'],
    targetProjectId: string | null,
  ): SnapshotFreeProjectMutationTransaction | null => {
    if (!applied.changed) return null;
    const beforeConversation = applied.before.conversations[conversationId];
    const nextConversation = applied.next.conversations[conversationId];
    if (beforeConversation === undefined) return null;
    const selectionChanged =
      applied.before.selectedConversationId !==
      applied.next.selectedConversationId;
    let settled = false;
    const nextStillOwned = () =>
      state.conversations[conversationId] === nextConversation;
    return {
      conversationId,
      action,
      targetProjectId,
      commit: () => {
        if (settled) return false;
        settled = true;
        return nextStillOwned();
      },
      rollback: () => {
        if (settled) return false;
        settled = true;
        if (!nextStillOwned()) return false;
        const conversations = {
          ...state.conversations,
          [conversationId]: beforeConversation,
        };
        state = {
          ...state,
          conversations,
          conversationOrder: orderConversationIds(conversations),
          selectedConversationId:
            selectionChanged &&
            state.selectedConversationId ===
              applied.next.selectedConversationId
              ? applied.before.selectedConversationId
              : state.selectedConversationId,
        };
        notifyListeners();
        return true;
      },
    };
  };

  const appendMessage = (
    role: 'user' | 'assistant',
    conversationId: string,
    text: string,
    appendOptions: AppendMessageOptions = {},
  ): string => {
    const id = createId('message');
    dispatch({
      type: 'message/append',
      payload: {
        conversationId,
        message: {
          id,
          role,
          text,
          createdAt: canonicalNow(now),
          attachments: appendOptions.attachments ?? [],
          ...(appendOptions.metadata === undefined
            ? {}
            : { metadata: appendOptions.metadata }),
        },
      },
    });
    return id;
  };

  const cleanupAcknowledgementTransaction = (
    cleanupId: string,
    expectedCleanup: AgentTranscriptCleanupV1,
  ): AgentCleanupAcknowledgementTransaction | null => {
    if (notificationDepth > 0) return null;
    const capturedAuthority = readSessionAuthority();
    const before = state;
    const current = (before.agentTranscriptCleanupOutbox ?? []).find(
      entry => entry.cleanup_id === cleanupId,
    );
    if (
      current === undefined ||
      expectedCleanup !== current
    ) return null;
    const locatedTaskId = Object.values(before.conversations)
      .flatMap(conversation => conversation.attempts)
      .find(attempt => attempt.attemptId === current.attempt_id)?.turnId;
    if (locatedTaskId !== undefined && locatedTaskId !== current.task_id) return null;
    const taskId = current.task_id;
    const beforeOutbox = before.agentTranscriptCleanupOutbox ?? [];
    const nextOutbox = beforeOutbox.filter(
      entry => entry.cleanup_id !== cleanupId,
    );
    const nextState = { ...before, agentTranscriptCleanupOutbox: nextOutbox };
    const nextSessionSha256 = sessionDigestForCandidate(nextState);
    if (nextSessionSha256 === null) return null;
    state = nextState;
    notifyListeners();
    let settled = false;
    return {
      commit: (proof, discardProof) => {
        if (settled || state.agentTranscriptCleanupOutbox !== nextOutbox) {
          if (state.agentTranscriptCleanupOutbox !== nextOutbox) settled = true;
          return false;
        }
        const committedAuthority =
          nativeSessionCommitProofMatchesCandidate(
            proof,
            nextSessionSha256,
            capturedAuthority,
        );
        if (committedAuthority === null) return false;
        if (!nativeAgentDiscardProofMatchesCleanup(discardProof, current, taskId)) {
          return false;
        }
        const liveAuthority = readSessionAuthority();
        if (
          options.getSessionAuthority !== undefined &&
          (liveAuthority === null ||
            liveAuthority.generation !== committedAuthority.generation ||
            liveAuthority.sessionSha256 !== committedAuthority.sessionSha256)
        ) return false;
        settled = true;
        sessionAuthority = committedAuthority;
        return true;
      },
      rollback: () => {
        if (settled) return false;
        settled = true;
        if (state.agentTranscriptCleanupOutbox !== nextOutbox) return false;
        state = { ...state, agentTranscriptCleanupOutbox: beforeOutbox };
        notifyListeners();
        return true;
      },
    };
  };

  const cleanupEnqueueTransaction = (
    applied: AppliedAction,
    input: AgentCleanupInput,
    capturedAuthority: SessionAuthority | null,
  ): AgentCheckpointTransaction | null => {
    if (!applied.changed) return null;
    const nextSessionSha256 = sessionDigestForCandidate(applied.next);
    if (nextSessionSha256 === null) {
      if (state === applied.next) {
        state = applied.before;
        notifyListeners();
      }
      return null;
    }
    const beforeOutbox = applied.before.agentTranscriptCleanupOutbox ?? [];
    const nextOutbox = applied.next.agentTranscriptCleanupOutbox ?? [];
    const beforeConversation = applied.before.conversations[input.conversationId];
    const nextConversation = applied.next.conversations[input.conversationId];
    const nextAttempt = nextConversation?.attempts.find(
      attempt => attempt.attemptId === input.attemptId,
    );
    let settled = false;
    const nextStillOwned = () =>
      state.agentTranscriptCleanupOutbox === nextOutbox;
    const targetStillOwned = () => {
      if (beforeConversation === undefined) {
        return state.conversations[input.conversationId] === undefined;
      }
      return (
        state.conversations[input.conversationId]?.attempts.find(
          attempt => attempt.attemptId === input.attemptId,
        ) === nextAttempt
      );
    };
    return {
      conversationId: input.conversationId,
      attemptId: input.attemptId,
      journalRevision:
        nextAttempt?.journalRevision ?? input.expectedAttempt.journalRevision ?? 0,
      commit: proof => {
        if (settled || !nextStillOwned()) {
          if (!nextStillOwned()) settled = true;
          return false;
        }
        const committedAuthority =
          nativeSessionCommitProofMatchesCandidate(
            proof,
            nextSessionSha256,
            capturedAuthority,
          );
        if (committedAuthority === null) return false;
        const liveAuthority = readSessionAuthority();
        if (
          options.getSessionAuthority !== undefined &&
          (liveAuthority === null ||
            liveAuthority.generation !== committedAuthority.generation ||
            liveAuthority.sessionSha256 !== committedAuthority.sessionSha256)
        ) return false;
        settled = true;
        sessionAuthority = committedAuthority;
        return true;
      },
      rollback: () => {
        if (settled) return false;
        settled = true;
        if (!targetStillOwned()) return false;
        state = { ...state, agentTranscriptCleanupOutbox: beforeOutbox };
        notifyListeners();
        return true;
      },
    };
  };

  const deleteConversationWithAgentCleanupTransaction = (
    input: AgentConversationDeleteWithCleanupInput,
  ): AgentSessionTransaction | null => {
    if (notificationDepth > 0) return null;
    const capturedAuthority = readSessionAuthority();
    const applied = applyAction({
      type: 'conversation/delete-with-agent-cleanup',
      payload: {
        conversationId: input.conversationId,
        expectedConversation: input.expectedConversation,
        cleanup: input.cleanup,
      },
    });
    if (!applied.changed) return null;
    const beforeConversation = applied.before.conversations[input.conversationId];
    const nextConversation = applied.next.conversations[input.conversationId];
    if (beforeConversation === undefined || nextConversation !== undefined) {
      return null;
    }
    const beforeOutbox = applied.before.agentTranscriptCleanupOutbox ?? [];
    const nextOutbox = applied.next.agentTranscriptCleanupOutbox ?? [];
    const beforeEvents = applied.before.sessionEvents;
    const nextEvents = applied.next.sessionEvents;
    const nextSessionSha256 = sessionDigestForCandidate(applied.next);
    if (nextSessionSha256 === null) {
      if (state === applied.next) {
        state = applied.before;
        notifyListeners();
      }
      return null;
    }
    const selectedBefore = applied.before.selectedConversationId;
    const selectedAfter = applied.next.selectedConversationId;
    let settled = false;
    const nextStillOwned = () =>
      state.conversations[input.conversationId] === undefined &&
      state.agentTranscriptCleanupOutbox === nextOutbox &&
      state.sessionEvents === nextEvents;
    return {
      commit: proof => {
        if (settled || !nextStillOwned()) {
          if (!nextStillOwned()) settled = true;
          return false;
        }
        const committedAuthority =
          nativeSessionCommitProofMatchesCandidate(
            proof,
            nextSessionSha256,
            capturedAuthority,
          );
        if (committedAuthority === null) return false;
        const liveAuthority = readSessionAuthority();
        if (
          options.getSessionAuthority !== undefined &&
          (liveAuthority === null ||
            liveAuthority.generation !== committedAuthority.generation ||
            liveAuthority.sessionSha256 !== committedAuthority.sessionSha256)
        ) return false;
        settled = true;
        sessionAuthority = committedAuthority;
        return true;
      },
      rollback: () => {
        if (settled) return false;
        settled = true;
        if (!nextStillOwned()) return false;
        const conversations = {
          ...state.conversations,
          [input.conversationId]: beforeConversation,
        };
        state = {
          ...state,
          conversations,
          conversationOrder: orderConversationIds(conversations),
          selectedConversationId:
            state.selectedConversationId === selectedAfter
              ? selectedBefore
              : state.selectedConversationId,
          agentTranscriptCleanupOutbox: beforeOutbox,
          ...(state.sessionEvents === nextEvents && beforeEvents !== undefined
            ? { sessionEvents: beforeEvents }
            : {}),
        };
        notifyListeners();
        return true;
      },
    };
  };

  return {
    getState: () => state,
    dispatch,
    subscribe: listener => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    createConversation: (createOptions = {}) => {
      const id = createId('conversation');
      dispatch({
        type: 'conversation/create',
        payload: {
          id,
          at: canonicalNow(now),
          ...createOptions,
        },
      });
      return id;
    },
    renameConversation: (id, title) => {
      dispatch({
        type: 'conversation/rename',
        payload: { id, title, at: canonicalNow(now) },
      });
    },
    autoTitleConversation: (id, sourceText) => {
      dispatch({
        type: 'conversation/auto-title',
        payload: { id, text: sourceText, at: canonicalNow(now) },
      });
    },
    selectConversation: id => {
      dispatch({ type: 'conversation/select', payload: { id } });
    },
    appendUserMessage: (conversationId, text, appendOptions) =>
      appendMessage('user', conversationId, text, appendOptions),
    appendAssistantMessage: (conversationId, text, appendOptions) =>
      appendMessage('assistant', conversationId, text, appendOptions),
    deleteConversation: id => {
      dispatch({ type: 'conversation/delete', payload: { id } });
    },
    setModel: (id, modelId) => {
      dispatch({
        type: 'conversation/set-model',
        payload: { id, modelId, at: canonicalNow(now) },
      });
    },
    setThinkingMode: (id, thinkingMode) => {
      dispatch({
        type: 'conversation/set-thinking',
        payload: { id, thinkingMode, at: canonicalNow(now) },
      });
    },
    bindConversationToProject: (id, projectId) => {
      dispatch({
        type: 'conversation/bind-project',
        payload: { id, projectId, at: canonicalNow(now) },
      });
    },
    unbindConversationFromProject: id => {
      dispatch({
        type: 'conversation/unbind-project',
        payload: { id, at: canonicalNow(now) },
      });
    },
    bindConversationToWorkspace: (id, workspaceId) => {
      dispatch({
        type: 'conversation/bind-workspace',
        payload: { id, workspaceId, at: canonicalNow(now) },
      });
    },
    unbindConversationFromWorkspace: id => {
      dispatch({
        type: 'conversation/unbind-workspace',
        payload: { id, at: canonicalNow(now) },
      });
    },
    ensureRuntimeContextId: conversationId => {
      const existing = state.conversations[conversationId]?.runtimeContextId;
      if (existing !== null && existing !== undefined) return existing;
      const id = createLifecycleId('runtimeContext');
      if (!isCanonicalLifecycleId(id)) return null;
      const before = state;
      dispatch({
        type: 'conversation/ensure-runtime-context',
        payload: {
          id: conversationId,
          runtimeContextId: id,
          at: canonicalNow(now),
        },
      });
      return state === before
        ? null
        : state.conversations[conversationId]?.runtimeContextId ?? null;
    },
    applyProjectContextAction: (conversationId, action) => {
      const before = state;
      dispatch({
        type: 'project-context/apply',
        payload: { conversationId, action, at: canonicalNow(now) },
      });
      return state !== before;
    },
    replaceProjectContextPrepared: (scope, input) => {
      const conversationId = scope.conversationId;
      if (typeof conversationId !== 'string') return null;
      const applied = applyAction({
        type: 'project-context/replace-prepared',
        payload: {
          scope,
          preparationId: input.preparationId,
          selectedPaths: input.selectedPaths,
          manifest: input.manifest,
          at: canonicalNow(now),
        },
      });
      return scopedProjectContextTransaction(applied, conversationId);
    },
    replaceProjectContextConfirmed: (scope, input) => {
      const conversationId = scope.conversationId;
      if (typeof conversationId !== 'string') return null;
      const applied = applyAction({
        type: 'project-context/replace-confirmed',
        payload: {
          scope,
          preparationId: input.preparationId,
          selectedPaths: input.selectedPaths,
          manifest: input.manifest,
          consent: input.consent,
          at: canonicalNow(now),
        },
      });
      return scopedProjectContextTransaction(applied, conversationId);
    },
    disableProjectContext: scope => {
      const conversationId = scope.conversationId;
      if (typeof conversationId !== 'string') return null;
      const applied = applyAction({
        type: 'project-context/disable',
        payload: { scope, at: canonicalNow(now) },
      });
      const transaction = scopedProjectContextTransaction(
        applied,
        conversationId,
      );
      return transaction === null
        ? null
        : {
            ...transaction,
            cleanupSnapshotId: transaction.previousSnapshotId,
          };
    },
    beginProjectContextDestructiveTransition: input => {
      if (notificationDepth > 0) return null;
      const projected = exactDataProjection(input, [
        'lifecycleId',
        'action',
        'targetProjectId',
        'owner',
      ]);
      if (projected === null) return null;
      const owner = exactDataProjection(projected.owner, [
        'conversationId',
        'projectId',
        'runtimeContextId',
        'modelId',
        'expectedUpdatedAt',
        'expectedContext',
      ]);
      if (owner === null) return null;
      const applied = applyAction({
        type: 'project-context-destructive/begin',
        payload: {
          lifecycleId: projected.lifecycleId as string,
          action: projected.action as ProjectContextDestructiveAction,
          targetProjectId: projected.targetProjectId as string | null,
          owner: owner as ProjectContextDestructiveOwner,
          at: canonicalNow(now),
        },
      });
      const conversationId =
        applied.next.projectContextDestructiveTransition?.conversationId;
      return conversationId === undefined
        ? null
        : destructiveTransaction(applied, conversationId);
    },
    tombstoneProjectContextDestructiveTransition: scope => {
      if (notificationDepth > 0) return null;
      const projected = exactDataProjection(scope, [
        'lifecycleId',
        'epoch',
        'action',
        'targetProjectId',
        'expectedTransition',
      ]);
      if (projected === null) return null;
      const conversationId =
        state.projectContextDestructiveTransition?.conversationId;
      if (conversationId === undefined) return null;
      const applied = applyAction({
        type: 'project-context-destructive/tombstone',
        payload: {
          scope: projected as ProjectContextDestructiveAdvanceScope,
          at: canonicalNow(now),
        },
      });
      return destructiveTransaction(applied, conversationId);
    },
    markProjectContextDestructiveCleanupComplete: scope => {
      if (notificationDepth > 0) return null;
      const projected = exactDataProjection(scope, [
        'lifecycleId',
        'epoch',
        'action',
        'targetProjectId',
        'expectedTransition',
      ]);
      if (projected === null) return null;
      const conversationId =
        state.projectContextDestructiveTransition?.conversationId;
      if (conversationId === undefined) return null;
      const applied = applyAction({
        type: 'project-context-destructive/cleanup-complete',
        payload: {
          scope: projected as ProjectContextDestructiveAdvanceScope,
          at: canonicalNow(now),
        },
      });
      return destructiveTransaction(applied, conversationId);
    },
    finalizeProjectContextDestructiveTransition: scope => {
      if (notificationDepth > 0) return null;
      const projected = exactDataProjection(scope, [
        'lifecycleId',
        'epoch',
        'action',
        'targetProjectId',
        'expectedTransition',
      ]);
      if (projected === null) return null;
      const conversationId =
        state.projectContextDestructiveTransition?.conversationId;
      if (conversationId === undefined) return null;
      const applied = applyAction({
        type: 'project-context-destructive/finalize',
        payload: {
          scope: projected as ProjectContextDestructiveAdvanceScope,
          at: canonicalNow(now),
        },
      });
      return destructiveTransaction(applied, conversationId);
    },
    applySnapshotFreeProjectMutation: input => {
      if (notificationDepth > 0) return null;
      const projected = exactDataProjection(input, [
        'action',
        'conversationId',
        'targetProjectId',
        'expectedConversation',
      ]);
      if (projected === null) return null;
      try {
        const action = projected.action;
        const conversationId = projected.conversationId;
        const targetProjectId = projected.targetProjectId;
        const expectedConversation = projected.expectedConversation;
        if (
          (action !== 'unbind' &&
            action !== 'delete' &&
            action !== 'rebind') ||
          typeof conversationId !== 'string' ||
          ((action === 'rebind') !== (typeof targetProjectId === 'string')) ||
          (action !== 'rebind' && targetProjectId !== null)
        ) {
          return null;
        }
        const at = action === 'delete' ? null : canonicalNow(now);
        if (
          expectedConversation !== state.conversations[conversationId] ||
          state.projectContextDestructiveTransition !== null
        ) {
          return null;
        }
        const applied =
          action === 'delete'
            ? applyAction({
                type: 'conversation/delete',
                payload: { id: conversationId },
              })
            : action === 'rebind'
              ? applyAction({
                  type: 'conversation/bind-project',
                  payload: {
                    id: conversationId,
                    projectId: targetProjectId as string,
                    at: at!,
                  },
                })
              : applyAction({
                  type: 'conversation/unbind-project',
                  payload: { id: conversationId, at: at! },
                });
        return snapshotFreeProjectTransaction(
          applied,
          conversationId,
          action,
          targetProjectId as string | null,
        );
      } catch {
        return null;
      }
    },
    applyConversationWorkspaceBinding: input => {
      if (notificationDepth > 0) return null;
      const normalized = normalizeWorkspaceBindingInput(input);
      if (normalized === null) return null;
      const owner = normalized.owner;
      const conversation = state.conversations[owner.conversationId];
      if (
        conversation === undefined ||
        owner.expectedConversation !== conversation ||
        owner.expectedProjectContext !== conversation.projectContext ||
        owner.expectedDestructiveEpoch !== state.projectContextDestructiveEpoch
      ) {
        return null;
      }
      const applied = applyAction({
        type: 'conversation/apply-workspace-binding',
        payload: {
          owner,
          binding: normalized.binding,
          at: canonicalNow(now),
        },
      });
      return workspaceBindingTransaction(applied, owner.conversationId);
    },
    revokeAgentGrant: input => {
      if (notificationDepth > 0) return null;
      const conversation = state.conversations[input.conversationId];
      if (
        conversation === undefined ||
        input.expectedConversation !== conversation
      ) {
        return null;
      }
      const grants = conversation.agentGrants ?? conversation.agent_grants ?? [];
      if (!grants.some(grant => grant.grant_id === input.grantId)) return null;
      const next = grants.filter(grant => grant.grant_id !== input.grantId);
      const applied = applyAction({
        type: 'conversation/agent-grants',
        payload: {
          conversationId: input.conversationId,
          grants: next,
          expectedConversation: conversation,
          at: canonicalNow(now),
        },
      });
      return workspaceBindingTransaction(applied, input.conversationId);
    },
    applyWorkspaceAuthorityMutation: input => {
      if (notificationDepth > 0) return null;
      const projected = exactDataProjection(input, [
        'schemaVersion',
        'operationId',
        'action',
        'workspaceId',
        'bindingRevision',
        'clearanceReceiptId',
        'expectedState',
      ]);
      if (projected === null) return null;
      const operationId = projected.operationId;
      const workspaceId = projected.workspaceId;
      const bindingRevision = projected.bindingRevision;
      const clearanceReceiptId = projected.clearanceReceiptId;
      const action = projected.action;
      const expectedState = projected.expectedState;
      if (
        projected.schemaVersion !== 1 ||
        typeof operationId !== 'string' ||
        !isCanonicalLifecycleId(operationId) ||
        (action !== 'forget' && action !== 'delete_owned') ||
        typeof workspaceId !== 'string' ||
        !isCanonicalLifecycleId(workspaceId) ||
        typeof bindingRevision !== 'number' ||
        !Number.isSafeInteger(bindingRevision) ||
        Object.is(bindingRevision, -0) ||
        bindingRevision <= 0 ||
        bindingRevision >= Number.MAX_SAFE_INTEGER ||
        typeof clearanceReceiptId !== 'string' ||
        !isCanonicalLifecycleId(clearanceReceiptId) ||
        expectedState !== state ||
        state.projectContextDestructiveTransition !== null ||
        (state.workspaceAuthorityOutbox ?? []).length >=
          MAX_WORKSPACE_AUTHORITY_OUTBOX_ENTRIES
      ) {
        return null;
      }
      if (
        (state.workspaceAuthorityOutbox ?? []).some(
          entry => entry.operationId === operationId,
        )
      ) {
        return null;
      }
      if (
        (state.workspaceAuthorityOutbox ?? []).some(
          entry => entry.workspaceId === workspaceId,
        )
      ) {
        return null;
      }
      const targetedConversationIds = Object.values(state.conversations)
        .filter(
          conversation =>
            conversation.workspaceId === workspaceId ||
            conversation.workspaceBinding?.workspaceId === workspaceId ||
            conversation.attempts.some(
              attempt => attempt.workspaceId === workspaceId,
            ),
        )
        .map(conversation => conversation.id);
      for (const conversationId of targetedConversationIds) {
        const conversation = state.conversations[conversationId];
        if (
          conversation === undefined ||
          hasLiveAttemptForWorkspace(conversation, workspaceId) ||
          hasAttemptHoldingWorkspace(state, conversation, workspaceId) ||
          (conversation.projectContext !== null &&
            (conversation.projectContext.snapshot !== null ||
              conversation.projectContext.activePreparationId !== null))
        ) {
          return null;
        }
      }
      const outboxEntry: WorkspaceAuthorityOutboxV1 = {
        schemaVersion: 1,
        operationId,
        action,
        workspaceId,
        bindingRevision,
        clearanceReceiptId,
        createdAt: canonicalNow(now),
      };
      if (!isWorkspaceAuthorityOutboxEntry(outboxEntry)) return null;
      const conversations = { ...state.conversations };
      targetedConversationIds.forEach(conversationId => {
        const conversation = conversations[conversationId];
        if (conversation === undefined) return;
        // The project lived under the workspace's binding, so it goes with
        // it: a project id left behind would read as a legacy project to
        // bootstrap a new workspace from, which is not what happened. The
        // finished attempts that ran here let go of the tuple they froze --
        // the schema keeps an attempt's tuple equal to its conversation's
        // binding -- and keep everything else: their messages, their
        // rounds, their outcome.
        conversations[conversationId] = {
          ...conversation,
          workspaceId: null,
          workspaceBinding: null,
          projectId: null,
          projectContext: null,
          runtimeContextId: null,
          workspaceBootstrapState: 'none',
          attempts: conversation.attempts.map(attempt =>
            attempt.workspaceId === workspaceId
              ? { ...attempt, workspaceId: null, workspaceBindingRevision: null }
              : attempt,
          ),
        };
      });
      const before = state;
      const next: ChatState = {
        ...state,
        conversations,
        workspaceAuthorityOutbox: [
          ...(state.workspaceAuthorityOutbox ?? []),
          outboxEntry,
        ],
        conversationOrder: orderConversationIds(conversations),
      };
      const applied: AppliedAction = {
        before,
        next,
        changed: true,
      };
      state = next;
      notifyListeners();
      return workspaceAuthorityTransaction(
        applied,
        outboxEntry,
        targetedConversationIds,
      );
    },
    acknowledgeWorkspaceAuthorityMutation: (operationId, expectedEntry) => {
      if (
        typeof operationId !== 'string' ||
        !isCanonicalLifecycleId(operationId)
      ) {
        return false;
      }
      const index = (state.workspaceAuthorityOutbox ?? []).findIndex(
        entry => entry.operationId === operationId,
      );
      if (index < 0) return false;
      const current = (state.workspaceAuthorityOutbox ?? [])[index];
      if (
        current === undefined ||
        (expectedEntry !== undefined && expectedEntry !== current) ||
        hasWorkspaceAuthorityReferences(state, current.workspaceId)
      ) {
        return false;
      }
      const workspaceAuthorityOutbox = (state.workspaceAuthorityOutbox ?? []).filter(
        (_entry, entryIndex) => entryIndex !== index,
      );
      state = { ...state, workspaceAuthorityOutbox };
      notifyListeners();
      return true;
    },
    prepareTurnAttempt: (conversationId, text, appendOptions = {}) => {
      const conversation = state.conversations[conversationId];
      if (conversation === undefined) return null;
      const harnessId =
        appendOptions.harnessId === undefined
          ? 'dsh'
          : appendOptions.harnessId;
      if (typeof harnessId !== 'string' || !isHarnessId(harnessId)) {
        return null;
      }
      const contextChoice = frozenProjectContext(
        conversation,
        appendOptions.sendWithoutProjectContext === true,
      );
      if (contextChoice === undefined) return null;
      const userMessageId = createId('message');
      const turnId = createLifecycleId('turn');
      const attemptId = createLifecycleId('attempt');
      if (
        !isCanonicalLifecycleId(turnId) ||
        !isCanonicalLifecycleId(attemptId)
      ) {
        return null;
      }
      const at = canonicalNow(now);
      const message = {
        id: userMessageId,
        role: 'user' as const,
        text,
        createdAt: at,
        attachments: appendOptions.attachments ?? [],
        ...(appendOptions.metadata === undefined
          ? {}
          : { metadata: appendOptions.metadata }),
      };
      const visibleMessages = [...conversation.messages, message].slice(
        -MAX_ATTEMPT_VISIBLE_MESSAGES,
      );
      const attachmentIds: string[] = [];
      const seenAttachmentIds = new Set<string>();
      visibleMessages.forEach(visibleMessage => {
        visibleMessage.attachments.forEach(attachment => {
          if (seenAttachmentIds.has(attachment.id)) return;
          seenAttachmentIds.add(attachment.id);
          attachmentIds.push(attachment.id);
        });
      });
      const attempt: TurnAttemptV1 = {
        schemaVersion: 1,
        attemptId,
        turnId,
        status: 'prepared',
        harnessId,
        visibleMessageIds: visibleMessages.map(item => item.id),
        visibleHistorySha256: null,
        attachmentIds,
        modelId: conversation.modelId,
        thinkingMode: conversation.thinkingMode,
        contextDisposition: contextChoice.contextDisposition,
        contextProjectId: contextChoice.contextProjectId,
        workspaceId: contextChoice.workspaceId,
        workspaceBindingRevision: contextChoice.workspaceBindingRevision,
        projectContext: contextChoice.projectContext,
        activeRound: null,
        rounds: [],
        assistantMessageId: null,
        failureCode: null,
        createdAt: at,
        updatedAt: at,
        journalRevision: 0,
        agent: null,
      };
      const applied = applyAction({
        type: 'turn/prepare',
        payload: {
          conversationId,
          message,
          turn: {
            schemaVersion: 1,
            turnId,
            userMessageId,
            attemptIds: [attemptId],
            createdAt: at,
          },
          attempt,
        },
      });
      return preparedTransaction(applied, {
        turnId,
        attemptId,
        userMessageId,
      });
    },
    startAttemptRound: (
      conversationId,
      attemptId,
      roundId,
      roundIndex,
    ) => {
      const before = state;
      dispatch({
        type: 'attempt/start-round',
        payload: {
          conversationId,
          attemptId,
          round: { roundId, roundIndex },
          at: canonicalNow(now),
        },
      });
      return state !== before;
    },
    recordAttemptRound: (conversationId, attemptId, receipt) => {
      const before = state;
      dispatch({
        type: 'attempt/record-round',
        payload: {
          conversationId,
          attemptId,
          receipt,
          at: canonicalNow(now),
        },
      });
      return state !== before;
    },
    completeAttempt: (
      conversationId,
      attemptId,
      text,
      appendOptions = {},
    ) => {
      const id = createId('message');
      const before = state;
      dispatch({
        type: 'attempt/complete',
        payload: {
          conversationId,
          attemptId,
          message: {
            id,
            role: 'assistant',
            text,
            createdAt: canonicalNow(now),
            attachments: appendOptions.attachments ?? [],
            ...(appendOptions.metadata === undefined
              ? {}
              : { metadata: appendOptions.metadata }),
          },
        },
      });
      return state === before ? null : id;
    },
    failAttempt: (conversationId, attemptId, failureCode) => {
      const before = state;
      dispatch({
        type: 'attempt/fail',
        payload: {
          conversationId,
          attemptId,
          failureCode,
          at: canonicalNow(now),
        },
      });
      return state !== before;
    },
    cancelAttempt: (conversationId, attemptId) => {
      const before = state;
      dispatch({
        type: 'attempt/cancel',
        payload: {
          conversationId,
          attemptId,
          at: canonicalNow(now),
        },
      });
      return state !== before;
    },
    retryAttempt: (conversationId, sourceAttemptId) => {
      const conversation = state.conversations[conversationId];
      const source = conversation?.attempts.find(
        attempt => attempt.attemptId === sourceAttemptId,
      );
      const turn = conversation?.turns.find(item => item.turnId === source?.turnId);
      if (conversation === undefined || source === undefined || turn === undefined) {
        return null;
      }
      if (
        source.agent !== undefined &&
        source.agent !== null &&
        source.failureCode !== 'E_ATTEMPT_INTERRUPTED'
      ) {
        // Live Agent attempts own their native recovery path; an interrupted
        // attempt's writer is dead, so it must never be resumed and retry
        // always prepares a fresh legacy attempt in the same turn.
        return null;
      }
      const attemptId = createLifecycleId('attempt');
      if (!isCanonicalLifecycleId(attemptId)) return null;
      const at = canonicalNow(now);
      const attempt: TurnAttemptV1 = {
        ...source,
        // A user may choose another model/effort before retrying. Freeze the
        // current selection in this new attempt, never rewrite the old one.
        modelId: conversation.modelId,
        thinkingMode: conversation.thinkingMode,
        harnessId: harnessForModel(conversation.modelId),
        attemptId,
        status: 'prepared',
        activeRound: null,
        rounds: [],
        assistantMessageId: null,
        failureCode: null,
        journalRevision: 0,
        agent: null,
        createdAt: at,
        updatedAt: at,
      };
      const applied = applyAction({
        type: 'attempt/retry',
        payload: { conversationId, sourceAttemptId, attempt },
      });
      return preparedTransaction(applied, {
        turnId: turn.turnId,
        attemptId,
        userMessageId: turn.userMessageId,
      });
    },
    checkpointAgentAttempt: input => applyAgentControllerCheckpoint(input),
    checkpointAgentAttemptCAS: input => {
      return applyAgentControllerCheckpoint(input);
    },
    checkpointAgentApproval: input => {
      if (notificationDepth > 0) return null;
      const capturedAuthority = readSessionAuthority();
      if (controllerCASMatchesCurrent(input.cas, input.expectedAttempt) === null) {
        return null;
      }
      const conversationId = input.conversationId ?? input.cas.conversation_id;
      const attemptId = input.attemptId ?? input.cas.attempt_id;
      if (
        conversationId !== input.cas.conversation_id ||
        attemptId !== input.cas.attempt_id
      ) return null;
      const normalized = normalizeAgentCheckpointInput({
        cas: input.cas,
        conversationId,
        attemptId,
        expectedAttempt: input.expectedAttempt,
        journal: input.journal,
        events: input.events,
        evidence: input.evidence,
        ...(input.journalRevision === undefined
          ? {}
          : { journalRevision: input.journalRevision }),
        ...(input.cleanup === undefined ? {} : { cleanup: input.cleanup }),
      });
      if (normalized === null) return null;
      const currentConversation = state.conversations[conversationId];
      if (
        currentConversation === undefined ||
        !approvalEvidenceGrantsMatch(
          normalized.evidence,
          input.grants,
          currentConversation.agentGrants ?? currentConversation.agent_grants ?? [],
        )
      ) return null;
      const candidateEvents = eventsForAgentCheckpoint(
        state,
        normalized.evidence,
        normalized.expectedAttempt,
        normalized.events,
        canonicalNow(now),
      );
      if (candidateEvents === null) return null;
      const applied = applyAction({
        type: 'agent/approval-checkpoint',
        payload: {
          cas: normalized.cas,
          conversationId,
          attemptId,
          expectedAttempt: normalized.expectedAttempt,
          expectedConversation: input.expectedConversation,
          journal: normalized.journal as PersistedAgentAttemptJournalV3,
          grants: input.grants,
          events: candidateEvents,
          evidence: normalized.evidence,
          ...(normalized.journalRevision === undefined
            ? {}
            : { journalRevision: normalized.journalRevision }),
          ...(normalized.cleanup === undefined
            ? {}
            : { cleanup: normalized.cleanup }),
          at: canonicalNow(now),
        },
      });
      return agentCheckpointTransaction(
        applied,
        conversationId,
        attemptId,
        capturedAuthority,
      );
    },
    decideAgentApproval: input => {
      if (notificationDepth > 0) return null;
      const capturedAuthority = readSessionAuthority();
      if (controllerCASMatchesCurrent(input.cas, input.expectedAttempt) === null) {
        return null;
      }
      const conversationId = input.conversationId ?? input.cas.conversation_id;
      const attemptId = input.attemptId ?? input.cas.attempt_id;
      if (
        conversationId !== input.cas.conversation_id ||
        attemptId !== input.cas.attempt_id
      ) return null;
      const normalized = normalizeAgentCheckpointInput({
        cas: input.cas,
        conversationId,
        attemptId,
        expectedAttempt: input.expectedAttempt,
        journal: input.journal,
        events: input.events,
        evidence: input.evidence,
        ...(input.journalRevision === undefined
          ? {}
          : { journalRevision: input.journalRevision }),
        ...(input.cleanup === undefined ? {} : { cleanup: input.cleanup }),
      });
      if (normalized === null) return null;
      const currentConversation = state.conversations[conversationId];
      if (
        currentConversation === undefined ||
        !approvalEvidenceGrantsMatch(
          normalized.evidence,
          input.grants,
          currentConversation.agentGrants ?? currentConversation.agent_grants ?? [],
        )
      ) return null;
      const candidateEvents = eventsForAgentCheckpoint(
        state,
        normalized.evidence,
        normalized.expectedAttempt,
        normalized.events,
        canonicalNow(now),
      );
      if (candidateEvents === null) return null;
      const applied = applyAction({
        type: 'agent/approval-checkpoint',
        payload: {
          cas: normalized.cas,
          conversationId,
          attemptId,
          expectedAttempt: normalized.expectedAttempt,
          expectedConversation: input.expectedConversation,
          journal: normalized.journal as PersistedAgentAttemptJournalV3,
          grants: input.grants,
          events: candidateEvents,
          evidence: normalized.evidence,
          ...(normalized.journalRevision === undefined
            ? {}
            : { journalRevision: normalized.journalRevision }),
          ...(normalized.cleanup === undefined
            ? {}
            : { cleanup: normalized.cleanup }),
          at: canonicalNow(now),
        },
      });
      return agentCheckpointTransaction(
        applied,
        conversationId,
        attemptId,
        capturedAuthority,
      );
    },
    checkpointAgentRound: input =>
      applyAgentControllerCheckpoint(input, [
        'begin_round',
        'complete_agent_round_v2',
        'prepare_agent_tool_batch',
      ]),
    initializeAgentAttempt: input =>
      applyAgentControllerCheckpoint(input, ['prepare_agent_attempt']),
    setAgentJournal: input =>
      applyAgentControllerCheckpoint(input, ['recover_agent_attempt']),
    insertAgentExecutionIntent: input => {
      const normalized = normalizeAgentExecutionInput(input, false);
      return normalized === null
        ? null
        : applyAgentControllerCheckpoint(normalized, ['begin_execution']);
    },
    recordAgentToolResult: input => {
      const normalized = normalizeAgentExecutionInput(input, true);
      return normalized === null
        ? null
        : applyAgentControllerCheckpoint(normalized, ['execute_agent_tool']);
    },
    checkpointAgentBatchAndBeginFirst: input => {
      if (notificationDepth > 0) return null;
      if (typeof input !== 'object' || input === null) return null;
      const capturedAuthority = readSessionAuthority();
      const first = normalizeAgentCheckpointInput(input.batch);
      if (
        first === null ||
        first.evidence.kind !== 'prepare_agent_tool_batch' ||
        !isAgentAttemptJournalV3(first.journal) ||
        first.journal.phase !== 'batch_frozen' ||
        controllerCASMatchesCurrent(first.cas, first.expectedAttempt) === null ||
        typeof input.next !== 'object' || input.next === null ||
        !isAgentAttemptJournalV3(input.next.journal)
      ) return null;
      const { conversationId, attemptId } = first;
      const batchEvents = eventsForAgentCheckpoint(
        state, first.evidence, first.expectedAttempt, first.events, canonicalNow(now),
      );
      if (batchEvents === null) return null;
      const applied = applyAction({
        type: 'attempt/agent-checkpoint',
        payload: {
          cas: first.cas,
          conversationId,
          attemptId,
          expectedAttempt: first.expectedAttempt,
          journal: first.journal,
          events: batchEvents,
          ...(first.journalRevision === undefined ? {} : { journalRevision: first.journalRevision }),
          evidence: first.evidence,
          at: canonicalNow(now),
        },
      });
      if (!applied.changed) return null;
      const abandon = (): null => {
        if (state !== applied.before) {
          state = applied.before;
          notifyListeners();
        }
        return null;
      };
      const afterBatch = state.conversations[conversationId]?.attempts.find(
        attempt => attempt.attemptId === attemptId,
      );
      if (afterBatch === undefined) return abandon();
      const second = normalizeAgentExecutionInput(
        { ...input.next, expectedAttempt: afterBatch, conversationId, attemptId },
        false,
      );
      if (
        second === null ||
        second.evidence.kind !== 'begin_execution' ||
        controllerCASMatchesCurrent(second.cas, afterBatch) === null
      ) return abandon();
      const intentEvents = eventsForAgentCheckpoint(
        state, second.evidence, afterBatch, second.events, canonicalNow(now),
      );
      if (intentEvents === null) return abandon();
      const intent = applyAction({
        type: 'attempt/agent-checkpoint',
        payload: {
          cas: second.cas,
          conversationId,
          attemptId,
          expectedAttempt: afterBatch,
          journal: second.journal,
          events: intentEvents,
          evidence: second.evidence,
          at: canonicalNow(now),
        },
      });
      if (!intent.changed) return abandon();
      const transaction = agentCheckpointTransaction(
        { before: applied.before, next: intent.next, changed: true },
        conversationId,
        attemptId,
        capturedAuthority,
      );
      return transaction === null ? abandon() : transaction;
    },
    recordAgentToolResultAndBeginNext: input => {
      if (notificationDepth > 0) return null;
      if (typeof input !== 'object' || input === null) return null;
      const capturedAuthority = readSessionAuthority();
      const first = normalizeAgentExecutionInput(input.result, true);
      if (
        first === null ||
        first.evidence.kind !== 'execute_agent_tool' ||
        controllerCASMatchesCurrent(first.cas, first.expectedAttempt) === null ||
        !isAgentAttemptJournalV3(input.advance?.journal) ||
        typeof input.next !== 'object' || input.next === null ||
        !isAgentAttemptJournalV3(input.next.journal)
      ) return null;
      const { conversationId, attemptId } = first;
      const attemptNow = (): TurnAttemptV1 | undefined =>
        state.conversations[conversationId]?.attempts.find(
          attempt => attempt.attemptId === attemptId,
        );
      const resultEvents = eventsForAgentCheckpoint(
        state, first.evidence, first.expectedAttempt, first.events, canonicalNow(now),
      );
      if (resultEvents === null) return null;
      const applied = applyAction({
        type: 'attempt/agent-checkpoint',
        payload: {
          cas: first.cas,
          conversationId,
          attemptId,
          expectedAttempt: first.expectedAttempt,
          journal: first.journal,
          events: resultEvents,
          ...(first.journalRevision === undefined ? {} : { journalRevision: first.journalRevision }),
          evidence: first.evidence,
          at: canonicalNow(now),
        },
      });
      if (!applied.changed) return null;
      // Any later transition that the reducers refuse leaves the store exactly
      // as it was; the caller then falls back to separate checkpoints.
      const abandon = (): null => {
        if (state !== applied.before) {
          state = applied.before;
          notifyListeners();
        }
        return null;
      };
      const casFor = (attempt: TurnAttemptV1): AgentControllerCASV1 => ({
        ...first.cas,
        expected_controller_generation: attempt.agent?.controller_generation ?? 0,
        expected_journal_revision: attempt.journalRevision ?? 0,
      });
      const afterResult = attemptNow();
      if (afterResult === undefined) return abandon();
      const advanced = applyAction({
        type: 'attempt/agent-advance-call',
        payload: {
          cas: casFor(afterResult),
          conversationId,
          attemptId,
          expectedAttempt: afterResult,
          journal: input.advance.journal,
          at: input.advance.journal.updated_at,
        },
      });
      if (!advanced.changed) return abandon();
      const afterAdvance = attemptNow();
      if (afterAdvance === undefined) return abandon();
      const third = normalizeAgentExecutionInput(
        { ...input.next, expectedAttempt: afterAdvance, conversationId, attemptId },
        false,
      );
      if (
        third === null ||
        third.evidence.kind !== 'begin_execution' ||
        controllerCASMatchesCurrent(third.cas, afterAdvance) === null
      ) return abandon();
      const intentEvents = eventsForAgentCheckpoint(
        state, third.evidence, afterAdvance, third.events, canonicalNow(now),
      );
      if (intentEvents === null) return abandon();
      const intent = applyAction({
        type: 'attempt/agent-checkpoint',
        payload: {
          cas: third.cas,
          conversationId,
          attemptId,
          expectedAttempt: afterAdvance,
          journal: third.journal,
          events: intentEvents,
          evidence: third.evidence,
          at: canonicalNow(now),
        },
      });
      if (!intent.changed) return abandon();
      const transaction = agentCheckpointTransaction(
        { before: applied.before, next: intent.next, changed: true },
        conversationId,
        attemptId,
        capturedAuthority,
      );
      return transaction === null ? abandon() : transaction;
    },
    advanceAgentCall: input => {
      if (notificationDepth > 0) return null;
      const capturedAuthority = readSessionAuthority();
      const normalized = normalizeAgentNextCallCheckpointInput(input);
      if (
        normalized === null ||
        controllerCASMatchesCurrent(
          normalized.cas,
          normalized.expectedAttempt,
        ) === null
      ) return null;
      const applied = applyAction({
        type: 'attempt/agent-advance-call',
        payload: {
          cas: normalized.cas,
          conversationId: normalized.conversationId,
          attemptId: normalized.attemptId,
          expectedAttempt: normalized.expectedAttempt,
          journal: normalized.journal,
          ...(normalized.journalRevision === undefined
            ? {}
            : { journalRevision: normalized.journalRevision }),
          // The advance reducer requires the journal's updated_at to equal
          // the checkpoint time. The journal was stamped by the controller's
          // clock a moment ago; reading this store's clock again here made
          // the two disagree whenever a millisecond boundary fell between
          // the reads, and that refusal surfaced as E_AGENT_CONFLICT after
          // the first tool of a batch. One checkpoint carries one time, and
          // the journal already validated it as canonical.
          at: normalized.journal.updated_at,
        },
      });
      return agentCheckpointTransaction(
        applied,
        normalized.conversationId,
        normalized.attemptId,
        capturedAuthority,
      );
    },
    advanceAgentRound: input =>
      applyAgentControllerCheckpoint(input, ['complete_agent_round_v2']),
    cancelAgentAttempt: input =>
      applyAgentControllerCheckpoint(input, [
        'request_cancel',
        'cancel_agent_attempt',
      ]),
    failAgentAttempt: input =>
      applyAgentControllerCheckpoint(input, [
        'complete_agent_round_v2',
        'recover_agent_attempt',
      ]),
    completeAgentAttempt: input => {
      if (notificationDepth > 0) return null;
      const capturedAuthority = readSessionAuthority();
      const normalized = normalizeAgentFinalCheckpointInput(input);
      if (
        normalized === null ||
        controllerCASMatchesCurrent(
          normalized.cas,
          normalized.expectedAttempt,
        ) === null
      ) return null;
      const applied = applyAction({
        type: 'attempt/agent-final-checkpoint',
        payload: {
          cas: normalized.cas,
          conversationId: normalized.conversationId,
          attemptId: normalized.attemptId,
          expectedAttempt: normalized.expectedAttempt,
          journal: normalized.journal,
          events: normalized.events,
          evidence: normalized.evidence,
          assistantMessage: normalized.assistantMessage,
          cleanup: normalized.cleanup,
          ...(normalized.journalRevision === undefined
            ? {}
            : { journalRevision: normalized.journalRevision }),
          at: canonicalNow(now),
        },
      });
      return agentCheckpointTransaction(
        applied,
        normalized.conversationId,
        normalized.attemptId,
        capturedAuthority,
      );
    },
    abandonUnresolvedAgentAttempt: input => {
      if (notificationDepth > 0) return null;
      const capturedAuthority = readSessionAuthority();
      const applied = applyAction({
        type: 'agent/abandon-unresolved',
        payload: {
          conversationId: input.conversationId,
          attemptId: input.attemptId,
          expectedAttempt: input.expectedAttempt,
          cleanup: input.cleanup,
          at: canonicalNow(now),
        },
      });
      return cleanupEnqueueTransaction(applied, input, capturedAuthority);
    },
    enqueueAgentTranscriptCleanup: input => {
      if (notificationDepth > 0) return null;
      const capturedAuthority = readSessionAuthority();
      const applied = applyAction({
        type: 'agent/cleanup-enqueue',
        payload: {
          conversationId: input.conversationId,
          attemptId: input.attemptId,
          cleanup: input.cleanup,
          expectedAttempt: input.expectedAttempt,
          at: canonicalNow(now),
        },
      });
      return cleanupEnqueueTransaction(applied, input, capturedAuthority);
    },
    acknowledgeAgentTranscriptCleanup: (
      cleanupId,
      expectedCleanup,
      proof,
      discardProof,
    ) => {
      const transaction = cleanupAcknowledgementTransaction(
        cleanupId,
        expectedCleanup,
      );
      if (transaction === null) return false;
      const committed = transaction.commit(proof, discardProof);
      if (!committed) transaction.rollback();
      return committed;
    },
    acknowledgeAgentTranscriptCleanupTransaction: (
      cleanupId,
      expectedCleanup,
    ) => cleanupAcknowledgementTransaction(cleanupId, expectedCleanup),
    deleteConversationWithAgentCleanup: input =>
      deleteConversationWithAgentCleanupTransaction(input),
    getSessionAuthority: () => readSessionAuthority(),
    setSessionAuthority: authority => {
      if (authority === null) {
        sessionAuthority = null;
        return true;
      }
      if (!validSessionAuthority(authority)) return false;
      sessionAuthority = { ...authority };
      return true;
    },
    setPreferences: input => {
      if (notificationDepth > 0) return false;
      let preferences: NonNullable<ChatState['preferences']>;
      try {
        preferences = JSON.parse(serializeAppPreferences(hydrateAppPreferences(input)));
      } catch {
        return false;
      }
      if (JSON.stringify(state.preferences) === JSON.stringify(preferences)) return true;
      state = { ...state, preferences };
      notifyListeners();
      return true;
    },
    serialize: () => serializeChatState(state),
    hydrate: input => {
      const authority = readSessionAuthority();
      const next = hydrateChatState(
        input,
        authority === null
          ? {}
          : {
              sessionAuthority: {
                schema_version: 1,
                generation: authority.generation,
                session_sha256: authority.sessionSha256,
              },
            },
      );
      if (next !== state) {
        state = next;
        notifyListeners();
      }
      return state;
    },
  };
}
