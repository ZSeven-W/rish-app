package tech.zseven.rish.runtime

import org.json.JSONArray
import org.json.JSONObject

/**
 * The execution ledger, as a facade over the shared reducer
 * (`rish_agent_ledger_reduce`). This side owns the WAL transaction, answers
 * whether an owner is still alive in this process, collects the view — the
 * row, the attempt's dispatch markers, the bound and expected transcripts,
 * and the reservation, batch and authority records with their slots — and
 * applies the changes the reducer returns.
 */
internal class AndroidAgentExecutionLedger(
    private val wal: AndroidAgentWal,
    private val liveTasks: AndroidLiveTasks,
    private val operations: AndroidAgentOperations,
) {
    class Refused(val code: Int) : RuntimeException("E_AGENT_STORE_$code")

    private fun reduce(envelope: JSONObject): JSONObject = reduce(envelope, batch = false)

    /**
     * One reducer step.
     *
     * The row operations and the batch preparation are two different reducers
     * with two different vocabularies: `rish_agent_ledger_reduce` knows
     * `insert`, `claim`, `settle`; `rish_agent_ledger_batch_reduce` knows
     * `prepare_tool_batch`. Sending a batch to the first one is not a refusal
     * with a reason -- it is an op it has never heard of, answered as Corrupt.
     */
    private fun reduce(envelope: JSONObject, batch: Boolean): JSONObject {
        check(RishAgentCoreNative.available) { "the shared agent core is not staged in this build" }
        val reply = (
            if (batch) {
                RishAgentCoreNative.ledgerBatchReduce(envelope.toString())
            } else {
                RishAgentCoreNative.ledgerReduce(envelope.toString())
            }
            ) ?: throw Refused(2)
        val parsed = JSONObject(reply)
        if (!parsed.optBoolean("ok")) {
            android.util.Log.w(
                "RishAgent",
                "ledger refused ${envelope.optString("op")}: ${parsed.optInt("error", 2)}",
            )
            throw Refused(parsed.optInt("error", 2))
        }
        return parsed
    }

    /** `{slot, record}` for every row the reducer may replace by position. */
    private fun slotted(rows: JSONArray?, keep: (JSONObject) -> Boolean): JSONArray {
        val slotted = JSONArray()
        if (rows == null) return slotted
        for (index in 0 until rows.length()) {
            val record = rows.optJSONObject(index) ?: continue
            if (keep(record)) slotted.put(JSONObject().put("slot", index).put("record", record))
        }
        return slotted
    }

    private fun transcriptIndex(transcripts: JSONArray?, reference: Any?): Int {
        if (transcripts == null || reference == null) return -1
        for (index in 0 until transcripts.length()) {
            if (AndroidJson.equal(transcripts.optJSONObject(index)?.opt("transcript_ref"), reference)) return index
        }
        return -1
    }

    private fun ownerAlive(owner: Any?): Boolean {
        val record = owner as? JSONObject ?: return false
        return liveTasks.isAlive(record.optString("native_task_id"), record.optString("launch_id"))
    }

    private fun apply(state: JSONObject, changes: JSONArray, rowIndex: Int) {
        for (index in 0 until changes.length()) {
            val change = changes.getJSONObject(index)
            when (change.optString("kind")) {
                "insert_ledger_row" -> {
                    val rows = state.optJSONArray("ledger") ?: JSONArray()
                    rows.put(change.getJSONObject("row"))
                    state.put("ledger", rows)
                }
                "replace_ledger_row" -> {
                    val rows = state.optJSONArray("ledger") ?: throw Refused(2)
                    if (rowIndex < 0 || rowIndex >= rows.length()) throw Refused(2)
                    rows.put(rowIndex, change.getJSONObject("row"))
                    state.put("ledger", rows)
                }
                "insert_dispatch_marker" -> {
                    val dispatch = state.optJSONArray("dispatch") ?: JSONArray()
                    dispatch.put(change.getJSONObject("marker"))
                    state.put("dispatch", dispatch)
                }
                "mark_dispatched" -> {
                    val dispatch = state.optJSONArray("dispatch") ?: throw Refused(2)
                    var marker = -1
                    for (cursor in 0 until dispatch.length()) {
                        val candidate = dispatch.optJSONObject(cursor) ?: continue
                        if (candidate.optString("kind") == "execution" &&
                            AndroidJson.equal(candidate.opt("locator"), change.opt("locator"))) {
                            marker = cursor; break
                        }
                    }
                    if (marker < 0) throw Refused(2)
                    dispatch.put(marker, JSONObject(dispatch.getJSONObject(marker).toString())
                        .put("dispatch_state", "dispatched"))
                    state.put("dispatch", dispatch)
                }
                "replace_transcript" -> {
                    val transcripts = state.optJSONArray("transcripts") ?: throw Refused(2)
                    val row = change.getJSONObject("row")
                    val at = transcriptIndex(transcripts, row.opt("transcript_ref"))
                    if (at < 0) throw Refused(2)
                    transcripts.put(at, row)
                    state.put("transcripts", transcripts)
                }
                // A batch preparation appends rather than replaces: the
                // attempt's first batch and its first reservation do not exist
                // yet, and a kind this side does not know is refused as a
                // corrupt change.
                "insert_denied_call" -> {
                    val denied = state.optJSONArray("denied_calls") ?: JSONArray()
                    denied.put(change.getJSONObject("record"))
                    state.put("denied_calls", denied)
                }
                "insert_batch", "insert_reservation" -> {
                    val table = if (change.optString("kind") == "insert_batch") {
                        "batches"
                    } else {
                        "reservations"
                    }
                    val records = state.optJSONArray(table) ?: JSONArray()
                    records.put(change.getJSONObject("record"))
                    state.put(table, records)
                }
                "replace_reservation", "replace_batch", "replace_authority" -> {
                    val table = when (change.optString("kind")) {
                        "replace_reservation" -> "reservations"
                        "replace_batch" -> "batches"
                        else -> "authorities"
                    }
                    val records = state.optJSONArray(table) ?: throw Refused(2)
                    val slot = change.optInt("slot", -1)
                    if (slot < 0 || slot >= records.length()) throw Refused(2)
                    records.put(slot, change.getJSONObject("record"))
                    state.put(table, records)
                }
                else -> {
                    // A change this side cannot apply is a corrupt change, and
                    // which one it was is the entire diagnosis.
                    android.util.Log.w(
                        "RishAgent",
                        "unapplicable ledger change: ${change.optString("kind")}",
                    )
                    throw Refused(2)
                }
            }
        }
    }

    /** What one reducer step decided, and whether it wants the state kept. */
    private class Step(val output: JSONObject?, val committed: Boolean)

    /**
     * One reducer step over a state the caller owns.
     *
     * Split out of [run] so a step can also run inside a transaction someone
     * else opened. A denied approval is the case that needs it: the settlement
     * and the operation commit that records it have to land together or a kill
     * between them would lose the person's refusal.
     */
    private fun step(
        state: JSONObject,
        op: String,
        args: JSONObject,
        locator: Any?,
        taskId: Any?,
        attemptId: Any?,
        expectedTranscript: JSONObject?,
        argOwner: Any?,
        readOnly: Boolean,
        extraEnv: JSONObject? = null,
    ): Step {
        val rows = state.optJSONArray("ledger") ?: JSONArray()
        var row: JSONObject? = null
        var rowIndex = -1
        var attemptRowCount = 0
        for (index in 0 until rows.length()) {
            val candidate = rows.optJSONObject(index) ?: continue
            if (row == null && locator != null && AndroidJson.equal(candidate.opt("locator"), locator)) {
                row = candidate; rowIndex = index
            }
            if (attemptId != null &&
                AndroidJson.equal(candidate.optJSONObject("locator")?.opt("attempt_id"), attemptId)) {
                attemptRowCount += 1
            }
        }
        val dispatch = JSONArray()
        state.optJSONArray("dispatch")?.let { markers ->
            for (index in 0 until markers.length()) {
                val marker = markers.optJSONObject(index) ?: continue
                if (marker.optString("kind") == "execution" && attemptId != null &&
                    AndroidJson.equal(marker.optJSONObject("locator")?.opt("attempt_id"), attemptId)) {
                    dispatch.put(marker)
                }
            }
        }
        val transcripts = state.optJSONArray("transcripts")
        // The bound transcript is the one the row names; an insert has no
        // row yet, so the intent argument names it instead.
        val bound = row?.opt("transcript_before")
            ?: args.optJSONObject("intent")?.opt("transcript_before")
        val boundIndex = transcriptIndex(transcripts,
            (bound as? JSONObject)?.opt("transcript_ref"))
        val expectedIndex = transcriptIndex(transcripts,
            expectedTranscript?.opt("transcript_ref"))
        val authorityTable = state.optJSONArray("authorities")
        val authorities: Any = if (authorityTable == null || authorityTable.length() == 0) {
            JSONObject.NULL
        } else {
            slotted(authorityTable) { record ->
                taskId != null && attemptId != null &&
                    AndroidJson.equal(record.opt("task_id"), taskId) &&
                    AndroidJson.equal(record.opt("attempt_id"), attemptId)
            }
        }
        val env = JSONObject().put("launch_id", AndroidAgentWal.launchId)
            .put("now", AndroidClock.now()).put("attempt_row_count", attemptRowCount)
        extraEnv?.let { for (name in it.keys()) env.put(name, it.get(name)) }
        val result = reduce(JSONObject().put("op", op).put("args", args).put("env", env)
            .put("view", JSONObject()
                .put("row", row ?: JSONObject.NULL)
                .put("dispatch", dispatch)
                .put("transcript", if (boundIndex < 0) JSONObject.NULL else transcripts!!.getJSONObject(boundIndex))
                .put("expected_transcript", if (expectedIndex < 0) JSONObject.NULL else transcripts!!.getJSONObject(expectedIndex))
                .put("reservations", slotted(state.optJSONArray("reservations")) { AndroidJson.equal(it.opt("attempt_id"), attemptId) })
                .put("batches", slotted(state.optJSONArray("batches")) { AndroidJson.equal(it.opt("attempt_id"), attemptId) })
                .put("authorities", authorities)
                .put("arg_owner_alive", ownerAlive(argOwner))
                .put("row_owner_alive", ownerAlive(row?.opt("owner")))))
        val output = result.optJSONObject("output") ?: throw Refused(2)
        if (readOnly || !result.optBoolean("commit")) return Step(output, false)
        apply(state, result.optJSONArray("changes") ?: JSONArray(), rowIndex)
        // An operation the reducer decided is committed in the same
        // transaction, and its result is what the caller is owed: the
        // reducer leaves `operation_result` null for the host to fill, and a
        // settle that skips it answers a row where JavaScript expects a
        // result.
        result.optJSONObject("commit_operation")?.let { operation ->
            val committed = operations.commitDecidedInState(state, operation, AndroidClock.now())
            output.put(
                "operation_result",
                operations.settledResult(committed) ?: throw Refused(4),
            )
        }
        return Step(output, true)
    }

    private fun run(
        op: String,
        args: JSONObject,
        locator: Any?,
        taskId: Any?,
        attemptId: Any?,
        expectedTranscript: JSONObject?,
        argOwner: Any?,
        readOnly: Boolean,
        extraEnv: JSONObject? = null,
    ): JSONObject? {
        var output: JSONObject? = null
        val body: (JSONObject) -> Boolean = { state ->
            val decided = step(
                state, op, args, locator, taskId, attemptId,
                expectedTranscript, argOwner, readOnly, extraEnv,
            )
            output = decided.output
            decided.committed
        }
        if (readOnly) {
            body(wal.snapshot())
            return output
        }
        wal.transaction(body)
        return output
    }

    private fun locatorOf(container: JSONObject?): Any? = container?.opt("locator")

    fun insert(insertCas: JSONObject, intent: JSONObject): JSONObject? =
        run("insert", JSONObject().put("insert_cas", insertCas).put("intent", intent),
            locatorOf(insertCas), insertCas.opt("task_id"), insertCas.opt("attempt_id"),
            null, intent.opt("owner"), false)

    /**
     * Claims an intent row for this process.
     *
     * The core reads `locator` and `expected_row_revision` directly, not a CAS
     * to unpack, and it refuses a claim whose owner this process cannot vouch
     * for -- `arg_owner_alive` -- so the caller must have registered the task
     * before asking.
     */
    fun claim(cas: JSONObject, owner: JSONObject): JSONObject? =
        run(
            "claim",
            JSONObject().put("locator", cas.opt("locator"))
                .put("expected_row_revision", cas.opt("expected_row_revision"))
                .put("owner", owner),
            locatorOf(cas),
            cas.optJSONObject("locator")?.opt("task_id"),
            cas.optJSONObject("locator")?.opt("attempt_id"), null, owner, false,
        )

    fun cas(cas: JSONObject, patch: JSONObject): JSONObject? =
        run("cas", JSONObject().put("cas", cas).put("patch", patch), locatorOf(cas),
            cas.optJSONObject("locator")?.opt("task_id"),
            cas.optJSONObject("locator")?.opt("attempt_id"), null, null, false)

    fun markDispatched(cas: JSONObject): JSONObject? =
        run("mark_dispatched", JSONObject().put("cas", cas), locatorOf(cas),
            cas.optJSONObject("locator")?.opt("task_id"),
            cas.optJSONObject("locator")?.opt("attempt_id"), null, null, false)

    /**
     * Settles a dispatched row with the plan the core built.
     *
     * The plan already *is* the arguments -- `patch`, `message` and the
     * optional `operation` -- so it is spread beside the CAS rather than
     * nested under a name the reducer never reads.
     */
    fun settle(cas: JSONObject, settlement: JSONObject): JSONObject? =
        run("settle", JSONObject().put("cas", cas)
            .put("patch", settlement.opt("patch"))
            .put("message", settlement.opt("message"))
            .put("operation", settlement.opt("operation") ?: JSONObject.NULL), locatorOf(cas),
            cas.optJSONObject("locator")?.opt("task_id"),
            cas.optJSONObject("locator")?.opt("attempt_id"), null, null, false)

    fun cancel(cas: JSONObject, patch: JSONObject): JSONObject? =
        run("cancel", JSONObject().put("cas", cas).put("patch", patch), locatorOf(cas),
            cas.optJSONObject("locator")?.opt("task_id"),
            cas.optJSONObject("locator")?.opt("attempt_id"), null, null, false)

    /** Every transcript as the reducer reads it: the row without its messages. */
    private fun summaries(transcripts: JSONArray?): JSONArray {
        val summaries = JSONArray()
        if (transcripts == null) return summaries
        for (index in 0 until transcripts.length()) {
            val transcript = transcripts.optJSONObject(index) ?: continue
            val summary = JSONObject(transcript.toString())
            summary.remove("messages")
            summaries.put(summary)
        }
        return summaries
    }

    /**
     * What the batch reducer is allowed to see of one attempt.
     *
     * Both batch operations read the same tables through the same filters --
     * `prepare_tool_batch` writes the batch and `open_effect_gate` unlocks it
     * -- so the view is built once. A gate request names no transcript, and
     * the reducer does not read one for it.
     */
    private fun batchView(
        state: JSONObject,
        taskId: Any?,
        attemptId: Any?,
        roundId: Any?,
        transcriptRef: Any?,
    ): JSONObject {
        val ledgerRows = JSONArray()
        state.optJSONArray("ledger")?.let { rows ->
            for (index in 0 until rows.length()) {
                val row = rows.optJSONObject(index) ?: continue
                if (AndroidJson.equal(row.optJSONObject("locator")?.opt("attempt_id"), attemptId)) {
                    ledgerRows.put(row)
                }
            }
        }
        val dispatch = JSONArray()
        state.optJSONArray("dispatch")?.let { markers ->
            for (index in 0 until markers.length()) {
                val marker = markers.optJSONObject(index) ?: continue
                if (marker.optString("kind") == "execution" &&
                    AndroidJson.equal(marker.optJSONObject("locator")?.opt("attempt_id"), attemptId)) {
                    dispatch.put(marker)
                }
            }
        }
        // A round row carries its identity in its `locator`. Matching on a
        // top-level `round_id` puts no round in the view at all, and the
        // reducer refuses a batch whose round it cannot see.
        val rounds = JSONArray()
        state.optJSONArray("rounds")?.let { table ->
            for (index in 0 until table.length()) {
                val round = table.optJSONObject(index) ?: continue
                val locator = round.optJSONObject("locator") ?: continue
                if (AndroidJson.equal(locator.opt("round_id"), roundId) &&
                    AndroidJson.equal(locator.opt("attempt_id"), attemptId)
                ) {
                    rounds.put(round)
                }
            }
        }
        val transcripts = state.optJSONArray("transcripts")
        val transcriptIndex = transcriptIndex(transcripts, transcriptRef)
        val authorityTable = state.optJSONArray("authorities")
        val authorities: Any = if (authorityTable == null) JSONObject.NULL else slotted(authorityTable) {
            AndroidJson.equal(it.opt("task_id"), taskId) &&
                AndroidJson.equal(it.opt("attempt_id"), attemptId)
        }
        // A stored operation result names its attempt on the inside: the
        // snapshot is `{operation_id, operation_kind, result, ...}` and only
        // the result it wraps -- or, for a batch, the receipt inside that --
        // carries task_id and attempt_id. Filtering on the snapshot's own keys
        // matched nothing, which left the reducer with no receipt to prove an
        // approval against and refused every write batch's gate as a conflict.
        val operationResults = JSONArray()
        state.optJSONArray("operation_results")?.let { table ->
            for (index in 0 until table.length()) {
                val record = table.optJSONObject(index) ?: continue
                val result = record.optJSONObject("result")?.optJSONObject("result")
                val receipt = result?.optJSONObject("receipt")
                val direct = AndroidJson.equal(result?.opt("task_id"), taskId) &&
                    AndroidJson.equal(result?.opt("attempt_id"), attemptId)
                val viaReceipt = AndroidJson.equal(receipt?.opt("task_id"), taskId) &&
                    AndroidJson.equal(receipt?.opt("attempt_id"), attemptId)
                if (taskId != null && (direct || viaReceipt)) operationResults.put(record)
            }
        }
        val view = JSONObject()
            .put("tables_present", true)
            .put("rounds", rounds)
            .put("batches", slotted(state.optJSONArray("batches")) {
                AndroidJson.equal(it.opt("attempt_id"), attemptId)
            })
            .put("reservations", slotted(state.optJSONArray("reservations")) {
                AndroidJson.equal(it.opt("task_id"), taskId) &&
                    AndroidJson.equal(it.opt("attempt_id"), attemptId)
            })
            .put(
                "transcript",
                if (transcriptIndex < 0) JSONObject.NULL
                else transcripts?.optJSONObject(transcriptIndex) ?: JSONObject.NULL,
            )
            // Every transcript without its messages. The reducer relates a
            // ledger row to the transcript it was cut from through these, and
            // an empty list makes that relation unprovable: it is what refused
            // every write batch's effect gate as not found.
            .put("transcript_summaries", summaries(transcripts))
            .put("ledger_rows", ledgerRows)
            .put("dispatch", dispatch)
            .put("denied_calls", JSONArray())
            .put("denied_attempt_count", 0)
            .put("denied_total_count", 0)
            .put("authorities", authorities)
            .put("authorities_present", (authorityTable?.length() ?: 0) > 0)
            .put("operations_present", (state.optJSONArray("operations")?.length() ?: 0) > 0)
            .put("operation_results", operationResults)

        return view
    }

    /**
     * Opens a mutation batch's effect gate, through
     * `rish_agent_ledger_batch_reduce`.
     *
     * A prepared write batch is created closed: the ledger refuses to dispatch
     * any call in it until the approvals the person gave are proved against
     * the manifest the batch froze. This is that proof, and it is the step
     * between binding an approval and running the write -- without it a
     * write's `mark_dispatched` is a conflict forever, while reads, which need
     * no gate, go through.
     */
    fun openEffectGate(request: JSONObject): JSONObject? {
        var output: JSONObject? = null
        val body: (JSONObject) -> Boolean = body@ { state ->
            val view = batchView(
                state, request.opt("task_id"), request.opt("attempt_id"),
                request.opt("round_id"), null,
            )
            val env = JSONObject()
                .put("launch_id", AndroidAgentWal.launchId)
                .put("now", RuntimeJson.now())
                .put("approval_tokens", JSONArray())
            val reply = try {
                reduce(
                    JSONObject().put("op", "open_effect_gate").put("request", request)
                        .put("env", env).put("view", view),
                    batch = true,
                )
            } catch (refused: Refused) {
                android.util.Log.w("RishAgent", "open_effect_gate refused: ${refused.code}")
                return@body false
            }
            output = reply.optJSONObject("output") ?: reply
            if (!reply.optBoolean("commit")) return@body false
            apply(state, reply.optJSONArray("changes") ?: JSONArray(), -1)
            true
        }
        wal.transaction(body)
        return output
    }

    /**
     * Writes a prepared tool batch and the ledger rows it implies, through
     * `rish_agent_ledger_batch_reduce`.
     *
     * The view is the whole attempt as the reducer needs to see it: the frozen
     * round, the attempt's batches and reservation, the transcript the request
     * names, the attempt's ledger rows and dispatch markers, the round's denied
     * calls, the authorities and the operation results. It is collected here
     * because reading the WAL is the host's job, and every decision over it is
     * the reducer's.
     *
     * `approvalTokens` are host-generated because the reducer has no
     * randomness. One per call that may need approval; the reducer takes what
     * it needs and ignores the rest.
     */
    fun prepareToolBatch(
        request: JSONObject,
        approvalTokens: List<String>,
    ): JSONObject? {
        var output: JSONObject? = null
        val taskId = request.opt("task_id")
        val attemptId = request.opt("attempt_id")
        val roundId = request.opt("round_id")
        val body: (JSONObject) -> Boolean = body@ { state ->
            val view = batchView(
                state, taskId, attemptId, roundId,
                request.optJSONObject("transcript")?.opt("transcript_ref"),
            )
            val env = JSONObject()
                .put("launch_id", AndroidAgentWal.launchId)
                .put("now", RuntimeJson.now())
                .put("approval_tokens", JSONArray(approvalTokens))
            val reply = try {
                reduce(
                    JSONObject().put("op", "prepare_tool_batch").put("request", request)
                        .put("env", env).put("view", view),
                    batch = true,
                )
            } catch (refused: Refused) {
                android.util.Log.w("RishAgent", "prepare_tool_batch refused: ${refused.code}")
                return@body false
            }
            // The reducer returns changes and an output; the facade applies
            // the changes to the state the WAL transaction will commit. A
            // batch insert names no existing row, so there is no slot to
            // replace and the row index is deliberately absent.
            apply(state, reply.optJSONArray("changes") ?: JSONArray(), -1)
            // The reducer's own output is the batch record, with its
            // `operation_result` left null for the host to fill: the operation
            // commit it hands back is what produces the result the controller
            // is given, and skipping it returns a record JavaScript refuses as
            // E_AGENT_LEDGER.
            val commitOperation = reply.optJSONObject("commit_operation")
            output = if (commitOperation == null) {
                reply.optJSONObject("output") ?: reply
            } else {
                val committed = operations.commitDecidedInState(
                    state, commitOperation, AndroidClock.now(),
                )
                operations.settledResult(committed)
                    ?: throw Refused(4)
            }
            true
        }
        wal.transaction(body)
        return output
    }

    /**
     * `settle_denied_approval`, over a state an outer transaction owns.
     *
     * A person's refusal is not a bare decision: it settles the intent row
     * that was never dispatched with a denied receipt and appends the exact
     * protected feedback the model is shown, and the operation result that
     * records the bind has to land in the same transaction. A kill between
     * the two would leave a refusal the controller cannot see, and the next
     * round would ask the model to try the same call again.
     *
     * Answers null when the reducer would not commit; the caller fails the
     * whole transaction rather than committing half of it.
     */
    fun settleDeniedApprovalInState(
        state: JSONObject,
        locator: JSONObject,
        root: JSONObject,
        expectedTranscript: JSONObject,
        policy: JSONObject,
        expectedReservedWriteBytes: Any?,
        feedbackJson: String,
        timestamp: String,
    ): JSONObject? {
        val args = JSONObject()
            .put("locator", locator)
            .put("root", root)
            .put("expected_transcript", expectedTranscript)
            .put("policy", policy)
            .put("expected_reserved_write_bytes", expectedReservedWriteBytes ?: 0)
            .put("feedback_json", feedbackJson)
            .put("timestamp", timestamp)
        val decided = step(
            state, "settle_denied_approval", args, locator,
            locator.opt("task_id"), locator.opt("attempt_id"),
            expectedTranscript, null, false,
        )
        return if (decided.committed) decided.output else null
    }

    fun query(locator: JSONObject, expectedTranscript: JSONObject?, root: JSONObject?): JSONObject? =
        run("query", JSONObject().put("locator", locator)
            .put("expected_transcript", expectedTranscript ?: JSONObject.NULL)
            .put("root", root ?: JSONObject.NULL),
            locator, locator.opt("task_id"), locator.opt("attempt_id"),
            expectedTranscript, null, true)
}
