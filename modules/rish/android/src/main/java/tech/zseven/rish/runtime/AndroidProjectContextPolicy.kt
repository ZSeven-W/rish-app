package tech.zseven.rish.runtime

import org.json.JSONArray
import org.json.JSONObject
import java.text.Normalizer
import java.util.Locale

/**
 * Whether a relative path may be sent as project context.
 *
 * The tables -- which name is a secret, generated output, a lockfile or a
 * binary, and the order they are consulted in -- live in the shared core. What
 * this does is the work before the core is asked, which is also everything
 * that can differ between hosts: NFC normalization, Unicode case folding,
 * and the extension and stem rules. Those are frozen from iOS in
 * modules/rish/ios/Tests/Fixtures/project-path-decisions.json and replayed here.
 */
internal object AndroidProjectContextPolicy {
    /** NSString.length counts UTF-16 units, and so does Kotlin's. */
    private const val MAX_RELATIVE_PATH_CHARACTERS = 4096

    class Decision(
        val normalizedPath: String,
        val eligible: Boolean,
        val omissionReason: String?,
    )

    private fun nfc(value: String): String = Normalizer.normalize(value, Normalizer.Form.NFC)

    /**
     * iOS folds with CFStringFold, which is Unicode case *folding* rather
     * than lowercasing -- ß becomes ss, İ becomes i̇. Upper-then-lower in the
     * root locale is the nearest the JVM offers, and the fixture is what
     * says whether it is near enough.
     */
    private fun folded(value: String): String =
        nfc(nfc(value).uppercase(Locale.ROOT).lowercase(Locale.ROOT))

    /** Foundation's pathExtension, for a single component. */
    private fun extensionOf(component: String): String {
        val dot = component.lastIndexOf('.')
        return if (dot <= 0 || dot == component.length - 1) "" else component.substring(dot + 1)
    }

    /** Foundation's stringByDeletingPathExtension, for a single component. */
    private fun stemOf(component: String): String {
        val extension = extensionOf(component)
        return when {
            extension.isNotEmpty() -> component.substring(0, component.length - extension.length - 1)
            component.length > 1 && component.endsWith('.') -> component.dropLast(1)
            else -> component
        }
    }

    private fun foldedComponent(component: String): JSONObject {
        val fold = folded(component)
        return JSONObject().put("folded", fold)
            .put("extension", extensionOf(fold))
            .put("stem", stemOf(fold))
    }

    fun decisionFor(relativePath: String): Decision {
        // Bounded on the reported length before a character is read, as iOS
        // does: normalizing a hostile input that is about to be refused is
        // work for nothing.
        if (relativePath.isEmpty() || relativePath.length > MAX_RELATIVE_PATH_CHARACTERS) {
            return Decision("", false, "policy")
        }
        val normalized = nfc(relativePath)
        val parts = normalized.split("/")
        val filename = parts.last()
        val envelope = JSONObject().put("op", "path_decision")
            .put("path", relativePath)
            .put("normalized", normalized)
            .put("components", JSONArray().apply { parts.forEach { put(foldedComponent(it)) } })
            .put("filename", foldedComponent(filename))
            // The extension is folded *after* being taken, which is how the
            // policy has always spelled it.
            .put("filename_extension", folded(extensionOf(filename)))
        if (!RishAgentCoreNative.available) return Decision(normalized, false, "policy")
        val reply = RishAgentCoreNative.projectContextReduce(envelope.toString(), null)
            ?: return Decision(normalized, false, "policy")
        val answer = try { JSONObject(reply) } catch (_: Exception) { null }
        if (answer == null || !answer.optBoolean("ok")) return Decision(normalized, false, "policy")
        return Decision(
            answer.optString("normalized_path", normalized),
            answer.optBoolean("eligible"),
            if (answer.isNull("omission_reason")) null else answer.optString("omission_reason"),
        )
    }
}
