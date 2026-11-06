package tech.zseven.rish

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.MediumTest
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.RishLibgit2Native
import java.io.File
import java.util.UUID

/**
 * Reading a repository's state on the device.
 *
 * This is the layer the project context stands on: what is in the index, and
 * which of it differs from the last commit. It decides nothing -- eligibility
 * and selection belong to the shared core -- so what these check is that the
 * reading is right and says the same thing every time.
 */
@RunWith(AndroidJUnit4::class)
@MediumTest
class AndroidProjectGitStateTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    private fun repository(body: (File) -> Unit) {
        assumeTrue("libgit2 is not staged in this build", RishLibgit2Native.available)
        val root = File(context.cacheDir, "project-git-${UUID.randomUUID()}")
        try {
            assertTrue(root.mkdirs())
            body(root)
        } finally {
            root.deleteRecursively()
        }
    }

    private fun read(root: File): JSONObject {
        val answer = JSONObject(RishLibgit2Native.readRepositoryState(null, root.absolutePath))
        assertTrue("$answer", answer.getBoolean("ok"))
        return answer
    }

    private fun entriesOf(answer: JSONObject): Map<String, JSONObject> {
        val entries = answer.getJSONArray("entries")
        return (0 until entries.length()).associate { index ->
            val entry = entries.getJSONObject(index)
            entry.getString("path") to entry
        }
    }

    /** A repository with one commit: everything in it is unchanged. */
    @Test fun acommittedFileReadsAsUnchanged() = repository { root ->
        assertEquals("ok:first", RishLibgit2Native.roundTrip(root.absolutePath))
        val answer = read(root)
        assertNotNull(answer.getString("head"))
        assertEquals("master", answer.getString("branch"))
        // A repository with nothing in progress: no merge, no rebase.
        assertEquals(0, answer.getInt("repository_state"))
        val entries = entriesOf(answer)
        val hello = entries.getValue("hello.txt")
        // Neither diff touched it. Turning the pair into one word is the
        // candidate layer's job, so this layer reports the pair.
        assertEquals(false, hello.getBoolean("staged"))
        assertEquals(false, hello.getBoolean("unstaged"))
        assertEquals(0, hello.getInt("stage"))
        assertEquals(19L, hello.getLong("size"))
        // A regular file, which is what the mode says and what eligibility
        // above this will ask about.
        assertEquals(0b1000000110100100, hello.getInt("mode"))
        assertEquals(40, hello.getString("oid").length)
    }

    /** A file edited after being committed reads as modified, not unchanged. */
    @Test fun anEditedFileReadsAsModified() = repository { root ->
        RishLibgit2Native.roundTrip(root.absolutePath)
        File(root, "hello.txt").writeText("changed on the device\n")
        val hello = entriesOf(read(root)).getValue("hello.txt")
        assertEquals(true, hello.getBoolean("unstaged"))
        assertEquals(false, hello.getBoolean("staged"))
    }

    /** A repository with no commits yet is not an error; it is a state. */
    @Test fun aRepositoryWithNoCommitsStillReads() = repository { root ->
        // roundTrip commits, so make a bare init by hand instead: an empty
        // repository is what a project looks like the moment it is created.
        val git = File(root, ".git")
        assertTrue(git.mkdirs())
        File(git, "HEAD").writeText("ref: refs/heads/main\n")
        File(git, "config").writeText("[core]\n\trepositoryformatversion = 0\n\tbare = false\n")
        assertTrue(File(git, "objects").mkdirs())
        assertTrue(File(git, "refs/heads").mkdirs())
        val answer = read(root)
        assertTrue("head should be null", answer.isNull("head"))
        assertEquals(0, answer.getJSONArray("entries").length())
    }

    /** The same repository read twice says exactly the same thing. */
    @Test fun readingTwiceGivesTheSameBytes() = repository { root ->
        RishLibgit2Native.roundTrip(root.absolutePath)
        File(root, "b.txt").writeText("second\n")
        File(root, "a.txt").writeText("first\n")
        val first = RishLibgit2Native.readRepositoryState(null, root.absolutePath)
        val second = RishLibgit2Native.readRepositoryState(null, root.absolutePath)
        assertEquals(first, second)
        // And untracked files are not in the index, so they are not entries.
        val paths = entriesOf(JSONObject(first)).keys
        assertEquals(setOf("hello.txt"), paths)
    }

    /** A path that is not a repository is refused, with where it stopped. */
    @Test fun somethingThatIsNotARepositoryIsRefused() = repository { root ->
        val answer = JSONObject(RishLibgit2Native.readRepositoryState(null, root.absolutePath))
        assertEquals("$answer", false, answer.getBoolean("ok"))
        assertEquals("open", answer.getString("stage"))
    }
}
