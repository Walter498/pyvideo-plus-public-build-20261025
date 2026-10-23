#!/usr/bin/env python3
from pathlib import Path
import os,tarfile,plistlib,json,hashlib,subprocess,struct,shutil
P=Path(__file__).resolve().parent
ORIG=Path('/var/minis/workspace/pyvideo-0.0.3-analysis')
STAGE=P/'package';DIST=P/'dist';DIST.mkdir(exist_ok=True)
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
for name in ['PyVideoPlus.dylib','PyVideoPhotoWorker']:
 p=P/'build'/name;data=p.read_bytes();cpu,sub=struct.unpack_from('<II',data,4)
 assert cpu==0x100000c and sub&0xffffff==2,'not genuine arm64e: '+name
 assert hashlib.sha256(data).hexdigest()==cloud[name]['sha256'],'artifact differs from cloud signature: '+name
place(P/'build/PyVideoPlus.dylib','Library/MobileSubstrate/DynamicLibraries/PyVideoPlus.dylib',0o755)
place(P/'build/PyVideoPhotoWorker','Applications/PyVideoAgent.app/PyVideoPhotoWorker',0o755)
place(P/'resources/MediaCollector.js','Library/Application Support/PyVideo/MediaCollector.js')
addon={'Filter':{'Bundles':['com.apple.mobilesafari']}}
(STAGE/'Library/MobileSubstrate/DynamicLibraries/PyVideoPlus.plist').write_bytes(plistlib.dumps(addon,fmt=plistlib.FMT_BINARY))
job={'Label':'com.crctdd.pyvideo.photo-worker','ProgramArguments':['/Applications/PyVideoAgent.app/PyVideoPhotoWorker','--worker'],'UserName':'mobile','RunAtLoad':True,'KeepAlive':True,'ThrottleInterval':10,'ProcessType':'Background','JetsamProperties':{'JetsamMemoryLimit':192}}
photo=STAGE/'Library/LaunchDaemons/com.crctdd.pyvideo.photo-worker.plist';photo.write_bytes(plistlib.dumps(job,fmt=plistlib.FMT_BINARY));photo.chmod(0o644)
control=STAGE/'DEBIAN/control';raw=control.read_text();raw=raw.replace('Name: PyVideo\n','Name: PyVideo Plus\n').replace('Version: 0.0.3\n','Version: 0.0.3+pvx.1~beta1\n');start=raw.index('Description:');end=raw.index('Maintainer:',start);raw=raw[:start]+'''Description: PyVideo 增强测试版：搜索栏长按入口、播放器当前视频下载、网页图片多选原格式下载。保留原视频插件引擎；iOS 15-17 arm64e/roothide，新增菜单需真机验证。\n'''+raw[end:];control.write_text(raw)
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
  rel=original.relative_to(ORIG/'rootfs');assert original.read_bytes()==(STAGE/rel).read_bytes(),rel
  unchanged.append(str(rel))
for script in ['postinst','prerm','postrm']:subprocess.run(['sh','-n',str(STAGE/'DEBIAN'/script)],check=True)
out=DIST/'PyVideo-0.0.3-pvx1-beta1-iphoneos-arm64e.deb'
subprocess.run(['dpkg-deb','--root-owner-group','-Zxz','-b',str(STAGE),str(out)],check=True)
info={'name':out.name,'size':out.stat().st_size,'sha256':hashlib.sha256(out.read_bytes()).hexdigest(),'originalPayloadFilesUnchanged':unchanged,'build':cloud,'testedOnDevice':False,'sourceCommit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=P,text=True).strip()}
(DIST/'manifest.json').write_text(json.dumps(info,ensure_ascii=False,indent=2)+'\n');print(json.dumps(info,ensure_ascii=False,indent=2))
