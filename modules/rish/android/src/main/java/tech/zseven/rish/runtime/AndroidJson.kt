package tech.zseven.rish.runtime

import org.json.JSONArray
import org.json.JSONObject

/**
 * Structural equality for org.json values.
 *
 * `JSONObject` and `JSONArray` inherit `Object.equals`, so `==` between two of
 * them compares references and is almost always false. Every place that asks
 * "is this the row the locator names" needs value equality, and getting it
 * wrong is silent: a lookup simply never matches, and the caller carries on as
 * if the row did not exist.
 */
internal object AndroidJson {
    fun equal(left: Any?, right: Any?): Boolean {
        if (left === right) return true
        if (left == null || right == null) return false
        if (left === JSONObject.NULL || right === JSONObject.NULL) {
            return left === JSONObject.NULL && right === JSONObject.NULL
        }
        if (left is JSONObject && right is JSONObject) {
            if (left.length() != right.length()) return false
            for (key in left.keys()) {
                if (!right.has(key) || !equal(left.opt(key), right.opt(key))) return false
            }
            return true
        }
        if (left is JSONArray && right is JSONArray) {
            if (left.length() != right.length()) return false
            for (index in 0 until left.length()) {
                if (!equal(left.opt(index), right.opt(index))) return false
            }
            return true
        }
        // JSON numbers cross the bridge as Integer, Long or Double depending on
        // how they were written, so compare them as numbers rather than boxes.
        if (left is Number && right is Number) {
            return left.toDouble() == right.toDouble()
        }
        return left == right
    }
}
