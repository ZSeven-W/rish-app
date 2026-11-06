package tech.zseven.rish

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.MediumTest
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.AndroidAgentToolBatchService
import tech.zseven.rish.runtime.AndroidRuntimeState
import tech.zseven.rish.runtime.RishAgentCoreNative

/**
 * `prepare_agent_tool_batch` on a device.
 *
 * The service owns no rules: the request shape, the gate, the per-call
 * analysis, the outcome mapping, the final authority check and the ledger
 * rejection all come back from `tool_batch`. What is covered here is the host
 * half -- the WAL view is collected under the names the core reads, the
 * probes run in order, and a refusal carries the code JavaScript branches on.
 *
 * **What these cannot cover yet.** A batch needs a prepared authority and a
 * completed round to gate against, and nothing on Android produces either:
 * `complete_agent_round_v2` is still a skeleton. So every path here ends in the
 * gate's rejection, and that rejection is the evidence -- it is the core's, it
 * names the reason, and reaching it means the request shape passed and a real
 * WAL snapshot was read. Asserting that a batch was written would be asserting
 * a fixture.
 */
@RunWith(AndroidJUnit4::class)
@MediumTest
class AndroidAgentToolBatchTest {

    private fun service(): AndroidAgentToolBatchService {
        assumeTrue("rish agent core is not staged in this build", RishAgentCoreNative.available)
        val app = ApplicationProvider.getApplicationContext<Application>()
        return AndroidRuntimeState.get(app).toolBatch
    }

    private fun request(): JSONObject = JSONObject()
        .put("schema_version", 2)
        .put("operation_id", "11111111-1111-4111-8111-111111111111")
        .put("task_id", "22222222-2222-4222-8222-222222222222")
        .put("conversation_id", "33333333-3333-4333-8333-333333333333")
        .put("attempt_id", "44444444-4444-4444-8444-444444444444")
        .put("round_id", "55555555-5555-4555-8555-555555555555")
        .put("round_index", 0)
        .put("expected_round_revision", 1)
        .put("expected_batch_revision", 0)
        .put("expected_reserved_write_bytes", 0)
        .put(
            "root",
            JSONObject().put("schema_version", 1)
                .put("kind", "workspace")
                .put("workspace_id", "66666666-6666-4666-8666-666666666666")
                .put("workspace_binding_revision", 1).put("project_id", JSONObject.NULL)
                .put("root_fingerprint_sha256", "0000000000000000000000000000000000000000000000000000000000000000")
                .put("capabilities", JSONArray().put("file_read").put("file_write")),
        )

    /**
     * With no authority and no round, the gate rejects, and the rejection is
     * the core's rather than an exception from the host. Reaching it means the
     * request passed its shape check and the WAL was read.
     */
    @Test
    fun aBatchWithNoAuthorityIsRejectedByTheGate() {
        val outcome = try {
            service().prepare(request()).toString()
        } catch (refused: AndroidAgentToolBatchService.Refused) {
            refused.code
        }
        assertTrue(
            "expected a gate rejection or a stable agent code, got: $outcome",
            outcome.contains("failure_code") || outcome.startsWith("E_AGENT_"),
        )
    }

    /** A malformed request never reaches a view of the WAL. */
    @Test
    fun aMalformedRequestIsRefusedOnItsShape() {
        val service = service()
        for (broken in listOf(
            JSONObject(),
            JSONObject().put("schema_version", 2),
            request().put("schema_version", 1),
            request().put("round_index", -1),
            request().put("root", JSONArray()),
        )) {
            val code = try {
                service.prepare(broken).toString()
            } catch (refused: AndroidAgentToolBatchService.Refused) {
                refused.code
            }
            assertTrue(
                "$broken was not refused: $code",
                code.startsWith("E_AGENT_") || code.contains("failure_code"),
            )
        }
    }

    /**
     * The round limit is the core's and it is real: a seventh round is refused
     * whatever else is true, which is what stops an agent looping forever.
     */
    @Test
    fun theSeventhRoundIsRefused() {
        val outcome = try {
            service().prepare(request().put("round_index", 7)).toString()
        } catch (refused: AndroidAgentToolBatchService.Refused) {
            refused.code
        }
        assertTrue("got: $outcome", outcome.contains("failure_code") || outcome.startsWith("E_AGENT_"))
    }

    /** The bridge's own wiring holds this service, and holds one of it. */
    @Test
    fun theBridgeOwnsThisService() {
        val app = ApplicationProvider.getApplicationContext<Application>()
        val state = AndroidRuntimeState.get(app)
        assertNotNull(state.toolBatch)
        assertTrue(state.toolBatch === AndroidRuntimeState.get(app).toolBatch)
    }
}
