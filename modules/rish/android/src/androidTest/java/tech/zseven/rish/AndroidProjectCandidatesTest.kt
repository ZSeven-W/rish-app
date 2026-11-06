package tech.zseven.rish

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.MediumTest
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.AndroidProjectCandidates
import tech.zseven.rish.runtime.RishAgentCoreNative
import tech.zseven.rish.runtime.RishLibgit2Native
import java.io.File
import java.util.UUID

/**
 * A project's candidates, listed on the device.
 *
 * The repository is real, the policy is the shared core's, and the rules in
 * between are the ones iOS applies. What these check is that a listing says
 * the same thing about each kind of file iOS would, and that a page can only
 * be continued for the listing it came from.
 */
@RunWith(AndroidJUnit4::class)
@MediumTest
class AndroidProjectCandidatesTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    /** A repository with one of each kind of file, all committed. */
    private fun project(body: (File, AndroidProjectCandidates) -> Unit) {
        assumeTrue(RishLibgit2Native.available && RishAgentCoreNative.available)
        val root = File(context.cacheDir, "candidates-${UUID.randomUUID()}")
        try {
            assertTrue(root.mkdirs())
            assertEquals("ok:first", RishLibgit2Native.roundTrip(root.absolutePath))
            body(root, AndroidProjectCandidates())
        } finally {
            root.deleteRecursively()
        }
    }

    private fun byPath(capture: AndroidProjectCandidates.Capture): Map<String, JSONObject> =
        capture.candidates.associateBy { it.getString("path") }

    @Test fun aCommittedFileIsAnUnchangedEligibleCandidate() = project { root, listing ->
        val hello = byPath(listing.capture(null, root.absolutePath)).getValue("hello.txt")
        assertEquals(true, hello.getBoolean("eligible"))
        assertEquals("unchanged", hello.getString("git_state"))
        assertTrue(hello.isNull("omission_reason"))
        assertEquals(40, hello.getString("revision").length)
        assertEquals(19L, hello.getLong("size"))
    }

    @Test fun anEditedFileIsUnstagedAndStillEligible() = project { root, listing ->
        File(root, "hello.txt").writeText("edited\n")
        val hello = byPath(listing.capture(null, root.absolutePath)).getValue("hello.txt")
        assertEquals("unstaged", hello.getString("git_state"))
        assertEquals(true, hello.getBoolean("eligible"))
    }

    /** The order is by path, by code unit, which is what iOS does. */
    @Test fun candidatesComeInPathOrder() = project { root, listing ->
        // Add more files through a second commit-less index write: the floor
        // helper only commits one file, so stage the rest by hand via git.
        stage(root, "b.txt", "b\n"); stage(root, "a.txt", "a\n"); stage(root, "Z.txt", "z\n")
        val paths = listing.capture(null, root.absolutePath).candidates.map { it.getString("path") }
        assertEquals(listOf("Z.txt", "a.txt", "b.txt", "hello.txt"), paths)
    }

    @Test fun aQueryNarrowsByFoldedSubstring() = project { root, listing ->
        stage(root, "docs/README.md", "r\n"); stage(root, "src/main.rs", "m\n")
        val capture = listing.capture(null, root.absolutePath)
        val page = listing.page(capture, query = "readme", cursor = null)
        val paths = (0 until page.getJSONArray("candidates").length())
            .map { page.getJSONArray("candidates").getJSONObject(it).getString("path") }
        assertEquals(listOf("docs/README.md"), paths)
        assertTrue(page.isNull("next_cursor"))
    }

    @Test fun aCursorContinuesTheSameListingAndNothingElse() = project { root, listing ->
        stage(root, "a.txt", "a\n"); stage(root, "b.txt", "b\n"); stage(root, "c.txt", "c\n")
        val capture = listing.capture(null, root.absolutePath)
        val first = listing.page(capture, "", null, limit = 2)
        assertEquals(2, first.getJSONArray("candidates").length())
        val cursor = first.getString("next_cursor")
        val second = listing.page(capture, "", cursor, limit = 2)
        assertEquals(2, second.getJSONArray("candidates").length())
        assertTrue(second.isNull("next_cursor"))
        // A cursor issued for one query does not continue another.
        assertEquals(AndroidProjectCandidates.INVALID_CURSOR, refusal { listing.page(capture, "a", cursor) })
        // A byte flipped anywhere is not a cursor this issued.
        val forged = cursor.substring(0, 10) + (if (cursor[10] == 'A') 'B' else 'A') + cursor.substring(11)
        assertEquals(AndroidProjectCandidates.INVALID_CURSOR, refusal { listing.page(capture, "", forged) })
        // And a listing taken after the project changed is a different listing.
        File(root, "a.txt").writeText("changed\n")
        val moved = listing.capture(null, root.absolutePath)
        assertEquals(AndroidProjectCandidates.CHANGED, refusal { listing.page(moved, "", cursor) })
        // A cursor from another process (another key) is not accepted either.
        assertEquals(AndroidProjectCandidates.INVALID_CURSOR, refusal { AndroidProjectCandidates().page(capture, "", cursor) })
    }

    private fun refusal(body: () -> Unit): String = try { body(); "answered" } catch (r: AndroidProjectCandidates.Refused) { r.code }

    /** Writes a file and stages it, the way `git add` does. */
    private fun stage(root: File, path: String, text: String) {
        val file = File(root, path); file.parentFile?.mkdirs(); file.writeText(text)
        assertEquals("ok", RishLibgit2Native.stagePath(null, root.absolutePath, path))
    }
}
