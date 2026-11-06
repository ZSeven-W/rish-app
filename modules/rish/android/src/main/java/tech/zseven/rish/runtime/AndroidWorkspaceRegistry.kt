package tech.zseven.rish.runtime

import android.system.Os
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.text.Normalizer
import java.util.Locale
import java.util.UUID

/**
 * Android's workspace registry: app-private roots, their authorities, and the
 * grants they imply.
 *
 * **Scope, stated plainly.** Only the `rish_created` origin can exist here.
 * Android has no security-scoped bookmarks and no legacy iOS projects, so the
 * granted and legacy shapes are unreachable on this platform — they are
 * rejected, not stubbed. There is no rebinding yet either: an app-private
 * directory keeps its identity for as long as the app is installed, and the
 * one event that changes it (reinstall) takes the data with it. So every
 * record here is at `binding_revision` 1.
 *
 * **What is written is what iOS writes.** The record, the authority and the
 * fingerprint are the same JSON shapes, validated by the same core rules
 * ([RishAgentCoreNative.workspaceRecord], `workspaceAuthority`,
 * `workspaceFingerprint`), so growing into rebinding later is new code over
 * the same bytes rather than a migration.
 *
 * **Folding is this host's own.** iOS folds with Foundation under
 * `en_US_POSIX`; here it is NFD, combining marks dropped, lowercased in the
 * root locale. The two do not always agree, and they do not have to: a folded
 * name is never stored, only compared against other names on the same device.
 * What *is* stored — the record, the authority, the fingerprint — goes through
 * the shared rules.
 */
internal class AndroidWorkspaceRegistry(val root: File) {
    companion object {
        /** The container that holds every owned workspace directory. */
        const val CONTAINER_NAME = "Rish Workspaces"
        private const val REGISTRY_NAME = "registry.json"
        private const val RECEIPTS_NAME = "receipts.json"
        private const val BINDINGS_DIR = "bindings"
        private const val REMOVALS_DIR = "removals"
        private const val JOURNAL_SUFFIX = ".journal.json"
        private const val CONTENT_SUFFIX = "-content"
        private const val GITDIRS_SUFFIX = "-gitdirs"
        private const val PHASE_PREPARED = "prepared"
        private const val PHASE_QUARANTINED = "quarantined"
        private const val PHASE_PUBLISHED = "published"
        private const val HOLD_DRAIN_MS = 3000L
        private val OWNED_ORIGINS = setOf("rish_created", "imported")

        /**
         * The empty registry. Generation 0 with no records is what a fresh
         * install has, and it is a state, not an absence.
         */
        fun emptyRegistry(): JSONObject = JSONObject()
            .put("schema_version", 1).put("generation", 0)
            .put("records", JSONArray())

        /** The empty receipt store, which a fresh install has. */
        fun emptyReceipts(): JSONObject = JSONObject()
            .put("schema_version", 1).put("receipts", JSONArray())

        /**
         * This host's folding. Not Foundation's, and it does not claim to be.
         */
        fun folded(component: String): String =
            Normalizer.normalize(component, Normalizer.Form.NFD)
                .replace(Regex("\\p{Mn}+"), "")
                .lowercase(Locale.ROOT)

        /** Grapheme clusters, in order, for the truncation projection. */
        fun graphemes(text: String): JSONArray {
            val clusters = JSONArray()
            val iterator = java.text.BreakIterator.getCharacterInstance(Locale.ROOT)
            iterator.setText(text)
            var start = iterator.first()
            var end = iterator.next()
            while (end != java.text.BreakIterator.DONE) {
                clusters.put(text.substring(start, end))
                start = end
                end = iterator.next()
            }
            return clusters
        }

        private fun sha256(bytes: ByteArray): String =
            MessageDigest.getInstance("SHA-256").digest(bytes)
                .joinToString("") { "%02x".format(it) }
    }

    /** Why a workspace could not be created or opened. */
    class Refused(val code: String) : Exception(code)

    private val container = File(root, CONTAINER_NAME)
    private val registryFile = File(root, REGISTRY_NAME)
    private val receiptsFile = File(root, RECEIPTS_NAME)
    private val bindings = File(root, BINDINGS_DIR)
    private val removals = File(root, REMOVALS_DIR)

    private val lock = Any()

    /** The committed registry, or the empty one on a fresh install. */
    fun registry(): JSONObject = synchronized(lock) { loadRegistry() }

    private fun loadRegistry(): JSONObject {
        if (!registryFile.exists()) return emptyRegistry()
        val bytes = try {
            registryFile.readBytes()
        } catch (_: Exception) {
            throw Refused("E_WORKSPACE_PERSISTENCE")
        }
        // Before the parse: one complete value, bounded in depth and nodes, no
        // duplicate keys, no negative zero. A corrupt file costs a refusal
        // rather than an unbounded walk, and `JSONObject` would have taken the
        // *last* of two duplicate keys without saying so.
        if (!RishAgentCoreNative.workspaceJsonBounded(bytes)) {
            throw Refused("E_WORKSPACE_CORRUPT")
        }
        val parsed = try {
            JSONObject(String(bytes, Charsets.UTF_8))
        } catch (_: Exception) {
            // A registry that will not parse is corrupt. It is never silently
            // replaced with an empty one: that would lose every binding.
            throw Refused("E_WORKSPACE_CORRUPT")
        }
        // The whole shape is the shared rule's: the envelope, the capacity,
        // every record, the ascending order, and the uniqueness of the folded
        // directory names. Only the folding is this host's.
        val records = parsed.optJSONArray("records")
        val foldings = JSONArray()
        if (records != null) {
            for (index in 0 until records.length()) {
                val record = records.optJSONObject(index)
                val display = record?.opt("display_name")
                val directory = record?.opt("owned_directory_name")
                foldings.put(
                    JSONObject()
                        .put(
                            "display_name",
                            if (display is String) folded(display) else JSONObject.NULL,
                        )
                        .put(
                            "directory_name",
                            if (directory is String) folded(directory) else JSONObject.NULL,
                        ),
                )
            }
        }
        val reply = RishAgentCoreNative.workspaceRecord(
            JSONObject().put("op", "registry_shape").put("registry", parsed)
                .put("folded", foldings),
        )
        if (reply?.optBoolean("valid") != true) throw Refused("E_WORKSPACE_CORRUPT")
        return parsed
    }

    /**
     * Creates an app-private workspace and returns its record.
     *
     * The order is deliberate: the directory, then the authority, then the
     * registry. A crash after the authority leaves an orphan nothing points
     * at; a crash the other way round would leave a record whose root cannot
     * be proven, which is the failure that matters.
     */
    fun create(
        displayName: String,
        workspaceId: String = UUID.randomUUID().toString(),
        now: String = RuntimeJson.now(),
        operationId: String = UUID.randomUUID().toString(),
    ): JSONObject = synchronized(lock) {
        if (!RishAgentCoreNative.available) throw Refused("E_WORKSPACE_UNAVAILABLE")
        if (!RuntimeJson.uuid(workspaceId)) throw Refused("E_WORKSPACE_INVALID")
        if (!RuntimeJson.uuid(operationId)) throw Refused("E_WORKSPACE_INVALID")
        // A retried operation is the one that already happened, not a second
        // one. Without this a crash between the directory and the registry
        // would leave the person with two workspaces where they asked for one.
        replayedRecord(operationId, displayName)?.let { return@synchronized it }
        val registry = loadRegistry()
        if (recordFor(registry, workspaceId) != null) throw Refused("E_WORKSPACE_CONFLICT")
        // A full registry refuses rather than dropping a binding somebody uses.
        val room = RishAgentCoreNative.workspaceRecord(
            JSONObject().put("op", "registry_has_room")
                .put("count", registry.getJSONArray("records").length()),
        )
        if (room?.optBoolean("has_room") != true) throw Refused("E_WORKSPACE_BUSY")
        if (!container.isDirectory && !container.mkdirs()) {
            throw Refused("E_WORKSPACE_PERSISTENCE")
        }
        val directoryName = allocateDirectoryName(displayName, registry)
        val record = JSONObject()
            .put("schema_version", 1)
            .put("workspace_id", workspaceId)
            .put("display_name", displayName)
            .put("origin", "rish_created")
            .put("root_locator_kind", "documents_owned")
            .put("location_class", "rish_owned")
            .put("owned_directory_name", directoryName)
            .put("legacy_project_id", JSONObject.NULL)
            .put("binding_revision", 1)
            .put("created_at", now)
            .put("last_opened_at", now)
        if (!recordValid(record)) throw Refused("E_WORKSPACE_INVALID")

        val directory = File(container, directoryName)
        if (directory.exists()) throw Refused("E_WORKSPACE_CONFLICT")
        if (!directory.mkdir()) throw Refused("E_WORKSPACE_PERSISTENCE")

        val authority = sealAuthority(record, directory, now)
        writeJson(authorityFile(workspaceId, 1), authority)

        // Records are stored in ascending workspace id order, because the
        // registry's canonical JSON is what a journal's
        // `previous_registry_sha256` is taken over: the same records in a
        // different order digest differently. Appending would have written a
        // registry this device could no longer read.
        val records = insertedInOrder(registry.getJSONArray("records"), record)
        val generation = registry.getInt("generation") + 1
        val published = JSONObject().put("schema_version", 1)
            .put("generation", generation).put("records", records)
        writeJson(registryFile, published)
        // The receipt is written last, so a crash before it leaves an
        // unreceipted workspace rather than a receipt for one that is not
        // there. A retry then finds no receipt and refuses on the directory
        // that already exists, which is a visible failure instead of a silent
        // second workspace.
        val digest = RishAgentCoreNative.workspaceJournal(
            JSONObject().put("op", "create_request_sha256")
                .put("display_name", displayName),
        )?.optString("digest")
        if (digest.isNullOrEmpty()) throw Refused("E_WORKSPACE_PERSISTENCE")
        writeReceipt(operationId, workspaceId, 1, "create", "committed", generation, published, digest, now)
        record
    }

    /**
     * The records the registry holds that are still provable: the record shape
     * is valid, its authority is the one the record implies, and the directory
     * is still the one the authority was sealed over. Anything else is left
     * out rather than repaired — repair is a rebind, and there is none yet.
     */
    fun list(): List<JSONObject> = synchronized(lock) {
        val records = loadRegistry().getJSONArray("records")
        (0 until records.length()).mapNotNull { index ->
            val record = records.optJSONObject(index) ?: return@mapNotNull null
            if (!recordValid(record)) return@mapNotNull null
            if (authorityFor(record) == null) return@mapNotNull null
            record
        }
    }

    /**
     * The root directory of a provable workspace, or null. Proving it means
     * re-reading the authority and re-stating the directory: a folder that was
     * replaced since the authority was written is not that workspace's root,
     * however matching its name.
     */
    fun rootFor(workspaceId: String): File? = synchronized(lock) {
        val record = recordFor(loadRegistry(), workspaceId) ?: return null
        if (!recordValid(record)) return null
        if (authorityFor(record) == null) return null
        File(container, record.getString("owned_directory_name"))
    }

    /**
     * The receipt store, or the empty one. A store the shared rule refuses is
     * corrupt: it is never replaced with an empty one, because that would let
     * every operation in it run a second time.
     */
    fun receipts(): JSONObject = synchronized(lock) { loadReceipts() }

    private fun loadReceipts(): JSONObject {
        if (!receiptsFile.exists()) return emptyReceipts()
        val bytes = try {
            receiptsFile.readBytes()
        } catch (_: Exception) {
            throw Refused("E_WORKSPACE_PERSISTENCE")
        }
        if (!RishAgentCoreNative.workspaceJsonBounded(bytes)) {
            throw Refused("E_WORKSPACE_CORRUPT")
        }
        val parsed = try {
            JSONObject(String(bytes, Charsets.UTF_8))
        } catch (_: Exception) {
            throw Refused("E_WORKSPACE_CORRUPT")
        }
        val reply = RishAgentCoreNative.workspaceReceipt(
            JSONObject().put("op", "store_shape").put("envelope", parsed),
        )
        if (reply?.optBoolean("valid") != true) throw Refused("E_WORKSPACE_CORRUPT")
        return parsed
    }

    /** What a caller is shown of an operation, or null if it never happened. */
    fun queryOperation(operationId: String): JSONObject? = synchronized(lock) {
        val receipt = receiptFor(loadReceipts(), operationId) ?: return null
        RishAgentCoreNative.workspaceReceipt(
            JSONObject().put("op", "public_receipt").put("receipt", receipt),
        )?.optJSONObject("receipt")
    }

    private fun receiptFor(store: JSONObject, operationId: String): JSONObject? {
        val receipts = store.getJSONArray("receipts")
        for (index in 0 until receipts.length()) {
            val receipt = receipts.optJSONObject(index) ?: continue
            if (receipt.optString("operation_id") == operationId) return receipt
        }
        return null
    }

    /**
     * The record a receipt names, when this operation already ran *and* the
     * request was the same one. A receipt whose request digest disagrees is a
     * different operation reusing an id, and it is refused rather than
     * answered with somebody else's workspace.
     */
    private fun replayedRecord(operationId: String, displayName: String): JSONObject? {
        val receipt = receiptFor(loadReceipts(), operationId) ?: return null
        val expected = RishAgentCoreNative.workspaceJournal(
            JSONObject().put("op", "create_request_sha256")
                .put("display_name", displayName),
        )?.optString("digest")
        if (expected.isNullOrEmpty() ||
            receipt.optString("request_sha256") != expected
        ) {
            throw Refused("E_WORKSPACE_CONFLICT")
        }
        val record = recordFor(loadRegistry(), receipt.optString("workspace_id"))
            ?: throw Refused("E_WORKSPACE_PERSISTENCE")
        return record
    }

    private fun writeReceipt(
        operationId: String,
        workspaceId: String,
        revision: Int,
        operation: String,
        outcome: String,
        generation: Int,
        published: JSONObject,
        requestDigest: String,
        now: String,
    ) {
        val store = loadReceipts()
        val canonical = RishAgentCoreNative.canonical(published.toString())
            ?: throw Refused("E_WORKSPACE_PERSISTENCE")
        val receipt = JSONObject()
            .put("schema_version", 1)
            .put("operation_id", operationId)
            .put("workspace_id", workspaceId)
            .put("operation", operation)
            .put("binding_revision", revision)
            // The generation and digest of the registry this committed
            // *against*, so a receipt describes one state of the store.
            .put("registry_generation", generation)
            .put("registry_sha256", sha256(canonical.toByteArray(Charsets.UTF_8)))
            .put("request_sha256", requestDigest)
            .put("outcome", outcome)
            .put("committed_at", now)
        val reply = RishAgentCoreNative.workspaceReceipt(
            JSONObject().put("op", "receipt_shape").put("receipt", receipt),
        )
        if (reply?.optBoolean("valid") != true) throw Refused("E_WORKSPACE_PERSISTENCE")
        val room = RishAgentCoreNative.workspaceReceipt(
            JSONObject().put("op", "has_room")
                .put("count", store.getJSONArray("receipts").length()),
        )
        if (room?.optBoolean("has_room") != true) throw Refused("E_WORKSPACE_BUSY")
        val receipts = store.getJSONArray("receipts")
        receipts.put(receipt)
        writeJson(
            receiptsFile,
            JSONObject().put("schema_version", 1).put("receipts", receipts),
        )
    }

    /** Refuses now, before anything moves, if no receipt could be written afterwards. */
    private fun reserveReceiptRoom() {
        val room = RishAgentCoreNative.workspaceReceipt(
            JSONObject().put("op", "has_room")
                .put("count", loadReceipts().getJSONArray("receipts").length()),
        )
        if (room?.optBoolean("has_room") != true) throw Refused("E_WORKSPACE_BUSY")
    }

    /** Rewrites one receipt's outcome in place; the store keeps its order. */
    private fun settleReceipt(operationId: String, outcome: String, now: String) {
        val store = loadReceipts()
        val receipts = store.getJSONArray("receipts")
        val rewritten = JSONArray()
        var found = false
        for (index in 0 until receipts.length()) {
            val receipt = receipts.getJSONObject(index)
            if (receipt.optString("operation_id") == operationId) {
                found = true
                val settled = JSONObject(receipt.toString()).put("outcome", outcome).put("committed_at", now)
                val reply = RishAgentCoreNative.workspaceReceipt(
                    JSONObject().put("op", "receipt_shape").put("receipt", settled),
                )
                if (reply?.optBoolean("valid") != true) throw Refused("E_WORKSPACE_PERSISTENCE")
                rewritten.put(settled)
            } else {
                rewritten.put(receipt)
            }
        }
        if (!found) throw Refused("E_WORKSPACE_PERSISTENCE")
        writeJson(receiptsFile, JSONObject().put("schema_version", 1).put("receipts", rewritten))
    }

    // --- holds -----------------------------------------------------------------
    //
    // Work that uses a root holds the workspace while it runs -- a git
    // operation, a file tool, a context capture, a clone. Removing a
    // workspace waits for its holds to drain and refuses new ones for as long
    // as it runs, so no operation ever finds its directory renamed from under
    // it. The wait is bounded: a hold that will not drain is a busy workspace,
    // not one to take apart anyway.

    private val holdLock = Object()
    private val holds = HashMap<String, Int>()
    private val removing = HashSet<String>()

    fun <T> holding(workspaceId: String, body: () -> T): T {
        synchronized(holdLock) {
            if (workspaceId in removing) throw Refused("E_WORKSPACE_BUSY")
            holds[workspaceId] = (holds[workspaceId] ?: 0) + 1
        }
        try {
            return body()
        } finally {
            synchronized(holdLock) {
                val left = (holds[workspaceId] ?: 1) - 1
                if (left <= 0) holds.remove(workspaceId) else holds[workspaceId] = left
                holdLock.notifyAll()
            }
        }
    }

    /** Runs [body] with the workspace closed to new work and none in flight, or refuses busy. */
    fun <T> removing(workspaceId: String, body: () -> T): T {
        synchronized(holdLock) {
            if (workspaceId in removing) throw Refused("E_WORKSPACE_BUSY")
            removing.add(workspaceId)
            val deadline = System.currentTimeMillis() + HOLD_DRAIN_MS
            while ((holds[workspaceId] ?: 0) > 0) {
                val left = deadline - System.currentTimeMillis()
                if (left <= 0) {
                    removing.remove(workspaceId)
                    throw Refused("E_WORKSPACE_BUSY")
                }
                holdLock.wait(left)
            }
        }
        try {
            return body()
        } finally {
            synchronized(holdLock) { removing.remove(workspaceId) }
        }
    }

    // --- forgetting and deleting -------------------------------------------------
    //
    // Forgetting removes the registration and its authority and leaves the
    // directory where it is. Deleting removes the directory too, and the
    // private gitdirs beside the registry that belong to it, through a
    // journal written before anything moves: every step after it -- the two
    // renames into quarantine, the authority, the registry, the receipt, the
    // purge -- is a crash boundary the journal lets the next launch cross.
    //
    // Whether either may happen at all is not decided here. The clearance --
    // that no conversation still names the workspace -- is the session
    // store's, and the caller holds it while this runs.

    /**
     * Whether a workspace is one a clearance could be issued for: registered
     * at this revision, owned, provable, and not already being removed. What
     * iOS proves in `validateWorkspaceForClearanceId:`.
     */
    fun clearable(workspaceId: String, revision: Int): Boolean = synchronized(lock) {
        val record = recordFor(loadRegistry(), workspaceId) ?: return false
        if (record.optInt("binding_revision") != revision || !recordValid(record)) return false
        if (record.optString("root_locator_kind") != "documents_owned" ||
            record.optString("origin") !in OWNED_ORIGINS
        ) {
            return false
        }
        if (authorityFor(record) == null) return false
        synchronized(holdLock) { workspaceId !in removing }
    }

    /** Whether a delete's intent is journaled and not yet finished. */
    fun removalJournaled(operationId: String): Boolean = synchronized(lock) {
        RuntimeJson.uuid(operationId) && journalFile(operationId).isFile
    }

    /** The removal receipt an operation already earned, or null. */
    fun removalReceipt(operationId: String): JSONObject? = synchronized(lock) {
        receiptFor(loadReceipts(), operationId)?.takeIf {
            it.optString("operation") == "forget" || it.optString("operation") == "delete_owned"
        }
    }

    /**
     * `forget`: the registry without this record, the authority gone, a
     * receipt. The directory and any private gitdir stay exactly where they
     * are: forgetting is about the registration, never the content.
     */
    fun forget(
        workspaceId: String,
        expectedRevision: Int,
        operationId: String,
        clearanceReceiptId: String,
        now: String = RuntimeJson.now(),
    ): JSONObject = synchronized(lock) {
        if (!RishAgentCoreNative.available) throw Refused("E_WORKSPACE_UNAVAILABLE")
        val digest = removalDigest("forget", workspaceId, expectedRevision, clearanceReceiptId)
        replayedRemoval(operationId, "forget", workspaceId, digest)?.let { return@synchronized forgotten() }
        val registry = loadRegistry()
        val record = recordFor(registry, workspaceId) ?: throw Refused("E_WORKSPACE_NOT_FOUND")
        if (record.optInt("binding_revision") != expectedRevision) throw Refused("E_WORKSPACE_STALE")
        reserveReceiptRoom()
        val (generation, published) = publishWithout(registry, workspaceId)
        authorityFile(workspaceId, expectedRevision).delete()
        // The receipt is written last, as for create: a crash before it leaves
        // a registry without the record and no receipt, and a retry finds
        // nothing to forget -- a visible refusal, never a receipt for a
        // registration that is still there.
        writeReceipt(operationId, workspaceId, expectedRevision, "forget", "committed", generation, published, digest, now)
        forgotten()
    }

    /**
     * `deleteOwnedContent`, journaled. Returns only once the content is gone:
     * a delete that reported success with the files still on disk would be
     * the worst possible lie here. A crash part-way leaves the journal, and
     * [sweepRemovals] or a retry of the same operation finishes it.
     */
    fun deleteOwned(
        workspaceId: String,
        expectedRevision: Int,
        operationId: String,
        clearanceReceiptId: String,
        expectedRegistryGeneration: Int?,
        now: String = RuntimeJson.now(),
    ): JSONObject = synchronized(lock) {
        if (!RishAgentCoreNative.available) throw Refused("E_WORKSPACE_UNAVAILABLE")
        val digest = removalDigest("delete_owned", workspaceId, expectedRevision, clearanceReceiptId)
        replayedRemoval(operationId, "delete_owned", workspaceId, digest)?.let { receipt ->
            // Committed means purged. Pending means the purge was interrupted,
            // and answering "deleted" now would have to be earned first.
            if (receipt.optString("outcome") == "purge_pending") {
                val journal = readJson(journalFile(operationId)) ?: throw Refused("E_WORKSPACE_PERSISTENCE")
                resumeRemoval(journal, now)
            }
            return@synchronized deleted()
        }
        // An interrupted journal for this operation is this operation, resumed.
        readJson(journalFile(operationId))?.let { journal ->
            if (journal.optString("workspace_id") != workspaceId || journal.optString("request_sha256") != digest) {
                throw Refused("E_WORKSPACE_CONFLICT")
            }
            resumeRemoval(journal, now)
            return@synchronized deleted()
        }
        val registry = loadRegistry()
        val record = recordFor(registry, workspaceId) ?: throw Refused("E_WORKSPACE_NOT_FOUND")
        if (record.optInt("binding_revision") != expectedRevision) throw Refused("E_WORKSPACE_STALE")
        if (expectedRegistryGeneration != null && registry.getInt("generation") != expectedRegistryGeneration) {
            throw Refused("E_WORKSPACE_STALE")
        }
        if (record.optString("root_locator_kind") != "documents_owned" ||
            record.optString("origin") !in OWNED_ORIGINS
        ) {
            throw Refused("E_WORKSPACE_CONFLICT")
        }
        if (authorityFor(record) == null) throw Refused("E_WORKSPACE_CONFLICT")
        reserveReceiptRoom()
        val directoryName = record.getString("owned_directory_name")
        val content = identityOf(File(container, directoryName)) ?: throw Refused("E_WORKSPACE_CONFLICT")
        val gitdirs = File(File(root, AndroidWorkspaceProjects.GITDIRS_NAME), workspaceId)
        val gitIdentity = if (gitdirs.isDirectory) identityOf(gitdirs) else null
        val canonical = RishAgentCoreNative.canonical(registry.toString()) ?: throw Refused("E_WORKSPACE_PERSISTENCE")
        val journal = JSONObject()
            .put("schema_version", 1)
            .put("operation_id", operationId)
            .put("workspace_id", workspaceId)
            .put("operation", "delete_owned")
            .put("binding_revision", expectedRevision)
            .put("clearance_receipt_id", clearanceReceiptId)
            .put("request_sha256", digest)
            .put("directory_name", directoryName)
            .put("content_device_id", content.first)
            .put("content_inode_id", content.second)
            .put("gitdirs_device_id", gitIdentity?.first ?: JSONObject.NULL)
            .put("gitdirs_inode_id", gitIdentity?.second ?: JSONObject.NULL)
            .put("previous_registry_generation", registry.getInt("generation"))
            .put("previous_registry_sha256", sha256(canonical.toByteArray(Charsets.UTF_8)))
            .put("phase", PHASE_PREPARED)
            .put("created_at", now)
            .put("updated_at", now)
        if (!removals.isDirectory && !removals.mkdirs()) throw Refused("E_WORKSPACE_PERSISTENCE")
        // The intent, durable before the first rename. From here the
        // operation finishes or is finished by the next launch; the
        // confirmation the caller consumed is not asked for again.
        writeJson(journalFile(operationId), journal)
        resumeRemoval(journal, now)
        deleted()
    }

    /**
     * Finishes every interrupted removal the journals describe. A journal
     * that cannot be finished -- a purge that still fails -- is left for the
     * next call rather than allowed to stop the others.
     */
    fun sweepRemovals(now: String = RuntimeJson.now()): Int = synchronized(lock) {
        if (!RishAgentCoreNative.available) return 0
        var finished = 0
        val files = removals.listFiles { file -> file.isFile && file.name.endsWith(JOURNAL_SUFFIX) } ?: return 0
        for (file in files.sortedBy { it.name }) {
            val journal = readJson(file) ?: continue
            try {
                resumeRemoval(journal, now)
                finished += 1
            } catch (_: Refused) {
                // Left in place: the journal is the record that it is unfinished.
            }
        }
        finished
    }

    /**
     * Carries a removal from whatever phase its journal records to the end.
     * Each phase re-derives what it needs from disk instead of trusting the
     * phase alone, because a crash lands between any two writes.
     */
    private fun resumeRemoval(journal: JSONObject, now: String) {
        val operationId = journal.getString("operation_id")
        val workspaceId = journal.getString("workspace_id")
        val revision = journal.getInt("binding_revision")
        val file = journalFile(operationId)
        val original = File(container, journal.getString("directory_name"))
        val quarantinedContent = File(removals, operationId + CONTENT_SUFFIX)
        val originalGitdirs = File(File(root, AndroidWorkspaceProjects.GITDIRS_NAME), workspaceId)
        val quarantinedGitdirs = File(removals, operationId + GITDIRS_SUFFIX)
        val content = Pair(journal.getString("content_device_id"), journal.getString("content_inode_id"))
        val gitIdentity = if (journal.isNull("gitdirs_device_id")) null
            else Pair(journal.getString("gitdirs_device_id"), journal.getString("gitdirs_inode_id"))
        var phase = journal.getString("phase")

        if (phase == PHASE_PREPARED) {
            quarantine(original, quarantinedContent, content)
            if (gitIdentity != null) quarantine(originalGitdirs, quarantinedGitdirs, gitIdentity)
            phase = PHASE_QUARANTINED
            writeJson(file, JSONObject(journal.toString()).put("phase", phase).put("updated_at", now))
        }
        if (phase == PHASE_QUARANTINED) {
            val registry = loadRegistry()
            val record = recordFor(registry, workspaceId)
            if (record != null) {
                if (record.optInt("binding_revision") != revision) throw Refused("E_WORKSPACE_CONFLICT")
                val (generation, published) = publishWithout(registry, workspaceId)
                authorityFile(workspaceId, revision).delete()
                if (receiptFor(loadReceipts(), operationId) == null) {
                    writeReceipt(
                        operationId, workspaceId, revision, "delete_owned", "purge_pending",
                        generation, published, journal.getString("request_sha256"), now,
                    )
                }
            } else {
                authorityFile(workspaceId, revision).delete()
                if (receiptFor(loadReceipts(), operationId) == null) {
                    writeReceipt(
                        operationId, workspaceId, revision, "delete_owned", "purge_pending",
                        registry.getInt("generation"), registry, journal.getString("request_sha256"), now,
                    )
                }
            }
            phase = PHASE_PUBLISHED
            writeJson(file, JSONObject(journal.toString()).put("phase", phase).put("updated_at", now))
        }
        if (phase == PHASE_PUBLISHED) {
            purge(quarantinedContent, content)
            if (gitIdentity != null) purge(quarantinedGitdirs, gitIdentity)
            if (quarantinedContent.exists() || quarantinedGitdirs.exists()) throw Refused("E_WORKSPACE_PERSISTENCE")
            settleReceipt(operationId, "committed", now)
            if (!file.delete() && file.exists()) throw Refused("E_WORKSPACE_PERSISTENCE")
        }
    }

    /**
     * Moves a directory into quarantine, or finds it already there. The
     * identity the journal recorded has to match at whichever place it is:
     * a directory replaced since the intent was written is not the one the
     * person agreed to delete.
     */
    private fun quarantine(original: File, quarantined: File, identity: Pair<String, String>) {
        val atOrigin = identityOf(original)
        val atQuarantine = identityOf(quarantined)
        when {
            atQuarantine == identity -> return
            atOrigin == identity && atQuarantine == null -> {
                if (!original.renameTo(quarantined)) throw Refused("E_WORKSPACE_PERSISTENCE")
                fsync(original.parentFile ?: container)
                fsync(removals)
            }
            else -> throw Refused("E_WORKSPACE_CONFLICT")
        }
    }

    /** Unlinks a quarantined tree after proving it is the one the journal names. */
    private fun purge(quarantined: File, identity: Pair<String, String>) {
        val found = identityOf(quarantined) ?: return
        if (found != identity) throw Refused("E_WORKSPACE_CONFLICT")
        if (!quarantined.deleteRecursively()) throw Refused("E_WORKSPACE_PERSISTENCE")
        fsync(removals)
    }

    private fun fsync(directory: File) {
        try {
            val descriptor = Os.open(directory.absolutePath, android.system.OsConstants.O_RDONLY, 0)
            try { Os.fsync(descriptor) } finally { Os.close(descriptor) }
        } catch (_: Exception) {
            // A directory that cannot be synced is still renamed; the journal
            // re-derives the state from disk either way.
        }
    }

    /** The registry with [workspaceId]'s record taken out, written and returned with its generation. */
    private fun publishWithout(registry: JSONObject, workspaceId: String): Pair<Int, JSONObject> {
        val records = registry.getJSONArray("records")
        val remaining = JSONArray()
        for (index in 0 until records.length()) {
            val record = records.getJSONObject(index)
            if (record.optString("workspace_id") != workspaceId) remaining.put(record)
        }
        val generation = registry.getInt("generation") + 1
        val published = JSONObject().put("schema_version", 1)
            .put("generation", generation).put("records", remaining)
        writeJson(registryFile, published)
        return Pair(generation, published)
    }

    /**
     * The receipt a removal already earned, when the request was the same
     * one. A receipt for the same operation id and a different request is
     * an id being reused, and is refused.
     */
    private fun replayedRemoval(operationId: String, operation: String, workspaceId: String, digest: String): JSONObject? {
        val receipt = receiptFor(loadReceipts(), operationId) ?: return null
        if (receipt.optString("operation") != operation || receipt.optString("workspace_id") != workspaceId ||
            receipt.optString("request_sha256") != digest
        ) {
            throw Refused("E_WORKSPACE_CONFLICT")
        }
        return receipt
    }

    /** The idempotency binding of a removal request: what was asked, not by whom. */
    private fun removalDigest(action: String, workspaceId: String, revision: Int, clearanceReceiptId: String): String {
        if (!RuntimeJson.uuid(workspaceId) || !RuntimeJson.uuid(clearanceReceiptId) || revision < 1) {
            throw Refused("E_WORKSPACE_INVALID")
        }
        return RishAgentCoreNative.hash(
            "workspace_removal_request",
            JSONObject().put("action", action).put("workspace_id", workspaceId)
                .put("expected_binding_revision", revision).put("clearance_receipt_id", clearanceReceiptId),
        )
    }

    private fun forgotten(): JSONObject = JSONObject().put("schema_version", 1).put("status", "forgotten")
    private fun deleted(): JSONObject = JSONObject().put("schema_version", 1).put("status", "deleted")
    private fun journalFile(operationId: String): File = File(removals, operationId + JOURNAL_SUFFIX)

    /**
     * The root fingerprint of a provable workspace, or null. It is read from
     * the authority rather than recomputed: the authority is the thing that
     * was verified, and it is only handed back while it still proves the
     * directory on disk.
     */
    fun fingerprintFor(workspaceId: String): String? = synchronized(lock) {
        val record = recordFor(loadRegistry(), workspaceId) ?: return null
        if (!recordValid(record)) return null
        val authority = authorityFor(record) ?: return null
        authority.optString("root_fingerprint_sha256").takeIf { it.length == 64 }
    }

    /**
     * What an agent may do with this workspace, as the shared rule states it.
     * A root that cannot be proven grants nothing — not "read only", nothing.
     */
    fun descriptor(workspaceId: String): JSONObject? = synchronized(lock) {
        val record = recordFor(loadRegistry(), workspaceId) ?: return null
        if (!recordValid(record)) return null
        // Deriving the status is this host's job — it stats a directory. What
        // the status *means* is the rule's, so the grants are asked for.
        val status = if (authorityFor(record) != null) "ok" else "root_changed"
        val grants = RishAgentCoreNative.workspaceGrants(
            JSONObject().put("op", "operational_grants")
                .put("locator_kind", record.optString("root_locator_kind"))
                .put("status", status),
        )?.optJSONArray("grants") ?: return null
        val reply = RishAgentCoreNative.workspaceGrants(
            JSONObject().put("op", "descriptor").put("record", record)
                .put("status", status).put("grants", grants),
        ) ?: return null
        reply.optJSONObject("descriptor")
    }


    // --- rules, asked rather than answered -------------------------------

    private fun recordValid(record: JSONObject): Boolean {
        val display = record.opt("display_name")
        val directory = record.opt("owned_directory_name")
        val reply = RishAgentCoreNative.workspaceRecord(
            JSONObject().put("op", "record_shape").put("record", record)
                .put(
                    "folded_display_name",
                    if (display is String) folded(display) else JSONObject.NULL,
                )
                .put(
                    "folded_directory_name",
                    if (directory is String) folded(directory) else JSONObject.NULL,
                ),
        ) ?: return false
        return reply.optBoolean("valid")
    }

    /**
     * The authority for a record, if it is still the record's own and still
     * describes the directory on disk. Everything about *what makes it valid*
     * is the core's; what is on disk is this host's.
     */
    private fun authorityFor(record: JSONObject): JSONObject? {
        val workspaceId = record.optString("workspace_id")
        val revision = record.opt("binding_revision") as? Int ?: return null
        val file = authorityFile(workspaceId, revision)
        val authority = readJson(file) ?: return null
        val reply = RishAgentCoreNative.workspaceAuthority(
            JSONObject().put("op", "owned").put("authority", authority)
                .put("record", record),
        ) ?: return null
        if (!reply.optBoolean("valid")) return null
        // The authority is internally sound; now it has to still be *this*
        // directory. Device and inode are what the authority was sealed over.
        val directory = File(container, record.optString("owned_directory_name"))
        val identity = identityOf(directory) ?: return null
        if (authority.optString("device_id") != identity.first ||
            authority.optString("inode_id") != identity.second
        ) {
            return null
        }
        return authority
    }

    private fun sealAuthority(record: JSONObject, directory: File, now: String): JSONObject {
        val identity = identityOf(directory) ?: throw Refused("E_WORKSPACE_PERSISTENCE")
        val base = JSONObject()
            .put("schema_version", 1)
            .put("workspace_id", record.getString("workspace_id"))
            .put("binding_revision", record.getInt("binding_revision"))
            .put("device_id", identity.first)
            .put("inode_id", identity.second)
            .put(
                "directory_name_sha256",
                sha256(record.getString("owned_directory_name").toByteArray(Charsets.UTF_8)),
            )
            .put("recorded_at", now)
        val input = RishAgentCoreNative.workspaceFingerprint(
            JSONObject().put("op", "fingerprint_input").put("record", record)
                .put("authority", base),
        )?.optJSONObject("input") ?: throw Refused("E_WORKSPACE_PERSISTENCE")
        val fingerprint = RishAgentCoreNative.workspaceFingerprint(
            JSONObject().put("op", "fingerprint").put("input", input),
        )?.optString("fingerprint").takeUnless { it.isNullOrEmpty() }
            ?: throw Refused("E_WORKSPACE_PERSISTENCE")
        val authority = JSONObject(base.toString())
            .put("root_fingerprint_sha256", fingerprint)
        // A sealed authority that the rule would not accept is a bug here, not
        // a state to write: refuse rather than persist something unreadable.
        val reply = RishAgentCoreNative.workspaceAuthority(
            JSONObject().put("op", "owned").put("authority", authority)
                .put("record", record),
        )
        if (reply?.optBoolean("valid") != true) throw Refused("E_WORKSPACE_PERSISTENCE")
        return authority
    }

    /**
     * The first ordinal whose name nothing has taken. The loop is here because
     * only this host can fold; each name is the core's.
     */
    private fun allocateDirectoryName(displayName: String, registry: JSONObject): String {
        val occupied = HashSet<String>()
        val records = registry.getJSONArray("records")
        for (index in 0 until records.length()) {
            val name = records.optJSONObject(index)?.opt("owned_directory_name")
            if (name is String) occupied.add(folded(name))
        }
        container.list()?.forEach { occupied.add(folded(it)) }
        val clusters = graphemes(displayName)
        var ordinal = 0L
        var candidate = displayName
        while (occupied.contains(folded(candidate))) {
            ordinal += 1
            candidate = RishAgentCoreNative.workspaceDirectoryName(
                JSONObject().put("op", "candidate").put("graphemes", clusters)
                    .put("ordinal", ordinal),
            )?.optString("candidate").takeUnless { it.isNullOrEmpty() }
                ?: throw Refused("E_WORKSPACE_INVALID")
            if (!internalComponent(candidate)) throw Refused("E_WORKSPACE_INVALID")
        }
        return candidate
    }

    private fun internalComponent(value: String): Boolean {
        val reply = RishAgentCoreNative.workspaceDirectoryName(
            JSONObject().put("op", "internal_component").put("value", value),
        ) ?: return false
        return reply.optBoolean("valid")
    }

    // --- host facts -------------------------------------------------------

    /** `st_dev` and `st_ino` as the decimal strings the authority carries. */
    private fun identityOf(directory: File): Pair<String, String>? = try {
        val stat = Os.stat(directory.absolutePath)
        if (stat.st_dev < 0 || stat.st_ino < 0) null
        else Pair(stat.st_dev.toString(), stat.st_ino.toString())
    } catch (_: Exception) {
        null
    }

    private fun authorityFile(workspaceId: String, revision: Int): File =
        File(bindings, "owned-$workspaceId-r$revision.json")

    private fun readJson(file: File): JSONObject? = try {
        if (file.isFile) JSONObject(file.readText()) else null
    } catch (_: Exception) {
        null
    }

    /**
     * Write, flush, rename. The rename is what makes the new bytes visible, so
     * a crash shows either the old object or the new one and never half of
     * either.
     */
    private fun writeJson(file: File, value: JSONObject) {
        val parent = file.parentFile ?: throw Refused("E_WORKSPACE_PERSISTENCE")
        if (!parent.isDirectory && !parent.mkdirs()) throw Refused("E_WORKSPACE_PERSISTENCE")
        val temporary = File(parent, file.name + ".partial")
        try {
            FileOutputStream(temporary).use { stream ->
                stream.write(value.toString().toByteArray(Charsets.UTF_8))
                stream.fd.sync()
            }
            if (!temporary.renameTo(file)) throw Refused("E_WORKSPACE_PERSISTENCE")
        } catch (refused: Refused) {
            temporary.delete()
            throw refused
        } catch (_: Exception) {
            temporary.delete()
            throw Refused("E_WORKSPACE_PERSISTENCE")
        }
    }

    /** The records with [record] in its sorted place. */
    private fun insertedInOrder(records: JSONArray, record: JSONObject): JSONArray {
        val id = record.getString("workspace_id")
        val ordered = JSONArray()
        var inserted = false
        for (index in 0 until records.length()) {
            val existing = records.getJSONObject(index)
            if (!inserted && existing.optString("workspace_id") > id) {
                ordered.put(record)
                inserted = true
            }
            ordered.put(existing)
        }
        if (!inserted) ordered.put(record)
        return ordered
    }

    private fun recordFor(registry: JSONObject, workspaceId: String): JSONObject? {
        val records = registry.getJSONArray("records")
        for (index in 0 until records.length()) {
            val record = records.optJSONObject(index) ?: continue
            if (record.optString("workspace_id") == workspaceId) return record
        }
        return null
    }
}
