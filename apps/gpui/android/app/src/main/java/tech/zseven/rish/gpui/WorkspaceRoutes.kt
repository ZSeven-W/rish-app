package tech.zseven.rish.gpui

import org.json.JSONArray
import org.json.JSONObject
import tech.zseven.rish.runtime.*

/** The runtime owns storage/reducer rules. This layer preserves the RN module's request checks. */
internal object WorkspaceRoutes {
    fun workspaces(runtime: AndroidRuntimeState, method: String, args: JSONArray): JSONObject {
        if (method == "getConstants") return JSONObject().put("implemented", RishAgentCoreNative.available)
            .put("removal", RishAgentCoreNative.available).put("folder_picker", false)
        if (!RishAgentCoreNative.available) throw BridgeFailure("E_WORKSPACE_UNAVAILABLE")
        val registry = runtime.workspaces
        if (method == "list") {
            runtime.workspaceRemoval.recover()
            val values = JSONArray()
            for (record in registry.list()) registry.descriptor(record.getString("workspace_id"))?.let(values::put)
            return JSONObject().put("schema_version", 1).put("workspaces", values)
        }
        val request = args.getJSONObject(0)
        return when (method) {
            "create" -> {
                exact(request, "schema_version", "display_name", "operation_id")
                val record = registry.create(text(request, "display_name"), operationId = text(request, "operation_id"))
                registry.descriptor(record.getString("workspace_id")) ?: throw BridgeFailure("E_WORKSPACE_UNAVAILABLE")
            }
            "resolve" -> {
                exact(request, "schema_version", "workspace_id", "expected_binding_revision", "required_capabilities")
                val descriptor = registry.descriptor(text(request, "workspace_id")) ?: throw BridgeFailure("E_WORKSPACE_UNAVAILABLE")
                val expected = request.opt("expected_binding_revision")
                if (expected != null && expected != JSONObject.NULL) {
                    if (expected !is Int) throw BridgeFailure("E_WORKSPACE_INVALID")
                    if (expected != descriptor.optInt("binding_revision")) throw BridgeFailure("E_WORKSPACE_STALE")
                }
                val required = request.getJSONArray("required_capabilities")
                for (index in 0 until required.length()) {
                    val capability = required.get(index)
                    if (capability !is String) throw BridgeFailure("E_WORKSPACE_INVALID")
                    if (!descriptor.getJSONObject("capabilities").optBoolean(capability)) throw BridgeFailure("E_WORKSPACE_CAPABILITY")
                }
                JSONObject().put("schema_version", 1).put("disposition", "direct").put("workspace", descriptor)
            }
            "queryOperation" -> {
                exact(request, "schema_version", "operation_id")
                val receipt = registry.queryOperation(text(request, "operation_id"))
                val result = JSONObject().put("schema_version", 1)
                if (receipt == null) result.put("status", "not_started") else result.put("status", "committed").put("receipt", receipt)
            }
            "forget" -> {
                exact(request, "schema_version", "workspace_id", "expected_binding_revision", "operation_id", "clearance_receipt_id")
                removalFields(request)
                runtime.workspaceRemoval.forget(request)
            }
            "prepareDeleteOwnedContent" -> {
                exact(request, "schema_version", "workspace_id", "expected_binding_revision", "clearance_receipt_id")
                removalFields(request)
                runtime.workspaceRemoval.prepareDelete(request)
            }
            "deleteOwnedContent" -> {
                exact(request, "schema_version", "workspace_id", "expected_binding_revision", "operation_id", "clearance_receipt_id", "confirmation_id")
                removalFields(request)
                if (!RuntimeJson.uuid(text(request, "confirmation_id"))) throw BridgeFailure("E_WORKSPACE_INVALID")
                runtime.workspaceRemoval.deleteOwned(request)
            }
            else -> throw BridgeFailure("E_WORKSPACE_UNAVAILABLE")
        }
    }

    fun files(runtime: AndroidRuntimeState, method: String, args: JSONArray): JSONObject {
        if (method == "getConstants") return JSONObject().put("implemented", RishAgentCoreNative.available)
        if (method in setOf("capabilities", "executePortableToolV2")) throw BridgeFailure("E_WORKSPACE_UNAVAILABLE")
        val request = args.getJSONObject(0)
        return holding(runtime, request) {
            when (method) {
                "listV2" -> runtime.workspaceFiles.list(request)
                "readV2" -> runtime.workspaceFiles.read(request)
                "writeV2" -> runtime.workspaceFiles.write(request)
                "listTrashV2" -> runtime.workspaceFiles.listTrash(request)
                "createDirectoryV2" -> runtime.workspaceFiles.createDirectory(request)
                "renameEntryV2" -> runtime.workspaceFiles.rename(request)
                "trashEntryV2" -> runtime.workspaceFiles.trash(request)
                "restoreFromTrashV2" -> runtime.workspaceFiles.restore(request)
                else -> throw BridgeFailure("E_WORKSPACE_UNAVAILABLE")
            }
        }
    }

    fun projects(runtime: AndroidRuntimeState, method: String, args: JSONArray): JSONObject {
        val available = RishAgentCoreNative.available && RishLibgit2Native.available
        if (method == "getConstants") return JSONObject().put("implemented", available)
        if (!available) throw BridgeFailure("E_PROJECT_NATIVE")
        val request = args.getJSONObject(0)
        // Cancellation may not acquire the lease held by the operation it cancels.
        if (method == "cancelPushV2") return runtime.projectGit.cancelPush(request)
        if (method == "cancelWorkspaceCloneV2") return runtime.workspaceClone.cancel(request)
        val writesWorkingTree = method in setOf(
            "attachWorkspaceProject", "stageAllV2", "commitV2", "setRemoteV2",
            "pullFastForwardV2", "mergeRemoteV2",
        )
        return holding(runtime, request, mutating = writesWorkingTree) {
            when (method) {
                "attachWorkspaceProject" -> runtime.workspaceProjects.attach(request)
                "projectForWorkspaceV2" -> runtime.workspaceProjects.projectFor(request)
                "statusV2" -> runtime.projectGit.status(request)
                "diffV2" -> runtime.projectGit.diff(request)
                "stageAllV2" -> runtime.projectGit.stageAll(request)
                "commitV2" -> runtime.projectGit.commit(request)
                "setRemoteV2" -> runtime.projectGit.setRemote(request)
                "remoteV2" -> runtime.projectGit.remote(request)
                "credentialStatusV2" -> runtime.projectGit.credentialStatus(request)
                "clearCredentialV2" -> runtime.projectGit.clearCredential(request)
                "pushV2" -> runtime.projectGit.push(request)
                "pushReceiptsV2" -> runtime.projectGit.pushReceipts(request)
                "fetchV2" -> runtime.projectGit.fetch(request)
                "pullFastForwardV2" -> runtime.projectGit.pullFastForward(request)
                "mergeRemoteV2" -> runtime.projectGit.mergeRemote(request)
                "cloneWorkspaceV2" -> runtime.workspaceClone.clone(request)
                else -> throw BridgeFailure("E_PROJECT_NATIVE")
            }
        }
    }

    internal fun holding(runtime: AndroidRuntimeState, request: JSONObject, mutating: Boolean = false, body: () -> JSONObject): JSONObject {
        val id = request.optJSONObject("root")?.optString("workspace_id")?.takeIf(RuntimeJson::uuid)
        return when {
            id == null -> body()
            mutating -> runtime.workspaces.mutating(id, body)
            else -> runtime.workspaces.holding(id, body)
        }
    }

    private fun exact(request: JSONObject, vararg keys: String) {
        if (request.keys().asSequence().toSet() != keys.toSet()) throw BridgeFailure("E_WORKSPACE_INVALID")
        RuntimeJson.checkVersion(request, 1)
    }

    private fun text(request: JSONObject, key: String): String =
        (request.opt(key) as? String)?.takeIf(String::isNotEmpty) ?: throw BridgeFailure("E_WORKSPACE_INVALID")

    private fun removalFields(request: JSONObject) {
        for (key in listOf("workspace_id", "clearance_receipt_id", "operation_id")) {
            val value = request.opt(key) ?: continue
            if (value !is String || !RuntimeJson.uuid(value)) throw BridgeFailure("E_WORKSPACE_INVALID")
        }
        val revision = request.opt("expected_binding_revision")
        if (revision !is Int || revision < 1) throw BridgeFailure("E_WORKSPACE_INVALID")
    }
}
