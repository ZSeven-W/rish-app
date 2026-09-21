package tech.zseven.rish.modules

import com.facebook.react.bridge.*
import android.util.Log
import tech.zseven.rish.RishUnavailable
import tech.zseven.rish.runtime.AndroidRuntimeState
import tech.zseven.rish.runtime.RuntimeJson
import org.json.JSONObject

/** Opaque chat snapshots with atomic CAS, and the workspace clearance the same store issues. */
class SessionSnapshotsModule(react: ReactApplicationContext) : ReactContextBaseJavaModule(react) {
    private val runtime = AndroidRuntimeState.get(react)
    override fun getName() = "SessionSnapshots"
    private fun run(promise: Promise, operation: () -> JSONObject) {
        runtime.io.execute {
            try { promise.resolve(Arguments.makeNativeMap(RuntimeJson.map(operation()))) }
            catch (failure: Exception) {
                // The code JavaScript branches on is deliberately opaque, but a
                // storage refusal that leaves no trace anywhere is a session
                // spent guessing which rule said no.
                Log.w(TAG, "session snapshot operation refused", failure)
                promise.reject("E_SESSION_NATIVE", "Session snapshot operation failed")
            }
        }
    }
    private fun capture(request: ReadableMap?): String {
        requireNotNull(request)
        val json = JSONObject(request.toHashMap()).toString()
        require(json.toByteArray(Charsets.UTF_8).size <= 20 * 1024 * 1024)
        return json
    }
    @ReactMethod fun loadSessionSnapshot(promise: Promise) = run(promise) { runtime.loadSnapshot() }
    @ReactMethod fun casPersistSession(request: ReadableMap?, promise: Promise) {
        try { val captured = capture(request); run(promise) { runtime.sessions.persist(JSONObject(captured)) } }
        catch (failure: Exception) {
            Log.w(TAG, "session persist request refused", failure)
            promise.reject("E_SESSION_NATIVE", "Invalid session request")
        }
    }
    @ReactMethod fun querySessionCommit(request: ReadableMap?, promise: Promise) {
        try { val captured = capture(request); run(promise) { runtime.sessions.query(JSONObject(captured)) } }
        catch (_: Exception) { promise.reject("E_SESSION_NATIVE", "Invalid session request") }
    }
    private companion object { const val TAG = "RishSession" }

    @ReactMethod fun persistSessionWithWorkspaceClearance(request: ReadableMap?, promise: Promise) {
        try {
            val captured = capture(request)
            run(promise) { runtime.sessions.persistWithClearance(JSONObject(captured), runtime.workspaceRemoval) }
        } catch (failure: Exception) {
            Log.w(TAG, "session clearance request refused", failure)
            promise.reject("E_SESSION_NATIVE", "Invalid session request")
        }
    }
    @ReactMethod fun queryWorkspaceClearance(request: ReadableMap?, promise: Promise) {
        try { val captured = capture(request); run(promise) { runtime.sessions.queryClearance(JSONObject(captured)) } }
        catch (_: Exception) { promise.reject("E_SESSION_NATIVE", "Invalid session request") }
    }
}
