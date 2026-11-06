# Optional runtime installation: P0 handoff

Checked on 2026-11-06 against source baseline `3b045629`. This is an installation
and execution boundary record, not a claim that any optional CLI can run a
Rish task. Pi remains the only embedded execution engine; custom runtime scripts
are Pi policy hooks.

## Current platform paths

| Product | iOS | Android | Next acceptance gate |
| --- | --- | --- | --- |
| Claude Code | Versioned Linux x64 musl download; existing guest session supports bounded text completion | No optional download installer; native CLI packaging disabled | Adapt actual guest execution to shared task, tool, approval, cancellation and recovery contracts |
| Codex | Versioned Linux x64 musl download; existing account/chat transport uses host HTTPS | No optional download installer; native CLI packaging disabled | Build and probe a real CLI execution adapter; host HTTPS is not proof of CLI execution |
| DSH | No install descriptor; guest Node is a candidate dependency | No installer or Android native addon package | Reproducible dependency closure and actual guest execution probe |
| zcode | No verified compatible CLI distribution descriptor | No installer or Android distribution | Produce and verify a compatible CLI package before exposing a download |

Download integrity, installation, execution and account authentication are
independent. A verified file remains `downloaded`, with execution `unavailable`,
until the selected backend completes a real task on its target platform.

## DSH release evidence

The intended product is
[`deepseek-ai/deepseek-harness`](https://github.com/deepseek-ai/deepseek-harness/releases/tag/dsh-v0.2.2-rc.1).
Its observed release is `dsh-v0.2.2-rc.1`; the release has no standalone binary
attachments. The official npm entry is
[`@deepseek-ai/dsh@0.2.2-rc.1`](https://registry.npmjs.org/@deepseek-ai/dsh/0.2.2-rc.1),
with `lib/bin.js` and Node `>=24.9.0`.

The registry reports 76,416 unpacked bytes for the entry package and integrity
`sha512-ijR9UEVYkG15Q/Q79JzvzLBzQOQfc63VLr9n6flpwHPhr5IKn2UxthnSoto/P9l7qGd7pPvI1Ra6TW7LH3oKpg==`.
This is not the total installation size. The package has plugin and transitive
dependencies; a verified lock, full payload size and locally computed SHA-256
are still needed. No registry SHA-1 is substituted for the downloader's SHA-256.

The versioned
[native system support matrix](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.2.2-rc.1/native/system/docs/support-matrix.md)
includes Linux x64 musl, but no Android or iOS native package. Preserve both the
first-party MIT notice and each dependency's notices, including the native
system package's BSD-3-Clause notice.

Rish already registers `node-24-18-1-alpine3-23-amd64` in
[`RuntimeEnvironmentCatalog.json`](../modules/rish/shared/GuestAssets/RuntimeEnvironmentCatalog.json).
The Node 24.18.1 environment satisfies DSH's declared minimum. Its recorded
32,586,455-byte `.rishenv` SHA-256 is
`7177a1dc1b72156e08dcd0ae350bcf013d1231966bf0bf9e59e499755fc3927f`.
The [environment release](https://github.com/ZSeven-W/rish-app/releases/tag/runtime-environments-2026-09-15)
is a candidate input; this work has not rerun that environment on a phone.

Next: lock and package the complete Linux x64 musl npm dependency tree, then
probe Node/addon loading, filesystem/process/network behavior, cancellation,
restart and memory requirements in the existing guest. Only after those checks
should a DSH install descriptor and shared task adapter be enabled.

## zcode release evidence

The intended product is [`zai-org/ZCode`](https://github.com/zai-org/ZCode), not
the separate `zode` project. The observed
[`v3.17.2` release](https://github.com/zai-org/ZCode/releases/tag/v3.17.2)
contains macOS DMG/ZIP, Windows EXE and `SHA256SUMS`; no Linux or mobile CLI
attachment was found.

Source revision `a9fe401eede6e6e5e01be9048679c206fe6f02d9` documents
[`pnpm build:zcode`](https://github.com/zai-org/ZCode/blob/a9fe401eede6e6e5e01be9048679c206fe6f02d9/README.md)
with Node 24.14.0 and pnpm 10.33.2. The resulting distribution needs Node and
bundled runtime dependencies. The example download domain is a placeholder,
not a usable Rish installation source.

Its [SEA target definitions](https://github.com/zai-org/ZCode/blob/a9fe401eede6e6e5e01be9048679c206fe6f02d9/apps/zcode-cli/packages/cli/scripts/sea-targets.mjs)
support desktop Linux/macOS/Windows targets. Linux uses the official Node
binary base; compatibility with Rish's Alpine musl guest is unverified.
Next: produce a reproducible compatible package, include upstream Apache-2.0
and third-party notices, publish its exact bytes/checksums, and run the same
execution probes before adding an install descriptor.

## Android installation boundary

The app targets SDK 36. Android's
[execution restriction for apps targeting API 29 or newer](https://developer.android.com/about/versions/10/behavior-changes-10#execute-permission)
prevents treating an ELF downloaded into writable app storage as a normal
`execve` target. The current subscription process factory expects packaged
files in `nativeLibraryDir`; its presence does not implement a downloadable
runtime.

Evaluate a packaged matching-ABI runtime or a verified guest path, then test
under the actual app UID. A desktop, ADB or Termux result does not satisfy that
gate. Keep Android installation explicitly unavailable until the complete
install/probe/cancel/recovery path is implemented.
