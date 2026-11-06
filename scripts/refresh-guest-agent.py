#!/usr/bin/env python3
"""Refresh the guest agent and init script in the verified bundled newc archive.

First build rish-guest-agent from the source pin in prepare-rish-ios.sh with
cargo +1.94 build --release --locked --target x86_64-unknown-linux-musl
-p rish-guest-agent. Pass that clean source checkout as the sole argument.
All other Alpine rootfs files and offline packages remain byte-for-byte intact.
"""
import hashlib
import json
import pathlib
import re
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parent.parent
source = pathlib.Path(sys.argv[1]).resolve()
preparation = (root / 'scripts/prepare-rish-ios.sh').read_text()
pin = re.search(r'EXPECTED_RISH_COMMIT="([a-f0-9]+)"', preparation)[1]
assert subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip() == pin
assert not subprocess.check_output(['git', '-C', str(source), 'status', '--porcelain'], text=True).strip()
agent = (source / 'target/x86_64-unknown-linux-musl/release/rish-guest-agent').read_bytes()
assert agent[:6] == b'\x7fELF\x02\x01' and int.from_bytes(agent[18:20], 'little') == 62
assert b'RISH_GUEST_AGENT_READY' in agent
assets = root / 'modules/rish/shared/GuestAssets'
archive = assets / 'rish-container.cpio'
data = archive.read_bytes()
old_sha = hashlib.sha256(data).hexdigest()
manifest = assets / 'SHA256SUMS'
assert f'{old_sha}  rish-container.cpio' in manifest.read_text()
module = root / 'modules/rish/ios/Sources/LocalGuestModule.mm'
assert old_sha in module.read_text()
init = (source / 'guest/x86_64/container-overlay/init').read_bytes()
payloads = {'usr/bin/rish-guest-agent': agent, 'init': init}
offset = 0
replacements = []
found = set()
while offset + 110 <= len(data):
    header = data[offset:offset + 110]
    assert header[:6] == b'070701'
    size, name_size = int(header[54:62], 16), int(header[94:102], 16)
    name = data[offset + 110:offset + 110 + name_size - 1].decode()
    start = (offset + 110 + name_size + 3) & ~3
    end = (start + size + 3) & ~3
    assert end <= len(data)
    if name == 'TRAILER!!!':
        break
    name = name.removeprefix('./')
    if name in payloads:
        assert name not in found and int(header[38:46], 16) == 1
        found.add(name)
        payload = payloads[name]
        updated_header = header[:54] + f'{len(payload):08x}'.encode() + header[62:]
        replacements.append((offset, start, end, updated_header, payload))
    offset = end
assert found == set(payloads)
updated = data
for begin, start, end, header, payload in reversed(replacements):
    updated = updated[:begin] + header + updated[begin + 110:start] + payload + bytes((-len(payload)) % 4) + updated[end:]
new_sha = hashlib.sha256(updated).hexdigest()
archive.write_bytes(updated)
manifest.write_text(manifest.read_text().replace(old_sha, new_sha))
module.write_text(module.read_text().replace(old_sha, new_sha))
provenance_path = assets / 'guest-agent-build.json'
# Only the facts this refresh establishes are rewritten. Everything else the
# file records -- the agent's own source commit, the kernel module digests --
# is provenance this script did not produce and must not drop.
provenance = json.loads(provenance_path.read_text()) if provenance_path.exists() else {}
provenance.update({
    'rish_commit': pin, 'rust_toolchain': '1.94',
    'target': 'x86_64-unknown-linux-musl',
    'base_initramfs_sha256': provenance.get('base_initramfs_sha256', old_sha),
    'agent_sha256': hashlib.sha256(agent).hexdigest(),
    'init_sha256': hashlib.sha256(init).hexdigest(),
    'initramfs_sha256': new_sha,
})
provenance_path.write_text(json.dumps(provenance, indent=2) + '\n')
print(f'Updated guest agent; initramfs SHA-256: {new_sha}')
