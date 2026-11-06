package tech.zseven.rish

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.AndroidAgentRootResolver
import tech.zseven.rish.runtime.AndroidWorkspaceProjects
import tech.zseven.rish.runtime.AndroidWorkspaceRegistry
import tech.zseven.rish.runtime.RishAgentCoreNative
import java.io.File
import java.util.UUID

/**
 * Resolving a workspace binding into the root an agent attempt runs against.
 *
 * The evidence is the host's — which record the registry holds, whether its
 * authority still proves the directory. What that evidence entitles the root
 * to is the shared rule's, so these assert the projection the core produces,
 * not one written out again here.
 */
@RunWith(AndroidJUnit4::class)
class AndroidAgentRootResolverTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    private fun fixture(): Pair<AndroidWorkspaceRegistry, AndroidAgentRootResolver> {
        assertTrue("the agent core is not staged", RishAgentCoreNative.available)
        val workspaces = AndroidWorkspaceRegistry(
            File(context.noBackupFilesDir, "roots-test-${UUID.randomUUID()}")
                .apply { mkdirs() },
        )
        return Pair(workspaces, AndroidAgentRootResolver(workspaces))
    }

    /**
     * A provable app-private root carries exactly the capabilities the shared
     * rule derives from its grants — which on this platform is file read and
     * file write, and nothing else.
     */
    @Test
    fun aProvableWorkspaceResolvesToTheRootTheRuleDerives() {
        val (workspaces, roots) = fixture()
        val record = workspaces.create("Scratch")
        val id = record.getString("workspace_id")
        val root = roots.resolve(id, null, 1)
        assertNotNull(root)
        assertEquals(1, root!!.getInt("schema_version"))
        assertEquals("workspace", root.getString("kind"))
        assertEquals(id, root.getString("workspace_id"))
        assertEquals(1, root.getInt("workspace_binding_revision"))
        assertTrue(root.isNull("project_id"))
        assertEquals(
            workspaces.fingerprintFor(id),
            root.getString("root_fingerprint_sha256"),
        )
        val capabilities = root.getJSONArray("capabilities")
        val names = (0 until capabilities.length()).map { capabilities.getString(it) }
        // Exactly two, and this is the honest part: the registry grants git,
        // but the shared rule only turns it into Agent Git capabilities for a
        // *project* root, and Android has no project subsystem. `guest_service`
        // needs the guest CGI tools, which this build does not ship. So an
        // Android workspace root reads and writes files, and that is all it
        // claims to do.
        assertEquals(listOf("file_read", "file_write"), names)
    }

    /**
     * A project root is the workspace root promoted, once the binding beside
     * the project's gitdir proves the project belongs to this root at this
     * revision. A project id nothing attached is refused rather than answered
     * with a workspace root wearing a project's name.
     */
    @Test
    fun aProjectRootResolvesOnceAttached() {
        val (workspaces, roots) = fixture()
        val id = workspaces.create("Scratch").getString("workspace_id")
        assertNull(roots.resolve(id, UUID.randomUUID().toString(), 1))
        val projects = AndroidWorkspaceProjects(workspaces)
        val projectId = projects.attach(
            JSONObject().put("schema_version", 1).put("operation_id", UUID.randomUUID().toString())
                .put("mode", "init")
                .put("root", JSONObject().put("schema_version", 1).put("workspace_id", id)
                    .put("binding_revision", 1).put("project_id", JSONObject.NULL)),
        ).getJSONObject("project").getString("project_id")
        val root = roots.resolve(id, projectId, 1)
        assertNotNull(root)
        assertEquals("project", root!!.getString("kind"))
        assertEquals(projectId, root.getString("project_id"))
        assertEquals(workspaces.fingerprintFor(id), root.getString("root_fingerprint_sha256"))
        val capabilities = root.getJSONArray("capabilities")
        val names = (0 until capabilities.length()).map { capabilities.getString(it) }
        assertTrue(names.toString(), names.containsAll(listOf("git_status", "git_commit", "git_push")))
        // Another project id, and another revision, are other roots.
        assertNull(roots.resolve(id, UUID.randomUUID().toString(), 1))
        assertNull(roots.resolve(id, projectId, 2))
    }

    /** Three absent arguments are "no root", which is not an error. */
    @Test
    fun anAbsentRootResolvesToNothing() {
        val (_, roots) = fixture()
        assertNull(roots.resolve(null, null, null))
    }

    /** A workspace this device does not hold is not a root it can resolve. */
    @Test
    fun anUnknownWorkspaceResolvesToNothing() {
        val (_, roots) = fixture()
        assertNull(roots.resolve(UUID.randomUUID().toString(), null, 1))
    }

    /**
     * The binding has to be the one asked about. A different revision is not a
     * stale version of this root; it is a different root, and answering with
     * this one would hand the caller authority it never asked for.
     */
    @Test
    fun aDifferentBindingRevisionIsADifferentRoot() {
        val (workspaces, roots) = fixture()
        val id = workspaces.create("Scratch").getString("workspace_id")
        assertNotNull(roots.resolve(id, null, 1))
        assertNull(roots.resolve(id, null, 2))
        assertNull(roots.resolve(id, null, 0))
    }

    /**
     * A root whose authority no longer proves the directory is no root at all
     * — not a read-only one, not one to be repaired.
     */
    @Test
    fun anUnprovableRootResolvesToNothing() {
        val (workspaces, roots) = fixture()
        val record = workspaces.create("Scratch")
        val id = record.getString("workspace_id")
        assertNotNull(roots.resolve(id, null, 1))
        val authority = File(File(workspaces.root, "bindings"), "owned-$id-r1.json")
        val edited = JSONObject(authority.readText())
        edited.put("inode_id", (edited.getString("inode_id").toLong() + 1).toString())
        authority.writeText(edited.toString())
        assertNull(roots.resolve(id, null, 1))
    }

    /** A malformed workspace id is not a root request the rule will act on. */
    @Test
    fun aMalformedRootRequestResolvesToNothing() {
        val (_, roots) = fixture()
        assertNull(roots.resolve("not-a-uuid", null, 1))
        // A workspace with no revision names no binding.
        assertNull(roots.resolve(UUID.randomUUID().toString(), null, null))
        // A revision with no workspace names nothing at all.
        assertNull(roots.resolve(null, null, 1))
    }
}
