import { conversationGrantIdsForBatch, hasLiveConversationGrant, isConversationGrantBoundCall } from '../agent/agent-conversation-grants';
import { isGuestServiceAgentTool } from '../agent/tool-registry';
import { approvalMessageBudget } from '../agent/approvalMessage';
import {
  agentRuntimeDiagnosticFromError,
  type AgentRuntimeDiagnostic,
} from '../native/agent-runtime-diagnostic';
import type {
  CompleteRoundV2Request,
  CompleteRoundV2Result,
  CompleteRoundV3Request,
  CompleteRoundV3Result,
  CompletionVisibleMessageV2,
} from './types';
import { SESSION_EVENT_SCHEMA_VERSION } from '../agent/SessionEvents';
import {
  createAgentRoundPreviewState,
  reduceAgentRoundPreview,
  type AgentRoundPreviewEvent,
  type AgentRoundPreviewState,
} from '../agent/AgentRoundPreview';
import type { AgentRoundPreviewSource } from '../agent/AgentRoundPreviewSource';
import type {
  SessionDurabilityResult,
  SessionSnapshotRefV1,
} from './SessionPersistence';
import { projectAgentVisibleHistory } from '../agent/AgentVisibleHistory';
import { validateAgentControllerPreflight } from '../agent/AgentControllerPreflight';
import {
  validateAgentStoreTransition,
  type AgentStoreTransitionEvidence,
} from '../agent/AgentStoreTransitions';
import { AGENT_FAILURE_CODES, type AgentFailureCode } from '../state/types';
import { agentAmbiguityCode } from '../agent/AgentAmbiguity';
import type {
  AgentApprovalBindingTokenV2,
  AgentApprovalPreviewV1,
  AgentAttemptProjectionV2,
  AgentBatchCallProjectionV2,
  AgentBatchReceiptV2,
  AgentConversationGrantV2,
  AgentRuntimeFacadeV2,
  AgentRuntimeCommittedCheckpointV1,
  AgentRuntimeControllerCASV1,
  AgentRuntimeRootV1,
  AgentRuntimeTranscriptHandleV1,
  AgentToolReceiptV1,
  CompleteAgentRoundRequestV2,
  CompleteAgentRoundResultV2,
  PrepareAgentAttemptRequestV2,
  PrepareAgentAttemptResultV2,
  PrepareAgentToolBatchRequestV2,
  PrepareAgentToolBatchResultV2,
  BindAgentApprovalRequestV2,
  BindAgentApprovalResultV2,
  ExecuteAgentToolRequestV2,
  ExecuteAgentToolResultV2,
  CancelAgentAttemptRequestV2,
  CancelAgentAttemptResultV2,
  QueryAgentAttemptRequestV2,
  QueryAgentAttemptResultV2,
  RecoverAgentAttemptRequestV2,
  RecoverAgentAttemptResultV2,
  FinalizeAgentAttemptRequestV2,
  FinalizeAgentAttemptResultV2,
  DiscardAgentAttemptRequestV2,
  DiscardAgentAttemptResultV2,
  InterruptAgentAttemptResultV2,
  AgentRecoveryTargetV2,
  AgentCancelTargetV2,
  AgentCancelTokenV2,
} from '../native/AgentRuntime';
import type { HarnessId } from '../harness/types';
import {
  ATTEMPT_FAILURE_CODES,
  MAX_SESSION_EVENT_ROWS,
  AGENT_EVENT_START_RESERVE,
  type AgentCheckpointTransaction,
  type AgentCleanupAcknowledgementTransaction,
  type AgentApprovalDecision,
  type AgentAttemptPhase,
  type AttemptFailureCode,
  type ChatAttachment,
  type ChatStore,
  type CompletionRoundReceiptV1,
  type Conversation,
  type PersistedAgentAttemptJournalV3,
  type PersistedAgentCallJournalV3,
  type AgentTranscriptCleanupV1,
  type AgentToolReceiptV1 as StoreAgentToolReceiptV1,
  type PersistedSessionEventV3,
  type PreparedTurnTransaction,
  type TurnAttemptV1,
  type NativeAgentDiscardProofV1,
} from '../state';

export type CompletionControllerPhase =
  | 'idle'
  | 'preparing'
  | 'persistence_pending'
  | 'starting'
  | 'sending'
  | 'approval_pending'
  | 'executing'
  | 'recovering'
  | 'cancelling'
  | 'finalizing'
  | 'retryable'
  | 'resume_available'
  | 'commit_pending'
  | 'blocked';

export type CompletionControllerState = {
  readonly phase: CompletionControllerPhase;
  readonly epoch: number;
  readonly conversationId: string | null;
  readonly turnId: string | null;
  readonly attemptId: string | null;
  readonly roundId: string | null;
  readonly transportSchemaVersion: 2 | 3 | null;
  readonly failureCode: AttemptFailureCode | null;
  /** Transient diagnostics only; never included in stored attempts or events. */
  readonly failureDiagnostic?: AgentRuntimeDiagnostic;
};

export type CompletionControllerInput = {
  readonly conversationId: string;
  readonly text: string;
  readonly attachments: readonly ChatAttachment[];
  readonly sendWithoutProjectContext?: boolean;
  /** Builtin harness that owns this turn; omitted by legacy callers and dsh. */
  readonly harnessId?: HarnessId;
};

/**
 * The persistence adapter returns the native committed snapshot reference when
 * one exists. The reference is optional for the legacy completion path so
 * status-only callers remain source-compatible; Agent checkpoints fail closed
 * unless a committed branch carries this proof.
 */
export type CompletionPersistenceResult = SessionDurabilityResult & {
  readonly snapshot?: SessionSnapshotRefV1;
};

/** Safe UI projection for a gated Agent call. Raw arguments never leave the
 * native/runtime transcript boundary.
 */
export type CompletionAgentApprovalRequest = {
  readonly approvalId: string;
  readonly conversationId: string;
  readonly taskId: string;
  readonly attemptId: string;
  readonly roundId: string;
  readonly roundIndex: number;
  readonly batchRevision: number;
  readonly manifestSha256: string;
  readonly callIndex: number;
  readonly callId: string;
  readonly name: string;
  readonly argumentsSha256: string;
  /** Bounded native-computed display preview: workspace-relative paths,
   * byte sizes, and the diff preview for write_file. Never raw model text. */
  readonly preview: AgentApprovalPreviewV1 | null;
  readonly access: 'conversation_confirm' | 'confirm_once';
  readonly allowedDecisions: readonly (
    | 'denied'
    | 'allow_once'
    | 'allow_conversation'
    | 'cancelled'
  )[];
};

export type CompletionAgentApprovalDecision =
  | { readonly status: 'denied' }
  | { readonly status: 'approved'; readonly scope: 'once' | 'conversation' };

/** Safe structured-question projection reserved for the Agent broker. */
export type CompletionAgentQuestionRequest = {
  readonly questionId: string;
  readonly conversationId: string;
  readonly taskId: string;
  readonly attemptId: string;
  readonly question: string;
  readonly inputMode: 'options' | 'free_text';
  readonly options: readonly { readonly id: string; readonly label: string }[];
  readonly required: boolean;
};

export type CompletionControllerEvents = {
  /** Accepted into the visible conversation; persistence is still pending. */
  readonly onPrepared?: () => void;
  readonly onPreparedDurable?: (prepared: {
    readonly conversationId: string;
    readonly turnId: string;
    readonly attemptId: string;
    readonly userMessageId: string;
  }) => void;
  readonly onCommitted?: (completed: {
    readonly conversationId: string;
    readonly turnId: string;
    readonly attemptId: string;
  }) => void;
};

export type CompletionControllerOutcome = {
  readonly status:
    | 'completed'
    /** The attempt settled as failed; nothing is left to resume, and `code`
     * says why, for the person. */
    | 'failed'
    | 'blocked'
    | 'persistence_pending'
    | 'retryable'
    | 'commit_pending'
    | 'cancelled'
    /** Internal batch marker: one decision of a multi-call approval batch
     * committed; the batch loop alone consumes it and never surfaces it. */
    | 'decision_committed';
  readonly conversationId: string | null;
  readonly turnId: string | null;
  readonly attemptId: string | null;
  readonly code: AttemptFailureCode | null;
};

export type CompletionControllerDependencies = {
  /**
   * Durable session-event hook: called exactly once per completed round
   * with the reasoning/text trajectory rows. The receiver owns event_id,
   * seq, and created_at allocation (the shared session-event journal), so
   * this emitter can never collide with the agent-turn driver on one
   * attempt's trajectory namespace. Optional; omitted in tests unless
   * asserted.
   */
  onSessionEvent?: (event: {
    schema_version: typeof SESSION_EVENT_SCHEMA_VERSION;
    attempt_id: string;
    kind: 'assistant_reasoning' | 'assistant_text';
    text: string;
  }) => void;
  readonly chat: ChatStore;
  readonly persistCurrent: () => Promise<CompletionPersistenceResult>;
  readonly completeRoundV2: (
    request: CompleteRoundV2Request,
  ) => Promise<CompleteRoundV2Result>;
  readonly completeRoundV3: (
    request: CompleteRoundV3Request,
  ) => Promise<CompleteRoundV3Result>;
  readonly cancelRoundV2: (roundId: string) => Promise<unknown>;
  readonly cancelRoundV3: (roundId: string) => Promise<unknown>;
  readonly createRoundId: () => string;
  /** Optional native high-level Agent facade. */
  readonly agentRuntime?: AgentRuntimeFacadeV2;
  /**
   * Optional source of streamed round previews. Preview state is
   * presentation material owned by this controller: it never enters chat
   * state, the session journal, or any proof input, and the validated round
   * result replaces it.
   */
  readonly previewSource?: AgentRoundPreviewSource;
  /** Injected safe UI approval broker; absence fails closed. */
  readonly requestAgentApproval?: (
    request: CompletionAgentApprovalRequest,
  ) => Promise<unknown>;
  /** Injected batch approval broker: presents all gated calls of one batch as
   * a single list and resolves with one raw decision per request (same order).
   * Absence falls back to per-call presentation; any malformed answer list
   * fails closed into denials. */
  readonly requestBatchApprovals?: (
    requests: readonly CompletionAgentApprovalRequest[],
  ) => Promise<readonly unknown[]>;
  /** Injected safe structured-question broker; reserved for ask_user. */
  readonly askAgentQuestion?: (
    request: CompletionAgentQuestionRequest,
  ) => Promise<unknown>;
  /** Fresh canonical operation/event IDs for Agent CAS records. */
  readonly createOperationId?: () => string;
  /** Testable canonical timestamp source for persisted Agent events. */
  readonly now?: () => string;
};

/** Streamed previews of the active attempt's rounds, keyed by round id. */
export type AgentRoundPreviews = Readonly<Record<string, AgentRoundPreviewState>>;

export type CompletionController = {
  getState(): CompletionControllerState;
  subscribe(listener: (state: CompletionControllerState) => void): () => void;
  getPreviews(): AgentRoundPreviews;
  subscribePreviews(listener: (previews: AgentRoundPreviews) => void): () => void;
  send(
    input: CompletionControllerInput,
    events?: CompletionControllerEvents,
  ): Promise<CompletionControllerOutcome>;
  retry(
    conversationId: string,
    attemptId: string,
    events?: CompletionControllerEvents,
  ): Promise<CompletionControllerOutcome>;
  resume(
    conversationId: string,
    attemptId: string,
    events?: CompletionControllerEvents,
  ): Promise<CompletionControllerOutcome>;
  /**
   * Give up on an attempt whose round the device cannot resolve, and run the
   * turn again as a fresh attempt.
   *
   * A round that reached the provider and was never answered settles
   * `ambiguous`, and recovery keeps answering that with manual reconciliation
   * -- correctly, because the model may already have done the work and
   * nothing may replay it on its own. This is the person deciding to replay
   * it. The old attempt is recorded as given up on, its native residue is
   * settled by the interrupt operation (the only one that may clear an
   * ambiguous round), and a new attempt in the same turn asks again.
   */
  abandonAndRetry(
    conversationId: string,
    attemptId: string,
    events?: CompletionControllerEvents,
  ): Promise<CompletionControllerOutcome>;
  retryPersistence(): Promise<CompletionControllerOutcome>;
  retryCommit(): Promise<CompletionControllerOutcome>;
  cancel(): Promise<void>;
  beforeConversationChange(conversationId: string): Promise<boolean>;
  beforeConversationDelete(conversationId: string): Promise<boolean>;
  reconcileHydrated(conversationId: string): CompletionControllerState;
};

type ExecutionIntent = {
  readonly preflight: NonNullable<ReturnType<typeof validateAgentControllerPreflight>>;
  readonly journal: PersistedAgentAttemptJournalV3;
  readonly batchKind: 'write_batch' | 'read_only_batch';
  readonly manifestSha256: string | null;
  readonly batchRevision: number;
  readonly approvalReference: string | null;
};

type ActiveRun = {
  readonly epoch: number;
  readonly conversationId: string;
  readonly turnId: string;
  readonly attemptId: string;
  readonly roundId: string;
  readonly transportSchemaVersion: 2 | 3;
  readonly events: CompletionControllerEvents;
};

type PendingPreparation = {
  readonly epoch: number;
  readonly transaction: PreparedTurnTransaction;
  readonly conversationId: string;
  readonly events: CompletionControllerEvents;
  readonly durability: 'session_only' | 'unknown' | null;
};

type PendingCommit = {
  readonly conversationId: string;
  readonly turnId: string;
  readonly attemptId: string;
  readonly events: CompletionControllerEvents;
};

type PendingTerminalPersistence = {
  readonly conversationId: string;
  readonly turnId: string;
  readonly attemptId: string;
  readonly successStatus: 'retryable' | 'cancelled';
  readonly failureCode: AttemptFailureCode | null;
  readonly preparedNotification: {
    readonly events: CompletionControllerEvents;
    readonly transaction: PreparedTurnTransaction;
  } | null;
};

type AgentOperationKind =
  | 'prepare_agent_attempt'
  | 'complete_agent_round_v2'
  | 'prepare_agent_tool_batch'
  | 'bind_agent_approval'
  | 'execute_agent_tool'
  | 'cancel_agent_attempt'
  | 'recover_agent_attempt';

type AgentBatchAuthority = {
  readonly roundId: string;
  readonly roundIndex: number;
  readonly batchKind: 'write_batch' | 'read_only_batch';
  readonly batchRevision: number;
  readonly manifestSha256: string | null;
  readonly resultRoundRevision: number;
};

type AgentRun = {
  readonly epoch: number;
  readonly conversationId: string;
  readonly turnId: string;
  readonly attemptId: string;
  readonly events: CompletionControllerEvents;
  readonly transportSchemaVersion: 2 | 3;
  /** The currently active native round, when one has been allocated. */
  readonly roundId: string | null;
  /** Native operation identity currently awaiting a result, if any. */
  readonly operationId: string | null;
  readonly cancelTarget:
    | AgentCancelTargetV2
    | null;
  /** Native batch authority committed by prepareAgentToolBatch. */
  readonly batchAuthority: AgentBatchAuthority | null;
  /** Full token objects are intentionally memory-only; Store keeps only token. */
  readonly approvalTokens: ReadonlyMap<number, AgentApprovalBindingTokenV2>;
  /** Native-computed display previews per call index; memory-only. */
  readonly approvalPreviews: ReadonlyMap<number, AgentApprovalPreviewV1>;
};

type PendingAgentPersistence = {
  readonly epoch: number;
  readonly transaction: AgentCheckpointTransaction;
  readonly conversationId: string;
  readonly turnId: string;
  readonly attemptId: string;
  readonly kind: 'checkpoint' | 'final' | 'cancel';
  readonly continuation: (
    checkpoint: AgentRuntimeCommittedCheckpointV1,
  ) => Promise<CompletionControllerOutcome>;
};

type PendingAgentCleanupAcknowledgement = {
  readonly epoch: number;
  readonly conversationId: string;
  readonly turnId: string;
  readonly attemptId: string;
  readonly cleanup: AgentTranscriptCleanupV1;
  readonly discardProof: NativeAgentDiscardProofV1;
  readonly transaction: AgentCleanupAcknowledgementTransaction;
};

const FAILURE_CODES: ReadonlySet<string> = new Set(ATTEMPT_FAILURE_CODES);

const IDLE: CompletionControllerState = {
  phase: 'idle',
  epoch: 0,
  conversationId: null,
  turnId: null,
  attemptId: null,
  roundId: null,
  transportSchemaVersion: null,
  failureCode: null,
};

function errorCode(error: unknown): AttemptFailureCode {
  try {
    if (typeof error !== 'object' || error === null) {
      return 'E_COMPLETION_NATIVE';
    }
    const descriptor = Object.getOwnPropertyDescriptor(error, 'code');
    if (
      descriptor !== undefined &&
      Object.prototype.hasOwnProperty.call(descriptor, 'value') &&
      typeof descriptor.value === 'string' &&
      FAILURE_CODES.has(descriptor.value)
    ) {
      return descriptor.value as AttemptFailureCode;
    }
  } catch {
    // Hostile thrown values collapse to the stable native code.
  }
  return 'E_COMPLETION_NATIVE';
}

/**
 * Says out loud that a native agent result failed the store's validation.
 *
 * The validator answers only yes or no, and every caller that gets a `null`
 * turns it into the same opaque failure -- twice now a beta report has been a
 * contract mismatch that left no trace anywhere to read. What gets written is
 * the shape, never the content: the operation, the status, and each key with
 * the type of its value. A missing key, a boolean arriving as a number, a
 * status nothing expects -- the whole class of mismatch this keeps hitting --
 * is visible in that, and no message text, path or secret can be.
 */
function rejectedTransition(operation: string, result: unknown, error?: unknown): void {
  let shape: string = typeof result;
  try {
    if (typeof result === 'object' && result !== null) {
      const status = Reflect.get(result, 'status');
      const keys = Object.keys(result)
        .slice(0, 64)
        .map(key => `${key}:${typeof Reflect.get(result, key)}`)
        .join(',');
      shape = `status=${typeof status === 'string' ? status : typeof status} {${keys}}`;
    }
  } catch {
    // A hostile result still deserves the operation name.
  }
  const reason = error === undefined ? '' : ` threw=${String(error).slice(0, 200)}`;
  console.warn(`[rish] agent transition rejected op=${operation}${reason} ${shape}`);
}

function visibleHistory(
  chat: ChatStore,
  conversationId: string,
  attempt: TurnAttemptV1,
): readonly CompletionVisibleMessageV2[] | null {
  const conversation = chat.getState().conversations[conversationId];
  if (conversation === undefined) return null;
  const messages = new Map(
    conversation.messages.map(message => [message.id, message] as const),
  );
  const projected: CompletionVisibleMessageV2[] = [];
  for (const messageId of attempt.visibleMessageIds) {
    const message = messages.get(messageId);
    if (message === undefined) return null;
    projected.push({
      role: message.role,
      content: message.text,
      attachments: message.attachments.map(attachment => ({
        schema_version: attachment.schema_version,
        id: attachment.id,
        kind: attachment.kind,
        name: attachment.name,
        mime_type: attachment.mime_type,
        size: attachment.size,
      })),
    });
  }
  return projected;
}

function receipt(
  result: CompleteRoundV2Result | CompleteRoundV3Result,
): CompletionRoundReceiptV1 {
  return {
    schemaVersion: 1,
    transportSchemaVersion: result.schema_version,
    harnessId: result.harness_id,
    ...(result.provider_configuration === undefined ? {} : { providerConfiguration: result.provider_configuration }),
    turnId: result.turn_id,
    attemptId: result.attempt_id,
    roundId: result.round_id,
    roundIndex: result.round_index,
    providerRequestId: result.provider_request_id,
    providerResponseId: result.provider_response_id,
    requestedModel: result.requested_model,
    model: result.model,
    thinkingMode: result.thinking_mode,
    finishReason: result.finish_reason,
    latencyMs: result.latency_ms,
    visibleHistorySha256: result.visible_history_sha256,
    modelInputSha256: result.model_input_sha256,
    requestBodySha256: result.request_body_sha256,
    projectContextReceipt: result.project_context_receipt,
  };
}

function outcome(
  status: CompletionControllerOutcome['status'],
  state: CompletionControllerState,
): CompletionControllerOutcome {
  return {
    status,
    conversationId: state.conversationId,
    turnId: state.turnId,
    attemptId: state.attemptId,
    code: state.failureCode,
  };
}

const AGENT_UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u;
const AGENT_DIGEST = /^[0-9a-f]{64}$/u;

function isSessionSnapshotRef(value: unknown): value is SessionSnapshotRefV1 {
  try {
    if (
      typeof value !== 'object' ||
      value === null ||
      Array.isArray(value) ||
      Object.getPrototypeOf(value) !== Object.prototype
    ) return false;
    const record = value as Record<string, unknown>;
    return (
      Object.keys(record).length === 3 &&
      record.schema_version === 1 &&
      typeof record.generation === 'number' &&
      Number.isSafeInteger(record.generation) &&
      record.generation >= 1 &&
      typeof record.session_sha256 === 'string' &&
      AGENT_DIGEST.test(record.session_sha256)
    );
  } catch {
    return false;
  }
}

function checkpointFromSnapshot(
  snapshot: SessionSnapshotRefV1,
  journalRevision: number,
): AgentRuntimeCommittedCheckpointV1 {
  return {
    schema_version: 1,
    journal_revision: journalRevision,
    session_generation: snapshot.generation,
    session_sha256: snapshot.session_sha256,
  };
}

function canonicalNow(source?: () => string): string {
  try {
    const value = source?.() ?? new Date().toISOString();
    const parsed = new Date(value);
    return parsed.toISOString() === value ? value : new Date().toISOString();
  } catch {
    return new Date().toISOString();
  }
}

function copyAgentTranscript(
  transcript: AgentRuntimeTranscriptHandleV1,
): AgentRuntimeTranscriptHandleV1 {
  return { ...transcript };
}

function copyAgentRoot(root: AgentRuntimeRootV1): AgentRuntimeRootV1 {
  return { ...root, capabilities: [...root.capabilities] };
}

function copyAgentCall(
  call: PersistedAgentCallJournalV3,
): PersistedAgentCallJournalV3 {
  return { ...call, receipt: call.receipt === null ? null : { ...call.receipt } };
}

function copyAgentJournal(
  journal: PersistedAgentAttemptJournalV3,
): PersistedAgentAttemptJournalV3 {
  return {
    ...journal,
    root: copyAgentRoot(journal.root),
    policy: { ...journal.policy },
    transcript: copyAgentTranscript(journal.transcript),
    round_lineage:
      journal.round_lineage === null ? null : { ...journal.round_lineage },
    batch: journal.batch.map(copyAgentCall),
    frozen_grant_ids: [...journal.frozen_grant_ids],
  };
}

function agentCallFromProjection(
  projection: AgentBatchCallProjectionV2,
): PersistedAgentCallJournalV3 {
  const approvalDecision: AgentApprovalDecision =
    projection.approval_state === 'denied'
      ? 'denied'
      : projection.approval_state === 'cancelled'
        ? 'cancelled'
        : projection.approval_state === 'bound'
          ? projection.approval_token === null ? 'allow_conversation' : 'allow_once'
          : 'pending';
  return {
    schema_version: 3,
    call_id: projection.call_id,
    call_index: projection.call_index,
    name: projection.name,
    arguments_sha256: projection.arguments_sha256,
    safe_summary_key: projection.safe_summary_key,
    access: projection.access,
    approval_token:
      projection.approval_token === null
        ? null
        : projection.approval_token.token,
    approval_decision: approvalDecision,
    approval_reference: projection.approval_reference,
    idempotency_key: projection.idempotency_key,
    native_row_revision: projection.native_row_revision,
    receipt:
      projection.receipt === null
        ? null
        : ({ ...projection.receipt } as unknown as StoreAgentToolReceiptV1),
  };
}

type AgentExecuteResult = Exclude<ExecuteAgentToolResultV2, { readonly status: 'conflict' }>;

function agentJournalFromProjection(
  projection: AgentAttemptProjectionV2,
  updatedAt: string,
): PersistedAgentAttemptJournalV3 | null {
  if (
    projection.phase === 'not_agent' ||
    projection.root === null ||
    projection.policy === null ||
    projection.transcript === null
  ) return null;
  return {
    schema_version: 3,
    phase: projection.phase,
    controller_generation: projection.controller_generation,
    policy: { ...projection.policy },
    root: copyAgentRoot(projection.root),
    tool_registry_version: projection.registry.registry_version,
    toolset_sha256: projection.registry.toolset_sha256,
    transcript: copyAgentTranscript(projection.transcript),
    round_index: projection.round_index,
    round_lineage:
      projection.round_id === null
        ? null
        : {
            schema_version: 2,
            round_id: projection.round_id,
            round_index: projection.round_index,
            launch_attempt: 1,
            status: projection.round_status ?? 'ready',
            native_row_revision: projection.round_revision,
          },
    call_index: projection.call_index,
    batch: projection.batch.map(agentCallFromProjection),
    frozen_grant_ids: [...projection.frozen_grant_ids],
    reserved_write_bytes: projection.reserved_write_bytes,
    updated_at: updatedAt,
  };
}

function agentFailure(error: unknown): AttemptFailureCode {
  try {
    if (typeof error !== 'object' || error === null) return 'E_COMPLETION_NATIVE';
    const descriptor = Object.getOwnPropertyDescriptor(error, 'code');
    if (
      descriptor !== undefined &&
      Object.prototype.hasOwnProperty.call(descriptor, 'value') &&
      typeof descriptor.value === 'string' &&
      FAILURE_CODES.has(descriptor.value)
    ) return descriptor.value as AttemptFailureCode;
  } catch {
    // Collapse hostile native values to the closed completion vocabulary.
  }
  return 'E_COMPLETION_NATIVE';
}

export function createCompletionController(
  dependencies: CompletionControllerDependencies,
): CompletionController {
  let state = IDLE;
  let epoch = 0;
  let active: ActiveRun | null = null;
  let pendingPreparation: PendingPreparation | null = null;
  let pendingCommit: PendingCommit | null = null;
  let pendingTerminal: PendingTerminalPersistence | null = null;
  let agentRun: AgentRun | null = null;
  let requestedAgentCancellationEpoch: number | null = null;
  let agentCancellationInFlight: number | null = null;
  let pendingAgentRecoveryRead: { epoch: number; stop: () => void } | null = null;
  let pendingAgentPersistence: PendingAgentPersistence | null = null;
  let pendingAgentCleanup: PendingAgentCleanupAcknowledgement | null = null;
  let retryPersistenceInFlight = false;
  let retryCommitInFlight = false;
  let lastCancellationCommitted = true;
  const listeners = new Set<(next: CompletionControllerState) => void>();

  const emitSessionEvent = (
    attemptId: string,
    kind: 'assistant_reasoning' | 'assistant_text',
    text: string,
  ): void => {
    if (dependencies.onSessionEvent === undefined) return;
    try {
      dependencies.onSessionEvent({
        schema_version: SESSION_EVENT_SCHEMA_VERSION,
        attempt_id: attemptId,
        kind,
        text,
      });
    } catch {
      // Trajectory emission must never affect the completion flow.
    }
  };

  // Streamed round previews: ephemeral, per attempt, replaced by the
  // validated result and dropped when the run settles.
  let roundPreviews: AgentRoundPreviews = Object.freeze({});
  let previewAttemptId: string | null = null;
  let previewKeys = new Map<string, { readonly operationId: string }>();
  let previewUnsubscribe: (() => void) | null = null;
  const previewListeners = new Set<(previews: AgentRoundPreviews) => void>();
  const publishPreviews = (next: AgentRoundPreviews): void => {
    if (next === roundPreviews) return;
    roundPreviews = next;
    previewListeners.forEach(listener => {
      try {
        listener(roundPreviews);
      } catch {
        // Preview listeners cannot affect the completion flow.
      }
    });
  };
  const clearPreviews = (): void => {
    previewAttemptId = null;
    previewKeys = new Map();
    if (Object.keys(roundPreviews).length > 0) publishPreviews(Object.freeze({}));
  };
  const onPreviewEvent = (event: AgentRoundPreviewEvent): void => {
    if (event.attemptId !== previewAttemptId) return;
    const key = previewKeys.get(event.roundId);
    if (key === undefined || key.operationId !== event.operationId) return;
    const current =
      roundPreviews[event.roundId] ??
      createAgentRoundPreviewState({
        taskId: event.taskId,
        attemptId: event.attemptId,
        roundId: event.roundId,
        roundIndex: event.roundIndex,
        operationId: event.operationId,
        providerRequestId: event.providerRequestId,
        harnessId: event.harnessId,
      });
    const next = reduceAgentRoundPreview(current, event);
    if (next === roundPreviews[event.roundId]) return;
    publishPreviews(Object.freeze({ ...roundPreviews, [event.roundId]: next }));
  };
  const openPreview = (attemptId: string, roundId: string, operationId: string): void => {
    if (previewAttemptId !== attemptId) clearPreviews();
    previewAttemptId = attemptId;
    previewKeys.set(roundId, { operationId });
    if (previewUnsubscribe === null && dependencies.previewSource !== undefined) {
      try {
        previewUnsubscribe = dependencies.previewSource(onPreviewEvent);
      } catch {
        previewUnsubscribe = null;
      }
    }
  };

  const publish = (next: Omit<CompletionControllerState, 'epoch'>) => {
    state = { ...next, epoch };
    if (
      next.phase === 'idle' ||
      next.phase === 'blocked' ||
      next.phase === 'retryable' ||
      next.phase === 'resume_available' ||
      next.phase === 'cancelling'
    ) {
      clearPreviews();
    }
    listeners.forEach(listener => {
      try {
        listener(state);
      } catch {
        // UI listeners cannot affect controller ownership.
      }
    });
  };

  const stateFor = (
    phase: CompletionControllerPhase,
    identity: {
      conversationId?: string | null;
      turnId?: string | null;
      attemptId?: string | null;
      roundId?: string | null;
      transportSchemaVersion?: 2 | 3 | null;
      failureCode?: AttemptFailureCode | null;
      failureDiagnostic?: AgentRuntimeDiagnostic | null;
    } = {},
  ): Omit<CompletionControllerState, 'epoch'> => ({
    phase,
    conversationId: identity.conversationId ?? null,
    turnId: identity.turnId ?? null,
    attemptId: identity.attemptId ?? null,
    roundId: identity.roundId ?? null,
    transportSchemaVersion: identity.transportSchemaVersion ?? null,
    failureCode: identity.failureCode ?? null,
    ...(identity.failureDiagnostic ? { failureDiagnostic: identity.failureDiagnostic } : {}),
  });

  const safePersist = async (): Promise<CompletionPersistenceResult> => {
    try {
      const result = await dependencies.persistCurrent();
      if (
        result?.status !== 'committed' &&
        result?.status !== 'session_only' &&
        result?.status !== 'not_committed' &&
        result?.status !== 'unknown'
      ) return { status: 'unknown' };
      if (result.status !== 'committed') return { status: result.status };
      return {
        status: 'committed',
        ...(isSessionSnapshotRef(result.snapshot)
          ? { snapshot: result.snapshot }
          : {}),
      };
    } catch {
      return { status: 'unknown' };
    }
  };

  const busyOutcome = (
    conversationId: string | null = state.conversationId,
    attemptId: string | null = state.attemptId,
  ): CompletionControllerOutcome => ({
    status: 'blocked',
    conversationId,
    turnId: state.turnId,
    attemptId,
    code: 'E_COMPLETION_BUSY',
  });

  const destructiveJournalActive = (): boolean => {
    try {
      return (
        dependencies.chat.getState().projectContextDestructiveTransition !==
        null
      );
    } catch {
      return true;
    }
  };

  const agentRuntime = dependencies.agentRuntime;

  const freshOperationId = (): string | null => {
    try {
      const value = dependencies.createOperationId?.() ?? dependencies.createRoundId();
      return typeof value === 'string' && AGENT_UUID.test(value) ? value : null;
    } catch {
      return null;
    }
  };

  const agentAvailable = (): boolean => {
    if (agentRuntime === undefined) return false;
    try {
      return agentRuntime.isAvailable();
    } catch {
      return false;
    }
  };

  const getConversationAttempt = (
    conversationId: string,
    attemptId: string,
  ): { readonly conversation: Conversation; readonly attempt: TurnAttemptV1 } | null => {
    try {
      const conversation = dependencies.chat.getState().conversations[conversationId];
      const attempt = conversation?.attempts.find(item => item.attemptId === attemptId);
      return conversation === undefined || attempt === undefined
        ? null
        : { conversation, attempt };
    } catch {
      return null;
    }
  };

  const authorityFor = (
    attempt: TurnAttemptV1,
    conversationId: string,
  ): AgentRuntimeControllerCASV1 | null => {
    const authority = dependencies.chat.getSessionAuthority();
    if (
      authority === null ||
      !Number.isSafeInteger(authority.generation) ||
      authority.generation < 1 ||
      !AGENT_DIGEST.test(authority.sessionSha256)
    ) return null;
    const journal = attempt.agent;
    return {
      schema_version: 1,
      conversation_id: conversationId,
      task_id: attempt.turnId,
      attempt_id: attempt.attemptId,
      expected_controller_generation: journal?.controller_generation ?? 0,
      expected_journal_revision: attempt.journalRevision ?? 0,
      expected_session_generation: authority.generation,
      expected_session_sha256: authority.sessionSha256,
    };
  };

  const agentEvent = (
    attemptId: string,
    eventId: string,
    kind: PersistedSessionEventV3['kind'],
    roundIndex: number | null,
    callId: string | null,
    status: PersistedSessionEventV3['status'],
    safeSummaryKey: string | null,
    argumentsSha256: string | null,
    resultSha256: string | null,
    approvalReference: string | null,
    failureCode: PersistedSessionEventV3['failure_code'],
    createdAt = canonicalNow(dependencies.now),
  ): PersistedSessionEventV3 => {
    const previous = dependencies.chat.getState().sessionEvents ?? [];
    const latest = previous
      .filter(event => event.attempt_id === attemptId)
      .reduce((value, event) => Math.max(value, event.seq), -1);
    return {
      schema_version: 2,
      event_id: eventId,
      attempt_id: attemptId,
      seq: latest + 1,
      kind,
      round_index: roundIndex,
      call_id: callId,
      status,
      safe_summary_key: safeSummaryKey,
      arguments_sha256: argumentsSha256,
      result_sha256: resultSha256,
      approval_reference: approvalReference,
      failure_code: failureCode,
      created_at: createdAt,
    } as PersistedSessionEventV3;
  };

  const mapEvidence = (
    operation: AgentOperationKind,
    request: unknown,
    result: unknown,
  ): AgentStoreTransitionEvidence | null => {
    try {
      const evidence = validateAgentStoreTransition({ operation, request, result });
      if (evidence === null) rejectedTransition(operation, result);
      return evidence;
    } catch (error) {
      rejectedTransition(operation, result, error);
      return null;
    }
  };

  const safeAgentPersist = async (
    transaction: AgentCheckpointTransaction,
    continuation: (
      checkpoint: AgentRuntimeCommittedCheckpointV1,
    ) => Promise<CompletionControllerOutcome>,
    runEpoch: number,
    ids: { readonly conversationId: string; readonly turnId: string; readonly attemptId: string },
    kind: PendingAgentPersistence['kind'] = 'checkpoint',
  ): Promise<CompletionControllerOutcome> => {
    const pending: PendingAgentPersistence = {
      epoch: runEpoch,
      transaction,
      conversationId: ids.conversationId,
      turnId: ids.turnId,
      attemptId: ids.attemptId,
      kind,
      continuation,
    };
    pendingAgentPersistence = pending;
    const durability = await safePersist();
    if (runEpoch !== epoch) return outcome('cancelled', state);
    if (durability.status !== 'committed') {
      if (durability.status === 'not_committed') {
        transaction.rollback();
        if (pendingAgentPersistence === pending) pendingAgentPersistence = null;
        publish(
          stateFor('blocked', {
            conversationId: ids.conversationId,
            turnId: ids.turnId,
            attemptId: ids.attemptId,
            failureCode: 'E_AGENT_PERSISTENCE',
          }),
        );
        return outcome('blocked', state);
      }
      publish(
        stateFor('persistence_pending', {
          conversationId: ids.conversationId,
          turnId: ids.turnId,
          attemptId: ids.attemptId,
          failureCode: 'E_AGENT_PERSISTENCE',
        }),
      );
      return outcome('persistence_pending', state);
    }
    if (durability.snapshot === undefined) {
      transaction.rollback();
      if (pendingAgentPersistence === pending) pendingAgentPersistence = null;
      publish(
        stateFor('blocked', {
          conversationId: ids.conversationId,
          turnId: ids.turnId,
          attemptId: ids.attemptId,
          failureCode: 'E_AGENT_PERSISTENCE',
        }),
      );
      return outcome('blocked', state);
    }
    const committed = transaction.commit(durability.snapshot);
    if (!committed) {
      transaction.rollback();
      if (pendingAgentPersistence === pending) pendingAgentPersistence = null;
      publish(
        stateFor('blocked', {
          conversationId: ids.conversationId,
          turnId: ids.turnId,
          attemptId: ids.attemptId,
          failureCode: 'E_COMPLETION_RESULT_CORRELATION',
        }),
      );
      return outcome('blocked', state);
    }
    if (pendingAgentPersistence === pending) pendingAgentPersistence = null;
    if (kind === 'checkpoint' && requestedAgentCancellationEpoch === runEpoch) {
      await settleAgentCancellation();
      return outcome('cancelled', state);
    }
    return await continuation(
      checkpointFromSnapshot(
        durability.snapshot,
        dependencies.chat.getState().conversations[ids.conversationId]?.attempts.find(
          attempt => attempt.attemptId === ids.attemptId,
        )?.journalRevision ?? 0,
      ),
    );
  };

  const notifyPrepared = (
    events: CompletionControllerEvents,
    transaction: PreparedTurnTransaction,
    conversationId: string,
  ) => {
    try {
      events.onPreparedDurable?.({
        conversationId,
        turnId: transaction.turnId,
        attemptId: transaction.attemptId,
        userMessageId: transaction.userMessageId,
      });
    } catch {
      // UI ownership notification cannot change the transaction.
    }
  };

  const notifyCommitted = (pending: PendingCommit) => {
    try {
      pending.events.onCommitted?.({
        conversationId: pending.conversationId,
        turnId: pending.turnId,
        attemptId: pending.attemptId,
      });
    } catch {
      // Proof/UI callbacks cannot affect durable state.
    }
  };

  const settleTerminalPersistence = (
    pending: PendingTerminalPersistence,
    durability: SessionDurabilityResult,
  ): CompletionControllerOutcome => {
    if (durability.status !== 'committed') {
      pendingTerminal = pending;
      if (pending.successStatus === 'cancelled') {
        lastCancellationCommitted = false;
      }
      publish(
        stateFor('persistence_pending', {
          conversationId: pending.conversationId,
          turnId: pending.turnId,
          attemptId: pending.attemptId,
          failureCode: 'E_ATTEMPT_PERSISTENCE',
        }),
      );
      return outcome('persistence_pending', state);
    }
    if (pendingTerminal === pending) pendingTerminal = null;
    if (pending.preparedNotification !== null) {
      notifyPrepared(
        pending.preparedNotification.events,
        pending.preparedNotification.transaction,
        pending.conversationId,
      );
    }
    if (pending.successStatus === 'cancelled') {
      lastCancellationCommitted = true;
    }
    publish(
      stateFor('retryable', {
        conversationId: pending.conversationId,
        turnId: pending.turnId,
        attemptId: pending.attemptId,
        failureCode: pending.failureCode,
      }),
    );
    return {
      status: pending.successStatus,
      conversationId: pending.conversationId,
      turnId: pending.turnId,
      attemptId: pending.attemptId,
      code:
        pending.successStatus === 'retryable' ? pending.failureCode : null,
    };
  };

  const persistTerminal = async (
    pending: PendingTerminalPersistence,
  ): Promise<CompletionControllerOutcome> => {
    pendingTerminal = pending;
    publish(
      stateFor('finalizing', {
        conversationId: pending.conversationId,
        turnId: pending.turnId,
        attemptId: pending.attemptId,
        failureCode: pending.failureCode,
      }),
    );
    return settleTerminalPersistence(pending, await safePersist());
  };

  const persistFailure = async (
    conversationId: string,
    attemptId: string,
    code: AttemptFailureCode,
  ) => {
    if (!dependencies.chat.failAttempt(conversationId, attemptId, code)) {
      publish(
        stateFor('blocked', {
          conversationId,
          attemptId,
          failureCode: 'E_COMPLETION_RESULT_CORRELATION',
        }),
      );
      return outcome('blocked', state);
    }
    const failedAttempt = dependencies.chat
      .getState()
      .conversations[conversationId]?.attempts.find(
        attempt => attempt.attemptId === attemptId,
      );
    if (failedAttempt === undefined) {
      publish(
        stateFor('blocked', {
          conversationId,
          attemptId,
          failureCode: 'E_COMPLETION_RESULT_CORRELATION',
        }),
      );
      return outcome('blocked', state);
    }
    return await persistTerminal({
      conversationId,
      turnId: failedAttempt.turnId,
      attemptId,
      successStatus: 'retryable',
      failureCode: code,
      preparedNotification: null,
    });
  };

  const agentProjectContextSha = (attempt: TurnAttemptV1): string | null =>
    attempt.contextDisposition === 'verified' && attempt.projectContext !== null
      ? attempt.projectContext.snapshotSha256
      : null;

  const agentRoundContextMatchesAttempt = (
    attempt: TurnAttemptV1,
    result: CompleteAgentRoundResultV2,
  ): boolean => {
    if (result.status !== 'completed') return true;
    const contextReceipt =
      result.outcome.completion_receipt.project_context_receipt;
    const context = attempt.projectContext;
    if (attempt.contextDisposition !== 'verified' || context === null) {
      return contextReceipt === null;
    }
    return contextReceipt !== null &&
      contextReceipt.snapshot_id === context.snapshotId &&
      contextReceipt.snapshot_sha256 === context.snapshotSha256 &&
      contextReceipt.source_fingerprint === context.sourceFingerprint &&
      contextReceipt.context_bytes === context.contextBytes;
  };

  const agentWorkspaceId = (attempt: TurnAttemptV1): string | null =>
    attempt.workspaceId ?? attempt.projectContext?.runtimeContextId ?? null;

  const agentProjectId = (attempt: TurnAttemptV1): string | null =>
    attempt.contextDisposition === 'verified' && attempt.projectContext !== null
      ? attempt.projectContext.projectId
      : null;

  const agentTransportSchema = (attempt: TurnAttemptV1): 2 | 3 =>
    attempt.contextDisposition === 'verified' && attempt.projectContext !== null
      ? 3
      : 2;

  const agentVisible = (
    conversation: Conversation,
    attempt: TurnAttemptV1,
  ): { readonly history: readonly CompletionVisibleMessageV2[]; readonly digest: string; readonly count: number } | null => {
    try {
      return projectAgentVisibleHistory(
        { messages: conversation.messages },
        { visibleMessageIds: attempt.visibleMessageIds },
      );
    } catch {
      return null;
    }
  };

  const agentRootForJournal = (
    journal: PersistedAgentAttemptJournalV3,
  ): AgentRuntimeRootV1 => copyAgentRoot(journal.root);

  const agentCheckpointForJournal = (
    attempt: TurnAttemptV1,
  ): AgentRuntimeCommittedCheckpointV1 | null => {
    const authority = dependencies.chat.getSessionAuthority();
    return authority === null
      ? null
      : checkpointFromSnapshot(
          {
            schema_version: 1,
            generation: authority.generation,
            session_sha256: authority.sessionSha256,
          },
          attempt.journalRevision ?? 0,
        );
  };

  const agentPreflightBase = (
    attempt: TurnAttemptV1,
    conversationId: string,
  ): AgentRuntimeControllerCASV1 | null =>
    authorityFor(attempt, conversationId);

  const agentTokenByIndex = (
    run: AgentRun | null,
    index: number,
  ): AgentApprovalBindingTokenV2 | null =>
    run?.approvalTokens.get(index) ?? null;

  const agentPreviewByIndex = (
    run: AgentRun | null,
    index: number,
  ): AgentApprovalPreviewV1 | null =>
    run?.approvalPreviews.get(index) ?? null;

  const rememberAgentTokens = (
    run: AgentRun,
    calls: readonly AgentBatchCallProjectionV2[],
  ): AgentRun => {
    const tokens = new Map(run.approvalTokens);
    const previews = new Map(run.approvalPreviews);
    calls.forEach(call => {
      if (call.approval_token !== null) tokens.set(call.call_index, call.approval_token);
      if (call.approval_preview !== null) previews.set(call.call_index, call.approval_preview);
    });
    return { ...run, approvalTokens: tokens, approvalPreviews: previews };
  };

  const agentBatchAuthorityFromProjection = (
    projection: AgentAttemptProjectionV2,
  ): AgentBatchAuthority | null => {
    if (
      projection.round_id === null ||
      projection.round_revision === null ||
      projection.batch_kind === null ||
      projection.batch_revision === null
    ) return null;
    return {
      roundId: projection.round_id,
      roundIndex: projection.round_index,
      batchKind: projection.batch_kind,
      batchRevision: projection.batch_revision,
      manifestSha256: projection.manifest_sha256,
      resultRoundRevision: projection.round_revision,
    };
  };

  const updateAgentRun = (patch: Partial<AgentRun>): void => {
    if (agentRun !== null) agentRun = { ...agentRun, ...patch };
  };

  const agentSafeApprovalDecision = (
    raw: unknown,
    allowed: readonly ('denied' | 'allow_once' | 'allow_conversation' | 'cancelled')[],
  ): 'denied' | 'allow_once' | 'allow_conversation' | 'cancelled' => {
    try {
      if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) return 'denied';
      const record = raw as Record<string, unknown>;
      if (record.status === 'denied') return allowed.includes('denied') ? 'denied' : 'cancelled';
      if (record.status !== 'approved') return 'denied';
      const scope = record.scope;
      const decision = scope === 'conversation' ? 'allow_conversation' : scope === 'once' ? 'allow_once' : null;
      return decision !== null && allowed.includes(decision) ? decision : 'denied';
    } catch {
      return 'denied';
    }
  };

  /** Bounded model-directed deny message. Anything malformed is discarded so
   * a hostile UI payload can never reach the protected transcript. */
  const agentSafeDenyMessage = (raw: unknown): string | null => {
    try {
      if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) return null;
      const record = raw as Record<string, unknown>;
      if (record.status !== 'denied' || record.message === undefined) return null;
      if (typeof record.message !== 'string') return null;
      const message = record.message;
      return approvalMessageBudget(message).valid ? message : null;
    } catch {
      return null;
    }
  };

  const agentToolFamily = (
    name: string,
  ): 'file_write' | 'git_commit' | 'git_push' | 'guest_service' | null =>
    name === 'write_file'
      ? 'file_write'
      : name === 'git_commit'
        ? 'git_commit'
        : name === 'git_push'
          ? 'git_push'
          : isGuestServiceAgentTool(name)
            ? 'guest_service'
          : null;

  const agentGrantFor = (
    conversation: Conversation,
    journal: PersistedAgentAttemptJournalV3,
    call: PersistedAgentCallJournalV3,
  ): AgentConversationGrantV2 | null => {
    const family = agentToolFamily(call.name);
    if (family === null) return null;
    const grants = conversation.agentGrants ?? conversation.agent_grants ?? [];
    return (
      grants.find(
        grant =>
          grant.conversation_id === conversation.id &&
          grant.workspace_id === journal.root.workspace_id &&
          grant.project_id === journal.root.project_id &&
          grant.binding_revision === journal.root.workspace_binding_revision &&
          grant.root_fingerprint_sha256 === journal.root.root_fingerprint_sha256 &&
          grant.tool_family === family &&
          grant.registry_version === journal.tool_registry_version &&
          grant.policy_version === journal.policy.policy_version,
      ) ?? null
    );
  };

  const agentNewGrant = (
    conversation: Conversation,
    attempt: TurnAttemptV1,
    journal: PersistedAgentAttemptJournalV3,
    call: PersistedAgentCallJournalV3,
  ): AgentConversationGrantV2 | null => {
    const family = agentToolFamily(call.name);
    if (family === null) return null;
    const grantId = freshOperationId();
    const createdAt = canonicalNow(dependencies.now);
    return grantId === null
      ? null
      : {
          schema_version: 2,
          grant_id: grantId,
          conversation_id: conversation.id,
          workspace_id: journal.root.workspace_id,
          project_id: journal.root.project_id,
          binding_revision: journal.root.workspace_binding_revision,
          root_fingerprint_sha256: journal.root.root_fingerprint_sha256,
          tool_family: family,
          registry_version: journal.tool_registry_version,
          policy_version: journal.policy.policy_version,
          issued_for: {
            schema_version: 1,
            task_id: attempt.turnId,
            attempt_id: attempt.attemptId,
          },
          created_at: createdAt,
      };
  };

  const agentPrepareRequest = (
    conversationId: string,
    attempt: TurnAttemptV1,
    operationId: string,
    visible: { readonly digest: string; readonly count: number },
    checkpoint: AgentRuntimeCommittedCheckpointV1,
    cas: AgentRuntimeControllerCASV1,
  ): PrepareAgentAttemptRequestV2 => ({
    schema_version: 2,
    operation_id: operationId,
    controller_cas: cas,
    committed_checkpoint: checkpoint,
    task_id: attempt.turnId,
    conversation_id: conversationId,
    attempt_id: attempt.attemptId,
    workspace_id: agentWorkspaceId(attempt),
    project_id: agentProjectId(attempt),
    workspace_binding_revision: attempt.workspaceBindingRevision,
    transport_schema_version: agentTransportSchema(attempt),
    harness_id: attempt.harnessId,
    model: attempt.modelId,
    thinking_mode: attempt.thinkingMode,
    visible_message_ids: [...attempt.visibleMessageIds],
    visible_history_sha256: visible.digest,
    visible_message_count: visible.count,
    project_context_sha256: agentProjectContextSha(attempt),
    registry_version: 3,
    expected_policy_version: null,
    expected_transcript: null,
  });

  const agentBeginRoundPreflight = (
    conversationId: string,
    attempt: TurnAttemptV1,
    journal: PersistedAgentAttemptJournalV3,
    visible: { readonly digest: string; readonly count: number },
    roundId: string,
    operationId: string,
    cas: AgentRuntimeControllerCASV1,
  ) => {
    const priorLineage = journal.round_lineage;
    const retrying = journal.phase === 'failed';
    const roundIndex =
      journal.phase === 'tool_result_pending'
        ? journal.round_index + 1
        : journal.round_index;
    const expectedRoundRevision =
      journal.phase === 'tool_result_pending'
        ? 0
        : priorLineage?.native_row_revision ?? 0;
    const launchAttempt = retrying
      ? (priorLineage?.launch_attempt ?? 1) + 1
      : 1;
    const raw = {
      schema_version: 1 as const,
      source: 'completion_controller' as const,
      kind: 'begin_round' as const,
      operation_id: operationId,
      base_cas: cas,
      conversation_id: conversationId,
      task_id: attempt.turnId,
      attempt_id: attempt.attemptId,
      round_id: roundId,
      round_index: roundIndex,
      launch_attempt: launchAttempt,
      expected_round_revision: expectedRoundRevision,
      transport_schema_version: agentTransportSchema(attempt),
      model: attempt.modelId,
      thinking_mode: attempt.thinkingMode,
      visible_history_sha256: visible.digest,
      visible_message_count: visible.count,
      project_context_sha256: agentProjectContextSha(attempt),
      transcript: journal.transcript,
      root: agentRootForJournal(journal),
      registry_version: journal.tool_registry_version,
      toolset_sha256: journal.toolset_sha256,
    };
    return validateAgentControllerPreflight(raw);
  };

  const journalForBeginRound = (
    journal: PersistedAgentAttemptJournalV3,
    preflight: Extract<
      NonNullable<ReturnType<typeof validateAgentControllerPreflight>>,
      { readonly kind: 'begin_round' }
    >,
    updatedAt: string,
  ): PersistedAgentAttemptJournalV3 => ({
    ...copyAgentJournal(journal),
    phase: 'round_in_flight',
    controller_generation: journal.controller_generation + 1,
    round_index: preflight.round_index,
    round_lineage: {
      schema_version: 2,
      round_id: preflight.round_id,
      round_index: preflight.round_index,
      launch_attempt: preflight.launch_attempt,
      status: 'active',
      native_row_revision: null,
    },
    call_index: null,
    batch: [],
    updated_at: updatedAt,
  });

  const journalForBatchReceipt = (
    journal: PersistedAgentAttemptJournalV3,
    batchReceipt: AgentBatchReceiptV2,
    roundRevision: number,
    updatedAt: string,
    conversation: Conversation,
  ): PersistedAgentAttemptJournalV3 | null => {
    const calls = batchReceipt.calls.map(agentCallFromProjection);
    const frozenGrantIds = conversationGrantIdsForBatch(journal, calls);
    const grantJournal = { ...journal, frozen_grant_ids: frozenGrantIds };
    if (frozenGrantIds.length > 2 || calls.some(call => !hasLiveConversationGrant(call, grantJournal, conversation.id, conversation.agentGrants ?? conversation.agent_grants ?? []))) return null;
    // Calls native already settled at preparation (refused arguments,
    // durable denials) need no approval; a batch settled in full is waiting
    // for the next round exactly like one whose calls all executed.
    const hasPendingApproval = calls.some(
      call =>
        call.receipt === null &&
        call.access !== 'auto' &&
        call.access !== 'durable_deny' &&
        call.approval_decision === 'pending',
    );
    const allSettled = calls.length > 0 && calls.every(call => call.receipt !== null);
    return {
      ...copyAgentJournal(journal),
      phase: hasPendingApproval
        ? 'approval_pending'
        : allSettled
          ? 'tool_result_pending'
          : 'batch_frozen',
      controller_generation: journal.controller_generation + 1,
      transcript: copyAgentTranscript(batchReceipt.transcript),
      round_lineage:
        journal.round_lineage === null
          ? null
          : {
              ...journal.round_lineage,
              status: 'completed',
              native_row_revision: roundRevision,
            },
      call_index: allSettled ? calls.length - 1 : calls.findIndex(call => call.receipt === null),
      batch: calls,
      frozen_grant_ids: frozenGrantIds,
      reserved_write_bytes: batchReceipt.reserved_write_bytes,
      updated_at: updatedAt,
    };
  };

  const journalForApproval = (
    journal: PersistedAgentAttemptJournalV3,
    callIndex: number,
    decision: AgentApprovalDecision,
    approvalReference: string | null,
    grantId: string | null,
    updatedAt: string,
  ): PersistedAgentAttemptJournalV3 => {
    const batch = journal.batch.map(copyAgentCall);
    const call = batch[callIndex];
    if (call !== undefined) {
      batch[callIndex] = {
        ...call,
        approval_decision: decision,
        approval_token:
          decision === 'denied' || decision === 'cancelled'
            ? null
            : call.approval_token,
        approval_reference:
          decision === 'denied' || decision === 'cancelled'
            ? null
            : approvalReference,
      };
    }
    const pending = batch.some(
      candidate =>
        candidate.access !== 'auto' &&
        candidate.access !== 'durable_deny' &&
        candidate.approval_decision === 'pending',
    );
    return {
      ...copyAgentJournal(journal),
      // A successful bind post-checkpoint is itself a batch-frozen state;
      // remaining gated calls are presented one at a time from that phase.
      // Denials keep the explicit approval-pending marker until all gates are
      // settled.
      phase:
        decision === 'allow_once' || decision === 'allow_conversation'
          ? 'batch_frozen'
          : pending
            ? 'approval_pending'
            : 'batch_frozen',
      controller_generation: journal.controller_generation + 1,
      frozen_grant_ids:
        grantId === null
          ? [...journal.frozen_grant_ids]
          : [...journal.frozen_grant_ids, grantId],
      call_index: batch.findIndex(candidate => candidate.receipt === null),
      batch,
      updated_at: updatedAt,
    };
  };

  const journalForExecutionIntent = (
    journal: PersistedAgentAttemptJournalV3,
    callIndex: number,
    updatedAt: string,
  ): PersistedAgentAttemptJournalV3 => ({
    ...copyAgentJournal(journal),
    phase: 'execution_intent',
    controller_generation: journal.controller_generation + 1,
    call_index: callIndex,
    updated_at: updatedAt,
  });

  const journalForToolResult = (
    journal: PersistedAgentAttemptJournalV3,
    result: AgentExecuteResult,
    updatedAt: string,
  ): PersistedAgentAttemptJournalV3 | null => {
    const call = journal.batch[result.call_index];
    if (call === undefined) return null;
    const toolReceipt =
      result.receipt === null
        ? null
        : ({ ...result.receipt } as unknown as StoreAgentToolReceiptV1);
    const batch = journal.batch.map(copyAgentCall);
    batch[result.call_index] = {
      ...call,
      native_row_revision: result.result_execution_revision,
      receipt: toolReceipt,
    };
    const phase =
      result.status === 'running' || result.status === 'cancel_requested'
        ? 'execution_intent'
        : result.status === 'cancelled'
        ? 'cancelled'
        : result.status === 'unknown'
          ? 'unknown'
          : result.status === 'ambiguous'
            ? 'ambiguous'
            : 'tool_result_pending';
    return {
      ...copyAgentJournal(journal),
      phase,
      controller_generation: journal.controller_generation + 1,
      transcript: copyAgentTranscript(result.transcript),
      call_index: result.call_index,
      batch,
      updated_at: updatedAt,
    };
  };

  const journalForDeniedSettlement = (
    journal: PersistedAgentAttemptJournalV3,
    callIndex: number,
    deniedReceipt: AgentToolReceiptV1,
    transcript: AgentRuntimeTranscriptHandleV1,
    updatedAt: string,
  ): PersistedAgentAttemptJournalV3 | null => {
    const call = journal.batch[callIndex];
    if (call === undefined) return null;
    const batch = journal.batch.map(copyAgentCall);
    batch[callIndex] = {
      ...call,
      approval_decision: 'denied',
      approval_token: null,
      approval_reference: null,
      native_row_revision: 2,
      receipt: { ...deniedReceipt } as unknown as StoreAgentToolReceiptV1,
    };
    const remainingPending = batch.some(
      candidate =>
        candidate.access !== 'auto' &&
        candidate.access !== 'durable_deny' &&
        candidate.approval_decision === 'pending',
    );
    // A denial that settles the last open call completes the batch: the
    // cursor rests on the denied call and the phase is tool_result_pending so
    // the next provider round starts from the denied tool result.
    const allSettled = batch.every(candidate => candidate.receipt !== null);
    return {
      ...copyAgentJournal(journal),
      phase: remainingPending
        ? 'approval_pending'
        : allSettled
          ? 'tool_result_pending'
          : 'batch_frozen',
      controller_generation: journal.controller_generation + 1,
      transcript: copyAgentTranscript(transcript),
      call_index: allSettled
        ? callIndex
        : batch.findIndex(candidate => candidate.receipt === null),
      batch,
      updated_at: updatedAt,
    };
  };

  let runAgentRound: (
    conversationId: string,
    attemptId: string,
    runEpoch: number,
  ) => Promise<CompletionControllerOutcome>;
  let runAgentBatch: (
    conversationId: string,
    attemptId: string,
    runEpoch: number,
  ) => Promise<CompletionControllerOutcome>;

  const failAgentWithoutNative = async (
    conversationId: string,
    attemptId: string,
    code: AttemptFailureCode,
    failureDiagnostic?: AgentRuntimeDiagnostic | null,
  ): Promise<CompletionControllerOutcome> => {
    const located = getConversationAttempt(conversationId, attemptId);
    if (located === null) {
      publish(stateFor('blocked', { conversationId, attemptId, failureCode: code }));
      return outcome('blocked', state);
    }
    // Agent attempts are reducer-owned by their native checkpoint evidence.
    // A local/native rejection such as a preflight conflict has no matching
    // terminal Agent evidence, so the generic attempt/fail reducer correctly
    // refuses it. Keep the last durable Agent checkpoint recoverable and expose
    // the original failure instead of misreporting that refusal as correlation.
    if (located.attempt.agent !== undefined && located.attempt.agent !== null) {
      agentRun = null;
      publish(
        stateFor('resume_available', {
          conversationId,
          turnId: located.attempt.turnId,
          attemptId,
          roundId: located.attempt.agent.round_lineage?.round_id ?? null,
          transportSchemaVersion: agentTransportSchema(located.attempt),
          failureCode: code,
          failureDiagnostic,
        }),
      );
      return outcome('retryable', state);
    }
    const failed = dependencies.chat.failAttempt(conversationId, attemptId, code);
    if (!failed) {
      publish(
        stateFor('blocked', {
          conversationId,
          turnId: located.attempt.turnId,
          attemptId,
          failureCode: 'E_COMPLETION_RESULT_CORRELATION',
        }),
      );
      return outcome('blocked', state);
    }
    const durability = await safePersist();
    if (durability.status !== 'committed') {
      publish(
        stateFor('persistence_pending', {
          conversationId,
          turnId: located.attempt.turnId,
          attemptId,
          failureCode: 'E_AGENT_PERSISTENCE',
        }),
      );
      return outcome('persistence_pending', state);
    }
    publish(
      stateFor('retryable', {
        conversationId,
        turnId: located.attempt.turnId,
        attemptId,
        failureCode: code,
      }),
    );
    return outcome('retryable', state);
  };

  const runAgentPreparedImpl = async (
    conversationId: string,
    turnId: string,
    attemptId: string,
    events: CompletionControllerEvents,
    runEpoch: number,
  ): Promise<CompletionControllerOutcome> => {
    if (agentRuntime === undefined || !agentAvailable()) {
      return await runLegacyPrepared(
        conversationId,
        turnId,
        attemptId,
        events,
        runEpoch,
      );
    }
    const located = getConversationAttempt(conversationId, attemptId);
    if (located === null || runEpoch !== epoch) return outcome('cancelled', state);
    const { conversation, attempt } = located;
    agentRun = {
      epoch: runEpoch,
      conversationId,
      turnId,
      attemptId,
      events,
      transportSchemaVersion: agentTransportSchema(attempt),
      roundId: null,
      operationId: null,
      cancelTarget: {
        schema_version: 2,
        kind: 'attempt',
        task_id: turnId,
        attempt_id: attemptId,
      },
      batchAuthority: null,
      approvalTokens: new Map(),
      approvalPreviews: new Map(),
    };
    const visible = agentVisible(conversation, attempt);
    const checkpoint = agentCheckpointForJournal(attempt);
    const cas = agentPreflightBase(attempt, conversationId);
    const operationId = freshOperationId();
    if (visible === null || checkpoint === null || cas === null || operationId === null) {
      const failureCode: AttemptFailureCode =
        visible === null
          ? 'E_COMPLETION_HISTORY'
          : checkpoint === null
            ? 'E_AGENT_PERSISTENCE'
            : cas === null
              ? 'E_AGENT_CONFLICT'
              : 'E_COMPLETION_NATIVE';
      publish(
        stateFor('retryable', {
          conversationId,
          turnId,
          attemptId,
          failureCode,
        }),
      );
      return outcome('retryable', state);
    }
    const request = agentPrepareRequest(
      conversationId,
      attempt,
      operationId,
      visible,
      checkpoint,
      cas,
    );
    const event = agentEvent(
      attemptId,
      operationId,
      'round',
      null,
      null,
      'waiting',
      null,
      null,
      null,
      null,
      null,
    );
    updateAgentRun({
      operationId,
      roundId: null,
      cancelTarget: {
        schema_version: 2,
        kind: 'attempt',
        task_id: turnId,
        attempt_id: attemptId,
      },
    });
    publish(
      stateFor('starting', {
        conversationId,
        turnId,
        attemptId,
        transportSchemaVersion: request.transport_schema_version,
      }),
    );
    let result: PrepareAgentAttemptResultV2;
    try {
      result = await agentRuntime.prepareAgentAttempt(request);
    } catch (error) {
      updateAgentRun({ operationId: null, cancelTarget: null });
      publish(
        stateFor('retryable', {
          conversationId,
          turnId,
          attemptId,
          failureCode: agentFailure(error),
        }),
      );
      return outcome('retryable', state);
    }
    if (runEpoch !== epoch) return outcome('cancelled', state);
    if (result.status === 'conflict') {
      updateAgentRun({ operationId: null, cancelTarget: null });
      return await failAgentWithoutNative(
        conversationId,
        attemptId,
        result.failure_code as AttemptFailureCode,
      );
    }
    const evidence = mapEvidence('prepare_agent_attempt', request, result);
    if (evidence === null) {
      updateAgentRun({ operationId: null, cancelTarget: null });
      return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_TRANSCRIPT');
    }
    if (result.status === 'not_agent') {
      agentRun = null;
      return await runLegacyPrepared(
        conversationId,
        turnId,
        attemptId,
        events,
        runEpoch,
      );
    }
    const preparedJournal = agentJournalFromProjection(
      result.attempt,
      canonicalNow(dependencies.now),
    );
    if (preparedJournal === null) {
      updateAgentRun({ operationId: null, cancelTarget: null });
      return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_TRANSCRIPT');
    }
    const transaction = dependencies.chat.initializeAgentAttempt({
      cas,
      expectedAttempt: attempt,
      journal: preparedJournal,
      events: [event],
      evidence,
    });
    if (transaction === null) {
      updateAgentRun({ operationId: null, cancelTarget: null });
      return await failAgentWithoutNative(
        conversationId,
        attemptId,
        'E_AGENT_CONFLICT',
      );
    }
    agentRun = {
      epoch: runEpoch,
      conversationId,
      turnId,
      attemptId,
      events,
      transportSchemaVersion: request.transport_schema_version,
      roundId: null,
      operationId,
      cancelTarget: {
        schema_version: 2,
        kind: 'attempt',
        task_id: turnId,
        attempt_id: attemptId,
      },
      batchAuthority: null,
      approvalTokens: new Map(),
      approvalPreviews: new Map(),
    };
    return await safeAgentPersist(
      transaction,
      async () => {
        if (runEpoch !== epoch) return outcome('cancelled', state);
        return await runAgentRound(conversationId, attemptId, runEpoch);
      },
      runEpoch,
      { conversationId, turnId, attemptId },
    );
  };

  const runAgentPrepared = async (
    conversationId: string, turnId: string, attemptId: string,
    events: CompletionControllerEvents, runEpoch: number,
  ): Promise<CompletionControllerOutcome> => {
    try {
      return await runAgentPreparedImpl(conversationId, turnId, attemptId, events, runEpoch);
    } finally {
      if (agentRun?.epoch === runEpoch && pendingAgentPersistence === null &&
          pendingAgentCleanup === null &&
          ['blocked', 'retryable', 'resume_available'].includes(state.phase)) {
        agentRun = null;
        if (requestedAgentCancellationEpoch === runEpoch) requestedAgentCancellationEpoch = null;
      }
    }
  };

  let prepareAgentBatch: (
    conversationId: string,
    attemptId: string,
    runEpoch: number,
    request: CompleteAgentRoundRequestV2,
    result: Extract<CompleteAgentRoundResultV2, { readonly status: 'completed' }> ,
    evidence: AgentStoreTransitionEvidence,
  ) => Promise<CompletionControllerOutcome>;
  let finishAgentTerminal: (
    conversationId: string,
    attemptId: string,
    runEpoch: number,
    request: CompleteAgentRoundRequestV2,
    result: Extract<CompleteAgentRoundResultV2, { readonly status: 'completed' }> ,
    evidence: AgentStoreTransitionEvidence,
  ) => Promise<CompletionControllerOutcome>;
  let finishAgentNonTerminal: (
    conversationId: string,
    attemptId: string,
    runEpoch: number,
    request: CompleteAgentRoundRequestV2,
    result: Exclude<CompleteAgentRoundResultV2, { readonly status: 'completed' }> ,
    evidence: AgentStoreTransitionEvidence,
  ) => Promise<CompletionControllerOutcome>;

  const runAgentRoundImpl = async (
    conversationId: string,
    attemptId: string,
    runEpoch: number,
  ): Promise<CompletionControllerOutcome> => {
    if (agentRuntime === undefined || runEpoch !== epoch) {
      return outcome('cancelled', state);
    }
    const located = getConversationAttempt(conversationId, attemptId);
    if (located === null || located.attempt.agent === undefined || located.attempt.agent === null) {
      return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_CONFLICT');
    }
    const { conversation, attempt } = located;
    const journal = attempt.agent;
    if (journal === undefined || journal === null) {
      return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_CONFLICT');
    }
    if (
      journal.phase !== 'ready_for_round' &&
      journal.phase !== 'tool_result_pending' &&
      journal.phase !== 'failed'
    ) return outcome('cancelled', state);
    const visible = agentVisible(conversation, attempt);
    const cas = agentPreflightBase(attempt, conversationId);
    const checkpoint = agentCheckpointForJournal(attempt);
    const operationId = freshOperationId();
    const isNextRound = journal.phase === 'tool_result_pending';
    const roundId =
      !isNextRound && journal.phase === 'failed' && journal.round_lineage !== null
        ? journal.round_lineage.round_id
        : freshOperationId();
    if (visible === null || cas === null || checkpoint === null || operationId === null || roundId === null) {
      return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_PERSISTENCE');
    }
    const preflight = agentBeginRoundPreflight(
      conversationId,
      attempt,
      journal,
      visible,
      roundId,
      operationId,
      cas,
    );
    if (preflight === null || preflight.kind !== 'begin_round') {
      return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_CONFLICT');
    }
    const nextJournal = journalForBeginRound(
      journal,
      preflight,
      canonicalNow(dependencies.now),
    );
    const transaction = dependencies.chat.checkpointAgentRound({
      cas,
      expectedAttempt: attempt,
      journal: nextJournal,
      events: [],
      evidence: preflight,
    });
    if (transaction === null) {
      return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_CONFLICT');
    }
    updateAgentRun({
      roundId,
      operationId,
      cancelTarget: {
        schema_version: 2,
        kind: 'round',
        task_id: attempt.turnId,
        attempt_id: attempt.attemptId,
        round_id: roundId,
        round_index: preflight.round_index,
      },
    });
    publish(
      stateFor('starting', {
        conversationId,
        turnId: attempt.turnId,
        attemptId,
        roundId,
        transportSchemaVersion: preflight.transport_schema_version,
      }),
    );
    return await safeAgentPersist(
      transaction,
      async committedCheckpoint => await runRoundAfterBegin(
        conversationId, attemptId, runEpoch, preflight, committedCheckpoint,
      ),
      runEpoch,
      { conversationId, turnId: attempt.turnId, attemptId },
    );
  };

  /** Everything after a durable round launch marker: the provider round and its dispatch. */
  const runRoundAfterBegin = async (
    conversationId: string,
    attemptId: string,
    runEpoch: number,
    preflight: Extract<
      NonNullable<ReturnType<typeof validateAgentControllerPreflight>>,
      { readonly kind: 'begin_round' }
    >,
    committedCheckpoint: AgentRuntimeCommittedCheckpointV1,
  ): Promise<CompletionControllerOutcome> => {
        if (runEpoch !== epoch) return outcome('cancelled', state);
        const current = getConversationAttempt(conversationId, attemptId);
        if (current === null || current.attempt.agent === undefined || current.attempt.agent === null) {
          return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_CONFLICT');
        }
        const currentJournal = current.attempt.agent;
        const currentVisible = agentVisible(current.conversation, current.attempt);
        if (currentVisible === null || currentJournal.round_lineage === null) {
          return await failAgentWithoutNative(conversationId, attemptId, 'E_COMPLETION_HISTORY');
        }
        // The begin-round preflight event is the durable round-launch marker.
        // Reusing its operation identity for the provider completion keeps the
        // post/final candidate anchored to one round event without adding a
        // second synthetic "running" row.
        const completeOperationId = preflight.operation_id;
        const completeRequest: CompleteAgentRoundRequestV2 = {
          schema_version: 2,
          operation_id: completeOperationId,
          controller_cas: authorityFor(current.attempt, conversationId)!,
          committed_checkpoint: committedCheckpoint,
          task_id: current.attempt.turnId,
          conversation_id: conversationId,
          attempt_id: attemptId,
          round_id: currentJournal.round_lineage.round_id,
          round_index: currentJournal.round_index,
          launch_attempt: currentJournal.round_lineage.launch_attempt,
          expected_round_revision: preflight.expected_round_revision,
          transport_schema_version: current.attempt.contextDisposition === 'verified' ? 3 : 2,
          harness_id: current.attempt.harnessId,
          model: current.attempt.modelId,
          thinking_mode: current.attempt.thinkingMode,
          visible_history_sha256: currentVisible.digest,
          visible_message_count: currentVisible.count,
          project_context_sha256: agentProjectContextSha(current.attempt),
          transcript: currentJournal.transcript,
          root: agentRootForJournal(currentJournal),
          registry_version: currentJournal.tool_registry_version,
          toolset_sha256: currentJournal.toolset_sha256,
        };
        updateAgentRun({ operationId: completeOperationId });
        publish(
          stateFor('sending', {
            conversationId,
            turnId: current.attempt.turnId,
            attemptId,
            roundId: currentJournal.round_lineage.round_id,
            transportSchemaVersion: completeRequest.transport_schema_version,
          }),
        );
        openPreview(attemptId, currentJournal.round_lineage.round_id, completeOperationId);
        let result: CompleteAgentRoundResultV2;
        try {
          result = await agentRuntime!.completeAgentRoundV2(completeRequest);
        } catch (error) {
          if (runEpoch !== epoch || agentCancellationInFlight === runEpoch) return outcome('cancelled', state);
          updateAgentRun({ operationId: null, cancelTarget: null });
          return await failAgentWithoutNative(
            conversationId, attemptId, agentFailure(error),
            agentRuntimeDiagnosticFromError(error),
          );
        }
        if (runEpoch !== epoch || agentCancellationInFlight === runEpoch) return outcome('cancelled', state);
        if (!agentRoundContextMatchesAttempt(current.attempt, result)) {
          return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_TRANSCRIPT');
        }
        const evidence = mapEvidence('complete_agent_round_v2', completeRequest, result);
        if (evidence === null) {
          updateAgentRun({ operationId: null, cancelTarget: null });
          return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_TRANSCRIPT');
        }
        if (result.status !== 'completed') {
          return await finishAgentNonTerminal(
            conversationId,
            attemptId,
            runEpoch,
            completeRequest,
            result,
            evidence,
          );
        }
        if (result.outcome.kind === 'tool_batch') {
          return await prepareAgentBatch(
            conversationId,
            attemptId,
            runEpoch,
            completeRequest,
            result,
            evidence,
          );
        }
        return await finishAgentTerminal(
          conversationId,
          attemptId,
          runEpoch,
          completeRequest,
          result,
          evidence,
        );
  };

  runAgentRound = runAgentRoundImpl;

  const agentCleanupFor = (
    conversationId: string,
    attempt: TurnAttemptV1,
    journal: PersistedAgentAttemptJournalV3,
    reason: AgentTranscriptCleanupV1['reason'],
    createdAt: string,
  ): AgentTranscriptCleanupV1 | null => {
    const cleanupId = freshOperationId();
    return cleanupId === null
      ? null
      : {
          schema_version: 1,
          cleanup_id: cleanupId,
          conversation_id: conversationId,
          task_id: attempt.turnId,
          attempt_id: attempt.attemptId,
          transcript_ref: journal.transcript.transcript_ref,
          transcript_sha256: journal.transcript.transcript_sha256,
          reason,
          created_at: createdAt,
        };
  };

  let finalizeAgent: (
    conversationId: string,
    attemptId: string,
    runEpoch: number,
    checkpoint: AgentRuntimeCommittedCheckpointV1,
    journal: PersistedAgentAttemptJournalV3,
    cleanup: AgentTranscriptCleanupV1,
    cas: AgentRuntimeControllerCASV1,
  ) => Promise<CompletionControllerOutcome>;

  const terminalizeAgent = async (
    conversationId: string,
    attemptId: string,
    runEpoch: number,
    request: CompleteAgentRoundRequestV2,
    result: Extract<CompleteAgentRoundResultV2, { readonly status: 'completed' }>,
    evidence: AgentStoreTransitionEvidence,
    phase: 'final_response' | 'failed',
  ): Promise<CompletionControllerOutcome> => {
    const located = getConversationAttempt(conversationId, attemptId);
    if (located === null || located.attempt.agent === undefined || located.attempt.agent === null) {
      return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_CONFLICT');
    }
    const currentJournal = located.attempt.agent;
    const roundOutcome = result.outcome;
    const lineage = currentJournal.round_lineage;
    if (lineage === null) {
      return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_CONFLICT');
    }
    const completionReceipt = roundOutcome.completion_receipt;
    if ((completionReceipt.harness_id ?? 'dsh') !== located.attempt.harnessId) {
      // A receipt minted by a different Harness than the attempt owner can
      // never be replayed as this attempt's model response.
      return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_TRANSCRIPT');
    }
    const terminalCreatedAt = canonicalNow(dependencies.now);
    const nextJournal: PersistedAgentAttemptJournalV3 = {
      ...copyAgentJournal(currentJournal),
      phase,
      controller_generation: currentJournal.controller_generation + 1,
      transcript: copyAgentTranscript(roundOutcome.transcript),
      round_lineage: {
        ...lineage,
        status: 'completed',
        native_row_revision: result.result_round_revision,
      },
      call_index: null,
      batch: [],
      updated_at: terminalCreatedAt,
    };
    const cleanup = agentCleanupFor(
      conversationId,
      located.attempt,
      nextJournal,
      phase === 'final_response' ? 'completed' : 'failed',
      terminalCreatedAt,
    );
    if (cleanup === null) {
      return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_PERSISTENCE');
    }
    const terminalEvent = agentEvent(
      attemptId,
      freshOperationId() ?? request.operation_id,
      'terminal',
      null,
      null,
      phase === 'final_response' ? 'ok' : 'failed',
      null,
      null,
      null,
      null,
      phase === 'final_response' ? null : (roundOutcome.kind === 'blocked' ? roundOutcome.failure_code : 'E_AGENT_PERSISTENCE'),
      terminalCreatedAt,
    );
    const assistantMessage =
      phase === 'final_response' && roundOutcome.kind === 'final'
        ? (() => {
            const id = freshOperationId();
            return id === null
              ? null
              : {
                  id,
                  role: 'assistant' as const,
                  text: roundOutcome.text,
                  createdAt: terminalCreatedAt,
                  attachments: [],
                  metadata: {
                    modelId: completionReceipt.model,
                    latencyMs: completionReceipt.latency_ms,
                    finishReason: completionReceipt.finish_reason,
                    ...(roundOutcome.reasoning.trim().length === 0
                      ? {}
                      : { reasoning: roundOutcome.reasoning }),
                  },
                };
          })()
        : null;
    if (phase === 'final_response' && assistantMessage === null) {
      return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_PERSISTENCE');
    }
    const currentCas = authorityFor(located.attempt, conversationId);
    if (currentCas === null) {
      return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_PERSISTENCE');
    }
    const finalEvidence = evidence;
    const transaction = dependencies.chat.completeAgentAttempt({
      cas: currentCas,
      expectedAttempt: located.attempt,
      journal: nextJournal,
      events: [terminalEvent],
      evidence: finalEvidence,
      assistantMessage,
      cleanup,
    });
    if (transaction === null) {
      return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_CONFLICT');
    }
    publish(
      stateFor('finalizing', {
        conversationId,
        turnId: located.attempt.turnId,
        attemptId,
        roundId: request.round_id,
        transportSchemaVersion: request.transport_schema_version,
      }),
    );
    return await safeAgentPersist(
      transaction,
      async committedCheckpoint => {
        if (runEpoch !== epoch || agentRuntime === undefined) return outcome('cancelled', state);
        const finalized = await finalizeAgent(
          conversationId,
          attemptId,
          runEpoch,
          committedCheckpoint,
          nextJournal,
          cleanup,
          currentCas,
        );
        return finalized;
      },
      runEpoch,
      { conversationId, turnId: located.attempt.turnId, attemptId },
      'final',
    );
  };

  finishAgentTerminal = async (
    conversationId,
    attemptId,
    runEpoch,
    request,
    result,
    evidence,
  ) => {
    if (result.outcome.kind !== 'final') {
      return await terminalizeAgent(
        conversationId,
        attemptId,
        runEpoch,
        request,
        result,
        evidence,
        'failed',
      );
    }
    if (result.outcome.text.trim().length === 0) {
      return await failAgentWithoutNative(conversationId, attemptId, 'E_COMPLETION_EMPTY_RESPONSE');
    }
    if (result.outcome.reasoning.length > 0) {
      emitSessionEvent(attemptId, 'assistant_reasoning', result.outcome.reasoning);
    }
    emitSessionEvent(attemptId, 'assistant_text', result.outcome.text);
    return await terminalizeAgent(
      conversationId,
      attemptId,
      runEpoch,
      request,
      result,
      evidence,
      'final_response',
    );
  };

  /**
   * Clear what an abandoned attempt still owns natively.
   *
   * `interrupt_agent_attempt` is the only operation that settles an
   * `ambiguous` or `unknown` round: a discard refuses one by design, because
   * a round that may have reached the provider is not residue anybody may
   * assume away. The session proves the attempt is over -- it now reads
   * failed with its journal kept -- and the interrupt discards the authority,
   * reservations, batches and never-dispatched intents with it, so the fresh
   * attempt that follows prepares over nothing.
   *
   * A refusal here is not fatal and is deliberately not reported: the outbox
   * entry stays durable and the launch drain retries it, while the attempt
   * is already recorded as given up on.
   */
  const settleAbandonedAgentResidue = async (
    conversationId: string,
    attemptId: string,
    runEpoch: number,
    cleanup: AgentTranscriptCleanupV1,
  ): Promise<void> => {
    if (agentRuntime === undefined || !agentAvailable()) return;
    const authority = dependencies.chat.getSessionAuthority();
    const operationId = freshOperationId();
    if (authority === null || operationId === null) return;
    let settled: InterruptAgentAttemptResultV2;
    try {
      settled = await agentRuntime.interruptAgentAttempt({
        schema_version: 2,
        operation_id: operationId,
        cleanup_id: cleanup.cleanup_id,
        task_id: cleanup.task_id,
        conversation_id: conversationId,
        attempt_id: attemptId,
        transcript_ref: cleanup.transcript_ref,
        transcript_sha256: cleanup.transcript_sha256,
        reason: 'failed',
        expected_session_generation: authority.generation,
        expected_session_sha256: authority.sessionSha256,
      });
    } catch {
      return;
    }
    if (settled.status !== 'discarded' && settled.status !== 'already_missing') {
      return;
    }
    if (runEpoch !== epoch) return;
    await acknowledgeAgentCleanup(conversationId, attemptId, runEpoch, cleanup, {
      ...settled,
      task_id: cleanup.task_id,
      conversation_id: conversationId,
      attempt_id: attemptId,
      transcript_ref: cleanup.transcript_ref,
      transcript_sha256: cleanup.transcript_sha256,
    });
  };

  const acknowledgeAgentCleanup = async (
    conversationId: string,
    attemptId: string,
    runEpoch: number,
    cleanup: AgentTranscriptCleanupV1,
    discardProof: NativeAgentDiscardProofV1,
  ): Promise<CompletionControllerOutcome> => {
    // The atomic final checkpoint stores a reducer-owned cleanup entry in the
    // outbox.  The object supplied by the caller is the pre-dispatch value,
    // so use the live entry for the identity-bound acknowledgement transaction.
    const committedCleanup = (dependencies.chat.getState().agentTranscriptCleanupOutbox ?? [])
      .find(entry => entry.cleanup_id === cleanup.cleanup_id);
    if (committedCleanup === undefined) {
      publish(
        stateFor('blocked', {
          conversationId,
          attemptId,
          failureCode: 'E_AGENT_PERSISTENCE',
        }),
      );
      return outcome('blocked', state);
    }
    const transaction = dependencies.chat.acknowledgeAgentTranscriptCleanupTransaction(
      committedCleanup.cleanup_id,
      committedCleanup,
    );
    if (transaction === null) {
      publish(
        stateFor('blocked', {
          conversationId,
          attemptId,
          failureCode: 'E_AGENT_PERSISTENCE',
        }),
      );
      return outcome('blocked', state);
    }
    const pending: PendingAgentCleanupAcknowledgement = {
      epoch: runEpoch,
      conversationId,
      turnId: cleanup.task_id,
      attemptId,
      cleanup: committedCleanup,
      discardProof,
      transaction,
    };
    pendingAgentCleanup = pending;
    const durability = await safePersist();
    if (runEpoch !== epoch) return outcome('cancelled', state);
    if (durability.status !== 'committed' || durability.snapshot === undefined) {
      publish(
        stateFor('persistence_pending', {
          conversationId,
          turnId: cleanup.task_id,
          attemptId,
          failureCode: 'E_AGENT_PERSISTENCE',
        }),
      );
      return outcome('persistence_pending', state);
    }
    if (!transaction.commit(durability.snapshot, discardProof)) {
      transaction.rollback();
      if (pendingAgentCleanup === pending) pendingAgentCleanup = null;
      publish(
        stateFor('blocked', {
          conversationId,
          turnId: cleanup.task_id,
          attemptId,
          failureCode: 'E_COMPLETION_RESULT_CORRELATION',
        }),
      );
      return outcome('blocked', state);
    }
    if (pendingAgentCleanup === pending) pendingAgentCleanup = null;
    const completedRun = agentRun;
    agentRun = null;
    publish(stateFor('idle'));
    try {
      completedRun?.events.onCommitted?.({
      conversationId,
      turnId: cleanup.task_id,
      attemptId,
      });
    } catch {
      // Completion callbacks cannot change the committed cleanup state.
    }
    return {
      status: 'completed',
      conversationId,
      turnId: cleanup.task_id,
      attemptId,
      code: null,
    };
  };

  finalizeAgent = async (
    conversationId,
    attemptId,
    runEpoch,
    checkpoint,
    journal,
    cleanup,
  ) => {
    if (agentRuntime === undefined || runEpoch !== epoch) return outcome('cancelled', state);
    const located = getConversationAttempt(conversationId, attemptId);
    if (located === null) return outcome('cancelled', state);
    const finalCas = authorityFor(located.attempt, conversationId);
    if (finalCas === null) return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_PERSISTENCE');
    const finalizeOperationId = freshOperationId();
    if (finalizeOperationId === null) return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_PERSISTENCE');
    const request: FinalizeAgentAttemptRequestV2 = {
      schema_version: 2,
      operation_id: finalizeOperationId,
      controller_cas: finalCas,
      committed_checkpoint: checkpoint,
      task_id: located.attempt.turnId,
      conversation_id: conversationId,
      attempt_id: attemptId,
      terminal_reason: journal.phase === 'final_response' ? 'completed' : journal.phase === 'cancelled' ? 'cancelled' : 'failed',
      cleanup_id: cleanup.cleanup_id,
      transcript: journal.transcript,
      root: agentRootForJournal(journal),
    };
    updateAgentRun({ operationId: finalizeOperationId });
    let finalized: FinalizeAgentAttemptResultV2;
    try {
      finalized = await agentRuntime.finalizeAgentAttempt(request);
    } catch (error) {
      updateAgentRun({ operationId: null, cancelTarget: null });
      return await failAgentWithoutNative(conversationId, attemptId, agentFailure(error));
    }
    if (finalized.status === 'conflict') {
      return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_CONFLICT');
    }
    const discardOperationId = freshOperationId();
    if (discardOperationId === null) return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_PERSISTENCE');
    const discardRequest: DiscardAgentAttemptRequestV2 = {
      schema_version: 2,
      operation_id: discardOperationId,
      cleanup_id: cleanup.cleanup_id,
      task_id: located.attempt.turnId,
      conversation_id: conversationId,
      attempt_id: attemptId,
      transcript_ref: journal.transcript.transcript_ref,
      transcript_sha256: journal.transcript.transcript_sha256,
    };
    let discarded: DiscardAgentAttemptResultV2;
    try {
      discarded = await agentRuntime.discardAgentAttempt(discardRequest);
    } catch (error) {
      return await failAgentWithoutNative(conversationId, attemptId, agentFailure(error));
    }
    if (discarded.status !== 'discarded' && discarded.status !== 'already_missing') {
      publish(
        stateFor('persistence_pending', {
          conversationId,
          turnId: located.attempt.turnId,
          attemptId,
          failureCode: 'E_AGENT_PERSISTENCE',
        }),
      );
      return outcome('persistence_pending', state);
    }
    const discardProof: NativeAgentDiscardProofV1 = {
      ...discarded,
      task_id: located.attempt.turnId,
      conversation_id: conversationId,
      attempt_id: attemptId,
      transcript_ref: journal.transcript.transcript_ref,
      transcript_sha256: journal.transcript.transcript_sha256,
    };
    return await acknowledgeAgentCleanup(
      conversationId,
      attemptId,
      runEpoch,
      cleanup,
      discardProof,
    );
  };

  finishAgentNonTerminal = async (
    conversationId,
    attemptId,
    runEpoch,
    request,
    result,
    evidence,
  ) => {
    if (result.status === 'conflict') {
      return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_CONFLICT');
    }
    const located = getConversationAttempt(conversationId, attemptId);
    if (located === null || located.attempt.agent === undefined || located.attempt.agent === null) {
      return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_CONFLICT');
    }
    const current = located.attempt.agent;
    const lineage = current.round_lineage;
    if (lineage === null) return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_CONFLICT');
    const transitionCreatedAt = canonicalNow(dependencies.now);
    const phase: AgentAttemptPhase =
      result.status === 'in_flight'
        ? 'round_in_flight'
        : result.status === 'cancelled'
          ? 'cancelled'
          : result.status === 'failed_retryable'
            ? 'failed'
          : result.status === 'unknown'
            ? 'unknown'
            : 'ambiguous';
    // A failed or cancelled round ends the attempt. The store keeps terminal
    // Agent phases on the atomic final checkpoint -- the ordinary controller
    // checkpoint refuses them outright -- so those two commit through
    // `completeAgentAttempt` with no assistant message, exactly as a settled
    // cancellation does.
    const terminal = phase === 'failed' || phase === 'cancelled';
    const nextJournal: PersistedAgentAttemptJournalV3 = {
      ...copyAgentJournal(current),
      phase,
      controller_generation: current.controller_generation + 1,
      transcript: copyAgentTranscript(result.transcript),
      round_lineage: {
        ...lineage,
        status:
          result.status === 'in_flight'
            ? 'active'
            : result.status === 'cancelled'
              ? 'cancelled'
              : result.status === 'failed_retryable'
                ? 'failed_retryable'
              : result.status,
        native_row_revision: result.result_round_revision,
      },
      updated_at: transitionCreatedAt,
    };
    const eventId = freshOperationId();
    if (eventId === null) {
      return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_PERSISTENCE');
    }
    // The atomic final checkpoint reads one terminal event and matches every
    // field of it, including the failure code the reducer derives, so the
    // two have to agree. A round that failed retryably carries no completion
    // receipt, but it does carry the code native derived from what the
    // provider -- or the transport, before the request ever left -- said.
    // The reducer's `evidenceRoundCauseFor` reads the same value and refuses
    // the same two codes, which belong to other phases.
    const roundCause =
      result.status === 'failed_retryable' &&
      result.failure_code !== 'E_AGENT_CONFLICT' &&
      result.failure_code !== 'E_AGENT_EXECUTION_AMBIGUOUS' &&
      (AGENT_FAILURE_CODES as readonly string[]).includes(result.failure_code)
        ? (result.failure_code as AgentFailureCode)
        : 'E_AGENT_PERSISTENCE';
    const event = terminal
      ? agentEvent(
          attemptId,
          eventId,
          'terminal',
          null,
          null,
          phase === 'cancelled' ? 'cancelled' : 'failed',
          null,
          null,
          null,
          null,
          phase === 'cancelled' ? 'E_AGENT_CANCELLED' : roundCause,
          transitionCreatedAt,
        )
      : agentEvent(
          attemptId,
          eventId,
          'round',
          request.round_index,
          null,
          'running',
          null,
          null,
          null,
          null,
          null,
          transitionCreatedAt,
        );
    // Unknown/ambiguous rounds still own unresolved native evidence. Only a
    // settled failed/cancelled journal may enqueue transcript cleanup; the
    // store deliberately rejects cleanup on the unresolved checkpoints.
    const needsCleanup = terminal;
    const cleanup = needsCleanup
        ? agentCleanupFor(
            conversationId,
            located.attempt,
            nextJournal,
            phase === 'cancelled' ? 'cancelled' : 'failed',
            transitionCreatedAt,
          )
        : undefined;
    if (needsCleanup && cleanup === null) {
      return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_PERSISTENCE');
    }
    const cas = authorityFor(located.attempt, conversationId);
    if (cas === null) return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_PERSISTENCE');
    const transaction =
      terminal && cleanup !== null && cleanup !== undefined
        ? dependencies.chat.completeAgentAttempt({
            cas,
            expectedAttempt: located.attempt,
            journal: nextJournal,
            events: [event],
            evidence,
            assistantMessage: null,
            cleanup,
          })
        : dependencies.chat.failAgentAttempt({
            cas,
            expectedAttempt: located.attempt,
            journal: nextJournal,
            events: [event],
            evidence,
          });
    if (transaction === null) return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_CONFLICT');
    if (phase !== 'round_in_flight' && cleanup !== null && cleanup !== undefined) {
      publish(stateFor('finalizing', { conversationId, turnId: located.attempt.turnId, attemptId, roundId: request.round_id, transportSchemaVersion: request.transport_schema_version }));
    }
    return await safeAgentPersist(
      transaction,
      async committedCheckpoint => {
        if (phase === 'round_in_flight') {
          // Native reported that the round is still in flight. The durable
          // journal now owns that identity; probing/recovery must decide its
          // outcome before any later provider request is attempted.
          publish(stateFor('resume_available', {
            conversationId,
            turnId: located.attempt.turnId,
            attemptId,
            roundId: request.round_id,
            transportSchemaVersion: request.transport_schema_version,
            failureCode: 'E_AGENT_CONFLICT',
          }));
          return outcome('retryable', state);
        }
        if (agentRuntime === undefined) return outcome('cancelled', state);
        // A cancelled/unknown/ambiguous round is never re-executed. Keep the
        // durable terminal candidate visible; recovery owns any later probe.
        if (terminal && cleanup !== null && cleanup !== undefined) {
          const finalized = await finalizeAgent(
            conversationId,
            attemptId,
            runEpoch,
            committedCheckpoint,
            nextJournal,
            cleanup,
            cas,
          );
          // The attempt is settled either way, but a failed round must still
          // say why: reported as completed, the screen cleared its notice
          // and a refusal before dispatch (a PDF past the page cap) showed
          // the person nothing at all.
          if (phase === 'failed' && finalized.status === 'completed') {
            return { ...finalized, status: 'failed', code: roundCause };
          }
          return finalized;
        }
        publish(stateFor('retryable', { conversationId, turnId: located.attempt.turnId, attemptId, roundId: request.round_id, transportSchemaVersion: request.transport_schema_version, failureCode: result.status === 'unknown' ? 'E_AGENT_CONFLICT' : 'E_AGENT_ROUND_AMBIGUOUS' }));
        return outcome('retryable', state);
      },
      runEpoch,
      { conversationId, turnId: located.attempt.turnId, attemptId },
      phase === 'round_in_flight' ? 'checkpoint' : 'cancel',
    );
  };

  prepareAgentBatch = async (
    conversationId,
    attemptId,
    runEpoch,
    request,
    result,
    evidence,
  ) => {
    if (agentRuntime === undefined || result.outcome.kind !== 'tool_batch') {
      return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_TRANSCRIPT');
    }
    const located = getConversationAttempt(conversationId, attemptId);
    if (located === null || located.attempt.agent === undefined || located.attempt.agent === null) {
      return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_CONFLICT');
    }
    const journal = located.attempt.agent;
    const lineage = journal.round_lineage;
    if (lineage === null) return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_CONFLICT');

    // First commit the completed provider round. The native batch preparation
    // is a separate effect and may only observe this committed checkpoint.
    const completedRoundJournal: PersistedAgentAttemptJournalV3 = {
      ...copyAgentJournal(journal),
      phase: 'batch_frozen',
      controller_generation: journal.controller_generation + 1,
      transcript: copyAgentTranscript(result.outcome.transcript),
      round_lineage: {
        ...lineage,
        status: 'completed',
        native_row_revision: result.result_round_revision,
      },
      call_index: null,
      batch: [],
      updated_at: canonicalNow(dependencies.now),
    };
    const completedRoundEventId = freshOperationId();
    const completedRoundCas = authorityFor(located.attempt, conversationId);
    if (completedRoundEventId === null || completedRoundCas === null) {
      return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_PERSISTENCE');
    }
    const completedRoundEvent = agentEvent(
      attemptId,
      completedRoundEventId,
      'round',
      request.round_index,
      null,
      'running',
      null,
      null,
      null,
      null,
      null,
    );
    const completedRoundTransaction = dependencies.chat.checkpointAgentRound({
      cas: completedRoundCas,
      expectedAttempt: located.attempt,
      journal: completedRoundJournal,
      events: [completedRoundEvent],
      evidence,
    });
    if (completedRoundTransaction === null) {
      return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_CONFLICT');
    }
    return await safeAgentPersist(
      completedRoundTransaction,
      async completedCheckpoint => {
        const completed = getConversationAttempt(conversationId, attemptId);
        if (
          completed === null ||
          completed.attempt.agent === undefined ||
          completed.attempt.agent === null ||
          completed.attempt.agent.round_lineage === null
        ) return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_CONFLICT');
        const completedJournal = completed.attempt.agent;
        const completedLineage = completedJournal.round_lineage;
        if (completedLineage === null) {
          return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_CONFLICT');
        }
        const batchOperationId = freshOperationId();
        const batchCas = authorityFor(completed.attempt, conversationId);
        // The batch revision is a native authority, not a count of provider
        // rounds. Keep the last committed batch receipt across the next
        // round; a fresh receipt replaces it below after the new batch
        // checkpoint is durably committed.
        const expectedBatchRevision = agentRun?.batchAuthority?.batchRevision ?? 0;
        if (batchOperationId === null || batchCas === null) {
          return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_PERSISTENCE');
        }
        const batchRequest: PrepareAgentToolBatchRequestV2 = {
          schema_version: 2,
          operation_id: batchOperationId,
          controller_cas: batchCas,
          committed_checkpoint: completedCheckpoint,
          task_id: completed.attempt.turnId,
          conversation_id: conversationId,
          attempt_id: attemptId,
          round_id: completedLineage.round_id,
          round_index: completedJournal.round_index,
          expected_round_revision: result.result_round_revision,
          transcript: result.outcome.transcript,
          root: agentRootForJournal(completedJournal),
          registry_version: completedJournal.tool_registry_version,
          toolset_sha256: completedJournal.toolset_sha256,
          policy_version: completedJournal.policy.policy_version as 'agent-v1',
          expected_batch_revision: expectedBatchRevision,
          expected_reserved_write_bytes: completedJournal.reserved_write_bytes,
        };
        updateAgentRun({ operationId: batchOperationId });
        let batchResult: PrepareAgentToolBatchResultV2;
        try {
          batchResult = await agentRuntime!.prepareAgentToolBatch(batchRequest);
        } catch (error) {
          return await failAgentWithoutNative(conversationId, attemptId, agentFailure(error));
        }
        if (runEpoch !== epoch) return outcome('cancelled', state);
        const batchEvidence = mapEvidence('prepare_agent_tool_batch', batchRequest, batchResult);
        if (batchEvidence === null) return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_TRANSCRIPT');
        if (batchResult.status === 'conflict') {
          return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_CONFLICT');
        }
        if (batchResult.status === 'rejected') {
          return await failAgentWithoutNative(conversationId, attemptId, batchResult.failure_code as AttemptFailureCode);
        }
        if (agentRun !== null) {
          agentRun = {
            ...rememberAgentTokens(agentRun, batchResult.receipt.calls),
            batchAuthority: {
              roundId: batchResult.receipt.round_id,
              roundIndex: batchResult.receipt.round_index,
              batchKind: batchResult.receipt.batch_kind,
              batchRevision: batchResult.receipt.batch_revision,
              manifestSha256: batchResult.receipt.manifest_sha256,
              resultRoundRevision: result.result_round_revision,
            },
          };
        }
        const batchJournal = journalForBatchReceipt(
          completedJournal,
          batchResult.receipt,
          result.result_round_revision,
          canonicalNow(dependencies.now),
          completed.conversation,
        );
        if (batchJournal === null) return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_CONFLICT');
        const batchEvent = agentEvent(
          attemptId,
          batchOperationId,
          'round',
          request.round_index,
          null,
          'running',
          null,
          null,
          null,
          null,
          null,
        );
        // Calls native settled while preparing (refused arguments) get their
        // durable tool rows now, so the cards show the failure and the next
        // round's transcript already carries the feedback.
        const settledEvents: PersistedSessionEventV3[] = [];
        for (const call of batchJournal.batch) {
          if (isConversationGrantBoundCall(call)) {
            const grantEventId = freshOperationId();
            if (grantEventId === null) return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_PERSISTENCE');
            // Preserve the verified grant reference after this batch leaves the
            // journal. This records reuse; it does not ask for another approval.
            settledEvents.push({ ...agentEvent(attemptId, grantEventId, 'approval', request.round_index,
              call.call_id, 'approval', call.safe_summary_key, call.arguments_sha256, null, call.approval_reference, null),
              seq: batchEvent.seq + settledEvents.length + 1 });
          }
          if (call.receipt === null || call.receipt.outcome !== 'failed') continue;
          const callEventId = freshOperationId();
          const resultEventId = freshOperationId();
          if (callEventId === null || resultEventId === null) {
            return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_PERSISTENCE');
          }
          const seqBase = batchEvent.seq + settledEvents.length;
          // The call row records that the call existed and never ran; the
          // result row carries the failure.
          settledEvents.push({
            ...agentEvent(attemptId, callEventId, 'tool_call', request.round_index, call.call_id, 'waiting',
              call.safe_summary_key, call.arguments_sha256, null, null, null),
            seq: seqBase + 1,
          });
          settledEvents.push({
            ...agentEvent(attemptId, resultEventId, 'tool_result', request.round_index, call.call_id, 'failed',
              call.safe_summary_key, call.arguments_sha256, call.receipt.result_sha256, null,
              call.receipt.failure_code as PersistedSessionEventV3['failure_code']),
            seq: seqBase + 2,
          });
        }
        // A batch with nothing left to approve starts its first executable
        // call in the same durable write as the batch receipt.
        const firstIndex = batchJournal.phase === 'approval_pending' ? -1 : batchJournal.batch.findIndex(
          call => call.receipt === null && call.idempotency_key !== null && call.access !== 'durable_deny' &&
            (call.access === 'auto' ||
              ((call.approval_decision === 'allow_once' || call.approval_decision === 'allow_conversation') &&
                call.approval_reference !== null)),
        );
        const firstOperationId = firstIndex >= 0 ? freshOperationId() : null;
        const batchAuthority = agentRun?.batchAuthority;
        if (firstIndex >= 0 && firstOperationId !== null && batchAuthority !== null && batchAuthority !== undefined) {
          const intentCas: AgentRuntimeControllerCASV1 = {
            ...batchCas,
            expected_controller_generation: batchJournal.controller_generation,
            expected_journal_revision: (completed.attempt.journalRevision ?? 0) + 1,
          };
          const intent = intentForCall(conversationId, completed.attempt, batchJournal, firstIndex, intentCas, firstOperationId, batchAuthority);
          const combined = intent === null ? null : dependencies.chat.checkpointAgentBatchAndBeginFirst({
            batch: { cas: batchCas, expectedAttempt: completed.attempt, journal: batchJournal, events: [batchEvent, ...settledEvents], evidence: batchEvidence },
            next: { cas: intentCas, journal: intent.journal, callIndex: firstIndex, events: [], evidence: intent.preflight },
          });
          if (intent !== null && combined !== null) {
            announceExecution(conversationId, completed.attempt, intent.journal, firstIndex, batchJournal.batch[firstIndex]!, firstOperationId);
            return await safeAgentPersist(
              combined,
              async committedCheckpoint => await runExecutionAfterIntent(
                conversationId, attemptId, runEpoch, firstIndex, firstOperationId, intent, committedCheckpoint,
              ),
              runEpoch,
              { conversationId, turnId: completed.attempt.turnId, attemptId },
            );
          }
        }
        const transaction = dependencies.chat.checkpointAgentRound({
          cas: batchCas,
          expectedAttempt: completed.attempt,
          journal: batchJournal,
          events: [batchEvent, ...settledEvents],
          evidence: batchEvidence,
        });
        if (transaction === null) return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_CONFLICT');
        publish(
          stateFor(batchJournal.phase === 'approval_pending' ? 'approval_pending' : 'executing', {
            conversationId,
            turnId: completed.attempt.turnId,
            attemptId,
            roundId: completedLineage.round_id,
            transportSchemaVersion: request.transport_schema_version,
          }),
        );
        return await safeAgentPersist(
          transaction,
          async () => await runAgentBatch(conversationId, attemptId, runEpoch),
          runEpoch,
          { conversationId, turnId: completed.attempt.turnId, attemptId },
        );
      },
      runEpoch,
      { conversationId, turnId: located.attempt.turnId, attemptId },
    );
  };

  type AgentApprovalRequestBundle = {
    readonly approvalId: string;
    readonly conversation: Conversation;
    readonly attempt: TurnAttemptV1;
    readonly journal: PersistedAgentAttemptJournalV3;
    readonly call: PersistedAgentCallJournalV3;
    readonly token: AgentApprovalBindingTokenV2;
    readonly allowedDecisions: readonly (
      | 'denied'
      | 'allow_once'
      | 'allow_conversation'
      | 'cancelled'
    )[];
    readonly request: CompletionAgentApprovalRequest;
  };

  const agentApprovalRequestFor = (
    conversationId: string,
    attemptId: string,
    callIndex: number,
  ): AgentApprovalRequestBundle | null => {
    const located = getConversationAttempt(conversationId, attemptId);
    if (located === null || located.attempt.agent === undefined || located.attempt.agent === null) return null;
    const { conversation, attempt } = located;
    const journal = attempt.agent;
    if (journal === undefined || journal === null) return null;
    const call = journal.batch[callIndex];
    const token = agentTokenByIndex(agentRun, callIndex);
    const approvalId = freshOperationId();
    if (
      call === undefined ||
      token === null ||
      approvalId === null ||
      call.approval_token !== token.token ||
      (call.access !== 'conversation_confirm' && call.access !== 'confirm_once')
    ) return null;
    const allowedDecisions = token.allowed_decisions;
    return {
      approvalId,
      conversation,
      attempt,
      journal,
      call,
      token,
      allowedDecisions,
      request: {
        approvalId,
        conversationId,
        taskId: attempt.turnId,
        attemptId,
        roundId: token.round_id,
        roundIndex: token.round_index,
        batchRevision: token.batch_revision,
        manifestSha256: token.manifest_sha256,
        callIndex,
        callId: call.call_id,
        name: call.name,
        argumentsSha256: call.arguments_sha256,
        preview: agentPreviewByIndex(agentRun, callIndex),
        access: call.access,
        allowedDecisions,
      },
    };
  };

  const bindAgentApproval = async (
    conversationId: string,
    attemptId: string,
    runEpoch: number,
    callIndex: number,
  ): Promise<CompletionControllerOutcome> => {
    if (agentRuntime === undefined) return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_APPROVAL');
    const bundle = agentApprovalRequestFor(conversationId, attemptId, callIndex);
    if (bundle === null) return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_APPROVAL');
    publish(
      stateFor('approval_pending', {
        conversationId,
        turnId: bundle.attempt.turnId,
        attemptId,
        roundId: bundle.token.round_id,
        transportSchemaVersion: bundle.attempt.contextDisposition === 'verified' ? 3 : 2,
      }),
    );
    let rawDecision: unknown;
    try {
      rawDecision = dependencies.requestAgentApproval === undefined
        ? undefined
        : await dependencies.requestAgentApproval(bundle.request);
    } catch {
      rawDecision = undefined;
    }
    if (runEpoch !== epoch) return outcome('cancelled', state);
    const decision = agentSafeApprovalDecision(rawDecision, bundle.allowedDecisions);
    const denyMessage = decision === 'denied' ? agentSafeDenyMessage(rawDecision) : null;
    const committed = await commitAgentApprovalDecision(
      conversationId,
      attemptId,
      runEpoch,
      callIndex,
      bundle.approvalId,
      decision,
      denyMessage,
      true,
    );
    return committed;
  };

  const bindAgentBatchApprovals = async (
    conversationId: string,
    attemptId: string,
    runEpoch: number,
    callIndexes: readonly number[],
  ): Promise<CompletionControllerOutcome> => {
    if (agentRuntime === undefined) return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_APPROVAL');
    const bundles = callIndexes.map(index =>
      agentApprovalRequestFor(conversationId, attemptId, index),
    );
    if (bundles.some(bundle => bundle === null)) {
      return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_APPROVAL');
    }
    const complete = bundles as AgentApprovalRequestBundle[];
    const first = complete[0];
    publish(
      stateFor('approval_pending', {
        conversationId,
        turnId: first.attempt.turnId,
        attemptId,
        roundId: first.token.round_id,
        transportSchemaVersion: first.attempt.contextDisposition === 'verified' ? 3 : 2,
      }),
    );
    let answers: readonly unknown[];
    try {
      answers = dependencies.requestBatchApprovals === undefined
        ? await Promise.all(complete.map(bundle =>
            dependencies.requestAgentApproval === undefined
              ? Promise.resolve(undefined)
              : dependencies.requestAgentApproval(bundle.request)))
        : await dependencies.requestBatchApprovals(complete.map(bundle => bundle.request));
    } catch {
      answers = complete.map(() => undefined);
    }
    if (!Array.isArray(answers) || answers.length !== complete.length) {
      answers = complete.map(() => undefined);
    }
    if (runEpoch !== epoch) return outcome('cancelled', state);
    for (let index = 0; index < complete.length; index += 1) {
      const bundle = complete[index];
      const decision = agentSafeApprovalDecision(answers[index], bundle.allowedDecisions);
      const denyMessage = decision === 'denied' ? agentSafeDenyMessage(answers[index]) : null;
      const committed = await commitAgentApprovalDecision(
        conversationId,
        attemptId,
        runEpoch,
        bundle.call.call_index,
        bundle.approvalId,
        decision,
        denyMessage,
        index === complete.length - 1,
      );
      if (committed.status === 'decision_committed') continue;
      return committed;
    }
    return await runAgentBatch(conversationId, attemptId, runEpoch);
  };

  const commitAgentApprovalDecision = async (
    conversationId: string,
    attemptId: string,
    runEpoch: number,
    callIndex: number,
    approvalId: string,
    decision: 'denied' | 'allow_once' | 'allow_conversation' | 'cancelled',
    denyMessage: string | null,
    resume: boolean,
  ): Promise<CompletionControllerOutcome> => {
    const located = getConversationAttempt(conversationId, attemptId);
    if (located === null || located.attempt.agent === undefined || located.attempt.agent === null) {
      return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_CONFLICT');
    }
    const { conversation, attempt } = located;
    const journal = attempt.agent;
    if (journal === undefined || journal === null) {
      return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_CONFLICT');
    }
    const call = journal.batch[callIndex];
    const token = agentTokenByIndex(agentRun, callIndex);
    if (
      call === undefined ||
      token === null ||
      call.approval_token !== token.token ||
      (call.access !== 'conversation_confirm' && call.access !== 'confirm_once')
    ) return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_APPROVAL');
    // The presented approval id is the preflight event identity and the
    // native bind operation id; it is drawn exactly once per presented call.
    const allowedDecisions = token.allowed_decisions;
    if (!AGENT_UUID.test(approvalId) || !allowedDecisions.includes(decision)) {
      return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_APPROVAL');
    }
    const grant =
      decision === 'allow_conversation'
        ? agentGrantFor(conversation, journal, call) ?? agentNewGrant(conversation, attempt, journal, call)
        : null;
    if (decision === 'allow_conversation' && grant === null) {
      return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_APPROVAL');
    }
    const baseCas = authorityFor(attempt, conversationId);
    if (baseCas === null) return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_PERSISTENCE');
    const nextJournal = journalForApproval(
      journal,
      callIndex,
      decision,
      decision === 'denied' || decision === 'cancelled' ? null : approvalId,
      grant?.grant_id ?? null,
      canonicalNow(dependencies.now),
    );
    const previousGrants = conversation.agentGrants ?? conversation.agent_grants ?? [];
    const grants =
      grant === null || previousGrants.some(item => item.grant_id === grant.grant_id)
        ? previousGrants
        : [...previousGrants, grant];
    const preflight = validateAgentControllerPreflight({
      schema_version: 1,
      source: 'completion_controller',
      kind: 'decide_approval',
      operation_id: approvalId,
      base_cas: baseCas,
      conversation_id: conversationId,
      task_id: attempt.turnId,
      attempt_id: attemptId,
      round_id: token.round_id,
      round_index: token.round_index,
      batch_revision: token.batch_revision,
      manifest_sha256: token.manifest_sha256,
      call_index: callIndex,
      call_id: call.call_id,
      name: call.name,
      arguments_sha256: call.arguments_sha256,
      approval_token: token.token,
      decision,
      source_event_id: approvalId,
      access: call.access,
      workspace_id: journal.root.workspace_id,
      project_id: journal.root.project_id,
      binding_revision: journal.root.workspace_binding_revision,
      root_fingerprint_sha256: journal.root.root_fingerprint_sha256,
      policy_version: 'agent-v1',
      registry_version: journal.tool_registry_version,
      tool_family: agentToolFamily(call.name),
      grant,
    });
    if (preflight === null) return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_APPROVAL');
    const transaction = dependencies.chat.decideAgentApproval({
      cas: baseCas,
      expectedConversation: conversation,
      expectedAttempt: attempt,
      journal: nextJournal,
      grants,
      events: [],
      evidence: preflight,
    });
    if (transaction === null) return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_CONFLICT');
    return await safeAgentPersist(
      transaction,
      async committedCheckpoint => {
        if (runEpoch !== epoch) return outcome('cancelled', state);
        if (decision === 'denied' || decision === 'cancelled') {
          // Native bind is still the idempotent authority record. The Store
          // preflight already closed the decision; no effect is dispatched.
          let deniedResult: BindAgentApprovalResultV2;
          const deniedOperationId = approvalId;
          const deniedCurrent = getConversationAttempt(conversationId, attemptId);
          const deniedCas = deniedCurrent === null
            ? null
            : authorityFor(deniedCurrent.attempt, conversationId);
          if (deniedCas === null) return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_PERSISTENCE');
          const deniedRequest: BindAgentApprovalRequestV2 = {
            schema_version: 2,
            operation_id: deniedOperationId,
            controller_cas: deniedCas,
            committed_checkpoint: committedCheckpoint,
            task_id: attempt.turnId,
            conversation_id: conversationId,
            attempt_id: attemptId,
            round_id: token.round_id,
            round_index: token.round_index,
            manifest_sha256: token.manifest_sha256,
            batch_revision: token.batch_revision,
            call_index: callIndex,
            call_id: call.call_id,
            // The native token is an immutable envelope issued with the batch
            // receipt. Top-level CAS advances with the persisted decision.
            token,
            decision,
            deny_message: decision === 'denied' ? denyMessage : null,
          };
          try {
            deniedResult = await agentRuntime!.bindAgentApproval(deniedRequest);
          } catch {
            return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_APPROVAL');
          }
          if (mapEvidence('bind_agent_approval', deniedRequest, deniedResult) === null) {
            return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_TRANSCRIPT');
          }
          if (decision === 'denied' && deniedResult.status !== 'conflict') {
            // The native bind already settled the denial atomically (feedback,
            // receipt, transcript). Persist that settlement into the schema-9
            // journal so it survives a kill and feeds the next provider round
            // as a structured denied tool result.
            const deniedReceipt = deniedResult.receipt;
            const deniedTranscript = deniedResult.transcript;
            if (deniedReceipt === null || deniedTranscript === null) {
              return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_TRANSCRIPT');
            }
            const settlementCurrent = getConversationAttempt(conversationId, attemptId);
            const settlementCas = settlementCurrent === null
              ? null
              : authorityFor(settlementCurrent.attempt, conversationId);
            if (settlementCas === null || settlementCurrent === null || settlementCurrent.attempt.agent === undefined || settlementCurrent.attempt.agent === null) {
              return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_PERSISTENCE');
            }
            const settlementJournal = journalForDeniedSettlement(
              settlementCurrent.attempt.agent,
              callIndex,
              deniedReceipt,
              deniedTranscript,
              canonicalNow(dependencies.now),
            );
            if (settlementJournal === null) {
              return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_CONFLICT');
            }
            const settlementEvent = agentEvent(
              attemptId,
              freshOperationId() ?? deniedOperationId,
              'tool_result',
              token.round_index,
              call.call_id,
              'denied',
              `agent.${call.name}`,
              call.arguments_sha256,
              deniedReceipt.result_sha256,
              null,
              'E_AGENT_DENIED_BY_USER',
            );
            const settlementConversation = getConversationAttempt(conversationId, attemptId)?.conversation;
            if (settlementConversation === undefined) {
              return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_CONFLICT');
            }
            const settlementTransaction = dependencies.chat.checkpointAgentApproval({
              cas: settlementCas,
              expectedConversation: settlementConversation,
              expectedAttempt: settlementCurrent.attempt,
              journal: settlementJournal,
              grants: settlementConversation.agentGrants ?? settlementConversation.agent_grants ?? [],
              events: [settlementEvent],
              evidence: mapEvidence('bind_agent_approval', deniedRequest, deniedResult)!,
            });
            if (settlementTransaction === null) {
              return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_CONFLICT');
            }
            return await safeAgentPersist(
              settlementTransaction,
              async () => resume
                ? await runAgentBatch(conversationId, attemptId, runEpoch)
                : outcome('decision_committed', state),
              runEpoch,
              { conversationId, turnId: attempt.turnId, attemptId },
            );
          }
          return resume
            ? await runAgentBatch(conversationId, attemptId, runEpoch)
            : outcome('decision_committed', state);
        }
        // Reuse the approval preflight event identity for the native bind. The
        // post-checkpoint ordering guard intentionally requires that marker to
        // already be durable before accepting bind evidence.
        const bindOperationId = approvalId;
        const current = getConversationAttempt(conversationId, attemptId);
        if (current === null || current.attempt.agent === undefined || current.attempt.agent === null) {
          return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_PERSISTENCE');
        }
        const currentJournal = current.attempt.agent;
        const bindCas = authorityFor(current.attempt, conversationId);
        if (bindCas === null) return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_PERSISTENCE');
        const bindRequest: BindAgentApprovalRequestV2 = {
          schema_version: 2,
          operation_id: bindOperationId,
          controller_cas: bindCas,
          committed_checkpoint: committedCheckpoint,
          task_id: current.attempt.turnId,
          conversation_id: conversationId,
          attempt_id: attemptId,
          round_id: token.round_id,
          round_index: token.round_index,
          manifest_sha256: token.manifest_sha256,
          batch_revision: token.batch_revision,
          call_index: callIndex,
          call_id: call.call_id,
          // Keep the native batch envelope byte-for-byte intact. Native binds
          // it against the newer top-level CAS and committed decision journal.
          token,
          decision,
          deny_message: null,
        };
        updateAgentRun({ operationId: bindOperationId });
        let bindResult: BindAgentApprovalResultV2;
        try {
          bindResult = await agentRuntime!.bindAgentApproval(bindRequest);
        } catch (error) {
          return await failAgentWithoutNative(conversationId, attemptId, agentFailure(error));
        }
        const bindEvidence = mapEvidence('bind_agent_approval', bindRequest, bindResult);
        if (bindEvidence === null || bindResult.status === 'conflict') {
          return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_APPROVAL');
        }
        const afterCall = currentJournal.batch[callIndex];
        if (afterCall === undefined) return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_CONFLICT');
        const postJournalBase: PersistedAgentAttemptJournalV3 = {
          ...copyAgentJournal(currentJournal),
          controller_generation: currentJournal.controller_generation + 1,
          phase: 'batch_frozen',
          call_index: currentJournal.batch.findIndex(candidate => candidate.receipt === null),
          updated_at: canonicalNow(dependencies.now),
        };
        const boundCall = postJournalBase.batch[callIndex];
        const postJournal: PersistedAgentAttemptJournalV3 = boundCall === undefined
          ? postJournalBase
          : {
              ...postJournalBase,
              batch: postJournalBase.batch.map((candidate, index) =>
                index === callIndex
                  ? { ...candidate, approval_reference: bindResult.approval_reference }
                  : candidate,
              ),
            };
        const approvalEvent = agentEvent(
          attemptId,
          freshOperationId() ?? bindRequest.operation_id,
          'approval',
          bindRequest.round_index,
          bindRequest.call_id,
          'approval',
          `agent.${call.name}`,
          call.arguments_sha256,
          null,
          bindResult.approval_reference,
          null,
        );
        const postCas = authorityFor(current.attempt, conversationId);
        if (postCas === null) return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_PERSISTENCE');
        const postConversation = getConversationAttempt(conversationId, attemptId)?.conversation;
        if (postConversation === undefined) return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_CONFLICT');
        const postTransaction = dependencies.chat.checkpointAgentApproval({
          cas: postCas,
          expectedConversation: postConversation,
          expectedAttempt: current.attempt,
          journal: postJournal,
          grants: postConversation.agentGrants ?? postConversation.agent_grants ?? [],
          events: [approvalEvent],
          evidence: bindEvidence,
        });
        if (postTransaction === null) return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_CONFLICT');
        return await safeAgentPersist(
          postTransaction,
          async () => resume
            ? await runAgentBatch(conversationId, attemptId, runEpoch)
            : outcome('decision_committed', state),
          runEpoch,
          { conversationId, turnId: current.attempt.turnId, attemptId },
        );
      },
      runEpoch,
      { conversationId, turnId: attempt.turnId, attemptId },
    );
  };

  const executeAgentCall = async (
    conversationId: string,
    attemptId: string,
    runEpoch: number,
    callIndex: number,
  ): Promise<CompletionControllerOutcome> => {
    if (agentRuntime === undefined) return await failAgentWithoutNative(conversationId, attemptId, 'E_COMPLETION_NATIVE');
    const located = getConversationAttempt(conversationId, attemptId);
    if (located === null || located.attempt.agent === undefined || located.attempt.agent === null) return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_CONFLICT');
    const { attempt } = located;
    const journal = attempt.agent;
    if (journal === undefined || journal === null) {
      return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_CONFLICT');
    }
    const call = journal.batch[callIndex];
    if (call === undefined || call.receipt !== null || call.idempotency_key === null) return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_CONFLICT');
    const cas = authorityFor(attempt, conversationId);
    const checkpoint = agentCheckpointForJournal(attempt);
    const operationId = freshOperationId();
    if (cas === null || checkpoint === null || operationId === null) return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_PERSISTENCE');
    const batchAuthority = agentRun?.batchAuthority;
    if (
      batchAuthority === null ||
      batchAuthority === undefined ||
      batchAuthority.roundId !== journal.round_lineage?.round_id ||
      batchAuthority.roundIndex !== journal.round_index ||
      batchAuthority.resultRoundRevision !== journal.round_lineage?.native_row_revision
    ) return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_CONFLICT');
    const intent = intentForCall(conversationId, attempt, journal, callIndex, cas, operationId, batchAuthority);
    if (intent === null) return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_CONFLICT');
    const transaction = dependencies.chat.insertAgentExecutionIntent({
      cas,
      expectedAttempt: attempt,
      journal: intent.journal,
      callIndex,
      events: [],
      evidence: intent.preflight,
    });
    if (transaction === null) return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_CONFLICT');
    announceExecution(conversationId, attempt, journal, callIndex, call, operationId);
    return await safeAgentPersist(
      transaction,
      async committedCheckpoint => await runExecutionAfterIntent(
        conversationId, attemptId, runEpoch, callIndex, operationId, intent, committedCheckpoint,
      ),
      runEpoch,
      { conversationId, turnId: attempt.turnId, attemptId },
    );
  };

  /** Launch-marker material for one batch call: the validated preflight and the intent journal. */
  const intentForCall = (
    conversationId: string,
    attempt: TurnAttemptV1,
    journal: PersistedAgentAttemptJournalV3,
    callIndex: number,
    cas: AgentRuntimeControllerCASV1,
    operationId: string,
    batchAuthority: NonNullable<AgentRun['batchAuthority']>,
  ): ExecutionIntent | null => {
    const call = journal.batch[callIndex];
    if (call === undefined || call.receipt !== null || call.idempotency_key === null) return null;
    const batchKind = batchAuthority.batchKind;
    const manifestSha256 = batchAuthority.manifestSha256;
    const approvalReference = call.access === 'auto' ? null : call.approval_reference;
    const preflight = validateAgentControllerPreflight({
      schema_version: 1,
      source: 'completion_controller',
      kind: 'begin_execution',
      operation_id: operationId,
      base_cas: cas,
      conversation_id: conversationId,
      task_id: attempt.turnId,
      attempt_id: attempt.attemptId,
      round_id: journal.round_lineage?.round_id ?? '',
      round_index: journal.round_index,
      batch_kind: batchKind,
      batch_revision: batchAuthority.batchRevision,
      manifest_sha256: manifestSha256,
      call_index: callIndex,
      call_id: call.call_id,
      name: call.name,
      arguments_sha256: call.arguments_sha256,
      idempotency_key: call.idempotency_key,
      expected_execution_revision: call.native_row_revision ?? 1,
      transcript: journal.transcript,
      root: agentRootForJournal(journal),
      access: call.access === 'durable_deny' ? 'auto' : call.access,
      approval_state: call.access === 'auto' ? 'not_required' : 'bound',
      approval_reference: approvalReference,
      source_event_id: operationId,
    });
    if (preflight === null) return null;
    return {
      preflight,
      journal: journalForExecutionIntent(journal, callIndex, canonicalNow(dependencies.now)),
      batchKind,
      manifestSha256,
      batchRevision: batchAuthority.batchRevision,
      approvalReference,
    };
  };

  const announceExecution = (
    conversationId: string,
    attempt: TurnAttemptV1,
    journal: PersistedAgentAttemptJournalV3,
    callIndex: number,
    call: PersistedAgentAttemptJournalV3['batch'][number],
    operationId: string,
  ): void => {
    updateAgentRun({ operationId, cancelTarget: { schema_version: 2, kind: 'tool', task_id: attempt.turnId, attempt_id: attempt.attemptId, round_id: journal.round_lineage?.round_id ?? '', round_index: journal.round_index, call_index: callIndex, call_id: call.call_id, idempotency_key: call.idempotency_key ?? '' } });
    publish(stateFor('executing', { conversationId, turnId: attempt.turnId, attemptId: attempt.attemptId, roundId: journal.round_lineage?.round_id ?? null, transportSchemaVersion: attempt.contextDisposition === 'verified' ? 3 : 2 }));
  };

  /** Everything after a durable execution intent: run the native tool and persist its outcome. */
  const runExecutionAfterIntent = async (
    conversationId: string,
    attemptId: string,
    runEpoch: number,
    callIndex: number,
    operationId: string,
    intent: ExecutionIntent,
    committedCheckpoint: AgentRuntimeCommittedCheckpointV1,
  ): Promise<CompletionControllerOutcome> => {
    const { batchKind, manifestSha256, approvalReference } = intent;
        const current = getConversationAttempt(conversationId, attemptId);
        if (current === null || current.attempt.agent === undefined || current.attempt.agent === null || current.attempt.agent.round_lineage === null) return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_CONFLICT');
        const currentJournal = current.attempt.agent;
        const currentLineage = currentJournal.round_lineage;
        const call = currentJournal.batch[callIndex];
        if (currentLineage === null || call === undefined || call.idempotency_key === null) {
          return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_CONFLICT');
        }
        const executeRequest: ExecuteAgentToolRequestV2 = {
          schema_version: 2,
          operation_id: operationId,
          controller_cas: authorityFor(current.attempt, conversationId)!,
          committed_checkpoint: committedCheckpoint,
          task_id: current.attempt.turnId,
          conversation_id: conversationId,
          attempt_id: attemptId,
          round_id: currentLineage.round_id,
          round_index: currentJournal.round_index,
          batch_kind: batchKind,
          manifest_sha256: manifestSha256,
          expected_batch_revision: intent.batchRevision,
          call_index: callIndex,
          call_id: call.call_id,
          name: call.name,
          arguments_sha256: call.arguments_sha256,
          idempotency_key: call.idempotency_key,
          expected_execution_revision: call.native_row_revision ?? 1,
          transcript: currentJournal.transcript,
          root: agentRootForJournal(currentJournal),
          approval_reference: approvalReference,
        };
        const executionEvent = (dependencies.chat.getState().sessionEvents ?? [])
          .find(event => event.event_id === executeRequest.operation_id);
        const resultEventId = freshOperationId();
        const terminalEventId = freshOperationId();
        if (executionEvent === undefined || resultEventId === null || terminalEventId === null) {
          return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_PERSISTENCE');
        }
        updateAgentRun({ operationId: executeRequest.operation_id });
        let executeResult: ExecuteAgentToolResultV2;
        try {
          executeResult = await agentRuntime!.executeAgentTool(executeRequest);
        } catch (error) {
          if (runEpoch !== epoch || agentCancellationInFlight === runEpoch) return outcome('cancelled', state);
          return await failAgentWithoutNative(conversationId, attemptId, agentFailure(error));
        }
        if (runEpoch !== epoch || agentCancellationInFlight === runEpoch) return outcome('cancelled', state);
        const executeEvidence = mapEvidence('execute_agent_tool', executeRequest, executeResult);
        if (executeEvidence === null || executeResult.status === 'conflict') return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_EXECUTION_AMBIGUOUS');
        const safeExecuteResult = executeResult as AgentExecuteResult;
        // Capture the discriminant before the receipt transaction narrows the
        // native union; the post-commit branch must still handle unknown and
        // ambiguous outcomes without issuing another effect.
        const executeStatus: ExecuteAgentToolResultV2['status'] = executeResult.status;
        const resultCreatedAt = canonicalNow(dependencies.now);
        const resultJournal = journalForToolResult(currentJournal, safeExecuteResult, resultCreatedAt);
        if (resultJournal === null) return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_TRANSCRIPT');
        const resultEvent =
          executeStatus === 'running' || executeStatus === 'cancel_requested'
            ? agentEvent(
                attemptId,
                resultEventId,
                'tool_call',
                executeRequest.round_index,
                executeRequest.call_id,
                'running',
                `agent.${executeRequest.name}`,
                executeRequest.arguments_sha256,
                null,
                null,
                null,
                resultCreatedAt,
              )
            : agentEvent(
                attemptId,
                resultEventId,
                'tool_result',
                executeRequest.round_index,
                executeRequest.call_id,
                executeStatus === 'unknown'
                  ? 'unknown'
                  : safeExecuteResult.receipt?.outcome ?? 'failed',
                `agent.${executeRequest.name}`,
                executeRequest.arguments_sha256,
                safeExecuteResult.receipt?.result_sha256 ?? null,
                safeExecuteResult.receipt?.approval_reference ?? approvalReference,
                executeStatus === 'unknown'
                  ? 'E_AGENT_CONFLICT'
                  : (safeExecuteResult.receipt?.failure_code ?? null) as PersistedSessionEventV3['failure_code'],
                resultCreatedAt,
              );
        const resultCas = authorityFor(current.attempt, conversationId);
        if (resultCas === null) return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_PERSISTENCE');
        if (executeStatus === 'cancelled') {
          const cleanup = agentCleanupFor(
            conversationId,
            current.attempt,
            resultJournal,
            'cancelled',
            resultCreatedAt,
          );
          if (cleanup === null) return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_PERSISTENCE');
          const terminalEvent = {
            ...agentEvent(
              attemptId,
              terminalEventId,
              'terminal',
              null,
              null,
              'cancelled',
              null,
              null,
              null,
              null,
              'E_AGENT_CANCELLED',
              resultCreatedAt,
            ),
            seq: resultEvent.seq + 1,
          };
          const terminalTransaction = dependencies.chat.completeAgentAttempt({
            cas: resultCas,
            expectedAttempt: current.attempt,
            journal: resultJournal,
            events: [executionEvent, resultEvent, terminalEvent],
            evidence: executeEvidence,
            assistantMessage: null,
            cleanup,
          });
          if (terminalTransaction === null) return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_CONFLICT');
          publish(stateFor('finalizing', {
            conversationId,
            turnId: current.attempt.turnId,
            attemptId,
            roundId: executeRequest.round_id,
            transportSchemaVersion: executeRequest.batch_kind === 'write_batch' ? 3 : 2,
          }));
          return await safeAgentPersist(
            terminalTransaction,
            async finalCheckpoint => await finalizeAgent(
              conversationId,
              attemptId,
              runEpoch,
              finalCheckpoint,
              resultJournal,
              cleanup,
              resultCas,
            ),
            runEpoch,
            { conversationId, turnId: current.attempt.turnId, attemptId },
            'final',
          );
        }
        const terminalResult =
            executeStatus === 'completed' || executeStatus === 'failed' || executeStatus === 'denied';
        // One durable write for "call k finished, call k+1 starts" when the
        // next call needs no approval: the result, the cursor advance and the
        // next launch marker are validated by their own reducers against the
        // intermediate states, exactly as three checkpoints would be.
        if (terminalResult) {
          const combined = combinedResultAndNextIntent(
            conversationId, current.attempt, resultJournal, callIndex, resultCas,
            safeExecuteResult.receipt! as unknown as StoreAgentToolReceiptV1,
            [executionEvent, resultEvent], executeEvidence,
          );
          if (combined !== null) {
            announceExecution(conversationId, current.attempt, combined.intent.journal, combined.nextCallIndex, combined.nextCall, combined.operationId);
            return await safeAgentPersist(
              combined.transaction,
              async nextCheckpoint => await runExecutionAfterIntent(
                conversationId, attemptId, runEpoch, combined.nextCallIndex, combined.operationId,
                combined.intent, nextCheckpoint,
              ),
              runEpoch,
              { conversationId, turnId: current.attempt.turnId, attemptId },
            );
          }
        }
        const resultTransaction = terminalResult
            ? dependencies.chat.recordAgentToolResult({ cas: resultCas, expectedAttempt: current.attempt, journal: resultJournal, callIndex, receipt: safeExecuteResult.receipt! as unknown as StoreAgentToolReceiptV1, events: [executionEvent, resultEvent], evidence: executeEvidence })
            : dependencies.chat.checkpointAgentAttempt({ cas: resultCas, expectedAttempt: current.attempt, journal: resultJournal, events: [executionEvent, resultEvent], evidence: executeEvidence });
        if (resultTransaction === null) return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_CONFLICT');
        return await safeAgentPersist(
          resultTransaction,
          async () => {
            if (executeStatus === 'unknown' || executeStatus === 'ambiguous') {
              publish(stateFor('retryable', { conversationId, turnId: current.attempt.turnId, attemptId, roundId: executeRequest.round_id, transportSchemaVersion: executeRequest.batch_kind === 'write_batch' ? 3 : 2, failureCode: safeExecuteResult.status === 'ambiguous' ? 'E_AGENT_EXECUTION_AMBIGUOUS' : 'E_AGENT_CONFLICT' }));
              return outcome('retryable', state);
            }
            const latest = getConversationAttempt(conversationId, attemptId);
            const nextCallIndex = latest?.attempt.agent === undefined || latest?.attempt.agent === null
              ? -1
              : latest.attempt.agent.batch.findIndex(
                  candidate =>
                    candidate.receipt === null &&
                    (candidate.access === 'auto' ||
                      candidate.approval_decision === 'allow_once' ||
                      candidate.approval_decision === 'allow_conversation'),
                );
            if (
              latest !== null &&
              latest.attempt.agent !== undefined &&
              latest.attempt.agent !== null &&
              nextCallIndex >= 0
            ) {
              const advanceCas = authorityFor(latest.attempt, conversationId);
              const nextCall = latest.attempt.agent.batch[nextCallIndex];
              const advanceJournal: PersistedAgentAttemptJournalV3 = {
                ...copyAgentJournal(latest.attempt.agent),
                phase:
                  nextCall !== undefined &&
                  nextCall.access !== 'auto' &&
                  nextCall.access !== 'durable_deny' &&
                  nextCall.approval_decision === 'pending'
                    ? 'approval_pending'
                    : 'batch_frozen',
                controller_generation: latest.attempt.agent.controller_generation + 1,
                call_index: nextCallIndex,
                updated_at: canonicalNow(dependencies.now),
              };
              const advanceTransaction =
                advanceCas === null
                  ? null
                  : dependencies.chat.advanceAgentCall({
                      cas: advanceCas,
                      expectedAttempt: latest.attempt,
                      journal: advanceJournal,
                    });
              if (advanceTransaction === null) {
                return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_CONFLICT');
              }
              return await safeAgentPersist(
                advanceTransaction,
                async () => await runAgentBatch(conversationId, attemptId, runEpoch),
                runEpoch,
                { conversationId, turnId: latest.attempt.turnId, attemptId },
              );
            }
            return await runAgentBatch(conversationId, attemptId, runEpoch);
          },
          runEpoch,
          { conversationId, turnId: current.attempt.turnId, attemptId },
        );
  };

  /**
   * Builds the combined "result k + advance + intent k+1" transaction, or null
   * when the next call is not immediately executable (needs approval, is
   * denied, or the batch is finished) so the caller keeps the separate path.
   */
  const combinedResultAndNextIntent = (
    conversationId: string,
    attempt: TurnAttemptV1,
    resultJournal: PersistedAgentAttemptJournalV3,
    callIndex: number,
    resultCas: AgentRuntimeControllerCASV1,
    toolReceipt: StoreAgentToolReceiptV1,
    events: readonly PersistedSessionEventV3[],
    evidence: NonNullable<ReturnType<typeof mapEvidence>>,
  ): {
    readonly transaction: AgentCheckpointTransaction;
    readonly nextCallIndex: number;
    readonly nextCall: PersistedAgentAttemptJournalV3['batch'][number];
    readonly operationId: string;
    readonly intent: ExecutionIntent;
  } | null => {
    const batchAuthority = agentRun?.batchAuthority;
    if (batchAuthority === null || batchAuthority === undefined) return null;
    let nextCallIndex = callIndex + 1;
    while (
      nextCallIndex < resultJournal.batch.length &&
      resultJournal.batch[nextCallIndex]!.receipt !== null
    ) nextCallIndex += 1;
    const nextCall = resultJournal.batch[nextCallIndex];
    if (
      nextCall === undefined ||
      nextCall.receipt !== null ||
      nextCall.idempotency_key === null ||
      nextCall.access === 'durable_deny' ||
      !(nextCall.access === 'auto' ||
        ((nextCall.approval_decision === 'allow_once' || nextCall.approval_decision === 'allow_conversation') &&
          nextCall.approval_reference !== null))
    ) return null;
    const advanceJournal: PersistedAgentAttemptJournalV3 = {
      ...copyAgentJournal(resultJournal),
      phase: 'batch_frozen',
      controller_generation: resultJournal.controller_generation + 1,
      call_index: nextCallIndex,
      updated_at: canonicalNow(dependencies.now),
    };
    const operationId = freshOperationId();
    if (operationId === null) return null;
    // The launch marker binds to the state two transitions ahead of the
    // committed one: same session authority, journal revision and controller
    // generation advanced by the result and the cursor move.
    const intentCas: AgentRuntimeControllerCASV1 = {
      ...resultCas,
      expected_controller_generation: advanceJournal.controller_generation,
      expected_journal_revision: (attempt.journalRevision ?? 0) + 2,
    };
    const intent = intentForCall(conversationId, attempt, advanceJournal, nextCallIndex, intentCas, operationId, batchAuthority);
    if (intent === null) return null;
    const transaction = dependencies.chat.recordAgentToolResultAndBeginNext({
      result: { cas: resultCas, expectedAttempt: attempt, journal: resultJournal, callIndex, receipt: toolReceipt, events, evidence },
      advance: { journal: advanceJournal },
      next: { cas: intentCas, journal: intent.journal, callIndex: nextCallIndex, events: [], evidence: intent.preflight },
    });
    return transaction === null ? null : { transaction, nextCallIndex, nextCall, operationId, intent };
  };

  const runAgentBatchImpl = async (
    conversationId: string,
    attemptId: string,
    runEpoch: number,
  ): Promise<CompletionControllerOutcome> => {
    if (agentRuntime === undefined || runEpoch !== epoch) return outcome('cancelled', state);
    const located = getConversationAttempt(conversationId, attemptId);
    if (located === null || located.attempt.agent === undefined || located.attempt.agent === null) return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_CONFLICT');
    const journal = located.attempt.agent;
    const pendingApprovalIndexes: number[] = [];
    journal.batch.forEach((call, index) => {
      if (
        call.receipt === null &&
        call.access !== 'auto' &&
        call.access !== 'durable_deny' &&
        call.approval_decision === 'pending'
      ) {
        pendingApprovalIndexes.push(index);
      }
    });
    if (pendingApprovalIndexes.length === 1) {
      return await bindAgentApproval(
        conversationId,
        attemptId,
        runEpoch,
        pendingApprovalIndexes[0],
      );
    }
    if (pendingApprovalIndexes.length > 1) {
      // Several gated calls freeze in one approval list with per-item
      // decisions and a single commit; every decision is still persisted as
      // its own approval checkpoint before any execution.
      return await bindAgentBatchApprovals(
        conversationId,
        attemptId,
        runEpoch,
        pendingApprovalIndexes,
      );
    }
    const index = journal.batch.findIndex(call => call.receipt === null && (call.access === 'auto' || call.approval_decision === 'allow_once' || call.approval_decision === 'allow_conversation'));
    if (index >= 0) return await executeAgentCall(conversationId, attemptId, runEpoch, index);
    if (journal.phase === 'tool_result_pending' && journal.batch.length > 0 && journal.batch.every(call => call.receipt !== null)) {
      return await runAgentRound(conversationId, attemptId, runEpoch);
    }
    if (journal.phase === 'batch_frozen' && journal.batch.every(call => call.receipt !== null || call.approval_decision === 'denied' || call.approval_decision === 'cancelled')) {
      return await runAgentRound(conversationId, attemptId, runEpoch);
    }
    return outcome('retryable', state);
  };

  runAgentBatch = runAgentBatchImpl;

  const runLegacyPrepared = async (
    conversationId: string,
    turnId: string,
    attemptId: string,
    events: CompletionControllerEvents,
    runEpoch: number,
  ): Promise<CompletionControllerOutcome> => {
    const conversation = dependencies.chat.getState().conversations[conversationId];
    const prepared = conversation?.attempts.find(
      candidate => candidate.attemptId === attemptId,
    );
    if (prepared === undefined || runEpoch !== epoch) {
      return outcome('cancelled', state);
    }
    const roundId = dependencies.createRoundId();
    const roundIndex = prepared.rounds.length;
    const transportSchemaVersion =
      prepared.contextDisposition === 'verified' ? 3 : 2;
    publish(
      stateFor('starting', {
        conversationId,
        turnId,
        attemptId,
        roundId,
        transportSchemaVersion,
      }),
    );
    if (
      !dependencies.chat.startAttemptRound(
        conversationId,
        attemptId,
        roundId,
        roundIndex,
      )
    ) {
      return await persistFailure(
        conversationId,
        attemptId,
        prepared.contextDisposition === 'verified'
          ? 'E_ATTEMPT_CONTEXT_REQUIRED'
          : 'E_COMPLETION_RESULT_CORRELATION',
      );
    }
    active = {
      epoch: runEpoch,
      conversationId,
      turnId,
      attemptId,
      roundId,
      transportSchemaVersion,
      events,
    };
    const sendingDurability = await safePersist();
    if (runEpoch !== epoch) return outcome('cancelled', state);
    if (sendingDurability.status !== 'committed') {
      active = null;
      return await persistFailure(
        conversationId,
        attemptId,
        'E_ATTEMPT_PERSISTENCE',
      );
    }
    const sendingConversation =
      dependencies.chat.getState().conversations[conversationId];
    const attempt = sendingConversation?.attempts.find(
      candidate => candidate.attemptId === attemptId,
    );
    const history =
      attempt === undefined
        ? null
        : visibleHistory(dependencies.chat, conversationId, attempt);
    if (
      attempt === undefined ||
      history === null ||
      attempt.activeRound?.roundId !== roundId
    ) {
      active = null;
      return await persistFailure(
        conversationId,
        attemptId,
        'E_COMPLETION_RESULT_CORRELATION',
      );
    }
    publish(
      stateFor('sending', {
        conversationId,
        turnId,
        attemptId,
        roundId,
        transportSchemaVersion,
      }),
    );
    let result: CompleteRoundV2Result | CompleteRoundV3Result;
    try {
      if (transportSchemaVersion === 3) {
        const binding = attempt.projectContext;
        if (binding === null) {
          throw { code: 'E_COMPLETION_CONTEXT_INVALID' };
        }
        result = await dependencies.completeRoundV3({
          schemaVersion: 3,
          harnessId: attempt.harnessId,
          turnId,
          attemptId,
          roundId,
          roundIndex,
          model: attempt.modelId,
          thinkingMode: attempt.thinkingMode,
          visibleHistory: history,
          roundTranscript: [],
          tools: [],
          projectContext: {
            schemaVersion: 1,
            snapshotId: binding.snapshotId,
            consentReceiptId: binding.consentReceiptId,
            conversationId: binding.runtimeContextId,
            projectId: binding.projectId,
            provider: binding.provider,
            policy: binding.policy,
          },
        });
      } else {
        result = await dependencies.completeRoundV2({
          schemaVersion: 2,
          harnessId: attempt.harnessId,
          turnId,
          attemptId,
          roundId,
          roundIndex,
          model: attempt.modelId,
          thinkingMode: attempt.thinkingMode,
          visibleHistory: history,
          roundTranscript: [],
          tools: [],
          projectContext: null,
        });
      }
    } catch (error) {
      if (runEpoch !== epoch) return outcome('cancelled', state);
      active = null;
      return await persistFailure(conversationId, attemptId, errorCode(error));
    }
    if (runEpoch !== epoch) return outcome('cancelled', state);
    active = null;
    if (!dependencies.chat.recordAttemptRound(conversationId, attemptId, receipt(result))) {
      return await persistFailure(
        conversationId,
        attemptId,
        'E_COMPLETION_RESULT_CORRELATION',
      );
    }
    if (
      result.finish_reason === 'tool_calls' ||
      result.finish_reason === 'content_filter' ||
      result.tool_calls.length > 0
    ) {
      return await persistFailure(
        conversationId,
        attemptId,
        'E_COMPLETION_FINISH_RELATION',
      );
    }
    if (result.text.trim().length === 0) {
      return await persistFailure(
        conversationId,
        attemptId,
        'E_COMPLETION_EMPTY_RESPONSE',
      );
    }
    if (result.reasoning.length > 0) {
      emitSessionEvent(attemptId, 'assistant_reasoning', result.reasoning);
    }
    emitSessionEvent(attemptId, 'assistant_text', result.text);
    const assistantId = dependencies.chat.completeAttempt(
      conversationId,
      attemptId,
      result.text,
      {
        metadata: {
          modelId: result.model,
          latencyMs: result.latency_ms,
          finishReason: result.finish_reason,
          ...(result.reasoning.length === 0
            ? {}
            : { reasoning: result.reasoning }),
        },
      },
    );
    if (assistantId === null) {
      return await persistFailure(
        conversationId,
        attemptId,
        'E_COMPLETION_RESULT_CORRELATION',
      );
    }
    pendingCommit = { conversationId, turnId, attemptId, events };
    publish(
      stateFor('finalizing', {
        conversationId,
        turnId,
        attemptId,
      }),
    );
    const finalDurability = await safePersist();
    if (runEpoch !== epoch) return outcome('cancelled', state);
    if (finalDurability.status !== 'committed') {
      publish(
        stateFor('commit_pending', {
          conversationId,
          turnId,
          attemptId,
          failureCode: 'E_ATTEMPT_PERSISTENCE',
        }),
      );
      return outcome('commit_pending', state);
    }
    const committed = pendingCommit;
    pendingCommit = null;
    publish(stateFor('idle'));
    if (committed !== null) notifyCommitted(committed);
    return {
      status: 'completed',
      conversationId,
      turnId,
      attemptId,
      code: null,
    };
  };

  const runPrepared = async (
    conversationId: string,
    turnId: string,
    attemptId: string,
    events: CompletionControllerEvents,
    runEpoch: number,
  ): Promise<CompletionControllerOutcome> => {
    const runtimeAvailable = agentRuntime !== undefined && agentAvailable();
    if (runtimeAvailable) {
      const located = getConversationAttempt(conversationId, attemptId);
      const attempt = located?.attempt;
      const conversation = located?.conversation;
      const agentEligible =
        attempt !== undefined &&
        conversation !== undefined &&
        attempt.contextDisposition !== 'explicit_without_context' &&
        (conversation.workspaceId !== null ||
          conversation.projectId !== null ||
          conversation.workspaceBinding !== null);
      if (agentEligible) {
        if (attempt.agent == null &&
            (dependencies.chat.getState().sessionEvents?.length ?? 0) + AGENT_EVENT_START_RESERVE > MAX_SESSION_EVENT_ROWS) {
          publish(stateFor('blocked', { conversationId, turnId, attemptId, failureCode: 'E_AGENT_EVENT_CAPACITY' }));
          return outcome('blocked', state);
        }
        return await runAgentPrepared(
          conversationId,
          turnId,
          attemptId,
          events,
          runEpoch,
        );
      }
    }
    return await runLegacyPrepared(
      conversationId,
      turnId,
      attemptId,
      events,
      runEpoch,
    );
  };

  const continuePreparation = async (
    transaction: PreparedTurnTransaction,
    conversationId: string,
    events: CompletionControllerEvents,
    runEpoch: number,
    durability: SessionDurabilityResult,
  ): Promise<CompletionControllerOutcome> => {
    if (runEpoch !== epoch) {
      pendingPreparation = null;
      if (durability.status === 'not_committed') {
        transaction.rollback();
        lastCancellationCommitted = true;
        publish(stateFor('idle'));
        return {
          status: 'cancelled',
          conversationId,
          turnId: transaction.turnId,
          attemptId: transaction.attemptId,
          code: null,
        };
      }
      transaction.commit();
      const preparedWasDurable = durability.status === 'committed';
      if (preparedWasDurable) {
        notifyPrepared(events, transaction, conversationId);
      }
      if (
        !dependencies.chat.cancelAttempt(
          conversationId,
          transaction.attemptId,
        )
      ) {
        lastCancellationCommitted = false;
        publish(
          stateFor('blocked', {
            conversationId,
            turnId: transaction.turnId,
            attemptId: transaction.attemptId,
            failureCode: 'E_COMPLETION_RESULT_CORRELATION',
          }),
        );
        return outcome('blocked', state);
      }
      return await persistTerminal({
        conversationId,
        turnId: transaction.turnId,
        attemptId: transaction.attemptId,
        successStatus: 'cancelled',
        failureCode: null,
        preparedNotification: preparedWasDurable
          ? null
          : { events, transaction },
      });
    }
    if (durability.status === 'not_committed') {
      pendingPreparation = null;
      transaction.rollback();
      publish(
        stateFor('blocked', {
          conversationId,
          turnId: transaction.turnId,
          attemptId: transaction.attemptId,
          failureCode: 'E_ATTEMPT_PERSISTENCE',
        }),
      );
      return outcome('blocked', state);
    }
    if (durability.status !== 'committed') {
      pendingPreparation = {
        epoch: runEpoch,
        transaction,
        conversationId,
        events,
        durability: durability.status,
      };
      publish(
        stateFor('persistence_pending', {
          conversationId,
          turnId: transaction.turnId,
          attemptId: transaction.attemptId,
          failureCode: 'E_ATTEMPT_PERSISTENCE',
        }),
      );
      return outcome('persistence_pending', state);
    }
    if (!transaction.commit()) {
      publish(
        stateFor('blocked', {
          conversationId,
          turnId: transaction.turnId,
          attemptId: transaction.attemptId,
          failureCode: 'E_ATTEMPT_PERSISTENCE',
        }),
      );
      return outcome('blocked', state);
    }
    pendingPreparation = null;
    notifyPrepared(events, transaction, conversationId);
    return await runPrepared(
      conversationId,
      transaction.turnId,
      transaction.attemptId,
      events,
      runEpoch,
    );
  };

  const beginTransaction = async (
    transaction: PreparedTurnTransaction,
    conversationId: string,
    events: CompletionControllerEvents,
    runEpoch: number,
  ) => {
    pendingPreparation = {
      epoch: runEpoch,
      transaction,
      conversationId,
      events,
      durability: null,
    };
    try { events.onPrepared?.(); } catch { /* Presentation cannot change ownership. */ }
    publish(
      stateFor('preparing', {
        conversationId,
        turnId: transaction.turnId,
        attemptId: transaction.attemptId,
      }),
    );
    return await continuePreparation(
      transaction,
      conversationId,
      events,
      runEpoch,
      await safePersist(),
    );
  };

  const agentRecoveryTarget = (
    attempt: TurnAttemptV1,
  ): AgentRecoveryTargetV2 | null => {
    const journal = attempt.agent;
    if (journal === undefined || journal === null) return null;
    const lineage = journal.round_lineage;
    if (lineage === null || lineage.native_row_revision === null) {
      return {
        schema_version: 2,
        kind: 'attempt',
        task_id: attempt.turnId,
        attempt_id: attempt.attemptId,
      };
    }
    const call = journal.call_index === null ? null : journal.batch[journal.call_index];
    if (
      call !== undefined &&
      call !== null &&
      call.idempotency_key !== null &&
      (journal.phase === 'execution_intent' ||
        journal.phase === 'tool_result_pending' ||
        journal.phase === 'unknown' ||
        journal.phase === 'ambiguous')
    ) {
      return {
        schema_version: 2,
        kind: 'tool',
        task_id: attempt.turnId,
        attempt_id: attempt.attemptId,
        round_id: lineage.round_id,
        round_index: journal.round_index,
        call_index: call.call_index,
        call_id: call.call_id,
        idempotency_key: call.idempotency_key,
      };
    }
    // A round whose outcome this journal already carries has nothing left to
    // reconcile, and asking about it is not merely useless: the round
    // selector binds the request's transcript to the row's *before*
    // transcript, and a committed round has moved the journal past it. Every
    // recovery of an attempt waiting on an approval therefore answered
    // E_AGENT_CONFLICT instead of putting the question back on screen. The
    // attempt itself is the right target: the query already says where the
    // turn stands, and the controller resumes from there.
    if (lineage.status === 'completed') {
      return {
        schema_version: 2,
        kind: 'attempt',
        task_id: attempt.turnId,
        attempt_id: attempt.attemptId,
      };
    }
    return {
      schema_version: 2,
      kind: 'round',
      task_id: attempt.turnId,
      attempt_id: attempt.attemptId,
      round_id: lineage.round_id,
      round_index: journal.round_index,
    };
  };

  const finishRecoveredFinal = async (
    conversationId: string,
    attemptId: string,
    runEpoch: number,
    request: RecoverAgentAttemptRequestV2,
    recovered: Extract<RecoverAgentAttemptResultV2, { readonly status: 'resumed' | 'terminal' }>,
    evidence: AgentStoreTransitionEvidence,
    _events: CompletionControllerEvents,
  ): Promise<CompletionControllerOutcome> => {
    const completed = recovered.completed_round;
    if (completed === null || completed.kind !== 'final') {
      return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_TRANSCRIPT');
    }
    const completionRequest: CompleteAgentRoundRequestV2 = {
      schema_version: 2,
      operation_id: request.operation_id,
      controller_cas: request.controller_cas,
      committed_checkpoint: request.committed_checkpoint,
      task_id: request.target.task_id,
      conversation_id: request.controller_cas.conversation_id,
      attempt_id: request.target.attempt_id,
      round_id: completed.round_id,
      round_index: completed.round_index,
      launch_attempt: completed.launch_attempt,
      expected_round_revision: request.expected_round_revision ?? 0,
      transport_schema_version: completed.completion_receipt.transport_schema_version,
      harness_id: completed.completion_receipt.harness_id ?? 'dsh',
      model: completed.completion_receipt.model,
      thinking_mode: completed.completion_receipt.thinking_mode,
      visible_history_sha256: completed.completion_receipt.visible_history_sha256,
      visible_message_count: 0,
      project_context_sha256:
        completed.completion_receipt.project_context_receipt?.snapshot_sha256 ?? null,
      transcript: request.expected_transcript,
      root: request.root,
      registry_version: recovered.attempt.registry.registry_version,
      toolset_sha256: recovered.attempt.registry.toolset_sha256,
    };
    // The recovery evidence already carries the authoritative projection. The
    // request fields above are used only as a correlation envelope by the
    // terminal Store transition; the native recovery result remains the source
    // for the receipt and transcript.
    return await terminalizeAgent(
      conversationId,
      attemptId,
      runEpoch,
      completionRequest,
      {
        schema_version: 2,
        status: 'completed',
        operation_id: request.operation_id,
        task_id: request.target.task_id,
        attempt_id: request.target.attempt_id,
        round_id: completed.round_id,
        round_index: completed.round_index,
        launch_attempt: completed.launch_attempt,
        result_round_revision: completed.result_round_revision,
        transcript: completed.transcript,
        outcome: {
          schema_version: 3,
          kind: 'final',
          finish_reason: 'stop',
          completion_receipt: completed.completion_receipt,
          transcript: completed.transcript,
          text: completed.text,
          reasoning: completed.reasoning,
        },
      },
      evidence,
      'final_response',
    );
  };

  const recoverAgentRunImpl = async (
    conversationId: string,
    attemptId: string,
    events: CompletionControllerEvents,
    runEpoch: number,
  ): Promise<CompletionControllerOutcome> => {
    if (agentRuntime === undefined || !agentAvailable()) {
      publish(stateFor('retryable', { conversationId, attemptId, failureCode: 'E_COMPLETION_NATIVE' }));
      return outcome('retryable', state);
    }
    const located = getConversationAttempt(conversationId, attemptId);
    if (located === null || located.attempt.agent === undefined || located.attempt.agent === null) {
      return outcome('blocked', state);
    }
    const { attempt } = located;
    if (attempt.failureCode === 'E_ATTEMPT_INTERRUPTED') {
      // An interrupted attempt belongs to a dead writer launch.  It must
      // never re-enter provider/tool recovery; retry creates a fresh attempt
      // in the same turn through the legacy retry path.
      return outcome('blocked', state);
    }
    const journal = attempt.agent;
    if (journal === undefined || journal === null) {
      return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_CONFLICT');
    }
    const cas = authorityFor(attempt, conversationId);
    const authorityCheckpoint = agentCheckpointForJournal(attempt);
    const target = agentRecoveryTarget(attempt);
    if (cas === null || authorityCheckpoint === null || target === null) {
      publish(stateFor('resume_available', { conversationId, turnId: attempt.turnId, attemptId, failureCode: 'E_AGENT_PERSISTENCE' }));
      return outcome('persistence_pending', state);
    }
    const queryRequest: QueryAgentAttemptRequestV2 = {
      schema_version: 2,
      controller_cas: cas,
      task_id: attempt.turnId,
      conversation_id: conversationId,
      attempt_id: attemptId,
      expected_journal_revision: attempt.journalRevision ?? 0,
      expected_session_generation: authorityCheckpoint.session_generation,
      expected_session_sha256: authorityCheckpoint.session_sha256,
      expected_transcript: journal.transcript,
      expected_root_fingerprint_sha256: journal.root.root_fingerprint_sha256,
      expected_workspace_binding_revision: journal.root.workspace_binding_revision,
    };
    publish(stateFor('recovering', { conversationId, turnId: attempt.turnId, attemptId, roundId: journal.round_lineage?.round_id ?? null, transportSchemaVersion: agentTransportSchema(attempt) }));
    let queried: QueryAgentAttemptResultV2;
    try {
      // A read can queue behind a long native provider round. Bound only this
      // UI inspection, never cancel/clear the durable native execution. Late
      // read results are consumed but cannot start recovery or replay work.
      queried = await new Promise<QueryAgentAttemptResultV2>((resolve, reject) => {
        let settled = false;
        const read = { epoch: runEpoch, stop: () => finish(undefined, { code: 'E_AGENT_EXECUTION_AMBIGUOUS' }) };
        const timer = setTimeout(() => read.stop(), 15_000);
        const finish = (value?: QueryAgentAttemptResultV2, error?: unknown) => {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          if (pendingAgentRecoveryRead === read) pendingAgentRecoveryRead = null;
          if (value !== undefined) resolve(value);
          else reject(error);
        };
        pendingAgentRecoveryRead = read;
        Promise.resolve().then(() => agentRuntime.queryAgentAttempt(queryRequest))
          .then(value => finish(value), error => finish(undefined, error));
      });
    } catch (error) {
      if (runEpoch !== epoch) return outcome('cancelled', state);
      publish(stateFor('resume_available', { conversationId, turnId: attempt.turnId, attemptId, failureCode: agentFailure(error) }));
      return outcome('retryable', state);
    }
    if (runEpoch !== epoch) return outcome('cancelled', state);
    if (queried.status === 'conflict' || queried.status === 'not_found') {
      publish(stateFor('resume_available', { conversationId, turnId: attempt.turnId, attemptId, failureCode: queried.status === 'conflict' ? 'E_AGENT_CONFLICT' : 'E_COMPLETION_HISTORY' }));
      return outcome('retryable', state);
    }
    const queriedBatchAuthority = agentBatchAuthorityFromProjection(queried.attempt);
    if (queriedBatchAuthority !== null) {
      updateAgentRun({ batchAuthority: queriedBatchAuthority });
    }
    const recoveryOperationId = freshOperationId();
    if (recoveryOperationId === null) return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_PERSISTENCE');
    const recoveryRequest: RecoverAgentAttemptRequestV2 = {
      schema_version: 2,
      operation_id: recoveryOperationId,
      controller_cas: cas,
      committed_checkpoint: authorityCheckpoint,
      target,
      action: 'reconcile',
      expected_round_revision: target.kind === 'round'
        ? journal.round_lineage?.native_row_revision ?? 0
        : null,
      expected_execution_revision: target.kind === 'tool'
        ? journal.batch[target.call_index]?.native_row_revision ?? 0
        : null,
      expected_transcript: journal.transcript,
      root: agentRootForJournal(journal),
    };
    updateAgentRun({ operationId: recoveryOperationId });
    let recovered: RecoverAgentAttemptResultV2;
    try {
      recovered = await agentRuntime.recoverAgentAttempt(recoveryRequest);
    } catch (error) {
      publish(stateFor('resume_available', { conversationId, turnId: attempt.turnId, attemptId, failureCode: agentFailure(error) }));
      return outcome('retryable', state);
    }
    const evidence = mapEvidence('recover_agent_attempt', recoveryRequest, recovered);
    if (evidence === null || recovered.status === 'conflict') {
      publish(stateFor('resume_available', { conversationId, turnId: attempt.turnId, attemptId, failureCode: 'E_AGENT_CONFLICT' }));
      return outcome('retryable', state);
    }
    if (recovered.status === 'manual_reconciliation') {
      publish(stateFor('resume_available', { conversationId, turnId: attempt.turnId, attemptId, failureCode: 'E_AGENT_EXECUTION_AMBIGUOUS' }));
      return outcome('retryable', state);
    }
    if (recovered.status === 'retryable') {
      publish(stateFor('retryable', { conversationId, turnId: attempt.turnId, attemptId, failureCode: 'E_AGENT_PERSISTENCE' }));
      return outcome('retryable', state);
    }
    if (recovered.completed_round !== null && recovered.completed_round.kind === 'final') {
      return await finishRecoveredFinal(conversationId, attemptId, runEpoch, recoveryRequest, recovered, evidence, events);
    }
    const recoveredProjection = agentJournalFromProjection(
      recovered.attempt,
      canonicalNow(dependencies.now),
    );
    if (recoveredProjection === null) {
      publish(stateFor('resume_available', { conversationId, turnId: attempt.turnId, attemptId, failureCode: 'E_AGENT_TRANSCRIPT' }));
      return outcome('retryable', state);
    }
    const recoveredJournal: PersistedAgentAttemptJournalV3 = {
      ...recoveredProjection,
      controller_generation: journal.controller_generation + 1,
      updated_at: canonicalNow(dependencies.now),
    };
    const recoveryIsTerminal =
      recoveredJournal.phase === 'final_response' ||
      recoveredJournal.phase === 'failed' ||
      recoveredJournal.phase === 'cancelled';
    const recoveryIsReady = recoveredJournal.phase === 'ready_for_round';
    const recoveryEvent = agentEvent(
      attemptId,
      recoveryOperationId,
      recoveryIsTerminal ? 'terminal' : 'round',
      recoveryIsTerminal || recoveryIsReady ? null : recoveredJournal.round_index,
      null,
      recoveredJournal.phase === 'final_response'
        ? 'ok'
        : recoveredJournal.phase === 'cancelled'
          ? 'cancelled'
          : recoveredJournal.phase === 'failed'
            ? 'failed'
            : recoveryIsReady
              ? 'waiting'
              : 'running',
      null,
      null,
      null,
      null,
      recoveredJournal.phase === 'failed'
        ? 'E_AGENT_PERSISTENCE'
        : recoveredJournal.phase === 'cancelled'
          ? 'E_AGENT_CANCELLED'
          : null,
    );
    const currentCas = authorityFor(attempt, conversationId);
    if (currentCas === null) return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_PERSISTENCE');
    const recoveryEvents: PersistedSessionEventV3[] = [recoveryEvent];
    for (const call of recoveredJournal.batch) {
      if (!isConversationGrantBoundCall(call)) continue;
      if (!hasLiveConversationGrant(call, recoveredJournal, conversationId, located.conversation.agentGrants ?? located.conversation.agent_grants ?? [])) {
        publish(stateFor('resume_available', { conversationId, turnId: attempt.turnId, attemptId, failureCode: 'E_AGENT_CONFLICT' }));
        return outcome('retryable', state);
      }
      const grantEventId = freshOperationId();
      if (grantEventId === null) return await failAgentWithoutNative(conversationId, attemptId, 'E_AGENT_PERSISTENCE');
      recoveryEvents.push({ ...agentEvent(attemptId, grantEventId, 'approval', recoveredJournal.round_index,
        call.call_id, 'approval', call.safe_summary_key, call.arguments_sha256, null, call.approval_reference, null),
        seq: recoveryEvent.seq + recoveryEvents.length });
    }
    const transaction = dependencies.chat.setAgentJournal({ cas: currentCas, expectedAttempt: attempt, journal: recoveredJournal, events: recoveryEvents, evidence });
    if (transaction === null) {
      publish(stateFor('resume_available', { conversationId, turnId: attempt.turnId, attemptId, failureCode: 'E_AGENT_CONFLICT' }));
      return outcome('retryable', state);
    }
    return await safeAgentPersist(transaction, async () => {
      const recoveredBatchAuthority = agentBatchAuthorityFromProjection(recovered.attempt);
      if (recoveredBatchAuthority !== null) {
        updateAgentRun({ batchAuthority: recoveredBatchAuthority });
      }
      // Approval tokens live only in this run, and a recovery is a new run:
      // without taking them back from the projection a turn recovered while
      // it was waiting for a person could never ask again, because the call
      // it wanted approved had no token to show.
      if (agentRun !== null) {
        agentRun = rememberAgentTokens(agentRun, recovered.attempt.batch);
      }
      if (recoveredJournal.phase === 'ready_for_round' || recoveredJournal.phase === 'tool_result_pending') return await runAgentRound(conversationId, attemptId, runEpoch);
      if (recoveredJournal.phase === 'batch_frozen' || recoveredJournal.phase === 'approval_pending') return await runAgentBatch(conversationId, attemptId, runEpoch);
      publish(stateFor('retryable', { conversationId, turnId: attempt.turnId, attemptId, failureCode: 'E_AGENT_PERSISTENCE' }));
      return outcome('retryable', state);
    }, runEpoch, { conversationId, turnId: attempt.turnId, attemptId });
  };

  const recoverAgentRun = async (
    conversationId: string,
    attemptId: string,
    events: CompletionControllerEvents,
    runEpoch: number,
  ): Promise<CompletionControllerOutcome> => {
    try {
      return await recoverAgentRunImpl(conversationId, attemptId, events, runEpoch);
    } finally {
      // A settled recovery probe is no longer an active provider/tool run.
      // Keep durable unresolved evidence, but release the transient owner so
      // another explicit reconciliation can inspect it instead of staying busy.
      if (agentRun?.epoch === runEpoch && pendingAgentPersistence === null &&
          pendingAgentCleanup === null &&
          (state.phase === 'resume_available' || state.phase === 'retryable' || state.phase === 'blocked')) {
        agentRun = null;
      }
    }
  };

  const cancelAgentRun = async (): Promise<void> => {
    if (agentRuntime === undefined || agentRun === null) return;
    const run = agentRun;
    const located = getConversationAttempt(run.conversationId, run.attemptId);
    if (located === null || located.attempt.agent === undefined || located.attempt.agent === null) return;
    const { attempt } = located;
    const journal = attempt.agent;
    if (journal === undefined || journal === null) return;
    const cas = authorityFor(attempt, run.conversationId);
    const checkpoint = agentCheckpointForJournal(attempt);
    const operationId = freshOperationId();
    if (cas === null || checkpoint === null || operationId === null) {
      publish(stateFor('blocked', { conversationId: run.conversationId, turnId: run.turnId, attemptId: run.attemptId, failureCode: 'E_AGENT_PERSISTENCE' }));
      lastCancellationCommitted = false;
      return;
    }
    const target: AgentCancelTargetV2 =
      journal.phase === 'round_in_flight' && journal.round_lineage !== null
        ? {
            schema_version: 2,
            kind: 'round',
            task_id: run.turnId,
            attempt_id: run.attemptId,
            round_id: journal.round_lineage.round_id,
            round_index: journal.round_index,
          }
        : journal.phase === 'execution_intent' && journal.call_index !== null && journal.batch[journal.call_index]?.idempotency_key !== null && journal.round_lineage !== null
          ? {
              schema_version: 2,
              kind: 'tool',
              task_id: run.turnId,
              attempt_id: run.attemptId,
              round_id: journal.round_lineage.round_id,
              round_index: journal.round_index,
              call_index: journal.call_index,
              call_id: journal.batch[journal.call_index]!.call_id,
              idempotency_key: journal.batch[journal.call_index]!.idempotency_key!,
            }
          : {
              schema_version: 2,
              kind: 'attempt',
              task_id: run.turnId,
              attempt_id: run.attemptId,
            };
    const expectedPhase = journal.phase as AgentCancelTokenV2['expected_phase'];
    const cancelToken: AgentCancelTokenV2 = {
      schema_version: 2,
      issuer: 'completion_controller',
      source_event_id: operationId,
      token: operationId,
      task_id: run.turnId,
      attempt_id: run.attemptId,
      expected_phase: expectedPhase,
      reason_code: 'E_AGENT_CANCELLED',
    };
    const cancelPreflightInput = {
      schema_version: 1,
      source: 'completion_controller',
      kind: 'request_cancel',
      operation_id: operationId,
      base_cas: cas,
      conversation_id: run.conversationId,
      task_id: run.turnId,
      attempt_id: run.attemptId,
      target,
      cancel_token: cancelToken,
      expected_round_revision: target.kind === 'round'
        ? journal.round_lineage?.native_row_revision ?? 0
        : null,
      expected_execution_revision: target.kind === 'tool'
        ? journal.batch[target.call_index]?.native_row_revision ?? 0
        : null,
      expected_transcript: journal.transcript,
      root: agentRootForJournal(journal),
    };
    const preflight = validateAgentControllerPreflight(cancelPreflightInput);
    if (preflight === null) {
      publish(stateFor('blocked', { conversationId: run.conversationId, turnId: run.turnId, attemptId: run.attemptId, failureCode: 'E_AGENT_CONFLICT' }));
      lastCancellationCommitted = false;
      return;
    }
    const cancelledJournal: PersistedAgentAttemptJournalV3 = {
      ...copyAgentJournal(journal),
      controller_generation: journal.controller_generation + 1,
      round_lineage: journal.round_lineage === null ? null : {
        ...journal.round_lineage,
        status: target.kind === 'attempt' ? journal.round_lineage.status : 'cancel_requested',
      },
      updated_at: canonicalNow(dependencies.now),
    };
    const transaction = dependencies.chat.cancelAgentAttempt({ cas, expectedAttempt: attempt, journal: cancelledJournal, events: [], evidence: preflight });
    if (transaction === null) {
      publish(stateFor('blocked', { conversationId: run.conversationId, turnId: run.turnId, attemptId: run.attemptId, failureCode: 'E_AGENT_CONFLICT' }));
      lastCancellationCommitted = false;
      return;
    }
    publish(stateFor('cancelling', { conversationId: run.conversationId, turnId: run.turnId, attemptId: run.attemptId, roundId: journal.round_lineage?.round_id ?? null, transportSchemaVersion: run.transportSchemaVersion }));
    await safeAgentPersist(transaction, async committedCheckpoint => {
      const current = getConversationAttempt(run.conversationId, run.attemptId);
      if (current === null || current.attempt.agent === undefined || current.attempt.agent === null) return outcome('cancelled', state);
      const nativeOperationId = freshOperationId();
      if (nativeOperationId === null) return await failAgentWithoutNative(run.conversationId, run.attemptId, 'E_AGENT_PERSISTENCE');
      const request: CancelAgentAttemptRequestV2 = {
        schema_version: 2,
        operation_id: nativeOperationId,
        controller_cas: authorityFor(current.attempt, run.conversationId)!,
        committed_checkpoint: committedCheckpoint,
        target,
        cancel_token: cancelToken,
        expected_round_revision: target.kind === 'round'
          ? journal.round_lineage?.native_row_revision ?? 0
          : null,
        expected_execution_revision: target.kind === 'tool'
          ? journal.batch[target.call_index]?.native_row_revision ?? 0
          : null,
        expected_transcript: current.attempt.agent.transcript,
        root: agentRootForJournal(current.attempt.agent),
      };
      updateAgentRun({ operationId: nativeOperationId });
      let result: CancelAgentAttemptResultV2;
      try {
        result = await agentRuntime!.cancelAgentAttempt(request);
      } catch {
        lastCancellationCommitted = false;
        return outcome('cancelled', state);
      }
      const evidence = mapEvidence('cancel_agent_attempt', request, result);
      if (evidence === null || result.status === 'conflict') {
        lastCancellationCommitted = false;
        return outcome('cancelled', state);
      }
      const currentJournal = current.attempt.agent!;
      const terminal = result.status === 'cancelled' || result.status === 'already_cancelled';
      const cancelledLineage: PersistedAgentAttemptJournalV3['round_lineage'] = currentJournal.round_lineage === null
        ? null
        : {
            ...currentJournal.round_lineage,
            status: terminal
              ? 'cancelled'
              : result.status === 'unknown'
                ? 'unknown'
                : result.status === 'ambiguous'
                  ? 'ambiguous'
                  : 'cancel_requested',
            ...(result.result_round_revision === null
              ? {}
              : { native_row_revision: result.result_round_revision }),
          };
      const cancelledBatch = currentJournal.batch.map((call, index) => {
        let nextCall = call;
        if (
          target.kind === 'tool' &&
          index === target.call_index &&
          result.result_execution_revision !== null
        ) {
          nextCall = {
            ...nextCall,
            native_row_revision: result.result_execution_revision,
            ...(result.receipt === null
              ? {}
              : { receipt: result.receipt as unknown as StoreAgentToolReceiptV1 }),
          };
        }
        if (
          terminal &&
          nextCall.receipt === null &&
          nextCall.approval_decision !== 'denied' &&
          nextCall.approval_decision !== 'cancelled'
        ) {
          nextCall = {
            ...nextCall,
            approval_decision: 'cancelled',
            approval_token: null,
            approval_reference: null,
          };
        }
        return nextCall;
      });
      const cancelCreatedAt = canonicalNow(dependencies.now);
      const nextJournal: PersistedAgentAttemptJournalV3 = {
        ...copyAgentJournal(currentJournal),
        phase: terminal ? 'cancelled' : result.status === 'unknown' ? 'unknown' : result.status === 'ambiguous' ? 'ambiguous' : currentJournal.phase,
        controller_generation: currentJournal.controller_generation + 1,
        transcript: copyAgentTranscript(result.transcript),
        round_lineage: cancelledLineage,
        batch: cancelledBatch,
        updated_at: cancelCreatedAt,
      };
      const cleanup = terminal
        ? agentCleanupFor(
            run.conversationId,
            current.attempt,
            nextJournal,
            'cancelled',
            cancelCreatedAt,
          )
        : null;
      if (terminal && cleanup === null) return await failAgentWithoutNative(run.conversationId, run.attemptId, 'E_AGENT_PERSISTENCE');
      const terminalEventId = terminal ? freshOperationId() : request.operation_id;
      if (terminal && terminalEventId === null) return await failAgentWithoutNative(run.conversationId, run.attemptId, 'E_AGENT_PERSISTENCE');
      const cancelEvent = terminal
        ? agentEvent(
            run.attemptId,
            terminalEventId!,
            'terminal',
            null,
            null,
            'cancelled',
            null,
            null,
            null,
            null,
            'E_AGENT_CANCELLED',
            cancelCreatedAt,
          )
        : agentEvent(
            run.attemptId,
            request.operation_id,
            'cancel',
            target.kind === 'attempt' ? null : target.round_index,
            target.kind === 'tool' ? target.call_id : null,
            'cancelled',
            null,
            target.kind === 'tool'
              ? currentJournal.batch[target.call_index]?.arguments_sha256 ?? null
              : null,
            null,
            request.operation_id,
            request.cancel_token.reason_code,
            cancelCreatedAt,
          );
      const postCas = authorityFor(current.attempt, run.conversationId);
      if (postCas === null) return await failAgentWithoutNative(run.conversationId, run.attemptId, 'E_AGENT_PERSISTENCE');
      const postTx = terminal
        ? dependencies.chat.completeAgentAttempt({
            cas: postCas,
            expectedAttempt: current.attempt,
            journal: nextJournal,
            events: [cancelEvent],
            evidence,
            assistantMessage: null,
            cleanup: cleanup!,
          })
        : dependencies.chat.cancelAgentAttempt({
            cas: postCas,
            expectedAttempt: current.attempt,
            journal: nextJournal,
            events: [cancelEvent],
            evidence,
          });
      if (postTx === null) return await failAgentWithoutNative(run.conversationId, run.attemptId, 'E_AGENT_CONFLICT');
      return await safeAgentPersist(postTx, async finalCheckpoint => {
        if (!terminal) {
          lastCancellationCommitted = false;
          publish(stateFor('retryable', { conversationId: run.conversationId, turnId: run.turnId, attemptId: run.attemptId, failureCode: result.status === 'ambiguous' ? 'E_AGENT_EXECUTION_AMBIGUOUS' : 'E_AGENT_CONFLICT' }));
          return outcome('retryable', state);
        }
        lastCancellationCommitted = true;
        return await finalizeAgent(run.conversationId, run.attemptId, run.epoch, finalCheckpoint, nextJournal, cleanup!, postCas);
      }, run.epoch, { conversationId: run.conversationId, turnId: run.turnId, attemptId: run.attemptId }, 'cancel');
    }, run.epoch, { conversationId: run.conversationId, turnId: run.turnId, attemptId: run.attemptId }, 'cancel');
  };

  const settleAgentCancellation = async (): Promise<void> => {
    const run = agentRun;
    if (run === null || agentCancellationInFlight === run.epoch) return;
    requestedAgentCancellationEpoch = null;
    agentCancellationInFlight = run.epoch;
    lastCancellationCommitted = false;
    try {
      await cancelAgentRun();
    } finally {
      agentCancellationInFlight = null;
      if (pendingAgentPersistence === null && pendingAgentCleanup === null) {
        if (agentRun?.epoch === run.epoch) agentRun = null;
        if (epoch === run.epoch) epoch += 1;
        if (!lastCancellationCommitted) {
          publish(stateFor('resume_available', { conversationId: run.conversationId,
            turnId: run.turnId, attemptId: run.attemptId,
            failureCode: state.failureCode ?? 'E_AGENT_CONFLICT' }));
        }
      }
    }
  };

  const controller: CompletionController = {
    getState: () => state,
    subscribe: listener => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    getPreviews: () => roundPreviews,
    subscribePreviews: listener => {
      previewListeners.add(listener);
      return () => previewListeners.delete(listener);
    },
    send: async (input, events = {}) => {
      if (destructiveJournalActive()) {
        return busyOutcome();
      }
      if (
        active !== null ||
        agentRun !== null ||
        pendingPreparation !== null ||
        pendingAgentPersistence !== null ||
        pendingAgentCleanup !== null ||
        pendingCommit !== null ||
        pendingTerminal !== null ||
        retryPersistenceInFlight ||
        retryCommitInFlight ||
        state.phase === 'preparing' ||
        state.phase === 'starting' ||
        state.phase === 'sending' ||
        state.phase === 'approval_pending' ||
        state.phase === 'executing' ||
        state.phase === 'recovering' ||
        state.phase === 'cancelling' ||
        state.phase === 'resume_available'
      ) {
        return busyOutcome(input.conversationId, null);
      }
      const startState = dependencies.chat.getState();
      const startConversation = startState.conversations[input.conversationId];
      if (
        agentRuntime !== undefined && agentAvailable() &&
        input.sendWithoutProjectContext !== true && startConversation !== undefined &&
        (startConversation.workspaceId !== null || startConversation.projectId !== null ||
          startConversation.workspaceBinding != null) &&
        (startState.sessionEvents?.length ?? 0) + AGENT_EVENT_START_RESERVE > MAX_SESSION_EVENT_ROWS
      ) {
        publish(stateFor('blocked', { conversationId: input.conversationId, failureCode: 'E_AGENT_EVENT_CAPACITY' }));
        return outcome('blocked', state);
      }
      epoch += 1;
      const runEpoch = epoch;
      const transaction = dependencies.chat.prepareTurnAttempt(
        input.conversationId,
        input.text,
        {
          attachments: input.attachments,
          sendWithoutProjectContext:
            input.sendWithoutProjectContext === true,
          ...(input.harnessId === undefined
            ? {}
            : { harnessId: input.harnessId }),
        },
      );
      if (transaction === null) {
        const conversation =
          dependencies.chat.getState().conversations[input.conversationId];
        const code: AttemptFailureCode =
          conversation?.projectId !== null &&
          input.sendWithoutProjectContext !== true
            ? 'E_ATTEMPT_CONTEXT_REQUIRED'
            : 'E_COMPLETION_HISTORY';
        publish(
          stateFor('blocked', {
            conversationId: input.conversationId,
            failureCode: code,
          }),
        );
        return outcome('blocked', state);
      }
      return await beginTransaction(
        transaction,
        input.conversationId,
        events,
        runEpoch,
      );
    },
    retry: async (conversationId, attemptId, events = {}) => {
      if (destructiveJournalActive()) {
        return busyOutcome(conversationId, attemptId);
      }
      if (
        active !== null ||
        agentRun !== null ||
        pendingPreparation !== null ||
        pendingAgentPersistence !== null ||
        pendingAgentCleanup !== null ||
        pendingCommit !== null ||
        pendingTerminal !== null ||
        retryPersistenceInFlight ||
        retryCommitInFlight ||
        state.phase === 'cancelling'
      ) {
        return busyOutcome(conversationId, attemptId);
      }
      const source = getConversationAttempt(conversationId, attemptId);
      if (
        source?.attempt.agent !== undefined &&
        source.attempt.agent !== null &&
        source.attempt.failureCode !== 'E_ATTEMPT_INTERRUPTED'
      ) {
        epoch += 1;
        agentRun = {
          epoch,
          conversationId,
          turnId: source.attempt.turnId,
          attemptId,
          events,
          transportSchemaVersion: agentTransportSchema(source.attempt),
          roundId: source.attempt.agent.round_lineage?.round_id ?? null,
          operationId: null,
          cancelTarget: agentRecoveryTarget(source.attempt),
          batchAuthority: null,
          approvalTokens: new Map(),
      approvalPreviews: new Map(),
        };
        return await recoverAgentRun(conversationId, attemptId, events, epoch);
      }
      epoch += 1;
      const transaction = dependencies.chat.retryAttempt(
        conversationId,
        attemptId,
      );
      if (transaction === null) {
        publish(
          stateFor('blocked', {
            conversationId,
            attemptId,
            failureCode: 'E_COMPLETION_RESULT_CORRELATION',
          }),
        );
        return outcome('blocked', state);
      }
      return await beginTransaction(
        transaction,
        conversationId,
        events,
        epoch,
      );
    },
    resume: async (conversationId, attemptId, events = {}) => {
      if (destructiveJournalActive()) {
        return busyOutcome(conversationId, attemptId);
      }
      if (
        active !== null ||
        agentRun !== null ||
        pendingPreparation !== null ||
        pendingAgentPersistence !== null ||
        pendingAgentCleanup !== null ||
        pendingCommit !== null ||
        pendingTerminal !== null ||
        retryPersistenceInFlight ||
        retryCommitInFlight ||
        state.phase === 'cancelling'
      ) {
        return busyOutcome(conversationId, attemptId);
      }
      const conversation = dependencies.chat.getState().conversations[conversationId];
      const attempt = conversation?.attempts.find(item => item.attemptId === attemptId);
      if (
        attempt?.agent !== undefined &&
        attempt.agent !== null &&
        attempt.failureCode !== 'E_ATTEMPT_INTERRUPTED'
      ) {
        epoch += 1;
        agentRun = {
          epoch,
          conversationId,
          turnId: attempt.turnId,
          attemptId,
          events,
          transportSchemaVersion: agentTransportSchema(attempt),
          roundId: attempt.agent.round_lineage?.round_id ?? null,
          operationId: null,
          cancelTarget: agentRecoveryTarget(attempt),
          batchAuthority: null,
          approvalTokens: new Map(),
      approvalPreviews: new Map(),
        };
        return await recoverAgentRun(conversationId, attemptId, events, epoch);
      }
      if (
        attempt === undefined ||
        attempt.status !== 'prepared' ||
        attempt.rounds.length !== 0
      ) {
        publish(
          stateFor('blocked', {
            conversationId,
            attemptId,
            failureCode: 'E_COMPLETION_RESULT_CORRELATION',
          }),
        );
        return outcome('blocked', state);
      }
      epoch += 1;
      return await runPrepared(
        conversationId,
        attempt.turnId,
        attemptId,
        events,
        epoch,
      );
    },
    abandonAndRetry: async (conversationId, attemptId, events = {}) => {
      if (destructiveJournalActive()) {
        return busyOutcome(conversationId, attemptId);
      }
      if (
        active !== null ||
        agentRun !== null ||
        pendingPreparation !== null ||
        pendingAgentPersistence !== null ||
        pendingAgentCleanup !== null ||
        pendingCommit !== null ||
        pendingTerminal !== null ||
        retryPersistenceInFlight ||
        retryCommitInFlight ||
        state.phase === 'cancelling'
      ) {
        return busyOutcome(conversationId, attemptId);
      }
      const located = getConversationAttempt(conversationId, attemptId);
      const journal = located?.attempt.agent ?? null;
      // Only the two answers recovery cannot resolve by itself. Everything
      // else is resumed, retried or already over, and has its own path.
      if (
        located === undefined ||
        located === null ||
        journal === undefined ||
        journal === null ||
        (journal.phase !== 'ambiguous' && journal.phase !== 'unknown')
      ) {
        publish(
          stateFor('blocked', {
            conversationId,
            attemptId,
            failureCode: 'E_COMPLETION_RESULT_CORRELATION',
          }),
        );
        return outcome('blocked', state);
      }
      const { attempt } = located;
      epoch += 1;
      const runEpoch = epoch;
      const cleanup = agentCleanupFor(
        conversationId,
        attempt,
        journal,
        'failed',
        canonicalNow(dependencies.now),
      );
      if (cleanup === null) {
        publish(
          stateFor('blocked', {
            conversationId,
            turnId: attempt.turnId,
            attemptId,
            failureCode: 'E_AGENT_PERSISTENCE',
          }),
        );
        return outcome('blocked', state);
      }
      const transaction = dependencies.chat.abandonUnresolvedAgentAttempt({
        conversationId,
        attemptId,
        expectedAttempt: attempt,
        cleanup,
      });
      if (transaction === null) {
        publish(
          stateFor('blocked', {
            conversationId,
            turnId: attempt.turnId,
            attemptId,
            failureCode: 'E_AGENT_CONFLICT',
          }),
        );
        return outcome('blocked', state);
      }
      // Each of the three steps owns the controller's single pending-persist
      // slot in turn, so they cannot be nested: the fresh turn is begun after
      // the abandonment has committed, not inside its continuation.
      const abandoned = await safeAgentPersist(
        transaction,
        async () => outcome('retryable', state),
        runEpoch,
        { conversationId, turnId: attempt.turnId, attemptId },
        'checkpoint',
      );
      if (abandoned.status !== 'retryable' || runEpoch !== epoch) {
        return abandoned;
      }
      await settleAbandonedAgentResidue(
        conversationId,
        attemptId,
        runEpoch,
        cleanup,
      );
      if (runEpoch !== epoch) return outcome('cancelled', state);
      const retryTransaction = dependencies.chat.retryAttempt(
        conversationId,
        attemptId,
      );
      if (retryTransaction === null) {
        publish(
          stateFor('blocked', {
            conversationId,
            turnId: attempt.turnId,
            attemptId,
            failureCode: 'E_COMPLETION_RESULT_CORRELATION',
          }),
        );
        return outcome('blocked', state);
      }
      return await beginTransaction(
        retryTransaction,
        conversationId,
        events,
        runEpoch,
      );
    },
    retryPersistence: async () => {
      if (destructiveJournalActive()) return busyOutcome();
      if (state.phase === 'cancelling' || state.phase === 'finalizing') {
        return busyOutcome();
      }
      const agentPending = pendingAgentPersistence;
      const cleanupPending = pendingAgentCleanup;
      const pending = pendingPreparation;
      const terminal = pendingTerminal;
      if (
        agentPending === null &&
        cleanupPending === null &&
        pending === null &&
        terminal === null
      ) return outcome('blocked', state);
      if (retryPersistenceInFlight) return busyOutcome();
      retryPersistenceInFlight = true;
      try {
        if (agentPending !== null) {
          return await safeAgentPersist(
            agentPending.transaction,
            agentPending.continuation,
            agentPending.epoch,
            {
              conversationId: agentPending.conversationId,
              turnId: agentPending.turnId,
              attemptId: agentPending.attemptId,
            },
            agentPending.kind,
          );
        }
        if (cleanupPending !== null) {
          const durability = await safePersist();
          if (durability.status !== 'committed' || durability.snapshot === undefined) {
            return outcome('persistence_pending', state);
          }
          if (!cleanupPending.transaction.commit(durability.snapshot, cleanupPending.discardProof)) {
            // The first attempt rolls back, releases the latch and publishes;
            // this one did none of it. A commit refused on digest drift stays
            // refused, so the latch outlived every retry and kept blocking
            // send, retry, resume, cancel and conversation change in silence.
            cleanupPending.transaction.rollback();
            if (pendingAgentCleanup === cleanupPending) pendingAgentCleanup = null;
            publish(
              stateFor('blocked', {
                conversationId: cleanupPending.conversationId,
                turnId: cleanupPending.turnId,
                attemptId: cleanupPending.attemptId,
                failureCode: 'E_COMPLETION_RESULT_CORRELATION',
              }),
            );
            return outcome('blocked', state);
          }
          if (pendingAgentCleanup === cleanupPending) pendingAgentCleanup = null;
          const completedRun = agentRun;
          agentRun = null;
          publish(stateFor('idle'));
          try {
            completedRun?.events.onCommitted?.({
              conversationId: cleanupPending.conversationId,
              turnId: cleanupPending.turnId,
              attemptId: cleanupPending.attemptId,
            });
          } catch {
            // UI callbacks cannot affect durable cleanup.
          }
          return {
            status: 'completed',
            conversationId: cleanupPending.conversationId,
            turnId: cleanupPending.turnId,
            attemptId: cleanupPending.attemptId,
            code: null,
          };
        }
        if (terminal !== null) {
          return settleTerminalPersistence(terminal, await safePersist());
        }
        if (pending === null) return outcome('blocked', state);
        return await continuePreparation(
          pending.transaction,
          pending.conversationId,
          pending.events,
          pending.epoch,
          await safePersist(),
        );
      } finally {
        retryPersistenceInFlight = false;
      }
    },
    retryCommit: async () => {
      if (destructiveJournalActive()) return busyOutcome();
      if (state.phase === 'finalizing') return busyOutcome();
      const pending = pendingCommit;
      if (pending === null) return outcome('blocked', state);
      if (retryCommitInFlight) return busyOutcome();
      retryCommitInFlight = true;
      try {
        const durability = await safePersist();
        if (durability.status !== 'committed') {
          return outcome('commit_pending', state);
        }
        pendingCommit = null;
        publish(stateFor('idle'));
        notifyCommitted(pending);
        return {
          status: 'completed',
          conversationId: pending.conversationId,
          turnId: pending.turnId,
          attemptId: pending.attemptId,
          code: null,
        };
      } finally {
        retryCommitInFlight = false;
      }
    },
    cancel: async () => {
      if (destructiveJournalActive()) return;
      if (pendingAgentRecoveryRead !== null && agentRun?.epoch === pendingAgentRecoveryRead.epoch) {
        const read = pendingAgentRecoveryRead;
        const run = agentRun;
        epoch += 1;
        agentRun = null;
        read.stop();
        // Stopping an inspection is not proof of cancelling its underlying
        // attempt. Keep the journal unchanged and allow another explicit read.
        publish(stateFor('resume_available', {
          conversationId: run.conversationId, turnId: run.turnId,
          attemptId: run.attemptId, failureCode: 'E_AGENT_EXECUTION_AMBIGUOUS',
        }));
        lastCancellationCommitted = false;
        return;
      }
      if (
        pendingCommit !== null ||
        pendingTerminal !== null ||
        pendingAgentCleanup !== null ||
        state.phase === 'cancelling'
      )
        return;
      if (agentRun !== null) {
        requestedAgentCancellationEpoch = agentRun.epoch;
        lastCancellationCommitted = false;
        if (pendingAgentPersistence !== null ||
            getConversationAttempt(agentRun.conversationId, agentRun.attemptId)?.attempt.agent == null) {
          publish(stateFor('cancelling', { conversationId: agentRun.conversationId,
            turnId: agentRun.turnId, attemptId: agentRun.attemptId }));
          return;
        }
        await settleAgentCancellation();
        return;
      }
      epoch += 1;
      const cancelling = active;
      active = null;
      if (cancelling === null) {
        const pending = pendingPreparation;
        if (pending !== null) {
          if (pending.durability === null || retryPersistenceInFlight) {
            publish(
              stateFor('cancelling', {
                conversationId: pending.conversationId,
                turnId: pending.transaction.turnId,
                attemptId: pending.transaction.attemptId,
              }),
            );
            return;
          }
          pending.transaction.commit();
          pendingPreparation = null;
          const cancelled = dependencies.chat.cancelAttempt(
            pending.conversationId,
            pending.transaction.attemptId,
          );
          if (!cancelled) {
            lastCancellationCommitted = false;
            publish(
              stateFor('blocked', {
                conversationId: pending.conversationId,
                turnId: pending.transaction.turnId,
                attemptId: pending.transaction.attemptId,
                failureCode: 'E_COMPLETION_RESULT_CORRELATION',
              }),
            );
            return;
          }
          await persistTerminal({
            conversationId: pending.conversationId,
            turnId: pending.transaction.turnId,
            attemptId: pending.transaction.attemptId,
            successStatus: 'cancelled',
            failureCode: null,
            preparedNotification: {
              events: pending.events,
              transaction: pending.transaction,
            },
          });
          return;
        }
        lastCancellationCommitted = true;
        publish(stateFor('idle'));
        return;
      }
      publish(
        stateFor('cancelling', {
          conversationId: cancelling.conversationId,
          turnId: cancelling.turnId,
          attemptId: cancelling.attemptId,
          roundId: cancelling.roundId,
          transportSchemaVersion: cancelling.transportSchemaVersion,
        }),
      );
      try {
        if (cancelling.transportSchemaVersion === 3) {
          await dependencies.cancelRoundV3(cancelling.roundId);
        } else {
          await dependencies.cancelRoundV2(cancelling.roundId);
        }
      } catch {
        // Durable cancellation below remains authoritative.
      }
      const cancelled = dependencies.chat.cancelAttempt(
        cancelling.conversationId,
        cancelling.attemptId,
      );
      if (!cancelled) {
        lastCancellationCommitted = false;
        publish(
          stateFor('blocked', {
            conversationId: cancelling.conversationId,
            turnId: cancelling.turnId,
            attemptId: cancelling.attemptId,
            failureCode: 'E_COMPLETION_RESULT_CORRELATION',
          }),
        );
        return;
      }
      await persistTerminal({
        conversationId: cancelling.conversationId,
        turnId: cancelling.turnId,
        attemptId: cancelling.attemptId,
        successStatus: 'cancelled',
        failureCode: null,
        preparedNotification: null,
      });
    },
    beforeConversationChange: async conversationId => {
      if (destructiveJournalActive()) return false;
      if (
        state.phase === 'cancelling' &&
        state.conversationId === conversationId
      ) {
        return false;
      }
      if (
        pendingCommit?.conversationId === conversationId ||
        pendingAgentPersistence?.conversationId === conversationId ||
        pendingAgentCleanup?.conversationId === conversationId ||
        pendingPreparation?.conversationId === conversationId ||
        pendingTerminal?.conversationId === conversationId
      ) {
        return false;
      }
      if (agentRun?.conversationId === conversationId) {
        const onlyInspecting = pendingAgentRecoveryRead?.epoch === agentRun.epoch;
        await controller.cancel();
        // Navigation may leave a paused inspection without claiming that its
        // underlying native attempt has been durably cancelled.
        return onlyInspecting || lastCancellationCommitted;
      }
      if (active?.conversationId !== conversationId) return true;
      await controller.cancel();
      return lastCancellationCommitted;
    },
    beforeConversationDelete: async conversationId => {
      if (destructiveJournalActive()) return false;
      if (agentRun?.conversationId === conversationId && pendingAgentRecoveryRead?.epoch === agentRun.epoch) {
        await controller.cancel();
        return false;
      }
      const conversation = dependencies.chat.getState().conversations[conversationId];
      if (agentRun?.conversationId !== conversationId && conversation?.attempts.some(attempt =>
        attempt.agent != null && attempt.failureCode !== 'E_ATTEMPT_INTERRUPTED' &&
        !['final_response', 'cancelled', 'failed'].includes(attempt.agent.phase),
      )) return false;
      return await controller.beforeConversationChange(conversationId);
    },
    reconcileHydrated: conversationId => {
      if (destructiveJournalActive()) return state;
      if (
        active !== null ||
        pendingPreparation !== null ||
        pendingCommit !== null ||
        pendingTerminal !== null
      ) {
        return state;
      }
      const conversation = dependencies.chat.getState().conversations[conversationId];
      const turn = conversation?.turns.at(-1);
      const attemptId = turn?.attemptIds.at(-1);
      const attempt = conversation?.attempts.find(item => item.attemptId === attemptId);
      const completedAgentHasAssistant =
        attempt?.agent !== undefined &&
        attempt.agent !== null &&
        attempt.status === 'completed' &&
        attempt.agent.phase === 'final_response' &&
        attempt.assistantMessageId !== null &&
        conversation?.messages.some(
          message =>
            message.id === attempt.assistantMessageId &&
            message.role === 'assistant',
        ) === true;
      const cancelledAgent = attempt?.status === 'cancelled' &&
        attempt.agent?.phase === 'cancelled';
      if (completedAgentHasAssistant || cancelledAgent) {
        // A completed or cancelled Agent checkpoint is terminal and must never
        // re-enter provider/tool recovery after hydration. Transcript cleanup,
        // if still present in the durable outbox, remains independently owned
        // by that outbox and does not make the completed attempt resumable.
        publish(stateFor('idle'));
      } else if (
        attempt?.agent !== undefined &&
        attempt.agent !== null &&
        attempt.failureCode !== 'E_ATTEMPT_INTERRUPTED'
      ) {
        publish(
          stateFor('resume_available', {
            conversationId,
            turnId: attempt.turnId,
            attemptId: attempt.attemptId,
            roundId: attempt.agent.round_lineage?.round_id ?? null,
            transportSchemaVersion: agentTransportSchema(attempt),
            // What a cold start shows has to be what a warm one showed. An
            // unknown journal is the conflict the warm path publishes; an
            // ambiguous one is whichever uncertainty its batch records.
            failureCode:
              attempt.agent.phase === 'unknown'
                ? 'E_AGENT_CONFLICT'
                : attempt.agent.phase === 'ambiguous'
                  ? agentAmbiguityCode(attempt.agent)
                  : null,
          }),
        );
      } else if (attempt?.status === 'prepared' && attempt.rounds.length === 0) {
        publish(
          stateFor('resume_available', {
            conversationId,
            turnId: attempt.turnId,
            attemptId: attempt.attemptId,
          }),
        );
      } else if (attempt?.status === 'failed' || attempt?.status === 'cancelled') {
        publish(
          stateFor('retryable', {
            conversationId,
            turnId: attempt.turnId,
            attemptId: attempt.attemptId,
            failureCode: attempt.failureCode,
          }),
        );
      } else {
        publish(stateFor('idle'));
      }
      return state;
    },
  };
  return controller;
}
