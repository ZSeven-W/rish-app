#!/usr/bin/env python3
"""Build-only, offline Java CDS derivation. QEMU success is not RISH verification."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import threading
import time
import zipfile
import apk
import java_cds

ROOT = Path(__file__).resolve().parents[2]
ORIGINAL_DISK = 'c4730d4faa1b1df12c9c4f9152b9241c43ab12f87e66c44a2767bd36044bbdea'
ORIGINAL_PACKAGE = '807424202355109c3f06c05823e1972f2e3bfea3e642d45f42f8926e3925df8d'
BASE_ID = 'java-21-0-12-p8-alpine3-23-amd64'
JMODS = ['java.compiler', 'jdk.compiler', 'jdk.httpserver']


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as file:
        while block := file.read(1 << 20): value.update(block)
    return value.hexdigest()


def controlled_asset(relative):
    rows = (ROOT / 'third-party/guest/manifest.tsv').read_text().splitlines()
    row = next(line.split('\t') for line in rows if line.startswith('asset\t' + relative + '\t'))
    path = ROOT / relative
    if path.stat().st_size != int(row[2]) or digest(path) != row[3]:
        raise ValueError('controlled guest asset integrity mismatch')
    return path


def make_classlist(rootfs):
    original = java_cds.read_regular(rootfs / (java_cds.JDK + 'lib/classlist'), 1 << 20)
    if not original.endswith(b'\n'): raise ValueError('unexpected original classlist termination')
    base = {line.split()[0] for line in original.decode().splitlines() if line and not line.startswith(('#', '@'))}
    additional = set()
    for module in JMODS:
        with zipfile.ZipFile(rootfs / (java_cds.JDK + 'jmods/' + module + '.jmod')) as archive:
            for name in archive.namelist():
                if name.startswith('classes/') and name.endswith('.class') and name != 'classes/module-info.class':
                    name = name[len('classes/'):-len('.class')]
                    if not re.fullmatch(r'[a-zA-Z0-9_$/]+', name):
                        raise ValueError('unexpected signed JMOD class name')
                    additional.add(name)
    extra = sorted(additional - base)
    data = original + b'# RISH extension: class names from exact signed JDK jmods only\n'
    data += ('\n'.join(extra) + '\n').encode()
    return data, {'original_classes': len(base), 'additional_classes': len(extra),
                  'classlist_sha256': java_cds.digest(data), 'classlist_bytes': len(data)}


def run_qemu(command, work, wall_seconds, proof):
    started = time.monotonic()
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
    reasons = []
    proof['qemu_pid'] = process.pid
    (work / 'active.json').write_text(json.dumps({'pid': process.pid, 'wall_limit_seconds': wall_seconds}) + '\n')
    print(f'QEMU_STARTED pid={process.pid} limit={wall_seconds}', flush=True)

    def stop(reason):
        if process.poll() is None:
            reasons.append(reason)
            try: os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError: pass

    def interrupted(signum, frame):
        stop('driver_signal_' + str(signum))

    previous = {s: signal.signal(s, interrupted) for s in (signal.SIGINT, signal.SIGTERM)}
    timer = threading.Timer(wall_seconds, lambda: stop('host_timeout'))
    timer.start()
    pending = b''; total = 0
    try:
        with (work / 'console.log').open('wb') as log:
            while block := os.read(process.stdout.fileno(), 65536):
                total += len(block)
                if total > 8 << 20:
                    stop('console_limit'); continue
                log.write(block); log.flush(); pending += block
                while b'\n' in pending:
                    line, pending = pending.split(b'\n', 1)
                    if b'RISH_JAVA_CDS_' in line:
                        text = line.decode(errors='replace').strip()
                        proof['phases'].append({'text': text, 'elapsed_seconds': time.monotonic() - started})
                        print(text, flush=True)
        process.wait(timeout=10)
    finally:
        timer.cancel(); stop('driver_cleanup'); process.wait(timeout=10)
        process.stdout.close()
        for signum, handler in previous.items(): signal.signal(signum, handler)
        (work / 'active.json').unlink(missing_ok=True)
    proof.update(exit_code=process.returncode, wall_seconds=time.monotonic() - started,
                 termination_reasons=reasons, console_bytes=total, console_sha256=digest(work / 'console.log'))
    log = (work / 'console.log').read_text(errors='replace')
    proof['build_succeeded'] = (process.returncode == 0 and not reasons
        and 'RISH_JAVA_CDS_BUILD_EXIT=0' in log and 'RISH_JAVA_CDS_EXPORT_EXIT=0' in log)
    print('QEMU_CLOSED ' + json.dumps({k: proof[k] for k in ['exit_code', 'wall_seconds', 'build_succeeded']}), flush=True)


def finalize(work, bindings, proof):
    files = java_cds.read_export(work / 'export.tar.disk')
    inventory = files[java_cds.EVIDENCE + 'archive-inventory.txt']
    validation = java_cds.validate_archive(files[java_cds.DESTINATION], inventory)
    text = inventory.decode()
    classpaths = re.findall(r'Expecting -Djava.class.path=(.*)', text)
    if not classpaths or any(value.strip() for value in classpaths):
        raise ValueError('CDS candidate binds an application classpath')
    output = work / 'candidate-inputs'; output.mkdir()
    filename = 'rish-compiler-http-21.0.12-static18.jsa'
    (output / filename).write_bytes(files[java_cds.DESTINATION])
    (output / 'archive-inventory.txt').write_bytes(inventory)
    for name in ['flags.txt', 'dump.log']:
        (output / name).write_bytes(files[java_cds.EVIDENCE + name])
    descriptor = {'schema_version': 1, 'kind': 'java-static-cds', 'filename': filename,
        'bytes': len(files[java_cds.DESTINATION]), 'sha256': java_cds.digest(files[java_cds.DESTINATION]),
        'inventory_filename': 'archive-inventory.txt', 'inventory_sha256': java_cds.digest(inventory),
        'source_bindings': bindings, 'environment_id': BASE_ID + '-r1', 'version': '21.0.12_p8+cds.1',
        'build_only': True, 'runtime_verified': False, 'backend': 'QEMU TCG microvm, offline, 1 CPU, 1024 MiB',
        'classlist_sha256': proof['classlist_sha256'], 'builder_receipt_sha256': digest(work / 'result.json'),
        'flags_sha256': java_cds.digest(files[java_cds.EVIDENCE + 'flags.txt']),
        'dump_log_sha256': java_cds.digest(files[java_cds.EVIDENCE + 'dump.log'])}
    (output / 'java-cds.json').write_text(json.dumps(descriptor, indent=2) + '\n')
    (work / 'archive-validation.json').write_text(json.dumps(validation, indent=2) + '\n')
    return descriptor


def main(receipt_path, work, wall_seconds):
    if not 1 <= wall_seconds <= 900: raise ValueError('build deadline must be 1..900 seconds')
    if ',' in str(work): raise ValueError('QEMU drive paths must not contain commas')
    receipt = json.loads(receipt_path.read_text())
    if receipt['manifest']['environment_id'] != BASE_ID: raise ValueError('expected exact original Java package')
    source, package = Path(receipt['disk_path']), Path(receipt['package_path'])
    if digest(source) != ORIGINAL_DISK or digest(package) != ORIGINAL_PACKAGE:
        raise ValueError('original Java input integrity mismatch')
    rootfs = Path(receipt['rootfs_path'])
    bindings = {}
    for path in java_cds.REQUIRED_BINDINGS:
        file = rootfs / path
        bindings[path] = {'bytes': file.stat().st_size, 'sha256': digest(file)}
    classlist, classproof = make_classlist(rootfs)
    if classproof['classlist_sha256'] != '4128f0378e76ed20bfae8f1036b75a8062343a3626649c9c6233ba17e9af3693':
        raise ValueError('classlist differs from reviewed exact JDK module inventory')
    base = controlled_asset('modules/rish/shared/GuestAssets/rish-container.cpio')
    kernel = controlled_asset('modules/rish/shared/GuestAssets/vmlinuz-virt-6.18.35')
    work.mkdir(parents=True, exist_ok=False)
    (work / 'compiler-http.classlist').write_bytes(classlist)
    (work / 'classlist-receipt.json').write_text(json.dumps(classproof, indent=2) + '\n')
    (work / 'source-bindings.json').write_text(json.dumps(bindings, indent=2) + '\n')
    disk = work / 'derived.ext4'
    if subprocess.run(['/bin/cp', '-c', str(source), str(disk)], capture_output=True).returncode:
        shutil.copyfile(source, disk)
    export = work / 'export.tar.disk'
    with export.open('xb') as file: file.truncate(256 << 20)
    entries = apk.read_newc(base)
    final_exec = 'exec /usr/bin/rish-guest-agent </dev/null >/dev/null 2>/dev/ttyS0'
    original = entries['init'][1].decode()
    if original.count(final_exec) != 1: raise ValueError('unknown controlled init suffix')
    suffix = Path(__file__).with_name('java-cds-init.sh').read_text()
    entries['init'] = stat.S_IFREG | 0o755, original.replace(final_exec, suffix).encode()
    entries['rish-cds-input'] = stat.S_IFDIR | 0o755, b''
    entries['rish-cds-input/classes.list'] = stat.S_IFREG | 0o644, classlist
    hashes = ''.join(value['sha256'] + '  /' + path + '\n' for path, value in bindings.items())
    entries['rish-cds-input/expected.sha256'] = stat.S_IFREG | 0o644, hashes.encode()
    spec = importlib.util.spec_from_file_location('cds_newc', Path(__file__).with_name('warm-go-cache.py'))
    packer = importlib.util.module_from_spec(spec); spec.loader.exec_module(packer)
    initrd = work / 'builder.cpio'; packer.pack_newc(entries, initrd)
    (work / 'builder-init.sh').write_bytes(entries['init'][1])
    command = ['qemu-system-x86_64', '-accel', 'tcg,thread=single', '-machine', 'microvm,auto-kernel-cmdline=on',
        '-cpu', 'qemu64', '-m', '1024', '-smp', '1', '-kernel', str(kernel), '-initrd', str(initrd),
        '-append', 'console=ttyS0,115200n8 rdinit=/init panic=-1 oops=panic nokaslr',
        '-drive', 'file=' + str(disk) + ',format=raw,if=none,id=runtime', '-device', 'virtio-blk-device,drive=runtime',
        '-drive', 'file=' + str(export) + ',format=raw,if=none,id=export', '-device', 'virtio-blk-device,drive=export',
        '-nographic', '-no-reboot', '-nic', 'none']
    proof = {'purpose': 'build-only static JDK compiler/http CDS; not RISH runtime verification',
        'command': command, 'wall_limit_seconds': wall_seconds, 'memory_mib': 1024, 'vcpu_count': 1,
        'network': 'disabled', 'source_disk_sha256': ORIGINAL_DISK, 'source_package_sha256': ORIGINAL_PACKAGE,
        'classlist_sha256': classproof['classlist_sha256'], 'base_sha256': digest(base),
        'kernel_sha256': digest(kernel), 'builder_initrd_sha256': digest(initrd), 'phases': [], 'runtime_verified': False}
    (work / 'request.json').write_text(json.dumps(proof, indent=2) + '\n')
    try: run_qemu(command, work, wall_seconds, proof)
    finally:
        proof['old_source_disk_unchanged'] = digest(source) == ORIGINAL_DISK
        proof['old_package_unchanged'] = digest(package) == ORIGINAL_PACKAGE
        (work / 'result.json').write_text(json.dumps(proof, indent=2) + '\n')
    if not proof['build_succeeded'] or not proof['old_source_disk_unchanged'] or not proof['old_package_unchanged']:
        raise ValueError('CDS build failed; preserve its bounded console and exported diagnostic files')
    print(json.dumps(finalize(work, bindings, proof), indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--receipt', type=Path, default=ROOT / '.build/runtime-environments/packages/java.build.json')
    parser.add_argument('--output', type=Path, required=True, help='new isolated output directory, must not exist')
    parser.add_argument('--wall-seconds', type=int, default=900)
    args = parser.parse_args()
    main(args.receipt.resolve(), args.output.resolve(), args.wall_seconds)
