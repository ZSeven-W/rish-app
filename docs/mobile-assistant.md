# Mobile local assistant

Rish's local assistant keeps responsibilities, explicit user notes and run state
on the phone, and executes through the existing mobile Agent. It does not need a
desktop runner. The selected model still uses its configured provider and native
credentials, so this is not an offline-inference feature.

The product reference is the ongoing responsibilities and memory described in
[Codex Dots](https://learn.chatgpt.com/docs/dots). Official Dots run in the cloud;
this implementation runs within Rish's mobile process and the operating system's
execution limits. It is not a Codex service integration.

## Using the assistant

Open **Bot** in the drawer or left sidebar to choose a Bot
or a group. The original assistant remains the default Bot, retaining its name,
avatar, Soul, notes, memories, tasks and conversation. Additional Bots have their
own profile, memory and tasks. Their private conversations have stable IDs in the
private assistant store and normal native workspace bindings. They do not reuse
whichever coding conversation happened to be active. The same inline input,
Agent controller, approvals and recovery are used for personal chat.

**Tasks / Memory** is a secondary panel: beside chat when the available content
width is at least 720 pixels, or a separate dismissible pane on phones. Existing
task forms and run controls remain available there. Each saved task still has
its own associated conversation; **Open conversation** becomes available after
that conversation exists in the saved session. Short screens keep details and
decisions scrollable. While the task runner owns another conversation's writer,
the personal pane shows that work explicitly instead of displaying its messages
or sending a personal draft into it.
The workspace can change before the first run. Afterwards, create a new task to
use another workspace, preserving the existing conversation's binding.

Tap the assistant avatar to open **Edit profile**. The same menu is available
from the Settings identity and the assistant's sidebar identity. It offers name
editing, an explicit system photo-picker action, and restoring the bundled
avatar. Cancelling the picker preserves the profile. Photo changes use the same
profile revision check as names and notes; an existing unsaved draft or a
concurrent profile change requires review before saving.

Native hosts normalize a selected image to a bounded PNG in the app's private
`avatars` directory. The profile stores only an ID, SHA-256, dimensions, MIME
type and byte length, with limits of 512 pixels per dimension and 2 MiB. It never
stores a picker URI or host file path. The shared loader checks the private file,
length, digest and PNG dimensions before GPUI decodes it in the background;
unavailable images fall back to the bundled avatar. Avatars are display-only and
are excluded from run snapshots and model context.

New tasks default to manual execution. **Run now** saves the request before
execution starts. A follow-up interval of at least 15 minutes can be selected
explicitly. Pausing a task stops future scheduled runs; **Stop** cancels the
current run through the Agent's cancellation protocol. Active or unresolved
runs cannot be replaced by another claim.
For an inactive task, **More → Delete task** opens an in-app confirmation. Deletion
removes the task and future follow-ups after the saved state confirms the change;
its associated conversation and messages remain available.

Long-term notes remain user-edited profile text, distinct from structured memory.
At the start of a saved-task run,
the current notes and instructions are frozen and included in the selected
model's task context. Editing notes later changes future runs, not the current
one. Notes do not grant tool permissions; native workspace capabilities,
approvals and policy still apply. Deleting a task definition does not erase its
conversation or previously recorded task text.

## Multiple Bots and group chats

The **+** menu in the Bot directory offers **New conversation / 新建会话**,
**New Bot / 新建 Bot** and **Start group / 发起群聊**. Ordinary conversations keep
using the existing Agent controller and workspace; they do not inherit a Bot's
private memory or task-management authority. The drawer's **New conversation**
entry remains available too. The page lists Bots and groups separately and filters
them by name. On a wide iPad, a selected Bot's profile and shortcuts appear in a
right detail pane; on a phone, selecting a row opens its conversation. A group
has a name and at least two Bot members. Select all members for
one response from each, or select a specific member for a directed response.
Replies run sequentially through the existing session writer; a Bot's answer
does not automatically start an unbounded exchange between Bots. Group messages
identify their actual speaker instead of presenting all replies as one assistant.

Each group member has a separate, immutable execution conversation. The group
shares its explicit message history with participants, without copying their
private chat transcripts. Each member retains its own Soul, runtime and
task/memory scope. Its memory tools can retrieve its own saved memories, so
relevant remembered information may inform its reply. A group uses its own
workspace binding; it does not inherit another private chat's workspace by
accident.

The private Rust store records the user message, selected participants and
stable execution IDs before sending. Confirmed replies are added to the group
only after their underlying session outcome is saved. A pending approval,
question, failure or unresolved result pauses progression. Stopping prevents
remaining members from starting and uses the normal Agent cancellation path
for the current member. Recovery reconciles recorded IDs instead of blindly
resending the user message.

Bot and group identifiers, membership and task ownership are stored with one
global revision and the existing atomic-write protocol. Native task and memory
tools resolve the owner from the committed execution conversation. A model
cannot select another Bot's memory by supplying its name or an extra argument.
Avatar imports remain display-only files, and late picker results cannot save
an image into a different Bot's profile.

The drawer header displays the person's own nickname. Tap it to edit; this is
independent of Bot names, is not included in model context and cannot be changed
by Bot tools. The drawer closes by tapping outside it or pressing Escape, without
a redundant close button in the identity row.

Creating or switching conversations keeps unsent input under its original
conversation or group identity. Navigation can wait for a short snapshot save,
catalog load or workspace read, then continue once. The latest pending navigation
wins, can be cancelled, and expires after 15 seconds if the operation remains
unresolved. Waiting does not resubmit messages or replay tools/Git/file writes.
Active Agent runs, unresolved save conflicts and unsaved file/profile edits still
need explicit handling. These states use contextual guidance rather than a
generic workspace error and a full-session reload button.

## Local memory and Soul

The avatar menu exposes **Soul**, profile notes and the memory panel. Soul is an
editable description of personality, tone and working style, independent of
the assistant name, avatar and runtime. Old profiles receive a default Soul;
existing notes and settings are retained. New saved-task runs freeze Soul along
with their other profile context; older saved runs retain their original empty
Soul rather than being rewritten.

Structured memories have a stable ID, title, full content, a preference/fact/
decision kind, timestamps and optional source conversation. They are stored in
the app-private Rust store and survive restart. Users can inspect, create, edit
and delete them. Editing uses revision checks; failed or conflicting saves keep
the draft, and retrying an uncertain creation reuses its ID.

The personal assistant can search, remember and forget through real tools. The
default guidance permits clearly stated lasting preferences and agreements,
asks before sensitive information, and does not infer unstated facts or retain
credentials. Explicit requests not to remember, to forget, or to use a stricter
memory policy take precedence. It searches before adding duplicate memories
and waits for a persistence receipt before claiming a save. Existing native
approval rules still apply to changes.

Memory search is local and bounded, returning full matching records rather than
pretending to provide semantic embeddings. The current limits are 256 memories,
8 KiB per content field, and at most 20 records/32 KiB per search result. Soul
and notes are each limited to 16 KiB. Stored memories are not all injected into
every request; relevant content is retrieved through the search tool. Profile
context and memories actually used in a turn are sent to the selected model
provider. Local storage does not mean offline model inference.

Forgetting removes the current memory record, not historical chat messages.
Mutation receipts retain IDs and hashes without copying the remembered content.
An exact replay after deletion returns its original receipt and cannot recreate
the memory.

## Assistant tools and authority

Registry 5 adds six tools only for registered personal and group-member
execution conversations:
`list_assistant_tasks`, `create_assistant_task`, `update_assistant_task`,
`search_assistant_memory`, `remember_assistant_memory`, and
`forget_assistant_memory`. Registry versions 1–4 retain their original tables.
Ordinary conversations cannot opt into these tools by changing a title, prompt,
or tool argument: native preparation and execution resolve the persisted private
conversation ID to its owning Bot. Task and memory IDs from another Bot are
rejected.

Task creation inherits model and workspace from the committed conversation.
Arguments cannot choose a private directory, authentication, runtime or profile.
New tasks are manual unless an interval is explicitly requested. Soul remains
a user-edited setting, not a model-editable tool target.

Private task/memory mutations use the separate `assistant_metadata` approval
family. A read-only workspace can still manage private assistant data after
approval, without granting file writes. Typed previews show the proposed title,
target and content, with omitted sensitive/long content identified. The native
ledger, approval and effect gate precede the Rust store mutation. Store revision
checks and the operation receipt are committed atomically; exact retries and
post-crash recovery read that receipt instead of repeating the effect. Unknown
outcomes remain unresolved. Receipt storage is bounded and fails safely when
full rather than discarding evidence needed for replay safety.

## Models, runtime engines and accounts

Settings keeps three independent controls:

- **Models** lists only saved provider models and models discovered through the
  selected subscription source. No bundled model list or fallback default is
  inserted. The default applies to new conversations and new assistant tasks;
  existing conversations and tasks retain their model.
- **Runtime Engine** selects the assistant execution engine. The default is
  embedded Pi Agent Core 1.4.0, running in QuickJS inside the mobile process.
  It does not require Node.js, the Pi CLI, or a desktop process.
- **Service accounts** configures DeepSeek, Anthropic, OpenAI and Z.AI API
  credentials. These labels describe model providers, not execution engines;
  the existing secure credential slots and GLM model identifiers are preserved.

Each API provider has a separate model editor. Fetching models uses that
provider's configured API-key credential; subscription tokens are not forwarded
to a generic model-list endpoint. Import is explicit and additive. Exact model
IDs, display names and image-support flags can also be entered manually when
discovery is unavailable. A failed fetch preserves the saved catalog and draft.
Removing an active model retires its identity for historical receipts and
recovery, without changing old conversations or tasks. New sends require a
currently configured model. An empty conversation can be saved with no model;
its draft remains intact while the UI opens setup or model selection.

DSH, Claude Code, Codex and zcode belong in the runtime engine list alongside
Pi, with their original logos. Their native installation state and execution
capability are separate. A downloaded CLI is not considered a usable assistant
engine until its actual task/session/approval/recovery adapter is available;
an unavailable CLI never silently runs through Pi or an API provider instead.
The current native optional download paths cover Claude Code and Codex on iOS.
DSH/zcode installation and complete CLI assistant backends are not implemented.
Android does not enable the optional CLI execution lane in the GPUI app.

Expand a runtime row to view its subscription account. Supported hosts expose
sign-in, native browser authorization, native code entry when required, cancel,
status refresh and sign-out. API-key configuration remains separate. iOS Codex
uses ChatGPT device authorization without requiring a CLI download; Claude
requires its downloaded CLI and guest prerequisites. zcode offers separate
BigModel/Z.AI account connection and an explicit paid-plan verification step.
Connecting an account is not proof that a plan is usable or that the optional
CLI assistant backend exists. DSH currently has no subscription adapter; Android
reports the actual unbundled CLI limitation and does not invent source selection.

The UI retains only bounded display status and temporary login identity/code,
not tokens or authorization URLs. Native code owns the official browser URL and
secret-code input. Status polling stops when hidden or backgrounded; stale
callbacks cannot switch another account. Codex login selects its subscription
source natively; other source changes are explicit. Switching back to API never
silently erases a saved key or changes the current conversation/model. Discovered
Codex model choices refresh without reloading or overwriting the saved session.

Tasks without a runtime override inherit the current profile engine when their
next run starts. Each claim freezes its engine definition, so changing the
default cannot change a run already in progress. Older saved runs without an
engine definition retain their explicit legacy recovery path.

The **Custom JavaScript** option adds synchronous `beforeModel` and `beforeTool`
policy hooks to Pi. Scripts can allow an operation or stop the run with a reason;
they do not replace the native provider/tool implementations. Scripts are bounded
to 32 KiB, stored with their hash and ABI/version, and evaluated in a fresh,
resource-limited realm without ambient filesystem, network or shell access.
Saving a script does not execute it. A hook failure stops execution without
falling back to a different engine. The
[runtime contract and example](../apps/gpui/crates/rish-pi-runtime/README.md)
describe the precise supported ABI.

Pi schedules model and tool intents; the existing native controller still
validates workspace authority, approvals, committed receipts and recovery.
Restoring Pi consumes committed evidence without replaying host effects.

## Scheduling and background execution

An interval is an eligibility time, not a delivery promise. While the UI is
running, it asks the runner to check due tasks every 30 seconds. A new run needs
an idle, loaded foreground session and a session-writer handoff. Due work waits
when the app cannot execute, the runner is active, or the UI still owns an
in-flight operation or unfinished input. A task with an unresolved saved run
cannot claim another run of that task. The implementation does not register
WorkManager periodic jobs, iOS background refresh jobs or exact alarms.

The next interval is anchored after a run finishes; missed intervals do not
create a catch-up burst. A recorded wall-clock high-water mark prevents clock
rollback from making previously elapsed work eligible again. A running or
attention-needed claim has no automatic expiry that would authorize replay.

**Continue in background** and **Task notifications** default to off and are
separate controls. Notification permission is requested only from the explicit
notification action. Background opt-in allows an eligible manual run started in
the foreground to request continued execution:

| Platform | Implemented allowance | Limits |
| --- | --- | --- |
| iOS 26 and later | `BGContinuedProcessingTaskRequest` with `.fail` strategy | OS admission can fail; submitted and accepted are distinct states. Earlier supported iOS versions have no continued-processing allowance. |
| Android | A `dataSync` foreground service with a task notification and Stop action | OS start restrictions, time limits, user stops and process termination still apply. The service is not sticky. |

Scheduled follow-up runs do not request this allowance. Leaving the foreground
without admission, or losing an existing allowance, sends a cancellation event
to the runner and begins checkpoint/cleanup handling. iOS uses only a bounded
cleanup allowance when continued processing is unavailable. The OS can kill the
process before cleanup completes, including without a final callback; durable
run and Agent journals remain the recovery basis on the next launch.

Native `backgroundAvailable` describes platform capability. A request with
`backgroundAdmission: submitted` is not a grant;
`backgroundAccepted: true` requires actual admission. Task completion is reported
only after the runner's terminal state is durable, independently of notification
delivery. Widgets and Live Activities are not embedded in the GPUI target.

Platform references:

- [Apple: performing long-running tasks](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados)
- [Android: foreground-service start restrictions](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start)
- [Android: foreground-service timeouts](https://developer.android.com/develop/background-work/services/fgs/timeout)
- [Android: handling user stopping](https://developer.android.com/develop/background-work/services/fgs/handle-user-stopping)

## Rust and native responsibilities

| Component | Owns |
| --- | --- |
| `rish-shell-core::assistant_store` | Profile/task schema, validation, revision checks, scheduling eligibility, run claims and frozen run context |
| `src/assistant_runtime` | Process-owned execution loop, session-writer handoff, native replies/events, approval/question routing, cancellation and recovery |
| `rish-pi-runtime` | Embedded Pi Agent Core, isolated custom hooks and bounded model/tool intents |
| `src/ui/assistant*` | Responsive views, local form drafts, explicit actions and display-only runner snapshots |
| `ShellAssistant.storage` | A canonical app-private directory supplied by the native host |
| `TaskExperience.handle` | Platform preferences, notification authorization, background admission, display and lifecycle events |
| Existing native Agent services | Provider requests, workspace validation, tool effects, authorization receipts and WAL |

The store writes schema-1 `assistant-v1.json` inside the native-provided private
directory. Rust uses descriptor-relative no-follow I/O, a process mutex and an
OS file lock, revision checks, atomic replacement and synchronization. Missing
storage creates the empty default state; corrupt storage is preserved and
reported rather than silently replaced. Limits include 64 tasks and 16 KiB per
notes/instructions field. Credentials are not copied into this store.

A task editor allocates one task ID before submitting a creation. Retrying the
same ID with the same normalized configuration returns the existing task;
different configuration under that ID is rejected. This handles an uncertain
save acknowledgement without creating a duplicate task. Form conflicts preserve
the user's draft and require an explicit decision before overwriting newer data.

Before a turn is created, the store saves the run ID, all five turn/message/
attempt/round IDs, and the model/workspace/notes snapshot. The session remains
the existing schema-9 store, with native generation/digest compare-and-swap.
The assistant store does not replace conversation history or the native Agent
journal.

The UI transfers the session-writer lease before sending `Grant`. While the
runner owns it, the UI renders snapshots and forwards actions; it cannot persist
an independent conversation state. Only a `Returned` event hands write authority
back. The runner receives lifecycle and task actions directly at native event
ingress, so cancellation does not depend on the assistant page being visible.

An interrupted run first reloads the native session and matches the saved claim
identities. It uses the existing Agent query/recovery protocol rather than
starting a replacement provider request. Missing or conflicting evidence needs
review. Where every saved ID and cleanup record is absent, recovery can close an
interrupted pre-turn start as failed without executing it. An old task claim
cannot cancel a newer ordinary chat attempt in the same conversation.

Approvals and structured questions keep their native tokens and call identities.
Stop is persisted before native cancellation; a persistence failure keeps an
in-memory stop fence but cannot be reported as a durable stop. Unknown outcomes
remain unresolved until their native evidence can be reconciled.

## Verification boundary

The implementation has separate store, runner, UI and native-adapter test suites.
These test different contracts and do not substitute for a linked app workflow.
Record actual results, artifact identities and device details alongside each run
rather than treating this guide as a rolling acceptance report.

For a release candidate, verify task/profile editing and restart persistence in
the actual app container; task start through the native provider and tool path;
approvals, questions, cancellation and late replies; process restart recovery;
and accepted, denied and expired background allowance. Check phone/tablet layout,
long text, input composition and lifecycle transitions in the linked build.

The existing [native Agent harness](../scripts/native-tests/shell-agent-harness/README.md)
tests the shared Agent controller against isolated native storage, a loopback
provider and file execution. It does not by itself establish assistant UI,
notification or OS admission acceptance. The macOS preview has no mobile runtime;
its layout and controller tests cannot prove mobile execution.

The [process assistant/iOS integration gate](../scripts/native-tests/assistant-actor-harness/README.md)
compiles the production Rust runner with a test transport connected to the real
iOS session CAS, Agent, workspace and task-experience services. Its loopback
provider checks saved note context, completes a file-read task, and verifies that
a missing credential fails without provider requests or tool effects. The
assistant store runs on the host in this gate; mobile sandbox persistence,
rendering and actual OS background admission remain separate checks.

This feature does not add a cloud worker, continuous execution while the phone
is off, a system-wide floating overlay, arbitrary other-app control, or messaging
service integrations. Guest and official-CLI availability still follows the
native capability registry and needs separate runtime verification.
