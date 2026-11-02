"""Offline packaging regressions; never installs or launches a daemon."""
from pathlib import Path
import ast,hashlib,io,json,plistlib,runpy,struct,subprocess,tarfile,tempfile,unittest
ROOT=Path(__file__).resolve().parents[1]
verify_signature=runpy.run_path(str(ROOT/'tests/package-contract-signatures.py'))['verify_signature']

def signed_fixture():
    ent=plistlib.dumps(plistlib.loads((ROOT/'worker/torrent-entitlements.plist').read_bytes()))
    ent=struct.pack('>II',0xfade7171,len(ent)+8)+ent
    code=bytearray(4096)
    struct.pack_into('<8I',code,0,0xfeedfacf,0x100000c,0x80000002,2,1,16,0,0)
    # SHA256 CodeDirectory with 5 special slots, one code slot.
    ident=b'package-test\0';hashoff=44+len(ident)+5*32
    cdlen=hashoff+32;total=28+cdlen+len(ent)
    struct.pack_into('<4I',code,32,0x1d,16,len(code),total)
    cd=bytearray(cdlen)
    struct.pack_into('>9I',cd,0,0xfade0c02,cdlen,0x20001,2,hashoff,44,5,1,len(code))
    struct.pack_into('4B',cd,36,32,2,0,12)
    cd[44:44+len(ident)]=ident
    cd[hashoff-160:hashoff-128]=hashlib.sha256(ent).digest()
    cd[hashoff:]=hashlib.sha256(code).digest()
    return bytes(code)+struct.pack('>7I',0xfade0cc0,total,2,0,28,5,28+cdlen)+bytes(cd)+ent

class Contract(unittest.TestCase):
    def test_signed_executable(self):
        self.assertEqual(verify_signature(signed_fixture()),plistlib.loads((ROOT/'worker/torrent-entitlements.plist').read_bytes()))
    def test_corrupt_code_rejected(self):
        b=bytearray(signed_fixture());b[100]^=1
        with self.assertRaises(AssertionError):verify_signature(bytes(b))
    def test_corrupt_entitlement_rejected(self):
        b=bytearray(signed_fixture());b[-20]^=1
        with self.assertRaises(AssertionError):verify_signature(bytes(b))
    def test_both_daemons_in_actual_archive_writer(self):
        # Execute the real plist-writing block and archive writer, not copied logic.
        source=(ROOT/'package.py').read_text();tree=ast.parse(source)
        with tempfile.TemporaryDirectory() as d:
            stage=Path(d);ns={'STAGE':stage,'Path':Path,'plistlib':plistlib,'tarfile':tarfile,'io':io}
            start=source.index("job={'Label'");end=source.index("control=STAGE/'DEBIAN/control'",start)
            exec(compile(source[start:end],str(ROOT/'package.py'),'exec'),ns)
            paths=[stage/'Library/LaunchDaemons'/('com.crctdd.pyvideo.'+kind+'-worker.plist') for kind in ('photo','torrent')]
            for name in ('PyVideoPhotoWorker','PyVideoBTWorker','PyVideoAria2c'):
                p=stage/'Applications/PyVideoAgent.app'/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(signed_fixture());paths.append(p)
            modes={str(p.relative_to(stage)):0o644 if p.suffix=='.plist' else 0o755 for p in paths}
            ns.update(allfiles=paths,modes=modes)
            fn=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='archive_bytes')
            exec(compile(ast.Module(body=[fn],type_ignores=[]),'package.py','exec'),ns)
            with tarfile.open(fileobj=io.BytesIO(ns['archive_bytes'](False))) as tf:
                for p in paths:
                    member=tf.getmember('./'+str(p.relative_to(stage)))
                    self.assertEqual(member.mode,modes[str(p.relative_to(stage))])
                    self.assertEqual((member.uid,member.gid),(0,0))
                    data=tf.extractfile(member).read()
                    if p.suffix=='.plist':
                        job=plistlib.loads(data);self.assertEqual(job['UserName'],'mobile')
                        self.assertIn(job['ProgramArguments'][0].lstrip('/'),modes)
                    else:verify_signature(data)
    def test_build_policy(self):
        script=(ROOT/'tools/build-aria2-ios.sh').read_text()
        for required in ('--with-appletls','--disable-werror','-Wno-deprecated-declarations','-framework Security -framework CoreFoundation','9e7273583f83e881e3ec067b523ba88724088d2f','aria2-source.tar.gz'):
            self.assertIn(required,script)
        for forbidden in ('saveAs(', 'setClientTLSContext', '--without-appletls', 'os.walk'):
            self.assertNotIn(forbidden,script)
        self.assertNotIn('Photos',str(plistlib.loads((ROOT/'worker/torrent-entitlements.plist').read_bytes())))
        subprocess.run(['bash','-n',str(ROOT/'tools/build-aria2-ios.sh')],check=True)
    def test_postinst_syntax_and_permissions(self):
        tree=ast.parse((ROOT/'package.py').read_text())
        extra=next(n.value for n in ast.walk(tree) if isinstance(n,ast.Constant) and isinstance(n.value,str) and n.value.startswith('pv_stage=torrent-storage-permissions'))
        for directory in ('torrent-inbox','torrent-tasks','torrent-cache','torrent-control'):
            self.assertIn('"$pv_data/'+directory+'"',extra)
        self.assertIn('chown mobile:mobile',extra);self.assertIn('chmod 700',extra)
        subprocess.run(['sh','-n'],input='#!/bin/sh\n'+extra,text=True,check=True)

if __name__=='__main__':unittest.main()
