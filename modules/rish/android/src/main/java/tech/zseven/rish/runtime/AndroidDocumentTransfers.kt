package tech.zseven.rish.runtime

import android.content.ContentResolver
import android.net.Uri
import android.provider.OpenableColumns
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException

/**
 * Bringing documents into a workspace, and sending them back out.
 *
 * An import is two steps on purpose. Every picked document is copied into a
 * staging directory first, and only when they are all there do they move into
 * the workspace. The bytes are local before anything is committed, so a
 * process that dies halfway leaves an operation that can be *finished*
 * rather than one that has to be picked again -- which is what the
 * `needs_recovery` status is for, and why `retry` needs no picker.
 *
 * An export has no such state. It writes through a URI the person chose,
 * outside anything this app owns, so there is nothing here to recover and
 * the operation is committed or it never happened.
 */
internal class AndroidDocumentTransfers(
    private val home: File,
    private val files: AndroidWorkspaceFiles,
    private val workspaces: AndroidWorkspaceRegistry,
    private val roots: AndroidAgentRootResolver,
) {

    class Refused(val code: String, val reason: String) : Exception(reason)

    /** Opens an operation before a picker is shown, so a crash is visible. */
    fun begin(operationId: String, kind: String, destination: String?): File {
        if (!UUID_PATTERN.matches(operationId)) {
            throw Refused(INVALID, "Operation id is invalid")
        }
        val record = record(operationId)
        if (record.isFile) {
            // Re-opening an operation that is already under way is the
            // caller repeating itself, not a second operation.
            return staging(operationId)
        }
        write(
            operationId,
            JSONObject()
                .put("operation_id", operationId)
                .put("kind", kind)
                .put("status", "in_progress")
                .put("destination_path", destination ?: JSONObject.NULL)
                .put("entries", JSONArray()),
        )
        val staging = staging(operationId)
        if (!staging.isDirectory && !staging.mkdirs()) {
            throw Refused(PERSISTENCE, "The import could not be staged")
        }
        return staging
    }

    /** Copies one picked document into the operation's staging directory. */
    fun stage(resolver: ContentResolver, uri: Uri, staging: File): JSONObject? {
        val name = displayName(resolver, uri) ?: return null
        if (!safeName(name)) return null
        val target = File(staging, name)
        val bytes = try {
            resolver.openInputStream(uri).use { input ->
                input ?: return null
                target.outputStream().use { output -> input.copyTo(output) }
            }
        } catch (_: IOException) {
            target.delete()
            throw Refused(PERSISTENCE, "That document could not be read")
        } catch (_: SecurityException) {
            target.delete()
            return null
        }
        if (bytes <= 0L) {
            target.delete()
            return null
        }
        return JSONObject().put("name", name).put("size", bytes)
    }

    /**
     * Moves everything staged into the workspace and closes the operation.
     *
     * A name already taken in the destination is not overwritten; the import
     * keeps the document under a numbered name beside it, because the person
     * asked for both files to exist.
     */
    fun commit(operationId: String, root: JSONObject, destination: String): JSONObject {
        val directory = directory(root, destination)
        val staging = staging(operationId)
        val staged = staging.listFiles()?.sortedBy { it.name } ?: emptyList()
        val entries = JSONArray()
        for (file in staged) {
            val target = free(directory, file.name)
            if (!file.renameTo(target)) {
                throw Refused(PERSISTENCE, "That document could not be imported")
            }
            entries.put(
                JSONObject()
                    .put("path", join(destination, target.name))
                    .put("kind", "file")
                    .put("size", target.length()),
            )
        }
        staging.deleteRecursively()
        write(
            operationId,
            JSONObject()
                .put("operation_id", operationId)
                .put("kind", "import")
                .put("status", "committed")
                .put("destination_path", destination)
                .put("entries", entries),
        )
        return entries.let { JSONObject().put("entries", it) }
    }

    /** Closes an operation whose picker came back with nothing. */
    fun abandon(operationId: String) {
        staging(operationId).deleteRecursively()
        record(operationId).delete()
    }

    /** Records an export, which has nothing left behind to recover. */
    fun exported(operationId: String, count: Int) {
        write(
            operationId,
            JSONObject()
                .put("operation_id", operationId)
                .put("kind", "export")
                .put("status", "committed")
                .put("destination_path", JSONObject.NULL)
                .put("entries", JSONArray())
                .put("item_count", count),
        )
    }

    /**
     * `queryOperation`: where an operation stands.
     *
     * An operation whose record says it was under way but whose staging is
     * still on disk did not finish, and says so rather than claiming either
     * outcome.
     */
    fun query(operationId: String): JSONObject {
        if (!UUID_PATTERN.matches(operationId)) {
            throw Refused(INVALID, "Operation id is invalid")
        }
        val stored = read(operationId)
            ?: return JSONObject().put("schema_version", 1)
                .put("operation_id", operationId).put("status", "not_started")
        val status = stored.optString("status")
        // A record still saying `in_progress` is one nobody closed: either
        // the staging is still there to be finished, or the process died
        // between the move and the record. Both need looking at, and neither
        // may be reported as done.
        val reported =
            if (status == "in_progress") "needs_recovery" else status.ifEmpty { "not_started" }
        return JSONObject().put("schema_version", 1)
            .put("operation_id", operationId).put("status", reported)
    }

    /**
     * `retryOperation`: finish what was staged.
     *
     * The bytes are already here, so this needs no picker and no permission
     * that may since have been revoked.
     */
    fun retry(operationId: String, root: JSONObject): JSONObject {
        if (!UUID_PATTERN.matches(operationId)) {
            throw Refused(INVALID, "Operation id is invalid")
        }
        val stored = read(operationId) ?: throw Refused(NOT_FOUND, "No such operation")
        if (stored.optString("status") == "committed") return query(operationId)
        if (stored.optString("kind") != "import") {
            // An export wrote outside this app; there is nothing to resume.
            throw Refused(CONFLICT, "That operation cannot be resumed")
        }
        val destination = stored.opt("destination_path") as? String
            ?: throw Refused(CONFLICT, "That operation has no destination")
        commit(operationId, root, destination)
        return query(operationId)
    }

    /** `cleanupOperation`: forget it, staging and all. */
    fun cleanup(operationId: String): JSONObject {
        if (!UUID_PATTERN.matches(operationId)) {
            throw Refused(INVALID, "Operation id is invalid")
        }
        staging(operationId).deleteRecursively()
        val stored = read(operationId)
        if (stored != null) {
            write(operationId, stored.put("status", "cleaned"))
        }
        return JSONObject().put("schema_version", 1)
            .put("operation_id", operationId).put("status", "cleaned")
    }

    /** What a committed import put where, for the result the reader reads. */
    fun entries(operationId: String): JSONArray =
        read(operationId)?.optJSONArray("entries") ?: JSONArray()

    /** The workspace directory a root and a path name, or a refusal. */
    fun directory(root: JSONObject?, path: String): File {
        val reference = root ?: throw Refused(INVALID, "Workspace root is invalid")
        val workspaceId = reference.optString("workspace_id")
        if (workspaceId.isEmpty()) throw Refused(INVALID, "Workspace root is invalid")
        if (roots.resolveWorkspaceRef(reference) == null) {
            throw Refused(ROOT_CHANGED, "That workspace binding is not the one this device holds")
        }
        val base = workspaces.rootFor(workspaceId)
            ?: throw Refused(NOT_FOUND, "This device does not hold that workspace")
        val target = resolved(base, path)
        if (!target.isDirectory) throw Refused(NOT_FOUND, "No such directory")
        return target
    }

    /** One workspace file, for an export to read. */
    fun file(root: JSONObject?, path: String): File {
        val reference = root ?: throw Refused(INVALID, "Workspace root is invalid")
        val workspaceId = reference.optString("workspace_id")
        if (roots.resolveWorkspaceRef(reference) == null) {
            throw Refused(ROOT_CHANGED, "That workspace binding is not the one this device holds")
        }
        val base = workspaces.rootFor(workspaceId)
            ?: throw Refused(NOT_FOUND, "This device does not hold that workspace")
        val target = resolved(base, path)
        if (!target.isFile) throw Refused(NOT_FOUND, "No such file")
        return target
    }

    /**
     * The same containment rule the Files drawer keeps, reported in this
     * surface's own refusal. A path that leaves the workspace is a bad
     * request, and saying so as a storage failure would send the reader
     * looking in the wrong place.
     */
    private fun resolved(base: File, path: String): File = try {
        files.resolveForTransfer(base, path)
    } catch (refused: AndroidWorkspaceFiles.Refused) {
        throw Refused(refused.code, refused.reason)
    }

    private fun free(directory: File, name: String): File {
        val target = File(directory, name)
        if (!target.exists()) return target
        val stem = name.substringBeforeLast('.', name)
        val suffix = name.substringAfterLast('.', "").let { if (it.isEmpty()) "" else ".$it" }
        for (index in 2..MAX_NAME_ATTEMPTS) {
            val candidate = File(directory, "$stem ($index)$suffix")
            if (!candidate.exists()) return candidate
        }
        throw Refused(CONFLICT, "That name is already taken")
    }

    private fun displayName(resolver: ContentResolver, uri: Uri): String? = try {
        resolver.query(uri, null, null, null, null)?.use { cursor ->
            val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (index >= 0 && cursor.moveToFirst() && !cursor.isNull(index)) {
                cursor.getString(index)
            } else {
                null
            }
        }
    } catch (_: Exception) {
        null
    }

    /** A picked name becomes a file name here, so it may not be a path. */
    private fun safeName(name: String): Boolean =
        name.isNotBlank() &&
            name.length <= MAX_NAME_LENGTH &&
            !name.contains('/') &&
            !name.contains('\\') &&
            !name.contains(' ') &&
            name != "." &&
            name != ".."

    private fun join(path: String, name: String): String =
        if (path.isEmpty()) name else "$path/$name"

    private fun operations(): File {
        val directory = File(home, DIRECTORY)
        if (!directory.isDirectory && !directory.mkdirs()) {
            throw Refused(PERSISTENCE, "Transfer storage could not be opened")
        }
        return directory
    }

    private fun record(operationId: String) = File(operations(), "$operationId.json")

    private fun staging(operationId: String) = File(operations(), operationId)

    private fun read(operationId: String): JSONObject? {
        val file = record(operationId)
        if (!file.isFile) return null
        return try {
            JSONObject(file.readText())
        } catch (_: Exception) {
            null
        }
    }

    private fun write(operationId: String, value: JSONObject) {
        try {
            record(operationId).writeText(value.toString())
        } catch (_: IOException) {
            throw Refused(PERSISTENCE, "The operation could not be recorded")
        }
    }

    private companion object {
        val UUID_PATTERN =
            Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
        const val DIRECTORY = "documents"
        const val MAX_NAME_LENGTH = 255
        const val MAX_NAME_ATTEMPTS = 99
        const val INVALID = "E_WORKSPACE_INVALID"
        const val NOT_FOUND = "E_WORKSPACE_NOT_FOUND"
        const val CONFLICT = "E_WORKSPACE_CONFLICT"
        const val PERSISTENCE = "E_WORKSPACE_PERSISTENCE"
        const val ROOT_CHANGED = "E_WORKSPACE_ROOT_CHANGED"
    }
}
