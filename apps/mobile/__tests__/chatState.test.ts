import { createPreferencesStore } from '../src/preferences';
import {
  CHAT_STATE_SCHEMA_VERSION,
  ChatStateValidationError,
  chatReducer,
  createChatStore,
  createEmptyChatState,
  deriveAutoTitle,
  hydrateChatState,
  migrateAgentApprovalTokenV3,
  parsePersistedAgentCallJournalV3,
  parsePersistedAgentAttemptJournalV3,
  safeHydrateChatState,
  selectActiveConversation,
  selectActiveMessages,
  selectProjectContextSnapshotReferences,
  selectOrderedConversations,
  serializeChatState,
  MAX_PROJECT_CONTEXT_SNAPSHOT_REFERENCE_ROWS,
  MAX_CHAT_MESSAGE_LENGTH,
  type ChatAttachment,
  type ChatStore,
  type CompletionRoundReceiptV1,
  type ChatState,
  type PersistedChatStateV7,
  type PersistedAgentAttemptJournalV3,
  type AgentConversationGrantV2,
  type AgentControllerCASV1,
  type AgentToolReceiptV1,
  type AgentCASCheckpointInput,
  type AgentTranscriptCleanupV1,
  type NativeSessionCommitProofV1,
  type NativeAgentDiscardProofV1,
  type SessionEventV2,
  type PersistedAgentCallJournalV3,
  type TurnAttemptV1,
  type ProjectContextMutationScope,
  type ScopedProjectContextTransaction,
} from '../src/state';
import {
  agentTextSHA256,
  sessionSnapshotSHA256,
} from '../src/completion/SessionPersistence';
import type {
  ProjectContextConsentV1,
  ProjectContextManifestV1,
} from '../src/project-context';
import {
  validateAgentStoreTransition,
  type AgentStoreTransitionEvidence,
} from '../src/agent/AgentStoreTransitions';
import {
  validateAgentControllerPreflight,
  type AgentControllerPreflightV1,
} from '../src/agent/AgentControllerPreflight';
import { projectAgentVisibleHistory } from '../src/agent/AgentVisibleHistory';

const T0 = '2026-08-24T01:00:00.000Z';
const T1 = '2026-08-24T01:01:00.000Z';
const T2 = '2026-08-24T01:02:00.000Z';
const T3 = '2026-08-24T01:03:00.000Z';

const IMAGE_ATTACHMENT: ChatAttachment = {
  schema_version: 1,
  id: 'attachment-image-1',
  kind: 'image',
  name: 'receipt.png',
  mime_type: 'image/png',
  size: 2048,
  thumbnail_data_url: 'data:image/png;base64,cHJldmlldw==',
};

function beginRoundPreflightForAttempt(
  attempt: TurnAttemptV1,
  journal: PersistedAgentAttemptJournalV3,
  cas: AgentControllerCASV1,
  operationId: string,
): AgentControllerPreflightV1 {
  const round = journal.round_lineage;
  if (round === null) throw new Error('test preflight requires round lineage');
  const preflight = validateAgentControllerPreflight({
    schema_version: 1,
    source: 'completion_controller',
    kind: 'begin_round',
    operation_id: operationId,
    base_cas: cas,
    conversation_id: cas.conversation_id,
    task_id: cas.task_id,
    attempt_id: cas.attempt_id,
    round_id: round.round_id,
    round_index: journal.round_index,
    launch_attempt: round.launch_attempt,
    expected_round_revision: round.native_row_revision ?? 0,
    transport_schema_version: 2,
    model: attempt.modelId,
    thinking_mode: attempt.thinkingMode,
    visible_history_sha256: attempt.visibleHistorySha256 ?? 'f'.repeat(64),
    visible_message_count: attempt.visibleMessageIds.length,
    project_context_sha256: null,
    transcript: journal.transcript,
    root: journal.root,
    registry_version: 1,
    toolset_sha256: journal.toolset_sha256,
  });
  if (preflight === null) throw new Error('invalid test begin-round preflight');
  return preflight;
}

function stripSchema9Fields(root: Record<string, unknown>): void {
  delete root.workspace_authority_outbox;
  delete root.agent_transcript_cleanup_outbox;
  delete root.session_events;
  delete root.preferences;
  delete root.project_context_destructive_epoch;
  delete root.project_context_destructive_transition;
  for (const conversation of root.conversations as Array<
    Record<string, unknown>
  >) {
    delete conversation.agent_grants;
    delete conversation.workspace_id;
    delete conversation.workspace_binding;
    delete conversation.workspace_bootstrap_state;
    for (const attempt of (conversation.attempts ?? []) as Array<
      Record<string, unknown>
    >) {
      attempt.schema_version = 1;
      delete attempt.journal_revision;
      delete attempt.agent;
      delete attempt.workspace_id;
      delete attempt.workspace_binding_revision;
    }
  }
}

function projectContextScope(
  store: ChatStore,
  conversationId: string,
): ProjectContextMutationScope {
  const conversation = store.getState().conversations[conversationId];
  if (
    conversation === undefined ||
    conversation.projectId === null ||
    conversation.runtimeContextId === null ||
    conversation.projectContext === null
  ) {
    throw new Error('test fixture requires a bound runtime project context');
  }
  return {
    conversationId,
    projectId: conversation.projectId,
    runtimeContextId: conversation.runtimeContextId,
    modelId: conversation.modelId,
    expectedContext: conversation.projectContext,
  };
}

function createConversation(
  state: ChatState,
  id: string,
  at: string,
  select = true,
): ChatState {
  return chatReducer(state, {
    type: 'conversation/create',
    payload: { id, at, select },
  });
}

function appendUser(
  state: ChatState,
  conversationId: string,
  id: string,
  text: string,
  createdAt: string,
  attachments: readonly ChatAttachment[] = [],
): ChatState {
  return chatReducer(state, {
    type: 'message/append',
    payload: {
      conversationId,
      message: { id, role: 'user', text, createdAt, attachments },
    },
  });
}

/** Native-shaped test double: the Store must consume this ref, never derive it. */
function nativeCommittedProof(
  store: ChatStore,
  generation: number,
): NativeSessionCommitProofV1 {
  const sessionSha256 = sessionSnapshotSHA256(store.serialize());
  if (sessionSha256 === null) throw new Error('test candidate is not serializable');
  return {
    schema_version: 1,
    status: 'committed',
    snapshot: { schema_version: 1, generation, session_sha256: sessionSha256 },
  };
}

function nativeDiscardProof(
  cleanup: AgentTranscriptCleanupV1,
  taskId: string,
): NativeAgentDiscardProofV1 {
  return {
    schema_version: 2,
    status: 'already_missing',
    operation_id: '77777777-7777-4777-8777-777777777777',
    cleanup_id: cleanup.cleanup_id,
    task_id: taskId,
    conversation_id: cleanup.conversation_id,
    attempt_id: cleanup.attempt_id,
    transcript_ref: cleanup.transcript_ref,
    transcript_sha256: cleanup.transcript_sha256,
  };
}

describe('chat reducer', () => {
  test('creates, selects, and deterministically orders conversations', () => {
    let state = createEmptyChatState();
    state = createConversation(state, 'zeta', T0, false);
    state = createConversation(state, 'alpha', T0, false);
    state = createConversation(state, 'recent', T1);

    expect(state.schemaVersion).toBe(CHAT_STATE_SCHEMA_VERSION);
    expect(state.conversationOrder).toEqual(['recent', 'alpha', 'zeta']);
    expect(state.selectedConversationId).toBe('recent');
    expect(selectOrderedConversations(state).map(item => item.id)).toEqual([
      'recent',
      'alpha',
      'zeta',
    ]);

    const selected = chatReducer(state, {
      type: 'conversation/select',
      payload: { id: 'alpha' },
    });
    expect(selected.selectedConversationId).toBe('alpha');
    expect(selected.conversationOrder).toEqual(state.conversationOrder);
    expect(
      chatReducer(selected, {
        type: 'conversation/select',
        payload: { id: 'missing' },
      }),
    ).toBe(selected);
  });

  test('auto-titles from the first user message and keeps manual titles', () => {
    let state = createConversation(createEmptyChatState(), 'chat', T0);
    state = appendUser(
      state,
      'chat',
      'u1',
      '  #   Plan   a local mobile DSH   ',
      T1,
    );
    expect(state.conversations.chat?.title).toBe('Plan a local mobile DSH');
    expect(state.conversations.chat?.titleSource).toBe('auto');

    state = chatReducer(state, {
      type: 'conversation/rename',
      payload: { id: 'chat', title: '  Mobile   proof  ', at: T2 },
    });
    state = appendUser(
      state,
      'chat',
      'u2',
      'This must not replace the title',
      T3,
    );
    expect(state.conversations.chat?.title).toBe('Mobile proof');
    expect(state.conversations.chat?.titleSource).toBe('manual');
  });

  test('derives Unicode-safe bounded automatic titles', () => {
    const source = Array.from({ length: 60 }, () => '深').join('');
    const title = deriveAutoTitle(source);
    expect(Array.from(title)).toHaveLength(48);
    expect(title.endsWith('…')).toBe(true);
    expect(deriveAutoTitle('  \n\t ')).toBe('New chat');
  });

  test('appends both roles, preserves metadata, and ignores duplicate ids', () => {
    let state = createConversation(createEmptyChatState(), 'chat', T0);
    state = appendUser(state, 'chat', 'm1', 'Hello', T1);
    const withAssistant = chatReducer(state, {
      type: 'message/append',
      payload: {
        conversationId: 'chat',
        message: {
          id: 'm2',
          role: 'assistant',
          text: 'Hi from the device',
          createdAt: T2,
          attachments: [],
          metadata: {
            modelId: 'deepseek-v4-pro',
            latencyMs: 412,
            finishReason: 'stop',
          },
        },
      },
    });
    expect(selectActiveMessages(withAssistant)).toHaveLength(2);
    expect(selectActiveMessages(withAssistant)[1]?.metadata).toEqual({
      modelId: 'deepseek-v4-pro',
      latencyMs: 412,
      finishReason: 'stop',
    });

    const duplicate = chatReducer(withAssistant, {
      type: 'message/append',
      payload: {
        conversationId: 'chat',
        message: {
          id: 'm2',
          role: 'assistant',
          text: 'duplicate',
          createdAt: T3,
          attachments: [],
        },
      },
    });
    expect(duplicate).toBe(withAssistant);
  });

  test('preserves legal message whitespace through serialization without accepting blanks', () => {
    let state = createConversation(createEmptyChatState(), 'chat', T0);
    state = appendUser(state, 'chat', 'm1', '  raw user text  ', T1);
    state = chatReducer(state, {
      type: 'message/append',
      payload: {
        conversationId: 'chat',
        message: {
          id: 'm2',
          role: 'assistant',
          text: '\nraw assistant text\t',
          createdAt: T2,
          attachments: [],
        },
      },
    });

    expect(
      state.conversations.chat?.messages.map(message => message.text),
    ).toEqual(['  raw user text  ', '\nraw assistant text\t']);
    expect(state.conversations.chat?.title).toBe('raw user text');
    expect(
      hydrateChatState(
        serializeChatState(state),
      ).conversations.chat?.messages.map(message => message.text),
    ).toEqual(['  raw user text  ', '\nraw assistant text\t']);

    const blankUser = appendUser(state, 'chat', 'm3', ' \n\t ', T3);
    const blankAssistant = chatReducer(state, {
      type: 'message/append',
      payload: {
        conversationId: 'chat',
        message: {
          id: 'm4',
          role: 'assistant',
          text: '\t  ',
          createdAt: T3,
          attachments: [],
        },
      },
    });
    expect(blankUser).toBe(state);
    expect(blankAssistant).toBe(state);
  });

  test('accepts an attachment-only user message and titles it from the file', () => {
    const state = createConversation(createEmptyChatState(), 'chat', T0);
    const next = appendUser(state, 'chat', 'm1', '', T1, [IMAGE_ATTACHMENT]);
    expect(next.conversations.chat?.messages[0]).toMatchObject({
      text: '',
      attachments: [IMAGE_ATTACHMENT],
    });
    expect(next.conversations.chat?.title).toBe('receipt.png');

    const blankAssistant = chatReducer(next, {
      type: 'message/append',
      payload: {
        conversationId: 'chat',
        message: {
          id: 'm2',
          role: 'assistant',
          text: '',
          createdAt: T2,
          attachments: [IMAGE_ATTACHMENT],
        },
      },
    });
    expect(blankAssistant).toBe(next);
  });

  test('titles a whitespace-only attachment message from the attachment name', () => {
    const state = createConversation(createEmptyChatState(), 'chat', T0);
    const next = appendUser(state, 'chat', 'm1', ' \n\t ', T1, [
      IMAGE_ATTACHMENT,
    ]);

    expect(next.conversations.chat?.messages[0]?.text).toBe(' \n\t ');
    expect(next.conversations.chat?.title).toBe('receipt.png');
  });

  test('bounds the preserved raw message length before serialization', () => {
    const state = createConversation(createEmptyChatState(), 'chat', T0);
    const boundary = `x${' '.repeat(MAX_CHAT_MESSAGE_LENGTH - 1)}`;
    const accepted = appendUser(state, 'chat', 'm1', boundary, T1);
    expect(accepted).not.toBe(state);
    expect(
      hydrateChatState(serializeChatState(accepted)).conversations.chat
        ?.messages[0]?.text,
    ).toBe(boundary);

    const overLimit = `${boundary} `;
    expect(appendUser(state, 'chat', 'm2', overLimit, T1)).toBe(state);
  });

  test('updates model and thinking per chat without moving on selection', () => {
    let state = createConversation(createEmptyChatState(), 'first', T0);
    state = createConversation(state, 'second', T1);
    state = chatReducer(state, {
      type: 'conversation/set-model',
      payload: { id: 'first', modelId: 'deepseek-v4-pro', at: T2 },
    });
    expect(state.conversations.first?.modelId).toBe('deepseek-v4-pro');
    expect(state.conversationOrder).toEqual(['first', 'second']);

    state = chatReducer(state, {
      type: 'conversation/set-thinking',
      payload: { id: 'first', thinkingMode: 'max', at: T3 },
    });
    expect(state.conversations.first?.thinkingMode).toBe('max');

    state = chatReducer(state, {
      type: 'conversation/select',
      payload: { id: 'second' },
    });
    expect(state.conversationOrder).toEqual(['first', 'second']);
    expect(selectActiveConversation(state)?.id).toBe('second');
  });

  test('creates, binds, and unbinds a conversation project', () => {
    let state = chatReducer(createEmptyChatState(), {
      type: 'conversation/create',
      payload: { id: 'chat', at: T0, projectId: 'project-a' },
    });
    expect(state.conversations.chat?.projectId).toBe('project-a');

    state = chatReducer(state, {
      type: 'conversation/bind-project',
      payload: { id: 'chat', projectId: 'project-b', at: T1 },
    });
    expect(state.conversations.chat?.projectId).toBe('project-b');
    expect(state.conversations.chat?.updatedAt).toBe(T1);

    state = chatReducer(state, {
      type: 'conversation/unbind-project',
      payload: { id: 'chat', at: T2 },
    });
    expect(state.conversations.chat?.projectId).toBeNull();
    expect(state.conversations.chat?.updatedAt).toBe(T2);

    const invalid = chatReducer(state, {
      type: 'conversation/bind-project',
      payload: { id: 'chat', projectId: '   ', at: T3 },
    });
    expect(invalid).toBe(state);
  });

  test('deletes conversations and selects the next most recent one', () => {
    let state = createConversation(createEmptyChatState(), 'oldest', T0);
    state = createConversation(state, 'middle', T1);
    state = createConversation(state, 'newest', T2);
    state = chatReducer(state, {
      type: 'conversation/delete',
      payload: { id: 'newest' },
    });
    expect(state.selectedConversationId).toBe('middle');
    expect(state.conversationOrder).toEqual(['middle', 'oldest']);

    state = chatReducer(state, {
      type: 'conversation/delete',
      payload: { id: 'oldest' },
    });
    expect(state.selectedConversationId).toBe('middle');
  });

  test('rejects malformed reducer inputs without changing state', () => {
    const state = createConversation(createEmptyChatState(), 'chat', T0);
    const invalidTimestamp = chatReducer(state, {
      type: 'conversation/rename',
      payload: { id: 'chat', title: 'Name', at: 'yesterday' },
    });
    const blankMessage = appendUser(state, 'chat', 'm1', '   ', T1);
    const duplicateConversation = createConversation(state, 'chat', T2);
    expect(invalidTimestamp).toBe(state);
    expect(blankMessage).toBe(state);
    expect(duplicateConversation).toBe(state);
  });
});

describe('schema v4 persistence', () => {
  function populatedState(): ChatState {
    let state = createConversation(createEmptyChatState(), 'chat-a', T0);
    state = chatReducer(state, {
      type: 'conversation/bind-project',
      payload: { id: 'chat-a', projectId: 'project-a', at: T0 },
    });
    state = appendUser(state, 'chat-a', 'u1', 'Local?', T1);
    state = chatReducer(state, {
      type: 'message/append',
      payload: {
        conversationId: 'chat-a',
        message: {
          id: 'a1',
          role: 'assistant',
          text: 'Local.',
          createdAt: T2,
          attachments: [],
          metadata: { modelId: 'deepseek-v4-flash', latencyMs: 585 },
        },
      },
    });
    state = createConversation(state, 'chat-b', T3);
    state = chatReducer(state, {
      type: 'conversation/select',
      payload: { id: 'chat-a' },
    });
    return state;
  }

  test('serializes deterministically with an active-message proof projection', () => {
    const state = populatedState();
    const first = serializeChatState(state);
    const second = serializeChatState(state);
    const decoded = JSON.parse(first) as PersistedChatStateV7;

    expect(first).toBe(second);
    expect(Object.keys(decoded).sort()).toEqual(
      [
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
      ].sort(),
    );
    expect(decoded.project_context_destructive_epoch).toBe(0);
    expect(decoded.project_context_destructive_transition).toBeNull();
    expect(decoded.schema_version).toBe(CHAT_STATE_SCHEMA_VERSION);
    expect(decoded.active_conversation_id).toBe('chat-a');
    expect(decoded.conversations.map(item => item.id)).toEqual([
      'chat-b',
      'chat-a',
    ]);
    expect(decoded.messages).toEqual(decoded.conversations[1]?.messages);
    expect(decoded.messages).toHaveLength(2);
    expect(decoded.conversations[1]?.project_id).toBe('project-a');
    expect(decoded.conversations[0]?.project_id).toBeNull();
  });

  test('round-trips every supported field', () => {
    const state = populatedState();
    const hydrated = hydrateChatState(serializeChatState(state));
    expect(hydrated).toEqual(state);
    expect(serializeChatState(hydrated)).toBe(serializeChatState(state));
  });

  test('round-trips attachment descriptors without persisting thumbnails', () => {
    let state = createConversation(createEmptyChatState(), 'chat', T0);
    state = appendUser(state, 'chat', 'u1', '', T1, [IMAGE_ATTACHMENT]);
    const serialized = serializeChatState(state);
    expect(serialized).not.toContain('thumbnail_data_url');
    expect(serialized).not.toContain('cHJldmlldw');

    const hydrated = hydrateChatState(serialized);
    expect(hydrated.conversations.chat?.messages[0]?.attachments).toEqual([
      {
        schema_version: 1,
        id: 'attachment-image-1',
        kind: 'image',
        name: 'receipt.png',
        mime_type: 'image/png',
        size: 2048,
      },
    ]);
    expect(serializeChatState(hydrated)).toBe(serialized);
  });

  test('deterministically migrates schema v2 conversations as unbound', () => {
    const legacy = JSON.parse(serializeChatState(populatedState())) as {
      schema_version: number;
      conversations: Array<Record<string, unknown>>;
      messages: Array<Record<string, unknown>>;
    };
    stripSchema9Fields(legacy);
    legacy.schema_version = 2;
    legacy.conversations.forEach(conversation => {
      delete conversation.project_id;
      delete conversation.thinking_mode;
      delete conversation.runtime_context_id;
      delete conversation.project_context;
      delete conversation.turns;
      delete conversation.attempts;
    });
    legacy.messages = (legacy.messages ?? []).map(message => {
      delete message.attachments;
      return message;
    });
    legacy.conversations.forEach(conversation => {
      (conversation.messages as Array<Record<string, unknown>>).forEach(
        message => delete message.attachments,
      );
    });

    const first = hydrateChatState(legacy);
    const second = hydrateChatState(JSON.stringify(legacy));
    expect(first).toEqual(second);
    expect(first.schemaVersion).toBe(CHAT_STATE_SCHEMA_VERSION);
    expect(first).toMatchObject({
      projectContextDestructiveEpoch: 0,
      projectContextDestructiveTransition: null,
    });
    expect(
      Object.values(first.conversations).every(
        conversation =>
          conversation.projectId === null &&
          conversation.thinkingMode === 'high',
      ),
    ).toBe(true);

    const migrated = JSON.parse(serializeChatState(first)) as {
      schema_version: number;
      conversations: Array<{ project_id?: unknown }>;
    };
    expect(migrated.schema_version).toBe(CHAT_STATE_SCHEMA_VERSION);
    expect(
      migrated.conversations.every(
        conversation => conversation.project_id === null,
      ),
    ).toBe(true);
  });

  test('deterministically migrates schema v3 messages with empty attachments', () => {
    const legacy = JSON.parse(serializeChatState(populatedState())) as {
      schema_version: number;
      messages: Array<Record<string, unknown>>;
      conversations: Array<{ messages: Array<Record<string, unknown>> }>;
    };
    stripSchema9Fields(legacy as unknown as Record<string, unknown>);
    legacy.schema_version = 3;
    legacy.messages.forEach(message => delete message.attachments);
    legacy.conversations.forEach(conversation =>
      conversation.messages.forEach(message => delete message.attachments),
    );
    legacy.conversations.forEach(conversation => {
      const row = conversation as unknown as Record<string, unknown>;
      delete row.runtime_context_id;
      delete row.project_context;
      delete row.turns;
      delete row.attempts;
    });

    const hydrated = hydrateChatState(legacy);
    expect(hydrated.schemaVersion).toBe(CHAT_STATE_SCHEMA_VERSION);
    expect(hydrated).toMatchObject({
      projectContextDestructiveEpoch: 0,
      projectContextDestructiveTransition: null,
    });
    expect(
      Object.values(hydrated.conversations).every(conversation =>
        conversation.messages.every(
          message => message.attachments.length === 0,
        ),
      ),
    ).toBe(true);
  });

  test('strictly validates the required v3 project_id field', () => {
    const missing = JSON.parse(serializeChatState(populatedState())) as {
      conversations: Array<Record<string, unknown>>;
    };
    delete missing.conversations[0]?.project_id;
    expect(() => hydrateChatState(missing)).toThrow(/project_id/);

    for (const invalidProjectId of ['', '   ', 'x'.repeat(257), 42]) {
      const invalid = JSON.parse(serializeChatState(populatedState())) as {
        conversations: Array<Record<string, unknown>>;
      };
      invalid.conversations[0]!.project_id = invalidProjectId;
      expect(() => hydrateChatState(invalid)).toThrow(/project_id/);
    }
  });

  test('hydrates old conversations without thinking_mode as high', () => {
    const decoded = JSON.parse(serializeChatState(populatedState())) as {
      schema_version: number;
      conversations: Array<{ thinking_mode?: string }>;
      messages: Array<Record<string, unknown>>;
    };
    stripSchema9Fields(decoded as unknown as Record<string, unknown>);
    decoded.schema_version = 2;
    delete decoded.conversations[0]?.thinking_mode;
    delete decoded.conversations[1]?.thinking_mode;
    decoded.conversations.forEach(conversation => {
      const row = conversation as unknown as Record<string, unknown>;
      delete row.project_id;
      delete row.runtime_context_id;
      delete row.project_context;
      delete row.turns;
      delete row.attempts;
    });
    decoded.messages.forEach(
      message => delete (message as Record<string, unknown>).attachments,
    );
    decoded.conversations.forEach(conversation => {
      const row = conversation as unknown as Record<string, unknown>;
      (row.messages as Array<Record<string, unknown>>).forEach(
        message => delete message.attachments,
      );
    });

    const hydrated = hydrateChatState(decoded);
    expect(
      Object.values(hydrated.conversations).every(
        conversation => conversation.thinkingMode === 'high',
      ),
    ).toBe(true);
  });

  test('persists Flash Vision Exp and rejects invalid thinking modes', () => {
    let state = createEmptyChatState();
    state = chatReducer(state, {
      type: 'conversation/create',
      payload: {
        id: 'vision',
        at: T0,
        modelId: 'deepseek-v4-flash-vision-exp',
        thinkingMode: 'off',
      },
    });
    const decoded = JSON.parse(serializeChatState(state)) as {
      conversations: Array<Record<string, unknown>>;
    };
    expect(decoded.conversations[0]?.model_id).toBe(
      'deepseek-v4-flash-vision-exp',
    );
    expect(decoded.conversations[0]?.thinking_mode).toBe('off');

    decoded.conversations[0]!.thinking_mode = 'medium';
    expect(() => hydrateChatState(decoded)).toThrow(/supported thinking mode/);
  });

  test('normalizes persisted conversation order using timestamps and ids', () => {
    const decoded = JSON.parse(
      serializeChatState(populatedState()),
    ) as unknown as {
      conversations: unknown[];
    };
    decoded.conversations.reverse();
    const hydrated = hydrateChatState(decoded);
    expect(hydrated.conversationOrder).toEqual(['chat-b', 'chat-a']);
  });

  test.each([
    ['invalid JSON', '{'],
    [
      'wrong schema',
      {
        schema_version: 1,
        active_conversation_id: null,
        conversations: [],
        messages: [],
      },
    ],
    [
      'missing projection',
      { schema_version: 4, active_conversation_id: null, conversations: [] },
    ],
    [
      'orphaned active id',
      {
        schema_version: 4,
        active_conversation_id: 'missing',
        conversations: [],
        messages: [],
      },
    ],
  ])('rejects %s', (_label, payload) => {
    expect(() => hydrateChatState(payload)).toThrow(ChatStateValidationError);
  });

  test('rejects duplicate conversations and unsupported models', () => {
    const valid = JSON.parse(serializeChatState(populatedState())) as {
      conversations: Record<string, unknown>[];
    };
    valid.conversations.push({ ...valid.conversations[0] });
    expect(() => hydrateChatState(valid)).toThrow(/must be unique/);

    const unsupported = JSON.parse(serializeChatState(populatedState())) as {
      conversations: Record<string, unknown>[];
    };
    unsupported.conversations[0]!.model_id = 'unknown-model';
    expect(() => hydrateChatState(unsupported)).toThrow(/supported model/);
  });

  test('rejects a stale or tampered active-message projection', () => {
    const decoded = JSON.parse(serializeChatState(populatedState())) as {
      messages: Array<{ text: string }>;
    };
    decoded.messages[0]!.text = 'tampered';
    expect(() => hydrateChatState(decoded)).toThrow(
      /must exactly mirror the active conversation/,
    );
  });

  test('rejects tampered attachment projections and invalid descriptors', () => {
    let state = createConversation(createEmptyChatState(), 'chat', T0);
    state = appendUser(state, 'chat', 'u1', '', T1, [IMAGE_ATTACHMENT]);

    const tampered = JSON.parse(serializeChatState(state)) as {
      messages: Array<{ attachments: Array<{ name: string }> }>;
    };
    tampered.messages[0]!.attachments[0]!.name = 'tampered.png';
    expect(() => hydrateChatState(tampered)).toThrow(
      /must exactly mirror the active conversation/,
    );

    for (const [field, value] of [
      ['id', ''],
      ['name', '   '],
      ['mime_type', 'not-a-mime'],
      ['size', -1],
      ['kind', 'audio'],
    ] as const) {
      const invalid = JSON.parse(serializeChatState(state)) as {
        conversations: Array<{
          messages: Array<{ attachments: Array<Record<string, unknown>> }>;
        }>;
      };
      invalid.conversations[0]!.messages[0]!.attachments[0]![field] = value;
      expect(() => hydrateChatState(invalid)).toThrow(
        new RegExp(String(field)),
      );
    }

    const duplicate = JSON.parse(serializeChatState(state)) as {
      conversations: Array<{
        messages: Array<{ attachments: Array<Record<string, unknown>> }>;
      }>;
    };
    const attachments = duplicate.conversations[0]!.messages[0]!.attachments;
    attachments.push({ ...attachments[0]! });
    expect(() => hydrateChatState(duplicate)).toThrow(
      /unique within the message/,
    );
  });

  test('returns typed validation failures without throwing', () => {
    const result = safeHydrateChatState('{bad json');
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.error).toBeInstanceOf(ChatStateValidationError);
      expect(result.error.path).toBe('$');
    }
  });
});

describe('schema-9 final Agent V3 contract', () => {
  const finalCall: PersistedAgentCallJournalV3 = {
    schema_version: 3,
    call_id: 'call-v3',
    call_index: 0,
    name: 'write_file',
    arguments_sha256: 'a'.repeat(64),
    safe_summary_key: 'agent.write_file',
    access: 'conversation_confirm',
    approval_token: 'approval-v3-token',
    approval_decision: 'pending',
    approval_reference: null,
    idempotency_key: null,
    native_row_revision: null,
    receipt: null,
  };

  test('uses the journal registry version for persisted CGI approval policy', () => {
    for (const name of ['start_guest_cgi', 'stop_guest_cgi']) {
      const cgi = {...finalCall, name, safe_summary_key: `agent.${name}`};
      expect(parsePersistedAgentCallJournalV3(cgi, '$', 2)).toEqual(cgi);
      expect(() => parsePersistedAgentCallJournalV3(cgi, '$', 1)).toThrow(/registered tool policy/);
      expect(() => parsePersistedAgentCallJournalV3({...cgi, access: 'auto'}, '$', 2)).toThrow(/registered tool policy/);
      const legacy = {...cgi, access: 'durable_deny', safe_summary_key: 'agent.unknown', approval_token: null, approval_decision: 'denied'};
      expect(parsePersistedAgentCallJournalV3(legacy, '$', 1).access).toBe('durable_deny');
    }
    expect(() => parsePersistedAgentCallJournalV3({...finalCall, name: 'unknown_service'}, '$', 2)).toThrow(/registered tool policy/);
  });

  test('keeps v1/v2 sessions readable while allowing runtime calls only in v3', () => {
    const names = ['list_runtime_environments', 'install_runtime_environment', 'run_program', 'start_runtime_service', 'stop_runtime_service'];
    for (const name of names) {
      const runtime = { ...finalCall, name, safe_summary_key: `agent.${name}`,
        ...(name === 'list_runtime_environments' ? { access: 'auto', approval_token: null } : {}),
      };
      expect(parsePersistedAgentCallJournalV3(runtime, '$', 3)).toEqual(runtime);
      for (const version of [1, 2] as const) {
        expect(() => parsePersistedAgentCallJournalV3(runtime, '$', version)).toThrow(/registered tool policy/);
        expect(parsePersistedAgentCallJournalV3(finalCall, '$', version)).toEqual(finalCall);
        const oldDenial = { ...runtime, access: 'durable_deny', safe_summary_key: 'agent.unknown', approval_token: null, approval_decision: 'denied' };
        expect(parsePersistedAgentCallJournalV3(oldDenial, '$', version).access).toBe('durable_deny');
      }
    }
  });

  test('accepts an opaque final token and rejects a structured token object', () => {
    expect(parsePersistedAgentCallJournalV3(finalCall)).toEqual(finalCall);
    expect(() =>
      parsePersistedAgentCallJournalV3({
        ...finalCall,
        approval_token: { schema_version: 1 },
      }),
    ).toThrow(/approval_token/);
  });

  test('classifies a legacy live object as cancelled, non-authority history', () => {
    const legacy = {
      schema_version: 1 as const,
      controller_cas: {
        schema_version: 1 as const,
        conversation_id: 'conversation-v3',
        task_id: '11111111-1111-4111-8111-111111111111',
        attempt_id: '22222222-2222-4222-8222-222222222222',
        expected_controller_generation: 0,
        expected_journal_revision: 1,
        expected_session_generation: 1,
        expected_session_sha256: 'b'.repeat(64),
      },
      round_id: '33333333-3333-4333-8333-333333333333',
      round_index: 0,
      batch_call_ids: ['call-v3'],
      batch_arguments_sha256: ['a'.repeat(64)],
      call_index: 0,
      call_id: 'call-v3',
      name: 'write_file',
      access: 'conversation_confirm' as const,
      arguments_sha256: 'a'.repeat(64),
      root_fingerprint_sha256: 'c'.repeat(64),
      binding_revision: 1,
      policy_version: 'agent-v1',
      registry_version: 1 as const,
      allowed_decisions: [
        'denied',
        'allow_once',
        'allow_conversation',
        'cancelled',
      ] as const,
    };
    const migrated = migrateAgentApprovalTokenV3(legacy, 'allow_once', {
      call_id: 'call-v3',
      call_index: 0,
      name: 'write_file',
      access: 'conversation_confirm',
      arguments_sha256: 'a'.repeat(64),
    });
    expect(migrated.status).toBe('needs_reprepare');
    expect(migrated.decision).toBe('cancelled');
    expect(migrated.approval_token).toBeNull();
    expect(migrated.historical_decision).toBe('allow_once');
    const call = {
      call_id: 'call-v3',
      call_index: 0,
      name: 'write_file',
      access: 'conversation_confirm' as const,
      arguments_sha256: 'a'.repeat(64),
    };
    const containingCAS = legacy.controller_cas;
    const casMismatches: readonly [string, unknown][] = [
      ['conversation_id', 'other-conversation'],
      ['expected_journal_revision', 2],
      ['expected_session_generation', 2],
      ['expected_session_sha256', 'c'.repeat(64)],
    ];
    for (const [field, value] of casMismatches) {
      expect(() =>
        migrateAgentApprovalTokenV3(legacy, 'allow_once', call, {
          ...containingCAS,
          [field]: value,
        }),
      ).toThrow(/complete containing controller CAS/);
    }
  });

  test('hydrates legacy live approvals as terminal inert calls for stable V3 round-trips', () => {
    const legacyToken = {
      schema_version: 1 as const,
      controller_cas: {
        schema_version: 1 as const,
        conversation_id: 'conversation-v3',
        task_id: '11111111-1111-4111-8111-111111111111',
        attempt_id: '22222222-2222-4222-8222-222222222222',
        expected_controller_generation: 0,
        expected_journal_revision: 1,
        expected_session_generation: 1,
        expected_session_sha256: 'b'.repeat(64),
      },
      round_id: '33333333-3333-4333-8333-333333333333',
      round_index: 0,
      batch_call_ids: ['call-v3'],
      batch_arguments_sha256: ['a'.repeat(64)],
      call_index: 0,
      call_id: 'call-v3',
      name: 'write_file',
      access: 'conversation_confirm' as const,
      arguments_sha256: 'a'.repeat(64),
      root_fingerprint_sha256: 'c'.repeat(64),
      binding_revision: 1,
      policy_version: 'agent-v1',
      registry_version: 1 as const,
      allowed_decisions: [
        'denied',
        'allow_once',
        'allow_conversation',
        'cancelled',
      ] as const,
    };
    const raw = {
      schema_version: 2,
      phase: 'approval_pending',
      controller_generation: 1,
      policy: {
        schema_version: 1,
        policy_version: 'agent-v1',
        max_single_write_bytes: 32768,
        max_batch_write_bytes: 32768,
        max_attempt_write_bytes: 32768,
      },
      root: {
        schema_version: 1,
        kind: 'project',
        workspace_id: '11111111-1111-4111-8111-111111111111',
        workspace_binding_revision: 1,
        project_id: '22222222-2222-4222-8222-222222222222',
        root_fingerprint_sha256: 'c'.repeat(64),
        capabilities: ['file_read', 'file_write'],
      },
      tool_registry_version: 1,
      toolset_sha256: 'd'.repeat(64),
      transcript: {
        schema_version: 1,
        transcript_ref: '44444444-4444-4444-8444-444444444444',
        generation: 0,
        transcript_sha256: 'e'.repeat(64),
        transcript_bytes: 0,
      },
      round_index: 0,
      round_lineage: {
        schema_version: 2,
        round_id: legacyToken.round_id,
        round_index: 0,
        launch_attempt: 1,
        status: 'completed',
        native_row_revision: 2,
      },
      call_index: 0,
      batch: [
        {
          schema_version: 2,
          call_id: 'call-v3',
          call_index: 0,
          name: 'write_file',
          arguments_sha256: 'a'.repeat(64),
          safe_summary_key: 'agent.write_file',
          access: 'conversation_confirm',
          approval_token: legacyToken,
          approval_decision: 'allow_once',
          approval_reference: null,
          idempotency_key: null,
          native_row_revision: null,
          receipt: null,
        },
      ],
      frozen_grant_ids: [],
      reserved_write_bytes: 0,
      updated_at: T0,
    };
    const hydrated = parsePersistedAgentAttemptJournalV3(raw);
    expect(hydrated.schema_version).toBe(3);
    expect(hydrated.phase).toBe('cancelled');
    expect(hydrated.round_lineage?.status).toBe('completed');
    expect(hydrated.batch[0]).toMatchObject({
      schema_version: 3,
      approval_token: null,
      approval_decision: 'cancelled',
      approval_reference: null,
    });
    expect(() =>
      parsePersistedAgentAttemptJournalV3(raw, '$', {
        taskId: legacyToken.controller_cas.task_id,
        attemptId: legacyToken.controller_cas.attempt_id,
        controllerCAS: legacyToken.controller_cas,
      }),
    ).not.toThrow();
    const legacyBindingMismatches: readonly [
      string,
      (token: Record<string, unknown>) => void,
    ][] = [
      ['round', token => { token.round_id = '99999999-9999-4999-8999-999999999999'; }],
      ['root', token => { token.root_fingerprint_sha256 = 'f'.repeat(64); }],
      ['binding', token => { token.binding_revision = 2; }],
      ['policy', token => { token.policy_version = 'other-policy'; }],
      ['registry', token => { token.registry_version = 2; }],
      ['complete batch', token => {
        token.batch_call_ids = ['call-v3', 'call-other'];
        token.batch_arguments_sha256 = ['a'.repeat(64), 'b'.repeat(64)];
      }],
    ];
    for (const [label, mutate] of legacyBindingMismatches) {
      const candidate = JSON.parse(JSON.stringify(raw)) as {
        batch: Array<{ approval_token: Record<string, unknown> }>;
      };
      mutate(candidate.batch[0]!.approval_token);
      expect(() => parsePersistedAgentAttemptJournalV3(candidate)).toThrow(
        label === 'registry' ? /registry_version|schema_version/ : /complete journal authority/,
      );
    }
    const legacyStore = createChatStore({ now: () => T0 });
    const legacyConversationId = legacyStore.createConversation();
    legacyStore.prepareTurnAttempt(legacyConversationId, 'legacy live');
    const legacyRoot = JSON.parse(legacyStore.serialize()) as {
      conversations: Array<Record<string, unknown>>;
    };
    const legacyConversation = legacyRoot.conversations[0]!;
    const legacyAttempt = (legacyConversation.attempts as Array<Record<string, unknown>>)[0];
    if (legacyAttempt === undefined) throw new Error('legacy attempt fixture missing');
    const legacyRootJournal = JSON.parse(JSON.stringify(raw)) as Record<string, unknown>;
    const roundTripLegacyToken = (
      (legacyRootJournal.batch as Array<Record<string, unknown>>)[0]!
        .approval_token as Record<string, unknown>
    );
    const legacyControllerCas = roundTripLegacyToken.controller_cas as Record<string, unknown>;
    legacyControllerCas.conversation_id = legacyConversation.id;
    legacyControllerCas.task_id = legacyAttempt.turn_id;
    legacyControllerCas.attempt_id = legacyAttempt.attempt_id;
    const legacyJournalRoot = legacyRootJournal.root as Record<string, unknown>;
    legacyJournalRoot.kind = 'workspace';
    legacyJournalRoot.workspace_id = '11111111-1111-4111-8111-111111111111';
    legacyJournalRoot.project_id = null;
    legacyJournalRoot.capabilities = ['file_read'];
    legacyConversation.workspace_id = '11111111-1111-4111-8111-111111111111';
    legacyConversation.workspace_binding = {
      schema_version: 1,
      workspace_id: '11111111-1111-4111-8111-111111111111',
      binding_revision: 1,
      project_id: null,
    };
    legacyConversation.workspace_bootstrap_state = 'none';
    legacyAttempt.workspace_id = '11111111-1111-4111-8111-111111111111';
    legacyAttempt.workspace_binding_revision = 1;
    legacyAttempt.status = 'cancelled';
    legacyAttempt.active_round = null;
    legacyAttempt.failure_code = null;
    legacyAttempt.assistant_message_id = null;
    legacyAttempt.journal_revision = 2;
    legacyAttempt.agent = legacyRootJournal;
    const legacyNativeEnvelope = {
      schema_version: 1 as const,
      journal_revision: 1,
      session_generation: 1,
      session_sha256: 'b'.repeat(64),
    };
    const migratedRoot = hydrateChatState(legacyRoot, {
      nativeEnvelope: legacyNativeEnvelope,
    });
    const persistedMigratedRoot = serializeChatState(migratedRoot);
    const restoredMigratedRoot = hydrateChatState(persistedMigratedRoot, {
      nativeEnvelope: legacyNativeEnvelope,
    });
    expect(restoredMigratedRoot.conversations).toEqual(
      migratedRoot.conversations,
    );
    expect(serializeChatState(restoredMigratedRoot)).toBe(persistedMigratedRoot);
    const persistedCASMismatches: readonly [
      string,
      (cas: Record<string, unknown>) => void,
    ][] = [
      ['conversation', cas => { cas.conversation_id = 'other-conversation'; }],
      ['task', cas => { cas.task_id = '99999999-9999-4999-8999-999999999999'; }],
      ['attempt', cas => { cas.attempt_id = '99999999-9999-4999-8999-999999999998'; }],
      ['journal', cas => { cas.expected_journal_revision = 2; }],
      ['session generation', cas => { cas.expected_session_generation = 2; }],
      ['session digest', cas => { cas.expected_session_sha256 = 'c'.repeat(64); }],
    ];
    for (const [, mutate] of persistedCASMismatches) {
      const candidate = JSON.parse(JSON.stringify(legacyRoot)) as {
        conversations: Array<{ attempts: Array<{ agent: { batch: Array<Record<string, unknown>> } }> }>;
      };
      const token = candidate.conversations[0]!.attempts[0]!.agent.batch[0]!
        .approval_token as Record<string, unknown>;
      mutate(token.controller_cas as Record<string, unknown>);
      expect(() => hydrateChatState(candidate, { nativeEnvelope: legacyNativeEnvelope })).toThrow(
        /complete journal authority/,
      );
    }
  });

  test('never hydrates a runtime V2 token without native revalidation', () => {
    const runtimeToken = {
      schema_version: 2,
      token: '55555555-5555-4555-8555-555555555555',
      controller_cas: {
        schema_version: 1,
        conversation_id: 'conversation-v3',
        task_id: '11111111-1111-4111-8111-111111111111',
        attempt_id: '22222222-2222-4222-8222-222222222222',
        expected_controller_generation: 0,
        expected_journal_revision: 1,
        expected_session_generation: 1,
        expected_session_sha256: 'b'.repeat(64),
      },
      task_id: '11111111-1111-4111-8111-111111111111',
      attempt_id: '22222222-2222-4222-8222-222222222222',
      round_id: '33333333-3333-4333-8333-333333333333',
      round_index: 0,
      batch_call_ids: ['call-v3'],
      batch_arguments_sha256: ['a'.repeat(64)],
      batch_revision: 1,
      manifest_sha256: 'c'.repeat(64),
      call_index: 0,
      call_id: 'call-v3',
      name: 'write_file',
      arguments_sha256: 'a'.repeat(64),
      idempotency_key: 'd'.repeat(64),
      root_fingerprint_sha256: 'e'.repeat(64),
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
    };
    expect(() =>
      migrateAgentApprovalTokenV3(runtimeToken, 'allow_once', {
        call_id: 'call-v3',
        call_index: 0,
        name: 'write_file',
        access: 'conversation_confirm',
        arguments_sha256: 'a'.repeat(64),
      }),
    ).not.toThrow();
    const migration = migrateAgentApprovalTokenV3(runtimeToken, 'allow_once', {
      call_id: 'call-v3',
      call_index: 0,
      name: 'write_file',
      access: 'conversation_confirm',
      arguments_sha256: 'a'.repeat(64),
    });
    expect(migration.approval_token).toBeNull();
    expect(migration.status).toBe('needs_reprepare');
  });

  test.each([
    [
      'controller task',
      (token: Record<string, unknown>) => {
        token.controller_cas = {
          ...(token.controller_cas as Record<string, unknown>),
          task_id: '99999999-9999-4999-8999-999999999999',
        };
      },
    ],
    [
      'token task',
      (token: Record<string, unknown>) => {
        token.task_id = '99999999-9999-4999-8999-999999999999';
      },
    ],
    [
      'idempotency digest',
      (token: Record<string, unknown>) => {
        token.idempotency_key = 'not-a-sha256';
      },
    ],
    [
      'manifest digest',
      (token: Record<string, unknown>) => {
        token.manifest_sha256 = 'not-a-sha256';
      },
    ],
  ])(
    'rejects a runtime V2 source with a wrong %s binding',
    (_label, mutate) => {
      const token: Record<string, unknown> = {
        schema_version: 2,
        token: '55555555-5555-4555-8555-555555555555',
        controller_cas: {
          schema_version: 1,
          conversation_id: 'conversation-v3',
          task_id: '11111111-1111-4111-8111-111111111111',
          attempt_id: '22222222-2222-4222-8222-222222222222',
          expected_controller_generation: 0,
          expected_journal_revision: 1,
          expected_session_generation: 1,
          expected_session_sha256: 'b'.repeat(64),
        },
        task_id: '11111111-1111-4111-8111-111111111111',
        attempt_id: '22222222-2222-4222-8222-222222222222',
        round_id: '33333333-3333-4333-8333-333333333333',
        round_index: 0,
        batch_call_ids: ['call-v3'],
        batch_arguments_sha256: ['a'.repeat(64)],
        batch_revision: 1,
        manifest_sha256: 'c'.repeat(64),
        call_index: 0,
        call_id: 'call-v3',
        name: 'write_file',
        arguments_sha256: 'a'.repeat(64),
        idempotency_key: 'd'.repeat(64),
        root_fingerprint_sha256: 'e'.repeat(64),
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
      };
      mutate(token);
      expect(() =>
        migrateAgentApprovalTokenV3(token, 'allow_once', {
          call_id: 'call-v3',
          call_index: 0,
          name: 'write_file',
          access: 'conversation_confirm',
          arguments_sha256: 'a'.repeat(64),
        }),
      ).toThrow();
    },
  );

  test('rejects schema-2 Agent journals during serialization instead of flattening them', () => {
    const store = createChatStore({ now: () => T0 });
    const conversationId = store.createConversation();
    const prepared = store.prepareTurnAttempt(
      conversationId,
      'legacy journal',
    )!;
    const state = store.getState();
    const conversation = state.conversations[conversationId]!;
    const legacyJournal = {
      schema_version: 2,
      phase: 'ready_for_round',
      controller_generation: 0,
      policy: {
        schema_version: 1,
        policy_version: 'agent-v1',
        max_single_write_bytes: 32768,
        max_batch_write_bytes: 32768,
        max_attempt_write_bytes: 32768,
      },
      root: {
        schema_version: 1,
        kind: 'project',
        workspace_id: '11111111-1111-4111-8111-111111111111',
        workspace_binding_revision: 1,
        project_id: '22222222-2222-4222-8222-222222222222',
        root_fingerprint_sha256: 'a'.repeat(64),
        capabilities: ['file_read'],
      },
      tool_registry_version: 1,
      toolset_sha256: 'b'.repeat(64),
      transcript: {
        schema_version: 1,
        transcript_ref: '33333333-3333-4333-8333-333333333333',
        generation: 0,
        transcript_sha256: 'c'.repeat(64),
        transcript_bytes: 0,
      },
      round_index: 0,
      round_lineage: null,
      call_index: null,
      batch: [],
      frozen_grant_ids: [],
      reserved_write_bytes: 0,
      updated_at: T0,
    };
    const mutated = {
      ...state,
      conversations: {
        ...state.conversations,
        [conversationId]: {
          ...conversation,
          attempts: [
            {
              ...prepared,
              journalRevision: 1,
              agent: legacyJournal,
            },
          ],
        },
      },
    } as unknown as ChatState;
    expect(() => serializeChatState(mutated)).toThrow(
      /schema-2 Agent journals/,
    );
  });
});

describe('schema 9 Agent journal persistence', () => {
  const UUID_A = '11111111-1111-4111-8111-111111111111';
  const UUID_B = '22222222-2222-4222-8222-222222222222';
  const UUID_C = '33333333-3333-4333-8333-333333333333';
  const UUID_D = '55555555-5555-4555-8555-555555555555';

  /** Build a closed prepare projection for a schema-9 journal candidate. */
  const prepareEvidence = (
    cas: AgentControllerCASV1,
    journal: PersistedAgentAttemptJournalV3,
  ): AgentStoreTransitionEvidence => {
    const operationId = '66666666-6666-4666-8666-666666666660';
    const request = {
      schema_version: 2 as const,
      operation_id: operationId,
      controller_cas: cas,
      committed_checkpoint: {
        schema_version: 1 as const,
        journal_revision: cas.expected_journal_revision,
        session_generation: cas.expected_session_generation,
        session_sha256: cas.expected_session_sha256,
      },
      task_id: cas.task_id,
      conversation_id: cas.conversation_id,
      attempt_id: cas.attempt_id,
      workspace_id: journal.root.workspace_id,
      project_id: journal.root.project_id,
      workspace_binding_revision: journal.root.workspace_binding_revision,
      transport_schema_version: 2 as const,
      model: 'deepseek-v4-flash' as const,
      thinking_mode: 'high' as const,
      visible_message_ids: [],
      visible_history_sha256: 'f'.repeat(64),
      visible_message_count: 0,
      project_context_sha256: null,
      registry_version: 1 as const,
      expected_policy_version: journal.policy.policy_version,
      expected_transcript: null,
    };
    const registry = {
      schema_version: 2 as const,
      registry_version: 1 as const,
      toolset_sha256: journal.toolset_sha256,
      tools: journal.batch.map(call => ({
        schema_version: 2 as const,
        name: call.name,
        safe_summary_key: call.safe_summary_key,
        access: call.access,
      })),
    };
    const batch = journal.batch.map(call => ({
      schema_version: 2 as const,
      call_index: call.call_index,
      call_id: call.call_id,
      name: call.name,
      arguments_sha256: call.arguments_sha256,
      idempotency_key: call.idempotency_key,
      safe_summary_key: call.safe_summary_key,
      access: call.access,
      approval_state:
        call.access === 'auto'
          ? 'not_required' as const
          : call.access === 'durable_deny'
            ? 'denied' as const
            : call.approval_decision === 'pending'
              ? 'pending' as const
              : call.approval_decision === 'denied'
                ? 'denied' as const
                : call.approval_decision === 'cancelled'
                  ? 'cancelled' as const
                  : 'bound' as const,
      approval_token:
        call.approval_token === null
          ? null
          : {
              schema_version: 2 as const,
              token: call.approval_token,
              controller_cas: cas,
              task_id: cas.task_id,
              attempt_id: cas.attempt_id,
              round_id: journal.round_lineage?.round_id ?? UUID_D,
              round_index: journal.round_index,
              batch_call_ids: journal.batch.map(item => item.call_id),
              batch_arguments_sha256: journal.batch.map(item => item.arguments_sha256),
              batch_revision: 1,
              manifest_sha256: 'a'.repeat(64),
              call_index: call.call_index,
              call_id: call.call_id,
              name: call.name,
              arguments_sha256: call.arguments_sha256,
              idempotency_key: call.idempotency_key ?? 'b'.repeat(64),
              root_fingerprint_sha256: journal.root.root_fingerprint_sha256,
              binding_revision: journal.root.workspace_binding_revision,
              policy_version: 'agent-v1' as const,
              registry_version: 1 as const,
              access:
                call.access === 'confirm_once'
                  ? 'confirm_once' as const
                  : 'conversation_confirm' as const,
              allowed_decisions:
                call.access === 'confirm_once'
                  ? ['denied', 'allow_once', 'cancelled'] as const
                  : ['denied', 'allow_once', 'allow_conversation', 'cancelled'] as const,
            },
      approval_reference: call.approval_reference,
      execution_status:
        call.receipt === null
          ? 'not_started' as const
          : call.receipt.outcome === 'ok'
            ? 'completed' as const
            : call.receipt.outcome,
      execution_revision: call.receipt === null ? null : call.native_row_revision,
      native_row_revision: call.native_row_revision,
      receipt: call.receipt,
    }));
    const result = {
      schema_version: 2 as const,
      status: 'prepared' as const,
      operation_id: operationId,
      attempt: {
        schema_version: 2 as const,
        task_id: cas.task_id,
        conversation_id: cas.conversation_id,
        attempt_id: cas.attempt_id,
        phase: journal.phase,
        controller_generation: journal.controller_generation,
        journal_revision: cas.expected_journal_revision,
        authority_revision: journal.round_lineage?.native_row_revision ?? 0,
        root: journal.root,
        policy: journal.policy,
        registry,
        transcript: journal.transcript,
        round_index: journal.round_index,
        round_id: journal.round_lineage?.round_id ?? null,
        round_revision: journal.round_lineage?.native_row_revision ?? null,
        round_status: journal.round_lineage?.status ?? null,
        batch_kind:
          journal.batch.length === 0
            ? null
            : journal.batch.some(call => call.access !== 'auto')
              ? 'write_batch' as const
              : 'read_only_batch' as const,
        batch_revision: journal.batch.length === 0 ? null : 1,
        manifest_sha256: journal.batch.length === 0 ? null : 'a'.repeat(64),
        call_index: journal.call_index,
        batch,
        frozen_grant_ids: journal.frozen_grant_ids,
        reserved_write_bytes: journal.reserved_write_bytes,
        cancel_source_event_id: null,
        cleanup_id: null,
      },
      observed_checkpoint: {
        schema_version: 1 as const,
        journal_revision: cas.expected_journal_revision,
        session_generation: cas.expected_session_generation,
        session_sha256: cas.expected_session_sha256,
      },
    };
    const mapped = validateAgentStoreTransition({
      operation: 'prepare_agent_attempt',
      request,
      result,
    });
    if (mapped === null) throw new Error('invalid test Agent evidence');
    return mapped;
  };

  const completeEvidence = (
    cas: AgentControllerCASV1,
    current: PersistedAgentAttemptJournalV3,
    next: PersistedAgentAttemptJournalV3,
    outcomeKind: 'in_flight' | 'tool_batch' | 'blocked' | 'final',
    finalReasoning = 'checked atomically',
  ): AgentStoreTransitionEvidence => {
    const operationId = '66666666-6666-4666-8666-666666666661';
    const lineage = current.round_lineage;
    if (lineage === null) throw new Error('test evidence requires round lineage');
    const request = {
      schema_version: 2 as const,
      operation_id: operationId,
      controller_cas: cas,
      committed_checkpoint: {
        schema_version: 1 as const,
        journal_revision: cas.expected_journal_revision,
        session_generation: cas.expected_session_generation,
        session_sha256: cas.expected_session_sha256,
      },
      task_id: cas.task_id,
      conversation_id: cas.conversation_id,
      attempt_id: cas.attempt_id,
      round_id: lineage.round_id,
      round_index: lineage.round_index,
      launch_attempt: lineage.launch_attempt,
      expected_round_revision: lineage.native_row_revision ?? 0,
      transport_schema_version: 2 as const,
      model: 'deepseek-v4-flash' as const,
      thinking_mode: 'high' as const,
      visible_history_sha256: 'f'.repeat(64),
      visible_message_count: 0,
      project_context_sha256: null,
      transcript: current.transcript,
      root: current.root,
      registry_version: 1 as const,
      toolset_sha256: current.toolset_sha256,
    };
    if (outcomeKind === 'in_flight') {
      const result = {
        schema_version: 2 as const,
        status: 'in_flight' as const,
        operation_id: operationId,
        task_id: cas.task_id,
        attempt_id: cas.attempt_id,
        round_id: lineage.round_id,
        round_index: lineage.round_index,
        launch_attempt: lineage.launch_attempt,
        result_round_revision: (lineage.native_row_revision ?? 0) + 1,
        transcript: current.transcript,
      };
      const mapped = validateAgentStoreTransition({
        operation: 'complete_agent_round_v2',
        request,
        result,
      });
      if (mapped === null) throw new Error('invalid in-flight test Agent evidence');
      return mapped;
    }
    const blocked = outcomeKind === 'blocked';
    const final = outcomeKind === 'final';
    const receipt = {
      schema_version: 2 as const,
      transport_schema_version: 2 as const,
      turn_id: cas.task_id,
      task_id: cas.task_id,
      attempt_id: cas.attempt_id,
      round_id: lineage.round_id,
      round_index: lineage.round_index,
      provider_request_id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      provider_response_id: blocked
        ? 'resp-blocked'
        : final
          ? 'resp-final'
          : 'resp-tool-batch',
      requested_model: 'deepseek-v4-flash' as const,
      model: 'deepseek-v4-flash' as const,
      thinking_mode: 'high' as const,
      finish_reason: blocked
        ? 'length' as const
        : final
          ? 'stop' as const
          : 'tool_calls' as const,
      latency_ms: 1,
      visible_history_sha256: 'f'.repeat(64),
      model_input_sha256: '1'.repeat(64),
      request_body_sha256: '2'.repeat(64),
      project_context_receipt: null,
    };
    const outcome = blocked
      ? {
          schema_version: 3 as const,
          kind: 'blocked' as const,
          finish_reason: 'length' as const,
          completion_receipt: receipt,
          transcript: next.transcript,
          failure_code: 'E_COMPLETION_LENGTH' as const,
        }
      : final
        ? {
            schema_version: 3 as const,
            kind: 'final' as const,
            finish_reason: 'stop' as const,
            completion_receipt: receipt,
            transcript: next.transcript,
            text: 'atomic final',
            reasoning: finalReasoning,
          }
        : {
          schema_version: 3 as const,
          kind: 'tool_batch' as const,
          finish_reason: 'tool_calls' as const,
          completion_receipt: receipt,
          transcript: next.transcript,
          calls: next.batch.map(call => ({
            schema_version: 3 as const,
            call_index: call.call_index,
            call_id: call.call_id,
            name: call.name,
            arguments_sha256: call.arguments_sha256,
            safe_summary_key: call.safe_summary_key,
            access: call.access === 'durable_deny' ? 'durable_deny' as const : call.access,
            approval_state: call.access === 'durable_deny' ? 'durable_denied' as const : 'deferred' as const,
          })),
          batch_class: 'executable' as const,
          executable_call_count: next.batch.length,
          denied_call_count: 0,
          reasoning: '',
        };
    const result = {
      schema_version: 2 as const,
      status: 'completed' as const,
      operation_id: operationId,
      task_id: cas.task_id,
      attempt_id: cas.attempt_id,
      round_id: lineage.round_id,
      round_index: lineage.round_index,
      launch_attempt: lineage.launch_attempt,
      result_round_revision: next.round_lineage?.native_row_revision ?? 1,
      transcript: next.transcript,
      outcome,
    };
    const mapped = validateAgentStoreTransition({
      operation: 'complete_agent_round_v2',
      request,
      result,
    });
    if (mapped === null) throw new Error('invalid completed test Agent evidence');
    return mapped;
  };

  const preparedBatchEvidence = (
    cas: AgentControllerCASV1,
    current: PersistedAgentAttemptJournalV3,
    next: PersistedAgentAttemptJournalV3,
  ): AgentStoreTransitionEvidence => {
    const operationId = '66666666-6666-4666-8666-666666666664';
    const lineage = current.round_lineage;
    if (lineage === null || lineage.native_row_revision === null) {
      throw new Error('test batch evidence requires completed round lineage');
    }
    const manifestSha256 = 'a'.repeat(64);
    const callIds = next.batch.map(call => call.call_id);
    const argumentDigests = next.batch.map(call => call.arguments_sha256);
    const batchRevision = 1;
    const calls = next.batch.map(call => ({
      schema_version: 2 as const,
      call_index: call.call_index,
      call_id: call.call_id,
      name: call.name,
      arguments_sha256: call.arguments_sha256,
      idempotency_key: call.idempotency_key,
      safe_summary_key: call.safe_summary_key,
      access: call.access,
      approval_state:
        call.access === 'auto'
          ? 'not_required' as const
          : call.access === 'durable_deny'
            ? 'denied' as const
            : 'pending' as const,
      approval_token:
        call.approval_token === null
          ? null
          : {
              schema_version: 2 as const,
              token: call.approval_token,
              controller_cas: cas,
              task_id: cas.task_id,
              attempt_id: cas.attempt_id,
              round_id: lineage.round_id,
              round_index: lineage.round_index,
              batch_call_ids: callIds,
              batch_arguments_sha256: argumentDigests,
              batch_revision: batchRevision,
              manifest_sha256: manifestSha256,
              call_index: call.call_index,
              call_id: call.call_id,
              name: call.name,
              arguments_sha256: call.arguments_sha256,
              idempotency_key: call.idempotency_key!,
              root_fingerprint_sha256: current.root.root_fingerprint_sha256,
              binding_revision: current.root.workspace_binding_revision,
              policy_version: 'agent-v1' as const,
              registry_version: current.tool_registry_version,
              access: call.access === 'confirm_once'
                ? 'confirm_once' as const
                : 'conversation_confirm' as const,
              allowed_decisions: call.access === 'confirm_once'
                ? ['denied', 'allow_once', 'cancelled'] as const
                : ['denied', 'allow_once', 'allow_conversation', 'cancelled'] as const,
            },
      approval_reference: call.approval_reference,
      execution_status: call.access === 'durable_deny'
        ? 'denied' as const
        : 'intent' as const,
      execution_revision: call.access === 'durable_deny'
        ? null
        : 1,
      native_row_revision: call.native_row_revision,
      receipt: call.receipt,
    }));
    const request = {
      schema_version: 2 as const,
      operation_id: operationId,
      controller_cas: cas,
      committed_checkpoint: {
        schema_version: 1 as const,
        journal_revision: cas.expected_journal_revision,
        session_generation: cas.expected_session_generation,
        session_sha256: cas.expected_session_sha256,
      },
      task_id: cas.task_id,
      conversation_id: cas.conversation_id,
      attempt_id: cas.attempt_id,
      round_id: lineage.round_id,
      round_index: lineage.round_index,
      expected_round_revision: lineage.native_row_revision,
      transcript: current.transcript,
      root: current.root,
      registry_version: current.tool_registry_version,
      toolset_sha256: current.toolset_sha256,
      policy_version: 'agent-v1' as const,
      expected_batch_revision: 0,
      expected_reserved_write_bytes: current.reserved_write_bytes,
    };
    const result = {
      schema_version: 2 as const,
      status: 'prepared' as const,
      operation_id: operationId,
      receipt: {
        schema_version: 2 as const,
        task_id: cas.task_id,
        attempt_id: cas.attempt_id,
        round_id: lineage.round_id,
        round_index: lineage.round_index,
        batch_kind: 'write_batch' as const,
        batch_revision: batchRevision,
        manifest_sha256: manifestSha256,
        transcript: next.transcript,
        calls,
        batch_new_write_bytes:
          next.reserved_write_bytes - current.reserved_write_bytes,
        reserved_write_bytes: next.reserved_write_bytes,
        effect_gate: 'closed' as const,
      },
      observed_checkpoint: request.committed_checkpoint,
    };
    const mapped = validateAgentStoreTransition({
      operation: 'prepare_agent_tool_batch',
      request,
      result,
    });
    if (mapped === null) throw new Error('invalid prepared-batch test evidence');
    return mapped;
  };

  const bindEvidence = (
    cas: AgentControllerCASV1,
    journal: PersistedAgentAttemptJournalV3,
    callIndex: number,
    decision: 'allow_once' | 'allow_conversation' | 'denied' | 'cancelled',
    operationId = '66666666-6666-4666-8666-666666666663',
  ): AgentStoreTransitionEvidence => {
    const call = journal.batch[callIndex];
    const lineage = journal.round_lineage;
    if (call === undefined || lineage === null || call.approval_token === null) {
      throw new Error('test bind evidence requires a gated call');
    }
    const manifestSha256 = 'a'.repeat(64);
    const token = {
      schema_version: 2 as const,
      token: call.approval_token,
      controller_cas: cas,
      task_id: cas.task_id,
      attempt_id: cas.attempt_id,
      round_id: lineage.round_id,
      round_index: lineage.round_index,
      batch_call_ids: journal.batch.map(item => item.call_id),
      batch_arguments_sha256: journal.batch.map(item => item.arguments_sha256),
      batch_revision: 1,
      manifest_sha256: manifestSha256,
      call_index: callIndex,
      call_id: call.call_id,
      name: call.name,
      arguments_sha256: call.arguments_sha256,
      idempotency_key: call.idempotency_key ?? 'b'.repeat(64),
      root_fingerprint_sha256: journal.root.root_fingerprint_sha256,
      binding_revision: journal.root.workspace_binding_revision,
      policy_version: 'agent-v1' as const,
      registry_version: 1 as const,
      access: call.access === 'confirm_once' ? 'confirm_once' as const : 'conversation_confirm' as const,
      allowed_decisions: call.access === 'confirm_once'
        ? ['denied', 'allow_once', 'cancelled'] as const
        : ['denied', 'allow_once', 'allow_conversation', 'cancelled'] as const,
    };
    const request = {
      schema_version: 2 as const,
      operation_id: operationId,
      controller_cas: cas,
      committed_checkpoint: {
        schema_version: 1 as const,
        journal_revision: cas.expected_journal_revision,
        session_generation: cas.expected_session_generation,
        session_sha256: cas.expected_session_sha256,
      },
      task_id: cas.task_id,
      conversation_id: cas.conversation_id,
      attempt_id: cas.attempt_id,
      round_id: lineage.round_id,
      round_index: lineage.round_index,
      manifest_sha256: manifestSha256,
      batch_revision: 1,
      call_index: callIndex,
      call_id: call.call_id,
      token,
      decision,
    };
    const result = {
      schema_version: 2 as const,
      status: 'bound' as const,
      operation_id: operationId,
      task_id: cas.task_id,
      attempt_id: cas.attempt_id,
      round_id: lineage.round_id,
      call_index: callIndex,
      call_id: call.call_id,
      decision,
      approval_reference:
        decision === 'allow_once' || decision === 'allow_conversation'
          ? operationId
          : null,
      grant: null,
      result_batch_revision: 1,
      observed_checkpoint: request.committed_checkpoint,
    };
    const mapped = validateAgentStoreTransition({
      operation: 'bind_agent_approval',
      request,
      result,
    });
    if (mapped === null) throw new Error('invalid bind test Agent evidence');
    return mapped;
  };

  const approvalPreflight = (
    cas: AgentControllerCASV1,
    journal: PersistedAgentAttemptJournalV3,
    callIndex: number,
    decision: 'allow_once' | 'allow_conversation' | 'denied' | 'cancelled',
    operationId = '66666666-6666-4666-8666-666666666663',
  ): AgentControllerPreflightV1 => {
    const call = journal.batch[callIndex];
    const lineage = journal.round_lineage;
    if (call === undefined || lineage === null || call.approval_token === null) {
      throw new Error('test approval preflight requires a gated call');
    }
    const preflight = validateAgentControllerPreflight({
      schema_version: 1,
      source: 'completion_controller',
      kind: 'decide_approval',
      operation_id: operationId,
      base_cas: cas,
      conversation_id: cas.conversation_id,
      task_id: cas.task_id,
      attempt_id: cas.attempt_id,
      round_id: lineage.round_id,
      round_index: lineage.round_index,
      batch_revision: 1,
      manifest_sha256: 'a'.repeat(64),
      call_index: callIndex,
      call_id: call.call_id,
      name: call.name,
      arguments_sha256: call.arguments_sha256,
      approval_token: call.approval_token,
      decision,
      source_event_id: operationId,
      access: call.access,
      workspace_id: journal.root.workspace_id,
      project_id: journal.root.project_id,
      binding_revision: journal.root.workspace_binding_revision,
      root_fingerprint_sha256: journal.root.root_fingerprint_sha256,
      policy_version: journal.policy.policy_version,
      registry_version: journal.tool_registry_version,
      tool_family: 'file_write',
      grant: null,
    });
    if (preflight === null) throw new Error('invalid approval test preflight');
    return preflight;
  };

  test('requires a native committed session ref before settling an Agent candidate', () => {
    const baseStore = createChatStore({
      now: () => T0,
      createId: () => UUID_A,
      createLifecycleId: kind =>
        kind === 'turn' ? UUID_B : kind === 'attempt' ? UUID_C : UUID_A,
    });
    const conversationId = baseStore.createConversation();
    const source = baseStore.getState().conversations[conversationId]!;
    const store = createChatStore({
      now: () => T0,
      sessionAuthority: { generation: 1, sessionSha256: 'd'.repeat(64) },
      initialState: {
        ...baseStore.getState(),
        conversations: {
          [conversationId]: {
            ...source,
            workspaceId: UUID_A,
            workspaceBinding: {
              schemaVersion: 1,
              workspaceId: UUID_A,
              bindingRevision: 1,
              projectId: null,
            },
            workspaceBootstrapState: 'none',
          },
        },
      },
    });
    store.prepareTurnAttempt(conversationId, 'requires native proof');
    const attempt = store.getState().conversations[conversationId]!.attempts[0]!;
    const journal: PersistedAgentAttemptJournalV3 = {
      schema_version: 3,
      phase: 'ready_for_round',
      controller_generation: 0,
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
        workspace_id: UUID_A,
        workspace_binding_revision: 1,
        project_id: null,
        root_fingerprint_sha256: 'a'.repeat(64),
        capabilities: ['file_read'],
      },
      tool_registry_version: 1,
      toolset_sha256: 'b'.repeat(64),
      transcript: {
        schema_version: 1,
        transcript_ref: UUID_C,
        generation: 0,
        transcript_sha256: 'c'.repeat(64),
        transcript_bytes: 0,
      },
      round_index: 0,
      round_lineage: {
        schema_version: 2,
        round_id: UUID_D,
        round_index: 0,
        launch_attempt: 1,
        status: 'ready',
        native_row_revision: null,
      },
      call_index: null,
      batch: [],
      frozen_grant_ids: [],
      reserved_write_bytes: 0,
      updated_at: T0,
    };
    const transaction = store.checkpointAgentAttemptCAS({
      cas: {
        schema_version: 1,
        conversation_id: conversationId,
        task_id: attempt.turnId,
        attempt_id: attempt.attemptId,
        expected_controller_generation: 0,
        expected_journal_revision: 0,
        expected_session_generation: 1,
        expected_session_sha256: 'd'.repeat(64),
      },
      expectedAttempt: attempt,
      journal,
      evidence: prepareEvidence(
        {
          schema_version: 1,
          conversation_id: conversationId,
          task_id: attempt.turnId,
          attempt_id: attempt.attemptId,
          expected_controller_generation: 0,
          expected_journal_revision: 0,
          expected_session_generation: 1,
          expected_session_sha256: 'd'.repeat(64),
        },
        journal,
      ),
      events: [
        {
          schema_version: 2,
          event_id: '99999999-9999-4999-8999-999999999991',
          attempt_id: attempt.attemptId,
          seq: 0,
          kind: 'round',
          round_index: 0,
          call_id: null,
          status: 'waiting',
          safe_summary_key: null,
          arguments_sha256: null,
          result_sha256: null,
          approval_reference: null,
          failure_code: null,
          created_at: T0,
        },
      ],
    });
    expect(transaction).not.toBeNull();
    expect(
      transaction?.commit(undefined as unknown as NativeSessionCommitProofV1),
    ).toBe(false);
    expect(transaction?.commit(nativeCommittedProof(store, 3))).toBe(false);
    let snapshotEvaluated = false;
    const hostileProof = {
      schema_version: 1,
      status: 'committed',
    } as Record<string, unknown>;
    Object.defineProperty(hostileProof, 'snapshot', {
      enumerable: true,
      get: () => {
        snapshotEvaluated = true;
        const proof = nativeCommittedProof(store, 2);
        return 'snapshot' in proof ? proof.snapshot : proof;
      },
    });
    expect(
      transaction?.commit(hostileProof as unknown as NativeSessionCommitProofV1),
    ).toBe(false);
    expect(snapshotEvaluated).toBe(false);
    expect(transaction?.rollback()).toBe(true);
  });

  const revokeFixture = (
    freeze: boolean,
  ): {
    store: ChatStore;
    conversationId: string;
    grant: AgentConversationGrantV2;
  } => {
    const baseStore = createChatStore({
      now: () => T0,
      createId: kind => (kind === 'conversation' ? UUID_A : UUID_B),
      createLifecycleId: kind =>
        kind === 'turn' ? UUID_B : kind === 'attempt' ? UUID_C : UUID_A,
    });
    const conversationId = baseStore.createConversation();
    expect(baseStore.prepareTurnAttempt(conversationId, 'revoke me')).not.toBeNull();
    const attempt =
      baseStore.getState().conversations[conversationId]!.attempts[0]!;
    const grant: AgentConversationGrantV2 = {
      schema_version: 2,
      grant_id: '77777777-7777-4777-8777-777777777777',
      conversation_id: conversationId,
      workspace_id: UUID_A,
      project_id: null,
      binding_revision: 1,
      root_fingerprint_sha256: 'a'.repeat(64),
      tool_family: 'file_write',
      registry_version: 1,
      policy_version: 'agent-v1',
      issued_for: {
        schema_version: 1,
        task_id: attempt.turnId,
        attempt_id: attempt.attemptId,
      },
      created_at: T0,
    };
    const wire = JSON.parse(baseStore.serialize()) as Record<string, unknown>;
    const wireConversation = (
      wire.conversations as Array<Record<string, unknown>>
    )[0]!;
    wireConversation.workspace_id = UUID_A;
    wireConversation.workspace_binding = {
      schema_version: 1,
      workspace_id: UUID_A,
      binding_revision: 1,
      project_id: null,
    };
    wireConversation.agent_grants = [grant];
    if (freeze) {
      const wireAttempt = (
        wireConversation.attempts as Array<Record<string, unknown>>
      )[0]!;
      wireAttempt.journal_revision = 1;
      wireAttempt.agent = {
        schema_version: 3,
        phase: 'ready_for_round',
        controller_generation: 0,
        policy: {
          schema_version: 1,
          policy_version: 'agent-v1',
          max_single_write_bytes: 32768,
          max_batch_write_bytes: 524288,
          max_attempt_write_bytes: 4194304,
        },
        root: {
          schema_version: 1,
          kind: 'workspace',
          workspace_id: UUID_A,
          workspace_binding_revision: 1,
          project_id: null,
          root_fingerprint_sha256: 'a'.repeat(64),
          capabilities: ['file_read', 'file_write'],
        },
        tool_registry_version: 1,
        toolset_sha256: 'b'.repeat(64),
        transcript: {
          schema_version: 1,
          transcript_ref: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
          generation: 0,
          transcript_sha256: 'c'.repeat(64),
          transcript_bytes: 0,
        },
        round_index: 0,
        round_lineage: null,
        call_index: null,
        batch: [],
        frozen_grant_ids: [grant.grant_id],
        reserved_write_bytes: 0,
        updated_at: T0,
      };
    }
    const hydrated = hydrateChatState(JSON.stringify(wire));
    const store = createChatStore({
      now: () => T0,
      createId: kind => (kind === 'conversation' ? UUID_A : UUID_B),
      createLifecycleId: kind =>
        kind === 'turn' ? UUID_B : kind === 'attempt' ? UUID_C : UUID_A,
      sessionAuthority: { generation: 1, sessionSha256: 'd'.repeat(64) },
      initialState: hydrated,
    });
    return { store, conversationId, grant };
  };

  test('revokeAgentGrant removes a grant as a persisted checkpoint', () => {
    const { store, conversationId, grant } = revokeFixture(false);
    const withGrant = store.getState().conversations[conversationId]!;
    expect(withGrant.agentGrants).toEqual([grant]);

    // The revoke applies with an exact expected-conversation guard.
    const transaction = store.revokeAgentGrant({
      conversationId,
      grantId: grant.grant_id,
      expectedConversation: withGrant,
    });
    expect(transaction).not.toBeNull();
    expect(transaction?.commit()).toBe(true);
    const after = store.getState().conversations[conversationId]!;
    expect(after.agentGrants).toEqual([]);
    // The wire form persists the revocation too.
    const wire = JSON.parse(store.serialize()) as Record<string, unknown>;
    const wireConversation = (
      wire.conversations as Array<Record<string, unknown>>
    )[0]!;
    expect(wireConversation.agent_grants).toEqual([]);
    const hydrated = hydrateChatState(store.serialize());
    expect(hydrated.conversations[conversationId]?.agentGrants).toEqual([]);
  });

  test('revokeAgentGrant fails closed on stale, missing, or frozen grants', () => {
    const { store, conversationId, grant } = revokeFixture(false);
    const withGrant = store.getState().conversations[conversationId]!;

    // Unknown grant id: nothing to revoke.
    expect(
      store.revokeAgentGrant({
        conversationId,
        grantId: '88888888-8888-4888-8888-888888888888',
        expectedConversation: withGrant,
      }),
    ).toBeNull();

    // Stale expected conversation: rejected.
    const stale = { ...withGrant, title: 'stale title' };
    expect(
      store.revokeAgentGrant({
        conversationId,
        grantId: grant.grant_id,
        expectedConversation: stale,
      }),
    ).toBeNull();
    expect(
      store.getState().conversations[conversationId]?.agentGrants,
    ).toEqual([grant]);

    // A grant frozen into a live attempt journal cannot be revoked: the
    // conversation grants replacement is rejected by the reducer.
    const frozen = revokeFixture(true);
    const frozenConversation =
      frozen.store.getState().conversations[conversationId]!;
    expect(frozenConversation.agentGrants).toEqual([grant]);
    expect(
      frozen.store.revokeAgentGrant({
        conversationId,
        grantId: grant.grant_id,
        expectedConversation: frozenConversation,
      }),
    ).toBeNull();
    expect(
      frozen.store.getState().conversations[conversationId]?.agentGrants,
    ).toEqual([grant]);
  });

  test('does not expose raw Agent grant mutations through dispatch', () => {
    const store = createChatStore({ now: () => T0 });
    const conversationId = store.createConversation();
    const before = store.getState();
    const expectedConversation = before.conversations[conversationId]!;
    store.dispatch({
      type: 'conversation/agent-grants',
      payload: {
        conversationId,
        expectedConversation,
        grants: [],
        at: T0,
      },
    });
    expect(store.getState()).toBe(before);
  });

  test('writes the exact schema-9 root and empty migration authority', () => {
    const store = createChatStore({
      now: () => T0,
      createId: kind => `${kind}-schema9`,
      createLifecycleId: kind =>
        kind === 'turn' ? UUID_B : kind === 'attempt' ? UUID_C : UUID_A,
    });
    const conversationId = store.createConversation();
    const root = JSON.parse(store.serialize()) as Record<string, unknown>;
    expect(Object.keys(root).sort()).toEqual(
      [
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
      ].sort(),
    );
    expect(root.schema_version).toBe(9);
    const conversation = (
      root.conversations as Array<Record<string, unknown>>
    )[0]!;
    expect(conversation.agent_grants).toEqual([]);
    expect(conversationId).toBe(conversation.id);

    const legacy = JSON.parse(JSON.stringify(root)) as Record<string, unknown>;
    legacy.schema_version = 8;
    delete legacy.agent_transcript_cleanup_outbox;
    delete legacy.session_events;
    delete legacy.preferences;
    for (const row of legacy.conversations as Array<Record<string, unknown>>) {
      delete row.agent_grants;
      for (const attempt of row.attempts as Array<Record<string, unknown>>) {
        delete attempt.journal_revision;
        delete attempt.agent;
        attempt.schema_version = 1;
      }
    }
    const migrated = hydrateChatState(legacy);
    expect(migrated.schemaVersion).toBe(9);
    expect(migrated.agentTranscriptCleanupOutbox).toEqual([]);
    expect(migrated.sessionEvents).toEqual([]);
    expect(migrated.conversations[conversationId]?.agentGrants).toEqual([]);
  });

  test('rejects duplicate JSON keys and malformed schema-9 event rows', () => {
    expect(() =>
      hydrateChatState('{"schema_version":9,"schema_version":9}'),
    ).toThrow(ChatStateValidationError);
    const store = createChatStore({ now: () => T0 });
    const payload = JSON.parse(store.serialize()) as Record<string, unknown>;
    payload.session_events = [
      {
        schema_version: 2,
        event_id: UUID_A,
        attempt_id: UUID_B,
        seq: 0,
        kind: 'round',
        round_index: null,
        call_id: null,
        status: 'waiting',
        safe_summary_key: null,
        arguments_sha256: null,
        result_sha256: null,
        approval_reference: null,
        failure_code: null,
        created_at: T0,
        unexpected: true,
      },
    ];
    expect(() => hydrateChatState(payload)).toThrow(/unexpected/);
  });

  test('guards Agent checkpoint transactions by exact attempt reference', () => {
    const baseStore = createChatStore({
      now: () => T0,
      createId: () => UUID_A,
      createLifecycleId: kind =>
        kind === 'turn' ? UUID_B : kind === 'attempt' ? UUID_C : UUID_A,
    });
    const conversationId = baseStore.createConversation();
    const baseConversation =
      baseStore.getState().conversations[conversationId]!;
    const store = createChatStore({
      now: () => T0,
      sessionAuthority: {
        generation: 1,
        sessionSha256: 'd'.repeat(64),
      },
      initialState: {
        ...baseStore.getState(),
        conversations: {
          [conversationId]: {
            ...baseConversation,
            workspaceId: UUID_A,
            workspaceBinding: {
              schemaVersion: 1,
              workspaceId: UUID_A,
              bindingRevision: 1,
              projectId: null,
            },
            workspaceBootstrapState: 'none',
          },
        },
      },
    });
    const prepared = store.prepareTurnAttempt(conversationId, 'agent task');
    expect(prepared).not.toBeNull();
    const attempt =
      store.getState().conversations[conversationId]!.attempts[0]!;
    const journal: PersistedAgentAttemptJournalV3 = {
      schema_version: 3 as const,
      phase: 'ready_for_round' as const,
      controller_generation: 0,
      policy: {
        schema_version: 1 as const,
        policy_version: 'agent-v1',
        max_single_write_bytes: 32768,
        max_batch_write_bytes: 512 * 1024,
        max_attempt_write_bytes: 4 * 1024 * 1024,
      },
      root: {
        schema_version: 1 as const,
        kind: 'workspace' as const,
        workspace_id: UUID_A,
        workspace_binding_revision: 1,
        project_id: null,
        root_fingerprint_sha256: 'a'.repeat(64),
        capabilities: ['file_read'] as const,
      },
      tool_registry_version: 1 as const,
      toolset_sha256: 'b'.repeat(64),
      transcript: {
        schema_version: 1 as const,
        transcript_ref: UUID_C,
        generation: 0,
        transcript_sha256: 'c'.repeat(64),
        transcript_bytes: 0,
      },
      round_index: 0,
      round_lineage: {
        schema_version: 2 as const,
        round_id: UUID_D,
        round_index: 0,
        launch_attempt: 1,
        status: 'ready',
        native_row_revision: null,
      },
      call_index: null,
      batch: [],
      frozen_grant_ids: [],
      reserved_write_bytes: 0,
      updated_at: T0,
    };
    const cas: AgentControllerCASV1 = {
      schema_version: 1,
      conversation_id: conversationId,
      task_id: attempt.turnId,
      attempt_id: attempt.attemptId,
      expected_controller_generation: 0,
      expected_journal_revision: 0,
      expected_session_generation: 1,
      expected_session_sha256: 'd'.repeat(64),
    };
    const events: SessionEventV2[] = [
      {
        schema_version: 2,
        event_id: '99999999-9999-4999-8999-999999999991',
        attempt_id: attempt.attemptId,
        seq: 0,
        kind: 'round',
        round_index: 0,
        call_id: null,
        status: 'waiting',
        safe_summary_key: null,
        arguments_sha256: null,
        result_sha256: null,
        approval_reference: null,
        failure_code: null,
        created_at: T0,
      },
    ];
    const transaction = store.checkpointAgentAttemptCAS({
      cas,
      expectedAttempt: attempt,
      journal,
      evidence: prepareEvidence(cas, journal),
      events,
    });
    expect(
      store.checkpointAgentRound({
        cas,
        expectedAttempt: attempt,
        journal,
        evidence: prepareEvidence(cas, journal),
        events,
      }),
    ).toBeNull();
    expect(
      store.checkpointAgentAttemptCAS({
        cas,
        expectedAttempt: attempt,
        journal,
        events,
        evidence: {
          operation: 'prepare_agent_attempt',
          request: {},
          result: {},
        } as unknown as AgentStoreTransitionEvidence,
      }),
    ).toBeNull();
    expect(transaction?.commit(nativeCommittedProof(store, 2))).toBe(true);
    expect(
      store.getState().conversations[conversationId]!.attempts[0]!.agent?.phase,
    ).toBe('ready_for_round');
    expect(
      hydrateChatState(store.serialize()).conversations[conversationId]!
        .attempts[0]!.agent?.phase,
    ).toBe('ready_for_round');
  });

  test('checkpoints prepared native intent projections without opening the approval gate', () => {
    const setup = (guestName?: 'start_guest_cgi' | 'stop_guest_cgi') => {
      const seed = createChatStore({
        now: () => T0,
        createId: () => UUID_A,
        createLifecycleId: kind =>
          kind === 'turn' ? UUID_B : kind === 'attempt' ? UUID_C : UUID_D,
      });
      const conversationId = seed.createConversation();
      expect(seed.prepareTurnAttempt(conversationId, 'prepare native batch')).not.toBeNull();
      const source = seed.getState().conversations[conversationId]!;
      const prepared = source.attempts[0]!;
      const currentJournal: PersistedAgentAttemptJournalV3 = {
        schema_version: 3,
        phase: 'batch_frozen',
        controller_generation: 2,
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
          workspace_id: UUID_A,
          workspace_binding_revision: 1,
          project_id: null,
          root_fingerprint_sha256: '9'.repeat(64),
          capabilities: guestName ? ['file_read', 'file_write', 'guest_service'] : ['file_read', 'file_write'],
        },
        tool_registry_version: guestName ? 2 : 1,
        toolset_sha256: '8'.repeat(64),
        transcript: {
          schema_version: 1,
          transcript_ref: '44444444-4444-4444-8444-444444444444',
          generation: 1,
          transcript_sha256: '7'.repeat(64),
          transcript_bytes: 32,
        },
        round_index: 0,
        round_lineage: {
          schema_version: 2,
          round_id: UUID_D,
          round_index: 0,
          launch_attempt: 1,
          status: 'completed',
          native_row_revision: 1,
        },
        call_index: null,
        batch: [],
        frozen_grant_ids: [],
        reserved_write_bytes: 0,
        updated_at: T0,
      };
      const currentAttempt: TurnAttemptV1 = {
        ...prepared,
        journalRevision: 2,
        agent: currentJournal,
      };
      const existingEvents: SessionEventV2[] = [
        {
          schema_version: 2,
          event_id: '99999999-9999-4999-8999-999999999991',
          attempt_id: currentAttempt.attemptId,
          seq: 0,
          kind: 'round',
          round_index: 0,
          call_id: null,
          status: 'waiting',
          safe_summary_key: null,
          arguments_sha256: null,
          result_sha256: null,
          approval_reference: null,
          failure_code: null,
          created_at: T0,
        },
        {
          schema_version: 2,
          event_id: '99999999-9999-4999-8999-999999999992',
          attempt_id: currentAttempt.attemptId,
          seq: 1,
          kind: 'round',
          round_index: 0,
          call_id: null,
          status: 'running',
          safe_summary_key: null,
          arguments_sha256: null,
          result_sha256: null,
          approval_reference: null,
          failure_code: null,
          created_at: T0,
        },
      ];
      const store = createChatStore({
        now: () => T1,
        sessionAuthority: {
          generation: 3,
          sessionSha256: 'd'.repeat(64),
        },
        initialState: {
          ...seed.getState(),
          sessionEvents: existingEvents,
          conversations: {
            [conversationId]: {
              ...source,
              workspaceId: UUID_A,
              workspaceBinding: {
                schemaVersion: 1,
                workspaceId: UUID_A,
                bindingRevision: 1,
                projectId: null,
              },
              workspaceBootstrapState: 'none',
              attempts: [currentAttempt],
            },
          },
        },
      });
      const expectedAttempt =
        store.getState().conversations[conversationId]!.attempts[0]!;
      const cas: AgentControllerCASV1 = {
        schema_version: 1,
        conversation_id: conversationId,
        task_id: expectedAttempt.turnId,
        attempt_id: expectedAttempt.attemptId,
        expected_controller_generation: 2,
        expected_journal_revision: 2,
        expected_session_generation: 3,
        expected_session_sha256: 'd'.repeat(64),
      };
      const deniedReceipt: AgentToolReceiptV1 = {
        schema_version: 1,
        call_id: 'call-denied',
        name: 'shell_exec',
        arguments_sha256: '3'.repeat(64),
        result_sha256: '6'.repeat(64),
        result_bytes: 16,
        truncated: false,
        duration_ms: 0,
        outcome: 'denied',
        failure_code: 'E_AGENT_UNKNOWN_TOOL',
        approval_reference: null,
      };
      const nextJournal: PersistedAgentAttemptJournalV3 = {
        ...currentJournal,
        phase: 'approval_pending',
        controller_generation: 3,
        transcript: {
          ...currentJournal.transcript,
          generation: 2,
          transcript_sha256: 'e'.repeat(64),
          transcript_bytes: 64,
        },
        call_index: 0,
        batch: [
          {
            schema_version: 3,
            call_index: 0,
            call_id: 'call-auto',
            name: 'read_file',
            arguments_sha256: '1'.repeat(64),
            safe_summary_key: 'agent.read_file',
            access: 'auto',
            approval_token: null,
            approval_decision: 'pending',
            approval_reference: null,
            idempotency_key: '4'.repeat(64),
            native_row_revision: null,
            receipt: null,
          },
          {
            schema_version: 3,
            call_index: 1,
            call_id: 'call-gated',
            name: guestName ?? 'write_file',
            arguments_sha256: '2'.repeat(64),
            safe_summary_key: guestName ? `agent.${guestName}` : 'agent.write_file',
            access: 'conversation_confirm',
            approval_token: '77777777-7777-4777-8777-777777777777',
            approval_decision: 'pending',
            approval_reference: null,
            idempotency_key: '5'.repeat(64),
            native_row_revision: null,
            receipt: null,
          },
          {
            schema_version: 3,
            call_index: 2,
            call_id: 'call-denied',
            name: 'shell_exec',
            arguments_sha256: '3'.repeat(64),
            safe_summary_key: 'agent.unknown',
            access: 'durable_deny',
            approval_token: null,
            approval_decision: 'denied',
            approval_reference: null,
            idempotency_key: null,
            native_row_revision: 1,
            receipt: deniedReceipt,
          },
        ],
        reserved_write_bytes: 32,
        updated_at: T1,
      };
      const evidence = preparedBatchEvidence(cas, currentJournal, nextJournal);
      const batchEvent: SessionEventV2 = {
        schema_version: 2,
        event_id: evidence.operation_id,
        attempt_id: expectedAttempt.attemptId,
        seq: 2,
        kind: 'round',
        round_index: 0,
        call_id: null,
        status: 'running',
        safe_summary_key: null,
        arguments_sha256: null,
        result_sha256: null,
        approval_reference: null,
        failure_code: null,
        created_at: T1,
      };
      return {
        store,
        conversationId,
        expectedAttempt,
        cas,
        nextJournal,
        evidence,
        batchEvent,
      };
    };
    const checkpoint = (
      fixture: ReturnType<typeof setup>,
      evidence: AgentStoreTransitionEvidence,
      journal = fixture.nextJournal,
    ) => chatReducer(fixture.store.getState(), {
      type: 'attempt/agent-checkpoint',
      payload: {
        cas: fixture.cas,
        conversationId: fixture.conversationId,
        attemptId: fixture.expectedAttempt.attemptId,
        expectedAttempt: fixture.expectedAttempt,
        journal,
        evidence,
        events: [fixture.batchEvent],
        at: T1,
      },
    });

    const valid = setup();
    const nextState = checkpoint(valid, valid.evidence);
    expect(nextState).not.toBe(valid.store.getState());
    expect(
      nextState.conversations[valid.conversationId]!.attempts[0]!.agent,
    ).toMatchObject({
      phase: 'approval_pending',
      call_index: 0,
      batch: [
        { idempotency_key: '4'.repeat(64) },
        {
          approval_decision: 'pending',
          approval_reference: null,
          idempotency_key: '5'.repeat(64),
        },
        {
          approval_decision: 'denied',
          receipt: { outcome: 'denied' },
        },
      ],
    });

    const routed = setup();
    const routedTransaction = routed.store.checkpointAgentRound({
      cas: routed.cas,
      expectedAttempt: routed.expectedAttempt,
      journal: routed.nextJournal,
      events: [routed.batchEvent],
      evidence: routed.evidence,
    });
    expect(routedTransaction).not.toBeNull();
    expect(
      routedTransaction?.commit(nativeCommittedProof(routed.store, 4)),
    ).toBe(true);
    expect(
      routed.store.getState().conversations[routed.conversationId]!.attempts[0]!
        .agent?.phase,
    ).toBe('approval_pending');

    // This exercises checkpoint -> candidate digest -> schema-9 serializer,
    // the boundary that rejected the actual prepared CGI receipt before any
    // native snapshot commit could be attempted.
    for (const name of ['start_guest_cgi', 'stop_guest_cgi'] as const) {
      const cgi = setup(name);
      const transaction = cgi.store.checkpointAgentRound({cas: cgi.cas, expectedAttempt: cgi.expectedAttempt, journal: cgi.nextJournal, events: [cgi.batchEvent], evidence: cgi.evidence});
      expect(transaction).not.toBeNull();
      expect(transaction?.commit(nativeCommittedProof(cgi.store, 4))).toBe(true);
      const reopened = hydrateChatState(cgi.store.serialize());
      expect(reopened.conversations[cgi.conversationId]!.attempts[0]!.agent?.batch[1]).toMatchObject({name, access: 'conversation_confirm', approval_decision: 'pending'});
    }

    const wrongCurrentPhase = setup();
    const wrongCurrentAttempt: TurnAttemptV1 = {
      ...wrongCurrentPhase.expectedAttempt,
      status: 'sending',
      activeRound: {
        roundId:
          wrongCurrentPhase.expectedAttempt.agent!.round_lineage!.round_id,
        roundIndex: wrongCurrentPhase.expectedAttempt.agent!.round_index,
      },
      agent: {
        ...wrongCurrentPhase.expectedAttempt.agent!,
        phase: 'round_in_flight',
        round_lineage: {
          ...wrongCurrentPhase.expectedAttempt.agent!.round_lineage!,
          status: 'active',
        },
      },
    };
    const wrongCurrentState = wrongCurrentPhase.store.getState();
    const wrongCurrentStore = createChatStore({
      now: () => T1,
      sessionAuthority: {
        generation: 3,
        sessionSha256: 'd'.repeat(64),
      },
      initialState: {
        ...wrongCurrentState,
        conversations: {
          ...wrongCurrentState.conversations,
          [wrongCurrentPhase.conversationId]: {
            ...wrongCurrentState.conversations[
              wrongCurrentPhase.conversationId
            ]!,
            attempts: [wrongCurrentAttempt],
          },
        },
      },
    });
    expect(
      wrongCurrentStore.checkpointAgentRound({
        cas: wrongCurrentPhase.cas,
        expectedAttempt: wrongCurrentAttempt,
        journal: wrongCurrentPhase.nextJournal,
        events: [wrongCurrentPhase.batchEvent],
        evidence: wrongCurrentPhase.evidence,
      }),
    ).toBeNull();

    const wrongEvidence = setup();
    expect(
      wrongEvidence.store.checkpointAgentRound({
        cas: wrongEvidence.cas,
        expectedAttempt: wrongEvidence.expectedAttempt,
        journal: wrongEvidence.nextJournal,
        events: [wrongEvidence.batchEvent],
        evidence: {
          ...wrongEvidence.evidence,
          kind: 'execute_agent_tool',
        } as AgentStoreTransitionEvidence,
      }),
    ).toBeNull();

    const withCall = (
      fixture: ReturnType<typeof setup>,
      index: number,
      change: (call: Record<string, unknown>) => Record<string, unknown>,
    ): AgentStoreTransitionEvidence => {
      if (fixture.evidence.kind !== 'prepare_agent_tool_batch' ||
        fixture.evidence.result.status === 'rejected') {
        throw new Error('expected prepared batch evidence');
      }
      const calls = fixture.evidence.result.receipt.calls.map(call => ({ ...call }));
      calls[index] = change(calls[index] as unknown as Record<string, unknown>) as never;
      return {
        ...fixture.evidence,
        result: {
          ...fixture.evidence.result,
          receipt: { ...fixture.evidence.result.receipt, calls },
        },
      } as AgentStoreTransitionEvidence;
    };
    const notStarted = setup();
    expect(checkpoint(notStarted, withCall(notStarted, 0, call => ({
      ...call,
      execution_status: 'not_started',
      execution_revision: null,
    })))).toBe(notStarted.store.getState());
    const running = setup();
    expect(checkpoint(running, withCall(running, 0, call => ({
      ...call,
      execution_status: 'running',
    })))).toBe(running.store.getState());
    const revisionDrift = setup();
    expect(checkpoint(revisionDrift, withCall(revisionDrift, 0, call => ({
      ...call,
      execution_revision: 2,
    })))).toBe(revisionDrift.store.getState());
    const tokenDrift = setup();
    expect(checkpoint(tokenDrift, withCall(tokenDrift, 1, call => ({
      ...call,
      approval_token: {
        ...(call.approval_token as Record<string, unknown>),
        token: '88888888-8888-4888-8888-888888888888',
      },
    })))).toBe(tokenDrift.store.getState());
    const callDrift = setup();
    expect(checkpoint(callDrift, withCall(callDrift, 0, call => ({
      ...call,
      call_id: 'call-auto-drift',
    })))).toBe(callDrift.store.getState());
    const terminalDrift = setup();
    expect(checkpoint(terminalDrift, withCall(terminalDrift, 2, call => ({
      ...call,
      receipt: null,
      native_row_revision: null,
    })))).toBe(terminalDrift.store.getState());
    const wrongPhase = setup();
    expect(checkpoint(
      wrongPhase,
      wrongPhase.evidence,
      { ...wrongPhase.nextJournal, phase: 'batch_frozen' },
    )).toBe(wrongPhase.store.getState());
  });

  test('keeps an issued approval token immutable across CAS revisions', () => {
    const baseStore = createChatStore({
      now: () => T0,
      createId: () => UUID_A,
    });
    const conversationId = baseStore.createConversation();
    const source = baseStore.getState().conversations[conversationId]!;
    const store = createChatStore({
      now: () => T0,
      sessionAuthority: { generation: 1, sessionSha256: 'd'.repeat(64) },
      initialState: {
        ...baseStore.getState(),
        conversations: {
          [conversationId]: {
            ...source,
            workspaceId: UUID_A,
            workspaceBinding: {
              schemaVersion: 1,
              workspaceId: UUID_A,
              bindingRevision: 1,
              projectId: null,
            },
            workspaceBootstrapState: 'none',
          },
        },
      },
    });
    const prepared = store.prepareTurnAttempt(conversationId, 'approval');
    expect(prepared).not.toBeNull();
    const attempt =
      store.getState().conversations[conversationId]!.attempts[0]!;
    const root = {
      schema_version: 1 as const,
      kind: 'workspace' as const,
      workspace_id: UUID_A,
      workspace_binding_revision: 1,
      project_id: null,
      root_fingerprint_sha256: 'a'.repeat(64),
      capabilities: ['file_read', 'file_write'] as const,
    };
    const transcript = {
      schema_version: 1 as const,
      transcript_ref: '33333333-3333-4333-8333-333333333333',
      generation: 0,
      transcript_sha256: 'b'.repeat(64),
      transcript_bytes: 0,
    };
    const policy = {
      schema_version: 1 as const,
      policy_version: 'agent-v1',
      max_single_write_bytes: 32768 as const,
      max_batch_write_bytes: 512 * 1024,
      max_attempt_write_bytes: 4 * 1024 * 1024,
    };
    const baseJournal: PersistedAgentAttemptJournalV3 = {
      schema_version: 3,
      phase: 'ready_for_round',
      controller_generation: 0,
      policy,
      root,
      tool_registry_version: 1,
      toolset_sha256: 'c'.repeat(64),
      transcript,
      round_index: 0,
      round_lineage: {
        schema_version: 2,
        round_id: UUID_D,
        round_index: 0,
        launch_attempt: 1,
        status: 'ready',
        native_row_revision: null,
      },
      call_index: null,
      batch: [],
      frozen_grant_ids: [],
      reserved_write_bytes: 0,
      updated_at: T0,
    };
    const event = (
      eventId: string,
      seq: number,
      kind: SessionEventV2['kind'],
      status: SessionEventV2['status'],
      callId: string | null = null,
      safeSummaryKey: string | null = null,
      argumentsSha256: string | null = null,
      approvalReference: string | null = null,
    ): SessionEventV2 => ({
      schema_version: 2,
      event_id: eventId,
      attempt_id: attempt.attemptId,
      seq,
      kind,
      round_index: kind === 'terminal' ? null : 0,
      call_id: callId,
      status,
      safe_summary_key: safeSummaryKey,
      arguments_sha256: argumentsSha256,
      result_sha256: null,
      approval_reference: approvalReference,
      failure_code: null,
      created_at: T0,
    });
    const readyEvents = [
      event('99999999-9999-4999-8999-999999999995', 0, 'round', 'waiting'),
    ];
    const initial = store.checkpointAgentAttemptCAS({
      cas: {
        schema_version: 1,
        conversation_id: conversationId,
        task_id: attempt.turnId,
        attempt_id: attempt.attemptId,
        expected_controller_generation: 0,
        expected_journal_revision: 0,
        expected_session_generation: 1,
        expected_session_sha256: 'd'.repeat(64),
      },
      expectedAttempt: attempt,
      journal: baseJournal,
      evidence: prepareEvidence(
        {
          schema_version: 1,
          conversation_id: conversationId,
          task_id: attempt.turnId,
          attempt_id: attempt.attemptId,
          expected_controller_generation: 0,
          expected_journal_revision: 0,
          expected_session_generation: 1,
          expected_session_sha256: 'd'.repeat(64),
        },
        baseJournal,
      ),
      events: readyEvents,
    });
    expect(initial?.commit(nativeCommittedProof(store, 2))).toBe(true);
    let currentAttempt =
      store.getState().conversations[conversationId]!.attempts[0]!;
    const activeJournal: PersistedAgentAttemptJournalV3 = {
      ...baseJournal,
      phase: 'round_in_flight',
      controller_generation: 1,
      round_lineage: {
        ...baseJournal.round_lineage!,
        status: 'active',
        native_row_revision: null,
      },
    };
    const activeCas: AgentControllerCASV1 = {
      schema_version: 1,
      conversation_id: conversationId,
      task_id: currentAttempt.turnId,
      attempt_id: currentAttempt.attemptId,
      expected_controller_generation: 0,
      expected_journal_revision: 1,
      expected_session_generation: 2,
      expected_session_sha256: store.getSessionAuthority()!.sessionSha256,
    };
    const beginRound = beginRoundPreflightForAttempt(
      currentAttempt,
      baseJournal,
      activeCas,
      '66666666-6666-4666-8666-666666666661',
    );
    const active = store.checkpointAgentAttemptCAS({
      cas: activeCas,
      expectedAttempt: currentAttempt,
      journal: activeJournal,
      evidence: beginRound,
      events: readyEvents,
    });
    expect(active?.commit(nativeCommittedProof(store, 3))).toBe(true);
    currentAttempt =
      store.getState().conversations[conversationId]!.attempts[0]!;
    const callId = 'store-call';
    const secondCallId = 'store-call-2';
    const argumentsSha256 = 'e'.repeat(64);
    const secondArgumentsSha256 = 'f'.repeat(64);
    const issuedCas: AgentControllerCASV1 = {
      schema_version: 1,
      conversation_id: conversationId,
      task_id: currentAttempt.turnId,
      attempt_id: currentAttempt.attemptId,
      expected_controller_generation: 1,
      expected_journal_revision: 2,
      expected_session_generation: 3,
      expected_session_sha256: store.getSessionAuthority()!.sessionSha256,
    };
    const token = '77777777-7777-4777-8777-777777777777';
    const secondToken = '88888888-8888-4888-8888-888888888888';
    const frozenJournal: PersistedAgentAttemptJournalV3 = {
      ...activeJournal,
      phase: 'approval_pending',
      controller_generation: 2,
      round_lineage: {
        ...activeJournal.round_lineage!,
        status: 'completed',
        native_row_revision: 1,
      },
      transcript: {
        ...activeJournal.transcript,
        generation: 1,
        transcript_sha256: '9'.repeat(64),
        transcript_bytes: 42,
      },
      batch: [
        {
          schema_version: 3,
          call_id: callId,
          call_index: 0,
          name: 'write_file',
          arguments_sha256: argumentsSha256,
          safe_summary_key: 'agent.write_file',
          access: 'conversation_confirm',
          approval_token: token,
          approval_decision: 'pending',
          approval_reference: null,
          idempotency_key: null,
          native_row_revision: null,
          receipt: null,
        },
        {
          schema_version: 3,
          call_id: secondCallId,
          call_index: 1,
          name: 'write_file',
          arguments_sha256: secondArgumentsSha256,
          safe_summary_key: 'agent.write_file',
          access: 'conversation_confirm',
          approval_token: secondToken,
          approval_decision: 'pending',
          approval_reference: null,
          idempotency_key: null,
          native_row_revision: null,
          receipt: null,
        },
      ],
      call_index: 0,
    };
    const frozenInput = {
      cas: issuedCas,
      expectedAttempt: currentAttempt,
      journal: frozenJournal,
      evidence: completeEvidence(
        issuedCas,
        activeJournal,
        frozenJournal,
        'tool_batch',
      ),
      events: [
        ...readyEvents,
        event('66666666-6666-4666-8666-666666666661', 1, 'round', 'running'),
        event(
          '66666666-6666-4666-8666-666666666662',
          2,
          'approval',
          'approval',
          callId,
          'agent.write_file',
          argumentsSha256,
        ),
      ],
    };
    expect(
      store.checkpointAgentAttemptCAS({
        ...frozenInput,
        evidence: undefined,
      } as unknown as AgentCASCheckpointInput),
    ).toBeNull();
    expect(
      store.checkpointAgentAttemptCAS({
        ...frozenInput,
        evidence: {
          ...frozenInput.evidence,
          operation_id: UUID_D,
        } as AgentStoreTransitionEvidence,
      }),
    ).toBeNull();
    const frozen = store.checkpointAgentAttemptCAS(frozenInput);
    expect(frozen?.commit(nativeCommittedProof(store, 4))).toBe(true);
    currentAttempt =
      store.getState().conversations[conversationId]!.attempts[0]!;
    expect(currentAttempt.agent?.transcript.generation).toBe(1);
    expect(currentAttempt.agent?.transcript.transcript_sha256).toBe(
      '9'.repeat(64),
    );
    expect(currentAttempt.agent?.round_lineage?.native_row_revision).toBe(1);
    const recoveredAfterProvider = hydrateChatState(store.serialize());
    const recoveredAttempt =
      recoveredAfterProvider.conversations[conversationId]!.attempts[0]!;
    expect(recoveredAttempt.agent?.transcript).toEqual(
      currentAttempt.agent?.transcript,
    );
    expect(recoveredAttempt.agent?.round_lineage?.native_row_revision).toBe(1);
    const decisionJournal: PersistedAgentAttemptJournalV3 = {
      ...frozenJournal,
      phase: 'batch_frozen',
      controller_generation: 3,
      batch: frozenJournal.batch.map((call, index) =>
        index === 0
          ? {
              ...call,
              approval_decision: 'allow_once' as const,
              approval_reference: '66666666-6666-4666-8666-666666666663',
            }
          : call,
      ),
    };
    const currentAuthority = store.getSessionAuthority()!;
    const decisionCas: AgentControllerCASV1 = {
      schema_version: 1,
      conversation_id: conversationId,
      task_id: currentAttempt.turnId,
      attempt_id: currentAttempt.attemptId,
      expected_controller_generation: 2,
      expected_journal_revision: 3,
      expected_session_generation: currentAuthority.generation,
      expected_session_sha256: currentAuthority.sessionSha256,
    };
    const directBind = store.checkpointAgentApproval({
      cas: decisionCas,
      expectedConversation: store.getState().conversations[conversationId]!,
      expectedAttempt: currentAttempt,
      journal: decisionJournal,
      evidence: bindEvidence(decisionCas, decisionJournal, 0, 'allow_once'),
      grants: [],
      events: [
        event(
          '99999999-9999-4999-8999-999999999998',
          3,
          'approval',
          'approval',
          callId,
          'agent.write_file',
          argumentsSha256,
          '66666666-6666-4666-8666-666666666663',
        ),
      ],
    });
    expect(directBind).toBeNull();

    const decision = store.decideAgentApproval({
      cas: decisionCas,
      expectedConversation: store.getState().conversations[conversationId]!,
      expectedAttempt: currentAttempt,
      journal: decisionJournal,
      evidence: approvalPreflight(
        decisionCas,
        frozenJournal,
        0,
        'allow_once',
      ),
      grants: [],
      events: [],
    });
    expect(decision?.commit(nativeCommittedProof(store, 5))).toBe(true);
    currentAttempt =
      store.getState().conversations[conversationId]!.attempts[0]!;
    expect(currentAttempt.agent?.phase).toBe('batch_frozen');
    expect(currentAttempt.agent?.batch[1]).toMatchObject({
      call_id: secondCallId,
      approval_decision: 'pending',
      approval_reference: null,
    });

    const postAuthority = store.getSessionAuthority()!;
    const postCas: AgentControllerCASV1 = {
      schema_version: 1,
      conversation_id: conversationId,
      task_id: currentAttempt.turnId,
      attempt_id: currentAttempt.attemptId,
      expected_controller_generation: 3,
      expected_journal_revision: 4,
      expected_session_generation: postAuthority.generation,
      expected_session_sha256: postAuthority.sessionSha256,
    };
    const postJournal: PersistedAgentAttemptJournalV3 = {
      ...currentAttempt.agent!,
      controller_generation: 4,
    };
    const postEvidence = bindEvidence(
      postCas,
      currentAttempt.agent!,
      0,
      'allow_once',
    );
    const post = store.checkpointAgentApproval({
      cas: postCas,
      expectedConversation: store.getState().conversations[conversationId]!,
      expectedAttempt: currentAttempt,
      journal: postJournal,
      evidence: postEvidence,
      grants: [],
      events: [
        event(
          '99999999-9999-4999-8999-999999999998',
          4,
          'approval',
          'approval',
          callId,
          'agent.write_file',
          argumentsSha256,
          '66666666-6666-4666-8666-666666666663',
        ),
      ],
    });
    expect(post?.commit(nativeCommittedProof(store, 6))).toBe(true);
    const committedConversation =
      store.getState().conversations[conversationId]!;
    const committedAttempt = committedConversation.attempts[0]!;
    const committedAuthority = store.getSessionAuthority()!;
    expect(committedAttempt.agent?.phase).toBe('batch_frozen');
    expect(committedAttempt.agent?.batch[1]?.approval_decision).toBe('pending');
    expect(
      store.checkpointAgentApproval({
        cas: postCas,
        expectedConversation: committedConversation,
        expectedAttempt: committedAttempt,
        journal: postJournal,
        evidence: postEvidence,
        grants: [],
        events: [],
      }),
    ).toBeNull();
    const substituted = {
      ...postJournal,
      batch: postJournal.batch.map((call, index) =>
        index === 0
          ? {
              ...call,
              approval_token: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
            }
          : call,
      ),
      controller_generation: 5,
    };
    const substitutedCas: AgentControllerCASV1 = {
      schema_version: 1,
      conversation_id: conversationId,
      task_id: committedAttempt.turnId,
      attempt_id: committedAttempt.attemptId,
      expected_controller_generation: 4,
      expected_journal_revision: 5,
      expected_session_generation: committedAuthority.generation,
      expected_session_sha256: committedAuthority.sessionSha256,
    };
    expect(
      store.checkpointAgentApproval({
        cas: substitutedCas,
        expectedConversation: store.getState().conversations[conversationId]!,
        expectedAttempt: committedAttempt,
        journal: substituted,
        evidence: bindEvidence(
          substitutedCas,
          substituted,
          0,
          'allow_once',
        ),
        grants: [],
        events: [
          event(
            '99999999-9999-4999-8999-999999999997',
            5,
            'approval',
            'approval',
            callId,
            'agent.write_file',
            argumentsSha256,
            '66666666-6666-4666-8666-666666666663',
          ),
        ],
      }),
    ).toBeNull();
  });

  test('validates and preserves a legacy preference while dropping its event attachment', () => {
    const store = createChatStore({ now: () => T0 });
    const legacy = JSON.parse(store.serialize()) as Record<string, unknown>;
    stripSchema9Fields(legacy);
    legacy.schema_version = 7;
    legacy.project_context_destructive_epoch = 0;
    legacy.project_context_destructive_transition = null;
    legacy.preferences = {
      schema_version: 1,
      theme_mode: 'dark',
      locale: 'zh-CN',
      default_model: 'deepseek-v4-flash',
      thinking_mode: 'high',
      tool_permission: 'workspace-write',
      show_reasoning: true,
      auto_expand_tools: false,
      confirm_destructive_file_actions: true,
    };
    legacy.session_events = [{ raw: 'must be dropped' }];
    const migrated = hydrateChatState(legacy);
    expect(migrated.preferences).toMatchObject({
      theme_mode: 'dark',
      locale: 'zh-CN',
    });
    expect(migrated.sessionEvents).toEqual([]);
    expect(JSON.parse(serializeChatState(migrated)).preferences).toMatchObject({
      theme_mode: 'dark',
      locale: 'zh-CN',
    });
    expect(migrated.migrationDiagnostics).toEqual({
      dropped_legacy_session_events: true,
    });
  });

  test('defaults missing legacy preferences and reports the migration fact', () => {
    const legacy = JSON.parse(
      serializeChatState(createEmptyChatState()),
    ) as Record<string, unknown>;
    stripSchema9Fields(legacy);
    legacy.schema_version = 8;
    legacy.workspace_authority_outbox = [];
    legacy.project_context_destructive_epoch = 0;
    legacy.project_context_destructive_transition = null;
    const migrated = hydrateChatState(legacy);
    expect(migrated.preferences).toMatchObject({
      schema_version: 1,
      theme_mode: 'system',
      locale: 'system',
    });
    expect(migrated.migrationDiagnostics).toEqual({
      defaulted_legacy_preferences: true,
    });
    const persisted = JSON.parse(serializeChatState(migrated)) as Record<
      string,
      unknown
    >;
    expect(persisted.preferences).toMatchObject({
      schema_version: 1,
      selected_harness_id: 'dsh',
    });
  });

  test('retains terminal cleanup ownership while deleting an Agent conversation', () => {
    const baseStore = createChatStore({
      now: () => T0,
      createId: () => UUID_A,
      createLifecycleId: kind =>
        kind === 'turn' ? UUID_B : kind === 'attempt' ? UUID_C : UUID_A,
    });
    const conversationId = baseStore.createConversation();
    const source = baseStore.getState().conversations[conversationId]!;
    const store = createChatStore({
      now: () => T0,
      sessionAuthority: {
        generation: 1,
        sessionSha256: 'd'.repeat(64),
      },
      initialState: {
        ...baseStore.getState(),
        conversations: {
          [conversationId]: {
            ...source,
            workspaceId: UUID_A,
            workspaceBinding: {
              schemaVersion: 1,
              workspaceId: UUID_A,
              bindingRevision: 1,
              projectId: null,
            },
            workspaceBootstrapState: 'none',
          },
        },
      },
    });
    const prepared = store.prepareTurnAttempt(conversationId, 'delete me');
    expect(prepared).not.toBeNull();
    const attempt =
      store.getState().conversations[conversationId]!.attempts[0]!;
    const initialJournal: PersistedAgentAttemptJournalV3 = {
      schema_version: 3,
      phase: 'ready_for_round',
      controller_generation: 0,
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
        workspace_id: UUID_A,
        workspace_binding_revision: 1,
        project_id: null,
        root_fingerprint_sha256: 'a'.repeat(64),
        capabilities: ['file_read'],
      },
      tool_registry_version: 1,
      toolset_sha256: 'b'.repeat(64),
      transcript: {
        schema_version: 1,
        transcript_ref: UUID_C,
        generation: 0,
        transcript_sha256: 'c'.repeat(64),
        transcript_bytes: 0,
      },
      round_index: 0,
      round_lineage: {
        schema_version: 2,
        round_id: UUID_D,
        round_index: 0,
        launch_attempt: 1,
        status: 'ready',
        native_row_revision: null,
      },
      call_index: null,
      batch: [],
      frozen_grant_ids: [],
      reserved_write_bytes: 0,
      updated_at: T0,
    };
    const initialEvents: SessionEventV2[] = [
      {
        schema_version: 2,
        event_id: '99999999-9999-4999-8999-999999999992',
        attempt_id: attempt.attemptId,
        seq: 0,
        kind: 'round',
        round_index: 0,
        call_id: null,
        status: 'waiting',
        safe_summary_key: null,
        arguments_sha256: null,
        result_sha256: null,
        approval_reference: null,
        failure_code: null,
        created_at: T0,
      },
    ];
    const initial = store.checkpointAgentAttemptCAS({
      cas: {
        schema_version: 1,
        conversation_id: conversationId,
        task_id: attempt.turnId,
        attempt_id: attempt.attemptId,
        expected_controller_generation: 0,
        expected_journal_revision: 0,
        expected_session_generation: 1,
        expected_session_sha256: 'd'.repeat(64),
      },
      expectedAttempt: attempt,
      journal: initialJournal,
      evidence: prepareEvidence(
        {
          schema_version: 1,
          conversation_id: conversationId,
          task_id: attempt.turnId,
          attempt_id: attempt.attemptId,
          expected_controller_generation: 0,
          expected_journal_revision: 0,
          expected_session_generation: 1,
          expected_session_sha256: 'd'.repeat(64),
        },
        initialJournal,
      ),
      events: initialEvents,
    });
    expect(initial?.commit(nativeCommittedProof(store, 2))).toBe(true);
    const currentAttempt =
      store.getState().conversations[conversationId]!.attempts[0]!;
    const activeJournal: PersistedAgentAttemptJournalV3 = {
      ...initialJournal,
      phase: 'round_in_flight',
      controller_generation: 1,
      round_lineage: {
        ...initialJournal.round_lineage!,
        status: 'active',
        native_row_revision: null,
      },
    };
    const activeCas: AgentControllerCASV1 = {
      schema_version: 1,
      conversation_id: conversationId,
      task_id: currentAttempt.turnId,
      attempt_id: currentAttempt.attemptId,
      expected_controller_generation: 0,
      expected_journal_revision: 1,
      expected_session_generation: 2,
      expected_session_sha256: store.getSessionAuthority()!.sessionSha256,
    };
    const beginRound = beginRoundPreflightForAttempt(
      currentAttempt,
      initialJournal,
      activeCas,
      '66666666-6666-4666-8666-666666666661',
    );
    const active = store.checkpointAgentAttemptCAS({
      cas: activeCas,
      expectedAttempt: currentAttempt,
      journal: activeJournal,
      evidence: beginRound,
      events: initialEvents,
    });
    expect(active?.commit(nativeCommittedProof(store, 3))).toBe(true);
    const afterActive =
      store.getState().conversations[conversationId]!.attempts[0]!;
    const terminalJournal: PersistedAgentAttemptJournalV3 = {
      ...activeJournal,
      phase: 'failed',
      controller_generation: 2,
      round_lineage: {
        ...activeJournal.round_lineage!,
        status: 'completed',
        native_row_revision: 1,
      },
      transcript: {
        ...activeJournal.transcript,
        generation: 1,
        transcript_sha256: 'e'.repeat(64),
        transcript_bytes: 1,
      },
    };
    const authority = store.getSessionAuthority()!;
    const terminalCas: AgentControllerCASV1 = {
      schema_version: 1,
      conversation_id: conversationId,
      task_id: currentAttempt.turnId,
      attempt_id: currentAttempt.attemptId,
      expected_controller_generation: 1,
      expected_journal_revision: 2,
      expected_session_generation: authority.generation,
      expected_session_sha256: authority.sessionSha256,
    };
    expect(
      store.enqueueAgentTranscriptCleanup({
        conversationId,
        attemptId: afterActive.attemptId,
        expectedAttempt: afterActive,
        cleanup: {
          schema_version: 1,
          cleanup_id: '66666666-6666-4666-8666-666666666664',
          conversation_id: conversationId,
          task_id: afterActive.turnId,
          attempt_id: afterActive.attemptId,
          transcript_ref: UUID_C,
          transcript_sha256: activeJournal.transcript.transcript_sha256,
          reason: 'failed',
          created_at: T0,
        },
      }),
    ).toBeNull();
    expect(store.getState().agentTranscriptCleanupOutbox).toEqual([]);
    const terminalCleanup: AgentTranscriptCleanupV1 = {
      schema_version: 1,
      cleanup_id: '66666666-6666-4666-8666-666666666665',
      conversation_id: conversationId,
      task_id: afterActive.turnId,
      attempt_id: afterActive.attemptId,
      transcript_ref: UUID_C,
      transcript_sha256: 'e'.repeat(64),
      reason: 'failed',
      created_at: T0,
    };
    const terminalInput: AgentCASCheckpointInput = {
      cas: terminalCas,
      expectedAttempt: afterActive,
      journal: terminalJournal,
      evidence: completeEvidence(
        terminalCas,
        activeJournal,
        terminalJournal,
        'blocked',
      ),
      events: [
        ...initialEvents,
        {
          ...initialEvents[0]!,
          event_id: '66666666-6666-4666-8666-666666666661',
          seq: 1,
          status: 'running',
        },
        {
          ...initialEvents[0]!,
          event_id: '99999999-9999-4999-8999-999999999994',
          seq: 2,
          kind: 'terminal',
          round_index: null,
          status: 'failed',
          failure_code: 'E_COMPLETION_LENGTH',
        },
      ],
    };

    const finalJournal: PersistedAgentAttemptJournalV3 = {
      ...terminalJournal,
      phase: 'final_response',
    };
    const finalEvidence = completeEvidence(
      terminalCas,
      activeJournal,
      finalJournal,
      'final',
    );
    const finalCleanup: AgentTranscriptCleanupV1 = {
      ...terminalCleanup,
      cleanup_id: '66666666-6666-4666-8666-666666666666',
      reason: 'completed',
    };
    const finalEvent: SessionEventV2 = {
      ...initialEvents[0]!,
      event_id: '99999999-9999-4999-8999-999999999993',
      seq: 2,
      kind: 'terminal',
      round_index: null,
      status: 'ok',
      failure_code: null,
    };
    const finalInput = {
      cas: terminalCas,
      expectedAttempt: afterActive,
      journal: finalJournal,
      evidence: finalEvidence,
      events: [
        ...initialEvents,
        {
          ...initialEvents[0]!,
          event_id: '66666666-6666-4666-8666-666666666661',
          seq: 1,
          status: 'running' as const,
        },
        finalEvent,
      ],
      assistantMessage: {
        id: 'atomic-final-message',
        role: 'assistant' as const,
        text: 'atomic final',
        createdAt: T0,
        attachments: [],
        metadata: {
          modelId: 'deepseek-v4-flash' as const,
          latencyMs: 1,
          finishReason: 'stop',
          reasoning: 'checked atomically',
        },
      },
      cleanup: finalCleanup,
    };
    const makeFinalStore = () =>
      createChatStore({
        now: () => T0,
        sessionAuthority: authority,
        initialState: store.getState(),
      });

    const committedFinalStore = makeFinalStore();
    const committedFinal = committedFinalStore.completeAgentAttempt(finalInput);
    expect(committedFinal).not.toBeNull();
    expect(
      committedFinal?.commit(nativeCommittedProof(committedFinalStore, 4)),
    ).toBe(true);
    const committedConversation =
      committedFinalStore.getState().conversations[conversationId]!;
    expect(committedConversation.attempts[0]).toMatchObject({
      status: 'completed',
      assistantMessageId: 'atomic-final-message',
      failureCode: null,
      agent: { phase: 'final_response' },
    });
    expect(committedConversation.messages.at(-1)?.text).toBe('atomic final');
    expect(committedFinalStore.getState().sessionEvents?.at(-1)).toEqual(
      finalEvent,
    );
    expect(committedFinalStore.getState().agentTranscriptCleanupOutbox).toEqual([
      finalCleanup,
    ]);

    const whitespaceEvidence = completeEvidence(
      terminalCas,
      activeJournal,
      finalJournal,
      'final',
      ' \n\t',
    );
    const whitespaceFinalInput = {
      ...finalInput,
      evidence: whitespaceEvidence,
      assistantMessage: {
        ...finalInput.assistantMessage,
        metadata: {
          modelId: 'deepseek-v4-flash' as const,
          latencyMs: 1,
          finishReason: 'stop',
        },
      },
    };
    const whitespaceFinalStore = makeFinalStore();
    const whitespaceFinal = whitespaceFinalStore.completeAgentAttempt(
      whitespaceFinalInput,
    );
    expect(whitespaceFinal).not.toBeNull();
    expect(whitespaceFinal?.rollback()).toBe(true);

    const explicitWhitespaceStore = makeFinalStore();
    expect(
      explicitWhitespaceStore.completeAgentAttempt({
        ...whitespaceFinalInput,
        assistantMessage: {
          ...whitespaceFinalInput.assistantMessage,
          metadata: {
            ...whitespaceFinalInput.assistantMessage.metadata,
            reasoning: ' \n\t',
          },
        },
      }),
    ).toBeNull();

    const missingNonemptyReasoningStore = makeFinalStore();
    expect(
      missingNonemptyReasoningStore.completeAgentAttempt({
        ...finalInput,
        assistantMessage: {
          ...finalInput.assistantMessage,
          metadata: {
            modelId: 'deepseek-v4-flash',
            latencyMs: 1,
            finishReason: 'stop',
          },
        },
      }),
    ).toBeNull();

    const committedSnapshot = committedFinalStore.getState();
    expect(committedFinalStore.completeAgentAttempt(finalInput)).toBeNull();
    expect(committedFinalStore.getState()).toBe(committedSnapshot);

    const rolledBackFinalStore = makeFinalStore();
    const beforeRollback = rolledBackFinalStore.getState();
    const rolledBackFinal = rolledBackFinalStore.completeAgentAttempt(finalInput);
    expect(rolledBackFinal).not.toBeNull();
    expect(rolledBackFinal?.rollback()).toBe(true);
    const rolledBackState = rolledBackFinalStore.getState();
    expect(
      rolledBackState.conversations[conversationId]?.attempts[0],
    ).toBe(afterActive);
    expect(rolledBackState.conversations[conversationId]?.messages).toBe(
      beforeRollback.conversations[conversationId]?.messages,
    );
    expect(rolledBackState.sessionEvents).toBe(beforeRollback.sessionEvents);
    expect(rolledBackState.agentTranscriptCleanupOutbox).toBe(
      beforeRollback.agentTranscriptCleanupOutbox,
    );

    const projectionEvidence = prepareEvidence(terminalCas, finalJournal);
    if (
      projectionEvidence.kind !== 'prepare_agent_attempt' ||
      finalEvidence.kind !== 'complete_agent_round_v2' ||
      finalEvidence.result.status !== 'completed' ||
      finalEvidence.result.outcome.kind !== 'final'
    ) throw new Error('invalid recovery fixture');
    const recoveryOperationId = '77777777-7777-4777-8777-777777777770';
    const recoveryRequest = {
      schema_version: 2 as const,
      operation_id: recoveryOperationId,
      controller_cas: terminalCas,
      committed_checkpoint: {
        schema_version: 1 as const,
        journal_revision: terminalCas.expected_journal_revision,
        session_generation: terminalCas.expected_session_generation,
        session_sha256: terminalCas.expected_session_sha256,
      },
      target: {
        schema_version: 2 as const,
        kind: 'round' as const,
        task_id: terminalCas.task_id,
        attempt_id: terminalCas.attempt_id,
        round_id: activeJournal.round_lineage!.round_id,
        round_index: activeJournal.round_index,
      },
      action: 'reconcile' as const,
      expected_round_revision: 1,
      expected_execution_revision: null,
      expected_transcript: activeJournal.transcript,
      root: activeJournal.root,
    };
    const recoveredRound = {
      schema_version: 2 as const,
      kind: 'final' as const,
      task_id: terminalCas.task_id,
      attempt_id: terminalCas.attempt_id,
      round_id: finalJournal.round_lineage!.round_id,
      round_index: finalJournal.round_index,
      launch_attempt: finalJournal.round_lineage!.launch_attempt,
      result_round_revision:
        finalJournal.round_lineage!.native_row_revision!,
      transcript: finalJournal.transcript,
      completion_receipt:
        finalEvidence.result.outcome.completion_receipt,
      text: finalEvidence.result.outcome.text,
      reasoning: finalEvidence.result.outcome.reasoning,
      assistant_text_sha256:
        agentTextSHA256(finalEvidence.result.outcome.text)!,
      reasoning_text_sha256:
        agentTextSHA256(finalEvidence.result.outcome.reasoning)!,
    };
    const recoveryResult = {
      schema_version: 2 as const,
      status: 'resumed' as const,
      operation_id: recoveryOperationId,
      next_action: 'persist_final' as const,
      attempt: projectionEvidence.result.attempt,
      completed_round: recoveredRound,
    };
    const recoveryEvidence = validateAgentStoreTransition({
      operation: 'recover_agent_attempt',
      request: recoveryRequest,
      result: recoveryResult,
    });
    if (recoveryEvidence === null) throw new Error('invalid recovery evidence');
    const recoveredFinalStore = makeFinalStore();
    const recoveredFinal = recoveredFinalStore.completeAgentAttempt({
      ...finalInput,
      evidence: recoveryEvidence,
    });
    expect(recoveredFinal).not.toBeNull();
    expect(recoveredFinal?.rollback()).toBe(true);
    const badDigestEvidence = {
      ...recoveryEvidence,
      result: {
        ...recoveryResult,
        completed_round: {
          ...recoveredRound,
          assistant_text_sha256: '0'.repeat(64),
        },
      },
    } as AgentStoreTransitionEvidence;
    const badDigestStore = makeFinalStore();
    const badDigestBefore = badDigestStore.getState();
    expect(
      badDigestStore.completeAgentAttempt({
        ...finalInput,
        evidence: badDigestEvidence,
      }),
    ).toBeNull();
    expect(badDigestStore.getState()).toBe(badDigestBefore);

    const cancelOperationId = '77777777-7777-4777-8777-777777777771';
    const cancelSourceEvent = {
      schema_version: 2 as const,
      event_id: cancelOperationId,
      attempt_id: afterActive.attemptId,
      seq: 2,
      kind: 'cancel' as const,
      round_index: 0,
      call_id: null,
      status: 'cancelled' as const,
      safe_summary_key: null,
      arguments_sha256: null,
      result_sha256: null,
      approval_reference: cancelOperationId,
      failure_code: 'E_AGENT_CANCELLED' as const,
      created_at: T0,
    };
    const cancelBaseState: ChatState = {
      ...store.getState(),
      sessionEvents: [
        ...(store.getState().sessionEvents ?? []),
        cancelSourceEvent,
      ],
    };
    const cancelBaseSha = sessionSnapshotSHA256(
      serializeChatState(cancelBaseState),
    );
    if (cancelBaseSha === null) throw new Error('invalid cancel base state');
    const cancelAuthority = {
      generation: 3,
      sessionSha256: cancelBaseSha,
    };
    const cancelCas: AgentControllerCASV1 = {
      ...terminalCas,
      expected_session_generation: cancelAuthority.generation,
      expected_session_sha256: cancelAuthority.sessionSha256,
    };
    const cancelledJournal: PersistedAgentAttemptJournalV3 = {
      ...terminalJournal,
      phase: 'cancelled',
      round_lineage: {
        ...terminalJournal.round_lineage!,
        status: 'cancelled',
        native_row_revision: 2,
      },
    };
    const cancelTarget = {
      schema_version: 2 as const,
      kind: 'round' as const,
      task_id: cancelCas.task_id,
      attempt_id: cancelCas.attempt_id,
      round_id: cancelledJournal.round_lineage!.round_id,
      round_index: cancelledJournal.round_index,
    };
    const cancelRequest = {
      schema_version: 2 as const,
      operation_id: cancelOperationId,
      controller_cas: cancelCas,
      committed_checkpoint: {
        schema_version: 1 as const,
        journal_revision: cancelCas.expected_journal_revision,
        session_generation: cancelCas.expected_session_generation,
        session_sha256: cancelCas.expected_session_sha256,
      },
      target: cancelTarget,
      cancel_token: {
        schema_version: 2 as const,
        issuer: 'completion_controller' as const,
        source_event_id: cancelOperationId,
        token: cancelOperationId,
        task_id: cancelCas.task_id,
        attempt_id: cancelCas.attempt_id,
        expected_phase: 'round_in_flight' as const,
        reason_code: 'E_AGENT_CANCELLED' as const,
      },
      expected_round_revision: 1,
      expected_execution_revision: null,
      expected_transcript: activeJournal.transcript,
      root: activeJournal.root,
    };
    const cancelResult = {
      schema_version: 2 as const,
      status: 'cancelled' as const,
      operation_id: cancelOperationId,
      target: cancelTarget,
      result_round_revision: 2,
      result_execution_revision: null,
      transcript: cancelledJournal.transcript,
      receipt: null,
      effect_may_have_occurred: false,
      observed_checkpoint: cancelRequest.committed_checkpoint,
    };
    const cancelEvidence = validateAgentStoreTransition({
      operation: 'cancel_agent_attempt',
      request: cancelRequest,
      result: cancelResult,
    });
    if (cancelEvidence === null) throw new Error('invalid cancel evidence');
    const cancelCleanup: AgentTranscriptCleanupV1 = {
      ...terminalCleanup,
      cleanup_id: '66666666-6666-4666-8666-666666666667',
      transcript_sha256: cancelledJournal.transcript.transcript_sha256,
      reason: 'cancelled',
    };
    const cancelTerminalEvent: SessionEventV2 = {
      ...initialEvents[0]!,
      event_id: '99999999-9999-4999-8999-999999999990',
      seq: 3,
      kind: 'terminal',
      round_index: null,
      status: 'cancelled',
      failure_code: 'E_AGENT_CANCELLED',
    };
    const cancelInput = {
      cas: cancelCas,
      expectedAttempt: afterActive,
      journal: cancelledJournal,
      evidence: cancelEvidence,
      events: [...cancelBaseState.sessionEvents!, cancelTerminalEvent],
      assistantMessage: null,
      cleanup: cancelCleanup,
    };
    const makeCancelStore = () =>
      createChatStore({
        now: () => T0,
        sessionAuthority: cancelAuthority,
        initialState: cancelBaseState,
      });
    const cancelledStore = makeCancelStore();
    const cancelled = cancelledStore.completeAgentAttempt(cancelInput);
    expect(cancelled).not.toBeNull();
    expect(cancelled?.commit(nativeCommittedProof(cancelledStore, 4))).toBe(true);
    expect(cancelledStore.getState().conversations[conversationId]?.attempts[0]).toMatchObject({
      status: 'cancelled',
      assistantMessageId: null,
      failureCode: null,
      agent: { phase: 'cancelled' },
    });
    expect(cancelledStore.getState().sessionEvents?.at(-1)).toEqual(
      cancelTerminalEvent,
    );
    expect(cancelledStore.getState().agentTranscriptCleanupOutbox).toEqual([
      cancelCleanup,
    ]);

    const cancelledNegativeStore = makeCancelStore();
    const cancelledNegativeBefore = cancelledNegativeStore.getState();
    const cancelRequestedEvidence = validateAgentStoreTransition({
      operation: 'cancel_agent_attempt',
      request: cancelRequest,
      result: {
        ...cancelResult,
        status: 'cancel_requested',
      },
    });
    if (cancelRequestedEvidence === null) {
      throw new Error('invalid cancel-requested evidence');
    }
    expect(
      cancelledNegativeStore.completeAgentAttempt({
        ...cancelInput,
        evidence: cancelRequestedEvidence,
      }),
    ).toBeNull();
    expect(
      cancelledNegativeStore.completeAgentAttempt({
        ...cancelInput,
        assistantMessage: finalInput.assistantMessage,
      }),
    ).toBeNull();
    expect(
      cancelledNegativeStore.completeAgentAttempt({
        ...cancelInput,
        cleanup: undefined,
      } as unknown as Parameters<ChatStore['completeAgentAttempt']>[0]),
    ).toBeNull();
    expect(cancelledNegativeStore.getState()).toBe(cancelledNegativeBefore);

    const executeOperationId = '77777777-7777-4777-8777-777777777772';
    const executeCallId = 'call-cancelled-by-executor';
    const executeArgumentsSha = '6'.repeat(64);
    const executeIdempotencyKey = '7'.repeat(64);
    const executeRoundReceipt: CompletionRoundReceiptV1 = {
      schemaVersion: 1,
      transportSchemaVersion: 2,
      harnessId: 'dsh',
      turnId: afterActive.turnId,
      attemptId: afterActive.attemptId,
      roundId: activeJournal.round_lineage!.round_id,
      roundIndex: 0,
      providerRequestId: 'provider-execute-request',
      providerResponseId: 'provider-execute-response',
      requestedModel: 'deepseek-v4-flash',
      model: 'deepseek-v4-flash',
      thinkingMode: 'high',
      finishReason: 'tool_calls',
      latencyMs: 2,
      visibleHistorySha256: 'f'.repeat(64),
      modelInputSha256: '1'.repeat(64),
      requestBodySha256: '2'.repeat(64),
      projectContextReceipt: null,
    };
    const executionJournal: PersistedAgentAttemptJournalV3 = {
      ...activeJournal,
      phase: 'execution_intent',
      controller_generation: 2,
      round_lineage: {
        ...activeJournal.round_lineage!,
        status: 'completed',
        native_row_revision: 1,
      },
      transcript: {
        ...activeJournal.transcript,
        generation: 1,
        transcript_sha256: '4'.repeat(64),
        transcript_bytes: 40,
      },
      call_index: 0,
      batch: [
        {
          schema_version: 3,
          call_id: executeCallId,
          call_index: 0,
          name: 'read_file',
          arguments_sha256: executeArgumentsSha,
          safe_summary_key: 'agent.read_file',
          access: 'auto',
          approval_token: null,
          approval_decision: 'pending',
          approval_reference: null,
          idempotency_key: executeIdempotencyKey,
          native_row_revision: 1,
          receipt: null,
        },
      ],
    };
    const executionAttempt: TurnAttemptV1 = {
      ...afterActive,
      status: 'prepared',
      visibleHistorySha256: executeRoundReceipt.visibleHistorySha256,
      activeRound: null,
      rounds: [executeRoundReceipt],
      journalRevision: 3,
      agent: executionJournal,
    };
    const executeRunningEvent: SessionEventV2 = {
      schema_version: 2,
      event_id: executeOperationId,
      attempt_id: executionAttempt.attemptId,
      seq: 2,
      kind: 'tool_call',
      round_index: 0,
      call_id: executeCallId,
      status: 'running',
      safe_summary_key: 'agent.read_file',
      arguments_sha256: executeArgumentsSha,
      result_sha256: null,
      approval_reference: null,
      failure_code: null,
      created_at: T0,
    };
    const executeBaseState: ChatState = {
      ...store.getState(),
      conversations: {
        ...store.getState().conversations,
        [conversationId]: {
          ...store.getState().conversations[conversationId]!,
          attempts: [executionAttempt],
        },
      },
      sessionEvents: [
        ...(store.getState().sessionEvents ?? []),
        executeRunningEvent,
      ],
    };
    const executeBaseSha = sessionSnapshotSHA256(
      serializeChatState(executeBaseState),
    );
    if (executeBaseSha === null) throw new Error('invalid execute base state');
    const executeAuthority = {
      generation: 4,
      sessionSha256: executeBaseSha,
    };
    const executeCas: AgentControllerCASV1 = {
      schema_version: 1,
      conversation_id: conversationId,
      task_id: executionAttempt.turnId,
      attempt_id: executionAttempt.attemptId,
      expected_controller_generation: 2,
      expected_journal_revision: 3,
      expected_session_generation: executeAuthority.generation,
      expected_session_sha256: executeAuthority.sessionSha256,
    };
    const executeRequest = {
      schema_version: 2 as const,
      operation_id: executeOperationId,
      controller_cas: executeCas,
      committed_checkpoint: {
        schema_version: 1 as const,
        journal_revision: executeCas.expected_journal_revision,
        session_generation: executeCas.expected_session_generation,
        session_sha256: executeCas.expected_session_sha256,
      },
      task_id: executeCas.task_id,
      conversation_id: executeCas.conversation_id,
      attempt_id: executeCas.attempt_id,
      round_id: executionJournal.round_lineage!.round_id,
      round_index: executionJournal.round_index,
      batch_kind: 'read_only_batch' as const,
      manifest_sha256: null,
      expected_batch_revision: 1,
      call_index: 0,
      call_id: executeCallId,
      name: 'read_file',
      arguments_sha256: executeArgumentsSha,
      idempotency_key: executeIdempotencyKey,
      expected_execution_revision: 1,
      transcript: executionJournal.transcript,
      root: executionJournal.root,
      approval_reference: null,
    };
    const executeCancelledReceipt = {
      schema_version: 1 as const,
      call_id: executeCallId,
      name: 'read_file',
      arguments_sha256: executeArgumentsSha,
      result_sha256: '8'.repeat(64),
      result_bytes: 0,
      truncated: false,
      duration_ms: 3,
      outcome: 'cancelled' as const,
      failure_code: 'E_AGENT_CANCELLED' as const,
      approval_reference: null,
    };
    const executedTranscript = {
      ...executionJournal.transcript,
      generation: 2,
      transcript_sha256: '5'.repeat(64),
      transcript_bytes: 64,
    };
    const executeCancelledResult = {
      schema_version: 2 as const,
      status: 'cancelled' as const,
      operation_id: executeOperationId,
      task_id: executeCas.task_id,
      attempt_id: executeCas.attempt_id,
      round_id: executeRequest.round_id,
      round_index: executeRequest.round_index,
      call_index: 0,
      call_id: executeCallId,
      name: 'read_file',
      idempotency_key: executeIdempotencyKey,
      result_execution_revision: 2,
      transcript: executedTranscript,
      receipt: executeCancelledReceipt,
      effect_may_have_occurred: false as const,
    };
    const executeCancelledEvidence = validateAgentStoreTransition({
      operation: 'execute_agent_tool',
      request: executeRequest,
      result: executeCancelledResult,
    });
    if (executeCancelledEvidence === null) {
      throw new Error('invalid execute-cancelled evidence');
    }
    const executedCancelledJournal: PersistedAgentAttemptJournalV3 = {
      ...executionJournal,
      phase: 'cancelled',
      controller_generation: 3,
      transcript: executedTranscript,
      batch: [
        {
          ...executionJournal.batch[0]!,
          native_row_revision: 2,
          receipt: executeCancelledReceipt,
        },
      ],
    };
    const executeCleanup: AgentTranscriptCleanupV1 = {
      ...terminalCleanup,
      cleanup_id: '66666666-6666-4666-8666-666666666668',
      transcript_sha256: executedTranscript.transcript_sha256,
      reason: 'cancelled',
    };
    const executeResultEvent: SessionEventV2 = {
      schema_version: 2,
      event_id: '99999999-9999-4999-8999-999999999988',
      attempt_id: executionAttempt.attemptId,
      seq: 3,
      kind: 'tool_result',
      round_index: 0,
      call_id: executeCallId,
      status: 'cancelled',
      safe_summary_key: 'agent.read_file',
      arguments_sha256: executeArgumentsSha,
      result_sha256: executeCancelledReceipt.result_sha256,
      approval_reference: null,
      failure_code: executeCancelledReceipt.failure_code,
      created_at: T0,
    };
    const executeTerminalEvent: SessionEventV2 = {
      ...initialEvents[0]!,
      event_id: '99999999-9999-4999-8999-999999999989',
      seq: 4,
      kind: 'terminal',
      round_index: null,
      status: 'cancelled',
      failure_code: executeCancelledReceipt.failure_code,
    };
    const executeFinalInput = {
      cas: executeCas,
      expectedAttempt: executionAttempt,
      journal: executedCancelledJournal,
      evidence: executeCancelledEvidence,
      // A is already durable; this candidate atomically owns B then C.
      events: [executeResultEvent, executeTerminalEvent],
      assistantMessage: null,
      cleanup: executeCleanup,
    };
    const makeExecuteStore = () =>
      createChatStore({
        now: () => T0,
        sessionAuthority: executeAuthority,
        initialState: executeBaseState,
      });
    const executeCancelledStore = makeExecuteStore();
    const executeCancelled =
      executeCancelledStore.completeAgentAttempt(executeFinalInput);
    expect(executeCancelled).not.toBeNull();
    expect(
      executeCancelled?.commit(nativeCommittedProof(executeCancelledStore, 5)),
    ).toBe(true);
    expect(
      executeCancelledStore.getState().conversations[conversationId]?.attempts[0],
    ).toMatchObject({
      status: 'cancelled',
      assistantMessageId: null,
      failureCode: null,
      agent: {
        phase: 'cancelled',
        transcript: executedTranscript,
        batch: [{ receipt: executeCancelledReceipt }],
      },
    });
    expect(executeCancelledStore.getState().agentTranscriptCleanupOutbox).toEqual([
      executeCleanup,
    ]);

    const executeNegativeStore = makeExecuteStore();
    const executeNegativeBefore = executeNegativeStore.getState();
    for (const invalidEvents of [
      [executeTerminalEvent],
      [executeResultEvent],
      [
        { ...executeResultEvent, event_id: executeOperationId },
        executeTerminalEvent,
      ],
      [executeTerminalEvent, executeResultEvent],
    ]) {
      expect(
        executeNegativeStore.completeAgentAttempt({
          ...executeFinalInput,
          events: invalidEvents,
        }),
      ).toBeNull();
    }
    const nonterminalResults = [
      {
        ...executeCancelledResult,
        status: 'running' as const,
        receipt: null,
        effect_may_have_occurred: false,
      },
      {
        ...executeCancelledResult,
        status: 'cancel_requested' as const,
        receipt: null,
        effect_may_have_occurred: true,
      },
      {
        ...executeCancelledResult,
        status: 'unknown' as const,
        receipt: null,
        effect_may_have_occurred: false as const,
        failure_code: 'E_AGENT_LEDGER' as const,
      },
      {
        ...executeCancelledResult,
        status: 'ambiguous' as const,
        receipt: {
          ...executeCancelledReceipt,
          outcome: 'ambiguous' as const,
          failure_code: 'E_AGENT_EXECUTION_AMBIGUOUS' as const,
        },
        effect_may_have_occurred: true as const,
        failure_code: 'E_AGENT_EXECUTION_AMBIGUOUS' as const,
      },
    ];
    for (const nonterminalResult of nonterminalResults) {
      const nonterminalEvidence = validateAgentStoreTransition({
        operation: 'execute_agent_tool',
        request: executeRequest,
        result: nonterminalResult,
      });
      if (nonterminalEvidence === null) {
        throw new Error('invalid nonterminal execute evidence');
      }
      expect(
        executeNegativeStore.completeAgentAttempt({
          ...executeFinalInput,
          evidence: nonterminalEvidence,
        }),
      ).toBeNull();
    }
    expect(
      executeNegativeStore.completeAgentAttempt({
        ...executeFinalInput,
        assistantMessage: finalInput.assistantMessage,
      }),
    ).toBeNull();
    expect(
      executeNegativeStore.completeAgentAttempt({
        ...executeFinalInput,
        cleanup: undefined,
      } as unknown as Parameters<ChatStore['completeAgentAttempt']>[0]),
    ).toBeNull();
    expect(executeNegativeStore.getState()).toBe(executeNegativeBefore);

    const rejectedFinalStore = makeFinalStore();
    const rejectedBefore = rejectedFinalStore.getState();
    expect(
      rejectedFinalStore.completeAgentAttempt({
        ...finalInput,
        cleanup: undefined,
      } as unknown as Parameters<ChatStore['completeAgentAttempt']>[0]),
    ).toBeNull();
    if (
      finalEvidence.kind !== 'complete_agent_round_v2' ||
      finalEvidence.result.status !== 'completed' ||
      finalEvidence.result.outcome.kind !== 'final'
    ) throw new Error('invalid final evidence fixture');
    const finalResult = finalEvidence.result;
    if (
      finalResult.status !== 'completed' ||
      finalResult.outcome.kind !== 'final'
    ) throw new Error('invalid final evidence fixture');
    expect(
      rejectedFinalStore.completeAgentAttempt({
        ...finalInput,
        evidence: {
          ...finalEvidence,
          result: {
            ...finalResult,
            outcome: {
              ...finalResult.outcome,
              completion_receipt: {
                ...finalResult.outcome.completion_receipt,
                latency_ms: 2,
              },
            },
          },
        } as AgentStoreTransitionEvidence,
      }),
    ).toBeNull();
    expect(
      rejectedFinalStore.completeAgentAttempt({
        ...finalInput,
        assistantMessage: {
          ...finalInput.assistantMessage,
          text: 'digest-mismatched text',
        },
      }),
    ).toBeNull();
    expect(
      rejectedFinalStore.completeAgentAttempt({
        ...finalInput,
        cas: {
          ...terminalCas,
          expected_journal_revision:
            terminalCas.expected_journal_revision - 1,
        },
      }),
    ).toBeNull();
    expect(rejectedFinalStore.getState()).toBe(rejectedBefore);

    const terminalWithoutCleanup = store.checkpointAgentAttemptCAS(terminalInput);
    expect(terminalWithoutCleanup).toBeNull();
    const terminal = store.completeAgentAttempt({
      ...terminalInput,
      journal: terminalJournal,
      evidence: terminalInput.evidence as AgentStoreTransitionEvidence,
      assistantMessage: null,
      cleanup: terminalCleanup,
    });
    expect(terminal?.commit(nativeCommittedProof(store, 4))).toBe(true);
    expect(store.getState().agentTranscriptCleanupOutbox).toEqual([
      terminalCleanup,
    ]);
    const wrongCleanupReason = JSON.parse(store.serialize()) as {
      agent_transcript_cleanup_outbox: Array<{ reason: string }>;
    };
    wrongCleanupReason.agent_transcript_cleanup_outbox[0]!.reason = 'completed';
    expect(() => hydrateChatState(wrongCleanupReason)).toThrow(/terminal attempt phase/);
    const storedTerminalCleanup = store.getState().agentTranscriptCleanupOutbox![0]!;
    expect(
      store.acknowledgeAgentTranscriptCleanup(
        storedTerminalCleanup.cleanup_id,
        storedTerminalCleanup,
        undefined as unknown as NativeSessionCommitProofV1,
        undefined as unknown as NativeAgentDiscardProofV1,
      ),
    ).toBe(false);
    expect(store.getState().agentTranscriptCleanupOutbox).toEqual([
      terminalCleanup,
    ]);
    const withoutDiscardEvidence =
      store.acknowledgeAgentTranscriptCleanupTransaction(
        storedTerminalCleanup.cleanup_id,
        storedTerminalCleanup,
      );
    expect(
      withoutDiscardEvidence?.commit(
        nativeCommittedProof(store, 5),
        undefined as unknown as NativeAgentDiscardProofV1,
      ),
    ).toBe(false);
    expect(withoutDiscardEvidence?.rollback()).toBe(true);
    const mismatchedDiscardEvidence =
      store.acknowledgeAgentTranscriptCleanupTransaction(
        storedTerminalCleanup.cleanup_id,
        storedTerminalCleanup,
      );
    expect(
      mismatchedDiscardEvidence?.commit(nativeCommittedProof(store, 5), {
        ...nativeDiscardProof(storedTerminalCleanup, afterActive.turnId),
        transcript_ref: UUID_D,
      }),
    ).toBe(false);
    expect(mismatchedDiscardEvidence?.rollback()).toBe(true);
    const acknowledgement = store.acknowledgeAgentTranscriptCleanupTransaction(
      storedTerminalCleanup.cleanup_id,
      storedTerminalCleanup,
    );
    expect(
      acknowledgement?.commit(
        nativeCommittedProof(store, 5),
        nativeDiscardProof(storedTerminalCleanup, afterActive.turnId),
      ),
    ).toBe(true);
    expect(store.getState().agentTranscriptCleanupOutbox).toEqual([]);
    const owned = store.getState().conversations[conversationId]!;
    expect(owned.attempts[0]?.status).toBe('failed');
    expect(owned.attempts[0]?.failureCode).toBe('E_COMPLETION_LENGTH');
    const recoveredBlocked = hydrateChatState(store.serialize());
    expect(
      recoveredBlocked.conversations[conversationId]?.attempts[0]?.failureCode,
    ).toBe('E_COMPLETION_LENGTH');
    expect((recoveredBlocked.sessionEvents ?? []).at(-1)?.failure_code).toBe(
      'E_COMPLETION_LENGTH',
    );
    const cleanup: AgentTranscriptCleanupV1 = {
      schema_version: 1,
      cleanup_id: '66666666-6666-4666-8666-666666666666',
      conversation_id: conversationId,
      task_id: afterActive.turnId,
      attempt_id: afterActive.attemptId,
      transcript_ref: UUID_C,
      transcript_sha256: 'e'.repeat(64),
      reason: 'conversation_deleted',
      created_at: T0,
    };
    const eventsBeforeDeletion = store.getState().sessionEvents;
    const deletion = store.deleteConversationWithAgentCleanup({
      conversationId,
      expectedConversation: owned,
      cleanup: [cleanup],
    });
    expect(deletion?.rollback()).toBe(true);
    expect(store.getState().sessionEvents).toBe(eventsBeforeDeletion);
    const committedDeletion = store.deleteConversationWithAgentCleanup({
      conversationId,
      expectedConversation: owned,
      cleanup: [cleanup],
    });
    expect(committedDeletion?.commit(nativeCommittedProof(store, 6))).toBe(true);
    expect(store.getState().conversations[conversationId]).toBeUndefined();
    expect(store.getState().agentTranscriptCleanupOutbox).toEqual([cleanup]);
    expect(
      hydrateChatState(store.serialize()).agentTranscriptCleanupOutbox,
    ).toEqual([cleanup]);
    const restarted = createChatStore({
      initialState: hydrateChatState(store.serialize()),
      sessionAuthority: store.getSessionAuthority()!,
    });
    const detachedCleanup = restarted.getState().agentTranscriptCleanupOutbox![0]!;
    const restartedAcknowledgement =
      restarted.acknowledgeAgentTranscriptCleanupTransaction(
        detachedCleanup.cleanup_id,
        detachedCleanup,
      );
    expect(
      restartedAcknowledgement?.commit(
        nativeCommittedProof(restarted, 7),
        nativeDiscardProof(detachedCleanup, '99999999-9999-4999-8999-999999999999'),
      ),
    ).toBe(false);
    expect(restartedAcknowledgement?.rollback()).toBe(true);
    const restartedCommit =
      restarted.acknowledgeAgentTranscriptCleanupTransaction(
        detachedCleanup.cleanup_id,
        detachedCleanup,
      );
    expect(
      restartedCommit?.commit(
        nativeCommittedProof(restarted, 7),
        nativeDiscardProof(detachedCleanup, detachedCleanup.task_id),
      ),
    ).toBe(true);
    expect(restarted.getState().agentTranscriptCleanupOutbox).toEqual([]);
  });

  test('persists a begin-round preflight event before any post result', () => {
    const baseStore = createChatStore({
      now: () => T0,
      createId: () => UUID_A,
      createLifecycleId: kind =>
        kind === 'turn' ? UUID_B : kind === 'attempt' ? UUID_C : UUID_D,
    });
    const conversationId = baseStore.createConversation();
    const source = baseStore.getState().conversations[conversationId]!;
    const store = createChatStore({
      now: () => T0,
      sessionAuthority: { generation: 1, sessionSha256: 'd'.repeat(64) },
      initialState: {
        ...baseStore.getState(),
        conversations: {
          [conversationId]: {
            ...source,
            workspaceId: UUID_A,
            workspaceBinding: {
              schemaVersion: 1,
              workspaceId: UUID_A,
              bindingRevision: 1,
              projectId: null,
            },
            workspaceBootstrapState: 'none',
          },
        },
      },
    });
    expect(store.prepareTurnAttempt(conversationId, 'preflight')).not.toBeNull();
    const attempt = store.getState().conversations[conversationId]!.attempts[0]!;
    const frozenHistory = projectAgentVisibleHistory(
      store.getState().conversations[conversationId]!,
      attempt,
    );
    if (frozenHistory === null) throw new Error('invalid frozen history fixture');
    const root = {
      schema_version: 1 as const,
      kind: 'workspace' as const,
      workspace_id: UUID_A,
      workspace_binding_revision: 1,
      project_id: null,
      root_fingerprint_sha256: 'a'.repeat(64),
      capabilities: ['file_read'] as const,
    };
    const transcript = {
      schema_version: 1 as const,
      transcript_ref: UUID_C,
      generation: 0,
      transcript_sha256: 'c'.repeat(64),
      transcript_bytes: 0,
    };
    const journal: PersistedAgentAttemptJournalV3 = {
      schema_version: 3,
      phase: 'round_in_flight',
      controller_generation: 1,
      policy: {
        schema_version: 1,
        policy_version: 'agent-v1',
        max_single_write_bytes: 32768,
        max_batch_write_bytes: 512 * 1024,
        max_attempt_write_bytes: 4 * 1024 * 1024,
      },
      root,
      tool_registry_version: 1,
      toolset_sha256: 'b'.repeat(64),
      transcript,
      round_index: 0,
      round_lineage: {
        schema_version: 2,
        round_id: UUID_D,
        round_index: 0,
        launch_attempt: 1,
        status: 'active',
        native_row_revision: null,
      },
      call_index: null,
      batch: [],
      frozen_grant_ids: [],
      reserved_write_bytes: 0,
      updated_at: T0,
    };
    const readyJournal: PersistedAgentAttemptJournalV3 = {
      ...journal,
      phase: 'ready_for_round',
      controller_generation: 0,
      round_lineage: null,
    };
    const prepareCas: AgentControllerCASV1 = {
      schema_version: 1,
      conversation_id: conversationId,
      task_id: attempt.turnId,
      attempt_id: attempt.attemptId,
      expected_controller_generation: 0,
      expected_journal_revision: 0,
      expected_session_generation: 1,
      expected_session_sha256: 'd'.repeat(64),
    };
    const readyEvent: SessionEventV2 = {
      schema_version: 2,
      event_id: '99999999-9999-4999-8999-999999999995',
      attempt_id: attempt.attemptId,
      seq: 0,
      kind: 'round',
      round_index: 0,
      call_id: null,
      status: 'waiting',
      safe_summary_key: null,
      arguments_sha256: null,
      result_sha256: null,
      approval_reference: null,
      failure_code: null,
      created_at: T0,
    };
    const unpreparedPreflight = beginRoundPreflightForAttempt(
      attempt,
      journal,
      prepareCas,
      '66666666-6666-4666-8666-66666666665f',
    );
    expect(
      store.checkpointAgentRound({
        cas: prepareCas,
        expectedAttempt: attempt,
        journal,
        events: [],
        evidence: unpreparedPreflight,
      }),
    ).toBeNull();
    const prepared = store.initializeAgentAttempt({
      cas: prepareCas,
      expectedAttempt: attempt,
      journal: readyJournal,
      evidence: prepareEvidence(prepareCas, readyJournal),
      events: [readyEvent],
    });
    expect(prepared?.commit(nativeCommittedProof(store, 2))).toBe(true);
    const preparedAttempt = store.getState().conversations[conversationId]!.attempts[0]!;
    const preflightCas: AgentControllerCASV1 = {
      schema_version: 1,
      conversation_id: conversationId,
      task_id: preparedAttempt.turnId,
      attempt_id: preparedAttempt.attemptId,
      expected_controller_generation: 0,
      expected_journal_revision: 1,
      expected_session_generation: 2,
      expected_session_sha256: store.getSessionAuthority()!.sessionSha256,
    };
    const initialRoundPreflight = (
      roundIndex: number,
      expectedRoundRevision: number,
      operationId: string,
    ): AgentControllerPreflightV1 | null =>
      validateAgentControllerPreflight({
        schema_version: 1,
        source: 'completion_controller',
        kind: 'begin_round',
        operation_id: operationId,
        base_cas: preflightCas,
        conversation_id: conversationId,
        task_id: preparedAttempt.turnId,
        attempt_id: preparedAttempt.attemptId,
        round_id: UUID_D,
        round_index: roundIndex,
        launch_attempt: 1,
        expected_round_revision: expectedRoundRevision,
        transport_schema_version: 2,
        model: preparedAttempt.modelId,
        thinking_mode: preparedAttempt.thinkingMode,
        visible_history_sha256: frozenHistory.digest,
        visible_message_count: frozenHistory.count,
        project_context_sha256: null,
        transcript,
        root,
        registry_version: 1,
        toolset_sha256: readyJournal.toolset_sha256,
      });
    const preflight = initialRoundPreflight(
      0,
      0,
      '66666666-6666-4666-8666-666666666660',
    );
    expect(preflight).not.toBeNull();
    if (preflight === null) throw new Error('invalid initial-round preflight');
    expect(
      store.checkpointAgentRound({
        cas: {
          ...preflight.base_cas,
          expected_journal_revision: 0,
          expected_session_generation: 1,
          expected_session_sha256: 'd'.repeat(64),
        },
        expectedAttempt: preparedAttempt,
        journal,
        events: [readyEvent],
        evidence: preflight,
      }),
    ).toBeNull();
    const wrongIndexPreflight = initialRoundPreflight(
      1,
      0,
      '66666666-6666-4666-8666-666666666661',
    );
    const wrongRevisionPreflight = initialRoundPreflight(
      0,
      1,
      '66666666-6666-4666-8666-666666666662',
    );
    if (wrongIndexPreflight === null || wrongRevisionPreflight === null) {
      throw new Error('invalid rejected initial-round preflight fixture');
    }
    expect(
      store.checkpointAgentRound({
        cas: preflightCas,
        expectedAttempt: preparedAttempt,
        journal: {
          ...journal,
          round_index: 1,
          round_lineage: {
            ...journal.round_lineage!,
            round_index: 1,
          },
        },
        events: [readyEvent],
        evidence: wrongIndexPreflight,
      }),
    ).toBeNull();
    expect(
      store.checkpointAgentRound({
        cas: preflightCas,
        expectedAttempt: preparedAttempt,
        journal,
        events: [readyEvent],
        evidence: wrongRevisionPreflight,
      }),
    ).toBeNull();
    const transaction = store.checkpointAgentRound({
      cas: preflight.base_cas,
      expectedAttempt: preparedAttempt,
      journal,
      events: [readyEvent],
      evidence: preflight,
    });
    expect(transaction).not.toBeNull();
    expect(
      transaction?.commit(nativeCommittedProof(store, 3)),
    ).toBe(true);
    expect(
      store.getState().sessionEvents?.some(
        event =>
          event.event_id === preflight.operation_id &&
          event.kind === 'round' &&
          event.status === 'running',
      ),
    ).toBe(true);
  });

  test('starts the next round directly from a fully settled tool batch', () => {
    const seed = createChatStore({
      now: () => T0,
      createId: () => UUID_A,
      createLifecycleId: kind =>
        kind === 'turn' ? UUID_B : kind === 'attempt' ? UUID_C : UUID_D,
    });
    const conversationId = seed.createConversation();
    const source = seed.getState().conversations[conversationId]!;
    const preparer = createChatStore({
      now: () => T0,
      sessionAuthority: { generation: 1, sessionSha256: 'd'.repeat(64) },
      initialState: {
        ...seed.getState(),
        conversations: {
          [conversationId]: {
            ...source,
            workspaceId: UUID_A,
            workspaceBinding: {
              schemaVersion: 1,
              workspaceId: UUID_A,
              bindingRevision: 1,
              projectId: null,
            },
            workspaceBootstrapState: 'none',
          },
        },
      },
    });
    expect(preparer.prepareTurnAttempt(conversationId, 'next round')).not.toBeNull();
    const preparedAttempt = preparer.getState().conversations[conversationId]!.attempts[0]!;
    const root = {
      schema_version: 1 as const,
      kind: 'workspace' as const,
      workspace_id: UUID_A,
      workspace_binding_revision: 1,
      project_id: null,
      root_fingerprint_sha256: 'a'.repeat(64),
      capabilities: ['file_read', 'file_write'] as const,
    };
    const transcript = {
      schema_version: 1 as const,
      transcript_ref: UUID_C,
      generation: 1,
      transcript_sha256: 'b'.repeat(64),
      transcript_bytes: 12,
    };
    const callId = 'call-direct';
    const argumentsSha256 = 'c'.repeat(64);
    const resultSha256 = 'e'.repeat(64);
    const currentJournal: PersistedAgentAttemptJournalV3 = {
      schema_version: 3,
      phase: 'tool_result_pending',
      controller_generation: 0,
      policy: {
        schema_version: 1,
        policy_version: 'agent-v1',
        max_single_write_bytes: 32768,
        max_batch_write_bytes: 512 * 1024,
        max_attempt_write_bytes: 4 * 1024 * 1024,
      },
      root,
      tool_registry_version: 1,
      toolset_sha256: 'f'.repeat(64),
      transcript,
      round_index: 0,
      round_lineage: {
        schema_version: 2,
        round_id: UUID_D,
        round_index: 0,
        launch_attempt: 1,
        status: 'completed',
        native_row_revision: 1,
      },
      call_index: 0,
      batch: [
        {
          schema_version: 3,
          call_index: 0,
          call_id: callId,
          name: 'write_file',
          arguments_sha256: argumentsSha256,
          safe_summary_key: 'agent.write_file',
          access: 'conversation_confirm',
          approval_token: 'approval-next-round',
          approval_decision: 'allow_once',
          approval_reference: '99999999-9999-4999-8999-999999999994',
          idempotency_key: '1'.repeat(64),
          native_row_revision: 1,
          receipt: {
            schema_version: 1,
            call_id: callId,
            name: 'write_file',
            arguments_sha256: argumentsSha256,
            result_sha256: resultSha256,
            result_bytes: 12,
            truncated: false,
            duration_ms: 1,
            outcome: 'ok',
            failure_code: null,
            approval_reference: '99999999-9999-4999-8999-999999999994',
          },
        },
      ],
      frozen_grant_ids: [],
      reserved_write_bytes: 123,
      updated_at: T0,
    };
    const attempt: TurnAttemptV1 = {
      ...preparedAttempt,
      visibleHistorySha256: '9'.repeat(64),
      rounds: [
        {
          schemaVersion: 1,
          transportSchemaVersion: 2,
          harnessId: 'dsh',
          turnId: preparedAttempt.turnId,
          attemptId: preparedAttempt.attemptId,
          roundId: UUID_D,
          roundIndex: 0,
          providerRequestId: '77777777-7777-4777-8777-777777777771',
          providerResponseId: '77777777-7777-4777-8777-777777777772',
          requestedModel: 'deepseek-v4-flash',
          model: 'deepseek-v4-flash',
          thinkingMode: 'high',
          finishReason: 'tool_calls',
          latencyMs: 1,
          visibleHistorySha256: '9'.repeat(64),
          modelInputSha256: '1'.repeat(64),
          requestBodySha256: '2'.repeat(64),
          projectContextReceipt: null,
        },
      ],
      agent: currentJournal,
      journalRevision: 0,
    };
    const roundEvent: SessionEventV2 = {
      schema_version: 2,
      event_id: '99999999-9999-4999-8999-999999999995',
      attempt_id: attempt.attemptId,
      seq: 0,
      kind: 'round',
      round_index: 0,
      call_id: null,
      status: 'running',
      safe_summary_key: null,
      arguments_sha256: null,
      result_sha256: null,
      approval_reference: null,
      failure_code: null,
      created_at: T0,
    };
    const approvalEvent: SessionEventV2 = {
      schema_version: 2,
      event_id: '99999999-9999-4999-8999-999999999994',
      attempt_id: attempt.attemptId,
      seq: 1,
      kind: 'approval',
      round_index: 0,
      call_id: callId,
      status: 'approval',
      safe_summary_key: 'agent.write_file',
      arguments_sha256: argumentsSha256,
      result_sha256: null,
      approval_reference: '99999999-9999-4999-8999-999999999994',
      failure_code: null,
      created_at: T0,
    };
    const toolEvent: SessionEventV2 = {
      schema_version: 2,
      event_id: '99999999-9999-4999-8999-999999999996',
      attempt_id: attempt.attemptId,
      seq: 2,
      kind: 'tool_call',
      round_index: 0,
      call_id: callId,
      status: 'waiting',
      safe_summary_key: 'agent.write_file',
      arguments_sha256: argumentsSha256,
      result_sha256: null,
      approval_reference: null,
      failure_code: null,
      created_at: T0,
    };
    const settledResultEvent: SessionEventV2 = {
      ...toolEvent,
      event_id: '99999999-9999-4999-8999-999999999997',
      seq: 3,
      kind: 'tool_result',
      status: 'ok',
      result_sha256: resultSha256,
      approval_reference: approvalEvent.event_id,
    };
    const settledEvents = [
      roundEvent,
      approvalEvent,
      toolEvent,
      settledResultEvent,
    ];
    const store = createChatStore({
      now: () => T0,
      sessionAuthority: { generation: 1, sessionSha256: 'd'.repeat(64) },
      initialState: {
        ...preparer.getState(),
        conversations: {
          [conversationId]: {
            ...preparer.getState().conversations[conversationId]!,
            attempts: [attempt],
          },
        },
        sessionEvents: settledEvents,
      },
    });
    const nextRoundId = '88888888-8888-4888-8888-888888888888';
    const nextJournal: PersistedAgentAttemptJournalV3 = {
      ...currentJournal,
      phase: 'round_in_flight',
      controller_generation: 1,
      round_index: 1,
      round_lineage: {
        schema_version: 2,
        round_id: nextRoundId,
        round_index: 1,
        launch_attempt: 1,
        status: 'active',
        native_row_revision: null,
      },
      batch: [],
      call_index: null,
    };
    const cas: AgentControllerCASV1 = {
      schema_version: 1,
      conversation_id: conversationId,
      task_id: attempt.turnId,
      attempt_id: attempt.attemptId,
      expected_controller_generation: 0,
      expected_journal_revision: 0,
      expected_session_generation: 1,
      expected_session_sha256: 'd'.repeat(64),
    };
    const preflight = validateAgentControllerPreflight({
      schema_version: 1,
      source: 'completion_controller',
      kind: 'begin_round',
      operation_id: '99999999-9999-4999-8999-999999999998',
      base_cas: cas,
      conversation_id: conversationId,
      task_id: attempt.turnId,
      attempt_id: attempt.attemptId,
      round_id: nextRoundId,
      round_index: 1,
      launch_attempt: 1,
      expected_round_revision: 0,
      transport_schema_version: 2,
      model: 'deepseek-v4-flash',
      thinking_mode: 'high',
      visible_history_sha256: attempt.visibleHistorySha256,
      visible_message_count: attempt.visibleMessageIds.length,
      project_context_sha256: null,
      transcript,
      root,
      registry_version: 1,
      toolset_sha256: currentJournal.toolset_sha256,
    });
    if (preflight === null) throw new Error('invalid next-round preflight');

    const unsettledJournal: PersistedAgentAttemptJournalV3 = {
      ...currentJournal,
      call_index: 1,
      batch: [
        {
          ...currentJournal.batch[0]!,
          call_id: 'call-unsettled',
          call_index: 0,
          arguments_sha256: '8'.repeat(64),
          approval_token: 'approval-unsettled',
          approval_reference: '99999999-9999-4999-8999-999999999990',
          idempotency_key: '7'.repeat(64),
          receipt: null,
        },
        {
          ...currentJournal.batch[0]!,
          call_index: 1,
        },
      ],
    };
    const unsettledAttempt: TurnAttemptV1 = {
      ...attempt,
      agent: unsettledJournal,
    };
    const unsettledStore = createChatStore({
      now: () => T0,
      sessionAuthority: { generation: 1, sessionSha256: 'd'.repeat(64) },
      initialState: {
        ...store.getState(),
        conversations: {
          [conversationId]: {
            ...store.getState().conversations[conversationId]!,
            attempts: [unsettledAttempt],
          },
        },
      },
    });
    expect(
      unsettledStore.checkpointAgentRound({
        cas,
        expectedAttempt: unsettledAttempt,
        journal: nextJournal,
        events: settledEvents,
        evidence: preflight,
      }),
    ).toBeNull();

    for (const [roundIndex, roundId, operationId] of [
      [1, UUID_D, '99999999-9999-4999-8999-999999999991'],
      [2, nextRoundId, '99999999-9999-4999-8999-999999999992'],
    ] as const) {
      const invalidRoundPreflight = validateAgentControllerPreflight({
        ...preflight,
        operation_id: operationId,
        round_id: roundId,
        round_index: roundIndex,
      });
      if (invalidRoundPreflight === null) {
        throw new Error('invalid rejected next-round preflight fixture');
      }
      expect(
        store.checkpointAgentRound({
          cas,
          expectedAttempt: attempt,
          journal: {
            ...nextJournal,
            round_index: roundIndex,
            round_lineage: {
              ...nextJournal.round_lineage!,
              round_id: roundId,
              round_index: roundIndex,
            },
          },
          events: settledEvents,
          evidence: invalidRoundPreflight,
        }),
      ).toBeNull();
    }

    const staleCas: AgentControllerCASV1 = {
      ...cas,
      expected_session_generation: 2,
    };
    const stalePreflight = validateAgentControllerPreflight({
      ...preflight,
      operation_id: '99999999-9999-4999-8999-999999999993',
      base_cas: staleCas,
    });
    if (stalePreflight === null) {
      throw new Error('invalid stale-authority preflight fixture');
    }
    expect(
      store.checkpointAgentRound({
        cas: staleCas,
        expectedAttempt: attempt,
        journal: nextJournal,
        events: settledEvents,
        evidence: stalePreflight,
      }),
    ).toBeNull();

    const before = store.getState();
    const transaction = store.checkpointAgentRound({
      cas,
      expectedAttempt: attempt,
      journal: nextJournal,
      events: settledEvents,
      evidence: preflight,
    });
    expect(transaction).not.toBeNull();
    expect(transaction?.commit(nativeCommittedProof(store, 2))).toBe(true);
    const nextAttempt = store.getState().conversations[conversationId]!.attempts[0]!;
    expect(nextAttempt.agent?.phase).toBe('round_in_flight');
    expect(nextAttempt.agent?.round_index).toBe(1);
    expect(nextAttempt.agent?.round_lineage?.round_id).toBe(nextRoundId);
    expect(nextAttempt.agent?.round_lineage).toMatchObject({
      round_index: 1,
      launch_attempt: 1,
      status: 'active',
      native_row_revision: null,
    });
    expect(nextAttempt.agent?.batch).toEqual([]);
    expect(nextAttempt.agent?.call_index).toBeNull();
    expect(nextAttempt.agent?.reserved_write_bytes).toBe(123);
    expect(nextAttempt.agent?.root).toEqual(currentJournal.root);
    expect(nextAttempt.agent?.transcript).toEqual(currentJournal.transcript);
    expect(nextAttempt.agent?.toolset_sha256).toBe(
      currentJournal.toolset_sha256,
    );
    expect(before.conversations[conversationId]!.attempts[0]!.agent?.phase).toBe('tool_result_pending');
  });

  test('advances an evidence-free tool cursor to gated and automatic calls', () => {
    const setup = (
      nextCall: PersistedAgentCallJournalV3,
      middleCalls: readonly PersistedAgentCallJournalV3[] = [],
      storeNow: () => string = () => T1,
    ) => {
      const seed = createChatStore({
        now: () => T0,
        createId: () => UUID_A,
        createLifecycleId: kind =>
          kind === 'turn' ? UUID_B : kind === 'attempt' ? UUID_C : UUID_D,
      });
      const conversationId = seed.createConversation();
      const source = seed.getState().conversations[conversationId]!;
      const preparer = createChatStore({
        now: () => T0,
        initialState: {
          ...seed.getState(),
          conversations: {
            [conversationId]: {
              ...source,
              workspaceId: UUID_A,
              workspaceBinding: {
                schemaVersion: 1,
                workspaceId: UUID_A,
                bindingRevision: 1,
                projectId: null,
              },
              workspaceBootstrapState: 'none',
            },
          },
        },
      });
      expect(preparer.prepareTurnAttempt(conversationId, 'advance call')).not.toBeNull();
      const prepared = preparer.getState().conversations[conversationId]!.attempts[0]!;
      const firstCall: PersistedAgentCallJournalV3 = {
        schema_version: 3,
        call_id: 'call-0',
        call_index: 0,
        name: 'read_file',
        arguments_sha256: '1'.repeat(64),
        safe_summary_key: 'agent.read_file',
        access: 'auto',
        approval_token: null,
        approval_decision: 'pending',
        approval_reference: null,
        idempotency_key: '2'.repeat(64),
        native_row_revision: 2,
        receipt: {
          schema_version: 1,
          call_id: 'call-0',
          name: 'read_file',
          arguments_sha256: '1'.repeat(64),
          result_sha256: '3'.repeat(64),
          result_bytes: 8,
          truncated: false,
          duration_ms: 1,
          outcome: 'ok',
          failure_code: null,
          approval_reference: null,
        },
      };
      const batch = [firstCall, ...middleCalls, nextCall].map((call, index) => ({
        ...call,
        call_index: index,
      }));
      const journal: PersistedAgentAttemptJournalV3 = {
        schema_version: 3,
        phase: 'tool_result_pending',
        controller_generation: 4,
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
          workspace_id: UUID_A,
          workspace_binding_revision: 1,
          project_id: null,
          root_fingerprint_sha256: '4'.repeat(64),
          capabilities: ['file_read', 'file_write'],
        },
        tool_registry_version: 1,
        toolset_sha256: '5'.repeat(64),
        transcript: {
          schema_version: 1,
          transcript_ref: UUID_D,
          generation: 2,
          transcript_sha256: '6'.repeat(64),
          transcript_bytes: 32,
        },
        round_index: 0,
        round_lineage: {
          schema_version: 2,
          round_id: '66666666-6666-4666-8666-666666666666',
          round_index: 0,
          launch_attempt: 1,
          status: 'completed',
          native_row_revision: 3,
        },
        call_index: 0,
        batch,
        frozen_grant_ids: [],
        reserved_write_bytes: 17,
        updated_at: T0,
      };
      const expectedAttempt: TurnAttemptV1 = {
        ...prepared,
        journalRevision: 4,
        agent: journal,
      };
      const state: ChatState = {
        ...preparer.getState(),
        conversations: {
          [conversationId]: {
            ...preparer.getState().conversations[conversationId]!,
            attempts: [expectedAttempt],
          },
        },
      };
      const store = createChatStore({
        now: storeNow,
        sessionAuthority: { generation: 1, sessionSha256: 'd'.repeat(64) },
        initialState: state,
      });
      const cas: AgentControllerCASV1 = {
        schema_version: 1,
        conversation_id: conversationId,
        task_id: expectedAttempt.turnId,
        attempt_id: expectedAttempt.attemptId,
        expected_controller_generation: 4,
        expected_journal_revision: 4,
        expected_session_generation: 1,
        expected_session_sha256: 'd'.repeat(64),
      };
      const candidate = (
        phase: 'batch_frozen' | 'approval_pending',
        callIndex = batch.length - 1,
      ): PersistedAgentAttemptJournalV3 => ({
        ...journal,
        phase,
        controller_generation: 5,
        call_index: callIndex,
        updated_at: T1,
      });
      return { store, conversationId, expectedAttempt, cas, journal, candidate };
    };
    const gatedCall: PersistedAgentCallJournalV3 = {
      schema_version: 3,
      call_id: 'call-gated',
      call_index: 1,
      name: 'write_file',
      arguments_sha256: '7'.repeat(64),
      safe_summary_key: 'agent.write_file',
      access: 'conversation_confirm',
      approval_token: 'opaque-approval-token',
      approval_decision: 'pending',
      approval_reference: null,
      idempotency_key: null,
      native_row_revision: null,
      receipt: null,
    };
    const gated = setup(gatedCall);
    const beforeEvents = gated.store.getState().sessionEvents;
    const gatedTransaction = gated.store.advanceAgentCall({
      cas: gated.cas,
      expectedAttempt: gated.expectedAttempt,
      journal: gated.candidate('approval_pending'),
    });
    expect(gatedTransaction).not.toBeNull();
    expect(gated.store.getState().sessionEvents).toBe(beforeEvents);
    expect(
      gated.store.getState().conversations[gated.conversationId]!.attempts[0]!.agent,
    ).toMatchObject({
      phase: 'approval_pending',
      controller_generation: 5,
      call_index: 1,
      reserved_write_bytes: 17,
    });
    expect(gatedTransaction?.rollback()).toBe(true);
    expect(
      gated.store.getState().conversations[gated.conversationId]!.attempts[0],
    ).toBe(gated.expectedAttempt);

    const autoCall: PersistedAgentCallJournalV3 = {
      ...gatedCall,
      call_id: 'call-auto',
      name: 'read_file',
      safe_summary_key: 'agent.read_file',
      access: 'auto',
      approval_token: null,
    };
    const automatic = setup(autoCall);
    const automaticTransaction = automatic.store.advanceAgentCall({
      cas: automatic.cas,
      expectedAttempt: automatic.expectedAttempt,
      journal: automatic.candidate('batch_frozen'),
    });
    expect(automaticTransaction).not.toBeNull();
    expect(automaticTransaction?.commit(nativeCommittedProof(automatic.store, 2))).toBe(true);
    expect(
      automatic.store.getState().conversations[automatic.conversationId]!.attempts[0]!.agent,
    ).toMatchObject({ phase: 'batch_frozen', call_index: 1 });

    const deniedReceipt: PersistedAgentCallJournalV3 = {
      ...gatedCall,
      call_id: 'call-denied',
      name: 'unknown_tool',
      safe_summary_key: 'agent.unknown',
      access: 'durable_deny',
      approval_token: null,
      approval_decision: 'denied',
      idempotency_key: null,
      native_row_revision: 1,
      receipt: {
        schema_version: 1,
        call_id: 'call-denied',
        name: 'unknown_tool',
        arguments_sha256: gatedCall.arguments_sha256,
        result_sha256: '8'.repeat(64),
        result_bytes: 0,
        truncated: false,
        duration_ms: 0,
        outcome: 'denied',
        failure_code: 'E_AGENT_UNKNOWN_TOOL',
        approval_reference: null,
      },
    };
    const skipped = setup(autoCall, [deniedReceipt]);
    const skippedTransaction = skipped.store.advanceAgentCall({
      cas: skipped.cas,
      expectedAttempt: skipped.expectedAttempt,
      journal: skipped.candidate('batch_frozen'),
    });
    expect(skippedTransaction).not.toBeNull();
    expect(
      skipped.store.getState().conversations[skipped.conversationId]!.attempts[0]!.agent?.call_index,
    ).toBe(2);

    const drifted = setup(autoCall);
    expect(drifted.store.advanceAgentCall({
      cas: drifted.cas,
      expectedAttempt: drifted.expectedAttempt,
      journal: {
        ...drifted.candidate('batch_frozen'),
        batch: drifted.journal.batch.map((call, index) =>
          index === 1 ? { ...call, arguments_sha256: '9'.repeat(64) } : call,
        ),
      },
    })).toBeNull();
    expect(drifted.store.advanceAgentCall({
      cas: drifted.cas,
      expectedAttempt: drifted.expectedAttempt,
      journal: drifted.candidate('batch_frozen', drifted.journal.batch.length),
    })).toBeNull();
    expect(drifted.store.advanceAgentCall({
      cas: drifted.cas,
      expectedAttempt: { ...drifted.expectedAttempt },
      journal: drifted.candidate('batch_frozen'),
    })).toBeNull();
    expect(drifted.store.advanceAgentCall({
      cas: { ...drifted.cas, expected_journal_revision: 3 },
      expectedAttempt: drifted.expectedAttempt,
      journal: drifted.candidate('batch_frozen'),
    })).toBeNull();

    // The controller stamps the advance journal from its own clock and the
    // store must not demand that its own clock agree to the millisecond.
    // Reading the clock twice refused roughly one advance in ten whenever a
    // millisecond boundary fell between the reads, and the run then stopped
    // after the first tool of a batch with E_AGENT_CONFLICT. The checkpoint
    // carries the journal's time, not a second reading.
    const laterClock = setup(autoCall, [], () => T2);
    const laterTransaction = laterClock.store.advanceAgentCall({
      cas: laterClock.cas,
      expectedAttempt: laterClock.expectedAttempt,
      journal: laterClock.candidate('batch_frozen'),
    });
    expect(laterTransaction).not.toBeNull();
    expect(
      laterClock.store.getState().conversations[laterClock.conversationId]!.attempts[0]!.agent,
    ).toMatchObject({ phase: 'batch_frozen', call_index: 1, updated_at: T1 });

    const settledNext: PersistedAgentCallJournalV3 = {
      ...autoCall,
      idempotency_key: 'a'.repeat(64),
      native_row_revision: 1,
      receipt: {
        schema_version: 1,
        call_id: autoCall.call_id,
        name: autoCall.name,
        arguments_sha256: autoCall.arguments_sha256,
        result_sha256: 'b'.repeat(64),
        result_bytes: 4,
        truncated: false,
        duration_ms: 1,
        outcome: 'ok',
        failure_code: null,
        approval_reference: null,
      },
    };
    const exhausted = setup(settledNext);
    expect(exhausted.store.advanceAgentCall({
      cas: exhausted.cas,
      expectedAttempt: exhausted.expectedAttempt,
      journal: exhausted.candidate('batch_frozen'),
    })).toBeNull();

    const missing = setup(autoCall);
    expect(missing.store.advanceAgentCall({
      cas: missing.cas,
      expectedAttempt: missing.expectedAttempt,
      journal: {
        ...missing.candidate('batch_frozen'),
        batch: missing.journal.batch.map((call, index) =>
          index === 0 ? { ...call, receipt: null } : call,
        ),
      },
    })).toBeNull();

    expect(drifted.store.advanceAgentCall({
      cas: drifted.cas,
      expectedAttempt: drifted.expectedAttempt,
      journal: drifted.candidate('batch_frozen'),
      evidence: {},
    } as unknown as Parameters<ChatStore['advanceAgentCall']>[0])).toBeNull();
  });
});

describe('framework-neutral chat store', () => {
  test('provides deterministic high-level operations and subscriptions', () => {
    const times = [T0, T1, T2, T3];
    const ids = ['conversation-1', 'message-1', 'message-2'];
    const listener = jest.fn();
    const store = createChatStore({
      now: () => times.shift() ?? T3,
      createId: () => ids.shift() ?? 'fallback',
    });
    const unsubscribe = store.subscribe(listener);

    const conversationId = store.createConversation();
    expect(conversationId).toBe('conversation-1');
    expect(
      store.appendUserMessage(conversationId, '', {
        attachments: [IMAGE_ATTACHMENT],
      }),
    ).toBe('message-1');
    expect(
      store.appendAssistantMessage(conversationId, 'Running locally', {
        metadata: { modelId: 'deepseek-v4-flash', latencyMs: 120 },
      }),
    ).toBe('message-2');
    store.setModel(conversationId, 'deepseek-v4-pro');
    store.setThinkingMode(conversationId, 'max');

    expect(listener).toHaveBeenCalledTimes(5);
    expect(selectActiveConversation(store.getState())?.modelId).toBe(
      'deepseek-v4-pro',
    );
    expect(selectActiveConversation(store.getState())?.thinkingMode).toBe(
      'max',
    );
    expect(selectActiveMessages(store.getState())).toHaveLength(2);

    const serialized = store.serialize();
    unsubscribe();
    store.deleteConversation(conversationId);
    expect(listener).toHaveBeenCalledTimes(5);
    store.hydrate(serialized);
    expect(selectActiveMessages(store.getState())).toHaveLength(2);
  });

  test('exposes project binding operations', () => {
    const times = [T0, T1, T2];
    const store = createChatStore({
      now: () => times.shift() ?? T2,
      createId: () => 'conversation-project',
    });

    const conversationId = store.createConversation({
      projectId: 'project-a',
    });
    expect(selectActiveConversation(store.getState())?.projectId).toBe(
      'project-a',
    );

    store.bindConversationToProject(conversationId, 'project-b');
    expect(selectActiveConversation(store.getState())?.projectId).toBe(
      'project-b',
    );

    store.unbindConversationFromProject(conversationId);
    expect(selectActiveConversation(store.getState())?.projectId).toBeNull();
  });

  test('exposes workspace binding operations', () => {
    const times = [T0, T1, T2];
    const store = createChatStore({
      now: () => times.shift() ?? T2,
      createId: () => 'conversation-workspace',
    });

    const conversationId = store.createConversation({
      workspaceId: 'ws-alpha',
    });
    expect(selectActiveConversation(store.getState())?.workspaceId).toBe(
      'ws-alpha',
    );

    store.bindConversationToWorkspace(conversationId, 'ws-beta');
    expect(selectActiveConversation(store.getState())?.workspaceId).toBe(
      'ws-beta',
    );

    store.unbindConversationFromWorkspace(conversationId);
    expect(selectActiveConversation(store.getState())?.workspaceId).toBeNull();
  });
});

describe('workspace binding persistence', () => {
  function workspaceBoundState(): ChatState {
    let state = createConversation(createEmptyChatState(), 'chat-a', T0, false);
    state = chatReducer(state, {
      type: 'conversation/create',
      payload: { id: 'chat-b', at: T1, select: false, workspaceId: 'ws-beta' },
    });
    state = chatReducer(state, {
      type: 'conversation/bind-workspace',
      payload: { id: 'chat-a', workspaceId: 'ws-alpha', at: T0 },
    });
    state = appendUser(state, 'chat-a', 'u1', 'Work in this folder?', T2);
    state = chatReducer(state, {
      type: 'conversation/select',
      payload: { id: 'chat-a' },
    });
    return state;
  }

  test('binds workspaces per conversation and rejects invalid ids', () => {
    const state = workspaceBoundState();
    expect(state.conversations['chat-a']?.workspaceId).toBe('ws-alpha');
    expect(state.conversations['chat-b']?.workspaceId).toBe('ws-beta');

    for (const invalidWorkspaceId of ['', '   ', 'x'.repeat(257), 42]) {
      const rejected = chatReducer(state, {
        type: 'conversation/bind-workspace',
        payload: {
          id: 'chat-a',
          // Intentionally invalid input; the reducer must not adopt it.
          workspaceId: invalidWorkspaceId as unknown as string,
          at: T3,
        },
      });
      expect(rejected).toBe(state);
    }

    const rebound = chatReducer(state, {
      type: 'conversation/unbind-workspace',
      payload: { id: 'chat-a', at: T3 },
    });
    expect(rebound.conversations['chat-a']?.workspaceId).toBeNull();
    expect(rebound.conversations['chat-b']?.workspaceId).toBe('ws-beta');

    const alreadyUnbound = chatReducer(rebound, {
      type: 'conversation/unbind-workspace',
      payload: { id: 'chat-a', at: T3 },
    });
    expect(alreadyUnbound).toBe(rebound);
  });

  test('persists current-schema workspace ids deterministically', () => {
    const state = workspaceBoundState();
    const first = serializeChatState(state);
    const second = serializeChatState(state);
    const decoded = JSON.parse(first) as {
      schema_version: number;
      conversations: Array<{ id: string; workspace_id: string | null }>;
    };

    expect(first).toBe(second);
    expect(decoded.schema_version).toBe(CHAT_STATE_SCHEMA_VERSION);
    expect(decoded.conversations[0]).toMatchObject({
      id: 'chat-a',
      workspace_id: 'ws-alpha',
    });
    expect(decoded.conversations[1]).toMatchObject({
      id: 'chat-b',
      workspace_id: 'ws-beta',
    });
  });

  test('round-trips bound workspaces through hydration', () => {
    const state = workspaceBoundState();
    const hydrated = hydrateChatState(serializeChatState(state));
    expect(hydrated).toEqual(state);
    expect(serializeChatState(hydrated)).toBe(serializeChatState(state));
  });

  test('deterministically migrates schema v4 conversations as unbound', () => {
    const legacy = JSON.parse(serializeChatState(workspaceBoundState())) as {
      schema_version: number;
      conversations: Array<Record<string, unknown>>;
    };
    stripSchema9Fields(legacy);
    legacy.schema_version = 4;
    legacy.conversations.forEach(conversation => {
      delete conversation.workspace_id;
      delete conversation.runtime_context_id;
      delete conversation.project_context;
      delete conversation.turns;
      delete conversation.attempts;
    });

    const first = hydrateChatState(legacy);
    const second = hydrateChatState(JSON.stringify(legacy));
    expect(first).toEqual(second);
    expect(first.schemaVersion).toBe(CHAT_STATE_SCHEMA_VERSION);
    expect(first).toMatchObject({
      projectContextDestructiveEpoch: 0,
      projectContextDestructiveTransition: null,
    });
    expect(
      Object.values(first.conversations).every(
        conversation => conversation.workspaceId === null,
      ),
    ).toBe(true);

    const migrated = JSON.parse(serializeChatState(first)) as {
      schema_version: number;
      conversations: Array<{ workspace_id: string | null }>;
    };
    expect(migrated.schema_version).toBe(CHAT_STATE_SCHEMA_VERSION);
    expect(
      migrated.conversations.every(
        conversation => conversation.workspace_id === null,
      ),
    ).toBe(true);
  });

  test('strictly validates the required v6 workspace_id field', () => {
    const missing = JSON.parse(serializeChatState(workspaceBoundState())) as {
      conversations: Array<Record<string, unknown>>;
    };
    delete missing.conversations[0]?.workspace_id;
    expect(() => hydrateChatState(missing)).toThrow(/workspace_id/);

    for (const invalidWorkspaceId of ['', '   ', 'x'.repeat(257), 42]) {
      const invalid = JSON.parse(serializeChatState(workspaceBoundState())) as {
        conversations: Array<Record<string, unknown>>;
      };
      invalid.conversations[0]!.workspace_id = invalidWorkspaceId;
      expect(() => hydrateChatState(invalid)).toThrow(/workspace_id/);
    }
  });
});

describe('schema v6 attempts and project context', () => {
  const RUNTIME_ID = '11111111-1111-4111-8111-111111111111';
  const TURN_ID = '22222222-2222-4222-8222-222222222222';
  const ATTEMPT_ID = '33333333-3333-4333-8333-333333333333';
  const RETRY_ID = '44444444-4444-4444-8444-444444444444';
  const ROUND_ID = '55555555-5555-4555-8555-555555555555';
  const PROJECT_ID = '99999999-9999-4999-8999-999999999999';
  const OTHER_PROJECT_ID = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
  const SNAPSHOT_ID = '77777777-7777-4777-8777-777777777777';
  const CONSENT_ID = '88888888-8888-4888-8888-888888888888';
  const REPLACEMENT_SNAPSHOT_ID = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  const REPLACEMENT_CONSENT_ID = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
  const REPLACEMENT_PREPARATION_ID = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
  const LIFECYCLE_ID = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';

  const contextManifest: ProjectContextManifestV1 = {
    schema_version: 1,
    snapshot_id: SNAPSHOT_ID,
    project_id: PROJECT_ID,
    project_name: 'demo',
    branch: 'main',
    head_oid: '0123456789abcdef0123456789abcdef01234567',
    clean: true,
    conflicted: false,
    captured_at: T1,
    policy_version: 'chat-read-v1.0.0',
    provider_host: 'api.deepseek.com',
    model: 'deepseek-v4-flash',
    included: [
      {
        path: 'README.md',
        source: 'tracked_file',
        bytes: 10,
        sha256: '9'.repeat(64),
      },
    ],
    omitted: [],
    context_bytes: 10,
    estimated_tokens: 3,
    snapshot_sha256: 'd'.repeat(64),
    source_fingerprint: 'e'.repeat(64),
  };
  const contextConsent: ProjectContextConsentV1 = {
    schema_version: 1,
    consent_receipt_id: CONSENT_ID,
    snapshot_id: SNAPSHOT_ID,
    snapshot_sha256: 'd'.repeat(64),
    confirmed_at: T2,
  };
  const replacementManifest: ProjectContextManifestV1 = {
    ...contextManifest,
    snapshot_id: REPLACEMENT_SNAPSHOT_ID,
    captured_at: T3,
    included: [
      {
        path: 'src/index.ts',
        source: 'tracked_file',
        bytes: 12,
        sha256: '7'.repeat(64),
      },
    ],
    context_bytes: 12,
    estimated_tokens: 3,
    snapshot_sha256: 'a'.repeat(64),
    source_fingerprint: 'b'.repeat(64),
  };
  const replacementConsent: ProjectContextConsentV1 = {
    schema_version: 1,
    consent_receipt_id: REPLACEMENT_CONSENT_ID,
    snapshot_id: REPLACEMENT_SNAPSHOT_ID,
    snapshot_sha256: 'a'.repeat(64),
    confirmed_at: T3,
  };

  function v6Store() {
    const runtimeIds = [RUNTIME_ID, TURN_ID, ATTEMPT_ID, RETRY_ID];
    let ordinary = 0;
    return createChatStore({
      now: () => T1,
      createId: kind => `${kind}-${++ordinary}`,
      createLifecycleId: () => runtimeIds.shift() ?? ROUND_ID,
    });
  }

  function readyProjectStore(contextBytes = 10) {
    const store = v6Store();
    const conversationId = store.createConversation({ projectId: PROJECT_ID });
    const manifest = {
      ...contextManifest,
      context_bytes: contextBytes,
      estimated_tokens: Math.floor((contextBytes + 3) / 4),
    };
    expect(store.ensureRuntimeContextId(conversationId)).toBe(RUNTIME_ID);
    const prepared = store.replaceProjectContextPrepared(
      projectContextScope(store, conversationId),
      {
        preparationId: REPLACEMENT_PREPARATION_ID,
        selectedPaths: [],
        manifest,
      },
    );
    expect(prepared?.commit()).toBe(true);
    const confirmed = store.replaceProjectContextConfirmed(
      projectContextScope(store, conversationId),
      {
        preparationId: REPLACEMENT_PREPARATION_ID,
        selectedPaths: [],
        manifest,
        consent: contextConsent,
      },
    );
    expect(confirmed?.commit()).toBe(true);
    return { store, conversationId };
  }

  function setupProjectStore() {
    const store = v6Store();
    const conversationId = store.createConversation({ projectId: PROJECT_ID });
    expect(store.ensureRuntimeContextId(conversationId)).toBe(RUNTIME_ID);
    return { store, conversationId };
  }

  function scopedReadyProjectStore(contextBytes = 10) {
    const fixture = readyProjectStore(contextBytes);
    return fixture;
  }

  function schema2Receipt(
    prepared: { turnId: string; attemptId: string },
    overrides: Partial<CompletionRoundReceiptV1> = {},
  ): CompletionRoundReceiptV1 {
    return {
      schemaVersion: 1,
      transportSchemaVersion: 2,
      turnId: prepared.turnId,
      attemptId: prepared.attemptId,
      roundId: ROUND_ID,
      roundIndex: 0,
      providerRequestId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      providerResponseId: 'resp_1',
      requestedModel: 'deepseek-v4-flash',
      model: 'deepseek-v4-flash',
      thinkingMode: 'high',
      finishReason: 'stop',
      latencyMs: 1,
      visibleHistorySha256: 'a'.repeat(64),
      modelInputSha256: 'b'.repeat(64),
      requestBodySha256: 'c'.repeat(64),
      harnessId: 'dsh',
      projectContextReceipt: null,
      ...overrides,
    };
  }

  const harnessCases = [
    ['dsh', 'deepseek-v4-flash'],
    ['glm', 'GLM-5.3-Flash'],
    ['claude-code', 'claude-fable-5-1'],
    ['codex', 'gpt-5.6'],
  ] as const;

  function completedHarnessStore(
    harnessId: CompletionRoundReceiptV1['harnessId'] = 'dsh',
    modelId: CompletionRoundReceiptV1['model'] = 'deepseek-v4-flash',
  ) {
    const store = v6Store();
    const conversationId = store.createConversation({ modelId });
    const prepared = store.prepareTurnAttempt(
      conversationId,
      'harness receipt',
      {
        harnessId,
      },
    )!;
    expect(prepared.commit()).toBe(true);
    expect(
      store.startAttemptRound(conversationId, prepared.attemptId, ROUND_ID, 0),
    ).toBe(true);
    expect(
      store.recordAttemptRound(
        conversationId,
        prepared.attemptId,
        schema2Receipt(prepared, {
          harnessId,
          model: modelId,
          requestedModel: modelId,
        }),
      ),
    ).toBe(true);
    expect(
      store.completeAttempt(conversationId, prepared.attemptId, 'done', {
        metadata: { modelId, latencyMs: 1, finishReason: 'stop' },
      }),
    ).not.toBeNull();
    return { store, conversationId };
  }

  test.each(harnessCases)(
    'round-trips %s identity on a failed attempt without receipts',
    (harnessId, modelId) => {
      const store = v6Store();
      const conversationId = store.createConversation({ modelId });
      const prepared = store.prepareTurnAttempt(
        conversationId,
        'failed request',
        {
          harnessId,
        },
      )!;
      expect(prepared.commit()).toBe(true);
      expect(
        store.failAttempt(
          conversationId,
          prepared.attemptId,
          'E_COMPLETION_MODEL_MISMATCH',
        ),
      ).toBe(true);

      const serialized = store.serialize();
      const hydrated = hydrateChatState(serialized);
      expect(hydrated.conversations[conversationId]?.attempts[0]).toMatchObject(
        {
          harnessId,
          status: 'failed',
          rounds: [],
        },
      );
      expect(hydrated).toEqual(store.getState());
      expect(serializeChatState(hydrated)).toBe(serialized);
    },
  );

  test.each(harnessCases)(
    'round-trips %s identity on a completed attempt and its round receipt',
    (harnessId, modelId) => {
      const { store, conversationId } = completedHarnessStore(
        harnessId,
        modelId,
      );
      const serialized = store.serialize();
      const hydrated = hydrateChatState(serialized);
      expect(hydrated.conversations[conversationId]?.attempts[0]).toMatchObject(
        {
          harnessId,
          status: 'completed',
          rounds: [{ harnessId }],
        },
      );
      expect(hydrated).toEqual(store.getState());
      expect(serializeChatState(hydrated)).toBe(serialized);
    },
  );

  test('defaults absent legacy attempt and receipt harness identity to dsh', () => {
    const { store } = completedHarnessStore();
    const payload = JSON.parse(store.serialize()) as {
      conversations: Array<{
        attempts: Array<{
          harness_id?: string;
          rounds: Array<{ harness_id?: string }>;
        }>;
      }>;
    };
    const attempt = payload.conversations[0]!.attempts[0]!;
    delete attempt.harness_id;
    delete attempt.rounds[0]!.harness_id;

    expect(hydrateChatState(payload)).toEqual(store.getState());
    expect(serializeChatState(hydrateChatState(JSON.stringify(payload)))).toBe(
      store.serialize(),
    );
  });

  test.each(['attempt', 'round receipt'] as const)(
    'rejects hostile optional harness identity on a persisted %s',
    target => {
      const { store } = completedHarnessStore();
      const getter = jest.fn(() => {
        throw new Error('OPTIONAL_HARNESS_GETTER_SENTINEL');
      });
      const setter = jest.fn();
      const descriptors: PropertyDescriptor[] = [
        { enumerable: true, get: getter },
        { enumerable: true, set: setter },
        { enumerable: false, value: 'dsh' },
        { enumerable: true, value: 'unsupported-harness' },
        { enumerable: true, value: null },
      ];
      for (const descriptor of descriptors) {
        const payload = JSON.parse(store.serialize()) as {
          conversations: Array<{
            attempts: Array<
              Record<string, unknown> & {
                rounds: Array<Record<string, unknown>>;
              }
            >;
          }>;
        };
        const attempt = payload.conversations[0]!.attempts[0]!;
        const record = target === 'attempt' ? attempt : attempt.rounds[0]!;
        Object.defineProperty(record, 'harness_id', descriptor);
        const result = safeHydrateChatState(payload);
        expect(result.ok).toBe(false);
        if (!result.ok) {
          expect(result.error).toBeInstanceOf(ChatStateValidationError);
          expect(result.error.path).toBe(
            '$.conversations[0].attempts[0]' +
              (target === 'attempt' ? '' : '.rounds[0]') +
              '.harness_id',
          );
          expect(result.error.message).not.toContain(
            'OPTIONAL_HARNESS_GETTER_SENTINEL',
          );
        }
      }
      expect(getter).not.toHaveBeenCalled();
      expect(setter).not.toHaveBeenCalled();
    },
  );

  function schema6Payload(store: ChatStore) {
    const payload = JSON.parse(store.serialize()) as Record<string, unknown>;
    stripSchema9Fields(payload);
    payload.schema_version = 6;
    delete payload.workspace_authority_outbox;
    delete payload.project_context_destructive_epoch;
    delete payload.project_context_destructive_transition;
    (payload.conversations as Array<Record<string, unknown>>).forEach(row => {
      const source = store.getState().conversations[String(row.id)];
      row.workspace_id = source?.workspaceId ?? null;
      delete row.workspace_binding;
      delete row.workspace_bootstrap_state;
      (row.attempts as Array<Record<string, unknown>> | undefined)?.forEach(
        attempt => {
          delete attempt.workspace_id;
          delete attempt.workspace_binding_revision;
        },
      );
    });
    return payload;
  }

  function schema7IntentPayload(
    store: ChatStore,
    conversationId: string,
    overrides: Record<string, unknown> = {},
  ) {
    const payload = schema6Payload(store);
    const conversation = store.getState().conversations[conversationId]!;
    const snapshot = conversation.projectContext!.snapshot!;
    const consent = conversation.projectContext!.consent;
    payload.schema_version = 7;
    payload.project_context_destructive_epoch = 1;
    payload.project_context_destructive_transition = {
      schema_version: 1,
      lifecycle_id: LIFECYCLE_ID,
      epoch: 1,
      action: 'unbind',
      phase: 'intent',
      conversation_id: conversationId,
      source_project_id: conversation.projectId,
      source_runtime_context_id: conversation.runtimeContextId,
      source_model_id: conversation.modelId,
      snapshot_id: snapshot.snapshot_id,
      snapshot_sha256: snapshot.snapshot_sha256,
      consent_receipt_id: consent?.consent_receipt_id ?? null,
      target_project_id: null,
      created_at: T3,
      updated_at: T3,
      ...overrides,
    };
    return payload;
  }

  test('migrates schema v6 to v7 without changing conversations, attempts, or messages', () => {
    const store = v6Store();
    const conversationId = store.createConversation();
    const prepared = store.prepareTurnAttempt(conversationId, 'preserve me');
    expect(prepared?.commit()).toBe(true);
    const v6 = schema6Payload(store) as {
      conversations: unknown;
      messages: unknown;
    };

    const hydrated = hydrateChatState(v6) as ChatState & {
      projectContextDestructiveEpoch?: number;
      projectContextDestructiveTransition?: unknown;
    };
    expect(hydrated.schemaVersion).toBe(CHAT_STATE_SCHEMA_VERSION);
    expect(hydrated.projectContextDestructiveEpoch).toBe(0);
    expect(hydrated.projectContextDestructiveTransition).toBeNull();
    const serialized = JSON.parse(serializeChatState(hydrated)) as {
      schema_version: number;
      project_context_destructive_epoch: number;
      project_context_destructive_transition: unknown;
      conversations: unknown;
      messages: unknown;
    };
    expect(serialized).toMatchObject({
      schema_version: CHAT_STATE_SCHEMA_VERSION,
      project_context_destructive_epoch: 0,
      project_context_destructive_transition: null,
    });
    const legacyProjection = JSON.parse(
      JSON.stringify(serialized.conversations),
    ) as Array<Record<string, unknown>>;
    legacyProjection.forEach(row => {
      delete row.agent_grants;
      delete row.workspace_binding;
      delete row.workspace_bootstrap_state;
      (row.attempts as Array<Record<string, unknown>>).forEach(attempt => {
        delete attempt.agent;
        delete attempt.journal_revision;
        attempt.schema_version = 1;
        delete attempt.workspace_id;
        delete attempt.workspace_binding_revision;
      });
    });
    expect(legacyProjection).toEqual(v6.conversations);
    expect(serialized.messages).toEqual(v6.messages);
  });

  test('strictly round-trips one metadata-only schema v7 intent journal', () => {
    const { store, conversationId } = readyProjectStore();
    const payload = schema7IntentPayload(store, conversationId);
    const hydrated = hydrateChatState(payload) as ChatState & {
      projectContextDestructiveEpoch: number;
      projectContextDestructiveTransition: {
        lifecycleId: string;
        action: string;
        phase: string;
        snapshotId: string;
        consentReceiptId: string | null;
      } | null;
    };
    expect(hydrated.projectContextDestructiveEpoch).toBe(1);
    expect(hydrated.projectContextDestructiveTransition).toMatchObject({
      lifecycleId: LIFECYCLE_ID,
      action: 'unbind',
      phase: 'intent',
      snapshotId: SNAPSHOT_ID,
      consentReceiptId: CONSENT_ID,
    });
    const serialized = JSON.parse(serializeChatState(hydrated)) as {
      project_context_destructive_transition: Record<string, unknown>;
    };
    expect(
      Object.keys(serialized.project_context_destructive_transition).sort(),
    ).toEqual(
      [
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
      ].sort(),
    );
    expect(serializeChatState(hydrateChatState(serialized))).toBe(
      JSON.stringify(serialized),
    );
    expect(
      JSON.stringify(serialized.project_context_destructive_transition),
    ).not.toMatch(/selected_paths|manifest|content|attachment|native|error/);
  });

  test('accepts exact nullable runtime and consent from a stale source snapshot', () => {
    const { store, conversationId } = readyProjectStore();
    expect(
      store.applyProjectContextAction(conversationId, {
        type: 'project_changed',
      }),
    ).toBe(true);
    const payload = schema7IntentPayload(store, conversationId, {
      source_runtime_context_id: null,
      consent_receipt_id: null,
    });
    const conversations = payload.conversations as Array<
      Record<string, unknown>
    >;
    conversations[0]!.runtime_context_id = null;

    const hydrated = hydrateChatState(payload) as ChatState & {
      projectContextDestructiveTransition: {
        sourceRuntimeContextId: string | null;
        consentReceiptId: string | null;
      } | null;
    };
    expect(hydrated.projectContextDestructiveTransition).toMatchObject({
      sourceRuntimeContextId: null,
      consentReceiptId: null,
    });
  });

  test('rejects hostile and non-exact schema v7 root and journal records', () => {
    const { store, conversationId } = readyProjectStore();
    const cases: unknown[] = [];
    const missingRoot = schema7IntentPayload(store, conversationId);
    delete missingRoot.project_context_destructive_epoch;
    cases.push(missingRoot);
    const extraRoot = schema7IntentPayload(store, conversationId);
    extraRoot.raw_context = 'RAW_CONTEXT_SENTINEL';
    cases.push(extraRoot);
    const extraJournal = schema7IntentPayload(store, conversationId);
    (
      extraJournal.project_context_destructive_transition as Record<
        string,
        unknown
      >
    ).path = '/private/raw-path-sentinel';
    cases.push(extraJournal);
    const symbolJournal = schema7IntentPayload(store, conversationId);
    Object.defineProperty(
      symbolJournal.project_context_destructive_transition as object,
      Symbol('raw'),
      { value: 'RAW_SYMBOL_SENTINEL', enumerable: true },
    );
    cases.push(symbolJournal);
    const exoticJournal = schema7IntentPayload(store, conversationId);
    Object.setPrototypeOf(
      exoticJournal.project_context_destructive_transition as object,
      { raw: true },
    );
    cases.push(exoticJournal);
    const hiddenJournal = schema7IntentPayload(store, conversationId);
    Object.defineProperty(
      hiddenJournal.project_context_destructive_transition as object,
      'action',
      { value: 'unbind', enumerable: false },
    );
    cases.push(hiddenJournal);
    let getterCalls = 0;
    const getterRoot = schema7IntentPayload(store, conversationId);
    Object.defineProperty(
      getterRoot,
      'project_context_destructive_transition',
      {
        enumerable: true,
        get: () => {
          getterCalls += 1;
          throw new Error('RAW_GETTER_SENTINEL');
        },
      },
    );
    cases.push(getterRoot);

    cases.forEach(candidate =>
      expect(() => hydrateChatState(candidate)).toThrow(
        ChatStateValidationError,
      ),
    );
    expect(getterCalls).toBe(0);
  });

  test('rejects invalid schema v7 journal bounds, identities, and relations', () => {
    const { store, conversationId } = readyProjectStore();
    const invalidOverrides: Array<Record<string, unknown>> = [
      { lifecycle_id: 'not-a-uuid' },
      { epoch: 0 },
      { action: 'destroy' },
      { phase: 'done' },
      { source_project_id: '' },
      { source_runtime_context_id: 'not-a-uuid' },
      { source_model_id: 'secret-model' },
      { snapshot_id: OTHER_PROJECT_ID },
      { snapshot_sha256: 'A'.repeat(64) },
      { consent_receipt_id: OTHER_PROJECT_ID },
      { target_project_id: PROJECT_ID },
      { created_at: 'not-a-time' },
      { updated_at: T0 },
      { conversation_id: 'missing-conversation' },
    ];
    invalidOverrides.forEach(overrides =>
      expect(() =>
        hydrateChatState(
          schema7IntentPayload(store, conversationId, overrides),
        ),
      ).toThrow(ChatStateValidationError),
    );

    expect(() =>
      hydrateChatState(
        schema7IntentPayload(store, conversationId, {
          action: 'rebind',
          target_project_id: null,
        }),
      ),
    ).toThrow(ChatStateValidationError);
    expect(() =>
      hydrateChatState(
        schema7IntentPayload(store, conversationId, {
          action: 'rebind',
          target_project_id: PROJECT_ID,
        }),
      ),
    ).toThrow(ChatStateValidationError);
  });

  test('rejects lifecycle checkpoints with impossible phase timestamp relationships', () => {
    const fixture = readyProjectStore();
    expect(() =>
      hydrateChatState(
        schema7IntentPayload(fixture.store, fixture.conversationId, {
          updated_at: '9999-12-31T23:59:59.999Z',
        }),
      ),
    ).toThrow(ChatStateValidationError);
    expect(() =>
      hydrateChatState(
        schema7IntentPayload(fixture.store, fixture.conversationId, {
          created_at: T0,
          updated_at: T0,
        }),
      ),
    ).toThrow(ChatStateValidationError);

    const begun = beginLifecycle(fixture.store, fixture.conversationId)!;
    expect(begun.commit()).toBe(true);
    const tombstone = tombstoneLifecycle(
      fixture.store,
      begun.lifecycleId,
      begun.epoch,
    )!;
    expect(tombstone.commit()).toBe(true);
    const cleanupPending = JSON.parse(fixture.store.serialize()) as {
      conversations: Array<Record<string, unknown>>;
      project_context_destructive_transition: Record<string, unknown>;
    };
    cleanupPending.project_context_destructive_transition.updated_at = T2;
    expect(() => hydrateChatState(cleanupPending)).toThrow(
      ChatStateValidationError,
    );

    const ready = cleanupLifecycle(
      fixture.store,
      begun.lifecycleId,
      begun.epoch,
    )!;
    expect(ready.commit()).toBe(true);
    const readyPayload = JSON.parse(fixture.store.serialize()) as {
      conversations: Array<Record<string, unknown>>;
    };
    readyPayload.conversations[0]!.updated_at = T2;
    expect(() => hydrateChatState(readyPayload)).toThrow(
      ChatStateValidationError,
    );
  });

  test('rejects root epoch edge cases, owner drift, lifecycle collisions, and journal accessors', () => {
    const { store, conversationId } = readyProjectStore();
    for (const epoch of [-1, -0, Number.MAX_SAFE_INTEGER + 1]) {
      const payload = schema7IntentPayload(store, conversationId);
      payload.project_context_destructive_epoch = epoch;
      expect(() => hydrateChatState(payload)).toThrow(ChatStateValidationError);
    }
    const mismatch = schema7IntentPayload(store, conversationId);
    mismatch.project_context_destructive_epoch = 2;
    expect(() => hydrateChatState(mismatch)).toThrow(ChatStateValidationError);
    for (const overrides of [
      { source_project_id: OTHER_PROJECT_ID },
      { source_runtime_context_id: OTHER_PROJECT_ID },
      { source_model_id: 'deepseek-v4-pro' },
      { lifecycle_id: RUNTIME_ID },
    ]) {
      expect(() =>
        hydrateChatState(
          schema7IntentPayload(store, conversationId, overrides),
        ),
      ).toThrow(ChatStateValidationError);
    }

    let getterCalls = 0;
    const nestedGetter = schema7IntentPayload(store, conversationId);
    Object.defineProperty(
      nestedGetter.project_context_destructive_transition as object,
      'snapshot_id',
      {
        enumerable: true,
        get: () => {
          getterCalls += 1;
          throw new Error('RAW_NESTED_GETTER');
        },
      },
    );
    expect(() => hydrateChatState(nestedGetter)).toThrow(
      ChatStateValidationError,
    );
    const epochGetter = schema7IntentPayload(store, conversationId);
    Object.defineProperty(epochGetter, 'project_context_destructive_epoch', {
      enumerable: true,
      get: () => {
        getterCalls += 1;
        throw new Error('RAW_EPOCH_GETTER');
      },
    });
    expect(() => hydrateChatState(epochGetter)).toThrow(
      ChatStateValidationError,
    );
    expect(getterCalls).toBe(0);
  });

  test('round-trips cleanup, ready, and finalized lifecycle checkpoints', () => {
    const { store, conversationId } = readyProjectStore();
    const begun = beginLifecycle(store, conversationId)!;
    expect(begun.commit()).toBe(true);
    const tombstone = tombstoneLifecycle(
      store,
      begun.lifecycleId,
      begun.epoch,
    )!;
    expect(tombstone.commit()).toBe(true);
    expect(hydrateChatState(store.serialize())).toEqual(store.getState());
    const ready = cleanupLifecycle(store, begun.lifecycleId, begun.epoch)!;
    expect(ready.commit()).toBe(true);
    expect(hydrateChatState(store.serialize())).toEqual(store.getState());
    const finalize = finalizeLifecycle(store, begun.lifecycleId, begun.epoch)!;
    expect(finalize.commit()).toBe(true);
    const finalized = hydrateChatState(store.serialize());
    expect(finalized).toMatchObject({
      projectContextDestructiveEpoch: 1,
      projectContextDestructiveTransition: null,
    });
  });

  test('rejects hydrated lifecycle journals whose snapshot gains an attempt reference', () => {
    const { store, conversationId } = readyProjectStore();
    const prepared = store.prepareTurnAttempt(
      conversationId,
      'persisted lifecycle reference',
    );
    expect(prepared?.commit()).toBe(true);
    expect(() =>
      hydrateChatState(schema7IntentPayload(store, conversationId)),
    ).toThrow(ChatStateValidationError);
  });

  type LifecycleTransactionHarness = {
    lifecycleId: string;
    epoch: number;
    commit(): boolean;
    rollback(): boolean;
  };

  type LifecycleAdvanceScopeHarness = {
    lifecycleId: string;
    epoch: number;
    action: 'unbind' | 'delete' | 'rebind';
    targetProjectId: string | null;
    expectedTransition: NonNullable<
      ChatState['projectContextDestructiveTransition']
    >;
  };

  type LifecycleStoreHarness = ChatStore & {
    beginProjectContextDestructiveTransition(input: {
      lifecycleId: string;
      action: 'unbind' | 'delete' | 'rebind';
      targetProjectId: string | null;
      owner: {
        conversationId: string;
        projectId: string;
        runtimeContextId: string | null;
        modelId: string;
        expectedUpdatedAt: string;
        expectedContext: NonNullable<
          ChatState['conversations'][string]['projectContext']
        >;
      };
    }): LifecycleTransactionHarness | null;
    tombstoneProjectContextDestructiveTransition(
      scope: LifecycleAdvanceScopeHarness,
    ): LifecycleTransactionHarness | null;
    markProjectContextDestructiveCleanupComplete(
      scope: LifecycleAdvanceScopeHarness,
    ): LifecycleTransactionHarness | null;
    finalizeProjectContextDestructiveTransition(
      scope: LifecycleAdvanceScopeHarness,
    ): LifecycleTransactionHarness | null;
  };

  type SnapshotFreeMutationHarness = ChatStore & {
    applySnapshotFreeProjectMutation(input: {
      action: 'unbind' | 'delete' | 'rebind';
      conversationId: string;
      targetProjectId: string | null;
      expectedConversation: ChatState['conversations'][string];
    }): {
      conversationId: string;
      action: 'unbind' | 'delete' | 'rebind';
      commit(): boolean;
      rollback(): boolean;
    } | null;
  };

  function snapshotFreeStore(store: ChatStore): SnapshotFreeMutationHarness {
    return store as SnapshotFreeMutationHarness;
  }

  function lifecycleStore(store: ChatStore): LifecycleStoreHarness {
    return store as LifecycleStoreHarness;
  }

  function lifecycleAdvanceScope(
    store: ChatStore,
    lifecycleId: string,
    epoch: number,
    expectedTransition = store.getState().projectContextDestructiveTransition!,
  ): LifecycleAdvanceScopeHarness {
    return {
      lifecycleId,
      epoch,
      action: expectedTransition.action,
      targetProjectId: expectedTransition.targetProjectId,
      expectedTransition,
    };
  }

  function tombstoneLifecycle(
    store: ChatStore,
    lifecycleId: string,
    epoch: number,
  ) {
    return lifecycleStore(store).tombstoneProjectContextDestructiveTransition(
      lifecycleAdvanceScope(store, lifecycleId, epoch),
    );
  }

  function cleanupLifecycle(
    store: ChatStore,
    lifecycleId: string,
    epoch: number,
  ) {
    return lifecycleStore(store).markProjectContextDestructiveCleanupComplete(
      lifecycleAdvanceScope(store, lifecycleId, epoch),
    );
  }

  function finalizeLifecycle(
    store: ChatStore,
    lifecycleId: string,
    epoch: number,
    expectedTransition?: NonNullable<
      ChatState['projectContextDestructiveTransition']
    >,
  ) {
    return lifecycleStore(store).finalizeProjectContextDestructiveTransition(
      lifecycleAdvanceScope(store, lifecycleId, epoch, expectedTransition),
    );
  }

  function beginLifecycle(
    store: ChatStore,
    conversationId: string,
    action: 'unbind' | 'delete' | 'rebind' = 'unbind',
    targetProjectId: string | null = null,
    lifecycleId = LIFECYCLE_ID,
  ) {
    const conversation = store.getState().conversations[conversationId]!;
    return lifecycleStore(store).beginProjectContextDestructiveTransition({
      lifecycleId,
      action,
      targetProjectId,
      owner: {
        conversationId,
        projectId: conversation.projectId!,
        runtimeContextId: conversation.runtimeContextId,
        modelId: conversation.modelId,
        expectedUpdatedAt: conversation.updatedAt,
        expectedContext: conversation.projectContext!,
      },
    });
  }

  function advanceLifecycleToReady(
    store: ChatStore,
    conversationId: string,
    action: 'unbind' | 'delete' | 'rebind' = 'unbind',
    targetProjectId: string | null = null,
  ) {
    const begun = beginLifecycle(
      store,
      conversationId,
      action,
      targetProjectId,
    )!;
    expect(begun.commit()).toBe(true);
    const tombstone = tombstoneLifecycle(
      store,
      begun.lifecycleId,
      begun.epoch,
    )!;
    expect(tombstone.commit()).toBe(true);
    const ready = cleanupLifecycle(store, begun.lifecycleId, begun.epoch)!;
    expect(ready.commit()).toBe(true);
    return ready;
  }

  test('creates one global intent journal and preserves unrelated listener changes on rollback', () => {
    const { store, conversationId } = readyProjectStore();
    const unrelated = store.createConversation({
      title: 'Unrelated before',
      select: false,
    });
    const notifications: number[] = [];
    let reentered = false;
    store.subscribe(() => {
      throw new Error('listener sentinel');
    });
    store.subscribe(state => {
      notifications.push(state.conversationOrder.length);
      if (!reentered && state.projectContextDestructiveTransition !== null) {
        reentered = true;
        store.renameConversation(unrelated, 'Unrelated after');
      }
    });

    const transaction = beginLifecycle(store, conversationId);
    expect(transaction).not.toBeNull();
    expect(store.getState()).toMatchObject({
      projectContextDestructiveEpoch: 1,
      projectContextDestructiveTransition: {
        lifecycleId: LIFECYCLE_ID,
        epoch: 1,
        action: 'unbind',
        phase: 'intent',
        conversationId,
      },
    });
    expect(beginLifecycle(store, conversationId)).toBeNull();
    expect(transaction?.rollback()).toBe(true);
    expect(transaction?.rollback()).toBe(false);
    expect(transaction?.commit()).toBe(false);
    expect(store.getState()).toMatchObject({
      projectContextDestructiveEpoch: 0,
      projectContextDestructiveTransition: null,
    });
    expect(store.getState().conversations[unrelated]?.title).toBe(
      'Unrelated after',
    );
    expect(notifications.length).toBeGreaterThanOrEqual(3);
  });

  test('rejects lifecycle advancement reentered from begin notification', () => {
    const { store, conversationId } = readyProjectStore();
    let nested: LifecycleTransactionHarness | null | undefined;
    store.subscribe(state => {
      const transition = state.projectContextDestructiveTransition;
      if (transition?.phase === 'intent' && nested === undefined) {
        nested = tombstoneLifecycle(
          store,
          transition.lifecycleId,
          transition.epoch,
        );
        store.dispatch({
          type: 'project-context-destructive/tombstone',
          payload: {
            scope: lifecycleAdvanceScope(
              store,
              transition.lifecycleId,
              transition.epoch,
              transition,
            ),
            at: T2,
          },
        });
      }
    });

    const begun = beginLifecycle(store, conversationId);
    expect(begun).not.toBeNull();
    expect(nested).toBeNull();
    expect(store.getState()).toMatchObject({
      projectContextDestructiveTransition: { phase: 'intent' },
      conversations: {
        [conversationId]: {
          projectContext: { snapshot: { snapshot_id: SNAPSHOT_ID } },
        },
      },
    });
  });

  test('tombstone and cleanup-complete transactions roll back to their exact prior phases', () => {
    const { store, conversationId } = readyProjectStore();
    const begun = beginLifecycle(store, conversationId)!;
    expect(begun.commit()).toBe(true);
    const sourceContext =
      store.getState().conversations[conversationId]!.projectContext;

    const tombstone = tombstoneLifecycle(
      store,
      begun.lifecycleId,
      begun.epoch,
    )!;
    expect(store.getState()).toMatchObject({
      projectContextDestructiveTransition: { phase: 'cleanup_pending' },
      conversations: {
        [conversationId]: {
          projectId: PROJECT_ID,
          projectContext: { status: 'setup_required', snapshot: null },
        },
      },
    });
    expect(tombstone.rollback()).toBe(true);
    expect(store.getState().conversations[conversationId]?.projectContext).toBe(
      sourceContext,
    );
    expect(store.getState()).toMatchObject({
      projectContextDestructiveTransition: { phase: 'intent' },
    });

    const tombstoneAgain = tombstoneLifecycle(
      store,
      begun.lifecycleId,
      begun.epoch,
    )!;
    expect(tombstoneAgain.commit()).toBe(true);
    const cleanup = cleanupLifecycle(store, begun.lifecycleId, begun.epoch)!;
    expect(store.getState()).toMatchObject({
      projectContextDestructiveTransition: { phase: 'ready_to_finalize' },
    });
    expect(cleanup.rollback()).toBe(true);
    expect(store.getState()).toMatchObject({
      projectContextDestructiveTransition: { phase: 'cleanup_pending' },
    });
    expect(cleanup.commit()).toBe(false);
  });

  test.each([
    { action: 'unbind' as const, targetProjectId: null },
    { action: 'rebind' as const, targetProjectId: OTHER_PROJECT_ID },
  ])('finalizes $action and clears the journal atomically', fixture => {
    const { store, conversationId } = readyProjectStore();
    const ready = advanceLifecycleToReady(
      store,
      conversationId,
      fixture.action,
      fixture.targetProjectId,
    );
    const finalize = finalizeLifecycle(store, ready.lifecycleId, ready.epoch)!;
    expect(finalize).not.toBeNull();
    expect(store.getState().projectContextDestructiveTransition).toBeNull();
    expect(store.getState().projectContextDestructiveEpoch).toBe(1);
    expect(store.getState().conversations[conversationId]).toMatchObject(
      fixture.action === 'unbind'
        ? { projectId: null, projectContext: null }
        : {
            projectId: OTHER_PROJECT_ID,
            projectContext: {
              projectId: OTHER_PROJECT_ID,
              status: 'setup_required',
              snapshot: null,
            },
          },
    );
    expect(finalize.rollback()).toBe(true);
    expect(store.getState()).toMatchObject({
      projectContextDestructiveTransition: { phase: 'ready_to_finalize' },
      conversations: {
        [conversationId]: { projectId: PROJECT_ID },
      },
    });
  });

  test('finalize delete preserves a nonactive selection and restores it exactly on rollback', () => {
    const { store, conversationId } = readyProjectStore();
    const selected = store.createConversation({ title: 'Keep selected' });
    const ready = advanceLifecycleToReady(store, conversationId, 'delete');
    const finalize = finalizeLifecycle(store, ready.lifecycleId, ready.epoch)!;
    expect(store.getState().conversations[conversationId]).toBeUndefined();
    expect(store.getState().selectedConversationId).toBe(selected);
    expect(finalize.rollback()).toBe(true);
    expect(store.getState().conversations[conversationId]).toBeDefined();
    expect(store.getState().selectedConversationId).toBe(selected);

    const activeFixture = readyProjectStore();
    const fallback = activeFixture.store.createConversation({
      title: 'Fallback',
      select: false,
    });
    activeFixture.store.selectConversation(activeFixture.conversationId);
    const activeReady = advanceLifecycleToReady(
      activeFixture.store,
      activeFixture.conversationId,
      'delete',
    );
    const activeFinalize = finalizeLifecycle(
      activeFixture.store,
      activeReady.lifecycleId,
      activeReady.epoch,
    )!;
    expect(activeFixture.store.getState().selectedConversationId).toBe(
      fallback,
    );
    expect(activeFinalize.commit()).toBe(true);
  });

  test('rejects begin without a snapshot, with active preparation, or with an exact-retry reference', () => {
    const setup = setupProjectStore();
    expect(beginLifecycle(setup.store, setup.conversationId)).toBeNull();

    const preparedFixture = setupProjectStore();
    const prepared = preparedFixture.store.replaceProjectContextPrepared(
      projectContextScope(
        preparedFixture.store,
        preparedFixture.conversationId,
      ),
      {
        preparationId: REPLACEMENT_PREPARATION_ID,
        selectedPaths: [],
        manifest: contextManifest,
      },
    );
    expect(prepared?.commit()).toBe(true);
    expect(
      beginLifecycle(preparedFixture.store, preparedFixture.conversationId),
    ).toBeNull();

    const retryFixture = readyProjectStore();
    const attempt = retryFixture.store.prepareTurnAttempt(
      retryFixture.conversationId,
      'frozen retry',
    );
    expect(attempt?.commit()).toBe(true);
    expect(
      retryFixture.store.failAttempt(
        retryFixture.conversationId,
        attempt!.attemptId,
        'E_COMPLETION_NATIVE',
      ),
    ).toBe(true);
    expect(
      beginLifecycle(retryFixture.store, retryFixture.conversationId),
    ).toBeNull();
  });

  test('fails closed for malformed or mismatched-owner bindings that reference the cleanup snapshot', () => {
    const makeCorruptStore = (extra: Record<string, unknown>) => {
      const fixture = readyProjectStore();
      const prepared = fixture.store.prepareTurnAttempt(
        fixture.conversationId,
        'corrupt binding reference',
      );
      expect(prepared?.commit()).toBe(true);
      const state = fixture.store.getState();
      const conversation = state.conversations[fixture.conversationId]!;
      const attempt = conversation.attempts[0]!;
      return {
        conversationId: fixture.conversationId,
        store: createChatStore({
          initialState: {
            ...state,
            conversations: {
              ...state.conversations,
              [fixture.conversationId]: {
                ...conversation,
                attempts: [
                  {
                    ...attempt,
                    projectContext: {
                      ...attempt.projectContext!,
                      ...extra,
                    },
                  },
                ],
              },
            },
          },
        }),
      };
    };

    const mismatched = makeCorruptStore({
      projectId: OTHER_PROJECT_ID,
      runtimeContextId: OTHER_PROJECT_ID,
    });
    expect(
      beginLifecycle(mismatched.store, mismatched.conversationId),
    ).toBeNull();

    const malformed = makeCorruptStore({ raw_content: 'RAW_BINDING_SENTINEL' });
    expect(
      beginLifecycle(malformed.store, malformed.conversationId),
    ).toBeNull();

    const wrongDisposition = makeCorruptStore({});
    const wrongDispositionState = wrongDisposition.store.getState();
    const wrongDispositionConversation =
      wrongDispositionState.conversations[wrongDisposition.conversationId]!;
    const wrongDispositionAttempt = wrongDispositionConversation.attempts[0]!;
    const wrongDispositionStore = createChatStore({
      initialState: {
        ...wrongDispositionState,
        conversations: {
          ...wrongDispositionState.conversations,
          [wrongDisposition.conversationId]: {
            ...wrongDispositionConversation,
            attempts: [
              {
                ...wrongDispositionAttempt,
                contextDisposition: 'explicit_without_context',
              },
            ],
          },
        },
      },
    });
    expect(
      beginLifecycle(wrongDispositionStore, wrongDisposition.conversationId),
    ).toBeNull();

    const unknownStatus = makeCorruptStore({});
    const unknownStatusState = unknownStatus.store.getState();
    const unknownStatusConversation =
      unknownStatusState.conversations[unknownStatus.conversationId]!;
    const unknownStatusAttempt = unknownStatusConversation.attempts[0]!;
    const unknownStatusStore = createChatStore({
      initialState: {
        ...unknownStatusState,
        conversations: {
          ...unknownStatusState.conversations,
          [unknownStatus.conversationId]: {
            ...unknownStatusConversation,
            attempts: [{ ...unknownStatusAttempt, status: 'unknown-status' }],
          },
        },
      } as ChatState,
    });
    expect(
      beginLifecycle(unknownStatusStore, unknownStatus.conversationId),
    ).toBeNull();
  });

  test('rejects timestamp regression at tombstone, cleanup-complete, and finalize', () => {
    const { store, conversationId } = readyProjectStore();
    const begun = beginLifecycle(store, conversationId)!;
    expect(begun.commit()).toBe(true);
    let before = store.getState();
    store.dispatch({
      type: 'project-context-destructive/tombstone',
      payload: {
        scope: lifecycleAdvanceScope(store, begun.lifecycleId, begun.epoch),
        at: T0,
      },
    });
    expect(store.getState()).toBe(before);

    const tombstone = tombstoneLifecycle(
      store,
      begun.lifecycleId,
      begun.epoch,
    )!;
    expect(tombstone.commit()).toBe(true);
    before = store.getState();
    store.dispatch({
      type: 'project-context-destructive/cleanup-complete',
      payload: {
        scope: lifecycleAdvanceScope(store, begun.lifecycleId, begun.epoch),
        at: T0,
      },
    });
    expect(store.getState()).toBe(before);

    const cleanup = cleanupLifecycle(store, begun.lifecycleId, begun.epoch)!;
    expect(cleanup.commit()).toBe(true);
    before = store.getState();
    store.dispatch({
      type: 'project-context-destructive/finalize',
      payload: {
        scope: lifecycleAdvanceScope(store, begun.lifecycleId, begun.epoch),
        at: T0,
      },
    });
    expect(store.getState()).toBe(before);
  });

  test('blocks direct target mutation and turn preparation while a journal exists', () => {
    const { store, conversationId } = readyProjectStore();
    const begun = beginLifecycle(store, conversationId)!;
    expect(begun.commit()).toBe(true);
    const before = store.getState().conversations[conversationId];

    store.bindConversationToProject(conversationId, OTHER_PROJECT_ID);
    store.unbindConversationFromProject(conversationId);
    store.setModel(conversationId, 'deepseek-v4-pro');
    store.applyProjectContextAction(conversationId, {
      type: 'project_changed',
    });
    expect(
      store.prepareTurnAttempt(conversationId, 'must be blocked'),
    ).toBeNull();
    store.deleteConversation(conversationId);

    expect(store.getState().conversations[conversationId]).toBe(before);
    expect(store.getState()).toMatchObject({
      projectContextDestructiveTransition: {
        lifecycleId: LIFECYCLE_ID,
        phase: 'intent',
      },
    });
  });

  test('rejects epoch overflow and wrong lifecycle CAS without mutation', () => {
    const { store, conversationId } = readyProjectStore();
    const overflow = createChatStore({
      initialState: {
        ...store.getState(),
        projectContextDestructiveEpoch: Number.MAX_SAFE_INTEGER,
        projectContextDestructiveTransition: null,
      } as ChatState,
    });
    expect(beginLifecycle(overflow, conversationId)).toBeNull();

    const begun = beginLifecycle(store, conversationId)!;
    expect(begun).not.toBeNull();
    const before = store.getState();
    expect(
      lifecycleStore(store).tombstoneProjectContextDestructiveTransition({
        ...lifecycleAdvanceScope(store, begun.lifecycleId, begun.epoch),
        lifecycleId: OTHER_PROJECT_ID,
      }),
    ).toBeNull();
    expect(
      lifecycleStore(store).tombstoneProjectContextDestructiveTransition({
        ...lifecycleAdvanceScope(store, begun.lifecycleId, begun.epoch),
        epoch: begun.epoch + 1,
      }),
    ).toBeNull();
    const current = store.getState().projectContextDestructiveTransition!;
    expect(
      lifecycleStore(store).tombstoneProjectContextDestructiveTransition({
        ...lifecycleAdvanceScope(store, begun.lifecycleId, begun.epoch),
        expectedTransition: { ...current },
      }),
    ).toBeNull();
    expect(store.getState()).toBe(before);
  });

  test('allows direct project mutation only when no snapshot or preparation exists', () => {
    const unbindFixture = setupProjectStore();
    unbindFixture.store.unbindConversationFromProject(
      unbindFixture.conversationId,
    );
    expect(
      unbindFixture.store.getState().conversations[
        unbindFixture.conversationId
      ],
    ).toMatchObject({ projectId: null, projectContext: null });

    const rebindFixture = setupProjectStore();
    rebindFixture.store.bindConversationToProject(
      rebindFixture.conversationId,
      OTHER_PROJECT_ID,
    );
    expect(
      rebindFixture.store.getState().conversations[
        rebindFixture.conversationId
      ],
    ).toMatchObject({
      projectId: OTHER_PROJECT_ID,
      projectContext: { projectId: OTHER_PROJECT_ID, snapshot: null },
    });

    const deleteFixture = setupProjectStore();
    deleteFixture.store.deleteConversation(deleteFixture.conversationId);
    expect(
      deleteFixture.store.getState().conversations[
        deleteFixture.conversationId
      ],
    ).toBeUndefined();
  });

  test.each([
    { action: 'unbind' as const, targetProjectId: null },
    { action: 'rebind' as const, targetProjectId: OTHER_PROJECT_ID },
    { action: 'delete' as const, targetProjectId: null },
  ])('returns an exact one-shot snapshot-free $action transaction', fixture => {
    const value = setupProjectStore();
    const beforeState = value.store.getState();
    const beforeConversation = beforeState.conversations[value.conversationId]!;
    const transaction = snapshotFreeStore(
      value.store,
    ).applySnapshotFreeProjectMutation({
      action: fixture.action,
      conversationId: value.conversationId,
      targetProjectId: fixture.targetProjectId,
      expectedConversation: beforeConversation,
    });
    expect(transaction).not.toBeNull();
    const applied = value.store.getState();
    if (fixture.action === 'delete') {
      expect(applied.conversations[value.conversationId]).toBeUndefined();
    } else {
      expect(applied.conversations[value.conversationId]?.projectId).toBe(
        fixture.targetProjectId,
      );
    }
    expect(transaction?.rollback()).toBe(true);
    expect(value.store.getState().conversations[value.conversationId]).toBe(
      beforeConversation,
    );
    expect(transaction?.rollback()).toBe(false);
    expect(transaction?.commit()).toBe(false);
  });

  test('commits snapshot-free mutation once and rejects stale, hostile, or unsafe input', () => {
    const ready = readyProjectStore();
    const readyConversation =
      ready.store.getState().conversations[ready.conversationId]!;
    expect(
      snapshotFreeStore(ready.store).applySnapshotFreeProjectMutation({
        action: 'unbind',
        conversationId: ready.conversationId,
        targetProjectId: null,
        expectedConversation: readyConversation,
      }),
    ).toBeNull();

    const setup = setupProjectStore();
    const expected =
      setup.store.getState().conversations[setup.conversationId]!;
    setup.store.renameConversation(setup.conversationId, 'Drifted');
    expect(
      snapshotFreeStore(setup.store).applySnapshotFreeProjectMutation({
        action: 'unbind',
        conversationId: setup.conversationId,
        targetProjectId: null,
        expectedConversation: expected,
      }),
    ).toBeNull();

    let getterCalls = 0;
    const hostile = {
      action: 'unbind',
      conversationId: setup.conversationId,
      targetProjectId: null,
      get expectedConversation() {
        getterCalls += 1;
        throw new Error('RAW_DIRECT_SENTINEL');
      },
    };
    expect(
      snapshotFreeStore(setup.store).applySnapshotFreeProjectMutation(
        hostile as never,
      ),
    ).toBeNull();
    expect(getterCalls).toBe(0);

    const fresh = setupProjectStore();
    const freshConversation =
      fresh.store.getState().conversations[fresh.conversationId]!;
    const committed = snapshotFreeStore(
      fresh.store,
    ).applySnapshotFreeProjectMutation({
      action: 'rebind',
      conversationId: fresh.conversationId,
      targetProjectId: OTHER_PROJECT_ID,
      expectedConversation: freshConversation,
    });
    expect(committed?.commit()).toBe(true);
    expect(committed?.commit()).toBe(false);
    expect(committed?.rollback()).toBe(false);
  });

  test('snapshot-free delete rollback preserves listener selection and unrelated changes', () => {
    const value = setupProjectStore();
    const fallback = value.store.createConversation({
      title: 'Fallback',
      select: false,
    });
    const listenerSelection = value.store.createConversation({
      title: 'Listener selection',
      select: false,
    });
    value.store.selectConversation(value.conversationId);
    let reentered = false;
    value.store.subscribe(state => {
      if (
        !reentered &&
        state.conversations[value.conversationId] === undefined
      ) {
        reentered = true;
        value.store.selectConversation(listenerSelection);
        value.store.renameConversation(fallback, 'Fallback changed');
      }
    });
    const beforeConversation =
      value.store.getState().conversations[value.conversationId]!;
    const transaction = snapshotFreeStore(
      value.store,
    ).applySnapshotFreeProjectMutation({
      action: 'delete',
      conversationId: value.conversationId,
      targetProjectId: null,
      expectedConversation: beforeConversation,
    });

    expect(transaction).not.toBeNull();
    expect(value.store.getState().selectedConversationId).toBe(
      listenerSelection,
    );
    expect(transaction?.rollback()).toBe(true);
    expect(value.store.getState()).toMatchObject({
      selectedConversationId: listenerSelection,
      conversations: {
        [value.conversationId]: { projectId: PROJECT_ID },
        [fallback]: { title: 'Fallback changed' },
      },
    });
  });

  test('snapshot-free delete rejects a live attempt', () => {
    const value = setupProjectStore();
    const prepared = value.store.prepareTurnAttempt(
      value.conversationId,
      'still active',
      { sendWithoutProjectContext: true },
    );
    expect(prepared?.commit()).toBe(true);
    const conversation =
      value.store.getState().conversations[value.conversationId]!;
    expect(
      snapshotFreeStore(value.store).applySnapshotFreeProjectMutation({
        action: 'delete',
        conversationId: value.conversationId,
        targetProjectId: null,
        expectedConversation: conversation,
      }),
    ).toBeNull();
    expect(value.store.getState().conversations[value.conversationId]).toBe(
      conversation,
    );
  });

  test('snapshot-free rollback preserves a lifecycle journal on an unrelated conversation', () => {
    const value = readyProjectStore();
    const directId = value.store.createConversation({
      projectId: OTHER_PROJECT_ID,
      select: false,
    });
    const beforeDirect = value.store.getState().conversations[directId]!;
    const transaction = snapshotFreeStore(
      value.store,
    ).applySnapshotFreeProjectMutation({
      action: 'delete',
      conversationId: directId,
      targetProjectId: null,
      expectedConversation: beforeDirect,
    });
    const lifecycle = beginLifecycle(value.store, value.conversationId);

    expect(transaction).not.toBeNull();
    expect(lifecycle).not.toBeNull();
    expect(transaction?.rollback()).toBe(true);
    expect(value.store.getState().conversations[directId]).toBe(beforeDirect);
    expect(
      value.store.getState().projectContextDestructiveTransition,
    ).toMatchObject({
      conversationId: value.conversationId,
      phase: 'intent',
    });
  });

  test('snapshot-free mutation rechecks target and journal after the injected clock returns', () => {
    let renameStore!: ChatStore;
    let renameReentry = false;
    let renameTargetId = '';
    renameStore = createChatStore({
      now: () => {
        if (renameReentry) {
          renameReentry = false;
          renameStore.renameConversation(renameTargetId, 'Clock drift');
        }
        return T2;
      },
    });
    const renameId = renameStore.createConversation({
      projectId: PROJECT_ID,
      select: false,
    });
    renameTargetId = renameId;
    const renamedState = renameStore.getState();
    const renamedConversation = renamedState.conversations[renameId]!;
    renameReentry = true;
    expect(
      snapshotFreeStore(renameStore).applySnapshotFreeProjectMutation({
        action: 'unbind',
        conversationId: renameId,
        targetProjectId: null,
        expectedConversation: renamedConversation,
      }),
    ).toBeNull();
    expect(renameStore.getState().conversations[renameId]).toMatchObject({
      projectId: PROJECT_ID,
      title: 'Clock drift',
    });

    const ready = readyProjectStore();
    const directId = ready.store.createConversation({
      projectId: OTHER_PROJECT_ID,
      select: false,
    });
    let journalStore!: ChatStore;
    let journalReentry = true;
    journalStore = createChatStore({
      initialState: ready.store.getState(),
      now: () => {
        if (journalReentry) {
          journalReentry = false;
          expect(
            beginLifecycle(journalStore, ready.conversationId),
          ).not.toBeNull();
        }
        return T2;
      },
    });
    const directConversation = journalStore.getState().conversations[directId]!;
    expect(
      snapshotFreeStore(journalStore).applySnapshotFreeProjectMutation({
        action: 'rebind',
        conversationId: directId,
        targetProjectId: PROJECT_ID,
        expectedConversation: directConversation,
      }),
    ).toBeNull();
    expect(journalStore.getState()).toMatchObject({
      projectContextDestructiveTransition: { phase: 'intent' },
      conversations: {
        [directId]: { projectId: OTHER_PROJECT_ID },
      },
    });
  });

  test('snapshot-free mutation rejects invalid action-target relations atomically', () => {
    const value = setupProjectStore();
    const conversation =
      value.store.getState().conversations[value.conversationId]!;
    const before = value.store.getState();
    for (const input of [
      {
        action: 'unbind',
        conversationId: value.conversationId,
        targetProjectId: OTHER_PROJECT_ID,
        expectedConversation: conversation,
      },
      {
        action: 'delete',
        conversationId: value.conversationId,
        targetProjectId: OTHER_PROJECT_ID,
        expectedConversation: conversation,
      },
      {
        action: 'rebind',
        conversationId: value.conversationId,
        targetProjectId: null,
        expectedConversation: conversation,
      },
      {
        action: 'rebind',
        conversationId: value.conversationId,
        targetProjectId: PROJECT_ID,
        expectedConversation: conversation,
      },
      {
        action: 'rebind',
        conversationId: value.conversationId,
        targetProjectId: '',
        expectedConversation: conversation,
      },
      {
        action: 'raw_action',
        conversationId: value.conversationId,
        targetProjectId: null,
        expectedConversation: conversation,
      },
    ]) {
      expect(
        snapshotFreeStore(value.store).applySnapshotFreeProjectMutation(
          input as never,
        ),
      ).toBeNull();
      expect(value.store.getState()).toBe(before);
    }
  });

  test('begins lifecycle cleanup for a stale snapshot with null runtime and consent', () => {
    const fixture = readyProjectStore();
    expect(
      fixture.store.applyProjectContextAction(fixture.conversationId, {
        type: 'project_changed',
      }),
    ).toBe(true);
    const state = fixture.store.getState();
    const conversation = state.conversations[fixture.conversationId]!;
    const store = createChatStore({
      initialState: {
        ...state,
        conversations: {
          ...state.conversations,
          [fixture.conversationId]: {
            ...conversation,
            runtimeContextId: null,
          },
        },
      },
    });
    const transaction = beginLifecycle(store, fixture.conversationId);
    expect(transaction).not.toBeNull();
    expect(store.getState().projectContextDestructiveTransition).toMatchObject({
      sourceRuntimeContextId: null,
      consentReceiptId: null,
    });
  });

  test('rejects lifecycle ids already used by runtime, turn, attempt, or round', () => {
    const { store, conversationId } = readyProjectStore();
    const other = store.createConversation({ select: false });
    const prepared = store.prepareTurnAttempt(other, 'identity claims')!;
    expect(
      store.startAttemptRound(other, prepared.attemptId, ROUND_ID, 0),
    ).toBe(true);
    for (const claimed of [
      RUNTIME_ID,
      prepared.turnId,
      prepared.attemptId,
      ROUND_ID,
    ]) {
      expect(
        beginLifecycle(store, conversationId, 'unbind', null, claimed),
      ).toBeNull();
    }
  });

  test('claims the journal lifecycle id against later unrelated runtime, turn, and round generation', () => {
    const fixture = readyProjectStore();
    const preparedConversation = fixture.store.createConversation({
      select: false,
    });
    const prepared = fixture.store.prepareTurnAttempt(
      preparedConversation,
      'prepared before journal',
    )!;
    const boundConversation = fixture.store.createConversation({
      projectId: OTHER_PROJECT_ID,
      select: false,
    });
    const emptyConversation = fixture.store.createConversation({
      select: false,
    });
    const begun = beginLifecycle(fixture.store, fixture.conversationId)!;
    expect(begun.commit()).toBe(true);
    const store = createChatStore({
      initialState: fixture.store.getState(),
      createLifecycleId: () => LIFECYCLE_ID,
    });

    expect(store.ensureRuntimeContextId(boundConversation)).toBeNull();
    expect(
      store.prepareTurnAttempt(emptyConversation, 'must not reuse journal id'),
    ).toBeNull();
    expect(
      store.startAttemptRound(
        preparedConversation,
        prepared.attemptId,
        LIFECYCLE_ID,
        0,
      ),
    ).toBe(false);
    expect(store.getState().projectContextDestructiveTransition).toMatchObject({
      lifecycleId: LIFECYCLE_ID,
      phase: 'intent',
    });
  });

  test('blocks later lifecycle checkpoints when the snapshot gains a reference', () => {
    const { store, conversationId } = readyProjectStore();
    const source = store.getState().conversations[conversationId]!;
    const snapshot = source.projectContext!.snapshot!;
    const consent = source.projectContext!.consent!;
    const begun = beginLifecycle(store, conversationId)!;
    expect(begun.commit()).toBe(true);
    const tombstone = tombstoneLifecycle(
      store,
      begun.lifecycleId,
      begun.epoch,
    )!;
    expect(tombstone.commit()).toBe(true);
    const tombstonedState = store.getState();
    const tombstoned = tombstonedState.conversations[conversationId]!;
    const referencedStore = createChatStore({
      initialState: {
        ...tombstonedState,
        conversations: {
          ...tombstonedState.conversations,
          [conversationId]: {
            ...tombstoned,
            attempts: [
              {
                schemaVersion: 1,
                attemptId: ATTEMPT_ID,
                turnId: TURN_ID,
                status: 'prepared',
                harnessId: 'dsh',
                visibleMessageIds: [],
                visibleHistorySha256: null,
                attachmentIds: [],
                modelId: source.modelId,
                thinkingMode: source.thinkingMode,
                contextDisposition: 'verified',
                contextProjectId: source.projectId,
                workspaceId: null,
                workspaceBindingRevision: null,
                projectContext: {
                  schemaVersion: 1,
                  runtimeContextId: source.runtimeContextId!,
                  projectId: source.projectId!,
                  snapshotId: snapshot.snapshot_id,
                  snapshotSha256: snapshot.snapshot_sha256,
                  sourceFingerprint: snapshot.source_fingerprint,
                  contextBytes: snapshot.context_bytes,
                  consentReceiptId: consent.consent_receipt_id,
                  provider: 'deepseek',
                  policy: 'chat-read-v1',
                  policyVersion: 'chat-read-v1.0.0',
                },
                activeRound: null,
                rounds: [],
                assistantMessageId: null,
                failureCode: null,
                createdAt: T3,
                updatedAt: T3,
              },
            ],
          },
        },
      },
    });
    const beforeAdvance = referencedStore.getState();
    expect(
      cleanupLifecycle(referencedStore, begun.lifecycleId, begun.epoch),
    ).toBeNull();
    expect(referencedStore.getState()).toBe(beforeAdvance);
  });

  test('rejects finalize after a new context or owner drift and consumes raced rollback once', () => {
    const { store, conversationId } = readyProjectStore();
    const ready = advanceLifecycleToReady(store, conversationId);
    const readyState = store.getState();
    const tombstoned = readyState.conversations[conversationId]!;
    const sourceContext =
      readyProjectStore().store.getState().conversations[conversationId]!
        .projectContext!;
    for (const patch of [
      { projectContext: sourceContext },
      { modelId: 'deepseek-v4-pro' as const },
      { runtimeContextId: OTHER_PROJECT_ID },
      { projectId: OTHER_PROJECT_ID },
    ]) {
      const drifted = createChatStore({
        initialState: {
          ...readyState,
          conversations: {
            ...readyState.conversations,
            [conversationId]: { ...tombstoned, ...patch },
          },
        },
      });
      expect(
        finalizeLifecycle(drifted, ready.lifecycleId, ready.epoch),
      ).toBeNull();
    }

    const beginFixture = readyProjectStore();
    const transaction = beginLifecycle(
      beginFixture.store,
      beginFixture.conversationId,
    )!;
    const serialized = JSON.parse(beginFixture.store.serialize()) as {
      conversations: Array<Record<string, unknown>>;
      project_context_destructive_transition: Record<string, unknown>;
    };
    serialized.conversations[0]!.title = 'Raced title';
    serialized.conversations[0]!.updated_at = T3;
    serialized.project_context_destructive_transition.created_at = T3;
    serialized.project_context_destructive_transition.updated_at = T3;
    beginFixture.store.hydrate(serialized);
    expect(transaction.rollback()).toBe(false);
    expect(transaction.commit()).toBe(false);
  });

  test('active delete rollback restores target and journal while preserving listener selection', () => {
    const fixture = readyProjectStore();
    const fallback = fixture.store.createConversation({
      title: 'Fallback',
      select: false,
    });
    const listenerSelection = fixture.store.createConversation({
      title: 'Listener selection',
      select: false,
    });
    fixture.store.selectConversation(fixture.conversationId);
    const ready = advanceLifecycleToReady(
      fixture.store,
      fixture.conversationId,
      'delete',
    );
    let reentered = false;
    fixture.store.subscribe(state => {
      if (
        !reentered &&
        state.projectContextDestructiveTransition === null &&
        state.conversations[fixture.conversationId] === undefined
      ) {
        reentered = true;
        fixture.store.selectConversation(listenerSelection);
      }
    });

    const finalize = finalizeLifecycle(
      fixture.store,
      ready.lifecycleId,
      ready.epoch,
    )!;
    expect(finalize).not.toBeNull();
    expect(fixture.store.getState().selectedConversationId).toBe(
      listenerSelection,
    );
    expect(fixture.store.getState().selectedConversationId).not.toBe(fallback);
    expect(finalize.rollback()).toBe(true);
    expect(fixture.store.getState()).toMatchObject({
      projectContextDestructiveTransition: { phase: 'ready_to_finalize' },
      selectedConversationId: listenerSelection,
      conversations: {
        [fixture.conversationId]: { projectId: PROJECT_ID },
      },
    });
  });

  test('rejects a semantically valid action or target drift before finalize', () => {
    const fixture = readyProjectStore();
    const ready = advanceLifecycleToReady(
      fixture.store,
      fixture.conversationId,
    );
    const readyState = fixture.store.getState();
    const original = readyState.projectContextDestructiveTransition!;
    const actionDrift = createChatStore({
      initialState: {
        ...readyState,
        projectContextDestructiveTransition: {
          ...original,
          action: 'delete',
        },
      },
    });
    const beforeAction = actionDrift.getState();
    expect(
      finalizeLifecycle(actionDrift, ready.lifecycleId, ready.epoch, original),
    ).toBeNull();
    expect(actionDrift.getState()).toBe(beforeAction);

    const rebindFixture = readyProjectStore();
    const rebindReady = advanceLifecycleToReady(
      rebindFixture.store,
      rebindFixture.conversationId,
      'rebind',
      OTHER_PROJECT_ID,
    );
    const rebindState = rebindFixture.store.getState();
    const rebindOriginal = rebindState.projectContextDestructiveTransition!;
    const targetDrift = createChatStore({
      initialState: {
        ...rebindState,
        projectContextDestructiveTransition: {
          ...rebindOriginal,
          targetProjectId: 'project-three',
        },
      },
    });
    const beforeTarget = targetDrift.getState();
    expect(
      finalizeLifecycle(
        targetDrift,
        rebindReady.lifecycleId,
        rebindReady.epoch,
        rebindOriginal,
      ),
    ).toBeNull();
    expect(targetDrift.getState()).toBe(beforeTarget);
  });

  test('rejects hostile destructive begin input and owner records without evaluating accessors', () => {
    const { store, conversationId } = readyProjectStore();
    const conversation = store.getState().conversations[conversationId]!;
    const validOwner = {
      conversationId,
      projectId: conversation.projectId!,
      runtimeContextId: conversation.runtimeContextId,
      modelId: conversation.modelId,
      expectedUpdatedAt: conversation.updatedAt,
      expectedContext: conversation.projectContext!,
    };
    let getterCalls = 0;
    const getterInput = {
      lifecycleId: LIFECYCLE_ID,
      action: 'unbind' as const,
      targetProjectId: null,
    } as Record<string, unknown>;
    Object.defineProperty(getterInput, 'owner', {
      enumerable: true,
      get: () => {
        getterCalls += 1;
        return validOwner;
      },
    });
    expect(
      lifecycleStore(store).beginProjectContextDestructiveTransition(
        getterInput as never,
      ),
    ).toBeNull();
    expect(getterCalls).toBe(0);

    for (const hostile of [
      new Proxy(
        {},
        {
          getPrototypeOf: () => {
            throw new Error('RAW_PROXY_PROTOTYPE');
          },
        },
      ),
      new Proxy(
        {},
        {
          ownKeys: () => {
            throw new Error('RAW_PROXY_KEYS');
          },
        },
      ),
      new Proxy(
        {},
        {
          getOwnPropertyDescriptor: () => {
            throw new Error('RAW_PROXY_DESCRIPTOR');
          },
        },
      ),
    ]) {
      expect(() =>
        lifecycleStore(store).beginProjectContextDestructiveTransition(
          hostile as never,
        ),
      ).not.toThrow();
      expect(
        lifecycleStore(store).beginProjectContextDestructiveTransition(
          hostile as never,
        ),
      ).toBeNull();
    }

    const getterOwner = { ...validOwner } as Record<string, unknown>;
    Object.defineProperty(getterOwner, 'expectedContext', {
      enumerable: true,
      get: () => {
        getterCalls += 1;
        return conversation.projectContext;
      },
    });
    expect(
      lifecycleStore(store).beginProjectContextDestructiveTransition({
        lifecycleId: LIFECYCLE_ID,
        action: 'unbind',
        targetProjectId: null,
        owner: getterOwner as never,
      }),
    ).toBeNull();
    expect(getterCalls).toBe(0);

    for (const mutate of [
      (input: Record<string, unknown>) => {
        input.extra = true;
      },
      (input: Record<string, unknown>) => {
        Object.defineProperty(input, Symbol('raw'), {
          value: true,
          enumerable: true,
        });
      },
      (input: Record<string, unknown>) => {
        Object.setPrototypeOf(input, { raw: true });
      },
    ]) {
      const input = {
        lifecycleId: LIFECYCLE_ID,
        action: 'unbind',
        targetProjectId: null,
        owner: validOwner,
      } as Record<string, unknown>;
      mutate(input);
      expect(
        lifecycleStore(store).beginProjectContextDestructiveTransition(
          input as never,
        ),
      ).toBeNull();
    }
    expect(store.getState().projectContextDestructiveTransition).toBeNull();
  });

  test('fails closed when begin sees a malformed in-memory project context', () => {
    const corruptions: Array<(context: Record<string, unknown>) => void> = [
      context => {
        const snapshot = context.snapshot as Record<string, unknown>;
        snapshot.project_id = OTHER_PROJECT_ID;
      },
      context => {
        const consent = context.consent as Record<string, unknown>;
        consent.snapshot_sha256 = 'f'.repeat(64);
      },
      context => {
        let calls = 0;
        Object.defineProperty(context, 'selectedPaths', {
          enumerable: true,
          get: () => {
            calls += 1;
            throw new Error(`RAW_CONTEXT_GETTER_${calls}`);
          },
        });
      },
    ];
    corruptions.forEach(corrupt => {
      const fixture = readyProjectStore();
      const state = fixture.store.getState();
      const conversation = state.conversations[fixture.conversationId]!;
      const context = {
        ...conversation.projectContext!,
        snapshot: { ...conversation.projectContext!.snapshot! },
        consent: { ...conversation.projectContext!.consent! },
        selectedPaths: [...conversation.projectContext!.selectedPaths],
      } as Record<string, unknown>;
      corrupt(context);
      const corruptStore = createChatStore({
        initialState: {
          ...state,
          conversations: {
            ...state.conversations,
            [fixture.conversationId]: {
              ...conversation,
              projectContext: context,
            },
          },
        } as ChatState,
      });
      expect(beginLifecycle(corruptStore, fixture.conversationId)).toBeNull();
      expect(
        corruptStore.getState().projectContextDestructiveTransition,
      ).toBeNull();
    });
  });

  function schema3Receipt(prepared: {
    turnId: string;
    attemptId: string;
  }): CompletionRoundReceiptV1 {
    return {
      ...schema2Receipt(prepared),
      transportSchemaVersion: 3,
      providerRequestId: '66666666-6666-4666-8666-666666666666',
      projectContextReceipt: {
        schema_version: 1,
        snapshot_id: SNAPSHOT_ID,
        snapshot_sha256: contextManifest.snapshot_sha256,
        source_fingerprint: contextManifest.source_fingerprint,
        context_bytes: contextManifest.context_bytes,
        verified_at: T2,
      },
    };
  }

  test('migrates old bound chats without rewriting ids or inventing attempts', () => {
    const legacy = JSON.parse(
      serializeChatState(
        chatReducer(createEmptyChatState(), {
          type: 'conversation/create',
          payload: { id: 'legacy-chat', at: T0, projectId: 'project-a' },
        }),
      ),
    ) as Record<string, unknown>;
    legacy.schema_version = 5;
    stripSchema9Fields(legacy);
    const conversations = legacy.conversations as Array<
      Record<string, unknown>
    >;
    conversations.forEach(row => {
      row.workspace_id = null;
      delete row.runtime_context_id;
      delete row.project_context;
      delete row.turns;
      delete row.attempts;
    });

    const migrated = hydrateChatState(legacy);
    const conversation = migrated.conversations['legacy-chat'];
    expect(migrated.schemaVersion).toBe(CHAT_STATE_SCHEMA_VERSION);
    expect(migrated).toMatchObject({
      projectContextDestructiveEpoch: 0,
      projectContextDestructiveTransition: null,
    });
    expect(conversation?.id).toBe('legacy-chat');
    expect(conversation?.runtimeContextId).toBeNull();
    expect(conversation?.projectContext).toMatchObject({
      projectId: 'project-a',
      status: 'setup_required',
    });
    expect(conversation?.turns).toEqual([]);
    expect(conversation?.attempts).toEqual([]);
  });

  test.each([3, 4, 5])(
    'migrates schema v%s bound chats to setup required',
    schemaVersion => {
      const legacy = JSON.parse(
        serializeChatState(
          chatReducer(createEmptyChatState(), {
            type: 'conversation/create',
            payload: { id: 'legacy-chat', at: T0, projectId: 'project-a' },
          }),
        ),
      ) as {
        schema_version: number;
        conversations: Array<Record<string, unknown>>;
      };
      stripSchema9Fields(legacy as unknown as Record<string, unknown>);
      legacy.schema_version = schemaVersion;
      if (schemaVersion === 5) {
        legacy.conversations.forEach(row => {
          row.workspace_id = null;
        });
      }
      legacy.conversations.forEach(row => {
        delete row.runtime_context_id;
        delete row.project_context;
        delete row.turns;
        delete row.attempts;
      });
      if (schemaVersion < 5) {
        legacy.conversations.forEach(row => delete row.workspace_id);
      }
      const migrated = hydrateChatState(legacy);
      expect(migrated.conversations['legacy-chat']).toMatchObject({
        runtimeContextId: null,
        projectContext: {
          projectId: 'project-a',
          status: 'setup_required',
        },
        turns: [],
        attempts: [],
      });
    },
  );

  test('late-allocates one canonical runtime context id atomically', () => {
    const store = v6Store();
    const conversationId = store.createConversation({ projectId: 'project-a' });
    expect(
      store.getState().conversations[conversationId]?.runtimeContextId,
    ).toBeNull();
    expect(store.ensureRuntimeContextId(conversationId)).toBe(RUNTIME_ID);
    expect(store.ensureRuntimeContextId(conversationId)).toBe(RUNTIME_ID);
    expect(
      store.getState().conversations[conversationId]?.runtimeContextId,
    ).toBe(RUNTIME_ID);
  });

  test('requires an explicit durable disposition to bypass project context', () => {
    const store = v6Store();
    const conversationId = store.createConversation({ projectId: 'project-a' });
    const before = store.getState();
    expect(
      store.prepareTurnAttempt(conversationId, 'default blocked'),
    ).toBeNull();
    expect(store.getState()).toBe(before);

    const explicit = store.prepareTurnAttempt(
      conversationId,
      'explicit local-only context bypass',
      { sendWithoutProjectContext: true },
    );
    expect(explicit).not.toBeNull();
    expect(
      store.getState().conversations[conversationId]?.attempts[0],
    ).toMatchObject({
      contextDisposition: 'explicit_without_context',
      contextProjectId: 'project-a',
      projectContext: null,
    });
    const serialized = store.serialize();
    expect(serialized).toContain(
      '"context_disposition":"explicit_without_context"',
    );
    expect(hydrateChatState(serialized)).toEqual(store.getState());
    store.startAttemptRound(conversationId, explicit!.attemptId, ROUND_ID, 0);
    expect(
      store.recordAttemptRound(
        conversationId,
        explicit!.attemptId,
        schema2Receipt(explicit!),
      ),
    ).toBe(true);
  });

  test('honors explicit without-context when verified context is ready', () => {
    const { store, conversationId } = readyProjectStore();
    const explicit = store.prepareTurnAttempt(
      conversationId,
      'do not send verified project context',
      { sendWithoutProjectContext: true },
    );
    expect(explicit).not.toBeNull();
    expect(
      store.getState().conversations[conversationId]?.attempts[0],
    ).toMatchObject({
      contextDisposition: 'explicit_without_context',
      contextProjectId: PROJECT_ID,
      projectContext: null,
    });
  });

  test('atomically prepares a user turn from ordered visible message ids', () => {
    const store = v6Store();
    const conversationId = store.createConversation();
    const prepared = store.prepareTurnAttempt(conversationId, 'hello');
    expect(prepared).toMatchObject({ turnId: RUNTIME_ID, attemptId: TURN_ID });
    const conversation = store.getState().conversations[conversationId]!;
    expect(conversation.messages).toHaveLength(1);
    expect(conversation.turns[0]).toMatchObject({
      turnId: RUNTIME_ID,
      userMessageId: prepared?.userMessageId,
      attemptIds: [TURN_ID],
    });
    expect(conversation.attempts[0]).toMatchObject({
      attemptId: TURN_ID,
      turnId: RUNTIME_ID,
      status: 'prepared',
      visibleMessageIds: [prepared?.userMessageId],
      visibleHistorySha256: null,
      contextDisposition: 'unbound',
      contextProjectId: null,
      rounds: [],
    });
  });

  test('freezes and round-trips the exact legal user text for a prepared attempt', () => {
    const store = v6Store();
    const conversationId = store.createConversation();
    const prepared = store.prepareTurnAttempt(
      conversationId,
      '  exact prepared text  ',
    );

    expect(prepared).not.toBeNull();
    expect(
      store.getState().conversations[conversationId]?.messages.at(-1)?.text,
    ).toBe('  exact prepared text  ');
    expect(
      hydrateChatState(store.serialize()).conversations[
        conversationId
      ]?.messages.at(-1)?.text,
    ).toBe('  exact prepared text  ');
  });

  test('bounds prepared raw text and keeps attachment title fallback', () => {
    const boundary = `x${' '.repeat(MAX_CHAT_MESSAGE_LENGTH - 1)}`;
    const acceptedStore = v6Store();
    const acceptedConversation = acceptedStore.createConversation();
    expect(
      acceptedStore.prepareTurnAttempt(acceptedConversation, boundary),
    ).not.toBeNull();
    expect(
      hydrateChatState(acceptedStore.serialize()).conversations[
        acceptedConversation
      ]?.messages.at(-1)?.text,
    ).toBe(boundary);

    const rejectedStore = v6Store();
    const rejectedConversation = rejectedStore.createConversation();
    expect(
      rejectedStore.prepareTurnAttempt(rejectedConversation, `${boundary} `),
    ).toBeNull();
    expect(
      rejectedStore.getState().conversations[rejectedConversation]?.messages,
    ).toHaveLength(0);

    const attachmentStore = v6Store();
    const attachmentConversation = attachmentStore.createConversation();
    expect(
      attachmentStore.prepareTurnAttempt(attachmentConversation, ' \n\t ', {
        attachments: [IMAGE_ATTACHMENT],
      }),
    ).not.toBeNull();
    expect(
      attachmentStore.getState().conversations[attachmentConversation]?.title,
    ).toBe('receipt.png');
  });

  test('freezes only the last 200 contiguous visible messages', () => {
    let ordinary = 0;
    const lifecycleIds = [TURN_ID, ATTEMPT_ID];
    const store = createChatStore({
      now: () => T1,
      createId: kind => `${kind}-${++ordinary}`,
      createLifecycleId: () => lifecycleIds.shift() ?? RETRY_ID,
    });
    const conversationId = store.createConversation();
    for (let index = 0; index < 205; index += 1) {
      store.appendUserMessage(conversationId, `history ${index}`);
    }
    const prepared = store.prepareTurnAttempt(conversationId, 'current')!;
    const conversation = store.getState().conversations[conversationId]!;
    const attempt = conversation.attempts[0]!;
    expect(attempt.visibleMessageIds).toHaveLength(200);
    expect(attempt.visibleMessageIds).toEqual(
      conversation.messages.slice(-200).map(message => message.id),
    );
    expect(attempt.visibleMessageIds.at(-1)).toBe(prepared.userMessageId);
  });

  test('retains visible-window attachments in first-seen order', () => {
    const store = v6Store();
    const conversationId = store.createConversation();
    store.appendUserMessage(conversationId, 'with image', {
      attachments: [IMAGE_ATTACHMENT],
    });
    const prepared = store.prepareTurnAttempt(conversationId, 'current')!;
    const attempt = store
      .getState()
      .conversations[conversationId]?.attempts.find(
        item => item.attemptId === prepared.attemptId,
      );
    expect(attempt?.attachmentIds).toEqual([IMAGE_ATTACHMENT.id]);
  });

  test('caps attachment references before retention-id deduplication', () => {
    for (const [historyCount, accepted] of [
      [24, true],
      [25, false],
    ] as const) {
      const store = v6Store();
      const conversationId = store.createConversation();
      for (let index = 0; index < historyCount; index += 1) {
        store.appendUserMessage(conversationId, `attachment ${index}`, {
          attachments: [IMAGE_ATTACHMENT],
        });
      }
      const prepared = store.prepareTurnAttempt(conversationId, 'current');
      expect(prepared !== null).toBe(accepted);
      if (prepared !== null) {
        expect(
          store.getState().conversations[conversationId]?.attempts[0]
            ?.attachmentIds,
        ).toEqual([IMAGE_ATTACHMENT.id]);
      }
    }
  });

  test('downgrades persisted sending to interrupted and retries with a new attempt', () => {
    const store = v6Store();
    const conversationId = store.createConversation();
    const prepared = store.prepareTurnAttempt(conversationId, 'retry me')!;
    expect(
      store.startAttemptRound(conversationId, prepared.attemptId, ROUND_ID, 0),
    ).toBe(true);
    const hydrated = hydrateChatState(store.serialize());
    expect(hydrated.conversations[conversationId]?.attempts[0]).toMatchObject({
      status: 'failed',
      activeRound: null,
      failureCode: 'E_ATTEMPT_INTERRUPTED',
    });

    const resumed = createChatStore({
      initialState: hydrated,
      now: () => T2,
      createLifecycleId: () => RETRY_ID,
    });
    resumed.setModel(conversationId, 'deepseek-v4-pro');
    resumed.setThinkingMode(conversationId, 'max');
    const retry = resumed.retryAttempt(conversationId, prepared.attemptId);
    expect(retry?.turnId).toBe(prepared.turnId);
    expect(retry?.attemptId).toBe(RETRY_ID);
    expect(
      resumed.getState().conversations[conversationId]?.turns[0]?.attemptIds,
    ).toEqual([prepared.attemptId, RETRY_ID]);
    expect(
      resumed.getState().conversations[conversationId]?.attempts[1],
    ).toMatchObject({
      modelId: 'deepseek-v4-pro',
      thinkingMode: 'max',
      visibleHistorySha256: null,
      rounds: [],
    });
    expect(resumed.getState().conversations[conversationId]?.attempts[0]).toMatchObject({
      modelId: 'deepseek-v4-flash', thinkingMode: 'high', failureCode: 'E_ATTEMPT_INTERRUPTED',
    });
  });

  test('persists exact schema3 round receipt metadata without raw context', () => {
    const { store, conversationId } = readyProjectStore();
    const prepared = store.prepareTurnAttempt(conversationId, 'context')!;
    store.startAttemptRound(conversationId, prepared.attemptId, ROUND_ID, 0);
    expect(
      store.recordAttemptRound(conversationId, prepared.attemptId, {
        schemaVersion: 1,
        transportSchemaVersion: 3,
        turnId: prepared.turnId,
        attemptId: prepared.attemptId,
        roundId: ROUND_ID,
        roundIndex: 0,
        providerRequestId: '66666666-6666-4666-8666-666666666666',
        providerResponseId: 'resp_1',
        harnessId: 'dsh',
        requestedModel: 'deepseek-v4-flash',
        model: 'deepseek-v4-flash',
        thinkingMode: 'high',
        finishReason: 'stop',
        latencyMs: 10,
        visibleHistorySha256: 'a'.repeat(64),
        modelInputSha256: 'b'.repeat(64),
        requestBodySha256: 'c'.repeat(64),
        projectContextReceipt: {
          schema_version: 1,
          snapshot_id: SNAPSHOT_ID,
          snapshot_sha256: 'd'.repeat(64),
          source_fingerprint: 'e'.repeat(64),
          context_bytes: 10,
          verified_at: T2,
        },
      }),
    ).toBe(true);
    const serialized = store.serialize();
    expect(serialized).toContain('visible_history_sha256');
    expect(serialized).not.toContain('raw_content');
    expect(serialized).not.toContain('source_descriptor');
  });

  test('freezes a confirmed context binding and rejects correlation mismatch', () => {
    const { store, conversationId } = readyProjectStore();
    const prepared = store.prepareTurnAttempt(conversationId, 'frozen')!;
    const attempt = store.getState().conversations[conversationId]?.attempts[0];
    expect(attempt?.projectContext).toEqual({
      schemaVersion: 1,
      runtimeContextId: RUNTIME_ID,
      projectId: PROJECT_ID,
      snapshotId: SNAPSHOT_ID,
      snapshotSha256: 'd'.repeat(64),
      sourceFingerprint: 'e'.repeat(64),
      contextBytes: 10,
      consentReceiptId: CONSENT_ID,
      provider: 'deepseek',
      policy: 'chat-read-v1',
      policyVersion: 'chat-read-v1.0.0',
    });
    expect(attempt?.contextDisposition).toBe('verified');
    expect(attempt?.contextProjectId).toBe(PROJECT_ID);
    expect(
      store.startAttemptRound(conversationId, prepared.attemptId, ROUND_ID, 0),
    ).toBe(true);
    const before = store.getState();
    expect(
      store.recordAttemptRound(conversationId, prepared.attemptId, {
        schemaVersion: 1,
        transportSchemaVersion: 3,
        turnId: '99999999-9999-4999-8999-999999999999',
        attemptId: prepared.attemptId,
        roundId: ROUND_ID,
        roundIndex: 0,
        harnessId: 'dsh',
        providerRequestId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        providerResponseId: 'resp_1',
        requestedModel: 'deepseek-v4-flash',
        model: 'deepseek-v4-flash',
        thinkingMode: 'high',
        finishReason: 'stop',
        latencyMs: 1,
        visibleHistorySha256: 'a'.repeat(64),
        modelInputSha256: 'b'.repeat(64),
        requestBodySha256: 'c'.repeat(64),
        projectContextReceipt: {
          schema_version: 1,
          snapshot_id: SNAPSHOT_ID,
          snapshot_sha256: 'd'.repeat(64),
          source_fingerprint: 'e'.repeat(64),
          context_bytes: 10,
          verified_at: T2,
        },
      }),
    ).toBe(false);
    expect(store.getState()).toBe(before);
  });

  test('rejects extra or accessor-backed round receipt fields atomically', () => {
    const store = v6Store();
    const conversationId = store.createConversation();
    const prepared = store.prepareTurnAttempt(conversationId, 'receipt')!;
    store.startAttemptRound(conversationId, prepared.attemptId, ROUND_ID, 0);
    const before = store.getState();
    expect(
      store.recordAttemptRound(conversationId, prepared.attemptId, {
        ...schema2Receipt(prepared),
        raw_content: 'UNIQUE_RECEIPT_SECRET',
      } as CompletionRoundReceiptV1),
    ).toBe(false);
    expect(store.getState()).toBe(before);

    const { store: verified, conversationId: verifiedId } = readyProjectStore();
    const verifiedAttempt = verified.prepareTurnAttempt(
      verifiedId,
      'verified receipt',
    )!;
    verified.startAttemptRound(
      verifiedId,
      verifiedAttempt.attemptId,
      ROUND_ID,
      0,
    );
    const contextReceipt: Record<string, unknown> = {
      schema_version: 1,
      snapshot_id: SNAPSHOT_ID,
      snapshot_sha256: 'd'.repeat(64),
      source_fingerprint: 'e'.repeat(64),
      context_bytes: 10,
      verified_at: T2,
    };
    const getter = jest.fn(() => {
      throw new Error('RECEIPT_GETTER_SENTINEL');
    });
    Object.defineProperty(contextReceipt, 'raw_content', {
      enumerable: true,
      get: getter,
    });
    const verifiedBefore = verified.getState();
    expect(
      verified.recordAttemptRound(verifiedId, verifiedAttempt.attemptId, {
        ...schema2Receipt(verifiedAttempt),
        transportSchemaVersion: 3,
        projectContextReceipt:
          contextReceipt as CompletionRoundReceiptV1['projectContextReceipt'],
      }),
    ).toBe(false);
    expect(verified.getState()).toBe(verifiedBefore);
    expect(getter).not.toHaveBeenCalled();
  });

  test('rejects an active round with extra fields atomically', () => {
    const store = v6Store();
    const conversationId = store.createConversation();
    const prepared = store.prepareTurnAttempt(conversationId, 'round')!;
    const before = store.getState();
    store.dispatch({
      type: 'attempt/start-round',
      payload: {
        conversationId,
        attemptId: prepared.attemptId,
        round: {
          roundId: ROUND_ID,
          roundIndex: 0,
          raw_content: 'UNIQUE_ROUND_SECRET',
        } as { roundId: string; roundIndex: number },
        at: T2,
      },
    });
    expect(store.getState()).toBe(before);
  });

  test('rejects a verified receipt that disagrees with frozen source metadata', () => {
    for (const override of [
      { source_fingerprint: 'f'.repeat(64) },
      { context_bytes: 11 },
    ]) {
      const { store, conversationId } = readyProjectStore();
      const prepared = store.prepareTurnAttempt(conversationId, 'source')!;
      store.startAttemptRound(conversationId, prepared.attemptId, ROUND_ID, 0);
      const before = store.getState();
      expect(
        store.recordAttemptRound(conversationId, prepared.attemptId, {
          ...schema2Receipt(prepared),
          transportSchemaVersion: 3,
          projectContextReceipt: {
            schema_version: 1,
            snapshot_id: SNAPSHOT_ID,
            snapshot_sha256: 'd'.repeat(64),
            source_fingerprint: 'e'.repeat(64),
            context_bytes: 10,
            verified_at: T2,
            ...override,
          },
        }),
      ).toBe(false);
      expect(store.getState()).toBe(before);
    }
  });

  test('does not revive a verified retry after project unbind and rebind', () => {
    const { store, conversationId } = readyProjectStore();
    const prepared = store.prepareTurnAttempt(conversationId, 'rebind')!;
    expect(
      store.failAttempt(
        conversationId,
        prepared.attemptId,
        'E_COMPLETION_TRANSPORT',
      ),
    ).toBe(true);
    store.appendUserMessage(conversationId, 'advance visible history');
    const ready = advanceLifecycleToReady(
      store,
      conversationId,
      'rebind',
      OTHER_PROJECT_ID,
    );
    expect(
      finalizeLifecycle(store, ready.lifecycleId, ready.epoch)?.commit(),
    ).toBe(true);
    store.bindConversationToProject(conversationId, PROJECT_ID);
    const before = store.getState();
    expect(store.retryAttempt(conversationId, prepared.attemptId)).toBeNull();
    expect(store.getState()).toBe(before);
  });

  test('strictly validates persisted v6 project context metadata', () => {
    const { store } = readyProjectStore();
    const baseline = JSON.parse(store.serialize()) as {
      conversations: Array<{
        project_id: string;
        project_context: {
          project_id: string;
          selected_paths: string[];
          manifest: Record<string, unknown>;
          consent: Record<string, unknown>;
        };
      }>;
    };

    const mutations: Array<
      (conversation: (typeof baseline.conversations)[number]) => void
    > = [
      row => {
        row.project_context.manifest.snapshot_id = 'snapshot-1';
        row.project_context.consent.snapshot_id = 'snapshot-1';
      },
      row => {
        row.project_context.consent.consent_receipt_id = 'consent-1';
      },
      row => {
        row.project_context.selected_paths = ['../secret'];
      },
      row => {
        row.project_context.selected_paths = Array.from(
          { length: 5001 },
          (_, index) => `src/file-${index}.ts`,
        );
      },
      row => {
        row.project_context.selected_paths = ['z.ts', 'a.ts'];
      },
      row => {
        row.project_context.manifest.project_name = '/private/raw-path';
      },
      row => {
        row.project_context.manifest.branch = '@';
      },
      row => {
        row.project_context.manifest.conflicted = true;
      },
      row => {
        row.project_context.manifest.policy_version = 'chat-read-v1';
      },
      row => {
        row.project_context.manifest.context_bytes = 0;
      },
      row => {
        row.project_context.manifest.estimated_tokens = 4;
      },
      row => {
        const included = row.project_context.manifest.included as Array<
          Record<string, unknown>
        >;
        included[0]!.path = '../README.md';
      },
      row => {
        const included = row.project_context.manifest.included as Array<
          Record<string, unknown>
        >;
        const base = included[0]!;
        row.project_context.manifest.included = Array.from(
          { length: 33 },
          (_, index) => ({ ...base, path: `src/file-${index}.ts` }),
        );
      },
      row => {
        row.project_context.manifest.omitted = [
          { path: '.env', reason: 'secret_path' },
          { path: '.env', reason: 'secret_path' },
        ];
      },
      row => {
        row.project_context.consent.confirmed_at = T0;
      },
      row => {
        row.project_id = 'project-a';
        row.project_context.project_id = 'project-a';
        row.project_context.manifest.project_id = 'project-a';
      },
    ];

    for (const mutate of mutations) {
      const payload = JSON.parse(JSON.stringify(baseline)) as typeof baseline;
      mutate(payload.conversations[0]!);
      expect(() => hydrateChatState(payload)).toThrow(ChatStateValidationError);
    }
  });

  test('prepares atomically and refuses malformed generated identity', () => {
    const store = createChatStore({
      now: () => T1,
      createId: () => 'message-1',
      createLifecycleId: kind => (kind === 'turn' ? 'not-a-uuid' : ATTEMPT_ID),
    });
    const conversationId = store.createConversation();
    const before = store.getState();
    expect(store.prepareTurnAttempt(conversationId, 'hello')).toBeNull();
    expect(store.getState()).toBe(before);
    expect(store.getState().conversations[conversationId]?.messages).toEqual(
      [],
    );
  });

  test('rejects a turn and attempt generated with the same lifecycle id', () => {
    const store = createChatStore({
      now: () => T1,
      createId: kind => `${kind}-1`,
      createLifecycleId: () => TURN_ID,
    });
    const conversationId = store.createConversation();
    const before = store.getState();
    expect(store.prepareTurnAttempt(conversationId, 'collision')).toBeNull();
    expect(store.getState()).toBe(before);
  });

  test('blocks project rebinding while an attempt is live', () => {
    const unbound = v6Store();
    const unboundId = unbound.createConversation();
    unbound.prepareTurnAttempt(unboundId, 'live');
    const unboundBefore = unbound.getState();
    unbound.bindConversationToProject(unboundId, PROJECT_ID);
    expect(unbound.getState()).toBe(unboundBefore);

    const explicit = v6Store();
    const explicitId = explicit.createConversation({ projectId: PROJECT_ID });
    explicit.prepareTurnAttempt(explicitId, 'live', {
      sendWithoutProjectContext: true,
    });
    const explicitBefore = explicit.getState();
    explicit.unbindConversationFromProject(explicitId);
    expect(explicit.getState()).toBe(explicitBefore);
  });

  test('completes an attempt by atomically storing the assistant reference', () => {
    const store = v6Store();
    const conversationId = store.createConversation();
    const prepared = store.prepareTurnAttempt(conversationId, 'finish')!;
    store.startAttemptRound(conversationId, prepared.attemptId, ROUND_ID, 0);
    store.recordAttemptRound(conversationId, prepared.attemptId, {
      schemaVersion: 1,
      transportSchemaVersion: 2,
      turnId: prepared.turnId,
      attemptId: prepared.attemptId,
      roundId: ROUND_ID,
      roundIndex: 0,
      providerRequestId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      providerResponseId: 'resp_1',
      requestedModel: 'deepseek-v4-flash',
      model: 'deepseek-v4-flash',
      thinkingMode: 'high',
      finishReason: 'stop',
      latencyMs: 1,
      visibleHistorySha256: 'a'.repeat(64),
      modelInputSha256: 'b'.repeat(64),
      requestBodySha256: 'c'.repeat(64),
      harnessId: 'dsh',
      projectContextReceipt: null,
    });
    const messageId = store.completeAttempt(
      conversationId,
      prepared.attemptId,
      'done',
      {
        metadata: {
          modelId: 'deepseek-v4-flash',
          latencyMs: 1,
          finishReason: 'stop',
          reasoning: 'real reasoning',
        },
      },
    );
    expect(messageId).toBe('message-3');
    expect(
      store.getState().conversations[conversationId]?.attempts[0],
    ).toMatchObject({
      status: 'completed',
      assistantMessageId: 'message-3',
      failureCode: null,
    });
    expect(
      store.getState().conversations[conversationId]?.messages.at(-1),
    ).toMatchObject({ id: 'message-3', role: 'assistant', text: 'done' });
  });

  test('rejects completion metadata that does not match the terminal receipt', () => {
    const store = v6Store();
    const conversationId = store.createConversation();
    const prepared = store.prepareTurnAttempt(conversationId, 'metadata')!;
    store.startAttemptRound(conversationId, prepared.attemptId, ROUND_ID, 0);
    store.recordAttemptRound(
      conversationId,
      prepared.attemptId,
      schema2Receipt(prepared),
    );

    for (const metadata of [
      undefined,
      {
        modelId: 'deepseek-v4-pro' as const,
        latencyMs: 1,
        finishReason: 'stop',
      },
      {
        modelId: 'deepseek-v4-flash' as const,
        latencyMs: 2,
        finishReason: 'stop',
      },
      {
        modelId: 'deepseek-v4-flash' as const,
        latencyMs: 1,
        finishReason: 'length',
      },
    ]) {
      const before = store.getState();
      expect(
        store.completeAttempt(
          conversationId,
          prepared.attemptId,
          'must stay atomic',
          metadata === undefined ? {} : { metadata },
        ),
      ).toBeNull();
      expect(store.getState()).toBe(before);
    }
  });

  test('allows one completed attempt and one assistant reference per turn', () => {
    const store = v6Store();
    const conversationId = store.createConversation();
    const prepared = store.prepareTurnAttempt(conversationId, 'complete')!;
    store.startAttemptRound(conversationId, prepared.attemptId, ROUND_ID, 0);
    store.recordAttemptRound(
      conversationId,
      prepared.attemptId,
      schema2Receipt(prepared),
    );
    store.completeAttempt(conversationId, prepared.attemptId, 'done', {
      metadata: {
        modelId: 'deepseek-v4-flash',
        latencyMs: 1,
        finishReason: 'stop',
      },
    });
    const payload = JSON.parse(store.serialize()) as {
      conversations: Array<{
        turns: Array<{ attempt_ids: string[] }>;
        attempts: Array<{
          attempt_id: string;
          rounds: Array<{
            attempt_id: string;
            round_id: string;
            provider_request_id: string;
            provider_response_id: string;
          }>;
        }>;
      }>;
    };
    const conversation = payload.conversations[0]!;
    const duplicate = JSON.parse(
      JSON.stringify(conversation.attempts[0]),
    ) as (typeof conversation.attempts)[number];
    duplicate.attempt_id = '77777777-7777-4777-8777-777777777777';
    duplicate.rounds[0]!.attempt_id = duplicate.attempt_id;
    duplicate.rounds[0]!.round_id = '66666666-6666-4666-8666-666666666666';
    duplicate.rounds[0]!.provider_request_id =
      'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    duplicate.rounds[0]!.provider_response_id = 'resp_2';
    conversation.turns[0]!.attempt_ids.push(duplicate.attempt_id);
    conversation.attempts.push(duplicate);
    expect(() => hydrateChatState(payload)).toThrow(ChatStateValidationError);
  });

  test('requires a completed assistant message after its user turn', () => {
    const store = v6Store();
    const conversationId = store.createConversation();
    const olderAssistantId = store.appendAssistantMessage(
      conversationId,
      'older',
      {
        metadata: {
          modelId: 'deepseek-v4-flash',
          latencyMs: 1,
          finishReason: 'stop',
        },
      },
    );
    const prepared = store.prepareTurnAttempt(conversationId, 'current')!;
    store.startAttemptRound(conversationId, prepared.attemptId, ROUND_ID, 0);
    store.recordAttemptRound(
      conversationId,
      prepared.attemptId,
      schema2Receipt(prepared),
    );
    const payload = JSON.parse(store.serialize()) as {
      conversations: Array<{
        attempts: Array<{
          status: string;
          assistant_message_id: string | null;
        }>;
      }>;
    };
    const attempt = payload.conversations[0]!.attempts[0]!;
    attempt.status = 'completed';
    attempt.assistant_message_id = olderAssistantId;
    expect(() => hydrateChatState(payload)).toThrow(ChatStateValidationError);
  });

  test('persists cancellation without manufacturing a failure code', () => {
    const store = v6Store();
    const conversationId = store.createConversation();
    const prepared = store.prepareTurnAttempt(conversationId, 'cancel')!;
    expect(store.cancelAttempt(conversationId, prepared.attemptId)).toBe(true);
    const attempt = store.getState().conversations[conversationId]?.attempts[0];
    expect(attempt).toMatchObject({
      status: 'cancelled',
      failureCode: null,
      activeRound: null,
    });
    expect(() => hydrateChatState(store.serialize())).not.toThrow();
  });

  test('allows only explicit stable attempt failure codes', () => {
    const store = v6Store();
    const conversationId = store.createConversation();
    const prepared = store.prepareTurnAttempt(conversationId, 'failure')!;
    const before = store.getState();
    expect(
      store.failAttempt(conversationId, prepared.attemptId, 'E_API_KEY_SECRET'),
    ).toBe(false);
    expect(store.getState()).toBe(before);

    expect(
      store.failAttempt(
        conversationId,
        prepared.attemptId,
        'E_COMPLETION_TRANSPORT',
      ),
    ).toBe(true);
    const payload = JSON.parse(store.serialize()) as {
      conversations: Array<{
        attempts: Array<{ failure_code: string | null }>;
      }>;
    };
    payload.conversations[0]!.attempts[0]!.failure_code = 'E_API_KEY_SECRET';
    expect(() => hydrateChatState(payload)).toThrow(/failure_code/);
  });

  test('rejects zero and over-budget verified context receipt bytes', () => {
    for (const contextBytes of [0, 256 * 1024 + 1]) {
      const { store, conversationId } = readyProjectStore();
      const prepared = store.prepareTurnAttempt(conversationId, 'bytes')!;
      store.startAttemptRound(conversationId, prepared.attemptId, ROUND_ID, 0);
      const before = store.getState();
      expect(
        store.recordAttemptRound(conversationId, prepared.attemptId, {
          ...schema2Receipt(prepared),
          transportSchemaVersion: 3,
          projectContextReceipt: {
            schema_version: 1,
            snapshot_id: SNAPSHOT_ID,
            snapshot_sha256: 'd'.repeat(64),
            source_fingerprint: 'e'.repeat(64),
            context_bytes: contextBytes,
            verified_at: T2,
          },
        }),
      ).toBe(false);
      expect(store.getState()).toBe(before);
    }
  });

  test('accepts verified context receipt byte boundaries', () => {
    for (const contextBytes of [1, 256 * 1024]) {
      const { store, conversationId } = readyProjectStore(contextBytes);
      const prepared = store.prepareTurnAttempt(conversationId, 'bytes')!;
      store.startAttemptRound(conversationId, prepared.attemptId, ROUND_ID, 0);
      expect(
        store.recordAttemptRound(conversationId, prepared.attemptId, {
          ...schema2Receipt(prepared),
          transportSchemaVersion: 3,
          projectContextReceipt: {
            schema_version: 1,
            snapshot_id: SNAPSHOT_ID,
            snapshot_sha256: 'd'.repeat(64),
            source_fingerprint: 'e'.repeat(64),
            context_bytes: contextBytes,
            verified_at: T2,
          },
        }),
      ).toBe(true);
    }
  });

  test('retains a known visible digest when retry resets prior rounds', () => {
    const store = v6Store();
    const conversationId = store.createConversation();
    const prepared = store.prepareTurnAttempt(conversationId, 'retry rounds')!;
    store.startAttemptRound(conversationId, prepared.attemptId, ROUND_ID, 0);
    store.recordAttemptRound(conversationId, prepared.attemptId, {
      schemaVersion: 1,
      transportSchemaVersion: 2,
      turnId: prepared.turnId,
      attemptId: prepared.attemptId,
      roundId: ROUND_ID,
      roundIndex: 0,
      providerRequestId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      providerResponseId: 'resp_0',
      harnessId: 'dsh',
      requestedModel: 'deepseek-v4-flash',
      model: 'deepseek-v4-flash',
      thinkingMode: 'high',
      finishReason: 'tool_calls',
      latencyMs: 1,
      visibleHistorySha256: 'a'.repeat(64),
      modelInputSha256: 'b'.repeat(64),
      requestBodySha256: 'c'.repeat(64),
      projectContextReceipt: null,
    });
    expect(
      store.failAttempt(
        conversationId,
        prepared.attemptId,
        'E_COMPLETION_TRANSPORT',
      ),
    ).toBe(true);
    const retry = store.retryAttempt(conversationId, prepared.attemptId)!;
    const attempt = store
      .getState()
      .conversations[conversationId]?.attempts.find(
        item => item.attemptId === retry.attemptId,
      );
    expect(attempt).toMatchObject({
      visibleHistorySha256: 'a'.repeat(64),
      rounds: [],
    });
    expect(() => hydrateChatState(store.serialize())).not.toThrow();
    const tampered = JSON.parse(store.serialize()) as {
      conversations: Array<{
        attempts: Array<{ model_id: string }>;
      }>;
    };
    tampered.conversations[0]!.attempts[1]!.model_id = 'deepseek-v4-pro';
    expect(() => hydrateChatState(tampered)).toThrow(ChatStateValidationError);

    const droppedDigest = JSON.parse(store.serialize()) as {
      conversations: Array<{
        attempts: Array<{ visible_history_sha256: string | null }>;
      }>;
    };
    droppedDigest.conversations[0]!.attempts[1]!.visible_history_sha256 = null;
    expect(() => hydrateChatState(droppedDigest)).toThrow(
      /visible_history_sha256/,
    );
  });

  test('roundtrips the first known visible digest after an unknown failed attempt', () => {
    const store = v6Store();
    const conversationId = store.createConversation();
    const first = store.prepareTurnAttempt(
      conversationId,
      'retry before receipt',
    )!;
    expect(first.commit()).toBe(true);
    expect(
      store.startAttemptRound(conversationId, first.attemptId, ROUND_ID, 0),
    ).toBe(true);
    expect(
      store.failAttempt(
        conversationId,
        first.attemptId,
        'E_COMPLETION_TRANSPORT',
      ),
    ).toBe(true);
    const retry = store.retryAttempt(conversationId, first.attemptId)!;
    expect(retry.commit()).toBe(true);
    const retryRoundId = '66666666-6666-4666-8666-666666666666';
    expect(
      store.startAttemptRound(conversationId, retry.attemptId, retryRoundId, 0),
    ).toBe(true);
    expect(
      store.recordAttemptRound(conversationId, retry.attemptId, {
        ...schema2Receipt(retry),
        roundId: retryRoundId,
        providerRequestId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        providerResponseId: 'resp_retry',
      }),
    ).toBe(true);
    expect(
      store.completeAttempt(conversationId, retry.attemptId, 'Recovered', {
        metadata: {
          modelId: 'deepseek-v4-flash',
          latencyMs: 1,
          finishReason: 'stop',
        },
      }),
    ).not.toBeNull();

    expect(
      store
        .getState()
        .conversations[conversationId]?.attempts.map(
          attempt => attempt.visibleHistorySha256,
        ),
    ).toEqual([null, 'a'.repeat(64)]);
    const serialized = store.serialize();
    expect(serializeChatState(hydrateChatState(serialized))).toBe(serialized);
  });

  test('rejects a roundful retry with a changed visible-history digest', () => {
    const store = v6Store();
    const conversationId = store.createConversation();
    const first = store.prepareTurnAttempt(conversationId, 'digest')!;
    store.startAttemptRound(conversationId, first.attemptId, ROUND_ID, 0);
    store.recordAttemptRound(conversationId, first.attemptId, {
      ...schema2Receipt(first),
      finishReason: 'tool_calls',
    });
    store.failAttempt(
      conversationId,
      first.attemptId,
      'E_COMPLETION_TRANSPORT',
    );
    const retry = store.retryAttempt(conversationId, first.attemptId)!;
    const retryRoundId = '66666666-6666-4666-8666-666666666666';
    store.startAttemptRound(conversationId, retry.attemptId, retryRoundId, 0);
    store.recordAttemptRound(conversationId, retry.attemptId, {
      ...schema2Receipt(retry),
      roundId: retryRoundId,
      providerRequestId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
      providerResponseId: 'resp_2',
    });
    const payload = JSON.parse(store.serialize()) as {
      conversations: Array<{
        attempts: Array<{
          visible_history_sha256: string | null;
          rounds: Array<{ visible_history_sha256: string }>;
        }>;
      }>;
    };
    const persistedRetry = payload.conversations[0]!.attempts[1]!;
    persistedRetry.visible_history_sha256 = 'f'.repeat(64);
    persistedRetry.rounds[0]!.visible_history_sha256 = 'f'.repeat(64);
    expect(() => hydrateChatState(payload)).toThrow(ChatStateValidationError);
  });

  test('copies a recorded receipt instead of retaining mutable caller input', () => {
    const store = v6Store();
    const conversationId = store.createConversation();
    const prepared = store.prepareTurnAttempt(conversationId, 'copy')!;
    store.startAttemptRound(conversationId, prepared.attemptId, ROUND_ID, 0);
    const receipt = schema2Receipt(prepared);
    expect(
      store.recordAttemptRound(conversationId, prepared.attemptId, receipt),
    ).toBe(true);
    (
      receipt as CompletionRoundReceiptV1 & {
        providerResponseId: string;
      }
    ).providerResponseId = 'mutated';
    expect(
      store.getState().conversations[conversationId]?.attempts[0]?.rounds[0]
        ?.providerResponseId,
    ).toBe('resp_1');
  });

  test('refuses to retry an old failed turn after visible history advances', () => {
    const store = v6Store();
    const conversationId = store.createConversation();
    const first = store.prepareTurnAttempt(conversationId, 'first')!;
    expect(
      store.failAttempt(
        conversationId,
        first.attemptId,
        'E_COMPLETION_TRANSPORT',
      ),
    ).toBe(true);
    const second = store.prepareTurnAttempt(conversationId, 'second')!;
    expect(
      store.failAttempt(
        conversationId,
        second.attemptId,
        'E_COMPLETION_TRANSPORT',
      ),
    ).toBe(true);
    const before = store.getState();
    expect(store.retryAttempt(conversationId, first.attemptId)).toBeNull();
    expect(store.getState()).toBe(before);
  });

  test('rejects missing, extra, duplicate, and raw v6 attempt fields', () => {
    const store = v6Store();
    const conversationId = store.createConversation();
    store.prepareTurnAttempt(conversationId, 'strict');
    const baseline = JSON.parse(store.serialize()) as {
      conversations: Array<Record<string, unknown>>;
    };
    const conversation = baseline.conversations[0]!;

    for (const mutate of [
      (row: Record<string, unknown>) => delete row.runtime_context_id,
      (row: Record<string, unknown>) => {
        row.raw_content = 'UNIQUE_PROJECT_SECRET';
        return true;
      },
      (row: Record<string, unknown>) => {
        const attempts = row.attempts as Array<Record<string, unknown>>;
        attempts[0]!.raw_history = ['UNIQUE_PROJECT_SECRET'];
        return true;
      },
      (row: Record<string, unknown>) => {
        const messages = row.messages as Array<Record<string, unknown>>;
        messages[0]!.raw_content = 'UNIQUE_PROJECT_SECRET';
        return true;
      },
      (row: Record<string, unknown>) => {
        const attempts = row.attempts as Array<Record<string, unknown>>;
        attempts.push({ ...attempts[0]! });
        return true;
      },
      (row: Record<string, unknown>) => {
        const attempts = row.attempts as Array<Record<string, unknown>>;
        attempts[0]!.visible_message_ids = Array.from(
          { length: 201 },
          (_, index) => `message-window-${index}`,
        );
        return true;
      },
      (row: Record<string, unknown>) => {
        const attempts = row.attempts as Array<Record<string, unknown>>;
        attempts[0]!.visible_history_sha256 = 'a'.repeat(64);
        return true;
      },
      (row: Record<string, unknown>) => {
        const attempts = row.attempts as Array<Record<string, unknown>>;
        attempts[0]!.created_at = T2;
        attempts[0]!.updated_at = T2;
        return true;
      },
      (row: Record<string, unknown>) => {
        row.runtime_context_id = 'NOT-A-UUID';
        return true;
      },
    ]) {
      const tampered = JSON.parse(JSON.stringify(baseline)) as {
        conversations: Array<Record<string, unknown>>;
      };
      mutate(tampered.conversations[0]!);
      expect(() => hydrateChatState(tampered)).toThrow(
        ChatStateValidationError,
      );
    }
    expect(JSON.stringify(conversation)).not.toContain('UNIQUE_PROJECT_SECRET');
    const rootExtra = JSON.parse(JSON.stringify(baseline)) as Record<
      string,
      unknown
    >;
    rootExtra.raw_context = 'UNIQUE_PROJECT_SECRET';
    expect(() => hydrateChatState(rootExtra)).toThrow(ChatStateValidationError);
  });

  test('reports the global attempt index for a later turn validation failure', () => {
    const store = v6Store();
    const conversationId = store.createConversation();
    const first = store.prepareTurnAttempt(conversationId, 'first turn')!;
    first.commit();
    store.failAttempt(
      conversationId,
      first.attemptId,
      'E_COMPLETION_TRANSPORT',
    );
    const second = store.prepareTurnAttempt(conversationId, 'second turn')!;
    second.commit();
    const payload = JSON.parse(store.serialize()) as {
      conversations: Array<{
        attempts: Array<{ visible_message_ids: string[] }>;
      }>;
    };
    payload.conversations[0]!.attempts[1]!.visible_message_ids = ['missing'];

    try {
      hydrateChatState(payload);
      throw new Error('expected hydration failure');
    } catch (error) {
      expect(error).toBeInstanceOf(ChatStateValidationError);
      expect((error as ChatStateValidationError).path).toBe(
        '$.conversations[0].attempts[1].visible_message_ids',
      );
    }
  });

  test('rejects accessor-backed v6 fields without evaluating the getter', () => {
    const store = v6Store();
    const conversationId = store.createConversation();
    store.prepareTurnAttempt(conversationId, 'hostile');
    const payload = JSON.parse(store.serialize()) as {
      conversations: Array<Record<string, unknown>>;
    };
    const getter = jest.fn(() => {
      throw new Error('UNIQUE_GETTER_SENTINEL');
    });
    Object.defineProperty(payload.conversations[0]!, 'runtime_context_id', {
      enumerable: true,
      configurable: true,
      get: getter,
    });
    const result = safeHydrateChatState(payload);
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.error).toBeInstanceOf(ChatStateValidationError);
      expect(result.error.message).not.toContain('UNIQUE_GETTER_SENTINEL');
    }
    expect(getter).not.toHaveBeenCalled();
  });

  test('rejects a root schema accessor without evaluating it', () => {
    const payload = JSON.parse(
      serializeChatState(createEmptyChatState()),
    ) as Record<string, unknown>;
    const getter = jest.fn(() => {
      throw new Error('ROOT_SCHEMA_GETTER_SENTINEL');
    });
    Object.defineProperty(payload, 'schema_version', {
      enumerable: true,
      configurable: true,
      get: getter,
    });
    const result = safeHydrateChatState(payload);
    expect(result.ok).toBe(false);
    expect(getter).not.toHaveBeenCalled();
  });

  test('normalizes project-context serialization failures to chat errors', () => {
    const { store, conversationId } = readyProjectStore();
    const state = store.getState();
    const conversation = state.conversations[conversationId]!;
    const unsafe: ChatState = {
      ...state,
      conversations: {
        ...state.conversations,
        [conversationId]: {
          ...conversation,
          projectContext: {
            ...conversation.projectContext!,
            consent: null,
          },
        },
      },
    };
    expect(() => serializeChatState(unsafe)).toThrow(ChatStateValidationError);
  });

  test('rejects more than one live attempt after hydration', () => {
    const store = v6Store();
    const conversationId = store.createConversation();
    const first = store.prepareTurnAttempt(conversationId, 'first')!;
    store.failAttempt(
      conversationId,
      first.attemptId,
      'E_COMPLETION_TRANSPORT',
    );
    const second = store.prepareTurnAttempt(conversationId, 'second')!;
    store.failAttempt(
      conversationId,
      second.attemptId,
      'E_COMPLETION_TRANSPORT',
    );
    const payload = JSON.parse(store.serialize()) as {
      conversations: Array<{
        attempts: Array<{
          status: string;
          failure_code: string | null;
        }>;
      }>;
    };
    payload.conversations[0]!.attempts.forEach(attempt => {
      attempt.status = 'prepared';
      attempt.failure_code = null;
    });
    expect(() => hydrateChatState(payload)).toThrow(ChatStateValidationError);
  });

  test('rejects an unreachable nonterminal attempt before a later retry', () => {
    const store = v6Store();
    const conversationId = store.createConversation();
    const first = store.prepareTurnAttempt(conversationId, 'first')!;
    store.failAttempt(
      conversationId,
      first.attemptId,
      'E_COMPLETION_TRANSPORT',
    );
    const second = store.retryAttempt(conversationId, first.attemptId)!;
    store.failAttempt(
      conversationId,
      second.attemptId,
      'E_COMPLETION_TRANSPORT',
    );
    const payload = JSON.parse(store.serialize()) as {
      conversations: Array<{
        attempts: Array<{
          status: string;
          failure_code: string | null;
        }>;
      }>;
    };
    payload.conversations[0]!.attempts[0]!.status = 'prepared';
    payload.conversations[0]!.attempts[0]!.failure_code = null;
    expect(() => hydrateChatState(payload)).toThrow(ChatStateValidationError);
  });

  test('rejects nested project context accessors without evaluating them', () => {
    const { store } = readyProjectStore();
    const payload = JSON.parse(store.serialize()) as {
      conversations: Array<{
        project_context: Record<string, unknown>;
      }>;
    };
    const getter = jest.fn(() => {
      throw new Error('NESTED_PROJECT_GETTER_SENTINEL');
    });
    Object.defineProperty(
      payload.conversations[0]!.project_context,
      'selected_paths',
      {
        enumerable: true,
        configurable: true,
        get: getter,
      },
    );
    const result = safeHydrateChatState(payload);
    expect(result.ok).toBe(false);
    expect(getter).not.toHaveBeenCalled();
  });

  test('rejects non-enumerable required project context fields', () => {
    const { store } = readyProjectStore();
    const payload = JSON.parse(store.serialize()) as {
      conversations: Array<{
        project_context: {
          consent: Record<string, unknown>;
        };
      }>;
    };
    const consent = payload.conversations[0]!.project_context.consent;
    Object.defineProperty(consent, 'consent_receipt_id', {
      configurable: true,
      enumerable: false,
      value: CONSENT_ID,
    });
    expect(() => hydrateChatState(payload)).toThrow(ChatStateValidationError);
  });

  test('rejects oversized arrays before enumerating their elements', () => {
    const store = v6Store();
    const conversationId = store.createConversation();
    store.prepareTurnAttempt(conversationId, 'oversized');
    const payload = JSON.parse(store.serialize()) as {
      conversations: Array<{
        attempts: Array<{ visible_message_ids: unknown }>;
      }>;
    };
    let ownKeysCalls = 0;
    let elementDescriptorCalls = 0;
    const oversized = new Proxy(new Array(201), {
      ownKeys: target => {
        ownKeysCalls += 1;
        return Reflect.ownKeys(target);
      },
      getOwnPropertyDescriptor: (target, key) => {
        if (key !== 'length') elementDescriptorCalls += 1;
        return Reflect.getOwnPropertyDescriptor(target, key);
      },
    });
    payload.conversations[0]!.attempts[0]!.visible_message_ids = oversized;
    const result = safeHydrateChatState(payload);
    expect(result.ok).toBe(false);
    expect(ownKeysCalls).toBe(0);
    expect(elementDescriptorCalls).toBe(0);
  });

  test('enforces round index and eight-round cap without partial mutation', () => {
    const store = v6Store();
    const conversationId = store.createConversation();
    const prepared = store.prepareTurnAttempt(conversationId, 'many')!;
    expect(
      store.startAttemptRound(conversationId, prepared.attemptId, ROUND_ID, 1),
    ).toBe(false);
    for (let index = 0; index < 8; index += 1) {
      const roundId = `${String(index + 1).padStart(
        8,
        '0',
      )}-0000-4000-8000-000000000000`;
      expect(
        store.startAttemptRound(
          conversationId,
          prepared.attemptId,
          roundId,
          index,
        ),
      ).toBe(true);
      expect(
        store.recordAttemptRound(conversationId, prepared.attemptId, {
          schemaVersion: 1,
          transportSchemaVersion: 2,
          turnId: prepared.turnId,
          attemptId: prepared.attemptId,
          roundId,
          roundIndex: index,
          harnessId: 'dsh',
          providerRequestId: `${String(index + 101).padStart(
            8,
            '0',
          )}-0000-4000-8000-000000000000`,
          providerResponseId: `resp_${index}`,
          requestedModel: 'deepseek-v4-flash',
          model: 'deepseek-v4-flash',
          thinkingMode: 'high',
          finishReason: index === 7 ? 'stop' : 'tool_calls',
          latencyMs: index,
          visibleHistorySha256: 'a'.repeat(64),
          modelInputSha256: 'b'.repeat(64),
          requestBodySha256: 'c'.repeat(64),
          projectContextReceipt: null,
        }),
      ).toBe(true);
    }
    const before = store.getState();
    expect(
      store.startAttemptRound(
        conversationId,
        prepared.attemptId,
        '99999999-0000-4000-8000-000000000000',
        8,
      ),
    ).toBe(false);
    expect(store.getState()).toBe(before);
  });

  test.each([
    ['provider_request_id', false],
    ['provider_response_id', true],
  ] as const)(
    'globally reused %s: accepted is %s, in reducer and hydration',
    (duplicateField, accepted) => {
      // The request id is ours and must never repeat. The response id is the
      // provider's: relays hand the same one back round after round, and
      // refusing it failed every later round in a workspace chat.
      function populatedSecondReceipt() {
        const store = v6Store();
        const firstConversation = store.createConversation();
        const first = store.prepareTurnAttempt(firstConversation, 'first')!;
        store.startAttemptRound(
          firstConversation,
          first.attemptId,
          ROUND_ID,
          0,
        );
        store.recordAttemptRound(firstConversation, first.attemptId, {
          ...schema2Receipt(first),
          finishReason: 'tool_calls',
        });
        store.failAttempt(
          firstConversation,
          first.attemptId,
          'E_COMPLETION_TRANSPORT',
        );

        const secondConversation = store.createConversation();
        const second = store.prepareTurnAttempt(secondConversation, 'second')!;
        const secondRoundId = '66666666-6666-4666-8666-666666666666';
        store.startAttemptRound(
          secondConversation,
          second.attemptId,
          secondRoundId,
          0,
        );
        return {
          store,
          firstConversation,
          secondConversation,
          first,
          second,
          secondRoundId,
        };
      }

      const duplicate = populatedSecondReceipt();
      const before = duplicate.store.getState();
      expect(
        duplicate.store.recordAttemptRound(
          duplicate.secondConversation,
          duplicate.second.attemptId,
          {
            ...schema2Receipt(duplicate.second),
            roundId: duplicate.secondRoundId,
            providerRequestId:
              duplicateField === 'provider_request_id'
                ? 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
                : 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
            providerResponseId:
              duplicateField === 'provider_response_id' ? 'resp_1' : 'resp_2',
          },
        ),
      ).toBe(accepted);
      if (!accepted) expect(duplicate.store.getState()).toBe(before);

      const persisted = populatedSecondReceipt();
      expect(
        persisted.store.recordAttemptRound(
          persisted.secondConversation,
          persisted.second.attemptId,
          {
            ...schema2Receipt(persisted.second),
            roundId: persisted.secondRoundId,
            providerRequestId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
            providerResponseId: 'resp_2',
          },
        ),
      ).toBe(true);
      const payload = JSON.parse(persisted.store.serialize()) as {
        conversations: Array<{
          attempts: Array<{
            rounds: Array<Record<string, unknown>>;
          }>;
        }>;
      };
      const allReceipts = payload.conversations.flatMap(conversation =>
        conversation.attempts.flatMap(attempt => attempt.rounds),
      );
      allReceipts[1]![duplicateField] = allReceipts[0]![duplicateField];
      if (accepted) expect(() => hydrateChatState(payload)).not.toThrow();
      else expect(() => hydrateChatState(payload)).toThrow(ChatStateValidationError);
    },
  );

  test('rejects duplicate in-flight round ids before restart downgrade', () => {
    const store = v6Store();
    const conversationId = store.createConversation();
    const prepared = store.prepareTurnAttempt(conversationId, 'sending')!;
    store.startAttemptRound(conversationId, prepared.attemptId, ROUND_ID, 0);
    const payload = JSON.parse(store.serialize()) as {
      active_conversation_id: string;
      conversations: Array<{
        id: string;
        turns: Array<{
          turn_id: string;
          attempt_ids: string[];
        }>;
        attempts: Array<{
          attempt_id: string;
          turn_id: string;
        }>;
      }>;
    };
    const copy = JSON.parse(
      JSON.stringify(payload.conversations[0]),
    ) as (typeof payload.conversations)[number];
    copy.id = 'conversation-copy';
    copy.turns[0]!.turn_id = '66666666-6666-4666-8666-666666666666';
    copy.turns[0]!.attempt_ids = ['77777777-7777-4777-8777-777777777777'];
    copy.attempts[0]!.turn_id = '66666666-6666-4666-8666-666666666666';
    copy.attempts[0]!.attempt_id = '77777777-7777-4777-8777-777777777777';
    payload.conversations.push(copy);
    expect(() => hydrateChatState(payload)).toThrow(ChatStateValidationError);
  });

  test('returns a one-shot exact rollback transaction for a prepared turn', () => {
    const store = v6Store();
    const conversationId = store.createConversation();
    store.appendUserMessage(conversationId, 'preview', {
      attachments: [IMAGE_ATTACHMENT],
    });
    const before = store.getState();
    const notifications: ChatState[] = [];
    store.subscribe(state => notifications.push(state));

    const transaction = store.prepareTurnAttempt(conversationId, 'draft')!;
    const preparedState = store.getState();
    expect(typeof transaction.commit).toBe('function');
    expect(typeof transaction.rollback).toBe('function');
    expect(transaction.rollback()).toBe(true);
    expect(store.getState()).toBe(before);
    expect(
      store.getState().conversations[conversationId]?.messages[0]
        ?.attachments[0]?.thumbnail_data_url,
    ).toBe(IMAGE_ATTACHMENT.thumbnail_data_url);
    expect(transaction.rollback()).toBe(false);
    expect(transaction.commit()).toBe(false);
    expect(notifications).toEqual([preparedState, before]);
  });

  test('commit disarms rollback and retry transactions restore exact source', () => {
    const committed = v6Store();
    const committedId = committed.createConversation();
    const first = committed.prepareTurnAttempt(committedId, 'commit')!;
    expect(first.commit()).toBe(true);
    expect(first.commit()).toBe(false);
    expect(first.rollback()).toBe(false);

    expect(
      committed.failAttempt(
        committedId,
        first.attemptId,
        'E_COMPLETION_TRANSPORT',
      ),
    ).toBe(true);
    const failedState = committed.getState();
    const retry = committed.retryAttempt(committedId, first.attemptId)!;
    expect(retry.rollback()).toBe(true);
    expect(committed.getState()).toBe(failedState);
  });

  test('rollback never overwrites a listener reentrant state transition', () => {
    const store = v6Store();
    const conversationId = store.createConversation();
    let reentered = false;
    store.subscribe(() => {
      if (reentered) return;
      reentered = true;
      store.renameConversation(conversationId, 'listener update');
    });
    const transaction = store.prepareTurnAttempt(conversationId, 'reentrant')!;
    expect(transaction.rollback()).toBe(false);
    expect(transaction.commit()).toBe(false);
    expect(store.getState().conversations[conversationId]).toMatchObject({
      title: 'listener update',
      messages: [{ text: 'reentrant' }],
    });
  });

  test('listener failures cannot strand a prepared state without a handle', () => {
    const store = v6Store();
    const conversationId = store.createConversation();
    const before = store.getState();
    const observed: ChatState[] = [];
    store.subscribe(() => {
      throw new Error('LISTENER_SECRET');
    });
    store.subscribe(state => observed.push(state));

    let transaction: ReturnType<typeof store.prepareTurnAttempt> | undefined;
    expect(() => {
      transaction = store.prepareTurnAttempt(conversationId, 'safe');
    }).not.toThrow();
    expect(transaction).toBeDefined();
    const prepared = store.getState();
    expect(observed).toEqual([prepared]);
    expect(() => transaction!.rollback()).not.toThrow();
    expect(store.getState()).toBe(before);
    expect(observed).toEqual([prepared, before]);
  });

  test('commit always disarms once and failed rollback is consumed', () => {
    const committed = v6Store();
    const committedId = committed.createConversation();
    const transaction = committed.prepareTurnAttempt(
      committedId,
      'commit after mutation',
    )!;
    committed.renameConversation(committedId, 'newer state');
    expect(transaction.commit()).toBe(true);
    expect(transaction.rollback()).toBe(false);
    expect(transaction.commit()).toBe(false);

    const conflicted = v6Store();
    const conflictedId = conflicted.createConversation();
    const failedRollback = conflicted.prepareTurnAttempt(
      conflictedId,
      'rollback conflict',
    )!;
    conflicted.renameConversation(conflictedId, 'wins');
    expect(failedRollback.rollback()).toBe(false);
    expect(failedRollback.commit()).toBe(false);
    expect(failedRollback.rollback()).toBe(false);
  });

  test('interrupts persisted prepared receipts but preserves zero-round resume', () => {
    const resumable = v6Store();
    const resumableId = resumable.createConversation();
    const zeroRound = resumable.prepareTurnAttempt(resumableId, 'resume')!;
    const hydratedZero = hydrateChatState(resumable.serialize());
    expect(
      hydratedZero.conversations[resumableId]?.attempts.find(
        attempt => attempt.attemptId === zeroRound.attemptId,
      ),
    ).toMatchObject({ status: 'prepared', rounds: [] });

    const interrupted = v6Store();
    const interruptedId = interrupted.createConversation();
    const prepared = interrupted.prepareTurnAttempt(
      interruptedId,
      'intermediate',
    )!;
    interrupted.startAttemptRound(
      interruptedId,
      prepared.attemptId,
      ROUND_ID,
      0,
    );
    interrupted.recordAttemptRound(interruptedId, prepared.attemptId, {
      ...schema2Receipt(prepared),
      finishReason: 'tool_calls',
    });
    const hydratedRound = hydrateChatState(interrupted.serialize());
    expect(
      hydratedRound.conversations[interruptedId]?.attempts.find(
        attempt => attempt.attemptId === prepared.attemptId,
      ),
    ).toMatchObject({
      status: 'failed',
      activeRound: null,
      failureCode: 'E_ATTEMPT_INTERRUPTED',
    });
  });

  test.each(['prepared', 'sending'] as const)(
    'rejects model and thinking mutations while an attempt is %s',
    status => {
      const store = v6Store();
      const conversationId = store.createConversation();
      const prepared = store.prepareTurnAttempt(
        conversationId,
        `freeze ${status}`,
      )!;
      if (status === 'sending') {
        expect(
          store.startAttemptRound(
            conversationId,
            prepared.attemptId,
            ROUND_ID,
            0,
          ),
        ).toBe(true);
      }
      const before = store.getState();
      const conversationBefore = before.conversations[conversationId]!;

      store.setModel(conversationId, 'deepseek-v4-pro');
      store.setThinkingMode(conversationId, 'max');

      expect(store.getState()).toBe(before);
      expect(store.getState().conversations[conversationId]).toBe(
        conversationBefore,
      );
      expect(conversationBefore).toMatchObject({
        modelId: 'deepseek-v4-flash',
        thinkingMode: 'high',
        updatedAt: T1,
      });
    },
  );

  test('allows model and thinking mutations after terminal attempt states', () => {
    const terminalStores: Array<{
      store: ChatStore;
      conversationId: string;
    }> = [];

    const failed = v6Store();
    const failedId = failed.createConversation();
    const failedAttempt = failed.prepareTurnAttempt(failedId, 'failed')!;
    expect(
      failed.failAttempt(
        failedId,
        failedAttempt.attemptId,
        'E_COMPLETION_NATIVE',
      ),
    ).toBe(true);
    terminalStores.push({ store: failed, conversationId: failedId });

    const cancelled = v6Store();
    const cancelledId = cancelled.createConversation();
    const cancelledAttempt = cancelled.prepareTurnAttempt(
      cancelledId,
      'cancelled',
    )!;
    expect(
      cancelled.cancelAttempt(cancelledId, cancelledAttempt.attemptId),
    ).toBe(true);
    terminalStores.push({ store: cancelled, conversationId: cancelledId });

    const completed = v6Store();
    const completedId = completed.createConversation();
    const completedAttempt = completed.prepareTurnAttempt(
      completedId,
      'completed',
    )!;
    expect(
      completed.startAttemptRound(
        completedId,
        completedAttempt.attemptId,
        ROUND_ID,
        0,
      ),
    ).toBe(true);
    expect(
      completed.recordAttemptRound(
        completedId,
        completedAttempt.attemptId,
        schema2Receipt(completedAttempt),
      ),
    ).toBe(true);
    expect(
      completed.completeAttempt(
        completedId,
        completedAttempt.attemptId,
        'done',
        {
          metadata: {
            modelId: 'deepseek-v4-flash',
            latencyMs: 1,
            finishReason: 'stop',
          },
        },
      ),
    ).not.toBeNull();
    terminalStores.push({ store: completed, conversationId: completedId });

    terminalStores.forEach(({ store, conversationId }) => {
      const before = store.getState();
      store.setModel(conversationId, 'deepseek-v4-pro');
      store.setThinkingMode(conversationId, 'max');
      expect(store.getState()).not.toBe(before);
      expect(store.getState().conversations[conversationId]).toMatchObject({
        modelId: 'deepseek-v4-pro',
        thinkingMode: 'max',
      });
    });
  });

  test('start revalidates frozen model, visible history, and verified context', () => {
    const modelStore = v6Store();
    const modelConversation = modelStore.createConversation();
    const modelAttempt = modelStore.prepareTurnAttempt(
      modelConversation,
      'model',
    )!;
    const legalModelState = modelStore.getState();
    const legalModelConversation =
      legalModelState.conversations[modelConversation]!;
    const hostileModelState: ChatState = {
      ...legalModelState,
      conversations: {
        ...legalModelState.conversations,
        [modelConversation]: {
          ...legalModelConversation,
          modelId: 'deepseek-v4-pro',
        },
      },
    };
    const hostileModelStore = createChatStore({
      initialState: hostileModelState,
      now: () => T1,
    });
    const modelBefore = hostileModelStore.getState();
    expect(
      hostileModelStore.startAttemptRound(
        modelConversation,
        modelAttempt.attemptId,
        ROUND_ID,
        0,
      ),
    ).toBe(false);
    expect(hostileModelStore.getState()).toBe(modelBefore);

    const historyStore = v6Store();
    const historyConversation = historyStore.createConversation();
    const historyAttempt = historyStore.prepareTurnAttempt(
      historyConversation,
      'history',
    )!;
    historyStore.appendAssistantMessage(historyConversation, 'later');
    expect(
      historyStore.startAttemptRound(
        historyConversation,
        historyAttempt.attemptId,
        ROUND_ID,
        0,
      ),
    ).toBe(false);

    const verified = readyProjectStore();
    const verifiedAttempt = verified.store.prepareTurnAttempt(
      verified.conversationId,
      'context',
    )!;
    verified.store.applyProjectContextAction(verified.conversationId, {
      type: 'snapshot_missing',
    });
    expect(
      verified.store.startAttemptRound(
        verified.conversationId,
        verifiedAttempt.attemptId,
        ROUND_ID,
        0,
      ),
    ).toBe(false);
  });

  test('scoped replace-prepared is one transition and never replaces Ready', () => {
    const setup = setupProjectStore();
    const observed: ChatState[] = [];
    setup.store.subscribe(state => observed.push(state));
    const transaction: ScopedProjectContextTransaction | null =
      setup.store.replaceProjectContextPrepared(
        projectContextScope(setup.store, setup.conversationId),
        {
          preparationId: REPLACEMENT_PREPARATION_ID,
          selectedPaths: ['src/index.ts'],
          manifest: replacementManifest,
        },
      );

    expect(transaction).not.toBeNull();
    expect(observed).toHaveLength(1);
    expect(
      observed.map(
        state =>
          state.conversations[setup.conversationId]?.projectContext?.status,
      ),
    ).toEqual(['setup_required']);
    expect(
      setup.store.getState().conversations[setup.conversationId]
        ?.projectContext,
    ).toMatchObject({
      activePreparationId: REPLACEMENT_PREPARATION_ID,
      snapshot: { snapshot_id: REPLACEMENT_SNAPSHOT_ID },
      consent: null,
    });
    expect(transaction?.commit()).toBe(true);

    const ready = scopedReadyProjectStore();
    const readyBefore = ready.store.getState();
    const readyNotifications: ChatState[] = [];
    ready.store.subscribe(state => readyNotifications.push(state));
    expect(
      ready.store.replaceProjectContextPrepared(
        projectContextScope(ready.store, ready.conversationId),
        {
          preparationId: REPLACEMENT_PREPARATION_ID,
          selectedPaths: ['src/index.ts'],
          manifest: replacementManifest,
        },
      ),
    ).toBeNull();
    expect(ready.store.getState()).toBe(readyBefore);
    expect(readyNotifications).toEqual([]);
  });

  test('scoped replace-confirmed atomically promotes prepared to Ready', () => {
    const fixture = setupProjectStore();
    const prepared = fixture.store.replaceProjectContextPrepared(
      projectContextScope(fixture.store, fixture.conversationId),
      {
        preparationId: REPLACEMENT_PREPARATION_ID,
        selectedPaths: ['src/index.ts'],
        manifest: replacementManifest,
      },
    )!;
    expect(prepared.commit()).toBe(true);
    const observed: ChatState[] = [];
    fixture.store.subscribe(state => observed.push(state));

    const confirmed = fixture.store.replaceProjectContextConfirmed(
      projectContextScope(fixture.store, fixture.conversationId),
      {
        preparationId: REPLACEMENT_PREPARATION_ID,
        selectedPaths: ['src/index.ts'],
        manifest: replacementManifest,
        consent: replacementConsent,
      },
    );

    expect(confirmed).not.toBeNull();
    expect(observed).toHaveLength(1);
    expect(
      observed[0]?.conversations[fixture.conversationId]?.projectContext,
    ).toMatchObject({
      status: 'ready',
      activePreparationId: null,
      snapshot: { snapshot_id: REPLACEMENT_SNAPSHOT_ID },
      consent: { consent_receipt_id: REPLACEMENT_CONSENT_ID },
    });
    expect(confirmed?.commit()).toBe(true);
  });

  test('scoped replace-confirmed swaps Ready A to Ready B without an intermediate state', () => {
    const fixture = scopedReadyProjectStore();
    const oldContext =
      fixture.store.getState().conversations[fixture.conversationId]!
        .projectContext!;
    const observed: ChatState[] = [];
    fixture.store.subscribe(state => observed.push(state));

    const transaction = fixture.store.replaceProjectContextConfirmed(
      projectContextScope(fixture.store, fixture.conversationId),
      {
        preparationId: REPLACEMENT_PREPARATION_ID,
        selectedPaths: ['src/index.ts'],
        manifest: replacementManifest,
        consent: replacementConsent,
      },
    );

    expect(transaction).toMatchObject({
      previousSnapshotId: SNAPSHOT_ID,
      nextSnapshotId: REPLACEMENT_SNAPSHOT_ID,
    });
    expect(observed).toHaveLength(1);
    expect(
      observed.map(
        state =>
          state.conversations[fixture.conversationId]?.projectContext?.snapshot
            ?.snapshot_id,
      ),
    ).toEqual([REPLACEMENT_SNAPSHOT_ID]);
    expect(
      observed[0]?.conversations[fixture.conversationId]?.projectContext
        ?.consent?.consent_receipt_id,
    ).toBe(REPLACEMENT_CONSENT_ID);

    // This verifies only the pure state transaction. A post-native refresh
    // persistence failure must not use this rollback after native pruned A.
    expect(transaction?.rollback()).toBe(true);
    expect(
      fixture.store.getState().conversations[fixture.conversationId]
        ?.projectContext,
    ).toBe(oldContext);
    expect(transaction?.commit()).toBe(false);
  });

  test('scoped confirmation rejects stale scope and mismatched authority metadata', () => {
    const stale = scopedReadyProjectStore();
    const staleScope = projectContextScope(stale.store, stale.conversationId);
    stale.store.setModel(stale.conversationId, 'deepseek-v4-pro');
    const afterModelChange = stale.store.getState();
    expect(
      stale.store.replaceProjectContextConfirmed(staleScope, {
        preparationId: REPLACEMENT_PREPARATION_ID,
        selectedPaths: ['src/index.ts'],
        manifest: {
          ...replacementManifest,
          model: 'deepseek-v4-pro',
        },
        consent: replacementConsent,
      }),
    ).toBeNull();
    expect(stale.store.getState()).toBe(afterModelChange);

    const fixture = scopedReadyProjectStore();
    const scope = projectContextScope(fixture.store, fixture.conversationId);
    const invalidRows: Array<{
      manifest: ProjectContextManifestV1;
      consent: ProjectContextConsentV1;
    }> = [
      {
        manifest: { ...replacementManifest, project_id: OTHER_PROJECT_ID },
        consent: replacementConsent,
      },
      {
        manifest: { ...replacementManifest, model: 'deepseek-v4-pro' },
        consent: replacementConsent,
      },
      {
        manifest: {
          ...replacementManifest,
          provider_host: 'proxy.example.com',
        } as unknown as ProjectContextManifestV1,
        consent: replacementConsent,
      },
      {
        manifest: {
          ...replacementManifest,
          policy_version: 'chat-read-v1.0.1',
        },
        consent: replacementConsent,
      },
      {
        manifest: replacementManifest,
        consent: {
          ...replacementConsent,
          snapshot_sha256: 'f'.repeat(64),
        },
      },
    ];
    for (const row of invalidRows) {
      const before = fixture.store.getState();
      expect(
        fixture.store.replaceProjectContextConfirmed(scope, {
          preparationId: REPLACEMENT_PREPARATION_ID,
          selectedPaths: ['src/index.ts'],
          manifest: row.manifest,
          consent: row.consent,
        }),
      ).toBeNull();
      expect(fixture.store.getState()).toBe(before);
    }

    expect(
      fixture.store.replaceProjectContextConfirmed(
        {
          ...scope,
          projectId: OTHER_PROJECT_ID,
          runtimeContextId: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
        },
        {
          preparationId: REPLACEMENT_PREPARATION_ID,
          selectedPaths: ['src/index.ts'],
          manifest: replacementManifest,
          consent: replacementConsent,
        },
      ),
    ).toBeNull();
  });

  test('all scoped context mutations reject live and exact-retry attempts', () => {
    const liveSetup = setupProjectStore();
    const setupScope = projectContextScope(
      liveSetup.store,
      liveSetup.conversationId,
    );
    const liveWithoutContext = liveSetup.store.prepareTurnAttempt(
      liveSetup.conversationId,
      'live',
      { sendWithoutProjectContext: true },
    )!;
    expect(liveWithoutContext.commit()).toBe(true);
    expect(
      liveSetup.store.replaceProjectContextPrepared(setupScope, {
        preparationId: REPLACEMENT_PREPARATION_ID,
        selectedPaths: ['src/index.ts'],
        manifest: replacementManifest,
      }),
    ).toBeNull();

    const retryable = scopedReadyProjectStore();
    const attempt = retryable.store.prepareTurnAttempt(
      retryable.conversationId,
      'retryable',
    )!;
    expect(attempt.commit()).toBe(true);
    expect(
      retryable.store.failAttempt(
        retryable.conversationId,
        attempt.attemptId,
        'E_COMPLETION_TRANSPORT',
      ),
    ).toBe(true);
    const retryScope = projectContextScope(
      retryable.store,
      retryable.conversationId,
    );
    expect(retryable.store.disableProjectContext(retryScope)).toBeNull();
    expect(
      retryable.store.replaceProjectContextConfirmed(retryScope, {
        preparationId: REPLACEMENT_PREPARATION_ID,
        selectedPaths: ['src/index.ts'],
        manifest: replacementManifest,
        consent: replacementConsent,
      }),
    ).toBeNull();
  });

  test('disable exposes cleanup identity and blocks schema3 before native cleanup', () => {
    const fixture = scopedReadyProjectStore();
    const observed: ChatState[] = [];
    fixture.store.subscribe(state => observed.push(state));
    const transaction = fixture.store.disableProjectContext(
      projectContextScope(fixture.store, fixture.conversationId),
    );

    expect(transaction).toMatchObject({
      previousSnapshotId: SNAPSHOT_ID,
      nextSnapshotId: null,
      cleanupSnapshotId: SNAPSHOT_ID,
    });
    expect(observed).toHaveLength(1);
    expect(
      fixture.store.getState().conversations[fixture.conversationId]
        ?.projectContext,
    ).toMatchObject({
      status: 'setup_required',
      snapshot: null,
      consent: null,
    });
    expect(
      fixture.store.prepareTurnAttempt(
        fixture.conversationId,
        'must not route schema3',
      ),
    ).toBeNull();
    expect(fixture.store.serialize()).not.toContain(SNAPSHOT_ID);
    expect(transaction?.commit()).toBe(true);
  });

  test('scoped rollback preserves unrelated root changes and rejects a target race', () => {
    const fixture = scopedReadyProjectStore();
    const transaction = fixture.store.disableProjectContext(
      projectContextScope(fixture.store, fixture.conversationId),
    )!;
    const otherConversation = fixture.store.createConversation({
      title: 'unrelated',
    });
    fixture.store.selectConversation(otherConversation);

    expect(transaction.rollback()).toBe(true);
    expect(fixture.store.getState().selectedConversationId).toBe(
      otherConversation,
    );
    expect(
      fixture.store.getState().conversations[otherConversation]?.title,
    ).toBe('unrelated');
    expect(
      fixture.store.getState().conversations[fixture.conversationId]
        ?.projectContext?.snapshot?.snapshot_id,
    ).toBe(SNAPSHOT_ID);

    const raced = scopedReadyProjectStore();
    const racedTransaction = raced.store.disableProjectContext(
      projectContextScope(raced.store, raced.conversationId),
    )!;
    raced.store.renameConversation(raced.conversationId, 'same target wins');
    expect(racedTransaction.rollback()).toBe(false);
    expect(racedTransaction.commit()).toBe(false);
    expect(racedTransaction.rollback()).toBe(false);
    expect(
      raced.store.getState().conversations[raced.conversationId]?.title,
    ).toBe('same target wins');
  });

  test('scoped transactions are once-only and isolate listener failures', () => {
    const rollbackFixture = scopedReadyProjectStore();
    const notifications: ChatState[] = [];
    rollbackFixture.store.subscribe(() => {
      throw new Error('CONTEXT_LISTENER_SECRET');
    });
    rollbackFixture.store.subscribe(state => notifications.push(state));
    let rollbackTransaction:
      | ReturnType<ChatStore['disableProjectContext']>
      | undefined;
    expect(() => {
      rollbackTransaction = rollbackFixture.store.disableProjectContext(
        projectContextScope(
          rollbackFixture.store,
          rollbackFixture.conversationId,
        ),
      );
    }).not.toThrow();
    expect(rollbackTransaction).not.toBeNull();
    expect(() => rollbackTransaction!.rollback()).not.toThrow();
    expect(rollbackTransaction!.rollback()).toBe(false);
    expect(rollbackTransaction!.commit()).toBe(false);
    expect(notifications).toHaveLength(2);

    const commitFixture = scopedReadyProjectStore();
    const commitTransaction = commitFixture.store.disableProjectContext(
      projectContextScope(commitFixture.store, commitFixture.conversationId),
    )!;
    expect(commitTransaction.commit()).toBe(true);
    expect(commitTransaction.commit()).toBe(false);
    expect(commitTransaction.rollback()).toBe(false);
  });

  test('generic project-context actions cannot bypass scoped durable mutations', () => {
    const fixture = setupProjectStore();
    const setupBefore = fixture.store.getState();
    expect(
      fixture.store.applyProjectContextAction(fixture.conversationId, {
        type: 'checking',
        preparationId: REPLACEMENT_PREPARATION_ID,
      }),
    ).toBe(false);
    expect(fixture.store.getState()).toBe(setupBefore);

    const prepared = fixture.store.replaceProjectContextPrepared(
      projectContextScope(fixture.store, fixture.conversationId),
      {
        preparationId: REPLACEMENT_PREPARATION_ID,
        selectedPaths: ['src/index.ts'],
        manifest: replacementManifest,
      },
    )!;
    expect(prepared.commit()).toBe(true);
    const preparedBefore = fixture.store.getState();
    expect(
      fixture.store.applyProjectContextAction(fixture.conversationId, {
        type: 'confirmed',
        preparationId: REPLACEMENT_PREPARATION_ID,
        manifest: replacementManifest,
        consent: replacementConsent,
      }),
    ).toBe(false);
    expect(fixture.store.getState()).toBe(preparedBefore);

    const confirmed = fixture.store.replaceProjectContextConfirmed(
      projectContextScope(fixture.store, fixture.conversationId),
      {
        preparationId: REPLACEMENT_PREPARATION_ID,
        selectedPaths: ['src/index.ts'],
        manifest: replacementManifest,
        consent: replacementConsent,
      },
    )!;
    expect(confirmed.commit()).toBe(true);
    const readyBefore = fixture.store.getState();
    expect(
      fixture.store.applyProjectContextAction(fixture.conversationId, {
        type: 'selection_changed',
        selectedPaths: ['README.md'],
      }),
    ).toBe(false);
    expect(
      fixture.store.applyProjectContextAction(fixture.conversationId, {
        type: 'disabled',
      }),
    ).toBe(false);
    expect(fixture.store.getState()).toBe(readyBefore);
  });

  test('scoped replacements reject v6-unsafe metadata before live mutation', () => {
    const invalidPreparedRows: Array<{
      selectedPaths: readonly string[];
      manifest: ProjectContextManifestV1;
    }> = [
      {
        selectedPaths: ['../secret'],
        manifest: replacementManifest,
      },
      {
        selectedPaths: ['src/index.ts'],
        manifest: {
          ...replacementManifest,
          included: [
            {
              ...replacementManifest.included[0]!,
              path: '../secret',
            },
          ],
        },
      },
      {
        selectedPaths: ['src/index.ts'],
        manifest: {
          ...replacementManifest,
          context_bytes: 256 * 1024 + 1,
          estimated_tokens: 65_537,
        },
      },
      {
        selectedPaths: ['src/index.ts'],
        manifest: {
          ...replacementManifest,
          estimated_tokens: replacementManifest.estimated_tokens + 1,
        },
      },
      {
        selectedPaths: ['src/index.ts'],
        manifest: {
          ...replacementManifest,
          clean: true,
          conflicted: true,
        },
      },
    ];

    for (const row of invalidPreparedRows) {
      const fixture = setupProjectStore();
      const before = fixture.store.getState();
      const notifications: ChatState[] = [];
      fixture.store.subscribe(state => notifications.push(state));
      expect(
        fixture.store.replaceProjectContextPrepared(
          projectContextScope(fixture.store, fixture.conversationId),
          {
            preparationId: REPLACEMENT_PREPARATION_ID,
            selectedPaths: row.selectedPaths,
            manifest: row.manifest,
          },
        ),
      ).toBeNull();
      expect(fixture.store.getState()).toBe(before);
      expect(notifications).toEqual([]);
    }

    const confirmed = scopedReadyProjectStore();
    const confirmedBefore = confirmed.store.getState();
    const confirmedNotifications: ChatState[] = [];
    confirmed.store.subscribe(state => confirmedNotifications.push(state));
    expect(
      confirmed.store.replaceProjectContextConfirmed(
        projectContextScope(confirmed.store, confirmed.conversationId),
        {
          preparationId: REPLACEMENT_PREPARATION_ID,
          selectedPaths: ['src/index.ts'],
          manifest: replacementManifest,
          consent: { ...replacementConsent, confirmed_at: T0 },
        },
      ),
    ).toBeNull();
    expect(confirmed.store.getState()).toBe(confirmedBefore);
    expect(confirmedNotifications).toEqual([]);
  });

  test('hostile scoped conversation identity is rejected without coercion', () => {
    const fixture = scopedReadyProjectStore();
    const validScope = projectContextScope(
      fixture.store,
      fixture.conversationId,
    );
    let coercions = 0;
    const hostileConversationId = {
      [Symbol.toPrimitive]: () => {
        coercions += 1;
        throw new Error('SCOPE_COERCION_SECRET');
      },
    };
    const hostileScope = {
      ...validScope,
      conversationId: hostileConversationId as unknown as string,
    };
    const before = fixture.store.getState();
    expect(() =>
      fixture.store.disableProjectContext(hostileScope),
    ).not.toThrow();
    expect(fixture.store.disableProjectContext(hostileScope)).toBeNull();
    expect(coercions).toBe(0);
    expect(fixture.store.getState()).toBe(before);
  });

  test('generic unavailable cannot clear a durable snapshot without cleanup identity', () => {
    const fixture = scopedReadyProjectStore();
    const before = fixture.store.getState();
    expect(
      fixture.store.applyProjectContextAction(fixture.conversationId, {
        type: 'unavailable',
      }),
    ).toBe(false);
    expect(fixture.store.getState()).toBe(before);
  });

  test('selects only verified prepared, sending, and exact-retry references', () => {
    const fixture = scopedReadyProjectStore();
    const prepared = fixture.store.prepareTurnAttempt(
      fixture.conversationId,
      'reference',
    )!;
    expect(prepared.commit()).toBe(true);
    expect(
      selectProjectContextSnapshotReferences(
        fixture.store.getState(),
        fixture.conversationId,
      ),
    ).toEqual([
      {
        conversationId: fixture.conversationId,
        attemptId: prepared.attemptId,
        kind: 'prepared',
      },
    ]);
    expect(
      selectProjectContextSnapshotReferences(
        fixture.store.getState(),
        fixture.conversationId,
        REPLACEMENT_SNAPSHOT_ID,
      ),
    ).toEqual([]);

    expect(
      fixture.store.startAttemptRound(
        fixture.conversationId,
        prepared.attemptId,
        ROUND_ID,
        0,
      ),
    ).toBe(true);
    expect(
      selectProjectContextSnapshotReferences(
        fixture.store.getState(),
        fixture.conversationId,
        SNAPSHOT_ID,
      ),
    ).toEqual([
      {
        conversationId: fixture.conversationId,
        attemptId: prepared.attemptId,
        kind: 'sending',
      },
    ]);

    expect(
      fixture.store.failAttempt(
        fixture.conversationId,
        prepared.attemptId,
        'E_COMPLETION_TRANSPORT',
      ),
    ).toBe(true);
    expect(
      selectProjectContextSnapshotReferences(
        fixture.store.getState(),
        fixture.conversationId,
        SNAPSHOT_ID,
      ),
    ).toEqual([
      {
        conversationId: fixture.conversationId,
        attemptId: prepared.attemptId,
        kind: 'retryable',
      },
    ]);

    const cancelled = scopedReadyProjectStore();
    const cancelledAttempt = cancelled.store.prepareTurnAttempt(
      cancelled.conversationId,
      'cancelled retry',
    )!;
    expect(cancelledAttempt.commit()).toBe(true);
    expect(
      cancelled.store.cancelAttempt(
        cancelled.conversationId,
        cancelledAttempt.attemptId,
      ),
    ).toBe(true);
    expect(
      selectProjectContextSnapshotReferences(
        cancelled.store.getState(),
        cancelled.conversationId,
        SNAPSHOT_ID,
      ),
    ).toEqual([
      {
        conversationId: cancelled.conversationId,
        attemptId: cancelledAttempt.attemptId,
        kind: 'retryable',
      },
    ]);
  });

  test('excludes plain, completed, old-visible, and other-snapshot attempts', () => {
    const explicit = setupProjectStore();
    const plain = explicit.store.prepareTurnAttempt(
      explicit.conversationId,
      'plain',
      { sendWithoutProjectContext: true },
    )!;
    expect(plain.commit()).toBe(true);
    expect(
      selectProjectContextSnapshotReferences(
        explicit.store.getState(),
        explicit.conversationId,
      ),
    ).toEqual([]);

    const completed = scopedReadyProjectStore();
    const terminal = completed.store.prepareTurnAttempt(
      completed.conversationId,
      'done',
    )!;
    expect(terminal.commit()).toBe(true);
    expect(
      completed.store.startAttemptRound(
        completed.conversationId,
        terminal.attemptId,
        ROUND_ID,
        0,
      ),
    ).toBe(true);
    expect(
      completed.store.recordAttemptRound(
        completed.conversationId,
        terminal.attemptId,
        schema3Receipt(terminal),
      ),
    ).toBe(true);
    expect(
      completed.store.completeAttempt(
        completed.conversationId,
        terminal.attemptId,
        'complete',
        {
          metadata: {
            modelId: 'deepseek-v4-flash',
            latencyMs: 1,
            finishReason: 'stop',
          },
        },
      ),
    ).not.toBeNull();
    expect(
      selectProjectContextSnapshotReferences(
        completed.store.getState(),
        completed.conversationId,
      ),
    ).toEqual([]);

    const oldVisible = scopedReadyProjectStore();
    const failed = oldVisible.store.prepareTurnAttempt(
      oldVisible.conversationId,
      'old',
    )!;
    expect(failed.commit()).toBe(true);
    expect(
      oldVisible.store.failAttempt(
        oldVisible.conversationId,
        failed.attemptId,
        'E_COMPLETION_TRANSPORT',
      ),
    ).toBe(true);
    oldVisible.store.appendAssistantMessage(
      oldVisible.conversationId,
      'history advanced',
    );
    expect(
      selectProjectContextSnapshotReferences(
        oldVisible.store.getState(),
        oldVisible.conversationId,
        SNAPSHOT_ID,
      ),
    ).toEqual([]);
  });

  test('bounds snapshot reference rows without returning raw context metadata', () => {
    const fixture = scopedReadyProjectStore();
    const prepared = fixture.store.prepareTurnAttempt(
      fixture.conversationId,
      'bounded',
    )!;
    expect(prepared.commit()).toBe(true);
    const state = fixture.store.getState();
    const conversation = state.conversations[fixture.conversationId]!;
    const source = conversation.attempts[0]!;
    const attempts = Array.from({ length: 2_000 }, (_, index) => ({
      ...source,
      attemptId: `${index
        .toString(16)
        .padStart(8, '0')}-0000-4000-8000-000000000000`,
    }));
    const adversarialState: ChatState = {
      ...state,
      conversations: {
        ...state.conversations,
        [fixture.conversationId]: { ...conversation, attempts },
      },
    };

    const rows = selectProjectContextSnapshotReferences(
      adversarialState,
      fixture.conversationId,
      SNAPSHOT_ID,
    );
    expect(rows.length).toBeGreaterThan(0);
    expect(rows.length).toBeLessThanOrEqual(
      MAX_PROJECT_CONTEXT_SNAPSHOT_REFERENCE_ROWS,
    );
    expect(JSON.stringify(rows)).not.toMatch(
      /snapshot|consent|source|fingerprint|contextBytes|projectContext/u,
    );
  });

  test('snapshot reference selector fails closed for missing and hostile inputs', () => {
    const fixture = scopedReadyProjectStore();
    expect(
      selectProjectContextSnapshotReferences(
        fixture.store.getState(),
        'missing-conversation',
      ),
    ).toEqual([]);

    let coercions = 0;
    const hostile = {
      [Symbol.toPrimitive]: () => {
        coercions += 1;
        throw new Error('REFERENCE_SELECTOR_SECRET');
      },
    };
    expect(() =>
      selectProjectContextSnapshotReferences(
        fixture.store.getState(),
        hostile as unknown as string,
        hostile as unknown as string,
      ),
    ).not.toThrow();
    expect(
      selectProjectContextSnapshotReferences(
        fixture.store.getState(),
        hostile as unknown as string,
        hostile as unknown as string,
      ),
    ).toEqual([]);
    expect(coercions).toBe(0);

    const hostileState = new Proxy({} as ChatState, {
      get: () => {
        throw new Error('HOSTILE_STATE_SECRET');
      },
    });
    expect(() =>
      selectProjectContextSnapshotReferences(
        hostileState,
        fixture.conversationId,
      ),
    ).not.toThrow();
    expect(
      selectProjectContextSnapshotReferences(
        hostileState,
        fixture.conversationId,
      ),
    ).toEqual([]);

    const validAttempt = fixture.store.prepareTurnAttempt(
      fixture.conversationId,
      'valid before hostile',
    )!;
    expect(validAttempt.commit()).toBe(true);
    let getterCalls = 0;
    const hostileAttempt = {};
    Object.defineProperty(hostileAttempt, 'attemptId', {
      enumerable: true,
      get: () => {
        getterCalls += 1;
        throw new Error('ATTEMPT_GETTER_SECRET');
      },
    });
    const current = fixture.store.getState();
    const currentConversation = current.conversations[fixture.conversationId]!;
    const hostileAttemptState = {
      ...current,
      conversations: {
        ...current.conversations,
        [fixture.conversationId]: {
          ...currentConversation,
          attempts: [...currentConversation.attempts, hostileAttempt],
        },
      },
    } as ChatState;
    expect(
      selectProjectContextSnapshotReferences(
        hostileAttemptState,
        fixture.conversationId,
      ),
    ).toEqual([]);
    expect(getterCalls).toBe(0);
  });

  test('session authority has one store owner and can be explicitly cleared', () => {
    const store = createChatStore();
    expect(store.getSessionAuthority()).toBeNull();
    expect(
      store.setSessionAuthority({
        generation: 18,
        sessionSha256: 'a'.repeat(64),
      }),
    ).toBe(true);
    expect(store.getSessionAuthority()).toEqual({
      generation: 18,
      sessionSha256: 'a'.repeat(64),
    });
    expect(store.setSessionAuthority(null)).toBe(true);
    expect(store.getSessionAuthority()).toBeNull();
  });
});

test('preference-only synchronization validates fields and preserves workspace transaction ownership', () => {
  const store = createChatStore();
  const conversationId = store.createConversation();
  const original = store.getState().conversations[conversationId];
  const binding = store.applyConversationWorkspaceBinding({
    schema_version: 1,
    owner: { conversation_id: conversationId, expected_conversation: original,
      expected_project_context: original.projectContext,
      expected_destructive_epoch: store.getState().projectContextDestructiveEpoch },
    binding: { schema_version: 1, workspace_id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', binding_revision: 1, project_id: null },
  });
  expect(binding).not.toBeNull();
  const candidate = store.getState();
  const authority = { generation: 3, sessionSha256: 'a'.repeat(64) };
  store.setSessionAuthority(authority);
  const preferences = createPreferencesStore();
  preferences.setShowReasoning(true);
  expect(store.setPreferences(preferences.serialize())).toBe(true);
  expect(store.getState().conversations).toBe(candidate.conversations);
  expect(store.getState().conversations[conversationId]).toBe(candidate.conversations[conversationId]);
  expect(store.getSessionAuthority()).toEqual(authority);
  expect(JSON.parse(store.serialize()).preferences.show_reasoning).toBe(true);
  expect(binding!.commit()).toBe(true);
  const after = store.getState();
  expect(store.setPreferences({ schema_version: 999 })).toBe(false);
  expect(store.getState()).toBe(after);
});

test('retry after model selection freezes the new selection and keeps the failed image source unchanged', () => {
  const store = createChatStore();
  const id = store.createConversation({ modelId: 'deepseek-v4-flash-vision-exp', thinkingMode: 'high' });
  const image = { schema_version: 1 as const, id: 'retry-image', kind: 'image' as const, name: 'image.png', mime_type: 'image/png', size: 100 };
  const first = store.prepareTurnAttempt(id, 'What is this?', { attachments: [image] })!;
  expect(first.commit()).toBe(true);
  expect(store.failAttempt(id, first.attemptId, 'E_COMPLETION_RESPONSE_MODEL')).toBe(true);
  const failed = store.getState().conversations[id].attempts[0];
  store.setModel(id, 'deepseek-v4-flash');
  store.setThinkingMode(id, 'off');
  const retry = store.retryAttempt(id, first.attemptId)!;
  expect(retry).not.toBeNull();
  const attempt = store.getState().conversations[id].attempts.at(-1)!;
  expect(attempt).toMatchObject({ modelId: 'deepseek-v4-flash', thinkingMode: 'off', harnessId: 'dsh', attachmentIds: ['retry-image'] });
  expect(attempt.visibleMessageIds).toEqual(failed.visibleMessageIds);
  expect(store.getState().conversations[id].attempts[0]).toEqual(failed);
  expect(retry.commit()).toBe(true);
  expect(store.startAttemptRound(id, retry.attemptId, '11111111-1111-4111-8111-111111111111', 0)).toBe(true);
});
