from pathlib import Path
import io,tarfile,hashlib,json,struct
p=Path(__file__).resolve().parents[1];name='Safari-Arthur-Downloads-1.0-download-ui-features-iphoneos-arm64e.deb';b=(p/'dist'/name).read_bytes();pos=8;parts={}
while pos<len(b):
 h=b[pos:pos+60];n=h[:16].decode().strip().rstrip('/');z=int(h[48:58]);parts[n]=b[pos+60:pos+60+z];pos+=60+z+(z%2)
assert set(parts)=={'debian-binary','control.tar.xz','data.tar.xz'}
cloud=json.loads((p/'build/cloud-build.json').read_text());result={}
with tarfile.open(fileobj=io.BytesIO(parts['data.tar.xz'])) as t:
 for k,path in {'PyVideoPlus.dylib':'Library/MobileSubstrate/DynamicLibraries/PyVideoPlus.dylib','PyVideoPhotoWorker':'Applications/PyVideoAgent.app/PyVideoPhotoWorker','PyVideoStorage.dylib':'Applications/PyVideoAgent.app/PyVideoStorage.dylib'}.items():
  d=t.extractfile('./'+path).read();cpu,sub=struct.unpack_from('<II',d,4);assert cpu==0x100000c and sub&0xffffff==2 and hashlib.sha256(d).hexdigest()==cloud[k]['sha256'];result[k]=True
 assert len([x for x in t.getnames() if 'depiction/screenshot-' in x])==5
with tarfile.open(fileobj=io.BytesIO(parts['control.tar.xz'])) as t:
 c=t.extractfile('./control').read().decode();assert 'Version: 1.0\n' in c and 'Name: Safari亚瑟下载\n' in c and 'Architecture: iphoneos-arm64e\n' in c
result.update({'package':name,'size':len(b),'sha256':hashlib.sha256(b).hexdigest(),'arm64eCloudHashes':True,'version':'1.0','screenshots':5,'commit':__import__('subprocess').check_output(['git','rev-parse','HEAD'],cwd=p,text=True).strip()})
(p/'dist/native-download-ui-verified.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n');print(json.dumps(result,ensure_ascii=False,indent=2))
