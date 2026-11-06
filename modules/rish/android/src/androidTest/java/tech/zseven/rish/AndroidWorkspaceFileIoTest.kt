package tech.zseven.rish

import android.system.Os
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.MediumTest
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.AndroidWorkspaceFileIo
import tech.zseven.rish.runtime.AndroidWorkspaceFiles
import tech.zseven.rish.runtime.AndroidWorkspaceRegistry
import tech.zseven.rish.runtime.AndroidWorkspaceToolExecutor
import tech.zseven.rish.runtime.AndroidWorkspaceMutation
import tech.zseven.rish.runtime.AndroidAgentRootResolver
import tech.zseven.rish.runtime.RishAgentCoreNative
import tech.zseven.rish.runtime.mutating
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
@MediumTest
class AndroidWorkspaceFileIoTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    /** An ancestor rename after opening must never redirect publication outside the workspace. */
    @Test fun aPinnedParentSurvivesItsPathBeingReplacedByAnOutsideSymlink() {
        assumeTrue("rish agent core is not staged in this build", RishAgentCoreNative.available)
        val home = File(context.cacheDir, "file-io-${UUID.randomUUID()}")
        val root = File(home, "workspace").apply { assertTrue(mkdirs()) }
        val current = File(root, "current").apply { assertTrue(mkdir()) }
        val original = File(root, "original")
        val outside = File(home, "outside").apply { assertTrue(mkdir()) }
        File(current, "notes.md").writeText("original\n")
        File(outside, "notes.md").writeText("outside\n")
        var replacedWithLink = false
        try {
            AndroidWorkspaceFileIo.Parent.open(root, "current/notes.md").use { existing ->
                AndroidWorkspaceFileIo.Parent.open(root, "current/new.md").use { fresh ->
                    val snapshot = existing.snapshot(requireContent = true)
                    assertNotNull(snapshot)
                    assertEquals("original\n", snapshot!!.bytes!!.toString(Charsets.UTF_8))
                    assertEquals(null, fresh.snapshot())

                    assertTrue(current.renameTo(original))
                    Os.symlink(outside.absolutePath, current.absolutePath)
                    replacedWithLink = true

                    val saved = existing.write("saved\n".toByteArray(), snapshot.revision, createOnly = false)
                    val created = fresh.write("created\n".toByteArray(), null, createOnly = true)
                    assertFalse(saved.second)
                    assertTrue(created.second)
                    assertEquals("saved\n", File(original, "notes.md").readText())
                    assertEquals("created\n", File(original, "new.md").readText())
                    assertEquals("outside\n", File(outside, "notes.md").readText())
                    assertFalse(File(outside, "new.md").exists())
                    assertEquals(saved.first.revision, existing.snapshot()!!.revision)
                    assertEquals(created.first.revision, fresh.snapshot()!!.revision)
                    assertTrue(File(root.parentFile, ".rish-file-recovery").listFiles().orEmpty().isEmpty())
                }
            }
        } finally {
            // Remove the link itself before recursive cleanup can inspect its target.
            if (replacedWithLink) current.delete()
            home.deleteRecursively()
        }
    }

    private fun withAgent(body: (AndroidWorkspaceToolExecutor, JSONObject, File, AndroidWorkspaceRegistry) -> Unit) {
        assumeTrue("rish agent core is not staged in this build", RishAgentCoreNative.available)
        val home = File(context.cacheDir, "file-io-agent-${UUID.randomUUID()}")
        try {
            val registry = AndroidWorkspaceRegistry(home)
            val record = registry.create("file publication test")
            val id = record.getString("workspace_id")
            val roots = AndroidAgentRootResolver(registry)
            val root = roots.resolve(id, null, record.getInt("binding_revision"))
                ?: error("The newly created workspace did not resolve")
            body(AndroidWorkspaceToolExecutor(registry, roots), root, registry.rootFor(id)!!, registry)
        } finally {
            home.deleteRecursively()
        }
    }

    private fun assertOnlyPublishedFile(directory: File, path: String) {
        assertEquals(listOf(path), directory.list()!!.toList())
        val recovery = File(directory.parentFile, ".rish-file-recovery")
        assertTrue(!recovery.exists() || recovery.isDirectory)
        assertTrue("No edit backup should remain after a completed publication or rollback", recovery.listFiles().orEmpty().isEmpty())
    }

    /** The real agent publishes after the browser's last check, before its atomic exchange. */
    @Test fun anAgentOverwriteImmediatelyBeforePublicationSurvivesABrowserConflict() =
        withAgent { agent, root, directory, _ ->
            val path = "notes.md"
            agent.execute("write_file", JSONObject().put("path", path).put("content", "initial\n"), root)
            AndroidWorkspaceFileIo.Parent.open(directory, path).use { parent ->
                val revision = parent.snapshot(requireContent = true)!!.revision
                var agentWrites = 0
                var conflict: AndroidWorkspaceFiles.Refused? = null
                try {
                    parent.write(
                        "browser\n".toByteArray(), revision, createOnly = false,
                        beforePublish = {
                            val result = agent.execute(
                                "write_file", JSONObject().put("path", path).put("content", "changed\n"), root,
                            )
                            assertEquals("ok", result.getString("status"))
                            assertEquals("changed\n", File(directory, path).readText())
                            agentWrites++
                        },
                    )
                } catch (refused: AndroidWorkspaceFiles.Refused) {
                    conflict = refused
                }
                assertEquals(1, agentWrites)
                assertEquals("E_WORKSPACE_CONFLICT", conflict?.code)
                assertEquals("changed\n", File(directory, path).readText())
                assertEquals("changed\n", parent.snapshot(requireContent = true)!!.bytes!!.toString(Charsets.UTF_8))
                assertOnlyPublishedFile(directory, path)
            }
        }

    @Test fun anAgentCreateImmediatelyBeforePublicationCannotBeClobbered() =
        withAgent { agent, root, directory, _ ->
            val path = "new.md"
            AndroidWorkspaceFileIo.Parent.open(directory, path).use { parent ->
                assertEquals(null, parent.snapshot())
                var agentWrites = 0
                var conflict: AndroidWorkspaceFiles.Refused? = null
                try {
                    parent.write(
                        "browser\n".toByteArray(), null, createOnly = true,
                        beforePublish = {
                            val result = agent.execute(
                                "write_file", JSONObject().put("path", path).put("content", "agent\n"), root,
                            )
                            assertEquals("ok", result.getString("status"))
                            assertEquals("agent\n", File(directory, path).readText())
                            agentWrites++
                        },
                    )
                } catch (refused: AndroidWorkspaceFiles.Refused) {
                    conflict = refused
                }
                assertEquals(1, agentWrites)
                assertEquals("E_WORKSPACE_CONFLICT", conflict?.code)
                assertEquals("agent\n", File(directory, path).readText())
                assertEquals("agent\n", parent.snapshot(requireContent = true)!!.bytes!!.toString(Charsets.UTF_8))
                assertOnlyPublishedFile(directory, path)
            }
        }

    /** A second agent publication must not be overwritten while recovering the first one. */
    @Test fun aNewerAgentWriteKeepsItsPathAndTheDisplacedVersionIsRecovered() =
        withAgent { agent, root, directory, _ ->
            val path = "notes.md"
            agent.execute("write_file", JSONObject().put("path", path).put("content", "initial"), root)
            AndroidWorkspaceFileIo.Parent.open(directory, path).use { parent ->
                val revision = parent.snapshot(requireContent = true)!!.revision
                val agentWrites = mutableListOf<String>()
                var conflict: AndroidWorkspaceFiles.Refused? = null
                try {
                    parent.write(
                        "browser".toByteArray(), revision, createOnly = false,
                        beforePublish = {
                            val result = agent.execute(
                                "write_file", JSONObject().put("path", path).put("content", "agent first"), root,
                            )
                            assertEquals("ok", result.getString("status"))
                            assertEquals("agent first", File(directory, path).readText())
                            agentWrites.add("first")
                        },
                        afterExchange = {
                            assertEquals("browser", File(directory, path).readText())
                            val result = agent.execute(
                                "write_file", JSONObject().put("path", path).put("content", "agent latest"), root,
                            )
                            assertEquals("ok", result.getString("status"))
                            assertEquals("agent latest", File(directory, path).readText())
                            agentWrites.add("latest")
                        },
                    )
                } catch (refused: AndroidWorkspaceFiles.Refused) {
                    conflict = refused
                }
                assertEquals(listOf("first", "latest"), agentWrites)
                assertEquals("E_WORKSPACE_CONFLICT", conflict?.code)
                assertEquals("agent latest", File(directory, path).readText())
                val entries = directory.listFiles()!!.toList()
                val recovery = File(directory.parentFile, ".rish-file-recovery")
                val backups = recovery.listFiles()!!.toList()
                assertEquals(1, backups.size)
                val backup = backups.single()
                assertTrue(backup.isFile)
                assertEquals("agent first", backup.readText())
                assertFalse(backup.canonicalPath.startsWith(directory.canonicalPath + File.separator))
                assertEquals(recovery.canonicalFile, backup.parentFile!!.canonicalFile)
                var refusedRecoveryRead = false
                try {
                    agent.execute(
                        "read_file",
                        JSONObject().put("path", "../.rish-file-recovery/${backup.name}"),
                        root,
                    )
                } catch (_: AndroidWorkspaceToolExecutor.Refused) {
                    refusedRecoveryRead = true
                }
                assertTrue("Agent paths must not reach retained bytes outside the workspace", refusedRecoveryRead)
                assertFalse(entries.any { it.name.endsWith(".rish-staging") })
                assertEquals(setOf(path), entries.map { it.name }.toSet())
            }
        }

    @Test fun anActualAgentWriterWaitsForTheEntireBrowserPublication() =
        withAgent { agent, root, directory, registry ->
            val path = "notes.md"
            val id = root.getString("workspace_id")
            agent.execute("write_file", JSONObject().put("path", path).put("content", "initial"), root)
            val started = CountDownLatch(1)
            val write = FutureTask<JSONObject> {
                started.countDown()
                agent.execute(
                    "write_file", JSONObject().put("path", path).put("content", "agent latest"), root,
                )
            }
            val writer = Thread(write, "workspace-agent-writer")
            try {
                registry.mutating(id) {
                    AndroidWorkspaceFileIo.Parent.open(directory, path).use { parent ->
                        val revision = parent.snapshot(requireContent = true)!!.revision
                        val saved = parent.write(
                            "browser".toByteArray(), revision, createOnly = false,
                            beforePublish = {
                                writer.start()
                                assertTrue(started.await(5, TimeUnit.SECONDS))
                                val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
                                while (!AndroidWorkspaceMutation.waiting(registry.root, id, writer) &&
                                    !write.isDone && System.nanoTime() < deadline
                                ) Thread.yield()
                                assertTrue(
                                    "The real agent must queue on the same workspace mutation lock",
                                    AndroidWorkspaceMutation.waiting(registry.root, id, writer),
                                )
                                assertFalse(write.isDone)
                            },
                        )
                        assertFalse(saved.second)
                        assertEquals("browser", File(directory, path).readText())
                        assertFalse("The agent must wait until the whole browser mutation ends", write.isDone)
                    }
                }
                assertEquals("ok", write.get(10, TimeUnit.SECONDS).getString("status"))
                assertEquals("agent latest", File(directory, path).readText())
                assertOnlyPublishedFile(directory, path)
            } finally {
                writer.interrupt()
                writer.join(5000)
                assertFalse("Agent writer did not finish after the browser released its lock", writer.isAlive)
            }
        }
}
