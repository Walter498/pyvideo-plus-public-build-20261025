#!/usr/bin/env python3
"""Structural wiring checks only; runtime validation is a separate required job."""
from pathlib import Path
import json
ROOT=Path(__file__).resolve().parents[1]
s=(ROOT/'btworker/main.mm').read_text()
for value in ('torrent-inbox','torrent-tasks','torrent-control','torrent-cache',
              'PyVideoAria2c','--bt-metadata-only=true','--bt-save-metadata=true',
              '--check-integrity=true','--select-file=','--stop-with-process=',
              'WNOHANG','LOCK_EX|LOCK_NB','PVXMapped','PVXVerified','noSidecars',
              'AVURLAsset','fsync','rename','engine_failed'):
    assert value in s,value
assert '@"\\0"' not in s
assert 'WEXITSTATUS(status)!=0' in s
for helper in ('Metadata.hpp','Runtime.hpp'):
    assert (ROOT/'btworker'/helper).is_file()
manifest=json.loads((ROOT/'config/build-manifest.json').read_text())
assert manifest['torrent_worker']==['btworker/main.mm']
b=(ROOT/'build-macos.py').read_text()
for value in ('PyVideoBTWorker','PyVideoAria2c',"'--sign','-'",'torrent-entitlements.plist','-std=c++17'):
    assert value in b,value
p=(ROOT/'package.py').read_text()
assert 'PyVideoBTWorker' in p and 'PyVideoAria2c' in p and 'torrent-worker' in p
w=(ROOT/'.github/workflows/build.yml').read_text()
for value in ('torrent-worker-contract.py','torrent-worker-runtime-check.sh',
              'magnet-normalizer-check.sh','torrent-device-e2e.py','package-contract.py',
              'timeout-minutes: 45','provenance.json'):
    assert value in w,value
print('PASS structural Torrent wiring only; requires native tests, real swarm and signed package validation')
