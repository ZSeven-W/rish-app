package tech.zseven.rish.modules

import android.app.AlertDialog
import android.text.InputType
import android.text.method.PasswordTransformationMethod
import android.widget.EditText
import android.util.Log
import com.facebook.react.bridge.*
import tech.zseven.rish.runtime.*
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

// Secret entry (API keys, login codes) masks the field and does not block screen
// capture: the owner decides what is safe to capture, and iOS never blocked it
// here either. The masking carries that decision, so set it explicitly --
// `isSingleLine = true` installs SingleLineTransformationMethod and silently
// replaces the PasswordTransformationMethod that a password inputType had just
// installed, so ordering alone decided whether the key showed in cleartext. It
// did, on both prompts, until 2026-09-17.
/** Native chat transport and encrypted credentials. Agent/project execution stays unavailable. */
class LocalRuntimeModule(private val react: ReactApplicationContext) : ReactContextBaseJavaModule(react) {
    private val runtime = AndroidRuntimeState.get(react)
    override fun getName() = "LocalRuntime"
    private fun resolve(promise: Promise, value: JSONObject) = promise.resolve(Arguments.makeNativeMap(RuntimeJson.map(value)))
    private fun reject(promise: Promise, error: Exception) {
        val code = (error as? RuntimeFailure)?.code ?: "E_COMPLETION_NATIVE"
        // The code that crosses the bridge stays opaque on purpose -- it must
        // carry no provider body, no URL with credentials and no secret. The
        // reason still has to be visible *here*, or a refusal on this side is
        // indistinguishable from any other and can only be found by guessing.
        Log.w("RishRuntime", "native runtime call refused as $code", error)
        promise.reject(code, code)
    }
    private fun io(promise: Promise, action: () -> JSONObject) { runtime.io.execute { try { resolve(promise, action()) } catch(error: Exception) { reject(promise, error) } } }
    @ReactMethod fun bootstrap(promise: Promise) = io(promise) { runtime.proof() }
    /**
     * The runtime proof for one harness. JavaScript asks this for every
     * harness but DSH since 2026-09-11 and, when the method is missing,
     * refuses with "harness-aware runtime bootstrap is unavailable" -- which
     * on Android turned every configured Claude Code / Codex / GLM key into
     * "Local proof failed" and a blocked composer (2026-09-21). The proof is
     * the same record `bootstrap` answers, taken for that harness's slot.
     */
    @ReactMethod fun bootstrapForHarness(harnessId: String, promise: Promise) = io(promise) {
        val slot = when (harnessId) {
            "dsh" -> "DEEPSEEK_API_KEY"; "glm" -> "BIGMODEL_API_KEY"; "codex" -> "OPENAI_API_KEY"; "claude-code" -> "ANTHROPIC_API_KEY"
            else -> throw IllegalArgumentException("E_RUNTIME_HARNESS")
        }
        runtime.selectedSlot = slot
        runtime.proof()
    }
    @ReactMethod fun credentialStatus(promise: Promise) = credentialStatusForSlot("DEEPSEEK_API_KEY", promise)
    @ReactMethod fun credentialStatusForSlot(slot: String, promise: Promise) = io(promise) {
        require(slot in AndroidCredentialStore.slots); runtime.selectedSlot = slot
        JSONObject().put("status", if(runtime.transport.configured(slot)) "configured" else "missing")
    }
    @ReactMethod fun presentCredentialPrompt(locale: String?, promise: Promise) = presentCredentialPromptForSlot("DEEPSEEK_API_KEY", locale, promise)
    @ReactMethod fun presentCredentialPromptForSlot(slot: String, locale: String?, promise: Promise) {
        try {
            val account = runtime.transport.account(slot)
            UiThreadUtil.runOnUiThread {
                val activity = react.currentActivity
                if(activity == null || activity.isFinishing) { promise.reject("E_COMPLETION_NATIVE", "Active screen required"); return@runOnUiThread }
                val chinese = locale == "zh-CN"
                val field = EditText(activity).apply { isSingleLine = true
                    inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
                    transformationMethod = PasswordTransformationMethod.getInstance()
                    if (android.os.Build.VERSION.SDK_INT >= 26) {
                        setAutofillHints(null)
                        importantForAutofill = android.view.View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS
                    } }
                val dialog = AlertDialog.Builder(activity).setTitle(if(chinese) "安全保存 API Key" else "Save API key securely")
                    .setMessage(if(chinese) "保存在此设备的 Android Keystore 中，不会写入会话。" else "Encrypted using Android Keystore on this device. Never written into chats.")
                    .setView(field).setNegativeButton(if(chinese) "取消" else "Cancel") { _, _ -> field.text.clear(); resolve(promise, JSONObject().put("status", "cancelled")) }
                    .setPositiveButton(if(chinese) "保存" else "Save", null)
                    .setOnCancelListener { field.text.clear(); resolve(promise, JSONObject().put("status", "cancelled")) }.create()
                dialog.setOnShowListener {
                    dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                        val secret = field.text.toString().trim()
                        if(secret.isEmpty()) { field.error = if(chinese) "请输入密钥" else "Enter a key"; return@setOnClickListener }
                        field.text.clear(); dialog.dismiss()
                        io(promise) { runtime.transport.put(slot, account, secret); JSONObject().put("status", "configured") }
                    }
                }
                dialog.show()
            }
        } catch(error: Exception) { reject(promise, error) }
    }
    @ReactMethod fun clearCredential(promise: Promise) = clearCredentialForSlot("DEEPSEEK_API_KEY", promise)
    @ReactMethod fun clearCredentialForSlot(slot: String, promise: Promise) = io(promise) { runtime.transport.clear(slot); JSONObject().put("status", "cleared") }
    @ReactMethod fun dshModelCatalog(promise: Promise) = io(promise) { AndroidDshModelCatalog.read() }
    @ReactMethod fun saveDshModelCatalog(request: ReadableMap?, promise: Promise) {
        try {
            val captured = RuntimeJson.fromBridgeMap(requireNotNull(request).toHashMap())
            // Validate before invalidating active transport ownership.
            RuntimeJson.checkVersion(captured, 1)
            AndroidDshModelCatalog.validateModels(captured.getJSONArray("models"))
            io(promise) { runtime.transport.whenIdle { AndroidDshModelCatalog.save(captured) } }
        } catch (error: Exception) { reject(promise, error) }
    }
    @ReactMethod fun providerConfiguration(harness: String, promise: Promise) = io(promise) { runtime.configurations.read(harness) }
    /** Official Codex/Claude subscription auth is native-only and isolated from API keys. */
    @ReactMethod fun harnessAuthStatus(harnessId: String, promise: Promise) = io(promise) {
        runtime.subscriptionAuth.status(harnessId)
    }
    @ReactMethod fun startHarnessLogin(harnessId: String, promise: Promise) = io(promise) {
        runtime.subscriptionAuth.start(harnessId)
    }
    @ReactMethod fun cancelHarnessLogin(harnessId: String, sessionId: String, promise: Promise) = io(promise) {
        runtime.subscriptionAuth.cancel(harnessId, sessionId)
    }
    @ReactMethod fun logoutHarness(harnessId: String, promise: Promise) = io(promise) {
        runtime.subscriptionAuth.logout(harnessId)
    }
    @ReactMethod fun presentHarnessLoginCode(harnessId: String, sessionId: String, locale: String?, promise: Promise) {
        try {
            UiThreadUtil.runOnUiThread {
                val activity = react.currentActivity
                if (activity == null || activity.isFinishing) {
                    promise.reject("E_AUTH_UI", "Active screen required")
                    return@runOnUiThread
                }
                val chinese = locale == "zh-CN"
                val field = EditText(activity).apply {
                    isSingleLine = true
                    inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
                    transformationMethod = PasswordTransformationMethod.getInstance()
                    if (android.os.Build.VERSION.SDK_INT >= 26) {
                        setAutofillHints(null)
                        importantForAutofill = android.view.View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS
                    }
                }
                val dialog = AlertDialog.Builder(activity)
                    .setTitle(if (chinese) "输入登录验证码" else "Enter login code")
                    .setMessage(if (chinese) "验证码仅发送给官方 CLI，不会写入会话。" else "The code is sent only to the official CLI and is never written to chat.")
                    .setView(field)
                    .setNegativeButton(if (chinese) "取消" else "Cancel") { _, _ ->
                        field.text.clear()
                        resolve(promise, JSONObject().put("status", "cancelled"))
                    }
                    .setPositiveButton(if (chinese) "提交" else "Submit", null)
                    .setOnCancelListener {
                        field.text.clear()
                        resolve(promise, JSONObject().put("status", "cancelled"))
                    }.create()
                dialog.setOnShowListener {
                    dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                        val code = field.text.toString().trim()
                        if (code.isEmpty()) {
                            field.error = if (chinese) "请输入验证码" else "Enter a code"
                            return@setOnClickListener
                        }
                        field.text.clear()
                        dialog.dismiss()
                        io(promise) { runtime.subscriptionAuth.submitCode(harnessId, sessionId, code) }
                    }
                }
                dialog.show()
            }
        } catch (error: Exception) { reject(promise, error) }
    }
    @ReactMethod fun saveProviderConfiguration(request: ReadableMap?, promise: Promise) {
        try { val text = runtime.configurations.normalize(RuntimeJson.fromBridgeMap(requireNotNull(request).toHashMap())).toString(); io(promise) { runtime.transport.mutate { runtime.configurations.save(JSONObject(text)) } } }
        catch(error: Exception) { reject(promise, error) }
    }
    @ReactMethod fun resetProviderConfiguration(harness: String, promise: Promise) = io(promise) { runtime.transport.mutate { runtime.configurations.reset(harness) } }
    @ReactMethod fun completeV2(envelope: String, promise: Promise) {
        try {
            // Reserve synchronously before queueing; cancellation before worker
            // binding must prevent a later request from being sent.
            val prepared = runtime.transport.prepare(envelope)
            io(promise) { runtime.transport.execute(prepared) }
        } catch(error: Exception) { reject(promise, error) }
    }
    @ReactMethod fun complete(model: String, history: ReadableArray, requestId: String, thinkingMode: String, promise: Promise) {
        val request = JSONObject().put("schema_version", 1).put("model", model).put("history", JSONArray(history.toArrayList()))
            .put("request_id", requestId).put("thinking_mode", thinkingMode).put("tools", JSONArray())
        completeV2(request.toString(), promise)
    }
    @ReactMethod fun cancelCompletion(requestId: String, promise: Promise) { resolve(promise, JSONObject().put("status", runtime.transport.cancel(requestId))) }
    @ReactMethod fun persistSession(json: String, promise: Promise) {
        runtime.io.execute {
            try {
                val loaded = runtime.sessions.load()
                val expected = JSONObject().put("schema_version", 1).put("kind", if(loaded.getString("status") == "missing") "missing" else "present")
                if(loaded.getString("status") == "present") expected.put("snapshot", loaded.getJSONObject("snapshot"))
                val result = runtime.sessions.persist(JSONObject().put("schema_version", 1).put("operation_id", UUID.randomUUID().toString()).put("expected", expected).put("candidate_json", json))
                promise.resolve(result.getString("status") == "committed")
            } catch(error: Exception) { reject(promise, error) }
        }
    }
    @ReactMethod fun loadSession(promise: Promise) {
        runtime.io.execute {
            try { val loaded = runtime.loadSnapshot(); promise.resolve(if(loaded.getString("status") == "missing") null else loaded.getString("session_json")) }
            catch(error: Exception) { reject(promise, error) }
        }
    }
    override fun invalidate() { runtime.subscriptionAuth.shutdown(); runtime.transport.mutate { }; super.invalidate() }
}
