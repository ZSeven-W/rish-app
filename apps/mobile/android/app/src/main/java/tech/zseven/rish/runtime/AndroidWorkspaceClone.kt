package tech.zseven.rish.runtime

import android.content.Context
import org.json.JSONObject
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption

/**
 * `cloneWorkspaceV2`: a public HTTPS repository becomes a new Rish-owned
 * workspace with a project attached, the way iOS's public clone becomes a
 * project. The network runs first, into a private staging pair (gitdir and
 * working tree) nothing else knows about; only a clone that finished is
 * given a workspace, an attached project, and then its files. A failure or
 * a cancel before that point leaves nothing but a staging directory to
 * delete, which is what this does -- there is no workspace to unmake,
 * because none was made.
 */
internal class AndroidWorkspaceClone(
    context: Context,
    private val workspaces: AndroidWorkspaceRegistry,
    private val projects: AndroidWorkspaceProjects,
) {
    private val staging = File(context.applicationContext.noBackupFilesDir, "clone-staging")

    fun clone(rawRequest: JSONObject?): JSONObject {
        val request = rawRequest ?: throw refused(REQUEST_INVALID, "clone request is missing")
        if (request.keys().asSequence().toSet() != CLONE_KEYS || request.opt("schema_version") != 1) {
            throw refused(REQUEST_INVALID, "clone request is invalid")
        }
        val operationId = request.opt("operation_id") as? String
        val displayName = (request.opt("display_name") as? String)?.trim()
        val url = AndroidGitRemoteUrl.validated(request.opt("url"))
        if (operationId == null || !projects.canonicalOperationId(operationId) || url == null ||
            displayName.isNullOrEmpty() || displayName.length > 120 || displayName.any { it.isISOControl() }
        ) {
            throw refused(REQUEST_INVALID, "clone request is invalid")
        }
        if (!RishLibgit2Native.require()) throw refused(UNAVAILABLE, "libgit2 is not available")

        // The network half, in staging.
        val area = File(staging, operationId)
        if (area.exists()) throw refused(OPERATION_CONFLICT, "clone operation conflicts")
        val stagedGit = File(area, "git")
        val stagedWork = File(area, "work")
        if (!stagedWork.mkdirs()) throw refused(STORAGE, "clone staging cannot be created")
        val outcome = try {
            if (RishLibgit2Native.initSplitRepository(stagedGit.absolutePath, stagedWork.absolutePath) != "ok") {
                throw refused(STORAGE, "clone staging cannot be initialised")
            }
            if (RishLibgit2Native.setRemote(stagedGit.absolutePath, stagedWork.absolutePath, url) != "ok") {
                throw refused(STORAGE, "clone origin cannot be set")
            }
            val reply = JSONObject(
                String(RishLibgit2Native.cloneCheckout(stagedGit.absolutePath, stagedWork.absolutePath, operationId, TIMEOUT_SECONDS), Charsets.UTF_8),
            )
            if (!reply.optBoolean("ok")) throw refused(reply.optInt("code", NATIVE), "clone ${reply.optString("stage")} failed")
            reply
        } catch (failure: Throwable) {
            area.deleteRecursively()
            throw failure
        }
        when (outcome.optString("outcome")) {
            "success" -> Unit
            else -> {
                area.deleteRecursively()
                throw refused(
                    when (outcome.optString("outcome")) {
                        "auth_failure" -> AUTH_REJECTED
                        "timed_out" -> TIMED_OUT
                        "cancelled" -> CANCELLED
                        "empty" -> REMOTE_MISSING
                        else -> NATIVE
                    },
                    "clone ${outcome.optString("outcome")}",
                )
            }
        }
        val branch = outcome.getString("branch")
        val oid = outcome.getString("oid")

        // The workspace and its project, then the files. From here on every
        // step is local; the staging area is removed only once the project
        // reads back as what the clone produced.
        val workspace = workspaces.create(displayName)
        val workspaceId = workspace.getString("workspace_id")
        val root = JSONObject().put("schema_version", 1).put("workspace_id", workspaceId)
            .put("binding_revision", workspace.get("binding_revision")).put("project_id", JSONObject.NULL)
        val attached = projects.attach(
            JSONObject().put("schema_version", 1).put("operation_id", operationId).put("mode", "init").put("root", root),
        )
        val project = attached.getJSONObject("project")
        val projectId = project.getString("project_id")
        val gitDir = projects.gitDirectory(workspaceId, projectId)
        val workDir = workspaces.rootFor(workspaceId) ?: throw refused(STORAGE, "workspace root is unavailable")
        try {
            moveChildren(stagedWork, workDir)
            // The attached gitdir is the clone's gitdir now, binding kept.
            for (child in gitDir.listFiles() ?: emptyArray()) {
                if (child.name != BINDING_NAME) child.deleteRecursively()
            }
            moveChildren(stagedGit, gitDir)
            val status = JSONObject(String(RishLibgit2Native.status(gitDir.absolutePath, workDir.absolutePath), Charsets.UTF_8))
            if (!status.optBoolean("ok") || status.opt("branch") != branch || status.opt("head_oid") != oid || !status.optBoolean("clean")) {
                throw refused(NATIVE, "cloned project does not read back")
            }
        } finally {
            area.deleteRecursively()
        }
        val attachedRoot = JSONObject(root.toString()).put("project_id", projectId)
        return JSONObject().put("schema_version", 2).put("root", attachedRoot).put("project", project)
            .put("workspace", JSONObject().put("workspace_id", workspaceId).put("display_name", workspace.getString("display_name")))
            .put("branch", branch).put("oid", oid)
    }

    /** `cancelWorkspaceCloneV2`: asks a running clone to stop at its next callback. */
    fun cancel(rawRequest: JSONObject?): JSONObject {
        val request = rawRequest ?: throw refused(REQUEST_INVALID, "cancel request is missing")
        if (request.keys().asSequence().toSet() != CANCEL_KEYS || request.opt("schema_version") != 1) {
            throw refused(REQUEST_INVALID, "cancel request is invalid")
        }
        val operationId = request.opt("operation_id") as? String
        if (operationId == null || !projects.canonicalOperationId(operationId)) throw refused(REQUEST_INVALID, "cancel request is invalid")
        val running = RishLibgit2Native.cancelPush(operationId)
        return JSONObject().put("schema_version", 2).put("operation_id", operationId)
            .put("status", if (running) "cancel_requested" else "not_running")
    }

    private fun moveChildren(from: File, into: File) {
        for (child in from.listFiles() ?: emptyArray()) {
            val target = File(into, child.name)
            if (target.exists()) target.deleteRecursively()
            try {
                Files.move(child.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE)
            } catch (_: Exception) {
                if (!child.copyRecursively(target, overwrite = true)) throw refused(STORAGE, "cloned files cannot be moved into place")
                child.deleteRecursively()
            }
        }
    }

    private fun refused(number: Int, reason: String) = AndroidWorkspaceProjects.Refused(number, reason)

    private companion object {
        val CLONE_KEYS = setOf("schema_version", "operation_id", "url", "display_name")
        val CANCEL_KEYS = setOf("schema_version", "operation_id")
        const val BINDING_NAME = "binding-v2.json"
        const val TIMEOUT_SECONDS = 300
        const val REQUEST_INVALID = 3101
        const val UNAVAILABLE = 3102
        const val STORAGE = 3104
        const val OPERATION_CONFLICT = 3106
        const val REMOTE_MISSING = 3112
        const val CANCELLED = 3195
        const val AUTH_REJECTED = 3197
        const val TIMED_OUT = 3198
        const val NATIVE = 3199
    }
}
