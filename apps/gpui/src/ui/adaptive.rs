//! Window-based layout policy, independent of device names and screen geometry.
//! UIKit traits refine the current *window* bounds; they never identify hardware.
//! Reserved fold/camera regions require newer SDK APIs and are not fabricated here.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SizeClass {
    Unspecified,
    Compact,
    Regular,
}
impl SizeClass {
    pub fn from_raw(value: u8) -> Self {
        match value {
            1 => Self::Compact,
            2 => Self::Regular,
            _ => Self::Unspecified,
        }
    }
}
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Insets {
    pub top: f32,
    pub right: f32,
    pub bottom: f32,
    pub left: f32,
}
#[derive(Clone, Copy, Debug)]
pub struct Metrics {
    pub width: f32,
    pub height: f32,
    pub insets: Insets,
    pub horizontal: SizeClass,
    pub vertical: SizeClass,
    pub mobile: bool,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Navigation {
    Sidebar,
    Drawer,
}
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Layout {
    pub navigation: Navigation,
    pub sidebar_width: f32,
    pub drawer_width: f32,
    pub content_width: f32,
    pub available_height: f32,
    pub insets: Insets,
    /// Persistent mobile sidebars own new-chat/rename actions in wide/short windows.
    pub side_controls: bool,
    pub compact_content: bool,
}
const MIN_CHAT_WIDTH: f32 = 340.;
const MIN_SIDEBAR_WIDTH: f32 = 200.;
const MAX_SIDEBAR_WIDTH: f32 = 240.;
const FALLBACK_SIDEBAR_WIDTH: f32 = 760.;
const MIN_DRAWER_WIDTH: f32 = 240.;
const MAX_DRAWER_WIDTH: f32 = 320.;
const DRAWER_DISMISS_WIDTH: f32 = 48.;
fn nonnegative(value: f32) -> f32 {
    if value.is_finite() { value.max(0.) } else { 0. }
}
fn constrain_pair(first: f32, second: f32, extent: f32) -> (f32, f32) {
    let first = nonnegative(first);
    let second = nonnegative(second);
    let total = f64::from(first) + f64::from(second);
    let scale = if total > f64::from(extent) && total > 0. {
        (f64::from(extent) / total) as f32
    } else {
        1.
    };
    (first * scale, second * scale)
}
pub fn resolve(metrics: Metrics) -> Layout {
    let width = nonnegative(metrics.width);
    let height = nonnegative(metrics.height);
    let (left, right) = constrain_pair(metrics.insets.left, metrics.insets.right, width);
    let (top, bottom) = constrain_pair(metrics.insets.top, metrics.insets.bottom, height);
    let insets = Insets {
        top,
        right,
        bottom,
        left,
    };
    let available_width = (width - left - right).max(0.);
    let available_height = (height - top - bottom).max(0.);
    let side_controls = metrics.mobile
        && (metrics.vertical == SizeClass::Compact || available_width > available_height);
    let room_for_sidebar = available_width >= MIN_CHAT_WIDTH + MIN_SIDEBAR_WIDTH;
    let sidebar = room_for_sidebar
        && match metrics.horizontal {
            SizeClass::Regular => true,
            SizeClass::Compact => false,
            SizeClass::Unspecified => available_width >= FALLBACK_SIDEBAR_WIDTH,
        };
    let navigation = if sidebar {
        Navigation::Sidebar
    } else {
        Navigation::Drawer
    };
    let sidebar_width = if sidebar {
        (available_width * 0.30).clamp(MIN_SIDEBAR_WIDTH, MAX_SIDEBAR_WIDTH)
    } else {
        0.
    };
    // The overlay leaves an outside dismissal target even in very narrow windows.
    // Its content uses the same already-inset width as the main pane.
    let drawer_width = if sidebar {
        0.
    } else {
        (available_width * 0.84)
            .clamp(MIN_DRAWER_WIDTH, MAX_DRAWER_WIDTH)
            .min((available_width - DRAWER_DISMISS_WIDTH).max(0.))
    };
    let content_width = (available_width - sidebar_width).max(0.);
    Layout {
        navigation,
        sidebar_width,
        drawer_width,
        content_width,
        available_height,
        insets,
        side_controls,
        compact_content: available_height < 440. || content_width < 360.,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn window(width: f32, height: f32, horizontal: SizeClass, vertical: SizeClass) -> Metrics {
        Metrics {
            width,
            height,
            horizontal,
            vertical,
            mobile: true,
            insets: Insets::default(),
        }
    }
    #[test]
    fn regular_window_can_show_both_panes_below_the_old_desktop_breakpoint() {
        let layout = resolve(window(620., 820., SizeClass::Regular, SizeClass::Regular));
        assert_eq!(layout.navigation, Navigation::Sidebar);
        assert!(layout.content_width >= MIN_CHAT_WIDTH);
        assert!(!layout.side_controls);
    }
    #[test]
    fn compact_portrait_uses_a_drawer_without_shrinking_the_content_pane() {
        let layout = resolve(window(390., 780., SizeClass::Compact, SizeClass::Regular));
        assert_eq!(layout.navigation, Navigation::Drawer);
        assert_eq!(layout.content_width, 390.);
        assert!(!layout.side_controls);
    }
    #[test]
    fn sidebar_opens_only_when_both_minimum_widths_fit() {
        let before = resolve(window(539.9, 820., SizeClass::Regular, SizeClass::Regular));
        let at = resolve(window(540., 820., SizeClass::Regular, SizeClass::Regular));
        assert_eq!(before.navigation, Navigation::Drawer);
        assert_eq!(at.navigation, Navigation::Sidebar);
        assert_eq!(at.sidebar_width, 200.);
        assert_eq!(at.content_width, 340.);
        for width in 540..=1600 {
            let layout = resolve(window(
                width as f32,
                820.,
                SizeClass::Regular,
                SizeClass::Regular,
            ));
            assert!(layout.content_width >= MIN_CHAT_WIDTH);
            assert!((MIN_SIDEBAR_WIDTH..=MAX_SIDEBAR_WIDTH).contains(&layout.sidebar_width));
            assert!((layout.content_width + layout.sidebar_width - width as f32).abs() < 0.001);
        }
    }
    #[test]
    fn compact_trait_keeps_a_single_pane_even_when_the_window_is_wide() {
        let layout = resolve(window(820., 390., SizeClass::Compact, SizeClass::Compact));
        assert_eq!(layout.navigation, Navigation::Drawer);
        assert_eq!(layout.sidebar_width, 0.);
        assert!(layout.side_controls);
    }
    #[test]
    fn narrow_split_view_collapses_even_if_a_regular_trait_is_reported() {
        let layout = resolve(window(480., 850., SizeClass::Regular, SizeClass::Regular));
        assert_eq!(layout.navigation, Navigation::Drawer);
        assert!(!layout.side_controls);
    }
    #[test]
    fn asymmetrical_safe_areas_reduce_available_space_without_being_mirrored() {
        let mut metrics = window(620., 820., SizeClass::Regular, SizeClass::Regular);
        metrics.insets = Insets {
            top: 17.,
            right: 61.,
            bottom: 29.,
            left: 9.,
        };
        let layout = resolve(metrics);
        assert_eq!(layout.insets, metrics.insets);
        assert_eq!(layout.content_width, 350.);
        assert_eq!(layout.available_height, 774.);
        assert_eq!(layout.navigation, Navigation::Sidebar);
        metrics.width = 609.;
        let narrower = resolve(metrics);
        assert_eq!(narrower.navigation, Navigation::Drawer);
        assert_eq!(narrower.content_width, 539.);
        assert_eq!(narrower.insets, metrics.insets);
    }
    #[test]
    fn regular_landscape_uses_a_persistent_sidebar_without_a_drawer() {
        let layout = resolve(window(930., 630., SizeClass::Regular, SizeClass::Regular));
        assert_eq!(layout.navigation, Navigation::Sidebar);
        assert!(layout.side_controls);
        assert_eq!(layout.drawer_width, 0.);
    }
    #[test]
    fn vertical_compact_uses_a_drawer_from_window_traits() {
        let layout = resolve(window(380., 450., SizeClass::Compact, SizeClass::Compact));
        assert_eq!(layout.navigation, Navigation::Drawer);
        assert!(layout.side_controls);
    }
    #[test]
    fn repeated_fold_resize_decisions_are_reversible_and_preserve_content_budget() {
        let sizes = [
            (440., 380., SizeClass::Compact),
            (620., 820., SizeClass::Regular),
            (480., 820., SizeClass::Regular),
            (440., 380., SizeClass::Compact),
        ];
        let layouts: Vec<_> = sizes
            .into_iter()
            .map(|(w, h, c)| resolve(window(w, h, c, SizeClass::Regular)))
            .collect();
        assert_eq!(layouts[0], layouts[3]);
        assert_eq!(
            layouts.iter().map(|l| l.navigation).collect::<Vec<_>>(),
            vec![
                Navigation::Drawer,
                Navigation::Sidebar,
                Navigation::Drawer,
                Navigation::Drawer
            ]
        );
        assert!(layouts.iter().all(|l| l.content_width > 0.));
    }
    #[test]
    fn trait_changes_at_the_same_size_recompute_navigation() {
        let mut metrics = window(620., 820., SizeClass::Compact, SizeClass::Regular);
        let compact = resolve(metrics);
        metrics.horizontal = SizeClass::Regular;
        assert_eq!(resolve(metrics).navigation, Navigation::Sidebar);
        metrics.horizontal = SizeClass::Compact;
        assert_eq!(resolve(metrics), compact);
    }
    #[test]
    fn unspecified_desktop_traits_use_available_space_not_phone_assumptions() {
        let mut metrics = window(1100., 700., SizeClass::Unspecified, SizeClass::Unspecified);
        metrics.mobile = false;
        assert_eq!(resolve(metrics).navigation, Navigation::Sidebar);
        metrics.width = 700.;
        assert_eq!(resolve(metrics).navigation, Navigation::Drawer);
    }
    #[test]
    fn drawer_width_preserves_an_outside_dismiss_target_across_compact_windows() {
        for width in 48..=1200 {
            let layout = resolve(window(
                width as f32,
                600.,
                SizeClass::Compact,
                SizeClass::Regular,
            ));
            assert_eq!(layout.navigation, Navigation::Drawer);
            assert_eq!(layout.content_width, width as f32);
            assert!(layout.drawer_width <= MAX_DRAWER_WIDTH);
            assert!(layout.content_width - layout.drawer_width >= DRAWER_DISMISS_WIDTH);
            if width >= (MIN_DRAWER_WIDTH + DRAWER_DISMISS_WIDTH) as i32 {
                assert!(layout.drawer_width >= MIN_DRAWER_WIDTH);
            }
        }
    }
    #[test]
    fn drawer_budget_applies_asymmetrical_safe_areas_once() {
        let mut metrics = window(430., 700., SizeClass::Compact, SizeClass::Regular);
        metrics.insets = Insets {
            top: 59.,
            right: 31.,
            bottom: 34.,
            left: 17.,
        };
        let layout = resolve(metrics);
        assert_eq!(layout.navigation, Navigation::Drawer);
        assert_eq!(layout.content_width, 382.);
        assert_eq!(layout.available_height, 607.);
        assert_eq!(layout.insets, metrics.insets);
        assert!(layout.content_width - layout.drawer_width >= DRAWER_DISMISS_WIDTH);
        // The panel extends behind the left inset; it is not deducted from its content twice.
        let panel_extent = layout.drawer_width + layout.insets.left;
        assert!(metrics.width - panel_extent - layout.insets.right >= DRAWER_DISMISS_WIDTH);
    }
    #[test]
    fn invalid_or_transitional_metrics_never_create_negative_layout_sizes() {
        let mut metrics = window(f32::NAN, -10., SizeClass::Unspecified, SizeClass::Compact);
        metrics.insets = Insets {
            top: 10.,
            right: 20.,
            bottom: 30.,
            left: 40.,
        };
        let layout = resolve(metrics);
        assert_eq!(layout.content_width, 0.);
        assert_eq!(layout.available_height, 0.);
        assert_eq!(layout.drawer_width, 0.);
        assert_eq!(layout.insets, Insets::default());
    }
    #[test]
    fn oversized_safe_areas_use_the_window_budget_and_preserve_asymmetry() {
        let mut metrics = window(300., 600., SizeClass::Regular, SizeClass::Regular);
        metrics.insets = Insets {
            top: f32::INFINITY,
            right: 1000.,
            bottom: -20.,
            left: 500.,
        };
        let layout = resolve(metrics);
        assert_eq!(
            layout.insets,
            Insets {
                top: 0.,
                right: 200.,
                bottom: 0.,
                left: 100.
            }
        );
        assert_eq!(layout.content_width, 0.);
        metrics.insets.left = f32::MAX;
        metrics.insets.right = f32::MAX;
        let layout = resolve(metrics);
        assert!(layout.content_width < 0.001);
        assert!((layout.insets.left - 150.).abs() < 0.001);
        assert!((layout.insets.right - 150.).abs() < 0.001);
    }
}
