//! Runtime product artwork and independent API account identities.
//! Product logos belong to execution engines, never model or API account rows.
use gpui::{AnyElement, div, img, prelude::*, px, rgb, svg};

/// The embedded Pi engine is not an optional download or subscription product.
pub fn pi_logo(size: f32, dark: bool) -> AnyElement {
    div()
        .debug_selector(|| "provider-logo-pi".into())
        .size(px(size))
        .flex_shrink_0()
        .child(
            svg()
                .path("providers/pi.svg")
                .size(px(size))
                // Match the original badge's light/dark CSS colors explicitly;
                // GPUI's SVG mask renderer does not evaluate media queries.
                .text_color(rgb(if dark { 0xf6f6f6 } else { 0x111111 })),
        )
        .into_any_element()
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RuntimeProduct {
    Dsh,
    ClaudeCode,
    Codex,
    Zcode,
}

impl RuntimeProduct {
    pub const ALL: [Self; 4] = [Self::Dsh, Self::ClaudeCode, Self::Codex, Self::Zcode];

    pub fn label(self) -> &'static str {
        match self {
            Self::Dsh => "DSH",
            Self::ClaudeCode => "Claude Code",
            Self::Codex => "Codex",
            Self::Zcode => "zcode",
        }
    }

    pub fn asset_path(self, dark: bool) -> &'static str {
        match self {
            Self::Dsh => "providers/dsh.svg",
            Self::ClaudeCode => "providers/claude-code.png",
            Self::Codex if dark => "providers/codex-dark.png",
            Self::Codex => "providers/codex-light.png",
            Self::Zcode => "providers/zcode.png",
        }
    }

    pub fn selector(self) -> &'static str {
        match self {
            Self::Dsh => "provider-logo-dsh",
            Self::ClaudeCode => "provider-logo-claude-code",
            Self::Codex => "provider-logo-codex",
            Self::Zcode => "provider-logo-zcode",
        }
    }

    pub fn logo(self, size: f32, dark: bool) -> AnyElement {
        let artwork = if self == Self::Dsh {
            // This original SVG is a single-color blue mark. Explicitly retain
            // its #4D6BFE fill in GPUI's sharp, scale-aware SVG mask renderer.
            svg()
                .path(self.asset_path(dark))
                .size(px(size))
                .text_color(rgb(0x4D6BFE))
                .into_any_element()
        } else {
            // Image rendering preserves the publisher's original colors; these
            // assets must never pass through the monochrome UI icon renderer.
            img(self.asset_path(dark)).size(px(size)).into_any_element()
        };
        div()
            .debug_selector(move || self.selector().into())
            .size(px(size))
            .flex_shrink_0()
            .child(artwork)
            .into_any_element()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ApiProvider {
    DeepSeek,
    Anthropic,
    OpenAi,
    Zai,
}

impl ApiProvider {
    pub const ALL: [Self; 4] = [Self::DeepSeek, Self::Anthropic, Self::OpenAi, Self::Zai];

    pub fn label(self) -> &'static str {
        match self {
            Self::DeepSeek => "DeepSeek",
            Self::Anthropic => "Anthropic",
            Self::OpenAi => "OpenAI",
            Self::Zai => "Z.AI",
        }
    }

    pub fn credential_slot(self) -> &'static str {
        match self {
            Self::DeepSeek => "DEEPSEEK_API_KEY",
            Self::Anthropic => "ANTHROPIC_API_KEY",
            Self::OpenAi => "OPENAI_API_KEY",
            Self::Zai => "BIGMODEL_API_KEY",
        }
    }
}

pub(crate) const ASSETS: &[(&str, &[u8])] = &[
    (
        "providers/pi.svg",
        include_bytes!("../assets/providers/pi.svg"),
    ),
    (
        "providers/dsh.svg",
        include_bytes!("../assets/providers/dsh.svg"),
    ),
    (
        "providers/claude-code.png",
        include_bytes!("../assets/providers/claude-code.png"),
    ),
    (
        "providers/codex-light.png",
        include_bytes!("../assets/providers/codex-light.png"),
    ),
    (
        "providers/codex-dark.png",
        include_bytes!("../assets/providers/codex-dark.png"),
    ),
    (
        "providers/zcode.png",
        include_bytes!("../assets/providers/zcode.png"),
    ),
];

#[cfg(test)]
mod tests {
    use super::*;
    use gpui::{AssetSource, Image, ImageFormat, SvgRenderer};
    use std::sync::Arc;

    #[test]
    fn original_artwork_is_embedded_intact_and_decodes_with_gpui() {
        let manifest: serde_json::Value =
            serde_json::from_str(include_str!("../assets/providers/provenance.json")).unwrap();
        let source = crate::icons::Assets;
        let paths = source.list("providers/").unwrap();
        for asset in manifest["assets"].as_array().unwrap() {
            let file = asset["file"].as_str().unwrap();
            let path = format!("providers/{file}");
            let bytes = source
                .load(&path)
                .unwrap()
                .expect("embedded provider asset");
            assert!(paths.iter().any(|p| p.as_ref() == path));
            assert_eq!(
                rish_agent_core::canonical::sha256_hex(bytes.as_ref()),
                asset["sha256"].as_str().unwrap()
            );
            let format = if file.ends_with(".svg") {
                ImageFormat::Svg
            } else {
                ImageFormat::Png
            };
            let decoded = Image::from_bytes(format, bytes.to_vec())
                .to_image_data(SvgRenderer::new(Arc::new(crate::icons::Assets)))
                .unwrap();
            assert_eq!(decoded.frame_count(), 1);
            // GPUI oversamples SVG frames; PNG dimensions remain unchanged.
            let scale = if file.ends_with(".svg") {
                gpui::SMOOTH_SVG_SCALE_FACTOR as u64
            } else {
                1
            };
            assert_eq!(
                decoded.size(0).width.0 as u64,
                asset["width"].as_u64().unwrap() * scale
            );
            assert_eq!(
                decoded.size(0).height.0 as u64,
                asset["height"].as_u64().unwrap() * scale
            );
            assert!(
                decoded
                    .as_bytes(0)
                    .unwrap()
                    .chunks_exact(4)
                    .any(|p| p[3] != 0)
            );
            if file == "dsh.svg" {
                assert!(
                    decoded
                        .as_bytes(0)
                        .unwrap()
                        .chunks_exact(4)
                        .any(|p| p == [0xFE, 0x6B, 0x4D, 0xFF])
                );
            }
        }
        assert!(source.load("providers/missing.png").unwrap().is_none());
    }

    #[test]
    fn runtime_products_and_api_accounts_have_distinct_labels_and_stable_storage() {
        assert_eq!(
            ApiProvider::ALL.map(|p| (p.label(), p.credential_slot())),
            [
                ("DeepSeek", "DEEPSEEK_API_KEY"),
                ("Anthropic", "ANTHROPIC_API_KEY"),
                ("OpenAI", "OPENAI_API_KEY"),
                ("Z.AI", "BIGMODEL_API_KEY"),
            ]
        );
        assert_eq!(
            RuntimeProduct::ALL.map(|product| product.label()),
            ["DSH", "Claude Code", "Codex", "zcode"]
        );
        for provider in RuntimeProduct::ALL {
            for dark in [false, true] {
                assert!(
                    ASSETS
                        .iter()
                        .any(|(path, _)| *path == provider.asset_path(dark))
                );
            }
        }
        assert_ne!(
            RuntimeProduct::Codex.asset_path(false),
            RuntimeProduct::Codex.asset_path(true)
        );
    }
}
