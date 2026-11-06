#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 1 ]]; then
  printf '%s\n' 'Usage: check-file-editor-layout.sh BOOTED_SIMULATOR_UDID' >&2
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
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/rish-file-editor-layout.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT
xcrun --sdk iphonesimulator clang -fobjc-arc -fblocks \
  -target arm64-apple-ios16.0-simulator -I "$root/Sources" \
  -framework UIKit -framework Foundation -framework QuartzCore -framework CoreGraphics \
  "$root/Sources/RishFileEditorController.m" "$root/Sources/RishFileEditorValidation.m" \
  "$root/Sources/RishComposerController.m" \
  "$root/Tests/FileEditorLayoutTests.m" -o "$build_dir/file-editor-layout-tests"

# Offscreen UIKit layout only: no UIApplication, windows, app installation,
# presentation, first responder changes, or synthesized keyboard/touch events.
xcrun simctl spawn "$simulator" "$build_dir/file-editor-layout-tests"
