package tech.zseven.rish.gpui

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject
import tech.zseven.rish.runtime.AndroidRuntimeState
import tech.zseven.rish.runtime.RishAgentCoreNative
import tech.zseven.rish.runtime.RuntimeJson
import java.util.UUID

/** Durable app ownership is an ID, never a display-name lookup. */
internal object DefaultWorkspace {
    @Synchronized
    fun ensure(runtime: AndroidRuntimeState, args: JSONArray): JSONObject {
        if (!RishAgentCoreNative.available) throw BridgeFailure("E_WORKSPACE_UNAVAILABLE")
        val request = args.optJSONObject(0)
        if (args.length() != 1 || request == null || request.keys().asSequence().toSet() != setOf("display_name") ||
            request.opt("display_name") !is String) throw BridgeFailure("E_BRIDGE_ARGUMENTS")
        val name = NamePromptValidation.evaluate(request.getString("display_name"), "workspace")
        if (!name.canSubmit) throw BridgeFailure("E_WORKSPACE_INVALID")
        runtime.workspaceRemoval.recover()
        val preferences = runtime.app.getSharedPreferences("rish_gpui_default_workspace", Context.MODE_PRIVATE)
        val store = SharedPreferencesDefaultWorkspaceStore(preferences)
        store.read().pending?.let { pending ->
            val savedName = NamePromptValidation.evaluate(pending.name, "workspace")
            if (!savedName.canSubmit || savedName.value != pending.name) throw BridgeFailure("E_WORKSPACE_CORRUPT")
        }
        return DefaultWorkspaceCoordinator(
            store,
            resolve = runtime.workspaces::descriptor,
            create = { pending ->
                runtime.workspaces.create(pending.name, workspaceId = pending.workspaceId,
                    now = pending.createdAt, operationId = pending.operationId)
            },
        ).ensure(name.value)
    }
}

internal data class PendingDefaultWorkspace(
    val workspaceId: String, val operationId: String, val name: String, val createdAt: String,
)
internal data class DefaultWorkspaceState(
    val workspaceId: String? = null, val pending: PendingDefaultWorkspace? = null,
)
internal interface DefaultWorkspaceStore {
    fun read(): DefaultWorkspaceState
    /** Implementations must durably publish the entire value before returning true. */
    fun write(state: DefaultWorkspaceState): Boolean
}

/** Injectable persistence/registry boundary lets crash recovery run without any user's data. */
internal class DefaultWorkspaceCoordinator(
    private val store: DefaultWorkspaceStore,
    private val resolve: (String) -> JSONObject?,
    private val create: (PendingDefaultWorkspace) -> JSONObject,
    private val newId: () -> String = { UUID.randomUUID().toString() },
    private val now: () -> String = RuntimeJson::now,
) {
    fun ensure(displayName: String): JSONObject {
        val state = store.read()
        state.workspaceId?.let { id ->
            if (!RuntimeJson.uuid(id) || state.pending != null) corrupt()
            return usable(resolve(id), id)
        }
        val pending = state.pending ?: PendingDefaultWorkspace(newId(), newId(), displayName, now())
        validate(pending)
        // Recommit retries too: SharedPreferences can update its memory map even
        // when commit() reports a failed disk write. Creation always requires a
        // successful durable write of both identities and the original request.
        persist(DefaultWorkspaceState(pending = pending))
        val existing = resolve(pending.workspaceId)
        val descriptor = if (existing != null) usable(existing, pending.workspaceId) else {
            val record = create(pending)
            if (record.optString("workspace_id") != pending.workspaceId) corrupt()
            usable(resolve(pending.workspaceId), pending.workspaceId)
        }
        // If this write fails, the durable pending ID resolves the same published registry record.
        persist(DefaultWorkspaceState(workspaceId = pending.workspaceId))
        return descriptor
    }

    private fun usable(descriptor: JSONObject?, id: String): JSONObject {
        if (descriptor == null || descriptor.opt("schema_version") != 2 ||
            descriptor.optString("workspace_id") != id || descriptor.optString("status") != "ok" ||
            descriptor.optJSONObject("capabilities")?.optBoolean("read") != true ||
            descriptor.optJSONObject("capabilities")?.optBoolean("write") != true)
            throw BridgeFailure("E_WORKSPACE_DEFAULT_UNAVAILABLE")
        return descriptor
    }
    private fun validate(pending: PendingDefaultWorkspace) {
        if (!RuntimeJson.uuid(pending.workspaceId) || !RuntimeJson.uuid(pending.operationId) ||
            pending.createdAt.isEmpty()) corrupt()
    }
    private fun persist(value: DefaultWorkspaceState) {
        if (!store.write(value)) throw BridgeFailure("E_WORKSPACE_PERSISTENCE")
    }
    private fun corrupt(): Nothing = throw BridgeFailure("E_WORKSPACE_CORRUPT")
}

private class SharedPreferencesDefaultWorkspaceStore(private val preferences: SharedPreferences) : DefaultWorkspaceStore {
    override fun read(): DefaultWorkspaceState {
        val all = preferences.all
        if (all.isEmpty()) return DefaultWorkspaceState()
        if (all["schema_version"] != 1) corrupt()
        fun string(key: String) = all[key] as? String ?: corrupt()
        if ("workspace_id" in all) {
            if (all.keys != setOf("schema_version", "workspace_id")) corrupt()
            return DefaultWorkspaceState(workspaceId = string("workspace_id"))
        }
        if (all.keys != setOf("schema_version", "pending_workspace_id", "pending_operation_id", "pending_name", "pending_created_at")) corrupt()
        return DefaultWorkspaceState(pending = PendingDefaultWorkspace(string("pending_workspace_id"),
            string("pending_operation_id"), string("pending_name"), string("pending_created_at")))
    }
    override fun write(state: DefaultWorkspaceState): Boolean = preferences.edit().clear().putInt("schema_version", 1).apply {
        state.workspaceId?.let { putString("workspace_id", it) }
        state.pending?.let {
            putString("pending_workspace_id", it.workspaceId)
            putString("pending_operation_id", it.operationId)
            putString("pending_name", it.name)
            putString("pending_created_at", it.createdAt)
        }
    }.commit()
    private fun corrupt(): Nothing = throw BridgeFailure("E_WORKSPACE_CORRUPT")
}
