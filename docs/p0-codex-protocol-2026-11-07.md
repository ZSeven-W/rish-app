# Android Codex stdio protocol · 2026-11-07

Base commit: `c0b0f209a432b5392acf7a5a0af8e1efdb379d1b`. This continues the
[command-only probe](p0-codex-probe-2026-11-06.md) with an actual app-server
connection. It remains an explicit development build; task execution and
production authentication are still disabled.

## Protocol and process lifecycle

After package/ABI/SHA-256 verification and the two existing offline commands,
the probe starts the same pinned Codex binary as `app-server --stdio`. Its fixed
JSONL exchange follows the [official app-server protocol](https://learn.chatgpt.com/docs/app-server):

1. Send `initialize` with fixed Rish client metadata and request ID 1.
2. Require the matching successful response with a nonempty string `userAgent`.
3. Send the `initialized` notification, then `thread/loaded/list` with ID 2.
4. Require an empty loaded-thread list from this fresh server.
5. Close stdin, drain protocol output, and require normal exit code 0.

The pinned `0.153.4` binary requires an explicit empty `params: {}` on
`thread/loaded/list`, even though the current documentation example omits it.
The first device attempt initialized successfully but rejected that query with
`-32600 / Invalid request: missing field params`. The probe now preserves only
a matching response's numeric error code and at most 512 Unicode code points of
its message, excluding arbitrary error data, and the request shape has a
regression assertion.

The connection does not create a thread/turn or request authentication. The
temporary credential/config home remains separate from real account storage,
and no inherited process environment is passed through. Stdout carries only
bounded protocol frames; stderr is drained independently with a bounded
diagnostic receipt. Bad response IDs, protocol errors, unexpected server
requests, malformed/oversized frames, early EOF, cancellation and timeout all
leave the capability unavailable. A process that cannot be reaped cannot count
as a successful probe. The 15-second total deadline reserves up to two seconds
for teardown. Stdout is limited to 64 KiB per frame, 256 KiB in total, 64 frames
and 16 queued frames; stderr is capped at 256 KiB read and 8 KiB retained. Strict
UTF-8 and depth-bounded JSON validation rejects malformed/duplicate-key frames.
`process_reaped` describes only the directly launched process. Post-test process
inspection separately checks for leftover Codex or CodeMode descendants; pipe
polling alone does not establish that every descendant closed its file handles.

The receipt now uses `probe_kind=offline_app_server_capability` and includes an
`app_server` result. Overall capability requires the original commands plus
successful protocol/shutdown verification. `execution` remains
`unavailable / cli_adapter_unavailable`. Shared Rust currently has only Pi and
custom Pi policies in `RuntimeSpec`; the existing Codex HTTP/SSE transport is a
different backend and is not used to fake this CLI result.

## Validation

The task-owned read-only Pixel XL API 33 arm64 emulator reported no active
Android default network before, between and after both requests. Under app UID
**10163** (instrumentation host PID **5337**), two fresh request UUIDs each
completed initialization, returned an empty loaded-thread list, and exited
normally with code **0** in **5,159 ms** and **5,183 ms**. Both receipts reported
`process_reaped=true`, `readers_stopped=true`, and no protocol error. The
installed executable SHA-256 matched the pinned input from the previous batch:
`4d76e542c222ea8c75861d8c4ade60a1a332a63255ce1c60bdaebf7c2a2869e6`.

Each request completed worker teardown and removed its temporary home before
the next could start. After both requests, probe-home and receipt directories
were empty; a device-wide process snapshot showed no remaining Codex/CodeMode
process. The production authentication factory remained disabled, including
direct start rejection, even with the verified executable installed.

Stderr reported that bubblewrap was absent from PATH and announced use of the
bundled fallback. This did not prevent the read-only protocol exchange; no
sandboxed tool process was exercised, so that fallback's Android task support
is still unverified.

- Android JVM: **152 passed**, zero failures/errors/skips, including 25 dedicated
  protocol cases and 15 surrounding probe cases. Mock cases cover response
  ordering, malformed/oversized output, late frames, timeout, cancellation,
  nonzero exit, resistant process teardown and bounded error diagnostics.
- Enabled app-UID probe plus authentication-disabled check: **2 passed**; the
  protocol test itself performs two separate requests.
- Source archive/preflight: **25 passed**, plus the checkout audit.
- Debug and instrumentation APKs built. Shared Rust, iOS, Python preparation,
  pure Gradle validator and release tests were unchanged and not rerun here.
- Restored ordinary debug plus its authentication-disabled device check:
  **1 passed**. APK inspection found no CLI/receipt, both CLI/probe build flags
  were false, and the internal probe service was disabled.

The initial device failure was retained as evidence, followed by a diagnostic
run that established the missing `params` field, then the passing corrected
run. The earlier unit failures exposed specific-error/EOF and teardown-budget
races; those were fixed without weakening their assertions.

Reproduction uses the existing
[Android build/test instructions](../apps/gpui/README.md#android). The pinned
Codex input from the previous batch is reused; no CLI download, Rust rebuild or
new Cargo target directory is needed. Local evidence for this run is under
`../output/rish-p0-codex-protocol-20261106/` (the run began before midnight).


| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| Probe debug APK | 157830257 | `eb50318b4a264482181e109644f4bf631716a1611afedbc760be9aa9f48df618` |
| Probe test APK | 1870729 | `79d4182e301cdf87399a017ddc786c6c3c1d0b8acdd32912ba652611624f359c` |
| Final ordinary debug APK | 32708460 | `a65b201660e5e0ec152bad5c26cd65e6c05781106f45e3361ee5250c2629c183` |
| Final ordinary test APK | 1870729 | `9eceab88bc382ab05666ca37f65e229445dd696ada42c36d81b215d7704b1da5` |

The probe APK was replaced by the ordinary APK, without retaining another
large copy. Only the debug packaging archive and its incremental packaging
state were rebuilt to avoid unused ZIP space. Switching back also removed the
three intermediate Codex copies; the Android app build directory fell from
about 1.4 GiB to 682 MiB. Existing prepared Codex input/cache were reused, the
owned emulator was stopped, and this batch's separate evidence contains only
small logs, receipts and source metadata.

## Remaining execution gate

An initialized process and an empty thread listing do not establish model
access, tool execution or task completion. The next adapter still needs shared
task authority, real turn streaming, approval/tool routing, cancellation,
durable results and restart recovery. Physical Android devices, other system
versions and any additional runtime dependencies for those tasks remain to be
validated.
