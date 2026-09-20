package tech.zseven.rish.runtime

import org.json.JSONObject

/**
 * The git panel over a workspace's project: `statusV2`, `diffV2`,
 * `stageAllV2`, `commitV2`.
 *
 * The rules are iOS's, request by request: the same keys, the same bounds on
 * a commit message and its author, the same HEAD expectation, the same error
 * numbers. What git itself reports is [RishLibgit2Native]'s; what this adds
 * is proving the root names a project this device holds before git is asked,
 * and stamping the answer with the root it was asked about.
 *
 * A refusal is [AndroidWorkspaceProjects.Refused], by iOS's number, so the
 * bridge reports both classes of failure through one mapping.
 */
internal class AndroidProjectGit(
    private val projects: AndroidWorkspaceProjects,
    private val workspaces: AndroidWorkspaceRegistry,
    /** Git HTTPS credentials by (project, host); null on a build that cannot push. */
    private val credentials: AndroidGitCredentials? = null,
) {
    private class Opened(val root: JSONObject, val projectId: String, val gitDir: String, val workDir: String)

    fun status(rawRequest: JSONObject?): JSONObject {
        val request = exact(rawRequest, WORKSPACE_KEYS)
        val opened = open(request, write = false)
        return stamped(answer(RishLibgit2Native.status(opened.gitDir, opened.workDir)), opened)
    }

    fun diff(rawRequest: JSONObject?): JSONObject {
        val request = exact(rawRequest, DIFF_KEYS)
        val maxBytes = request.opt("max_bytes")
        val limit = when (maxBytes) {
            is Int -> maxBytes.toLong()
            is Long -> maxBytes
            else -> throw refused(REQUEST_INVALID, "git diff request is invalid")
        }
        if (limit < 1 || limit > MAX_DIFF_BYTES) throw refused(REQUEST_INVALID, "git diff request is invalid")
        // The index against HEAD, or the working tree against the index: the
        // panel shows both, and a commit review is the first.
        val staged = request.opt("staged") as? Boolean ?: throw refused(REQUEST_INVALID, "git diff request is invalid")
        val opened = open(request, write = false)
        val diff = answer(RishLibgit2Native.diff(opened.gitDir, opened.workDir, staged, CONTEXT_LINES))
        // The patch is clipped to what the caller will take, on a character
        // boundary, and the clip counts as truncation.
        val clipped = RishAgentCoreNative.projectModuleReduce(
            JSONObject().put("op", "clip_utf8").put("value", diff.getString("patch"))
                .put("maximum_bytes", limit).toString(),
        )?.let { JSONObject(it) } ?: throw refused(NATIVE, "git diff failed")
        diff.put("patch", clipped.getString("value"))
        diff.put("truncated", diff.getBoolean("truncated") || clipped.optBoolean("truncated"))
        return stamped(diff, opened)
    }

    fun stageAll(rawRequest: JSONObject?): JSONObject {
        val request = exact(rawRequest, WORKSPACE_KEYS)
        val opened = open(request, write = true)
        return stamped(answer(RishLibgit2Native.stageAll(opened.gitDir, opened.workDir)), opened)
    }

    fun commit(rawRequest: JSONObject?): JSONObject {
        val request = exact(rawRequest, COMMIT_KEYS)
        val operationId = request.opt("operation_id") as? String
        val message = request.opt("message") as? String
        val name = request.opt("author_name") as? String
        val email = request.opt("author_email") as? String
        val expected = request.opt("expected_head_oid").takeIf { it != JSONObject.NULL }
        if (operationId == null || !projects.canonicalOperationId(operationId) ||
            message == null || !bounded(message, MAX_COMMIT_MESSAGE_BYTES) || message.isBlank() ||
            name == null || !bounded(name, MAX_AUTHOR_NAME_BYTES) || name.any { it.isWhitespace() } ||
            email == null || !bounded(email, MAX_EMAIL_BYTES) || !emailShaped(email) ||
            (expected != null && (expected !is String || !oid(expected)))
        ) {
            throw refused(REQUEST_INVALID, "git commit request is invalid")
        }
        val opened = open(request, write = true)
        val committed = answer(
            RishLibgit2Native.commit(opened.gitDir, opened.workDir, message, name, email, expected as String?),
        )
        return JSONObject().put("schema_version", 2).put("root", opened.root).put("project_id", opened.projectId)
            .put("oid", committed.getString("oid")).put("summary", message.lineSequence().first())
            .put("committed_at", RuntimeJson.now())
    }

    // --- the remote --------------------------------------------------------

    /** `setRemoteV2`: origin becomes `url`, judged as iOS judges it. Answers the sanitized remote. */
    fun setRemote(rawRequest: JSONObject?): JSONObject {
        val request = exact(rawRequest, REMOTE_KEYS)
        val url = validatedRemoteUrl(request.opt("url")) ?: throw refused(REQUEST_INVALID, "remote url is invalid")
        val opened = open(request, write = true)
        val answer = RishLibgit2Native.setRemote(opened.gitDir, opened.workDir, url)
        if (answer != "ok") throw refused(NATIVE, "git remote failed")
        return remoteDescriptor(opened, url)
    }

    /** `remoteV2`: the origin, or `url: null` when the project has none. */
    fun remote(rawRequest: JSONObject?): JSONObject {
        val request = exact(rawRequest, WORKSPACE_KEYS)
        val opened = open(request, write = false)
        return remoteDescriptor(opened, originUrl(opened))
    }

    /** `credentialStatusV2`: whether a credential exists for the origin's host, and until when. */
    fun credentialStatus(rawRequest: JSONObject?): JSONObject {
        val request = exact(rawRequest, WORKSPACE_KEYS)
        val opened = open(request, write = false)
        val host = originHost(opened)
        return stamped(credentialStore().status(opened.projectId, host), opened)
    }

    /**
     * `storeCredentialV2`, the native prompt's completion: the username and
     * token travel from the prompt into here and no further. The origin is
     * read again at save time so a remote changed under the prompt does not
     * receive a credential meant for another host.
     */
    fun storeCredential(rawRequest: JSONObject?): JSONObject {
        val request = exact(rawRequest, STORE_CREDENTIAL_KEYS)
        val username = request.opt("username") as? String ?: throw refused(REQUEST_INVALID, "credential is invalid")
        val token = request.opt("token") as? String ?: throw refused(REQUEST_INVALID, "credential is invalid")
        val expiry = (request.opt("expiry_seconds") as? Number)?.toLong() ?: throw refused(REQUEST_INVALID, "credential is invalid")
        val host = request.opt("host") as? String ?: throw refused(REQUEST_INVALID, "credential is invalid")
        val opened = open(request, write = false)
        if (originHost(opened) != host) throw refused(REMOTE_CHANGED, "origin remote changed before credential save")
        try {
            credentialStore().store(opened.projectId, host, username, token, expiry)
        } catch (_: IllegalArgumentException) {
            throw refused(REQUEST_INVALID, "credential is invalid")
        }
        return stamped(credentialStore().status(opened.projectId, host), opened)
    }

    fun clearCredential(rawRequest: JSONObject?): JSONObject {
        val request = exact(rawRequest, WORKSPACE_KEYS)
        val opened = open(request, write = false)
        val host = originHost(opened)
        credentialStore().clear(opened.projectId, host)
        return stamped(credentialStore().status(opened.projectId, host), opened)
    }

    /**
     * `pushV2`: the current branch, at exactly `expected_local_oid`, to origin,
     * with the credential stored for origin's host. Mirrors iOS's request
     * and answer, including the numbers it refuses with.
     */
    fun push(rawRequest: JSONObject?): JSONObject {
        val request = exact(rawRequest, PUSH_KEYS)
        val operationId = request.opt("operation_id") as? String
        val expected = request.opt("expected_local_oid") as? String
        val reference = request.opt("credential_reference") as? String
        if (operationId == null || !projects.canonicalOperationId(operationId) || request.opt("remote") != "origin" ||
            expected == null || !oid(expected) || reference == null || !bounded(reference, 256)
        ) {
            throw refused(REQUEST_INVALID, "git push request is invalid")
        }
        // No proxy on Android yet: a request that names one is refused
        // rather than sent past it.
        if (request.opt("https_proxy_url") != JSONObject.NULL) throw refused(REQUEST_INVALID, "https proxy is not supported here")
        val opened = open(request, write = true)
        val status = answer(RishLibgit2Native.status(opened.gitDir, opened.workDir))
        val branch = status.opt("branch") as? String
        val head = status.opt("head_oid") as? String
        if (branch.isNullOrEmpty() || head != expected) throw refused(HEAD_CHANGED, "git HEAD changed")
        val url = originUrl(opened) ?: throw refused(REMOTE_MISSING, "git remote is not configured")
        val host = hostOf(url)
        val credential = credentialStore().read(opened.projectId, host) ?: throw refused(CREDENTIAL_MISSING, "git credential is unavailable")
        val reply = answer(
            RishLibgit2Native.push(
                opened.gitDir, opened.workDir, operationId, url, host, "refs/heads/$branch", expected,
                credential.username, credential.token, PUSH_TIMEOUT_SECONDS,
            ),
        )
        val outcome = reply.optString("outcome")
        if (outcome != "success") {
            throw refused(
                when (outcome) {
                    "non_fast_forward" -> NON_FAST_FORWARD
                    "auth_failure" -> AUTH_REJECTED
                    "timed_out" -> TIMED_OUT
                    "cancelled" -> CANCELLED
                    else -> NATIVE
                },
                "git push $outcome",
            )
        }
        return JSONObject().put("schema_version", 2).put("root", opened.root).put("project_id", opened.projectId)
            .put("remote", "origin").put("branch", branch).put("oid", reply.optString("remote_oid", expected))
            .put("pushed_at", RuntimeJson.now())
    }

    /** `cancelPushV2`: asks a running push for this root to stop. */
    fun cancelPush(rawRequest: JSONObject?): JSONObject {
        val request = exact(rawRequest, CANCEL_PUSH_KEYS)
        val operationId = request.opt("operation_id") as? String
        if (operationId == null || !projects.canonicalOperationId(operationId)) throw refused(REQUEST_INVALID, "cancel request is invalid")
        val opened = open(request, write = false)
        val running = RishLibgit2Native.cancelPush(operationId)
        return stamped(JSONObject().put("operation_id", operationId).put("status", if (running) "cancel_requested" else "not_running"), opened)
    }

    private fun credentialStore(): AndroidGitCredentials = credentials ?: throw refused(UNAVAILABLE, "git credentials are unavailable")

    private fun originUrl(opened: Opened): String? =
        answer(RishLibgit2Native.remoteUrl(opened.gitDir, opened.workDir)).opt("url").takeIf { it != JSONObject.NULL } as? String

    private fun originHost(opened: Opened): String {
        val url = originUrl(opened) ?: throw refused(REMOTE_MISSING, "git remote is not configured")
        return hostOf(url)
    }

    private fun remoteDescriptor(opened: Opened, url: String?): JSONObject =
        stamped(JSONObject().put("remote", "origin").put("url", url ?: JSONObject.NULL).put("host", url?.let { hostOf(it) } ?: JSONObject.NULL), opened)

    private fun hostOf(url: String): String = java.net.URI(url).host?.lowercase() ?: ""

    /**
     * `DSHGitValidatedRemoteURL`: https to a public DNS name on 443, or
     * plain http to a private literal (a test remote on this device or the
     * LAN); never a user, password, query or fragment. Returns the URL with
     * scheme and host lowercased, or null.
     */
    private fun validatedRemoteUrl(value: Any?): String? {
        val text = value as? String ?: return null
        if (text.isEmpty() || text.length > 2048 || text.any { it.isISOControl() || it.isWhitespace() }) return null
        val uri = try { java.net.URI(text) } catch (_: Exception) { return null }
        val scheme = uri.scheme?.lowercase() ?: return null
        val host = uri.host?.lowercase() ?: return null
        if (uri.userInfo != null || uri.rawQuery != null || uri.rawFragment != null) return null
        val httpsValid = scheme == "https" && publicDnsName(host) && (uri.port == -1 || uri.port == 443)
        val httpValid = scheme == "http" && privateLiteral(host) && (uri.port == -1 || uri.port in 1..65535)
        if (!httpsValid && !httpValid) return null
        val port = if (uri.port == -1) "" else ":${uri.port}"
        return "$scheme://$host$port${uri.rawPath ?: ""}"
    }

    private fun publicDnsName(host: String): Boolean =
        Regex("[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+").matches(host) &&
            !host.endsWith(".local") && !host.endsWith(".localhost") && !privateLiteral(host)

    private fun privateLiteral(host: String): Boolean {
        if (host == "localhost") return true
        val parts = host.split(".")
        if (parts.size == 4 && parts.all { it.toIntOrNull()?.let { n -> n in 0..255 } == true }) {
            val a = parts[0].toInt(); val b = parts[1].toInt()
            return a == 127 || a == 10 || (a == 192 && b == 168) || (a == 172 && b in 16..31) || (a == 169 && b == 254)
        }
        val v6 = host.removePrefix("[").removeSuffix("]")
        return v6 == "::1" || v6.startsWith("fe80:") || v6.startsWith("fc") || v6.startsWith("fd")
    }

    // --- shared ------------------------------------------------------------

    private fun exact(rawRequest: JSONObject?, keys: Set<String>): JSONObject {
        val request = rawRequest ?: throw refused(REQUEST_INVALID, "git request is missing")
        if (request.keys().asSequence().toSet() != keys || request.opt("schema_version") != 1) {
            throw refused(REQUEST_INVALID, "git request is invalid")
        }
        return request
    }

    /**
     * The root, proven: the binding beside the gitdir restates it, and the
     * workspace grants what the operation needs. `v2LeaseForRoot` on iOS.
     */
    private fun open(request: JSONObject, write: Boolean): Opened {
        if (!RishLibgit2Native.require()) throw refused(UNAVAILABLE, "libgit2 is not available")
        val root = projects.canonicalRoot(request.optJSONObject("root"), projectRequired = true)
        val workspaceId = root.getString("workspace_id")
        val projectId = root.getString("project_id")
        projects.verifiedDescriptor(root, projectId)
        val capabilities = workspaces.descriptor(workspaceId)?.optJSONObject("capabilities")
        val needed = if (write) listOf("read", "write", "git") else listOf("read", "git")
        if (capabilities == null || !needed.all { capabilities.optBoolean(it) }) {
            throw refused(UNAVAILABLE, "workspace project is unavailable")
        }
        val workDir = projects.workingTree(workspaceId) ?: throw refused(UNAVAILABLE, "workspace project is unavailable")
        return Opened(root, projectId, projects.gitDirectory(workspaceId, projectId).absolutePath, workDir.absolutePath)
    }

    private fun answer(bytes: ByteArray): JSONObject {
        val reply = JSONObject(String(bytes, Charsets.UTF_8))
        if (!reply.optBoolean("ok")) {
            throw refused(reply.optInt("number", NATIVE), "git ${reply.optString("stage")} failed")
        }
        reply.remove("ok")
        return reply
    }

    private fun stamped(reply: JSONObject, opened: Opened): JSONObject =
        reply.put("schema_version", 2).put("root", opened.root).put("project_id", opened.projectId)

    private fun refused(number: Int, reason: String) = AndroidWorkspaceProjects.Refused(number, reason)

    private fun bounded(value: String, maximumBytes: Int): Boolean =
        value.isNotEmpty() && value.toByteArray(Charsets.UTF_8).size <= maximumBytes

    /** iOS's shape: one `@` with something on both sides, no whitespace, no angle brackets. */
    private fun emailShaped(value: String): Boolean {
        val parts = value.split("@")
        return parts.size == 2 && parts[0].isNotEmpty() && parts[1].isNotEmpty() &&
            value.none { it.isWhitespace() } && '<' !in value && '>' !in value
    }

    private fun oid(value: String): Boolean = value.length == 40 && value.all { it in '0'..'9' || it in 'a'..'f' }

    companion object {
        private const val REQUEST_INVALID = AndroidWorkspaceProjects.REQUEST_INVALID
        private const val UNAVAILABLE = AndroidWorkspaceProjects.UNAVAILABLE
        private const val NATIVE = 3199
        private const val CONTEXT_LINES = 3
        private const val MAX_DIFF_BYTES = 1024L * 1024
        private const val MAX_COMMIT_MESSAGE_BYTES = 500
        private const val MAX_AUTHOR_NAME_BYTES = 120
        private const val MAX_EMAIL_BYTES = 254
        private val WORKSPACE_KEYS = setOf("schema_version", "root")
        private val DIFF_KEYS = setOf("schema_version", "root", "max_bytes", "staged")
        private val COMMIT_KEYS = setOf(
            "schema_version", "root", "operation_id", "message", "author_name", "author_email", "expected_head_oid",
        )
        private val REMOTE_KEYS = setOf("schema_version", "root", "url")
        private val STORE_CREDENTIAL_KEYS = setOf("schema_version", "root", "host", "username", "token", "expiry_seconds")
        private val PUSH_KEYS = setOf(
            "schema_version", "root", "operation_id", "remote", "expected_local_oid", "credential_reference", "https_proxy_url",
        )
        private val CANCEL_PUSH_KEYS = setOf("schema_version", "root", "operation_id")
        private const val PUSH_TIMEOUT_SECONDS = 60
        // iOS's numbers for the same refusals.
        private const val HEAD_CHANGED = 3110
        private const val CREDENTIAL_MISSING = 3111
        private const val REMOTE_MISSING = 3112
        private const val REMOTE_CHANGED = 3113
        private const val CANCELLED = 3195
        private const val NON_FAST_FORWARD = 3196
        private const val AUTH_REJECTED = 3197
        private const val TIMED_OUT = 3198
    }
}
