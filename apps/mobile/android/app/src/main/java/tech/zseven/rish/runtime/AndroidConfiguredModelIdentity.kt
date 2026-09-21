package tech.zseven.rish.runtime

/**
 * Whether the model a configured (third-party) provider reports is the one
 * that was asked for. The rule is iOS's `ConfiguredProviderTransport`, kept
 * here as one function so the two hosts cannot drift apart again:
 *
 * - exactly the mapped wire model, on any protocol;
 * - on Messages, the wire model with a dated suffix (`<model>-<anything>`),
 *   which is how Anthropic-compatible relays spell the model they served;
 * - no model at all (absent or empty) on Messages and Responses, where the
 *   field is not part of the contract; Chat Completions must name one.
 *
 * Anything else is a different model, and the reply is refused.
 */
internal object AndroidConfiguredModelIdentity {
    fun matches(protocol: String, wireModel: String, reported: Any?): Boolean {
        val chat = protocol == "chat-completions"
        val messages = protocol == "messages"
        val text = reported as? String
        if (text == null || text.isEmpty()) return !chat && reported !is Number && reported !is Boolean
        if (text == wireModel) return true
        return messages && text.startsWith("$wireModel-")
    }
}
