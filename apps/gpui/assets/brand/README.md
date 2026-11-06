# Rish assistant avatar

`rish-avatar-v2.png` is the transparent bitmap extracted with the built-in
image_gen tool from the approved UI concept. It is embedded through the same
asset source as the Lucide icons, with no runtime network or filesystem access.

The PNG is preserved unchanged at 1254 × 1254 pixels. `visuals::rish_mark` places
its visible circular content inside the requested native viewport while clipping
the transparent outer padding; it does not substitute a font glyph. The same
asset is used by phone, tablet, sidebar and settings.

- [Design concept](../../design/2026-10-28/local-assistant-v2.png)
- [Design prompt](../../design/2026-10-28/local-assistant-v2-prompt.md)
- [Extraction prompt](../../design/2026-10-28/rish-avatar-v2-prompt.md)
