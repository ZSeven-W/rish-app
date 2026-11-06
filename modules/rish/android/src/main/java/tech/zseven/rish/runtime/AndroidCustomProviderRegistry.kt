package tech.zseven.rish.runtime

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/** Shared Rust schema/revision policy; Android owns atomic preference persistence. */
internal class AndroidCustomProviderRegistry(
    context: Context,
    namespace: String,
    internal val providerModels: AndroidProviderModelCatalog? = null,
) {
    private val preferences = context.applicationContext.getSharedPreferences(namespace, Context.MODE_PRIVATE)
    private val lock = synchronized(locks) { locks.getOrPut(namespace) { Any() } }
    companion object {
        private val locks = HashMap<String, Any>()
        private const val UUID = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
        val credentialAccount = Regex("CUSTOM_PROVIDER_custom-${UUID}_[a-f0-9]{64}")
        private val logical = Regex("custom:($UUID):($UUID)")
        fun harnessForLogical(model: String): String? = logical.matchEntire(model)?.let { "custom-${it.groupValues[1]}" }
    }
    private fun call(request: JSONObject): Any = try { AndroidProviderConfiguration.policy(request) }
        catch (failure: IllegalArgumentException) {
            throw RuntimeFailure(failure.message?.takeIf { it.startsWith("E_") } ?: "E_CUSTOM_PROVIDER_REGISTRY_INVALID")
        }
    private fun stored(): Any {
        val raw = preferences.getString("registry", null)?.let { JSONObject(it) } ?: return JSONObject.NULL
        val checked = call(JSONObject().put("op", "registry_read").put("registry", raw)) as JSONObject
        val providers = checked.getJSONArray("providers")
        for (index in 0 until providers.length()) {
            val configuration = providers.getJSONObject(index).getJSONObject("configuration")
            val endpoint = configuration.getString("endpoint_url")
            if (AndroidProviderConfiguration.endpoint(endpoint, configuration.get("protocol"), true) != endpoint) {
                throw RuntimeFailure("E_CUSTOM_PROVIDER_REGISTRY_INVALID")
            }
        }
        return checked
    }
    fun read(): JSONObject = synchronized(lock) {
        call(JSONObject().put("op", "registry_read").put("registry", stored())) as JSONObject
    }
    fun models(includeRetired: Boolean = false): JSONArray = synchronized(lock) {
        call(JSONObject().put("op", "registry_models").put("registry", stored()).put("include_retired", includeRetired)) as JSONArray
    }
    fun route(model: String, requireActive: Boolean = true): JSONObject? = synchronized(lock) {
        if (harnessForLogical(model) == null) return@synchronized null
        call(JSONObject().put("op", "registry_route").put("registry", stored())
            .put("model_id", model).put("require_active", requireActive)) as? JSONObject
    }
    fun provider(id: String): JSONObject {
        val providers = read().getJSONArray("providers")
        for (index in 0 until providers.length()) {
            val provider = providers.getJSONObject(index)
            if (provider.getString("id") == id && provider.getBoolean("active")) return provider
        }
        throw RuntimeFailure("E_CUSTOM_PROVIDER_UNAVAILABLE")
    }
    fun configuration(harness: String): JSONObject {
        require(harness.startsWith("custom-"))
        return provider(harness.removePrefix("custom-")).getJSONObject("configuration")
    }
    fun save(expectedRevision: Long, provider: JSONObject): JSONObject = synchronized(lock) {
        val configuration = provider.getJSONObject("configuration")
        val endpoint = configuration.getString("endpoint_url")
        if (AndroidProviderConfiguration.endpoint(endpoint, configuration.get("protocol"), true) != endpoint) {
            throw RuntimeFailure("E_CUSTOM_PROVIDER_REGISTRY_INVALID")
        }
        persist(call(JSONObject().put("op", "registry_save").put("registry", stored())
            .put("expected_revision", expectedRevision).put("provider", provider)) as JSONObject)
    }
    fun remove(expectedRevision: Long, id: String): JSONObject = synchronized(lock) {
        persist(call(JSONObject().put("op", "registry_remove").put("registry", stored())
            .put("expected_revision", expectedRevision).put("provider_id", id)) as JSONObject)
    }
    private fun persist(next: JSONObject): JSONObject {
        check(preferences.edit().putString("registry", next.toString()).commit()) { "E_CUSTOM_PROVIDER_STORAGE" }
        return next
    }
}
