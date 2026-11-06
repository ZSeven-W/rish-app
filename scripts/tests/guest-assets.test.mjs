import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import fs from 'node:fs';
import test from 'node:test';

const root = new URL('../../', import.meta.url);
const read = path => fs.readFileSync(new URL(path, root));
const assets = 'modules/rish/shared/GuestAssets/';
const sha = bytes => createHash('sha256').update(bytes).digest('hex');

test('bundled guest assets match the manifest and native integrity checks', () => {
  const manifest = read(`${assets}SHA256SUMS`).toString();
  const module = read('modules/rish/ios/Sources/LocalGuestModule.mm').toString();
  // Android packages the same two files and pins the same digests in Kotlin.
  const android = read('modules/rish/android/src/main/java/tech/zseven/rish/guest/GuestAssets.kt').toString();
  for (const line of manifest.split('\n').filter(line => line && !line.startsWith('#'))) {
    const [digest, file] = line.split('  ');
    assert.equal(sha(read(`${assets}${file}`)), digest);
    assert.ok(module.includes(digest), `iOS module must pin ${file}`);
    assert.ok(android.includes(digest), `Android GuestAssets must pin ${file}`);
    assert.ok(android.includes(`"${file}"`), `Android GuestAssets must name ${file}`);
  }
});

test('bundled agent agrees with the pinned host readiness protocol', () => {
  const provenance = JSON.parse(read(`${assets}guest-agent-build.json`).toString());
  assert.ok(read('scripts/prepare-rish-ios.sh').toString().includes(`EXPECTED_RISH_COMMIT="${provenance.rish_commit}"`));
  assert.ok(read('scripts/prepare-rish-android.sh').toString().includes(`EXPECTED_RISH_COMMIT="${provenance.rish_commit}"`));
  const data = read(`${assets}rish-container.cpio`);
  assert.equal(sha(data), provenance.initramfs_sha256);
  let found = false;
  let initFound = false;
  for (let offset = 0; offset + 110 <= data.length;) {
    assert.equal(data.toString('ascii', offset, offset + 6), '070701');
    const size = parseInt(data.toString('ascii', offset + 54, offset + 62), 16);
    const nameSize = parseInt(data.toString('ascii', offset + 94, offset + 102), 16);
    const name = data.toString('utf8', offset + 110, offset + 110 + nameSize - 1).replace(/^\.\//, '');
    const start = Math.ceil((offset + 110 + nameSize) / 4) * 4;
    if (name === 'TRAILER!!!') break;
    if (name === 'init') {
      const init = data.subarray(start, start + size);
      assert.equal(sha(init), provenance.init_sha256);
      assert.ok(init.includes(Buffer.from('/bin/busybox mkdir -p')));
      const text = init.toString();
      assert.ok(text.indexOf('/bin/busybox --install') < text.indexOf('\nmount -t devtmpfs'));
      assert.ok(text.indexOf('\nmount -t devtmpfs') > 0);
      initFound = true;
    }
    if (name === 'usr/bin/rish-guest-agent') {
      const agent = data.subarray(start, start + size);
      assert.equal(sha(agent), provenance.agent_sha256);
      assert.ok(agent.includes(Buffer.from('RISH_GUEST_AGENT_READY')));
      found = true;
    }
    offset = Math.ceil((start + size) / 4) * 4;
  }
  assert.ok(found && initFound, 'guest agent and matching init must be present');
});
