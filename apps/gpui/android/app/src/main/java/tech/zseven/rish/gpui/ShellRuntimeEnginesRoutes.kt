package tech.zseven.rish.gpui

import org.json.JSONArray
import org.json.JSONObject
import tech.zseven.rish.runtime.AndroidSubscriptionAuthProtocol

/** Runtime products, independent of model providers and authentication state. */
internal object ShellRuntimeEnginesRoutes {
    private val engineIds = listOf("pi", "dsh", "claude-code", "codex", "zcode")

    fun call(
        method: String, args: JSONArray,
        authenticationAvailable: (String) -> Boolean = { false },
    ): JSONObject = when (method) {
        "catalog" -> {
            require(args.length() == 0)
            catalog(authenticationAvailable)
        }
        "install" -> {
            val engine = installRequest(args)
            if (engine != "pi") throw BridgeFailure("E_RUNTIME_ENGINE_INSTALL_UNAVAILABLE")
            // Pi is linked into the application; this is an idempotent read.
            catalog(authenticationAvailable)
        }
        "cancel" -> {
            installRequest(args)
            // This host has no download to cancel. Never manufacture success.
            throw BridgeFailure("E_RUNTIME_ENGINE_INSTALL_UNAVAILABLE")
        }
        else -> throw BridgeFailure("E_BRIDGE_UNAVAILABLE")
    }

    private fun catalog(authenticationAvailable: (String) -> Boolean): JSONObject {
        val engines = JSONArray()
        for (id in engineIds) {
            val builtin = id == "pi"
            val installation = JSONObject()
                .put("state", if (builtin) "builtin" else "unavailable")
                .put("version", JSONObject.NULL)
                .put("download_supported", false)
                .put("integrity", if (builtin) "builtin" else "unknown")
            val execution = JSONObject().put("state", if (builtin) "ready" else "unavailable")
            if (!builtin) {
                // Build-host CLI packaging and account login adapters are not
                // an on-device installer or an assistant execution backend.
                installation.put("reason_code", "platform_install_unavailable")
                execution.put("reason_code", "cli_adapter_unavailable")
            }
            // Knowing the CLI protocol does not establish a usable native
            // login adapter. This metadata-only check must not open a process,
            // restore credentials or initialize an authentication manager.
            val authSupported = AndroidSubscriptionAuthProtocol.supports(id) &&
                try { authenticationAvailable(id) } catch (_: Exception) { false }
            val authentication = JSONObject().put("supported", authSupported)
                .put("source_selection", false).put("authorization_browser", authSupported)
                // The current manager never advertises a code submission
                // contract, even when its browser login flow is available.
                .put("native_code_entry", false).put("provider_selection", false)
            engines.put(JSONObject().put("id", id).put("installation", installation).put("execution", execution)
                .put("authentication", authentication))
        }
        return JSONObject().put("schema_version", 1).put("engines", engines)
    }

    private fun installRequest(args: JSONArray): String {
        require(args.length() == 1)
        val request = args.getJSONObject(0)
        require(request.keys().asSequence().toSet() == setOf("schema_version", "engine_id", "userInitiated"))
        val schema = request.opt("schema_version")
        require((schema is Int || schema is Long) && (schema as Number).toLong() == 1L)
        require(request.opt("userInitiated") == true)
        val engine = request.opt("engine_id") as? String
        require(engine in engineIds)
        return requireNotNull(engine)
    }
}
