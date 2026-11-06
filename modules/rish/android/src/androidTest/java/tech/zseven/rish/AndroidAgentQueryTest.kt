package tech.zseven.rish

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.MediumTest
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.AndroidAgentExecutionLedger
import tech.zseven.rish.runtime.AndroidAgentOperations
import tech.zseven.rish.runtime.AndroidAgentQueryService
import tech.zseven.rish.runtime.AndroidAgentRootResolver
import tech.zseven.rish.runtime.AndroidAgentTranscriptStore
import tech.zseven.rish.runtime.AndroidAgentWal
import tech.zseven.rish.runtime.AndroidLiveTasks
import tech.zseven.rish.runtime.AndroidPreparedAttemptStore
import tech.zseven.rish.runtime.AndroidSessionStore
import tech.zseven.rish.runtime.AndroidWorkspaceRegistry
import tech.zseven.rish.runtime.RishAgentCoreNative
import java.io.File
import java.util.UUID

/**
 * The three reads: an attempt, one of its tool calls, and the residue a
 * discarded attempt leaves behind.
 *
 * All three refused outright on Android, which left a restarted controller
 * unable to ask the durable state anything at all. These hold the seams that
 * a compile cannot: that a query answers a *result* where the core shapes one
 * rather than throwing, and that it refuses on the request's own shape before
 * it reads a store.
 */
@RunWith(AndroidJUnit4::class)
@MediumTest
class AndroidAgentQueryTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    private class Fixture(
        val service: AndroidAgentQueryService,
        val sessions: AndroidSessionStore,
        val ids: AgentSessionFixture.Ids,
    )

    private fun fixture(body: (Fixture) -> Unit) {
        assumeTrue("rish agent core is not staged in this build", RishAgentCoreNative.available)
        val name = "query-${UUID.randomUUID()}"
        val walRoot = File(context.noBackupFilesDir, name).apply { mkdirs() }
        val home = File(context.cacheDir, name)
        val sessions = AndroidSessionStore(context, name)
        val wal = AndroidAgentWal(walRoot)
        val roots = AndroidAgentRootResolver(AndroidWorkspaceRegistry(home))
        val operations = AndroidAgentOperations(wal)
        val service = AndroidAgentQueryService(
            wal, sessions, AndroidPreparedAttemptStore(sessions, wal, roots),
            AndroidAgentExecutionLedger(wal, AndroidLiveTasks(), operations),
            AndroidAgentTranscriptStore(wal),
        )
        try {
            body(Fixture(service, sessions, AgentSessionFixture.Ids()))
        } finally {
            walRoot.deleteRecursively()
            home.deleteRecursively()
        }
    }

    private fun cas(
        f: Fixture,
        snapshot: JSONObject,
        generation: Int = 0,
        journalRevision: Int = 0,
    ): JSONObject = JSONObject()
        .put("schema_version", 1)
        .put("conversation_id", f.ids.conversation).put("task_id", f.ids.task)
        .put("attempt_id", f.ids.attempt)
        .put("expected_controller_generation", generation)
        .put("expected_journal_revision", journalRevision)
        .put("expected_session_generation", snapshot.getLong("generation"))
        .put("expected_session_sha256", snapshot.getString("session_sha256"))

    /**
     * An attempt this device never prepared is *not found*, and saying so is
     * the whole point: a controller that cannot tell "never here" from "here
     * and conflicted" has nothing to decide with.
     */
    @Test
    fun anAttemptThisDeviceNeverPreparedIsNotFound() = fixture { f ->
        val workspace = UUID.randomUUID().toString()
        val snapshot = AgentSessionFixture.commit(
            f.sessions, f.ids,
            workspace = workspace,
            agent = AgentSessionFixture.agentJournal(workspace),
        )
        val result = f.service.query(
            JSONObject().put("schema_version", 2)
                .put("controller_cas", cas(f, snapshot, generation = 1, journalRevision = 1))
                .put("task_id", f.ids.task).put("conversation_id", f.ids.conversation)
                .put("attempt_id", f.ids.attempt)
                .put("expected_journal_revision", 1)
                .put("expected_session_generation", snapshot.getLong("generation"))
                .put("expected_session_sha256", snapshot.getString("session_sha256"))
                .put(
                    "expected_transcript",
                    JSONObject().put("schema_version", 1)
                        .put("transcript_ref", UUID.randomUUID().toString())
                        .put("transcript_sha256", AgentSessionFixture.DIGEST),
                )
                .put("expected_root_fingerprint_sha256", AgentSessionFixture.DIGEST)
                .put("expected_workspace_binding_revision", 1),
        )
        assertEquals("$result", "not_found", result.getString("status"))
    }

    /** A query whose shape the coordinator refuses never reads a store. */
    @Test
    fun aMalformedAttemptQueryIsRefusedOnItsShape() = fixture { f ->
        val code = try {
            "answered: " + f.service.query(JSONObject().put("schema_version", 2))
        } catch (refused: AndroidAgentQueryService.Refused) {
            refused.code
        }
        assertEquals("E_AGENT_BAD_ARGUMENTS", code)
    }

    /**
     * A cleanup nobody has heard of is `unknown` rather than a refusal: the
     * controller drains its outbox by asking about entries that may already
     * have been collected, and a throw there would strand them.
     */
    @Test
    fun anUnknownCleanupIsAnswered() = fixture { f ->
        val cleanupId = UUID.randomUUID().toString()
        val result = f.service.queryCleanup(
            JSONObject().put("schema_version", 2).put("cleanup_id", cleanupId),
        )
        assertEquals("unknown", result.getString("status"))
        assertEquals(cleanupId, result.getString("cleanup_id"))
        assertEquals(2, result.getInt("schema_version"))
    }

    /** A cleanup id that is not one is refused before the store is read. */
    @Test
    fun aMalformedCleanupQueryIsRefused() = fixture { f ->
        val code = try {
            "answered: " + f.service.queryCleanup(
                JSONObject().put("schema_version", 2).put("cleanup_id", "not-a-uuid")
                    .put("extra", true),
            )
        } catch (refused: AndroidAgentQueryService.Refused) {
            refused.code
        }
        assertEquals("E_AGENT_BAD_ARGUMENTS", code)
    }

    /**
     * A tool query over a session that has moved answers the session conflict
     * the core shapes, rather than throwing: the controller reconciles from
     * the answer.
     */
    @Test
    fun aToolQueryAgainstAMovedSessionAnswersAConflict() = fixture { f ->
        val workspace = UUID.randomUUID().toString()
        val snapshot = AgentSessionFixture.commit(
            f.sessions, f.ids,
            workspace = workspace,
            agent = AgentSessionFixture.agentJournal(workspace),
        )
        // The session is real; the generation the caller asserts is not.
        val stale = cas(f, snapshot, generation = 1, journalRevision = 1)
            .put("expected_session_generation", 99)
        val result = f.service.queryTool(
            JSONObject().put("schema_version", 2).put("controller_cas", stale)
                .put("task_id", f.ids.task).put("conversation_id", f.ids.conversation)
                .put("attempt_id", f.ids.attempt)
                .put("round_id", UUID.randomUUID().toString())
                .put("round_index", 0)
                .put("call_index", 0)
                .put("call_id", "call_00_aaaaaaaaaaaaaaaaaaaaaaaa")
                .put("idempotency_key", AgentSessionFixture.DIGEST)
                .put("expected_execution_revision", 0)
                .put(
                    "expected_transcript",
                    JSONObject().put("schema_version", 1)
                        .put("transcript_ref", UUID.randomUUID().toString())
                        .put("transcript_sha256", AgentSessionFixture.DIGEST),
                )
                .put("expected_root_fingerprint_sha256", AgentSessionFixture.DIGEST)
                .put("expected_workspace_binding_revision", 1),
        )
        assertTrue("$result", result.getString("status") == "conflict")
    }

}
