#!/usr/bin/env python3
from pathlib import Path
import subprocess,json,plistlib,time
P=Path(__file__).resolve().parent;B=P/'build';app=B/'Preview.app';app.mkdir(exist_ok=True)
def run(args,check=True):
 r=subprocess.run(list(map(str,args)),text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 print(r.stdout,end='')
 if check and r.returncode:raise RuntimeError(' '.join(map(str,args)))
 return r.stdout.strip()
sdk=run(['xcrun','--sdk','iphonesimulator','--show-sdk-path']);arch=run(['uname','-m'])
run(['xcrun','--sdk','iphonesimulator','clang','-arch',arch,'-mios-simulator-version-min=15.0','-isysroot',sdk,'-F'+sdk+'/System/Library/SubFrameworks','-fobjc-arc','-fblocks','-Wno-deprecated-declarations','-I',P/'src',P/'src/Downloads.m',P/'preview/Preview.m','-framework','UIKit','-framework','Foundation','-framework','WebKit','-framework','CoreGraphics','-o',app/'Preview'])
(app/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.crctdd.pyvideo.preview','CFBundleExecutable':'Preview','CFBundleName':'Preview','CFBundleVersion':'1','CFBundleShortVersionString':'1','CFBundlePackageType':'APPL','UILaunchScreen':{},'LSRequiresIPhoneOS':True,'UIDeviceFamily':[1],'UISupportedInterfaceOrientations':['UIInterfaceOrientationPortrait']}))
devices=json.loads(run(['xcrun','simctl','list','devices','available','--json']))['devices'];phone=next((d for group in devices.values() for d in group if d['name'].startswith('iPhone') and d.get('isAvailable')),None)
assert phone
udid=phone['udid'];run(['xcrun','simctl','boot',udid],False);run(['xcrun','simctl','bootstatus',udid,'-b']);run(['xcrun','simctl','install',udid,app]);run(['xcrun','simctl','launch',udid,'com.crctdd.pyvideo.preview']);time.sleep(4);run(['xcrun','simctl','io',udid,'screenshot',B/'downloads-preview.png']);print('UI preview fixtures only: not a live download or on-device test')
