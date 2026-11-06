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

/** Native receipts remain readable after retirement, while dispatch facts do not. */
@RunWith(AndroidJUnit4::class)
class AndroidCustomProviderEnvironmentTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private fun uuid() = UUID.randomUUID().toString()
    private val digest = "c".repeat(64)
    private val now = "2026-10-29T00:00:00.000Z"

    private class Provider(val configuration: AndroidProviderConfiguration, val id: String, val model: String, val binding: JSONObject) {
        val harness: String get() = binding.getString("harness_id")
    }

    private fun provider(namespace: String): Provider {
        val configurations = AndroidProviderConfiguration(context, namespace)
        val id = uuid()
        val modelId = uuid()
        val model = "custom:$id:$modelId"
        val config = configurations.normalize(JSONObject().put("schema_version", 1).put("harness_id", "custom-$id")
            .put("name", "Independent relay").put("endpoint_url", "https://relay.example.com/v1")
            .put("protocol", "responses").put("auth_type", "bearer").put("send_reasoning", false)
            .put("model_mappings", JSONObject().put(model, "upstream-model")))
        configurations.custom.save(0, JSONObject().put("id", id).put("configuration", config).put("active", true)
            .put("models", JSONArray().put(JSONObject().put("id", modelId).put("name", "My model")
                .put("wire_model", "upstream-model").put("supports_images", false).put("active", true))))
        return Provider(configurations, id, model, configurations.binding(config, model)!!)
    }

    private fun strings(rows: JSONArray): List<String> = (0 until rows.length()).map { rows.getString(it) }

    @Test fun retiredRoutesAreHistoricalFactsButCannotPrepareNewWork() {
        val previous = AndroidProviderConfiguration.registry
        val namespace = "rish.providers.environment-${uuid()}"
        try {
            val provider = provider(namespace)
            val unknown = "custom:${uuid()}:${uuid()}"
            val record = JSONObject().put("model", provider.model).put("provider", "custom-${provider.id}")
                .put("provider_configuration", provider.binding).put("unknown", unknown)
            assertTrue(AndroidSessionEnvironment.isSupported(provider.model))
            assertEquals("relay.example.com", AndroidSessionEnvironment.hostFor(provider.model))
            assertEquals("custom-${provider.id}", AndroidSessionEnvironment.providerFor(provider.model))
            provider.configuration.custom.remove(1, provider.id)
            assertFalse(AndroidSessionEnvironment.isSupported(provider.model))
            assertNull(AndroidSessionEnvironment.harnessIdFor(provider.model))
            assertNull(AndroidSessionEnvironment.hostFor(provider.model))
            assertNull(AndroidSessionEnvironment.providerFor(provider.model))
            assertTrue(AndroidProviderConfiguration.validBinding(provider.binding, provider.model))
            val historical = AndroidSessionEnvironment.facts(record)
            assertEquals(listOf(provider.model), strings(historical.getJSONArray("supported_models")))
            assertEquals(listOf("custom-${provider.id}"), strings(historical.getJSONArray("provider_ids")))
            assertTrue(historical.getJSONArray("provider_bindings").getJSONObject(0).getBoolean("valid"))
            assertEquals("relay.example.com", historical.getJSONArray("provider_bindings").getJSONObject(0).getString("host"))
            assertFalse(historical.getJSONObject("host_by_model").has(provider.model))
            val active = AndroidSessionEnvironment.facts(record, includeRetired = false)
            assertEquals(0, active.getJSONArray("supported_models").length())
            assertEquals(0, active.getJSONArray("provider_ids").length())
            assertFalse(AndroidProviderConfiguration.validBinding(provider.binding, unknown))
        } finally {
            AndroidProviderConfiguration.registry = previous
            context.getSharedPreferences(namespace, 0).edit().clear().commit()
            context.getSharedPreferences("$namespace.custom", 0).edit().clear().commit()
        }
    }

    private fun completedRound(wal: AndroidAgentWal, provider: Provider): JSONObject {
        val task = uuid(); val attempt = uuid(); val roundId = uuid(); val nativeTask = uuid()
        val root = JSONObject().put("schema_version", 1).put("kind", "workspace")
            .put("workspace_id", uuid()).put("project_id", JSONObject.NULL).put("workspace_binding_revision", 1)
            .put("root_fingerprint_sha256", digest).put("capabilities", JSONArray().put("file_read"))
        val transcript = AndroidAgentTranscriptStore(wal).create(JSONObject().put("schema_version", 1)
            .put("attempt_id", attempt).put("root", root))!!
        val locator = JSONObject().put("schema_version", 1).put("task_id", task).put("attempt_id", attempt)
            .put("round_id", roundId).put("round_index", 0)
        val owner = JSONObject().put("schema_version", 1).put("task_id", task).put("launch_id", AndroidAgentWal.launchId)
            .put("native_task_id", nativeTask).put("owner_generation", 1).put("heartbeat_at", now)
        val row = JSONObject().put("schema_version", 3).put("locator", locator).put("row_revision", 1)
            .put("root_fingerprint_sha256", digest).put("binding_revision", 1).put("request_sha256", digest)
            .put("transcript_before", transcript).put("launch_attempt", 1).put("state", "in_flight").put("owner", owner)
            .put("failure_code", JSONObject.NULL).put("completion_receipt", JSONObject.NULL).put("transcript_after", JSONObject.NULL)
            .put("calls", JSONArray()).put("batch_class", JSONObject.NULL).put("executable_call_count", 0).put("denied_call_count", 0)
            .put("terminal_kind", JSONObject.NULL).put("created_at", now).put("updated_at", now)
        val tasks = AndroidLiveTasks().apply { register(nativeTask) }
        val journal = AndroidAgentRoundJournal(wal, tasks)
        val insert = JSONObject().put("schema_version", 1).put("locator", locator).put("expected_absent", true)
            .put("expected_transcript_generation", transcript.getLong("generation"))
            .put("expected_transcript_sha256", transcript.getString("transcript_sha256"))
            .put("expected_root_fingerprint_sha256", digest).put("expected_binding_revision", 1)
        fun cas(saved: JSONObject) = JSONObject().put("schema_version", 2).put("locator", locator)
            .put("expected_row_revision", saved.getLong("row_revision")).put("expected_state", saved.getString("state"))
            .put("expected_owner_generation", 1).put("expected_launch_id", AndroidAgentWal.launchId)
            .put("expected_native_task_id", nativeTask).put("expected_transcript_generation", transcript.getLong("generation"))
            .put("expected_transcript_sha256", transcript.getString("transcript_sha256"))
            .put("expected_root_fingerprint_sha256", digest).put("expected_binding_revision", 1)
        val created = journal.create(insert, row)!!.getJSONObject("row")
        val dispatched = journal.markDispatched(cas(created))!!.getJSONObject("row")
        val receipt = JSONObject().put("schema_version", 1).put("transport_schema_version", 3)
            .put("turn_id", task).put("attempt_id", attempt).put("round_id", roundId).put("round_index", 0)
            .put("provider_request_id", "request-1").put("provider_response_id", "response-1")
            .put("harness_id", provider.harness).put("model", provider.model).put("requested_model", provider.model)
            .put("thinking_mode", "off").put("finish_reason", "stop").put("latency_ms", 1)
            .put("visible_history_sha256", digest).put("model_input_sha256", digest).put("request_body_sha256", digest)
            .put("project_context_receipt", JSONObject.NULL).put("provider_configuration", provider.binding)
        val messages = JSONArray().put(JSONObject().put("schema_version", 1).put("role", "assistant").put("round_index", 0)
            .put("content", "done").put("reasoning_content", "").put("tool_calls", JSONArray()))
        return journal.complete(locator, cas(dispatched), messages, receipt, "final", JSONArray(), root)!!.getJSONObject("row")
    }

    @Test fun nativeJournalCommitsBoundReceiptAndReopensAfterProviderRetirement() {
        val previous = AndroidProviderConfiguration.registry
        val namespace = "rish.providers.journal-${uuid()}"
        val directory = File(context.noBackupFilesDir, "custom-round-${uuid()}").apply { mkdirs() }
        val reopened = File(context.noBackupFilesDir, "custom-round-reopen-${uuid()}").apply { mkdirs() }
        try {
            val provider = provider(namespace)
            val wal = AndroidAgentWal(directory)
            val row = completedRound(wal, provider)
            assertEquals("completed", row.getString("state"))
            provider.configuration.custom.remove(1, provider.id)
            // A distinct storage root has no resident handle: the reader must
            // validate the canonical bytes, the receipt and historical route.
            File(directory, AndroidAgentWal.FILE_NAME).copyTo(File(reopened, AndroidAgentWal.FILE_NAME))
            val restored = AndroidAgentWal(reopened).snapshot()
            assertEquals("completed", restored.getJSONArray("rounds").getJSONObject(0).getString("state"))
            assertTrue(AndroidWalRowVerdicts.forState(restored).getJSONArray("round_valid").getBoolean(0))
            val receipt = restored.getJSONArray("rounds").getJSONObject(0).getJSONObject("completion_receipt")
            receipt.getJSONObject("provider_configuration").put("model_id", "another-upstream")
            assertFalse(AndroidWalRowVerdicts.forState(restored).getJSONArray("round_valid").getBoolean(0))
        } finally {
            AndroidProviderConfiguration.registry = previous
            directory.deleteRecursively(); reopened.deleteRecursively()
            context.getSharedPreferences(namespace, 0).edit().clear().commit()
            context.getSharedPreferences("$namespace.custom", 0).edit().clear().commit()
        }
    }

    @Test fun legacyOpaqueCustomNamesRetainDshHistoryButCannotClaimRegistryIdentities() {
        AndroidDshModelCatalog.initialize(context)
        val catalogPreferences = context.getSharedPreferences("rish.dsh-models.v1", 0)
        val previousCatalog = catalogPreferences.getString("catalog", null)
        val previousRegistry = AndroidProviderConfiguration.registry
        val namespace = "rish.providers.legacy-journal-${uuid()}"
        val directory = File(context.noBackupFilesDir, "legacy-custom-round-${uuid()}").apply { mkdirs() }
        val reopened = File(context.noBackupFilesDir, "legacy-custom-reopen-${uuid()}").apply { mkdirs() }
        val opaque = "custom:my-llama"
        val retired = "custom:retired-llama"
        val collision = "custom:${uuid()}:${uuid()}"
        fun entry(id: String) = JSONObject().put("id", id).put("name", "Legacy model").put("supports_images", false)
        fun storeCatalog(active: JSONArray, historical: JSONArray) {
            // This is an old stored catalog, not a new-input save. New catalog
            // writes intentionally reserve custom: for independent providers.
            assertTrue(catalogPreferences.edit().putString("catalog", JSONObject().put("schema_version", 1)
                .put("models", active).put("retired_models", historical).toString()).commit())
        }
        try {
            storeCatalog(JSONArray().put(entry(opaque)).put(entry(collision)), JSONArray().put(entry(retired)))
            val configurations = AndroidProviderConfiguration(context, namespace)
            assertFalse(AndroidProviderConfiguration.isCustomModel(opaque))
            assertTrue(AndroidProviderConfiguration.isCustomModel(collision))
            assertEquals("dsh", AndroidProviderConfiguration.harness(opaque))
            assertEquals("dsh", AndroidProviderConfiguration.harnessForHistory(retired))
            assertNull(AndroidProviderConfiguration.harnessForHistory(collision))
            assertFalse(AndroidSessionEnvironment.isSupported(collision))
            assertEquals("dsh", AndroidProviderConfiguration.harness("deepseek-v4-flash"))
            val config = configurations.normalize(JSONObject().put("schema_version", 1).put("harness_id", "dsh")
                .put("name", "Legacy DSH relay").put("endpoint_url", "https://legacy-relay.example.com/v1")
                .put("protocol", "chat-completions").put("auth_type", "bearer").put("send_reasoning", false)
                .put("model_mappings", JSONObject().put(opaque, "legacy-upstream")))
            val binding = configurations.binding(config, opaque)!!
            assertTrue(AndroidProviderConfiguration.validBinding(binding, opaque))
            val facts = AndroidSessionEnvironment.facts(JSONObject().put("model", opaque)
                .put("provider_configuration", binding).put("retired", retired).put("collision", collision))
            assertEquals(setOf(opaque, retired), strings(facts.getJSONArray("supported_models")).toSet())
            assertEquals("dsh", facts.getJSONObject("harness_by_model").getString(opaque))
            assertTrue(facts.getJSONArray("provider_bindings").getJSONObject(0).getBoolean("valid"))
            assertFalse(AndroidProviderConfiguration.historicalModels().contains(collision))
            val wal = AndroidAgentWal(directory)
            val row = completedRound(wal, Provider(configurations, "legacy", opaque, binding))
            assertEquals("completed", row.getString("state"))
            assertEquals("dsh", row.getJSONObject("completion_receipt").getString("harness_id"))
            // Retirement of the opaque DSH entry preserves the completed
            // receipt even beside a stored collision with the new namespace.
            storeCatalog(JSONArray().put(entry("deepseek-v4-flash")).put(entry(collision)),
                JSONArray().put(entry(opaque)).put(entry(retired)))
            File(directory, AndroidAgentWal.FILE_NAME).copyTo(File(reopened, AndroidAgentWal.FILE_NAME))
            val restored = AndroidAgentWal(reopened).snapshot()
            assertEquals("completed", restored.getJSONArray("rounds").getJSONObject(0).getString("state"))
            assertTrue(AndroidWalRowVerdicts.forState(restored).getJSONArray("round_valid").getBoolean(0))
            assertEquals("dsh", AndroidProviderConfiguration.harnessForHistory(opaque))
            assertNull(AndroidProviderConfiguration.harnessForHistory(collision))
        } finally {
            catalogPreferences.edit().apply {
                if (previousCatalog == null) remove("catalog") else putString("catalog", previousCatalog)
            }.commit()
            AndroidProviderConfiguration.registry = previousRegistry
            context.getSharedPreferences(namespace, 0).edit().clear().commit()
            context.getSharedPreferences("$namespace.custom", 0).edit().clear().commit()
            directory.deleteRecursively(); reopened.deleteRecursively()
        }
    }

}
