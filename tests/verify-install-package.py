"""Validate an actual final Debian archive, not only staging files."""
from pathlib import Path
import sys,io,tarfile,json,hashlib,struct,re,plistlib,runpy
verify_signature=runpy.run_path(str(Path(__file__).with_name('package-contract-signatures.py')))['verify_signature']
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from tools.agent_exports import BASE_SHA,verify_signed_contract

def members(path):
    data=Path(path).read_bytes();assert data[:8]==b'!<arch>\n';pos=8;result={}
    while pos<len(data):
        header=data[pos:pos+60];assert len(header)==60 and header[58:]==b'`\n';pos+=60
        size=int(header[48:58]);name=header[:16].decode().strip().rstrip('/')
        assert name not in result;result[name]=data[pos:pos+size];assert len(result[name])==size
        pos+=size+(size&1)
    assert pos==len(data)
    return result

def verify(path,manifest_path,base_path):
    package_path=path
    manifest=json.loads(Path(manifest_path).read_text());data=Path(path).read_bytes()
    assert manifest['sha256']==hashlib.sha256(data).hexdigest();assert manifest['size']==len(data)
    ar=members(path);assert ar['debian-binary']==b'2.0\n'
    files={};modes={}
    with tarfile.open(fileobj=io.BytesIO(ar['data.tar.xz'])) as tf:
        for entry in tf.getmembers():
            name=entry.name.removeprefix('./');assert '..' not in Path(name).parts and not Path(name).is_absolute()
            assert entry.isdir() or entry.isfile(),'unsafe archive member'
            assert entry.uid==0 and entry.gid==0
            if entry.isfile():
                assert name not in files,'duplicate archive member'
                files[name]=tf.extractfile(entry).read();modes[name]=entry.mode
    assert not any('/Frameworks/' in p and ('ffmpeg' in p.lower() or 'libav' in p.lower() or 'libsw' in p.lower()) for p in files),'external FFmpeg runtime still included'
    assert not any('/depiction/screenshot-' in p for p in files),'large screenshots still included'
    for name,installed in {'PyVideoPlus.dylib':'Library/MobileSubstrate/DynamicLibraries/PyVideoPlus.dylib',
        'PyVideoPhotoWorker':'Applications/PyVideoAgent.app/PyVideoPhotoWorker',
        'PyVideoBTWorker':'Applications/PyVideoAgent.app/PyVideoBTWorker',
        'PyVideoAria2c':'Applications/PyVideoAgent.app/PyVideoAria2c',
        'PyVideoStorage.dylib':'Applications/PyVideoAgent.app/PyVideoStorage.dylib'}.items():
        b=files[installed];assert hashlib.sha256(b).hexdigest()==manifest['build'][name]['sha256']
        magic,cpu,sub=struct.unpack_from('<III',b)
        assert magic==0xfeedfacf and cpu==0x100000c and sub&0xffffff==2
        assert struct.unpack_from('<I',b,12)[0]==(6 if name.endswith('.dylib') else 2)
        assert modes[installed]==0o755
        ent=verify_signature(b)
        assert manifest['build'][name]['signatureVerified'] is True
        if name in ('PyVideoBTWorker','PyVideoAria2c'):
            expected=plistlib.loads((Path(__file__).resolve().parents[1]/'worker/torrent-entitlements.plist').read_bytes())
            assert ent==expected and 'Photos' not in str(ent)
    for label,executable in [('photo-worker','PyVideoPhotoWorker'),('torrent-worker','PyVideoBTWorker')]:
        path='Library/LaunchDaemons/com.crctdd.pyvideo.'+label+'.plist'
        job=plistlib.loads(files[path]);assert modes[path]==0o644
        assert job['Label']=='com.crctdd.pyvideo.'+label
        assert job['ProgramArguments']==['/Applications/PyVideoAgent.app/'+executable,'--worker']
        assert job['UserName']=='mobile' and job['RunAtLoad'] and job['KeepAlive']
    prefix='Library/Application Support/PyVideo/third-party/aria2/'
    provenance=json.loads(files[prefix+'provenance.json'])
    assert provenance==manifest['build']['_aria2']
    assert hashlib.sha256(files[prefix+'provenance.json']).hexdigest()==manifest['build']['_aria2ProvenanceSHA256']
    assert manifest['build']['PyVideoAria2c']['provenanceSHA256']==manifest['build']['_aria2ProvenanceSHA256']
    assert provenance['gitCommit']=='9e7273583f83e881e3ec067b523ba88724088d2f'
    assert provenance['version']=='1.37.0' and provenance['tlsBackend']=='AppleTLS' and provenance['sourcePatches']==[]
    assert {'COPYRIGHT','COPYING','LICENSE.OpenSSL','NOTICE','build-aria2-ios.sh','aria2-source.tar.gz'}<=provenance['files'].keys()
    for filename,digest in provenance['files'].items():
        assert Path(filename).name==filename
        assert hashlib.sha256(files[prefix+filename]).hexdigest()==digest
        assert modes[prefix+filename]==0o644
    original=Path(base_path).read_bytes();assert hashlib.sha256(original).hexdigest()==BASE_SHA
    agent='Applications/PyVideoAgent.app/PyVideoAgent'
    contract=verify_signed_contract(files[agent],original);assert modes[agent]==0o755
    verify_signature(files[agent])
    assert set(manifest['protectedPayloadSHA256'])==set(manifest['originalPayloadFilesUnchanged'])
    for protected,digest in manifest['protectedPayloadSHA256'].items():
        assert not Path(protected).is_absolute() and '..' not in Path(protected).parts
        assert hashlib.sha256(files[protected]).hexdigest()==digest,'protected payload changed: '+protected
    with tarfile.open(fileobj=io.BytesIO(ar['control.tar.xz'])) as tf:
        seen=set()
        for entry in tf.getmembers():
            name=entry.name.removeprefix('./')
            assert not Path(name).is_absolute() and '..' not in Path(name).parts
            assert entry.isfile() or entry.isdir()
            assert name not in seen;seen.add(name)
            if name in ('postinst','prerm','postrm'):assert entry.mode==0o755
        postinst=tf.extractfile('./postinst').read().decode()
        for worker in ('photo','torrent'):
            assert 'com.crctdd.pyvideo.'+worker+'-worker.plist' in postinst
        assert '.jbroot' in postinst and 'PlistBuddy' in postinst
        for directory in ('torrent-inbox','torrent-tasks','torrent-cache','torrent-control'):
            for operation in ('mkdir -p','chown mobile:mobile','chmod 700'):
                assert any(line.startswith(operation) and '"$pv_data/'+directory+'"' in line for line in postinst.splitlines())
        control=tf.extractfile('./control').read().decode()
        version=re.search(r'#define PVX_VERSION @"([^"]+)"',
            (Path(__file__).resolve().parents[1]/'src/PVXCommon.h').read_text())[1]
        assert manifest['version']==version
        assert manifest['name']==Path(package_path).name
        assert 'Package: com.crctdd.pyvideo\n' in control and f'Version: {version}\n' in control
        assert manifest['name']==f'Safari-Arthur-Downloads-{version}-storage-recovery-refactor-iphoneos-arm64e.deb'
    print(json.dumps({'archiveVerified':True,'bytes':len(data),'files':len(files),**contract},indent=2))

if __name__=='__main__':
    if len(sys.argv)!=4:raise SystemExit('usage: verify-install-package.py PACKAGE MANIFEST ORIGINAL_AGENT')
    verify(*sys.argv[1:])
