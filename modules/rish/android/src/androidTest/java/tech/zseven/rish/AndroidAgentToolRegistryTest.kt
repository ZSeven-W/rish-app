package tech.zseven.rish

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.AndroidAgentToolRegistry
import java.util.UUID

/**
 * Android reads the tool table from the shared core rather than keeping one.
 * These cases pin the facts a second copy would eventually get wrong.
 */
@RunWith(AndroidJUnit4::class)
class AndroidAgentToolRegistryTest {
    private fun workspaceRoot(capabilities: JSONArray): JSONObject = JSONObject()
        .put("schema_version", 1).put("kind", "workspace")
        .put("workspace_id", UUID.randomUUID().toString()).put("project_id", JSONObject.NULL)
        .put("root_fingerprint_sha256", "c".repeat(64))
        .put("workspace_binding_revision", 1).put("capabilities", capabilities)

    @Test fun theFrozenVersionTwoToolsetDigestRemainsUnchanged() {
        // Android ships no guest CGI tools, so its toolset — and therefore
        // every authority it writes — is bound to the digest without them.
        assertEquals("62e426ffac0cc058b8affcbc8744549eeb91bc9a99923bb1982ec42c47e8a60c",
            AndroidAgentToolRegistry.toolsetSha256(2))
    }

    @Test fun aRootOnlyEverOffersTheToolsItsCapabilitiesAllow() {
        val registry = AndroidAgentToolRegistry.registryForRoot(
            workspaceRoot(JSONArray().put("file_read")))
        val tools = registry.getJSONArray("tools")
        assertEquals(3, tools.length())
        assertEquals(listOf("ask_user", "list_dir", "read_file"),
            (0 until tools.length()).map { tools.getJSONObject(it).getString("name") })
        assertEquals(4, registry.getInt("registry_version"))
        assertEquals(AndroidAgentToolRegistry.toolsetSha256(),
            registry.getString("toolset_sha256"))
        assertTrue(AndroidAgentToolRegistry.validateRegistry(registry,
            workspaceRoot(JSONArray().put("file_read"))))
    }

    @Test fun aToolTheRootDoesNotOfferIsADurableDenialNotAnError() {
        val root = workspaceRoot(JSONArray().put("file_read"))
        val denied = AndroidAgentToolRegistry.descriptorForTool("write_file", root)
        assertEquals("durable_deny", denied.getString("access"))
        assertEquals("agent.unknown", denied.getString("safe_summary_key"))
        // An unknown name is denied under a name that cannot carry a payload.
        assertEquals("unknown",
            AndroidAgentToolRegistry.descriptorForTool("../../etc/passwd", root).getString("name"))
    }

    @Test fun aRegistryWhoseAccessDisagreesWithItsRootIsRefused() {
        val root = workspaceRoot(JSONArray().put("file_read"))
        val registry = AndroidAgentToolRegistry.registryForRoot(root)
        registry.getJSONArray("tools").getJSONObject(0).put("access", "conversation_confirm")
        assertFalse(AndroidAgentToolRegistry.validateRegistry(registry, root))
    }

    @Test fun thePolicyIsTheSameBoundsTheWalEnforces() {
        val policy = AndroidAgentToolRegistry.policyForRoot(
            workspaceRoot(JSONArray().put("file_read")))
        assertEquals("agent-v1", policy.getString("policy_version"))
        assertEquals(32768, policy.getInt("max_single_write_bytes"))
        assertEquals(524288, policy.getInt("max_batch_write_bytes"))
        assertEquals(4194304, policy.getInt("max_attempt_write_bytes"))
    }
}
