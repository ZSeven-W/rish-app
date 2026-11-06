gpui::actions!(rish_desktop, [Quit]);

fn main() {
    gpui_platform::application()
        .with_assets(rish_gpui::icons::Assets)
        .run(|cx| {
            cx.on_action(|_: &Quit, cx| cx.quit());
            cx.bind_keys([gpui::KeyBinding::new("cmd-q", Quit, None)]);
            rish_gpui::ui::open(cx);
        });
}
