package tech.zseven.rish.gpui

import org.json.JSONArray
import java.util.UUID
import kotlin.math.max
import kotlin.math.roundToInt

internal object ShellAvatarContract {
    const val MAX_SOURCE_BYTES = 64 * 1024 * 1024
    const val MAX_PNG_BYTES = 2 * 1024 * 1024
    const val MAX_DIMENSION = 512

    fun validate(args: JSONArray) {
        require(args.length() == 1)
        val request = args.getJSONObject(0)
        require(request.keys().asSequence().toSet() == setOf("schema_version", "userInitiated"))
        val schema = request.opt("schema_version")
        require((schema is Int || schema is Long) && (schema as Number).toLong() == 1L)
        require(request.opt("userInitiated") == true)
    }

    fun targetSize(width: Int, height: Int): Pair<Int, Int> {
        if (width !in 1..32768 || height !in 1..32768 || width.toLong() * height > 100_000_000L) {
            throw BridgeFailure("E_ASSISTANT_AVATAR_IMAGE")
        }
        val scale = minOf(1.0, MAX_DIMENSION.toDouble() / max(width, height))
        return max(1, (width * scale).roundToInt()) to max(1, (height * scale).roundToInt())
    }

    fun sampleSize(width: Int, height: Int): Int {
        targetSize(width, height)
        var sample = 1
        while (max(width, height) / sample > MAX_DIMENSION * 2) sample *= 2
        return sample
    }
}

/** A duplicate/late system result cannot settle a newer picker request. */
internal class AvatarPickLease<T> {
    private var pending: Pair<String, (T) -> Unit>? = null
    @Synchronized fun begin(reply: (T) -> Unit): String {
        if (pending != null) throw BridgeFailure("E_ASSISTANT_AVATAR_BUSY")
        return UUID.randomUUID().toString().also { pending = it to reply }
    }
    @Synchronized fun active(token: String): Boolean = pending?.first == token
    fun finish(token: String, value: T): Boolean {
        val callback = synchronized(this) {
            val request = pending?.takeIf { it.first == token } ?: return false
            pending = null
            request.second
        }
        callback(value)
        return true
    }
}
