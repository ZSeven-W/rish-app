package tech.zseven.rish.runtime

import android.system.Os
import android.system.OsConstants
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID

/**
 * The git project a workspace is attached to, and how one gets attached.
 *
 * A workspace is a folder the person granted; a project is a git repository
 * over it. The two are tied by a binding, and the repository's own directory
 * lives outside the workspace in app-private storage --
 * `workspace-gitdirs/<workspace>/<project>/` beside the registry, the same
 * layout and the same `binding-v2.json` iOS writes, validated by the same
 * rules. Nothing inside the workspace says it is a repository.
 *
 * **Attaching is journaled.** The gitdir is built under a staging name, the
 * binding is written into it, the pairing is proven by opening it, and only
 * then is it renamed into place. A journal beside it records which phase the
 * operation reached, so a crash at any point leaves something the next call
 * can reconcile rather than a half-project the listing would trip over.
 * A staged directory without a published journal is swept; a published one
 * whose gitdir is missing is a failure this class refuses to guess about.
 *
 * Error numbers are iOS's (`LPError`), and the code JavaScript sees is the
 * shared rule's translation of them, so both hosts report an attach that
 * found a project already there as the same `E_PROJECT_BUSY`.
 */
internal class AndroidWorkspaceProjects(
    private val workspaces: AndroidWorkspaceRegistry,
    private val gitdirs: File = File(workspaces.root, GITDIRS_NAME),
) {
    /** A refusal by iOS's number; [code] is what JavaScript is told. */
    class Refused(val number: Int, reason: String) : Exception(reason) {
        val code: String get() = codeFor(number)
    }

    private val lock = Any()
    private val attachResults = HashMap<String, Pair<JSONObject, JSONObject>>()
    private var reconciled = false
    private var startupFailure: Refused? = null

    // --- what JavaScript asks -------------------------------------------

    /** `projectForWorkspaceV2`: `{status:"none"}` or `{status:"attached", project}`. */
    fun projectFor(rawRoot: JSONObject?): JSONObject = synchronized(lock) {
        val root = canonicalRoot(rawRoot, projectRequired = false)
        reconcileAtStartup()
        projectForCanonical(root)
    }

    /**
     * `attachWorkspaceProject`. `mode:"open"` answers only a project that is
     * already there; `mode:"init"` creates one when there is none. Repeating
     * an operation id answers what that operation answered.
     */
    fun attach(rawRequest: JSONObject?): JSONObject = synchronized(lock) {
        if (!RishLibgit2Native.require()) throw Refused(UNAVAILABLE, "libgit2 is not available")
        val request = rawRequest ?: throw Refused(REQUEST_INVALID, "attach request is missing")
        if (!exactKeys(request, ATTACH_KEYS) || request.opt("schema_version") != 1) {
            throw Refused(REQUEST_INVALID, "attach request is invalid")
        }
        val operationId = request.opt("operation_id") as? String
        val mode = request.opt("mode") as? String
        if (operationId == null || !canonicalOperationId(operationId) || (mode != "open" && mode != "init")) {
            throw Refused(REQUEST_INVALID, "attach request is invalid")
        }
        val root = canonicalRoot(request.optJSONObject("root"), projectRequired = false)
        val workspaceId = root.getString("workspace_id")
        reconcileAtStartup()
        reconcile(workspaceId)

        attachResults[operationId]?.let { (cachedRoot, result) ->
            if (RuntimeJson.canonical(cachedRoot) != RuntimeJson.canonical(root)) {
                throw Refused(OPERATION_CONFLICT, "attach operation conflicts")
            }
            val projectId = result.getJSONObject("project").getString("project_id")
            return@synchronized alreadyAttached(verifiedDescriptor(root, projectId))
        }
        if (!root.isNull("project_id")) {
            // The caller already knows the project; the answer is that
            // project, re-verified, or nothing.
            val descriptor = verifiedDescriptor(root, root.getString("project_id"))
            return@synchronized remember(operationId, root, alreadyAttached(descriptor))
        }
        val existing = projectForCanonical(root)
        if (existing.getString("status") == "attached") {
            val projectId = existing.getJSONObject("project").getString("project_id")
            return@synchronized remember(operationId, root, alreadyAttached(verifiedDescriptor(root, projectId)))
        }
        if (mode == "open") throw Refused(UNAVAILABLE, "workspace project is unavailable")
        remember(operationId, root, initialize(root, operationId))
    }

    // --- what a removal needs to know ------------------------------------

    /** A workspace's project relation, as a clearance sees it. */
    enum class Relation { NONE, PUBLISHED, IN_FLIGHT }

    /**
     * Whether this workspace has a published project, an attach in flight, or
     * neither. Anything under its gitdirs that is not a published project is
     * treated as in flight: unknown entries fail closed, as on iOS.
     */
    fun relation(workspaceId: String): Relation = synchronized(lock) {
        reconcileAtStartup()
        val entries = File(gitdirs, workspaceId).listFiles() ?: return Relation.NONE
        if (entries.isEmpty()) return Relation.NONE
        if (entries.any { it.name.startsWith(STAGING_PREFIX) }) return Relation.IN_FLIGHT
        if (entries.all { RuntimeJson.uuid(it.name) && File(it, BINDING_NAME).isFile }) return Relation.PUBLISHED
        Relation.IN_FLIGHT
    }

    /**
     * Runs [body] with no attach able to start, and afterwards drops what
     * this class remembered about the workspace: an attach result cached for
     * a root that no longer exists is not an answer for the next caller.
     */
    fun <T> excluding(workspaceId: String, body: () -> T): T = synchronized(lock) {
        reconcileAtStartup()
        try {
            body()
        } finally {
            attachResults.entries.removeAll { it.value.first.optString("workspace_id") == workspaceId }
        }
    }

    // --- the layout -------------------------------------------------------

    /** The private gitdir of one project: `workspace-gitdirs/<workspace>/<project>`. */
    fun gitDirectory(workspaceId: String, projectId: String): File =
        File(File(gitdirs, workspaceId), projectId)

    /** The working tree, which is the workspace root, or null when it cannot be proven. */
    fun workingTree(workspaceId: String): File? = workspaces.rootFor(workspaceId)

    /**
     * A root reference as the shared rule spells it, with `project_id`
     * present (possibly null) and `binding_revision` a number.
     */
    fun canonicalRoot(rawRoot: JSONObject?, projectRequired: Boolean): JSONObject {
        val raw = rawRoot ?: throw Refused(REQUEST_INVALID, "workspace root is missing")
        val valid = RishAgentCoreNative.projectAccessReduce(
            JSONObject().put("op", "root_ref_valid").put("root_ref", raw)
                .put("project_required", projectRequired).toString(),
        )?.let { JSONObject(it) }?.optBoolean("valid") == true
        val canonical = if (valid) {
            RishAgentCoreNative.projectAccessReduce(
                JSONObject().put("op", "canonical_root_ref").put("root_ref", raw).toString(),
            )?.let { JSONObject(it) }?.optJSONObject("root_ref")
        } else {
            null
        }
        return canonical ?: throw Refused(REQUEST_INVALID, "workspace root is invalid")
    }

    /** The project descriptor JavaScript reads, re-verified against the binding on disk. */
    fun verifiedDescriptor(root: JSONObject, projectId: String): JSONObject =
        verifiedDescriptorAndBinding(root, projectId).first

    /** The descriptor and the binding it was read from, for a caller that binds to the binding's digest. */
    fun verifiedDescriptorAndBinding(root: JSONObject, projectId: String): Pair<JSONObject, JSONObject> {
        val attached = rootWith(root, projectId)
        val binding = binding(attached, projectId)
        return Pair(descriptor(attached, projectId, binding.getString("display_name")), binding)
    }

    // --- reading ----------------------------------------------------------

    private fun projectForCanonical(root: JSONObject): JSONObject {
        val workspaceId = root.getString("workspace_id")
        if (!root.isNull("project_id")) {
            val projectId = root.getString("project_id")
            return attached(descriptor(root, projectId, binding(root, projectId).getString("display_name")))
        }
        val children = File(gitdirs, workspaceId).listFiles() ?: return none()
        val projectIds = children.map { it.name }
            .filter { !it.startsWith(STAGING_PREFIX) && RuntimeJson.uuid(it) }
            .sorted()
        // Every candidate has to hold a valid binding: a directory that
        // looks like a project and is not one is not skipped, it is refused.
        for (candidate in projectIds) binding(rootWith(root, candidate), candidate)
        if (projectIds.isEmpty()) return none()
        if (projectIds.size != 1) throw Refused(ALREADY_EXISTS, "workspace has conflicting projects")
        val projectId = projectIds.single()
        val attachedRoot = rootWith(root, projectId)
        return attached(descriptor(attachedRoot, projectId, binding(attachedRoot, projectId).getString("display_name")))
    }

    /**
     * The binding beside a project's gitdir, or a refusal. It has to restate
     * this root, this revision and this project, and carry the fingerprint the
     * workspace authority carries now: a binding for a root that has since
     * been replaced is a binding for something else.
     */
    private fun binding(root: JSONObject, projectId: String): JSONObject {
        val workspaceId = root.getString("workspace_id")
        val file = File(gitDirectory(workspaceId, projectId), BINDING_NAME)
        if (!file.isFile || file.length() <= 0 || file.length() > MAX_BINDING_BYTES) {
            throw Refused(UNAVAILABLE, "workspace project is unavailable")
        }
        val binding = try {
            JSONObject(file.readText(Charsets.UTF_8))
        } catch (_: Exception) {
            throw Refused(BINDING_INVALID, "project binding is invalid")
        }
        if (!exactKeys(binding, BINDING_KEYS) || binding.opt("schema_version") != 2 ||
            binding.opt("workspace_id") != workspaceId ||
            binding.opt("binding_revision") != root.get("binding_revision") ||
            binding.opt("project_id") != projectId ||
            binding.opt("git_topology") != GIT_TOPOLOGY ||
            !boundedString(binding.opt("display_name"), MAX_DISPLAY_NAME_BYTES) ||
            !canonicalDigest(binding.opt("root_fingerprint_sha256"))
        ) {
            throw Refused(BINDING_INVALID, "project binding is invalid")
        }
        if (binding.getString("root_fingerprint_sha256") != rootFingerprint(workspaceId, root.get("binding_revision"))) {
            throw Refused(BINDING_INVALID, "project binding is invalid")
        }
        return binding
    }

    /**
     * The workspace's current fingerprint: the registry's record at this
     * revision, provable now. A root that no longer holds -- wrong revision,
     * changed directory, no authority -- has no fingerprint to compare
     * against, and a binding cannot be checked against nothing.
     */
    private fun rootFingerprint(workspaceId: String, bindingRevision: Any): String {
        val record = workspaces.list().firstOrNull { it.optString("workspace_id") == workspaceId }
            ?: throw Refused(UNAVAILABLE, "workspace project is unavailable")
        if (record.opt("binding_revision") != bindingRevision) throw Refused(UNAVAILABLE, "workspace project is unavailable")
        if (workspaces.descriptor(workspaceId)?.optString("status") != "ok") throw Refused(UNAVAILABLE, "workspace project is unavailable")
        return workspaces.fingerprintFor(workspaceId)?.takeIf { canonicalDigest(it) }
            ?: throw Refused(UNAVAILABLE, "workspace project is unavailable")
    }

    /**
     * `LPV2ProjectDisplayName`: the project is named after the workspace it
     * lives in, and a name that would not survive as a path component --
     * empty, oversized, a control character, a slash, `.` or `..` -- falls
     * back to the project id rather than being repaired.
     */
    private fun projectDisplayName(candidate: Any?, projectId: String): String {
        val name = candidate as? String ?: return projectId
        if (name.isEmpty() || name.toByteArray(Charsets.UTF_8).size > MAX_DISPLAY_NAME_BYTES ||
            name.any { it.isISOControl() } || '/' in name || '\\' in name || name == "." || name == ".."
        ) return projectId
        return name
    }

    private fun descriptor(root: JSONObject, projectId: String, displayName: String): JSONObject =
        JSONObject().put("schema_version", 2).put("project_id", projectId)
            .put("workspace_id", root.getString("workspace_id"))
            .put("workspace_binding_revision", root.get("binding_revision"))
            .put("display_name", displayName).put("git_topology", GIT_TOPOLOGY)

    // --- attaching --------------------------------------------------------

    private fun initialize(root: JSONObject, operationId: String): JSONObject {
        val workspaceId = root.getString("workspace_id")
        val descriptor = workspaces.descriptor(workspaceId)
        val capabilities = descriptor?.optJSONObject("capabilities")
        if (descriptor?.optString("status") != "ok" || capabilities == null ||
            !INIT_CAPABILITIES.all { capabilities.optBoolean(it) }
        ) {
            throw Refused(UNAVAILABLE, "workspace project is unavailable")
        }
        val workingTree = workingTree(workspaceId)?.takeIf { it.isDirectory }
            ?: throw Refused(UNAVAILABLE, "workspace project is unavailable")
        val fingerprint = rootFingerprint(workspaceId, root.get("binding_revision"))
        val projectId = UUID.randomUUID().toString()
        val displayName = projectDisplayName(descriptor.opt("display_name"), projectId)
        val parent = File(gitdirs, workspaceId)
        val staging = File(parent, STAGING_PREFIX + operationId)
        val journal = File(parent, STAGING_PREFIX + operationId + JOURNAL_SUFFIX)
        val final = File(parent, projectId)
        if (!parent.isDirectory && !parent.mkdirs()) {
            throw Refused(STORAGE, "attach staging root cannot be created")
        }
        fsyncDirectory(gitdirs)

        val record = JSONObject().put("schema_version", 1).put("operation_id", operationId)
            .put("workspace_id", workspaceId).put("binding_revision", root.get("binding_revision"))
            .put("project_id", projectId).put("root_fingerprint_sha256", fingerprint)
            .put("staging_name", staging.name).put("final_name", final.name)
            .put("phase", PHASE_PREPARED)
        // Only what this operation made is its to remove: staging that was
        // already there belongs to another operation, and is left for
        // reconciliation.
        var createdStaging = false
        var published = false
        try {
            writeDurably(journal, record)
            if (staging.exists()) throw Refused(ALREADY_EXISTS, "workspace project already exists")
            if (!staging.mkdir()) throw Refused(STORAGE, "attach staging creation failed")
            createdStaging = true
            fsyncDirectory(parent)
            val initialized = RishLibgit2Native.initSplitRepository(staging.absolutePath, workingTree.absolutePath)
            if (initialized != "ok") throw Refused(STORAGE, "project repository cannot be initialised")
            writeDurably(
                File(staging, BINDING_NAME),
                JSONObject().put("schema_version", 2).put("workspace_id", workspaceId)
                    .put("binding_revision", root.get("binding_revision")).put("project_id", projectId)
                    .put("display_name", displayName).put("git_topology", GIT_TOPOLOGY)
                    .put("git_directory_relative", "$GITDIRS_NAME/$workspaceId/$projectId")
                    .put("root_fingerprint_sha256", fingerprint),
            )
            // The pairing is proven on the staged directory before anything
            // is published; a gitdir that cannot be opened is not a project.
            val preflight = JSONObject(RishLibgit2Native.readRepositoryState(staging.absolutePath, workingTree.absolutePath))
            if (!preflight.optBoolean("ok")) throw Refused(UNAVAILABLE, "workspace project verification failed")
            if (final.exists()) throw Refused(ALREADY_EXISTS, "workspace project already exists")
            try {
                Files.move(staging.toPath(), final.toPath(), StandardCopyOption.ATOMIC_MOVE)
            } catch (_: Exception) {
                throw Refused(STORAGE, "workspace project cannot be published")
            }
            published = true
            fsyncDirectory(parent)
            writeDurably(journal, record.put("phase", PHASE_PUBLISHED))
            // The published directory is read back through the same path
            // every later call takes: the binding, then the repository.
            val verified = verifiedDescriptor(root, projectId)
            val opened = JSONObject(RishLibgit2Native.readRepositoryState(final.absolutePath, workingTree.absolutePath))
            if (!opened.optBoolean("ok")) throw Refused(UNAVAILABLE, "workspace project verification failed")
            remove(journal)
            return attached(verified)
        } catch (failure: Throwable) {
            if (published) remove(final) else if (createdStaging) remove(staging)
            remove(journal)
            throw failure
        }
    }

    // --- reconciliation ---------------------------------------------------

    private fun reconcileAtStartup() {
        startupFailure?.let { throw it }
        if (reconciled) return
        try {
            gitdirs.listFiles()?.map { it.name }?.filter { RuntimeJson.uuid(it) }?.sorted()?.forEach { reconcile(it) }
            reconciled = true
        } catch (failure: Refused) {
            startupFailure = failure
            throw failure
        }
    }

    /**
     * Settles what an interrupted attach left behind in one workspace's
     * gitdirs, as iOS does at the same point. Each `.rish-attach-<op>` entry
     * is staging or a journal; a journal decides its staging's fate, and
     * staging without a journal never got as far as mattering.
     */
    private fun reconcile(workspaceId: String) {
        val parent = File(gitdirs, workspaceId)
        val entries = parent.listFiles() ?: return
        val stagings = HashMap<String, File>()
        val journals = HashMap<String, Pair<File, JSONObject>>()
        for (entry in entries) {
            if (!entry.name.startsWith(STAGING_PREFIX)) continue
            var operation = entry.name.removePrefix(STAGING_PREFIX)
            val isJournal = operation.endsWith(JOURNAL_SUFFIX)
            if (isJournal) operation = operation.removeSuffix(JOURNAL_SUFFIX)
            if (!canonicalOperationId(operation)) throw Refused(STORAGE, "attach staging entry is invalid")
            if (isJournal) {
                if (journals.containsKey(operation)) throw Refused(STORAGE, "attach journal is duplicated")
                journals[operation] = Pair(entry, readJournal(entry, workspaceId, operation))
            } else {
                if (stagings.containsKey(operation)) throw Refused(STORAGE, "attach staging is duplicated")
                stagings[operation] = entry
            }
        }
        for ((operation, journalEntry) in journals) {
            val (journalFile, journal) = journalEntry
            val staging = stagings[operation]
            val final = File(parent, journal.getString("final_name"))
            val stagingExists = staging?.exists() == true
            val finalExists = final.exists()
            if ((stagingExists && finalExists) || (journal.getString("phase") == PHASE_PUBLISHED && stagingExists)) {
                throw Refused(STORAGE, "attach recovery is ambiguous")
            }
            if (finalExists) {
                // Published and present: it is a project only if its binding
                // still says what the journal says.
                val root = JSONObject().put("schema_version", 1).put("workspace_id", workspaceId)
                    .put("binding_revision", journal.get("binding_revision"))
                    .put("project_id", journal.getString("project_id"))
                val binding = try {
                    binding(root, journal.getString("project_id"))
                } catch (_: Refused) {
                    throw Refused(STORAGE, "published attach is invalid")
                }
                if (binding.getString("root_fingerprint_sha256") != journal.getString("root_fingerprint_sha256")) {
                    throw Refused(STORAGE, "published attach is invalid")
                }
            }
            if (stagingExists) remove(staging!!)
            remove(journalFile)
            stagings.remove(operation)
        }
        for (staging in stagings.values) remove(staging)
    }

    private fun readJournal(file: File, workspaceId: String, operation: String): JSONObject {
        val journal = try {
            JSONObject(file.readText(Charsets.UTF_8))
        } catch (_: Exception) {
            throw Refused(STORAGE, "attach journal is invalid")
        }
        val phase = journal.opt("phase")
        val projectId = journal.opt("project_id") as? String
        if (!exactKeys(journal, JOURNAL_KEYS) || journal.opt("schema_version") != 1 ||
            journal.opt("operation_id") != operation || journal.opt("workspace_id") != workspaceId ||
            (journal.opt("binding_revision") as? Int ?: 0) < 1 ||
            projectId == null || !RuntimeJson.uuid(projectId) ||
            !canonicalDigest(journal.opt("root_fingerprint_sha256")) ||
            journal.opt("staging_name") != STAGING_PREFIX + operation ||
            journal.opt("final_name") != projectId ||
            (phase != PHASE_PREPARED && phase != PHASE_PUBLISHED)
        ) {
            throw Refused(STORAGE, "attach journal is invalid")
        }
        return journal
    }

    // --- small helpers ----------------------------------------------------

    private fun remember(operationId: String, root: JSONObject, result: JSONObject): JSONObject {
        attachResults[operationId] = Pair(root, result)
        return result
    }

    private fun rootWith(root: JSONObject, projectId: String): JSONObject =
        JSONObject().put("schema_version", 1).put("workspace_id", root.getString("workspace_id"))
            .put("binding_revision", root.get("binding_revision")).put("project_id", projectId)

    private fun none(): JSONObject = JSONObject().put("schema_version", 1).put("status", "none")
    private fun attached(project: JSONObject): JSONObject =
        JSONObject().put("schema_version", 1).put("status", "attached").put("project", project)
    private fun alreadyAttached(project: JSONObject): JSONObject =
        JSONObject().put("schema_version", 1).put("status", "already_attached").put("project", project)

    /** Written whole, synced, and in the sorted-key bytes iOS writes. */
    private fun writeDurably(file: File, value: JSONObject) {
        try {
            FileOutputStream(file).use { stream ->
                stream.write(RuntimeJson.receiptJson(value).toByteArray(Charsets.UTF_8))
                stream.fd.sync()
            }
        } catch (_: Exception) {
            throw Refused(STORAGE, "attach record cannot be saved")
        }
        fsyncDirectory(file.parentFile ?: throw Refused(STORAGE, "attach record cannot be saved"))
    }

    private fun fsyncDirectory(directory: File) {
        try {
            val descriptor = Os.open(directory.absolutePath, OsConstants.O_RDONLY, 0)
            try {
                Os.fsync(descriptor)
            } finally {
                Os.close(descriptor)
            }
        } catch (_: Exception) {
            throw Refused(STORAGE, "attach directory is not durable")
        }
    }

    private fun remove(target: File) {
        if (!target.exists()) return
        if (!target.deleteRecursively()) throw Refused(STORAGE, "attach cleanup failed")
    }

    private fun exactKeys(value: JSONObject, keys: Set<String>): Boolean =
        value.keys().asSequence().toSet() == keys

    fun canonicalOperationId(value: String): Boolean =
        RishAgentCoreNative.projectModuleReduce(
            JSONObject().put("op", "canonical_operation_id").put("value", value).toString(),
        )?.let { JSONObject(it) }?.optBoolean("valid") == true

    private fun boundedString(value: Any?, maximumBytes: Int): Boolean =
        RishAgentCoreNative.projectModuleReduce(
            JSONObject().put("op", "bounded_string").put("value", value ?: JSONObject.NULL)
                .put("maximum_bytes", maximumBytes).put("allow_empty", false).toString(),
        )?.let { JSONObject(it) }?.optBoolean("valid") == true

    private fun canonicalDigest(value: Any?): Boolean =
        (value as? String)?.let { it.length == 64 && it.all { c -> c in '0'..'9' || c in 'a'..'f' } } == true

    companion object {
        const val GITDIRS_NAME = "workspace-gitdirs"
        const val BINDING_NAME = "binding-v2.json"
        const val GIT_TOPOLOGY = "private_split_gitdir"
        private const val STAGING_PREFIX = ".rish-attach-"
        private const val JOURNAL_SUFFIX = ".journal"
        private const val PHASE_PREPARED = "prepared"
        private const val PHASE_PUBLISHED = "published"
        private const val MAX_BINDING_BYTES = 64L * 1024
        private const val MAX_DISPLAY_NAME_BYTES = 120
        private val INIT_CAPABILITIES = listOf("read", "write", "git")
        private val ATTACH_KEYS = setOf("schema_version", "operation_id", "root", "mode")
        private val BINDING_KEYS = setOf(
            "schema_version", "workspace_id", "binding_revision", "project_id",
            "display_name", "git_topology", "git_directory_relative", "root_fingerprint_sha256",
        )
        private val JOURNAL_KEYS = setOf(
            "schema_version", "operation_id", "workspace_id", "binding_revision", "project_id",
            "root_fingerprint_sha256", "staging_name", "final_name", "phase",
        )

        // iOS's LPError numbers; the shared rule turns them into codes.
        const val REQUEST_INVALID = 3101
        const val UNAVAILABLE = 3102
        const val STORAGE = 3104
        const val BINDING_INVALID = 3104
        const val ALREADY_EXISTS = 3105
        const val OPERATION_CONFLICT = 3106

        fun codeFor(number: Int): String = RishAgentCoreNative.projectModuleReduce(
            JSONObject().put("op", "stable_error_code").put("domain", "LocalProjects").put("code", number).toString(),
        )?.let { JSONObject(it) }?.optString("code")?.takeIf { it.isNotEmpty() } ?: "E_PROJECT_NATIVE"
    }
}
