#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
repo=$PWD
output=${RISH_ASSISTANT_ACTOR_OUTPUT:-"$repo/.build/assistant-actor-contract"}
device=${RISH_ASSISTANT_ACTOR_DEVICE_ID:?Set RISH_ASSISTANT_ACTOR_DEVICE_ID to an isolated simulator.}
vendor=${RISH_GPUI_NATIVE_VENDOR:-"$repo/.build/gpui-native-smoke/modules/rish/ios/Vendor"}
include=${RISH_GPUI_NATIVE_INCLUDE:-"$repo/.build/gpui-native-smoke/modules/rish/ios/include"}
target=${RISH_NATIVE_TEST_CARGO_TARGET_DIR:-"$output/target"}
derived=${RISH_ASSISTANT_ACTOR_DERIVED_DATA:-"$output/DerivedData"}
test_name=AssistantActorNativeTests/testProcessAssistantReadsRealFileThenPersistsMissingCredentialFailure
mkdir -p "$output"
CARGO_INCREMENTAL=0 cargo build --locked --offline --manifest-path scripts/native-tests/assistant-actor-harness/Cargo.toml --target-dir "$target"
RISH_ASSISTANT_ACTOR_OUTPUT="$output" "$target/debug/rish-assistant-actor-harness" > "$output/harness.log" 2>&1 &
harness_pid=$!
trap 'kill "$harness_pid" 2>/dev/null || true' EXIT
for _ in $(seq 1 100); do
  [[ -s "$output/harness.log" ]] && break
  kill -0 "$harness_pid" 2>/dev/null || { cat "$output/harness.log" >&2; exit 1; }
  sleep 0.05
done
url=$(head -n 1 "$output/harness.log")
[[ $url == http://127.0.0.1:* ]] || { echo 'Local actor harness failed to start' >&2; exit 1; }
if [[ -z ${RISH_ASSISTANT_ACTOR_XCTESTRUN:-} ]]; then
  xcodegen generate --spec apps/gpui/ios/project.yml
  xcodebuild build-for-testing -project apps/gpui/ios/RishGPUI.xcodeproj -scheme RishGPUI \
    -configuration Debug -destination "id=$device" -derivedDataPath "$derived" \
    RISH_NATIVE_VENDOR="$vendor" RISH_NATIVE_INCLUDE="$include" \
    RISH_GUEST_CGI_ENABLED="${RISH_IOS_GUEST_CGI_ENABLED:-0}" \
    CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=YES \
    -only-testing:"RishTests/$test_name" > "$output/build.log" 2>&1
  sdk=$(xcrun --sdk iphonesimulator --show-sdk-version)
  plans=("$derived"/Build/Products/RishGPUI_iphonesimulator"$sdk"-*.xctestrun)
  [[ ${#plans[@]} == 1 && -f ${plans[0]} ]] || { echo 'Expected one test plan' >&2; exit 1; }
  plan=${plans[0]}
else
  plan=$RISH_ASSISTANT_ACTOR_XCTESTRUN
fi
python3 - "$plan" "$output/AssistantActor.xctestrun" "$url" "$test_name" <<'PY'
import pathlib, plistlib, sys
source, target = map(pathlib.Path, sys.argv[1:3])
def expand(value):
    if isinstance(value,str): return value.replace('__TESTROOT__',str(source.resolve().parent))
    if isinstance(value,list): return [expand(v) for v in value]
    if isinstance(value,dict): return {k:expand(v) for k,v in value.items()}
    return value
data = expand(plistlib.loads(source.read_bytes())); found = 0
def visit(value):
    global found
    if isinstance(value,dict):
        if value.get('BlueprintName') == 'RishTests' and 'TestBundlePath' in value:
            value.setdefault('EnvironmentVariables',{})['RISH_SHELL_AGENT_HARNESS_URL'] = sys.argv[3]
            value['OnlyTestIdentifiers'] = [sys.argv[4]]
            value.pop('SkipTestIdentifiers',None); found += 1
        else:
            for child in value.values(): visit(child)
    elif isinstance(value,list):
        for child in value: visit(child)
visit(data)
if found != 1: raise SystemExit('Expected one RishTests target')
target.write_bytes(plistlib.dumps(data))
PY
result="$output/AssistantActor-$(date -u +%Y%m%dT%H%M%SZ).xcresult"
set +e
xcodebuild test-without-building -xctestrun "$output/AssistantActor.xctestrun" \
  -destination "id=$device" -parallel-testing-enabled NO -collect-test-diagnostics never \
  -resultBundlePath "$result" -only-testing:"RishTests/$test_name" | tee "$output/test.log"
test_status=$?
set -e
xcrun xcresulttool get test-results tests --path "$result" --compact > "$output/tests.json"
python3 - "$output/tests.json" <<'PY'
import json, sys
found=[]
def visit(node):
    if node.get('nodeType') == 'Test Case': found.append((node.get('name'),node.get('result')))
    for child in node.get('children',[]): visit(child)
for node in json.load(open(sys.argv[1]))['testNodes']: visit(node)
if len(found)!=1 or found[0][1]!='Passed' or 'testProcessAssistantReadsRealFileThenPersistsMissingCredentialFailure' not in found[0][0]:
    raise SystemExit(f'Expected exactly one passed actor/native gate, no skip: {found}')
print('PASS: actual process actor -> real iOS read/completion and missing-credential terminal persistence')
PY
exit "$test_status"
