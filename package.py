#!/usr/bin/env python3
from pathlib import Path
import os,tarfile,plistlib,json,hashlib,subprocess,struct,io,re
VERSION='1.4.0'
P=Path(__file__).resolve().parent
ORIG=Path(os.environ.get('PYVIDEO_BASE_PAYLOAD','/var/minis/workspace/pyvideo-0.0.3-analysis'))
STAGE=P/'package';DIST=P/'dist';DIST.mkdir(exist_ok=True)
if not (ORIG/'archive/data.tar.xz').is_file() or not (ORIG/'archive/control.tar.xz').is_file():raise RuntimeError('missing base payload archives; set PYVIDEO_BASE_PAYLOAD')
if STAGE.exists():
 subprocess.run(['rm','-rf',str(STAGE)],check=True)
STAGE.mkdir()
for archive,root in [('data',STAGE),('control',STAGE/'DEBIAN')]:
 root.mkdir(exist_ok=True)
 with tarfile.open(ORIG/'archive'/(archive+'.tar.xz')) as t:
  for m in t.getmembers():
   name=m.name.removeprefix('./')
   if not name:continue
   assert '..' not in Path(name).parts and not Path(name).is_absolute()
   target=root/name
   if m.isdir():target.mkdir(parents=True,exist_ok=True)
   elif m.isfile():target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(t.extractfile(m).read())
   else:raise RuntimeError('unexpected entry '+name)
   target.chmod(m.mode)
def place(source,destination,mode=0o644):
 target=STAGE/destination;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(Path(source).read_bytes());target.chmod(mode)
cloud=json.loads((P/'build/cloud-build.json').read_text())
for name in ['PyVideoPlus.dylib','PyVideoPhotoWorker','PyVideoStorage.dylib']:
 p=P/'build'/name;data=p.read_bytes();cpu,sub=struct.unpack_from('<II',data,4)
 assert cpu==0x100000c and sub&0xffffff==2,'not genuine arm64e: '+name
 assert hashlib.sha256(data).hexdigest()==cloud[name]['sha256'],'artifact differs from cloud signature: '+name
place(P/'build/PyVideoPlus.dylib','Library/MobileSubstrate/DynamicLibraries/PyVideoPlus.dylib',0o755)
place(P/'build/PyVideoPhotoWorker','Applications/PyVideoAgent.app/PyVideoPhotoWorker',0o755)
place(P/'resources/MediaCollector.js','Library/Application Support/PyVideo/MediaCollector.js')
for old in ['screenshot-1.jpeg','screenshot-2.png','screenshot-3.png','screenshot-4.png','screenshot-5.png']:
 (STAGE/'Library/Application Support/PyVideo/depiction'/old).unlink(missing_ok=True)
for depiction in (P/'depiction').rglob('*'):
 if depiction.is_file():place(depiction,Path('Library/Application Support/PyVideo/depiction')/depiction.relative_to(P/'depiction'))

place(P/'build/PyVideoStorage.dylib','Applications/PyVideoAgent.app/PyVideoStorage.dylib',0o755)
# FFmpegKit/libav runtime used only by the Storage recovery worker. Keep the
# original framework install names and rpath layout so FFmpegKit can resolve
# libavcodec/libavformat and friends inside PyVideoAgent.
FFMPEG_ROOT=Path(os.environ.get('PYVIDEO_FFMPEG_ROOT','/var/minis/workspace/yase-25.3/Payload/YSBrowser.app/Frameworks'))
if not FFMPEG_ROOT.is_dir():raise RuntimeError('missing FFmpeg framework root; set PYVIDEO_FFMPEG_ROOT')
for framework in ['ffmpegkit','libavdevice','libavcodec','libavfilter','libavformat','libavutil','libswscale','libswresample']:
 source=FFMPEG_ROOT/(framework+'.framework')/framework
 if not source.is_file():raise RuntimeError('missing FFmpeg runtime '+str(source))
 target='Applications/PyVideoAgent.app/Frameworks/'+framework+'.framework/'+framework
 place(source,target,0o755)
 info=FFMPEG_ROOT/(framework+'.framework')/'Info.plist'
 if info.is_file():place(info,'Applications/PyVideoAgent.app/Frameworks/'+framework+'.framework/Info.plist',0o644)
 subprocess.run(['ldid','-S',str(STAGE/target)],check=True)
# Add storage load command and Frameworks RPATH in known zero header padding.
agent=STAGE/'Applications/PyVideoAgent.app/PyVideoAgent'
originalAgent=agent.read_bytes();data=bytearray(originalAgent);n,sz=struct.unpack_from('<II',data,16)
load_name=b'@executable_path/PyVideoStorage.dylib\0';load_size=(24+len(load_name)+7)&~7
rpath_name=b'@executable_path/Frameworks\0';rpath_size=(12+len(rpath_name)+7)&~7
base=32+sz;assert data[base:base+load_size+rpath_size]==bytes(load_size+rpath_size)
load=struct.pack('<IIIIII',0xc,load_size,24,0,0,0)+load_name;load+=bytes(load_size-len(load))
rpath=struct.pack('<III',0x8000001c,rpath_size,12)+rpath_name;rpath+=bytes(rpath_size-len(rpath))
data[base:base+load_size]=load;data[base+load_size:base+load_size+rpath_size]=rpath
struct.pack_into('<II',data,16,n+2,sz+load_size+rpath_size);assert data[0x4000:]==originalAgent[0x4000:]
# The user explicitly forbids background Photos. Replace only the verified
# exportReady entry with plain RET before PAC prologue; downloads/validation intact.
assert data[0x197fac:0x197fb0]==bytes.fromhex('7f2303d5')
data[0x197fac:0x197fb0]=bytes.fromhex('c0035fd6')
agent.write_bytes(data)
subprocess.run(['ldid','-Icom.crctdd.pyvideo','-S'+str(P/'worker/entitlements.plist'),str(agent)],check=True)
# libSandy keys AllowedProcesses by CodeDirectory identifier, not Info.plist.
def signing_identifiers(binary):
 b=Path(binary).read_bytes();n=struct.unpack_from('<I',b,16)[0];pos=32;off=None
 for _ in range(n):
  cmd,size=struct.unpack_from('<II',b,pos)
  if cmd==0x1d:off=struct.unpack_from('<I',b,pos+8)[0]
  pos+=size
 assert off is not None,'missing LC_CODE_SIGNATURE'
 magic,length,count=struct.unpack_from('>III',b,off);assert magic==0xfade0cc0
 out=[]
 for i in range(count):
  slot,relative=struct.unpack_from('>II',b,off+12+i*8);p=off+relative
  if struct.unpack_from('>I',b,p)[0]!=0xfade0c02:continue
  ident=struct.unpack_from('>I',b,p+20)[0];end=b.index(b'\0',p+ident);out.append(b[p+ident:end].decode())
 return out
assert signing_identifiers(agent) and all(x=='com.crctdd.pyvideo' for x in signing_identifiers(agent)),signing_identifiers(agent)
agentpatch={'path':'Applications/PyVideoAgent.app/PyVideoAgent','change':'Add storage LC_LOAD_DYLIB and @executable_path/Frameworks LC_RPATH; verified exportReady entry VA0x100197fac/file0x197fac PACIBSP -> RET to hard-disable automatic Photos; all other original code bytes preserved; signing identifier com.crctdd.pyvideo retained','sha256':hashlib.sha256(agent.read_bytes()).hexdigest()}

addon={'Filter':{'Bundles':['com.apple.mobilesafari']}}
(STAGE/'Library/MobileSubstrate/DynamicLibraries/PyVideoPlus.plist').write_bytes(plistlib.dumps(addon,fmt=plistlib.FMT_BINARY))
job={'Label':'com.crctdd.pyvideo.photo-worker','ProgramArguments':['/Applications/PyVideoAgent.app/PyVideoPhotoWorker','--worker'],'UserName':'mobile','RunAtLoad':True,'KeepAlive':True,'ThrottleInterval':10,'ProcessType':'Background','JetsamProperties':{'JetsamMemoryLimit':192}}
photo=STAGE/'Library/LaunchDaemons/com.crctdd.pyvideo.photo-worker.plist';photo.write_bytes(plistlib.dumps(job,fmt=plistlib.FMT_BINARY));photo.chmod(0o644)
control=STAGE/'DEBIAN/control';raw=control.read_text();raw=raw.replace('Name: PyVideo\n','Name: Safari亚瑟下载\n').replace('Version: 0.0.3\n',f'Version: {VERSION}\n');start=raw.index('Description:');end=raw.index('Maintainer:',start);raw=raw[:start]+'''Description: 让Safari获得某些类似亚瑟浏览器的功能，能够在画中画中直接下载影片，或者在网站中采集图片及影片以下载，长按搜索栏或点击画中画中的菜单开始使用\n'''+raw[end:];raw=re.sub(r'^Author: .*$', 'Author: 水甲嫩鸡', raw, flags=re.M);raw=re.sub(r'^Maintainer: .*$', 'Maintainer: 水甲嫩鸡', raw, flags=re.M);raw+='Depiction: file:///Library/Application%20Support/PyVideo/depiction/index.html\n';control.write_text(raw)
post=STAGE/'DEBIAN/postinst';text=post.read_text();assert text.endswith('exit 0\n');text=text[:-7]+'''pv_stage=photo-storage-permissions
for pv_child in image-inbox image-tasks image-media; do
  if [ -d "$pv_data/$pv_child" ]; then
    chown mobile:mobile "$pv_data/$pv_child"
    chmod 700 "$pv_data/$pv_child"
  fi
done
pv_stage=photo-worker-registration
pv_photo_job="$pv_prefix/Library/LaunchDaemons/com.crctdd.pyvideo.photo-worker.plist"
chown root:wheel "$pv_photo_job"
chmod 644 "$pv_photo_job"
launchctl bootout system/com.crctdd.pyvideo.photo-worker >/dev/null 2>&1 || true
launchctl bootstrap system "$pv_photo_job" || launchctl load "$pv_photo_job"
launchctl print system/com.crctdd.pyvideo.photo-worker >/dev/null
exit 0
''';post.write_text(text);post.chmod(0o755)
pre=STAGE/'DEBIAN/prerm';text=pre.read_text();text=text.replace('  launchctl bootout system/com.crctdd.pyvideo.worker','  launchctl bootout system/com.crctdd.pyvideo.photo-worker >/dev/null 2>&1 || true\n  launchctl bootout system/com.crctdd.pyvideo.worker');pre.write_text(text);pre.chmod(0o755)
# Original core binaries, Collector.js and routing filters are byte-identical.
unchanged=[]
for original in (ORIG/'rootfs').rglob('*'):
 if original.is_file():
  rel=original.relative_to(ORIG/'rootfs')
  if str(rel)=='Applications/PyVideoAgent.app/PyVideoAgent':continue
  assert original.read_bytes()==(STAGE/rel).read_bytes(),rel
  unchanged.append(str(rel))
for script in ['postinst','prerm','postrm']:subprocess.run(['sh','-n',str(STAGE/'DEBIAN'/script)],check=True)
out=DIST/f'Safari-Arthur-Downloads-{VERSION}-storage-recovery-refactor-iphoneos-arm64e.deb'
# The iOS shared filesystem ignores chmod; archive modes must be explicit.
modes={}
for archive,prefix in [('data',''),('control','DEBIAN/')]:
 with tarfile.open(ORIG/'archive'/(archive+'.tar.xz')) as tf:
  for m in tf.getmembers():
   rel=m.name.removeprefix('./').rstrip('/')
   if rel:modes[prefix+rel]=m.mode
for rel in ['Library/MobileSubstrate/DynamicLibraries/PyVideoPlus.dylib','Applications/PyVideoAgent.app/PyVideoPhotoWorker','Applications/PyVideoAgent.app/PyVideoStorage.dylib','DEBIAN/postinst','DEBIAN/prerm','DEBIAN/postrm']:modes[rel]=0o755
for framework in ['ffmpegkit','libavdevice','libavcodec','libavfilter','libavformat','libavutil','libswscale','libswresample']:modes['Applications/PyVideoAgent.app/Frameworks/'+framework+'.framework/'+framework]=0o755
allfiles=[Path(x) for x in subprocess.check_output(['rg','--files','-uuu',str(STAGE)],text=True).splitlines()]
size=sum(p.stat().st_size for p in allfiles if 'DEBIAN' not in p.relative_to(STAGE).parts)
control.write_text(re.sub(r'Installed-Size: .*',f'Installed-Size: {(size+1023)//1024}',control.read_text()))
def archive_bytes(iscontrol):
 files=[p for p in allfiles if (p.is_relative_to(STAGE/'DEBIAN'))==iscontrol]
 root=STAGE/'DEBIAN' if iscontrol else STAGE
 dirs=set()
 for p in files:
  rel=p.relative_to(root)
  dirs.update(str(x) for x in rel.parents if str(x)!='.')
 for rel in modes:
  if rel.startswith('DEBIAN/')!=iscontrol:continue
  relative=rel[7:] if iscontrol else rel
  if (root/relative).is_dir():dirs.add(relative)
 buf=io.BytesIO()
 with tarfile.open(fileobj=buf,mode='w:xz',preset=3,format=tarfile.GNU_FORMAT) as tf:
  for d in ['.']+sorted(dirs):
   t=tarfile.TarInfo('./' if d=='.' else './'+d+'/');t.type=tarfile.DIRTYPE;t.mode=0o755;t.uid=t.gid=0;t.uname=t.gname='root';t.mtime=0;tf.addfile(t)
  for p in sorted(files):
   rel=p.relative_to(root);t=tarfile.TarInfo('./'+str(rel));t.mode=modes.get(str(p.relative_to(STAGE)),0o644);t.uid=t.gid=0;t.uname=t.gname='root';t.mtime=0;data=p.read_bytes();t.size=len(data);tf.addfile(t,io.BytesIO(data))
 return buf.getvalue()
with out.open('wb') as ar:
 ar.write(b'!<arch>\n')
 for name,data in [('debian-binary',b'2.0\n'),('control.tar.xz',archive_bytes(True)),('data.tar.xz',archive_bytes(False))]:
  header=f'{name+"/":<16}{0:<12}{0:<6}{0:<6}{"100644":<8}{len(data):<10}`\n';assert len(header)==60;ar.write(header.encode());ar.write(data)
  if len(data)%2:ar.write(b'\n')
info={'name':out.name,'size':out.stat().st_size,'sha256':hashlib.sha256(out.read_bytes()).hexdigest(),'originalPayloadFilesUnchanged':unchanged,'patchedOriginal':agentpatch,'build':cloud,'testedOnDevice':False,'sourceCommit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=P,text=True).strip()}
(DIST/'manifest.json').write_text(json.dumps(info,ensure_ascii=False,indent=2)+'\n');print(json.dumps(info,ensure_ascii=False,indent=2))
