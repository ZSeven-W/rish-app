# GPUI development guide

The application source is [`apps/gpui`](../apps/gpui/README.md). iOS and Android
share the Rust view/controller tree; Objective-C/Objective-C++ and Kotlin/JNI
services own platform operations. The previous React Native app, JavaScript UI,
and its build pipeline have been removed. The earlier architecture notes remain
available in Git history, not as instructions for building the current app.

## Repository layout

| Path | Responsibility |
| --- | --- |
| `apps/gpui/src` | Shared GPUI UI, model selection, input and native transport |
| `apps/gpui/crates/rish-shell-core` | Session transitions, configuration and persistence contract |
| `apps/gpui/ios` | UIKit host, native input, native bridge and app resources |
| `apps/gpui/ios/Native/RishNative` | Native module, promise and event declarations |
| `apps/gpui/android` | Android host, prompts, JNI routing and Gradle project |
| `modules/rish/core` | Shared Rust session validator and runtime reducers |
| `modules/rish/ios/Sources` | iOS platform services |
| `modules/rish/ios/Tests` | Native iOS service regression tests |
| `modules/rish/android/src` | Android platform service sources and tests |
| `modules/rish/android/guestprobe` | Android guest probe sources |
| `modules/rish/android/rish-agent-core` | Prepared agent-core JNI dependency |
| `modules/rish/android/rish-libgit2` | Prepared Git dependencies |
| `modules/rish/android/rish-ffi` | Prepared VM dependency |
| `modules/rish/shared/GuestAssets` | Guest resources and integrity metadata |
| `brand/harness` | Provider brand assets |

Generated Cargo targets, Gradle outputs, Xcode projects, native Vendor archives,
app data and signed products are local build inputs, not source changes.

## Check and run the desktop preview

Use Rust 1.95.0 and `rustfmt` for the GPUI workspaces. The shared native core and
VM preparation scripts have separate pinned toolchains; do not change their
pins to make a local environment pass. The desktop preview requires macOS and
Xcode command-line tools. Run these commands from the repository root:

```sh
node scripts/verify-source-checkout.mjs
apps/gpui/scripts/check.sh core
apps/gpui/scripts/check.sh desktop
cargo test --locked --manifest-path apps/gpui/Cargo.toml --lib
apps/gpui/scripts/build-desktop.sh --run
```

Node is used by repository maintenance scripts, not by the app. The preview
has no mobile model, secure-storage, file/Git or VM runtime; unavailable
operations report that fact. A working preview does not establish mobile
feature parity.

The desktop and mobile Cargo workspaces intentionally use separate lockfiles.
Format only the GPUI packages, without reformatting the independently maintained
native core workspace:

```sh
cargo fmt --manifest-path apps/gpui/Cargo.toml -p rish-gpui -p rish-shell-core
cargo fmt --manifest-path apps/gpui/mobile/Cargo.toml -p rish-gpui-mobile
```

## iOS build prerequisites

The GPUI host targets iOS 16 or newer and needs Xcode, XcodeGen, and Rust targets
`aarch64-apple-ios` and `aarch64-apple-ios-sim`. Preparation of the VM dependency
is stricter than building the host: `scripts/prepare-rish-ios.sh` currently pins
Xcode 26.6 (17F113), iOS device/simulator SDK 26.5, and Rust 1.94.1 through the
`1.94` toolchain name. Its expected source commit, header and lockfile hashes are
checked by the script. Read each preparation script before selecting toolchains;
a newer Xcode installation does not automatically satisfy these pins.

The agent-core preparation script uses
`modules/rish/core/rust-toolchain.toml`. Git preparation needs CMake, Perl and
`make`; set `CMAKE_BIN=/absolute/path/to/cmake` when CMake is not on `PATH`.

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
apps/gpui/scripts/check.sh ios
```

This checks Rust and runs the Foundation bridge/name-validation tests plus
native host syntax checks for both SDKs. It does not link all native services.

After installing the exact native preparation prerequisites:

```sh
scripts/prepare-rish-ios.sh
scripts/prepare-rish-agent-core.sh
scripts/prepare-libgit2-ios.sh
apps/gpui/scripts/build-ios.sh --simulator
```

The VM script fetches the pinned public Rish source into an isolated temporary
checkout by default. A reviewed checkout can be selected with `RISH_SOURCE_DIR`.
`RISH_IOS_OFFLINE=1` requires that checkout, the pinned toolchain/targets and a
populated Cargo cache; it does not make the other preparation scripts offline.

The build creates an unsigned app at:

```text
apps/gpui/build/ios-simulator/Build/Products/Debug-iphonesimulator/RishGPUI.app
```

Use `--device` for an unsigned device build and `--release` for optimization.
Device installation requires your own signing configuration. The GPUI target
has no verified distribution or TestFlight pipeline; see
[distribution status](testflight.md).

For an explicitly prepared development archive set, the build script accepts
`RISH_GPUI_NATIVE_VENDOR` and `RISH_GPUI_NATIVE_INCLUDE`. Xcode's corresponding
settings are `RISH_NATIVE_VENDOR` and `RISH_NATIVE_INCLUDE`. Record source
versions, hashes and toolchains beside the archives. The overrides retain
existence and current agent-core header checks but do not certify canonical
release preparation.

The Rust iOS artifact is a static library whose host request symbol is resolved
at the final application link. If building it directly, use:

```sh
IPHONEOS_DEPLOYMENT_TARGET=16.0 cargo rustc --locked \
  --manifest-path apps/gpui/mobile/Cargo.toml \
  --target aarch64-apple-ios-sim --lib --crate-type staticlib
```

The manifest's Android `cdylib` is not an iOS output. App resources are in
`apps/gpui/ios/Resources`; shared guest resources are in
`modules/rish/shared/GuestAssets`. Regenerate the Xcode project with
`xcodegen generate --spec apps/gpui/ios/project.yml` after changing its source
or resource list.

## Android build prerequisites

Install JDK 17, SDK platform 36, build-tools 36.0.0, NDK 27.1.12297006,
CMake 3.22.1, and the ARM64 Rust target:

```sh
rustup target add aarch64-linux-android
cargo install cargo-ndk --locked --version 4.1.2
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/27.1.12297006"
apps/gpui/scripts/check.sh android
scripts/prepare-rish-agent-core-android.sh
apps/gpui/scripts/build-android.sh
```

The preparation script uses the core's pinned Rust toolchain. The host packages
ARM64 only and builds native libraries with 16 KiB page alignment. Its debug
APK is in `apps/gpui/android/app/build/outputs/apk/debug/`; `--release` produces
an unsigned release APK. The build does not install it automatically.

Use `RISH_GPUI_AGENT_CORE_DIR` to select a prepared agent-core dependency and
`RISH_GPUI_LIBGIT2_DIR` for an explicitly prepared Git dependency. Missing
required artifacts stop packaging. The GPUI Android host does not bundle the
experimental Linux guest or official CLI payloads by default.

Host unit checks can run independently of APK packaging:

```sh
apps/gpui/android/gradlew -p apps/gpui/android --no-daemon \
  compileDebugKotlin testDebugUnitTest
```

A compiled APK and successful unit tests do not establish renderer/device or
provider acceptance. Run the actual selected binary on the target device and
record its native artifact provenance when testing platform services.

## Session and native bridge rules

The shell reads schema 9 and 10 JSON and delegates validation to `rish-agent-core`.
It preserves Agent journals and extension fields. Writes include the native
generation, digest and operation ID; a conflict reloads authoritative state and
an uncertain write queries its outcome before another mutation or request.
Provider requests follow durable user-turn persistence. Do not add a parallel
UI-owned history store or rewrite active Agent conversations as basic chat.

Schema 10 adds the required `composer_drafts` object: stable editor keys map to
exact, nonempty unsent text. Empty drafts have no entry. Limits are 256 entries,
256 UTF-8 bytes per key, 1 MiB per draft and 4 MiB of text in total. Schema 9
continues to reject this field. Loading does not rewrite session bytes or their
digest; the first draft mutation upgrades through the existing generation/digest
CAS and v3 native envelope. Unknown versions fail closed without resetting data.
Older binaries cannot read schema 10; installing one over upgraded data is not a
supported downgrade. Both native Rust archives must be rebuilt with the new
reader before deploying the shell that writes schema 10.

Native services own credentials, storage, authority checks and provider calls.
The bridge accepts only the reviewed exported operations, bounds outstanding
requests/events and copies borrowed data before asynchronous delivery. Never
log credentials, session text, private paths or raw provider response bodies in
generic error notices.

```sh
python3 apps/gpui/ios/generate-exports.py --check
apps/gpui/ios/check-bridge.sh
(cd modules/rish/core && cargo test --locked --workspace)
```

Run the core suite with its pinned toolchain. Regenerate `Sources/Exports.inc`
without `--check` only when intentionally changing an export, then review the
diff. The iOS bridge checker covers dispatch and validation with fixtures; the
retained iOS service tests are source assets, not a claim that the GPUI scheme
currently runs the entire former app XCTest suite.

## Input and layout

Phone message input uses the native `ShellInput.edit` editor for marked-text
composition, selection and keyboard handling. Workspace creation and
conversation renaming use `ShellInput.name`, a compact single-line form with
localized hints, explicit theme and validation. Cancellation preserves the
draft. Never truncate or normalize a field while IME composition is active.

Compact windows use a drawer; wide regular windows use a persistent sidebar.
Layout reads actual window safe-area insets and size classes. Preserve the
composer and transcript entities across resizing. Adaptive phone/tablet layouts
do not establish foldable-device pose or reserved-region acceptance.

## Honest runtime boundary

Basic native text chat is implemented. Full Agent controller/tool parity,
attachments, complete settings and task Live Activity integration are still
incomplete in the GPUI app. The existence of an export, native service or tool
registry entry does not prove that its UI workflow is reachable and correct.
Model inference uses configured remote services; local workspaces are not
an offline inference promise. Guest and official-CLI capabilities depend on
prepared assets, platform restrictions and explicit build configuration.

The development bundle ID is `tech.zseven.rish.gpui`; it has a separate container
and does not automatically migrate data or credentials from older installations.
Removal of old source does not delete installed applications or their data.

For acceptance, distinguish state tests, compilation, linked packaging, actual
simulator/device interaction, and end-to-end provider/runtime workflows. Record
the tested source revision, binary, platform, artifact inputs and observed
results. Include Chinese/Japanese composition, emoji, keyboard avoidance,
rotation, long transcripts, cancellation, restart recovery, concurrent writes
and uncertain commit recovery where relevant. Do not promote historical app
results or a passing compile check into GPUI feature or release acceptance.
