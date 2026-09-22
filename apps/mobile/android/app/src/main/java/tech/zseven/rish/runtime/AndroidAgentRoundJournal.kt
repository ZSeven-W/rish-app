package tech.zseven.rish.runtime

import org.json.JSONArray
import org.json.JSONObject

/**
 * The schema-3 round journal, as a facade over the shared reducer
 * (`rish_agent_round_reduce`). This side owns the WAL transaction, answers
 * whether an owner is still alive in this process, and applies the row,
 * dispatch-marker and transcript effects the reducer returns.
 *
 * A decided-but-uncommitted answer — already present, already dispatched, a
 * query — is the WAL's explicit no-op: the caller still gets the output and
 * no generation is consumed.
 */
internal class AndroidAgentRoundJournal(
    private val wal: AndroidAgentWal,
    private val liveTasks: AndroidLiveTasks,
) {
    class Refused(val code: Int, val op: String = "") :
        RuntimeException("E_AGENT_STORE_${code}${if (op.isEmpty()) "" else " in $op"}")

    private fun reduce(envelope: JSONObject): JSONObject {
        check(RishAgentCoreNative.available) { "the shared agent core is not staged in this build" }
        val op = envelope.optString("op")
        val reply = RishAgentCoreNative.roundReduce(envelope.toString()) ?: throw Refused(2, op)
        val parsed = JSONObject(reply)
        if (!parsed.optBoolean("ok")) throw Refused(parsed.optInt("error", 2), op)
        return parsed
    }

    /** The catalogue and clock facts the reducer treats as the host's. */
    private fun environment(receipt: JSONObject?, roundCount: Int): JSONObject {
        var harness: Any = JSONObject.NULL
        var bindingValid = false
        val model = receipt?.optString("model")
        if (!model.isNullOrEmpty()) {
            try { harness = AndroidProviderConfiguration.harness(model) }
            catch (_: IllegalStateException) { }
            // Android issues no provider bindings of its own, so a receipt
            // that carries one is never valid here.
            bindingValid = false
        }
        val models = JSONArray()
        for (name in AndroidProviderConfiguration.models.values.flatten().sorted()) models.put(name)
        return JSONObject().put("launch_id", AndroidAgentWal.launchId)
            .put("now", AndroidClock.now()).put("supported_models", models)
            .put("receipt_harness_id", harness).put("receipt_binding_valid", bindingValid)
            .put("round_count", roundCount)
    }

    private fun dispatchState(dispatch: JSONArray?, locator: Any?): Any {
        if (dispatch == null || locator == null) return JSONObject.NULL
        for (index in 0 until dispatch.length()) {
            val marker = dispatch.optJSONObject(index) ?: continue
            if (marker.optString("kind") == "round" && AndroidJson.equal(marker.opt("locator"), locator)) {
                return marker.opt("dispatch_state") ?: JSONObject.NULL
            }
        }
        return JSONObject.NULL
    }

    private fun ownerAlive(owner: Any?): Boolean {
        val record = owner as? JSONObject ?: return false
        return liveTasks.isAlive(record.optString("native_task_id"), record.optString("launch_id"))
    }

    private fun run(
        op: String,
        args: JSONObject,
        locator: Any?,
        argOwner: Any?,
        receipt: JSONObject?,
        needsTranscript: Boolean,
        readOnly: Boolean,
    ): JSONObject? {
        var output: JSONObject? = null
        val apply: (JSONObject) -> Boolean = apply@ { state ->
            val rounds = state.optJSONArray("rounds") ?: JSONArray()
            val dispatch = state.optJSONArray("dispatch") ?: JSONArray()
            val transcripts = state.optJSONArray("transcripts") ?: JSONArray()
            var row: JSONObject? = null
            var rowIndex = -1
            for (index in 0 until rounds.length()) {
                val candidate = rounds.optJSONObject(index) ?: continue
                if (locator != null && AndroidJson.equal(candidate.opt("locator"), locator)) {
                    row = candidate; rowIndex = index; break
                }
            }
            var transcript: JSONObject? = null
            var transcriptIndex = -1
            if (needsTranscript && row != null) {
                val reference = row.optJSONObject("transcript_before")?.opt("transcript_ref")
                for (index in 0 until transcripts.length()) {
                    val candidate = transcripts.optJSONObject(index) ?: continue
                    if (reference != null && AndroidJson.equal(candidate.opt("transcript_ref"), reference)) {
                        transcript = candidate; transcriptIndex = index; break
                    }
                }
            }
            val result = reduce(JSONObject().put("op", op).put("args", args)
                .put("env", environment(receipt, rounds.length()))
                .put("view", JSONObject()
                    .put("row", row ?: JSONObject.NULL)
                    .put("dispatch_state", dispatchState(dispatch, locator))
                    .put("transcript", transcript ?: JSONObject.NULL)
                    .put("arg_owner_alive", ownerAlive(argOwner))
                    .put("row_owner_alive", ownerAlive(row?.opt("owner")))))
            output = result.optJSONObject("output") ?: throw Refused(2)
            if (readOnly || !result.optBoolean("commit")) return@apply false
            result.optJSONObject("row")?.let { next ->
                if (rowIndex < 0) rounds.put(next) else rounds.put(rowIndex, next)
                state.put("rounds", rounds)
            }
            when (result.optString("dispatch")) {
                "insert_not_dispatched" -> {
                    dispatch.put(JSONObject().put("schema_version", 1).put("kind", "round")
                        .put("locator", result.getJSONObject("row").opt("locator"))
                        .put("dispatch_state", "not_dispatched"))
                    state.put("dispatch", dispatch)
                }
                "mark_dispatched" -> {
                    var marker = -1
                    for (index in 0 until dispatch.length()) {
                        val candidate = dispatch.optJSONObject(index) ?: continue
                        if (candidate.optString("kind") == "round" && AndroidJson.equal(candidate.opt("locator"), locator)) {
                            marker = index; break
                        }
                    }
                    if (marker < 0) throw Refused(2)
                    dispatch.put(marker, JSONObject(dispatch.getJSONObject(marker).toString())
                        .put("dispatch_state", "dispatched"))
                    state.put("dispatch", dispatch)
                }
            }
            result.optJSONObject("transcript")?.let { next ->
                if (transcriptIndex < 0) throw Refused(2)
                transcripts.put(transcriptIndex, next)
                state.put("transcripts", transcripts)
            }
            true
        }
        if (readOnly) {
            apply(wal.snapshot())
            return output
        }
        wal.transaction(apply)
        return output
    }

    fun create(insertCas: JSONObject, round: JSONObject): JSONObject? =
        run("create", JSONObject().put("insert_cas", insertCas).put("round", round),
            insertCas.opt("locator"), round.opt("owner"), null, false, false)

    fun claim(cas: JSONObject, owner: JSONObject): JSONObject? =
        run("claim", JSONObject().put("cas", cas).put("owner", owner),
            cas.opt("locator"), owner, null, false, false)

    fun markDispatched(cas: JSONObject): JSONObject? =
        run("mark_dispatched", JSONObject().put("cas", cas), cas.opt("locator"), null, null,
            false, false)

    /**
     * Settles a dispatched round with what the model answered.
     *
     * The core reads these flat -- `locator`, `cas`, `messages`, `receipt`,
     * `terminal_kind`, `calls`, `root` -- and nesting them under a `patch`
     * only ever produced InvalidArgument.
     */
    fun complete(
        locator: JSONObject,
        cas: JSONObject,
        messages: JSONArray,
        receipt: JSONObject,
        terminalKind: String,
        calls: JSONArray,
        root: JSONObject,
    ): JSONObject? =
        run(
            "complete",
            JSONObject().put("locator", locator).put("cas", cas)
                .put("messages", messages).put("receipt", receipt)
                .put("terminal_kind", terminalKind).put("calls", calls)
                .put("root", root),
            locator, null, receipt, true, false,
        )

    fun cancel(cas: JSONObject): JSONObject? =
        run("cancel", JSONObject().put("cas", cas), cas.opt("locator"), null, null, false, false)

    /**
     * The core reads this argument as `cas`, the same name every other
     * journal operation uses. Sending it as `expected_cas` left the rule
     * reading nothing at all, so every reconcile answered InvalidArgument and
     * every caller quietly fell back to the row it already had -- which is
     * how a round nobody was running stayed `in_flight` for good.
     */
    /**
     * Settles a round whose writer is gone.
     *
     * `cause` is what the caller knows about why, and the core takes it only
     * for a round that was never dispatched -- a dispatched round whose
     * answer never came is ambiguous whatever its writer believed. Without
     * it the row records the generic "could not be saved", which is what
     * every later reader and every restart then has to report.
     */
    fun reconcile(
        locator: JSONObject,
        expectedCas: JSONObject,
        cause: String? = null,
    ): JSONObject? =
        run(
            "reconcile",
            JSONObject().put("locator", locator).put("cas", expectedCas)
                .put("failure_code", cause ?: JSONObject.NULL),
            locator, null, null, false, false,
        )

    fun query(locator: JSONObject): JSONObject? =
        run("query", JSONObject().put("locator", locator), locator, null, null, false, true)
}

/**
 * Which native tasks this process is still running. A persisted owner counts
 * as live only when its launch id is this launch and its task is registered
 * here, so a dead writer's rows are recoverable rather than pinned forever.
 */
internal class AndroidLiveTasks {
    private val tasks = HashSet<String>()

    @Synchronized fun register(taskId: String) { tasks.add(taskId) }
    @Synchronized fun unregister(taskId: String) { tasks.remove(taskId) }
    @Synchronized fun isAlive(taskId: String?, launchId: String?): Boolean =
        taskId != null && launchId == AndroidAgentWal.launchId && tasks.contains(taskId)
}
