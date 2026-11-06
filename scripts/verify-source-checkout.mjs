#!/usr/bin/env node
// Offline source/archive checks. These prove the checked-in build graph is
// portable; native compilation and prepared VM/Git libraries are separate gates.
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

export const requiredFiles = [
  'apps/gpui/Cargo.toml',
  'apps/gpui/Cargo.lock',
  'apps/gpui/mobile/Cargo.toml',
  'apps/gpui/mobile/Cargo.lock',
  'apps/gpui/crates/rish-shell-core/Cargo.toml',
  'apps/gpui/crates/rish-pi-runtime/Cargo.toml',
  'apps/gpui/vendor/gpui-mobile/Cargo.toml',
  'apps/gpui/vendor/gpui-mobile/UPSTREAM.json',
  'apps/gpui/vendor/gpui-mobile/RISH-PATCHES.txt',
  'apps/gpui/vendor/gpui-mobile/src/android/surface_lifecycle.rs',
  'apps/gpui/vendor/gpui-mobile/LICENSE-APACHE',
  'apps/gpui/vendor/gpui-pre-wgpu/Cargo.toml',
  'apps/gpui/vendor/gpui-pre-wgpu/UPSTREAM.toml',
  'apps/gpui/vendor/gpui-pre-wgpu/RISH-PATCHES.txt',
  'apps/gpui/vendor/gpui-pre-wgpu/LICENSE-APACHE',
  'apps/gpui/vendor/gpui-pre-wgpu/src/wgpu_context.rs',
  'apps/gpui/vendor/gpui-pre-wgpu/src/wgpu_renderer.rs',
  'apps/gpui/vendor/gpui-pre-wgpu/src/wgpu_backend_policy.rs',
  'apps/gpui/src/main.rs',
  'apps/gpui/src/lib.rs',
  'apps/gpui/ios/project.yml',
  'apps/gpui/ios/Info.plist',
  'apps/gpui/ios/Sources/main.m',
  'apps/gpui/ios/Sources/RishGPUIBridge.m',
  'apps/gpui/ios/Sources/Exports.inc',
  'apps/gpui/ios/Native/RishNative/RishNativeModule.h',
  'apps/gpui/ios/Resources/Images.xcassets/AppIcon.appiconset/Contents.json',
  'apps/gpui/ios/Resources/LaunchScreen.storyboard',
  'apps/gpui/ios/Resources/PrivacyInfo.xcprivacy',
  'apps/gpui/android/settings.gradle',
  'apps/gpui/android/app/build.gradle',
  'apps/gpui/android/gradlew',
  'apps/gpui/android/gradle/wrapper/gradle-wrapper.jar',
  'apps/gpui/android/gradle/wrapper/gradle-wrapper.properties',
  'apps/gpui/android/app/src/main/AndroidManifest.xml',
  'apps/gpui/android/app/src/main/java/dev/gpui/mobile/GpuiActivity.java',
  'apps/gpui/android/app/src/main/java/tech/zseven/rish/gpui/RishGpuiBridge.kt',
  'apps/gpui/android/app/src/main/cpp/CMakeLists.txt',
  'modules/rish/android/src/main/cpp/CMakeLists.txt',
  'modules/rish/android/src/main/cpp/rish_agent_core_jni.cpp',
  'modules/rish/android/src/main/java/tech/zseven/rish/runtime/RishAgentCoreNative.kt',
  'modules/rish/android/src/main/java/tech/zseven/rish/guest/GuestAssets.kt',
  'modules/rish/ios/Sources/SessionSnapshotStore.mm',
  'modules/rish/shared/GuestAssets/SHA256SUMS',
  'modules/rish/shared/GuestAssets/guest-agent-build.json',
  'modules/rish/shared/git/rish_project_merge.h',
  'modules/rish/shared/git/rish_project_merge.cpp',
  'modules/rish/core/Cargo.toml',
  'modules/rish/core/crates/rish-agent-core/Cargo.toml',
  'modules/rish/core/include/rish_agent_core.h',
  'run-simulator.sh',
  'apps/gpui/scripts/build-ios.sh',
  'apps/gpui/scripts/build-android.sh',
  'scripts/prepare-rish-ios.sh',
  'scripts/prepare-rish-agent-core.sh',
  'scripts/prepare-libgit2-ios.sh',
  'scripts/prepare-libssh2-ios.sh',
  'scripts/prepare-openssl-ios.sh',
];

const runtimeRoots = [
  'apps/gpui/src', 'apps/gpui/ios/Sources', 'apps/gpui/ios/Native',
  'apps/gpui/android/app/src', 'modules/rish/ios/Sources', 'modules/rish/android/src',
];
const sourceExtension = /\.(?:rs|m|mm|h|cpp|kt|java|gradle|toml|yml|xml|sh|plist|storyboard|xcprivacy)$/;
const inside = (root, file) => {
  const relative = path.relative(root, file);
  return relative !== '..' && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative);
};
const activeLines = text => text.split('\n').map((line, index) => ({line, index}))
  .filter(({line}) => !/^\s*(?:#(?!include|import)|\/\/|\/\*|\*)/.test(line));
const table = (text, name) => {
  const lines = text.split('\n');
  const start = lines.findIndex(line => line.trim() === `[${name}]`);
  if (start < 0) return '';
  const end = lines.findIndex((line, index) => index > start && /^\s*\[/.test(line));
  return lines.slice(start + 1, end < 0 ? undefined : end).join('\n');
};
const field = (text, name) => text.match(new RegExp(`^${name}\\s*=\\s*"([^"\\n]+)"`, 'm'))?.[1];
const localPackages = {
  'rish-agent-core': 'modules/rish/core/crates/rish-agent-core/Cargo.toml',
  'rish-gpui': 'apps/gpui/Cargo.toml',
  'rish-gpui-mobile': 'apps/gpui/mobile/Cargo.toml',
  'rish-shell-core': 'apps/gpui/crates/rish-shell-core/Cargo.toml',
  'rish-pi-runtime': 'apps/gpui/crates/rish-pi-runtime/Cargo.toml',
  'gpui-mobile': 'apps/gpui/vendor/gpui-mobile/Cargo.toml',
  'gpui-pre-wgpu': 'apps/gpui/vendor/gpui-pre-wgpu/Cargo.toml',
};
const mobilePatches = [
  ['gpui-mobile', 'patch."https://github.com/itsbalamurali/gpui-mobile"'],
  ['gpui-pre-wgpu', 'patch.crates-io'],
];

export function auditSource(sourceRoot) {
  const root = fs.realpathSync(sourceRoot);
  const errors = [];
  const readable = new Set();
  const inspect = file => {
    const absolute = path.join(root, file);
    if (!fs.existsSync(absolute) || !fs.statSync(absolute).isFile()) {
      errors.push(`${file}: required source file is missing`);
      return;
    }
    if (!inside(root, fs.realpathSync(absolute))) {
      errors.push(`${file}: source resolves outside this checkout`);
      return;
    }
    readable.add(file);
  };
  requiredFiles.forEach(inspect);
  const read = file => readable.has(file) ? fs.readFileSync(path.join(root, file), 'utf8') : null;
  // Walk only authored runtime sources, never generated outputs or vendor trees.
  const walk = directory => {
    const absolute = path.join(root, directory);
    if (!fs.existsSync(absolute)) return;
    if (!inside(root, fs.realpathSync(absolute))) {
      errors.push(`${directory}: source resolves outside this checkout`);
      return;
    }
    for (const entry of fs.readdirSync(absolute, {withFileTypes: true})) {
      const file = path.join(directory, entry.name);
      if (entry.isSymbolicLink()) inspect(file);
      else if (entry.isDirectory()) walk(file);
      else if (sourceExtension.test(file)) inspect(file);
    }
  };
  runtimeRoots.forEach(walk);
  for (const file of readable) {
    if (!sourceExtension.test(file) && !file.endsWith('CMakeLists.txt')) continue;
    for (const {line, index} of activeLines(read(file))) {
      if (/\/(?:Users|home)\/[A-Za-z0-9_.-]+\//.test(line) || line.includes('/opt/homebrew/')) {
        errors.push(`${file}:${index + 1}: build input contains a machine-specific path`);
      }
      if (/Developer\/SDKs\/iPhoneOS[0-9.]+\.sdk\//.test(line)) {
        errors.push(`${file}:${index + 1}: use SDKROOT instead of a versioned SDK path`);
      }
      if (/(?:apps\/mobile|(?:\.\.\/){2,}mobile\/|DSHMobile)/.test(line)) {
        errors.push(`${file}:${index + 1}: retired mobile app build reference`);
      }
      if (/(?:react-native|com\.facebook\.react|<React\/|\bRCT[A-Z]\w*|\bReactActivity\b|\bReactApplication\b|\bHermesExecutor\b|\bhermes-android\b|\bJavaScriptCore\b)/.test(line)) {
        errors.push(`${file}:${index + 1}: React Native or JavaScript engine dependency in the GPUI build graph`);
      }
    }
  }
  if (fs.existsSync(path.join(root, 'apps/mobile'))) {
    errors.push('apps/mobile: retired React Native application must not be present');
  }
  for (const [file, expected] of [
    ['apps/gpui/Cargo.toml', /gpui\s*=\s*\{[^\n]*package\s*=\s*"gpui-fast"/],
    ['apps/gpui/mobile/Cargo.toml', /path\s*=\s*"\.\.\/src\/lib\.rs"/],
    ['apps/gpui/src/main.rs', /gpui_platform::application\(\)/],
    ['apps/gpui/src/lib.rs', /pub extern "C" fn rish_gpui_run\(\)/],
    ['apps/gpui/src/lib.rs', /pub fn android_main\(app: android_activity::AndroidApp\)/],
    ['apps/gpui/ios/Sources/main.m', /rish_gpui_run\(\);/],
    ['apps/gpui/ios/project.yml', /-force_load[\s\S]*\$\(RISH_GPUI_STATIC_LIB\)/],
    ['apps/gpui/android/app/src/main/AndroidManifest.xml', /android:name="dev\.gpui\.mobile\.GpuiActivity"/],
    ['apps/gpui/android/app/src/main/AndroidManifest.xml', /android:name="android\.app\.lib_name" android:value="rish_gpui"/],
  ]) {
    const text = read(file);
    if (text !== null && !expected.test(text)) errors.push(`${file}: GPUI entry point does not match`);
  }
  for (const file of requiredFiles.filter(file => file.endsWith('Cargo.toml'))) {
    const text = read(file);
    if (text === null) continue;
    // Local dependency paths must exist in the source archive; generated
    // libraries and Cargo's registry/git cache are deliberately not required.
    for (const match of text.matchAll(/\{[^\n}]*\bpath\s*=\s*"([^"]+)"[^\n}]*\}/g)) {
      const dependency = path.resolve(root, path.dirname(file), match[1]);
      const manifest = path.join(dependency, 'Cargo.toml');
      if (!inside(root, dependency) || !fs.existsSync(manifest) ||
          !fs.statSync(manifest).isFile() || !inside(root, fs.realpathSync(manifest))) {
        errors.push(`${file}: local Cargo dependency must resolve inside this source checkout`);
      }
    }
  }
  const locks = new Map();
  for (const file of ['apps/gpui/Cargo.lock', 'apps/gpui/mobile/Cargo.lock']) {
    const text = read(file);
    if (text === null) continue;
    if (!/^version = 4$/m.test(text)) errors.push(`${file}: expected a Cargo v4 lockfile`);
    const packages = text.split('[[package]]').slice(1);
    const names = new Set();
    const entries = new Map();
    locks.set(file, entries);
    for (const entry of packages) {
      const name = field(entry, 'name');
      const source = field(entry, 'source');
      names.add(name);
      entries.set(name, entry);
      if (!source) {
        const manifest = Object.hasOwn(localPackages, name) ? localPackages[name] : null;
        const mobileOnly = ['rish-gpui-mobile', 'gpui-mobile', 'gpui-pre-wgpu'].includes(name);
        if (!manifest || (mobileOnly && !file.includes('/mobile/')) ||
            (name === 'rish-gpui' && file.includes('/mobile/'))) {
          errors.push(`${file}: ${name || 'unnamed package'} has an unexpected unpinned source`);
        } else {
          const contents = read(manifest);
          const metadata = contents === null ? '' : table(contents, 'package');
          // The independently maintained agent core inherits its version from
          // its own workspace; the GPUI packages declare theirs directly.
          const version = name === 'rish-agent-core' && /^version\.workspace\s*=\s*true\s*$/m.test(metadata)
            ? field(table(read('modules/rish/core/Cargo.toml') || '', 'workspace.package'), 'version')
            : field(metadata, 'version');
          if (field(metadata, 'name') !== name || version !== field(entry, 'version')) {
            errors.push(`${file}: ${name} does not match its checked-in Cargo manifest`);
          }
        }
      } else if (source === 'registry+https://github.com/rust-lang/crates.io-index') {
        if (!/^checksum = "[a-f0-9]{64}"$/m.test(entry)) errors.push(`${file}: ${name} needs a registry checksum`);
      } else if (!/^git\+https:\/\/github\.com\/[\w.-]+\/[\w.-]+\?rev=([a-f0-9]{40})#\1$/.test(source)) {
        errors.push(`${file}: ${name} needs a public revision-pinned Cargo source`);
      }
    }
    for (const name of file.includes('/mobile/') ? ['rish-gpui-mobile', 'gpui-mobile', 'gpui-pre'] : ['rish-gpui', 'gpui-fast']) {
      if (!names.has(name)) errors.push(`${file}: missing ${name} from the locked GPUI graph`);
    }
  }
  const mobile = read('apps/gpui/mobile/Cargo.toml');
  const mobileEntries = locks.get('apps/gpui/mobile/Cargo.lock');
  if (mobile !== null && mobileEntries) {
    for (const [name, section] of mobilePatches) {
      const expected = `../vendor/${name}`;
      const patch = table(mobile, section).match(new RegExp(`^${name}\\s*=\\s*\\{([^\\n}]+)\\}`, 'm'))?.[1];
      if (!patch || !new RegExp(`\\bpath\\s*=\\s*"${expected.replaceAll('.', '\\.')}"`).test(patch)) {
        errors.push(`apps/gpui/mobile/Cargo.toml: ${name} must use its reviewed in-repository path patch`);
      }
      const entry = mobileEntries.get(name);
      if (!entry || field(entry, 'source')) {
        errors.push(`apps/gpui/mobile/Cargo.lock: ${name} must resolve to its checked-in path patch`);
      }
    }
    const dependency = table(mobile, 'dependencies').match(/^gpui-mobile\s*=\s*\{([^\n}]+)\}/m)?.[1] || '';
    const revision = dependency.match(/\brev\s*=\s*"([a-f0-9]{40})"/)?.[1];
    const repository = dependency.match(/\bgit\s*=\s*"([^"]+)"/)?.[1];
    let upstream;
    try { upstream = JSON.parse(read('apps/gpui/vendor/gpui-mobile/UPSTREAM.json')); } catch { /* diagnosed below */ }
    if (!revision || repository !== 'https://github.com/itsbalamurali/gpui-mobile' ||
        upstream?.repository !== repository || upstream?.revision !== revision) {
      errors.push('apps/gpui/vendor/gpui-mobile/UPSTREAM.json: gpui-mobile revision differs from Cargo.toml');
    }
    const renderer = read('apps/gpui/vendor/gpui-pre-wgpu/UPSTREAM.toml') || '';
    const rendererVersion = field(mobileEntries.get('gpui-pre-wgpu') || '', 'version');
    if (field(renderer, 'name') !== 'gpui-pre-wgpu' || !rendererVersion ||
        field(renderer, 'version') !== rendererVersion ||
        field(renderer, 'archive_url') !== `https://static.crates.io/crates/gpui-pre-wgpu/gpui-pre-wgpu-${rendererVersion}.crate` ||
        !/^[a-f0-9]{64}$/.test(field(renderer, 'archive_sha256') || '') ||
        !/^[a-f0-9]{40}$/.test(field(renderer, 'zed_revision') || '')) {
      errors.push('apps/gpui/vendor/gpui-pre-wgpu/UPSTREAM.toml: renderer provenance does not match the locked path patch');
    }
    const modified = renderer.match(/^modified_upstream_files\s*=\s*\[([^\]]*)\]/m)?.[1] || '';
    const added = renderer.match(/^added_local_files\s*=\s*\[([^\]]*)\]/m)?.[1] || '';
    if (!modified.includes('"src/wgpu_context.rs"') || !modified.includes('"src/wgpu_renderer.rs"') ||
        !added.includes('"src/wgpu_backend_policy.rs"')) {
      errors.push('apps/gpui/vendor/gpui-pre-wgpu/UPSTREAM.toml: renderer backend policy patch must be recorded');
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
    else console.log('GPUI source checkout preflight passed (offline; native builds still require prepared dependencies).');
  } catch (error) {
    console.error(`Source checkout preflight failed: ${error.code || error.name}`);
    process.exitCode = 1;
  }
}
