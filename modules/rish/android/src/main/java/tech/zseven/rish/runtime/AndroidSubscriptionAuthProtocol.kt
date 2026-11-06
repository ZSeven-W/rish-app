package tech.zseven.rish.runtime

import java.net.URI
import java.net.URLDecoder
import java.util.Locale

internal object AndroidSubscriptionAuthProtocol {
    fun supports(harnessId: String): Boolean = harnessId == "codex" || harnessId == "claude-code"

    fun authMethodForStatus(status: String): String =
        if (status == "authorizing" || status == "signed_in") "subscription" else "none"

    /** Shared by CLI output parsing and the explicit native browser action. */
    fun isVerificationUrl(harnessId: String, value: String): Boolean = try {
        if (value.length !in 1..2048 || value.any { it <= ' ' || it == '\u007f' }) false
        else {
            val uri = URI(value)
            val host = uri.host?.lowercase(Locale.US)
            val allowedHost = when (harnessId) {
                "codex" -> host == "auth.openai.com" || host == "chatgpt.com"
                "claude-code" -> host == "claude.ai" || host == "console.anthropic.com" || host == "auth.anthropic.com"
                else -> false
            }
            val tokenParameter = uri.rawQuery.orEmpty().split('&').any { parameter ->
                val key = URLDecoder.decode(parameter.substringBefore('='), "UTF-8").lowercase(Locale.US)
                key in setOf("access_token", "refresh_token", "id_token", "api_key", "apikey", "token")
            }
            uri.scheme.equals("https", ignoreCase = true) && allowedHost && uri.rawUserInfo == null &&
                uri.port in setOf(-1, 443) && uri.rawFragment == null && !tokenParameter
        }
    } catch (_: Exception) { false }
}
