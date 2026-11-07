package tech.zseven.rish.runtime

import org.json.JSONArray
import org.json.JSONObject

/** One ephemeral text turn on a dedicated stdio connection. */
internal class CodexSingleTurn(
    private val model: String,
    private val prompt: String,
    private val instructions: String?,
    private val preview: (String) -> Unit,
) {
    private var threadId: String? = null
    private var turnId: String? = null
    private val itemTypes = mutableMapOf<String, String>()
    private val completedItems = mutableSetOf<String>()
    private var finalAnswer: String? = null
    private var legacyAnswer: String? = null
    private var legacyCount = 0
    private var terminal = false

    var requestBody: String? = null
        private set

    fun threadStart() = JSONObject()
        .put("model", model).put("ephemeral", true)
        .put("sandbox", "read-only").put("approvalPolicy", "never")
        .also { if (instructions != null) it.put("developerInstructions", instructions) }

    fun turnStart(result: JSONObject): JSONObject {
        val thread = result.optJSONObject("thread") ?: invalid()
        if (thread.opt("ephemeral") != true || result.opt("model") != model) invalid()
        val id = identifier(thread.opt("id"))
        threadId = id
        return JSONObject().put("threadId", id).put("input", JSONArray()
            .put(JSONObject().put("type", "text").put("text", prompt).put("text_elements", JSONArray())))
    }

    fun bind(result: JSONObject, body: String) {
        val turn = result.optJSONObject("turn") ?: invalid()
        if (turn.opt("status") != "inProgress" || !turn.isNull("error")) invalid()
        turnId = identifier(turn.opt("id"))
        requestBody = body
    }

    fun accept(message: JSONObject) {
        val method = message.getString("method")
        val params = message.optJSONObject("params") ?: return
        if (params.opt("threadId") != threadId) return
        val eventTurn = when (method) {
            "turn/started", "turn/completed" -> params.optJSONObject("turn")?.opt("id")
            else -> params.opt("turnId")
        }
        if (eventTurn != turnId) return

        when (method) {
            "turn/started" -> if (terminal) invalid()
            "turn/completed" -> {
                val turn = params.getJSONObject("turn")
                if (terminal || turn.opt("status") != "completed" || !turn.isNull("error")) invalid()
                terminal = true
                if (answer().isNullOrBlank()) invalid()
            }
            "item/agentMessage/delta" -> {
                recordItem(params.opt("itemId"), "agentMessage")
                val delta = params.opt("delta") as? String ?: invalid()
                if (delta.isNotEmpty()) preview(delta)
            }
            "item/started", "item/completed" -> {
                val item = params.optJSONObject("item") ?: invalid()
                val type = item.opt("type") as? String ?: invalid()
                if (type !in setOf("agentMessage", "userMessage", "reasoning")) invalid()
                val id = recordItem(item.opt("id"), type)
                if (method == "item/completed") {
                    completedItems.add(id)
                    if (type == "agentMessage") completeMessage(item)
                }
            }
            "item/reasoning/summaryTextDelta", "item/reasoning/summaryPartAdded",
            "item/reasoning/textDelta" -> recordItem(params.opt("itemId"), "reasoning")
            else -> if (method.startsWith("item/")) invalid()
        }
    }

    private fun recordItem(value: Any?, type: String): String {
        val id = identifier(value)
        if (terminal || id in completedItems) invalid()
        val previousType = itemTypes.putIfAbsent(id, type)
        if (previousType != null && previousType != type) invalid()
        return id
    }

    private fun completeMessage(item: JSONObject) {
        val text = item.opt("text") as? String ?: invalid()
        when (item.opt("phase")) {
            "final_answer" -> {
                if (finalAnswer != null) invalid()
                finalAnswer = text
            }
            "commentary", "partial_answer" -> Unit
            null, JSONObject.NULL -> {
                legacyCount++
                legacyAnswer = text
            }
            else -> invalid()
        }
    }

    fun completed(): Boolean = terminal

    fun answer(): String? = if (terminal) finalAnswer ?: legacyAnswer.takeIf { legacyCount == 1 } else null

    fun responseId(): String = checkNotNull(turnId)

    private fun identifier(value: Any?): String =
        (value as? String)?.takeIf { ID.matches(it) } ?: invalid()

    private fun invalid(): Nothing = throw CodexProtocolRefused("invalid_turn_result")

    companion object {
        private val ID = Regex("[a-zA-Z0-9._:-]{1,128}")
    }
}

internal class CodexProtocolRefused(val code: String) : Exception()
