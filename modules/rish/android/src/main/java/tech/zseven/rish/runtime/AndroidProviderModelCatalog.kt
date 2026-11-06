package tech.zseven.rish.runtime

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/** Non-secret provider model choices. Shared Rust owns identity, migration and CAS rules. */
internal class AndroidProviderModelCatalog(
    context: Context,
    namespace: String,
    private val legacy: () -> Any = { AndroidDshModelCatalog.storedForMigration() },
) {
    private val preferences = context.applicationContext.getSharedPreferences(namespace, Context.MODE_PRIVATE)
    private val lock = synchronized(locks) { locks.getOrPut(namespace) { Any() } }

    companion object {
        private val locks = HashMap<String, Any>()
        val harnesses = setOf("dsh", "claude-code", "codex", "glm")
    }

    private fun stored(): Any = preferences.getString("registry", null)?.let { raw ->
        // Corrupt storage is not an empty catalog and must not be silently repaired.
        try { JSONObject(raw) } catch (_: Exception) { raw }
    } ?: JSONObject.NULL

    private fun request(op: String): JSONObject = JSONObject().put("op", op)
        .put("registry", stored()).put("legacy_dsh_catalog", legacy()).put("discovered_models", JSONArray())

    private fun reduce(request: JSONObject): Any = try { AndroidDshModelCatalog.reduce(request) }
        catch (error: IllegalArgumentException) {
            throw RuntimeFailure(error.message?.takeIf { it.startsWith("E_") } ?: "E_PROVIDER_MODEL_CATALOG_INVALID")
        }

    fun read(): JSONObject = synchronized(lock) { reduce(request("provider_read")) as JSONObject }

    fun models(includeRetired: Boolean = false): JSONArray = synchronized(lock) {
        reduce(request("provider_models").put("include_retired", includeRetired)) as JSONArray
    }

    fun harnessForHistory(model: String): String? = synchronized(lock) {
        reduce(request("provider_harness").put("model", model)) as? String
    }

    fun active(model: String): JSONObject? = models().let { rows ->
        (0 until rows.length()).asSequence().map(rows::getJSONObject).firstOrNull { it.getString("id") == model }
    }

    fun save(value: JSONObject): JSONObject = synchronized(lock) {
        val next = reduce(request("provider_save").put("request", value)) as JSONObject
        check(preferences.edit().putString("registry", next.toString()).commit()) { "E_PROVIDER_MODEL_CATALOG_STORAGE" }
        next
    }
}
