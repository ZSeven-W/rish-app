// Adapted from gpui-mobile c7cab3a43970bd5f1e05d907695404ed73fcdc95.
// Copyright Balamurali Pandranki. Apache-2.0; see GPUI-MOBILE-LICENSE.
package dev.gpui.mobile;

import android.app.NativeActivity;
import android.content.Intent;
import android.os.Bundle;
import tech.zseven.rish.gpui.RishGpuiBridge;

/** The package is part of gpui-mobile's JNI ABI. GPUI owns the only render surface. */
public final class GpuiActivity extends NativeActivity {
    static { System.loadLibrary("rish_gpui"); }

    /** Backend readiness belongs to the current renderer, not the process. */
    public static native boolean nativeIsInitialized();

    /** Records only this Activity's embedded editor window focus. */
    public static native void nativeSetEmbeddedInputFocus(boolean transferring, boolean focused);

    @Override protected void onCreate(Bundle state) {
        // Set the host before NativeActivity launches android_main on its thread.
        RishGpuiBridge.attach(this);
        super.onCreate(state);
    }

    @Override protected void onResume() {
        super.onResume();
        RishGpuiBridge.resume(this);
    }

    @Override protected void onPause() {
        RishGpuiBridge.pause(this);
        super.onPause();
    }

    @Override protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        RishGpuiBridge.openTask(this, intent);
    }

    @Override public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        RishGpuiBridge.permissionResult(this, requestCode);
    }

    @Override protected void onDestroy() {
        RishGpuiBridge.detach(this);
        super.onDestroy();
    }
}
