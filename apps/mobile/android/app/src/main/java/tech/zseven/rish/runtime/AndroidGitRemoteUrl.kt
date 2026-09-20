package tech.zseven.rish.runtime

/**
 * Which remote addresses this app will talk to, the same rule on both
 * platforms (`DSHGitValidatedRemoteURL`): https to a public DNS name on 443,
 * or plain http to a private literal (a test remote on this device or the
 * LAN); never a user, password, query or fragment.
 */
internal object AndroidGitRemoteUrl {
    /** The URL with scheme and host lowercased, or null when it is not one this app pushes to. */
    fun validated(value: Any?): String? {
        val text = value as? String ?: return null
        if (text.isEmpty() || text.length > 2048 || text.any { it.isISOControl() || it.isWhitespace() }) return null
        val uri = try { java.net.URI(text) } catch (_: Exception) { return null }
        val scheme = uri.scheme?.lowercase() ?: return null
        val host = uri.host?.lowercase() ?: return null
        if (uri.userInfo != null || uri.rawQuery != null || uri.rawFragment != null) return null
        val httpsValid = scheme == "https" && publicDnsName(host) && (uri.port == -1 || uri.port == 443)
        val httpValid = scheme == "http" && privateLiteral(host) && (uri.port == -1 || uri.port in 1..65535)
        if (!httpsValid && !httpValid) return null
        val port = if (uri.port == -1) "" else ":${uri.port}"
        return "$scheme://$host$port${uri.rawPath ?: ""}"
    }

    fun publicDnsName(host: String): Boolean =
        Regex("[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+").matches(host) &&
            !host.endsWith(".local") && !host.endsWith(".localhost") && !privateLiteral(host)

    fun privateLiteral(host: String): Boolean {
        if (host == "localhost") return true
        val parts = host.split(".")
        if (parts.size == 4 && parts.all { it.toIntOrNull()?.let { n -> n in 0..255 } == true }) {
            val a = parts[0].toInt(); val b = parts[1].toInt()
            return a == 127 || a == 10 || (a == 192 && b == 168) || (a == 172 && b in 16..31) || (a == 169 && b == 254)
        }
        val v6 = host.removePrefix("[").removeSuffix("]")
        return v6 == "::1" || v6.startsWith("fe80:") || v6.startsWith("fc") || v6.startsWith("fd")
    }

    fun hostOf(url: String): String = java.net.URI(url).host?.lowercase() ?: ""
}
