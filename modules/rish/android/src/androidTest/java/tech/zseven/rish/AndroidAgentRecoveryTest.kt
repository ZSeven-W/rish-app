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
import tech.zseven.rish.runtime.AndroidAgentProviderRoundService
import tech.zseven.rish.runtime.AndroidAgentQueryService
import tech.zseven.rish.runtime.AndroidAgentRecoveryService
import tech.zseven.rish.runtime.AndroidAgentRootResolver
import tech.zseven.rish.runtime.AndroidAgentRoundJournal
import tech.zseven.rish.runtime.AndroidAgentToolExecutionService
import tech.zseven.rish.runtime.AndroidAgentToolRegistry
import tech.zseven.rish.runtime.AndroidAgentTranscriptStore
import tech.zseven.rish.runtime.AndroidAgentWal
import tech.zseven.rish.runtime.AndroidCredentialStore
import tech.zseven.rish.runtime.AndroidLiveTasks
import tech.zseven.rish.runtime.AndroidModelTransport
import tech.zseven.rish.runtime.AndroidPreparedAttemptStore
import tech.zseven.rish.runtime.AndroidProviderConfiguration
import tech.zseven.rish.runtime.AndroidSessionStore
import tech.zseven.rish.runtime.AndroidWorkspaceRegistry
import tech.zseven.rish.runtime.AndroidWorkspaceToolExecutor
import tech.zseven.rish.runtime.RishAgentCoreNative
import java.io.File
import java.util.UUID

/**
 * Recovery's two actions.
 *
 * `reconcile` asks what became of a round or a tool call whose writer died;
 * `retry_failed_round` re-launches one the reconcile found failed retryably.
 * The second used to be refused outright, which meant a turn could be told it
 * was retryable and then never retried.
 *
 * **What these cannot cover.** Both actions need a prepared authority over a
 * root this device holds -- a whole turn -- so they stop at the root gate
 * here, exactly as the batch and execution tests do. What they hold is that
 * the shapes are accepted and that each action reaches that gate rather than
 * being refused before it: a retry that answered E_AGENT_NATIVE never asked
 * the core anything.
 */
@RunWith(AndroidJUnit4::class)
@MediumTest
class AndroidAgentRecoveryTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    private class Fixture(
        val service: AndroidAgentRecoveryService,
        val sessions: AndroidSessionStore,
        val ids: AgentSessionFixture.Ids,
        val workspace: String,
    )

    private fun fixture(body: (Fixture) -> Unit) {
        assumeTrue("rish agent core is not staged in this build", RishAgentCoreNative.available)
        val name = "recovery-${UUID.randomUUID()}"
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
            AndroidCredentialStore(context, name),
            AndroidProviderConfiguration(context, "$name.providers"),
        )
        val rounds = AndroidAgentProviderRoundService(
            sessions, prepared, AndroidAgentRoundJournal(wal, liveTasks), roots,
            AndroidAgentToolRegistry, transport, wal, operations, liveTasks, transcripts,
        )
        val executions = AndroidAgentToolExecutionService(
            wal, sessions, prepared, ledger, roots,
            AndroidWorkspaceToolExecutor(workspaces, roots), liveTasks, transcripts, operations,
        )
        val queries = AndroidAgentQueryService(wal, sessions, prepared, ledger, transcripts)
        try {
            body(
                Fixture(
                    AndroidAgentRecoveryService(
                        wal, sessions, prepared, queries, rounds, executions, roots, operations,
                    ),
                    sessions,
                    AgentSessionFixture.Ids(),
                    UUID.randomUUID().toString(),
                ),
            )
        } finally {
            walRoot.deleteRecursively()
            home.deleteRecursively()
        }
    }

    private fun request(f: Fixture, snapshot: JSONObject, action: String): JSONObject = JSONObject()
        .put("schema_version", 2)
        .put("operation_id", UUID.randomUUID().toString())
        .put(
            "controller_cas",
            JSONObject().put("schema_version", 1)
                .put("conversation_id", f.ids.conversation).put("task_id", f.ids.task)
                .put("attempt_id", f.ids.attempt)
                .put("expected_controller_generation", 1)
                .put("expected_journal_revision", 1)
                .put("expected_session_generation", snapshot.getLong("generation"))
                .put("expected_session_sha256", snapshot.getString("session_sha256")),
        )
        .put("committed_checkpoint", AgentSessionFixture.checkpoint(snapshot, 1))
        .put(
            "target",
            JSONObject().put("schema_version", 1).put("kind", "round")
                .put("task_id", f.ids.task).put("attempt_id", f.ids.attempt)
                .put("round_id", UUID.randomUUID().toString()).put("round_index", 0),
        )
        .put("action", action)
        .put("expected_round_revision", 1)
        .put("expected_execution_revision", JSONObject.NULL)
        .put(
            "expected_transcript",
            JSONObject().put("schema_version", 1)
                .put("transcript_ref", UUID.randomUUID().toString())
                .put("transcript_sha256", AgentSessionFixture.DIGEST),
        )
        .put("root", JSONObject.NULL)

    private fun committed(f: Fixture): JSONObject = AgentSessionFixture.commit(
        f.sessions, f.ids,
        workspace = f.workspace,
        // `round_in_flight` needs a round lineage the fixture does not build;
        // the phase is not what these hold.
        agent = AgentSessionFixture.agentJournal(f.workspace),
    )

    private fun refusal(f: Fixture, action: String): String = try {
        "recovered: " + f.service.recover(request(f, committed(f), action))
    } catch (refused: AndroidAgentRecoveryService.Refused) {
        refused.code
    }

    /**
     * Reconciling gets as far as the prepared authority, which this fixture
     * does not hold: the shape passed, the session was read and the request
     * was related to a real attempt before anything refused.
     */
    @Test
    fun aReconcileIsCarriedAsFarAsTheAuthority() = fixture { f ->
        assertEquals("E_AGENT_CONFLICT", refusal(f, "reconcile"))
    }

    /**
     * And a retry reaches the same gate. Before it existed the same request
     * answered E_AGENT_NATIVE at the very top without asking the core
     * anything, so a round reported as retryable could never be retried.
     */
    @Test
    fun aRetryIsCarriedAsFarAsTheAuthority() = fixture { f ->
        val code = refusal(f, "retry_failed_round")
        assertEquals("E_AGENT_CONFLICT", code)
        assertTrue("a retry must not be refused as unimplemented", code != "E_AGENT_NATIVE")
    }

    /** An action neither of those is refused rather than guessed at. */
    @Test
    fun anUnknownActionIsRefused() = fixture { f ->
        val code = refusal(f, "reconcile_everything")
        assertTrue(code, code.startsWith("E_AGENT_"))
    }

}
