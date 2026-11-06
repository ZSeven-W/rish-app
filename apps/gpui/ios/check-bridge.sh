#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")" && pwd)
core="$root/../../../modules/rish/core"
native="$root/../../../modules/rish/ios"
python3 "$root/generate-exports.py" --check
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/rish-gpui-bridge.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT
common=(-fobjc-arc -fblocks -I "$root/Native" -I "$root/Sources" -I "$core/include" -I "$native/Sources")
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
swift_sources=(
  "$root/Sources/RishTaskExperienceBridge.swift"
  "$native/TaskExperience/TaskExperience.swift"
  "$native/TaskExperience/TaskBackgroundExecution.swift"
  "$native/TaskExperience/TaskAlertPolicy.swift"
  "$native/TaskExperience/Widget/TaskAttributes.swift"
)
for sdk in iphonesimulator iphoneos; do
  target=arm64-apple-ios16.0
  [[ $sdk != iphonesimulator ]] || target=arm64-apple-ios16.0-simulator
  # main.m imports the generated Swift interface; check the real bridge sources
  # with the same language version as the application instead of a header stub.
  mkdir -p "$build_dir/$sdk"
  xcrun --sdk "$sdk" swiftc -swift-version 5 -parse-as-library -emit-module \
    -sdk "$(xcrun --sdk "$sdk" --show-sdk-path)" -target "$target" \
    -module-name RishGPUI -emit-module-path "$build_dir/$sdk/RishGPUI.swiftmodule" \
    -emit-objc-header-path "$build_dir/$sdk/RishGPUI-Swift.h" "${swift_sources[@]}"
  xcrun --sdk "$sdk" clang "${common[@]}" -I "$build_dir/$sdk" -fsyntax-only -target "$target" \
    "$root/Sources/RishGPUIBridge.m" "$root/Sources/RishEventEmitter.m" \
    "$root/Sources/ShellInputModule.m" "$root/Sources/RishNameController.m" \
    "$root/Sources/RishComposerController.m" "$root/Sources/ShellWorkspaceModule.m" \
    "$root/Sources/RishInlineComposer.m" "$root/Sources/RishInlineComposerValidation.m" \
    "$root/Sources/RishFileEditorController.m" "$root/Sources/RishFileEditorValidation.m" \
    "$root/Sources/RishGitFormController.m" "$root/Sources/RishGitFormValidation.mm" \
    "$root/Sources/RishNameValidation.m" "$root/Sources/LayoutMetrics.m" "$root/Sources/main.m"
done
printf '%s\n' 'PASS: native host syntax checked for iOS device and simulator'
