package tech.zseven.rish

import android.system.Os
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.AndroidWorkspaceRegistry
import tech.zseven.rish.runtime.RishAgentCoreNative
import java.io.File
import java.util.UUID

/**
 * Android's workspace registry writes the same record, authority and
 * fingerprint iOS writes, validated by the same shared rules. These tests are
 * the first thing on Android to exercise `workspace_record`,
 * `workspace_authority`, `workspace_fingerprint`, `workspace_grants` and
 * `workspace_directory_name` at all.
 *
 * **What they do not cover.** There is no rebinding on Android yet, so every
 * record here is at binding revision 1 and nothing exercises
 * `binding_revision_advance`. The granted and legacy origins are unreachable
 * on this platform and are not tested here because they cannot be produced —
 * their coverage stays on iOS and in the core.
 */
@RunWith(AndroidJUnit4::class)
class AndroidWorkspaceRegistryTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    private fun registry(): AndroidWorkspaceRegistry =
        AndroidWorkspaceRegistry(
            File(context.noBackupFilesDir, "workspaces-test-${UUID.randomUUID()}")
                .apply { mkdirs() },
        )

    private fun container(store: AndroidWorkspaceRegistry): File =
        File(store.root, AndroidWorkspaceRegistry.CONTAINER_NAME)

    private fun authorityFile(store: AndroidWorkspaceRegistry, id: String): File =
        File(File(store.root, "bindings"), "owned-$id-r1.json")

    /** The refusal code, or a failure if the call did not refuse at all. */
    private fun refusedCode(what: String, body: () -> Unit): String {
        try {
            body()
        } catch (refused: AndroidWorkspaceRegistry.Refused) {
            return refused.code
        }
        fail("$what was accepted")
        return ""
    }

    /**
     * Without the shared core there is no second set of workspace rules to
     * fall back on. Every test below assumes it is staged, so this is the one
     * that says so out loud.
     */
    @Test
    fun theSharedCoreIsStaged() {
        assertTrue(
            "the shared agent core is not staged in this build",
            RishAgentCoreNative.available,
        )
    }

    @Test
    fun aCreatedWorkspaceIsTheShapeTheSharedRuleAccepts() {
        val store = registry()
        val record = store.create("Scratch")
        assertEquals(1, record.getInt("schema_version"))
        assertEquals("rish_created", record.getString("origin"))
        assertEquals("documents_owned", record.getString("root_locator_kind"))
        assertEquals("rish_owned", record.getString("location_class"))
        assertEquals("Scratch", record.getString("owned_directory_name"))
        assertEquals(1, record.getInt("binding_revision"))
        assertTrue(record.isNull("legacy_project_id"))
        // The record is in the registry, and the registry advanced.
        assertEquals(1, store.registry().getInt("generation"))
        assertEquals(1, store.list().size)
        assertTrue(File(container(store), "Scratch").isDirectory)
    }

    /**
     * The authority is sealed with the fingerprint its own contents imply, and
     * the shared rule is what says so. If this ever passed with a fingerprint
     * the host invented, every root on the platform would be unprovable.
     */
    @Test
    fun theAuthorityIsSealedWithTheFingerprintItsContentsImply() {
        val store = registry()
        val record = store.create("Notes")
        val authority = JSONObject(
            authorityFile(store, record.getString("workspace_id")).readText(),
        )
        assertEquals(64, authority.getString("root_fingerprint_sha256").length)
        val reply = RishAgentCoreNative.workspaceAuthority(
            JSONObject().put("op", "owned").put("authority", authority)
                .put("record", record),
        )
        assertNotNull(reply)
        assertTrue(reply!!.getBoolean("valid"))
    }

    /**
     * An authority whose bytes were edited no longer matches the fingerprint
     * it was sealed with, so the workspace stops being provable. This is the
     * check that makes the fingerprint worth writing.
     */
    @Test
    fun anEditedAuthorityStopsProvingTheRoot() {
        val store = registry()
        val record = store.create("Notes")
        val id = record.getString("workspace_id")
        assertNotNull(store.rootFor(id))
        val file = authorityFile(store, id)
        val authority = JSONObject(file.readText())
        authority.put("device_id", (authority.getString("device_id").toLong() + 1).toString())
        file.writeText(authority.toString())
        assertNull(store.rootFor(id))
        assertTrue(store.list().isEmpty())
        val descriptor = store.descriptor(id)
        assertNotNull(descriptor)
        assertEquals("root_changed", descriptor!!.getString("status"))
        val capabilities = descriptor.getJSONObject("capabilities")
        assertFalse(capabilities.getBoolean("read"))
        assertFalse(capabilities.getBoolean("write"))
        // `files_visible` describes the folder, not a grant: it stays true.
        assertTrue(capabilities.getBoolean("files_visible"))
    }

    /**
     * The authority is sealed over the directory's device and inode, so a
     * directory that was replaced since — same name, different folder — is not
     * that workspace's root.
     *
     * **The replacement is made by moving, not by deleting.** Deleting the
     * directory and recreating it under the same name hands the freed inode
     * straight back, so the "new" directory has the identity the authority was
     * sealed over and nothing here would be under test. Moving it keeps the
     * old inode allocated, which forces the replacement to get a different
     * one. The precondition is asserted, so this test cannot quietly stop
     * testing if that ever changes.
     *
     * That inode reuse is worth naming: physical identity catches a folder
     * swapped for a *different* one, not a folder deleted and rebuilt in its
     * place. Neither platform claims otherwise.
     */
    @Test
    fun aReplacedDirectoryIsNotTheSameRoot() {
        val store = registry()
        val record = store.create("Scratch")
        val id = record.getString("workspace_id")
        assertNotNull(store.rootFor(id))
        val directory = File(container(store), "Scratch")
        val before = Os.stat(directory.absolutePath).st_ino
        assertTrue(directory.renameTo(File(container(store), "moved")))
        assertTrue(directory.mkdir())
        assertNotEquals(before, Os.stat(directory.absolutePath).st_ino)
        assertNull(store.rootFor(id))
    }

    /** A provable documents-owned root grants everything the rule allows. */
    @Test
    fun aProvableRootGrantsWhatTheRuleAllows() {
        val store = registry()
        val record = store.create("Scratch")
        val descriptor = store.descriptor(record.getString("workspace_id"))
        assertNotNull(descriptor)
        assertEquals("ok", descriptor!!.getString("status"))
        assertEquals(2, descriptor.getInt("schema_version"))
        val capabilities = descriptor.getJSONObject("capabilities")
        for (capability in listOf("read", "write", "git", "project_context", "files_visible")) {
            assertTrue(capability, capabilities.getBoolean(capability))
        }
    }

    /**
     * A second workspace wanting a taken name gets an ordinal, and the folding
     * that decides "taken" is case- and diacritic-insensitive on this host too.
     */
    @Test
    fun anOccupiedNameGetsAnOrdinal() {
        val store = registry()
        assertEquals("Scratch", store.create("Scratch").getString("owned_directory_name"))
        assertEquals("sCrAtCh (1)", store.create("sCrAtCh").getString("owned_directory_name"))
        assertEquals("Scratch (2)", store.create("Scratch").getString("owned_directory_name"))
        assertEquals(3, store.list().size)
    }

    /**
     * A directory the registry knows nothing about still occupies its name:
     * the container is walked, not just the records, so creating a workspace
     * can never land on top of an existing folder.
     */
    @Test
    fun anUnknownDirectoryStillOccupiesItsName() {
        val store = registry()
        val container = container(store)
        assertTrue(container.mkdirs())
        assertTrue(File(container, "Scratch").mkdir())
        assertEquals("Scratch (1)", store.create("Scratch").getString("owned_directory_name"))
    }

    /**
     * A name at the 120-byte bound gives up bytes to make room for its
     * suffix, and the cut falls on a grapheme cluster — the same projection
     * iOS uses, over this host's own segmentation.
     */
    @Test
    fun anOccupiedNameAtTheBoundIsTruncatedOnAClusterBoundary() {
        val store = registry()
        val flag = "🇯🇵"
        assertEquals(8, flag.toByteArray(Charsets.UTF_8).size)
        val name = flag.repeat(15)
        assertEquals(120, name.toByteArray(Charsets.UTF_8).size)
        assertEquals(name, store.create(name).getString("owned_directory_name"))
        val second = store.create(name).getString("owned_directory_name")
        assertEquals(flag.repeat(14) + " (1)", second)
        assertEquals(116, second.toByteArray(Charsets.UTF_8).size)
    }

    /** A display name the shared rule refuses is never written. */
    @Test
    fun anInvalidDisplayNameIsRefusedBeforeAnythingIsWritten() {
        val store = registry()
        val names = listOf("", " ", ".", "..", ".hidden", "Rish Workspaces", "a/b", "a b")
        for (name in names) {
            assertEquals(
                "E_WORKSPACE_INVALID",
                refusedCode("the display name ${JSONObject.quote(name)}") { store.create(name) },
            )
        }
        assertEquals(0, store.registry().getInt("generation"))
        assertTrue(store.list().isEmpty())
    }

    /**
     * Records are stored in ascending workspace id order, because the
     * registry's canonical JSON is what a journal's
     * `previous_registry_sha256` is taken over: the same records in a
     * different order digest differently. Creating appends in the right place,
     * and a registry written any other way would not load.
     */
    @Test
    fun recordsAreStoredInAscendingWorkspaceIdOrder() {
        val store = registry()
        val ids = (0 until 6).map { store.create("Space $it").getString("workspace_id") }
        val records = store.registry().getJSONArray("records")
        assertEquals(ids.size, records.length())
        val stored = (0 until records.length())
            .map { records.getJSONObject(it).getString("workspace_id") }
        assertEquals(stored.sorted(), stored)
        assertEquals(ids.sorted(), stored)
        // And it still reads back, which is the point of the order.
        assertEquals(ids.size, store.list().size)
    }

    /**
     * The whole registry shape is the shared rule's now, so a file the rule
     * refuses is refused here — including one that would only fail the
     * ordering, which this host could never have written.
     */
    @Test
    fun aRegistryTheSharedRuleRefusesIsNotLoaded() {
        val store = registry()
        store.create("Alpha")
        store.create("Beta")
        val file = File(store.root, "registry.json")
        val parsed = JSONObject(file.readText())
        val records = parsed.getJSONArray("records")
        // Reverse the order; nothing else changes.
        val reversed = JSONArray()
        for (index in records.length() - 1 downTo 0) reversed.put(records.getJSONObject(index))
        file.writeText(JSONObject(parsed.toString()).put("records", reversed).toString())
        assertEquals(
            "E_WORKSPACE_CORRUPT",
            refusedCode("a registry out of order") { store.registry() },
        )
    }

    /**
     * Bytes are vetted before the parse. `JSONObject` would have taken the
     * last of two duplicate keys without saying so — the shared scanner
     * refuses the file instead.
     */
    @Test
    fun aRegistryWithADuplicateKeyIsRefusedBeforeItIsParsed() {
        val store = registry()
        store.create("Alpha")
        val file = File(store.root, "registry.json")
        val text = file.readText()
        assertTrue(text.contains("\"generation\""))
        // Appended, so it is the one org.json keeps: a value the writer never
        // wrote survives the parse and nothing says so.
        file.writeText(text.dropLast(1) + ",\"generation\":99}")
        assertEquals(
            "E_WORKSPACE_CORRUPT",
            refusedCode("a registry with a duplicate key") { store.registry() },
        )
        // And the scanner is what refused it. JSONObject accepts the same
        // bytes and keeps the last occurrence, so the generation it reports is
        // one nothing ever wrote — which is the whole hazard, and why the
        // bytes are vetted before the parse rather than after.
        assertFalse(RishAgentCoreNative.workspaceJsonBounded(file.readBytes()))
        assertEquals(99, JSONObject(file.readText()).getInt("generation"))
    }

    /** A registry that will not parse is corrupt, never quietly replaced. */    /** A registry that will not parse is corrupt, never quietly replaced. */
    @Test
    fun aCorruptRegistryIsNeverReplacedWithAnEmptyOne() {
        val store = registry()
        store.create("Scratch")
        File(store.root, "registry.json").writeText("{\"generation\":")
        assertEquals(
            "E_WORKSPACE_CORRUPT",
            refusedCode("a truncated registry") { store.registry() },
        )
    }

    /**
     * A retried operation is the one that already happened, not a second one.
     * Without a receipt store a crash between the directory and the registry
     * would leave the person with two workspaces where they asked for one.
     */
    @Test
    fun retryingAnOperationReturnsTheWorkspaceItAlreadyMade() {
        val store = registry()
        val operation = UUID.randomUUID().toString()
        val first = store.create("Scratch", operationId = operation)
        val again = store.create("Scratch", operationId = operation)
        assertEquals(
            first.getString("workspace_id"),
            again.getString("workspace_id"),
        )
        assertEquals(1, store.list().size)
        assertEquals(1, store.registry().getInt("generation"))
        assertEquals(1, store.receipts().getJSONArray("receipts").length())
        // The directory was not made twice either.
        assertEquals(
            1,
            container(store).list()?.count { it.startsWith("Scratch") } ?: 0,
        )
    }

    /**
     * A receipt binds the operation to the request that produced it. The same
     * id with a different request is a different operation reusing an id, and
     * it is refused rather than answered with somebody else's workspace.
     */
    @Test
    fun anOperationIdCannotBeReusedForADifferentRequest() {
        val store = registry()
        val operation = UUID.randomUUID().toString()
        store.create("Scratch", operationId = operation)
        assertEquals(
            "E_WORKSPACE_CONFLICT",
            refusedCode("the same id for another display name") {
                store.create("Notes", operationId = operation)
            },
        )
        assertEquals(1, store.list().size)
    }

    /** What a caller is shown of an operation withholds the request digest. */
    @Test
    fun queryingAnOperationWithholdsTheRequestDigest() {
        val store = registry()
        val operation = UUID.randomUUID().toString()
        val record = store.create("Scratch", operationId = operation)
        val query = store.queryOperation(operation)
        assertNotNull(query)
        assertEquals(operation, query!!.getString("operation_id"))
        assertEquals(record.getString("workspace_id"), query.getString("workspace_id"))
        assertEquals("create", query.getString("operation"))
        assertEquals("committed", query.getString("outcome"))
        // The idempotency binding stays in the store.
        assertTrue(query.isNull("request_sha256"))
        assertTrue(
            store.receipts().getJSONArray("receipts").getJSONObject(0)
                .getString("request_sha256").length == 64,
        )
        // An operation that never happened has nothing to show.
        assertNull(store.queryOperation(UUID.randomUUID().toString()))
    }

    /**
     * A receipt store the shared rule refuses is corrupt. It is never replaced
     * with an empty one: that would let every operation in it run again.
     */
    @Test
    fun aCorruptReceiptStoreIsNeverReplacedWithAnEmptyOne() {
        val store = registry()
        store.create("Scratch")
        val file = File(store.root, "receipts.json")
        val text = file.readText()
        // Two receipts with one operation id: the store cannot say which
        // retry is the one that happened.
        val parsed = JSONObject(text)
        val only = parsed.getJSONArray("receipts").getJSONObject(0)
        parsed.getJSONArray("receipts").put(JSONObject(only.toString()))
        file.writeText(parsed.toString())
        assertEquals(
            "E_WORKSPACE_CORRUPT",
            refusedCode("a receipt store with a repeated operation id") {
                store.receipts()
            },
        )
    }

    /** The empty registry is a state a fresh install has, not an absence. */    /** The empty registry is a state a fresh install has, not an absence. */
    @Test
    fun aFreshInstallHasAnEmptyRegistry() {
        val store = registry()
        val registry = store.registry()
        assertEquals(1, registry.getInt("schema_version"))
        assertEquals(0, registry.getInt("generation"))
        assertEquals(0, registry.getJSONArray("records").length())
        assertTrue(store.list().isEmpty())
        assertNull(store.rootFor(UUID.randomUUID().toString()))
        assertNull(store.descriptor(UUID.randomUUID().toString()))
    }
}
