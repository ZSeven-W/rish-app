package tech.zseven.rish

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import tech.zseven.rish.runtime.AndroidConfiguredModelIdentity

/**
 * What a configured provider may call the model it served, mirroring iOS's
 * ConfiguredProviderTransport. Relays answer in three ways this host used to
 * refuse: a dated Messages id, no id at all, and the exact id. Only the
 * first two are new; the third was the whole rule before.
 */
class ConfiguredModelIdentityTest {
    private val m = AndroidConfiguredModelIdentity

    @Test fun theExactWireModelMatchesOnEveryProtocol() {
        for (protocol in listOf("messages", "responses", "chat-completions")) {
            assertTrue(protocol, m.matches(protocol, "claude-sonnet-4-5", "claude-sonnet-4-5"))
            assertTrue(protocol, m.matches(protocol, "deepseek-chat", "deepseek-chat"))
        }
    }

    @Test fun aDatedFormIsTheSameModelOnMessagesOnly() {
        assertTrue(m.matches("messages", "claude-sonnet-4-5", "claude-sonnet-4-5-20250929"))
        assertFalse(m.matches("responses", "gpt-5.6", "gpt-5.6-2026-01-01"))
        assertFalse(m.matches("chat-completions", "gpt-5.6", "gpt-5.6-2026-01-01"))
        // The dash is the boundary, as on iOS: a longer name without it is
        // another model, while a dashed suffix -- date or otherwise -- is the
        // same one (iOS accepts `claude-sonnet-4` answered as
        // `claude-sonnet-4-5`, and so does this).
        assertFalse(m.matches("messages", "claude-sonnet-4-5", "claude-sonnet-4-5x"))
        assertTrue(m.matches("messages", "claude-sonnet-4", "claude-sonnet-4-5"))
    }

    @Test fun anAbsentModelIsAcceptedOffChatCompletions() {
        assertTrue(m.matches("messages", "claude-sonnet-4-5", null))
        assertTrue(m.matches("messages", "claude-sonnet-4-5", ""))
        assertTrue(m.matches("responses", "gpt-5.6", null))
        assertFalse(m.matches("chat-completions", "gpt-5.6", null))
        assertFalse(m.matches("chat-completions", "gpt-5.6", ""))
        // A model that is not text is not a model.
        assertFalse(m.matches("messages", "claude-sonnet-4-5", 7))
        assertFalse(m.matches("messages", "claude-sonnet-4-5", true))
    }

    @Test fun anotherModelIsRefusedEverywhere() {
        assertFalse(m.matches("messages", "claude-sonnet-4-5", "claude-opus-4-1"))
        assertFalse(m.matches("responses", "gpt-5.6", "gpt-5.6-mini"))
        assertFalse(m.matches("chat-completions", "deepseek-chat", "deepseek-reasoner"))
    }
}
