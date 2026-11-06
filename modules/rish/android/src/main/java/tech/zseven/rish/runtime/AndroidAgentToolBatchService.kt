package tech.zseven.rish.runtime

import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/**
 * `prepare_agent_tool_batch` on Android.
 *
 * Mirrors modules/rish/ios/Sources/AgentToolBatchService.mm. This is the step
 * that turns a finished round's raw tool calls into ledger rows an execution
 * can claim, and it owns no rules: the request shape, the preparation gate,
 * the per-call analysis, the executor-outcome mapping, the final authority
 * check and the ledger-failure rejection all come back from `tool_batch`,
 * whose own module names the split -- *the host keeps the WAL operation
 * relation, the session load, the root proofs, the executors' preparation
 * probes and the denied-approval transaction, and calls back with what it
 * observed*.
 *
 * The probe is the interesting half. For every call the core says has an
 * executor, the host asks that executor what the call asserts about the world
 * right now, and hands the answer back. A probe that refuses is an outcome
 * too: the core turns it into a rejection the round can carry rather than a
 * failure that loses the batch.
 */
internal class AndroidAgentToolBatchService(
    private val wal: AndroidAgentWal,
    private val sessions: AndroidSessionStore,
    private val prepared: AndroidPreparedAttemptStore,
    private val ledger: AndroidAgentExecutionLedger,
    private val roots: AndroidAgentRootResolver,
    private val workspaceTools: AndroidWorkspaceToolExecutor,
    private val operations: AndroidAgentOperations,
    private val transcripts: AndroidAgentTranscriptStore,
    private val gitTools: AndroidAgentGitToolExecutor? = null,
    private val assistantTools: AndroidAssistantTaskExecutor? = null,
) {
    class Refused(val code: String) : Exception(code)

    private fun decide(envelope: JSONObject): JSONObject {
        if (!RishAgentCoreNative.available) throw Refused(NATIVE)
        val reply = RishAgentCoreNative.toolBatchReduce(envelope.toString())
            ?: throw Refused(NATIVE)
        val parsed = JSONObject(reply)
        if (!parsed.optBoolean("ok")) throw Refused(codeFor(parsed.optInt("error", 2)))
        return parsed
    }

    private fun codeFor(error: Int): String = when (error) {
        1 -> "E_AGENT_BAD_ARGUMENTS"
        3 -> "E_AGENT_CONFLICT"
        4 -> "E_AGENT_PERSISTENCE"
        else -> NATIVE
    }

    fun prepare(request: JSONObject): JSONObject {
        decide(JSONObject().put("op", "prepare_request").put("request", request))

        val taskId = request.optString("task_id")
        val attemptId = request.optString("attempt_id")
        val root = request.optJSONObject("root") ?: throw Refused(BAD_ARGUMENTS)

        val session = AndroidCommittedSession.load(sessions, request)
        val sessionOk = AndroidCommittedSession.conversation(session, request) != null
        val resolved = roots.resolveAgentProjection(root)
        val state = wal.snapshot()
        val authority = prepared.authorityFor(taskId, attemptId)
        val conversation = AndroidCommittedSession.conversation(session, request)
        if (authority?.optJSONObject("registry")?.optInt("registry_version") == AndroidAssistantTaskExecutor.REGISTRY_VERSION &&
            assistantTools?.scopeAllowed(AndroidAssistantTaskExecutor.REGISTRY_VERSION, conversation) != true) {
            throw Refused("E_AGENT_CONFLICT")
        }
        val round = roundFor(state, request)

        // The operation relation is started before anything is written, as
        // iOS does: the ledger's own commit settles *this* operation, and a
        // commit with nothing started finds no record to settle.
        var replayed: JSONObject? = null
        wal.transaction { live ->
            val started = operations.startInState(
                live, "prepare_agent_tool_batch", request,
                authority?.opt("authority_revision"), RuntimeJson.now(),
            )
            if (started.optString("status") == "replayed") {
                replayed = operations.settledResult(started)
            }
            replayed == null
        }
        replayed?.let { return it }

        val gate = decide(
            JSONObject().put("op", "prepare_gate").put("request", request)
                .put("authority", authority ?: JSONObject.NULL)
                .put("round", round ?: JSONObject.NULL)
                .put("session_ok", sessionOk)
                .put("root_ok", resolved != null),
        )
        if (!gate.optBoolean("proceed")) {
            // The rejection the controller reads is the `reject` value, not
            // the reducer's envelope around it.
            val rejected = gate.optJSONObject("reject") ?: throw Refused(NATIVE)
            android.util.Log.w(
                "RishAgent",
                "batch gate refused: ${rejected.optString("failure_code")}",
            )
            return rejected
        }

        // `messages` is the transcript's own native messages -- the round's
        // assistant turn and its calls -- not the WAL's transcripts table. And
        // `grants` is what the *person* has allowed in this conversation, not
        // what the root is capable of: a capability list in its place makes
        // every call look ungranted.
        val messages = transcripts.nativeMessages(
            JSONObject().put("schema_version", 1)
                .put("attempt_id", request.opt("attempt_id"))
                .put("root", root)
                .put("transcript", request.opt("transcript")),
        ) ?: JSONArray()
        val grants = AndroidCommittedSession.conversation(session, request)
            ?.optJSONArray("agent_grants") ?: JSONArray()
        val analysis = decide(
            JSONObject().put("op", "prepare_calls").put("request", request)
                .put("round", round ?: JSONObject.NULL)
                .put("messages", messages)
                .put("authority", authority ?: JSONObject.NULL)
                .put("grants", grants),
        )
        val calls = analysis.optJSONArray("calls")
            ?: return analysis.optJSONObject("reject") ?: throw Refused(NATIVE)

        // The probes. One per call, in order, and the order is kept because
        // the core reads the outcomes positionally.
        val outcomes = JSONArray()
        for (index in 0 until calls.length()) {
            outcomes.put(probe(calls.optJSONObject(index), root, conversation, authority))
        }

        val finished = decide(
            JSONObject().put("op", "prepare_finish").put("request", request)
                .put("calls", calls).put("outcomes", outcomes),
        )
        val preparedCalls = finished.optJSONArray("prepared_calls") ?: JSONArray()

        // The authority is read again after the probes: they take time, and a
        // batch may only be written against the authority it started under.
        val finalAuthority = prepared.authorityFor(taskId, attemptId)
        val final = decide(
            JSONObject().put("op", "prepare_final").put("request", request)
                .put("authority", authority ?: JSONObject.NULL)
                .put("final_authority", finalAuthority ?: JSONObject.NULL)
                .put("started_authority_revision", authority?.opt("authority_revision") ?: JSONObject.NULL)
                .put(
                    "request_sha256",
                    operations.requestSha256("prepare_agent_tool_batch", request),
                )
                .put("prepared_calls", preparedCalls)
                .put("mutation_batch", finished.optBoolean("mutation_batch")),
        )
        val internal = final.optJSONObject("internal")
            ?: return final.optJSONObject("reject") ?: throw Refused(NATIVE)

        // One per call the reducer may need to mint an approval for. A batch
        // carries at most sixteen calls and the reducer takes what it needs,
        // so this is generous by design: running out mid-way is a corrupt
        // batch, not a smaller one.
        val tokens = (0 until 16).map { UUID.randomUUID().toString() }
        ledger.prepareToolBatch(internal, tokens)?.let { return it }
        return decide(
            JSONObject().put("op", "prepare_ledger_failure").put("request", request)
                .put("native_code", 3).put("prepared_calls", preparedCalls),
        ).optJSONObject("rejected") ?: throw Refused(PERSISTENCE)
    }

    /**
     * What one call asserts about the world right now. A call the core gave no
     * executor is not probed; a probe that refuses becomes an outcome the core
     * turns into a rejection, so one bad call does not lose the batch.
     */
    private fun probe(call: JSONObject?, root: JSONObject, conversation: JSONObject?, authority: JSONObject?): JSONObject {
        if (call == null) return JSONObject()
        if (call.opt("executor") == null || call.opt("executor") == JSONObject.NULL) {
            return JSONObject()
        }
        if (!call.isNull("rejection")) return JSONObject()
        val name = call.optString("name")
        val git = gitTools?.takeIf { name in it.tools }
        val assistant = assistantTools?.takeIf { name in it.tools }
        if (name !in workspaceTools.tools && git == null && assistant == null) {
            // Not servable here. The core's own invalid-argument mapping turns
            // this into the right rejection for the tool's family.
            return JSONObject().put("error", 1)
        }
        val arguments = call.optJSONObject("arguments") ?: JSONObject()
        return try {
            JSONObject().put("prepared", assistant?.prepare(call, conversation, authority)
                ?: git?.prepare(name, arguments, root) ?: workspaceTools.prepare(name, arguments, root))
        } catch (refused: AndroidWorkspaceToolExecutor.Refused) {
            // A probe that refuses becomes a rejection the round carries, not
            // a lost batch -- but which call refused, and why, is otherwise
            // invisible from the outside.
            android.util.Log.w(
                "RishAgent",
                "tool probe refused: $name ${refused.code}",
            )
            JSONObject().put("error", errorFor(refused.code))
        }
    }

    /** The executor's vocabulary back into the store codes the core reads. */
    private fun errorFor(code: String): Int = when (code) {
        "E_AGENT_CONFLICT" -> 3
        "E_AGENT_NOT_FOUND" -> 5
        "E_AGENT_PERSISTENCE" -> 4
        else -> 1
    }

    /**
     * The round row this batch belongs to.
     *
     * A row carries its identity in its `locator`, not at the top level, so
     * matching on `round_id` off the row itself never found one -- and a batch
     * with no round is a conflict, which is exactly what this reported.
     */
    private fun roundFor(state: JSONObject, request: JSONObject): JSONObject? {
        val rounds = state.optJSONArray("rounds") ?: return null
        for (index in 0 until rounds.length()) {
            val round = rounds.optJSONObject(index) ?: continue
            val locator = round.optJSONObject("locator") ?: continue
            if (AndroidJson.equal(locator.opt("round_id"), request.opt("round_id")) &&
                AndroidJson.equal(locator.opt("attempt_id"), request.opt("attempt_id"))
            ) {
                return round
            }
        }
        return null
    }

    private companion object {
        const val NATIVE = "E_AGENT_NATIVE"
        const val BAD_ARGUMENTS = "E_AGENT_BAD_ARGUMENTS"
        const val PERSISTENCE = "E_AGENT_PERSISTENCE"
    }
}
