import {
  CHAT_STATE_SCHEMA_VERSION,
  createChatStore,
  createEmptyChatState,
  hydrateChatState,
  serializeChatState,
} from '../src/state';

const T0 = '2026-08-29T00:00:00.000Z';
const WS_ID = '11111111-1111-4111-8111-111111111111';
const OTHER_WS_ID = '22222222-2222-4222-8222-222222222222';
const PROJECT_ID = '33333333-3333-4333-8333-333333333333';
const OTHER_PROJECT_ID = '44444444-4444-4444-8444-444444444444';
const OPERATION_ID = '55555555-5555-4555-8555-555555555555';
const OTHER_OPERATION_ID = '66666666-6666-4666-8666-666666666666';
const CLEARANCE_RECEIPT_ID = '77777777-7777-4777-8777-777777777777';
const OTHER_CLEARANCE_RECEIPT_ID = '88888888-8888-4888-8888-888888888888';
const ROUND_ID = '99999999-9999-4999-8999-999999999999';
const RUNTIME_ID = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const SNAPSHOT_ID = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const CONSENT_ID = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const BLOCKED_BOOTSTRAP_STATES = [
  'blocked_invalid_legacy_id',
  'blocked_missing_legacy_workspace',
] as const;

function workspaceBindingInput(
  store: ReturnType<typeof createChatStore>,
  conversationId: string,
  workspaceId: string,
  bindingRevision: number,
  projectId: string | null,
) {
  const state = store.getState();
  const conversation = state.conversations[conversationId]!;
  return {
    schema_version: 1 as const,
    owner: {
      conversation_id: conversationId,
      expected_conversation: conversation,
      expected_project_context: conversation.projectContext,
      expected_destructive_epoch: state.projectContextDestructiveEpoch,
    },
    binding: {
      schema_version: 1 as const,
      workspace_id: workspaceId,
      binding_revision: bindingRevision,
      project_id: projectId,
    },
  };
}

function authorityMutationInput(
  store: ReturnType<typeof createChatStore>,
  operationId: string,
  clearanceReceiptId: string,
) {
  return {
    schemaVersion: 1 as const,
    operationId,
    action: 'forget' as const,
    workspaceId: WS_ID,
    bindingRevision: 1,
    clearanceReceiptId,
    expectedState: store.getState(),
  };
}

function establishedAuthorityOutbox() {
  const store = createChatStore({ now: () => T0 });
  const conversationId = store.createConversation({ workspaceId: WS_ID });
  const transaction = store.applyWorkspaceAuthorityMutation(
    authorityMutationInput(store, OPERATION_ID, CLEARANCE_RECEIPT_ID),
  );
  expect(transaction).not.toBeNull();
  expect(transaction?.commit()).toBe(true);
  return { store, conversationId };
}

function blockedBootstrapStore(
  workspaceBootstrapState: (typeof BLOCKED_BOOTSTRAP_STATES)[number],
  confirmedContext = false,
) {
  const source = createChatStore({
    now: () => T0,
    createId: () => 'conversation-1',
  });
  source.createConversation({ projectId: PROJECT_ID });
  const payload = JSON.parse(source.serialize()) as Record<string, unknown>;
  const conversation = (payload.conversations as Array<Record<string, unknown>>)[0]!;
  conversation.workspace_id = null;
  conversation.workspace_binding = null;
  conversation.workspace_bootstrap_state = workspaceBootstrapState;
  if (confirmedContext) {
    conversation.runtime_context_id = RUNTIME_ID;
    conversation.project_context = {
      schema_version: 1,
      project_id: PROJECT_ID,
      status: 'ready',
      selected_paths: [],
      active_preparation_id: null,
      manifest: {
        schema_version: 1,
        snapshot_id: SNAPSHOT_ID,
        project_id: PROJECT_ID,
        project_name: 'demo',
        branch: null,
        head_oid: null,
        clean: true,
        conflicted: false,
        captured_at: T0,
        policy_version: 'chat-read-v1.0.0',
        provider_host: 'api.deepseek.com',
        model: 'deepseek-v4-flash',
        included: [],
        omitted: [],
        context_bytes: 1,
        estimated_tokens: 1,
        snapshot_sha256: 'd'.repeat(64),
        source_fingerprint: 'e'.repeat(64),
      },
      consent: {
        schema_version: 1,
        consent_receipt_id: CONSENT_ID,
        snapshot_id: SNAPSHOT_ID,
        snapshot_sha256: 'd'.repeat(64),
        confirmed_at: T0,
      },
      stale_reason: null,
      error_code: null,
    };
  }
  const hydrated = hydrateChatState(payload);
  return {
    store: createChatStore({ now: () => T0, initialState: hydrated }),
    conversationId: 'conversation-1',
  };
}

describe('schema 9 workspace routing state', () => {
  test('migrates schema 7 workspace strings to pending bootstrap without inventing a revision', () => {
    const source = createChatStore({
      now: () => T0,
      createId: () => 'conversation-1',
    });
    source.createConversation({ projectId: PROJECT_ID, workspaceId: WS_ID });
    const payload = JSON.parse(source.serialize()) as Record<string, unknown>;
    payload.schema_version = 7;
    delete payload.workspace_authority_outbox;
    delete payload.agent_transcript_cleanup_outbox;
    delete payload.session_events;
    delete payload.preferences;
    (payload.conversations as Array<Record<string, unknown>>).forEach(
      conversation => {
        delete conversation.workspace_binding;
        delete conversation.workspace_bootstrap_state;
        delete conversation.agent_grants;
      },
    );
    const migrated = hydrateChatState(payload);

    expect(CHAT_STATE_SCHEMA_VERSION).toBe(9);
    expect(migrated.workspaceAuthorityOutbox).toEqual([]);
    expect(migrated.conversations['conversation-1']).toMatchObject({
      workspaceId: null,
      workspaceBinding: null,
      workspaceBootstrapState: 'pending_legacy_project',
    });
    expect(serializeChatState(migrated)).not.toContain(WS_ID);
  });

  test('commits an exact workspace/project binding once and freezes it into attempts', () => {
    const store = createChatStore({
      now: () => T0,
      createId: () => 'conversation-1',
      createLifecycleId: kind => {
        if (kind === 'turn') return '44444444-4444-4444-8444-444444444444';
        if (kind === 'attempt') return '55555555-5555-4555-8555-555555555555';
        return '66666666-6666-4666-8666-666666666666';
      },
    });
    const conversationId = store.createConversation({
      projectId: PROJECT_ID,
      select: true,
    });
    const before = store.getState().conversations[conversationId]!;
    const transaction = store.applyConversationWorkspaceBinding({
      schema_version: 1,
      owner: {
        conversation_id: conversationId,
        expected_conversation: before,
        expected_project_context: before.projectContext,
        expected_destructive_epoch: 0,
      },
      binding: {
        schema_version: 1,
        workspace_id: WS_ID,
        binding_revision: 1,
        project_id: PROJECT_ID,
      },
    });

    expect(transaction?.commit()).toBe(true);
    const bound = store.getState().conversations[conversationId]!;
    expect(bound.workspaceId).toBe(WS_ID);
    expect(bound.workspaceBinding).toEqual({
      schemaVersion: 1,
      workspaceId: WS_ID,
      bindingRevision: 1,
      projectId: PROJECT_ID,
    });
    expect(bound.workspaceBootstrapState).toBe('none');

    const attempt = store.prepareTurnAttempt(conversationId, 'frozen', {
      sendWithoutProjectContext: true,
    })!;
    expect(attempt.commit()).toBe(true);
    expect(store.getState().conversations[conversationId]!.attempts[0]).toMatchObject({
      workspaceId: WS_ID,
      workspaceBindingRevision: 1,
      contextProjectId: PROJECT_ID,
    });

    expect(transaction?.commit()).toBe(false);
  });

  test('does not apply a stale owner and preserves unrelated selection changes on rollback', () => {
    const state = createEmptyChatState();
    const store = createChatStore({ now: () => T0, initialState: state });
    const first = store.createConversation({ select: true });
    const second = store.createConversation({ select: false });
    const expected = store.getState().conversations[first]!;
    store.selectConversation(second);

    const transaction = store.applyConversationWorkspaceBinding({
      schema_version: 1,
      owner: {
        conversation_id: first,
        expected_conversation: expected,
        expected_project_context: expected.projectContext,
        expected_destructive_epoch: 0,
      },
      binding: {
        schema_version: 1,
        workspace_id: OTHER_WS_ID,
        binding_revision: 2,
        project_id: null,
      },
    });
    expect(transaction).not.toBeNull();
    store.selectConversation(second);
    expect(transaction?.rollback()).toBe(true);
    expect(store.getState().selectedConversationId).toBe(second);
    expect(store.getState().conversations[first]!.workspaceBinding).toBeNull();
  });

  test('blocks workspace binding changes after terminal or historical attempts', () => {
    const store = createChatStore({ now: () => T0 });
    const conversationId = store.createConversation();
    const prepared = store.prepareTurnAttempt(conversationId, 'history')!;
    expect(prepared.commit()).toBe(true);
    expect(
      store.failAttempt(
        conversationId,
        prepared.attemptId,
        'E_COMPLETION_NATIVE',
      ),
    ).toBe(true);

    const before = store.getState();
    expect(
      store.applyConversationWorkspaceBinding(
        workspaceBindingInput(store, conversationId, WS_ID, 1, null),
      ),
    ).toBeNull();
    expect(store.getState()).toBe(before);
  });

  /** A conversation bound the V2 way, so its attempts freeze the workspace tuple. */
  function boundConversation(store: ReturnType<typeof createChatStore>): string {
    const conversationId = store.createConversation();
    const binding = store.applyConversationWorkspaceBinding(
      workspaceBindingInput(store, conversationId, WS_ID, 1, null),
    );
    expect(binding?.commit()).toBe(true);
    return conversationId;
  }

  test('clears a workspace whose attempts have finished; the attempts keep their history', () => {
    const store = createChatStore({ now: () => T0 });
    const conversationId = boundConversation(store);
    const prepared = store.prepareTurnAttempt(conversationId, 'ran here', {
      sendWithoutProjectContext: true,
    })!;
    expect(prepared.commit()).toBe(true);
    expect(
      store.failAttempt(conversationId, prepared.attemptId, 'E_COMPLETION_NATIVE'),
    ).toBe(true);
    expect(
      store.getState().conversations[conversationId]!.attempts[0]!.workspaceId,
    ).toBe(WS_ID);

    const transaction = store.applyWorkspaceAuthorityMutation(
      authorityMutationInput(store, OPERATION_ID, CLEARANCE_RECEIPT_ID),
    );
    expect(transaction).not.toBeNull();
    const cleared = store.getState().conversations[conversationId]!;
    expect(cleared.workspaceId).toBeNull();
    expect(cleared.workspaceBinding).toBeNull();
    expect(cleared.workspaceBootstrapState).toBe('none');
    // The attempt lets go of the tuple it froze and keeps everything else.
    expect(cleared.attempts[0]!.workspaceId).toBeNull();
    expect(cleared.attempts[0]!.workspaceBindingRevision).toBeNull();
    expect(cleared.attempts[0]!.status).toBe('failed');
    expect(cleared.attempts[0]!.attemptId).toBe(prepared.attemptId);
    expect(store.getState().workspaceAuthorityOutbox).toHaveLength(1);
    // And the serialized candidate is still one the schema accepts.
    expect(() => store.serialize()).not.toThrow();
    expect(transaction?.rollback()).toBe(true);
    expect(store.getState().conversations[conversationId]!.attempts[0]!.workspaceId).toBe(WS_ID);
  });

  test('drops the project with the binding instead of leaving a legacy project to bootstrap', () => {
    const store = createChatStore({ now: () => T0 });
    const conversationId = store.createConversation({
      workspaceId: WS_ID,
      projectId: PROJECT_ID,
    });
    const transaction = store.applyWorkspaceAuthorityMutation(
      authorityMutationInput(store, OPERATION_ID, CLEARANCE_RECEIPT_ID),
    );
    expect(transaction).not.toBeNull();
    const cleared = store.getState().conversations[conversationId]!;
    expect(cleared.workspaceId).toBeNull();
    expect(cleared.projectId).toBeNull();
    expect(cleared.projectContext).toBeNull();
    expect(cleared.workspaceBootstrapState).toBe('none');
    expect(() => store.serialize()).not.toThrow();

    expect(transaction?.rollback()).toBe(true);
    const restored = store.getState().conversations[conversationId]!;
    expect(restored.workspaceId).toBe(WS_ID);
    expect(restored.projectId).toBe(PROJECT_ID);
    expect(store.getState().workspaceAuthorityOutbox).toHaveLength(0);
  });

  test('refuses to clear a workspace while an attempt still holds it', () => {
    const live = createChatStore({ now: () => T0 });
    const liveId = boundConversation(live);
    expect(
      live.prepareTurnAttempt(liveId, 'still running', { sendWithoutProjectContext: true })!.commit(),
    ).toBe(true);
    expect(live.getState().conversations[liveId]!.attempts[0]!.workspaceId).toBe(WS_ID);
    const beforeLive = live.getState();
    expect(
      live.applyWorkspaceAuthorityMutation(
        authorityMutationInput(live, OPERATION_ID, CLEARANCE_RECEIPT_ID),
      ),
    ).toBeNull();
    expect(live.getState()).toBe(beforeLive);

    // A finished attempt whose transcript is still to be swept holds it too.
    const sweeping = createChatStore({ now: () => T0 });
    const sweepingId = boundConversation(sweeping);
    const prepared = sweeping.prepareTurnAttempt(sweepingId, 'interrupted', {
      sendWithoutProjectContext: true,
    })!;
    expect(prepared.commit()).toBe(true);
    expect(
      sweeping.failAttempt(sweepingId, prepared.attemptId, 'E_ATTEMPT_INTERRUPTED'),
    ).toBe(true);
    const outbox = sweeping.getState().agentTranscriptCleanupOutbox ?? [];
    if (outbox.some(entry => entry.attempt_id === prepared.attemptId)) {
      expect(
        sweeping.applyWorkspaceAuthorityMutation(
          authorityMutationInput(sweeping, OPERATION_ID, CLEARANCE_RECEIPT_ID),
        ),
      ).toBeNull();
    }
  });

  test('blocks legacy workspace bind and unbind actions while an attempt is live', () => {
    const boundLater = createChatStore({ now: () => T0 });
    const boundLaterId = boundLater.createConversation();
    expect(boundLater.prepareTurnAttempt(boundLaterId, 'live')).not.toBeNull();
    const beforeBind = boundLater.getState();
    boundLater.bindConversationToWorkspace(boundLaterId, WS_ID);
    expect(boundLater.getState()).toBe(beforeBind);

    const unboundLater = createChatStore({ now: () => T0 });
    const unboundLaterId = unboundLater.createConversation({
      workspaceId: WS_ID,
    });
    expect(
      unboundLater.prepareTurnAttempt(unboundLaterId, 'live'),
    ).not.toBeNull();
    const beforeUnbind = unboundLater.getState();
    unboundLater.unbindConversationFromWorkspace(unboundLaterId);
    expect(unboundLater.getState()).toBe(beforeUnbind);
  });

  test('requires workspace binding revisions to increase without same-revision project switches', () => {
    const rollbackStore = createChatStore({ now: () => T0 });
    const rollbackId = rollbackStore.createConversation();
    const initial = rollbackStore.applyConversationWorkspaceBinding(
      workspaceBindingInput(rollbackStore, rollbackId, WS_ID, 2, null),
    );
    expect(initial?.commit()).toBe(true);
    const beforeRollback = rollbackStore.getState();
    expect(
      rollbackStore.applyConversationWorkspaceBinding(
        workspaceBindingInput(
          rollbackStore,
          rollbackId,
          OTHER_WS_ID,
          1,
          null,
        ),
      ),
    ).toBeNull();
    expect(rollbackStore.getState()).toBe(beforeRollback);

    const switchStore = createChatStore({ now: () => T0 });
    const switchId = switchStore.createConversation();
    const first = switchStore.applyConversationWorkspaceBinding(
      workspaceBindingInput(switchStore, switchId, WS_ID, 1, PROJECT_ID),
    );
    expect(first?.commit()).toBe(true);
    const beforeSwitch = switchStore.getState();
    expect(
      switchStore.applyConversationWorkspaceBinding(
        workspaceBindingInput(
          switchStore,
          switchId,
          WS_ID,
          1,
          OTHER_PROJECT_ID,
        ),
      ),
    ).toBeNull();
    expect(switchStore.getState()).toBe(beforeSwitch);
  });

  test('does not prepare project turns from a blocked invalid legacy workspace id', () => {
    const source = createChatStore({
      now: () => T0,
      createId: () => 'conversation-1',
    });
    source.createConversation({ projectId: PROJECT_ID });
    const payload = JSON.parse(source.serialize()) as Record<string, unknown>;
    payload.schema_version = 7;
    delete payload.workspace_authority_outbox;
    delete payload.agent_transcript_cleanup_outbox;
    delete payload.session_events;
    delete payload.preferences;
    (payload.conversations as Array<Record<string, unknown>>).forEach(
      conversation => {
        conversation.workspace_id = 'legacy-invalid';
        delete conversation.workspace_binding;
        delete conversation.workspace_bootstrap_state;
        delete conversation.agent_grants;
      },
    );
    const migrated = hydrateChatState(payload);
    const store = createChatStore({ now: () => T0, initialState: migrated });
    const conversationId = migrated.conversationOrder[0]!;

    expect(
      store.getState().conversations[conversationId]?.workspaceBootstrapState,
    ).toBe('blocked_invalid_legacy_id');
    expect(store.prepareTurnAttempt(conversationId, 'blocked')).toBeNull();
    expect(
      store.prepareTurnAttempt(conversationId, 'blocked explicitly', {
        sendWithoutProjectContext: true,
      }),
    ).toBeNull();
  });

  test('does not rebind or enqueue another authority operation while an outbox entry exists', () => {
    const bindingFixture = establishedAuthorityOutbox();
    expect(
      bindingFixture.store.applyConversationWorkspaceBinding(
        workspaceBindingInput(
          bindingFixture.store,
          bindingFixture.conversationId,
          WS_ID,
          2,
          null,
        ),
      ),
    ).toBeNull();

    const enqueueFixture = establishedAuthorityOutbox();
    const beforeEnqueue = enqueueFixture.store.getState();
    expect(
      enqueueFixture.store.applyWorkspaceAuthorityMutation({
        ...authorityMutationInput(
          enqueueFixture.store,
          OTHER_OPERATION_ID,
          OTHER_CLEARANCE_RECEIPT_ID,
        ),
        expectedState: beforeEnqueue,
      }),
    ).toBeNull();
    expect(enqueueFixture.store.getState()).toBe(beforeEnqueue);
  });

  test('captures the authority transaction candidate before reentrant ack and rebind listeners', () => {
    const { store, conversationId } = (() => {
      const authorityStore = createChatStore({ now: () => T0 });
      return {
        store: authorityStore,
        conversationId: authorityStore.createConversation({
          workspaceId: WS_ID,
        }),
      };
    })();
    let reentered = false;
    store.subscribe(() => {
      if (reentered) return;
      reentered = true;
      expect(
        store.acknowledgeWorkspaceAuthorityMutation(OPERATION_ID),
      ).toBe(true);
      store.bindConversationToWorkspace(conversationId, WS_ID);
    });

    const transaction = store.applyWorkspaceAuthorityMutation(
      authorityMutationInput(store, OPERATION_ID, CLEARANCE_RECEIPT_ID),
    );
    expect(transaction).not.toBeNull();
    expect(transaction?.commit()).toBe(false);
  });

  test('rejects creating a conversation for a workspace with a pending outbox, including listener reentry', () => {
    const store = createChatStore({ now: () => T0 });
    const existingConversationId = store.createConversation({
      workspaceId: WS_ID,
    });
    let reentered = false;
    store.subscribe(state => {
      if (!reentered && state.workspaceAuthorityOutbox?.length === 1) {
        reentered = true;
        store.createConversation({ workspaceId: WS_ID, select: false });
      }
    });

    const transaction = store.applyWorkspaceAuthorityMutation(
      authorityMutationInput(store, OPERATION_ID, CLEARANCE_RECEIPT_ID),
    );
    expect(transaction).not.toBeNull();
    expect(Object.keys(store.getState().conversations)).toEqual([
      existingConversationId,
    ]);
    expect(() => store.serialize()).not.toThrow();
    expect(transaction?.commit()).toBe(true);
  });

  test.each(BLOCKED_BOOTSTRAP_STATES)(
    'blocks prepare from schema8 %s bootstrap state',
    workspaceBootstrapState => {
      const { store, conversationId } = blockedBootstrapStore(
        workspaceBootstrapState,
      );
      expect(
        store.getState().conversations[conversationId]?.workspaceBootstrapState,
      ).toBe(workspaceBootstrapState);
      expect(
        store.prepareTurnAttempt(conversationId, 'blocked explicitly', {
          sendWithoutProjectContext: true,
        }),
      ).toBeNull();
    },
  );

  test.each(BLOCKED_BOOTSTRAP_STATES)(
    'blocks confirmed project context from schema8 %s bootstrap state',
    workspaceBootstrapState => {
      const { store, conversationId } = blockedBootstrapStore(
        workspaceBootstrapState,
        true,
      );
      expect(store.prepareTurnAttempt(conversationId, 'confirmed')).toBeNull();
      expect(
        store.prepareTurnAttempt(conversationId, 'confirmed explicitly', {
          sendWithoutProjectContext: true,
        }),
      ).toBeNull();
    },
  );

  test.each(BLOCKED_BOOTSTRAP_STATES)(
    'blocks start and retry from schema8 %s bootstrap state',
    workspaceBootstrapState => {
      const source = createChatStore({ now: () => T0 });
      const conversationId = source.createConversation();
      const prepared = source.prepareTurnAttempt(conversationId, 'live')!;
      expect(prepared.commit()).toBe(true);
      const liveState = source.getState();
      const blockedLiveState = {
        ...liveState,
        conversations: {
          ...liveState.conversations,
          [conversationId]: {
            ...liveState.conversations[conversationId]!,
            workspaceBootstrapState,
          },
        },
      };
      const startStore = createChatStore({
        now: () => T0,
        initialState: blockedLiveState,
      });
      expect(
        startStore.startAttemptRound(
          conversationId,
          prepared.attemptId,
          ROUND_ID,
          0,
        ),
      ).toBe(false);

      const retrySource = createChatStore({ now: () => T0 });
      const retryConversationId = retrySource.createConversation();
      const retryable = retrySource.prepareTurnAttempt(
        retryConversationId,
        'retryable',
      )!;
      expect(retryable.commit()).toBe(true);
      expect(
        retrySource.failAttempt(
          retryConversationId,
          retryable.attemptId,
          'E_COMPLETION_NATIVE',
        ),
      ).toBe(true);
      const retryState = retrySource.getState();
      const blockedRetryState = {
        ...retryState,
        conversations: {
          ...retryState.conversations,
          [retryConversationId]: {
            ...retryState.conversations[retryConversationId]!,
            workspaceBootstrapState,
          },
        },
      };
      const retryStore = createChatStore({
        now: () => T0,
        initialState: blockedRetryState,
      });
      expect(
        retryStore.retryAttempt(retryConversationId, retryable.attemptId),
      ).toBeNull();
    },
  );
});
