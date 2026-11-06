package tech.zseven.rish

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.*
import java.util.UUID

/**
 * The facts Android hands the shared core when it judges a session: the
 * host each model's harness reaches, and the provider bindings the candidate
 * carries. A prepared project context records the host its snapshot was
 * prepared for, and the core refuses a manifest whose host it cannot vouch
 * for -- which, with an empty catalogue, was every manifest on Android.
 */
@RunWith(AndroidJUnit4::class)
class AndroidSessionEnvironmentTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext

    private fun customBinding(model: String): JSONObject {
        val configurations = AndroidProviderConfiguration(context, "rish.providers.env-test")
        val config = configurations.normalize(JSONObject().put("schema_version", 1).put("harness_id", "codex")
            .put("name", "Relay").put("endpoint_url", "https://relay.example.com/v1")
            .put("protocol", "responses").put("auth_type", "bearer").put("send_reasoning", true)
            .put("model_mappings", JSONObject()))
        return configurations.binding(config, model)!!
    }

    @Test fun factsCarryOfficialHostsAndJudgedBindings() {
        val binding = customBinding("gpt-5.6")
        val tampered = JSONObject(binding.toString()).put("model_id", "other")
        val value = JSONObject().put("a", "deepseek-v4-flash").put("b", JSONArray().put("GLM-5.3").put("claude-sonnet-5"))
            .put("record", JSONObject().put("model", "gpt-5.6").put("provider_configuration", binding))
            .put("broken", JSONObject().put("model", "gpt-5.6").put("provider_configuration", tampered))
            .put("wrong_model", JSONObject().put("model", "deepseek-v4-flash").put("provider_configuration", binding))
        val facts = AndroidSessionEnvironment.facts(value)
        val hosts = facts.getJSONObject("host_by_model")
        assertEquals("api.deepseek.com", hosts.getString("deepseek-v4-flash"))
        assertEquals("open.bigmodel.cn", hosts.getString("GLM-5.3"))
        assertEquals("api.anthropic.com", hosts.getString("claude-sonnet-5"))
        assertEquals("api.openai.com", hosts.getString("gpt-5.6"))
        assertEquals("api.openai.com", AndroidSessionEnvironment.hostFor("gpt-5.6"))
        assertNull(AndroidSessionEnvironment.hostFor("no-such-model"))
        // Provider ids are the provider's, not the harness's: a verified
        // attempt says `deepseek`, and `dsh` is not an answer.
        val providers = (0 until facts.getJSONArray("provider_ids").length()).map { facts.getJSONArray("provider_ids").getString(it) }
        assertEquals(emptyList<String>(), providers)
        val named = AndroidSessionEnvironment.facts(JSONObject().put("p", JSONArray().put("deepseek").put("dsh").put("openai").put("codex")))
        val namedProviders = (0 until named.getJSONArray("provider_ids").length()).map { named.getJSONArray("provider_ids").getString(it) }
        assertEquals(listOf("deepseek", "openai"), namedProviders)
        assertEquals("deepseek", AndroidSessionEnvironment.providerFor("deepseek-v4-flash"))

        val bindings = facts.getJSONArray("provider_bindings")
        assertEquals(3, bindings.length())
        val byKey = (0 until bindings.length()).map { bindings.getJSONObject(it) }.associateBy { it.getString("canonical_sha256") }
        fun key(binding: JSONObject, model: String) =
            RuntimeJson.sha(RuntimeJson.canonical(JSONObject().put("binding", binding).put("model", model)))
        val good = byKey.getValue(key(binding, "gpt-5.6"))
        assertTrue(good.getBoolean("valid")); assertEquals("relay.example.com", good.getString("host"))
        // The profile digest no longer covers the record, so it is not a
        // binding this build issued.
        val bad = byKey.getValue(key(tampered, "gpt-5.6"))
        assertFalse(bad.getBoolean("valid")); assertTrue(bad.isNull("host"))
        // A codex binding is not a binding for a DeepSeek model.
        val mismatched = byKey.getValue(key(binding, "deepseek-v4-flash"))
        assertFalse(mismatched.getBoolean("valid"))
    }

    @Test fun bindingValidityFollowsTheIosRule() {
        val binding = customBinding("gpt-5.6")
        assertTrue(AndroidProviderConfiguration.validBinding(binding, "gpt-5.6"))
        assertFalse(AndroidProviderConfiguration.validBinding(binding, null))
        assertFalse(AndroidProviderConfiguration.validBinding(JSONObject(binding.toString()).put("extra", 1), "gpt-5.6"))
        assertFalse(AndroidProviderConfiguration.validBinding(JSONObject(binding.toString()).put("endpoint_url", "HTTPS://relay.example.com/v1/responses"), "gpt-5.6"))
        assertFalse(AndroidProviderConfiguration.validBinding(JSONObject(binding.toString()).put("model_id", "has space"), "gpt-5.6"))
        assertFalse(AndroidProviderConfiguration.validBinding("not an object", "gpt-5.6"))
    }

    private fun manifest(projectId: String, snapshotId: String, host: String, model: String, binding: JSONObject? = null): JSONObject {
        val manifest = JSONObject().put("schema_version", 1).put("snapshot_id", snapshotId).put("project_id", projectId)
            .put("project_name", "smoke").put("branch", "main").put("head_oid", "0000000000000000000000000000000000000000")
            .put("clean", true).put("conflicted", false).put("captured_at", "2026-09-20T05:32:12.533Z")
            .put("policy_version", "chat-read-v1.0.0").put("provider_host", host).put("model", model)
            .put("included", JSONArray().put(JSONObject().put("path", "README.md").put("source", "tracked_file").put("bytes", 1)
                .put("sha256", "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc")))
            .put("omitted", JSONArray()).put("context_bytes", 1).put("estimated_tokens", 1)
            .put("snapshot_sha256", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
            .put("source_fingerprint", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        binding?.let { manifest.put("provider_configuration", it) }
        return manifest
    }

    /** A session whose conversation holds a prepared, confirmed context, the way JavaScript writes one after `confirmSnapshotV2`. */
    private fun sessionWithContext(model: String, host: String, binding: JSONObject? = null): JSONObject {
        val projectId = UUID.randomUUID().toString()
        val snapshotId = UUID.randomUUID().toString()
        val ids = AgentSessionFixture.Ids()
        val attemptContext = JSONObject().put("schema_version", 1).put("runtime_context_id", UUID.randomUUID().toString())
            .put("project_id", projectId).put("snapshot_id", snapshotId)
            .put("snapshot_sha256", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
            .put("source_fingerprint", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
            .put("context_bytes", 1).put("consent_receipt_id", UUID.randomUUID().toString())
            .put("provider", "deepseek").put("policy", "chat-read-v1").put("policy_version", "chat-read-v1.0.0")
        val session = AgentSessionFixture.session(ids, workspace = UUID.randomUUID().toString(), model = model, attemptContext = attemptContext)
        val conversation = session.getJSONArray("conversations").getJSONObject(0)
        conversation.put("project_context", JSONObject().put("schema_version", 1).put("project_id", projectId)
            .put("status", "ready").put("selected_paths", JSONArray()).put("active_preparation_id", JSONObject.NULL)
            .put("manifest", manifest(projectId, snapshotId, host, model, binding))
            .put("consent", JSONObject().put("schema_version", 1).put("consent_receipt_id", attemptContext.getString("consent_receipt_id"))
                .put("snapshot_id", snapshotId).put("snapshot_sha256", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
                .put("confirmed_at", "2026-09-20T05:32:13.000Z"))
            .put("stale_reason", JSONObject.NULL).put("error_code", JSONObject.NULL))
        return session
    }

    private fun persist(store: AndroidSessionStore, session: JSONObject): JSONObject =
        store.persist(JSONObject().put("schema_version", 1).put("operation_id", UUID.randomUUID().toString())
            .put("expected", JSONObject().put("schema_version", 1).put("kind", "missing"))
            .put("candidate_json", session.toString()))

    @Test fun preparedContextManifestsCommitWhenTheirHostIsTheCatalogueHost() {
        val name = "session-env-${UUID.randomUUID()}.db"
        val store = AndroidSessionStore(context, name)
        try {
            assertEquals("committed", persist(store, sessionWithContext("deepseek-v4-flash", "api.deepseek.com")).getString("status"))
        } finally { store.close(); context.deleteDatabase(name) }
    }

    @Test fun preparedContextManifestsForAnotherHostAreRefused() {
        val name = "session-env-${UUID.randomUUID()}.db"
        val store = AndroidSessionStore(context, name)
        try {
            try {
                persist(store, sessionWithContext("deepseek-v4-flash", "example.invalid"))
                fail("a manifest for a host this build never reaches was committed")
            } catch (_: RuntimeException) { }
        } finally { store.close(); context.deleteDatabase(name) }
    }

    @Test fun preparedContextManifestsWithAValidBindingCommitUnderTheBindingHost() {
        val name = "session-env-${UUID.randomUUID()}.db"
        val store = AndroidSessionStore(context, name)
        try {
            val binding = customBinding("gpt-5.6")
            assertEquals("committed", persist(store, sessionWithContext("gpt-5.6", "relay.example.com", binding)).getString("status"))
            try {
                persist(store, sessionWithContext("gpt-5.6", "api.openai.com", binding))
                fail("a bound manifest naming the official host was committed")
            } catch (_: RuntimeException) { }
        } finally { store.close(); context.deleteDatabase(name) }
    }
}
