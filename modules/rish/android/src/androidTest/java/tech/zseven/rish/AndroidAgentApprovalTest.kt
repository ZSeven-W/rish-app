package tech.zseven.rish

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.MediumTest
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.AndroidAgentApprovalService
import tech.zseven.rish.runtime.AndroidRuntimeState
import tech.zseven.rish.runtime.RishAgentCoreNative
import java.util.UUID

/**
 * `bind_agent_approval` on a device.
 *
 * This is the step between a person deciding and a tool running, and the one
 * place where "the world moved while they were reading" has to become a
 * refusal rather than an effect.
 *
 * **What these assert, and why it is not another empty refusal.** A bind with
 * no prepared authority behind it is a *conflict*, and a conflict here is not
 * an exception thrown on the way in -- it is a decision the core makes, that
 * the host commits against the operation id, and that a repeat of the same
 * request must answer with **byte for byte the same thing** without deciding
 * again. So the tests below check the conflict's own fields and then check
 * that asking twice replays. That exercises the operation relation for real:
 * `start`, `bind_check`, `commit_prepare`, `commit_apply` and the replay path
 * all have to work, and a relation that quietly wrote nothing would fail the
 * second assertion.
 *
 * Still uncovered: an *allowed* bind, which needs a prepared authority and a
 * batch that minted the token, and a denial's settlement. Both need a round
 * that a model actually answered.
 */
@RunWith(AndroidJUnit4::class)
@MediumTest
class AndroidAgentApprovalTest {

    private fun service(): AndroidAgentApprovalService {
        assumeTrue("rish agent core is not staged in this build", RishAgentCoreNative.available)
        val app = ApplicationProvider.getApplicationContext<Application>()
        return AndroidRuntimeState.get(app).approvals
    }

    private class Ids(
        val operation: String = UUID.randomUUID().toString(),
        val task: String = UUID.randomUUID().toString(),
        val conversation: String = UUID.randomUUID().toString(),
        val attempt: String = UUID.randomUUID().toString(),
        val round: String = UUID.randomUUID().toString(),
        val token: String = UUID.randomUUID().toString(),
    )

    private fun cas(ids: Ids): JSONObject = JSONObject().put("schema_version", 1)
        .put("conversation_id", ids.conversation)
        .put("task_id", ids.task).put("attempt_id", ids.attempt)
        .put("expected_controller_generation", 0)
        .put("expected_journal_revision", 0)
        .put("expected_session_generation", 1)
        .put("expected_session_sha256", DIGEST)

    private fun token(ids: Ids): JSONObject = JSONObject().put("schema_version", 2)
        .put("token", ids.token).put("controller_cas", cas(ids))
        .put("task_id", ids.task).put("attempt_id", ids.attempt)
        .put("round_id", ids.round).put("round_index", 0)
        .put("batch_call_ids", JSONArray().put(CALL))
        .put("batch_arguments_sha256", JSONArray().put(DIGEST))
        .put("batch_revision", 1).put("manifest_sha256", DIGEST)
        .put("call_index", 0).put("call_id", CALL)
        .put("name", "write_file").put("arguments_sha256", DIGEST)
        .put("idempotency_key", DIGEST).put("root_fingerprint_sha256", DIGEST)
        .put("binding_revision", 1).put("policy_version", "agent-v1")
                // A mutation's token always carries the full decision set, and the
        // core refuses any other spelling of it.
        .put("registry_version", 2).put("access", "conversation_confirm")
        .put(
            "allowed_decisions",
            JSONArray().put("denied").put("allow_once")
                .put("allow_conversation").put("cancelled"),
        )

    private fun request(ids: Ids, decision: String = "allow_once"): JSONObject =
        JSONObject().put("schema_version", 2)
            .put("operation_id", ids.operation)
            .put("controller_cas", cas(ids))
            .put(
                "committed_checkpoint",
                JSONObject().put("schema_version", 1).put("journal_revision", 0)
                    .put("session_generation", 1).put("session_sha256", DIGEST),
            )
            .put("task_id", ids.task).put("conversation_id", ids.conversation)
            .put("attempt_id", ids.attempt).put("round_id", ids.round)
            .put("round_index", 0).put("manifest_sha256", DIGEST)
            .put("batch_revision", 1).put("call_index", 0).put("call_id", CALL)
            .put("token", token(ids)).put("decision", decision)
            .put("deny_message", JSONObject.NULL)

    /**
     * No authority, no batch, no session: the core's answer is a conflict, and
     * it is a conflict *this operation committed*, not an exception. The
     * fields are the ones the controller branches on.
     */
    @Test
    fun aBindWithNothingBehindItIsCommittedAsAConflict() {
        val ids = Ids()
        val result = service().bind(request(ids))
        assertEquals("conflict", result.getString("status"))
        assertEquals("E_AGENT_APPROVAL", result.getString("failure_code"))
        assertEquals(ids.operation, result.getString("operation_id"))
        assertEquals(1, result.getInt("expected_batch_revision"))
    }

    /**
     * The operation relation is the point of this test. Asking the same thing
     * twice must answer the same thing, decided once. If `start` never wrote a
     * record, or `commit_apply` never stored the result, the second call would
     * re-decide over a world that had moved -- and on the allow path that is
     * the difference between a tool running once and running twice.
     */
    @Test
    fun theSameBindAskedTwiceReplaysItsAnswer() {
        val service = service()
        val ids = Ids()
        val first = service.bind(request(ids))
        val second = service.bind(request(ids))
        assertEquals(
            RishAgentCoreNative.canonical(first.toString()),
            RishAgentCoreNative.canonical(second.toString()),
        )
        assertNotNull(RishAgentCoreNative.canonical(first.toString()))
    }

    /**
     * A different operation id is a different operation, even for the same
     * call. The relation must not collapse them, or a retried decision would
     * silently answer with an older one.
     */
    @Test
    fun aDifferentOperationIdIsADifferentOperation() {
        val service = service()
        val ids = Ids()
        val first = service.bind(request(ids))
        val again = service.bind(request(ids).put("operation_id", UUID.randomUUID().toString()))
        assertEquals("conflict", again.getString("status"))
        assertTrue(first.getString("operation_id") != again.getString("operation_id"))
    }

    /** A malformed request never reaches the relation. */
    @Test
    fun aMalformedRequestIsRefusedOnItsShape() {
        val service = service()
        val ids = Ids()
        for (broken in listOf(
            JSONObject(),
            JSONObject().put("schema_version", 2),
            request(ids).put("schema_version", 1),
            request(ids).put("round_index", -1),
            request(ids).put("call_index", 99),
            // A request missing a key the shape names exactly.
            JSONObject(request(ids).toString()).also { it.remove("token") },
            // A deny message on a decision that is not a denial.
            request(ids).put("deny_message", "no"),
        )) {
            val code = try {
                service.bind(broken).toString()
            } catch (refused: AndroidAgentApprovalService.Refused) {
                refused.code
            }
            assertTrue("$broken was not refused: $code", code.startsWith("E_AGENT_"))
        }
    }

    /** The bridge's own wiring holds this service, and holds one of it. */
    @Test
    fun theBridgeOwnsThisService() {
        val app = ApplicationProvider.getApplicationContext<Application>()
        val state = AndroidRuntimeState.get(app)
        assertNotNull(state.approvals)
        assertTrue(state.approvals === AndroidRuntimeState.get(app).approvals)
    }

    private companion object {
        const val DIGEST = "0000000000000000000000000000000000000000000000000000000000000000"
        const val CALL = "call_1"
    }
}
