# Process assistant / iOS Agent integration gate

This opt-in gate compiles the production `apps/gpui/src/assistant_runtime` source
directly. Only `runtime::Runtime` is a test transport: it queues the actor's exact
requests and waits on oneshot replies from the real iOS native modules. No
session CAS proof, Agent receipt, workspace binding, or terminal result is made
up by the host adapter. It runs a single actor process and exercises two tasks:

- Save an explicit profile and task, persist Run Now intent before session
  handoff, read a real fixture file through Agent tools, feed the tool result
  into a second real native provider round, and persist the completed result.
- Start another task without a credential, require zero provider requests and
  zero tool effects, then correlate the durable failed run with native session
  IDs, terminal state, and completed cleanup.

New claims use the default embedded Pi Agent Core. The production Pi gate must
admit each native model/tool request and consume its committed receipt; the
transport does not replace the runtime or synthesize Pi events. The QuickJS
interpreter runs in the host actor process in this gate, while the separately
built mobile app verifies target compilation/linking. Full in-app assistant
execution remains a separate device acceptance check.

The model is a deterministic loopback fixture through the existing real
`DshProviderTransport` and parser. No external provider or real credentials are
used. The provider verifies that the actor's saved profile context arrives.
Every inspection reopens the host `AssistantStore` and compares it with the actor
snapshot. **That store runs on the host**, so this gate does not prove the Rust
store works inside the mobile app sandbox, UI layout, or background OS admission.
Those require separate app-container, UI, and platform tests.

With the current mobile static library and native vendor already built:

```sh
RISH_ASSISTANT_ACTOR_DEVICE_ID=<isolated-simulator-udid> \
  bash scripts/native-tests/test-assistant-actor-ios.sh
```

Vendor/include overrides match the existing native test scripts. Optional
`RISH_ASSISTANT_ACTOR_XCTESTRUN` reuses a test plan already containing the new
case. `RISH_ASSISTANT_ACTOR_OUTPUT`, `RISH_ASSISTANT_ACTOR_DERIVED_DATA`, and
`RISH_NATIVE_TEST_CARGO_TARGET_DIR` select artifact/build directories. Never use
a user simulator. A skipped, absent, or failed gate is rejected by the launcher.
The earlier twelve shared-shell/native contract cases remain a separate gate.
