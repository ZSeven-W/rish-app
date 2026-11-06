package tech.zseven.rish.runtime

import android.system.OsConstants
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.UUID

/**
 * The Files browser's view of a workspace, on Android.
 *
 * This is `LocalWorkspace` -- what the drawer lists and opens -- and not the
 * agent's tools, which have their own gate in [AndroidWorkspaceToolExecutor].
 * The two share the rules that decide identity rather than duplicating them:
 * a path is decomposed by the core's `path_components`, and which directory a
 * root names is the resolver's answer. What a person browses and what the
 * agent writes are therefore the same bytes, under the same containment
 * rules; only the spelling of a revision differs, because this bridge's
 * reader requires a digest where the agent's tools carry opaque metadata.
 *
 * **What is here.** Listing, reading, writing, creating directories,
 * renaming, and a recoverable trash. Portable tools and the capability
 * record still reject: the record asserts a tool set this platform does not
 * have, and asserting it would be a claim rather than an answer.
 */
internal class AndroidWorkspaceFiles(
    private val workspaces: AndroidWorkspaceRegistry,
    private val roots: AndroidAgentRootResolver,
) {

    class Refused(val code: String, val reason: String) : Exception(reason)

    /** `listV2`: one directory, sorted, capped by the request. */
    fun list(request: JSONObject?): JSONObject {
        val captured = exact(request, "schema_version", "root", "path", "max_entries")
        val root = directory(captured)
        val path = captured.optString("path")
        val max = integer(captured, "max_entries")
        if (max < 1 || max > MAX_LIST_ENTRIES) throw Refused(INVALID, "max_entries is out of range")
        val target = resolve(root, path, allowRoot = true)
        if (!target.isDirectory) throw Refused(NOT_FOUND, "No such directory")
        val children = target.listFiles() ?: throw Refused(PERSISTENCE, "Directory could not be read")
        val entries = JSONArray()
        children.sortedBy { it.name }
            // Links and special files are not safe editing targets, even
            // when a link currently points back into this workspace.
            .filter { !isLink(it) }
            // The trash and a half-written file are this store's bookkeeping,
            // not the person's files. `.git` stays visible: the reader knows
            // about it and protects it itself.
            .filter { !hidden(path, it.name) }
            .take(max)
            .forEach { entries.put(entry(root, it, join(path, it.name))) }
        return JSONObject()
            .put("schema_version", 1)
            .put("root", captured.getJSONObject("root"))
            .put("path", path)
            .put("entries", entries)
    }

    /** `readV2`: one text file, refused rather than truncated. */
    fun read(request: JSONObject?): JSONObject {
        val captured = exact(request, "schema_version", "root", "path", "max_bytes")
        val root = directory(captured)
        val path = captured.optString("path")
        val max = integer(captured, "max_bytes")
        if (max < 1 || max > MAX_TEXT_BYTES) throw Refused(INVALID, "max_bytes is out of range")
        resolve(root, path, allowRoot = false)
        val snapshot = AndroidWorkspaceFileIo.Parent.open(root, path).use {
            it.snapshot(max, requireContent = true)
                ?: throw Refused(NOT_FOUND, "No such file")
        }
        return JSONObject()
            .put("schema_version", 1)
            .put("root", captured.getJSONObject("root"))
            .put("path", path)
            .put("file", fileEntry(root, path, snapshot))
            .put("content", text(snapshot.bytes!!))
    }

    /**
     * `writeV2`: one text file, atomically, against the revision the caller
     * last saw.
     */
    fun write(request: JSONObject?): JSONObject = mutation(request) { writeHeld(request) }

    private fun writeHeld(request: JSONObject?): JSONObject {
        val captured = exact(
            request, "schema_version", "root", "path", "content", "expected_revision", "create_only",
        )
        val root = directory(captured, writing = true)
        val path = captured.optString("path")
        val content = captured.opt("content") as? String
            ?: throw Refused(INVALID, "Content must be text")
        val encoded = try {
            Charsets.UTF_8.newEncoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT).encode(java.nio.CharBuffer.wrap(content))
        } catch (_: CharacterCodingException) {
            throw Refused(INVALID, "Content must be valid text")
        }
        val bytes = ByteArray(encoded.remaining()).also { encoded.get(it) }
        if (bytes.size > MAX_TEXT_BYTES) {
            throw Refused(INVALID, "Content is larger than a workspace file may be")
        }
        val rawExpected = captured.opt("expected_revision")
        val expected = when (rawExpected) {
            JSONObject.NULL -> null
            is String -> rawExpected.takeIf { REVISION_PATTERN.matches(it) }
                ?: throw Refused(INVALID, "Expected revision is invalid")
            else -> throw Refused(INVALID, "Expected revision is invalid")
        }
        val createOnly = captured.opt("create_only") as? Boolean
            ?: throw Refused(INVALID, "create_only must be a boolean")
        resolve(root, path, allowRoot = false)
        val (snapshot, created) = AndroidWorkspaceFileIo.Parent.open(root, path).use {
            it.write(bytes, expected, createOnly)
        }
        return JSONObject()
            .put("schema_version", 1)
            .put("root", captured.getJSONObject("root"))
            .put("file", fileEntry(root, path, snapshot))
            .put("created", created)
    }

    /** `createDirectoryV2`: one directory, where nothing is yet. */
    fun createDirectory(request: JSONObject?): JSONObject = mutation(request) { createDirectoryHeld(request) }

    private fun createDirectoryHeld(request: JSONObject?): JSONObject {
        val captured = exact(request, "schema_version", "root", "path")
        val root = directory(captured, writing = true)
        val path = captured.optString("path")
        val target = resolve(root, path, allowRoot = false)
        AndroidWorkspaceFileIo.Parent.open(root, path).use { it.createDirectory() }
        return JSONObject()
            .put("schema_version", 1)
            .put("root", captured.getJSONObject("root"))
            .put("directory", entry(root, target, path))
    }

    /** `renameEntryV2`: a move within the workspace, never over something. */
    fun rename(request: JSONObject?): JSONObject = mutation(request) { renameHeld(request) }

    private fun renameHeld(request: JSONObject?): JSONObject {
        val captured = exact(request, "schema_version", "root", "source_path", "destination_path")
        val root = directory(captured, writing = true)
        val from = captured.optString("source_path")
        val to = captured.optString("destination_path")
        if (from == to) throw Refused(INVALID, "Source and destination are the same")
        val source = resolve(root, from, allowRoot = false)
        val destination = resolve(root, to, allowRoot = false)
        if (!source.exists()) throw Refused(NOT_FOUND, "No such file or directory")
        if (destination.exists()) throw Refused(CONFLICT, "Something already exists at that path")
        // Moving a directory into itself leaves it unreachable, and the
        // rename would appear to succeed.
        if (source.isDirectory && destination.canonicalPath.startsWith(source.canonicalPath + File.separator)) {
            throw Refused(CONFLICT, "A folder cannot be moved into itself")
        }
        val parent = destination.parentFile ?: throw Refused(INVALID, "Path is invalid")
        if (!parent.isDirectory) throw Refused(NOT_FOUND, "No such directory")
        if (!source.renameTo(destination)) throw Refused(PERSISTENCE, "Entry could not be renamed")
        return JSONObject()
            .put("schema_version", 1)
            .put("root", captured.getJSONObject("root"))
            .put("entry", entry(root, destination, to))
            .put("from", from)
    }

    /**
     * `trashEntryV2`: recoverable deletion.
     *
     * The entry is moved whole into `.trash/<trash_id>/payload/`, beside a
     * receipt that remembers where it came from. Nothing is unlinked, so a
     * restore is a move back rather than a rebuild, and a trash that cannot
     * be read is reported as a count rather than pretended away.
     */
    fun trash(request: JSONObject?): JSONObject = mutation(request) { trashHeld(request) }

    private fun trashHeld(request: JSONObject?): JSONObject {
        val captured = exact(request, "schema_version", "root", "path")
        val root = directory(captured, writing = true)
        val path = captured.optString("path")
        val target = resolve(root, path, allowRoot = false)
        if (!target.exists()) throw Refused(NOT_FOUND, "No such file or directory")
        if (isLink(target)) throw Refused(CONFLICT, "That entry is a link")
        val kind = if (target.isDirectory) "directory" else "file"
        val trashId = UUID.randomUUID().toString()
        val holder = File(trashRoot(root), trashId)
        val payload = File(holder, PAYLOAD)
        if (!payload.mkdirs()) throw Refused(PERSISTENCE, "Trash could not be written")
        val receipt = JSONObject()
            .put("schema_version", 1)
            .put("trash_id", trashId)
            .put("original_path", path)
            .put("kind", kind)
            .put("deleted_at", AndroidClock.now())
        // The receipt lands first: an entry with a payload and no receipt is
        // unrecoverable, while a receipt with no payload is merely reported
        // as an unreadable record.
        try {
            File(holder, RECEIPT).writeText(receipt.toString())
        } catch (_: IOException) {
            holder.deleteRecursively()
            throw Refused(PERSISTENCE, "Trash could not be written")
        }
        if (!target.renameTo(File(payload, target.name))) {
            holder.deleteRecursively()
            throw Refused(PERSISTENCE, "Entry could not be moved to the trash")
        }
        return JSONObject()
            .put("schema_version", 1)
            .put("root", captured.getJSONObject("root"))
            .put("receipt", receipt)
    }

    /** `listTrashV2`: the receipts, newest first, and how many were unreadable. */
    fun listTrash(request: JSONObject?): JSONObject {
        val captured = exact(request, "schema_version", "root", "max_entries")
        val root = directory(captured)
        val max = integer(captured, "max_entries")
        if (max < 1 || max > MAX_LIST_ENTRIES) throw Refused(INVALID, "max_entries is out of range")
        val holders = trashRoot(root).listFiles()?.filter { it.isDirectory } ?: emptyList()
        var invalid = 0
        val receipts = mutableListOf<JSONObject>()
        for (holder in holders) {
            val receipt = readReceipt(holder)
            if (receipt == null || !File(holder, PAYLOAD).isDirectory) invalid += 1
            else receipts.add(receipt)
        }
        receipts.sortByDescending { it.optString("deleted_at") }
        val entries = JSONArray()
        receipts.take(max).forEach { entries.put(it) }
        return JSONObject()
            .put("schema_version", 1)
            .put("root", captured.getJSONObject("root"))
            .put("entries", entries)
            // Bounded by the same cap the entries are: this is a hint for the
            // reader, not a census.
            .put("invalid_record_count", minOf(invalid, max))
    }

    /** `restoreFromTrashV2`: the move back, refused rather than overwriting. */
    fun restore(request: JSONObject?): JSONObject = mutation(request) { restoreHeld(request) }

    private fun restoreHeld(request: JSONObject?): JSONObject {
        val captured = exact(request, "schema_version", "root", "trash_id", "destination_path")
        val root = directory(captured, writing = true)
        val trashId = captured.opt("trash_id") as? String
            ?: throw Refused(INVALID, "trash_id is invalid")
        if (!UUID_PATTERN.matches(trashId)) throw Refused(INVALID, "trash_id is invalid")
        val holder = File(trashRoot(root), trashId)
        val receipt = readReceipt(holder) ?: throw Refused(NOT_FOUND, "No such trashed entry")
        val payload = File(holder, PAYLOAD).listFiles()?.firstOrNull()
            ?: throw Refused(NOT_FOUND, "That trashed entry has no contents")
        val requested = captured.opt("destination_path")?.takeIf { it != JSONObject.NULL } as? String
        val path = requested ?: receipt.optString("original_path")
        val target = resolve(root, path, allowRoot = false)
        if (target.exists()) throw Refused(CONFLICT, "Something already exists at that path")
        val parent = target.parentFile ?: throw Refused(INVALID, "Path is invalid")
        if (!parent.isDirectory) throw Refused(NOT_FOUND, "No such directory")
        if (!payload.renameTo(target)) throw Refused(PERSISTENCE, "Entry could not be restored")
        // The holder is bookkeeping; if it survives the restore it is listed
        // as an unreadable record rather than offered again.
        holder.deleteRecursively()
        return JSONObject()
            .put("schema_version", 1)
            .put("root", captured.getJSONObject("root"))
            .put("entry", entry(root, target, path))
            .put("trash_id", trashId)
            .put("original_path", receipt.optString("original_path"))
    }

    private fun trashRoot(root: File): File {
        val trash = File(root, TRASH)
        if (!trash.isDirectory && !trash.mkdirs()) {
            throw Refused(PERSISTENCE, "Trash could not be opened")
        }
        return trash
    }

    private fun readReceipt(holder: File): JSONObject? {
        val file = File(holder, RECEIPT)
        if (!file.isFile) return null
        return try {
            val receipt = JSONObject(file.readText())
            // A receipt that does not name this holder is not this holder's.
            if (receipt.optString("trash_id") != holder.name) null else receipt
        } catch (_: Exception) {
            null
        }
    }

    private fun hidden(@Suppress("UNUSED_PARAMETER") path: String, name: String): Boolean =
        name == TRASH || name.endsWith(".rish-staging")

    private fun exact(request: JSONObject?, vararg keys: String): JSONObject {
        val captured = request ?: throw Refused(INVALID, "Workspace request is missing")
        if (captured.keys().asSequence().toSet() != keys.toSet()) {
            throw Refused(INVALID, "Workspace request is invalid")
        }
        if (integer(captured, "schema_version") != 1) {
            throw Refused(INVALID, "Workspace request is invalid")
        }
        return captured
    }

    /**
     * Numbers cross the bridge as `Double`, so every integer is read through
     * `Number` rather than cast -- the same trap that made every agent root
     * fail to resolve in production while the tests stayed green.
     */
    private fun integer(value: JSONObject, key: String): Int =
        when (val raw = value.opt(key)) {
            is Number -> raw.toDouble().let { number ->
                if (!number.isFinite() || number % 1.0 != 0.0 ||
                    number < Int.MIN_VALUE || number > Int.MAX_VALUE
                ) throw Refused(INVALID, "$key must be an integer")
                number.toInt()
            }
            else -> throw Refused(INVALID, "$key must be a number")
        }

    /** Which directory this root names, or why it does not name one. */
    private fun directory(request: JSONObject, writing: Boolean = false): File {
        val reference = request.optJSONObject("root")
            ?: throw Refused(INVALID, "Workspace root is invalid")
        val workspaceId = reference.optString("workspace_id")
        if (workspaceId.isEmpty()) throw Refused(INVALID, "Workspace root is invalid")
        val known = workspaces.list().firstOrNull { it.optString("workspace_id") == workspaceId }
            ?: throw Refused(NOT_FOUND, "This device does not hold that workspace")
        // A binding revision this device does not hold is a root that moved,
        // not a malformed request.
        val resolved = roots.resolveWorkspaceRef(reference)
        if (resolved == null) {
            val held = known.opt("binding_revision")
            throw Refused(
                if (held == null) NOT_FOUND else ROOT_CHANGED,
                "That workspace binding is not the one this device holds",
            )
        }
        val capabilities = resolved.optJSONArray("capabilities") ?: JSONArray()
        val required = if (writing) "file_write" else "file_read"
        if ((0 until capabilities.length()).none { capabilities.optString(it) == required }) {
            throw Refused(CAPABILITY, "This workspace does not allow that operation")
        }
        return workspaces.rootFor(workspaceId)
            ?: throw Refused(NOT_FOUND, "This device does not hold that workspace")
    }

    /**
     * The same containment rule, for a transfer that needs a path resolved
     * without going through a request shape. Exposed rather than duplicated:
     * an import must land inside exactly the directories a listing shows.
     */
    fun resolveForTransfer(root: File, path: String): File =
        resolve(root, path, allowRoot = true)

    private fun resolve(root: File, path: String, allowRoot: Boolean): File {
        if (path.toByteArray(Charsets.UTF_8).size > MAX_PATH_BYTES) {
            throw Refused(INVALID, "Path is too long")
        }
        if (!RishAgentCoreNative.available) throw Refused(UNAVAILABLE, "Workspace rules are unavailable")
        val reply = RishAgentCoreNative.workspaceTool(
            JSONObject().put("op", "path_components").put("path", path)
                .put("allow_root", allowRoot),
        ) ?: throw Refused(INVALID, "Path is invalid")
        val components = reply.optJSONArray("components") ?: throw Refused(INVALID, "Path is invalid")
        var target = root
        val rootStat = AndroidWorkspaceFileIo.stat(root)
        if (rootStat == null || !OsConstants.S_ISDIR(rootStat.st_mode)) {
            throw Refused(ROOT_CHANGED, "That workspace root changed")
        }
        for (index in 0 until components.length()) {
            target = File(target, components.getString(index))
            val stat = AndroidWorkspaceFileIo.stat(target)
            if (stat != null && !AndroidWorkspaceFileIo.safeKind(stat)) {
                throw Refused(CONFLICT, "Links and special files are not supported")
            }
            if (index < components.length() - 1 && (stat == null || !OsConstants.S_ISDIR(stat.st_mode))) {
                throw Refused(NOT_FOUND, "No such directory")
            }
        }
        return target
    }

    private fun entry(root: File, file: File, path: String): JSONObject {
        val stat = AndroidWorkspaceFileIo.stat(file) ?: throw Refused(NOT_FOUND, "No such entry")
        val snapshot = if (OsConstants.S_ISDIR(stat.st_mode)) {
            AndroidWorkspaceFileIo.Snapshot(stat, null)
        } else {
            AndroidWorkspaceFileIo.Parent.open(root, path).use {
                it.snapshot() ?: throw Refused(NOT_FOUND, "No such file")
            }
        }
        return fileEntry(root, path, snapshot)
    }

    private fun fileEntry(root: File, path: String, snapshot: AndroidWorkspaceFileIo.Snapshot): JSONObject {
        val directory = OsConstants.S_ISDIR(snapshot.stat.st_mode)
        return JSONObject()
            .put("path", path)
            .put("name", if (path.isEmpty()) root.name else path.substringAfterLast('/'))
            .put("kind", if (directory) "directory" else "file")
            .put("size", if (directory) 0L else snapshot.stat.st_size)
            .put("modified_at", timestamp(snapshot.modifiedMillis))
            .put("revision", snapshot.revision)
    }

    /** Text or nothing: a file the reader cannot show is not half-shown. */
    private fun text(bytes: ByteArray): String {
        val decoder = Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
        return try {
            decoder.decode(java.nio.ByteBuffer.wrap(bytes)).toString()
        } catch (_: CharacterCodingException) {
            throw Refused(UNAVAILABLE, "This file is not text")
        }
    }

    /** Do not offer links or special files as editable entries. */
    private fun isLink(file: File): Boolean = try {
        AndroidWorkspaceFileIo.stat(file)?.let { !AndroidWorkspaceFileIo.safeKind(it) } ?: true
    } catch (_: Refused) {
        true
    }

    /** Serialize browser mutations and keep workspace removal from racing a save. */
    private fun <T> mutation(request: JSONObject?, body: () -> T): T {
        val workspaceId = request?.optJSONObject("root")?.optString("workspace_id")
        if (workspaceId == null || !RuntimeJson.uuid(workspaceId)) {
            throw Refused(INVALID, "Workspace root is invalid")
        }
        return try {
            workspaces.mutating(workspaceId, body)
        } catch (refused: AndroidWorkspaceRegistry.Refused) {
            throw Refused(refused.code, "This workspace is busy")
        }
    }

    private fun join(path: String, name: String): String =
        if (path.isEmpty()) name else "$path/$name"

    private fun timestamp(millis: Long): String = synchronized(format) {
        format.format(Date(millis))
    }

    private companion object {
        val REVISION_PATTERN = Regex("^[0-9a-f]{64}$")
        val format = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
            .apply { timeZone = TimeZone.getTimeZone("UTC") }
        val UUID_PATTERN =
            Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
        const val TRASH = ".trash"
        const val PAYLOAD = "payload"
        const val RECEIPT = "receipt.json"
        const val MAX_PATH_BYTES = 1024
        const val MAX_TEXT_BYTES = 1024 * 1024
        const val MAX_LIST_ENTRIES = 1000
        const val INVALID = "E_WORKSPACE_INVALID"
        const val NOT_FOUND = "E_WORKSPACE_NOT_FOUND"
        const val CONFLICT = "E_WORKSPACE_CONFLICT"
        const val PERSISTENCE = "E_WORKSPACE_PERSISTENCE"
        const val ROOT_CHANGED = "E_WORKSPACE_ROOT_CHANGED"
        const val UNAVAILABLE = "E_WORKSPACE_UNAVAILABLE"
        const val CAPABILITY = "E_WORKSPACE_CAPABILITY"
    }
}
