#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

mode="${1:-desktop}"
[[ $# -le 1 ]] || fail "Usage: $0 [core|desktop|ios|android]"
case "$mode" in
  --help|-h) printf 'Usage: %s [core|desktop|ios|android]\n' "$0"; exit 0 ;;
  core|desktop|ios|android) ;;
  *) fail "Unknown check: $mode" ;;
esac
require_command cargo
case "$mode" in
  core)
    # Do not recurse into the independently maintained native core workspace.
    cargo fmt --manifest-path "$GPUI_DIR/Cargo.toml" -p rish-gpui -p rish-shell-core -- --check
    cargo fmt --manifest-path "$GPUI_DIR/mobile/Cargo.toml" -p rish-gpui-mobile -- --check
    cargo test --locked --manifest-path "$GPUI_DIR/Cargo.toml" -p rish-shell-core
    ;;
  desktop)
    require_macos
    cargo check --locked --manifest-path "$GPUI_DIR/Cargo.toml" --all-targets
    ;;
  ios)
    require_macos
    export IPHONEOS_DEPLOYMENT_TARGET=16.0
    for target in aarch64-apple-ios-sim aarch64-apple-ios; do
      require_target "$target"
      cargo check --locked --manifest-path "$GPUI_DIR/mobile/Cargo.toml" --target "$target" --lib
    done
    "$GPUI_DIR/ios/check-bridge.sh"
    ;;
  android)
    configure_android
    (cd "$GPUI_DIR/mobile" && cargo ndk --manifest-path "$GPUI_DIR/mobile/Cargo.toml" \
      -t arm64-v8a --platform 26 check --locked --lib)
    ;;
esac
