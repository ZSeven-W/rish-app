# Third-party notices

This file is a source-tree notice inventory for the current Rish App checkout.
It is not a complete SBOM and is not a legal conclusion about a future App
binary or guest distribution. It covers the fixed native libraries used by the
native builds and GPUI sources described below. Rust transitive dependencies,
Android dependencies, guest package closures, and any optional externally
downloaded CLI must be audited against the exact release candidate before
distribution.

The project source is licensed under the top-level [MIT License](LICENSE), with
copyright stated there as `2026 Rish contributors`. That project license does
not relicense third-party components, guest payloads, or brand/trademark assets.
The Rish MIT text below also preserves the pinned sibling Rish source's own
license record.

## Copied license texts

The exact upstream license files are kept under `third-party/licenses/`:

| Component | Version / source revision | License text | SHA-256 of copied text |
| --- | --- | --- | --- |
| Rish runtime/FFI | [`ZSeven-W/rish`](https://github.com/ZSeven-W/rish) commit `ef660dc81fa31cbe279b1f4ba355a97734ff1740` | [rish-MIT.txt](third-party/licenses/rish-MIT.txt), MIT | `7cfca0a2a21dc7b205a5c4289dc1605056280edb858e2ea5894d38efaa926f6d` |
| libgit2 | `1.9.6`, commit `26055f5af74ab1cf636d272e8a34315496d3f06f` | [libgit2-COPYING.txt](third-party/licenses/libgit2-COPYING.txt), GPLv2 plus the upstream linking exception | `e0938121c0554985fe17196ac38fc590d149268e9c46e0c0e7a2eae1354fae71` |
| libssh2 | `1.11.1`, commit `a312b43325e3383c865a87bb1d26cb52e3292641` | [libssh2-COPYING.txt](third-party/licenses/libssh2-COPYING.txt), BSD-3-Clause | `f7f9633cf9ff2f1333f3d7ce46973a8716a4d2a2815ad56f30d437d5fea7bafe` |
| OpenSSL | `3.6.2`, commit `fe686e15d84334b284f883118ed92f64b409b3aa` | [openssl-Apache-2.0.txt](third-party/licenses/openssl-Apache-2.0.txt), Apache-2.0 | `7d5450cb2d142651b8afa315b5f238efc805dad827d91ba367d8516bc9d49e7a` |

The fixed native build metadata is in `modules/rish/ios/Vendor/*.version`.
The generated `libgit2`, `libssh2`, and `libcrypto` XCFramework archives are
ignored build outputs; their source revision, configuration, architecture, and
archive hashes are recorded there rather than copied into this source tree.

## Native GPUI development shell

The independent `apps/gpui` shell adds the following sources. Its two Cargo
lockfiles record the complete resolved Rust dependencies.

- [GPUI Mobile](https://github.com/itsbalamurali/gpui-mobile) at
  `5abbefa5f753ee9a1920d6d2eaeede981e79eeff` (the reviewed, unreleased
  [PR #49](https://github.com/itsbalamurali/gpui-mobile/pull/49) revision), used
  under its Apache-2.0 option.
  Adapted Android host sources retain their upstream attribution and
  [license text](apps/gpui/android/GPUI-MOBILE-LICENSE).
  The pinned source is retained under `apps/gpui/vendor/gpui-mobile`; its
  [local patch record](apps/gpui/vendor/gpui-mobile/RISH-PATCHES.txt) documents
  the Android Activity recreation changes, with upstream hashes and licenses.
- [GPUI Fast](https://github.com/longbridge/gpui-fast), published crates
  `gpui-fast` and `gpui-fast-platform` at `0.1.7`, Apache-2.0.
  The editable desktop input adapts its GPUI input example at source revision
  `5ae2355035b956afc4ee37a32a1283f9c848fb50`, with changes for IME ranges,
  selection and scrolling. [Apache license](apps/gpui/GPUI-LICENSE-APACHE).
- Mobile core/renderer use `gpui-pre` and `gpui-pre-wgpu` at `0.3.6`, with
  `wgpu` at `29.0.4`; the corresponding crate licenses and transitive
  dependency notices remain applicable.
  The renderer's Android debug-metadata workaround is documented in its
  [local patch record](apps/gpui/vendor/gpui-pre-wgpu/RISH-PATCHES.txt), alongside
  the source archive checksum and Apache-2.0 license.
- The native interface embeds 36 unmodified [Lucide](https://github.com/lucide-icons/lucide)
  SVGs from version `1.34.0`, commit
  `1a60fd28ed7111bbf6acedc0896f3d83cd73945a`. Their
  [license, source and checksums](apps/gpui/assets/icons/lucide/README.md) are
  retained with the assets. Icons inherit the current interface color.

## Embedded assistant runtime and engine artwork

The mobile assistant embeds `@earendil-works/pi-agent-core` and
`@earendil-works/pi-ai` at `1.4.0`, together with TypeBox `1.3.27` code used by
those packages. Their original MIT notices, pinned npm dependency graph, bundle
digest and reproducible build instructions are retained in
[`rish-pi-runtime`](apps/gpui/crates/rish-pi-runtime/README.md). QuickJS is
embedded through `rquickjs` `0.12.1`; the Cargo lockfiles record the Rust/C
dependency versions. The Pi CLI and provider SDKs are not in the JavaScript
bundle.

Runtime-engine artwork uses original DSH, Claude Code, Codex and zcode assets.
Their individual sources, hashes and available license texts are recorded in
[`assets/providers`](apps/gpui/assets/providers/README.md). These brand assets
are not relicensed under the application's MIT license.

## Guest and optional runtime boundary

The app tracks a kernel and CPIO guest payload under
`modules/rish/shared/GuestAssets/`, with `SHA256SUMS` for the exact bytes.
The Android guest diagnostic target can package the same files after the
runtime is staged with `scripts/prepare-rish-android.sh`; the GPUI Android app
does not bundle the experimental guest by default. There is one source copy
and one set of pinned digests.
The pinned sibling Rish source provides the guest provenance and license
correspondence in
[`guest/x86_64/SOURCES-AND-LICENSES.md`](https://github.com/ZSeven-W/rish/blob/ef660dc81fa31cbe279b1f4ba355a97734ff1740/guest/x86_64/SOURCES-AND-LICENSES.md)
and its `assets.lock.tsv`/build recipes. The exact App hashes are paired with
the verified member mapping, Alpine package records, source lock, and guest
license texts in [`third-party/guest/`](third-party/guest/PROVENANCE.md).
The currently tracked values are CPIO SHA-256
`ebcd2279be5dfc92b1c3264c355bb440a027079bcef2fa9be209654891479b9d` (the base
Alpine initramfs `152905238ade87b7e1cd495508ff1bb92807b4440cc0ed056030e4dfd72caea0`
with the guest agent rebuilt from the pinned host revision recorded in
`guest-agent-build.json`) and kernel SHA-256
`1e6bf9027720c75c3ed0d79171f21b5791ee40ca9795d07c7c6e04dc5ea2ae90`, both
verified against the adjacent `SHA256SUMS` file.
The CPIO includes BusyBox, musl, apk/libapk, OpenSSL/zlib and the pinned
musl/tree APK inputs.

### Corresponding source for the guest payload (written offer)

The kernel (`vmlinuz-virt-6.18.35`) and parts of the initramfs
(`rish-container.cpio`: BusyBox, apk-tools, the Linux kernel modules) are
distributed under the GNU General Public License version 2. Distributing this
repository distributes those binaries, so the complete corresponding source is
provided as follows:

1. **Download.** Every Rish App release that ships or changes these two files
   attaches the archive `rish-guest-corresponding-sources-<date>.tar` with its
   SHA-256 on the release page:
   <https://github.com/ZSeven-W/rish-app/releases>. The archive contains the
   exact Linux 6.18 source tarball and 6.18.35 stable patch, the Alpine
   APKBUILDs, patches and kernel configuration named by the pinned package
   revisions, the upstream source tarballs of BusyBox 1.37.0, musl 1.2.6,
   apk-tools 3.0.6, OpenSSL 3.5.7, zlib and tree 2.3.2, the guest license
   texts, and source snapshots of the sibling runtime commits (`2b66dd9`,
   `83233ea`) that hold the guest recipe, overlay and guest-agent source. The
   member list and per-file hashes are in `third-party/guest/source-lock.tsv`
   and `manifest.tsv`; the archive is rebuilt from them with
   `third-party/guest/collect-source-materials.sh`.
2. **Written offer.** If the release download is unavailable, any third party
   may request the same corresponding source, on a physical medium or as a
   download, for no more than the cost of physically performing the
   distribution. Open an issue titled "GPL source request" at
   <https://github.com/ZSeven-W/rish-app/issues>. This offer is valid for
   three years from the date each affected release is first published, as
   required by GPLv2 §3(b).

The App bundle only ever ships the two tracked files above; the officially
downloaded CLI experiments are excluded from this offer and are documented
separately below.

Official Codex and Claude CLI binaries are not tracked in this repository. If a
future installer or release downloads or redistributes them, their exact
source, version, hash, terms and user-facing boundary must be reviewed
separately. No closed-source CLI authorization is asserted here.

## Dependency inventory

The retired React Native app, npm dependency graph, CocoaPods integration and
React source compatibility layer have been removed. Current resolved Rust
dependencies are recorded by the two GPUI Cargo lockfiles and the shared core
lockfile; Android dependencies are declared in the GPUI Gradle project. Produce
a complete notice inventory from the exact candidate before distributing a build.

No API keys, private keys, passwords, credential-bearing URLs, or user data are
included in these notices. This file and the copied texts are source-release
materials only; they do not authorize a commit, push, repository visibility
change, binary release, or product claim.
