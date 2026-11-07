package tech.zseven.rish.runtime

import org.json.JSONObject

/** Built-in API provider catalogs keep their established endpoint and credential accounts. */
internal class AndroidProviderModels(
    private val configurations: AndroidProviderConfiguration,
    private val transport: AndroidModelTransport,
    private val credentials: AndroidCredentialStore,
    private val persistedGuard: () -> Unit,
) {
    constructor(runtime: AndroidRuntimeState) : this(
        runtime.configurations, runtime.transport, runtime.credentials,
        { runtime.customProviders.requireIdlePersisted() },
    )

    fun list(): JSONObject = transport.withProviderLock { configurations.providerModels.read() }

    fun legacyDshCatalog(): JSONObject = transport.withProviderLock { dshRow(configurations.providerModels.read()) }

    /** Old callers update the same authoritative registry, never a second preference key. */
    fun saveLegacyDshCatalog(request: JSONObject): JSONObject = transport.whenIdle {
        exact(request, setOf("schema_version", "models"))
        persistedGuard()
        val current = configurations.providerModels.read()
        val saved = configurations.providerModels.save(JSONObject().put("schema_version", 1)
            .put("expected_revision", current.getLong("revision")).put("harness_id", "dsh")
            .put("models", request.getJSONArray("models")))
        dshRow(saved)
    }

    private fun dshRow(registry: JSONObject): JSONObject {
        val rows = registry.getJSONArray("providers")
        val row = (0 until rows.length()).asSequence().map(rows::getJSONObject)
            .first { it.getString("harness_id") == "dsh" }
        return JSONObject().put("schema_version", 1).put("models", row.getJSONArray("models"))
            .put("retired_models", row.getJSONArray("retired_models"))
    }

    fun save(request: JSONObject): JSONObject = transport.whenIdle {
        exact(request, setOf("schema_version", "harness_id", "expected_revision", "models"))
        harness(request)
        persistedGuard()
        configurations.providerModels.save(request)
    }

    fun prepareDiscovery(request: JSONObject): AndroidProviderModelDiscovery.Prepared =
        AndroidProviderModelDiscovery(configurations, transport, credentials).prepareBuiltin(request, persistedGuard)

    fun discover(request: JSONObject): JSONObject = prepareDiscovery(request).execute()

    fun cancelDiscovery(request: JSONObject): JSONObject {
        exact(request, setOf("schema_version", "harness_id", "operation_id"))
        val harness = harness(request)
        val operation = request.optString("operation_id")
        if (!RuntimeJson.uuid(operation)) throw RuntimeFailure("E_PROVIDER_MODEL_DISCOVERY_INVALID")
        return JSONObject().put("schema_version", 1).put("harness_id", harness).put("operation_id", operation)
            .put("status", transport.cancelDiscovery("builtin:$harness", operation))
    }

    private fun harness(request: JSONObject): String = (request.opt("harness_id") as? String)
        ?.takeIf { it in AndroidProviderModelCatalog.harnesses }
        ?: throw RuntimeFailure("E_PROVIDER_MODEL_DISCOVERY_INVALID")

    private fun exact(request: JSONObject, keys: Set<String>) {
        if (request.opt("schema_version") != 1 || request.keys().asSequence().toSet() != keys)
            throw RuntimeFailure("E_PROVIDER_MODEL_DISCOVERY_INVALID")
    }
}
