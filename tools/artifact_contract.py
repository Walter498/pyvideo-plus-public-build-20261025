"""Fingerprint tracked production inputs, shared by build and packaging."""
from pathlib import Path
import hashlib,subprocess

def source_contract(root):
    root=Path(root)
    files=subprocess.check_output(['git','ls-files','src','storage','worker','btworker','config','resources','depiction','build-macos.py','package.py','tools','tests/package-contract-signatures.py','.github/workflows/build.yml'],cwd=root,text=True).splitlines()
    digest=hashlib.sha256()
    for name in sorted(files):
        digest.update(name.encode()+b'\0'+(root/name).read_bytes()+b'\0')
    return {'gitCommit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),
            'productionSHA256':digest.hexdigest(),'inputCount':len(files)}
