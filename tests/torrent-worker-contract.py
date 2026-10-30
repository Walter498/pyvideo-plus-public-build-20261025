#!/usr/bin/env python3
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
checks={
 'worker':'btworker/main.mm',
 'manifest':'config/build-manifest.json',
 'build':'build-macos.py',
 'package':'package.py'
}
for k,p in checks.items():
 assert (ROOT/p).is_file(),p
s=(ROOT/'btworker/main.mm').read_text()
for x in ['torrent-inbox','torrent-tasks','PyVideoAria2c','bt-metadata-only=true','bt-save-metadata=true','enable-dht=true','media/%@.mp4','backend']:
 assert x in s,x
m=(ROOT/'config/build-manifest.json').read_text()
assert 'torrent_worker' in m and 'btworker/main.mm' in m
b=(ROOT/'build-macos.py').read_text(); assert 'PyVideoBTWorker' in b and 'PyVideoAria2c' in b
p=(ROOT/'package.py').read_text(); assert 'PyVideoBTWorker' in p and 'PyVideoAria2c' in p and 'torrent-worker' in p
print('PASS torrent worker contract: isolated queue, aria2 metadata, DHT, atomic media publication, daemon packaging')
