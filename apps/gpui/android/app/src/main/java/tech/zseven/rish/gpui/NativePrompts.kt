package tech.zseven.rish.gpui

import android.app.Activity
import android.app.AlertDialog
import android.app.Dialog
import android.content.Context
import android.text.Editable
import android.text.InputType
import android.text.SpanWatcher
import android.text.Spannable
import android.text.Spanned
import android.text.TextWatcher
import android.text.method.PasswordTransformationMethod
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.WindowManager
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import org.json.JSONArray
import org.json.JSONObject
import tech.zseven.rish.runtime.AndroidCustomProviders
import tech.zseven.rish.runtime.AndroidRuntimeState
import tech.zseven.rish.runtime.AndroidGitCredentials
import tech.zseven.rish.runtime.AndroidWorkspaceProjects
import tech.zseven.rish.runtime.RishAgentCoreNative
import java.util.concurrent.atomic.AtomicBoolean

/** Android owns composition and secret entry, including CJK IME and accessibility. */
internal object NativePrompts {
    private val nameDialogs = mutableMapOf<Activity, Dialog>()
    private val editDialogs = mutableMapOf<Activity, Dialog>()

    private fun active(activity: Activity?): Activity =
        activity?.takeUnless { it.isFinishing || it.isDestroyed } ?: throw BridgeFailure("E_NATIVE_UI")

    fun dismissName(activity: Activity) {
        nameDialogs.remove(activity)?.cancel()
        editDialogs.remove(activity)?.cancel()
    }

    fun dismissGitForm(activity: Activity) = GitFormPrompt.dismiss(activity)

    fun gitForm(activity: Activity?, args: JSONArray, result: (JSONObject?) -> Unit) =
        GitFormPrompt.present(activity, args, result)

    fun dismissFileEditor(activity: Activity) = NativeFileEditor.dismiss(activity)

    fun editFile(activity: Activity?, args: JSONArray, result: (String?) -> Unit) =
        NativeFileEditor.present(activity, args, result)

    fun edit(activity: Activity?, args: JSONArray, result: (String?) -> Unit) {
        val screen = active(activity)
        editDialogs.remove(screen)?.cancel()
        val palette = NativeTheme.palette(screen)
        val context = NativeTheme.context(screen, palette)
        val field = EditText(context).apply {
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
            imeOptions = EditorInfo.IME_FLAG_NO_EXTRACT_UI or EditorInfo.IME_FLAG_NO_FULLSCREEN
            gravity = Gravity.TOP or Gravity.START
            minLines = 5
            maxLines = 12
            setAutofillHints(null)
            importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO
            NativeTheme.field(this, palette)
            setText(args.optString(0, ""))
            setSelection(text.length)
        }
        val completion = NamePromptCompletion(result)
        val body = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(context, 20), dp(context, 8), dp(context, 20), 0)
            addView(field, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
        }
        val dialog = NativeFormDialog(context, palette, args.optString(1, "Message"),
            screen.getString(android.R.string.cancel), screen.getString(android.R.string.ok), body, 720)
        dialog.submit.setOnClickListener {
            // The IME retains marked text until it commits composition.
            if (BaseInputConnection.getComposingSpanStart(field.text) >= 0 ||
                BaseInputConnection.getComposingSpanEnd(field.text) >= 0) return@setOnClickListener
            try { completion.finish(field.text.toString()) } finally { dialog.dismiss() }
        }
        dialog.setOnCancelListener { completion.finish(null) }
        dialog.setOnDismissListener {
            if (editDialogs[screen] === dialog) editDialogs.remove(screen)
            completion.finish(null)
        }
        dialog.setOnShowListener { field.requestFocus() }
        editDialogs[screen] = dialog
        try { dialog.show() } catch (failure: Throwable) { editDialogs.remove(screen); throw failure }
    }

    fun name(activity: Activity?, args: JSONArray, result: (String?) -> Unit) {
        val screen = active(activity)
        val options = NamePromptOptions.parse(args)
        dismissName(screen)
        val palette = NativeTheme.palette(screen, options.appearance)
        val context = NativeTheme.context(screen, palette)
        val secondary = palette.muted
        val field = EditText(context).apply {
            id = View.generateViewId()
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
            isSingleLine = true
            imeOptions = EditorInfo.IME_ACTION_DONE or EditorInfo.IME_FLAG_NO_EXTRACT_UI or EditorInfo.IME_FLAG_NO_FULLSCREEN
            NativeTheme.field(this, palette)
            hint = options.placeholder
            setAutofillHints(null)
            importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO
            setText(options.initialText)
            setSelection(text.length)
        }
        val label = TextView(context).apply {
            text = options.label
            textSize = 14f
            setTextColor(secondary)
            labelFor = field.id
            setPadding(0, 0, 0, dp(context, 8))
        }
        val hint = TextView(context).apply {
            text = options.hint
            textSize = 13f
            setTextColor(secondary)
            setPadding(0, dp(context, 10), 0, 0)
        }
        val error = TextView(context).apply {
            textSize = 13f
            setTextColor(palette.error)
            setPadding(0, dp(context, 8), 0, 0)
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
            visibility = View.GONE
        }
        val fields = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(context, 20), dp(context, 12), dp(context, 20), 0)
            addView(label)
            addView(field, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
            addView(hint)
            addView(error)
        }
        val completion = NamePromptCompletion(result)
        val dialog = NativeFormDialog(context, palette, options.title, options.cancelLabel, options.submitLabel, fields)
        dialog.setOnCancelListener { completion.finish(null) }
        var edited = false
        var pendingRefresh = false
        fun validation(): NameValidation = NamePromptValidation.evaluate(
            field.text.toString(), options.kind,
            BaseInputConnection.getComposingSpanStart(field.text) >= 0 ||
                BaseInputConnection.getComposingSpanEnd(field.text) >= 0,
        )
        fun refresh() {
            val state = validation()
            dialog.submit.isEnabled = state.canSubmit
            error.text = when (state.issue) {
                NameIssue.EMPTY -> if (edited) options.emptyError else ""
                NameIssue.INVALID -> options.invalidError
                NameIssue.TOO_LONG -> options.longError
                NameIssue.NONE, NameIssue.COMPOSING -> ""
            }
            error.visibility = if (error.text.isEmpty()) View.GONE else View.VISIBLE
        }
        fun scheduleRefresh() {
            if (pendingRefresh || completion.finished) return
            pendingRefresh = true
            // IMEs attach composing spans after the text callback. Read the
            // final span state, including composition-only changes, next turn.
            field.post {
                pendingRefresh = false
                if (!completion.finished) refresh()
            }
        }
        val watcher = object : TextWatcher, SpanWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = Unit
            override fun afterTextChanged(s: Editable?) { edited = true; scheduleRefresh() }
            override fun onSpanAdded(text: Spannable?, what: Any?, start: Int, end: Int) = scheduleRefresh()
            override fun onSpanRemoved(text: Spannable?, what: Any?, start: Int, end: Int) = scheduleRefresh()
            override fun onSpanChanged(text: Spannable?, what: Any?, oldStart: Int, oldEnd: Int, newStart: Int, newEnd: Int) = scheduleRefresh()
        }
        field.addTextChangedListener(watcher)
        field.text.setSpan(watcher, 0, field.text.length, Spanned.SPAN_INCLUSIVE_INCLUSIVE)
        fun submit() {
            val state = validation()
            if (!state.canSubmit) { edited = true; refresh(); return }
            try { completion.finish(state.value) } finally { dialog.dismiss() }
        }
        field.setOnEditorActionListener { _, action, key ->
            val enter = key?.keyCode == KeyEvent.KEYCODE_ENTER
            if (action == EditorInfo.IME_ACTION_DONE || enter) {
                if (key == null || key.action == KeyEvent.ACTION_UP) submit()
                true
            } else false
        }
        dialog.setOnDismissListener {
            if (nameDialogs[screen] === dialog) nameDialogs.remove(screen)
            field.removeTextChangedListener(watcher)
            field.text.removeSpan(watcher)
            completion.finish(null)
        }
        dialog.setOnShowListener {
            dialog.submit.setOnClickListener { submit() }
            refresh()
            field.requestFocus()
            dialog.window?.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_VISIBLE or WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
        }
        nameDialogs[screen] = dialog
        try { dialog.show() } catch (failure: Throwable) {
            nameDialogs.remove(screen)
            throw failure
        }
    }

    fun runtime(activity: Activity?, runtime: AndroidRuntimeState, method: String, args: JSONArray, id: Long) {
        val screen = active(activity)
        val palette = NativeTheme.palette(screen)
        val context = NativeTheme.context(screen, palette)
        val login = method == "presentHarnessLoginCode"
        val slot = if (method == "presentCredentialPrompt") "DEEPSEEK_API_KEY" else args.getString(0)
        val account = if (login) null else runtime.transport.account(slot)
        val localeIndex = if (login) 2 else if (method == "presentCredentialPrompt") 0 else 1
        val chinese = args.optString(localeIndex) == "zh-CN"
        val field = secretField(context, palette)
        val title = if (login) {
            if (chinese) "输入登录验证码" else "Enter login code"
        } else if (chinese) "安全保存 API Key" else "Save API key securely"
        val message = if (login) {
            if (chinese) "验证码仅发送给官方 CLI，不会写入会话。" else "The code goes only to the official CLI and is never stored in chat."
        } else if (chinese) "密钥使用本机 Android Keystore 加密，不会写入会话。" else "Encrypted with Android Keystore on this device. Never stored in chat."
        val settled = AtomicBoolean(false)
        val cancelled = {
            field.text.clear()
            if (settled.compareAndSet(false, true)) RishGpuiBridge.answer(id, JSONObject().put("status", "cancelled"))
        }
        val fields = credentialBody(context, palette, message).apply { addView(field) }
        val dialog = NativeFormDialog(context, palette, title, screen.getString(android.R.string.cancel),
            screen.getString(android.R.string.ok), fields)
        dialog.setOnCancelListener { cancelled() }
        dialog.setOnDismissListener { cancelled() }
        dialog.setOnShowListener {
            field.requestFocus()
            dialog.submit.setOnClickListener {
                val secret = field.text.toString().trim()
                if (secret.isEmpty()) { field.error = if (chinese) "请输入内容" else "Enter a value"; return@setOnClickListener }
                if (!settled.compareAndSet(false, true)) return@setOnClickListener
                field.text.clear(); dialog.dismiss()
                runtime.io.execute {
                    RishGpuiBridge.settle(id) {
                        if (login) runtime.subscriptionAuth.submitCode(args.getString(0), args.getString(1), secret)
                        else { runtime.transport.put(slot, requireNotNull(account), secret); JSONObject().put("status", "configured") }
                    }
                }
            }
        }
        dialog.show()
    }

    fun customProvider(activity: Activity?, runtime: AndroidRuntimeState,
        scope: AndroidCustomProviders.CredentialScope, locale: String, id: Long) {
        if (scope.account == null) {
            RishGpuiBridge.answer(id, JSONObject().put("schema_version", 1).put("id", scope.id).put("status", "not_required"))
            return
        }
        val screen = active(activity)
        val palette = NativeTheme.palette(screen)
        val context = NativeTheme.context(screen, palette)
        val chinese = locale == "zh-CN"
        val field = secretField(context, palette)
        val settled = AtomicBoolean(false)
        val message = scope.configuration.getString("name") + "\n" + scope.configuration.getString("endpoint_url") + "\n" +
            if (chinese) "密钥使用本机 Android Keystore 加密，不会写入会话。" else "Encrypted with Android Keystore on this device. Never stored in chat."
        val fields = credentialBody(context, palette, message).apply { addView(field) }
        val dialog = NativeFormDialog(context, palette, if (chinese) "安全保存 API Key" else "Save API key securely",
            screen.getString(android.R.string.cancel), screen.getString(android.R.string.ok), fields)
        val cancelled = {
            field.text.clear()
            if (settled.compareAndSet(false, true)) RishGpuiBridge.answer(id,
                JSONObject().put("schema_version", 1).put("id", scope.id).put("status", "cancelled"))
        }
        dialog.setOnCancelListener { cancelled() }
        dialog.setOnDismissListener { cancelled() }
        dialog.setOnShowListener {
            field.requestFocus()
            dialog.submit.setOnClickListener {
                val secret = field.text.toString().trim()
                if (secret.isEmpty()) { field.error = if (chinese) "请输入内容" else "Enter a value"; return@setOnClickListener }
                if (!settled.compareAndSet(false, true)) return@setOnClickListener
                field.text.clear(); dialog.dismiss()
                runtime.io.execute { RishGpuiBridge.settle(id) { runtime.customProviders.put(scope, secret) } }
            }
        }
        dialog.show()
    }

    fun git(activity: Activity?, runtime: AndroidRuntimeState, request: JSONObject, scope: JSONObject, clone: Boolean, id: Long) {
        val screen = active(activity)
        val palette = NativeTheme.palette(screen)
        val context = NativeTheme.context(screen, palette)
        val chinese = scope.optBoolean("chinese")
        val host = scope.getString("host")
        val username = EditText(context).apply {
            isSingleLine = true
            hint = if (chinese) "用户名" else "Username"
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            imeOptions = EditorInfo.IME_ACTION_NEXT or EditorInfo.IME_FLAG_NO_EXTRACT_UI or EditorInfo.IME_FLAG_NO_FULLSCREEN
            NativeTheme.field(this, palette)
        }
        val token = secretField(context, palette).apply { hint = "Personal access token" }
        val settled = AtomicBoolean(false)
        val cancel = {
            username.text.clear(); token.text.clear()
            if (settled.compareAndSet(false, true)) RishGpuiBridge.reject(id, BridgeFailure(AndroidWorkspaceProjects.codeFor(3195)))
        }
        val title = if (chinese) "Git HTTPS 凭据" else "Git HTTPS credential"
        val notice = if (chinese) "凭据用于 $host，并使用本机 Android Keystore 加密。" else "Credentials for $host are encrypted using Android Keystore."
        val plaintext = if (!scope.optBoolean("plaintext")) "" else if (chinese) " 此远程使用局域网明文 HTTP。" else " This remote uses plain HTTP on the local network."
        val fields = credentialBody(context, palette, notice + plaintext).apply {
            addView(username)
            addView(token, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
                topMargin = dp(context, 12)
            })
        }
        val dialog = NativeFormDialog(context, palette, title, screen.getString(android.R.string.cancel),
            screen.getString(android.R.string.ok), fields)
        var choosingExpiry = false
        dialog.setOnCancelListener { cancel() }
        dialog.setOnDismissListener { if (!choosingExpiry) cancel() }
        dialog.setOnShowListener {
            username.requestFocus()
            dialog.submit.setOnClickListener {
                val user = username.text.toString().trim()
                val secret = token.text.toString().trim()
                if (user.isEmpty() || secret.isEmpty()) { token.error = if (chinese) "请输入用户名和令牌" else "Enter a username and token"; return@setOnClickListener }
                choosingExpiry = true
                username.text.clear(); token.text.clear(); dialog.dismiss()
                val options = AndroidGitCredentials.EXPIRIES.sorted()
                val expiry = AlertDialog.Builder(context).setTitle(if (chinese) "令牌保存时长" else "Keep credential for")
                    .setItems(if (chinese) arrayOf("1 小时", "24 小时", "7 天") else arrayOf("1 hour", "24 hours", "7 days")) { _, index ->
                        if (settled.compareAndSet(false, true)) runtime.io.execute {
                            RishGpuiBridge.settle(id) {
                                if (clone) runtime.workspaceClone.offerCredential(scope.getString("operation_id"), host, user, secret, options[index])
                                else runtime.projectGit.storeCredential(JSONObject().put("schema_version", 1).put("root", request.get("root"))
                                    .put("host", host).put("username", user).put("token", secret).put("expiry_seconds", options[index]))
                            }
                        }
                    }.setNegativeButton(android.R.string.cancel) { _, _ -> cancel() }
                    .setOnCancelListener { cancel() }.create()
                expiry.setOnShowListener { NativeTheme.styleAlert(expiry, palette) }
                expiry.setOnDismissListener { cancel() }
                expiry.show()
            }
        }
        dialog.show()
    }

    private fun secretField(context: Context, palette: NativePalette) = EditText(context).apply {
        isSingleLine = true
        inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
        transformationMethod = PasswordTransformationMethod.getInstance()
        imeOptions = EditorInfo.IME_FLAG_NO_EXTRACT_UI or EditorInfo.IME_FLAG_NO_FULLSCREEN
        setAutofillHints(null)
        importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS
        NativeTheme.field(this, palette)
    }

    private fun credentialBody(context: Context, palette: NativePalette, notice: String) = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(context, 20), dp(context, 4), dp(context, 20), 0)
        addView(TextView(context).apply {
            text = notice
            textSize = 13f
            setTextColor(palette.muted)
            setLineSpacing(dp(context, 3).toFloat(), 1f)
            setPadding(0, 0, 0, dp(context, 20))
        })
    }

    private fun dp(context: Context, value: Int): Int = NativeTheme.dp(context, value)

}

internal data class NamePromptOptions(
    val kind: String, val initialText: String, val title: String, val label: String,
    val placeholder: String, val hint: String, val submitLabel: String, val cancelLabel: String,
    val emptyError: String, val invalidError: String, val longError: String, val appearance: String,
) {
    companion object {
        private val keys = setOf("kind", "initial_text", "title", "label", "placeholder", "hint",
            "submit_label", "cancel_label", "empty_error", "invalid_error", "long_error", "appearance")

        fun parse(args: JSONArray): NamePromptOptions {
            if (args.length() != 1) throw BridgeFailure("E_BRIDGE_ARGUMENTS")
            val source = args.optJSONObject(0) ?: throw BridgeFailure("E_BRIDGE_ARGUMENTS")
            if (source.keys().asSequence().toSet() != keys || keys.any { source.opt(it) !is String } ||
                source.getString("kind") !in setOf("workspace", "conversation") ||
                source.getString("appearance") !in setOf("light", "dark")) throw BridgeFailure("E_BRIDGE_ARGUMENTS")
            return NamePromptOptions(source.getString("kind"), source.getString("initial_text"),
                source.getString("title"), source.getString("label"), source.getString("placeholder"),
                source.getString("hint"), source.getString("submit_label"), source.getString("cancel_label"),
                source.getString("empty_error"), source.getString("invalid_error"), source.getString("long_error"),
                source.getString("appearance"))
        }
    }
}

internal enum class NameIssue { NONE, EMPTY, INVALID, TOO_LONG, COMPOSING }
internal data class NameValidation(val value: String, val issue: NameIssue) {
    val canSubmit: Boolean get() = issue == NameIssue.NONE
}

internal object NamePromptValidation {
    fun evaluate(text: String, kind: String, composing: Boolean = false): NameValidation {
        // Marked text belongs to the IME. Only completed, representable UTF-8
        // crosses the bridge; normalization and every naming rule live in Rust.
        if (composing) return NameValidation(text, NameIssue.COMPOSING)
        if (hasUnpairedSurrogate(text)) return NameValidation(text, NameIssue.INVALID)
        val failed = NameValidation(text, NameIssue.INVALID)
        if (!RishAgentCoreNative.available) return failed
        return try {
            val encoded = RishAgentCoreNative.namePolicy(JSONObject().put("kind", kind).put("text", text).toString())
                ?: return failed
            val reply = JSONObject(encoded)
            if (reply.keys().asSequence().toSet() != setOf("ok", "value") || reply.opt("ok") != true) return failed
            val value = reply.optJSONObject("value") ?: return failed
            if (value.keys().asSequence().toSet() != setOf("text", "issue")) return failed
            val normalized = value.opt("text") as? String ?: return failed
            if (hasUnpairedSurrogate(normalized)) return failed
            val issue = when (value.opt("issue")) {
                JSONObject.NULL -> NameIssue.NONE
                "empty" -> NameIssue.EMPTY
                "invalid" -> NameIssue.INVALID
                "too_long" -> NameIssue.TOO_LONG
                else -> return failed
            }
            NameValidation(normalized, issue)
        } catch (_: org.json.JSONException) { failed }
        catch (_: UnsatisfiedLinkError) { failed }
    }

    private fun hasUnpairedSurrogate(text: String): Boolean {
        var index = 0
        while (index < text.length) {
            val value = text[index++]
            if (Character.isHighSurrogate(value)) {
                if (index == text.length || !Character.isLowSurrogate(text[index++])) return true
            } else if (Character.isLowSurrogate(value)) return true
        }
        return false
    }
}

internal class NamePromptCompletion(private val result: (String?) -> Unit) {
    private val settled = AtomicBoolean(false)
    val finished: Boolean get() = settled.get()
    fun finish(value: String?) {
        if (settled.compareAndSet(false, true)) result(value)
    }
}
