package tech.zseven.rish.runtime

import org.json.JSONObject

/** Shared Rust URL policy, constrained to transports this Android host implements. */
internal object AndroidGitRemoteUrl {
    fun validated(value: Any?): String? = decision(value)?.getString("url")

    fun validatedForm(value: Any?): String? = decision(value, form = true)?.getString("url")

    fun hostOf(url: String): String = decision(url)?.getString("host") ?: ""

    private fun decision(value: Any?, form: Boolean = false): JSONObject? {
        val text = value as? String ?: return null
        // Kotlin strings can contain isolated UTF-16 surrogates. Never let a
        // lossy JNI conversion silently select a different repository address.
        if (!wellFormedUtf16(text) || !RishAgentCoreNative.available) return null
        return try {
            val request = JSONObject().put("url", text).apply { if (form) put("form", true) }
            val encoded = RishAgentCoreNative.gitRemotePolicy(request.toString()) ?: return null
            val reply = JSONObject(encoded)
            if (reply.keys().asSequence().toSet() != setOf("ok", "value") || reply.opt("ok") != true) return null
            val result = reply.optJSONObject("value") ?: return null
            if (result.keys().asSequence().toSet() != setOf("url", "canonical_url", "scheme", "host", "port", "username", "path", "scp")) return null
            if (listOf("url", "canonical_url", "scheme", "host", "path").any { result.opt(it) !is String }) return null
            if (result.opt("port") !is Int || result.opt("scp") !is Boolean ||
                (result.opt("username") != JSONObject.NULL && result.opt("username") !is String)) return null
            // A shared policy accepting SSH does not add SSH credentials or
            // transport support to this host. Those remain native capabilities.
            if (result.getString("scheme") !in setOf("https", "http")) return null
            result
        } catch (_: org.json.JSONException) { null }
        catch (_: UnsatisfiedLinkError) { null }
    }

    private fun wellFormedUtf16(text: String): Boolean {
        var index = 0
        while (index < text.length) {
            val value = text[index++]
            if (Character.isHighSurrogate(value)) {
                if (index == text.length || !Character.isLowSurrogate(text[index++])) return false
            } else if (Character.isLowSurrogate(value)) return false
        }
        return true
    }
}
