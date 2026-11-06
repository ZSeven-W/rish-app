#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 1 ]]; then
  printf '%s\n' 'Usage: check-provider-policy.sh BOOTED_SIMULATOR_UDID' >&2
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
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/rish-provider-policy.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT

cargo build --locked --manifest-path "$core/Cargo.toml" -p rish-agent-ffi \
  --target aarch64-apple-ios-sim --target-dir "$core/target"
xcrun --sdk iphonesimulator clang++ -std=c++20 -fobjc-arc -fblocks \
  -target arm64-apple-ios16.0-simulator -I "$native/Sources" -I "$core/include" \
  -framework Foundation -framework Security -framework SystemConfiguration \
  "$native/Sources/ProviderConfiguration.mm" "$native/Sources/RishHarnessCatalog.mm" \
  "$root/Tests/ProviderPolicyHostTests.mm" \
  "$core/target/aarch64-apple-ios-sim/debug/librish_agent_ffi.a" \
  -o "$build_dir/provider-policy-tests"

# No UI, credentials, network or user app state. NSUserDefaults is redirected
# within this host process to a fresh isolated suite, removed after testing.
xcrun simctl spawn "$simulator" "$build_dir/provider-policy-tests" \
  "$native/Tests/Fixtures/provider-policy-ios-baseline.json" \
  "$core/fixtures/model-catalog-policy.json" \
  "$core/fixtures/provider-policy.json" \
  "$native/Tests/Fixtures/provider-policy-ios-repeated-suffix.json"
