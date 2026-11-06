#!/bin/zsh
# Builds OpenSSL, libssh2 and libgit2 for Android and stages them as
# modules/rish/android/rish-libgit2 for the app's JNI shim. The companion of
# prepare-libgit2-ios.sh: same sources, same pinned commits, same libgit2
# options -- except the HTTPS backend, because Android has no SecureTransport
# and OpenSSL is what is already being built here for libssh2.
#
# Requires the pinned NDK and cmake; this script never installs either.
set -euo pipefail

readonly SCRIPT_DIR=${0:A:h}
readonly APP_ROOT=${SCRIPT_DIR:h}
readonly DEPS_ROOT=${APP_ROOT}/.build/deps
readonly OUTPUT_ROOT=${APP_ROOT}/modules/rish/android/rish-libgit2

# The same pins the iOS vendor build uses. Two hosts building one library from
# two commits would be a difference nobody would see until a repository read
# disagreed across platforms.
readonly OPENSSL_REPOSITORY=https://github.com/openssl/openssl.git
readonly OPENSSL_VERSION=3.6.2
readonly OPENSSL_COMMIT=fe686e15d84334b284f883118ed92f64b409b3aa
readonly LIBSSH2_REPOSITORY=https://github.com/libssh2/libssh2.git
readonly LIBSSH2_VERSION=1.11.1
readonly LIBSSH2_COMMIT=a312b43325e3383c865a87bb1d26cb52e3292641
readonly LIBGIT2_REPOSITORY=https://github.com/libgit2/libgit2.git
readonly LIBGIT2_VERSION=1.9.6
readonly LIBGIT2_COMMIT=26055f5af74ab1cf636d272e8a34315496d3f06f

readonly EXPECTED_NDK_VERSION="27.1.12297006"
readonly ANDROID_API_LEVEL=24
readonly ABI=arm64-v8a
readonly TARGET=aarch64-linux-android

fail() {
  print -u2 -- "prepare-libgit2-android: $*"
  exit 1
}

sha256_file() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

if [[ -n ${CMAKE_BIN:-} ]]; then
  CMAKE=${CMAKE_BIN}
elif command -v cmake >/dev/null 2>&1; then
  CMAKE=$(command -v cmake)
else
  fail "cmake is required (3.24 or newer). Set CMAKE_BIN to its absolute path."
fi

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
readonly NDK_TOOLCHAIN=${ndk_root}/build/cmake/android.toolchain.cmake
[[ -f ${NDK_TOOLCHAIN} ]] || fail "NDK cmake toolchain missing: ${NDK_TOOLCHAIN}"
[[ -x ${NDK_BIN}/${TARGET}${ANDROID_API_LEVEL}-clang ]] ||
  fail "NDK compiler missing: ${NDK_BIN}/${TARGET}${ANDROID_API_LEVEL}-clang"

mkdir -p "${DEPS_ROOT}"

# Every library is checked out the same way: a bare init with a pinned remote,
# a refusal to touch a checkout that is dirty or points somewhere else, and a
# blobless fetch of exactly one commit.
checkout() {
  local root=$1 repository=$2 commit=$3 label=$4
  if [[ ! -d ${root}/.git ]]; then
    [[ ! -e ${root} || -z "$(find "${root}" -mindepth 1 -maxdepth 1 -print -quit)" ]] ||
      fail "${label} source path is not an empty checkout: ${root}"
    mkdir -p "${root}"
    git -C "${root}" init --quiet
    git -C "${root}" remote add origin "${repository}"
  fi
  local actual_remote
  actual_remote=$(git -C "${root}" remote get-url origin)
  [[ ${actual_remote} == ${repository} ]] ||
    fail "${label} source has unexpected origin: ${actual_remote}"
  [[ -z "$(git -C "${root}" status --porcelain=v1 --untracked-files=no)" ]] ||
    fail "${label} source checkout is dirty; refusing to overwrite local files"
  if ! git -C "${root}" cat-file -e "${commit}^{commit}" 2>/dev/null; then
    git -C "${root}" fetch --quiet --filter=blob:none --depth=1 origin "${commit}"
  fi
  git -C "${root}" checkout --quiet --detach "${commit}"
  [[ $(git -C "${root}" rev-parse HEAD) == ${commit} ]] ||
    fail "${label} checkout mismatch"
}

# A build is skipped when its inputs and options are unchanged; the
# fingerprint is what says so, and it names everything that would change the
# bytes.
cached() {
  local install_root=$1 fingerprint=$2 witness=$3
  [[ -f ${install_root}/.prepare-fingerprint &&
     $(<${install_root}/.prepare-fingerprint) == ${fingerprint} &&
     -f ${witness} ]]
}

# Each library gets its own checkout rather than sharing the iOS one. The
# shared tree carries that build's generated assembly -- perlasm emits a
# Mach-O flavour for Apple and a GNU one here -- and make will not regenerate
# a .S that is newer than its .pl. Excluding artefacts one kind at a time was
# how this was found twice; a separate checkout is how it stops.
readonly OPENSSL_SOURCE=${DEPS_ROOT}/openssl-src-android-checkout
readonly OPENSSL_INSTALL=${DEPS_ROOT}/openssl-android-install
readonly LIBSSH2_SOURCE=${DEPS_ROOT}/libssh2-src-android
readonly LIBSSH2_INSTALL=${DEPS_ROOT}/libssh2-android-install
readonly LIBGIT2_SOURCE=${DEPS_ROOT}/libgit2-src-android
readonly LIBGIT2_BUILD=${DEPS_ROOT}/libgit2-android-build
readonly LIBGIT2_INSTALL=${DEPS_ROOT}/libgit2-android-install

build_openssl() {
  local fingerprint="source=${OPENSSL_COMMIT};target=android-arm64;api=${ANDROID_API_LEVEL};options=no-shared,no-tests,no-apps,no-docs,no-async,no-dso,no-engine,no-zlib,no-zstd,no-legacy;march=armv8-a+crypto"
  if cached "${OPENSSL_INSTALL}" "${fingerprint}" "${OPENSSL_INSTALL}/lib/libcrypto.a"; then
    print "prepare-libgit2-android: OpenSSL is current"
    return
  fi
  checkout "${OPENSSL_SOURCE}" "${OPENSSL_REPOSITORY}" "${OPENSSL_COMMIT}" OpenSSL
  local slice=${DEPS_ROOT}/openssl-src-android
  rm -rf -- "${slice}" "${OPENSSL_INSTALL}"
  mkdir -p "${slice}"
  # The source tree is shared with the iOS vendor build, which leaves its own
  # object files in it. Copying those over means make finds a Mach-O .o newer
  # than its .S and never rebuilds it -- which links, fails, and says nothing
  # about why. Carry the source and nothing else.
  (cd "${OPENSSL_SOURCE}" && tar -cf - --exclude='./.git' \
    --exclude='*.o' --exclude='*.a' --exclude='*.d' .) | tar -x -C "${slice}"
  find "${slice}" -name '*.o' -delete
  (
    cd "${slice}"
    # OpenSSL's own Android support wants the NDK on PATH and reads
    # ANDROID_NDK_ROOT; it picks the compiler out of the toolchain itself.
    #
    # The crypto extensions have to be enabled for the assembly to assemble
    # at all. That does not require them at runtime: OpenSSL reads the
    # processor's capabilities through armcap and only dispatches to those
    # paths on a chip that has them.
    PATH="${NDK_BIN}:${PATH}" ANDROID_NDK_ROOT="${ndk_root}" \
      ./Configure android-arm64 -D__ANDROID_API__="${ANDROID_API_LEVEL}" \
        -march=armv8-a+crypto \
        no-shared no-tests no-apps no-docs no-async no-dso no-engine \
        no-zlib no-zstd no-legacy \
        --prefix="${OPENSSL_INSTALL}" --openssldir="${OPENSSL_INSTALL}/ssl"
    PATH="${NDK_BIN}:${PATH}" ANDROID_NDK_ROOT="${ndk_root}" \
      /usr/bin/make -j"$(sysctl -n hw.ncpu 2>/dev/null || echo 4)" build_sw
    PATH="${NDK_BIN}:${PATH}" ANDROID_NDK_ROOT="${ndk_root}" \
      /usr/bin/make install_sw
  ) >| "${DEPS_ROOT}/openssl-android.log" 2>&1 ||
    fail "OpenSSL build failed; see ${DEPS_ROOT}/openssl-android.log"
  [[ -f ${OPENSSL_INSTALL}/lib/libcrypto.a ]] || fail "OpenSSL produced no libcrypto.a"
  # Every member, not just the C ones: the assembly is what came out wrong.
  local stray
  stray=$("${NDK_BIN}/llvm-objdump" -f "${OPENSSL_INSTALL}/lib/libcrypto.a" 2>/dev/null |
    /usr/bin/awk '$1 == "architecture:" { print $2 }' |
    /usr/bin/sort -u | /usr/bin/grep -v '^aarch64$' || true)
  [[ -z ${stray} ]] ||
    fail "OpenSSL archive has non-aarch64 members: ${stray}"
  print -r -- "${fingerprint}" > "${OPENSSL_INSTALL}/.prepare-fingerprint"
}

# The NDK toolchain sets CMAKE_FIND_ROOT_PATH_MODE_* to ONLY, so a find
# module will not look at a host path however it is pointed there. Naming the
# files is what actually works.
OPENSSL_CMAKE_ARGS=(
  "-DOPENSSL_ROOT_DIR=${OPENSSL_INSTALL}"
  "-DOPENSSL_INCLUDE_DIR=${OPENSSL_INSTALL}/include"
  "-DOPENSSL_CRYPTO_LIBRARY=${OPENSSL_INSTALL}/lib/libcrypto.a"
  "-DOPENSSL_SSL_LIBRARY=${OPENSSL_INSTALL}/lib/libssl.a"
  "-DOPENSSL_USE_STATIC_LIBS=ON"
  "-DCMAKE_FIND_ROOT_PATH=${OPENSSL_INSTALL}"
)

configure_android() {
  "${CMAKE}" "$@" \
    -DCMAKE_TOOLCHAIN_FILE="${NDK_TOOLCHAIN}" \
    -DANDROID_ABI="${ABI}" \
    -DANDROID_PLATFORM="android-${ANDROID_API_LEVEL}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF
}

build_libssh2() {
  local fingerprint="source=${LIBSSH2_COMMIT};openssl=${OPENSSL_COMMIT};abi=${ABI};api=${ANDROID_API_LEVEL}"
  if cached "${LIBSSH2_INSTALL}" "${fingerprint}" "${LIBSSH2_INSTALL}/lib/libssh2.a"; then
    print "prepare-libgit2-android: libssh2 is current"
    return
  fi
  checkout "${LIBSSH2_SOURCE}" "${LIBSSH2_REPOSITORY}" "${LIBSSH2_COMMIT}" libssh2
  local build=${DEPS_ROOT}/libssh2-android-build
  rm -rf -- "${build}" "${LIBSSH2_INSTALL}"
  configure_android -S "${LIBSSH2_SOURCE}" -B "${build}" -G "Unix Makefiles" \
    -DCMAKE_INSTALL_PREFIX="${LIBSSH2_INSTALL}" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCRYPTO_BACKEND=OpenSSL \
    ${(@)OPENSSL_CMAKE_ARGS} \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_TESTING=OFF \
    -DENABLE_ZLIB_COMPRESSION=OFF \
    >| "${DEPS_ROOT}/libssh2-android.log" 2>&1 ||
    fail "libssh2 configure failed; see ${DEPS_ROOT}/libssh2-android.log"
  "${CMAKE}" --build "${build}" --parallel \
    >> "${DEPS_ROOT}/libssh2-android.log" 2>&1 ||
    fail "libssh2 build failed; see ${DEPS_ROOT}/libssh2-android.log"
  "${CMAKE}" --install "${build}" >> "${DEPS_ROOT}/libssh2-android.log" 2>&1 ||
    fail "libssh2 install failed; see ${DEPS_ROOT}/libssh2-android.log"
  [[ -f ${LIBSSH2_INSTALL}/lib/libssh2.a ]] || fail "libssh2 produced no archive"
  print -r -- "${fingerprint}" > "${LIBSSH2_INSTALL}/.prepare-fingerprint"
}

build_libgit2() {
  local fingerprint="source=${LIBGIT2_COMMIT};ssh=${LIBSSH2_COMMIT};openssl=${OPENSSL_COMMIT};abi=${ABI};api=${ANDROID_API_LEVEL};https=OpenSSL"
  if cached "${LIBGIT2_INSTALL}" "${fingerprint}" "${LIBGIT2_INSTALL}/lib/libgit2.a"; then
    print "prepare-libgit2-android: libgit2 is current"
    return
  fi
  checkout "${LIBGIT2_SOURCE}" "${LIBGIT2_REPOSITORY}" "${LIBGIT2_COMMIT}" libgit2
  rm -rf -- "${LIBGIT2_BUILD}" "${LIBGIT2_INSTALL}"
  # Every option matches the iOS build except USE_HTTPS: there is no
  # SecureTransport here, and OpenSSL is already built for libssh2.
  configure_android -S "${LIBGIT2_SOURCE}" -B "${LIBGIT2_BUILD}" -G "Unix Makefiles" \
    -DCMAKE_C_FLAGS=-DZ_PREFIX \
    -DCMAKE_INSTALL_PREFIX="${LIBGIT2_INSTALL}" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DBUILD_TESTS=OFF \
    -DBUILD_CLI=OFF \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_FUZZERS=OFF \
    -DUSE_HTTPS=OpenSSL \
    -DUSE_SSH=libssh2 \
    -DPKG_CONFIG_EXECUTABLE=/usr/bin/false \
    ${(@)OPENSSL_CMAKE_ARGS} \
    -DLIBSSH2_INCLUDE_DIR="${LIBSSH2_INSTALL}/include" \
    -DLIBSSH2_LIBRARY="${LIBSSH2_INSTALL}/lib/libssh2.a" \
    -DUSE_GSSAPI=OFF \
    -DUSE_NTLMCLIENT=OFF \
    -DUSE_ICONV=OFF \
    -DUSE_BUNDLED_ZLIB=ON \
    -DREGEX_BACKEND=builtin \
    -DUSE_HTTP_PARSER=builtin \
    -DUSE_SHA1=CollisionDetection \
    -DUSE_SHA256=HTTPS \
    >| "${DEPS_ROOT}/libgit2-android.log" 2>&1 ||
    fail "libgit2 configure failed; see ${DEPS_ROOT}/libgit2-android.log"
  "${CMAKE}" --build "${LIBGIT2_BUILD}" --parallel \
    >> "${DEPS_ROOT}/libgit2-android.log" 2>&1 ||
    fail "libgit2 build failed; see ${DEPS_ROOT}/libgit2-android.log"
  "${CMAKE}" --install "${LIBGIT2_BUILD}" >> "${DEPS_ROOT}/libgit2-android.log" 2>&1 ||
    fail "libgit2 install failed; see ${DEPS_ROOT}/libgit2-android.log"
  local features=${LIBGIT2_BUILD}/gen_headers/git2_features.h
  [[ -f ${features} ]] || fail "libgit2 feature header is missing"
  /usr/bin/grep -q '^#define GIT_SSH_LIBSSH2 1$' "${features}" ||
    fail "libgit2 was built without the libssh2 SSH feature"
  /usr/bin/grep -q '^#define GIT_HTTPS 1$' "${features}" ||
    fail "libgit2 was built without an HTTPS backend"
  print -r -- "${fingerprint}" > "${LIBGIT2_INSTALL}/.prepare-fingerprint"
}

# The symbols the project context service actually calls, so a library that
# built but cannot answer is caught here rather than at runtime.
verify_archive() {
  local archive=$1
  [[ -f ${archive} ]] || fail "libgit2 archive is missing"
  # An archive is not an ELF file, so the format is read off its members.
  local architectures
  architectures=$("${NDK_BIN}/llvm-objdump" -f "${archive}" 2>/dev/null |
    /usr/bin/awk '$1 == "architecture:" { print $2 }' |
    /usr/bin/sort -u | /usr/bin/tr '\n' ' ' | /usr/bin/sed 's/[[:space:]]*$//')
  [[ ${architectures} == "aarch64" ]] ||
    fail "libgit2 archive members are ${architectures:-unknown}, expected aarch64"
  # One read of the symbol table, because `grep -q` closing the pipe early
  # makes llvm-nm see SIGPIPE and `pipefail` calls that a failure.
  local symbols
  symbols=$("${NDK_BIN}/llvm-nm" --defined-only "${archive}" 2>/dev/null || true)
  [[ -n ${symbols} ]] || fail "libgit2 archive has no readable symbol table"
  for symbol in git_libgit2_init git_repository_open git_status_list_new \
    git_diff_tree_to_index git_diff_index_to_workdir git_diff_find_similar \
    git_index_checksum git_blob_rawcontent git_commit_tree; do
    print -r -- "${symbols}" |
      /usr/bin/grep "[[:space:]]${symbol}\$" >/dev/null ||
      fail "libgit2 archive is missing ${symbol}"
  done
  # The bundled zlib is built with Z_PREFIX so it cannot displace the
  # platform zlib the runtime uses to unpack environment packages.
  print -r -- "${symbols}" |
    /usr/bin/grep "[[:space:]]z_inflate\$" >/dev/null ||
    fail "libgit2 archive is missing the private zlib symbol z_inflate"
  if print -r -- "${symbols}" |
    /usr/bin/grep "[[:space:]]inflateInit2_\$" >/dev/null; then
    fail "libgit2 archive exports an unprefixed zlib symbol"
  fi
}

build_openssl
build_libssh2
build_libgit2
verify_archive "${LIBGIT2_INSTALL}/lib/libgit2.a"

staging=$(mktemp -d "${DEPS_ROOT}/.libgit2-android-stage.XXXXXX")
trap 'rm -rf -- "${staging}"' EXIT
mkdir -p "${staging}/${ABI}" "${staging}/include"
cp "${LIBGIT2_INSTALL}/lib/libgit2.a" "${staging}/${ABI}/libgit2.a"
cp "${LIBSSH2_INSTALL}/lib/libssh2.a" "${staging}/${ABI}/libssh2.a"
cp "${OPENSSL_INSTALL}/lib/libcrypto.a" "${staging}/${ABI}/libcrypto.a"
cp "${OPENSSL_INSTALL}/lib/libssl.a" "${staging}/${ABI}/libssl.a"
cp -R "${LIBGIT2_INSTALL}/include/." "${staging}/include/"

rm -rf -- "${OUTPUT_ROOT}"
mkdir -p "${OUTPUT_ROOT:h}"
mv "${staging}" "${OUTPUT_ROOT}"
trap - EXIT

version_file=${OUTPUT_ROOT}/libgit2.version
{
  print -r -- "format=1"
  print -r -- "source=${LIBGIT2_REPOSITORY}"
  print -r -- "version=${LIBGIT2_VERSION}"
  print -r -- "commit=${LIBGIT2_COMMIT}"
  print -r -- "https=OpenSSL"
  print -r -- "ssh=libssh2"
  print -r -- "crypto=OpenSSL"
  print -r -- "zlib=bundled-z-prefix"
  print -r -- "libssh2_version=${LIBSSH2_VERSION}"
  print -r -- "libssh2_commit=${LIBSSH2_COMMIT}"
  print -r -- "openssl_version=${OPENSSL_VERSION}"
  print -r -- "openssl_commit=${OPENSSL_COMMIT}"
  print -r -- "redirect_policy=caller-enforced-none"
  print -r -- "ndk=${EXPECTED_NDK_VERSION}"
  print -r -- "android_api=${ANDROID_API_LEVEL}"
  print -r -- "architectures=${ABI}"
  print -r -- "libgit2_library_sha256=$(sha256_file "${OUTPUT_ROOT}/${ABI}/libgit2.a")"
  print -r -- "libssh2_library_sha256=$(sha256_file "${OUTPUT_ROOT}/${ABI}/libssh2.a")"
  print -r -- "openssl_library_sha256=$(sha256_file "${OUTPUT_ROOT}/${ABI}/libcrypto.a")"
  print -r -- "header_version_sha256=$(sha256_file "${OUTPUT_ROOT}/include/git2/version.h")"
} > "${version_file}"

print "prepare-libgit2-android: staged libgit2 ${LIBGIT2_VERSION} at ${OUTPUT_ROOT}"
