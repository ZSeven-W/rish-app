package tech.zseven.rish.runtime

import org.json.JSONObject

/**
 * The native operation relation, as a facade over `rish_agent_wal_operation_reduce`.
 *
 * Mirrors `DSHAgentNativeWALStartOperation` and `DSHAgentNativeWALCommitOperation`.
 * Every agent operation that changes anything writes a record saying it
 * started, and later the result it settled with. That record is what makes a
 * repeat a *replay*: a controller that asks again after a kill, a restart or a
 * dropped promise gets back the answer that was already decided instead of
 * running the effect a second time.
 *
 * Opening the transaction and holding the state is the host's job here; which
 * record may be written, when a request counts as the same request, and what a
 * replay answers are all the core's. In particular this file never computes
 * the request digest -- the core derives it from the operation kind, so two
 * hosts cannot disagree about whether two requests are the same one.
 */
internal class AndroidAgentOperations(private val wal: AndroidAgentWal) {

    class Refused(val code: String) : Exception(code)

    private fun reduce(envelope: JSONObject): JSONObject {
        if (!RishAgentCoreNative.available) throw Refused(NATIVE)
        val reply = RishAgentCoreNative.walOperationReduce(envelope.toString())
            ?: throw Refused(NATIVE)
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

    /**
     * `changes` names whole top-level tables to replace, so applying them is a
     * put per table rather than a positional edit.
     */
    private fun apply(state: JSONObject, changes: JSONObject?) {
        val tables = changes ?: return
        for (name in tables.keys()) state.put(name, tables.get(name))
    }

    private fun outcome(reply: JSONObject, state: JSONObject): JSONObject =
        when (reply.optString("result")) {
            "commit" -> {
                apply(state, reply.optJSONObject("changes"))
                reply.optJSONObject("output") ?: throw Refused(NATIVE)
            }
            "replay" -> reply.optJSONObject("output") ?: throw Refused(NATIVE)
            else -> throw Refused(codeFor(reply.optInt("error", 2)))
        }

    /**
     * Starts the relation for one request, over a state the caller owns.
     *
     * Answers the envelope the core builds: `status` is `started` for a first
     * attempt and `replayed` for a repeat, and a replayed one whose operation
     * already settled carries the `result` to hand straight back.
     */
    fun startInState(
        state: JSONObject,
        kind: String,
        request: JSONObject,
        authorityRevision: Any?,
        timestamp: String,
    ): JSONObject {
        val arguments = JSONObject()
            .put("request", request)
            .put("operation_kind", kind)
            .put("task_id", request.opt("task_id"))
            .put("attempt_id", request.opt("attempt_id"))
            .put("authority_revision", authorityRevision ?: 0)
        return outcome(
            reduce(
                JSONObject().put("op", "start").put("state", state)
                    .put("arguments", arguments).put("timestamp", timestamp),
            ),
            state,
        )
    }

    /**
     * Starts the relation for a request that names its attempt in `target`.
     *
     * A cancellation or a recovery does not carry `task_id` at the top level,
     * and the plain `start` refuses a request whose ids do not match the ones
     * it is given. `start_target` is the core's reading of exactly that shape,
     * and it validates the target as well as the request.
     */
    fun startTargetInState(
        state: JSONObject,
        kind: String,
        request: JSONObject,
        target: JSONObject,
        authorityRevision: Any?,
        timestamp: String,
    ): JSONObject {
        val arguments = JSONObject()
            .put("request", request)
            .put("target", target)
            .put("operation_kind", kind)
            .put("task_id", target.opt("task_id"))
            .put("attempt_id", target.opt("attempt_id"))
            .put("authority_revision", authorityRevision ?: 0)
        return outcome(
            reduce(
                JSONObject().put("op", "start_target").put("state", state)
                    .put("arguments", arguments).put("timestamp", timestamp),
            ),
            state,
        )
    }

    /**
     * Settles a started operation with its result, over a state the caller
     * owns. Two reducer calls because the core splits the decision from the
     * write: the first says whether this commit is allowed and what the stored
     * result will be, the second produces the rows.
     */
    fun commitInState(
        state: JSONObject,
        operationId: Any?,
        requestSha256: Any?,
        taskId: Any?,
        attemptId: Any?,
        terminalState: String,
        resultStatus: String,
        resultRef: JSONObject,
        resultRevision: Any?,
        safeResult: JSONObject,
        timestamp: String,
    ): JSONObject {
        val arguments = JSONObject()
            .put("operation_id", operationId)
            .put("request_sha256", requestSha256)
            .put("task_id", taskId)
            .put("attempt_id", attemptId)
            .put("terminal_state", terminalState)
            .put("result_status", resultStatus)
            .put("result_ref", resultRef)
            .put("result_revision", resultRevision ?: JSONObject.NULL)
            .put("safe_result", safeResult)
        val prepared = reduce(
            JSONObject().put("op", "commit_prepare").put("state", state)
                .put("arguments", arguments).put("timestamp", timestamp),
        )
        when (prepared.optString("result")) {
            "replay" -> return prepared.optJSONObject("output") ?: throw Refused(NATIVE)
            "proceed" -> Unit
            else -> throw Refused(codeFor(prepared.optInt("error", 2)))
        }
        return outcome(
            reduce(
                JSONObject().put("op", "commit_apply").put("state", state)
                    .put("arguments", arguments)
                    .put("snapshot", prepared.optJSONObject("snapshot") ?: throw Refused(NATIVE))
                    .put("timestamp", timestamp),
            ),
            state,
        )
    }

    /**
     * What the relation already knows about one request: `not_started`,
     * `found` with the record, or `conflict` when this operation id was used
     * for a different request.
     */
    fun queryInState(
        state: JSONObject,
        operationId: Any?,
        requestSha256: Any?,
        taskId: Any?,
        attemptId: Any?,
    ): JSONObject {
        val arguments = JSONObject()
            .put("operation_id", operationId).put("request_sha256", requestSha256)
            .put("task_id", taskId).put("attempt_id", attemptId)
        val reply = reduce(
            JSONObject().put("op", "query").put("state", state)
                .put("arguments", arguments).put("timestamp", ""),
        )
        return when (reply.optString("result")) {
            "replay" -> reply.optJSONObject("output") ?: throw Refused(NATIVE)
            else -> throw Refused(codeFor(reply.optInt("error", 2)))
        }
    }

    /**
     * The digest the relation identifies a request by. The core derives it
     * from the operation kind, so this only names the kind.
     */
    fun requestSha256(kind: String, request: JSONObject): String =
        RishAgentCoreNative.hash(
            "agent-operation-request",
            JSONObject().put("operation_kind", kind).put("request", request),
        )

    /** Applies a commit descriptor the coordinator decided. */
    fun commitDecidedInState(state: JSONObject, commit: JSONObject, timestamp: String): JSONObject =
        commitInState(
            state,
            commit.opt("operation_id"), commit.opt("request_sha256"),
            commit.opt("task_id"), commit.opt("attempt_id"),
            commit.optString("terminal_state"), commit.optString("result_status"),
            commit.optJSONObject("result_ref")
                ?: JSONObject().put("schema_version", 2).put("kind", "none"),
            commit.opt("result_revision")?.takeIf { it != JSONObject.NULL },
            commit.optJSONObject("safe_result") ?: throw Refused(NATIVE),
            timestamp,
        )

    /** What a settled operation answered, from a commit or start envelope. */
    fun settledResult(envelope: JSONObject?): JSONObject? =
        envelope?.optJSONObject("result")?.optJSONObject("result")

    /** The envelope every operation result is wrapped in. */
    fun safeResult(kind: String, result: JSONObject): JSONObject = JSONObject()
        .put("schema_version", 2).put("result_kind", kind).put("result", result)

    private companion object {
        const val NATIVE = "E_AGENT_NATIVE"
    }
}
