package tech.zseven.rish.runtime

import org.json.JSONObject

/**
 * `AgentPolicy.describe` on Android.
 *
 * Mirrors modules/rish/ios/Sources/AgentPolicyService.mm. It answers what the
 * agent may do in one workspace binding: which capabilities the root carries,
 * what access each tool has, and the write budget. It is read-only and for
 * display; every effect is revalidated natively when it happens.
 *
 * Without it the permissions sheet said "this app version cannot check
 * workspace permissions" and showed every tool as unverified -- on a build
 * where those tools run.
 *
 * The decisions are the core's `rish_agent_policy_reduce`: the request shape,
 * whether the resolved root is the one the request asked about, whether the
 * budget is well formed, and the projection itself. This file resolves the
 * root against this device's registry and hands the three facts over.
 */
internal class AndroidAgentPolicyService(
    private val roots: AndroidAgentRootResolver,
    private val registry: AndroidAgentToolRegistry,
) {
    class Refused(val code: String) : Exception(code)

    private fun policy(envelope: JSONObject): JSONObject =
        RishAgentCoreNative.agentPolicy(envelope) ?: throw Refused(NATIVE)

    fun describe(request: JSONObject): JSONObject {
        if (!policy(
                JSONObject().put("op", "request_shape").put("request", request),
            ).optBoolean("valid")
        ) {
            throw Refused(BAD_ARGUMENTS)
        }
        // A binding that will not resolve here is stale rather than invalid:
        // the request was well formed, and this device simply no longer holds
        // what it asked about.
        val root = roots.resolve(
            request.optString("workspace_id").takeIf { it.isNotEmpty() },
            request.opt("project_id") as? String,
            request.optInt("workspace_binding_revision", -1).takeIf { it >= 0 },
        ) ?: throw Refused(ROOT_STALE)
        // A resolver that answered for a different workspace, revision or
        // project answered a different question.
        if (roots.resolveAgentProjection(root) == null ||
            !policy(
                JSONObject().put("op", "root_matches_request")
                    .put("root", root).put("request", request),
            ).optBoolean("matches")
        ) {
            throw Refused(ROOT_STALE)
        }
        val tools = registry.registryForRoot(root)
        val budget = registry.policyForRoot(root)
        if (!registry.validateRegistry(tools, root) ||
            !policy(
                JSONObject().put("op", "budget_shape").put("policy", budget),
            ).optBoolean("valid")
        ) {
            throw Refused(NATIVE)
        }
        return policy(
            JSONObject().put("op", "projection").put("request", request)
                .put("root", root).put("registry", tools).put("policy", budget),
        ).optJSONObject("result") ?: throw Refused(NATIVE)
    }

    private companion object {
        const val BAD_ARGUMENTS = "E_AGENT_BAD_ARGUMENTS"
        const val ROOT_STALE = "E_AGENT_ROOT_STALE"
        const val NATIVE = "E_AGENT_NATIVE"
    }
}
