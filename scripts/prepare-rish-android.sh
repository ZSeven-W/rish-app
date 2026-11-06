#!/bin/zsh
set -euo pipefail

# Builds the pinned rish runtime as an Android shared library and stages it
# where apps/gpui/android/app/build.gradle picks it up. The pins below are
# deliberately identical to prepare-rish-ios.sh: updating rish for the app is
# a reviewed source upgrade, not a side effect of whatever is checked out next
# door. Both scripts must move together.
readonly EXPECTED_RISH_COMMIT="9020e9648115bd9ae8eb5215dd3e7ac76620da3f"
readonly EXPECTED_RISH_REMOTE="git@github.com:ZSeven-W/rish.git"
readonly EXPECTED_RISH_PUBLIC_REMOTE="https://github.com/ZSeven-W/rish.git"
readonly EXPECTED_HEADER_SHA256="ba15e5084739538acc5edc7c5bb12638272c5594a548c77ba23d5e22d94e422f"
readonly EXPECTED_CARGO_LOCK_SHA256="88571f30fd4496f9efbe5834dc91c087fc35836140f906fc91712092bfed537e"
readonly EXPECTED_CRATE_VERSION="0.1.0"
readonly RUST_TOOLCHAIN="1.94"
readonly EXPECTED_RUSTC_RELEASE="1.94.1"
readonly EXPECTED_RUSTC_COMMIT="e408947bfd200af42db322daf0fadfe7e26d3bd1"
# Matches the GPUI NDK pin; API 24 keeps these libraries reusable by native hosts.
readonly EXPECTED_NDK_VERSION="27.1.12297006"
readonly ANDROID_API_LEVEL="24"
# Android 15 loads app libraries on 16 KiB pages; every ELF segment must align.
readonly EXPECTED_PAGE_ALIGNMENT="0x4000"

readonly SCRIPT_DIR=${0:A:h}
readonly APP_ROOT=${SCRIPT_DIR:h}
readonly RISH_SOURCE_ARG=${RISH_SOURCE_DIR:-${RISH_ANDROID_RISH_ROOT:-${1:-}}}
readonly OFFLINE=${RISH_ANDROID_OFFLINE:-0}
# Comma-separated Android ABIs to build. arm64-v8a covers every current phone
# and the arm64 emulator; add x86_64 for an x86_64 emulator image.
readonly REQUESTED_ABIS=${RISH_ANDROID_ABIS:-arm64-v8a}
RISH_ROOT=""
rish_source_tmp=""
readonly OUTPUT_ROOT=${APP_ROOT}/modules/rish/android/rish-ffi
readonly VERSION_OUTPUT=${OUTPUT_ROOT}/rish_ffi.version

fail() {
  print -u2 -- "prepare-rish-android: $*"
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

sha256_file() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

abi_target() {
  case "$1" in
    arm64-v8a) print -- "aarch64-linux-android" ;;
    x86_64) print -- "x86_64-linux-android" ;;
    *) fail "unsupported Android ABI '$1'; supported: arm64-v8a, x86_64" ;;
  esac
}

abi_machine() {
  case "$1" in
    arm64-v8a) print -- "AArch64" ;;
    x86_64) print -- "Advanced Micro Devices X86-64" ;;
  esac
}

# Upper-cases a target triple the way Cargo spells per-target env overrides.
target_env_key() {
  print -- "${1:u}" | /usr/bin/tr '-' '_'
}

verify_library() {
  local library=$1
  local abi=$2
  local label=$3
  [[ -f "${library}" ]] || fail "${label} library was not produced: ${library}"

  local header
  header=$("${LLVM_READELF}" -hW "${library}")
  print -r -- "${header}" | /usr/bin/grep -q "Class:[[:space:]]*ELF64" || \
    fail "${label} library is not ELF64"
  print -r -- "${header}" | /usr/bin/grep -q "Machine:[[:space:]]*$(abi_machine "${abi}")" || \
    fail "${label} library is not built for ${abi}"

  # Every PT_LOAD segment must be 16 KiB aligned for Android 15 devices.
  local alignments
  alignments=$("${LLVM_READELF}" -lW "${library}" | /usr/bin/awk '$1 == "LOAD" { print $NF }' | /usr/bin/sort -u)
  [[ "${alignments}" == "${EXPECTED_PAGE_ALIGNMENT}" ]] || \
    fail "${label} library LOAD alignment is '${alignments// /,}', expected ${EXPECTED_PAGE_ALIGNMENT}"

  # The runtime may depend only on Bionic; an ambient library would not exist
  # on a phone and would silently break loading.
  local needed
  needed=$("${LLVM_READELF}" -dW "${library}" | /usr/bin/awk '/NEEDED/ { gsub(/[][]/, "", $NF); print $NF }')
  local entry
  for entry in ${(f)needed}; do
    case "${entry}" in
      libc.so|libdl.so|libm.so|liblog.so) ;;
      *) fail "${label} library needs unexpected shared library ${entry}" ;;
    esac
  done

  local symbol
  for symbol in \
    rish_plan_json \
    rish_protocol_version \
    rish_execute_applet_json \
    rish_pull_image_json \
    rish_vm_run_docker_json \
    rish_vm_boot_session \
    rish_vm_boot_session_cancellable \
    rish_vm_cancel_new \
    rish_vm_cancel_request \
    rish_vm_cancel_free \
    rish_vm_session_exec_json \
    rish_vm_session_exec_stream_json \
    rish_vm_session_free \
    rish_string_free; do
    "${LLVM_NM}" -D --defined-only "${library}" 2>/dev/null | \
      /usr/bin/grep "[[:space:]]T[[:space:]]${symbol}$" >/dev/null || \
      fail "${label} library is missing exported symbol ${symbol}"
  done
}

build_root=""
lock_dir=""
lock_acquired=false
publish_in_progress=false
publish_complete=false
next_output=""
previous_output=""
original_output=false

rollback_outputs() {
  if [[ -n "${previous_output}" && -e "${previous_output}" ]]; then
    /bin/rm -rf -- "${OUTPUT_ROOT}" || true
    /bin/mv "${previous_output}" "${OUTPUT_ROOT}" || true
  elif [[ "${original_output}" == false ]]; then
    /bin/rm -rf -- "${OUTPUT_ROOT}" || true
  fi
}

cleanup() {
  if [[ "${publish_in_progress}" == true && "${publish_complete}" == false ]]; then
    rollback_outputs
  fi
  [[ -n "${next_output}" ]] && /bin/rm -rf -- "${next_output}" || true
  [[ -n "${build_root}" && -d "${build_root}" ]] && /bin/rm -rf -- "${build_root}" || true
  [[ -n "${rish_source_tmp}" && -d "${rish_source_tmp}" ]] && /bin/rm -rf -- "${rish_source_tmp}" || true
  if [[ "${lock_acquired}" == true && -n "${lock_dir}" ]]; then
    /bin/rmdir "${lock_dir}" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM HUP

require_command cargo
require_command git
require_command jq
require_command rustc
require_command rustup
require_command tar

[[ "${OFFLINE}" == 0 || "${OFFLINE}" == 1 ]] || \
  fail "RISH_ANDROID_OFFLINE must be 0 or 1"

abis=(${(s:,:)REQUESTED_ABIS})
[[ ${#abis} -gt 0 ]] || fail "RISH_ANDROID_ABIS must name at least one ABI"
typeset -A abi_targets
for abi in "${abis[@]}"; do
  abi_targets[${abi}]=$(abi_target "${abi}")
done

# Resolve the pinned NDK from the usual environment, then the default SDK.
ndk_root=${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}
if [[ -z "${ndk_root}" ]]; then
  sdk_root=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-${HOME}/Library/Android/sdk}}
  ndk_root=${sdk_root}/ndk/${EXPECTED_NDK_VERSION}
fi
[[ -d "${ndk_root}" ]] || fail "Android NDK ${EXPECTED_NDK_VERSION} not found at ${ndk_root}; set ANDROID_NDK_HOME"
ndk_version=$(/usr/bin/sed -n 's/^Pkg\.Revision *= *//p' "${ndk_root}/source.properties" 2>/dev/null | /usr/bin/head -1)
[[ "${ndk_version}" == "${EXPECTED_NDK_VERSION}" ]] || \
  fail "NDK at ${ndk_root} is ${ndk_version:-unknown}; expected ${EXPECTED_NDK_VERSION}"
case "$(uname -s)-$(uname -m)" in
  Darwin-*) ndk_host_tag="darwin-x86_64" ;;
  Linux-x86_64) ndk_host_tag="linux-x86_64" ;;
  *) fail "unsupported host for the Android NDK: $(uname -s)-$(uname -m)" ;;
esac
readonly NDK_BIN=${ndk_root}/toolchains/llvm/prebuilt/${ndk_host_tag}/bin
readonly LLVM_READELF=${NDK_BIN}/llvm-readelf
readonly LLVM_NM=${NDK_BIN}/llvm-nm
readonly LLVM_STRIP=${NDK_BIN}/llvm-strip
readonly LLVM_AR=${NDK_BIN}/llvm-ar
for tool in "${LLVM_READELF}" "${LLVM_NM}" "${LLVM_STRIP}" "${LLVM_AR}"; do
  [[ -x "${tool}" ]] || fail "NDK tool missing: ${tool}"
done

build_rust_toolchain=${RUST_TOOLCHAIN}
if [[ "${OFFLINE}" == 1 ]]; then
  installed_toolchains=$(rustup toolchain list --quiet) || \
    fail "could not inspect installed Rust toolchains"
  build_rust_toolchain=$(
    print -r -- "${installed_toolchains}" |
      /usr/bin/awk -v requested="${RUST_TOOLCHAIN}" \
        '$1 == requested || index($1, requested "-") == 1 { print $1; exit }'
  )
  [[ -n "${build_rust_toolchain}" ]] || \
    fail "offline preparation requires preinstalled Rust ${RUST_TOOLCHAIN}; install the pinned toolchain before retrying"
fi
if [[ -n "${RISH_SOURCE_ARG}" ]]; then
  RISH_ROOT=${RISH_SOURCE_ARG:A}
  [[ -d "${RISH_ROOT}" ]] || fail "rish source checkout does not exist: ${RISH_ROOT}"
else
  [[ "${OFFLINE}" == 0 ]] || \
    fail "offline preparation requires RISH_SOURCE_DIR or an explicit reviewed checkout path"
  rish_source_tmp=$(mktemp -d "${TMPDIR:-/tmp}/rish-android-source.XXXXXX")
  RISH_ROOT=${rish_source_tmp}/rish
  git init --quiet "${RISH_ROOT}"
  git -C "${RISH_ROOT}" remote add origin "${EXPECTED_RISH_PUBLIC_REMOTE}"
  git -C "${RISH_ROOT}" fetch --quiet --depth=1 origin "${EXPECTED_RISH_COMMIT}" ||
    fail "could not fetch pinned rish commit from ${EXPECTED_RISH_PUBLIC_REMOTE}"
  git -C "${RISH_ROOT}" checkout --quiet --detach "${EXPECTED_RISH_COMMIT}" ||
    fail "could not check out pinned rish commit ${EXPECTED_RISH_COMMIT}"
fi

rustc_release=$(rustc +"${build_rust_toolchain}" -vV | /usr/bin/awk '/^release:/ { print $2 }')
rustc_commit=$(rustc +"${build_rust_toolchain}" -vV | /usr/bin/awk '/^commit-hash:/ { print $2 }')
[[ "${rustc_release}" == "${EXPECTED_RUSTC_RELEASE}" && \
  "${rustc_commit}" == "${EXPECTED_RUSTC_COMMIT}" ]] || \
  fail "Rust ${RUST_TOOLCHAIN} resolved to ${rustc_release}/${rustc_commit}; expected ${EXPECTED_RUSTC_RELEASE}/${EXPECTED_RUSTC_COMMIT}"

git -C "${RISH_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || \
  fail "expected a Git source checkout at ${RISH_ROOT}"
actual_commit=$(git -C "${RISH_ROOT}" rev-parse HEAD)
actual_remote=$(git -C "${RISH_ROOT}" remote get-url origin)
[[ "${actual_commit}" == "${EXPECTED_RISH_COMMIT}" ]] || \
  fail "rish HEAD is ${actual_commit}; expected pinned commit ${EXPECTED_RISH_COMMIT}"
case "${actual_remote}" in
  "${EXPECTED_RISH_REMOTE}"|"${EXPECTED_RISH_PUBLIC_REMOTE}"|ssh://git@github.com/ZSeven-W/rish.git)
    ;;
  *)
    fail "rish origin is ${actual_remote}; expected the canonical ZSeven-W/rish repository"
    ;;
esac
[[ -z "$(git -C "${RISH_ROOT}" status --porcelain=v1 --untracked-files=all)" ]] || \
  fail "rish checkout is dirty; refusing to package beside unreviewed source"

for abi in "${abis[@]}"; do
  target=${abi_targets[${abi}]}
  rustup target list --installed --toolchain "${build_rust_toolchain}" |
    /usr/bin/grep -x "${target}" >/dev/null || \
    fail "Rust target ${target} is not installed; run: rustup target add --toolchain ${RUST_TOOLCHAIN} ${target}"
done

/bin/mkdir -p "${OUTPUT_ROOT:h}"
lock_dir=${OUTPUT_ROOT:h}/.prepare-rish-android.lock
/bin/mkdir "${lock_dir}" 2>/dev/null || \
  fail "another packaging run holds ${lock_dir}; remove it only if no build is running"
lock_acquired=true

build_root=$(mktemp -d "${TMPDIR:-/tmp}/rish-android-ffi.XXXXXX")
[[ -n "${build_root}" && -d "${build_root}" ]] || fail "could not create build directory"
source_root=${build_root}/rish-source
/bin/mkdir -p "${source_root}"

# Build an immutable snapshot instead of the mutable adjacent checkout.
git -C "${RISH_ROOT}" archive --format=tar "${EXPECTED_RISH_COMMIT}" |
  /usr/bin/tar -x -C "${source_root}"
source_header=${source_root}/platform/rish.h
actual_header_sha=$(sha256_file "${source_header}")
actual_lock_sha=$(sha256_file "${source_root}/Cargo.lock")
[[ "${actual_header_sha}" == "${EXPECTED_HEADER_SHA256}" ]] || \
  fail "archived rish.h SHA-256 is ${actual_header_sha}; expected ${EXPECTED_HEADER_SHA256}"
[[ "${actual_lock_sha}" == "${EXPECTED_CARGO_LOCK_SHA256}" ]] || \
  fail "archived Cargo.lock SHA-256 is ${actual_lock_sha}; expected ${EXPECTED_CARGO_LOCK_SHA256}"

dependency_cache_root=${CARGO_HOME:-${HOME}/.cargo}
for cargo_config in "${dependency_cache_root}/config" "${dependency_cache_root}/config.toml"; do
  [[ ! -e "${cargo_config}" ]] || \
    fail "ambient Cargo config is not allowed during release packaging: ${cargo_config}"
done
unset AR CC CFLAGS CPPFLAGS CXX CXXFLAGS LD LDFLAGS RUSTFLAGS CARGO_ENCODED_RUSTFLAGS CARGO_BUILD_TARGET SDKROOT || true
unset CARGO_REGISTRIES_CRATES_IO_INDEX CARGO_REGISTRIES_CRATES_IO_PROTOCOL CARGO_NET_GIT_FETCH_WITH_CLI || true
export LC_ALL=C
export TZ=UTC
export CARGO_HOME=${dependency_cache_root}
export CARGO_TARGET_DIR=${build_root}/cargo-target
export RISH_SOURCE_REVISION=${EXPECTED_RISH_COMMIT}
export SOURCE_DATE_EPOCH=$(git -C "${RISH_ROOT}" show -s --format=%ct "${EXPECTED_RISH_COMMIT}")
# Per-target linker and archiver from the pinned NDK, plus the 16 KiB page
# alignment Android 15 requires. Scoped per target so nothing leaks into
# build scripts compiled for the host.
target_args=()
for abi in "${abis[@]}"; do
  target=${abi_targets[${abi}]}
  key=$(target_env_key "${target}")
  export "CARGO_TARGET_${key}_LINKER=${NDK_BIN}/${target}${ANDROID_API_LEVEL}-clang"
  export "CARGO_TARGET_${key}_AR=${LLVM_AR}"
  export "CARGO_TARGET_${key}_RUSTFLAGS=-C link-arg=-Wl,-z,max-page-size=16384"
  # cc-rs reads CC_<target> with the triple's hyphens spelled as underscores.
  cc_key=${target//-/_}
  export "CC_${cc_key}=${NDK_BIN}/${target}${ANDROID_API_LEVEL}-clang"
  export "AR_${cc_key}=${LLVM_AR}"
  target_args+=(--target "${target}")
done
fetch_options=(--locked)
[[ "${OFFLINE}" == 1 ]] && fetch_options+=(--offline)
(
  cd "${source_root}"
  cargo +"${build_rust_toolchain}" fetch "${fetch_options[@]}" "${target_args[@]}"
)
crate_version=$(
  cd "${source_root}"
  cargo +"${build_rust_toolchain}" metadata --frozen --no-deps --format-version 1 |
    /usr/bin/jq -r '.packages[] | select(.name == "rish-ffi") | .version'
)
[[ "${crate_version}" == "${EXPECTED_CRATE_VERSION}" ]] || \
  fail "rish-ffi version is ${crate_version}; expected ${EXPECTED_CRATE_VERSION}"

stage_root=${build_root}/stage
/bin/mkdir -p "${stage_root}/include" "${stage_root}/jniLibs"
/bin/cp "${source_header}" "${stage_root}/include/rish.h"
library_lines=()
for abi in "${abis[@]}"; do
  target=${abi_targets[${abi}]}
  print -- "building immutable rish-ffi ${EXPECTED_RISH_COMMIT} for ${abi} (${target})"
  (
    cd "${source_root}"
    cargo +"${build_rust_toolchain}" build --frozen --release --target "${target}" -p rish-ffi
  )
  built=${CARGO_TARGET_DIR}/${target}/release/librish_ffi.so
  staged_dir=${stage_root}/jniLibs/${abi}
  /bin/mkdir -p "${staged_dir}"
  /bin/cp "${built}" "${staged_dir}/librish_ffi.so"
  # Drop the local symbol table; dynamic exports the app links against stay.
  "${LLVM_STRIP}" --strip-unneeded "${staged_dir}/librish_ffi.so"
  verify_library "${staged_dir}/librish_ffi.so" "${abi}" "${abi}"
  library_lines+=("library_sha256_${abi}=$(sha256_file "${staged_dir}/librish_ffi.so")")
done

rustc_version=$(rustc +"${build_rust_toolchain}" --version)
cargo_version=$(cargo +"${build_rust_toolchain}" --version)
{
  print -- "format=1"
  print -- "source=https://github.com/ZSeven-W/rish"
  print -- "source_remote=${EXPECTED_RISH_PUBLIC_REMOTE}"
  print -- "source_snapshot=git-archive"
  print -- "commit=${EXPECTED_RISH_COMMIT}"
  print -- "crate=rish-ffi"
  print -- "crate_version=${crate_version}"
  print -- "rust_toolchain=${RUST_TOOLCHAIN}"
  print -- "rustc=${rustc_version}"
  print -- "cargo=${cargo_version}"
  print -- "cargo_dependency_mode=verified-cache-offline-frozen"
  print -- "cargo_home_config=none"
  print -- "ambient_codegen_flags=cleared"
  print -- "ndk=${ndk_version}"
  print -- "android_api_level=${ANDROID_API_LEVEL}"
  print -- "abis=${(j:,:)abis}"
  print -- "page_alignment=${EXPECTED_PAGE_ALIGNMENT}"
  print -- "symbols=stripped-unneeded"
  print -- "header_sha256=${actual_header_sha}"
  print -- "cargo_lock_sha256=${actual_lock_sha}"
  for line in "${library_lines[@]}"; do print -- "${line}"; done
  print -- "source_date_epoch=${SOURCE_DATE_EPOCH}"
} > "${stage_root}/rish_ffi.version"

# Publish atomically: copy the verified set beside the destination, then swap
# it in with rollback. The version manifest is part of the swap and acts as
# the commit marker Gradle checks for.
suffix=${$}
next_output=${OUTPUT_ROOT:h}/.rish-ffi.next.${suffix}
previous_output=${OUTPUT_ROOT:h}/.rish-ffi.previous.${suffix}
/bin/rm -rf -- "${next_output}"
/bin/cp -R "${stage_root}" "${next_output}"
for abi in "${abis[@]}"; do
  verify_library "${next_output}/jniLibs/${abi}/librish_ffi.so" "${abi}" "staged ${abi}"
done
/usr/bin/cmp -s "${source_header}" "${next_output}/include/rish.h" || \
  fail "staged rish.h differs from the pinned header"

[[ -e "${OUTPUT_ROOT}" ]] && original_output=true
publish_in_progress=true
if [[ "${original_output}" == true ]]; then
  /bin/mv "${OUTPUT_ROOT}" "${previous_output}" || fail "could not back up existing runtime staging"
fi
/bin/mv "${next_output}" "${OUTPUT_ROOT}" || fail "could not publish runtime staging"
next_output=""
[[ "$(sha256_file "${VERSION_OUTPUT}")" == "$(sha256_file "${stage_root}/rish_ffi.version")" ]] || \
  fail "published provenance hash changed"
publish_complete=true
publish_in_progress=false
/bin/rm -rf -- "${previous_output}"

print -- "prepared pinned rish Android runtime at ${OUTPUT_ROOT}"
for abi in "${abis[@]}"; do
  print -- "  ${abi}: jniLibs/${abi}/librish_ffi.so (16 KiB page aligned, API ${ANDROID_API_LEVEL})"
done
print -- "  provenance: ${VERSION_OUTPUT}"
print -- "build with: apps/gpui/android/gradlew -p apps/gpui/android :app:assembleDebug -PrishArchitectures=${(j:,:)abis}"
