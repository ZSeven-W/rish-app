package tech.zseven.rish.runtime

import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * The push receipt journal beside a project's gitdir, as DSHGitPushSupport
 * keeps it: `rish-push-receipts.json`, `{schema_version: 1, project_id,
 * receipts: [...]}`, the newest 25, never more than 256 KiB, written to a
 * temporary file and renamed into place. A receipt says what one push
 * proved -- host, branch, the local oid sent, the remote oid read back,
 * when -- and never a token or a path.
 */
internal object AndroidGitPushReceipts {
    const val FILENAME = "rish-push-receipts.json"
    private const val TEMP_FILENAME = "rish-push-receipts.json.tmp"
    private const val MAX_RECEIPTS = 25
    private const val MAX_JOURNAL_BYTES = 262144
    private const val STORAGE_UNAVAILABLE = 3020
    private const val JOURNAL_INVALID = 3021

    fun receipt(host: String, branch: String, localOid: String, remoteOid: String, pushedAt: String): JSONObject =
        JSONObject().put("schema_version", 1).put("remote", "origin").put("host", host).put("branch", branch)
            .put("local_oid", localOid).put("remote_oid", remoteOid).put("pushed_at", pushedAt)

    /** Every receipt in the journal, oldest first; an absent journal is an empty list. */
    fun load(gitDir: File, projectId: String): JSONArray {
        val file = File(gitDir, FILENAME)
        if (!file.exists()) return JSONArray()
        if (!file.isFile || file.length() > MAX_JOURNAL_BYTES) throw refused(STORAGE_UNAVAILABLE, "receipt storage is unavailable")
        val journal = try { JSONObject(file.readText(Charsets.UTF_8)) } catch (_: Exception) { throw refused(JOURNAL_INVALID, "receipt journal is invalid") }
        val receipts = journal.optJSONArray("receipts")
        if (journal.opt("schema_version") != 1 || journal.opt("project_id") != projectId || receipts == null ||
            receipts.length() > MAX_RECEIPTS || (0 until receipts.length()).any { !valid(receipts.optJSONObject(it)) }
        ) {
            throw refused(JOURNAL_INVALID, "receipt journal is invalid")
        }
        return receipts
    }

    /** Appends one receipt, keeping the newest [MAX_RECEIPTS]. */
    fun record(gitDir: File, projectId: String, receipt: JSONObject) {
        if (!valid(receipt)) throw refused(JOURNAL_INVALID, "receipt journal is invalid")
        val existing = load(gitDir, projectId)
        val kept = JSONArray()
        val start = maxOf(0, existing.length() + 1 - MAX_RECEIPTS)
        for (index in start until existing.length()) kept.put(existing.getJSONObject(index))
        kept.put(receipt)
        val bytes = JSONObject().put("schema_version", 1).put("project_id", projectId).put("receipts", kept)
            .toString().toByteArray(Charsets.UTF_8)
        if (bytes.size > MAX_JOURNAL_BYTES) throw refused(JOURNAL_INVALID, "receipt journal is invalid")
        val temp = File(gitDir, TEMP_FILENAME)
        try {
            java.io.FileOutputStream(temp).use { it.write(bytes); it.fd.sync() }
            if (!temp.renameTo(File(gitDir, FILENAME))) throw refused(STORAGE_UNAVAILABLE, "receipt storage is unavailable")
        } catch (failure: java.io.IOException) {
            temp.delete()
            throw refused(STORAGE_UNAVAILABLE, "receipt storage is unavailable")
        }
    }

    /** The bridge-safe copy: the seven fields, nothing else. */
    fun sanitized(receipt: JSONObject): JSONObject =
        receipt(receipt.getString("host"), receipt.getString("branch"), receipt.getString("local_oid"),
            receipt.getString("remote_oid"), receipt.getString("pushed_at"))

    private fun valid(receipt: JSONObject?): Boolean {
        if (receipt == null || receipt.length() != 7 || receipt.opt("schema_version") != 1 || receipt.opt("remote") != "origin") return false
        val host = receipt.opt("host") as? String ?: return false
        val branch = receipt.opt("branch") as? String ?: return false
        val pushedAt = receipt.opt("pushed_at") as? String ?: return false
        return host.length in 1..253 && host.none { it.isISOControl() } &&
            branch.length in 1..1024 && branch.none { it.isISOControl() } && ".." !in branch &&
            oid(receipt.opt("local_oid")) && oid(receipt.opt("remote_oid")) &&
            pushedAt.length in 1..64 && pushedAt.none { it.isISOControl() }
    }

    private fun oid(value: Any?): Boolean = value is String && value.length == 40 && value.all { it in '0'..'9' || it in 'a'..'f' }

    private fun refused(number: Int, reason: String) = AndroidWorkspaceProjects.Refused(number, reason)
}
