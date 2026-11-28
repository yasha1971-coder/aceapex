#!/usr/bin/env python3
"""Run only correctness/representation probes on the registered C4 SPOT VM."""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile


def sha(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as f:
        for b in iter(lambda:f.read(4*1024*1024),b''):h.update(b)
    return h.hexdigest()


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--source-sha',required=True)
    args=parser.parse_args()
    root=Path('/work/crown2');source=root/'source/research/crown2-bwt'
    logs=root/'evidence';logs.mkdir(exist_ok=False)
    build=root/'build';prepared=root/'prepared';inputs=root/'inputs'
    manifest={}
    records=[]
    def run(label,argv,required=True):
        r=subprocess.run(argv,capture_output=True)
        (logs/(label+'.stdout')).write_bytes(r.stdout)
        (logs/(label+'.stderr')).write_bytes(r.stderr)
        records.append({'label':label,'argv':argv,'returncode':r.returncode,
                        'stdout_sha256':hashlib.sha256(r.stdout).hexdigest(),
                        'stderr_sha256':hashlib.sha256(r.stderr).hexdigest()})
        print(json.dumps({'event':label,'returncode':r.returncode}),flush=True)
        if required and r.returncode:raise RuntimeError(label+' failed; stop before any timing')
        return r
    result={'source_sha':args.source_sha,'utc_start':dt.datetime.now(dt.timezone.utc).isoformat(),
            'scope':'C4 SPOT correctness/bytes only; no speed interpretation',
            'inputs':manifest,'status':'STARTED'}
    try:
        manifest=json.loads((root/'input-manifest.json').read_text())
        result['inputs']=manifest
        assert manifest['source_sha']==args.source_sha and sha(root/'source.tar')==manifest['source_archive_sha256']
        for name,rec in manifest['inputs'].items():
            p=inputs/name
            assert p.is_file() and not p.is_symlink() and p.stat().st_size==rec['bytes'] and sha(p)==rec['sha256'],name
        run('uname',['uname','-a']);run('compiler',['gcc','--version']);run('glibc',['ldd','--version'])
        run('configure',['cmake','-S',str(source),'-B',str(build),'-DCMAKE_C_COMPILER=gcc','-DCMAKE_CXX_COMPILER=g++'])
        run('build',['cmake','--build',str(build),'--target','crown2_probe','-j','4'])
        probe=build/'crown2_probe';lib=build/'libcrown2_baseline.so'
        exports=run('baseline-exports',['nm','-D','--defined-only',str(lib)]).stdout.decode()
        assert 'libsais' not in exports and 'bsc_' not in exports,'baseline dependency symbol escaped isolation'
        assert all(s in exports for s in ['baseline_encode','baseline_decode','baseline_decode_inplace'])
        dynamic=run('probe-dynamic',['readelf','-d',str(probe)]).stdout.decode()
        assert '$ORIGIN' in dynamic,'missing sibling baseline DSO lookup'
        run('linked-libraries',['ldd',str(probe)])
        run('selftest',[str(probe),'selftest'])
        run('prepare',[str(probe),'prepare',str(inputs),str(prepared)])
        # Instruction availability is ancillary. A counter setup failure is
        # retained and never reinterpreted as a codec correctness failure.
        if shutil.which('perf'):
            counter=run('instructions',['sudo','-n','perf','stat','-e','instructions:u','-x,','-o',str(logs/'instructions.csv'),'--',str(probe),'selftest'],required=False)
            result['instruction_counter']='available' if counter.returncode==0 else 'unavailable; retained diagnostics'
        else:result['instruction_counter']='unavailable: perf absent'
        output=[]
        for name,rec in manifest['inputs'].items():
            case=prepared/name
            for packet in sorted(case.glob('*.packet')):
                restored=packet.with_name(packet.stem+'.restored.bin')
                actual=sha(restored)
                assert actual==rec['sha256'] and restored.stat().st_size==rec['bytes']
                output.append({'piece':name,'packet':str(packet.relative_to(root)),
                               'bytes':packet.stat().st_size,'sha256':sha(packet),
                               'restored':str(restored.relative_to(root)),
                               'restored_sha256':actual,'byte_equal':True})
        assert len(output)==42
        result.update(status='PASS',representations=output,binaries={p.name:{'bytes':p.stat().st_size,'sha256':sha(p)} for p in [probe,lib]})
    except BaseException as error:
        result.update(status='FAIL',error=repr(error));raise
    finally:
        result.update(utc_end=dt.datetime.now(dt.timezone.utc).isoformat(),commands=records)
        (logs/'cloud-result.json').write_text(json.dumps(result,sort_keys=True,indent=2)+'\n')
        # Preserve failed attempts too. The controller retrieves this before
        # deleting this task's VM, then confirms VM/disk absence.
        with tarfile.open(root/'artifacts.tar.gz','w:gz') as tar:
            tar.add(logs,arcname='evidence')
            if prepared.exists():tar.add(prepared,arcname='prepared')
            for p in [build/'crown2_probe',build/'libcrown2_baseline.so',build/'compile_commands.json']:
                if p.is_file():tar.add(p,arcname='bin/'+p.name)
        print(json.dumps({'event':'artifacts_saved','status':result['status'],
                          'archive_sha256':sha(root/'artifacts.tar.gz'),
                          'archive_bytes':(root/'artifacts.tar.gz').stat().st_size}),flush=True)
    return 0


if __name__=='__main__':raise SystemExit(main())
