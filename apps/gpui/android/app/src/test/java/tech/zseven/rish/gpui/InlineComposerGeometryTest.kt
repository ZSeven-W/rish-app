package tech.zseven.rish.gpui

import org.junit.Assert.*
import org.junit.Test

class InlineComposerGeometryTest {
    @Test fun logicalFrameUsesActualSurfaceOriginAndScaleWithoutAddingSafeInsets() {
        val frame = InlineComposerGeometry.frame(listOf(20.0, 300.0, 280.0, 90.0), 2.0,
            surfaceX = 12.0, surfaceY = 48.0, surfaceWidth = 700.0, surfaceHeight = 1200.0,
            parentX = 0.0, parentY = 24.0)
        assertEquals(InlineComposerFrame(52, 624, 560, 180), frame)
    }

    @Test fun partiallyOffscreenOrResizingRectsDoNotCaptureTouchesBeyondSurface() {
        assertEquals(InlineComposerFrame(10, 20, 160, 80), InlineComposerGeometry.frame(
            listOf(-20.0, -10.0, 100.0, 50.0), 2.0, 10.0, 20.0, 500.0, 800.0, 0.0, 0.0))
        assertEquals(InlineComposerFrame(40, 600, 400, 0), InlineComposerGeometry.frame(
            listOf(20.0, 400.0, 200.0, 80.0), 2.0, 0.0, 0.0, 500.0, 600.0, 0.0, 0.0))
    }

    @Test fun alreadyResizedSurfaceDoesNotAvoidTheKeyboardTwice() {
        assertEquals(0.0, InlineComposerGeometry.keyboardBottom(650.0, 650.0, 325.0, 2.0, true), 0.0)
        assertEquals(0.0, InlineComposerGeometry.keyboardBottom(620.0, 650.0, 310.0, 2.0, true), 0.0)
        assertEquals(175.0, InlineComposerGeometry.keyboardBottom(1000.0, 650.0, 500.0, 2.0, true), 0.0)
    }

    @Test fun floatingKeyboardOrUnfocusedEditorDoesNotReserveScreenHeight() {
        assertEquals(0.0, InlineComposerGeometry.keyboardBottom(1000.0, 1000.0, 500.0, 2.0, true), 0.0)
        assertEquals(0.0, InlineComposerGeometry.keyboardBottom(1000.0, 650.0, 500.0, 2.0, false), 0.0)
        assertEquals(80.0, InlineComposerGeometry.keyboardBottom(1000.0, 0.0, 80.0, 2.0, true), 0.0)
    }
}
