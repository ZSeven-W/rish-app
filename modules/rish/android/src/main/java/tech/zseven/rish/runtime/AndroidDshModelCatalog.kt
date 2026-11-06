package tech.zseven.rish.runtime

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

/** Native preference I/O only. Catalog identities and capabilities belong to Rust. */
internal object AndroidDshModelCatalog {
    private var preferences: SharedPreferences? = null

    @Synchronized fun initialize(context: Context) {
        if (preferences == null) preferences = context.applicationContext.getSharedPreferences("rish.dsh-models.v1", Context.MODE_PRIVATE)
    }

    /** A malformed stored value must fail, never turn into a new default catalog. */
    internal fun storedForMigration(): Any = preferences?.getString("catalog", null)?.let { raw ->
        // An invalid value is a fact for Rust, not an absent preference. Builtin
        // harness routing may still work; catalog operations must refuse it.
        try { JSONObject(raw) } catch (_: JSONException) { raw }
    } ?: JSONObject.NULL

    private fun stored(): Any = storedForMigration()

    internal fun reduce(request: JSONObject): Any {
        check(RishAgentCoreNative.available) { "E_MODEL_CATALOG_UNAVAILABLE" }
        val encoded = RishAgentCoreNative.modelCatalog(request.toString()) ?: error("E_MODEL_CATALOG_UNAVAILABLE")
        val reply = JSONObject(encoded)
        require(reply.opt("ok") == true) { reply.optString("error", "E_MODEL_CATALOG_INVALID") }
        return reply.get("value")
    }

    fun builtinModels(): Map<String, Set<String>> {
        val value = reduce(JSONObject().put("op", "builtin_models")) as JSONObject
        return value.keys().asSequence().associateWith { harness ->
            val rows = value.getJSONArray(harness)
            (0 until rows.length()).map { rows.getString(it) }.toSet()
        }
    }

    @Synchronized fun supportedModels(): List<String> {
        val rows = reduce(JSONObject().put("op", "supported_models").put("catalog", stored())
            .put("discovered_models", JSONArray())) as JSONArray
        return (0 until rows.length()).map { rows.getString(it) }
    }

    fun validateModels(models: JSONArray, allowEmpty: Boolean = false): JSONArray =
        reduce(JSONObject().put("op", "validate_models").put("models", models).put("retired", allowEmpty)) as JSONArray

    @Synchronized fun read(): JSONObject = reduce(JSONObject().put("op", "read").put("catalog", stored())) as JSONObject

    @Synchronized fun save(request: JSONObject): JSONObject {
        val value = reduce(JSONObject().put("op", "save").put("catalog", stored()).put("request", request)) as JSONObject
        check(requireNotNull(preferences).edit().putString("catalog", value.toString()).commit())
        return value
    }

    @Synchronized fun lookup(model: String): JSONObject? =
        reduce(JSONObject().put("op", "lookup").put("catalog", stored()).put("model", model)) as? JSONObject

    @Synchronized fun supportsImages(model: String): Boolean =
        reduce(JSONObject().put("op", "supports_images").put("catalog", stored()).put("model", model)) as Boolean

    @Synchronized fun isKnown(model: String): Boolean =
        reduce(JSONObject().put("op", "is_known").put("catalog", stored()).put("model", model)) as Boolean

    @Synchronized fun harness(model: String): String? =
        reduce(JSONObject().put("op", "harness_for_model").put("catalog", stored()).put("model", model)
            .put("discovered_models", JSONArray())) as? String
}
