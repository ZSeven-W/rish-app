package tech.zseven.rish.gpui

import org.junit.Assert.*
import org.junit.Test

class InlineComposerInputTest {
    @Test fun rejectingOversizedPasteOverSelectionPreservesTheOriginalText() {
        val before = "保留这段原文"
        val selected = InlineComposerInput.replacement("你".repeat(350_000), 0, 350_000, before, 2, 4)
        assertEquals("这段", selected.toString())
        assertEquals(before, before.substring(0, 2) + selected + before.substring(4))
    }

    @Test fun rejectingInputRetainsMarkedRangeMetadataInsteadOfConvertingToString() {
        val marked = MarkedText("候选词", "ime-marker")
        val rejected = InlineComposerInput.replacement("x".repeat(1_048_577), 0, 1_048_577, marked, 0, marked.length)
        assertTrue(rejected is MarkedText)
        assertEquals("ime-marker", (rejected as MarkedText).marker)
        assertEquals("候选词", rejected.toString())
    }

    @Test fun acceptedReplacementReturnsNullSoNativeInputKeepsItsOriginalSpans() {
        assertNull(InlineComposerInput.replacement("你好\n新行", 0, 5, "原文", 0, 2))
    }

    @Test fun malformedSurrogateReplacementDoesNotDeleteSelection() {
        assertEquals("甲", InlineComposerInput.replacement("\uD800", 0, 1, "甲乙", 0, 1).toString())
    }

    private class MarkedText(private val text: String, val marker: String) : CharSequence {
        override val length get() = text.length
        override fun get(index: Int) = text[index]
        override fun subSequence(startIndex: Int, endIndex: Int): CharSequence = MarkedText(text.substring(startIndex, endIndex), marker)
        override fun toString() = text
    }
}
