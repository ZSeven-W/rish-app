package tech.zseven.rish

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.*
import java.net.InetAddress
import java.net.ServerSocket
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Actual OkHttp loopback requests with fixture keys only; no external inference. */
@RunWith(AndroidJUnit4::class)
class AndroidCustomProviderTransportTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private fun uuid() = UUID.randomUUID().toString()
    private class Capture(private val response: String, count: Int = 1) : AutoCloseable {
        val socket = ServerSocket(0, 4, InetAddress.getByName("127.0.0.1"))
        val requests = mutableListOf<String>()
        private val finished = CountDownLatch(1)
        var failure: Throwable? = null
        init {
            socket.soTimeout = 10000
            Thread {
                try {
                    repeat(count) {
                        socket.accept().use { client ->
                            client.soTimeout = 10000
                            val reader = client.getInputStream().bufferedReader(Charsets.UTF_8)
                            val header = StringBuilder()
                            var size = 0
                            while (true) {
                                val line = reader.readLine() ?: error("request ended before headers")
                                if (line.isEmpty()) break
                                header.append(line).append("\r\n")
                                if (line.startsWith("content-length:", true)) size = line.substringAfter(':').trim().toInt()
                            }
                            val body = CharArray(size)
                            var position = 0
                            while (position < size) {
                                val length = reader.read(body, position, size - position)
                                require(length > 0); position += length
                            }
                            requests.add(header.append("\r\n").append(body).toString())
                            val bytes = response.toByteArray()
                            client.getOutputStream().apply {
                                write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${bytes.size}\r\nConnection: close\r\n\r\n".toByteArray())
                                write(bytes); flush()
                            }
                        }
                    }
                } catch (error: Throwable) { failure = error }
                finally { finished.countDown() }
            }.start()
        }
        fun await() { assertTrue(finished.await(15, TimeUnit.SECONDS)); failure?.let { throw AssertionError(it) } }
        override fun close() { socket.close() }
    }
    private class Fixture(val configs: AndroidProviderConfiguration, val keys: AndroidCredentialStore, val transport: AndroidModelTransport)
    private fun isolated(body: (Fixture) -> Unit) {
        assertTrue("shared native core required", RishAgentCoreNative.available)
        val previous = AndroidProviderConfiguration.registry
        val namespace = "custom-provider-transport-${uuid()}"
        try {
            val configs = AndroidProviderConfiguration(context, "$namespace.providers")
            val keys = AndroidCredentialStore(context, namespace)
            body(Fixture(configs, keys, AndroidModelTransport(keys, configs)))
        } finally {
            AndroidProviderConfiguration.registry = previous
            for (name in listOf(namespace, "$namespace.providers", "$namespace.providers.custom")) {
                context.getSharedPreferences(name, 0).edit().clear().commit()
            }
            java.security.KeyStore.getInstance("AndroidKeyStore").apply { load(null); deleteEntry("$namespace.aes") }
        }
    }
    private fun add(f: Fixture, endpoint: String, protocol: String, auth: String = "bearer"): Pair<String, JSONObject> {
        val id = uuid(); val modelId = uuid(); val model = "custom:$id:$modelId"
        val config = f.configs.normalize(JSONObject().put("schema_version", 1).put("harness_id", "custom-$id")
            .put("name", "Independent provider").put("endpoint_url", endpoint).put("full_url", true)
            .put("protocol", protocol).put("auth_type", auth).put("send_reasoning", false)
            .put("model_mappings", JSONObject().put(model, "same-upstream")))
        val row = JSONObject().put("id", id).put("configuration", config).put("active", true)
            .put("models", JSONArray().put(JSONObject().put("id", modelId).put("name", "My model")
                .put("wire_model", "same-upstream").put("supports_images", false).put("active", true)))
        f.configs.custom.save(f.configs.custom.read().getLong("revision"), row)
        return model to row
    }
    private fun request(model: String): JSONObject = JSONObject().put("schema_version", 2)
        .put("harness_id", AndroidProviderConfiguration.harness(model)).put("turn_id", uuid()).put("attempt_id", uuid())
        .put("round_id", uuid()).put("round_index", 0).put("model", model).put("thinking_mode", "off")
        .put("project_context", JSONObject.NULL).put("round_transcript", JSONArray()).put("tools", JSONArray())
        .put("visible_history", JSONArray().put(JSONObject().put("role", "user").put("content", "fixture").put("attachments", JSONArray())))
    private val chatReply = """{"id":"r","model":"same-upstream","choices":[{"index":0,"message":{"role":"assistant","content":"answer"},"finish_reason":"stop"}]}"""

    @Test fun allThreeDialectsRouteNamespacedModelAndRecordCapturedBinding() {
        val replies = mapOf(
            "chat-completions" to chatReply,
            "messages" to """{"id":"r","type":"message","role":"assistant","model":"same-upstream","content":[{"type":"text","text":"answer"}],"stop_reason":"end_turn"}""",
            "responses" to """{"id":"r","object":"response","model":"same-upstream","status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"answer"}]}]}""",
        )
        for ((protocol, reply) in replies) isolated { f ->
            Capture(reply).use { server ->
                val (model, provider) = add(f, "http://127.0.0.1:${server.socket.localPort}/$protocol", protocol)
                f.keys.put(f.configs.accountForModel(model)!!, "fixture-key")
                val prepared = f.transport.prepare(request(model).toString())
                f.transport.validate(prepared, true)
                val result = f.transport.execute(prepared)
                server.await()
                assertEquals("answer", result.getString("text"))
                assertEquals(model, result.getString("model"))
                assertEquals("custom-${provider.getString("id")}", result.getString("harness_id"))
                assertTrue(AndroidProviderConfiguration.validBinding(result.get("provider_configuration"), model))
                assertEquals("same-upstream", JSONObject(server.requests.single().substringAfter("\r\n\r\n")).getString("model"))
                assertTrue(server.requests.single().contains("Authorization: Bearer fixture-key"))
            }
        }
    }

    @Test fun identicalEndpointAndWireNamesStillHaveSeparateCredentialsAndReceipts() = isolated { f ->
        Capture(chatReply, 2).use { server ->
            val url = "http://127.0.0.1:${server.socket.localPort}/chat/completions"
            val (first, _) = add(f, url, "chat-completions")
            val (second, _) = add(f, url, "chat-completions")
            val firstAccount = f.configs.accountForModel(first)!!
            val secondAccount = f.configs.accountForModel(second)!!
            assertNotEquals(firstAccount, secondAccount)
            f.keys.put(firstAccount, "first-fixture-key"); f.keys.put(secondAccount, "second-fixture-key")
            val a = f.transport.execute(f.transport.prepare(request(first).toString()))
            val b = f.transport.execute(f.transport.prepare(request(second).toString()))
            server.await()
            assertTrue(server.requests[0].contains("Authorization: Bearer first-fixture-key"))
            assertFalse(server.requests[0].contains("second-fixture-key"))
            assertTrue(server.requests[1].contains("Authorization: Bearer second-fixture-key"))
            assertNotEquals(a.getString("model"), b.getString("model"))
            assertNotEquals(a.getJSONObject("provider_configuration").getString("profile_id"), b.getJSONObject("provider_configuration").getString("profile_id"))
            f.keys.clear(firstAccount)
            assertFalse(f.keys.configured(firstAccount)); assertTrue(f.keys.configured(secondAccount))
        }
    }

    @Test fun noAuthOmitsAllCredentialHeadersAndNeverFallsBackToBuiltinKey() = isolated { f ->
        Capture(chatReply).use { server ->
            val (model, _) = add(f, "http://127.0.0.1:${server.socket.localPort}/chat/completions", "chat-completions", "none")
            f.keys.put("OPENAI_API_KEY", "builtin-key-must-never-travel")
            assertNull(f.configs.accountForModel(model))
            val prepared = f.transport.prepare(request(model).toString())
            f.transport.validate(prepared, true)
            f.transport.execute(prepared); server.await()
            val headers = server.requests.single().substringBefore("\r\n\r\n").lowercase()
            assertFalse(headers.contains("authorization:")); assertFalse(headers.contains("api-key:"))
            assertFalse(headers.contains("builtin-key-must-never-travel"))
        }
    }

    @Test fun existingOpaqueCustomPrefixDshModelStillExecutesItsOriginalRoute() = isolated { f ->
        AndroidDshModelCatalog.initialize(context)
        val prefs = context.getSharedPreferences("rish.dsh-models.v1", 0)
        val previous = prefs.getString("catalog", null)
        val model = "custom:my-llama"
        try {
            val stored = JSONObject().put("schema_version", 1)
                .put("models", JSONArray().put(JSONObject().put("id", model).put("name", "Legacy model").put("supports_images", false)))
                .put("retired_models", JSONArray())
            assertTrue(prefs.edit().putString("catalog", stored.toString()).commit())
            assertFalse(AndroidProviderConfiguration.isCustomModel(model))
            assertEquals("dsh", AndroidProviderConfiguration.harness(model))
            Capture(chatReply).use { server ->
                f.configs.save(JSONObject().put("schema_version", 1).put("harness_id", "dsh").put("name", "Original relay")
                    .put("endpoint_url", "http://127.0.0.1:${server.socket.localPort}/chat/completions").put("full_url", true)
                    .put("protocol", "chat-completions").put("auth_type", "bearer").put("send_reasoning", false)
                    .put("model_mappings", JSONObject().put(model, "same-upstream")))
                f.keys.put(f.configs.effectiveAccount("DEEPSEEK_API_KEY"), "legacy-fixture-key")
                val result = f.transport.execute(f.transport.prepare(request(model).toString()))
                server.await()
                assertEquals(model, result.getString("model"))
                assertEquals("dsh", result.getString("harness_id"))
                assertTrue(AndroidProviderConfiguration.validBinding(result.get("provider_configuration"), model))
                assertTrue(server.requests.single().contains("Authorization: Bearer legacy-fixture-key"))
            }
            // Existing records remain valid while new writes reserve the prefix.
            assertThrows(Exception::class.java) { AndroidDshModelCatalog.save(JSONObject().put("schema_version", 1).put("models", stored.get("models"))) }
            assertEquals(stored.toString(), prefs.getString("catalog", null))
        } finally {
            val editor = prefs.edit()
            if (previous == null) editor.remove("catalog") else editor.putString("catalog", previous)
            assertTrue(editor.commit())
        }
    }

    @Test fun mappingEditOrRetirementCannotSilentlyChangeAPreparedRequest() = isolated { f ->
        val (model, provider) = add(f, "http://127.0.0.1:9/chat/completions", "chat-completions", "none")
        val prepared = f.transport.prepare(request(model).toString())
        val revision = f.configs.custom.read().getLong("revision")
        f.configs.custom.remove(revision, provider.getString("id"))
        try { f.transport.execute(prepared); fail("retired request dispatched") } catch (_: Exception) { }
        assertEquals(0, f.transport.sentRequestCount)
        assertEquals(0, f.transport.activeRequestCount())
        assertThrows(Exception::class.java) { f.transport.prepare(request(model).toString()) }
    }
}
