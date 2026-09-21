package tech.zseven.rish.runtime

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException

/**
 * The file work an agent does inside a workspace it is bound to.
 *
 * Mirrors modules/rish/ios/Sources/AgentWorkspaceToolExecutor.mm. Every rule is
 * the core's and asked for: which path components a tool argument may name, how
 * many bytes may be read, how a file revision is spelled. What is left here is
 * the mechanism -- opening, reading, writing, listing -- and the containment
 * that keeps all of it under one root.
 *
 * **Containment, and where it is weaker than iOS.** The core's path rule makes
 * an escape by `..` impossible: a component that is `.`, `..`, `.git` or
 * `.trash` is refused, and so is a leading slash, a backslash, a NUL, a
 * non-NFC spelling and any control or format character. That leaves symbolic
 * links, and iOS closes those with `openat` against a frozen root descriptor,
 * so the check and the open cannot disagree. Here the resolved path is compared
 * against the root's canonical path before the file is touched, which is a
 * check and then an open: a link swapped between the two would not be caught.
 *
 * That is sound for a workspace this app owns -- it lives under `filesDir`,
 * where nothing but this app can create anything, and the only writer is this
 * executor, which writes regular files. It stops being sound the day a folder
 * the person granted through the Storage Access Framework becomes a workspace
 * root, and that is the day this needs the descriptor discipline instead.
 */
internal class AndroidWorkspaceToolExecutor(
    private val workspaces: AndroidWorkspaceRegistry,
    private val roots: AndroidAgentRootResolver,
) {

    /** A refusal carrying the agent's vocabulary rather than a message. */
    class Refused(val code: String) : Exception(code)

    /** The three tools a workspace root carries. */
    val tools: List<String> = listOf("read_file", "write_file", "list_dir")

    private fun rule(request: JSONObject): JSONObject =
        RishAgentCoreNative.workspaceTool(request) ?: throw Refused(INVALID)

    private fun bounds(): JSONObject = rule(JSONObject().put("op", "bounds"))

    /**
     * The components of a tool's path argument, decided by the core. `list_dir`
     * may name the root itself; a file tool never can.
     */
    private fun components(path: String, allowRoot: Boolean): List<String> {
        val reply = rule(
            JSONObject().put("op", "path_components").put("path", path)
                .put("allow_root", allowRoot),
        )
        val array = reply.optJSONArray("components") ?: throw Refused(INVALID)
        return (0 until array.length()).map { array.getString(it) }
    }

    /**
     * The file a path names, or a refusal. The canonical path is compared
     * before anything is opened; see the note on containment above.
     */
    private fun resolve(root: File, components: List<String>): File {
        var target = root
        for (component in components) target = File(target, component)
        val canonicalRoot = try {
            root.canonicalFile
        } catch (_: IOException) {
            throw Refused(PERSISTENCE)
        }
        // A file that does not exist yet has no canonical path of its own, so
        // the parent is what has to be inside the root; the leaf is a name.
        val probe = if (target.exists()) target else target.parentFile ?: throw Refused(INVALID)
        val canonical = try {
            probe.canonicalFile
        } catch (_: IOException) {
            throw Refused(PERSISTENCE)
        }
        if (canonical != canonicalRoot && !canonical.path.startsWith(canonicalRoot.path + File.separator)) {
            throw Refused(CONFLICT)
        }
        return target
    }

    /** `dev:ino:size:mtime_sec:mtime_nsec`, spelled by the core. */
    private fun revision(file: File): String {
        // Android exposes no st_dev or st_ino through java.io, and the rule
        // only requires the five numbers to identify a file state, so the
        // fields this platform cannot read are reported as zero rather than
        // invented. A file that changed still changes size or mtime.
        val reply = rule(
            JSONObject().put("op", "revision").put("dev", 0).put("ino", 0)
                .put("size", file.length()).put("mtime_sec", file.lastModified() / 1000)
                .put("mtime_nsec", (file.lastModified() % 1000) * 1_000_000),
        )
        return reply.optString("revision").ifEmpty { throw Refused(INVALID) }
    }

    /**
     * Runs one tool against the root a binding resolves to.
     *
     * `root` is the agent root reference, not a path: which directory it names
     * is the resolver's answer, and a request naming a project or a workspace
     * this device does not hold is refused there rather than here.
     */
    fun execute(name: String, arguments: JSONObject, root: JSONObject): JSONObject {
        if (name !in tools) throw Refused(INVALID)
        val workspaceId = root.optString("workspace_id").takeIf { it.isNotEmpty() }
        // The tool holds the workspace while it runs, so a removal waits for
        // it rather than renaming the directory from under a write.
        if (workspaceId == null || !RuntimeJson.uuid(workspaceId)) throw Refused(CONFLICT)
        return try {
            workspaces.holding(workspaceId) { executeHeld(name, arguments, root, workspaceId) }
        } catch (_: AndroidWorkspaceRegistry.Refused) {
            throw Refused(CONFLICT)
        }
    }

    private fun executeHeld(name: String, arguments: JSONObject, root: JSONObject, workspaceId: String): JSONObject {
        // The projection carries the authority -- which grants this root has,
        // and the fingerprint the registry sealed it under. It deliberately
        // carries no path: where the directory is stays with the registry, and
        // a path is not something JavaScript's root reference should imply.
        val resolved = roots.resolveAgentProjection(root) ?: throw Refused(CONFLICT)
        val directory = workspaces.rootFor(workspaceId ?: throw Refused(CONFLICT))
            ?: throw Refused(CONFLICT)
        if (!directory.isDirectory) throw Refused(CONFLICT)

        // A capability the binding does not carry is a conflict, not an
        // invalid argument: the tool is real and the root simply may not. The
        // names are the projection's -- `file_read` and `file_write`, what a
        // tool may do -- not the registry's `read`/`write` grants, which are
        // about the binding. Checking the wrong list accepted every tool.
        val capabilities = resolved.optJSONArray("capabilities") ?: JSONArray()
        val needed = if (name == "write_file") "file_write" else "file_read"
        if ((0 until capabilities.length()).none { capabilities.optString(it) == needed }) {
            throw Refused(CONFLICT)
        }

        return when (name) {
            "read_file" -> readFile(directory, arguments)
            "write_file" -> writeFile(directory, arguments)
            else -> listDir(directory, arguments)
        }
    }

    /**
     * What a call asserts about the world before it runs, and what a person
     * would be approving. The batch gate needs both before any effect: a
     * precondition the ledger row carries, and a preview that never contains
     * the file's bytes beyond the core's own prior-read cap.
     *
     * Shapes are the core's and iOS's, not this file's. A `read_file` asserts
     * the revision it read; a `write_file` asserts the prior the caller
     * claimed, and refuses when the disk disagrees -- that check is why a
     * stale write is a conflict here rather than a silent overwrite later.
     */
    fun prepare(name: String, arguments: JSONObject, root: JSONObject): JSONObject {
        if (name !in tools) throw Refused(INVALID)
        val directory = rootDirectory(name, root)
        val prepared = when (name) {
            "list_dir" -> prepareList(directory, arguments)
            "read_file" -> prepareRead(directory, arguments)
            else -> prepareWrite(directory, arguments)
        }
        // What the call reserves is part of the prepared shape, not an extra:
        // the ledger holds a write's reservation to its precondition's
        // content_bytes, and a prepared call that omits the key reserves zero
        // -- which refuses every write batch as a conflict. Only a write
        // reserves anything, exactly as iOS reports it.
        val reserved = if (name == "write_file") {
            prepared.getJSONObject("precondition").optInt("content_bytes")
        } else {
            0
        }
        return prepared.put("schema_version", 1).put("reserved_write_bytes", reserved)
    }

    private fun prepareList(root: File, arguments: JSONObject): JSONObject {
        val keys = arguments.keys().asSequence().toSet()
        if (keys.isNotEmpty() && keys != setOf("path")) throw Refused(INVALID)
        val requested = if (keys.isEmpty()) "" else path(arguments)
        val parts = components(requested, allowRoot = true)
        val directory = resolve(root, parts)
        if (!directory.isDirectory) throw Refused(NOT_FOUND)
        // The fingerprint a listing asserts is the core's, over the public
        // entries it would report -- not one this file invents. A home-made
        // digest agrees with nothing the ledger or the other platform computes.
        val fingerprint = listing(directory).optString("directory_fingerprint_sha256")
            .takeIf { it.isNotEmpty() } ?: throw Refused(PERSISTENCE)
        return JSONObject()
            .put(
                "precondition",
                JSONObject().put("schema_version", 1).put("kind", "list_dir")
                    .put("directory_fingerprint_sha256", fingerprint),
            )
            .put("approval_preview", preview("list_dir", if (parts.isEmpty()) JSONArray() else JSONArray().put(requested)))
    }

    private fun prepareRead(root: File, arguments: JSONObject): JSONObject {
        if (arguments.keys().asSequence().toSet() != setOf("path")) throw Refused(INVALID)
        val requested = path(arguments)
        val file = resolve(root, components(requested, allowRoot = false))
        if (!file.isFile) throw Refused(NOT_FOUND)
        return JSONObject()
            .put(
                "precondition",
                JSONObject().put("schema_version", 1).put("kind", "read_file")
                    .put("source_revision", revision(file)),
            )
            .put("approval_preview", preview("read_file", JSONArray().put(requested)))
    }

    private fun prepareWrite(root: File, arguments: JSONObject): JSONObject {
        val content = arguments.opt("content")
        if (content !is String) throw Refused(INVALID)
        val requested = path(arguments)
        val file = resolve(root, components(requested, allowRoot = false))
        // Which prior a write asserts is the core's reading of its arguments,
        // not this file's: a call naming neither form asserts the file absent.
        val expected = rule(
            JSONObject().put("op", "write_expected_prior").put("arguments", arguments),
        ).optJSONObject("expected_prior") ?: throw Refused(INVALID)
        val actual = if (file.isFile) {
            JSONObject().put("schema_version", 1).put("kind", "known")
                .put("revision", revision(file))
        } else {
            if (file.exists()) throw Refused(CONFLICT)
            JSONObject().put("schema_version", 1).put("kind", "absent")
        }
        // Compared in the core's canonical form, not by toString(): two JSON
        // objects with the same content can print their keys in different
        // orders, and they did -- the core emits them sorted and a JSONObject
        // built here keeps insertion order, so every fresh write looked like a
        // conflict. "The same value" is the canonicaliser's answer, and it is
        // the one both platforms already use to decide it.
        val same = RishAgentCoreNative.canonical(expected.toString())
            ?.let { it == RishAgentCoreNative.canonical(actual.toString()) } ?: false
        if (!same) throw Refused(CONFLICT)
        // The preview's prior is not the precondition's: the ledger validates
        // it as exactly {schema_version, kind, bytes}, so a `revision` there --
        // or a missing `bytes` -- refuses the whole batch as invalid. iOS
        // builds the two shapes separately for the same reason.
        val priorPreview = JSONObject().put("schema_version", 1)
            .put("kind", actual.optString("kind"))
            .put(
                "bytes",
                if (file.isFile) file.length().toInt() else JSONObject.NULL,
            )
        val bytes = content.toByteArray(Charsets.UTF_8)
        val pathDigest = RishAgentCoreNative.hashBytes(
            "relative-path", requested.toByteArray(Charsets.UTF_8),
        ) ?: throw Refused(PERSISTENCE)
        val contentDigest = RishAgentCoreNative.hashBytes("file-content", bytes)
            ?: throw Refused(PERSISTENCE)
        return JSONObject()
            .put(
                "precondition",
                JSONObject().put("schema_version", 2).put("kind", "write_file")
                    .put("relative_path_sha256", pathDigest).put("prior", actual)
                    .put("content_sha256", contentDigest).put("content_bytes", bytes.size),
            )
            .put(
                "approval_preview",
                JSONObject().put("schema_version", 1).put("kind", "write_file")
                    .put("paths", JSONArray().put(requested))
                    .put("content_bytes", bytes.size)
                    .put("prior", priorPreview)
                    .put("diff_preview", JSONObject.NULL)
                    .put("diff_truncated", false),
            )
    }

    /** A read never previews content; only what it would touch. */
    private fun preview(kind: String, paths: JSONArray): JSONObject = JSONObject()
        .put("schema_version", 1).put("kind", kind).put("paths", paths)
        .put("content_bytes", JSONObject.NULL).put("prior", JSONObject.NULL)
        .put("diff_preview", JSONObject.NULL).put("diff_truncated", false)

    /** The directory a root names, with the capability the tool needs. */
    private fun rootDirectory(name: String, root: JSONObject): File {
        val workspaceId = root.optString("workspace_id").takeIf { it.isNotEmpty() }
        val resolved = roots.resolveAgentProjection(root) ?: throw Refused(CONFLICT)
        val directory = workspaces.rootFor(workspaceId ?: throw Refused(CONFLICT))
            ?: throw Refused(CONFLICT)
        if (!directory.isDirectory) throw Refused(CONFLICT)
        val capabilities = resolved.optJSONArray("capabilities") ?: JSONArray()
        val needed = if (name == "write_file") "file_write" else "file_read"
        if ((0 until capabilities.length()).none { capabilities.optString(it) == needed }) {
            throw Refused(CONFLICT)
        }
        return directory
    }

    private fun path(arguments: JSONObject, key: String = "path"): String {
        val value = arguments.opt(key)
        if (value !is String) throw Refused(INVALID)
        return value
    }

    /**
     * What the world says about a call whose process died, for a recovery.
     *
     * Three answers, and only three: `not_dispatched` when the effect provably
     * never happened, `settled` when it provably did, and `ambiguous` when the
     * disk cannot tell -- which the core turns into a failure the model is
     * shown rather than a silent retry. Guessing `not_dispatched` when a write
     * may have landed is how an agent writes a file twice.
     *
     * A read or a listing has no effect to find, so it is re-prepared: the
     * same precondition means nothing moved and the call can simply be run
     * again; anything else means the world changed under it.
     */
    fun recover(
        name: String,
        arguments: JSONObject,
        root: JSONObject,
        precondition: JSONObject?,
    ): JSONObject {
        if (name !in tools) throw Refused(INVALID)
        if (name != "write_file") {
            val fresh = prepare(name, arguments, root).optJSONObject("precondition")
            return status(if (sameJson(fresh, precondition)) "not_dispatched" else "ambiguous")
        }
        val directory = rootDirectory(name, root)
        val content = arguments.opt("content") as? String ?: throw Refused(INVALID)
        val requested = path(arguments)
        val file = resolve(directory, components(requested, allowRoot = false))
        val prior = precondition?.optJSONObject("prior")
        val priorKind = prior?.optString("kind")
        if (!file.exists()) {
            // Still absent, and absence is what the call asserted: nothing
            // happened. If it asserted otherwise the file is simply gone, and
            // this cannot say by whose hand.
            return status(if (priorKind == "absent") "not_dispatched" else "ambiguous")
        }
        if (!file.isFile) return status("ambiguous")
        val before = revision(file)
        if (priorKind == "known" && prior.optString("revision") == before) {
            // The file is exactly as the call found it: the write never landed.
            return status("not_dispatched")
        }
        val bytes = content.toByteArray(Charsets.UTF_8)
        if (file.length() != bytes.size.toLong()) return status("ambiguous")
        val actual = try {
            file.readBytes()
        } catch (_: IOException) {
            return status("ambiguous")
        }
        // Read between two readings of the revision: a file being written
        // while this looks at it is ambiguous, not settled.
        val stable = revision(file) == before
        val digest = RishAgentCoreNative.hashBytes("file-content", actual)
        val landed = stable && digest != null &&
            digest == precondition?.optString("content_sha256")
        return status(if (landed) "settled" else "ambiguous").put("actual_revision", before)
    }

    private fun status(value: String): JSONObject =
        JSONObject().put("schema_version", 1).put("status", value)

    /** Two JSON values are the same value when the core canonicalises alike. */
    private fun sameJson(left: JSONObject?, right: JSONObject?): Boolean {
        if (left == null || right == null) return false
        val canonical = { value: JSONObject -> RishAgentCoreNative.canonical(value.toString()) }
        val a = canonical(left) ?: return false
        return a == canonical(right)
    }

    /**
     * What a finished tool reports, in the one shape the ledger settles.
     *
     * `feedback` is the canonical JSON *string* of the model-facing object,
     * built and validated by the core: the settlement reducer parses it, hashes
     * it and holds it to the feedback contract, so a host that returns its own
     * loose object settles nothing. `settled_facts` is what the row records
     * about the world afterwards, and `effect_may_have_occurred` is the only
     * thing a retry needs to know.
     */
    private fun effect(
        feedback: String,
        settledFacts: Any,
        truncated: Boolean,
        mayHaveOccurred: Boolean,
    ): JSONObject = JSONObject().put("schema_version", 1)
        .put("status", "ok").put("feedback", feedback)
        .put("settled_facts", settledFacts).put("truncated", truncated)
        .put("effect_may_have_occurred", mayHaveOccurred)

    /** The core's canonical feedback string, or null when it will not fit. */
    private fun feedbackOrNull(name: String, payload: JSONObject): String? =
        RishAgentCoreNative.workspaceTool(
            JSONObject().put("op", "feedback").put(
                "feedback",
                JSONObject().put("schema_version", 1).put("name", name)
                    .put("outcome", "ok").put("payload", payload),
            ),
        )?.optString("feedback")?.takeIf { it.isNotEmpty() }

    /** Plain SHA-256, hex: what the feedback payload's `sha256` means. */
    private fun sha256(bytes: ByteArray): String =
        java.security.MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it) }

    /**
     * The directory as the core reads it: which entries are public, and the
     * fingerprint over them. Both sides of a listing -- what a call asserts
     * when it is prepared and what it reports when it runs -- come from here,
     * so the two cannot disagree.
     */
    private fun listing(directory: File): JSONObject {
        val children = directory.listFiles() ?: throw Refused(PERSISTENCE)
        val entries = JSONArray()
        for (child in children.sortedBy { it.name }) {
            entries.put(
                JSONObject().put("name", child.name)
                    .put("kind", if (child.isDirectory) "directory" else "file")
                    .put("revision", revision(child)),
            )
        }
        return rule(JSONObject().put("op", "directory_listing").put("entries", entries))
    }

    private fun readFile(root: File, arguments: JSONObject): JSONObject {
        if (arguments.keys().asSequence().toSet() != setOf("path")) throw Refused(INVALID)
        val file = resolve(root, components(path(arguments), allowRoot = false))
        if (!file.isFile) throw Refused(NOT_FOUND)
        val cap = bounds().getInt("max_read_bytes")
        val bytes = try {
            file.inputStream().use { stream ->
                // One byte past the cap, so a file exactly at the cap is not
                // reported as truncated and one over it is.
                val buffer = ByteArray(cap + 1)
                var read = 0
                while (read < buffer.size) {
                    val n = stream.read(buffer, read, buffer.size - read)
                    if (n < 0) break
                    read += n
                }
                buffer.copyOf(read)
            }
        } catch (_: IOException) {
            throw Refused(PERSISTENCE)
        }
        val truncated = bytes.size > cap
        val kept = if (truncated) bytes.copyOf(cap) else bytes
        val content = String(kept, Charsets.UTF_8)
        val source = revision(file)
        // A truncated read carries no digest: the bytes it reports are not the
        // bytes of the file, and the contract refuses a sha256 beside them.
        val payload = JSONObject().put("schema_version", 1).put("content", content)
            .put("revision", source).put("truncated", truncated)
        if (!truncated) payload.put("sha256", sha256(kept))
        val feedback = feedbackOrNull("read_file", payload) ?: throw Refused(PERSISTENCE)
        return effect(
            feedback,
            JSONObject().put("schema_version", 1).put("kind", "read_file")
                .put("source_revision", source),
            truncated,
            mayHaveOccurred = false,
        )
    }

    private fun writeFile(root: File, arguments: JSONObject): JSONObject {
        if (arguments.keys().asSequence().toSet() != setOf("path", "content")) throw Refused(INVALID)
        val content = arguments.opt("content")
        if (content !is String) throw Refused(INVALID)
        val file = resolve(root, components(path(arguments), allowRoot = false))
        if (file.exists() && !file.isFile) throw Refused(CONFLICT)
        val parent = file.parentFile ?: throw Refused(INVALID)
        if (!parent.isDirectory && !parent.mkdirs()) throw Refused(PERSISTENCE)
        // Written beside the target and renamed, so a crash leaves the old
        // file rather than half of the new one.
        val staging = File(parent, "${file.name}.rish-staging")
        try {
            staging.outputStream().use { out ->
                out.write(content.toByteArray(Charsets.UTF_8))
                out.fd.sync()
            }
            if (!staging.renameTo(file)) {
                staging.delete()
                throw Refused(PERSISTENCE)
            }
        } catch (_: IOException) {
            staging.delete()
            throw Refused(PERSISTENCE)
        }
        val bytes = content.toByteArray(Charsets.UTF_8)
        val actual = revision(file)
        val digest = sha256(bytes)
        val feedback = feedbackOrNull(
            "write_file",
            JSONObject().put("schema_version", 1).put("bytes", bytes.size)
                .put("revision", actual).put("sha256", digest),
        ) ?: throw Refused(PERSISTENCE)
        // The write happened; whatever comes next, a retry must not assume it
        // did not.
        return effect(
            feedback,
            JSONObject().put("schema_version", 1).put("kind", "write_file")
                .put("actual_revision", actual)
                .put("content_sha256", RishAgentCoreNative.hashBytes("file-content", bytes)),
            truncated = false,
            mayHaveOccurred = true,
        )
    }

    private fun listDir(root: File, arguments: JSONObject): JSONObject {
        val keys = arguments.keys().asSequence().toSet()
        if (keys.isNotEmpty() && keys != setOf("path")) throw Refused(INVALID)
        val requested = if (keys.isEmpty()) "" else path(arguments)
        val directory = resolve(root, components(requested, allowRoot = true))
        if (!directory.isDirectory) throw Refused(NOT_FOUND)
        val listed = listing(directory)
        val entries = listed.optJSONArray("entries") ?: throw Refused(PERSISTENCE)
        // A listing that will not fit the feedback cap drops its last entries
        // and says so, rather than failing the call: the model is better served
        // by a truncated listing than by nothing. The core decides what fits.
        var visible = entries
        var truncated = false
        while (true) {
            val payload = JSONObject().put("schema_version", 1)
                .put("entries", visible).put("truncated", truncated)
            val feedback = feedbackOrNull("list_dir", payload)
            if (feedback != null) {
                return effect(
                    feedback,
                    JSONObject().put("schema_version", 1).put("kind", "list_dir")
                        .put(
                            "directory_fingerprint_sha256",
                            listed.optString("directory_fingerprint_sha256"),
                        ),
                    truncated,
                    mayHaveOccurred = false,
                )
            }
            if (visible.length() == 0) throw Refused(PERSISTENCE)
            val shorter = JSONArray()
            for (index in 0 until visible.length() - 1) shorter.put(visible.get(index))
            visible = shorter
            truncated = true
        }
    }

    private companion object {
        const val INVALID = "E_AGENT_BAD_ARGUMENTS"
        const val CONFLICT = "E_AGENT_CONFLICT"
        const val NOT_FOUND = "E_AGENT_NOT_FOUND"
        const val PERSISTENCE = "E_AGENT_PERSISTENCE"
    }
}
