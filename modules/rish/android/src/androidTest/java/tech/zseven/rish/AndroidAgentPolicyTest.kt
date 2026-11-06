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
import tech.zseven.rish.runtime.AndroidAgentPolicyService
import tech.zseven.rish.runtime.AndroidAgentRootResolver
import tech.zseven.rish.runtime.AndroidAgentToolRegistry
import tech.zseven.rish.runtime.AndroidWorkspaceRegistry
import tech.zseven.rish.runtime.RishAgentCoreNative
import java.io.File
import java.util.UUID

/**
 * What the permissions sheet is allowed to say.
 *
 * The sheet read "this app version cannot check workspace permissions" and
 * showed every tool as unverified, on a build where list_dir and read_file run
 * without asking and write_file asks. These hold the answer to what the agent
 * may do against what it actually does.
 */
@RunWith(AndroidJUnit4::class)
@MediumTest
class AndroidAgentPolicyTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    private class Fixture(
        val service: AndroidAgentPolicyService,
        val workspaceId: String,
    )

    private fun fixture(body: (Fixture) -> Unit) {
        assumeTrue("rish agent core is not staged in this build", RishAgentCoreNative.available)
        val name = "policy-${UUID.randomUUID()}"
        val home = File(context.cacheDir, name)
        val workspaces = AndroidWorkspaceRegistry(home)
        val created = workspaces.create("demo")
        val roots = AndroidAgentRootResolver(workspaces)
        try {
            body(
                Fixture(
                    AndroidAgentPolicyService(roots, AndroidAgentToolRegistry),
                    created.getString("workspace_id"),
                ),
            )
        } finally {
            home.deleteRecursively()
        }
    }

    private fun request(f: Fixture, revision: Int = 1): JSONObject = JSONObject()
        .put("schema_version", 1)
        .put("workspace_id", f.workspaceId)
        .put("workspace_binding_revision", revision)
        .put("project_id", JSONObject.NULL)

    /**
     * The three workspace tools, as they actually behave: a listing and a read
     * run without asking, and a write asks. A sheet that said otherwise would
     * be describing a different build.
     */
    @Test
    fun theSheetDescribesWhatTheToolsActuallyDo() = fixture { f ->
        val policy = f.service.describe(request(f))
        assertEquals(f.workspaceId, policy.getString("workspace_id"))
        assertEquals("agent-v1", policy.getString("policy_version"))
        val access = policy.getJSONArray("tools").let { tools ->
            (0 until tools.length()).associate { index ->
                val tool = tools.getJSONObject(index)
                tool.getString("name") to tool.getString("access")
            }
        }
        assertEquals("$access", "auto", access["list_dir"])
        assertEquals("$access", "auto", access["read_file"])
        assertEquals("$access", "conversation_confirm", access["write_file"])
        val capabilities = policy.getJSONArray("capabilities").let { list ->
            (0 until list.length()).map { list.getString(it) }
        }
        assertTrue("$capabilities", capabilities.containsAll(listOf("file_read", "file_write")))
        // The budget the sheet shows is the one the ledger enforces.
        assertEquals(
            32768,
            policy.getJSONObject("budget").getInt("max_single_write_bytes"),
        )
    }

    /**
     * A binding revision this device does not hold is *stale*, not invalid:
     * the question was well formed and the answer has moved on.
     */
    @Test
    fun aBindingThisDeviceDoesNotHoldIsStale() = fixture { f ->
        val code = try {
            "described: " + f.service.describe(request(f, revision = 7))
        } catch (refused: AndroidAgentPolicyService.Refused) {
            refused.code
        }
        assertEquals("E_AGENT_ROOT_STALE", code)
    }

    /** A malformed request is refused before any registry is read. */
    @Test
    fun aMalformedPolicyRequestIsRefused() = fixture { f ->
        val code = try {
            "described: " + f.service.describe(
                JSONObject(request(f).toString()).also { it.remove("project_id") },
            )
        } catch (refused: AndroidAgentPolicyService.Refused) {
            refused.code
        }
        assertEquals("E_AGENT_BAD_ARGUMENTS", code)
    }

}
