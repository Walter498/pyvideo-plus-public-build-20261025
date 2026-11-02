#!/usr/bin/env python3
"""Real aria2 + production worker loopback E2E. Explicit isolated root only.
Run on macOS/device, never uses production job roots or LaunchDaemons.
"""
import argparse
import hashlib
import fcntl
import platform
import json
import os
from pathlib import Path
import plistlib
import signal
import socket
import subprocess
import sys
import time
import uuid


def physical(path):
    # roothide toolchain exposes the real root via /rootfs; native executable
    # is unhooked and needs the physical path without this tool-only prefix.
    value = os.path.realpath(str(path))
    return value[len('/rootfs'):] if value.startswith('/rootfs/') else value


def atomic_plist(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name('.test-write-' + path.name + '.pending')
    with open(temp, 'wb') as f:
        plistlib.dump(obj, f, fmt=plistlib.FMT_BINARY)
        f.flush(); os.fsync(f.fileno())
    os.replace(temp, path)


def get_plist(path):
    try:
        with open(path, 'rb') as f:
            obj = plistlib.load(f)
            return obj if isinstance(obj, dict) else {}
    except (OSError, ValueError, plistlib.InvalidFileException):
        return {}


def digest(path):
    h=hashlib.sha256()
    with open(path,'rb') as f:
        for data in iter(lambda:f.read(1048576),b''): h.update(data)
    return h.hexdigest()


def port():
    with socket.socket() as s:
        s.bind(('127.0.0.1',0)); return s.getsockname()[1]


def main():
    p=argparse.ArgumentParser()
    p.add_argument('--worker',required=True); p.add_argument('--engine',required=True)
    p.add_argument('--mp4',required=True); p.add_argument('--root',required=True)
    p.add_argument('--swarm',default=str(Path(__file__).with_name('torrent-swarm.py')))
    args=p.parse_args()
    root=Path(args.root)
    assert root.is_absolute() and 'pvx-bt-' in root.name, 'explicit new pvx-bt-* fixture root required'
    root.mkdir(parents=True,exist_ok=False)
    engine=Path(args.engine).absolute(); worker=Path(args.worker).absolute()
    tracker_port,seed_port=port(),port()
    announce='http://127.0.0.1:%d/announce'%tracker_port
    children=[]; log_handles=[]; checks=[]; events=[]
    started=time.time(); report=root/'device-verification.json'
    scope = 'isolated iOS device' if platform.machine().startswith(('iPhone','iPad')) else 'isolated macOS host'
    result={'success':False,'checks':checks,'error':'interrupted before completion','scope':scope}
    def unlocked(state):
        lockpath=state/'.torrent-worker.lock'
        if not lockpath.exists(): return False
        with open(lockpath,'rb') as f:
            try:
                fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)
                fcntl.flock(f,fcntl.LOCK_UN)
                return True
            except OSError: return False
    def record(name, data=None):
        checks.append({'name':name,'passed':True,'evidence':data or {}})
        print('PASS '+name,flush=True)
    def spawn(argv, name, env=None):
        log=open(root/(name+'.log'),'ab'); log_handles.append(log)
        proc=subprocess.Popen(list(map(str,argv)),stdout=log,stderr=log,stdin=subprocess.DEVNULL,env=env)
        children.append(proc); return proc
    def stop(proc, hard=False):
        if proc.poll() is None:
            proc.send_signal(signal.SIGKILL if hard else signal.SIGTERM)
            try: proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                proc.kill(); proc.wait(timeout=10)
    def wait_fn(label, fn, timeout=120):
        end=time.monotonic()+timeout
        while time.monotonic()<end:
            result=fn()
            if result: return result
            time.sleep(.15)
        raise AssertionError('timeout: '+label)
    def launch_worker(state, suffix):
        env=dict(os.environ,PVX_ARIA2_PATH=physical(engine),PVX_BT_TEST_LOCAL='1')
        return spawn([worker,'--worker','--root',physical(state)],'worker-'+suffix,env)
    def submit(state, manifest):
        job=str(uuid.uuid4()).upper()
        atomic_plist(state/'torrent-inbox'/(job+'.plist'),{
            'id':job,'kind':'video','backend':'torrent','sourceKind':'magnet',
            'magnet':manifest['magnet'],'infoHash':manifest['infoHash'],
            'sourceKey':'btih:'+manifest['infoHash'],'title':'Private swarm fixture',
            'page':'http://127.0.0.1/','created':time.time()})
        return job
    def control(state, job, action):
        cmd=str(uuid.uuid4()).upper()
        atomic_plist(state/'torrent-control'/(cmd+'.plist'),{
            'id':cmd,'target':job,'action':action,'created':time.time()})
    def task(state,job):
        obj=get_plist(state/'torrent-tasks'/(job+'.plist'))
        snap={k:obj.get(k) for k in ('id','state','phase','received','total','error')}
        if not events or snap!=events[-1]: events.append(snap)
        return obj
    def wait_state(state,job,want,timeout=120):
        def cond():
            obj=task(state,job)
            if obj.get('state')=='failed' and want!='failed':
                raise AssertionError('worker failed: '+json.dumps(obj,ensure_ascii=True))
            return obj if obj.get('state')==want else None
        return wait_fn(want,cond,timeout)
    try:
        subprocess.run([sys.executable,args.swarm,'fixture','--root',str(root/'fixture'),
                        '--mp4',args.mp4,'--announce',announce,'--pad-bytes','8388608'],check=True,timeout=30)
        fixture=root/'fixture'; manifest=json.loads((fixture/'fixture.json').read_text())
        tracker=spawn([sys.executable,args.swarm,'tracker','--port',tracker_port],'tracker')
        def tracker_ready():
            try:
                with socket.create_connection(('127.0.0.1',tracker_port),timeout=.5):return True
            except OSError:return False
        wait_fn('tracker listen',tracker_ready,10)
        seed=spawn([engine,'--no-conf=true','--check-integrity=true','--bt-hash-check-seed=true',
                    '--enable-dht=false','--enable-dht6=false','--bt-enable-lpd=false',
                    '--enable-peer-exchange=false','--seed-time=30','--seed-ratio=0.0',
                    '--max-upload-limit=512K','--summary-interval=1','--console-log-level=notice',
                    '--listen-port='+str(seed_port),'--dir='+physical(fixture/'seed'),
                    physical(fixture/'fixture.torrent')],'seeder')
        wait_fn('seed integrity',lambda:'SEED(' in (root/'seeder.log').read_text(errors='replace'),20)
        record('real seeder verified all pieces before serving',{'pieces':manifest['pieceCount'],'bytes':manifest['bytes']})
        state=root/'state-resume'; state.mkdir()
        proc=launch_worker(state,'resume'); job=submit(state,manifest)
        def partial():
            obj=task(state,job)
            if obj.get('state')=='failed':raise AssertionError('download failed: '+str(obj.get('error')))
            return obj if obj.get('phase')=='pieces' and 0<int(obj.get('received',0))<manifest['bytes'] else None
        progress=wait_fn('partial verified progress',partial,90)
        record('metadata resolved and pieces downloading', {k:progress.get(k) for k in ('phase','received','total')})
        control(state,job,'pause'); paused=wait_state(state,job,'paused',20)
        assert not (state/'media'/(job+'.mp4')).exists()
        record('pause reaps writer and never publishes partial',{'received':paused.get('received')})
        stop(proc,True)
        proc=launch_worker(state,'paused-restart')
        time.sleep(3)
        assert task(state,job).get('state')=='paused'
        record('paused state survives process restart')
        control(state,job,'resume'); done=wait_state(state,job,'ready',180)
        output=state/'media'/(job+'.mp4')
        assert output.stat().st_size==manifest['bytes']
        assert digest(output)==manifest['sha256']
        assert done.get('backend')=='torrent' and done.get('fileComplete') is True
        record('resume completes exact full MP4 and publishes ready',{'bytes':output.stat().st_size,'sha256':digest(output)})
        control(state,job,'delete'); wait_state(state,job,'deleted',20)
        assert not output.exists() and not (state/'torrent-cache'/job).exists()
        time.sleep(2); assert task(state,job).get('state')=='deleted'
        record('completed deletion removes own cache/output without resurrection')
        stop(proc)
        state2=root/'state-active-delete';state2.mkdir()
        proc=launch_worker(state2,'active-delete');job2=submit(state2,manifest)
        wait_fn('second task receives data',lambda:task(state2,job2).get('phase')=='pieces' and int(task(state2,job2).get('received',0))>0,90)
        control(state2,job2,'delete');wait_state(state2,job2,'deleted',20)
        assert not (state2/'media'/(job2+'.mp4')).exists()
        assert not (state2/'torrent-cache'/job2).exists()
        record('deletion interrupts active engine before removing files')
        stop(proc)
        state3=root/'state-crash-recovery';state3.mkdir()
        proc=launch_worker(state3,'active-crash');job3=submit(state3,manifest)
        wait_fn('third task partial pieces',lambda:task(state3,job3).get('phase')=='pieces' and int(task(state3,job3).get('received',0))>0,90)
        stop(proc,True)
        wait_fn('orphaned engine exits and releases writer lock',lambda:unlocked(state3),20)
        assert not (state3/'media'/(job3+'.mp4')).exists()
        proc=launch_worker(state3,'active-crash-restart')
        wait_state(state3,job3,'ready',180)
        recovered=state3/'media'/(job3+'.mp4')
        assert digest(recovered)==manifest['sha256']
        record('active crash stops orphan writer and recovers complete bytes',{'sha256':digest(recovered)})
        stop(proc)
        multi_root=root/'multifile'
        subprocess.run([sys.executable,args.swarm,'fixture','--root',str(multi_root),
                        '--mp4',args.mp4,'--announce',announce,'--pad-bytes','2097152','--multi'],check=True,timeout=30)
        multi=json.loads((multi_root/'fixture.json').read_text())
        multi_seed=spawn([engine,'--no-conf=true','--check-integrity=true','--bt-hash-check-seed=true',
                          '--enable-dht=false','--enable-dht6=false','--bt-enable-lpd=false','--seed-time=30',
                          '--seed-ratio=0.0','--summary-interval=1','--console-log-level=notice',
                          '--listen-port='+str(port()),'--dir='+physical(multi_root/'seed'),
                          physical(multi_root/'fixture.torrent')],'seeder-multifile')
        wait_fn('multi seeder complete integrity',lambda:'SEED(' in (root/'seeder-multifile.log').read_text(errors='replace'),20)
        state4=root/'state-multifile';state4.mkdir()
        proc=launch_worker(state4,'multifile');job4=submit(state4,multi)
        done=wait_state(state4,job4,'ready',120)
        selected=state4/'media'/(job4+'.mp4')
        assert done.get('total')==multi['bytes'] and selected.stat().st_size==multi['bytes']
        assert digest(selected)==multi['sha256']
        record('multifile selects largest MP4 rather than trailer',{'sha256':digest(selected),'bytes':multi['bytes']})
        stop(proc)
        for statex in (state,state2,state3,state4):
            assert not list((statex/'inbox').glob('*')) and not list((statex/'image-inbox').glob('*'))
        record('HTTP and image queues untouched')
        result={'success':True,'checks':checks,'engineSHA256':digest(engine),'workerSHA256':digest(worker),
                'fixture':manifest,'platform':platform.platform(),'scope':scope+' loopback swarm; no production install or production tasks'}
    except Exception as exc:
        result={'success':False,'checks':checks,'error':str(exc),'scope':scope+' private swarm'}
        raise
    finally:
        for proc in reversed(children):stop(proc)
        for handle in log_handles:handle.close()
        result['elapsedSeconds']=round(time.time()-started,2)
        result['events']=events
        report.write_text(json.dumps(result,indent=2,ensure_ascii=False)+'\n')
        print('report: '+str(report),flush=True)


if __name__=='__main__':main()
