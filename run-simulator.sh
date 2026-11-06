#!/usr/bin/env bash
set -euo pipefail

APP_ROOT="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_ID=tech.zseven.rish.gpui
DEVICE_ID="${1:-}"

if [[ -z "$DEVICE_ID" ]]; then
  DEVICE_ID=$(xcrun simctl list devices available --json | python3 -c '
import json, sys
phones = [d for devices in json.load(sys.stdin)["devices"].values() for d in devices
          if d.get("isAvailable") and "iPhone" in d["name"]]
phones.sort(key=lambda d: (d.get("state") != "Booted", d["name"] != "iPhone 17 Pro"))
print(phones[0]["udid"] if phones else "")')
fi
if [[ -z "$DEVICE_ID" ]]; then
  echo "No available iPhone simulator was found" >&2
  exit 2
fi

"$APP_ROOT/apps/gpui/scripts/build-ios.sh" --simulator
# bootstatus also waits for an already booted simulator.
xcrun simctl boot "$DEVICE_ID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$DEVICE_ID" -b
APP_BUNDLE="$APP_ROOT/apps/gpui/build/ios-simulator/Build/Products/Debug-iphonesimulator/RishGPUI.app"
xcrun simctl install "$DEVICE_ID" "$APP_BUNDLE"
xcrun simctl launch --terminate-running-process "$DEVICE_ID" "$BUNDLE_ID"
printf 'app=%s\nsimulator=%s\nbundle_id=%s\n' "$APP_BUNDLE" "$DEVICE_ID" "$BUNDLE_ID"
