package tech.zseven.rish.runtime

import android.content.Context
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import org.json.JSONObject

internal class AndroidProviderConfiguration(context: Context, namespace: String = "rish.providers.v1") {
    private val preferences = context.applicationContext.getSharedPreferences(namespace, Context.MODE_PRIVATE)
    companion object {
        val models = mapOf(
            "dsh" to setOf("deepseek-v4-flash", "deepseek-v4-pro", "deepseek-v4-flash-vision-exp"),
            "glm" to setOf("GLM-5.3", "GLM-5.3-Flash"),
            "codex" to setOf("gpt-5.6", "gpt-5.6-mini", "gpt-5.6-nano"),
            "claude-code" to setOf("claude-sonnet-5", "claude-opus-5", "claude-haiku-4-5-20251001", "claude-fable-5-1"),
        )
        /** Every harness can go through a relay the person configured. */
        val configurable = setOf("codex", "claude-code", "dsh", "glm")
        /** DSH's slots are its catalog, which the person can add to. */
        fun mapsModel(harness: String, model: String): Boolean =
            if (harness == "dsh") AndroidDshModelCatalog.isKnown(model) else model in models.getValue(harness)
        private fun harnessOfSlot(slot: String): String? = when(slot) {
            "OPENAI_API_KEY" -> "codex"; "ANTHROPIC_API_KEY" -> "claude-code"
            "DEEPSEEK_API_KEY" -> "dsh"; "BIGMODEL_API_KEY" -> "glm"; else -> null
        }
        fun harness(model: String): String = if (AndroidDshModelCatalog.isKnown(model)) "dsh" else models.entries.firstOrNull { model in it.value }?.key ?: error("E_COMPLETION_MODEL_MISMATCH")
        fun slot(harness: String): String = when(harness) {
            "dsh" -> "DEEPSEEK_API_KEY"; "glm" -> "BIGMODEL_API_KEY"; "codex" -> "OPENAI_API_KEY"; "claude-code" -> "ANTHROPIC_API_KEY"
            else -> error("E_COMPLETION_MODEL_MISMATCH")
        }
        fun profileDigest(value: JSONObject) = RuntimeJson.sha("rish.provider-configuration-v1.v1\u0000" + RuntimeJson.canonical(value))
        private val bindingKeys = setOf("schema_version", "harness_id", "endpoint_url", "protocol", "auth_type", "send_reasoning", "model_id", "profile_id")
        /**
         * `DSHValidateProviderBinding`: a binding is the record `binding()`
         * would issue for this model today -- exact keys, a custom-capable
         * harness that is the model's, a normalised endpoint that is its own
         * normal form, and a profile digest over everything but itself.
         */
        fun validBinding(raw: Any?, model: String?): Boolean {
            val binding = raw as? JSONObject ?: return false
            if (binding.keys().asSequence().toSet() != bindingKeys || binding.opt("schema_version") != 1) return false
            val harness = binding.opt("harness_id") as? String ?: return false
            if (harness !in configurable) return false
            if (model == null || (try { harness(model) } catch (_: IllegalStateException) { null }) != harness) return false
            val wire = binding.opt("model_id") as? String ?: return false
            if (wire.isEmpty() || wire.toByteArray(Charsets.UTF_8).size > 128 || wire.any { it.isWhitespace() || it.isISOControl() }) return false
            if (binding.opt("send_reasoning") !is Boolean) return false
            if (binding.opt("auth_type") !in setOf("bearer", "x-api-key", "api-key")) return false
            val protocol = binding.opt("protocol") as? String ?: return false
            if (protocol !in setOf("messages", "chat-completions", "responses")) return false
            val endpoint = binding.opt("endpoint_url") as? String ?: return false
            if (endpoint.isEmpty() || endpoint.length > 2048 || endpoint.any { it.isISOControl() }) return false
            val url = endpoint.trim().toHttpUrlOrNull() ?: return false
            val local = url.host in setOf("localhost", "127.0.0.1", "::1", "[::1]")
            if (url.username.isNotEmpty() || url.password.isNotEmpty() || url.query != null || url.fragment != null) return false
            if (!(url.isHttps || (local && url.scheme == "http"))) return false
            if (url.toString() != endpoint) return false
            val identity = JSONObject(binding.toString()); identity.remove("profile_id")
            return binding.opt("profile_id") == profileDigest(identity)
        }
    }
    fun read(harness: String): JSONObject {
        require(harness in configurable)
        preferences.getString(harness, null)?.let { return normalize(JSONObject(it)).also { value -> require(value.getString("harness_id") == harness) } }
        val (endpoint, protocol, auth) = when (harness) {
            "codex" -> Triple("https://api.openai.com/v1/responses", "responses", "bearer")
            "claude-code" -> Triple("https://api.anthropic.com/v1/messages", "messages", "x-api-key")
            "glm" -> Triple("https://open.bigmodel.cn/api/anthropic/v1/messages", "messages", "x-api-key")
            else -> Triple("https://api.deepseek.com/chat/completions", "chat-completions", "bearer")
        }
        return JSONObject().put("schema_version", 1).put("harness_id", harness).put("name", "")
            .put("endpoint_url", endpoint).put("protocol", protocol).put("auth_type", auth)
            .put("send_reasoning", true).put("model_mappings", JSONObject()).put("official", true)
    }
    fun normalize(raw: JSONObject): JSONObject {
        RuntimeJson.checkVersion(raw, 1)
        val keys = raw.keys().asSequence().toSet()
        require(keys - "full_url" == setOf("schema_version", "harness_id", "name", "endpoint_url", "protocol", "auth_type", "model_mappings", "send_reasoning"))
        val harness = raw.getString("harness_id"); require(harness in configurable)
        val name = raw.getString("name"); require(name.isNotEmpty() && name.toByteArray().size <= 80 && name.none { it.isISOControl() })
        val protocol = raw.getString("protocol"); require(protocol in setOf("messages", "chat-completions", "responses"))
        require(raw.getString("auth_type") in setOf("bearer", "x-api-key", "api-key"))
        require(raw.opt("send_reasoning") is Boolean)
        if (raw.has("full_url")) require(raw.opt("full_url") is Boolean)
        val urlText = raw.getString("endpoint_url"); require(urlText.length <= 2048 && urlText.none { it.isISOControl() })
        val url = urlText.trim().toHttpUrlOrNull() ?: error("Invalid endpoint")
        require(url.username.isEmpty() && url.password.isEmpty() && url.query == null && url.fragment == null)
        require(url.isHttps || url.host in setOf("localhost", "127.0.0.1", "::1"))
        var path = url.encodedPath
        if (!raw.optBoolean("full_url", false)) {
            val suffix = when(protocol) { "messages" -> "messages"; "responses" -> "responses"; else -> "chat/completions" }
            path = path.trimEnd('/')
            var knownEndpoint = false
            for (known in listOf("/messages", "/responses", "/chat/completions")) if(path.endsWith(known)) { path = path.removeSuffix(known); knownEndpoint = true; break }
            if (!knownEndpoint && !path.endsWith("/v1")) path += "/v1"
            path += "/$suffix"
        }
        // DSH's catalog holds up to 32 models, and each may be mapped.
        val mappings = raw.getJSONObject("model_mappings"); require(mappings.length() <= 32)
        for (model in mappings.keys()) {
            require(mapsModel(harness, model)); val wire = mappings.getString(model)
            require(wire.length in 1..128 && wire.none { it.isWhitespace() || it.isISOControl() })
        }
        val normalized = JSONObject(raw.toString()).put("endpoint_url", url.newBuilder().encodedPath(path).build().toString()).put("full_url", raw.optBoolean("full_url", false))
        return normalized
    }
    fun save(raw: JSONObject): JSONObject {
        val normalized = normalize(raw)
        check(preferences.edit().putString(normalized.getString("harness_id"), normalized.toString()).commit())
        return normalized
    }
    fun reset(harness: String): JSONObject {
        require(harness in configurable)
        check(preferences.edit().remove(harness).commit()); return read(harness)
    }
    fun forModel(model: String): JSONObject = read(harness(model))
    fun binding(config: JSONObject, model: String): JSONObject? {
        if (config.optBoolean("official")) return null
        val binding = JSONObject().put("schema_version", 1).put("harness_id", config.getString("harness_id"))
            .put("endpoint_url", config.getString("endpoint_url")).put("protocol", config.getString("protocol"))
            .put("auth_type", config.getString("auth_type")).put("send_reasoning", config.getBoolean("send_reasoning"))
            .put("model_id", config.getJSONObject("model_mappings").optString(model, model))
        return binding.put("profile_id", profileDigest(binding))
    }
    fun previousAccount(slot: String): String {
        require(slot in AndroidCredentialStore.slots)
        val harness = harnessOfSlot(slot) ?: return slot
        // DSH and GLM had no custom provider before the current identity, so
        // there is no legacy account to carry a key over from.
        if (harness == "dsh" || harness == "glm") return effectiveAccount(slot)
        val config = read(harness)
        if(config.optBoolean("official")) return slot
        val identity = mapOf("harness_id" to harness, "endpoint_url" to config.getString("endpoint_url"),
            "auth_type" to config.getString("auth_type"), "protocol" to config.getString("protocol"))
        val legacy = identity.keys.sorted().joinToString(",", "{", "}") { JSONObject.quote(it) + ":" + JSONObject.quote(identity.getValue(it)) }
        return "CUSTOM_PROVIDER_${harness}_${RuntimeJson.sha("rish.provider-configuration-v1.v1\u0000" + legacy)}"
    }
    fun effectiveAccount(slot: String): String {
        require(slot in AndroidCredentialStore.slots)
        val harness = harnessOfSlot(slot) ?: return slot
        val config = read(harness)
        if(config.optBoolean("official")) return slot
        val identity = JSONObject().put("harness_id", harness).put("endpoint_url", config.getString("endpoint_url"))
            .put("auth_type", config.getString("auth_type")).put("protocol", config.getString("protocol"))
        return "CUSTOM_PROVIDER_${harness}_${profileDigest(identity)}"
    }
}
