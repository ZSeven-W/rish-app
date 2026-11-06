package tech.zseven.rish.gpui

import org.json.JSONArray
import org.json.JSONObject
import tech.zseven.rish.runtime.AndroidSubscriptionAuthProtocol

/** Rust supplies identity only; the current native login owns the browser URL. */
internal object HarnessAuthorizationRoutes {
    data class Request(val harnessId: String, val sessionId: String)

    fun handles(module: String, method: String): Boolean =
        module == "LocalRuntime" && method == "openHarnessAuthorization"

    fun request(args: JSONArray): Request {
        if (args.length() != 2 || args.opt(0) !is String || args.opt(1) !is String) {
            throw BridgeFailure("E_BRIDGE_ARGUMENTS")
        }
        val harness = args.getString(0)
        val session = args.getString(1)
        if (!AndroidSubscriptionAuthProtocol.supports(harness)) throw BridgeFailure("E_AUTH_HARNESS")
        if (session.length !in 1..128 || session.any { it <= ' ' || it == '\u007f' }) {
            throw BridgeFailure("E_BRIDGE_ARGUMENTS")
        }
        return Request(harness, session)
    }

    fun resolve(request: Request, status: JSONObject): String {
        val runtime = status.optJSONObject("runtime")
        val login = status.optJSONObject("login")
        if (status.opt("schema_version") != 1 || status.opt("harness_id") != request.harnessId ||
            status.opt("status") != "authorizing" || runtime?.opt("available") != true ||
            runtime?.opt("kind") != "official-cli" || login?.opt("session_id") != request.sessionId) {
            throw BridgeFailure("E_AUTH_STALE_SESSION")
        }
        val url = login?.opt("verification_url") as? String
        if (url == null || !AndroidSubscriptionAuthProtocol.isVerificationUrl(request.harnessId, url)) {
            throw BridgeFailure("E_AUTH_URL_UNAVAILABLE")
        }
        return url
    }

    fun open(request: Request, status: JSONObject, launch: (String) -> Unit): JSONObject {
        val url = resolve(request, status)
        try { launch(url) } catch (_: Exception) { throw BridgeFailure("E_AUTH_BROWSER_UNAVAILABLE") }
        return JSONObject().put("status", "opened")
    }
}
