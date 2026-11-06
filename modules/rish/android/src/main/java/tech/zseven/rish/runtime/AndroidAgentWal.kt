package tech.zseven.rish.runtime

import android.system.Os
import android.system.OsConstants
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.util.UUID

/**
 * The agent WAL, in the same bytes iOS writes: one file per storage root named
 * `agent-native-wal-v1.json`, holding the whole state as canonical JSON, and
 * replaced by write-temp, fsync, rename, fsync-directory.
 *
 * The format is shared on purpose. Every rule about what a stored state may
 * look like already lives in the core, and a WAL pulled off a device replays
 * through the same golden harness whichever platform wrote it. SQLite would
 * have meant a second storage adapter and a second answer to "what is
 * committed".
 *
 * The core also holds the committed state between transactions behind an
 * opaque handle, so a transaction does not re-read the file to learn what is
 * committed — and the handle is trusted only while the file it was read from
 * is still the file on disk.
 */
internal class AndroidAgentWal(val root: File) {
    companion object {
        const val FILE_NAME = "agent-native-wal-v1.json"
        const val TEMPORARY_SUFFIX = ".tmp"
        const val MAX_BYTES = 64 * 1024 * 1024
        val launchId: String = UUID.randomUUID().toString()

        /** One resident state per root, never per instance: two owners of one
         *  state would overwrite each other's commits wholesale. */
        private val residents = HashMap<String, Resident>()
        private val locks = HashMap<String, Any>()

        @Synchronized private fun lockFor(key: String): Any =
            locks.getOrPut(key) { Any() }
    }

    /** What the host learned about the bytes it tried to write. */
    enum class Confirmation { COMMITTED, NOT_COMMITTED, UNKNOWN }

    private class Resident(var handle: Long, var identity: String?)

    private val key: String = root.canonicalPath
    private val file = File(root, FILE_NAME)
    private val temporary = File(root, FILE_NAME + TEMPORARY_SUFFIX)

    /** The freshly created state a missing file stands for. */
    private fun freshState(): JSONObject = JSONObject()
        .put("schema_version", 2).put("generation", 0)
        .apply {
            for (field in listOf("authorities", "operations", "operation_results",
                "transcripts", "rounds", "ledger", "reservations", "cleanup",
                "dispatch", "batches", "denied_calls")) {
                put(field, org.json.JSONArray())
            }
        }

    /**
     * The file's identity right now: device, inode, size and modification
     * time. A resident state is only trusted while this still matches what it
     * was read from, so anything that replaces the WAL behind our back — a
     * fixture, a restore, a future tool — is seen rather than served from
     * memory. `null` means the file is absent.
     */
    private fun identity(): String? = try {
        val stat = Os.stat(file.path)
        "${stat.st_dev}:${stat.st_ino}:${stat.st_size}:${stat.st_mtime}"
    } catch (_: android.system.ErrnoException) {
        null
    }

    private fun readCommitted(): JSONObject {
        if (!file.exists()) return freshState()
        val bytes = file.readBytes()
        check(bytes.size <= MAX_BYTES) { "E_AGENT_CAPACITY" }
        val text = String(bytes, Charsets.UTF_8)
        val canonical = RishAgentCoreNative.canonical(text)
        check(canonical != null && canonical == text) { "E_AGENT_CORRUPT: the WAL is not canonical" }
        val state = JSONObject(text)
        check(validate(state)) { "E_AGENT_CORRUPT: the WAL is not a state the core accepts" }
        return state
    }

    /** The whole stored state, judged by the same rules iOS loads it with. */
    private fun validate(state: JSONObject): Boolean {
        val verdicts = AndroidWalRowVerdicts.forState(state)
        val reply = RishAgentCoreNative.wal(JSONObject().put("op", "state_basic")
            .put("value", state).put("env", verdicts)) ?: return false
        return reply.optBoolean("valid")
    }

    /**
     * The committed state, from the resident handle when it still describes
     * the file on disk, and from the file itself otherwise.
     */
    private fun committedState(): JSONObject {
        // A leftover staging file is a writer that died between staging and
        // rename. It is checked before the resident state, because a cache
        // that answers from memory would hide exactly the hazard it proves.
        check(!temporary.exists()) { "E_AGENT_CORRUPT: a torn WAL transaction is staged" }
        val current = identity()
        val resident = residents[key]
        if (resident != null && resident.identity == current) {
            RishAgentCoreNative.snapshotWal(resident.handle)?.let { return JSONObject(it) }
            // The handle can no longer say what is committed; only the file can.
            RishAgentCoreNative.closeWal(resident.handle)
            residents.remove(key)
        }
        val state = readCommitted()
        // Loading does not settle an orphaned owner. In particular, a dispatched
        // assistant mutation must retain its row and transcript until recovery
        // queries the Rust store's atomic receipt; process death alone cannot
        // decide whether that mutation committed.
        residents[key]?.let { RishAgentCoreNative.closeWal(it.handle); residents.remove(key) }
        val handle = RishAgentCoreNative.openWal(state.toString())
        if (handle != 0L) residents[key] = Resident(handle, current)
        return state
    }

    /** Publishes or discards the candidate, by what the write established. */
    private fun publish(candidate: JSONObject, confirmation: Confirmation) {
        val resident = residents[key] ?: return
        if (confirmation != Confirmation.COMMITTED) {
            // An unknown outcome means the handle can no longer describe the
            // file either way, so it is dropped rather than guessed at.
            if (confirmation == Confirmation.UNKNOWN) {
                RishAgentCoreNative.closeWal(resident.handle)
                residents.remove(key)
            }
            return
        }
        val staged = RishAgentCoreNative.beginWal(resident.handle, candidate.toString())
        val reply = if (staged == null) null
            else RishAgentCoreNative.confirmWal(resident.handle, "committed")
        val published = reply != null && JSONObject(reply).optBoolean("published")
        if (!published) {
            RishAgentCoreNative.closeWal(resident.handle)
            residents.remove(key)
            return
        }
        resident.identity = identity()
    }

    /** Writes the state and reports which of the three states the write ended in. */
    private fun write(state: JSONObject): Pair<Boolean, Confirmation> {
        val canonical = RishAgentCoreNative.canonical(state.toString())
            ?: return false to Confirmation.NOT_COMMITTED
        val bytes = canonical.toByteArray(Charsets.UTF_8)
        if (bytes.size > MAX_BYTES) return false to Confirmation.NOT_COMMITTED
        if (temporary.exists()) return false to Confirmation.NOT_COMMITTED
        try {
            FileOutputStream(temporary).use { stream ->
                stream.write(bytes)
                stream.flush()
                stream.fd.sync()
            }
        } catch (_: Exception) {
            temporary.delete()
            return false to Confirmation.NOT_COMMITTED
        }
        // Until the rename takes effect nothing can have replaced the file.
        if (!temporary.renameTo(file)) {
            temporary.delete()
            return false to Confirmation.NOT_COMMITTED
        }
        // From here a failure no longer proves the rename did not happen.
        return try {
            // Opening a directory read-only is what the fsync needs; bionic
            // exposes no O_DIRECTORY constant and the path is known to be one.
            val directory = Os.open(root.path, OsConstants.O_RDONLY, 0)
            try { Os.fsync(directory) } finally { Os.close(directory) }
            true to Confirmation.COMMITTED
        } catch (_: android.system.ErrnoException) {
            false to Confirmation.UNKNOWN
        }
    }

    /**
     * One transaction: the committed state in, the candidate out. The mutation
     * returns false to abandon it. The per-root lock covers the whole of
     * "check the resident against disk, decide, write, confirm", because a
     * second writer that started from a stale state would overwrite this one's
     * commit wholesale.
     */
    fun transaction(mutation: (JSONObject) -> Boolean): Boolean = synchronized(lockFor(key)) {
        require(root.isDirectory || root.mkdirs()) { "E_AGENT_UNAVAILABLE" }
        val state = committedState()
        val candidate = JSONObject(state.toString())
        if (!mutation(candidate)) return false
        val generation = state.optLong("generation")
        check(generation < 9007199254740991L) { "E_AGENT_CAPACITY" }
        candidate.put("generation", generation + 1)
        check(validate(candidate)) { "E_AGENT_CORRUPT: the candidate is not a state the core accepts" }
        val (written, confirmation) = write(candidate)
        publish(candidate, confirmation)
        if (confirmation == Confirmation.UNKNOWN) {
            error("E_AGENT_PERSISTENCE: the WAL write neither committed nor provably failed")
        }
        return written
    }

    /** The committed state, for readers. */
    fun snapshot(): JSONObject = synchronized(lockFor(key)) { committedState() }
}
