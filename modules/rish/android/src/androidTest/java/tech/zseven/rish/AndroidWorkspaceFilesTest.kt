package tech.zseven.rish

import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.MediumTest
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.AndroidAgentRootResolver
import tech.zseven.rish.runtime.AndroidWorkspaceFiles
import tech.zseven.rish.runtime.AndroidWorkspaceRegistry
import tech.zseven.rish.runtime.RishAgentCoreNative
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * What the Files drawer may see.
 *
 * The entries it reads are a contract with the Files reader, which refuses a
 * result whose revision is not a digest, whose name does not end the path, or
 * whose timestamp is not canonical — so these hold the shape as much as the
 * behaviour. The containment rules are the same ones the agent's executor
 * keeps, because a person browsing and an agent writing have to agree about
 * which bytes belong to the workspace.
 */
@RunWith(AndroidJUnit4::class)
@MediumTest
class AndroidWorkspaceFilesTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    private class Fixture(
        val files: AndroidWorkspaceFiles,
        val root: JSONObject,
        val directory: File,
        val registry: AndroidWorkspaceRegistry,
    )

    private fun fixture(body: (Fixture) -> Unit) {
        assumeTrue("rish agent core is not staged in this build", RishAgentCoreNative.available)
        val home = File(context.cacheDir, "files-${UUID.randomUUID()}")
        try {
            val workspaces = AndroidWorkspaceRegistry(home)
            val created = workspaces.create("demo")
            val workspaceId = created.getString("workspace_id")
            val root = JSONObject().put("schema_version", 1)
                .put("workspace_id", workspaceId)
                .put("binding_revision", 1)
                .put("project_id", JSONObject.NULL)
            body(
                Fixture(
                    AndroidWorkspaceFiles(workspaces, AndroidAgentRootResolver(workspaces)),
                    root,
                    workspaces.rootFor(workspaceId)!!,
                    workspaces,
                ),
            )
        } finally {
            home.deleteRecursively()
        }
    }

    private fun externalDirectory(body: (File) -> Unit) {
        val directory = File(context.cacheDir, "outside-files-${UUID.randomUUID()}")
        assertTrue(directory.mkdir())
        try {
            body(directory)
        } finally {
            directory.deleteRecursively()
        }
    }

    private val UUID_SHAPE =
        Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")

    private fun refusal(body: () -> JSONObject): String = try {
        "answered: " + body()
    } catch (refused: AndroidWorkspaceFiles.Refused) {
        refused.code
    }

    private fun listRequest(f: Fixture, path: String, max: Int = 1000): JSONObject = JSONObject()
        .put("schema_version", 1).put("root", f.root).put("path", path).put("max_entries", max)

    private fun readRequest(f: Fixture, path: String, max: Int = 1024 * 1024): JSONObject =
        JSONObject().put("schema_version", 1).put("root", f.root).put("path", path)
            .put("max_bytes", max)

    private fun writeRequest(
        f: Fixture,
        path: String,
        content: String,
        expected: Any = JSONObject.NULL,
        createOnly: Boolean = true,
    ): JSONObject = JSONObject().put("schema_version", 1).put("root", f.root).put("path", path)
        .put("content", content).put("expected_revision", expected).put("create_only", createOnly)

    /**
     * A write, a listing and a read over the same file, in the shapes the
     * reader validates: the name ends the path, the revision is a digest, and
     * the timestamp is the canonical one.
     */
    @Test fun aFileIsWrittenListedAndReadBack() = fixture { f ->
        val written = f.files.write(writeRequest(f, "notes.md", "hello\n"))
        assertEquals(true, written.getBoolean("created"))
        val file = written.getJSONObject("file")
        assertEquals("notes.md", file.getString("path"))
        assertEquals("notes.md", file.getString("name"))
        assertEquals("file", file.getString("kind"))
        assertEquals(6L, file.getLong("size"))
        assertTrue(file.getString("revision").matches(Regex("^[0-9a-f]{64}$")))
        assertTrue(
            file.getString("modified_at"),
            file.getString("modified_at")
                .matches(Regex("^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{3}Z$")),
        )

        val listing = f.files.list(listRequest(f, ""))
        assertEquals("", listing.getString("path"))
        val entries = listing.getJSONArray("entries")
        assertEquals(1, entries.length())
        assertEquals("notes.md", entries.getJSONObject(0).getString("path"))

        val read = f.files.read(readRequest(f, "notes.md"))
        assertEquals("hello\n", read.getString("content"))
        assertEquals(file.getString("revision"), read.getJSONObject("file").getString("revision"))
    }

    /** A nested path is listed under its own prefix, not its bare name. */
    @Test fun aNestedEntryKeepsItsPath() = fixture { f ->
        File(f.directory, "src").mkdirs()
        f.files.write(writeRequest(f, "src/main.kt", "fun main() {}\n"))
        val listing = f.files.list(listRequest(f, "src"))
        val entry = listing.getJSONArray("entries").getJSONObject(0)
        assertEquals("src/main.kt", entry.getString("path"))
        assertEquals("main.kt", entry.getString("name"))
    }

    /**
     * The two ways of saying "I know what is there". A create that would
     * overwrite and a stale revision are both conflicts, not silent writes.
     */
    @Test fun aWriteWillNotOverwriteWhatItDidNotExpect() = fixture { f ->
        val first = f.files.write(writeRequest(f, "notes.md", "one\n"))
        val revision = first.getJSONObject("file").getString("revision")
        assertEquals(
            "E_WORKSPACE_CONFLICT",
            refusal { f.files.write(writeRequest(f, "notes.md", "two\n")) },
        )
        assertEquals(
            "E_WORKSPACE_CONFLICT",
            refusal {
                f.files.write(
                    writeRequest(f, "notes.md", "two\n", expected = "0".repeat(64), createOnly = false),
                )
            },
        )
        val second = f.files.write(
            writeRequest(f, "notes.md", "two\n", expected = revision, createOnly = false),
        )
        assertEquals(false, second.getBoolean("created"))
        assertEquals("two\n", f.files.read(readRequest(f, "notes.md")).getString("content"))
    }

    @Test fun aSameSizeExternalEditWithTheSameTimestampStillConflicts() = fixture { f ->
        val first = f.files.write(writeRequest(f, "notes.md", "first\n"))
        val revision = first.getJSONObject("file").getString("revision")
        val file = File(f.directory, "notes.md")
        val timestamp = file.lastModified()
        file.writeText("later\n")
        assertTrue(file.setLastModified(timestamp))
        assertEquals(timestamp, file.lastModified())
        assertEquals(6L, file.length())

        assertEquals(
            "E_WORKSPACE_CONFLICT",
            refusal {
                f.files.write(writeRequest(f, "notes.md", "stale\n", revision, createOnly = false))
            },
        )
        assertEquals("later\n", file.readText())
    }

    @Test fun leafSymlinksAreRefusedEvenInsideTheWorkspaceOrWhenDangling() = fixture { f ->
        externalDirectory { outside ->
            val inside = File(f.directory, "original.txt").apply { writeText("inside\n") }
            val external = File(outside, "original.txt").apply { writeText("outside\n") }
            val missing = File(outside, "missing.txt")
            val alias = File(f.directory, "alias.txt")
            for (target in listOf(inside, external, missing)) {
                Os.symlink(target.absolutePath, alias.absolutePath)
                try {
                    assertEquals("E_WORKSPACE_CONFLICT", refusal { f.files.read(readRequest(f, "alias.txt")) })
                    assertEquals("E_WORKSPACE_CONFLICT", refusal { f.files.write(writeRequest(f, "alias.txt", "changed")) })
                    assertTrue(OsConstants.S_ISLNK(Os.lstat(alias.absolutePath).st_mode))
                    assertEquals("inside\n", inside.readText())
                    assertEquals("outside\n", external.readText())
                    assertFalse(missing.exists())
                } finally {
                    Os.remove(alias.absolutePath)
                }
            }
        }
    }

    @Test fun intermediateSymlinksCannotRedirectReadsWritesOrDirectoryCreation() = fixture { f ->
        externalDirectory { outside ->
            val inside = File(f.directory, "src").apply { assertTrue(mkdir()) }
            val missing = File(outside, "missing")
            File(inside, "notes.md").writeText("inside\n")
            File(outside, "notes.md").writeText("outside\n")
            val alias = File(f.directory, "alias")
            for (target in listOf(inside, outside, missing)) {
                Os.symlink(target.absolutePath, alias.absolutePath)
                try {
                    assertEquals("E_WORKSPACE_CONFLICT", refusal { f.files.read(readRequest(f, "alias/notes.md")) })
                    assertEquals("E_WORKSPACE_CONFLICT", refusal { f.files.write(writeRequest(f, "alias/new.md", "changed")) })
                    assertEquals(
                        "E_WORKSPACE_CONFLICT",
                        refusal {
                            f.files.createDirectory(
                                JSONObject().put("schema_version", 1).put("root", f.root)
                                    .put("path", "alias/new-folder"),
                            )
                        },
                    )
                    assertEquals("inside\n", File(inside, "notes.md").readText())
                    assertEquals("outside\n", File(outside, "notes.md").readText())
                    assertFalse(File(inside, "new.md").exists())
                    assertFalse(File(outside, "new.md").exists())
                    assertFalse(File(inside, "new-folder").exists())
                    assertFalse(File(outside, "new-folder").exists())
                    assertFalse(missing.exists())
                } finally {
                    Os.remove(alias.absolutePath)
                }
            }
        }
    }

    @Test fun hardlinkedFilesAreRefusedWithoutChangingEitherName() = fixture { f ->
        externalDirectory { outside ->
            val original = File(outside, "original.txt").apply { writeText("preserved\n") }
            val alias = File(f.directory, "alias.txt")
            try {
                Os.link(original.absolutePath, alias.absolutePath)
            } catch (error: ErrnoException) {
                if (error.errno != OsConstants.EACCES && error.errno != OsConstants.EPERM) throw error
                // SELinux forbids app-UID hard links on some Android images.
                // This is an unavailable fixture, not proof of the file guard.
                assumeTrue("Android sandbox denied creation of the hard-link fixture", false)
            }
            assertEquals(2L, Os.lstat(alias.absolutePath).st_nlink)
            assertEquals("E_WORKSPACE_CONFLICT", refusal { f.files.read(readRequest(f, "alias.txt")) })
            assertEquals("E_WORKSPACE_CONFLICT", refusal { f.files.write(writeRequest(f, "alias.txt", "changed")) })
            assertEquals("preserved\n", alias.readText())
            assertEquals("preserved\n", original.readText())
        }
    }

    @Test fun predictableStagingSymlinksCannotRedirectASave() = fixture { f ->
        externalDirectory { outside ->
            val external = File(outside, "untouched.txt").apply { writeText("preserved\n") }
            val aliases = listOf("notes.md.rish-staging", ".notes.md.rish-staging")
                .map { File(f.directory, it) }
            aliases.forEach { Os.symlink(external.absolutePath, it.absolutePath) }
            try {
                val first = f.files.write(writeRequest(f, "notes.md", "first\n"))
                val revision = first.getJSONObject("file").getString("revision")
                f.files.write(writeRequest(f, "notes.md", "saved\n", revision, createOnly = false))
                assertEquals("saved\n", File(f.directory, "notes.md").readText())
                assertEquals("preserved\n", external.readText())
                aliases.forEach { assertTrue(OsConstants.S_ISLNK(Os.lstat(it.absolutePath).st_mode)) }
            } finally {
                aliases.forEach { Os.remove(it.absolutePath) }
            }
        }
    }

    @Test fun competingBridgeCreatesPublishExactlyOneCompleteFile() = fixture { f ->
        val other = AndroidWorkspaceFiles(f.registry, AndroidAgentRootResolver(f.registry))
        val executor = Executors.newFixedThreadPool(2)
        try {
            repeat(8) { index ->
                val path = "competing-$index.txt"
                val ready = CountDownLatch(2)
                val start = CountDownLatch(1)
                val writes = listOf(f.files, other).mapIndexed { writer, files ->
                    val content = "writer-$writer:" + "x".repeat(16 * 1024)
                    executor.submit<Pair<String, String>> {
                        ready.countDown()
                        assertTrue(start.await(5, TimeUnit.SECONDS))
                        val result = try {
                            files.write(writeRequest(f, path, content))
                            "saved"
                        } catch (refused: AndroidWorkspaceFiles.Refused) {
                            refused.code
                        }
                        Pair(result, content)
                    }
                }
                assertTrue(ready.await(5, TimeUnit.SECONDS))
                start.countDown()
                val results = writes.map { it.get(10, TimeUnit.SECONDS) }
                assertEquals(1, results.count { it.first == "saved" })
                assertEquals(1, results.count { it.first == "E_WORKSPACE_CONFLICT" })
                assertEquals(results.single { it.first == "saved" }.second, File(f.directory, path).readText())
            }
        } finally {
            executor.shutdownNow()
            assertTrue(executor.awaitTermination(5, TimeUnit.SECONDS))
        }
    }

    @Test fun anUnwritableParentLeavesTheExistingFileIntact() = fixture { f ->
        assumeTrue("Permission denial needs an unprivileged process", Os.getuid() != 0)
        val parent = File(f.directory, "locked").apply { assertTrue(mkdir()) }
        val first = f.files.write(writeRequest(f, "locked/notes.md", "preserved\n"))
        val revision = first.getJSONObject("file").getString("revision")
        try {
            Os.chmod(parent.absolutePath, 0x16d) // 0555, only this disposable nested directory.
            val code = refusal {
                f.files.write(writeRequest(f, "locked/notes.md", "changed\n", revision, createOnly = false))
            }
            assertTrue(code, code.startsWith("E_WORKSPACE_"))
            val file = File(parent, "notes.md")
            assertTrue(file.isFile)
            assertEquals("preserved\n", file.readText())
            assertEquals(listOf("notes.md"), parent.list()!!.toList())
            assertTrue(File(f.directory.parentFile, ".rish-file-recovery").listFiles().orEmpty().isEmpty())
        } finally {
            Os.chmod(parent.absolutePath, 0x1c0) // 0700, allow fixture cleanup.
        }
    }

    /** Nothing outside the workspace is readable through this. */
    @Test fun aPathThatLeavesTheWorkspaceIsRefused() = fixture { f ->
        for (path in listOf("../escape.txt", "/etc/hosts", "src/../../escape.txt")) {
            val code = refusal { f.files.list(listRequest(f, path)) }
            assertTrue(path + " -> " + code, code.startsWith("E_WORKSPACE_"))
            assertTrue(path + " -> " + code, code != "E_WORKSPACE_PERSISTENCE")
        }
    }

    /** A file the reader cannot show is refused rather than half-shown. */
    @Test fun aFileTooLargeOrNotTextIsRefused() = fixture { f ->
        File(f.directory, "big.txt").writeText("0123456789")
        assertEquals(
            "E_WORKSPACE_UNAVAILABLE",
            refusal { f.files.read(readRequest(f, "big.txt", max = 4)) },
        )
        File(f.directory, "binary.bin").writeBytes(byteArrayOf(0xC3.toByte(), 0x28))
        assertEquals(
            "E_WORKSPACE_UNAVAILABLE",
            refusal { f.files.read(readRequest(f, "binary.bin")) },
        )
    }

    /** A root this device does not hold is refused before any path is read. */
    @Test fun anUnheldRootIsRefused() = fixture { f ->
        val unknown = JSONObject(f.root.toString()).put("workspace_id", UUID.randomUUID().toString())
        assertEquals(
            "E_WORKSPACE_NOT_FOUND",
            refusal {
                f.files.list(
                    JSONObject().put("schema_version", 1).put("root", unknown)
                        .put("path", "").put("max_entries", 10),
                )
            },
        )
        val moved = JSONObject(f.root.toString()).put("binding_revision", 7)
        assertEquals(
            "E_WORKSPACE_ROOT_CHANGED",
            refusal {
                f.files.list(
                    JSONObject().put("schema_version", 1).put("root", moved)
                        .put("path", "").put("max_entries", 10),
                )
            },
        )
    }

    /** A malformed request is refused rather than half-read. */
    @Test fun aMalformedRequestIsRefused() = fixture { f ->
        assertEquals("E_WORKSPACE_INVALID", refusal { f.files.list(null) })
        assertEquals(
            "E_WORKSPACE_INVALID",
            refusal { f.files.list(JSONObject(listRequest(f, "").toString()).also { it.remove("path") }) },
        )
        assertEquals(
            "E_WORKSPACE_INVALID",
            refusal { f.files.list(JSONObject(listRequest(f, "").toString()).put("extra", 1)) },
        )
        assertEquals("E_WORKSPACE_INVALID", refusal { f.files.list(listRequest(f, "", max = 0)) })
    }

    /** An empty workspace has an empty trash, and says so. */
    @Test fun theTrashStartsEmpty() = fixture { f ->
        val trash = f.files.listTrash(
            JSONObject().put("schema_version", 1).put("root", f.root).put("max_entries", 8),
        )
        assertEquals(0, trash.getJSONArray("entries").length())
        assertEquals(0, trash.getInt("invalid_record_count"))
    }

    /**
     * Deleting is recoverable: the entry is moved whole, the receipt
     * remembers where it came from, and restoring is the move back.
     */
    @Test fun aTrashedEntryComesBackWhereItWas() = fixture { f ->
        f.files.write(writeRequest(f, "notes.md", "keep me\n"))
        val receipt = f.files.trash(
            JSONObject().put("schema_version", 1).put("root", f.root).put("path", "notes.md"),
        ).getJSONObject("receipt")
        assertEquals("notes.md", receipt.getString("original_path"))
        assertEquals("file", receipt.getString("kind"))
        assertTrue(receipt.getString("trash_id").matches(UUID_SHAPE))
        assertTrue(
            receipt.getString("deleted_at"),
            receipt.getString("deleted_at")
                .matches(Regex("^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{3}Z$")),
        )
        // Gone from the listing, and the trash itself is never listed.
        assertEquals(0, f.files.list(listRequest(f, "")).getJSONArray("entries").length())

        val listed = f.files.listTrash(
            JSONObject().put("schema_version", 1).put("root", f.root).put("max_entries", 8),
        )
        assertEquals(1, listed.getJSONArray("entries").length())
        assertEquals(
            receipt.getString("trash_id"),
            listed.getJSONArray("entries").getJSONObject(0).getString("trash_id"),
        )

        val restored = f.files.restore(
            JSONObject().put("schema_version", 1).put("root", f.root)
                .put("trash_id", receipt.getString("trash_id"))
                .put("destination_path", JSONObject.NULL),
        )
        assertEquals("notes.md", restored.getJSONObject("entry").getString("path"))
        assertEquals("keep me\n", f.files.read(readRequest(f, "notes.md")).getString("content"))
        assertEquals(
            0,
            f.files.listTrash(
                JSONObject().put("schema_version", 1).put("root", f.root).put("max_entries", 8),
            ).getJSONArray("entries").length(),
        )
    }

    /** A restore never writes over what is there now. */
    @Test fun aRestoreWillNotOverwrite() = fixture { f ->
        f.files.write(writeRequest(f, "notes.md", "first\n"))
        val receipt = f.files.trash(
            JSONObject().put("schema_version", 1).put("root", f.root).put("path", "notes.md"),
        ).getJSONObject("receipt")
        f.files.write(writeRequest(f, "notes.md", "second\n"))
        assertEquals(
            "E_WORKSPACE_CONFLICT",
            refusal {
                f.files.restore(
                    JSONObject().put("schema_version", 1).put("root", f.root)
                        .put("trash_id", receipt.getString("trash_id"))
                        .put("destination_path", JSONObject.NULL),
                )
            },
        )
        // The one that is there is untouched, and the trashed one is still
        // recoverable somewhere else.
        assertEquals("second\n", f.files.read(readRequest(f, "notes.md")).getString("content"))
        val elsewhere = f.files.restore(
            JSONObject().put("schema_version", 1).put("root", f.root)
                .put("trash_id", receipt.getString("trash_id"))
                .put("destination_path", "notes-old.md"),
        )
        assertEquals("notes-old.md", elsewhere.getJSONObject("entry").getString("path"))
        assertEquals("first\n", f.files.read(readRequest(f, "notes-old.md")).getString("content"))
    }

    /** A folder is trashed whole, contents and all. */
    @Test fun aTrashedFolderKeepsItsContents() = fixture { f ->
        File(f.directory, "src").mkdirs()
        f.files.write(writeRequest(f, "src/main.kt", "fun main() {}\n"))
        val receipt = f.files.trash(
            JSONObject().put("schema_version", 1).put("root", f.root).put("path", "src"),
        ).getJSONObject("receipt")
        assertEquals("directory", receipt.getString("kind"))
        f.files.restore(
            JSONObject().put("schema_version", 1).put("root", f.root)
                .put("trash_id", receipt.getString("trash_id"))
                .put("destination_path", JSONObject.NULL),
        )
        assertEquals("fun main() {}\n", f.files.read(readRequest(f, "src/main.kt")).getString("content"))
    }

    /** A new folder, and a rename that will not land on something. */
    @Test fun aFolderIsCreatedAndAnEntryRenamed() = fixture { f ->
        val made = f.files.createDirectory(
            JSONObject().put("schema_version", 1).put("root", f.root).put("path", "docs"),
        )
        assertEquals("directory", made.getJSONObject("directory").getString("kind"))
        assertEquals(
            "E_WORKSPACE_CONFLICT",
            refusal {
                f.files.createDirectory(
                    JSONObject().put("schema_version", 1).put("root", f.root).put("path", "docs"),
                )
            },
        )
        f.files.write(writeRequest(f, "docs/one.md", "one\n"))
        val renamed = f.files.rename(
            JSONObject().put("schema_version", 1).put("root", f.root)
                .put("source_path", "docs/one.md").put("destination_path", "docs/two.md"),
        )
        assertEquals("docs/two.md", renamed.getJSONObject("entry").getString("path"))
        assertEquals("docs/one.md", renamed.getString("from"))
        assertEquals("one\n", f.files.read(readRequest(f, "docs/two.md")).getString("content"))
        // A rename never writes over an existing entry, and a folder cannot
        // swallow itself.
        f.files.write(writeRequest(f, "docs/three.md", "three\n"))
        assertEquals(
            "E_WORKSPACE_CONFLICT",
            refusal {
                f.files.rename(
                    JSONObject().put("schema_version", 1).put("root", f.root)
                        .put("source_path", "docs/two.md").put("destination_path", "docs/three.md"),
                )
            },
        )
        assertEquals(
            "E_WORKSPACE_CONFLICT",
            refusal {
                f.files.rename(
                    JSONObject().put("schema_version", 1).put("root", f.root)
                        .put("source_path", "docs").put("destination_path", "docs/inner"),
                )
            },
        )
    }

    /** A trash holder without its contents is counted, not offered. */
    @Test fun anUnreadableTrashRecordIsCountedRatherThanListed() = fixture { f ->
        f.files.write(writeRequest(f, "notes.md", "gone\n"))
        val receipt = f.files.trash(
            JSONObject().put("schema_version", 1).put("root", f.root).put("path", "notes.md"),
        ).getJSONObject("receipt")
        File(File(f.directory, ".trash"), receipt.getString("trash_id") + "/payload")
            .deleteRecursively()
        val listed = f.files.listTrash(
            JSONObject().put("schema_version", 1).put("root", f.root).put("max_entries", 8),
        )
        assertEquals(0, listed.getJSONArray("entries").length())
        assertEquals(1, listed.getInt("invalid_record_count"))
    }

}
