//! Native Rish UI. All platform effects remain behind the existing host services.
pub mod assistant_runtime;
pub mod icons;
#[cfg(target_os = "ios")]
mod ios_platform;
pub mod providers;
pub mod runtime;
pub mod ui;

#[cfg(target_os = "ios")]
unsafe extern "C" {
    fn rish_gpui_layout_metrics(values: *mut f32, count: usize) -> bool;
}

#[cfg(target_os = "ios")]
fn ios_layout_metrics() -> Option<[f32; 8]> {
    let mut values = [0.; 8];
    // GPUI invokes this on UIKit's main thread. The host writes exactly eight
    // floats and reports unavailable until a real application window exists.
    unsafe { rish_gpui_layout_metrics(values.as_mut_ptr(), values.len()) }.then_some(values)
}

/// UIKit size classes for the current window, never inferred from a device name.
/// 0 = unspecified, 1 = compact, 2 = regular.
pub fn window_size_classes() -> (u8, u8) {
    #[cfg(target_os = "ios")]
    {
        ios_layout_metrics()
            .map(|m| (m[6] as u8, m[7] as u8))
            .unwrap_or_default()
    }
    #[cfg(not(target_os = "ios"))]
    {
        (0, 0)
    }
}

/// Logical GPUI pixels in top/right/bottom/left order, including cutouts.
pub fn safe_area_insets() -> (f32, f32, f32, f32) {
    #[cfg(target_os = "ios")]
    {
        ios_layout_metrics()
            .map(|m| (m[2], m[3], m[4], m[5]))
            .unwrap_or_default()
    }
    #[cfg(target_os = "android")]
    {
        gpui_mobile::android::jni::platform()
            .and_then(|platform| platform.primary_window())
            .map(|window| {
                let insets = window.safe_area_insets_logical();
                (insets.top, insets.right, insets.bottom, insets.left)
            })
            .unwrap_or_default()
    }
    #[cfg(not(any(target_os = "ios", target_os = "android")))]
    {
        (0.0, 0.0, 0.0, 0.0)
    }
}

#[cfg(target_os = "ios")]
#[unsafe(no_mangle)]
pub extern "C" fn rish_gpui_run() {
    ios_platform::run();
}

#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
pub fn android_main(app: android_activity::AndroidApp) {
    android_logger::init_once(
        android_logger::Config::default()
            .with_max_level(log::LevelFilter::Info)
            .with_tag("rish-gpui"),
    );
    gpui_mobile::android::jni::install_panic_hook();
    gpui_mobile::android::jni::init_platform(&app);
    if let Some(platform) = gpui_mobile::android::jni::shared_platform() {
        gpui::Application::with_platform(platform.into_rc())
            .with_assets(icons::Assets)
            .run(ui::open);
    } else {
        log::error!("Android native surface platform was not initialized");
    }
}
