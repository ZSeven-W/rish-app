package tech.zseven.rish

import androidx.test.ext.junit.runners.AndroidJUnit4
import tech.zseven.rish.runtime.AndroidSubscriptionAuthStatusParser
import tech.zseven.rish.runtime.AndroidSubscriptionAuthProtocol
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidSubscriptionAuthStatusParserTest {
    @Test
    fun authorizingUsesSubscriptionAuthMethod() {
        assertEquals("subscription", AndroidSubscriptionAuthProtocol.authMethodForStatus("authorizing"))
        assertEquals("subscription", AndroidSubscriptionAuthProtocol.authMethodForStatus("signed_in"))
        assertEquals("none", AndroidSubscriptionAuthProtocol.authMethodForStatus("signed_out"))
        assertEquals("none", AndroidSubscriptionAuthProtocol.authMethodForStatus("unavailable"))
    }

    @Test
    fun acceptsOnlyKnownChatGptStatusMethod() {
        val result = AndroidSubscriptionAuthStatusParser.parse(
            "codex",
            "{\"loggedIn\":true,\"authMethod\":\"chatgpt\",\"email\":\"account@example.invalid\",\"planType\":\"plus\"}",
            0,
        )
        assertEquals("signed_in", result.status)
        assertEquals("account@example.invalid", result.account)
        assertEquals("plus", result.plan)
    }

    @Test
    fun rejectsApiKeyAndArbitraryNestedMethodFields() {
        val apiKey = AndroidSubscriptionAuthStatusParser.parse(
            "codex", "{\"loggedIn\":true,\"authMethod\":\"apiKey\"}", 0
        )
        assertEquals("signed_out", apiKey.status)
        val forged = AndroidSubscriptionAuthStatusParser.parse(
            "codex", "{\"loggedIn\":true,\"account\":{\"method\":\"chatgpt\",\"name\":\"plus\"}}", 0
        )
        assertEquals("error", forged.status)
        assertNull(forged.account)
        val malformed = AndroidSubscriptionAuthStatusParser.parse(
            "codex", "{\"loggedIn\":\"true\",\"authMethod\":\"chatgpt\"}", 0
        )
        assertEquals("error", malformed.status)
        val failedPositive = AndroidSubscriptionAuthStatusParser.parse(
            "codex", "{\"loggedIn\":true,\"authMethod\":\"chatgpt\"}", 2
        )
        assertEquals("error", failedPositive.status)
        assertEquals("signed_out", AndroidSubscriptionAuthStatusParser.parse("codex", "Not logged in", 1).status)
        assertEquals("error", AndroidSubscriptionAuthStatusParser.parse("codex", "unexpected failure", 1).status)
    }

    @Test
    fun claudeRequiresStructuredStatusAndCodexHumanLineIsExact() {
        val claudeText = AndroidSubscriptionAuthStatusParser.parse("claude-code", "Logged in", 0)
        assertEquals("error", claudeText.status)
        assertEquals("status_unverified", claudeText.errorCode)
        val codexText = AndroidSubscriptionAuthStatusParser.parse("codex", "Logged in using ChatGPT", 0)
        assertEquals("signed_in", codexText.status)
    }
}
