#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

variant=simulator
profile=debug
configuration=Debug
args=(--locked)
for arg in "$@"; do
  case "$arg" in
    --simulator) variant=simulator ;;
    --device) variant=device ;;
    --release) profile=release; configuration=Release; args+=(--release) ;;
    --help|-h) printf 'Usage: %s [--simulator|--device] [--release]\nBuilds a development app (ad-hoc signed simulator or unsigned device); does not install or upload.\n' "$0"; exit 0 ;;
    *) fail "Unknown option: $arg" ;;
  esac
done
require_macos
for command_name in cargo xcodebuild xcodegen; do require_command "$command_name"; done
target=aarch64-apple-ios-sim
sdk=iphonesimulator
destination='generic/platform=iOS Simulator'
# Simulator Keychain requires an ad-hoc signature; no developer account or
# provisioning profile is needed. Device signing remains an explicit setup.
signing=(CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=YES)
if [[ "$variant" == device ]]; then
  target=aarch64-apple-ios
  sdk=iphoneos
  destination='generic/platform=iOS'
  signing=(CODE_SIGNING_ALLOWED=NO)
fi
require_target "$target"

# Native services are compiled from the existing app. Never silently download
# or rebuild the VM, Git, or agent-core dependency set while building the UI.
vendor="${RISH_GPUI_NATIVE_VENDOR:-$REPO_DIR/modules/rish/ios/Vendor}"
include="${RISH_GPUI_NATIVE_INCLUDE:-$REPO_DIR/modules/rish/ios/include}"
missing=()
for name in rish_ffi rish_agent_core libgit2 libssh2 libcrypto; do
  [[ -d "$vendor/$name.xcframework" ]] || missing+=("$name.xcframework")
done
[[ -f "$include/rish.h" ]] || missing+=(include/rish.h)
if (( ${#missing[@]} )); then
  printf 'Missing native prerequisites: %s\n' "${missing[*]}" >&2
  fail "Follow docs/development.md toolchain pins, then run scripts/prepare-rish-ios.sh, scripts/prepare-rish-agent-core.sh, and scripts/prepare-libgit2-ios.sh from the repository root. For Rust-only validation use apps/gpui/scripts/check.sh ios."
fi
for headers in "$vendor/rish_agent_core.xcframework"/ios-arm64*/Headers; do
  cmp -s "$REPO_DIR/modules/rish/core/include/rish_agent_core.h" "$headers/rish_agent_core.h" ||
    fail "The prepared agent-core header is stale or missing: $headers/rish_agent_core.h. Rebuild it with scripts/prepare-rish-agent-core.sh."
done

export IPHONEOS_DEPLOYMENT_TARGET=16.0
# The Objective-C host defines rish_gpui_host_request at the final app link.
# Building the manifest's Android cdylib on iOS would demand that symbol early.
cargo rustc --manifest-path "$GPUI_DIR/mobile/Cargo.toml" \
  --target-dir "$GPUI_DIR/mobile/target" --target "$target" \
  --crate-type staticlib --lib "${args[@]}"
xcodegen generate --spec "$GPUI_DIR/ios/project.yml"
xcodebuild -project "$GPUI_DIR/ios/RishGPUI.xcodeproj" -scheme RishGPUI \
  -configuration "$configuration" -sdk "$sdk" -destination "$destination" \
  -derivedDataPath "$GPUI_DIR/build/ios-$variant" \
  RISH_GPUI_TARGET="$target" RISH_GPUI_PROFILE="$profile" \
  RISH_NATIVE_VENDOR="$vendor" RISH_NATIVE_INCLUDE="$include" \
  "${signing[@]}" build
printf 'Development app: %s\n' "$GPUI_DIR/build/ios-$variant/Build/Products/$configuration-$sdk/RishGPUI.app"
