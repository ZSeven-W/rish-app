package tech.zseven.rish.runtime

import android.system.Os
import android.system.OsConstants
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.util.UUID

/** Bounded, display-only copies of committed assistant rounds. Never Agent authority. */
internal class AndroidAgentRoundPresentations(private val root: File) {
    private val directory = File(root, "round-presentations-v1")

    fun cache(request: JSONObject, message: JSONObject, kind: String) = bestEffort {
        val conversation = request.optString("conversation_id")
        val attempt = request.optString("attempt_id")
        identity(conversation, attempt)
        synchronized(lock) {
            if (!storage()) return@synchronized
            val file = file(conversation, attempt)
            val value = reduce(envelope("upsert", conversation, attempt)
                .put("prior", readFile(file, conversation, attempt) ?: JSONObject.NULL)
                .put("round_id", request.opt("round_id") ?: JSONObject.NULL)
                // JSONObject otherwise serializes integral Double values as JSON integers.
                // Preserve the host type distinction before the shared core checks the index.
                .put("round_index", integerToken(request.opt("round_index")))
                .put("kind", kind)
                .put("text", message.opt("content") ?: JSONObject.NULL)
                .put("reasoning", message.opt("reasoning_content") ?: JSONObject.NULL))
                .getJSONObject("value")
            val bytes = value.toString().toByteArray(Charsets.UTF_8)
            if (bytes.size > MAX_FILE) return@synchronized
            val temporary = File(directory, ".${UUID.randomUUID()}.tmp")
            try {
                val descriptor = Os.open(temporary.path,
                    OsConstants.O_WRONLY or OsConstants.O_CREAT or OsConstants.O_EXCL or OsConstants.O_NOFOLLOW,
                    0x180)
                FileOutputStream(descriptor).use { it.write(bytes); it.fd.sync() }
                Os.rename(temporary.path, file.path)
                pruneLocked(null)
            } finally { temporary.delete() }
        }
    }

    /** WAL rows have already passed shared-core shape and digest validation. */
    fun read(conversation: String, attempt: String, state: JSONObject): JSONObject {
        identity(conversation, attempt)
        val cached = synchronized(lock) {
            if (safeDirectory()) readFile(file(conversation, attempt), conversation, attempt) else null
        }
        // Transport only this attempt's already-validated rows. The core owns the join,
        // assistant selection, validation, ordering and cache/WAL precedence.
        val rounds = JSONArray()
        state.optJSONArray("rounds")?.let { rows ->
            for (i in 0 until rows.length()) {
                val row = rows.getJSONObject(i)
                if (row.optJSONObject("locator")?.optString("attempt_id") == attempt) rounds.put(row)
            }
        }
        val transcripts = JSONArray()
        state.optJSONArray("transcripts")?.let { rows ->
            for (i in 0 until rows.length()) {
                val row = rows.getJSONObject(i)
                if (row.optString("attempt_id") == attempt) transcripts.put(row)
            }
        }
        return reduce(envelope("project", conversation, attempt)
            .put("cached", cached ?: JSONObject.NULL).put("rounds", rounds).put("transcripts", transcripts))
            .getJSONObject("value")
    }

    private fun identity(conversation: String, attempt: String) {
        reduce(envelope("identity", conversation, attempt))
    }

    private fun envelope(op: String, conversation: String, attempt: String) = JSONObject()
        .put("schema_version", 1).put("op", op)
        .put("conversation_id", conversation).put("attempt_id", attempt)

    private fun reduce(request: JSONObject): JSONObject {
        val reply = RishAgentCoreNative.roundPresentationReduce(request.toString())
            ?: error("the shared round presentation core produced no reply")
        val parsed = JSONObject(reply)
        check(parsed.optBoolean("ok")) { "the shared round presentation core refused: ${parsed.opt("error")}" }
        return parsed
    }

    fun prune(conversationIds: Set<String>? = null) = bestEffort {
        synchronized(lock) { if (safeDirectory()) pruneLocked(conversationIds) }
    }

    private fun pruneLocked(conversations: Set<String>?) {
        val retained = mutableListOf<File>()
        for (file in directory.listFiles().orEmpty()) {
            val parts = file.name.removeSuffix(".json").split('_')
            if (!file.name.endsWith(".json") || parts.size != 2 || !parts.all(::uuid)) continue
            val stat = try { Os.lstat(file.path) } catch (_: Exception) { continue }
            if (!OsConstants.S_ISREG(stat.st_mode) || stat.st_size > MAX_FILE ||
                (conversations != null && parts[0] !in conversations)) file.delete()
            else retained.add(file)
        }
        var total = retained.sumOf { it.length() }
        var count = retained.size
        for (file in retained.sortedBy { it.lastModified() }) {
            if (total <= MAX_TOTAL && count <= MAX_COUNT) break
            val size = file.length()
            if (file.delete()) { total -= size; count-- }
        }
    }

    private fun storage(): Boolean {
        if (!root.exists() && !root.mkdirs()) return false
        if (!directory.exists() && !directory.mkdir()) return false
        if (!safeDirectory()) return false
        Os.chmod(directory.path, 0x1c0)
        return true
    }

    private fun safeDirectory(): Boolean = try {
        OsConstants.S_ISDIR(Os.lstat(directory.path).st_mode)
    } catch (_: Exception) { false }

    private fun file(conversation: String, attempt: String) = File(directory, "${conversation}_${attempt}.json")

    private fun readFile(file: File, conversation: String, attempt: String): JSONObject? {
        return try {
            val descriptor = Os.open(file.path, OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW, 0)
            val bytes = FileInputStream(descriptor).use { input ->
                val stat = Os.fstat(input.fd)
                if (!OsConstants.S_ISREG(stat.st_mode) || stat.st_size !in 0..MAX_FILE.toLong()) return null
                // A concurrent cache replacement is atomic, but keep reads bounded even for corrupt files.
                val bytes = ByteArray(stat.st_size.toInt())
                var offset = 0
                while (offset < bytes.size) {
                    val count = input.read(bytes, offset, bytes.size - offset)
                    if (count <= 0) return null
                    offset += count
                }
                if (input.read() != -1) return null
                bytes
            }
            // Do not parse stored JSON through JSONObject: it accepts duplicate keys and
            // normalizes numeric tokens before the shared core can validate the archive.
            val raw = Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes)).toString()
            reduce(envelope("decode", conversation, attempt).put("archive_json", raw)).getJSONObject("value")
        } catch (_: Exception) { null }
    }

    private companion object {
        val lock = Any()
        const val MAX_FILE = 2 * 1024 * 1024
        const val MAX_TOTAL = 64 * 1024 * 1024
        const val MAX_COUNT = 256
        // Only filename recognition for native pruning; semantic identities belong to core.
        val UUID_PATTERN = Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
        fun uuid(value: String) = UUID_PATTERN.matches(value)
        fun integerToken(value: Any?): Any = when (value) {
            is Byte, is Short, is Int, is Long -> value
            else -> JSONObject.NULL
        }
        inline fun bestEffort(body: () -> Unit) { try { body() } catch (_: Exception) { /* Display loss never changes authority. */ } }
    }
}
