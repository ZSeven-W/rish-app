package tech.zseven.rish.runtime

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException

/**
 * A PDF's pages as pictures, for a model that reads images.
 *
 * Android has no PDF *text* API a person's phone can be counted on to have
 * (the platform one needs Android 15 or a Play system update most phones
 * sold here never get), so a PDF reaches the model the way a person would
 * read it: every page, drawn. That also reads a scanned document, which text
 * extraction cannot.
 *
 * Every page or none. A PDF that is too long, locked, or will not draw is
 * refused whole -- sending the first pages of a document would answer a
 * question about pages the model never saw.
 *
 * Drawing uses the platform's `PdfRenderer` (PDFium inside the system,
 * updated with it) in this process. One document is drawn at a time: the
 * renderer is not safe to use from two threads, and one page's bitmap is the
 * memory this needs. Not isolated: a PDF that crashes PDFium takes the app
 * with it, and drawing cannot be interrupted. Moving this into a killable
 * isolated process is the known next step.
 *
 * Every round of a conversation sends its history again, so drawn pages are
 * kept in memory by the file's identity: an attachment's bytes never change
 * once stored.
 */
internal object AndroidPdfPages {

    class Refused(val code: String, val reason: String) : Exception(reason)

    /** One drawn page: JPEG bytes. */
    class Page(val jpeg: ByteArray)

    const val MAX_PAGES = 20
    /** The long edge of a drawn page, in pixels: a letter page at about 145 dpi. */
    const val LONG_EDGE = 1600
    const val QUALITY = 85
    /**
     * A page longer than this many times its width (or the reverse) would be
     * drawn too thin to read -- a till receipt becomes a 16-pixel strip. It is
     * refused rather than sent unreadable.
     */
    const val MAX_ASPECT = 3f
    private const val CACHE_BYTES = 24L * 1024L * 1024L

    private val lock = Any()
    private val cache = object : LinkedHashMap<String, List<Page>>(16, 0.75f, true) {}
    private var cachedBytes = 0L

    /**
     * Every page of `file`, in order. `pageBudget` and `byteBudget` are what
     * the request may still add; a document past either is refused, not cut.
     */
    fun render(file: File, pageBudget: Int, byteBudget: Long): List<Page> = synchronized(lock) {
        val key = "${file.absolutePath}|${file.length()}|${file.lastModified()}|$LONG_EDGE|$QUALITY"
        val known = cache[key]
        val pages = known ?: try {
            drawAll(file, pageBudget, byteBudget)
        } catch (_: OutOfMemoryError) {
            throw Refused(TOO_LARGE, "A PDF attachment is too large to draw")
        }
        if (pages.size > pageBudget) {
            throw Refused(TOO_LARGE, "The PDFs in this conversation have too many pages")
        }
        if (pages.sumOf { it.jpeg.size.toLong() } > byteBudget) {
            throw Refused(TOO_LARGE, "The pictures in this conversation are too large to send")
        }
        if (known == null) remember(key, pages)
        pages
    }

    private fun remember(key: String, pages: List<Page>) {
        val size = pages.sumOf { it.jpeg.size.toLong() }
        if (size > CACHE_BYTES) return
        cache[key] = pages
        cachedBytes += size
        val eldest = cache.entries.iterator()
        while (cachedBytes > CACHE_BYTES && eldest.hasNext()) {
            val entry = eldest.next()
            cachedBytes -= entry.value.sumOf { it.jpeg.size.toLong() }
            eldest.remove()
        }
    }

    private fun drawAll(file: File, pageBudget: Int, byteBudget: Long): List<Page> {
        val descriptor = try {
            ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
        } catch (_: IOException) {
            throw Refused(INVALID, "A PDF attachment could not be opened")
        }
        descriptor.use {
            val renderer = try {
                PdfRenderer(descriptor)
            } catch (_: SecurityException) {
                throw Refused(UNSUPPORTED, "A password-protected PDF cannot be sent")
            } catch (_: IOException) {
                throw Refused(INVALID, "A PDF attachment cannot be read")
            } catch (_: RuntimeException) {
                throw Refused(INVALID, "A PDF attachment cannot be read")
            }
            return renderer.use { pages(renderer, pageBudget, byteBudget) }
        }
    }

    private fun pages(renderer: PdfRenderer, pageBudget: Int, byteBudget: Long): List<Page> {
        val count = renderer.pageCount
        if (count <= 0) throw Refused(INVALID, "A PDF attachment has no pages")
        if (count > MAX_PAGES) {
            throw Refused(TOO_LARGE, "A PDF attachment has more than $MAX_PAGES pages")
        }
        if (count > pageBudget) {
            throw Refused(TOO_LARGE, "The PDFs in this conversation have too many pages")
        }
        val drawn = ArrayList<Page>(count)
        var bytes = 0L
        for (index in 0 until count) {
            val page = try {
                renderer.openPage(index)
            } catch (_: RuntimeException) {
                throw Refused(INVALID, "A PDF page cannot be read")
            }
            page.use { drawn.add(Page(draw(page))) }
            // Checked as each page lands, so a document that would not fit
            // stops here rather than after every page is in memory.
            bytes += drawn.last().jpeg.size.toLong()
            if (bytes > byteBudget) {
                throw Refused(TOO_LARGE, "The pictures in this conversation are too large to send")
            }
        }
        return drawn
    }

    private fun draw(page: PdfRenderer.Page): ByteArray {
        // Page sizes are in points. The long edge is fixed so every page is
        // equally legible whatever its paper; the short edge follows.
        val width = page.width
        val height = page.height
        if (width <= 0 || height <= 0) throw Refused(INVALID, "A PDF page has no size")
        if (maxOf(width, height).toFloat() / minOf(width, height).toFloat() > MAX_ASPECT) {
            throw Refused(UNSUPPORTED, "A PDF page is too long or narrow to send legibly")
        }
        val scale = LONG_EDGE.toFloat() / maxOf(width, height).toFloat()
        val pixelsWide = maxOf(1, (width * scale).toInt())
        val pixelsHigh = maxOf(1, (height * scale).toInt())
        val bitmap = try {
            Bitmap.createBitmap(pixelsWide, pixelsHigh, Bitmap.Config.ARGB_8888)
        } catch (_: OutOfMemoryError) {
            throw Refused(TOO_LARGE, "A PDF page is too large to draw")
        }
        try {
            // The renderer draws onto transparency; JPEG has none, and a
            // transparent page would become black.
            bitmap.eraseColor(Color.WHITE)
            try {
                page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
            } catch (_: RuntimeException) {
                throw Refused(INVALID, "A PDF page cannot be drawn")
            }
            val stream = ByteArrayOutputStream()
            if (!bitmap.compress(Bitmap.CompressFormat.JPEG, QUALITY, stream)) {
                throw Refused(INVALID, "A PDF page cannot be encoded")
            }
            return stream.toByteArray()
        } finally {
            bitmap.recycle()
        }
    }

    const val INVALID = "E_COMPLETION_CONTEXT_INVALID"
    const val UNSUPPORTED = "E_COMPLETION_CONTEXT_UNSUPPORTED"
    const val TOO_LARGE = "E_COMPLETION_BODY_TOO_LARGE"
}
