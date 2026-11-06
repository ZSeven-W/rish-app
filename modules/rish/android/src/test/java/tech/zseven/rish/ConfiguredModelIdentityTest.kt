package tech.zseven.rish

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.json.JSONObject
import tech.zseven.rish.runtime.AndroidConfiguredModelIdentity

/**
 * What a configured provider may call the model it served, mirroring iOS's
 * ConfiguredProviderTransport. The selected model remains authoritative;
 * a relay's reported model is optional, bounded display metadata.
 */
class ConfiguredModelIdentityTest {
    private val m = AndroidConfiguredModelIdentity

    @Test fun theExactWireModelMatchesOnEveryProtocol() {
        for (protocol in listOf("messages", "responses", "chat-completions")) {
            assertTrue(protocol, m.matches(protocol, "claude-sonnet-4-5", "claude-sonnet-4-5"))
            assertTrue(protocol, m.matches(protocol, "deepseek-chat", "deepseek-chat"))
        }
    }

    @Test fun configuredRelaysMayReportDatedOrReroutedNames() {
        for (protocol in listOf("messages", "responses", "chat-completions")) {
            for (reported in listOf("gpt-5.6-2026-01-01", "claude-opus-4-1", "relay/model", "深度模型")) {
                assertTrue(protocol, m.matches(protocol, "chosen-model", reported))
            }
        }
    }

    @Test fun aConfiguredRelayMayOmitTheReportedModel() {
        for (protocol in listOf("messages", "responses", "chat-completions")) {
            for (reported in listOf(null, JSONObject.NULL, "")) {
                assertTrue(protocol, m.matches(protocol, "chosen-model", reported))
            }
        }
    }

    @Test fun nonTextControlsAndOversizedReportedNamesAreRefused() {
        for (protocol in listOf("messages", "responses", "chat-completions")) {
            assertTrue(protocol, m.matches(protocol, "chosen-model", "m".repeat(256)))
            for (reported in listOf(7, true, JSONObject(), "m".repeat(257), "model\nname", "model\u0000", "\u007fmodel", "model\u0085")) {
                assertFalse(protocol, m.matches(protocol, "chosen-model", reported))
            }
        }
    }
}
