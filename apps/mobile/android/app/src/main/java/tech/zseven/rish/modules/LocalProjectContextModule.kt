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
import tech.zseven.rish.runtime.AndroidProjectContextService
import tech.zseven.rish.runtime.AndroidProjectContextSnapshots
import tech.zseven.rish.runtime.AndroidRuntimeState
import tech.zseven.rish.runtime.RishAgentCoreNative
import tech.zseven.rish.runtime.RishLibgit2Native
import tech.zseven.rish.runtime.AndroidWorkspaceRegistry
import tech.zseven.rish.runtime.RuntimeJson

/**
 * LocalProjectContext on Android.
 *
 * Mirrors the iOS registration in modules/rish/ios/Sources/LocalProjectContextModule.mm
 * (RCT_EXPORT_MODULE(LocalProjectContext)) and the JS wrapper in
 * apps/mobile/src/native/LocalProjectContext.ts.
 *
 * [listCandidatesV2] answers through [AndroidProjectContextService]; the
 * snapshot operations -- prepare, confirm, inspect, discard and the verified
 * send -- through [AndroidProjectContextSnapshots]. The v1 methods, which
 * only a legacy iOS project could serve, still reject with "E_CONTEXT_NATIVE".
 */
class LocalProjectContextModule(private val react: ReactApplicationContext) :
    ReactContextBaseJavaModule(react) {

    private val runtime by lazy { AndroidRuntimeState.get(react) }

    override fun getConstants(): MutableMap<String, Any> =
        mutableMapOf("implemented" to (RishAgentCoreNative.available && RishLibgit2Native.available))

    override fun getName(): String = "LocalProjectContext"

    @ReactMethod
    fun listProjectContextCandidates(projectId: String?, query: String?, nextCursor: String?, promise: Promise) = RishUnavailable.reject("LocalProjectContext", "E_CONTEXT_NATIVE", promise)

    @ReactMethod
    fun prepareProjectContext(selection: ReadableMap?, promise: Promise) = RishUnavailable.reject("LocalProjectContext", "E_CONTEXT_NATIVE", promise)

    @ReactMethod
    fun confirmProjectContext(snapshotId: String?, promise: Promise) = RishUnavailable.reject("LocalProjectContext", "E_CONTEXT_NATIVE", promise)

    @ReactMethod
    fun inspectProjectContext(snapshotId: String?, promise: Promise) = RishUnavailable.reject("LocalProjectContext", "E_CONTEXT_NATIVE", promise)

    @ReactMethod
    fun discardProjectContext(snapshotId: String?, promise: Promise) = RishUnavailable.reject("LocalProjectContext", "E_CONTEXT_NATIVE", promise)

    @ReactMethod
    fun listCandidatesV2(request: ReadableMap?, promise: Promise) {
        if (!RishAgentCoreNative.available || !RishLibgit2Native.available) {
            RishUnavailable.reject("LocalProjectContext", "E_CONTEXT_NATIVE", promise)
            return
        }
        val captured = try {
            request?.let { RuntimeJson.fromBridgeMap(it.toHashMap()) }
        } catch (_: Exception) {
            promise.reject("E_CONTEXT_REQUEST_INVALID", "E_CONTEXT_REQUEST_INVALID")
            return
        }
        runtime.io.execute {
            try {
                val page = runtime.projectContext.listCandidates(captured)
                // A count and nothing else: the paths stay on the device. The
                // line tells a listing that came back empty apart from one
                // that never reached this module.
                Log.i(TAG, "listCandidatesV2 answered ${page.optJSONArray("candidates")?.length() ?: -1} candidates")
                promise.resolve(Arguments.makeNativeMap(RuntimeJson.map(page)))
            } catch (refused: AndroidProjectContextService.Refused) {
                // The code and nothing else: a reason could name a path.
                Log.w(TAG, "listCandidatesV2 refused: ${refused.code}")
                promise.reject(refused.code, refused.code)
            } catch (failure: Throwable) {
                Log.w(TAG, "listCandidatesV2 could not be answered", failure)
                promise.reject("E_CONTEXT_NATIVE", "E_CONTEXT_NATIVE")
            }
        }
    }

    @ReactMethod
    fun prepareCandidateV2(request: ReadableMap?, promise: Promise) =
        answer("prepareCandidateV2", request, promise) { runtime.projectSnapshots.prepare(it) }

    @ReactMethod
    fun confirmSnapshotV2(request: ReadableMap?, promise: Promise) =
        answer("confirmSnapshotV2", request, promise) { runtime.projectSnapshots.confirm(it) }

    @ReactMethod
    fun inspectSnapshotV2(request: ReadableMap?, promise: Promise) =
        answer("inspectSnapshotV2", request, promise) { runtime.projectSnapshots.inspect(it) }

    @ReactMethod
    fun discardProjectContextV2(request: ReadableMap?, promise: Promise) =
        answer("discardProjectContextV2", request, promise) { runtime.projectSnapshots.discard(it) }

    /**
     * The envelope is consumed inside native code -- the agent round takes
     * it -- and only its receipt is projected through React Native.
     */
    @ReactMethod
    fun verifiedSendProjectContextV2(request: ReadableMap?, promise: Promise) =
        answer("verifiedSendProjectContextV2", request, promise) { runtime.projectSnapshots.verifiedEnvelope(it, true).second }

    private fun answer(operation: String, request: ReadableMap?, promise: Promise, body: (JSONObject?) -> JSONObject) {
        if (!RishAgentCoreNative.available || !RishLibgit2Native.available) {
            RishUnavailable.reject("LocalProjectContext", "E_CONTEXT_NATIVE", promise)
            return
        }
        val captured = try {
            request?.let { RuntimeJson.fromBridgeMap(it.toHashMap()) }
        } catch (_: Exception) {
            promise.reject("E_CONTEXT_REQUEST_INVALID", "E_CONTEXT_REQUEST_INVALID")
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
                promise.reject(busy.code, busy.code)
            } catch (refused: AndroidProjectContextSnapshots.Refused) {
                // The code and nothing else: a reason could name a path.
                Log.w(TAG, "$operation refused: ${refused.code}")
                promise.reject(refused.code, refused.code)
            } catch (failure: Throwable) {
                Log.w(TAG, "$operation could not be answered", failure)
                promise.reject("E_CONTEXT_NATIVE", "E_CONTEXT_NATIVE")
            }
        }
    }

    private companion object {
        const val TAG = "RishProjectContext"
    }
}
