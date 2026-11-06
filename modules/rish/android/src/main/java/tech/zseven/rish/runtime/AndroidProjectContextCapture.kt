package tech.zseven.rish.runtime

import android.system.Os
import android.system.OsConstants
import android.system.StructStat
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest

/**
 * What a selection of a project's files becomes before it is framed: the
 * candidates, the files read, the diffs cut, the omissions, and a fingerprint
 * of everything that was looked at.
 *
 * Mirrors `captureLease` in `ProjectContextService.mm`, decision for decision.
 * Git is asked through [RishLibgit2Native] with nothing decided there; every
 * rule about what is eligible, what a directory selection expands to, what a
 * file's bytes may be and what a patch may show is applied here -- most of
 * them by asking the shared core, which owns the path policy, the content
 * policy and the credential scanner.
 *
 * **The fingerprint is not iOS's bytes.** It hashes the same kinds of facts
 * -- the index, the two diffs, the selection and what was observed about
 * each selected file -- but the device and inode numbers in it are this
 * device's. It only ever answers "has anything changed since this was read",
 * on this device, and it is never compared across hosts.
 */
internal class AndroidProjectContextCapture {
    class Refused(val code: String, reason: String) : Exception(reason)

    class Block(val path: String, val source: String, val data: ByteArray)

    class Capture(
        val branch: String?,
        val headOid: String?,
        val clean: Boolean,
        val conflicted: Boolean,
        val sourceFingerprint: String,
        val candidates: List<JSONObject>,
        val blocks: List<Block>,
        val omitted: JSONArray,
        val trackedStatus: JSONArray,
        val expandedPaths: List<String>,
    )

    /** One file read from the working tree, or why it was not. */
    private class SafeFile(
        val data: ByteArray?,
        val sha256: String?,
        val reason: String?,
        val metadata: JSONObject?,
        val observationSha256: String?,
    )

    /**
     * Captures, then captures again without blocks and requires the two
     * fingerprints to agree: a project that moved between the two reads is
     * not one to snapshot. `captureAndVerifyLease` on iOS.
     */
    fun captureAndVerify(
        gitDir: File, workDir: File, projectMetadataSha256: String, selectedPaths: List<String>,
        includeBlocks: Boolean, deadline: Deadline,
    ): Capture {
        val first = capture(gitDir, workDir, projectMetadataSha256, selectedPaths, includeBlocks, deadline)
        val second = capture(gitDir, workDir, projectMetadataSha256, selectedPaths, false, deadline)
        if (first.sourceFingerprint != second.sourceFingerprint) throw Refused(CHANGED, "the project changed while it was read")
        return first
    }

    /** `DSHProjectContextDeadlineSeconds`: two seconds from the request. */
    class Deadline(private val startedAt: Long = System.nanoTime()) {
        fun check() {
            if (System.nanoTime() - startedAt > 2_000_000_000L) throw Refused(TIMEOUT, "the capture took too long")
        }
    }

    fun capture(
        gitDir: File, workDir: File, projectMetadataSha256: String, selectedPaths: List<String>,
        includeBlocks: Boolean, deadline: Deadline,
    ): Capture {
        if (!RishLibgit2Native.require()) throw Refused(NOT_FOUND, "libgit2 is not available")
        val gitPath = gitDir.absolutePath
        val workPath = workDir.absolutePath
        val state = JSONObject(String(RishLibgit2Native.captureRepository(gitPath, workPath), Charsets.UTF_8))
        if (!state.optBoolean("ok")) {
            throw Refused(
                when (state.optString("code")) {
                    "integrity" -> INTEGRITY
                    "budget_exceeded" -> BUDGET
                    else -> NOT_FOUND
                },
                "repository could not be read at ${state.optString("stage")}",
            )
        }
        val branch = state.opt("branch") as? String
        val headOid = state.opt("head_oid") as? String
        val headTarget = state.opt("head_target") as? String

        // The index: every entry decided once, spelled the way the policy
        // spells it, or the whole capture refused.
        val candidateByPath = HashMap<String, JSONObject>()
        val rawByNormalized = HashMap<String, String>()
        val indexRows = ArrayList<JSONObject>()
        val conflictPaths = HashSet<String>()
        val entries = state.getJSONArray("entries")
        for (index in 0 until entries.length()) {
            val entry = entries.getJSONObject(index)
            val rawPath = entry.getString("path")
            val decision = AndroidProjectContextPolicy.decisionFor(rawPath)
            val path = decision.normalizedPath
            val existingRaw = rawByNormalized[path]
            if (path.isEmpty() || path != rawPath || (existingRaw != null && existingRaw != rawPath)) {
                throw Refused(INTEGRITY, "index path is not in normal form")
            }
            rawByNormalized[path] = rawPath
            val stage = entry.getInt("stage")
            indexRows.add(
                JSONObject().put("path", path).put("stage", stage).put("mode", entry.getInt("mode"))
                    .put("size", entry.getLong("size")).put("oid", entry.getString("oid")),
            )
            if (stage != 0) { conflictPaths.add(path); continue }
            val mode = entry.getInt("mode")
            val regular = mode == MODE_BLOB || mode == MODE_BLOB_EXECUTABLE
            val size = entry.getLong("size")
            val eligible = decision.eligible && regular && size <= MAX_FILE_BYTES
            val reason = when {
                decision.eligible && !regular -> POLICY
                decision.eligible && size > MAX_FILE_BYTES -> BUDGET_EXCEEDED
                else -> decision.omissionReason
            }
            candidateByPath[path] = JSONObject().put("path", path).put("size", size).put("revision", entry.getString("oid"))
                .put("git_state", "unchanged").put("eligible", eligible)
                .put("omission_reason", if (eligible) JSONObject.NULL else (reason ?: POLICY))
                .put("staged", false).put("unstaged", false).put("conflicted", false)
        }
        indexRows.sortWith(compareBy({ it.getString("path") }, { it.getInt("stage") }))

        // The two diffs: which paths moved, and the rows a fingerprint and a
        // manifest each see -- the manifest only the paths it may name.
        val statusRows = ArrayList<JSONObject>()
        val disclosedRows = ArrayList<JSONObject>()
        val changedPaths = HashSet<String>()
        val rows = state.getJSONArray("status_rows")
        for (index in 0 until rows.length()) {
            val row = rows.getJSONObject(index)
            val kind = row.getString("kind")
            val oldPath = row.getString("old_path")
            val newPath = row.getString("new_path")
            for (raw in listOf(oldPath, newPath)) {
                if (raw.isEmpty()) continue
                val decision = AndroidProjectContextPolicy.decisionFor(raw)
                if (decision.normalizedPath.isEmpty() || decision.normalizedPath != raw) {
                    throw Refused(INTEGRITY, "changed path is not in normal form")
                }
                changedPaths.add(raw)
                candidateByPath[raw]?.put(if (kind == "staged") "staged" else "unstaged", true)
            }
            statusRows.add(
                JSONObject().put("kind", kind).put("status", row.getInt("status"))
                    .put("old_path", oldPath).put("new_path", newPath)
                    .put("old_mode", row.getInt("old_mode")).put("new_mode", row.getInt("new_mode"))
                    .put("old_oid", row.getString("old_oid")).put("new_oid", row.getString("new_oid")),
            )
            val oldDecision = oldPath.takeIf { it.isNotEmpty() }?.let { AndroidProjectContextPolicy.decisionFor(it) }
            val newDecision = newPath.takeIf { it.isNotEmpty() }?.let { AndroidProjectContextPolicy.decisionFor(it) }
            disclosedRows.add(
                JSONObject().put("kind", kind).put("status", row.getInt("status"))
                    .put("old_path", if (oldDecision?.eligible == true) oldDecision.normalizedPath else JSONObject.NULL)
                    .put("new_path", if (newDecision?.eligible == true) newDecision.normalizedPath else JSONObject.NULL)
                    .put("old_restricted", oldDecision != null && !oldDecision.eligible)
                    .put("new_restricted", newDecision != null && !newDecision.eligible),
            )
        }
        for (path in conflictPaths) {
            changedPaths.add(path)
            val candidate = candidateByPath[path]
            if (candidate == null) {
                val conflictRows = JSONArray()
                for (row in indexRows) if (row.getString("path") == path) conflictRows.put(row)
                candidateByPath[path] = JSONObject().put("path", path).put("size", 0)
                    .put("revision", sha256(RuntimeJson.canonical(conflictRows).toByteArray(Charsets.UTF_8)))
                    .put("git_state", "conflicted").put("eligible", false).put("omission_reason", POLICY)
                    .put("staged", false).put("unstaged", false).put("conflicted", true)
            } else {
                candidate.put("conflicted", true).put("eligible", false).put("omission_reason", POLICY)
            }
        }
        if (changedPaths.size > MAX_CHANGED_PATHS) throw Refused(BUDGET, "too many changed paths")
        statusRows.sortBy { RuntimeJson.canonical(it) }
        disclosedRows.sortBy { RuntimeJson.canonical(it) }

        val candidatePaths = candidateByPath.keys.sorted()
        val candidates = candidatePaths.map { path ->
            val candidate = candidateByPath.getValue(path)
            candidate.put(
                "git_state",
                when {
                    candidate.getBoolean("conflicted") -> "conflicted"
                    candidate.getBoolean("unstaged") -> "unstaged"
                    candidate.getBoolean("staged") -> "staged"
                    else -> "unchanged"
                },
            )
            JSONObject().put("path", candidate.getString("path")).put("size", candidate.getLong("size"))
                .put("revision", candidate.getString("revision")).put("git_state", candidate.getString("git_state"))
                .put("eligible", candidate.getBoolean("eligible")).put("omission_reason", candidate.opt("omission_reason"))
        }

        // A selected directory means everything under it; a selected path
        // that is neither a candidate nor a directory stays, to be reported
        // as not tracked.
        val effective = LinkedHashSet<String>()
        for (selection in selectedPaths) {
            if (candidateByPath.containsKey(selection)) { effective.add(selection); continue }
            val prefix = "$selection/"
            var expanded = false
            for (candidatePath in candidatePaths) {
                if (candidatePath.startsWith(prefix)) { effective.add(candidatePath); expanded = true }
            }
            if (!expanded) effective.add(selection)
        }
        val effectivePaths = effective.sorted()

        val blocks = ArrayList<Block>()
        val omitted = JSONArray()
        val safeFiles = HashMap<String, SafeFile>()
        val selectedStates = JSONArray()
        for (path in effectivePaths) {
            val candidate = candidateByPath[path]
            if (candidate == null) {
                addOmission(omitted, path, NOT_TRACKED)
                selectedStates.put(JSONObject().put("path", path).put("state", "not_tracked"))
                continue
            }
            val revision = candidate.getString("revision")
            if (revision.length == 40 && !RishLibgit2Native.blobExists(gitPath, workPath, revision)) {
                throw Refused(INTEGRITY, "a candidate's blob is missing")
            }
            if (!candidate.getBoolean("eligible")) {
                val reason = (candidate.opt("omission_reason") as? String) ?: POLICY
                addOmission(omitted, path, reason)
                selectedStates.put(JSONObject().put("path", path).put("state", "omitted").put("reason", reason).put("revision", revision))
                continue
            }
            if (safeFiles.size >= MAX_FILES) {
                addOmission(omitted, path, BUDGET_EXCEEDED)
                selectedStates.put(JSONObject().put("path", path).put("state", "omitted").put("reason", BUDGET_EXCEEDED).put("revision", revision))
                continue
            }
            val safe = safeReadPath(workDir, path)
            if (safe.data == null) {
                val reason = safe.reason ?: POLICY
                addOmission(omitted, path, reason)
                val stateRow = JSONObject().put("path", path).put("state", "omitted").put("reason", reason).put("revision", revision)
                safe.metadata?.let { stateRow.put("metadata", it) }
                safe.observationSha256?.let { stateRow.put("observation_sha256", it) }
                selectedStates.put(stateRow)
                continue
            }
            safeFiles[path] = safe
            selectedStates.put(
                JSONObject().put("path", path).put("state", "included").put("revision", revision)
                    .put("content_sha256", safe.sha256).put("metadata", safe.metadata),
            )
            if (includeBlocks) blocks.add(Block(path, "tracked_file", safe.data))
        }
        deadline.check()

        if (includeBlocks) {
            for (row in statusRows) {
                val kind = row.getString("kind")
                val oldPath = row.getString("old_path")
                val newPath = row.getString("new_path")
                val selectedPath = when {
                    newPath in effective -> newPath
                    oldPath in effective -> oldPath
                    else -> null
                } ?: continue
                if (selectedPath in conflictPaths) continue
                val safe = safeFiles[selectedPath] ?: continue
                val oldDecision = oldPath.takeIf { it.isNotEmpty() }?.let { AndroidProjectContextPolicy.decisionFor(it) }
                val newDecision = newPath.takeIf { it.isNotEmpty() }?.let { AndroidProjectContextPolicy.decisionFor(it) }
                if ((oldDecision != null && !oldDecision.eligible) || (newDecision != null && !newDecision.eligible)) {
                    val reason = if (oldDecision != null && !oldDecision.eligible) oldDecision.omissionReason else newDecision?.omissionReason
                    addOmission(omitted, selectedPath, reason ?: POLICY)
                    continue
                }
                val oldOid = row.getString("old_oid")
                val newOid = row.getString("new_oid")
                val oldBlob = if (isZero(oldOid)) null else (RishLibgit2Native.blob(gitPath, workPath, oldOid)
                    ?: throw Refused(INTEGRITY, "a changed file's old blob is missing"))
                val newBlob = if (kind == "staged" && !isZero(newOid)) {
                    RishLibgit2Native.blob(gitPath, workPath, newOid) ?: throw Refused(INTEGRITY, "a changed file's new blob is missing")
                } else null
                val oldValidation = validatedBlob(oldBlob)
                val newValidation: Pair<ByteArray?, String?> = if (kind == "staged") validatedBlob(newBlob) else Pair(safe.data, null)
                val reason = oldValidation.second ?: newValidation.second
                val deletion = row.getInt("status") == GIT_DELTA_DELETED
                if (reason != null || (kind == "worktree" && newValidation.first == null && !deletion)) {
                    addOmission(omitted, selectedPath, reason ?: POLICY)
                    continue
                }
                val patch = RishLibgit2Native.patch(
                    gitPath, workPath, kind == "staged", oldOid, oldPath, newOid, newPath,
                    if (kind == "staged") null else (newValidation.first ?: ByteArray(0)),
                ) ?: throw Refused(INTEGRITY, "a patch could not be serialized")
                blocks.add(Block(selectedPath, if (kind == "staged") "staged_diff" else "worktree_diff", patch))
            }
        }

        val fingerprintInput = JSONObject().put("policy_version", POLICY_VERSION)
            .put("root", identity(workDir)).put("git", identity(gitDir)).put("objects", identity(File(gitDir, "objects")))
            .put("project_metadata_sha256", projectMetadataSha256)
            .put("repository_state", state.getInt("repository_state"))
            .put("branch", branch ?: JSONObject.NULL).put("head_oid", headOid ?: JSONObject.NULL)
            .put("head_target", headTarget ?: JSONObject.NULL)
            .put("index_checksum", state.opt("index_checksum") ?: "none")
            .put("index_digest", sha256(RuntimeJson.canonical(JSONArray(indexRows)).toByteArray(Charsets.UTF_8)))
            .put("status_digest", sha256(RuntimeJson.canonical(JSONArray(statusRows)).toByteArray(Charsets.UTF_8)))
            .put("selection_intent", JSONArray(selectedPaths)).put("selected_paths", JSONArray(effectivePaths))
            .put("selected_states", selectedStates)
        return Capture(
            branch, headOid, changedPaths.isEmpty(),
            conflictPaths.isNotEmpty() || state.getInt("repository_state") != 0,
            sha256(RuntimeJson.canonical(fingerprintInput).toByteArray(Charsets.UTF_8)),
            candidates, blocks, omitted, JSONArray(disclosedRows), effectivePaths,
        )
    }

    // --- reading one file --------------------------------------------------

    /**
     * `safeReadPath`: every component walked and checked to be a directory
     * on the same device and not a link, the file itself a regular file with
     * one link within the size budget, its bytes read and re-checked against
     * the metadata seen before, and then judged by the content and secret
     * policies. What was observed is recorded whichever way it went.
     */
    private fun safeReadPath(workDir: File, relativePath: String): SafeFile {
        val components = relativePath.split("/")
        val rootStat = lstat(workDir.absolutePath) ?: throw Refused(NOT_FOUND, "the working tree is unavailable")
        var current = workDir
        for ((index, component) in components.dropLast(1).withIndex()) {
            val next = File(current, component)
            val before = lstat(next.absolutePath)
                ?: return SafeFile(null, null, POLICY, null, observationSha(JSONObject().put("state", "missing_ancestor").put("component_index", index)))
            if (!OsConstants.S_ISDIR(before.st_mode) || before.st_dev != rootStat.st_dev) {
                val descriptor = statDescriptor(before)
                return SafeFile(
                    null, null, POLICY, descriptor,
                    observationSha(JSONObject().put("state", "unsafe_ancestor").put("component_index", index).put("metadata", descriptor)),
                )
            }
            current = next
        }
        val file = File(current, components.last())
        val before = lstat(file.absolutePath)
            ?: return SafeFile(null, null, POLICY, null, observationSha(JSONObject().put("state", "missing")))
        val descriptor = statDescriptor(before)
        val observation = observationSha(descriptor)
        if (!OsConstants.S_ISREG(before.st_mode) || before.st_nlink != 1L || before.st_dev != rootStat.st_dev) {
            return SafeFile(null, null, POLICY, descriptor, observation)
        }
        if (before.st_size < 0 || before.st_size > MAX_FILE_BYTES) {
            return SafeFile(null, null, BUDGET_EXCEEDED, descriptor, observation)
        }
        val data = try { file.readBytes() } catch (_: Exception) { throw Refused(CHANGED, "the file changed while it was read") }
        val after = lstat(file.absolutePath) ?: throw Refused(CHANGED, "the file changed while it was read")
        if (!sameStat(before, after) || data.size.toLong() != before.st_size) throw Refused(CHANGED, "the file changed while it was read")
        val metadata = statDescriptor(after)
        val content = contentDecision(data)
        if (content != null) return SafeFile(null, null, content, metadata, sha256(data))
        if (suspectedSecret(data)) return SafeFile(null, null, SUSPECTED_SECRET, metadata, sha256(data))
        return SafeFile(data, sha256(data), null, metadata, null)
    }

    /** `validatedBlob`: the bytes when they may be shown, else the reason. */
    private fun validatedBlob(blob: ByteArray?): Pair<ByteArray?, String?> {
        if (blob == null) return Pair(ByteArray(0), null)
        if (blob.size > MAX_FILE_BYTES) return Pair(null, BUDGET_EXCEEDED)
        contentDecision(blob)?.let { return Pair(null, it) }
        if (suspectedSecret(blob)) return Pair(null, SUSPECTED_SECRET)
        return Pair(blob, null)
    }

    private fun contentDecision(data: ByteArray): String? {
        val reply = RishAgentCoreNative.projectContextReduce(JSONObject().put("op", "content_decision").toString(), data)
            ?.let { JSONObject(it) }?.takeIf { it.optBoolean("ok") } ?: return BINARY
        return if (reply.optBoolean("eligible")) null else (reply.opt("omission_reason") as? String ?: POLICY)
    }

    private fun suspectedSecret(data: ByteArray): Boolean =
        RishAgentCoreNative.projectContextReduce(JSONObject().put("op", "secret_decision").toString(), data)
            ?.let { JSONObject(it) }?.optBoolean("suspected_secret") != false

    private fun addOmission(omitted: JSONArray, path: String, reason: String) {
        for (index in 0 until omitted.length()) {
            val existing = omitted.getJSONObject(index)
            if (existing.optString("path") == path && existing.optString("reason") == reason) return
        }
        omitted.put(JSONObject().put("path", path).put("reason", reason))
    }

    private fun isZero(oid: String): Boolean = oid.isEmpty() || oid.all { it == '0' }

    private fun lstat(path: String): StructStat? = try { Os.lstat(path) } catch (_: Exception) { null }

    /** `DSHServiceStatDescriptor`, with whole-second times: what this platform's stat gives every API level. */
    private fun statDescriptor(stat: StructStat): JSONObject = JSONObject()
        .put("device", stat.st_dev).put("inode", stat.st_ino).put("mode", stat.st_mode).put("links", stat.st_nlink)
        .put("size", stat.st_size).put("mtime_seconds", stat.st_mtime).put("mtime_nanoseconds", 0)
        .put("ctime_seconds", stat.st_ctime).put("ctime_nanoseconds", 0)

    private fun sameStat(left: StructStat, right: StructStat): Boolean =
        left.st_dev == right.st_dev && left.st_ino == right.st_ino && left.st_mode == right.st_mode &&
            left.st_nlink == right.st_nlink && left.st_size == right.st_size &&
            left.st_mtime == right.st_mtime && left.st_ctime == right.st_ctime

    private fun observationSha(value: JSONObject): String = sha256(RuntimeJson.canonical(value).toByteArray(Charsets.UTF_8))

    /** Device and inode of a directory, as the fingerprint and the source descriptor record them. */
    fun identity(directory: File): JSONObject {
        val stat = lstat(directory.absolutePath) ?: return JSONObject().put("device", 0).put("inode", 0)
        return JSONObject().put("device", stat.st_dev).put("inode", stat.st_ino)
    }

    companion object {
        const val NOT_FOUND = "E_PROJECT_NOT_FOUND"
        const val INTEGRITY = "E_CONTEXT_INTEGRITY"
        const val BUDGET = "E_CONTEXT_BUDGET"
        const val CHANGED = "E_CONTEXT_CHANGED"
        const val TIMEOUT = "E_CONTEXT_TIMEOUT"
        const val POLICY_VERSION = "chat-read-v1.0.0"
        const val MAX_FILE_BYTES = 64L * 1024
        const val MAX_FILES = 32
        private const val MAX_CHANGED_PATHS = 100
        private const val MODE_BLOB = 0b1000000110100100
        private const val MODE_BLOB_EXECUTABLE = 0b1000000111101101
        private const val GIT_DELTA_DELETED = 2
        private const val POLICY = "policy"
        private const val BUDGET_EXCEEDED = "budget_exceeded"
        private const val NOT_TRACKED = "not_tracked"
        private const val SUSPECTED_SECRET = "suspected_secret"
        private const val BINARY = "binary"

        fun sha256(bytes: ByteArray): String =
            MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    }
}
