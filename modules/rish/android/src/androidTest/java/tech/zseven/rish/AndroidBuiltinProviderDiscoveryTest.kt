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
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Native GET discovery uses only captured API credentials and does not save candidate models. */
@RunWith(AndroidJUnit4::class)
class AndroidBuiltinProviderDiscoveryTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private fun uuid() = UUID.randomUUID().toString()
    private data class Reply(val body: String, val status: Int = 200, val release: CountDownLatch? = null)
    private data class Received(val method: String, val path: String, val headers: Map<String, String>, val body: JSONObject?)

    private class Server(private val replies: List<Reply>) : AutoCloseable {
        private val socket = ServerSocket(0, 4, InetAddress.getByName("127.0.0.1"))
        val requests = mutableListOf<Received>()
        private val arrivals = replies.map { CountDownLatch(1) }
        private val finished = CountDownLatch(1)
        @Volatile private var failure: Throwable? = null
        private val thread = Thread {
            try {
                socket.soTimeout = 10000
                replies.forEachIndexed { index, reply -> socket.accept().use { client ->
                    client.soTimeout = 10000
                    val reader = client.getInputStream().bufferedReader()
                    val first = reader.readLine().split(' ')
                    val headers = linkedMapOf<String, String>()
                    while (true) {
                        val line = reader.readLine() ?: error("incomplete headers")
                        if (line.isEmpty()) break
                        headers[line.substringBefore(':').lowercase()] = line.substringAfter(':').trim()
                    }
                    // These fixture completion payloads contain ASCII only,
                    // so character and UTF-8 byte counts are identical.
                    val length = headers["content-length"]?.toInt() ?: 0
                    val chars = CharArray(length)
                    var offset = 0
                    while (offset < length) {
                        val count = reader.read(chars, offset, length - offset)
                        check(count > 0); offset += count
                    }
                    val body = if (length == 0) null else JSONObject(String(chars))
                    synchronized(requests) { requests.add(Received(first[0], first[1], headers, body)) }
                    arrivals[index].countDown()
                    check(reply.release?.await(10, TimeUnit.SECONDS) != false)
                    val bytes = reply.body.toByteArray(Charsets.UTF_8)
                    client.getOutputStream().apply {
                        write("HTTP/1.1 ${reply.status} Fixture\r\nContent-Type: application/json\r\nContent-Length: ${bytes.size}\r\nConnection: close\r\n\r\n".toByteArray())
                        write(bytes); flush()
                    }
                } }
            } catch (error: Throwable) { failure = error }
            finally { finished.countDown() }
        }.apply { isDaemon = true; start() }
        fun url(path: String) = "http://127.0.0.1:${socket.localPort}$path"
        fun received(index: Int = 0) { assertTrue(arrivals[index].await(10, TimeUnit.SECONDS)) }
        fun await(allowDisconnect: Boolean = false) {
            assertTrue(finished.await(15, TimeUnit.SECONDS))
            failure?.let { if (!allowDisconnect || it !is java.io.IOException) throw AssertionError(it) }
        }
        override fun close() { replies.forEach { it.release?.countDown() }; socket.close(); thread.join(1000) }
    }

    private inner class Fixture : AutoCloseable {
        val previous = AndroidProviderConfiguration.registry
        val name = "builtin-discovery-${uuid()}"
        val configs = AndroidProviderConfiguration(context, name) { JSONObject.NULL }
        val keys = AndroidCredentialStore(context, "$name.keys")
        val transport = AndroidModelTransport(keys, configs)
        val service = AndroidProviderModels(configs, transport, keys) {}
        fun setup(server: Server, harness: String, protocol: String, auth: String) {
            val suffix = if (protocol == "chat-completions") "chat/completions" else protocol
            configs.save(JSONObject().put("schema_version", 1).put("harness_id", harness)
                .put("name", "API fixture").put("endpoint_url", server.url("/prefix/v1/$suffix"))
                .put("protocol", protocol).put("auth_type", auth).put("send_reasoning", false)
                .put("model_mappings", JSONObject()).put("full_url", true))
            // A default-slot secret deliberately differs: relay discovery must
            // use only its captured scoped account, never borrow the default.
            val slot = AndroidProviderConfiguration.slot(harness)
            keys.put(slot, "unrelated-default-fixture-key")
            keys.put(configs.effectiveAccount(slot), "captured-api-fixture-key")
        }
        fun request(harness: String, operation: String = uuid()) = JSONObject().put("schema_version", 1)
            .put("harness_id", harness).put("operation_id", operation).put("expected_profile", configs.read(harness))
        fun cancel(harness: String, operation: String) = JSONObject().put("schema_version", 1)
            .put("harness_id", harness).put("operation_id", operation)
        override fun close() {
            for (suffix in listOf("", ".models", ".custom", ".keys")) context.getSharedPreferences(name + suffix, 0).edit().clear().commit()
            java.security.KeyStore.getInstance("AndroidKeyStore").apply { load(null); deleteEntry("$name.keys.aes") }
            AndroidProviderConfiguration.registry = previous
        }
    }
    private fun page(vararg ids: String) = JSONObject().put("data", JSONArray().apply {
        ids.forEach { put(JSONObject().put("id", it).put("display_name", "Discovered $it").put("supports_images", true)) }
    }).toString()

    @Test fun allBuiltinProvidersFetchThroughTheirCapturedDialectAndScopedApiKey() {
        val cases = listOf(Triple("dsh", "chat-completions", "bearer"), Triple("claude-code", "messages", "x-api-key"),
            Triple("codex", "responses", "api-key"), Triple("glm", "chat-completions", "bearer"))
        for ((harness, protocol, auth) in cases) Fixture().use { f ->
            Server(listOf(Reply(page("vendor-future-model")))).use { server ->
                f.setup(server, harness, protocol, auth)
                val configBefore = RuntimeJson.canonical(f.configs.read(harness))
                val catalogBefore = RuntimeJson.canonical(f.service.list())
                val request = f.request(harness)
                val result = f.service.discover(request)
                server.await()
                assertEquals(harness, result.getString("harness_id"))
                assertEquals(request.getString("operation_id"), result.getString("operation_id"))
                assertEquals("vendor-future-model", result.getJSONArray("models").getJSONObject(0).getString("wire_model"))
                assertEquals("GET", server.requests.single().method)
                assertEquals("/prefix/v1/models", server.requests.single().path)
                val header = if (auth == "bearer") "authorization" else auth
                val expected = if (auth == "bearer") "Bearer captured-api-fixture-key" else "captured-api-fixture-key"
                assertEquals(expected, server.requests.single().headers[header])
                for (other in setOf("authorization", "x-api-key", "api-key") - header)
                    assertFalse(server.requests.single().headers.containsKey(other))
                if (protocol == "messages") assertEquals("2023-06-01", server.requests.single().headers["anthropic-version"])
                assertEquals(configBefore, RuntimeJson.canonical(f.configs.read(harness)))
                assertEquals(catalogBefore, RuntimeJson.canonical(f.service.list()))
                assertEquals(0, f.transport.activeRequestCount())
            }
        }
    }

    @Test fun missingScopedKeyNeverFallsBackToTheOfficialSlot() = Fixture().use { f ->
        Server(emptyList()).use { server ->
            f.setup(server, "codex", "responses", "bearer")
            f.keys.clear(f.configs.effectiveAccount("OPENAI_API_KEY"))
            val error = assertThrows(RuntimeFailure::class.java) { f.service.discover(f.request("codex")) }
            assertEquals("E_PROVIDER_MODEL_DISCOVERY_CREDENTIAL", error.code)
            assertTrue(server.requests.isEmpty())
            assertTrue(f.keys.configured("OPENAI_API_KEY"))
        }
    }

    @Test fun manuallyRegisteredFutureModelIdsReachEachProtocolWithoutSubstitution() {
        val cases = listOf(Triple("dsh", "chat-completions", "deepseek-future-choice"),
            Triple("claude-code", "messages", "claude-future-choice"), Triple("codex", "responses", "gpt-future-choice"))
        for ((harness, protocol, model) in cases) Fixture().use { f ->
            val response = when (protocol) {
                "messages" -> JSONObject().put("id", "fixture-result").put("type", "message").put("role", "assistant")
                    .put("model", model).put("content", JSONArray().put(JSONObject().put("type", "text").put("text", "answer")))
                    .put("stop_reason", "end_turn")
                "responses" -> JSONObject().put("id", "fixture-result").put("object", "response").put("model", model)
                    .put("status", "completed").put("output", JSONArray().put(JSONObject().put("type", "message").put("role", "assistant")
                        .put("content", JSONArray().put(JSONObject().put("type", "output_text").put("text", "answer")))))
                else -> JSONObject().put("id", "fixture-result").put("model", model).put("choices", JSONArray().put(
                    JSONObject().put("index", 0).put("message", JSONObject().put("role", "assistant").put("content", "answer"))
                        .put("finish_reason", "stop")))
            }
            Server(listOf(Reply(response.toString()))).use { server ->
                f.setup(server, harness, protocol, if (protocol == "messages") "x-api-key" else "bearer")
                f.service.save(JSONObject().put("schema_version", 1).put("expected_revision", 0).put("harness_id", harness)
                    .put("models", JSONArray().put(JSONObject().put("id", model).put("name", "Manual future choice").put("supports_images", false))))
                val request = JSONObject().put("schema_version", 1).put("request_id", uuid()).put("model", model)
                    .put("thinking_mode", "off").put("history", JSONArray().put(JSONObject().put("role", "user")
                        .put("content", "fixture").put("attachments", JSONArray())))
                val answer = f.transport.execute(f.transport.prepare(request.toString()))
                server.await()
                assertEquals("answer", answer.getString("text"))
                assertEquals(model, answer.getString("model"))
                assertEquals(model, server.requests.single().body!!.getString("model"))
                assertEquals("POST", server.requests.single().method)
            }
        }
    }

    @Test fun staleProfilesAndForeignCancellationCannotChangeAnActiveFetch() = Fixture().use { f ->
        val release = CountDownLatch(1)
        Server(listOf(Reply(page("new-model"), release = release))).use { server ->
            f.setup(server, "dsh", "chat-completions", "bearer")
            val request = f.request("dsh")
            val wrong = JSONObject(request.toString()).apply { getJSONObject("expected_profile").put("name", "wrong") }
            assertEquals("E_PROVIDER_CONFIGURATION_CHANGED", assertThrows(RuntimeFailure::class.java) { f.service.discover(wrong) }.code)
            val executor = Executors.newSingleThreadExecutor()
            try {
                val pending = executor.submit<JSONObject> { f.service.discover(request) }
                server.received()
                assertEquals("idle", f.service.cancelDiscovery(f.cancel("codex", request.getString("operation_id"))).getString("status"))
                assertEquals("idle", f.service.cancelDiscovery(f.cancel("dsh", uuid())).getString("status"))
                assertEquals("E_COMPLETION_BUSY", assertThrows(RuntimeFailure::class.java) {
                    f.service.save(JSONObject().put("schema_version", 1).put("harness_id", "dsh")
                        .put("expected_revision", 0).put("models", JSONArray()))
                }.code)
                release.countDown()
                assertEquals(1, pending.get(10, TimeUnit.SECONDS).getJSONArray("models").length())
                server.await()
            } finally { release.countDown(); executor.shutdownNow() }
        }
    }

    @Test fun matchingCancellationStopsOnlyItsOwnOperationAndDoesNotSaveModels() = Fixture().use { f ->
        val release = CountDownLatch(1)
        Server(listOf(Reply(page("cancelled-model"), release = release))).use { server ->
            f.setup(server, "claude-code", "messages", "x-api-key")
            val request = f.request("claude-code")
            val executor = Executors.newSingleThreadExecutor()
            try {
                val pending = executor.submit<JSONObject> { f.service.discover(request) }
                server.received()
                assertEquals("cancelled", f.service.cancelDiscovery(f.cancel("claude-code", request.getString("operation_id"))).getString("status"))
                val error = assertThrows(ExecutionException::class.java) { pending.get(10, TimeUnit.SECONDS) }
                assertEquals("E_PROVIDER_MODEL_DISCOVERY_CANCELLED", (error.cause as RuntimeFailure).code)
                release.countDown(); server.await(true)
                assertEquals(0, f.configs.providerModels.models().length())
                assertEquals(0, f.transport.activeRequestCount())
            } finally { release.countDown(); executor.shutdownNow() }
        }
    }

    @Test fun directCredentialRotationAndCatalogChangesInvalidateCapturedResults() {
        for (changeCatalog in listOf(false, true)) Fixture().use { f ->
            val release = CountDownLatch(1)
            Server(listOf(Reply(page("new-model"), release = release))).use { server ->
                f.setup(server, "glm", "chat-completions", "bearer")
                val executor = Executors.newSingleThreadExecutor()
                try {
                    val pending = executor.submit<JSONObject> { f.service.discover(f.request("glm")) }
                    server.received()
                    if (changeCatalog) f.configs.providerModels.save(JSONObject().put("schema_version", 1)
                        .put("harness_id", "glm").put("expected_revision", 0).put("models", JSONArray().put(
                            JSONObject().put("id", "manual-model").put("name", "Manual").put("supports_images", false))))
                    else f.keys.put(f.configs.effectiveAccount("BIGMODEL_API_KEY"), "rotated-fixture-key")
                    release.countDown()
                    val error = assertThrows(ExecutionException::class.java) { pending.get(10, TimeUnit.SECONDS) }
                    assertEquals("E_PROVIDER_CONFIGURATION_CHANGED", (error.cause as RuntimeFailure).code)
                    server.await()
                } finally { release.countDown(); executor.shutdownNow() }
            }
        }
    }

    @Test fun unknownFullEndpointAndUnsupportedHttpResponseKeepManualCatalog() = Fixture().use { f ->
        Server(listOf(Reply("{}", 404))).use { server ->
            f.setup(server, "glm", "chat-completions", "bearer")
            f.service.save(JSONObject().put("schema_version", 1).put("harness_id", "glm").put("expected_revision", 0)
                .put("models", JSONArray().put(JSONObject().put("id", "manual").put("name", "Manual").put("supports_images", false))))
            val before = RuntimeJson.canonical(f.service.list())
            assertEquals("E_PROVIDER_MODEL_DISCOVERY_HTTP", assertThrows(RuntimeFailure::class.java) { f.service.discover(f.request("glm")) }.code)
            server.await()
            val config = f.configs.read("glm").put("endpoint_url", server.url("/custom-unknown-action")).put("full_url", true)
            f.configs.save(config)
            assertEquals("E_PROVIDER_MODEL_DISCOVERY_UNSUPPORTED", assertThrows(RuntimeFailure::class.java) { f.service.discover(f.request("glm")) }.code)
            assertEquals(before, RuntimeJson.canonical(f.service.list()))
        }
    }
}
