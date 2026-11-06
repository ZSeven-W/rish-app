package tech.zseven.rish.gpui

import org.json.JSONArray
import org.json.JSONObject
import java.math.BigInteger

internal data class InlineSyncRequest(
    val sessionId: String,
    val textRevision: Long,
    val text: String,
    val rect: List<Double>,
    val viewport: List<Double>,
    val scale: Double,
    val visible: Boolean,
    val focus: Boolean?,
    val appearance: String,
    val placeholder: String,
) {
    companion object {
        fun parse(args: JSONArray): InlineSyncRequest {
            val value = InlineComposerProtocol.objectArgument(args, setOf(
                "session_id", "text_revision", "text", "rect", "viewport", "scale",
                "visible", "focus", "appearance", "placeholder",
            ))
            val session = InlineComposerProtocol.sessionId(value)
            val revision = InlineComposerProtocol.integer(value.opt("text_revision"), positive = true)
            val text = InlineComposerProtocol.text(value.opt("text"))
            val placeholder = InlineComposerProtocol.text(value.opt("placeholder"))
            val rect = InlineComposerProtocol.vector(value.opt("rect"), 4)
            val viewport = InlineComposerProtocol.vector(value.opt("viewport"), 2)
            val scale = InlineComposerProtocol.number(value.opt("scale"))
            if (rect.any { it < -65_536.0 || it > 65_536.0 } || rect[2] < 0 || rect[3] < 0 ||
                viewport.any { it <= 0 || it > 16_384.0 } || scale <= 0 || scale > 16.0) invalidInline()
            val visible = value.opt("visible") as? Boolean ?: invalidInline()
            val focus = when (val candidate = value.opt("focus")) {
                JSONObject.NULL -> null
                is Boolean -> candidate
                else -> invalidInline()
            }
            val appearance = value.opt("appearance") as? String ?: invalidInline()
            if (appearance != "light" && appearance != "dark") invalidInline()
            return InlineSyncRequest(session, revision, text, rect, viewport, scale, visible,
                focus, appearance, placeholder)
        }
    }
}

internal data class InlineWaitRequest(val sessionId: String, val afterRevision: Long) {
    companion object {
        fun parse(args: JSONArray): InlineWaitRequest {
            val value = InlineComposerProtocol.objectArgument(args, setOf("session_id", "after_revision"))
            return InlineWaitRequest(InlineComposerProtocol.sessionId(value),
                InlineComposerProtocol.integer(value.opt("after_revision"), positive = false))
        }
    }
}

internal data class InlineSessionRequest(val sessionId: String) {
    companion object {
        fun parse(args: JSONArray): InlineSessionRequest {
            val value = InlineComposerProtocol.objectArgument(args, setOf("session_id"))
            return InlineSessionRequest(InlineComposerProtocol.sessionId(value))
        }
    }
}

internal data class InlineClearRequest(val sessionId: String, val expectedRevision: Long, val textRevision: Long) {
    companion object {
        fun parse(args: JSONArray): InlineClearRequest {
            val value = InlineComposerProtocol.objectArgument(args,
                setOf("session_id", "expected_revision", "text_revision"))
            return InlineClearRequest(InlineComposerProtocol.sessionId(value),
                InlineComposerProtocol.integer(value.opt("expected_revision"), positive = false),
                InlineComposerProtocol.integer(value.opt("text_revision"), positive = true))
        }
    }
}

internal object InlineComposerProtocol {
    const val MAX_TEXT_BYTES = 1024 * 1024
    private val uuid = Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")

    fun objectArgument(args: JSONArray, keys: Set<String>): JSONObject {
        if (args.length() != 1) invalidInline()
        val value = args.opt(0) as? JSONObject ?: invalidInline()
        if (value.keys().asSequence().toSet() != keys) invalidInline()
        return value
    }

    fun sessionId(value: JSONObject): String {
        val session = value.opt("session_id") as? String ?: invalidInline()
        if (!uuid.matches(session)) invalidInline()
        return session
    }

    fun integer(value: Any?, positive: Boolean): Long {
        val result = when (value) {
            is Byte, is Short, is Int, is Long -> (value as Number).toLong()
            is BigInteger -> try { value.longValueExact() } catch (_: ArithmeticException) { invalidInline() }
            else -> invalidInline()
        }
        if (result < if (positive) 1 else 0) invalidInline()
        return result
    }

    fun number(value: Any?): Double {
        val number = (value as? Number)?.toDouble() ?: invalidInline()
        if (!number.isFinite()) invalidInline()
        return number
    }

    fun vector(value: Any?, size: Int): List<Double> {
        val array = value as? JSONArray ?: invalidInline()
        if (array.length() != size) invalidInline()
        return List(size) { number(array.opt(it)) }
    }

    fun text(value: Any?): String {
        val text = value as? String ?: invalidInline()
        if (text.length > MAX_TEXT_BYTES || text.toByteArray(Charsets.UTF_8).size > MAX_TEXT_BYTES) invalidInline()
        var index = 0
        while (index < text.length) {
            val char = text[index++]
            if (Character.isHighSurrogate(char)) {
                if (index == text.length || !Character.isLowSurrogate(text[index++])) invalidInline()
            } else if (Character.isLowSurrogate(char)) invalidInline()
        }
        return text
    }
}

internal fun invalidInline(): Nothing = throw BridgeFailure("E_INLINE_COMPOSER_INVALID")
