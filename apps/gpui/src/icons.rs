//! Embedded Lucide 1.34.0 icons shared by the desktop and mobile shells.
//! Source revision, license and checksums live in `assets/icons/lucide`.

use gpui::{AssetSource, Hsla, SharedString, Svg, prelude::*, px, svg};
use std::borrow::Cow;

macro_rules! lucide_icons {
    ($($variant:ident => $name:literal),+ $(,)?) => {
        #[derive(Clone, Copy)]
        pub enum Icon {
            $($variant),+
        }

        impl Icon {
            pub fn path(self) -> &'static str {
                match self {
                    $(Self::$variant => concat!("icons/lucide/", $name, ".svg")),+
                }
            }
        }

        const ASSETS: &[(&str, &[u8])] = &[
            $(
                (
                    concat!("icons/lucide/", $name, ".svg"),
                    include_bytes!(concat!("../assets/icons/lucide/", $name, ".svg")),
                ),
            )+
        ];
    };
}

lucide_icons! {
    ArrowDown => "arrow-down",
    ArrowUp => "arrow-up",
    Bell => "bell",
    Box => "box",
    Check => "check",
    CheckCheck => "check-check",
    ChevronDown => "chevron-down",
    ChevronLeft => "chevron-left",
    ChevronRight => "chevron-right",
    ChevronsUpDown => "chevrons-up-down",
    Clock => "clock",
    CodeXml => "code-xml",
    Copy => "copy",
    Ellipsis => "ellipsis",
    File => "file",
    Folder => "folder",
    FolderPlus => "folder-plus",
    GitBranch => "git-branch",
    Globe => "globe",
    ListChecks => "list-checks",
    MessageSquare => "message-square",
    MessagesSquare => "messages-square",
    Monitor => "monitor",
    Moon => "moon",
    PanelLeft => "panel-left",
    PanelRight => "panel-right",
    Play => "play",
    Plus => "plus",
    RefreshCw => "refresh-cw",
    RotateCcw => "rotate-ccw",
    Search => "search",
    Settings2 => "settings-2",
    Square => "square",
    SquarePen => "square-pen",
    Sun => "sun",
    Trash2 => "trash-2",
    X => "x",
}

/// A static asset source, with no runtime filesystem or network dependency.
pub struct Assets;

const RISH_AVATAR: &str = "brand/rish-avatar-v2.png";
const RISH_AVATAR_BYTES: &[u8] = include_bytes!("../assets/brand/rish-avatar-v2.png");

impl AssetSource for Assets {
    fn load(&self, path: &str) -> gpui::Result<Option<Cow<'static, [u8]>>> {
        if path == RISH_AVATAR {
            return Ok(Some(Cow::Borrowed(RISH_AVATAR_BYTES)));
        }
        Ok(ASSETS
            .iter()
            .chain(crate::providers::ASSETS.iter())
            .find(|(name, _)| *name == path)
            .map(|(_, bytes)| Cow::Borrowed(*bytes)))
    }

    fn list(&self, path: &str) -> gpui::Result<Vec<SharedString>> {
        let mut paths: Vec<SharedString> = ASSETS
            .iter()
            .chain(crate::providers::ASSETS.iter())
            .filter(|(name, _)| name.starts_with(path))
            .map(|(name, _)| SharedString::from(*name))
            .collect();
        if RISH_AVATAR.starts_with(path) {
            paths.push(RISH_AVATAR.into());
        }
        Ok(paths)
    }
}

/// Sets color explicitly because GPUI SVG paint does not inherit a Div's text color.
/// Touch size belongs to the interactive container, independently of icon size.
pub fn icon(name: Icon, size: f32, color: Hsla) -> Svg {
    svg()
        .path(name.path())
        .size(px(size))
        .text_color(color)
        .flex_shrink_0()
}
