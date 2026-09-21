package tech.zseven.rish.runtime

import org.json.JSONObject
import java.util.UUID

/**
 * Forgetting a workspace and deleting its owned content, in the order the
 * spec fixes and with the locks in the order iOS takes them.
 *
 * The session store is outermost: it proves the clearance -- that a committed
 * session names the workspace nowhere and carries this very request -- and
 * holds that proof while the rest runs, so no commit can take the workspace
 * back in between. Then the project layer, so no attach can start. Then the
 * registry, closed to new work on the workspace and waiting for work in
 * flight to finish. Only then does anything move.
 *
 * **What Android amends.** iOS asks that a project be detached -- through
 * its own reviewed checkpoint -- before either action. Android has no detach
 * yet. Forgetting keeps that rule: a workspace with a published project is
 * refused. Deleting does not need it: the private gitdir is owned content of
 * an owned workspace, and the delete journal records its identity before the
 * first rename and removes it with the rest, under the one confirmation the
 * person gave. An attach in flight refuses both.
 */
internal class AndroidWorkspaceRemoval(
    private val sessions: AndroidSessionStore,
    private val workspaces: AndroidWorkspaceRegistry,
    private val projects: AndroidWorkspaceProjects,
) : WorkspaceClearanceHost {
    /**
     * A confirmation is one delete, prepared: bound to everything the
     * prepare proved, consumed the moment the delete's intent is journaled,
     * and gone with the process. Restarting before that means preparing --
     * and confirming -- again; restarting after it means nothing is asked.
     */
    private class Confirmation(
        val id: String,
        val workspaceId: String,
        val revision: Int,
        val clearanceReceiptId: String,
        val registryGeneration: Int,
        val expiresAtMs: Long,
    )

    private val confirmations = HashMap<String, Confirmation>()

    override fun clearable(operation: JSONObject): Boolean {
        val workspaceId = operation.optString("workspace_id")
        val revision = operation.optInt("binding_revision")
        if (!workspaces.clearable(workspaceId, revision)) return false
        return when (operation.optString("action")) {
            "forget" -> projects.relation(workspaceId) == AndroidWorkspaceProjects.Relation.NONE
            "delete_owned" -> projects.relation(workspaceId) != AndroidWorkspaceProjects.Relation.IN_FLIGHT
            else -> false
        }
    }

    /** Finishes what an earlier launch left half done. Cheap when there is nothing. */
    fun recover() {
        workspaces.sweepRemovals()
    }

    fun forget(fields: JSONObject): JSONObject {
        recover()
        val workspaceId = fields.getString("workspace_id")
        val revision = fields.getInt("expected_binding_revision")
        val operationId = fields.getString("operation_id")
        val clearanceReceiptId = fields.getString("clearance_receipt_id")
        // A replay is answered from the receipt: the clearance it was issued
        // under may be long gone, and the registration already is.
        workspaces.removalReceipt(operationId)?.let {
            return workspaces.forget(workspaceId, revision, operationId, clearanceReceiptId)
        }
        return sessions.withClearance(operationId, clearanceReceiptId, workspaceId, revision) {
            projects.excluding(workspaceId) {
                if (projects.relation(workspaceId) != AndroidWorkspaceProjects.Relation.NONE) {
                    throw AndroidWorkspaceRegistry.Refused("E_WORKSPACE_CONFLICT")
                }
                workspaces.removing(workspaceId) {
                    workspaces.forget(workspaceId, revision, operationId, clearanceReceiptId)
                }
            }
        } ?: throw AndroidWorkspaceRegistry.Refused("E_WORKSPACE_CONFLICT")
    }

    fun prepareDelete(fields: JSONObject): JSONObject {
        recover()
        val workspaceId = fields.getString("workspace_id")
        val revision = fields.getInt("expected_binding_revision")
        val clearanceReceiptId = fields.getString("clearance_receipt_id")
        if (!workspaces.clearable(workspaceId, revision)) throw AndroidWorkspaceRegistry.Refused("E_WORKSPACE_CONFLICT")
        if (projects.relation(workspaceId) == AndroidWorkspaceProjects.Relation.IN_FLIGHT) {
            throw AndroidWorkspaceRegistry.Refused("E_WORKSPACE_BUSY")
        }
        // The clearance must exist and still stand; the operation it belongs
        // to is the receipt's own, which the delete will name again.
        val operationId = sessions.clearanceOperation(clearanceReceiptId, workspaceId, revision)
            ?: throw AndroidWorkspaceRegistry.Refused("E_WORKSPACE_CONFLICT")
        val generation = workspaces.registry().getInt("generation")
        val confirmation = Confirmation(
            id = UUID.randomUUID().toString(),
            workspaceId = workspaceId,
            revision = revision,
            clearanceReceiptId = clearanceReceiptId,
            registryGeneration = generation,
            expiresAtMs = System.currentTimeMillis() + CONFIRMATION_TTL_MS,
        )
        synchronized(confirmations) { confirmations[workspaceId] = confirmation }
        check(operationId.isNotEmpty())
        return JSONObject().put("schema_version", 1).put("confirmation_id", confirmation.id)
            .put("expires_at", RuntimeJson.at(confirmation.expiresAtMs))
    }

    fun deleteOwned(fields: JSONObject): JSONObject {
        recover()
        val workspaceId = fields.getString("workspace_id")
        val revision = fields.getInt("expected_binding_revision")
        val operationId = fields.getString("operation_id")
        val clearanceReceiptId = fields.getString("clearance_receipt_id")
        val confirmationId = fields.getString("confirmation_id")
        // A replay, or a journaled delete this process was restarted into,
        // finishes without a confirmation: the intent was already durable.
        if (workspaces.removalReceipt(operationId) != null || workspaces.removalJournaled(operationId)) {
            return workspaces.deleteOwned(workspaceId, revision, operationId, clearanceReceiptId, null)
        }
        val confirmation = synchronized(confirmations) { confirmations.remove(workspaceId) }
            ?: throw AndroidWorkspaceRegistry.Refused("E_WORKSPACE_CONFLICT")
        if (confirmation.id != confirmationId || confirmation.revision != revision ||
            confirmation.clearanceReceiptId != clearanceReceiptId ||
            confirmation.expiresAtMs < System.currentTimeMillis()
        ) {
            throw AndroidWorkspaceRegistry.Refused("E_WORKSPACE_CONFLICT")
        }
        return sessions.withClearance(operationId, clearanceReceiptId, workspaceId, revision) {
            projects.excluding(workspaceId) {
                if (projects.relation(workspaceId) == AndroidWorkspaceProjects.Relation.IN_FLIGHT) {
                    throw AndroidWorkspaceRegistry.Refused("E_WORKSPACE_BUSY")
                }
                workspaces.removing(workspaceId) {
                    workspaces.deleteOwned(
                        workspaceId, revision, operationId, clearanceReceiptId,
                        expectedRegistryGeneration = confirmation.registryGeneration,
                    )
                }
            }
        } ?: throw AndroidWorkspaceRegistry.Refused("E_WORKSPACE_CONFLICT")
    }

    private companion object {
        const val CONFIRMATION_TTL_MS = 2L * 60 * 1000
    }
}
