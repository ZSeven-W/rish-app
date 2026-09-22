import { sanitizeCompletionError } from '../src/completion/validation';
import {
  createCompletionController,
  type CompletionController,
} from '../src/completion/CompletionController';
import type {
  CompleteRoundV2Request,
  CompleteRoundV2Result,
  CompleteRoundV3Request,
  CompleteRoundV3Result,
} from '../src/completion/types';
import type { SessionDurabilityResult } from '../src/completion/SessionPersistence';
import type { AgentRoundPreviewEvent } from '../src/agent/AgentRoundPreview';
import type { AgentRoundPreviews } from '../src/completion/CompletionController';
import { sessionSnapshotSHA256 } from '../src/completion/SessionPersistence';
import {
  providerHostForModel,
  type HarnessModelId,
} from '../src/harness/types';
import type {
  AgentRuntimeFacadeV2,
  AgentAttemptProjectionV2,
  AgentBatchReceiptV2,
  AgentBatchCallProjectionV2,
  AgentRuntimeRootV1,
  AgentRuntimePolicyV1,
  AgentRuntimeRegistryV2,
  AgentRuntimeTranscriptHandleV1,
  AgentApprovalBindingTokenV2,
  AgentConversationGrantV2,
  AgentToolReceiptV1,
  AgentRoundReceiptV2,
  CompleteAgentRoundRequestV2,
  CompleteAgentRoundResultV2,
  PrepareAgentAttemptRequestV2,
  PrepareAgentToolBatchRequestV2,
  PrepareAgentToolBatchResultV2,
  BindAgentApprovalRequestV2,
  ExecuteAgentToolRequestV2,
  ExecuteAgentToolResultV2,
  CancelAgentAttemptResultV2,
  QueryAgentAttemptResultV2,
  RecoverAgentAttemptResultV2,
} from '../src/native/AgentRuntime';
import type {
  CompletionAgentApprovalRequest,
  CompletionControllerDependencies,
  CompletionPersistenceResult,
} from '../src/completion/CompletionController';
import {
  createSessionEventJournal,
  type SessionEventEmission,
} from '../src/agent/SessionEvents';
import {
  createChatStore,
  hydrateChatState,
  type ChatStore,
} from '../src/state';
import type {
  ProjectContextConsentV1,
  ProjectContextManifestV1,
  ProjectContextState,
} from '../src/project-context';

declare const __dirname: string;

const nodeFs = jest.requireActual('node:fs') as {
  readFileSync(path: string, encoding: 'utf8'): string;
  writeFileSync(path: string, data: string): void;
};
const nodePath = jest.requireActual('node:path') as {
  resolve(...paths: string[]): string;
};

const NOW = '2026-08-28T01:00:00.000Z';
const LATER = '2026-08-28T01:00:01.000Z';
const TURN_ID = '11111111-1111-4111-8111-111111111111';
const ATTEMPT_ID = '22222222-2222-4222-8222-222222222222';
const RETRY_ID = '33333333-3333-4333-8333-333333333333';
const ROUND_ID = '44444444-4444-4444-8444-444444444444';
const RUNTIME_ID = '55555555-5555-4555-8555-555555555555';
const SNAPSHOT_ID = '66666666-6666-4666-8666-666666666666';
const CONSENT_ID = '77777777-7777-4777-8777-777777777777';
const PROJECT_ID = '88888888-8888-4888-8888-888888888888';
const PROVIDER_REQUEST_ID = '99999999-9999-4999-8999-999999999999';
const CONTEXT_PREPARATION_ID =
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>(resolvePromise => {
    resolve = resolvePromise;
  });
  return { promise, resolve };
}

function storeWithIds(ids = [TURN_ID, ATTEMPT_ID, RETRY_ID]): ChatStore {
  let message = 0;
  const queue = [...ids];
  return createChatStore({
    now: () => NOW,
    createId: kind => `${kind}-${++message}`,
    createLifecycleId: () => queue.shift() ?? RETRY_ID,
  });
}

function v2Result(request: CompleteRoundV2Request): CompleteRoundV2Result {
  return {
    schema_version: 2,
    harness_id: request.harnessId,
    turn_id: request.turnId,
    attempt_id: request.attemptId,
    round_id: request.roundId,
    round_index: request.roundIndex,
    provider_request_id: PROVIDER_REQUEST_ID,
    provider_response_id: 'resp_1',
    requested_model: request.model,
    model: request.model,
    thinking_mode: request.thinkingMode,
    text: 'Strict local answer',
    reasoning: 'actual reasoning',
    tool_calls: [],
    finish_reason: 'stop',
    latency_ms: 12,
    visible_history_sha256: 'a'.repeat(64),
    model_input_sha256: 'b'.repeat(64),
    request_body_sha256: 'c'.repeat(64),
    project_context_receipt: null,
  };
}

function v3Result(request: CompleteRoundV3Request): CompleteRoundV3Result {
  return {
    ...v2Result({ ...request, schemaVersion: 2, projectContext: null }),
    schema_version: 3,
    project_context_receipt: {
      schema_version: 1,
      snapshot_id: SNAPSHOT_ID,
      snapshot_sha256: 'd'.repeat(64),
      source_fingerprint: 'e'.repeat(64),
      context_bytes: 20,
      verified_at: LATER,
    },
  };
}

type Fixture = {
  readonly store: ChatStore;
  readonly controller: CompletionController;
  readonly persistCurrent: jest.Mock<Promise<SessionDurabilityResult>, []>;
  readonly completeRoundV2: jest.Mock<
    Promise<CompleteRoundV2Result>,
    [CompleteRoundV2Request]
  >;
  readonly completeRoundV3: jest.Mock<
    Promise<CompleteRoundV3Result>,
    [CompleteRoundV3Request]
  >;
  readonly cancelRoundV2: jest.Mock;
  readonly cancelRoundV3: jest.Mock;
  readonly createRoundId: jest.Mock<string, []>;
  readonly onSessionEvent: jest.Mock;
};

function fixture(options: {
  store?: ChatStore;
  durability?: SessionDurabilityResult[];
  persistCurrent?: Fixture['persistCurrent'];
  completeRoundV2?: Fixture['completeRoundV2'];
  completeRoundV3?: Fixture['completeRoundV3'];
  cancelRoundV2?: Fixture['cancelRoundV2'];
  cancelRoundV3?: Fixture['cancelRoundV3'];
  createRoundId?: Fixture['createRoundId'];
  onSessionEvent?: Fixture['onSessionEvent'];
} = {}): Fixture {
  const store = options.store ?? storeWithIds();
  const durability = options.durability ?? [
    { status: 'committed' },
    { status: 'committed' },
    { status: 'committed' },
  ];
  const persistCurrent =
    options.persistCurrent ??
    jest.fn(async () =>
      durability.shift() ?? { status: 'committed' as const },
    );
  const completeRoundV2 =
    options.completeRoundV2 ?? jest.fn(async request => v2Result(request));
  const completeRoundV3 =
    options.completeRoundV3 ?? jest.fn(async request => v3Result(request));
  const cancelRoundV2 =
    options.cancelRoundV2 ?? jest.fn(async () => undefined);
  const cancelRoundV3 =
    options.cancelRoundV3 ?? jest.fn(async () => undefined);
  const createRoundId = options.createRoundId ?? jest.fn(() => ROUND_ID);
  const onSessionEvent =
    options.onSessionEvent ?? jest.fn();
  const controller = createCompletionController({
    chat: store,
    persistCurrent,
    completeRoundV2,
    completeRoundV3,
    cancelRoundV2,
    cancelRoundV3,
    createRoundId,
    onSessionEvent,
  });
  return {
    store,
    controller,
    persistCurrent,
    completeRoundV2,
    completeRoundV3,
    cancelRoundV2,
    cancelRoundV3,
    createRoundId,
    onSessionEvent,
  };
}

function commitDestructiveJournal(store: ChatStore) {
  const conversation = Object.values(store.getState().conversations).find(
    candidate => candidate.projectContext?.snapshot !== null,
  )!;
  const transaction = store.beginProjectContextDestructiveTransition({
    lifecycleId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    action: 'unbind',
    targetProjectId: null,
    owner: {
      conversationId: conversation.id,
      projectId: conversation.projectId!,
      runtimeContextId: conversation.runtimeContextId,
      modelId: conversation.modelId,
      expectedUpdatedAt: conversation.updatedAt,
      expectedContext: conversation.projectContext!,
    },
  });
  expect(transaction).not.toBeNull();
  expect(transaction!.commit()).toBe(true);
}

function readyProjectStore(): ChatStore {
  const store = storeWithIds([RUNTIME_ID, TURN_ID, ATTEMPT_ID, RETRY_ID]);
  const conversationId = store.createConversation({ projectId: PROJECT_ID });
  const manifest: ProjectContextManifestV1 = {
    schema_version: 1,
    snapshot_id: SNAPSHOT_ID,
    project_id: PROJECT_ID,
    project_name: 'demo',
    branch: 'main',
    head_oid: '0'.repeat(40),
    clean: true,
    conflicted: false,
    captured_at: NOW,
    policy_version: 'chat-read-v1.0.0',
    provider_host: 'api.deepseek.com',
    model: 'deepseek-v4-flash',
    included: [
      {
        path: 'README.md',
        source: 'tracked_file',
        bytes: 20,
        sha256: 'f'.repeat(64),
      },
    ],
    omitted: [],
    context_bytes: 20,
    estimated_tokens: 5,
    snapshot_sha256: 'd'.repeat(64),
    source_fingerprint: 'e'.repeat(64),
  };
  const consent: ProjectContextConsentV1 = {
    schema_version: 1,
    consent_receipt_id: CONSENT_ID,
    snapshot_id: SNAPSHOT_ID,
    snapshot_sha256: 'd'.repeat(64),
    confirmed_at: LATER,
  };
  expect(store.ensureRuntimeContextId(conversationId)).toBe(RUNTIME_ID);
  const preparedConversation = store.getState().conversations[conversationId]!;
  const prepared = store.replaceProjectContextPrepared(
    {
      conversationId,
      projectId: PROJECT_ID,
      runtimeContextId: RUNTIME_ID,
      modelId: preparedConversation.modelId,
      expectedContext: preparedConversation.projectContext!,
    },
    {
      preparationId: CONTEXT_PREPARATION_ID,
      selectedPaths: ['README.md'],
      manifest,
    },
  );
  expect(prepared).not.toBeNull();
  expect(prepared!.commit()).toBe(true);

  const confirmedConversation = store.getState().conversations[conversationId]!;
  const confirmed = store.replaceProjectContextConfirmed(
    {
      conversationId,
      projectId: PROJECT_ID,
      runtimeContextId: RUNTIME_ID,
      modelId: confirmedConversation.modelId,
      expectedContext: confirmedConversation.projectContext!,
    },
    {
      preparationId: CONTEXT_PREPARATION_ID,
      selectedPaths: ['README.md'],
      manifest,
      consent,
    },
  );
  expect(confirmed).not.toBeNull();
  expect(confirmed!.commit()).toBe(true);
  return store;
}

describe('transactional completion controller', () => {
  test.each(['send', 'retry', 'resume'] as const)(
    'reverse-gates %s while a destructive journal exists with zero side effects',
    async operation => {
      const store = readyProjectStore();
      const conversationId = store.createConversation();
      let attemptId: string | null = null;
      if (operation !== 'send') {
        const prepared = store.prepareTurnAttempt(conversationId, operation)!;
        expect(prepared.commit()).toBe(true);
        attemptId = prepared.attemptId;
        if (operation === 'retry') {
          expect(
            store.failAttempt(
              conversationId,
              attemptId,
              'E_COMPLETION_NATIVE',
            ),
          ).toBe(true);
        }
      }
      commitDestructiveJournal(store);
      const value = fixture({ store });
      const beforeChat = store.getState();
      const beforeController = value.controller.getState();
      const events = {
        onPreparedDurable: jest.fn(),
        onCommitted: jest.fn(),
      };

      const outcome =
        operation === 'send'
          ? await value.controller.send(
              { conversationId, text: 'blocked', attachments: [] },
              events,
            )
          : operation === 'retry'
            ? await value.controller.retry(conversationId, attemptId!, events)
            : await value.controller.resume(conversationId, attemptId!, events);

      expect(outcome).toMatchObject({
        status: 'blocked',
        code: 'E_COMPLETION_BUSY',
      });
      expect(store.getState()).toBe(beforeChat);
      expect(value.controller.getState()).toBe(beforeController);
      expect(value.persistCurrent).not.toHaveBeenCalled();
      expect(value.completeRoundV2).not.toHaveBeenCalled();
      expect(value.completeRoundV3).not.toHaveBeenCalled();
      expect(value.cancelRoundV2).not.toHaveBeenCalled();
      expect(value.cancelRoundV3).not.toHaveBeenCalled();
      expect(value.createRoundId).not.toHaveBeenCalled();
      expect(events.onPreparedDurable).not.toHaveBeenCalled();
      expect(events.onCommitted).not.toHaveBeenCalled();
    },
  );

  test('reverse-gates every remaining public completion action without reading hostile input', async () => {
    const store = readyProjectStore();
    commitDestructiveJournal(store);
    const value = fixture({ store });
    const before = value.controller.getState();
    const hostileInput = new Proxy(
      {},
      {
        get: () => {
          throw new Error('RAW_INPUT_SENTINEL');
        },
      },
    ) as Parameters<CompletionController['send']>[0];

    await expect(value.controller.send(hostileInput)).resolves.toMatchObject({
      status: 'blocked',
      code: 'E_COMPLETION_BUSY',
    });
    await expect(value.controller.retryPersistence()).resolves.toMatchObject({
      status: 'blocked',
      code: 'E_COMPLETION_BUSY',
    });
    await expect(value.controller.retryCommit()).resolves.toMatchObject({
      status: 'blocked',
      code: 'E_COMPLETION_BUSY',
    });
    await expect(value.controller.cancel()).resolves.toBeUndefined();
    await expect(
      value.controller.beforeConversationChange('hostile-conversation'),
    ).resolves.toBe(false);
    await expect(
      value.controller.beforeConversationDelete('hostile-conversation'),
    ).resolves.toBe(false);
    expect(
      value.controller.reconcileHydrated('hostile-conversation'),
    ).toBe(before);

    expect(value.controller.getState()).toBe(before);
    expect(store.getState().projectContextDestructiveTransition).not.toBeNull();
    expect(value.persistCurrent).not.toHaveBeenCalled();
    expect(value.completeRoundV2).not.toHaveBeenCalled();
    expect(value.completeRoundV3).not.toHaveBeenCalled();
    expect(value.cancelRoundV2).not.toHaveBeenCalled();
    expect(value.cancelRoundV3).not.toHaveBeenCalled();
    expect(value.createRoundId).not.toHaveBeenCalled();
  });

  test('runs an unbound turn through exact schema2 durability boundaries', async () => {
    const value = fixture();
    const conversationId = value.store.createConversation();
    const onPreparedDurable = jest.fn();
    const onCommitted = jest.fn();
    const outcome = await value.controller.send(
      { conversationId, text: 'hello', attachments: [] },
      { onPreparedDurable, onCommitted },
    );

    expect(outcome).toMatchObject({ status: 'completed', attemptId: ATTEMPT_ID });
    expect(value.persistCurrent).toHaveBeenCalledTimes(3);
    expect(onPreparedDurable).toHaveBeenCalledTimes(1);
    expect(onCommitted).toHaveBeenCalledTimes(1);
    expect(value.completeRoundV2).toHaveBeenCalledWith({
      schemaVersion: 2,
      harnessId: 'dsh',
      turnId: TURN_ID,
      attemptId: ATTEMPT_ID,
      roundId: ROUND_ID,
      roundIndex: 0,
      model: 'deepseek-v4-flash',
      thinkingMode: 'high',
      visibleHistory: [
        { role: 'user', content: 'hello', attachments: [] },
      ],
      roundTranscript: [],
      tools: [],
      projectContext: null,
    });
    expect(
      value.store.getState().conversations[conversationId]?.attempts[0],
    ).toMatchObject({
      status: 'completed',
      visibleHistorySha256: 'a'.repeat(64),
      rounds: [{ transportSchemaVersion: 2 }],
    });
  });

  test('uses schema3 only for an exact verified project binding', async () => {
    const store = readyProjectStore();
    const value = fixture({ store });
    const conversationId = store.getState().selectedConversationId!;
    await value.controller.send({
      conversationId,
      text: 'read project',
      attachments: [],
    });
    expect(value.completeRoundV2).not.toHaveBeenCalled();
    expect(value.completeRoundV3).toHaveBeenCalledWith(
      expect.objectContaining({
        schemaVersion: 3,
        projectContext: {
          schemaVersion: 1,
          snapshotId: SNAPSHOT_ID,
          consentReceiptId: CONSENT_ID,
          conversationId: RUNTIME_ID,
          projectId: PROJECT_ID,
          provider: 'deepseek',
          policy: 'chat-read-v1',
        },
      }),
    );
  });

  test('uses explicit schema2 without-context for a verified project', async () => {
    const store = readyProjectStore();
    const value = fixture({ store });
    const conversationId = store.getState().selectedConversationId!;

    await value.controller.send({
      conversationId,
      text: 'explicitly omit context',
      attachments: [],
      sendWithoutProjectContext: true,
    });
    expect(value.completeRoundV2).toHaveBeenCalledWith(
      expect.objectContaining({ schemaVersion: 2, projectContext: null }),
    );
    expect(value.completeRoundV3).not.toHaveBeenCalled();
  });

  test('cancels a verified schema3 round through the schema3 alias', async () => {
    const pending = deferred<CompleteRoundV3Result>();
    const store = readyProjectStore();
    const value = fixture({
      store,
      completeRoundV3: jest.fn(
        (_request: CompleteRoundV3Request) => pending.promise,
      ),
    });
    const conversationId = store.getState().selectedConversationId!;
    const run = value.controller.send({
      conversationId,
      text: 'cancel verified context',
      attachments: [],
    });
    for (let index = 0; index < 8; index += 1) await Promise.resolve();

    await value.controller.cancel();
    expect(value.cancelRoundV3).toHaveBeenCalledWith(ROUND_ID);
    expect(value.cancelRoundV2).not.toHaveBeenCalled();
    pending.resolve(v3Result(value.completeRoundV3.mock.calls[0]![0]));
    await expect(run).resolves.toMatchObject({ status: 'cancelled' });
  });

  test.each([
    {
      name: 'tool calls',
      result: (request: CompleteRoundV2Request): CompleteRoundV2Result => ({
        ...v2Result(request),
        text: '',
        tool_calls: [
          { id: 'call_1', name: 'read_file', arguments: '{}' },
        ],
        finish_reason: 'tool_calls',
      }),
    },
    {
      name: 'content filtering',
      result: (request: CompleteRoundV2Request): CompleteRoundV2Result => ({
        ...v2Result(request),
        text: 'provider filtered response',
        finish_reason: 'content_filter',
      }),
    },
  ])('records the terminal receipt but stores no assistant for $name', async ({
    result,
  }) => {
    const value = fixture({
      completeRoundV2: jest.fn(async request => result(request)),
    });
    const conversationId = value.store.createConversation();

    await expect(
      value.controller.send({
        conversationId,
        text: 'terminal relation',
        attachments: [],
      }),
    ).resolves.toMatchObject({
      status: 'retryable',
      code: 'E_COMPLETION_FINISH_RELATION',
    });
    const conversation = value.store.getState().conversations[conversationId]!;
    expect(conversation.attempts[0]).toMatchObject({
      status: 'failed',
      rounds: [{ finishReason: expect.any(String) }],
      assistantMessageId: null,
    });
    expect(conversation.messages.map(message => message.role)).toEqual(['user']);
  });

  test.each([
    {
      name: 'allowlisted native error',
      error: { code: 'E_COMPLETION_TRANSPORT', message: 'PROVIDER_SECRET' },
      expected: 'E_COMPLETION_TRANSPORT',
    },
    {
      name: 'unknown native error',
      error: { code: 'E_PROVIDER_KEY_SECRET', message: 'PROVIDER_SECRET' },
      expected: 'E_COMPLETION_NATIVE',
    },
    {
      name: 'hostile native error',
      error: new Proxy(
        {},
        {
          getOwnPropertyDescriptor() {
            throw new Error('PROVIDER_SECRET');
          },
        },
      ),
      expected: 'E_COMPLETION_NATIVE',
    },
  ])('maps $name to a stable value-free code', async ({ error, expected }) => {
    const value = fixture({
      completeRoundV2: jest.fn(
        async (
          _request: CompleteRoundV2Request,
        ): Promise<CompleteRoundV2Result> => {
        throw error;
        },
      ),
    });
    const conversationId = value.store.createConversation();

    await expect(
      value.controller.send({
        conversationId,
        text: 'sanitize failure',
        attachments: [],
      }),
    ).resolves.toMatchObject({ status: 'retryable', code: expected });
    expect(
      value.store.getState().conversations[conversationId]?.attempts[0]
        ?.failureCode,
    ).toBe(expected);
  });

  test('records and completes synchronously before the single final persist', async () => {
    const base = storeWithIds();
    let persisted: Fixture['persistCurrent'] | null = null;
    const order: Array<readonly [string, number]> = [];
    const chat: ChatStore = {
      ...base,
      recordAttemptRound: (conversationId, attemptId, roundReceipt) => {
        order.push(['record', persisted?.mock.calls.length ?? -1]);
        return base.recordAttemptRound(
          conversationId,
          attemptId,
          roundReceipt,
        );
      },
      completeAttempt: (conversationId, attemptId, text, options) => {
        order.push(['complete', persisted?.mock.calls.length ?? -1]);
        return base.completeAttempt(conversationId, attemptId, text, options);
      },
    };
    const value = fixture({ store: chat });
    persisted = value.persistCurrent;
    const conversationId = chat.createConversation();

    await value.controller.send({
      conversationId,
      text: 'ordered outcome',
      attachments: [],
    });
    expect(order).toEqual([
      ['record', 2],
      ['complete', 2],
    ]);
    expect(value.persistCurrent).toHaveBeenCalledTimes(3);
  });

  test('blocks setup-required projects while preserving explicit schema2 API', async () => {
    const store = storeWithIds();
    const conversationId = store.createConversation({ projectId: PROJECT_ID });
    const value = fixture({ store });
    await expect(
      value.controller.send({ conversationId, text: 'blocked', attachments: [] }),
    ).resolves.toMatchObject({
      status: 'blocked',
      code: 'E_ATTEMPT_CONTEXT_REQUIRED',
    });
    expect(value.persistCurrent).not.toHaveBeenCalled();
    expect(value.completeRoundV2).not.toHaveBeenCalled();

    await expect(
      value.controller.send({
        conversationId,
        text: 'explicit',
        attachments: [],
        sendWithoutProjectContext: true,
      }),
    ).resolves.toMatchObject({ status: 'completed' });
    expect(value.completeRoundV2).toHaveBeenCalledTimes(1);
  });

  test.each(['session_only', 'unknown'] as const)(
    'holds %s preparation without HTTP until retryPersistence commits',
    async status => {
      const value = fixture({
        durability: [
          { status },
          { status: 'committed' },
          { status: 'committed' },
          { status: 'committed' },
        ],
      });
      const conversationId = value.store.createConversation();
      const onPreparedDurable = jest.fn();
      await expect(
        value.controller.send(
          { conversationId, text: 'pending', attachments: [] },
          { onPreparedDurable },
        ),
      ).resolves.toMatchObject({ status: 'persistence_pending' });
      expect(value.completeRoundV2).not.toHaveBeenCalled();
      expect(onPreparedDurable).not.toHaveBeenCalled();

      await expect(value.controller.retryPersistence()).resolves.toMatchObject({
        status: 'completed',
      });
      expect(onPreparedDurable).toHaveBeenCalledTimes(1);
      expect(value.completeRoundV2).toHaveBeenCalledTimes(1);
    },
  );

  test('rolls back not-committed preparation and never calls HTTP', async () => {
    const value = fixture({ durability: [{ status: 'not_committed' }] });
    const conversationId = value.store.createConversation();
    const before = value.store.getState();
    const onPreparedDurable = jest.fn();
    await expect(
      value.controller.send(
        { conversationId, text: 'rollback', attachments: [] },
        { onPreparedDurable },
      ),
    ).resolves.toMatchObject({
      status: 'blocked',
      code: 'E_ATTEMPT_PERSISTENCE',
    });
    expect(value.store.getState()).toBe(before);
    expect(onPreparedDurable).not.toHaveBeenCalled();
    expect(value.completeRoundV2).not.toHaveBeenCalled();
  });

  test('fails before HTTP when sending state is not fully committed', async () => {
    const value = fixture({
      durability: [
        { status: 'committed' },
        { status: 'session_only' },
        { status: 'committed' },
      ],
    });
    const conversationId = value.store.createConversation();
    await expect(
      value.controller.send({ conversationId, text: 'no http', attachments: [] }),
    ).resolves.toMatchObject({
      status: 'retryable',
      code: 'E_ATTEMPT_PERSISTENCE',
    });
    expect(value.completeRoundV2).not.toHaveBeenCalled();
  });

  test('keeps final persistence commit-pending and never repeats HTTP', async () => {
    const value = fixture({
      durability: [
        { status: 'committed' },
        { status: 'committed' },
        { status: 'not_committed' },
        { status: 'committed' },
      ],
    });
    const conversationId = value.store.createConversation();
    await expect(
      value.controller.send({ conversationId, text: 'once', attachments: [] }),
    ).resolves.toMatchObject({ status: 'commit_pending' });
    expect(value.completeRoundV2).toHaveBeenCalledTimes(1);
    await expect(value.controller.retryCommit()).resolves.toMatchObject({
      status: 'completed',
    });
    expect(value.completeRoundV2).toHaveBeenCalledTimes(1);
  });

  test('cancels the exact active schema2 round and ignores late results', async () => {
    let resolveResult!: (result: CompleteRoundV2Result) => void;
    const completeRoundV2: Fixture['completeRoundV2'] = jest.fn(
      (_request: CompleteRoundV2Request) =>
        new Promise<CompleteRoundV2Result>(resolve => {
          resolveResult = resolve;
        }),
    );
    const value = fixture({ completeRoundV2 });
    const conversationId = value.store.createConversation();
    const run = value.controller.send({
      conversationId,
      text: 'cancel',
      attachments: [],
    });
    for (let index = 0; index < 8; index += 1) await Promise.resolve();
    expect(completeRoundV2).toHaveBeenCalledTimes(1);
    await value.controller.cancel();
    expect(value.cancelRoundV2).toHaveBeenCalledWith(ROUND_ID);
    resolveResult(v2Result(completeRoundV2.mock.calls[0]![0]));
    await expect(run).resolves.toMatchObject({ status: 'cancelled' });
    expect(
      value.store.getState().conversations[conversationId]?.messages,
    ).toHaveLength(1);
  });

  test('keeps cancelling identity authoritative until native cancel is durable', async () => {
    const completion = deferred<CompleteRoundV2Result>();
    const nativeCancel = deferred<unknown>();
    const value = fixture({
      completeRoundV2: jest.fn(
        (_request: CompleteRoundV2Request) => completion.promise,
      ),
      cancelRoundV2: jest.fn(() => nativeCancel.promise),
    });
    const conversationId = value.store.createConversation();
    const run = value.controller.send({
      conversationId,
      text: 'first active request',
      attachments: [],
    });
    for (let index = 0; index < 8; index += 1) await Promise.resolve();
    const cancelling = value.controller.cancel();
    for (let index = 0; index < 4; index += 1) await Promise.resolve();
    expect(value.controller.getState()).toMatchObject({
      phase: 'cancelling',
      conversationId,
      roundId: ROUND_ID,
    });

    await expect(
      value.controller.send({
        conversationId,
        text: 'must remain blocked',
        attachments: [],
      }),
    ).resolves.toMatchObject({
      status: 'blocked',
      code: 'E_COMPLETION_BUSY',
    });
    expect(value.controller.getState()).toMatchObject({
      phase: 'cancelling',
      conversationId,
      roundId: ROUND_ID,
    });
    expect(value.completeRoundV2).toHaveBeenCalledTimes(1);

    nativeCancel.resolve(undefined);
    await cancelling;
    completion.resolve(v2Result(value.completeRoundV2.mock.calls[0]![0]));
    await run;
  });

  test('serializes persistence and commit retries across duplicate taps', async () => {
    const pendingPreparationWrite = deferred<SessionDurabilityResult>();
    const persistence = jest
      .fn<Promise<SessionDurabilityResult>, []>()
      .mockResolvedValue({ status: 'committed' })
      .mockResolvedValueOnce({ status: 'session_only' })
      .mockImplementationOnce(() => pendingPreparationWrite.promise);
    const pending = fixture({ persistCurrent: persistence });
    const pendingConversation = pending.store.createConversation();
    await pending.controller.send({
      conversationId: pendingConversation,
      text: 'persist once',
      attachments: [],
    });
    const firstPersistenceRetry = pending.controller.retryPersistence();
    await Promise.resolve();
    await expect(pending.controller.retryPersistence()).resolves.toMatchObject({
      status: 'blocked',
      code: 'E_COMPLETION_BUSY',
    });
    expect(persistence).toHaveBeenCalledTimes(2);
    pendingPreparationWrite.resolve({ status: 'committed' });
    await expect(firstPersistenceRetry).resolves.toMatchObject({
      status: 'completed',
    });

    const pendingCommitWrite = deferred<SessionDurabilityResult>();
    const commitPersistence = jest
      .fn<Promise<SessionDurabilityResult>, []>()
      .mockResolvedValue({ status: 'committed' })
      .mockResolvedValueOnce({ status: 'committed' })
      .mockResolvedValueOnce({ status: 'committed' })
      .mockResolvedValueOnce({ status: 'session_only' })
      .mockImplementationOnce(() => pendingCommitWrite.promise);
    const committed = fixture({ persistCurrent: commitPersistence });
    const committedConversation = committed.store.createConversation();
    await committed.controller.send(
      {
        conversationId: committedConversation,
        text: 'commit once',
        attachments: [],
      },
      { onCommitted: jest.fn() },
    );
    const firstCommitRetry = committed.controller.retryCommit();
    await Promise.resolve();
    await expect(committed.controller.retryCommit()).resolves.toMatchObject({
      status: 'blocked',
      code: 'E_COMPLETION_BUSY',
    });
    expect(commitPersistence).toHaveBeenCalledTimes(4);
    pendingCommitWrite.resolve({ status: 'committed' });
    await expect(firstCommitRetry).resolves.toMatchObject({
      status: 'completed',
    });
  });

  test('blocks retry methods while the initial terminal write is finalizing', async () => {
    const finalWrite = deferred<SessionDurabilityResult>();
    const completionPersistence = jest
      .fn<Promise<SessionDurabilityResult>, []>()
      .mockResolvedValue({ status: 'committed' })
      .mockResolvedValueOnce({ status: 'committed' })
      .mockResolvedValueOnce({ status: 'committed' })
      .mockImplementationOnce(() => finalWrite.promise);
    const completed = fixture({ persistCurrent: completionPersistence });
    const completedConversation = completed.store.createConversation();
    const completing = completed.controller.send({
      conversationId: completedConversation,
      text: 'final write',
      attachments: [],
    });
    for (let index = 0; index < 8; index += 1) await Promise.resolve();
    expect(completed.controller.getState()).toMatchObject({ phase: 'finalizing' });
    await expect(completed.controller.retryCommit()).resolves.toMatchObject({
      status: 'blocked',
      code: 'E_COMPLETION_BUSY',
    });
    expect(completionPersistence).toHaveBeenCalledTimes(3);
    finalWrite.resolve({ status: 'committed' });
    await completing;

    const failureWrite = deferred<SessionDurabilityResult>();
    const failurePersistence = jest
      .fn<Promise<SessionDurabilityResult>, []>()
      .mockResolvedValue({ status: 'committed' })
      .mockResolvedValueOnce({ status: 'committed' })
      .mockResolvedValueOnce({ status: 'committed' })
      .mockImplementationOnce(() => failureWrite.promise);
    const failed = fixture({
      persistCurrent: failurePersistence,
      completeRoundV2: jest.fn(
        async (
          _request: CompleteRoundV2Request,
        ): Promise<CompleteRoundV2Result> => {
          throw { code: 'E_COMPLETION_TRANSPORT' };
        },
      ),
    });
    const failedConversation = failed.store.createConversation();
    const failing = failed.controller.send({
      conversationId: failedConversation,
      text: 'failure write',
      attachments: [],
    });
    for (let index = 0; index < 8; index += 1) await Promise.resolve();
    expect(failed.controller.getState()).toMatchObject({ phase: 'finalizing' });
    await expect(failed.controller.retryPersistence()).resolves.toMatchObject({
      status: 'blocked',
      code: 'E_COMPLETION_BUSY',
    });
    expect(failurePersistence).toHaveBeenCalledTimes(3);
    failureWrite.resolve({ status: 'committed' });
    await failing;
  });

  test('cancels and rolls back a preparation while first durability is in flight', async () => {
    const durability = deferred<SessionDurabilityResult>();
    const store = storeWithIds();
    const persistCurrent = jest
      .fn()
      .mockImplementationOnce(() => durability.promise)
      .mockResolvedValue({ status: 'committed' });
    const completeRoundV2 = jest.fn(async request => v2Result(request));
    const controller = createCompletionController({
      chat: store,
      persistCurrent,
      completeRoundV2,
      completeRoundV3: jest.fn(async request => v3Result(request)),
      cancelRoundV2: jest.fn(async () => undefined),
      cancelRoundV3: jest.fn(async () => undefined),
      createRoundId: () => ROUND_ID,
    });
    const conversationId = store.createConversation();
    const run = controller.send({
      conversationId,
      text: 'cancel before save',
      attachments: [],
    });
    await Promise.resolve();
    await controller.cancel();
    durability.resolve({ status: 'not_committed' });
    await expect(run).resolves.toMatchObject({ status: 'cancelled' });
    expect(store.getState().conversations[conversationId]?.messages).toEqual(
      [],
    );
    expect(completeRoundV2).not.toHaveBeenCalled();
  });

  test('transfers durable draft ownership when pre-send cancellation commits', async () => {
    const firstWrite = deferred<SessionDurabilityResult>();
    const persistCurrent = jest
      .fn<Promise<SessionDurabilityResult>, []>()
      .mockImplementationOnce(() => firstWrite.promise)
      .mockResolvedValue({ status: 'committed' });
    const value = fixture({ persistCurrent });
    const conversationId = value.store.createConversation();
    const onPreparedDurable = jest.fn();
    const run = value.controller.send(
      {
        conversationId,
        text: 'cancel after durable prepare',
        attachments: [],
      },
      { onPreparedDurable },
    );
    await Promise.resolve();
    await value.controller.cancel();
    await expect(value.controller.retryPersistence()).resolves.toMatchObject({
      status: 'blocked',
      code: 'E_COMPLETION_BUSY',
    });
    expect(persistCurrent).toHaveBeenCalledTimes(1);
    firstWrite.resolve({ status: 'committed' });

    await expect(run).resolves.toMatchObject({ status: 'cancelled' });
    expect(onPreparedDurable).toHaveBeenCalledTimes(1);
    expect(persistCurrent).toHaveBeenCalledTimes(2);
    expect(
      value.store.getState().conversations[conversationId]?.attempts[0],
    ).toMatchObject({ status: 'cancelled' });
    expect(value.controller.getState()).toMatchObject({ phase: 'retryable' });
  });

  test('keeps failed pre-send cancellation persistence pending until retried', async () => {
    const firstWrite = deferred<SessionDurabilityResult>();
    const persistCurrent = jest
      .fn<Promise<SessionDurabilityResult>, []>()
      .mockImplementationOnce(() => firstWrite.promise)
      .mockResolvedValueOnce({ status: 'not_committed' })
      .mockResolvedValue({ status: 'committed' });
    const value = fixture({ persistCurrent });
    const conversationId = value.store.createConversation();
    const onPreparedDurable = jest.fn();
    const run = value.controller.send(
      {
        conversationId,
        text: 'cancel persistence failure',
        attachments: [],
      },
      { onPreparedDurable },
    );
    await Promise.resolve();
    await value.controller.cancel();
    firstWrite.resolve({ status: 'committed' });

    await expect(run).resolves.toMatchObject({
      status: 'persistence_pending',
      code: 'E_ATTEMPT_PERSISTENCE',
    });
    expect(onPreparedDurable).toHaveBeenCalledTimes(1);
    expect(value.controller.getState()).toMatchObject({
      phase: 'persistence_pending',
      failureCode: 'E_ATTEMPT_PERSISTENCE',
    });
    await expect(
      value.controller.beforeConversationChange(conversationId),
    ).resolves.toBe(false);
    await expect(value.controller.retryPersistence()).resolves.toMatchObject({
      status: 'cancelled',
      code: null,
    });
    await expect(
      value.controller.beforeConversationChange(conversationId),
    ).resolves.toBe(true);
  });

  test('does not transfer draft ownership from session-only cancellation state', async () => {
    const firstWrite = deferred<SessionDurabilityResult>();
    const persistCurrent = jest
      .fn<Promise<SessionDurabilityResult>, []>()
      .mockImplementationOnce(() => firstWrite.promise)
      .mockResolvedValueOnce({ status: 'not_committed' })
      .mockResolvedValue({ status: 'committed' });
    const value = fixture({ persistCurrent });
    const conversationId = value.store.createConversation();
    const onPreparedDurable = jest.fn();
    const run = value.controller.send(
      {
        conversationId,
        text: 'session-only cancel',
        attachments: [],
      },
      { onPreparedDurable },
    );
    await Promise.resolve();
    await value.controller.cancel();
    firstWrite.resolve({ status: 'session_only' });

    await expect(run).resolves.toMatchObject({
      status: 'persistence_pending',
    });
    expect(onPreparedDurable).not.toHaveBeenCalled();
    await value.controller.retryPersistence();
    expect(onPreparedDurable).toHaveBeenCalledTimes(1);
  });

  test('lets the in-flight persistence retry own a concurrent cancellation', async () => {
    const retryWrite = deferred<SessionDurabilityResult>();
    const persistCurrent = jest
      .fn<Promise<SessionDurabilityResult>, []>()
      .mockResolvedValueOnce({ status: 'session_only' })
      .mockImplementationOnce(() => retryWrite.promise)
      .mockResolvedValue({ status: 'committed' });
    const value = fixture({ persistCurrent });
    const conversationId = value.store.createConversation();
    const onPreparedDurable = jest.fn();
    await value.controller.send(
      {
        conversationId,
        text: 'retry then cancel',
        attachments: [],
      },
      { onPreparedDurable },
    );
    const retrying = value.controller.retryPersistence();
    await Promise.resolve();
    await value.controller.cancel();
    expect(value.controller.getState()).toMatchObject({ phase: 'cancelling' });
    expect(persistCurrent).toHaveBeenCalledTimes(2);
    retryWrite.resolve({ status: 'committed' });

    await expect(retrying).resolves.toMatchObject({ status: 'cancelled' });
    expect(onPreparedDurable).toHaveBeenCalledTimes(1);
    expect(persistCurrent).toHaveBeenCalledTimes(3);
    expect(value.controller.getState()).toMatchObject({
      phase: 'retryable',
      failureCode: null,
    });
  });

  test('does not expose an undurable failure as retryable', async () => {
    const value = fixture({
      durability: [
        { status: 'committed' },
        { status: 'committed' },
        { status: 'not_committed' },
        { status: 'committed' },
      ],
      completeRoundV2: jest.fn(
        async (
          _request: CompleteRoundV2Request,
        ): Promise<CompleteRoundV2Result> => {
          throw { code: 'E_COMPLETION_TRANSPORT' };
        },
      ),
    });
    const conversationId = value.store.createConversation();
    await expect(
      value.controller.send({
        conversationId,
        text: 'persist failure state',
        attachments: [],
      }),
    ).resolves.toMatchObject({
      status: 'persistence_pending',
      code: 'E_ATTEMPT_PERSISTENCE',
    });
    await expect(
      value.controller.beforeConversationChange(conversationId),
    ).resolves.toBe(false);
    expect(value.completeRoundV2).toHaveBeenCalledTimes(1);
    await expect(value.controller.retryPersistence()).resolves.toMatchObject({
      status: 'retryable',
      code: 'E_COMPLETION_TRANSPORT',
    });
    expect(value.completeRoundV2).toHaveBeenCalledTimes(1);
  });

  test.each(['E_CLAUDE_OFFICIAL_TEXT_TIMEOUT', 'E_COMPLETION_TIMEOUT'])('persists and rehydrates %s as a retryable canonical timeout', async code => {
    const value = fixture();
    const conversationId = value.store.createConversation({ modelId: 'claude-haiku-4-5-20251001', thinkingMode: 'off' });
    value.completeRoundV2.mockRejectedValueOnce(sanitizeCompletionError({ code, message: 'private provider output' }));
    const result = await value.controller.send({ conversationId, text: 'hello', attachments: [] });
    expect(result).toMatchObject({ status: 'retryable', code: 'E_COMPLETION_TIMEOUT' });
    const saved = value.store.serialize();
    expect(saved).toContain('E_COMPLETION_TIMEOUT');
    expect(saved).not.toContain('E_CLAUDE_OFFICIAL_TEXT_TIMEOUT');
    const reloaded = createChatStore({ initialState: hydrateChatState(saved) });
    const restored = fixture({ store: reloaded });
    expect(restored.controller.reconcileHydrated(conversationId)).toMatchObject({
      phase: 'retryable', failureCode: 'E_COMPLETION_TIMEOUT',
    });
    expect(restored.completeRoundV2).not.toHaveBeenCalled();
  });

  test('retry after selecting a model sends the same image with the newly frozen selection and completes', async () => {
    const value = fixture();
    const conversationId = value.store.createConversation({ modelId: 'deepseek-v4-flash-vision-exp', thinkingMode: 'high' });
    const image = { schema_version: 1 as const, id: 'retry-image', kind: 'image' as const, name: 'image.png', mime_type: 'image/png', size: 100 };
    value.completeRoundV2.mockRejectedValueOnce(sanitizeCompletionError({ code: 'E_COMPLETION_RESPONSE_MODEL' }));
    await value.controller.send({ conversationId, text: 'What is this?', attachments: [image] });
    const source = value.store.getState().conversations[conversationId].attempts[0];
    value.store.setModel(conversationId, 'deepseek-v4-flash');
    value.store.setThinkingMode(conversationId, 'off');
    const result = await value.controller.retry(conversationId, source.attemptId);
    expect(result.status).toBe('completed');
    const request = value.completeRoundV2.mock.calls[1][0];
    expect(request).toMatchObject({ model: 'deepseek-v4-flash', thinkingMode: 'off', harnessId: 'dsh' });
    expect(request.visibleHistory[0].attachments).toEqual([image]);
    expect(value.store.getState().conversations[conversationId].attempts[0]).toEqual(source);
    expect(value.store.getState().conversations[conversationId].attempts[1].status).toBe('completed');
  });

  test('reconciles a persisted sending round to interrupted without HTTP', () => {
    const source = storeWithIds();
    const conversationId = source.createConversation();
    const prepared = source.prepareTurnAttempt(conversationId, 'restart')!;
    prepared.commit();
    source.startAttemptRound(conversationId, prepared.attemptId, ROUND_ID, 0);
    const hydrated = createChatStore({
      initialState: hydrateChatState(source.serialize()),
    });
    const value = fixture({ store: hydrated });

    expect(value.controller.reconcileHydrated(conversationId)).toMatchObject({
      phase: 'retryable',
      attemptId: ATTEMPT_ID,
      failureCode: 'E_ATTEMPT_INTERRUPTED',
    });
    expect(value.completeRoundV2).not.toHaveBeenCalled();
  });

  test('reconciles a completed persisted attempt without repeating HTTP', async () => {
    const source = fixture();
    const conversationId = source.store.createConversation();
    await source.controller.send({
      conversationId,
      text: 'already completed',
      attachments: [],
    });
    const reloaded = createChatStore({
      initialState: hydrateChatState(source.store.serialize()),
    });
    const value = fixture({ store: reloaded });

    expect(value.controller.reconcileHydrated(conversationId)).toMatchObject({
      phase: 'idle',
    });
    expect(value.completeRoundV2).not.toHaveBeenCalled();
  });

  test('does not let cancel or duplicate send overwrite active controller identity', async () => {
    const pendingResult = deferred<CompleteRoundV2Result>();
    const completeRoundV2: Fixture['completeRoundV2'] = jest.fn(
      (_request: CompleteRoundV2Request) => pendingResult.promise,
    );
    const value = fixture({ completeRoundV2 });
    const conversationId = value.store.createConversation();
    const run = value.controller.send({
      conversationId,
      text: 'active',
      attachments: [],
    });
    for (let index = 0; index < 8; index += 1) await Promise.resolve();
    const sending = value.controller.getState();
    expect(sending).toMatchObject({
      phase: 'sending',
      conversationId,
      attemptId: ATTEMPT_ID,
      roundId: ROUND_ID,
    });
    await expect(
      value.controller.send({
        conversationId,
        text: 'duplicate',
        attachments: [],
      }),
    ).resolves.toMatchObject({
      status: 'blocked',
      code: 'E_COMPLETION_BUSY',
    });
    expect(value.controller.getState()).toBe(sending);

    await value.controller.cancel();
    pendingResult.resolve(v2Result(completeRoundV2.mock.calls[0]![0]));
    await run;
  });

  test('keeps commit-pending authoritative until retryCommit succeeds', async () => {
    const value = fixture({
      durability: [
        { status: 'committed' },
        { status: 'committed' },
        { status: 'not_committed' },
        { status: 'committed' },
      ],
    });
    const conversationId = value.store.createConversation();
    await value.controller.send({
      conversationId,
      text: 'pending commit',
      attachments: [],
    });
    const pending = value.controller.getState();
    expect(pending.phase).toBe('commit_pending');
    await value.controller.cancel();
    expect(value.controller.getState()).toBe(pending);
    expect(value.cancelRoundV2).not.toHaveBeenCalled();
    await expect(value.controller.retryCommit()).resolves.toMatchObject({
      status: 'completed',
    });
  });

  test('fails closed when a failure transition cannot be recorded', async () => {
    const base = storeWithIds();
    const chat: ChatStore = {
      ...base,
      failAttempt: () => false,
    };
    const value = fixture({
      store: chat,
      durability: [
        { status: 'committed' },
        { status: 'not_committed' },
      ],
    });
    const conversationId = chat.createConversation();
    await expect(
      value.controller.send({
        conversationId,
        text: 'transition conflict',
        attachments: [],
      }),
    ).resolves.toMatchObject({
      status: 'blocked',
      code: 'E_COMPLETION_RESULT_CORRELATION',
    });
  });

  test('blocks navigation for pending durability and cancels active identity before switching', async () => {
    const pending = fixture({
      durability: [{ status: 'session_only' }],
    });
    const pendingId = pending.store.createConversation();
    await pending.controller.send({
      conversationId: pendingId,
      text: 'pending',
      attachments: [],
    });
    await expect(
      pending.controller.beforeConversationChange(pendingId),
    ).resolves.toBe(false);
    await expect(
      pending.controller.beforeConversationDelete(pendingId),
    ).resolves.toBe(false);

    const activeResult = deferred<CompleteRoundV2Result>();
    const active = fixture({
      completeRoundV2: jest.fn(
        (_request: CompleteRoundV2Request) => activeResult.promise,
      ),
    });
    const activeId = active.store.createConversation();
    const run = active.controller.send({
      conversationId: activeId,
      text: 'switch',
      attachments: [],
    });
    for (let index = 0; index < 8; index += 1) await Promise.resolve();
    await expect(
      active.controller.beforeConversationChange(activeId),
    ).resolves.toBe(true);
    expect(active.cancelRoundV2).toHaveBeenCalledWith(ROUND_ID);
    activeResult.resolve(v2Result(active.completeRoundV2.mock.calls[0]![0]));
    await run;
  });

  test('retries the same turn with a new attempt and resumes prepared without HTTP automation', async () => {
    const store = storeWithIds();
    const conversationId = store.createConversation();
    const first = store.prepareTurnAttempt(conversationId, 'retry')!;
    first.commit();
    store.failAttempt(conversationId, first.attemptId, 'E_COMPLETION_TRANSPORT');
    const value = fixture({ store });
    await expect(
      value.controller.retry(conversationId, first.attemptId),
    ).resolves.toMatchObject({ status: 'completed', attemptId: RETRY_ID });
    const conversation = store.getState().conversations[conversationId]!;
    expect(conversation.turns[0]?.attemptIds).toEqual([
      ATTEMPT_ID,
      RETRY_ID,
    ]);
    expect(conversation.messages.filter(message => message.role === 'user')).toHaveLength(1);

    const resumableStore = storeWithIds();
    const resumableId = resumableStore.createConversation();
    const prepared = resumableStore.prepareTurnAttempt(resumableId, 'resume')!;
    prepared.commit();
    const resumable = fixture({ store: resumableStore });
    resumable.controller.reconcileHydrated(resumableId);
    expect(resumable.controller.getState()).toMatchObject({
      phase: 'resume_available',
      attemptId: ATTEMPT_ID,
    });
    const resumeIdentity = resumable.controller.getState();
    await expect(
      resumable.controller.send({
        conversationId: resumableId,
        text: 'must resume first',
        attachments: [],
      }),
    ).resolves.toMatchObject({
      status: 'blocked',
      code: 'E_COMPLETION_BUSY',
    });
    expect(resumable.controller.getState()).toBe(resumeIdentity);
    expect(resumable.completeRoundV2).not.toHaveBeenCalled();
    await expect(
      resumable.controller.resume(resumableId, ATTEMPT_ID),
    ).resolves.toMatchObject({ status: 'completed' });
  });
});

test('completing a round emits reasoning before text session events', async () => {
  // The controller delegates event_id/seq/created_at allocation to the
  // receiver; feed its emissions through the shared journal exactly like
  // production wiring does.
  const journal = createSessionEventJournal();
  const f = fixture({
    onSessionEvent: jest.fn((event: { schema_version: number; attempt_id: string; kind: string; text: string }) => {
      journal.append(event as unknown as SessionEventEmission);
    }),
  });
  f.store.createConversation();
  const conversationId = f.store.getState().selectedConversationId;
  if (conversationId === null) throw new Error('no conversation');
  await f.controller.send({ conversationId, text: 'hello', attachments: [] });

  const events = journal.snapshot();
  const kinds = events.map(e => e.kind);
  expect(kinds).toContain('assistant_text');
  // The journal allocates strictly increasing per-attempt sequences.
  expect(events.map(e => e.seq)).toEqual(
    events.map((_, i) => i),
  );
  expect(new Set(events.map(e => e.event_id)).size).toBe(events.length);
  // Every emitted row must conform to the persisted session-event schema.
  expect(
    events.every(e => (e as { schema_version?: unknown }).schema_version === 1),
  ).toBe(true);
  const textIdx = kinds.indexOf('assistant_text');
  const reasoningIdx = kinds.indexOf('assistant_reasoning');
  if (reasoningIdx !== -1) {
    expect(reasoningIdx).toBeLessThan(textIdx);
  }
});

describe('project Agent completion controller', () => {
  const AGENT_CONVERSATION = '10101010-1010-4101-8101-101010101010';
  const AGENT_MESSAGE = '20202020-2020-4202-8202-202020202020';
  const AGENT_TURN = '30303030-3030-4303-8303-303030303030';
  const AGENT_ATTEMPT = '40404040-4040-4404-8404-404040404040';
  // A second attempt in the same turn -- only a retry after an abandoned
  // agent attempt asks for one, and it must not reuse the first attempt's id.
  const AGENT_RETRY_ATTEMPT = '41414141-4141-4414-8414-414141414141';
  const AGENT_RETRY_TRANSCRIPT = '71717171-7171-4717-8717-717171717171';
  const AGENT_WORKSPACE = '50505050-5050-4505-8505-505050505050';
  const AGENT_PROJECT = '60606060-6060-4606-8606-606060606060';
  const AGENT_TRANSCRIPT = '70707070-7070-4707-8707-707070707070';
  const SHA = 'a'.repeat(64);
  const ROOT_SHA = 'b'.repeat(64);
  const TOOLSET_SHA = 'c'.repeat(64);
  const MANIFEST_SHA = 'd'.repeat(64);
  const IDS = [
    '80808080-8080-4808-8808-808080808080',
    '90909090-9090-4909-8909-909090909090',
    'a0a0a0a0-a0a0-40a0-80a0-a0a0a0a0a0a0',
    'b0b0b0b0-b0b0-40b0-80b0-b0b0b0b0b0b0',
    'c0c0c0c0-c0c0-40c0-80c0-c0c0c0c0c0c0',
    'd0d0d0d0-d0d0-40d0-80d0-d0d0d0d0d0d0',
    'e0e0e0e0-e0e0-40e0-80e0-e0e0e0e0e0e0',
    'f0f0f0f0-f0f0-40f0-80f0-f0f0f0f0f0f0',
    '81818181-8181-4181-8181-818181818181',
    '82828282-8282-4282-8282-828282828282',
    '83838383-8383-4383-8383-838383838383',
    '84848484-8484-4484-8484-848484848484',
    '85858585-8585-4585-8585-858585858585',
    '86868686-8686-4686-8686-868686868686',
    '87878787-8787-4787-8787-878787878787',
    '88888888-8888-4888-8888-888888888888',
    '89898989-8989-4989-8989-898989898989',
    '8a8a8a8a-8a8a-4a8a-8a8a-8a8a8a8a8a8a',
    '8b8b8b8b-8b8b-4b8b-8b8b-8b8b8b8b8b8b',
    '8c8c8c8c-8c8c-4c8c-8c8c-8c8c8c8c8c8c',
  ];

  function agentStore(model: HarnessModelId = 'deepseek-v4-flash') {
    let messageUsed = false;
    let attemptUsed = false;
    const options: Parameters<typeof createChatStore>[0] = {
      now: () => NOW,
      sessionAuthority: { generation: 1, sessionSha256: SHA },
      createId: kind => {
        if (kind === 'conversation') return AGENT_CONVERSATION;
        if (!messageUsed) {
          messageUsed = true;
          return AGENT_MESSAGE;
        }
        return IDS.shift() ?? AGENT_MESSAGE;
      },
      createLifecycleId: kind => {
        if (kind === 'turn') return AGENT_TURN;
        if (kind === 'attempt') {
          const first = !attemptUsed;
          attemptUsed = true;
          return first ? AGENT_ATTEMPT : AGENT_RETRY_ATTEMPT;
        }
        return IDS.shift() ?? AGENT_TURN;
      },
    };
    const base = createChatStore(options);
    const conversationId = base.createConversation({ workspaceId: AGENT_WORKSPACE, projectId: AGENT_PROJECT });
    const source = base.getState().conversations[conversationId]!;
    const manifest: ProjectContextManifestV1 = {
      schema_version: 1 as const,
      snapshot_id: '91919191-9191-4919-8919-919191919191',
      project_id: AGENT_PROJECT,
      project_name: 'agent-project',
      branch: 'main',
      head_oid: '0'.repeat(40),
      clean: true,
      conflicted: false,
      captured_at: NOW,
      policy_version: 'chat-read-v1.0.0',
      provider_host: providerHostForModel(model),
      model,
      included: [{ path: 'README.md', source: 'tracked_file' as const, bytes: 1, sha256: 'c'.repeat(64) }],
      omitted: [],
      context_bytes: 1,
      estimated_tokens: 1,
      snapshot_sha256: 'a'.repeat(64),
      source_fingerprint: 'b'.repeat(64),
    };
    const context: ProjectContextState = {
      schemaVersion: 1 as const,
      projectId: AGENT_PROJECT,
      status: 'ready' as const,
      selectedPaths: [],
      activePreparationId: null,
      snapshot: manifest,
      consent: {
        schema_version: 1 as const,
        consent_receipt_id: '92929292-9292-4929-8929-929292929292',
        snapshot_id: manifest.snapshot_id,
        snapshot_sha256: manifest.snapshot_sha256,
        confirmed_at: LATER,
      },
      staleReason: null,
      errorCode: null,
    };
    const state = base.getState();
    return createChatStore({
      ...options,
      initialState: {
        ...state,
        conversations: {
          ...state.conversations,
          [conversationId]: {
            ...source,
            modelId: model,
            workspaceId: AGENT_WORKSPACE,
            runtimeContextId: AGENT_WORKSPACE,
            workspaceBinding: {
              schemaVersion: 1 as const,
              workspaceId: AGENT_WORKSPACE,
              bindingRevision: 1,
              projectId: AGENT_PROJECT,
            },
            workspaceBootstrapState: 'none' as const,
            projectContext: context,
          },
        },
      },
    });
  }

  type AgentRuntimeFixtureCall = {
    readonly callId: string;
    readonly name: string;
    readonly argumentsSha256: string;
    readonly access: 'auto' | 'conversation_confirm' | 'confirm_once' | 'durable_deny';
  };

  type AgentRuntimeFixtureOptions = {
    readonly batchRounds?: readonly (readonly AgentRuntimeFixtureCall[])[];
    readonly finalRoundIndex?: number;
    readonly completedRoundRevision?: number;
    readonly finalReasoning?: string;
    readonly responseOffset?: number;
    readonly transcriptRef?: string;
    readonly cancelledCallIds?: readonly string[];
    /** Adds git_push to the frozen root capabilities and registry. */
    readonly pushCapable?: boolean;
    /** Exercises the v3 guest-service registry and its live conversation grants. */
    readonly runtimeCapable?: boolean;
    readonly getConversationGrants?: () => readonly AgentConversationGrantV2[];
    /**
     * Round indexes whose batch native refuses at preparation: every call
     * comes back settled as a failed result (E_AGENT_BAD_PATH) and the
     * transcript advanced by one tool message per call.
     */
    readonly refusedRounds?: readonly number[];
  };

  const defaultBatchCalls: readonly AgentRuntimeFixtureCall[] = [
    { callId: 'write-call', name: 'write_file', argumentsSha256: '2'.repeat(64), access: 'conversation_confirm' },
    { callId: 'commit-call', name: 'git_commit', argumentsSha256: '3'.repeat(64), access: 'conversation_confirm' },
  ];
  const tokenIds = [
    '93939393-9393-4939-8939-939393939393',
    '94949494-9494-4949-8949-949494949494',
    '95959595-9595-4959-8959-959595959595',
    '96969696-9696-4969-8969-969696969696',
    '97979797-9797-4979-8979-979797979797',
    '98989898-9898-4989-8989-989898989898',
  ];

  function makeRuntime(
    operations: ReturnType<typeof jest.fn>[],
    options: AgentRuntimeFixtureOptions = {},
  ): AgentRuntimeFacadeV2 {
    const root: AgentRuntimeRootV1 = {
      schema_version: 1,
      kind: 'project',
      workspace_id: AGENT_WORKSPACE,
      workspace_binding_revision: 1,
      project_id: AGENT_PROJECT,
      root_fingerprint_sha256: ROOT_SHA,
      capabilities: [
        'file_read', 'file_write', 'git_commit',
        ...(options.pushCapable ? ['git_push' as const] : []),
        ...(options.runtimeCapable ? ['guest_service' as const] : []),
      ],
    };
    const policy: AgentRuntimePolicyV1 = {
      schema_version: 1,
      policy_version: 'agent-v1',
      max_single_write_bytes: 32768,
      max_batch_write_bytes: 512 * 1024,
      max_attempt_write_bytes: 4 * 1024 * 1024,
    };
    const registry: AgentRuntimeRegistryV2 = {
      schema_version: 2,
      registry_version: options.runtimeCapable ? 3 : 1,
      toolset_sha256: TOOLSET_SHA,
      tools: [
        { schema_version: 2, name: 'write_file', safe_summary_key: 'agent.write_file', access: 'conversation_confirm' },
        { schema_version: 2, name: 'git_commit', safe_summary_key: 'agent.git_commit', access: 'conversation_confirm' },
        ...(options.pushCapable
          ? [{ schema_version: 2 as const, name: 'git_push', safe_summary_key: 'agent.git_push', access: 'conversation_confirm' as const }]
          : []),
        ...(options.runtimeCapable
          ? ['install_runtime_environment', 'run_program', 'start_runtime_service'].map(name => ({
              schema_version: 2 as const, name, safe_summary_key: `agent.${name}`,
              access: 'conversation_confirm' as const,
            }))
          : []),
      ],
    };
    const conversationGrantFor = (name: string): AgentConversationGrantV2 | null => {
      if (!options.runtimeCapable || !['install_runtime_environment', 'run_program', 'start_runtime_service'].includes(name)) return null;
      return options.getConversationGrants?.().find(grant =>
        grant.conversation_id === AGENT_CONVERSATION &&
        grant.workspace_id === root.workspace_id &&
        grant.project_id === root.project_id &&
        grant.binding_revision === root.workspace_binding_revision &&
        grant.root_fingerprint_sha256 === root.root_fingerprint_sha256 &&
        grant.tool_family === 'guest_service' &&
        grant.registry_version === registry.registry_version &&
        grant.policy_version === policy.policy_version,
      ) ?? null;
    };
    const transcript = (
      generation: number,
      digest: string,
      ref: string = options.transcriptRef ?? AGENT_TRANSCRIPT,
    ): AgentRuntimeTranscriptHandleV1 => ({
      schema_version: 1,
      transcript_ref: ref,
      generation,
      transcript_sha256: digest,
      transcript_bytes: generation * 10,
    });
    // Native mints one transcript per attempt, and the store refuses a
    // second attempt that reuses the first one's ref -- which is how it keeps
    // an abandoned attempt's evidence its own.
    const transcriptRefs = new Map<string, string>();
    const transcriptRefFor = (attemptId: string): string => {
      const known = transcriptRefs.get(attemptId);
      if (known !== undefined) return known;
      const minted =
        transcriptRefs.size === 0
          ? options.transcriptRef ?? AGENT_TRANSCRIPT
          : AGENT_RETRY_TRANSCRIPT;
      transcriptRefs.set(attemptId, minted);
      return minted;
    };
    const prepareAgentAttempt = jest.fn(async (request: PrepareAgentAttemptRequestV2) => ({
      schema_version: 2 as const,
      status: 'prepared' as const,
      operation_id: request.operation_id,
      attempt: {
        schema_version: 2 as const,
        task_id: request.task_id,
        conversation_id: request.conversation_id,
        attempt_id: request.attempt_id,
        phase: 'ready_for_round' as const,
        controller_generation: request.controller_cas.expected_controller_generation,
        journal_revision: request.controller_cas.expected_journal_revision,
        authority_revision: 1,
        root,
        policy,
        registry,
        transcript: transcript(0, SHA, transcriptRefFor(request.attempt_id)),
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
      } as AgentAttemptProjectionV2,
      observed_checkpoint: request.committed_checkpoint,
    }));
    const completeAgentRoundV2 = jest.fn(async (request: CompleteAgentRoundRequestV2): Promise<CompleteAgentRoundResultV2> => {
      operations.push(completeAgentRoundV2);
      const final = request.round_index >= (options.finalRoundIndex ?? 1);
      const nextGeneration = request.transcript.generation + 1;
      const nextTranscript = transcript(
        nextGeneration,
        final ? '9'.repeat(64) : nextGeneration.toString(16).slice(-1).repeat(64),
        request.transcript.transcript_ref,
      );
      const completionReceipt: AgentRoundReceiptV2 = {
        schema_version: 2,
        transport_schema_version: request.transport_schema_version,
        harness_id: request.harness_id,
        turn_id: request.task_id,
        task_id: request.task_id,
        attempt_id: request.attempt_id,
        round_id: request.round_id,
        round_index: request.round_index,
        provider_request_id:
          `77777777-7777-4777-8777-${String(request.round_index + (options.responseOffset ?? 0) + 1).padStart(12, '0')}`,
        provider_response_id: `response-${request.round_index + (options.responseOffset ?? 0)}`,
        requested_model: request.model,
        model: request.model,
        thinking_mode: request.thinking_mode,
        finish_reason: final ? 'stop' : 'tool_calls',
        latency_ms: 1,
        // Native separately proves the controller HJ digest and the provider
        // transport body digest; exercise the intentionally distinct values.
        visible_history_sha256: 'f'.repeat(64),
        model_input_sha256: SHA,
        request_body_sha256: SHA,
        project_context_receipt: request.transport_schema_version === 3 ? {
          schema_version: 1,
          snapshot_id: '91919191-9191-4919-8919-919191919191',
          snapshot_sha256: SHA,
          source_fingerprint: 'b'.repeat(64),
          context_bytes: 1,
          verified_at: NOW,
        } : null,
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
          result_round_revision: options.completedRoundRevision ?? 1,
          transcript: nextTranscript,
          outcome: {
            schema_version: 3,
            kind: 'final',
            finish_reason: 'stop',
            completion_receipt: completionReceipt,
            transcript: nextTranscript,
            text: 'Agent final',
            reasoning: options.finalReasoning ?? 'Agent reasoning',
          },
        };
      }
      const callsForRound = options.batchRounds?.[request.round_index] ?? defaultBatchCalls;
      const executableCallCount = callsForRound.filter(call => call.access !== 'durable_deny').length;
      const deniedCallCount = callsForRound.length - executableCallCount;
      return {
        schema_version: 2,
        status: 'completed',
        operation_id: request.operation_id,
        task_id: request.task_id,
        attempt_id: request.attempt_id,
        round_id: request.round_id,
        round_index: request.round_index,
        launch_attempt: request.launch_attempt,
        result_round_revision: options.completedRoundRevision ?? 1,
        transcript: nextTranscript,
        outcome: {
          schema_version: 3,
          kind: 'tool_batch',
          finish_reason: 'tool_calls',
          completion_receipt: completionReceipt,
          transcript: nextTranscript,
          calls: [
            ...callsForRound.map((call, callIndex) => ({
              schema_version: 3 as const,
              call_index: callIndex,
              call_id: call.callId,
              name: call.name,
              arguments_sha256: call.argumentsSha256,
              safe_summary_key: call.access === 'durable_deny' ? 'agent.unknown' : `agent.${call.name}`,
              access: call.access,
              approval_state: call.access === 'durable_deny' ? 'durable_denied' as const : 'deferred' as const,
            })),
          ],
          batch_class: deniedCallCount === 0 ? 'executable' : deniedCallCount === callsForRound.length ? 'denied_only' : 'mixed',
          executable_call_count: executableCallCount,
          denied_call_count: deniedCallCount,
          reasoning: '',
        },
      };
    });
    let lastBatchTranscript: AgentRuntimeTranscriptHandleV1 | null = null;
    let writeReservationRevision = 0;
    const writeRevisions = new Map<string, number>();
    const prepareAgentToolBatch = jest.fn(async (request: PrepareAgentToolBatchRequestV2) => {
      operations.push(prepareAgentToolBatch);
      const callsForRound = options.batchRounds?.[request.round_index] ?? defaultBatchCalls;
      const hasMutation = callsForRound.some(call => ['write_file', 'git_commit', 'git_push', 'install_runtime_environment', 'run_program', 'start_runtime_service'].includes(call.name));
      if (hasMutation && !writeRevisions.has(request.operation_id)) {
        writeRevisions.set(request.operation_id, ++writeReservationRevision);
      }
      const refused = options.refusedRounds?.includes(request.round_index) === true;
      // A refused batch opens no write manifest, so it carries the round
      // revision like any read-only batch.
      const batchRevision = hasMutation && !refused
        ? writeRevisions.get(request.operation_id)!
        : request.expected_round_revision;
      const makeToken = (index: number, call: AgentRuntimeFixtureCall): AgentApprovalBindingTokenV2 => ({
        schema_version: 2,
        token: tokenIds[request.round_index * 2 + index] ?? tokenIds[index]!,
        controller_cas: request.controller_cas,
        task_id: request.task_id,
        attempt_id: request.attempt_id,
        round_id: request.round_id,
        round_index: request.round_index,
        batch_call_ids: callsForRound.map(candidate => candidate.callId),
        batch_arguments_sha256: callsForRound.map(candidate => candidate.argumentsSha256),
        batch_revision: batchRevision,
        manifest_sha256: MANIFEST_SHA,
        call_index: index,
        call_id: call.callId,
        name: call.name,
        arguments_sha256: call.argumentsSha256,
        idempotency_key: (request.round_index + index + 4).toString(16).slice(-1).repeat(64),
        root_fingerprint_sha256: ROOT_SHA,
        binding_revision: 1,
        policy_version: 'agent-v1',
        registry_version: registry.registry_version,
        access: call.access === 'confirm_once' ? 'confirm_once' : 'conversation_confirm',
        allowed_decisions: call.access === 'confirm_once'
          ? ['denied', 'allow_once', 'cancelled']
          : ['denied', 'allow_once', 'allow_conversation', 'cancelled'],
      });
      const calls: AgentBatchCallProjectionV2[] = callsForRound.map((call, callIndex) => {
        const durableDeny = call.access === 'durable_deny';
        const grant = call.access === 'conversation_confirm' ? conversationGrantFor(call.name) : null;
        const idempotencyKey = durableDeny ? null : (request.round_index + callIndex + 4).toString(16).slice(-1).repeat(64);
        const refusedReceipt: AgentToolReceiptV1 | null = refused && !durableDeny
          ? {
              schema_version: 1,
              call_id: call.callId,
              name: call.name,
              arguments_sha256: call.argumentsSha256,
              result_sha256: 'b'.repeat(64),
              result_bytes: 96,
              truncated: false,
              duration_ms: 0,
              outcome: 'failed',
              failure_code: 'E_AGENT_BAD_PATH',
              approval_reference: null,
            }
          : null;
        const deniedReceipt: AgentToolReceiptV1 | null = durableDeny
          ? {
              schema_version: 1,
              call_id: call.callId,
              name: call.name,
              arguments_sha256: call.argumentsSha256,
              result_sha256: 'e'.repeat(64),
              result_bytes: 0,
              truncated: false,
              duration_ms: 0,
              outcome: 'denied',
              failure_code: 'E_AGENT_UNKNOWN_TOOL',
              approval_reference: null,
            }
          : null;
        return {
          schema_version: 2,
          call_index: callIndex,
          call_id: call.callId,
          name: call.name,
          arguments_sha256: call.argumentsSha256,
          idempotency_key: idempotencyKey,
          safe_summary_key: durableDeny ? 'agent.unknown' : `agent.${call.name}`,
          approval_preview: durableDeny || refusedReceipt !== null
            ? null
            : call.name === 'write_file'
              ? {
                  schema_version: 1,
                  kind: 'write_file',
                  paths: ['notes.md'],
                  content_bytes: 5,
                  prior: { schema_version: 1, kind: 'absent', bytes: null },
                  diff_preview: '@@ -1,0 +1,1 @@\n+hello',
                  diff_truncated: false,
                }
              : {
                  schema_version: 1,
                  kind: call.name as 'list_dir' | 'read_file' | 'git_commit' | 'git_push' | 'install_runtime_environment' | 'run_program' | 'start_runtime_service',
                  paths: call.name === 'run_program' || call.name === 'start_runtime_service' ? ['server.js'] : [],
                  content_bytes: null,
                  prior: null,
                  diff_preview: null,
                  diff_truncated: false,
                },
          access: call.access,
          approval_state: durableDeny ? 'denied' : call.access === 'auto' ? 'not_required' : refusedReceipt !== null ? 'cancelled' : grant !== null ? 'bound' : 'pending',
          approval_token: durableDeny || call.access === 'auto' || refusedReceipt !== null || grant !== null ? null : makeToken(callIndex, call),
          approval_reference: grant?.grant_id ?? null,
          execution_status: durableDeny ? 'denied' : refusedReceipt !== null ? 'failed' : 'intent',
          execution_revision: durableDeny ? null : 1,
          native_row_revision: 1,
          receipt: refusedReceipt ?? deniedReceipt,
        };
      });
      const refusedTranscript = refused
        ? transcript(request.transcript.generation + callsForRound.length, (request.transcript.generation + callsForRound.length).toString(16).slice(-1).repeat(64), request.transcript.transcript_ref)
        : request.transcript;
      const batchKind = hasMutation && !refused ? 'write_batch' : 'read_only_batch';
      const batchNewWriteBytes = hasMutation ? 1 : 0;
      const receipt: AgentBatchReceiptV2 = {
        schema_version: 2,
        task_id: request.task_id,
        attempt_id: request.attempt_id,
        round_id: request.round_id,
        round_index: request.round_index,
        batch_kind: batchKind,
        batch_revision: batchRevision,
        manifest_sha256: hasMutation && !refused ? MANIFEST_SHA : null,
        transcript: refusedTranscript,
        calls,
        batch_new_write_bytes: refused ? 0 : batchNewWriteBytes,
        reserved_write_bytes: request.expected_reserved_write_bytes + (refused ? 0 : batchNewWriteBytes),
        effect_gate: hasMutation && !refused ? 'closed' : 'not_applicable',
      };
      lastBatchTranscript = refusedTranscript;
      return { schema_version: 2 as const, status: 'prepared' as const, operation_id: request.operation_id, receipt, observed_checkpoint: request.committed_checkpoint };
    });
    const bindAgentApproval = jest.fn(async (request: BindAgentApprovalRequestV2) => {
      operations.push(bindAgentApproval);
      // A native denial appends the protected feedback message, so the
      // settlement transcript is exactly one generation past the prepared
      // batch transcript (the mock keeps single-digit generations).
      const deniedGeneration = (lastBatchTranscript?.generation ?? 0) + 1;
      const boundReceipt = request.decision === 'denied'
        ? {
            schema_version: 1 as const,
            call_id: request.call_id,
            name: request.token.name,
            arguments_sha256: request.token.arguments_sha256,
            result_sha256: 'd'.repeat(64),
            result_bytes: 64,
            truncated: false,
            duration_ms: 0,
            outcome: 'denied' as const,
            failure_code: 'E_AGENT_DENIED_BY_USER' as const,
            approval_reference: null,
          }
        : null;
      const boundTranscript = request.decision === 'denied'
        ? {
            schema_version: 1 as const,
            transcript_ref: options.transcriptRef ?? AGENT_TRANSCRIPT,
            generation: deniedGeneration,
            transcript_sha256: deniedGeneration.toString(16).slice(-1).repeat(64),
            transcript_bytes: deniedGeneration * 10,
          }
        : null;
      const boundReference = request.decision === 'denied' || request.decision === 'cancelled'
        ? null
        : request.operation_id;
      return { schema_version: 2 as const, status: 'bound' as const, operation_id: request.operation_id, task_id: request.task_id, attempt_id: request.attempt_id, round_id: request.round_id, call_index: request.call_index, call_id: request.call_id, decision: request.decision, approval_reference: boundReference, grant: request.decision === 'allow_conversation' ? conversationGrantFor(request.token.name) : null, result_batch_revision: request.batch_revision, observed_checkpoint: request.committed_checkpoint, receipt: boundReceipt, transcript: boundTranscript };
    });
    const executeAgentTool = jest.fn(async (request: ExecuteAgentToolRequestV2): Promise<ExecuteAgentToolResultV2> => {
      operations.push(executeAgentTool);
      const cancelled = options.cancelledCallIds?.includes(request.call_id) === true;
      const receipt: AgentToolReceiptV1 = { schema_version: 1, call_id: request.call_id, name: request.name, arguments_sha256: request.arguments_sha256, result_sha256: `${request.call_index + 6}`.repeat(64), result_bytes: 1, truncated: false, duration_ms: 1, outcome: cancelled ? 'cancelled' : 'ok', failure_code: cancelled ? 'E_AGENT_CANCELLED' : null, approval_reference: request.approval_reference };
      const nextGeneration = request.transcript.generation + 1;
      const commonResult = { operation_id: request.operation_id, task_id: request.task_id, attempt_id: request.attempt_id, round_id: request.round_id, round_index: request.round_index, call_index: request.call_index, call_id: request.call_id, name: request.name, idempotency_key: request.idempotency_key, result_execution_revision: request.expected_execution_revision + 3, transcript: { schema_version: 1 as const, transcript_ref: options.transcriptRef ?? AGENT_TRANSCRIPT, generation: nextGeneration, transcript_sha256: nextGeneration.toString(16).slice(-1).repeat(64), transcript_bytes: nextGeneration * 10 }, receipt };
      if (cancelled) {
        return { schema_version: 2, status: 'cancelled', ...commonResult, effect_may_have_occurred: false };
      }
      return { schema_version: 2, status: 'completed', ...commonResult, effect_may_have_occurred: true };
    });
    const finalizeAgentAttempt = jest.fn(async (request: any) => ({ schema_version: 2 as const, status: 'terminal' as const, operation_id: request.operation_id, cleanup_id: request.cleanup_id, transcript: request.transcript }));
    const discardAgentAttempt = jest.fn(async (request: any) => ({ schema_version: 2 as const, status: 'discarded' as const, operation_id: request.operation_id, cleanup_id: request.cleanup_id }));
    const runtime: AgentRuntimeFacadeV2 = {
      isAvailable: () => true,
      prepareAgentAttempt,
      completeAgentRoundV2,
      prepareAgentToolBatch,
      bindAgentApproval,
      executeAgentTool,
      cancelAgentAttempt: jest.fn(),
      queryAgentAttempt: jest.fn(),
      queryAgentTool: jest.fn(),
      recoverAgentAttempt: jest.fn(),
      finalizeAgentAttempt,
      discardAgentAttempt,
      interruptAgentAttempt: jest.fn(),
      queryAgentCleanup: jest.fn(),
    };
    return runtime;
  }

  function committedPersistence(store: ChatStore) {
    return jest.fn(async (): Promise<CompletionPersistenceResult> => {
      const digest = sessionSnapshotSHA256(store.serialize())!;
      const generation = (store.getSessionAuthority()?.generation ?? 1) + 1;
      const snapshot = { schema_version: 1 as const, generation, session_sha256: digest };
      store.setSessionAuthority({ generation, sessionSha256: digest });
      return { status: 'committed', snapshot };
    });
  }

  function agentController(
    store: ChatStore,
    runtime: AgentRuntimeFacadeV2,
    persistCurrent: () => Promise<CompletionPersistenceResult>,
    operationIds = [...IDS],
    requestAgentApproval = jest.fn(async () => ({ status: 'approved' as const, scope: 'once' as const })),
    now: () => string = () => NOW,
    requestBatchApprovals?: CompletionControllerDependencies['requestBatchApprovals'],
    previewSource?: CompletionControllerDependencies['previewSource'],
  ) {
    return createCompletionController({
      chat: store,
      persistCurrent,
      completeRoundV2: jest.fn(),
      completeRoundV3: jest.fn(),
      cancelRoundV2: jest.fn(),
      cancelRoundV3: jest.fn(),
      createRoundId: jest.fn(() => operationIds.shift() ?? AGENT_TURN),
      createOperationId: jest.fn(() => operationIds.shift() ?? AGENT_ATTEMPT),
      agentRuntime: runtime,
      requestAgentApproval,
      now,
      ...(requestBatchApprovals === undefined
        ? {}
        : { requestBatchApprovals }),
      ...(previewSource === undefined ? {} : { previewSource }),
    });
  }

  test.each(['ambiguous', 'unknown'] as const)(
    'persists a GLM %s round without discarding unresolved native evidence',
    async status => {
      const store = agentStore('GLM-5.3');
      const conversationId = store.getState().selectedConversationId!;
      const runtime = makeRuntime([]);
      (runtime.completeAgentRoundV2 as jest.Mock).mockImplementationOnce(
        async (request: CompleteAgentRoundRequestV2): Promise<CompleteAgentRoundResultV2> => ({
          schema_version: 2,
          status,
          operation_id: request.operation_id,
          task_id: request.task_id,
          attempt_id: request.attempt_id,
          round_id: request.round_id,
          round_index: request.round_index,
          launch_attempt: request.launch_attempt,
          result_round_revision: 3,
          transcript: request.transcript,
          failure_code: status === 'ambiguous'
            ? 'E_AGENT_ROUND_AMBIGUOUS'
            : 'E_AGENT_CONFLICT',
        }),
      );
      const checkpoint = jest.spyOn(store, 'failAgentAttempt');
      const committed: string[] = [];
      const persistCurrent = jest.fn(async (): Promise<CompletionPersistenceResult> => {
        const session = store.serialize();
        const generation = (store.getSessionAuthority()?.generation ?? 1) + 1;
        const digest = sessionSnapshotSHA256(session)!;
        committed.push(session);
        store.setSessionAuthority({ generation, sessionSha256: digest });
        return { status: 'committed', snapshot: {
          schema_version: 1, generation, session_sha256: digest,
        } };
      });
      const controller = agentController(store, runtime, persistCurrent);
      const result = await controller.send({ conversationId, harnessId: 'glm', text: 'read only', attachments: [] });
      const failureCode = status === 'ambiguous'
        ? 'E_AGENT_EXECUTION_AMBIGUOUS'
        : 'E_AGENT_CONFLICT';
      expect(result.status).toBe('retryable');
      // What the person is shown. An ambiguous round says a request may have
      // reached the service; it used to be shown as an ambiguous
      // *execution*, which says instead that a tool may already have changed
      // their files. The persisted attempt still carries the older code --
      // `persistence.ts` requires it and sessions on disk have it -- so the
      // two differ until that migration lands.
      expect(controller.getState().failureCode).toBe(
        status === 'ambiguous' ? 'E_AGENT_ROUND_AMBIGUOUS' : 'E_AGENT_CONFLICT',
      );
      expect(checkpoint).toHaveBeenCalledTimes(1);
      expect(checkpoint.mock.calls[0]![0].cleanup).toBeUndefined();
      const expectedAttempt = {
        status: 'failed', harnessId: 'glm', modelId: 'GLM-5.3', failureCode,
        activeRound: null,
        agent: { phase: status, round_lineage: { status, native_row_revision: 3 } },
      };
      expect(store.getState().conversations[conversationId]?.attempts[0]).toMatchObject(expectedAttempt);
      const restored = hydrateChatState(committed.at(-1)!);
      expect(restored.conversations[conversationId]?.attempts[0]).toMatchObject(expectedAttempt);
      expect(restored.agentTranscriptCleanupOutbox).toEqual([]);
      expect(runtime.completeAgentRoundV2).toHaveBeenCalledTimes(1);
      expect(runtime.prepareAgentToolBatch).not.toHaveBeenCalled();
      expect(runtime.executeAgentTool).not.toHaveBeenCalled();
      expect(runtime.finalizeAgentAttempt).not.toHaveBeenCalled();
      expect(runtime.discardAgentAttempt).not.toHaveBeenCalled();
    },
  );

  test('does not invoke Agent native effects when outer preparation is not durable', async () => {
    const store = agentStore();
    const runtime = makeRuntime([]);
    const persistCurrent = jest.fn(async (): Promise<CompletionPersistenceResult> => ({ status: 'not_committed' }));
    const controller = agentController(store, runtime, persistCurrent);
    const conversationId = store.getState().selectedConversationId!;

    const result = await controller.send({ conversationId, text: 'write', attachments: [] });

    expect(result).toMatchObject({ status: 'blocked', code: 'E_ATTEMPT_PERSISTENCE' });
    expect(runtime.prepareAgentAttempt).not.toHaveBeenCalled();
    expect(runtime.completeAgentRoundV2).not.toHaveBeenCalled();
    expect(store.getState().conversations[conversationId]?.attempts).toHaveLength(0);
  });

  test.each(['native preparation', 'initial checkpoint'] as const)(
    'cancels during %s without launching a round or blocking navigation', async stage => {
      const store = agentStore();
      const runtime = makeRuntime([]);
      const held = deferred<void>();
      let reached = false;
      const prepare = runtime.prepareAgentAttempt;
      if (stage === 'native preparation') {
        runtime.prepareAgentAttempt = jest.fn(async request => {
          const result = await prepare(request);
          reached = true;
          await held.promise;
          return result;
        });
      }
      const commit = committedPersistence(store);
      const persist = jest.fn(async () => {
        const attempt = store.getState().conversations[AGENT_CONVERSATION]?.attempts[0];
        if (stage === 'initial checkpoint' && !reached && attempt?.agent?.phase === 'ready_for_round') {
          reached = true;
          await held.promise;
        }
        return await commit();
      });
      (runtime.cancelAgentAttempt as jest.Mock).mockImplementation(async request => {
        const journal = store.getState().conversations[AGENT_CONVERSATION]!.attempts[0]!.agent!;
        expect(journal.phase).toBe(request.cancel_token.expected_phase);
        return { schema_version: 2, status: 'cancelled', operation_id: request.operation_id,
          target: request.target, result_round_revision: null, result_execution_revision: null,
          transcript: request.expected_transcript, receipt: null, effect_may_have_occurred: false,
          observed_checkpoint: request.committed_checkpoint };
      });
      const controller = agentController(store, runtime, persist);
      const conversationId = store.getState().selectedConversationId!;
      const send = controller.send({ conversationId, text: 'Cancel before the first round', attachments: [] });
      for (let i = 0; i < 40 && !reached; i++) await Promise.resolve();
      expect(reached).toBe(true);
      await controller.cancel();
      expect(controller.getState().phase).toBe('cancelling');
      held.resolve();
      await send;
      expect(runtime.completeAgentRoundV2).not.toHaveBeenCalled();
      expect(runtime.executeAgentTool).not.toHaveBeenCalled();
      expect(runtime.cancelAgentAttempt).toHaveBeenCalledTimes(1);
      expect(store.getState().conversations[conversationId]?.attempts[0]).toMatchObject({ status: 'cancelled', agent: { phase: 'cancelled', round_lineage: null } });
      expect(await controller.beforeConversationChange(conversationId)).toBe(true);
      expect(await controller.beforeConversationDelete(conversationId)).toBe(true);
      expect(controller.reconcileHydrated(conversationId).phase).toBe('idle');
      expect(runtime.recoverAgentAttempt).not.toHaveBeenCalled();
      const snapshot = store.getState();
      const previous = snapshot.conversations[conversationId]!;
      const interrupted = createChatStore({ initialState: { ...snapshot,
        conversations: { ...snapshot.conversations, [conversationId]: { ...previous,
          attempts: previous.attempts.map(attempt => ({ ...attempt, status: 'failed' as const,
            failureCode: 'E_ATTEMPT_INTERRUPTED' as const,
            agent: { ...attempt.agent!, phase: 'ready_for_round' as const, round_lineage: null },
          })),
        } },
      } });
      const restarted = agentController(interrupted, runtime, committedPersistence(interrupted));
      expect(await restarted.beforeConversationDelete(conversationId)).toBe(true);
      expect(runtime.cancelAgentAttempt).toHaveBeenCalledTimes(1);
    },
  );

  test('streamed previews follow the in-flight round and drop when the run settles', async () => {
    const store = agentStore();
    const runtime = makeRuntime([]);
    const round = deferred<CompleteAgentRoundResultV2>();
    (runtime.completeAgentRoundV2 as jest.Mock).mockImplementationOnce(() => round.promise);
    (runtime.cancelAgentAttempt as jest.Mock).mockImplementation(async (request: any): Promise<CancelAgentAttemptResultV2> => ({
      schema_version: 2,
      status: 'cancelled',
      operation_id: request.operation_id,
      target: request.target,
      result_round_revision: request.target.kind === 'round' ? 1 : null,
      result_execution_revision: null,
      transcript: request.expected_transcript,
      receipt: null,
      effect_may_have_occurred: false,
      observed_checkpoint: request.committed_checkpoint,
    }));
    let emit: ((event: AgentRoundPreviewEvent) => void) | null = null;
    const previewSource = jest.fn((listener: (event: AgentRoundPreviewEvent) => void) => {
      emit = listener;
      return () => { emit = null; };
    });
    const controller = agentController(store, runtime, committedPersistence(store), [...IDS], undefined, undefined, undefined, previewSource);
    const published: AgentRoundPreviews[] = [];
    controller.subscribePreviews(previews => published.push(previews));
    expect(previewSource).not.toHaveBeenCalled();
    const conversationId = store.getState().selectedConversationId!;
    const sendPromise = controller.send({ conversationId, text: 'stream me', attachments: [] });
    for (let index = 0; index < 20 && !(runtime.completeAgentRoundV2 as jest.Mock).mock.calls.length; index += 1) {
      await Promise.resolve();
    }
    expect(previewSource).toHaveBeenCalledTimes(1);
    const request = (runtime.completeAgentRoundV2 as jest.Mock).mock.calls[0][0] as CompleteAgentRoundRequestV2;
    const correlation = {
      taskId: request.task_id,
      attemptId: request.attempt_id,
      roundId: request.round_id,
      roundIndex: request.round_index,
      operationId: request.operation_id,
      providerRequestId: '77777777-7777-4777-8777-000000000001',
      harnessId: request.harness_id,
    };
    emit!({ ...correlation, kind: 'delta', seq: 1, reasoning: 'thinking' });
    emit!({ ...correlation, kind: 'delta', seq: 2, text: 'Hel' });
    // A stale operation or another round never reaches the preview.
    emit!({ ...correlation, operationId: 'someone-else', kind: 'delta', seq: 3, text: 'XX' });
    emit!({ ...correlation, roundId: '22222222-2222-4222-8222-222222222222', kind: 'delta', seq: 1, text: 'YY' });
    emit!({ ...correlation, kind: 'delta', seq: 3, text: 'lo' });
    const preview = controller.getPreviews()[request.round_id];
    expect(preview).toMatchObject({ reasoning: 'thinking', text: 'Hello', lastSeq: 3, incomplete: false });
    expect(Object.keys(controller.getPreviews())).toEqual([request.round_id]);
    expect(published.length).toBe(3);
    expect(store.getState().sessionEvents ?? []).not.toContainEqual(expect.objectContaining({ text: 'Hello' }));

    await controller.cancel();
    expect(controller.getPreviews()).toEqual({});
    expect(published.at(-1)).toEqual({});
    round.resolve(undefined as unknown as CompleteAgentRoundResultV2);
    await sendPromise;
  });

  test('a validated round keeps its preview until the run ends, then the durable message stands alone', async () => {
    const store = agentStore();
    const runtime = makeRuntime([], { finalRoundIndex: 0 });
    const original = (runtime.completeAgentRoundV2 as jest.Mock).getMockImplementation()!;
    let emit: ((event: AgentRoundPreviewEvent) => void) | null = null;
    const controller = agentController(store, runtime, committedPersistence(store), [...IDS], undefined, undefined, undefined,
      listener => { emit = listener; return () => {}; });
    let previewDuringRound: AgentRoundPreviews | null = null;
    (runtime.completeAgentRoundV2 as jest.Mock).mockImplementationOnce(async (request: CompleteAgentRoundRequestV2) => {
      const correlation = {
        taskId: request.task_id, attemptId: request.attempt_id, roundId: request.round_id,
        roundIndex: request.round_index, operationId: request.operation_id,
        providerRequestId: '77777777-7777-4777-8777-000000000001', harnessId: request.harness_id,
      };
      emit!({ ...correlation, kind: 'delta', seq: 1, text: 'done' });
      emit!({ ...correlation, kind: 'end', seq: 2, status: 'validated', truncated: false });
      previewDuringRound = controller.getPreviews();
      return original(request);
    });
    const conversationId = store.getState().selectedConversationId!;
    const outcome = await controller.send({ conversationId, text: 'stream me', attachments: [] });
    expect(outcome.status).toBe('completed');
    expect(previewDuringRound).not.toBeNull();
    expect(Object.values(previewDuringRound!)[0]).toMatchObject({ text: 'done', ended: { status: 'validated', failureCode: null } });
    expect(controller.getState().phase).toBe('idle');
    expect(controller.getPreviews()).toEqual({});
  });

  test('cancel persists request_cancel before native cancel and never runs the held round', async () => {
    const store = agentStore();
    const runtime = makeRuntime([]);
    const round = deferred<CompleteAgentRoundResultV2>();
    (runtime.completeAgentRoundV2 as jest.Mock).mockImplementationOnce(() => round.promise);
    (runtime.cancelAgentAttempt as jest.Mock).mockImplementation(async (request: any): Promise<CancelAgentAttemptResultV2> => ({
      schema_version: 2,
      status: 'cancelled',
      operation_id: request.operation_id,
      target: request.target,
      result_round_revision: request.target.kind === 'round' ? 1 : null,
      result_execution_revision: null,
      transcript: request.expected_transcript,
      receipt: null,
      effect_may_have_occurred: false,
      observed_checkpoint: request.committed_checkpoint,
    }));
    const persistCurrent = committedPersistence(store);
    const controller = agentController(store, runtime, persistCurrent);
    const conversationId = store.getState().selectedConversationId!;
    const sendPromise = controller.send({ conversationId, text: 'cancel me', attachments: [] });
    for (let index = 0; index < 20 && !(runtime.completeAgentRoundV2 as jest.Mock).mock.calls.length; index += 1) {
      await Promise.resolve();
    }
    expect(runtime.completeAgentRoundV2).toHaveBeenCalledTimes(1);

    await controller.cancel();
    expect(runtime.cancelAgentAttempt).toHaveBeenCalledTimes(1);
    expect((runtime.cancelAgentAttempt as jest.Mock).mock.invocationCallOrder[0]).toBeGreaterThan(
      (runtime.completeAgentRoundV2 as jest.Mock).mock.invocationCallOrder[0] ?? 0,
    );
    expect(
      persistCurrent.mock.invocationCallOrder.some(
        order => order < (runtime.cancelAgentAttempt as jest.Mock).mock.invocationCallOrder[0]!,
      ),
    ).toBe(true);
    expect(runtime.finalizeAgentAttempt).toHaveBeenCalledTimes(1);
    expect(runtime.discardAgentAttempt).toHaveBeenCalledTimes(1);
    expect(store.getState().agentTranscriptCleanupOutbox).toEqual([]);

    // The round was still in flight when cancel committed; its late result
    // must be ignored and cannot trigger another native call.
    round.resolve({} as CompleteAgentRoundResultV2);
    await sendPromise;
    expect(runtime.completeAgentRoundV2).toHaveBeenCalledTimes(1);
  });

  test.each(['timeout', 'cancel', 'delete', 'navigate'] as const)('a stalled recovery query %s releases only its transient owner without replay', async action => {
    const store = agentStore();
    const runtime = makeRuntime([]);
    (runtime.completeAgentRoundV2 as jest.Mock).mockImplementationOnce(async (request: CompleteAgentRoundRequestV2) => ({
      schema_version: 2, status: 'in_flight', operation_id: request.operation_id,
      task_id: request.task_id, attempt_id: request.attempt_id, round_id: request.round_id,
      round_index: request.round_index, launch_attempt: request.launch_attempt,
      result_round_revision: 1, transcript: request.transcript,
    }));
    const first = agentController(store, runtime, committedPersistence(store));
    const conversationId = store.getState().selectedConversationId!;
    await first.send({ conversationId, text: 'recovery read', attachments: [] });
    const attempt = store.getState().conversations[conversationId]!.attempts[0]!;
    const journal = attempt.agent;
    const late = deferred<QueryAgentAttemptResultV2>();
    (runtime.queryAgentAttempt as jest.Mock).mockReturnValue(late.promise);
    const controller = agentController(store, runtime, committedPersistence(store));
    jest.useFakeTimers();
    try {
      const pending = controller.resume(conversationId, attempt.attemptId);
      await Promise.resolve();
      expect(controller.getState().phase).toBe('recovering');
      if (action === 'timeout') await jest.advanceTimersByTimeAsync(15000);
      else if (action === 'delete') expect(await controller.beforeConversationDelete(conversationId)).toBe(false);
      else if (action === 'navigate') expect(await controller.beforeConversationChange(conversationId)).toBe(true);
      else await controller.cancel();
      expect(controller.getState().phase).toBe('resume_available');
      await pending;
      expect(store.getState().conversations[conversationId]!.attempts[0]!.agent).toEqual(journal);
      expect(runtime.cancelAgentAttempt).not.toHaveBeenCalled();
      expect(runtime.recoverAgentAttempt).not.toHaveBeenCalled();
      expect(await controller.beforeConversationChange(conversationId)).toBe(true);
      expect(await controller.beforeConversationDelete(conversationId)).toBe(false);
      const protectedConversation = store.getState().conversations[conversationId];
      store.deleteConversation(conversationId);
      expect(store.getState().conversations[conversationId]).toBe(protectedConversation);
      late.resolve({ schema_version: 2, status: 'not_found', failure_code: 'E_AGENT_NOT_FOUND' });
      await Promise.resolve();
      expect(controller.getState().phase).toBe('resume_available');
      // A second explicit inspection remains possible; the old result cannot
      // start a provider, tool, or recovery mutation.
      (runtime.queryAgentAttempt as jest.Mock).mockResolvedValue({ schema_version: 2, status: 'not_found', failure_code: 'E_AGENT_NOT_FOUND' });
      await controller.resume(conversationId, attempt.attemptId);
      expect(runtime.queryAgentAttempt).toHaveBeenCalledTimes(2);
      expect(runtime.completeAgentRoundV2).toHaveBeenCalledTimes(1);
      expect(runtime.executeAgentTool).not.toHaveBeenCalled();
    } finally { jest.useRealTimers(); }
  });

  /**
   * A round the provider never answered ends the attempt. The store keeps
   * terminal Agent phases on the atomic final checkpoint, so a failed round
   * that was checkpointed through the ordinary controller transaction was
   * refused outright: the journal stayed `round_in_flight`, the attempt stayed
   * `sending`, and the turn could neither finish nor be recovered.
   */
  /**
   * A round that reached the provider and was never answered is `ambiguous`,
   * and recovery answers that with manual reconciliation forever -- rightly,
   * since the model may already have done the work. Giving up on the attempt
   * is the one decision only a person can make, and it has to leave the turn
   * askable again: the old attempt recorded as a dead writer's is, its
   * native residue settled by the interrupt (the only operation that clears
   * an ambiguous round), and a fresh attempt in the same turn.
   */
  test('giving up on an unresolved round settles it and asks the turn again', async () => {
    const store = agentStore();
    const runtime = makeRuntime([]);
    (runtime.completeAgentRoundV2 as jest.Mock).mockImplementationOnce(async (request: CompleteAgentRoundRequestV2) => ({
      schema_version: 2,
      status: 'ambiguous',
      operation_id: request.operation_id,
      task_id: request.task_id,
      attempt_id: request.attempt_id,
      round_id: request.round_id,
      round_index: request.round_index,
      launch_attempt: request.launch_attempt,
      result_round_revision: 1,
      transcript: request.transcript,
      failure_code: 'E_AGENT_ROUND_AMBIGUOUS',
    }));
    (runtime.interruptAgentAttempt as jest.Mock).mockImplementation(async (request: any) => ({
      schema_version: 2 as const,
      status: 'discarded' as const,
      operation_id: request.operation_id,
      cleanup_id: request.cleanup_id,
    }));
    const controller = agentController(store, runtime, committedPersistence(store));
    const conversationId = store.getState().selectedConversationId!;
    await controller.send({ conversationId, text: 'unresolved round', attachments: [] });
    const attempts = store.getState().conversations[conversationId]!.attempts;
    expect(attempts).toHaveLength(1);
    const unresolved = attempts[0]!;
    expect(unresolved.agent!.phase).toBe('ambiguous');

    await controller.abandonAndRetry(conversationId, unresolved.attemptId);

    const after = store.getState().conversations[conversationId]!;
    const abandoned = after.attempts.find(
      attempt => attempt.attemptId === unresolved.attemptId,
    )!;
    // Recorded exactly as a dead writer's attempt is, journal kept: that is
    // the one failure code the retry reducer accepts a journal with.
    expect(abandoned.status).toBe('failed');
    expect(abandoned.failureCode).toBe('E_ATTEMPT_INTERRUPTED');
    expect(abandoned.agent).not.toBeNull();
    // The residue was settled and the outbox entry acknowledged, rather than
    // left for the next launch.
    expect(runtime.interruptAgentAttempt).toHaveBeenCalledTimes(1);
    expect(store.getState().agentTranscriptCleanupOutbox ?? []).toHaveLength(0);
    // And the turn asked again, in the same turn, with a second round.
    expect(after.attempts).toHaveLength(2);
    const fresh = after.attempts[1]!;
    expect(fresh.turnId).toBe(unresolved.turnId);
    expect(fresh.attemptId).not.toBe(unresolved.attemptId);
    expect(runtime.completeAgentRoundV2).toHaveBeenCalledTimes(2);
  });

  test('a round that failed retryably ends the attempt instead of leaving it sending', async () => {
    const store = agentStore();
    const runtime = makeRuntime([]);
    (runtime.completeAgentRoundV2 as jest.Mock).mockImplementationOnce(async (request: CompleteAgentRoundRequestV2) => ({
      schema_version: 2,
      status: 'failed_retryable',
      operation_id: request.operation_id,
      task_id: request.task_id,
      attempt_id: request.attempt_id,
      round_id: request.round_id,
      round_index: request.round_index,
      launch_attempt: request.launch_attempt,
      result_round_revision: 1,
      transcript: request.transcript,
      failure_code: 'E_AGENT_CAPABILITY',
    }));
    const controller = agentController(store, runtime, committedPersistence(store));
    const conversationId = store.getState().selectedConversationId!;
    await controller.send({ conversationId, text: 'offline round', attachments: [] });
    const attempt = store.getState().conversations[conversationId]!.attempts[0]!;
    expect(attempt.agent!.phase).toBe('failed');
    expect(attempt.agent!.round_lineage!.status).toBe('failed_retryable');
    expect(attempt.status).toBe('failed');
    // The round said why, and that is what the attempt records. It used to
    // be flattened to E_AGENT_PERSISTENCE, so a request refused for carrying
    // an attachment read as a save that could not be confirmed, with Retry
    // save as the only advice.
    expect(attempt.failureCode).toBe('E_AGENT_CAPABILITY');
    const terminal = (store.getState().sessionEvents ?? []).filter(
      event => event.attempt_id === attempt.attemptId && event.kind === 'terminal',
    );
    expect(terminal).toHaveLength(1);
    expect(terminal[0]!.failure_code).toBe('E_AGENT_CAPABILITY');
    // The terminal checkpoint carries its cleanup, and finalize/discard drain
    // it: a refused checkpoint reached neither.
    expect(runtime.finalizeAgentAttempt).toHaveBeenCalledTimes(1);
    expect(runtime.discardAgentAttempt).toHaveBeenCalledTimes(1);
  });


  /**
   * A turn interrupted while it was waiting for a person has to be able to
   * ask again.
   *
   * Four separate rules had to agree before it could. The recovery must not
   * target a round whose outcome the journal already carries -- the round
   * selector binds the request to the row's *before* transcript, so a
   * committed round always answers conflict. The reducer must allow a
   * recovery that finds the attempt standing still. The projection and the
   * journal must describe an open intent in the same words. And the approval
   * tokens, which live only in the run, have to be taken back from the
   * projection, or the call has nothing to show.
   */
  test('a turn recovered while it waits for a person asks again', async () => {
    const store = agentStore();
    const runtime = makeRuntime([]);
    const conversationId = store.getState().selectedConversationId!;
    // Hold the turn where a person would hold it: at the question.
    const asked = deferred<{ status: 'approved'; scope: 'once' }>();
    const first = agentController(
      store, runtime, committedPersistence(store), [...IDS],
      jest.fn(async () => await asked.promise),
    );
    const sending = first.send({ conversationId, text: 'approve me', attachments: [] });
    for (let index = 0; index < 200 && first.getState().phase !== 'approval_pending'; index += 1) {
      await Promise.resolve();
    }
    const attempt = store.getState().conversations[conversationId]!.attempts[0]!;
    const journal = attempt.agent!;
    expect(journal.phase).toBe('approval_pending');
    expect(first.getState().phase).toBe('approval_pending');

    // What native reports about the same attempt. The calls are the ones the
    // batch preparation already returned, so their execution status is
    // native's own word for an open intent rather than this test's.
    const prepared = await (runtime.prepareAgentToolBatch as jest.Mock).mock.results[0]!.value;
    const projection: AgentAttemptProjectionV2 = {
      schema_version: 2,
      task_id: attempt.turnId,
      conversation_id: conversationId,
      attempt_id: attempt.attemptId,
      phase: journal.phase,
      controller_generation: journal.controller_generation + 1,
      journal_revision: attempt.journalRevision ?? 0,
      authority_revision: 1,
      root: journal.root,
      policy: {
        schema_version: 1,
        policy_version: 'agent-v1',
        max_single_write_bytes: journal.policy.max_single_write_bytes,
        max_batch_write_bytes: journal.policy.max_batch_write_bytes,
        max_attempt_write_bytes: journal.policy.max_attempt_write_bytes,
      },
      registry: {
        schema_version: 2,
        registry_version: journal.tool_registry_version,
        toolset_sha256: journal.toolset_sha256,
        tools: [],
      },
      transcript: journal.transcript,
      round_index: journal.round_index,
      round_id: journal.round_lineage?.round_id ?? null,
      round_revision: journal.round_lineage?.native_row_revision ?? null,
      round_status: journal.round_lineage?.status ?? null,
      batch_kind: prepared.receipt.batch_kind,
      batch_revision: prepared.receipt.batch_revision,
      manifest_sha256: prepared.receipt.manifest_sha256,
      call_index: journal.call_index,
      batch: prepared.receipt.calls,
      frozen_grant_ids: [...journal.frozen_grant_ids],
      reserved_write_bytes: journal.reserved_write_bytes,
      cancel_source_event_id: null,
      cleanup_id: null,
    };
    (runtime.queryAgentAttempt as jest.Mock).mockResolvedValue({
      schema_version: 2,
      status: 'active',
      attempt: projection,
    } as QueryAgentAttemptResultV2);
    (runtime.recoverAgentAttempt as jest.Mock).mockImplementation(async (request: any): Promise<RecoverAgentAttemptResultV2> => ({
      schema_version: 2,
      status: 'resumed',
      operation_id: request.operation_id,
      next_action: 'none',
      attempt: projection,
      completed_round: null,
    }));

    // A reload: the journal survives, the run's approval tokens do not.
    // A recovery mints its own operation ids; sharing the first run's queue
    // would replay an event the session already holds.
    const askedAgain = jest.fn(async () => ({ status: 'approved' as const, scope: 'once' as const }));
    const reloaded = agentController(store, runtime, committedPersistence(store), [
      '51515151-5151-4515-8515-515151515151',
      '52525252-5252-4525-8525-525252525252',
      '53535353-5353-4535-8535-535353535353',
      '54545454-5454-4545-8545-545454545454',
      '55555555-5555-4555-8555-555555555555',
      '56565656-5656-4565-8565-565656565656',
      '57575757-5757-4575-8575-575757575757',
    ], askedAgain);
    await reloaded.resume(conversationId, attempt.attemptId);

    const target = (runtime.recoverAgentAttempt as jest.Mock).mock.calls[0][0].target;
    expect(target.kind).toBe('attempt');
    // The recovery was accepted rather than refused as a conflict -- which is
    // the whole of what those four rules had to agree on -- and the turn put
    // its question back to the person.
    const after = store.getState().conversations[conversationId]!.attempts[0]!.agent!;
    expect(after.controller_generation).toBeGreaterThan(journal.controller_generation);
    expect(askedAgain).toHaveBeenCalled();
    asked.resolve({ status: 'approved', scope: 'once' });
    await sending;
  });

  test('restarts through query/recover without replaying an in-flight round', async () => {

    const store = agentStore();
    const runtime = makeRuntime([]);
    (runtime.completeAgentRoundV2 as jest.Mock).mockImplementationOnce(async (request: CompleteAgentRoundRequestV2) => ({
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
    }));
    const firstController = agentController(store, runtime, committedPersistence(store));
    const conversationId = store.getState().selectedConversationId!;
    const first = await firstController.send({ conversationId, text: 'resume me', attachments: [] });
    expect(first.status).toBe('retryable');
    expect(firstController.getState().phase).toBe('resume_available');
    expect(runtime.completeAgentRoundV2).toHaveBeenCalledTimes(1);

    const attempt = store.getState().conversations[conversationId]!.attempts[0]!;
    const journal = attempt.agent!;
    const projection: AgentAttemptProjectionV2 = {
      schema_version: 2,
      task_id: attempt.turnId,
      conversation_id: conversationId,
      attempt_id: attempt.attemptId,
      phase: journal.phase,
      controller_generation: journal.controller_generation,
      journal_revision: attempt.journalRevision ?? 0,
      authority_revision: 1,
      root: journal.root,
      policy: {
        schema_version: 1,
        policy_version: 'agent-v1',
        max_single_write_bytes: journal.policy.max_single_write_bytes,
        max_batch_write_bytes: journal.policy.max_batch_write_bytes,
        max_attempt_write_bytes: journal.policy.max_attempt_write_bytes,
      },
      registry: {
        schema_version: 2,
        registry_version: journal.tool_registry_version,
        toolset_sha256: journal.toolset_sha256,
        tools: [],
      },
      transcript: journal.transcript,
      round_index: journal.round_index,
      round_id: journal.round_lineage?.round_id ?? null,
      round_revision: journal.round_lineage?.native_row_revision ?? null,
      round_status: journal.round_lineage?.status ?? null,
      batch_kind: null,
      batch_revision: null,
      manifest_sha256: null,
      call_index: null,
      batch: [],
      frozen_grant_ids: [...journal.frozen_grant_ids],
      reserved_write_bytes: journal.reserved_write_bytes,
      cancel_source_event_id: null,
      cleanup_id: null,
    };
    (runtime.queryAgentAttempt as jest.Mock).mockResolvedValue({
      schema_version: 2,
      status: 'active',
      attempt: projection,
    } as QueryAgentAttemptResultV2);
    (runtime.recoverAgentAttempt as jest.Mock).mockImplementation(async (request: any): Promise<RecoverAgentAttemptResultV2> => ({
      schema_version: 2,
      status: 'manual_reconciliation',
      operation_id: request.operation_id,
      next_action: 'inspect_native_state',
      attempt: projection,
      completed_round: null,
    }));

    const restarted = agentController(store, runtime, committedPersistence(store));
    const recovered = await restarted.resume(conversationId, attempt.attemptId);
    expect(recovered.status).toBe('retryable');
    expect(restarted.getState().phase).toBe('resume_available');
    expect(runtime.queryAgentAttempt).toHaveBeenCalledTimes(1);
    expect(runtime.recoverAgentAttempt).toHaveBeenCalledTimes(1);
    const retried = await restarted.retry(conversationId, attempt.attemptId);
    expect(retried).toMatchObject({ status: 'retryable', code: 'E_AGENT_EXECUTION_AMBIGUOUS' });
    expect(runtime.queryAgentAttempt).toHaveBeenCalledTimes(2);
    expect(runtime.recoverAgentAttempt).toHaveBeenCalledTimes(2);
    expect(await restarted.beforeConversationChange(conversationId)).toBe(true);
    expect(runtime.cancelAgentAttempt).not.toHaveBeenCalled();
    expect(store.getState().conversations[conversationId]!.attempts[0]!.agent).toEqual(journal);
    expect(runtime.completeAgentRoundV2).toHaveBeenCalledTimes(1);
    expect(runtime.prepareAgentToolBatch).not.toHaveBeenCalled();
    expect(runtime.executeAgentTool).not.toHaveBeenCalled();
  });

  test('freezes one timestamp across an atomic final checkpoint when the clock advances', async () => {
    const store = agentStore();
    const conversationId = store.getState().selectedConversationId!;
    const runtime = makeRuntime([], { finalRoundIndex: 0 });
    const finalStore = jest.spyOn(store, 'completeAgentAttempt');
    let tick = 0;
    const observedTimes: string[] = [];
    const advancingNow = jest.fn(() => {
      const value = new Date(Date.parse(NOW) + tick).toISOString();
      tick += 1;
      observedTimes.push(value);
      return value;
    });
    const controller = agentController(
      store,
      runtime,
      committedPersistence(store),
      [...IDS],
      undefined,
      advancingNow,
    );

    const result = await controller.send({
      conversationId,
      text: 'finish with a moving clock',
      attachments: [],
    });

    expect(result.status).toBe('completed');
    expect(new Set(observedTimes).size).toBeGreaterThan(1);
    expect(finalStore).toHaveBeenCalledTimes(1);
    const terminal = finalStore.mock.calls[0]?.[0];
    const terminalEvent = terminal?.events.find(event => event.kind === 'terminal');
    expect(terminalEvent).toBeDefined();
    expect(terminal?.journal.updated_at).toBe(terminal?.cleanup.created_at);
    expect(terminalEvent?.created_at).toBe(terminal?.cleanup.created_at);
    expect(terminal?.assistantMessage?.createdAt).toBe(terminal?.cleanup.created_at);
    expect(store.getState().conversations[conversationId]?.attempts[0]).toMatchObject({
      status: 'completed',
      agent: { phase: 'final_response' },
    });
  });

  test('reconciles a hydrated completed Agent attempt to idle without native recovery', async () => {
    const source = agentStore();
    const conversationId = source.getState().selectedConversationId!;
    const sourceRuntime = makeRuntime([], { finalRoundIndex: 0 });
    const sourceController = agentController(
      source,
      sourceRuntime,
      committedPersistence(source),
      [...IDS],
    );

    await expect(sourceController.send({
      conversationId,
      text: 'complete before restart',
      attachments: [],
    })).resolves.toMatchObject({ status: 'completed' });
    expect(source.getState().agentTranscriptCleanupOutbox).toEqual([]);

    const hydrated = createChatStore({
      initialState: hydrateChatState(source.serialize()),
      sessionAuthority: source.getSessionAuthority()!,
    });
    const restartedRuntime = makeRuntime([]);
    const restarted = agentController(
      hydrated,
      restartedRuntime,
      committedPersistence(hydrated),
      [...IDS],
    );

    expect(restarted.reconcileHydrated(conversationId)).toMatchObject({
      phase: 'idle',
    });
    expect(restartedRuntime.queryAgentAttempt).not.toHaveBeenCalled();
    expect(restartedRuntime.recoverAgentAttempt).not.toHaveBeenCalled();
    expect(restartedRuntime.completeAgentRoundV2).not.toHaveBeenCalled();
    expect(restartedRuntime.prepareAgentToolBatch).not.toHaveBeenCalled();
    expect(restartedRuntime.executeAgentTool).not.toHaveBeenCalled();
  });

  test('does not resume a hydrated completed Agent attempt with cleanup still pending', async () => {
    const source = agentStore();
    const conversationId = source.getState().selectedConversationId!;
    const sourceRuntime = makeRuntime([], { finalRoundIndex: 0 });
    (sourceRuntime.finalizeAgentAttempt as jest.Mock).mockRejectedValueOnce({
      code: 'E_AGENT_PERSISTENCE',
    });
    const sourceController = agentController(
      source,
      sourceRuntime,
      committedPersistence(source),
      [...IDS],
    );

    await expect(sourceController.send({
      conversationId,
      text: 'complete with cleanup pending',
      attachments: [],
    })).resolves.toMatchObject({ status: 'retryable' });
    expect(source.getState().conversations[conversationId]?.attempts[0]).toMatchObject({
      status: 'completed',
      agent: { phase: 'final_response' },
    });
    expect(source.getState().agentTranscriptCleanupOutbox).toHaveLength(1);

    const hydrated = createChatStore({
      initialState: hydrateChatState(source.serialize()),
      sessionAuthority: source.getSessionAuthority()!,
    });
    const restartedRuntime = makeRuntime([]);
    const restarted = agentController(
      hydrated,
      restartedRuntime,
      committedPersistence(hydrated),
      [...IDS],
    );

    expect(restarted.reconcileHydrated(conversationId)).toMatchObject({
      phase: 'idle',
    });
    expect(hydrated.getState().agentTranscriptCleanupOutbox).toHaveLength(1);
    expect(restartedRuntime.queryAgentAttempt).not.toHaveBeenCalled();
    expect(restartedRuntime.recoverAgentAttempt).not.toHaveBeenCalled();
    expect(restartedRuntime.completeAgentRoundV2).not.toHaveBeenCalled();
    expect(restartedRuntime.prepareAgentToolBatch).not.toHaveBeenCalled();
    expect(restartedRuntime.executeAgentTool).not.toHaveBeenCalled();
  });

  test.each([
    ['empty', ''],
    ['whitespace-only', ' \n\t'],
  ] as const)(
    'completes and round-trips an %s-reasoning final checkpoint while the clock advances',
    async (_label, finalReasoning) => {
      const store = agentStore();
      const conversationId = store.getState().selectedConversationId!;
      const runtime = makeRuntime([], {
        finalRoundIndex: 0,
        finalReasoning,
      });
      let tick = 0;
      const advancingNow = jest.fn(() => {
        const value = new Date(Date.parse(NOW) + tick).toISOString();
        tick += 1;
        return value;
      });
      const controller = agentController(
        store,
        runtime,
        committedPersistence(store),
        [...IDS],
        undefined,
        advancingNow,
      );

      const result = await controller.send({
        conversationId,
        text: 'finish without reasoning while the clock advances',
        attachments: [],
      });

      expect(result.status).toBe('completed');
      expect(advancingNow).toHaveBeenCalled();
      const conversation = store.getState().conversations[conversationId]!;
      expect(conversation.attempts[0]).toMatchObject({
        status: 'completed',
        agent: { phase: 'final_response' },
      });
      const assistant = conversation.messages.find(
        message => message.id === conversation.attempts[0]?.assistantMessageId,
      );
      expect(assistant?.metadata).toEqual({
        modelId: 'deepseek-v4-flash',
        latencyMs: 1,
        finishReason: 'stop',
      });
      expect(assistant?.metadata).not.toHaveProperty('reasoning');

      const serialized = store.serialize();
      const hydrated = hydrateChatState(serialized);
      const hydratedConversation = hydrated.conversations[conversationId]!;
      expect(hydratedConversation.attempts[0]).toMatchObject({
        status: 'completed',
        agent: { phase: 'final_response' },
      });
      const hydratedAssistant = hydratedConversation.messages.find(
        message =>
          message.id === hydratedConversation.attempts[0]?.assistantMessageId,
      );
      expect(hydratedAssistant?.metadata).toEqual({
        modelId: 'deepseek-v4-flash',
        latencyMs: 1,
        finishReason: 'stop',
      });
      expect(hydratedAssistant?.metadata).not.toHaveProperty('reasoning');
    },
  );

  test('drives write approval, commit, next round, and atomic final cleanup', async () => {
    const store = agentStore();
    const conversationId = store.getState().selectedConversationId!;
    const operations: ReturnType<typeof jest.fn>[] = [];
    const runtime = makeRuntime(operations);
    const originalCheckpointAgentRound = store.checkpointAgentRound.bind(store);
    const roundCommitByOperationId = new Map<string, jest.Mock>();
    const roundCommits: Array<{
      readonly kind: string;
      readonly commit: jest.Mock;
    }> = [];
    const roundStore = jest
      .spyOn(store, 'checkpointAgentRound')
      .mockImplementation(input => {
        const transaction = originalCheckpointAgentRound(input);
        if (transaction === null) return null;
        const originalCommit = transaction.commit.bind(transaction);
        const commit = jest.fn(
          (proof: Parameters<typeof transaction.commit>[0]) =>
            originalCommit(proof),
        );
        roundCommitByOperationId.set(input.evidence.operation_id, commit);
        roundCommits.push({ kind: input.evidence.kind, commit });
        return { ...transaction, commit };
      });
    const executionStore = jest.spyOn(store, 'insertAgentExecutionIntent');
    const receiptStore = jest.spyOn(store, 'recordAgentToolResult');
    const combinedStore = jest.spyOn(store, 'recordAgentToolResultAndBeginNext');
    const opIds = [...IDS];
    const committedSnapshots: NonNullable<
      CompletionPersistenceResult['snapshot']
    >[] = [];
    const committedSessions: Array<{
      readonly snapshot: NonNullable<CompletionPersistenceResult['snapshot']>;
      readonly session: string;
    }> = [];
    const persistCurrent = jest.fn(async (): Promise<CompletionPersistenceResult> => {
      const session = store.serialize();
      const digest = sessionSnapshotSHA256(session)!;
      const generation = (store.getSessionAuthority()?.generation ?? 1) + 1;
      const snapshot = { schema_version: 1 as const, generation, session_sha256: digest };
      committedSnapshots.push(snapshot);
      committedSessions.push({ snapshot, session });
      store.setSessionAuthority({ generation, sessionSha256: digest });
      return { status: 'committed', snapshot };
    });
    const controller = createCompletionController({
      chat: store,
      persistCurrent,
      completeRoundV2: jest.fn(),
      completeRoundV3: jest.fn(),
      cancelRoundV2: jest.fn(),
      cancelRoundV3: jest.fn(),
      createRoundId: jest.fn(() => opIds.shift() ?? AGENT_TURN),
      createOperationId: jest.fn(() => opIds.shift() ?? AGENT_ATTEMPT),
      agentRuntime: runtime,
      requestAgentApproval: jest.fn(async () => ({ status: 'approved', scope: 'once' })),
      now: () => NOW,
    });
    const result = await controller.send({ conversationId, text: 'write and commit', attachments: [] });    expect(result.status).toBe('completed');
    expect(runtime.prepareAgentAttempt).toHaveBeenCalledTimes(1);
    expect(runtime.completeAgentRoundV2).toHaveBeenCalledTimes(2);
    expect(runtime.prepareAgentToolBatch).toHaveBeenCalledTimes(1);
    expect(runtime.bindAgentApproval).toHaveBeenCalledTimes(2);
    expect(runtime.executeAgentTool).toHaveBeenCalledTimes(2);
    expect(runtime.finalizeAgentAttempt).toHaveBeenCalledTimes(1);
    expect(runtime.discardAgentAttempt).toHaveBeenCalledTimes(1);
    expect(roundStore.mock.calls.map(call => call[0]?.evidence?.kind)).toEqual([
      'begin_round',
      'complete_agent_round_v2',
      'prepare_agent_tool_batch',
      'begin_round',
    ]);
    const completeRoundCheckpoint = roundStore.mock.calls.find(
      call => call[0]?.evidence?.kind === 'complete_agent_round_v2',
    );
    const batchCheckpoint = roundStore.mock.calls.find(
      call => call[0]?.evidence?.kind === 'prepare_agent_tool_batch',
    );
    const completeRoundEvidence = completeRoundCheckpoint?.[0]?.evidence;
    const batchEvidence = batchCheckpoint?.[0]?.evidence;
    if (
      completeRoundEvidence?.kind !== 'complete_agent_round_v2' ||
      batchEvidence?.kind !== 'prepare_agent_tool_batch'
    ) throw new Error('missing exact round/batch evidence');
    const batchNative = runtime.prepareAgentToolBatch as jest.Mock;
    const batchRequest = batchNative.mock.calls[0]?.[0];
    const batchResult = await batchNative.mock.results[0]?.value;
    expect(completeRoundEvidence.operation_id).not.toBe(batchEvidence.operation_id);
    expect(batchEvidence.operation_id).toBe(batchRequest.operation_id);
    expect(batchEvidence.request).toStrictEqual(batchRequest);
    expect(batchEvidence.result).toStrictEqual(batchResult);

    const completeRoundCommit = roundCommitByOperationId.get(
      completeRoundEvidence.operation_id,
    );
    const beginRoundEvidence = roundStore.mock.calls.find(
      call => call[0]?.evidence?.kind === 'begin_round',
    )?.[0]?.evidence;
    if (beginRoundEvidence?.kind !== 'begin_round') {
      throw new Error('missing begin-round evidence');
    }
    const beginRoundCommit = roundCommits.find(
      entry => entry.kind === 'begin_round',
    )?.commit;
    const nextRoundCommit = roundCommits.filter(
      entry => entry.kind === 'begin_round',
    )[1]?.commit;
    const batchCommit = roundCommitByOperationId.get(batchEvidence.operation_id);
    expect(beginRoundCommit).toHaveBeenCalledTimes(1);
    expect(nextRoundCommit).toHaveBeenCalledTimes(1);
    expect(completeRoundCommit).toHaveBeenCalledTimes(1);
    expect(batchCommit).toHaveBeenCalledTimes(1);
    expect(completeRoundCommit!.mock.results[0]?.value).toBe(true);
    expect(batchCommit!.mock.results[0]?.value).toBe(true);
    const completeRoundProof = completeRoundCommit!.mock.calls[0]?.[0];
    const beginRoundProof = beginRoundCommit!.mock.calls[0]?.[0];
    const nextRoundProof = nextRoundCommit!.mock.calls[0]?.[0];
    const batchProof = batchCommit!.mock.calls[0]?.[0];
    expect(committedSnapshots).toContain(completeRoundProof);
    expect(committedSnapshots).toContain(batchProof);
    expect(committedSnapshots).toContain(nextRoundProof);
    const beginSession = committedSessions.find(
      entry => entry.snapshot === beginRoundProof,
    )?.session;
    const completeSession = committedSessions.find(
      entry => entry.snapshot === completeRoundProof,
    )?.session;
    const nextRoundSession = committedSessions.find(
      entry => entry.snapshot === nextRoundProof,
    )?.session;
    expect(beginSession).toBeDefined();
    expect(completeSession).toBeDefined();
    expect(nextRoundSession).toBeDefined();
    assertSharedFixture(beginSession!, 'agent-begin-round-session.json');
    assertSharedFixture(completeSession!, 'agent-first-round-complete-session.json');
    assertSharedFixture(nextRoundSession!, 'agent-next-round-after-tool-session.json');
    expect(batchRequest.committed_checkpoint).toMatchObject({
      session_generation: completeRoundProof.generation,
      session_sha256: completeRoundProof.session_sha256,
    });
    expect(completeRoundCommit!.mock.invocationCallOrder[0]!).toBeLessThan(
      batchNative.mock.invocationCallOrder[0]!,
    );
    for (const native of [runtime.bindAgentApproval, runtime.executeAgentTool]) {
      for (const invocation of (native as jest.Mock).mock.invocationCallOrder) {
        expect(batchCommit!.mock.invocationCallOrder[0]!).toBeLessThan(invocation);
      }
    }
    // The second call is already approved, so its launch marker rides in the
    // same durable write as the first call's result.
    expect(executionStore.mock.calls).toHaveLength(1);
    expect(combinedStore.mock.calls).toHaveLength(1);
    const intentOperationIds = [
      ...executionStore.mock.calls.map(call => call[0]?.evidence?.operation_id),
      ...combinedStore.mock.calls.map(call => call[0]?.next.evidence?.operation_id),
    ];
    expect(intentOperationIds).toEqual(
      (runtime.executeAgentTool as jest.Mock).mock.calls.map(call => call[0]?.operation_id),
    );
    const receiptMarkerIds = [
      ...combinedStore.mock.calls.map(call => call[0]?.result.events[0]?.event_id),
      ...receiptStore.mock.calls.map(call => call[0]?.events[0]?.event_id),
    ];
    expect(receiptMarkerIds).toEqual(
      (runtime.executeAgentTool as jest.Mock).mock.calls.map(call => call[0]?.operation_id),
    );
    expect(persistCurrent).toHaveBeenCalled();
    const committedPersistOrders = persistCurrent.mock.invocationCallOrder;
    for (const native of [
      runtime.prepareAgentAttempt,
      runtime.completeAgentRoundV2,
      runtime.prepareAgentToolBatch,
      runtime.bindAgentApproval,
      runtime.executeAgentTool,
      runtime.finalizeAgentAttempt,
      runtime.discardAgentAttempt,
    ]) {
      for (const invocation of (native as jest.Mock).mock.invocationCallOrder) {
        expect(committedPersistOrders.some(order => order < invocation)).toBe(true);
      }
    }
    expect(store.getState().agentTranscriptCleanupOutbox).toEqual([]);
    const completedAttempt = store.getState().conversations[conversationId]?.attempts[0];
    expect(completedAttempt).toMatchObject({ status: 'completed', agent: { phase: 'final_response' } });
    expect(completedAttempt?.visibleHistorySha256).not.toBe('f'.repeat(64));
    expect(completedAttempt?.rounds.every(
      round => round.visibleHistorySha256 === 'f'.repeat(64),
    )).toBe(true);
  });

  /**
   * Byte-exact parity with the native SessionSnapshotStoreTests fixtures.
   * `RISH_UPDATE_FIXTURES=1 npx jest CompletionController` rewrites them
   * after an intentional persisted-shape change; the native suite must then
   * still validate and CAS-commit every file.
   */
  function assertSharedFixture(session: string, name: string): void {
    const file = nodePath.resolve(
      __dirname,
      '../ios/RishTests/Fixtures',
      name,
    );
    const env = process.env as Record<string, string | undefined>;
    if (env.RISH_UPDATE_FIXTURES === '1') {
      nodeFs.writeFileSync(file, `${session}\n`);
    }
    expect(`${session}\n`).toBe(nodeFs.readFileSync(file, 'utf8'));
  }

  async function captureHarnessSessions(
    harnessId: 'claude-code' | 'codex',
    model: 'claude-sonnet-5' | 'gpt-5.6',
    finalRoundIndex: number,
  ): Promise<{
    readonly sessions: ReadonlyArray<{ readonly kind: string; readonly session: string }>;
    readonly store: ChatStore;
    readonly runtime: AgentRuntimeFacadeV2;
  }> {
    const store = agentStore(model);
    const conversationId = store.getState().selectedConversationId!;
    const operations: ReturnType<typeof jest.fn>[] = [];
    const runtime = makeRuntime(operations, { finalRoundIndex });
    const roundKinds: string[] = [];
    const originalCheckpointAgentRound = store.checkpointAgentRound.bind(store);
    jest.spyOn(store, 'checkpointAgentRound').mockImplementation(input => {
      roundKinds.push(input.evidence.kind);
      return originalCheckpointAgentRound(input);
    });
    const sessions: Array<{ readonly kind: string; readonly session: string }> = [];
    const persistCurrent = jest.fn(async (): Promise<CompletionPersistenceResult> => {
      const session = store.serialize();
      const digest = sessionSnapshotSHA256(session)!;
      const generation = (store.getSessionAuthority()?.generation ?? 1) + 1;
      const snapshot = { schema_version: 1 as const, generation, session_sha256: digest };
      sessions.push({ kind: roundKinds[roundKinds.length - 1] ?? 'none', session });
      store.setSessionAuthority({ generation, sessionSha256: digest });
      return { status: 'committed', snapshot };
    });
    const opIds = [...IDS];
    const controller = createCompletionController({
      chat: store,
      persistCurrent,
      completeRoundV2: jest.fn(),
      completeRoundV3: jest.fn(),
      cancelRoundV2: jest.fn(),
      cancelRoundV3: jest.fn(),
      createRoundId: jest.fn(() => opIds.shift() ?? AGENT_TURN),
      createOperationId: jest.fn(() => opIds.shift() ?? AGENT_ATTEMPT),
      agentRuntime: runtime,
      requestAgentApproval: jest.fn(async () => ({ status: 'approved', scope: 'once' })),
      now: () => NOW,
    });
    const result = await controller.send({
      conversationId,
      text: 'write and commit',
      attachments: [],
      harnessId,
    });
    expect(result.status).toBe('completed');
    return { sessions, store, runtime };
  }

  test('persists a git_push conversation grant in the shared native fixture', async () => {
    // git_push follows the git_commit pattern: a conversation-scoped approval
    // issues a grant whose tool_family is git_push. The committed session is
    // the JS-to-native parity fixture the native SessionSnapshotStore test
    // replays (regenerate with RISH_UPDATE_FIXTURES=1 like the others).
    const store = agentStore();
    const conversationId = store.getState().selectedConversationId!;
    const runtime = makeRuntime([], {
      pushCapable: true,
      batchRounds: [[
        { callId: 'push-call', name: 'git_push', argumentsSha256: '5'.repeat(64), access: 'conversation_confirm' },
      ]],
    });
    const committedSessions: string[] = [];
    const persistCurrent = jest.fn(async (): Promise<CompletionPersistenceResult> => {
      const session = store.serialize();
      const digest = sessionSnapshotSHA256(session)!;
      const generation = (store.getSessionAuthority()?.generation ?? 1) + 1;
      committedSessions.push(session);
      store.setSessionAuthority({ generation, sessionSha256: digest });
      return { status: 'committed', snapshot: { schema_version: 1, generation, session_sha256: digest } };
    });
    const requestAgentApproval = jest.fn(async () => ({
      status: 'approved' as const,
      scope: 'conversation' as const,
    }));
    // Native binds a conversation decision by echoing the grant the controller
    // recorded at decide time; the mock reads it back from the store.
    (runtime.bindAgentApproval as jest.Mock).mockImplementation(
      async (request: BindAgentApprovalRequestV2) => {
        const conversation = store.getState().conversations[conversationId]!;
        const grant =
          (conversation.agentGrants ?? conversation.agent_grants ?? []).find(
            candidate => candidate.tool_family === 'git_push',
          ) ?? null;
        return {
          schema_version: 2 as const,
          status: 'bound' as const,
          operation_id: request.operation_id,
          task_id: request.task_id,
          attempt_id: request.attempt_id,
          round_id: request.round_id,
          call_index: request.call_index,
          call_id: request.call_id,
          decision: request.decision,
          approval_reference: request.operation_id,
          grant: request.decision === 'allow_conversation' ? grant : null,
          result_batch_revision: request.batch_revision,
          observed_checkpoint: request.committed_checkpoint,
        };
      },
    );
    const opIds = [...IDS];
    const controller = createCompletionController({
      chat: store,
      persistCurrent,
      completeRoundV2: jest.fn(),
      completeRoundV3: jest.fn(),
      cancelRoundV2: jest.fn(),
      cancelRoundV3: jest.fn(),
      createRoundId: jest.fn(() => opIds.shift() ?? AGENT_TURN),
      createOperationId: jest.fn(() => opIds.shift() ?? AGENT_ATTEMPT),
      agentRuntime: runtime,
      requestAgentApproval,
      now: () => NOW,
    });
    const result = await controller.send({ conversationId, text: 'push it', attachments: [] });
    expect(result.status).toBe('completed');
    expect(requestAgentApproval).toHaveBeenCalledTimes(1);
    expect(runtime.bindAgentApproval).toHaveBeenCalledWith(expect.objectContaining({
      call_id: 'push-call',
      decision: 'allow_conversation',
      token: expect.objectContaining({ name: 'git_push', access: 'conversation_confirm' }),
    }));
    expect(runtime.executeAgentTool).toHaveBeenCalledWith(expect.objectContaining({
      name: 'git_push',
      call_id: 'push-call',
    }));
    // The last mid-flow session that still carries the bound git_push call:
    // it holds both the conversation grant and the allow_conversation decision.
    const session = [...committedSessions]
      .reverse()
      .find(candidate => /"approval_decision":\s*"allow_conversation"/u.test(candidate));
    expect(session).toBeDefined();
    expect(session).toMatch(/"tool_family":\s*"git_push"/u);
    expect(session).toMatch(/"name":\s*"git_push"/u);
    expect(committedSessions[committedSessions.length - 1]).toMatch(/"tool_family":\s*"git_push"/u);
    assertSharedFixture(session!, 'agent-git-push-conversation-session.json');
  });

  async function runtimeConversationGrantFlow(forgedReference = false) {
    const store = agentStore();
    const conversationId = store.getState().selectedConversationId!;
    const runtime = makeRuntime([], {
      runtimeCapable: true,
      getConversationGrants: () => store.getState().conversations[conversationId]?.agentGrants ?? [],
      batchRounds: [
        [{ callId: 'install-runtime', name: 'install_runtime_environment', argumentsSha256: '4'.repeat(64), access: 'conversation_confirm' }],
        [{ callId: 'run-runtime', name: 'run_program', argumentsSha256: '5'.repeat(64), access: 'conversation_confirm' }],
        [{ callId: 'start-runtime', name: 'start_runtime_service', argumentsSha256: '6'.repeat(64), access: 'conversation_confirm' }],
      ],
      finalRoundIndex: 3,
    });
    if (forgedReference) {
      const prepare = (runtime.prepareAgentToolBatch as jest.Mock).getMockImplementation()!;
      (runtime.prepareAgentToolBatch as jest.Mock).mockImplementation(async (request: PrepareAgentToolBatchRequestV2) => {
        const result = await prepare(request) as PrepareAgentToolBatchResultV2;
        if (request.round_index !== 1 || result.status !== 'prepared') return result;
        return {
          ...result,
          receipt: {
            ...result.receipt,
            calls: result.receipt.calls.map(call => ({
              ...call,
              approval_reference: 'ffffffff-ffff-4fff-8fff-ffffffffffff',
            })),
          },
        };
      });
    }
    const sessions: string[] = [];
    const persist = committedPersistence(store);
    const persistCurrent = jest.fn(async () => {
      sessions.push(store.serialize());
      return persist();
    });
    const requestAgentApproval = jest.fn(async () => ({
      status: 'approved' as const, scope: 'conversation' as const,
    }));
    const operationIds = [
      ...IDS,
      ...Array.from({ length: 80 }, (_, index) =>
        `00000000-0000-4000-8000-${(index + 1).toString(16).padStart(12, '0')}`),
    ];
    const controller = createCompletionController({
      chat: store, persistCurrent, agentRuntime: runtime, requestAgentApproval,
      completeRoundV2: jest.fn(), completeRoundV3: jest.fn(),
      cancelRoundV2: jest.fn(), cancelRoundV3: jest.fn(),
      createRoundId: jest.fn(() => operationIds.shift() ?? AGENT_TURN),
      createOperationId: jest.fn(() => operationIds.shift() ?? AGENT_ATTEMPT),
      now: () => NOW,
    });
    const beginExecution = jest.spyOn(store, 'checkpointAgentBatchAndBeginFirst');
    const result = await controller.send({
      conversationId, text: 'install Node, run it, then start its service', attachments: [],
    });
    return { store, conversationId, runtime, sessions, requestAgentApproval, beginExecution, result };
  }

  test('reuses an install conversation grant for native-bound run and service rounds and persists it', async () => {
    const flow = await runtimeConversationGrantFlow();
    expect(flow.result).toMatchObject({ status: 'completed' });
    expect(flow.requestAgentApproval).toHaveBeenCalledTimes(1);
    expect(flow.runtime.bindAgentApproval).toHaveBeenCalledTimes(1);
    expect(flow.runtime.bindAgentApproval).toHaveBeenCalledWith(expect.objectContaining({
      call_id: 'install-runtime', decision: 'allow_conversation',
      token: expect.objectContaining({ registry_version: 3 }),
    }));
    const grants = flow.store.getState().conversations[flow.conversationId]!.agentGrants!;
    expect(grants).toHaveLength(1);
    const grant = grants[0]!;
    expect(grant).toMatchObject({ tool_family: 'guest_service', registry_version: 3 });
    const executions = (flow.runtime.executeAgentTool as jest.Mock).mock.calls.map(call => call[0] as ExecuteAgentToolRequestV2);
    expect(executions.map(call => call.name)).toEqual([
      'install_runtime_environment', 'run_program', 'start_runtime_service',
    ]);
    expect(executions.slice(1).map(call => call.approval_reference)).toEqual([grant.grant_id, grant.grant_id]);
    expect(flow.beginExecution.mock.results.filter(result => result.value !== null)).toHaveLength(2);
    const prepared = await Promise.all((flow.runtime.prepareAgentToolBatch as jest.Mock).mock.results.map(result => result.value));
    expect(prepared.slice(1).map(result => result.receipt.calls[0])).toEqual([
      expect.objectContaining({ call_id: 'run-runtime', approval_state: 'bound', approval_token: null, approval_reference: grant.grant_id }),
      expect.objectContaining({ call_id: 'start-runtime', approval_state: 'bound', approval_token: null, approval_reference: grant.grant_id }),
    ]);
    for (const callId of ['run-runtime', 'start-runtime']) {
      const boundSessions = flow.sessions.filter(session => {
        const saved = JSON.parse(session);
        return saved.conversations.some((conversation: any) => conversation.attempts.some((attempt: any) =>
          attempt.agent?.batch.some((call: any) => call.call_id === callId && call.approval_reference === grant.grant_id)));
      });
      expect(boundSessions.length).toBeGreaterThan(0);
      for (const session of boundSessions) {
        const restored = hydrateChatState(session).conversations[flow.conversationId]!;
        expect(restored.agentGrants).toEqual(grants);
        const call = restored.attempts[0]!.agent!.batch.find(candidate => candidate.call_id === callId)!;
        expect(call).toMatchObject({ approval_token: null, approval_reference: grant.grant_id });
        expect(call.approval_decision).not.toBe('pending');
      }
    }
    const hydrated = createChatStore({ initialState: hydrateChatState(flow.store.serialize()) });
    expect(hydrated.getState().conversations[flow.conversationId]).toMatchObject({
      agentGrants: grants, attempts: [expect.objectContaining({ status: 'completed' })],
    });
  });

  test('reuses a persisted runtime conversation grant on the first batch of a new attempt', async () => {
    const previous = await runtimeConversationGrantFlow();
    expect(previous.result.status).toBe('completed');
    const conversationId = previous.conversationId;
    const grant = previous.store.getState().conversations[conversationId]!.agentGrants![0]!;
    let sequence = 200;
    const nextId = () => `00000000-0000-4000-8000-${(++sequence).toString(16).padStart(12, '0')}`;
    const store = createChatStore({
      initialState: hydrateChatState(previous.store.serialize()),
      sessionAuthority: previous.store.getSessionAuthority()!,
      now: () => LATER, createId: nextId, createLifecycleId: nextId,
    });
    const runtime = makeRuntime([], {
      runtimeCapable: true,
      getConversationGrants: () => store.getState().conversations[conversationId]!.agentGrants ?? [],
      responseOffset: 20,
      transcriptRef: '77777777-7777-4777-8777-777777777777',
      batchRounds: [
        [{ callId: 'run-again', name: 'run_program', argumentsSha256: '7'.repeat(64), access: 'conversation_confirm' }],
        [{ callId: 'start-again', name: 'start_runtime_service', argumentsSha256: '8'.repeat(64), access: 'conversation_confirm' }],
      ],
      finalRoundIndex: 2,
    });
    const requestAgentApproval = jest.fn();
    const controller = agentController(
      store, runtime, committedPersistence(store), Array.from({ length: 80 }, nextId), requestAgentApproval, () => LATER,
    );
    const result = await controller.send({ conversationId, text: 'run and start again', attachments: [] });
    expect(result.status).toBe('completed');
    const preparation = await (runtime.prepareAgentAttempt as jest.Mock).mock.results[0]!.value;
    expect(preparation.attempt.frozen_grant_ids).toEqual([]);
    expect(preparation.attempt.attempt_id).not.toBe(grant.issued_for.attempt_id);
    expect(requestAgentApproval).not.toHaveBeenCalled();
    expect(runtime.bindAgentApproval).not.toHaveBeenCalled();
    expect((runtime.executeAgentTool as jest.Mock).mock.calls.map(call => [call[0].name, call[0].approval_reference])).toEqual([
      ['run_program', grant.grant_id], ['start_runtime_service', grant.grant_id],
    ]);
    const restored = hydrateChatState(store.serialize()).conversations[conversationId]!;
    expect(restored.agentGrants).toEqual([grant]);
    expect(restored.attempts).toHaveLength(2);
    expect(restored.attempts.every(attempt => attempt.status === 'completed')).toBe(true);
  });

  test('recovers a committed grant-bound batch when its reply was lost before the JS checkpoint', async () => {
    const previous = await runtimeConversationGrantFlow();
    expect(previous.result.status).toBe('completed');
    const conversationId = previous.conversationId;
    const grant = previous.store.getState().conversations[conversationId]!.agentGrants![0]!;
    let sequence = 500;
    const nextId = () => `00000000-0000-4000-8000-${(++sequence).toString(16).padStart(12, '0')}`;
    const store = createChatStore({ initialState: hydrateChatState(previous.store.serialize()),
      sessionAuthority: previous.store.getSessionAuthority()!, now: () => LATER, createId: nextId, createLifecycleId: nextId });
    const runtime = makeRuntime([], { runtimeCapable: true,
      getConversationGrants: () => store.getState().conversations[conversationId]!.agentGrants ?? [],
      responseOffset: 40, transcriptRef: '66666666-6666-4666-8666-666666666666',
      batchRounds: [[{ callId: 'lost-reply-run', name: 'run_program', argumentsSha256: '8'.repeat(64), access: 'conversation_confirm' }]], finalRoundIndex: 1 });
    const wal: { batch: AgentBatchReceiptV2 | null } = { batch: null };
    const prepare = (runtime.prepareAgentToolBatch as jest.Mock).getMockImplementation()!;
    (runtime.prepareAgentToolBatch as jest.Mock).mockImplementationOnce(async request => {
      const result = await prepare(request) as PrepareAgentToolBatchResultV2;
      if (result.status !== 'prepared') throw new Error('expected prepared WAL batch');
      wal.batch = result.receipt;
      throw { code: 'E_AGENT_PERSISTENCE' };
    });
    const approvals = jest.fn();
    const controller = agentController(store, runtime, committedPersistence(store), Array.from({ length: 100 }, nextId), approvals, () => LATER);
    expect(await controller.send({ conversationId, text: 'run after an uncertain prepare reply', attachments: [] })).toMatchObject({ status: 'retryable', code: 'E_AGENT_PERSISTENCE' });
    expect(controller.getState().phase).toBe('resume_available');
    const current = store.getState().conversations[conversationId]!.attempts[1]!;
    const journal = current.agent!;
    expect(journal.frozen_grant_ids).toEqual([]); expect(journal.batch).toEqual([]);
    expect(wal.batch?.calls[0]).toMatchObject({ approval_state: 'bound', approval_token: null, approval_reference: grant.grant_id });
    const prepared = await (runtime.prepareAgentAttempt as jest.Mock).mock.results[0]!.value;
    const provider = await (runtime.completeAgentRoundV2 as jest.Mock).mock.results[0]!.value as CompleteAgentRoundResultV2;
    if (provider.status !== 'completed' || provider.outcome.kind !== 'tool_batch' || wal.batch === null) throw new Error('missing native proof');
    const roundOutcome = provider.outcome;
    let recoveredCompletion = roundOutcome.completion_receipt;
    let recoveredCalls = roundOutcome.calls;
    let projection: AgentAttemptProjectionV2 = { ...prepared.attempt, phase: 'batch_frozen',
      controller_generation: journal.controller_generation, journal_revision: current.journalRevision!,
      transcript: wal.batch.transcript, round_index: 0, round_id: wal.batch.round_id,
      round_revision: provider.result_round_revision, round_status: 'completed', batch_kind: wal.batch.batch_kind,
      batch_revision: wal.batch.batch_revision, manifest_sha256: wal.batch.manifest_sha256,
      call_index: 0, batch: wal.batch.calls, frozen_grant_ids: [], reserved_write_bytes: wal.batch.reserved_write_bytes };
    (runtime.queryAgentAttempt as jest.Mock).mockImplementation(async () => ({ schema_version: 2, status: 'active', attempt: projection }));
    (runtime.recoverAgentAttempt as jest.Mock).mockImplementation(async request => ({ schema_version: 2, status: 'resumed',
      operation_id: request.operation_id, next_action: 'persist_batch', attempt: projection,
      completed_round: { schema_version: 2, kind: 'tool_batch', task_id: current.turnId, attempt_id: current.attemptId,
        round_id: projection.round_id, round_index: 0, launch_attempt: 1, result_round_revision: provider.result_round_revision,
        transcript: wal.batch!.transcript, completion_receipt: recoveredCompletion,
        text: '', reasoning: '', assistant_text_sha256: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        reasoning_text_sha256: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        calls: recoveredCalls, batch_class: 'executable', executable_call_count: 1, denied_call_count: 0 } }));
    expect((await controller.resume(conversationId, current.attemptId)).status).toBe('retryable');
    expect(runtime.executeAgentTool).not.toHaveBeenCalled();
    expect(store.getState().conversations[conversationId]!.attempts[1]!.agent?.frozen_grant_ids).toEqual([]);
    // The repaired native query derives this reference from committed WAL and the matching live grant.
    projection = { ...projection, frozen_grant_ids: [grant.grant_id] };
    recoveredCompletion = { ...roundOutcome.completion_receipt, provider_response_id: 'changed-recovered-response' };
    expect((await controller.resume(conversationId, current.attemptId)).status).toBe('retryable');
    expect(runtime.executeAgentTool).not.toHaveBeenCalled();
    recoveredCompletion = roundOutcome.completion_receipt;
    recoveredCalls = roundOutcome.calls.map(call => ({ ...call, arguments_sha256: '9'.repeat(64) }));
    expect((await controller.resume(conversationId, current.attemptId)).status).toBe('retryable');
    expect(runtime.executeAgentTool).not.toHaveBeenCalled();
    recoveredCalls = roundOutcome.calls;
    const verifiedProjection = projection;
    const forgedGrantId = 'ffffffff-ffff-4fff-8fff-ffffffffffff';
    projection = { ...projection, frozen_grant_ids: [forgedGrantId], batch: projection.batch.map(call => ({ ...call, approval_reference: forgedGrantId })) };
    expect((await controller.resume(conversationId, current.attemptId)).status).toBe('retryable');
    expect(runtime.executeAgentTool).not.toHaveBeenCalled();
    projection = verifiedProjection;
    const resumed = await controller.resume(conversationId, current.attemptId);
    expect(resumed.status).toBe('completed');
    expect(runtime.prepareAgentToolBatch).toHaveBeenCalledTimes(1);
    expect(runtime.executeAgentTool).toHaveBeenCalledTimes(1);
    expect(approvals).not.toHaveBeenCalled();
    const restoredAttempt = hydrateChatState(store.serialize()).conversations[conversationId]!.attempts[1]!;
    expect(restoredAttempt.status).toBe('completed');
    expect(restoredAttempt.rounds).toHaveLength(2);
    expect(new Set(restoredAttempt.rounds.map(round => round.roundId)).size).toBe(2);
  });

  test('does not execute a native-bound runtime call whose reference is a forged grant ID', async () => {
    const flow = await runtimeConversationGrantFlow(true);
    expect(flow.result).toMatchObject({ status: 'retryable', code: 'E_AGENT_CONFLICT' });
    expect(flow.requestAgentApproval).toHaveBeenCalledTimes(1);
    expect((flow.runtime.executeAgentTool as jest.Mock).mock.calls.map(call => call[0].name)).toEqual([
      'install_runtime_environment',
    ]);
    expect(flow.runtime.completeAgentRoundV2).toHaveBeenCalledTimes(2);
  });

  test.each(['revoked', 'wrong tool family', 'wrong workspace binding', 'wrong root fingerprint', 'wrong registry', 'wrong policy'] as const)(
    'rejects a persisted runtime grant-bound call with a %s grant before recovery can execute',
    async corruption => {
      const flow = await runtimeConversationGrantFlow();
      expect(flow.result.status).toBe('completed');
      const grant = flow.store.getState().conversations[flow.conversationId]!.agentGrants![0]!;
      const session = flow.sessions.find(candidate => {
        const saved = JSON.parse(candidate);
        return saved.conversations.some((conversation: any) => conversation.attempts.some((attempt: any) =>
          attempt.agent?.batch.some((call: any) => call.call_id === 'run-runtime' && call.approval_reference === grant.grant_id)));
      });
      expect(session).toBeDefined();
      const saved = JSON.parse(session!);
      const conversation = saved.conversations.find((candidate: any) => candidate.id === flow.conversationId);
      expect(conversation.agent_grants).toHaveLength(1);
      if (corruption === 'revoked') conversation.agent_grants = [];
      if (corruption === 'wrong tool family') conversation.agent_grants[0].tool_family = 'file_write';
      if (corruption === 'wrong workspace binding') conversation.agent_grants[0].binding_revision += 1;
      if (corruption === 'wrong root fingerprint') conversation.agent_grants[0].root_fingerprint_sha256 = 'f'.repeat(64);
      if (corruption === 'wrong registry') conversation.agent_grants[0].registry_version = 2;
      if (corruption === 'wrong policy') conversation.agent_grants[0].policy_version = 'agent-v2';
      const restartedRuntime = makeRuntime([], { runtimeCapable: true });
      expect(() => {
        const restored = createChatStore({ initialState: hydrateChatState(JSON.stringify(saved)) });
        agentController(restored, restartedRuntime, committedPersistence(restored)).reconcileHydrated(flow.conversationId);
      }).toThrow();
      expect(restartedRuntime.queryAgentAttempt).not.toHaveBeenCalled();
      expect(restartedRuntime.recoverAgentAttempt).not.toHaveBeenCalled();
      expect(restartedRuntime.executeAgentTool).not.toHaveBeenCalled();
    },
  );

  test('serializes Claude Code and Codex Agent sessions into the shared native fixtures', async () => {
    const claude = await captureHarnessSessions('claude-code', 'claude-sonnet-5', 1);
    expect(claude.runtime.completeAgentRoundV2).toHaveBeenCalledTimes(2);
    const claudeRequests = (claude.runtime.completeAgentRoundV2 as jest.Mock).mock.calls.map(
      call => call[0] as CompleteAgentRoundRequestV2,
    );
    expect(claudeRequests.map(request => [request.harness_id, request.model, request.transport_schema_version])).toEqual([
      ['claude-code', 'claude-sonnet-5', 3],
      ['claude-code', 'claude-sonnet-5', 3],
    ]);
    const claudeAttempt = claude.store.getState().conversations[
      claude.store.getState().selectedConversationId!
    ]!.attempts[0]!;
    expect(claudeAttempt.harnessId).toBe('claude-code');
    expect(claudeAttempt.rounds.map(round => round.harnessId)).toEqual(['claude-code', 'claude-code']);
    // The second begin_round commit is the session after the write tool
    // round settled and before the final round started.
    const claudeToolRound = claude.sessions.filter(entry => entry.kind === 'begin_round')[1];
    expect(claudeToolRound).toBeDefined();
    assertSharedFixture(claudeToolRound!.session, 'claude-code-tool-round-session.json');

    const codex = await captureHarnessSessions('codex', 'gpt-5.6', 0);
    expect(codex.runtime.completeAgentRoundV2).toHaveBeenCalledTimes(1);
    const codexRequest = (codex.runtime.completeAgentRoundV2 as jest.Mock).mock.calls[0]?.[0] as CompleteAgentRoundRequestV2;
    expect([codexRequest.harness_id, codexRequest.model]).toEqual(['codex', 'gpt-5.6']);
    const codexAttempt = codex.store.getState().conversations[
      codex.store.getState().selectedConversationId!
    ]!.attempts[0]!;
    expect(codexAttempt).toMatchObject({ status: 'completed', harnessId: 'codex' });
    expect(codexAttempt.rounds.map(round => round.harnessId)).toEqual(['codex']);
    // The final persisted session carries the completed single-round attempt
    // with its Codex receipt and final assistant message.
    const codexComplete = codex.sessions[codex.sessions.length - 1];
    expect(codexComplete).toBeDefined();
    assertSharedFixture(codexComplete!.session, 'codex-round-session.json');
  });

  test('hydrates a pre-harness Agent session as DSH', () => {
    const legacy = nodeFs.readFileSync(
      nodePath.resolve(__dirname, '../ios/RishTests/Fixtures/legacy-pre-harness-session.json'),
      'utf8',
    );
    expect(legacy.includes('"harness_id"')).toBe(false);
    const store = createChatStore({ now: () => NOW });
    const hydrated = store.hydrate(legacy);
    const conversation = Object.values(hydrated.conversations)[0]!;
    expect(conversation.attempts[0]?.harnessId).toBe('dsh');
    expect(conversation.attempts[0]?.rounds.every(round => round.harnessId === 'dsh')).toBe(true);
  });

  test('keeps rejected round diagnostics in memory and clears them on recovery', async () => {
    const store = agentStore();
    const conversationId = store.getState().selectedConversationId!;
    const runtime = makeRuntime([]);
    const diagnostic = 'agent_runtime/v1 operation=complete_agent_round_v2 kind=exception';
    (runtime.completeAgentRoundV2 as jest.Mock).mockRejectedValueOnce({
      code: 'E_AGENT_PERSISTENCE', message: `E_AGENT_PERSISTENCE\n${diagnostic}`,
    });
    const controller = agentController(store, runtime, committedPersistence(store));
    const result = await controller.send({ conversationId, text: 'test', attachments: [] });
    expect(result).toMatchObject({ status: 'retryable', code: 'E_AGENT_PERSISTENCE' });
    expect(controller.getState()).toMatchObject({
      phase: 'resume_available', failureCode: 'E_AGENT_PERSISTENCE',
      failureDiagnostic: diagnostic,
    });
    expect(store.serialize()).not.toContain('agent_runtime/v1');
    const attemptId = controller.getState().attemptId!;
    (runtime.queryAgentAttempt as jest.Mock).mockRejectedValueOnce({ code: 'E_AGENT_CONFLICT' });
    await controller.retry(conversationId, attemptId);
    expect(controller.getState().failureDiagnostic).toBeUndefined();
    expect(store.serialize()).not.toContain('agent_runtime/v1');
  });

  test('keeps a rejected Agent batch recoverable with its native failure code', async () => {
    const store = agentStore();
    const conversationId = store.getState().selectedConversationId!;
    const runtime = makeRuntime([]);
    const requestAgentApproval = jest.fn(async () => ({
      status: 'approved' as const,
      scope: 'once' as const,
    }));
    (runtime.prepareAgentToolBatch as jest.Mock).mockImplementationOnce(
      async (request: PrepareAgentToolBatchRequestV2): Promise<PrepareAgentToolBatchResultV2> => ({
        schema_version: 2,
        status: 'rejected',
        operation_id: request.operation_id,
        failure_code: 'E_AGENT_CONFLICT',
        expected_batch_revision: request.expected_batch_revision,
        expected_reserved_write_bytes: request.expected_reserved_write_bytes,
        result_reserved_write_bytes: request.expected_reserved_write_bytes,
        effect_gate: 'closed',
        reservation_status: 'unchanged',
        effect_dispatched: false,
        retry_advice: 'requery',
      }),
    );
    (runtime.queryAgentAttempt as jest.Mock).mockResolvedValue({
      schema_version: 2,
      status: 'not_found',
      failure_code: 'E_AGENT_NOT_FOUND',
    } satisfies QueryAgentAttemptResultV2);
    const failAttempt = jest.spyOn(store, 'failAttempt');
    const controller = agentController(
      store,
      runtime,
      committedPersistence(store),
      [...IDS],
      requestAgentApproval,
    );

    const result = await controller.send({
      conversationId,
      text: 'write an existing file',
      attachments: [],
    });

    expect(result).toMatchObject({ status: 'retryable', code: 'E_AGENT_CONFLICT' });
    expect(controller.getState()).toMatchObject({
      phase: 'resume_available',
      conversationId,
      failureCode: 'E_AGENT_CONFLICT',
    });
    expect(failAttempt).not.toHaveBeenCalled();
    expect(requestAgentApproval).not.toHaveBeenCalled();
    expect(runtime.bindAgentApproval).not.toHaveBeenCalled();
    expect(runtime.executeAgentTool).not.toHaveBeenCalled();
    expect(store.getState().conversations[conversationId]?.attempts[0]).toMatchObject({
      status: 'prepared',
      failureCode: null,
      agent: { phase: 'batch_frozen' },
    });
    const resumed = await controller.resume(
      conversationId,
      result.attemptId!,
    );
    expect(resumed).toMatchObject({ status: 'retryable', code: 'E_COMPLETION_HISTORY' });
    expect(runtime.queryAgentAttempt).toHaveBeenCalledTimes(1);
  });

  test('carries the persisted batch authority into a second write batch', async () => {
    const store = agentStore();
    const conversationId = store.getState().selectedConversationId!;
    const operations: ReturnType<typeof jest.fn>[] = [];
    const secondBatch: readonly AgentRuntimeFixtureCall[] = [
      { callId: 'write-call-2', name: 'write_file', argumentsSha256: '6'.repeat(64), access: 'conversation_confirm' },
    ];
    const runtime = makeRuntime(operations, {
      batchRounds: [defaultBatchCalls, secondBatch],
      finalRoundIndex: 2,
    });
    const persistCurrent = committedPersistence(store);
    const additionalOperationIds = Array.from({ length: 40 }, (_, index) => {
      const suffix = (index + 1).toString(16).padStart(12, '0');
      return `${suffix.slice(0, 8)}-${suffix.slice(0, 4)}-4${suffix.slice(0, 3)}-8${suffix.slice(0, 3)}-${suffix}`;
    });
    const controller = agentController(store, runtime, persistCurrent, [...IDS, ...additionalOperationIds]);

    const result = await controller.send({ conversationId, text: 'two write batches', attachments: [] });
    expect(result.status).toBe('completed');
    expect(runtime.completeAgentRoundV2).toHaveBeenCalledTimes(3);
    expect(runtime.prepareAgentToolBatch).toHaveBeenCalledTimes(2);
    expect(runtime.executeAgentTool).toHaveBeenCalledTimes(3);
    const batchRequests = (runtime.prepareAgentToolBatch as jest.Mock).mock.calls.map(call => call[0]);
    expect(batchRequests.map(request => request.expected_batch_revision)).toEqual([0, 1]);
    expect(batchRequests.every(request => request.expected_batch_revision >= 0)).toBe(true);
    const batchResults = await Promise.all(
      (runtime.prepareAgentToolBatch as jest.Mock).mock.results.map(resultValue => resultValue.value),
    );
    const executeRequests = (runtime.executeAgentTool as jest.Mock).mock.calls.map(call => call[0]);
    expect(executeRequests.map(request => request.expected_batch_revision)).toEqual([1, 1, 2]);
    expect(executeRequests.every(request => request.manifest_sha256 === MANIFEST_SHA)).toBe(true);
    expect(batchResults.map(resultValue => resultValue.receipt.batch_revision)).toEqual([1, 2]);
  });

  test('accepts opaque native batch revisions across read-read-write-read-write rounds', async () => {
    const store = agentStore();
    const conversationId = store.getState().selectedConversationId!;
    const batchRounds: readonly (readonly AgentRuntimeFixtureCall[])[] = [
      [{callId: 'read-0', name: 'read_file', argumentsSha256: '1'.repeat(64), access: 'auto'}],
      [{callId: 'read-1', name: 'read_file', argumentsSha256: '2'.repeat(64), access: 'auto'}],
      [{callId: 'write-2', name: 'write_file', argumentsSha256: '3'.repeat(64), access: 'conversation_confirm'}],
      [{callId: 'read-3', name: 'read_file', argumentsSha256: '4'.repeat(64), access: 'auto'}],
      [{callId: 'write-4', name: 'write_file', argumentsSha256: '5'.repeat(64), access: 'conversation_confirm'}],
    ];
    const runtime = makeRuntime([], {batchRounds, finalRoundIndex: 5, completedRoundRevision: 3});
    const ids = Array.from({length: 128}, (_, index) => `00000000-0000-4000-8000-${(index + 1).toString(16).padStart(12, '0')}`);
    const controller = agentController(store, runtime, committedPersistence(store), [...IDS, ...ids]);
    const result = await controller.send({conversationId, text: 'read then write repeatedly', attachments: []});
    expect(result.status).toBe('completed');
    const prepares = (runtime.prepareAgentToolBatch as jest.Mock).mock.calls.map(call => call[0]);
    expect(prepares.map(request => request.expected_batch_revision)).toEqual([0, 3, 3, 1, 3]);
    const executions = (runtime.executeAgentTool as jest.Mock).mock.calls.map(call => call[0]);
    expect(executions.map(request => request.expected_batch_revision)).toEqual([3, 3, 1, 3, 2]);
    expect(runtime.completeAgentRoundV2).toHaveBeenCalledTimes(6);
  });

  test('an auto batch persists one checkpoint per finished call instead of three', async () => {
    const store = agentStore();
    const conversationId = store.getState().selectedConversationId!;
    const runtime = makeRuntime([], {
      batchRounds: [[
        { callId: 'read-a', name: 'read_file', argumentsSha256: '5'.repeat(64), access: 'auto' },
        { callId: 'read-b', name: 'read_file', argumentsSha256: '6'.repeat(64), access: 'auto' },
        { callId: 'read-c', name: 'read_file', argumentsSha256: '7'.repeat(64), access: 'auto' },
      ]],
      finalRoundIndex: 1,
    });
    const persistCurrent = committedPersistence(store);
    const intentStore = jest.spyOn(store, 'insertAgentExecutionIntent');
    const combinedStore = jest.spyOn(store, 'recordAgentToolResultAndBeginNext');
    const advanceStore = jest.spyOn(store, 'advanceAgentCall');
    const receiptStore = jest.spyOn(store, 'recordAgentToolResult');
    const controller = agentController(store, runtime, persistCurrent, [...IDS, ...Array.from({ length: 30 }, (_, index) => {
      const suffix = (index + 1).toString(16).padStart(12, '0');
      return `${suffix.slice(0, 8)}-${suffix.slice(0, 4)}-4${suffix.slice(0, 3)}-8${suffix.slice(0, 3)}-${suffix}`;
    })]);

    const result = await controller.send({ conversationId, text: 'read three files', attachments: [] });

    expect(result.status).toBe('completed');
    expect(runtime.executeAgentTool).toHaveBeenCalledTimes(3);
    expect((runtime.executeAgentTool as jest.Mock).mock.calls.map(call => call[0].call_id)).toEqual(['read-a', 'read-b', 'read-c']);
    // The first launch marker rides with the batch receipt, then
    // result+advance+next-intent twice, then the last result on its own: no
    // stand-alone intent and no cursor-only write at all.
    const batchStore = jest.spyOn(store, 'checkpointAgentBatchAndBeginFirst');
    expect(intentStore).not.toHaveBeenCalled();
    expect(combinedStore).toHaveBeenCalledTimes(2);
    expect(receiptStore).toHaveBeenCalledTimes(1);
    expect(advanceStore).not.toHaveBeenCalled();
    batchStore.mockRestore();
    // Every native execution ran against the checkpoint that made its own
    // launch marker durable: the combined write's proof is the next request's
    // committed_checkpoint.
    const executeRequests = (runtime.executeAgentTool as jest.Mock).mock.calls.map(call => call[0]);
    const combinedTransactions = combinedStore.mock.results.map(entry => entry.value);
    expect(combinedTransactions.every(transaction => transaction !== null)).toBe(true);
    expect(executeRequests[1].committed_checkpoint.journal_revision).toBe(executeRequests[0].committed_checkpoint.journal_revision + 3);
    expect(executeRequests[2].committed_checkpoint.journal_revision).toBe(executeRequests[1].committed_checkpoint.journal_revision + 3);
    const attempt = store.getState().conversations[conversationId]!.attempts[0]!;
    expect(attempt.status).toBe('completed');
    expect(attempt.assistantMessageId).not.toBeNull();
    // Compared with separate batch/intent/result/advance writes the turn
    // saves five whole-session persists (16 before).
    expect(persistCurrent).toHaveBeenCalledTimes(11);
  });

  test('a batch refused for its arguments settles as failed feedback and the next round runs', async () => {
    const store = agentStore();
    const conversationId = store.getState().selectedConversationId!;
    const runtime = makeRuntime([], {
      batchRounds: [
        [
          { callId: 'read-abs', name: 'read_file', argumentsSha256: '5'.repeat(64), access: 'auto' },
          { callId: 'write-abs', name: 'write_file', argumentsSha256: '6'.repeat(64), access: 'conversation_confirm' },
        ],
        [
          { callId: 'read-rel', name: 'read_file', argumentsSha256: '7'.repeat(64), access: 'auto' },
        ],
      ],
      refusedRounds: [0],
      finalRoundIndex: 2,
    });
    const persistCurrent = committedPersistence(store);
    const requestAgentApproval = jest.fn(async () => ({ status: 'approved' as const, scope: 'once' as const }));
    const controller = agentController(store, runtime, persistCurrent, [...IDS, ...Array.from({ length: 30 }, (_, index) => {
      const suffix = (index + 1).toString(16).padStart(12, '0');
      return `${suffix.slice(0, 8)}-${suffix.slice(0, 4)}-4${suffix.slice(0, 3)}-8${suffix.slice(0, 3)}-${suffix}`;
    })], requestAgentApproval);

    const result = await controller.send({ conversationId, text: 'start with an absolute path', attachments: [] });

    expect([result.status, result.code, controller.getState().phase, controller.getState().failureCode]).toEqual(['completed', null, 'idle', null]);
    // Round 0's batch never executed or asked for approval; round 1 ran its
    // corrected call; round 2 answered.
    expect(runtime.completeAgentRoundV2).toHaveBeenCalledTimes(3);
    expect(requestAgentApproval).not.toHaveBeenCalled();
    expect(runtime.bindAgentApproval).not.toHaveBeenCalled();
    expect((runtime.executeAgentTool as jest.Mock).mock.calls.map(call => call[0].call_id)).toEqual(['read-rel']);
    const events = store.getState().sessionEvents ?? [];
    const refusedResults = events.filter(event => event.kind === 'tool_result' && event.round_index === 0);
    expect(refusedResults.map(event => [event.call_id, event.status, event.failure_code])).toEqual([
      ['read-abs', 'failed', 'E_AGENT_BAD_PATH'],
      ['write-abs', 'failed', 'E_AGENT_BAD_PATH'],
    ]);
    const attempt = store.getState().conversations[conversationId]!.attempts[0]!;
    expect(attempt.status).toBe('completed');
    expect(attempt.rounds.map(round => round.roundIndex)).toEqual([0, 1, 2]);
  });

  test('uses batch authority for a mixed auto and write batch', async () => {
    const store = agentStore();
    const conversationId = store.getState().selectedConversationId!;
    const runtime = makeRuntime([], {
      batchRounds: [[
        { callId: 'read-call', name: 'read_file', argumentsSha256: '8'.repeat(64), access: 'auto' },
        { callId: 'write-call-mixed', name: 'write_file', argumentsSha256: '9'.repeat(64), access: 'conversation_confirm' },
      ]],
      finalRoundIndex: 1,
    });
    const persistCurrent = committedPersistence(store);
    const controller = agentController(store, runtime, persistCurrent, [...IDS, ...Array.from({ length: 30 }, (_, index) => {
      const suffix = (index + 1).toString(16).padStart(12, '0');
      return `${suffix.slice(0, 8)}-${suffix.slice(0, 4)}-4${suffix.slice(0, 3)}-8${suffix.slice(0, 3)}-${suffix}`;
    })]);

    const result = await controller.send({ conversationId, text: 'read then write', attachments: [] });

    expect(result.status).toBe('completed');
    expect(runtime.prepareAgentToolBatch).toHaveBeenCalledTimes(1);
    expect(runtime.bindAgentApproval).toHaveBeenCalledTimes(1);
    expect(runtime.executeAgentTool).toHaveBeenCalledTimes(2);
    expect((runtime.prepareAgentToolBatch as jest.Mock).mock.calls[0]?.[0].expected_batch_revision).toBe(0);
    expect((runtime.executeAgentTool as jest.Mock).mock.calls.every(call => call[0].expected_batch_revision === 1)).toBe(true);
    expect((runtime.executeAgentTool as jest.Mock).mock.calls[0]?.[0].name).toBe('read_file');
    expect((runtime.executeAgentTool as jest.Mock).mock.calls[1]?.[0].name).toBe('write_file');
  });

  test('keeps durable-deny calls terminal without executing them', async () => {
    const store = agentStore();
    const conversationId = store.getState().selectedConversationId!;
    const runtime = makeRuntime([], {
      batchRounds: [[
        { callId: 'unknown-call', name: 'unknown_tool', argumentsSha256: 'b'.repeat(64), access: 'durable_deny' },
        { callId: 'read-call-deny', name: 'read_file', argumentsSha256: 'a'.repeat(64), access: 'auto' },
      ]],
      finalRoundIndex: 1,
    });
    const persistCurrent = committedPersistence(store);
    const controller = agentController(store, runtime, persistCurrent, [...IDS, ...Array.from({ length: 30 }, (_, index) => {
      const suffix = (index + 1).toString(16).padStart(12, '0');
      return `${suffix.slice(0, 8)}-${suffix.slice(0, 4)}-4${suffix.slice(0, 3)}-8${suffix.slice(0, 3)}-${suffix}`;
    })]);

    const result = await controller.send({ conversationId, text: 'read with denied tool', attachments: [] });

    expect(result.status).toBe('completed');
    expect(runtime.bindAgentApproval).not.toHaveBeenCalled();
    expect(runtime.executeAgentTool).toHaveBeenCalledTimes(1);
    expect((runtime.executeAgentTool as jest.Mock).mock.calls[0]?.[0].name).toBe('read_file');
    expect((runtime.prepareAgentToolBatch as jest.Mock).mock.calls[0]?.[0].expected_batch_revision).toBe(0);
  });

  test('atomically finalizes a cancelled tool result with cleanup', async () => {
    const store = agentStore();
    const conversationId = store.getState().selectedConversationId!;
    const runtime = makeRuntime([], {
      batchRounds: [[
        { callId: 'cancelled-write', name: 'write_file', argumentsSha256: 'c'.repeat(64), access: 'conversation_confirm' },
      ]],
      finalRoundIndex: 1,
      cancelledCallIds: ['cancelled-write'],
    });
    const persistCurrent = committedPersistence(store);
    const finalStore = jest.spyOn(store, 'completeAgentAttempt');
    const receiptStore = jest.spyOn(store, 'recordAgentToolResult');
    const cleanupAck = jest.spyOn(store, 'acknowledgeAgentTranscriptCleanupTransaction');
    const controller = agentController(store, runtime, persistCurrent, [...IDS, ...Array.from({ length: 30 }, (_, index) => {
      const suffix = (index + 1).toString(16).padStart(12, '0');
      return `${suffix.slice(0, 8)}-${suffix.slice(0, 4)}-4${suffix.slice(0, 3)}-8${suffix.slice(0, 3)}-${suffix}`;
    })]);

    const result = await controller.send({ conversationId, text: 'cancelled tool', attachments: [] });

    expect(result.status).toBe('completed');
    expect(runtime.executeAgentTool).toHaveBeenCalledTimes(1);
    expect(receiptStore).not.toHaveBeenCalled();
    expect(finalStore).toHaveBeenCalledTimes(1);
    expect(finalStore.mock.calls[0]?.[0]).toMatchObject({
      assistantMessage: null,
      journal: { phase: 'cancelled' },
      evidence: { kind: 'execute_agent_tool' },
      cleanup: { reason: 'cancelled' },
    });
    const executeRequest = (runtime.executeAgentTool as jest.Mock).mock.calls[0]?.[0];
    const finalEvents = finalStore.mock.calls[0]?.[0]?.events ?? [];
    expect(finalEvents).toHaveLength(3);
    expect(finalEvents[0]).toMatchObject({
      event_id: executeRequest.operation_id,
      kind: 'tool_call',
      status: 'running',
      call_id: 'cancelled-write',
    });
    expect(finalEvents[1]).toMatchObject({
      kind: 'tool_result',
      status: 'cancelled',
      call_id: 'cancelled-write',
    });
    expect(finalEvents[1]?.event_id).not.toBe(executeRequest.operation_id);
    expect(finalEvents[2]).toMatchObject({
      kind: 'terminal',
      status: 'cancelled',
      call_id: null,
    });
    expect(new Set(finalEvents.map(event => event.event_id)).size).toBe(3);
    expect(runtime.finalizeAgentAttempt).toHaveBeenCalledTimes(1);
    expect(runtime.discardAgentAttempt).toHaveBeenCalledTimes(1);
    expect(cleanupAck).toHaveBeenCalledTimes(1);
    expect(store.getState().agentTranscriptCleanupOutbox).toEqual([]);
    expect(store.getState().conversations[conversationId]?.messages).toHaveLength(1);
    expect(store.getState().conversations[conversationId]?.attempts[0]).toMatchObject({
      status: 'cancelled',
      assistantMessageId: null,
      agent: { phase: 'cancelled' },
    });
  });

  test.each([{ label: 'ASCII', reason: 'no commits right now' }, { label: 'Chinese byte boundary', reason: '拒'.repeat(666) + 'ab' }, { label: 'emoji byte boundary', reason: '😀'.repeat(500) }])('persists batch decisions and exact denial text: $label', async ({ reason }) => {
    const store = agentStore();
    const conversationId = store.getState().selectedConversationId!;
    const runtime = makeRuntime([]);
    const committedSessions: string[] = [];
    const persistCurrent = jest.fn(async (): Promise<CompletionPersistenceResult> => {
      const session = store.serialize();
      const digest = sessionSnapshotSHA256(session)!;
      const generation = (store.getSessionAuthority()?.generation ?? 1) + 1;
      const snapshot = { schema_version: 1 as const, generation, session_sha256: digest };
      committedSessions.push(session);
      store.setSessionAuthority({ generation, sessionSha256: digest });
      return { status: 'committed', snapshot };
    });
    const requestBatchApprovals = jest.fn(
      async (requests: readonly CompletionAgentApprovalRequest[]) => {
        expect(requests).toHaveLength(2);
        expect(requests[0]?.preview?.kind).toBe('write_file');
        expect(requests[0]?.preview?.paths).toEqual(['notes.md']);
        expect(requests[1]?.preview?.kind).toBe('git_commit');
        return [
          { status: 'approved', scope: 'once' },
          { status: 'denied', message: reason },
        ];
      },
    );
    const controller = agentController(
      store,
      runtime,
      persistCurrent,
      [...IDS],
      jest.fn(),
      () => NOW,
      requestBatchApprovals,
    );
    const result = await controller.send({
      conversationId,
      text: 'write and commit',
      attachments: [],
    });
    expect(result.status).toBe('completed');
    // One batch presentation for both gated calls, never a single-card ask.
    expect(requestBatchApprovals).toHaveBeenCalledTimes(1);
    const bindMock = runtime.bindAgentApproval as jest.Mock;
    expect(bindMock).toHaveBeenCalledTimes(2);
    expect(bindMock.mock.calls[0]?.[0]).toMatchObject({
      call_id: 'write-call',
      decision: 'allow_once',
      deny_message: null,
    });
    expect(bindMock.mock.calls[1]?.[0]).toMatchObject({
      call_id: 'commit-call',
      decision: 'denied',
      deny_message: reason,
    });
    // The denied call never executes; only the allowed write does.
    const executeMock = runtime.executeAgentTool as jest.Mock;
    expect(executeMock).toHaveBeenCalledTimes(1);
    expect(executeMock.mock.calls[0]?.[0].call_id).toBe('write-call');
    // The completed attempt cleared its batch, but the denial settlement is
    // durable in the session events: a decide_approval marker followed by a
    // structured denied tool result carrying the native denied receipt digest
    // and the user-denial failure code, with no approval reference.
    const conversation = store.getState().conversations[conversationId]!;
    const attemptId = conversation.attempts[0]!.attemptId;
    expect(conversation.attempts[0]).toMatchObject({
      status: 'completed',
      agent: { phase: 'final_response' },
    });
    const commitEvents = (store.getState().sessionEvents ?? []).filter(
      event => event.attempt_id === attemptId && event.call_id === 'commit-call',
    );
    expect(commitEvents.map(event => `${event.kind}:${event.status}`)).toEqual([
      'approval:approval',
      'tool_result:denied',
    ]);
    expect(commitEvents[0]?.approval_reference).toBe(commitEvents[0]?.event_id);
    expect(commitEvents[1]).toMatchObject({
      result_sha256: 'd'.repeat(64),
      approval_reference: null,
      failure_code: 'E_AGENT_DENIED_BY_USER',
    });
    // The allowed write executed and settled normally after the denial.
    const writeEvents = (store.getState().sessionEvents ?? []).filter(
      event => event.attempt_id === attemptId && event.call_id === 'write-call',
    );
    expect(writeEvents.map(event => `${event.kind}:${event.status}`)).toEqual([
      'approval:approval',
      'approval:approval',
      'tool_call:running',
      'tool_result:ok',
    ]);
    // Rehydration through the schema-9 serializer preserves the denial.
    const hydrated = hydrateChatState(store.serialize());
    const hydratedEvents = (hydrated.sessionEvents ?? []).filter(
      event => event.attempt_id === attemptId && event.call_id === 'commit-call',
    );
    expect(hydratedEvents).toEqual(commitEvents);
    // JS-to-native parity: the first checkpoint that persists the denial
    // (journal still frozen on the batch, denied receipt on the commit call,
    // structured denied tool result) is the shared fixture the native
    // SessionSnapshotStore must accept byte-for-byte.
    const deniedSession = committedSessions.find(session => {
      const parsed = JSON.parse(session) as {
        session_events: Array<{ status: string; call_id: string | null }>;
      };
      return parsed.session_events.some(
        event => event.status === 'denied' && event.call_id === 'commit-call',
      );
    });
    expect(deniedSession).toBeDefined();
    const deniedJournal = (JSON.parse(deniedSession!) as {
      conversations: Array<{
        attempts: Array<{
          agent: {
            phase: string;
            call_index: number;
            batch: Array<{ call_id: string; receipt: { outcome: string } | null }>;
          };
        }>;
      }>;
    }).conversations[0]!.attempts[0]!.agent;
    expect(deniedJournal.phase).toBe('batch_frozen');
    expect(deniedJournal.call_index).toBe(0);
    expect(deniedJournal.batch.map(call => call.receipt?.outcome ?? null)).toEqual([
      null,
      'denied',
    ]);
    assertSharedFixture(deniedSession!, 'agent-denied-call-session.json');
  });

  test('a batch answer list of the wrong length fails closed into denials', async () => {
    const store = agentStore();
    const conversationId = store.getState().selectedConversationId!;
    const runtime = makeRuntime([]);
    const persistCurrent = committedPersistence(store);
    const requestBatchApprovals = jest.fn(async () => []);
    const controller = agentController(
      store,
      runtime,
      persistCurrent,
      [...IDS],
      jest.fn(),
      () => NOW,
      requestBatchApprovals,
    );
    const result = await controller.send({
      conversationId,
      text: 'write and commit',
      attachments: [],
    });
    expect(result.status).toBe('completed');
    const bindMock = runtime.bindAgentApproval as jest.Mock;
    expect(bindMock).toHaveBeenCalledTimes(2);
    expect(bindMock.mock.calls[0]?.[0].decision).toBe('denied');
    expect(bindMock.mock.calls[1]?.[0].decision).toBe('denied');
    expect(runtime.executeAgentTool).not.toHaveBeenCalled();
  });
});
