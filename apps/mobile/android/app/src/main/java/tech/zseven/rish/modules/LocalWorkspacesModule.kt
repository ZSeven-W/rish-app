package tech.zseven.rish.modules

import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.ReadableMap
import org.json.JSONArray
import org.json.JSONObject
import tech.zseven.rish.RishUnavailable
import tech.zseven.rish.runtime.AndroidRuntimeState
import tech.zseven.rish.runtime.AndroidWorkspaceRegistry
import tech.zseven.rish.runtime.RishAgentCoreNative
import tech.zseven.rish.runtime.RuntimeJson

/**
 * LocalWorkspaces on Android.
 *
 * Mirrors the iOS registration in modules/rish/ios/Sources/LocalWorkspacesModule.mm
 * and the JS wrapper in apps/mobile/src/native/LocalWorkspaces.ts. Every rule
 * it needs already lives in the shared core and every mechanism already lives
 * in [AndroidWorkspaceRegistry]; this is the wire between them and the bridge,
 * and it decides nothing of its own.
 *
 * A person can make a workspace here and an agent can work inside it: create,
 * list, resolve and the operation query are real. Binding a folder the person
 * chose is not: that needs the Storage Access Framework, whose grants are a
 * different thing from an owned directory, and it keeps refusing until that
 * lands rather than pretending a picker appeared.
 */
class LocalWorkspacesModule(private val react: ReactApplicationContext) :
    ReactContextBaseJavaModule(react) {

    private val runtime by lazy { AndroidRuntimeState.get(react) }
    private val registry: AndroidWorkspaceRegistry get() = runtime.workspaces

    /**
     * Without the core there are no rules to ask, so there is nothing this
     * module could answer honestly. That is the same question LocalGuest asks
     * about its runtime, and the same answer.
     */
    override fun getConstants(): MutableMap<String, Any> =
        mutableMapOf(
            "implemented" to RishAgentCoreNative.available,
            // Forget and delete are real here; JavaScript gates the actions
            // on this rather than finding out after it has already cleared
            // the workspace from the session.
            "removal" to RishAgentCoreNative.available,
        )

    override fun getName(): String = "LocalWorkspaces"

    private fun resolve(promise: Promise, value: JSONObject) =
        promise.resolve(Arguments.makeNativeMap(RuntimeJson.map(value)))

    /**
     * A refusal carries the workspace code JS branches on and no detail: a
     * message could name a directory, and a path is not JavaScript's to see.
     */
    private fun reject(promise: Promise, error: Throwable) {
        val code = (error as? AndroidWorkspaceRegistry.Refused)?.code ?: "E_WORKSPACE_UNAVAILABLE"
        promise.reject(code, code)
    }

    private fun work(promise: Promise, action: () -> JSONObject) {
        runtime.io.execute {
            try {
                if (!RishAgentCoreNative.available) throw AndroidWorkspaceRegistry.Refused(UNAVAILABLE)
                resolve(promise, action())
            } catch (error: Throwable) {
                reject(promise, error)
            }
        }
    }

    /** `exactKeys` on the way in: an unexpected key is a different request. */
    private fun request(value: ReadableMap?, vararg keys: String): JSONObject {
        val map = RuntimeJson.fromBridgeMap(
            (value ?: throw AndroidWorkspaceRegistry.Refused(INVALID)).toHashMap(),
        )
        val present = map.keys().asSequence().toSet()
        if (present != keys.toSet()) throw AndroidWorkspaceRegistry.Refused(INVALID)
        RuntimeJson.checkVersion(map, 1)
        return map
    }

    private fun text(request: JSONObject, key: String): String {
        val value = request.opt(key)
        if (value !is String || value.isEmpty()) throw AndroidWorkspaceRegistry.Refused(INVALID)
        return value
    }

    private fun descriptorOrRefuse(workspaceId: String): JSONObject =
        registry.descriptor(workspaceId) ?: throw AndroidWorkspaceRegistry.Refused(UNAVAILABLE)

    @ReactMethod
    fun list(promise: Promise) = work(promise) {
        // A removal an earlier launch did not finish is finished before the
        // listing, so what is shown is what is there.
        runtime.workspaceRemoval.recover()
        val workspaces = JSONArray()
        // `list` already leaves out every record it cannot still prove, so a
        // descriptor missing here is a record that stopped being provable
        // between the two reads rather than one to report as broken.
        for (record in registry.list()) {
            val id = record.optString("workspace_id")
            registry.descriptor(id)?.let { workspaces.put(it) }
        }
        JSONObject().put("schema_version", 1).put("workspaces", workspaces)
    }

    @ReactMethod
    fun create(request: ReadableMap?, promise: Promise) = work(promise) {
        val fields = request(request, "schema_version", "display_name", "operation_id")
        val record = registry.create(
            displayName = text(fields, "display_name"),
            operationId = text(fields, "operation_id"),
        )
        descriptorOrRefuse(record.getString("workspace_id"))
    }

    /**
     * An owned workspace is always reachable directly: there is no grant to
     * have expired, because the directory is the app's own. A revision the
     * caller did not expect, or a capability this binding does not carry, is
     * refused rather than answered with a descriptor that would mislead.
     */
    @ReactMethod
    fun resolve(request: ReadableMap?, promise: Promise) = work(promise) {
        val fields = request(
            request,
            "schema_version",
            "workspace_id",
            "expected_binding_revision",
            "required_capabilities",
        )
        val descriptor = descriptorOrRefuse(text(fields, "workspace_id"))
        val expected = fields.opt("expected_binding_revision")
        if (expected != null && expected != JSONObject.NULL) {
            if (expected !is Int) throw AndroidWorkspaceRegistry.Refused(INVALID)
            if (expected != descriptor.optInt("binding_revision")) {
                throw AndroidWorkspaceRegistry.Refused(STALE)
            }
        }
        val required = fields.opt("required_capabilities") as? JSONArray
            ?: throw AndroidWorkspaceRegistry.Refused(INVALID)
        val capabilities = descriptor.optJSONObject("capabilities")
            ?: throw AndroidWorkspaceRegistry.Refused(UNAVAILABLE)
        for (index in 0 until required.length()) {
            val capability = required.opt(index)
            if (capability !is String) throw AndroidWorkspaceRegistry.Refused(INVALID)
            if (!capabilities.optBoolean(capability)) {
                throw AndroidWorkspaceRegistry.Refused(CAPABILITY)
            }
        }
        JSONObject().put("schema_version", 1).put("disposition", "direct")
            .put("workspace", descriptor)
    }

    @ReactMethod
    fun queryOperation(request: ReadableMap?, promise: Promise) = work(promise) {
        val fields = request(request, "schema_version", "operation_id")
        // The shape JavaScript parses: a receipt under `committed`, or
        // `not_started` when the operation never happened here.
        val receipt = registry.queryOperation(text(fields, "operation_id"))
        if (receipt == null) JSONObject().put("schema_version", 1).put("status", "not_started")
        else JSONObject().put("schema_version", 1).put("status", "committed").put("receipt", receipt)
    }

    // --- not yet on Android ------------------------------------------------
    //
    // Choosing a folder outside the app needs the Storage Access Framework,
    // and a persisted tree grant is not an owned directory: it can be revoked,
    // it has no POSIX path, and the guest cannot read it the way it reads one.
    // Until that is built these refuse, because a picker that never appeared
    // is not a cancelled picker.

    @ReactMethod
    fun presentFolderPicker(request: ReadableMap?, promise: Promise) = refuseUnbuilt(promise)

    @ReactMethod
    fun importSelection(request: ReadableMap?, promise: Promise) = refuseUnbuilt(promise)

    @ReactMethod
    fun cancelSelection(request: ReadableMap?, promise: Promise) = refuseUnbuilt(promise)

    @ReactMethod
    fun presentRegrantPicker(request: ReadableMap?, promise: Promise) = refuseUnbuilt(promise)

    @ReactMethod
    fun completeRegrant(request: ReadableMap?, promise: Promise) = refuseUnbuilt(promise)

    @ReactMethod
    fun cancelPicker(request: ReadableMap?, promise: Promise) = refuseUnbuilt(promise)

    @ReactMethod
    fun bootstrapLegacyProject(request: ReadableMap?, promise: Promise) = refuseUnbuilt(promise)

    // --- forgetting and deleting -------------------------------------------
    //
    // Both are cleared by the session store first (SessionSnapshots
    // `persistSessionWithWorkspaceClearance`) and carried out by
    // AndroidWorkspaceRemoval under that clearance. The shapes are iOS's
    // exactly; the answer says forgotten or deleted only once it is true.

    @ReactMethod
    fun forget(request: ReadableMap?, promise: Promise) = work(promise) {
        val fields = request(
            request, "schema_version", "workspace_id", "expected_binding_revision",
            "operation_id", "clearance_receipt_id",
        )
        removalFields(fields)
        runtime.workspaceRemoval.forget(fields)
    }

    @ReactMethod
    fun prepareDeleteOwnedContent(request: ReadableMap?, promise: Promise) = work(promise) {
        val fields = request(
            request, "schema_version", "workspace_id", "expected_binding_revision", "clearance_receipt_id",
        )
        removalFields(fields)
        runtime.workspaceRemoval.prepareDelete(fields)
    }

    @ReactMethod
    fun deleteOwnedContent(request: ReadableMap?, promise: Promise) = work(promise) {
        val fields = request(
            request, "schema_version", "workspace_id", "expected_binding_revision",
            "operation_id", "clearance_receipt_id", "confirmation_id",
        )
        removalFields(fields)
        if (!RuntimeJson.uuid(text(fields, "confirmation_id"))) throw AndroidWorkspaceRegistry.Refused(INVALID)
        runtime.workspaceRemoval.deleteOwned(fields)
    }

    /** The ids a removal names are canonical uuids and the revision counts from one. */
    private fun removalFields(fields: JSONObject) {
        for (key in listOf("workspace_id", "clearance_receipt_id", "operation_id")) {
            val value = fields.opt(key) ?: continue
            if (value !is String || !RuntimeJson.uuid(value)) throw AndroidWorkspaceRegistry.Refused(INVALID)
        }
        val revision = fields.opt("expected_binding_revision")
        if (revision !is Int || revision < 1) throw AndroidWorkspaceRegistry.Refused(INVALID)
    }

    private fun refuseUnbuilt(promise: Promise) =
        RishUnavailable.reject("LocalWorkspaces", UNAVAILABLE, promise)

    private companion object {
        const val UNAVAILABLE = "E_WORKSPACE_UNAVAILABLE"
        const val INVALID = "E_WORKSPACE_INVALID"
        const val STALE = "E_WORKSPACE_STALE"
        const val CAPABILITY = "E_WORKSPACE_CAPABILITY"
        const val NOT_FOUND = "E_WORKSPACE_NOT_FOUND"
    }
}
