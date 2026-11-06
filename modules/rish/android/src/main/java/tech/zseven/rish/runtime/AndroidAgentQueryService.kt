package tech.zseven.rish.runtime

import org.json.JSONObject

/**
 * `query_agent_attempt` on Android.
 *
 * Mirrors `queryAgentAttempt` in modules/rish/ios/Sources/AgentRuntimeCoordinator.mm.
 * It answers what the durable state says about one attempt: which round or
 * tool call it is on, whether that row is still owned by a live writer, and
 * what a controller that has just been restarted should do about it. Nothing
 * here writes -- a query that changed the thing it reports would be a poor
 * thing to recover from.
 *
 * Every decision is the coordinator's. `query_attempt_request` checks the
 * shape, the session proof relates the request to the committed session,
 * `query_attempt_session_conflict` and `query_attempt_base_conflict` produce
 * the two refusals, and `query_attempt_projection` reads the WAL snapshot and
 * builds the answer. This file supplies the session, the prepared attempt and
 * the snapshot.
 */
internal class AndroidAgentQueryService(
    private val wal: AndroidAgentWal,
    private val sessions: AndroidSessionStore,
    private val prepared: AndroidPreparedAttemptStore,
    private val ledger: AndroidAgentExecutionLedger,
    private val transcripts: AndroidAgentTranscriptStore,
) {
    class Refused(val code: String) : Exception(code)

    private fun runtime(envelope: JSONObject): JSONObject {
        if (!RishAgentCoreNative.available) throw Refused(NATIVE)
        val reply = RishAgentCoreNative.runtimeReduce(envelope.toString()) ?: throw Refused(NATIVE)
        val parsed = JSONObject(reply)
        if (!parsed.optBoolean("ok")) {
            android.util.Log.w(
                "RishAgent",
                "query reduce refused: op=${envelope.optString("op")} error=${parsed.optInt("error", 2)}",
            )
            throw Refused(codeFor(parsed.optInt("error", 2)))
        }
        return parsed
    }

    private fun codeFor(error: Int): String = when (error) {
        1 -> "E_AGENT_BAD_ARGUMENTS"
        3 -> "E_AGENT_CONFLICT"
        4 -> "E_AGENT_PERSISTENCE"
        5 -> "E_AGENT_NOT_FOUND"
        else -> NATIVE
    }

    /** Same read-only request and ownership gate as the iOS coordinator. */
    fun readRoundPresentations(request: JSONObject): JSONObject = synchronized(sessions) {
        runtime(JSONObject().put("op", "presentations_request").put("request", request))
        val loaded = loadSession() ?: throw Refused("E_AGENT_UNAVAILABLE")
        val owns = runtime(JSONObject().put("op", "session_owns_attempt")
            .put("session", loaded.session).put("request", request)).optBoolean("owns")
        if (!owns) throw Refused("E_AGENT_NOT_FOUND")
        transcripts.roundPresentations(request.getString("conversation_id"), request.getString("attempt_id"))
    }

    fun query(request: JSONObject): JSONObject {
        runtime(JSONObject().put("op", "query_attempt_request").put("request", request))
        val loaded = loadSession() ?: throw Refused(PERSISTENCE)
        val proof = sessionProof(request, loaded)
        runtime(
            JSONObject().put("op", "query_attempt_session_conflict")
                .put("request", request).put("proof", proof),
        ).optJSONObject("output")?.let { return it }

        // An attempt this device never prepared is not found rather than
        // conflicted: there is nothing here to have a stale view of.
        val base = prepared.preparedAttemptFor(
            request.optString("task_id"), request.optString("attempt_id"),
        ) ?: return JSONObject().put("schema_version", 2).put("status", "not_found")
            .put("failure_code", "E_AGENT_NOT_FOUND")

        val state = wal.snapshot()
        runtime(
            JSONObject().put("op", "query_attempt_base_conflict")
                .put("request", request).put("proof", proof).put("base", base).put("state", state),
        ).optJSONObject("output")?.let { return it }

        return runtime(
            JSONObject().put("op", "query_attempt_projection")
                .put("request", request).put("proof", proof).put("base", base)
                .put("state", state),
        ).optJSONObject("output") ?: throw Refused(NATIVE)
    }

    /**
     * `query_agent_tool`: what the ledger says about one call.
     *
     * A session that has moved and a ledger row that will not bind to the
     * transcript or the root are two different refusals, and the core shapes
     * both from the live state rather than this file guessing which applies.
     */
    fun queryTool(request: JSONObject): JSONObject {
        val locator = runtime(
            JSONObject().put("op", "query_tool_request").put("request", request),
        ).optJSONObject("locator") ?: throw Refused(BAD_ARGUMENTS)
        val loaded = loadSession() ?: throw Refused(PERSISTENCE)
        val proof = sessionProof(request, loaded)
        if (!proof.optBoolean("matches")) {
            return runtime(
                JSONObject().put("op", "query_tool_session_conflict")
                    .put("state", wal.snapshot()).put("request", request),
            ).optJSONObject("output") ?: throw Refused(NATIVE)
        }
        val queried = ledger.query(
            locator,
            request.optJSONObject("expected_transcript"),
            JSONObject().put("schema_version", 1)
                .put(
                    "root_fingerprint_sha256",
                    request.opt("expected_root_fingerprint_sha256"),
                )
                .put("binding_revision", request.opt("expected_workspace_binding_revision")),
        ) ?: return runtime(
            // The ledger refused to bind the row. Which row, and to what, is
            // the core's answer over the live state.
            JSONObject().put("op", "query_tool_ledger_conflict")
                .put("state", wal.snapshot()).put("request", request),
        ).optJSONObject("output") ?: throw Refused(NATIVE)
        return runtime(
            JSONObject().put("op", "query_tool_result")
                .put("queried", queried).put("request", request),
        ).optJSONObject("output") ?: throw Refused(NATIVE)
    }

    /**
     * `query_agent_cleanup`: whether a discarded attempt's transcript residue
     * is gone yet. The controller drains its cleanup outbox by asking, and an
     * operation that always refused left those entries accumulating.
     */
    fun queryCleanup(request: JSONObject): JSONObject {
        val cleanupId = request.opt("cleanup_id")
        if (request.keys().asSequence().toSet() != setOf("schema_version", "cleanup_id") ||
            request.optInt("schema_version", 0) != 2 ||
            cleanupId !is String
        ) {
            throw Refused(BAD_ARGUMENTS)
        }
        val result = transcripts.queryCleanup(
            JSONObject().put("schema_version", 1).put("cleanup_id", cleanupId),
        ) ?: throw Refused(PERSISTENCE)
        return JSONObject().put("schema_version", 2)
            .put("status", result.opt("status")).put("cleanup_id", cleanupId)
    }

    private class Loaded(val session: JSONObject, val facts: JSONObject)

    private fun loadSession(): Loaded? {
        val loaded = sessions.load()
        if (loaded.optString("status") != "present") return null
        val snapshot = loaded.optJSONObject("snapshot") ?: return null
        val json = loaded.opt("session_json") as? String ?: return null
        val session = try {
            JSONObject(json)
        } catch (_: org.json.JSONException) {
            return null
        }
        return Loaded(
            session,
            JSONObject().put("session_generation", snapshot.opt("generation"))
                .put("session_sha256", snapshot.opt("session_sha256")),
        )
    }

    private fun sessionProof(request: JSONObject, loaded: Loaded): JSONObject {
        val cas = request.optJSONObject("controller_cas") ?: JSONObject()
        val reply = runtime(
            JSONObject().put("op", "session_proof")
                .put("session", loaded.session).put("facts", loaded.facts)
                .put(
                    "request",
                    JSONObject()
                        .put("conversation_id", request.opt("conversation_id"))
                        .put("task_id", request.opt("task_id"))
                        .put("attempt_id", request.opt("attempt_id"))
                        .put(
                            "expected_controller_generation",
                            cas.opt("expected_controller_generation"),
                        )
                        .put("expected_journal_revision", cas.opt("expected_journal_revision"))
                        .put(
                            "expected_session_generation",
                            cas.opt("expected_session_generation"),
                        )
                        .put("expected_session_sha256", cas.opt("expected_session_sha256")),
                ),
        )
        return reply.optJSONObject("proof") ?: throw Refused(NATIVE)
    }

    private companion object {
        const val NATIVE = "E_AGENT_NATIVE"
        const val PERSISTENCE = "E_AGENT_PERSISTENCE"
        const val BAD_ARGUMENTS = "E_AGENT_BAD_ARGUMENTS"
    }
}
