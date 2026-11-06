#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
fixture="$PWD/.build/runtime-environment-fixtures"
output="$PWD/.build/runtime-environment-tests"
mkdir -p "$output"
python3 scripts/ci/prepare-runtime-fixtures.py --output "$fixture"
plans=("$PWD"/.build/preview-tests/DerivedData/Build/Products/*.xctestrun)
[[ ${#plans[@]} == 1 && -f "${plans[0]}" ]] || { echo 'Run scripts/ci/test-ios-preview.sh to build the GPUI Release simulator test host first.' >&2; exit 1; }
device=$(python3 - "$PWD/.build/preview-tests/devices.json" <<'PY'
import json, sys
for runtime, devices in sorted(json.load(open(sys.argv[1]))['devices'].items(), reverse=True):
    if '.iOS-' not in runtime: continue
    for device in devices:
        if device['name'].startswith('iPhone') and device.get('isAvailable'):
            print(device['udid']); sys.exit(0)
raise SystemExit('No available iPhone simulator')
PY
)
xcrun simctl boot "$device" || true
xcrun simctl bootstatus "$device" -b
trap 'xcrun simctl shutdown "$device" >/dev/null 2>&1 || true' EXIT
python3 - "${plans[0]}" "$output/Runtime.xctestrun" "$fixture" <<'PY'
import pathlib, plistlib, sys
config = plistlib.loads(pathlib.Path(sys.argv[1]).read_bytes())
test_root = str(pathlib.Path(sys.argv[1]).resolve().parent)
def expand_test_root(value):
    if isinstance(value, str): return value.replace('__TESTROOT__', test_root)
    if isinstance(value, dict): return {key: expand_test_root(child) for key, child in value.items()}
    if isinstance(value, list): return [expand_test_root(child) for child in value]
    return value
# The modified plan lives outside Build/Products, so preserve Xcode's original
# relative product root before moving it to the execution-evidence directory.
config = expand_test_root(config)
updated = 0
def visit(value):
    global updated
    if isinstance(value, dict):
        if 'TestBundlePath' in value:
            value.setdefault('EnvironmentVariables', {}).update({
                'RISH_RUNTIME_ENVIRONMENTS_LIVE': '1',
                'RISH_RUNTIME_ENVIRONMENTS_FIXTURE_DIR': sys.argv[3],
            })
            value['OnlyTestIdentifiers'] = ['RuntimeEnvironmentLiveTests']
            value.pop('SkipTestIdentifiers', None)
            updated += 1
        else:
            for child in value.values(): visit(child)
    elif isinstance(value, list):
        for child in value: visit(child)
visit(config)
if not updated: raise SystemExit('No test target in xctestrun')
pathlib.Path(sys.argv[2]).write_bytes(plistlib.dumps(config))
PY
xcodebuild test-without-building -xctestrun "$output/Runtime.xctestrun" \
  -destination "id=$device" -parallel-testing-enabled NO \
  -resultBundlePath "$output/Runtime.xcresult" \
  -only-testing:RishTests/RuntimeEnvironmentLiveTests
xcrun xcresulttool get test-results tests --path "$output/Runtime.xcresult" --compact > "$output/tests.json"
python3 - "$output/tests.json" <<'PY'
import json, sys
required = {
    'testPythonEnvironmentExecutesAndReallyStopsInfiniteProgram',
    'testJavaEnvironmentExecutesWorkspaceSource',
    'testGoEnvironmentCompilesAndExecutesWorkspaceSource',
    'testRustEnvironmentCompilesAndExecutesWorkspaceSource',
    'testBunEnvironmentExecutesWorkspaceSource',
    'testNodeEnvironmentExecutesWorkspaceSource',
}
found = {name: [] for name in required}
def visit(node):
    if node.get('nodeType') == 'Test Case':
        for name in required:
            if name in node.get('name', ''): found[name].append(node.get('result'))
    for child in node.get('children', []): visit(child)
for node in json.load(open(sys.argv[1]))['testNodes']: visit(node)
if any(results != ['Passed'] for results in found.values()):
    raise SystemExit(f'All six real language cases must run and pass; observed: {found}')
print('All six installed environments executed through the real native program service; Python stop passed.')
PY
