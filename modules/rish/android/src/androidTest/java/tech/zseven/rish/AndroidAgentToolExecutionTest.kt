package tech.zseven.rish

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.MediumTest
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.AndroidAgentToolExecutionService
import tech.zseven.rish.runtime.RishAgentCoreNative

/**
 * `execute_agent_tool` on a device, end to end through the real core.
 *
 * The service owns no rules: the request shape, the committed-session
 * relation, every pre-execution check, the ledger CAS, the arguments, the
 * settlement and the reply all come back from `tool_execution`. What these
 * cover is that the host half is wired -- the WAL views are collected under
 * the names the core reads, the ledger calls happen in the order the core
 * expects, and a refusal carries the code JavaScript branches on.
 *
 * **What they do not cover.** No ledger row exists here, because nothing on
 * Android creates one yet: `prepare_agent_tool_batch` is still a skeleton. So
 * every path below ends in a refusal, and the refusal is the evidence: it is
 * the core's, it names the reason, and it is reached by collecting a real
 * snapshot of a real WAL rather than by failing before any of that. A test
 * that asserted a tool ran would be asserting a fixture, not this code.
 */
@RunWith(AndroidJUnit4::class)
@MediumTest
class AndroidAgentToolExecutionTest {

    private fun service(): AndroidAgentToolExecutionService {
        assumeTrue("rish agent core is not staged in this build", RishAgentCoreNative.available)
        val app = ApplicationProvider.getApplicationContext<Application>()
        return tech.zseven.rish.runtime.AndroidRuntimeState.get(app).toolExecution
    }

    private fun request(name: String = "read_file"): JSONObject = JSONObject()
        .put("schema_version", 2)
        .put("operation_id", "11111111-1111-4111-8111-111111111111")
        .put("task_id", "22222222-2222-4222-8222-222222222222")
        .put("conversation_id", "33333333-3333-4333-8333-333333333333")
        .put("attempt_id", "44444444-4444-4444-8444-444444444444")
        .put("round_id", "55555555-5555-4555-8555-555555555555")
        .put("round_index", 0)
        .put("call_index", 0)
        .put("call_id", "call_1")
        .put("name", name)
        .put("batch_kind", "read_only_batch")
        .put("manifest_sha256", JSONObject.NULL)
        .put("expected_batch_revision", 1)
        .put("arguments_sha256", "0".repeat(64))
        .put(
            "root",
            JSONObject().put("schema_version", 1)
                .put("kind", "workspace")
                .put("workspace_id", "66666666-6666-4666-8666-666666666666")
                .put("workspace_binding_revision", 1).put("project_id", JSONObject.NULL)
                .put("root_fingerprint_sha256", "0000000000000000000000000000000000000000000000000000000000000000")
                .put("capabilities", org.json.JSONArray().put("file_read").put("file_write")),
        )

    /**
     * A request with no ledger row behind it is refused, and the refusal is a
     * code the controller knows. Reaching it means the shape passed, the WAL
     * was read and the core's precheck ran.
     */
    @Test
    fun aCallWithNoLedgerRowIsRefusedWithAStableCode() {
        val service = service()
        val outcome = try {
            service.execute(request()).toString()
        } catch (refused: AndroidAgentToolExecutionService.Refused) {
            refused.code
        }
        assertTrue(
            "expected a stable agent code or a conflict result, got: $outcome",
            outcome.startsWith("E_AGENT_") || outcome.contains("failure_code"),
        )
    }

    /**
     * A malformed request never reaches a view of the WAL. The core refuses the
     * shape first, and the code says so rather than reporting a conflict that
     * would suggest something about the ledger.
     */
    @Test
    fun aMalformedRequestIsRefusedOnItsShape() {
        val service = service()
        for (broken in listOf(
            JSONObject(),
            JSONObject().put("schema_version", 2),
            request().put("schema_version", 1),
            request().put("call_index", -1),
            request().put("name", ""),
        )) {
            val code = try {
                service.execute(broken)
                "no refusal"
            } catch (refused: AndroidAgentToolExecutionService.Refused) {
                refused.code
            }
            assertTrue("$broken was not refused: $code", code.startsWith("E_AGENT_"))
        }
    }

    /**
     * The service is reachable from the bridge's own wiring, not only from a
     * test that built it by hand. If AndroidRuntimeState stopped constructing
     * it, everything above would still pass and nothing would run in the app.
     */
    @Test
    fun theBridgeOwnsThisServiceOnTheRealRuntimeState() {
        val app = ApplicationProvider.getApplicationContext<Application>()
        val state = tech.zseven.rish.runtime.AndroidRuntimeState.get(app)
        assertNotNull(state.toolExecution)
        assertNotNull(state.executionLedger)
        assertNotNull(state.workspaceTools)
        // The same instance every time: a second ledger over one WAL would let
        // two owners believe they hold the same row.
        assertEquals(state.toolExecution, tech.zseven.rish.runtime.AndroidRuntimeState.get(app).toolExecution)
    }
}
