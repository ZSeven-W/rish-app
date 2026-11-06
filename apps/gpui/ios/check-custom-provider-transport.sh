#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 1 ]]; then
  printf '%s\n' 'Usage: check-custom-provider-transport.sh BOOTED_SIMULATOR_UDID' >&2
  exit 2
fi
simulator=$1
xcrun simctl list devices booted -j | python3 -c '
import json, sys, uuid
requested = str(uuid.UUID(sys.argv[1])).upper()
devices = json.load(sys.stdin)["devices"]
if not any(device["udid"].upper() == requested and device["state"] == "Booted"
           and device.get("isAvailable", False)
           for runtime, entries in devices.items() if ".iOS-" in runtime
           for device in entries):
    raise SystemExit("Specify an available, already booted iOS simulator.")
' "$simulator"

root=$(cd "$(dirname "$0")" && pwd)
native="$root/../../../modules/rish/ios"
core="$root/../../../modules/rish/core"
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/rish-custom-provider-transport.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT

RUSTUP_TOOLCHAIN=${RISH_CORE_TOOLCHAIN:-1.94} cargo build --locked \
  --manifest-path "$core/Cargo.toml" -p rish-agent-ffi \
  --target aarch64-apple-ios-sim --target-dir "$core/target"
xcrun --sdk iphonesimulator clang++ -std=c++20 -fobjc-arc -fblocks \
  -target arm64-apple-ios16.0-simulator -I "$native/Sources" -I "$core/include" \
  -framework Foundation -framework Security -framework SystemConfiguration \
  "$native/Sources/ProviderConfiguration.mm" "$native/Sources/RishHarnessCatalog.mm" \
  "$native/Sources/ConfiguredProviderTransport.mm" "$native/Sources/DSHCompletionProviderTransport.mm" \
  "$native/Sources/DSHCompletionV2.mm" "$native/Sources/DSHCompletionResponse.mm" \
  "$native/Sources/DSHStreamEvents.mm" "$native/Sources/DshProviderTransport.mm" \
  "$native/Sources/ClaudeProviderTransport.mm" "$native/Sources/CodexProviderTransport.mm" \
  "$root/Tests/CustomProviderTransportHostTests.mm" \
  "$core/target/aarch64-apple-ios-sim/debug/librish_agent_ffi.a" \
  -o "$build_dir/custom-provider-transport-tests"

# A standalone host process with isolated defaults, synthetic credentials and
# an ephemeral 127.0.0.1 server. No app, UI, login or external endpoint is used.
xcrun simctl spawn "$simulator" "$build_dir/custom-provider-transport-tests"
