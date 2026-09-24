package tech.zseven.rish

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.SmallTest
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.AndroidCredentialStore
import tech.zseven.rish.runtime.AndroidModelTransport
import tech.zseven.rish.runtime.AndroidProviderConfiguration
import tech.zseven.rish.runtime.RishAgentCoreNative
import tech.zseven.rish.runtime.RuntimeFailure
import java.io.InputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.json.JSONArray

/**
 * Reassembling a streamed reply.
 *
 * The preview is display-only, but the reply the round settles on is built
 * from the same chunks, so the assembler has to produce exactly what the
 * non-streaming path would have received. These hold the two things chunked
 * transports get wrong: arguments split mid-token across frames, and frames
 * that carry nothing at all.
 */
@RunWith(AndroidJUnit4::class)
@SmallTest
class AndroidModelTransportStreamTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    private fun transport(): AndroidModelTransport {
        // The parsing lives in the shared core now; without it staged there
        // is nothing here to test.
        assumeTrue("rish agent core is not staged in this build", RishAgentCoreNative.available)
        val namespace = "stream-${UUID.randomUUID()}"
        return AndroidModelTransport(
            AndroidCredentialStore(context, namespace),
            AndroidProviderConfiguration(context, "$namespace.providers"),
        )
    }

    private fun stream(vararg lines: String) =
        lines.joinToString("\n", postfix = "\n").byteInputStream(Charsets.UTF_8)

    @Test
    fun textAndReasoningArriveInPiecesAndEndAsOneReply() {
        val seen = mutableListOf<JSONObject>()
        val reply = transport().assembleStream(
            stream(
                """data: {"id":"r-1","model":"deepseek-v4-flash","choices":[{"delta":{"reasoning_content":"think"}}]}""",
                ": keep-alive",
                "",
                """data: {"id":"r-1","model":"deepseek-v4-flash","choices":[{"delta":{"content":"Hel"}}]}""",
                """data: {"id":"r-1","model":"deepseek-v4-flash","choices":[{"delta":{"content":"lo"},"finish_reason":"stop"}]}""",
                "data: [DONE]",
            ),
        ) { seen.add(it) }
        val choice = reply.getJSONArray("choices").getJSONObject(0)
        val message = choice.getJSONObject("message")
        assertEquals("r-1", reply.getString("id"))
        assertEquals("Hello", message.getString("content"))
        assertEquals("think", message.getString("reasoning_content"))
        assertEquals("stop", choice.getString("finish_reason"))
        // The keep-alive and the blank line are not events.
        assertEquals("$seen", 3, seen.size)
        assertEquals("think", seen[0].getString("reasoning"))
        assertEquals("Hel", seen[1].getString("text"))
    }

    /**
     * A tool call arrives as a name once and arguments a few characters at a
     * time. Reassembled wrongly, the round asks the model to write a file with
     * half a path.
     */
    @Test
    fun toolCallFragmentsAreJoinedInOrder() {
        val seen = mutableListOf<JSONObject>()
        val reply = transport().assembleStream(
            stream(
                """data: {"id":"r-2","model":"m","choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"write_file","arguments":"{\"pa"}}]}}]}""",
                """data: {"id":"r-2","model":"m","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"th\":\"a.txt\"}"}}]}}]}""",
                """data: {"id":"r-2","model":"m","choices":[{"delta":{},"finish_reason":"tool_calls"}]}""",
                "data: [DONE]",
            ),
        ) { seen.add(it) }
        val call = reply.getJSONArray("choices").getJSONObject(0)
            .getJSONObject("message").getJSONArray("tool_calls").getJSONObject(0)
        assertEquals("call_1", call.getString("id"))
        assertEquals("write_file", call.getJSONObject("function").getString("name"))
        assertEquals(
            """{"path":"a.txt"}""",
            call.getJSONObject("function").getString("arguments"),
        )
        // Each fragment was previewed as it arrived, not only at the end.
        assertTrue("$seen", seen.size >= 2)
        assertEquals(
            "write_file",
            seen[0].getJSONArray("tool_calls").getJSONObject(0).getString("name"),
        )
    }

    /**
     * A socket that hands over at most `size` bytes at a time, wherever that
     * falls -- mid-line, mid-token, mid-character. This is what a real one
     * does and what a line reader hid.
     */
    private class Dribble(private val bytes: ByteArray, private val size: Int) : InputStream() {
        private var position = 0
        override fun read(): Int =
            if (position >= bytes.size) -1 else bytes[position++].toInt() and 0xff

        override fun read(destination: ByteArray, offset: Int, length: Int): Int {
            if (position >= bytes.size) return -1
            val count = minOf(size, length, bytes.size - position)
            System.arraycopy(bytes, position, destination, offset, count)
            position += count
            return count
        }
    }

    private fun wire(vararg lines: String) = lines.joinToString("\n", postfix = "\n")

    /**
     * The case the old line reader could not be asked about: a multi-byte
     * character cut in half by the chunk boundary. Read as two chunks of
     * text, it came back as replacement marks; read as bytes, it is one
     * character. The stream is delivered one byte at a time, so the split
     * happens inside the character, inside the token and inside the line.
     */
    @Test
    fun aCharacterSplitAcrossChunksIsOneCharacter() {
        val text = wire(
            """data: {"id":"r-4","model":"m","choices":[{"delta":{"content":"你好，世界"},"finish_reason":"stop"}]}""",
            "data: [DONE]",
        )
        val seen = mutableListOf<JSONObject>()
        val reply = transport()
            .assembleStream(Dribble(text.toByteArray(Charsets.UTF_8), 1)) { seen.add(it) }
        assertEquals(
            "\u4f60\u597d\uff0c\u4e16\u754c",
            reply.getJSONArray("choices").getJSONObject(0)
                .getJSONObject("message").getString("content"),
        )
        assertEquals("$seen", 1, seen.size)
    }

    /**
     * Where the socket breaks may not change the reply. The same transcript
     * is read at five different chunk sizes and has to assemble identically
     * every time -- including at three bytes, which lands inside events, and
     * at one, which lands everywhere.
     */
    @Test
    fun whereTheSocketBreaksCannotChangeTheReply() {
        val text = wire(
            """data: {"id":"r-5","model":"m","choices":[{"delta":{"reasoning_content":"why"}}]}""",
            """data: {"id":"r-5","model":"m","choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"read_file","arguments":"{\"path\""}}]}}]}""",
            """data: {"id":"r-5","model":"m","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":":\"a.txt\"}"}}]}}]}""",
            """data: {"id":"r-5","model":"m","choices":[{"delta":{"content":"done"},"finish_reason":"tool_calls"}]}""",
            "data: [DONE]",
        ).toByteArray(Charsets.UTF_8)
        val transport = transport()
        val whole = transport.assembleStream(Dribble(text, text.size)) {}.toString()
        for (size in listOf(1, 3, 17, 64, 8192)) {
            val events = mutableListOf<JSONObject>()
            val reply = transport.assembleStream(Dribble(text, size)) { events.add(it) }
            assertEquals("a chunk size of $size changed the reply", whole, reply.toString())
            // And the previews are the events, not the chunks: four of them,
            // however many reads it took.
            assertEquals("$size: $events", 4, events.size)
        }
    }


    /**
     * The whole path, on a real socket.
     *
     * Everything above this point hands bytes to the assembler directly. This
     * one runs a server, lets the app's own HTTP client fetch from it, and
     * checks what the round is settled on -- request built, sent, streamed
     * back through the shared core, reassembled, and read by the same code
     * that reads a reply that arrived whole. Until this existed, no test had
     * ever put a socket under the streaming path.
     *
     * The bytes go out in pieces with a pause between them, so the chunk
     * boundaries are the network's rather than the test's.
     */
    private class Streamer(private val pieces: List<String>) {
        val socket: ServerSocket = ServerSocket().apply {
            reuseAddress = true
            bind(InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0))
        }
        val ready = CountDownLatch(1)
        @Volatile var request: String = ""

        fun start() {
            Thread {
                socket.use { server ->
                    server.accept().use { client ->
                        val input = client.getInputStream()
                        // Read the head, then the body the head declared.
                        val head = StringBuilder()
                        while (!head.endsWith("\r\n\r\n")) {
                            val next = input.read()
                            if (next < 0) return@use
                            head.append(next.toChar())
                        }
                        val length = Regex("(?i)content-length: *(\\d+)")
                            .find(head)?.groupValues?.get(1)?.toInt() ?: 0
                        val body = ByteArray(length)
                        var read = 0
                        while (read < length) {
                            val count = input.read(body, read, length - read)
                            if (count < 0) break
                            read += count
                        }
                        request = head.toString() + String(body, Charsets.UTF_8)
                        val out = client.getOutputStream()
                        out.write(
                            ("HTTP/1.1 200 OK\r\n" +
                                "Content-Type: text/event-stream\r\n" +
                                "Cache-Control: no-cache\r\n" +
                                "Connection: close\r\n\r\n").toByteArray(),
                        )
                        out.flush()
                        ready.countDown()
                        for (piece in pieces) {
                            out.write(piece.toByteArray(Charsets.UTF_8))
                            out.flush()
                            Thread.sleep(15)
                        }
                    }
                }
            }.apply { isDaemon = true }.start()
        }
    }

    @Test
    fun aStreamedRoundGoesOutAndComesBackOverASocket() {
        assumeTrue("rish agent core is not staged in this build", RishAgentCoreNative.available)
        val namespace = "stream-socket-${UUID.randomUUID()}"
        val credentials = AndroidCredentialStore(context, namespace)
        val configurations = AndroidProviderConfiguration(context, "$namespace.providers")
        val transport = AndroidModelTransport(credentials, configurations)

        // An event per line, split so the pieces land mid-event and mid-token.
        val streamer = Streamer(
            listOf(
                """data: {"id":"resp-socket","model":"gpt-5.6","choices":[{"delta":{"content":"He""",
                """llo"}}]}""" + "\n\n" +
                    """data: {"id":"resp-socket","model":"gpt-5.6","choices":[{"delta":{"content":" there"},"finish_re""",
                """ason":"stop"}]}""" + "\n\ndata: [DONE]\n\n",
            ),
        )
        streamer.start()
        val port = streamer.socket.localPort

        configurations.save(
            JSONObject().put("schema_version", 1).put("harness_id", "codex")
                .put("name", "Local stream").put("endpoint_url", "http://127.0.0.1:$port/v1/chat/completions")
                .put("protocol", "chat-completions").put("auth_type", "bearer")
                .put("model_mappings", JSONObject().put("gpt-5.6", "gpt-5.6"))
                .put("send_reasoning", false).put("full_url", true),
        )
        transport.put("OPENAI_API_KEY", transport.account("OPENAI_API_KEY"), "local-test-key")

        val roundId = UUID.randomUUID().toString()
        val request = JSONObject().put("schema_version", 2).put("harness_id", "codex")
            .put("turn_id", UUID.randomUUID().toString())
            .put("attempt_id", UUID.randomUUID().toString())
            .put("round_id", roundId).put("round_index", 0)
            .put("model", "gpt-5.6").put("thinking_mode", "off")
            .put("project_context", JSONObject.NULL)
            .put(
                "visible_history",
                JSONArray().put(
                    JSONObject().put("role", "user").put("content", "Say hello")
                        .put("attachments", JSONArray()),
                ),
            )
            .put("round_transcript", JSONArray()).put("tools", JSONArray())

        val seen = mutableListOf<JSONObject>()
        val result = transport.execute(transport.prepare(request.toString())) { seen.add(it) }

        // The request really went out, asking for a stream.
        assertTrue(streamer.ready.await(20, TimeUnit.SECONDS))
        assertTrue(streamer.request, streamer.request.contains("Accept: text/event-stream"))
        assertTrue(streamer.request, streamer.request.contains("\"stream\":true"))
        assertTrue(streamer.request, streamer.request.contains("Authorization: Bearer local-test-key"))

        // The pieces were previewed as they arrived, not once at the end.
        assertEquals("$seen", 2, seen.size)
        assertEquals("Hello", seen[0].getString("text"))
        assertEquals(" there", seen[1].getString("text"))
        assertEquals("stop", seen[1].getString("finish_reason"))

        // And the round is settled on the reassembled reply, read by the same
        // code that reads one that arrived whole.
        assertEquals("Hello there", result.getString("text"))
        assertEquals("stop", result.getString("finish_reason"))
        assertEquals("gpt-5.6", result.getString("model"))
        assertEquals(roundId, result.getString("round_id"))
        assertEquals("resp-socket", result.getString("provider_response_id"))
        assertEquals(0, result.getJSONArray("tool_calls").length())
        assertEquals(1, transport.sentRequestCount)
    }


    /** The fixture every socket test shares: a local provider and a round. */
    private class Wired(val transport: AndroidModelTransport, val port: Int, val roundId: String) {
        fun request(): JSONObject = JSONObject().put("schema_version", 2)
            .put("harness_id", "codex").put("turn_id", UUID.randomUUID().toString())
            .put("attempt_id", UUID.randomUUID().toString())
            .put("round_id", roundId).put("round_index", 0)
            .put("model", "gpt-5.6").put("thinking_mode", "off")
            .put("project_context", JSONObject.NULL)
            .put(
                "visible_history",
                JSONArray().put(
                    JSONObject().put("role", "user").put("content", "Say hello")
                        .put("attachments", JSONArray()),
                ),
            )
            .put("round_transcript", JSONArray()).put("tools", JSONArray())
    }

    private fun wired(streamer: Streamer): Wired {
        val namespace = "stream-socket-${UUID.randomUUID()}"
        val configurations = AndroidProviderConfiguration(context, "$namespace.providers")
        val transport =
            AndroidModelTransport(AndroidCredentialStore(context, namespace), configurations)
        streamer.start()
        configurations.save(
            JSONObject().put("schema_version", 1).put("harness_id", "codex")
                .put("name", "Local stream")
                .put("endpoint_url", "http://127.0.0.1:${streamer.socket.localPort}/v1/chat/completions")
                .put("protocol", "chat-completions").put("auth_type", "bearer")
                .put("model_mappings", JSONObject().put("gpt-5.6", "gpt-5.6"))
                .put("send_reasoning", false).put("full_url", true),
        )
        transport.put("OPENAI_API_KEY", transport.account("OPENAI_API_KEY"), "local-test-key")
        return Wired(transport, streamer.socket.localPort, UUID.randomUUID().toString())
    }

    /**
     * A relay the person configured answers for the model they chose under
     * whatever name it uses: one it redirected to, or none at all. Refusing
     * every name but the exact one made custom relays fail after the answer
     * arrived -- "only Claude works" (2026-09-24). The receipt keeps the
     * chosen model; a `model` that is not text is still refused.
     */
    @Test
    fun aRelayMayReportAnotherModelNameAndTheChosenModelIsKept() {
        assumeTrue("rish agent core is not staged in this build", RishAgentCoreNative.available)
        for (reported in listOf("\"model\":\"deepseek-chat\",", "\"model\":\"gpt-5.6-2026-01-01\",", "")) {
            val streamer = Streamer(
                listOf(
                    """data: {"id":"resp-alias",${reported}"choices":[{"delta":{"content":"Hi"},"finish_reason":"stop"}]}""" +
                        "\n\ndata: [DONE]\n\n",
                ),
            )
            val wired = wired(streamer)
            val result = wired.transport.execute(wired.transport.prepare(wired.request().toString())) {}
            assertEquals(reported, "Hi", result.getString("text"))
            assertEquals(reported, "gpt-5.6", result.getString("model"))
            // Reasoning settings are off for this relay: none go out, not
            // even a `thinking` that says disabled.
            for (key in listOf("\"thinking\"", "\"reasoning_effort\"", "\"reasoning\"")) {
                assertFalse(streamer.request, streamer.request.contains(key))
            }
        }
        val streamer = Streamer(
            listOf(
                // The fill-in is for a relay that never named a model, not for
                // a stream that never said what it was: no id is still short.
                """data: {"choices":[{"delta":{"content":"Hi"},"finish_reason":"stop"}]}""" +
                    "\n\ndata: [DONE]\n\n",
            ),
        )
        val wired = wired(streamer)
        val code = try {
            wired.transport.execute(wired.transport.prepare(wired.request().toString())) {}
            "no refusal"
        } catch (failure: tech.zseven.rish.runtime.RuntimeFailure) {
            failure.code
        }
        assertTrue(code, code.startsWith("E_COMPLETION_RESPONSE"))
    }

    /**
     * A round after a tool call, over the two dialects that are not chat
     * completions. The round transcript arrives in OpenAI's shape and the
     * core rewrites it into each wire's own: tool_use and tool_result blocks
     * for Messages, function_call and function_call_output items for
     * Responses. Refusing it made every agent turn with a tool in it fail at
     * its second round on Android, for official Claude Code, Codex and GLM
     * as much as for a relay (E_COMPLETION_CONTEXT_UNSUPPORTED).
     */
    @Test
    fun aRoundAfterAToolCallGoesOutInEveryDialect() {
        assumeTrue("rish agent core is not staged in this build", RishAgentCoreNative.available)
        val replies = mapOf(
            "messages" to """{"id":"msg_after","type":"message","role":"assistant","model":"gpt-5.6",""" +
                """"content":[{"type":"text","text":"Done"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}""",
            "responses" to """{"id":"resp_after","object":"response","model":"gpt-5.6","status":"completed",""" +
                """"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done"}]}]}""",
        )
        for ((protocol, reply) in replies) {
            val streamer = Streamer(listOf(reply))
            val namespace = "round-dialect-${UUID.randomUUID()}"
            val configurations = AndroidProviderConfiguration(context, "$namespace.providers")
            val transport = AndroidModelTransport(AndroidCredentialStore(context, namespace), configurations)
            streamer.start()
            configurations.save(
                JSONObject().put("schema_version", 1).put("harness_id", "codex")
                    .put("name", "Local relay")
                    .put("endpoint_url", "http://127.0.0.1:${streamer.socket.localPort}/v1/$protocol")
                    .put("protocol", protocol).put("auth_type", "bearer")
                    .put("model_mappings", JSONObject().put("gpt-5.6", "gpt-5.6"))
                    .put("send_reasoning", false).put("full_url", true),
            )
            transport.put("OPENAI_API_KEY", transport.account("OPENAI_API_KEY"), "local-test-key")
            val request = Wired(transport, streamer.socket.localPort, UUID.randomUUID().toString()).request()
                .put("round_index", 1)
                .put(
                    "round_transcript",
                    JSONArray()
                        .put(
                            JSONObject().put("role", "assistant").put("content", JSONObject.NULL).put(
                                "tool_calls",
                                JSONArray().put(
                                    JSONObject().put("id", "call_1").put("type", "function").put(
                                        "function",
                                        JSONObject().put("name", "list_dir").put("arguments", """{"path":"."}"""),
                                    ),
                                ),
                            ),
                        )
                        .put(JSONObject().put("role", "tool").put("tool_call_id", "call_1").put("content", "README.md")),
                )
            val result = transport.execute(transport.prepare(request.toString()), null)
            assertEquals(protocol, "Done", result.getString("text"))
            val sent = streamer.request.substringAfter("\r\n\r\n")
            val body = JSONObject(sent)
            if (protocol == "messages") {
                val turns = body.getJSONArray("messages")
                val asked = turns.getJSONObject(1).getJSONArray("content").getJSONObject(0)
                assertEquals(sent, "tool_use", asked.getString("type"))
                assertEquals(sent, "call_1", asked.getString("id"))
                val answered = turns.getJSONObject(2).getJSONArray("content").getJSONObject(0)
                assertEquals(sent, "tool_result", answered.getString("type"))
                assertEquals(sent, "call_1", answered.getString("tool_use_id"))
            } else {
                val items = body.getJSONArray("input")
                val types = (0 until items.length()).map { items.getJSONObject(it).optString("type") }
                assertTrue(sent, "function_call" in types && "function_call_output" in types)
            }
        }
    }

    /**
     * The round an agent actually runs: a tool call, whose name arrives once
     * and whose arguments arrive a few characters at a time, over a socket
     * that breaks them wherever it likes. Reassembled wrongly, the round asks
     * a person to approve a call with half a path in it.
     */
    @Test
    fun aStreamedToolCallSurvivesTheSocket() {
        assumeTrue("rish agent core is not staged in this build", RishAgentCoreNative.available)
        val head = """data: {"id":"resp-tool","model":"gpt-5.6","choices":[{"delta":{"tool_calls":"""
        val streamer = Streamer(
            listOf(
                head + """[{"index":0,"id":"call_1","function":{"name":"write_fi""",
                """le","arguments":"{\"pa"}}]}}]}""" + "\n\n" + head,
                """[{"index":0,"function":{"arguments":"th\":\"notes.txt\"}"}}]}}]}""" + "\n\n",
                """data: {"id":"resp-tool","model":"gpt-5.6","choices":[{"delta":{},"finish_reason":"tool_calls"}]}""" +
                    "\n\ndata: [DONE]\n\n",
            ),
        )
        val wired = wired(streamer)
        val seen = mutableListOf<JSONObject>()
        val result = wired.transport.execute(
            wired.transport.prepare(wired.request().toString()),
        ) { seen.add(it) }

        assertEquals("tool_calls", result.getString("finish_reason"))
        val calls = result.getJSONArray("tool_calls")
        assertEquals("$calls", 1, calls.length())
        val call = calls.getJSONObject(0)
        assertEquals("call_1", call.getString("id"))
        assertEquals("write_file", call.getString("name"))
        assertEquals("""{"path":"notes.txt"}""", call.getString("arguments"))
        // The name was previewed once, when it arrived, and the arguments in
        // the pieces they arrived in -- never the accumulation.
        assertTrue("$seen", seen.size >= 2)
        assertEquals(
            "write_file",
            seen[0].getJSONArray("tool_calls").getJSONObject(0).getString("name"),
        )
    }

    /**
     * A provider that hangs up mid-reply. Everything it said is discarded,
     * because a turn that never said how it ended is not a reply -- and a
     * round settled on half a sentence would be worse than a failed one.
     */
    @Test
    fun aSocketThatHangsUpMidReplyFailsTheRound() {
        assumeTrue("rish agent core is not staged in this build", RishAgentCoreNative.available)
        val streamer = Streamer(
            listOf(
                """data: {"id":"resp-cut","model":"gpt-5.6","choices":[{"delta":{"content":"half a sen""" +
                    """tence"}}]}""" + "\n\n" +
                    """data: {"id":"resp-cut","model":"gpt-5.6","choices":[{"delta":{"content":"and then not""",
            ),
        )
        val wired = wired(streamer)
        val seen = mutableListOf<JSONObject>()
        val code = try {
            wired.transport.execute(
                wired.transport.prepare(wired.request().toString()),
            ) { seen.add(it) }
            "answered"
        } catch (failure: tech.zseven.rish.runtime.RuntimeFailure) {
            failure.code
        }
        assertEquals("E_COMPLETION_RESPONSE_JSON", code)
        // What did arrive was shown while it arrived; it is the *reply* that
        // is refused, not the preview.
        assertEquals("$seen", 1, seen.size)
        assertEquals("half a sentence", seen[0].getString("text"))
    }

    /** A stream that stops without a finish reason is a truncated reply. */
    @Test
    fun aStreamWithoutAFinishReasonIsRefused() {
        val refused = try {
            transport().assembleStream(
                stream("""data: {"id":"r-3","model":"m","choices":[{"delta":{"content":"half"}}]}"""),
            ) {}
            false
        } catch (_: Exception) {
            true
        }
        assertTrue("a truncated stream must not answer as a complete reply", refused)
    }

    /**
     * A round that carries a verified project context sends it first, as a
     * system message ahead of everything the person said -- the shape iOS
     * prepends and the core's request body carries for every dialect.
     */
    @Test
    fun aProjectContextGoesOutAheadOfTheConversation() {
        assumeTrue("rish agent core is not staged in this build", RishAgentCoreNative.available)
        val streamer = Streamer(
            listOf(
                """data: {"id":"resp-ctx","model":"gpt-5.6","choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}""" +
                    "\n\ndata: [DONE]\n\n",
            ),
        )
        val wired = wired(streamer)
        val envelope = "RISH-PROJECT-CONTEXT/2\nMETA 2\n{}\nEND\n"
        val request = wired.request().put(
            "project_context",
            JSONArray().put(JSONObject().put("role", "system").put("content", envelope).put("attachments", JSONArray())),
        )
        val result = wired.transport.execute(wired.transport.prepare(request.toString())) {}
        assertEquals("ok", result.getString("text"))
        assertTrue(streamer.ready.await(20, TimeUnit.SECONDS))
        val body = JSONObject(streamer.request.substringAfter("\r\n\r\n"))
        val messages = body.getJSONArray("messages")
        assertEquals("system", messages.getJSONObject(0).getString("role"))
        assertEquals(envelope, messages.getJSONObject(0).getString("content"))
        assertEquals("user", messages.getJSONObject(1).getString("role"))
        assertEquals("Say hello", messages.getJSONObject(1).getString("content"))

        // A context that is not a list of system messages is refused before anything is sent.
        val bad = wired.request().put("project_context", JSONArray().put(JSONObject().put("role", "user").put("content", "x")))
        try {
            wired.transport.prepare(bad.toString())
            fail("expected a refusal")
        } catch (failure: RuntimeFailure) {
            assertEquals("E_COMPLETION_CONTEXT_UNSUPPORTED", failure.code)
        }
    }
}
