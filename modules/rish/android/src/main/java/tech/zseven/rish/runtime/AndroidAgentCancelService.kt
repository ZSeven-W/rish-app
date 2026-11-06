package tech.zseven.rish.runtime

import org.json.JSONObject

/**
 * `cancel_agent_attempt` on Android.
 *
 * Mirrors the cancelling half of modules/rish/ios/Sources/AgentRuntimeCoordinator.mm.
 * This is the stop button. Without it the controller writes a cancelled
 * journal, the native call refuses, and the turn ends visibly conflicted while
 * the round row it was cancelling is still claimed and still in flight.
 *
 * What may be cancelled, and what cancelling one thing means for the rest, is
 * the coordinator's: `cancel_plan` reads the live WAL and says whether this is
 * a round, a tool row, an attempt that never started, or nothing at all; each
 * branch has its own result rule; and `cancel_commit` produces the operation
 * commit that makes the answer durable. This file reads the stores, moves the
 * one row the plan names, and commits what comes back.
 *
 * **A cancellation is an operation like any other.** It is started before it
 * acts and committed after, so a repeat answers with what the first one
 * decided instead of cancelling twice.
 */
internal class AndroidAgentCancelService(
    private val wal: AndroidAgentWal,
    private val sessions: AndroidSessionStore,
    private val prepared: AndroidPreparedAttemptStore,
    private val ledger: AndroidAgentExecutionLedger,
    private val rounds: AndroidAgentProviderRoundService,
    private val roots: AndroidAgentRootResolver,
    private val operations: AndroidAgentOperations,
) {
    class Refused(val code: String) : Exception(code)

    private fun runtime(envelope: JSONObject): JSONObject {
        if (!RishAgentCoreNative.available) throw Refused(NATIVE)
        val reply = RishAgentCoreNative.runtimeReduce(envelope.toString()) ?: throw Refused(NATIVE)
        val parsed = JSONObject(reply)
        if (!parsed.optBoolean("ok")) {
            android.util.Log.w(
                "RishAgent",
                "cancel reduce refused: op=${envelope.optString("op")} error=${parsed.optInt("error", 2)}",
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

    fun cancel(request: JSONObject): JSONObject {
        runtime(
            JSONObject().put("op", "target_request").put("kind", "cancel")
                .put("request", request),
        )
        val target = request.optJSONObject("target") ?: throw Refused(BAD_ARGUMENTS)
        val taskId = target.opt("task_id")
        val attemptId = target.opt("attempt_id")
        val kind = "cancel_agent_attempt"
        val sha = operations.requestSha256(kind, request)
        val timestamp = AndroidClock.now()

        // An operation that exists but is no longer started has already
        // answered. Replay it rather than cancel twice.
        var replay: JSONObject? = null
        var found = false
        var recordRevision: Any? = null
        wal.transaction { state ->
            val query = operations.queryInState(state, request.opt("operation_id"), sha, taskId, attemptId)
            found = query.optString("status") == "found"
            val record = query.optJSONObject("record")
            recordRevision = record?.opt("authority_revision")
            if (found && record?.optString("state") != "started") {
                val replayed = operations.startTargetInState(
                    state, kind, request, target, recordRevision, timestamp,
                )
                replay = operations.settledResult(replayed)
            }
            false
        }
        replay?.let { return it }

        val session = loadSession() ?: throw Refused(PERSISTENCE)
        val proof = sessionProof(request, session)
        // A conflict is still an answer, and it is committed as one.
        val conflict = { failureCode: String ->
            runtime(
                JSONObject().put("op", "target_conflict").put("failure_code", failureCode)
                    .put("request", request).put("proof", proof),
            ).optJSONObject("output") ?: throw Refused(NATIVE)
        }
        // These three refuse before the operation exists, so they answer
        // directly. Committing a conflict needs something started to commit it
        // against, and starting one here would be the cancellation claiming to
        // have run.
        if (!proof.optBoolean("matches")) return conflict("E_AGENT_CONFLICT")
        // The proof says whether the session matches; it does not carry the
        // session. The rule that reads the cancel event needs the session
        // itself, and handing it the proof's absent `session` made every
        // cancellation unproved.
        val proves = runtime(
            JSONObject().put("op", "cancel_source_proof")
                .put("session", session.session).put("request", request),
        ).optBoolean("proves")
        if (!proves) {
            android.util.Log.w(
                "RishAgent",
                "cancel source unproved: token=${request.optJSONObject("cancel_token")}",
            )
            return conflict("E_AGENT_CANCELLED")
        }

        val authority = prepared.authorityFor(
            taskId as? String ?: "", attemptId as? String ?: "",
        )
        if (!preparedRootHolds(authority, request.opt("root"))) {
            return conflict("E_AGENT_ROOT_STALE")
        }
        if (authority == null) throw Refused(CONFLICT)

        var started: JSONObject? = null
        var startedReplay: JSONObject? = null
        wal.transaction { state ->
            val outcome = operations.startTargetInState(
                state, kind, request, target,
                if (found) recordRevision else authority.opt("authority_revision"),
                timestamp,
            )
            if (outcome.optString("status") == "replayed") {
                startedReplay = operations.settledResult(outcome)
            }
            started = outcome
            startedReplay == null
        }
        startedReplay?.let { return it }
        val startedOperation = started ?: throw Refused(PERSISTENCE)

        val plan = runtime(
            JSONObject().put("op", "cancel_plan").put("state", wal.snapshot())
                .put("request", request),
        )
        val result = when (plan.optString("plan")) {
            "round" -> cancelRound(request, target, plan, proof)
            "idle_attempt" -> {
                val pending = plan.optJSONArray("rows") ?: org.json.JSONArray()
                for (index in 0 until pending.length()) {
                    val row = pending.optJSONObject(index) ?: throw Refused(NATIVE)
                    val settled = ledger.cancel(executionCas(row), JSONObject().put("state", "cancelled"))
                        ?: throw Refused(CONFLICT)
                    settled.optJSONObject("row")?.optJSONObject("transcript_after")
                        ?.let { plan.put("transcript", it) } ?: throw Refused(NATIVE)
                }
                runtime(JSONObject().put("op", "cancel_idle_attempt_result")
                    .put("request", request).put("plan", plan)).optJSONObject("output")
                    ?: throw Refused(NATIVE)
            }
            "never_started" -> runtime(
                JSONObject().put("op", "cancel_never_started_result").put("request", request),
            ).optJSONObject("output") ?: throw Refused(NATIVE)
            "not_found" -> runtime(
                JSONObject().put("op", "cancel_not_found_result").put("request", request),
            ).optJSONObject("output") ?: throw Refused(NATIVE)
            "row" -> cancelRow(request, plan)
            else -> throw Refused(NATIVE)
        }
        return commit(request, startedOperation, result, timestamp)
    }

    private fun commit(
        request: JSONObject,
        started: JSONObject,
        result: JSONObject,
        timestamp: String,
    ): JSONObject {
        val decided = runtime(
            JSONObject().put("op", "cancel_commit").put("request", request)
                .put("started", started).put("settled", result),
        )
        val commit = decided.optJSONObject("commit") ?: throw Refused(NATIVE)
        var settled: JSONObject? = null
        wal.transaction { state ->
            settled = operations.settledResult(
                operations.commitDecidedInState(state, commit, timestamp),
            )
            true
        }
        return settled ?: result
    }

    /** Stops the round the plan names, through the service that owns it. */
    private fun cancelRound(
        request: JSONObject,
        target: JSONObject,
        plan: JSONObject,
        proof: JSONObject,
    ): JSONObject {
        val roundTarget = plan.optJSONObject("round_target") ?: throw Refused(NATIVE)
        val cancelled = rounds.cancelRound(
            JSONObject().put("schema_version", 2)
                .put("task_id", target.opt("task_id"))
                .put("attempt_id", target.opt("attempt_id"))
                .put("round_id", roundTarget.opt("round_id"))
                .put("round_index", roundTarget.opt("round_index"))
                .put("expected_round_revision", plan.opt("expected_round_revision"))
                .put("transcript", request.opt("expected_transcript"))
                .put("root", request.opt("root"))
                .put("cancel_token", request.optJSONObject("cancel_token")?.opt("token")),
        )
        return runtime(
            JSONObject().put("op", "cancel_round_result").put("request", request)
                .put("cancelled", cancelled).put("proof", proof),
        ).optJSONObject("output") ?: throw Refused(NATIVE)
    }

    /**
     * Moves one execution row.
     *
     * A row that has not been claimed is simply cancelled; a running one is
     * marked `cancel_requested`, because its effect may already be happening
     * and only the execution that owns it can say how it ended. Anything else
     * is past cancelling.
     */
    private fun cancelRow(request: JSONObject, plan: JSONObject): JSONObject {
        val row = plan.optJSONObject("row") ?: throw Refused(NATIVE)
        val cas = executionCas(row)
        val updated = when (plan.optString("state")) {
            "intent", "cancel_requested" ->
                ledger.cancel(cas, JSONObject().put("state", "cancelled"))?.optJSONObject("row")
            "running" ->
                ledger.cas(cas, JSONObject().put("state", "cancel_requested"))?.optJSONObject("row")
            else -> null
        } ?: throw Refused(CONFLICT)
        return runtime(
            JSONObject().put("op", "cancel_row_result").put("request", request)
                .put("updated", updated)
                .put("dispatched", dispatched(updated.optJSONObject("locator"))),
        ).optJSONObject("output") ?: throw Refused(NATIVE)
    }

    /** The CAS a coordinator asserts over an execution row it is moving. */
    private fun executionCas(row: JSONObject): JSONObject {
        val raw = RishAgentCoreNative.toolExecutionReduce(JSONObject().put("op", "execution_cas")
            .put("request", JSONObject()).put("row", row).put("state", row.getString("state")).toString())
            ?: throw Refused(NATIVE)
        val reply = JSONObject(raw)
        if (!reply.optBoolean("ok")) throw Refused(codeFor(reply.optInt("error", 2)))
        return reply.optJSONObject("cas") ?: throw Refused(NATIVE)
    }

    /** Whether the row's effect was already handed to the executor. */
    private fun dispatched(locator: JSONObject?): Boolean {
        val markers = wal.snapshot().optJSONArray("dispatch") ?: return false
        for (index in 0 until markers.length()) {
            val marker = markers.optJSONObject(index) ?: continue
            if (marker.optString("kind") == "execution" &&
                AndroidJson.equal(marker.opt("locator"), locator)
            ) {
                return marker.optString("dispatch_state") == "dispatched"
            }
        }
        return false
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

    /**
     * Whether the session still says what the cancellation was built against.
     * A cancellation names its attempt in `target` and its conversation in the
     * controller CAS, so the flat request the proof reads is assembled from
     * both.
     */
    private fun sessionProof(request: JSONObject, loaded: Loaded): JSONObject {
        val cas = request.optJSONObject("controller_cas") ?: JSONObject()
        val checkpoint = request.optJSONObject("committed_checkpoint") ?: JSONObject()
        val target = request.optJSONObject("target") ?: JSONObject()
        val reply = runtime(
            JSONObject().put("op", "session_proof")
                .put("session", loaded.session).put("facts", loaded.facts)
                .put(
                    "request",
                    JSONObject()
                        .put("conversation_id", cas.opt("conversation_id"))
                        .put("task_id", target.opt("task_id"))
                        .put("attempt_id", target.opt("attempt_id"))
                        .put(
                            "expected_controller_generation",
                            cas.opt("expected_controller_generation"),
                        )
                        .put("expected_journal_revision", cas.opt("expected_journal_revision"))
                        .put("expected_session_generation", checkpoint.opt("session_generation"))
                        .put("expected_session_sha256", checkpoint.opt("session_sha256")),
                ),
        )
        return reply.optJSONObject("proof") ?: throw Refused(NATIVE)
    }

    private fun preparedRootHolds(authority: JSONObject?, root: Any?): Boolean {
        val frozen = authority?.optJSONObject("root") ?: return false
        val canonical = { value: Any? ->
            (value as? JSONObject)?.let { RishAgentCoreNative.canonical(it.toString()) }
        }
        if (canonical(frozen) == null || canonical(frozen) != canonical(root)) return false
        return roots.resolveAgentProjection(frozen) != null
    }

    private companion object {
        const val NATIVE = "E_AGENT_NATIVE"
        const val CONFLICT = "E_AGENT_CONFLICT"
        const val BAD_ARGUMENTS = "E_AGENT_BAD_ARGUMENTS"
        const val PERSISTENCE = "E_AGENT_PERSISTENCE"
    }
}
