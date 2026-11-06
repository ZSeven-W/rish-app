package tech.zseven.rish.runtime

import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/**
 * The transcript store, as a facade over the shared reducer
 * (`rish_agent_transcript_reduce`). This side owns the WAL transaction,
 * generates the fresh transcript id and the retention timestamp, collects the
 * view the reducer asks for, and applies the returned changes verbatim — the
 * same division iOS uses, so both platforms answer alike.
 *
 * Display-only round retention lives beside the WAL, independently of authority.
 */
internal class AndroidAgentTranscriptStore(private val wal: AndroidAgentWal) {
    private val presentations = AndroidAgentRoundPresentations(wal.root)

    fun cacheRoundPresentation(request: JSONObject, message: JSONObject, kind: String) =
        presentations.cache(request, message, kind)

    fun roundPresentations(conversation: String, attempt: String): JSONObject =
        presentations.read(conversation, attempt, wal.snapshot())

    fun pruneRoundPresentations(conversationIds: Set<String>) = presentations.prune(conversationIds)


    /** A refusal the core reported, carrying its store error code. */
    class Refused(val code: Int) : RuntimeException("E_AGENT_STORE_$code")

    private fun reduce(envelope: JSONObject): JSONObject {
        check(RishAgentCoreNative.available) { "the shared agent core is not staged in this build" }
        val reply = RishAgentCoreNative.transcriptReduce(envelope.toString())
            ?: throw Refused(2)
        val parsed = JSONObject(reply)
        if (!parsed.optBoolean("ok")) throw Refused(parsed.optInt("error", 2))
        return parsed
    }

    /** `{locator, state}` for every round or ledger row, which discard must respect. */
    private fun rowReferences(rows: JSONArray?): JSONArray {
        val references = JSONArray()
        if (rows == null) return references
        for (index in 0 until rows.length()) {
            val row = rows.optJSONObject(index) ?: continue
            references.put(JSONObject()
                .put("locator", row.opt("locator") ?: JSONObject.NULL)
                .put("state", row.opt("state") ?: JSONObject.NULL))
        }
        return references
    }

    private fun view(state: JSONObject, request: JSONObject?, transcriptRef: Any?): JSONObject {
        val attemptId = request?.opt("attempt_id")
        val cleanupId = request?.opt("cleanup_id")
        val transcripts = state.optJSONArray("transcripts")
        val attemptRows = JSONArray()
        var row: JSONObject? = null
        if (transcripts != null) {
            for (index in 0 until transcripts.length()) {
                val candidate = transcripts.optJSONObject(index) ?: continue
                if (attemptId != null && AndroidJson.equal(candidate.opt("attempt_id"), attemptId)) attemptRows.put(candidate)
                if (row == null && transcriptRef != null && AndroidJson.equal(candidate.opt("transcript_ref"), transcriptRef)) {
                    row = candidate
                }
            }
        }
        val cleanup = JSONArray()
        state.optJSONArray("cleanup")?.let { table ->
            for (index in 0 until table.length()) {
                val entry = table.optJSONObject(index) ?: continue
                if (cleanupId != null && AndroidJson.equal(entry.opt("cleanup_id"), cleanupId)) {
                    cleanup.put(JSONObject().put("slot", index).put("record", entry))
                }
            }
        }
        return JSONObject()
            .put("transcripts_present", transcripts != null)
            .put("transcript_count", transcripts?.length() ?: 0)
            .put("attempt_transcripts", attemptRows)
            .put("transcript", row ?: JSONObject.NULL)
            .put("cleanup", cleanup)
            .put("rounds", rowReferences(state.optJSONArray("rounds")))
            .put("ledger", rowReferences(state.optJSONArray("ledger")))
    }

    private fun environment(): JSONObject = JSONObject()
        .put("launch_id", AndroidAgentWal.launchId)
        .put("now", AndroidClock.now())
        .put("retention_until", AndroidClock.nowAdding(7 * 24 * 60 * 60))
        .put("transcript_ref", UUID.randomUUID().toString())

    /** Applies one change from the reducer's list to the candidate state. */
    private fun apply(state: JSONObject, change: JSONObject) {
        when (change.optString("kind")) {
            "insert_transcript" -> {
                val next = state.optJSONArray("transcripts") ?: JSONArray()
                next.put(change.getJSONObject("row"))
                state.put("transcripts", next)
            }
            "replace_transcript", "remove_transcript" -> {
                val replacing = change.optString("kind") == "replace_transcript"
                val reference = if (replacing) change.getJSONObject("row").opt("transcript_ref")
                    else change.opt("transcript_ref")
                val rows = state.optJSONArray("transcripts") ?: throw Refused(2)
                var index = -1
                for (cursor in 0 until rows.length()) {
                    if (AndroidJson.equal(rows.optJSONObject(cursor)?.opt("transcript_ref"), reference)) { index = cursor; break }
                }
                if (index < 0) throw Refused(2)
                if (replacing) rows.put(index, change.getJSONObject("row")) else rows.remove(index)
                state.put("transcripts", rows)
            }
            "insert_cleanup" -> {
                val next = state.optJSONArray("cleanup") ?: JSONArray()
                next.put(change.getJSONObject("record"))
                state.put("cleanup", next)
            }
            "replace_cleanup" -> {
                val rows = state.optJSONArray("cleanup") ?: throw Refused(2)
                val slot = change.optInt("slot", -1)
                if (slot < 0 || slot >= rows.length()) throw Refused(2)
                rows.put(slot, change.getJSONObject("record"))
                state.put("cleanup", rows)
            }
            else -> throw Refused(2)
        }
    }

    /** One transcript operation that may write. */
    private fun run(op: String, request: JSONObject?, transcriptRef: Any?): Any? {
        var output: Any? = null
        val committed = wal.transaction { state ->
            val result = reduce(JSONObject().put("op", op)
                .put("request", request ?: JSONObject.NULL)
                .put("env", environment())
                .put("view", view(state, request, transcriptRef)))
            output = result.opt("output")
            if (output == null || output == JSONObject.NULL) throw Refused(2)
            if (!result.optBoolean("commit")) return@transaction false
            val changes = result.optJSONArray("changes") ?: JSONArray()
            for (index in 0 until changes.length()) apply(state, changes.getJSONObject(index))
            true
        }
        // A reducer that answered without committing still answered: the
        // caller gets its output, and the state is untouched.
        return if (committed || output != null) output else null
    }

    /** One transcript operation that only reads. */
    private fun read(op: String, request: JSONObject?, transcriptRef: Any?): Any? {
        val state = wal.snapshot()
        val result = reduce(JSONObject().put("op", op)
            .put("request", request ?: JSONObject.NULL)
            .put("env", environment())
            .put("view", view(state, request, transcriptRef)))
        val output = result.opt("output")
        return if (output == JSONObject.NULL) null else output
    }

    fun create(request: JSONObject): JSONObject? = run("create", request, null) as JSONObject?

    fun validate(request: JSONObject): JSONObject? =
        read("validate", request, request.opt("transcript_ref")) as JSONObject?

    fun nativeMessages(request: JSONObject): JSONArray? =
        read("native_messages", request,
            request.optJSONObject("transcript")?.opt("transcript_ref")) as JSONArray?

    // append and mark_terminal address the row they expect to still be there,
    // so their reference is the expected one, not a current one.
    fun append(request: JSONObject): JSONObject? =
        run("append", request, request.optJSONObject("expected_transcript")?.opt("transcript_ref")) as JSONObject?

    fun markTerminal(request: JSONObject): JSONObject? =
        run("mark_terminal", request, request.optJSONObject("expected_transcript")?.opt("transcript_ref")) as JSONObject?

    fun discard(request: JSONObject): JSONObject? =
        run("discard", request, request.opt("transcript_ref")) as JSONObject?

    fun queryCleanup(request: JSONObject): JSONObject? =
        read("query_cleanup", request, null) as JSONObject?
}
