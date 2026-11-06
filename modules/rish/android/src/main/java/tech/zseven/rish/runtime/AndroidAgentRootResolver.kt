package tech.zseven.rish.runtime

import org.json.JSONArray
import org.json.JSONObject

/**
 * Turns a workspace binding into the root an agent attempt runs against.
 *
 * The evidence is this host's: which record the registry holds, whether its
 * authority still proves the directory on disk. The projection — what that
 * evidence entitles the root to — is the shared rule's
 * ([RishAgentCoreNative.agentRoot], `root_projection.rs`), so a root resolved
 * here carries exactly the capabilities the same evidence would carry on iOS.
 *
 * **Projects are not resolvable here.** A project root needs an independently
 * verified project lease, and Android has no project subsystem. A request that
 * names a `project_id` is refused rather than answered with a workspace root
 * wearing a project's name — the caller asked a question this platform cannot
 * answer, and saying so is the honest reply.
 *
 * **A root that cannot be proven is no root.** Not a read-only root, not a
 * stale one to be repaired: [resolve] returns null and the caller reports the
 * binding as stale.
 */
internal class AndroidAgentRootResolver(
    private val workspaces: AndroidWorkspaceRegistry,
    private val projects: AndroidWorkspaceProjects = AndroidWorkspaceProjects(workspaces),
) {
    /** The grants a workspace root may carry; a project's three are not here. */
    private val workspaceGrants = listOf("read", "write", "git")

    /**
     * The root for a binding, or null when there is none to be had — the
     * request names no root, names a project, names a workspace this device
     * does not hold, or names one whose directory can no longer be proven.
     */
    /**
     * Resolves the root projection an **agent** request carries.
     *
     * There are two root shapes crossing this bridge and they spell the
     * binding differently. `AgentRuntimeRootV1` -- what every agent operation
     * carries -- says `workspace_binding_revision`; `WorkspaceRootRefV1` --
     * what the workspace and project modules take -- says `binding_revision`.
     * Reading the wrong one yields null, which resolves nothing and reports a
     * root that cannot be proved: indistinguishable, from the outside, from a
     * root that genuinely moved. That is how the agent path stayed shut on
     * this platform without a single test going red, so the two now have two
     * names and neither caller has to remember which spelling it holds.
     */
    fun resolveAgentProjection(root: JSONObject?): JSONObject? {
        val projection = root ?: return null
        return resolve(
            workspaceId = projection.optString("workspace_id").takeIf { it.isNotEmpty() },
            projectId = projection.opt("project_id")?.takeIf { it != JSONObject.NULL } as? String,
            bindingRevision = revisionOf(projection, "workspace_binding_revision"),
        )
    }

    /** Resolves a `WorkspaceRootRefV1`, which spells it `binding_revision`. */
    fun resolveWorkspaceRef(root: JSONObject?): JSONObject? {
        val reference = root ?: return null
        return resolve(
            workspaceId = reference.optString("workspace_id").takeIf { it.isNotEmpty() },
            projectId = reference.opt("project_id")?.takeIf { it != JSONObject.NULL } as? String,
            bindingRevision = revisionOf(reference, "binding_revision"),
        )
    }

    /**
     * A binding revision as it actually arrives, not as a cast hopes.
     *
     * JSON callers may supply integral `Double` values, so `opt(key) as? Int`
     * answers null for every revision a real request carries -- while a
     * JSONObject built in a test with `put(key, 1)` holds an `Integer` and
     * casts fine. That asymmetry is why every root in production failed to
     * resolve while the tests over the same code stayed green.
     */
    private fun revisionOf(value: JSONObject, key: String): Int? =
        when (val raw = value.opt(key)) {
            is Number -> raw.toInt()
            is String -> raw.toIntOrNull()
            else -> null
        }

    fun resolve(
        workspaceId: String?,
        projectId: String?,
        bindingRevision: Int?,
    ): JSONObject? {
        if (!RishAgentCoreNative.available) return null
        // Whether this is even a well-formed root request is the rule's call.
        val request = RishAgentCoreNative.agentRoot(
            JSONObject().put("op", "resolve_request")
                .put("workspace_id", workspaceId ?: JSONObject.NULL)
                .put("project_id", projectId ?: JSONObject.NULL)
                .put("binding_revision", bindingRevision ?: JSONObject.NULL),
        ) ?: return null
        if (request.optString("outcome") != "resolve") return null
        val id = request.optString("workspace_id")
        val revision = request.optInt("binding_revision", -1)
        if (revision < 0) return null

        val record = workspaces.list().firstOrNull { it.optString("workspace_id") == id }
            ?: return null
        // The binding has to be the one asked about. An older revision is not
        // a stale version of this root; it is a different one.
        if (record.opt("binding_revision") != revision) return null

        val descriptor = workspaces.descriptor(id) ?: return null
        if (descriptor.optString("status") != "ok") return null
        val capabilities = descriptor.optJSONObject("capabilities") ?: return null
        val grants = JSONArray()
        for (grant in workspaceGrants) {
            if (capabilities.optBoolean(grant)) grants.put(grant)
        }

        val fingerprint = workspaces.fingerprintFor(id) ?: return null
        val reply = RishAgentCoreNative.agentRoot(
            JSONObject().put("op", "workspace_projection")
                .put("workspace_id", id)
                .put("binding_revision", revision)
                .put("root_fingerprint_sha256", fingerprint)
                .put("grants", grants)
                // Android ships no guest CGI tools, and the toolset digest
                // every stored authority is bound to says so too.
                .put("guest_cgi", false),
        ) ?: return null
        val workspaceRoot = reply.optJSONObject("root") ?: return null
        if (request.optString("kind") != "project") return workspaceRoot
        // A project root: the workspace, promoted once the binding beside the
        // project's gitdir proves it belongs to this root at this revision.
        // The core appends the three Git capabilities; the fingerprint is
        // the one the workspace authority carries now, which the binding was
        // checked against.
        val projectRef = JSONObject().put("schema_version", 1).put("workspace_id", id)
            .put("binding_revision", revision).put("project_id", projectId)
        try {
            projects.verifiedDescriptor(projectRef, projectId ?: return null)
        } catch (_: AndroidWorkspaceProjects.Refused) {
            return null
        }
        return RishAgentCoreNative.agentRoot(
            JSONObject().put("op", "project_projection").put("base", workspaceRoot)
                .put("project_id", projectId).put("root_fingerprint_sha256", fingerprint),
        )?.optJSONObject("root")
    }

}
