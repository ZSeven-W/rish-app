# P0 continuation · 2026-11-06

The first P0 batch was pushed to `origin/main` as
`669a99736f9c426298eb139bf81eae78ef195b56`. This record describes the follow-up
changes built from that base. The [first-pass record](p0-progress-2026-11-06.md)
is historical; it is not the status of the follow-up binaries below.

## Durable unsent input

Normal chat drafts now share the existing session snapshot, writer lease and
generation/digest CAS. There is no second draft store or new native export.
Edits are coalesced; only a durable receipt acknowledges a save. A newer edit
is not cleared by an older save or send receipt. Empty input explicitly removes
its draft, while whitespace and Unicode are preserved.

The reader accepts schema 9 and 10. Loading an old snapshot does not change its
bytes or digest; the first draft mutation upgrades to schema 10 using the same
v3 persistence envelope. Schema 10 has a bounded `composer_drafts` map. Unknown
versions fail closed rather than resetting data. Both native core archives were
rebuilt with the updated validator; an older binary cannot read schema 10.

New-chat drafts are transferred to the created conversation in the same commit.
Normal sends and successful structured-answer receipts consume only the exact
submitted draft. Cold loading, queued editor changes, actor snapshots, native
clear failures and oversize inputs retain unsaved text. Conflicts identify the
affected conversation and show both local and saved text before an explicit
choice. An unrelated writer cannot silently resolve a draft conflict.

Scope: group drafts remain process-local because BotStore has a different
submission authority; the composer says so. While an assistant owns the writer
lease, pending input is retained and marked as waiting, then flushed after the
writer returns. Unacknowledged input is not promised to survive termination.

## Android GLES rendering

Three verified failures were fixed in the vendored renderer:

1. Native GL requested unsupported compute/storage limits and used the storage
   shader path. It now shares the existing WebGL2 limits and texture transport.
2. Creating both Vulkan and GL surfaces could let Vulkan claim the native window
   before GL configured it, even with no Vulkan adapter. The native instance now
   honors the standard process-local `WGPU_BACKEND` mask before surface creation.
3. Window replacement overwrote a negotiated Fifo mode with Android's Mailbox
   preference. Startup and replacement now both select a supported mode from
   the actual surface capabilities.

Default adapter selection is unchanged. `WGPU_BACKEND=gl` is an explicit test or
runtime override, not an automatic fallback. On the API 33 arm64 emulator with
host GLES, the real-tap popup pixel test passes before and after an Activity
CREATED → RESUMED transition; screenshots were also inspected. The test checks
an empty panel's opaque interior rather than merely accepting a nonempty PNG.
See the [Android test command](../apps/gpui/README.md#android).

SwiftShader Vulkan still fails the popup test on this emulator. The GLES result
does not prove that Vulkan or physical-device rendering is fixed. No shader
algorithm, dependency version, global GPU setting or adapter ranking changed.

## Checks and mobile evidence

| Check | Result |
| --- | --- |
| Shared native core workspace | 633 passed |
| Shared shell core | 190 passed; 1 existing subprocess helper ignored |
| GPUI library after integration fixes | 450 passed |
| Source preflight / assets / preparation tests | 28 passed |
| Backend policy using locked wgpu-types 29.0.4 | 7 passed |
| Android unit tests | 112 passed; no failures/errors/skips |
| iOS native bridge/editor/workspace/naming checks | 606 passed; both SDK syntax checks passed |
| Desktop and both mobile Rust checks; formatting | Passed |
| iOS simulator app; Android arm64 app/test APK | Built successfully |
| Final iPhone native UI QA | 3 passed: initial load, draft restore, deliberate clear |
| Final Android GLES popup / Activity pause-resume QA | 1 passed; final screenshot inspected |

The first full GPUI integration run caught 22 failures. They exposed lost early
fallback input and missing capture before authority replacement; production code
was corrected. The final 450-test run includes cold-load, rejected oversized
input, late close, send/answer, conflict and writer-handoff regressions.

iPad portrait and landscape each completed manual model entry, save, select and
exact unsent-input preservation. Seventeen actual XCTest stages passed; two
zero-test discovery-cache invocations were excluded. This used the first-batch
executable `5614bbb7…`, not the follow-up executable. It is evidence for that
model-setup flow, not for the new restart behavior.

The final follow-up iOS executable `8af381ab…` was installed on a dedicated
iPhone 17 Pro / iOS 26.5 simulator, and the installed hash was verified again
after QA. Native `rish-inline-composer` assertions confirmed exact restoration
of `iPhone restart unsent draft 20261106` after app termination and relaunch,
then confirmed that deliberate deletion stayed empty after another relaunch.
Both mutations settled for five seconds before termination. These checks cover
settled ordinary-chat drafts, not an unacknowledged edit, an OS reboot or a
physical device. The final Android APK also passed the GLES pixel/lifecycle
test; logcat confirmed the GL adapter and the post-resume image was inspected.

Evidence is local at `../output/rish-p0-continuation-20261106/`: logs,
`ipad-qa/verification.json`, `iphone-draft-qa/verification.json`,
`renderer-final.log`, selected screenshots, and a source manifest recording the
base commit and modified-file hashes. No credentials,
provider authentication, live model discovery or model request was used in UI QA.

## Follow-up artifacts

Host: macOS 26.5.2 / Xcode 26.6; iOS 26.5 simulator; GPUI Rust 1.95.0;
native core Rust 1.94.1; JDK 17; Android SDK/Build Tools 36 and NDK 27.1.12297006.
Final builds used `CARGO_INCREMENTAL=0` to limit cache growth. These are developer
builds, not signed distribution releases.

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| iOS `.app/RishGPUI` executable | 151661312 | `8af381ab6cdebcb84c6ae6dcd11c93bce20ed1f48e09b48ddaced1cd7fe5a739` |
| Android `app-debug.apk` | 59247930 | `a515299e7583496ffe5875c90eec02ad91979afac76ae060b60e91350139aae2` |
| Android `app-debug-androidTest.apk` | 1854242 | `df6d6864315fe20e4502cf64897f1e26c4014a6918febc70010ba0d82586384e` |

The artifacts remain in their normal build output paths. Duplicate candidate
APKs, completed QA DerivedData, the temporary core-test target and incremental
caches were removed; necessary logs, test sources and compact evidence remain.
Task-owned simulators are removed after verification. Source, prepared native
libraries, the final packages and unrelated user data are retained.

## Remaining P0 gates

- Default Vulkan rendering on the observed emulator and physical-device coverage.
- Android complete custom-model edit/select and restart-input acceptance.
- Live-provider discovery/account changes, and group/active-assistant durable
  drafts beyond the explicitly bounded scope above.
- Verified DSH/zcode packages and Android installation architecture, followed by
  actual optional-CLI task adapters, capability probes and real-phone tasks.

P1 research and P2/P3 phone-control implementation have not been started.
