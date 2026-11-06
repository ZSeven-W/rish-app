package tech.zseven.rish.runtime

import org.json.JSONArray
import org.json.JSONObject
import java.security.SecureRandom
import java.text.Normalizer
import java.util.Base64
import java.util.Locale
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * The candidates a project offers as context, and a page of them.
 *
 * Reading the repository is [RishLibgit2Native.readRepositoryState]; deciding
 * a path is [AndroidProjectContextPolicy] and, under it, the shared core.
 * What this adds is the rules iOS applies between the two: what makes an
 * index entry a candidate, how a conflict is reported, the order candidates
 * come in, how a query narrows them, and a cursor that can only continue the
 * listing it was issued for.
 */
internal class AndroidProjectCandidates {
    class Refused(val code: String, val reason: String) : Exception(reason)

    /** Everything the listing read, so a cursor can tell if it changed. */
    class Capture(val candidates: List<JSONObject>, val sourceFingerprint: String)

    // Issued per process, as iOS does: a cursor is a continuation of one
    // listing on one device, not a value with meaning anywhere else.
    private val cursorKey = ByteArray(32).also { SecureRandom().nextBytes(it) }

    /**
     * Reads the repository at [workDir] -- through the private [gitDir] when
     * it is a workspace's project -- and decides every entry once.
     */
    fun capture(gitDir: String?, workDir: String): Capture {
        if (!RishLibgit2Native.require()) throw Refused(UNAVAILABLE, "libgit2 is not available")
        val state = JSONObject(RishLibgit2Native.readRepositoryState(gitDir, workDir))
        if (!state.optBoolean("ok")) {
            throw Refused(UNAVAILABLE, "repository could not be read at ${state.optString("stage")}")
        }
        val entries = state.getJSONArray("entries")
        if (entries.length() > MAX_ENTRIES) throw Refused(BUDGET, "too many index entries")
        val byPath = linkedMapOf<String, JSONObject>()
        val conflicted = linkedMapOf<String, JSONObject>()
        val rows = JSONArray()
        for (index in 0 until entries.length()) {
            val entry = entries.getJSONObject(index)
            val rawPath = entry.getString("path")
            val decision = AndroidProjectContextPolicy.decisionFor(rawPath)
            // A path the policy respells is a path two hosts would disagree
            // about; iOS refuses the whole listing rather than one entry.
            if (decision.normalizedPath.isEmpty() || decision.normalizedPath != rawPath) {
                throw Refused(INTEGRITY, "index path is not in normal form: $rawPath")
            }
            rows.put(
                JSONObject().put("path", rawPath).put("oid", entry.getString("oid"))
                    .put("stage", entry.getInt("stage"))
                    .put("staged", entry.getBoolean("staged"))
                    .put("unstaged", entry.getBoolean("unstaged")),
            )
            if (entry.getInt("stage") != 0) {
                // One side of an unresolved merge. The lowest stage seen is
                // the row reported; nothing about it is eligible.
                conflicted.putIfAbsent(
                    rawPath,
                    candidate(rawPath, entry, eligible = false, reason = POLICY, state = "conflicted"),
                )
                continue
            }
            val mode = entry.getInt("mode")
            val regular = mode == MODE_BLOB || mode == MODE_BLOB_EXECUTABLE
            val size = entry.getLong("size")
            val eligible = decision.eligible && regular && size <= MAX_FILE_BYTES
            val reason = when {
                decision.eligible && !regular -> POLICY
                decision.eligible && size > MAX_FILE_BYTES -> BUDGET_EXCEEDED
                else -> decision.omissionReason
            }
            val gitState = when {
                entry.getBoolean("unstaged") -> "unstaged"
                entry.getBoolean("staged") -> "staged"
                else -> "unchanged"
            }
            byPath[rawPath] = candidate(rawPath, entry, eligible, reason, gitState)
        }
        // A conflicted path replaces whatever its stage-zero row said.
        byPath.putAll(conflicted)
        val candidates = byPath.values.sortedWith(CANDIDATE_ORDER)
        val fingerprint = RuntimeJson.sha(
            RuntimeJson.canonical(
                JSONObject().put("policy_version", 1)
                    .put("repository_state", state.getInt("repository_state"))
                    .put("branch", state.opt("branch") ?: JSONObject.NULL)
                    .put("head_oid", state.opt("head") ?: JSONObject.NULL)
                    .put("index_checksum", state.opt("index_checksum") ?: "none")
                    .put("rows", rows),
            ),
        )
        return Capture(candidates, fingerprint)
    }

    private fun candidate(
        path: String,
        entry: JSONObject,
        eligible: Boolean,
        reason: String?,
        state: String,
    ): JSONObject = JSONObject().put("path", path).put("size", entry.getLong("size"))
        .put("revision", entry.getString("oid")).put("git_state", state)
        .put("eligible", eligible)
        // Exactly one of eligible and a reason, which is what the reader
        // checks: an eligible candidate has nothing to explain.
        .put("omission_reason", if (eligible) JSONObject.NULL else (reason ?: POLICY))

    /**
     * One page of a capture. `query` narrows by folded substring; `cursor`
     * continues an earlier page of the same listing under the same query, and
     * is refused if either has changed.
     */
    fun page(capture: Capture, query: String, cursor: String?, limit: Int = MAX_PAGE_SIZE): JSONObject {
        if (query.length > MAX_QUERY_CHARACTERS) throw Refused(INVALID, "query too long")
        val folded = fold(query)
        val scope = sha256(folded.toByteArray(Charsets.UTF_8))
        val filtered = capture.candidates.filter {
            folded.isEmpty() || fold(it.getString("path")).contains(folded)
        }
        val offset = if (cursor == null) 0 else decodeCursor(cursor, capture.sourceFingerprint, scope)
        if (offset > filtered.size) throw Refused(INVALID_CURSOR, "cursor is past the end")
        val end = minOf(filtered.size, offset + minOf(limit, MAX_PAGE_SIZE))
        val page = JSONArray()
        for (index in offset until end) page.put(filtered[index])
        val next = if (end < filtered.size) encodeCursor(capture.sourceFingerprint, end, scope) else JSONObject.NULL
        return JSONObject().put("candidates", page).put("next_cursor", next)
    }

    // A cursor is version(1) | offset(8, big-endian) | sha256(fingerprint)(32),
    // followed by an HMAC over that and the query scope. Same layout as iOS,
    // with a key that never leaves this process.
    private fun encodeCursor(fingerprint: String, offset: Int, scope: ByteArray): String {
        val payload = ByteArray(CURSOR_PAYLOAD_BYTES)
        payload[0] = CURSOR_VERSION
        var value = offset.toLong()
        for (index in 7 downTo 0) { payload[1 + index] = (value and 0xff).toByte(); value = value ushr 8 }
        System.arraycopy(sha256(fingerprint.toByteArray(Charsets.UTF_8)), 0, payload, 9, 32)
        return Base64.getUrlEncoder().withoutPadding().encode(payload + hmac(payload + scope))
            .toString(Charsets.US_ASCII)
    }

    private fun decodeCursor(cursor: String, fingerprint: String, scope: ByteArray): Int {
        val bytes = try {
            Base64.getUrlDecoder().decode(cursor)
        } catch (_: IllegalArgumentException) {
            throw Refused(INVALID_CURSOR, "cursor is not base64url")
        }
        if (bytes.size != CURSOR_PAYLOAD_BYTES + 32) throw Refused(INVALID_CURSOR, "cursor has the wrong length")
        val payload = bytes.copyOfRange(0, CURSOR_PAYLOAD_BYTES)
        val tag = bytes.copyOfRange(CURSOR_PAYLOAD_BYTES, bytes.size)
        if (!constantTimeEquals(tag, hmac(payload + scope)) || payload[0] != CURSOR_VERSION) {
            throw Refused(INVALID_CURSOR, "cursor was not issued here for this query")
        }
        val digest = sha256(fingerprint.toByteArray(Charsets.UTF_8))
        // A cursor that was issued here but for a different repository state
        // is stale rather than invalid: the listing moved under it.
        if (!constantTimeEquals(payload.copyOfRange(9, 41), digest)) {
            throw Refused(CHANGED, "the project changed since this cursor was issued")
        }
        var offset = 0L
        for (index in 1..8) offset = (offset shl 8) or (payload[index].toLong() and 0xff)
        if (offset > Int.MAX_VALUE) throw Refused(INVALID_CURSOR, "cursor offset is out of range")
        return offset.toInt()
    }

    private fun hmac(data: ByteArray): ByteArray = Mac.getInstance("HmacSHA256")
        .apply { init(SecretKeySpec(cursorKey, "HmacSHA256")) }.doFinal(data)

    private fun sha256(data: ByteArray): ByteArray =
        java.security.MessageDigest.getInstance("SHA-256").digest(data)

    private fun constantTimeEquals(left: ByteArray, right: ByteArray): Boolean {
        if (left.size != right.size) return false
        var difference = 0
        for (index in left.indices) difference = difference or (left[index].toInt() xor right[index].toInt())
        return difference == 0
    }

    /** The same folding the path policy uses, so a query matches as iOS matches. */
    private fun fold(value: String): String {
        val nfc = Normalizer.normalize(value, Normalizer.Form.NFC)
        return Normalizer.normalize(nfc.uppercase(Locale.ROOT).lowercase(Locale.ROOT), Normalizer.Form.NFC)
    }

    companion object {
        // The codes are the ones JavaScript branches on; a code it does not
        // know collapses to E_CONTEXT_NATIVE and tells the person nothing. A
        // malformed cursor is a bad request, as iOS reports it; a cursor from
        // another state of the project is [CHANGED].
        const val INVALID = "E_CONTEXT_REQUEST_INVALID"
        const val INVALID_CURSOR = "E_CONTEXT_REQUEST_INVALID"
        const val CHANGED = "E_CONTEXT_CHANGED"
        const val INTEGRITY = "E_CONTEXT_INTEGRITY"
        const val BUDGET = "E_CONTEXT_BUDGET"
        const val UNAVAILABLE = "E_PROJECT_NOT_FOUND"
        private const val POLICY = "policy"
        private const val BUDGET_EXCEEDED = "budget_exceeded"
        private const val MAX_FILE_BYTES = 64L * 1024
        private const val MAX_ENTRIES = 5000
        private const val MAX_PAGE_SIZE = 100
        private const val MAX_QUERY_CHARACTERS = 256
        private const val MODE_BLOB = 0b1000000110100100
        private const val MODE_BLOB_EXECUTABLE = 0b1000000111101101
        private const val CURSOR_VERSION: Byte = 1
        private const val CURSOR_PAYLOAD_BYTES = 41
        // path, then revision, then state, all by code unit, as iOS compares.
        private val CANDIDATE_ORDER = compareBy<JSONObject>({ it.getString("path") },
            { it.getString("revision") }, { it.getString("git_state") })
    }
}
