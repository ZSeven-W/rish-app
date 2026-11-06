package tech.zseven.rish.gpui

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ShellRuntimeEnginesRoutesTest {
    private val cliIds = listOf("dsh", "claude-code", "codex", "zcode")
    private fun install(id: Any = "codex", schema: Any = 1, initiated: Any = true) = JSONArray().put(
        JSONObject().put("schema_version", schema).put("engine_id", id).put("userInitiated", initiated),
    )

    @Test fun catalogReportsRealBuiltinAndExplicitlyUnavailableOptionalRuntimes() {
        val result = ShellRuntimeEnginesRoutes.call("catalog", JSONArray())
        assertEquals(setOf("schema_version", "engines"), result.keys().asSequence().toSet())
        assertEquals(1, result.getInt("schema_version"))
        val engines = result.getJSONArray("engines")
        assertEquals(listOf("pi") + cliIds, (0 until engines.length()).map { engines.getJSONObject(it).getString("id") })
        for (index in 0 until engines.length()) {
            val engine = engines.getJSONObject(index)
            assertEquals(setOf("id", "installation", "execution", "authentication"), engine.keys().asSequence().toSet())
            val installation = engine.getJSONObject("installation")
            val execution = engine.getJSONObject("execution")
            assertTrue(installation.isNull("version"))
            assertFalse(installation.getBoolean("download_supported"))
            assertFalse("Unavailable catalog entries have not attempted a download", installation.has("error"))
            if (engine.getString("id") == "pi") {
                assertEquals("builtin", installation.getString("state"))
                assertEquals("builtin", installation.getString("integrity"))
                assertEquals("ready", execution.getString("state"))
                assertFalse(installation.has("reason_code"))
                assertFalse(execution.has("reason_code"))
            } else {
                assertEquals("unavailable", installation.getString("state"))
                assertEquals("unknown", installation.getString("integrity"))
                assertEquals("platform_install_unavailable", installation.getString("reason_code"))
                assertEquals("unavailable", execution.getString("state"))
                assertEquals("cli_adapter_unavailable", execution.getString("reason_code"))
            }
        }
    }

    @Test fun catalogWithoutNativeCapabilityDisablesEveryAuthenticationAction() {
        val engines = ShellRuntimeEnginesRoutes.call("catalog", JSONArray()).getJSONArray("engines")
        for (index in 0 until engines.length()) {
            val engine = engines.getJSONObject(index)
            val authentication = engine.getJSONObject("authentication")
            assertEquals(setOf("supported", "source_selection", "authorization_browser", "native_code_entry", "provider_selection"),
                authentication.keys().asSequence().toSet())
            assertTrue(authentication.keys().asSequence().all { authentication.get(it) == false })
        }
    }

    @Test fun nativeAvailabilityOnlyEnablesSupportedBrowserAuthentication() {
        val queried = mutableListOf<String>()
        val engines = ShellRuntimeEnginesRoutes.call("catalog", JSONArray()) { id ->
            queried += id
            id == "codex"
        }.getJSONArray("engines")
        assertEquals(listOf("claude-code", "codex"), queried)
        for (index in 0 until engines.length()) {
            val engine = engines.getJSONObject(index)
            val authentication = engine.getJSONObject("authentication")
            val supported = engine.getString("id") == "codex"
            assertEquals(supported, authentication.get("supported"))
            assertEquals(supported, authentication.get("authorization_browser"))
            assertFalse(authentication.getBoolean("native_code_entry"))
            assertFalse(authentication.getBoolean("source_selection"))
            assertFalse(authentication.getBoolean("provider_selection"))
            if (supported) {
                assertEquals("unavailable", engine.getJSONObject("installation").getString("state"))
                assertEquals("unavailable", engine.getJSONObject("execution").getString("state"))
            }
        }
    }

    @Test fun nativePredicateCannotGrantAuthenticationToUnknownProtocols() {
        val queried = mutableListOf<String>()
        val engines = ShellRuntimeEnginesRoutes.call("catalog", JSONArray()) { id ->
            queried += id
            true
        }.getJSONArray("engines")
        assertEquals(listOf("claude-code", "codex"), queried)
        for (index in 0 until engines.length()) {
            val engine = engines.getJSONObject(index)
            val id = engine.getString("id")
            val authentication = engine.getJSONObject("authentication")
            assertEquals(id in queried, authentication.get("supported"))
            assertFalse(authentication.getBoolean("native_code_entry"))
            assertFalse(authentication.getBoolean("source_selection"))
            assertFalse(authentication.getBoolean("provider_selection"))
            if (id != "pi") {
                assertEquals("unavailable", engine.getJSONObject("installation").getString("state"))
                assertEquals("unavailable", engine.getJSONObject("execution").getString("state"))
            }
        }
    }

    @Test fun failedCapabilityReadDisablesOnlyThatEngineWithoutLeakingItsError() {
        val result = ShellRuntimeEnginesRoutes.call("catalog", JSONArray()) { id ->
            if (id == "claude-code") throw SecurityException("PRIVATE_CAPABILITY_DETAIL")
            true
        }
        val engines = result.getJSONArray("engines")
        assertFalse(result.toString().contains("PRIVATE_CAPABILITY_DETAIL"))
        assertFalse(engines.getJSONObject(2).getJSONObject("authentication").getBoolean("supported"))
        assertTrue(engines.getJSONObject(3).getJSONObject("authentication").getBoolean("supported"))
    }

    @Test fun eachCatalogReadAndBuiltinInstallUseCurrentNativeCapability() {
        var available = true
        val capability: (String) -> Boolean = { it == "codex" && available }
        fun codexSupported(method: String, args: JSONArray) =
            ShellRuntimeEnginesRoutes.call(method, args, capability).getJSONArray("engines")
                .getJSONObject(3).getJSONObject("authentication").getBoolean("supported")
        assertTrue(codexSupported("catalog", JSONArray()))
        assertTrue(codexSupported("install", install("pi")))
        available = false
        assertFalse(codexSupported("catalog", JSONArray()))
        assertFalse(codexSupported("install", install("pi")))
    }

    @Test fun unsupportedCliInstallNeverReturnsDownloadedOrInstalled() {
        for (id in cliIds) {
            val failure = assertThrows(BridgeFailure::class.java) {
                ShellRuntimeEnginesRoutes.call("install", install(id))
            }
            assertEquals("E_RUNTIME_ENGINE_INSTALL_UNAVAILABLE", failure.code)
        }
        catalogReportsRealBuiltinAndExplicitlyUnavailableOptionalRuntimes()
    }

    @Test fun cancelValidatesExplicitActionAndNeverPretendsAnUnavailableDownloadStopped() {
        for (id in listOf("pi") + cliIds) {
            val failure = assertThrows(BridgeFailure::class.java) {
                ShellRuntimeEnginesRoutes.call("cancel", install(id))
            }
            assertEquals("E_RUNTIME_ENGINE_INSTALL_UNAVAILABLE", failure.code)
        }
        for (args in listOf(install(initiated = false), install(schema = true), install(schema = 1.0),
            install("unknown"), install().apply { getJSONObject(0).put("url", "https://example.invalid/") })) {
            assertThrows(IllegalArgumentException::class.java) { ShellRuntimeEnginesRoutes.call("cancel", args) }
        }
        catalogReportsRealBuiltinAndExplicitlyUnavailableOptionalRuntimes()
    }

    @Test fun builtinInstallIsIdempotentAndDoesNotEnableAnyCli() {
        val result = ShellRuntimeEnginesRoutes.call("install", install("pi"))
        assertEquals(ShellRuntimeEnginesRoutes.call("catalog", JSONArray()).toString(), result.toString())
    }

    @Test fun installRequiresExactSchemaExplicitActionAndKnownRuntimeIdentity() {
        for (schema in listOf<Any>(true, "1", 1.0, 0, 2, JSONObject.NULL)) {
            assertThrows(IllegalArgumentException::class.java) { ShellRuntimeEnginesRoutes.call("install", install(schema = schema)) }
        }
        for (initiated in listOf<Any>(false, "true", 1, JSONObject.NULL)) {
            assertThrows(IllegalArgumentException::class.java) { ShellRuntimeEnginesRoutes.call("install", install(initiated = initiated)) }
        }
        for (id in listOf<Any>("", "glm", "openai", "../../codex", "CODEX", 1, JSONObject.NULL, "a".repeat(4096))) {
            assertThrows(IllegalArgumentException::class.java) { ShellRuntimeEnginesRoutes.call("install", install(id)) }
        }
        for (args in listOf(JSONArray(), JSONArray().put(1), install().put(JSONObject()),
            install().apply { getJSONObject(0).put("url", "https://example.invalid/runtime") },
            install().apply { getJSONObject(0).remove("userInitiated") })) {
            assertThrows(Exception::class.java) { ShellRuntimeEnginesRoutes.call("install", args) }
        }
    }

    @Test fun catalogRejectsArgumentsAndUnknownOperations() {
        assertThrows(IllegalArgumentException::class.java) { ShellRuntimeEnginesRoutes.call("catalog", JSONArray().put(JSONObject())) }
        val failure = assertThrows(BridgeFailure::class.java) { ShellRuntimeEnginesRoutes.call("execute", JSONArray()) }
        assertEquals("E_BRIDGE_UNAVAILABLE", failure.code)
    }

    @Test fun callerCannotMutateLaterCatalogState() {
        val result = ShellRuntimeEnginesRoutes.call("catalog", JSONArray())
        result.getJSONArray("engines").getJSONObject(1).getJSONObject("execution").put("state", "ready")
        assertEquals("unavailable", ShellRuntimeEnginesRoutes.call("catalog", JSONArray())
            .getJSONArray("engines").getJSONObject(1).getJSONObject("execution").getString("state"))
    }
}
