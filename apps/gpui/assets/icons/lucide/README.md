# Lucide icons

These SVGs are unmodified assets from [Lucide 1.34.0](https://github.com/lucide-icons/lucide/tree/1a60fd28ed7111bbf6acedc0896f3d83cd73945a/icons), pinned to commit `1a60fd28ed7111bbf6acedc0896f3d83cd73945a`.

- Upstream: https://github.com/lucide-icons/lucide
- Source: `icons/<name>.svg` at the pinned commit
- License: ISC, with MIT terms for icons derived from Feather; the full upstream notices are in [LICENSE](LICENSE).
- Integrity: [SHA256SUMS](SHA256SUMS) records each vendored SVG.
- Rendering: 24 by 24 view boxes, stroke width 2, round joins and caps. Each call passes its theme color explicitly to GPUI's SVG renderer; SVG elements do not inherit parent text color. Interactive containers provide their own touch targets; icon size does not define the hit area.

`src/icons.rs` embeds these assets for desktop, iOS and Android. No font, network fetch or runtime asset directory is required.
