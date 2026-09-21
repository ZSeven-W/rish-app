package tech.zseven.rish.modules

import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.UiThreadUtil
import java.util.concurrent.Executors
import org.json.JSONObject
import tech.zseven.rish.RishUnavailable
import tech.zseven.rish.runtime.AndroidRuntimeState
import tech.zseven.rish.runtime.AndroidWorkspaceProjects
import tech.zseven.rish.runtime.RishAgentCoreNative
import tech.zseven.rish.runtime.RishLibgit2Native
import tech.zseven.rish.runtime.RuntimeJson

/**
 * LocalProjects on Android.
 *
 * Mirrors the iOS registration in modules/rish/ios/Sources/LocalProjectsModule.mm
 * (RCT_EXPORT_MODULE(LocalProjects)) and the JS wrapper in
 * apps/mobile/src/native/LocalProjects.ts.
 *
 * [projectForWorkspaceV2] and [attachWorkspaceProject] answer, through
 * [AndroidWorkspaceProjects]: whether a git project is attached to a workspace
 * root, and attaching one. That is what turns a bound working directory into
 * something the project context can list. The git panel's local operations
 * -- [statusV2], [diffV2], [stageAllV2], [commitV2] -- and its remote half
 * -- [setRemoteV2], [remoteV2], [credentialStatusV2],
 * [presentCredentialPromptV2], [clearCredentialV2], [pushV2], [cancelPushV2],
 * [fetchV2], [pullFastForwardV2]
 * -- answer through [tech.zseven.rish.runtime.AndroidProjectGit].
 *
 * Everything else still rejects with the JS-recognized "E_PROJECT_NATIVE"; no
 * success is stubbed anywhere, and nothing here pretends a repository exists.
 */
class LocalProjectsModule(private val react: ReactApplicationContext) :
    ReactContextBaseJavaModule(react) {

    private val runtime by lazy { AndroidRuntimeState.get(react) }

    override fun getConstants(): MutableMap<String, Any> =
        mutableMapOf("implemented" to (RishAgentCoreNative.available && RishLibgit2Native.available))

    override fun getName(): String = "LocalProjects"

    @ReactMethod
    fun list(promise: Promise) = RishUnavailable.reject("LocalProjects", "E_PROJECT_NATIVE", promise)

    @ReactMethod
    fun create(name: String?, promise: Promise) = RishUnavailable.reject("LocalProjects", "E_PROJECT_NATIVE", promise)

    @ReactMethod
    fun clone(url: String?, name: String?, options: ReadableMap?, promise: Promise) = RishUnavailable.reject("LocalProjects", "E_PROJECT_NATIVE", promise)

    @ReactMethod
    fun status(projectId: String?, promise: Promise) = RishUnavailable.reject("LocalProjects", "E_PROJECT_NATIVE", promise)

    @ReactMethod
    fun diff(projectId: String?, options: ReadableMap?, promise: Promise) = RishUnavailable.reject("LocalProjects", "E_PROJECT_NATIVE", promise)

    @ReactMethod
    fun stageAll(projectId: String?, promise: Promise) = RishUnavailable.reject("LocalProjects", "E_PROJECT_NATIVE", promise)

    @ReactMethod
    fun commit(projectId: String?, input: ReadableMap?, promise: Promise) = RishUnavailable.reject("LocalProjects", "E_PROJECT_NATIVE", promise)

    @ReactMethod
    fun setRemote(projectId: String?, url: String?, promise: Promise) = RishUnavailable.reject("LocalProjects", "E_PROJECT_NATIVE", promise)

    @ReactMethod
    fun credentialStatus(projectId: String?, promise: Promise) = RishUnavailable.reject("LocalProjects", "E_PROJECT_NATIVE", promise)

    @ReactMethod
    fun presentCredentialPrompt(projectId: String?, locale: String?, promise: Promise) = RishUnavailable.reject("LocalProjects", "E_PROJECT_NATIVE", promise)

    @ReactMethod
    fun clearCredential(projectId: String?, promise: Promise) = RishUnavailable.reject("LocalProjects", "E_PROJECT_NATIVE", promise)

    @ReactMethod
    fun push(projectId: String?, options: ReadableMap?, promise: Promise) = RishUnavailable.reject("LocalProjects", "E_PROJECT_NATIVE", promise)

    @ReactMethod
    fun attachWorkspaceProject(request: ReadableMap?, promise: Promise) =
        answer("attachWorkspaceProject", request, promise) { runtime.workspaceProjects.attach(it) }

    @ReactMethod
    fun projectForWorkspaceV2(request: ReadableMap?, promise: Promise) =
        answer("projectForWorkspaceV2", request, promise) { runtime.workspaceProjects.projectFor(it) }

    /**
     * A refusal carries the stable code the shared rule maps iOS's number to,
     * and no detail: a message could name a directory, and a path is not
     * JavaScript's to see. Anything else is the native failure JS already
     * knows how to sanitize.
     */
    private fun answer(
        operation: String,
        request: ReadableMap?,
        promise: Promise,
        executor: java.util.concurrent.Executor = runtime.io,
        body: (JSONObject?) -> JSONObject,
    ) {
        val captured = captured(request, promise) ?: return
        executor.execute { settle(operation, promise) { body(captured) } }
    }

    /** The request as JSON, or null after the promise has been rejected for it. */
    private fun captured(request: ReadableMap?, promise: Promise): JSONObject? {
        if (!RishAgentCoreNative.available || !RishLibgit2Native.available) {
            RishUnavailable.reject("LocalProjects", "E_PROJECT_NATIVE", promise)
            return null
        }
        return try {
            request?.let { RuntimeJson.fromBridgeMap(it.toHashMap()) } ?: JSONObject()
        } catch (_: Exception) {
            promise.reject("E_PROJECT_REQUEST_INVALID", "E_PROJECT_REQUEST_INVALID")
            null
        }
    }

    private fun settle(operation: String, promise: Promise, body: () -> JSONObject) {
        try {
            promise.resolve(Arguments.makeNativeMap(RuntimeJson.map(body())))
        } catch (refused: AndroidWorkspaceProjects.Refused) {
            android.util.Log.w(TAG, "$operation refused: ${refused.number}")
            promise.reject(refused.code, refused.code)
        } catch (failure: Throwable) {
            android.util.Log.w(TAG, "$operation could not be answered", failure)
            promise.reject("E_PROJECT_NATIVE", "E_PROJECT_NATIVE")
        }
    }

    /** A cancel must not queue behind the push it cancels, so it has a thread of its own. */
    private val cancels by lazy { Executors.newSingleThreadExecutor() }

    @ReactMethod
    fun prepareProjectDetachV1(request: ReadableMap?, promise: Promise) = RishUnavailable.reject("LocalProjects", "E_PROJECT_NATIVE", promise)

    @ReactMethod
    fun commitProjectDetachV1(request: ReadableMap?, promise: Promise) = RishUnavailable.reject("LocalProjects", "E_PROJECT_NATIVE", promise)

    @ReactMethod
    fun statusV2(request: ReadableMap?, promise: Promise) =
        answer("statusV2", request, promise) { runtime.projectGit.status(it) }

    @ReactMethod
    fun diffV2(request: ReadableMap?, promise: Promise) =
        answer("diffV2", request, promise) { runtime.projectGit.diff(it) }

    @ReactMethod
    fun stageAllV2(request: ReadableMap?, promise: Promise) =
        answer("stageAllV2", request, promise) { runtime.projectGit.stageAll(it) }

    @ReactMethod
    fun commitV2(request: ReadableMap?, promise: Promise) =
        answer("commitV2", request, promise) { runtime.projectGit.commit(it) }

    @ReactMethod
    fun setRemoteV2(request: ReadableMap?, promise: Promise) =
        answer("setRemoteV2", request, promise) { runtime.projectGit.setRemote(it) }

    @ReactMethod
    fun remoteV2(request: ReadableMap?, promise: Promise) =
        answer("remoteV2", request, promise) { runtime.projectGit.remote(it) }

    @ReactMethod
    fun credentialStatusV2(request: ReadableMap?, promise: Promise) =
        answer("credentialStatusV2", request, promise) { runtime.projectGit.credentialStatus(it) }

    /**
     * The prompt is native end to end: the origin is read first so the dialog
     * can name its host, the person types into the dialog, and what they
     * typed goes straight into the credential store. JS receives the status.
     */
    @ReactMethod
    fun presentCredentialPromptV2(request: ReadableMap?, promise: Promise) {
        val captured = captured(request, promise) ?: return
        runtime.io.execute {
            val scope = try {
                runtime.projectGit.promptScope(captured)
            } catch (refused: AndroidWorkspaceProjects.Refused) {
                android.util.Log.w(TAG, "presentCredentialPromptV2 refused: ${refused.number}")
                promise.reject(refused.code, refused.code); return@execute
            } catch (failure: Throwable) {
                android.util.Log.w(TAG, "presentCredentialPromptV2 could not be answered", failure)
                promise.reject("E_PROJECT_NATIVE", "E_PROJECT_NATIVE"); return@execute
            }
            val host = scope.getString("host")
            UiThreadUtil.runOnUiThread {
                AndroidGitCredentialPrompt.present(
                    react.currentActivity, host, scope.getBoolean("chinese"), scope.getBoolean("plaintext"),
                ) { username, token, expiry, failure ->
                    if (failure != null || username == null || token == null) {
                        val number = if (failure == "presentation") AndroidWorkspaceProjects.UNAVAILABLE else CANCELLED
                        promise.reject(AndroidWorkspaceProjects.codeFor(number), AndroidWorkspaceProjects.codeFor(number))
                        return@present
                    }
                    runtime.io.execute {
                        settle("presentCredentialPromptV2", promise) {
                            runtime.projectGit.storeCredential(
                                JSONObject().put("schema_version", 1).put("root", captured.opt("root")).put("host", host)
                                    .put("username", username).put("token", token).put("expiry_seconds", expiry),
                            )
                        }
                    }
                }
            }
        }
    }

    @ReactMethod
    fun clearCredentialV2(request: ReadableMap?, promise: Promise) =
        answer("clearCredentialV2", request, promise) { runtime.projectGit.clearCredential(it) }

    @ReactMethod
    fun pushV2(request: ReadableMap?, promise: Promise) =
        answer("pushV2", request, promise) { runtime.projectGit.push(it) }

    @ReactMethod
    fun cloneWorkspaceV2(request: ReadableMap?, promise: Promise) =
        answer("cloneWorkspaceV2", request, promise) { runtime.workspaceClone.clone(it) }

    @ReactMethod
    fun cancelWorkspaceCloneV2(request: ReadableMap?, promise: Promise) =
        answer("cancelWorkspaceCloneV2", request, promise, cancels) { runtime.workspaceClone.cancel(it) }

    @ReactMethod
    fun pushReceiptsV2(request: ReadableMap?, promise: Promise) =
        answer("pushReceiptsV2", request, promise) { runtime.projectGit.pushReceipts(it) }

    @ReactMethod
    fun fetchV2(request: ReadableMap?, promise: Promise) =
        answer("fetchV2", request, promise) { runtime.projectGit.fetch(it) }

    @ReactMethod
    fun pullFastForwardV2(request: ReadableMap?, promise: Promise) =
        answer("pullFastForwardV2", request, promise) { runtime.projectGit.pullFastForward(it) }

    @ReactMethod
    fun cancelPushV2(request: ReadableMap?, promise: Promise) =
        answer("cancelPushV2", request, promise, cancels) { runtime.projectGit.cancelPush(it) }

    private companion object {
        const val TAG = "RishProjects"
        const val CANCELLED = 3195
    }
}
