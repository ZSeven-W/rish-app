import { createChatStore } from '../src/state/store';
import {
  WorkspaceRemovalCoordinator,
  type WorkspaceRemovalDependencies,
} from '../src/workspaces/WorkspaceRemoval';

const T0 = '2026-09-21T00:00:00.000Z';
const WS_ID = '11111111-1111-4111-8111-111111111111';
const OTHER_WS = '22222222-2222-4222-8222-222222222222';
const RECEIPT_SHA = 'a'.repeat(64);

let nextId = 0;
function uuid(): string {
  nextId += 1;
  return `00000000-0000-4000-8000-${String(nextId).padStart(12, '0')}`;
}

function workspace(id = WS_ID, origin: 'rish_created' | 'granted_folder' = 'rish_created') {
  return { workspace_id: id, binding_revision: 1, display_name: 'Scratch', origin };
}

function receiptFor(operation: { operation_id: string; workspace_id: string; clearance_receipt_id: string }) {
  return {
    schema_version: 1 as const,
    clearance_receipt_id: operation.clearance_receipt_id,
    operation_id: operation.operation_id,
    workspace_id: operation.workspace_id,
    binding_revision: 1,
    committed_session_generation: 3,
    committed_session_sha256: RECEIPT_SHA,
    issued_at: T0,
  };
}

function refusal(code: string): Error & { code: string } {
  return Object.assign(new Error(code), { code });
}

function harness(overrides: Partial<WorkspaceRemovalDependencies> = {}) {
  const store = createChatStore({ now: () => T0, createId: () => uuid() });
  const conversationId = store.createConversation();
  const state = store.getState();
  const conversation = state.conversations[conversationId]!;
  const binding = store.applyConversationWorkspaceBinding({
    schema_version: 1,
    owner: {
      conversation_id: conversationId,
      expected_conversation: conversation,
      expected_project_context: conversation.projectContext,
      expected_destructive_epoch: state.projectContextDestructiveEpoch,
    },
    binding: { schema_version: 1, workspace_id: WS_ID, binding_revision: 1, project_id: null },
  });
  if (binding?.commit() !== true) throw new Error('fixture could not bind the conversation');
  type Operation = { operation_id: string; workspace_id: string; clearance_receipt_id: string; action: string };
  const workspaces = {
    isRemovalAvailable: jest.fn<boolean, []>(() => true),
    forget: jest.fn<Promise<unknown>, [unknown]>(async () => ({ schema_version: 1, status: 'forgotten' })),
    prepareDeleteOwnedContent: jest.fn<
      Promise<{ schema_version: 1; confirmation_id: string; expires_at: string }>,
      [unknown]
    >(async () => ({ schema_version: 1, confirmation_id: uuid(), expires_at: T0 })),
    deleteOwnedContent: jest.fn<Promise<unknown>, [unknown]>(async () => ({ schema_version: 1, status: 'deleted' })),
    queryOperation: jest.fn<Promise<unknown>, [{ operation_id: string }]>(async () => ({
      schema_version: 1,
      status: 'not_started',
    })),
  };
  const sessions = {
    persistSessionWithWorkspaceClearance: jest.fn<Promise<unknown>, [{ operation: Operation }]>(
      async request => ({ schema_version: 1, status: 'committed', receipt: receiptFor(request.operation) }),
    ),
    queryWorkspaceClearance: jest.fn<Promise<unknown>, [{ operation_id: string }]>(async () => ({
      schema_version: 1,
      status: 'not_started',
    })),
  };
  const persist = jest.fn(async () => true);
  const confirmDelete = jest.fn(async () => true);
  const serialized: string[] = [];
  const coordinator = new WorkspaceRemovalCoordinator({
    store,
    serialize: () => {
      const candidate = store.serialize();
      serialized.push(candidate);
      return candidate;
    },
    enqueueSessionWrite: work => work(),
    persist,
    createOperationId: uuid,
    confirmDelete,
    workspaces: workspaces as never,
    sessions: sessions as never,
    ...overrides,
  });
  return { store, conversationId, workspaces, sessions, persist, confirmDelete, coordinator, serialized };
}

beforeEach(() => {
  nextId = 0;
});

test('refuses before anything changes when the platform cannot remove workspaces', async () => {
  const h = harness();
  h.workspaces.isRemovalAvailable.mockReturnValue(false);
  const before = h.store.getState();
  expect(await h.coordinator.remove(workspace(), 'forget')).toEqual({ status: 'unavailable' });
  expect(h.store.getState()).toBe(before);
  expect(h.sessions.persistSessionWithWorkspaceClearance).not.toHaveBeenCalled();
  expect(h.persist).not.toHaveBeenCalled();
});

test('forgets: unbinds, clears against the committed session, calls native, acknowledges, persists', async () => {
  const h = harness();
  const outcome = await h.coordinator.remove(workspace(), 'forget');
  expect(outcome).toEqual({ status: 'forgotten' });

  // The candidate handed to native named the workspace nowhere and carried the request.
  expect(h.serialized).toHaveLength(1);
  const candidate = JSON.parse(h.serialized[0]!) as {
    conversations: { workspace_id: string | null; workspace_binding: unknown }[];
    workspace_authority_outbox: { action: string; workspace_id: string; operation_id: string }[];
  };
  expect(candidate.conversations[0]!.workspace_id).toBeNull();
  expect(candidate.conversations[0]!.workspace_binding).toBeNull();
  expect(candidate.workspace_authority_outbox).toHaveLength(1);
  expect(candidate.workspace_authority_outbox[0]!.action).toBe('forget');
  expect(candidate.workspace_authority_outbox[0]!.workspace_id).toBe(WS_ID);

  const operation = h.sessions.persistSessionWithWorkspaceClearance.mock.calls[0]![0]!.operation;
  expect(h.workspaces.forget).toHaveBeenCalledWith({
    schema_version: 1,
    workspace_id: WS_ID,
    expected_binding_revision: 1,
    operation_id: operation.operation_id,
    clearance_receipt_id: operation.clearance_receipt_id,
  });
  expect(h.workspaces.deleteOwnedContent).not.toHaveBeenCalled();
  // Acknowledged and persisted without the request.
  expect(h.store.getState().workspaceAuthorityOutbox).toEqual([]);
  expect(h.store.getState().conversations[h.conversationId]!.workspaceId).toBeNull();
  expect(h.persist).toHaveBeenCalledTimes(1);
});

test('deletes only after the person confirms, through prepare and the one-shot confirmation', async () => {
  const declined = harness();
  declined.confirmDelete.mockResolvedValue(false);
  const before = declined.store.getState();
  expect(await declined.coordinator.remove(workspace(), 'delete_owned')).toEqual({ status: 'cancelled' });
  expect(declined.store.getState()).toBe(before);
  expect(declined.sessions.persistSessionWithWorkspaceClearance).not.toHaveBeenCalled();

  const h = harness();
  expect(await h.coordinator.remove(workspace(), 'delete_owned')).toEqual({ status: 'deleted' });
  expect(h.confirmDelete).toHaveBeenCalledWith(workspace());
  const operation = h.sessions.persistSessionWithWorkspaceClearance.mock.calls[0]![0]!.operation;
  expect(operation.action).toBe('delete_owned');
  expect(h.workspaces.prepareDeleteOwnedContent).toHaveBeenCalledWith({
    schema_version: 1,
    workspace_id: WS_ID,
    expected_binding_revision: 1,
    clearance_receipt_id: operation.clearance_receipt_id,
  });
  const confirmation = (await h.workspaces.prepareDeleteOwnedContent.mock.results[0]!.value).confirmation_id;
  expect(h.workspaces.deleteOwnedContent).toHaveBeenCalledWith({
    schema_version: 1,
    workspace_id: WS_ID,
    expected_binding_revision: 1,
    operation_id: operation.operation_id,
    clearance_receipt_id: operation.clearance_receipt_id,
    confirmation_id: confirmation,
  });
  expect(h.workspaces.forget).not.toHaveBeenCalled();
  expect(h.store.getState().workspaceAuthorityOutbox).toEqual([]);
});

test('is blocked while something still holds the workspace, and changes nothing', async () => {
  const h = harness();
  expect(
    h.store.prepareTurnAttempt(h.conversationId, 'live', { sendWithoutProjectContext: true })!.commit(),
  ).toBe(true);
  const before = h.store.getState();
  expect(await h.coordinator.remove(workspace(), 'forget')).toEqual({ status: 'blocked' });
  expect(h.store.getState()).toBe(before);
  expect(h.sessions.persistSessionWithWorkspaceClearance).not.toHaveBeenCalled();
  expect(h.workspaces.forget).not.toHaveBeenCalled();
});

test('a clearance that does not commit gives the bindings back and retires the request', async () => {
  const h = harness();
  h.sessions.persistSessionWithWorkspaceClearance.mockResolvedValue({
    schema_version: 1,
    status: 'not_committed',
    receipt: null,
  } as never);
  expect(await h.coordinator.remove(workspace(), 'forget')).toEqual({
    status: 'retired',
    code: 'E_WORKSPACE_CLEARANCE_UNAVAILABLE',
  });
  expect(h.store.getState().conversations[h.conversationId]!.workspaceId).toBe(WS_ID);
  expect(h.store.getState().workspaceAuthorityOutbox).toEqual([]);
  expect(h.workspaces.forget).not.toHaveBeenCalled();
  expect(h.persist).toHaveBeenCalledTimes(1);
});

test('a native refusal that will not change retires the request and gives the bindings back', async () => {
  const h = harness();
  h.workspaces.forget.mockRejectedValue(refusal('E_WORKSPACE_CONFLICT'));
  expect(await h.coordinator.remove(workspace(), 'forget')).toEqual({
    status: 'retired',
    code: 'E_WORKSPACE_CONFLICT',
  });
  // Native was asked whether it happened anyway before the request was dropped.
  expect(h.workspaces.queryOperation).toHaveBeenCalledTimes(1);
  expect(h.store.getState().conversations[h.conversationId]!.workspaceId).toBe(WS_ID);
  expect(h.store.getState().workspaceAuthorityOutbox).toEqual([]);
  expect(h.persist).toHaveBeenCalledTimes(1);
});

test('a lost answer is settled by the receipt, and an ambiguous one keeps the request', async () => {
  const lost = harness();
  lost.workspaces.forget.mockRejectedValue(new Error('bridge went away'));
  lost.workspaces.queryOperation.mockImplementation(async request => ({
    schema_version: 1 as const,
    status: 'committed' as const,
    receipt: {
      schema_version: 1 as const,
      operation_id: request.operation_id,
      workspace_id: WS_ID,
      operation: 'forget' as const,
      binding_revision: 1,
      registry_generation: 2,
      registry_sha256: RECEIPT_SHA,
      outcome: 'committed' as const,
      committed_at: T0,
    },
  }));
  expect(await lost.coordinator.remove(workspace(), 'forget')).toEqual({ status: 'forgotten' });
  expect(lost.store.getState().workspaceAuthorityOutbox).toEqual([]);

  const ambiguous = harness();
  ambiguous.workspaces.forget.mockRejectedValue(refusal('E_WORKSPACE_PERSISTENCE'));
  expect(await ambiguous.coordinator.remove(workspace(), 'forget')).toEqual({ status: 'pending' });
  // The request stays, the conversation stays unbound, and the state is persisted that way.
  expect(ambiguous.store.getState().workspaceAuthorityOutbox).toHaveLength(1);
  expect(ambiguous.store.getState().conversations[ambiguous.conversationId]!.workspaceId).toBeNull();
  expect(ambiguous.persist).toHaveBeenCalledTimes(1);
});

test('nothing registered under the id is nothing left to forget', async () => {
  const h = harness();
  h.workspaces.forget.mockRejectedValue(refusal('E_WORKSPACE_NOT_FOUND'));
  expect(await h.coordinator.remove(workspace(), 'forget')).toEqual({ status: 'forgotten' });
  expect(h.store.getState().workspaceAuthorityOutbox).toEqual([]);
});

test('a second request for the same workspace reuses the pending one and refuses a different action', async () => {
  const h = harness();
  h.workspaces.forget.mockRejectedValueOnce(refusal('E_WORKSPACE_PERSISTENCE'));
  expect(await h.coordinator.remove(workspace(), 'forget')).toEqual({ status: 'pending' });
  const pending = h.store.getState().workspaceAuthorityOutbox![0]!;
  expect(await h.coordinator.remove(workspace(), 'delete_owned')).toEqual({ status: 'blocked' });
  expect(await h.coordinator.remove(workspace(), 'forget')).toEqual({ status: 'forgotten' });
  expect(h.workspaces.forget).toHaveBeenLastCalledWith(
    expect.objectContaining({ operation_id: pending.operationId }),
  );
  expect(h.store.getState().workspaceAuthorityOutbox).toEqual([]);
});

describe('drain', () => {
  function pendingEntry(store: ReturnType<typeof createChatStore>, action: 'forget' | 'delete_owned', workspaceId = WS_ID) {
    const transaction = store.applyWorkspaceAuthorityMutation({
      schemaVersion: 1,
      operationId: uuid(),
      action,
      workspaceId,
      bindingRevision: 1,
      clearanceReceiptId: uuid(),
      expectedState: store.getState(),
    })!;
    expect(transaction.commit()).toBe(true);
    return transaction.outboxEntry;
  }

  test('acknowledges a request native already carried out', async () => {
    const h = harness();
    const entry = pendingEntry(h.store, 'forget');
    h.workspaces.queryOperation.mockResolvedValue({
      schema_version: 1,
      status: 'committed',
      receipt: {
        schema_version: 1,
        operation_id: entry.operationId,
        workspace_id: WS_ID,
        operation: 'forget',
        binding_revision: 1,
        registry_generation: 2,
        registry_sha256: RECEIPT_SHA,
        outcome: 'committed',
        committed_at: T0,
      },
    });
    await h.coordinator.drain();
    expect(h.store.getState().workspaceAuthorityOutbox).toEqual([]);
    expect(h.workspaces.forget).not.toHaveBeenCalled();
    expect(h.sessions.persistSessionWithWorkspaceClearance).not.toHaveBeenCalled();
    expect(h.persist).toHaveBeenCalledTimes(1);
  });

  test('carries a forget out under the clearance on file, and leaves a delete for the person', async () => {
    const h = harness();
    const forgetEntry = pendingEntry(h.store, 'forget');
    const deleteEntry = pendingEntry(h.store, 'delete_owned', OTHER_WS);
    h.sessions.queryWorkspaceClearance.mockImplementation(async request => ({
      schema_version: 1 as const,
      status: 'committed' as const,
      receipt: receiptFor({
        operation_id: request.operation_id,
        workspace_id: request.operation_id === forgetEntry.operationId ? WS_ID : OTHER_WS,
        clearance_receipt_id: request.operation_id === forgetEntry.operationId ? forgetEntry.clearanceReceiptId : deleteEntry.clearanceReceiptId,
      }),
    }));
    await h.coordinator.drain();
    expect(h.workspaces.forget).toHaveBeenCalledTimes(1);
    expect(h.workspaces.deleteOwnedContent).not.toHaveBeenCalled();
    expect(h.sessions.persistSessionWithWorkspaceClearance).not.toHaveBeenCalled();
    expect(h.store.getState().workspaceAuthorityOutbox).toEqual([deleteEntry]);
  });

  test('retires a request whose clearance can neither be found nor issued', async () => {
    const h = harness();
    const entry = pendingEntry(h.store, 'forget');
    h.sessions.queryWorkspaceClearance.mockResolvedValue({ schema_version: 1, status: 'unknown' } as never);
    h.sessions.persistSessionWithWorkspaceClearance.mockResolvedValue({
      schema_version: 1,
      status: 'not_committed',
      receipt: null,
    } as never);
    await h.coordinator.drain();
    expect(h.workspaces.forget).not.toHaveBeenCalled();
    expect(h.store.getState().workspaceAuthorityOutbox).toEqual([]);
    // Retired from a cold start: the bindings cannot be given back, the
    // conversation stays unbound and the workspace stays registered.
    expect(h.store.getState().conversations[h.conversationId]!.workspaceId).toBeNull();
    expect(entry.operationId).toBeDefined();
    expect(h.persist).toHaveBeenCalledTimes(1);
  });
});
