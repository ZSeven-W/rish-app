#!/bin/zsh
# Builds the shared Rust agent core (modules/rish/core) for Android and stages
# it as modules/rish/android/rish-agent-core for the app's JNI shim. Run next to
# prepare-rish-android.sh. Requires the workspace toolchain
# (modules/rish/core/rust-toolchain.toml) with the Android targets installed and
# the pinned NDK; this script never installs toolchains, targets or an NDK.
set -euo pipefail

readonly SCRIPT_DIR=${0:A:h}
readonly REPO_ROOT=${SCRIPT_DIR:h}
readonly CORE_ROOT=${REPO_ROOT}/modules/rish/core
readonly OUTPUT_ROOT=${REPO_ROOT}/modules/rish/android/rish-agent-core
readonly HEADER=${CORE_ROOT}/include/rish_agent_core.h
readonly LIBRARY_NAME=librish_agent_ffi.so
readonly EXPECTED_NDK_VERSION="27.1.12297006"
readonly ANDROID_API_LEVEL="24"
# arm64 only, matching prepare-rish-android.sh: it is the only ABI the guest
# runtime ships, so it is the only one an agent build can run beside.
readonly ABI="arm64-v8a"
readonly TARGET="aarch64-linux-android"

fail() {
  print -u2 -- "prepare-rish-agent-core-android: $*"
  exit 1
}

command -v cargo >/dev/null || fail "cargo is required"
command -v rustup >/dev/null || fail "rustup is required"

ndk_root=${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}
if [[ -z "${ndk_root}" ]]; then
  sdk_root=${ANDROID_SDK_ROOT:-${ANDROID_HOME:-${HOME}/Library/Android/sdk}}
  ndk_root=${sdk_root}/ndk/${EXPECTED_NDK_VERSION}
fi
[[ -d "${ndk_root}" ]] ||
  fail "Android NDK ${EXPECTED_NDK_VERSION} not found at ${ndk_root}; set ANDROID_NDK_HOME"
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64|Darwin-x86_64) ndk_host_tag=darwin-x86_64 ;;
  Linux-x86_64) ndk_host_tag=linux-x86_64 ;;
  *) fail "unsupported host for the Android NDK: $(uname -s)-$(uname -m)" ;;
esac
readonly NDK_BIN=${ndk_root}/toolchains/llvm/prebuilt/${ndk_host_tag}/bin
[[ -x "${NDK_BIN}/llvm-ar" ]] || fail "NDK tool missing: ${NDK_BIN}/llvm-ar"
[[ -x "${NDK_BIN}/${TARGET}${ANDROID_API_LEVEL}-clang" ]] ||
  fail "NDK linker missing: ${NDK_BIN}/${TARGET}${ANDROID_API_LEVEL}-clang"

toolchain=$(sed -n 's/^channel *= *"\(.*\)"/\1/p' "${CORE_ROOT}/rust-toolchain.toml")
[[ -n "${toolchain}" ]] || fail "rust-toolchain.toml names no channel"
rustup target list --installed --toolchain "${toolchain}" |
  /usr/bin/grep -x "${TARGET}" >/dev/null ||
  fail "Rust target ${TARGET} is not installed for toolchain ${toolchain}; install it with: rustup target add --toolchain ${toolchain} ${TARGET}"

key=${${TARGET:u}//-/_}
export "CARGO_TARGET_${key}_LINKER=${NDK_BIN}/${TARGET}${ANDROID_API_LEVEL}-clang"
export "CARGO_TARGET_${key}_AR=${NDK_BIN}/llvm-ar"
# Android 15 requires 16 KiB page alignment.
export "CARGO_TARGET_${key}_RUSTFLAGS=-C link-arg=-Wl,-z,max-page-size=16384"
export RISH_AGENT_CORE_GIT_SHA="$(git -C "${REPO_ROOT}" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)$(git -C "${REPO_ROOT}" diff --quiet -- modules/rish/core 2>/dev/null || echo -dirty)"

(cd "${CORE_ROOT}" && cargo "+${toolchain}" build --release --locked \
    --package rish-agent-ffi --target "${TARGET}") ||
  fail "cargo build failed for ${TARGET}"
built=${CORE_ROOT}/target/${TARGET}/release/${LIBRARY_NAME}
[[ -f "${built}" ]] || fail "no ${LIBRARY_NAME} for ${TARGET}"

staging=$(mktemp -d "${TMPDIR:-/tmp}/rish-agent-core-android.XXXXXX")
trap '/bin/rm -rf -- "${staging}"' EXIT
/bin/mkdir -p "${staging}/include" "${staging}/jniLibs/${ABI}"
/bin/cp "${HEADER}" "${staging}/include/rish_agent_core.h"
/bin/cp "${built}" "${staging}/jniLibs/${ABI}/${LIBRARY_NAME}"
"${NDK_BIN}/llvm-strip" --strip-unneeded "${staging}/jniLibs/${ABI}/${LIBRARY_NAME}" ||
  fail "llvm-strip failed"
"${NDK_BIN}/llvm-nm" --dynamic --defined-only "${staging}/jniLibs/${ABI}/${LIBRARY_NAME}" |
  /usr/bin/grep -q " rish_agent_session_reduce$" ||
  fail "the staged library does not export rish_agent_session_reduce"

/bin/mkdir -p "${OUTPUT_ROOT:h}"
/bin/rm -rf -- "${OUTPUT_ROOT}"
/bin/mv "${staging}" "${OUTPUT_ROOT}"
/bin/chmod -R u+w "${OUTPUT_ROOT}"
version=$(cd "${CORE_ROOT}" && git rev-parse --short HEAD 2>/dev/null || print unknown)
print -- "rish-agent-core ${version} (${toolchain}) ${ABI}" > "${OUTPUT_ROOT}/rish_agent_core.version"
print -- "prepare-rish-agent-core-android: staged ${OUTPUT_ROOT}"
