package tech.zseven.rish.gpui

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class HarnessAuthorizationRoutesTest {
    private val request = HarnessAuthorizationRoutes.Request("codex", "current-session")
    private fun status(harness: String = "codex", session: String = "current-session",
        url: String = "https://auth.openai.com/device") = JSONObject()
        .put("schema_version", 1).put("harness_id", harness).put("status", "authorizing")
        .put("runtime", JSONObject().put("kind", "official-cli").put("available", true))
        .put("login", JSONObject().put("session_id", session).put("verification_url", url))

    private fun refused(code: String, value: JSONObject, identity: HarnessAuthorizationRoutes.Request = request) {
        var launched = false
        val failure = assertThrows(BridgeFailure::class.java) {
            HarnessAuthorizationRoutes.open(identity, value) { launched = true }
        }
        assertEquals(code, failure.code)
        assertFalse(launched)
    }

    @Test fun bridgeRegistersOnlyTheExplicitLocalRuntimeBrowserAction() {
        assertTrue(HarnessAuthorizationRoutes.handles("LocalRuntime", "openHarnessAuthorization"))
        assertFalse(HarnessAuthorizationRoutes.handles("ShellRuntimeEngines", "openHarnessAuthorization"))
        for (method in listOf("startHarnessLogin", "harnessAuthStatus", "openUrl", "openHarnessAuthorization ")) {
            assertFalse(HarnessAuthorizationRoutes.handles("LocalRuntime", method))
        }
    }

    @Test fun browserRequestAcceptsOnlyKnownHarnessAndSessionIdentity() {
        for (harness in listOf("codex", "claude-code")) {
            assertEquals(HarnessAuthorizationRoutes.Request(harness, "current-session"),
                HarnessAuthorizationRoutes.request(JSONArray().put(harness).put("current-session")))
        }
        for (harness in listOf("dsh", "zcode", "pi", "CODEX", "codex\n", "../../codex")) {
            assertEquals("E_AUTH_HARNESS", assertThrows(BridgeFailure::class.java) {
                HarnessAuthorizationRoutes.request(JSONArray().put(harness).put("current-session"))
            }.code)
        }
        for (args in listOf(JSONArray(), JSONArray().put("codex"), JSONArray().put("codex").put(1),
            JSONArray().put("codex").put(""), JSONArray().put("codex").put("session\n"),
            JSONArray().put("codex").put("x".repeat(129)),
            JSONArray().put("codex").put("current-session").put("https://evil.invalid"))) {
            assertEquals("E_BRIDGE_ARGUMENTS", assertThrows(BridgeFailure::class.java) {
                HarnessAuthorizationRoutes.request(args)
            }.code)
        }
    }

    @Test fun currentSessionOpensNativeUrlAndReturnsNoAuthMaterial() {
        var launched: String? = null
        val result = HarnessAuthorizationRoutes.open(request, status()) { launched = it }
        assertEquals("https://auth.openai.com/device", launched)
        assertEquals(setOf("status"), result.keys().asSequence().toSet())
        assertEquals("opened", result.getString("status"))
        val claude = HarnessAuthorizationRoutes.Request("claude-code", "current-session")
        assertEquals("https://claude.ai/oauth/authorize?state=abc", HarnessAuthorizationRoutes.resolve(
            claude, status("claude-code", url = "https://claude.ai/oauth/authorize?state=abc")))
    }

    @Test fun changedCanceledOrCompletedSessionsCannotOpenAnOldChallenge() {
        refused("E_AUTH_STALE_SESSION", status(session = "newer-session"))
        refused("E_AUTH_STALE_SESSION", status(harness = "claude-code"))
        for (state in listOf("signed_out", "signed_in", "error", "unavailable")) {
            refused("E_AUTH_STALE_SESSION", status().put("status", state))
        }
        refused("E_AUTH_STALE_SESSION", status().apply { remove("login") })
        refused("E_AUTH_STALE_SESSION", status().apply { getJSONObject("runtime").put("available", false) })
        refused("E_AUTH_STALE_SESSION", status().apply { getJSONObject("runtime").put("available", "true") })
        refused("E_AUTH_STALE_SESSION", status().put("schema_version", "1"))
    }

    @Test fun unvalidatedAndInjectedUrlsNeverReachTheBrowser() {
        for (url in listOf("http://auth.openai.com/device", "https://auth.openai.com.evil.invalid/device",
            "https://evil.invalid@auth.openai.com/device", "https://auth.openai.com:444/device",
            "https://auth.openai.com/device#code", "javascript:alert(1)", "intent://auth.openai.com/device",
            "https://claude.ai/oauth/authorize", "https://auth.openai.com/device\nhttps://evil.invalid",
            "https://auth.openai.com/device?access_token=private", "https://auth.openai.com/device?%61ccess_token=private",
            "https://auth.openai.com/device?STATE=ok&ToKeN=private", "https://auth.openai.com/device?%=bad")) {
            refused("E_AUTH_URL_UNAVAILABLE", status(url = url))
        }
        refused("E_AUTH_URL_UNAVAILABLE", status().apply { getJSONObject("login").remove("verification_url") })
    }

    @Test fun browserFailureIsSanitized() {
        val failure = assertThrows(BridgeFailure::class.java) {
            HarnessAuthorizationRoutes.open(request, status()) { throw IllegalStateException("url?token=private") }
        }
        assertEquals("E_AUTH_BROWSER_UNAVAILABLE", failure.code)
        assertEquals("E_AUTH_BROWSER_UNAVAILABLE", BridgeProtocol.failureMessage(failure, failure.code))
    }
}
