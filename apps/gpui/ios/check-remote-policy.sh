#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 1 ]]; then
  printf '%s\n' 'Usage: check-remote-policy.sh BOOTED_SIMULATOR_UDID' >&2
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
vendor="${RISH_NATIVE_VENDOR:-$native/Vendor}"
slice=ios-arm64-simulator
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/rish-remote-policy.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT

cargo build --locked --manifest-path "$core/Cargo.toml" -p rish-agent-ffi \
  --target aarch64-apple-ios-sim --target-dir "$core/target"
xcrun --sdk iphonesimulator clang++ -std=c++20 -fobjc-arc -fblocks \
  -target arm64-apple-ios16.0-simulator -I "$native/Sources" -I "$core/include" -I "$root/Sources" \
  -I "$vendor/libgit2.xcframework/$slice/Headers" \
  -framework Foundation -framework Security -framework SystemConfiguration \
  "$native/Sources/DSHGitPushSupport.mm" "$native/Sources/DSHGitSSHSupport.mm" \
  "$root/Sources/RishGitFormValidation.mm" \
  "$root/Tests/RemotePolicyHostTests.mm" \
  "$core/target/aarch64-apple-ios-sim/debug/librish_agent_ffi.a" \
  "$vendor/libgit2.xcframework/$slice/libgit2.a" \
  "$vendor/libssh2.xcframework/$slice/libssh2.a" \
  "$vendor/libcrypto.xcframework/$slice/libcrypto.a" -lz -liconv \
  -o "$build_dir/remote-policy-tests"

# Only pure policy calls run: no app launch, workspace registry, storage,
# network request, simulator boot or UI operation is performed.
xcrun simctl spawn "$simulator" "$build_dir/remote-policy-tests" "$core/fixtures/git-remote-policy.json"
