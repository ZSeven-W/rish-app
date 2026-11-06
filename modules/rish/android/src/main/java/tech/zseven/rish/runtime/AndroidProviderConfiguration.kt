package tech.zseven.rish.runtime

import android.content.Context
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import org.json.JSONArray
import org.json.JSONObject

/** Platform URL codec and preference I/O; provider rules are shared in Rust. */
internal class AndroidProviderConfiguration(
    context: Context,
    namespace: String = "rish.providers.v1",
    legacyModels: () -> Any = { AndroidDshModelCatalog.storedForMigration() },
) {
    private val preferences = context.applicationContext.getSharedPreferences(namespace, Context.MODE_PRIVATE)

    val providerModels = AndroidProviderModelCatalog(context, "$namespace.models", legacyModels)
    val custom = AndroidCustomProviderRegistry(context, "$namespace.custom", providerModels)
    init { registry = custom }

    companion object {
        @Volatile var registry: AndroidCustomProviderRegistry? = null
        fun isCustomModel(model: String): Boolean = model.startsWith("custom:") &&
            policy(JSONObject().put("op", "is_custom_model").put("model_id", model)) == true
        fun harnessForHistory(model: String): String? = if (isCustomModel(model))
            registry?.route(model, false)?.getString("harness_id")
            else registry?.providerModels?.harnessForHistory(model) ?: AndroidDshModelCatalog.harness(model)
        fun historicalModels(): List<String> = AndroidDshModelCatalog.supportedModels() +
            (registry?.providerModels?.models(true)?.let { rows -> (0 until rows.length()).map { rows.getJSONObject(it).getString("id") } } ?: emptyList()) +
            (registry?.models(true)?.let { rows -> (0 until rows.length()).map { rows.getJSONObject(it).getString("id") } } ?: emptyList())
        /** Frozen identifiers for validating old configuration mappings, never choices. */
        val legacyModelIds get() = AndroidDshModelCatalog.builtinModels()
        val configurable: Set<String> get() {
            val rows = policy(JSONObject().put("op", "harnesses")) as JSONArray
            return (0 until rows.length()).map { rows.getString(it) }.toSet()
        }

        fun mapsModel(harness: String, model: String): Boolean = runCatching { this.harness(model) }.getOrNull() == harness
        fun harness(model: String): String = (if (isCustomModel(model)) registry?.route(model)?.getString("harness_id")
            else harnessForHistory(model)) ?: error("E_COMPLETION_MODEL_MISMATCH")
        /** Old identities stay readable; only an explicit active choice can start new work. */
        fun isActiveModel(model: String): Boolean = if (isCustomModel(model)) registry?.route(model) != null
            else registry?.providerModels?.active(model) != null
        fun slot(harness: String): String = policy(JSONObject().put("op", "slot_for_harness").put("harness_id", harness)) as? String
            ?: error("E_COMPLETION_MODEL_MISMATCH")
        private fun harnessOfSlot(slot: String): String? =
            policy(JSONObject().put("op", "harness_for_slot").put("slot", slot)) as? String

        internal fun policy(request: JSONObject): Any {
            check(RishAgentCoreNative.available) { "E_PROVIDER_POLICY_UNAVAILABLE" }
            val encoded = RishAgentCoreNative.providerPolicy(request.toString()) ?: error("E_PROVIDER_POLICY_UNAVAILABLE")
            val reply = JSONObject(encoded)
            require(reply.opt("ok") == true) { reply.optString("error", "E_PROVIDER_CONFIGURATION") }
            return reply.get("value")
        }

        fun profileDigest(value: JSONObject): String =
            policy(JSONObject().put("op", "profile_digest").put("identity", value)) as String

        /** Keep OkHttp's existing escaping; Rust decides transport safety and suffix policy. */
        internal fun endpoint(raw: Any?, protocol: Any?, fullUrl: Any): String {
            val text = raw as? String ?: error("E_PROVIDER_CONFIGURATION")
            val url = text.trim().toHttpUrlOrNull() ?: error("E_PROVIDER_CONFIGURATION")
            val parts = JSONObject().put("scheme", url.scheme).put("host", url.host).put("port", url.port)
                .put("has_user", url.username.isNotEmpty()).put("has_password", url.password.isNotEmpty())
                .put("has_query", url.query != null).put("has_fragment", url.fragment != null).put("path", url.encodedPath)
            val plan = policy(JSONObject().put("op", "endpoint_plan").put("codec", "okhttp").put("raw", text)
                .put("protocol", protocol ?: JSONObject.NULL).put("full_url", fullUrl).put("parts", parts)) as JSONObject
            return url.newBuilder().scheme(plan.getString("scheme")).host(plan.getString("host"))
                .encodedPath(plan.getString("path")).build().toString()
        }

        fun validBinding(raw: Any?, model: String?): Boolean = try {
            val binding = raw as? JSONObject
            val url = binding?.opt("endpoint_url") as? String
            val route = if (model?.let { isCustomModel(it) } == true) registry?.route(model, false) else null
            if (model?.let { isCustomModel(it) } == true && (route == null || binding?.optString("model_id") != route.getString("wire_model"))) error("E_PROVIDER_CONFIGURATION")
            val canonical = url != null && endpoint(url, binding?.opt("protocol"), true) == url
            policy(JSONObject().put("op", "validate_binding").put("binding", raw ?: JSONObject.NULL)
                .put("logical_model", model ?: JSONObject.NULL)
                .put("model_harness", model?.let { harnessForHistory(it) } ?: JSONObject.NULL)
                .put("endpoint_is_canonical", canonical)) as Boolean
        } catch (_: Exception) {
            false
        }
    }

    fun read(harness: String): JSONObject {
        if (harness.startsWith("custom-")) return custom.configuration(harness)
        require(harness in configurable)
        // Do not rewrite, remove or default corrupt/unsupported stored configurations.
        preferences.getString(harness, null)?.let {
            return normalize(JSONObject(it)).also { value -> require(value.getString("harness_id") == harness) }
        }
        return policy(JSONObject().put("op", "defaults").put("harness_id", harness)) as JSONObject
    }

    fun normalize(raw: JSONObject): JSONObject {
        val normalized = JSONObject(raw.toString()).put("endpoint_url",
            endpoint(raw.opt("endpoint_url"), raw.opt("protocol"), raw.opt("full_url") ?: false))
        val harnesses = JSONObject()
        (raw.opt("model_mappings") as? JSONObject)?.keys()?.forEach { model ->
            harnesses.put(model, AndroidCustomProviderRegistry.harnessForLogical(model)
                ?: harnessForHistory(model) ?: JSONObject.NULL)
        }
        return policy(JSONObject().put("op", "validate_configuration").put("configuration", normalized)
            .put("harness_by_model", harnesses)) as JSONObject
    }

    fun save(raw: JSONObject): JSONObject {
        val normalized = normalize(raw)
        require(normalized.getString("harness_id") in configurable)
        check(preferences.edit().putString(normalized.getString("harness_id"), normalized.toString()).commit())
        return normalized
    }

    fun reset(harness: String): JSONObject {
        require(harness in configurable)
        check(preferences.edit().remove(harness).commit())
        return read(harness)
    }

    fun forModel(model: String): JSONObject = if (isCustomModel(model))
        custom.route(model)?.getJSONObject("configuration") ?: error("E_COMPLETION_MODEL_MISMATCH")
        else read(harness(model))

    fun accountForModel(model: String): String? {
        val config = forModel(model)
        return policy(JSONObject().put("op", "credential_account").put("slot", slot(config.getString("harness_id")))
            .put("configuration", config)) as? String
    }

    fun binding(config: JSONObject, model: String): JSONObject? =
        policy(JSONObject().put("op", "binding").put("configuration", config).put("logical_model", model)
            .put("model_harness", runCatching { harness(model) }.getOrNull() ?: JSONObject.NULL)) as? JSONObject

    fun previousAccount(slot: String): String {
        require(slot in AndroidCredentialStore.slots)
        val harness = harnessOfSlot(slot) ?: return slot
        // This platform-specific v0 identity must retain JSONObject.quote's escaping.
        // DSH and GLM never had an account in that legacy scheme.
        if (harness == "dsh" || harness == "glm") return effectiveAccount(slot)
        val config = read(harness)
        if (config.optBoolean("official")) return slot
        val identity = mapOf("harness_id" to harness, "endpoint_url" to config.getString("endpoint_url"),
            "auth_type" to config.getString("auth_type"), "protocol" to config.getString("protocol"))
        val legacy = identity.keys.sorted().joinToString(",", "{", "}") { JSONObject.quote(it) + ":" + JSONObject.quote(identity.getValue(it)) }
        return "CUSTOM_PROVIDER_${harness}_${RuntimeJson.sha("rish.provider-configuration-v1.v1\u0000" + legacy)}"
    }

    fun effectiveAccount(slot: String): String {
        require(slot in AndroidCredentialStore.slots)
        val harness = harnessOfSlot(slot)
        return policy(JSONObject().put("op", "credential_account").put("slot", slot)
            .put("configuration", harness?.let { read(it) } ?: JSONObject.NULL)) as String
    }
}
