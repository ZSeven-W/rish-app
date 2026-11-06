# GPUI iOS host

This target embeds the GPUI Rust static library and directly compiles the Rish
Objective-C/Objective-C++ runtime services in `modules/rish/ios/Sources`.
`Native/RishNative` declares the native module, promise and event interfaces.
The host does not link a JavaScript framework or bundle.

The default bundle ID is `tech.zseven.rish.gpui`, so this development app has its
own sandbox and keychain access. Existing Rish sessions, workspaces, and secrets
are not automatically migrated. Do not change the installed app's bundle ID to
work around migration.

## Build and verify

From `apps/gpui`, run the checked-in `scripts/build-ios.sh` build workflow. The
XcodeGen scheme is `RishGPUI`. The host links the exact static archive at:

```
mobile/target/aarch64-apple-ios-sim/debug/librish_gpui.a
mobile/target/aarch64-apple-ios/debug/librish_gpui.a
```

Release uses `release/` instead of `debug/`. Xcode settings
`RISH_GPUI_TARGET`, `RISH_GPUI_PROFILE`, and `RISH_GPUI_STATIC_LIB` allow explicit
selection. Signing and distribution are not configured by this target.

For a separately documented local smoke build, `RISH_NATIVE_VENDOR` and
`RISH_NATIVE_INCLUDE` can point Xcode at an isolated archive/header set. Their
defaults remain the canonical native module's `Vendor` and `include` directories.
Changing these settings does not relax the preparation workflow's artifact
provenance checks or establish release/runtime acceptance.

The existing `modules/rish/ios/Vendor` native XCFrameworks and `include/rish.h`
must be prepared using the repository's existing preparation scripts. Merely
having an old archive present is insufficient: the `rish_agent_core.h` in each
slice must match `modules/rish/core/include/rish_agent_core.h`. App resources
are in `Resources`; shared guest resources are in
`modules/rish/shared/GuestAssets`. The host links the framework dependencies
required by the native services. Guest CGI remains disabled by default.

`./ios/check-bridge.sh` runs a Foundation executable against the actual bridge
with controlled native fixtures, then checks the new host sources against both
iOS SDKs. It covers queue selection, positional argument validation, UTF-8,
BOOL calling convention, 128 queued completion/cancellation pairs,
private-selector rejection, changed-signature rejection,
once-only replies, JSON errors, synchronous exports, and event filtering.
It also validates the naming prompt's dictionary ABI and runs Foundation name
validation checks against a freshly built host core FFI archive. These checks do
not link the full iOS runtime or prove device execution.

Run `./ios/check-name-layout.sh BOOTED_SIMULATOR_UDID` with an explicitly selected,
already booted iOS simulator to exercise ten UIKit naming-layout checks. The
script builds the current arm64 simulator core FFI and runs an offscreen test
executable; it does not boot a simulator, install/relaunch the app, or send UI
events. It checks the initial viewport before keyboard tracking activates,
keyboard constraint precedence, viewport restoration, opaque card fill, scrim
ordering, and bounded landscape layout. The Rust
`aarch64-apple-ios-sim` target and Xcode iOS simulator SDK are required.

After a debug simulator build, run `./ios/check-gpui-fonts.sh BOOTED_SIMULATOR_UDID`
to check the app's current code-font helper against its actual compiled GPUI
backend. This standalone process resolves regular/bold/italic fonts, checks
equal ASCII advances, and shapes Chinese, Latin, and emoji text. It uses existing
mobile artifacts and Python 3.11+, without installing the app or creating UI.

`python3 ios/generate-exports.py --check` detects API drift. Regenerate without
`--check` and review `Sources/Exports.inc` when an exported native API changes.
Xcode also enforces this check before compiling.

## Host ABI

Rust calls:

```c
void rish_gpui_host_request(uint64_t id, const char *module,
                           const char *method, const char *args_json);
```

`args_json` is always a positional JSON array, including `[]` for no arguments.
For example, `LocalRuntime.providerConfiguration` receives `["dsh"]`, and
`AgentRuntime.prepare_agent_attempt` receives `[request_object]`.

The host copies input strings before returning. A serial ingress queue preserves
request order before routing to the module's `methodQueue` when declared, or a
dedicated serial queue otherwise. Native
services retain their existing stores, validation, persistence, and authority
checks. Each promise settles at most once. Synchronous native exports are
adapted into the same asynchronous reply interface.

Rust must export:

```c
void rish_gpui_host_reply(uint64_t id, const char *result_json, bool is_error);
void rish_gpui_host_event(const char *name, const char *payload_json);
```

Callbacks may arrive on any native queue. Copy the borrowed UTF-8 strings during
the callback, then notify the GPUI view through its executor. Errors have
`{"code":"...","message":"..."}` shape. A process-lifetime event sink observes
each event-emitting module; only names declared by `supportedEvents` are sent.

Dispatch is restricted to `Sources/Exports.inc`, generated from 14 existing native
module export surfaces plus `ShellInput`. Class names or Objective-C selectors
provided by a caller are never invoked directly. Argument count, declared object
types, BOOL values, and Objective-C method encodings are validated first. Native
request validators remain responsible for their domain-specific schema.

## UIKit integration

`main.m` initializes the GPUI FFI state and calls `rish_gpui_run`. The Rust
platform synchronously calls `rish_gpui_enter_ui_application`, which blocks in
`UIApplicationMain` while `Application::run` retains its strong application
owner. The delegate invokes the stored launch callback, then drives frames with
`CADisplayLink`. It forwards lifecycle events and pauses frames while inactive.
The presenter helper supports the pinned GPUI backend's legacy `UIWindow`.

`rish_gpui_layout_metrics(float *values, size_t count)` fills eight values from the
actual key window: width, height, safe-area top/right/bottom/left, horizontal size
class, and vertical size class. Sizes are UIKit points and classes use UIKit enum
values. Call only on the main thread with room for at least eight floats. It
returns false without changing output if there is no key window. The host does
not infer foldable-device dimensions, hinges, or reserved regions.

The chat composer uses `ShellInput.inlineSync`, `inlineWait`, `inlineSnapshot`,
`inlineClose`, and `inlineClearIfUnchanged` from the exact
[`inline-composer-contract.md`](../inline-composer-contract.md) protocol. A
`UITextView` occupies only the GPUI text rectangle; the surrounding card and
footer remain GPUI. It borrows the pinned backend's root view on a later main
queue turn and never presents a controller. UIKit owns IME marked text,
selection, paste, and multiline Return. Layout-only updates preserve the buffer;
only a newer explicit text revision replaces it. Native snapshots include
bottom keyboard intersection and preferred text height, with one waiter and a
10-second heartbeat. Sending clears the buffer only if its native revision is
still unchanged and there is no marked text. Late keystrokes survive a failed
compare, without an automatic retry.

Run `check-inline-composer.sh BOOTED_SIMULATOR_UDID` for offscreen protocol,
JSON round-trip types, composition, lifecycle, wait/close, atomic clear,
keyboard geometry and placeholder/caret alignment checks.
The executable creates a private UIView root; it never installs an app,
initializes workspace services, or sends user input. `ShellInput.edit` remains
exported for legacy callers but is not the inline chat path.

`ShellInput.name([options])` presents a compact, themed single-line sheet for
workspace creation and conversation renaming. The options dictionary contains
`kind`, `initial_text`, `title`, `label`, `placeholder`, `hint`, `submit_label`,
`cancel_label`, `empty_error`, `invalid_error`, `long_error`, and `appearance`.
It returns a trimmed NFC string after submission or JSON null after cancellation.
The field preserves marked IME text and disables submission until composition
finishes and validation passes. Workspace names use the shared core validator;
conversation names allow up to 120 Unicode scalars. The caller still performs the
existing workspace creation or conversation CAS operation after the sheet closes.

`ShellInput.editFile([options])` presents an opaque, themed full-screen text
editor. The exact options are `initial_text`, `title`, `appearance`, `save_label`,
`cancel_label`, `max_bytes`, and `too_long_message`. It preserves committed text
verbatim, including an empty string, and returns JSON null on cancellation.
Save is disabled during marked IME composition or above the UTF-8 byte limit
(at most 262144). The controller does not write files: the Rust caller keeps
the original workspace/path/revision and performs the guarded native write.

Task Live Activity integration and the full Agent controller/tool workflows
remain incomplete in the GPUI app. There is no verified GPUI signing or
TestFlight pipeline. Native runtime functionality still requires integration
validation on a simulator/device with current vendor archives; a syntax check is
not that acceptance test.
