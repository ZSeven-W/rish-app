package tech.zseven.rish

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import tech.zseven.rish.runtime.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class AndroidRuntimeStoreTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    @Test fun credentialsAreEncryptedAndIsolatedByAccount() {
        val namespace = "rish.credentials.test." + UUID.randomUUID()
        val store = AndroidCredentialStore(context, namespace)
        val secret = "fixture-secret-not-a-real-key"
        try {
            store.put("DEEPSEEK_API_KEY", secret)
            assertEquals(secret, store.get("DEEPSEEK_API_KEY"))
            val preferences = context.getSharedPreferences(namespace, 0)
            val cipher = preferences.getString("DEEPSEEK_API_KEY", "")!!
            assertFalse(cipher.contains(secret))
            preferences.edit().putString("BIGMODEL_API_KEY", cipher).commit()
            try { store.get("BIGMODEL_API_KEY"); fail("Cross-slot ciphertext was accepted") } catch (_: javax.crypto.AEADBadTagException) { }
            store.clear("DEEPSEEK_API_KEY"); assertFalse(store.configured("DEEPSEEK_API_KEY"))
        } finally {
            context.getSharedPreferences(namespace, 0).edit().clear().commit()
            java.security.KeyStore.getInstance("AndroidKeyStore").apply { load(null); deleteEntry("$namespace.aes") }
        }
    }
    @Test fun providerEndpointChangesDoNotReuseCredentials() {
        val namespace = "rish.providers.test." + UUID.randomUUID()
        val config = AndroidProviderConfiguration(context, namespace)
        try {
            val original = config.effectiveAccount("OPENAI_API_KEY")
            val profile = JSONObject().put("schema_version", 1).put("harness_id", "codex").put("name", "Fixture")
                .put("endpoint_url", "https://example.com/v1").put("protocol", "chat-completions").put("auth_type", "bearer")
                .put("model_mappings", JSONObject().put("gpt-5.6", "test-model")).put("send_reasoning", false)
            config.save(profile); val first = config.effectiveAccount("OPENAI_API_KEY")
            config.save(profile.put("endpoint_url", "https://other.example.com/v1")); val second = config.effectiveAccount("OPENAI_API_KEY")
            assertNotEquals(original, first); assertNotEquals(first, second)
            config.reset("codex"); assertEquals(original, config.effectiveAccount("OPENAI_API_KEY"))
        } finally { context.getSharedPreferences(namespace, 0).edit().clear().commit() }
    }
    @Test fun endpointNormalizationAndStoredProfilesRemainValidated() {
        val namespace = "rish.providers.test." + UUID.randomUUID()
        val config = AndroidProviderConfiguration(context, namespace)
        val preferences = context.getSharedPreferences(namespace, 0)
        try {
            val profile = JSONObject().put("schema_version", 1).put("harness_id", "claude-code").put("name", "Fixture")
                .put("endpoint_url", "https://example.com/api/anthropic").put("protocol", "messages").put("auth_type", "x-api-key")
                .put("model_mappings", JSONObject()).put("send_reasoning", false)
            assertEquals("https://example.com/api/anthropic/v1/messages", config.normalize(profile).getString("endpoint_url"))
            profile.put("endpoint_url", "https://example.com/custom/").put("full_url", true)
            assertEquals("https://example.com/custom/", config.normalize(profile).getString("endpoint_url"))
            config.save(profile)
            assertEquals("https://example.com/custom/", config.read("claude-code").getString("endpoint_url"))
            preferences.edit().putString("claude-code", profile.put("official", true).toString()).commit()
            try { config.read("claude-code"); fail("Forged official configuration accepted") } catch (_: IllegalArgumentException) { }
        } finally { preferences.edit().clear().commit() }
    }
    @Test fun jsonNumericVersionsAcceptIntegersButRejectFractions() {
        val integer = JSONObject().put("schema_version", 1.0)
        RuntimeJson.checkVersion(JSONObject(integer.toString()), 1)
        val fractional = JSONObject().put("schema_version", 1.5)
        try {
            RuntimeJson.checkVersion(JSONObject(fractional.toString()), 1)
            fail("Fractional JSON version accepted")
        } catch (_: IllegalArgumentException) { }
    }
    @Test fun customDshCatalogRoutesNewModelsAndRetainsRetiredIdentity() {
        AndroidDshModelCatalog.initialize(context)
        val prefs = context.getSharedPreferences("rish.dsh-models.v1", 0)
        val previous = prefs.getString("catalog", null)
        try {
            prefs.edit().remove("catalog").commit()
            val initial = AndroidDshModelCatalog.read()
            val models = org.json.JSONArray(initial.getJSONArray("models").toString())
            val model = "catalog-fixture-vNext"
            assertFalse(AndroidDshModelCatalog.isKnown(model))
            models.put(JSONObject().put("id", model).put("name", "Future model").put("supports_images", false))
            AndroidDshModelCatalog.save(JSONObject().put("schema_version", 1).put("models", models))
            assertEquals("dsh", AndroidProviderConfiguration.harness(model))
            AndroidDshModelCatalog.save(JSONObject().put("schema_version", 1).put("models", initial.getJSONArray("models")))
            assertTrue(AndroidDshModelCatalog.isKnown(model))
            assertEquals(1, AndroidDshModelCatalog.read().getJSONArray("retired_models").length())
            val reserved = org.json.JSONArray().put(JSONObject().put("id", "gpt-5.6").put("name", "Wrong provider").put("supports_images", false))
            try { AndroidDshModelCatalog.validateModels(reserved); fail("Reserved model accepted") } catch (_: IllegalArgumentException) { }
        } finally {
            if (previous == null) prefs.edit().remove("catalog").commit()
            else prefs.edit().putString("catalog", previous).commit()
        }
    }
    @Test fun sessionDigestMatchesTheSharedJcsDomainVector() {
        val candidate = JSONObject().put("schema_version", 9).put("z", "https://example.com/你好😀")
            .put("a", org.json.JSONArray().put(true).put(JSONObject.NULL).put(1))
        assertEquals("4604b724aeae709f20da9f323bac4618a16cba34701dadb069e4e68f930f8d97", RishAgentCoreNative.session(JSONObject().put("op", "candidate_digest"), candidate.toString()).getString("digest"))
    }
    /**
     * The smallest session the shared schema accepts. Android used to persist
     * anything that merely said schema_version 9; the core judges the whole
     * root, so a fixture has to be a real session.
     */
    private fun emptySession(activeConversationId: Any = JSONObject.NULL): JSONObject =
        JSONObject().put("schema_version", 9)
            .put("workspace_authority_outbox", org.json.JSONArray())
            .put("agent_transcript_cleanup_outbox", org.json.JSONArray())
            .put("project_context_destructive_epoch", 0)
            .put("project_context_destructive_transition", JSONObject.NULL)
            .put("active_conversation_id", activeConversationId)
            .put("conversations", org.json.JSONArray())
            .put("messages", org.json.JSONArray())
            .put("session_events", org.json.JSONArray())
            .put("preferences", JSONObject().put("schema_version", 1)
                .put("theme_mode", "system").put("locale", "system")
                .put("default_model", "deepseek-v4-flash").put("thinking_mode", "off")
                .put("tool_permission", "read-only").put("show_reasoning", false)
                .put("auto_expand_tools", false).put("confirm_destructive_file_actions", true))

    @Test fun snapshotCASIsAtomicIdempotentAndDetectsConflicts() {
        val name = "session-test-${UUID.randomUUID()}.db"
        val store = AndroidSessionStore(context, name)
        try {
            val operation = UUID.randomUUID().toString()
            val request = JSONObject().put("schema_version", 1).put("operation_id", operation)
                .put("expected", JSONObject().put("schema_version", 1).put("kind", "missing"))
                .put("candidate_json", emptySession().toString())
            val first = store.persist(request)
            assertEquals("committed", first.getString("status")); assertEquals(1, first.getJSONObject("snapshot").getInt("generation"))
            assertEquals(first.toString(), store.persist(request).toString())
            assertEquals(RuntimeJson.canonical(emptySession()), store.load().getString("session_json"))
            // The operation is identified by the candidate it committed, not by
            // the request's spelling: the same session in different bytes is
            // the same commit replayed.
            assertEquals(first.toString(), store.persist(JSONObject(request.toString())
                .put("candidate_json", " " + emptySession().toString() + " ")).toString())
            val competing = JSONObject(request.toString()).put("operation_id", UUID.randomUUID().toString())
            val conflict = store.persist(competing)
            assertEquals("conflict", conflict.getString("status"))
            assertEquals("present", conflict.getJSONObject("current").getString("kind"))
            // A conflict is not written down. The same operation may be retried
            // once its author has re-read the authority, and then it commits.
            val retried = store.persist(JSONObject(competing.toString())
                .put("expected", JSONObject().put("schema_version", 1).put("kind", "present")
                    .put("snapshot", first.getJSONObject("snapshot"))))
            assertEquals("committed", retried.getString("status"))
            assertEquals(2, retried.getJSONObject("snapshot").getInt("generation"))
            // A different candidate under an operation that already committed
            // conflicts; it never overwrites what that operation settled.
            val reused = store.persist(JSONObject(request.toString())
                .put("candidate_json", emptySession(JSONObject.NULL).put("project_context_destructive_epoch", 1).toString()))
            assertEquals("conflict", reused.getString("status"))
            assertEquals("committed", store.query(JSONObject().put("schema_version", 1).put("operation_id", operation)).getString("status"))
            assertEquals("not_started", store.query(JSONObject().put("schema_version", 1)
                .put("operation_id", UUID.randomUUID().toString())).getString("status"))
            assertEquals(2, store.load().getJSONObject("snapshot").getInt("generation"))
        } finally { store.close(); context.deleteDatabase(name) }
    }
    @Test fun unsupportedAuthorityNeverGetsCommitted() {
        val name = "session-authority-test-${UUID.randomUUID()}.db"
        val store = AndroidSessionStore(context, name)
        try {
            val request = JSONObject().put("schema_version", 1).put("operation_id", UUID.randomUUID().toString())
                .put("expected", JSONObject().put("schema_version", 1).put("kind", "missing"))
                .put("candidate_json", emptySession().put("project_context_destructive_transition", JSONObject()).toString())
            // Two layers refuse native authority and the test cares that
            // neither commits: the shared rules reject a journal they do not
            // recognise, and Android's own policy rejects the ones they do,
            // because this platform issues no project, workspace, tool or
            // Agent authority yet.
            for (carrier in listOf(request,
                JSONObject(request.toString()).put("operation_id", UUID.randomUUID().toString())
                    .put("candidate_json", emptySession().put("workspace_authority_outbox",
                        org.json.JSONArray().put(JSONObject().put("schema_version", 1))).toString()),
                JSONObject(request.toString()).put("operation_id", UUID.randomUUID().toString())
                    .put("candidate_json", emptySession().put("agent_transcript_cleanup_outbox",
                        org.json.JSONArray().put(JSONObject().put("schema_version", 1))).toString()))) {
                try { store.persist(carrier); fail("Unsupported authority committed") } catch (_: RuntimeException) { }
                assertEquals("missing", store.load().getString("status"))
            }
        } finally { store.close(); context.deleteDatabase(name) }
    }
    @Test fun cancellationBeforeWorkerBindingNeverReachesNetwork() {
        val namespace = "runtime-cancel-test-${UUID.randomUUID()}"
        val credentials = AndroidCredentialStore(context, namespace)
        val config = AndroidProviderConfiguration(context, "$namespace.providers")
        val transport = AndroidModelTransport(credentials, config)
        val request = JSONObject().put("schema_version", 1).put("request_id", UUID.randomUUID().toString())
            .put("model", "deepseek-v4-flash").put("thinking_mode", "off").put("history", org.json.JSONArray().put(JSONObject().put("role", "user").put("content", "fixture")))
            .put("tools", org.json.JSONArray())
        val prepared = transport.prepare(request.toString())
        try { transport.whenIdle { fail("Catalog changed during a prepared request") } } catch (error: RuntimeFailure) { assertEquals("E_COMPLETION_BUSY", error.code) }
        transport.cancel(prepared.id)
        try { transport.execute(prepared); fail("Cancelled request executed") } catch(error: RuntimeFailure) { assertEquals("E_COMPLETION_CANCELLED", error.code) }
    }
}
