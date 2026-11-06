#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 1 ]]; then
  printf '%s\n' 'Usage: check-inline-composer.sh BOOTED_SIMULATOR_UDID' >&2
  exit 2
fi
simulator=$1
xcrun simctl list devices booted -j | python3 -c '
import json, sys, uuid
requested = str(uuid.UUID(sys.argv[1])).upper()
devices = json.load(sys.stdin)["devices"]
if not any(d["udid"].upper() == requested and d["state"] == "Booted" and d.get("isAvailable", False)
           for runtime, entries in devices.items() if ".iOS-" in runtime for d in entries):
    raise SystemExit("Specify an available, already booted iOS simulator.")
' "$simulator"
root=$(cd "$(dirname "$0")" && pwd)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/rish-inline-composer.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT
xcrun --sdk iphonesimulator clang -fobjc-arc -fblocks \
  -target arm64-apple-ios16.0-simulator -I "$root/Sources" -I "$root/Native" \
  -framework UIKit -framework Foundation -framework QuartzCore -framework CoreGraphics \
  "$root/Sources/RishInlineComposer.m" "$root/Sources/RishInlineComposerValidation.m" \
  "$root/Tests/InlineComposerTests.m" -o "$build_dir/inline-composer-tests"
# Offscreen root only: no UIApplication, windows, app install, workspace data,
# presentation, responder activation or synthetic UI input.
xcrun simctl spawn "$simulator" "$build_dir/inline-composer-tests"
