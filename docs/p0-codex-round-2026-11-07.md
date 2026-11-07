# Android Codex single text turn · 2026-11-07

This batch exercises the Android native round service through its existing
committed-session and prepared-attempt checks, dispatch marker, preview
events, and journal settlement. The Android tests inject the Codex transport
into that service and create the same checkpoints that the controller sends.
The runtime catalog still reports execution unavailable. App runtime
construction has no Codex transport or credential provisioning.

The scoped input is one user text message and optional frozen instructions on
round zero. A fresh app-server connection starts an ephemeral thread in a
temporary home with read-only sandbox requested and approval policy set to
never. Notifications are matched to the acknowledged thread and turn,
including notifications that arrive before the turn response. Deltas are
preview only. The journal accepts the completed message after a matching
successful turn and clean process shutdown. The receipt includes the Codex
turn ID, the Rish operation ID, and hashes of the Rish-visible input and the
exact thread/turn request frames. The [app-server protocol](https://learn.chatgpt.com/docs/app-server)
defines the message shapes.

Cancellation first marks the round in the WAL and signals the local process
owner. A late reply cannot settle against that revision. When dispatch
occurred and no terminal answer can be committed, recovery reads the
`ambiguous` row without resending. Local cancellation does not establish
remote cancellation. The adapter rejects tool items and server requests.
Tool event rejection is a protocol check. Android sandbox enforcement and
process-tree teardown under a tool workload still require validation before
enabling any user execution entry.

## Verification

- **156 Android JVM tests passed**, including the existing bounded stdio
  probe cases. Source preflight passed all 25 cases and the checkout audit.
- **10 probe-package device tests passed** on the offline API 33 arm64
  emulator. Four scripted round tests cover preview correlation and
  durable text, queued replies after cancellation, no replay after EOF,
  and rejection of tool output. The real packaged Codex 0.153.4 app-server
  called a credential-free `127.0.0.1` Responses fixture and saved its reply
  through the same journal. The original binary integrity and handshake
  checks, HTTP credential preflight, and disabled authorization checks also
  passed. The device process snapshot showed no remaining Codex process.
- **8 standard-package device tests passed.** After restoring the standard
  package, the compact debug APK was 31.2 MiB. It has no Codex binary or probe
  receipt, and both CLI authorization and probe build flags are false.
- The loopback fixture returns scripted SSE. Live model and account
  validation remain open, along with task selection in the shared assistant
  controller. Neither the standard build nor the probe package advertises
  Codex execution.

Reuse the verified binary and [probe build instructions](../apps/gpui/README.md#android).
On an offline arm64 Android fixture, run the round class with both APKs
installed. The loopback case requires the probe package.

```sh
adb shell am instrument -w -r -e class tech.zseven.rish.AndroidCodexRoundTest \
  tech.zseven.rish.gpui.test/androidx.test.runner.AndroidJUnitRunner
```
