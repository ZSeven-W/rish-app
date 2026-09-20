package tech.zseven.rish.runtime

import android.content.Context
import org.json.JSONObject

/**
 * A git HTTPS credential for one (project, host): what the native prompt
 * stores and what a push reads. `DSHGitCredentialForScope` on iOS, in the
 * Keychain there; here the same AES-in-Keystore store the provider keys use,
 * under its own namespace and account shape, so a project's token cannot
 * be read as a provider key or vice versa.
 *
 * The token never leaves native code: the status a caller sees carries the
 * host, whether a credential exists and when it expires, nothing else. An
 * expired credential reads as absent and is removed when met.
 */
internal class AndroidGitCredentials(context: Context, namespace: String = "rish.git-credentials.v1") {
    private val store = AndroidCredentialStore(context, namespace, ACCOUNT)

    data class Credential(val username: String, val token: String, val expiresAt: Long, val expirySeconds: Long)

    private fun account(projectId: String, host: String): String {
        require(RuntimeJson.uuid(projectId) && validHost(host))
        return "git:$projectId:$host"
    }

    fun store(projectId: String, host: String, username: String, token: String, expirySeconds: Long, now: Long = nowSeconds()) {
        require(expirySeconds in EXPIRIES) { "expiry is not one of the offered windows" }
        require(username.isNotEmpty() && username.toByteArray(Charsets.UTF_8).size <= 256 && username.none { it.isISOControl() })
        require(token.isNotEmpty() && token.toByteArray(Charsets.UTF_8).size <= 4096 && token.none { it.isISOControl() })
        val record = JSONObject().put("schema_version", 1).put("username", username).put("token", token)
            .put("expires_at", now + expirySeconds).put("expiry_seconds", expirySeconds)
        store.put(account(projectId, host), record.toString())
    }

    /** The credential, or null when there is none or it has expired. */
    fun read(projectId: String, host: String, now: Long = nowSeconds()): Credential? {
        val slot = account(projectId, host)
        val raw = try { store.get(slot) } catch (_: Exception) { null } ?: return null
        val record = try { JSONObject(raw) } catch (_: Exception) { null }
        val expiresAt = record?.optLong("expires_at", -1L) ?: -1L
        if (record == null || record.optInt("schema_version") != 1 || expiresAt <= now) {
            store.clear(slot)
            return null
        }
        return Credential(
            record.optString("username"), record.optString("token"), expiresAt, record.optLong("expiry_seconds"),
        )
    }

    fun clear(projectId: String, host: String) = store.clear(account(projectId, host))

    /** What React Native is told: presence and expiry, never the secret. */
    fun status(projectId: String, host: String): JSONObject {
        val credential = read(projectId, host)
        val status = JSONObject().put("schema_version", 1).put("project_id", projectId).put("host", host)
            .put("configured", credential != null)
        credential?.let { status.put("expires_at", it.expiresAt).put("expiry_seconds", it.expirySeconds) }
        return status
    }

    companion object {
        /** The windows the prompt offers, as iOS offers them: one hour, one day, seven days. */
        val EXPIRIES = setOf(3600L, 24 * 3600L, 7 * 24 * 3600L)
        private val ACCOUNT = Regex("git:[0-9a-f-]{36}:[a-z0-9.-]{1,253}")
        fun validHost(host: String): Boolean = Regex("[a-z0-9.-]{1,253}").matches(host) && '.' in host || host == "localhost" || Regex("[0-9.]{7,15}").matches(host)
        private fun nowSeconds(): Long = System.currentTimeMillis() / 1000
    }
}
