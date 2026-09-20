package tech.zseven.rish.modules

import android.app.Activity
import android.app.AlertDialog
import android.text.InputType
import android.text.method.PasswordTransformationMethod
import android.widget.EditText
import android.widget.LinearLayout
import tech.zseven.rish.runtime.AndroidGitCredentials

/**
 * The native Git credential prompt: a username, a personal access token and
 * how long to keep them. The token goes from the field into
 * [tech.zseven.rish.runtime.AndroidProjectGit.storeCredential] and nowhere
 * else -- JavaScript asked for the prompt and receives only a status back.
 * Mirrors `presentCredentialAlertForHost:` on iOS, expiry choice included.
 */
/** `(username, token, expirySeconds, failure)`: a failure of `cancelled` or `presentation`, or a credential. */
internal typealias GitCredentialPromptCompletion = (String?, String?, Long, String?) -> Unit

internal object AndroidGitCredentialPrompt {

    /** A test's stand-in for the dialog; iOS keeps the same seam as `credentialPromptHook`. */
    @Volatile var hook: ((host: String, chinese: Boolean, plaintext: Boolean, completion: GitCredentialPromptCompletion) -> Unit)? = null

    fun present(activity: Activity?, host: String, chinese: Boolean, plaintext: Boolean, completion: GitCredentialPromptCompletion) {
        hook?.let { it(host, chinese, plaintext, completion); return }
        if (activity == null || activity.isFinishing) { completion(null, null, 0, "presentation"); return }
        val transport = if (plaintext) {
            if (chinese) "该远程是局域网明文 HTTP 测试地址。" else " This remote is a plain-HTTP address on the local network."
        } else ""
        val message = if (chinese) {
            "用于 $host 的推送。PAT 仅保存在本机 Android Keystore，永不传回 React Native。${transport}接下来选择保存时长（1 小时 / 24 小时 / 7 天）。"
        } else {
            "Used to push to $host. The PAT stays in this device's Android Keystore and is never returned to React Native.$transport Next, choose how long to keep it (1 hour / 24 hours / 7 days)."
        }
        val username = EditText(activity).apply {
            hint = if (chinese) "用户名" else "Username"
            isSingleLine = true
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
        }
        val token = EditText(activity).apply {
            hint = "Personal access token"
            isSingleLine = true
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
            transformationMethod = PasswordTransformationMethod.getInstance()
            if (android.os.Build.VERSION.SDK_INT >= 26) {
                setAutofillHints(null)
                importantForAutofill = android.view.View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS
            }
        }
        val fields = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            val pad = (16 * activity.resources.displayMetrics.density).toInt()
            setPadding(pad, pad / 2, pad, 0)
            addView(username); addView(token)
        }
        val clear = { username.text.clear(); token.text.clear() }
        val dialog = AlertDialog.Builder(activity)
            .setTitle(if (chinese) "Git HTTPS 凭据" else "Git HTTPS credential")
            .setMessage(message)
            .setView(fields)
            .setNegativeButton(if (chinese) "取消" else "Cancel") { _, _ -> clear(); completion(null, null, 0, "cancelled") }
            .setPositiveButton(if (chinese) "保存" else "Save", null)
            .setOnCancelListener { clear(); completion(null, null, 0, "cancelled") }
            .create()
        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                val user = username.text.toString().trim()
                val secret = token.text.toString().trim()
                if (user.isEmpty()) { username.error = if (chinese) "请输入用户名" else "Enter a username"; return@setOnClickListener }
                if (secret.isEmpty()) { token.error = if (chinese) "请输入令牌" else "Enter a token"; return@setOnClickListener }
                clear(); dialog.dismiss()
                presentExpiry(activity, chinese) { expiry ->
                    if (expiry == null) completion(null, null, 0, "cancelled") else completion(user, secret, expiry, null)
                }
            }
        }
        dialog.show()
    }

    /** The expiry is an explicit choice in the same native flow; cancelling it abandons the whole provisioning. */
    private fun presentExpiry(activity: Activity, chinese: Boolean, chosen: (Long?) -> Unit) {
        if (activity.isFinishing) { chosen(null); return }
        val options = AndroidGitCredentials.EXPIRIES.sorted()
        val labels = if (chinese) arrayOf("1 小时", "24 小时", "7 天") else arrayOf("1 hour", "24 hours", "7 days")
        AlertDialog.Builder(activity)
            .setTitle(if (chinese) "令牌保存时长" else "How long should this token stay stored?")
            .setItems(labels) { _, which -> chosen(options[which]) }
            .setNegativeButton(if (chinese) "取消" else "Cancel") { _, _ -> chosen(null) }
            .setOnCancelListener { chosen(null) }
            .show()
    }
}
