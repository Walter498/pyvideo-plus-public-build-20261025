#!/usr/bin/env python3
from pathlib import Path
import subprocess,os,json,plistlib,tarfile,hashlib,struct,zipfile
P=Path(__file__).resolve().parent
SDK=Path(os.environ.get('PVX_SDK','/root/theos/sdks/iPhoneOS16.5.sdk'))
B=P/'build';B.mkdir(exist_ok=True)
def run(args):
 r=subprocess.run([str(x) for x in args],text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 with (B/'build.log').open('a') as f:f.write('$ '+' '.join(map(str,args))+'\n'+r.stdout+'\n')
 if r.returncode:raise RuntimeError(r.stdout[-6000:])
 return r.stdout
(B/'build.log').write_text('')
common=['clang','-target','arm64e-apple-ios15.0','-isysroot',SDK,'-F'+str(SDK/'System/Library/SubFrameworks'),'-fobjc-arc','-fblocks','-Os','-Wall','-Wextra','-Wno-unused-parameter','-Wno-deprecated-declarations','-I',P/'src']
objects=[]
for name in ['Main','Images','Menus','Player','DownloadsUI','TaskSupport','PiPInline','Collection','MediaPreview','MediaQuality','MediaMetadata','PVXMediaResource']:
 out=B/(name+'.o');run(common+['-c',P/'src'/(name+'.m'),'-o',out]);objects.append(out)
frameworks=['Foundation','UIKit','WebKit','AVFoundation','AVKit','AVFAudio','Photos','ImageIO','CoreGraphics','CoreMedia','QuartzCore','UniformTypeIdentifiers']
link=['ld64.lld','-arch','arm64e','-platform_version','ios','15.0','16.5','-syslibroot',SDK,'-L'+str(SDK/'usr/lib'),'-F'+str(SDK/'System/Library/Frameworks'),'-lSystem','-lobjc']
for f in frameworks:link+=['-framework',f]
run(link+['-dylib','-install_name','@loader_path/PyVideoPlus.dylib','-o',B/'PyVideoPlus.dylib']+objects)
run(common+['-c',P/'worker/main.m','-o',B/'PhotoWorker.o'])
workerlink=link+['-framework','Photos','-framework','UniformTypeIdentifiers']
run(workerlink+['-o',B/'PyVideoPhotoWorker',B/'PhotoWorker.o'])
ent=Path('/var/minis/workspace/pyvideo-0.0.3-analysis/evidence/PyVideoAgent/entitlements.txt')
run(['ldid','-S',B/'PyVideoPlus.dylib']);run(['ldid','-S'+str(ent),B/'PyVideoPhotoWorker'])
for name in ['PyVideoPlus.dylib','PyVideoPhotoWorker']:
 data=(B/name).read_bytes();cpu,sub=struct.unpack_from('<II',data,4)
 assert cpu==0x100000c and sub&0xffffff==2,(name,hex(cpu),hex(sub))
print('Compiled and adhoc-signed arm64e addon + photo worker')
