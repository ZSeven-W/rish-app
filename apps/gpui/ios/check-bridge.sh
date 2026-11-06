#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")" && pwd)
core="$root/../../../modules/rish/core"
python3 "$root/generate-exports.py" --check
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/rish-gpui-bridge.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT
common=(-fobjc-arc -fblocks -I "$root/Native" -I "$root/Sources" -I "$core/include")
xcrun --sdk macosx clang "${common[@]}" -framework Foundation \
  "$root/Sources/RishGPUIBridge.m" "$root/Sources/RishEventEmitter.m" \
  "$root/Tests/BridgeTests.m" -o "$build_dir/bridge-tests"
"$build_dir/bridge-tests"
xcrun --sdk macosx clang "${common[@]}" -framework Foundation \
  "$root/Sources/RishFileEditorValidation.m" "$root/Tests/FileEditorValidationTests.m" \
  -o "$build_dir/file-editor-tests"
"$build_dir/file-editor-tests"
# Exercise the same name policy as the app; a mock could silently drift
# from filesystem naming rules. This is a host-only core build, not an iOS app.
cargo build --locked --manifest-path "$core/Cargo.toml" -p rish-agent-ffi --target-dir "$core/target"
xcrun --sdk macosx clang "${common[@]}" -framework Foundation -framework Security \
  "$root/Sources/ShellWorkspaceModule.m" "$root/Sources/RishNameValidation.m" \
  "$root/Tests/DefaultWorkspaceTests.m" "$core/target/debug/librish_agent_ffi.a" \
  -o "$build_dir/default-workspace-tests"
"$build_dir/default-workspace-tests"
xcrun --sdk macosx clang "${common[@]}" -framework Foundation -framework Security \
  "$root/Sources/RishNameValidation.m" "$root/Tests/NameValidationTests.m" \
  "$core/target/debug/librish_agent_ffi.a" -o "$build_dir/name-tests"
"$build_dir/name-tests"
for sdk in iphonesimulator iphoneos; do
  target=arm64-apple-ios16.0
  [[ $sdk != iphonesimulator ]] || target=arm64-apple-ios16.0-simulator
  xcrun --sdk "$sdk" clang "${common[@]}" -fsyntax-only -target "$target" \
    "$root/Sources/RishGPUIBridge.m" "$root/Sources/RishEventEmitter.m" \
    "$root/Sources/ShellInputModule.m" "$root/Sources/RishNameController.m" \
    "$root/Sources/RishComposerController.m" "$root/Sources/ShellWorkspaceModule.m" \
    "$root/Sources/RishInlineComposer.m" "$root/Sources/RishInlineComposerValidation.m" \
    "$root/Sources/RishFileEditorController.m" "$root/Sources/RishFileEditorValidation.m" \
    "$root/Sources/RishGitFormController.m" "$root/Sources/RishGitFormValidation.mm" \
    "$root/Sources/RishNameValidation.m" "$root/Sources/LayoutMetrics.m" "$root/Sources/main.m"
done
printf '%s\n' 'PASS: native host syntax checked for iOS device and simulator'
