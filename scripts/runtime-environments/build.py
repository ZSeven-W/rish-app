#!/usr/bin/env python3
"""Build one locked RISHENV1 ext4 environment; guest code never runs on host."""
from __future__ import annotations
import argparse
import concurrent.futures
import gzip
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import stat
import struct
import subprocess
import tempfile
import time
import uuid
import zipfile
import apk
import ext4
import package as environment_package
import python_cache
import java_cds

REPO = Path(__file__).resolve().parents[2]
LOCKS = REPO / 'runtime-environments'
DEFAULT_OUTPUT = REPO / '.build/runtime-environments/packages'
EPOCH = 1789430400
APPLET_NAMES = 'sh ash env cat cp mv mkdir rm ln uname pwd printf echo ls sort grep sed awk head tail cut tr find xargs touch chmod basename dirname readlink test true false sleep wc which tee'.split()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as file:
        while chunk := file.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _download_unlocked(url: str, destination: Path, size: int, expected_sha256: str | None = None) -> None:
    if not url.startswith('https://'):
        raise ValueError('downloads require HTTPS')
    destination.parent.mkdir(parents=True, exist_ok=True)
    if not destination.exists():
        temporary = destination.with_suffix(destination.suffix + '.partial')
        result = subprocess.run(
            ['curl', '--http1.1', '--fail', '--location', '--silent', '--show-error', '--max-time', '180', '--retry', '2', '--retry-all-errors',
             '--max-filesize', str(size), url, '-o', str(temporary)], check=False,
        )
        if result.returncode:
            raise ValueError('download failed: ' + destination.name)
        if temporary.stat().st_size != size:
            raise ValueError('download size mismatch')
        temporary.replace(destination)
    if destination.stat().st_size != size:
        raise ValueError('cached download size mismatch')
    if expected_sha256 and sha256(destination) != expected_sha256:
        raise ValueError('download SHA256 mismatch')


def download(url: str, destination: Path, size: int, expected_sha256: str | None = None) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.with_suffix(destination.suffix + '.lock').open('a') as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        _download_unlocked(url, destination, size, expected_sha256)


def cache_path(downloads: Path, filename: str, url: str) -> Path:
    # Different Alpine branches can publish the same filename with different
    # signed contents; cache identity includes the complete source URL.
    return downloads / (hashlib.sha256(url.encode()).hexdigest()[:16] + '-' + filename)


def add_layout(entries: dict, lock: dict) -> None:
    for name in ['bin', 'usr', 'usr/bin', 'workspace', 'tmp', 'proc', 'sys', 'dev', 'etc', 'root']:
        entries.setdefault(name, (stat.S_IFDIR | (0o1777 if name == 'tmp' else 0o755), b''))
    for name in APPLET_NAMES:
        entries.setdefault('bin/' + name, (stat.S_IFLNK | 0o777, b'busybox'))
    for destination, target in lock.get('entry_links', {}).items():
        entries[destination] = (stat.S_IFLNK | 0o777, apk.safe_link(destination, target).encode())
    entries.setdefault('etc/passwd', (stat.S_IFREG | 0o644, b'root:x:0:0:root:/root:/bin/sh\n'))
    entries.setdefault('etc/group', (stat.S_IFREG | 0o644, b'root:x:0:\n'))
    entries.setdefault('etc/hosts', (stat.S_IFREG | 0o644, b'127.0.0.1 localhost\n'))
    if lock['family'] == 'node':
        # npm's official entrypoint is #!/usr/bin/env node.
        entries['usr/bin/env'] = (stat.S_IFLNK | 0o777, b'../../bin/busybox')
    if lock['family'] == 'python':
        # The installation target is a disposable guest disk, never host Python.
        entries['etc/pip.conf'] = (stat.S_IFREG | 0o644, b'[global]\nbreak-system-packages = true\ndisable-pip-version-check = true\n')
    provenance = {'schema_version': 1, 'environment_id': lock['environment_id'],
                  'alpine_version': lock['alpine_version'], 'packages': lock['packages'],
                  'extra_archives': lock.get('extra_archives', []),
                  'derived_archives': lock.get('derived_archives', []),
                  'build_scripts_executed_in_guest': any(
                      item.get('kind') == 'java-static-cds' for item in lock.get('derived_archives', []))}
    if lock['family'] == 'python':
        provenance['python_bytecode'] = lock['python_bytecode']
    entries['usr/share/doc/rish-environment/sources.json'] = (
        stat.S_IFREG | 0o644, (json.dumps(provenance, sort_keys=True, indent=2) + '\n').encode())
    entries['usr/share/doc/rish-environment/README.txt'] = (
        stat.S_IFREG | 0o644,
        b'Official signed Alpine packages. sources.json pins package versions, licenses,\n'
        b'build recipes and source commits. No APK install scripts were executed.\n'
        b'Filesystem snapshot writes remain inside this disposable guest disk.\n')
    required = ['bin/sh', lock['entrypoint']]
    for name in required:
        current = name
        for _ in range(12):
            if current not in entries:
                raise ValueError('missing environment entrypoint: ' + current)
            mode, data = entries[current]
            if stat.S_ISREG(mode):
                break
            if not stat.S_ISLNK(mode):
                raise ValueError('entrypoint is not a regular executable')
            current = os.path.normpath(os.path.join(os.path.dirname(current), data.decode()))
        else:
            raise ValueError('entrypoint link cycle')


def pack_ext4(root: Path, disk: Path, lock: dict, output: Path) -> None:
    mke2fs = os.environ.get('RISH_MKE2FS') or shutil.which('mke2fs')
    for candidate in [Path('/opt/homebrew/opt/e2fsprogs/sbin/mke2fs'), Path.home() / 'Library/Android/sdk/platform-tools/mke2fs']:
        if not mke2fs and candidate.is_file():
            mke2fs = str(candidate)
    if not mke2fs:
        raise ValueError('mke2fs is required; set RISH_MKE2FS')
    disk_bytes = lock['disk_mib'] * 1024 * 1024
    if shutil.disk_usage(output).free < disk_bytes * 2:
        raise ValueError('insufficient space for environment disk')
    with disk.open('xb') as file:
        file.truncate(disk_bytes)
    deterministic_uuid = str(uuid.uuid5(uuid.NAMESPACE_URL, lock['environment_id']))
    command = [mke2fs, '-q', '-F', '-t', 'ext4', '-b', '4096', '-I', '256', '-m', '0',
               '-U', deterministic_uuid, '-L', lock['family'],
               '-O', 'extent,dir_index,filetype,sparse_super,large_file,^has_journal,^metadata_csum,^64bit',
               '-E', 'root_owner=0:0,hash_seed=' + deterministic_uuid + ',lazy_itable_init=0,lazy_journal_init=0',
               '-d', str(root), str(disk)]
    result = subprocess.run(command, capture_output=True, text=True,
                            env={**os.environ, 'E2FSPROGS_FAKE_TIME': str(EPOCH), 'SOURCE_DATE_EPOCH': str(EPOCH)})
    (disk.parent / 'mke2fs.log').write_text(result.stdout + result.stderr)
    if result.returncode:
        raise ValueError('ext4 construction failed; see mke2fs.log')
    with disk.open('rb') as file:
        file.seek(1024 + 56)
        if file.read(2) != b'\x53\xef':
            raise ValueError('missing ext4 magic')
    ext4.normalize_metadata(disk, EPOCH)


def build(family: str, output: Path, download_limit_mib: int, bootstrap_go_cache: bool = False,
          java_cds_receipt: Path | None = None) -> dict:
    lock_path = LOCKS / (family + '.lock.json')
    lock = json.loads(lock_path.read_text())
    cds_input = None
    if java_cds_receipt is not None:
        if family != 'java' or bootstrap_go_cache:
            raise ValueError('CDS derivation applies only to Java')
        cds_input = java_cds.load_candidate(java_cds_receipt)
        descriptor = cds_input[0]
        identifier, version = descriptor.get('environment_id'), descriptor.get('version')
        if (not isinstance(identifier, str) or not identifier.startswith(lock['environment_id'] + '-')
                or not isinstance(version, str) or not version.startswith(lock['version'] + '+')):
            raise ValueError('CDS candidate must have a new environment identity and version')
        lock['environment_id'], lock['version'] = identifier, version
    if bootstrap_go_cache:
        if family != 'go': raise ValueError('cache bootstrap applies only to Go')
        lock.pop('derived_archives', None)
    if lock['schema_version'] != 1 or lock['family'] != family:
        raise ValueError('invalid build lock')
    if type(lock.get('disk_mib')) is not int or not 1 <= lock['disk_mib'] <= 4096:
        raise ValueError('invalid locked disk size')
    expected_manifest = {key: lock[key] for key in environment_package.MANIFEST_KEYS - {'disk_sha256', 'disk_bytes'}}
    expected_manifest.update({'disk_sha256': '0' * 64, 'disk_bytes': lock['disk_mib'] * 1024 * 1024})
    environment_package.validate_manifest(expected_manifest)
    kernel = REPO / 'modules/rish/shared/GuestAssets/vmlinuz-virt-6.18.35'
    if sha256(kernel) != lock['kernel_sha256']:
        raise ValueError('locked kernel differs from application kernel')
    planned = sum(p['package_bytes'] for p in lock['packages'])
    planned += sum(p['bytes'] for p in lock.get('extra_archives', []))
    if planned > download_limit_mib * 1024 * 1024:
        raise ValueError('download budget exceeded')
    output.mkdir(parents=True, exist_ok=True)
    downloads = output / 'downloads'
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        futures = [pool.submit(download, p['url'], cache_path(downloads, p['filename'], p['url']), p['package_bytes'], p.get('sha256')) for p in lock['packages']]
        for future in futures:
            future.result()
    for archive in lock.get('extra_archives', []):
        download(archive['url'], cache_path(downloads, archive['filename'], archive['url']), archive['bytes'], archive['sha256'])
    work = Path(tempfile.mkdtemp(prefix=family + '-', dir=output))
    entries, verified = {}, []
    for package in lock['packages']:
        data, checks = apk.verify_package(cache_path(downloads, package['filename'], package['url']), package, LOCKS / 'keys', work / 'checks' / package['name'])
        apk.add_tar(entries, data)
        verified.append({'name': package['name'], 'version': package['version'], **checks})
    for archive in lock.get('extra_archives', []):
        if archive['kind'] != 'bun-official-zip':
            raise ValueError('unknown extra archive')
        with zipfile.ZipFile(cache_path(downloads, archive['filename'], archive['url'])) as zipped:
            names = zipped.namelist()
            for name in names:
                apk.safe_path(name)
            binary = zipped.read(archive['member'])
            if hashlib.sha256(binary).hexdigest() != archive['binary_sha256']:
                raise ValueError('Bun binary digest mismatch')
            entries['usr/bin/bun'] = stat.S_IFREG | 0o755, binary
    for derived in lock.get('derived_archives', []):
        if derived.get('prefix') != 'tmp/go-build' or family != 'go':
            raise ValueError('unsupported derived build data')
        if Path(derived['filename']).name != derived['filename']:
            raise ValueError('derived cache filename must be a basename')
        cache = downloads / derived['filename']
        if not cache.is_file() or cache.stat().st_size != derived['bytes'] or sha256(cache) != derived['sha256']:
            raise ValueError('required verified Go cache artifact is missing; run the documented cache builder')
        parts = apk.gzip_members(cache.read_bytes())
        if len(parts) != 1:
            raise ValueError('derived cache must contain one gzip tar stream')
        cache_entries = {}
        apk.add_tar(cache_entries, parts[0][1])
        if any(name != 'tmp/go-build' and not name.startswith('tmp/go-build/') for name in cache_entries):
            raise ValueError('derived cache escaped its fixed prefix')
        for name, entry in cache_entries.items():
            if name in entries and entries[name] != entry:
                raise ValueError('derived cache conflicts with signed package data')
            entries[name] = entry
    cds_validation = None
    if cds_input is not None:
        cds_validation = java_cds.install(entries, *cds_input)
        lock['derived_archives'] = [cds_input[0]]
    add_layout(entries, lock)
    bytecode_validation = python_cache.validate(entries, lock)
    contents_bytes = sum(len(data) for mode, data in entries.values() if stat.S_ISREG(mode))
    if contents_bytes + 48 * 1024 * 1024 > lock['disk_mib'] * 1024 * 1024:
        raise ValueError('environment lacks required workspace/scratch capacity')
    root = work / 'rootfs'
    apk.stage_entries(entries, root, EPOCH)
    entries.clear()
    disk = work / 'rootfs.ext4'
    pack_ext4(root, disk, lock, output)
    scratch_bytes = None
    if family == 'python' or cds_input is not None:
        scratch_bytes = ext4.available_bytes(disk)
        if scratch_bytes < 48 * 1024 * 1024:
            raise ValueError('environment ext4 lacks the required 48 MiB of free scratch capacity')
    manifest = {key: lock[key] for key in ['schema_version', 'environment_id', 'family', 'display_name', 'version', 'architecture', 'kernel_sha256', 'minimum_memory_mib']}
    manifest.update({'disk_sha256': sha256(disk), 'disk_bytes': disk.stat().st_size})
    header = json.dumps(manifest, separators=(',', ':'), sort_keys=True).encode('utf-8')
    if not 1 <= len(header) <= 16384:
        raise ValueError('manifest exceeds header budget')
    package = output / (lock['environment_id'] + '.rishenv')
    temporary = package.with_suffix('.rishenv.partial')
    with temporary.open('wb') as out:
        out.write(b'RISHENV1' + struct.pack('>I', len(header)) + header)
        with gzip.GzipFile(filename='', fileobj=out, mode='wb', compresslevel=6, mtime=0) as zipped:
            with disk.open('rb') as source:
                shutil.copyfileobj(source, zipped, length=1024 * 1024)
    if temporary.stat().st_size > 768 * 1024 * 1024:
        raise ValueError('package exceeds native import limit')
    verified_package = environment_package.verify(temporary, lock['kernel_sha256'])
    if verified_package['manifest'] != manifest:
        raise ValueError('written package manifest differs from construction input')
    temporary.replace(package)
    receipt = {'manifest': manifest, 'package_path': str(package), 'package_sha256': verified_package['package_sha256'],
               'package_bytes': package.stat().st_size, 'disk_path': str(disk), 'rootfs_path': str(root),
               'contents_bytes': contents_bytes, 'lock_sha256': sha256(lock_path), 'verified_packages': verified,
               'execution_verified': False, 'backend': None, 'host_guest_code_execution': False, 'bootstrap_go_cache': bootstrap_go_cache}
    if bytecode_validation:
        receipt['python_bytecode_validation'] = bytecode_validation
        receipt['free_scratch_bytes'] = scratch_bytes
    if cds_validation:
        receipt['java_cds_validation'] = cds_validation
        receipt['java_cds_receipt_sha256'] = sha256(java_cds_receipt)
        receipt['free_scratch_bytes'] = scratch_bytes
    (output / (family + '.build.json')).write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps({key: receipt[key] for key in ['manifest', 'package_path', 'package_bytes', 'package_sha256', 'disk_path']}, indent=2), flush=True)
    return receipt


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('family', choices=['python', 'java', 'go', 'rust', 'bun', 'node'])
    parser.add_argument('--output', type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument('--download-limit-mib', type=int, default=1024)
    parser.add_argument('--bootstrap-go-cache', action='store_true', help='build a bare Go disk only for controlled std-cache generation')
    parser.add_argument('--java-cds-receipt', type=Path,
                        help='add a verified build-only CDS file to a fresh Java candidate; does not edit its lock or catalog')
    arguments = parser.parse_args()
    build(arguments.family, arguments.output.resolve(), arguments.download_limit_mib, arguments.bootstrap_go_cache,
          arguments.java_cds_receipt.resolve() if arguments.java_cds_receipt else None)
