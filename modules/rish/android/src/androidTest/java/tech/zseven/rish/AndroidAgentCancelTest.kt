package tech.zseven.rish

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.MediumTest
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.AndroidAgentCancelService
import tech.zseven.rish.runtime.AndroidAgentExecutionLedger
import tech.zseven.rish.runtime.AndroidAgentOperations
import tech.zseven.rish.runtime.AndroidAgentProviderRoundService
import tech.zseven.rish.runtime.AndroidAgentRootResolver
import tech.zseven.rish.runtime.AndroidAgentRoundJournal
import tech.zseven.rish.runtime.AndroidAgentToolRegistry
import tech.zseven.rish.runtime.AndroidAgentTranscriptStore
import tech.zseven.rish.runtime.AndroidAgentWal
import tech.zseven.rish.runtime.AndroidLiveTasks
import tech.zseven.rish.runtime.AndroidModelTransport
import tech.zseven.rish.runtime.AndroidPreparedAttemptStore
import tech.zseven.rish.runtime.AndroidProviderConfiguration
import tech.zseven.rish.runtime.AndroidCredentialStore
import tech.zseven.rish.runtime.AndroidSessionStore
import tech.zseven.rish.runtime.AndroidWorkspaceRegistry
import tech.zseven.rish.runtime.RishAgentCoreNative
import java.io.File
import java.util.UUID

/**
 * The stop button, at the seam where it was missing.
 *
 * `cancel_agent_attempt` was the third of the four operations Android never
 * declared, and a stop pressed mid-turn ended the turn as a conflict while the
 * round it was cancelling stayed claimed. These tests hold the two things that
 * made the first implementation wrong anyway: that a cancellation names its
 * attempt in `target`, so the operation has to be started as a *target*
 * operation; and that the rule proving the person really asked to stop reads
 * the committed session itself, not the proof of it.
 */
@RunWith(AndroidJUnit4::class)
@MediumTest
class AndroidAgentCancelTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    private class Fixture(
        val service: AndroidAgentCancelService,
        val sessions: AndroidSessionStore,
        val ids: AgentSessionFixture.Ids,
        val workspace: String,
        val eventId: String,
    )

    private fun fixture(body: (Fixture) -> Unit) {
        assumeTrue("rish agent core is not staged in this build", RishAgentCoreNative.available)
        val name = "cancel-${UUID.randomUUID()}"
        val walRoot = File(context.noBackupFilesDir, name).apply { mkdirs() }
        val home = File(context.cacheDir, name)
        val sessions = AndroidSessionStore(context, name)
        val wal = AndroidAgentWal(walRoot)
        val workspaces = AndroidWorkspaceRegistry(home)
        val roots = AndroidAgentRootResolver(workspaces)
        val operations = AndroidAgentOperations(wal)
        val liveTasks = AndroidLiveTasks()
        val ledger = AndroidAgentExecutionLedger(wal, liveTasks, operations)
        val prepared = AndroidPreparedAttemptStore(sessions, wal, roots)
        val transcripts = AndroidAgentTranscriptStore(wal)
        val transport = AndroidModelTransport(
            AndroidCredentialStore(context, name), AndroidProviderConfiguration(context, "$name.providers"),
        )
        val rounds = AndroidAgentProviderRoundService(
            sessions, prepared, AndroidAgentRoundJournal(wal, liveTasks), roots,
            AndroidAgentToolRegistry, transport, wal, operations, liveTasks, transcripts,
        )
        val service = AndroidAgentCancelService(
            wal, sessions, prepared, ledger, rounds, roots, operations,
        )
        val ids = AgentSessionFixture.Ids()
        try {
            body(Fixture(service, sessions, ids, UUID.randomUUID().toString(), UUID.randomUUID().toString()))
        } finally {
            walRoot.deleteRecursively()
            home.deleteRecursively()
        }
    }

    private fun token(f: Fixture, phase: String = "ready_for_round"): JSONObject = JSONObject()
        .put("schema_version", 2).put("issuer", "completion_controller")
        .put("source_event_id", f.eventId).put("token", f.eventId)
        .put("task_id", f.ids.task).put("attempt_id", f.ids.attempt)
        .put("expected_phase", phase).put("reason_code", "E_AGENT_CANCELLED")

    private fun request(
        f: Fixture,
        snapshot: JSONObject,
        journalRevision: Int = 1,
    ): JSONObject = JSONObject()
        .put("schema_version", 2)
        .put("operation_id", UUID.randomUUID().toString())
        .put(
            "controller_cas",
            JSONObject().put("schema_version", 1)
                .put("conversation_id", f.ids.conversation).put("task_id", f.ids.task)
                .put("attempt_id", f.ids.attempt)
                // The agent journal the fixture writes is at generation 1.
                .put("expected_controller_generation", if (journalRevision == 0) 0 else 1)
                .put("expected_journal_revision", journalRevision)
                .put("expected_session_generation", snapshot.getLong("generation"))
                .put("expected_session_sha256", snapshot.getString("session_sha256")),
        )
        .put("committed_checkpoint", AgentSessionFixture.checkpoint(snapshot, journalRevision))
        .put(
            "target",
            JSONObject().put("schema_version", 1).put("kind", "attempt")
                .put("task_id", f.ids.task).put("attempt_id", f.ids.attempt),
        )
        .put("cancel_token", token(f))
        .put("expected_round_revision", JSONObject.NULL)
        .put("expected_execution_revision", JSONObject.NULL)
        .put(
            "expected_transcript",
            JSONObject().put("schema_version", 1)
                .put("transcript_ref", UUID.randomUUID().toString())
                .put("transcript_sha256", AgentSessionFixture.DIGEST),
        )
        .put("root", JSONObject.NULL)

    /**
     * An attempt the session never says was cancelled is not cancellable, and
     * the answer is a conflict result rather than a throw: the controller has
     * already written its own cancelled journal and needs an answer it can
     * reconcile against, not an exception.
     */
    @Test
    fun aCancellationTheSessionDoesNotRecordIsRefusedAsOne() = fixture { f ->
        // Everything a cancellation needs except the event that says the
        // person asked for one.
        val snapshot = AgentSessionFixture.commit(
            f.sessions, f.ids,
            workspace = f.workspace,
            agent = AgentSessionFixture.agentJournal(f.workspace),
        )
        val result = f.service.cancel(request(f, snapshot))
        assertEquals("conflict", result.getString("status"))
        assertEquals("E_AGENT_CANCELLED", result.getString("failure_code"))
    }

    /**
     * The one that matters. With the cancel event in the session and the
     * attempt in the phase the token names, the source *is* proved, and the
     * cancellation moves on to the next gate: the prepared root, which this
     * fixture does not hold, so it stops there.
     *
     * The assertion is which refusal comes back. A host that hands the proving
     * rule the `session_proof` output instead of the session -- that output
     * carries no session, so the rule sees null -- answers E_AGENT_CANCELLED
     * exactly like the case above, and every cancellation is silently
     * unprovable. Getting as far as E_AGENT_ROOT_STALE is what says the rule
     * read a real session and agreed with it.
     *
     * Cancelling for real needs a prepared authority over a root this device
     * holds, which is a whole turn; that is covered by the end-to-end run, not
     * here, exactly as the batch and execution tests draw the same line.
     */
    @Test
    fun aCancellationTheSessionRecordsIsProvedFromTheSession() = fixture { f ->
        val snapshot = AgentSessionFixture.commit(
            f.sessions, f.ids,
            workspace = f.workspace,
            agent = AgentSessionFixture.agentJournal(f.workspace),
            events = JSONArray().put(AgentSessionFixture.cancelEvent(f.ids.attempt, f.eventId)),
        )
        val result = f.service.cancel(request(f, snapshot))
        assertEquals("$result", "E_AGENT_ROOT_STALE", result.getString("failure_code"))
    }

    /** A request the coordinator's shape rule refuses never reaches a store. */
    @Test
    fun aMalformedCancellationIsRefusedOnItsShape() = fixture { f ->
        val snapshot = AgentSessionFixture.commit(f.sessions, f.ids)
        val malformed = request(f, snapshot, journalRevision = 0).apply { remove("cancel_token") }
        val code = try {
            "answered: " + f.service.cancel(malformed)
        } catch (refused: AndroidAgentCancelService.Refused) {
            refused.code
        }
        assertEquals("E_AGENT_BAD_ARGUMENTS", code)
    }

}
