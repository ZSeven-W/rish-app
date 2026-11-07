package tech.zseven.rish.runtime

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.nio.file.Files
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Experimental Android round backend. Its host owns the executable, isolation
 * and credential policy. The installed app does not provision this transport.
 */
internal class AndroidCodexRoundTransport(
    private val executable: File,
    private val workDirectory: File,
    private val server: BoundedCodexAppServerProbeRunner,
) {
    internal class Prepared(
        val roundId: String,
        val operationId: String,
        val model: String,
        val input: JSONObject,
        val historyDigest: String,
    ) {
        val cancelled = AtomicBoolean()
    }

    private var active: Prepared? = null

    @Synchronized
    fun prepare(request: JSONObject, history: JSONArray, transcript: JSONArray, instructions: JSONArray): Prepared {
        // Initial single-message scope. In particular, this route cannot
        // silently drop a previous message, attachment or tool result.
        if (request.opt("harness_id") != "codex" || request.optInt("transport_schema_version") != 2 ||
            request.optInt("round_index", -1) != 0 || request.opt("thinking_mode") != "off" ||
            history.length() != 1 || transcript.length() != 0
        ) throw RuntimeFailure("E_COMPLETION_CONTEXT_UNSUPPORTED")
        val message = history.getJSONObject(0)
        val prompt = message.opt("content") as? String
        if (message.opt("role") != "user" || message.getJSONArray("attachments").length() != 0 || prompt.isNullOrBlank()) {
            throw RuntimeFailure("E_COMPLETION_CONTEXT_UNSUPPORTED")
        }
        val developer = (0 until instructions.length()).joinToString("\n\n") { index ->
            val instruction = instructions.getJSONObject(index)
            if (instruction.opt("role") != "system") throw RuntimeFailure("E_COMPLETION_CONTEXT_UNSUPPORTED")
            instruction.getString("content")
        }
        if (listOf(prompt, developer).any { it.toByteArray(Charsets.UTF_8).size > MAX_INPUT_BYTES }) {
            throw RuntimeFailure("E_COMPLETION_BODY_TOO_LARGE")
        }
        if (active != null) throw RuntimeFailure("E_COMPLETION_BUSY")
        return Prepared(
            request.getString("round_id"), request.getString("operation_id"), request.getString("model"),
            JSONObject().put("prompt", prompt).put("developer_instructions", developer.ifEmpty { null }),
            RuntimeJson.sha(RuntimeJson.receiptJson(history)),
        ).also { active = it }
    }

    @Synchronized
    fun cancel(roundId: String) {
        active?.takeIf { it.roundId == roundId }?.cancelled?.set(true)
    }

    @Synchronized
    fun discard(prepared: Prepared) {
        if (active === prepared) active = null
    }

    fun execute(prepared: Prepared, preview: ((JSONObject) -> Unit)?): JSONObject {
        val started = System.nanoTime()
        var home: File? = null
        try {
            if (prepared.cancelled.get()) throw RuntimeFailure("E_COMPLETION_CANCELLED")
            val directory = Files.createTempDirectory(workDirectory.toPath(), "codex-round-").toFile()
            home = directory
            val turn = CodexSingleTurn(
                prepared.model,
                prepared.input.getString("prompt"),
                prepared.input.opt("developer_instructions") as? String,
            ) { text ->
                if (!prepared.cancelled.get()) preview?.invoke(JSONObject().put("kind", "delta").put("text", text))
            }
            val result = server.runTurn(executable, directory, prepared.cancelled, turn)
            if (prepared.cancelled.get()) throw RuntimeFailure("E_COMPLETION_CANCELLED")
            if (result.optString("reason_code") != "text_turn_completed") {
                // A missing terminal frame is a lost response after dispatch.
                // The existing journal reconciles it without replaying a turn.
                android.util.Log.w("RishAgent", "Codex stdio refused: ${result.optString("reason_code")}")
                throw RuntimeFailure("E_COMPLETION_TRANSPORT")
            }
            return JSONObject().put("harness_id", "codex")
                .put("provider_request_id", prepared.operationId).put("provider_response_id", turn.responseId())
                .put("text", checkNotNull(turn.answer())).put("reasoning", "")
                .put("tool_calls", JSONArray()).put("finish_reason", "stop")
                .put("latency_ms", (System.nanoTime() - started) / 1_000_000)
                .put("visible_history_sha256", prepared.historyDigest)
                .put("model_input_sha256", RuntimeJson.sha(RuntimeJson.receiptJson(prepared.input)))
                .put("request_body_sha256", RuntimeJson.sha(checkNotNull(turn.requestBody)))
        } finally {
            try { home?.let(CodexOfflineProbe::removeTree) } finally { discard(prepared) }
        }
    }

    private companion object {
        // Leaves room for JSON escaping and framing inside the pipe budget.
        const val MAX_INPUT_BYTES = 8 * 1024
    }
}
