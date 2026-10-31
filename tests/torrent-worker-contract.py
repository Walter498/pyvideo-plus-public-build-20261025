#!/usr/bin/env python3
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
checks={
 'worker':'btworker/main.mm',
 'manifest':'config/build-manifest.json',
 'build':'build-macos.py',
 'package':'package.py',
 'contract':'tools/artifact_contract.py'
}
for k,p in checks.items():
 assert (ROOT/p).is_file(),p
s=(ROOT/'btworker/main.mm').read_text()
for x in ['torrent-inbox','torrent-tasks','torrent-control','PyVideoAria2c','bt-save-metadata=true','enable-dht=true','bt-stop-timeout=600','PVXPlayable','media/%@.mp4','backend','calloc(args.count+1','flock(lock,LOCK_EX|LOCK_NB)','PVXMapped','PVXRoot(NSString *override)']:
 assert x in s,x
assert 'bt-metadata-only=true' not in s
assert '@"\\0"' not in s
m=(ROOT/'config/build-manifest.json').read_text()
assert 'torrent_worker' in m and 'btworker/main.mm' in m
b=(ROOT/'build-macos.py').read_text(); assert 'PyVideoBTWorker' in b and 'PyVideoAria2c' in b and "'--sign','-'" in b
p=(ROOT/'package.py').read_text(); assert 'PyVideoBTWorker' in p and 'PyVideoAria2c' in p and 'torrent-worker' in p and 'torrent-inbox' in p
w=(ROOT/'.github/workflows/build.yml').read_text(); assert 'torrent-worker-contract.py' in w and 'timeout-minutes: 45' in w
print('PASS torrent worker contract: isolated queue, mapped paths, argv safety, DHT, daemon packaging')
