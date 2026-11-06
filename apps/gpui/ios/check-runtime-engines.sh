#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")" && pwd)
native="$root/../../../modules/rish/ios/Sources"
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/rish-runtime-engines.XXXXXX")
fixture_pid=
cleanup() {
  if [[ -n "$fixture_pid" ]]; then
    kill "$fixture_pid" 2>/dev/null || true
    wait "$fixture_pid" 2>/dev/null || true
  fi
  rm -rf "$build_dir"
}
trap cleanup EXIT
common=(-fobjc-arc -fblocks -I "$root/Native" -I "$root/Sources" -I "$native")
xcrun --sdk macosx clang++ "${common[@]}" -framework Foundation \
  "$native/RishRuntimeEngineDownloads.mm" "$root/Sources/ShellRuntimeEnginesModule.m" \
  "$root/Tests/RuntimeEngineTests.mm" -o "$build_dir/runtime-engine-tests"
python3 "$root/Tests/runtime-engine-http-fixture.py" "$build_dir/port" &
fixture_pid=$!
for attempt in {1..50}; do
  [[ ! -f "$build_dir/port" ]] || break
  sleep 0.1
done
"$build_dir/runtime-engine-tests" "http://127.0.0.1:$(cat "$build_dir/port")"
python3 "$root/generate-exports.py" --check
for sdk in iphonesimulator iphoneos; do
  target=arm64-apple-ios16.0
  [[ $sdk != iphonesimulator ]] || target=arm64-apple-ios16.0-simulator
  xcrun --sdk "$sdk" clang++ "${common[@]}" -fsyntax-only -target "$target" \
    "$native/RishRuntimeEngineDownloads.mm" "$root/Sources/ShellRuntimeEnginesModule.m"
done
printf '%s\n' 'PASS: runtime engine bridge syntax checked for iOS device and simulator'
