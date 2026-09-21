package tech.zseven.rish.runtime

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/**
 * Snapshot and commit receipt in one FULL-synchronous SQLite transaction.
 *
 * SQLite is the storage mechanism; every decision — what a request may look
 * like, whether a candidate is acceptable and what it digests to, whether this
 * operation already committed, whether `expected` is still the authority, and
 * what a query may conclude — belongs to the shared core, exactly as it does
 * on iOS. There is no second set of rules here to drift from it.
 */
internal class AndroidSessionStore(context: Context, name: String = "rish.sessions.v1.db") : SQLiteOpenHelper(context.applicationContext, name, null, 4) {
    companion object {
        val launchId: String = UUID.randomUUID().toString()
        const val MAX_BYTES = 16 * 1024 * 1024
        /**
         * Clearance receipts, beside the commits they were issued against. On
         * iOS they are a file under the session CAS lock; here the same
         * transaction that commits the session inserts the receipt, so a
         * receipt never exists for a generation that did not commit.
         */
        private const val CLEARANCES_TABLE = "CREATE TABLE IF NOT EXISTS clearances (" +
            "operation TEXT PRIMARY KEY, receipt_id TEXT NOT NULL UNIQUE, workspace TEXT NOT NULL, " +
            "revision INTEGER NOT NULL, generation INTEGER NOT NULL, digest TEXT NOT NULL, " +
            "issued_ms INTEGER NOT NULL, operation_json TEXT NOT NULL, receipt_json TEXT NOT NULL)"
        private const val RECEIPT_TTL_MS = 30L * 24 * 60 * 60 * 1000
        private val CLEARANCE_KEYS = setOf("schema_version", "candidate_json", "operation")
    }
    override fun onConfigure(db: SQLiteDatabase) { db.execSQL("PRAGMA synchronous=FULL") }
    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE snapshot (id INTEGER PRIMARY KEY CHECK(id=1), generation INTEGER NOT NULL, digest TEXT NOT NULL, candidate TEXT NOT NULL, writer TEXT NOT NULL)")
        // Commits only. A conflict is not an outcome an operation keeps: the
        // controller may retry the same operation once it has re-read the
        // authority, and a stored conflict would replay forever.
        db.execSQL("CREATE TABLE commits (operation TEXT PRIMARY KEY, generation INTEGER NOT NULL, digest TEXT NOT NULL)")
        db.execSQL(CLEARANCES_TABLE)
    }
    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        check(oldVersion in 1..3 && newVersion == 4)
        if (oldVersion == 3) {
            db.execSQL(CLEARANCES_TABLE)
            return
        }
        // Preserve prototype snapshots while migrating their digest protocol.
        // Old receipts are dropped rather than translated: they were keyed by
        // the whole request's bytes and could carry a conflict, neither of
        // which the shared rules recognise, so they stay unobserved.
        db.rawQuery("SELECT candidate FROM snapshot WHERE id=1", null).use { cursor ->
            if (cursor.moveToFirst()) {
                db.execSQL("UPDATE snapshot SET digest=? WHERE id=1", arrayOf(candidateDigest(cursor.getString(0))))
            }
        }
        db.execSQL("DROP TABLE IF EXISTS operations")
        db.execSQL("CREATE TABLE IF NOT EXISTS commits (operation TEXT PRIMARY KEY, generation INTEGER NOT NULL, digest TEXT NOT NULL)")
        db.execSQL(CLEARANCES_TABLE)
    }

    /** The candidate's digest, as the shared core computes it. */
    private fun candidateDigest(candidate: String): String =
        RishAgentCoreNative.session(JSONObject().put("op", "candidate_digest"), candidate).getString("digest")

    private fun reference(generation: Long, digest: String) = JSONObject().put("schema_version", 1).put("generation", generation).put("session_sha256", digest)

    private fun load(db: SQLiteDatabase): JSONObject {
        db.rawQuery("SELECT generation,digest,candidate,writer FROM snapshot WHERE id=1", null).use { cursor ->
            if (!cursor.moveToFirst()) return JSONObject().put("schema_version", 1).put("status", "missing")
                .put("snapshot", JSONObject.NULL).put("session_json", JSONObject.NULL).put("writer_launch_instance_id", JSONObject.NULL).put("current_launch_instance_id", launchId)
            val candidate = cursor.getString(2)
            check(candidateDigest(candidate) == cursor.getString(1)) { "Corrupt session snapshot" }
            // The bytes handed out are canonical, exactly as iOS's
            // `loadResultForState:` hands out `DSHSessionCanonicalJSON`.
            // Everything downstream that gives these bytes back to the core --
            // the prepared-attempt store above all -- is refused outright when
            // they are not the core's own canonical form, and the controller
            // writes a candidate in insertion order. Storing what it wrote and
            // answering with what the rules can read is the same split iOS
            // makes; the digest stays over the stored bytes, because that is
            // what it is a digest *of*.
            val canonical = RishAgentCoreNative.canonical(candidate)
                ?: error("Corrupt session snapshot: the stored candidate is not JSON the core reads")
            return JSONObject().put("schema_version", 1).put("status", "present")
                .put("snapshot", reference(cursor.getLong(0), cursor.getString(1))).put("session_json", canonical)
                .put("writer_launch_instance_id", cursor.getString(3)).put("current_launch_instance_id", launchId)
        }
    }
    @Synchronized fun load(): JSONObject = load(readableDatabase)

    /**
     * The state as the core reads it: the current snapshot and the whole
     * commit chain. SQLite keeps every commit, so the chain is never evicted
     * and a query can always prove an operation's absence.
     */
    private fun loadedState(db: SQLiteDatabase): JSONObject {
        db.rawQuery("SELECT generation,digest FROM snapshot WHERE id=1", null).use { cursor ->
            if (!cursor.moveToFirst()) return JSONObject().put("kind", "missing")
            val commits = JSONArray()
            db.rawQuery("SELECT operation,generation,digest FROM commits ORDER BY generation ASC", null).use { rows ->
                while (rows.moveToNext()) {
                    commits.put(JSONObject().put("schema_version", 1).put("operation_id", rows.getString(0))
                        .put("generation", rows.getLong(1)).put("session_sha256", rows.getString(2)))
                }
            }
            return JSONObject().put("kind", "present").put("generation", cursor.getLong(0))
                .put("session_sha256", cursor.getString(1)).put("recent_commits", commits)
        }
    }

    /**
     * Storage preserves opaque JSON bytes; it does not issue project, tool or
     * Agent authority. Those native APIs remain closed on Android, so a
     * candidate that carries their journals is refused here — a platform
     * policy on top of the shared acceptance rules, not a different reading of
     * them.
     *
     * **Workspace bindings are no longer among them.** Android has a workspace
     * registry now, so a conversation may name a `workspace_id` and carry a
     * `workspace_binding`; the shared schema already says what a well-formed
     * one looks like, and whether the binding can still be *proved* is decided
     * where it is used, not here. A session records what the person chose; the
     * root resolver decides what that is still worth.
     *
     * **Agent journals are no longer among them either.** This platform now
     * serves the operations a turn walks through, so a conversation carries an
     * `agent` journal on its attempt, `agent_grants` the person allowed,
     * `session_events` recording what they decided, and cleanup entries a
     * finished attempt left behind. Refusing those was the last gate on the
     * agent path: every one of them is written by the first turn that runs a
     * tool, so storage refused the save and the turn failed with
     * E_AGENT_PERSISTENCE before anything could change on disk.
     *
     * The shared schema already says what a well-formed one of each looks
     * like, and the core judges the candidate's bytes before this runs. What
     * is left here is only the platform question: *can this build issue or
     * verify the thing at all?*
     *
     * A conversation's `project_id` and `project_context` are the core's to
     * judge now that a workspace can be attached to a project here; only the
     * destructive-transition journal stays refused, since nothing on this
     * platform issues one. `workspace_authority_outbox` is accepted now: it is
     * filled when a workspace is forgotten or deleted, and this store is what
     * issues the clearance receipt that drains it (`persistWithClearance`).
     *
     * One thing this does let through that nothing here consumes:
     * `agent_transcript_cleanup_outbox` entries accumulate, because
     * `query_agent_cleanup` still refuses. They are records of transcripts to
     * sweep, not authority, and `discard_agent_attempt` -- which is served --
     * is what actually removes the residue they describe.
     */
    private fun refuseUnsupportedAuthority(parsed: JSONObject) {
        require(parsed.isNull("project_context_destructive_transition")) {
            "Project journals are not supported on Android"
        }
    }

    /**
     * The candidate's bytes and their digest, once the core has judged them
     * acceptable. The catalogue facts come from this build, because only it
     * knows them; an unacceptable candidate never reaches a transaction.
     */
    private fun accepted(candidate: String): Pair<JSONObject, String> {
        require(candidate.toByteArray(Charsets.UTF_8).size <= MAX_BYTES)
        val parsed = JSONObject(candidate)
        val digest = RishAgentCoreNative.session(JSONObject().put("op", "candidate")
            .put("env", AndroidSessionEnvironment.facts(parsed)), candidate).getString("digest")
        refuseUnsupportedAuthority(parsed)
        return parsed to digest
    }

    @Synchronized fun persist(request: JSONObject): JSONObject {
        RishAgentCoreNative.session(JSONObject().put("op", "cas_request").put("request", request))
        val candidate = request.getString("candidate_json")
        val (_, digest) = accepted(candidate)
        val db = writableDatabase
        db.beginTransaction()
        try {
            val reply = commitLocked(db, request.getString("operation_id"), request.getJSONObject("expected"), candidate, digest)
            db.setTransactionSuccessful()
            return reply
        } finally { db.endTransaction() }
    }

    /**
     * One compare-and-swap inside an open transaction: `committed` with the
     * snapshot it made (or already made, for an exact repeat), or `conflict`
     * with the authority that stands. Nothing is written for a conflict.
     */
    private fun commitLocked(db: SQLiteDatabase, operation: String, expected: JSONObject, candidate: String, digest: String): JSONObject {
        val precheck = RishAgentCoreNative.session(JSONObject().put("op", "cas_precheck")
            .put("operation_id", operation).put("expected", expected)
            .put("candidate_digest", digest).put("state", loadedState(db)))
        when (precheck.getString("outcome")) {
            // An exact repeat: the same operation already committed these
            // very bytes, so it answers with what it committed then.
            "committed" -> {
                val snapshot = precheck.getJSONObject("snapshot")
                return JSONObject().put("schema_version", 1).put("status", "committed")
                    .put("snapshot", reference(snapshot.getLong("generation"), snapshot.getString("session_sha256")))
            }
            // Not written down: the controller may re-read and retry.
            "conflict" -> return JSONObject().put("schema_version", 1).put("status", "conflict")
                .put("current", precheck.getJSONObject("current"))
        }
        val loaded = load(db)
        val generation = if (loaded.getString("status") == "missing") 1L else loaded.getJSONObject("snapshot").getLong("generation") + 1
        require(generation in 1..9007199254740991L)
        if (loaded.getString("status") == "present") db.delete("snapshot", "id=1", null)
        db.insertOrThrow("snapshot", null, ContentValues().apply {
            put("id", 1); put("generation", generation); put("digest", digest); put("candidate", candidate); put("writer", launchId)
        })
        db.insertOrThrow("commits", null, ContentValues().apply {
            put("operation", operation); put("generation", generation); put("digest", digest)
        })
        return JSONObject().put("schema_version", 1).put("status", "committed").put("snapshot", reference(generation, digest))
    }

    @Synchronized fun query(request: JSONObject): JSONObject {
        RishAgentCoreNative.session(JSONObject().put("op", "query_request").put("request", request))
        val reply = RishAgentCoreNative.session(JSONObject().put("op", "query_commit")
            .put("operation_id", request.getString("operation_id"))
            .put("state", loadedState(readableDatabase)))
        return reply.getJSONObject("result")
    }

    // --- workspace clearance -------------------------------------------------
    //
    // Forgetting a workspace or deleting its content is authorised against a
    // *specific committed session*: the one in which every conversation had
    // let go of the workspace and the request sat in the authority outbox.
    // The receipt names that session. Issuing it is the same transaction as
    // committing the session, and checking it later re-reads the session that
    // is committed *now*, so the authority is only ever removed under a
    // durable state that proves nothing still points at it.

    /**
     * `persistSessionWithWorkspaceClearance`. The host answers whether the
     * workspace is one that can be cleared at all (registered at that revision,
     * its project relation in the state the action needs); everything about
     * the candidate is the core's.
     */
    @Synchronized fun persistWithClearance(request: JSONObject, host: WorkspaceClearanceHost): JSONObject {
        require(request.keys().asSequence().toSet() == CLEARANCE_KEYS)
        RuntimeJson.checkVersion(request, 1)
        val operation = request.optJSONObject("operation") ?: throw IllegalArgumentException("operation")
        require(operationShape(operation)) { "clearance operation is invalid" }
        val candidate = request.getString("candidate_json")
        val (parsed, digest) = accepted(candidate)
        // The operation must sit unchanged in the candidate's outbox and the
        // candidate may reference the workspace nowhere; the core says so or
        // refuses, and a refusal is a conflict the caller sees.
        RishAgentCoreNative.session(JSONObject().put("op", "clearance_candidate").put("operation", operation)
            .put("env", AndroidSessionEnvironment.facts(parsed)), candidate)
        if (!host.clearable(operation)) return clearanceResult("not_committed", null)
        val db = writableDatabase
        db.beginTransaction()
        try {
            val operationId = operation.getString("operation_id")
            // A replayed operation is only idempotent while it still describes
            // the current authority: once a later generation committed, it can
            // no longer mint or return its receipt.
            val replay = RishAgentCoreNative.session(JSONObject().put("op", "clearance_replay")
                .put("operation_id", operationId).put("state", loadedState(db)))
            if (!replay.optBoolean("allowed")) return clearanceResult("not_committed", null)
            val cas = commitLocked(db, operationId, authority(db), candidate, digest)
            if (cas.getString("status") != "committed") return clearanceResult("not_committed", null)
            val snapshot = cas.getJSONObject("snapshot")
            val receipt = issueReceiptLocked(db, operation, snapshot.getLong("generation"), snapshot.getString("session_sha256"))
            db.setTransactionSuccessful()
            return clearanceResult("committed", receipt)
        } finally { db.endTransaction() }
    }

    /**
     * `queryWorkspaceClearance`: the receipt, when one was issued and still
     * authorises; `unknown` once the session store has observed the operation
     * without a provable receipt; `not_started` otherwise.
     */
    @Synchronized fun queryClearance(request: JSONObject): JSONObject {
        RishAgentCoreNative.session(JSONObject().put("op", "query_request").put("request", request))
        val operationId = request.getString("operation_id")
        val db = readableDatabase
        val row = clearanceRow(db, "operation=?", arrayOf(operationId))
        if (row != null && receiptAuthorises(db, row)) {
            return JSONObject().put("schema_version", 1).put("status", "committed")
                .put("receipt", JSONObject(row.getString("receipt_json")))
        }
        val observed = RishAgentCoreNative.session(JSONObject().put("op", "clearance_observed")
            .put("operation_id", operationId).put("state", loadedStateWithOutbox(db)))
        return JSONObject().put("schema_version", 1)
            .put("status", if (observed.optBoolean("observed")) "unknown" else "not_started")
    }

    /**
     * Runs [body] while this receipt provably authorises the operation, with
     * the store locked so no commit can land between the proof and the
     * mutation. Returns null when it does not: no such receipt, a receipt for
     * another workspace or revision, or a committed session that has since
     * taken the workspace back.
     */
    @Synchronized fun <T> withClearance(operationId: String, clearanceReceiptId: String, workspaceId: String, revision: Int, body: () -> T): T? {
        val db = readableDatabase
        val row = clearanceRow(db, "operation=? AND receipt_id=?", arrayOf(operationId, clearanceReceiptId)) ?: return null
        if (row.getString("workspace") != workspaceId || row.getInt("revision") != revision) return null
        if (!receiptAuthorises(db, row)) return null
        return body()
    }

    /** The operation a still-valid receipt belongs to, or null. */
    @Synchronized fun clearanceOperation(clearanceReceiptId: String, workspaceId: String, revision: Int): String? {
        val db = readableDatabase
        val row = clearanceRow(db, "receipt_id=?", arrayOf(clearanceReceiptId)) ?: return null
        if (row.getString("workspace") != workspaceId || row.getInt("revision") != revision) return null
        if (!receiptAuthorises(db, row)) return null
        return row.getString("operation")
    }

    private fun operationShape(operation: JSONObject): Boolean =
        RishAgentCoreNative.workspaceClearance(
            JSONObject().put("op", "operation_shape").put("operation", operation),
        )?.optBoolean("valid") == true

    private fun clearanceResult(status: String, receipt: JSONObject?): JSONObject =
        JSONObject().put("schema_version", 1).put("status", status).put("receipt", receipt ?: JSONObject.NULL)

    /** The current authority as a CAS `expected` names it. */
    private fun authority(db: SQLiteDatabase): JSONObject {
        val loaded = load(db)
        if (loaded.getString("status") == "missing") return JSONObject().put("schema_version", 1).put("kind", "missing")
        return JSONObject().put("schema_version", 1).put("kind", "present").put("snapshot", loaded.getJSONObject("snapshot"))
    }

    private fun issueReceiptLocked(db: SQLiteDatabase, operation: JSONObject, generation: Long, digest: String): JSONObject {
        val operationId = operation.getString("operation_id")
        val receiptId = operation.getString("clearance_receipt_id")
        val nowMs = System.currentTimeMillis()
        db.delete("clearances", "issued_ms<?", arrayOf((nowMs - RECEIPT_TTL_MS).toString()))
        clearanceRow(db, "operation=? OR receipt_id=?", arrayOf(operationId, receiptId))?.let { existing ->
            val same = existing.getString("operation") == operationId && existing.getString("receipt_id") == receiptId &&
                existing.getString("workspace") == operation.getString("workspace_id") &&
                existing.getInt("revision") == operation.getInt("binding_revision") &&
                existing.getLong("generation") == generation && existing.getString("digest") == digest
            check(same) { "clearance receipt conflicts with an earlier one" }
            return JSONObject(existing.getString("receipt_json"))
        }
        val count = android.database.DatabaseUtils.queryNumEntries(db, "clearances")
        val room = RishAgentCoreNative.workspaceReceipt(JSONObject().put("op", "has_room").put("count", count))
        check(room?.optBoolean("has_room") == true) { "the clearance store is full" }
        val receipt = JSONObject()
            .put("schema_version", 1)
            .put("clearance_receipt_id", receiptId)
            .put("operation_id", operationId)
            .put("workspace_id", operation.getString("workspace_id"))
            .put("binding_revision", operation.getInt("binding_revision"))
            .put("committed_session_generation", generation)
            .put("committed_session_sha256", digest)
            .put("issued_at", RuntimeJson.now())
        val shape = RishAgentCoreNative.workspaceClearance(JSONObject().put("op", "receipt_shape").put("receipt", receipt))
        check(shape?.optBoolean("valid") == true) { "the clearance receipt is not the shape the rule accepts" }
        db.insertOrThrow("clearances", null, ContentValues().apply {
            put("operation", operationId); put("receipt_id", receiptId)
            put("workspace", operation.getString("workspace_id")); put("revision", operation.getInt("binding_revision"))
            put("generation", generation); put("digest", digest); put("issued_ms", nowMs)
            put("operation_json", operation.toString()); put("receipt_json", receipt.toString())
        })
        return receipt
    }

    /**
     * Whether a stored receipt still authorises its operation: issued within
     * its lifetime, and for the session that is committed *now* -- the same
     * generation and the same digest, as iOS requires. Any later commit,
     * however unrelated, ends the receipt; the operation is then retired and
     * the person starts another.
     */
    private fun receiptAuthorises(db: SQLiteDatabase, row: JSONObject): Boolean {
        if (row.getLong("issued_ms") < System.currentTimeMillis() - RECEIPT_TTL_MS) return false
        return db.rawQuery("SELECT generation,digest FROM snapshot WHERE id=1", null).use { cursor ->
            cursor.moveToFirst() && cursor.getLong(0) == row.getLong("generation") && cursor.getString(1) == row.getString("digest")
        }
    }

    private fun clearanceRow(db: SQLiteDatabase, where: String, args: Array<String>): JSONObject? =
        db.query("clearances", null, where, args, null, null, "generation DESC", "1").use { cursor ->
            if (!cursor.moveToFirst()) return null
            val row = JSONObject()
            for (index in 0 until cursor.columnCount) {
                when (cursor.getType(index)) {
                    android.database.Cursor.FIELD_TYPE_INTEGER -> row.put(cursor.getColumnName(index), cursor.getLong(index))
                    else -> row.put(cursor.getColumnName(index), cursor.getString(index))
                }
            }
            row
        }

    /** The loaded state with the outbox the committed candidate carries. */
    private fun loadedStateWithOutbox(db: SQLiteDatabase): JSONObject {
        val state = loadedState(db)
        if (state.getString("kind") != "present") return state
        val ids = JSONArray()
        db.rawQuery("SELECT candidate FROM snapshot WHERE id=1", null).use { cursor ->
            if (cursor.moveToFirst()) {
                val outbox = JSONObject(cursor.getString(0)).optJSONArray("workspace_authority_outbox")
                for (index in 0 until (outbox?.length() ?: 0)) {
                    (outbox!!.optJSONObject(index)?.opt("operation_id") as? String)?.let { ids.put(it) }
                }
            }
        }
        return state.put("outbox_operation_ids", ids)
    }
}

/**
 * The host half of a clearance: whether the workspace an operation names can
 * be cleared at all. Registered at that revision and provable, and its project
 * relation in the state the action needs -- what iOS checks through
 * `validateWorkspaceForClearanceId:` and the project-detached proof.
 */
internal interface WorkspaceClearanceHost {
    fun clearable(operation: JSONObject): Boolean
}
