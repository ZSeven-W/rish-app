package tech.zseven.rish.runtime

import java.net.URI

/**
 * The HTTPS proxy a person set for Git, judged the way iOS judges it
 * (`LPValidatedHTTPSProxyURL`): an `http` or `https` proxy with a host and an
 * explicit port, and nothing else -- no path, no user or password (proxy
 * authentication is not supported), no query or fragment. Answers the one
 * canonical spelling, `scheme://host:port/`, so both hosts hand libgit2 the
 * same string.
 */
internal object AndroidGitProxyUrl {

    /** Not a proxy URL this app accepts. */
    class Invalid : Exception("https proxy url is invalid")

    /**
     * The canonical proxy for a request's `https_proxy_url`: null for JSON
     * null (no proxy), the canonical string for a valid one, and [Invalid]
     * for anything else -- including a missing key, which the request's
     * exact key set already refuses.
     */
    fun canonical(value: Any?): String? {
        if (value == null || value == org.json.JSONObject.NULL) return null
        val text = value as? String ?: throw Invalid()
        if (text.isEmpty() || text.length > 2048 || text != text.trim() || text.any { it.isISOControl() }) {
            throw Invalid()
        }
        val uri = try { URI(text) } catch (_: Exception) { throw Invalid() }
        val scheme = uri.scheme?.lowercase()
        val host = uri.host
        val path = uri.rawPath
        if ((scheme != "http" && scheme != "https") || host.isNullOrEmpty() || host.any { it.isISOControl() } ||
            uri.port !in 1..65535 || !(path.isNullOrEmpty() || path == "/") ||
            uri.rawUserInfo != null || uri.rawQuery != null || uri.rawFragment != null
        ) {
            throw Invalid()
        }
        return "$scheme://${host.lowercase()}:${uri.port}/"
    }

    /**
     * libgit2 sends a plain `http://` remote straight to the origin even when
     * a proxy is configured, so a proxy with such a remote would be a promise
     * the transport does not keep. Only the test remote is http here.
     */
    fun usableWith(proxy: String?, remoteUrl: String): Boolean =
        proxy == null || remoteUrl.lowercase().startsWith("https://")
}
