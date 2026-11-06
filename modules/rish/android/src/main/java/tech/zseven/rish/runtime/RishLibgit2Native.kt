package tech.zseven.rish.runtime

/**
 * The vendored libgit2, as staged by scripts/prepare-libgit2-android.sh.
 *
 * A build without the library staged simply does not have it, the same way a
 * build without the agent core does not have the agent: [available] says so
 * rather than the app crashing on a missing symbol.
 */
internal object RishLibgit2Native {
    val available: Boolean by lazy {
        try {
            System.loadLibrary("rish_libgit2_jni")
            true
        } catch (_: UnsatisfiedLinkError) {
            false
        }
    }

    /**
     * Loads the library, or says it cannot. Every entry point that reaches a
     * native symbol calls this first: `available` is lazy, and a caller that
     * happened to be the first in a process to touch libgit2 got an
     * UnsatisfiedLinkError instead of an answer.
     */
    fun require(): Boolean = available

    /** The library's own version, for the receipt that records which one ran. */
    @JvmStatic external fun version(): String

    /** The features compiled in, comma separated: threads, https, ssh, nsec. */
    @JvmStatic external fun features(): String

    /**
     * Creates a repository at [path], commits a file into it and reads the
     * commit back. `ok:<message>` or `error:<stage>:<why>`.
     *
     * A floor test, not a feature: the object database, the index and the
     * commit path are what everything above this leans on, and a library that
     * only initialises proves none of them.
     */
    @JvmStatic external fun roundTrip(path: String): String

    /**
     * A repository's index and working state, as JSON.
     *
     * `{"ok":true,"head":…,"branch":…,"repository_state":…,
     *   "index_checksum":…,"entries":[{path,oid,mode,size,stage,staged,unstaged}]}`
     * or `{"ok":false,"stage":…,"error":…}`.
     *
     * [gitDir] is null for a plain repository whose `.git` is in [workDir].
     * A workspace's project is the other shape: a private bare gitdir, paired
     * with the workspace root as its working tree at every open, the way iOS
     * keeps it -- nothing inside the workspace says it is a repository.
     *
     * This layer holds no policy: which of these paths may be sent, and what
     * a selection of them becomes, is decided above it and mostly in the
     * shared core already. Entries come back sorted by path so two hosts
     * reading one repository produce the same bytes.
     */
    @JvmStatic external fun readRepositoryState(gitDir: String?, workDir: String): String

    /**
     * `git init --bare` at [gitDir], paired once with [workDir] to prove the
     * pairing works before the directory is published. `ok` or
     * `error:<stage>:<why>`.
     */
    @JvmStatic external fun initSplitRepository(gitDir: String, workDir: String): String

    /** `git add <path>` for a test that needs more than one staged file. */
    @JvmStatic external fun stagePath(gitDir: String?, workDir: String, path: String): String

    // --- the git panel ----------------------------------------------------
    //
    // Answers come back as UTF-8 bytes of JSON, `{"ok":true,...}` or
    // `{"ok":false,"number":<iOS error number>,"stage":...,"error":...}`.
    // Bytes rather than a string because a patch may hold a four-byte
    // character, which NewStringUTF's modified UTF-8 cannot carry.

    /** `statusForRepository`: branch, head, ahead/behind, and every changed path. */
    @JvmStatic external fun status(gitDir: String?, workDir: String): ByteArray

    /** `diffForRepository`: per-file stats and up to a mebibyte of patch text. */
    @JvmStatic external fun diff(gitDir: String?, workDir: String, staged: Boolean, contextLines: Int): ByteArray

    /** `git add -A`, answering the status that results. */
    @JvmStatic external fun stageAll(gitDir: String?, workDir: String): ByteArray

    /**
     * Commits the index on HEAD when HEAD is [expectedHead] (null: no commit
     * yet). `{"ok":true,"oid":...}`, or 3110 when HEAD moved.
     */
    @JvmStatic external fun commit(
        gitDir: String?, workDir: String, message: String, authorName: String, authorEmail: String,
        expectedHead: String?,
    ): ByteArray

    // --- the remote --------------------------------------------------------
    //
    // rish_project_remote.cpp. Kotlin validates the URL and holds the
    // credential; native only connects, uploads one refspec and reports the
    // remote's verdict in DSHGitPushSupport's outcome vocabulary.

    /** Points OpenSSL at the exported system roots; "ok" or "error:<why>". */
    @JvmStatic external fun configureCertificates(file: String): String

    /** `git remote add|set-url origin`; "ok" or "error:<stage>:<why>". */
    @JvmStatic external fun setRemote(gitDir: String?, workDir: String, url: String): String

    /** `{"ok":true,"url":<origin url or null>}`. */
    @JvmStatic external fun remoteUrl(gitDir: String?, workDir: String): ByteArray

    /**
     * `{"ok":true,"outcome":success|conflict|non_fast_forward|rejected|
     * auth_failure|timed_out|cancelled|failed,"advertised_oid","remote_oid",
     * "verified","effect_may_have_occurred"}`. Cancelled by `cancelPush` with
     * the same operation id from any thread.
     */
    @JvmStatic external fun push(
        gitDir: String?, workDir: String, operationId: String, remoteUrl: String, host: String,
        reference: String, localOid: String, username: String, token: String, timeoutSeconds: Int,
        hasExpectedRemoteOid: Boolean, expectedRemoteOid: String?, proxy: String,
    ): ByteArray

    /** [push] with no proxy. */
    @JvmStatic fun push(
        gitDir: String?, workDir: String, operationId: String, remoteUrl: String, host: String,
        reference: String, localOid: String, username: String, token: String, timeoutSeconds: Int,
        hasExpectedRemoteOid: Boolean, expectedRemoteOid: String?,
    ): ByteArray = push(
        gitDir, workDir, operationId, remoteUrl, host, reference, localOid, username, token, timeoutSeconds,
        hasExpectedRemoteOid, expectedRemoteOid, "",
    )

    /**
     * What origin advertises for `reference` now, over a FETCH connection
     * with the push's credential rule: `{"ok":true,"oid":…|null}`, null when
     * the remote does not have the reference. Refuses 3197 when the remote
     * turned the credential away, 3199 for any other transport failure.
     */
    @JvmStatic external fun remoteRefOid(
        gitDir: String?, workDir: String, remoteUrl: String, host: String, reference: String,
        username: String, token: String, timeoutSeconds: Int, proxy: String,
    ): ByteArray

    /** [remoteRefOid] with no proxy. */
    @JvmStatic fun remoteRefOid(
        gitDir: String?, workDir: String, remoteUrl: String, host: String, reference: String,
        username: String, token: String, timeoutSeconds: Int,
    ): ByteArray = remoteRefOid(gitDir, workDir, remoteUrl, host, reference, username, token, timeoutSeconds, "")

    /** `refs/remotes/origin/<branch>` := oid. Answers "ok" or "error:<stage>". */
    @JvmStatic external fun setTrackingReference(gitDir: String?, workDir: String, branch: String, oid: String): String

    @JvmStatic external fun cancelPush(operationId: String): Boolean

    /**
     * `git fetch origin`, bounded like a push and cancelled by `cancelPush`
     * with the same operation id: `{"ok":true,"outcome":success|auth_failure|
     * timed_out|cancelled|failed,"remote_oid":…|null,"ahead":n,"behind":n}`.
     * The current branch tracks `origin/<branch>` afterwards.
     */
    @JvmStatic external fun fetch(
        gitDir: String?, workDir: String, operationId: String, remoteUrl: String, host: String, branch: String,
        username: String, token: String, timeoutSeconds: Int, proxy: String,
    ): ByteArray

    /** [fetch] with no proxy. */
    @JvmStatic fun fetch(
        gitDir: String?, workDir: String, operationId: String, remoteUrl: String, host: String, branch: String,
        username: String, token: String, timeoutSeconds: Int,
    ): ByteArray = fetch(gitDir, workDir, operationId, remoteUrl, host, branch, username, token, timeoutSeconds, "")

    /**
     * A fast-forward of the current branch to `origin/<branch>` and nothing
     * else: `{"ok":true,"outcome":updated|up_to_date|diverged|dirty|
     * no_upstream,"oid":…,"previous_oid":…}`; 3110 when HEAD is not
     * `expectedHeadOid`.
     */
    @JvmStatic external fun fastForward(gitDir: String?, workDir: String, expectedHeadOid: String): ByteArray

    // --- merge after divergence --------------------------------------------
    //
    // rish_project_merge.cpp. Only a clean merge is ever carried out; the
    // steps are split so the caller can journal before the first write.

    /**
     * Every precondition, the merge in memory, the unreferenced merge commit
     * and a dry-run checkout: `{"ok":true,"outcome":ready|up_to_date|
     * fast_forward_available|conflicts|obstructed|detached_head|unborn_head|
     * head_changed|operation_in_progress|shallow|no_upstream|
     * upstream_changed|unrelated_histories|dirty|unsupported_submodule|
     * unsupported_filter|unsupported_paths,…}`. Changes no ref, index or
     * working tree.
     */
    @JvmStatic external fun mergePrepare(
        gitDir: String?, workDir: String, branch: String, expectedHeadOid: String,
        expectedTheirsOid: String, authorName: String, authorEmail: String,
    ): ByteArray

    /**
     * Checks the merge commit's tree out over the `ours` baseline, then moves
     * the branch with a compare-and-swap: merged | head_changed | obstructed
     * | checkout_failed | ref_changed | ref_failed. Only head_changed and
     * obstructed promise nothing was written.
     */
    @JvmStatic external fun mergeApply(
        gitDir: String?, workDir: String, branch: String, oursOid: String, mergeOid: String,
    ): ByteArray

    /** The compare-and-swap alone: merged | ref_changed | ref_failed. */
    @JvmStatic external fun mergeMoveRef(
        gitDir: String?, workDir: String, branch: String, oursOid: String, mergeOid: String,
    ): ByteArray

    /**
     * Where the branch, index and working tree stand against a journal's two
     * trees: `{"ok":true,"head":ours|merge|other,"index":ours|merge|other,
     * "worktree_clean":…,"conflicted":…}`.
     */
    @JvmStatic external fun mergeInspect(
        gitDir: String?, workDir: String, branch: String, oursOid: String, mergeOid: String,
    ): ByteArray

    /**
     * The network half of a clone into an empty split repository whose
     * origin is set: `{"ok":true,"outcome":success|auth_failure|timed_out|
     * cancelled|empty|failed,"branch":…,"oid":…}`. Anonymous when
     * `username` or `token` is empty; otherwise the credential is offered
     * once and only to `host`. Cancelled by `cancelPush` with the same
     * operation id.
     */
    @JvmStatic external fun cloneCheckout(
        gitDir: String?, workDir: String, operationId: String, host: String, username: String, token: String,
        timeoutSeconds: Int, proxy: String,
    ): ByteArray

    /** [cloneCheckout] with no proxy. */
    @JvmStatic fun cloneCheckout(
        gitDir: String?, workDir: String, operationId: String, host: String, username: String, token: String,
        timeoutSeconds: Int,
    ): ByteArray = cloneCheckout(gitDir, workDir, operationId, host, username, token, timeoutSeconds, "")

    // --- capturing a selection --------------------------------------------
    //
    // What `captureLease` reads from git on iOS, with nothing decided: the
    // decisions are AndroidProjectContextCapture's. Options and byte shapes
    // are iOS's, so a fingerprint and a patch come out the same.

    /**
     * `{"ok":true,"head_oid","branch","head_target","repository_state",
     *   "index_checksum","entries":[{path,stage,mode,size,oid}],
     *   "status_rows":[{kind,status,old_path,new_path,old_mode,new_mode,old_oid,new_oid}]}`
     * or `{"ok":false,"code":"project_unavailable"|"integrity"|"budget_exceeded","stage":...}`.
     */
    @JvmStatic external fun captureRepository(gitDir: String?, workDir: String): ByteArray

    @JvmStatic external fun blobExists(gitDir: String?, workDir: String, oid: String): Boolean

    /** A blob's raw bytes, or null when there is no such blob. */
    @JvmStatic external fun blob(gitDir: String?, workDir: String, oid: String): ByteArray?

    /**
     * The serialized patch between two revisions of one file, or null when
     * git cannot say or the patch is not clean text. Staged compares blobs;
     * otherwise the old blob against [newBuffer].
     */
    @JvmStatic external fun patch(
        gitDir: String?, workDir: String, staged: Boolean, oldOid: String, oldPath: String,
        newOid: String, newPath: String, newBuffer: ByteArray?,
    ): ByteArray?

    // --- the agent's git tools --------------------------------------------
    //
    // AgentGitToolSupport.mm's half. The commit is made only with the id the
    // core predicted; see AndroidAgentGitToolExecutor.

    /** `{ok, reference|null, branch|null, head_oid|null, head_reference_name|null}`. */
    @JvmStatic external fun agentBranch(gitDir: String?, workDir: String): ByteArray

    /** `{ok, branch, head_oid, clean, has_conflicts, entry_count}`. */
    @JvmStatic external fun agentStatus(gitDir: String?, workDir: String): ByteArray

    /** The tree a stage-all would commit and its index rows; nothing is written. */
    @JvmStatic external fun agentStage(gitDir: String?, workDir: String): ByteArray

    /**
     * Stages, commits without moving HEAD, requires the predicted id, then
     * moves HEAD from [expectedHead] (null: unborn) and writes the index.
     * `{ok, commit_oid, tree_oid}` or `{ok:false, failure}`.
     */
    @JvmStatic external fun agentCommit(
        gitDir: String?, workDir: String, message: String, timestampSeconds: Long, timezoneMinutes: Int,
        expectedHead: String?, expectedTree: String, expectedCommit: String,
    ): ByteArray
}
