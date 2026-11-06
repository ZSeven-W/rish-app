package tech.zseven.rish

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.SmallTest
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.RishLibgit2Native
import java.io.File
import java.util.UUID

/**
 * Whether the vendored libgit2 works on a device.
 *
 * Building a library, linking it and having it run are three different
 * things, and only the third one matters. The project context service makes
 * a hundred and forty-one libgit2 calls; this asks the nine that everything
 * else is built on, on real hardware, before any of that is written.
 */
@RunWith(AndroidJUnit4::class)
@SmallTest
class AndroidLibgit2FloorTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    @Test fun theVendoredLibraryIsTheOneThatWasPinned() {
        assumeTrue("libgit2 is not staged in this build", RishLibgit2Native.available)
        // The version the iOS vendor build pins, so the two hosts cannot read
        // one repository through two different libraries.
        assertEquals("1.9.6", RishLibgit2Native.version())
    }

    @Test fun itHasTheTransportsAProjectNeeds() {
        assumeTrue("libgit2 is not staged in this build", RishLibgit2Native.available)
        val features = RishLibgit2Native.features().split(",").toSet()
        // Without these two a fetch fails at the point of use rather than
        // here, which is the wrong place to find out.
        assertTrue("$features", "https" in features)
        assertTrue("$features", "ssh" in features)
        assertTrue("$features", "threads" in features)
    }

    /**
     * A repository created, a file staged through the index, a tree written,
     * a commit made and read back -- on the device, in the app's own storage.
     */
    @Test fun aRepositoryCanBeWrittenAndReadOnTheDevice() {
        assumeTrue("libgit2 is not staged in this build", RishLibgit2Native.available)
        val root = File(context.cacheDir, "libgit2-floor-${UUID.randomUUID()}")
        try {
            assertTrue(root.mkdirs())
            val answer = RishLibgit2Native.roundTrip(root.absolutePath)
            assertEquals("ok:first", answer)
            // And the repository is really on disk, not only in libgit2's head.
            assertTrue("no .git directory", File(root, ".git").isDirectory)
            assertTrue("no object database", File(root, ".git/objects").isDirectory)
        } finally {
            root.deleteRecursively()
        }
    }
}
