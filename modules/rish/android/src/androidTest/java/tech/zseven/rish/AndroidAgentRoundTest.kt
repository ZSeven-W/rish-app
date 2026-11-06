package tech.zseven.rish

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.MediumTest
import org.json.JSONObject
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.AndroidAgentProviderRoundService
import tech.zseven.rish.runtime.AndroidRuntimeState
import tech.zseven.rish.runtime.RishAgentCoreNative

/**
 * `complete_agent_round_v2` on a device.
 *
 * The round is the step that asks the model what to do next. Its rules are the
 * core's; what is covered here is the host half -- the request reaches
 * `provider_round`, the root is proved, and a refusal carries the code
 * JavaScript branches on rather than an exception from Kotlin.
 *
 * **These cannot show a round completing.** A round needs a prepared authority
 * and a committed conversation, and no test here makes either without the rest
 * of the attempt machinery. More importantly, even a complete round would show
 * the model no tools: AndroidModelTransport refuses any request carrying them.
 * The service says so in its own documentation rather than dropping them, and
 * this file says so too, because a passing test named for a working round
 * would be the most misleading thing in the tree.
 */
@RunWith(AndroidJUnit4::class)
@MediumTest
class AndroidAgentRoundTest {

    private fun service(): AndroidAgentProviderRoundService {
        assumeTrue("rish agent core is not staged in this build", RishAgentCoreNative.available)
        val app = ApplicationProvider.getApplicationContext<Application>()
        return AndroidRuntimeState.get(app).providerRound
    }

    private fun request(): JSONObject = JSONObject()
        .put("schema_version", 2)
        .put("operation_id", "11111111-1111-4111-8111-111111111111")
        .put("task_id", "22222222-2222-4222-8222-222222222222")
        .put("conversation_id", "33333333-3333-4333-8333-333333333333")
        .put("attempt_id", "44444444-4444-4444-8444-444444444444")
        .put("round_id", "55555555-5555-4555-8555-555555555555")
        .put("turn_id", "77777777-7777-4777-8777-777777777777")
        .put("round_index", 0)
        .put("harness_id", "dsh")
        .put("model", "deepseek-v4-flash")
        .put("thinking_mode", "off")
        .put(
            "root",
            JSONObject().put("schema_version", 1)
                .put("workspace_id", "66666666-6666-4666-8666-666666666666")
                .put("binding_revision", 1).put("project_id", JSONObject.NULL),
        )

    @Test
    fun aRoundWithNoAuthorityIsRefusedWithAStableCode() {
        val outcome = try {
            service().completeRound(request()).toString()
        } catch (refused: AndroidAgentProviderRoundService.Refused) {
            refused.code
        }
        assertTrue(
            "expected a stable agent code, got: $outcome",
            outcome.startsWith("E_AGENT_") || outcome.contains("failure_code"),
        )
    }

    @Test
    fun aMalformedRoundIsRefusedOnItsShape() {
        val service = service()
        for (broken in listOf(
            JSONObject(),
            request().put("schema_version", 1),
            request().put("round_index", 99),
            request().put("round_id", "not-a-uuid"),
        )) {
            val code = try {
                service.completeRound(broken).toString()
            } catch (refused: AndroidAgentProviderRoundService.Refused) {
                refused.code
            }
            assertTrue("$broken was not refused: $code", code.startsWith("E_AGENT_"))
        }
    }

    @Test
    fun theBridgeOwnsThisService() {
        val app = ApplicationProvider.getApplicationContext<Application>()
        val state = AndroidRuntimeState.get(app)
        assertNotNull(state.providerRound)
        assertTrue(state.providerRound === AndroidRuntimeState.get(app).providerRound)
    }
}
