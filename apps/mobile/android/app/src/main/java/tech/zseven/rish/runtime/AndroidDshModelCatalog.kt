package tech.zseven.rish.runtime

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject

/** Model metadata only. Retired models keep old session identities readable. */
internal object AndroidDshModelCatalog {
    private var preferences: SharedPreferences? = null
    private val defaults get() = JSONArray()
        .put(entry("deepseek-v4-flash", "V4 Flash", true))
        .put(entry("deepseek-v4-pro", "V4 Pro", false))
        .put(entry("deepseek-v4-flash-vision-exp", "Flash Exp", true))
    private fun entry(id: String, name: String, images: Boolean) =
        JSONObject().put("id", id).put("name", name).put("supports_images", images)
    @Synchronized fun initialize(context: Context) {
        if (preferences == null) preferences = context.applicationContext.getSharedPreferences("rish.dsh-models.v1", Context.MODE_PRIVATE)
    }
    fun validateModels(models: JSONArray, allowEmpty: Boolean = false): JSONArray {
        require(models.length() in (if (allowEmpty) 0 else 1)..(if (allowEmpty) 256 else 32))
        val seen = mutableSetOf<String>()
        val reserved = AndroidProviderConfiguration.models.filterKeys { it != "dsh" }.values.flatten().toSet()
        val result = JSONArray()
        for (i in 0 until models.length()) {
            val row = models.getJSONObject(i)
            require(row.keys().asSequence().toSet() == setOf("id", "name", "supports_images"))
            val id = row.getString("id"); val name = row.getString("name").trim()
            require(Regex("[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}").matches(id) && id !in reserved && seen.add(id))
            require(name.length in 1..80 && name.none { it.isISOControl() } && row.opt("supports_images") is Boolean)
            result.put(entry(id, name, row.getBoolean("supports_images")))
        }
        return result
    }
    @Synchronized fun read(): JSONObject {
        val stored = preferences?.getString("catalog", null)
        if (stored == null) return JSONObject().put("schema_version", 1).put("models", defaults).put("retired_models", JSONArray())
        val value = JSONObject(stored); RuntimeJson.checkVersion(value, 1)
        validateModels(value.getJSONArray("models")); validateModels(value.getJSONArray("retired_models"), true)
        return value
    }
    @Synchronized fun save(request: JSONObject): JSONObject {
        RuntimeJson.checkVersion(request, 1)
        require(request.keys().asSequence().toSet() == setOf("schema_version", "models"))
        val models = validateModels(request.getJSONArray("models"))
        val active = (0 until models.length()).map { models.getJSONObject(it).getString("id") }.toSet()
        val old = read(); val known = linkedMapOf<String, JSONObject>()
        for (rows in listOf(defaults, old.getJSONArray("retired_models"), old.getJSONArray("models"))) {
            for (i in 0 until rows.length()) rows.getJSONObject(i).let { known[it.getString("id")] = it }
        }
        val retired = JSONArray()
        known.filterKeys { it !in active }.values.forEach { retired.put(it) }
        require(retired.length() <= 256)
        val value = JSONObject().put("schema_version", 1).put("models", models).put("retired_models", retired)
        check(requireNotNull(preferences).edit().putString("catalog", value.toString()).commit())
        return value
    }
    /**
     * Whether this model can be shown a picture.
     *
     * Read from the same catalog the model picker shows, so a model the
     * person added by hand answers for itself. A model nobody has heard of
     * answers no: sending an image to it would get either an opaque provider
     * error or, worse, a confident answer about an image it never received.
     */
    @Synchronized fun supportsImages(model: String): Boolean {
        val value = read()
        for (key in listOf("models", "retired_models")) {
            val rows = value.getJSONArray(key)
            for (index in 0 until rows.length()) {
                val row = rows.getJSONObject(index)
                if (row.getString("id") == model) return row.getBoolean("supports_images")
            }
        }
        return false
    }

    @Synchronized fun isKnown(model: String): Boolean {
        if (AndroidProviderConfiguration.models.getValue("dsh").contains(model)) return true
        val value = read()
        return listOf("models", "retired_models").any { key ->
            val rows = value.getJSONArray(key)
            (0 until rows.length()).any { rows.getJSONObject(it).getString("id") == model }
        }
    }
}
