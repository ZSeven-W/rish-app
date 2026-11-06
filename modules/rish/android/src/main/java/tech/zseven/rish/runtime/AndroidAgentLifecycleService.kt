package tech.zseven.rish.runtime

import org.json.JSONArray
import org.json.JSONObject

/**
 * `finalize_agent_attempt` and `discard_agent_attempt` on Android.
 *
 * Mirrors the settling half of modules/rish/ios/Sources/AgentRuntimeCoordinator.mm.
 * These are how a turn *ends*. Finalizing settles the attempt's authority and
 * hands back the proof the controller writes into the session; discarding
 * clears the durable residue the attempt left behind. The controller calls
 * both, in that order, on every completed turn -- so without them an agent can
 * run every tool it likes and still never finish.
 *
 * The rules are entirely the coordinator's: `settle_request` checks the shape,
 * `session_proof` relates the request to the committed session,
 * `finalize_transaction` and `residue_discard` produce both the state changes
 * and the operation commit, and `finalize_conflict` and `already_missing`
 * produce the refusals. This file reads the two stores, holds the transaction,
 * and applies what comes back.
 *
 * **A refusal is committed too.** A finalize that loses a race does not just
 * throw: once its operation exists, the conflict is written against it, so a
 * retry is answered with the same conflict instead of racing again.
 */
internal class AndroidAgentLifecycleService(
    private val wal: AndroidAgentWal,
    private val sessions: AndroidSessionStore,
    private val operations: AndroidAgentOperations,
    private val roots: AndroidAgentRootResolver,
) {
    class Refused(val code: String) : Exception(code)

    private fun runtime(envelope: JSONObject): JSONObject {
        if (!RishAgentCoreNative.available) throw Refused(NATIVE)
        val reply = RishAgentCoreNative.runtimeReduce(envelope.toString()) ?: throw Refused(NATIVE)
        val parsed = JSONObject(reply)
        if (!parsed.optBoolean("ok")) throw Refused(codeFor(parsed.optInt("error", 2)))
        return parsed
    }

    private fun codeFor(error: Int): String = when (error) {
        1 -> "E_AGENT_BAD_ARGUMENTS"
        3 -> "E_AGENT_CONFLICT"
        4 -> "E_AGENT_PERSISTENCE"
        5 -> "E_AGENT_NOT_FOUND"
        else -> NATIVE
    }

    /** The committed session and the facts that name which one it is. */
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
     * Whether the session still says what the request was built against. The
     * proof carries the session itself, because the ops below read it.
     */
    private fun sessionProof(request: JSONObject, loaded: Loaded): JSONObject {
        val cas = request.optJSONObject("controller_cas") ?: JSONObject()
        val checkpoint = request.optJSONObject("committed_checkpoint") ?: JSONObject()
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
                        .put("expected_session_generation", checkpoint.opt("session_generation"))
                        .put("expected_session_sha256", checkpoint.opt("session_sha256")),
                ),
        )
        return reply.optJSONObject("proof") ?: throw Refused(NATIVE)
    }

    private fun authorityIn(state: JSONObject, request: JSONObject): JSONObject? {
        val authorities = state.optJSONArray("authorities") ?: return null
        for (index in 0 until authorities.length()) {
            val candidate = authorities.optJSONObject(index) ?: continue
            if (AndroidJson.equal(candidate.opt("task_id"), request.opt("task_id")) &&
                AndroidJson.equal(candidate.opt("attempt_id"), request.opt("attempt_id"))
            ) {
                return candidate
            }
        }
        return null
    }

    /**
     * The frozen root the authority holds must be the one the request names,
     * and it must still prove out against this device's registry. A binding
     * that moved is a different root, not an older copy of this one.
     */
    private fun preparedRootHolds(authority: JSONObject?, root: Any?): Boolean {
        val frozen = authority?.optJSONObject("root") ?: return false
        val canonical = { value: Any? ->
            (value as? JSONObject)?.let { RishAgentCoreNative.canonical(it.toString()) }
        }
        if (canonical(frozen) == null || canonical(frozen) != canonical(root)) return false
        return roots.resolveAgentProjection(frozen) != null
    }

    // MARK: - finalize

    fun finalize(request: JSONObject): JSONObject {
        runtime(
            JSONObject().put("op", "settle_request").put("kind", "finalize")
                .put("request", request),
        )
        val kind = "finalize_agent_attempt"
        val sha = operations.requestSha256(kind, request)
        val loaded = loadSession() ?: throw Refused(PERSISTENCE)
        val proof = sessionProof(request, loaded)
        val timestamp = AndroidClock.now()

        var output: JSONObject? = null
        var refusal: String? = null
        val committed = wal.transaction { state ->
            try {
                output = finalizeIn(state, request, kind, sha, proof, timestamp)
                output != null && wroteSomething
            } catch (refused: Refused) {
                refusal = refused.code; false
            } catch (refused: AndroidAgentOperations.Refused) {
                refusal = refused.code; false
            }
        }
        refusal?.let { throw Refused(it) }
        val result = output ?: throw Refused(PERSISTENCE)
        if (wroteSomething && !committed) throw Refused(PERSISTENCE)
        return result
    }

    /** Whether the last decision asked for the state to be written. */
    private var wroteSomething: Boolean = false

    private fun finalizeIn(
        state: JSONObject,
        request: JSONObject,
        kind: String,
        sha: String,
        proof: JSONObject,
        timestamp: String,
    ): JSONObject {
        wroteSomething = false
        val query = operations.queryInState(
            state, request.opt("operation_id"), sha,
            request.opt("task_id"), request.opt("attempt_id"),
        )
        val found = query.optString("status") == "found"
        val record = query.optJSONObject("record")
        if (found && record?.optString("state") != "started") {
            // Already terminal: the relation answers with what it decided.
            val replay = operations.startInState(
                state, kind, request, record?.opt("authority_revision"), timestamp,
            )
            return operations.settledResult(replay) ?: throw Refused(CONFLICT)
        }

        // A refused finalize still commits its conflict once the operation
        // exists, so a retry sees the same answer rather than racing again.
        val refuse = { failureCode: String ->
            if (!found) {
                JSONObject().put("schema_version", 2).put("status", "conflict")
                    .put("operation_id", request.opt("operation_id"))
                    .put("failure_code", failureCode)
            } else {
                val decided = runtime(
                    JSONObject().put("op", "finalize_conflict")
                        .put("failure_code", failureCode).put("request", request)
                        .put(
                            "started",
                            JSONObject().put(
                                "request_sha256",
                                record?.opt("request_sha256") ?: JSONObject.NULL,
                            ),
                        ),
                )
                operations.commitDecidedInState(
                    state, decided.optJSONObject("commit") ?: throw Refused(NATIVE), timestamp,
                )
                wroteSomething = true
                decided.optJSONObject("output") ?: throw Refused(NATIVE)
            }
        }

        if (!proof.optBoolean("matches")) return refuse("E_AGENT_CONFLICT")
        val authority = authorityIn(state, request)
        if (!preparedRootHolds(authority, request.opt("root"))) return refuse("E_AGENT_ROOT_STALE")
        if (authority == null) throw Refused(CONFLICT)

        val started = operations.startInState(
            state, kind, request,
            if (found) record?.opt("authority_revision") else authority.opt("authority_revision"),
            timestamp,
        )
        if (started.optString("status") == "replayed") {
            operations.settledResult(started)?.let { return it }
        }
        wroteSomething = true

        val decided = runtime(
            JSONObject().put("op", "finalize_transaction").put("state", state)
                .put("request", request).put("started", started)
                .put("timestamp", timestamp)
                .put("retention_until", AndroidClock.nowAdding(RETENTION_SECONDS)),
        )
        if (decided.optString("result") != "settle") {
            // The core refused over the live state. That is a conflict, and it
            // is committed as one so the retry is answered rather than raced.
            return refuse("E_AGENT_CONFLICT")
        }
        applyChanges(state, decided.optJSONObject("changes"))
        operations.commitDecidedInState(
            state, decided.optJSONObject("commit") ?: throw Refused(NATIVE), timestamp,
        )
        return decided.optJSONObject("output") ?: throw Refused(NATIVE)
    }

    // MARK: - discard

    fun discard(request: JSONObject): JSONObject = settleResidue(
        request, "discard", "discard_agent_attempt", JSONArray(),
    )

    /**
     * `interrupt_agent_attempt`: the same residue settlement as a discard, for
     * an attempt whose process went away.
     *
     * This is how the controller drains its cleanup outbox. An entry stays
     * durable until this answers, so while the operation refused, every
     * interrupted attempt left one behind and the next launch tried again.
     *
     * The two differences from a discard are the proof and the effects: the
     * session has to say this attempt really was interrupted, and the
     * settlement also closes undispatched intents and unsettled rounds and
     * writes the cleanup row.
     */
    fun interrupt(request: JSONObject): JSONObject {
        runtime(
            JSONObject().put("op", "settle_request").put("kind", "interrupt")
                .put("request", request),
        )
        val session = loadSession() ?: throw Refused(PERSISTENCE)
        val proves = runtime(
            JSONObject().put("op", "interruption_proof")
                .put("session", session.session).put("facts", session.facts)
                .put("request", request),
        ).optBoolean("proves")
        if (!proves) throw Refused(CONFLICT)
        return settleResidue(
            request, "interrupt", "interrupt_agent_attempt",
            JSONArray().put("undispatched_intents").put("create_cleanup_row")
                .put("unsettled_rounds"),
            validated = true,
        )
    }

    private fun settleResidue(
        request: JSONObject,
        authorityKind: String,
        kind: String,
        options: JSONArray,
        validated: Boolean = false,
    ): JSONObject {
        if (!validated) {
            runtime(
                JSONObject().put("op", "settle_request").put("kind", authorityKind)
                    .put("request", request),
            )
        }
        val sha = operations.requestSha256(kind, request)
        val timestamp = AndroidClock.now()
        val session = loadSession()

        var output: JSONObject? = null
        var refusal: String? = null
        val committed = wal.transaction { state ->
            try {
                output = discardIn(
                    state, request, kind, authorityKind, options, sha, session, timestamp,
                )
                output != null && wroteSomething
            } catch (refused: Refused) {
                refusal = refused.code; false
            } catch (refused: AndroidAgentOperations.Refused) {
                refusal = refused.code; false
            }
        }
        refusal?.let { throw Refused(it) }
        val result = output ?: throw Refused(PERSISTENCE)
        if (wroteSomething && !committed) throw Refused(PERSISTENCE)
        return result
    }

    private fun discardIn(
        state: JSONObject,
        request: JSONObject,
        kind: String,
        authorityKind: String,
        options: JSONArray,
        sha: String,
        session: Loaded?,
        timestamp: String,
    ): JSONObject {
        wroteSomething = false
        val query = operations.queryInState(
            state, request.opt("operation_id"), sha,
            request.opt("task_id"), request.opt("attempt_id"),
        )
        val found = query.optString("status") == "found"
        val record = query.optJSONObject("record")
        if (found && record?.optString("state") != "started") {
            val replay = operations.startInState(
                state, kind, request, record?.opt("authority_revision"), timestamp,
            )
            return operations.settledResult(replay) ?: throw Refused(CONFLICT)
        }

        val authorityState = runtime(
            JSONObject().put("op", "settle_authority_state").put("kind", authorityKind)
                .put("state", state).put("request", request),
        )
        if (authorityState.isNull("authority")) {
            // Nothing durable is left. That is only a clean close if the core
            // agrees the cleanup this request names is the discarded one, and
            // the session's outbox agrees too.
            val closes = runtime(
                JSONObject().put("op", "exact_discarded_cleanup")
                    .put("state", state).put("request", request),
            ).optBoolean("proves")
            val outbox = session != null && runtime(
                JSONObject().put("op", "cleanup_outbox_proof")
                    .put("session", session.session).put("request", request),
            ).optBoolean("proves")
            if (!closes || !outbox) throw Refused(CONFLICT)
            return alreadyMissing(state, request, kind, record, found, timestamp)
        }
        if (!authorityState.optBoolean("settles")) throw Refused(CONFLICT)

        val authority = authorityState.optJSONObject("authority")
        val started = operations.startInState(
            state, kind, request,
            if (found) record?.opt("authority_revision") else authority?.opt("authority_revision"),
            timestamp,
        )
        if (started.optString("status") == "replayed") {
            operations.settledResult(started)?.let { return it }
        }
        wroteSomething = true

        val decided = runtime(
            JSONObject().put("op", "residue_discard").put("kind", kind)
                .put("options", options).put("state", state)
                .put("request", request).put("started", started)
                .put("timestamp", timestamp),
        )
        if (decided.optString("result") != "settle") throw Refused(CONFLICT)
        applyChanges(state, decided.optJSONObject("changes"))
        operations.commitDecidedInState(
            state, decided.optJSONObject("commit") ?: throw Refused(NATIVE), timestamp,
        )
        return decided.optJSONObject("output") ?: throw Refused(NATIVE)
    }

    /** Closes a command whose durable residue is already gone. */
    private fun alreadyMissing(
        state: JSONObject,
        request: JSONObject,
        kind: String,
        record: JSONObject?,
        found: Boolean,
        timestamp: String,
    ): JSONObject {
        val started = operations.startInState(
            state, kind, request, if (found) record?.opt("authority_revision") else 0, timestamp,
        )
        if (started.optString("status") == "replayed") {
            operations.settledResult(started)?.let { return it }
        }
        wroteSomething = true
        val decided = runtime(
            JSONObject().put("op", "already_missing").put("kind", kind)
                .put("request", request).put("started", started),
        )
        operations.commitDecidedInState(
            state, decided.optJSONObject("commit") ?: throw Refused(NATIVE), timestamp,
        )
        return decided.optJSONObject("output") ?: throw Refused(NATIVE)
    }

    /** `changes` names whole top-level tables to replace. */
    private fun applyChanges(state: JSONObject, changes: JSONObject?) {
        val tables = changes ?: return
        for (name in tables.keys()) state.put(name, tables.get(name))
    }

    private companion object {
        const val NATIVE = "E_AGENT_NATIVE"
        const val CONFLICT = "E_AGENT_CONFLICT"
        const val PERSISTENCE = "E_AGENT_PERSISTENCE"
        const val RETENTION_SECONDS = 7L * 24 * 60 * 60
    }
}
