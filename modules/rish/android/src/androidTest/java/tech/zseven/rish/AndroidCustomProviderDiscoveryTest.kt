package tech.zseven.rish

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.*
import java.io.File
import java.net.InetAddress
import java.net.ServerSocket
import java.util.UUID
import java.util.concurrent.Callable
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Real native discovery against bounded loopback fixtures; no external requests or user keys. */
@RunWith(AndroidJUnit4::class)
class AndroidCustomProviderDiscoveryTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private fun uuid() = UUID.randomUUID().toString()

    private data class Reply(val body: String, val status: Int = 200, val release: CountDownLatch? = null)
    private data class Request(val method: String, val target: String, val headers: Map<String, String>)

    private class Loopback(private val replies: List<Reply>) : AutoCloseable {
        val socket = ServerSocket(0, 4, InetAddress.getByName("127.0.0.1"))
        val requests = mutableListOf<Request>()
        private val arrivals = replies.map { CountDownLatch(1) }
        private val finished = CountDownLatch(1)
        @Volatile private var failure: Throwable? = null
        private val thread: Thread
        init {
            socket.soTimeout = 10000
            thread = Thread {
                try {
                    for ((index, reply) in replies.withIndex()) socket.accept().use { client ->
                        client.soTimeout = 10000
                        val input = client.getInputStream().bufferedReader(Charsets.UTF_8)
                        val line = input.readLine() ?: error("missing request line")
                        val words = line.split(' ')
                        val headers = linkedMapOf<String, String>()
                        while (true) {
                            val header = input.readLine() ?: error("missing request headers")
                            if (header.isEmpty()) break
                            headers[header.substringBefore(':').lowercase()] = header.substringAfter(':').trim()
                        }
                        synchronized(requests) { requests.add(Request(words[0], words[1], headers)) }
                        arrivals[index].countDown()
                        check(reply.release?.await(10, TimeUnit.SECONDS) != false) { "fixture response was never released" }
                        val bytes = reply.body.toByteArray(Charsets.UTF_8)
                        client.getOutputStream().apply {
                            write("HTTP/1.1 ${reply.status} Fixture\r\nContent-Type: application/json\r\nContent-Length: ${bytes.size}\r\nConnection: close\r\n\r\n".toByteArray())
                            write(bytes); flush()
                        }
                    }
                } catch (error: Throwable) { failure = error }
                finally { finished.countDown() }
            }.apply { isDaemon = true; start() }
        }
        fun url(path: String) = "http://127.0.0.1:${socket.localPort}$path"
        fun received(index: Int = 0) {
            assertTrue("loopback request $index did not arrive", arrivals[index].await(10, TimeUnit.SECONDS))
        }
        fun await(allowDisconnect: Boolean = false) {
            assertTrue("loopback server did not finish", finished.await(15, TimeUnit.SECONDS))
            failure?.let { if (!allowDisconnect || it !is java.io.IOException) throw AssertionError(it) }
        }
        override fun close() {
            replies.forEach { it.release?.countDown() }
            socket.close()
            thread.join(1000)
        }
    }

    private inner class Fixture : AutoCloseable {
        val previousRegistry = AndroidProviderConfiguration.registry
        val namespace = "custom-provider-discovery-${uuid()}"
        val directory = File(context.noBackupFilesDir, namespace).apply { mkdirs() }
        val configurations = AndroidProviderConfiguration(context, namespace)
        val credentials = AndroidCredentialStore(context, "$namespace.keys")
        val transport = AndroidModelTransport(credentials, configurations)
        val sessions = AndroidSessionStore(context, "$namespace.db")
        val wal = AndroidAgentWal(directory)
        val service = AndroidCustomProviders(configurations, transport, credentials, sessions, wal)
        val id = uuid()
        val operation = uuid()
        fun add(server: Loopback, protocol: String = "messages", auth: String = "x-api-key") {
            val suffix = when (protocol) { "chat-completions" -> "chat/completions"; else -> protocol }
            val config = configurations.normalize(JSONObject().put("schema_version", 1).put("harness_id", "custom-$id")
                .put("name", "Discovery fixture").put("endpoint_url", server.url("/v1/$suffix")).put("full_url", true)
                .put("protocol", protocol).put("auth_type", auth).put("send_reasoning", false)
                .put("model_mappings", JSONObject()))
            // The provider exists before discovery and may have no selected models yet.
            service.save(JSONObject().put("schema_version", 1).put("expected_revision", 0)
                .put("provider", JSONObject().put("id", id).put("configuration", config).put("models", JSONArray()).put("active", true)))
            if (auth != "none") service.put(service.credentialScope(credentialRequest()), "fixture-discovery-key")
        }
        fun credentialRequest() = JSONObject().put("schema_version", 1).put("id", id)
            .put("expected_profile", configurations.custom.provider(id).getJSONObject("configuration"))
        fun request(operationId: String = operation) = credentialRequest().put("operation_id", operationId)
        fun cancelRequest(operationId: String = operation, providerId: String = id) = JSONObject()
            .put("schema_version", 1).put("id", providerId).put("operation_id", operationId)
        fun registry() = RuntimeJson.canonical(configurations.custom.read())
        override fun close() {
            sessions.close(); context.deleteDatabase("$namespace.db")
            for (name in listOf(namespace, "$namespace.custom", "$namespace.keys")) {
                context.getSharedPreferences(name, 0).edit().clear().commit()
            }
            java.security.KeyStore.getInstance("AndroidKeyStore").apply { load(null); deleteEntry("$namespace.keys.aes") }
            directory.deleteRecursively()
            AndroidProviderConfiguration.registry = previousRegistry
        }
    }

    private fun page(ids: List<String>, more: Boolean = false, padding: Int = 0): String = JSONObject()
        .put("data", JSONArray().apply { ids.forEach { put(JSONObject().put("id", it).put("display_name", "Name $it").put("supports_images", true)) } })
        .put("has_more", more).put("last_id", ids.lastOrNull() ?: JSONObject.NULL)
        .apply { if (padding > 0) put("unused_padding", "x".repeat(padding)) }.toString()

    private fun wires(result: JSONObject): List<String> = result.getJSONArray("models").let { rows ->
        (0 until rows.length()).map { rows.getJSONObject(it).getString("wire_model") }
    }

    private fun refused(code: String, operation: () -> Any?): RuntimeFailure {
        try { operation(); fail("expected $code") } catch (failure: RuntimeFailure) {
            assertEquals(code, failure.code)
            return failure
        }
        error("unreachable")
    }

    @Test fun threeDialectsDiscoverWithGetAtTheCapturedModelsPathAndAuthHeader() {
        val cases = listOf(Triple("chat-completions", "bearer", "authorization"),
            Triple("responses", "api-key", "api-key"), Triple("messages", "x-api-key", "x-api-key"))
        for ((protocol, auth, header) in cases) Fixture().use { fixture ->
            Loopback(listOf(Reply(page(listOf("vendor/model"))))).use { server ->
                fixture.add(server, protocol, auth)
                val before = fixture.registry()
                val result = fixture.service.discover(fixture.request())
                server.await()
                val request = server.requests.single()
                assertEquals("GET", request.method); assertEquals("/v1/models", request.target)
                assertEquals(if (auth == "bearer") "Bearer fixture-discovery-key" else "fixture-discovery-key", request.headers[header])
                for (other in setOf("authorization", "x-api-key", "api-key") - header) assertFalse(request.headers.containsKey(other))
                if (protocol == "messages") assertEquals("2023-06-01", request.headers["anthropic-version"])
                assertEquals(fixture.id, result.getString("id")); assertEquals(1, result.getInt("schema_version"))
                assertEquals(fixture.operation, result.getString("operation_id"))
                assertEquals(listOf("vendor/model"), wires(result)); assertFalse(result.getBoolean("truncated"))
                assertEquals("Name vendor/model", result.getJSONArray("models").getJSONObject(0).getString("name"))
                assertTrue(result.getJSONArray("models").getJSONObject(0).getBoolean("supports_images"))
                assertEquals(before, fixture.registry()); assertEquals(0, fixture.transport.activeRequestCount())
            }
        }
    }

    @Test fun noAuthDiscoveryNeverBorrowsABuiltinCredential() = Fixture().use { fixture ->
        Loopback(listOf(Reply(page(listOf("no-key-model"))))).use { server ->
            fixture.add(server, "responses", "none")
            fixture.credentials.put("OPENAI_API_KEY", "builtin-secret-must-not-travel")
            fixture.service.discover(fixture.request()); server.await()
            val headers = server.requests.single().headers
            assertFalse(headers.containsKey("authorization")); assertFalse(headers.containsKey("x-api-key")); assertFalse(headers.containsKey("api-key"))
            assertFalse(headers.values.any { it.contains("builtin-secret-must-not-travel") })
        }
    }

    @Test fun paginationEncodesTheOpaqueCursorStaysOnOriginAndDeduplicatesAcrossPages() = Fixture().use { fixture ->
        val cursor = "opaque/?a=1&b=2#fragment"
        val first = JSONObject(page(listOf("one", cursor), more = true))
            .put("next", "http://127.0.0.1:9/remote?secret=must-not-follow")
            .put("next_url", "https://external.invalid/models").toString()
        Loopback(listOf(Reply(first), Reply(page(listOf(cursor, "two"))))).use { server ->
            fixture.add(server)
            val before = fixture.registry()
            val result = fixture.service.discover(fixture.request()); server.await()
            assertEquals(listOf("one", cursor, "two"), wires(result))
            assertEquals(2, server.requests.size)
            val second = server.url(server.requests[1].target).toHttpUrl()
            assertEquals("/v1/models", second.encodedPath)
            assertEquals(setOf("after_id"), second.queryParameterNames)
            assertEquals(cursor, second.queryParameter("after_id")); assertNull(second.fragment)
            assertEquals(server.socket.localPort, second.port)
            assertEquals(before, fixture.registry())
        }
    }

    @Test fun anEntirelyRetiredPageStillAdvancesToNestedImageCapabilityModels() = Fixture().use { fixture ->
        val retired = JSONObject().put("data", JSONArray().put(JSONObject().put("id", "retired-cursor").put("lifecycle", "retired")))
            .put("has_more", true).put("last_id", "retired-cursor")
        val active = JSONObject().put("data", JSONArray().put(JSONObject().put("id", "active-image")
            .put("display_name", "x".repeat(200)).put("capabilities", JSONObject().put("image_input", JSONObject().put("supported", true)))))
            .put("has_more", false)
        Loopback(listOf(Reply(retired.toString()), Reply(active.toString()))).use { server ->
            fixture.add(server)
            val before = fixture.registry()
            val result = fixture.service.discover(fixture.request()); server.await()
            assertEquals(listOf("active-image"), wires(result)); assertEquals(2, server.requests.size)
            assertEquals("retired-cursor", server.url(server.requests[1].target).toHttpUrl().queryParameter("after_id"))
            val model = result.getJSONArray("models").getJSONObject(0)
            assertEquals("active-image", model.getString("name")); assertTrue(model.getBoolean("supports_images"))
            assertEquals(before, fixture.registry())
        }
    }

    @Test fun nonMessageDialectsIgnorePaginationUrlsAndFlags() = Fixture().use { fixture ->
        val response = JSONObject(page(listOf("single"), more = true)).put("next", "http://127.0.0.1:9/never").toString()
        Loopback(listOf(Reply(response))).use { server ->
            fixture.add(server, "responses", "bearer")
            assertEquals(listOf("single"), wires(fixture.service.discover(fixture.request())))
            server.await(); assertEquals(1, server.requests.size)
        }
    }

    @Test fun unsupportedFullPathsAndStaleProfilesAreRefusedBeforeAnyRequest() = Fixture().use { fixture ->
        Loopback(emptyList()).use { server ->
            fixture.add(server)
            val oldRequest = fixture.request()
            val provider = fixture.configurations.custom.provider(fixture.id)
            provider.getJSONObject("configuration").put("endpoint_url", server.url("/bespoke/generate"))
            fixture.service.save(JSONObject().put("schema_version", 1).put("expected_revision", 1).put("provider", provider))
            val before = fixture.registry()
            refused("E_PROVIDER_MODEL_DISCOVERY_UNSUPPORTED") { fixture.service.discover(fixture.request()) }
            refused("E_PROVIDER_CONFIGURATION_CHANGED") { fixture.service.discover(oldRequest) }
            assertEquals(before, fixture.registry()); assertEquals(0, fixture.transport.activeRequestCount())
            assertEquals(0, server.requests.size)
        }
    }

    @Test fun failuresAreBoundedAndNeverExposeTheResponseBody() {
        val marker = "private-provider-response-marker"
        val cases = listOf(
            Reply(marker, 401) to "E_PROVIDER_MODEL_DISCOVERY_AUTH",
            Reply(marker, 403) to "E_PROVIDER_MODEL_DISCOVERY_AUTH",
            Reply(marker, 429) to "E_PROVIDER_MODEL_DISCOVERY_HTTP",
            Reply(marker, 302) to "E_PROVIDER_MODEL_DISCOVERY_REDIRECT",
            Reply(marker, 500) to "E_PROVIDER_MODEL_DISCOVERY_HTTP",
            Reply("{bad-json:$marker") to "E_PROVIDER_MODEL_DISCOVERY_INVALID",
            Reply(JSONObject().put("data", JSONArray().put(JSONObject().put("id", "duplicate")).put(JSONObject().put("id", "duplicate"))).toString()) to "E_PROVIDER_MODEL_DISCOVERY_INVALID",
            Reply(page((0..512).map { "oversized-$it" })) to "E_PROVIDER_MODEL_DISCOVERY_LIMIT",
            Reply("x".repeat(1024 * 1024 + 1)) to "E_PROVIDER_MODEL_DISCOVERY_LIMIT",
        )
        for ((reply, code) in cases) Fixture().use { fixture ->
            Loopback(listOf(reply)).use { server ->
                fixture.add(server)
                val before = fixture.registry()
                val failure = refused(code) { fixture.service.discover(fixture.request()) }
                server.await(allowDisconnect = true)
                assertFalse(failure.toString().contains(marker))
                assertFalse(failure.toString().contains("fixture-discovery-key"))
                assertEquals(before, fixture.registry()); assertEquals(0, fixture.transport.activeRequestCount())
            }
        }
    }

    @Test fun repeatedPaginationCursorIsRejectedWithoutAThirdRequest() = Fixture().use { fixture ->
        Loopback(listOf(Reply(page(listOf("same-cursor"), true)), Reply(page(listOf("same-cursor"), true)))).use { server ->
            fixture.add(server)
            val before = fixture.registry()
            refused("E_PROVIDER_MODEL_DISCOVERY_INVALID") { fixture.service.discover(fixture.request()) }
            server.await(); assertEquals(2, server.requests.size)
            assertEquals(before, fixture.registry()); assertEquals(0, fixture.transport.activeRequestCount())
        }
    }

    @Test fun theResponseBudgetAppliesAcrossPages() = Fixture().use { fixture ->
        Loopback((1..5).map { Reply(page(listOf("page-$it"), more = it < 5, padding = 900000)) }).use { server ->
            fixture.add(server)
            val before = fixture.registry()
            refused("E_PROVIDER_MODEL_DISCOVERY_LIMIT") { fixture.service.discover(fixture.request()) }
            server.await(allowDisconnect = true)
            assertEquals(before, fixture.registry()); assertEquals(0, fixture.transport.activeRequestCount())
        }
    }

    @Test fun pageAndUniqueModelCapsReturnExplicitlyTruncatedResults() {
        Fixture().use { fixture ->
            Loopback((1..8).map { Reply(page(listOf("page-$it"), more = true)) }).use { server ->
                fixture.add(server)
                val result = fixture.service.discover(fixture.request()); server.await()
                assertEquals(8, server.requests.size); assertEquals(8, wires(result).size); assertTrue(result.getBoolean("truncated"))
            }
        }
        Fixture().use { fixture ->
            Loopback(listOf(Reply(page((0 until 300).map { "model-$it" }, true)),
                Reply(page((300 until 600).map { "model-$it" })))).use { server ->
                fixture.add(server)
                val result = fixture.service.discover(fixture.request()); server.await()
                assertEquals(512, wires(result).size); assertEquals("model-511", wires(result).last()); assertTrue(result.getBoolean("truncated"))
            }
        }
    }

    @Test fun discoveryReservationBlocksEveryMetadataAndCredentialMutation() = Fixture().use { fixture ->
        val release = CountDownLatch(1)
        Loopback(listOf(Reply(page(listOf("model")), release = release))).use { server ->
            fixture.add(server)
            val scope = fixture.service.credentialScope(fixture.credentialRequest())
            val before = fixture.registry()
            val executor = Executors.newSingleThreadExecutor()
            try {
                val future = executor.submit(Callable { fixture.service.discover(fixture.request()) })
                server.received(); assertEquals(1, fixture.transport.activeRequestCount())
                refused("E_COMPLETION_BUSY") { fixture.service.save(JSONObject().put("schema_version", 1).put("expected_revision", 1)
                    .put("provider", fixture.configurations.custom.provider(fixture.id))) }
                refused("E_COMPLETION_BUSY") { fixture.service.remove(JSONObject().put("schema_version", 1).put("expected_revision", 1).put("id", fixture.id)) }
                refused("E_COMPLETION_BUSY") { fixture.service.put(scope, "replacement-fixture-key") }
                refused("E_COMPLETION_BUSY") { fixture.service.clear(fixture.credentialRequest()) }
                release.countDown(); assertEquals(listOf("model"), wires(future.get(15, TimeUnit.SECONDS)))
                server.await(); assertEquals(before, fixture.registry()); assertEquals(0, fixture.transport.activeRequestCount())
            } finally { release.countDown(); executor.shutdownNow() }
        }
    }

    @Test fun profileAndKeyChangesDuringDiscoveryCannotPublishStaleResults() {
        for (change in listOf("profile", "key", "transport-revision")) Fixture().use { fixture ->
            val release = CountDownLatch(1)
            Loopback(listOf(Reply(page(listOf("stale-result")), release = release))).use { server ->
                fixture.add(server)
                val scope = fixture.service.credentialScope(fixture.credentialRequest())
                val executor = Executors.newSingleThreadExecutor()
                try {
                    val future = executor.submit(Callable { fixture.service.discover(fixture.request()) })
                    server.received()
                    // Bypass the public guard to reproduce stale persisted or
                    // credential state restored by another native owner.
                    when (change) {
                        "profile" -> {
                            val provider = fixture.configurations.custom.provider(fixture.id)
                            provider.getJSONObject("configuration").put("endpoint_url", server.url("/changed/messages"))
                            fixture.configurations.custom.save(1, provider)
                        }
                        "key" -> fixture.credentials.put(scope.account!!, "rotated-fixture-key")
                        else -> fixture.transport.mutate { Unit }
                    }
                    release.countDown()
                    try { future.get(15, TimeUnit.SECONDS); fail("$change published stale discovery") }
                    catch (failure: ExecutionException) {
                        val cause = failure.cause as? RuntimeFailure ?: throw AssertionError(failure)
                        assertEquals("E_PROVIDER_CONFIGURATION_CHANGED", cause.code)
                        assertFalse(cause.toString().contains("stale-result"))
                    }
                    server.await(allowDisconnect = true); assertEquals(0, fixture.transport.activeRequestCount())
                } finally { release.countDown(); executor.shutdownNow() }
            }
        }
    }

    private fun assertCancellation(result: JSONObject, id: String, operation: String, status: String) {
        assertEquals(1, result.getInt("schema_version"))
        assertEquals(id, result.getString("id"))
        assertEquals(operation, result.getString("operation_id"))
        assertEquals(status, result.getString("status"))
    }

    @Test fun cancellationOnlyAffectsTheExactProviderAndOperationPair() = Fixture().use { fixture ->
        val release = CountDownLatch(1)
        Loopback(listOf(Reply(page(listOf("cancelled-result")), release = release))).use { server ->
            fixture.add(server)
            val before = fixture.registry()
            val executor = Executors.newSingleThreadExecutor()
            try {
                val future = executor.submit(Callable { fixture.service.discover(fixture.request()) })
                server.received()
                val otherProvider = uuid()
                val otherOperation = uuid()
                assertCancellation(fixture.service.cancelDiscovery(fixture.cancelRequest(providerId = otherProvider)),
                    otherProvider, fixture.operation, "idle")
                assertCancellation(fixture.service.cancelDiscovery(fixture.cancelRequest(operationId = otherOperation)),
                    fixture.id, otherOperation, "idle")
                assertFalse(future.isDone); assertEquals(1, fixture.transport.activeRequestCount())
                assertCancellation(fixture.service.cancelDiscovery(fixture.cancelRequest()), fixture.id, fixture.operation, "cancelled")
                try { future.get(15, TimeUnit.SECONDS); fail("cancelled discovery published a result") }
                catch (failure: ExecutionException) {
                    val cause = failure.cause as? RuntimeFailure ?: throw AssertionError(failure)
                    assertEquals("E_PROVIDER_MODEL_DISCOVERY_CANCELLED", cause.code)
                }
                assertEquals(0, fixture.transport.activeRequestCount())
                assertCancellation(fixture.service.cancelDiscovery(fixture.cancelRequest()), fixture.id, fixture.operation, "idle")
                assertEquals(before, fixture.registry())
                release.countDown(); server.await(allowDisconnect = true)
            } finally { release.countDown(); executor.shutdownNow() }
        }
    }

    @Test fun anOldOperationCannotCancelTheNextDiscoveryForTheSameProvider() = Fixture().use { fixture ->
        val release = CountDownLatch(1)
        Loopback(listOf(Reply(page(listOf("first-result"))), Reply(page(listOf("next-result")), release = release))).use { server ->
            fixture.add(server)
            val before = fixture.registry()
            val first = fixture.service.discover(fixture.request())
            assertEquals(fixture.operation, first.getString("operation_id"))
            val nextOperation = uuid()
            val executor = Executors.newSingleThreadExecutor()
            try {
                val next = executor.submit(Callable { fixture.service.discover(fixture.request(nextOperation)) })
                server.received(1)
                assertCancellation(fixture.service.cancelDiscovery(fixture.cancelRequest()), fixture.id, fixture.operation, "idle")
                assertFalse(next.isDone); assertEquals(1, fixture.transport.activeRequestCount())
                release.countDown()
                val result = next.get(15, TimeUnit.SECONDS)
                assertEquals(nextOperation, result.getString("operation_id"))
                assertEquals(listOf("next-result"), wires(result))
                server.await(); assertEquals(0, fixture.transport.activeRequestCount()); assertEquals(before, fixture.registry())
            } finally { release.countDown(); executor.shutdownNow() }
        }
    }

    @Test fun escapedCredentialsEchoedInModelIdsOrNamesAreRejectedBeforePublication() {
        val secret = "fixture-discovery-key"
        val escaped = secret.map { "\\u%04x".format(it.code) }.joinToString("")
        val bodies = listOf(
            "{\"data\":[{\"id\":\"$escaped\",\"display_name\":\"Model\"}],\"has_more\":false}",
            "{\"data\":[{\"id\":\"safe-model\",\"display_name\":\"prefix-$escaped-suffix\"}],\"has_more\":false}",
        )
        for (body in bodies) Fixture().use { fixture ->
            assertFalse("fixture should exercise decoded JSON, not raw substring matching", body.contains(secret))
            Loopback(listOf(Reply(body))).use { server ->
                fixture.add(server)
                val before = fixture.registry()
                val failure = refused("E_PROVIDER_MODEL_DISCOVERY_INVALID") { fixture.service.discover(fixture.request()) }
                server.await()
                assertFalse(failure.toString().contains(secret)); assertFalse(failure.toString().contains(escaped))
                assertEquals(before, fixture.registry()); assertEquals(0, fixture.transport.activeRequestCount())
            }
        }
    }

    @Test fun retiredCredentialEchoCannotBecomeAPaginationUrlButNoAuthMarkersRemainOrdinaryIds() {
        val marker = "fixture-discovery-key"
        val retired = JSONObject().put("data", JSONArray().put(JSONObject().put("id", marker).put("lifecycle", "retired")))
            .put("has_more", true).put("last_id", marker).toString()
        Fixture().use { fixture ->
            Loopback(listOf(Reply(retired))).use { server ->
                fixture.add(server)
                val before = fixture.registry()
                val failure = refused("E_PROVIDER_MODEL_DISCOVERY_INVALID") { fixture.service.discover(fixture.request()) }
                server.await(); assertEquals(1, server.requests.size)
                assertFalse(server.requests.single().target.contains(marker)); assertFalse(failure.toString().contains(marker))
                assertEquals(before, fixture.registry()); assertEquals(0, fixture.transport.activeRequestCount())
            }
        }
        Fixture().use { fixture ->
            Loopback(listOf(Reply(retired), Reply(page(listOf("public-model"))))).use { server ->
                fixture.add(server, auth = "none")
                val result = fixture.service.discover(fixture.request()); server.await()
                assertEquals(listOf("public-model"), wires(result)); assertEquals(2, server.requests.size)
                assertEquals(marker, server.url(server.requests[1].target).toHttpUrl().queryParameter("after_id"))
                assertFalse(server.requests.any { "x-api-key" in it.headers || "authorization" in it.headers || "api-key" in it.headers })
            }
        }
    }

    @Test fun missingNativeCredentialIsRefusedBeforeAnySocketRequest() = Fixture().use { fixture ->
        Loopback(emptyList()).use { server ->
            fixture.add(server)
            fixture.service.clear(fixture.credentialRequest())
            refused("E_PROVIDER_MODEL_DISCOVERY_CREDENTIAL") { fixture.service.discover(fixture.request()) }
            assertEquals(0, server.requests.size); assertEquals(0, fixture.transport.activeRequestCount())
        }
    }

}
