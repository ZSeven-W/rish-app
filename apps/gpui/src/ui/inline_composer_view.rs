//! GPUI placeholder used only after native attachment is known to be absent.
use super::*;
use gpui::{canvas, div, prelude::*, px};

pub(super) fn element(shell: &Shell, max_height: f32, cx: &mut Context<Shell>) -> impl IntoElement {
    let weak = cx.weak_entity();
    let limit = if max_height.is_finite() {
        max_height.clamp(44., 168.)
    } else {
        80.
    };
    let p = crate::ui::Palette::get(cx);
    let fallback = shell.inline_composer.fallback_visible();
    let text = shell.composer.read(cx).text();
    div()
        .id("native-composer")
        .debug_selector(|| "native-composer".into())
        .h(px(shell.inline_composer.state.content_height().min(limit)))
        .min_h(px(80_f32.min(limit)))
        .max_h(px(limit))
        .w_full()
        .flex_shrink_0()
        .px_4()
        .child(
            canvas(
                |_, _, _| (),
                move |bounds, _, _, cx| {
                    let rect = [
                        f32::from(bounds.origin.x),
                        f32::from(bounds.origin.y),
                        f32::from(bounds.size.width),
                        f32::from(bounds.size.height),
                    ];
                    cx.defer(move |cx| {
                        let _ = weak.update(cx, |this, cx| {
                            if this.inline_composer.rect != rect {
                                this.inline_composer.rect = rect;
                                this.update_inline_composer(cx);
                            }
                        });
                    });
                },
            )
            .w_full()
            .h_full(),
        )
        .when(fallback, |s| {
            s.child(
                div()
                    .absolute()
                    .inset_0()
                    .px_4()
                    .py_2()
                    .overflow_hidden()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .text_size(px(15.))
                    .line_height(px(23.))
                    .text_color(if text.is_empty() { p.muted } else { p.text })
                    .child(
                        div()
                            .flex_1()
                            .min_h(px(0.))
                            .overflow_hidden()
                            .whitespace_normal()
                            .child(if text.is_empty() {
                                shell.composer_placeholder().to_owned()
                            } else {
                                text
                            }),
                    )
                    .child(
                        div()
                            .text_size(px(11.))
                            .text_color(p.muted)
                            .child(shell.locale.text(Text::InlineRetry)),
                    ),
            )
        })
        .cursor_pointer()
        .on_click(cx.listener(|this, _, _, cx| {
            this.inline_composer.focus = Some(true);
            this.inline_composer.failed_key = None;
            this.defer_inline_update(cx);
            cx.notify();
        }))
}
