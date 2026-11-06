package tech.zseven.rish

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.AndroidDshModelCatalog
import tech.zseven.rish.runtime.AndroidProviderConfiguration
import tech.zseven.rish.runtime.RishAgentCoreNative
import tech.zseven.rish.runtime.RuntimeJson
import java.util.UUID

/** Real JNI policy and native storage/URL adapters. No injected success or skipped native gate. */
@RunWith(AndroidJUnit4::class)
class SharedProviderPolicyTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext

    @Before fun requireSharedNativePolicy() {
        assertTrue("Package the shared Rust agent core for this acceptance gate", RishAgentCoreNative.available)
    }

    private fun fixtures(name: String, reduce: (String) -> String?) {
        val text = InstrumentationRegistry.getInstrumentation().context.assets.open(name).bufferedReader().use { it.readText() }
        val cases = JSONObject(text).getJSONArray("cases")
        for (index in 0 until cases.length()) {
            val row = cases.getJSONObject(index)
            val encoded = reduce(row.getJSONObject("input").toString())
            assertNotNull(row.getString("name"), encoded)
            assertEquals(row.getString("name"), RuntimeJson.canonical(row.get("expected")), RuntimeJson.canonical(JSONObject(encoded!!)))
        }
    }

    @Test fun modelCatalogMatchesSharedFixtures() = fixtures("model-catalog-policy.json", RishAgentCoreNative::modelCatalog)
    @Test fun providerPolicyMatchesSharedFixtures() = fixtures("provider-policy.json", RishAgentCoreNative::providerPolicy)

    private fun profile(endpoint: String = "https://relay.example.com/v1", fullUrl: Boolean = false) = JSONObject()
        .put("schema_version", 1).put("harness_id", "codex").put("name", "Fixture")
        .put("endpoint_url", endpoint).put("protocol", "responses").put("auth_type", "bearer")
        .put("model_mappings", JSONObject().put("gpt-5.6", "mapped-model")).put("send_reasoning", true)
        .put("full_url", fullUrl)

    private fun <T> isolated(block: (AndroidProviderConfiguration, android.content.SharedPreferences) -> T): T {
        val namespace = "rish.providers.shared-policy-test.${UUID.randomUUID()}"
        val prefs = context.getSharedPreferences(namespace, 0)
        return try { block(AndroidProviderConfiguration(context, namespace), prefs) }
        finally { assertTrue(prefs.edit().clear().commit()) }
    }

    @Test fun nativeUrlEscapingAndExistingAccountBytesRemainCompatible() = isolated { adapter, _ ->
        val saved = adapter.save(profile("HTTPS://relay.example.com:443/api/a%2Fb/%E4%B8%AD/", true))
        val endpoint = "https://relay.example.com/api/a%2Fb/%E4%B8%AD/"
        assertEquals(endpoint, saved.getString("endpoint_url"))
        assertEquals(endpoint, adapter.read("codex").getString("endpoint_url"))
        val identity = JSONObject().put("harness_id", "codex").put("endpoint_url", endpoint)
            .put("auth_type", "bearer").put("protocol", "responses")
        val expectedCurrent = "CUSTOM_PROVIDER_codex_${RuntimeJson.sha("rish.provider-configuration-v1.v1\u0000" + RuntimeJson.canonical(identity))}"
        assertEquals(expectedCurrent, adapter.effectiveAccount("OPENAI_API_KEY"))
        val legacy = identity.keys().asSequence().toList().sorted().joinToString(",", "{", "}") {
            JSONObject.quote(it) + ":" + JSONObject.quote(identity.getString(it))
        }
        assertEquals("CUSTOM_PROVIDER_codex_${RuntimeJson.sha("rish.provider-configuration-v1.v1\u0000" + legacy)}", adapter.previousAccount("OPENAI_API_KEY"))
        val binding = requireNotNull(adapter.binding(saved, "gpt-5.6"))
        assertTrue(AndroidProviderConfiguration.validBinding(binding, "gpt-5.6"))
        assertFalse(AndroidProviderConfiguration.validBinding(JSONObject(binding.toString()).put("model_id", "changed"), "gpt-5.6"))
        assertFalse(AndroidProviderConfiguration.validBinding(binding, "deepseek-v4-flash"))
    }

    @Test fun suffixAndTransportSafetyAreRustDecisionsAfterNativeParsing() = isolated { adapter, _ ->
        for ((input, expected) in listOf(
            "https://relay.example.com" to "https://relay.example.com/v1/responses",
            "https://relay.example.com/v1/" to "https://relay.example.com/v1/responses",
            "https://relay.example.com/v1/messages" to "https://relay.example.com/v1/responses",
            "http://127.0.0.1:8123/api" to "http://127.0.0.1:8123/api/v1/responses",
            "http://[::1]:8123" to "http://[::1]:8123/v1/responses",
        )) assertEquals(expected, adapter.normalize(profile(input)).getString("endpoint_url"))
        for (input in listOf("http://relay.example.com", "https://user:pass@relay.example.com", "https://relay.example.com?key=value", "https://relay.example.com#fragment")) {
            assertThrows(Exception::class.java) { adapter.normalize(profile(input)) }
        }
    }

    @Test fun rejectedStoredConfigurationIsNeverResetOrWrittenBack() = isolated { adapter, prefs ->
        for (stored in listOf("{", "{}", profile().put("official", true).toString(), profile().put("schema_version", true).toString(),
            profile().put("model_mappings", JSONObject().put("gpt-5.6", "中".repeat(43))).toString())) {
            assertTrue(prefs.edit().putString("codex", stored).commit())
            assertThrows(Exception::class.java) { adapter.read("codex") }
            assertEquals(stored, prefs.getString("codex", null))
        }
    }

    @Test fun invalidSaveLeavesPreviousConfigurationUntouched() = isolated { adapter, prefs ->
        adapter.save(profile())
        val previous = prefs.getString("codex", null)
        for (bad in listOf(profile().put("full_url", "true"), profile().put("send_reasoning", 1),
            profile().put("model_mappings", JSONObject().put("claude-sonnet-5", "mapped")))) {
            assertThrows(Exception::class.java) { adapter.save(bad) }
            assertEquals(previous, prefs.getString("codex", null))
        }
    }

    @Test fun catalogRetirementAndCorruptionUseSharedPolicyWithoutReplacement() {
        AndroidDshModelCatalog.initialize(context)
        val prefs = context.getSharedPreferences("rish.dsh-models.v1", 0)
        val previous = prefs.getString("catalog", null)
        try {
            assertTrue(prefs.edit().remove("catalog").commit())
            val original = AndroidDshModelCatalog.read()
            val custom = JSONObject().put("id", "fixture-custom-vision").put("name", "测试模型").put("supports_images", true)
            AndroidDshModelCatalog.save(JSONObject().put("schema_version", 1).put("models", JSONArray().put(custom)))
            assertTrue(AndroidDshModelCatalog.supportsImages("fixture-custom-vision"))
            AndroidDshModelCatalog.save(JSONObject().put("schema_version", 1).put("models", original.getJSONArray("models")))
            assertTrue(AndroidDshModelCatalog.isKnown("fixture-custom-vision"))
            assertEquals("测试模型", AndroidDshModelCatalog.lookup("fixture-custom-vision")?.getString("name"))
            assertTrue(AndroidDshModelCatalog.supportsImages("fixture-custom-vision"))
            assertEquals("dsh", AndroidProviderConfiguration.harness("fixture-custom-vision"))
            for (stored in listOf("{", "{}", "false")) {
                assertTrue(prefs.edit().putString("catalog", stored).commit())
                assertEquals("codex", AndroidProviderConfiguration.harness("gpt-5.6"))
                assertThrows(Exception::class.java) { AndroidProviderConfiguration.harness("fixture-custom-vision") }
                assertThrows(Exception::class.java) { AndroidDshModelCatalog.isKnown("deepseek-v4-flash") }
                assertThrows(Exception::class.java) { AndroidDshModelCatalog.read() }
                assertThrows(Exception::class.java) {
                    AndroidDshModelCatalog.save(JSONObject().put("schema_version", 1).put("models", original.getJSONArray("models")))
                }
                assertEquals(stored, prefs.getString("catalog", null))
            }
        } finally {
            val editor = prefs.edit()
            if (previous == null) editor.remove("catalog") else editor.putString("catalog", previous)
            assertTrue(editor.commit())
        }
    }
}
