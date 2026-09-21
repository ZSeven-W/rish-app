package tech.zseven.rish.modules

import android.util.Log
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.ReadableMap
import org.json.JSONObject
import tech.zseven.rish.RishUnavailable
import tech.zseven.rish.runtime.AndroidRuntimeState
import tech.zseven.rish.runtime.AndroidWorkspaceFiles
import tech.zseven.rish.runtime.AndroidWorkspaceRegistry
import tech.zseven.rish.runtime.RuntimeJson

/**
 * LocalWorkspace on Android: what the Files drawer lists and opens.
 *
 * The rules live in [AndroidWorkspaceFiles]: listing, reading, writing,
 * creating directories, renaming, and a recoverable trash. Portable tools and
 * the capability record still reject, because the record asserts a tool set
 * this platform does not have.
 */
class LocalWorkspaceModule(reactContext: ReactApplicationContext) :
    ReactContextBaseJavaModule(reactContext) {

    private val runtime = AndroidRuntimeState.get(reactContext)

    override fun getConstants(): MutableMap<String, Any> = mutableMapOf("implemented" to true)

    override fun getName(): String = "LocalWorkspace"

    /**
     * Not answered here. The capability record asserts a recoverable,
     * listable trash and a set of portable tools; this platform has neither
     * yet, and the reader falls back to its own defaults when the method is
     * absent rather than being told something untrue.
     */
    @ReactMethod
    fun capabilities(promise: Promise) =
        RishUnavailable.reject("LocalWorkspace", "E_WORKSPACE_UNAVAILABLE", promise)

    @ReactMethod
    fun listV2(request: ReadableMap?, promise: Promise) =
        answer("listV2", request, promise) { runtime.workspaceFiles.list(it) }

    @ReactMethod
    fun readV2(request: ReadableMap?, promise: Promise) =
        answer("readV2", request, promise) { runtime.workspaceFiles.read(it) }

    @ReactMethod
    fun writeV2(request: ReadableMap?, promise: Promise) =
        answer("writeV2", request, promise) { runtime.workspaceFiles.write(it) }

    @ReactMethod
    fun listTrashV2(request: ReadableMap?, promise: Promise) =
        answer("listTrashV2", request, promise) { runtime.workspaceFiles.listTrash(it) }

    @ReactMethod
    fun createDirectoryV2(request: ReadableMap?, promise: Promise) =
        answer("createDirectoryV2", request, promise) { runtime.workspaceFiles.createDirectory(it) }

    @ReactMethod
    fun renameEntryV2(request: ReadableMap?, promise: Promise) =
        answer("renameEntryV2", request, promise) { runtime.workspaceFiles.rename(it) }

    @ReactMethod
    fun trashEntryV2(request: ReadableMap?, promise: Promise) =
        answer("trashEntryV2", request, promise) { runtime.workspaceFiles.trash(it) }

    @ReactMethod
    fun restoreFromTrashV2(request: ReadableMap?, promise: Promise) =
        answer("restoreFromTrashV2", request, promise) { runtime.workspaceFiles.restore(it) }

    @ReactMethod
    fun executePortableToolV2(request: ReadableMap?, promise: Promise) =
        RishUnavailable.reject("LocalWorkspace", "E_WORKSPACE_UNAVAILABLE", promise)

    private fun answer(
        operation: String,
        request: ReadableMap?,
        promise: Promise,
        body: (JSONObject?) -> JSONObject,
    ) {
        val captured = try {
            request?.let { JSONObject(it.toHashMap()) }
        } catch (failure: Exception) {
            Log.w(TAG, "$operation request is invalid", failure)
            promise.reject("E_WORKSPACE_INVALID", "Workspace request is invalid")
            return
        }
        val workspaceId = captured?.optJSONObject("root")?.optString("workspace_id")?.takeIf { RuntimeJson.uuid(it) }
        runtime.io.execute {
            try {
                val answered = if (workspaceId == null) body(captured)
                    else runtime.workspaces.holding(workspaceId) { body(captured) }
                promise.resolve(Arguments.makeNativeMap(RuntimeJson.map(answered)))
            } catch (busy: AndroidWorkspaceRegistry.Refused) {
                Log.w(TAG, "$operation refused: ${busy.code}")
                promise.reject(busy.code, "Workspace is being removed")
            } catch (refused: AndroidWorkspaceFiles.Refused) {
                Log.w(TAG, "$operation refused: ${refused.code}")
                promise.reject(refused.code, refused.reason)
            } catch (failure: Exception) {
                Log.w(TAG, "$operation could not be answered", failure)
                promise.reject("E_WORKSPACE_PERSISTENCE", "Workspace could not be read")
            }
        }
    }

    private companion object {
        const val TAG = "RishWorkspace"
    }
}
