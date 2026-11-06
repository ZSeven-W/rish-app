#!/usr/bin/env python3
"""Add hash-locked block/network/ext4 drivers to the current bundled guest.

Preserves the existing guest agent, Alpine libraries and signed offline APK
repository. --preview writes an isolated candidate while a source change is
under review; normal updates require the clean, pinned rish checkout.
"""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import re
import stat
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / 'modules/rish/shared/GuestAssets'
NETBOOT_MODULES = [
    'kernel/drivers/block/virtio_blk.ko',
    'kernel/fs/fat/fat.ko', 'kernel/fs/fat/vfat.ko',
    'kernel/fs/nls/nls_cp437.ko', 'kernel/fs/nls/nls_ascii.ko',
    'kernel/fs/nls/nls_utf8.ko', 'kernel/net/core/failover.ko',
    'kernel/drivers/net/net_failover.ko', 'kernel/drivers/net/virtio_net.ko',
]
EXT4_MODULES = [
    'kernel/lib/crc/crc16.ko', 'kernel/fs/mbcache.ko',
    'kernel/fs/jbd2/jbd2.ko', 'kernel/fs/ext4/ext4.ko',
]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def members(data):
    result = {}
    offset = 0
    while offset + 110 <= len(data):
        header = data[offset:offset + 110]
        if header[:6] != b'070701':
            raise ValueError('expected uncompressed newc archive')
        fields = [int(header[index:index + 8], 16) for index in range(6, 110, 8)]
        size, name_size = fields[6], fields[11]
        if not 1 <= name_size <= 4096:
            raise ValueError('invalid member name size')
        name_end = offset + 110 + name_size
        start = (name_end + 3) & ~3
        end = (start + size + 3) & ~3
        if end > len(data) or data[name_end - 1] != 0:
            raise ValueError('truncated member')
        name = data[offset + 110:name_end - 1].decode().removeprefix('./')
        if name == 'TRAILER!!!':
            return result
        if name not in ('', '.'):
            if name.startswith('/') or '..' in name.split('/') or name in result:
                raise ValueError('unsafe or repeated member')
            result[name] = (fields[1], data[start:start + size])
        offset = end
    raise ValueError('missing archive trailer')


def pack(entries):
    output = bytearray()
    for inode, (name, (mode, payload)) in enumerate(
            [*sorted(entries.items()), ('TRAILER!!!', (0, b''))], 1):
        encoded = name.encode() + b'\0'
        fields = [inode, mode, 0, 0, 1, 0, len(payload), 0, 0, 0, 0, len(encoded), 0]
        output.extend(b'070701' + b''.join(f'{field:08x}'.encode() for field in fields))
        output.extend(encoded)
        output.extend(bytes((-len(output)) % 4))
        output.extend(payload)
        output.extend(bytes((-len(output)) % 4))
    output.extend(bytes((-len(output)) % 512))
    return bytes(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('downloads', type=Path)
    parser.add_argument('--preview', type=Path)
    args = parser.parse_args()
    source = args.source.resolve()
    commit = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    if args.preview is None:
        pin = re.search(r'EXPECTED_RISH_COMMIT="([a-f0-9]+)"',
                        (ROOT / 'scripts/prepare-rish-ios.sh').read_text())[1]
        if commit != pin or subprocess.check_output(
                ['git', '-C', str(source), 'status', '--porcelain'], text=True).strip():
            raise ValueError('normal update requires the clean pinned rish checkout')
    locks = {}
    for line in (source / 'guest/x86_64/assets.lock.tsv').read_text().splitlines():
        if line and not line.startswith('#'):
            _, _, name, size, digest, _ = line.split('\t')
            locks[name] = (int(size), digest)

    def verified(name):
        data = (args.downloads / name).read_bytes()
        if (len(data), sha(data)) != locks[name]:
            raise ValueError(f'asset integrity mismatch: {name}')
        return data

    verified('modloop-virt')
    netboot = members(gzip.decompress(verified('initramfs-virt')))
    kernel_name = next(name for name in locks if name.startswith('vmlinuz-virt-'))
    if sha((ASSETS / kernel_name).read_bytes()) != locks[kernel_name][1]:
        raise ValueError('module source does not match the bundled kernel')
    kernel_version = next(name.removeprefix('config-') for name in locks if name.startswith('config-'))
    archive = ASSETS / 'rish-container.cpio'
    old_bytes = archive.read_bytes()
    old_sha = sha(old_bytes)
    if f'{old_sha}  rish-container.cpio' not in (ASSETS / 'SHA256SUMS').read_text():
        raise ValueError('current guest does not match its manifest')
    original = members(old_bytes)
    updated = dict(original)
    records = []
    for relative in NETBOOT_MODULES + EXT4_MODULES:
        if relative in NETBOOT_MODULES:
            payload = netboot[f'usr/lib/modules/{kernel_version}/{relative}'][1]
            asset = 'initramfs-virt'
        else:
            payload = subprocess.check_output([
                'unsquashfs', '-cat', str(args.downloads / 'modloop-virt'),
                f'modules/{kernel_version}/{relative}',
            ])
            asset = 'modloop-virt'
        if payload[:6] != b'\x7fELF\x02\x01' or int.from_bytes(payload[18:20], 'little') != 62:
            raise ValueError('module is not an x86_64 ELF')
        if f'vermagic={kernel_version} '.encode() not in payload:
            raise ValueError('kernel module version mismatch')
        path = f'lib/modules/{kernel_version}/{relative}'
        updated[path] = (stat.S_IFREG | 0o644, payload)
        for directory in Path(path).parents:
            if str(directory) != '.':
                updated.setdefault(str(directory), (stat.S_IFDIR | 0o755, b''))
        records.append({'path': path, 'sha256': sha(payload), 'bytes': len(payload),
                        'source_asset': asset, 'source_sha256': locks[asset][1]})
    init = (source / 'guest/x86_64/container-overlay/init').read_bytes()
    if b'RISH_X86_64_BOOT_OK' not in init or b'exec /usr/bin/rish-guest-agent' not in init:
        raise ValueError('init must retain the guest protocol startup')
    updated['init'] = (stat.S_IFREG | 0o755, init)
    for name, value in original.items():
        if name != 'init' and not name.startswith('lib/modules/') and updated[name] != value:
            raise ValueError('unrelated rootfs content changed')
    candidate = pack(updated)
    target = args.preview or archive
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=target.parent, suffix='.cpio', delete=False) as temporary:
        temporary.write(candidate)
        candidate_path = Path(temporary.name)
    try:
        subprocess.run(['sh', str(source / 'guest/x86_64/test-container-modules.sh'),
                        str(candidate_path.resolve())], check=True)
    except BaseException:
        candidate_path.unlink(missing_ok=True)
        raise
    replacements = {}
    if args.preview is None:
        new_sha = sha(candidate)
        for path in [ASSETS / 'SHA256SUMS', ROOT / 'modules/rish/ios/Sources/LocalGuestModule.mm',
                     ROOT / 'modules/rish/android/src/main/java/tech/zseven/rish/guest/GuestAssets.kt']:
            text = path.read_text()
            if old_sha not in text:
                candidate_path.unlink(missing_ok=True)
                raise ValueError(f'missing previous integrity pin in {path.name}')
            replacements[path] = text.replace(old_sha, new_sha)
        provenance_path = ASSETS / 'guest-agent-build.json'
        provenance = json.loads(provenance_path.read_text())
        provenance.setdefault('agent_rish_commit', provenance['rish_commit'])
        provenance.update({'rish_commit': commit, 'init_sha256': sha(init),
                           'initramfs_sha256': new_sha, 'kernel_modules': records})
        replacements[provenance_path] = json.dumps(provenance, indent=2) + '\n'
    candidate_path.replace(target)
    for path, text in replacements.items():
        path.write_text(text)
    print(json.dumps({'archive': str(target), 'sha256': sha(candidate),
                      'bytes': len(candidate), 'modules': len(records), 'preview': args.preview is not None}))


if __name__ == '__main__':
    main()
