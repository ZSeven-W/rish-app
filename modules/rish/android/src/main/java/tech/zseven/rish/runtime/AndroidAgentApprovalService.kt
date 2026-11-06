package tech.zseven.rish.runtime

import org.json.JSONArray
import org.json.JSONObject

/**
 * `bind_agent_approval` on Android.
 *
 * Mirrors the binding half of modules/rish/ios/Sources/AgentToolBatchService.mm.
 * This is the step between a person deciding and a tool running: the batch
 * minted an approval token, the controller showed the call, the person said
 * allow or deny, and this binds that decision to the exact call it was made
 * about -- or refuses, because the world moved while they were reading it.
 *
 * It owns no rules. `bind_request` says whether the request relates its own
 * token to its own batch; `bind_check` reads the persisted decision, the
 * session event that recorded it, the token the batch minted, the authority
 * and the ledger, and answers either a conflict or exactly what to write.
 * Collecting those facts and writing the result is all this file does.
 *
 * **A denial is an effect, not a note.** When the person refuses, the call's
 * never-dispatched intent row is settled with a denied receipt and the model
 * is shown the protected feedback saying so -- in the same transaction that
 * records the bind. Anything less and a kill between the two steps would lose
 * the refusal, and the next round would ask the model to try the call again.
 *
 * The whole decision runs inside one WAL transaction. iOS takes several and
 * revalidates between them; here the state never leaves the transaction that
 * decided over it, so the revalidation it needs is the authority re-read
 * below, which guards against nothing else in this process having changed the
 * authority between the check and the settlement.
 */
internal class AndroidAgentApprovalService(
    private val wal: AndroidAgentWal,
    private val sessions: AndroidSessionStore,
    private val ledger: AndroidAgentExecutionLedger,
    private val operations: AndroidAgentOperations,
    private val roots: AndroidAgentRootResolver,
) {
    class Refused(val code: String) : Exception(code)

    /** A decision, and whether the state it was taken over must be written. */
    private class Decided(val result: JSONObject, val write: Boolean)

    private fun decide(envelope: JSONObject): JSONObject {
        if (!RishAgentCoreNative.available) throw Refused(NATIVE)
        val reply = RishAgentCoreNative.toolBatchReduce(envelope.toString()) ?: throw Refused(NATIVE)
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
     * Whether the root the authority was prepared against still proves out on
     * this device. The registry is the only thing that can say so, and a
     * binding revision that has moved is a different root, not a stale copy of
     * this one.
     */
    private fun rootStillProves(authority: JSONObject?): Boolean =
        roots.resolveAgentProjection(authority?.optJSONObject("root")) != null

    fun bind(request: JSONObject): JSONObject {
        // Shape and the request's internal token relation first. A request
        // that does not relate its own token to its own batch never reaches
        // the operation relation, let alone a decision.
        val tokenRelationValid = decide(
            JSONObject().put("op", "bind_request").put("request", request),
        ).optBoolean("token_relation_valid")

        // The session is a different store. It is read before the transaction
        // opens so that transaction holds one lock rather than two.
        val session = AndroidCommittedSession.load(sessions, request)
        val conversation = if (!tokenRelationValid) null else {
            AndroidCommittedSession.conversation(session, request)
        }
        val events = AndroidCommittedSession.events(session)

        val timestamp = RuntimeJson.now()
        var decided: Decided? = null
        var refusal: String? = null
        val committed = wal.transaction { state ->
            try {
                decided = decided(state, request, tokenRelationValid, conversation, events, timestamp)
                decided?.write == true
            } catch (refused: Refused) {
                refusal = refused.code
                false
            } catch (refused: AndroidAgentOperations.Refused) {
                refusal = refused.code
                false
            } catch (refused: AndroidAgentExecutionLedger.Refused) {
                refusal = codeFor(refused.code)
                false
            }
        }
        refusal?.let { throw Refused(it) }
        val answer = decided ?: throw Refused(PERSISTENCE)
        // A replay writes nothing and still has an answer. Only a decision
        // that asked to be written and was not is a persistence failure.
        if (answer.write && !committed) throw Refused(PERSISTENCE)
        return answer.result
    }

    private fun decided(
        state: JSONObject,
        request: JSONObject,
        tokenRelationValid: Boolean,
        conversation: JSONObject?,
        events: JSONArray,
        timestamp: String,
    ): Decided {
        val authority = authorityIn(state, request)

        // Started before the relationship checks below, so a conflict is
        // committed against this operation id and replays as the same
        // conflict rather than being re-decided over a newer world.
        val started = operations.startInState(
            state, "bind_agent_approval", request,
            authority?.opt("authority_revision"), timestamp,
        )
        if (started.optString("status") == "replayed") {
            operations.settledResult(started)?.let { return Decided(it, false) }
        }
        val requestSha = started.opt("request_sha256")

        // Read the session again: one that moved while this was being decided
        // is not the session the person's decision was made against.
        val sessionOkAfter = tokenRelationValid &&
            AndroidCommittedSession.conversation(
                AndroidCommittedSession.load(sessions, request), request,
            ) != null

        val check = decide(
            JSONObject().put("op", "bind_check").put("request", request)
                .put("token_relation_valid", tokenRelationValid)
                .put("conversation", conversation ?: JSONObject.NULL)
                .put("events", events)
                .put("operation_results", state.optJSONArray("operation_results") ?: JSONArray())
                .put("authority", authority ?: JSONObject.NULL)
                .put("batches", state.optJSONArray("batches") ?: JSONArray())
                .put("ledger", state.optJSONArray("ledger") ?: JSONArray())
                .put("root_ok", rootStillProves(authority))
                .put("session_ok_after", sessionOkAfter),
        )

        check.optJSONObject("conflict")?.let { conflict ->
            val commit = operations.commitInState(
                state, request.opt("operation_id"), requestSha,
                request.opt("task_id"), request.opt("attempt_id"),
                "conflict", "conflict",
                JSONObject().put("schema_version", 2).put("kind", "none"), null,
                operations.safeResult("bind_agent_approval", conflict), timestamp,
            )
            return Decided(operations.settledResult(commit) ?: conflict, true)
        }

        val proceed = check.optJSONObject("proceed") ?: throw Refused(NATIVE)
        val result = proceed.optJSONObject("result") ?: throw Refused(NATIVE)
        val resultRef = proceed.optJSONObject("result_ref") ?: throw Refused(NATIVE)

        if (!proceed.optBoolean("denied_fresh")) {
            val commit = operations.commitInState(
                state, request.opt("operation_id"), requestSha,
                request.opt("task_id"), request.opt("attempt_id"),
                "committed", result.optString("status"),
                resultRef, request.opt("batch_revision"),
                operations.safeResult("bind_agent_approval", result), timestamp,
            )
            return Decided(operations.settledResult(commit) ?: result, true)
        }

        // A fresh denial. The authority is read again rather than the copy
        // above being trusted: the row about to be settled must still be the
        // exact intent the person was shown.
        val live = authorityIn(state, request) ?: throw Refused(CONFLICT)
        if (!AndroidJson.equal(live.opt("root"), authority?.opt("root")) ||
            !AndroidJson.equal(live.opt("policy"), authority?.opt("policy")) ||
            !AndroidJson.equal(
                live.opt("reserved_write_bytes"), authority?.opt("reserved_write_bytes"),
            )
        ) {
            throw Refused(CONFLICT)
        }
        val feedback = proceed.optString("feedback_json").takeIf { it.isNotEmpty() }
            ?: throw Refused(NATIVE)
        val settlement = ledger.settleDeniedApprovalInState(
            state,
            proceed.optJSONObject("intent_locator") ?: throw Refused(NATIVE),
            live.optJSONObject("root") ?: throw Refused(CONFLICT),
            live.optJSONObject("transcript") ?: throw Refused(CONFLICT),
            live.optJSONObject("policy") ?: throw Refused(CONFLICT),
            live.opt("reserved_write_bytes"), feedback, timestamp,
        ) ?: throw Refused(CONFLICT)

        val settled = JSONObject(result.toString())
            .put("receipt", settlement.opt("receipt") ?: JSONObject.NULL)
            .put("transcript", settlement.opt("transcript") ?: JSONObject.NULL)
        val commit = operations.commitInState(
            state, request.opt("operation_id"), requestSha,
            request.opt("task_id"), request.opt("attempt_id"),
            "committed", "bound", resultRef, request.opt("batch_revision"),
            operations.safeResult("bind_agent_approval", settled), timestamp,
        )
        return Decided(operations.settledResult(commit) ?: settled, true)
    }

    private companion object {
        const val NATIVE = "E_AGENT_NATIVE"
        const val CONFLICT = "E_AGENT_CONFLICT"
        const val PERSISTENCE = "E_AGENT_PERSISTENCE"
    }
}
