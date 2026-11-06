package tech.zseven.rish.runtime

import org.json.JSONObject

/**
 * What `LocalProjectContext` answers on Android, before the bridge.
 *
 * The listing is iOS's `listCandidatesV2ForRoot` in three steps: the root
 * has to name a project this device holds ([AndroidWorkspaceProjects]), the
 * repository is read and every entry decided once ([AndroidProjectCandidates]),
 * and one page is cut with a cursor bound to what was read. The fingerprint
 * the cursor binds is widened here, as iOS widens it, to include the
 * workspace root and its authority: a cursor is not only "this listing" but
 * "this listing of this root as it was proven then".
 *
 * A refusal carries the code JavaScript branches on and nothing else.
 */
internal class AndroidProjectContextService(
    private val projects: AndroidWorkspaceProjects,
    private val roots: AndroidAgentRootResolver,
    private val candidates: AndroidProjectCandidates = AndroidProjectCandidates(),
) {
    class Refused(val code: String, reason: String) : Exception(reason)

    /** `listCandidatesV2`: `{schema_version:2, root, project, candidates, next_cursor}`. */
    fun listCandidates(rawRequest: JSONObject?, limit: Int = MAX_PAGE_SIZE): JSONObject {
        val request = rawRequest ?: throw Refused(REQUEST_INVALID, "request is missing")
        if (request.keys().asSequence().toSet() != LIST_KEYS || request.opt("schema_version") != 1) {
            throw Refused(REQUEST_INVALID, "request is invalid")
        }
        val query = request.opt("query") as? String ?: throw Refused(REQUEST_INVALID, "query is invalid")
        val cursor = request.opt("cursor").takeIf { it != JSONObject.NULL }
        if (!boundedText(query, MAX_QUERY_BYTES, allowEmpty = true) ||
            (cursor != null && (cursor !is String || !boundedText(cursor, MAX_CURSOR_BYTES, allowEmpty = false)))
        ) {
            throw Refused(REQUEST_INVALID, "request is invalid")
        }
        val root = try {
            projects.canonicalRoot(request.optJSONObject("root"), projectRequired = true)
        } catch (refused: AndroidWorkspaceProjects.Refused) {
            throw Refused(REQUEST_INVALID, refused.message ?: "root is invalid")
        }
        val workspaceId = root.getString("workspace_id")
        val projectId = root.getString("project_id")
        val (project, workingTree, fingerprint) = try {
            val descriptor = projects.verifiedDescriptor(root, projectId)
            val tree = projects.workingTree(workspaceId) ?: throw Refused(NOT_FOUND, "workspace root is unavailable")
            val resolved = roots.resolveWorkspaceRef(
                JSONObject().put("schema_version", 1).put("workspace_id", workspaceId)
                    .put("binding_revision", root.get("binding_revision")).put("project_id", JSONObject.NULL),
            ) ?: throw Refused(NOT_FOUND, "workspace root is unavailable")
            Triple(descriptor, tree, resolved.getString("root_fingerprint_sha256"))
        } catch (refused: AndroidWorkspaceProjects.Refused) {
            throw Refused(contextCode(refused), refused.message ?: "project is unavailable")
        }
        val capture = try {
            candidates.capture(projects.gitDirectory(workspaceId, projectId).absolutePath, workingTree.absolutePath)
        } catch (refused: AndroidProjectCandidates.Refused) {
            throw Refused(refused.code, refused.reason)
        }
        val bound = AndroidProjectCandidates.Capture(
            capture.candidates,
            RuntimeJson.sha(
                RuntimeJson.canonical(
                    JSONObject().put("workspace_root", root)
                        .put("workspace_root_fingerprint", fingerprint)
                        .put("candidate_source_fingerprint", capture.sourceFingerprint),
                ),
            ),
        )
        val page = try {
            candidates.page(bound, query, cursor as String?, limit)
        } catch (refused: AndroidProjectCandidates.Refused) {
            throw Refused(refused.code, refused.reason)
        }
        return JSONObject().put("schema_version", 2).put("root", root).put("project", project)
            .put("candidates", page.getJSONArray("candidates"))
            .put("next_cursor", page.opt("next_cursor") ?: JSONObject.NULL)
    }

    /** iOS's `v2LeaseForRoot` mapping: a project that is not there is not found; the rest changed. */
    private fun contextCode(refused: AndroidWorkspaceProjects.Refused): String = when (refused.number) {
        AndroidWorkspaceProjects.REQUEST_INVALID -> REQUEST_INVALID
        AndroidWorkspaceProjects.UNAVAILABLE -> NOT_FOUND
        else -> CHANGED
    }

    private fun boundedText(value: String, maximumBytes: Int, allowEmpty: Boolean): Boolean =
        (allowEmpty || value.isNotEmpty()) && value.length <= maximumBytes &&
            value.toByteArray(Charsets.UTF_8).size <= maximumBytes &&
            value.none { Character.isISOControl(it) }

    companion object {
        const val REQUEST_INVALID = "E_CONTEXT_REQUEST_INVALID"
        const val NOT_FOUND = "E_PROJECT_NOT_FOUND"
        const val CHANGED = "E_CONTEXT_CHANGED"
        private const val MAX_PAGE_SIZE = 100
        private const val MAX_QUERY_BYTES = 256
        private const val MAX_CURSOR_BYTES = 256
        private val LIST_KEYS = setOf("schema_version", "root", "query", "cursor")
    }
}
