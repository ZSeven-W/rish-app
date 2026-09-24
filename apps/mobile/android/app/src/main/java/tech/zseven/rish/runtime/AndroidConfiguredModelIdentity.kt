package tech.zseven.rish.runtime

/**
 * Whether the model a configured (third-party) provider reports can be
 * accepted. The rule is iOS's `ConfiguredProviderTransport`, kept here as one
 * function so the two hosts cannot drift apart again.
 *
 * A relay the person configured answers for the model they chose, under
 * whatever name it uses: OpenAI-compatible APIs report dated names
 * (`gpt-4o` as `gpt-4o-2024-08-06`), and relays that redirect a model report
 * the one they routed to. Refusing every such name made custom relays fail
 * after the answer had already arrived -- "only Claude works", because
 * Anthropic-compatible relays tend to echo the name back (2026-09-24).
 *
 * So any bounded, printable name is accepted, and so is none at all. The
 * name never selects a harness, a capability or the conversation's model:
 * the caller keeps the chosen model on the receipt and logs what the relay
 * reported. What is refused is a reply whose `model` is not text.
 */
internal object AndroidConfiguredModelIdentity {
    private const val MAX_REPORTED_MODEL_CHARS = 256

    @Suppress("UNUSED_PARAMETER")
    fun matches(protocol: String, wireModel: String, reported: Any?): Boolean {
        if (reported == null || reported == org.json.JSONObject.NULL) return true
        val text = reported as? String ?: return false
        return text.isEmpty() ||
            (text.length <= MAX_REPORTED_MODEL_CHARS && text.none { it.isISOControl() })
    }
}
