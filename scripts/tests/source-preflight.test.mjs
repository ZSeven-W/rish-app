import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import test from 'node:test';
import {auditSource, requiredFiles} from '../verify-source-checkout.mjs';

const checkout = fileURLToPath(new URL('../..', import.meta.url));
function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'rish-source-preflight-'));
  t.after(() => fs.rmSync(root, {recursive: true, force: true}));
  for (const file of requiredFiles) {
    fs.mkdirSync(path.dirname(path.join(root, file)), {recursive: true});
    fs.copyFileSync(path.join(checkout, file), path.join(root, file));
  }
  return root;
}
function edit(root, file, transform) {
  const absolute = path.join(root, file);
  fs.writeFileSync(absolute, transform(fs.readFileSync(absolute, 'utf8')));
}

test('minimal GPUI source archive passes without Git, Cargo cache, generated project or native libraries', t => {
  assert.deepEqual(auditSource(fixture(t)), []);
});
test('missing GPUI host source is rejected', t => {
  const root = fixture(t);
  fs.unlinkSync(path.join(root, 'apps/gpui/ios/Sources/main.m'));
  assert.ok(auditSource(root).some(error => error.includes('main.m: required source')));
});
test('Android launcher must load the GPUI renderer', t => {
  const root = fixture(t);
  edit(root, 'apps/gpui/android/app/src/main/AndroidManifest.xml', text => text.replace('android:value="rish_gpui"', 'android:value="wrong_renderer"'));
  assert.ok(auditSource(root).some(error => error.includes('GPUI entry point does not match')));
});
test('machine-specific executable is rejected', t => {
  const root = fixture(t);
  edit(root, 'run-simulator.sh', text => `${text}\n/opt/homebrew/bin/xcodegen generate\n`);
  assert.ok(auditSource(root).some(error => error.includes('machine-specific path')));
});
test('a retired Xcode SDK path is rejected', t => {
  const root = fixture(t);
  edit(root, 'apps/gpui/ios/project.yml', text => `${text}\nSDKROOT: Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS18.0.sdk/System\n`);
  assert.ok(auditSource(root).some(error => error.includes('use SDKROOT instead')));
});
test('external Cargo checkout is rejected', t => {
  const root = fixture(t);
  edit(root, 'apps/gpui/crates/rish-shell-core/Cargo.toml', text => text.replace('../../../../modules/rish/core/crates/rish-agent-core', '../../../../../private-runtime'));
  assert.ok(auditSource(root).some(error => error.includes('local Cargo dependency must resolve inside')));
});
test('a symlink cannot conceal an external source prerequisite', t => {
  const root = fixture(t);
  const file = 'apps/gpui/ios/Info.plist';
  fs.unlinkSync(path.join(root, file));
  fs.symlinkSync(path.join(checkout, file), path.join(root, file));
  assert.ok(auditSource(root).some(error => error.includes('source resolves outside')));
});
test('registry dependencies require checksums', t => {
  const root = fixture(t);
  edit(root, 'apps/gpui/Cargo.lock', text => text.replace(/^checksum = "[^"]+"\n/m, ''));
  assert.ok(auditSource(root).some(error => error.includes('needs a registry checksum')));
});
test('git dependencies require public immutable revisions', t => {
  const root = fixture(t);
  edit(root, 'apps/gpui/mobile/Cargo.lock', text => `${text}\n[[package]]\nname = "external-backend"\nversion = "1.0.0"\nsource = "git+file:///private/backend#main"\n`);
  assert.ok(auditSource(root).some(error => error.includes('public revision-pinned Cargo source')));
});
test('a remote Git dependency retains its immutable revision check beside local patches', t => {
  const root = fixture(t);
  const revision = 'a'.repeat(40);
  edit(root, 'apps/gpui/mobile/Cargo.lock', text => `${text}\n[[package]]\nname = "external-backend"\nversion = "1.0.0"\nsource = "git+https://github.com/example/backend?rev=${revision}#${revision}"\n`);
  assert.deepEqual(auditSource(root), []);
  edit(root, 'apps/gpui/mobile/Cargo.lock', text => text.replace(`#${revision}`, `#${'b'.repeat(40)}`));
  assert.ok(auditSource(root).some(error => error.includes('public revision-pinned Cargo source')));
});
test('unreviewed local lockfile packages are rejected', t => {
  const root = fixture(t);
  edit(root, 'apps/gpui/Cargo.lock', text => `${text}\n[[package]]\nname = "unreviewed-runtime"\nversion = "1.0.0"\n`);
  assert.ok(auditSource(root).some(error => error.includes('unreviewed-runtime has an unexpected unpinned source')));
});
test('the Pi runtime must be present and agree with its locked package identity', t => {
  const root = fixture(t);
  const file = 'apps/gpui/crates/rish-pi-runtime/Cargo.toml';
  edit(root, file, text => text.replace('version = "0.1.0"', 'version = "0.2.0"'));
  assert.ok(auditSource(root).some(error => error.includes('rish-pi-runtime does not match its checked-in Cargo manifest')));
  fs.unlinkSync(path.join(root, file));
  assert.ok(auditSource(root).some(error => error.includes(`${file}: required source`)));
});
test('a vendored package cannot impersonate the locked renderer', t => {
  const root = fixture(t);
  edit(root, 'apps/gpui/vendor/gpui-pre-wgpu/Cargo.toml', text => text.replace('name = "gpui-pre-wgpu"', 'name = "replacement-renderer"'));
  assert.ok(auditSource(root).some(error => error.includes('gpui-pre-wgpu does not match its checked-in Cargo manifest')));
});
test('a local dependency manifest cannot escape through a symlink', t => {
  const root = fixture(t);
  const file = 'apps/gpui/vendor/gpui-mobile/Cargo.toml';
  fs.unlinkSync(path.join(root, file));
  fs.symlinkSync(path.join(checkout, file), path.join(root, file));
  const errors = auditSource(root);
  assert.ok(errors.some(error => error.includes('source resolves outside')));
  assert.ok(errors.some(error => error.includes('local Cargo dependency must resolve inside')));
});
test('mobile path patches must retain their reviewed source directories', t => {
  const root = fixture(t);
  edit(root, 'apps/gpui/mobile/Cargo.toml', text => text.replace('path = "../vendor/gpui-mobile"', 'path = "../vendor/gpui-pre-wgpu"'));
  assert.ok(auditSource(root).some(error => error.includes('gpui-mobile must use its reviewed in-repository path patch')));
});
test('a stale remote lock entry cannot bypass the local mobile patch', t => {
  const root = fixture(t);
  const revision = '5abbefa5f753ee9a1920d6d2eaeede981e79eeff';
  edit(root, 'apps/gpui/mobile/Cargo.lock', text => text.replace('name = "gpui-mobile"\nversion = "0.1.0"', `name = "gpui-mobile"\nversion = "0.1.0"\nsource = "git+https://github.com/itsbalamurali/gpui-mobile?rev=${revision}#${revision}"`));
  assert.ok(auditSource(root).some(error => error.includes('gpui-mobile must resolve to its checked-in path patch')));
});
test('renderer provenance must match its locked package and retain the archive checksum', t => {
  const root = fixture(t);
  edit(root, 'apps/gpui/vendor/gpui-pre-wgpu/UPSTREAM.toml', text => text.replace('version = "0.3.6"', 'version = "0.3.7"'));
  assert.ok(auditSource(root).some(error => error.includes('renderer provenance does not match')));
});
test('malformed vendored Git provenance is rejected without crashing the audit', t => {
  const root = fixture(t);
  edit(root, 'apps/gpui/vendor/gpui-mobile/UPSTREAM.json', () => '{');
  assert.ok(auditSource(root).some(error => error.includes('gpui-mobile revision differs from Cargo.toml')));
});
test('a stale mobile backend revision is rejected before Cargo builds', t => {
  const root = fixture(t);
  edit(root, 'apps/gpui/mobile/Cargo.toml', text => text.replace(/rev = "[a-f0-9]{40}"/, `rev = "${'a'.repeat(40)}"`));
  assert.ok(auditSource(root).some(error => error.includes('revision differs from Cargo.toml')));
});
test('the retired React Native app cannot reenter the source archive', t => {
  const root = fixture(t);
  fs.mkdirSync(path.join(root, 'apps/mobile'));
  assert.ok(auditSource(root).some(error => error.includes('retired React Native application must not be present')));
});
test('native runtime sources cannot import a React Native bridge', t => {
  const root = fixture(t);
  const file = 'modules/rish/ios/Sources/SessionSnapshotStore.mm';
  edit(root, file, text => `${text}\n#import <React/RCTBridgeModule.h>\n`);
  assert.ok(auditSource(root).some(error => error.includes('React Native or JavaScript engine dependency')));
});
test('a new source file cannot hide a React Native Android dependency', t => {
  const root = fixture(t);
  fs.writeFileSync(path.join(root, 'apps/gpui/android/app/src/main/java/OldBridge.java'), 'import com.facebook.react.ReactActivity;\n');
  assert.ok(auditSource(root).some(error => error.includes('React Native or JavaScript engine dependency')));
});
test('Gradle cannot retain a React Native source path', t => {
  const root = fixture(t);
  edit(root, 'apps/gpui/android/app/build.gradle', text => `${text}\ndef retired = file("../../../mobile/android")\n`);
  assert.ok(auditSource(root).some(error => error.includes('retired mobile app build reference')));
});
