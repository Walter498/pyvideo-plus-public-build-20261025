"""Validate an actual final Debian archive, not only staging files."""
from pathlib import Path
import sys,io,tarfile,json,hashlib,struct,re
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
    manifest=json.loads(Path(manifest_path).read_text());data=Path(path).read_bytes()
    assert manifest['sha256']==hashlib.sha256(data).hexdigest();assert manifest['size']==len(data)
    ar=members(path);assert ar['debian-binary']==b'2.0\n'
    files={};modes={}
    with tarfile.open(fileobj=io.BytesIO(ar['data.tar.xz'])) as tf:
        for entry in tf.getmembers():
            name=entry.name.removeprefix('./');assert '..' not in Path(name).parts
            if entry.isfile():files[name]=tf.extractfile(entry).read();modes[name]=entry.mode
    assert not any('/Frameworks/' in p and ('ffmpeg' in p.lower() or 'libav' in p.lower() or 'libsw' in p.lower()) for p in files),'external FFmpeg runtime still included'
    assert not any('/depiction/screenshot-' in p for p in files),'large screenshots still included'
    for name,installed in {'PyVideoPlus.dylib':'Library/MobileSubstrate/DynamicLibraries/PyVideoPlus.dylib',
        'PyVideoPhotoWorker':'Applications/PyVideoAgent.app/PyVideoPhotoWorker',
        'PyVideoBTWorker':'Applications/PyVideoAgent.app/PyVideoBTWorker',
        'PyVideoAria2c':'Applications/PyVideoAgent.app/PyVideoAria2c',
        'PyVideoStorage.dylib':'Applications/PyVideoAgent.app/PyVideoStorage.dylib'}.items():
        b=files[installed];assert hashlib.sha256(b).hexdigest()==manifest['build'][name]['sha256']
        assert struct.unpack_from('<III',b)==(0xfeedfacf,0x100000c,0x80000002)
        assert modes[installed]==0o755
    original=Path(base_path).read_bytes();assert hashlib.sha256(original).hexdigest()==BASE_SHA
    agent='Applications/PyVideoAgent.app/PyVideoAgent'
    contract=verify_signed_contract(files[agent],original);assert modes[agent]==0o755
    with tarfile.open(fileobj=io.BytesIO(ar['control.tar.xz'])) as tf:
        control=tf.extractfile('./control').read().decode()
        version=re.search(r'#define PVX_VERSION @"([0-9]+\.[0-9]+\.[0-9]+)"',
            (Path(__file__).resolve().parents[1]/'src/PVXCommon.h').read_text())[1]
        assert 'Package: com.crctdd.pyvideo\n' in control and f'Version: {version}\n' in control
        assert manifest['name']==f'Safari-Arthur-Downloads-{version}-storage-recovery-refactor-iphoneos-arm64e.deb'
    print(json.dumps({'archiveVerified':True,'bytes':len(data),'files':len(files),**contract},indent=2))

if __name__=='__main__':
    if len(sys.argv)!=4:raise SystemExit('usage: verify-install-package.py PACKAGE MANIFEST ORIGINAL_AGENT')
    verify(*sys.argv[1:])
