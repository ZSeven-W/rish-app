#!/usr/bin/env python3
"""Exercise a built disk with an explicitly selected current pure-Rust host."""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import shutil
import threading
import time

REPO = Path(__file__).resolve().parents[2]
OUT = REPO / '.build/runtime-environments/packages'
SCRIPTS = {
    'python': '/usr/bin/python3 -I -B -c \'import sys, json, socket, http.server; print("RISH_PYTHON_OK", sys.version.split()[0], 6 * 7, flush=True)\'',
    'java': "printf '%s\\n' 'class Main { public static void main(String[] args) { System.out.println(\"RISH_JAVA_OK \" + (6 * 7)); }}' > Main.java; /usr/bin/java /workspace/Main.java",
    'go': "printf '%s\\n' 'package main' 'import \"fmt\"' 'func main() { fmt.Println(\"RISH_GO_OK\", 6 * 7) }' > main.go; GOTOOLCHAIN=local GOPROXY=off /usr/bin/go run /workspace/main.go",
    'rust': "printf '%s\\n' 'fn main() { println!(\"RISH_RUST_OK {}\", 6 * 7); }' > main.rs; /usr/bin/rustc --edition=2024 main.rs -o main && ./main",
    'bun': '/usr/bin/bun -e \'console.log("RISH_BUN_OK", process.arch, process.platform, 6 * 7)\'',
    'node': '/usr/bin/node -e \'console.log("RISH_NODE_OK", process.arch, process.platform, 6 * 7)\'',
}


def digest(path):
    sha = hashlib.sha256()
    with path.open('rb') as file:
        while block := file.read(1024 * 1024):
            sha.update(block)
    return sha.hexdigest()


def run(family, library, base, wall_seconds, exec_seconds=None, run_label=None):
    receipt = json.loads((OUT / (family + '.build.json')).read_text())
    work = OUT / (family + '-smoke' + ('-' + run_label if run_label else ''))
    if work.exists():
        raise ValueError('refusing to overwrite prior smoke evidence')
    work.mkdir()
    disk = work / 'run.ext4'
    # Use APFS clone when available; never mutate the immutable installed source.
    import subprocess
    copy = subprocess.run(['/bin/cp', '-c', receipt['disk_path'], str(disk)], capture_output=True)
    if copy.returncode:
        shutil.copyfile(receipt['disk_path'], disk)
    kernel = REPO / 'modules/rish/shared/GuestAssets/vmlinuz-virt-6.18.35'
    request = {'kernel_path': str(kernel), 'initrd_path': str(base), 'root_disk_path': str(disk),
               'memory_mib': receipt['manifest']['minimum_memory_mib'], 'network': 'disabled', 'command': ['true'],
               'command_line': 'console=ttyS0,115200n8 rdinit=/init panic=-1 oops=panic nokaslr cgroup_no_v1=all 8250.nr_uarts=1',
               'boot_budget_units': 60000000000, 'handshake_budget_units': 40000000000}
    inner = 'cd /workspace && ' + SCRIPTS[family]
    # All shell text is owned diagnostic source; entry paths and user args do not
    # enter this diagnostic. Production uses its own descriptor-bound snapshot.
    import shlex
    script = 'set -e; mkdir -p /runtime; mount -t ext4 /dev/vda /runtime; mount -t proc proc /runtime/proc; mount --bind /dev /runtime/dev; mount --bind /sys /runtime/sys; mkdir -p /runtime/tmp/rish-home; chroot /runtime /bin/sh -c ' + shlex.quote(inner)
    execute = {'protocol_version': 2, 'command': ['/bin/sh', '-c', script],
               'cwd': '/', 'env': {'HOME': '/tmp/rish-home', 'PATH': '/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin',
                       'TMPDIR': '/tmp', 'GOCACHE': '/tmp/go-build', 'CARGO_HOME': '/tmp/cargo'},
               'timeout_ms': int((exec_seconds or wall_seconds) * 1000), 'max_output_bytes': 262144}
    (work / 'boot-request.json').write_text(json.dumps(request, indent=2) + '\n')
    (work / 'exec-request.json').write_text(json.dumps(execute, indent=2) + '\n')
    result = {'family': family, 'backend': 'pure-Rust x86_64 interpreter on macOS arm64 via cancellable C ABI',
              'production_ios_execution': False, 'library_path': str(library), 'library_sha256': digest(library),
              'base_sha256': digest(base), 'kernel_sha256': digest(kernel),
              'source_disk_sha256': receipt['manifest']['disk_sha256'], 'wall_limit_seconds': wall_seconds, 'exec_limit_seconds': exec_seconds or wall_seconds,
              'memory_mib': receipt['manifest']['minimum_memory_mib'], 'guest_script': inner}
    lib = ctypes.CDLL(str(library))
    for name in ['rish_vm_cancel_new']:
        getattr(lib, name).argtypes = []; getattr(lib, name).restype = ctypes.c_void_p
    for name in ['rish_vm_cancel_request', 'rish_vm_cancel_free', 'rish_vm_session_free', 'rish_string_free']:
        getattr(lib, name).argtypes = [ctypes.c_void_p]; getattr(lib, name).restype = None
    lib.rish_vm_boot_session_cancellable.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.c_void_p]
    lib.rish_vm_boot_session_cancellable.restype = ctypes.c_void_p
    CALLBACK = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t)
    lib.rish_vm_session_exec_stream_json.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_void_p, CALLBACK]
    lib.rish_vm_session_exec_stream_json.restype = ctypes.c_void_p
    token = lib.rish_vm_cancel_new()
    if not token:
        raise RuntimeError('cancel token creation failed')
    session = None
    cancelled = threading.Event()
    def cancel():
        cancelled.set(); lib.rish_vm_cancel_request(token)
    timer = threading.Timer(wall_seconds, cancel)
    started = time.monotonic()
    with (work / 'events.jsonl').open('w') as events:
        @CALLBACK
        def observe(context, pointer, length):
            event = json.loads(ctypes.string_at(pointer, length))
            events.write(json.dumps({'elapsed_seconds': time.monotonic() - started, **event}) + '\n'); events.flush()
        timer.start()
        try:
            blob = json.dumps(request).encode()
            session = lib.rish_vm_boot_session_cancellable(blob, len(blob), token)
            result['boot_wall_seconds'] = time.monotonic() - started
            if not session:
                result['error'] = 'E_VM_BOOT_CANCELLED' if cancelled.is_set() else 'E_VM_BOOT_FAILED'
            else:
                blob = json.dumps(execute).encode(); command_started = time.monotonic()
                pointer = lib.rish_vm_session_exec_stream_json(session, blob, len(blob), None, observe)
                try:
                    result['reply'] = json.loads(ctypes.string_at(pointer)) if pointer else {'error': 'E_VM_NULL_REPLY'}
                finally:
                    if pointer: lib.rish_string_free(pointer)
                result['command_wall_seconds'] = time.monotonic() - command_started
        finally:
            timer.cancel(); timer.join()
            if session: lib.rish_vm_session_free(session)
            lib.rish_vm_cancel_free(token)
    result['total_wall_seconds'] = time.monotonic() - started
    result['cancel_requested'] = cancelled.is_set()
    marker = 'RISH_' + family.upper() + '_OK'
    result['execution_verified'] = result.get('reply', {}).get('exit_code') == 0 and marker in result.get('reply', {}).get('stdout', '')
    (work / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('family', choices=list(SCRIPTS))
    parser.add_argument('--library', type=Path, required=True)
    parser.add_argument('--base', type=Path, required=True)
    parser.add_argument('--wall-seconds', type=int, default=120)
    parser.add_argument('--exec-seconds', type=int)
    parser.add_argument('--run-label')
    args = parser.parse_args()
    import re
    if not 1 <= args.wall_seconds <= 680 or (args.exec_seconds is not None and not 1 <= args.exec_seconds <= 600):
        raise ValueError('wall budget must be 1..680 seconds, exec 1..600 seconds')
    if args.run_label and not re.fullmatch('[a-z0-9-]{1,40}', args.run_label):
        raise ValueError('invalid run label')
    run(args.family, args.library.resolve(), args.base.resolve(), args.wall_seconds, args.exec_seconds, args.run_label)
