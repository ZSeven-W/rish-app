package tech.zseven.rish.gpui

import org.json.JSONArray
import org.json.JSONObject
import tech.zseven.rish.BuildConfig
import tech.zseven.rish.runtime.*

internal object RuntimeRoutes {
    private fun slot(harness: String): String = when (harness) {
        "dsh" -> "DEEPSEEK_API_KEY"
        "glm" -> "BIGMODEL_API_KEY"
        "codex" -> "OPENAI_API_KEY"
        "claude-code" -> "ANTHROPIC_API_KEY"
        else -> throw BridgeFailure("E_RUNTIME_HARNESS")
    }

    fun call(runtime: AndroidRuntimeState, method: String, args: JSONArray): Any? = when (method) {
        "bootstrap" -> runtime.proof()
        "bootstrapForHarness" -> {
            runtime.selectedSlot = slot(args.getString(0))
            runtime.proof()
        }
        "buildInfo" -> JSONObject().put("build", BuildConfig.RISH_BUILD_COMMIT).put("platform", "android")
            .put("os", android.os.Build.VERSION.RELEASE).put("api", android.os.Build.VERSION.SDK_INT)
            .put("device", "${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}")
        "credentialStatus", "credentialStatusForSlot" -> {
            val slot = if (method == "credentialStatus") "DEEPSEEK_API_KEY" else args.getString(0)
            require(slot in AndroidCredentialStore.slots)
            runtime.selectedSlot = slot
            JSONObject().put("status", if (runtime.transport.configured(slot)) "configured" else "missing")
        }
        "clearCredential", "clearCredentialForSlot" -> {
            val slot = if (method == "clearCredential") "DEEPSEEK_API_KEY" else args.getString(0)
            runtime.transport.clear(slot)
            JSONObject().put("status", "cleared")
        }
        "cancelCompletion" -> JSONObject().put("status", runtime.transport.cancel(args.getString(0)))
        "dshModelCatalog" -> runtime.providerModels.legacyDshCatalog()
        "saveDshModelCatalog" -> runtime.providerModels.saveLegacyDshCatalog(args.getJSONObject(0))
        "listCustomProviders" -> runtime.customProviders.list()
        "listProviderModels" -> runtime.providerModels.list()
        "saveProviderModels" -> runtime.providerModels.save(args.getJSONObject(0))
        "discoverProviderModels" -> runtime.providerModels.discover(args.getJSONObject(0))
        "cancelProviderModelDiscovery" -> runtime.providerModels.cancelDiscovery(args.getJSONObject(0))
        "discoverCustomProviderModels" -> runtime.customProviders.discover(args.getJSONObject(0))
        "cancelCustomProviderModelDiscovery" -> runtime.customProviders.cancelDiscovery(args.getJSONObject(0))
        "saveCustomProvider" -> runtime.customProviders.save(args.getJSONObject(0))
        "removeCustomProvider" -> runtime.customProviders.remove(args.getJSONObject(0))
        "customProviderCredentialStatus" -> runtime.customProviders.credentialStatus(args.getJSONObject(0))
        "clearCustomProviderCredential" -> runtime.customProviders.clear(args.getJSONObject(0))
        "providerConfiguration" -> runtime.configurations.read(args.getString(0))
        "saveProviderConfiguration" -> {
            val request = runtime.configurations.normalize(args.getJSONObject(0))
            runtime.transport.mutate { runtime.configurations.save(request) }
        }
        "resetProviderConfiguration" -> runtime.transport.mutate { runtime.configurations.reset(args.getString(0)) }
        "harnessAuthStatus" -> runtime.subscriptionAuth.status(args.getString(0))
        "startHarnessLogin" -> runtime.subscriptionAuth.start(args.getString(0))
        "cancelHarnessLogin" -> runtime.subscriptionAuth.cancel(args.getString(0), args.getString(1))
        "logoutHarness" -> runtime.subscriptionAuth.logout(args.getString(0))
        "loadSession" -> runtime.loadSnapshot().let { if (it.getString("status") == "missing") null else it.getString("session_json") }
        "copyText" -> {
            val text = args.getString(0)
            require(text.length <= 64 * 1024)
            val clipboard = runtime.app.getSystemService(android.content.Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
            clipboard.setPrimaryClip(android.content.ClipData.newPlainText("Rish", text))
            true
        }
        else -> throw BridgeFailure("E_RUNTIME_UNAVAILABLE")
    }
}
