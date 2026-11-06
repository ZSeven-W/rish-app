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
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class AndroidCustomProviderRegistryTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private fun uuid() = UUID.randomUUID().toString()
    private fun provider(configs: AndroidProviderConfiguration): JSONObject {
        val id = uuid(); val modelId = uuid()
        val config = configs.normalize(JSONObject().put("schema_version", 1).put("harness_id", "custom-$id")
            .put("name", "Fixture provider").put("endpoint_url", "https://relay.example.com/v1")
            .put("protocol", "chat-completions").put("auth_type", "bearer").put("send_reasoning", false)
            .put("model_mappings", JSONObject().put("custom:$id:$modelId", "model")))
        return JSONObject().put("id", id).put("configuration", config).put("active", true)
            .put("models", JSONArray().put(JSONObject().put("id", modelId).put("name", "Fixture model")
                .put("wire_model", "model").put("supports_images", false).put("active", true)))
    }
    private fun isolated(body: (AndroidProviderConfiguration, String) -> Unit) {
        val previous = AndroidProviderConfiguration.registry
        val namespace = "custom-registry-${uuid()}"
        try { body(AndroidProviderConfiguration(context, namespace), namespace) }
        finally {
            AndroidProviderConfiguration.registry = previous
            for (name in listOf(namespace, "$namespace.custom")) context.getSharedPreferences(name, 0).edit().clear().commit()
        }
    }

    @Test fun corruptStoredEndpointIsRefusedWithoutResettingMetadata() = isolated { configs, namespace ->
        val saved = configs.custom.save(0, provider(configs))
        saved.getJSONArray("providers").getJSONObject(0).getJSONObject("configuration")
            .put("endpoint_url", "http://external.example.com/v1/chat/completions")
        val prefs = context.getSharedPreferences("$namespace.custom", 0)
        val tampered = saved.toString()
        assertTrue(prefs.edit().putString("registry", tampered).commit())
        assertThrows(Exception::class.java) { configs.custom.read() }
        assertEquals(tampered, prefs.getString("registry", null))
    }

    @Test fun twoNativeWritersCannotBothCommitTheSameRevision() = isolated { configs, namespace ->
        val other = AndroidCustomProviderRegistry(context, "$namespace.custom")
        val ready = CountDownLatch(1); val done = CountDownLatch(2)
        val outcomes = java.util.Collections.synchronizedList(mutableListOf<String>())
        for ((registry, proposed) in listOf(configs.custom to provider(configs), other to provider(configs))) {
            Thread {
                try { ready.await(); registry.save(0, proposed); outcomes.add("saved") }
                catch (failure: RuntimeFailure) { outcomes.add(failure.code) }
                finally { done.countDown() }
            }.start()
        }
        ready.countDown()
        assertTrue(done.await(10, TimeUnit.SECONDS))
        assertEquals(listOf("E_CUSTOM_PROVIDER_REGISTRY_CONFLICT", "saved"), outcomes.sorted())
        assertEquals(1L, configs.custom.read().getLong("revision"))
        assertEquals(1, configs.custom.read().getJSONArray("providers").length())
    }

    @Test fun encryptedCiphertextCannotMoveToAnotherProviderAccount() {
        val namespace = "custom-keys-${uuid()}"
        val store = AndroidCredentialStore(context, namespace)
        val first = "CUSTOM_PROVIDER_custom-${uuid()}_${"a".repeat(64)}"
        val second = "CUSTOM_PROVIDER_custom-${uuid()}_${"a".repeat(64)}"
        val prefs = context.getSharedPreferences(namespace, 0)
        try {
            store.put(first, "fixture-only-secret")
            val ciphertext = prefs.getString(first, null)!!
            assertFalse(ciphertext.contains("fixture-only-secret"))
            assertTrue(prefs.edit().putString(second, ciphertext).commit())
            assertThrows(Exception::class.java) { store.get(second) }
            assertEquals("fixture-only-secret", store.get(first))
            assertThrows(IllegalArgumentException::class.java) { store.put("CUSTOM_PROVIDER_custom-anything_${"a".repeat(64)}", "fixture") }
        } finally {
            prefs.edit().clear().commit()
            java.security.KeyStore.getInstance("AndroidKeyStore").apply { load(null); deleteEntry("$namespace.aes") }
        }
    }
}
