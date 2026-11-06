package tech.zseven.rish.gpui

import org.json.JSONArray
import org.json.JSONObject
import tech.zseven.rish.runtime.AndroidGitRemoteUrl
import java.text.Normalizer
import java.util.concurrent.atomic.AtomicBoolean

internal data class GitFormField(val key: String, val label: String, val placeholder: String, val value: String)
internal data class GitFormOptions(
    val kind: String, val appearance: String, val title: String, val submitLabel: String,
    val cancelLabel: String, val fields: List<GitFormField>, val hint: String, val invalidMessage: String,
) {
    companion object {
        fun parse(args: JSONArray): GitFormOptions {
            val source = args.opt(0) as? JSONObject ?: throw BridgeFailure("E_BRIDGE_ARGUMENTS")
            val strings = setOf("kind", "appearance", "title", "submit_label", "cancel_label", "hint", "invalid_message")
            if (args.length() != 1 || source.keys().asSequence().toSet() != strings + "fields" ||
                strings.any { source.opt(it) !is String } || source.optString("kind") !in setOf("commit", "remote") ||
                source.optString("appearance") !in setOf("light", "dark")) throw BridgeFailure("E_BRIDGE_ARGUMENTS")
            val expected = if (source.getString("kind") == "commit") listOf("message", "author_name", "author_email") else listOf("url")
            val array = source.opt("fields") as? JSONArray ?: throw BridgeFailure("E_BRIDGE_ARGUMENTS")
            if (array.length() != expected.size) throw BridgeFailure("E_BRIDGE_ARGUMENTS")
            val fields = expected.mapIndexed { index, key ->
                val item = array.opt(index) as? JSONObject ?: throw BridgeFailure("E_BRIDGE_ARGUMENTS")
                val keys = setOf("key", "label", "placeholder", "value")
                if (item.keys().asSequence().toSet() != keys || keys.any { item.opt(it) !is String } ||
                    item.getString("key") != key) throw BridgeFailure("E_BRIDGE_ARGUMENTS")
                GitFormField(key, item.getString("label"), item.getString("placeholder"), item.getString("value"))
            }
            return GitFormOptions(source.getString("kind"), source.getString("appearance"), source.getString("title"),
                source.getString("submit_label"), source.getString("cancel_label"), fields,
                source.getString("hint"), source.getString("invalid_message"))
        }
    }
}

internal object GitFormValidation {
    /** Input buffers are never changed. Only a valid, committed submission is normalized. */
    fun evaluate(kind: String, values: List<String>, composing: Boolean = false): JSONObject? {
        if (composing) return null
        if (kind == "remote") {
            if (values.size != 1) return null
            // The form policy owns whitespace, byte limits and repository identity.
            val url = AndroidGitRemoteUrl.validatedForm(values.single()) ?: return null
            return JSONObject().put("url", url)
        }
        val normalized = values.map { Normalizer.normalize(it.trim(::unicodeWhitespace), Normalizer.Form.NFC) }
        if (normalized.any(::forbidden)) return null
        return when (kind) {
            "commit" -> {
                if (normalized.size != 3) return null
                val (message, name, email) = normalized
                if (!bounded(message, 500) || !bounded(name, 120) || name.any { it == '<' || it == '>' } ||
                    !bounded(email, 254) || email.any { unicodeWhitespace(it) || it == '<' || it == '>' } ||
                    email.count { it == '@' } != 1 || email.startsWith('@') || email.endsWith('@')) return null
                JSONObject().put("message", message).put("author_name", name).put("author_email", email)
            }
            else -> null
        }
    }

    private fun bounded(text: String, bytes: Int): Boolean = text.isNotEmpty() && text.toByteArray(Charsets.UTF_8).size <= bytes

    private fun forbidden(text: String): Boolean {
        var index = 0
        while (index < text.length) {
            val next = text[index]
            if (Character.isHighSurrogate(next)) {
                if (index + 1 == text.length || !Character.isLowSurrogate(text[index + 1])) return true
            } else if (Character.isLowSurrogate(next)) return true
            val scalar = text.codePointAt(index)
            val category = Character.getType(scalar)
            if (category == Character.CONTROL.toInt() || category == Character.FORMAT.toInt() ||
                category == Character.LINE_SEPARATOR.toInt() || category == Character.PARAGRAPH_SEPARATOR.toInt()) return true
            index += Character.charCount(scalar)
        }
        return false
    }

    private fun unicodeWhitespace(value: Char): Boolean = value.code in 0x09..0x0d ||
        value == ' ' || value == '\u0085' || value == '\u00a0' || value == '\u1680' ||
        value.code in 0x2000..0x200a || value == '\u2028' || value == '\u2029' ||
        value == '\u202f' || value == '\u205f' || value == '\u3000'
}

internal class GitFormCompletion(private val result: (JSONObject?) -> Unit) {
    private val settled = AtomicBoolean(false)
    val finished: Boolean get() = settled.get()
    fun finish(value: JSONObject?) { if (settled.compareAndSet(false, true)) result(value) }
}
