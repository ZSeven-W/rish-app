package tech.zseven.rish

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.*
import java.io.File
import java.util.UUID

/** Actual JNI policy and atomic preferences; no provider credentials or network. */
@RunWith(AndroidJUnit4::class)
class AndroidProviderModelCatalogTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private fun uuid() = UUID.randomUUID().toString()
    private inner class Fixture(legacy: () -> Any = { JSONObject.NULL }) : AutoCloseable {
        val previous = AndroidProviderConfiguration.registry
        val name = "provider-models-${uuid()}"
        val configurations = AndroidProviderConfiguration(context, name, legacy)
        val catalog = configurations.providerModels
        val keys = AndroidCredentialStore(context, "$name.keys")
        val transport = AndroidModelTransport(keys, configurations)
        val service = AndroidProviderModels(configurations, transport, keys) {}
        fun save(harness: String, vararg ids: String): JSONObject = service.save(JSONObject()
            .put("schema_version", 1).put("expected_revision", catalog.read().getLong("revision"))
            .put("harness_id", harness).put("models", rows(*ids)))
        override fun close() {
            for (suffix in listOf("", ".models", ".custom", ".keys")) context.getSharedPreferences(name + suffix, 0).edit().clear().commit()
            java.security.KeyStore.getInstance("AndroidKeyStore").apply { load(null); deleteEntry("$name.keys.aes") }
            AndroidProviderConfiguration.registry = previous
        }
    }
    private fun rows(vararg ids: String) = JSONArray().apply {
        ids.forEach { put(JSONObject().put("id", it).put("name", "Model $it").put("supports_images", false)) }
    }

    @Test fun freshProviderChoicesAreEmptyWhileOldIdentityRemainsReadable() = Fixture().use { f ->
        val registry = f.service.list()
        assertEquals(0L, registry.getLong("revision"))
        assertEquals(4, registry.getJSONArray("providers").length())
        assertEquals(0, f.catalog.models().length())
        assertEquals("dsh", AndroidProviderConfiguration.harnessForHistory("deepseek-v4-flash"))
        assertEquals("codex", AndroidProviderConfiguration.harnessForHistory("gpt-5.6"))
        assertFalse(AndroidProviderConfiguration.isActiveModel("deepseek-v4-flash"))
        assertTrue(context.getSharedPreferences("${f.name}.models", 0).all.isEmpty())
    }

    @Test fun unconfiguredDefaultAndEmptyConversationRoundTripThroughNativeSessionCas() = Fixture().use { f ->
        val database = "unconfigured-session-${uuid()}.db"
        val sessions = AndroidSessionStore(context, database)
        try {
            val ids = AgentSessionFixture.Ids()
            val session = AgentSessionFixture.session(ids)
            session.put("active_conversation_id", ids.conversation)
            session.getJSONObject("preferences").put("default_model", JSONObject.NULL)
                .put("selected_harness_id", JSONObject.NULL)
            session.getJSONArray("conversations").getJSONObject(0).apply {
                put("model_id", JSONObject.NULL)
                put("messages", JSONArray()); put("turns", JSONArray()); put("attempts", JSONArray())
            }
            val first = sessions.persist(JSONObject().put("schema_version", 1).put("operation_id", uuid())
                .put("expected", JSONObject().put("schema_version", 1).put("kind", "missing"))
                .put("candidate_json", RishAgentCoreNative.canonical(session.toString())))
            assertEquals("committed", first.getString("status"))
            val loaded = JSONObject(sessions.load().getString("session_json"))
            assertTrue(loaded.getJSONObject("preferences").isNull("default_model"))
            assertTrue(loaded.getJSONArray("conversations").getJSONObject(0).isNull("model_id"))
            loaded.getJSONArray("conversations").getJSONObject(0).put("title", "Unconfigured conversation")
            val request = JSONObject().put("schema_version", 1).put("operation_id", uuid())
                .put("expected", AgentSessionFixture.expecting(first.getJSONObject("snapshot")))
                .put("candidate_json", RishAgentCoreNative.canonical(loaded.toString()))
            val saved = sessions.persist(request)
            assertEquals("committed", saved.getString("status"))
            assertEquals(saved.getJSONObject("snapshot").toString(), sessions.persist(request).getJSONObject("snapshot").toString())
            assertEquals(0, f.catalog.models().length())
        } finally { sessions.close(); context.deleteDatabase(database) }
    }

    @Test fun explicitRawModelsHaveIndependentProviderOwnershipAndCanRetire() = Fixture().use { f ->
        for (harness in AndroidProviderModelCatalog.harnesses) {
            val id = "new-${harness}-model"
            f.save(harness, id)
            assertEquals(harness, AndroidProviderConfiguration.harness(id))
            assertTrue(AndroidProviderConfiguration.isActiveModel(id))
            assertEquals(harness, f.configurations.forModel(id).getString("harness_id"))
        }
        f.save("codex")
        assertFalse(AndroidProviderConfiguration.isActiveModel("new-codex-model"))
        assertEquals("codex", AndroidProviderConfiguration.harnessForHistory("new-codex-model"))
        val history = AndroidSessionEnvironment.facts(JSONObject().put("model", "new-codex-model"))
        assertEquals("codex", history.getJSONObject("harness_by_model").getString("new-codex-model"))
        assertEquals(0, AndroidSessionEnvironment.facts(JSONObject().put("model", "new-codex-model"), false)
            .getJSONArray("supported_models").length())
    }

    @Test fun legacyStoredDshMetadataMigratesWithoutGeneratingDefaultsOrWritingItsKey() {
        val legacy = JSONObject().put("schema_version", 1).put("models", rows("old-dsh-personal"))
            .put("retired_models", rows("older-dsh-personal"))
        Fixture { legacy }.use { f ->
            val before = RuntimeJson.canonical(legacy)
            assertEquals("old-dsh-personal", f.catalog.models().getJSONObject(0).getString("id"))
            assertEquals("dsh", f.catalog.harnessForHistory("older-dsh-personal"))
            f.save("codex", "manually-added-openai")
            assertEquals(before, RuntimeJson.canonical(legacy))
            assertEquals(2, f.catalog.models().length())
            assertEquals("old-dsh-personal", f.service.legacyDshCatalog().getJSONArray("models").getJSONObject(0).getString("id"))
            f.service.saveLegacyDshCatalog(JSONObject().put("schema_version", 1).put("models", rows("replacement-dsh")))
            assertEquals("replacement-dsh", f.service.legacyDshCatalog().getJSONArray("models").getJSONObject(0).getString("id"))
            assertFalse(AndroidProviderConfiguration.isActiveModel("old-dsh-personal"))
            assertEquals("dsh", AndroidProviderConfiguration.harnessForHistory("old-dsh-personal"))
        }
    }

    @Test fun staleAndForeignModelSavesLeaveSavedProviderAndCredentialScopeUnchanged() = Fixture().use { f ->
        val official = RuntimeJson.canonical(f.configurations.read("codex"))
        val account = f.configurations.effectiveAccount("OPENAI_API_KEY")
        f.save("codex", "provider-owned-new-model")
        val before = RuntimeJson.canonical(f.service.list())
        assertThrows(RuntimeFailure::class.java) { f.save("dsh", "provider-owned-new-model") }
        assertThrows(RuntimeFailure::class.java) { f.service.save(JSONObject().put("schema_version", 1)
            .put("harness_id", "codex").put("expected_revision", 0).put("models", rows("another-openai-model"))) }
        assertEquals(before, RuntimeJson.canonical(f.service.list()))
        assertEquals(official, RuntimeJson.canonical(f.configurations.read("codex")))
        assertEquals(account, f.configurations.effectiveAccount("OPENAI_API_KEY"))
    }

    @Test fun editingMigratedCatalogRetainsOpaqueLegacyIdsAndExactOldLabels() {
        val old = JSONObject().put("id", "custom:legacy-llama").put("name", "旧👩‍💻模型").put("supports_images", false)
        val legacy = JSONObject().put("schema_version", 1).put("models", JSONArray().put(old)).put("retired_models", JSONArray())
        Fixture { legacy }.use { f ->
            val active = f.service.legacyDshCatalog().getJSONArray("models")
            active.put(JSONObject().put("id", "fresh-dsh-choice").put("name", "Fresh choice").put("supports_images", false))
            f.service.saveLegacyDshCatalog(JSONObject().put("schema_version", 1).put("models", active))
            val saved = f.service.legacyDshCatalog().getJSONArray("models")
            assertEquals(2, saved.length())
            assertEquals(RuntimeJson.canonical(old), RuntimeJson.canonical(saved.getJSONObject(0)))
            assertEquals("dsh", AndroidProviderConfiguration.harnessForHistory("custom:legacy-llama"))
        }
    }

    @Test fun newTransportRequiresAnActiveCatalogRowAndNeverFallsBackToStaticModels() = Fixture().use { f ->
        fun request(id: String) = JSONObject().put("schema_version", 1).put("request_id", uuid())
            .put("model", id).put("thinking_mode", "off").put("history", JSONArray()
                .put(JSONObject().put("role", "user").put("content", "fixture").put("attachments", JSONArray()))).toString()
        assertThrows(RuntimeFailure::class.java) { f.transport.prepare(request("deepseek-v4-flash")) }
        f.save("dsh", "fresh-provider-chat")
        val prepared = f.transport.prepare(request("fresh-provider-chat"))
        try {
            f.transport.validate(prepared)
            assertEquals("fresh-provider-chat", prepared.model)
            assertEquals("dsh", prepared.harness)
            assertEquals("DEEPSEEK_API_KEY", prepared.account)
            assertEquals(0, f.transport.sentRequestCount)
            assertThrows(RuntimeFailure::class.java) { f.save("dsh") }
        } finally { f.transport.discard(prepared) }
        f.save("dsh")
        assertThrows(RuntimeFailure::class.java) { f.transport.prepare(request("fresh-provider-chat")) }
        assertEquals("dsh", AndroidProviderConfiguration.harnessForHistory("fresh-provider-chat"))
    }

    @Test fun persistedAttemptGuardBlocksCatalogMutationAndDiscovery() = Fixture().use { f ->
        var calls = 0
        val guarded = AndroidProviderModels(f.configurations, f.transport, f.keys) {
            calls += 1; throw RuntimeFailure("E_COMPLETION_BUSY")
        }
        assertThrows(RuntimeFailure::class.java) { guarded.save(JSONObject().put("schema_version", 1)
            .put("expected_revision", 0).put("harness_id", "dsh").put("models", rows("model"))) }
        val request = JSONObject().put("schema_version", 1).put("harness_id", "dsh")
            .put("operation_id", uuid()).put("expected_profile", f.configurations.read("dsh"))
        val failure = assertThrows(RuntimeFailure::class.java) { guarded.discover(request) }
        assertEquals("E_COMPLETION_BUSY", failure.code)
        assertEquals(2, calls)
        assertEquals(0, f.catalog.models().length())
    }

    @Test fun retiringAChoiceDoesNotPreventExactPreparedOperationReceiptReplay() = Fixture().use { f ->
        f.save("dsh", AgentSessionFixture.MODEL)
        val database = "provider-retirement-${uuid()}.db"
        val directory = File(context.noBackupFilesDir, "provider-retirement-${uuid()}").apply { mkdirs() }
        val sessions = AndroidSessionStore(context, database)
        try {
            val ids = AgentSessionFixture.Ids()
            val snapshot = AgentSessionFixture.commit(sessions, ids)
            val wal = AndroidAgentWal(directory)
            val prepared = AndroidPreparedAttemptStore(sessions, wal)
            val request = preparedRequest(snapshot, ids)
            val first = prepared.prepareAgentAttempt(request)
            assertEquals("not_agent", first.getString("status"))
            val before = RuntimeJson.canonical(wal.snapshot())
            f.save("dsh")
            assertFalse(AndroidProviderConfiguration.isActiveModel(AgentSessionFixture.MODEL))
            assertEquals(RuntimeJson.canonical(first), RuntimeJson.canonical(prepared.prepareAgentAttempt(request)))
            assertEquals(before, RuntimeJson.canonical(wal.snapshot()))
        } finally {
            sessions.close(); context.deleteDatabase(database); directory.deleteRecursively()
        }
    }

    private fun preparedRequest(snapshot: JSONObject, ids: AgentSessionFixture.Ids): JSONObject {
        val cas = JSONObject().put("schema_version", 1).put("conversation_id", ids.conversation)
            .put("task_id", ids.task).put("attempt_id", ids.attempt).put("expected_controller_generation", 0)
            .put("expected_journal_revision", 0).put("expected_session_generation", snapshot.getLong("generation"))
            .put("expected_session_sha256", snapshot.getString("session_sha256"))
        val checkpoint = JSONObject().put("schema_version", 1).put("journal_revision", 0)
            .put("session_generation", snapshot.getLong("generation")).put("session_sha256", snapshot.getString("session_sha256"))
        val visible = RishAgentCoreNative.hash("visible-history", JSONObject().put("messages", JSONArray().put(
            JSONObject().put("role", "user").put("content", "hello").put("attachments", JSONArray()))))
        return JSONObject().put("schema_version", 2).put("operation_id", ids.operation).put("controller_cas", cas)
            .put("committed_checkpoint", checkpoint).put("task_id", ids.task).put("conversation_id", ids.conversation)
            .put("attempt_id", ids.attempt).put("workspace_id", JSONObject.NULL).put("project_id", JSONObject.NULL)
            .put("workspace_binding_revision", JSONObject.NULL).put("transport_schema_version", 2)
            .put("model", AgentSessionFixture.MODEL).put("thinking_mode", AgentSessionFixture.THINKING)
            .put("visible_message_ids", JSONArray().put(ids.message)).put("visible_history_sha256", visible)
            .put("visible_message_count", 1).put("project_context_sha256", JSONObject.NULL).put("registry_version", 2)
            .put("expected_policy_version", JSONObject.NULL).put("expected_transcript", JSONObject.NULL)
    }
}
