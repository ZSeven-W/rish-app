import {
  LocalWorkspaces,
  type WorkspaceDescriptorV2,
} from '../native/LocalWorkspaces';
import {
  SessionSnapshots,
  type WorkspaceAuthorityOutboxV1 as PersistedWorkspaceAuthorityOutboxV1,
  type WorkspaceBindingClearanceReceiptV1,
} from '../native/SessionSnapshots';
import type { ChatStore } from '../state/store';
import type { WorkspaceAuthorityOutboxV1 } from '../state/types';

/**
 * Forgetting a workspace and deleting its owned content, in the order the
 * spec fixes and owned end to end by one coordinator:
 *
 *   guard (nothing live references the workspace)
 *   -> one store mutation: unbind every conversation, append the request to
 *      the authority outbox
 *   -> native session commit with clearance: the committed session names the
 *      workspace nowhere and carries the request, and native issues the
 *      receipt that proves it
 *   -> native forget / prepare + delete under that receipt
 *   -> acknowledge the request (remove it from the outbox) and persist
 *
 * Nothing about the workspace changes durably until native has cleared it,
 * and the outbox entry is only removed once native has a receipt for the
 * operation -- or once the operation is provably abandoned (see `retire`).
 * A request the person never finished is left in the outbox and picked up
 * again by `drain` on the next launch.
 */

export type WorkspaceRemovalAction = 'forget' | 'delete_owned';

export type WorkspaceRemovalOutcome =
  | { readonly status: 'forgotten' | 'deleted' }
  /** This platform cannot remove workspaces yet; nothing changed. */
  | { readonly status: 'unavailable' }
  /** Something still holds the workspace: a live turn, a prepared context, another request. */
  | { readonly status: 'blocked' }
  /** The person declined the confirmation. */
  | { readonly status: 'cancelled' }
  /** The request was abandoned before anything durable changed. */
  | { readonly status: 'retired'; readonly code: string }
  /** The request stays in the outbox: native could not say whether it happened. */
  | { readonly status: 'pending' };

export type WorkspaceRemovalTarget = Pick<
  WorkspaceDescriptorV2,
  'workspace_id' | 'binding_revision' | 'display_name' | 'origin'
>;

type RemovalStore = Pick<
  ChatStore,
  'getState' | 'applyWorkspaceAuthorityMutation' | 'acknowledgeWorkspaceAuthorityMutation'
>;

type RemovalWorkspaces = Pick<
  typeof LocalWorkspaces,
  'isRemovalAvailable' | 'forget' | 'prepareDeleteOwnedContent' | 'deleteOwnedContent' | 'queryOperation'
>;

type RemovalSessions = Pick<
  typeof SessionSnapshots,
  'persistSessionWithWorkspaceClearance' | 'queryWorkspaceClearance'
>;

export type WorkspaceRemovalDependencies = {
  readonly store: RemovalStore;
  /** The candidate bytes for the state as it is now, preferences included. */
  readonly serialize: () => string;
  /** Runs a native session write behind every write already queued. */
  readonly enqueueSessionWrite: <T>(work: () => Promise<T>) => Promise<T>;
  /** An ordinary compare-and-swap persist of the current state. */
  readonly persist: () => Promise<boolean>;
  readonly createOperationId: () => string;
  /** The person's answer to "delete these files and their history?". */
  readonly confirmDelete: (workspace: WorkspaceRemovalTarget) => Promise<boolean>;
  readonly workspaces?: RemovalWorkspaces;
  readonly sessions?: RemovalSessions;
};

/**
 * Refusals under which the request is provably not carried out and will
 * never be: the receipt was stale or for another workspace, the revision
 * moved, the workspace is busy or cannot be removed here. Anything else --
 * a lost bridge response, a storage failure -- is ambiguous and keeps the
 * request for the next launch.
 */
const RETIRING_CODES = new Set([
  'E_WORKSPACE_CONFLICT',
  'E_WORKSPACE_STALE',
  'E_WORKSPACE_BUSY',
  'E_WORKSPACE_UNAVAILABLE',
  'E_WORKSPACE_INVALID',
  'E_WORKSPACE_CAPABILITY',
]);

function errorCode(error: unknown): string {
  const code =
    typeof error === 'object' && error !== null && 'code' in error
      ? (error as { code?: unknown }).code
      : undefined;
  if (typeof code === 'string' && code.length > 0) return code;
  const text = error instanceof Error ? error.message : String(error);
  return text.match(/\bE_[A-Z][A-Z0-9_]*\b/u)?.[0] ?? 'E_WORKSPACE_PERSISTENCE';
}

function persisted(entry: WorkspaceAuthorityOutboxV1): PersistedWorkspaceAuthorityOutboxV1 {
  return {
    schema_version: 1,
    operation_id: entry.operationId,
    action: entry.action,
    workspace_id: entry.workspaceId,
    binding_revision: entry.bindingRevision,
    clearance_receipt_id: entry.clearanceReceiptId,
    created_at: entry.createdAt,
  };
}

export class WorkspaceRemovalCoordinator {
  private readonly store: RemovalStore;
  private readonly workspaces: RemovalWorkspaces;
  private readonly sessions: RemovalSessions;
  private readonly dependencies: WorkspaceRemovalDependencies;
  private busy = false;

  constructor(dependencies: WorkspaceRemovalDependencies) {
    this.dependencies = dependencies;
    this.store = dependencies.store;
    this.workspaces = dependencies.workspaces ?? LocalWorkspaces;
    this.sessions = dependencies.sessions ?? SessionSnapshots;
  }

  /** Whether this platform can carry a removal out at all. Read before anything changes. */
  isAvailable(): boolean {
    try {
      return this.workspaces.isRemovalAvailable();
    } catch {
      return false;
    }
  }

  /** The request already pending for a workspace, if the outbox holds one. */
  pendingFor(workspaceId: string): WorkspaceAuthorityOutboxV1 | null {
    return (
      (this.store.getState().workspaceAuthorityOutbox ?? []).find(
        entry => entry.workspaceId === workspaceId,
      ) ?? null
    );
  }

  async remove(
    workspace: WorkspaceRemovalTarget,
    action: WorkspaceRemovalAction,
  ): Promise<WorkspaceRemovalOutcome> {
    if (!this.isAvailable()) return { status: 'unavailable' };
    if (this.busy) return { status: 'blocked' };
    this.busy = true;
    try {
      if (action === 'delete_owned' && !(await this.dependencies.confirmDelete(workspace))) {
        return { status: 'cancelled' };
      }
      const existing = this.pendingFor(workspace.workspace_id);
      if (existing !== null && existing.action !== action) return { status: 'blocked' };
      let entry = existing;
      let transaction = null as ReturnType<RemovalStore['applyWorkspaceAuthorityMutation']>;
      if (entry === null) {
        transaction = this.store.applyWorkspaceAuthorityMutation({
          schemaVersion: 1,
          operationId: this.dependencies.createOperationId(),
          action,
          workspaceId: workspace.workspace_id,
          bindingRevision: workspace.binding_revision,
          clearanceReceiptId: this.dependencies.createOperationId(),
          expectedState: this.store.getState(),
        });
        if (transaction === null) return { status: 'blocked' };
        entry = transaction.outboxEntry;
      }
      const receipt = await this.clearance(entry);
      if (receipt === null) {
        // Not committed: nothing durable names the request, so the
        // in-memory unbinding is undone as if nothing had been asked.
        if (transaction !== null && !transaction.rollback()) {
          this.store.acknowledgeWorkspaceAuthorityMutation(entry.operationId);
        }
        await this.dependencies.persist();
        return { status: 'retired', code: 'E_WORKSPACE_CLEARANCE_UNAVAILABLE' };
      }
      // The store transaction settles with the outcome: committed once the
      // request is done or provably still pending, rolled back when the
      // request is retired before anything durable named the workspace gone.
      return await this.carryOut(entry, receipt, transaction);
    } finally {
      this.busy = false;
    }
  }

  /**
   * Launch-time drain of the authority outbox. A request native already
   * carried out is acknowledged; a forget that still has, or can still get,
   * its clearance is carried out; a delete is left for the person to confirm
   * again in the picker; and a request whose clearance can neither be found
   * nor issued is retired.
   */
  async drain(): Promise<void> {
    if (!this.isAvailable() || this.busy) return;
    this.busy = true;
    try {
      for (const entry of [...(this.store.getState().workspaceAuthorityOutbox ?? [])]) {
        if (await this.alreadyCarriedOut(entry)) {
          await this.settle(entry);
          continue;
        }
        const receipt = await this.clearance(entry);
        if (receipt === null) {
          await this.retire(entry, null, 'E_WORKSPACE_CLEARANCE_UNAVAILABLE');
          continue;
        }
        if (entry.action === 'forget') await this.carryOut(entry, receipt, null);
      }
    } finally {
      this.busy = false;
    }
  }

  // --- the steps ---------------------------------------------------------------

  /** The clearance receipt for a request: the one on file, or a fresh one. */
  private async clearance(
    entry: WorkspaceAuthorityOutboxV1,
  ): Promise<WorkspaceBindingClearanceReceiptV1 | null> {
    const operation = persisted(entry);
    try {
      const known = await this.sessions.queryWorkspaceClearance({
        schema_version: 1,
        operation_id: entry.operationId,
      });
      if (known.status === 'committed' && known.receipt.workspace_id === entry.workspaceId) {
        return known.receipt;
      }
    } catch {
      // Not knowable: try to issue one.
    }
    try {
      const issued = await this.dependencies.enqueueSessionWrite(() =>
        this.sessions.persistSessionWithWorkspaceClearance({
          schema_version: 1,
          candidate_json: this.dependencies.serialize(),
          operation,
        }),
      );
      return issued.status === 'committed' ? issued.receipt : null;
    } catch {
      return null;
    }
  }

  private async alreadyCarriedOut(entry: WorkspaceAuthorityOutboxV1): Promise<boolean> {
    try {
      const query = await this.workspaces.queryOperation({
        schema_version: 1,
        operation_id: entry.operationId,
      });
      return (
        query.status === 'committed' &&
        query.receipt.workspace_id === entry.workspaceId &&
        query.receipt.operation === entry.action &&
        query.receipt.outcome === 'committed'
      );
    } catch {
      return false;
    }
  }

  private async carryOut(
    entry: WorkspaceAuthorityOutboxV1,
    receipt: WorkspaceBindingClearanceReceiptV1,
    transaction: ReturnType<RemovalStore['applyWorkspaceAuthorityMutation']>,
  ): Promise<WorkspaceRemovalOutcome> {
    const request = {
      schema_version: 1 as const,
      workspace_id: entry.workspaceId,
      expected_binding_revision: entry.bindingRevision,
      operation_id: entry.operationId,
      clearance_receipt_id: receipt.clearance_receipt_id,
    };
    try {
      if (entry.action === 'forget') {
        await this.workspaces.forget(request);
      } else {
        const prepared = await this.workspaces.prepareDeleteOwnedContent({
          schema_version: 1,
          workspace_id: entry.workspaceId,
          expected_binding_revision: entry.bindingRevision,
          clearance_receipt_id: receipt.clearance_receipt_id,
        });
        await this.workspaces.deleteOwnedContent({
          ...request,
          confirmation_id: prepared.confirmation_id,
        });
      }
      return await this.settle(entry, transaction);
    } catch (error) {
      const code = errorCode(error);
      // A lost answer is not a lost operation: the receipt says.
      if (await this.alreadyCarriedOut(entry)) return await this.settle(entry, transaction);
      // Nothing registered under that id is nothing left to forget.
      if (code === 'E_WORKSPACE_NOT_FOUND') return await this.settle(entry, transaction);
      if (RETIRING_CODES.has(code)) return await this.retire(entry, transaction, code);
      // Ambiguous: keep the request; the next launch asks native again.
      transaction?.commit();
      await this.dependencies.persist();
      return { status: 'pending' };
    }
  }

  /** The request is done: out of the outbox, and the session persisted without it. */
  private async settle(
    entry: WorkspaceAuthorityOutboxV1,
    transaction: ReturnType<RemovalStore['applyWorkspaceAuthorityMutation']> = null,
  ): Promise<WorkspaceRemovalOutcome> {
    transaction?.commit();
    this.store.acknowledgeWorkspaceAuthorityMutation(entry.operationId);
    await this.dependencies.persist();
    return { status: entry.action === 'forget' ? 'forgotten' : 'deleted' };
  }

  /**
   * The request is abandoned: native refused it for a reason that will not
   * change by asking again, and has no receipt for it. The bindings it took
   * are given back when the store still allows that; otherwise the request
   * alone is dropped, and the workspace stays registered and unbound.
   */
  private async retire(
    entry: WorkspaceAuthorityOutboxV1,
    transaction: ReturnType<RemovalStore['applyWorkspaceAuthorityMutation']>,
    code: string,
  ): Promise<WorkspaceRemovalOutcome> {
    if (transaction === null || !transaction.rollback()) {
      this.store.acknowledgeWorkspaceAuthorityMutation(entry.operationId);
    }
    await this.dependencies.persist();
    return { status: 'retired', code };
  }
}
