package tech.zseven.rish.runtime

import org.json.JSONObject

/**
 * JNI binding for the shared Rust agent core (modules/rish/core, see
 * src/main/cpp/rish_agent_core_jni.cpp).
 *
 * The library is only present in builds that staged it through
 * scripts/prepare-rish-agent-core-android.sh. [available] answers whether it
 * loaded; without it the session store refuses to persist rather than falling
 * back to a second set of rules.
 */
internal object RishAgentCoreNative {
    val available: Boolean by lazy {
        try {
            System.loadLibrary("rish_agent_ffi")
            System.loadLibrary("rish_agent_core_jni")
            true
        } catch (_: UnsatisfiedLinkError) {
            false
        } catch (_: SecurityException) {
            false
        }
    }

    @JvmStatic external fun protocolVersion(): Int

    /** "rish-agent-core <version> <git sha>" of the linked build. */
    @JvmStatic external fun buildId(): String?

    /**
     * One session-schema decision. [requestJson] is the `{"op", ...}` envelope
     * and [input] the operation's raw bytes (a candidate, a stored envelope, a
     * tombstone ledger), empty for ops that take none.
     */
    @JvmStatic external fun sessionReduce(requestJson: String, input: String?): String?

    /** One stored-WAL-row decision over the `{"op","value","env"?}` envelope. */
    @JvmStatic external fun walStateReduce(requestJson: String): String?

    /** One WAL operation-relation decision. */
    @JvmStatic external fun walOperationReduce(requestJson: String): String?

    /**
     * One workspace-tool decision: what a file tool may read or write, what a
     * listing includes, what a refusal is called. The host opens the file; the
     * rule about it is the core's, and it is the same rule iOS asks.
     */
    @JvmStatic external fun workspaceToolReduce(requestJson: String): String?

    /** `DSHAgentHB`: SHA-256 over tagged raw bytes. */
    @JvmStatic external fun hashBytes(tag: String, bytes: ByteArray): String?

    /** The canonical form of tool arguments the strict parser accepts. */
    @JvmStatic external fun parseArguments(requestJson: String): String?

    // The rest of the core's decision surface, bound in one go rather than one
    // at a time as each layer above turned out to need it. A binding is not an
    // implementation: these say only that the rule can be asked from here.
    @JvmStatic external fun completionResponseReduce(requestJson: String): String?
    @JvmStatic external fun containerAnchorReduce(requestJson: String): String?
    @JvmStatic external fun gitToolReduce(requestJson: String): String?
    @JvmStatic external fun ledgerBatchReduce(requestJson: String): String?
    @JvmStatic external fun policyReduce(requestJson: String): String?
    @JvmStatic external fun projectAccessReduce(requestJson: String): String?
    @JvmStatic external fun projectContextBridgeReduce(requestJson: String): String?
    @JvmStatic external fun projectContextReduce(requestJson: String, content: ByteArray?): String?
    @JvmStatic external fun projectContextServiceReduce(requestJson: String): String?
    @JvmStatic external fun projectContextStoreReduce(requestJson: String): String?
    @JvmStatic external fun projectModuleReduce(requestJson: String): String?
    @JvmStatic external fun providerRoundReduce(requestJson: String): String?
    @JvmStatic external fun toolBatchReduce(requestJson: String): String?
    @JvmStatic external fun toolExecutionReduce(requestJson: String): String?
    @JvmStatic external fun workspaceClearanceReduce(requestJson: String): String?
    @JvmStatic external fun workspaceErrorReduce(requestJson: String): String?
    @JvmStatic external fun workspaceReadToolsReduce(requestJson: String): String?

    /** One runtime-coordinator decision. */
    @JvmStatic external fun runtimeReduce(requestJson: String): String?

    /** One transcript-store decision over `{"op","request","env","view"}`. */
    fun transcriptReduce(requestJson: String): String? {
        requireAvailable()
        return transcriptReduceNative(requestJson)
    }

    @JvmStatic external fun transcriptReduceNative(requestJson: String): String?

    /** One schema-3 round-journal decision over `{"op","args","env","view"}`. */
    fun roundReduce(requestJson: String): String? {
        requireAvailable()
        return roundReduceNative(requestJson)
    }

    @JvmStatic external fun roundReduceNative(requestJson: String): String?

    /** One execution-ledger row decision over `{"op","args","env","view"}`. */
    fun ledgerReduce(requestJson: String): String? {
        requireAvailable()
        return ledgerReduceNative(requestJson)
    }

    @JvmStatic external fun ledgerReduceNative(requestJson: String): String?

    /** One tool-registry question over `{"op","guest_cgi",...}`. */
    fun toolRegistryReduce(requestJson: String): String? {
        requireAvailable()
        return toolRegistryReduceNative(requestJson)
    }

    @JvmStatic external fun toolRegistryReduceNative(requestJson: String): String?

    /** Adopts a committed WAL state and returns an opaque handle, or 0. */
    @JvmStatic external fun walOpen(stateJson: String): Long

    /** The committed state, or null once the handle has been invalidated. */
    @JvmStatic external fun walSnapshot(handle: Long): String?

    /** Takes a candidate and returns the exact bytes to write, or null. */
    @JvmStatic external fun walBegin(handle: Long, candidateJson: String): String?

    /** Resolves the candidate with "committed", "not_committed" or "unknown". */
    @JvmStatic external fun walConfirm(handle: Long, outcome: String): String?

    /** Releases a handle. Zero is ignored. */
    @JvmStatic external fun walClose(handle: Long)

    /** SHA-256 over "rish.<tag>.v1\0" and the canonical JSON, lowercase hex. */
    @JvmStatic external fun hashJson(tag: String, json: String): String?

    /** One prepared-attempt decision; `session` carries the committed
     *  session's exact bytes for the `session` op. */
    @JvmStatic external fun preparedAttemptReduce(
        requestJson: String, session: String?): String?

    /** Canonical JSON of a JSON text, or null when it cannot be canonicalised. */
    @JvmStatic external fun workspaceJsonBoundedNative(bytes: ByteArray): Boolean

    @JvmStatic external fun rootReduceNative(requestJson: String): String?

    @JvmStatic external fun workspaceReceiptReduceNative(requestJson: String): String?

    @JvmStatic external fun workspaceJournalReduceNative(requestJson: String): String?

    @JvmStatic external fun workspaceRecordReduceNative(requestJson: String): String?

    @JvmStatic external fun workspaceFingerprintReduceNative(requestJson: String): String?

    @JvmStatic external fun workspaceGrantsReduceNative(requestJson: String): String?

    @JvmStatic external fun workspaceAuthorityReduceNative(requestJson: String): String?

    @JvmStatic external fun workspaceDirectoryNameReduceNative(requestJson: String): String?

    @JvmStatic external fun canonicalJson(json: String): String?

    /**
     * Runs one session decision and returns its reply, or throws when the core
     * refused. A refusal is never downgraded into a local decision: the whole
     * point of routing through the core is that both platforms answer alike.
     */
    fun session(request: JSONObject, input: String? = null): JSONObject {
        check(available) { "the shared agent core is not staged in this build" }
        val reply = sessionReduce(request.toString(), input)
            ?: error("the shared agent core produced no reply for ${request.optString("op")}")
        val parsed = JSONObject(reply)
        if (parsed.optBoolean("ok")) return parsed
        error("the shared agent core refused ${request.optString("op")}: ${parsed.opt("error")}")
    }

    private fun requireAvailable() {
        check(available) { "the shared agent core is not staged in this build" }
    }

    // The raw externals are unbound until `available` has loaded the
    // libraries, so nothing may call them directly. These wrappers are the
    // only way in, and each one loads first.

    /** Canonical JSON of a JSON text, or null when it cannot be canonicalised. */
    fun canonical(json: String): String? {
        requireAvailable()
        return canonicalJson(json)
    }

    /** Adopts a committed WAL state and returns an opaque handle, or 0. */
    fun openWal(stateJson: String): Long {
        requireAvailable()
        return walOpen(stateJson)
    }

    /** The committed state, or null once the handle has been invalidated. */
    fun snapshotWal(handle: Long): String? {
        requireAvailable()
        return walSnapshot(handle)
    }

    /** Takes a candidate and returns the exact bytes to write, or null. */
    fun beginWal(handle: Long, candidateJson: String): String? {
        requireAvailable()
        return walBegin(handle, candidateJson)
    }

    /** Resolves the candidate with "committed", "not_committed" or "unknown". */
    fun confirmWal(handle: Long, outcome: String): String? {
        requireAvailable()
        return walConfirm(handle, outcome)
    }

    /** Releases a handle; a build without the core has none to release. */
    fun closeWal(handle: Long) {
        if (available) walClose(handle)
    }

    /** One stored-WAL-row or operation-relation decision, or null on refusal. */
    fun wal(request: JSONObject, operation: Boolean = false): JSONObject? {
        if (!available) return null
        val reply = (if (operation) walOperationReduce(request.toString())
                     else walStateReduce(request.toString())) ?: return null
        val parsed = JSONObject(reply)
        return if (parsed.optBoolean("ok")) parsed else null
    }

    /** The domain-separated digest of a canonical JSON value. */
    fun hash(tag: String, value: JSONObject): String {
        requireAvailable()
        return hashJson(tag, value.toString())
            ?: error("the shared agent core could not digest a $tag value")
    }

    /**
     * One prepared-attempt decision, or null on refusal. The reply carries the
     * outcome; a refusal here is the core saying the request or the state is
     * not one it will act on, never a reason to decide locally.
     */
    fun preparedAttempt(request: JSONObject, session: String? = null): JSONObject? {
        if (!available) return null
        val reply = preparedAttemptReduce(request.toString(), session) ?: return null
        val parsed = JSONObject(reply)
        return if (parsed.optBoolean("ok")) parsed else null
    }

    /**
     * The five workspace reducers. Each takes an envelope naming an `op` and
     * returns the reply, or null when the core refused it — which means the
     * envelope was not one the rule acts on, never a licence to answer here.
     *
     * A host that cannot reach the core has no second set of workspace rules
     * to fall back to, so it refuses too.
     */
    /**
     * Whether stored bytes are JSON the engine will look at. Raw bytes, not an
     * envelope: the question is about bytes that may not be JSON.
     *
     * A build without the core cannot answer, and answers no — refusing to
     * read a file it cannot vet is the only honest option.
     */
    fun workspaceJsonBounded(bytes: ByteArray): Boolean =
        available && workspaceJsonBoundedNative(bytes)

    fun agentRoot(request: JSONObject): JSONObject? =
        workspaceReply(request) { rootReduceNative(it) }

    fun workspaceReceipt(request: JSONObject): JSONObject? =
        workspaceReply(request) { workspaceReceiptReduceNative(it) }

    fun workspaceJournal(request: JSONObject): JSONObject? =
        workspaceReply(request) { workspaceJournalReduceNative(it) }

    fun workspaceRecord(request: JSONObject): JSONObject? =
        workspaceReply(request) { workspaceRecordReduceNative(it) }

    fun workspaceFingerprint(request: JSONObject): JSONObject? =
        workspaceReply(request) { workspaceFingerprintReduceNative(it) }

    fun workspaceGrants(request: JSONObject): JSONObject? =
        workspaceReply(request) { workspaceGrantsReduceNative(it) }

    fun workspaceAuthority(request: JSONObject): JSONObject? =
        workspaceReply(request) { workspaceAuthorityReduceNative(it) }

    /** What a clearance operation and its receipt look like, and whether one authorises the other. */
    fun workspaceClearance(request: JSONObject): JSONObject? =
        workspaceReply(request) { workspaceClearanceReduce(it) }

    fun workspaceDirectoryName(request: JSONObject): JSONObject? =
        workspaceReply(request) { workspaceDirectoryNameReduceNative(it) }

    /** What a file tool may do, decided by the same rule iOS asks. */
    fun workspaceTool(request: JSONObject): JSONObject? =
        workspaceReply(request) { workspaceToolReduce(it) }

    /** What the agent may do in one binding, for the permissions sheet. */
    fun agentPolicy(request: JSONObject): JSONObject? =
        workspaceReply(request) { policyReduce(it) }

    private inline fun workspaceReply(
        request: JSONObject,
        reduce: (String) -> String?,
    ): JSONObject? {
        if (!available) return null
        val reply = reduce(request.toString()) ?: return null
        val parsed = JSONObject(reply)
        return if (parsed.optBoolean("ok")) parsed else null
    }

    /** The same call, with a refusal reported as null instead of thrown. */
    fun sessionOrNull(request: JSONObject, input: String? = null): JSONObject? {
        if (!available) return null
        val reply = sessionReduce(request.toString(), input) ?: return null
        val parsed = JSONObject(reply)
        return if (parsed.optBoolean("ok")) parsed else null
    }
}
