#!/usr/bin/env python3
"""Run whole production TaskSupport.m + Collection.m on an iOS simulator, no device install."""
from pathlib import Path
import json, os, plistlib, subprocess, time
P=Path(__file__).resolve().parents[1]
B=P/'tests/export-beta3-output'; B.mkdir(exist_ok=True)
def run(args):
    r=subprocess.run(list(map(str,args)),text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    print(r.stdout,end='')
    if r.returncode: raise RuntimeError('command failed: '+' '.join(map(str,args)))
    return r.stdout.strip()
sdk=run(['xcrun','--sdk','iphonesimulator','--show-sdk-path'])
arch=run(['uname','-m'])
app=B/'ExportBeta3.app'; app.mkdir(exist_ok=True)
plist={'CFBundleIdentifier':'org.pyvideo.ExportBeta3Integration','CFBundleExecutable':'ExportBeta3','CFBundleName':'ExportBeta3','CFBundlePackageType':'APPL','MinimumOSVersion':'15.0','UIDeviceFamily':[1,2], 'NSPhotoLibraryAddUsageDescription':'Only user-initiated system activity sheet export.'}
(app/'Info.plist').write_bytes(plistlib.dumps(plist))
run(['xcrun','--sdk','iphonesimulator','clang','-arch',arch,'-mios-simulator-version-min=15.0','-isysroot',sdk,'-fobjc-arc','-fblocks','-Wall','-Wextra','-Werror','-Wno-unused-parameter','-Wno-deprecated-declarations','-I',P/'src',P/'tests/export-beta3-ui.m','-o',app/'ExportBeta3','-framework','Foundation','-framework','UIKit','-framework','WebKit','-framework','ImageIO','-framework','UniformTypeIdentifiers','-framework','AVFoundation'])
run(['codesign','--force','--sign','-',app])
devices=json.loads(run(['xcrun','simctl','list','devices','available','--json']))['devices']
flat=[d for ds in devices.values() for d in ds if d.get('isAvailable') and d['name'].startswith('iPhone')]
assert flat,'No iPhone simulator available'
d=next((d for d in flat if d['state']=='Booted'),flat[0]); udid=d['udid']
if d['state']!='Booted':run(['xcrun','simctl','boot',udid])
run(['xcrun','simctl','bootstatus',udid,'-b'])
run(['xcrun','simctl','install',udid,app])
run(['xcrun','simctl','launch',udid,'org.pyvideo.ExportBeta3Integration'])
container=Path(run(['xcrun','simctl','get_app_container',udid,'org.pyvideo.ExportBeta3Integration','data']))
result=container/'Documents/export-beta3-ui-result.txt'
for _ in range(90):
    if result.exists():break
    time.sleep(1)
assert result.exists(),'Integration failed: no PASS result from assertions; inspect simulator crash log'
text=result.read_text();assert text.startswith('PASS '),text
(B/'result.txt').write_text(text)
print(text)
