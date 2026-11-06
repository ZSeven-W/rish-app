# Tracked GuestAssets provenance

This directory records the evidence for the two binary files tracked under
`modules/rish/shared/GuestAssets/`. It is a provenance and rebuild aid,
not a legal opinion. The package license identifiers below are copied from
Alpine package metadata; the corresponding source and notice obligations still
need to be handled by the release owner.

## What matches the pinned inputs

The tracked kernel is byte-identical to the Alpine 3.24.1 x86_64 netboot
`vmlinuz-virt` pin in `rish/guest/x86_64/assets.lock.tsv`:

```
size  12575744
sha256 1e6bf9027720c75c3ed0d79171f21b5791ee40ca9795d07c7c6e04dc5ea2ae90
url    https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/x86_64/netboot-3.24.1/vmlinuz-virt
```

The tracked CPIO is an uncompressed `newc` archive with 9,835,008 bytes and
SHA-256 `152905238ade87b7e1cd495508ff1bb92807b4440cc0ed056030e4dfd72caea0`.
The archive contains 50 `newc` entries, including directories and symlinks;
`manifest.tsv` records every payload member with an independently checked
source or construction mapping.
That exact derived hash is recorded by runtime commit `83233ea` when the
offline APK repository was added. The archive's Alpine payload was inspected
with host archive readers only. BusyBox, the musl loader, apk/libapk, OpenSSL,
zlib, and all three Alpine signing keys match the corresponding files in the
pinned `alpine-minirootfs-3.24.1-x86_64.tar.gz` byte-for-byte. The two embedded
APKs and the APKINDEX also match the 83233ea lock inputs byte-for-byte.

The APKINDEX embedded in the App is the older 83233ea pin
(`24281c730dfa9c721f2f21fc30ead29f99f557ff2d6736663617aaa5cd5d2102`). The
runtime branch later changed that index pin at `0205930`; the newer current
runtime output must therefore not be substituted for the tracked App CPIO.

The minirootfs installed database is not present in the App CPIO. The runtime
recipe deliberately creates an empty `lib/apk/db/installed` so the image can
use its offline repository and let `apk add tree` populate bookkeeping during
the guest proof. `minirootfs-packages.tsv` preserves the 16 package records
read from the pinned minirootfs database, including versions, upstream URLs,
the APK metadata `c:` commit fields, and license fields. The two repository APKs carry
their own `.PKGINFO` records: musl is `1.2.6-r2`, commit
`f5640d3a10f664c9119720c60515265d3d6f6d01`, MIT; tree is `2.3.2-r0`, commit
`429bf8299b274b32b6bb940fd5b1ba171e32872a`, GPL-2.0-or-later.
For audit of the embedded package metadata itself, the musl APK `.PKGINFO`
is 559 bytes with SHA-256
`71d411d06c8674bed118e4df9ee408278cd8ee4bc917e8cbda2aeda688bcff98`, and the
tree APK `.PKGINFO` is 638 bytes with SHA-256
`088eb29d0f337be24325434180970e644f239c041953af0daf11a06e57c69806`.

## Source identity and reproducibility boundary

Member bytes identify a mixed historical workspace state. The `init` member
(846 bytes, SHA-256
`70d18ed7699d9c43456d141d646e5540a4b8c4fd0cda02a8751991f537f5a497`)
exactly matches runtime `2b66dd9`, while the offline repository files match
runtime `83233ea`. The later clean 83233ea overlay `init` is 898 bytes and does
not match the tracked member. The guest-agent member exactly matches a fresh
build from runtime `2b66dd9` source: Rust `1.97.1` for
`aarch64-apple-darwin`, `--release --target x86_64-unknown-linux-musl -p
rish-guest-agent`, the workspace `zig-musl-cc` linker, and
`-C link-self-contained=no` (with the workspace sysroot). The resulting
1,047,592-byte executable has SHA-256
`53b0b0702920f7c5d46c2f00490f7819f4774d6c50dee609942ce05c09b96f04`.

The runtime `guest/x86_64/build-container-initramfs.sh` and
`guest/x86_64/tools/pack-newc.rs` remain the authoritative recipe and packer.
An isolated build from clean runtime `83233ea` source with its own agent emits
9,988,608 bytes (`8734db194a7bd44d0342c1c241c008729c60cefa4689c4c1365b321ecd7dc5eb`),
because that clean source has the newer overlay and agent. Replacing those two
inputs with the exact `2b66dd9` agent/init identified above, and preserving the
observed `0600` modes for `etc/apk/repositories` and `etc/apk/world`, emitted
the tracked 9,835,008-byte CPIO byte-for-byte. This is a reproducible mapping
of the observed mixed input state, not evidence for a single runtime commit.

The linker script used above has SHA-256
`5c47e32f57dcc8c0064f73b668a51045df4068a786e3c2e6f6e04534bbac058c`, and the
workspace sysroot manifest has SHA-256
`b143d166ce601798c2ed51089c2e8b33ee106e86e9f2c02cbd3878a1e6e2907b` in the
runtime checkout. To make a new candidate, fetch the exact Alpine inputs from
the historical 83233ea lock, use the explicit source commits and build flags
above, run the runtime packer, and record a new candidate digest. A new
candidate must not silently replace the tracked App digest or alter
`SHA256SUMS`; those are separate release decisions.

## Source correspondence

The Alpine kernel packaging source recorded by runtime `ef660dc` is aports
commit `954487c7d11ef901fdf7350f9fa8638e7a45df4e`, with the pinned APKBUILD
source hash `b56b1cc91a16f54f02fd07568e1fba6200c3c62683b636efc55710165ba37e22`:

<https://gitlab.alpinelinux.org/alpine/aports/-/raw/954487c7d11ef901fdf7350f9fa8638e7a45df4e/main/linux-lts/APKBUILD>

The binary release inputs are listed in runtime
`guest/x86_64/assets.lock.tsv`; the full member-to-input mapping for the
tracked App artifact is in `manifest.tsv`. The rish overlay and guest-agent
code remain in the runtime repository and are MIT-licensed under its own
source terms. Existing copied Apache-2.0 and rish-MIT text is mapped in
`licenses/README.md`; GPL/Zlib/MIT guest package source and notice references
are also recorded there without pretending that an identifier alone completes
a corresponding-source offer. This directory intentionally does not copy or
rewrite runtime history.

## Source-delivery scope and remaining build gaps

`source-lock.tsv` and `collect-source-materials.sh` define a bounded,
hash-locked source-delivery set. Running the collector against
`/tmp/rish-guest-source-delivery-20260909` fetched and verified 215,747,734
bytes without extracting or executing any archive. It includes the exact
Linux 6.18 source tarball, stable patch, all eight Alpine patches/configs
listed by the fixed kernel APKBUILD, the APKBUILD itself, fixed Alpine
APKBUILDs and package patch/config inputs for BusyBox 1.37.0, musl 1.2.6,
apk-tools 3.0.6, and OpenSSL 3.5.7, and upstream version tarballs for BusyBox,
musl, zlib, OpenSSL, apk-tools, and tree 2.3.2. HTTP reads of the fixed
Alpine `c:` revisions confirm each APKBUILD's `pkgver/pkgrel` matches the
minirootfs/APK metadata. The delivery contains all 44 BusyBox patches plus
both BusyBox configs, all five musl patches and helper sources, the apk-tools
and OpenSSL patches, and the package APKBUILDs.

The following items remain intentionally explicit gaps rather than invented
pins:

- The kernel's corresponding source is Linux 6.18 plus the 6.18.35 stable
  patch and the Alpine patch series named by the fixed APKBUILD. Every listed
  source and patch is collected in the temporary delivery directory and
  verified against the APKBUILD's SHA-512 values; none is mirrored into Git.
- The BusyBox, apk-tools, musl, and OpenSSL APKs' fixed Alpine APKBUILDs,
  listed patches, configs, and auxiliary recipe files are collected and
  verified from their `c:` revisions. zlib and tree have fixed APKBUILDs and
  source tarballs with matching APKBUILD SHA-512 values; neither APKBUILD
  lists additional patches. The APKs' generated build environment and any
  distribution-level compiler flags remain outside this source-only audit.
- The guest-agent and overlay source are available from runtime commit
  `2b66dd9`; the exact mixed CPIO additionally uses the repository files from
  `83233ea` and the observed restrictive modes recorded above.

Consequently the collector provides a complete, bounded set of identified
source archives, Alpine recipes, patches, configs, and notices for this audit,
without putting the large archives in Git. The source set is offered through
the release-asset download and the written offer in the top-level
`THIRD_PARTY_NOTICES.md`; if a byte-identical rebuild is ever required, the
Alpine build environment and toolchain inputs would still need pinning.

## Local delivery status

At audit close, a local source archive named
`rish-guest-corresponding-sources-20260909.tar` is prepared under `/tmp` for
review. It contains the verified source-delivery files, this provenance and
lock material, the guest license texts, and source snapshots of runtime
commits `2b66dd9` and `83233ea` needed to read the guest recipe, overlay, and
guest-agent source. It excludes `.toolchain` binaries, build caches, logs,
private material, and the tracked App blobs. Local archives are not kept;
each release rebuilds the archive with `collect-source-materials.sh` and
attaches it, with its size and SHA-256, to the release that ships the guest
files, as the written offer in `THIRD_PARTY_NOTICES.md` describes.

## Guest-agent Rust dependency scope

The runtime guest-agent build from `2b66dd9` resolves the target-specific
dependency closure recorded in `rust-dependencies.tsv`. Runtime-linked crates
are base64, serde/serde_core, serde_json, itoa, memchr, zmij, rustix,
bitflags, errno, libc, and linux-raw-sys, plus the workspace
`rish-guest-protocol`. `serde_derive`, `thiserror-impl`, proc-macro2, quote,
syn, and unicode-ident are build-time proc-macro inputs; they are not guest
runtime libraries. `tempfile` is dev-only, and Windows-only lock entries are
excluded from the x86_64-musl target. Rust `std`/`core`/`alloc` licensing and
copyright are copied into `licenses/` as the Rust 1.97.1
`COPYRIGHT-library.html`, Apache, and MIT files, with their hashes recorded in
`licenses/rust-std-license-reference.md`; the compiler and toolchain are not
redistributed. This is the guest-agent closure only and does not claim to be a
manifest of the App's full npm or workspace dependency graph.

## Audit commands

The tracked `SHA256SUMS` was verified with `shasum -a 256 -c`; both entries
passed. The CPIO member table was read with host `cpio -itv`; no absolute or
parent-traversal member names were found. APK member names and `.PKGINFO`
records were read with host `tar` only; no archive-contained executable was
invoked. Canonical GPL-2.0, MIT, and Zlib texts were fetched from their
upstream license endpoints and copied under `licenses/`; the package-specific
source URLs, revisions, and metadata remain in the TSV records. The downloaded
package sources, 44 BusyBox patches/config inputs, five musl patches/helpers,
apk-tools/OpenSSL patches, and kernel source/patch/config inputs were checked
against the SHA-512 values in their fixed Alpine APKBUILDs.
