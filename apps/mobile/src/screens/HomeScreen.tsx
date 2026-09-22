import { DshModelCatalog } from '../models/native';
import { isHarnessModelId } from '../harness/types';
import { glmAccountStatus, glmCredentialSource, glmSourceProvider } from '../harnessAuth/glmAccount';
import { codexChatSource, codexAvailableModels, claudeChatSource, type CodexChatSource } from '../harnessAuth/native';
import { getDshCatalog, subscribeDshCatalog, dshModelSupportsImages } from '../models/catalog';
import { useSyncExternalStore } from 'react';
import { withTaskExperience, cancelTaskExperienceRun } from '../taskExperience/controller';
import { useTaskActions } from '../taskExperience/useTaskActions';
import { ProviderConfigurations } from '../providers/native';
import type { ProviderConfiguration } from '../providers/configuration';
import { RecoveryNotice } from '../components/RecoveryNotice';
import { completionRecoveryLabel, recoveryCode } from '../components/recoveryMessage';
import React, {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from 'react';
import CircleAlert from 'lucide-react-native/icons/circle-alert';
import CircleEllipsis from 'lucide-react-native/icons/circle-ellipsis';
import LoaderCircle from 'lucide-react-native/icons/loader-circle';
import Menu from 'lucide-react-native/icons/menu';
import {
  Alert,
  AccessibilityInfo,
  findNodeHandle,
  KeyboardAvoidingView,
  ScrollView,
  Platform,
  Pressable,
  StyleSheet,
  Text,
  View,
  useWindowDimensions,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import {
  ChatComposer,
  type AttachmentSource,
} from '../components/ChatComposer';
import { ChatDrawer, type ConversationSummary } from '../components/ChatDrawer';
import { BrandMark } from '../components/BrandMark';
import { AppIcon } from '../components/AppIcon';
import { SpinningIcon } from '../components/SpinningIcon';
import { markTimingSync } from '../native/SessionSnapshots';

// The native module (or a test mock) may lack the timing mark; never let a
// missing diagnostic break the screen.
const markTiming = (label: string, elapsedMs: number): void => {
  try {
    markTimingSync(label, elapsedMs);
  } catch {}
};
import { AccountSheet } from '../components/AccountSheet';
import { ConversationActionSheet } from '../components/ConversationActionSheet';
import { EmptyChat } from '../components/EmptyChat';
import { MessageList, type DisplayMessage } from '../components/MessageList';
import { MirrorSettingsSheet } from '../components/MirrorSettingsSheet';
import { RuntimeEnvironmentSheet } from '../components/runtime-environment-sheet';
import { RuntimeProgramSheet } from '../components/runtime-program-sheet';
import { ConversationOptionsPicker } from '../components/ConversationOptionsPicker';
import { HarnessPicker } from '../components/HarnessPicker';
import type { StructuredBlock } from '../components/StructuredContent';
import { projectAgentActivity, projectRoundPreviews } from '../components/agentActivityProjection';
import { nativeAgentRoundPreviewSource } from '../agent/AgentRoundPreviewSource';
import type { AgentRoundPreviewState } from '../agent/AgentRoundPreview';
import { readAgentAttemptPresentation, type AgentAttemptPresentation } from '../agent/AgentRoundPresentation';
import {
  ModelPicker,
  type SupportedModel,
} from '../components/ModelPicker';
import { LocalWorkspaces } from '../native/LocalWorkspaces';
import {
  createWorkspaceGitActivation,
  workspaceGitActivationError as gitActivationErrorCode,
} from '../workspaces/workspace-git-activation';
import { createProjectWorkspaceRootResolver } from '../native/projectWorkspaceRoot';
import { ProjectsSurface } from '../components/ProjectsSurface';
import {
  ProjectContextSheet,
  type ProjectContextSheetBusyAction,
  type ProjectContextSheetFilter,
  type ProjectContextSheetMode,
  type ProjectContextSheetRecoveryAction,
} from '../components/ProjectContextSheet';
import {
  ProjectContextStrip,
  type ProjectContextVerificationStatus,
} from '../components/ProjectContextStrip';
import {
  RuntimeEvidenceSheet,
  type RuntimeVerificationStatus,
} from '../components/RuntimeEvidenceSheet';
import { SettingsSheet } from '../components/SettingsSheet';
import { WorkspaceDrawer } from '../components/WorkspaceDrawer';
import { WorkspacePickerSheet } from '../components/WorkspacePickerSheet';
import {
  createChatStore,
  MAX_ATTACHMENTS_PER_MESSAGE,
  MAX_TOTAL_ATTACHMENT_SIZE,
  safeHydrateChatState,
  selectActiveConversation,
  selectConversationById,
  selectProjectContextSnapshotReferences,
  selectOrderedConversations,
  serializeChatState,
  type ChatState,
  type Conversation,
  type AttachmentDescriptor,
  type NativeAgentDiscardProofV1,
  type SessionAuthority,
  type SnapshotFreeProjectMutationTransaction,
} from '../state';
import { createColdStartConversationSelection } from '../state/coldStartConversation';
import type { InterruptAgentAttemptResultV2 } from '../native/AgentRuntime';
import {
  LocalRuntime,
  type ModelTransitionSource,
  type RuntimeProof,
} from '../native/LocalRuntime';
import {
  createCompletionController,
  type CompletionAgentApprovalRequest,
  type CompletionAgentQuestionRequest,
  type CompletionControllerOutcome,
  type CompletionControllerState,
  type CompletionPersistenceResult,
} from '../completion/CompletionController';
import {
  createAgentInteractionController,
  type AgentInteractionController,
  type AgentInteractionState,
} from '../agent/AgentInteractionController';
import { ApprovalComposer } from '../components/ApprovalComposer';
import {
  AgentPolicySheet,
} from '../components/AgentPolicySheet';
import { projectAgentPolicy } from '../components/agent-policy-projection';
import { useAgentPolicy } from '../components/use-agent-policy';
import { QuestionComposer } from '../components/QuestionComposer';
import { DEFAULT_APPROVAL_TIMEOUT_MS } from '../agent/AgentApprovals';
import {
  createSessionPersistenceCoordinator,
  sessionSnapshotSHA256,
  type LoadSessionSnapshotResultV1,
  type SessionCASPersistResultV1,
  type SessionCommitQueryResultV1,
  type SessionDurabilityResult,
  type SessionSnapshotAuthorityV1,
  type SessionSnapshotRefV1,
} from '../completion/SessionPersistence';
import { readRuntimeEvidence } from '../runtime/evidence';
import { LocalProjects, type LocalProject } from '../native/LocalProjects';
import { workspaceProjectName } from '../native/workspaceProjects';
import type { WorkspaceDescriptorV2 } from '../native/LocalWorkspaces';
import { LocalProjectContext } from '../native/LocalProjectContext';
import { LocalAttachments } from '../native/LocalAttachments';
import {
  BUILTIN_HARNESSES,
  DSH_HARNESS,
  getHarnessAdapter,
  harnessForModel,
  isHarnessId,
} from '../harness';
import { defaultModelForHarness } from './harnessSelection';

async function bootstrapForHarness(harnessId: string) {
  const runtime = LocalRuntime as typeof LocalRuntime & {
    bootstrapForHarness?: (id: string) => Promise<{ proof: RuntimeProof }>;
  };
  return typeof runtime.bootstrapForHarness === 'function'
    ? runtime.bootstrapForHarness(harnessId)
    : harnessId === 'dsh'
      ? runtime.bootstrap()
      : Promise.reject(new Error('Harness-aware runtime bootstrap is unavailable'));
}
import {
  createProjectContextController,
  createProjectContextLifecycleController,
  isProjectContextSendable,
  type ProjectContextActionToken,
  type ProjectContextControllerOwner,
  type ProjectContextControllerState,
  type ProjectContextDestructiveBeginToken,
  type ProjectContextDestructiveOutcome,
  type ProjectContextDestructiveToken,
  type ProjectContextLifecycleControllerState,
} from '../project-context';
import { useAppPresentation } from '../presentation/AppPresentation';
import { useKeyboardHeight } from '../layout/keyboard';
import {
  resolveAdaptiveLayout,
  WIDE_CONTENT_MAX_WIDTH,
  WIDE_SIDEBAR_WIDTH,
} from '../layout/adaptive';
import { fonts, hitSlop, type ThemePalette } from '../theme';
import { seedMarkdownDemoConversation } from '../dev/markdownDemo';
import { SessionSnapshots } from '../native/SessionSnapshots';
import { AgentRuntime } from '../native/AgentRuntime';
import {
  WorkspaceBindingController,
} from '../workspaces/WorkspaceBindingController';
import {
  WorkspaceRemovalCoordinator,
  type WorkspaceRemovalAction,
  type WorkspaceRemovalOutcome,
  type WorkspaceRemovalTarget,
} from '../workspaces/WorkspaceRemoval';
import {
  assertWorkspaceRootRefV1,
  type WorkspaceRootRefV1,
} from '../native/WorkspaceRoot';

type RequestState = 'idle' | 'sending';

type PendingSessionWrite = {
  readonly operationId: string;
  readonly candidateJSON: string;
  readonly candidateDigest: string;
};

const MAX_PENDING_SESSION_WRITES = 16;

type PendingContextOpen = {
  readonly conversationId: string;
  readonly projectId: string;
  readonly runtimeContextId: string | null;
  readonly modelId: Conversation['modelId'];
  readonly uiEpoch: number;
};

type PendingProjectSend = {
  readonly conversationId: string;
  readonly uiEpoch: number;
  readonly text: string;
  readonly attachments: readonly AttachmentDescriptor[];
  readonly attachmentIds: readonly string[];
};

type PendingProjectSendStage = 'recovery' | 'context_flow';
type PendingContextDismissAction = {
  readonly kind: 'verified' | 'without_context';
  readonly pendingEpoch: number;
};

type ProjectContextLifecycleIntent = {
  readonly nonce: number;
  readonly action: 'unbind' | 'delete' | 'rebind';
  readonly conversationId: string;
  readonly selectedConversationId: string | null;
  readonly targetProjectId: string | null;
  readonly beginToken: ProjectContextDestructiveBeginToken;
};

type ConversationDeleteRequest = {
  readonly actionEpoch: number;
  readonly completionEpoch: number;
  readonly selectedConversationId: string | null;
  readonly conversation: Conversation;
};

type DirectProjectMutationOutbox = {
  readonly action: 'unbind' | 'delete' | 'rebind';
  readonly conversationId: string;
  readonly targetProjectId: string | null;
  readonly targetProjectName: string | null;
  readonly expectedConversation: Conversation;
  readonly selectedConversationId: string | null;
  readonly transaction: SnapshotFreeProjectMutationTransaction | null;
  readonly sourceProjectsEpoch: number | null;
};

type DirectProjectMutationView = Pick<
  DirectProjectMutationOutbox,
  'action' | 'conversationId' | 'targetProjectId' | 'targetProjectName'
>;

function sameDeleteOwner(
  current: Conversation | null,
  expected: Conversation,
): boolean {
  return (
    current !== null &&
    current.id === expected.id &&
    current.projectId === expected.projectId &&
    current.workspaceId === expected.workspaceId &&
    current.runtimeContextId === expected.runtimeContextId &&
    current.projectContext === expected.projectContext &&
    current.title === expected.title &&
    current.titleSource === expected.titleSource &&
    current.modelId === expected.modelId &&
    current.thinkingMode === expected.thinkingMode &&
    current.messages === expected.messages &&
    current.turns === expected.turns &&
    current.createdAt === expected.createdAt
  );
}

function copyPendingAttachment(
  attachment: AttachmentDescriptor,
): AttachmentDescriptor {
  return Object.freeze({
    schema_version: attachment.schema_version,
    id: attachment.id,
    kind: attachment.kind,
    name: attachment.name,
    mime_type: attachment.mime_type,
    size: attachment.size,
  });
}

function sameOrderedAttachmentIds(
  attachments: readonly AttachmentDescriptor[],
  expectedIds: readonly string[],
): boolean {
  return (
    attachments.length === expectedIds.length &&
    attachments.every(
      (attachment, index) => attachment.id === expectedIds[index],
    )
  );
}

function sameSessionSnapshotAuthority(
  left: SessionSnapshotAuthorityV1,
  right: SessionSnapshotAuthorityV1,
): boolean {
  if (left.kind !== right.kind) return false;
  if (left.kind === 'missing' || right.kind === 'missing') return true;
  if (left.kind === 'legacy_present' && right.kind === 'legacy_present') {
    return (
      left.legacy.legacy_bytes_sha256 === right.legacy.legacy_bytes_sha256
    );
  }
  if (left.kind !== 'present' || right.kind !== 'present') return false;
  return (
    left.snapshot.generation === right.snapshot.generation &&
    left.snapshot.session_sha256 === right.snapshot.session_sha256
  );
}

const ATTACHMENT_PICKER_TIMEOUT_MS = 120_000;

function waitForAttachmentPicker<T>(
  operation: Promise<T>,
  timeoutMessage: string,
): Promise<T> {
  return new Promise((resolve, reject) => {
    let settled = false;
    const timeout = setTimeout(() => {
      settled = true;
      reject(new Error(timeoutMessage));
    }, ATTACHMENT_PICKER_TIMEOUT_MS);
    operation.then(
      value => {
        if (settled) return;
        settled = true;
        clearTimeout(timeout);
        resolve(value);
      },
      error => {
        if (settled) return;
        settled = true;
        clearTimeout(timeout);
        reject(error);
      },
    );
  });
}

function errorText(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function completionBusy(state: CompletionControllerState): boolean {
  return (
    state.phase === 'preparing' ||
    state.phase === 'persistence_pending' ||
    state.phase === 'resume_available' ||
    state.phase === 'starting' ||
    state.phase === 'sending' ||
    state.phase === 'approval_pending' ||
    state.phase === 'executing' ||
    state.phase === 'recovering' ||
    state.phase === 'cancelling' ||
    state.phase === 'finalizing' ||
    state.phase === 'commit_pending'
  );
}

function completionCancellable(state: CompletionControllerState): boolean {
  return (
    state.phase === 'preparing' ||
    state.phase === 'starting' ||
    state.phase === 'sending' ||
    state.phase === 'approval_pending' ||
    state.phase === 'executing' ||
    state.phase === 'recovering'
  );
}

function completionOwnsPresentation(
  state: CompletionControllerState,
  conversationId: string,
): boolean {
  return state.conversationId === conversationId && state.phase !== 'idle';
}

function completionBlocksContextMutation(
  state: CompletionControllerState,
  conversationId: string,
): boolean {
  return state.conversationId === conversationId && completionBusy(state);
}

function projectContextOwnsMutation(
  state: ProjectContextControllerState,
): boolean {
  return (
    state.phase === 'inspecting' ||
    state.phase === 'preparing' ||
    state.phase === 'review' ||
    state.phase === 'confirming' ||
    state.phase === 'disabling' ||
    state.phase === 'persistence_pending' ||
    state.phase === 'cleanup_pending' ||
    state.candidateManifest !== null ||
    state.list.loading ||
    state.list.loadingMore
  );
}

function projectContextOperationInFlight(
  state: ProjectContextControllerState,
): boolean {
  return (
    state.phase === 'inspecting' ||
    state.phase === 'preparing' ||
    state.phase === 'confirming' ||
    state.phase === 'disabling' ||
    state.phase === 'persistence_pending' ||
    state.phase === 'cleanup_pending' ||
    state.list.loading ||
    state.list.loadingMore
  );
}

function sameProjectContextOwner(
  owner: ProjectContextControllerOwner | null,
  conversation: Conversation | null,
): boolean {
  return (
    owner !== null &&
    conversation !== null &&
    conversation.projectId !== null &&
    owner.conversationId === conversation.id &&
    owner.projectId === conversation.projectId &&
    owner.runtimeContextId === conversation.runtimeContextId &&
    owner.modelId === conversation.modelId
  );
}

function sameConversationOwner(
  expected: Conversation | null,
  current: Conversation | null,
): boolean {
  return (
    expected === null
      ? current === null
      : current !== null &&
        current.id === expected.id &&
        current.projectId === expected.projectId &&
        current.runtimeContextId === expected.runtimeContextId &&
        current.modelId === expected.modelId &&
        current.projectContext === expected.projectContext
  );
}

function sameProjectContextToken(
  left: ProjectContextActionToken | null,
  right: ProjectContextActionToken | null,
): boolean {
  return (
    left !== null &&
    right !== null &&
    left.conversationId === right.conversationId &&
    left.projectId === right.projectId &&
    left.runtimeContextId === right.runtimeContextId &&
    left.modelId === right.modelId &&
    left.generation === right.generation &&
    left.preparationId === right.preparationId &&
    left.listGeneration === right.listGeneration
  );
}

function sameDestructiveBeginToken(
  left: ProjectContextDestructiveBeginToken,
  right: ProjectContextDestructiveBeginToken,
): boolean {
  return (
    left.expectedRootEpoch === right.expectedRootEpoch &&
    left.action === right.action &&
    left.conversationId === right.conversationId &&
    left.sourceProjectId === right.sourceProjectId &&
    left.sourceRuntimeContextId === right.sourceRuntimeContextId &&
    left.sourceModelId === right.sourceModelId &&
    left.snapshotId === right.snapshotId &&
    left.snapshotSha256 === right.snapshotSha256 &&
    left.consentReceiptId === right.consentReceiptId &&
    left.expectedUpdatedAt === right.expectedUpdatedAt &&
    left.targetProjectId === right.targetProjectId
  );
}

function sameDestructiveToken(
  left: ProjectContextDestructiveToken,
  right: ProjectContextDestructiveToken | null,
): boolean {
  return (
    right !== null &&
    left.generation === right.generation &&
    left.lifecycleId === right.lifecycleId &&
    left.epoch === right.epoch &&
    left.action === right.action &&
    left.conversationId === right.conversationId &&
    left.sourceProjectId === right.sourceProjectId &&
    left.sourceRuntimeContextId === right.sourceRuntimeContextId &&
    left.sourceModelId === right.sourceModelId &&
    left.snapshotId === right.snapshotId &&
    left.snapshotSha256 === right.snapshotSha256 &&
    left.consentReceiptId === right.consentReceiptId &&
    left.targetProjectId === right.targetProjectId &&
    left.phase === right.phase
  );
}

function scheduleProjectContextSearch(
  delayMilliseconds: number,
  operation: () => void,
) {
  let active = true;
  const timer = setTimeout(() => {
    if (!active) return;
    active = false;
    operation();
  }, delayMilliseconds);
  return {
    cancel: () => {
      if (!active) return;
      active = false;
      clearTimeout(timer);
    },
  };
}

function completionOwnershipKey(
  state: CompletionControllerState,
  conversationId: string | null,
  uiEpoch: number,
): string {
  return JSON.stringify([
    uiEpoch,
    conversationId,
    state.epoch,
    state.phase,
    state.conversationId,
    state.turnId,
    state.attemptId,
    state.roundId,
  ]);
}

function summaryFor(conversation: Conversation): ConversationSummary {
  const last = conversation.messages.at(-1);
  const latestAttempt = conversation.attempts.at(-1);
  return {
    id: conversation.id,
    title: conversation.title,
    preview:
      last?.text ||
      last?.attachments?.map(attachment => attachment.name).join(', ') ||
      '',
    updatedAt: Date.parse(conversation.updatedAt),
    messageCount: conversation.messages.length,
    ...(latestAttempt?.status === 'failed' &&
    latestAttempt.failureCode === 'E_ATTEMPT_INTERRUPTED'
      ? { interrupted: true }
      : {}),
  };
}

export function displayMessages(
  conversation: Conversation | null,
  previews: Readonly<Record<string, string>>,
  sessionEvents: readonly import('../state/types').PersistedSessionEventV3[] = [],
  presentations: Readonly<Record<string, AgentAttemptPresentation>> = {},
  roundPreviews: Readonly<Record<string, AgentRoundPreviewState>> = {},
  pendingAttemptId: string | null = null,
  labels: { readonly thinking: string } = { thinking: 'Thinking' },
): DisplayMessage[] {
  const rendered = (conversation?.messages ?? []).map(message => {
    const attempt = conversation?.attempts.find(item => item.assistantMessageId === message.id);
    const projectedTools = attempt === undefined ? [] : projectAgentActivity(sessionEvents, attempt.attemptId, presentations[attempt.attemptId], true);
    const blocks: StructuredBlock[] | undefined =
      message.role === 'assistant' && message.metadata?.reasoning !== undefined
        ? [
            ...projectedTools,
            {
              id: `${message.id}-reasoning`,
              type: 'reasoning',
              text: message.metadata.reasoning,
            },
            { id: `${message.id}-text`, type: 'text', text: message.text },
          ]
        : projectedTools.length > 0 ? [...projectedTools, { id: `${message.id}-text`, type: 'text', text: message.text }] : undefined;
    const providerBinding = attempt?.rounds.at(-1)?.providerConfiguration;
    return {
      id: message.id,
      role: message.role,
      text: message.text,
      ...(providerBinding === undefined ? {} : { providerLabel: new URL(providerBinding.endpoint_url).host }),
      modelId: message.metadata?.modelId ?? attempt?.modelId,
      ...(message.attachments === undefined || message.attachments.length === 0
        ? {}
        : {
            attachments: message.attachments.map(attachment => ({
              ...attachment,
              ...(attachment.thumbnail_data_url !== undefined
                ? {}
                : previews[attachment.id] === undefined
                ? {}
                : { thumbnail_data_url: previews[attachment.id] }),
            })),
          }),
      ...(blocks === undefined ? {} : { blocks }),
      ...(message.metadata === undefined
        ? {}
        : {
            meta: [
              providerBinding?.model_id ?? message.metadata.modelId,
              message.metadata.latencyMs === undefined
                ? undefined
                : `${message.metadata.latencyMs} ms`,
            ]
              .filter(Boolean)
              .join(' · '),
          }),
    };
  });
  if (conversation === null) return rendered;
  const synthetic = new Map<string, DisplayMessage[]>();
  const orderedAttempts = conversation.attempts.slice().sort((a, b) => Date.parse(a.createdAt) - Date.parse(b.createdAt));
  for (const attempt of orderedAttempts) {
    if (attempt.assistantMessageId !== null) continue;
    const blocks = projectAgentActivity(sessionEvents, attempt.attemptId, presentations[attempt.attemptId]);
    // Streamed material of rounds still in flight, then a bare "thinking"
    // placeholder while the round is being prepared or sent.
    blocks.push(...projectRoundPreviews(roundPreviews, attempt.attemptId, sessionEvents, presentations[attempt.attemptId], labels));
    if (blocks.length === 0 && attempt.attemptId === pendingAttemptId) {
      blocks.push({ id: `pending-${attempt.attemptId}`, type: 'activity', label: labels.thinking });
    }
    if (blocks.length === 0) continue;
    const turn = conversation.turns.find(item => item.turnId === attempt.turnId);
    if (turn === undefined) continue;
    const entry = { id: `activity-${attempt.attemptId}`, role: 'assistant' as const, text: '', modelId: attempt.modelId, blocks };
    const existing = synthetic.get(turn.userMessageId) ?? [];
    existing.push(entry); synthetic.set(turn.userMessageId, existing);
  }
  if (synthetic.size === 0) return rendered;
  const merged: DisplayMessage[] = [];
  for (const message of rendered) { merged.push(message); const activities = synthetic.get(message.id); if (activities) merged.push(...activities); }
  return merged;
}

export function HomeScreen({
  seedMarkdownDemo = false,
}: {
  seedMarkdownDemo?: boolean;
}) {
  const insets = useSafeAreaInsets();
  const keyboardHeight = useKeyboardHeight();
  const { width: windowWidth } = useWindowDimensions();
  const { isWide: wideLayout } = resolveAdaptiveLayout(windowWidth);
  const {
    colors,
    locale,
    preferences,
    store: preferencesStore,
    t,
  } = useAppPresentation();
  const styles = useMemo(() => createStyles(colors), [colors]);
  const shell = useMemo(readRuntimeEvidence, []);
  const store = useMemo(
    () =>
      createChatStore({
        createId: () => LocalRuntime.createCompletionRequestId(),
      }),
    [],
  );
  const selectColdStartConversation = useMemo(createColdStartConversationSelection, []);
  const [chatState, setChatState] = useState<ChatState>(() => store.getState());
  const [draft, setDraft] = useState('');
  const draftRef = useRef('');
  draftRef.current = draft;
  const [draftAttachments, setDraftAttachments] = useState<
    readonly AttachmentDescriptor[]
  >([]);
  const draftAttachmentsRef = useRef<readonly AttachmentDescriptor[]>([]);
  draftAttachmentsRef.current = draftAttachments;
  const [attachmentBusy, setAttachmentBusy] = useState(false);
  const [attachmentNotice, setAttachmentNotice] = useState<string | null>(null);
  // Conversation that was last sent without a workspace while the agent
  // runtime was available: the turn silently ran as plain chat, so the hint
  // stays until a workspace is bound or the chat changes.
  const [workspaceHintConversationId, setWorkspaceHintConversationId] =
    useState<string | null>(null);
  const [attachmentPreviews, setAttachmentPreviews] = useState<
    Readonly<Record<string, string>>
  >({});
  const [previewingAttachmentId, setPreviewingAttachmentId] = useState<
    string | null
  >(null);
  const [drawerVisible, setDrawerVisible] = useState(false);
  const drawerVisibleRef = useRef(false);
  drawerVisibleRef.current = drawerVisible;
  const drawerSurfaceEpoch = useRef(0);
  const [accountVisible, setAccountVisible] = useState(false);
  const [settingsVisible, setSettingsVisible] = useState(false);
  const [settingsAuthOnly, setSettingsAuthOnly] = useState(false);
  const settingsVisibleRef = useRef(false);
  settingsVisibleRef.current = settingsVisible;
  const settingsSurfaceEpoch = useRef(0);
  const [composerOptionsVisible, setComposerOptionsVisible] = useState(false);
  const [workspaceSheetVisible, setWorkspaceSheetVisible] = useState(false);
  const workspaceSheetVisibleRef = useRef(false);
  const [workspaceNames, setWorkspaceNames] = useState<
    Readonly<Record<string, string>>
  >({});
  const [workspaceDescriptors, setWorkspaceDescriptors] = useState<
    Readonly<Record<string, WorkspaceDescriptorV2>>
  >({});
  const [agentPolicyVisible, setAgentPolicyVisible] = useState(false);
  const [agentPolicyRevokeBusy, setAgentPolicyRevokeBusy] = useState(false);
  const [agentPolicyRevokeFailed, setAgentPolicyRevokeFailed] = useState<
    string | null
  >(null);
  const [workspaceRefreshToken, setWorkspaceRefreshToken] = useState(0);
  const workspacePickerGenerationRef = useRef(0);
  const [workspacePickerGeneration, setWorkspacePickerGeneration] =
    useState(0);
  const workspacePickerOwnersRef = useRef(
    new Map<number, { conversation: Conversation | null; surfaceNonce: number }>(),
  );
  const workspaceSurfaceNonceRef = useRef(0);
  const [workspaceRoute, setWorkspaceRoute] = useState<{
    readonly root: WorkspaceRootRefV1;
    readonly label: string;
    readonly conversationId: string | null;
    readonly projectId: string | null;
  } | null>(null);
  const [modelVisible, setModelVisible] = useState(false);
  const [mirrorsVisible, setMirrorsVisible] = useState(false);
  const [environmentsVisible, setEnvironmentsVisible] = useState(false);
  const [programVisible, setProgramVisible] = useState(false);
  const [programContext, setProgramContext] = useState<{
    root: WorkspaceRootRefV1;
    label: string;
    conversationId: string | null;
  } | null>(null);
  const pendingProgramOpenRef = useRef<{
    source: 'files' | 'environments';
    context: NonNullable<typeof programContext>;
    selectedConversationId: string | null;
  } | null>(null);
  const programOpenBlockedRef = useRef(true);
  const [harnessesVisible, setHarnessesVisible] = useState(false);
  const harnessesVisibleRef = useRef(false);
  harnessesVisibleRef.current = harnessesVisible;
  const [evidenceVisible, setEvidenceVisible] = useState(false);
  const [workspaceVisible, setWorkspaceVisible] = useState(false);
  const workspaceVisibleRef = useRef(false);
  workspaceSheetVisibleRef.current = workspaceSheetVisible;
  workspaceVisibleRef.current = workspaceVisible;
  const [projectsVisible, setProjectsVisible] = useState(false);
  const projectsVisibleRef = useRef(false);
  projectsVisibleRef.current = projectsVisible;
  const projectsSurfaceEpoch = useRef(0);
  const [contextSheetVisible, setContextSheetVisible] = useState(false);
  const contextSheetVisibleRef = useRef(false);
  contextSheetVisibleRef.current = contextSheetVisible;
  const navigationSurfaceVisibleRef = useRef(false);
  const lifecycleBootstrapReadyRef = useRef(false);
  const [lifecycleBootstrapReady, setLifecycleBootstrapReady] =
    useState(false);
  const lifecycleIntentNonce = useRef(0);
  const lifecycleActionInFlight = useRef(false);
  const [lifecycleIntent, setLifecycleIntent] =
    useState<ProjectContextLifecycleIntent | null>(null);
  const lifecycleIntentRef = useRef<ProjectContextLifecycleIntent | null>(
    null,
  );
  lifecycleIntentRef.current = lifecycleIntent;
  const [lifecycleSheetTargetId, setLifecycleSheetTargetId] = useState<
    string | null
  >(null);
  const [directProjectMutationView, setDirectProjectMutationView] =
    useState<DirectProjectMutationView | null>(null);
  const directProjectMutationOutboxRef =
    useRef<DirectProjectMutationOutbox | null>(null);
  const directProjectMutationPersistenceInFlight = useRef(false);
  const [contextSheetFilter, setContextSheetFilter] =
    useState<ProjectContextSheetFilter>('all');
  const [pendingProjectSend, setPendingProjectSend] =
    useState<PendingProjectSend | null>(null);
  const [pendingProjectSendStage, setPendingProjectSendStage] =
    useState<PendingProjectSendStage | null>(null);
  const pendingProjectSendRef = useRef<PendingProjectSend | null>(null);
  const pendingProjectSendEpoch = useRef(0);
  const pendingContextDismissAction =
    useRef<PendingContextDismissAction | null>(null);
  const pendingProjectSendActionInFlight = useRef(false);
  const [projectFilesScope, setProjectFilesScope] =
    useState<LocalProject | null>(null);
  const [projectRefreshToken, setProjectRefreshToken] = useState(0);
  const [activeProjectName, setActiveProjectName] = useState<string | null>(
    null,
  );
  const [actionConversationId, setActionConversationId] = useState<
    string | null
  >(null);
  const conversationActionEpoch = useRef(0);
  const [credentialConfiguredValue, setCredentialConfigured] = useState(false);
  const [credentialHarnessId, setCredentialHarnessId] = useState<string | null>(null);
  const [credentialBusy, setCredentialBusy] = useState(false);
  const [runtimeChecking, setRuntimeChecking] = useState(true);
  const [proof, setProof] = useState<RuntimeProof | null>(null);
  const [runtimeFailure, setRuntimeFailure] = useState<string | null>(null);
  const [requestFailure, setRequestFailure] = useState<string | null>(null);
  const [storageWarning, setStorageWarning] = useState<string | null>(null);
  const [sessionLoadFailure, setSessionLoadFailure] = useState<string | null>(null);
  const sessionReloadBusy = useRef(false);
  // Native authority alone cannot authorize replacing chats we never loaded.
  const sessionProjectionReady = useRef(false);
  const verifiedSessionMigration = useRef<{
    candidateJSON: string;
    expected: SessionSnapshotAuthorityV1;
  } | null>(null);
  const [workspaceBindingRecoveryVisible, setWorkspaceBindingRecoveryVisible] =
    useState(false);
  const attachmentOperationGeneration = useRef(0);
  const activeAttachmentOperation = useRef<{
    generation: number;
    conversationId: string;
    stale: boolean;
  } | null>(null);
  const activeAttachmentPreviewId = useRef<string | null>(null);
  const afterDrawerDismiss = useRef<(() => void) | null>(null);
  const afterActionDismiss = useRef<(() => void) | null>(null);
  const pendingContextOpenAfterProjectsDismiss =
    useRef<PendingContextOpen | null>(null);
  const pendingContextAttachAfterOpen = useRef<PendingContextOpen | null>(null);
  const pendingLifecycleOpenAfterProjectsDismiss =
    useRef<ProjectContextLifecycleIntent | null>(null);
  const pendingExistingLifecycleAfterProjectsDismiss =
    useRef<ProjectContextDestructiveToken | null>(null);
  const pendingDirectOpenAfterProjectsDismiss =
    useRef<DirectProjectMutationView | null>(null);
  const pendingLifecycleOpenAfterDrawerDismiss = useRef<{
    readonly intent: ProjectContextLifecycleIntent | null;
    readonly token: ProjectContextDestructiveToken | null;
    readonly direct: DirectProjectMutationView | null;
  } | null>(null);
  const projectChatTransitionInFlight = useRef(false);
  const navigationMutationInFlight = useRef(false);
  const projectContextUiEpoch = useRef(0);
  const projectContextStripRef =
    useRef<React.ElementRef<typeof View> | null>(null);
  const projectContextStripTarget = useRef<number | null>(null);
  const completionUiEpoch = useRef(0);
  const retryActionInFlight = useRef(false);
  const started = useRef(false);
  const nativeAvailable = useMemo(() => LocalRuntime.isAvailable(), []);
  // Forget and delete are only offered where native can carry them out;
  // elsewhere the picker keeps its inert legacy button.
  const workspaceRemovalAvailable = useMemo(() => LocalWorkspaces.isRemovalAvailable(), []);
  const [sessionSnapshotsAvailable, setSessionSnapshotsAvailable] = useState<
    boolean | null
  >(
    () => (SessionSnapshots.isAvailable() ? true : null),
  );
  const sessionSnapshotsAvailableRef = useRef(sessionSnapshotsAvailable === true);
  sessionSnapshotsAvailableRef.current = sessionSnapshotsAvailable === true;
  const [selectionHydrated, setSelectionHydrated] = useState(false);
  const activeConversation = selectActiveConversation(chatState);
  const activeHarness =
    BUILTIN_HARNESSES.get(
      activeConversation === null
        ? preferences.selectedHarnessId
        : harnessForModel(activeConversation.modelId),
    ) ?? DSH_HARNESS;
  const activeHarnessId = isHarnessId(activeHarness.id)
    ? activeHarness.id
    : 'dsh';
  const activeHarnessIdRef = useRef(activeHarnessId);
  activeHarnessIdRef.current = activeHarnessId;
  const activeAdapter = getHarnessAdapter(activeHarnessId);
  const dshCatalog = useSyncExternalStore(subscribeDshCatalog, getDshCatalog);
  const [providerConfigurationRevision, setProviderConfigurationRevision] = useState(0);
  const [claudeSource, setClaudeSource] = useState<CodexChatSource | null>(null);
  const [claudeSourceChecking, setClaudeSourceChecking] = useState(false);
  useEffect(() => {
    let cancelled = false;
    setClaudeSource(null);
    if (!selectionHydrated || !lifecycleBootstrapReady || activeHarnessId !== 'claude-code' || !nativeAvailable) { setClaudeSourceChecking(false); return; }
    setClaudeSourceChecking(true);
    claudeChatSource().then(source => { if (!cancelled) setClaudeSource(source); })
      .finally(() => { if (!cancelled) setClaudeSourceChecking(false); });
    return () => { cancelled = true; };
  }, [activeHarnessId, selectionHydrated, lifecycleBootstrapReady, nativeAvailable, providerConfigurationRevision, settingsVisible]);
  const claudeSubscriptionSelected = activeHarnessId === 'claude-code' && claudeSource?.source === 'subscription';
  const [codexModels, setCodexModels] = useState<readonly {id: string; name: string}[] | null>(null);
  const [codexModelsLoading, setCodexModelsLoading] = useState(false);
  useEffect(() => {
    let cancelled = false;
    setCodexModels(null);
    if (!selectionHydrated || !lifecycleBootstrapReady || activeHarnessId !== 'codex' || !nativeAvailable) { setCodexModelsLoading(false); return; }
    setCodexModelsLoading(true);
    codexChatSource().then(async source => {
      if (cancelled || source.source !== 'subscription' || !source.ready) return;
      const models = await codexAvailableModels();
      if (!cancelled) setCodexModels(models);
    }).catch(() => { if (!cancelled) setRuntimeFailure('E_CODEX_MODEL_CATALOG'); })
      .finally(() => { if (!cancelled) setCodexModelsLoading(false); });
    return () => { cancelled = true; };
  }, [activeHarnessId, selectionHydrated, lifecycleBootstrapReady, nativeAvailable, providerConfigurationRevision, settingsVisible]);
  const [glmSubscriptionState, setGlmSubscriptionState] = useState<'signed_in' | 'needs_login' | null>(null);
  useEffect(() => {
    let cancelled = false;
    setGlmSubscriptionState(null);
    if (selectionHydrated && lifecycleBootstrapReady && nativeAvailable && activeHarnessId === 'glm') {
      glmCredentialSource().then(async source => {
        if (cancelled) return;
        const provider = glmSourceProvider(source.source);
        if (!provider) return;
        const account = await glmAccountStatus(provider);
        if (!cancelled) setGlmSubscriptionState(account.status === 'signed_in' ? 'signed_in' : 'needs_login');
      }).catch(() => undefined);
    }
    return () => { cancelled = true; };
  }, [activeHarnessId, selectionHydrated, lifecycleBootstrapReady, nativeAvailable, providerConfigurationRevision, settingsVisible]);
  const subscriptionNeedsAttention = activeHarnessId === 'glm' && glmSubscriptionState !== null;
  const [providerOverride, setProviderOverride] = useState<ProviderConfiguration | null>(null);
  useEffect(() => {
    let cancelled = false;
    setProviderOverride(null);
    if (selectionHydrated && lifecycleBootstrapReady && nativeAvailable && (activeHarnessId === 'claude-code' || activeHarnessId === 'codex') && ProviderConfigurations.isAvailable()) {
      ProviderConfigurations.read(activeHarnessId).then(async value => {
        if (cancelled) return;
        const subscription = activeHarnessId === 'codex' ? (await codexChatSource()).source === 'subscription'
          : (await claudeChatSource()).source === 'subscription';
        if (!cancelled) setProviderOverride(subscription || value.official ? null : value);
      }).catch(() => undefined);
    }
    return () => { cancelled = true; };
  }, [activeHarnessId, selectionHydrated, lifecycleBootstrapReady, nativeAvailable, providerConfigurationRevision]);
  const providerName = (providerOverride?.harness_id === activeHarnessId ? providerOverride.name : null) ?? {
    dsh: 'DeepSeek',
    'claude-code': 'Anthropic',
    codex: 'OpenAI',
    glm: 'Zhipu GLM',
  }[activeHarnessId];
  const credentialConfigured =
    claudeSubscriptionSelected ? claudeSource.ready : credentialHarnessId === activeHarnessId && credentialConfiguredValue;
  // A cold launch (or Harness switch) has not established that the key is
  // missing. Keep configuration actions hidden until that read has settled.
  const configurationPending = claudeSourceChecking || (
    !credentialConfigured && nativeAvailable && (
      runtimeChecking || (selectionHydrated && credentialHarnessId !== activeHarnessId)
    )
  );
  const activeModels = useMemo(
    () =>
      (activeHarness.id === "dsh" ? dshCatalog.models : activeHarness.id === 'codex' && codexModels ? codexModels : activeHarness.models)
        .map(model => model.id)
        .filter((id): id is SupportedModel =>
          isHarnessModelId(id),
        ),
    [activeHarness, dshCatalog, codexModels],
  );

  const publishedAtRef = useRef(0);
  useEffect(
    () =>
      store.subscribe(next => {
        publishedAtRef.current = Date.now();
        setChatState(next);
      }),
    [store],
  );
  useEffect(() => {
    if (publishedAtRef.current === 0) return;
    markTiming('js.render_after_publish', Date.now() - publishedAtRef.current);
    publishedAtRef.current = 0;
  }, [chatState]);

  useEffect(() => {
    if (SessionSnapshots.isAvailable() === true) {
      setSessionSnapshotsAvailable(true);
      return undefined;
    }
    // New-architecture modules can appear after the first post-mount probe on
    // a cold device launch.  Keep bootstrap gated briefly instead of turning
    // that transient miss into a permanent blank session for this process.
    const retry = setTimeout(() => {
      setSessionSnapshotsAvailable(SessionSnapshots.isAvailable() === true);
    }, 100);
    return () => clearTimeout(retry);
  }, []);

  const invalidatePendingProjectSend = useCallback(() => {
    pendingProjectSendEpoch.current += 1;
    pendingProjectSendRef.current = null;
    pendingContextDismissAction.current = null;
    pendingProjectSendActionInFlight.current = false;
    setPendingProjectSend(null);
    setPendingProjectSendStage(null);
  }, []);

  const capturePendingProjectSend = useCallback(
    (
      conversationId: string,
      text: string,
      attachments: readonly AttachmentDescriptor[],
    ): PendingProjectSend => {
      const uiEpoch = ++pendingProjectSendEpoch.current;
      pendingContextDismissAction.current = null;
      pendingProjectSendActionInFlight.current = false;
      const attachmentCopies = Object.freeze(
        attachments.map(copyPendingAttachment),
      );
      const attachmentIds = Object.freeze(
        attachmentCopies.map(attachment => attachment.id),
      );
      const pending = Object.freeze({
        conversationId,
        uiEpoch,
        text,
        attachments: attachmentCopies,
        attachmentIds,
      });
      pendingProjectSendRef.current = pending;
      setPendingProjectSend(pending);
      setPendingProjectSendStage('recovery');
      return pending;
    },
    [],
  );

  const pendingProjectSendIsLive = useCallback(
    (pending: PendingProjectSend): boolean => {
      return (
        pendingProjectSendRef.current === pending &&
        pendingProjectSendEpoch.current === pending.uiEpoch &&
        store.getState().selectedConversationId === pending.conversationId &&
        draftRef.current === pending.text &&
        sameOrderedAttachmentIds(
          draftAttachmentsRef.current,
          pending.attachmentIds,
        )
      );
    },
    [store],
  );

  const changeDraft = useCallback(
    (value: string) => {
      invalidatePendingProjectSend();
      draftRef.current = value;
      setDraft(value);
    },
    [invalidatePendingProjectSend],
  );

  useEffect(() => {
    const operation = activeAttachmentOperation.current;
    if (
      operation !== null &&
      chatState.selectedConversationId !== operation.conversationId
    ) {
      operation.stale = true;
    }
  }, [chatState.selectedConversationId]);

  useEffect(() => {
    if (attachmentNotice === null) return;
    const timer = setTimeout(() => setAttachmentNotice(null), 2800);
    return () => clearTimeout(timer);
  }, [attachmentNotice]);

  const referencedAttachmentIds = useCallback(
    (state: ChatState): string[] =>
      Array.from(
        new Set(
          Object.values(state.conversations).flatMap(conversation =>
            conversation.messages.flatMap(message =>
              (message.attachments ?? []).map(attachment => attachment.id),
            ),
          ),
        ),
      ),
    [],
  );

  const synchronizeAttachmentStore = useCallback(
    async (state: ChatState) => {
      if (!sessionProjectionReady.current) return;
      if (!LocalAttachments.isAvailable()) return;
      const referencedIds = referencedAttachmentIds(state);
      try {
        await LocalAttachments.prune(referencedIds);
      } catch (error) {
        setRequestFailure(
          t('messages.attachment.failed', { error: errorText(error) }),
        );
      }
      const images = Array.from(
        new Map(
          Object.values(state.conversations)
            .flatMap(conversation =>
              conversation.messages.flatMap(message =>
                (message.attachments ?? []).filter(
                  attachment => attachment.kind === 'image',
                ),
              ),
            )
            .map(attachment => [attachment.id, attachment] as const),
        ).values(),
      );
      const previews = await Promise.all(
        images.map(async attachment => {
          if (attachment.thumbnail_data_url !== undefined) {
            return [attachment.id, attachment.thumbnail_data_url] as const;
          }
          try {
            const preview = await LocalAttachments.preview(attachment.id);
            return preview.thumbnail_data_url === null
              ? null
              : ([preview.id, preview.thumbnail_data_url] as const);
          } catch {
            return null;
          }
        }),
      );
      setAttachmentPreviews(
        Object.fromEntries(
          previews.filter(
            (entry): entry is readonly [string, string] => entry !== null,
          ),
        ),
      );
    },
    [referencedAttachmentIds, t],
  );

  const sessionPersistence = useMemo(
    () =>
      createSessionPersistenceCoordinator({
        loadSessionSnapshot: () => SessionSnapshots.loadSessionSnapshot(),
        casPersistSession: request =>
          SessionSnapshots.casPersistSession(request),
        querySessionCommit: request =>
          SessionSnapshots.querySessionCommit(request),
      }),
    [],
  );
  const pendingSessionWritesRef = useRef(new Map<string, PendingSessionWrite>());
  const sessionWriteTailRef = useRef(Promise.resolve());
  const drainInterruptedCleanupRef = useRef(false);

  /** Keep validated preferences current without replacing in-flight row owners. */
  const synchronizePreferencesIntoChatState = useCallback(() => {
    if (!store.setPreferences(preferencesStore.serialize())) {
      throw new Error('E_SESSION_PERSISTENCE');
    }
    // Full V9 serialization still validates the complete persisted envelope.
    return store.serialize();
  }, [preferencesStore, store]);

  const setSessionAuthority = useCallback(
    (authority: SessionAuthority | null) => {
      store.setSessionAuthority(authority);
    },
    [store],
  );

  const installSessionAuthority = useCallback(
    (snapshot: SessionSnapshotRefV1): boolean => {
      const authority: SessionAuthority = {
        generation: snapshot.generation,
        sessionSha256: snapshot.session_sha256,
      };
      setSessionAuthority(authority);
      const installed = store.getSessionAuthority();
      if (
        installed === null ||
        installed.generation !== authority.generation ||
        installed.sessionSha256 !== authority.sessionSha256
      ) {
        setSessionAuthority(null);
        return false;
      }
      return true;
    },
    [setSessionAuthority, store],
  );

  const restoreCurrentSessionAuthority = useCallback(async (): Promise<boolean> => {
    let loaded: LoadSessionSnapshotResultV1 | null;
    try {
      loaded = await sessionPersistence.loadSessionSnapshotResult();
    } catch {
      return false;
    }
    if (loaded === null || loaded.status !== 'present') return false;
    let currentDigest: string | null = null;
    try {
      currentDigest = sessionSnapshotSHA256(store.serialize());
    } catch {
      return false;
    }
    if (currentDigest !== loaded.snapshot.session_sha256) {
      const hydrated = safeHydrateChatState(loaded.session_json, {
        sessionAuthority: {
          schema_version: 1,
          generation: loaded.snapshot.generation,
          session_sha256: loaded.snapshot.session_sha256,
        },
        staleWriterLaunch: loaded.writer_launch_instance_id !==
          loaded.current_launch_instance_id,
      });
      if (!hydrated.ok) return false;
      let durableCandidate: string;
      try {
        durableCandidate = serializeChatState(hydrated.state);
      } catch {
        return false;
      }
      if (
        sessionSnapshotSHA256(durableCandidate) !==
        loaded.snapshot.session_sha256
      ) {
        return false;
      }
      store.hydrate(durableCandidate);
    }
    return installSessionAuthority(loaded.snapshot);
  }, [installSessionAuthority, sessionPersistence, store]);

  const performSessionCandidate = useCallback(
    async (
      candidateJSON: string,
      expectedAuthority?: SessionSnapshotAuthorityV1,
    ): Promise<CompletionPersistenceResult> => {
      if (
        !sessionProjectionReady.current &&
        (verifiedSessionMigration.current?.candidateJSON !== candidateJSON ||
          verifiedSessionMigration.current?.expected !== expectedAuthority)
      ) return { status: 'unknown' };
      const digestStarted = Date.now();
      const candidateDigest = sessionSnapshotSHA256(candidateJSON);
      markTiming('js.candidate_digest', Date.now() - digestStarted);
      if (candidateDigest === null) return { status: 'unknown' };
      let pending = pendingSessionWritesRef.current.get(candidateDigest);
      const hadPending = pending !== undefined;
      if (pending !== undefined && pending.candidateJSON !== candidateJSON) {
        pending = undefined;
      }
      if (pending === undefined) {
        if (
          pendingSessionWritesRef.current.size >= MAX_PENDING_SESSION_WRITES
        ) {
          return { status: 'unknown' };
        }
        let operationId: string;
        try {
          operationId = LocalRuntime.createCompletionRequestId();
        } catch {
          return { status: 'unknown' };
        }
        pending = { operationId, candidateJSON, candidateDigest };
        pendingSessionWritesRef.current.set(candidateDigest, pending);
      }

      if (hadPending && pending !== undefined) {
        const prior: SessionCommitQueryResultV1 | null =
          await sessionPersistence.queryCommit(pending.operationId);
        if (prior?.status === 'committed') {
          if (
            prior.snapshot.session_sha256 !== pending.candidateDigest ||
            !installSessionAuthority(prior.snapshot)
          ) {
            return { status: 'unknown' };
          }
          pendingSessionWritesRef.current.delete(candidateDigest);
          return { status: 'committed', snapshot: prior.snapshot };
        }
        if (prior?.status === 'conflict') {
          pendingSessionWritesRef.current.delete(candidateDigest);
          return { status: 'not_committed' };
        }
      }

      // A CAS response that cannot be correlated does not mean the write was
      // refused: the native store may already hold this exact candidate. The
      // digest covers the candidate bytes, so a durable snapshot carrying it
      // is proof that this write is durable, whichever call committed it.
      // Without this the Agent attempt is failed with E_AGENT_PERSISTENCE
      // while its own journal is already on disk, and the pending entry is
      // stranded because no later write ever asks about it again.
      const write = pending;
      const reconcileWithDurableSnapshot =
        async (): Promise<CompletionPersistenceResult> => {
          let current: SessionSnapshotAuthorityV1;
          try {
            current = await sessionPersistence.loadAuthority();
          } catch {
            return { status: 'unknown' };
          }
          if (
            current.kind !== 'present' ||
            current.snapshot.session_sha256 !== write.candidateDigest ||
            !installSessionAuthority(current.snapshot)
          ) {
            return { status: 'unknown' };
          }
          pendingSessionWritesRef.current.delete(candidateDigest);
          return { status: 'committed', snapshot: current.snapshot };
        };

      let authority: SessionSnapshotAuthorityV1;
      const loadStarted = Date.now();
      try {
        authority = await sessionPersistence.loadAuthority();
      } catch {
        // Keep the exact operation/candidate pair for a later query/retry.
        return { status: 'unknown' };
      }
      markTiming('js.load_authority', Date.now() - loadStarted);
      if (
        expectedAuthority !== undefined &&
        !sameSessionSnapshotAuthority(expectedAuthority, authority)
      ) {
        pendingSessionWritesRef.current.delete(candidateDigest);
        return { status: 'not_committed' };
      }

      const casStarted = Date.now();
      const response: SessionCASPersistResultV1 | null =
        await sessionPersistence.casPersist({
          schema_version: 1,
          operation_id: pending.operationId,
          expected: authority,
          candidate_json: pending.candidateJSON,
        });
      markTiming('js.cas_persist_await', Date.now() - casStarted);
      if (response?.status === 'committed') {
        if (
          response.snapshot.session_sha256 !== pending.candidateDigest ||
          !installSessionAuthority(response.snapshot)
        ) {
          // The native CAS may already have committed, but without a
          // correlated Store authority it is unsafe to report durability.
          return await reconcileWithDurableSnapshot();
        }
        pendingSessionWritesRef.current.delete(candidateDigest);
        return { status: 'committed', snapshot: response.snapshot };
      }
      if (
        response?.status === 'conflict' ||
        response?.status === 'not_committed'
      ) {
        pendingSessionWritesRef.current.delete(candidateDigest);
        return { status: 'not_committed' };
      }
      if (response?.status === 'session_only') {
        // session_only is deliberately not promoted to Store authority.
        return { status: 'session_only' };
      }

      // A null/unknown CAS response is indeterminate. Query the exact same
      // operation before retrying; never mint a second operation for it.
      const queried: SessionCommitQueryResultV1 | null =
        await sessionPersistence.queryCommit(pending.operationId);
      if (queried?.status === 'committed') {
        if (
          queried.snapshot.session_sha256 !== pending.candidateDigest ||
          !installSessionAuthority(queried.snapshot)
        ) {
          return await reconcileWithDurableSnapshot();
        }
        pendingSessionWritesRef.current.delete(candidateDigest);
        return { status: 'committed', snapshot: queried.snapshot };
      }
      if (queried?.status === 'conflict') {
        pendingSessionWritesRef.current.delete(candidateDigest);
        return { status: 'not_committed' };
      }
      if (queried?.status === 'not_started') {
        pendingSessionWritesRef.current.delete(candidateDigest);
        return { status: 'not_committed' };
      }
      return await reconcileWithDurableSnapshot();
    },
    [installSessionAuthority, sessionPersistence],
  );

  /** Runs one native session write behind every write already queued. */
  const enqueueSessionWrite = useCallback(<T,>(work: () => Promise<T>): Promise<T> => {
    const operation = sessionWriteTailRef.current.then(work, work);
    sessionWriteTailRef.current = operation.then(
      () => undefined,
      () => undefined,
    );
    return operation;
  }, []);

  const persistSessionCandidate = useCallback(
    (
      candidateJSON: string,
      expectedAuthority?: SessionSnapshotAuthorityV1,
    ): Promise<CompletionPersistenceResult> => {
      // Reject before enqueueing as well: a blank candidate created during a
      // failed load must not become eligible when a later retry succeeds.
      if (
        !sessionProjectionReady.current &&
        (verifiedSessionMigration.current?.candidateJSON !== candidateJSON ||
          verifiedSessionMigration.current?.expected !== expectedAuthority)
      ) return Promise.resolve({ status: 'unknown' });
      const operation = sessionWriteTailRef.current.then(
        () => performSessionCandidate(candidateJSON, expectedAuthority),
        () => performSessionCandidate(candidateJSON, expectedAuthority),
      );
      sessionWriteTailRef.current = operation.then(
        () => undefined,
        () => undefined,
      );
      return operation;
    },
    [performSessionCandidate],
  );

  /**
   * Launch-time drain of the transcript cleanup outbox.  Entries that
   * reference interrupted attempts (failed + E_ATTEMPT_INTERRUPTED, journal
   * retained as evidence) or terminal attempts whose native finalize/discard
   * never completed are closed through the dedicated native interrupt
   * operation, which discards the native authority, transcript,
   * reservations, batches, and never-dispatched ledger intents in one
   * fail-closed transaction.  The outbox entry is then acknowledged with the
   * committed session proof.  An entry native refuses (for example an
   * attempt with an unresolved operation) is skipped for this launch so it
   * cannot starve the entries behind it; it stays durable and is retried on
   * the next launch.
   */
  const drainInterruptedAgentCleanup = useCallback(async (): Promise<void> => {
    if (!sessionProjectionReady.current || !nativeAvailable || !sessionSnapshotsAvailableRef.current) return;
    if (drainInterruptedCleanupRef.current) return;
    drainInterruptedCleanupRef.current = true;
    const skipped = new Set<string>();
    try {
      for (;;) {
        const state = store.getState();
        const outbox = state.agentTranscriptCleanupOutbox ?? [];
        let progressed = false;
        for (const entry of outbox) {
          if (skipped.has(entry.cleanup_id)) continue;
          const conversation = state.conversations[entry.conversation_id];
          const attempt = conversation?.attempts.find(
            candidate => candidate.attemptId === entry.attempt_id,
          );
          if (attempt === undefined) continue;
          const interrupted =
            attempt.status === 'failed' &&
            attempt.failureCode === 'E_ATTEMPT_INTERRUPTED';
          const journalTerminal =
            attempt.agent !== undefined &&
            attempt.agent !== null &&
            (attempt.status === 'completed' ||
              attempt.status === 'cancelled' ||
              attempt.status === 'failed');
          if (!interrupted && !journalTerminal) continue;
          const authority = store.getSessionAuthority();
          if (authority === null) return;
          let operationId: string | null;
          try {
            operationId = LocalRuntime.createCompletionRequestId();
          } catch {
            return;
          }
          if (operationId === null) return;
          let discarded: InterruptAgentAttemptResultV2;
          try {
            discarded = await AgentRuntime.interruptAgentAttempt({
              schema_version: 2,
              operation_id: operationId,
              cleanup_id: entry.cleanup_id,
              task_id: entry.task_id,
              conversation_id: entry.conversation_id,
              attempt_id: entry.attempt_id,
              transcript_ref: entry.transcript_ref,
              transcript_sha256: entry.transcript_sha256,
              reason: interrupted
                ? 'failed'
                : attempt.status === 'completed'
                  ? 'completed'
                  : 'cancelled',
              expected_session_generation: authority.generation,
              expected_session_sha256: authority.sessionSha256,
            });
          } catch {
            // Native rejected this entry (or is unavailable); fail closed for
            // it and move on.  The entry and the interrupted attempt stay
            // durable, the stale attempt can never be resumed, and the next
            // launch retries the discard.
            skipped.add(entry.cleanup_id);
            continue;
          }
          if (
            discarded.status !== 'discarded' &&
            discarded.status !== 'already_missing'
          ) {
            skipped.add(entry.cleanup_id);
            continue;
          }
          const transaction =
            store.acknowledgeAgentTranscriptCleanupTransaction(
              entry.cleanup_id,
              entry,
            );
          if (transaction === null) {
            skipped.add(entry.cleanup_id);
            continue;
          }
          const candidateJSON = store.serialize();
          const durability = await persistSessionCandidate(candidateJSON, {
            schema_version: 1,
            kind: 'present',
            snapshot: {
              schema_version: 1,
              generation: authority.generation,
              session_sha256: authority.sessionSha256,
            },
          });
          if (
            durability.status !== 'committed' ||
            durability.snapshot === undefined
          ) {
            transaction.rollback();
            return;
          }
          const nativeProof: NativeAgentDiscardProofV1 = {
            ...discarded,
            task_id: entry.task_id,
            conversation_id: entry.conversation_id,
            attempt_id: entry.attempt_id,
            transcript_ref: entry.transcript_ref,
            transcript_sha256: entry.transcript_sha256,
          };
          if (!transaction.commit(durability.snapshot, nativeProof)) return;
          progressed = true;
          break;
        }
        if (!progressed) return;
      }
    } finally {
      drainInterruptedCleanupRef.current = false;
    }
  }, [nativeAvailable, persistSessionCandidate, store]);

  const persistCurrent = useCallback(
    async (): Promise<CompletionPersistenceResult> => {
      if (!nativeAvailable || !sessionSnapshotsAvailableRef.current) {
        setStorageWarning(t('home.persistenceUnavailable'));
        return { status: 'unknown' };
      }
      if (!sessionProjectionReady.current) return { status: 'unknown' };
      try {
        const serializeStarted = Date.now();
        const candidate = synchronizePreferencesIntoChatState();
        markTiming('js.serialize_candidate', Date.now() - serializeStarted);
        const persistStarted = Date.now();
        const result = await persistSessionCandidate(candidate);
        markTiming('js.persist_candidate', Date.now() - persistStarted);
        if (result.status === 'committed') {
          setStorageWarning(null);
        } else {
          setStorageWarning(
            t('home.saveFailed', { error: result.status }),
          );
        }
        return result;
      } catch (error) {
        setStorageWarning(t('home.saveFailed', { error: errorText(error) }));
        return { status: 'unknown' };
      }
    },
    [
      nativeAvailable,
      persistSessionCandidate,
      synchronizePreferencesIntoChatState,
      t,
    ],
  );

  const persist = useCallback(async (): Promise<boolean> => {
    return (await persistCurrent()).status === 'committed';
  }, [persistCurrent]);

  const persistCurrentRef = useRef(persistCurrent);
  persistCurrentRef.current = persistCurrent;

  // Forgetting and deleting workspaces: one coordinator owns the clearance,
  // the native call and the acknowledgement, and the launch-time drain of
  // requests an earlier launch left in the outbox.
  const translateRef = useRef(t);
  translateRef.current = t;
  const workspaceRemoval = useMemo(
    () =>
      new WorkspaceRemovalCoordinator({
        store,
        serialize: () => synchronizePreferencesIntoChatState(),
        enqueueSessionWrite,
        persist: async () => (await persistCurrentRef.current()).status === 'committed',
        createOperationId: () => LocalRuntime.createCompletionRequestId(),
        confirmDelete: (workspace: WorkspaceRemovalTarget) =>
          new Promise<boolean>(resolve => {
            const translate = translateRef.current;
            Alert.alert(
              translate('workspaces.deleteTitle'),
              translate('workspaces.deleteBody', { name: workspace.display_name }),
              [
                { text: translate('common.cancel'), style: 'cancel', onPress: () => resolve(false) },
                { text: translate('common.delete'), style: 'destructive', onPress: () => resolve(true) },
              ],
              { cancelable: true, onDismiss: () => resolve(false) },
            );
          }),
      }),
    [enqueueSessionWrite, store, synchronizePreferencesIntoChatState],
  );

  const removeWorkspace = useCallback(
    async (
      workspace: WorkspaceRemovalTarget,
      action: WorkspaceRemovalAction,
    ): Promise<WorkspaceRemovalOutcome> => {
      if (!nativeAvailable || !sessionSnapshotsAvailableRef.current || !sessionProjectionReady.current) {
        return { status: 'unavailable' };
      }
      const outcome = await workspaceRemoval.remove(workspace, action);
      if (outcome.status === 'forgotten' || outcome.status === 'deleted') {
        setWorkspaceDescriptors(previous =>
          Object.fromEntries(
            Object.entries(previous).filter(([id]) => id !== workspace.workspace_id),
          ),
        );
        setWorkspaceRefreshToken(token => token + 1);
      }
      return outcome;
    },
    [nativeAvailable, workspaceRemoval],
  );

  // One UI broker is shared by the durable controller and the composers.
  // The adapter below projects only safe call metadata; raw arguments and
  // workspace paths never enter React state or the approval modal.
  const agentInteractions: AgentInteractionController = useMemo(
    () => createAgentInteractionController(),
    [],
  );
  const [agentInteractionState, setAgentInteractionState] =
    useState<AgentInteractionState>(() => agentInteractions.getState());
  useEffect(
    () => agentInteractions.subscribe(setAgentInteractionState),
    [agentInteractions],
  );

  const completionController = useMemo(
    () =>
      withTaskExperience(createCompletionController({
        chat: store,
        persistCurrent: () => persistCurrentRef.current(),
        completeRoundV2: request =>
          getHarnessAdapter(request.harnessId).completeRoundV2(request),
        completeRoundV3: request =>
          getHarnessAdapter(request.harnessId).completeRoundV3(request),
        cancelRoundV2: roundId =>
          getHarnessAdapter('dsh').cancelRoundV2(roundId),
        cancelRoundV3: roundId =>
          getHarnessAdapter('dsh').cancelRoundV3(roundId),
        createRoundId: () => LocalRuntime.createCompletionRequestId(),
        createOperationId: () => LocalRuntime.createCompletionRequestId(),
        agentRuntime: AgentRuntime,
        previewSource: nativeAgentRoundPreviewSource,
        requestAgentApproval: (request: CompletionAgentApprovalRequest) => {
          const scopes = [
            ...(request.allowedDecisions.includes('allow_once')
              ? (['once'] as const)
              : []),
            ...(request.allowedDecisions.includes('allow_conversation')
              ? (['conversation'] as const)
              : []),
          ];
          if (scopes.length === 0) {
            return Promise.resolve({ status: 'denied' as const });
          }
          return agentInteractions.requestApproval({
            approvalId: request.approvalId,
            toolCallId: request.callId,
            toolName: request.name,
            argumentsJson: JSON.stringify({
              arguments_sha256: request.argumentsSha256,
            }),
            preview: request.preview,
            scopes,
            expiresAtMs: Date.now() + DEFAULT_APPROVAL_TIMEOUT_MS,
          });
        },
        requestBatchApprovals: requests =>
          agentInteractions.requestBatchApprovals(
            requests.map(request => {
              const scopes = [
                ...(request.allowedDecisions.includes('allow_once')
                  ? (['once'] as const)
                  : []),
                ...(request.allowedDecisions.includes('allow_conversation')
                  ? (['conversation'] as const)
                  : []),
              ];
              return {
                approvalId: request.approvalId,
                toolCallId: request.callId,
                toolName: request.name,
                argumentsJson: JSON.stringify({
                  arguments_sha256: request.argumentsSha256,
                }),
                preview: request.preview,
                scopes:
                  scopes.length > 0
                    ? scopes
                    : (['once'] as const),
                expiresAtMs: Date.now() + DEFAULT_APPROVAL_TIMEOUT_MS,
              };
            }),
          ),
        askAgentQuestion: (request: CompletionAgentQuestionRequest) =>
          agentInteractions.askQuestion({
            questionId: request.questionId,
            text: request.question,
            inputMode: request.inputMode,
            options: request.options,
            required: request.required,
          }),
        now: () => new Date().toISOString(),
      })),
    [agentInteractions, store],
  );
  const [completionState, setCompletionState] =
    useState<CompletionControllerState>(() =>
      completionController.getState(),
    );
  useEffect(
    () => completionController.subscribe(setCompletionState),
    [completionController],
  );
  const [roundPreviews, setRoundPreviews] = useState(() => completionController.getPreviews());
  useEffect(
    () => completionController.subscribePreviews(setRoundPreviews),
    [completionController],
  );
  const projectContextNativeAvailable = useMemo(
    () => LocalProjectContext.isAvailable(),
    [],
  );
  const projectContextController = useMemo(
    () =>
      createProjectContextController({
        chat: store,
        native: LocalProjectContext,
        persistCurrent: () => persistCurrentRef.current(),
        createPreparationId: () => LocalRuntime.createCompletionRequestId(),
        completionMutationBlocked: conversationId =>
          completionBlocksContextMutation(
            completionController.getState(),
            conversationId,
          ),
        snapshotReferences: (conversationId, snapshotId) =>
          selectProjectContextSnapshotReferences(
            store.getState(),
            conversationId,
            snapshotId,
          ),
        scheduleSearch: scheduleProjectContextSearch,
        maximumPendingPersistence: 1,
      }),
    [completionController, store],
  );
  const [projectContextControllerState, setProjectContextControllerState] =
    useState<ProjectContextControllerState>(() =>
      projectContextController.getState(),
    );
  useEffect(
    () => projectContextController.subscribe(setProjectContextControllerState),
    [projectContextController],
  );
  const projectContextLifecycleController = useMemo(
    () =>
      createProjectContextLifecycleController({
        chat: store,
        native: LocalProjectContext,
        persistCurrent: () => persistCurrentRef.current(),
        createLifecycleId: () => LocalRuntime.createCompletionRequestId(),
        completionMutationBlocked: () =>
          completionBusy(completionController.getState()),
        projectContextMutationBlocked: () =>
          projectContextOwnsMutation(projectContextController.getState()),
        snapshotReferences: (conversationId, snapshotId) =>
          selectProjectContextSnapshotReferences(
            store.getState(),
            conversationId,
            snapshotId,
          ),
        maximumPendingLifecycle: 1,
      }),
    [completionController, projectContextController, store],
  );
  const [projectContextLifecycleState, setProjectContextLifecycleState] =
    useState<ProjectContextLifecycleControllerState>(() =>
      projectContextLifecycleController.getState(),
    );
  useEffect(
    () =>
      projectContextLifecycleController.subscribe(
        setProjectContextLifecycleState,
      ),
    [projectContextLifecycleController],
  );
  const workspaceBindingController = useMemo(
    () =>
      new WorkspaceBindingController({
        chat: store,
        workspaces: LocalWorkspaces,
        projectForWorkspace: root => LocalProjects.projectForWorkspaceV2(root),
        contextGuard: async (conversationId, targetProjectId) => {
          try {
            if (
              !(await projectContextController.beforeConversationChange(
                conversationId,
              ))
            ) {
              return false;
            }
            const current = selectConversationById(
              store.getState(),
              conversationId,
            );
            const context = current?.projectContext;
            if (
              context === null ||
              context === undefined ||
              (context.snapshot === null && context.activePreparationId === null)
            ) {
              return true;
            }
            const begin =
              projectContextLifecycleController.captureDestructiveBeginToken(
                conversationId,
                targetProjectId === null ? 'unbind' : 'rebind',
                targetProjectId,
              );
            if (!begin.ok) return false;
            const outcome =
              await projectContextLifecycleController.beginDestructiveTransition(
                begin.token,
              );
            if (outcome.status !== 'completed') {
              // The transition has already begun, so the Store is latched with
              // the write unsettled. Returning bare left that invisible: this
              // is the surface every other lifecycle outcome reaches.
              if (
                outcome.status === 'blocked' ||
                outcome.status === 'cleanup_pending' ||
                outcome.status === 'persistence_pending'
              )
                setRequestFailure(outcome.code);
              return false;
            }
            return { status: 'rebound' as const };
          } catch {
            return false;
          }
        },
        completionGuard: conversationId =>
          completionController.beforeConversationChange(conversationId),
        persistCurrent: () => persistCurrentRef.current(),
        createOperationId: () => LocalRuntime.createCompletionRequestId(),
        isPickerGenerationCurrent: generation =>
          workspacePickerGenerationRef.current === generation &&
          workspaceSheetVisibleRef.current,
        isSurfaceNonceCurrent: nonce =>
          workspaceSurfaceNonceRef.current === nonce,
      }),
    [
      completionController,
      projectContextController,
      projectContextLifecycleController,
      store,
    ],
  );
  const requestState: RequestState = completionBusy(completionState)
    ? 'sending'
    : 'idle';
  const attachmentOwnershipKey = completionOwnershipKey(
    completionState,
    chatState.selectedConversationId,
    completionUiEpoch.current,
  );
  const completionAgentRetryBlocked =
    (completionState.phase === 'resume_available' ||
      completionState.phase === 'retryable') &&
    completionState.conversationId !== null &&
    completionState.attemptId !== null &&
    selectConversationById(chatState, completionState.conversationId)?.attempts.some(
      attempt =>
        attempt.attemptId === completionState.attemptId &&
        attempt.agent !== undefined &&
        attempt.agent !== null &&
        attempt.failureCode !== 'E_ATTEMPT_INTERRUPTED',
    ) === true;
  const completionRetryVisible =
    (completionState.phase === 'retryable' && !completionAgentRetryBlocked) ||
    (completionState.phase === 'resume_available' &&
      !completionAgentRetryBlocked) ||
    completionState.phase === 'persistence_pending' ||
    completionState.phase === 'commit_pending';
  const completionActionVisible =
    completionRetryVisible || completionAgentRetryBlocked;
  /**
   * A round that reached the provider and was never answered is `ambiguous`,
   * and recovery answers that with manual reconciliation every time -- for
   * good reason, since the model may already have done the work. Without a
   * second action the turn has nowhere to go, so offer the one decision only
   * a person can make: give up on this attempt and ask again.
   */
  const completionAgentUnresolved =
    completionAgentRetryBlocked &&
    completionState.conversationId !== null &&
    completionState.attemptId !== null &&
    selectConversationById(chatState, completionState.conversationId)?.attempts.some(
      attempt =>
        attempt.attemptId === completionState.attemptId &&
        (attempt.agent?.phase === 'ambiguous' ||
          attempt.agent?.phase === 'unknown'),
    ) === true;
  const completionNoticeVisible = completionActionVisible;
  const durabilityFailure =
    completionState.phase === 'persistence_pending' ||
    completionState.phase === 'commit_pending'
      ? completionState.failureCode ?? 'E_ATTEMPT_PERSISTENCE'
      : null;
  const visibleRequestFailure =
    durabilityFailure ??
    requestFailure ??
    (completionNoticeVisible
      ? completionState.failureCode ??
        (completionState.phase === 'resume_available'
          ? 'E_ATTEMPT_INTERRUPTED'
          : t('home.responseStopped'))
      : null);

  const applyCompletionOutcome = useCallback(
    (result: CompletionControllerOutcome, expectedEpoch: number) => {
      if (expectedEpoch !== completionUiEpoch.current) return;
      if (
        result.conversationId !== null &&
        store.getState().selectedConversationId !== result.conversationId
      ) {
        return;
      }
      if (result.status === 'completed') {
        setRequestFailure(null);
      } else if (result.status === 'cancelled') {
        setRequestFailure(t('home.responseStopped'));
      } else {
        setRequestFailure(result.code ?? 'E_COMPLETION_NATIVE');
      }
    },
    [store, t],
  );

  // The persisted active conversation owns the last choice, even when it is
  // blank. Settings defaults remain the fallback for an empty session. Copy
  // only model/effort so a new chat never inherits project or workspace state.
  const newConversationOptions = useCallback(() => {
    const selected = selectActiveConversation(store.getState());
    const defaults = preferencesStore.getState();
    return {
      modelId: defaultModelForHarness(
        selected === null ? defaults.selectedHarnessId : harnessForModel(selected.modelId),
        selected?.modelId ?? defaults.defaultModel,
      ),
      thinkingMode: selected?.thinkingMode ?? defaults.thinkingMode,
    };
  }, [preferencesStore, store]);

  const ensureConversation = useCallback((): string => {
    const selected = store.getState().selectedConversationId;
    if (selected !== null) return selected;
    return store.createConversation(newConversationOptions());
  }, [newConversationOptions, store]);

  const reconcileSelectedConversation = useCallback(
    (conversationId: string) => {
      if (!sessionProjectionReady.current) return;
      if (
        directProjectMutationOutboxRef.current !== null ||
        store.getState().projectContextDestructiveTransition !== null
      ) {
        return;
      }
      completionController.reconcileHydrated(conversationId);
      if (!projectContextNativeAvailable) return;
      if (
        completionBusy(completionController.getState()) ||
        selectProjectContextSnapshotReferences(
          store.getState(),
          conversationId,
        ).length > 0
      ) {
        return;
      }
      projectContextController
        .reconcileHydrated(conversationId)
        .catch(() => undefined);
    },
    [
      completionController,
      projectContextController,
      projectContextNativeAvailable,
      store,
    ],
  );

  const hydrateStoredState = useCallback(
    async (loaded: LoadSessionSnapshotResultV1 | null, failureCode = 'E_SESSION_PERSISTENCE'): Promise<boolean> => {
      sessionProjectionReady.current = false;
      if (loaded === null) {
        setSessionLoadFailure(failureCode);
        // A malformed, unavailable, or boolean native result is not a
        // missing session. Do not hydrate or overwrite the live projection;
        // the blank shell remains usable while storage fails closed.
        setSessionAuthority(null);
        ensureConversation();
        setStorageWarning(
          t('home.storedChatsRejected', { error: failureCode }),
        );
        return false;
      }
      if (loaded.status === 'missing') {
        setSessionLoadFailure(null);
        setStorageWarning(null);
        setSessionAuthority(null);
        ensureConversation();
        sessionProjectionReady.current = true;
        return true;
      }

      const hydrated = safeHydrateChatState(
        loaded.session_json,
        loaded.status === 'present' || loaded.status === 'legacy_present'
          ? {
              sessionAuthority:
                loaded.status === 'present'
                  ? {
                      schema_version: 1,
                      generation: loaded.snapshot.generation,
                      session_sha256: loaded.snapshot.session_sha256,
                    }
                  : undefined,
              staleWriterLaunch: loaded.writer_launch_instance_id !==
                loaded.current_launch_instance_id,
            }
          : {},
      );
      if (!hydrated.ok) {
        setSessionLoadFailure('E_SESSION_CORRUPT');
        setSessionAuthority(null);
        ensureConversation();
        setStorageWarning(
          t('home.storedChatsRejected', { error: hydrated.error.message }),
        );
        return false;
      }

      let candidate: string;
      try {
        candidate = serializeChatState(hydrated.state);
      } catch (error) {
        setSessionAuthority(null);
        ensureConversation();
        setStorageWarning(t('home.saveFailed', { error: errorText(error) }));
        return false;
      }
      const candidateDigest = sessionSnapshotSHA256(candidate);
      if (candidateDigest === null) {
        setSessionAuthority(null);
        ensureConversation();
        setStorageWarning(
          t('home.saveFailed', { error: 'E_SESSION_PERSISTENCE' }),
        );
        return false;
      }

      let migratedFromLegacy = false;
      const persistMigration = async (expected: SessionSnapshotAuthorityV1) => {
        const migration = { candidateJSON: candidate, expected };
        verifiedSessionMigration.current = migration;
        try {
          return await persistSessionCandidate(candidate, expected);
        } finally {
          if (verifiedSessionMigration.current === migration) {
            verifiedSessionMigration.current = null;
          }
        }
      };
      if (loaded.status === 'legacy_present') {
        const expected: SessionSnapshotAuthorityV1 = {
          schema_version: 1,
          kind: 'legacy_present',
          legacy: loaded.legacy,
        };
        const migrated = await persistMigration(expected);
        if (migrated.status !== 'committed') {
          // Do not expose or mutate the legacy projection unless the exact
          // V2 byte-token CAS promoted it to schema-9.
          setSessionAuthority(null);
          ensureConversation();
          setStorageWarning(t('home.saveFailed', { error: migrated.status }));
          return false;
        }
        migratedFromLegacy = true;
      } else if (candidateDigest !== loaded.snapshot.session_sha256) {
        const expected: SessionSnapshotAuthorityV1 = {
          schema_version: 1,
          kind: 'present',
          snapshot: loaded.snapshot,
        };
        const migrated = await persistMigration(expected);
        const installed = store.getSessionAuthority();
        if (
          migrated.status !== 'committed' ||
          installed === null ||
          installed.sessionSha256 !== candidateDigest
        ) {
          // A decoded migration candidate is not live authority.  It becomes
          // visible only after the exact present snapshot CAS commits and the
          // returned reference is correlated to these candidate bytes.
          setSessionAuthority(null);
          ensureConversation();
          setStorageWarning(t('home.saveFailed', { error: migrated.status }));
          return false;
        }
      } else {
        // The native facade has already verified the V9 digest and requires
        // generations to start at one; retain that authority for CAS-bound
        // in-memory mutations before touching the live store.
        if (!installSessionAuthority(loaded.snapshot)) {
          setStorageWarning(
            t('home.saveFailed', { error: 'E_SESSION_PERSISTENCE' }),
          );
          ensureConversation();
          return false;
        }
      }

      store.hydrate(candidate);
      setSessionLoadFailure(null);
      setStorageWarning(null);
      const persistedPreferences = store.getState().preferences;
      if (persistedPreferences !== undefined) {
        preferencesStore.hydrate(persistedPreferences);
      }
      sessionProjectionReady.current = true;
      if (store.getState().selectedConversationId === null) {
        ensureConversation();
      }
      if (migratedFromLegacy) {
        setStorageWarning(t('home.legacySessionUpgraded'));
      }
      if (store.getSessionAuthority() !== null) {
        drainInterruptedAgentCleanup().catch(() => undefined);
        workspaceRemoval.drain().catch(() => undefined);
      }
      return true;
    },
    [
      drainInterruptedAgentCleanup,
      workspaceRemoval,
      ensureConversation,
      installSessionAuthority,
      preferencesStore,
      persistSessionCandidate,
      setSessionAuthority,
      store,
      t,
    ],
  );

  const bootstrap = useCallback(async (sessionAvailable = sessionSnapshotsAvailable === true) => {
    sessionProjectionReady.current = false;
    setSelectionHydrated(false);
    setRuntimeChecking(true);
    setRuntimeFailure(null);
    if (!nativeAvailable) {
      ensureConversation();
      setChatState(store.getState());
      lifecycleBootstrapReadyRef.current = true;
      setLifecycleBootstrapReady(true);
      setRuntimeFailure(t('home.localAdapterUnavailable'));
      setRuntimeChecking(false);
      return;
    }
    let restoredSelection = false;
    // Set only once the probe effect below has been handed the job of
    // clearing runtimeChecking. A throw before that point must not leave
    // the flag set: Retry load is disabled by it, and retrySessionLoad
    // refuses on it too, so the only offered way out would be gone.
    let probeOwnsRuntimeChecking = false;
    try {
      const load = sessionAvailable
        ? await sessionPersistence.loadSessionSnapshotOutcome()
        : { status: 'failed' as const, code: 'E_SESSION_NATIVE' };
      restoredSelection = await hydrateStoredState(
        load.status === 'loaded' ? load.value : null,
        load.status === 'failed' ? load.code : undefined,
      );
      setChatState(store.getState());
      const restoredTransition =
        store.getState().projectContextDestructiveTransition;
      if (restoredSelection && restoredTransition !== null) {
        const outcome =
          await projectContextLifecycleController.reconcileDestructiveTransition();
        if (outcome.status !== 'completed') {
          drawerSurfaceEpoch.current += 1;
          drawerVisibleRef.current = false;
          setDrawerVisible(false);
          conversationActionEpoch.current += 1;
          setActionConversationId(null);
          settingsSurfaceEpoch.current += 1;
          settingsVisibleRef.current = false;
          setSettingsVisible(false);
          setAccountVisible(false);
          setMirrorsVisible(false);
          setEnvironmentsVisible(false);
          setProgramVisible(false);
          setProgramContext(null);
          pendingProgramOpenRef.current = null;
          setModelVisible(false);
          setComposerOptionsVisible(false);
          workspacePickerGenerationRef.current += 1;
          setWorkspacePickerGeneration(workspacePickerGenerationRef.current);
          workspaceSurfaceNonceRef.current += 1;
          workspaceBindingController.invalidate();
          workspaceSheetVisibleRef.current = false;
          setWorkspaceSheetVisible(false);
          setHarnessesVisible(false);
          setEvidenceVisible(false);
          projectsSurfaceEpoch.current += 1;
          projectsVisibleRef.current = false;
          setProjectsVisible(false);
          workspaceVisibleRef.current = false;
          setWorkspaceVisible(false);
          setWorkspaceRoute(null);
          afterDrawerDismiss.current = null;
          afterActionDismiss.current = null;
          lifecycleIntentRef.current = null;
          setLifecycleIntent(null);
          setLifecycleSheetTargetId(restoredTransition.conversationId);
          projectContextUiEpoch.current += 1;
          contextSheetVisibleRef.current = true;
          setContextSheetVisible(true);
        }
      }
      // Restore history and reconcile destructive recovery first. Only the cold
      // bootstrap changes the default selection; resume and queued task links
      // retain their existing navigation flow after this gate opens.
      if (restoredSelection && selectColdStartConversation(store, newConversationOptions())) {
        await persist();
        setChatState(store.getState());
      }
      setSelectionHydrated(restoredSelection);
      lifecycleBootstrapReadyRef.current = restoredSelection;
      setLifecycleBootstrapReady(restoredSelection);
      probeOwnsRuntimeChecking = restoredSelection;
      if (
        restoredSelection &&
        store.getState().projectContextDestructiveTransition === null &&
        store.getState().selectedConversationId === null
      ) {
        ensureConversation();
      }
      const selectedAfterLifecycle = store.getState().selectedConversationId;
      if (
        restoredSelection &&
        store.getState().projectContextDestructiveTransition === null &&
        selectedAfterLifecycle !== null
      ) {
        reconcileSelectedConversation(selectedAfterLifecycle);
      }
      if (restoredSelection) await synchronizeAttachmentStore(store.getState());
    } catch (error) {
      setRuntimeFailure(errorText(error));
      if (store.getState().selectedConversationId === null)
        ensureConversation();
      setChatState(store.getState());
    } finally {
      if (!probeOwnsRuntimeChecking) setRuntimeChecking(false);
      if (!restoredSelection) {
        lifecycleBootstrapReadyRef.current = false;
        setLifecycleBootstrapReady(false);
      }
    }
  }, [
    ensureConversation,
    selectColdStartConversation,
    newConversationOptions,
    persist,
    hydrateStoredState,
    nativeAvailable,
    sessionSnapshotsAvailable,
    sessionPersistence,
    projectContextLifecycleController,
    reconcileSelectedConversation,
    store,
    synchronizeAttachmentStore,
    t,
    workspaceBindingController,
  ]);

  const retrySessionLoad = useCallback(async () => {
    if (sessionReloadBusy.current || runtimeChecking || sessionLoadFailure === null) return;
    sessionReloadBusy.current = true;
    try {
      // Catalog-dependent validation must see the latest on-device catalog.
      try {
        await DshModelCatalog.refresh();
      } catch {
        setStorageWarning(t('home.storedChatsRejected', { error: 'E_MODEL_CATALOG' }));
        return;
      }
      const available = SessionSnapshots.isAvailable() === true;
      sessionSnapshotsAvailableRef.current = available;
      setSessionSnapshotsAvailable(available);
      await bootstrap(available);
    } finally {
      sessionReloadBusy.current = false;
    }
  }, [bootstrap, runtimeChecking, sessionLoadFailure, t]);

  useEffect(() => {
    if (sessionSnapshotsAvailable === null) return;
    if (started.current) return;
    started.current = true;
    bootstrap().catch(() => undefined);
  }, [bootstrap, sessionSnapshotsAvailable]);

  // Probe only the final hydrated selection. The launch callback must not
  // retain the adapter from its pre-hydration render, and stale results must
  // not start another provider after the user has switched conversations.
  useEffect(() => {
    if (!selectionHydrated || !lifecycleBootstrapReady || !nativeAvailable) return;
    let cancelled = false;
    setRuntimeChecking(true);
    setRuntimeFailure(null);
    setProof(null);
    const probe = async () => {
      let credentialReadSucceeded = false;
      try {
        const credential = await activeAdapter.credentialStatus();
        if (cancelled) return;
        credentialReadSucceeded = true;
        const configured = credential.status === 'configured';
        setCredentialHarnessId(activeHarnessId);
        setCredentialConfigured(configured);
        if (configured) {
          const initialProof = (await bootstrapForHarness(activeHarnessId)).proof;
          if (!cancelled) setProof(initialProof);
        }
      } catch (error) {
        if (cancelled) return;
        // A failed key/source read invalidates the earlier configured value;
        // an observational runtime-proof failure does not erase a known key.
        if (!credentialReadSucceeded) {
          setCredentialHarnessId(activeHarnessId);
          setCredentialConfigured(false);
        }
        setRuntimeFailure(errorText(error));
      } finally {
        if (!cancelled) setRuntimeChecking(false);
      }
    };
    probe().catch(() => undefined);
    return () => { cancelled = true; };
  }, [activeAdapter, activeHarnessId, selectionHydrated, lifecycleBootstrapReady, nativeAvailable, providerConfigurationRevision]);

  // QA fixture: with -DSHSeedMarkdownDemo the Simulator seeds one
  // markdown-demo conversation after bootstrap, unless a session restored.
  const markdownSeedAppliedRef = useRef(false);
  useEffect(() => {
    if (!seedMarkdownDemo || !lifecycleBootstrapReady) return;
    if (markdownSeedAppliedRef.current) return;
    markdownSeedAppliedRef.current = true;
    seedMarkdownDemoConversation(store);
    setChatState(store.getState());
  }, [lifecycleBootstrapReady, seedMarkdownDemo, store]);

  const activeProjectId = activeConversation?.projectId ?? null;
  useEffect(() => {
    if (pendingProgramOpenRef.current !== null &&
        pendingProgramOpenRef.current.selectedConversationId !== (activeConversation?.id ?? null)) {
      pendingProgramOpenRef.current = null;
    }
    if (programContext?.conversationId != null &&
        programContext.conversationId !== activeConversation?.id) {
      setProgramVisible(false);
      setProgramContext(null);
    }
  }, [activeConversation?.id, programContext]);
  const workspaceOwnerConversationRef = useRef<string | null>(null);
  useEffect(() => {
    const previous = workspaceOwnerConversationRef.current;
    const current = activeConversation?.id ?? null;
    if (
      previous !== null && previous !== current &&
      (current === null || workspaceBindingController.getState().conversationId !== current)
    ) {
      workspaceBindingController.invalidate();
    }
    workspaceOwnerConversationRef.current = current;
  }, [activeConversation?.id, workspaceBindingController]);
  useEffect(() => {
    const routeConversationId = workspaceRoute?.conversationId;
    if (
      !workspaceVisibleRef.current ||
      routeConversationId === null ||
      routeConversationId === undefined ||
      routeConversationId === activeConversation?.id
    ) {
      return;
    }
    workspaceSurfaceNonceRef.current += 1;
    if (
      activeConversation?.id == null ||
      workspaceBindingController.getState().conversationId !== activeConversation.id
    ) {
      workspaceBindingController.invalidate();
    }
    workspaceVisibleRef.current = false;
    setWorkspaceVisible(false);
    setWorkspaceRoute(null);
  }, [activeConversation?.id, workspaceBindingController, workspaceRoute]);
  useEffect(() => {
    let cancelled = false;
    if (activeProjectId === null || !LocalProjects.isAvailable()) {
      setActiveProjectName(null);
      return () => {
        cancelled = true;
      };
    }
    // The legacy listing knows legacy projects; a project attached to a
    // workspace is named by the workspace. On Android only the second exists.
    LocalProjects.list()
      .then(listing => listing.projects.find(project => project.id === activeProjectId)?.name ?? null)
      .catch(() => null)
      .then(name => name ?? workspaceProjectName(activeProjectId))
      .then(name => {
        if (!cancelled) setActiveProjectName(name);
      })
      .catch(() => {
        if (!cancelled) setActiveProjectName(null);
      });
    return () => {
      cancelled = true;
    };
  }, [activeProjectId]);
  const [roundPresentations, setRoundPresentations] = useState<Readonly<Record<string, AgentAttemptPresentation>>>({});
  // Read native completed projections on hydration and each durable round transition.
  // This display cache never changes model history or execution checkpoints.
  const presentationOwner = activeConversation?.id ?? null;
  // Native presentations change only when a round lands or the attempt
  // settles; keying on the journal revision re-read every attempt on every
  // persisted checkpoint (about a second of native time each).
  const presentationRevision = JSON.stringify(activeConversation?.attempts.filter(attempt => attempt.agent != null).map(attempt => [
    attempt.attemptId, attempt.rounds.length, attempt.status, attempt.assistantMessageId,
  ]) ?? []);
  useEffect(() => {
    let cancelled = false;
    if (presentationOwner === null) { setRoundPresentations({}); return; }
    const attempts = JSON.parse(presentationRevision) as [string, number, string | null][];
    Promise.all(attempts.map(async ([attemptId]) => {
      const result = await readAgentAttemptPresentation(presentationOwner, attemptId);
      return [attemptId, result] as const;
    })).then(results => {
      if (!cancelled) setRoundPresentations(Object.fromEntries(results.filter((entry): entry is readonly [string, AgentAttemptPresentation] => entry[1] !== null)));
    });
    return () => { cancelled = true; };
  }, [presentationOwner, presentationRevision]);
  const pendingAttemptId =
    completionState.conversationId === activeConversation?.id &&
    (completionState.phase === 'preparing' ||
      completionState.phase === 'starting' ||
      completionState.phase === 'sending')
      ? completionState.attemptId
      : null;
  const previewLabels = useMemo(() => ({ thinking: t('messages.thinking') }), [t]);
  const activeMessages = useMemo(
    () => {
      const started = Date.now();
      const rows = displayMessages(activeConversation, attachmentPreviews, chatState.sessionEvents ?? [], roundPresentations, roundPreviews, pendingAttemptId, previewLabels);
      markTiming('js.display_messages', Date.now() - started);
      return rows;
    },
    [activeConversation, attachmentPreviews, chatState.sessionEvents, roundPresentations, roundPreviews, pendingAttemptId, previewLabels],
  );
  const conversationSummaries = useMemo(
    () => {
      const started = Date.now();
      const summaries = selectOrderedConversations(chatState).map(summaryFor);
      markTiming('js.conversation_summaries', Date.now() - started);
      return summaries;
    },
    [chatState],
  );
  const activeModel = activeConversation?.modelId ??
    defaultModelForHarness(preferences.selectedHarnessId, preferences.defaultModel);
  const activeThinkingMode =
    activeConversation?.thinkingMode ?? preferences.thinkingMode;
  const activeWorkspaceId = activeConversation?.workspaceId ?? null;
  const projectContextOwnerAligned = sameProjectContextOwner(
    projectContextControllerState.owner,
    activeConversation,
  );
  const lifecycleToken = projectContextLifecycleState.token;
  const projectContextVerificationStatus: ProjectContextVerificationStatus =
    (directProjectMutationView?.conversationId ??
      lifecycleIntent?.conversationId ??
      lifecycleToken?.conversationId) ===
      activeConversation?.id
      ? 'recovery'
      : !projectContextNativeAvailable ||
    activeConversation?.projectContext?.status === 'unavailable'
      ? 'unavailable'
      : !projectContextOwnerAligned
        ? 'checking'
        : projectContextControllerState.phase === 'persistence_pending' ||
          projectContextControllerState.phase === 'cleanup_pending'
        ? 'recovery'
        // A blocked phase with no failure is a stale, errored or
        // unavailable *context*, which the strip already reads from the
        // context state itself; only a controller failure is an error here.
        // Mapping every blocked phase to error showed "Error" for a context
        // the agent had merely made stale by committing.
        : projectContextControllerState.failureCode !== null
          ? 'error'
          : projectContextControllerState.phase === 'inspecting' ||
              projectContextControllerState.phase === 'preparing' ||
              projectContextControllerState.phase === 'confirming' ||
              projectContextControllerState.phase === 'disabling'
            ? 'checking'
            : 'verified';
  const projectContextCandidateManifest =
    projectContextOwnerAligned
      ? projectContextControllerState.candidateManifest
      : null;
  const projectContextManifest =
    projectContextCandidateManifest ??
    activeConversation?.projectContext?.snapshot ??
    null;
  const lifecycleTargetId =
    directProjectMutationView?.conversationId ??
    lifecycleIntent?.conversationId ??
    lifecycleToken?.conversationId ??
    lifecycleSheetTargetId;
  const lifecycleTargetConversation =
    lifecycleTargetId === null
      ? null
      : selectConversationById(chatState, lifecycleTargetId);
  const lifecycleSheetActive =
    lifecycleTargetId !== null &&
    (directProjectMutationView !== null ||
      lifecycleIntent !== null ||
      lifecycleToken !== null);
  const lifecycleAction =
    directProjectMutationView?.action ??
    lifecycleIntent?.action ??
    lifecycleToken?.action ??
    null;
  const lifecyclePresentation =
    lifecycleSheetActive && lifecycleAction !== null
      ? directProjectMutationView !== null
        ? {
            kind: 'direct_persistence' as const,
            action: directProjectMutationView.action,
            targetProjectLabel:
              directProjectMutationView.action === 'rebind'
                ? directProjectMutationView.targetProjectName ??
                  t('context.sheet.lifecycle.localProject')
                : null,
          }
        : {
          kind: lifecycleIntent !== null ? ('confirmation' as const) : ('transition' as const),
          action: lifecycleAction,
          controllerState: projectContextLifecycleState,
          targetProjectLabel:
            lifecycleAction === 'rebind'
              ? t('context.sheet.lifecycle.localProject')
              : null,
          }
      : null;
  const projectContextConfirmationRequired =
    projectContextControllerState.phase === 'review' &&
    projectContextCandidateManifest !== null;
  const projectContextSheetMode: ProjectContextSheetMode =
    lifecycleSheetActive
      ? 'lifecycle'
      : pendingProjectSend !== null && pendingProjectSendStage === 'recovery'
      ? 'recovery'
      : pendingProjectSend !== null &&
          pendingProjectSendStage === 'context_flow' &&
          projectContextCandidateManifest === null
        ? 'candidates'
      : projectContextManifest === null
        ? 'candidates'
        : 'disclosure';
  const projectContextBusyAction: ProjectContextSheetBusyAction =
    !projectContextOwnerAligned
      ? null
      : projectContextControllerState.phase === 'preparing'
      ? 'prepare'
      : projectContextControllerState.phase === 'confirming'
        ? 'confirm'
        : projectContextControllerState.phase === 'inspecting'
          ? 'refresh'
          : projectContextControllerState.phase === 'disabling'
            ? 'disable'
            : null;
  const projectContextRecoveryAction: ProjectContextSheetRecoveryAction =
    !projectContextOwnerAligned
      ? null
      : projectContextControllerState.phase === 'persistence_pending'
      ? 'persistence'
      : projectContextControllerState.phase === 'cleanup_pending'
        ? 'cleanup'
        : null;
  const projectContextActionToken = projectContextOwnerAligned
    ? projectContextController.getActionToken()
    : null;
  const completionBlocksActiveProjectMutation =
    activeConversation !== null &&
    completionBlocksContextMutation(completionState, activeConversation.id);
  const projectContextHasSnapshotReferences =
    activeConversation !== null &&
    selectProjectContextSnapshotReferences(
      chatState,
      activeConversation.id,
    ).length > 0;
  const projectContextActionsDisabled =
    projectContextActionToken === null ||
    completionBlocksActiveProjectMutation ||
    projectContextHasSnapshotReferences;
  const projectContextLocksComposer =
    directProjectMutationView !== null ||
    projectContextLifecycleState.token !== null ||
    lifecycleIntent !== null ||
    (activeConversation?.projectId !== null &&
      activeConversation?.projectId !== undefined &&
      projectContextOwnerAligned &&
      projectContextOwnsMutation(projectContextControllerState));
  const projectContextRecoveryGloballyDisabled =
    (activeConversation !== null &&
      completionOwnsPresentation(completionState, activeConversation.id)) ||
    (projectContextOwnerAligned &&
      projectContextOwnsMutation(projectContextControllerState));
  const projectContextRecoveryRefreshDisabled =
    projectContextRecoveryGloballyDisabled ||
    !projectContextNativeAvailable ||
    projectContextActionToken === null ||
    projectContextHasSnapshotReferences;
  const projectContextRenderEpoch = projectContextUiEpoch.current;
  const projectsRenderEpoch = projectsSurfaceEpoch.current;
  const drawerRenderEpoch = drawerSurfaceEpoch.current;
  const settingsRenderEpoch = settingsSurfaceEpoch.current;
  const projectContextActionKey = JSON.stringify([
    projectContextRenderEpoch,
    contextSheetVisible,
    activeConversation?.id ?? null,
    projectContextActionToken?.generation ?? null,
    projectContextActionToken?.listGeneration ?? null,
    projectContextActionToken?.preparationId ?? null,
    projectContextActionToken?.projectId ?? null,
    projectContextActionToken?.runtimeContextId ?? null,
    projectContextActionToken?.modelId ?? null,
    pendingProjectSend?.uiEpoch ?? null,
    pendingProjectSendStage,
    lifecycleIntent?.nonce ?? null,
    projectContextLifecycleState.generation,
    lifecycleToken?.lifecycleId ?? null,
    lifecycleToken?.epoch ?? null,
    lifecycleToken?.phase ?? null,
    directProjectMutationView?.action ?? null,
    directProjectMutationView?.conversationId ?? null,
  ]);
  useEffect(() => {
    if (
      !lifecycleBootstrapReady ||
      directProjectMutationView !== null ||
      lifecycleIntent !== null ||
      store.getState().projectContextDestructiveTransition !== null ||
      directProjectMutationOutboxRef.current !== null ||
      !projectContextNativeAvailable ||
      activeConversation === null
    )
      return;
    if (
      activeConversation.projectId === null ||
      activeConversation.projectContext === null ||
      completionBusy(completionState) ||
      selectProjectContextSnapshotReferences(
        store.getState(),
        activeConversation.id,
      ).length > 0
    ) {
      return;
    }
    const controllerState = projectContextController.getState();
    if (sameProjectContextOwner(controllerState.owner, activeConversation)) {
      return;
    }
    if (projectContextOwnsMutation(controllerState)) {
      return;
    }
    projectContextController
      .reconcileHydrated(activeConversation.id)
      .catch(() => undefined);
  }, [
    activeConversation,
    completionState,
    directProjectMutationView,
    lifecycleIntent,
    lifecycleBootstrapReady,
    projectContextController,
    projectContextControllerState,
    projectContextNativeAvailable,
    store,
  ]);
  const runtimeLocal =
    proof !== null &&
    (proof.checks.credential_in_keychain || proof.checks.credential_in_secure_store === true) &&
    proof.checks.rish_applet_executed &&
    !proof.mac_dsh_port_3180_reachable;
  const runtimeLabel = sessionLoadFailure !== null ? t('recovery.loadBlocked') : codexModelsLoading ? t('messages.loadingSubscriptionModels') : runtimeChecking
    ? t('runtime.status.verifying')
    : !nativeAvailable
    ? t('home.localAdapterUnavailable')
    : !credentialConfigured
    ? subscriptionNeedsAttention
      ? t(glmSubscriptionState === 'signed_in' ? 'messages.subscriptionUnverified' : 'messages.subscriptionLoginRequired')
      : t('settings.credential.notConfigured')
    : runtimeFailure !== null
    ? t('runtime.status.failed')
    : proof?.mac_dsh_port_3180_reachable
    ? t('runtime.status.proxyDetected')
    : runtimeLocal
    ? t('runtime.status.verified')
    : proof?.platform?.startsWith('android')
    // The guest applet and the workspace tools are separate things. Saying
    // "local tools unavailable" while list_dir and write_file were running
    // was one sentence covering both, and it was wrong about one of them.
    ? t(proof.checks.workspace_tools_available === true
        ? (proof.checks.model_response_received ? 'runtime.status.chatReadyToolsLocal' : 'runtime.status.chatConfiguredToolsLocal')
        : (proof.checks.model_response_received ? 'runtime.status.chatReadyToolsPending' : 'runtime.status.chatConfiguredToolsPending'))
    : t('runtime.status.incomplete');
  const runtimeStatus: RuntimeVerificationStatus = runtimeChecking
    ? 'checking'
    : sessionLoadFailure !== null || runtimeFailure !== null ||
      !nativeAvailable ||
      proof?.mac_dsh_port_3180_reachable
    ? 'failed'
    : runtimeLocal
    ? 'verified'
    : 'incomplete';

  const refreshProof = useCallback(async () => {
    if (!nativeAvailable) return;
    try {
      const credential = await activeAdapter.credentialStatus();
      if (activeHarnessIdRef.current !== activeHarnessId) return;
      const configured = credential.status === 'configured';
      setCredentialHarnessId(activeHarnessId);
      setCredentialConfigured(configured);
      if (!configured) {
        setProof(null);
        setRuntimeFailure(null);
        return;
      }
      const refreshedProof = (await bootstrapForHarness(activeHarnessId)).proof;
      if (activeHarnessIdRef.current !== activeHarnessId) return;
      setProof(refreshedProof);
      setRuntimeFailure(null);
    } catch (error) {
      if (activeHarnessIdRef.current !== activeHarnessId) return;
      setRuntimeFailure(errorText(error));
    }
  }, [activeAdapter, activeHarnessId, nativeAvailable]);

  const changeConversationModel = useCallback(
    (
      conversationId: string,
      model: SupportedModel,
      source: ModelTransitionSource,
    ): boolean => {
      const controllerState = completionController.getState();
      if (
        completionBusy(controllerState) ||
        activeAttachmentOperation.current !== null
      ) {
        return false;
      }
      const conversation = selectConversationById(
        store.getState(),
        conversationId,
      );
      if (conversation === null || conversation.modelId === model) return false;
      const historyImageCount = conversation.messages.reduce(
        (count, message) =>
          count +
          (message.attachments?.filter(
            attachment => attachment.kind === 'image',
          ).length ?? 0),
        0,
      );
      const draftImageCount = draftAttachments.filter(
        attachment => attachment.kind === 'image',
      ).length;
      const fromModel = conversation.modelId;
      store.setModel(conversationId, model);
      LocalRuntime.recordModelTransition({
          conversation_id: conversationId,
          from_model: fromModel,
          to_model: model,
          source,
          request_epoch: controllerState.epoch,
          request_state: completionBusy(controllerState)
            ? 'sending'
            : 'idle',
          attachment_busy: activeAttachmentOperation.current !== null,
          draft_image_count: draftImageCount,
          history_image_count: historyImageCount,
        }).catch(() => undefined);
      return true;
    },
    [completionController, draftAttachments, store],
  );

  const discardDraftAttachments = useCallback(() => {
    invalidatePendingProjectSend();
    const referencedIds = new Set(referencedAttachmentIds(store.getState()));
    const ids = draftAttachments
      .map(attachment => attachment.id)
      .filter(id => !referencedIds.has(id));
    draftAttachmentsRef.current = [];
    setDraftAttachments([]);
    if (ids.length > 0 && LocalAttachments.isAvailable()) {
      LocalAttachments.discard(ids).catch(error =>
        setRequestFailure(
          t('messages.attachment.failed', { error: errorText(error) }),
        ),
      );
    }
  }, [
    draftAttachments,
    invalidatePendingProjectSend,
    referencedAttachmentIds,
    store,
    t,
  ]);

  const markAttachmentOperationStale = useCallback(() => {
    if (activeAttachmentOperation.current !== null) {
      activeAttachmentOperation.current.stale = true;
    }
  }, []);

  const addAttachment = useCallback(
    async (source: AttachmentSource, expectedOwnershipKey: string) => {
      if (!sessionProjectionReady.current) return;
      const liveOwnershipKey = completionOwnershipKey(
        completionController.getState(),
        store.getState().selectedConversationId,
        completionUiEpoch.current,
      );
      if (
        expectedOwnershipKey !== liveOwnershipKey ||
        completionBusy(completionController.getState())
      ) {
        return;
      }
      if (
        !LocalAttachments.isAvailable() ||
        activeAttachmentOperation.current !== null
      ) {
        setRequestFailure(t('messages.attachment.unsupported'));
        return;
      }
      const conversationId = ensureConversation();
      const generation = ++attachmentOperationGeneration.current;
      activeAttachmentOperation.current = {
        generation,
        conversationId,
        stale: false,
      };
      const discardUnreferenced = (attachments: readonly AttachmentDescriptor[]) => {
        const liveDraftAttachments = draftAttachmentsRef.current;
        const protectedIds = new Set([
          ...referencedAttachmentIds(store.getState()),
          ...liveDraftAttachments.map(attachment => attachment.id),
        ]);
        const ids = attachments
          .map(attachment => attachment.id)
          .filter(id => !protectedIds.has(id));
        return ids.length === 0
          ? Promise.resolve()
          : LocalAttachments.discard(ids).then(() => undefined);
      };
      setAttachmentBusy(true);
      setRequestFailure(null);
      try {
        const nativeOperation = LocalAttachments.present(source);
        // A native picker may finish after our timeout. If this operation is
        // no longer current, reclaim every returned opaque attachment instead
        // of leaking it into native storage.
        nativeOperation
          .then(result => {
            if (
              activeAttachmentOperation.current?.generation !== generation &&
              result.attachments.length > 0
            ) {
              discardUnreferenced(result.attachments).catch(() => undefined);
            }
          })
          .catch(() => undefined);
        const result = await waitForAttachmentPicker(
          nativeOperation,
          t('messages.attachment.timeout'),
        );
        if (result.status === 'cancelled' || result.attachments.length === 0)
          return;
        const selectedConversationId = store.getState().selectedConversationId;
        const operation = activeAttachmentOperation.current;
        if (
          operation?.generation !== generation ||
          operation.conversationId !== conversationId ||
          operation.stale ||
          selectedConversationId !== conversationId ||
          expectedOwnershipKey !==
            completionOwnershipKey(
              completionController.getState(),
              selectedConversationId,
              completionUiEpoch.current,
            ) ||
          completionBusy(completionController.getState()) ||
          selectConversationById(store.getState(), conversationId) === null
        ) {
          await discardUnreferenced(result.attachments).catch(() => undefined);
          return;
        }
        const liveDraftAttachments = draftAttachmentsRef.current;
        const ids = new Set(
          liveDraftAttachments.map(attachment => attachment.id),
        );
        let totalSize = liveDraftAttachments.reduce(
          (sum, attachment) => sum + attachment.size,
          0,
        );
        const accepted: AttachmentDescriptor[] = [];
        const overflow: AttachmentDescriptor[] = [];
        result.attachments.forEach(attachment => {
          if (ids.has(attachment.id)) return;
          ids.add(attachment.id);
          if (
            liveDraftAttachments.length + accepted.length >=
              MAX_ATTACHMENTS_PER_MESSAGE ||
            totalSize + attachment.size > MAX_TOTAL_ATTACHMENT_SIZE
          ) {
            overflow.push(attachment);
            return;
          }
          totalSize += attachment.size;
          accepted.push(attachment);
        });
        const nextAttachments = [...liveDraftAttachments, ...accepted];
        if (accepted.length > 0) invalidatePendingProjectSend();
        draftAttachmentsRef.current = nextAttachments;
        setDraftAttachments(nextAttachments);
        if (overflow.length > 0) {
          LocalAttachments.discard(
            overflow.map(attachment => attachment.id),
          ).catch(() => undefined);
          setRequestFailure(t('messages.attachment.limit'));
        }
      } catch (error) {
        const operation = activeAttachmentOperation.current;
        if (
          operation?.generation === generation &&
          !operation.stale &&
          store.getState().selectedConversationId === conversationId &&
          expectedOwnershipKey ===
            completionOwnershipKey(
              completionController.getState(),
              conversationId,
              completionUiEpoch.current,
            ) &&
          !completionBusy(completionController.getState())
        ) {
          setRequestFailure(
            t('messages.attachment.failed', { error: errorText(error) }),
          );
        }
      } finally {
        if (activeAttachmentOperation.current?.generation === generation) {
          activeAttachmentOperation.current = null;
          setAttachmentBusy(false);
        }
      }
    },
    [
      completionController,
      ensureConversation,
      invalidatePendingProjectSend,
      referencedAttachmentIds,
      store,
      t,
    ],
  );

  const removeDraftAttachment = useCallback(
    (id: string, expectedOwnershipKey: string) => {
      const liveOwnershipKey = completionOwnershipKey(
        completionController.getState(),
        store.getState().selectedConversationId,
        completionUiEpoch.current,
      );
      if (
        expectedOwnershipKey !== liveOwnershipKey ||
        completionBusy(completionController.getState()) ||
        activeAttachmentOperation.current !== null ||
        activeAttachmentPreviewId.current !== null ||
        !draftAttachmentsRef.current.some(attachment => attachment.id === id)
      ) {
        return;
      }
      const nextAttachments = draftAttachmentsRef.current.filter(
        attachment => attachment.id !== id,
      );
      invalidatePendingProjectSend();
      draftAttachmentsRef.current = nextAttachments;
      setDraftAttachments(nextAttachments);
      const referenced = referencedAttachmentIds(store.getState()).includes(id);
      if (!referenced && LocalAttachments.isAvailable()) {
        LocalAttachments.discard([id]).catch(error =>
          setRequestFailure(
            t('messages.attachment.failed', { error: errorText(error) }),
          ),
        );
      }
    },
    [
      completionController,
      invalidatePendingProjectSend,
      referencedAttachmentIds,
      store,
      t,
    ],
  );

  const presentAttachmentPreview = useCallback(
    async (id: string, expectedOwnershipKey: string) => {
      const liveOwnershipKey = completionOwnershipKey(
        completionController.getState(),
        store.getState().selectedConversationId,
        completionUiEpoch.current,
      );
      if (
        activeAttachmentPreviewId.current !== null ||
        activeAttachmentOperation.current !== null ||
        completionBusy(completionController.getState()) ||
        expectedOwnershipKey !== liveOwnershipKey
      )
        return;
      if (!LocalAttachments.isAvailable()) {
        setRequestFailure(t('messages.attachment.previewUnavailable'));
        return;
      }
      activeAttachmentPreviewId.current = id;
      setPreviewingAttachmentId(id);
      setRequestFailure(null);
      try {
        await LocalAttachments.presentPreview(id);
      } catch (error) {
        if (
          activeAttachmentPreviewId.current === id &&
          expectedOwnershipKey ===
            completionOwnershipKey(
              completionController.getState(),
              store.getState().selectedConversationId,
              completionUiEpoch.current,
            ) &&
          !completionBusy(completionController.getState())
        ) {
          setRequestFailure(
            t('messages.attachment.previewFailed', { error: errorText(error) }),
          );
        }
      } finally {
        if (activeAttachmentPreviewId.current === id) {
          activeAttachmentPreviewId.current = null;
          setPreviewingAttachmentId(null);
        }
      }
    },
    [completionController, store, t],
  );

  const openPendingProjectRecovery = useCallback(
    (
      conversationId: string,
      text: string,
      attachments: readonly AttachmentDescriptor[],
    ) => {
      capturePendingProjectSend(conversationId, text, attachments);
      projectContextUiEpoch.current += 1;
      setContextSheetFilter('all');
      contextSheetVisibleRef.current = true;
      setContextSheetVisible(true);
    },
    [capturePendingProjectSend],
  );

  const performCompletionSend = useCallback(
    async (
      conversationId: string,
      text: string,
      attachments: readonly AttachmentDescriptor[],
      sendWithoutProjectContext = false,
    ) => {
      const conversation = selectConversationById(
        store.getState(),
        conversationId,
      );
      if (conversation === null) return;
      const attachmentIds = attachments.map(attachment => attachment.id);
      setAttachmentNotice(null);
      setRequestFailure(null);
      const unboundAgentChat =
        !sendWithoutProjectContext &&
        conversation.workspaceId === null &&
        conversation.projectId === null &&
        conversation.workspaceBinding == null &&
        AgentRuntime.isAvailable();
      setWorkspaceHintConversationId(unboundAgentChat ? conversationId : null);
      const outcomeEpoch = ++completionUiEpoch.current;
      let durable = false;
      let restored = false;
      const clearOutgoingDraft = () => {
        if (store.getState().selectedConversationId !== conversationId ||
            completionUiEpoch.current !== outcomeEpoch) return;
        if (draftRef.current === text) {
          draftRef.current = '';
          setDraft('');
        }
        if (sameOrderedAttachmentIds(draftAttachmentsRef.current, attachmentIds)) {
          draftAttachmentsRef.current = [];
          setDraftAttachments([]);
        }
      };
      const result = await completionController.send(
        {
          conversationId,
          text,
          attachments,
          harnessId: harnessForModel(conversation.modelId),
          ...(sendWithoutProjectContext ? { sendWithoutProjectContext: true } : {}),
        },
        {
          onPrepared: clearOutgoingDraft,
          onPreparedDurable: () => {
            durable = true;
            if (restored) clearOutgoingDraft();
          },
          onCommitted: () => {
            refreshProof().catch(() => undefined);
          },
        },
      );
      if (!durable && store.getState().selectedConversationId === conversationId &&
          completionUiEpoch.current === outcomeEpoch &&
          draftRef.current === '' && draftAttachmentsRef.current.length === 0) {
        restored = true;
        draftRef.current = text;
        setDraft(text);
        draftAttachmentsRef.current = attachments;
        setDraftAttachments(attachments);
      }
      applyCompletionOutcome(result, outcomeEpoch);
    },
    [
      applyCompletionOutcome,
      completionController,
      refreshProof,
      store,
    ],
  );

  const send = useCallback(async () => {
    if (!sessionProjectionReady.current) return;
    const prompt = draft;
    const outgoingAttachments = draftAttachments;
    const selectedConversation = selectActiveConversation(store.getState());
    const contextControllerState = projectContextController.getState();
    if (
      !credentialConfigured ||
      (prompt.trim().length === 0 && outgoingAttachments.length === 0) ||
      completionBusy(completionController.getState()) ||
      store.getState().projectContextDestructiveTransition !== null ||
      directProjectMutationOutboxRef.current !== null ||
      lifecycleIntentRef.current !== null ||
      contextSheetVisibleRef.current ||
      pendingProjectSendActionInFlight.current ||
      (selectedConversation !== null &&
        sameProjectContextOwner(
          contextControllerState.owner,
          selectedConversation,
        ) &&
        projectContextOwnsMutation(contextControllerState)) ||
      activeAttachmentOperation.current !== null ||
      activeAttachmentPreviewId.current !== null
    )
      return;
    const conversationId = ensureConversation();
    const beforeAppend = selectConversationById(
      store.getState(),
      conversationId,
    );
    // Whether anything in this turn carries an attachment at all, of any
    // kind. Android's transport refuses a request whose history carries one,
    // because it has no way to put the content in front of the model; sending
    // the text alone would answer a question about a file the model was never
    // shown. Refusing here keeps the draft and the attachment and says why,
    // instead of starting a round that fails for a reason nothing explains.
    const carriesAttachment =
      beforeAppend?.messages.some(
        message => (message.attachments?.length ?? 0) > 0,
      ) === true || outgoingAttachments.length > 0;
    if (carriesAttachment && !LocalAttachments.isModelDeliverySupported()) {
      setRequestFailure(t('messages.attachment.platformUnsupported'));
      return;
    }
    const historyNeedsVision =
      beforeAppend?.messages.some(message =>
        message.attachments?.some(attachment => attachment.kind === 'image'),
      ) === true ||
      outgoingAttachments.some(attachment => attachment.kind === 'image');
    const imageHarness = beforeAppend === null
      ? null
      : BUILTIN_HARNESSES.get(harnessForModel(beforeAppend.modelId));
    if (
      historyNeedsVision &&
      !imageHarness?.models.some(model => model.inputModalities.includes('image'))
    ) {
      setRequestFailure(
        t('messages.attachment.harnessUnsupported', { harness: imageHarness?.name ?? '' }),
      );
      return;
    }
    let visionModelChanged = false;
    if (
      historyNeedsVision &&
      !dshModelSupportsImages(beforeAppend?.modelId ?? '')
    ) {
      visionModelChanged = changeConversationModel(
        conversationId,
        imageHarness!.models.find(entry => entry.inputModalities.includes('image'))!.id,
        'send_image_guard',
      );
      if (visionModelChanged) {
        setAttachmentNotice(t('messages.attachment.visionEnabled'));
      }
    }
    if (visionModelChanged && beforeAppend?.projectId !== null) {
      if (await persist()) reconcileSelectedConversation(conversationId);
      openPendingProjectRecovery(
        conversationId,
        prompt,
        outgoingAttachments,
      );
      return;
    }
    if (
      beforeAppend?.projectId !== null &&
      beforeAppend?.projectId !== undefined &&
      (beforeAppend.projectContext === null ||
        !isProjectContextSendable(beforeAppend.projectContext) ||
        !projectContextNativeAvailable ||
        !sameProjectContextOwner(
          projectContextController.getState().owner,
          beforeAppend,
        ) ||
        projectContextController.getState().phase !== 'idle' ||
        projectContextController.getState().candidateManifest !== null)
    ) {
      openPendingProjectRecovery(
        conversationId,
        prompt,
        outgoingAttachments,
      );
      return;
    }
    invalidatePendingProjectSend();
    await performCompletionSend(
      conversationId,
      prompt,
      outgoingAttachments,
    );
  }, [
    changeConversationModel,
    completionController,
    credentialConfigured,
    draft,
    draftAttachments,
    ensureConversation,
    invalidatePendingProjectSend,
    openPendingProjectRecovery,
    performCompletionSend,
    projectContextController,
    projectContextNativeAvailable,
    persist,
    reconcileSelectedConversation,
    store,
    t,
  ]);

  const retry = useCallback(async (expected: CompletionControllerState) => {
    if (
      retryActionInFlight.current ||
      directProjectMutationOutboxRef.current !== null ||
      lifecycleIntentRef.current !== null ||
      store.getState().projectContextDestructiveTransition !== null ||
      activeAttachmentOperation.current !== null ||
      activeAttachmentPreviewId.current !== null
    )
      return;
    const current = completionController.getState();
    if (
      current.epoch !== expected.epoch ||
      current.phase !== expected.phase ||
      current.conversationId !== expected.conversationId ||
      current.attemptId !== expected.attemptId ||
      current.roundId !== expected.roundId
    ) {
      return;
    }
    const actionable =
      current.phase === 'persistence_pending' ||
      current.phase === 'commit_pending' ||
      ((current.phase === 'resume_available' ||
        current.phase === 'retryable') &&
        current.conversationId !== null &&
        current.attemptId !== null);
    if (!actionable) return;
    if (
      (current.phase === 'resume_available' || current.phase === 'retryable') &&
      !(await restoreCurrentSessionAuthority())
    ) {
      setStorageWarning(t('home.persistenceUnavailable'));
      return;
    }
    const restored = completionController.getState();
    if (
      restored.epoch !== current.epoch ||
      restored.phase !== current.phase ||
      restored.conversationId !== current.conversationId ||
      restored.attemptId !== current.attemptId ||
      restored.roundId !== current.roundId
    ) {
      return;
    }
    retryActionInFlight.current = true;
    const outcomeEpoch = ++completionUiEpoch.current;
    let result: CompletionControllerOutcome | null = null;
    try {
      if (current.phase === 'persistence_pending') {
        result = await completionController.retryPersistence();
      } else if (current.phase === 'commit_pending') {
        result = await completionController.retryCommit();
      } else if (
        current.phase === 'resume_available' &&
        current.conversationId !== null &&
        current.attemptId !== null
      ) {
        result = await completionController.resume(
          current.conversationId,
          current.attemptId,
          { onCommitted: () => refreshProof().catch(() => undefined) },
        );
      } else if (
        current.phase === 'retryable' &&
        current.conversationId !== null &&
        current.attemptId !== null
      ) {
        result = await completionController.retry(
          current.conversationId,
          current.attemptId,
          { onCommitted: () => refreshProof().catch(() => undefined) },
        );
      }
      if (result !== null) applyCompletionOutcome(result, outcomeEpoch);
    } finally {
      retryActionInFlight.current = false;
    }
  }, [
    applyCompletionOutcome,
    completionController,
    refreshProof,
    restoreCurrentSessionAuthority,
    store,
    t,
  ]);

  /**
   * Give up on an attempt whose round nobody can resolve, and ask again.
   *
   * The same guards as `retry`: nothing else may be in flight, and the state
   * must still be the one the button was drawn from.
   */
  const abandonAndRetry = useCallback(async (expected: CompletionControllerState) => {
    if (
      retryActionInFlight.current ||
      directProjectMutationOutboxRef.current !== null ||
      lifecycleIntentRef.current !== null ||
      store.getState().projectContextDestructiveTransition !== null ||
      activeAttachmentOperation.current !== null ||
      activeAttachmentPreviewId.current !== null
    )
      return;
    const current = completionController.getState();
    if (
      current.epoch !== expected.epoch ||
      current.phase !== expected.phase ||
      current.conversationId !== expected.conversationId ||
      current.attemptId !== expected.attemptId ||
      current.roundId !== expected.roundId ||
      current.conversationId === null ||
      current.attemptId === null
    ) {
      return;
    }
    if (!(await restoreCurrentSessionAuthority())) {
      setStorageWarning(t('home.persistenceUnavailable'));
      return;
    }
    const restored = completionController.getState();
    if (
      restored.epoch !== current.epoch ||
      restored.phase !== current.phase ||
      restored.conversationId !== current.conversationId ||
      restored.attemptId !== current.attemptId ||
      restored.roundId !== current.roundId
    ) {
      return;
    }
    retryActionInFlight.current = true;
    const outcomeEpoch = ++completionUiEpoch.current;
    try {
      const result = await completionController.abandonAndRetry(
        current.conversationId,
        current.attemptId,
        { onCommitted: () => refreshProof().catch(() => undefined) },
      );
      applyCompletionOutcome(result, outcomeEpoch);
    } finally {
      retryActionInFlight.current = false;
    }
  }, [
    applyCompletionOutcome,
    completionController,
    refreshProof,
    restoreCurrentSessionAuthority,
    store,
    t,
  ]);

  const cancel = useCallback(async (expected: CompletionControllerState) => {
    const owned = completionController.getState();
    if (
      !completionCancellable(owned) ||
      owned.epoch !== expected.epoch ||
      owned.conversationId !== expected.conversationId ||
      owned.attemptId !== expected.attemptId ||
      owned.roundId !== expected.roundId
    ) {
      return;
    }
    const outcomeEpoch = ++completionUiEpoch.current;
    await completionController.cancel();
    if (outcomeEpoch !== completionUiEpoch.current) return;
    const current = completionController.getState();
    if (
      current.phase === 'persistence_pending' ||
      current.phase === 'blocked'
    ) {
      setRequestFailure(current.failureCode ?? 'E_ATTEMPT_PERSISTENCE');
    } else if (current.phase === 'cancelling') {
      setRequestFailure(null);
    } else {
      setRequestFailure(t('home.responseStopped'));
    }
  }, [completionController, t]);

  const captureLifecycleIntent = useCallback(
    (
      conversationId: string,
      action: ProjectContextLifecycleIntent['action'],
      targetProjectId: string | null = null,
    ): ProjectContextLifecycleIntent | null => {
      const captured =
        projectContextLifecycleController.captureDestructiveBeginToken(
          conversationId,
          action,
          targetProjectId,
        );
      if (!captured.ok) {
        setRequestFailure(captured.code);
        return null;
      }
      return Object.freeze({
        nonce: ++lifecycleIntentNonce.current,
        action,
        conversationId,
        selectedConversationId: store.getState().selectedConversationId,
        targetProjectId,
        beginToken: captured.token,
      });
    },
    [projectContextLifecycleController, store],
  );

  const lifecycleIntentIsLive = useCallback(
    (expected: ProjectContextLifecycleIntent): boolean => {
      if (
        lifecycleIntentRef.current !== expected ||
        store.getState().selectedConversationId !==
          expected.selectedConversationId
      ) {
        return false;
      }
      const fresh =
        projectContextLifecycleController.captureDestructiveBeginToken(
          expected.conversationId,
          expected.action,
          expected.targetProjectId,
        );
      return fresh.ok && sameDestructiveBeginToken(fresh.token, expected.beginToken);
    },
    [projectContextLifecycleController, store],
  );

  const openLifecycleSheet = useCallback(
    (intent: ProjectContextLifecycleIntent) => {
      lifecycleIntentRef.current = intent;
      setLifecycleIntent(intent);
      setLifecycleSheetTargetId(intent.conversationId);
      projectContextUiEpoch.current += 1;
      contextSheetVisibleRef.current = true;
      setContextSheetVisible(true);
    },
    [],
  );

  const openBlockedProjectContext = useCallback((conversationId: string) => {
    lifecycleIntentRef.current = null;
    setLifecycleIntent(null);
    setLifecycleSheetTargetId(null);
    projectContextUiEpoch.current += 1;
    contextSheetVisibleRef.current = true;
    setContextSheetVisible(true);
    if (
      projectContextController.getState().owner?.conversationId !==
      conversationId
    ) {
      projectContextController
        .attachConversation(conversationId)
        .catch(() => undefined);
    }
  }, [projectContextController]);

  const finishLifecycleOutcome = useCallback(
    async (
      result: ProjectContextDestructiveOutcome,
      action: ProjectContextLifecycleIntent['action'],
      targetConversationId: string,
      selectedAtStart: string | null,
    ) => {
      lifecycleActionInFlight.current = false;
      if (result.status !== 'completed') {
        if (store.getState().projectContextDestructiveTransition !== null) {
          lifecycleIntentRef.current = null;
          setLifecycleIntent(null);
        }
        setRequestFailure(
          result.status === 'blocked' ||
            result.status === 'cleanup_pending' ||
            result.status === 'persistence_pending'
            ? result.code
            : null,
        );
        return;
      }

      lifecycleIntentRef.current = null;
      setLifecycleIntent(null);
      setLifecycleSheetTargetId(null);
      contextSheetVisibleRef.current = false;
      projectContextUiEpoch.current += 1;
      setContextSheetVisible(false);
      setRequestFailure(null);
      completionUiEpoch.current += 1;

      if (action === 'delete') {
        if (selectedAtStart === targetConversationId) {
          markAttachmentOperationStale();
          discardDraftAttachments();
          draftRef.current = '';
          setDraft('');
        }
        if (store.getState().selectedConversationId === null) {
          store.createConversation(newConversationOptions());
        }
        await synchronizeAttachmentStore(store.getState());
      } else if (
        action === 'unbind' &&
        store.getState().selectedConversationId === targetConversationId
      ) {
        setActiveProjectName(null);
      }

      const selected = store.getState().selectedConversationId;
      if (selected !== null) reconcileSelectedConversation(selected);
    },
    [
      discardDraftAttachments,
      markAttachmentOperationStale,
      newConversationOptions,
      reconcileSelectedConversation,
      store,
      synchronizeAttachmentStore,
    ],
  );

  const confirmLifecycleIntent = useCallback(async (
    expected: ProjectContextLifecycleIntent | null,
    expectedSurfaceEpoch: number,
  ) => {
    if (
      expected === null ||
      projectContextUiEpoch.current !== expectedSurfaceEpoch ||
      lifecycleActionInFlight.current ||
      !contextSheetVisibleRef.current ||
      !lifecycleIntentIsLive(expected)
    ) {
      return;
    }
    lifecycleActionInFlight.current = true;
    try {
    if (
      !(await projectContextController.beforeConversationChange(
        expected.conversationId,
      )) ||
      !lifecycleIntentIsLive(expected) ||
      completionBusy(completionController.getState())
    ) {
      lifecycleActionInFlight.current = false;
      return;
    }
    const fresh =
      projectContextLifecycleController.captureDestructiveBeginToken(
        expected.conversationId,
        expected.action,
        expected.targetProjectId,
      );
    if (
      !fresh.ok ||
      !sameDestructiveBeginToken(fresh.token, expected.beginToken) ||
      !lifecycleIntentIsLive(expected)
    ) {
      lifecycleActionInFlight.current = false;
      return;
    }
    const result =
      await projectContextLifecycleController.beginDestructiveTransition(
        fresh.token,
      );
    await finishLifecycleOutcome(
      result,
      expected.action,
      expected.conversationId,
      expected.selectedConversationId,
    );
    } finally {
      // finishLifecycleOutcome releases this, but only when it is reached.
      // A rejected await before it stranded the flag, and every lifecycle
      // recovery control is gated on it -- as is destructiveAuthorityActive,
      // so conversation switching went with it.
      lifecycleActionInFlight.current = false;
    }
  }, [
    completionController,
    finishLifecycleOutcome,
    lifecycleIntentIsLive,
    projectContextController,
    projectContextLifecycleController,
  ]);

  const retryLifecyclePersistence = useCallback(
    async (
      expected: ProjectContextDestructiveToken,
      expectedSurfaceEpoch: number,
    ) => {
      if (
        projectContextUiEpoch.current !== expectedSurfaceEpoch ||
        lifecycleActionInFlight.current ||
        !contextSheetVisibleRef.current ||
        !sameDestructiveToken(
          expected,
          projectContextLifecycleController.getDestructiveToken(),
        )
      ) {
        return;
      }
      lifecycleActionInFlight.current = true;
      try {
        const result =
          await projectContextLifecycleController.retryDestructivePersistence(
            expected,
          );
        await finishLifecycleOutcome(
          result,
          expected.action,
          expected.conversationId,
          store.getState().selectedConversationId,
        );
      } finally {
      // finishLifecycleOutcome releases this, but only when it is reached.
      // A rejected await before it stranded the flag, and every lifecycle
      // recovery control is gated on it -- as is destructiveAuthorityActive,
      // so conversation switching went with it.
        lifecycleActionInFlight.current = false;
      }
    }, [finishLifecycleOutcome, projectContextLifecycleController, store],
  );

  const retryLifecycleCleanup = useCallback(
    async (
      expected: ProjectContextDestructiveToken,
      expectedSurfaceEpoch: number,
    ) => {
      if (
        projectContextUiEpoch.current !== expectedSurfaceEpoch ||
        lifecycleActionInFlight.current ||
        !contextSheetVisibleRef.current ||
        !sameDestructiveToken(
          expected,
          projectContextLifecycleController.getDestructiveToken(),
        )
      ) {
        return;
      }
      lifecycleActionInFlight.current = true;
      try {
        const result =
          await projectContextLifecycleController.retryDestructiveCleanup(
            expected,
          );
        await finishLifecycleOutcome(
          result,
          expected.action,
          expected.conversationId,
          store.getState().selectedConversationId,
        );
      } finally {
        // See confirmLifecycleIntent: the flag has to be released whatever the
        // await does, or every lifecycle recovery control stays inert.
        lifecycleActionInFlight.current = false;
      }
    }, [finishLifecycleOutcome, projectContextLifecycleController, store],
  );

  const showDirectProjectMutationRecovery = useCallback(
    (outbox: DirectProjectMutationOutbox) => {
      const view: DirectProjectMutationView = {
        action: outbox.action,
        conversationId: outbox.conversationId,
        targetProjectId: outbox.targetProjectId,
        targetProjectName: outbox.targetProjectName,
      };
      directProjectMutationOutboxRef.current = outbox;
      setDirectProjectMutationView(view);
      setLifecycleSheetTargetId(outbox.conversationId);
      projectContextUiEpoch.current += 1;
      if (
        outbox.sourceProjectsEpoch !== null &&
        projectsSurfaceEpoch.current !== outbox.sourceProjectsEpoch
      ) {
        setRequestFailure('E_CONTEXT_PERSISTENCE');
        return;
      }
      if (
        outbox.sourceProjectsEpoch !== null &&
        projectsVisibleRef.current
      ) {
        pendingDirectOpenAfterProjectsDismiss.current = view;
        projectsVisibleRef.current = false;
        setProjectsVisible(false);
      } else {
        contextSheetVisibleRef.current = true;
        setContextSheetVisible(true);
      }
      setRequestFailure('E_CONTEXT_PERSISTENCE');
    },
    [],
  );

  const completeDirectProjectMutation = useCallback(
    async (outbox: DirectProjectMutationOutbox) => {
      directProjectMutationOutboxRef.current = null;
      setDirectProjectMutationView(null);
      setLifecycleSheetTargetId(null);
      contextSheetVisibleRef.current = false;
      projectContextUiEpoch.current += 1;
      setContextSheetVisible(false);
      setRequestFailure(null);
      if (outbox.action === 'delete') {
        if (outbox.selectedConversationId === outbox.conversationId) {
          markAttachmentOperationStale();
          discardDraftAttachments();
          draftRef.current = '';
          setDraft('');
        }
        if (store.getState().selectedConversationId === null) {
          store.createConversation(newConversationOptions());
        }
        await synchronizeAttachmentStore(store.getState());
      } else if (
        store.getState().selectedConversationId === outbox.conversationId
      ) {
        setActiveProjectName(
          outbox.action === 'rebind' ? outbox.targetProjectName : null,
        );
      }
      const selected = store.getState().selectedConversationId;
      if (selected !== null) reconcileSelectedConversation(selected);
    },
    [
      discardDraftAttachments,
      markAttachmentOperationStale,
      newConversationOptions,
      reconcileSelectedConversation,
      store,
      synchronizeAttachmentStore,
    ],
  );

  const settleDirectProjectMutation = useCallback(
    async (
      outbox: DirectProjectMutationOutbox,
      transaction: SnapshotFreeProjectMutationTransaction,
      durability: SessionDurabilityResult,
    ) => {
      if (directProjectMutationOutboxRef.current !== outbox) return;
      if (durability.status === 'committed') {
        if (!transaction.commit()) {
          showDirectProjectMutationRecovery({
            ...outbox,
            transaction: null,
          });
          return;
        }
        await completeDirectProjectMutation(outbox);
        return;
      }
      if (durability.status === 'not_committed') {
        if (!transaction.rollback()) {
          showDirectProjectMutationRecovery({
            ...outbox,
            transaction: null,
          });
          return;
        }
        showDirectProjectMutationRecovery({
          ...outbox,
          transaction: null,
        });
        return;
      }
      showDirectProjectMutationRecovery({ ...outbox, transaction });
    }, [completeDirectProjectMutation, showDirectProjectMutationRecovery],
  );

  const applyDirectProjectMutation = useCallback(
    async (
      action: DirectProjectMutationOutbox['action'],
      conversation: Conversation,
      targetProjectId: string | null,
      targetProjectName: string | null = null,
    ): Promise<boolean> => {
      if (directProjectMutationOutboxRef.current !== null) return false;
      const selectedConversationId = store.getState().selectedConversationId;
      const sourceProjectsEpoch = projectsVisibleRef.current
        ? projectsSurfaceEpoch.current
        : null;
      const transaction = store.applySnapshotFreeProjectMutation({
        action,
        conversationId: conversation.id,
        targetProjectId,
        expectedConversation: conversation,
      });
      if (transaction === null) {
        setRequestFailure('E_PROJECT_MUTATION_UNAVAILABLE');
        return false;
      }
      const outbox: DirectProjectMutationOutbox = {
        action,
        conversationId: conversation.id,
        targetProjectId,
        targetProjectName,
        expectedConversation: conversation,
        selectedConversationId,
        transaction,
        sourceProjectsEpoch,
      };
      directProjectMutationOutboxRef.current = outbox;
      setDirectProjectMutationView({
        action,
        conversationId: conversation.id,
        targetProjectId,
        targetProjectName,
      });
      directProjectMutationPersistenceInFlight.current = true;
      try {
        await settleDirectProjectMutation(
          outbox,
          transaction,
          await persistCurrentRef.current(),
        );
      } finally {
        directProjectMutationPersistenceInFlight.current = false;
      }
      return true;
    }, [settleDirectProjectMutation, store],
  );

  const retryDirectProjectMutationPersistence = useCallback(async (
    expected: DirectProjectMutationView | null,
    expectedSurfaceEpoch: number,
  ) => {
    const outbox = directProjectMutationOutboxRef.current;
    if (
      expected === null ||
      projectContextUiEpoch.current !== expectedSurfaceEpoch ||
      outbox === null ||
      outbox.action !== expected.action ||
      outbox.conversationId !== expected.conversationId ||
      outbox.targetProjectId !== expected.targetProjectId ||
      lifecycleActionInFlight.current ||
      !contextSheetVisibleRef.current
    ) {
      return;
    }
    lifecycleActionInFlight.current = true;
    try {
      const transaction =
        outbox.transaction ??
        store.applySnapshotFreeProjectMutation({
          action: outbox.action,
          conversationId: outbox.conversationId,
          targetProjectId: outbox.targetProjectId,
          expectedConversation: outbox.expectedConversation,
        });
      if (transaction === null) return;
      const next = { ...outbox, transaction, sourceProjectsEpoch: null };
      directProjectMutationOutboxRef.current = next;
      directProjectMutationPersistenceInFlight.current = true;
      try {
        await settleDirectProjectMutation(
          next,
          transaction,
          await persistCurrentRef.current(),
        );
      } finally {
        directProjectMutationPersistenceInFlight.current = false;
      }
    } finally {
      lifecycleActionInFlight.current = false;
    }
  }, [settleDirectProjectMutation, store]);

  const destructiveAuthorityActive = useCallback(
    (allowSettledRecovery = false) => {
      const destructiveToken =
        projectContextLifecycleController.getDestructiveToken();
      const durableLifecycleActive =
        store.getState().projectContextDestructiveTransition !== null ||
        destructiveToken !== null;
      return (
      (directProjectMutationOutboxRef.current !== null &&
        (!allowSettledRecovery ||
          directProjectMutationPersistenceInFlight.current)) ||
      lifecycleIntentRef.current !== null ||
        (durableLifecycleActive &&
          (!allowSettledRecovery ||
            lifecycleActionInFlight.current ||
            destructiveToken === null))
      );
    },
    [projectContextLifecycleController, store],
  );

  const rootSurfaceAdmissionAllowed = useCallback(
    (allowSettledDirectRecovery = false) =>
      (!nativeAvailable || sessionProjectionReady.current) &&
      lifecycleBootstrapReadyRef.current &&
      !navigationSurfaceVisibleRef.current &&
      !contextSheetVisibleRef.current &&
      !destructiveAuthorityActive(allowSettledDirectRecovery) &&
      !projectContextOperationInFlight(projectContextController.getState()),
    [destructiveAuthorityActive, nativeAvailable, projectContextController],
  );

  // The drawer is admitted with rootSurfaceAdmissionAllowed(true), which
  // tolerates a settled recovery. An action that refuses what admission
  // allowed is a button that does nothing and says nothing, so an entry guard
  // asks with the same tolerance and routes to the recovery sheet itself.
  // Re-validation after an await stays strict: nothing destructive proceeds.
  const drawerSourceIsLive = useCallback(
    (expectedEpoch: number, allowSettledDirectRecovery = false) =>
      (!nativeAvailable || sessionProjectionReady.current) &&
      lifecycleBootstrapReadyRef.current &&
      (wideLayout || drawerVisibleRef.current) &&
      drawerSurfaceEpoch.current === expectedEpoch &&
      !contextSheetVisibleRef.current &&
      !destructiveAuthorityActive(allowSettledDirectRecovery) &&
      !projectContextOperationInFlight(projectContextController.getState()),
    [destructiveAuthorityActive, nativeAvailable, projectContextController, wideLayout],
  );

  const settingsSourceIsLive = useCallback(
    (expectedEpoch: number) =>
      (!nativeAvailable || sessionProjectionReady.current) &&
      lifecycleBootstrapReadyRef.current &&
      settingsVisibleRef.current &&
      settingsSurfaceEpoch.current === expectedEpoch &&
      !contextSheetVisibleRef.current &&
      !destructiveAuthorityActive() &&
      !projectContextOperationInFlight(projectContextController.getState()),
    [destructiveAuthorityActive, nativeAvailable, projectContextController],
  );

  // A docked Drawer never dismisses: SlidingSurface returns before it can fire
  // onDismiss (SlidingSurface.tsx:76). Every caller that stages work for the
  // dismissal and then closes would strand it on a wide layout, so the hand-off
  // runs here instead. It re-validates what it was given, so a close that
  // staged nothing is a no-op.
  const drawerDismissHandoff = useRef<(() => void) | null>(null);
  const drawerRecoveryRouter = useRef<((epoch: number) => boolean) | null>(null);
  const closeDrawerSurface = useCallback(() => {
    drawerSurfaceEpoch.current += 1;
    drawerVisibleRef.current = false;
    setDrawerVisible(false);
    if (wideLayout) drawerDismissHandoff.current?.();
  }, [wideLayout]);

  const createConversation = useCallback(async (
    expectedDrawerEpoch: number,
  ) => {
    if (
      navigationMutationInFlight.current ||
      !drawerSourceIsLive(expectedDrawerEpoch, true)
    )
      return;
    navigationMutationInFlight.current = true;
    try {
      const currentId = store.getState().selectedConversationId;
      const currentConversation =
        currentId === null
          ? null
          : selectConversationById(store.getState(), currentId);
      if (directProjectMutationOutboxRef.current !== null) {
        const direct = directProjectMutationView;
        if (direct !== null) {
          pendingLifecycleOpenAfterDrawerDismiss.current = {
            intent: null,
            token: null,
            direct,
          };
          closeDrawerSurface();
        }
        return;
      }
      if (
        currentId !== null &&
        !projectContextLifecycleController.beforeConversationChange(currentId)
      ) {
        const token = projectContextLifecycleController.getDestructiveToken();
        if (token !== null) {
          pendingLifecycleOpenAfterDrawerDismiss.current = {
            intent: null,
            token,
            direct: null,
          };
          closeDrawerSurface();
        }
        return;
      }
      if (
        currentId !== null &&
        !(await projectContextController.beforeConversationChange(currentId))
      ) {
        afterDrawerDismiss.current = () =>
          openBlockedProjectContext(currentId);
        closeDrawerSurface();
        return;
      }
      if (
        !drawerSourceIsLive(expectedDrawerEpoch) ||
        store.getState().selectedConversationId !== currentId ||
        !sameConversationOwner(
          currentConversation,
          currentId === null
            ? null
            : selectConversationById(store.getState(), currentId),
        )
      )
        return;
      if (
        currentId !== null &&
        !(await completionController.beforeConversationChange(currentId))
      ) {
        return;
      }
      if (
        !drawerSourceIsLive(expectedDrawerEpoch) ||
        store.getState().selectedConversationId !== currentId ||
        !sameConversationOwner(
          currentConversation,
          currentId === null
            ? null
            : selectConversationById(store.getState(), currentId),
        )
      )
        return;
      completionUiEpoch.current += 1;
      markAttachmentOperationStale();
      discardDraftAttachments();
      store.createConversation(newConversationOptions());
      setDraft('');
      setAttachmentNotice(null);
      setRequestFailure(null);
      closeDrawerSurface();
      reconcileSelectedConversation(store.getState().selectedConversationId!);
      await persist();
    } finally {
      navigationMutationInFlight.current = false;
    }
  }, [
    completionController,
    closeDrawerSurface,
    discardDraftAttachments,
    directProjectMutationView,
    drawerSourceIsLive,
    markAttachmentOperationStale,
    openBlockedProjectContext,
    persist,
    newConversationOptions,
    projectContextController,
    projectContextLifecycleController,
    reconcileSelectedConversation,
    store,
  ]);

  const selectConversation = useCallback(
    async (id: string, expectedDrawerEpoch: number) => {
      if (
        navigationMutationInFlight.current ||
        !drawerSourceIsLive(expectedDrawerEpoch, true)
      )
        return;
      navigationMutationInFlight.current = true;
      try {
        const currentId = store.getState().selectedConversationId;
        const currentConversation =
          currentId === null
            ? null
            : selectConversationById(store.getState(), currentId);
        const targetConversation = selectConversationById(store.getState(), id);
        if (targetConversation === null) return;
        if (directProjectMutationOutboxRef.current !== null) {
          const direct = directProjectMutationView;
          if (direct !== null) {
            pendingLifecycleOpenAfterDrawerDismiss.current = {
              intent: null,
              token: null,
              direct,
            };
            closeDrawerSurface();
          }
          return;
        }
        if (
          currentId !== null &&
          !projectContextLifecycleController.beforeConversationChange(currentId)
        ) {
          const token = projectContextLifecycleController.getDestructiveToken();
          if (token !== null) {
            pendingLifecycleOpenAfterDrawerDismiss.current = {
              intent: null,
              token,
              direct: null,
            };
            closeDrawerSurface();
          }
          return;
        }
        if (
          currentId !== null &&
          !(await projectContextController.beforeConversationChange(currentId))
        ) {
          afterDrawerDismiss.current = () =>
            openBlockedProjectContext(currentId);
          closeDrawerSurface();
          return;
        }
        if (
          !drawerSourceIsLive(expectedDrawerEpoch) ||
          store.getState().selectedConversationId !== currentId ||
          !sameConversationOwner(
            currentConversation,
            currentId === null
              ? null
              : selectConversationById(store.getState(), currentId),
          ) ||
          !sameConversationOwner(
            targetConversation,
            selectConversationById(store.getState(), id),
          )
        )
          return;
        if (
          currentId !== null &&
          !(await completionController.beforeConversationChange(currentId))
        ) {
          return;
        }
        if (
          !drawerSourceIsLive(expectedDrawerEpoch) ||
          store.getState().selectedConversationId !== currentId ||
          !sameConversationOwner(
            currentConversation,
            currentId === null
              ? null
              : selectConversationById(store.getState(), currentId),
          ) ||
          !sameConversationOwner(
            targetConversation,
            selectConversationById(store.getState(), id),
          )
        )
          return;
        completionUiEpoch.current += 1;
        markAttachmentOperationStale();
        discardDraftAttachments();
        store.selectConversation(id);
        setDraft('');
        setAttachmentNotice(null);
        setRequestFailure(null);
        closeDrawerSurface();
        reconcileSelectedConversation(id);
        await persist();
      } finally {
        navigationMutationInFlight.current = false;
      }
    },
    [
      completionController,
      closeDrawerSurface,
      discardDraftAttachments,
      directProjectMutationView,
      drawerSourceIsLive,
      markAttachmentOperationStale,
      openBlockedProjectContext,
      persist,
      projectContextController,
      projectContextLifecycleController,
      reconcileSelectedConversation,
      store,
    ],
  );

  const openSystemTask = useCallback(async (id: string) => {
    if (!selectConversationById(store.getState(), id)) return true;
    if (store.getState().selectedConversationId === id) return true;
    if (completionBusy(completionState) && completionState.conversationId !== id) return false;
    if (!rootSurfaceAdmissionAllowed(true)) return false;
    drawerSurfaceEpoch.current += 1;
    drawerVisibleRef.current = true;
    setDrawerVisible(true);
    await selectConversation(id, drawerSurfaceEpoch.current);
    return store.getState().selectedConversationId === id;
  }, [store, rootSurfaceAdmissionAllowed, selectConversation, completionState]);


  const renameConversation = useCallback(
    (title: string) => {
      if (
        actionConversationId === null ||
        directProjectMutationOutboxRef.current !== null ||
        lifecycleIntentRef.current !== null ||
        store.getState().projectContextDestructiveTransition !== null
      )
        return;
      store.renameConversation(actionConversationId, title);
      persist().catch(() => undefined);
    },
    [actionConversationId, persist, store],
  );

  const confirmDeleteConversation = useCallback(
    (request: ConversationDeleteRequest) => {
      const requestIsLive = () =>
        conversationActionEpoch.current === request.actionEpoch &&
        completionUiEpoch.current === request.completionEpoch &&
        store.getState().selectedConversationId ===
          request.selectedConversationId &&
        selectConversationById(
          store.getState(),
          request.conversation.id,
        ) === request.conversation &&
        !contextSheetVisibleRef.current &&
        lifecycleIntentRef.current === null &&
        directProjectMutationOutboxRef.current === null &&
        store.getState().projectContextDestructiveTransition === null;
      if (!requestIsLive()) return;
      Alert.alert(t('home.deleteChatTitle'), t('home.deleteChatBody'), [
        {
          text: t('common.cancel'),
          style: 'cancel',
          onPress: () => {
            if (conversationActionEpoch.current === request.actionEpoch) {
              conversationActionEpoch.current += 1;
            }
          },
        },
        {
          text: t('common.delete'),
          style: 'destructive',
          onPress: () =>
            (async () => {
              if (navigationMutationInFlight.current || !requestIsLive()) return;
              const operationActionEpoch = ++conversationActionEpoch.current;
              const operationIsLive = () =>
                conversationActionEpoch.current === operationActionEpoch &&
                completionUiEpoch.current === request.completionEpoch &&
                store.getState().selectedConversationId ===
                  request.selectedConversationId &&
                sameDeleteOwner(
                  selectConversationById(
                    store.getState(),
                    request.conversation.id,
                  ),
                  request.conversation,
                ) &&
                !contextSheetVisibleRef.current &&
                lifecycleIntentRef.current === null &&
                directProjectMutationOutboxRef.current === null &&
                store.getState().projectContextDestructiveTransition === null;
              navigationMutationInFlight.current = true;
              try {
                if (
                  !operationIsLive() ||
                  !projectContextLifecycleController.beforeConversationDelete(
                    request.conversation.id,
                  )
                ) {
                  return;
                }
                if (
                  request.conversation.projectContext?.snapshot !== null &&
                  request.conversation.projectContext?.snapshot !== undefined
                ) {
                  const intent = captureLifecycleIntent(
                    request.conversation.id,
                    'delete',
                  );
                  if (
                    intent === null ||
                    !operationIsLive() ||
                    !(await projectContextController.beforeConversationChange(
                      request.conversation.id,
                    )) ||
                    !operationIsLive()
                  ) {
                    return;
                  }
                  const fresh =
                    projectContextLifecycleController.captureDestructiveBeginToken(
                      request.conversation.id,
                      'delete',
                      null,
                    );
                  if (
                    !fresh.ok ||
                    !sameDestructiveBeginToken(
                      fresh.token,
                      intent.beginToken,
                    ) ||
                    !operationIsLive()
                  ) {
                    return;
                  }
                  openLifecycleSheet(intent);
                  return;
                }
                if (
                  !(await projectContextController.beforeConversationDelete(
                    request.conversation.id,
                  )) ||
                  !operationIsLive()
                ) {
                  return;
                }
                const completionAllowed =
                  await completionController.beforeConversationDelete(
                    request.conversation.id,
                  );
                if (!completionAllowed || !operationIsLive()) {
                  return;
                }
                const beforeMutation = selectConversationById(
                  store.getState(),
                  request.conversation.id,
                );
                if (beforeMutation === null) return;
                completionUiEpoch.current += 1;
                setRequestFailure(null);
                await applyDirectProjectMutation(
                  'delete',
                  beforeMutation,
                  null,
                );
              } finally {
                navigationMutationInFlight.current = false;
              }
            })().catch(() => undefined),
        },
      ]);
    },
    [
      completionController,
      applyDirectProjectMutation,
      captureLifecycleIntent,
      openLifecycleSheet,
      projectContextController,
      projectContextLifecycleController,
      store,
      t,
    ],
  );

  // Effective policy projection for the read-only Agent policy panel. This
  // is display context only: native revalidates every capability and grant
  // before any effect.
  const policyBindingRevision = activeConversation?.workspaceBinding?.bindingRevision ??
    (activeWorkspaceId === null ? null : workspaceDescriptors[activeWorkspaceId]?.binding_revision ?? null);
  const policyProjectId = activeConversation?.workspaceBinding?.projectId ?? activeConversation?.projectId ?? null;
  const nativeAgentPolicy = useAgentPolicy({
    visible: agentPolicyVisible,
    workspaceId: activeWorkspaceId,
    bindingRevision: policyBindingRevision,
    projectId: policyProjectId,
  });
  const agentPolicy = projectAgentPolicy({
    workspaceId: activeWorkspaceId,
    bindingRevision: policyBindingRevision,
    projectId: policyProjectId,
    conversationId: activeConversation?.id ?? null,
    status: nativeAgentPolicy.status,
    policy: nativeAgentPolicy.policy,
    grants: activeConversation?.agentGrants ?? activeConversation?.agent_grants ?? [],
  });

  const revokeAgentGrant = useCallback(
    async (grantId: string): Promise<void> => {
      if (agentPolicyRevokeBusy) return;
      const conversation = selectActiveConversation(store.getState());
      if (conversation === null) return;
      setAgentPolicyRevokeBusy(true);
      setAgentPolicyRevokeFailed(null);
      const transaction = store.revokeAgentGrant({
        conversationId: conversation.id,
        grantId,
        expectedConversation: conversation,
      });
      if (transaction === null) {
        setAgentPolicyRevokeFailed('conflict');
        setAgentPolicyRevokeBusy(false);
        return;
      }
      try {
        const persisted = await persistCurrent();
        if (persisted.status === 'committed') {
          transaction.commit();
          setChatState(store.getState());
        } else {
          transaction.rollback();
          setAgentPolicyRevokeFailed('persistence');
        }
      } catch {
        transaction.rollback();
        setAgentPolicyRevokeFailed('persistence');
      }
      setAgentPolicyRevokeBusy(false);
    },
    [agentPolicyRevokeBusy, persistCurrent, store],
  );

  const requestDeleteConversation = useCallback(() => {
    if (
      actionConversationId === null ||
      contextSheetVisibleRef.current ||
      lifecycleIntentRef.current !== null ||
      directProjectMutationOutboxRef.current !== null ||
      store.getState().projectContextDestructiveTransition !== null
    )
      return;
    const deleting = selectConversationById(
      store.getState(),
      actionConversationId,
    );
    if (deleting === null) return;
    const request: ConversationDeleteRequest = Object.freeze({
      actionEpoch: conversationActionEpoch.current,
      completionEpoch: completionUiEpoch.current,
      selectedConversationId: store.getState().selectedConversationId,
      conversation: deleting,
    });
    afterActionDismiss.current = () => confirmDeleteConversation(request);
    setActionConversationId(null);
  }, [actionConversationId, confirmDeleteConversation, store]);

  const destructiveSurfaceBlocked = useCallback(
    () =>
      contextSheetVisibleRef.current ||
      store.getState().projectContextDestructiveTransition !== null ||
      directProjectMutationOutboxRef.current !== null ||
      lifecycleIntentRef.current !== null,
    [store],
  );

  const selectModel = useCallback(
    (model: SupportedModel, source: ModelTransitionSource) => {
      if (
        completionBusy(completionController.getState()) ||
        store.getState().projectContextDestructiveTransition !== null ||
        directProjectMutationOutboxRef.current !== null ||
        lifecycleIntentRef.current !== null ||
        projectContextOwnsMutation(projectContextController.getState()) ||
        activeAttachmentOperation.current !== null
      ) {
        return;
      }
      const conversationId = ensureConversation();
      invalidatePendingProjectSend();
      if (!changeConversationModel(conversationId, model, source)) return;
      setAttachmentNotice(null);
      persist()
        .then(saved => {
          if (saved) reconcileSelectedConversation(conversationId);
        })
        .catch(() => undefined);
    },
    [
      changeConversationModel,
      completionController,
      ensureConversation,
      persist,
      projectContextController,
      reconcileSelectedConversation,
      invalidatePendingProjectSend,
      store,
    ],
  );

  const selectComposerModel = useCallback(
    (model: SupportedModel) => selectModel(model, 'composer_picker'),
    [selectModel],
  );
  useEffect(() => {
    if (activeHarnessId !== 'codex' || !codexModels?.length || codexModels.some(model => model.id === activeModel)) return;
    if (activeConversation && activeConversation.messages.length > 0) return;
    selectModel(codexModels[0].id, 'composer_picker');
  }, [activeHarnessId, codexModels, activeModel, activeConversation, selectModel]);

  const selectSettingsModel = useCallback(
    (model: SupportedModel) => selectModel(model, 'settings_picker'),
    [selectModel],
  );

  const presentSettingsSurface = useCallback(() => {
    setSettingsAuthOnly(false);
    settingsSurfaceEpoch.current += 1;
    settingsVisibleRef.current = true;
    setSettingsVisible(true);
  }, []);

  const closeSettingsSurface = useCallback(() => {
    settingsSurfaceEpoch.current += 1;
    settingsVisibleRef.current = false;
    setSettingsVisible(false);
  }, []);

  const selectThinkingMode = useCallback(
    (thinkingMode: Conversation['thinkingMode']) => {
      if (
        completionBusy(completionController.getState()) ||
        store.getState().projectContextDestructiveTransition !== null ||
        directProjectMutationOutboxRef.current !== null ||
        lifecycleIntentRef.current !== null ||
        projectContextOwnsMutation(projectContextController.getState()) ||
        activeAttachmentOperation.current !== null
      ) {
        return;
      }
      const conversationId = ensureConversation();
      invalidatePendingProjectSend();
      store.setThinkingMode(conversationId, thinkingMode);
      persist().catch(() => undefined);
    },
    [
      completionController,
      ensureConversation,
      persist,
      projectContextController,
      invalidatePendingProjectSend,
      store,
    ],
  );

  const openComposerOptions = useCallback(() => {
    if (
      !rootSurfaceAdmissionAllowed() ||
      completionBusy(completionController.getState()) ||
      activeAttachmentOperation.current !== null
    ) {
      return;
    }
    setComposerOptionsVisible(true);
  }, [completionController, rootSurfaceAdmissionAllowed]);

  const openSettings = useCallback(() => {
    if (!rootSurfaceAdmissionAllowed()) return;
    presentSettingsSurface();
  }, [presentSettingsSurface, rootSurfaceAdmissionAllowed]);

  const openSettingsFromDrawer = useCallback((expectedEpoch: number) => {
    if (!drawerSourceIsLive(expectedEpoch, true)) return;
    if (drawerRecoveryRouter.current?.(expectedEpoch) === true) return;
    presentSettingsSurface();
  }, [drawerSourceIsLive, presentSettingsSurface]);

  useEffect(() => {
    if (!LocalWorkspaces.isAvailable()) return;
    let cancelled = false;
    LocalWorkspaces.list()
      .then(listing => {
        if (cancelled) return;
        setWorkspaceNames(
          Object.fromEntries(
            listing.workspaces.map(workspace => [
              workspace.workspace_id,
              workspace.display_name,
            ]),
          ),
        );
        setWorkspaceDescriptors(
          Object.fromEntries(
            listing.workspaces.map(workspace => [
              workspace.workspace_id,
              workspace,
            ]),
          ),
        );
      })
      .catch(() => undefined);
    return () => {
      cancelled = true;
    };
  }, [workspaceRefreshToken]);

  const [workspaceGitActivationBusy, setWorkspaceGitActivationBusy] = useState(false);
  const [workspaceGitActivationError, setWorkspaceGitActivationError] = useState<string | null>(null);
  const workspaceGitActivationBusyRef = useRef(false);
  const agentPolicyVisibleRef = useRef(agentPolicyVisible);
  agentPolicyVisibleRef.current = agentPolicyVisible;
  const workspaceGitActivation = useMemo(() => createWorkspaceGitActivation({
    resolve: request => LocalWorkspaces.resolve(request),
    projectForWorkspace: root => LocalProjects.projectForWorkspaceV2(root),
    attach: request => LocalProjects.attachWorkspaceProject(request),
    createOperationId: () => LocalRuntime.createCompletionRequestId(),
  }), []);
  const workspaceGitActivationAvailable =
    nativeAvailable && LocalProjects.isV2Available() && LocalWorkspaces.isAvailable() &&
    activeConversation?.projectId === null && activeConversation.workspaceBinding != null &&
    activeConversation.workspaceBinding.projectId === null &&
    activeConversation.workspaceId === activeConversation.workspaceBinding.workspaceId &&
    workspaceDescriptors[activeConversation.workspaceBinding.workspaceId]?.capabilities.git === true &&
    workspaceDescriptors[activeConversation.workspaceBinding.workspaceId]?.capabilities.project_context === true;
  const workspaceGitActivationBlocked =
    !sessionProjectionReady.current || !lifecycleBootstrapReadyRef.current ||
    navigationMutationInFlight.current || projectChatTransitionInFlight.current ||
    completionBusy(completionState) || projectContextOwnsMutation(projectContextControllerState) ||
    destructiveSurfaceBlocked() || workspaceBindingRecoveryVisible ||
    workspaceBindingController.getState().phase === 'persistence_pending' ||
    activeAttachmentOperation.current !== null || activeAttachmentPreviewId.current !== null ||
    (chatState.workspaceAuthorityOutbox ?? []).some(entry => entry.workspaceId === activeWorkspaceId) ||
    activeConversation?.attempts.some(attempt => attempt.status === 'prepared' || attempt.status === 'sending') === true;
  programOpenBlockedRef.current = workspaceGitActivationBlocked;
  const finishProgramSurfaceTransition = useCallback((source: 'files' | 'environments') => {
    const pending = pendingProgramOpenRef.current;
    if (pending === null || pending.source !== source) return;
    pendingProgramOpenRef.current = null;
    const current = selectActiveConversation(store.getState());
    if (programOpenBlockedRef.current ||
        (current?.id ?? null) !== pending.selectedConversationId) return;
    if (pending.context.conversationId !== null) {
      const binding = current?.workspaceBinding;
      if (current?.id !== pending.context.conversationId || binding == null ||
          binding.workspaceId !== pending.context.root.workspace_id ||
          binding.bindingRevision !== pending.context.root.binding_revision ||
          binding.projectId !== pending.context.root.project_id) return;
    }
    setProgramContext(pending.context);
    setProgramVisible(true);
  }, [store]);

  const enableWorkspaceGit = useCallback(async () => {
    const source = selectActiveConversation(store.getState());
    const binding = source?.workspaceBinding;
    if (
      workspaceGitActivationBusyRef.current || projectChatTransitionInFlight.current ||
      navigationMutationInFlight.current || !source || !binding || source.projectId !== null ||
      binding.projectId !== null ||
      source.workspaceId !== binding.workspaceId || !LocalProjects.isV2Available()
    ) return;
    const currentOwner = () =>
      agentPolicyVisibleRef.current && sessionProjectionReady.current &&
      lifecycleBootstrapReadyRef.current &&
      selectActiveConversation(store.getState()) === source &&
      !destructiveSurfaceBlocked() && !completionBusy(completionController.getState()) &&
      !projectContextOwnsMutation(projectContextController.getState()) &&
      activeAttachmentOperation.current === null && activeAttachmentPreviewId.current === null &&
      workspaceBindingController.getState().phase !== 'persistence_pending' &&
      !(store.getState().workspaceAuthorityOutbox ?? []).some(entry => entry.workspaceId === binding.workspaceId) &&
      !source.attempts.some(attempt => attempt.status === 'prepared' || attempt.status === 'sending');
    if (!currentOwner()) {
      setWorkspaceGitActivationError('E_WORKSPACE_BUSY');
      return;
    }
    workspaceGitActivationBusyRef.current = true;
    projectChatTransitionInFlight.current = true;
    setWorkspaceGitActivationBusy(true);
    setWorkspaceGitActivationError(null);
    let openedConversationId: string | null = null;
    try {
      const attached = await workspaceGitActivation.activate({
        schema_version: 1, workspace_id: binding.workspaceId,
        binding_revision: binding.bindingRevision, project_id: null,
      }, currentOwner, async () => {
        if (!projectContextLifecycleController.beforeConversationChange(source.id)) return false;
        if (!(await projectContextController.beforeConversationChange(source.id)) || !currentOwner()) return false;
        return await completionController.beforeConversationChange(source.id);
      });
      if (attached.status !== 'attached') {
        setWorkspaceGitActivationError(attached.code);
        return;
      }
      if (!currentOwner()) {
        setWorkspaceGitActivationError('E_WORKSPACE_CONFLICT');
        return;
      }
      // Existing attempts retain their frozen root. Like opening a project,
      // use a new conversation and the existing guarded binding/CAS flow.
      const conversationId = store.createConversation(newConversationOptions());
      openedConversationId = conversationId;
      const outcome = await workspaceBindingController.bindWorkspace({
        conversationId, workspaceId: attached.workspace.workspace_id,
        target: attached.workspace, expectedProjectId: attached.project.project_id,
        requiredCapabilities: ['read', 'write', 'git', 'project_context'],
      });
      if (outcome.status !== 'committed' && outcome.status !== 'unchanged') {
        setWorkspaceGitActivationError(outcome.code ?? 'E_WORKSPACE_CONFLICT');
        setRequestFailure(outcome.code ?? 'E_WORKSPACE_CONFLICT');
        if (outcome.status === 'unknown' || outcome.status === 'session_only' ||
            workspaceBindingController.getState().phase === 'persistence_pending') {
          setWorkspaceBindingRecoveryVisible(true);
          setAgentPolicyVisible(false);
        } else if (store.getState().selectedConversationId === conversationId) {
          const empty = store.getState().conversations[conversationId];
          if (empty?.messages.length === 0 && empty.attempts.length === 0) {
            store.selectConversation(source.id);
          }
        }
        return;
      }
      if (outcome.ownerDrifted || store.getState().selectedConversationId !== conversationId ||
          outcome.root.workspace_id !== binding.workspaceId ||
          outcome.root.project_id !== attached.project.project_id) {
        setWorkspaceGitActivationError('E_WORKSPACE_CONFLICT');
        return;
      }
      completionUiEpoch.current += 1;
      invalidatePendingProjectSend();
      setWorkspaceNames(previous => ({ ...previous, [binding.workspaceId]: outcome.workspace.display_name }));
      setWorkspaceDescriptors(previous => ({ ...previous, [binding.workspaceId]: outcome.workspace }));
      setWorkspaceRefreshToken(token => token + 1);
      setActiveProjectName(outcome.workspace.display_name);
      setWorkspaceBindingRecoveryVisible(false);
      setRequestFailure(null);
      setAgentPolicyVisible(false);
      reconcileSelectedConversation(conversationId);
    } catch (error) {
      setWorkspaceGitActivationError(gitActivationErrorCode(error));
      if (workspaceBindingController.getState().phase === 'persistence_pending') {
        setWorkspaceBindingRecoveryVisible(true);
        setAgentPolicyVisible(false);
      } else if (openedConversationId !== null && store.getState().selectedConversationId === openedConversationId) {
        const empty = store.getState().conversations[openedConversationId];
        if (empty?.projectId === null && empty.messages.length === 0 && empty.attempts.length === 0) {
          store.selectConversation(source.id);
        }
      }
    } finally {
      workspaceGitActivationBusyRef.current = false;
      projectChatTransitionInFlight.current = false;
      setWorkspaceGitActivationBusy(false);
    }
  }, [
    completionController, destructiveSurfaceBlocked, invalidatePendingProjectSend,
    newConversationOptions, projectContextController, projectContextLifecycleController,
    reconcileSelectedConversation, store, workspaceBindingController, workspaceGitActivation,
  ]);

  const openWorkspacePicker = useCallback(() => {
    if (
      !rootSurfaceAdmissionAllowed() ||
      completionBusy(completionController.getState())
    ) {
      return;
    }
    const nextGeneration = workspacePickerGenerationRef.current + 1;
    workspacePickerGenerationRef.current = nextGeneration;
    const nextNonce = workspaceSurfaceNonceRef.current + 1;
    workspaceSurfaceNonceRef.current = nextNonce;
    workspacePickerOwnersRef.current.set(
      nextGeneration,
      { conversation: selectActiveConversation(store.getState()), surfaceNonce: nextNonce },
    );
    setWorkspacePickerGeneration(nextGeneration);
    workspaceSheetVisibleRef.current = true;
    setWorkspaceSheetVisible(true);
  }, [completionController, rootSurfaceAdmissionAllowed, store]);

  const closeWorkspacePicker = useCallback(() => {
    workspacePickerGenerationRef.current += 1;
    workspacePickerOwnersRef.current.clear();
    setWorkspacePickerGeneration(workspacePickerGenerationRef.current);
    workspaceSurfaceNonceRef.current += 1;
    workspaceBindingController.invalidate();
    workspaceSheetVisibleRef.current = false;
    setWorkspaceSheetVisible(false);
    setWorkspaceRefreshToken(token => token + 1);
  }, [workspaceBindingController]);

  const handleWorkspaceSelect = useCallback(
    (
      workspaceId: string,
      pickerGeneration: number,
      surfaceNonce: number,
      expectedConversation: Conversation | null,
    ) => {
      if (
        destructiveSurfaceBlocked() ||
        !workspaceSheetVisibleRef.current ||
        workspacePickerGenerationRef.current !== pickerGeneration ||
        workspaceSurfaceNonceRef.current !== surfaceNonce ||
        selectActiveConversation(store.getState()) !== expectedConversation
      )
        return;
      invalidatePendingProjectSend();
      const conversationId = ensureConversation();
      workspaceBindingController
        .bindWorkspace({
          conversationId,
          workspaceId,
          pickerGeneration,
          surfaceNonce,
          requiredCapabilities:
            preferences.toolPermission === 'read-only'
              ? ['read']
              : ['read', 'write'],
        })
        .then(outcome => {
          if (
            outcome.status !== 'committed' &&
            outcome.status !== 'unchanged'
          ) {
            if (
              outcome.status === 'unknown' ||
              outcome.status === 'session_only'
            ) {
              setWorkspaceBindingRecoveryVisible(true);
              if ('code' in outcome) setRequestFailure(outcome.code);
            } else if (
              outcome.status === 'stale' &&
              workspaceBindingController.getState().phase ===
                'persistence_pending'
            ) {
              setWorkspaceBindingRecoveryVisible(true);
              setRequestFailure('E_WORKSPACE_PERSISTENCE');
            } else if (
              outcome.status !== 'stale' &&
              outcome.code !== undefined
            ) {
              setRequestFailure(outcome.code);
            }
            return;
          }
          if (
            workspacePickerGenerationRef.current !== pickerGeneration ||
            workspaceSurfaceNonceRef.current !== surfaceNonce
          ) {
            // The binding is durable. A dismissed/replaced picker cannot
            // publish a late conflict banner into the current conversation.
            // Controller ownership checks and uncertain-write recovery remain intact.
            return;
          }
          if ('ownerDrifted' in outcome && outcome.ownerDrifted) {
            setChatState(store.getState());
            setRequestFailure('E_WORKSPACE_CONFLICT');
            return;
          }
          setRequestFailure(previous => previous === 'E_WORKSPACE_CONFLICT' ? null : previous);
          setWorkspaceNames(previous => ({
            ...previous,
            [outcome.workspace.workspace_id]: outcome.workspace.display_name,
          }));
          setWorkspaceDescriptors(previous => ({
            ...previous,
            [outcome.workspace.workspace_id]: outcome.workspace,
          }));
          setWorkspaceBindingRecoveryVisible(false);
          closeWorkspacePicker();
        })
        .catch(error => setRequestFailure(errorText(error)));
    },
    [
      closeWorkspacePicker,
      destructiveSurfaceBlocked,
      ensureConversation,
      invalidatePendingProjectSend,
      preferences.toolPermission,
      store,
      workspaceBindingController,
    ],
  );

  const retryWorkspaceBinding = useCallback(() => {
    workspaceBindingController
      .retryPersistence()
      .then(outcome => {
          if (
            outcome.status === 'unknown' ||
            outcome.status === 'session_only'
          ) {
            setWorkspaceBindingRecoveryVisible(true);
            if ('code' in outcome) setRequestFailure(outcome.code);
          return;
        }
        if (outcome.status === 'not_committed' || outcome.status === 'conflict') {
          setWorkspaceBindingRecoveryVisible(false);
          if ('code' in outcome) setRequestFailure(outcome.code);
          return;
        }
        if (outcome.status !== 'committed' && outcome.status !== 'unchanged') {
          return;
        }
        setWorkspaceBindingRecoveryVisible(false);
        if ('ownerDrifted' in outcome && outcome.ownerDrifted) {
          setRequestFailure('E_WORKSPACE_CONFLICT');
          return;
        }
        if (workspaceSheetVisibleRef.current) {
          closeWorkspacePicker();
        } else if ('root' in outcome && 'workspace' in outcome) {
          const current = selectActiveConversation(store.getState());
          if (current !== null) {
            workspaceVisibleRef.current = true;
            setWorkspaceRoute({
              root: outcome.root,
              label: outcome.workspace.display_name,
              conversationId: current.id,
              projectId: outcome.root.project_id,
            });
            setWorkspaceVisible(true);
          }
        }
      })
      .catch(() => setWorkspaceBindingRecoveryVisible(true));
  }, [closeWorkspacePicker, store, workspaceBindingController]);

  const workspacePickerOnSelect = useCallback(
    (workspaceId: string) => {
      const owner = workspacePickerOwnersRef.current.get(workspacePickerGeneration);
      if (owner === undefined) return;
      handleWorkspaceSelect(
        workspaceId,
        workspacePickerGeneration,
        owner.surfaceNonce,
        owner.conversation,
      );
    },
    [handleWorkspaceSelect, workspacePickerGeneration],
  );

  const openFilesForConversation = useCallback(
    async (expectedConversation: Conversation | null) => {
      if (!lifecycleBootstrapReadyRef.current || expectedConversation === null)
        return;
      const current = selectActiveConversation(store.getState());
      if (current === null || current !== expectedConversation) return;
      const binding = current.workspaceBinding ?? null;
      if (binding !== null) {
        try {
          const root = assertWorkspaceRootRefV1({
            schema_version: 1,
            workspace_id: binding.workspaceId,
            binding_revision: binding.bindingRevision,
            project_id: binding.projectId,
          });
          workspaceVisibleRef.current = true;
          setWorkspaceRoute({
            root,
            label:
              workspaceNames[binding.workspaceId] ??
              (binding.projectId === null
                ? t('files.workspace')
                : activeProjectName ?? binding.projectId),
            conversationId: current.id,
            projectId: binding.projectId,
          });
          setWorkspaceVisible(true);
        } catch (error) {
          setRequestFailure(errorText(error));
        }
        return;
      }
      if (current.projectId !== null) {
        // Legacy project rows have no public workspace authority. Do not
        // synthesize a path or silently create a second app-owned root.
        setRequestFailure('E_WORKSPACE_ROOT_CHANGED');
        return;
      }
      const surfaceNonce = workspaceSurfaceNonceRef.current + 1;
      workspaceSurfaceNonceRef.current = surfaceNonce;
      const outcome = await workspaceBindingController.ensureAppOwnedWorkspace({
        conversationId: current.id,
        displayName: t('files.workspace'),
        requiredCapabilities:
          preferences.toolPermission === 'read-only'
            ? ['read']
            : ['read', 'write'],
        surfaceNonce,
        requireProjectless: true,
      });
      if (
        outcome.status !== 'committed' &&
        outcome.status !== 'unchanged'
      ) {
        if (
          outcome.status === 'unknown' ||
          outcome.status === 'session_only'
        ) {
          setWorkspaceBindingRecoveryVisible(true);
          if ('code' in outcome) setRequestFailure(outcome.code);
        } else if (
          outcome.status === 'stale' &&
          workspaceBindingController.getState().phase ===
            'persistence_pending'
        ) {
          setWorkspaceBindingRecoveryVisible(true);
          setRequestFailure('E_WORKSPACE_PERSISTENCE');
        } else if (outcome.status !== 'stale' && outcome.code !== undefined) {
          setRequestFailure(outcome.code);
        }
        return;
      }
      if (
        workspaceSurfaceNonceRef.current !== surfaceNonce ||
        store.getState().selectedConversationId !== current.id ||
        store.getState().conversations[current.id] === undefined
      ) {
        if ('ownerDrifted' in outcome && outcome.ownerDrifted) {
          setChatState(store.getState());
          setRequestFailure('E_WORKSPACE_CONFLICT');
        }
        return;
      }
      if ('ownerDrifted' in outcome && outcome.ownerDrifted) {
        setChatState(store.getState());
        setRequestFailure('E_WORKSPACE_CONFLICT');
        return;
      }
      setWorkspaceNames(previous => ({ ...previous, [outcome.workspace.workspace_id]: outcome.workspace.display_name }));
      setWorkspaceDescriptors(previous => ({ ...previous, [outcome.workspace.workspace_id]: outcome.workspace }));
      workspaceVisibleRef.current = true;
      setWorkspaceRoute({
        root: outcome.root,
        label: outcome.workspace.display_name,
        conversationId: current.id,
        projectId: outcome.root.project_id,
      });
      setWorkspaceVisible(true);
    },
    [
      activeProjectName,
      preferences.toolPermission,
      store,
      t,
      workspaceBindingController,
      workspaceNames,
    ],
  );

  const resolveProjectWorkspaceRoot = useMemo(() => createProjectWorkspaceRootResolver(), []);

  const chatInProject = useCallback(
    async (project: LocalProject) => {
      if (
        projectChatTransitionInFlight.current ||
        !projectsVisibleRef.current ||
        contextSheetVisibleRef.current ||
        lifecycleIntentRef.current !== null ||
        // A settled recovery outbox is handled below, by handing off to the
        // recovery surface. Refusing it here made that branch unreachable and
        // the control silent.
        store.getState().projectContextDestructiveTransition !== null
      )
        return;
      projectChatTransitionInFlight.current = true;
      let waitForDismiss = false;
      try {
        const sourceSurfaceEpoch = projectsSurfaceEpoch.current;
        const current = selectActiveConversation(store.getState());
        const expectedSelectedId = current?.id ?? null;
        if (directProjectMutationOutboxRef.current !== null) {
          if (directProjectMutationView !== null) {
            pendingDirectOpenAfterProjectsDismiss.current =
              directProjectMutationView;
            waitForDismiss = true;
            setProjectsVisible(false);
          }
          return;
        }
        if (
          current !== null &&
          !projectContextLifecycleController.beforeConversationChange(
            current.id,
          )
        ) {
          const token = projectContextLifecycleController.getDestructiveToken();
          if (token !== null) {
            pendingExistingLifecycleAfterProjectsDismiss.current = token;
            waitForDismiss = true;
            setProjectsVisible(false);
          }
          return;
        }
        if (
          current !== null &&
          !(await projectContextController.beforeConversationChange(current.id))
        ) {
          return;
        }
        const afterContextGuard =
          expectedSelectedId === null
            ? null
            : selectConversationById(store.getState(), expectedSelectedId);
        if (
          projectsSurfaceEpoch.current !== sourceSurfaceEpoch ||
          store.getState().selectedConversationId !== expectedSelectedId ||
          (current !== null &&
            (afterContextGuard === null ||
              afterContextGuard.projectId !== current.projectId ||
              afterContextGuard.runtimeContextId !== current.runtimeContextId ||
              afterContextGuard.modelId !== current.modelId ||
              afterContextGuard.projectContext !== current.projectContext))
        )
          return;
        if (
          current !== null &&
          !(await completionController.beforeConversationChange(current.id))
        ) {
          return;
        }
        const afterCompletionGuard =
          expectedSelectedId === null
            ? null
            : selectConversationById(store.getState(), expectedSelectedId);
        if (
          projectsSurfaceEpoch.current !== sourceSurfaceEpoch ||
          store.getState().selectedConversationId !== expectedSelectedId ||
          (current !== null &&
            (afterCompletionGuard === null ||
              afterCompletionGuard.projectId !== current.projectId ||
              afterCompletionGuard.runtimeContextId !==
                current.runtimeContextId ||
              afterCompletionGuard.modelId !== current.modelId ||
              afterCompletionGuard.projectContext !== current.projectContext))
        )
          return;
        const requiresProjectAuthority = current?.projectId !== project.id;
        let bootstrappedWorkspace: Awaited<
          ReturnType<typeof LocalWorkspaces.bootstrapLegacyProject>
        > | null = null;
        if (requiresProjectAuthority) {
          try {
            const root = await resolveProjectWorkspaceRoot(project.id);
            if (root === null) throw new Error('E_WORKSPACE_ROOT_CHANGED');
            const resolved = await LocalWorkspaces.resolve({
              schema_version: 1,
              workspace_id: root.workspace_id,
              expected_binding_revision: root.binding_revision,
              required_capabilities: ['read', 'write', 'git', 'project_context'],
            });
            if (resolved.disposition !== 'direct' || resolved.workspace.status !== 'ok' ||
                resolved.workspace.workspace_id !== root.workspace_id ||
                resolved.workspace.binding_revision !== root.binding_revision) {
              throw new Error('E_WORKSPACE_ROOT_CHANGED');
            }
            bootstrappedWorkspace = resolved.workspace;
          } catch {
            setRequestFailure('E_WORKSPACE_UNAVAILABLE');
            return;
          }
          const afterBootstrap =
            expectedSelectedId === null
              ? null
              : selectConversationById(store.getState(), expectedSelectedId);
          if (
            projectsSurfaceEpoch.current !== sourceSurfaceEpoch ||
            store.getState().selectedConversationId !== expectedSelectedId ||
            (current === null
              ? afterBootstrap !== null
              : afterBootstrap === null ||
                afterBootstrap.projectId !== current.projectId ||
                afterBootstrap.runtimeContextId !== current.runtimeContextId ||
                afterBootstrap.modelId !== current.modelId ||
                afterBootstrap.projectContext !== current.projectContext ||
                afterBootstrap.workspaceId !== current.workspaceId ||
                afterBootstrap.workspaceBinding !== current.workspaceBinding)
          ) {
            setRequestFailure('E_WORKSPACE_CONFLICT');
            return;
          }
        }
        completionUiEpoch.current += 1;
        setRequestFailure(null);
        if (current?.projectId !== project.id) {
          invalidatePendingProjectSend();
          if (bootstrappedWorkspace === null) {
            setRequestFailure('E_WORKSPACE_CONFLICT');
            return;
          }
          markAttachmentOperationStale();
          discardDraftAttachments();
          setDraft('');
          setAttachmentNotice(null);
          const conversationId = store.createConversation(newConversationOptions());
          let outcome: Awaited<
            ReturnType<typeof workspaceBindingController.bindWorkspace>
          >;
          try {
            outcome = await workspaceBindingController.bindWorkspace({
              conversationId,
              workspaceId: bootstrappedWorkspace.workspace_id,
              target: bootstrappedWorkspace,
              expectedProjectId: project.id,
              requiredCapabilities: [
                'read',
                'write',
                'git',
                'project_context',
              ],
            });
          } catch {
            setRequestFailure('E_WORKSPACE_CONFLICT');
            return;
          }
          if (
            outcome.status === 'session_only' ||
            outcome.status === 'unknown'
          ) {
            setWorkspaceBindingRecoveryVisible(true);
            setRequestFailure(outcome.code);
            return;
          }
          setWorkspaceBindingRecoveryVisible(false);
          if (
            outcome.status !== 'committed' &&
            outcome.status !== 'unchanged'
          ) {
            setRequestFailure(outcome.code ?? 'E_WORKSPACE_CONFLICT');
            return;
          }
          if (
            outcome.ownerDrifted === true ||
            outcome.root.workspace_id !== bootstrappedWorkspace.workspace_id ||
            outcome.root.binding_revision !==
              bootstrappedWorkspace.binding_revision ||
            outcome.root.project_id !== project.id
          ) {
            setChatState(store.getState());
            setRequestFailure('E_WORKSPACE_CONFLICT');
            return;
          }
          const boundConversation = selectConversationById(
            store.getState(),
            conversationId,
          );
          if (
            projectsSurfaceEpoch.current !== sourceSurfaceEpoch ||
            store.getState().selectedConversationId !== conversationId ||
            boundConversation === null ||
            boundConversation.projectId !== project.id ||
            boundConversation.workspaceId !== outcome.root.workspace_id ||
            boundConversation.workspaceBinding?.workspaceId !==
              outcome.root.workspace_id ||
            boundConversation.workspaceBinding.bindingRevision !==
              outcome.root.binding_revision ||
            boundConversation.workspaceBinding.projectId !== project.id
          ) {
            setRequestFailure('E_WORKSPACE_CONFLICT');
            return;
          }
          setWorkspaceNames(previous => ({
            ...previous,
            [outcome.workspace.workspace_id]: outcome.workspace.display_name,
          }));
          setWorkspaceDescriptors(previous => ({
            ...previous,
            [outcome.workspace.workspace_id]: outcome.workspace,
          }));
        }
        setActiveProjectName(project.name);
        const selected = store.getState().selectedConversationId;
        if (
          projectsSurfaceEpoch.current !== sourceSurfaceEpoch ||
          selected === null
        )
          return;
        const selectedConversation = selectConversationById(
          store.getState(),
          selected,
        );
        if (
          projectsSurfaceEpoch.current !== sourceSurfaceEpoch ||
          selectedConversation === null ||
          selectedConversation.projectId !== project.id
        ) {
          return;
        }
        const uiEpoch = ++projectContextUiEpoch.current;
        pendingContextOpenAfterProjectsDismiss.current = {
          conversationId: selected,
          projectId: project.id,
          runtimeContextId: selectedConversation.runtimeContextId,
          modelId: selectedConversation.modelId,
          uiEpoch,
        };
        waitForDismiss = true;
        projectsVisibleRef.current = false;
        setProjectsVisible(false);
      } finally {
        if (!waitForDismiss) projectChatTransitionInFlight.current = false;
      }
    },
    [
      resolveProjectWorkspaceRoot,
      completionController,
      discardDraftAttachments,
      directProjectMutationView,
      invalidatePendingProjectSend,
      markAttachmentOperationStale,
      newConversationOptions,
      projectContextController,
      projectContextLifecycleController,
      store,
      workspaceBindingController,
    ],
  );

  const handleProjectsDismiss = useCallback(() => {
    const direct = pendingDirectOpenAfterProjectsDismiss.current;
    pendingDirectOpenAfterProjectsDismiss.current = null;
    if (direct !== null) {
      projectChatTransitionInFlight.current = false;
      const live = directProjectMutationOutboxRef.current;
      if (
        live !== null &&
        live.action === direct.action &&
        live.conversationId === direct.conversationId &&
        live.targetProjectId === direct.targetProjectId
      ) {
        setLifecycleSheetTargetId(direct.conversationId);
        projectContextUiEpoch.current += 1;
        contextSheetVisibleRef.current = true;
        setContextSheetVisible(true);
      }
      return;
    }
    const existingLifecycle =
      pendingExistingLifecycleAfterProjectsDismiss.current;
    pendingExistingLifecycleAfterProjectsDismiss.current = null;
    if (existingLifecycle !== null) {
      projectChatTransitionInFlight.current = false;
      if (
        sameDestructiveToken(
          existingLifecycle,
          projectContextLifecycleController.getDestructiveToken(),
        )
      ) {
        setLifecycleSheetTargetId(existingLifecycle.conversationId);
        projectContextUiEpoch.current += 1;
        contextSheetVisibleRef.current = true;
        setContextSheetVisible(true);
      }
      return;
    }
    const lifecycle = pendingLifecycleOpenAfterProjectsDismiss.current;
    pendingLifecycleOpenAfterProjectsDismiss.current = null;
    if (lifecycle !== null) {
      projectChatTransitionInFlight.current = false;
      if (lifecycleIntentIsLive(lifecycle)) openLifecycleSheet(lifecycle);
      return;
    }
    const pending = pendingContextOpenAfterProjectsDismiss.current;
    pendingContextOpenAfterProjectsDismiss.current = null;
    if (pending === null) return;
    projectChatTransitionInFlight.current = false;
    const selected = selectActiveConversation(store.getState());
    if (
      selected === null ||
      selected.id !== pending.conversationId ||
      selected.projectId !== pending.projectId ||
      selected.runtimeContextId !== pending.runtimeContextId ||
      selected.modelId !== pending.modelId ||
      projectContextUiEpoch.current !== pending.uiEpoch
    ) {
      return;
    }
    setContextSheetFilter('all');
    contextSheetVisibleRef.current = true;
    setContextSheetVisible(true);
    if (
      completionOwnsPresentation(
        completionController.getState(),
        selected.id,
      ) ||
      selectProjectContextSnapshotReferences(store.getState(), selected.id)
        .length > 0 ||
      !projectContextNativeAvailable
    ) {
      return;
    }
    pendingContextAttachAfterOpen.current = pending;
  }, [
    completionController,
    lifecycleIntentIsLive,
    openLifecycleSheet,
    projectContextNativeAvailable,
    projectContextLifecycleController,
    store,
  ]);

  useEffect(() => {
    if (!contextSheetVisible) return;
    const pending = pendingContextAttachAfterOpen.current;
    pendingContextAttachAfterOpen.current = null;
    if (pending === null) return;
    (async () => {
      await projectContextController.attachConversation(pending.conversationId);
      const current = selectActiveConversation(store.getState());
      if (
        !contextSheetVisibleRef.current ||
        current === null ||
        current.id !== pending.conversationId ||
        current.projectId !== pending.projectId ||
        current.runtimeContextId !== pending.runtimeContextId ||
        current.modelId !== pending.modelId ||
        projectContextUiEpoch.current !== pending.uiEpoch
      ) {
        return;
      }
      const token = projectContextController.getActionToken();
      if (token !== null && current.projectContext?.snapshot === null) {
        projectContextController.search(token, '').catch(() => undefined);
      }
    })().catch(() => undefined);
  }, [contextSheetVisible, projectContextController, store]);

  const openProjectContextFromStrip = useCallback(() => {
    if (
      contextSheetVisibleRef.current ||
      navigationSurfaceVisibleRef.current
    ) {
      return;
    }
    const selected = selectActiveConversation(store.getState());
    if (
      selected === null ||
      selected.projectId === null ||
      selected.projectContext === null
    ) {
      return;
    }
    const pendingLifecycle = lifecycleIntentRef.current;
    const durableLifecycle =
      store.getState().projectContextDestructiveTransition;
    if (
      pendingLifecycle?.conversationId === selected.id ||
      durableLifecycle?.conversationId === selected.id
    ) {
      setLifecycleSheetTargetId(selected.id);
      projectContextUiEpoch.current += 1;
      contextSheetVisibleRef.current = true;
      setContextSheetVisible(true);
      return;
    }
    const uiEpoch = ++projectContextUiEpoch.current;
    setContextSheetFilter('all');
    contextSheetVisibleRef.current = true;
    setContextSheetVisible(true);
    if (
      completionOwnsPresentation(
        completionController.getState(),
        selected.id,
      ) ||
      selectProjectContextSnapshotReferences(store.getState(), selected.id)
        .length > 0 ||
      !projectContextNativeAvailable
    ) {
      return;
    }
    const controllerState = projectContextController.getState();
    if (sameProjectContextOwner(controllerState.owner, selected)) {
      // Already attached (the workspace picker attaches on binding), so
      // there is no attach to wait for -- but a sheet opened onto a context
      // with no snapshot still needs its candidate listing, or it opens on
      // "No project files found" until the person taps Refresh files.
      const token = projectContextController.getActionToken();
      if (
        selected.projectContext.snapshot === null &&
        token !== null &&
        controllerState.list.candidates.length === 0 &&
        !controllerState.list.loading
      ) {
        projectContextController.search(token, '').catch(() => undefined);
      }
      return;
    }
    projectContextController
      .attachConversation(selected.id)
      .then(() => {
        if (
          projectContextUiEpoch.current !== uiEpoch ||
          store.getState().selectedConversationId !== selected.id
        ) {
          return;
        }
        const current = selectConversationById(store.getState(), selected.id);
        const token = projectContextController.getActionToken();
        if (
          current?.projectContext?.snapshot === null &&
          token !== null
        ) {
          projectContextController.search(token, '').catch(() => undefined);
        }
      })
      .catch(() => undefined);
  }, [
    completionController,
    projectContextController,
    projectContextNativeAvailable,
    store,
  ]);

  const projectContextActionIsLive = (
    expected: ProjectContextActionToken | null,
  ): expected is ProjectContextActionToken => {
    if (
      !contextSheetVisibleRef.current ||
      projectContextUiEpoch.current !== projectContextRenderEpoch ||
      expected === null
    ) {
      return false;
    }
    const selected = selectActiveConversation(store.getState());
    if (
      selected === null ||
      selected.id !== expected.conversationId ||
      selected.projectId !== expected.projectId ||
      completionBlocksContextMutation(
        completionController.getState(),
        selected.id,
      ) ||
      selectProjectContextSnapshotReferences(store.getState(), selected.id)
        .length > 0
    ) {
      return false;
    }
    return sameProjectContextToken(
      expected,
      projectContextController.getActionToken(),
    );
  };

  const closeProjectContextSheet = () => {
    if (
      lifecycleIntentRef.current !== null &&
      store.getState().projectContextDestructiveTransition === null
    ) {
      lifecycleIntentNonce.current += 1;
      lifecycleIntentRef.current = null;
      setLifecycleIntent(null);
      setLifecycleSheetTargetId(null);
      lifecycleActionInFlight.current = false;
      setRequestFailure(null);
    }
    contextSheetVisibleRef.current = false;
    projectContextUiEpoch.current += 1;
    setContextSheetVisible(false);
  };

  const pendingProjectSurfaceIsLive = (
    expected: PendingProjectSend | null,
  ): expected is PendingProjectSend =>
    expected !== null &&
    contextSheetVisibleRef.current &&
    projectContextUiEpoch.current === projectContextRenderEpoch &&
    pendingProjectSendIsLive(expected);

  const pendingProjectActionIsBlocked = (
    expected: PendingProjectSend,
  ): boolean => {
    const conversation = selectConversationById(
      store.getState(),
      expected.conversationId,
    );
    if (conversation === null || conversation.projectId === null) return true;
    const completion = completionController.getState();
    if (completionOwnsPresentation(completion, conversation.id)) return true;
    const context = projectContextController.getState();
    return (
      sameProjectContextOwner(context.owner, conversation) &&
      projectContextOwnsMutation(context)
    );
  };

  const verifiedPendingProjectContextIsLive = (
    expected: PendingProjectSend,
  ): boolean => {
    if (!pendingProjectSendIsLive(expected)) return false;
    const conversation = selectConversationById(
      store.getState(),
      expected.conversationId,
    );
    const controllerState = projectContextController.getState();
    return (
      conversation !== null &&
      conversation.projectId !== null &&
      conversation.projectContext !== null &&
      isProjectContextSendable(conversation.projectContext) &&
      sameProjectContextOwner(controllerState.owner, conversation) &&
      controllerState.phase === 'idle' &&
      controllerState.candidateManifest === null &&
      !completionOwnsPresentation(
        completionController.getState(),
        conversation.id,
      )
    );
  };

  const queuePendingProjectSendAfterDismiss = (
    expected: PendingProjectSend | null,
    kind: PendingContextDismissAction['kind'],
  ) => {
    if (
      pendingProjectSendActionInFlight.current ||
      !pendingProjectSurfaceIsLive(expected) ||
      (kind === 'verified'
        ? !verifiedPendingProjectContextIsLive(expected)
        : pendingProjectActionIsBlocked(expected))
    ) {
      return;
    }
    pendingProjectSendActionInFlight.current = true;
    pendingContextDismissAction.current = {
      kind,
      pendingEpoch: expected.uiEpoch,
    };
    closeProjectContextSheet();
  };

  const refreshPendingProjectContext = (
    expectedPending: PendingProjectSend | null,
    expectedToken: ProjectContextActionToken | null,
  ) => {
    if (
      pendingProjectSendActionInFlight.current ||
      !pendingProjectSurfaceIsLive(expectedPending) ||
      expectedToken === null ||
      !projectContextNativeAvailable ||
      !projectContextActionIsLive(expectedToken) ||
      pendingProjectActionIsBlocked(expectedPending)
    ) {
      return;
    }
    pendingProjectSendActionInFlight.current = true;
    setPendingProjectSendStage('context_flow');
    projectContextController
      .search(expectedToken, '')
      .catch(() => undefined)
      .finally(() => {
        if (pendingProjectSendRef.current === expectedPending) {
          pendingProjectSendActionInFlight.current = false;
        }
      });
  };

  const completePendingProjectContextAction = (
    expectedPending: PendingProjectSend | null,
    expectedToken: ProjectContextActionToken | null,
    sendWhenCompleted: boolean,
    operation: () => Promise<{ readonly status: string }>,
  ) => {
    if (
      pendingProjectSendActionInFlight.current ||
      !pendingProjectSurfaceIsLive(expectedPending) ||
      !projectContextActionIsLive(expectedToken)
    ) {
      return;
    }
    const surfaceEpoch = projectContextRenderEpoch;
    pendingProjectSendActionInFlight.current = true;
    operation()
      .then(outcome => {
        if (pendingProjectSendRef.current !== expectedPending) return;
        pendingProjectSendActionInFlight.current = false;
        if (
          sendWhenCompleted &&
          outcome.status === 'completed' &&
          contextSheetVisibleRef.current &&
          projectContextUiEpoch.current === surfaceEpoch
        ) {
          queuePendingProjectSendAfterDismiss(expectedPending, 'verified');
        }
      })
      .catch(() => {
        if (pendingProjectSendRef.current === expectedPending) {
          pendingProjectSendActionInFlight.current = false;
        }
      });
  };

  const completeProjectContextAction = (
    expected: ProjectContextActionToken,
    closeOnSuccess: boolean,
    operation: () => Promise<{ readonly status: string }>,
  ) => {
    if (!projectContextActionIsLive(expected)) return;
    const capturedEpoch = projectContextRenderEpoch;
    operation()
      .then(outcome => {
        const selected = selectConversationById(
          store.getState(),
          expected.conversationId,
        );
        if (
          closeOnSuccess &&
          outcome.status === 'completed' &&
          contextSheetVisibleRef.current &&
          projectContextUiEpoch.current === capturedEpoch &&
          store.getState().selectedConversationId === expected.conversationId &&
          selected?.projectId === expected.projectId &&
          selected.runtimeContextId === expected.runtimeContextId &&
          selected.modelId === expected.modelId
        ) {
          closeProjectContextSheet();
        }
      })
      .catch(() => undefined);
  };

  const handleProjectContextDismiss = () => {
    const target =
      findNodeHandle(projectContextStripRef.current) ??
      projectContextStripTarget.current;
    if (typeof target === 'number') {
      AccessibilityInfo.setAccessibilityFocus(target);
    }
    const action = pendingContextDismissAction.current;
    pendingContextDismissAction.current = null;
    if (action === null) return;
    const pending = pendingProjectSendRef.current;
    if (
      pending === null ||
      pending.uiEpoch !== action.pendingEpoch ||
      !pendingProjectSendIsLive(pending) ||
      (action.kind === 'verified' &&
        !verifiedPendingProjectContextIsLive(pending)) ||
      (action.kind === 'without_context' &&
        pendingProjectActionIsBlocked(pending))
    ) {
      pendingProjectSendActionInFlight.current = false;
      return;
    }
    const text = pending.text;
    const attachments = pending.attachments;
    const conversationId = pending.conversationId;
    invalidatePendingProjectSend();
    performCompletionSend(
      conversationId,
      text,
      attachments,
      action.kind === 'without_context',
    ).catch(() => undefined);
  };

  const unbindProjectFromConversation = useCallback(async (
    sourceSurfaceEpoch: number,
  ) => {
    if (
      !projectsVisibleRef.current ||
      projectsSurfaceEpoch.current !== sourceSurfaceEpoch ||
      destructiveSurfaceBlocked()
    ) {
      return;
    }
    const conversationId = store.getState().selectedConversationId;
    if (conversationId === null) return;
    const conversation = selectConversationById(store.getState(), conversationId);
    if (conversation === null || conversation.projectId === null) return;
    const sourceIsLive = () => {
      if (
        !projectsVisibleRef.current ||
        projectsSurfaceEpoch.current !== sourceSurfaceEpoch ||
        destructiveSurfaceBlocked() ||
        store.getState().selectedConversationId !== conversationId
      ) {
        return false;
      }
      const current = selectConversationById(store.getState(), conversationId);
      return (
        current !== null &&
        current.projectId === conversation.projectId &&
        current.runtimeContextId === conversation.runtimeContextId &&
        current.modelId === conversation.modelId &&
        current.projectContext === conversation.projectContext
      );
    };
    if (!sourceIsLive()) return;
    if (conversation.projectContext?.snapshot !== null &&
        conversation.projectContext?.snapshot !== undefined) {
      const intent = captureLifecycleIntent(conversationId, 'unbind');
      if (!sourceIsLive()) return;
      if (intent === null) {
        const uiEpoch = ++projectContextUiEpoch.current;
        pendingContextOpenAfterProjectsDismiss.current = {
          conversationId,
          projectId: conversation.projectId,
          runtimeContextId: conversation.runtimeContextId,
          modelId: conversation.modelId,
          uiEpoch,
        };
        projectsSurfaceEpoch.current += 1;
        projectsVisibleRef.current = false;
        setProjectsVisible(false);
        return;
      }
      lifecycleIntentRef.current = intent;
      setLifecycleIntent(intent);
      setLifecycleSheetTargetId(conversationId);
      pendingLifecycleOpenAfterProjectsDismiss.current = intent;
      projectsSurfaceEpoch.current += 1;
      projectsVisibleRef.current = false;
      setProjectsVisible(false);
      return;
    }
    if (
      !(await projectContextController.beforeConversationChange(conversationId)) ||
      !sourceIsLive()
    ) {
      return;
    }
    if (
      !(await completionController.beforeConversationChange(conversationId)) ||
      !sourceIsLive()
    ) {
      return;
    }
    completionUiEpoch.current += 1;
    invalidatePendingProjectSend();
    setRequestFailure(null);
    const beforeMutation = selectConversationById(
      store.getState(),
      conversationId,
    );
    if (beforeMutation === null) return;
    await applyDirectProjectMutation('unbind', beforeMutation, null);
  }, [
    applyDirectProjectMutation,
    captureLifecycleIntent,
    completionController,
    destructiveSurfaceBlocked,
    invalidatePendingProjectSend,
    projectContextController,
    store,
  ]);

  const selectHarness = useCallback(
    (harnessId: string) => {
      if (
        !harnessesVisibleRef.current ||
        !BUILTIN_HARNESSES.has(harnessId) ||
        completionBusy(completionController.getState()) ||
        navigationMutationInFlight.current ||
        projectChatTransitionInFlight.current ||
        store.getState().projectContextDestructiveTransition !== null ||
        directProjectMutationOutboxRef.current !== null ||
        lifecycleIntentRef.current !== null ||
        projectContextOwnsMutation(projectContextController.getState()) ||
        activeAttachmentOperation.current !== null ||
        activeAttachmentPreviewId.current !== null ||
        credentialBusy
      ) {
        return;
      }
      const conversation = selectActiveConversation(store.getState());
      const model = defaultModelForHarness(
        harnessId,
        conversation?.modelId ?? preferencesStore.getState().defaultModel,
      );
      if (conversation !== null && conversation.modelId !== model) {
        store.setModel(conversation.id, model);
      }
      invalidatePendingProjectSend();
      preferencesStore.setSelectedHarness(harnessId);
      harnessesVisibleRef.current = false;
      setHarnessesVisible(false);
      const completionEpoch = completionUiEpoch.current;
      persist()
        .then(saved => {
          const selected = selectActiveConversation(store.getState());
          if (
            saved &&
            conversation !== null &&
            completionUiEpoch.current === completionEpoch &&
            selected?.id === conversation.id &&
            selected.modelId === model &&
            preferencesStore.getState().selectedHarnessId === harnessId
          ) {
            reconcileSelectedConversation(conversation.id);
          }
        })
        .catch(() => undefined);
    },
    [
      completionController,
      credentialBusy,
      invalidatePendingProjectSend,
      persist,
      preferencesStore,
      projectContextController,
      reconcileSelectedConversation,
      store,
    ],
  );

  const configureCredential = useCallback(async () => {
    if (!nativeAvailable) {
      setRuntimeFailure(t('home.secureStorageUnavailable'));
      return;
    }
    if (!sessionProjectionReady.current) return;
    setCredentialBusy(true);
    try {
      const result = await activeAdapter.presentCredentialPrompt(locale);
      if (result.status === 'configured') {
        setCredentialHarnessId(activeHarnessId);
        setCredentialConfigured(true);
        const refreshedProof = (await bootstrapForHarness(activeHarnessId)).proof;
        if (activeHarnessIdRef.current !== activeHarnessId) return;
        setProof(refreshedProof);
        setRuntimeFailure(null);
      }
    } catch (error) {
      setRuntimeFailure(errorText(error));
    } finally {
      setCredentialBusy(false);
    }
  }, [activeAdapter, activeHarnessId, locale, nativeAvailable, t]);

  const clearCredential = useCallback(() => {
    if (!sessionProjectionReady.current) return;
    Alert.alert(t('home.clearKeyTitle', { provider: providerName }), t('home.clearKeyBody'), [
      { text: t('common.cancel'), style: 'cancel' },
      {
        text: t('common.clear'),
        style: 'destructive',
        onPress: () => {
          setCredentialBusy(true);
          activeAdapter.clearCredential()
            .then(() => {
              setCredentialConfigured(false);
              setProof(null);
              closeSettingsSurface();
            })
            .catch(error => setRuntimeFailure(errorText(error)))
            .finally(() => setCredentialBusy(false));
        },
      },
    ]);
  }, [activeAdapter, closeSettingsSurface, providerName, t]);

  const openAfterDrawerDismiss = useCallback((
    expectedEpoch: number,
    open: () => void,
  ) => {
    if (!drawerSourceIsLive(expectedEpoch, true)) return;
    if (drawerRecoveryRouter.current?.(expectedEpoch) === true) return;
    if (wideLayout) {
      closeDrawerSurface();
      open();
      return;
    }
    afterDrawerDismiss.current = open;
    closeDrawerSurface();
  }, [closeDrawerSurface, drawerSourceIsLive, wideLayout]);

  const openPendingLifecycleFromDrawer = useCallback(
    (
      expectedIntent: ProjectContextLifecycleIntent | null,
      expectedToken: ProjectContextDestructiveToken | null,
      expectedDirect: DirectProjectMutationView | null,
      expectedDrawerEpoch: number,
    ) => {
      if (
        !lifecycleBootstrapReadyRef.current ||
        (!wideLayout && !drawerVisibleRef.current) ||
        drawerSurfaceEpoch.current !== expectedDrawerEpoch
      )
        return;
      if (
        expectedDirect !== null
          ? directProjectMutationOutboxRef.current === null ||
            directProjectMutationOutboxRef.current.action !==
              expectedDirect.action ||
            directProjectMutationOutboxRef.current.conversationId !==
              expectedDirect.conversationId ||
            directProjectMutationOutboxRef.current.targetProjectId !==
              expectedDirect.targetProjectId
          : expectedIntent !== null
          ? !lifecycleIntentIsLive(expectedIntent)
          : expectedToken === null ||
            !sameDestructiveToken(
              expectedToken,
              projectContextLifecycleController.getDestructiveToken(),
            )
      ) {
        return;
      }
      pendingLifecycleOpenAfterDrawerDismiss.current = {
        intent: expectedIntent,
        token: expectedToken,
        direct: expectedDirect,
      };
      closeDrawerSurface();
    },
    [
      closeDrawerSurface,
      lifecycleIntentIsLive,
      projectContextLifecycleController,
      wideLayout,
    ],
  );

  const handleDrawerDismiss = useCallback(() => {
    const lifecycle = pendingLifecycleOpenAfterDrawerDismiss.current;
    pendingLifecycleOpenAfterDrawerDismiss.current = null;
    if (lifecycle !== null) {
      const targetId =
        lifecycle.direct?.conversationId ??
        lifecycle.intent?.conversationId ??
        lifecycle.token?.conversationId;
      const live =
        lifecycle.direct !== null
          ? directProjectMutationOutboxRef.current !== null &&
            directProjectMutationOutboxRef.current.action ===
              lifecycle.direct.action &&
            directProjectMutationOutboxRef.current.conversationId ===
              lifecycle.direct.conversationId &&
            directProjectMutationOutboxRef.current.targetProjectId ===
              lifecycle.direct.targetProjectId
          : lifecycle.intent !== null
          ? lifecycleIntentIsLive(lifecycle.intent)
          : lifecycle.token !== null &&
            sameDestructiveToken(
              lifecycle.token,
              projectContextLifecycleController.getDestructiveToken(),
            );
      if (live && targetId !== undefined) {
        setLifecycleSheetTargetId(targetId);
        projectContextUiEpoch.current += 1;
        contextSheetVisibleRef.current = true;
        setContextSheetVisible(true);
      }
      return;
    }
    const open = afterDrawerDismiss.current;
    afterDrawerDismiss.current = null;
    if (
      !lifecycleBootstrapReadyRef.current ||
      contextSheetVisibleRef.current ||
      lifecycleIntentRef.current !== null ||
      directProjectMutationOutboxRef.current !== null ||
      store.getState().projectContextDestructiveTransition !== null
    ) {
      return;
    }
    open?.();
  }, [lifecycleIntentIsLive, projectContextLifecycleController, store]);
  drawerDismissHandoff.current = handleDrawerDismiss;

  // The Drawer is admitted with rootSurfaceAdmissionAllowed(true), so it opens
  // while a settled recovery waits. Its actions ask the strict guard, which
  // refuses exactly that state. Rather than each one doing nothing and saying
  // nothing, they take the person to the recovery the Drawer was opened over.
  const routeDrawerActionToRecovery = useCallback(
    (expectedDrawerEpoch: number) => {
      if (!destructiveAuthorityActive() || destructiveAuthorityActive(true))
        return false;
      openPendingLifecycleFromDrawer(
        lifecycleIntent,
        lifecycleToken,
        directProjectMutationView,
        expectedDrawerEpoch,
      );
      return true;
    },
    [
      destructiveAuthorityActive,
      directProjectMutationView,
      lifecycleIntent,
      lifecycleToken,
      openPendingLifecycleFromDrawer,
    ],
  );
  drawerRecoveryRouter.current = routeDrawerActionToRecovery;

  const handleActionDismiss = useCallback(() => {
    const open = afterActionDismiss.current;
    afterActionDismiss.current = null;
    if (
      !lifecycleBootstrapReadyRef.current ||
      contextSheetVisibleRef.current ||
      lifecycleIntentRef.current !== null ||
      directProjectMutationOutboxRef.current !== null ||
      store.getState().projectContextDestructiveTransition !== null
    ) {
      return;
    }
    open?.();
  }, [store]);

  const openRuntimeFromDrawer = useCallback((expectedEpoch: number) => {
    openAfterDrawerDismiss(expectedEpoch, () => setEvidenceVisible(true));
  }, [openAfterDrawerDismiss]);

  const openConversationActions = useCallback(
    (id: string, expectedEpoch: number) => {
      openAfterDrawerDismiss(expectedEpoch, () => {
        conversationActionEpoch.current += 1;
        setActionConversationId(id);
      });
    },
    [openAfterDrawerDismiss],
  );

  const actionConversation =
    actionConversationId === null
      ? null
      : selectConversationById(chatState, actionConversationId);
  const navigationSurfaceVisible =
    drawerVisible ||
    actionConversation !== null ||
    settingsVisible ||
    accountVisible ||
    mirrorsVisible ||
    environmentsVisible ||
    programVisible ||
    modelVisible ||
    composerOptionsVisible ||
    workspaceSheetVisible ||
    harnessesVisible ||
    evidenceVisible ||
    projectsVisible ||
    workspaceVisible ||
    contextSheetVisible;
  navigationSurfaceVisibleRef.current = navigationSurfaceVisible;

  useTaskActions(
    navigationSurfaceVisible || contextSheetVisible ? null : chatState.selectedConversationId,
    openSystemTask,
    runId => cancelTaskExperienceRun(completionController, runId),
    lifecycleBootstrapReady && !navigationSurfaceVisible && !contextSheetVisible,
    locale,
  );

  return (
    <KeyboardAvoidingView
      behavior={Platform.OS === 'ios' ? 'padding' : undefined}
      style={styles.root}
    >
      <View
        accessibilityElementsHidden={navigationSurfaceVisible}
        importantForAccessibility={
          navigationSurfaceVisible ? 'no-hide-descendants' : 'auto'
        }
        style={[styles.screen, wideLayout && styles.screenWide, { paddingTop: insets.top }]}
      >
        <View
          style={[styles.contentContainer, wideLayout && styles.wideContent]}
        >
        <View style={styles.topBar}>
          <RoundButton
            accessibilityLabel={t('home.openNavigation')}
            testID="home-open-navigation"
            onPress={() => {
              if (!rootSurfaceAdmissionAllowed(true)) return;
              drawerSurfaceEpoch.current += 1;
              drawerVisibleRef.current = true;
              setDrawerVisible(true);
            }}
          >
            <AppIcon color={colors.text} icon={Menu} size={20} />
          </RoundButton>
          <View style={styles.titleWrap}>
            <BrandMark compact size={30} />
            {activeConversation !== null &&
              activeConversation.messages.length > 0 && (
                <Text numberOfLines={1} style={styles.chatTitle}>
                  {activeConversation.title}
                </Text>
              )}
          </View>
          {runtimeStatus === 'verified' ? (
            <View style={styles.topBarSpacer} />
          ) : (
            <RoundButton
              accessibilityLabel={t('home.showRuntimeEvidence')}
              onPress={() => {
                if (!rootSurfaceAdmissionAllowed()) return;
                setEvidenceVisible(true);
              }}
            >
              <View style={styles.runtimeGlyph}>
                <View
                  style={[
                    styles.runtimeDot,
                    runtimeStatus === 'failed' && styles.runtimeDotFailed,
                  ]}
                />
                {runtimeStatus === 'checking' ? (
                  <SpinningIcon color={colors.warning} icon={LoaderCircle} size={18} />
                ) : (
                  <AppIcon
                    color={
                      runtimeStatus === 'failed' ? colors.danger : colors.warning
                    }
                    icon={runtimeStatus === 'failed' ? CircleAlert : CircleEllipsis}
                    size={18}
                  />
                )}
              </View>
            </RoundButton>
          )}
        </View>

        {activeMessages.length === 0 ? (
          // The welcome hero is taller than the space left once the keyboard
          // is up; let it scroll instead of overlapping the composer.
          <ScrollView
            contentContainerStyle={styles.emptyChatContent}
            keyboardDismissMode="on-drag"
            keyboardShouldPersistTaps="handled"
            showsVerticalScrollIndicator={false}
            style={styles.emptyChatScroll}
          >
            <EmptyChat onSuggestion={changeDraft} />
          </ScrollView>
        ) : (
          <MessageList
            key={activeConversation?.id ?? 'no-conversation'}
            autoExpandTools={preferences.autoExpandTools}
            messages={activeMessages}
            onPreviewAttachment={id => {
              presentAttachmentPreview(id, attachmentOwnershipKey).catch(
                () => undefined,
              );
            }}
            previewingAttachmentId={previewingAttachmentId}
            showReasoning={preferences.showReasoning}
          />
        )}

        <View
          style={[
            styles.bottomArea,
            // Android draws edge to edge since RN 0.87, so the window no
            // longer shrinks for the keyboard and the composer was simply
            // covered by it. The height the keyboard reports is measured
            // from the top of the navigation bar, so the bottom inset is
            // still needed underneath it. iOS reports zero here and keeps
            // the screen's KeyboardAvoidingView.
            { paddingBottom: Math.max(insets.bottom, 11) + keyboardHeight },
          ]}
        >
          {(visibleRequestFailure !== null || storageWarning !== null) && (
            <View style={styles.notice}>
              <RecoveryNotice
                error={completionState.conversationId === activeConversation?.id &&
                  visibleRequestFailure === completionState.failureCode &&
                  completionState.failureDiagnostic !== undefined
                  ? `${visibleRequestFailure}\n${completionState.failureDiagnostic}`
                  : visibleRequestFailure ?? storageWarning ?? ''}
                message={recoveryCode(visibleRequestFailure ?? storageWarning ?? '') === null
                  ? visibleRequestFailure ?? storageWarning ?? undefined : undefined}
              />
              {sessionLoadFailure !== null && (
                <Pressable
                  accessibilityRole="button"
                  accessibilityLabel={t('recovery.retryLoad')}
                  disabled={runtimeChecking || credentialBusy}
                  onPress={() => retrySessionLoad().catch(() => undefined)}
                  style={({ pressed }) => [styles.retry, pressed && styles.pressed]}
                  testID="retry-session-load"
                >
                  <Text style={styles.retryText}>{t('recovery.retryLoad')}</Text>
                </Pressable>
              )}
              {completionActionVisible && visibleRequestFailure !== null && (
                <Pressable
                  accessibilityLabel={completionRecoveryLabel(completionState.phase, t)}
                  accessibilityRole="button"
                  accessibilityState={{
                    disabled:
                      attachmentBusy || previewingAttachmentId !== null,
                  }}
                  disabled={attachmentBusy || previewingAttachmentId !== null}
                  hitSlop={hitSlop}
                  onPress={() =>
                    retry(completionState).catch(() => undefined)
                  }
                  style={({ pressed }) => [
                    styles.retry,
                    pressed && styles.pressed,
                  ]}
                >
                  <Text style={styles.retryText}>{completionRecoveryLabel(completionState.phase, t)}</Text>
                </Pressable>
              )}
              {completionAgentUnresolved && visibleRequestFailure !== null && (
                <Pressable
                  accessibilityLabel={t('recovery.abandonAndRetry')}
                  accessibilityRole="button"
                  accessibilityState={{
                    disabled:
                      attachmentBusy || previewingAttachmentId !== null,
                  }}
                  disabled={attachmentBusy || previewingAttachmentId !== null}
                  hitSlop={hitSlop}
                  onPress={() =>
                    abandonAndRetry(completionState).catch(() => undefined)
                  }
                  style={({ pressed }) => [
                    styles.retry,
                    pressed && styles.pressed,
                  ]}
                >
                  <Text style={styles.retryText}>{t('recovery.abandonAndRetry')}</Text>
                </Pressable>
              )}
              {workspaceBindingRecoveryVisible && (
                <Pressable
                  accessibilityLabel={t('recovery.retryBinding')}
                  accessibilityRole="button"
                  disabled={attachmentBusy || previewingAttachmentId !== null}
                  onPress={retryWorkspaceBinding}
                  style={({ pressed }) => [
                    styles.retry,
                    pressed && styles.pressed,
                  ]}
                >
                  <Text style={styles.retryText}>{t('recovery.retryBinding')}</Text>
                </Pressable>
              )}
            </View>
          )}
          {attachmentNotice !== null && visibleRequestFailure === null && (
            <View
              accessibilityLiveRegion="polite"
              accessibilityRole={Platform.OS === 'android' ? 'text' : 'status'}
              style={styles.attachmentNotice}
            >
              <Text numberOfLines={2} style={styles.attachmentNoticeText}>
                {attachmentNotice}
              </Text>
            </View>
          )}
          {workspaceHintConversationId !== null &&
            workspaceHintConversationId === activeConversation?.id &&
            activeWorkspaceId === null &&
            visibleRequestFailure === null && (
            <View
              accessibilityLiveRegion="polite"
              accessibilityRole={Platform.OS === 'android' ? 'text' : 'status'}
              style={styles.workspaceHint}
              testID="workspace-unbound-hint"
            >
              <Text numberOfLines={3} style={styles.workspaceHintText}>
                {t('messages.workspaceUnboundNotice')}
              </Text>
              <Pressable
                accessibilityLabel={t('messages.chooseWorkspace')}
                accessibilityRole="button"
                onPress={() => {
                  openWorkspacePicker();
                }}
                style={({ pressed }) => [styles.workspaceHintAction, pressed && styles.pressed]}
                testID="workspace-unbound-hint-action"
              >
                <Text style={styles.workspaceHintActionText}>
                  {t('messages.chooseWorkspace')}
                </Text>
              </Pressable>
            </View>
          )}
          <View style={styles.proofRow}>
          <Pressable
            accessibilityLabel={runtimeLabel}
            accessibilityRole="button"
            accessibilityState={{ busy: runtimeStatus === 'checking' }}
            hitSlop={hitSlop}
            onPress={() => {
              if (!rootSurfaceAdmissionAllowed()) return;
              setEvidenceVisible(true);
            }}
            style={({ pressed }) => [
              styles.proofChip,
              pressed && styles.pressed,
            ]}
          >
            <View
              style={[
                styles.proofDot,
                runtimeStatus === 'verified' && styles.proofDotReady,
                runtimeStatus === 'failed' && styles.proofDotFailed,
              ]}
            />
            <Text style={styles.proofText}>
              {runtimeLabel.toLocaleUpperCase()}
            </Text>
          </Pressable>
          {activeWorkspaceId !== null && (
            <Pressable
              accessibilityLabel={t('agent.policy.title')}
              accessibilityRole="button"
              hitSlop={hitSlop}
              onPress={() => {
                if (!rootSurfaceAdmissionAllowed()) return;
                setAgentPolicyRevokeFailed(null);
                setAgentPolicyVisible(true);
              }}
              style={({ pressed }) => [
                styles.proofChip,
                pressed && styles.pressed,
              ]}
              testID="agent-policy-chip"
            >
              <View
                style={[
                  styles.proofDot,
                  styles.agentPolicyDot,
                ]}
              />
              <Text style={styles.proofText}>
                {t('agent.policy.title').toLocaleUpperCase()}
              </Text>
            </Pressable>
          )}
          </View>
          {activeConversation?.projectContext !== null &&
            activeConversation?.projectContext !== undefined &&
            activeConversation.projectId !== null && (
              <View
                collapsable={false}
                onLayout={event => {
                  if (typeof event.target === 'number') {
                    projectContextStripTarget.current = event.target;
                  }
                }}
                testID="project-context-strip-focus-target"
              >
                <ProjectContextStrip
                  ref={projectContextStripRef}
                  projectName={
                    activeProjectName ??
                    activeConversation.projectContext.snapshot?.project_name ??
                    activeConversation.projectId
                  }
                  state={activeConversation.projectContext}
                  verificationStatus={projectContextVerificationStatus}
                  onPress={openProjectContextFromStrip}
                />
              </View>
            )}
          <ChatComposer
            attachmentBusy={attachmentBusy}
            attachments={draftAttachments}
            configured={credentialConfigured}
            draft={draft}
            harnessName={activeHarness.name}
            providerName={providerName}
            configurationHint={sessionLoadFailure !== null ? t('recovery.loadRequired') : claudeSourceChecking ? t('settings.auth.checkingClaude') : configurationPending ? t('messages.preparingConnection', { harness: activeHarness.name }) : subscriptionNeedsAttention ? t(glmSubscriptionState === 'signed_in' ? 'messages.subscriptionUnverified' : 'messages.subscriptionLoginRequired') : undefined}
            configurationPending={sessionLoadFailure !== null ? runtimeChecking : configurationPending}
            textOnly={claudeSubscriptionSelected}
            configurationAction={sessionLoadFailure !== null ? t('recovery.retryLoad') : subscriptionNeedsAttention ? t('messages.manageSubscription') : undefined}
            model={activeModel}
            modelLabel={providerOverride?.harness_id === activeHarnessId ? providerOverride.model_mappings[activeModel] : undefined}
            locked={
              codexModelsLoading ||
              requestState === 'sending' ||
              previewingAttachmentId !== null ||
              projectContextLocksComposer
            }
            ownershipKey={attachmentOwnershipKey}
            optionsVisible={composerOptionsVisible}
            previewingAttachmentId={previewingAttachmentId}
            thinkingMode={activeThinkingMode}
            workspaceName={
              activeWorkspaceId === null
                ? null
                : workspaceNames[activeWorkspaceId] ?? null
            }
            workspacePickerVisible={workspaceSheetVisible}
            cancelling={completionState.phase === 'cancelling'}
            sending={completionCancellable(completionState)}
            onAddAttachment={(source, ownershipKey) => {
              addAttachment(source, ownershipKey).catch(() => undefined);
            }}
            onCancel={() => cancel(completionState)}
            onChange={changeDraft}
            onLogin={sessionLoadFailure !== null || activeHarnessId === 'dsh' ? undefined : () => {
              if (!rootSurfaceAdmissionAllowed() || credentialBusy) return;
              presentSettingsSurface();
              setSettingsAuthOnly(true);
            }}
            onConfigure={() => {
              if (sessionLoadFailure !== null) {
                retrySessionLoad().catch(() => undefined);
                return;
              }
              if (!rootSurfaceAdmissionAllowed() || credentialBusy) return;
              if (!nativeAvailable || subscriptionNeedsAttention) {
                openSettings();
                return;
              }
              configureCredential().catch(() => undefined);
            }}
            onOptionsPress={openComposerOptions}
            onWorkspacePress={() => {
              openWorkspacePicker();
            }}
            onPreviewAttachment={(id, ownershipKey) => {
              presentAttachmentPreview(id, ownershipKey).catch(
                () => undefined,
              );
            }}
            onRemoveAttachment={removeDraftAttachment}
            onSend={() => send().catch(() => undefined)}
          />
        </View>
        </View>
      </View>

      <ChatDrawer
        activeId={chatState.selectedConversationId}
        conversations={conversationSummaries}
        covered={settingsVisible || accountVisible || mirrorsVisible}
        pendingProjectCleanup={
          lifecycleSheetActive &&
          (lifecycleTargetId !== chatState.selectedConversationId ||
            (directProjectMutationView !== null &&
              activeConversation?.projectId === null))
        }
        runtimeLabel={runtimeLabel}
        runtimeStatus={runtimeStatus}
        visible={drawerVisible}
        docked={wideLayout}
        onClose={closeDrawerSurface}
        onDismiss={handleDrawerDismiss}
        onNewChat={() => createConversation(drawerRenderEpoch)}
        onOpenAccount={() => {
          if (!drawerSourceIsLive(drawerRenderEpoch, true)) return;
          if (routeDrawerActionToRecovery(drawerRenderEpoch)) return;
          setAccountVisible(true);
        }}
        onOpenConversationMenu={id =>
          openConversationActions(id, drawerRenderEpoch)
        }
        onOpenFiles={() => {
          const expectedConversation = selectActiveConversation(store.getState());
          openAfterDrawerDismiss(drawerRenderEpoch, () => {
            openFilesForConversation(expectedConversation).catch(error =>
              setRequestFailure(errorText(error)),
            );
          });
        }}
        onOpenProjects={() =>
          openAfterDrawerDismiss(drawerRenderEpoch, () => {
            projectsSurfaceEpoch.current += 1;
            projectsVisibleRef.current = true;
            setProjectsVisible(true);
          })
        }
        onOpenPendingProjectCleanup={() =>
          openPendingLifecycleFromDrawer(
            lifecycleIntent,
            lifecycleToken,
            directProjectMutationView,
            drawerRenderEpoch,
          )
        }
        onOpenHarnesses={() =>
          openAfterDrawerDismiss(drawerRenderEpoch, () =>
            setHarnessesVisible(true),
          )
        }
        onOpenRuntime={() => openRuntimeFromDrawer(drawerRenderEpoch)}
        onOpenSettings={() => openSettingsFromDrawer(drawerRenderEpoch)}
        onSelect={id => selectConversation(id, drawerRenderEpoch)}
      />
      {agentInteractionState.pendingApprovals.length > 0 && (
        <ApprovalComposer
          requests={agentInteractionState.pendingApprovals}
          onDecide={decisions => {
            if (decisions.length === 1) {
              agentInteractions.decideApproval(
                decisions[0].approvalId,
                decisions[0].decision,
              );
            } else {
              agentInteractions.decideBatchApprovals(
                decisions.map(entry => ({
                  approvalId: entry.approvalId,
                  decision: entry.decision,
                })),
              );
            }
          }}
        />
      )}
      {agentInteractionState.pendingQuestion !== null && (
        <QuestionComposer
          question={agentInteractionState.pendingQuestion}
          onAnswer={(questionId, answer) =>
            agentInteractions.answerQuestion(questionId, answer)
          }
          onCancel={questionId =>
            agentInteractions.cancelQuestion(questionId)
          }
        />
      )}
      <AgentPolicySheet
        visible={agentPolicyVisible}
        workspaceName={
          activeWorkspaceId === null
            ? null
            : workspaceNames[activeWorkspaceId] ?? null
        }
        capabilities={agentPolicy.capabilities}
        toolAccess={agentPolicy.toolAccess}
        policyStatus={agentPolicy.status}
        onRetryPolicy={nativeAgentPolicy.retry}
        gitProjectRequired={agentPolicy.gitProjectRequired}
        gitActivationAvailable={workspaceGitActivationAvailable}
        gitActivationBlocked={workspaceGitActivationBlocked}
        gitActivationBusy={workspaceGitActivationBusy}
        gitActivationError={workspaceGitActivationError}
        onEnableWorkspaceGit={enableWorkspaceGit}
        budget={agentPolicy.budget}
        grants={agentPolicy.grants}
        revokeBusy={agentPolicyRevokeBusy}
        revokeFailed={agentPolicyRevokeFailed}
        onClose={() => setAgentPolicyVisible(false)}
        onRevoke={revokeAgentGrant}
      />
      <ConversationActionSheet
        title={actionConversation?.title ?? ''}
        visible={actionConversation !== null}
        onClose={() => {
          conversationActionEpoch.current += 1;
          setActionConversationId(null);
        }}
        onDelete={requestDeleteConversation}
        onDismiss={handleActionDismiss}
        onRename={renameConversation}
      />
      <SettingsSheet
        authOnly={settingsAuthOnly}
        taskConversationId={chatState.selectedConversationId}
        busy={credentialBusy}
        harnessName={activeHarness.name}
        providerName={providerName}
        covered={mirrorsVisible || modelVisible || environmentsVisible || programVisible}
        credentialConfigured={credentialConfigured}
        model={activeModel}
        runtimeAvailable={nativeAvailable}
        runtimeLabel={runtimeLabel}
        runtimeStatus={runtimeStatus}
        visible={settingsVisible}
        onClearCredential={() => {
          if (!settingsSourceIsLive(settingsRenderEpoch)) return;
          clearCredential();
        }}
        onClose={closeSettingsSurface}
        onDismiss={() => undefined}
        onConfigureCredential={() => {
          if (!settingsSourceIsLive(settingsRenderEpoch)) return;
          configureCredential().catch(() => undefined);
        }}
        onOpenModelPicker={() => {
          if (!settingsSourceIsLive(settingsRenderEpoch)) return;
          setModelVisible(true);
        }}
        onOpenMirrors={() => {
          if (!settingsSourceIsLive(settingsRenderEpoch)) return;
          setMirrorsVisible(true);
        }}
        onOpenEnvironments={() => {
          if (!settingsSourceIsLive(settingsRenderEpoch)) return;
          setEnvironmentsVisible(true);
        }}
        onOpenRuntime={() => {
          if (!settingsSourceIsLive(settingsRenderEpoch)) return;
          setEvidenceVisible(true);
        }}
        onProviderConfigurationChanged={harness => {
          for (const conversation of Object.values(store.getState().conversations)) {
            if (harnessForModel(conversation.modelId) === harness && conversation.projectContext !== null) {
              store.applyProjectContextAction(conversation.id, { type: 'provider_configuration_changed' });
            }
          }
          setProviderConfigurationRevision(value => value + 1);
          persist().catch(() => undefined);
        }}
        onPreferencesChanged={() => {
          if (!settingsSourceIsLive(settingsRenderEpoch)) return;
          persist().catch(() => undefined);
        }}
      />
      <AccountSheet
        visible={accountVisible}
        onClose={() => setAccountVisible(false)}
      />
      <ModelPicker
        disabled={
          requestState === 'sending' ||
          attachmentBusy ||
          projectContextLocksComposer
        }
        models={activeModels}
        placement="settings"
        selected={activeModel}
        visible={modelVisible}
        onClose={() => setModelVisible(false)}
        onSelect={selectSettingsModel}
      />
      <ConversationOptionsPicker
        disabled={
          requestState === 'sending' ||
          attachmentBusy ||
          projectContextLocksComposer
        }
        models={activeModels}
        model={activeModel}
        thinkingMode={activeThinkingMode}
        visible={composerOptionsVisible}
        onClose={() => setComposerOptionsVisible(false)}
        onSelectModel={selectComposerModel}
        onSelectThinkingMode={selectThinkingMode}
      />
      <WorkspacePickerSheet
        activeWorkspaceId={activeWorkspaceId}
        visible={workspaceSheetVisible}
        onClose={closeWorkspacePicker}
        onSelect={workspacePickerOnSelect}
        onRemove={workspaceRemovalAvailable ? removeWorkspace : undefined}
      />
      <MirrorSettingsSheet
        visible={mirrorsVisible}
        onClose={() => setMirrorsVisible(false)}
        onDismiss={() => undefined}
        onPreferencesChanged={() => {
          persist().catch(() => undefined);
        }}
      />
      <RuntimeEnvironmentSheet
        visible={environmentsVisible}
        workspaceId={activeWorkspaceId}
        onClose={() => setEnvironmentsVisible(false)}
        onDismiss={() => finishProgramSurfaceTransition('environments')}
        onRun={activeConversation?.workspaceBinding == null || workspaceGitActivationBlocked ? undefined : () => {
          const conversation = selectActiveConversation(store.getState());
          const binding = conversation?.workspaceBinding;
          if (conversation === null || binding == null || workspaceGitActivationBlocked) return;
          pendingProgramOpenRef.current = { source: 'environments', selectedConversationId: conversation.id, context: {
            root: {
              schema_version: 1,
              workspace_id: binding.workspaceId,
              binding_revision: binding.bindingRevision,
              project_id: binding.projectId,
            },
            label: workspaceNames[binding.workspaceId] ?? '',
            conversationId: conversation.id,
          }};
          setEnvironmentsVisible(false);
        }}
      />
      <RuntimeProgramSheet
        visible={programVisible}
        ownerKey={activeConversation?.id ?? 'no-conversation'}
        root={programContext?.root ?? null}
        workspaceName={programContext?.label}
        blocked={workspaceGitActivationBlocked}
        onClose={() => {
          setProgramVisible(false);
          setProgramContext(null);
        }}
      />
      <HarnessPicker
        disabled={
          requestState === 'sending' ||
          attachmentBusy ||
          previewingAttachmentId !== null ||
          projectContextLocksComposer ||
          credentialBusy
        }
        manifests={BUILTIN_HARNESSES.list()}
        selectedId={activeHarness.id}
        visible={harnessesVisible}
        onClose={() => setHarnessesVisible(false)}
        onSelect={selectHarness}
      />
      <RuntimeEvidenceSheet
        failure={runtimeFailure}
        proof={proof}
        runtimeLabel={runtimeLabel}
        runtimeStatus={runtimeStatus}
        shell={shell}
        visible={evidenceVisible}
        onClose={() => setEvidenceVisible(false)}
        onRetry={() => refreshProof().catch(() => undefined)}
      />
      <ProjectsSurface
        boundProjectId={activeConversation?.projectId ?? null}
        covered={workspaceVisible}
        refreshToken={projectRefreshToken}
        visible={projectsVisible}
        onChatInProject={chatInProject}
        onClose={() => {
          projectsSurfaceEpoch.current += 1;
          projectContextUiEpoch.current += 1;
          projectsVisibleRef.current = false;
          pendingContextOpenAfterProjectsDismiss.current = null;
          pendingContextAttachAfterOpen.current = null;
          pendingExistingLifecycleAfterProjectsDismiss.current = null;
          pendingLifecycleOpenAfterProjectsDismiss.current = null;
          pendingDirectOpenAfterProjectsDismiss.current = null;
          setProjectsVisible(false);
        }}
        onDismiss={handleProjectsDismiss}
        onOpenFiles={async (project, isCurrent = () => true) => {
          if (
            !projectsVisibleRef.current ||
            !isCurrent() ||
            destructiveSurfaceBlocked()
          )
            return;
          const expectedProjectsEpoch = projectsSurfaceEpoch.current;
          const nonce = ++workspaceSurfaceNonceRef.current;
          const canOpen = () =>
            projectsVisibleRef.current &&
            isCurrent() &&
            projectsSurfaceEpoch.current === expectedProjectsEpoch &&
            workspaceSurfaceNonceRef.current === nonce &&
            !destructiveSurfaceBlocked();
          const current = selectActiveConversation(store.getState());
          const binding = current?.workspaceBinding ?? null;
          if (
            current !== null &&
            current.projectId === project.id &&
            binding !== null
          ) {
            const root = assertWorkspaceRootRefV1({
              schema_version: 1,
              workspace_id: binding.workspaceId,
              binding_revision: binding.bindingRevision,
              project_id: binding.projectId,
            });
            if (!canOpen()) return;
            setProjectFilesScope(project);
            workspaceVisibleRef.current = true;
            setWorkspaceRoute({
              root,
              label: project.name,
              conversationId: current.id,
              projectId: project.id,
            });
            setWorkspaceVisible(true);
            return;
          }
          const root = await resolveProjectWorkspaceRoot(project.id);
          if (!canOpen()) return;
          if (root === null) throw new Error('E_WORKSPACE_ROOT_CHANGED');
          setProjectFilesScope(project);
          workspaceVisibleRef.current = true;
          setWorkspaceRoute({
            root,
            label: project.name,
            conversationId: null,
            projectId: project.id,
          });
          setWorkspaceVisible(true);
        }}
        onUnbindFromChat={() =>
          unbindProjectFromConversation(projectsRenderEpoch)
        }
      />
      <ProjectContextSheet
        actionKey={projectContextActionKey}
        busyAction={projectContextBusyAction}
        candidates={
          projectContextOwnerAligned
            ? projectContextControllerState.list.candidates
            : []
        }
        checking={projectContextVerificationStatus === 'checking'}
        confirmationRequired={projectContextConfirmationRequired}
        disabled={
          projectContextSheetMode === 'lifecycle'
            ? lifecycleActionInFlight.current
            : projectContextSheetMode === 'recovery'
            ? projectContextRecoveryGloballyDisabled
            : projectContextActionsDisabled
        }
        errorCode={
          projectContextOwnerAligned
            ? projectContextControllerState.failureCode
            : null
        }
        filter={contextSheetFilter}
        hasActiveContext={
          !projectContextConfirmationRequired &&
          activeConversation?.projectContext?.snapshot !== null &&
          activeConversation?.projectContext?.snapshot !== undefined
        }
        loading={
          projectContextOwnerAligned && projectContextControllerState.list.loading
        }
        loadingMore={
          projectContextOwnerAligned &&
          projectContextControllerState.list.loadingMore
        }
        lifecycle={lifecyclePresentation}
        manifest={projectContextManifest}
        mode={projectContextSheetMode}
        nextCursor={
          projectContextOwnerAligned
            ? projectContextControllerState.list.nextCursor
            : null
        }
        projectName={
          lifecycleSheetActive
            ? lifecycleTargetConversation?.projectContext?.snapshot
                ?.project_name ??
              t('context.sheet.lifecycle.localProject')
            : activeProjectName ??
              activeConversation?.projectContext?.snapshot?.project_name ??
              activeConversation?.projectId ??
          ''
        }
        query={
          projectContextOwnerAligned
            ? projectContextControllerState.list.query
            : ''
        }
        recoveryAction={projectContextRecoveryAction}
        recoveryRefreshDisabled={projectContextRecoveryRefreshDisabled}
        recoverySendWithoutDisabled={projectContextRecoveryGloballyDisabled}
        selectedCandidates={
          projectContextOwnerAligned
            ? projectContextControllerState.selectedCandidates
            : []
        }
        selectedPaths={
          projectContextOwnerAligned
            ? projectContextControllerState.selectedPaths
            : []
        }
        unavailable={
          !projectContextNativeAvailable ||
          activeConversation?.projectContext?.status === 'unavailable'
        }
        visible={contextSheetVisible}
        onCancelCandidate={() => {
          const token = projectContextActionToken;
          if (token === null) return;
          completeProjectContextAction(
            token,
            true,
            () => projectContextController.cancel(token),
          );
        }}
        onCancelRecovery={() => {
          const expected = pendingProjectSend;
          if (
            !pendingProjectSurfaceIsLive(expected) ||
            pendingProjectActionIsBlocked(expected)
          ) {
            return;
          }
          invalidatePendingProjectSend();
          closeProjectContextSheet();
        }}
        onClose={() => {
          if (projectContextUiEpoch.current !== projectContextRenderEpoch) return;
          closeProjectContextSheet();
        }}
        onConfirm={() => {
          const token = projectContextActionToken;
          if (token === null) return;
          if (
            pendingProjectSend !== null &&
            pendingProjectSendStage === 'context_flow'
          ) {
            completePendingProjectContextAction(
              pendingProjectSend,
              token,
              true,
              () => projectContextController.confirm(token),
            );
            return;
          }
          completeProjectContextAction(
            token,
            true,
            () => projectContextController.confirm(token),
          );
        }}
        onConfirmLifecycle={() => {
          confirmLifecycleIntent(
            lifecycleIntent,
            projectContextRenderEpoch,
          ).catch(() => undefined);
        }}
        onDisable={() => {
          const token = projectContextActionToken;
          if (token === null) return;
          completeProjectContextAction(
            token,
            true,
            () => projectContextController.disable(token),
          );
        }}
        onDismiss={handleProjectContextDismiss}
        onFilterChange={filter => {
          if (!projectContextActionIsLive(projectContextActionToken)) return;
          setContextSheetFilter(filter);
        }}
        onLoadMore={() => {
          const token = projectContextActionToken;
          if (!projectContextActionIsLive(token)) return;
          projectContextController.loadMore(token).catch(() => undefined);
        }}
        onPrepare={() => {
          const token = projectContextActionToken;
          if (token === null) return;
          if (
            pendingProjectSend !== null &&
            pendingProjectSendStage === 'context_flow'
          ) {
            completePendingProjectContextAction(
              pendingProjectSend,
              token,
              false,
              () => projectContextController.prepare(token),
            );
            return;
          }
          completeProjectContextAction(
            token,
            false,
            () => projectContextController.prepare(token),
          );
        }}
        onQueryChange={query => {
          const token = projectContextActionToken;
          if (!projectContextActionIsLive(token)) return;
          projectContextController.search(token, query).catch(() => undefined);
        }}
        onRefreshAndSend={() =>
          refreshPendingProjectContext(
            pendingProjectSend,
            projectContextActionToken,
          )
        }
        onRefreshCandidates={() => {
          const token = projectContextActionToken;
          if (!projectContextActionIsLive(token)) return;
          projectContextController
            .search(token, projectContextControllerState.list.query)
            .catch(() => undefined);
        }}
        onRefreshContext={() => {
          const token = projectContextActionToken;
          if (token === null) return;
          completeProjectContextAction(
            token,
            false,
            () => projectContextController.inspect(token),
          );
        }}
        onRetryCleanup={() => {
          const token = projectContextActionToken;
          if (token === null) return;
          completeProjectContextAction(
            token,
            false,
            () => projectContextController.retryCleanup(token),
          );
        }}
        onRetryLifecycleCleanup={token => {
          retryLifecycleCleanup(token, projectContextRenderEpoch).catch(
            () => undefined,
          );
        }}
        onRetryLifecyclePersistence={token => {
          retryLifecyclePersistence(token, projectContextRenderEpoch).catch(
            () => undefined,
          );
        }}
        onRetryDirectPersistence={() => {
          retryDirectProjectMutationPersistence(
            directProjectMutationView,
            projectContextRenderEpoch,
          ).catch(() => undefined);
        }}
        onRetryPersistence={() => {
          const token = projectContextActionToken;
          if (token === null) return;
          if (
            pendingProjectSend !== null &&
            pendingProjectSendStage === 'context_flow'
          ) {
            completePendingProjectContextAction(
              pendingProjectSend,
              token,
              projectContextControllerState.pendingPersistence?.kind ===
                'confirmed_consent',
              () => projectContextController.retryPersistence(token),
            );
            return;
          }
          completeProjectContextAction(
            token,
            false,
            () => projectContextController.retryPersistence(token),
          );
        }}
        onSendWithoutContext={() =>
          queuePendingProjectSendAfterDismiss(
            pendingProjectSend,
            'without_context',
          )
        }
        onTogglePath={path => {
          const token = projectContextActionToken;
          if (!projectContextActionIsLive(token)) return;
          const selected = projectContextController.getState().selectedPaths;
          const next = selected.includes(path)
            ? selected.filter(candidate => candidate !== path)
            : [...selected, path];
          projectContextController.setSelectedPaths(token, next);
        }}
      />
      <WorkspaceDrawer
        confirmDestructive={preferences.confirmDestructiveFileActions}
        workspaceLabel={workspaceRoute?.label}
        workspaceRoot={workspaceRoute?.root}
        readOnly={preferences.toolPermission === 'read-only'}
        visible={workspaceVisible}
        runProgramBlocked={workspaceGitActivationBlocked}
        onRunProgram={() => {
          if (workspaceRoute === null || !workspaceVisibleRef.current || workspaceGitActivationBlocked) return;
          pendingProgramOpenRef.current = { source: 'files', selectedConversationId: store.getState().selectedConversationId, context: {
            root: workspaceRoute.root,
            label: workspaceRoute.label,
            conversationId: workspaceRoute.conversationId,
          }};
          workspaceSurfaceNonceRef.current += 1;
          workspaceBindingController.invalidate();
          workspaceVisibleRef.current = false;
          setWorkspaceVisible(false);
          setWorkspaceRoute(null);
        }}
        onDismiss={() => finishProgramSurfaceTransition('files')}
        onClose={() => {
          workspaceSurfaceNonceRef.current += 1;
          workspaceBindingController.invalidate();
          workspaceVisibleRef.current = false;
          setWorkspaceVisible(false);
          setWorkspaceRoute(null);
          if (projectFilesScope !== null)
            setProjectRefreshToken(previous => previous + 1);
        }}
      />
    </KeyboardAvoidingView>
  );
}

function RoundButton({
  accessibilityLabel,
  children,
  onPress,
  testID,
}: React.PropsWithChildren<{
  accessibilityLabel: string;
  onPress: () => void;
  testID?: string;
}>) {
  const { colors } = useAppPresentation();
  const styles = useMemo(() => createStyles(colors), [colors]);
  return (
    <Pressable
      accessibilityLabel={accessibilityLabel}
      accessibilityRole="button"
      hitSlop={hitSlop}
      onPress={onPress}
      style={({ pressed }) => [styles.roundButton, pressed && styles.pressed]}
      testID={testID}
    >
      {children}
    </Pressable>
  );
}

const createStyles = (colors: ThemePalette) =>
  StyleSheet.create({
    agentPanel: {
      marginTop: 6,
      borderRadius: 14,
      backgroundColor: colors.surfaceRaised,
      borderWidth: StyleSheet.hairlineWidth,
      borderColor: colors.line,
      paddingHorizontal: 12,
      paddingVertical: 8,
      gap: 6,
    },
    agentPanelText: { color: colors.text, fontSize: 12, fontWeight: '600' },
    agentButtonsRow: { flexDirection: 'row', gap: 8 },
    agentAllow: {
      borderRadius: 12,
      paddingHorizontal: 14,
      paddingVertical: 6,
      backgroundColor: colors.accent,
    },
    agentDeny: {
      borderRadius: 12,
      paddingHorizontal: 14,
      paddingVertical: 6,
      backgroundColor: colors.surfaceRaised,
      borderWidth: StyleSheet.hairlineWidth,
      borderColor: colors.line,
    },
    agentButtonText: {
      color: colors.background,
      fontSize: 12,
      fontWeight: '700',
    },
    agentButtonTextDim: {
      color: colors.textDim,
      fontSize: 12,
      fontWeight: '700',
    },
    agentTrace: {
      color: colors.muted,
      fontSize: 10,
      fontFamily: fonts.mono,
    },
    root: { flex: 1, backgroundColor: colors.background },
    screen: { flex: 1, backgroundColor: colors.background },
    contentContainer: { flex: 1 },
    screenWide: {
      paddingLeft: WIDE_SIDEBAR_WIDTH,
      paddingRight: 24,
    },
    wideContent: {
      flex: 1,
      width: '100%',
      maxWidth: WIDE_CONTENT_MAX_WIDTH,
      alignSelf: 'center',
    },
    topBar: {
      height: 66,
      paddingHorizontal: 16,
      flexDirection: 'row',
      alignItems: 'center',
      justifyContent: 'space-between',
    },
    titleWrap: { alignItems: 'center', maxWidth: '58%' },
    topBarSpacer: { width: 42, height: 42 },
    chatTitle: {
      color: colors.muted,
      fontFamily: fonts.body,
      fontSize: 9,
      marginTop: 3,
      maxWidth: 210,
    },
    roundButton: {
      width: 42,
      height: 42,
      borderRadius: 21,
      alignItems: 'center',
      justifyContent: 'center',
      backgroundColor: colors.surface,
      borderWidth: StyleSheet.hairlineWidth,
      borderColor: colors.line,
    },
    pressed: { opacity: 0.6, transform: [{ scale: 0.98 }] },
    runtimeGlyph: { alignItems: 'center', justifyContent: 'center' },
    emptyChatScroll: { flex: 1 },
    emptyChatContent: { flexGrow: 1 },
    runtimeDot: {
      position: 'absolute',
      width: 6,
      height: 6,
      borderRadius: 3,
      backgroundColor: colors.warning,
      right: -4,
      top: -3,
    },
    runtimeDotReady: { backgroundColor: colors.success },
    runtimeDotFailed: { backgroundColor: colors.danger },
    bottomArea: { paddingHorizontal: 13, gap: 5 },
    // Both status chips share one row; they used to stack and cost two
    // lines above the composer.
    proofRow: {
      flexDirection: 'row',
      flexWrap: 'wrap',
      justifyContent: 'center',
      columnGap: 16,
    },
    proofChip: {
      alignSelf: 'center',
      minHeight: 24,
      paddingHorizontal: 8,
      flexDirection: 'row',
      alignItems: 'center',
      gap: 7,
    },
    proofDot: {
      width: 6,
      height: 6,
      borderRadius: 3,
      backgroundColor: colors.warning,
    },
    proofDotReady: { backgroundColor: colors.success },
    proofDotFailed: { backgroundColor: colors.danger },
    agentPolicyDot: { backgroundColor: colors.accent },
    proofText: {
      color: colors.muted,
      fontFamily: fonts.mono,
      fontSize: 8,
      fontWeight: '700',
      letterSpacing: 1.1,
    },
    notice: {
      minHeight: 42,
      borderRadius: 13,
      backgroundColor: colors.surfaceWarm,
      borderWidth: StyleSheet.hairlineWidth,
      borderColor: colors.danger,
      paddingHorizontal: 12,
      paddingVertical: 9,
      alignItems: 'stretch',
      gap: 8,
    },
    noticeText: { flex: 1, color: colors.danger, fontSize: 11, lineHeight: 15 },
    attachmentNotice: {
      minHeight: 34,
      borderRadius: 12,
      backgroundColor: colors.surfaceWarm,
      borderWidth: StyleSheet.hairlineWidth,
      borderColor: colors.accent,
      paddingHorizontal: 11,
      paddingVertical: 8,
      justifyContent: 'center',
    },
    attachmentNoticeText: {
      color: colors.textDim,
      fontSize: 10,
      lineHeight: 14,
    },
    workspaceHint: {
      minHeight: 34,
      borderRadius: 12,
      backgroundColor: colors.surfaceWarm,
      borderWidth: StyleSheet.hairlineWidth,
      borderColor: colors.accent,
      paddingHorizontal: 11,
      paddingVertical: 6,
      flexDirection: 'row',
      alignItems: 'center',
      gap: 10,
    },
    workspaceHintText: {
      color: colors.textDim,
      fontSize: 10,
      lineHeight: 14,
      flex: 1,
    },
    workspaceHintAction: {
      minHeight: 28,
      borderRadius: 14,
      paddingHorizontal: 11,
      backgroundColor: colors.accent,
      justifyContent: 'center',
    },
    workspaceHintActionText: {
      color: colors.background,
      fontSize: 10,
      fontWeight: '700',
    },
    retry: {
      height: 28,
      borderRadius: 14,
      backgroundColor: colors.text,
      paddingHorizontal: 11,
      alignItems: 'center',
      justifyContent: 'center',
      marginLeft: 9,
    },
    retryText: { color: colors.background, fontSize: 10, fontWeight: '800' },
  });
