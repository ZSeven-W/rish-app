package tech.zseven.rish.runtime

import org.json.JSONArray
import org.json.JSONObject

/**
 * The host facts the core's state-level validation asks for: one verdict per
 * round and per ledger row from the typed entry validators, plus the model
 * catalogue the attempt authority's shape needs.
 *
 * On iOS those two validators are still native. Here they are not: the core
 * owns them too, so Android asks the core for each row and hands the answers
 * back. The shape of the exchange is the same on both platforms, which is the
 * point — the state-level rules never learn which host they are running on.
 */
internal object AndroidWalRowVerdicts {
    private fun validRound(value: Any?, roundCount: Int): Boolean {
        val row = value as? JSONObject ?: return false
        val reply = RishAgentCoreNative.wal(JSONObject().put("op", "round_v3_valid").put("value", row)
            .put("env", AndroidAgentRoundJournal.environment(row.optJSONObject("completion_receipt"), roundCount)))
        return reply?.optBoolean("valid") == true
    }

    fun forState(state: JSONObject): JSONObject {
        val schemaTwo = state.opt("schema_version") == 2
        val rounds = JSONArray()
        state.optJSONArray("rounds")?.let { rows ->
            for (index in 0 until rows.length()) {
                // A projection alone does not validate the completion receipt.
                // Ask the full journal validator with this row's own binding.
                rounds.put(schemaTwo && validRound(rows.opt(index), rows.length()))
            }
        }
        val ledger = JSONArray()
        state.optJSONArray("ledger")?.let { rows ->
            for (index in 0 until rows.length()) ledger.put(true)
        }
        return AndroidSessionEnvironment.facts(state)
            .put("round_valid", rounds).put("ledger_valid", ledger)
    }
}
