#!/usr/bin/env python3
from pathlib import Path
import subprocess,struct,json,hashlib
P=Path(__file__).resolve().parent;B=P/'build';B.mkdir(exist_ok=True)
def run(args):
 r=subprocess.run(list(map(str,args)),text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 print(r.stdout,end='')
 if r.returncode:raise RuntimeError('command failed: '+' '.join(map(str,args)))
 return r.stdout.strip()
sdk=run(['xcrun','--sdk','iphoneos','--show-sdk-path'])
flags=['xcrun','--sdk','iphoneos','clang','-arch','arm64e','-miphoneos-version-min=15.0','-isysroot',sdk,'-F'+sdk+'/System/Library/SubFrameworks','-fobjc-arc','-fblocks','-Os','-Wall','-Wextra','-Werror','-Wno-unused-parameter','-Wno-deprecated-declarations','-I',P/'src']
frameworks=['Foundation','UIKit','WebKit','AVFoundation','AVFAudio','AVKit','Photos','ImageIO','CoreGraphics','CoreMedia','QuartzCore','UniformTypeIdentifiers']
fw=[]
for f in frameworks:fw+=['-framework',f]
run(flags+['-dynamiclib','-Wl,-install_name,@loader_path/PyVideoPlus.dylib','-o',B/'PyVideoPlus.dylib']+[P/'src'/(n+'.m') for n in ['Main','Images','Menus','Player','DownloadsUI','TaskSupport','PiPInline','Collection','MediaPreview','MediaQuality']]+fw)
run(flags+['-o',B/'PyVideoPhotoWorker',P/'worker/main.m']+fw+['-framework','Photos','-framework','UniformTypeIdentifiers'])
run(flags+['-dynamiclib','-Wl,-install_name,@executable_path/PyVideoStorage.dylib','-o',B/'PyVideoStorage.dylib',P/'storage/Storage.m','-framework','Foundation'])
info={}
for name in ['PyVideoPlus.dylib','PyVideoPhotoWorker','PyVideoStorage.dylib']:
 p=B/name;data=p.read_bytes();magic,cpu,sub,typ=struct.unpack_from('<IIII',data)
 assert magic==0xfeedfacf and cpu==0x100000c and sub&0xffffff==2,(name,hex(sub))
 run(['codesign','--force','--sign','-','--entitlements',P/'worker/entitlements.plist',p] if name=='PyVideoPhotoWorker' else ['codesign','--force','--sign','-',p])
 run(['codesign','--verify','--strict',p]);info[name]={'size':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'cpuSubtype':hex(sub),'fileType':typ}
(B/'cloud-build.json').write_text(json.dumps(info,indent=2)+'\n');print(json.dumps(info,indent=2))
