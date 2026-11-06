//! Keep GPUI's application owner alive for the complete UIKit event loop.
//!
//! The pinned mobile backend registers the launch callback and returns from
//! `Platform::run`. GPUI's `Application::run` owns the application until that
//! method returns, so invoking the callback later would drop the last owner
//! while UIKit still holds pointers to its windows. Entering UIApplicationMain
//! here gives the mobile platform the same blocking lifetime as desktop GPUI.

use futures::channel::oneshot;
use gpui::{
    Action, ActivityGuard, AnyWindowHandle, Application, BackgroundExecutor, ClipboardItem,
    CursorStyle, ForegroundExecutor, Keymap, Menu, MenuItem, PathPromptOptions, Platform,
    PlatformDisplay, PlatformKeyboardLayout, PlatformKeyboardMapper, PlatformTextSystem,
    PlatformWindow, Result, Task, ThermalState, WindowAppearance, WindowParams,
};
use gpui_mobile::ios::IosPlatform;
use std::{
    ffi::c_int,
    path::{Path, PathBuf},
    rc::Rc,
    sync::Arc,
};

unsafe extern "C" {
    fn rish_gpui_enter_ui_application() -> c_int;
}

/// Start GPUI on the main thread after the native host initializes its FFI state.
pub fn run() {
    static LOGGER: PlatformLogger = PlatformLogger;
    let _ = log::set_logger(&LOGGER);
    log::set_max_level(log::LevelFilter::Info);
    Application::with_platform(Rc::new(HostingPlatform(IosPlatform::new())))
        .with_assets(crate::icons::Assets)
        .run(crate::ui::open);
}

struct PlatformLogger;
impl log::Log for PlatformLogger {
    fn enabled(&self, metadata: &log::Metadata<'_>) -> bool {
        metadata.level() <= log::Level::Info
            && (metadata.target().starts_with("gpui") || metadata.target().starts_with("rish_gpui"))
    }
    fn log(&self, record: &log::Record<'_>) {
        if self.enabled(record.metadata()) {
            eprintln!(
                "[{}] {}: {}",
                record.level(),
                record.target(),
                record.args()
            );
        }
    }
    fn flush(&self) {}
}

struct HostingPlatform(IosPlatform);

macro_rules! forward_to_ios {
    ($(fn $method:ident(&self $(, $argument:ident: $argument_type:ty)* $(,)?) $(-> $result:ty)?;)*) => {
        $(
            fn $method(&self $(, $argument: $argument_type)*) $(-> $result)? {
                self.0.$method($($argument),*)
            }
        )*
    };
}

impl Platform for HostingPlatform {
    fn run(&self, on_finish_launching: Box<dyn 'static + FnOnce()>) {
        self.0.run(on_finish_launching);

        // SAFETY: The native main entry point initializes gpui-mobile before
        // calling this function on the main thread. The host enters UIKit once;
        // its delegate invokes the callback registered above during launch.
        // This call remains on the stack while UIKit can access GPUI windows.
        unsafe { rish_gpui_enter_ui_application() };
    }

    // The pinned iOS backend uses Platform's defaults for optional methods.
    // Preserve those defaults and delegate all required iOS methods unchanged.
    forward_to_ios! {
        fn background_executor(&self) -> BackgroundExecutor;
        fn foreground_executor(&self) -> ForegroundExecutor;
        fn text_system(&self) -> Arc<dyn PlatformTextSystem>;
        fn quit(&self);
        fn restart(&self, binary_path: Option<PathBuf>, arguments: Vec<std::ffi::OsString>);
        fn activate(&self, ignoring_other_apps: bool);
        fn hide(&self);
        fn hide_other_apps(&self);
        fn unhide_other_apps(&self);
        fn displays(&self) -> Vec<Rc<dyn PlatformDisplay>>;
        fn primary_display(&self) -> Option<Rc<dyn PlatformDisplay>>;
        fn active_window(&self) -> Option<AnyWindowHandle>;
        fn open_window(
            &self,
            handle: AnyWindowHandle,
            options: WindowParams,
        ) -> Result<Box<dyn PlatformWindow>>;
        fn window_appearance(&self) -> WindowAppearance;
        fn open_url(&self, url: &str);
        fn on_open_urls(&self, callback: Box<dyn FnMut(Vec<String>)>);
        fn register_url_scheme(&self, url: &str) -> Task<Result<()>>;
        fn prompt_for_paths(
            &self,
            options: PathPromptOptions,
        ) -> oneshot::Receiver<Result<Option<Vec<PathBuf>>>>;
        fn prompt_for_new_path(
            &self,
            directory: &Path,
            suggested_name: Option<&str>,
        ) -> oneshot::Receiver<Result<Option<PathBuf>>>;
        fn can_select_mixed_files_and_dirs(&self) -> bool;
        fn reveal_path(&self, path: &Path);
        fn open_with_system(&self, path: &Path);
        fn on_quit(&self, callback: Box<dyn FnMut() -> bool>);
        fn on_system_wake(&self, callback: Box<dyn FnMut()>);
        fn on_system_sleep(&self, callback: Box<dyn FnMut()>);
        fn on_reopen(&self, callback: Box<dyn FnMut()>);
        fn set_menus(&self, menus: Vec<Menu>, keymap: &Keymap);
        fn set_dock_menu(&self, menu: Vec<MenuItem>, keymap: &Keymap);
        fn on_app_menu_action(&self, callback: Box<dyn FnMut(&dyn Action)>);
        fn on_will_open_app_menu(&self, callback: Box<dyn FnMut()>);
        fn on_validate_app_menu_command(&self, callback: Box<dyn FnMut(&dyn Action) -> bool>);
        fn thermal_state(&self) -> ThermalState;
        fn on_thermal_state_change(&self, callback: Box<dyn FnMut()>);
        fn prevent_idle_sleep(&self, reason: &str) -> Task<Result<ActivityGuard>>;
        fn app_path(&self) -> Result<PathBuf>;
        fn path_for_auxiliary_executable(&self, name: &str) -> Result<PathBuf>;
        fn set_cursor_style(&self, style: CursorStyle);
        fn hide_cursor_until_mouse_moves(&self);
        fn is_cursor_visible(&self) -> bool;
        fn should_auto_hide_scrollbars(&self) -> bool;
        fn read_from_clipboard(&self) -> Option<ClipboardItem>;
        fn write_to_clipboard(&self, item: ClipboardItem);
        fn write_credentials(&self, url: &str, username: &str, password: &[u8]) -> Task<Result<()>>;
        fn read_credentials(&self, url: &str) -> Task<Result<Option<(String, Vec<u8>)>>>;
        fn delete_credentials(&self, url: &str) -> Task<Result<()>>;
        fn keyboard_layout(&self) -> Box<dyn PlatformKeyboardLayout>;
        fn keyboard_mapper(&self) -> Rc<dyn PlatformKeyboardMapper>;
        fn on_keyboard_layout_change(&self, callback: Box<dyn FnMut()>);
    }
}
