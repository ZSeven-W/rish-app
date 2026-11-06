# Native task experience

The GPUI iOS host builds the real UIKit, UserNotifications and BackgroundTasks
service. It owns OS admission and task reporting; the Rust process actor owns
Agent execution, durable checkpoints, cancellation and recovery.

The native allowlist exposes:

- `ShellAssistant.storage()` returns schema 1, platform `ios`, and the canonical
  app-private `Application Support/Assistant-v1` directory. The directory is
  mode 0700, excluded from backup, and protected until first authentication.
- `TaskExperience.handle(request)` accepts the existing schema-1 operations
  `settings`, `preferences`, `permission`, `openSettings`, `visible`, `drain`,
  `begin`, `update`, and `end`. Calls are serialized on the main actor.
- `begin` requires `runId`, `conversationId`, and a Boolean `backgroundEligible`.
  Only an explicit user start/resume sets eligibility; scheduled due work does
  not. The reply includes `started`, `backgroundAdmission` and
  `backgroundAccepted`. `submitted` is not evidence that the handler accepted.
- `permission` requires `userInitiated: true`. Initialization never requests
  notification authorization. Notification and background preferences default
  to false.
- Native actions are emitted directly to the process actor as
  `taskExperienceAction` with schema 1, action `cancel` or `open`, `runId`,
  `conversationId`, and an optional reason. Application background/foreground
  changes emit `taskExperienceLifecycle` independently of UI rendering.

On iOS 26+, an eligible foreground task with background enabled requests
`BGContinuedProcessingTask` using the `.fail` submission strategy. Concrete
identifiers are registered once and matched by the plist wildcard. No periodic
wake-up, permanent residency, silent notification, or background GPU entitlement
is requested. See Apple's [continued processing guidance](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados/).

If the OS has not accepted the task when the app backgrounds, the service
immediately asks the actor to cancel and save under a bounded checkpoint lease.
Expiration and the system Stop control use the same OS expiration callback;
these emit `background_expired`. Explicit app cancellation emits `user_stop`.
A normal cleanup lease is released by `end`, after the actor has durably saved
its terminal state. If the OS expires the checkpoint lease first, the native
service must release it and report failure; this does not claim persistence
completed. Relaunch recovery remains the actor's responsibility.

The Widget extension is not embedded in the GPUI app. Consequently
`liveActivitiesAvailable` is false, and the service does not request an
ActivityKit activity. Continued processing's own system presentation is separate
from an app-provided Live Activity. `Widget/` and the acceptance driver remain
available for a separate, explicit extension/device integration.

`TaskExperienceNativeTests` exercise admission, automatic-run refusal, pending
revocation, immediate cancellation, bounded lease expiry and durable-end release
with injected OS drivers. They do not establish real-device continued processing
acceptance or guarantee background execution duration.
