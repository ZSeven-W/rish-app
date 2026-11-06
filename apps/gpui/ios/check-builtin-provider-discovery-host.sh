#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 1 || ! -f "$1" ]]; then
  printf '%s\n' 'Usage: check-builtin-provider-discovery-host.sh PATH_TO_MACOS_librish_agent_ffi.a' >&2
  exit 2
fi

# The caller supplies the current macOS Rust library. This script neither
# rebuilds dependencies nor boots/installs anything in a simulator.
core_library=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
root=$(cd "$(dirname "$0")" && pwd)
native="$root/../../../modules/rish/ios"
core="$root/../../../modules/rish/core"
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/rish-builtin-model-bridge.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT

xcrun --sdk macosx clang++ -std=c++20 -fobjc-arc -fblocks \
  -I "$native/Sources" -I "$core/include" -I "$root/Native" \
  -framework Foundation -framework Security -framework SystemConfiguration \
  "$native/Sources/ProviderConfiguration.mm" \
  "$native/Sources/RishHarnessCatalog.mm" \
  "$native/Sources/CustomProviderModelDiscovery.mm" \
  "$native/Sources/SessionWorkspaceCoordinator.mm" \
  "$root/Tests/BuiltinProviderDiscoveryBridgeHostTests.mm" \
  "$core_library" -o "$build_dir/builtin-provider-bridge-tests"

# Real local HTTP + shared Rust policy; all credential bytes are synthetic and
# the production bridge's Keychain read is substituted only in this test TU.
"$build_dir/builtin-provider-bridge-tests"
