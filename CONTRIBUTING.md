# Contributing to Rish App

Rish App is licensed under the [MIT License](LICENSE). The active application is
[`apps/gpui`](apps/gpui/README.md), with shared Rust views and native iOS/Android
hosts. Start with the [developer guide](docs/development.md) and
[migration status](docs/gpui-migration.md).

## Before changing code

Keep credentials, provider tokens, Keychain data, signing keys, generated app
data and native build outputs outside source control. Do not include them in
fixtures, logs, screenshots, documentation or app bundles.

GPUI and native dependency preparation use separate toolchain pins. Follow the
checked-in scripts rather than weakening their source, header or lockfile
checks. Keep preparation explicit; normal UI builds must not silently fetch or
replace the VM, Git or agent-core dependency set.

## Local checks

From the repository root:

```sh
node scripts/verify-source-checkout.mjs
apps/gpui/scripts/check.sh core
apps/gpui/scripts/check.sh desktop
cargo test --locked --manifest-path apps/gpui/Cargo.toml --lib
```

Run the affected native checks for host or bridge changes:

```sh
apps/gpui/scripts/check.sh ios
apps/gpui/scripts/check.sh android
apps/gpui/android/gradlew -p apps/gpui/android --no-daemon \
  compileDebugKotlin testDebugUnitTest
```

These commands need the platform prerequisites listed in the developer guide.
A source check or successful compilation is not a substitute for exercising the
selected binary on a simulator/device. Report skipped or unavailable checks
accurately. Changes to shared native rules need the corresponding core tests;
bridge changes need export-registry and argument/error contract checks.

## Change scope

Keep new files focused and under 800 lines. Preserve native validation,
authority, persistence and recovery rules when changing the UI. Add user-facing
strings to both supported app locales, and use the shared theme and Lucide icon
assets. Do not add a second session store or bypass generation/digest CAS.

Describe the concrete problem, resulting behavior and validation in a pull
request. Separate implemented behavior from unverified platform/provider paths.
The GPUI app currently provides basic native text chat; full Agent controller,
tool workflows and task Live Activity integration remain incomplete. Historical
results from the removed app are not proof of GPUI parity.

Release signing and distribution are separate from ordinary development; the
GPUI release pipeline is still pending. See [distribution status](docs/testflight.md).
