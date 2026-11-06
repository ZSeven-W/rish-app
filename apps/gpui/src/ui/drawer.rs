use super::adaptive::Layout;
use super::*;
use crate::icons::{Icon, icon};

impl Shell {
    fn open_drawer(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.drawer_open {
            return;
        }
        self.drawer_previous_focus = window.focused(cx);
        self.drawer_open = true;
        window.focus(&self.drawer_focus, cx);
        cx.notify();
    }

    pub(super) fn close_drawer(
        &mut self,
        restore_focus: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.drawer_open {
            return;
        }
        self.drawer_open = false;
        let previous = self.drawer_previous_focus.take();
        if let Some(previous) = previous.filter(|_| restore_focus) {
            window.focus(&previous, cx);
        } else {
            window.blur(cx);
        }
        cx.notify();
    }

    pub(super) fn drawer_open_button(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let p = Palette::get(cx);
        visuals::round_button(cx)
            .id("open-navigation")
            .debug_selector(|| "drawer-open".into())
            .role(gpui::Role::Button)
            .aria_label(self.locale.text(Text::OpenMenu))
            .cursor_pointer()
            .hover(|s| s.bg(p.surface))
            .flex()
            .items_center()
            .justify_center()
            .child(icon(Icon::PanelLeft, 22., p.text))
            .on_click(cx.listener(|this, _, window, cx| this.open_drawer(window, cx)))
    }

    pub(super) fn drawer(&self, layout: Layout, cx: &mut Context<Self>) -> impl IntoElement {
        let p = Palette::get(cx);
        div()
            .id("navigation-overlay")
            .absolute()
            .top_0()
            .left_0()
            .size_full()
            .occlude()
            .child(
                div()
                    .id("navigation-scrim")
                    .debug_selector(|| "drawer-scrim".into())
                    .absolute()
                    .top_0()
                    .left_0()
                    .size_full()
                    .bg(gpui::black().opacity(0.28))
                    .occlude()
                    .on_click(cx.listener(|this, _, window, cx| {
                        this.close_drawer(true, window, cx);
                        cx.stop_propagation();
                    })),
            )
            .child(
                div()
                    .id("navigation-drawer")
                    .debug_selector(|| "drawer-panel".into())
                    .relative()
                    .w(px(layout.drawer_width + layout.insets.left))
                    .h_full()
                    .overflow_hidden()
                    .pt(px(layout.insets.top))
                    .pb(px(layout.insets.bottom))
                    .pl(px(layout.insets.left))
                    .bg(p.surface)
                    .border_r_1()
                    .border_color(p.line)
                    .occlude()
                    .track_focus(&self.drawer_focus)
                    .capture_key_down(cx.listener(
                        |this, event: &gpui::KeyDownEvent, window, cx| {
                            if event.keystroke.key == "escape" {
                                this.close_drawer(true, window, cx);
                                window.prevent_default();
                                cx.stop_propagation();
                            }
                        },
                    ))
                    .child(self.sidebar(layout.drawer_width, false, true, cx)),
            )
    }
}
