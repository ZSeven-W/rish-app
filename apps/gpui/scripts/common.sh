#!/usr/bin/env bash
# Shared helpers; source this file from a build/check entry point.
set -euo pipefail

GPUI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "$GPUI_DIR/../.." && pwd)"

fail() { printf 'rish-gpui: %s\n' "$*" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || fail "Required command missing: $1"; }
require_target() {
  require_command rustup
  rustup target list --installed | grep -Fxq "$1" ||
    fail "Install the Rust target first: rustup target add $1"
}
require_macos() { [[ "$(uname -s)" == Darwin ]] || fail "This command requires macOS and Xcode."; }

configure_android() {
  require_command cargo
  cargo ndk --version >/dev/null 2>&1 || fail "Install cargo-ndk first: cargo install cargo-ndk --locked"
  require_target aarch64-linux-android
  local sdk="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
  export ANDROID_HOME="$sdk"
  export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-$sdk/ndk/27.1.12297006}}"
  [[ -f "$ANDROID_NDK_HOME/source.properties" ]] || fail "Install Android NDK 27.1.12297006 and set ANDROID_NDK_HOME."
  grep -Eq '^Pkg.Revision[[:space:]]*=[[:space:]]*27\.1\.12297006[[:space:]]*$' "$ANDROID_NDK_HOME/source.properties" ||
    fail "Use Android NDK 27.1.12297006 to match the native host and existing runtime."
  export RUST_FONTCONFIG_DLOPEN=on
  # QuickJS generates Android bindings with libclang. Its headers must come
  # from the same NDK/API as cargo-ndk rather than the build host's C library.
  local ndk_toolchains=("$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*)
  [[ ${#ndk_toolchains[@]} -eq 1 && -d "${ndk_toolchains[0]}/sysroot" ]] ||
    fail "Expected one NDK LLVM host toolchain."
  export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="${BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android:-} --target=aarch64-linux-android26 --sysroot=\"${ndk_toolchains[0]}/sysroot\""
  # Align the GPUI .so as well as the existing runtime for Android 16 KiB pages.
  export CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS="${CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS:-} -C link-arg=-Wl,-z,max-page-size=16384"
}
