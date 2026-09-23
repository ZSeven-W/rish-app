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
    private val credentials: AndroidGitCredentials? = null,
) {
    private val staging = File(context.applicationContext.noBackupFilesDir, "clone-staging")

    /**
     * A credential the person typed for one clone, held until that clone
     * runs. It is keyed by the operation id the prompt was presented for and
     * bound to the host of the URL the prompt named; it never crosses the
     * bridge, and it is forgotten when the clone finishes either way, or
     * after five minutes unused. A clone that succeeded stores it for the
     * new project and origin's host, so fetch and push find it later.
     */
    private class Offered(val host: String, val username: String, val token: String, val expirySeconds: Long, val until: Long)
    private val offered = HashMap<String, Offered>()

    /**
     * `presentCloneCredentialPromptV2`, before the prompt: what the dialog
     * says -- the host, and whether the URL is plain HTTP.
     */
    fun promptScope(rawRequest: JSONObject?): JSONObject {
        val request = rawRequest ?: throw refused(REQUEST_INVALID, "prompt request is missing")
        if (request.keys().asSequence().toSet() != PROMPT_KEYS || request.opt("schema_version") != 1) {
            throw refused(REQUEST_INVALID, "prompt request is invalid")
        }
        val operationId = request.opt("operation_id") as? String
        val url = AndroidGitRemoteUrl.validated(request.opt("url"))
        val locale = request.opt("locale") as? String
        if (operationId == null || !projects.canonicalOperationId(operationId) || url == null || (locale != "zh-CN" && locale != "en")) {
            throw refused(REQUEST_INVALID, "prompt request is invalid")
        }
        if (credentials == null) throw refused(UNAVAILABLE, "credentials are unavailable")
        return JSONObject().put("operation_id", operationId).put("host", AndroidGitRemoteUrl.hostOf(url))
            .put("plaintext", url.startsWith("http://")).put("chinese", locale == "zh-CN")
    }

    /** What the person typed, kept for the clone that carries this operation id. */
    fun offerCredential(operationId: String, host: String, username: String, token: String, expirySeconds: Long): JSONObject {
        if (!projects.canonicalOperationId(operationId) || !AndroidGitCredentials.validHost(host) ||
            username.isEmpty() || token.isEmpty() || expirySeconds !in AndroidGitCredentials.EXPIRIES
        ) {
            throw refused(REQUEST_INVALID, "credential is invalid")
        }
        synchronized(offered) {
            sweepOffered()
            offered[operationId] = Offered(host, username, token, expirySeconds, System.currentTimeMillis() + OFFER_TTL_MS)
        }
        return JSONObject().put("schema_version", 2).put("operation_id", operationId).put("host", host)
            .put("expiry_seconds", expirySeconds)
    }

    private fun takeOffered(operationId: String): Offered? = synchronized(offered) {
        sweepOffered()
        offered.remove(operationId)
    }

    private fun sweepOffered() {
        val now = System.currentTimeMillis()
        offered.entries.removeAll { it.value.until <= now }
    }

    fun clone(rawRequest: JSONObject?): JSONObject {
        val request = rawRequest ?: throw refused(REQUEST_INVALID, "clone request is missing")
        val keys = request.keys().asSequence().toSet()
        if ((keys != CLONE_KEYS && keys != CLONE_KEYS + "credential_reference") || request.opt("schema_version") != 1) {
            throw refused(REQUEST_INVALID, "clone request is invalid")
        }
        val operationId = request.opt("operation_id") as? String
        val displayName = (request.opt("display_name") as? String)?.trim()
        val url = AndroidGitRemoteUrl.validated(request.opt("url"))
        val reference = if (request.has("credential_reference")) request.opt("credential_reference") else "none"
        if (operationId == null || !projects.canonicalOperationId(operationId) || url == null ||
            displayName.isNullOrEmpty() || displayName.length > 120 || displayName.any { it.isISOControl() } ||
            (reference != "none" && reference != "prompt")
        ) {
            throw refused(REQUEST_INVALID, "clone request is invalid")
        }
        val proxy = try {
            AndroidGitProxyUrl.canonical(request.opt("https_proxy_url"))
        } catch (_: AndroidGitProxyUrl.Invalid) {
            throw refused(REQUEST_INVALID, "https proxy url is invalid")
        }
        // libgit2 would send a plain http remote straight past the proxy.
        if (!AndroidGitProxyUrl.usableWith(proxy, url)) throw refused(REQUEST_INVALID, "a proxy cannot carry a plain http remote")
        if (!RishLibgit2Native.require()) throw refused(UNAVAILABLE, "libgit2 is not available")
        // The credential the person typed for this very clone, if any. It is
        // taken now, so a clone that fails does not leave it for another.
        val host = AndroidGitRemoteUrl.hostOf(url)
        val credential = if (reference == "prompt") {
            takeOffered(operationId)?.takeIf { it.host == host } ?: throw refused(AUTH_REJECTED, "no credential was offered for this clone")
        } else {
            null
        }

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
                String(
                    RishLibgit2Native.cloneCheckout(
                        stagedGit.absolutePath, stagedWork.absolutePath, operationId, host,
                        credential?.username ?: "", credential?.token ?: "", TIMEOUT_SECONDS, proxy ?: "",
                    ),
                    Charsets.UTF_8,
                ),
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
                        "proxy_failed" -> PROXY_FAILED
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
        // The credential that cloned it is the project's now, for the host
        // it was typed for, so a later fetch or push does not ask again.
        if (credential != null) {
            try {
                credentials?.store(projectId, host, credential.username, credential.token, credential.expirySeconds)
            } catch (_: IllegalArgumentException) {
                // The expiry was checked at the offer; a store that refuses it
                // now leaves the clone intact and the credential unsaved.
            }
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
        val CLONE_KEYS = setOf("schema_version", "operation_id", "url", "display_name", "https_proxy_url")
        val PROMPT_KEYS = setOf("schema_version", "operation_id", "url", "locale")
        val CANCEL_KEYS = setOf("schema_version", "operation_id")
        const val OFFER_TTL_MS = 5L * 60 * 1000
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
        /** The person's proxy refused, failed or could not be reached. */
        const val PROXY_FAILED = 3182
    }
}
