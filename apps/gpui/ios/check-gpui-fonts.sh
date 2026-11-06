#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 1 ]]; then
  printf '%s\n' 'Usage: check-gpui-fonts.sh BOOTED_SIMULATOR_UDID' >&2
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
target="$root/../mobile/target"
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/rish-gpui-fonts.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT

# Use existing artifacts only, without interfering with an app build. Old
# backend revisions can coexist here; never choose an arbitrary/newest rlib.
python3 - "$root/../mobile" > "$build_dir/artifacts" <<'PY'
import json, os, pathlib, sys, tomllib

mobile = pathlib.Path(sys.argv[1]).resolve()
manifest = tomllib.loads((mobile / "Cargo.toml").read_text())
lock = tomllib.loads((mobile / "Cargo.lock").read_text())
backend = next(p for p in lock["package"] if p["name"] == "gpui-mobile")
revision = backend["source"].rsplit("#", 1)[-1]
features = set(manifest["dependencies"]["gpui-mobile"].get("features", []))
debug = mobile / "target/aarch64-apple-ios-sim/debug"
fingerprints = debug / ".fingerprint"
candidates = []
for library in (debug / "deps").glob("libgpui_mobile-*.rlib"):
    digest = library.stem.removeprefix("libgpui_mobile-")
    dep_info = library.with_name(f"gpui_mobile-{digest}.d")
    fingerprint = fingerprints / f"gpui-mobile-{digest}/lib-gpui_mobile.json"
    if not dep_info.exists() or not fingerprint.exists():
        continue
    metadata = json.loads(fingerprint.read_text())
    if f"/{revision[:7]}" in dep_info.read_text() and set(json.loads(metadata["features"])) == features:
        candidates.append((library, metadata))
override = os.environ.get("RISH_GPUI_FONT_BACKEND_RLIB")
if override:
    candidates = [(library, metadata) for library, metadata in candidates
                  if library.resolve() == pathlib.Path(override).resolve()]
if len(candidates) != 1:
    raise SystemExit("Expected one built debug simulator backend matching Cargo.lock. "
        "Build mobile first; if several compatible artifacts exist, select one with "
        "RISH_GPUI_FONT_BACKEND_RLIB. Candidates: " + str([str(p) for p, _ in candidates]))
backend_library, metadata = candidates[0]
gpui_fingerprint = next(dep[3] for dep in metadata["deps"] if dep[1] == "gpui")
gpui_libraries = []
for fingerprint in fingerprints.glob("gpui-pre-*/lib-gpui"):
    digest = fingerprint.parent.name.rsplit("-", 1)[-1]
    library = debug / f"deps/libgpui-{digest}.rlib"
    if library.exists() and int.from_bytes(bytes.fromhex(fingerprint.read_text().strip()), "little") == gpui_fingerprint:
        gpui_libraries.append(library)
if len(gpui_libraries) != 1:
    raise SystemExit("The matching backend GPUI dependency is missing or ambiguous; rebuild mobile.")
print(gpui_libraries[0])
print(backend_library)
PY
{
  IFS= read -r gpui_rlib
  IFS= read -r backend_rlib
} < "$build_dir/artifacts"

rustc --edition=2024 --target aarch64-apple-ios-sim "$root/Tests/GPUIFontTests.rs" \
  --extern "gpui=$gpui_rlib" --extern "gpui_mobile=$backend_rlib" \
  -L "dependency=$target/aarch64-apple-ios-sim/debug/deps" \
  -L "dependency=$target/debug/deps" -o "$build_dir/gpui-font-tests"
# A standalone text-system process only; no app/window lifecycle or UI events.
xcrun simctl spawn "$simulator" "$build_dir/gpui-font-tests"
