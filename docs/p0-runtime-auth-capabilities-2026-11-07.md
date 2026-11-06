# Android runtime authentication capabilities · 2026-11-07

Base commit: `6486f5d78cfe7724a4b6166f3256ec84cbc73e5e`.

## Corrected behavior

The Android runtime catalog used protocol recognition (`codex` / `claude-code`)
as its authentication capability. Both ordinary and Codex-probe builds disable
production CLI authentication, so the UI initially offered a sign-in detail
view and a redundant status lookup before discovering it was unavailable.
The actual login remained blocked; this was a capability-reporting defect.

The production catalog route now uses the same read-only process-factory
availability check as authentication. Missing capability defaults to false,
an exception disables only the affected engine, and only known protocols can
receive authentication capability. It does not initialize the runtime or
authentication manager, restore credentials, inspect login status, or launch a
process. When the build flag is false, it does not even inspect executable
metadata.

`supported` and `authorization_browser` follow that native capability.
`native_code_entry` stays false because the Android manager has no verified
stdin code-submission contract. Source/provider selection also remain false.
Installation and task execution retain their separate unavailable states.
The existing shared UI consequently uses its “Sign-in unavailable” branch and
does not request authentication status from an unsupported engine.

The iOS catalog is unchanged: it has different native authentication paths,
including host HTTPS for Codex and separate guest/account services. This batch
does not establish their current end-to-end readiness.

## Observed checks

- Android JVM: **156 passed**, zero failures/errors/skips. The catalog suite
  contains 12 cases, including selective native capability, default denial,
  unknown-protocol denial, failed reads and capability changes between reads.
- API 33 arm64 emulator, ordinary package: **3 passed**.
- Same emulator, explicit Codex package: **3 passed**. The test observed the
  packaged executable while confirming all authentication capabilities stayed
  false and the actual factory returned `cli_auth_disabled`.
- A production `routePlatform` test uses a context that records prohibited
  storage, executable-metadata and UI access. No access occurred, even when a
  capability-read exception could otherwise be caught by the catalog.
- Source preflight: **25 passed**, plus the checkout audit.

The device had no active default network. This batch did not run either CLI,
start authentication, call a provider, or alter credentials. Rust, iOS, release
packaging and the existing app-server protocol tests on a device were not
rerun; their implementation was unchanged. Existing native libraries were
reused without a new Cargo target or a Rust rebuild.

After restoring ordinary debug, the same **3 device checks passed** again.
APK inspection confirmed no CLI or probe manifest and a disabled probe service.
The final app build directory occupies 682 MiB, the APK about 31.2 MiB. The
owned emulator was stopped; no extra APK copy or native build tree was kept.
Evidence is in `../output/rish-p0-auth-capabilities-20261107/`; the verified
Codex input/cache from the previous batch was reused without a download.

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| Probe debug APK | 131299491 | `9037a0108b43b9980ee1b4f9179700f55902245e3bda259b128baf40e5161726` |
| Probe test APK | 2216497 | `5c13343dff6784efe440fa8ce50ecea101b9c48da041dd5142561c1dacfd1469` |
| Final ordinary debug APK | 32709004 | `b628d545f25facafad986cbb2f7214471eac66cbf68d9db543c9f8ce550239d6` |
| Final ordinary test APK | 2216517 | `cfaac9e4d25a5c13e570e98ffd13b423ebe4482084dd4498bfbfc1b431616341` |

## Next runtime gate

Codex app-server owns a turn/tool loop; replacing the existing model HTTP
transport would not integrate it with Rish's shared task authority. The next
adapter must bind its thread/turn/item identities to the frozen local attempt,
preserve generation/digest CAS, route approvals and cancellation through the
existing native journal, and reject unknown or stale callbacks. Android's
downloaded-ELF execution restriction also remains separate from the debug
packaging route. No new installer or task-ready capability is enabled here.
