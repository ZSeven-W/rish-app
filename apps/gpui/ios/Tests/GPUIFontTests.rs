use gpui::Platform;

// Compile the same helper used by workspace previews and transcript code.
// The remainder of this module is typechecked but never invokes UIKit chrome.
#[allow(dead_code)]
#[path = "../../src/ui/theme.rs"]
mod theme;

fn main() {
    // Construct only the platform's text service. Do not run the application,
    // open a window, activate a responder, or send input events.
    let platform = gpui_mobile::ios::IosPlatform::new();
    let system = platform.text_system();
    let family = theme::code_font_family();
    let fonts = [
        gpui::font(family),
        gpui::font(family).bold(),
        gpui::font(family).italic(),
    ];
    let mut checked_lines = 0;
    for font in fonts {
        let id = system.font_id(&font).unwrap_or_else(|error| {
            panic!(
                "Code font {family:?} {:?} {:?} failed: {error}",
                font.weight, font.style
            )
        });
        let advance = |character| {
            let glyph = system
                .glyph_for_char(id, character)
                .expect("ASCII glyph must exist");
            system
                .advance(id, glyph)
                .expect("ASCII glyph must have metrics")
                .width
        };
        assert!(advance('m') > 0.0, "Code font must have usable metrics");
        assert_eq!(
            advance('m'),
            advance('i'),
            "Code font must remain monospaced"
        );
        for text in [
            "中文 GPUI 编辑验证 notes.md 🚀",
            "  let value = 1; // 保留缩进",
            "👩‍💻 Cafe\u{301}",
        ] {
            let line = system.layout_line(
                text,
                gpui::px(14.),
                &[gpui::FontRun {
                    len: text.len(),
                    font_id: id,
                }],
            );
            assert_eq!(line.len, text.len(), "Shaping must preserve UTF-8 length");
            assert!(
                line.width > gpui::px(0.),
                "Mixed text must have positive width"
            );
            assert!(
                line.runs.iter().any(|run| !run.glyphs.is_empty()),
                "Mixed text must produce glyphs"
            );
            checked_lines += 1;
        }
    }
    println!(
        "PASS: actual GPUI code font {family:?}, regular/bold/italic, equal ASCII advances and {checked_lines} mixed Unicode lines"
    );
}
