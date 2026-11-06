package tech.zseven.rish

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.SmallTest
import org.json.JSONObject
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.RishAgentCoreNative

/**
 * Every core decision Android can ask for actually answers.
 *
 * Android bound 29 of the core's 47 entry points, and the missing ones were
 * found one at a time, each by walking into the layer that needed it: a tool
 * batch, a tool execution, a ledger batch, a provider round, a policy. The
 * rest are bound now, and this is what says they are wired rather than merely
 * declared -- a `@JvmStatic external fun` with no matching JNI export compiles
 * and then throws `UnsatisfiedLinkError` the first time anyone calls it.
 *
 * Each call here is deliberately an envelope the rule should **refuse**. A
 * refusal that comes back as a reply is proof the call crossed; what the rule
 * decides is its own module's tests' business, not this one's.
 */
@RunWith(AndroidJUnit4::class)
@SmallTest
class AndroidCoreBindingsTest {

    private fun refusal(name: String, call: () -> String?) {
        val reply = try {
            call()
        } catch (error: UnsatisfiedLinkError) {
            throw AssertionError("$name is declared but not exported by the JNI shim", error)
        }
        // Null or {"ok":false} both mean the call reached the rule and the rule
        // said no. Either is a crossing; only a link error is not.
        if (reply != null) {
            assertTrue(
                "$name replied something that is not JSON: $reply",
                reply.startsWith("{") || reply.startsWith("["),
            )
        }
    }

    private val nothing = JSONObject().put("op", "no_such_decision").toString()

    @Test
    fun everyBoundDecisionCrossesTheBridge() {
        assumeTrue("rish agent core is not staged in this build", RishAgentCoreNative.available)
        refusal("completionResponseReduce") { RishAgentCoreNative.completionResponseReduce(nothing) }
        refusal("containerAnchorReduce") { RishAgentCoreNative.containerAnchorReduce(nothing) }
        refusal("gitToolReduce") { RishAgentCoreNative.gitToolReduce(nothing) }
        refusal("ledgerBatchReduce") { RishAgentCoreNative.ledgerBatchReduce(nothing) }
        refusal("policyReduce") { RishAgentCoreNative.policyReduce(nothing) }
        refusal("projectAccessReduce") { RishAgentCoreNative.projectAccessReduce(nothing) }
        refusal("projectContextBridgeReduce") { RishAgentCoreNative.projectContextBridgeReduce(nothing) }
        refusal("projectContextReduce") { RishAgentCoreNative.projectContextReduce(nothing, null) }
        refusal("projectContextServiceReduce") { RishAgentCoreNative.projectContextServiceReduce(nothing) }
        refusal("projectContextStoreReduce") { RishAgentCoreNative.projectContextStoreReduce(nothing) }
        refusal("projectModuleReduce") { RishAgentCoreNative.projectModuleReduce(nothing) }
        refusal("providerRoundReduce") { RishAgentCoreNative.providerRoundReduce(nothing) }
        refusal("toolBatchReduce") { RishAgentCoreNative.toolBatchReduce(nothing) }
        refusal("toolExecutionReduce") { RishAgentCoreNative.toolExecutionReduce(nothing) }
        refusal("workspaceClearanceReduce") { RishAgentCoreNative.workspaceClearanceReduce(nothing) }
        refusal("workspaceErrorReduce") { RishAgentCoreNative.workspaceErrorReduce(nothing) }
        refusal("workspaceReadToolsReduce") { RishAgentCoreNative.workspaceReadToolsReduce(nothing) }
        refusal("workspaceToolReduce") { RishAgentCoreNative.workspaceToolReduce(nothing) }
    }

    /**
     * The content argument is a separate question from the envelope: a file's
     * bytes reach `content_decision` beside it, and passing null is not the
     * same as passing an empty file. Both spellings have to cross.
     */
    @Test
    fun theProjectContextDecisionCarriesFileBytesBesideItsEnvelope() {
        assumeTrue("rish agent core is not staged in this build", RishAgentCoreNative.available)
        val envelope = JSONObject().put("op", "content_decision").toString()
        refusal("projectContextReduce(null)") {
            RishAgentCoreNative.projectContextReduce(envelope, null)
        }
        refusal("projectContextReduce(empty)") {
            RishAgentCoreNative.projectContextReduce(envelope, ByteArray(0))
        }
        refusal("projectContextReduce(bytes)") {
            RishAgentCoreNative.projectContextReduce(envelope, "hello".toByteArray())
        }
    }

    /** A decision that was already bound still answers; nothing regressed. */
    @Test
    fun theDecisionsBoundBeforeStillAnswer() {
        assumeTrue("rish agent core is not staged in this build", RishAgentCoreNative.available)
        val bounds = RishAgentCoreNative.workspaceTool(JSONObject().put("op", "bounds"))
        assertNotNull(bounds)
        assertTrue(bounds!!.getInt("max_read_bytes") > 0)
        assertNotNull(RishAgentCoreNative.buildId())
    }
}
