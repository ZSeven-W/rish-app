#!/usr/bin/env node
// Offline source/archive checks. Passing these checks does not prove a native
// build: the pinned toolchains and generated XCFrameworks are separate inputs.
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

export const requiredFiles = [
  'apps/mobile/package.json',
  'apps/mobile/package-lock.json',
  'apps/mobile/app.json',
  'apps/mobile/index.js',
  'apps/mobile/ios/Podfile',
  'apps/mobile/ios/.xcode.env',
  'apps/mobile/ios/Rish.xcodeproj/project.pbxproj',
  'apps/mobile/ios/Rish.xcodeproj/xcshareddata/xcschemes/Rish.xcscheme',
  'apps/mobile/ios/Rish.xcworkspace/contents.xcworkspacedata',
  'apps/mobile/ios/Rish/AppDelegate.swift',
  'apps/mobile/ios/Rish/Info.plist',
  'apps/mobile/ios/Rish/Rish.entitlements',
  'apps/mobile/android/gradlew',
  'apps/mobile/android/gradle/wrapper/gradle-wrapper.jar',
  'apps/mobile/android/app/src/main/java/tech/zseven/rish/MainActivity.kt',
  'modules/rish/ios/RishLocalRuntime.podspec',
  // Git logic both hosts compile: Android's CMake and LocalProjectsModule.mm.
  'modules/rish/shared/git/rish_project_merge.h',
  'modules/rish/shared/git/rish_project_merge.cpp',
  'run-simulator.sh',
  'scripts/prepare-rish-ios.sh',
  'scripts/prepare-rish-agent-core.sh',
  'modules/rish/core/Cargo.toml',
  'modules/rish/core/include/rish_agent_core.h',
  'scripts/prepare-libgit2-ios.sh',
  'scripts/prepare-libssh2-ios.sh',
  'scripts/prepare-openssl-ios.sh',
];

const portableFiles = requiredFiles.filter(file =>
  /(?:\.sh|\.swift|\.kt|\.podspec|\.pbxproj|\.xcscheme|\.xcworkspacedata|\.xcode\.env|Podfile)$/.test(file));

export function auditSource(sourceRoot) {
  const root = fs.realpathSync(sourceRoot);
  const errors = [];
  const readable = new Set();
  const read = file => readable.has(file) ? fs.readFileSync(path.join(root, file), 'utf8') : null;
  for (const file of requiredFiles) {
    const absolute = path.join(root, file);
    if (!fs.existsSync(absolute) || !fs.statSync(absolute).isFile()) {
      errors.push(`${file}: required source file is missing`);
      continue;
    }
    const resolved = path.relative(root, fs.realpathSync(absolute));
    if (resolved === '..' || resolved.startsWith(`..${path.sep}`) || path.isAbsolute(resolved)) {
      errors.push(`${file}: source resolves outside this checkout`);
      continue;
    }
    readable.add(file);
  }
  for (const file of portableFiles) {
    const text = read(file);
    if (text === null) continue;
    text.split('\n').forEach((line, index) => {
      if (/^\s*(?:#|\/\/)/.test(line)) return;
      if (/\/(?:Users|home)\/[A-Za-z0-9_.-]+\//.test(line) || line.includes('/opt/homebrew/')) {
        errors.push(`${file}:${index + 1}: build input contains a machine-specific path`);
      }
      if (line.includes('DSHMobile')) {
        errors.push(`${file}:${index + 1}: stale DSHMobile build reference`);
      }
      if (/Developer\/SDKs\/iPhoneOS[0-9.]+\.sdk\//.test(line)) {
        errors.push(`${file}:${index + 1}: use SDKROOT instead of a versioned SDK path`);
      }
    });
  }
  const parse = file => {
    const text = read(file);
    if (text === null) return null;
    try { return JSON.parse(text); } catch {
      errors.push(`${file}: invalid JSON`);
      return null;
    }
  };
  const app = parse('apps/mobile/app.json');
  if (app && app.name !== 'Rish') errors.push('apps/mobile/app.json: native component name must be Rish');
  for (const [file, expected] of [
    ['apps/mobile/ios/Rish/AppDelegate.swift', /withModuleName:\s*"Rish"/],
    ['apps/mobile/android/app/src/main/java/tech/zseven/rish/MainActivity.kt', /getMainComponentName\(\):\s*String\s*=\s*"Rish"/],
    ['apps/mobile/ios/Rish.xcworkspace/contents.xcworkspacedata', /location\s*=\s*"group:Rish\.xcodeproj"/],
    ['apps/mobile/ios/Rish.xcodeproj/xcshareddata/xcschemes/Rish.xcscheme', /ReferencedContainer\s*=\s*"container:Rish\.xcodeproj"/],
  ]) {
    const text = read(file);
    if (text !== null && !expected.test(text)) errors.push(`${file}: Rish entry point does not match`);
  }
  const podfile = read('apps/mobile/ios/Podfile');
  if (podfile !== null) {
    const localPod = podfile.match(/pod\s+['"]RishLocalRuntime['"],\s*:path\s*=>\s*['"]([^'"]+)['"]/);
    if (!localPod || path.resolve(root, 'apps/mobile/ios', localPod[1]) !== path.join(root, 'modules/rish/ios')) {
      errors.push('apps/mobile/ios/Podfile: local runtime must resolve inside this source checkout');
    }
  }
  const manifest = parse('apps/mobile/package.json');
  const lock = parse('apps/mobile/package-lock.json');
  if (manifest && lock) {
    if (lock.lockfileVersion !== 3 || !lock.packages || !lock.packages['']) {
      errors.push('apps/mobile/package-lock.json: expected a complete npm v3 lockfile');
    } else {
      for (const section of ['dependencies', 'devDependencies', 'optionalDependencies']) {
        const declared = manifest[section] || {};
        const locked = lock.packages[''][section] || {};
        const keys = new Set([...Object.keys(declared), ...Object.keys(locked)]);
        if ([...keys].some(key => declared[key] !== locked[key])) {
          errors.push(`apps/mobile/package-lock.json: ${section} differs from package.json`);
        }
      }
      for (const [name, entry] of Object.entries(lock.packages)) {
        if (!name) continue;
        let publicRegistry = false;
        try {
          const url = new URL(entry.resolved);
          publicRegistry = url.protocol === 'https:' && url.hostname === 'registry.npmjs.org' &&
            !url.username && !url.password && !url.port;
        } catch { /* Local, missing and malformed resolutions fail below. */ }
        if (entry.link || !publicRegistry || !/^sha(?:256|384|512)-[A-Za-z0-9+/=]+$/.test(entry.integrity || '')) {
          errors.push(`apps/mobile/package-lock.json: ${name} needs a public, integrity-pinned npm resolution`);
        }
      }
    }
  }
  return errors;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (process.argv.length > 3) {
    console.error('usage: node scripts/verify-source-checkout.mjs [source-root]');
    process.exit(2);
  }
  const root = process.argv[2] || fileURLToPath(new URL('..', import.meta.url));
  try {
    const errors = auditSource(root);
    for (const error of errors) console.error(error);
    if (errors.length) process.exitCode = 1;
    else console.log('Source checkout preflight passed (offline; native builds still require prepared dependencies).');
  } catch (error) {
    console.error(`Source checkout preflight failed: ${error.code || error.name}`);
    process.exitCode = 1;
  }
}
