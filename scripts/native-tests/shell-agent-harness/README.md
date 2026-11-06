# Shared shell / native Agent contract gate

This opt-in test uses the production `rish-shell-core::ShellState` on the host.
The iOS XCTest receives its generated commands over an ephemeral IPv4 loopback
port and invokes the real generated `AgentRuntimeModule` selectors, backed by
fresh native session/WAL/transcript/workspace stores. Every native reply is
returned to the same Rust state machine. The harness never creates a successful
native receipt, rewrites a journal, or substitutes an approval result. One fault
case withholds a real committed CAS reply and reports `unknown`; only the real
native `querySessionCommit` response can then advance the controller.

The provider transport is real `DshProviderTransport`. A test-only NSURLProtocol
relays its generated request body to the local deterministic HTTP provider and
returns the response through the native parser. It never forwards Authorization,
loads credentials, uses a configured provider, or contacts an external service.
The second provider round requires actual tool feedback, including the fixture
file marker or denied outcome. Test fixtures use a new private root per case.

Run on an **isolated simulator** with current mobile static library and native
FFI vendor already built:

```sh
RISH_SHELL_AGENT_DEVICE_ID=<isolated-udid> \
  bash scripts/native-tests/test-shell-agent-ios.sh
```

`RISH_SHELL_AGENT_XCTESTRUN` can point to an already-built plan containing
`ShellAgentNativeContractTests` to skip Xcode build. `RISH_SHELL_AGENT_OUTPUT`
selects a separate artifact directory. Native vendor/include overrides use the
same `RISH_GPUI_NATIVE_VENDOR` / `RISH_GPUI_NATIVE_INCLUDE` variables as other
native tests. Set `RISH_IOS_GUEST_CGI_ENABLED=1` when reusing this build for the
feature-enabled offline native regression matrix. The twelve contract scenarios
do not start a VM. Missing harness URL causes tests to **skip**, not claim a pass.

Cases cover read→answer→cleanup, lost user-CAS reply resolution before provider
dispatch, approval before write, durable denial,
cancellation while waiting, cancellation after confirmed provider dispatch with
its response held until cleanup, controller reconstruction with pending approval,
lost write reply recovery without a second execution, and structured question
answering. Two refusal cases use a missing credential and an unavailable
transport; both must fail before any HTTP/tool effect and finish durable cleanup.
The in-flight cancellation case uses a condition-variable handshake, delivers
the actual old native callback after cleanup, and requires zero assistant
messages, no second provider dispatch, an empty cleanup outbox and an ignored
stale callback. The session retains the provider round's ambiguous outcome;
explicit native interruption cleans its ownerless residue after durable Stop. A restart case drops a real pre-dispatch failure reply, commits
Stop, recreates the shell from the native snapshot, and requires reconciliation
to honor that durable Stop without sending a provider request. Success requires exact native transitions and verified filesystem
effects; pure Rust tests and bridge selector inventory cannot replace this gate.

The GPUI workflow compiles this host driver and checks its launcher syntax.
It does **not** run the twelve native scenarios: its iOS job lacks the complete
pinned VM/Git XCFramework vendor needed to link the app. A CI runner with those
existing native dependencies, XcodeGen, the mobile static library and an isolated
simulator can use the same launcher; it needs no external provider credentials.
The launcher binds a fresh localhost port, injects it into a private xctestrun,
and requires all twelve exact test names to report Passed once. Missing, skipped,
duplicated or failed cases fail the gate. Native command failures retain only
synthetic test state in JSON artifacts / XCTest attachments.
