package tech.zseven.rish.runtime

import android.system.Os
import org.json.JSONArray
import org.json.JSONObject
import tech.zseven.rish.guest.GuestRuntimeState
import java.io.File
import java.net.URI

/**
 * Where the guest's package mirrors are staged, on Android.
 *
 * This writes the same three files iOS writes, into the same overlay, and
 * answers with the same receipt: `LocalMirrorsModule.mm` is the contract and
 * this is the other implementation of it, not a variation on it.
 *
 * **What staging is not.** The files land in an app-private overlay and stay
 * there. The interpreter has no block-device injection, so nothing here
 * reaches a booted guest, which keeps using the offline repository baked into
 * its initramfs — that is what `staged_config_enters_guest: false` says, and
 * it is false on both platforms for the same reason. `guest_runtime_mounted`
 * is a separate fact about this process, not a claim about these files.
 */
internal class AndroidMirrorStore(private val home: File) {

    class Refused(val code: String, val reason: String) : Exception(reason)

    private data class Category(
        val name: String,
        val logicalPath: String,
        val defaultBase: String,
    )

    private val categories = listOf(
        Category("alpine", "etc/apk/repositories", "https://dl-cdn.alpinelinux.org/alpine/"),
        Category("pip", "etc/pip/pip.conf", "https://pypi.org/simple/"),
        Category("npm", "root/.npmrc", "https://registry.npmjs.org/"),
    )

    /** Stages the three configurations and answers the receipt it wrote. */
    fun apply(mirrors: JSONObject?): JSONObject {
        val requested = mirrors ?: throw Refused(BAD_ARGUMENTS, "Mirror configuration is missing")
        // Three categories, no more and no fewer: an extra key is a request
        // this version does not understand, not something to ignore.
        if (requested.length() != categories.size) {
            throw Refused(BAD_ARGUMENTS, "Mirror configuration must contain three categories")
        }
        val entries = categories.map { category -> entry(requested, category) }
        val root = overlayRoot()
        val bases = entries.associate { it.getString("category") to it.getString("base_url") }
        write(root, "etc/apk/repositories", buildString {
            append(bases.getValue("alpine")).append("v3.21/main\n")
            append(bases.getValue("alpine")).append("v3.21/community\n")
        })
        write(
            root, "etc/pip/pip.conf",
            "[global]\nbreak-system-packages = true\nindex-url = ${bases.getValue("pip")}\n",
        )
        write(root, "root/.npmrc", "registry=${bases.getValue("npm")}\n")

        val receipt = JSONObject()
            .put("schema_version", 1)
            .put("status", "staged")
            .put("staged_at", AndroidClock.now())
            .put("guest_runtime_mounted", GuestRuntimeState.guestRuntimeMounted)
            .put("staged_config_enters_guest", false)
            .put("root", OVERLAY)
            .put("entries", JSONArray(entries))
        write(root, MANIFEST, receipt.toString(2))
        return receipt
    }

    /** The receipt of the last staging, or null if nothing was ever staged. */
    fun status(): JSONObject? {
        val manifest = File(overlayRoot(), MANIFEST)
        if (!manifest.isFile) return null
        val text = try {
            manifest.readText()
        } catch (failure: Exception) {
            throw Refused(PERSISTENCE, "Stored mirror manifest could not be read")
        }
        return try {
            JSONObject(text)
        } catch (_: org.json.JSONException) {
            throw Refused(CORRUPT, "Stored mirror manifest is invalid")
        }
    }

    private fun entry(mirrors: JSONObject, category: Category): JSONObject {
        val raw = mirrors.optJSONObject(category.name)
            ?: throw Refused(BAD_ARGUMENTS, "Mirror configuration is invalid")
        // `optBoolean` cannot tell false from absent, and an absent flag is a
        // malformed request rather than a disabled mirror.
        if (!raw.has("enabled") || raw.opt("enabled") !is Boolean) {
            throw Refused(BAD_ARGUMENTS, "Mirror configuration is invalid")
        }
        val enabled = raw.getBoolean("enabled")
        // The URL is validated whether or not the mirror is enabled: a
        // disabled mirror with a broken URL is still a broken preference, and
        // iOS refuses it too.
        val base = normalizedHttpsBase(raw.opt("baseUrl"))
        return JSONObject()
            .put("category", category.name)
            .put("enabled", enabled)
            .put("base_url", if (enabled) base else category.defaultBase)
            .put("logical_path", category.logicalPath)
    }

    /**
     * An HTTPS base URL with no credentials, query or fragment, and a
     * trailing slash so the paths below it concatenate.
     */
    private fun normalizedHttpsBase(value: Any?): String {
        val raw = value as? String
        if (raw.isNullOrEmpty() || raw.toByteArray(Charsets.UTF_8).size > MAX_URL_BYTES) {
            throw Refused(BAD_ARGUMENTS, "Mirror URL is invalid")
        }
        val uri = try {
            URI(raw)
        } catch (_: Exception) {
            throw Refused(BAD_ARGUMENTS, "Mirror URL is invalid")
        }
        if (!uri.isAbsolute ||
            !"https".equals(uri.scheme, ignoreCase = true) ||
            uri.host.isNullOrEmpty() ||
            !uri.userInfo.isNullOrEmpty() ||
            !uri.query.isNullOrEmpty() ||
            !uri.fragment.isNullOrEmpty()
        ) {
            throw Refused(
                BAD_ARGUMENTS,
                "Mirror URL must be a credential-free HTTPS base URL",
            )
        }
        val normalized = uri.toASCIIString()
        return if (normalized.endsWith("/")) normalized else "$normalized/"
    }

    private fun overlayRoot(): File {
        val root = File(home, OVERLAY)
        if (!root.isDirectory && !root.mkdirs()) {
            throw Refused(PERSISTENCE, "Mirror overlay could not be created")
        }
        private0700(root)
        return root
    }

    private fun write(root: File, relative: String, text: String) {
        val target = File(root, relative)
        val parent = target.parentFile ?: throw Refused(PERSISTENCE, "Mirror path is invalid")
        if (!parent.isDirectory && !parent.mkdirs()) {
            throw Refused(PERSISTENCE, "Mirror overlay could not be created")
        }
        private0700(parent)
        val staging = File(parent, "${target.name}.staging")
        try {
            staging.writeText(text)
            private0600(staging)
            if (!staging.renameTo(target)) {
                target.delete()
                if (!staging.renameTo(target)) {
                    throw Refused(PERSISTENCE, "Mirror configuration could not be staged")
                }
            }
        } catch (refused: Refused) {
            staging.delete()
            throw refused
        } catch (failure: Exception) {
            staging.delete()
            throw Refused(PERSISTENCE, "Mirror configuration could not be staged")
        }
        private0600(target)
    }

    // The app sandbox already keeps other apps out; these narrow the mode the
    // way iOS does, so the overlay reads the same from inside the guest tree.
    private fun private0700(target: File) = chmod(target, "700")

    private fun private0600(target: File) = chmod(target, "600")

    private fun chmod(target: File, mode: String) {
        try {
            Os.chmod(target.absolutePath, mode.toInt(8))
        } catch (_: Exception) {
            // A filesystem that will not take a mode is not a reason to fail
            // the staging: the sandbox is the real boundary.
        }
    }

    private companion object {
        const val OVERLAY = "rish-guest-overlay"
        const val MANIFEST = "mirrors.json"
        const val MAX_URL_BYTES = 2048
        const val BAD_ARGUMENTS = "E_MIRRORS_INVALID"
        const val PERSISTENCE = "E_MIRRORS_PERSISTENCE"
        const val CORRUPT = "E_MIRRORS_CORRUPT"
    }
}
