# GPUI migration status

[`apps/gpui`](../apps/gpui/README.md) is the active application. The React Native
application and its build pipeline have been removed. Native platform services
remain responsible for credential storage, network and filesystem effects,
Git transport and runtime execution. Shared Rust rules and reducers decide the
business behavior around those effects. Removing the old UI does not mean
every old feature has been ported or accepted in the new shell.

## Dependencies and source layout

| Source | Used here | Boundary |
| --- | --- | --- |
| [GPUI Mobile](https://github.com/itsbalamurali/gpui-mobile/tree/5abbefa5f753ee9a1920d6d2eaeede981e79eeff) | UIKit/wgpu-Metal and Android NativeActivity/wgpu backends | Pinned revision from upstream PR #49; native editors compensate for incomplete mobile text-composition support |
| [GPUI Fast](https://github.com/longbridge/gpui-fast) | Published `gpui-fast` / `gpui-fast-platform` `0.1.7` for the macOS preview | Does not provide the mobile renderer or establish measured mobile speedups |
| Rish native services | Objective-C/Objective-C++, Kotlin/JNI, shared Rust validation and reducers | A bridge export alone does not establish UI reachability, provider acceptance or feature parity |

The mobile pin is `5abbefa5f753ee9a1920d6d2eaeede981e79eeff`, the reviewed
[PR #49 revision](https://github.com/itsbalamurali/gpui-mobile/pull/49) selected for
its Metal display-handle fix. Mobile uses `gpui-pre` and `gpui-pre-wgpu` at
`0.3.6`, with `wgpu` at `29.0.4`. The mobile manifest patches `gpui-pre-wgpu`
to the recorded local vendor copy to disable Android shader debug metadata;
its source provenance and patch scope are in `apps/gpui/vendor/gpui-pre-wgpu`.
Desktop and mobile maintain
separate manifests and lockfiles but compile the same shared UI source tree.
Their platform APIs differ; a future unified backend needs a deliberate port
and regression checks, not just a dependency source override.

The retained native sources now live under `modules/rish/ios` and
`modules/rish/android`. iOS app resources live under `apps/gpui/ios/Resources`;
shared guest resources live under `modules/rish/shared/GuestAssets`. Native
module declarations are under `apps/gpui/ios/Native/RishNative`. These services
are compiled directly by the GPUI hosts, without a JavaScript UI runtime.
The assistant's separate embedded Pi interpreter does not render the interface.

## Implemented interface and controller

- Shared GPUI conversation UI, Lucide icons, light/dark themes, and English/Chinese strings.
- Compact left drawer and regular wide-window sidebar, preserving composer and transcript entities across layout changes.
- Conversation-owned Files/Git views, in a compact right sidebar on wide windows
  and a modal bottom sheet on phones. A focused workspace mode provides directory/document or
  changes/diff splits. Settings reflows into two columns at sufficient content width.
- Each conversation stores a native workspace binding in the existing session
  schema. Native hosts provision and remember a default workspace; unbound old
  conversations migrate through CAS. Existing bindings and historical attempts
  are preserved. A binding alone does not grant model filesystem access.
- Imagegen visual references and exact prompts live in
  `apps/gpui/design/2026-10-15`; the workspace sidebar board and annotated-review
  notes supersede the earlier global navigation explorations.
  The assistant/settings visual direction is now
  [`local-assistant-v2`](../apps/gpui/design/2026-10-28/local-assistant-v2.png), with its
  [recorded prompt](../apps/gpui/design/2026-10-28/local-assistant-v2-prompt.md).
  The bundled avatar is the generated bitmap recorded in
  `apps/gpui/assets/brand`; the app uses the existing Lucide assets, real saved
  task state and native controls. Users can rename the assistant, choose a
  private photo through the system picker, or restore the bundled avatar.
- Settings separates actual catalog models, the assistant Runtime Engine and
  service accounts. New assistant runs default to embedded Pi Agent Core;
  custom JavaScript hooks extend Pi independently of model/provider selection.
  DSH, Claude Code, Codex and zcode are runtime entries with their original
  logos and separate native installation/execution state. API account rows
  instead name DeepSeek, Anthropic, OpenAI and Z.AI. Unimplemented CLI backends
  remain unavailable even after an artifact has downloaded.
- Bottom configuration card with model and reasoning rows; local draft changes are applied together only after Done.
- Basic native text-chat requests, saved conversation state, cancellation and persistence recovery handling.
- Native multiline message input embedded in the composer, with IME-preserving
  layout sync, keyboard intersection handling and versioned snapshots. Naming,
  file editing and Git forms remain separate native forms.
- Git lookup treats the native `status: none` response as a normal empty state.
  Initialization requires a user action and read/write/git capabilities; real
  lookup or status failures remain distinct and can be retried.
- Git actions include stage all, commit with explicit author details, unstaged/staged
  diff, origin configuration, native credential entry, fetch, fast-forward pull,
  and normal push. Pull refuses a dirty or diverged checkout. Ambiguous push
  results block resending until the captured origin and remote state are checked;
  a receipt alone is not treated as proof of the current remote branch tip.
  Remote forms currently accept HTTPS and supported local-network HTTP URLs.
- A mobile **Local assistant** page for explicit long-term notes, saved tasks,
  workspace/model selection, manual runs and optional follow-up intervals.
  Wide windows use list/detail columns; phones navigate one pane at a time.
  A process-owned Rust runner reuses the Agent controller and native journal,
  with exclusive session-writer handoff from the UI. See the
  [assistant contract](mobile-assistant.md) for scheduling and background limits.
- The assistant now opens a dedicated personal conversation, with tasks and
  local memories in a secondary phone panel or iPad right column. Registry 5
  exposes six scoped task/memory tools through the existing approval, WAL and
  effect path. Soul and structured memories persist in the shared Rust store;
  private metadata writes do not grant workspace file writes. See the assistant
  contract for authority, replay and memory limits.
- Runtime rows expose existing native subscription authorization and explicit
  source selection where the host supports them. Login, plan readiness, package
  download and CLI execution capability remain independent states.
- **Settings → API providers → Add custom provider** creates independent named
  services with their own endpoint, protocol, authentication and model list.
  Chat Completions, Responses and Anthropic Messages share the existing native
  transport codecs. Credentials stay in the native secure store; an explicit
  no-key configuration sends no authentication header. Custom models have
  provider-specific logical identities, so identical upstream names cannot
  collide with each other or built-in models. Retired identities remain readable
  in history and are unavailable for new requests rather than redirected.
  Custom providers may start with no models, then fetch their own model list or
  accept manually entered IDs. Discovery is explicit, bounded and cancellable;
  selected results merge into a draft without replacing manual choices.

The naming form returns committed, validated text; it does not itself create a
workspace or mutate a conversation. Existing native creation and session CAS
operations still perform those changes. The reasoning setting is not presented
as a provider speed tier that the runtime does not implement.

## Runtime and persistence contract

The bridge sends named asynchronous JSON operations with bounded request/event
buffers. Request IDs route replies, and native credentials remain outside the
Rust UI. iOS dispatch uses a reviewed export registry with argument/signature
validation; Android routes to retained Kotlin services and JNI reducers.

`rish-shell-core` retains schema 9 session JSON and delegates validation to
`rish-agent-core`. It preserves Agent journals and extension fields. Writes
carry generation, digest and operation ID. Conflicts require an authoritative
reload; uncertain writes query their outcome before retrying or issuing another
provider request. User turns must be durably stored before provider execution.
There is no second UI-owned conversation store.

The shared Agent controller now drives native prepare, provider rounds, frozen
tool batches, one-time approvals, execution, cancellation, reconciliation and
terminal cleanup. Each effect follows its confirmed session checkpoint;
unknown commits and ambiguous effects cannot trigger automatic replay.
Registry v4 adds durable structured questions to the same execution ledger.
GPUI only renders the shared projection and returns the user's explicit
decision, bound to the original approval or question identity.

Native `agentRoundPreview` events are consumed as ephemeral display data with
round/operation/provider correlation and sequence checks. Saved round text is
loaded through `read_agent_round_presentations` on both mobile platforms,
checked against durable round identities and content digests, and kept in a
bounded display cache. Neither path supplies execution authority.

## Shared business logic

`modules/rish/core` is the platform-independent business core. The GPUI
`rish-shell-core` uses it directly; iOS uses its C ABI and Android its JNI ABI.
New pure validation and state transitions belong in these existing crates,
with native code executing effects and reporting their results.

Completed consolidations remove duplicate rules from both native hosts:

- `rish-agent-core::name_policy` owns completed-input trim/NFC normalization,
  workspace name rules, conversation title validation and automatic titles.
  Titles use the same 120 UTF-8 byte bound as the persisted session schema;
  deriving a title never truncates the message body. Both native name forms,
  default-workspace name checks and the Rust conversation controller call it.
- `rish-agent-core::git_remote_policy` owns HTTP(S)/SSH/SCP parsing, host and
  path acceptance, port validation, and remote identity. The remote form adds
  shared trim and its input-size limit. Both platforms call the same policy;
  their available transports still determine what they can execute. The
  shared fixture covers both platforms' prior cases and divergence regressions.
- `rish-agent-core::model_catalog` owns model validation, default entries,
  active/retired merging, stable retirement order, image capability and model
  ownership lookup. Retired identities remain usable by old conversations.
  Stored labels accepted by older Android builds keep their original Unicode
  text; new labels use the shared validation rule. Missing storage alone selects
  defaults, and malformed storage is never silently rewritten.
- `rish-agent-core::provider_policy` owns configuration fields, defaults,
  credential slots, endpoint safety/suffix decisions, binding validation and
  profile/account digests. Native hosts supply URL-parser facts and serialize
  the resulting plan with Foundation or OkHttp. The explicit codec preserves
  their historical escaping and repeated-suffix behavior; replacing this with
  a different URL normalizer could disconnect existing credential accounts.
  Identity hashes retain their original domain and field sets. Android's older
  `JSONObject.quote` credential lookup remains a compatibility adapter.
- `rish-agent-core::round_presentation` owns saved-round identity and schema
  validation, digest checks, upsert ordering and projection from native-validated
  WAL entries. Both hosts call the same reducer. Native adapters retain bounded,
  no-follow reads, atomic writes and cache retention; the shell additionally
  checks durable session/round correlation and its display budget. Presentation
  text remains a display cache, never provider history or execution authority.
- `rish-shell-core::assistant_store` owns local task/profile validation,
  revision checks, durable run claims and interval eligibility. The shared
  `assistant_runtime` owns execution, recovery and session-writer handoff.
  Native adapters supply the private storage root, app lifecycle, notifications
  and actual OS background admission; they do not duplicate the task scheduler.
- Native code retains strict string conversion and ABI response checking.
  A missing Rust library fails closed rather than activating a second policy.
  Name fields do not normalize an IME's unfinished marked text.

Provider read failures must not become an absent/official binding. iOS refuses
misfiled configurations and refuses ordinary saves over a corrupt preference
root. Android resolves the provider before capturing/writing a context snapshot;
lookup failure also invalidates a prior snapshot instead of treating two null
bindings as a match. These paths leave the stored configuration intact.

The remaining duplication should migrate in separate, compatible steps:

| Next area | Move into Rust | Keep in native adapters |
| --- | --- | --- |
| Provider response metadata | Reported-model/response-ID rules and remaining provider metadata | HTTP, UUID generation and existing account compatibility |
| Input/form protocol | Exact DTOs, limits, field issues, revision decisions | UITextView/EditText, IME buffers, main-thread mutations, keyboard geometry |
| Default workspace | Recovery reducer and effect ordering | Durable preferences, existing iOS/Android journal formats, filesystem effects |
| Git receipt/recovery | Receipt schema, retention and retry decisions | Git locks, descriptor-based file access, atomic writes, libgit2 callbacks |

Default-workspace journals and provider credential identities must be imported
without resetting user state. Existing Rust agent, session, WAL, tool-policy
and provider-stream reducers should be reused, not wrapped in another parallel
business implementation. Native source size alone does not measure duplication.

The shared catalog/provider fixture files exercise the same Rust ABI from both
hosts. `apps/gpui/ios/check-provider-policy.sh` additionally compares actual old
Foundation URL/binding/account baselines and uses a private preference suite.
Android instrumentation assets contain the shared fixtures; they are excluded
from the production APK. Compilation of those tests does not establish Android
device execution.

The development identifier `tech.zseven.rish.gpui` has independent app data and
credentials from older installations. The source cleanup performs no automatic
migration or deletion of installed applications and their data.

## Native host decisions

**File editing:** The GPUI file browser exposes native `writeV2` and
`createDirectoryV2` using the current workspace binding and write capability.
Updates retain the original read revision; new files use `create_only` with no
expected revision. Name/editor replies are bound to the originating workspace,
folder and view generation. A stale reply does not initiate a write. Failed
saves preserve an in-memory draft; there is no automatic overwrite or retry
after an uncertain result. The native text editor supports complete UTF-8 text
up to 256 KiB. Manual file editing and Agent tool execution keep their respective
native revision, authorization and receipt checks.

**iOS:** The host keeps GPUI alive around UIKit's blocking application loop and
drives frames from the application delegate. Rust produces a static library;
the native request callback is resolved when Xcode links the app. VM, agent-core
and Git XCFrameworks come from explicit preparation scripts with their existing
source/toolchain checks. Missing or stale required artifacts stop the build.

**Android:** The host retains GPUI Mobile's Java namespace for its JNI exports
and uses Rish's own application identifier. Packaging requires ARM64 GPUI and
agent-core libraries; prepared Git artifacts enable the native Git dependency.
The build uses NDK 27.1.12297006 and 16 KiB native-library alignment. Guest and
official CLI payloads are not bundled by default.

**Text entry:** `ShellInput.inlineSync` embeds native message editing in the
GPUI composer for composition, selection and keyboard handling;
`ShellInput.edit` remains only for legacy callers. `ShellInput.name` uses a
themed single-line form with localized hints and shared Rust validation.
Neither path commits incomplete IME composition. Cancellation preserves the draft. The desktop input translates
UTF-16 ranges and handles grapheme-aware deletion.

**Adaptive layout:** Size classes and actual safe-area edges drive layout,
without inferring dimensions from device model names. This supports ordinary
window resizing and phone/tablet layout work; it does not establish foldable
pose, reserved-region or iPhone Duo device acceptance.

## Remaining work and acceptance

Attachments, complete settings and task Live Activity integration remain
incomplete. Legacy text-chat attempts retain their separate recovery path;
they must not rewrite active Agent journals. Agent acceptance requires the
shared controller to run against native session storage, WAL, provider parsing
and tool execution, in addition to layout and state-machine tests.

The local assistant is implemented in shared Rust and both native hosts, but its
acceptance must distinguish store/runner tests, native adapter tests and a linked
app workflow. Notes and scheduling state are stored on the phone; inference uses
the configured provider. Intervals are foreground execution eligibility, not
guaranteed background wakeups. Manual runs may request iOS 26 continued
processing or an Android foreground service after opt-in, subject to OS
admission and expiration. There is no cloud runner, offline-inference guarantee,
system-wide overlay or control of arbitrary other apps. Existing Guest/CLI
runtime repairs require their own end-to-end evidence.

The desktop preview has no mobile runtime. Provider/account, file/Git,
authorization, background execution, Guest and official-CLI workflows need
validation against the features actually enabled by the tested native build.
Historical verification of the removed app is not GPUI acceptance.

Use the [developer guide](development.md) and
[GPUI host guide](../apps/gpui/README.md) for current checks and builds. The
[`gpui.yml`](../.github/workflows/gpui.yml) workflow is the GPUI check entry point;
it is not a distribution workflow. The old TestFlight pipeline is retired and
a GPUI release pipeline is still pending. No signing, upload, store-processing
or full mobile-parity claim follows from this migration.

Record evidence at the level actually exercised:

1. Shell/core tests validate transitions, validation and recovery rules.
2. Rust and native compilation validate the selected integration surface.
3. A linked app or APK validates packaging of its recorded artifact inputs.
4. Simulator/device interaction validates rendering, input, layout and lifecycle.
5. End-to-end workflows validate provider calls, native effects, approvals and recovery.

For device acceptance, include Chinese/Japanese composition and emoji,
keyboard avoidance, rotation, long transcripts, restart recovery, simultaneous
native updates, uncertain writes, and provider cancellation/retry. Identify the
source revision, binary, device and prepared native archives. A compile check,
a screenshot, and a complete workflow are different forms of evidence.
