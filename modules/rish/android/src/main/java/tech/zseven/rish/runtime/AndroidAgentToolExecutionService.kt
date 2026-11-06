package tech.zseven.rish.runtime

import org.json.JSONArray
import org.json.JSONObject

/**
 * `execute_agent_tool` on Android.
 *
 * Mirrors modules/rish/ios/Sources/AgentToolExecutionService.mm. The shared
 * core decides everything about the execution -- whether the request is
 * well-formed, whether the committed session is still the one it names, every
 * pre-execution check over the WAL views, the ledger CAS, the arguments handed
 * to the executor, how an effect settles and what the reply says. Its own
 * module documents the split: *the host keeps the WAL operation relation, the
 * session load, the root proofs, liveness, the executors and the ledger calls*,
 * and that is exactly what is left here.
 *
 * The one rule this file owns is that it owns none. Every branch below comes
 * back from `tool_execution`, and a branch it does not recognise is a refusal
 * rather than a guess.
 */
internal class AndroidAgentToolExecutionService(
    private val wal: AndroidAgentWal,
    private val sessions: AndroidSessionStore,
    private val prepared: AndroidPreparedAttemptStore,
    private val ledger: AndroidAgentExecutionLedger,
    private val roots: AndroidAgentRootResolver,
    private val workspaceTools: AndroidWorkspaceToolExecutor,
    private val liveTasks: AndroidLiveTasks,
    private val transcripts: AndroidAgentTranscriptStore,
    private val operations: AndroidAgentOperations,
    private val gitTools: AndroidAgentGitToolExecutor? = null,
    private val assistantTools: AndroidAssistantTaskExecutor? = null,
) {
    class Refused(val code: String) : Exception(code)

    private fun decide(envelope: JSONObject): JSONObject {
        if (!RishAgentCoreNative.available) throw Refused(NATIVE)
        val reply = RishAgentCoreNative.toolExecutionReduce(envelope.toString())
            ?: throw Refused(NATIVE)
        val parsed = JSONObject(reply)
        if (!parsed.optBoolean("ok")) {
            // Which decision refused, and why, is otherwise invisible: the
            // bridge only reports the code, and every step of an execution
            // goes through here.
            android.util.Log.w(
                "RishAgent",
                "execution refused ${envelope.optString("op")}: ${parsed.optInt("error", 2)}",
            )
            throw Refused(codeFor(parsed.optInt("error", 2)))
        }
        return parsed
    }

    /**
     * The store's numeric refusals become the codes JavaScript branches on.
     * An unrecognised one is `E_AGENT_NATIVE` rather than a number nobody
     * downstream knows how to read.
     */
    private fun codeFor(error: Int): String = when (error) {
        1 -> "E_AGENT_BAD_ARGUMENTS"
        3 -> "E_AGENT_CONFLICT"
        4 -> "E_AGENT_PERSISTENCE"
        else -> NATIVE
    }

    /**
     * Runs one tool call. The reply is whatever the core said the reply is:
     * a conflict, a result already settled, a result for a call another owner
     * is running, or the result of doing the work now.
     */
    fun execute(request: JSONObject): JSONObject {
        // Shape first, so a malformed request never reaches a view of the WAL.
        decide(JSONObject().put("op", "request").put("request", request))

        val taskId = request.optString("task_id")
        val attemptId = request.optString("attempt_id")
        val root = request.optJSONObject("root") ?: throw Refused(BAD_ARGUMENTS)

        // The conversation as the committed checkpoint saw it. The core reads
        // it to relate the call to the batch the person approved, so a session
        // that has moved on must read as absent rather than as a newer one.
        val conversation = AndroidCommittedSession.conversation(
            AndroidCommittedSession.load(sessions, request), request,
        )
        val authority = prepared.authorityFor(taskId, attemptId)
        requireAssistantScope(request, conversation, authority)
        if (request.optString("name") == "ask_user") {
            val question = rowFor(wal.snapshot(), request) ?: throw Refused(CONFLICT)
            // Validate options membership before reserving an operation. A typo
            // in a human response must not strand an otherwise untouched intent.
            decide(JSONObject().put("op", "question_response").put("request", request).put("row", question))
        }
        // An execution is an operation, and an operation has to be started
        // before it can be settled: the commit the settlement carries finds no
        // record otherwise, and the ledger refuses it. A replay answers with
        // what the first run recorded rather than running the tool twice.
        //
        // A same-operation replay must settle against the authority revision
        // its own start froze -- claiming the row may have advanced the live
        // one -- so an existing record's revision wins.
        var replayed: JSONObject? = null
        wal.transaction { live ->
            val revision = authority?.opt("authority_revision")
            val started = operations.startInState(
                live, "execute_agent_tool", request,
                operationRevision(live, request) ?: revision, RuntimeJson.now(),
            )
            if (started.optString("status") == "replayed") {
                replayed = operations.settledResult(started)
            }
            replayed == null
        }
        replayed?.let { return it }

        val state = wal.snapshot()
        // Whether the root still proves out is the resolver's answer, and the
        // core only needs to know that it did.
        val rootOk = roots.resolveAgentProjection(root) != null

        val view = JSONObject()
            .put("op", "precheck").put("request", request)
            .put("authority", authority ?: JSONObject.NULL)
            .put("batches", state.optJSONArray("batches") ?: JSONArray())
            .put("ledger", state.optJSONArray("ledger") ?: JSONArray())
            .put("operation_results", state.optJSONArray("operation_results") ?: JSONArray())
            .put("conversation", conversation ?: JSONObject.NULL)
            .put("root_ok", rootOk)
            .put("dispatch_state", dispatchState(state, request))
            .put("owner_alive", liveTasks.isAlive(taskId, AndroidAgentWal.launchId))
        val precheck = decide(view)

        precheck.optJSONObject("conflict")?.let { return it }
        precheck.optJSONObject("commit")?.let { return it.optJSONObject("result") ?: it }
        precheck.optJSONObject("result")?.let { return it }
        if (!precheck.optBoolean("proceed")) throw Refused(NATIVE)

        val row = rowFor(state, request) ?: throw Refused(CONFLICT)
        return if (request.optString("name") == "ask_user") answerQuestion(request, row)
            else run(request, row, state)
    }

    /** A user answer settles the durable intent without claiming a native effect. */
    private fun answerQuestion(request: JSONObject, row: JSONObject): JSONObject {
        val messages = transcripts.nativeMessages(JSONObject().put("schema_version", 1)
            .put("attempt_id", request.opt("attempt_id")).put("root", request.opt("root"))
            .put("transcript", request.opt("transcript"))) ?: throw Refused(CONFLICT)
        val arguments = decide(JSONObject().put("op", "arguments").put("request", request)
            .put("messages", messages)).optJSONObject("arguments") ?: throw Refused(BAD_ARGUMENTS)
        val plan = decide(JSONObject().put("op", "question_settlement").put("request", request)
            .put("row", row).put("arguments", arguments)
            .put("request_sha256", operations.requestSha256("execute_agent_tool", request)))
        val cas = plan.optJSONObject("cas") ?: throw Refused(NATIVE)
        val settled = ledger.settle(cas, plan) ?: throw Refused(CONFLICT)
        return settled.optJSONObject("operation_result") ?: throw Refused(NATIVE)
    }

    /** The authority revision an already-started operation froze, if any. */
    private fun operationRevision(state: JSONObject, request: JSONObject): Any? {
        val records = state.optJSONArray("operations") ?: return null
        for (index in 0 until records.length()) {
            val record = records.optJSONObject(index) ?: continue
            if (AndroidJson.equal(record.opt("operation_id"), request.opt("operation_id"))) {
                return record.opt("authority_revision")
            }
        }
        return null
    }

    /**
     * Works out what became of a tool call whose process died, for
     * `recover_agent_attempt`.
     *
     * Nothing is re-run here. The row says what was claimed; the world says
     * whether the effect landed; the core turns the two into either a
     * settlement to commit or a result to report. A recovery that re-ran a
     * write would be the one way to write a file twice.
     */
    fun recover(request: JSONObject): JSONObject {
        decide(JSONObject().put("op", "request").put("request", request))
        val conversation = AndroidCommittedSession.conversation(AndroidCommittedSession.load(sessions, request), request)
        val authority = prepared.authorityFor(request.optString("task_id"), request.optString("attempt_id"))
        requireAssistantScope(request, conversation, authority)
        // An operation that already settled answers with what it answered
        // then. Anything else that is not simply started is a conflict.
        historicalResult(request)?.let { return it }

        val state = wal.snapshot()
        val row = rowFor(state, request)
            ?: return JSONObject().put("schema_version", 2).put("status", "not_started")
        val rowState = row.optString("state")
        if (rowState == "settled" || rowState == "cancelled" || rowState == "ambiguous") {
            return decide(
                JSONObject().put("op", "safe_result").put("request", request).put("row", row),
            ).optJSONObject("result") ?: throw Refused(NATIVE)
        }

        // A question has no running process. Recovery preserves its exact
        // durable intent so the controller can show the same unanswered prompt.
        if (row.optString("name") == "ask_user" && rowState == "intent") {
            return decide(JSONObject().put("op", "active_result").put("request", request)
                .put("row", row).put("status", "intent").put("effect_may_have_occurred", false))
                .optJSONObject("result") ?: throw Refused(NATIVE)
        }

        // Read under the transcript the request names -- the one the
        // controller carries now -- as iOS does. The row's `transcript_before`
        // is the generation the batch was prepared at, and every call in the
        // batch after the first settles against a transcript past it.
        val messages = transcripts.nativeMessages(
            JSONObject().put("schema_version", 1)
                .put("attempt_id", request.opt("attempt_id"))
                .put("root", request.opt("root"))
                .put("transcript", request.opt("transcript")),
        ) ?: throw Refused(CONFLICT)
        val arguments = decide(
            JSONObject().put("op", "recover_arguments").put("request", request)
                .put("messages", messages),
        ).optJSONObject("arguments") ?: throw Refused(BAD_ARGUMENTS)

        val name = request.optString("name")
        val git = gitTools?.takeIf { name in it.tools }
        val assistant = assistantTools?.takeIf { name in it.tools }
        val recovered = if (name in workspaceTools.tools || git != null || assistant != null) {
            try {
                val root = request.optJSONObject("root") ?: JSONObject()
                assistant?.recover(request, arguments, row, conversation, authority)
                    ?: git?.recover(name, arguments, root, row.optJSONObject("precondition"))
                    ?: workspaceTools.recover(name, arguments, root, row.optJSONObject("precondition"))
            } catch (refused: AndroidWorkspaceToolExecutor.Refused) {
                // The disk could not answer. That is not proof the effect did
                // not happen, and recovery must never say it was.
                android.util.Log.w("RishAgent", "tool recovery unresolved: $name ${refused.code}")
                JSONObject().put("schema_version", 1).put("status", "ambiguous")
            }
        } else {
            // Nothing else runs on this platform yet, so nothing else can have
            // been dispatched by it.
            JSONObject().put("schema_version", 1).put("status", "not_dispatched")
        }

        val plan = decide(
            JSONObject().put("op", "recover").put("request", request).put("row", row)
                .put("recovered", recovered),
        )
        val settle = plan.optJSONObject("settle")
            ?: return plan.optJSONObject("result") ?: throw Refused(NATIVE)
        val settled = ledger.settle(settle.optJSONObject("cas") ?: throw Refused(NATIVE), settle)
            ?: throw Refused(CONFLICT)
        return settled.optJSONObject("operation_result") ?: throw Refused(NATIVE)
    }

    /** What this operation already answered, if it is past answering. */
    private fun historicalResult(request: JSONObject): JSONObject? {
        val sha = operations.requestSha256("execute_agent_tool", request)
        val state = wal.snapshot()
        val query = operations.queryInState(
            state, request.opt("operation_id"), sha,
            request.opt("task_id"), request.opt("attempt_id"),
        )
        val status = query.optString("status")
        val record = query.optJSONObject("record")
        if (status == "not_started" || (status == "found" && record?.optString("state") == "started")) {
            return null
        }
        if (status != "found") throw Refused(CONFLICT)
        val results = state.optJSONArray("operation_results") ?: throw Refused(NATIVE)
        for (index in 0 until results.length()) {
            val snapshot = results.optJSONObject(index) ?: continue
            if (AndroidJson.equal(snapshot.opt("operation_id"), request.opt("operation_id")) &&
                snapshot.optString("operation_kind") == "execute_agent_tool"
            ) {
                return snapshot.optJSONObject("result")?.optJSONObject("result")
                    ?: throw Refused(NATIVE)
            }
        }
        throw Refused(NATIVE)
    }

    /**
     * Claim, dispatch, do the work, settle. The order is the point: a row is
     * marked dispatched **before** the effect, so a crash in between leaves a
     * row that says an effect may have happened rather than one that says it
     * did not.
     */
    private fun run(request: JSONObject, row: JSONObject, state: JSONObject): JSONObject {
        // A mutation batch is frozen closed when it is prepared, and the
        // ledger refuses to dispatch anything in it until the approvals the
        // person gave are proved against the manifest. That proof is this
        // step. Reads need no gate, and the core says which is which.
        val gate = decide(JSONObject().put("op", "effect_gate").put("request", request))
        if (gate.optBoolean("needed")) {
            val gateRequest = gate.optJSONObject("request") ?: throw Refused(NATIVE)
            ledger.openEffectGate(gateRequest) ?: throw Refused(APPROVAL)
        }
        val claimCas = decide(
            JSONObject().put("op", "execution_cas").put("request", request)
                .put("row", row).put("state", "intent"),
        ).optJSONObject("cas") ?: throw Refused(CONFLICT)
        // The core refuses a claim whose owner is not alive in this process,
        // so the task is registered before it is claimed -- the same relation
        // the round journal insists on.
        val nativeTaskId = request.optString("operation_id")
        liveTasks.register(nativeTaskId)
        return try {
            claimed(request, claimCas)
        } finally {
            // Alive only while the call is being run, exactly as the round
            // does: a dispatched row whose owner never dies can never be
            // recovered by the process that owns it.
            liveTasks.unregister(nativeTaskId)
        }
    }

    private fun claimed(request: JSONObject, claimCas: JSONObject): JSONObject {
        val owner = ownerFor(request)
        ledger.claim(claimCas, owner) ?: throw Refused(CONFLICT)

        val claimed = rowFor(wal.snapshot(), request) ?: throw Refused(CONFLICT)
        val dispatchCas = decide(
            JSONObject().put("op", "execution_cas").put("request", request)
                // A claimed row's state is `running`; "claimed" and
                // "dispatched" are not states a row is ever in. Dispatch is a
                // separate marker, so the row is still running when it is set
                // and still running when the effect settles.
                .put("row", claimed).put("state", "running"),
        ).optJSONObject("cas") ?: throw Refused(CONFLICT)
        ledger.markDispatched(dispatchCas) ?: throw Refused(CONFLICT)

        // The arguments are read back out of the transcript that recorded the
        // call -- its own native messages, not the WAL's transcripts table.
        // Under the transcript the *request* names, as iOS reads it: the
        // row's `transcript_before` is the generation the batch was prepared
        // at, and once the first call in a batch settles the transcript has
        // moved past it, so the second call would read as a conflict.
        val messages = transcripts.nativeMessages(
            JSONObject().put("schema_version", 1)
                .put("attempt_id", request.opt("attempt_id"))
                .put("root", request.opt("root"))
                .put("transcript", request.opt("transcript")),
        ) ?: JSONArray()
        val arguments = decide(
            JSONObject().put("op", "arguments").put("request", request)
                .put("messages", messages),
        ).optJSONObject("arguments") ?: throw Refused(BAD_ARGUMENTS)

        val began = System.currentTimeMillis()
        val effect = effectOf(request, arguments, claimed)
        val duration = System.currentTimeMillis() - began

        val dispatched = rowFor(wal.snapshot(), request) ?: throw Refused(CONFLICT)
        val plan = decide(
            JSONObject().put("op", "settlement").put("request", request)
                .put("row", dispatched).put("effect", effect)
                .put("duration_ms", duration)
                // The operation the settlement commits is named by the same
                // digest its start recorded; without it the ledger refuses the
                // settle as invalid.
                .put(
                    "request_sha256",
                    operations.requestSha256("execute_agent_tool", request),
                ),
        )
        // The plan *is* the settlement: the core hands back the CAS it expects,
        // the patch, the tool message and the operation to commit. There is no
        // `settlement` key to unwrap, and the CAS is the plan's -- deciding a
        // fresh one here would assert a state the plan did not.
        val settleCas = plan.optJSONObject("cas") ?: throw Refused(NATIVE)
        val settled = ledger.settle(settleCas, plan)
        if (settled == null) {
            // The effect happened and the ledger did not record it. That is
            // not a failure to execute; it is a failure to remember, and the
            // core spells the difference.
            return decide(
                JSONObject().put("op", "settle_failed").put("request", request)
                    .put("row", dispatched).put("plan", plan).put("effect", effect),
            ).optJSONObject("result") ?: throw Refused(PERSISTENCE)
        }
        // What the settled operation answered is the operation's own result,
        // recorded with it. Re-deriving one from the row would return a result
        // the WAL never stored.
        return settled.optJSONObject("operation_result") ?: throw Refused(NATIVE)
    }

    /**
     * Only the three workspace tools run here. A name the registry knows but
     * this platform cannot serve -- a git tool, a runtime program, a guest CGI
     * handler -- becomes the core's generic failure rather than a crash or a
     * silence, so the round sees a settled call it can carry on from.
     */
    private fun effectOf(request: JSONObject, arguments: JSONObject, row: JSONObject): JSONObject {
        val name = request.optString("name")
        val git = gitTools?.takeIf { name in it.tools }
        val assistant = assistantTools?.takeIf { name in it.tools }
        if (name !in workspaceTools.tools && git == null && assistant == null) {
            return decide(
                JSONObject().put("op", "generic_failure").put("request", request),
            ).optJSONObject("effect") ?: throw Refused(NATIVE)
        }
        return try {
            val root = request.optJSONObject("root") ?: JSONObject()
            val conversation = AndroidCommittedSession.conversation(AndroidCommittedSession.load(sessions, request), request)
            val authority = prepared.authorityFor(request.optString("task_id"), request.optString("attempt_id"))
            requireAssistantScope(request, conversation, authority)
            (assistant?.execute(request, arguments, row, conversation, authority)
                ?: git?.execute(name, arguments, root, row.optJSONObject("precondition"))
                ?: workspaceTools.execute(name, arguments, root))
                .also { android.util.Log.w("RishAgent", "tool $name ran") }
        } catch (refused: AndroidWorkspaceToolExecutor.Refused) {
            // The tool's own refusal becomes a failure the model is shown; it
            // must still be visible here, or an effect that never happened is
            // indistinguishable from one that did nothing.
            android.util.Log.w("RishAgent", "tool $name refused: ${refused.code}", refused)
            val outcome = when {
                assistant != null && refused.code == "E_AGENT_EXECUTION_AMBIGUOUS" -> "ambiguous_effect"
                assistant != null && refused.code in setOf("E_AGENT_CONFLICT", "E_AGENT_BAD_ARGUMENTS", "E_AGENT_NOT_FOUND") -> "assistant_failure"
                else -> "generic_failure"
            }
            decide(JSONObject().put("op", outcome).put("request", request).put("failure_code", refused.code))
                .optJSONObject("effect") ?: throw Refused(NATIVE)
        }
    }

    private fun requireAssistantScope(request: JSONObject, conversation: JSONObject?, authority: JSONObject?) {
        val version = authority?.optJSONObject("registry")?.optInt("registry_version")
        val assistantName = request.optString("name") in AndroidAssistantTaskExecutor.TOOLS
        if (assistantName && version != AndroidAssistantTaskExecutor.REGISTRY_VERSION) throw Refused(CONFLICT)
        if (version == AndroidAssistantTaskExecutor.REGISTRY_VERSION &&
            assistantTools?.scopeAllowed(version, conversation) != true) throw Refused(CONFLICT)
    }

    private fun rowFor(state: JSONObject, request: JSONObject): JSONObject? =
        decide(
            JSONObject().put("op", "row").put("request", request)
                .put("ledger", state.optJSONArray("ledger") ?: JSONArray()),
        ).optJSONObject("row")

    private fun dispatchState(state: JSONObject, request: JSONObject): String {
        val locator = rowFor(state, request)?.optJSONObject("locator") ?: return "absent"
        val markers = state.optJSONArray("dispatch") ?: return "absent"
        for (index in 0 until markers.length()) {
            val marker = markers.optJSONObject(index) ?: continue
            if (marker.optString("kind") == "execution" && AndroidJson.equal(marker.opt("locator"), locator)) {
                return marker.optString("dispatch_state", "absent")
            }
        }
        return "absent"
    }

    private fun ownerFor(request: JSONObject): JSONObject = JSONObject()
        .put("schema_version", 1)
        .put("task_id", request.optString("task_id"))
        .put("launch_id", AndroidAgentWal.launchId)
        .put("native_task_id", request.optString("operation_id"))
        .put("owner_generation", 1)
        .put("heartbeat_at", RuntimeJson.now())

    private companion object {
        const val NATIVE = "E_AGENT_NATIVE"
        const val CONFLICT = "E_AGENT_CONFLICT"
        const val BAD_ARGUMENTS = "E_AGENT_BAD_ARGUMENTS"
        const val PERSISTENCE = "E_AGENT_PERSISTENCE"
        const val APPROVAL = "E_AGENT_APPROVAL"
    }
}
