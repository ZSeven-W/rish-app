#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

variant=debug
gradle_task=assembleDebug
args=(--locked)
for arg in "$@"; do
  case "$arg" in
    --release) variant=release; gradle_task=assembleRelease; args+=(--release) ;;
    --help|-h) printf 'Usage: %s [--release]\nBuilds an arm64 APK; release output is unsigned.\n' "$0"; exit 0 ;;
    *) fail "Unknown option: $arg" ;;
  esac
done
configure_android
require_command java
core_dir="${RISH_GPUI_AGENT_CORE_DIR:-$REPO_DIR/modules/rish/android/rish-agent-core}"
[[ -f "$core_dir/jniLibs/arm64-v8a/librish_agent_ffi.so" ]] ||
  fail "Prepare the existing runtime first: scripts/prepare-rish-agent-core-android.sh (see its Rust/NDK prerequisites). Or set RISH_GPUI_AGENT_CORE_DIR to a prepared runtime directory."
(cd "$GPUI_DIR/mobile" && cargo ndk --manifest-path "$GPUI_DIR/mobile/Cargo.toml" \
  -t arm64-v8a --platform 26 -o "$GPUI_DIR/android/app/src/main/jniLibs" \
  build --target-dir "$GPUI_DIR/mobile/target" --lib "${args[@]}")
gradle_args=("-PrishAgentCoreDir=$core_dir")
if [[ -n "${RISH_GPUI_LIBGIT2_DIR:-}" ]]; then
  gradle_args+=("-PrishLibgit2Dir=$RISH_GPUI_LIBGIT2_DIR")
fi
(cd "$GPUI_DIR/android" && ./gradlew --no-daemon "$gradle_task" "${gradle_args[@]}")
printf 'APK output directory: %s\n' "$GPUI_DIR/android/app/build/outputs/apk/$variant"
