#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 1 ]]; then
  printf '%s\n' 'Usage: check-name-layout.sh BOOTED_SIMULATOR_UDID' >&2
  exit 2
fi
simulator=$1
xcrun simctl list devices booted -j | python3 -c '
import json, sys, uuid
try:
    requested = str(uuid.UUID(sys.argv[1])).upper()
    if requested != sys.argv[1].upper():
        raise ValueError("Use the complete simulator UDID")
except ValueError:
    raise SystemExit("Specify the UDID of an already booted iOS simulator.")
devices = json.load(sys.stdin)["devices"]
if not any(device["udid"].upper() == requested and device["state"] == "Booted"
           and device.get("isAvailable", False)
           for runtime, entries in devices.items() if ".iOS-" in runtime
           for device in entries):
    raise SystemExit("The requested iOS simulator is not available and booted.")
' "$simulator"

root=$(cd "$(dirname "$0")" && pwd)
core="$root/../../../modules/rish/core"
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/rish-name-layout.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT

# Build the current pure core for the same arm64 simulator target as the app.
# The test links UIKit and the pure core without starting the application.
cargo build --locked --manifest-path "$core/Cargo.toml" -p rish-agent-ffi \
  --target aarch64-apple-ios-sim --target-dir "$core/target"
xcrun --sdk iphonesimulator clang -fobjc-arc -fblocks \
  -target arm64-apple-ios16.0-simulator \
  -I "$root/Native" -I "$root/Sources" -I "$core/include" \
  -framework UIKit -framework Foundation -framework Security \
  -framework QuartzCore -framework CoreGraphics \
  "$root/Sources/RishNameController.m" "$root/Sources/RishNameValidation.m" \
  "$root/Tests/NameLayoutTests.m" \
  "$core/target/aarch64-apple-ios-sim/debug/librish_agent_ffi.a" \
  -o "$build_dir/name-layout-tests"

# An offscreen executable only: no simulator boot, app install, or UI events.
xcrun simctl spawn "$simulator" "$build_dir/name-layout-tests"
