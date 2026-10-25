from pathlib import Path
import subprocess,tarfile,io,json,hashlib,struct
p=Path(__file__).resolve().parents[1]
deb=p/'dist/Safari-Arthur-Downloads-1.0-system-player-fix-iphoneos-arm64e.deb'
b=deb.read_bytes();assert b.startswith(b'!<arch>\n')
pos=8;parts={}
while pos<len(b):
 h=b[pos:pos+60];size=int(h[48:58]);parts[h[:16].decode().strip().rstrip('/')]=b[pos+60:pos+60+size];pos+=60+size+(size%2)
with tarfile.open(fileobj=io.BytesIO(parts['control.tar.xz'])) as t:
 control=t.extractfile('./control').read().decode()
 assert 'Version: 1.0\n' in control and 'Name: Safari亚瑟下载\n' in control
 for n in ['./postinst','./prerm','./postrm']:assert t.getmember(n).mode&0o111
cloud=json.loads((p/'build/cloud-build.json').read_text())
files={'PyVideoPlus.dylib':'Library/MobileSubstrate/DynamicLibraries/PyVideoPlus.dylib','PyVideoPhotoWorker':'Applications/PyVideoAgent.app/PyVideoPhotoWorker','PyVideoStorage.dylib':'Applications/PyVideoAgent.app/PyVideoStorage.dylib'}
with tarfile.open(fileobj=io.BytesIO(parts['data.tar.xz'])) as t:
 for name,path in files.items():
  m=t.getmember('./'+path);data=t.extractfile(m).read();cpu,sub=struct.unpack_from('<II',data,4)
  assert cpu==0x100000c and sub&0xffffff==2
  assert hashlib.sha256(data).hexdigest()==cloud[name]['sha256']
  assert m.mode&0o111
  if name=='PyVideoPlus.dylib':
   assert b'AVPlayerViewController' in data and b'PVXRequestTaskSnapshot' in data
 dep=[n for n in t.getnames() if 'depiction/screenshot-' in n];assert len(dep)==5
r={'file':deb.name,'size':len(b),'sha256':hashlib.sha256(b).hexdigest(),'control':control,'arm64eArtifactsMatchCloud':True,'nativePlayerAndAsyncSnapshotSymbols':True,'depictionScreenshots':len(dep),'sourceCommit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=p,text=True).strip()}
(p/'dist/native-watchdog-verified.json').write_text(json.dumps(r,ensure_ascii=False,indent=2)+'\n');print(json.dumps(r,ensure_ascii=False,indent=2))
