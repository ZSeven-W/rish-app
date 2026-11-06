package tech.zseven.rish.runtime

import java.util.Locale
import org.json.JSONObject

/** Strict parser for the pinned official CLI status envelopes. */
internal object AndroidSubscriptionAuthStatusParser {
    data class Result(val status: String, val account: String? = null, val plan: String? = null, val errorCode: String? = null)

    fun parse(harnessId: String, output: String, exitCode: Int): Result {
        if (exitCode != 0) {
            // A failed status subprocess is not evidence of signed-out state.
            // Keep only the exact human output emitted by the pinned Codex CLI.
            if (harnessId == "codex" && output.lineSequence().any { it.trim() == "Not logged in" }) {
                return Result("signed_out")
            }
            return Result("error", errorCode = "status_command_failed")
        }
        val json = extractJson(output)
        if (json != null) {
            val authMethod = firstTopLevelString(json, "authMethod", "auth_method")?.lowercase(Locale.US)
            val loggedIn = firstTopLevelBoolean(json, "loggedIn", "logged_in", "authenticated", "isAuthenticated", "isLoggedIn")
            val acceptedMethod = when (harnessId) {
                "codex" -> authMethod in setOf("chatgpt", "chatgptdevicecode", "oauth")
                "claude-code" -> authMethod in setOf("claude.ai", "claudeai", "oauth", "subscription")
                else -> false
            }
            val apiKey = authMethod in setOf("apikey", "api_key", "api-key", "token", "personalaccesstoken")
            if (loggedIn == true && acceptedMethod && !apiKey) {
                val accountObject = json.optJSONObject("account")
                val account = (accountObject?.optString("email")?.takeIf { it.isNotEmpty() }
                    ?: json.optString("email").takeIf { it.isNotEmpty() })?.let(::safeLabel)
                val plan = (accountObject?.optString("planType")?.takeIf { it.isNotEmpty() }
                    ?: json.optString("planType").takeIf { it.isNotEmpty() }
                    ?: json.optString("plan_type").takeIf { it.isNotEmpty() })?.let(::safeLabel)
                return Result("signed_in", account, plan)
            }
            if (loggedIn == false || apiKey) return Result("signed_out")
            if (loggedIn == true) return Result("error", errorCode = "status_unverified")
        }
        val codexHumanStatus = harnessId == "codex" &&
            Regex("(?m)^\\s*Logged in using ChatGPT\\s*$").containsMatchIn(output)
        if (codexHumanStatus && exitCode == 0) return Result("signed_in")
        val signedOutText = output.lineSequence().map { it.trim() }.any {
            it == "Not logged in" || it == "Not authenticated" || it == "Logged out" || it == "No credentials"
        }
        return if (signedOutText) Result("signed_out")
        else Result("error", errorCode = "status_unverified")
    }

    private fun extractJson(output: String): JSONObject? {
        val starts = output.indexOf('{')
        val ends = output.lastIndexOf('}')
        if (starts < 0 || ends <= starts) return null
        return try { JSONObject(output.substring(starts, ends + 1)) } catch (_: Exception) { null }
    }

    private fun firstTopLevelString(json: JSONObject, vararg names: String): String? = names
        .asSequence().mapNotNull { key -> json.optString(key).takeIf { it.isNotEmpty() } }.firstOrNull()

    private fun firstTopLevelBoolean(json: JSONObject, vararg names: String): Boolean? = names
        .asSequence().mapNotNull { key ->
            if (!json.has(key) || json.isNull(key)) null
            else json.get(key).let { if (it is Boolean) it else null }
        }.firstOrNull()

    private fun safeLabel(value: String): String? {
        val clean = value.filter { it.code in 0x20..0x7e }.trim()
        return clean.takeIf { it.isNotEmpty() && it.length <= 128 }
    }
}
