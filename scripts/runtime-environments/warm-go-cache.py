#!/usr/bin/env python3
"""Use QEMU only to build Go std cache; this is never rish execution evidence."""
import argparse
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import time
import apk

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / '.build/runtime-environments/packages'


def pack_newc(entries, path):
    with path.open('wb') as file:
        def record(name, mode, data, number):
            encoded = name.encode() + b'\0'
            fields = [number, mode, 0, 0, 2 if stat.S_ISDIR(mode) else 1, 0, len(data), 0, 0, 0, 0, len(encoded), 0]
            file.write(b'070701' + ''.join(f'{x:08x}' for x in fields).encode() + encoded)
            file.write(b'\0' * (-file.tell() % 4)); file.write(data); file.write(b'\0' * (-file.tell() % 4))
        for number, name in enumerate(sorted(entries, key=lambda n: (len(Path(n).parts), n)), 1):
            record(name, *entries[name], number)
        record('TRAILER!!!', 0, b'', len(entries) + 1)
        file.write(b'\0' * (-file.tell() % 512))


def main(base, wall_seconds, receipt_path=None):
    receipt = json.loads((receipt_path or OUT / 'go.build.json').read_text())
    work = OUT / 'go-cache-builder'
    if work.exists(): raise ValueError('refusing to overwrite cache-build evidence')
    work.mkdir()
    disk = work / 'warmed.ext4'
    subprocess.run(['/bin/cp', '-c', receipt['disk_path'], str(disk)], check=True)
    entries = apk.read_newc(base)
    original = entries['init'][1].decode()
    split = original.rsplit('exec /usr/bin/rish-guest-agent', 1)
    if len(split) != 2: raise ValueError('unknown controlled init format')
    warm = '''
set -e
mkdir -p /runtime
mount -t ext4 /dev/vda /runtime
mount -t proc proc /runtime/proc
mount --bind /sys /runtime/sys
mount --bind /dev /runtime/dev
mkdir -p /runtime/tmp/rish-home /runtime/tmp/go-build
set +e
chroot /runtime /bin/sh -c '
  export HOME=/tmp/rish-home PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
  export TMPDIR=/tmp GOCACHE=/tmp/go-build GOTOOLCHAIN=local GOPROXY=off GOMAXPROCS=1
  /usr/bin/go version
  /usr/bin/go env GOCACHE GOROOT GOAMD64
  CGO_ENABLED=0 /usr/bin/go install -p 1 std && CGO_ENABLED=1 /usr/bin/go install -p 1 std
'
rc=$?
echo RISH_GO_CACHE_EXIT=$rc
sync
/bin/busybox poweroff -f
'''
    entries['init'] = stat.S_IFREG | 0o755, (split[0] + warm).encode()
    initrd = work / 'cache-build-base.cpio'
    pack_newc(entries, initrd)
    kernel = ROOT / 'modules/rish/shared/GuestAssets/vmlinuz-virt-6.18.35'
    command = ['qemu-system-x86_64', '-accel', 'tcg,thread=single', '-machine', 'microvm,auto-kernel-cmdline=on',
               '-cpu', 'qemu64', '-m', '1024', '-smp', '1', '-kernel', str(kernel), '-initrd', str(initrd),
               '-append', 'console=ttyS0,115200n8 rdinit=/init panic=-1 oops=panic nokaslr',
               '-drive', 'file=' + str(disk) + ',format=raw,if=none,id=runtime',
               '-device', 'virtio-blk-device,drive=runtime', '-nographic', '-no-reboot', '-nic', 'none']
    record = {'purpose': 'build-only Go standard library cache; not rish program verification',
              'backend': 'QEMU TCG microvm', 'command': command, 'source_disk_sha256': receipt['manifest']['disk_sha256'],
              'wall_limit_seconds': wall_seconds, 'network': 'disabled', 'go_version': receipt['manifest']['version']}
    (work / 'request.json').write_text(json.dumps(record, indent=2) + '\n')
    started = time.monotonic()
    with (work / 'console.log').open('wb') as log:
        process = subprocess.Popen(command, stdout=log, stderr=log, start_new_session=True)
        try: record['exit_code'] = process.wait(timeout=wall_seconds); record['timed_out'] = False
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired: os.killpg(process.pid, signal.SIGKILL); process.wait()
            record['exit_code'] = process.returncode; record['timed_out'] = True
    record['wall_seconds'] = time.monotonic() - started
    record['cache_build_succeeded'] = record['exit_code'] == 0 and 'RISH_GO_CACHE_EXIT=0' in (work / 'console.log').read_text(errors='replace')
    record['warmed_disk_path'] = str(disk)
    (work / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps(record, indent=2), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', type=Path, required=True)
    parser.add_argument('--wall-seconds', type=int, default=900)
    parser.add_argument('--receipt', type=Path, help='bare Go build receipt for fresh cache bootstrap')
    args = parser.parse_args()
    if not 1 <= args.wall_seconds <= 900: raise ValueError('cache-build budget must be 1..900 seconds')
    main(args.base.resolve(), args.wall_seconds, args.receipt)
