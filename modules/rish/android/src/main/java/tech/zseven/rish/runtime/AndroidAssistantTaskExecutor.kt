package tech.zseven.rish.runtime

import org.json.JSONObject

/**
 * Host facts for the Rust assistant task store. The native ledger calls apply
 * only after its approval gate, claim and durable dispatch marker. Rust owns
 * validation, CAS mutations and receipts; Kotlin never persists a task copy.
 */
internal class AndroidAssistantTaskExecutor(
    private val bridge: (JSONObject) -> JSONObject,
    private val descriptor: (String) -> JSONObject?,
) {
    val tools = TOOLS

    /** Registry 5 is private to the store's durable assistant conversation. */
    fun scopeAllowed(version: Int, conversation: JSONObject?): Boolean {
        if (version != REGISTRY_VERSION) return true
        val id = conversationId(conversation) ?: return false
        return try {
            call(JSONObject().put("action", "authorize").put("conversation_id", id))
                .opt("authorized") == true
        } catch (_: AndroidWorkspaceToolExecutor.Refused) {
            false
        }
    }

    /** Profile text is a native fact frozen into the v5 authority, never a caller field. */
    fun assistantContext(conversation: JSONObject?): JSONObject? {
        val id = conversationId(conversation) ?: return null
        val reply = call(JSONObject().put("action", "authorize").put("conversation_id", id))
        if (reply.opt("authorized") != true) return null
        val context = reply.optJSONObject("assistant_context") ?: return null
        if (context.optString("conversation_id") != id) return null
        return JSONObject(context.toString())
    }

    fun prepare(
        call: JSONObject, conversation: JSONObject?, authority: JSONObject?,
    ): JSONObject {
        val context = context(call.optString("name"), conversation, authority)
        val request = envelope("prepare", call, context, call.optJSONObject("arguments") ?: refused())
        return JSONObject().put("schema_version", 1).put("reserved_write_bytes", 0)
            .put("precondition", this.call(request))
    }

    fun execute(
        request: JSONObject, arguments: JSONObject, row: JSONObject,
        conversation: JSONObject?, authority: JSONObject?,
    ): JSONObject {
        val envelope = effectEnvelope("apply", request, arguments, row, conversation, authority)
            .put("now_ms", System.currentTimeMillis())
        return try { call(envelope) } catch (failure: AndroidWorkspaceToolExecutor.Refused) {
            if (failure.code != "E_AGENT_PERSISTENCE") throw failure
            // A reply can be lost after the atomic store commit. Read its
            // receipt before settling the ledger, using exactly this identity.
            val receipt = try {
                callValue(JSONObject(envelope.toString()).put("action", "recover").apply { remove("now_ms") })
            } catch (_: AndroidWorkspaceToolExecutor.Refused) { refused("E_AGENT_EXECUTION_AMBIGUOUS") }
            if (receipt is JSONObject) receipt else refused("E_AGENT_EXECUTION_AMBIGUOUS")
        }
    }

    /** A missing receipt proves no atomic task mutation committed. Never replay a mutation here. */
    fun recover(
        request: JSONObject, arguments: JSONObject, row: JSONObject,
        conversation: JSONObject?, authority: JSONObject?,
    ): JSONObject {
        val reply = callValue(effectEnvelope("recover", request, arguments, row, conversation, authority))
        return if (reply == JSONObject.NULL) {
            JSONObject().put("schema_version", 1).put("status", "not_dispatched")
        } else {
            JSONObject().put("schema_version", 1).put("status", "settled")
                .put("effect", reply as? JSONObject ?: refused())
        }
    }

    private fun effectEnvelope(
        action: String, request: JSONObject, arguments: JSONObject, row: JSONObject,
        conversation: JSONObject?, authority: JSONObject?,
    ): JSONObject {
        val context = context(request.optString("name"), conversation, authority)
        if (request.optString("conversation_id") != context.getString("conversation_id")) refused()
        val locator = row.optJSONObject("locator") ?: refused()
        // The locator comes from the persisted native row. A caller cannot use
        // another operation's receipt by changing a request or retry identity.
        for (key in listOf("task_id", "attempt_id", "round_id", "round_index", "call_index", "call_id", "idempotency_key")) {
            if (!same(locator.opt(key), request.opt(key))) refused()
        }
        for (key in listOf("name", "arguments_sha256")) {
            if (!same(row.opt(key), request.opt(key))) refused()
        }
        val precondition = row.optJSONObject("precondition") ?: refused()
        if (precondition.optString("kind") != request.optString("name") ||
            precondition.optString("conversation_id") != context.getString("conversation_id") ||
            precondition.optString("arguments_sha256") != request.optString("arguments_sha256")) refused()
        val revision = precondition.opt("expected_store_revision") as? Number ?: refused()
        if (revision.toLong() < 0 || revision.toDouble() != revision.toLong().toDouble()) refused()
        return envelope(action, request, context, arguments)
            .put("locator", JSONObject(locator.toString())).put("expected_revision", revision.toLong())
    }

    private fun envelope(action: String, call: JSONObject, context: JSONObject, arguments: JSONObject): JSONObject {
        val sha = call.opt("arguments_sha256") as? String ?: refused()
        if (!sha.matches(Regex("[0-9a-f]{64}"))) refused()
        return JSONObject().put("action", action).put("name", call.getString("name"))
            .put("conversation_id", context.getString("conversation_id"))
            .put("arguments_sha256", sha).put("arguments", JSONObject(arguments.toString()))
            .put("context", context)
    }

    private fun context(name: String, conversation: JSONObject?, authority: JSONObject?): JSONObject {
        if (name !in tools || authority?.optJSONObject("registry")?.optInt("registry_version") != REGISTRY_VERSION) refused()
        val id = conversationId(conversation) ?: refused()
        if (authority.optString("conversation_id") != id || !scopeAllowed(REGISTRY_VERSION, conversation)) refused()
        val committed = conversation ?: refused()
        val model = committed.opt("model_id") as? String ?: refused()
        if (model.isEmpty()) refused()
        val binding = committed.optJSONObject("workspace_binding") ?: refused()
        val workspaceId = binding.opt("workspace_id") as? String ?: refused()
        val nativeDescriptor = descriptor(workspaceId) ?: refused()
        val root = authority.optJSONObject("root") ?: refused()
        // Assistant metadata lives in the private store. It needs proof of
        // the committed workspace's read binding, never a workspace write lease.
        val capabilities = root.optJSONArray("capabilities") ?: refused()
        if ((0 until capabilities.length()).none { capabilities.optString(it) == "file_read" } ||
            nativeDescriptor.optJSONObject("capabilities")?.opt("read") != true) refused()
        if (root.optString("workspace_id") != workspaceId ||
            !same(root.opt("workspace_binding_revision"), binding.opt("binding_revision")) ||
            !same(root.opt("project_id"), binding.opt("project_id"))) refused()
        if (nativeDescriptor.optString("status") != "ok" ||
            nativeDescriptor.optString("workspace_id") != workspaceId ||
            !same(nativeDescriptor.opt("binding_revision"), binding.opt("binding_revision"))) refused()
        return JSONObject().put("conversation_id", id).put("model_id", model)
            .put("workspace_binding", JSONObject(binding.toString()))
            .put("workspace_descriptor", JSONObject(nativeDescriptor.toString()))
    }

    private fun call(request: JSONObject): JSONObject = callValue(request) as? JSONObject ?: refused()

    private fun callValue(request: JSONObject): Any {
        val reply = try { bridge(request) } catch (_: Exception) { refused("E_AGENT_PERSISTENCE") }
        if (reply.opt("ok") != true || !reply.has("result")) {
            val code = when (reply.optString("error")) {
                "E_AGENT_CONFLICT", "E_AGENT_NOT_FOUND", "E_AGENT_BAD_ARGUMENTS" -> reply.getString("error")
                else -> "E_AGENT_PERSISTENCE"
            }
            refused(code)
        }
        return reply.get("result")
    }

    private fun conversationId(conversation: JSONObject?): String? =
        ((conversation?.opt("id") ?: conversation?.opt("conversation_id")) as? String)?.takeIf { it.isNotEmpty() }

    private fun same(a: Any?, b: Any?): Boolean = when {
        a == null || b == null -> false
        a is Number && b is Number -> a.toDouble() == b.toDouble()
        else -> a == b
    }

    private fun refused(code: String = "E_AGENT_CONFLICT"): Nothing = throw AndroidWorkspaceToolExecutor.Refused(code)

    companion object {
        const val REGISTRY_VERSION = 5
        val TOOLS = setOf("list_assistant_tasks", "create_assistant_task", "update_assistant_task",
            "search_assistant_memory", "remember_assistant_memory", "forget_assistant_memory")
    }
}
