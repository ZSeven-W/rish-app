package tech.zseven.rish.runtime

import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.util.concurrent.TimeUnit

/** Read-only native discovery. Endpoint and response policy belong to the shared core. */
internal class AndroidProviderModelDiscovery(
    private val configurations: AndroidProviderConfiguration,
    private val transport: AndroidModelTransport,
    private val credentials: AndroidCredentialStore,
) {
    companion object {
        private const val MAX_PAGES = 8
        private const val MAX_MODELS = 512
        private const val MAX_PAGE_BYTES = 1024 * 1024
        private const val MAX_TOTAL_BYTES = 4 * 1024 * 1024
        private const val DEADLINE_MS = 60_000L
        private val client = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false)
            .retryOnConnectionFailure(false).connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(15, TimeUnit.SECONDS).callTimeout(20, TimeUnit.SECONDS).build()
    }
    private class Captured(val id: String, val operationId: String, val configuration: JSONObject, val account: String?, val secret: String?,
        val endpoint: HttpUrl, val reservation: AndroidModelTransport.Discovery, val builtin: Boolean = false,
        val catalog: JSONObject? = null)

    class Prepared internal constructor(
        private val executeCaptured: () -> JSONObject,
        private val release: () -> Unit,
    ) {
        fun execute(): JSONObject = try { executeCaptured() } finally { discard() }
        fun discard() = release()
    }

    private fun fail(code: String): Nothing = throw RuntimeFailure(code)
    private fun policy(request: JSONObject): Any = try { AndroidProviderConfiguration.policy(request) }
        catch (failure: IllegalArgumentException) {
            val code = failure.message
            fail(if (code in setOf("E_PROVIDER_MODEL_DISCOVERY_INVALID", "E_PROVIDER_MODEL_DISCOVERY_UNSUPPORTED", "E_PROVIDER_MODEL_DISCOVERY_LIMIT"))
                code!! else "E_PROVIDER_MODEL_DISCOVERY_INVALID")
        }
    private fun account(config: JSONObject): String? = AndroidProviderConfiguration.policy(JSONObject()
        .put("op", "credential_account").put("slot", AndroidProviderConfiguration.slot(config.getString("harness_id")))
        .put("configuration", config)) as? String
    private fun secret(account: String?): String? {
        if (account == null) return null
        return try { credentials.get(account) ?: fail("E_PROVIDER_MODEL_DISCOVERY_CREDENTIAL") }
            catch (failure: RuntimeFailure) { throw failure }
            catch (_: Exception) { fail("E_PROVIDER_MODEL_DISCOVERY_CREDENTIAL") }
    }
    fun prepare(request: JSONObject): Prepared {
        if (request.opt("schema_version") != 1 || request.keys().asSequence().toSet() !=
            setOf("schema_version", "id", "operation_id", "expected_profile") || !RuntimeJson.uuid(request.optString("id")) ||
            !RuntimeJson.uuid(request.optString("operation_id")) || request.opt("expected_profile") !is JSONObject) fail("E_PROVIDER_MODEL_DISCOVERY_INVALID")
        val id = request.getString("id")
        val operation = request.getString("operation_id")
        val reservation = transport.reserveDiscovery(id, operation)
        return prepared(reservation) {
            val config = try { configurations.custom.provider(id).getJSONObject("configuration") }
                catch (_: Exception) { fail("E_PROVIDER_CONFIGURATION_CHANGED") }
            capture(request, id, config, reservation)
        }
    }

    fun prepareBuiltin(request: JSONObject, persistedGuard: () -> Unit): Prepared {
        if (request.opt("schema_version") != 1 || request.keys().asSequence().toSet() !=
            setOf("schema_version", "harness_id", "operation_id", "expected_profile") ||
            request.opt("harness_id") !is String || request.getString("harness_id") !in AndroidProviderModelCatalog.harnesses ||
            !RuntimeJson.uuid(request.optString("operation_id")) || request.opt("expected_profile") !is JSONObject)
            fail("E_PROVIDER_MODEL_DISCOVERY_INVALID")
        val harness = request.getString("harness_id")
        val operation = request.getString("operation_id")
        val reservation = transport.whenIdle { transport.reserveDiscovery("builtin:$harness", operation) }
        return prepared(reservation) {
            persistedGuard()
            capture(request, harness, configurations.read(harness), reservation, configurations.providerModels.read())
        }
    }

    private fun prepared(reservation: AndroidModelTransport.Discovery, capture: () -> Captured): Prepared =
        Prepared(
            {
                var captured: Captured? = null
                val result = try {
                    val input = transport.withDiscovery(reservation, capture)
                    captured = input
                    Result.success(execute(input))
                } catch (failure: Exception) {
                    Result.failure(failure)
                }
                transport.finishDiscovery(reservation) {
                    // A refusal also belongs to the captured profile.
                    captured?.let(::verify)
                    result.getOrThrow()
                }
            },
            { transport.releaseDiscovery(reservation) },
        )

    private fun capture(
        request: JSONObject,
        id: String,
        config: JSONObject,
        reservation: AndroidModelTransport.Discovery,
        catalog: JSONObject? = null,
    ): Captured {
        if (!AndroidJson.equal(config, request.getJSONObject("expected_profile"))) fail("E_PROVIDER_CONFIGURATION_CHANGED")
        val url = config.getString("endpoint_url").toHttpUrlOrNull() ?: fail("E_PROVIDER_MODEL_DISCOVERY_UNSUPPORTED")
        val path = policy(JSONObject().put("op", "models_endpoint_path").put("path", url.encodedPath)
            .put("protocol", config.getString("protocol"))) as String
        val endpoint = url.newBuilder().encodedPath(path).query(null).fragment(null).build()
        val account = account(config)
        // Explicit API provider discovery reads only the encrypted API-key
        // account. Subscription/CLI credentials are never borrowed here.
        return Captured(id, reservation.operationId, config, account, secret(account), endpoint, reservation, catalog != null, catalog)
    }
    private fun verify(captured: Captured) {
        val current = try { if (captured.builtin) configurations.read(captured.id)
            else configurations.custom.provider(captured.id).getJSONObject("configuration") }
            catch (_: Exception) { fail("E_PROVIDER_CONFIGURATION_CHANGED") }
        if (!AndroidJson.equal(current, captured.configuration) || account(current) != captured.account) fail("E_PROVIDER_CONFIGURATION_CHANGED")
        if (captured.builtin && !AndroidJson.equal(configurations.providerModels.read(), captured.catalog))
            fail("E_PROVIDER_CONFIGURATION_CHANGED")
        // Rotation at the same URL/account is still a changed credential. This
        // also catches direct native-store changes outside the guarded UI API.
        val currentSecret = try { captured.account?.let { credentials.get(it) } }
            catch (_: Exception) { fail("E_PROVIDER_CONFIGURATION_CHANGED") }
        if (currentSecret != captured.secret) fail("E_PROVIDER_CONFIGURATION_CHANGED")
    }
    private fun rejectCredentialEcho(captured: Captured, values: List<String>) {
        val secret = captured.secret ?: return
        if (values.any { it == secret || secret.length >= 8 && it.contains(secret) }) {
            fail("E_PROVIDER_MODEL_DISCOVERY_INVALID")
        }
    }
    private fun body(response: okhttp3.Response, remainingBytes: Int): ByteArray {
        val stream = response.body ?: fail("E_PROVIDER_MODEL_DISCOVERY_INVALID")
        if (stream.contentLength() > remainingBytes) fail("E_PROVIDER_MODEL_DISCOVERY_LIMIT")
        return stream.byteStream().use { input ->
            val bytes = ByteArrayOutputStream(); val buffer = ByteArray(8192)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                if (bytes.size() + count > remainingBytes) fail("E_PROVIDER_MODEL_DISCOVERY_LIMIT")
                bytes.write(buffer, 0, count)
            }
            bytes.toByteArray()
        }
    }
    private fun execute(captured: Captured): JSONObject {
        val deadline = android.os.SystemClock.elapsedRealtime() + DEADLINE_MS
        val models = LinkedHashMap<String, JSONObject>()
        val cursors = HashSet<String>()
        var cursor: String? = null
        var totalBytes = 0
        var truncated = false
        try {
            for (page in 0 until MAX_PAGES) {
                if (totalBytes >= MAX_TOTAL_BYTES) fail("E_PROVIDER_MODEL_DISCOVERY_LIMIT")
                val call = transport.withDiscovery(captured.reservation) {
                    verify(captured)
                    val remaining = deadline - android.os.SystemClock.elapsedRealtime()
                    if (remaining <= 0) fail("E_PROVIDER_MODEL_DISCOVERY_TIMEOUT")
                    val url = captured.endpoint.newBuilder().apply { cursor?.let { addQueryParameter("after_id", it) } }.build()
                    val builder = Request.Builder().url(url).get().header("Accept", "application/json").header("User-Agent", "Rish/Android")
                    when (captured.configuration.getString("auth_type")) {
                        "bearer" -> builder.header("Authorization", "Bearer ${requireNotNull(captured.secret)}")
                        "x-api-key" -> builder.header("x-api-key", requireNotNull(captured.secret))
                        "api-key" -> builder.header("api-key", requireNotNull(captured.secret))
                        "none" -> Unit
                        else -> fail("E_PROVIDER_MODEL_DISCOVERY_INVALID")
                    }
                    if (captured.configuration.getString("protocol") == "messages") builder.header("anthropic-version", "2023-06-01")
                    client.newCall(builder.build()).also {
                        it.timeout().timeout(minOf(remaining, 20_000), TimeUnit.MILLISECONDS)
                        captured.reservation.call = it
                    }
                }
                val bytes = call.execute().use { response ->
                    when {
                        response.code in 300..399 -> fail("E_PROVIDER_MODEL_DISCOVERY_REDIRECT")
                        response.code == 401 || response.code == 403 -> fail("E_PROVIDER_MODEL_DISCOVERY_AUTH")
                        response.code == 429 -> fail("E_PROVIDER_MODEL_DISCOVERY_HTTP")
                        !response.isSuccessful -> fail("E_PROVIDER_MODEL_DISCOVERY_HTTP")
                    }
                    body(response, minOf(MAX_PAGE_BYTES, MAX_TOTAL_BYTES - totalBytes))
                }
                totalBytes += bytes.size
                val text = try { Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString() }
                    catch (_: Exception) { fail("E_PROVIDER_MODEL_DISCOVERY_INVALID") }
                val parsed = policy(JSONObject().put("op", "models_parse_page").put("protocol", captured.configuration.getString("protocol"))
                    .put("response_body", text)) as JSONObject
                transport.withDiscovery(captured.reservation) { verify(captured) }
                // A retired row can be omitted from models while still naming
                // the next cursor. Never copy a vault secret into a URL.
                (parsed.opt("last_id") as? String)?.let { rejectCredentialEcho(captured, listOf(it)) }
                val rows = parsed.getJSONArray("models")
                for (index in 0 until rows.length()) {
                    val model = rows.getJSONObject(index)
                    val id = model.getString("wire_model")
                    rejectCredentialEcho(captured, listOf(id, model.getString("name")))
                    if (id in models) continue
                    if (models.size == MAX_MODELS) { truncated = true; break }
                    models[id] = model
                }
                if (truncated || !parsed.getBoolean("has_more")) break
                if (models.size == MAX_MODELS || page + 1 == MAX_PAGES) { truncated = true; break }
                cursor = parsed.getString("last_id")
                if (!cursors.add(cursor!!)) fail("E_PROVIDER_MODEL_DISCOVERY_INVALID")
            }
            return JSONObject().put("schema_version", 1).put(if (captured.builtin) "harness_id" else "id", captured.id).put("operation_id", captured.operationId)
                .put("models", JSONArray(models.values.toList())).put("truncated", truncated)
        } catch (failure: Exception) {
            if (failure is RuntimeFailure) throw failure
            fail(if (failure is java.net.SocketTimeoutException || failure is java.io.InterruptedIOException)
                "E_PROVIDER_MODEL_DISCOVERY_TIMEOUT" else "E_PROVIDER_MODEL_DISCOVERY_TRANSPORT")
        }
    }
}
