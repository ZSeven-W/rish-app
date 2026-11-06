#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

args=(--locked)
operation=build
for arg in "$@"; do
  case "$arg" in
    --release) args+=(--release) ;;
    --run) operation=run ;;
    --help|-h) printf 'Usage: %s [--release] [--run]\n' "$0"; exit 0 ;;
    *) fail "Unknown option: $arg" ;;
  esac
done
require_macos
require_command cargo
require_command xcrun
cargo "$operation" --manifest-path "$GPUI_DIR/Cargo.toml" \
  --target-dir "$GPUI_DIR/target" --bin rish-gpui "${args[@]}"
