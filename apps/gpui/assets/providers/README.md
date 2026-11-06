# Runtime product artwork

These are original publisher assets, copied byte-for-byte. The four optional runtime product assets were retrieved on 2026-10-28; the embedded Pi engine badge was added on 2026-11-06. They identify the runtime engines in Rish settings. API credential providers are a separate setting. These are not generated illustrations, replacement lettermarks, or Lucide interface icons.

| Asset | Verified product source | Notice |
| --- | --- | --- |
| `pi.svg` | [Pi press kit](https://pi.dev/press-kit), its [square badge](https://pi.dev/favicon.svg) offered for favicons and compact badges | The publisher site declares MIT License; [upstream MIT notice](LICENSE.pi), copied from [the pinned official repository](https://github.com/earendil-works/pi/blob/c466d97b7909184bac60cdca6324ea2b5d67ed3e/LICENSE) |
| `dsh.svg` | [DeepSeek Harness website favicon](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/website/public/favicon.svg), from the local official checkout at that commit | [Upstream MIT license](LICENSE.deepseek-harness) |
| `claude-code.png` | `resources/claude-logo.png` in the official [Anthropic Claude Code extension](https://marketplace.visualstudio.com/items?itemName=anthropic.claude-code), version `2.1.92`; its manifest identifies this exact file as the extension icon | © Anthropic PBC. All rights reserved. [Trademark guidelines](https://www.anthropic.com/legal/trademark-guidelines) and [product legal terms](https://code.claude.com/docs/en/legal-and-compliance) |
| `codex-light.png`, `codex-dark.png` | `Contents/Resources/icon-codex-light.png` and `icon-codex-dark-color.png` from the official [Codex desktop app](https://openai.com/codex/), bundle `com.openai.codex`, version `26.1023.50603`, build `22391` | Proprietary OpenAI product artwork; [OpenAI brand terms](https://openai.com/brand/) |
| `zcode.png` | [ZCode app icon](https://github.com/zai-org/ZCode/blob/3c5b227649371507ddc4eb46ac5133afe6db1cab/public/logo/icons/128x128.png), pinned to the official repository commit | [Upstream Apache-2.0 license](LICENSE.zcode), [upstream notice](NOTICE.zcode.md), [brand terms](https://zcode.z.ai/en/terms) |

The Claude Code icon uses the Claude radial mark as the publisher does in its official extension. The Codex icon is the Codex terminal product artwork, not the generic OpenAI logo. The zcode icon is the application's Z mark, not the Z.ai company wordmark. Rish's lowercase `zcode` label does not rename the underlying `BIGMODEL_API_KEY` credential slot or model identifiers.

Product names and marks remain the property of their respective owners. Retaining a software license does not relicense a trademark; the proprietary Claude and Codex assets are not represented as MIT or Apache licensed. The copied ZCode notice describes the upstream product, not Rish's capabilities.

## Integrity and rendering

- [provenance.json](provenance.json) records exact source paths, versions, image dimensions and SHA-256 values.
- [SHA256SUMS](SHA256SUMS) covers the unmodified artwork bytes.
- `src/providers.rs` separates `RuntimeProduct` artwork from `ApiProvider` credential slots and embeds both Codex appearance variants. Pi has its own logo helper and is not included in the optional runtime download or subscription catalog.
- PNGs use GPUI's image renderer so publisher colors are retained. The single-color DSH vector uses its original `#4D6BFE` fill with the scale-aware SVG renderer. Pi uses the same renderer with its original `#111111` light and `#f6f6f6` dark colors selected explicitly, because GPUI does not evaluate the SVG's CSS media query. Its geometry and source bytes are unchanged.
- All assets are embedded by `icons::Assets`. Rendering performs no filesystem lookup or network request on the phone.
