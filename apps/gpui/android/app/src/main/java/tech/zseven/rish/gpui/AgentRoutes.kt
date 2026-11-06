package tech.zseven.rish.gpui

import org.json.JSONArray
import org.json.JSONObject
import tech.zseven.rish.runtime.*

internal object AgentRoutes {
    fun agent(runtime: AndroidRuntimeState, method: String, args: JSONArray): Any? {
        if (method == "getConstants") return JSONObject().put("implemented", RishAgentCoreNative.available)
        if (method in setOf("addListener", "removeListeners")) return null
        if (!RishAgentCoreNative.available) throw BridgeFailure("E_AGENT_UNAVAILABLE")
        val request = args.getJSONObject(0)
        return when (method) {
            "prepare_agent_attempt" -> runtime.transport.withProviderLock { runtime.preparedAttempts.prepareAgentAttempt(request) }
            "complete_agent_round_v2" -> runtime.providerRound.completeRound(request)
            "prepare_agent_tool_batch" -> runtime.toolBatch.prepare(request)
            "bind_agent_approval" -> runtime.approvals.bind(request)
            "execute_agent_tool" -> runtime.toolExecution.execute(request)
            "interrupt_agent_attempt" -> runtime.lifecycle.interrupt(request)
            "cancel_agent_attempt" -> runtime.cancellation.cancel(request)
            "read_agent_round_presentations" -> runtime.queries.readRoundPresentations(request)
            "query_agent_attempt" -> runtime.queries.query(request)
            "query_agent_tool" -> runtime.queries.queryTool(request)
            "recover_agent_attempt" -> runtime.recovery.recover(request)
            "finalize_agent_attempt" -> runtime.lifecycle.finalize(request)
            "discard_agent_attempt" -> runtime.lifecycle.discard(request)
            "query_agent_cleanup" -> runtime.queries.queryCleanup(request)
            else -> throw BridgeFailure("E_AGENT_UNAVAILABLE")
        }
    }

    fun context(runtime: AndroidRuntimeState, method: String, args: JSONArray): JSONObject {
        val available = RishAgentCoreNative.available && RishLibgit2Native.available
        if (method == "getConstants") return JSONObject().put("implemented", available)
        if (!available) throw BridgeFailure("E_CONTEXT_NATIVE")
        if (method == "discardProjectContext") return runtime.projectSnapshots.discardById(args.optString(0))
        val request = args.getJSONObject(0)
        return WorkspaceRoutes.holding(runtime, request) {
            when (method) {
                "listCandidatesV2" -> runtime.projectContext.listCandidates(request)
                "prepareCandidateV2" -> runtime.projectSnapshots.prepare(request)
                "confirmSnapshotV2" -> runtime.projectSnapshots.confirm(request)
                "inspectSnapshotV2" -> runtime.projectSnapshots.inspect(request)
                "discardProjectContextV2" -> runtime.projectSnapshots.discard(request)
                "verifiedSendProjectContextV2" -> runtime.projectSnapshots.verifiedEnvelope(request, true).second
                else -> throw BridgeFailure("E_CONTEXT_NATIVE")
            }
        }
    }
}
