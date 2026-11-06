//! Native visual primitives shared by the phone and tablet surfaces.
use super::theme::Palette;
use gpui::{App, Div, div, img, prelude::*, px};

/// The approved imagegen mark, embedded once and shared by all surfaces.
pub(super) fn rish_mark(size: f32, _cx: &App) -> Div {
    rish_mark_image(size)
}

pub(super) fn rish_mark_image(size: f32) -> Div {
    div()
        .size(px(size))
        .flex_shrink_0()
        .relative()
        .rounded_full()
        .overflow_hidden()
        // The source stays untouched. Its transparent padding is outside the
        // native avatar viewport, so the visible disc occupies the given size.
        .child(
            img("brand/rish-avatar-v2.png")
                .absolute()
                .left(px(-size * 101. / 1050.))
                .top(px(-size * 103. / 1050.))
                .size(px(size * 1254. / 1050.)),
        )
}

pub(super) fn round_button(cx: &App) -> Div {
    let p = Palette::get(cx);
    div()
        .size(px(44.))
        .flex_shrink_0()
        .rounded_full()
        .bg(p.composer)
        .text_color(p.text)
        .shadow_sm()
        .flex()
        .items_center()
        .justify_center()
}
