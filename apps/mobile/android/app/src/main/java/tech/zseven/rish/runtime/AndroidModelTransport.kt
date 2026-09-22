package tech.zseven.rish.runtime

import okhttp3.Call
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.UUID
import java.util.concurrent.TimeUnit

internal class RuntimeFailure(val code: String, val httpStatus: Int? = null) : Exception(code)
internal class AndroidModelTransport(private val credentials: AndroidCredentialStore, val configurations: AndroidProviderConfiguration) {
    private val lock = Any()
    private var revision = 0L
    private val active = mutableMapOf<String, Prepared>()
    private val client = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false)
        .retryOnConnectionFailure(false).connectTimeout(20, TimeUnit.SECONDS).readTimeout(120, TimeUnit.SECONDS).callTimeout(150, TimeUnit.SECONDS).build()
    @Volatile var sentRequestCount = 0
        private set
    fun activeRequestCount(): Int = synchronized(lock) { active.size }
    @Volatile var lastProof: JSONObject? = null
        private set
    @Volatile var lastModel: String? = null
        private set
    class Prepared(val input: JSONObject, val id: String, val model: String, val harness: String,
        val configuration: JSONObject, val account: String, val revision: Long) {
        var call: Call? = null
        var cancelled = false
    }
    private fun fail(code: String): Nothing = throw RuntimeFailure(code)
    fun prepare(text: String): Prepared = synchronized(lock) {
        if (text.toByteArray().size > 4 * 1024 * 1024) fail("E_COMPLETION_BODY_TOO_LARGE")
        val input = try { JSONObject(text) } catch (_: Exception) { fail("E_COMPLETION_BODY_INVALID") }
        val schema = input.opt("schema_version")
        if (schema !is Int || schema !in 1..2) fail("E_COMPLETION_CONTEXT_UNSUPPORTED")
        val model = input.getString("model"); val harness = AndroidProviderConfiguration.harness(model)
        if (schema == 2 && input.getString("harness_id") != harness) fail("E_COMPLETION_MODEL_MISMATCH")
        val id = input.getString(if(schema == 2) "round_id" else "request_id")
        if (!RuntimeJson.uuid(id)) fail("E_COMPLETION_IDENTIFIER")
        if (input.getString("thinking_mode") !in setOf("off", "high", "max")) fail("E_COMPLETION_THINKING")
        // Tools travel now. Bounded here rather than trusted: the round decides
        // which tools exist, and this only refuses a list no provider would
        // accept anyway.
        val toolCount = input.optJSONArray("tools")?.length() ?: 0
        if (toolCount > 64) fail("E_COMPLETION_CONTEXT_UNSUPPORTED")
        if (schema == 2) {
            // The verified project context, when the round carries one: the
            // system messages the core's context_bundle released, already
            // checked. Bounded here rather than trusted.
            if (!input.isNull("project_context")) {
                val context = input.optJSONArray("project_context") ?: fail("E_COMPLETION_CONTEXT_UNSUPPORTED")
                if (context.length() !in 1..32) fail("E_COMPLETION_CONTEXT_UNSUPPORTED")
                for (index in 0 until context.length()) {
                    val message = context.optJSONObject(index) ?: fail("E_COMPLETION_CONTEXT_UNSUPPORTED")
                    if (message.optString("role") != "system" || message.opt("content") !is String) fail("E_COMPLETION_CONTEXT_UNSUPPORTED")
                }
            }
            // The round transcript is judged in execute, where the protocol is
            // known: only chat-completions can carry one.
            if ((input.optJSONArray("round_transcript")?.length() ?: 0) > 64) fail("E_COMPLETION_CONTEXT_UNSUPPORTED")
            if (!RuntimeJson.uuid(input.getString("turn_id")) || !RuntimeJson.uuid(input.getString("attempt_id"))) fail("E_COMPLETION_IDENTIFIER")
            if (input.opt("round_index") !is Int || input.getInt("round_index") !in 0..7) fail("E_COMPLETION_ROUND")
        }
        if (active.size >= 4 || active.containsKey(id)) fail("E_COMPLETION_BUSY")
        val config = configurations.forModel(model)
        val account = migratedAccount(AndroidProviderConfiguration.slot(harness))
        Prepared(input, id, model, harness, config, account, revision).also { active[id] = it }
    }
    fun cancel(id: String): String = synchronized(lock) {
        val request = active[id] ?: return@synchronized "idle"
        request.cancelled = true; request.call?.cancel(); "cancelled"
    }
    fun <T> whenIdle(change: () -> T): T = synchronized(lock) {
        if (active.isNotEmpty()) fail("E_COMPLETION_BUSY")
        change()
    }
    fun <T> mutate(change: () -> T): T = synchronized(lock) {
        revision += 1
        active.values.forEach { it.cancelled = true; it.call?.cancel() }
        change()
    }
    private fun migratedAccount(slot: String): String {
        val current = configurations.effectiveAccount(slot)
        credentials.migrateAccount(configurations.previousAccount(slot), current)
        return current
    }
    fun account(slot: String): String = synchronized(lock) { configurations.effectiveAccount(slot) }
    fun configured(slot: String): Boolean = synchronized(lock) { credentials.configured(migratedAccount(slot)) }
    fun put(slot: String, expectedAccount: String, secret: String) = mutate {
        if (expectedAccount != configurations.effectiveAccount(slot)) fail("E_COMPLETION_CREDENTIAL_CHANGED")
        credentials.put(expectedAccount, secret)
        credentials.migrateAccount(configurations.previousAccount(slot), expectedAccount)
    }
    fun clear(slot: String) = mutate { credentials.clearAccounts(configurations.effectiveAccount(slot), configurations.previousAccount(slot)) }
    private fun own(request: Prepared) {
        if (active[request.id] !== request) fail("E_COMPLETION_CANCELLED")
        if (request.revision != revision || request.account != configurations.effectiveAccount(AndroidProviderConfiguration.slot(request.harness))) fail("E_COMPLETION_CREDENTIAL_CHANGED")
        if (request.cancelled) fail("E_COMPLETION_CANCELLED")
    }
    /**
     * A tool as the chat-completions protocol spells one. The name, the
     * description and the schema are the registry's; the wrapper around them
     * is this protocol's, and that is the only part this file decides.
     */
    /**
     * The chat-completions wrapper, reachable from a test. It is the one part
     * of a tool's trip to the model this platform decides, and the two lines
     * that used to refuse tools entirely are the reason it is worth seeing
     * directly rather than only through a network call.
     */
    internal fun functionToolsForTest(declared: JSONArray): JSONArray = functionTools(declared)

    /**
     * One round-transcript entry as a provider message.
     *
     * The core has already shaped these -- an assistant turn with its
     * `tool_calls`, or a `tool` result against a call id. What is dropped here
     * is only the nulls: a provider sent `"content": null` beside tool calls,
     * or a null `reasoning_content`, rejects the whole request.
     */
    private fun roundMessage(entry: JSONObject): JSONObject {
        val message = JSONObject()
        for (key in entry.keys()) {
            val value = entry.opt(key)
            if (value == null || value == JSONObject.NULL) continue
            if (value is JSONArray && value.length() == 0) continue
            message.put(key, value)
        }
        if (!message.has("content")) message.put("content", "")
        return message
    }

    /**
     * What a provider's reply says, in the one vocabulary every dialect
     * reduces to.
     *
     * The other two dialects come from the shared core, which is where the
     * reading of a tool call and of a reasoning summary lives. This host
     * refused Anthropic's tool_use blocks outright and read no reasoning at
     * all from a responses reply, so those two dialects could neither send a
     * tool nor hear about one. chat-completions stays here for now: its
     * reply is the shape everything else is assembled into, and the core
     * parses it on a separate path.
     */
    internal fun parseResponse(protocol: String, response: JSONObject): JSONObject {
        if (protocol != "chat-completions") return readReply(protocol, response)
        val choice = response.getJSONArray("choices").getJSONObject(0)
        val message = choice.getJSONObject("message")
        val calls = JSONArray()
        // The calls the model asked for, carried back as the provider stated
        // them. What they *mean* -- whether the name is a tool, whether the
        // arguments parse, what may run -- stays the core's.
        val raw = message.optJSONArray("tool_calls") ?: JSONArray()
        for (index in 0 until raw.length()) {
            val call = raw.optJSONObject(index) ?: continue
            val function = call.optJSONObject("function") ?: continue
            calls.put(
                JSONObject().put("id", call.optString("id"))
                    .put("name", function.optString("name"))
                    .put("arguments", function.optString("arguments")),
            )
        }
        return JSONObject().put("text", stringOrEmpty(message, "content"))
            .put("reasoning", stringOrEmpty(message, "reasoning_content"))
            .put("finish_reason", choice.getString("finish_reason"))
            .put("tool_calls", calls)
    }

    /** One reply, read by the shared core for the dialect that sent it. */
    private fun readReply(protocol: String, response: JSONObject): JSONObject {
        if (!RishAgentCoreNative.available) fail("E_COMPLETION_RESPONSE_JSON")
        val envelope = JSONObject().put("op", "read_reply").put("dialect", protocol)
            // The host decides whether the model that answered is the model
            // that was asked; the core records the one that was requested.
            .put("requested_model", response.optString("model", ""))
            .put("response", response)
        val reply = RishAgentCoreNative.completionResponseReduce(envelope.toString())
            ?: fail("E_COMPLETION_RESPONSE_JSON")
        val answer = try {
            JSONObject(reply)
        } catch (_: Exception) {
            fail("E_COMPLETION_RESPONSE_JSON")
        }
        if (!answer.optBoolean("ok")) {
            fail(answer.optString("failure_code").ifEmpty { "E_COMPLETION_RESPONSE_JSON" })
        }
        return answer.getJSONObject("reply")
    }

    /**
     * One round's request body, from the shared core.
     *
     * `send_reasoning` stays a host decision because it is a property of the
     * configured endpoint rather than of the round: a provider that does not
     * accept a thinking vocabulary is told the round is unthinking.
     */
    internal fun requestBody(
        protocol: String,
        wireModel: String,
        thinkingMode: String,
        sendReasoning: Boolean,
        streaming: Boolean,
        messages: JSONArray,
        tools: JSONArray,
    ): JSONObject {
        if (!RishAgentCoreNative.available) fail("E_COMPLETION_BODY_INVALID")
        val envelope = JSONObject().put("op", "request_body").put("dialect", protocol)
            .put("model", wireModel)
            .put("thinking_mode", if (sendReasoning) thinkingMode else "off")
            .put("streaming", streaming)
            .put("messages", messages).put("tools", tools)
        val reply = RishAgentCoreNative.completionResponseReduce(envelope.toString())
            ?: fail("E_COMPLETION_BODY_INVALID")
        val answer = try {
            JSONObject(reply)
        } catch (_: Exception) {
            fail("E_COMPLETION_BODY_INVALID")
        }
        if (!answer.optBoolean("ok")) {
            fail(answer.optString("failure_code").ifEmpty { "E_COMPLETION_BODY_INVALID" })
        }
        return answer.getJSONObject("body")
    }

    private fun functionTools(declared: JSONArray): JSONArray {
        val tools = JSONArray()
        for (index in 0 until declared.length()) {
            val tool = declared.optJSONObject(index) ?: continue
            tools.put(
                JSONObject().put("type", "function").put(
                    "function",
                    JSONObject()
                        .put("name", tool.optString("name"))
                        .put("description", tool.optString("description"))
                        .put("parameters", tool.opt("parameters") ?: JSONObject()),
                ),
            )
        }
        return tools
    }

    /**
     * Reads a server-sent event stream into the reply the rest of this file
     * already knows how to read.
     *
     * The parsing is not here. This hands the socket's bytes to the shared
     * core a chunk at a time and passes back whatever previews it answers
     * with; the core carries the state between calls and assembles the final
     * reply. That matters because a reader that splits the stream into lines
     * -- which is what this used to do -- cannot be asked about the cases
     * that actually break: a character cut in half by a chunk boundary, three
     * events in one read, a `data:` line delivered in pieces. iOS runs the
     * same reducer, so a stream that parses on one platform parses on both.
     *
     * `[DONE]` ends it; a stream that ends without a finish reason is a
     * truncated response, not a silent success, and the core says so.
     */
    internal fun assembleStream(
        stream: java.io.InputStream,
        thinkingMode: String = "off",
        sink: (JSONObject) -> Unit,
    ): JSONObject {
        var state: Any = JSONObject.NULL
        val buffer = ByteArray(8192)
        stream.use { source ->
            while (true) {
                val count = source.read(buffer)
                if (count < 0) break
                if (count == 0) continue
                val answer = streamReduce(
                    JSONObject().put("op", "stream_chunk").put("state", state).put(
                        "chunk_base64",
                        android.util.Base64.encodeToString(
                            buffer.copyOf(count), android.util.Base64.NO_WRAP,
                        ),
                    ),
                )
                state = answer.getJSONObject("state")
                val previews = answer.optJSONArray("previews") ?: JSONArray()
                for (index in 0 until previews.length()) {
                    previews.optJSONObject(index)?.let(sink)
                }
            }
        }
        // The thinking mode travels with the assembly: a turn that asked to
        // think reports the reasoning it got, even when that is none.
        return streamReduce(
            JSONObject().put("op", "stream_finish").put("state", state)
                .put("thinking_mode", thinkingMode),
        ).getJSONObject("response")
    }

    /**
     * One call into the core's completion reducer, with its refusal turned
     * into this file's own failure. A build without the core staged cannot
     * read a stream at all, and says that rather than half-reading one.
     */
    private fun streamReduce(request: JSONObject): JSONObject {
        if (!RishAgentCoreNative.available) fail("E_COMPLETION_RESPONSE_JSON")
        val reply = RishAgentCoreNative.completionResponseReduce(request.toString())
            ?: fail("E_COMPLETION_RESPONSE_JSON")
        val answer = try {
            JSONObject(reply)
        } catch (_: Exception) {
            fail("E_COMPLETION_RESPONSE_JSON")
        }
        if (!answer.optBoolean("ok")) {
            fail(answer.optString("failure_code").ifEmpty { "E_COMPLETION_RESPONSE_JSON" })
        }
        return answer
    }

    /**
     * Runs one prepared request.
     *
     * `sink` asks for the reply as it arrives: on chat-completions the request
     * is sent with `stream: true` and each chunk is handed over as it is
     * parsed, for display only. What the round *decides* never comes from the
     * chunks -- they are reassembled into exactly the reply shape the
     * non-streaming path produces, and everything below this point is the same
     * code reading the same object. A preview that disagreed with the settled
     * round would be worse than no preview.
     */
    /**
     * The messages this request will be sent as, and every refusal that can
     * be decided without touching the network.
     *
     * Pulled out of `execute` so a caller can learn *before* it commits to
     * having dispatched anything that the request is one this transport
     * cannot carry. An attachment it cannot deliver, a round transcript in a
     * dialect that cannot express one, a message over the size limit: none of
     * those depend on the provider, and a round stopped by one of them
     * provably never left the device. `execute` calls this too, so there is
     * one rule rather than two that can drift.
     */
    private fun composeMessages(request: Prepared): JSONArray {
        val input = request.input
        val history = input.getJSONArray(if(input.getInt("schema_version") == 2) "visible_history" else "history")
        if (history.length() !in 1..512) fail("E_COMPLETION_HISTORY")
        val messages = JSONArray()
        // The project context comes first, as iOS prepends it: what the
        // model is told about the project precedes what was said in it.
        val context = if (input.isNull("project_context")) null else input.optJSONArray("project_context")
        if (context != null) {
            for (index in 0 until context.length()) {
                val message = context.getJSONObject(index)
                messages.put(JSONObject().put("role", "system").put("content", message.getString("content")))
            }
        }
        for (index in 0 until history.length()) {
            val item = history.getJSONObject(index)
            if (item.getString("role") !in setOf("user", "assistant")) fail("E_COMPLETION_CONTEXT_UNSUPPORTED")
            // Android cannot yet put an attachment's content in front of a
            // model, on either path. Refusing is the honest answer: sending
            // the text alone would answer a question about an image the model
            // was never shown. This is the backstop, not the message the
            // person reads -- the composer refuses an undeliverable attachment
            // before a turn is ever started, because only there can the draft
            // and the attachment be kept and the reason be said plainly. The
            // code stays inside the core's closed failure set.
            if ((item.optJSONArray("attachments")?.length() ?: 0) != 0) fail("E_COMPLETION_CONTEXT_UNSUPPORTED")
            val text = item.getString("content")
            if (text.toByteArray().size > 1024 * 1024) fail("E_COMPLETION_BODY_TOO_LARGE")
            messages.put(JSONObject().put("role", item.getString("role")).put("content", text))
        }
        // What this round already did: the assistant turn that asked for a
        // tool, and the results that came back. Without it the model is
        // told nothing of the call it just made and asks for it again, so
        // a turn with a tool in it could never finish.
        val round = input.optJSONArray("round_transcript") ?: JSONArray()
        if (round.length() != 0) {
            if (request.configuration.getString("protocol") != "chat-completions") fail("E_COMPLETION_CONTEXT_UNSUPPORTED")
            for (index in 0 until round.length()) {
                messages.put(roundMessage(round.getJSONObject(index)))
            }
        }
        return messages
    }

    /**
     * Raises now whatever `execute` would raise before it sends anything.
     *
     * A prepared request holds a slot in `active` that only `execute` frees,
     * so a refusal here has to give the slot back; otherwise the next round
     * is refused as busy over a request that was never run.
     */
    fun validate(request: Prepared) {
        try {
            composeMessages(request)
        } catch (failure: Throwable) {
            discard(request)
            throw failure
        }
    }

    /**
     * Gives a prepared request's slot back without running it, for a caller
     * that prepared one and then could not go through with it.
     */
    fun discard(request: Prepared) = synchronized(lock) {
        if (active[request.id] === request) active.remove(request.id)
        Unit
    }

    fun execute(request: Prepared, sink: ((JSONObject) -> Unit)? = null): JSONObject {
        val started = android.os.SystemClock.elapsedRealtime()
        try {
            val input = request.input
            val history = input.getJSONArray(if(input.getInt("schema_version") == 2) "visible_history" else "history")
            val config = request.configuration
            val protocol = config.getString("protocol")
            val messages = composeMessages(request)
            val declared = input.optJSONArray("tools") ?: JSONArray()
            val wireModel = config.getJSONObject("model_mappings").optString(request.model, request.model)
            val streaming = sink != null && protocol == "chat-completions"
            // The body is the shared core's, for every dialect. What each one
            // asks for -- the ceiling that follows the round's shape, the
            // thinking vocabulary that follows the model family, `store`,
            // `strict`, the rewriting of turns into content blocks -- was
            // written here once per dialect and got four of them wrong.
            val body = requestBody(
                protocol, wireModel, input.getString("thinking_mode"),
                config.getBoolean("send_reasoning"), streaming,
                messages, functionTools(declared),
            )
            val encoded = RuntimeJson.receiptJson(body)
            val providerRequestId = UUID.randomUUID().toString()
            val httpCall: Call = synchronized(lock) {
                own(request)
                val secret = credentials.get(request.account) ?: fail("E_COMPLETION_CREDENTIAL_UNAVAILABLE")
                val builder = Request.Builder().url(config.getString("endpoint_url"))
                    .header("User-Agent", "Rish/Android").header("X-Client-Request-Id", providerRequestId)
                    .post(encoded.toRequestBody("application/json".toMediaType()))
                if (streaming) builder.header("Accept", "text/event-stream")
                when(config.getString("auth_type")) {
                    "bearer" -> builder.header("Authorization", "Bearer $secret")
                    "x-api-key" -> builder.header("x-api-key", secret)
                    "api-key" -> builder.header("api-key", secret)
                }
                if(protocol == "messages") builder.header("anthropic-version", "2023-06-01")
                client.newCall(builder.build()).also { request.call = it; sentRequestCount += 1 }
            }
            val response = httpCall.execute().use { http ->
                if(http.code in 300..399) fail("E_COMPLETION_REDIRECT")
                if(http.code == 429) fail("E_COMPLETION_HTTP_429")
                if(!http.isSuccessful) throw RuntimeFailure("E_COMPLETION_HTTP_STATUS", http.code)
                val stream = http.body?.byteStream() ?: fail("E_COMPLETION_RESPONSE_JSON")
                if (streaming) {
                    assembleStream(stream, input.getString("thinking_mode"), sink!!)
                } else {
                    val bytes = ByteArrayOutputStream(); val buffer = ByteArray(8192)
                    stream.use { source ->
                        while(true) { val count = source.read(buffer); if(count < 0) break
                            if(bytes.size() + count > 4 * 1024 * 1024) fail("E_COMPLETION_RESPONSE_SIZE")
                            bytes.write(buffer, 0, count)
                        }
                    }
                    try { JSONObject(bytes.toString("UTF-8")) } catch (_: Exception) { fail("E_COMPLETION_RESPONSE_JSON") }
                }
            }
            synchronized(lock) { own(request) }
            val reported = response.optString("model", "")
            val glmWire = wireModel.startsWith("glm", ignoreCase = true)
            val custom = !config.optBoolean("official")
            // DeepSeek's 2026-09-10 announcement routes these two retired
            // request ids to V4.1 Flash (deepseek-flash). Mirrors the closed
            // compatibility map in modules/rish/ios/Sources/DshProviderTransport.mm:
            // the same two ids, the same official endpoint, the same single
            // accepted alias. V4 Pro is deliberately excluded -- its announced
            // transition is later. Without this the provider's own answer is
            // refused as E_COMPLETION_RESPONSE_MODEL, for a plain chat as much
            // as for an agent round.
            val documentedLegacyAlias =
                config.getString("endpoint_url") == "https://api.deepseek.com/chat/completions" &&
                    wireModel in setOf("deepseek-v4-flash", "deepseek-v4-flash-vision-exp") &&
                    reported == "deepseek-flash"
            // A configured (third-party) provider answers under the rule iOS's
            // ConfiguredProviderTransport applies: the mapped wire model
            // exactly, a dated form of it on the Messages protocol
            // (`claude-sonnet-4-5` answered as `claude-sonnet-4-5-20250929`),
            // or no model at all off Chat Completions -- relays do all three,
            // and refusing them made every custom configuration on Android
            // fail with E_COMPLETION_RESPONSE_MODEL after the reply had
            // already arrived (2026-09-21).
            val configuredMatches = custom && AndroidConfiguredModelIdentity.matches(protocol, wireModel, response.opt("model"))
            if (!(reported == wireModel || documentedLegacyAlias || configuredMatches ||
                    (glmWire && reported.all { it.code < 128 } && reported.equals(wireModel, ignoreCase = true)))
            ) {
                fail("E_COMPLETION_RESPONSE_MODEL")
            }
            if (configuredMatches && reported != wireModel) {
                // The core reads the reply for the model that was asked; the
                // relay's spelling is what was answered, not a second model.
                response.put("model", wireModel)
                android.util.Log.i(
                    "RishRuntime",
                    "completion_model_alias harness=${request.harness} requested_model=$wireModel reported_model=${reported.ifEmpty { "(absent)" }}",
                )
            }
            if (documentedLegacyAlias) {
                // Never claim raw equality: the receipt keeps the canonical
                // requested model its schema requires, and the wire identity
                // is recorded beside it.
                response.put("model", wireModel)
                android.util.Log.i(
                    "RishRuntime",
                    "completion_model_alias harness=dsh requested_model=$wireModel reported_model=deepseek-flash",
                )
            }
            val read = parseResponse(protocol, response)
            val text = read.getString("text")
            val reasoning = read.getString("reasoning")
            val finish = read.getString("finish_reason")
            val calls = read.getJSONArray("tool_calls")
            if(finish !in setOf("stop", "length", "tool_calls")) fail("E_COMPLETION_FINISH_RELATION")
            if((finish == "tool_calls") != (calls.length() > 0)) fail("E_COMPLETION_FINISH_RELATION")
            val responseId = response.getString("id"); if(responseId.isBlank() || responseId.length > 256) fail("E_COMPLETION_PROVIDER_RESPONSE_ID")
            val result = JSONObject().put("schema_version", input.getInt("schema_version"))
                .put("text", text).put("reasoning", reasoning).put("tool_calls", calls).put("finish_reason", finish)
                .put("model", request.model).put("thinking_mode", input.getString("thinking_mode"))
                .put("latency_ms", android.os.SystemClock.elapsedRealtime() - started)
            if(input.getInt("schema_version") == 1) result.put("request_id", request.id)
            else {
                result.put("harness_id", request.harness).put("turn_id", input.getString("turn_id"))
                    .put("attempt_id", input.getString("attempt_id")).put("round_id", request.id).put("round_index", input.getInt("round_index"))
                    .put("requested_model", request.model).put("provider_request_id", providerRequestId).put("provider_response_id", responseId)
                    // Both of these are provider-input digests, so both are
                    // the receipt encoding -- the same one iOS has always
                    // written them with.
                    .put("visible_history_sha256", RuntimeJson.sha(RuntimeJson.receiptJson(history)))
                    .put("model_input_sha256", RuntimeJson.sha(RuntimeJson.receiptJson(messages)))
                    .put("request_body_sha256", RuntimeJson.sha(encoded)).put("project_context_receipt", JSONObject.NULL)
                configurations.binding(config, request.model)?.let { result.put("provider_configuration", it) }
            }
            synchronized(lock) {
                own(request); lastModel = request.model
                lastProof = JSONObject().put("proof_run_id", request.id).put("launch_instance_id", AndroidSessionStore.launchId)
                    .put("received_at", RuntimeJson.now()).put("http_status", 200).put("model", request.model).put("requested_model", request.model)
                    .put("thinking_mode", input.getString("thinking_mode")).put("finish_reason", finish).put("response_id", responseId)
                    .put("assistant_text_sha256", RuntimeJson.sha(text)).put("reasoning_text_sha256", RuntimeJson.sha(reasoning))
            }
            return result
        } catch(error: RuntimeFailure) { throw error }
        catch (_: Exception) { synchronized(lock) { own(request) }; fail("E_COMPLETION_TRANSPORT") }
        finally { synchronized(lock) { if(active[request.id] === request) active.remove(request.id) } }
    }
    private fun stringOrEmpty(value: JSONObject, key: String): String = if(value.isNull(key)) "" else value.getString(key)
}
