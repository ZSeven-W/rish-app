import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';

const read = file => fs.readFileSync(new URL(`../../${file}`, import.meta.url), 'utf8');

test('GPUI iOS host retains the isolated development identifier', () => {
  // Signed App Store/TestFlight delivery is not wired for this native host yet.
  const project = read('apps/gpui/ios/project.yml');
  const identifiers = [...project.matchAll(/PRODUCT_BUNDLE_IDENTIFIER:\s*([^\s]+)/g)].map(match => match[1]);
  assert.ok(identifiers.includes('tech.zseven.rish.gpui'));
  assert.ok(identifiers.every(identifier => identifier === 'tech.zseven.rish.gpui' || identifier.startsWith('tech.zseven.rish.gpui.')));
  assert.match(read('apps/gpui/ios/Info.plist'), /<key>CFBundleIdentifier<\/key>\s*<string>\$\(PRODUCT_BUNDLE_IDENTIFIER\)<\/string>/);
});

test('GPUI iOS version and build number come from the project configuration', () => {
  const plist = read('apps/gpui/ios/Info.plist');
  assert.match(plist, /<key>CFBundleShortVersionString<\/key>\s*<string>\$\(MARKETING_VERSION\)<\/string>/);
  assert.match(plist, /<key>CFBundleVersion<\/key>\s*<string>\$\(CURRENT_PROJECT_VERSION\)<\/string>/);
});

test('Android retains native service namespace and isolated GPUI application ID', () => {
  const gradle = read('apps/gpui/android/app/build.gradle');
  assert.match(gradle, /namespace "tech\.zseven\.rish"/);
  assert.match(gradle, /applicationId "tech\.zseven\.rish\.gpui"/);
  assert.match(read('apps/gpui/android/app/src/main/AndroidManifest.xml'), /android:name="dev\.gpui\.mobile\.GpuiActivity"/);
  assert.match(read('apps/gpui/android/app/src/main/java/dev/gpui/mobile/GpuiActivity.java'), /^package dev\.gpui\.mobile;$/m);
});

test('retired React Native signing pipeline cannot be dispatched', () => {
  for (const file of ['.github/workflows/testflight.yml', 'scripts/ci/export-ios.rb']) {
    assert.equal(fs.existsSync(new URL(`../../${file}`, import.meta.url)), false, `${file} must be removed until a GPUI release pipeline is verified`);
  }
});
