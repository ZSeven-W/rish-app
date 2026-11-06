#!/usr/bin/env python3
"""Export only Go cache data through a dedicated blank QEMU block disk."""
from pathlib import Path
import sys,subprocess,json,time,stat,os,signal
ROOT=Path(__file__).resolve().parents[2];sys.path.insert(0,str(ROOT/'scripts/runtime-environments'))
import apk
import importlib.util
spec=importlib.util.spec_from_file_location('warmer',ROOT/'scripts/runtime-environments/warm-go-cache.py');warmer=importlib.util.module_from_spec(spec);spec.loader.exec_module(warmer)
work=ROOT/'.build/runtime-environments/packages/go-cache-builder';result=json.loads((work/'result.json').read_text());assert result['cache_build_succeeded']
entries=apk.read_newc(ROOT/'.build/runtime-environments/rish-runtime-base.cpio');original=entries['init'][1].decode().rsplit('exec /usr/bin/rish-guest-agent',1)[0]
script='''
set -e
mkdir -p /runtime
mount -t ext4 -o ro /dev/vda /runtime
set +e
tar -C /runtime -cf /dev/vdb tmp/go-build
rc=$?
echo RISH_GO_CACHE_EXPORT_EXIT=$rc
sync
/bin/busybox poweroff -f
'''
entries['init']=(stat.S_IFREG|0o755,(original+script).encode());base=work/'export-base.cpio';warmer.pack_newc(entries,base)
output=work/'cache-export.tar.disk'
with output.open('wb') as f:f.truncate(1024**3)
command=['qemu-system-x86_64','-accel','tcg,thread=single','-machine','microvm,auto-kernel-cmdline=on','-cpu','qemu64','-m','1024','-smp','1','-kernel',str(ROOT/'modules/rish/shared/GuestAssets/vmlinuz-virt-6.18.35'),'-initrd',str(base),'-append','console=ttyS0,115200n8 rdinit=/init panic=-1 oops=panic nokaslr','-drive','file='+result['warmed_disk_path']+',format=raw,if=none,id=runtime,readonly=on','-device','virtio-blk-device,drive=runtime','-drive','file='+str(output)+',format=raw,if=none,id=export','-device','virtio-blk-device,drive=export','-nographic','-no-reboot','-nic','none']
started=time.monotonic()
with (work/'export-console.log').open('wb') as log:
 p=subprocess.Popen(command,stdout=log,stderr=log,start_new_session=True)
 try:code=p.wait(timeout=180)
 except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait();code=p.returncode
ok=code==0 and 'RISH_GO_CACHE_EXPORT_EXIT=0' in (work/'export-console.log').read_text(errors='replace');r={'success':ok,'exit_code':code,'wall_seconds':time.monotonic()-started,'cache_tar_path':str(output),'backend':'QEMU build-data export only, not rish execution verification'};(work/'export-result.json').write_text(json.dumps(r,indent=2)+'\n');print(r)
