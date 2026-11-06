package tech.zseven.rish.runtime

import android.system.Os
import android.system.OsConstants
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.UUID

/**
 * Where a prepared project-context snapshot lives until it is sent or
 * discarded.
 *
 * Mirrors `ProjectContextStore.mm`. Under [root]: `snapshots/<id>.json` (the
 * record: manifest, source descriptor, digests) beside `snapshots/<id>.envelope`
 * (the bytes the model is shown), `consents/<receipt>.json`, `references.json`
 * (which snapshot each key names) and `accesses.json` (when each was last
 * read, for pruning).
 *
 * **A reference is a name pointing at a snapshot**, and the names are the
 * core's rule: `active:<reference>` is what a conversation uses, `retry:<…>`
 * holds one for a retry, and `txn:prepare:<reference>` records, before the
 * active key is swapped, the id to go back to. Preparing is a transaction so
 * a crash between writing the files and swapping the key leaves something
 * the next launch resolves (`recover_references`) rather than two snapshots
 * both claiming to be current. Confirming a snapshot commits its transaction
 * and issues a consent receipt; sending verifies the receipt against the
 * bytes on disk under an authorization lease, so a snapshot swapped out
 * between the two reads is refused rather than sent.
 *
 * Every file is written whole, synced and published by rename. Capacity is
 * enforced by pruning unreferenced snapshots, oldest access first.
 */
internal class AndroidProjectContextStore(
    val root: File,
    private val capacityBytes: Long = DEFAULT_CAPACITY_BYTES,
    private val clock: () -> String = { RuntimeJson.now() },
    private val identifiers: () -> String = { UUID.randomUUID().toString() },
) {
    /** A refusal by iOS's store error number. */
    class Failed(val code: Int, reason: String = "") : Exception(reason)

    /** One loaded snapshot: the bytes and what was recorded about them. */
    class Snapshot(
        val envelope: ByteArray,
        val manifest: JSONObject,
        val sourceDescriptor: JSONObject,
        val createdAt: String,
        val lastAccessedAt: String,
    )

    /** A snapshot read under authorization; what it was when the lease began. */
    class Authorization internal constructor(val snapshotId: String, val snapshot: Snapshot) {
        internal var finished = false
    }

    private val snapshots = File(root, "snapshots")
    private val consents = File(root, "consents")
    private val referencesFile = File(root, "references.json")
    private val accessesFile = File(root, "accesses.json")
    private val lock = Any()
    private var reconciled = false

    // --- the prepare transaction ------------------------------------------

    fun beginPrepareTransaction(
        envelope: ByteArray,
        manifest: JSONObject,
        sourceDescriptor: JSONObject,
        snapshotId: String,
        activeKey: String,
    ): Unit = synchronized(lock) {
        val transactionKey = transactionKeyFor(activeKey)
        if (transactionKey == null || !canonicalId(snapshotId)) throw Failed(INVALID_ARGUMENT)
        ensureStorage()
        var references = references()
        val existingTransaction = references.optString(transactionKey).takeIf { references.has(transactionKey) }
        val existingActive = references.optString(activeKey).takeIf { references.has(activeKey) }
        if (existingTransaction != null) {
            if (existingActive != null) {
                abortPrepareTransactionLocked(existingActive, activeKey)
            } else {
                references.remove(transactionKey)
                writeReferences(references)
            }
        }
        references = references()
        if (references.has(transactionKey)) throw Failed(UNAVAILABLE)
        val previousActive = references.optString(activeKey).takeIf { references.has(activeKey) }
        val transactional = JSONObject(references.toString()).put(transactionKey, previousActive ?: NO_PRIOR_SNAPSHOT_ID)
        writeReferences(transactional)
        try {
            saveEnvelope(envelope, manifest, sourceDescriptor, snapshotId, activeKey)
        } catch (failure: Failed) {
            try {
                writeReferences(references)
            } catch (_: Failed) {
                throw Failed(UNAVAILABLE)
            }
            throw failure
        }
    }

    fun abortPrepareTransaction(snapshotId: String, activeKey: String): Unit = synchronized(lock) {
        abortPrepareTransactionLocked(snapshotId, activeKey)
    }

    private fun abortPrepareTransactionLocked(snapshotId: String, activeKey: String) {
        val transactionKey = transactionKeyFor(activeKey)
        if (transactionKey == null || !canonicalId(snapshotId)) throw Failed(INVALID_ARGUMENT)
        ensureStorage()
        val references = references()
        val rollback = references.optString(transactionKey).takeIf { references.has(transactionKey) }
        if (rollback == null || references.optString(activeKey) != snapshotId) throw Failed(NOT_FOUND)
        references.remove(transactionKey)
        if (rollback == NO_PRIOR_SNAPSHOT_ID) {
            references.remove(activeKey)
        } else if (loadRecordOrNull(rollback) != null) {
            references.put(activeKey, rollback)
        } else {
            references.remove(activeKey)
        }
        writeReferences(references)
        if (!referencesName(references, snapshotId)) {
            try {
                discardSnapshotLocked(snapshotId)
            } catch (_: Failed) {
                reconciled = false
            }
        }
    }

    /** Commits the prepared snapshot and issues its consent receipt. */
    fun commitPrepareTransaction(snapshotId: String, activeKey: String, snapshotDigest: String): JSONObject =
        synchronized(lock) {
            val transactionKey = transactionKeyFor(activeKey)
            if (transactionKey == null || !canonicalId(snapshotId) || !hexDigest(snapshotDigest)) {
                throw Failed(INVALID_ARGUMENT)
            }
            ensureStorage()
            val references = references()
            val snapshot = loadLocked(snapshotId)
            if (!references.has(transactionKey) || references.optString(activeKey) != snapshotId ||
                snapshot.manifest.optString("snapshot_sha256") != snapshotDigest
            ) {
                throw Failed(NOT_FOUND)
            }
            val updated = JSONObject(references.toString()).apply { remove(transactionKey) }
            pruneUnreferencedExcept(snapshotId)
            val (receipt, receiptBytes) = newConsentReceipt(snapshotId, snapshotDigest)
            val referenceBytes = RuntimeJson.receiptJson(updated).toByteArray(Charsets.UTF_8)
            val rollback = references.optString(transactionKey)
            val reclaimRollback = canonicalId(rollback) && !referencesName(updated, rollback)
            val reclaimBytes = if (reclaimRollback) snapshotArtifactBytes(rollback) else 0L
            val currentBytes = storageBytes()
            val currentReferenceBytes = referencesFile.length()
            var projected = if (currentBytes < currentReferenceBytes) Long.MAX_VALUE
            else currentBytes - currentReferenceBytes + referenceBytes.size + receiptBytes.size
            if (reclaimBytes > 0) projected = if (projected < reclaimBytes) Long.MAX_VALUE else projected - reclaimBytes
            if (referenceBytes.size > MAX_REFERENCE_BYTES || projected > capacityBytes) throw Failed(CAPACITY)
            val consentFile = File(consents, receipt.getString("consent_receipt_id") + ".json")
            publishImmutable(receiptBytes, consentFile)
            try {
                writeReferences(updated)
            } catch (failure: Failed) {
                consentFile.delete()
                fsyncDirectoryQuietly(consents)
                throw failure
            }
            if (reclaimRollback) {
                try {
                    discardSnapshotLocked(rollback)
                } catch (_: Failed) {
                    reconciled = false
                }
            }
            receipt
        }

    // --- reading ----------------------------------------------------------

    fun load(snapshotId: String): Snapshot = synchronized(lock) { loadLocked(snapshotId) }

    private fun loadLocked(snapshotId: String): Snapshot {
        if (!canonicalId(snapshotId)) throw Failed(INVALID_ARGUMENT)
        ensureStorage()
        val record = loadRecord(snapshotId)
        val length = record.getLong("envelope_bytes")
        val envelope = readProtected(envelopeFile(snapshotId), length)
        if (envelope.size.toLong() != length || sha256(envelope) != record.getString("snapshot_sha256") ||
            record.getJSONObject("manifest").optString("snapshot_sha256") != record.getString("snapshot_sha256")
        ) {
            throw Failed(INTEGRITY)
        }
        val accesses = accesses()
        val lastAccessed = clock()
        accesses.put(snapshotId, lastAccessed)
        writeAccesses(accesses)
        return Snapshot(
            envelope, record.getJSONObject("manifest"), record.getJSONObject("source_descriptor"),
            record.getString("created_at"), lastAccessed,
        )
    }

    fun loadConsent(receiptId: String): JSONObject = synchronized(lock) {
        if (!canonicalId(receiptId)) throw Failed(INVALID_ARGUMENT)
        ensureStorage()
        val bytes = readProtected(File(consents, "$receiptId.json"), MAX_RECORD_BYTES)
        val receipt = try {
            JSONObject(String(bytes, Charsets.UTF_8))
        } catch (_: Exception) {
            throw Failed(INTEGRITY)
        }
        val core = JSONObject(receipt.toString())
        val digest = core.opt("receipt_sha256") as? String
        core.remove("receipt_sha256")
        if (receipt.keys().asSequence().toSet() != CONSENT_KEYS || receipt.opt("schema_version") != 1 ||
            receipt.opt("consent_receipt_id") != receiptId || !canonicalId(receipt.optString("snapshot_id")) ||
            !hexDigest(receipt.optString("snapshot_sha256")) || digest == null || !hexDigest(digest) ||
            digest != sha256(RuntimeJson.receiptJson(core).toByteArray(Charsets.UTF_8)) ||
            receipt.opt("confirmed_at") !is String
        ) {
            throw Failed(INTEGRITY)
        }
        core
    }

    /** The consent receipts that name a snapshot. */
    fun consentsFor(snapshotId: String): List<JSONObject> = synchronized(lock) {
        ensureStorage()
        (consents.listFiles() ?: emptyArray()).mapNotNull { file ->
            val receiptId = file.name.removeSuffix(".json")
            if (!file.name.endsWith(".json") || !canonicalId(receiptId)) return@mapNotNull null
            val receipt = try { loadConsent(receiptId) } catch (_: Failed) { return@mapNotNull null }
            receipt.takeIf { it.optString("snapshot_id") == snapshotId }
        }
    }

    fun snapshotIdForReferenceKey(key: String): String? = synchronized(lock) {
        if (!safeReferenceKey(key)) throw Failed(INVALID_ARGUMENT)
        ensureStorage()
        references().optString(key).takeIf { references().has(key) }
    }

    fun clearReferenceKey(key: String): Unit = synchronized(lock) {
        if (key.startsWith(TRANSACTION_PREFIX) || !safeReferenceKey(key)) throw Failed(INVALID_ARGUMENT)
        ensureStorage()
        val references = references()
        val transactionKey = transactionKeyFor(key)
        if (transactionKey != null && references.has(transactionKey)) throw Failed(INVALID_ARGUMENT)
        val removed = references.optString(key).takeIf { references.has(key) }
        references.remove(key)
        if (removed != null && !referencesName(references, removed)) {
            discardSnapshotLocked(removed)
        } else {
            writeReferences(references)
        }
    }

    // --- authorization ------------------------------------------------------

    fun isSnapshotAuthorized(snapshotId: String, activeKey: String?): Boolean = synchronized(lock) {
        if (!canonicalId(snapshotId) || (activeKey != null && !safeReferenceKey(activeKey))) throw Failed(INVALID_ARGUMENT)
        ensureStorage()
        val references = references()
        if (activeKey != null && references.optString(activeKey) == snapshotId) return true
        for (key in references.keys()) {
            val permitted = key.startsWith(RETRY_PREFIX) || (activeKey == null && key.startsWith(ACTIVE_PREFIX))
            if (permitted && references.optString(key) == snapshotId) return true
        }
        false
    }

    fun beginAuthorization(snapshotId: String, activeKey: String?): Authorization = synchronized(lock) {
        if (!isSnapshotAuthorized(snapshotId, activeKey)) throw Failed(NOT_FOUND)
        Authorization(snapshotId, loadLocked(snapshotId))
    }

    /**
     * Runs [operation] over the snapshot as it is now, provided it is still
     * authorized and still the bytes the lease began with.
     */
    fun <T> completeAuthorization(authorization: Authorization, activeKey: String?, operation: (Snapshot) -> T): T =
        synchronized(lock) {
            if (authorization.finished || !isSnapshotAuthorized(authorization.snapshotId, activeKey)) {
                authorization.finished = true
                throw Failed(NOT_FOUND)
            }
            val current = try {
                loadLocked(authorization.snapshotId)
            } catch (failure: Failed) {
                authorization.finished = true
                throw failure
            }
            val original = authorization.snapshot
            if (current.manifest.optString("snapshot_sha256") != original.manifest.optString("snapshot_sha256") ||
                current.manifest.optString("source_fingerprint") != original.manifest.optString("source_fingerprint")
            ) {
                authorization.finished = true
                throw Failed(INTEGRITY)
            }
            authorization.finished = true
            operation(current)
        }

    fun cancelAuthorization(authorization: Authorization) {
        authorization.finished = true
    }

    // --- discarding and pruning ---------------------------------------------

    fun discardSnapshot(snapshotId: String): Unit = synchronized(lock) { discardSnapshotLocked(snapshotId) }

    private fun discardSnapshotLocked(snapshotId: String) {
        if (!canonicalId(snapshotId)) throw Failed(INVALID_ARGUMENT)
        ensureStorage()
        var references = references()
        for (key in references.keys().asSequence().toList()) {
            if (!key.startsWith(TRANSACTION_PREFIX)) continue
            val activeKey = ACTIVE_PREFIX + key.removePrefix(TRANSACTION_PREFIX)
            if (references.optString(key) == snapshotId) throw Failed(INVALID_ARGUMENT)
            if (references.optString(activeKey) == snapshotId) {
                abortPrepareTransactionLocked(snapshotId, activeKey)
                references = references()
                break
            }
        }
        val accesses = accesses()
        val matching = (consents.listFiles() ?: emptyArray()).filter { file ->
            val bytes = try { readProtected(file, MAX_RECORD_BYTES) } catch (_: Failed) { null }
            bytes != null && try {
                JSONObject(String(bytes, Charsets.UTF_8)).optString("snapshot_id") == snapshotId
            } catch (_: Exception) {
                false
            }
        }
        for (key in references.keys().asSequence().toList()) {
            if (references.optString(key) == snapshotId) references.remove(key)
        }
        accesses.remove(snapshotId)
        writeReferences(references)
        writeAccesses(accesses)
        var success = deleteIfPresent(envelopeFile(snapshotId))
        success = deleteIfPresent(recordFile(snapshotId)) && success
        for (file in matching) success = deleteIfPresent(file) && success
        for (directory in listOf(snapshots, consents, root)) {
            if (!fsyncDirectoryQuietly(directory)) success = false
        }
        if (!success) throw Failed(UNAVAILABLE)
    }

    private fun pruneUnreferencedExcept(protectedId: String?) {
        val referenced = referencedIds(references())
        for (snapshotId in snapshotIdsOnDisk()) {
            if (snapshotId == protectedId || snapshotId in referenced) continue
            discardSnapshotLocked(snapshotId)
        }
    }

    private fun pruneWithProtected(protectedId: String?) {
        val referenced = referencedIds(references())
        val accesses = accesses()
        while (storageBytes() > capacityBytes) {
            val victim = snapshotIdsOnDisk()
                .filter { it != protectedId && it !in referenced }
                .mapNotNull { id -> loadRecordOrNull(id)?.let { id to (accesses.optString(id).ifEmpty { it.getString("last_accessed_at") }) } }
                .sortedWith(compareBy({ it.second }, { it.first }))
                .firstOrNull() ?: throw Failed(CAPACITY)
            discardSnapshotLocked(victim.first)
        }
    }

    // --- the files ----------------------------------------------------------

    private fun saveEnvelope(
        envelope: ByteArray, manifest: JSONObject, source: JSONObject, snapshotId: String, activeKey: String,
    ) {
        val digest = manifest.opt("snapshot_sha256") as? String
        val fingerprint = manifest.opt("source_fingerprint") as? String
        if (envelope.isEmpty() || !canonicalId(snapshotId) || digest == null || !hexDigest(digest) ||
            digest != sha256(envelope) || fingerprint.isNullOrEmpty() || fingerprint.length > 512 ||
            !safeReferenceKey(activeKey) || (manifest.has("snapshot_id") && manifest.opt("snapshot_id") != snapshotId)
        ) {
            throw Failed(INVALID_ARGUMENT)
        }
        ensureStorage()
        val previousReferences = references()
        val timestamp = clock()
        val previousAccesses = accesses()
        val recordCore = JSONObject().put("schema_version", 1).put("snapshot_id", snapshotId)
            .put("snapshot_sha256", digest).put("envelope_bytes", envelope.size)
            .put("created_at", timestamp).put("last_accessed_at", timestamp)
            .put("manifest", manifest).put("source_descriptor", source)
        val record = JSONObject(recordCore.toString())
            .put("record_sha256", sha256(RuntimeJson.receiptJson(recordCore).toByteArray(Charsets.UTF_8)))
        val recordBytes = RuntimeJson.receiptJson(record).toByteArray(Charsets.UTF_8)
        if (recordBytes.size > MAX_RECORD_BYTES) throw Failed(INVALID_ARGUMENT)
        publishImmutable(envelope, envelopeFile(snapshotId))
        try {
            publishImmutable(recordBytes, recordFile(snapshotId))
        } catch (failure: Failed) {
            envelopeFile(snapshotId).delete()
            throw failure
        }
        val rollbackNew = {
            val rollback = try { accesses() } catch (_: Failed) { JSONObject(previousAccesses.toString()) }
            rollback.remove(snapshotId)
            try { writeAccesses(rollback) } catch (_: Failed) {}
            recordFile(snapshotId).delete()
            envelopeFile(snapshotId).delete()
            fsyncDirectoryQuietly(snapshots)
        }
        val accesses = JSONObject(previousAccesses.toString()).put(snapshotId, timestamp)
        try {
            writeAccesses(accesses)
        } catch (failure: Failed) {
            recordFile(snapshotId).delete()
            envelopeFile(snapshotId).delete()
            throw failure
        }
        val oldActive = previousReferences.optString(activeKey).takeIf { previousReferences.has(activeKey) }
        val updated = JSONObject(previousReferences.toString()).put(activeKey, snapshotId)
        try {
            pruneUnreferencedExcept(snapshotId)
        } catch (failure: Failed) {
            rollbackNew(); throw failure
        }
        val referenceBytes = RuntimeJson.receiptJson(updated).toByteArray(Charsets.UTF_8)
        val currentReferenceBytes = referencesFile.length()
        val total = storageBytes()
        val oldCanPrune = oldActive != null && oldActive != snapshotId && !referencesName(updated, oldActive)
        val oldBytes = if (oldCanPrune) snapshotArtifactBytes(oldActive!!) else 0L
        var projected = if (total < currentReferenceBytes) Long.MAX_VALUE else total - currentReferenceBytes + referenceBytes.size
        if (oldCanPrune) projected = if (oldBytes == 0L || projected < oldBytes) Long.MAX_VALUE else projected - oldBytes
        if (referenceBytes.size > MAX_REFERENCE_BYTES || projected > capacityBytes) {
            rollbackNew(); throw Failed(CAPACITY)
        }
        try {
            writeReferences(updated)
        } catch (failure: Failed) {
            rollbackNew(); throw failure
        }
        if (oldCanPrune) {
            try {
                discardSnapshotLocked(oldActive!!)
            } catch (failure: Failed) {
                if (recordFile(oldActive!!).exists() && envelopeFile(oldActive).exists()) {
                    try { writeReferences(previousReferences) } catch (_: Failed) {}
                    rollbackNew()
                }
                throw failure
            }
        }
        if (!recordFile(snapshotId).exists()) throw Failed(CAPACITY)
    }

    private fun loadRecordOrNull(snapshotId: String): JSONObject? = try { loadRecord(snapshotId) } catch (_: Failed) { null }

    private fun loadRecord(snapshotId: String): JSONObject {
        val bytes = readProtected(recordFile(snapshotId), MAX_RECORD_BYTES)
        val record = try {
            JSONObject(String(bytes, Charsets.UTF_8))
        } catch (_: Exception) {
            throw Failed(INTEGRITY)
        }
        val core = JSONObject(record.toString())
        val digest = core.opt("record_sha256") as? String
        core.remove("record_sha256")
        val manifest = record.optJSONObject("manifest")
        val source = record.optJSONObject("source_descriptor")
        val length = record.opt("envelope_bytes")
        val exactLength = (length as? Number)?.toLong()?.takeIf { it > 0 && it <= DEFAULT_CAPACITY_BYTES }
        if (record.keys().asSequence().toSet() != RECORD_KEYS || record.opt("schema_version") != 1 ||
            record.opt("snapshot_id") != snapshotId || !hexDigest(record.optString("snapshot_sha256")) ||
            digest == null || !hexDigest(digest) ||
            digest != sha256(RuntimeJson.receiptJson(core).toByteArray(Charsets.UTF_8)) ||
            manifest == null || source == null ||
            (manifest.has("snapshot_id") && manifest.opt("snapshot_id") != snapshotId) ||
            manifest.opt("snapshot_sha256") != record.opt("snapshot_sha256") ||
            (manifest.has("project_id") && source.has("project_id") && manifest.opt("project_id") != source.opt("project_id")) ||
            (manifest.has("source_fingerprint") && source.has("source_fingerprint") &&
                manifest.opt("source_fingerprint") != source.opt("source_fingerprint")) ||
            exactLength == null || record.opt("created_at") !is String || record.opt("last_accessed_at") !is String
        ) {
            throw Failed(INTEGRITY)
        }
        return record
    }

    private fun newConsentReceipt(snapshotId: String, digest: String): Pair<JSONObject, ByteArray> {
        val receiptId = identifiers()
        if (!canonicalId(receiptId)) throw Failed(INVALID_ARGUMENT)
        val receipt = JSONObject().put("schema_version", 1).put("consent_receipt_id", receiptId)
            .put("snapshot_id", snapshotId).put("snapshot_sha256", digest).put("confirmed_at", clock())
        val stored = JSONObject(receipt.toString())
            .put("receipt_sha256", sha256(RuntimeJson.receiptJson(receipt).toByteArray(Charsets.UTF_8)))
        val bytes = RuntimeJson.receiptJson(stored).toByteArray(Charsets.UTF_8)
        if (bytes.size > MAX_RECORD_BYTES) throw Failed(INVALID_ARGUMENT)
        return Pair(receipt, bytes)
    }

    /**
     * Startup reconciliation: every snapshot on disk is checked against its
     * record, the references are recovered by the core's rule, and whatever
     * nothing names any more is removed. Runs once per process.
     */
    private fun ensureStorage() {
        if (!snapshots.isDirectory && !snapshots.mkdirs()) throw Failed(UNAVAILABLE)
        if (!consents.isDirectory && !consents.mkdirs()) throw Failed(UNAVAILABLE)
        if (reconciled) return
        val cleanupSnapshotFiles = ArrayList<File>()
        val snapshotIds = HashSet<String>()
        for (file in snapshots.listFiles() ?: throw Failed(UNAVAILABLE)) {
            val name = file.name
            if (name.startsWith(".")) { cleanupSnapshotFiles.add(file); continue }
            val id = name.substringBeforeLast('.')
            val extension = name.substringAfterLast('.', "")
            if (canonicalId(id) && (extension == "json" || extension == "envelope")) snapshotIds.add(id)
            else cleanupSnapshotFiles.add(file)
        }
        val validIds = HashSet<String>()
        val corruptIds = HashSet<String>()
        for (id in snapshotIds) {
            val record = loadRecordOrNull(id)
            val envelope = record?.let { r ->
                try { readProtected(envelopeFile(id), r.getLong("envelope_bytes")) } catch (_: Failed) { null }
            }
            val valid = record != null && envelope != null && envelope.size.toLong() == record.getLong("envelope_bytes") &&
                sha256(envelope) == record.getString("snapshot_sha256")
            if (valid) validIds.add(id) else corruptIds.add(id)
        }
        val cleanupConsentFiles = ArrayList<File>()
        val consentFiles = consents.listFiles() ?: throw Failed(UNAVAILABLE)
        val receiptsByFile = HashMap<File, JSONObject>()
        for (file in consentFiles) {
            val receiptId = file.name.substringBeforeLast('.')
            val receipt = if (canonicalId(receiptId) && file.name.endsWith(".json")) {
                try { loadConsentUnlocked(receiptId) } catch (_: Failed) { null }
            } else null
            if (receipt == null || receipt.optString("snapshot_id") !in validIds) cleanupConsentFiles.add(file)
            else receiptsByFile[file] = receipt
        }
        val stored = references()
        val recovery = RishAgentCoreNative.projectContextStoreReduce(
            JSONObject().put("op", "recover_references").put("references", stored)
                .put("valid_ids", org.json.JSONArray(validIds.sorted())).toString(),
        )?.let { JSONObject(it) }?.takeIf { it.optBoolean("ok") } ?: throw Failed(UNAVAILABLE)
        val references = recovery.getJSONObject("references")
        val orphanIds = HashSet(validIds)
        orphanIds.removeAll(referencedIds(references))
        val newIds = recovery.optJSONArray("transaction_new_ids") ?: org.json.JSONArray()
        for (index in 0 until newIds.length()) orphanIds.add(newIds.getString(index))
        validIds.removeAll(orphanIds)
        val accesses = accesses()
        for (key in accesses.keys().asSequence().toList()) if (key !in validIds) accesses.remove(key)
        for ((file, receipt) in receiptsByFile) {
            if (receipt.optString("snapshot_id") in orphanIds && file !in cleanupConsentFiles) cleanupConsentFiles.add(file)
        }
        writeReferences(references)
        writeAccesses(accesses)
        var success = true
        for (file in cleanupSnapshotFiles) success = deleteIfPresent(file) && success
        for (id in corruptIds + orphanIds) {
            success = deleteIfPresent(recordFile(id)) && success
            success = deleteIfPresent(envelopeFile(id)) && success
        }
        for (file in cleanupConsentFiles) success = deleteIfPresent(file) && success
        reconciled = true
        if (success && storageBytes() > capacityBytes) {
            try { pruneWithProtected(null) } catch (failure: Failed) { if (failure.code != CAPACITY) { reconciled = false; throw failure } }
        }
        for (directory in listOf(snapshots, consents, root)) if (!fsyncDirectoryQuietly(directory)) success = false
        if (!success) { reconciled = false; throw Failed(UNAVAILABLE) }
    }

    private fun loadConsentUnlocked(receiptId: String): JSONObject {
        // The same rule as loadConsent, without re-entering the lock or
        // reconciliation, for use during reconciliation itself.
        val bytes = readProtected(File(consents, "$receiptId.json"), MAX_RECORD_BYTES)
        val receipt = try { JSONObject(String(bytes, Charsets.UTF_8)) } catch (_: Exception) { throw Failed(INTEGRITY) }
        val core = JSONObject(receipt.toString())
        val digest = core.opt("receipt_sha256") as? String
        core.remove("receipt_sha256")
        if (receipt.keys().asSequence().toSet() != CONSENT_KEYS || receipt.opt("schema_version") != 1 ||
            receipt.opt("consent_receipt_id") != receiptId || !canonicalId(receipt.optString("snapshot_id")) ||
            !hexDigest(receipt.optString("snapshot_sha256")) || digest == null || !hexDigest(digest) ||
            digest != sha256(RuntimeJson.receiptJson(core).toByteArray(Charsets.UTF_8)) ||
            receipt.opt("confirmed_at") !is String
        ) {
            throw Failed(INTEGRITY)
        }
        return core
    }

    // A transaction key may hold the sentinel that says "no prior snapshot",
    // which is not a snapshot id and must not be read as one anywhere else.
    private fun references(): JSONObject = readMap(referencesFile, MAX_REFERENCE_BYTES) { key, value ->
        safeReferenceKey(key) && value is String &&
            (canonicalId(value) || (key.startsWith(TRANSACTION_PREFIX) && value == NO_PRIOR_SNAPSHOT_ID))
    }

    private fun accesses(): JSONObject = readMap(accessesFile, MAX_REFERENCE_BYTES) { key, value ->
        canonicalId(key) && value is String
    }

    private fun readMap(file: File, maximum: Long, entryValid: (String, Any?) -> Boolean): JSONObject {
        if (!file.exists()) return JSONObject()
        val bytes = readProtected(file, maximum)
        val map = try { JSONObject(String(bytes, Charsets.UTF_8)) } catch (_: Exception) { throw Failed(INTEGRITY) }
        for (key in map.keys()) if (!entryValid(key, map.opt(key))) throw Failed(INTEGRITY)
        return map
    }

    private fun writeReferences(references: JSONObject) = replace(referencesFile, RuntimeJson.receiptJson(references))
    private fun writeAccesses(accesses: JSONObject) = replace(accessesFile, RuntimeJson.receiptJson(accesses))

    /** Written to a sibling, synced, then renamed over the old file. */
    private fun replace(file: File, text: String) {
        val temporary = File(file.parentFile, ".${file.name}.${identifiers()}")
        try {
            FileOutputStream(temporary).use { stream ->
                stream.write(text.toByteArray(Charsets.UTF_8)); stream.fd.sync()
            }
            Files.move(temporary.toPath(), file.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        } catch (_: Exception) {
            temporary.delete()
            throw Failed(UNAVAILABLE)
        }
        if (!fsyncDirectoryQuietly(file.parentFile ?: root)) throw Failed(UNAVAILABLE)
    }

    /** Written once: a file already there is not overwritten. */
    private fun publishImmutable(bytes: ByteArray, file: File) {
        if (file.exists()) throw Failed(UNAVAILABLE)
        val temporary = File(file.parentFile, ".${file.name}.${identifiers()}")
        try {
            FileOutputStream(temporary).use { stream -> stream.write(bytes); stream.fd.sync() }
            Files.move(temporary.toPath(), file.toPath(), StandardCopyOption.ATOMIC_MOVE)
        } catch (_: Exception) {
            temporary.delete()
            throw Failed(UNAVAILABLE)
        }
        if (!fsyncDirectoryQuietly(file.parentFile ?: root)) throw Failed(UNAVAILABLE)
    }

    /** A regular file of at most [maximum] bytes, whole. Missing is NOT_FOUND. */
    private fun readProtected(file: File, maximum: Long): ByteArray {
        if (!file.exists()) throw Failed(NOT_FOUND)
        if (!file.isFile || Files.isSymbolicLink(file.toPath())) throw Failed(INTEGRITY)
        if (file.length() > maximum) throw Failed(INTEGRITY)
        return try { file.readBytes() } catch (_: Exception) { throw Failed(UNAVAILABLE) }
    }

    private fun storageBytes(): Long {
        var total = 0L
        for (directory in listOf(snapshots, consents)) {
            for (file in directory.listFiles() ?: emptyArray()) if (file.isFile) total += file.length()
        }
        for (file in listOf(referencesFile, accessesFile)) if (file.isFile) total += file.length()
        return total
    }

    private fun snapshotArtifactBytes(snapshotId: String): Long =
        listOf(recordFile(snapshotId), envelopeFile(snapshotId)).sumOf { if (it.isFile) it.length() else 0L }

    private fun snapshotIdsOnDisk(): List<String> = (snapshots.listFiles() ?: emptyArray())
        .filter { it.name.endsWith(".json") }
        .map { it.name.removeSuffix(".json") }
        .filter { canonicalId(it) }
        .sorted()

    private fun referencedIds(references: JSONObject): Set<String> =
        references.keys().asSequence().map { references.optString(it) }.toSet()

    private fun referencesName(references: JSONObject, snapshotId: String): Boolean =
        references.keys().asSequence().any { references.optString(it) == snapshotId }

    private fun recordFile(snapshotId: String) = File(snapshots, "$snapshotId.json")
    private fun envelopeFile(snapshotId: String) = File(snapshots, "$snapshotId.envelope")

    private fun deleteIfPresent(file: File): Boolean = !file.exists() || file.delete()

    private fun fsyncDirectoryQuietly(directory: File): Boolean = try {
        val descriptor = Os.open(directory.absolutePath, OsConstants.O_RDONLY, 0)
        try { Os.fsync(descriptor); true } finally { Os.close(descriptor) }
    } catch (_: Exception) {
        false
    }

    private fun sha256(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    // --- the core's rules ---------------------------------------------------

    private fun storeRule(op: String, key: String, value: String): JSONObject? =
        RishAgentCoreNative.projectContextStoreReduce(JSONObject().put("op", op).put(key, value).toString())
            ?.let { JSONObject(it) }?.takeIf { it.optBoolean("ok") }

    private fun canonicalId(value: String): Boolean = storeRule("canonical_snapshot_id", "value", value)?.optBoolean("valid") == true
    private fun safeReferenceKey(value: String): Boolean = storeRule("safe_reference_key", "value", value)?.optBoolean("valid") == true
    private fun hexDigest(value: String): Boolean = storeRule("hex_digest", "value", value)?.optBoolean("valid") == true
    private fun transactionKeyFor(activeKey: String): String? =
        storeRule("prepare_transaction_key", "active_key", activeKey)?.opt("key") as? String

    companion object {
        const val INVALID_ARGUMENT = 1
        const val UNAVAILABLE = 2
        const val INTEGRITY = 3
        const val NOT_FOUND = 4
        const val CAPACITY = 5
        const val DEFAULT_CAPACITY_BYTES = 64L * 1024 * 1024
        const val NO_PRIOR_SNAPSHOT_ID = "00000000-0000-0000-0000-000000000000"
        private const val MAX_RECORD_BYTES = 1024L * 1024
        private const val MAX_REFERENCE_BYTES = 1024L * 1024
        private const val ACTIVE_PREFIX = "active:"
        private const val RETRY_PREFIX = "retry:"
        private const val TRANSACTION_PREFIX = "txn:prepare:"
        private val RECORD_KEYS = setOf(
            "schema_version", "snapshot_id", "snapshot_sha256", "envelope_bytes", "created_at",
            "last_accessed_at", "manifest", "source_descriptor", "record_sha256",
        )
        private val CONSENT_KEYS = setOf(
            "schema_version", "consent_receipt_id", "snapshot_id", "snapshot_sha256", "confirmed_at", "receipt_sha256",
        )
    }
}
