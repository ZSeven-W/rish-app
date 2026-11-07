package tech.zseven.rish.gpui

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import org.json.JSONArray
import org.json.JSONObject
import tech.zseven.rish.runtime.*
import tech.zseven.rish.tasks.TaskExperience
import java.lang.ref.WeakReference
import java.util.concurrent.Executors

/** JSON-only JNI boundary; credentials and filesystem authority stay in native services. */
object RishGpuiBridge {
    private var screen = WeakReference<Activity>(null)
    @Volatile private var application: Context? = null
    private val main = Handler(Looper.getMainLooper())
    private val cancellation = Executors.newSingleThreadExecutor()

    @JvmStatic fun initialize(context: Context) {
        application = context.applicationContext
        TaskExperience.initialize(context)
        bindTaskEvents()
    }

    internal fun bindTaskEvents(sink: (String, JSONObject) -> Unit = ::publish) {
        TaskExperience.emit = { sink("taskExperienceAction", JSONObject(it)) }
        TaskExperience.emitLifecycle = { foreground ->
            sink("taskExperienceLifecycle", JSONObject().put("schema_version", 1).put("foreground", foreground))
        }
    }

    @JvmStatic fun attach(activity: Activity) {
        initialize(activity.applicationContext)
        screen = WeakReference(activity)
        NativeInlineComposer.attach(activity)
        TaskExperience.open(activity.intent)
    }

    @JvmStatic fun resume(activity: Activity) {
        if (screen.get() === activity) TaskExperience.resume()
    }

    @JvmStatic fun pause(activity: Activity) {
        if (screen.get() === activity) TaskExperience.pause()
    }

    @JvmStatic fun openTask(activity: Activity, intent: Intent?) {
        if (screen.get() === activity) TaskExperience.open(intent)
    }

    @JvmStatic fun permissionResult(activity: Activity, requestCode: Int) =
        TaskExperienceRoutes.permissionResult(activity, requestCode)

    @JvmStatic fun detach(activity: Activity) {
        ShellAvatarPicker.detachOwner(activity)
        TaskExperienceRoutes.detach(activity)
        NativeInlineComposer.detach(activity)
        NativePrompts.dismissName(activity)
        NativePrompts.dismissFileEditor(activity)
        NativePrompts.dismissGitForm(activity)
        if (screen.get() === activity) screen.clear()
    }

    // Rust exports Java_tech_zseven_rish_gpui_RishGpuiBridge_{reply,event}.
    @JvmStatic external fun reply(id: Long, json: String, rejected: Boolean)
    @JvmStatic external fun event(name: String, json: String)

    internal fun publish(name: String, value: JSONObject) {
        // A dropped display-only preview must never fail a durable provider round.
        try { event(name, value.toString()) } catch (_: UnsatisfiedLinkError) { }
    }

    @JvmStatic fun dispatch(id: Long, module: String, method: String, argsJson: String) {
        try {
            val args = BridgeProtocol.arguments(argsJson)
            val context = application ?: throw BridgeFailure("E_BRIDGE_NOT_ATTACHED")
            if (module == "ShellAssistant" && method == "pickAvatar") {
                main.post {
                    settle(id) {
                        ShellAvatarPicker.present(screen.get(), args) { result ->
                            result.fold(onSuccess = { answer(id, it) }, onFailure = { reject(id, it) })
                        }
                        Deferred
                    }
                }
                return
            }
            if (module in setOf("ShellAssistant", "ShellRuntimeEngines", "TaskExperience")) {
                // Control/lifecycle requests must not wait behind a provider call on runtime.io.
                main.post {
                    settle(id) {
                        val value = routePlatform(context, screen.get(), module, method, args) { answer(id, it) }
                        if (value === TaskExperienceRoutes.Pending) Deferred else value
                    }
                }
                return
            }
            val runtime = AndroidRuntimeState.get(context)
            runtime.roundPreview = { publish("agentRoundPreview", it) }
            if (HarnessAuthorizationRoutes.handles(module, method)) {
                val request = HarnessAuthorizationRoutes.request(args)
                val owner = screen.get()
                runtime.io.execute {
                    settle(id) {
                        runtime.subscriptionAuth.withAuthorizationStatus(request.harnessId) {
                            HarnessAuthorizationRoutes.resolve(request, it)
                        }
                        main.post {
                            settle(id) {
                                if (owner == null || screen.get() !== owner || owner.isFinishing || owner.isDestroyed) {
                                    throw BridgeFailure("E_AUTH_BROWSER_UNAVAILABLE")
                                }
                                runtime.subscriptionAuth.withAuthorizationStatus(request.harnessId) {
                                    HarnessAuthorizationRoutes.open(request, it) { url ->
                                        owner.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))
                                            .addCategory(Intent.CATEGORY_BROWSABLE))
                                    }
                                }
                            }
                        }
                        Deferred
                    }
                }
                return
            }
            if (module == "ShellInput" && method in setOf("inlineSync", "inlineWait", "inlineSnapshot", "inlineClose", "inlineClearIfUnchanged")) {
                val inlineActivity = screen.get()
                main.post {
                    settle(id) {
                        when (method) {
                            "inlineSync" -> NativeInlineComposer.sync(inlineActivity, args)
                            "inlineSnapshot" -> NativeInlineComposer.snapshot(args)
                            "inlineClose" -> NativeInlineComposer.close(args)
                            "inlineClearIfUnchanged" -> NativeInlineComposer.clearIfUnchanged(args)
                            else -> {
                                NativeInlineComposer.wait(args) { value -> answer(id, value) }
                                Deferred
                            }
                        }
                    }
                }
                return
            }
            if (module == "ShellInput" && method in setOf("edit", "name", "editFile", "gitForm")) {
                main.post {
                    settle(id) {
                        when (method) {
                            "gitForm" -> NativePrompts.gitForm(screen.get(), args) { answer(id, it) }
                            "name" -> NativePrompts.name(screen.get(), args) { answer(id, it) }
                            "editFile" -> NativePrompts.editFile(screen.get(), args) { answer(id, it) }
                            else -> NativePrompts.edit(screen.get(), args) { answer(id, it) }
                        }
                        Deferred
                    }
                }
                return
            }
            if (module == "LocalRuntime" && method in setOf("presentCredentialPrompt", "presentCredentialPromptForSlot", "presentHarnessLoginCode")) {
                main.post { settle(id) { NativePrompts.runtime(screen.get(), runtime, method, args, id); Deferred } }
                return
            }
            if (module == "LocalRuntime" && method == "presentCustomProviderCredentialPrompt") {
                val request = args.getJSONObject(0)
                val scope = runtime.customProviders.credentialScope(request)
                main.post { settle(id) { NativePrompts.customProvider(screen.get(), runtime, scope, request.optString("locale"), id); Deferred } }
                return
            }
            if (module == "LocalProjects" && method in setOf("presentCredentialPromptV2", "presentCloneCredentialPromptV2")) {
                runtime.io.execute {
                    settle(id) {
                        val request = args.getJSONObject(0)
                        val clone = method == "presentCloneCredentialPromptV2"
                        val scope = if (clone) runtime.workspaceClone.promptScope(request) else runtime.projectGit.promptScope(request)
                        main.post { settle(id) { NativePrompts.git(screen.get(), runtime, request, scope, clone, id); Deferred } }
                        Deferred
                    }
                }
                return
            }
            if (module == "LocalRuntime" && method in setOf("completeV2", "completeV2Stream")) {
                // Reservation precedes enqueueing so an immediate cancel cannot be lost.
                val prepared = runtime.transport.prepare(args.getString(0))
                runtime.io.execute {
                    settle(id) {
                        val sink: ((JSONObject) -> Unit)? = if (method == "completeV2Stream") ({ preview ->
                            publish("completionPreview", JSONObject(preview.toString()).put("request_id", prepared.id))
                        }) else null
                        runtime.transport.execute(prepared, sink)
                    }
                }
                return
            }
            val isCancellation = method in setOf(
                "cancelProviderModelDiscovery", "cancelCustomProviderModelDiscovery", "cancelCompletion",
                "cancel_agent_attempt", "cancelPushV2", "cancelWorkspaceCloneV2",
            )
            val executor = if (isCancellation) cancellation else runtime.io
            executor.execute { settle(id) { route(runtime, module, method, args) } }
        } catch (failure: Throwable) { reject(id, failure) }
    }

    internal fun routePlatform(
        context: Context, activity: Activity?, module: String, method: String, args: JSONArray,
        permissionReply: (JSONObject) -> Unit,
    ): Any = when (module) {
        "ShellAssistant" -> ShellAssistantRoutes.call(context, method, args)
        "ShellRuntimeEngines" -> ShellRuntimeEnginesRoutes.call(method, args,
            AndroidSubscriptionAuthProcessFactory(context)::available)
        "TaskExperience" -> TaskExperienceRoutes.call(activity, method, args, permissionReply)
        else -> throw BridgeFailure("E_BRIDGE_UNAVAILABLE")
    }

    private fun route(runtime: AndroidRuntimeState, module: String, method: String, args: JSONArray): Any? = when (module) {
        "LocalRuntime" -> RuntimeRoutes.call(runtime, method, args)
        "SessionSnapshots" -> when (method) {
            "loadSessionSnapshot" -> runtime.loadSnapshot()
            "casPersistSession", "compareAndSwapSessionSnapshot" -> runtime.transport.withProviderLock { runtime.sessions.persist(args.getJSONObject(0)) }
            "querySessionCommit" -> runtime.sessions.query(args.getJSONObject(0))
            "persistSessionWithWorkspaceClearance" -> runtime.transport.withProviderLock { runtime.sessions.persistWithClearance(args.getJSONObject(0), runtime.workspaceRemoval) }
            "queryWorkspaceClearance" -> runtime.sessions.queryClearance(args.getJSONObject(0))
            else -> throw BridgeFailure("E_SESSION_UNAVAILABLE")
        }
        "ShellWorkspace" -> when (method) {
            "ensureDefault" -> DefaultWorkspace.ensure(runtime, args)
            else -> throw BridgeFailure("E_BRIDGE_UNAVAILABLE")
        }
        "LocalWorkspaces" -> WorkspaceRoutes.workspaces(runtime, method, args)
        "LocalWorkspace" -> WorkspaceRoutes.files(runtime, method, args)
        "LocalProjects" -> WorkspaceRoutes.projects(runtime, method, args)
        "LocalProjectContext" -> AgentRoutes.context(runtime, method, args)
        "AgentRuntime" -> AgentRoutes.agent(runtime, method, args)
        "AgentPolicy" -> when (method) {
            "describe" -> runtime.agentPolicy.describe(args.getJSONObject(0))
            "getConstants" -> JSONObject().put("implemented", RishAgentCoreNative.available)
            else -> throw BridgeFailure("E_AGENT_UNAVAILABLE")
        }
        else -> throw BridgeFailure("E_BRIDGE_UNAVAILABLE")
    }

    internal fun settle(id: Long, body: () -> Any?) {
        try { val value = body(); if (value !== Deferred) answer(id, value) }
        catch (failure: Throwable) { reject(id, failure) }
    }

    internal fun answer(id: Long, value: Any?) = reply(id, BridgeProtocol.encode(value), false)

    internal fun reject(id: Long, failure: Throwable) {
        val code = BridgeProtocol.failureCode(failure)
        reply(id, JSONObject().put("code", code)
            .put("message", BridgeProtocol.failureMessage(failure, code)).toString(), true)
    }

    private object Deferred
}

internal class BridgeFailure(val code: String) : Exception(code)

internal object BridgeProtocol {
    fun failureMessage(error: Throwable, code: String): String {
        // Exception text may contain credentials. Only expose the generated,
        // bounded recovery location from the workspace writer, never raw text.
        if (error !is AndroidWorkspaceFiles.Refused || code != "E_WORKSPACE_CONFLICT") return code
        val match = Regex("File changed concurrently; a recoverable version remains at (\\.rish-file-recovery/rish-edit-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})")
            .matchEntire(error.reason) ?: return code
        return "Recovery copy preserved: ${match.groupValues[1]}"
    }

    fun arguments(text: String): JSONArray {
        if (text.toByteArray(Charsets.UTF_8).size > 20 * 1024 * 1024) throw BridgeFailure("E_BRIDGE_ARGUMENTS")
        return JSONArray(text)
    }

    fun encode(value: Any?): String = when (value) {
        null, JSONObject.NULL -> "null"
        is String -> JSONObject.quote(value)
        is JSONObject, is JSONArray, is Boolean, is Number -> value.toString()
        else -> throw BridgeFailure("E_BRIDGE_RESULT")
    }

    fun failureCode(error: Throwable): String {
        val code = when (error) {
            is BridgeFailure -> error.code
            is RuntimeFailure -> error.code
            is AndroidWorkspaceProjects.Refused -> error.code
            is AndroidWorkspaceRegistry.Refused -> error.code
            is AndroidWorkspaceFiles.Refused -> error.code
            is AndroidProjectContextService.Refused -> error.code
            is AndroidProjectContextSnapshots.Refused -> error.code
            is AndroidPreparedAttemptStore.Refused -> error.code
            is AndroidAgentProviderRoundService.Refused -> error.code
            is AndroidAgentToolBatchService.Refused -> error.code
            is AndroidAgentToolExecutionService.Refused -> error.code
            is AndroidAgentApprovalService.Refused -> error.code
            is AndroidAgentLifecycleService.Refused -> error.code
            is AndroidAgentCancelService.Refused -> error.code
            is AndroidAgentQueryService.Refused -> error.code
            is AndroidAgentRecoveryService.Refused -> error.code
            is AndroidAgentPolicyService.Refused -> error.code
            is IllegalArgumentException, is org.json.JSONException -> "E_BRIDGE_ARGUMENTS"
            is UnsatisfiedLinkError -> "E_NATIVE_UNAVAILABLE"
            else -> "E_BRIDGE_NATIVE"
        }
        return code.takeIf { Regex("E_[A-Z0-9_]{1,96}").matches(it) } ?: "E_BRIDGE_NATIVE"
    }
}
