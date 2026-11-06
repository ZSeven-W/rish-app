package tech.zseven.rish.runtime

import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/**
 * `prepare_agent_attempt`, the one operation that reads the committed session
 * and writes the agent WAL in the same breath.
 *
 * That seam is why this exists on Android at all. The session lives in SQLite
 * and the WAL is a file; nothing makes the two atomic, and the window between
 * "the session says generation N" and "the WAL has committed an operation
 * bound to N" is the only place in the engine where a crash can leave the two
 * stores disagreeing. Every decision inside it belongs to the core, exactly as
 * on iOS — the checkpoint relation, whether the observed session still matches
 * the request, what the operation row looks like, and whether this operation
 * already committed.
 *
 * **Scope.** Android now has a workspace registry, so a request naming a
 * workspace binding is resolved against it and, when the root still proves
 * out, prepared for real — an authority, a transcript, the lot. A request
 * naming a `project_id` is still refused as `E_AGENT_ROOT_STALE`: a project
 * root needs an independently verified project lease and there is no project
 * subsystem here.
 *
 * A rootless request remains a first-class case, and the core commits it as
 * `not_agent` / `E_AGENT_NO_ROOT` with the operation in state `rejected`.
 * A binding that cannot be proven is `E_AGENT_ROOT_STALE`, which is what iOS
 * answers when a root it was given can no longer be proved.
 */
internal class AndroidPreparedAttemptStore(
    private val sessions: AndroidSessionStore,
    private val wal: AndroidAgentWal,
    private val roots: AndroidAgentRootResolver? = null,
    private val assistantTools: AndroidAssistantTaskExecutor? = null,
) {
    private fun reduce(op: String, fields: JSONObject, session: String? = null): JSONObject? =
        RishAgentCoreNative.preparedAttempt(
            JSONObject(fields.toString()).put("op", op), session)

    private fun value(value: Any?): Any = value ?: JSONObject.NULL

    /** The result the core shapes for a refusal the caller can recover from. */
    private fun conflict(request: JSONObject, code: String, observed: Any?): JSONObject =
        reduce("conflict", JSONObject().put("request", request)
            .put("failure_code", code).put("observed", value(observed)))
            ?.getJSONObject("result")
            ?: error("E_AGENT_CORRUPT: the core would not shape a $code conflict")

    private fun observed(request: JSONObject, load: JSONObject, conversation: Any?): Any {
        val snapshot = if (load.isNull("snapshot")) JSONObject.NULL
                       else load.getJSONObject("snapshot")
        val reply = reduce("observed", JSONObject().put("request", request)
            .put("snapshot", snapshot).put("conversation", value(conversation)))
        return reply?.opt("observed") ?: JSONObject.NULL
    }

    /**
     * The conversation the request names, read out of the committed session's
     * **exact bytes** — the rule is about those bytes, not about a value that
     * happens to encode to them. Answers null when the session cannot be read
     * as one the core recognises.
     */
    private fun conversation(load: JSONObject, request: JSONObject): Pair<Boolean, Any?> {
        if (load.isNull("session_json")) return false to null
        val sessionJson = load.optString("session_json")
        if (sessionJson.isEmpty()) return false to null
        val reply = reduce("session", JSONObject().put("request", request), sessionJson)
            ?: return false to null
        return true to (if (reply.isNull("conversation")) null else reply.opt("conversation"))
    }

    /** Thrown for the failures a caller cannot recover from by re-reading. */
    class Refused(val code: String) : RuntimeException(code)

    fun prepareAgentAttempt(request: JSONObject): JSONObject {
        val model = request.optString("model")
        val shape = reduce("request", JSONObject()
            .put("request", request)
            .put("model_supported", AndroidSessionEnvironment.isSupported(model))
            .put("harness_id", value(AndroidSessionEnvironment.harnessIdFor(model))))
            ?: throw Refused("E_AGENT_BAD_ARGUMENTS")

        // The controller CAS is a complete assertion over the stored
        // checkpoint. A disagreement is a conflict the caller recovers from by
        // re-reading, never a malformed request.
        if (!shape.optBoolean("checkpoint_relation")) {
            val load = sessions.load()
            val (_, conversation) = conversation(load, request)
            return conflict(request, "E_AGENT_CONFLICT", observed(request, load, conversation))
        }

        val load = sessions.load()
        if (load.optString("status") != "present" || load.isNull("snapshot")) {
            // Missing or unreadable storage is not an observed mismatch; it
            // stays a stable failure rather than inviting a retry loop.
            throw Refused("E_AGENT_CORRUPT")
        }
        val snapshot = load.getJSONObject("snapshot")
        val checkpoint = request.getJSONObject("committed_checkpoint")
        val (parsed, conversation) = conversation(load, request)
        if (snapshot.optLong("generation") != checkpoint.optLong("session_generation") ||
            snapshot.optString("session_sha256") != checkpoint.optString("session_sha256")) {
            return conflict(request, "E_AGENT_CONFLICT", observed(request, load, conversation))
        }
        if (snapshot.optInt("schema_version") != 1 || !parsed) {
            throw Refused(if (parsed) "E_AGENT_CONFLICT" else "E_AGENT_CORRUPT")
        }
        val seen = observed(request, load, conversation)
        val matches = reduce("session_matches", JSONObject().put("request", request)
            .put("conversation", value(conversation)))
        if (matches?.optBoolean("matches") != true) {
            return conflict(request, "E_AGENT_CONFLICT", seen)
        }
        val assistantContext = if (request.optInt("registry_version") == AndroidAssistantTaskExecutor.REGISTRY_VERSION) {
            try { assistantTools?.assistantContext(conversation as? JSONObject) }
            catch (failure: AndroidWorkspaceToolExecutor.Refused) { throw Refused(failure.code) }
                ?: return conflict(request, "E_AGENT_CONFLICT", seen)
        } else null

        // A root request is answered from the workspace registry. One that
        // names a project, or a binding this device cannot prove, is answered
        // the way iOS answers a root it can no longer prove.
        val rooted = !request.isNull("workspace_id") || !request.isNull("project_id") ||
            !request.isNull("workspace_binding_revision")
        val root = if (!rooted) null else roots?.resolve(
            request.optString("workspace_id").takeUnless { request.isNull("workspace_id") },
            request.optString("project_id").takeUnless { request.isNull("project_id") },
            if (request.isNull("workspace_binding_revision")) null
            else request.optInt("workspace_binding_revision", -1),
        ) ?: return conflict(request, "E_AGENT_ROOT_STALE", seen)

        // The registry and the policy are the root's, and both come from the
        // core. A rootless attempt is rejected before either is consulted, so
        // it carries the empty registry the core expects for one.
        val registry = if (root != null) {
            AndroidAgentToolRegistry.registryForRoot(root, request.getInt("registry_version"))
        } else {
            JSONObject()
                .put("schema_version", 2).put("registry_version", request.getInt("registry_version"))
                .put("toolset_sha256", AndroidAgentToolRegistry.toolsetSha256(request.getInt("registry_version")))
                .put("tools", JSONArray())
        }
        val policy = if (root != null) AndroidAgentToolRegistry.policyForRoot(root) else null
        val requestSha = RishAgentCoreNative.hash("agent-operation-request", JSONObject()
            .put("operation_kind", "prepare_agent_attempt").put("request", request))

        var published: JSONObject? = null
        var conflicted = false
        val committed = wal.transaction { state ->
            // Fresh identities and clock readings are host facts; the core
            // picks the first unused candidate. Four readings in the order the
            // row builders take them: transcript row, authority created_at,
            // authority updated_at, snapshot.
            val transcriptRefs = JSONArray().apply {
                repeat(16) { put(UUID.randomUUID().toString().lowercase()) }
            }
            val timestamps = JSONArray().apply { repeat(4) { put(AndroidClock.now()) } }
            val outcome = reduce("transaction", JSONObject()
                .put("request", request)
                .put("request_sha256", requestSha)
                .put("root", value(root))
                .put("policy", value(policy))
                .put("registry", registry)
                .put("toolset_sha256", registry.getString("toolset_sha256"))
                .put("operations", state.getJSONArray("operations"))
                .put("operation_results", state.getJSONArray("operation_results"))
                .put("authorities", state.getJSONArray("authorities"))
                .put("transcripts", state.getJSONArray("transcripts"))
                .put("transcript_refs", transcriptRefs)
                .put("timestamps", timestamps)
                .apply { if (assistantContext != null) put("assistant_context", assistantContext) })
            if (outcome == null) { conflicted = true; return@transaction false }
            when (outcome.optString("outcome")) {
                "conflict" -> { conflicted = true; return@transaction false }
                // A replay publishes what was committed then, and writes
                // nothing now.
                "replay" -> {
                    published = outcome.getJSONObject("result")
                    return@transaction false
                }
                "commit" -> Unit
                else -> error("E_AGENT_CORRUPT: unknown prepared-attempt outcome")
            }
            // Existing operation receipts remain replayable after a model is
            // retired. Only a newly committed attempt needs an active choice.
            if (!AndroidProviderConfiguration.isActiveModel(model)) throw Refused("E_AGENT_BAD_ARGUMENTS")
            if (!outcome.isNull("transcript")) {
                state.getJSONArray("transcripts").put(outcome.getJSONObject("transcript"))
            }
            if (!outcome.isNull("authority")) {
                state.getJSONArray("authorities").put(outcome.getJSONObject("authority"))
            }
            state.getJSONArray("operations").put(outcome.getJSONObject("operation"))
            state.getJSONArray("operation_results")
                .put(outcome.getJSONObject("operation_result"))
            published = outcome.getJSONObject("result")
            true
        }
        published?.let { return it }
        if (conflicted) return conflict(request, "E_AGENT_CONFLICT", seen)
        check(committed) { "E_AGENT_PERSISTENCE" }
        error("E_AGENT_PERSISTENCE: the transaction committed without a result")
    }

    /**
     * The prepared attempt a query reads: the stored authority as the core
     * projects it. The projection is the shape every caller outside this store
     * is allowed to see, and the generations are zero because a query asserts
     * none of its own.
     */
    fun preparedAttemptFor(taskId: String, attemptId: String): JSONObject? {
        val authority = authorityFor(taskId, attemptId) ?: return null
        return reduce(
            "projection",
            JSONObject().put("request", JSONObject()).put("authority", authority)
                .put("controller_generation", 0).put("journal_revision", 0),
        )?.optJSONObject("projection")
    }

    /** The stored authority for one attempt, or null. */
    fun authorityFor(taskId: String, attemptId: String): JSONObject? {
        val authorities = wal.snapshot().optJSONArray("authorities") ?: return null
        for (index in 0 until authorities.length()) {
            val authority = authorities.getJSONObject(index)
            if (authority.optString("task_id") == taskId &&
                authority.optString("attempt_id") == attemptId) return authority
        }
        return null
    }
}
