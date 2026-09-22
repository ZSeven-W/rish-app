package tech.zseven.rish

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.AndroidAgentRoundJournal
import tech.zseven.rish.runtime.AndroidAgentTranscriptStore
import tech.zseven.rish.runtime.AndroidAgentWal
import tech.zseven.rish.runtime.AndroidLiveTasks
import java.io.File
import java.util.UUID

/**
 * The round journal on Android runs one round through the shared reducer:
 * created against a real transcript, claimed by this process, dispatched, and
 * queried back. The journal decides nothing; these are the answers the core
 * gives, applied here.
 */
@RunWith(AndroidJUnit4::class)
class AndroidAgentRoundJournalTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val fingerprint = "c".repeat(64)

    private fun directory(): File =
        File(context.noBackupFilesDir, "round-test-${UUID.randomUUID()}").apply { mkdirs() }

    private fun uuid() = UUID.randomUUID().toString()

    private fun workspaceRoot(): JSONObject = JSONObject()
        .put("schema_version", 1).put("kind", "workspace")
        .put("workspace_id", uuid()).put("project_id", JSONObject.NULL)
        .put("root_fingerprint_sha256", fingerprint)
        .put("workspace_binding_revision", 1)
        .put("capabilities", JSONArray().put("file_read"))

    private fun locator(taskId: String, attemptId: String, roundId: String): JSONObject =
        JSONObject().put("schema_version", 1).put("task_id", taskId)
            .put("attempt_id", attemptId).put("round_id", roundId).put("round_index", 0)

    @Test fun aRoundIsCreatedClaimedDispatchedAndQueriedThroughTheCore() {
        val root = directory()
        try {
            val wal = AndroidAgentWal(root)
            val liveTasks = AndroidLiveTasks()
            val transcripts = AndroidAgentTranscriptStore(wal)
            val journal = AndroidAgentRoundJournal(wal, liveTasks)
            val taskId = uuid()
            val attemptId = uuid()
            val roundId = uuid()
            val rootValue = workspaceRoot()
            val transcript = transcripts.create(JSONObject().put("schema_version", 1)
                .put("attempt_id", attemptId).put("root", rootValue))!!
            val where = locator(taskId, attemptId, roundId)
            val nativeTask = uuid()
            liveTasks.register(nativeTask)
            val owner = JSONObject().put("schema_version", 1).put("task_id", taskId)
                .put("launch_id", AndroidAgentWal.launchId).put("native_task_id", nativeTask)
                .put("owner_generation", 1).put("heartbeat_at", "2026-09-15T00:00:00.000Z")
            val round = JSONObject()
                .put("schema_version", 3).put("locator", where).put("row_revision", 1)
                .put("root_fingerprint_sha256", fingerprint).put("binding_revision", 1)
                .put("request_sha256", "a".repeat(64))
                .put("transcript_before", transcript)
                .put("launch_attempt", 1).put("state", "in_flight").put("owner", owner)
                .put("failure_code", JSONObject.NULL)
                .put("completion_receipt", JSONObject.NULL)
                .put("transcript_after", JSONObject.NULL)
                .put("calls", JSONArray()).put("batch_class", JSONObject.NULL)
                .put("executable_call_count", 0).put("denied_call_count", 0)
                .put("terminal_kind", JSONObject.NULL)
                .put("created_at", "2026-09-15T00:00:00.000Z")
                .put("updated_at", "2026-09-15T00:00:00.000Z")
            val insertCas = JSONObject().put("schema_version", 1).put("locator", where)
                .put("expected_absent", true)
                .put("expected_transcript_generation", transcript.getLong("generation"))
                .put("expected_transcript_sha256", transcript.getString("transcript_sha256"))
                .put("expected_root_fingerprint_sha256", fingerprint)
                .put("expected_binding_revision", 1)
            val created = journal.create(insertCas, round)
            assertNotNull("the round was not created", created)
            assertEquals("inserted", created!!.getString("status"))
            // Creating the same round again is the explicit no-op, not a
            // second row and not a failure.
            assertEquals("already_present", journal.create(insertCas, round)!!.getString("status"))
            // The dispatch marker was inserted with the row and starts undispatched.
            val state = wal.snapshot()
            assertEquals(1, state.getJSONArray("rounds").length())
            val marker = state.getJSONArray("dispatch").getJSONObject(0)
            assertEquals("round", marker.getString("kind"))
            assertEquals("not_dispatched", marker.getString("dispatch_state"))
            val row = created.getJSONObject("row")
            // The round CAS is schema 2, unlike the locator and the insert CAS.
            val cas = JSONObject().put("schema_version", 2).put("locator", where)
                .put("expected_row_revision", row.get("row_revision"))
                .put("expected_state", row.getString("state"))
                .put("expected_owner_generation", owner.get("owner_generation"))
                .put("expected_launch_id", owner.getString("launch_id"))
                .put("expected_native_task_id", owner.getString("native_task_id"))
                .put("expected_transcript_generation", transcript.getLong("generation"))
                .put("expected_transcript_sha256", transcript.getString("transcript_sha256"))
                .put("expected_root_fingerprint_sha256", fingerprint)
                .put("expected_binding_revision", 1)
            val dispatched = journal.markDispatched(cas)
            assertNotNull(dispatched)
            assertEquals("dispatched", wal.snapshot().getJSONArray("dispatch")
                .getJSONObject(0).getString("dispatch_state"))
            val queried = journal.query(where)
            assertNotNull(queried)
            assertEquals("in_flight", queried!!.getJSONObject("row").getString("state"))
        } finally { root.deleteRecursively() }
    }

    @Test fun aRoundWhoseTranscriptMovedIsRefused() {
        val root = directory()
        try {
            val wal = AndroidAgentWal(root)
            val journal = AndroidAgentRoundJournal(wal, AndroidLiveTasks())
            val taskId = uuid(); val attemptId = uuid(); val roundId = uuid()
            val transcripts = AndroidAgentTranscriptStore(wal)
            val transcript = transcripts.create(JSONObject().put("schema_version", 1)
                .put("attempt_id", attemptId).put("root", workspaceRoot()))!!
            val where = locator(taskId, attemptId, roundId)
            // The CAS names a transcript generation the store never had.
            val insertCas = JSONObject().put("schema_version", 1).put("locator", where)
                .put("expected_absent", true)
                .put("expected_transcript_generation", transcript.getLong("generation") + 5)
                .put("expected_transcript_sha256", transcript.getString("transcript_sha256"))
                .put("expected_root_fingerprint_sha256", fingerprint)
                .put("expected_binding_revision", 1)
            try {
                journal.create(insertCas, JSONObject().put("schema_version", 3)
                    .put("locator", where).put("transcript_before", transcript))
                fail("a round was created against a transcript the CAS does not name")
            } catch (refused: AndroidAgentRoundJournal.Refused) {
                assertEquals(1, refused.code)
            }
            assertEquals(0, wal.snapshot().getJSONArray("rounds").length())
        } finally { root.deleteRecursively() }
    }

    /**
     * A round whose writer is gone is reconciled rather than left in flight.
     *
     * The core reads this operation's compare-and-set as `cas`; the journal
     * sent it as `expected_cas`, so every reconcile answered InvalidArgument
     * and each caller quietly kept the row it already had. A dispatched round
     * then stayed `in_flight` for good -- and an `in_flight` round is residue
     * no discard clears, so the attempt it belongs to could never be
     * finalized and its transcript cleanup never drained.
     */
    @Test fun aRoundWhoseWriterIsGoneIsReconciled() {
        val root = directory()
        try {
            val wal = AndroidAgentWal(root)
            val liveTasks = AndroidLiveTasks()
            val transcripts = AndroidAgentTranscriptStore(wal)
            val journal = AndroidAgentRoundJournal(wal, liveTasks)
            val taskId = uuid(); val attemptId = uuid(); val roundId = uuid()
            val transcript = transcripts.create(JSONObject().put("schema_version", 1)
                .put("attempt_id", attemptId).put("root", workspaceRoot()))!!
            val where = locator(taskId, attemptId, roundId)
            val nativeTask = uuid()
            liveTasks.register(nativeTask)
            val owner = JSONObject().put("schema_version", 1).put("task_id", taskId)
                .put("launch_id", AndroidAgentWal.launchId).put("native_task_id", nativeTask)
                .put("owner_generation", 1).put("heartbeat_at", "2026-09-15T00:00:00.000Z")
            val round = JSONObject()
                .put("schema_version", 3).put("locator", where).put("row_revision", 1)
                .put("root_fingerprint_sha256", fingerprint).put("binding_revision", 1)
                .put("request_sha256", "a".repeat(64))
                .put("transcript_before", transcript)
                .put("launch_attempt", 1).put("state", "in_flight").put("owner", owner)
                .put("failure_code", JSONObject.NULL)
                .put("completion_receipt", JSONObject.NULL)
                .put("transcript_after", JSONObject.NULL)
                .put("calls", JSONArray()).put("batch_class", JSONObject.NULL)
                .put("executable_call_count", 0).put("denied_call_count", 0)
                .put("terminal_kind", JSONObject.NULL)
                .put("created_at", "2026-09-15T00:00:00.000Z")
                .put("updated_at", "2026-09-15T00:00:00.000Z")
            val insertCas = JSONObject().put("schema_version", 1).put("locator", where)
                .put("expected_absent", true)
                .put("expected_transcript_generation", transcript.getLong("generation"))
                .put("expected_transcript_sha256", transcript.getString("transcript_sha256"))
                .put("expected_root_fingerprint_sha256", fingerprint)
                .put("expected_binding_revision", 1)
            val created = journal.create(insertCas, round)!!
            fun casFor(row: JSONObject): JSONObject = JSONObject()
                .put("schema_version", 2).put("locator", where)
                .put("expected_row_revision", row.get("row_revision"))
                .put("expected_state", row.getString("state"))
                .put("expected_owner_generation", owner.get("owner_generation"))
                .put("expected_launch_id", owner.getString("launch_id"))
                .put("expected_native_task_id", owner.getString("native_task_id"))
                .put("expected_transcript_generation", transcript.getLong("generation"))
                .put("expected_transcript_sha256", transcript.getString("transcript_sha256"))
                .put("expected_root_fingerprint_sha256", fingerprint)
                .put("expected_binding_revision", 1)
            val dispatched = journal.markDispatched(casFor(created.getJSONObject("row")))!!
            val cas = casFor(dispatched.getJSONObject("row"))
            // The core refuses to reconcile a row somebody is still running,
            // so the owner has to be released first -- which is exactly what
            // the round service does when its provider call fails.
            liveTasks.unregister(nativeTask)
            val reconciled = journal.reconcile(where, cas)
            assertNotNull("the round was not reconciled", reconciled)
            val row = reconciled!!.getJSONObject("row")
            // A dispatched round may have reached the provider, so its
            // outcome is unknowable rather than retryable.
            assertEquals("ambiguous", row.getString("state"))
            assertEquals("E_AGENT_ROUND_AMBIGUOUS", row.getString("failure_code"))
            assertEquals(JSONObject.NULL, row.get("owner"))
            assertEquals(
                "ambiguous",
                wal.snapshot().getJSONArray("rounds").getJSONObject(0).getString("state"),
            )
        } finally { root.deleteRecursively() }
    }

    /**
     * A round that was never dispatched keeps the reason it was not.
     *
     * The transport refuses some requests while it is still building them --
     * an attachment it cannot carry, a dialect that cannot express a round
     * transcript -- and that refusal is the only account of why the turn
     * ended. It used to be flattened into `E_AGENT_PERSISTENCE` here, which
     * reads to a person as a save that could not be confirmed, with Retry
     * save as the only advice; every later reader and every restart took the
     * row's code, so the cause was gone before it left this process.
     */
    @Test fun aRoundSettledBeforeDispatchKeepsItsCause() {
        val root = directory()
        try {
            val wal = AndroidAgentWal(root)
            val liveTasks = AndroidLiveTasks()
            val transcripts = AndroidAgentTranscriptStore(wal)
            val journal = AndroidAgentRoundJournal(wal, liveTasks)
            val taskId = uuid(); val attemptId = uuid(); val roundId = uuid()
            val transcript = transcripts.create(JSONObject().put("schema_version", 1)
                .put("attempt_id", attemptId).put("root", workspaceRoot()))!!
            val where = locator(taskId, attemptId, roundId)
            val nativeTask = uuid()
            liveTasks.register(nativeTask)
            val owner = JSONObject().put("schema_version", 1).put("task_id", taskId)
                .put("launch_id", AndroidAgentWal.launchId).put("native_task_id", nativeTask)
                .put("owner_generation", 1).put("heartbeat_at", "2026-09-15T00:00:00.000Z")
            val round = JSONObject()
                .put("schema_version", 3).put("locator", where).put("row_revision", 1)
                .put("root_fingerprint_sha256", fingerprint).put("binding_revision", 1)
                .put("request_sha256", "a".repeat(64))
                .put("transcript_before", transcript)
                .put("launch_attempt", 1).put("state", "in_flight").put("owner", owner)
                .put("failure_code", JSONObject.NULL)
                .put("completion_receipt", JSONObject.NULL)
                .put("transcript_after", JSONObject.NULL)
                .put("calls", JSONArray()).put("batch_class", JSONObject.NULL)
                .put("executable_call_count", 0).put("denied_call_count", 0)
                .put("terminal_kind", JSONObject.NULL)
                .put("created_at", "2026-09-15T00:00:00.000Z")
                .put("updated_at", "2026-09-15T00:00:00.000Z")
            val insertCas = JSONObject().put("schema_version", 1).put("locator", where)
                .put("expected_absent", true)
                .put("expected_transcript_generation", transcript.getLong("generation"))
                .put("expected_transcript_sha256", transcript.getString("transcript_sha256"))
                .put("expected_root_fingerprint_sha256", fingerprint)
                .put("expected_binding_revision", 1)
            val created = journal.create(insertCas, round)!!
            val cas = JSONObject().put("schema_version", 2).put("locator", where)
                .put("expected_row_revision", created.getJSONObject("row").get("row_revision"))
                .put("expected_state", "in_flight")
                .put("expected_owner_generation", owner.get("owner_generation"))
                .put("expected_launch_id", owner.getString("launch_id"))
                .put("expected_native_task_id", owner.getString("native_task_id"))
                .put("expected_transcript_generation", transcript.getLong("generation"))
                .put("expected_transcript_sha256", transcript.getString("transcript_sha256"))
                .put("expected_root_fingerprint_sha256", fingerprint)
                .put("expected_binding_revision", 1)
            // Never marked dispatched: this is the round the transport
            // refused while the request was still being assembled.
            liveTasks.unregister(nativeTask)
            val settled = journal.reconcile(where, cas, "E_AGENT_CAPABILITY")
            assertNotNull("the round was not settled", settled)
            val row = settled!!.getJSONObject("row")
            assertEquals("failed_retryable", row.getString("state"))
            assertEquals("E_AGENT_CAPABILITY", row.getString("failure_code"))
            // And it survives in the log, which is what a reader after a
            // restart actually sees.
            assertEquals(
                "E_AGENT_CAPABILITY",
                wal.snapshot().getJSONArray("rounds").getJSONObject(0).getString("failure_code"),
            )
        } finally { root.deleteRecursively() }
    }
}
