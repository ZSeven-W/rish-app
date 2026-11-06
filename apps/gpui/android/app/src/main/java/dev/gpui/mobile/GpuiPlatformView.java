package dev.gpui.mobile;

/**
 * gpui-mobile calls these lifecycle hooks even with embedded views disabled.
 * Rish draws its app in GPUI and uses ordinary Activity dialogs for IME and
 * credentials, so there are no embedded platform views to pause or dispose.
 */
public final class GpuiPlatformView {
    private GpuiPlatformView() {}

    public static void pauseAll() {}
    public static void resumeAll() {}
    public static void disposeAll() {}
}
