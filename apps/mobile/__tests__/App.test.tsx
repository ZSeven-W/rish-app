/**
 * @format
 */

import React from 'react';
import { AccessibilityInfo, Alert, AppState, Dimensions, Keyboard, StyleSheet, Text, type AppStateStatus } from 'react-native';
import ReactTestRenderer, {
  act,
  type ReactTestInstance,
  type ReactTestRenderer as Renderer,
} from 'react-test-renderer';

import App from '../App';
import * as HarnessAuth from '../src/harnessAuth/native';
import * as GlmAccount from '../src/harnessAuth/glmAccount';
import { ProviderConfigurations } from '../src/providers/native';
import { AppPresentationProvider } from '../src/presentation/AppPresentation';
import { AccountSheet } from '../src/components/AccountSheet';
import { AgentPolicySheet } from '../src/components/AgentPolicySheet';
import { ChatDrawer } from '../src/components/ChatDrawer';
import { ChatComposer } from '../src/components/ChatComposer';
import { ConversationActionSheet } from '../src/components/ConversationActionSheet';
import { EmptyChat } from '../src/components/EmptyChat';
import { ProjectContextSheet } from '../src/components/ProjectContextSheet';
import { ProjectContextStrip } from '../src/components/ProjectContextStrip';
import { ProjectsSurface } from '../src/components/ProjectsSurface';
import { SettingsSheet } from '../src/components/SettingsSheet';
import { WorkspacePickerSheet } from '../src/components/WorkspacePickerSheet';
import { ModelPicker } from '../src/components/ModelPicker';
import { MirrorSettingsSheet } from '../src/components/MirrorSettingsSheet';
import { ConversationOptionsPicker } from '../src/components/ConversationOptionsPicker';
import { HarnessPicker } from '../src/components/HarnessPicker';
import { RuntimeEvidenceSheet } from '../src/components/RuntimeEvidenceSheet';
import { WorkspaceDrawer } from '../src/components/WorkspaceDrawer';
import { RuntimeEnvironmentSheet } from '../src/components/runtime-environment-sheet';
import { RuntimeProgramSheet } from '../src/components/runtime-program-sheet';
import { ApprovalComposer } from '../src/components/ApprovalComposer';
import {
  createChatStore,
  safeHydrateChatState,
  type AgentToolReceiptV1,
} from '../src/state';
import { sessionSnapshotSHA256 } from '../src/completion/SessionPersistence';
import { createPreferencesStore } from '../src/preferences';
import type {
  AgentApprovalBindingTokenV2,
  AgentAttemptProjectionV2,
  AgentBatchCallProjectionV2,
  AgentBatchReceiptV2,
  AgentRoundReceiptV2,
  AgentRuntimePolicyV1,
  AgentRuntimeRootV1,
  AgentRuntimeTranscriptHandleV1,
  BindAgentApprovalRequestV2,
  CompleteAgentRoundRequestV2,
  ExecuteAgentToolRequestV2,
  PrepareAgentAttemptRequestV2,
  PrepareAgentToolBatchRequestV2,
} from '../src/native/AgentRuntime';
import type {
  ProjectContextInspectionV1,
  ProjectContextManifestV1,
} from '../src/project-context';

jest.mock('../src/native/LocalRuntime', () => ({
  LocalRuntime: {
    isAvailable: jest.fn(),
    isCompletionV2Available: jest.fn(() => false),
    createCompletionRequestId: jest.fn(),
    bootstrap: jest.fn(),
    credentialStatus: jest.fn(),
    presentCredentialPrompt: jest.fn(),
    clearCredential: jest.fn(),
    credentialStatusForSlot: jest.fn(),
    presentCredentialPromptForSlot: jest.fn(),
    clearCredentialForSlot: jest.fn(),
    isCredentialSlotAvailable: jest.fn(),
    complete: jest.fn(),
    completeV2: jest.fn(),
    recordModelTransition: jest.fn(),
    cancelCompletion: jest.fn(),
  },
}));
jest.mock('../src/native/SessionSnapshots', () => ({
  SessionSnapshots: {
    isAvailable: jest.fn(),
    loadSessionSnapshot: jest.fn(),
    casPersistSession: jest.fn(),
    querySessionCommit: jest.fn(),
  },
}));
jest.mock('../src/native/AgentRuntime', () => ({
  AgentRuntime: {
    isAvailable: jest.fn(),
    prepareAgentAttempt: jest.fn(),
    completeAgentRoundV2: jest.fn(),
    prepareAgentToolBatch: jest.fn(),
    bindAgentApproval: jest.fn(),
    executeAgentTool: jest.fn(),
    cancelAgentAttempt: jest.fn(),
    queryAgentAttempt: jest.fn(),
    queryAgentTool: jest.fn(),
    recoverAgentAttempt: jest.fn(),
    finalizeAgentAttempt: jest.fn(),
    discardAgentAttempt: jest.fn(),
    queryAgentCleanup: jest.fn(),
  },
}));
jest.mock('../src/agent/runAgentTurn', () => ({
  runAgentTurn: jest.fn(),
}));
jest.mock('../src/native/LocalAttachments', () => ({
  LocalAttachments: {
    isAvailable: jest.fn(),
    isModelDeliverySupported: jest.fn(() => true),
    present: jest.fn(),
    discard: jest.fn(),
    prune: jest.fn(),
    preview: jest.fn(),
    presentPreview: jest.fn(),
  },
}));
jest.mock('../src/native/LocalWorkspace', () => ({
  LocalWorkspace: {
    isAvailable: jest.fn(),
    capabilities: jest.fn(),
    listDirectory: jest.fn(),
    readText: jest.fn(),
    writeText: jest.fn(),
    createDirectory: jest.fn(),
    renameEntry: jest.fn(),
    trashEntry: jest.fn(),
    listTrash: jest.fn(),
    restoreFromTrash: jest.fn(),
    executePortableTool: jest.fn(),
    listV2: jest.fn(),
    readV2: jest.fn(),
    writeV2: jest.fn(),
    createDirectoryV2: jest.fn(),
    renameEntryV2: jest.fn(),
    trashEntryV2: jest.fn(),
    listTrashV2: jest.fn(),
    restoreFromTrashV2: jest.fn(),
    executePortableToolV2: jest.fn(),
  },
}));
jest.mock('../src/native/LocalProjects', () => ({
  LocalProjects: {
    isAvailable: jest.fn(),
    isV2Available: jest.fn(),
    list: jest.fn(),
    create: jest.fn(),
    clone: jest.fn(),
    status: jest.fn(),
    diff: jest.fn(),
    stageAll: jest.fn(),
    commit: jest.fn(),
    setRemote: jest.fn(),
    credentialStatus: jest.fn(),
    presentCredentialPrompt: jest.fn(),
    clearCredential: jest.fn(),
    push: jest.fn(),
    attachWorkspaceProject: jest.fn(),
    projectForWorkspaceV2: jest.fn(),
    prepareProjectDetachV1: jest.fn(),
    commitProjectDetachV1: jest.fn(),
    statusV2: jest.fn(),
    diffV2: jest.fn(),
    stageAllV2: jest.fn(),
    commitV2: jest.fn(),
    pushV2: jest.fn(),
  },
}));
jest.mock('../src/native/LocalProjectContext', () => {
  const actual = jest.requireActual('../src/native/LocalProjectContext');
  return {
    ...actual,
    LocalProjectContext: {
      isAvailable: jest.fn(),
      listCandidates: jest.fn(),
      listCandidatesV2: jest.fn(),
      prepare: jest.fn(),
      prepareV2: jest.fn(),
      confirm: jest.fn(),
      confirmV2: jest.fn(),
      inspect: jest.fn(),
      inspectV2: jest.fn(),
      discard: jest.fn(),
      discardV2: jest.fn(),
    },
  };
});
jest.mock('../src/native/LocalMirrors', () => ({
  LocalMirrors: {
    isAvailable: jest.fn(),
    apply: jest.fn(),
    status: jest.fn(),
  },
}));
jest.mock('../src/native/LocalWorkspaces', () => ({
  LocalWorkspaces: {
    isAvailable: jest.fn(),
    isRemovalAvailable: jest.fn(() => false),
    isFolderPickerAvailable: jest.fn(() => true),
    list: jest.fn(),
    create: jest.fn(),
    bootstrapLegacyProject: jest.fn(),
    presentFolderPicker: jest.fn(),
    importSelection: jest.fn(),
    cancelSelection: jest.fn(),
    presentRegrantPicker: jest.fn(),
    completeRegrant: jest.fn(),
    resolve: jest.fn(),
    forget: jest.fn(),
    prepareDeleteOwnedContent: jest.fn(),
    deleteOwnedContent: jest.fn(),
    queryOperation: jest.fn(),
    cancelPicker: jest.fn(),
  },
}));
jest.mock('react-native-safe-area-context', () => {
  const ReactModule = require('react') as typeof React;
  return {
    SafeAreaProvider: ({ children }: React.PropsWithChildren) =>
      ReactModule.createElement(ReactModule.Fragment, null, children),
    useSafeAreaInsets: () => ({ top: 59, right: 0, bottom: 34, left: 0 }),
  };
});

type MockLocalRuntime = Record<
  | 'isAvailable'
  | 'createCompletionRequestId'
  | 'bootstrap'
  | 'credentialStatus'
  | 'presentCredentialPrompt'
  | 'clearCredential'
  | 'credentialStatusForSlot'
  | 'presentCredentialPromptForSlot'
  | 'clearCredentialForSlot'
  | 'isCredentialSlotAvailable'
  | 'complete'
  | 'completeV2'
  | 'isCompletionV2Available'
  | 'recordModelTransition'
  | 'cancelCompletion',
  jest.Mock
>;
const mockLocalRuntime = (
  jest.requireMock('../src/native/LocalRuntime') as {
    LocalRuntime: MockLocalRuntime;
  }
).LocalRuntime;
const mockSessionSnapshots = (
  jest.requireMock('../src/native/SessionSnapshots') as {
    SessionSnapshots: Record<string, jest.Mock>;
  }
).SessionSnapshots;
const mockAgentRuntime = (
  jest.requireMock('../src/native/AgentRuntime') as {
    AgentRuntime: Record<string, jest.Mock>;
  }
).AgentRuntime;
const mockRunAgentTurn = (
  jest.requireMock('../src/agent/runAgentTurn') as {
    runAgentTurn: jest.Mock;
  }
).runAgentTurn;
const mockLocalAttachments = (
  jest.requireMock('../src/native/LocalAttachments') as {
    LocalAttachments: Record<string, jest.Mock>;
  }
).LocalAttachments;
const mockLocalWorkspaces = (
  jest.requireMock('../src/native/LocalWorkspaces') as {
    LocalWorkspaces: Record<string, jest.Mock>;
  }
).LocalWorkspaces;
const mockLocalWorkspace = (
  jest.requireMock('../src/native/LocalWorkspace') as {
    LocalWorkspace: Record<string, jest.Mock>;
  }
).LocalWorkspace;
const mockLocalProjects = (
  jest.requireMock('../src/native/LocalProjects') as {
    LocalProjects: Record<string, jest.Mock>;
  }
).LocalProjects;
const mockLocalProjectContext = (
  jest.requireMock('../src/native/LocalProjectContext') as {
    LocalProjectContext: Record<string, jest.Mock>;
  }
).LocalProjectContext;
const mockLocalMirrors = (
  jest.requireMock('../src/native/LocalMirrors') as {
    LocalMirrors: Record<string, jest.Mock>;
  }
).LocalMirrors;

const proof = {
  schema_version: 2,
  mode: 'local_substrate',
  platform: 'ios_simulator',
  bundle_id: 'tech.zseven.rish',
  runtime_id: 'runtime-1',
  launch_instance_id: 'launch-1',
  process_id: 123,
  generated_at: '2026-08-24T00:00:00.000Z',
  container_root: 'Application Support',
  session_store: 'sessions.json',
  model_transport: 'url_session',
  rish_backend: 'portable_applet',
  rish_protocol_version: 1,
  rish_probe: { path_kind: 'portable_applet' },
  mac_dsh_port_3180_reachable: false,
  checks: {
    credential_in_keychain: true,
    model_response_received: false,
    session_restored_after_restart: false,
    rish_applet_executed: true,
  },
};

type StrictCompletionRequest = {
  schemaVersion: 2 | 3;
  harnessId?: string;
  turnId: string;
  attemptId: string;
  roundId: string;
  roundIndex: number;
  model: string;
  thinkingMode: string;
  visibleHistory?: Array<{ attachments?: unknown }>;
  projectContext?: {
    schemaVersion: number;
    snapshotId: string;
    consentReceiptId: string;
    conversationId: string;
    projectId: string;
    provider: string;
    policy: string;
  } | null;
};

function strictCompletionResult(
  request: StrictCompletionRequest,
  overrides: Record<string, unknown> = {},
) {
  return {
    schema_version: request.schemaVersion,
    harness_id: request.harnessId ?? 'dsh',
    turn_id: request.turnId,
    attempt_id: request.attemptId,
    round_id: request.roundId,
    round_index: request.roundIndex,
    provider_request_id: request.roundId,
    provider_response_id: `resp_${request.roundId}`,
    requested_model: request.model,
    model: request.model,
    thinking_mode: request.thinkingMode,
    text: 'STRICT_LOCAL_OK',
    reasoning: '',
    tool_calls: [],
    finish_reason: 'stop',
    latency_ms: 24,
    visible_history_sha256: 'a'.repeat(64),
    model_input_sha256: 'b'.repeat(64),
    request_body_sha256: 'c'.repeat(64),
    project_context_receipt: null,
    ...overrides,
  };
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((nextResolve, nextReject) => {
    resolve = nextResolve;
    reject = nextReject;
  });
  return { promise, resolve, reject };
}

const CONTEXT_PROJECT_ID = '44444444-4444-4444-8444-444444444444';
const APP_LAUNCH_INSTANCE_ID = '99999999-9999-4999-8999-999999999999';
const CONTEXT_RUNTIME_ID = '11111111-1111-4111-8111-111111111111';
const CONTEXT_SNAPSHOT_ID = '22222222-2222-4222-8222-222222222222';
const CONTEXT_CONSENT_ID = '33333333-3333-4333-8333-333333333333';
const CONTEXT_PREPARATION_ID = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

const contextProject = {
  schema_version: 1 as const,
  id: CONTEXT_PROJECT_ID,
  name: 'verified-demo',
  workspace_path: `projects/${CONTEXT_PROJECT_ID}/repo`,
  created_at: '2026-08-28T00:00:00.000Z',
  updated_at: '2026-08-28T00:00:00.000Z',
  origin_url: null,
};

const APP_WORKSPACE_ID = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

function appWorkspaceDescriptor(
  workspaceId = APP_WORKSPACE_ID,
  displayName = 'Workspace',
) {
  return {
    schema_version: 2 as const,
    workspace_id: workspaceId,
    display_name: displayName,
    origin: 'rish_created' as const,
    status: 'ok' as const,
    binding_revision: 1,
    capabilities: {
      read: true,
      write: true,
      git: false,
      project_context: false,
      files_visible: true,
    },
    created_at: '2026-08-30T00:00:00.000Z',
    last_opened_at: '2026-08-30T00:00:00.000Z',
  };
}

function appWorkspaceRoot(request: { root: { workspace_id: string; binding_revision: number; project_id: string | null } }) {
  return {
    schema_version: 1 as const,
    workspace_id: request.root.workspace_id,
    binding_revision: request.root.binding_revision,
    project_id: request.root.project_id,
  };
}

function contextManifest(): ProjectContextManifestV1 {
  return {
    schema_version: 1,
    snapshot_id: CONTEXT_SNAPSHOT_ID,
    project_id: CONTEXT_PROJECT_ID,
    project_name: contextProject.name,
    branch: 'main',
    head_oid: '0'.repeat(40),
    clean: true,
    conflicted: false,
    captured_at: '2026-08-28T00:00:00.000Z',
    policy_version: 'chat-read-v1.0.0',
    provider_host: 'api.deepseek.com',
    model: 'deepseek-v4-flash',
    included: [
      {
        path: 'README.md',
        source: 'tracked_file',
        bytes: 16,
        sha256: 'f'.repeat(64),
      },
    ],
    omitted: [],
    context_bytes: 16,
    estimated_tokens: 4,
    snapshot_sha256: 'd'.repeat(64),
    source_fingerprint: 'e'.repeat(64),
  };
}

function storedProjectContext(confirmed: boolean, modelId: 'deepseek-v4-flash' | 'deepseek-v4-pro' = 'deepseek-v4-flash') {
  let messageId = 0;
  const lifecycleIds = [
    CONTEXT_RUNTIME_ID,
    '55555555-5555-4555-8555-555555555555',
    '66666666-6666-4666-8666-666666666666',
    '77777777-7777-4777-8777-777777777777',
    '88888888-8888-4888-8888-888888888888',
    '99999999-9999-4999-8999-999999999999',
  ];
  const stored = createChatStore({
    now: () => '2026-08-28T00:00:00.000Z',
    createId: kind => `${kind}-${++messageId}`,
    createLifecycleId: () => lifecycleIds.shift()!,
  });
  const conversationId = stored.createConversation({
    modelId,
    projectId: CONTEXT_PROJECT_ID,
  });
  expect(stored.ensureRuntimeContextId(conversationId)).toBe(
    CONTEXT_RUNTIME_ID,
  );
  const manifest = {...contextManifest(), model: modelId};
  const initial = stored.getState().conversations[conversationId]!;
  const prepared = stored.replaceProjectContextPrepared(
    {
      conversationId,
      projectId: CONTEXT_PROJECT_ID,
      runtimeContextId: CONTEXT_RUNTIME_ID,
      modelId: initial.modelId,
      expectedContext: initial.projectContext!,
    },
    {
      preparationId: CONTEXT_PREPARATION_ID,
      selectedPaths: ['README.md'],
      manifest,
    },
  );
  expect(prepared?.commit()).toBe(true);
  if (confirmed) {
    const preparedConversation = stored.getState().conversations[conversationId]!;
    const transaction = stored.replaceProjectContextConfirmed(
      {
        conversationId,
        projectId: CONTEXT_PROJECT_ID,
        runtimeContextId: CONTEXT_RUNTIME_ID,
        modelId: preparedConversation.modelId,
        expectedContext: preparedConversation.projectContext!,
      },
      {
        preparationId: CONTEXT_PREPARATION_ID,
        selectedPaths: ['README.md'],
        manifest,
        consent: {
          schema_version: 1,
          consent_receipt_id: CONTEXT_CONSENT_ID,
          snapshot_id: CONTEXT_SNAPSHOT_ID,
          snapshot_sha256: manifest.snapshot_sha256,
          confirmed_at: '2026-08-28T00:00:01.000Z',
        },
      },
    );
    expect(transaction?.commit()).toBe(true);
  }
  return { stored, conversationId, manifest };
}

function storedAgentProject() {
  const fixture = storedProjectContext(true);
  const state = fixture.stored.getState();
  const conversation = state.conversations[fixture.conversationId]!;
  const conversationId = '10101010-1010-4010-8010-101010101010';
  const stored = createChatStore({
    initialState: {
      ...state,
      conversations: {
        [conversationId]: {
          ...conversation,
          id: conversationId,
          workspaceId: CONTEXT_RUNTIME_ID,
          workspaceBinding: {
            schemaVersion: 1,
            workspaceId: CONTEXT_RUNTIME_ID,
            bindingRevision: 1,
            projectId: CONTEXT_PROJECT_ID,
          },
          workspaceBootstrapState: 'none',
        },
      },
      conversationOrder: [conversationId],
      selectedConversationId: conversationId,
    },
  });
  return { ...fixture, stored, conversationId };
}

function mockConfirmedAgentProjectInspection(
  manifest: ProjectContextManifestV1,
): void {
  mockLocalProjectContext.inspectV2.mockReset();
  mockLocalProjectContext.inspectV2.mockImplementation(
    async (request: {
      schema_version: 2;
      snapshot_id: string;
      root: {
        schema_version: 1;
        workspace_id: string;
        binding_revision: number;
        project_id: string;
      };
    }) => ({
      schema_version: 2,
      state: 'confirmed',
      manifest: {
        schema_version: 2,
        snapshot_id: request.snapshot_id,
        root: request.root,
        project: {
          schema_version: 2,
          project_id: CONTEXT_PROJECT_ID,
          workspace_id: request.root.workspace_id,
          workspace_binding_revision: request.root.binding_revision,
          display_name: contextProject.name,
          git_topology: 'legacy_embedded',
        },
        project_id: CONTEXT_PROJECT_ID,
        conversation_id: CONTEXT_RUNTIME_ID,
        model_id: manifest.model,
        policy: 'chat-read-v1',
        branch: manifest.branch,
        head_oid: manifest.head_oid,
        clean: manifest.clean,
        conflicted: manifest.conflicted,
        captured_at: manifest.captured_at,
        policy_version: manifest.policy_version,
        included: manifest.included,
        omitted: manifest.omitted,
        context_bytes: manifest.context_bytes,
        estimated_tokens: manifest.estimated_tokens,
        snapshot_sha256: manifest.snapshot_sha256,
        source_fingerprint: manifest.source_fingerprint,
      },
    }),
  );
}

function mockAgentWorkspaceAuthority(): void {
  const workspace = {
    ...appWorkspaceDescriptor(CONTEXT_RUNTIME_ID, contextProject.name),
    capabilities: {
      read: true,
      write: true,
      git: true,
      project_context: true,
      files_visible: true,
    },
  };
  mockLocalWorkspaces.list.mockResolvedValue({
    schema_version: 1,
    workspaces: [workspace],
  });
  mockLocalWorkspaces.resolve.mockResolvedValue({
    schema_version: 1,
    disposition: 'direct',
    workspace,
  });
  mockLocalProjects.projectForWorkspaceV2.mockResolvedValue({
    schema_version: 1,
    status: 'attached',
    project: {
      schema_version: 2,
      project_id: CONTEXT_PROJECT_ID,
      workspace_id: CONTEXT_RUNTIME_ID,
      workspace_binding_revision: 1,
      display_name: contextProject.name,
      git_topology: 'legacy_embedded',
    },
  });
}

function storedSetupProject() {
  const stored = createChatStore({
    now: () => '2026-08-28T00:00:00.000Z',
  });
  const conversationId = stored.createConversation({
    projectId: CONTEXT_PROJECT_ID,
  });
  return { stored, conversationId };
}

function storedLifecycleCheckpoint(
  phase: 'intent' | 'cleanup_pending' | 'ready_to_finalize',
) {
  const fixture = storedProjectContext(true);
  const conversation = fixture.stored.getState().conversations[
    fixture.conversationId
  ]!;
  const begun = fixture.stored.beginProjectContextDestructiveTransition({
    lifecycleId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    action: 'unbind',
    targetProjectId: null,
    owner: {
      conversationId: fixture.conversationId,
      projectId: conversation.projectId!,
      runtimeContextId: conversation.runtimeContextId,
      modelId: conversation.modelId,
      expectedUpdatedAt: conversation.updatedAt,
      expectedContext: conversation.projectContext!,
    },
  })!;
  expect(begun.commit()).toBe(true);
  if (phase !== 'intent') {
    const transition = fixture.stored.getState()
      .projectContextDestructiveTransition!;
    const tombstone =
      fixture.stored.tombstoneProjectContextDestructiveTransition({
        lifecycleId: transition.lifecycleId,
        epoch: transition.epoch,
        action: transition.action,
        targetProjectId: transition.targetProjectId,
        expectedTransition: transition,
      })!;
    expect(tombstone.commit()).toBe(true);
  }
  if (phase === 'ready_to_finalize') {
    const transition = fixture.stored.getState()
      .projectContextDestructiveTransition!;
    const ready =
      fixture.stored.markProjectContextDestructiveCleanupComplete({
        lifecycleId: transition.lifecycleId,
        epoch: transition.epoch,
        action: transition.action,
        targetProjectId: transition.targetProjectId,
        expectedTransition: transition,
      })!;
    expect(ready.commit()).toBe(true);
  }
  return fixture;
}

async function settle() {
  for (let index = 0; index < 24; index += 1) {
    await Promise.resolve();
  }
}

const mountedRenderers = new Set<Renderer>();

async function renderApp(): Promise<Renderer> {
  let renderer: Renderer | undefined;
  await act(async () => {
    renderer = ReactTestRenderer.create(<App />);
    mountedRenderers.add(renderer);
    await settle();
  });
  if (renderer === undefined) throw new Error('renderer was not created');
  return renderer;
}

/** Workflow fixture setup: cold boot normally, then explicitly reopen its history. */
async function renderAppOpeningStoredConversation(): Promise<Renderer> {
  const storedId = bridgedSessionJSON === null ? null : JSON.parse(bridgedSessionJSON).active_conversation_id;
  const renderer = await renderApp();
  if (typeof storedId === 'string') {
    const root = renderer.root;
    await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
    await act(async () => {
      await root.findByType(ChatDrawer).props.onSelect(storedId);
      await settle();
    });
  }
  // Subsequent assertions measure the workflow, not completed setup writes.
  mockSessionSnapshots.casPersistSession.mockClear();
  return renderer;
}

function lastPersistedState() {
  const calls = mockSessionSnapshots.casPersistSession.mock.calls;
  const serialized = calls.at(-1)?.[0]?.candidate_json;
  if (typeof serialized !== 'string') throw new Error('no persisted state');
  return JSON.parse(serialized) as {
    active_conversation_id: string;
    conversations: Array<{
      id: string;
      model_id: string;
      project_id: string | null;
      project_context: null | {
        status: string;
        selected_paths: string[];
        manifest: null | { snapshot_id: string };
        consent: null | { consent_receipt_id: string };
      };
      workspace_id: string | null;
      workspace_binding: null | {
        schema_version: 1;
        workspace_id: string;
        binding_revision: number;
        project_id: string | null;
      };
      runtime_context_id: string | null;
      thinking_mode: string;
      attempts?: Array<{
        attempt_id: string;
        status: string;
        context_disposition?: string;
        project_context?: null | { snapshot_id: string };
        assistant_message_id: string | null;
        failure_code: string | null;
        rounds: Array<{ round_id: string }>;
      }>;
      messages: Array<{
        role: string;
        text: string;
        metadata?: { model_id?: string };
        attachments: Array<{
          id: string;
          kind: string;
          thumbnail_data_url?: string;
        }>;
      }>;
    }>;
    messages: Array<{
      role: string;
      text: string;
      metadata?: { model_id?: string };
      attachments: Array<{
        id: string;
        kind: string;
        thumbnail_data_url?: string;
      }>;
    }>;
  };
}

function lastPersistedCandidateJSON(): string {
  const serialized =
    mockSessionSnapshots.casPersistSession.mock.calls.at(-1)?.[0]
      ?.candidate_json;
  if (typeof serialized !== 'string') throw new Error('no persisted state');
  return serialized;
}

function persistedStates(): Array<ReturnType<typeof lastPersistedState>> {
  return mockSessionSnapshots.casPersistSession.mock.calls.flatMap(call => {
    const value = call[0]?.candidate_json;
    return typeof value === 'string'
      ? [JSON.parse(value) as ReturnType<typeof lastPersistedState>]
      : [];
  });
}

function sessionOnlyResultFor(request: { candidate_json: string }) {
  const current = bridgedAuthority();
  const generation =
    current.kind === 'present' ? current.snapshot.generation + 1 : 1;
  return {
    schema_version: 1,
    status: 'session_only' as const,
    current: {
      schema_version: 1 as const,
      kind: 'present' as const,
      snapshot: {
        schema_version: 1 as const,
        generation,
        session_sha256: sessionSnapshotSHA256(request.candidate_json)!,
      },
    },
  };
}

function notCommittedResult() {
  return {
    schema_version: 1,
    status: 'not_committed' as const,
    current: bridgedAuthority(),
  };
}

function unknownResult() {
  return {
    schema_version: 1,
    status: 'unknown' as const,
    current: bridgedAuthority(),
  };
}

function queuePresentSession(sessionJSON: string, generation = 1): void {
  bridgedSessionJSON = sessionJSON;
  bridgedGeneration = generation;
  mockSessionSnapshots.loadSessionSnapshot.mockResolvedValueOnce(
    presentLoadResult(sessionJSON, generation),
  );
}

function queueLegacySession(sessionJSON: string): void {
  bridgedSessionJSON = sessionJSON;
  bridgedGeneration = 0;
  mockSessionSnapshots.loadSessionSnapshot.mockResolvedValueOnce(
    legacyLoadResult(sessionJSON),
  );
}

function queueDeferredSessionLoad(load: Promise<string | null>): void {
  mockSessionSnapshots.loadSessionSnapshot.mockReturnValueOnce(
    load.then(sessionJSON =>
      sessionJSON === null
        ? {
            schema_version: 1,
            status: 'missing',
            snapshot: null,
            session_json: null,
            writer_launch_instance_id: null,
            current_launch_instance_id: APP_LAUNCH_INSTANCE_ID,
          }
        : presentLoadResult(sessionJSON),
    ),
  );
}

function actionByLabel(
  root: ReactTestInstance,
  label: string,
): ReactTestInstance {
  const action = root
    .findAllByProps({ accessibilityLabel: label })
    .find(instance => typeof instance.props.onPress === 'function');
  if (action === undefined) throw new Error(`no actionable ${label}`);
  return action;
}

function visibleContextSheets(root: ReactTestInstance): ReactTestInstance[] {
  return root
    .findAllByType(ProjectContextSheet)
    .filter(sheet => sheet.props.visible === true);
}

async function openProjectsSurface(root: ReactTestInstance): Promise<void> {
  await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
  await act(async () => {
    root.findByType(ChatDrawer).props.onOpenProjects();
    root.findByType(ChatDrawer).props.onDismiss();
    await settle();
  });
  expect(root.findByType(ProjectsSurface).props.visible).toBe(true);
}

async function renderSetupProjectApp(): Promise<Renderer> {
  const fixture = storedSetupProject();
  queuePresentSession(fixture.stored.serialize());
  mockLocalProjects.list.mockResolvedValue({
    schema_version: 1,
    projects: [contextProject],
  });
  return await renderAppOpeningStoredConversation();
}

async function enterPendingProjectRecovery(
  root: ReactTestInstance,
  text: string,
) {
  await act(async () =>
    root
      .findByProps({ accessibilityLabel: 'Message DSH' })
      .props.onChangeText(text),
  );
  await act(async () => {
    actionByLabel(root, 'Send message').props.onPress();
    await settle();
  });
}

async function preparePendingProjectDisclosure(root: ReactTestInstance) {
  await act(async () =>
    actionByLabel(root, 'Refresh and send').props.onPress(),
  );
  await act(async () => {
    jest.advanceTimersByTime(180);
    await settle();
  });
  await act(async () =>
    root
      .findByProps({ testID: 'project-context-candidate-README.md' })
      .props.onPress(),
  );
  await act(async () => {
    actionByLabel(root, 'Prepare context').props.onPress();
    await settle();
    await settle();
  });
}

function composerOptionsChip(root: ReactTestInstance): ReactTestInstance {
  const chip = root
    .findAllByProps({ testID: 'composer-options-chip' })
    .find(instance => typeof instance.props.onPress === 'function');
  if (chip === undefined) throw new Error('no composer options chip');
  return chip;
}

function optionInComposerPanel(
  root: ReactTestInstance,
  label: string,
): ReactTestInstance {
  const popover = root.findAllByProps({
    testID: 'conversation-options-popover',
  })[0];
  if (popover === undefined) throw new Error('composer panel not rendered');
  return actionByLabel(popover, label);
}

test('binds the active conversation to a chosen local workspace', async () => {
  mockLocalWorkspaces.list.mockResolvedValue({
    schema_version: 1,
    workspaces: [
      {
        ...appWorkspaceDescriptor(
          'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          'Alpha',
        ),
      },
      {
        ...appWorkspaceDescriptor(
          'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
          'Beta',
        ),
      },
    ],
  });
  const renderer = await renderApp();
  const root = renderer.root;

  await act(async () =>
    actionByLabel(root, 'Choose workspace').props.onPress(),
  );
  await act(async () => settle());
  const sheetHosts = () =>
    root
      .findAllByProps({ testID: 'workspace-picker-sheet' })
      .filter(node => typeof node.type === 'string');
  expect(sheetHosts()).toHaveLength(1);

  await act(async () => {
    const popover = root.findByProps({
      testID: 'workspace-picker-sheet',
    }) as ReactTestInstance;
    actionByLabel(popover, 'Use Alpha').props.onPress();
    await settle();
  });

  expect(sheetHosts()).toHaveLength(0);
  expect(lastPersistedState().conversations[0]?.workspace_id).toBe(
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  );
});

test('creates a new project chat from a workspace-only active conversation', async () => {
  jest.useFakeTimers();
  const harnessWorkspaceId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  const spoonWorkspaceId = CONTEXT_RUNTIME_ID;
  const harnessWorkspace = appWorkspaceDescriptor(
    harnessWorkspaceId,
    'Harness',
  );
  const spoonWorkspace = {
    ...appWorkspaceDescriptor(spoonWorkspaceId, 'Spoon'),
    capabilities: {
      read: true,
      write: true,
      git: true,
      project_context: true,
      files_visible: true,
    },
  };
  const projectRoot = {
    schema_version: 1 as const,
    workspace_id: spoonWorkspaceId,
    binding_revision: 1,
    project_id: contextProject.id,
  };
  const projectDescriptor = {
    schema_version: 2 as const,
    project_id: contextProject.id,
    workspace_id: spoonWorkspaceId,
    workspace_binding_revision: 1,
    display_name: contextProject.name,
    git_topology: 'legacy_embedded' as const,
  };
  const manifest = contextManifest();
  mockLocalWorkspaces.list.mockResolvedValue({
    schema_version: 1,
    workspaces: [harnessWorkspace, spoonWorkspace],
  });
  mockLocalWorkspaces.bootstrapLegacyProject.mockResolvedValue(
    spoonWorkspace,
  );
  mockLocalWorkspaces.resolve.mockImplementation(async request => ({
    schema_version: 1,
    disposition: 'direct',
    workspace:
      request.workspace_id === spoonWorkspaceId
        ? spoonWorkspace
        : harnessWorkspace,
  }));
  mockLocalProjects.projectForWorkspaceV2.mockImplementation(async root =>
    root.workspace_id === spoonWorkspaceId
      ? {
          schema_version: 1,
          status: 'attached',
          project: projectDescriptor,
        }
      : { schema_version: 1, status: 'none' },
  );
  mockLocalProjects.list.mockResolvedValue({
    schema_version: 1,
    projects: [contextProject],
  });
  mockLocalProjectContext.listCandidatesV2.mockImplementation(
    async request => ({
      schema_version: 2,
      root: request.root,
      project: projectDescriptor,
      candidates: [
        {
          path: 'README.md',
          size: 16,
          revision: 'f'.repeat(40),
          git_state: 'unchanged',
          eligible: true,
          omission_reason: null,
        },
      ],
      next_cursor: null,
    }),
  );
  mockLocalProjectContext.prepareV2.mockImplementation(async request => ({
    schema_version: 2,
    snapshot_id: CONTEXT_SNAPSHOT_ID,
    root: request.root,
    project: projectDescriptor,
    project_id: contextProject.id,
    conversation_id: request.conversation_id,
    model_id: request.model_id,
    policy: 'chat-read-v1',
    branch: manifest.branch,
    head_oid: manifest.head_oid,
    clean: manifest.clean,
    conflicted: manifest.conflicted,
    captured_at: manifest.captured_at,
    policy_version: manifest.policy_version,
    included: manifest.included,
    omitted: manifest.omitted,
    context_bytes: manifest.context_bytes,
    estimated_tokens: manifest.estimated_tokens,
    snapshot_sha256: manifest.snapshot_sha256,
    source_fingerprint: manifest.source_fingerprint,
  }));
  mockLocalProjectContext.confirmV2.mockImplementation(async request => ({
    schema_version: 2,
    consent_receipt_id: CONTEXT_CONSENT_ID,
    snapshot_id: request.snapshot_id,
    root: request.root,
    workspace_id: request.root.workspace_id,
    workspace_binding_revision: request.root.binding_revision,
    snapshot_sha256: manifest.snapshot_sha256,
    confirmed_at: '2026-08-28T00:00:01.000Z',
  }));
  const renderer = await renderApp();
  const root = renderer.root;

  await act(async () =>
    actionByLabel(root, 'Choose workspace').props.onPress(),
  );
  await act(async () => settle());
  await act(async () => {
    const popover = root.findByProps({
      testID: 'workspace-picker-sheet',
    }) as ReactTestInstance;
    actionByLabel(popover, 'Use Harness').props.onPress();
    await settle();
  });

  const workspaceOnly = lastPersistedState();
  const workspaceConversationId = workspaceOnly.active_conversation_id;
  expect(workspaceOnly.conversations).toHaveLength(1);
  expect(workspaceOnly.conversations[0]).toMatchObject({
    id: workspaceConversationId,
    workspace_id: harnessWorkspaceId,
    project_id: null,
    project_context: null,
  });

  await openProjectsSurface(root);
  await act(async () => {
    await root.findByType(ProjectsSurface).props.onChatInProject(contextProject);
    await settle();
  });
  // This project is already registered; reuse its root rather than bootstrap again.
  expect(mockLocalWorkspaces.bootstrapLegacyProject).not.toHaveBeenCalled();
  await act(async () => {
    jest.advanceTimersByTime(180);
    await settle();
  });

  const persisted = lastPersistedState();
  expect(persisted.conversations).toHaveLength(2);
  expect(
    persisted.conversations.find(
      conversation => conversation.id === workspaceConversationId,
    ),
  ).toMatchObject({
    workspace_id: harnessWorkspaceId,
    project_id: null,
    project_context: null,
  });
  const selected = persisted.conversations.find(
    conversation => conversation.id === persisted.active_conversation_id,
  );
  expect(selected?.id).not.toBe(workspaceConversationId);
  expect(selected).toMatchObject({
    workspace_id: spoonWorkspaceId,
    workspace_binding: {
      binding_revision: 1,
      project_id: contextProject.id,
    },
    project_id: contextProject.id,
    project_context: { status: 'setup_required' },
  });
  expect(visibleContextSheets(root)).toHaveLength(1);
  expect(visibleContextSheets(root)[0]?.props.mode).toBe('candidates');
  expect(visibleContextSheets(root)[0]?.props.projectName).toBe(
    contextProject.name,
  );
  expect(mockLocalProjectContext.listCandidatesV2).toHaveBeenCalledWith({
    schema_version: 1,
    root: projectRoot,
    query: '',
    cursor: null,
  });
  expect(mockSessionSnapshots.casPersistSession).toHaveBeenCalledTimes(2);
  expect(bridgedSessionJSON).toBe(lastPersistedCandidateJSON());

  await act(async () =>
    root
      .findByProps({ testID: 'project-context-candidate-README.md' })
      .props.onPress(),
  );
  await act(async () => {
    actionByLabel(root, 'Prepare context').props.onPress();
    await settle();
    await settle();
  });
  expect(mockLocalProjectContext.prepareV2).toHaveBeenCalledWith(
    expect.objectContaining({
      schema_version: 2,
      root: projectRoot,
      conversation_id: expect.any(String),
      selected_paths: ['README.md'],
    }),
  );
  expect(visibleContextSheets(root)[0]?.props.mode).toBe('disclosure');
  expect(visibleContextSheets(root)[0]?.props.confirmationRequired).toBe(true);

  await act(async () => {
    actionByLabel(root, 'Confirm context').props.onPress();
    await settle();
    await settle();
  });
  expect(mockLocalProjectContext.confirmV2).toHaveBeenCalledWith({
    schema_version: 2,
    snapshot_id: CONTEXT_SNAPSHOT_ID,
    root: projectRoot,
  });
  const confirmed = lastPersistedState().conversations.find(
    conversation => conversation.id === persisted.active_conversation_id,
  );
  expect(confirmed).toMatchObject({
    workspace_id: spoonWorkspaceId,
    workspace_binding: {
      binding_revision: 1,
      project_id: contextProject.id,
    },
    project_id: contextProject.id,
    project_context: {
      status: 'ready',
      selected_paths: ['README.md'],
      manifest: { snapshot_id: CONTEXT_SNAPSHOT_ID },
      consent: { consent_receipt_id: CONTEXT_CONSENT_ID },
    },
  });
  expect(
    mockLocalProjectContext.prepareV2.mock.calls[0]?.[0].conversation_id,
  ).toBe(confirmed?.runtime_context_id);
  jest.useRealTimers();
});

test('does not create a chat when legacy project bootstrap fails', async () => {
  const workspaceId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  mockLocalWorkspaces.list.mockResolvedValue({
    schema_version: 1,
    workspaces: [appWorkspaceDescriptor(workspaceId, 'Alpha')],
  });
  mockLocalProjects.list.mockResolvedValue({
    schema_version: 1,
    projects: [contextProject],
  });
  const renderer = await renderApp();
  const root = renderer.root;

  await act(async () =>
    actionByLabel(root, 'Choose workspace').props.onPress(),
  );
  await act(async () => settle());
  await act(async () => {
    const popover = root.findByProps({
      testID: 'workspace-picker-sheet',
    }) as ReactTestInstance;
    actionByLabel(popover, 'Use Alpha').props.onPress();
    await settle();
  });
  const workspaceOnly = lastPersistedState();
  mockLocalWorkspaces.bootstrapLegacyProject.mockRejectedValueOnce({
    code: 'E_WORKSPACE_UNAVAILABLE',
    message: 'RAW_BOOTSTRAP /private/project',
  });

  await openProjectsSurface(root);
  await act(async () => {
    await root.findByType(ProjectsSurface).props.onChatInProject(contextProject);
    await settle();
  });

  expect(visibleContextSheets(root)).toHaveLength(0);
  expect(mockLocalProjectContext.listCandidatesV2).not.toHaveBeenCalled();
  expect(mockSessionSnapshots.casPersistSession).toHaveBeenCalledTimes(1);
  expect(lastPersistedState()).toEqual(workspaceOnly);
  expect(root.findByType(ChatDrawer).props.conversations).toHaveLength(1);
  expect(JSON.stringify(renderer.toJSON())).toContain(
    'E_WORKSPACE_UNAVAILABLE',
  );
  expect(JSON.stringify(renderer.toJSON())).not.toContain('RAW_BOOTSTRAP');
});

test('shows workspace recovery and no Context when project binding durability is unknown', async () => {
  const workspaceId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  const workspace = {
    ...appWorkspaceDescriptor(workspaceId, 'Alpha'),
    capabilities: {
      read: true,
      write: true,
      git: true,
      project_context: true,
      files_visible: true,
    },
  };
  const projectDescriptor = {
    schema_version: 2 as const,
    project_id: contextProject.id,
    workspace_id: workspaceId,
    workspace_binding_revision: 1,
    display_name: contextProject.name,
    git_topology: 'legacy_embedded' as const,
  };
  mockLocalWorkspaces.list.mockResolvedValue({
    schema_version: 1,
    workspaces: [workspace],
  });
  mockLocalWorkspaces.resolve.mockResolvedValue({
    schema_version: 1,
    disposition: 'direct',
    workspace,
  });
  mockLocalWorkspaces.bootstrapLegacyProject.mockResolvedValue(workspace);
  mockLocalProjects.list.mockResolvedValue({
    schema_version: 1,
    projects: [contextProject],
  });
  mockLocalProjects.projectForWorkspaceV2
    .mockResolvedValueOnce({
      schema_version: 1,
      status: 'none',
    })
    .mockResolvedValue({
      schema_version: 1,
      status: 'attached',
      project: projectDescriptor,
    });
  const renderer = await renderApp();
  const root = renderer.root;

  await act(async () =>
    actionByLabel(root, 'Choose workspace').props.onPress(),
  );
  await act(async () => settle());
  await act(async () => {
    const popover = root.findByProps({
      testID: 'workspace-picker-sheet',
    }) as ReactTestInstance;
    actionByLabel(popover, 'Use Alpha').props.onPress();
    await settle();
  });
  const committedWorkspaceOnly = bridgedSessionJSON;
  mockSessionSnapshots.casPersistSession.mockResolvedValueOnce(unknownResult());
  mockSessionSnapshots.querySessionCommit.mockResolvedValueOnce({
    schema_version: 1,
    status: 'unknown',
  });

  await openProjectsSurface(root);
  await act(async () => {
    await root.findByType(ProjectsSurface).props.onChatInProject(contextProject);
    await settle();
  });

  expect(visibleContextSheets(root)).toHaveLength(0);
  expect(mockLocalProjectContext.listCandidatesV2).not.toHaveBeenCalled();
  expect(actionByLabel(root, 'Retry saving workspace')).toBeDefined();
  expect(mockSessionSnapshots.casPersistSession).toHaveBeenCalledTimes(2);
  expect(mockSessionSnapshots.querySessionCommit).toHaveBeenCalledTimes(1);
  expect(bridgedSessionJSON).toBe(committedWorkspaceOnly);
});

async function chooseAttachmentSource(
  root: ReactTestInstance,
  label: 'Camera' | 'Photos' | 'Files',
) {
  const modal = root.findByProps({ testID: 'attachment-menu-modal' });
  await act(async () => actionByLabel(root, label).props.onPress());
  await act(async () => {
    modal.props.onDismiss();
    await settle();
  });
}

type AppSessionAuthority =
  | { schema_version: 1; kind: 'missing' }
  | {
      schema_version: 1;
      kind: 'legacy_present';
      legacy: { schema_version: 1; legacy_bytes_sha256: string };
    }
  | {
      schema_version: 1;
      kind: 'present';
      snapshot: {
        schema_version: 1;
        generation: number;
        session_sha256: string;
      };
    };

let bridgedSessionJSON: string | null = null;
let bridgedGeneration = 0;
let bridgedLegacyBytesSha256 = 'a'.repeat(64);
let bootstrappedLegacyProjectId: string | null = null;
const bridgedOperations = new Map<
  string,
  {
    candidateJSON: string;
    snapshot: { schema_version: 1; generation: number; session_sha256: string };
  }
>();

function bridgedAuthority(): AppSessionAuthority {
  if (bridgedSessionJSON === null) {
    return { schema_version: 1, kind: 'missing' };
  }
  let schema: unknown;
  try {
    schema = JSON.parse(bridgedSessionJSON).schema_version;
  } catch {
    return { schema_version: 1, kind: 'missing' };
  }
  if (typeof schema !== 'number') {
    return { schema_version: 1, kind: 'missing' };
  }
  if (schema === 9) {
    const digest = sessionSnapshotSHA256(bridgedSessionJSON);
    if (digest === null) return { schema_version: 1, kind: 'missing' };
    return {
      schema_version: 1,
      kind: 'present',
      snapshot: {
        schema_version: 1,
        generation: Math.max(1, bridgedGeneration),
        session_sha256: digest,
      },
    };
  }
  if (schema >= 2 && schema <= 8) {
    return {
      schema_version: 1,
      kind: 'legacy_present',
      legacy: {
        schema_version: 1,
        legacy_bytes_sha256: bridgedLegacyBytesSha256,
      },
    };
  }
  return { schema_version: 1, kind: 'missing' };
}

function bridgedLoadResult(): unknown {
  if (bridgedSessionJSON === null) {
    return {
      schema_version: 1,
      status: 'missing',
      snapshot: null,
      session_json: null,
      writer_launch_instance_id: null,
      current_launch_instance_id: APP_LAUNCH_INSTANCE_ID,
    };
  }
  const authority = bridgedAuthority();
  if (authority.kind === 'present') {
    return {
      schema_version: 1,
      status: 'present',
      snapshot: authority.snapshot,
      session_json: bridgedSessionJSON,
      writer_launch_instance_id: APP_LAUNCH_INSTANCE_ID,
      current_launch_instance_id: APP_LAUNCH_INSTANCE_ID,
    };
  }
  if (authority.kind === 'legacy_present') {
    return {
      schema_version: 1,
      status: 'legacy_present',
      legacy: authority.legacy,
      session_json: bridgedSessionJSON,
      writer_launch_instance_id: APP_LAUNCH_INSTANCE_ID,
      current_launch_instance_id: APP_LAUNCH_INSTANCE_ID,
    };
  }
  return bridgedSessionJSON;
}

function sameBridgedAuthority(
  left: AppSessionAuthority,
  right: AppSessionAuthority,
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

function commitBridgedCandidate(request: {
  operation_id: string;
  candidate_json: string;
}) {
  const digest = sessionSnapshotSHA256(request.candidate_json);
  if (digest === null) {
    return {
      schema_version: 1,
      status: 'unknown' as const,
      current: bridgedAuthority(),
    };
  }
  const current = bridgedAuthority();
  bridgedSessionJSON = request.candidate_json;
  bridgedGeneration =
    current.kind === 'present' ? current.snapshot.generation + 1 : 1;
  const snapshot = {
    schema_version: 1 as const,
    generation: bridgedGeneration,
    session_sha256: digest,
  };
  bridgedOperations.set(request.operation_id, {
    candidateJSON: request.candidate_json,
    snapshot,
  });
  return { schema_version: 1, status: 'committed' as const, snapshot };
}

beforeEach(() => {
  jest.clearAllMocks();
  jest.spyOn(AppState, 'addEventListener').mockReturnValue({ remove: jest.fn() });
  mockSessionSnapshots.isAvailable.mockReset();
  mockSessionSnapshots.loadSessionSnapshot.mockReset();
  mockSessionSnapshots.casPersistSession.mockReset();
  mockSessionSnapshots.querySessionCommit.mockReset();
  mockLocalProjectContext.listCandidatesV2.mockReset();
  mockLocalProjectContext.prepareV2.mockReset();
  mockLocalProjectContext.confirmV2.mockReset();
  mockLocalProjectContext.discardV2.mockReset();
  mockLocalWorkspaces.bootstrapLegacyProject.mockReset();
  mockLocalWorkspaces.resolve.mockReset();
  mockLocalProjects.projectForWorkspaceV2.mockReset();
  mockLocalWorkspaces.isAvailable.mockReset();
  Object.values(mockAgentRuntime).forEach(method => method.mockReset());
  bridgedSessionJSON = null;
  bridgedGeneration = 0;
  bridgedLegacyBytesSha256 = 'a'.repeat(64);
  bootstrappedLegacyProjectId = null;
  bridgedOperations.clear();
  let requestCounter = 0;
  mockLocalRuntime.isAvailable.mockReturnValue(true);
  mockLocalRuntime.createCompletionRequestId.mockImplementation(
    () =>
      `${String(++requestCounter).padStart(
        8,
        '0',
      )}-0000-4000-8000-000000000000`,
  );
  mockLocalRuntime.credentialStatus.mockResolvedValue({ status: 'configured' });
  mockLocalRuntime.credentialStatusForSlot.mockResolvedValue({
    status: 'configured',
  });
  mockLocalRuntime.presentCredentialPromptForSlot.mockResolvedValue({
    status: 'configured',
  });
  mockLocalRuntime.clearCredentialForSlot.mockResolvedValue({ status: 'cleared' });
  mockLocalRuntime.isCredentialSlotAvailable.mockReturnValue(true);
  mockLocalRuntime.bootstrap.mockResolvedValue({ proof, rish: {} });
  mockSessionSnapshots.isAvailable.mockReturnValue(true);
  mockAgentRuntime.isAvailable.mockReturnValue(false);
  mockSessionSnapshots.loadSessionSnapshot.mockImplementation(async () =>
    bridgedLoadResult(),
  );
  mockSessionSnapshots.casPersistSession.mockImplementation(async request => {
    const expected = request.expected as AppSessionAuthority;
    const operationId = request.operation_id as string;
    const replay = bridgedOperations.get(operationId);
    if (replay !== undefined) {
      return replay.candidateJSON === request.candidate_json
        ? { schema_version: 1, status: 'committed', snapshot: replay.snapshot }
        : {
            schema_version: 1,
            status: 'conflict',
            current: bridgedAuthority(),
          };
    }
    const current = bridgedAuthority();
    if (!sameBridgedAuthority(expected, current)) {
      return { schema_version: 1, status: 'conflict', current };
    }
    return commitBridgedCandidate(request);
  });
  mockSessionSnapshots.querySessionCommit.mockImplementation(
    async (request: { operation_id: string }) => {
      const operation = bridgedOperations.get(request.operation_id);
      return operation === undefined
        ? { schema_version: 1, status: 'not_started' }
        : { schema_version: 1, status: 'committed', snapshot: operation.snapshot };
    },
  );
  mockLocalRuntime.complete.mockResolvedValue({
    text: 'SIMULATOR_LOCAL_OK',
    model: 'deepseek-v4-flash',
    request_id: 'request-1',
    latency_ms: 42,
    reasoning: '',
    thinking_mode: 'high',
  });
  mockLocalRuntime.completeV2.mockImplementation(
    async (request: StrictCompletionRequest) =>
      strictCompletionResult(request),
  );
  mockRunAgentTurn.mockResolvedValue({
    status: 'failed',
    traces: [],
    failure: { code: 'E_AGENT_FAILED' },
  });
  mockLocalRuntime.recordModelTransition.mockResolvedValue({ recorded: 1 });
  mockLocalRuntime.cancelCompletion.mockResolvedValue({ status: 'cancelled' });
  mockLocalRuntime.presentCredentialPrompt.mockResolvedValue({
    status: 'configured',
  });
  mockLocalRuntime.clearCredential.mockResolvedValue({ status: 'cleared' });
  mockLocalAttachments.isAvailable.mockReturnValue(true);
  mockLocalAttachments.isModelDeliverySupported.mockReturnValue(true);
  mockLocalAttachments.present.mockResolvedValue({
    schema_version: 1,
    status: 'cancelled',
    attachments: [],
  });
  mockLocalAttachments.discard.mockResolvedValue({
    schema_version: 1,
    discarded_count: 0,
  });
  mockLocalAttachments.prune.mockResolvedValue({
    schema_version: 1,
    removed_count: 0,
  });
  mockLocalAttachments.preview.mockResolvedValue({
    schema_version: 1,
    id: 'attachment-1',
    thumbnail_data_url: null,
  });
  mockLocalAttachments.presentPreview.mockResolvedValue({
    schema_version: 1,
    status: 'closed',
  });
  mockLocalWorkspace.isAvailable.mockReturnValue(true);
  mockLocalWorkspace.listDirectory.mockResolvedValue({ path: '', entries: [] });
  mockLocalWorkspace.listTrash.mockResolvedValue({
    entries: [],
    invalid_record_count: 0,
  });
  mockLocalWorkspace.writeText.mockResolvedValue({
    created: true,
    file: {
      path: 'note.md',
      name: 'note.md',
      kind: 'file',
      size: 0,
      modified_at: '2026-08-24T00:00:00.000Z',
      revision: 'rev-1',
    },
  });
  mockLocalWorkspace.createDirectory.mockResolvedValue({
    directory: {
      path: 'docs',
      name: 'docs',
      kind: 'directory',
      size: 0,
      modified_at: '2026-08-24T00:00:00.000Z',
    },
  });
  mockLocalWorkspace.executePortableTool.mockResolvedValue({
    tool: 'sha256sum',
    path: 'note.md',
    exit_code: 0,
    stdout: 'abc  note.md\n',
    stderr: '',
    protocol_version: 1,
    path_kind: 'portable_applet',
  });
  mockLocalWorkspace.listV2.mockImplementation(
    async (request: {
      root: { workspace_id: string; binding_revision: number; project_id: string | null };
      path: string;
    }) => ({
      schema_version: 1,
      root: appWorkspaceRoot(request),
      path: request.path,
      entries: [],
    }),
  );
  mockLocalWorkspace.listTrashV2.mockImplementation(
    async (request: {
      root: { workspace_id: string; binding_revision: number; project_id: string | null };
    }) => ({
      schema_version: 1,
      root: appWorkspaceRoot(request),
      entries: [],
      invalid_record_count: 0,
    }),
  );
  mockLocalWorkspace.writeV2.mockImplementation(
    async (request: {
      root: { workspace_id: string; binding_revision: number; project_id: string | null };
      path: string;
      content: string;
      create_only: boolean;
    }) => ({
      schema_version: 1,
      root: appWorkspaceRoot(request),
      file: {
        path: request.path,
        name: request.path.split('/').at(-1) ?? request.path,
        kind: 'file',
        size: request.content.length,
        modified_at: '2026-08-30T00:00:00.000Z',
        revision: 'rev-1',
      },
      created: request.create_only,
    }),
  );
  mockLocalWorkspace.readV2.mockImplementation(
    async (request: {
      root: { workspace_id: string; binding_revision: number; project_id: string | null };
      path: string;
    }) => ({
      schema_version: 1,
      root: appWorkspaceRoot(request),
      path: request.path,
      file: {
        path: request.path,
        name: request.path.split('/').at(-1) ?? request.path,
        kind: 'file',
        size: 5,
        modified_at: '2026-08-30T00:00:00.000Z',
        revision: 'rev-1',
      },
      content: 'hello',
    }),
  );
  mockLocalWorkspace.executePortableToolV2.mockImplementation(
    async (request: {
      root: { workspace_id: string; binding_revision: number; project_id: string | null };
      tool: string;
      path: string;
    }) => ({
      schema_version: 1,
      root: appWorkspaceRoot(request),
      tool: request.tool,
      path: request.path,
      exit_code: 0,
      stdout: 'abc  note.md\n',
      stderr: '',
      protocol_version: 1,
      path_kind: 'portable_applet',
    }),
  );
  mockLocalProjects.isAvailable.mockReturnValue(true);
  mockLocalProjects.isV2Available.mockReturnValue(false);
  mockLocalProjects.list.mockResolvedValue({
    schema_version: 1,
    projects: [],
  });
  mockLocalProjects.projectForWorkspaceV2.mockImplementation(async root =>
    bootstrappedLegacyProjectId !== null &&
    root.workspace_id === CONTEXT_RUNTIME_ID
      ? {
          schema_version: 1,
          status: 'attached',
          project: {
            schema_version: 2,
            project_id: bootstrappedLegacyProjectId,
            workspace_id: CONTEXT_RUNTIME_ID,
            workspace_binding_revision: 1,
            display_name: contextProject.name,
            git_topology: 'legacy_embedded',
          },
        }
      : { schema_version: 1, status: 'none' },
  );
  mockLocalWorkspaces.list.mockResolvedValue({
    schema_version: 1,
    workspaces: [],
  });
  mockLocalWorkspaces.create.mockResolvedValue(appWorkspaceDescriptor());
  mockLocalWorkspaces.bootstrapLegacyProject.mockImplementation(
    async request => {
      bootstrappedLegacyProjectId = request.project_id;
      return {
        ...appWorkspaceDescriptor(CONTEXT_RUNTIME_ID, contextProject.name),
        capabilities: {
          read: true,
          write: true,
          git: true,
          project_context: true,
          files_visible: true,
        },
      };
    },
  );
  mockLocalWorkspaces.resolve.mockImplementation(
    async (request: { workspace_id: string; expected_binding_revision: number }) => {
      const workspace = appWorkspaceDescriptor(request.workspace_id);
      return {
        schema_version: 1,
        disposition: 'direct',
        workspace:
          request.workspace_id === CONTEXT_RUNTIME_ID
            ? {
                ...workspace,
                capabilities: {
                  read: true,
                  write: true,
                  git: true,
                  project_context: true,
                  files_visible: true,
                },
              }
            : workspace,
      };
    },
  );
  mockLocalProjects.status.mockResolvedValue({
    schema_version: 1,
    project_id: 'project-1',
    branch: 'main',
    head_oid: null,
    clean: true,
    has_conflicts: false,
    ahead: 0,
    behind: 0,
    entries: [],
  });
  mockLocalProjects.diff.mockResolvedValue({
    schema_version: 1,
    project_id: 'project-1',
    staged: false,
    truncated: false,
    patch: '',
    files: [],
  });
  mockLocalProjects.credentialStatus.mockResolvedValue({
    schema_version: 1,
    project_id: 'project-1',
    host: '',
    configured: false,
  });
  mockLocalProjectContext.isAvailable.mockReturnValue(true);
  mockLocalProjectContext.listCandidates.mockImplementation(
    async (projectId: string) => ({
      schema_version: 1,
      project_id: projectId,
      candidates: [],
      next_cursor: null,
    }),
  );
  mockLocalProjectContext.listCandidatesV2.mockImplementation(async request => {
    const page = await mockLocalProjectContext.listCandidates(
      request.root.project_id,
      request.query,
      request.cursor,
    );
    return {
      schema_version: 2,
      root: request.root,
      project: {
        schema_version: 2,
        project_id: request.root.project_id,
        workspace_id: request.root.workspace_id,
        workspace_binding_revision: request.root.binding_revision,
        display_name: contextProject.name,
        git_topology: 'legacy_embedded',
      },
      candidates: page.candidates,
      next_cursor: page.next_cursor,
    };
  });
  mockLocalProjectContext.prepare.mockRejectedValue({
    code: 'E_CONTEXT_REQUEST_INVALID',
  });
  mockLocalProjectContext.prepareV2.mockImplementation(async request => {
    const manifest = await mockLocalProjectContext.prepare({
      schema_version: 1,
      project_id: request.root.project_id,
      conversation_id: request.conversation_id,
      provider: 'deepseek',
      model: request.model_id,
      policy: request.policy,
      selected_paths: request.selected_paths,
    });
    return {
      schema_version: 2,
      snapshot_id: manifest.snapshot_id,
      root: request.root,
      project: {
        schema_version: 2,
        project_id: request.root.project_id,
        workspace_id: request.root.workspace_id,
        workspace_binding_revision: request.root.binding_revision,
        display_name: manifest.project_name,
        git_topology: 'legacy_embedded',
      },
      project_id: request.root.project_id,
      conversation_id: request.conversation_id,
      model_id: request.model_id,
      policy: request.policy,
      branch: manifest.branch,
      head_oid: manifest.head_oid,
      clean: manifest.clean,
      conflicted: manifest.conflicted,
      captured_at: manifest.captured_at,
      policy_version: manifest.policy_version,
      included: manifest.included,
      omitted: manifest.omitted,
      context_bytes: manifest.context_bytes,
      estimated_tokens: manifest.estimated_tokens,
      snapshot_sha256: manifest.snapshot_sha256,
      source_fingerprint: manifest.source_fingerprint,
    };
  });
  mockLocalProjectContext.confirm.mockRejectedValue({
    code: 'E_CONTEXT_REQUEST_INVALID',
  });
  mockLocalProjectContext.confirmV2.mockImplementation(async request => {
    const consent = await mockLocalProjectContext.confirm(request.snapshot_id);
    return {
      schema_version: 2,
      consent_receipt_id: consent.consent_receipt_id,
      snapshot_id: consent.snapshot_id,
      root: request.root,
      workspace_id: request.root.workspace_id,
      workspace_binding_revision: request.root.binding_revision,
      snapshot_sha256: consent.snapshot_sha256,
      confirmed_at: consent.confirmed_at,
    };
  });
  mockLocalProjectContext.inspect.mockRejectedValue({
    code: 'E_CONTEXT_SNAPSHOT_MISSING',
  });
  mockLocalProjectContext.inspectV2.mockRejectedValue({
    code: 'E_CONTEXT_SNAPSHOT_MISSING',
  });
  mockLocalProjectContext.discard.mockResolvedValue({
    schema_version: 1,
    status: 'discarded',
  });
  mockLocalProjectContext.discardV2.mockImplementation(async request => {
    const result = await mockLocalProjectContext.discard(request.snapshot_id);
    return {
      schema_version: 2,
      status: result.status,
      snapshot_id: request.snapshot_id,
      root: request.root,
    };
  });
  mockLocalMirrors.isAvailable.mockReturnValue(true);
  mockLocalMirrors.status.mockResolvedValue(null);
  mockLocalMirrors.apply.mockResolvedValue({
    schema_version: 1,
    status: 'staged',
    staged_at: '2026-08-24T00:00:00.000Z',
    guest_runtime_mounted: false,
    root: 'rish-guest-overlay',
    entries: [],
  });
});

afterEach(async () => {
  await act(async () => {
    for (const renderer of mountedRenderers) renderer.unmount();
    mountedRenderers.clear();
    await settle();
  });
  jest.restoreAllMocks();
  jest.useRealTimers();
});

test('boots into a usable local empty chat', async () => {
  const renderer = await renderApp();
  const root = renderer.root;

  expect(
    root.findByProps({ accessibilityLabel: 'Message DSH' }).props.editable,
  ).toBe(true);
  expect(
    root.findByProps({ accessibilityLabel: 'Open navigation' }),
  ).toBeDefined();
  expect(
    root.findAllByProps({ accessibilityLabel: 'Show runtime evidence' }),
  ).toHaveLength(0);
  expect(root.findByProps({ accessibilityLabel: 'Rish' })).toBeDefined();
  expect(mockLocalRuntime.bootstrap).toHaveBeenCalledTimes(1);
});

test('re-probes false session availability before bootstrap and loads exactly once when it becomes true', async () => {
  mockSessionSnapshots.isAvailable
    .mockReturnValueOnce(false)
    .mockReturnValueOnce(true);
  await renderApp();

  expect(mockSessionSnapshots.isAvailable).toHaveBeenCalledTimes(2);
  expect(mockSessionSnapshots.loadSessionSnapshot).toHaveBeenCalledTimes(1);
});

test('keeps cold-start bootstrap gated for a third session availability probe', async () => {
  jest.useFakeTimers();
  mockSessionSnapshots.isAvailable
    .mockReturnValueOnce(false)
    .mockReturnValueOnce(false)
    .mockReturnValueOnce(true);
  let renderer: Renderer | undefined;
  await act(async () => {
    renderer = ReactTestRenderer.create(<App />);
    mountedRenderers.add(renderer);
    await settle();
  });
  expect(mockSessionSnapshots.loadSessionSnapshot).not.toHaveBeenCalled();
  await act(async () => {
    jest.advanceTimersByTime(100);
    await settle();
  });
  expect(renderer).toBeDefined();
  expect(mockSessionSnapshots.isAvailable).toHaveBeenCalledTimes(3);
  expect(mockSessionSnapshots.loadSessionSnapshot).toHaveBeenCalledTimes(1);
});

test.each(['prepared', 'failed'] as const)(
  'surfaces Retry for a hydrated %s attempt without automatic HTTP',
  async status => {
    const lifecycleIds = [
      '11111111-1111-4111-8111-111111111111',
      '22222222-2222-4222-8222-222222222222',
    ];
    let messageId = 0;
    const stored = createChatStore({
      now: () => '2026-08-28T00:00:00.000Z',
      createId: kind => `${kind}-${++messageId}`,
      createLifecycleId: () => lifecycleIds.shift()!,
    });
    const conversationId = stored.createConversation();
    const prepared = stored.prepareTurnAttempt(
      conversationId,
      `${status} after restart`,
    )!;
    prepared.commit();
    if (status === 'failed') {
      stored.failAttempt(
        conversationId,
        prepared.attemptId,
        'E_COMPLETION_TRANSPORT',
      );
    }
    queuePresentSession(stored.serialize());

    const renderer = await renderAppOpeningStoredConversation();
    expect(actionByLabel(renderer.root, status === 'prepared' ? 'Continue response' : 'Retry response')).toBeDefined();
    if (status === 'prepared') {
      expect(
        renderer.root.findByProps({ accessibilityLabel: 'Message DSH' }).props
          .editable,
      ).toBe(false);
      expect(actionByLabel(renderer.root, 'Send message').props.disabled).toBe(
        true,
      );
    }
    expect(mockLocalRuntime.completeV2).not.toHaveBeenCalled();
  },
);

test('runtime evidence retry refreshes proof without rehydrating active chat state', async () => {
  mockLocalRuntime.bootstrap
    .mockRejectedValueOnce(new Error('temporary proof failure'))
    .mockResolvedValueOnce({ proof, rish: {} });
  const renderer = await renderApp();
  const root = renderer.root;

  await act(async () => composerOptionsChip(root).props.onPress());
  await act(async () => {
    optionInComposerPanel(root, 'Use V4 Pro').props.onPress();
    await settle();
  });
  await act(async () => optionInComposerPanel(root, 'Done').props.onPress());
  await act(async () =>
    actionByLabel(root, 'Show runtime evidence').props.onPress(),
  );
  await act(async () => {
    actionByLabel(root, 'Retry runtime check').props.onPress();
    await settle();
  });

  expect(mockLocalRuntime.bootstrap).toHaveBeenCalledTimes(2);
  expect(mockSessionSnapshots.loadSessionSnapshot).toHaveBeenCalled();
  expect(composerOptionsChip(root).props.accessibilityLabel).toBe(
    'Model V4 Pro, thinking High',
  );
  expect(lastPersistedState().conversations[0]?.model_id).toBe(
    'deepseek-v4-pro',
  );
});

test('presents DSH as one built-in harness under the Rish runtime', async () => {
  const renderer = await renderApp();
  const root = renderer.root;

  await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
  await act(async () => actionByLabel(root, 'Harnesses').props.onPress());
  await act(async () => settle());

  expect(actionByLabel(root, 'Use DSH')).toBeDefined();
  expect(root.findByProps({ children: 'Harness manifest v1' })).toBeDefined();
  expect(root.findByProps({ children: 'Current harness' })).toBeDefined();
});

async function openHarnessPicker(root: ReactTestInstance): Promise<void> {
  await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
  await act(async () => {
    const drawer = root.findByType(ChatDrawer);
    drawer.props.onOpenHarnesses();
    drawer.props.onDismiss();
    await settle();
  });
  expect(root.findByType(HarnessPicker).props.visible).toBe(true);
}

test('seeds GLM new chats from the selected Harness and shows its actual settings credential', async () => {
  const stored = createChatStore();
  const preferences = createPreferencesStore();
  preferences.setSelectedHarness('glm');
  queuePresentSession(JSON.stringify({
    ...JSON.parse(stored.serialize()),
    preferences: JSON.parse(preferences.serialize()),
  }));
  const renderer = await renderApp();
  const root = renderer.root;
  expect(root.findByType(ChatComposer).props.model).toBe('GLM-5.3');
  expect(root.findByType(ChatComposer).props.harnessName).toBe('GLM');
  await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
  await act(async () => {
    await root.findByType(ChatDrawer).props.onNewChat();
    await settle();
  });
  expect(lastPersistedState().conversations.every(chat => chat.model_id === 'GLM-5.3')).toBe(true);
  expect(root.findByType(ChatComposer).props.model).toBe('GLM-5.3');
  await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
  await act(async () => {
    const drawer = root.findByType(ChatDrawer);
    drawer.props.onOpenSettings();
    drawer.props.onDismiss();
    await settle();
  });
  expect(root.findByProps({ children: 'Harness · GLM' })).toBeDefined();
  expect(actionByLabel(root, 'Replace Zhipu GLM key')).toBeDefined();
  await act(async () => {
    root.findByType(SettingsSheet).props.onConfigureCredential();
    await settle();
  });
  expect(mockLocalRuntime.presentCredentialPromptForSlot).toHaveBeenLastCalledWith('BIGMODEL_API_KEY', 'en-US');
});

test('switches Harness in the same settled conversation without rewriting history or discarding its draft', async () => {
  const renderer = await renderApp();
  const root = renderer.root;
  await act(async () => root.findByType(ChatComposer).props.onChange('Existing DSH turn'));
  await act(async () => {
    root.findByType(ChatComposer).props.onSend();
    await settle();
  });
  const before = lastPersistedState();
  expect(before.conversations[0]?.attempts).toHaveLength(1);
  await act(async () => root.findByType(ChatComposer).props.onChange('Keep this draft'));
  await openHarnessPicker(root);
  await act(async () => {
    root.findByType(HarnessPicker).props.onSelect('glm');
    await settle();
  });
  const after = lastPersistedState();
  expect(after.active_conversation_id).toBe(before.active_conversation_id);
  expect(after.conversations).toHaveLength(1);
  expect(after.conversations[0]?.model_id).toBe('GLM-5.3');
  expect(after.conversations[0]?.messages).toEqual(before.conversations[0]?.messages);
  expect(after.conversations[0]?.attempts).toEqual(before.conversations[0]?.attempts);
  expect(root.findByType(ChatComposer).props.draft).toBe('Keep this draft');
  await act(async () => {
    root.findByType(ChatComposer).props.onSend();
    await settle();
  });
  expect(mockLocalRuntime.completeV2.mock.calls.at(-1)?.[0]).toMatchObject({ harnessId: 'glm', model: 'GLM-5.3' });
});

test('routes explicitly reopened conversations by their own models while keeping the new-chat Harness preference', async () => {
  const stored = createChatStore();
  const glm = stored.createConversation({ title: 'GLM history', modelId: 'GLM-5.3-Flash' });
  const dsh = stored.createConversation({ title: 'DSH history', modelId: 'deepseek-v4-pro' });
  stored.selectConversation(glm);
  queuePresentSession(stored.serialize());
  const renderer = await renderApp();
  const root = renderer.root;
  // Cold launch now defaults to a new chat; history reopening is explicit.
  await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
  await act(async () => {
    await root.findByType(ChatDrawer).props.onSelect(glm);
    await settle();
  });
  expect(root.findByType(ChatComposer).props.harnessName).toBe('GLM');
  await act(async () => root.findByType(ChatComposer).props.onChange('GLM restored send'));
  await act(async () => {
    root.findByType(ChatComposer).props.onSend();
    await settle();
  });
  expect(mockLocalRuntime.completeV2.mock.calls.at(-1)?.[0]).toMatchObject({ harnessId: 'glm', model: 'GLM-5.3-Flash' });
  await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
  await act(async () => {
    await root.findByType(ChatDrawer).props.onSelect(dsh);
    await settle();
  });
  expect(root.findByType(ChatComposer).props.harnessName).toBe('DSH');
  await act(async () => root.findByType(ChatComposer).props.onChange('DSH reopened send'));
  await act(async () => {
    root.findByType(ChatComposer).props.onSend();
    await settle();
  });
  expect(mockLocalRuntime.completeV2.mock.calls.at(-1)?.[0]).toMatchObject({ harnessId: 'dsh', model: 'deepseek-v4-pro' });
  expect(JSON.parse(lastPersistedCandidateJSON()).preferences.selected_harness_id).toBe('dsh');
});

test('keeps the selected conversation retry owner when an earlier Harness save finishes late', async () => {
  const stored = createChatStore();
  const firstId = stored.createConversation({ title: 'Harness switch source' });
  const secondId = stored.createConversation({ title: 'Retry destination' });
  const prepared = stored.prepareTurnAttempt(secondId, 'Retry this destination')!;
  expect(prepared.commit()).toBe(true);
  expect(
    stored.failAttempt(secondId, prepared.attemptId, 'E_COMPLETION_NATIVE'),
  ).toBe(true);
  stored.selectConversation(firstId);
  queuePresentSession(stored.serialize());
  const renderer = await renderAppOpeningStoredConversation();
  const root = renderer.root;
  const harnessSave = deferred<boolean>();
  mockSessionSnapshots.casPersistSession.mockImplementationOnce(async request => {
    await harnessSave.promise;
    return commitBridgedCandidate(request);
  });

  await openHarnessPicker(root);
  await act(async () => {
    root.findByType(HarnessPicker).props.onSelect('glm');
    await settle();
  });
  expect(mockSessionSnapshots.casPersistSession).toHaveBeenCalledTimes(1);
  expect(root.findByType(ChatComposer).props.harnessName).toBe('GLM');

  await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
  let selectDestination: Promise<void> | undefined;
  await act(async () => {
    selectDestination = root.findByType(ChatDrawer).props.onSelect(secondId);
    await settle();
  });
  expect(root.findByType(ChatComposer).props.harnessName).toBe('DSH');
  expect(actionByLabel(root, 'Retry response')).toBeDefined();

  await act(async () => {
    harnessSave.resolve(true);
    await selectDestination;
    await settle();
  });
  expect(lastPersistedState().active_conversation_id).toBe(secondId);
  expect(root.findByType(ChatComposer).props.harnessName).toBe('DSH');
  expect(actionByLabel(root, 'Retry response')).toBeDefined();
});

test('blocks Harness switching during an active completion and allows it after the attempt settles', async () => {
  const completion = deferred<ReturnType<typeof strictCompletionResult>>();
  let request: StrictCompletionRequest | undefined;
  mockLocalRuntime.completeV2.mockImplementationOnce((input: StrictCompletionRequest) => {
    request = input;
    return completion.promise;
  });
  const renderer = await renderApp();
  const root = renderer.root;
  await act(async () => root.findByType(ChatComposer).props.onChange('Keep this running attempt'));
  await act(async () => {
    root.findByType(ChatComposer).props.onSend();
    await settle();
  });
  expect(request).toBeDefined();
  // Progress is shown by the send/stop button alone; there is no status row.
  expect(root.findByType(ChatComposer).props.sending).toBe(true);
  expect(() => root.findByProps({ children: 'Working with DeepSeek…' })).toThrow();
  await openHarnessPicker(root);
  expect(actionByLabel(root, 'Use GLM').props.disabled).toBe(true);
  await act(async () => root.findByType(HarnessPicker).props.onSelect('glm'));
  expect(root.findByType(ChatComposer).props.model).toBe('deepseek-v4-flash');
  expect(root.findByType(HarnessPicker).props.visible).toBe(true);
  expect(mockLocalRuntime.cancelCompletion).not.toHaveBeenCalled();
  await act(async () => {
    completion.resolve(strictCompletionResult(request!));
    await settle();
  });
  await act(async () => {
    root.findByType(HarnessPicker).props.onSelect('glm');
    await settle();
  });
  expect(root.findByType(ChatComposer).props.model).toBe('GLM-5.3');
  expect(lastPersistedState().conversations[0]?.attempts?.[0]?.status).toBe('completed');
});

test('refreshes credential availability when switching Harness instead of reusing the previous provider key', async () => {
  mockLocalRuntime.credentialStatusForSlot.mockImplementation(async slot => ({
    status: slot === 'BIGMODEL_API_KEY' ? 'missing' : 'configured',
  }));
  const renderer = await renderApp();
  const root = renderer.root;
  await openHarnessPicker(root);
  await act(async () => {
    root.findByType(HarnessPicker).props.onSelect('glm');
    await settle();
  });
  expect(root.findByType(ChatComposer).props.configured).toBe(false);
  expect(actionByLabel(root, 'Configure Zhipu GLM key')).toBeDefined();
  expect(root.findByProps({ accessibilityLabel: 'Message GLM' }).props.placeholder).toBe('Sign in or configure an API key to start');
  expect(typeof root.findByType(ChatComposer).props.onLogin).toBe('function');
});

test.each([
  ['dsh', 'DSH', 'DeepSeek'],
  ['claude-code', 'Claude Code', 'Anthropic'],
  ['codex', 'Codex', 'OpenAI'],
  ['glm', 'GLM', 'Zhipu GLM'],
] as const)('labels the %s API provider independently from its Harness name', async (id, harness, provider) => {
  const renderer = await renderApp();
  const root = renderer.root;
  await openHarnessPicker(root);
  await act(async () => {
    root.findByType(HarnessPicker).props.onSelect(id);
    await settle();
  });
  expect(root.findByType(ChatComposer).props).toMatchObject({
    harnessName: harness,
    providerName: provider,
  });
  expect(root.findByType(SettingsSheet).props).toMatchObject({
    harnessName: harness,
    providerName: provider,
  });
});

test('invalidates project context consent when switching Harness in the same conversation', async () => {
  const fixture = storedProjectContext(true);
  queuePresentSession(fixture.stored.serialize());
  const renderer = await renderAppOpeningStoredConversation();
  const root = renderer.root;
  await openHarnessPicker(root);
  await act(async () => {
    root.findByType(HarnessPicker).props.onSelect('glm');
    await settle();
  });
  const current = lastPersistedState().conversations.find(chat => chat.id === fixture.conversationId);
  expect(current?.project_id).toBe(CONTEXT_PROJECT_ID);
  expect(current?.runtime_context_id).toBe(CONTEXT_RUNTIME_ID);
  expect(current?.model_id).toBe('GLM-5.3');
  expect(current?.project_context?.consent).toBeNull();
  expect(current?.project_context?.status).not.toBe('ready');
  expect(mockLocalRuntime.completeV2).not.toHaveBeenCalled();
});

test('does not silently switch an image draft from GLM to the DeepSeek provider', async () => {
  const renderer = await renderApp();
  const root = renderer.root;
  await openHarnessPicker(root);
  await act(async () => {
    root.findByType(HarnessPicker).props.onSelect('glm');
    await settle();
  });
  mockLocalAttachments.present.mockResolvedValueOnce({
    schema_version: 1, status: 'selected', attachments: [{
      schema_version: 1, id: 'glm-image', kind: 'image', name: 'glm.png', mime_type: 'image/png', size: 64,
    }],
  });
  await act(async () => actionByLabel(root, 'Add attachment').props.onPress());
  await chooseAttachmentSource(root, 'Photos');
  await act(async () => {
    root.findByType(ChatComposer).props.onSend();
    await settle();
  });
  expect(mockLocalRuntime.completeV2).not.toHaveBeenCalled();
  expect(root.findByType(ChatComposer).props.model).toBe('GLM-5.3');
  expect(root.findByType(ChatComposer).props.attachments).toHaveLength(1);
  expect(root.findByProps({ children: 'Images are not supported by GLM. Choose a harness with image input before sending.' })).toBeDefined();
});

test('opens Projects as a full-width primary surface from the navigation drawer', async () => {
  const renderer = await renderApp();
  const root = renderer.root;

  await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
  await act(async () => {
    actionByLabel(root, 'Projects').props.onPress();
    await settle();
  });

  expect(mockLocalProjects.list).toHaveBeenCalledTimes(1);
  expect(root.findByProps({ children: 'No projects yet' })).toBeDefined();
  expect(actionByLabel(root, 'New project')).toBeDefined();
});

describe('project context Home integration H1', () => {
  test('hydrates a confirmed snapshot as Checking until one native inspection confirms', async () => {
    const fixture = storedProjectContext(true);
    const inspection = deferred<ProjectContextInspectionV1>();
    queuePresentSession(fixture.stored.serialize());
    mockLocalProjects.list.mockResolvedValue({
      schema_version: 1,
      projects: [contextProject],
    });
    mockLocalProjectContext.inspect.mockReturnValueOnce(inspection.promise);

    const renderer = await renderAppOpeningStoredConversation();
    const root = renderer.root;
    expect(mockLocalProjectContext.inspect).toHaveBeenCalledTimes(1);
    expect(mockLocalProjectContext.inspect).toHaveBeenCalledWith(
      CONTEXT_SNAPSHOT_ID,
    );
    expect(root.findByProps({ children: 'Checking' })).toBeDefined();
    expect(root.findAllByProps({ children: 'Ready' })).toHaveLength(0);
    expect(mockLocalRuntime.completeV2).not.toHaveBeenCalled();
    expect(mockLocalRuntime.complete).not.toHaveBeenCalled();

    inspection.resolve({
      schema_version: 1,
      state: 'confirmed',
      manifest: fixture.manifest,
    });
    await act(async () => settle());

    expect(root.findByProps({ children: 'Ready' })).toBeDefined();
    expect(mockLocalProjectContext.inspect).toHaveBeenCalledTimes(1);
    expect(mockLocalRuntime.completeV2).not.toHaveBeenCalled();
  });

  test('fails closed when hydrated native inspection rejects', async () => {
    const fixture = storedProjectContext(true);
    queuePresentSession(fixture.stored.serialize());
    mockLocalProjects.list.mockResolvedValue({
      schema_version: 1,
      projects: [contextProject],
    });
    mockLocalProjectContext.inspect.mockRejectedValueOnce({
      code: 'E_CONTEXT_TIMEOUT',
      message: 'RAW_NATIVE_SENTINEL /private/project',
    });

    const renderer = await renderAppOpeningStoredConversation();
    const root = renderer.root;
    await act(async () => settle());

    expect(root.findByProps({ children: 'Error' })).toBeDefined();
    expect(root.findAllByProps({ children: 'Ready' })).toHaveLength(0);
    expect(
      root.findByProps({ accessibilityLabel: 'Message DSH' }).props.editable,
    ).toBe(true);
    expect(JSON.stringify(renderer.toJSON())).not.toContain(
      'RAW_NATIVE_SENTINEL',
    );
    expect(mockLocalRuntime.completeV2).not.toHaveBeenCalled();
    expect(mockLocalRuntime.complete).not.toHaveBeenCalled();
    expect(mockSessionSnapshots.casPersistSession).not.toHaveBeenCalled();
  });

  test('opens Context only after Projects starts dismissal and renders one Strip', async () => {
    jest.useFakeTimers();
    mockLocalProjects.list.mockResolvedValue({
      schema_version: 1,
      projects: [contextProject],
    });
    const renderer = await renderApp();
    const root = renderer.root;
    await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
    await act(async () => {
      actionByLabel(root, 'Projects').props.onPress();
      await settle();
    });
    await act(async () => {
      actionByLabel(root, `Open project ${contextProject.name}`).props.onPress();
      await settle();
    });

    await act(async () => {
      const opening = actionByLabel(root, 'Chat in this project').props.onPress();
      expect(visibleContextSheets(root)).toHaveLength(0);
      await opening;
      await settle();
    });
    await act(async () => {
      jest.advanceTimersByTime(180);
      await settle();
    });

    expect(root.findByType(ProjectsSurface).props.visible).toBe(false);
    expect(visibleContextSheets(root)).toHaveLength(1);
    expect(mockLocalProjectContext.listCandidates).toHaveBeenCalledTimes(1);
    expect(root.findAllByType(ProjectContextStrip)).toHaveLength(1);
    expect(
      root.findAllByProps({ accessibilityLabel: `Project ${contextProject.name}` }),
    ).toHaveLength(0);
    expect(
      Object.prototype.hasOwnProperty.call(
        root.findByType(ChatComposer).props,
        'projectName',
      ),
    ).toBe(false);
    jest.useRealTimers();
  });

  test('opens current confirmed context as disclosure without confirmation', async () => {
    const fixture = storedProjectContext(true);
    queuePresentSession(fixture.stored.serialize());
    mockLocalProjects.list.mockResolvedValue({
      schema_version: 1,
      projects: [contextProject],
    });
    mockLocalProjectContext.inspect.mockResolvedValueOnce({
      schema_version: 1,
      state: 'confirmed',
      manifest: fixture.manifest,
    });
    const renderer = await renderAppOpeningStoredConversation();
    const root = renderer.root;
    await act(async () =>
      root.findByProps({ testID: 'project-context-strip' }).props.onPress(),
    );
    await act(async () => settle());

    const sheet = visibleContextSheets(root)[0];
    expect(sheet?.props.mode).toBe('disclosure');
    expect(sheet?.props.confirmationRequired).toBe(false);
    expect(
      root.findAllByProps({ accessibilityLabel: 'Confirm context' }),
    ).toHaveLength(0);
  });

  test('shows Context Checking immediately after Projects dismisses while reinspection is pending', async () => {
    const fixture = storedProjectContext(true);
    const reinspection = deferred<ProjectContextInspectionV1>();
    queuePresentSession(fixture.stored.serialize());
    mockLocalProjects.list.mockResolvedValue({
      schema_version: 1,
      projects: [contextProject],
    });
    mockLocalProjectContext.inspect
      .mockResolvedValueOnce({
        schema_version: 1,
        state: 'confirmed',
        manifest: fixture.manifest,
      })
      .mockReturnValueOnce(reinspection.promise);
    const renderer = await renderAppOpeningStoredConversation();
    const root = renderer.root;
    await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
    await act(async () => {
      actionByLabel(root, 'Projects').props.onPress();
      await settle();
    });

    await act(async () => {
      root.findByType(ProjectsSurface).props.onChatInProject(contextProject);
      await settle();
    });

    expect(root.findByType(ProjectsSurface).props.visible).toBe(false);
    expect(visibleContextSheets(root)).toHaveLength(1);
    expect(visibleContextSheets(root)[0]?.props.checking).toBe(true);
    expect(mockLocalProjectContext.inspect).toHaveBeenCalledTimes(2);

    reinspection.resolve({
      schema_version: 1,
      state: 'confirmed',
      manifest: fixture.manifest,
    });
    await act(async () => settle());
    expect(visibleContextSheets(root)[0]?.props.checking).toBe(false);
  });

  test('selects a fresh candidate, prepares disclosure, and confirms durably with zero HTTP', async () => {
    jest.useFakeTimers();
    const manifest = contextManifest();
    mockLocalProjects.list.mockResolvedValue({
      schema_version: 1,
      projects: [contextProject],
    });
    mockLocalProjectContext.listCandidates.mockResolvedValue({
      schema_version: 1,
      project_id: CONTEXT_PROJECT_ID,
      candidates: [
        {
          path: 'README.md',
          size: 16,
          revision: 'f'.repeat(40),
          git_state: 'unchanged',
          eligible: true,
          omission_reason: null,
        },
      ],
      next_cursor: null,
    });
    mockLocalProjectContext.prepare.mockResolvedValue(manifest);
    mockLocalProjectContext.confirm.mockResolvedValue({
      schema_version: 1,
      consent_receipt_id: CONTEXT_CONSENT_ID,
      snapshot_id: CONTEXT_SNAPSHOT_ID,
      snapshot_sha256: manifest.snapshot_sha256,
      confirmed_at: '2026-08-28T00:00:01.000Z',
    });
    const renderer = await renderApp();
    const root = renderer.root;
    await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
    await act(async () => {
      actionByLabel(root, 'Projects').props.onPress();
      await settle();
    });
    await act(async () => {
      actionByLabel(root, `Open project ${contextProject.name}`).props.onPress();
      await settle();
    });
    await act(async () => {
      await actionByLabel(root, 'Chat in this project').props.onPress();
      await settle();
    });
    await act(async () => {
      jest.advanceTimersByTime(180);
      await settle();
    });

    await act(async () =>
      root
        .findByProps({ testID: 'project-context-candidate-README.md' })
        .props.onPress(),
    );
    await act(async () => {
      actionByLabel(root, 'Prepare context').props.onPress();
      await settle();
      await settle();
    });
    expect(visibleContextSheets(root)[0]?.props.mode).toBe('disclosure');
    expect(visibleContextSheets(root)[0]?.props.confirmationRequired).toBe(true);
    expect(visibleContextSheets(root)[0]?.props.manifest).toEqual(manifest);
    expect(mockLocalRuntime.completeV2).not.toHaveBeenCalled();

    await act(async () => {
      actionByLabel(root, 'Confirm context').props.onPress();
      await settle();
      await settle();
    });
    expect(mockLocalProjectContext.confirm).toHaveBeenCalledWith(
      CONTEXT_SNAPSHOT_ID,
    );
    expect(visibleContextSheets(root)).toHaveLength(0);
    const persisted = lastPersistedState().conversations.find(
      conversation => conversation.project_id === CONTEXT_PROJECT_ID,
    );
    expect(persisted?.project_context).toMatchObject({
      status: 'ready',
      selected_paths: ['README.md'],
      manifest: { snapshot_id: CONTEXT_SNAPSHOT_ID },
      consent: { consent_receipt_id: CONTEXT_CONSENT_ID },
    });
    expect(root.findByProps({ children: 'Ready' })).toBeDefined();
    expect(mockLocalRuntime.completeV2).not.toHaveBeenCalled();
    expect(mockLocalRuntime.complete).not.toHaveBeenCalled();
    jest.useRealTimers();
  });

  test('opens a persisted prepared snapshot as disclosure requiring confirmation', async () => {
    const fixture = storedProjectContext(false);
    queuePresentSession(fixture.stored.serialize());
    mockLocalProjects.list.mockResolvedValue({
      schema_version: 1,
      projects: [contextProject],
    });
    mockLocalProjectContext.inspect.mockResolvedValueOnce({
      schema_version: 1,
      state: 'prepared',
      manifest: fixture.manifest,
    });
    const renderer = await renderAppOpeningStoredConversation();
    const root = renderer.root;
    await act(async () => settle());
    await act(async () =>
      root.findByProps({ testID: 'project-context-strip' }).props.onPress(),
    );

    const sheet = visibleContextSheets(root)[0];
    expect(sheet?.props.mode).toBe('disclosure');
    expect(sheet?.props.confirmationRequired).toBe(true);
    expect(actionByLabel(root, 'Confirm context')).toBeDefined();
  });

  test('opens a retryable completion owner read-only with zero context attach side effects', async () => {
    const fixture = storedProjectContext(true);
    const pending = fixture.stored.prepareTurnAttempt(
      fixture.conversationId,
      'Retry this project request',
    );
    expect(pending?.commit()).toBe(true);
    expect(
      fixture.stored.failAttempt(
        fixture.conversationId,
        pending!.attemptId,
        'E_COMPLETION_NATIVE',
      ),
    ).toBe(true);
    queuePresentSession(fixture.stored.serialize());
    mockLocalProjects.list.mockResolvedValue({
      schema_version: 1,
      projects: [contextProject],
    });

    const renderer = await renderAppOpeningStoredConversation();
    const root = renderer.root;
    expect(mockLocalProjectContext.inspect).not.toHaveBeenCalled();
    expect(mockLocalProjectContext.listCandidates).not.toHaveBeenCalled();
    await act(async () =>
      root.findByProps({ testID: 'project-context-strip' }).props.onPress(),
    );
    await act(async () => settle());

    expect(mockLocalProjectContext.inspect).not.toHaveBeenCalled();
    expect(mockLocalProjectContext.listCandidates).not.toHaveBeenCalled();
    expect(
      root.findAllByProps({ accessibilityLabel: 'Stop response' }),
    ).toHaveLength(0);
  });

  test('hard-blocks model and options callbacks while Context owns an inspection', async () => {
    const fixture = storedProjectContext(true);
    const inspection = deferred<ProjectContextInspectionV1>();
    queuePresentSession(fixture.stored.serialize());
    mockLocalProjects.list.mockResolvedValue({
      schema_version: 1,
      projects: [contextProject],
    });
    mockLocalProjectContext.inspect.mockReturnValueOnce(inspection.promise);
    const renderer = await renderAppOpeningStoredConversation();
    const root = renderer.root;

    await act(async () => root.findByType(ChatComposer).props.onOptionsPress());
    await act(async () => root.findByType(ChatDrawer).props.onOpenSettings());
    expect(
      root.findAllByProps({ testID: 'conversation-options-popover' }),
    ).toHaveLength(0);
    expect(root.findByType(SettingsSheet).props.visible).toBe(false);
    await act(async () => root.findByType(SettingsSheet).props.onOpenModelPicker());
    expect(root.findByType(ModelPicker).props.visible).toBe(false);
    await act(async () =>
      root.findByType(ModelPicker).props.onSelect('deepseek-v4-pro'),
    );
    await act(async () =>
      root
        .findByType(ConversationOptionsPicker)
        .props.onSelectThinkingMode('max'),
    );
    expect(mockLocalRuntime.recordModelTransition).not.toHaveBeenCalled();

    inspection.resolve({
      schema_version: 1,
      state: 'confirmed',
      manifest: fixture.manifest,
    });
    await act(async () => settle());
  });

  test('reconciles Context after a retryable Completion owner returns idle', async () => {
    const fixture = storedProjectContext(true);
    const pending = fixture.stored.prepareTurnAttempt(
      fixture.conversationId,
      'Retry and release context ownership',
    );
    expect(pending?.commit()).toBe(true);
    expect(
      fixture.stored.failAttempt(
        fixture.conversationId,
        pending!.attemptId,
        'E_COMPLETION_NATIVE',
      ),
    ).toBe(true);
    queuePresentSession(fixture.stored.serialize());
    mockLocalProjects.list.mockResolvedValue({
      schema_version: 1,
      projects: [contextProject],
    });
    mockLocalProjectContext.inspect.mockResolvedValue({
      schema_version: 1,
      state: 'confirmed',
      manifest: fixture.manifest,
    });
    mockLocalRuntime.completeV2.mockImplementationOnce(
      async (request: StrictCompletionRequest) => ({
        ...strictCompletionResult(request, { text: 'Retry succeeded' }),
        project_context_receipt: {
          schema_version: 1,
          snapshot_id: CONTEXT_SNAPSHOT_ID,
          snapshot_sha256: fixture.manifest.snapshot_sha256,
          source_fingerprint: fixture.manifest.source_fingerprint,
          context_bytes: fixture.manifest.context_bytes,
          verified_at: '2026-08-28T00:00:02.000Z',
        },
      }),
    );
    const renderer = await renderAppOpeningStoredConversation();
    const root = renderer.root;
    expect(mockLocalProjectContext.inspect).not.toHaveBeenCalled();

    await act(async () =>
      actionByLabel(root, 'Retry response').props.onPress(),
    );
    await act(async () => settle());

    expect(mockLocalProjectContext.inspect).toHaveBeenCalledTimes(1);
    expect(root.findByProps({ children: 'Ready' })).toBeDefined();
  });

  test('never projects prior-owner candidate metadata into a retryable conversation', async () => {
    jest.useFakeTimers();
    const fixture = storedProjectContext(true);
    fixture.stored.renameConversation(fixture.conversationId, 'Project A');
    fixture.stored.appendUserMessage(fixture.conversationId, 'Visible A');
    const conversationB = fixture.stored.createConversation({
      projectId: CONTEXT_PROJECT_ID,
    });
    const runtimeB = fixture.stored.ensureRuntimeContextId(conversationB)!;
    const initialB = fixture.stored.getState().conversations[conversationB]!;
    const preparedB = fixture.stored.replaceProjectContextPrepared(
      {
        conversationId: conversationB,
        projectId: CONTEXT_PROJECT_ID,
        runtimeContextId: runtimeB,
        modelId: initialB.modelId,
        expectedContext: initialB.projectContext!,
      },
      {
        preparationId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        selectedPaths: ['README.md'],
        manifest: fixture.manifest,
      },
    );
    expect(preparedB?.commit()).toBe(true);
    const preparedConversationB =
      fixture.stored.getState().conversations[conversationB]!;
    const confirmedB = fixture.stored.replaceProjectContextConfirmed(
      {
        conversationId: conversationB,
        projectId: CONTEXT_PROJECT_ID,
        runtimeContextId: runtimeB,
        modelId: preparedConversationB.modelId,
        expectedContext: preparedConversationB.projectContext!,
      },
      {
        preparationId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        selectedPaths: ['README.md'],
        manifest: fixture.manifest,
        consent: {
          schema_version: 1,
          consent_receipt_id: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
          snapshot_id: CONTEXT_SNAPSHOT_ID,
          snapshot_sha256: fixture.manifest.snapshot_sha256,
          confirmed_at: '2026-08-28T00:00:02.000Z',
        },
      },
    );
    expect(confirmedB?.commit()).toBe(true);
    fixture.stored.renameConversation(conversationB, 'Project B');
    const retryB = fixture.stored.prepareTurnAttempt(
      conversationB,
      'Visible B retry',
    );
    expect(retryB?.commit()).toBe(true);
    expect(
      fixture.stored.failAttempt(
        conversationB,
        retryB!.attemptId,
        'E_COMPLETION_NATIVE',
      ),
    ).toBe(true);
    fixture.stored.selectConversation(fixture.conversationId);
    queuePresentSession(fixture.stored.serialize());
    mockLocalProjects.list.mockResolvedValue({
      schema_version: 1,
      projects: [contextProject],
    });
    mockLocalProjectContext.inspect.mockResolvedValue({
      schema_version: 1,
      state: 'confirmed',
      manifest: fixture.manifest,
    });
    mockLocalProjectContext.listCandidates.mockResolvedValue({
      schema_version: 1,
      project_id: CONTEXT_PROJECT_ID,
      candidates: [
        {
          path: 'SECRET_A.ts',
          size: 10,
          revision: 'a'.repeat(40),
          git_state: 'unchanged',
          eligible: true,
          omission_reason: null,
        },
      ],
      next_cursor: null,
    });
    const renderer = await renderAppOpeningStoredConversation();
    const root = renderer.root;
    await act(async () =>
      root.findByProps({ testID: 'project-context-strip' }).props.onPress(),
    );
    await act(async () =>
      visibleContextSheets(root)[0]!.props.onRefreshCandidates(),
    );
    await act(async () => {
      jest.advanceTimersByTime(180);
      await settle();
    });
    expect(visibleContextSheets(root)[0]?.props.candidates).toHaveLength(1);
    mockLocalProjectContext.inspect.mockRejectedValueOnce({
      code: 'E_CONTEXT_TIMEOUT',
    });
    await act(async () =>
      visibleContextSheets(root)[0]!.props.onRefreshContext(),
    );
    await act(async () => settle());
    expect(root.findByProps({ children: 'Error' })).toBeDefined();
    await act(async () => visibleContextSheets(root)[0]!.props.onClose());
    await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
    await act(async () =>
      actionByLabel(root, 'Open chat Project B').props.onPress(),
    );
    await act(async () =>
      root.findByProps({ testID: 'project-context-strip' }).props.onPress(),
    );

    const sheetB = visibleContextSheets(root)[0]!;
    expect(sheetB.props.candidates).toEqual([]);
    expect(sheetB.props.selectedCandidates).toEqual([]);
    expect(sheetB.props.errorCode).toBeNull();
    expect(sheetB.props.checking).toBe(true);
    expect(root.findAllByProps({ children: 'Error' })).toHaveLength(0);
    expect(root.findAllByProps({ children: 'Recovery required' })).toHaveLength(
      0,
    );
    expect(
      root.findByProps({ accessibilityLabel: 'Message DSH' }).props.editable,
    ).toBe(true);
    mockLocalRuntime.completeV2.mockImplementationOnce(
      async (request: StrictCompletionRequest) => ({
        ...strictCompletionResult(request, { text: 'B retry completed' }),
        project_context_receipt: {
          schema_version: 1,
          snapshot_id: CONTEXT_SNAPSHOT_ID,
          snapshot_sha256: fixture.manifest.snapshot_sha256,
          source_fingerprint: fixture.manifest.source_fingerprint,
          context_bytes: fixture.manifest.context_bytes,
          verified_at: '2026-08-28T00:00:03.000Z',
        },
      }),
    );
    mockLocalProjectContext.inspect.mockClear();
    mockLocalProjectContext.inspect.mockResolvedValue({
      schema_version: 1,
      state: 'confirmed',
      manifest: fixture.manifest,
    });
    await act(async () => visibleContextSheets(root)[0]!.props.onClose());

    await act(async () =>
      actionByLabel(root, 'Retry response').props.onPress(),
    );
    await act(async () => settle());
    expect(mockLocalProjectContext.inspect).toHaveBeenCalledTimes(1);
    expect(root.findByProps({ children: 'Ready' })).toBeDefined();
    jest.useRealTimers();
  });

  test('lets an unmounted pending search settle once without React updates', async () => {
    jest.useFakeTimers();
    mockLocalProjects.list.mockResolvedValue({
      schema_version: 1,
      projects: [contextProject],
    });
    const renderer = await renderApp();
    const root = renderer.root;
    await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
    await act(async () => {
      actionByLabel(root, 'Projects').props.onPress();
      await settle();
    });
    await act(async () => {
      actionByLabel(root, `Open project ${contextProject.name}`).props.onPress();
      await settle();
    });
    await act(async () => {
      await actionByLabel(root, 'Chat in this project').props.onPress();
      await settle();
    });
    expect(mockLocalProjectContext.listCandidates).not.toHaveBeenCalled();
    const consoleError = jest
      .spyOn(console, 'error')
      .mockImplementation(() => undefined);

    await act(async () => renderer.unmount());
    await act(async () => {
      jest.advanceTimersByTime(180);
      await settle();
    });

    expect(mockLocalProjectContext.listCandidates).toHaveBeenCalledTimes(1);
    expect(
      consoleError.mock.calls.some(call =>
        call.some(value =>
          String(value).includes('not wrapped in act'),
        ),
      ),
    ).toBe(false);
    consoleError.mockRestore();
    jest.useRealTimers();
  });

  test('coalesces rapid project Chat transitions into one authority bind', async () => {
    jest.useFakeTimers();
    const firstPersist = deferred<boolean>();
    mockSessionSnapshots.casPersistSession
      .mockImplementationOnce(async request => {
        await firstPersist.promise;
        return commitBridgedCandidate(request);
      })
      .mockImplementation(async request => commitBridgedCandidate(request));
    mockLocalProjects.list.mockResolvedValue({
      schema_version: 1,
      projects: [contextProject],
    });
    const renderer = await renderApp();
    const root = renderer.root;
    await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
    await act(async () => {
      actionByLabel(root, 'Projects').props.onPress();
      await settle();
    });
    await act(async () => {
      actionByLabel(root, `Open project ${contextProject.name}`).props.onPress();
      await settle();
    });
    const chat = root.findByType(ProjectsSurface).props.onChatInProject;
    let firstChat: Promise<void> | undefined;

    await act(async () => {
      firstChat = chat(contextProject);
      chat(contextProject);
      await settle();
    });
    expect(mockSessionSnapshots.casPersistSession).toHaveBeenCalledTimes(1);
    firstPersist.resolve(true);
    await act(async () => {
      await firstChat;
      await settle();
    });
    expect(mockLocalWorkspaces.bootstrapLegacyProject).toHaveBeenCalledTimes(1);
    expect(mockSessionSnapshots.casPersistSession).toHaveBeenCalledTimes(1);
    jest.useRealTimers();
  });

  test('keeps the project transition lock until Projects onDismiss consumes it', async () => {
    jest.useFakeTimers();
    mockLocalProjects.list.mockResolvedValue({
      schema_version: 1,
      projects: [contextProject],
    });
    const renderer = await renderApp();
    const root = renderer.root;
    await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
    await act(async () => {
      actionByLabel(root, 'Projects').props.onPress();
      await settle();
    });
    await act(async () => {
      actionByLabel(root, `Open project ${contextProject.name}`).props.onPress();
      await settle();
    });
    const chat = root.findByType(ProjectsSurface).props.onChatInProject;

    await act(async () => {
      await chat(contextProject);
      chat(contextProject);
      expect(mockSessionSnapshots.casPersistSession).toHaveBeenCalledTimes(1);
    });
    expect(mockSessionSnapshots.casPersistSession).toHaveBeenCalledTimes(1);
    expect(visibleContextSheets(root)).toHaveLength(1);
    await act(async () => {
      jest.advanceTimersByTime(180);
      await settle();
    });
    jest.useRealTimers();
  });

  test('rejects an old Sheet callback after close and reopen with the same owner', async () => {
    const fixture = storedProjectContext(true);
    queuePresentSession(fixture.stored.serialize());
    mockLocalProjects.list.mockResolvedValue({
      schema_version: 1,
      projects: [contextProject],
    });
    mockLocalProjectContext.inspect.mockResolvedValue({
      schema_version: 1,
      state: 'confirmed',
      manifest: fixture.manifest,
    });
    const renderer = await renderAppOpeningStoredConversation();
    const root = renderer.root;
    await act(async () =>
      root.findByProps({ testID: 'project-context-strip' }).props.onPress(),
    );
    const oldRefresh = visibleContextSheets(root)[0]!.props.onRefreshContext;
    await act(async () => visibleContextSheets(root)[0]!.props.onClose());
    await act(async () =>
      root.findByProps({ testID: 'project-context-strip' }).props.onPress(),
    );
    mockLocalProjectContext.inspect.mockClear();

    await act(async () => oldRefresh());
    await act(async () => settle());
    expect(mockLocalProjectContext.inspect).not.toHaveBeenCalled();
  });

  test('keeps the current Sheet callbacks live after a duplicate Strip press', async () => {
    const fixture = storedProjectContext(true);
    queuePresentSession(fixture.stored.serialize());
    mockLocalProjects.list.mockResolvedValue({
      schema_version: 1,
      projects: [contextProject],
    });
    mockLocalProjectContext.inspect.mockResolvedValue({
      schema_version: 1,
      state: 'confirmed',
      manifest: fixture.manifest,
    });
    const renderer = await renderAppOpeningStoredConversation();
    const root = renderer.root;
    await act(async () =>
      root.findByProps({ testID: 'project-context-strip' }).props.onPress(),
    );
    const sheet = visibleContextSheets(root)[0]!;
    const actionKey = sheet.props.actionKey;
    const refresh = sheet.props.onRefreshContext;

    await act(async () =>
      root.findByProps({ testID: 'project-context-strip' }).props.onPress(),
    );
    expect(visibleContextSheets(root)[0]?.props.actionKey).toBe(actionKey);
    mockLocalProjectContext.inspect.mockClear();
    await act(async () => refresh());
    await act(async () => settle());
    expect(mockLocalProjectContext.inspect).toHaveBeenCalledTimes(1);
  });

  test('returns accessibility focus to the Strip only after Sheet dismissal', async () => {
    const fixture = storedProjectContext(true);
    queuePresentSession(fixture.stored.serialize());
    mockLocalProjects.list.mockResolvedValue({
      schema_version: 1,
      projects: [contextProject],
    });
    mockLocalProjectContext.inspect.mockResolvedValue({
      schema_version: 1,
      state: 'confirmed',
      manifest: fixture.manifest,
    });
    const focus = jest
      .spyOn(AccessibilityInfo, 'setAccessibilityFocus')
      .mockImplementation(() => undefined);
    const renderer = await renderAppOpeningStoredConversation();
    const root = renderer.root;
    await act(async () =>
      root.findByProps({ testID: 'project-context-strip-focus-target' }).props.onLayout({
        target: 77,
        nativeEvent: { layout: { x: 0, y: 0, width: 320, height: 44 } },
      }),
    );
    await act(async () =>
      root.findByProps({ testID: 'project-context-strip' }).props.onPress(),
    );
    const beforeClose = focus.mock.calls.length;
    const close = visibleContextSheets(root)[0]!.props.onClose;

    act(() => {
      close();
      expect(focus).toHaveBeenCalledTimes(beforeClose);
    });
    expect(visibleContextSheets(root)).toHaveLength(0);
    expect(focus).toHaveBeenCalledTimes(beforeClose + 1);
    focus.mockRestore();
  });

  test('stops a confirmed project image send after Vision invalidates context', async () => {
    jest.useFakeTimers();
    const fixture = storedProjectContext(true, 'deepseek-v4-pro');
    queuePresentSession(fixture.stored.serialize());
    mockLocalProjects.list.mockResolvedValue({
      schema_version: 1,
      projects: [contextProject],
    });
    mockLocalProjectContext.inspect
      .mockResolvedValueOnce({
        schema_version: 1,
        state: 'confirmed',
        manifest: fixture.manifest,
      })
      .mockRejectedValueOnce({ code: 'E_CONTEXT_TIMEOUT' });
    mockLocalAttachments.present.mockResolvedValueOnce({
      schema_version: 1,
      status: 'selected',
      attachments: [
        {
          schema_version: 1,
          id: 'project-image-1',
          kind: 'image',
          name: 'project.png',
          mime_type: 'image/png',
          size: 128,
          thumbnail_data_url: 'data:image/png;base64,AAAA',
        },
      ],
    });
    const renderer = await renderAppOpeningStoredConversation();
    const root = renderer.root;
    await act(async () => actionByLabel(root, 'Add attachment').props.onPress());
    await chooseAttachmentSource(root, 'Photos');

    await act(async () => actionByLabel(root, 'Send message').props.onPress());
    await act(async () => settle());

    expect(mockLocalRuntime.completeV2).not.toHaveBeenCalled();
    expect(mockLocalRuntime.complete).not.toHaveBeenCalled();
    expect(root.findByType(ChatComposer).props.attachments).toEqual([
      expect.objectContaining({ id: 'project-image-1' }),
    ]);
    expect(
      lastPersistedState().conversations.find(
        conversation => conversation.project_id === CONTEXT_PROJECT_ID,
      )?.model_id,
    ).toBe('deepseek-v4-flash');
    expect(visibleContextSheets(root)[0]?.props.mode).toBe('recovery');
    expect(visibleContextSheets(root)[0]?.props.disabled).toBe(true);
    await act(async () => {
      jest.advanceTimersByTime(3000);
      await settle();
    });
    jest.useRealTimers();
  });
});

describe('project context Home integration H2', () => {
  test('keeps explicit fallback and Cancel available when native context is unavailable', async () => {
    mockLocalProjectContext.isAvailable.mockReturnValue(false);
    const renderer = await renderSetupProjectApp();
    const root = renderer.root;
    await enterPendingProjectRecovery(root, 'Fallback without native context');

    const refresh = actionByLabel(root, 'Refresh and send');
    const sendWithout = actionByLabel(root, 'Send without project context');
    const cancel = actionByLabel(root, 'Cancel');
    expect(refresh.props.disabled).toBe(true);
    expect(sendWithout.props.disabled).toBe(false);
    expect(cancel.props.disabled).toBe(false);

    await act(async () => refresh.props.onPress());
    expect(mockLocalProjectContext.listCandidates).not.toHaveBeenCalled();
    expect(mockLocalRuntime.completeV2).not.toHaveBeenCalled();
  });

  test('freezes a raw setup draft and attachment into explicit recovery with zero HTTP', async () => {
    mockLocalAttachments.present.mockResolvedValueOnce({
      schema_version: 1,
      status: 'selected',
      attachments: [
        {
          schema_version: 1,
          id: 'pending-file-1',
          kind: 'text',
          name: 'notes.txt',
          mime_type: 'text/plain',
          size: 12,
        },
      ],
    });
    const renderer = await renderSetupProjectApp();
    const root = renderer.root;
    await act(async () => actionByLabel(root, 'Add attachment').props.onPress());
    await chooseAttachmentSource(root, 'Files');

    await enterPendingProjectRecovery(root, '  raw setup request  ');

    const sheet = visibleContextSheets(root)[0];
    expect(sheet?.props.mode).toBe('recovery');
    for (const label of [
      'Refresh and send',
      'Send without project context',
      'Cancel',
    ]) {
      expect(actionByLabel(root, label)).toBeDefined();
    }
    expect(
      root.findAllByProps({ accessibilityLabel: 'Prepare context' }),
    ).toHaveLength(0);
    expect(
      root.findByProps({ accessibilityLabel: 'Message DSH' }).props.value,
    ).toBe('  raw setup request  ');
    expect(root.findByType(ChatComposer).props.attachments).toEqual([
      expect.objectContaining({ id: 'pending-file-1', name: 'notes.txt' }),
    ]);
    expect(mockLocalRuntime.completeV2).not.toHaveBeenCalled();
    expect(mockLocalRuntime.complete).not.toHaveBeenCalled();
    expect(mockSessionSnapshots.casPersistSession).not.toHaveBeenCalled();
  });

  test('recovery Cancel clears only the pending intent and preserves the draft', async () => {
    const renderer = await renderSetupProjectApp();
    const root = renderer.root;
    await enterPendingProjectRecovery(root, 'Keep after cancel');
    expect(visibleContextSheets(root)[0]?.props.mode).toBe('recovery');

    await act(async () => actionByLabel(root, 'Cancel').props.onPress());
    expect(visibleContextSheets(root)).toHaveLength(0);
    expect(
      root.findByProps({ accessibilityLabel: 'Message DSH' }).props.value,
    ).toBe('Keep after cancel');
    expect(mockLocalRuntime.completeV2).not.toHaveBeenCalled();

    await act(async () =>
      root.findByProps({ testID: 'project-context-strip' }).props.onPress(),
    );
    expect(visibleContextSheets(root)[0]?.props.mode).toBe('candidates');
  });

  test('top close preserves pending recovery but any edit invalidates it permanently', async () => {
    const renderer = await renderSetupProjectApp();
    const root = renderer.root;
    await enterPendingProjectRecovery(root, 'same text');
    await act(async () => visibleContextSheets(root)[0]!.props.onClose());
    expect(visibleContextSheets(root)).toHaveLength(0);
    expect(mockLocalRuntime.completeV2).not.toHaveBeenCalled();

    await act(async () =>
      root.findByProps({ testID: 'project-context-strip' }).props.onPress(),
    );
    expect(visibleContextSheets(root)[0]?.props.mode).toBe('recovery');
    await act(async () => visibleContextSheets(root)[0]!.props.onClose());
    await act(async () =>
      root
        .findByProps({ accessibilityLabel: 'Message DSH' })
        .props.onChangeText('changed text'),
    );
    await act(async () =>
      root
        .findByProps({ accessibilityLabel: 'Message DSH' })
        .props.onChangeText('same text'),
    );
    await act(async () =>
      root.findByProps({ testID: 'project-context-strip' }).props.onPress(),
    );
    expect(visibleContextSheets(root)[0]?.props.mode).toBe('candidates');
    expect(mockLocalRuntime.completeV2).not.toHaveBeenCalled();
  });

  test('invalidates closed pending recovery when an EmptyChat suggestion changes the draft', async () => {
    const renderer = await renderSetupProjectApp();
    const root = renderer.root;
    await enterPendingProjectRecovery(root, 'pending suggestion');
    await act(async () => visibleContextSheets(root)[0]!.props.onClose());
    await act(async () =>
      root.findByType(EmptyChat).props.onSuggestion('Use this suggestion'),
    );
    await act(async () =>
      root.findByProps({ testID: 'project-context-strip' }).props.onPress(),
    );

    expect(visibleContextSheets(root)[0]?.props.mode).toBe('candidates');
    expect(mockLocalRuntime.completeV2).not.toHaveBeenCalled();
  });

  test('invalidates a closed pending send before reusing the empty chat for another project', async () => {
    jest.useFakeTimers();
    const secondProject = {
      ...contextProject,
      id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
      name: 'second-project',
      workspace_path:
        'projects/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb/repo',
    };
    const fixture = storedSetupProject();
    queuePresentSession(fixture.stored.serialize());
    mockLocalProjects.list.mockResolvedValue({
      schema_version: 1,
      projects: [contextProject, secondProject],
    });
    const renderer = await renderAppOpeningStoredConversation();
    const root = renderer.root;
    await enterPendingProjectRecovery(root, 'Do not move this intent');
    const oldSheet = visibleContextSheets(root)[0]!;
    const staleSendWithout = oldSheet.props.onSendWithoutContext;
    const staleDismiss = oldSheet.props.onDismiss;
    await act(async () => oldSheet.props.onClose());

    await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
    await act(async () => {
      actionByLabel(root, 'Projects').props.onPress();
      await settle();
    });

    await act(async () => {
      await root.findByType(ProjectsSurface).props.onChatInProject(secondProject);
      await settle();
    });
    await act(async () => root.findByType(ProjectsSurface).props.onDismiss());

    expect(visibleContextSheets(root)[0]?.props.mode).toBe('candidates');
    await act(async () => staleSendWithout());
    await act(async () => staleDismiss());
    expect(mockLocalRuntime.completeV2).not.toHaveBeenCalled();
    await act(async () => {
      jest.advanceTimersByTime(180);
      await settle();
    });
    jest.useRealTimers();
  });

  test('invalidates pending recovery when attachment ID order changes', async () => {
    mockLocalAttachments.present.mockResolvedValueOnce({
      schema_version: 1,
      status: 'selected',
      attachments: [
        {
          schema_version: 1,
          id: 'ordered-a',
          kind: 'text',
          name: 'a.txt',
          mime_type: 'text/plain',
          size: 1,
        },
        {
          schema_version: 1,
          id: 'ordered-b',
          kind: 'text',
          name: 'b.txt',
          mime_type: 'text/plain',
          size: 1,
        },
      ],
    });
    const renderer = await renderSetupProjectApp();
    const root = renderer.root;
    await act(async () => actionByLabel(root, 'Add attachment').props.onPress());
    await chooseAttachmentSource(root, 'Files');
    await enterPendingProjectRecovery(root, 'Attachment ownership');
    await act(async () => visibleContextSheets(root)[0]!.props.onClose());

    await act(async () =>
      actionByLabel(root, 'Remove a.txt').props.onPress({
        stopPropagation: jest.fn(),
      }),
    );
    await act(async () =>
      root.findByProps({ testID: 'project-context-strip' }).props.onPress(),
    );
    expect(visibleContextSheets(root)[0]?.props.mode).toBe('candidates');
    expect(mockLocalRuntime.completeV2).not.toHaveBeenCalled();
  });

  test('sends without context exactly once and only after Sheet dismissal', async () => {
    const renderer = await renderSetupProjectApp();
    const root = renderer.root;
    await enterPendingProjectRecovery(root, '  explicit raw text  ');
    const sheet = visibleContextSheets(root)[0]!;
    const sendWithout = sheet.props.onSendWithoutContext;
    const dismiss = sheet.props.onDismiss;
    const staleSend = actionByLabel(root, 'Send message').props.onPress;

    act(() => {
      sendWithout();
      staleSend();
      expect(mockLocalRuntime.completeV2).not.toHaveBeenCalled();
    });
    await act(async () => settle());
    expect(mockLocalRuntime.completeV2).toHaveBeenCalledTimes(1);
    expect(mockLocalRuntime.completeV2).toHaveBeenCalledWith(
      expect.objectContaining({
        schemaVersion: 2,
        projectContext: null,
        visibleHistory: [
          expect.objectContaining({ content: '  explicit raw text  ' }),
        ],
      }),
      'dsh',
    );
    await act(async () => sendWithout());
    await act(async () => dismiss());
    expect(mockLocalRuntime.completeV2).toHaveBeenCalledTimes(1);
    const persisted = lastPersistedState().conversations.find(
      conversation => conversation.project_id === CONTEXT_PROJECT_ID,
    );
    expect(persisted?.attempts?.at(-1)).toMatchObject({
      status: 'completed',
      context_disposition: 'explicit_without_context',
      project_context: null,
    });
  });

  test('refreshes through explicit selection and confirmation, then sends schema3 after dismissal', async () => {
    jest.useFakeTimers();
    const manifest = contextManifest();
    mockLocalProjectContext.listCandidates.mockResolvedValue({
      schema_version: 1,
      project_id: CONTEXT_PROJECT_ID,
      candidates: [
        {
          path: 'README.md',
          size: 16,
          revision: 'f'.repeat(40),
          git_state: 'unchanged',
          eligible: true,
          omission_reason: null,
        },
      ],
      next_cursor: null,
    });
    mockLocalProjectContext.prepare.mockResolvedValue(manifest);
    mockLocalProjectContext.confirm.mockResolvedValue({
      schema_version: 1,
      consent_receipt_id: CONTEXT_CONSENT_ID,
      snapshot_id: CONTEXT_SNAPSHOT_ID,
      snapshot_sha256: manifest.snapshot_sha256,
      confirmed_at: '2026-08-28T00:00:01.000Z',
    });
    mockLocalRuntime.completeV2.mockImplementationOnce(
      async (request: StrictCompletionRequest) => ({
        ...strictCompletionResult(request, { text: 'Context answer' }),
        project_context_receipt: {
          schema_version: 1,
          snapshot_id: CONTEXT_SNAPSHOT_ID,
          snapshot_sha256: manifest.snapshot_sha256,
          source_fingerprint: manifest.source_fingerprint,
          context_bytes: manifest.context_bytes,
          verified_at: '2026-08-28T00:00:02.000Z',
        },
      }),
    );
    const renderer = await renderSetupProjectApp();
    const root = renderer.root;
    await enterPendingProjectRecovery(root, 'Use confirmed context');
    await act(async () =>
      actionByLabel(root, 'Refresh and send').props.onPress(),
    );
    await act(async () => {
      jest.advanceTimersByTime(180);
      await settle();
    });
    expect(visibleContextSheets(root)[0]?.props.mode).toBe('candidates');
    await act(async () =>
      root
        .findByProps({ testID: 'project-context-candidate-README.md' })
        .props.onPress(),
    );
    await act(async () => {
      actionByLabel(root, 'Prepare context').props.onPress();
      await settle();
      await settle();
    });
    expect(visibleContextSheets(root)[0]?.props.confirmationRequired).toBe(true);
    const confirm = actionByLabel(root, 'Confirm context').props.onPress;
    act(() => {
      confirm();
      expect(mockLocalRuntime.completeV2).not.toHaveBeenCalled();
    });
    await act(async () => {
      await settle();
      await settle();
    });
    expect(mockLocalRuntime.completeV2).toHaveBeenCalledTimes(1);
    expect(mockLocalRuntime.completeV2).toHaveBeenCalledWith(
      expect.objectContaining({
        schemaVersion: 3,
        projectContext: expect.objectContaining({
          snapshotId: CONTEXT_SNAPSHOT_ID,
          consentReceiptId: CONTEXT_CONSENT_ID,
          projectId: CONTEXT_PROJECT_ID,
        }),
      }),
      'dsh',
    );
    await act(async () => confirm());
    expect(mockLocalRuntime.completeV2).toHaveBeenCalledTimes(1);
    expect(
      root.findByProps({ accessibilityLabel: 'Message DSH' }).props.value,
    ).toBe('');
    jest.useRealTimers();
  });

  test('waits for confirmed-context persistence retry before dismissing and sending', async () => {
    jest.useFakeTimers();
    const manifest = contextManifest();
    mockLocalProjectContext.listCandidates.mockResolvedValue({
      schema_version: 1,
      project_id: CONTEXT_PROJECT_ID,
      candidates: [
        {
          path: 'README.md',
          size: 16,
          revision: 'f'.repeat(40),
          git_state: 'unchanged',
          eligible: true,
          omission_reason: null,
        },
      ],
      next_cursor: null,
    });
    mockLocalProjectContext.prepare.mockResolvedValue(manifest);
    mockLocalProjectContext.confirm.mockResolvedValue({
      schema_version: 1,
      consent_receipt_id: CONTEXT_CONSENT_ID,
      snapshot_id: CONTEXT_SNAPSHOT_ID,
      snapshot_sha256: manifest.snapshot_sha256,
      confirmed_at: '2026-08-28T00:00:01.000Z',
    });
    mockLocalRuntime.completeV2.mockImplementationOnce(
      async (request: StrictCompletionRequest) => ({
        ...strictCompletionResult(request, { text: 'Retried persistence answer' }),
        project_context_receipt: {
          schema_version: 1,
          snapshot_id: CONTEXT_SNAPSHOT_ID,
          snapshot_sha256: manifest.snapshot_sha256,
          source_fingerprint: manifest.source_fingerprint,
          context_bytes: manifest.context_bytes,
          verified_at: '2026-08-28T00:00:02.000Z',
        },
      }),
    );
    const renderer = await renderSetupProjectApp();
    const root = renderer.root;
    await enterPendingProjectRecovery(root, 'Persist before sending');
    await preparePendingProjectDisclosure(root);
    let candidate = '';
    mockSessionSnapshots.casPersistSession.mockImplementationOnce(async request => {
      candidate = request.candidate_json;
      const digest = sessionSnapshotSHA256(candidate)!;
      return {
        schema_version: 1,
        status: 'session_only',
        current: {
          schema_version: 1,
          kind: 'present',
          snapshot: {
            schema_version: 1,
            generation: 1,
            session_sha256: digest,
          },
        },
      };
    });

    await act(async () => {
      actionByLabel(root, 'Confirm context').props.onPress();
      await settle();
      await settle();
    });
    expect(mockLocalRuntime.completeV2).not.toHaveBeenCalled();
    expect(visibleContextSheets(root)[0]?.props.recoveryAction).toBe(
      'persistence',
    );
    expect(actionByLabel(root, 'Retry save')).toBeDefined();

    await act(async () => {
      actionByLabel(root, 'Retry save').props.onPress();
      await settle();
      await settle();
    });
    expect(mockLocalRuntime.completeV2).toHaveBeenCalledTimes(1);
    expect(visibleContextSheets(root)).toHaveLength(0);
    jest.useRealTimers();
  });

  test('keeps recovery disclosure and draft when native confirmation rejects', async () => {
    jest.useFakeTimers();
    const manifest = contextManifest();
    mockLocalProjectContext.listCandidates.mockResolvedValue({
      schema_version: 1,
      project_id: CONTEXT_PROJECT_ID,
      candidates: [
        {
          path: 'README.md',
          size: 16,
          revision: 'f'.repeat(40),
          git_state: 'unchanged',
          eligible: true,
          omission_reason: null,
        },
      ],
      next_cursor: null,
    });
    mockLocalProjectContext.prepare.mockResolvedValue(manifest);
    mockLocalProjectContext.confirm.mockRejectedValueOnce({
      code: 'E_CONTEXT_TIMEOUT',
      message: 'RAW_CONFIRM_SENTINEL',
    });
    const renderer = await renderSetupProjectApp();
    const root = renderer.root;
    await enterPendingProjectRecovery(root, 'Keep after confirm failure');
    await preparePendingProjectDisclosure(root);

    await act(async () => {
      actionByLabel(root, 'Confirm context').props.onPress();
      await settle();
    });
    expect(visibleContextSheets(root)).toHaveLength(1);
    expect(
      root.findByProps({ accessibilityLabel: 'Message DSH' }).props.value,
    ).toBe('Keep after confirm failure');
    expect(mockLocalRuntime.completeV2).not.toHaveBeenCalled();
    expect(
      root.findAll(node =>
        Object.values(node.props).some(
          value =>
            typeof value === 'string' &&
            value.includes('RAW_CONFIRM_SENTINEL'),
        ),
      ),
    ).toHaveLength(0);
    jest.useRealTimers();
  });

  test('consumes a preserved pending intent before direct send after a hidden confirmation completes', async () => {
    jest.useFakeTimers();
    const manifest = contextManifest();
    const confirmation = deferred<{
      schema_version: 1;
      consent_receipt_id: string;
      snapshot_id: string;
      snapshot_sha256: string;
      confirmed_at: string;
    }>();
    mockLocalProjectContext.listCandidates.mockResolvedValue({
      schema_version: 1,
      project_id: CONTEXT_PROJECT_ID,
      candidates: [
        {
          path: 'README.md',
          size: 16,
          revision: 'f'.repeat(40),
          git_state: 'unchanged',
          eligible: true,
          omission_reason: null,
        },
      ],
      next_cursor: null,
    });
    mockLocalProjectContext.prepare.mockResolvedValue(manifest);
    mockLocalProjectContext.confirm.mockReturnValueOnce(confirmation.promise);
    mockLocalRuntime.completeV2.mockImplementationOnce(
      async (request: StrictCompletionRequest) => ({
        ...strictCompletionResult(request),
        project_context_receipt: {
          schema_version: 1,
          snapshot_id: CONTEXT_SNAPSHOT_ID,
          snapshot_sha256: manifest.snapshot_sha256,
          source_fingerprint: manifest.source_fingerprint,
          context_bytes: manifest.context_bytes,
          verified_at: '2026-08-28T00:00:02.000Z',
        },
      }),
    );
    const renderer = await renderSetupProjectApp();
    const root = renderer.root;
    await enterPendingProjectRecovery(root, 'Confirm while hidden');
    await preparePendingProjectDisclosure(root);

    await act(async () =>
      actionByLabel(root, 'Confirm context').props.onPress(),
    );
    await act(async () => visibleContextSheets(root)[0]!.props.onClose());
    confirmation.resolve({
      schema_version: 1,
      consent_receipt_id: CONTEXT_CONSENT_ID,
      snapshot_id: CONTEXT_SNAPSHOT_ID,
      snapshot_sha256: manifest.snapshot_sha256,
      confirmed_at: '2026-08-28T00:00:01.000Z',
    });
    await act(async () => {
      await settle();
      await settle();
    });
    expect(mockLocalRuntime.completeV2).not.toHaveBeenCalled();

    await act(async () => {
      actionByLabel(root, 'Send message').props.onPress();
      await settle();
      await settle();
    });
    expect(mockLocalRuntime.completeV2).toHaveBeenCalledTimes(1);
    await act(async () =>
      root.findByProps({ testID: 'project-context-strip' }).props.onPress(),
    );
    expect(visibleContextSheets(root)[0]?.props.mode).toBe('disclosure');
    await act(async () => visibleContextSheets(root)[0]!.props.onDismiss());
    expect(mockLocalRuntime.completeV2).toHaveBeenCalledTimes(1);
    jest.useRealTimers();
  });

  test('does not clear a newly edited draft when prepared durability resolves', async () => {
    jest.useFakeTimers();
    const manifest = contextManifest();
    mockLocalProjectContext.listCandidates.mockResolvedValue({
      schema_version: 1,
      project_id: CONTEXT_PROJECT_ID,
      candidates: [
        {
          path: 'README.md',
          size: 16,
          revision: 'f'.repeat(40),
          git_state: 'unchanged',
          eligible: true,
          omission_reason: null,
        },
      ],
      next_cursor: null,
    });
    mockLocalProjectContext.prepare.mockResolvedValue(manifest);
    mockLocalProjectContext.confirm.mockResolvedValue({
      schema_version: 1,
      consent_receipt_id: CONTEXT_CONSENT_ID,
      snapshot_id: CONTEXT_SNAPSHOT_ID,
      snapshot_sha256: manifest.snapshot_sha256,
      confirmed_at: '2026-08-28T00:00:01.000Z',
    });
    mockLocalRuntime.completeV2.mockImplementationOnce(
      async (request: StrictCompletionRequest) => ({
        ...strictCompletionResult(request, { text: 'Raw equality answer' }),
        project_context_receipt: {
          schema_version: 1,
          snapshot_id: CONTEXT_SNAPSHOT_ID,
          snapshot_sha256: manifest.snapshot_sha256,
          source_fingerprint: manifest.source_fingerprint,
          context_bytes: manifest.context_bytes,
          verified_at: '2026-08-28T00:00:02.000Z',
        },
      }),
    );
    const completionPersist = deferred<boolean>();
    const renderer = await renderSetupProjectApp();
    const root = renderer.root;
    await enterPendingProjectRecovery(root, '  raw  ');
    await preparePendingProjectDisclosure(root);
    mockSessionSnapshots.casPersistSession.mockImplementation(async request => {
      const decoded = JSON.parse(request.candidate_json) as {
        conversations: Array<{ attempts?: unknown[] }>;
      };
      return decoded.conversations.some(
        conversation => (conversation.attempts?.length ?? 0) > 0,
      )
        ? (await completionPersist.promise,
          commitBridgedCandidate(request))
        : commitBridgedCandidate(request);
    });

    await act(async () => {
      actionByLabel(root, 'Confirm context').props.onPress();
      await settle();
      await settle();
    });
    expect(mockLocalRuntime.completeV2).not.toHaveBeenCalled();
    await act(async () =>
      root
        .findByProps({ accessibilityLabel: 'Message DSH' })
        .props.onChangeText('raw'),
    );
    completionPersist.resolve(true);
    await act(async () => {
      await settle();
      await settle();
    });

    expect(
      root.findByProps({ accessibilityLabel: 'Message DSH' }).props.value,
    ).toBe('raw');
    jest.useRealTimers();
  });

  test('copies pending text and attachment metadata before explicit schema2 send', async () => {
    const selectedAttachment = {
      schema_version: 1,
      id: 'immutable-file-1',
      kind: 'text',
      name: 'original.txt',
      mime_type: 'text/plain',
      size: 12,
      thumbnail_data_url: 'data:image/png;base64,RAW_PENDING_SENTINEL',
    } as const;
    mockLocalAttachments.present.mockResolvedValueOnce({
      schema_version: 1,
      status: 'selected',
      attachments: [selectedAttachment],
    });
    const renderer = await renderSetupProjectApp();
    const root = renderer.root;
    await act(async () => actionByLabel(root, 'Add attachment').props.onPress());
    await chooseAttachmentSource(root, 'Files');
    await enterPendingProjectRecovery(root, '  immutable raw text  ');
    const liveAttachment = root.findByType(ChatComposer).props.attachments[0] as {
      name: string;
    };
    liveAttachment.name = 'MUTATED.txt';

    await act(async () =>
      actionByLabel(root, 'Send without project context').props.onPress(),
    );
    await act(async () => settle());
    const request = mockLocalRuntime.completeV2.mock.calls[0]?.[0] as {
      visibleHistory: Array<{
        content: string;
        attachments: Array<{ name: string }>;
      }>;
    };
    expect(request.visibleHistory[0]).toEqual(
      expect.objectContaining({
        content: '  immutable raw text  ',
        attachments: [expect.objectContaining({ name: 'original.txt' })],
      }),
    );
    expect(request.visibleHistory[0]?.attachments[0]).not.toHaveProperty(
      'thumbnail_data_url',
    );
    expect(JSON.stringify(request)).not.toContain('RAW_PENDING_SENTINEL');
  });

  test('locks Send without a fake Stop while native context preparation is active', async () => {
    jest.useFakeTimers();
    const manifest = contextManifest();
    const preparation = deferred<ProjectContextManifestV1>();
    mockLocalProjectContext.listCandidates.mockResolvedValue({
      schema_version: 1,
      project_id: CONTEXT_PROJECT_ID,
      candidates: [
        {
          path: 'README.md',
          size: 16,
          revision: 'f'.repeat(40),
          git_state: 'unchanged',
          eligible: true,
          omission_reason: null,
        },
      ],
      next_cursor: null,
    });
    mockLocalProjectContext.prepare.mockReturnValueOnce(preparation.promise);
    const renderer = await renderSetupProjectApp();
    const root = renderer.root;
    await enterPendingProjectRecovery(root, 'Locked while preparing');
    await act(async () =>
      actionByLabel(root, 'Refresh and send').props.onPress(),
    );
    await act(async () => {
      jest.advanceTimersByTime(180);
      await settle();
    });
    await act(async () =>
      root
        .findByProps({ testID: 'project-context-candidate-README.md' })
        .props.onPress(),
    );
    const staleSend = actionByLabel(root, 'Send message').props.onPress;
    await act(async () => actionByLabel(root, 'Prepare context').props.onPress());

    expect(actionByLabel(root, 'Send message').props.disabled).toBe(true);
    expect(
      root.findAllByProps({ accessibilityLabel: 'Stop response' }),
    ).toHaveLength(0);
    await act(async () => staleSend());
    expect(mockLocalRuntime.completeV2).not.toHaveBeenCalled();
    expect(visibleContextSheets(root)[0]?.props.mode).toBe('candidates');
    expect(visibleContextSheets(root)[0]?.props.busyAction).toBe('prepare');

    preparation.resolve(manifest);
    await act(async () => {
      await settle();
      await settle();
    });
    expect(visibleContextSheets(root)[0]?.props.mode).toBe('disclosure');
    expect(visibleContextSheets(root)[0]?.props.confirmationRequired).toBe(true);
    jest.useRealTimers();
  });
});

describe('project context Home integration H3', () => {
  test.each([
    ['intent', 1],
    ['cleanup_pending', 1],
    ['ready_to_finalize', 0],
  ] as const)(
    'resumes a hydrated %s lifecycle before normal Context attachment',
    async (phase, expectedDiscardCalls) => {
      const fixture = storedLifecycleCheckpoint(phase);
      queuePresentSession(fixture.stored.serialize());
      mockLocalProjectContext.inspect.mockResolvedValue({
        schema_version: 1,
        state: 'confirmed',
        manifest: fixture.manifest,
      });

      const renderer = await renderApp();
      await act(async () => {
        await settle();
        await settle();
      });

      expect(mockLocalProjectContext.inspect).not.toHaveBeenCalled();
      expect(mockLocalProjectContext.discard).toHaveBeenCalledTimes(
        expectedDiscardCalls,
      );
      const persisted = JSON.parse(
        lastPersistedCandidateJSON(),
      ) as {
        project_context_destructive_transition: unknown;
        conversations: Array<{
          id: string;
          project_id: string | null;
          project_context: unknown;
        }>;
      };
      expect(persisted.project_context_destructive_transition).toBeNull();
      expect(
        persisted.conversations.find(
          conversation => conversation.id === fixture.conversationId,
        ),
      ).toMatchObject({ project_id: null, project_context: null });
      expect(visibleContextSheets(renderer.root)).toHaveLength(0);
    },
  );

  test('restores cleanup recovery value-free when hydrated native discard fails', async () => {
    const fixture = storedLifecycleCheckpoint('cleanup_pending');
    queuePresentSession(fixture.stored.serialize());
    mockLocalProjectContext.discard.mockRejectedValueOnce({
      code: 'E_CONTEXT_TIMEOUT',
      message: 'RAW_RESTART_CLEANUP_SENTINEL',
    });

    const renderer = await renderApp();
    await act(async () => {
      await settle();
      await settle();
    });

    const sheet = visibleContextSheets(renderer.root)[0];
    expect(sheet?.props.mode).toBe('lifecycle');
    expect(sheet?.props.lifecycle).toMatchObject({
      kind: 'transition',
      action: 'unbind',
      controllerState: {
        phase: 'cleanup_pending',
        failureCode: 'E_CONTEXT_TIMEOUT',
      },
    });
    expect(mockLocalProjectContext.inspect).not.toHaveBeenCalled();
    expect(
      renderer.root.findAll(node =>
        Object.values(node.props).some(
          value =>
            typeof value === 'string' &&
            value.includes('RAW_RESTART_CLEANUP_SENTINEL'),
        ),
      ),
    ).toHaveLength(0);
  });

  test('keeps a restored journal visible when the native context bridge is unavailable', async () => {
    const fixture = storedLifecycleCheckpoint('cleanup_pending');
    queuePresentSession(fixture.stored.serialize());
    mockLocalProjectContext.isAvailable.mockReturnValue(false);
    mockLocalProjectContext.discard.mockRejectedValueOnce({
      code: 'E_CONTEXT_NATIVE',
      message: 'RAW_UNAVAILABLE_SENTINEL',
    });

    const renderer = await renderApp();
    await act(async () => {
      await settle();
      await settle();
    });

    const sheet = visibleContextSheets(renderer.root)[0];
    expect(sheet?.props.mode).toBe('lifecycle');
    expect(sheet?.props.unavailable).toBe(true);
    expect(sheet?.props.lifecycle).toMatchObject({
      kind: 'transition',
      action: 'unbind',
      controllerState: {
        phase: 'cleanup_pending',
        failureCode: 'E_CONTEXT_NATIVE',
      },
    });
    expect(mockLocalProjectContext.inspect).not.toHaveBeenCalled();
  });

  test('closes navigation and opens the blocking Context review before creating a new chat', async () => {
    const fixture = storedProjectContext(false);
    queuePresentSession(fixture.stored.serialize());
    mockLocalProjects.list.mockResolvedValue({
      schema_version: 1,
      projects: [contextProject],
    });
    mockLocalProjectContext.inspect.mockResolvedValueOnce({
      schema_version: 1,
      state: 'prepared',
      manifest: fixture.manifest,
    });
    const renderer = await renderAppOpeningStoredConversation();
    const root = renderer.root;
    await act(async () => settle());
    const originalConversationId = root.findByType(ChatDrawer).props.activeId;
    await act(async () => actionByLabel(root, 'Open navigation').props.onPress());

    await act(async () => {
      await root.findByType(ChatDrawer).props.onNewChat();
      root.findByType(ChatDrawer).props.onDismiss();
      await settle();
    });

    expect(root.findByType(ChatDrawer).props.visible).toBe(false);
    expect(root.findByType(ChatDrawer).props.activeId).toBe(
      originalConversationId,
    );
    expect(visibleContextSheets(root)).toHaveLength(1);
    expect(visibleContextSheets(root)[0]?.props.mode).toBe('disclosure');
    expect(visibleContextSheets(root)[0]?.props.confirmationRequired).toBe(true);
    expect(mockLocalRuntime.cancelCompletion).not.toHaveBeenCalled();
    expect(mockSessionSnapshots.casPersistSession).not.toHaveBeenCalled();
  });

  test('keeps an active confirmed snapshot conversation and opens lifecycle delete confirmation', async () => {
    let deletePromise: Promise<unknown> | undefined;
    const alert = jest
      .spyOn(Alert, 'alert')
      .mockImplementation((_title, _message, buttons) => {
        const destructive = buttons?.find(button => button.style === 'destructive');
        const result = destructive?.onPress?.();
        if (result !== undefined) deletePromise = Promise.resolve(result);
      });
    const fixture = storedProjectContext(true);
    queuePresentSession(fixture.stored.serialize());
    mockLocalProjects.list.mockResolvedValue({
      schema_version: 1,
      projects: [contextProject],
    });
    mockLocalProjectContext.inspect.mockResolvedValue({
      schema_version: 1,
      state: 'confirmed',
      manifest: fixture.manifest,
    });
    const renderer = await renderAppOpeningStoredConversation();
    const root = renderer.root;
    await act(async () => settle());
    await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
    await act(async () => {
      root.findByType(ChatDrawer).props.onOpenConversationMenu(
        fixture.conversationId,
      );
      root.findByType(ChatDrawer).props.onDismiss();
    });
    expect(root.findByType(ConversationActionSheet).props.visible).toBe(true);
    await act(async () => {
      root.findByType(ConversationActionSheet).props.onDelete();
      root.findByType(ConversationActionSheet).props.onDismiss();
      await settle();
      await deletePromise;
    });

    expect(root.findByType(ChatDrawer).props.activeId).toBe(
      fixture.conversationId,
    );
    expect(root.findAllByType(ProjectContextStrip)).toHaveLength(1);
    expect(visibleContextSheets(root)).toHaveLength(1);
    expect(visibleContextSheets(root)[0]?.props.mode).toBe('lifecycle');
    expect(visibleContextSheets(root)[0]?.props.lifecycle).toMatchObject({
      kind: 'confirmation',
      action: 'delete',
    });
    expect(actionByLabel(root, 'Delete chat')).toBeDefined();
    expect(mockLocalProjectContext.discard).not.toHaveBeenCalled();
    expect(mockLocalRuntime.cancelCompletion).not.toHaveBeenCalled();
    await act(async () => visibleContextSheets(root)[0]!.props.onClose());
    expect(visibleContextSheets(root)).toHaveLength(0);
    await act(async () => root.findByType(ChatComposer).props.onOptionsPress());
    expect(root.findByType(ConversationOptionsPicker).props.visible).toBe(true);
    await act(async () =>
      root.findByType(ConversationOptionsPicker).props.onClose(),
    );
    await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
    expect(
      root.findAllByProps({ accessibilityLabel: 'Pending project cleanup' }),
    ).toHaveLength(0);
    alert.mockRestore();
  });

  test('drops a stale snapshot delete confirmation after the selected owner changes', async () => {
    let staleConfirm: (() => unknown) | undefined;
    const alert = jest
      .spyOn(Alert, 'alert')
      .mockImplementation((_title, _message, buttons) => {
        const onPress = buttons?.find(
          button => button.style === 'destructive',
        )?.onPress;
        staleConfirm =
          typeof onPress === 'function' ? () => onPress() : undefined;
      });
    const fixture = storedProjectContext(true);
    const otherId = fixture.stored.createConversation({
      title: 'Other chat',
      select: false,
    });
    queuePresentSession(fixture.stored.serialize());
    const renderer = await renderApp();
    const root = renderer.root;
    await act(async () => settle());

    await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
    await act(async () => {
      root.findByType(ChatDrawer).props.onOpenConversationMenu(
        fixture.conversationId,
      );
      root.findByType(ChatDrawer).props.onDismiss();
    });
    await act(async () => {
      root.findByType(ConversationActionSheet).props.onDelete();
      root.findByType(ConversationActionSheet).props.onDismiss();
      await settle();
    });
    expect(staleConfirm).toEqual(expect.any(Function));

    await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
    await act(async () => {
      await root.findByType(ChatDrawer).props.onSelect(otherId);
      await settle();
    });
    expect(root.findByType(ChatDrawer).props.activeId).toBe(otherId);
    mockSessionSnapshots.casPersistSession.mockClear();
    mockLocalProjectContext.discard.mockClear();

    await act(async () => {
      await staleConfirm?.();
      await settle();
    });

    expect(root.findByType(ChatDrawer).props.activeId).toBe(otherId);
    expect(visibleContextSheets(root)).toHaveLength(0);
    expect(mockSessionSnapshots.casPersistSession).not.toHaveBeenCalled();
    expect(mockLocalProjectContext.discard).not.toHaveBeenCalled();
    alert.mockRestore();
  });

  test('dismisses Projects into exact Context review when snapshot unbind is blocked by a candidate', async () => {
    const fixture = storedProjectContext(false);
    queuePresentSession(fixture.stored.serialize());
    mockLocalProjectContext.inspect.mockResolvedValue({
      schema_version: 1,
      state: 'prepared',
      manifest: fixture.manifest,
    });
    const renderer = await renderAppOpeningStoredConversation();
    const root = renderer.root;
    mockSessionSnapshots.casPersistSession.mockClear();

    await openProjectsSurface(root);
    await act(async () => {
      root.findByType(ProjectsSurface).props.onUnbindFromChat();
      await settle();
    });
    expect(root.findByType(ProjectsSurface).props.visible).toBe(false);
    await act(async () => root.findByType(ProjectsSurface).props.onDismiss());

    expect(visibleContextSheets(root)[0]?.props.mode).toBe('disclosure');
    expect(visibleContextSheets(root)[0]?.props.confirmationRequired).toBe(true);
    expect(mockSessionSnapshots.casPersistSession).not.toHaveBeenCalled();
    expect(mockLocalProjectContext.discard).not.toHaveBeenCalled();
    expect(mockLocalRuntime.cancelCompletion).not.toHaveBeenCalled();
  });

  test('unbinds only after the context tombstone is durable and native cleanup succeeds', async () => {
    const fixture = storedProjectContext(true);
    const cleanup = deferred<{
      schema_version: 1;
      status: 'discarded';
    }>();
    queuePresentSession(fixture.stored.serialize());
    mockLocalProjects.list.mockResolvedValue({
      schema_version: 1,
      projects: [contextProject],
    });
    mockLocalProjectContext.inspect.mockResolvedValue({
      schema_version: 1,
      state: 'confirmed',
      manifest: fixture.manifest,
    });
    mockLocalProjectContext.discard.mockReturnValueOnce(cleanup.promise);
    const renderer = await renderAppOpeningStoredConversation();
    const root = renderer.root;
    await act(async () => settle());
    mockSessionSnapshots.casPersistSession.mockClear();

    await openProjectsSurface(root);
    await act(async () => {
      root.findByType(ProjectsSurface).props.onUnbindFromChat();
      await settle();
    });
    await act(async () => root.findByType(ProjectsSurface).props.onDismiss());
    await act(async () => {
      actionByLabel(root, 'Disable context and unbind').props.onPress();
      await settle();
    });

    const beforeCleanup = persistedStates();
    expect(beforeCleanup.at(-1)?.conversations[0]).toMatchObject({
      project_id: CONTEXT_PROJECT_ID,
      project_context: {
        status: 'setup_required',
        manifest: null,
        consent: null,
      },
    });
    expect(root.findByType(ProjectsSurface).props.boundProjectId).toBe(
      CONTEXT_PROJECT_ID,
    );
    expect(mockLocalProjectContext.discard).toHaveBeenCalledTimes(1);
    expect(mockLocalProjectContext.discard).toHaveBeenCalledWith(
      CONTEXT_SNAPSHOT_ID,
    );
    cleanup.resolve({ schema_version: 1, status: 'discarded' });
    await act(async () => {
      await settle();
      await settle();
    });

    expect(persistedStates().at(-1)?.conversations[0]).toMatchObject({
      project_id: null,
      project_context: null,
    });
    expect(mockLocalProjectContext.discard).toHaveBeenCalledTimes(1);
  });

  test('keeps the project bound until Retry save completes a pending unbind', async () => {
    const fixture = storedProjectContext(true);
    queuePresentSession(fixture.stored.serialize());
    mockLocalProjects.list.mockResolvedValue({
      schema_version: 1,
      projects: [contextProject],
    });
    mockLocalProjectContext.inspect.mockResolvedValue({
      schema_version: 1,
      state: 'confirmed',
      manifest: fixture.manifest,
    });
    const renderer = await renderAppOpeningStoredConversation();
    const root = renderer.root;
    await act(async () => settle());
    mockSessionSnapshots.casPersistSession.mockClear();
    mockSessionSnapshots.casPersistSession
      .mockImplementationOnce(async request => {
        return sessionOnlyResultFor(request);
      })
      .mockImplementation(async request => commitBridgedCandidate(request));

    await openProjectsSurface(root);
    await act(async () => {
      root.findByType(ProjectsSurface).props.onUnbindFromChat();
      await settle();
    });
    await act(async () => root.findByType(ProjectsSurface).props.onDismiss());
    await act(async () => settle());
    await act(async () => {
      actionByLabel(root, 'Disable context and unbind').props.onPress();
      await settle();
    });

    expect(root.findByType(ProjectsSurface).props.boundProjectId).toBe(
      CONTEXT_PROJECT_ID,
    );
    expect(visibleContextSheets(root)[0]?.props.lifecycle).toMatchObject({
      kind: 'transition',
      action: 'unbind',
      controllerState: { pendingPersistence: 'intent' },
    });
    expect(actionByLabel(root, 'Retry save')).toBeDefined();
    expect(mockLocalProjectContext.discard).not.toHaveBeenCalled();

    await act(async () => {
      actionByLabel(root, 'Retry save').props.onPress();
      await settle();
      await settle();
    });
    expect(mockLocalProjectContext.discard).toHaveBeenCalledTimes(1);
    expect(persistedStates().at(-1)?.conversations[0]).toMatchObject({
      project_id: null,
      project_context: null,
    });
  });

  test('keeps the project bound until Retry cleanup succeeds exactly once', async () => {
    const fixture = storedProjectContext(true);
    queuePresentSession(fixture.stored.serialize());
    mockLocalProjects.list.mockResolvedValue({
      schema_version: 1,
      projects: [contextProject],
    });
    mockLocalProjectContext.inspect.mockResolvedValue({
      schema_version: 1,
      state: 'confirmed',
      manifest: fixture.manifest,
    });
    mockLocalProjectContext.discard
      .mockRejectedValueOnce({
        code: 'E_CONTEXT_TIMEOUT',
        message: 'RAW_UNBIND_CLEANUP_SENTINEL',
      })
      .mockResolvedValue({ schema_version: 1, status: 'discarded' });
    const renderer = await renderAppOpeningStoredConversation();
    const root = renderer.root;
    await act(async () => settle());
    mockSessionSnapshots.casPersistSession.mockClear();

    await openProjectsSurface(root);
    await act(async () => {
      root.findByType(ProjectsSurface).props.onUnbindFromChat();
      await settle();
    });
    await act(async () => root.findByType(ProjectsSurface).props.onDismiss());
    await act(async () => settle());
    await act(async () => {
      actionByLabel(root, 'Disable context and unbind').props.onPress();
      await settle();
      await settle();
    });

    expect(root.findByType(ProjectsSurface).props.boundProjectId).toBe(
      CONTEXT_PROJECT_ID,
    );
    expect(visibleContextSheets(root)[0]?.props.lifecycle).toMatchObject({
      kind: 'transition',
      action: 'unbind',
      controllerState: {
        phase: 'cleanup_pending',
        failureCode: 'E_CONTEXT_TIMEOUT',
      },
    });
    expect(actionByLabel(root, 'Retry cleanup')).toBeDefined();
    expect(
      root.findAll(node =>
        Object.values(node.props).some(
          value =>
            typeof value === 'string' &&
            value.includes('RAW_UNBIND_CLEANUP_SENTINEL'),
        ),
      ),
    ).toHaveLength(0);
    const staleRetry = visibleContextSheets(root)[0]!.props
      .onRetryLifecycleCleanup;
    const staleToken = visibleContextSheets(root)[0]!.props.lifecycle
      .controllerState.token;

    await act(async () => {
      actionByLabel(root, 'Retry cleanup').props.onPress();
      await settle();
      await settle();
    });
    expect(mockLocalProjectContext.discard).toHaveBeenCalledTimes(2);
    expect(persistedStates().at(-1)?.conversations[0]).toMatchObject({
      project_id: null,
      project_context: null,
    });
    await act(async () => staleRetry(staleToken));
    expect(mockLocalProjectContext.discard).toHaveBeenCalledTimes(2);
  });

  test('does not unbind a snapshot referenced by an exact retry attempt', async () => {
    const fixture = storedProjectContext(true);
    const prepared = fixture.stored.prepareTurnAttempt(
      fixture.conversationId,
      'Keep the frozen snapshot',
    );
    expect(prepared?.commit()).toBe(true);
    expect(
      fixture.stored.failAttempt(
        fixture.conversationId,
        prepared!.attemptId,
        'E_COMPLETION_NATIVE',
      ),
    ).toBe(true);
    queuePresentSession(fixture.stored.serialize());
    mockLocalProjects.list.mockResolvedValue({
      schema_version: 1,
      projects: [contextProject],
    });
    const renderer = await renderAppOpeningStoredConversation();
    const root = renderer.root;
    await act(async () => settle());
    mockSessionSnapshots.casPersistSession.mockClear();

    await openProjectsSurface(root);
    await act(async () => {
      await root.findByType(ProjectsSurface).props.onUnbindFromChat();
      await settle();
    });

    expect(root.findByType(ProjectsSurface).props.boundProjectId).toBe(
      CONTEXT_PROJECT_ID,
    );
    expect(mockSessionSnapshots.casPersistSession).not.toHaveBeenCalled();
    expect(mockLocalProjectContext.discard).not.toHaveBeenCalled();
    expect(actionByLabel(root, 'Retry response')).toBeDefined();
    await act(async () =>
      root.findByProps({ testID: 'project-context-strip' }).props.onPress(),
    );
    expect(visibleContextSheets(root)[0]?.props.disabled).toBe(true);
  });

  test('creates a new project chat instead of rebinding an empty snapshot owner', async () => {
    jest.useFakeTimers();
    const secondProject = {
      ...contextProject,
      id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
      name: 'second-project',
      workspace_path:
        'projects/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb/repo',
    };
    const fixture = storedProjectContext(true);
    queuePresentSession(fixture.stored.serialize());
    mockLocalProjects.list.mockResolvedValue({
      schema_version: 1,
      projects: [contextProject, secondProject],
    });
    mockLocalProjectContext.inspect.mockResolvedValue({
      schema_version: 1,
      state: 'confirmed',
      manifest: fixture.manifest,
    });
    const renderer = await renderAppOpeningStoredConversation();
    const root = renderer.root;
    await act(async () => settle());

    await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
    await act(async () => {
      actionByLabel(root, 'Projects').props.onPress();
      await settle();
    });

    await act(async () => {
      await root.findByType(ProjectsSurface).props.onChatInProject(secondProject);
      await settle();
    });
    await act(async () => root.findByType(ProjectsSurface).props.onDismiss());

    const persisted = lastPersistedState();
    // Preserved snapshot owner + cold-launch blank + new project conversation.
    expect(persisted.conversations).toHaveLength(3);
    expect(
      persisted.conversations.find(
        conversation => conversation.id === fixture.conversationId,
      ),
    ).toMatchObject({
      project_id: CONTEXT_PROJECT_ID,
      project_context: {
        manifest: { snapshot_id: CONTEXT_SNAPSHOT_ID },
        consent: { consent_receipt_id: CONTEXT_CONSENT_ID },
      },
    });
    const selected = persisted.conversations.find(
      conversation => conversation.id === persisted.active_conversation_id,
    );
    expect(selected?.id).not.toBe(fixture.conversationId);
    expect(selected).toMatchObject({
      project_id: secondProject.id,
      project_context: { status: 'setup_required' },
    });
    expect(mockLocalProjectContext.discard).not.toHaveBeenCalled();
    await act(async () => {
      jest.advanceTimersByTime(180);
      await settle();
    });
    jest.useRealTimers();
  });

  test('deletes a nonactive snapshot chat without selecting it and prunes only after commit', async () => {
    let deletePromise: Promise<unknown> | undefined;
    const alert = jest
      .spyOn(Alert, 'alert')
      .mockImplementation((_title, _message, buttons) => {
        const destructive = buttons?.find(
          button => button.style === 'destructive',
        );
        const result = destructive?.onPress?.();
        if (result !== undefined) deletePromise = Promise.resolve(result);
      });
    const fixture = storedProjectContext(true);
    fixture.stored.appendUserMessage(
      fixture.conversationId,
      'Project attachment',
      {
        attachments: [
          {
            schema_version: 1,
            id: 'attachment-project-delete',
            kind: 'text',
            name: 'project.txt',
            mime_type: 'text/plain',
            size: 12,
          },
        ],
      },
    );
    const activeId = fixture.stored.createConversation({ title: 'Keep me' });
    queuePresentSession(fixture.stored.serialize());
    const renderer = await renderAppOpeningStoredConversation();
    const root = renderer.root;
    await act(async () => settle());
    await act(async () => {
      root
        .findByProps({ accessibilityLabel: 'Message DSH' })
        .props.onChangeText('active draft');
    });
    mockLocalAttachments.prune.mockClear();
    mockLocalAttachments.discard.mockClear();

    await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
    expect(root.findByType(ChatDrawer).props.visible).toBe(true);
    await act(async () => {
      root.findByType(ChatDrawer).props.onOpenConversationMenu(
        fixture.conversationId,
      );
      root.findByType(ChatDrawer).props.onDismiss();
    });
    expect(root.findByType(ConversationActionSheet).props.visible).toBe(true);
    await act(async () => {
      root.findByType(ConversationActionSheet).props.onDelete();
      root.findByType(ConversationActionSheet).props.onDismiss();
      await settle();
      await deletePromise;
    });

    expect(root.findByType(ChatDrawer).props.activeId).toBe(activeId);
    expect(visibleContextSheets(root)[0]?.props.lifecycle).toMatchObject({
      kind: 'confirmation',
      action: 'delete',
    });
    expect(mockLocalProjectContext.discard).not.toHaveBeenCalled();
    expect(mockLocalAttachments.prune).not.toHaveBeenCalled();
    await act(async () => {
      actionByLabel(root, 'Delete chat').props.onPress();
      await settle();
      await settle();
    });

    expect(root.findByType(ChatDrawer).props.activeId).toBe(activeId);
    expect(
      root.findByProps({ accessibilityLabel: 'Message DSH' }).props.value,
    ).toBe('active draft');
    expect(
      lastPersistedState().conversations.find(
        conversation => conversation.id === fixture.conversationId,
      ),
    ).toBeUndefined();
    expect(mockLocalProjectContext.discard).toHaveBeenCalledTimes(1);
    expect(mockLocalAttachments.prune).toHaveBeenCalledWith([]);
    expect(mockLocalAttachments.discard).not.toHaveBeenCalled();
    alert.mockRestore();
  });

  test('directly unbinds snapshot-free context with no journal or native discard', async () => {
    const fixture = storedSetupProject();
    queuePresentSession(fixture.stored.serialize());
    const renderer = await renderAppOpeningStoredConversation();
    const root = renderer.root;
    mockSessionSnapshots.casPersistSession.mockClear();

    await openProjectsSurface(root);
    await act(async () => {
      root.findByType(ProjectsSurface).props.onUnbindFromChat();
      await settle();
      await settle();
    });

    const persisted = JSON.parse(
      lastPersistedCandidateJSON(),
    ) as {
      project_context_destructive_transition: unknown;
      conversations: Array<{ project_id: string | null }>;
    };
    expect(persisted.project_context_destructive_transition).toBeNull();
    expect(persisted.conversations[0]?.project_id).toBeNull();
    expect(mockLocalProjectContext.discard).not.toHaveBeenCalled();
  });

  test('rolls back snapshot-free unbind when the direct session write is not committed', async () => {
    const fixture = storedSetupProject();
    queuePresentSession(fixture.stored.serialize());
    const renderer = await renderAppOpeningStoredConversation();
    const root = renderer.root;
    mockSessionSnapshots.casPersistSession.mockResolvedValueOnce(
      notCommittedResult(),
    );

    await openProjectsSurface(root);
    await act(async () => {
      root.findByType(ProjectsSurface).props.onUnbindFromChat();
      await settle();
      await settle();
    });

    expect(root.findByType(ProjectsSurface).props.boundProjectId).toBe(
      CONTEXT_PROJECT_ID,
    );
    expect(mockLocalProjectContext.discard).not.toHaveBeenCalled();
  });

  test.each(
    (
      ['unbind', 'delete'] as Array<'unbind' | 'delete' | 'rebind'>
    ).flatMap(action =>
      (['not_committed', 'session_only', 'unknown'] as const).map(status => [
        action,
        status,
      ] as const),
    ),
  )(
    'keeps snapshot-free %s crash-safe for %s durability and retries once',
    async (action, status) => {
      const fixture = storedSetupProject();
      const secondProject = {
        ...contextProject,
        id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        name: 'second-project',
        workspace_path:
          'projects/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb/repo',
      };
      queuePresentSession(fixture.stored.serialize());
      mockLocalProjects.list.mockResolvedValue({
        schema_version: 1,
        projects: [contextProject, secondProject],
      });
      let deletePromise: Promise<unknown> | undefined;
      const alert = jest
        .spyOn(Alert, 'alert')
        .mockImplementation((_title, _message, buttons) => {
          const result = buttons
            ?.find(button => button.style === 'destructive')
            ?.onPress?.();
          if (result !== undefined) deletePromise = Promise.resolve(result);
        });
      const renderer = await renderAppOpeningStoredConversation();
      const root = renderer.root;
      if (status === 'unknown') {
        mockSessionSnapshots.casPersistSession.mockImplementationOnce(
          async () => unknownResult(),
        );
        mockSessionSnapshots.querySessionCommit.mockResolvedValueOnce({
          schema_version: 1,
          status: 'unknown',
        });
      } else {
        mockSessionSnapshots.casPersistSession.mockImplementationOnce(
          async request =>
            status === 'session_only'
              ? sessionOnlyResultFor(request)
              : notCommittedResult(),
        );
      }

      if (action === 'unbind') {
        await openProjectsSurface(root);
        await act(async () => {
          root.findByType(ProjectsSurface).props.onUnbindFromChat();
          await settle();
          await settle();
        });
      } else if (action === 'rebind') {
        await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
        await act(async () => {
          actionByLabel(root, 'Projects').props.onPress();
          await settle();
        });
        await act(async () => {
          await root.findByType(ProjectsSurface).props.onChatInProject(
            secondProject,
          );
          await settle();
          await settle();
        });
      } else {
        await act(async () =>
          actionByLabel(root, 'Open navigation').props.onPress(),
        );
        await act(async () => {
          root.findByType(ChatDrawer).props.onOpenConversationMenu(
            fixture.conversationId,
          );
          root.findByType(ChatDrawer).props.onDismiss();
        });
        await act(async () => {
          root.findByType(ConversationActionSheet).props.onDelete();
          root.findByType(ConversationActionSheet).props.onDismiss();
          await settle();
          await deletePromise;
          await settle();
        });
      }

      if (action !== 'delete') {
        expect(root.findByType(ProjectsSurface).props.visible).toBe(false);
        await act(async () => root.findByType(ProjectsSurface).props.onDismiss());
      }

      expect(visibleContextSheets(root)[0]?.props.lifecycle).toMatchObject({
        kind: 'direct_persistence',
        action,
      });
      const boundBeforeRetry = root.findByType(ProjectsSurface).props
        .boundProjectId;
      if (action === 'unbind') {
        expect(boundBeforeRetry).toBe(
          status === 'not_committed' ? CONTEXT_PROJECT_ID : null,
        );
      } else if (action === 'rebind') {
        expect(boundBeforeRetry).toBe(
          status === 'not_committed' ? CONTEXT_PROJECT_ID : secondProject.id,
        );
      } else {
        expect(root.findByType(ChatDrawer).props.activeId === fixture.conversationId).toBe(
          status === 'not_committed',
        );
      }
      expect(mockLocalProjectContext.discard).not.toHaveBeenCalled();

      mockSessionSnapshots.casPersistSession.mockImplementationOnce(
        async request => commitBridgedCandidate(request),
      );
      await act(async () => {
        actionByLabel(root, 'Retry save').props.onPress();
        await settle();
        await settle();
      });
      expect(visibleContextSheets(root)).toHaveLength(0);
      if (action === 'unbind') {
        expect(root.findByType(ProjectsSurface).props.boundProjectId).toBeNull();
      } else if (action === 'rebind') {
        expect(root.findByType(ProjectsSurface).props.boundProjectId).toBe(
          secondProject.id,
        );
      } else {
        expect(root.findByType(ChatDrawer).props.activeId).not.toBe(
          fixture.conversationId,
        );
      }
      alert.mockRestore();
    },
  );

  test('busy lifecycle top close is presentation-only and late cleanup cannot reopen it', async () => {
    const fixture = storedProjectContext(true);
    const cleanup = deferred<{ schema_version: 1; status: 'discarded' }>();
    queuePresentSession(fixture.stored.serialize());
    mockLocalProjectContext.inspect.mockResolvedValue({
      schema_version: 1,
      state: 'confirmed',
      manifest: fixture.manifest,
    });
    mockLocalProjectContext.discard.mockReturnValueOnce(cleanup.promise);
    const renderer = await renderAppOpeningStoredConversation();
    const root = renderer.root;
    await openProjectsSurface(root);
    await act(async () => {
      root.findByType(ProjectsSurface).props.onUnbindFromChat();
      await settle();
    });
    await act(async () => root.findByType(ProjectsSurface).props.onDismiss());
    await act(async () => {
      actionByLabel(root, 'Disable context and unbind').props.onPress();
      await settle();
    });
    const sheet = visibleContextSheets(root)[0]!;
    await act(async () => sheet.props.onClose());
    expect(visibleContextSheets(root)).toHaveLength(0);
    expect(mockLocalProjectContext.discard).toHaveBeenCalledTimes(1);

    cleanup.resolve({ schema_version: 1, status: 'discarded' });
    await act(async () => {
      await settle();
      await settle();
    });
    expect(visibleContextSheets(root)).toHaveLength(0);
    expect(mockLocalProjectContext.discard).toHaveBeenCalledTimes(1);
    expect(lastPersistedState().conversations[0]?.project_id).toBeNull();
  });

  test('reopens nonactive direct persistence from one value-free Drawer row and rejects its stale callback', async () => {
    let deletePromise: Promise<unknown> | undefined;
    const alert = jest
      .spyOn(Alert, 'alert')
      .mockImplementation((_title, _message, buttons) => {
        const result = buttons
          ?.find(button => button.style === 'destructive')
          ?.onPress?.();
        if (result !== undefined) deletePromise = Promise.resolve(result);
      });
    const fixture = storedSetupProject();
    const activeId = fixture.stored.createConversation({ title: 'Active' });
    queuePresentSession(fixture.stored.serialize());
    const renderer = await renderAppOpeningStoredConversation();
    const root = renderer.root;
    mockSessionSnapshots.casPersistSession.mockImplementationOnce(
      async () => unknownResult(),
    );
    mockSessionSnapshots.querySessionCommit.mockResolvedValueOnce({
      schema_version: 1,
      status: 'unknown',
    });

    await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
    await act(async () => {
      root.findByType(ChatDrawer).props.onOpenConversationMenu(
        fixture.conversationId,
      );
      root.findByType(ChatDrawer).props.onDismiss();
    });
    await act(async () => {
      root.findByType(ConversationActionSheet).props.onDelete();
      root.findByType(ConversationActionSheet).props.onDismiss();
      await settle();
      await deletePromise;
      await settle();
    });
    await act(async () => visibleContextSheets(root)[0]!.props.onClose());
    expect(visibleContextSheets(root)).toHaveLength(0);

    await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
    const pending = actionByLabel(root, 'Pending project cleanup');
    const stalePending = pending.props.onPress;
    expect(pending.props.accessibilityLabel).toBe('Pending project cleanup');
    await act(async () => pending.props.onPress());
    expect(root.findByType(ChatDrawer).props.visible).toBe(false);
    await act(async () => root.findByType(ChatDrawer).props.onDismiss());
    expect(visibleContextSheets(root)[0]?.props.lifecycle).toMatchObject({
      kind: 'direct_persistence',
      action: 'delete',
    });
    expect(root.findByType(ChatDrawer).props.activeId).toBe(activeId);
    expect(mockLocalProjectContext.inspect).not.toHaveBeenCalled();
    expect(mockLocalProjectContext.discard).not.toHaveBeenCalled();

    mockSessionSnapshots.casPersistSession.mockImplementationOnce(
      async request => commitBridgedCandidate(request),
    );
    await act(async () => {
      actionByLabel(root, 'Retry save').props.onPress();
      await settle();
      await settle();
    });
    expect(visibleContextSheets(root)).toHaveLength(0);
    await act(async () => stalePending());
    expect(visibleContextSheets(root)).toHaveLength(0);
    expect(root.findByType(ChatDrawer).props.activeId).toBe(activeId);
    alert.mockRestore();
  });

  test('reopens nonactive lifecycle cleanup from Drawer without selecting its target', async () => {
    let deletePromise: Promise<unknown> | undefined;
    const alert = jest
      .spyOn(Alert, 'alert')
      .mockImplementation((_title, _message, buttons) => {
        const result = buttons
          ?.find(button => button.style === 'destructive')
          ?.onPress?.();
        if (result !== undefined) deletePromise = Promise.resolve(result);
      });
    const fixture = storedProjectContext(true);
    const activeId = fixture.stored.createConversation({ title: 'Active' });
    queuePresentSession(fixture.stored.serialize());
    mockLocalProjectContext.discard
      .mockRejectedValueOnce({ code: 'E_CONTEXT_TIMEOUT' })
      .mockResolvedValue({ schema_version: 1, status: 'discarded' });
    const renderer = await renderAppOpeningStoredConversation();
    const root = renderer.root;

    await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
    await act(async () => {
      root.findByType(ChatDrawer).props.onOpenConversationMenu(
        fixture.conversationId,
      );
      root.findByType(ChatDrawer).props.onDismiss();
    });
    await act(async () => {
      root.findByType(ConversationActionSheet).props.onDelete();
      root.findByType(ConversationActionSheet).props.onDismiss();
      await settle();
      await deletePromise;
    });
    await act(async () => {
      actionByLabel(root, 'Delete chat').props.onPress();
      await settle();
      await settle();
    });
    expect(visibleContextSheets(root)[0]?.props.lifecycle).toMatchObject({
      kind: 'transition',
      action: 'delete',
      controllerState: { phase: 'cleanup_pending' },
    });
    await act(async () => visibleContextSheets(root)[0]!.props.onClose());

    await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
    const pending = actionByLabel(root, 'Pending project cleanup');
    await act(async () => pending.props.onPress());
    await act(async () => root.findByType(ChatDrawer).props.onDismiss());
    expect(root.findByType(ChatDrawer).props.activeId).toBe(activeId);
    expect(visibleContextSheets(root)[0]?.props.lifecycle).toMatchObject({
      kind: 'transition',
      action: 'delete',
      controllerState: { phase: 'cleanup_pending' },
    });
    expect(mockLocalProjectContext.inspect).not.toHaveBeenCalled();

    await act(async () => {
      actionByLabel(root, 'Retry cleanup').props.onPress();
      await settle();
      await settle();
    });
    expect(root.findByType(ChatDrawer).props.activeId).toBe(activeId);
    expect(
      lastPersistedState().conversations.find(
        conversation => conversation.id === fixture.conversationId,
      ),
    ).toBeUndefined();
    alert.mockRestore();
  });

  test('rejects stale Drawer and composer surface openers while lifecycle confirmation owns the screen', async () => {
    let deletePromise: Promise<unknown> | undefined;
    let staleDelete = () => undefined;
    const alert = jest
      .spyOn(Alert, 'alert')
      .mockImplementation((_title, _message, buttons) => {
        const result = buttons
          ?.find(button => button.style === 'destructive')
          ?.onPress?.();
        if (result !== undefined) deletePromise = Promise.resolve(result);
    });
    const fixture = storedProjectContext(true);
    const staleSelectTarget = fixture.stored.createConversation({
      title: 'Stale target',
      select: false,
    });
    queuePresentSession(fixture.stored.serialize());
    mockLocalRuntime.bootstrap.mockResolvedValue({
      proof: {
        ...proof,
        checks: { ...proof.checks, rish_applet_executed: false },
      },
      rish: {},
    });
    const renderer = await renderAppOpeningStoredConversation();
    const root = renderer.root;
    const staleMainRuntime = actionByLabel(
      root,
      'Show runtime evidence',
    ).props.onPress;
    const composer = root.findByType(ChatComposer);
    const staleWorkspace = composer.props.onWorkspacePress;
    const staleOptions = composer.props.onOptionsPress;
    const staleContext = root.findByProps({
      testID: 'project-context-strip',
    }).props.onPress;
    const staleDrawerOpen = actionByLabel(root, 'Open navigation').props.onPress;
    await act(async () => staleDrawerOpen());
    const firstDrawer = root.findByType(ChatDrawer);
    const staleAccount = firstDrawer.props.onOpenAccount;
    const staleNew = firstDrawer.props.onNewChat;
    const staleSelect = () => firstDrawer.props.onSelect(staleSelectTarget);
    await act(async () => {
      firstDrawer.props.onOpenSettings();
      firstDrawer.props.onDismiss();
    });
    const staleModel = root.findByType(SettingsSheet).props.onOpenModelPicker;
    const staleEvidenceFromSettings = root.findByType(SettingsSheet).props
      .onOpenRuntime;
    const staleMirrors = root.findByType(SettingsSheet).props.onOpenMirrors;
    const staleProjectFiles = root.findByType(ProjectsSurface).props.onOpenFiles;
    const staleProjectChat = root.findByType(ProjectsSurface).props.onChatInProject;
    const staleProjectUnbind = root.findByType(ProjectsSurface).props
      .onUnbindFromChat;
    await act(async () => root.findByType(SettingsSheet).props.onClose());
    await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
    const drawer = root.findByType(ChatDrawer);
    const staleProjects = drawer.props.onOpenProjects;
    const staleSettings = drawer.props.onOpenSettings;
    const staleHarnesses = drawer.props.onOpenHarnesses;
    const staleEvidence = drawer.props.onOpenRuntime;
    await act(async () => {
      drawer.props.onOpenConversationMenu(fixture.conversationId);
      drawer.props.onDismiss();
    });
    await act(async () => {
      staleDelete = root.findByType(ConversationActionSheet).props.onDelete;
      staleDelete();
      root.findByType(ConversationActionSheet).props.onDismiss();
      await settle();
      await deletePromise;
    });
    expect(visibleContextSheets(root)[0]?.props.mode).toBe('lifecycle');
    mockSessionSnapshots.casPersistSession.mockClear();
    const activeBefore = root.findByType(ChatDrawer).props.activeId;

    await act(async () => {
      staleNew();
      staleSelect();
      staleProjectChat(contextProject);
      staleDelete();
      staleProjects();
      staleSettings();
      staleWorkspace();
      staleOptions();
      staleModel();
      staleEvidenceFromSettings();
      staleMirrors();
      staleAccount();
      staleProjectFiles(contextProject);
      staleProjectUnbind();
      staleHarnesses();
      staleEvidence();
      staleMainRuntime();
      staleContext();
      staleDrawerOpen();
      root.findByType(ChatDrawer).props.onDismiss();
      await settle();
    });
    expect(root.findByType(ProjectsSurface).props.visible).toBe(false);
    expect(root.findByType(SettingsSheet).props.visible).toBe(false);
    expect(root.findByType(ConversationOptionsPicker).props.visible).toBe(
      false,
    );
    expect(root.findByType(WorkspacePickerSheet).props.visible).toBe(false);
    expect(root.findByType(ModelPicker).props.visible).toBe(false);
    expect(root.findByType(HarnessPicker).props.visible).toBe(false);
    expect(root.findByType(RuntimeEvidenceSheet).props.visible).toBe(false);
    expect(root.findByType(AccountSheet).props.visible).toBe(false);
    expect(root.findByType(MirrorSettingsSheet).props.visible).toBe(false);
    expect(root.findByType(WorkspaceDrawer).props.visible).toBe(false);
    expect(root.findByType(ChatDrawer).props.visible).toBe(false);
    expect(visibleContextSheets(root)).toHaveLength(1);
    expect(visibleContextSheets(root)[0]?.props.lifecycle).toMatchObject({
      kind: 'confirmation',
      action: 'delete',
    });
    expect(root.findByType(ChatDrawer).props.activeId).toBe(activeBefore);
    expect(mockSessionSnapshots.casPersistSession).not.toHaveBeenCalled();
    alert.mockRestore();
  });

  test('rejects a stale Drawer Settings opener after Context disclosure takes authority', async () => {
    const fixture = storedProjectContext(true);
    queuePresentSession(fixture.stored.serialize());
    mockLocalProjectContext.inspect.mockResolvedValue({
      schema_version: 1,
      state: 'confirmed',
      manifest: fixture.manifest,
    });
    const renderer = await renderAppOpeningStoredConversation();
    const root = renderer.root;
    await act(async () => settle());
    const staleOptions = root.findByType(ChatComposer).props.onOptionsPress;

    await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
    const staleSettings = root.findByType(ChatDrawer).props.onOpenSettings;
    await act(async () => root.findByType(ChatDrawer).props.onClose());
    await act(async () => {
      root.findByProps({ testID: 'project-context-strip' }).props.onPress();
      await settle();
    });
    expect(visibleContextSheets(root)).toHaveLength(1);

    await act(async () => {
      staleSettings();
      staleOptions();
    });

    expect(visibleContextSheets(root)).toHaveLength(1);
    expect(root.findByType(SettingsSheet).props.visible).toBe(false);
    expect(root.findByType(ConversationOptionsPicker).props.visible).toBe(
      false,
    );
  });

  test.each(['Drawer', 'Settings'] as const)(
    'blocks a stale composer Workspace opener behind %s',
    async surface => {
      const renderer = await renderApp();
      const root = renderer.root;
      await act(async () => settle());
      const staleWorkspace = root.findByType(ChatComposer).props
        .onWorkspacePress;

      await act(async () =>
        actionByLabel(root, 'Open navigation').props.onPress(),
      );
      if (surface === 'Settings') {
        await act(async () =>
          root.findByType(ChatDrawer).props.onOpenSettings(),
        );
        expect(root.findByType(SettingsSheet).props.visible).toBe(true);
      }

      await act(async () => staleWorkspace());

      expect(root.findByType(WorkspacePickerSheet).props.visible).toBe(false);
    },
  );

  test('only the presented uncovered Settings surface adjusts keyboard insets', async () => {
    const renderer = await renderApp();
    const root = renderer.root;
    await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
    await act(async () => root.findByType(ChatDrawer).props.onOpenSettings());
    expect(root.findByProps({testID: 'settings-scroll'}).props.automaticallyAdjustKeyboardInsets).toBe(true);
    await act(async () => root.findByType(SettingsSheet).props.onOpenMirrors());
    expect(root.findByType(SettingsSheet).props.covered).toBe(true);
    expect(root.findByProps({testID: 'settings-scroll'}).props.automaticallyAdjustKeyboardInsets).toBe(false);
    await act(async () => root.findByType(MirrorSettingsSheet).props.onClose());
    expect(root.findByProps({testID: 'settings-scroll'}).props.automaticallyAdjustKeyboardInsets).toBe(true);
  });

  test('rejects old Settings child openers after close and reopen', async () => {
    const renderer = await renderApp();
    const root = renderer.root;
    await act(async () => settle());
    await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
    await act(async () => root.findByType(ChatDrawer).props.onOpenSettings());
    const settings = root.findByType(SettingsSheet);
    const staleModel = settings.props.onOpenModelPicker;
    const staleMirrors = settings.props.onOpenMirrors;
    const staleRuntime = settings.props.onOpenRuntime;

    await act(async () => settings.props.onClose());
    expect(root.findByType(ChatDrawer).props.visible).toBe(true);
    await act(async () => root.findByType(ChatDrawer).props.onOpenSettings());
    expect(root.findByType(SettingsSheet).props.visible).toBe(true);

    await act(async () => {
      staleModel();
      staleMirrors();
      staleRuntime();
    });

    expect(root.findByType(ModelPicker).props.visible).toBe(false);
    expect(root.findByType(MirrorSettingsSheet).props.visible).toBe(false);
    expect(root.findByType(RuntimeEvidenceSheet).props.visible).toBe(false);
  });

  test('blocks every root surface and navigation mutation until lifecycle bootstrap settles', async () => {
    const restored = storedLifecycleCheckpoint('cleanup_pending');
    const load = deferred<string | null>();
    queueDeferredSessionLoad(load.promise);
    mockLocalProjectContext.discard.mockRejectedValueOnce({
      code: 'E_CONTEXT_TIMEOUT',
      message: 'BOOTSTRAP_SURFACE_SENTINEL',
    });
    const renderer = await renderApp();
    const root = renderer.root;
    const initialActive = root.findByType(ChatDrawer).props.activeId;
    const composer = root.findByType(ChatComposer);
    const drawer = root.findByType(ChatDrawer);
    const settings = root.findByType(SettingsSheet);

    await act(async () => {
      actionByLabel(root, 'Open navigation').props.onPress();
      actionByLabel(root, 'Show runtime evidence').props.onPress();
      composer.props.onConfigure();
      composer.props.onOptionsPress();
      composer.props.onWorkspacePress();
      drawer.props.onOpenAccount();
      drawer.props.onOpenSettings();
      await drawer.props.onNewChat();
      await drawer.props.onSelect('stale-bootstrap-conversation');
      settings.props.onOpenModelPicker();
      settings.props.onOpenMirrors();
      settings.props.onOpenRuntime();
      await settle();
    });

    expect(root.findByType(ChatDrawer).props.visible).toBe(false);
    expect(root.findByType(SettingsSheet).props.visible).toBe(false);
    expect(root.findByType(AccountSheet).props.visible).toBe(false);
    expect(root.findByType(ModelPicker).props.visible).toBe(false);
    expect(root.findByType(MirrorSettingsSheet).props.visible).toBe(false);
    expect(root.findByType(RuntimeEvidenceSheet).props.visible).toBe(false);
    expect(root.findByType(ConversationOptionsPicker).props.visible).toBe(false);
    expect(root.findByType(WorkspacePickerSheet).props.visible).toBe(false);
    expect(root.findByType(ChatDrawer).props.activeId).toBe(initialActive);
    expect(mockSessionSnapshots.casPersistSession).not.toHaveBeenCalled();

    load.resolve(restored.stored.serialize());
    await act(async () => {
      await settle();
      await settle();
    });

    expect(visibleContextSheets(root)).toHaveLength(1);
    expect(visibleContextSheets(root)[0]?.props.lifecycle).toMatchObject({
      kind: 'transition',
      controllerState: { phase: 'cleanup_pending' },
    });
    expect(root.findByType(ChatDrawer).props.visible).toBe(false);
    expect(root.findByType(SettingsSheet).props.visible).toBe(false);
    expect(root.findByType(RuntimeEvidenceSheet).props.visible).toBe(false);
  });

  test('closes Projects during an in-flight project transition and ignores its late persistence', async () => {
    const persisted = deferred<boolean>();
    mockSessionSnapshots.casPersistSession.mockImplementationOnce(
      async request => {
        const saved = await persisted.promise;
        return saved ? commitBridgedCandidate(request) : unknownResult();
      },
    );
    mockLocalProjects.list.mockResolvedValue({
      schema_version: 1,
      projects: [contextProject],
    });
    const renderer = await renderApp();
    const root = renderer.root;
    await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
    await act(async () => {
      actionByLabel(root, 'Projects').props.onPress();
      await settle();
    });
    const chat = root.findByType(ProjectsSurface).props.onChatInProject;
    await act(async () => {
      chat(contextProject);
      await settle();
    });
    expect(mockSessionSnapshots.casPersistSession).toHaveBeenCalledTimes(1);

    await act(async () => root.findByType(ProjectsSurface).props.onClose());
    expect(root.findByType(ProjectsSurface).props.visible).toBe(false);
    persisted.resolve(true);
    await act(async () => {
      await settle();
      await settle();
      root.findByType(ProjectsSurface).props.onDismiss();
    });
    expect(visibleContextSheets(root)).toHaveLength(0);
  });

  test('does not auto-open direct recovery after Projects closes during an ambiguous write', async () => {
    const fixture = storedSetupProject();
    queuePresentSession(fixture.stored.serialize());
    const persisted = deferred<boolean>();
    const renderer = await renderAppOpeningStoredConversation();
    const root = renderer.root;
    mockSessionSnapshots.casPersistSession.mockImplementationOnce(
      async request => {
        const saved = await persisted.promise;
        return saved ? commitBridgedCandidate(request) : unknownResult();
      },
    );
    await openProjectsSurface(root);

    await act(async () => {
      root.findByType(ProjectsSurface).props.onUnbindFromChat();
      await settle();
    });
    await act(async () => root.findByType(ProjectsSurface).props.onClose());
    expect(root.findByType(ProjectsSurface).props.visible).toBe(false);
    await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
    expect(root.findByType(ChatDrawer).props.visible).toBe(false);
    mockSessionSnapshots.querySessionCommit.mockResolvedValueOnce({
      schema_version: 1,
      status: 'unknown',
    });
    persisted.resolve(false);
    await act(async () => {
      await settle();
      await settle();
      root.findByType(ProjectsSurface).props.onDismiss();
    });
    expect(visibleContextSheets(root)).toHaveLength(0);

    await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
    expect(actionByLabel(root, 'Pending project cleanup')).toBeDefined();
  });

  // The Drawer is admitted while this recovery is settled, so its actions have
  // to answer. Refusing what admission allowed made New chat do nothing at all
  // and say nothing, with no way to reach the recovery it was waiting on.
  test('routes New chat to direct recovery while an ambiguous write is settled', async () => {
    const fixture = storedSetupProject();
    queuePresentSession(fixture.stored.serialize());
    const persisted = deferred<boolean>();
    const renderer = await renderAppOpeningStoredConversation();
    const root = renderer.root;
    mockSessionSnapshots.casPersistSession.mockImplementationOnce(
      async request => {
        const saved = await persisted.promise;
        return saved ? commitBridgedCandidate(request) : unknownResult();
      },
    );
    await openProjectsSurface(root);
    await act(async () => {
      root.findByType(ProjectsSurface).props.onUnbindFromChat();
      await settle();
    });
    await act(async () => root.findByType(ProjectsSurface).props.onClose());
    mockSessionSnapshots.querySessionCommit.mockResolvedValueOnce({
      schema_version: 1,
      status: 'unknown',
    });
    persisted.resolve(false);
    await act(async () => {
      await settle();
      await settle();
      root.findByType(ProjectsSurface).props.onDismiss();
    });

    await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
    expect(root.findByType(ChatDrawer).props.visible).toBe(true);
    const openedConversationId = root.findByType(ChatDrawer).props.activeId;

    await act(async () => {
      await root.findByType(ChatDrawer).props.onNewChat();
      root.findByType(ChatDrawer).props.onDismiss();
      await settle();
    });

    expect(root.findByType(ChatDrawer).props.visible).toBe(false);
    expect(root.findByType(ChatDrawer).props.activeId).toBe(openedConversationId);
    expect(visibleContextSheets(root)).toHaveLength(1);
  });

  // Settings is one of six Drawer controls that asked the strict guard while
  // the Drawer itself was admitted by the tolerant one. Each was inert and
  // silent in this state; they route to the recovery instead.
  test('routes Drawer Settings to direct recovery while an ambiguous write is settled', async () => {
    const fixture = storedSetupProject();
    queuePresentSession(fixture.stored.serialize());
    const persisted = deferred<boolean>();
    const renderer = await renderAppOpeningStoredConversation();
    const root = renderer.root;
    mockSessionSnapshots.casPersistSession.mockImplementationOnce(
      async request => {
        const saved = await persisted.promise;
        return saved ? commitBridgedCandidate(request) : unknownResult();
      },
    );
    await openProjectsSurface(root);
    await act(async () => {
      root.findByType(ProjectsSurface).props.onUnbindFromChat();
      await settle();
    });
    await act(async () => root.findByType(ProjectsSurface).props.onClose());
    mockSessionSnapshots.querySessionCommit.mockResolvedValueOnce({
      schema_version: 1,
      status: 'unknown',
    });
    persisted.resolve(false);
    await act(async () => {
      await settle();
      await settle();
      root.findByType(ProjectsSurface).props.onDismiss();
    });

    await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
    await act(async () => {
      root.findByType(ChatDrawer).props.onOpenSettings();
      root.findByType(ChatDrawer).props.onDismiss();
      await settle();
    });

    expect(root.findByType(SettingsSheet).props.visible).toBe(false);
    expect(visibleContextSheets(root)).toHaveLength(1);
  });

  // A docked Drawer never fires onDismiss, so a hand-off staged for the
  // dismissal has to run when the Drawer closes or it is stranded and the
  // control is silent again -- on the layout where the Drawer is always there.
  test('hands off New chat to direct recovery on a docked wide layout', async () => {
    const narrow = Dimensions.get('window');
    Dimensions.set({
      window: { ...narrow, width: 1024, height: 1366 },
      screen: { ...narrow, width: 1024, height: 1366 },
    } as never);
    try {
      const fixture = storedSetupProject();
      queuePresentSession(fixture.stored.serialize());
      const persisted = deferred<boolean>();
      const renderer = await renderAppOpeningStoredConversation();
      const root = renderer.root;
      expect(root.findByType(ChatDrawer).props.docked).toBe(true);
      mockSessionSnapshots.casPersistSession.mockImplementationOnce(
        async request => {
          const saved = await persisted.promise;
          return saved ? commitBridgedCandidate(request) : unknownResult();
        },
      );
      await openProjectsSurface(root);
      await act(async () => {
        root.findByType(ProjectsSurface).props.onUnbindFromChat();
        await settle();
      });
      await act(async () => root.findByType(ProjectsSurface).props.onClose());
      mockSessionSnapshots.querySessionCommit.mockResolvedValueOnce({
        schema_version: 1,
        status: 'unknown',
      });
      persisted.resolve(false);
      await act(async () => {
        await settle();
        await settle();
        root.findByType(ProjectsSurface).props.onDismiss();
      });

      // No onDismiss is fired here: a docked surface never sends one.
      await act(async () => {
        await root.findByType(ChatDrawer).props.onNewChat();
        await settle();
      });
      expect(visibleContextSheets(root)).toHaveLength(1);
    } finally {
      Dimensions.set({ window: narrow, screen: narrow } as never);
    }
  });

  test('drops a queued Drawer opener when bootstrap restores lifecycle recovery first', async () => {
    const loaded = deferred<string | null>();
    const fixture = storedLifecycleCheckpoint('cleanup_pending');
    queueDeferredSessionLoad(loaded.promise);
    mockLocalProjectContext.discard.mockRejectedValueOnce({
      code: 'E_CONTEXT_TIMEOUT',
    });
    let renderer: Renderer | undefined;
    await act(async () => {
      renderer = ReactTestRenderer.create(<App />);
      mountedRenderers.add(renderer);
      await settle();
    });
    if (renderer === undefined) throw new Error('renderer missing');
    const root = renderer.root;
    await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
    await act(async () => root.findByType(ChatDrawer).props.onOpenProjects());
    expect(root.findByType(ChatDrawer).props.visible).toBe(false);

    loaded.resolve(fixture.stored.serialize());
    await act(async () => {
      await settle();
      await settle();
    });
    expect(visibleContextSheets(root)[0]?.props.mode).toBe('lifecycle');
    await act(async () => root.findByType(ChatDrawer).props.onDismiss());
    expect(root.findByType(ProjectsSurface).props.visible).toBe(false);
    expect(visibleContextSheets(root)).toHaveLength(1);
  });
});

test('starts a project-bound chat with one actionable context Strip', async () => {
  jest.useFakeTimers();
  mockLocalProjects.list.mockResolvedValue({
    schema_version: 1,
    projects: [
      {
        schema_version: 1,
        id: CONTEXT_PROJECT_ID,
        name: 'demo',
        workspace_path: `projects/${CONTEXT_PROJECT_ID}/repo`,
        created_at: '2026-08-24T00:00:00.000Z',
        updated_at: '2026-08-24T00:00:00.000Z',
        origin_url: null,
      },
    ],
  });
  const renderer = await renderApp();
  const root = renderer.root;

  await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
  await act(async () => {
    actionByLabel(root, 'Projects').props.onPress();
    await settle();
  });
  await act(async () => {
    actionByLabel(root, 'Open project demo').props.onPress();
    await settle();
  });
  await act(async () => {
    actionByLabel(root, 'Chat in this project').props.onPress();
    await settle();
  });
  await act(async () => {
    jest.advanceTimersByTime(180);
    await settle();
  });

  expect(lastPersistedState().conversations.at(-1)?.project_id).toBe(
    CONTEXT_PROJECT_ID,
  );
  expect(root.findAllByType(ProjectContextStrip)).toHaveLength(1);
  expect(
    root.findAllByProps({ accessibilityLabel: 'Project demo' }),
  ).toHaveLength(0);
  jest.useRealTimers();
});

test('does not auto-route a setup-required project through AgentLoop', async () => {
  jest.useFakeTimers();
  mockLocalRuntime.isCompletionV2Available.mockReturnValue(true);
  mockLocalProjects.list.mockResolvedValue({
    schema_version: 1,
    projects: [
      {
        schema_version: 1,
        id: CONTEXT_PROJECT_ID,
        name: 'demo',
        workspace_path: `projects/${CONTEXT_PROJECT_ID}/repo`,
        created_at: '2026-08-24T00:00:00.000Z',
        updated_at: '2026-08-24T00:00:00.000Z',
        origin_url: null,
      },
    ],
  });
  const renderer = await renderApp();
  const root = renderer.root;
  await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
  await act(async () => {
    actionByLabel(root, 'Projects').props.onPress();
    await settle();
  });
  await act(async () => {
    actionByLabel(root, 'Open project demo').props.onPress();
    await settle();
  });
  await act(async () => {
    actionByLabel(root, 'Chat in this project').props.onPress();
    await settle();
  });
  await act(async () => {
    jest.advanceTimersByTime(180);
    await settle();
  });
  await act(async () => {
    root
      .findByProps({ accessibilityLabel: 'Message DSH' })
      .props.onChangeText('Wait for context');
  });
  await act(async () => {
    actionByLabel(root, 'Send message').props.onPress();
    await settle();
  });

  expect(mockRunAgentTurn).not.toHaveBeenCalled();
  expect(mockLocalRuntime.completeV2).not.toHaveBeenCalled();
  expect(mockLocalRuntime.complete).not.toHaveBeenCalled();
  expect(
    root.findByProps({ accessibilityLabel: 'Message DSH' }).props.value,
  ).toBe('Wait for context');
  expect(visibleContextSheets(root)[0]?.props.disabled).toBe(false);
  expect(
    root.findAllByProps({ accessibilityLabel: 'Retry response' }),
  ).toHaveLength(0);
  jest.useRealTimers();
});

test('sends verified project context through schema3 without AgentLoop', async () => {
  const runtimeContextId = '11111111-1111-4111-8111-111111111111';
  const snapshotId = '22222222-2222-4222-8222-222222222222';
  const consentReceiptId = '33333333-3333-4333-8333-333333333333';
  const projectId = '44444444-4444-4444-8444-444444444444';
  const preparationId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  const lifecycleIds = [
    runtimeContextId,
    '55555555-5555-4555-8555-555555555555',
    '66666666-6666-4666-8666-666666666666',
  ];
  let messageId = 0;
  const stored = createChatStore({
    now: () => '2026-08-28T00:00:00.000Z',
    createId: kind => `${kind}-${++messageId}`,
    createLifecycleId: () => lifecycleIds.shift()!,
  });
  const conversationId = stored.createConversation({ projectId });
  expect(stored.ensureRuntimeContextId(conversationId)).toBe(runtimeContextId);
  const manifest = {
    schema_version: 1 as const,
    snapshot_id: snapshotId,
    project_id: projectId,
    project_name: 'verified-demo',
    branch: 'main',
    head_oid: '0'.repeat(40),
    clean: true,
    conflicted: false,
    captured_at: '2026-08-28T00:00:00.000Z',
    policy_version: 'chat-read-v1.0.0' as const,
    provider_host: 'api.deepseek.com' as const,
    model: 'deepseek-v4-flash' as const,
    included: [
      {
        path: 'README.md',
        source: 'tracked_file' as const,
        bytes: 16,
        sha256: 'f'.repeat(64),
      },
    ],
    omitted: [],
    context_bytes: 16,
    estimated_tokens: 4,
    snapshot_sha256: 'd'.repeat(64),
    source_fingerprint: 'e'.repeat(64),
  };
  const consent = {
    schema_version: 1 as const,
    consent_receipt_id: consentReceiptId,
    snapshot_id: snapshotId,
    snapshot_sha256: 'd'.repeat(64),
    confirmed_at: '2026-08-28T00:00:01.000Z',
  };
  const preparedConversation = stored.getState().conversations[conversationId]!;
  const prepared = stored.replaceProjectContextPrepared(
    {
      conversationId,
      projectId,
      runtimeContextId,
      modelId: preparedConversation.modelId,
      expectedContext: preparedConversation.projectContext!,
    },
    {
      preparationId,
      selectedPaths: ['README.md'],
      manifest,
    },
  );
  expect(prepared).not.toBeNull();
  expect(prepared!.commit()).toBe(true);

  const confirmedConversation = stored.getState().conversations[conversationId]!;
  const confirmed = stored.replaceProjectContextConfirmed(
    {
      conversationId,
      projectId,
      runtimeContextId,
      modelId: confirmedConversation.modelId,
      expectedContext: confirmedConversation.projectContext!,
    },
    {
      preparationId,
      selectedPaths: ['README.md'],
      manifest,
      consent,
    },
  );
  expect(confirmed).not.toBeNull();
  expect(confirmed!.commit()).toBe(true);
  queuePresentSession(stored.serialize());
  mockLocalProjectContext.inspect.mockResolvedValueOnce({
    schema_version: 1,
    state: 'confirmed',
    manifest,
  });
  mockLocalRuntime.completeV2.mockImplementationOnce(
    async (request: StrictCompletionRequest) => ({
      ...strictCompletionResult(request, { text: 'Verified context answer' }),
      project_context_receipt: {
        schema_version: 1,
        snapshot_id: snapshotId,
        snapshot_sha256: 'd'.repeat(64),
        source_fingerprint: 'e'.repeat(64),
        context_bytes: 16,
        verified_at: '2026-08-28T00:00:02.000Z',
      },
    }),
  );
  const renderer = await renderAppOpeningStoredConversation();
  const root = renderer.root;
  await act(async () => {
    root
      .findByProps({ accessibilityLabel: 'Message DSH' })
      .props.onChangeText('Read verified project');
  });
  await act(async () => {
    await actionByLabel(root, 'Send message').props.onPress();
  });

  expect(mockLocalRuntime.completeV2).toHaveBeenCalledWith(
    expect.objectContaining({
      schemaVersion: 3,
      projectContext: {
        schemaVersion: 1,
        snapshotId,
        consentReceiptId,
        conversationId: runtimeContextId,
        projectId,
        provider: 'deepseek',
        policy: 'chat-read-v1',
      },
    }),
    'dsh',
  );
  expect(mockRunAgentTurn).not.toHaveBeenCalled();
  expect(lastPersistedState().messages.at(-1)?.text).toBe(
    'Verified context answer',
  );
});

test('sends the complete conversation history and persists both messages', async () => {
  const renderer = await renderApp();
  const root = renderer.root;

  await act(async () => {
    root
      .findByProps({ accessibilityLabel: 'Message DSH' })
      .props.onChangeText('First turn');
  });
  await act(async () => {
    root.findByProps({ accessibilityLabel: 'Send message' }).props.onPress();
    await settle();
  });

  expect(mockLocalRuntime.complete).not.toHaveBeenCalled();
  expect(mockLocalRuntime.completeV2).toHaveBeenCalledWith(
    expect.objectContaining({
      schemaVersion: 2,
      model: 'deepseek-v4-flash',
      thinkingMode: 'high',
      visibleHistory: [
        { role: 'user', content: 'First turn', attachments: [] },
      ],
      roundTranscript: [],
      tools: [],
      projectContext: null,
    }),
    'dsh',
  );
  const persisted = lastPersistedState();
  expect(persisted.messages.map(message => message.role)).toEqual([
    'user',
    'assistant',
  ]);
  expect(persisted.messages[1]?.text).toBe('STRICT_LOCAL_OK');
});

test('treats a lost CAS response as durable when the store already holds the candidate', async () => {
  const renderer = await renderApp();
  const root = renderer.root;

  // The native store commits the candidate and then loses its own response,
  // and the follow-up query for the same operation is indeterminate too.
  // This is the shape the device produced: the journal was already durable
  // while the controller was told the write had not landed, which failed the
  // turn with a persistence error that no retry could clear.  The durable
  // snapshot carries this candidate's digest, so the write is provably ours.
  mockSessionSnapshots.casPersistSession.mockImplementationOnce(
    async request => {
      commitBridgedCandidate(request);
      return unknownResult();
    },
  );
  mockSessionSnapshots.querySessionCommit.mockResolvedValueOnce({
    schema_version: 1,
    status: 'unknown',
  });

  await act(async () => {
    root
      .findByProps({ accessibilityLabel: 'Message DSH' })
      .props.onChangeText('First turn');
  });
  await act(async () => {
    root.findByProps({ accessibilityLabel: 'Send message' }).props.onPress();
    await settle();
  });

  expect(mockLocalRuntime.completeV2).toHaveBeenCalledTimes(1);
  expect(
    root.findByProps({ accessibilityLabel: 'Message DSH' }).props.value,
  ).toBe('');
  const persisted = lastPersistedState();
  expect(persisted.messages.map(message => message.role)).toEqual([
    'user',
    'assistant',
  ]);
  expect(bridgedSessionJSON).toBe(lastPersistedCandidateJSON());
});

test('keeps a lost CAS response indeterminate when the store holds other bytes', async () => {
  const renderer = await renderApp();
  const root = renderer.root;

  // Same lost response, but nothing committed.  The durable digest belongs to
  // an older candidate, so the write stays indeterminate and no request is
  // sent: reconciliation must never assume durability it cannot prove.
  mockSessionSnapshots.casPersistSession.mockResolvedValueOnce(unknownResult());
  mockSessionSnapshots.querySessionCommit.mockResolvedValueOnce({
    schema_version: 1,
    status: 'unknown',
  });

  await act(async () => {
    root
      .findByProps({ accessibilityLabel: 'Message DSH' })
      .props.onChangeText('Keep this draft');
  });
  await act(async () => {
    root.findByProps({ accessibilityLabel: 'Send message' }).props.onPress();
    await settle();
  });

  expect(mockLocalRuntime.completeV2).not.toHaveBeenCalled();
  expect(
    root.findByProps({ accessibilityLabel: 'Message DSH' }).props.value,
  ).toBe('Keep this draft');
});

test('preserves the draft and sends zero HTTP when prepared durability is absent', async () => {
  mockLocalAttachments.present.mockResolvedValueOnce({
    schema_version: 1,
    status: 'selected',
    attachments: [
      {
        schema_version: 1,
        id: 'undurable-file',
        kind: 'text',
        name: 'undurable.txt',
        mime_type: 'text/plain',
        size: 32,
      },
    ],
  });
  const renderer = await renderApp();
  const root = renderer.root;
  await act(async () => actionByLabel(root, 'Add attachment').props.onPress());
  await chooseAttachmentSource(root, 'Files');
  mockSessionSnapshots.casPersistSession.mockImplementationOnce(
    async request => sessionOnlyResultFor(request),
  );

  await act(async () => {
    root
      .findByProps({ accessibilityLabel: 'Message DSH' })
      .props.onChangeText('Keep this draft');
  });
  await act(async () => {
    actionByLabel(root, 'Send message').props.onPress();
    await settle();
  });

  expect(
    root.findByProps({ accessibilityLabel: 'Message DSH' }).props.value,
  ).toBe('Keep this draft');
  expect(actionByLabel(root, 'Remove undurable.txt')).toBeDefined();
  expect(mockLocalAttachments.discard).not.toHaveBeenCalledWith([
    'undurable-file',
  ]);
  expect(mockLocalRuntime.completeV2).not.toHaveBeenCalled();
  expect(mockLocalRuntime.complete).not.toHaveBeenCalled();
  expect(mockSessionSnapshots.casPersistSession).toHaveBeenCalledTimes(1);
});

test('moves the draft into the conversation immediately while durability is pending', async () => {
  let resolvePersist!: (saved: boolean) => void;
  const renderer = await renderApp();
  const root = renderer.root;
  mockSessionSnapshots.casPersistSession.mockImplementationOnce(
    async request => {
      await new Promise<boolean>(resolve => {
        resolvePersist = resolve;
      });
      return commitBridgedCandidate(request);
    },
  );
  await act(async () => {
    root
      .findByProps({ accessibilityLabel: 'Message DSH' })
      .props.onChangeText('Durable first');
  });
  await act(async () => {
    actionByLabel(root, 'Send message').props.onPress();
    await Promise.resolve();
  });
  expect(
    root.findByProps({ accessibilityLabel: 'Message DSH' }).props.value,
  ).toBe('');
  expect(root.findAllByProps({ children: 'Durable first' }).length).toBeGreaterThan(0);
  expect(mockLocalRuntime.completeV2).not.toHaveBeenCalled();

  await act(async () => {
    resolvePersist(true);
    await settle();
  });
  expect(
    root.findByProps({ accessibilityLabel: 'Message DSH' }).props.value,
  ).toBe('');
  expect(mockLocalRuntime.completeV2).toHaveBeenCalledTimes(1);
});

test('clears a durable draft after cancellation during its first persistence', async () => {
  mockLocalAttachments.present.mockResolvedValueOnce({
    schema_version: 1,
    status: 'selected',
    attachments: [
      {
        schema_version: 1,
        id: 'cancel-draft-image',
        kind: 'image',
        name: 'cancel-draft.png',
        mime_type: 'image/png',
        size: 128,
      },
    ],
  });
  const renderer = await renderApp();
  const root = renderer.root;
  await act(async () => actionByLabel(root, 'Add attachment').props.onPress());
  await chooseAttachmentSource(root, 'Photos');
  await act(async () => {
    root
      .findByProps({ accessibilityLabel: 'Message DSH' })
      .props.onChangeText('Cancel during save');
  });
  let resolvePersist!: (saved: boolean) => void;
  mockSessionSnapshots.casPersistSession.mockImplementationOnce(
    async request => {
      await new Promise<boolean>(resolve => {
        resolvePersist = resolve;
      });
      return commitBridgedCandidate(request);
    },
  );
  let sendPromise: Promise<unknown> | undefined;
  await act(async () => {
    const result = actionByLabel(root, 'Send message').props.onPress() as unknown;
    if (result instanceof Promise) sendPromise = result;
    await Promise.resolve();
  });
  expect(actionByLabel(root, 'Stop response')).toBeDefined();
  await act(async () => {
    await actionByLabel(root, 'Stop response').props.onPress();
  });
  await act(async () => {
    resolvePersist(true);
    await sendPromise;
  });

  expect(
    root.findByProps({ accessibilityLabel: 'Message DSH' }).props.value,
  ).toBe('');
  expect(
    root.findAllByProps({ accessibilityLabel: 'Remove cancel-draft.png' }),
  ).toHaveLength(0);
  expect(mockLocalRuntime.completeV2).not.toHaveBeenCalled();
  expect(
    lastPersistedState().conversations[0]?.attempts?.at(-1)?.status,
  ).toBe('cancelled');
});

test('shows cancellation persistence failure instead of a false stopped notice', async () => {
  const renderer = await renderApp();
  const root = renderer.root;
  await act(async () => {
    root
      .findByProps({ accessibilityLabel: 'Message DSH' })
      .props.onChangeText('Cancel must persist');
  });
  let resolvePersist!: (saved: boolean) => void;
  mockSessionSnapshots.casPersistSession
    .mockImplementationOnce(async request => {
      await new Promise<boolean>(resolve => {
        resolvePersist = resolve;
      });
      return commitBridgedCandidate(request);
    })
    .mockImplementationOnce(async request => sessionOnlyResultFor(request));
  let sendPromise: Promise<unknown> | undefined;
  await act(async () => {
    const result = actionByLabel(root, 'Send message').props.onPress() as unknown;
    if (result instanceof Promise) sendPromise = result;
    await Promise.resolve();
  });
  await act(async () => {
    await actionByLabel(root, 'Stop response').props.onPress();
  });
  await act(async () => {
    resolvePersist(true);
    await sendPromise;
  });

  const rendered = JSON.stringify(renderer.toJSON());
  expect(rendered).toContain('E_ATTEMPT_PERSISTENCE');
  expect(rendered).not.toContain('Response stopped.');
  expect(actionByLabel(root, 'Retry save')).toBeDefined();
});

test('adds an image attachment, keeps V4 Flash, and sends without text', async () => {
  mockLocalAttachments.present.mockResolvedValueOnce({
    schema_version: 1,
    status: 'selected',
    attachments: [
      {
        schema_version: 1,
        id: 'image-1',
        kind: 'image',
        name: 'camera.jpg',
        mime_type: 'image/jpeg',
        size: 2048,
        thumbnail_data_url: 'data:image/jpeg;base64,dGh1bWI=',
      },
    ],
  });
  const renderer = await renderApp();
  const root = renderer.root;

  await act(async () => actionByLabel(root, 'Add attachment').props.onPress());
  expect(actionByLabel(root, 'Camera')).toBeDefined();
  expect(actionByLabel(root, 'Photos')).toBeDefined();
  expect(actionByLabel(root, 'Files')).toBeDefined();
  const attachmentModal = root.findByProps({
    testID: 'attachment-menu-modal',
  });
  await act(async () => actionByLabel(root, 'Photos').props.onPress());
  expect(mockLocalAttachments.present).not.toHaveBeenCalled();
  await act(async () => {
    attachmentModal.props.onDismiss();
    await settle();
  });

  expect(mockLocalAttachments.present).toHaveBeenCalledWith('photos');
  expect(actionByLabel(root, 'Remove camera.jpg')).toBeDefined();
  expect(mockLocalRuntime.recordModelTransition).not.toHaveBeenCalled();
  expect(
    root.findByProps({ accessibilityLabel: 'Send message' }).props.disabled,
  ).toBe(false);

  await act(async () => {
    actionByLabel(root, 'Send message').props.onPress();
    await settle();
  });

  expect(mockLocalRuntime.completeV2).toHaveBeenCalledWith(
    expect.objectContaining({
      schemaVersion: 2,
      model: 'deepseek-v4-flash',
      thinkingMode: 'high',
      visibleHistory: [
        {
          role: 'user',
          content: '',
          attachments: [
            {
              schema_version: 1,
              id: 'image-1',
              kind: 'image',
              name: 'camera.jpg',
              mime_type: 'image/jpeg',
              size: 2048,
            },
          ],
        },
      ],
    }),
    'dsh',
  );
  const persisted = lastPersistedState();
  expect(persisted.conversations[0]?.model_id).toBe(
    'deepseek-v4-flash',
  );
  expect(persisted.messages[0]?.attachments[0]).toMatchObject({
    id: 'image-1',
    kind: 'image',
  });
  expect(
    persisted.messages[0]?.attachments[0]?.thumbnail_data_url,
  ).toBeUndefined();
  expect(mockLocalAttachments.discard).not.toHaveBeenCalled();
  expect(mockLocalRuntime.recordModelTransition).not.toHaveBeenCalled();
});

test('refuses to send an attachment a platform cannot deliver, keeping the draft', async () => {
  // Android carries no attachment content to a model on either path, so the
  // transport refuses the request. Before this guard the turn was started
  // anyway and the round came back as E_AGENT_EXECUTION_AMBIGUOUS, over a
  // request that provably never left the device, with only retries offered.
  mockLocalAttachments.isModelDeliverySupported.mockReturnValue(false);
  mockLocalAttachments.present.mockResolvedValueOnce({
    schema_version: 1,
    status: 'selected',
    attachments: [
      {
        schema_version: 1,
        id: 'image-1',
        kind: 'image',
        name: 'camera.jpg',
        mime_type: 'image/jpeg',
        size: 2048,
        thumbnail_data_url: 'data:image/jpeg;base64,dGh1bWI=',
      },
    ],
  });
  const renderer = await renderApp();
  const root = renderer.root;

  await act(async () => actionByLabel(root, 'Add attachment').props.onPress());
  const attachmentModal = root.findByProps({
    testID: 'attachment-menu-modal',
  });
  await act(async () => actionByLabel(root, 'Photos').props.onPress());
  await act(async () => {
    attachmentModal.props.onDismiss();
    await settle();
  });
  expect(actionByLabel(root, 'Remove camera.jpg')).toBeDefined();

  await act(async () => {
    actionByLabel(root, 'Send message').props.onPress();
    await settle();
  });

  expect(mockLocalRuntime.completeV2).not.toHaveBeenCalled();
  // The draft and its attachment survive, so the person can remove the image
  // and send the same words.
  expect(actionByLabel(root, 'Remove camera.jpg')).toBeDefined();
  expect(
    JSON.stringify(renderer.toJSON()).includes(
      'cannot send attachments to a model',
    ),
  ).toBe(true);
});

test('ignores a stale attachment-menu dismissal after completion ownership changes', async () => {
  let activeRequest: StrictCompletionRequest | undefined;
  let resolveCompletion:
    | ((value: ReturnType<typeof strictCompletionResult>) => void)
    | undefined;
  mockLocalRuntime.completeV2.mockImplementationOnce(
    (request: StrictCompletionRequest) =>
      new Promise(resolve => {
        activeRequest = request;
        resolveCompletion = resolve;
      }),
  );
  const renderer = await renderApp();
  const root = renderer.root;
  await act(async () => actionByLabel(root, 'Add attachment').props.onPress());
  const menu = root.findByProps({ testID: 'attachment-menu-modal' });
  await act(async () => actionByLabel(root, 'Files').props.onPress());
  await act(async () => {
    root
      .findByProps({ accessibilityLabel: 'Message DSH' })
      .props.onChangeText('Own the composer first');
  });
  await act(async () => {
    actionByLabel(root, 'Send message').props.onPress();
    await settle();
  });

  await act(async () => {
    menu.props.onDismiss();
    await settle();
  });
  expect(mockLocalAttachments.present).not.toHaveBeenCalled();

  await act(async () => {
    await actionByLabel(root, 'Stop response').props.onPress();
    if (activeRequest !== undefined) {
      resolveCompletion?.(strictCompletionResult(activeRequest));
    }
    await settle();
  });
});

test('never discards a referenced attachment through a stale Remove callback', async () => {
  mockLocalAttachments.present.mockResolvedValueOnce({
    schema_version: 1,
    status: 'selected',
    attachments: [
      {
        schema_version: 1,
        id: 'owned-file',
        kind: 'text',
        name: 'owned.txt',
        mime_type: 'text/plain',
        size: 64,
      },
    ],
  });
  let activeRequest: StrictCompletionRequest | undefined;
  let resolveCompletion:
    | ((value: ReturnType<typeof strictCompletionResult>) => void)
    | undefined;
  mockLocalRuntime.completeV2.mockImplementationOnce(
    (request: StrictCompletionRequest) =>
      new Promise(resolve => {
        activeRequest = request;
        resolveCompletion = resolve;
      }),
  );
  const renderer = await renderApp();
  const root = renderer.root;
  await act(async () => actionByLabel(root, 'Add attachment').props.onPress());
  await chooseAttachmentSource(root, 'Files');
  const staleRemove = actionByLabel(root, 'Remove owned.txt').props.onPress;
  mockLocalAttachments.discard.mockClear();
  await act(async () => {
    root
      .findByProps({ accessibilityLabel: 'Message DSH' })
      .props.onChangeText('Persist this file');
  });
  await act(async () => {
    actionByLabel(root, 'Send message').props.onPress();
    await settle();
  });

  await act(async () => {
    staleRemove({ stopPropagation: jest.fn() });
  });
  expect(mockLocalAttachments.discard).not.toHaveBeenCalledWith(['owned-file']);
  expect(lastPersistedState().messages[0]?.attachments[0]?.id).toBe(
    'owned-file',
  );

  await act(async () => {
    await actionByLabel(root, 'Stop response').props.onPress();
    if (activeRequest !== undefined) {
      resolveCompletion?.(strictCompletionResult(activeRequest));
    }
    await settle();
  });
});

test('keeps the existing draft stable while another picker is in flight', async () => {
  mockLocalAttachments.present.mockResolvedValueOnce({
    schema_version: 1,
    status: 'selected',
    attachments: [
      {
        schema_version: 1,
        id: 'existing-draft',
        kind: 'text',
        name: 'existing.txt',
        mime_type: 'text/plain',
        size: 10,
      },
    ],
  });
  const renderer = await renderApp();
  const root = renderer.root;
  await act(async () => actionByLabel(root, 'Add attachment').props.onPress());
  await chooseAttachmentSource(root, 'Files');
  const staleRemove = actionByLabel(root, 'Remove existing.txt').props.onPress;
  let resolvePicker:
    | ((value: {
        schema_version: number;
        status: string;
        attachments: Array<{
          schema_version: number;
          id: string;
          kind: string;
          name: string;
          mime_type: string;
          size: number;
        }>;
      }) => void)
    | undefined;
  mockLocalAttachments.present.mockReturnValueOnce(
    new Promise(resolve => {
      resolvePicker = resolve;
    }),
  );
  mockLocalAttachments.discard.mockClear();
  await act(async () => actionByLabel(root, 'Add attachment').props.onPress());
  await chooseAttachmentSource(root, 'Files');
  expect(
    actionByLabel(root, 'Remove existing.txt').props.disabled,
  ).toBe(true);

  await act(async () => {
    staleRemove({ stopPropagation: jest.fn() });
  });
  expect(mockLocalAttachments.discard).not.toHaveBeenCalledWith([
    'existing-draft',
  ]);
  await act(async () => {
    resolvePicker?.({
      schema_version: 1,
      status: 'selected',
      attachments: [
        {
          schema_version: 1,
          id: 'new-draft',
          kind: 'text',
          name: 'new.txt',
          mime_type: 'text/plain',
          size: 20,
        },
      ],
    });
    await settle();
  });
  expect(actionByLabel(root, 'Remove existing.txt')).toBeDefined();
  expect(actionByLabel(root, 'Remove new.txt')).toBeDefined();
});

test('does not remove native bytes while an attachment preview is active', async () => {
  mockLocalAttachments.present.mockResolvedValueOnce({
    schema_version: 1,
    status: 'selected',
    attachments: [
      {
        schema_version: 1,
        id: 'preview-owned',
        kind: 'text',
        name: 'preview-owned.txt',
        mime_type: 'text/plain',
        size: 12,
      },
    ],
  });
  let closePreview: ((value: unknown) => void) | undefined;
  mockLocalAttachments.presentPreview.mockReturnValueOnce(
    new Promise(resolve => {
      closePreview = resolve;
    }),
  );
  const renderer = await renderApp();
  const root = renderer.root;
  await act(async () => actionByLabel(root, 'Add attachment').props.onPress());
  await chooseAttachmentSource(root, 'Files');
  const staleRemove = actionByLabel(
    root,
    'Remove preview-owned.txt',
  ).props.onPress;
  mockLocalAttachments.discard.mockClear();
  await act(async () => {
    actionByLabel(root, 'Preview preview-owned.txt').props.onPress();
    await Promise.resolve();
  });
  expect(
    actionByLabel(root, 'Remove preview-owned.txt').props.disabled,
  ).toBe(true);

  await act(async () => {
    staleRemove({ stopPropagation: jest.fn() });
  });
  expect(mockLocalAttachments.discard).not.toHaveBeenCalledWith([
    'preview-owned',
  ]);
  await act(async () => {
    closePreview?.({ schema_version: 1, status: 'closed' });
    await settle();
  });
  expect(actionByLabel(root, 'Remove preview-owned.txt')).toBeDefined();
});

test('recovers the attachment button when a native picker promise never settles', async () => {
  mockLocalAttachments.present.mockReturnValueOnce(new Promise(() => {}));
  const renderer = await renderApp();
  const root = renderer.root;
  jest.useFakeTimers();

  await act(async () => actionByLabel(root, 'Add attachment').props.onPress());
  await chooseAttachmentSource(root, 'Photos');
  expect(
    root.findByProps({ accessibilityLabel: 'Add attachment' }).props
      .accessibilityState.busy,
  ).toBe(true);

  await act(async () => {
    jest.advanceTimersByTime(120_000);
    await settle();
  });

  expect(
    root.findByProps({ accessibilityLabel: 'Add attachment' }).props
      .accessibilityState.busy,
  ).toBe(false);
  expect(
    root.findByProps({
      children:
        'Could not add attachment: The attachment picker did not finish. Please try again.',
    }),
  ).toBeDefined();
  jest.useRealTimers();
});

test('blocks send and conversation options while the attachment picker is pending', async () => {
  let resolvePicker:
    | ((value: {
        schema_version: 1;
        status: 'cancelled';
        attachments: [];
      }) => void)
    | undefined;
  mockLocalAttachments.present.mockReturnValueOnce(
    new Promise(resolve => {
      resolvePicker = resolve;
    }),
  );
  const renderer = await renderApp();
  const root = renderer.root;

  await act(async () => {
    root
      .findByProps({ accessibilityLabel: 'Message DSH' })
      .props.onChangeText('Do not race this picker');
  });
  await act(async () => composerOptionsChip(root).props.onPress());
  const staleModelPress = optionInComposerPanel(root, 'Use V4 Pro').props.onPress;
  const staleEffortPress = optionInComposerPanel(
    root,
    'Use Max thinking',
  ).props.onPress;
  await act(async () => optionInComposerPanel(root, 'Done').props.onPress());
  const staleOptionsOpen = composerOptionsChip(root).props.onPress;
  await act(async () => actionByLabel(root, 'Add attachment').props.onPress());
  await chooseAttachmentSource(root, 'Photos');

  const send = actionByLabel(root, 'Send message');
  expect(send.props.disabled).toBe(true);
  expect(composerOptionsChip(root).props.disabled).toBe(true);
  expect(composerOptionsChip(root).props.accessibilityState).toEqual({
    disabled: true,
    expanded: false,
  });
  await act(async () => {
    staleModelPress();
    staleEffortPress();
    staleOptionsOpen();
    await settle();
  });
  expect(composerOptionsChip(root).props.accessibilityLabel).toBe(
    'Model V4 Flash, thinking High',
  );
  expect(
    root.findByProps({ testID: 'conversation-options-modal' }).props.visible,
  ).toBe(false);
  expect(mockLocalRuntime.recordModelTransition).not.toHaveBeenCalled();

  // The screen owns a second guard: even a stale callback or programmatic
  // invocation cannot start a request while native attachment work is active.
  await act(async () => {
    send.props.onPress();
    await settle();
  });
  expect(mockLocalRuntime.complete).not.toHaveBeenCalled();

  await act(async () => {
    resolvePicker?.({
      schema_version: 1,
      status: 'cancelled',
      attachments: [],
    });
    await settle();
  });
  expect(actionByLabel(root, 'Send message').props.disabled).toBe(false);
});

test('discards a late attachment result when the originating conversation changed', async () => {
  let resolvePicker:
    | ((value: {
        schema_version: 1;
        status: 'selected';
        attachments: Array<{
          schema_version: 1;
          id: string;
          kind: 'image';
          name: string;
          mime_type: string;
          size: number;
        }>;
      }) => void)
    | undefined;
  mockLocalAttachments.present.mockReturnValueOnce(
    new Promise(resolve => {
      resolvePicker = resolve;
    }),
  );
  const renderer = await renderApp();
  const root = renderer.root;

  await act(async () => {
    root
      .findByProps({ accessibilityLabel: 'Message DSH' })
      .props.onChangeText('Origin chat');
  });
  await act(async () => {
    actionByLabel(root, 'Send message').props.onPress();
    await settle();
  });
  await act(async () => actionByLabel(root, 'Add attachment').props.onPress());
  await chooseAttachmentSource(root, 'Photos');
  await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
  await act(async () => {
    actionByLabel(root, 'Create new chat').props.onPress();
    await settle();
  });
  await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
  await act(async () => {
    actionByLabel(root, 'Open chat Origin chat').props.onPress();
    await settle();
  });

  await act(async () => {
    resolvePicker?.({
      schema_version: 1,
      status: 'selected',
      attachments: [
        {
          schema_version: 1,
          id: 'late-image',
          kind: 'image',
          name: 'late.png',
          mime_type: 'image/png',
          size: 64,
        },
      ],
    });
    await settle();
  });

  expect(mockLocalAttachments.discard).toHaveBeenCalledWith(['late-image']);
  expect(root.findAllByProps({ accessibilityLabel: 'Remove late.png' })).toHaveLength(0);
  expect(
    lastPersistedState().conversations.every(
      conversation => conversation.model_id === 'deepseek-v4-flash',
    ),
  ).toBe(
    true,
  );
  expect(mockLocalRuntime.recordModelTransition).not.toHaveBeenCalled();
});

test('suppresses a stale picker failure after leaving and returning to its conversation', async () => {
  let rejectPicker: ((error: Error) => void) | undefined;
  mockLocalAttachments.present.mockReturnValueOnce(
    new Promise((_resolve, reject) => {
      rejectPicker = reject;
    }),
  );
  const renderer = await renderApp();
  const root = renderer.root;

  await act(async () => {
    root
      .findByProps({ accessibilityLabel: 'Message DSH' })
      .props.onChangeText('Stable origin');
  });
  await act(async () => {
    actionByLabel(root, 'Send message').props.onPress();
    await settle();
  });
  await act(async () => actionByLabel(root, 'Add attachment').props.onPress());
  await chooseAttachmentSource(root, 'Photos');
  await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
  await act(async () => {
    actionByLabel(root, 'Create new chat').props.onPress();
    await settle();
  });
  await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
  await act(async () => {
    actionByLabel(root, 'Open chat Stable origin').props.onPress();
    await settle();
  });
  await act(async () => {
    rejectPicker?.(new Error('late picker failure'));
    await settle();
  });

  expect(
    root.findAllByProps({
      children: 'Could not add attachment: late picker failure',
    }),
  ).toHaveLength(0);
  expect(
    root.findByProps({ accessibilityLabel: 'Add attachment' }).props
      .accessibilityState.busy,
  ).toBe(false);
});

test('keeps the selected model when a draft image is selected then removed', async () => {
  mockLocalAttachments.present.mockResolvedValueOnce({
    schema_version: 1,
    status: 'selected',
    attachments: [
      {
        schema_version: 1,
        id: 'removed-image',
        kind: 'image',
        name: 'remove-before-send.png',
        mime_type: 'image/png',
        size: 32,
      },
    ],
  });
  const renderer = await renderApp();
  const root = renderer.root;

  await act(async () => composerOptionsChip(root).props.onPress());
  await act(async () => {
    optionInComposerPanel(root, 'Use V4 Pro').props.onPress();
    await settle();
  });
  await act(async () => optionInComposerPanel(root, 'Done').props.onPress());

  mockLocalRuntime.recordModelTransition.mockClear();
  await act(async () => actionByLabel(root, 'Add attachment').props.onPress());
  await chooseAttachmentSource(root, 'Photos');
  expect(lastPersistedState().conversations[0]?.model_id).toBe(
    'deepseek-v4-pro',
  );
  expect(mockLocalRuntime.recordModelTransition).not.toHaveBeenCalled();

  await act(async () => {
    actionByLabel(root, 'Remove remove-before-send.png').props.onPress({
      stopPropagation: jest.fn(),
    });
    root
      .findByProps({ accessibilityLabel: 'Message DSH' })
      .props.onChangeText('Text only');
    await settle();
  });
  await act(async () => {
    actionByLabel(root, 'Send message').props.onPress();
    await settle();
  });

  expect(mockLocalRuntime.completeV2.mock.calls.at(-1)?.[0]?.model).toBe(
    'deepseek-v4-pro',
  );
  expect(lastPersistedState().conversations[0]?.model_id).toBe(
    'deepseek-v4-pro',
  );
  expect(mockLocalRuntime.recordModelTransition).not.toHaveBeenCalled();
});

test('removes an unsent attachment from native storage', async () => {
  mockLocalAttachments.present.mockResolvedValueOnce({
    schema_version: 1,
    status: 'selected',
    attachments: [
      {
        schema_version: 1,
        id: 'text-1',
        kind: 'text',
        name: 'notes.txt',
        mime_type: 'text/plain',
        size: 12,
      },
    ],
  });
  const renderer = await renderApp();
  const root = renderer.root;

  await act(async () => actionByLabel(root, 'Add attachment').props.onPress());
  await chooseAttachmentSource(root, 'Files');
  const stopPropagation = jest.fn();
  await act(async () => {
    actionByLabel(root, 'Remove notes.txt').props.onPress({ stopPropagation });
    await settle();
  });

  expect(stopPropagation).toHaveBeenCalledTimes(1);
  expect(mockLocalAttachments.discard).toHaveBeenCalledWith(['text-1']);
  expect(mockLocalAttachments.presentPreview).not.toHaveBeenCalled();
  expect(
    root.findByProps({ accessibilityLabel: 'Send message' }).props.disabled,
  ).toBe(true);
});

test('previews image, text, and PDF attachments from draft and history cards', async () => {
  mockLocalAttachments.present.mockResolvedValueOnce({
    schema_version: 1,
    status: 'selected',
    attachments: [
      {
        schema_version: 1,
        id: 'preview-image',
        kind: 'image',
        name: 'preview.png',
        mime_type: 'image/png',
        size: 120,
        thumbnail_data_url: 'data:image/png;base64,cHJldmlldw==',
      },
      {
        schema_version: 1,
        id: 'preview-text',
        kind: 'text',
        name: 'preview.txt',
        mime_type: 'text/plain',
        size: 24,
      },
      {
        schema_version: 1,
        id: 'preview-pdf',
        kind: 'pdf',
        name: 'preview.pdf',
        mime_type: 'application/pdf',
        size: 2048,
      },
    ],
  });
  const renderer = await renderApp();
  const root = renderer.root;

  await act(async () => actionByLabel(root, 'Add attachment').props.onPress());
  await chooseAttachmentSource(root, 'Files');
  for (const name of ['preview.png', 'preview.txt', 'preview.pdf']) {
    await act(async () => {
      actionByLabel(root, `Preview ${name}`).props.onPress();
      await settle();
    });
  }
  expect(
    mockLocalAttachments.presentPreview.mock.calls.map(call => call[0]),
  ).toEqual(['preview-image', 'preview-text', 'preview-pdf']);

  await act(async () => {
    actionByLabel(root, 'Send message').props.onPress();
    await settle();
  });
  mockLocalAttachments.presentPreview.mockClear();
  for (const name of ['preview.png', 'preview.txt', 'preview.pdf']) {
    await act(async () => {
      actionByLabel(root, `Preview ${name}`).props.onPress();
      await settle();
    });
  }
  expect(
    mockLocalAttachments.presentPreview.mock.calls.map(call => call[0]),
  ).toEqual(['preview-image', 'preview-text', 'preview-pdf']);
});

test('serializes preview presentation and recovers from a native rejection', async () => {
  mockLocalAttachments.present.mockResolvedValueOnce({
    schema_version: 1,
    status: 'selected',
    attachments: [
      {
        schema_version: 1,
        id: 'busy-text',
        kind: 'text',
        name: 'busy.txt',
        mime_type: 'text/plain',
        size: 10,
      },
      {
        schema_version: 1,
        id: 'busy-pdf',
        kind: 'pdf',
        name: 'busy.pdf',
        mime_type: 'application/pdf',
        size: 100,
      },
    ],
  });
  let closePreview: ((value: unknown) => void) | undefined;
  mockLocalAttachments.presentPreview.mockReturnValueOnce(
    new Promise(resolve => {
      closePreview = resolve;
    }),
  );
  const renderer = await renderApp();
  const root = renderer.root;

  await act(async () => actionByLabel(root, 'Add attachment').props.onPress());
  await chooseAttachmentSource(root, 'Files');
  await act(async () =>
    actionByLabel(root, 'Preview busy.txt').props.onPress(),
  );

  expect(
    actionByLabel(root, 'Preview busy.txt').props.accessibilityState.busy,
  ).toBe(true);
  expect(actionByLabel(root, 'Preview busy.pdf').props.disabled).toBe(true);
  expect(mockLocalAttachments.presentPreview).toHaveBeenCalledTimes(1);

  await act(async () => {
    closePreview?.({ schema_version: 1, status: 'closed' });
    await settle();
  });
  expect(actionByLabel(root, 'Preview busy.pdf').props.disabled).toBe(false);

  mockLocalAttachments.presentPreview.mockRejectedValueOnce(
    new Error('preview controller unavailable'),
  );
  await act(async () => {
    actionByLabel(root, 'Preview busy.pdf').props.onPress();
    await settle();
  });
  expect(
    root.findByProps({
      children: 'Could not preview attachment: preview controller unavailable',
    }),
  ).toBeDefined();
  expect(
    actionByLabel(root, 'Preview busy.pdf').props.accessibilityState.busy,
  ).toBe(false);
});

test('enforces the six-attachment limit across repeated picker sessions', async () => {
  const attachment = (index: number) => ({
    schema_version: 1,
    id: `text-${index}`,
    kind: 'text',
    name: `note-${index}.txt`,
    mime_type: 'text/plain',
    size: 1,
  });
  mockLocalAttachments.present
    .mockResolvedValueOnce({
      schema_version: 1,
      status: 'selected',
      attachments: [1, 2, 3, 4, 5].map(attachment),
    })
    .mockResolvedValueOnce({
      schema_version: 1,
      status: 'selected',
      attachments: [6, 7].map(attachment),
    });
  const renderer = await renderApp();
  const root = renderer.root;

  for (let selection = 0; selection < 2; selection += 1) {
    await act(async () =>
      actionByLabel(root, 'Add attachment').props.onPress(),
    );
    await chooseAttachmentSource(root, 'Files');
  }

  expect(actionByLabel(root, 'Remove note-6.txt')).toBeDefined();
  expect(
    root.findAllByProps({ accessibilityLabel: 'Remove note-7.txt' }),
  ).toHaveLength(0);
  expect(mockLocalAttachments.discard).toHaveBeenCalledWith(['text-7']);
  expect(
    root.findByProps({
      children: 'Up to 6 attachments and 24 MB per message.',
    }),
  ).toBeDefined();
});

test('restores persisted image thumbnails through the bounded preview API', async () => {
  const imageAttachment = {
    schema_version: 1,
    id: 'restored-image',
    kind: 'image',
    name: 'restored.png',
    mime_type: 'image/png',
    size: 99,
  };
  const message = {
    id: 'message-restored',
    role: 'user',
    text: 'Inspect this',
    created_at: '2026-08-24T00:00:01.000Z',
    attachments: [imageAttachment],
  };
  queueLegacySession(
    JSON.stringify({
      schema_version: 4,
      active_conversation_id: 'conversation-restored',
      conversations: [
        {
          id: 'conversation-restored',
          project_id: null,
          title: 'Inspect this',
          title_source: 'auto',
          model_id: 'deepseek-v4-flash-vision-exp',
          thinking_mode: 'high',
          messages: [message],
          created_at: '2026-08-24T00:00:00.000Z',
          updated_at: '2026-08-24T00:00:01.000Z',
        },
      ],
      messages: [message],
    }),
  );
  mockLocalAttachments.preview.mockResolvedValueOnce({
    schema_version: 1,
    id: 'restored-image',
    thumbnail_data_url: 'data:image/png;base64,cmVzdG9yZWQ=',
  });

  const renderer = await renderAppOpeningStoredConversation();
  const root = renderer.root;

  expect(mockLocalAttachments.prune).toHaveBeenCalledWith(['restored-image']);
  expect(mockLocalAttachments.preview).toHaveBeenCalledWith('restored-image');
  expect(
    root.findAll(
      node => node.props.source?.uri === 'data:image/png;base64,cmVzdG9yZWQ=',
    ).length,
  ).toBeGreaterThanOrEqual(1);
});

test('globally prunes sent attachments only after their conversation is persisted as deleted', async () => {
  mockLocalAttachments.present.mockResolvedValueOnce({
    schema_version: 1,
    status: 'selected',
    attachments: [
      {
        schema_version: 1,
        id: 'delete-image',
        kind: 'image',
        name: 'delete-me.jpg',
        mime_type: 'image/jpeg',
        size: 100,
      },
    ],
  });
  const alert = jest
    .spyOn(Alert, 'alert')
    .mockImplementation((_title, _message, buttons) => {
      buttons?.find(button => button.style === 'destructive')?.onPress?.();
    });
  const renderer = await renderApp();
  const root = renderer.root;

  await act(async () => actionByLabel(root, 'Add attachment').props.onPress());
  await chooseAttachmentSource(root, 'Photos');
  await act(async () => {
    actionByLabel(root, 'Send message').props.onPress();
    await settle();
  });
  expect(mockLocalAttachments.discard).not.toHaveBeenCalled();

  await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
  await act(async () =>
    actionByLabel(root, 'Chat actions for delete-me.jpg').props.onPress(),
  );
  await act(async () => {
    actionByLabel(root, 'Delete conversation').props.onPress();
    await settle();
  });

  expect(mockLocalAttachments.prune).toHaveBeenLastCalledWith([]);
  expect(mockLocalAttachments.discard).not.toHaveBeenCalled();
  expect(lastPersistedState().messages).toEqual([]);
  alert.mockRestore();
});

test('creates a second chat without overwriting the completed conversation', async () => {
  const renderer = await renderApp();
  const root = renderer.root;

  await act(async () => {
    root
      .findByProps({ accessibilityLabel: 'Message DSH' })
      .props.onChangeText('Keep this chat');
  });
  await act(async () => {
    root.findByProps({ accessibilityLabel: 'Send message' }).props.onPress();
    await settle();
  });
  await act(async () => {
    root.findByProps({ accessibilityLabel: 'Open navigation' }).props.onPress();
  });
  await act(async () => {
    root.findByProps({ accessibilityLabel: 'Create new chat' }).props.onPress();
    await settle();
  });

  const persisted = lastPersistedState();
  expect(persisted.conversations).toHaveLength(2);
  expect(
    persisted.conversations.some(
      conversation => conversation.messages.length === 2,
    ),
  ).toBe(true);
  expect(persisted.messages).toEqual([]);
});

test('creates a file through the app-owned workspace drawer', async () => {
  mockLocalWorkspaces.isAvailable.mockReturnValue(true);
  const workspace = appWorkspaceDescriptor();
  workspace.capabilities.git = true;
  workspace.capabilities.project_context = true;
  mockLocalProjects.isV2Available.mockReturnValue(true);
  mockLocalWorkspaces.create.mockResolvedValue(workspace);
  mockLocalWorkspaces.resolve.mockResolvedValue({ schema_version: 1, disposition: 'direct', workspace });
  const renderer = await renderApp();
  const root = renderer.root;

  await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
  await act(async () => actionByLabel(root, 'Files').props.onPress());
  await act(async () => {
    await settle();
  });
  expect(root.findByType(AgentPolicySheet).props.workspaceName).toBe('Workspace');
  expect(root.findByType(AgentPolicySheet).props.gitActivationAvailable).toBe(true);
  expect(mockLocalProjects.attachWorkspaceProject).not.toHaveBeenCalled();
  await act(async () => actionByLabel(root, 'New file').props.onPress());
  await act(async () => {
    root
      .findByProps({ accessibilityLabel: 'Name' })
      .props.onChangeText('note.md');
  });
  await act(async () => {
    actionByLabel(root, 'Create').props.onPress();
    await settle();
  });

  expect(mockLocalWorkspace.writeV2).toHaveBeenCalledWith(
    expect.objectContaining({
      schema_version: 1,
      path: 'note.md',
      content: '',
      expected_revision: null,
      create_only: true,
      root: expect.objectContaining({
        workspace_id: APP_WORKSPACE_ID,
        binding_revision: 1,
        project_id: null,
      }),
    }),
  );
});

test('local workspace selection remains available without a model API key', async () => {
  mockLocalWorkspaces.isAvailable.mockReturnValue(true);
  mockLocalRuntime.credentialStatusForSlot.mockResolvedValue({ status: 'missing' });
  mockLocalRuntime.credentialStatus.mockResolvedValue({ status: 'missing' });
  const renderer = await renderApp();
  const root = renderer.root;
  expect(root.findByType(ChatComposer).props.configured).toBe(false);
  const chip = root.findByProps({ testID: 'composer-workspace-chip' });
  expect(chip.props.disabled).toBe(false);
  await act(async () => { chip.props.onPress(); await settle(); });
  expect(root.findByType(WorkspacePickerSheet).props.visible).toBe(true);
  expect(mockLocalRuntime.presentCredentialPromptForSlot).not.toHaveBeenCalled();
});

test('waits for environment native dismissal before opening the program surface', async () => {
  mockLocalWorkspaces.isAvailable.mockReturnValue(true);
  const workspace = appWorkspaceDescriptor();
  mockLocalWorkspaces.create.mockResolvedValue(workspace);
  mockLocalWorkspaces.resolve.mockResolvedValue({ schema_version: 1, disposition: 'direct', workspace });
  const renderer = await renderApp();
  const root = renderer.root;
  await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
  await act(async () => { actionByLabel(root, 'Files').props.onPress(); await settle(); });
  await act(async () => { root.findByType(WorkspaceDrawer).props.onClose(); await settle(); });
  await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
  await act(async () => actionByLabel(root, 'Settings').props.onPress());
  await act(async () => root.findByType(SettingsSheet).props.onOpenEnvironments());
  expect(root.findByType(RuntimeEnvironmentSheet).props.visible).toBe(true);
  await act(async () => root.findByType(RuntimeEnvironmentSheet).props.onRun());
  expect(root.findByType(RuntimeEnvironmentSheet).props.visible).toBe(false);
  expect(root.findByType(RuntimeProgramSheet).props.visible).toBe(false);
  await act(async () => root.findByType(RuntimeEnvironmentSheet).props.onDismiss());
  expect(root.findByType(RuntimeProgramSheet).props.visible).toBe(true);
  expect(root.findByType(RuntimeProgramSheet).props.root).toEqual({
    schema_version: 1, workspace_id: APP_WORKSPACE_ID, binding_revision: 1, project_id: null,
  });
  await act(async () => root.findByType(RuntimeProgramSheet).props.onClose());
  await act(async () => root.findByType(RuntimeEnvironmentSheet).props.onDismiss());
  expect(root.findByType(RuntimeProgramSheet).props.visible).toBe(false);
});

test('opens the honest local profile entry from the drawer footer', async () => {
  const renderer = await renderApp();
  const root = renderer.root;

  await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
  expect(actionByLabel(root, 'Settings')).toBeDefined();
  await act(async () =>
    actionByLabel(root, 'Open local profile').props.onPress(),
  );
  await act(async () => settle());

  expect(root.findByProps({ children: 'Rish profile' })).toBeDefined();
  expect(
    root.findByProps({ accessibilityLabel: 'Account & sync · coming soon' }).props
      .accessibilityState,
  ).toEqual({ disabled: true });
});

test('closes settings back to the still-open navigation drawer', async () => {
  const renderer = await renderApp();
  const root = renderer.root;

  await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
  await act(async () => actionByLabel(root, 'Settings').props.onPress());
  expect(root.findByProps({ children: 'Settings' })).toBeDefined();

  await act(async () => actionByLabel(root, 'Close settings').props.onPress());
  await act(async () => settle());

  expect(actionByLabel(root, 'Open local profile')).toBeDefined();
  expect(actionByLabel(root, 'Settings')).toBeDefined();
  expect(
    root
      .findAllByProps({ children: 'Settings' })
      .filter(node => node.props.accessibilityRole === 'header'),
  ).toHaveLength(0);
});

test('opens one combined composer options panel and keeps it open across changes', async () => {
  const dismissKeyboard = jest
    .spyOn(Keyboard, 'dismiss')
    .mockImplementation(() => undefined);
  const renderer = await renderApp();
  const root = renderer.root;

  expect(composerOptionsChip(root).props.accessibilityState).toEqual({
    disabled: false,
    expanded: false,
  });

  await act(async () => composerOptionsChip(root).props.onPress());
  expect(dismissKeyboard).toHaveBeenCalledTimes(1);
  const modal = () => root.findByProps({ testID: 'conversation-options-modal' });
  expect(modal().props.visible).toBe(true);
  expect(
    root.findByProps({ testID: 'model-picker-modal' }).props.visible,
  ).toBe(false);
  expect(composerOptionsChip(root).props.accessibilityState).toEqual({
    disabled: false,
    expanded: true,
  });

  await act(async () => {
    optionInComposerPanel(root, 'Use V4 Pro').props.onPress();
    await settle();
  });
  expect(mockLocalRuntime.recordModelTransition).toHaveBeenCalledWith({
    attachment_busy: false,
    conversation_id: expect.any(String),
    draft_image_count: 0,
    from_model: 'deepseek-v4-flash',
    history_image_count: 0,
    request_epoch: 0,
    request_state: 'idle',
    source: 'composer_picker',
    to_model: 'deepseek-v4-pro',
  });
  expect(modal().props.visible).toBe(true);
  expect(dismissKeyboard).toHaveBeenCalledTimes(1);
  expect(composerOptionsChip(root).props.accessibilityLabel).toBe(
    'Model V4 Pro, thinking High',
  );

  await act(async () => {
    optionInComposerPanel(root, 'Use Max thinking').props.onPress();
    await settle();
  });
  expect(modal().props.visible).toBe(true);

  await act(async () =>
    optionInComposerPanel(root, 'Done').props.onPress(),
  );
  await act(async () => settle());
  expect(modal().props.visible).toBe(false);
  expect(composerOptionsChip(root).props.accessibilityState).toEqual({
    disabled: false,
    expanded: false,
  });
  expect(composerOptionsChip(root).props.accessibilityLabel).toBe(
    'Model V4 Pro, thinking Max',
  );

  dismissKeyboard.mockRestore();
});

test('closes the combined panel from its light scrim without changing anything', async () => {
  const renderer = await renderApp();
  const root = renderer.root;

  await act(async () => composerOptionsChip(root).props.onPress());
  await act(async () => {
    root
      .findByProps({ testID: 'conversation-options-backdrop' })
      .props.onPress();
  });
  await act(async () => settle());

  expect(
    root.findByProps({ testID: 'conversation-options-modal' }).props.visible,
  ).toBe(false);
  expect(composerOptionsChip(root).props.accessibilityLabel).toBe(
    'Model V4 Flash, thinking High',
  );
});

test('freezes model and effort while a request is in flight', async () => {
  let finishInitialPersist: ((value: boolean) => void) | undefined;
  let finishRequest:
    | ((value: ReturnType<typeof strictCompletionResult>) => void)
    | undefined;
  let frozenRequest: StrictCompletionRequest | undefined;
  mockLocalRuntime.completeV2.mockImplementationOnce(
    (request: StrictCompletionRequest) => {
      frozenRequest = request;
      return new Promise(resolve => {
        finishRequest = resolve;
      });
    },
  );
  const renderer = await renderApp();
  const root = renderer.root;

  await act(async () => composerOptionsChip(root).props.onPress());
  const staleModelPress = optionInComposerPanel(root, 'Use V4 Pro').props.onPress;
  const staleEffortPress = optionInComposerPanel(
    root,
    'Use Max thinking',
  ).props.onPress;
  await act(async () => optionInComposerPanel(root, 'Done').props.onPress());
  await act(async () => {
    root
      .findByProps({ accessibilityLabel: 'Message DSH' })
      .props.onChangeText('Freeze this request');
  });
  mockSessionSnapshots.casPersistSession.mockImplementationOnce(
    async request => {
      await new Promise<boolean>(resolve => {
        finishInitialPersist = resolve;
      });
      return commitBridgedCandidate(request);
    },
  );
  const staleSendPress = actionByLabel(root, 'Send message').props.onPress;
  await act(async () => {
    staleSendPress();
    await settle();
  });

  expect(composerOptionsChip(root).props.disabled).toBe(true);
  expect(composerOptionsChip(root).props.accessibilityState).toEqual({
    disabled: true,
    expanded: false,
  });
  await act(async () => {
    // These callbacks came from the render before `sending`; the screen guard
    // must reject them rather than trusting only Pressable.disabled.
    staleModelPress();
    staleEffortPress();
    staleSendPress();
    await settle();
  });
  expect(lastPersistedState().conversations[0]).toMatchObject({
    model_id: 'deepseek-v4-flash',
    thinking_mode: 'high',
  });
  expect(mockLocalRuntime.recordModelTransition).not.toHaveBeenCalled();
  expect(mockSessionSnapshots.casPersistSession).toHaveBeenCalledTimes(1);
  expect(mockLocalRuntime.completeV2).not.toHaveBeenCalled();

  await act(async () => {
    finishInitialPersist?.(true);
    await settle();
  });
  expect(mockLocalRuntime.completeV2.mock.calls[0]?.[0]?.model).toBe(
    'deepseek-v4-flash',
  );
  expect(mockLocalRuntime.completeV2.mock.calls[0]?.[0]?.thinkingMode).toBe(
    'high',
  );

  await act(async () => {
    if (frozenRequest !== undefined) {
      finishRequest?.(
        strictCompletionResult(frozenRequest, {
          text: 'Frozen response',
          latency_ms: 9,
        }),
      );
    }
    await settle();
  });
  const persisted = lastPersistedState();
  expect(persisted.conversations[0]?.model_id).toBe('deepseek-v4-flash');
  expect(persisted.conversations[0]?.messages.at(-1)?.metadata?.model_id).toBe(
    'deepseek-v4-flash',
  );
});

test('keeps model, effort, and attachments frozen while persistence is pending', async () => {
  const renderer = await renderApp();
  const root = renderer.root;
  await act(async () => composerOptionsChip(root).props.onPress());
  const staleModelPress = optionInComposerPanel(root, 'Use V4 Pro').props.onPress;
  const staleEffortPress = optionInComposerPanel(
    root,
    'Use Max thinking',
  ).props.onPress;
  await act(async () => optionInComposerPanel(root, 'Done').props.onPress());
  mockSessionSnapshots.casPersistSession.mockImplementationOnce(async request => {
    return sessionOnlyResultFor(request);
  });
  await act(async () => {
    root
      .findByProps({ accessibilityLabel: 'Message DSH' })
      .props.onChangeText('Hold pending state');
  });
  await act(async () => {
    await actionByLabel(root, 'Send message').props.onPress();
  });

  expect(actionByLabel(root, 'Retry save')).toBeDefined();
  expect(composerOptionsChip(root).props.disabled).toBe(true);
  expect(actionByLabel(root, 'Add attachment').props.disabled).toBe(true);
  expect(
    root.findAllByProps({ accessibilityLabel: 'Stop response' }),
  ).toHaveLength(0);
  expect(actionByLabel(root, 'Send message').props.disabled).toBe(true);
  expect(
    root.findAllByProps({ accessibilityLabel: 'Configure DeepSeek key' }),
  ).toHaveLength(0);
  await act(async () => {
    staleModelPress();
    staleEffortPress();
  });
  expect(lastPersistedState().conversations[0]).toMatchObject({
    model_id: 'deepseek-v4-flash',
    thinking_mode: 'high',
  });
  expect(mockLocalRuntime.recordModelTransition).not.toHaveBeenCalled();
  expect(mockLocalRuntime.completeV2).not.toHaveBeenCalled();
});

test('opens the compact model popover from settings and returns to settings', async () => {
  const renderer = await renderApp();
  const root = renderer.root;

  await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
  await act(async () => actionByLabel(root, 'Settings').props.onPress());
  await act(async () =>
    actionByLabel(root, 'Choose default model').props.onPress(),
  );

  const anchorStyle = StyleSheet.flatten(
    root.findByProps({ testID: 'model-picker-anchor' }).props.style,
  );
  expect(anchorStyle.paddingHorizontal).toBe(18);
  expect(anchorStyle.paddingBottom).toBe(52);
  expect(root.findByProps({ children: 'Settings' })).toBeDefined();

  await act(async () =>
    root.findByProps({ testID: 'model-picker-backdrop' }).props.onPress(),
  );
  expect(root.findByProps({ testID: 'model-picker-modal' }).props.visible).toBe(
    false,
  );
  expect(root.findByProps({ children: 'Settings' })).toBeDefined();

  await act(async () => actionByLabel(root, 'Close settings').props.onPress());
  await act(async () => settle());
  expect(actionByLabel(root, 'Open local profile')).toBeDefined();
});

test('audits settings model changes with their distinct source', async () => {
  const renderer = await renderApp();
  const root = renderer.root;

  await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
  await act(async () => actionByLabel(root, 'Settings').props.onPress());
  await act(async () =>
    actionByLabel(root, 'Choose default model').props.onPress(),
  );
  await act(async () => {
    actionByLabel(root, 'Use V4 Pro').props.onPress();
    await settle();
  });

  expect(mockLocalRuntime.recordModelTransition).toHaveBeenCalledWith(
    expect.objectContaining({
      from_model: 'deepseek-v4-flash',
      source: 'settings_picker',
      to_model: 'deepseek-v4-pro',
    }),
  );
});

test('stages a custom npm mirror through the native rish adapter', async () => {
  const renderer = await renderApp();
  const root = renderer.root;

  await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
  await act(async () => actionByLabel(root, 'Settings').props.onPress());
  await act(async () => actionByLabel(root, 'Package mirrors').props.onPress());
  await act(async () => settle());

  await act(async () => {
    root
      .findByProps({
        accessibilityLabel: 'Custom HTTPS base URL Node.js npm',
      })
      .props.onChangeText('https://registry.npmmirror.com');
  });
  await act(async () => {
    root
      .findByProps({ accessibilityLabel: 'Use this mirror Node.js npm' })
      .props.onValueChange(true);
  });
  await act(async () => {
    actionByLabel(root, 'Save mirror configuration').props.onPress();
    await settle();
  });

  expect(mockLocalMirrors.apply).toHaveBeenCalledWith(
    expect.objectContaining({
      npm: {
        enabled: true,
        baseUrl: 'https://registry.npmmirror.com/',
      },
    }),
  );
  const persisted = JSON.parse(
    mockSessionSnapshots.casPersistSession.mock.calls.at(-1)?.[0]
      ?.candidate_json,
  ) as {
    preferences: { mirrors: { npm: { enabled: boolean; base_url: string } } };
  };
  expect(persisted.preferences.mirrors.npm).toEqual({
    enabled: true,
    base_url: 'https://registry.npmmirror.com/',
  });

  await act(async () => {
    actionByLabel(root, 'Back to settings').props.onPress();
    await settle();
  });
  expect(root.findByProps({ children: 'Settings' })).toBeDefined();
});

test('persists only a validated Git HTTPS proxy and clears it to direct', async () => {
  const renderer = await renderApp();
  const root = renderer.root;

  await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
  await act(async () => actionByLabel(root, 'Settings').props.onPress());
  mockSessionSnapshots.casPersistSession.mockClear();

  await act(async () => {
    root
      .findByProps({ accessibilityLabel: 'Git HTTPS proxy URL' })
      .props.onChangeText('http://127.0.0.1');
  });
  await act(async () => {
    actionByLabel(root, 'Save Git proxy').props.onPress();
    await settle();
  });

  expect(mockSessionSnapshots.casPersistSession).not.toHaveBeenCalled();
  expect(
    root.findByProps({
      children:
        'Enter http:// or https:// with a host and explicit port, without credentials, a path, query, fragment, or surrounding spaces.',
    }),
  ).toBeDefined();

  await act(async () => {
    root
      .findByProps({ accessibilityLabel: 'Git HTTPS proxy URL' })
      .props.onChangeText('http://127.0.0.1:1082');
  });
  await act(async () => {
    actionByLabel(root, 'Save Git proxy').props.onPress();
    await settle();
  });

  const configured = JSON.parse(
    mockSessionSnapshots.casPersistSession.mock.calls.at(-1)?.[0]
      ?.candidate_json,
  ) as { preferences: { git_https_proxy_url: string | null } };
  expect(configured.preferences.git_https_proxy_url).toBe(
    'http://127.0.0.1:1082/',
  );
  expect(
    root.findByProps({ accessibilityLabel: 'Git HTTPS proxy URL' }).props.value,
  ).toBe('http://127.0.0.1:1082/');

  await act(async () => {
    actionByLabel(root, 'Clear Git proxy').props.onPress();
    await settle();
  });
  const cleared = JSON.parse(
    mockSessionSnapshots.casPersistSession.mock.calls.at(-1)?.[0]
      ?.candidate_json,
  ) as { preferences: { git_https_proxy_url: string | null } };
  expect(cleared.preferences.git_https_proxy_url).toBeNull();
  expect(
    root.findByProps({ accessibilityLabel: 'Git HTTPS proxy URL' }).props.value,
  ).toBe('');
});

test('retries an indeterminate session write by query with the same operation and candidate', async () => {
  const renderer = await renderApp();
  const root = renderer.root;
  await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
  await act(async () => actionByLabel(root, 'Settings').props.onPress());

  mockSessionSnapshots.casPersistSession.mockResolvedValueOnce({
    schema_version: 1,
    status: 'unknown',
    current: { schema_version: 1, kind: 'missing' },
  });
  mockSessionSnapshots.querySessionCommit
    .mockResolvedValueOnce({ schema_version: 1, status: 'unknown' })
    .mockImplementationOnce(async request => {
      const casRequest =
        mockSessionSnapshots.casPersistSession.mock.calls[0]?.[0];
      const candidateJSON = casRequest?.candidate_json as string;
      return commitBridgedCandidate({
        operation_id: request.operation_id,
        candidate_json: candidateJSON,
      });
    });

  await act(async () => {
    root
      .findByProps({ accessibilityLabel: 'Git HTTPS proxy URL' })
      .props.onChangeText('http://127.0.0.1:1082');
  });
  await act(async () => {
    actionByLabel(root, 'Save Git proxy').props.onPress();
    await settle();
  });
  await act(async () => {
    actionByLabel(root, 'Save Git proxy').props.onPress();
    await settle();
  });

  expect(mockSessionSnapshots.casPersistSession).toHaveBeenCalledTimes(1);
  expect(mockSessionSnapshots.querySessionCommit).toHaveBeenCalledTimes(2);
  const firstQuery =
    mockSessionSnapshots.querySessionCommit.mock.calls[0]?.[0];
  const secondQuery =
    mockSessionSnapshots.querySessionCommit.mock.calls[1]?.[0];
  expect(secondQuery?.operation_id).toBe(firstQuery?.operation_id);
  expect(
    mockSessionSnapshots.casPersistSession.mock.calls[0]?.[0].candidate_json,
  ).toBeDefined();
});

test('retries session-only durability by the exact operation before any second CAS', async () => {
  const renderer = await renderApp();
  const root = renderer.root;
  await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
  await act(async () => actionByLabel(root, 'Settings').props.onPress());

  mockSessionSnapshots.casPersistSession.mockImplementationOnce(async request => {
    const candidateJSON = request.candidate_json as string;
    return {
      schema_version: 1,
      status: 'session_only',
      current: {
        schema_version: 1,
        kind: 'present',
        snapshot: {
          schema_version: 1,
          generation: 1,
          session_sha256: sessionSnapshotSHA256(candidateJSON)!,
        },
      },
    };
  });
  mockSessionSnapshots.querySessionCommit.mockImplementationOnce(async request => {
    const candidateJSON =
      mockSessionSnapshots.casPersistSession.mock.calls[0]?.[0]
        ?.candidate_json as string;
    return commitBridgedCandidate({
      operation_id: request.operation_id,
      candidate_json: candidateJSON,
    });
  });

  await act(async () => {
    root
      .findByProps({ accessibilityLabel: 'Git HTTPS proxy URL' })
      .props.onChangeText('http://127.0.0.1:1082');
  });
  await act(async () => {
    actionByLabel(root, 'Save Git proxy').props.onPress();
    await settle();
  });
  await act(async () => {
    actionByLabel(root, 'Save Git proxy').props.onPress();
    await settle();
  });

  expect(mockSessionSnapshots.casPersistSession).toHaveBeenCalledTimes(1);
  expect(mockSessionSnapshots.querySessionCommit).toHaveBeenCalledTimes(1);
  expect(
    mockSessionSnapshots.querySessionCommit.mock.calls[0]?.[0].operation_id,
  ).toBe(
    mockSessionSnapshots.casPersistSession.mock.calls[0]?.[0].operation_id,
  );
});

test('maps rejected CAS queried not_started to not_committed and clears the pending operation', async () => {
  const renderer = await renderApp();
  const root = renderer.root;
  await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
  await act(async () => actionByLabel(root, 'Settings').props.onPress());

  mockSessionSnapshots.casPersistSession.mockClear();
  mockSessionSnapshots.querySessionCommit.mockClear();
  mockSessionSnapshots.casPersistSession
    .mockRejectedValueOnce(new Error('native CAS rejected'))
    .mockResolvedValueOnce(notCommittedResult());
  mockSessionSnapshots.querySessionCommit.mockResolvedValueOnce({
    schema_version: 1,
    status: 'not_started',
  });

  await act(async () => {
    root
      .findByProps({ accessibilityLabel: 'Git HTTPS proxy URL' })
      .props.onChangeText('http://127.0.0.1:1082');
  });
  await act(async () => {
    actionByLabel(root, 'Save Git proxy').props.onPress();
    await settle();
  });
  await waitForRenderedText(renderer, 'Could not save locally: not_committed');

  expect(mockSessionSnapshots.casPersistSession).toHaveBeenCalledTimes(1);
  expect(mockSessionSnapshots.querySessionCommit).toHaveBeenCalledTimes(1);
  const firstOperationId =
    mockSessionSnapshots.casPersistSession.mock.calls[0]?.[0].operation_id;

  await act(async () => {
    actionByLabel(root, 'Save Git proxy').props.onPress();
    await settle();
  });

  expect(mockSessionSnapshots.casPersistSession).toHaveBeenCalledTimes(2);
  expect(mockSessionSnapshots.querySessionCommit).toHaveBeenCalledTimes(1);
  expect(
    mockSessionSnapshots.casPersistSession.mock.calls[1]?.[0].operation_id,
  ).not.toBe(firstOperationId);
  expect(mockLocalRuntime.completeV2).not.toHaveBeenCalled();
});

function legacyV2SessionJSON(): string {
  const stored = createChatStore({
    now: () => '2026-08-30T00:00:00.000Z',
    createId: kind => `${kind}-legacy`,
    createLifecycleId: () => '11111111-1111-4111-8111-111111111111',
  });
  const conversationId = stored.createConversation();
  stored.appendUserMessage(conversationId, 'legacy message');
  const legacy = JSON.parse(stored.serialize()) as Record<string, unknown>;
  legacy.schema_version = 8;
  delete legacy.agent_transcript_cleanup_outbox;
  delete legacy.session_events;
  legacy.conversations = (
    legacy.conversations as Array<Record<string, unknown>>
  ).map(conversation => {
    const copy = { ...conversation };
    delete copy.agent_grants;
    return copy;
  });
  return JSON.stringify(legacy);
}

function schema9AgentExecutionIntentJSON(): string {
  const seed = createChatStore({ now: () => '2026-08-30T00:00:00.000Z' });
  const conversationId = seed.createConversation();
  const seedState = seed.getState();
  const seedConversation = seedState.conversations[conversationId]!;
  const workspaceId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  const boundState = {
    ...seedState,
    conversations: {
      [conversationId]: {
        ...seedConversation,
        workspaceId,
        workspaceBinding: {
          schemaVersion: 1 as const,
          workspaceId,
          bindingRevision: 1,
          projectId: null,
        },
        workspaceBootstrapState: 'none' as const,
      },
    },
  };
  const authoritySeed = createChatStore({ initialState: boundState });
  const authorityDigest = sessionSnapshotSHA256(authoritySeed.serialize());
  if (authorityDigest === null) throw new Error('invalid Agent seed');
  const stored = createChatStore({
    initialState: boundState,
    sessionAuthority: { generation: 1, sessionSha256: authorityDigest },
    now: () => '2026-08-30T00:00:00.000Z',
  });
  const prepared = stored.prepareTurnAttempt(
    conversationId,
    'agent restart pending',
  );
  if (prepared === null || !prepared.commit()) {
    throw new Error('could not prepare Agent fixture');
  }
  const persisted = JSON.parse(stored.serialize()) as Record<string, unknown>;
  const conversations = persisted.conversations as Array<Record<string, unknown>>;
  const conversation = conversations[0]!;
  const attempts = conversation.attempts as Array<Record<string, unknown>>;
  const attempt = attempts[0]!;
  const attemptId = attempt.attempt_id as string;
  const roundId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
  const callId = 'agent-list-dir';
  const argumentsSha256 = 'c'.repeat(64);
  attempt.journal_revision = 1;
  attempt.agent = {
    schema_version: 2,
    phase: 'execution_intent',
    controller_generation: 1,
    policy: {
      schema_version: 1,
      policy_version: 'agent-v1',
      max_single_write_bytes: 32768,
      max_batch_write_bytes: 512 * 1024,
      max_attempt_write_bytes: 4 * 1024 * 1024,
    },
    root: {
      schema_version: 1,
      kind: 'workspace',
      workspace_id: workspaceId,
      workspace_binding_revision: 1,
      project_id: null,
      root_fingerprint_sha256: 'd'.repeat(64),
      capabilities: ['file_read'],
    },
    tool_registry_version: 1,
    toolset_sha256: 'e'.repeat(64),
    transcript: {
      schema_version: 1,
      transcript_ref: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
      generation: 0,
      transcript_sha256: 'f'.repeat(64),
      transcript_bytes: 0,
    },
    round_index: 0,
    round_lineage: {
      schema_version: 2,
      round_id: roundId,
      round_index: 0,
      launch_attempt: 1,
      status: 'completed',
      native_row_revision: 2,
    },
    call_index: 0,
    batch: [
      {
        schema_version: 2,
        call_id: callId,
        call_index: 0,
        name: 'list_dir',
        arguments_sha256: argumentsSha256,
        safe_summary_key: 'agent.list_dir',
        access: 'auto',
        approval_token: null,
        approval_decision: 'allow_once',
        approval_reference: null,
        idempotency_key: '1'.repeat(64),
        native_row_revision: 1,
        receipt: null,
      },
    ],
    frozen_grant_ids: [],
    reserved_write_bytes: 0,
    updated_at: '2026-08-30T00:00:00.000Z',
  };
  persisted.session_events = [
    {
      schema_version: 2,
      event_id: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
      attempt_id: attemptId,
      seq: 0,
      kind: 'tool_call',
      round_index: 0,
      call_id: callId,
      status: 'running',
      safe_summary_key: 'agent.list_dir',
      arguments_sha256: argumentsSha256,
      result_sha256: null,
      approval_reference: null,
      failure_code: null,
      created_at: '2026-08-30T00:00:00.000Z',
    },
  ];
  return JSON.stringify(persisted);
}

function schema9AgentPendingSessionJSON(
  phase: 'execution_intent' | 'tool_result_pending' | 'final_response',
): string {
  const persisted = JSON.parse(
    schema9AgentExecutionIntentJSON(),
  ) as Record<string, unknown>;
  const conversation = (
    persisted.conversations as Array<Record<string, unknown>>
  )[0]!;
  const attempt = (conversation.attempts as Array<Record<string, unknown>>)[0]!;
  const agent = attempt.agent as Record<string, unknown>;
  if (phase === 'execution_intent') return JSON.stringify(persisted);
  if (phase === 'final_response') {
    agent.phase = 'final_response';
    agent.call_index = null;
    agent.batch = [];
    persisted.session_events = [
      {
        schema_version: 2,
        event_id: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
        attempt_id: attempt.attempt_id,
        seq: 0,
        kind: 'terminal',
        round_index: null,
        call_id: null,
        status: 'ok',
        safe_summary_key: null,
        arguments_sha256: null,
        result_sha256: null,
        approval_reference: null,
        failure_code: null,
        created_at: '2026-08-30T00:00:00.000Z',
      },
    ];
    return JSON.stringify(persisted);
  }

  agent.phase = 'tool_result_pending';
  agent.transcript = {
    ...(agent.transcript as Record<string, unknown>),
    generation: 1,
    transcript_sha256: '0'.repeat(64),
  };
  const call = (agent.batch as Array<Record<string, unknown>>)[0]!;
  call.native_row_revision = 2;
  call.receipt = {
    schema_version: 1,
    call_id: call.call_id,
    name: call.name,
    arguments_sha256: call.arguments_sha256,
    result_sha256: '1'.repeat(64),
    result_bytes: 0,
    truncated: false,
    duration_ms: 1,
    outcome: 'ok',
    failure_code: null,
    approval_reference: null,
  };
  persisted.session_events = [
    {
      schema_version: 2,
      event_id: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeef',
      attempt_id: attempt.attempt_id,
      seq: 0,
      kind: 'tool_result',
      round_index: 0,
      call_id: call.call_id,
      status: 'ok',
      safe_summary_key: call.safe_summary_key,
      arguments_sha256: call.arguments_sha256,
      result_sha256: '1'.repeat(64),
      approval_reference: null,
      failure_code: null,
      created_at: '2026-08-30T00:00:00.000Z',
    },
  ];
  return JSON.stringify(persisted);
}

function schema9LegacyApprovalSessionJSON(
  mismatch: 'conversation' | 'session' | 'journal' | 'root',
): string {
  const persisted = JSON.parse(
    schema9AgentExecutionIntentJSON(),
  ) as Record<string, unknown>;
  const conversation = (
    persisted.conversations as Array<Record<string, unknown>>
  )[0]!;
  const attempt = (conversation.attempts as Array<Record<string, unknown>>)[0]!;
  const agent = attempt.agent as Record<string, unknown>;
  const root = agent.root as Record<string, unknown>;
  const lineage = agent.round_lineage as Record<string, unknown>;
  const callId = 'legacy-write-file';
  const argumentsSha256 = '2'.repeat(64);
  root.capabilities = ['file_read', 'file_write'];
  agent.phase = 'approval_pending';
  agent.call_index = 0;
  const token = {
    schema_version: 1,
    controller_cas: {
      schema_version: 1,
      conversation_id: conversation.id,
      task_id: attempt.turn_id,
      attempt_id: attempt.attempt_id,
      expected_controller_generation: 0,
      expected_journal_revision: 0,
      expected_session_generation: 7,
      expected_session_sha256: '3'.repeat(64),
    },
    round_id: lineage.round_id,
    round_index: 0,
    batch_call_ids: [callId],
    batch_arguments_sha256: [argumentsSha256],
    call_index: 0,
    call_id: callId,
    name: 'write_file',
    access: 'conversation_confirm',
    arguments_sha256: argumentsSha256,
    root_fingerprint_sha256: root.root_fingerprint_sha256,
    binding_revision: root.workspace_binding_revision,
    policy_version: (agent.policy as Record<string, unknown>).policy_version,
    registry_version: 1,
    allowed_decisions: [
      'denied',
      'allow_once',
      'allow_conversation',
      'cancelled',
    ],
  };
  if (mismatch === 'conversation') {
    token.controller_cas.conversation_id = 'wrong-conversation';
  } else if (mismatch === 'session') {
    token.controller_cas.expected_session_sha256 = '4'.repeat(64);
  } else if (mismatch === 'journal') {
    token.controller_cas.expected_journal_revision = 4;
  } else {
    token.root_fingerprint_sha256 = '5'.repeat(64);
  }
  agent.batch = [
    {
      schema_version: 2,
      call_id: callId,
      call_index: 0,
      name: 'write_file',
      arguments_sha256: argumentsSha256,
      safe_summary_key: 'agent.write_file',
      access: 'conversation_confirm',
      approval_token: token,
      approval_decision: 'allow_once',
      approval_reference: null,
      idempotency_key: null,
      native_row_revision: null,
      receipt: null,
    },
  ];
  persisted.session_events = [
    {
      schema_version: 2,
      event_id: 'f1111111-1111-4111-8111-111111111111',
      attempt_id: attempt.attempt_id,
      seq: 0,
      kind: 'tool_call',
      round_index: 0,
      call_id: callId,
      status: 'approval',
      safe_summary_key: 'agent.write_file',
      arguments_sha256: argumentsSha256,
      result_sha256: null,
      approval_reference: null,
      failure_code: null,
      created_at: '2026-08-30T00:00:00.000Z',
    },
  ];
  const sessionJSON = JSON.stringify(persisted);
  if (mismatch !== 'root' && !safeHydrateChatState(sessionJSON).ok) {
    throw new Error('legacy approval fixture must expose the missing-authority bug');
  }
  return sessionJSON;
}

function schema9MixedAgentSession(): {
  sessionJSON: string;
  currentAttemptId: string;
} {
  const persisted = JSON.parse(schema9AgentExecutionIntentJSON()) as Record<
    string,
    unknown
  >;
  const persistedConversation = (
    persisted.conversations as Array<Record<string, unknown>>
  )[0]!;
  const historical = (
    persistedConversation.attempts as Array<Record<string, unknown>>
  )[0]!;
  historical.status = 'cancelled';
  historical.failure_code = null;
  const historicalAgent = historical.agent as Record<string, unknown>;
  historicalAgent.phase = 'cancelled';
  historicalAgent.round_lineage = {
    ...(historicalAgent.round_lineage as Record<string, unknown>),
    status: 'completed',
  };
  historicalAgent.call_index = null;
  historicalAgent.batch = [];
  persisted.session_events = [];
  const hydrated = safeHydrateChatState(JSON.stringify(persisted));
  if (!hydrated.ok) throw new Error('could not hydrate mixed Agent fixture');
  const mixed = createChatStore({
    initialState: hydrated.state,
    now: () => '2026-08-30T00:00:01.000Z',
  });
  const conversationId = mixed.getState().selectedConversationId;
  if (conversationId === null) throw new Error('mixed Agent chat not selected');
  const current = mixed.prepareTurnAttempt(conversationId, 'current non-agent');
  if (current === null || !current.commit()) {
    throw new Error('could not prepare mixed Agent attempt');
  }
  return { sessionJSON: mixed.serialize(), currentAttemptId: current.attemptId };
}

function legacyLoadResult(sessionJSON: string) {
  return {
    schema_version: 1 as const,
    status: 'legacy_present' as const,
    legacy: {
      schema_version: 1 as const,
      legacy_bytes_sha256: 'a'.repeat(64),
    },
    session_json: sessionJSON,
    writer_launch_instance_id: APP_LAUNCH_INSTANCE_ID,
    current_launch_instance_id: APP_LAUNCH_INSTANCE_ID,
  };
}

function presentLoadResult(sessionJSON: string, generation = 1) {
  const digest = sessionSnapshotSHA256(sessionJSON);
  if (digest === null) throw new Error('fixture is not a V9 session');
  return {
    schema_version: 1 as const,
    status: 'present' as const,
    snapshot: {
      schema_version: 1 as const,
      generation,
      session_sha256: digest,
    },
    session_json: sessionJSON,
    writer_launch_instance_id: APP_LAUNCH_INSTANCE_ID,
    current_launch_instance_id: APP_LAUNCH_INSTANCE_ID,
  };
}

function installAgentRuntimeFlow(options: { inFlight?: boolean } = {}) {
  const root: AgentRuntimeRootV1 = {
    schema_version: 1,
    kind: 'project',
    workspace_id: CONTEXT_RUNTIME_ID,
    workspace_binding_revision: 1,
    project_id: CONTEXT_PROJECT_ID,
    root_fingerprint_sha256: '6'.repeat(64),
    capabilities: ['file_read', 'file_write', 'git_commit'],
  };
  const policy: AgentRuntimePolicyV1 = {
    schema_version: 1,
    policy_version: 'agent-v1',
    max_single_write_bytes: 32768,
    max_batch_write_bytes: 512 * 1024,
    max_attempt_write_bytes: 4 * 1024 * 1024,
  };
  const transcript = (
    generation: number,
    digest: string,
  ): AgentRuntimeTranscriptHandleV1 => ({
    schema_version: 1,
    transcript_ref: 'abababab-abab-4bab-8bab-abababababab',
    generation,
    transcript_sha256: digest,
    transcript_bytes: generation * 10,
  });
  mockAgentRuntime.isAvailable.mockReturnValue(true);
  mockAgentRuntime.prepareAgentAttempt.mockImplementation(
    async (request: PrepareAgentAttemptRequestV2) => ({
      schema_version: 2,
      status: 'prepared',
      operation_id: request.operation_id,
      attempt: {
        schema_version: 2,
        task_id: request.task_id,
        conversation_id: request.conversation_id,
        attempt_id: request.attempt_id,
        phase: 'ready_for_round',
        controller_generation:
          request.controller_cas.expected_controller_generation,
        journal_revision: request.controller_cas.expected_journal_revision,
        authority_revision: 1,
        root,
        policy,
        registry: {
          schema_version: 2,
          registry_version: 1,
          toolset_sha256: '7'.repeat(64),
          tools: [
            {
              schema_version: 2,
              name: 'write_file',
              safe_summary_key: 'agent.write_file',
              access: 'conversation_confirm',
            },
            {
              schema_version: 2,
              name: 'git_commit',
              safe_summary_key: 'agent.git_commit',
              access: 'conversation_confirm',
            },
          ],
        },
        transcript: transcript(0, '8'.repeat(64)),
        round_index: 0,
        round_id: null,
        round_revision: null,
        round_status: null,
        batch_kind: null,
        batch_revision: null,
        manifest_sha256: null,
        call_index: null,
        batch: [],
        frozen_grant_ids: [],
        reserved_write_bytes: 0,
        cancel_source_event_id: null,
        cleanup_id: null,
      } satisfies AgentAttemptProjectionV2,
      observed_checkpoint: request.committed_checkpoint,
    }),
  );
  mockAgentRuntime.completeAgentRoundV2.mockImplementation(
    async (request: CompleteAgentRoundRequestV2) => {
      if (options.inFlight) {
        return {
          schema_version: 2,
          status: 'in_flight',
          operation_id: request.operation_id,
          task_id: request.task_id,
          attempt_id: request.attempt_id,
          round_id: request.round_id,
          round_index: request.round_index,
          launch_attempt: request.launch_attempt,
          result_round_revision: 1,
          transcript: request.transcript,
        };
      }
      const final = request.round_index === 1;
      const nextTranscript = transcript(
        final ? 4 : 1,
        final ? '9'.repeat(64) : '1'.repeat(64),
      );
      const completionReceipt: AgentRoundReceiptV2 = {
        schema_version: 2,
        transport_schema_version: request.transport_schema_version,
        turn_id: request.task_id,
        task_id: request.task_id,
        attempt_id: request.attempt_id,
        round_id: request.round_id,
        round_index: request.round_index,
        provider_request_id: `provider-${request.round_index}`,
        provider_response_id: `response-${request.round_index}`,
        requested_model: request.model,
        model: request.model,
        thinking_mode: request.thinking_mode,
        finish_reason: final ? 'stop' : 'tool_calls',
        latency_ms: 1,
        visible_history_sha256: request.visible_history_sha256,
        model_input_sha256: 'a'.repeat(64),
        request_body_sha256: 'b'.repeat(64),
        project_context_receipt: {
          schema_version: 1,
          snapshot_id: CONTEXT_SNAPSHOT_ID,
          snapshot_sha256: request.project_context_sha256!,
          source_fingerprint: 'e'.repeat(64),
          context_bytes: 16,
          verified_at: '2026-08-30T00:00:02.000Z',
        },
      };
      if (final) {
        return {
          schema_version: 2,
          status: 'completed',
          operation_id: request.operation_id,
          task_id: request.task_id,
          attempt_id: request.attempt_id,
          round_id: request.round_id,
          round_index: request.round_index,
          launch_attempt: request.launch_attempt,
          result_round_revision: 1,
          transcript: nextTranscript,
          outcome: {
            schema_version: 3,
            kind: 'final',
            finish_reason: 'stop',
            completion_receipt: completionReceipt,
            transcript: nextTranscript,
            text: 'Agent final',
            reasoning: 'Agent reasoning',
          },
        };
      }
      return {
        schema_version: 2,
        status: 'completed',
        operation_id: request.operation_id,
        task_id: request.task_id,
        attempt_id: request.attempt_id,
        round_id: request.round_id,
        round_index: request.round_index,
        launch_attempt: request.launch_attempt,
        result_round_revision: 1,
        transcript: nextTranscript,
        outcome: {
          schema_version: 3,
          kind: 'tool_batch',
          finish_reason: 'tool_calls',
          completion_receipt: completionReceipt,
          transcript: nextTranscript,
          calls: [
            {
              schema_version: 3,
              call_index: 0,
              call_id: 'write-call',
              name: 'write_file',
              arguments_sha256: '2'.repeat(64),
              safe_summary_key: 'agent.write_file',
              access: 'conversation_confirm',
              approval_state: 'deferred',
            },
            {
              schema_version: 3,
              call_index: 1,
              call_id: 'commit-call',
              name: 'git_commit',
              arguments_sha256: '3'.repeat(64),
              safe_summary_key: 'agent.git_commit',
              access: 'conversation_confirm',
              approval_state: 'deferred',
            },
          ],
          batch_class: 'executable',
          executable_call_count: 2,
          denied_call_count: 0,
          reasoning: '',
        },
      };
    },
  );
  mockAgentRuntime.prepareAgentToolBatch.mockImplementation(
    async (request: PrepareAgentToolBatchRequestV2) => {
      const batchRevision = request.expected_batch_revision + 1;
      const makeToken = (
        index: number,
        callId: string,
        name: string,
        argumentsSha256: string,
      ): AgentApprovalBindingTokenV2 => ({
        schema_version: 2,
        token:
          index === 0
            ? '93939393-9393-4939-8939-939393939393'
            : '94949494-9494-4949-8949-949494949494',
        controller_cas: request.controller_cas,
        task_id: request.task_id,
        attempt_id: request.attempt_id,
        round_id: request.round_id,
        round_index: request.round_index,
        batch_call_ids: ['write-call', 'commit-call'],
        batch_arguments_sha256: ['2'.repeat(64), '3'.repeat(64)],
        batch_revision: batchRevision,
        manifest_sha256: 'c'.repeat(64),
        call_index: index,
        call_id: callId,
        name,
        arguments_sha256: argumentsSha256,
        idempotency_key: `${index + 4}`.repeat(64),
        root_fingerprint_sha256: root.root_fingerprint_sha256,
        binding_revision: 1,
        policy_version: 'agent-v1',
        registry_version: 1,
        access: 'conversation_confirm',
        allowed_decisions: [
          'denied',
          'allow_once',
          'allow_conversation',
          'cancelled',
        ],
      });
      const calls: AgentBatchCallProjectionV2[] = [
        {
          schema_version: 2,
          call_index: 0,
          call_id: 'write-call',
          name: 'write_file',
          arguments_sha256: '2'.repeat(64),
          idempotency_key: '4'.repeat(64),
          safe_summary_key: 'agent.write_file',
          approval_preview: {
            schema_version: 1,
            kind: 'write_file',
            paths: ['notes.md'],
            content_bytes: 5,
            prior: { schema_version: 1, kind: 'absent', bytes: null },
            diff_preview: '@@ -1,0 +1,1 @@\n+hello',
            diff_truncated: false,
          },
          access: 'conversation_confirm',
          approval_state: 'pending',
          approval_token: makeToken(0, 'write-call', 'write_file', '2'.repeat(64)),
          approval_reference: null,
          execution_status: 'intent',
          execution_revision: 1,
          native_row_revision: 1,
          receipt: null,
        },
        {
          schema_version: 2,
          call_index: 1,
          call_id: 'commit-call',
          name: 'git_commit',
          arguments_sha256: '3'.repeat(64),
          idempotency_key: '5'.repeat(64),
          safe_summary_key: 'agent.git_commit',
          approval_preview: {
            schema_version: 1,
            kind: 'git_commit',
            paths: [],
            content_bytes: null,
            prior: null,
            diff_preview: null,
            diff_truncated: false,
          },
          access: 'conversation_confirm',
          approval_state: 'pending',
          approval_token: makeToken(1, 'commit-call', 'git_commit', '3'.repeat(64)),
          approval_reference: null,
          execution_status: 'intent',
          execution_revision: 1,
          native_row_revision: 1,
          receipt: null,
        },
      ];
      const receipt: AgentBatchReceiptV2 = {
        schema_version: 2,
        task_id: request.task_id,
        attempt_id: request.attempt_id,
        round_id: request.round_id,
        round_index: request.round_index,
        batch_kind: 'write_batch',
        batch_revision: batchRevision,
        manifest_sha256: 'c'.repeat(64),
        transcript: request.transcript,
        calls,
        batch_new_write_bytes: 1,
        reserved_write_bytes: request.expected_reserved_write_bytes + 1,
        effect_gate: 'closed',
      };
      return {
        schema_version: 2,
        status: 'prepared',
        operation_id: request.operation_id,
        receipt,
        observed_checkpoint: request.committed_checkpoint,
      };
    },
  );
  mockAgentRuntime.bindAgentApproval.mockImplementation(
    async (request: BindAgentApprovalRequestV2) => ({
      schema_version: 2,
      status: 'bound',
      operation_id: request.operation_id,
      task_id: request.task_id,
      attempt_id: request.attempt_id,
      round_id: request.round_id,
      call_index: request.call_index,
      call_id: request.call_id,
      decision: request.decision,
      approval_reference: request.operation_id,
      grant: null,
      result_batch_revision: request.batch_revision,
      observed_checkpoint: request.committed_checkpoint,
    }),
  );
  mockAgentRuntime.executeAgentTool.mockImplementation(
    async (request: ExecuteAgentToolRequestV2) => {
      const receipt: AgentToolReceiptV1 = {
        schema_version: 1,
        call_id: request.call_id,
        name: request.name,
        arguments_sha256: request.arguments_sha256,
        result_sha256: `${request.call_index + 6}`.repeat(64),
        result_bytes: 1,
        truncated: false,
        duration_ms: 1,
        outcome: 'ok',
        failure_code: null,
        approval_reference: request.approval_reference,
      };
      return {
        schema_version: 2,
        status: 'completed',
        operation_id: request.operation_id,
        task_id: request.task_id,
        attempt_id: request.attempt_id,
        round_id: request.round_id,
        round_index: request.round_index,
        call_index: request.call_index,
        call_id: request.call_id,
        name: request.name,
        idempotency_key: request.idempotency_key,
        result_execution_revision: 2,
        transcript: transcript(
          request.call_index + 2,
          `${request.call_index + 2}`.repeat(64),
        ),
        receipt,
        effect_may_have_occurred: true,
      };
    },
  );
  mockAgentRuntime.finalizeAgentAttempt.mockImplementation(async request => ({
    schema_version: 2,
    status: 'terminal',
    operation_id: request.operation_id,
    cleanup_id: request.cleanup_id,
    transcript: request.transcript,
  }));
  mockAgentRuntime.discardAgentAttempt.mockImplementation(async request => ({
    schema_version: 2,
    status: 'discarded',
    operation_id: request.operation_id,
    cleanup_id: request.cleanup_id,
  }));
}

async function waitForAgentApproval(
  renderer: Renderer,
  toolName: string,
): Promise<ReactTestInstance> {
  for (let index = 0; index < 100; index += 1) {
    const composer = renderer.root
      .findAllByType(ApprovalComposer)
      .find(candidate =>
        candidate.props.requests.some(
          (request: { toolName: string }) => request.toolName === toolName,
        ),
      );
    if (composer !== undefined) return composer;
    await act(async () => settle());
  }
  throw new Error(
    `missing Agent approval for ${toolName}`,
  );
}

async function waitForRenderedText(
  renderer: Renderer,
  text: string,
): Promise<void> {
  // A batch approval commits every decision as its own persisted checkpoint
  // before execution, so the Agent path needs more settle hops than the
  // single-card flow did.
  for (let index = 0; index < 400; index += 1) {
    if (renderer.root.findAllByProps({ children: text }).length > 0) return;
    await act(async () => {
      await settle();
      await new Promise<void>(resolve => setTimeout(() => resolve(), 0));
    });
  }
  // Report where the Agent flow actually stopped, not just that the text is
  // missing: the native call counts and the last persisted attempt tell
  // apart a stalled flow, a wrong terminal, and a restart that hydrated an
  // older candidate.
  const counts = {
    prepare: mockAgentRuntime.prepareAgentAttempt.mock.calls.length,
    rounds: mockAgentRuntime.completeAgentRoundV2.mock.calls.length,
    batches: mockAgentRuntime.prepareAgentToolBatch.mock.calls.length,
    binds: mockAgentRuntime.bindAgentApproval.mock.calls.length,
    executes: mockAgentRuntime.executeAgentTool.mock.calls.length,
    finalizes: mockAgentRuntime.finalizeAgentAttempt.mock.calls.length,
    discards: mockAgentRuntime.discardAgentAttempt.mock.calls.length,
    persists: mockSessionSnapshots.casPersistSession.mock.calls.length,
  };
  let lastAttempt = 'none';
  try {
    const persisted = JSON.parse(lastPersistedCandidateJSON()) as {
      conversations: Array<{
        attempts: Array<{
          status: string;
          failure_code: string | null;
          agent: null | { phase: string };
        }>;
      }>;
    };
    const attempt = persisted.conversations[0]?.attempts.at(-1);
    lastAttempt = attempt === undefined
      ? 'no attempt'
      : `${attempt.status}/${attempt.failure_code ?? 'null'}/${attempt.agent?.phase ?? 'no journal'}`;
  } catch {
    lastAttempt = 'unreadable';
  }
  const composers = renderer.root.findAllByType(ApprovalComposer).length;
  const banners = renderer.root
    .findAllByType(Text)
    .map(node => node.props.children)
    .filter((child): child is string => typeof child === 'string' && child.startsWith('E_'));
  throw new Error(
    `missing rendered text ${text}; calls=${JSON.stringify(counts)}; lastAttempt=${lastAttempt}; approvalComposers=${composers}; banners=${JSON.stringify(banners)}`,
  );
}

test('runs a project Agent task through two safe approvals and restores it without replay', async () => {
  const fixture = storedAgentProject();
  queuePresentSession(fixture.stored.serialize(), 7);
  mockAgentWorkspaceAuthority();
  mockConfirmedAgentProjectInspection(fixture.manifest);
  installAgentRuntimeFlow();

  const renderer = await renderAppOpeningStoredConversation();
  expect(
    renderer.root.findAllByType(ProjectContextStrip).map(strip => ({
      status: strip.props.state.status,
      verificationStatus: strip.props.verificationStatus,
    })),
  ).toEqual([{ status: 'ready', verificationStatus: 'verified' }]);
  await waitForRenderedText(renderer, 'Ready');
  expect(renderer.root.findByType(ChatComposer).props.locked).toBe(false);
  await act(async () => {
    renderer.root
      .findByProps({ accessibilityLabel: 'Message DSH' })
      .props.onChangeText('write and commit');
  });
  await act(async () => {
    const sendAction = actionByLabel(renderer.root, 'Send message');
    expect(sendAction.props.disabled).toBe(false);
    sendAction.props.onPress();
    await settle();
  });
  for (let index = 0; index < 20; index += 1) {
    await act(async () => settle());
    if (mockAgentRuntime.prepareAgentAttempt.mock.calls.length > 0) break;
  }
  expect(mockAgentRuntime.isAvailable).toHaveBeenCalled();
  expect(mockLocalRuntime.completeV2).not.toHaveBeenCalled();
  expect(mockAgentRuntime.prepareAgentAttempt).toHaveBeenCalledTimes(1);

  // Both gated calls of the batch are presented as one list with per-item
  // decisions and a single commit.
  const batchApproval = await waitForAgentApproval(renderer, 'write_file');
  await openHarnessPicker(renderer.root);
  expect(actionByLabel(renderer.root, 'Use GLM').props.disabled).toBe(true);
  await act(async () => renderer.root.findByType(HarnessPicker).props.onSelect('glm'));
  expect(renderer.root.findByType(ChatComposer).props.model).toBe('deepseek-v4-flash');
  expect(mockAgentRuntime.cancelAgentAttempt).not.toHaveBeenCalled();
  await act(async () => renderer.root.findByType(HarnessPicker).props.onClose());
  const presented = batchApproval.props.requests as Array<{
    toolName: string;
    argumentsJson: string;
    preview: { kind: string; paths: string[] } | null;
  }>;
  expect(presented.map(request => request.toolName)).toEqual([
    'write_file',
    'git_commit',
  ]);
  expect(JSON.parse(presented[0]!.argumentsJson)).toEqual({
    arguments_sha256: '2'.repeat(64),
  });
  expect(presented[0]!.argumentsJson).not.toContain('path');
  expect(presented[0]!.preview).toMatchObject({
    kind: 'write_file',
    paths: ['notes.md'],
  });
  expect(JSON.parse(presented[1]!.argumentsJson)).toEqual({
    arguments_sha256: '3'.repeat(64),
  });
  expect(presented[1]!.preview).toMatchObject({ kind: 'git_commit' });
  await act(async () => {
    renderer.root.findByProps({ testID: 'approval-item-0-once' }).props.onPress();
  });
  await act(async () => {
    renderer.root.findByProps({ testID: 'approval-item-1-once' }).props.onPress();
  });
  await act(async () => {
    renderer.root.findByProps({ testID: 'approval-batch-commit' }).props.onPress();
    await settle();
  });
  await waitForRenderedText(renderer, 'Agent final');

  expect(mockAgentRuntime.prepareAgentAttempt).toHaveBeenCalledTimes(1);
  expect(mockAgentRuntime.completeAgentRoundV2).toHaveBeenCalledTimes(2);
  expect(mockAgentRuntime.prepareAgentToolBatch).toHaveBeenCalledTimes(1);
  expect(mockAgentRuntime.bindAgentApproval).toHaveBeenCalledTimes(2);
  expect(mockAgentRuntime.executeAgentTool).toHaveBeenCalledTimes(2);
  expect(mockAgentRuntime.finalizeAgentAttempt).toHaveBeenCalledTimes(1);
  expect(mockAgentRuntime.discardAgentAttempt).toHaveBeenCalledTimes(1);
  expect(mockRunAgentTurn).not.toHaveBeenCalled();
  expect(mockLocalRuntime.completeV2).not.toHaveBeenCalled();
  const persisted = JSON.parse(lastPersistedCandidateJSON()) as {
    conversations: Array<{
      attempts: Array<{
        status: string;
        agent: null | { phase: string; batch: unknown[] };
      }>;
    }>;
    session_events: Array<{ kind: string; status: string }>;
  };
  expect(persisted.conversations[0]?.attempts[0]).toMatchObject({
    status: 'completed',
    agent: { phase: 'final_response' },
  });
  expect(
    persisted.session_events.map(event => `${event.kind}:${event.status}`),
  ).toEqual(
    expect.arrayContaining(['tool_result:ok', 'terminal:ok']),
  );

  const callsBeforeRestart = {
    prepare: mockAgentRuntime.prepareAgentAttempt.mock.calls.length,
    rounds: mockAgentRuntime.completeAgentRoundV2.mock.calls.length,
    batches: mockAgentRuntime.prepareAgentToolBatch.mock.calls.length,
    effects: mockAgentRuntime.executeAgentTool.mock.calls.length,
  };
  queuePresentSession(lastPersistedCandidateJSON(), bridgedGeneration);
  await act(async () => renderer.unmount());
  const restarted = await renderAppOpeningStoredConversation();
  await waitForRenderedText(restarted, 'Agent final');
  expect(mockAgentRuntime.prepareAgentAttempt).toHaveBeenCalledTimes(
    callsBeforeRestart.prepare,
  );
  expect(mockAgentRuntime.completeAgentRoundV2).toHaveBeenCalledTimes(
    callsBeforeRestart.rounds,
  );
  expect(mockAgentRuntime.prepareAgentToolBatch).toHaveBeenCalledTimes(
    callsBeforeRestart.batches,
  );
  expect(mockAgentRuntime.executeAgentTool).toHaveBeenCalledTimes(
    callsBeforeRestart.effects,
  );
});

test('executes zero Agent native calls when outer project-task persistence fails', async () => {
  const fixture = storedAgentProject();
  queuePresentSession(fixture.stored.serialize(), 7);
  mockAgentWorkspaceAuthority();
  mockConfirmedAgentProjectInspection(fixture.manifest);
  installAgentRuntimeFlow();
  const renderer = await renderAppOpeningStoredConversation();
  await waitForRenderedText(renderer, 'Ready');
  mockSessionSnapshots.casPersistSession.mockResolvedValueOnce(
    notCommittedResult(),
  );

  await act(async () => {
    renderer.root
      .findByProps({ accessibilityLabel: 'Message DSH' })
      .props.onChangeText('must not execute');
  });
  await act(async () => {
    actionByLabel(renderer.root, 'Send message').props.onPress();
    await settle();
  });
  for (let index = 0; index < 20; index += 1) {
    await act(async () => settle());
  }

  expect(mockAgentRuntime.prepareAgentAttempt).not.toHaveBeenCalled();
  expect(mockAgentRuntime.completeAgentRoundV2).not.toHaveBeenCalled();
  expect(mockAgentRuntime.prepareAgentToolBatch).not.toHaveBeenCalled();
  expect(mockAgentRuntime.bindAgentApproval).not.toHaveBeenCalled();
  expect(mockAgentRuntime.executeAgentTool).not.toHaveBeenCalled();
  expect(mockLocalRuntime.completeV2).not.toHaveBeenCalled();
  expect(mockRunAgentTurn).not.toHaveBeenCalled();
  expect(
    renderer.root.findByProps({ accessibilityLabel: 'Message DSH' }).props.value,
  ).toBe('must not execute');
});

test('promotes an exact V2 legacy token to one canonical V3/V9 session', async () => {
  const legacyJSON = legacyV2SessionJSON();
  mockSessionSnapshots.loadSessionSnapshot
    .mockResolvedValueOnce(legacyLoadResult(legacyJSON))
    .mockResolvedValueOnce(legacyLoadResult(legacyJSON));
  mockSessionSnapshots.casPersistSession.mockImplementationOnce(
    async request => commitBridgedCandidate(request),
  );

  const renderer = await renderApp();
  const root = renderer.root;
  expect(root.findAllByType(EmptyChat).length).toBeGreaterThan(0);
  expect(lastPersistedCandidateJSON()).toContain('legacy message');
  expect(mockSessionSnapshots.casPersistSession).toHaveBeenCalledWith(
    expect.objectContaining({
      expected: {
        schema_version: 1,
        kind: 'legacy_present',
        legacy: {
          schema_version: 1,
          legacy_bytes_sha256: 'a'.repeat(64),
        },
      },
      candidate_json: expect.stringContaining('"schema_version":9'),
    }),
  );
  // Additional authority read belongs to the cold-start selection save.
  expect(mockSessionSnapshots.loadSessionSnapshot).toHaveBeenCalledTimes(3);
});

test.each([
  'execution_intent',
  'tool_result_pending',
  'final_response',
] as const)('hydrates a present %s without replaying tools after restart', async phase => {
  const sessionJSON = schema9AgentPendingSessionJSON(phase);
  queuePresentSession(sessionJSON, 7);

  const renderer = await renderAppOpeningStoredConversation();
  expect(
    renderer.root.findAllByProps({ children: 'agent restart pending' }),
  ).not.toHaveLength(0);
  await act(async () => {
    actionByLabel(renderer.root, 'Continue response').props.onPress();
    await settle();
  });
  // Setup completed migration and explicit history selection; Continue must
  // not manufacture a new commit or replay this interrupted native work.
  expect(mockSessionSnapshots.casPersistSession).not.toHaveBeenCalled();
  expect(mockSessionSnapshots.querySessionCommit).not.toHaveBeenCalled();
  expect(mockLocalRuntime.completeV2).not.toHaveBeenCalled();
  expect(mockLocalWorkspace.executePortableTool).not.toHaveBeenCalled();
  expect(mockRunAgentTurn).not.toHaveBeenCalled();
});

test('CAS-migrates a present V2/V9 candidate before installing its new authority', async () => {
  const sessionJSON = schema9AgentExecutionIntentJSON();
  const loaded = presentLoadResult(sessionJSON, 7);
  queuePresentSession(sessionJSON, 7);

  const renderer = await renderApp();
  expect(renderer.root.findAllByType(EmptyChat).length).toBeGreaterThan(0);
  expect(lastPersistedCandidateJSON()).toContain('agent restart pending');
  // Migration CAS first; cold-start selection CAS uses its committed authority.
  expect(mockSessionSnapshots.casPersistSession).toHaveBeenCalledTimes(2);
  const selection = mockSessionSnapshots.casPersistSession.mock.calls[1]?.[0];
  expect(selection.expected.snapshot.generation).toBe(8);
  const request = mockSessionSnapshots.casPersistSession.mock.calls[0]?.[0];
  expect(request.expected).toEqual({
    schema_version: 1,
    kind: 'present',
    snapshot: loaded.snapshot,
  });
  expect(sessionSnapshotSHA256(request.candidate_json)).not.toBe(
    loaded.snapshot.session_sha256,
  );
  const candidate = JSON.parse(request.candidate_json) as {
    conversations: Array<{ attempts: Array<{ agent: { schema_version: number } }> }>;
  };
  expect(candidate.conversations[0]?.attempts[0]?.agent.schema_version).toBe(3);
});

test.each(['conversation', 'session', 'journal', 'root'] as const)(
  'rejects a present legacy approval with the wrong %s authority',
  async mismatch => {
    const sessionJSON = schema9LegacyApprovalSessionJSON(mismatch);
    queuePresentSession(sessionJSON, 7);

    const renderer = await renderApp();
    expect(
      renderer.root.findAllByProps({ children: 'agent restart pending' }),
    ).toHaveLength(0);
    expect(mockSessionSnapshots.casPersistSession).not.toHaveBeenCalled();
    expect(mockLocalRuntime.completeV2).not.toHaveBeenCalled();
  },
);

test.each(['conflict', 'lost'] as const)(
  'does not install the old present authority when migration is %s',
  async outcome => {
    const sessionJSON = schema9AgentExecutionIntentJSON();
    const loaded = presentLoadResult(sessionJSON, 7);
    queuePresentSession(sessionJSON, 7);
    if (outcome === 'conflict') {
      mockSessionSnapshots.casPersistSession.mockResolvedValueOnce({
        schema_version: 1,
        status: 'conflict',
        current: { schema_version: 1, kind: 'present', snapshot: loaded.snapshot },
      });
    } else {
      mockSessionSnapshots.casPersistSession.mockResolvedValueOnce(undefined);
    }

    const renderer = await renderApp();
    expect(
      renderer.root.findAllByProps({ children: 'agent restart pending' }),
    ).toHaveLength(0);
    expect(mockLocalRuntime.completeV2).not.toHaveBeenCalled();
    expect(mockRunAgentTurn).not.toHaveBeenCalled();
  },
);

test('uses the ordinary retry path for a current non-Agent attempt after Agent history', async () => {
  const { sessionJSON, currentAttemptId } = schema9MixedAgentSession();
  queuePresentSession(sessionJSON, 7);

  const renderer = await renderAppOpeningStoredConversation();
  expect(currentAttemptId).toBeDefined();
  expect(actionByLabel(renderer.root, 'Continue response')).toBeDefined();

  await act(async () => {
    actionByLabel(renderer.root, 'Continue response').props.onPress();
    await settle();
    await settle();
  });

  expect(mockLocalRuntime.completeV2).toHaveBeenCalledTimes(1);
  expect(mockRunAgentTurn).not.toHaveBeenCalled();
});

test.each([
  ['boolean native load', true],
  [
    'malformed native load',
    { schema_version: 1, status: 'present', snapshot: null, session_json: '{}' },
  ],
] as const)('does not downgrade or overwrite on %s', async (_label, loaded) => {
  mockSessionSnapshots.loadSessionSnapshot.mockResolvedValueOnce(loaded);

  const renderer = await renderApp();
  expect(renderer.root.findByProps({ accessibilityLabel: 'Message DSH' })).toBeDefined();
  expect(mockSessionSnapshots.casPersistSession).not.toHaveBeenCalled();
  expect(mockSessionSnapshots.querySessionCommit).not.toHaveBeenCalled();
});

test.each(['conflict', 'unknown', 'session_only'] as const)(
  'keeps a legacy session hidden when migration returns %s',
  async status => {
    const legacyJSON = legacyV2SessionJSON();
    mockSessionSnapshots.loadSessionSnapshot.mockResolvedValueOnce(
      legacyLoadResult(legacyJSON),
    );
    mockSessionSnapshots.loadSessionSnapshot.mockResolvedValueOnce(
      legacyLoadResult(legacyJSON),
    );
    mockSessionSnapshots.casPersistSession.mockResolvedValueOnce({
      schema_version: 1,
      status,
      current: { schema_version: 1, kind: 'missing' },
    });

    const renderer = await renderApp();
    expect(renderer.root.findAllByProps({ children: 'legacy message' })).toHaveLength(0);
  },
);

test('edits with revision protection and renders a real portable tool receipt', async () => {
  const file = {
    path: 'note.md',
    name: 'note.md',
    kind: 'file',
    size: 5,
    modified_at: '2026-08-24T00:00:00.000Z',
    revision: 'rev-1',
  };
  mockLocalWorkspace.listV2.mockImplementationOnce(
    async (request: {
      root: { workspace_id: string; binding_revision: number; project_id: string | null };
      path: string;
    }) => ({
      schema_version: 1,
      root: appWorkspaceRoot(request),
      path: request.path,
      entries: [file],
    }),
  );
  mockLocalWorkspace.readV2.mockImplementationOnce(
    async (request: {
      root: { workspace_id: string; binding_revision: number; project_id: string | null };
      path: string;
    }) => ({
      schema_version: 1,
      root: appWorkspaceRoot(request),
      path: request.path,
      file,
      content: 'hello',
    }),
  );
  mockLocalWorkspace.writeV2.mockImplementationOnce(
    async (request: {
      root: { workspace_id: string; binding_revision: number; project_id: string | null };
      path: string;
      content: string;
    }) => ({
      schema_version: 1,
      root: appWorkspaceRoot(request),
      file: { ...file, size: request.content.length, revision: 'rev-2' },
      created: false,
    }),
  );
  mockLocalWorkspace.executePortableToolV2.mockImplementationOnce(
    async (request: {
      root: { workspace_id: string; binding_revision: number; project_id: string | null };
      tool: string;
      path: string;
    }) => ({
      schema_version: 1,
      root: appWorkspaceRoot(request),
      tool: request.tool,
      path: request.path,
      exit_code: 0,
      stdout: 'abc  note.md\n',
      stderr: '',
      protocol_version: 1,
      path_kind: 'portable_applet',
    }),
  );
  const renderer = await renderApp();
  const root = renderer.root;

  await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
  await act(async () => actionByLabel(root, 'Files').props.onPress());
  await act(async () => {
    await settle();
  });
  await act(async () => {
    actionByLabel(root, 'Open note.md').props.onPress();
    await settle();
  });
  await act(async () => {
    root
      .findByProps({ accessibilityLabel: 'File content' })
      .props.onChangeText('hello mobile');
  });
  await act(async () => {
    actionByLabel(root, 'Save changes').props.onPress();
    await settle();
  });
  expect(mockLocalWorkspace.writeV2).toHaveBeenCalledWith(
    expect.objectContaining({
      schema_version: 1,
      path: 'note.md',
      content: 'hello mobile',
      expected_revision: 'rev-1',
      create_only: false,
      root: expect.objectContaining({
        workspace_id: APP_WORKSPACE_ID,
        binding_revision: 1,
        project_id: null,
      }),
    }),
  );

  await act(async () => {
    actionByLabel(root, 'SHA-256').props.onPress();
    await settle();
  });
  expect(mockLocalWorkspace.executePortableToolV2).toHaveBeenCalledWith(
    expect.objectContaining({
      schema_version: 1,
      tool: 'sha256sum',
      path: 'note.md',
      options: {},
      root: expect.objectContaining({
        workspace_id: APP_WORKSPACE_ID,
        binding_revision: 1,
        project_id: null,
      }),
    }),
  );
  expect(root.findByProps({ children: 'abc  note.md\n' })).toBeDefined();
});

test('opens chat actions from the drawer and persists a renamed title', async () => {
  const renderer = await renderApp();
  const root = renderer.root;

  await act(async () => {
    root
      .findByProps({ accessibilityLabel: 'Message DSH' })
      .props.onChangeText('Rename this chat');
  });
  await act(async () => {
    root.findByProps({ accessibilityLabel: 'Send message' }).props.onPress();
    await settle();
  });
  await act(async () => {
    actionByLabel(root, 'Open navigation').props.onPress();
  });
  await act(async () => {
    actionByLabel(root, 'Chat actions for Rename this chat').props.onPress();
  });
  await act(async () => {
    root
      .findByProps({ accessibilityLabel: 'Conversation title' })
      .props.onChangeText('Renamed locally');
  });
  await act(async () => {
    actionByLabel(root, 'Save conversation title').props.onPress();
    await settle();
  });

  expect(lastPersistedState().conversations[0]?.id).toBeDefined();
  const lastSerialized = JSON.parse(
    lastPersistedCandidateJSON(),
  ) as {
    conversations: Array<{ title: string }>;
  };
  expect(lastSerialized.conversations[0]?.title).toBe('Renamed locally');
});

test('keeps the composer recoverable and retries a failed response', async () => {
  mockLocalRuntime.completeV2
    .mockRejectedValueOnce(new Error('network unavailable'))
    .mockImplementationOnce(async (request: StrictCompletionRequest) =>
      strictCompletionResult(request, {
        text: 'Recovered',
        latency_ms: 50,
        reasoning: 'Retrying the local request.',
      }),
    );
  const renderer = await renderApp();
  const root = renderer.root;

  await act(async () => {
    root
      .findByProps({ accessibilityLabel: 'Message DSH' })
      .props.onChangeText('Retry me');
  });
  await act(async () => {
    root.findByProps({ accessibilityLabel: 'Send message' }).props.onPress();
    await settle();
  });
  expect(
    root.findByProps({ accessibilityLabel: 'Message DSH' }).props.editable,
  ).toBe(true);
  expect(
    root.findByProps({ accessibilityLabel: 'Retry response' }),
  ).toBeDefined();

  await act(async () => {
    await root
      .findByProps({ accessibilityLabel: 'Retry response' })
      .props.onPress();
  });
  expect(mockLocalRuntime.completeV2).toHaveBeenCalledTimes(2);
  expect(
    mockSessionSnapshots.casPersistSession.mock.calls.map(call => {
      const state = JSON.parse(call[0]?.candidate_json as string) as {
        conversations: Array<{ attempts?: Array<{ status: string }> }>;
      };
      return state.conversations[0]?.attempts?.at(-1)?.status ?? 'none';
    }),
  ).toEqual([
    'prepared',
    'sending',
    'failed',
    'prepared',
    'sending',
    'completed',
  ]);
  const persisted = lastPersistedState();
  expect(persisted.conversations[0]?.attempts?.at(-1)).toMatchObject({
    status: 'completed',
    assistant_message_id: expect.any(String),
  });
  expect(persisted.messages.at(-1)?.text).toBe('Recovered');
});

test('coalesces rapid Retry taps without hiding the successful outcome', async () => {
  mockLocalRuntime.completeV2.mockRejectedValueOnce(
    new Error('retry once'),
  );
  const renderer = await renderApp();
  const root = renderer.root;
  await act(async () => {
    root
      .findByProps({ accessibilityLabel: 'Message DSH' })
      .props.onChangeText('Retry rapidly');
  });
  await act(async () => {
    await actionByLabel(root, 'Send message').props.onPress();
  });

  let retryRequest: StrictCompletionRequest | undefined;
  let resolveRetry:
    | ((value: ReturnType<typeof strictCompletionResult>) => void)
    | undefined;
  mockLocalRuntime.completeV2.mockImplementationOnce(
    (request: StrictCompletionRequest) =>
      new Promise(resolve => {
        retryRequest = request;
        resolveRetry = resolve;
      }),
  );
  const retryPress = actionByLabel(root, 'Retry response').props.onPress;
  let firstTap: Promise<unknown> | undefined;
  let secondTap: Promise<unknown> | undefined;
  await act(async () => {
    const first = retryPress() as unknown;
    const second = retryPress() as unknown;
    if (first instanceof Promise) firstTap = first;
    if (second instanceof Promise) secondTap = second;
    await settle();
  });
  expect(mockLocalRuntime.completeV2).toHaveBeenCalledTimes(2);

  await act(async () => {
    if (retryRequest !== undefined) {
      resolveRetry?.(
        strictCompletionResult(retryRequest, { text: 'One retry wins' }),
      );
    }
    await firstTap;
    await secondTap;
  });
  expect(lastPersistedState().messages.at(-1)?.text).toBe('One retry wins');
  const rendered = JSON.stringify(renderer.toJSON());
  expect(rendered).not.toContain('E_COMPLETION_BUSY');
  expect(rendered).not.toContain('E_COMPLETION_NATIVE');
  expect(
    root.findAllByProps({ accessibilityLabel: 'Retry response' }),
  ).toHaveLength(0);
});

test('ignores a stale Retry callback after moving to another failed chat', async () => {
  mockLocalRuntime.completeV2
    .mockRejectedValueOnce(new Error('first failed'))
    .mockRejectedValueOnce(new Error('second failed'));
  const renderer = await renderApp();
  const root = renderer.root;
  await act(async () => {
    root
      .findByProps({ accessibilityLabel: 'Message DSH' })
      .props.onChangeText('First failed chat');
  });
  await act(async () => {
    await actionByLabel(root, 'Send message').props.onPress();
  });
  const staleRetry = actionByLabel(root, 'Retry response').props.onPress;
  await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
  await act(async () => {
    await actionByLabel(root, 'Create new chat').props.onPress();
  });
  await act(async () => {
    root
      .findByProps({ accessibilityLabel: 'Message DSH' })
      .props.onChangeText('Second failed chat');
  });
  await act(async () => {
    await actionByLabel(root, 'Send message').props.onPress();
  });
  expect(mockLocalRuntime.completeV2).toHaveBeenCalledTimes(2);

  await act(async () => {
    await staleRetry();
  });
  expect(mockLocalRuntime.completeV2).toHaveBeenCalledTimes(2);
  expect(actionByLabel(root, 'Retry response')).toBeDefined();
  expect(lastPersistedState().messages.at(-1)?.text).toBe('Second failed chat');
});

test('blocks Retry while a native attachment picker owns the composer', async () => {
  mockLocalRuntime.completeV2.mockRejectedValueOnce(new Error('first failed'));
  const renderer = await renderApp();
  const root = renderer.root;
  await act(async () => {
    root
      .findByProps({ accessibilityLabel: 'Message DSH' })
      .props.onChangeText('Retry after picker');
  });
  await act(async () => {
    await actionByLabel(root, 'Send message').props.onPress();
  });
  const staleRetry = actionByLabel(root, 'Retry response').props.onPress;
  let rejectPicker: ((error: Error) => void) | undefined;
  mockLocalAttachments.present.mockReturnValueOnce(
    new Promise((_resolve, reject) => {
      rejectPicker = reject;
    }),
  );
  await act(async () => actionByLabel(root, 'Add attachment').props.onPress());
  await chooseAttachmentSource(root, 'Files');
  expect(actionByLabel(root, 'Retry response').props.disabled).toBe(true);

  await act(async () => {
    await staleRetry();
  });
  expect(mockLocalRuntime.completeV2).toHaveBeenCalledTimes(1);
  await act(async () => {
    rejectPicker?.(new Error('picker released'));
    await settle();
  });
});

test('blocks Retry while native attachment preview owns the file', async () => {
  mockLocalAttachments.present.mockResolvedValueOnce({
    schema_version: 1,
    status: 'selected',
    attachments: [
      {
        schema_version: 1,
        id: 'retry-preview',
        kind: 'text',
        name: 'retry-preview.txt',
        mime_type: 'text/plain',
        size: 8,
      },
    ],
  });
  mockLocalRuntime.completeV2.mockRejectedValueOnce(new Error('first failed'));
  const renderer = await renderApp();
  const root = renderer.root;
  await act(async () => actionByLabel(root, 'Add attachment').props.onPress());
  await chooseAttachmentSource(root, 'Files');
  await act(async () => {
    root
      .findByProps({ accessibilityLabel: 'Message DSH' })
      .props.onChangeText('Retry after preview');
  });
  await act(async () => {
    await actionByLabel(root, 'Send message').props.onPress();
  });
  const staleRetry = actionByLabel(root, 'Retry response').props.onPress;
  await act(async () => {
    root
      .findByProps({ accessibilityLabel: 'Message DSH' })
      .props.onChangeText('Do not send during preview');
  });
  const staleSend = actionByLabel(root, 'Send message').props.onPress;
  let closePreview: ((value: unknown) => void) | undefined;
  mockLocalAttachments.presentPreview.mockReturnValueOnce(
    new Promise(resolve => {
      closePreview = resolve;
    }),
  );
  await act(async () => {
    actionByLabel(root, 'Preview retry-preview.txt').props.onPress();
    await Promise.resolve();
  });
  expect(actionByLabel(root, 'Retry response').props.disabled).toBe(true);

  await act(async () => {
    await staleRetry();
    await staleSend();
  });
  expect(mockLocalRuntime.completeV2).toHaveBeenCalledTimes(1);
  await act(async () => {
    closePreview?.({ schema_version: 1, status: 'closed' });
    await settle();
  });
});

test('retry keeps the exact attachment history', async () => {
  mockLocalAttachments.present.mockResolvedValueOnce({
    schema_version: 1,
    status: 'selected',
    attachments: [
      {
        schema_version: 1,
        id: 'pdf-1',
        kind: 'pdf',
        name: 'spec.pdf',
        mime_type: 'application/pdf',
        size: 4096,
      },
    ],
  });
  mockLocalRuntime.completeV2
    .mockRejectedValueOnce(new Error('temporary failure'))
    .mockImplementationOnce(async (request: StrictCompletionRequest) =>
      strictCompletionResult(request, {
        text: 'Recovered with the PDF',
        latency_ms: 50,
      }),
    );
  const renderer = await renderApp();
  const root = renderer.root;

  await act(async () => actionByLabel(root, 'Add attachment').props.onPress());
  await chooseAttachmentSource(root, 'Files');
  await act(async () => {
    actionByLabel(root, 'Send message').props.onPress();
    await settle();
  });
  await act(async () => {
    actionByLabel(root, 'Retry response').props.onPress();
    await settle();
  });

  expect(mockLocalRuntime.completeV2).toHaveBeenCalledTimes(2);
  expect(mockLocalRuntime.completeV2.mock.calls[1]?.[0]?.visibleHistory).toEqual(
    mockLocalRuntime.completeV2.mock.calls[0]?.[0]?.visibleHistory,
  );
  expect(
    mockLocalRuntime.completeV2.mock.calls[1]?.[0]?.visibleHistory?.[0]
      ?.attachments,
  ).toEqual([expect.objectContaining({ id: 'pdf-1', kind: 'pdf' })]);
});

test('reselects V4 Flash when existing history still contains an image', async () => {
  mockLocalAttachments.present.mockResolvedValueOnce({
    schema_version: 1,
    status: 'selected',
    attachments: [
      {
        schema_version: 1,
        id: 'history-image',
        kind: 'image',
        name: 'history.png',
        mime_type: 'image/png',
        size: 128,
        thumbnail_data_url: 'data:image/png;base64,aGlzdG9yeQ==',
      },
    ],
  });
  const renderer = await renderApp();
  const root = renderer.root;

  await act(async () => actionByLabel(root, 'Add attachment').props.onPress());
  await chooseAttachmentSource(root, 'Photos');
  await act(async () => {
    actionByLabel(root, 'Send message').props.onPress();
    await settle();
  });
  await act(async () => composerOptionsChip(root).props.onPress());
  await act(async () => {
    optionInComposerPanel(root, 'Use V4 Pro').props.onPress();
  });
  await act(async () => {
    optionInComposerPanel(root, 'Done').props.onPress();
    await settle();
  });
  await act(async () => {
    root
      .findByProps({ accessibilityLabel: 'Message DSH' })
      .props.onChangeText('Continue with the same image context');
  });
  await act(async () => {
    actionByLabel(root, 'Send message').props.onPress();
    await settle();
  });

  expect(mockLocalRuntime.completeV2.mock.calls.at(-1)?.[0]?.model).toBe(
    'deepseek-v4-flash',
  );
  expect(mockLocalRuntime.completeV2.mock.calls.at(-1)?.[0]?.visibleHistory[0]?.attachments).toEqual([expect.objectContaining({ id: 'history-image' })]);
  expect(lastPersistedState().conversations[0]?.model_id).toBe(
    'deepseek-v4-flash',
  );
});

test('uses the model selected for the active conversation', async () => {
  const renderer = await renderApp();
  const root = renderer.root;

  await act(async () => composerOptionsChip(root).props.onPress());
  await act(async () => {
    optionInComposerPanel(root, 'Use V4 Pro').props.onPress();
  });
  await act(async () => {
    optionInComposerPanel(root, 'Done').props.onPress();
    await settle();
  });
  await act(async () => {
    root
      .findByProps({ accessibilityLabel: 'Message DSH' })
      .props.onChangeText('Use pro');
  });
  await act(async () => {
    root.findByProps({ accessibilityLabel: 'Send message' }).props.onPress();
    await settle();
  });

  expect(mockLocalRuntime.completeV2.mock.calls.at(-1)?.[0]?.model).toBe(
    'deepseek-v4-pro',
  );
  expect(lastPersistedState().conversations[0]?.model_id).toBe(
    'deepseek-v4-pro',
  );
});

test('offers the multimodal Flash Exp route in the model picker', async () => {
  const renderer = await renderApp();
  const root = renderer.root;

  await act(async () => composerOptionsChip(root).props.onPress());
  await act(async () => {
    optionInComposerPanel(root, 'Use Flash Exp').props.onPress();
  });
  await act(async () => {
    optionInComposerPanel(root, 'Done').props.onPress();
    await settle();
  });
  await act(async () => {
    root
      .findByProps({ accessibilityLabel: 'Message DSH' })
      .props.onChangeText('Inspect an image-capable route');
  });
  await act(async () => {
    actionByLabel(root, 'Send message').props.onPress();
    await settle();
  });

  expect(mockLocalRuntime.completeV2.mock.calls.at(-1)?.[0]?.model).toBe(
    'deepseek-v4-flash-vision-exp',
  );
  expect(lastPersistedState().conversations[0]?.model_id).toBe(
    'deepseek-v4-flash-vision-exp',
  );
});

test('selects thinking beside the composer and persists it per conversation', async () => {
  const renderer = await renderApp();
  const root = renderer.root;

  await act(async () => composerOptionsChip(root).props.onPress());
  await act(async () => {
    optionInComposerPanel(root, 'Use Max thinking').props.onPress();
  });
  await act(async () => {
    optionInComposerPanel(root, 'Done').props.onPress();
    await settle();
  });
  await act(async () => {
    root
      .findByProps({ accessibilityLabel: 'Message DSH' })
      .props.onChangeText('Think deeply');
  });
  await act(async () => {
    actionByLabel(root, 'Send message').props.onPress();
    await settle();
  });

  expect(
    mockLocalRuntime.completeV2.mock.calls.at(-1)?.[0]?.thinkingMode,
  ).toBe('max');
  expect(lastPersistedState().conversations[0]?.thinking_mode).toBe('max');

  await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
  await act(async () => actionByLabel(root, 'Settings').props.onPress());
  expect(root.findAllByProps({ children: 'Thinking mode' })).toHaveLength(0);
});

test('passes thinking mode and renders persisted reasoning when enabled', async () => {
  mockLocalRuntime.completeV2.mockImplementation(
    async (request: StrictCompletionRequest) =>
      strictCompletionResult(request, {
        text: 'Reasoned answer',
        latency_ms: 88,
        reasoning: 'I inspected the request before answering.',
      }),
  );
  const renderer = await renderApp();
  const root = renderer.root;

  await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
  await act(async () => actionByLabel(root, 'Settings').props.onPress());
  await act(async () => {
    root
      .findByProps({ accessibilityLabel: 'Show reasoning' })
      .props.onValueChange(true);
    await settle();
  });
  await act(async () => actionByLabel(root, 'Close settings').props.onPress());
  await act(async () => {
    root
      .findByProps({ accessibilityLabel: 'Message DSH' })
      .props.onChangeText('Think first');
  });
  await act(async () => {
    actionByLabel(root, 'Send message').props.onPress();
    await settle();
  });

  expect(
    mockLocalRuntime.completeV2.mock.calls.at(-1)?.[0]?.thinkingMode,
  ).toBe('high');
  expect(
    root.findByProps({ accessibilityLabel: 'Show reasoning' }),
  ).toBeDefined();
  const persisted = lastPersistedState();
  const assistant = persisted.conversations[0]?.messages.at(-1) as unknown as {
    metadata?: { reasoning?: string };
  };
  expect(assistant.metadata?.reasoning).toBe(
    'I inspected the request before answering.',
  );
});

test('stops an in-flight response and ignores its late resolution', async () => {
  let resolveCompletion:
    | ((value: ReturnType<typeof strictCompletionResult>) => void)
    | undefined;
  let stoppedRequest: StrictCompletionRequest | undefined;
  mockLocalRuntime.completeV2.mockImplementation(
    (request: StrictCompletionRequest) =>
      new Promise(resolve => {
        stoppedRequest = request;
        resolveCompletion = resolve;
      }),
  );
  const renderer = await renderApp();
  const root = renderer.root;

  await act(async () => {
    root
      .findByProps({ accessibilityLabel: 'Message DSH' })
      .props.onChangeText('Stop me');
  });
  await act(async () => {
    root.findByProps({ accessibilityLabel: 'Send message' }).props.onPress();
    await settle();
  });
  await act(async () => {
    root.findByProps({ accessibilityLabel: 'Stop response' }).props.onPress();
    await settle();
  });
  expect(mockLocalRuntime.cancelCompletion).toHaveBeenCalledTimes(1);
  expect(mockLocalRuntime.cancelCompletion).toHaveBeenCalledWith(
    stoppedRequest?.roundId,
  );

  await act(async () => {
    if (stoppedRequest !== undefined) {
      resolveCompletion?.(
        strictCompletionResult(stoppedRequest, {
          text: 'Too late',
          latency_ms: 99,
        }),
      );
    }
    await settle();
  });
  expect(lastPersistedState().messages.map(message => message.text)).toEqual([
    'Stop me',
  ]);
});

test('ignores a stale Stop callback from an earlier completed request', async () => {
  const requests: StrictCompletionRequest[] = [];
  const resolvers: Array<
    (value: ReturnType<typeof strictCompletionResult>) => void
  > = [];
  mockLocalRuntime.completeV2.mockImplementation(
    (request: StrictCompletionRequest) =>
      new Promise(resolve => {
        requests.push(request);
        resolvers.push(resolve);
      }),
  );
  const renderer = await renderApp();
  const root = renderer.root;
  await act(async () => {
    root
      .findByProps({ accessibilityLabel: 'Message DSH' })
      .props.onChangeText('First request');
  });
  await act(async () => {
    actionByLabel(root, 'Send message').props.onPress();
    await settle();
  });
  const staleStop = actionByLabel(root, 'Stop response').props.onPress;
  await act(async () => {
    resolvers[0]?.(
      strictCompletionResult(requests[0]!, { text: 'First completed' }),
    );
    await settle();
  });
  await act(async () => {
    root
      .findByProps({ accessibilityLabel: 'Message DSH' })
      .props.onChangeText('Second request');
  });
  await act(async () => {
    actionByLabel(root, 'Send message').props.onPress();
    await settle();
  });
  expect(requests).toHaveLength(2);
  mockLocalRuntime.cancelCompletion.mockClear();

  await act(async () => {
    await staleStop();
  });
  expect(mockLocalRuntime.cancelCompletion).not.toHaveBeenCalled();

  await act(async () => {
    resolvers[1]?.(
      strictCompletionResult(requests[1]!, { text: 'Second completed' }),
    );
    await settle();
  });
  expect(lastPersistedState().messages.map(message => message.text)).toEqual([
    'First request',
    'First completed',
    'Second request',
    'Second completed',
  ]);
});

test('locks without Stop while a successful result is finalizing', async () => {
  let completionRequest: StrictCompletionRequest | undefined;
  let resolveCompletion:
    | ((value: ReturnType<typeof strictCompletionResult>) => void)
    | undefined;
  mockLocalRuntime.completeV2.mockImplementationOnce(
    (request: StrictCompletionRequest) =>
      new Promise(resolve => {
        completionRequest = request;
        resolveCompletion = resolve;
      }),
  );
  let resolveFinalPersist!: (saved: boolean) => void;
  mockSessionSnapshots.casPersistSession
    .mockImplementationOnce(async request => commitBridgedCandidate(request))
    .mockImplementationOnce(async request => commitBridgedCandidate(request))
    .mockImplementationOnce(async request => {
      await new Promise<boolean>(resolve => {
        resolveFinalPersist = resolve;
      });
      return commitBridgedCandidate(request);
    });
  const renderer = await renderApp();
  const root = renderer.root;
  await act(async () => {
    root
      .findByProps({ accessibilityLabel: 'Message DSH' })
      .props.onChangeText('Finalize success');
  });
  let sendPromise: Promise<unknown> | undefined;
  await act(async () => {
    const result = actionByLabel(root, 'Send message').props.onPress() as unknown;
    if (result instanceof Promise) sendPromise = result;
    await settle();
  });
  const staleStop = actionByLabel(root, 'Stop response').props.onPress;
  await act(async () => {
    resolveCompletion?.(
      strictCompletionResult(completionRequest!, { text: 'Finalized answer' }),
    );
    await settle();
  });

  expect(
    root.findAllByProps({ accessibilityLabel: 'Stop response' }),
  ).toHaveLength(0);
  expect(actionByLabel(root, 'Send message').props.disabled).toBe(true);
  await act(async () => {
    await staleStop();
  });
  expect(mockLocalRuntime.cancelCompletion).not.toHaveBeenCalled();
  await act(async () => {
    resolveFinalPersist(true);
    await sendPromise;
  });
  expect(lastPersistedState().messages.at(-1)?.text).toBe('Finalized answer');
  expect(JSON.stringify(renderer.toJSON())).not.toContain('Response stopped.');
});

test('locks without Stop while a failed result is becoming durable', async () => {
  let rejectCompletion!: (error: unknown) => void;
  mockLocalRuntime.completeV2.mockImplementationOnce(
    () =>
      new Promise((_resolve, reject) => {
        rejectCompletion = reject;
      }),
  );
  let resolveFailurePersist!: (saved: boolean) => void;
  mockSessionSnapshots.casPersistSession
    .mockImplementationOnce(async request => commitBridgedCandidate(request))
    .mockImplementationOnce(async request => commitBridgedCandidate(request))
    .mockImplementationOnce(async request => {
      await new Promise<boolean>(resolve => {
        resolveFailurePersist = resolve;
      });
      return commitBridgedCandidate(request);
    });
  const renderer = await renderApp();
  const root = renderer.root;
  await act(async () => {
    root
      .findByProps({ accessibilityLabel: 'Message DSH' })
      .props.onChangeText('Finalize failure');
  });
  let sendPromise: Promise<unknown> | undefined;
  await act(async () => {
    const result = actionByLabel(root, 'Send message').props.onPress() as unknown;
    if (result instanceof Promise) sendPromise = result;
    await settle();
  });
  const staleStop = actionByLabel(root, 'Stop response').props.onPress;
  await act(async () => {
    rejectCompletion({ code: 'E_COMPLETION_TRANSPORT' });
    await settle();
  });

  expect(
    root.findAllByProps({ accessibilityLabel: 'Stop response' }),
  ).toHaveLength(0);
  expect(actionByLabel(root, 'Send message').props.disabled).toBe(true);
  await act(async () => {
    await staleStop();
  });
  expect(mockLocalRuntime.cancelCompletion).not.toHaveBeenCalled();
  await act(async () => {
    resolveFailurePersist(true);
    await sendPromise;
  });
  const rendered = JSON.stringify(renderer.toJSON());
  expect(rendered).toContain('E_COMPLETION_TRANSPORT');
  expect(rendered).not.toContain('Response stopped.');
  expect(actionByLabel(root, 'Retry response')).toBeDefined();
});

test('cancels and persists the active round before switching chats', async () => {
  const renderer = await renderApp();
  const root = renderer.root;
  const sendText = async (text: string) => {
    await act(async () => {
      root
        .findByProps({ accessibilityLabel: 'Message DSH' })
        .props.onChangeText(text);
    });
    await act(async () => {
      await actionByLabel(root, 'Send message').props.onPress();
    });
  };

  await sendText('Origin chat');
  await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
  await act(async () => {
    await actionByLabel(root, 'Create new chat').props.onPress();
  });
  await sendText('Destination chat');
  await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
  await act(async () => {
    await actionByLabel(root, 'Create new chat').props.onPress();
  });
  await sendText('Third chat');
  await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
  await act(async () => {
    await actionByLabel(root, 'Open chat Origin chat').props.onPress();
  });

  let activeRequest: StrictCompletionRequest | undefined;
  let resolveCompletion:
    | ((value: ReturnType<typeof strictCompletionResult>) => void)
    | undefined;
  mockLocalRuntime.completeV2.mockImplementationOnce(
    (request: StrictCompletionRequest) =>
      new Promise(resolve => {
        activeRequest = request;
        resolveCompletion = resolve;
      }),
  );
  await act(async () => {
    root
      .findByProps({ accessibilityLabel: 'Message DSH' })
      .props.onChangeText('Switch while active');
  });
  await act(async () => {
    actionByLabel(root, 'Send message').props.onPress();
    await settle();
  });
  expect(activeRequest).toBeDefined();
  mockSessionSnapshots.casPersistSession.mockClear();
  const cancellation = deferred<{ status: 'cancelled' }>();
  mockLocalRuntime.cancelCompletion.mockReturnValueOnce(cancellation.promise);

  await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
  const drawer = root.findByType(ChatDrawer);
  const destinationId = drawer.props.conversations.find(
    (conversation: { title: string }) => conversation.title === 'Destination chat',
  )?.id;
  const thirdId = drawer.props.conversations.find(
    (conversation: { title: string }) => conversation.title === 'Third chat',
  )?.id;
  await act(async () => {
    const first = drawer.props.onSelect(destinationId);
    const second = drawer.props.onSelect(thirdId);
    await settle();
    expect(mockLocalRuntime.cancelCompletion).toHaveBeenCalledTimes(1);
    cancellation.resolve({ status: 'cancelled' });
    await first;
    await second;
  });

  expect(mockLocalRuntime.cancelCompletion).toHaveBeenCalledWith(
    activeRequest?.roundId,
  );
  const switchedSnapshots = mockSessionSnapshots.casPersistSession.mock.calls.map(
    call =>
      JSON.parse(call[0]?.candidate_json as string) as {
        active_conversation_id: string;
        conversations: Array<{
          id: string;
          title: string;
          attempts: Array<{ status: string }>;
          messages: Array<{ text: string }>;
        }>;
      },
  );
  expect(
    switchedSnapshots.some(snapshot =>
      snapshot.conversations
        .find(conversation => conversation.title === 'Origin chat')
        ?.attempts.some(attempt => attempt.status === 'cancelled'),
    ),
  ).toBe(true);
  const selectedAfterSwitch = switchedSnapshots.at(-1)!;
  expect(
    selectedAfterSwitch.conversations.find(
      conversation => conversation.id === selectedAfterSwitch.active_conversation_id,
    )?.title,
  ).toBe('Destination chat');

  await act(async () => {
    if (activeRequest !== undefined) {
      resolveCompletion?.(
        strictCompletionResult(activeRequest, { text: 'Too late after switch' }),
      );
    }
    await settle();
  });
  expect(
    lastPersistedState().conversations.flatMap(conversation =>
      conversation.messages.map(message => message.text),
    ),
  ).not.toContain('Too late after switch');
  expect(JSON.stringify(renderer.toJSON())).not.toContain('Response stopped.');
});

test('persists cancellation before deleting the active chat and ignores late output', async () => {
  let deletePromise: Promise<unknown> | undefined;
  const alert = jest
    .spyOn(Alert, 'alert')
    .mockImplementation((_title, _message, buttons) => {
      const destructive = buttons?.find(button => button.style === 'destructive');
      const invoke = destructive?.onPress as (() => unknown) | undefined;
      const result = invoke?.();
      if (
        typeof result === 'object' &&
        result !== null &&
        'then' in result
      ) {
        deletePromise = Promise.resolve(result);
      }
    });
  let activeRequest: StrictCompletionRequest | undefined;
  let resolveCompletion:
    | ((value: ReturnType<typeof strictCompletionResult>) => void)
    | undefined;
  mockLocalRuntime.completeV2.mockImplementationOnce(
    (request: StrictCompletionRequest) =>
      new Promise(resolve => {
        activeRequest = request;
        resolveCompletion = resolve;
      }),
  );
  const renderer = await renderApp();
  const root = renderer.root;

  await act(async () => {
    root
      .findByProps({ accessibilityLabel: 'Message DSH' })
      .props.onChangeText('Delete active chat');
  });
  await act(async () => {
    actionByLabel(root, 'Send message').props.onPress();
    await settle();
  });
  expect(activeRequest).toBeDefined();
  mockSessionSnapshots.casPersistSession.mockClear();
  await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
  await act(async () => {
    actionByLabel(root, 'Chat actions for Delete active chat').props.onPress();
    root.findByType(ChatDrawer).props.onDismiss();
  });
  await act(async () => {
    actionByLabel(root, 'Delete conversation').props.onPress();
    root.findByType(ConversationActionSheet).props.onDismiss();
    await settle();
    expect(alert).toHaveBeenCalledTimes(1);
    expect(deletePromise).toBeInstanceOf(Promise);
    await deletePromise;
  });

  expect(mockLocalRuntime.cancelCompletion).toHaveBeenCalledWith(
    activeRequest?.roundId,
  );
  const deletionSnapshots = mockSessionSnapshots.casPersistSession.mock.calls.map(
    call =>
      JSON.parse(call[0]?.candidate_json as string) as {
        conversations: Array<{
          title: string;
          attempts: Array<{ status: string }>;
          messages: Array<{ text: string }>;
        }>;
      },
  );
  const cancelledIndex = deletionSnapshots.findIndex(snapshot =>
    snapshot.conversations
      .find(conversation => conversation.title === 'Delete active chat')
      ?.attempts.some(attempt => attempt.status === 'cancelled'),
  );
  const deletedIndex = deletionSnapshots.findIndex(
    snapshot =>
      !snapshot.conversations.some(
        conversation => conversation.title === 'Delete active chat',
      ),
  );
  expect(cancelledIndex).toBeGreaterThanOrEqual(0);
  expect(deletedIndex).toBeGreaterThan(cancelledIndex);

  await act(async () => {
    if (activeRequest !== undefined) {
      resolveCompletion?.(
        strictCompletionResult(activeRequest, { text: 'Too late after delete' }),
      );
    }
    await settle();
  });
  expect(
    lastPersistedState().conversations.some(
      conversation =>
        conversation.messages.some(message => message.text === 'Too late after delete'),
    ),
  ).toBe(false);
  expect(JSON.stringify(renderer.toJSON())).not.toContain('Response stopped.');
  alert.mockRestore();
});

test.each(['configured', 'missing'] as const)('cold launch waits for credential status before showing configuration actions: %s', async status => {
  let finishCredential!: (value: { status: string }) => void;
  let finishProof!: (value: { proof: typeof proof }) => void;
  mockLocalRuntime.credentialStatusForSlot.mockImplementation(() => new Promise(resolve => { finishCredential = resolve; }));
  mockLocalRuntime.bootstrap.mockImplementation(() => new Promise(resolve => { finishProof = resolve; }));
  const renderer = await renderApp();
  try {
    const composer = () => renderer.root.findByType(ChatComposer);
    const input = () => composer().findByProps({ accessibilityLabel: 'Message DSH' });
    expect(input().props.placeholder).toBe('Preparing DSH…');
    expect(input().props.editable).toBe(false);
    expect(composer().findAllByProps({ accessibilityLabel: 'Configure DeepSeek key' })).toHaveLength(0);
    expect(composer().findByProps({ accessibilityLabel: 'Send message' }).props.accessibilityState).toMatchObject({ busy: true, disabled: true });
    expect(composerOptionsChip(renderer.root).props.disabled).toBe(false);

    await act(async () => { finishCredential({ status }); await settle(); });
    if (status === 'configured') {
      // A slow runtime proof must not keep an already verified key unusable.
      expect(input().props.placeholder).toBe('Message DSH');
      expect(input().props.editable).toBe(true);
      expect(composer().findAllByProps({ accessibilityLabel: 'Configure DeepSeek key' })).toHaveLength(0);
      expect(composer().props.configurationPending).toBe(false);
      await act(async () => { finishProof({ proof }); await settle(); });
    } else {
      expect(input().props.placeholder).toBe('Configure a DeepSeek key to start');
      expect(input().props.editable).toBe(false);
      expect(actionByLabel(composer(), 'Configure DeepSeek key').props.disabled).toBe(false);
      expect(mockLocalRuntime.bootstrap).not.toHaveBeenCalled();
    }
  } finally {
    await act(async () => renderer.unmount());
  }
});

test('a workspace commit arriving after picker dismissal does not report a conflict', async () => {
  const workspace = appWorkspaceDescriptor('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'codextest');
  mockLocalWorkspaces.list.mockResolvedValue({ schema_version: 1, workspaces: [workspace] });
  const renderer = await renderApp();
  const root = renderer.root;
  const commit = mockSessionSnapshots.casPersistSession.getMockImplementation()!;
  let finish!: () => Promise<void>;
  mockSessionSnapshots.casPersistSession.mockImplementationOnce(request => new Promise(resolve => {
    finish = async () => resolve(await commit(request));
  }));
  try {
    await act(async () => { actionByLabel(root, 'Choose workspace').props.onPress(); await settle(); });
    await act(async () => {
      actionByLabel(root.findByProps({ testID: 'workspace-picker-sheet' }), 'Use codextest').props.onPress();
      await settle();
    });
    expect(finish).toBeDefined();
    expect(root.findByType(WorkspacePickerSheet).props.activeWorkspaceId).toBe(workspace.workspace_id);
    await act(async () => { root.findByType(WorkspacePickerSheet).props.onClose(); await settle(); });
    await act(async () => { await finish(); await settle(); });
    expect(lastPersistedState().conversations.find(chat => chat.id === lastPersistedState().active_conversation_id)?.workspace_id).toBe(workspace.workspace_id);
    expect(root.findByType(WorkspacePickerSheet).props.visible).toBe(false);
    expect(root.findAllByProps({ children: 'E_WORKSPACE_CONFLICT' })).toHaveLength(0);
  } finally {
    await act(async () => renderer.unmount());
  }
});

test('workspace selection still works after opening and closing Files', async () => {
  const workspace = appWorkspaceDescriptor('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'codextest');
  mockLocalWorkspaces.list.mockResolvedValue({ schema_version: 1, workspaces: [workspace] });
  const renderer = await renderApp();
  const root = renderer.root;
  try {
    await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
    await act(async () => {
      root.findByType(ChatDrawer).props.onOpenFiles();
      root.findByType(ChatDrawer).props.onDismiss();
      await settle();
    });
    expect(root.findByType(WorkspaceDrawer).props.visible).toBe(true);
    await act(async () => { root.findByType(WorkspaceDrawer).props.onClose(); await settle(); });
    await act(async () => { actionByLabel(root, 'Choose workspace').props.onPress(); await settle(); });
    await act(async () => {
      actionByLabel(root.findByProps({ testID: 'workspace-picker-sheet' }), 'Use codextest').props.onPress();
      await settle();
    });
    expect(root.findByType(WorkspacePickerSheet).props.visible).toBe(false);
    expect(root.findAllByProps({ children: 'E_WORKSPACE_CONFLICT' })).toHaveLength(0);
  } finally {
    await act(async () => renderer.unmount());
  }
});

test('keeps model selection available before configuring a key', async () => {
  mockLocalRuntime.credentialStatusForSlot.mockResolvedValue({ status: 'missing' });
  const renderer = await renderApp();
  const root = renderer.root;
  expect(composerOptionsChip(root).props.disabled).toBe(false);
  await act(async () => { composerOptionsChip(root).props.onPress(); });
  expect(root.findByType(ChatComposer).props.optionsVisible).toBe(true);
});

test('offers native credential recovery when no key is configured', async () => {
  mockLocalRuntime.credentialStatusForSlot.mockResolvedValue({ status: 'missing' });
  const renderer = await renderApp();
  const root = renderer.root;

  expect(
    root.findByProps({ accessibilityLabel: 'Message DSH' }).props.editable,
  ).toBe(false);
  await act(async () => {
    actionByLabel(root, 'Configure DeepSeek key').props.onPress();
    await settle();
  });

  expect(mockLocalRuntime.presentCredentialPromptForSlot).toHaveBeenCalledTimes(1);
  expect(mockLocalRuntime.presentCredentialPromptForSlot).toHaveBeenCalledWith(
    'DEEPSEEK_API_KEY',
    'en-US',
  );
  expect(
    root.findByProps({ accessibilityLabel: 'Message DSH' }).props.editable,
  ).toBe(true);
});

test('applies and persists light theme plus Simplified Chinese immediately', async () => {
  const renderer = await renderApp();
  const root = renderer.root;

  await act(async () => {
    actionByLabel(root, 'Open navigation').props.onPress();
  });
  await act(async () => {
    actionByLabel(root, 'Settings').props.onPress();
  });
  await act(async () => {
    actionByLabel(root, 'Light').props.onPress();
    await settle();
  });
  await act(async () => {
    actionByLabel(root, '简体中文').props.onPress();
    await settle();
  });

  expect(root.findByProps({ children: '设置' })).toBeDefined();
  const serialized = lastPersistedCandidateJSON();
  const persisted = JSON.parse(serialized) as {
    preferences: { theme_mode: string; locale: string };
  };
  expect(persisted.preferences).toMatchObject({
    theme_mode: 'light',
    locale: 'zh-CN',
  });
});

test('fails gracefully when the platform has no local native adapter', async () => {
  mockLocalRuntime.isAvailable.mockReturnValue(false);
  const renderer = await renderApp();
  const root = renderer.root;

  expect(mockLocalRuntime.credentialStatus).not.toHaveBeenCalled();
  expect(
    root.findByProps({ accessibilityLabel: 'Message DSH' }).props.editable,
  ).toBe(false);
  await act(async () => {
    actionByLabel(root, 'Configure DeepSeek key').props.onPress();
  });
  expect(root.findByType(SettingsSheet).props.visible).toBe(true);
  const adapterButton = root
    .findAllByProps({ accessibilityLabel: 'Configure DeepSeek key' })
    .find(instance => instance.props.disabled === true);
  expect(adapterButton).toBeDefined();
});


test('opens Files for an unregistered project without creating or rebinding a chat', async () => {
  const renderer = await renderApp();
  const root = renderer.root;
  const activeId = root.findByType(ChatDrawer).props.activeId;
  await openProjectsSurface(root);
  await act(async () => {
    await root
      .findByType(ProjectsSurface)
      .props.onOpenFiles(contextProject, () => true);
    await settle();
  });
  expect(mockLocalWorkspaces.bootstrapLegacyProject).toHaveBeenCalledWith(
    expect.objectContaining({ project_id: contextProject.id }),
  );
  expect(root.findByType(WorkspaceDrawer).props.visible).toBe(true);
  expect(root.findByType(WorkspaceDrawer).props.workspaceRoot).toMatchObject({
    workspace_id: CONTEXT_RUNTIME_ID,
    project_id: contextProject.id,
  });
  expect(root.findByType(ChatDrawer).props.activeId).toBe(activeId);
});

test('does not present a root after its Projects view is no longer current', async () => {
  const renderer = await renderApp();
  const root = renderer.root;
  await openProjectsSurface(root);
  let current = true;
  const bootstrap =
    mockLocalWorkspaces.bootstrapLegacyProject.getMockImplementation();
  mockLocalWorkspaces.bootstrapLegacyProject.mockImplementationOnce(
    async (request) => {
      const result = await bootstrap?.(request);
      current = false;
      return result;
    },
  );
  await act(async () => {
    await root
      .findByType(ProjectsSurface)
      .props.onOpenFiles(contextProject, () => current);
    await settle();
  });
  expect(root.findByType(WorkspaceDrawer).props.visible).toBe(false);
});


test('Files registration remains reusable by the subsequent project chat action', async () => {
  jest.useFakeTimers();
  mockLocalWorkspaces.list.mockImplementation(async () => ({
    schema_version: 1,
    workspaces: bootstrappedLegacyProjectId === null ? [] : [appWorkspaceDescriptor(CONTEXT_RUNTIME_ID)],
  }));
  const renderer = await renderApp();
  const root = renderer.root;
  await openProjectsSurface(root);
  await act(async () => {
    await root.findByType(ProjectsSurface).props.onOpenFiles(contextProject, () => true);
    await settle();
  });
  expect(root.findByType(WorkspaceDrawer).props.visible).toBe(true);
  await act(async () => { root.findByType(WorkspaceDrawer).props.onClose(); await settle(); });
  await act(async () => {
    await root.findByType(ProjectsSurface).props.onChatInProject(contextProject);
    await settle();
  });
  expect(mockLocalWorkspaces.bootstrapLegacyProject).toHaveBeenCalledTimes(1);
  expect(lastPersistedState().conversations.some(conversation => conversation.project_id === contextProject.id)).toBe(true);
  await act(async () => { jest.advanceTimersByTime(300); await settle(); });
  await act(async () => renderer.unmount());
});

test('keeps a new project binding alive when native resolution yields across the conversation selection effect', async () => {
  jest.useFakeTimers();
  mockLocalWorkspaces.list.mockImplementation(async () => ({
    schema_version: 1,
    workspaces: bootstrappedLegacyProjectId === null ? [] : [appWorkspaceDescriptor(CONTEXT_RUNTIME_ID)],
  }));
  const originalResolve = mockLocalWorkspaces.resolve.getMockImplementation()!;
  mockLocalWorkspaces.resolve.mockImplementation(async request => {
    await new Promise<void>(resolve => setTimeout(resolve, 1));
    return originalResolve(request);
  });
  const renderer = await renderApp();
  await openProjectsSurface(renderer.root);
  let opening!: Promise<void>;
  await act(async () => {
    opening = renderer.root.findByType(ProjectsSurface).props.onChatInProject(contextProject);
    await settle();
  });
  for (let index = 0; index < 40; index += 1) {
    await act(async () => { jest.advanceTimersByTime(1); await settle(); });
  }
  await act(async () => { await opening; await settle(); });
  expect(lastPersistedState().conversations.some(conversation => conversation.project_id === contextProject.id)).toBe(true);
  await act(async () => { jest.advanceTimersByTime(300); await settle(); renderer.unmount(); });
});

test('cold launch opens a blank chat after restoration and history remains reopenable on resume', async () => {
  const appStateListeners: Array<(state: AppStateStatus) => void> = [];
  const appStateSubscription = jest.spyOn(AppState, 'addEventListener').mockImplementation((event, listener) => {
    if (event === 'change') appStateListeners.push(listener);
    return { remove: jest.fn() };
  });
  const stored = createChatStore();
  const previous = stored.createConversation({ title: 'Previous launch history', modelId: 'deepseek-v4-pro' });
  stored.appendUserMessage(previous, 'Keep this previous conversation');
  queuePresentSession(stored.serialize());
  const renderer = await renderApp();
  const root = renderer.root;
  const coldState = lastPersistedState();
  expect(coldState.active_conversation_id).not.toBe(previous);
  expect(coldState.conversations.some(conversation => conversation.id === previous)).toBe(true);
  expect(root.findAllByType(EmptyChat).length).toBeGreaterThan(0);
  expect(root.findByType(ChatComposer).props.draft).toBe('');
  await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
  await act(async () => {
    await root.findByType(ChatDrawer).props.onSelect(previous);
    await settle();
  });
  expect(lastPersistedState().active_conversation_id).toBe(previous);
  const persistedCount = mockSessionSnapshots.casPersistSession.mock.calls.length;
  await act(async () => { renderer.update(<App />); await settle(); });
  expect(lastPersistedState().active_conversation_id).toBe(previous);
  expect(mockSessionSnapshots.casPersistSession.mock.calls).toHaveLength(persistedCount);
  await act(async () => root.findByType(ChatComposer).props.onChange('Keep draft on resume'));
  await act(async () => {
    appStateListeners.forEach(listener => listener('background'));
    appStateListeners.forEach(listener => listener('active'));
    await settle();
  });
  expect(lastPersistedState().active_conversation_id).toBe(previous);
  expect(root.findByType(ChatComposer).props.draft).toBe('Keep draft on resume');
  appStateSubscription.mockRestore();
});

test.each([false, true])('cold CC workspace binding preserves its owner when preferences changed=%s', async changed => {
  const stored = createChatStore();
  const history = stored.createConversation({ modelId: 'claude-sonnet-5', thinkingMode: 'high' });
  stored.appendUserMessage(history, 'previous CC conversation');
  const preferences = createPreferencesStore();
  preferences.setSelectedHarness('claude-code');
  queuePresentSession(JSON.stringify({ ...JSON.parse(stored.serialize()), preferences: JSON.parse(preferences.serialize()) }));
  const workspace = appWorkspaceDescriptor('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'Smoke-0902');
  mockLocalWorkspaces.list.mockResolvedValue({ schema_version: 1, workspaces: [workspace] });
  const renderer = await renderApp();
  const root = renderer.root;
  expect(root.findByType(ChatComposer).props.model).toBe('claude-sonnet-5');
  if (changed) {
    // A queued preference must not replace the in-flight binding owner.
    await act(async () => root.findByType(AppPresentationProvider).props.store.setShowReasoning(true));
  }
  await act(async () => actionByLabel(root, 'Choose workspace').props.onPress());
  await act(async () => {
    actionByLabel(root.findByProps({ testID: 'workspace-picker-sheet' }), 'Use Smoke-0902').props.onPress();
    await settle();
  });
  expect(lastPersistedState().conversations.find(chat => chat.id === lastPersistedState().active_conversation_id)?.workspace_id).toBe(workspace.workspace_id);
  expect(root.findByType(WorkspacePickerSheet).props.visible).toBe(false);
  expect(root.findAllByProps({ children: 'E_WORKSPACE_CONFLICT' })).toHaveLength(0);
});


test.each([
  ['dsh', 'deepseek-v4-flash', 'claude-code', 'claude-sonnet-5'],
  ['claude-code', 'claude-sonnet-5', 'dsh', 'deepseek-v4-pro'],
] as const)('cold launch hydrates last %s selection before any provider startup work', async (harness, model, defaultHarness, defaultModel) => {
  const stored = createChatStore();
  const previous = stored.createConversation({ modelId: model, thinkingMode: 'high' });
  stored.appendUserMessage(previous, 'Last used model history');
  const preferences = createPreferencesStore();
  preferences.setSelectedHarness(defaultHarness);
  preferences.setDefaultModel(defaultModel);
  preferences.setThinkingMode('off');
  queuePresentSession(JSON.stringify({ ...JSON.parse(stored.serialize()), preferences: JSON.parse(preferences.serialize()) }));
  const loaded = bridgedLoadResult();
  let finishLoad!: (value: typeof loaded) => void;
  mockSessionSnapshots.loadSessionSnapshot.mockReset().mockImplementation(async () => bridgedLoadResult())
    .mockImplementationOnce(() => new Promise(resolve => { finishLoad = resolve; }));
  const appState = jest.spyOn(AppState, 'addEventListener').mockReturnValue({ remove: jest.fn() });
  const providerAvailable = jest.spyOn(ProviderConfigurations, 'isAvailable').mockReturnValue(true);
  const source = { schema_version: 1 as const, source: 'api_key' as const, ready: true, error_code: null };
  const claude = jest.spyOn(HarnessAuth, 'claudeChatSource').mockResolvedValue(source);
  const codex = jest.spyOn(HarnessAuth, 'codexChatSource').mockResolvedValue(source);
  const glm = jest.spyOn(GlmAccount, 'glmCredentialSource');
  const provider = jest.spyOn(ProviderConfigurations, 'read').mockImplementation(async id => ({
    schema_version: 1, harness_id: id, name: 'Official', endpoint_url: 'https://example.test',
    protocol: 'messages', auth_type: 'x-api-key', send_reasoning: true, model_mappings: {}, official: true,
  }));
  const runtime = mockLocalRuntime as MockLocalRuntime & { bootstrapForHarness?: jest.Mock };
  runtime.bootstrapForHarness = jest.fn().mockResolvedValue({ proof });
  let renderer: Renderer | undefined;
  try {
    renderer = await renderApp();
    // Exercise a pre-hydration provider selection while native storage is slow.
    for (const pendingHarness of ['claude-code', 'codex', 'glm']) {
      await act(async () => {
        renderer!.root.findByType(AppPresentationProvider).props.store.setSelectedHarness(pendingHarness);
        await settle();
      });
      expect(claude).not.toHaveBeenCalled();
      expect(codex).not.toHaveBeenCalled();
      expect(glm).not.toHaveBeenCalled();
      expect(provider).not.toHaveBeenCalled();
      expect(mockLocalRuntime.credentialStatus).not.toHaveBeenCalled();
      expect(mockLocalRuntime.credentialStatusForSlot).not.toHaveBeenCalled();
      expect(runtime.bootstrapForHarness).not.toHaveBeenCalled();
    }
    await act(async () => { finishLoad(loaded); await settle(); });
    const root = renderer.root;
    expect(root.findByType(ChatComposer).props.model).toBe(model);
    expect(root.findByType(ChatComposer).props.thinkingMode).toBe('high');
    expect(root.findAllByType(EmptyChat).length).toBeGreaterThan(0);
    const persisted = lastPersistedState();
    const blank = persisted.conversations.find(chat => chat.id === persisted.active_conversation_id);
    expect(blank).toMatchObject({ model_id: model, thinking_mode: 'high', project_id: null, workspace_id: null, runtime_context_id: null, project_context: null });
    expect(blank?.id).not.toBe(previous);
    expect(root.findByType(AppPresentationProvider).props.store.getState()).toEqual(preferences.getState());
    expect(runtime.bootstrapForHarness).toHaveBeenCalledWith(harness);
    expect(runtime.bootstrapForHarness.mock.calls.every(([id]) => id === harness)).toBe(true);
    expect(codex).not.toHaveBeenCalled();
    expect(glm).not.toHaveBeenCalled();
    if (harness === 'dsh') {
      expect(claude).not.toHaveBeenCalled();
      expect(mockLocalRuntime.credentialStatusForSlot).toHaveBeenCalledWith('DEEPSEEK_API_KEY');
      expect(mockLocalRuntime.credentialStatusForSlot).not.toHaveBeenCalledWith('ANTHROPIC_API_KEY');
      expect(provider).not.toHaveBeenCalled();
    } else {
      expect(claude).toHaveBeenCalled();
      expect(mockLocalRuntime.credentialStatus).not.toHaveBeenCalled();
      expect(mockLocalRuntime.credentialStatusForSlot).toHaveBeenCalledWith('ANTHROPIC_API_KEY');
    }
  } finally {
    await act(async () => renderer?.unmount());
    claude.mockRestore(); codex.mockRestore(); glm.mockRestore(); provider.mockRestore();
    providerAvailable.mockRestore(); appState.mockRestore();
    delete runtime.bootstrapForHarness;
  }
});

test('model and effort choices survive New Chat and remount, including a selected blank', async () => {
  const appState = jest.spyOn(AppState, 'addEventListener').mockReturnValue({ remove: jest.fn() });
  const stored = createChatStore();
  const previous = stored.createConversation({ modelId: 'deepseek-v4-flash', thinkingMode: 'high' });
  stored.appendUserMessage(previous, 'Earlier history');
  const preferences = createPreferencesStore();
  preferences.setSelectedHarness('claude-code');
  preferences.setDefaultModel('claude-sonnet-5');
  preferences.setThinkingMode('off');
  queuePresentSession(JSON.stringify({ ...JSON.parse(stored.serialize()), preferences: JSON.parse(preferences.serialize()) }));
  let renderer = await renderApp();
  let root = renderer.root;
  await act(async () => {
    root.findByType(ConversationOptionsPicker).props.onSelectModel('deepseek-v4-pro');
    await settle();
  });
  await act(async () => {
    root.findByType(ConversationOptionsPicker).props.onSelectThinkingMode('max');
    await settle();
  });
  await act(async () => actionByLabel(root, 'Open navigation').props.onPress());
  await act(async () => { await root.findByType(ChatDrawer).props.onNewChat(); await settle(); });
  expect(root.findByType(ChatComposer).props.model).toBe('deepseek-v4-pro');
  expect(root.findByType(ChatComposer).props.thinkingMode).toBe('max');
  const blankId = lastPersistedState().active_conversation_id;
  await act(async () => renderer.unmount());
  renderer = await renderApp();
  root = renderer.root;
  expect(root.findByType(ChatComposer).props.model).toBe('deepseek-v4-pro');
  expect(root.findByType(ChatComposer).props.thinkingMode).toBe('max');
  expect(root.findByType(ChatDrawer).props.activeId).toBe(blankId);
  expect(root.findAllByType(EmptyChat).length).toBeGreaterThan(0);
  await act(async () => renderer.unmount());
  appState.mockRestore();
});

test.each(['credential', 'proof'] as const)('provider refresh handles a %s failure without keeping stale credential state', async failure => {
  const appState = jest.spyOn(AppState, 'addEventListener').mockReturnValue({ remove: jest.fn() });
  const renderer = await renderApp();
  try {
    const root = renderer.root;
    expect(root.findByType(SettingsSheet).props.credentialConfigured).toBe(true);
    mockLocalRuntime.bootstrap.mockClear();
    if (failure === 'credential') {
      mockLocalRuntime.credentialStatusForSlot.mockRejectedValueOnce(new Error('credential read failed'));
    } else {
      mockLocalRuntime.bootstrap.mockRejectedValueOnce(new Error('runtime proof failed'));
    }
    await act(async () => {
      root.findByType(SettingsSheet).props.onProviderConfigurationChanged('dsh');
      await settle();
    });
    expect(root.findByType(SettingsSheet).props.credentialConfigured).toBe(failure === 'proof');
    expect(mockLocalRuntime.bootstrap).toHaveBeenCalledTimes(failure === 'proof' ? 1 : 0);
  } finally {
    await act(async () => renderer.unmount());
    appState.mockRestore();
  }
});

test('sending without a bound workspace shows a hint whose action opens the picker', async () => {
  mockAgentRuntime.isAvailable.mockReturnValue(true);
  const renderer = await renderApp();
  const root = renderer.root;
  try {
    expect(
      root.findByProps({ testID: 'composer-workspace-chip' }).props.accessibilityValue,
    ).toEqual({ text: 'Choose workspace' });
    expect(root.findAllByProps({ testID: 'workspace-unbound-hint' })).toHaveLength(0);
    await act(async () =>
      root.findByProps({ accessibilityLabel: 'Message DSH' }).props.onChangeText('hello'),
    );
    await act(async () => {
      actionByLabel(root, 'Send message').props.onPress();
      await settle();
      await settle();
    });
    expect(root.findAllByProps({ testID: 'workspace-unbound-hint' }).length).toBeGreaterThan(0);
    await act(async () => {
      root.findByProps({ testID: 'workspace-unbound-hint-action' }).props.onPress();
      await settle();
    });
    expect(root.findByType(WorkspacePickerSheet).props.visible).toBe(true);
  } finally {
    // Leave the tree mounted like the other agent-runtime flows: the task
    // bridge subscription has no emitter to remove in this environment.
    mockAgentRuntime.isAvailable.mockReturnValue(false);
  }
});

test('preserves stored chats after a failed startup read and explicit retry', async () => {
  const stored = createChatStore();
  const conversation = stored.createConversation();
  stored.appendUserMessage(conversation, 'Keep this saved conversation');
  mockSessionSnapshots.loadSessionSnapshot.mockRejectedValueOnce({
    code: 'E_SESSION_PROTECTION', message: 'private device path must not be displayed',
  });
  queuePresentSession(stored.serialize(), 7);
  const renderer = await renderApp();
  expect(mockSessionSnapshots.casPersistSession).not.toHaveBeenCalled();
  expect(mockLocalAttachments.prune).not.toHaveBeenCalled();
  expect(JSON.stringify(renderer.toJSON())).toContain('E_SESSION_PROTECTION');
  expect(JSON.stringify(renderer.toJSON())).not.toContain('private device path');
  expect(renderer.root.findByType(ChatComposer).props.configurationAction).toBe('Retry loading chats');
  expect(JSON.stringify(renderer.toJSON())).not.toContain('NOT CONFIGURED');
  await act(async () => {
    await renderer.root.findByProps({ testID: 'retry-session-load' }).props.onPress();
    await settle();
  });
  expect(renderer.root.findAllByProps({ testID: 'retry-session-load' })).toHaveLength(0);
  expect(lastPersistedCandidateJSON()).toContain('Keep this saved conversation');
  expect(mockSessionSnapshots.casPersistSession.mock.calls[0]?.[0].expected.snapshot.generation).toBe(7);
});

test.each(['settings', 'new chat', 'background'] as const)(
  'keeps unreadable chats and attachments intact when %s changes before retry', async action => {
    const appStateListeners: Array<(state: AppStateStatus) => void> = [];
    jest.spyOn(AppState, 'addEventListener').mockImplementation((event, listener) => {
      if (event === 'change') appStateListeners.push(listener);
      return { remove: jest.fn() };
    });
    const stored = createChatStore();
    const conversation = stored.createConversation();
    stored.appendUserMessage(conversation, 'Original saved attachment', {
      attachments: [{
        schema_version: 1, id: 'saved-attachment', kind: 'text',
        name: 'saved.txt', mime_type: 'text/plain', size: 12,
      }],
    });
    mockSessionSnapshots.loadSessionSnapshot.mockRejectedValueOnce({ code: 'E_SESSION_PROTECTION' });
    // Storage becomes readable after the first read. Unrelated UI/background
    // work must not acquire its authority to overwrite the blank projection.
    queuePresentSession(stored.serialize(), 7);
    const renderer = await renderApp();
    const root = renderer.root;
    await act(async () => {
      if (action === 'settings') {
        actionByLabel(root, 'Open navigation').props.onPress();
        root.findByType(ChatDrawer).props.onOpenSettings();
        root.findByType(AppPresentationProvider).props.store.setThemeMode('light');
        root.findByType(SettingsSheet).props.onPreferencesChanged();
        // This callback can arrive independently of the settings UI and reaches
        // persistCurrent, exercising the write gate beneath surface admission.
        root.findByType(SettingsSheet).props.onProviderConfigurationChanged('dsh');
      } else if (action === 'new chat') {
        actionByLabel(root, 'Open navigation').props.onPress();
        await root.findByType(ChatDrawer).props.onNewChat();
      } else {
        appStateListeners.forEach(listener => listener('background'));
        appStateListeners.forEach(listener => listener('active'));
      }
      await settle();
    });
    expect(mockSessionSnapshots.loadSessionSnapshot).toHaveBeenCalledTimes(1);
    expect(mockSessionSnapshots.casPersistSession).not.toHaveBeenCalled();
    expect(mockLocalAttachments.prune).not.toHaveBeenCalled();
    expect(root.findByType(SettingsSheet).props.visible).toBe(false);
    expect(root.findByType(ChatDrawer).props.visible).toBe(false);

    await act(async () => {
      await root.findByProps({ testID: 'retry-session-load' }).props.onPress();
      await settle();
    });
    expect(root.findAllByProps({ testID: 'retry-session-load' })).toHaveLength(0);
    expect(lastPersistedCandidateJSON()).toContain('Original saved attachment');
    expect(mockSessionSnapshots.casPersistSession.mock.calls[0]?.[0].expected.snapshot.generation).toBe(7);
    expect(mockLocalAttachments.prune).toHaveBeenCalledWith(['saved-attachment']);
    expect(mockLocalAttachments.prune.mock.calls.every(([ids]) => ids.includes('saved-attachment'))).toBe(true);
  },
);

test('retry re-probes a native session module that becomes available after startup', async () => {
  jest.useFakeTimers();
  mockSessionSnapshots.isAvailable.mockReturnValue(false);
  const stored = createChatStore();
  const conversation = stored.createConversation();
  stored.appendUserMessage(conversation, 'Recovered after native module became available');
  queuePresentSession(stored.serialize(), 7);
  const renderer = await renderApp();
  await act(async () => {
    jest.advanceTimersByTime(100);
    await settle();
  });
  expect(mockSessionSnapshots.loadSessionSnapshot).not.toHaveBeenCalled();
  expect(mockSessionSnapshots.casPersistSession).not.toHaveBeenCalled();
  expect(mockLocalAttachments.prune).not.toHaveBeenCalled();
  expect(renderer.root.findByType(ChatComposer).props.configurationAction).toBe('Retry loading chats');

  mockSessionSnapshots.isAvailable.mockReturnValue(true);
  await act(async () => {
    renderer.root.findByType(ChatComposer).props.onConfigure();
    await settle();
  });
  expect(renderer.root.findAllByProps({ testID: 'retry-session-load' })).toHaveLength(0);
  expect(lastPersistedCandidateJSON()).toContain('Recovered after native module became available');
  expect(mockSessionSnapshots.casPersistSession.mock.calls[0]?.[0].expected.snapshot.generation).toBe(7);
  expect(mockLocalRuntime.presentCredentialPromptForSlot).not.toHaveBeenCalled();
});
