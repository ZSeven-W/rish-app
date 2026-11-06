# Rish GPUI shell

The active application lives here. It shares a view/controller source tree
between macOS, iOS, and Android, while calling native platform services through
a JSON bridge. The previous React Native application has been removed.
Development mobile apps use `tech.zseven.rish.gpui`, with a separate data
container from previously installed apps.

Mobile conversations use the shared Rust Agent controller for provider rounds,
tool execution, approvals, structured questions, cancellation and recovery.
The mobile local assistant adds saved responsibilities, explicit user notes and
follow-up eligibility on top of that same controller. Attachments, complete
settings and task Live Activity integration remain incomplete. A successful desktop preview or `cargo check` does not establish
mobile feature parity. See the
[migration and verification boundary](../../docs/gpui-migration.md).
Next milestones and the fini handoff are in the [Mobile Agent roadmap](../../ROADMAP.md).

## Source layout

| Location | Responsibility |
| --- | --- |
| `src/ui` | Shared GPUI views, transcript rendering, desktop text input, theme and strings |
| `src/runtime` | Bounded asynchronous requests/events between Rust and native services |
| `src/assistant_runtime` | Process-owned local assistant runner and exclusive session-writer handoff |
| `crates/rish-shell-core` | Session editing, durable Agent orchestration, recovery and display projections without a UI dependency |
| `crates/rish-pi-runtime` | Embedded Pi Agent Core in QuickJS, versioned runtime definitions and bounded custom script hooks |
| `Cargo.toml` | macOS preview using published GPUI Fast `0.1.7` |
| `mobile/Cargo.toml` | The same Rust sources using pinned GPUI Mobile and matching `gpui-pre` core |
| `ios` | UIKit entry point, native input, and adapters for existing Objective-C services |
| `android` | NativeActivity, native input, and adapters for existing Kotlin services |
| `scripts` | Checks and development builds; never upload or install automatically |

The desktop preview does not provide the phone's model, secure-storage, Git, or
VM services. It reports their absence instead of displaying simulated results.

The model picker has no bundled choices. DeepSeek, Anthropic, OpenAI and Z.AI
each keep their own saved model catalog under **Settings → API providers**;
fetch the provider's models or enter an exact upstream model ID manually.
Cached and manually entered models remain available after a failed fetch.
Providers without a model-list API use manual entry. Subscription-discovered
models remain tied to that subscription source, separate from API-key catalogs.
A fresh install starts without a default model. Empty conversations and drafts
can be saved before setup; sending opens model setup or selection until a
configured model is chosen. Existing conversations keep their saved IDs, even
when a model is removed from active choices, and are never silently reassigned.

Both the default-model settings and conversation model picker offer **Add /
custom model**. In a conversation, provider setup opens inside the picker and
reuses the same provider editors. Returning preserves the unsent chat input and
the pending model/thinking choices; saving a catalog does not select a model.
If a pending choice was removed while editing the catalog, Done keeps the draft
open with an error until the user chooses an available model.

Custom API services can be added under **Settings → API providers**. Set the
name, API address and protocol, then save the provider and
optionally open its native secure-key prompt. Display aliases and image support
are configurable per model. The URL can be a base address or an explicit full
API endpoint; the saved normalized address is shown after confirmation. HTTPS
is supported, with HTTP reserved for loopback development. Authentication can
use Bearer, `x-api-key`, `api-key`, or explicit no-key mode.

You can save a provider before choosing any models. **Fetch models** explicitly
reads that provider's standard model-list endpoint; it never fetches just because
the page is opened. The returned choices can be filtered, selected and added to
the draft, then saved. Manual model entry remains available. Import is additive:
existing manual model names, image flags and logical IDs are retained, including
models not returned by the server. An unsupported or failed discovery does not
clear the draft or saved model list.

Discovery uses the [OpenAI model-list](https://developers.openai.com/api/reference/resources/models/methods/list)
and [Anthropic model-list](https://platform.claude.com/docs/en/api/models/list)
formats. It preserves the configured origin, refuses redirects, follows only a
validated model cursor, and is bounded to 512 choices, eight pages and a timeout.
Unknown nonstandard endpoint paths require manual entry. Cancellation is tied
to one request ID, so an old cancel cannot stop a newer fetch. Only explicit
server image-support metadata is imported; capability is never guessed from a
model's name. A catalog response does not establish successful inference.

Provider metadata and models save together with revision checks. Each provider
has its own credential identity, even when two use the same address and model.
Renaming keeps its key; changing endpoint/protocol/authentication uses a separate
credential scope instead of forwarding an old key to a new address. Clear Key
removes the currently selected scoped credential. Removing a provider retires
its metadata and model identities, preserving old conversation receipts. Existing
model selections are not silently changed and retired choices show unavailable.
Neither a successful save nor “key saved” is presented as a tested connection.

The shared `custom_provider_registry` and provider policy own validation,
identity, revision conflicts and retirement. Native hosts own URL serialization,
atomic storage, secure credentials and HTTP. Mutations refuse active requests
and durable unfinished attempts; responses retain the binding captured for their
request. Custom routing is separate from built-in API and subscription sources.

Mobile workspace files support creating folders and text files, plus editing
complete UTF-8 files up to 256 KiB through the native editor. Creation is
exclusive; updates use the revision captured when the file was read. Failed or
conflicting saves keep the draft in memory without retrying automatically. A
workspace without native write capability remains read-only. Drafts are not
persisted across app restarts; copying or discarding a conflicted draft is an
explicit user action.

The Git page distinguishes an unassociated workspace from loading and failures.
An eligible workspace offers an explicit **Initialize Git repository** action;
browsing never initializes it automatically. Existing associated repositories
load status through their validated workspace/project binding. The native
`mode: open` operation is not a repository picker or filesystem discovery API.

Compact windows use a left navigation drawer, opened from the header. The drawer
contains recent conversations, new chat, Local assistant and Settings; selecting an
item or clicking the backdrop closes it. Wide regular windows show the same
content as a persistent sidebar. Files and Git are tools inside the current
conversation, opened with the header workspace button. Wide windows use a
340–380 px right sidebar; phones use a high bottom sheet with the chat and its
draft still mounted underneath. Expanding the workspace gives files a directory
and document split, or Git a changes and diff split. The composer and transcript
remain the same entities when the window changes size. Workspace selection sits
at the left of the composer footer, with model and reasoning controls beside
Send on the right. Narrow phones use a compact single-row toolbar. The compact right file inspector keeps its directory above a selected
preview when height permits.

The mobile composer edits in place through a native UITextView/EditText overlay;
it does not open a separate editor. Native composition and selection survive
layout updates. Keyboard overlap is measured in the viewport, and sending takes
a fresh input snapshot before a conditional native clear, preserving new typing.

The model control opens a compact bottom configuration card with Model and Thinking
rows and a Done button. Secondary selection pages use bounded, independently
scrolling options. Choices remain a local draft until Done submits one native
CAS write; dismissing the card discards them. The second row controls the
existing reasoning setting, not a synthetic provider speed tier. Opening the
card does not reflow the underlying conversation or composer.

## Prerequisites

- Rust 1.95.0 with `rustfmt`; the existing native dependency preparation scripts
  retain their own pinned Rust toolchain.
- macOS preview: an Apple Silicon Mac with Xcode and its command-line tools.
- iOS: the iOS device/simulator Rust targets, Xcode, XcodeGen, and the prepared
  native dependencies described below. The GPUI host targets iOS 16 or newer.
- Android: JDK 17, SDK platform 36, build-tools 36.0.0, NDK 27.1.12297006,
  CMake 3.22.1, `cargo-ndk`, and the `aarch64-linux-android` Rust target.

Run all following commands from the repository root. Build scripts use the two
committed Cargo lockfiles. They report missing tools and native artifacts;
dependency preparation is explicit.

## Check and preview

```sh
apps/gpui/scripts/check.sh core
apps/gpui/scripts/check.sh desktop
apps/gpui/scripts/build-desktop.sh --run
```

`core` checks formatting and runs the shell's persistence/state tests. `desktop`
checks all desktop Rust targets. Library tests, including input and bridge
regressions, can be executed with:

```sh
cargo test --locked --manifest-path apps/gpui/Cargo.toml --lib
```

## iOS

Rust and bridge compilation can be checked without building the full VM:

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
apps/gpui/scripts/check.sh ios
```

To link the app, first follow the exact toolchain prerequisites in the existing
[developer guide](../../docs/development.md#ios-build-prerequisites), then
prepare the native dependencies:

```sh
scripts/prepare-rish-ios.sh
scripts/prepare-rish-agent-core.sh
scripts/prepare-libgit2-ios.sh
apps/gpui/scripts/build-ios.sh --simulator
```

These prepare `rish_ffi`, `rish_agent_core`, `libgit2`, `libssh2`, and `libcrypto`
XCFrameworks plus `rish.h` in the `modules/rish/ios` directory. The GPUI script
compiles `mobile/target/<target>/<profile>/librish_gpui.a` with
`cargo rustc --crate-type staticlib`, generates the
`RishGPUI` Xcode project, and produces an ad-hoc signed simulator `.app` in
`apps/gpui/build/ios-simulator/Build/Products/Debug-iphonesimulator/`.
The simulator signature enables local Keychain storage for Git credentials;
it does not require a developer account or provisioning profile.

iOS builds only the static library: its native host supplies the bridge request
symbol when Xcode links the app. The mobile manifest also declares a `cdylib`
for Android, but that dynamic artifact is not an iOS build output.

An explicitly prepared development archive set can be selected with
`RISH_GPUI_NATIVE_VENDOR` and `RISH_GPUI_NATIVE_INCLUDE`. The same existence and
current agent-core header checks apply. Keep its source versions, archive hashes
and toolchain provenance with that set; using an override does not establish a
release build with the canonical preparation toolchains.

Use `--device` for an unsigned device build and `--release` for optimization.
An unsigned device build cannot be installed on a physical iPhone; configure
your own signing in Xcode for that step. No TestFlight/export/upload path is
added by this rewrite.

## Android

```sh
rustup target add aarch64-linux-android
cargo install cargo-ndk --locked --version 4.1.2
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/27.1.12297006"
apps/gpui/scripts/check.sh android
```

Prepare the existing agent core using that script's pinned Rust toolchain,
then package the arm64 APK:

```sh
scripts/prepare-rish-agent-core-android.sh
apps/gpui/scripts/build-android.sh
```

The script copies the GPUI native library to `android/app/src/main/jniLibs` and
runs the checked-in Gradle wrapper. The APK is under
`apps/gpui/android/app/build/outputs/apk/debug/`. `--release` produces an unsigned
release APK. Override the prepared core location with
`RISH_GPUI_AGENT_CORE_DIR`; optionally set `RISH_GPUI_LIBGIT2_DIR` for a prepared
Git dependency directory. Missing runtime artifacts stop packaging.

Android platform services and native dependencies live under
`modules/rish/android`; the host does not bundle the experimental Linux
Guest or official CLI payloads. Availability is determined by native
capabilities, not by the presence of a tab or button.

On the isolated API 33 phone emulator, use emulator `-gpu host`. The default
Android startup detects the exact known-corrupt SwiftShader Vulkan adapter and
uses GLES only after a surface-free GL device probe passes. Other Vulkan
adapters and explicit `WGPU_BACKEND` / `ZED_DEVICE_ID` overrides are preserved.
This is a compatibility workaround; explicitly selecting SwiftShader Vulkan
still reproduces corruption. A backend choice must precede surface creation:
Vulkan can claim the native window even if its adapter is never selected.
After building/installing the app and test APK on a fresh portrait phone in
light mode, run the default-backend pixel and background/resume regression with:

```sh
adb shell am instrument -w -r \
  -e class tech.zseven.rish.gpui.ModelPickerRendererTest \
  tech.zseven.rish.gpui.test/androidx.test.runner.AndroidJUnitRunner
```

The test checks four window detach/reattach cycles, readiness, the opaque panel
and retained title glyphs. Add `-e backend gl` or `-e backend vulkan` to test an
explicit backend; the prior environment is restored afterward. It never sends
a message; screenshots are saved in the target app's cache.

On an isolated Pixel XL fixture (1440×2560, 560 dpi), the opt-in
`ModelDraftAcceptanceTest` uses real touches and native keyboard input to save a
synthetic manual model, choose it and retain an unsent draft. Run the methods
separately, with an external process stop between preparation and restoration:

```sh
adb shell am instrument -w -r -e modelDraftQa true -e backend auto \
  -e manual 700,1375 -e save 700,2006 \
  -e class tech.zseven.rish.gpui.ModelDraftAcceptanceTest#prepareModelAndDraft \
  tech.zseven.rish.gpui.test/androidx.test.runner.AndroidJUnitRunner
adb shell am force-stop tech.zseven.rish.gpui
adb shell pidof tech.zseven.rish.gpui # Must be empty before the next invocation.
adb shell am instrument -w -r -e modelDraftQa true -e backend auto \
  -e class tech.zseven.rish.gpui.ModelDraftAcceptanceTest#restoreAfterProcessRestart \
  tech.zseven.rish.gpui.test/androidx.test.runner.AndroidJUnitRunner
```

The test refuses an existing draft or synthetic model. It reads the native
catalog/session authority to verify the UI result and checks the new launch ID,
unchanged persisted digest/generation, selected model and actual native text.
No credentials, model discovery or sends are involved.

## Input and persistence

On phones, `ShellInput.inlineSync` keeps UIKit/Android text editing inside the
composer, including Chinese/Japanese composition, selection and keyboard
avoidance. Sending or answering a question first reads a correlated native
snapshot; incomplete IME composition is never submitted.
Workspace creation and conversation renaming use `ShellInput.name`, a compact
single-line form with explicit theme, localized hints and validation before
submission. Cancellation leaves the current state unchanged.
The GPUI macOS input uses UTF-16 ranges and grapheme-aware editing.

Session state uses schema 9/10 JSON validated by the existing Rust agent core.
Writes use native generation/digest compare-and-swap and operation IDs.
Conflicts and uncertain writes are resolved before subsequent mutations or
provider requests; there is no second local history store in the shell.
Loading schema 9 preserves its bytes and digest. The first saved composer draft
upgrades to schema 10 through the same CAS; schema 10 requires a bounded
`composer_drafts` map. Older binaries cannot reopen upgraded snapshots, and
unknown versions are refused without replacing stored data. Native core archives
must be rebuilt with the matching reader; see the
[session contract](../../docs/development.md#session-and-native-bridge-rules).
Ordinary chat and personal-assistant input drafts share this snapshot. Native
input observations are coalesced into the current writer; the UI shows waiting,
saving or failed status until the matching receipt arrives. While a task owns
the writer or input is composing, the latest text can still be pending in memory;
keep the app open until that status clears. Confirmed user-turn and question
answer checkpoints consume only their corresponding draft. Group drafts remain
process-only because group submissions belong to BotStore; the composer labels
that limit explicitly. Model-editor changes and conversation switching retain
ordinary drafts independently. A conflicting saved draft requires an explicit
choice; refused oversized input is kept and cannot be silently left behind.

The development bundle ID does not migrate data or credentials from older
installations. Removing the old source does not delete installed app data.

## Agent execution

Optional CLI downloads are separate from executable engines. The iOS runtime
list supports cancelling a download and explicitly retrying; cancelled or old
transfer callbacks cannot publish a newer attempt. Verified payloads still show
**Tasks unavailable** until a real execution adapter is implemented and probed.
See [runtime installation evidence and platform gaps](../../docs/runtime-engine-installation.md).

Each provider round, approval and tool execution is gated by its committed
session checkpoint. Native services retain authority over workspace bindings,
policy, execution receipts and the transcript WAL. The GPUI view dispatches
commands from `rish-shell-core`; it does not execute model tool arguments.
Uncertain results remain recoverable until the native journal resolves them.
Stopping a task persists cancellation before requesting native cancellation.

Approval cards show the native safe preview and only actions offered by the
current approval token. Registry v4 adds `ask_user` for explicit option or text
answers. Answering and skipping use the existing durable tool receipt path;
the app never invents an answer when the user dismisses or restarts it.

Live previews are display-only and correlated to the exact attempt, round,
operation and provider request. Missing events are marked incomplete. Saved
round presentations are separately validated and bounded; they never authorize
execution or become provider history. Unsupported platform tools remain absent
from the native capability registry, including Android's unbundled guest VM.

The [native Agent contract harness](../../scripts/native-tests/shell-agent-harness/README.md)
drives this exact shared controller against an isolated iOS native session
store, WAL, file executor and loopback provider. Its gate requires every selected
scenario to execute and pass; a build, skip or missing case is not acceptance.

## Local assistant on mobile

Open **Local assistant / 本机助手** from the drawer or sidebar to edit the
assistant's name and long-term notes, create a task, select its workspace and
configured model, and run it. Tasks begin in manual mode. An optional follow-up
interval of at least 15 minutes makes a task eligible for another run when Rish
is able to execute and has an idle foreground session. The app checks for due
tasks every 30 seconds while its UI is running; it does not register an exact
background alarm or promise execution while the app is suspended.

Tap the avatar for name/photo editing or to restore the default mark. Photo
selection is explicit, and bounded PNGs stay in app-private storage. Profile
writes retain the existing revision and conflict checks; avatars are never
included in Agent model context.

Task definitions, notes and run identities are saved in app-private storage by
Rust. Long-term notes are explicit user text, and are sent to the selected model
as task context; they do not grant additional tool permissions. The model uses
the existing native provider configuration and credentials. Local execution
does not mean offline inference, and no desktop or cloud task runner is added.

The process-owned runner uses the existing Agent approval, question, Stop and
recovery flows. It saves a run claim before creating a turn, holds the only
session-writer lease while active, and reconciles interrupted work against the
native journal before another run. The task page uses list/detail columns on
wide windows and one pane at a time on phones.

**Continue in background** and **Task notifications** are separate, explicit
opt-ins. Eligible manual starts can request iOS 26 continued processing or an
Android foreground service. The OS can reject or end that allowance; a submitted
request is not an accepted grant. Scheduled follow-ups do not request this
allowance, and leaving the foreground without it starts cancellation and
checkpoint handling. Forced termination may prevent a final callback, so the
next launch must reconcile the saved run. Widgets and Live Activities are not
included in the GPUI target.

See [mobile assistant architecture and verification](../../docs/mobile-assistant.md)
for the persistence, scheduling and platform boundaries.
