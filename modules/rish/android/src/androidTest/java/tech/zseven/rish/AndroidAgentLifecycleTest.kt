package tech.zseven.rish

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.MediumTest
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.AndroidAgentLifecycleService
import tech.zseven.rish.runtime.AndroidAgentOperations
import tech.zseven.rish.runtime.AndroidAgentRootResolver
import tech.zseven.rish.runtime.AndroidAgentWal
import tech.zseven.rish.runtime.AndroidRuntimeState
import tech.zseven.rish.runtime.AndroidSessionStore
import tech.zseven.rish.runtime.AndroidWorkspaceRegistry
import tech.zseven.rish.runtime.RishAgentCoreNative
import java.io.File
import java.util.UUID

/**
 * How a turn ends on Android: `finalize_agent_attempt` and
 * `discard_agent_attempt`.
 *
 * The controller calls both on every completed turn, in that order. Without
 * them an agent can run every tool it likes and the turn never finishes, so
 * these are on the happy path rather than only on a recovery path.
 *
 * **What is asserted.** A finalize whose session does not prove out answers a
 * conflict *object*, with the operation id and failure code the controller
 * branches on -- not an exception, and not silence. That is the shape the
 * whole refusal path is built to produce, and reaching it means the request
 * shape passed, the committed session was read, the operation relation was
 * queried and the core decided. The shape tests then check that a request the
 * core does not recognise never gets that far.
 *
 * Still uncovered: a finalize that *settles*, which needs a prepared authority
 * over a root this device holds and a session whose attempt is terminal. That
 * is a whole turn, and it belongs to the end-to-end run rather than here.
 */
@RunWith(AndroidJUnit4::class)
@MediumTest
class AndroidAgentLifecycleTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    private class Fixture(
        val service: AndroidAgentLifecycleService,
        val ids: AgentSessionFixture.Ids,
        val snapshot: JSONObject,
    )

    private fun fixture(body: (Fixture) -> Unit) {
        assumeTrue("rish agent core is not staged in this build", RishAgentCoreNative.available)
        val name = "lifecycle-${UUID.randomUUID()}"
        val walRoot = File(context.noBackupFilesDir, name).apply { mkdirs() }
        val home = File(context.cacheDir, name)
        val sessions = AndroidSessionStore(context, name)
        val wal = AndroidAgentWal(walRoot)
        val workspaces = AndroidWorkspaceRegistry(home)
        val roots = AndroidAgentRootResolver(workspaces)
        val service = AndroidAgentLifecycleService(
            wal, sessions, AndroidAgentOperations(wal), roots,
        )
        val ids = AgentSessionFixture.Ids()
        try {
            body(Fixture(service, ids, AgentSessionFixture.commit(sessions, ids)))
        } finally {
            walRoot.deleteRecursively()
            home.deleteRecursively()
        }
    }

    private fun cas(ids: AgentSessionFixture.Ids, snapshot: JSONObject): JSONObject =
        JSONObject().put("schema_version", 1)
            .put("conversation_id", ids.conversation).put("task_id", ids.task)
            .put("attempt_id", ids.attempt)
            .put("expected_controller_generation", 0)
            .put("expected_journal_revision", 0)
            .put("expected_session_generation", snapshot.getLong("generation"))
            .put("expected_session_sha256", snapshot.getString("session_sha256"))

    private fun finalizeRequest(f: Fixture): JSONObject = JSONObject()
        .put("schema_version", 2)
        .put("operation_id", UUID.randomUUID().toString())
        .put("controller_cas", cas(f.ids, f.snapshot))
        .put("committed_checkpoint", AgentSessionFixture.checkpoint(f.snapshot))
        .put("task_id", f.ids.task).put("conversation_id", f.ids.conversation)
        .put("attempt_id", f.ids.attempt)
        .put("terminal_reason", "completed")
        .put("cleanup_id", UUID.randomUUID().toString())
        .put(
            "transcript",
            JSONObject().put("schema_version", 1)
                .put("transcript_ref", UUID.randomUUID().toString())
                .put("transcript_sha256", DIGEST),
        )
        .put("root", JSONObject.NULL)

    private fun discardRequest(f: Fixture): JSONObject = JSONObject()
        .put("schema_version", 2)
        .put("operation_id", UUID.randomUUID().toString())
        .put("cleanup_id", UUID.randomUUID().toString())
        .put("task_id", f.ids.task).put("conversation_id", f.ids.conversation)
        .put("attempt_id", f.ids.attempt)
        .put("transcript_ref", UUID.randomUUID().toString())
        .put("transcript_sha256", DIGEST)

    /**
     * An attempt with no agent journal cannot be finalized, and the core says
     * so with a *conflict* rather than a bad-argument or a native failure.
     * The distinction is the assertion: reaching CONFLICT means the request
     * shape passed, the committed session was found and parsed, and the core
     * decided over its contents. A host that could not read the session would
     * refuse with E_AGENT_PERSISTENCE here instead.
     */
    @Test
    fun aFinalizeOfAnAttemptWithNoAgentJournalIsAConflict() = fixture { f ->
        val code = try {
            "settled: " + f.service.finalize(finalizeRequest(f))
        } catch (refused: AndroidAgentLifecycleService.Refused) {
            refused.code
        }
        assertEquals("E_AGENT_CONFLICT", code)
    }

    /** A request whose shape the core does not recognise never gets that far. */
    @Test
    fun aMalformedFinalizeIsRefusedOnItsShape() = fixture { f ->
        for (broken in listOf(
            JSONObject(),
            finalizeRequest(f).put("schema_version", 1),
            JSONObject(finalizeRequest(f).toString()).also { it.remove("cleanup_id") },
            // A checkpoint the controller CAS does not agree with.
            finalizeRequest(f).put(
                "committed_checkpoint",
                AgentSessionFixture.checkpoint(f.snapshot, journalRevision = 7),
            ),
        )) {
            val code = try {
                f.service.finalize(broken).toString()
            } catch (refused: AndroidAgentLifecycleService.Refused) {
                refused.code
            }
            assertTrue("$broken was not refused: $code", code.startsWith("E_AGENT_"))
        }
    }

    /**
     * Discarding residue that was never there is a conflict, because the core
     * will not close a cleanup it cannot prove is the discarded one.
     */
    @Test
    fun aDiscardWithNoResidueIsRefused() = fixture { f ->
        val code = try {
            f.service.discard(discardRequest(f)).toString()
        } catch (refused: AndroidAgentLifecycleService.Refused) {
            refused.code
        }
        assertTrue("got: $code", code.startsWith("E_AGENT_"))
    }

    @Test
    fun aMalformedDiscardIsRefusedOnItsShape() = fixture { f ->
        for (broken in listOf(
            JSONObject(),
            discardRequest(f).put("schema_version", 1),
            JSONObject(discardRequest(f).toString()).also { it.remove("transcript_ref") },
        )) {
            val code = try {
                f.service.discard(broken).toString()
            } catch (refused: AndroidAgentLifecycleService.Refused) {
                refused.code
            }
            assertTrue("$broken was not refused: $code", code.startsWith("E_AGENT_"))
        }
    }

    private fun interruptRequest(f: Fixture): JSONObject = JSONObject()
        .put("schema_version", 2)
        .put("operation_id", UUID.randomUUID().toString())
        .put("cleanup_id", UUID.randomUUID().toString())
        .put("task_id", f.ids.task).put("conversation_id", f.ids.conversation)
        .put("attempt_id", f.ids.attempt)
        .put("transcript_ref", UUID.randomUUID().toString())
        .put("transcript_sha256", DIGEST)
        .put("reason", "failed")
        .put("expected_session_generation", f.snapshot.getLong("generation"))
        .put("expected_session_sha256", f.snapshot.getString("session_sha256"))

    /**
     * An interruption the session does not record is a conflict, not a
     * settlement. This is the drain the controller runs over its cleanup
     * outbox, and an entry it cannot prove must stay durable rather than be
     * quietly dropped: the attempt behind it can never be resumed either way,
     * and the next launch tries again.
     */
    @Test
    fun anInterruptionTheSessionDoesNotRecordIsAConflict() = fixture { f ->
        val code = try {
            "settled: " + f.service.interrupt(interruptRequest(f))
        } catch (refused: AndroidAgentLifecycleService.Refused) {
            refused.code
        }
        assertEquals("E_AGENT_CONFLICT", code)
    }

    /** And one whose shape the coordinator refuses never reads a store. */
    @Test
    fun aMalformedInterruptionIsRefusedOnItsShape() = fixture { f ->
        for (broken in listOf(
            JSONObject(),
            interruptRequest(f).put("schema_version", 1),
            JSONObject(interruptRequest(f).toString()).also { it.remove("reason") },
        )) {
            val code = try {
                f.service.interrupt(broken).toString()
            } catch (refused: AndroidAgentLifecycleService.Refused) {
                refused.code
            }
            assertTrue("$broken was not refused: $code", code.startsWith("E_AGENT_"))
        }
    }

    /** The bridge's own wiring holds this service, and holds one of it. */
    @Test
    fun theBridgeOwnsThisService() {
        assumeTrue("rish agent core is not staged in this build", RishAgentCoreNative.available)
        val app = ApplicationProvider.getApplicationContext<Application>()
        val state = AndroidRuntimeState.get(app)
        assertNotNull(state.lifecycle)
        assertTrue(state.lifecycle === AndroidRuntimeState.get(app).lifecycle)
    }

    private companion object {
        const val DIGEST = "0000000000000000000000000000000000000000000000000000000000000000"
    }
}
