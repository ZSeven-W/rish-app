#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
# Independent opt-in service lane. Reuses installed build products and immutable
# released packages; it never runs the existing six-program lane or downloads.
[[ ${RISH_RUNTIME_SERVICES_LIVE:-} == 1 ]] || {
  echo 'Set RISH_RUNTIME_SERVICES_LIVE=1 to enable the real six-language HTTP gate.' >&2; exit 1;
}
[[ $# == 0 || ( $# == 1 && $1 == --prepare-only ) ]] || { echo 'Usage: test-ios-runtime-services.sh [--prepare-only]' >&2; exit 1; }
fixture=${RISH_RUNTIME_ENVIRONMENTS_FIXTURE_DIR:-"$PWD/.build/runtime-environment-fixtures"}
sources="$PWD/scripts/tests/fixtures/runtime-services"
output=${RISH_RUNTIME_SERVICES_OUTPUT_DIR:-"$PWD/.build/runtime-service-tests/$(date -u +%Y%m%dT%H%M%SZ)-$$"}
if [[ -n ${RISH_RUNTIME_SERVICES_XCTESTRUN:-} ]]; then
  plan=$RISH_RUNTIME_SERVICES_XCTESTRUN
else
  plans=("$PWD"/.build/preview-tests/DerivedData/Build/Products/*.xctestrun)
  [[ ${#plans[@]} == 1 && -f ${plans[0]} ]] || {
    echo 'Set RISH_RUNTIME_SERVICES_XCTESTRUN to the already-built simulator test plan containing AgentRuntimeServiceLiveTests.' >&2; exit 1;
  }
  plan=${plans[0]}
fi
mkdir -p "$output"
python3 - "$plan" "$output/RuntimeServices.xctestrun" "$fixture" "$sources" "$PWD/runtime-environments/catalog.json" "$PWD/scripts/ci/prepare-runtime-fixtures.py" <<'PY'
import hashlib, importlib.util, json, pathlib, plistlib, re, stat, sys
original, target, fixture, sources, catalog, verifier = map(pathlib.Path, sys.argv[1:])
if not original.is_file(): raise SystemExit('The existing xctestrun is missing; build the new test class first.')
if not fixture.is_absolute() or not sources.is_absolute(): raise SystemExit('Fixture paths must be absolute.')
if fixture.is_symlink() or not fixture.is_dir(): raise SystemExit('Fixture directory must be a real directory.')
manifest_path = fixture / 'fixture.json'
if manifest_path.is_symlink() or manifest_path.stat().st_size > 65536: raise SystemExit('Invalid fixture manifest.')
manifest = json.loads(manifest_path.read_bytes())
spec = importlib.util.spec_from_file_location('runtime_fixture_pinning', verifier)
pinning = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pinning)
pinning.validate_fixture_catalog(manifest, json.loads(catalog.read_bytes()))
if set(manifest) != {'schema_version', 'packages'} or type(manifest['schema_version']) is not int or manifest['schema_version'] != 1:
    raise SystemExit('Unsupported fixture manifest.')
expected = {'python':'python.py', 'java':'Main.java', 'go':'go.go', 'rust':'rust.rs', 'bun':'bun.js', 'node':'node.js'}
seen, files, ids = set(), set(), set()
records = manifest['packages']
if not isinstance(records, list) or len(records) != 6: raise SystemExit('Exactly six package records are required.')
for record in records:
    if not isinstance(record, dict) or set(record) != {'family','file','environment_id','package_sha256','package_bytes'}:
        raise SystemExit('Unexpected package fields.')
    family, filename, environment, digest, size = (record[k] for k in ('family','file','environment_id','package_sha256','package_bytes'))
    if family not in expected or family in seen or filename in files or environment in ids:
        raise SystemExit('Unknown or duplicate package identity.')
    if not isinstance(filename, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,159}\.rishenv', filename):
        raise SystemExit('Unsafe package filename.')
    if not isinstance(environment, str) or not re.fullmatch(r'[a-z0-9-]{1,96}', environment): raise SystemExit('Invalid environment ID.')
    if not isinstance(digest, str) or not re.fullmatch(r'[0-9a-f]{64}', digest): raise SystemExit('Invalid package digest.')
    if type(size) is not int or not 0 < size <= 768 * 1024 * 1024: raise SystemExit('Invalid package size.')
    package = fixture / filename
    info = package.lstat()
    if not stat.S_ISREG(info.st_mode) or package.is_symlink() or info.st_size != size: raise SystemExit(f'Missing/changed package: {filename}')
    with package.open('rb') as stream:
        hasher = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b''): hasher.update(chunk)
        actual = hasher.hexdigest()
    if actual != digest: raise SystemExit(f'Package digest mismatch: {filename}')
    source = sources / expected[family]
    if source.is_symlink() or not source.is_file() or not 0 < source.stat().st_size <= 32768:
        raise SystemExit(f'Missing or oversized language HTTP source: {source}')
    seen.add(family); files.add(filename); ids.add(environment)
if seen != set(expected): raise SystemExit('One or more language fixtures are missing.')
config = plistlib.loads(original.read_bytes())
test_root = str(original.resolve().parent)
def expand(value):
    if isinstance(value, str): return value.replace('__TESTROOT__', test_root)
    if isinstance(value, dict): return {key:expand(child) for key,child in value.items()}
    if isinstance(value, list): return [expand(child) for child in value]
    return value
config = expand(config)
updated = 0
def visit(value):
    global updated
    if isinstance(value, dict):
        if 'TestBundlePath' in value:
            if value.get('BlueprintName') != 'RishTests': return
            value.setdefault('EnvironmentVariables', {}).update({
                'RISH_RUNTIME_SERVICES_LIVE':'1',
                'RISH_RUNTIME_ENVIRONMENTS_FIXTURE_DIR':str(fixture),
                'RISH_RUNTIME_SERVICES_SOURCE_DIR':str(sources),
            })
            value['EnvironmentVariables'].pop('RISH_RUNTIME_ENVIRONMENTS_LIVE', None)
            value['EnvironmentVariables'].pop('RISH_RUNTIME_SERVICES_DIAGNOSTIC_FIXTURE', None)
            value['OnlyTestIdentifiers'] = ['AgentRuntimeServiceLiveTests']
            value.pop('SkipTestIdentifiers', None)
            updated += 1
        else:
            for child in value.values(): visit(child)
    elif isinstance(value, list):
        for child in value: visit(child)
visit(config)
if updated != 1: raise SystemExit(f'Expected one RishTests target, found {updated}.')
target.write_bytes(plistlib.dumps(config))
print(f'Prepared immutable-package service gate: {target}')
PY
[[ ${1:-} != --prepare-only ]] || exit 0
xcrun simctl list devices available --json > "$output/devices.json"
device=${RISH_RUNTIME_SERVICES_DEVICE_ID:-$(python3 - "$output/devices.json" <<'PY'
import json, sys
for runtime, devices in sorted(json.load(open(sys.argv[1]))['devices'].items(), reverse=True):
    if '.iOS-' not in runtime: continue
    eligible = [d for d in devices if d.get('isAvailable') and d['name'].startswith('iPhone')]
    eligible.sort(key=lambda d: d.get('state') != 'Booted')
    if eligible: print(eligible[0]['udid']); break
else: raise SystemExit('No available iPhone simulator.')
PY
)}
booted_here=0
if ! python3 - "$output/devices.json" "$device" <<'PY'
import json, sys
state = next((d['state'] for group in json.load(open(sys.argv[1]))['devices'].values() for d in group if d['udid'] == sys.argv[2]), None)
sys.exit(0 if state == 'Booted' else 1)
PY
then
  xcrun simctl boot "$device"
  booted_here=1
fi
trap 'if [[ $booted_here == 1 ]]; then xcrun simctl shutdown "$device" >/dev/null 2>&1 || true; fi' EXIT
xcrun simctl bootstatus "$device" -b
xcodebuild test-without-building -xctestrun "$output/RuntimeServices.xctestrun" \
  -destination "id=$device" -parallel-testing-enabled NO \
  -resultBundlePath "$output/RuntimeServices.xcresult" \
  -only-testing:RishTests/AgentRuntimeServiceLiveTests | tee "$output/xcodebuild.log"
xcrun xcresulttool get test-results tests --path "$output/RuntimeServices.xcresult" --compact > "$output/tests.json"
python3 - "$output/tests.json" <<'PY'
import json, re, sys
required = {f'test{family}AgentRuntimeServiceServesAndStops' for family in ('Python','Java','Go','Rust','Bun','Node')}
found = {name:[] for name in required}
unexpected = []
def visit(node):
    if node.get('nodeType') == 'Test Case':
        name = re.split(r'[./]', node.get('name','').removesuffix('()'))[-1]
        if name in found: found[name].append(node.get('result'))
        else: unexpected.append(node.get('name'))
    for child in node.get('children',[]): visit(child)
for node in json.load(open(sys.argv[1]))['testNodes']: visit(node)
if unexpected or any(results != ['Passed'] for results in found.values()):
    raise SystemExit(f'All six exact service cases must run once and pass; observed={found}, unexpected={unexpected}')
print('Six real Agent language HTTP services passed GET/query, dynamic POST, persistent counter and cross-attempt stop.')
PY
