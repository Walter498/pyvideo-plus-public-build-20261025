#!/usr/bin/env python3
from pathlib import Path
from tools.artifact_contract import source_contract
import subprocess,struct,json,hashlib
P=Path(__file__).resolve().parent;B=P/'build';B.mkdir(exist_ok=True)
manifest=json.loads((P/'config/build-manifest.json').read_text())
def sources(key):
 paths=[P/item for item in manifest[key]]
 missing=[str(p) for p in paths if not p.is_file()]
 if missing:raise RuntimeError('missing manifest sources: '+', '.join(missing))
 return paths
def run(args):
 r=subprocess.run(list(map(str,args)),text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 print(r.stdout,end='')
 if r.returncode:raise RuntimeError('command failed: '+' '.join(map(str,args)))
 return r.stdout.strip()
sdk=run(['xcrun','--sdk','iphoneos','--show-sdk-path'])
flags=['xcrun','--sdk','iphoneos','clang','-arch','arm64e','-miphoneos-version-min=15.0','-isysroot',sdk,'-F'+sdk+'/System/Library/SubFrameworks','-fobjc-arc','-fblocks','-Os','-Wall','-Wextra','-Werror','-Wno-unused-parameter','-Wno-deprecated-declarations','-I',P/'src']
plugin_frameworks=['Foundation','UIKit','WebKit','AVFoundation','AVFAudio','AVKit','Photos','ImageIO','CoreGraphics','CoreMedia','QuartzCore','UniformTypeIdentifiers']
worker_frameworks=['Foundation','ImageIO','UniformTypeIdentifiers']
storage_frameworks=['Foundation','AVFoundation','CoreMedia','CoreVideo','CoreGraphics']
def frameworks(names):
 out=[]
 for name in names:out += ['-framework',name]
 return out
plugin_flags=flags+frameworks(plugin_frameworks)
worker_flags=flags+frameworks(worker_frameworks)
torrent_flags=['xcrun','--sdk','iphoneos','clang++','-std=c++17','-arch','arm64e','-miphoneos-version-min=15.0','-isysroot',sdk,'-fobjc-arc','-fblocks','-stdlib=libc++','-Os','-Wall','-Wextra','-Werror','-Wno-unused-parameter','-Wno-deprecated-declarations','-I',P/'src']+frameworks(['Foundation','AVFoundation','CoreMedia','CoreGraphics'])
storage_flags=flags+frameworks(storage_frameworks)
plugin_sources=sources('plugin')
run(plugin_flags+['-dynamiclib','-Wl,-install_name,@loader_path/PyVideoPlus.dylib','-o',B/'PyVideoPlus.dylib']+plugin_sources)
run(worker_flags+['-o',B/'PyVideoPhotoWorker']+sources('photo_worker'))
run(torrent_flags+['-o',B/'PyVideoBTWorker']+sources('torrent_worker'))
run(storage_flags+['-dynamiclib','-Wl,-install_name,@executable_path/PyVideoStorage.dylib','-Wl,-rpath,@executable_path/Frameworks','-Wl,-rpath,@loader_path/../Frameworks','-o',B/'PyVideoStorage.dylib']+sources('storage'))
# aria2 is fetched and built by the CI wrapper before this script.
aria2=B/'PyVideoAria2c'
if not aria2.is_file():raise RuntimeError('missing build/PyVideoAria2c; run tools/build-aria2-ios.sh first')
provenance_path=B/'third-party/aria2/provenance.json'
provenance=json.loads(provenance_path.read_text())
assert provenance['gitCommit']=='9e7273583f83e881e3ec067b523ba88724088d2f'
assert provenance['version']=='1.37.0' and provenance['tlsBackend']=='AppleTLS' and provenance['sourcePatches']==[]
for filename,digest in provenance['files'].items():
 assert Path(filename).name==filename
 assert hashlib.sha256((provenance_path.parent/filename).read_bytes()).hexdigest()==digest
info={'_source':source_contract(P),'_aria2':provenance,'_aria2ProvenanceSHA256':hashlib.sha256(provenance_path.read_bytes()).hexdigest()}
for name in ['PyVideoPlus.dylib','PyVideoPhotoWorker','PyVideoBTWorker','PyVideoStorage.dylib','PyVideoAria2c']:
 p=B/name;data=p.read_bytes();magic,cpu,sub,typ=struct.unpack_from('<IIII',data)
 assert magic==0xfeedfacf and cpu==0x100000c and sub&0xffffff==2,(name,hex(sub))
 entitlement=None
 if name=='PyVideoPhotoWorker':entitlement=P/'worker/entitlements.plist'
 elif name in ('PyVideoBTWorker','PyVideoAria2c'):entitlement=P/'worker/torrent-entitlements.plist'
 signing=['codesign','--force','--sign','-']
 if entitlement:signing+=['--entitlements',entitlement]
 run(signing+[p])
 run(['codesign','--verify','--strict',p])
 info[name]={'size':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'cpuSubtype':hex(sub),'fileType':typ,'signatureVerified':True,'entitlementsSHA256':hashlib.sha256(entitlement.read_bytes()).hexdigest() if entitlement else None}
 if name=='PyVideoAria2c':info[name]['provenanceSHA256']=info['_aria2ProvenanceSHA256']
(B/'cloud-build.json').write_text(json.dumps(info,indent=2)+'\n');print(json.dumps(info,indent=2))
