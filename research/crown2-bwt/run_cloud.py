#!/usr/bin/env python3
"""ace-core controller: one task-owned C4 SPOT attempt, preserve, then delete."""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
import time
import uuid
import cloud

INPUTS={
 'd2_text_en':(8388608,'046f85db05c0edd1febd35efc2da541dfe2df301463c0e2b157953228e733b86'),
 'd2_text_src':(8388608,'b736b80247d5ff42850ab4f739743577eec3a132355ec7fccaac801aa7fe875a'),
 'd2_x86':(8388608,'0524f1ff5dff38664a8d49ee34fb3be6062ef96b5c865ac197a9573c188b83fe'),
 'd2_table_sdf':(4194304,'95f2fed1bbb4cc09e1d15d64273696c34196c48780d7045fabb27cde0b44f1e2'),
 'd2_table_db':(4194304,'555aff149ccec419bdfd5479f86f49cab853a59349be33d776e3fd25f16c6de1'),
 'd2_image':(4194304,'45375150a801b0562e1ee934f71c16e70374b990ec3a0c526a9aff626f92d49b'),
 'd2_xml':(4194304,'45b8a5ad4442c4ad5fd70f38fafcf27bf9ba31e5be6f75fdfbe68afd347b2d46')}


def sha(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as f:
        for b in iter(lambda:f.read(4*1024*1024),b''):h.update(b)
    return h.hexdigest()


def main():
    p=argparse.ArgumentParser();p.add_argument('--source-sha',required=True);args=p.parse_args()
    assert re.fullmatch('[0-9a-f]{40}',args.source_sha)
    assert os.uname().nodename=='ace-core'
    os.sched_setaffinity(0,{15});os.nice(15)
    here=Path(__file__).resolve().parent;repo=here.parent.parent
    def git(*a):return subprocess.check_output(['git','-C',str(repo),*a]).decode().strip()
    assert git('rev-parse','HEAD')==args.source_sha and not git('status','--porcelain')
    token=uuid.uuid4().hex[:20];stamp=dt.datetime.now(dt.timezone.utc).strftime('%m%d%H%M%S')
    name='crown2-bwt-h21-'+token[:8]+'-'+stamp
    work=here/'_local'/name;work.mkdir(parents=True,exist_ok=False)
    control=cloud.Controller(name,token,work/'cloud.jsonl')
    (work/'identity.json').write_text(json.dumps({'name':name,'token':token,'source_sha':args.source_sha},indent=2)+'\n')
    source_archive=work/'source.tar'
    with source_archive.open('wb') as f:subprocess.run(['git','-C',str(repo),'archive',args.source_sha,'research/crown2-bwt'],stdout=f,check=True)
    source_dir=Path('/home/ubuntu/ACE_TRINITY_EVO/LAB/DEV2/blocks')
    inputs={'source_sha':args.source_sha,'source_archive_sha256':sha(source_archive),'inputs':{}}
    with tarfile.open(work/'inputs.tar','w') as tar:
        for piece,(size,digest) in INPUTS.items():
            f=source_dir/piece;assert f.is_file() and not f.is_symlink()
            assert f.stat().st_size==size and sha(f)==digest,piece
            inputs['inputs'][piece]={'bytes':size,'sha256':digest};tar.add(f,arcname=piece,recursive=False)
    (work/'input-manifest.json').write_text(json.dumps(inputs,sort_keys=True,indent=2)+'\n')
    key=work/'ssh-key'
    subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','','-C',name,'-f',str(key)],check=True)
    ssh_metadata=work/'ssh-public-metadata'
    ssh_metadata.write_text('ubuntu:'+Path(str(key)+'.pub').read_text())
    prefix=['sudo','-n','env','CLOUDSDK_CONFIG='+cloud.CONFIG,'CLOUDSDK_CORE_DISABLE_PROMPTS=1','CLOUDSDK_PAGER=',cloud.GCLOUD]
    common=['--project='+cloud.PROJECT,'--zone='+cloud.ZONE,'--quiet','--ssh-key-file='+str(key)]
    counter=0
    def sdk(kind,extra,required=True,timeout=300):
        nonlocal counter
        counter+=1;label='%03d-%s'%(counter,kind)
        argv=prefix+['compute',kind]+extra+common
        r=subprocess.run(argv,capture_output=True,timeout=timeout)
        # CLI/remote output stays in this own private attempt, never credentials
        # in the publication. Primary probe logs are inside artifacts.tar.gz.
        (work/(label+'.stdout')).write_bytes(r.stdout)
        (work/(label+'.stderr')).write_bytes(r.stderr)
        control.emit('transfer_or_job',label=label,returncode=r.returncode,
                     stdout_sha256=hashlib.sha256(r.stdout).hexdigest(),
                     stderr_sha256=hashlib.sha256(r.stderr).hexdigest())
        if required and r.returncode:raise RuntimeError(label+' failed')
        return r
    def ssh(command,required=True,timeout=300):
        return sdk('ssh',['ubuntu@'+name,'--ssh-flag=-oUserKnownHostsFile='+str(work/'known_hosts'),
                          '--ssh-flag=-oStrictHostKeyChecking=accept-new','--ssh-flag=-oConnectTimeout=10',
                          '--ssh-flag=-oConnectionAttempts=1','--command='+command],required,timeout)
    def scp(src,dst,required=True):
        return sdk('scp',[str(src),str(dst),'--scp-flag=-oUserKnownHostsFile='+str(work/'known_hosts'),
                          '--scp-flag=-oStrictHostKeyChecking=accept-new','--scp-flag=-oConnectTimeout=10',
                          '--scp-flag=-oConnectionAttempts=1'],required)
    created=False;job_status=None;fetched=False
    try:
        control.create(here/'cloud_startup.sh',args.source_sha,ssh_metadata);created=True
        ready=False
        for attempt in range(40):
            r=ssh('test -f /var/lib/crown2-startup.ready',required=False)
            if r.returncode==0:ready=True;break
            failed=ssh('test -f /var/lib/crown2-startup.failed',required=False)
            if failed.returncode==0:raise RuntimeError('cloud startup failed')
            control.emit('waiting_for_startup',poll=attempt);time.sleep(15)
        if not ready:raise RuntimeError('cloud startup admission timeout')
        for f in [source_archive,work/'inputs.tar',work/'input-manifest.json']:
            scp(f,'ubuntu@'+name+':/work/crown2/'+f.name)
        ssh('mkdir -p /work/crown2/source /work/crown2/inputs && tar -xf /work/crown2/source.tar -C /work/crown2/source && tar -xf /work/crown2/inputs.tar -C /work/crown2/inputs')
        result=ssh('python3 /work/crown2/source/research/crown2-bwt/cloud_job.py --source-sha '+args.source_sha,required=False,timeout=3600)
        job_status=result.returncode
        scp('ubuntu@'+name+':/work/crown2/artifacts.tar.gz',work/'artifacts.tar.gz')
        fetched=True
        control.emit('artifacts_retained_before_delete',path=str(work/'artifacts.tar.gz'),sha256=sha(work/'artifacts.tar.gz'),bytes=(work/'artifacts.tar.gz').stat().st_size,job_returncode=job_status)
        if job_status:raise RuntimeError('cloud method/build failed; evidence retained; stop for diagnosis')
    finally:
        if created:
            # Retain startup evidence even if compilation or method failed.
            try:
                ssh('sudo cat /var/log/crown2-startup.log',required=False)
            except Exception as error:
                control.emit('startup_log_unavailable',error_type=type(error).__name__)
            finally:
                control.delete()
    assert fetched and job_status==0
    print(json.dumps({'event':'cloud_attempt_complete','work':str(work),'artifact_sha256':sha(work/'artifacts.tar.gz'),'status':'PASS'}),flush=True)


if __name__=='__main__':main()
