use gpui::{App, Global, Hsla, WindowAppearance, rgb};

#[derive(Clone, Copy, PartialEq)]
pub enum ThemeMode {
    Light,
    Dark,
    System,
}
impl ThemeMode {
    pub fn code(self) -> &'static str {
        match self {
            Self::Light => "light",
            Self::Dark => "dark",
            Self::System => "system",
        }
    }
    pub fn from_code(code: &str) -> Self {
        match code {
            "dark" => Self::Dark,
            "system" => Self::System,
            _ => Self::Light,
        }
    }
}
#[derive(Clone, Copy)]
pub struct ThemeState {
    pub mode: ThemeMode,
    pub system_dark: bool,
}
impl Global for ThemeState {}
impl Default for ThemeState {
    fn default() -> Self {
        Self {
            mode: ThemeMode::Light,
            system_dark: false,
        }
    }
}
pub fn set_mode(mode: ThemeMode, cx: &mut App) {
    let old = cx.try_global::<ThemeState>().copied().unwrap_or_default();
    if old.mode != mode || cx.try_global::<ThemeState>().is_none() {
        sync_chrome(ThemeState { mode, ..old });
        cx.set_global(ThemeState { mode, ..old });
    }
}
pub fn sync_system(appearance: WindowAppearance, cx: &mut App) {
    let dark = matches!(
        appearance,
        WindowAppearance::Dark | WindowAppearance::VibrantDark
    );
    let old = cx.try_global::<ThemeState>().copied().unwrap_or_default();
    if old.system_dark != dark {
        sync_chrome(ThemeState {
            system_dark: dark,
            ..old
        });
        cx.set_global(ThemeState {
            system_dark: dark,
            ..old
        });
    }
}

fn sync_chrome(theme: ThemeState) {
    #[cfg(any(target_os = "ios", target_os = "android"))]
    {
        let dark =
            theme.mode == ThemeMode::Dark || (theme.mode == ThemeMode::System && theme.system_dark);
        gpui_mobile::set_system_chrome(&gpui_mobile::SystemChromeStyle {
            status_bar_color: None,
            status_bar_style: if dark {
                gpui_mobile::StatusBarContentStyle::Light
            } else {
                gpui_mobile::StatusBarContentStyle::Dark
            },
            navigation_bar_color: None,
        });
    }
    #[cfg(not(any(target_os = "ios", target_os = "android")))]
    let _ = theme;
}
#[derive(Clone, Copy)]
pub struct Palette {
    pub background: Hsla,
    pub surface: Hsla,
    pub raised: Hsla,
    pub composer: Hsla,
    pub line: Hsla,
    pub text: Hsla,
    pub muted: Hsla,
    pub faint: Hsla,
    pub accent: Hsla,
    pub accent_soft: Hsla,
    pub on_accent: Hsla,
    pub info: Hsla,
    pub danger: Hsla,
    pub success: Hsla,
    pub success_soft: Hsla,
}
impl Palette {
    pub fn get(cx: &App) -> Self {
        let theme = cx.try_global::<ThemeState>().copied().unwrap_or_default();
        if theme.mode == ThemeMode::Dark || (theme.mode == ThemeMode::System && theme.system_dark) {
            Self::dark()
        } else {
            Self::light()
        }
    }
    fn light() -> Self {
        Self {
            background: rgb(0xF7F7F8).into(),
            surface: rgb(0xEEEEF0).into(),
            raised: rgb(0xE4E4E8).into(),
            composer: rgb(0xFFFFFF).into(),
            line: rgb(0xE7E7EA).into(),
            text: rgb(0x19191B).into(),
            muted: rgb(0x727279).into(),
            faint: rgb(0xA0A0A7).into(),
            accent: rgb(0x1C1C1E).into(),
            accent_soft: rgb(0xE8E8EC).into(),
            on_accent: rgb(0xFFFFFF).into(),
            info: rgb(0x2E7DF6).into(),
            danger: rgb(0xBB413C).into(),
            success: rgb(0x367A52).into(),
            success_soft: rgb(0xE9F3ED).into(),
        }
    }
    fn dark() -> Self {
        Self {
            background: rgb(0x121214).into(),
            surface: rgb(0x1C1C1F).into(),
            raised: rgb(0x2B2B2F).into(),
            composer: rgb(0x202023).into(),
            line: rgb(0x36363C).into(),
            text: rgb(0xF2F2F4).into(),
            muted: rgb(0xA4A4AD).into(),
            faint: rgb(0x73737C).into(),
            accent: rgb(0xF4F4F5).into(),
            accent_soft: rgb(0x34343A).into(),
            on_accent: rgb(0x171719).into(),
            info: rgb(0x75A8FF).into(),
            danger: rgb(0xFF9990).into(),
            success: rgb(0x92D1A7).into(),
            success_soft: rgb(0x23392B).into(),
        }
    }
}
pub const HIT_TARGET: f32 = if cfg!(target_os = "android") {
    48.
} else if cfg!(target_os = "ios") {
    44.
} else {
    40.
};

/// GPUI Mobile's CoreText matcher expects a real font family on iOS.
pub fn code_font_family() -> &'static str {
    if cfg!(target_os = "ios") {
        ".AppleSystemUIFontMonospaced"
    } else {
        "monospace"
    }
}
