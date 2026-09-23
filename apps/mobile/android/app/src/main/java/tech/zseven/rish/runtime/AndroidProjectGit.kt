package tech.zseven.rish.runtime

import org.json.JSONArray
import org.json.JSONObject
import java.io.File

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
            name == null || !bounded(name, MAX_AUTHOR_NAME_BYTES) || !nameShaped(name) ||
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

    /**
     * `presentCredentialPromptV2`, before the prompt: the origin's host and
     * whether it is plain HTTP, so the dialog can say so. The credential
     * itself arrives through [storeCredential] once the person has chosen.
     */
    fun promptScope(rawRequest: JSONObject?): JSONObject {
        val request = exact(rawRequest, PROMPT_KEYS)
        val locale = request.opt("locale") as? String
        if (locale != "zh-CN" && locale != "en") throw refused(REQUEST_INVALID, "locale is invalid")
        val opened = open(request, write = false)
        val url = originUrl(opened) ?: throw refused(REMOTE_MISSING, "git remote is not configured")
        return JSONObject().put("host", hostOf(url)).put("plaintext", url.startsWith("http://")).put("chinese", locale == "zh-CN")
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
                credential.username, credential.token, PUSH_TIMEOUT_SECONDS, false, null,
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
        val pushedAt = RuntimeJson.now()
        val remoteOid = reply.optString("remote_oid").takeIf { it.isNotEmpty() } ?: expected
        // What this push proved, kept beside the gitdir for the panel; a
        // receipt that cannot be written does not unmake the push.
        try {
            AndroidGitPushReceipts.record(File(opened.gitDir), opened.projectId, AndroidGitPushReceipts.receipt(host, branch, expected, remoteOid, pushedAt))
        } catch (refused: AndroidWorkspaceProjects.Refused) {
            android.util.Log.w("RishProjects", "push receipt not recorded: ${refused.number}")
        }
        return JSONObject().put("schema_version", 2).put("root", opened.root).put("project_id", opened.projectId)
            .put("remote", "origin").put("branch", branch).put("oid", remoteOid)
            .put("pushed_at", pushedAt)
    }

    /** `pushReceiptsV2`: what every recorded push proved, oldest first, sanitized. */
    fun pushReceipts(rawRequest: JSONObject?): JSONObject {
        val request = exact(rawRequest, WORKSPACE_KEYS)
        val opened = open(request, write = false)
        val receipts = AndroidGitPushReceipts.load(File(opened.gitDir), opened.projectId)
        val rows = JSONArray()
        for (index in 0 until receipts.length()) rows.put(AndroidGitPushReceipts.sanitized(receipts.getJSONObject(index)))
        return stamped(JSONObject().put("receipts", rows), opened)
    }

    /**
     * `fetchV2`: `git fetch origin` with the credential stored for origin's
     * host, or anonymously when none is stored (a public remote answers
     * that; a private one turns it away as 3197). Answers what the remote
     * holds for the current branch and how far the local branch stands
     * from it. Cancelled by [cancelPush] with the same operation id.
     */
    fun fetch(rawRequest: JSONObject?): JSONObject {
        val request = exact(rawRequest, FETCH_KEYS)
        val operationId = request.opt("operation_id") as? String
        if (operationId == null || !projects.canonicalOperationId(operationId) || request.opt("remote") != "origin") {
            throw refused(REQUEST_INVALID, "git fetch request is invalid")
        }
        val opened = open(request, write = true)
        val branch = answer(RishLibgit2Native.status(opened.gitDir, opened.workDir)).opt("branch") as? String
        if (branch.isNullOrEmpty()) throw refused(HEAD_CHANGED, "no branch to fetch for")
        val url = originUrl(opened) ?: throw refused(REMOTE_MISSING, "git remote is not configured")
        val host = hostOf(url)
        val credential = credentialStore().read(opened.projectId, host)
        val reply = answer(
            RishLibgit2Native.fetch(
                opened.gitDir, opened.workDir, operationId, url, host, branch,
                credential?.username ?: "", credential?.token ?: "", PUSH_TIMEOUT_SECONDS,
            ),
        )
        val outcome = reply.optString("outcome")
        if (outcome != "success") {
            throw refused(
                when (outcome) {
                    "auth_failure" -> AUTH_REJECTED
                    "timed_out" -> TIMED_OUT
                    "cancelled" -> CANCELLED
                    else -> NATIVE
                },
                "git fetch $outcome",
            )
        }
        return stamped(
            JSONObject().put("remote", "origin").put("branch", branch)
                .put("remote_oid", reply.opt("remote_oid") ?: JSONObject.NULL)
                .put("ahead", reply.optInt("ahead")).put("behind", reply.optInt("behind"))
                .put("fetched_at", RuntimeJson.now()),
            opened,
        )
    }

    /**
     * `pullFastForwardV2`: the current branch moves to `origin/<branch>`
     * only when that is a fast-forward over a working tree with no changes
     * to tracked files; anything else is refused before a file moves.
     * Diverged history is 3196, a dirty tree or a moved HEAD 3110, no
     * fetched upstream 3112. Fetch first; this touches no network.
     */
    fun pullFastForward(rawRequest: JSONObject?): JSONObject {
        val request = exact(rawRequest, PULL_KEYS)
        val expected = request.opt("expected_head_oid") as? String
        if (expected == null || !oid(expected)) throw refused(REQUEST_INVALID, "git pull request is invalid")
        val opened = open(request, write = true)
        val status = answer(RishLibgit2Native.status(opened.gitDir, opened.workDir))
        val branch = status.opt("branch") as? String
        if (branch.isNullOrEmpty() || status.opt("head_oid") != expected) throw refused(HEAD_CHANGED, "git HEAD changed")
        val reply = answer(RishLibgit2Native.fastForward(opened.gitDir, opened.workDir, expected))
        when (reply.optString("outcome")) {
            "updated", "up_to_date" -> Unit
            "diverged" -> throw refused(NON_FAST_FORWARD, "local and remote histories diverged")
            "dirty" -> throw refused(HEAD_CHANGED, "working tree has changes")
            "no_upstream" -> throw refused(REMOTE_MISSING, "nothing fetched for this branch")
            else -> throw refused(NATIVE, "git fast-forward failed")
        }
        return stamped(
            JSONObject().put("branch", branch).put("oid", reply.getString("oid"))
                .put("previous_oid", reply.getString("previous_oid"))
                .put("updated", reply.optString("outcome") == "updated"),
            opened,
        )
    }

    /**
     * `mergeRemoteV2`: a diverged branch merged with the upstream the person
     * just fetched -- only when the merge is clean.
     *
     * A conflict is answered with its paths and nothing moves. A clean merge
     * is carried out in the order astra ruled on: everything is decided and
     * the merge commit exists (referenced by nothing) before a file changes;
     * a journal is written before the first index or working-tree write; the
     * merged tree is checked out; then the branch moves with a
     * compare-and-swap. Checkout is not atomic, so anything that fails after
     * it started leaves the journal for [recoverMerge] instead of being
     * reported as "nothing changed".
     */
    fun mergeRemote(rawRequest: JSONObject?): JSONObject {
        val request = exact(rawRequest, MERGE_KEYS)
        val operationId = request.opt("operation_id") as? String
        val branch = request.opt("expected_branch") as? String
        val ours = request.opt("expected_head_oid") as? String
        val theirs = request.opt("expected_remote_oid") as? String
        val name = request.opt("author_name") as? String
        val email = request.opt("author_email") as? String
        if (operationId == null || !projects.canonicalOperationId(operationId) ||
            branch == null || !branchShaped(branch) ||
            ours == null || !oid(ours) || theirs == null || !oid(theirs) ||
            name == null || !bounded(name, MAX_AUTHOR_NAME_BYTES) || !nameShaped(name) ||
            email == null || !bounded(email, MAX_EMAIL_BYTES) || !emailShaped(email)
        ) {
            throw refused(REQUEST_INVALID, "git merge request is invalid")
        }
        val opened = open(request, write = true)
        // A merge left unfinished by a crash is settled first; if it cannot
        // be, nothing new is attempted over it.
        recoverMerge(opened)

        val prepared = answer(
            RishLibgit2Native.mergePrepare(opened.gitDir, opened.workDir, branch, ours, theirs, name, email),
        )
        fun result(outcome: String, oid: String) = stamped(
            JSONObject().put("branch", branch).put("outcome", outcome).put("oid", oid).put("previous_oid", ours)
                .put("conflicts", prepared.optJSONArray("conflicts") ?: JSONArray())
                .put("paths", prepared.optJSONArray("paths") ?: JSONArray()),
            opened,
        )
        when (val outcome = prepared.optString("outcome")) {
            "ready" -> Unit
            "up_to_date", "fast_forward_available", "conflicts", "obstructed" -> return result(outcome, ours)
            "head_changed", "detached_head", "unborn_head", "dirty", "operation_in_progress" ->
                throw refused(HEAD_CHANGED, "git merge refused: $outcome")
            "no_upstream", "upstream_changed" -> throw refused(REMOTE_MISSING, "git merge refused: $outcome")
            "shallow", "unrelated_histories", "unsupported_submodule", "unsupported_filter", "unsupported_paths" ->
                throw refused(MERGE_UNSUPPORTED, "git merge refused: $outcome")
            else -> throw refused(NATIVE, "git merge prepare failed")
        }
        val mergeOid = prepared.getString("merge_oid")
        val journal = JSONObject().put("schema_version", 1).put("operation_id", operationId)
            .put("branch", branch).put("ours", ours).put("theirs", theirs).put("merge_oid", mergeOid)
            .put("tree_oid", prepared.getString("tree_oid")).put("phase", "applying")
            .put("created_at", RuntimeJson.now())
        writeMergeJournal(opened, journal)

        val applied = answer(RishLibgit2Native.mergeApply(opened.gitDir, opened.workDir, branch, ours, mergeOid))
        when (applied.optString("outcome")) {
            "merged" -> Unit
            // Found before a file was written: the journal has nothing to
            // guard, so it goes, and the refusal is an honest one.
            "head_changed" -> { clearMergeJournal(opened); throw refused(HEAD_CHANGED, "git merge refused: head_changed") }
            "obstructed" -> { clearMergeJournal(opened); return result("obstructed", ours) }
            // Anything else may have happened after the checkout began.
            else -> throw refused(RECOVERY_REQUIRED, "git merge interrupted: ${applied.optString("outcome")}")
        }
        val inspected = answer(RishLibgit2Native.mergeInspect(opened.gitDir, opened.workDir, branch, ours, mergeOid))
        // index_merge, not "not ours": when both sides made the same change
        // the merge's tree is the tree the branch already had, and both hold.
        if (inspected.optString("head") != "merge" || !inspected.optBoolean("index_merge") ||
            !inspected.optBoolean("worktree_clean") || inspected.optBoolean("conflicted")
        ) {
            throw refused(RECOVERY_REQUIRED, "git merge landed in an unexpected state")
        }
        clearMergeJournal(opened)
        return result("merged", mergeOid)
    }

    /**
     * Settles a merge journal left by an interrupted merge, from what the
     * repository actually is -- never from the phase alone, which may have
     * been written before its effect. Never a hard reset: a state this does
     * not recognise is kept, and refused as needing recovery.
     */
    private fun recoverMerge(opened: Opened) {
        val file = mergeJournal(opened)
        if (!file.exists()) return
        val journal = try {
            JSONObject(file.readText())
        } catch (_: Exception) {
            throw refused(RECOVERY_REQUIRED, "git merge journal is unreadable")
        }
        val branch = journal.optString("branch")
        val ours = journal.optString("ours")
        val merge = journal.optString("merge_oid")
        if (!branchShaped(branch) || !oid(ours) || !oid(merge)) {
            throw refused(RECOVERY_REQUIRED, "git merge journal is invalid")
        }
        val state = answer(RishLibgit2Native.mergeInspect(opened.gitDir, opened.workDir, branch, ours, merge))
        val head = state.optString("head")
        val indexMerge = state.optBoolean("index_merge")
        val indexOurs = state.optBoolean("index_ours")
        val clean = state.optBoolean("worktree_clean") && !state.optBoolean("conflicted")
        when {
            // Done: the branch, the index and the files are the merge.
            head == "merge" && indexMerge && clean -> clearMergeJournal(opened)
            // Checked out but the branch never moved: finish the move.
            // Also the case where the merge's tree equals ours: the person
            // approved this merge, and finishing it writes no file.
            head == "ours" && indexMerge && clean -> {
                val moved = answer(RishLibgit2Native.mergeMoveRef(opened.gitDir, opened.workDir, branch, ours, merge))
                if (moved.optString("outcome") != "merged") {
                    throw refused(RECOVERY_REQUIRED, "git merge could not be finished")
                }
                clearMergeJournal(opened)
            }
            // Nothing was written: the merge never started.
            head == "ours" && indexOurs && clean -> clearMergeJournal(opened)
            else -> throw refused(RECOVERY_REQUIRED, "git merge needs recovery")
        }
    }

    private fun mergeJournal(opened: Opened): File = File(opened.gitDir, MERGE_JOURNAL)

    /**
     * Written whole and flushed before the first write to the index or the
     * working tree: a journal that could be lost in a crash would guard
     * nothing.
     */
    private fun writeMergeJournal(opened: Opened, journal: JSONObject) {
        val target = mergeJournal(opened)
        val staging = File(target.parentFile, "$MERGE_JOURNAL.tmp")
        try {
            java.io.FileOutputStream(staging).use { stream ->
                stream.write(journal.toString().toByteArray(Charsets.UTF_8))
                stream.fd.sync()
            }
            if (!staging.renameTo(target)) throw java.io.IOException("rename")
            syncDirectory(target.parentFile)
        } catch (_: Exception) {
            // Nothing has been changed yet, so a journal that may not be
            // durable is withdrawn and the merge refused.
            staging.delete()
            target.delete()
            throw refused(NATIVE, "git merge journal could not be written")
        }
    }

    /**
     * A rename or removal made durable. A directory is synced through a raw
     * descriptor: Java's file classes refuse to open one. Throws when it
     * cannot be synced; each caller decides what that means.
     */
    private fun syncDirectory(directory: File?) {
        if (directory == null) throw java.io.IOException("no directory")
        val descriptor = android.system.Os.open(directory.absolutePath, android.system.OsConstants.O_RDONLY, 0)
        try { android.system.Os.fsync(descriptor) } finally { android.system.Os.close(descriptor) }
    }

    private fun clearMergeJournal(opened: Opened) {
        val file = mergeJournal(opened)
        if (file.exists() && !file.delete()) throw refused(NATIVE, "git merge journal could not be cleared")
        // A removal lost to power failure brings the journal back over a
        // repository recovery reads as finished or untouched, and clears it
        // again, so a failed sync here is not a failed merge.
        try { syncDirectory(file.parentFile) } catch (_: Exception) {}
    }

    /** A branch name as the panel can show one: no ref prefix, no whitespace or control characters. */
    private fun branchShaped(value: String): Boolean =
        value.isNotEmpty() && value.length <= 255 && !value.startsWith("refs/") &&
            value.none { it.isWhitespace() || it.isISOControl() } && !value.contains("..")

    /** `cancelPushV2`: asks a running push -- or fetch -- for this root to stop. */
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

    private fun hostOf(url: String): String = AndroidGitRemoteUrl.hostOf(url)

    private fun validatedRemoteUrl(value: Any?): String? = AndroidGitRemoteUrl.validated(value)

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

    /**
     * A person's name as a git signature can carry it: spaces inside, but
     * no edge whitespace, no control characters, no angle brackets.
     */
    private fun nameShaped(value: String): Boolean =
        value == value.trim() && value.none { it.isISOControl() || it == '<' || it == '>' }

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
        private val PROMPT_KEYS = setOf("schema_version", "root", "locale")
        private val STORE_CREDENTIAL_KEYS = setOf("schema_version", "root", "host", "username", "token", "expiry_seconds")
        private val PUSH_KEYS = setOf(
            "schema_version", "root", "operation_id", "remote", "expected_local_oid", "credential_reference", "https_proxy_url",
        )
        private val CANCEL_PUSH_KEYS = setOf("schema_version", "root", "operation_id")
        private val FETCH_KEYS = setOf("schema_version", "root", "operation_id", "remote")
        private val PULL_KEYS = setOf("schema_version", "root", "expected_head_oid")
        private val MERGE_KEYS = setOf(
            "schema_version", "root", "operation_id", "expected_branch", "expected_head_oid",
            "expected_remote_oid", "author_name", "author_email",
        )
        private const val MERGE_JOURNAL = "rish-merge.json"
        private const val PUSH_TIMEOUT_SECONDS = 60
        // iOS's numbers for the same refusals.
        private const val HEAD_CHANGED = 3110
        private const val CREDENTIAL_MISSING = 3111
        private const val REMOTE_MISSING = 3112
        private const val REMOTE_CHANGED = 3113
        private const val CANCELLED = 3195
        private const val NON_FAST_FORWARD = 3196
        /** A merge this slice does not carry out: shallow, unrelated, submodule, filter, path. */
        private const val MERGE_UNSUPPORTED = 3180
        /** A merge journal whose state this cannot settle on its own. */
        private const val RECOVERY_REQUIRED = 3181
        private const val AUTH_REJECTED = 3197
        private const val TIMED_OUT = 3198
    }
}
