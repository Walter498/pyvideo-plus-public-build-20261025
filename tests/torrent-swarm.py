#!/usr/bin/env python3
"""Deterministic private BitTorrent fixture/tracker. No public DHT required."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import socket
import struct
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, urlsplit


def enc(value):
    if isinstance(value, int):
        return b'i' + str(value).encode() + b'e'
    if isinstance(value, str):
        value = value.encode('utf8')
    if isinstance(value, bytes):
        return str(len(value)).encode() + b':' + value
    if isinstance(value, list):
        return b'l' + b''.join(map(enc, value)) + b'e'
    if isinstance(value, dict):
        pairs = sorted((k.encode() if isinstance(k, str) else k, v) for k, v in value.items())
        return b'd' + b''.join(enc(k) + enc(v) for k, v in pairs) + b'e'
    raise TypeError(type(value))


def dec(data, at=0):
    if data[at:at+1] == b'i':
        end = data.index(b'e', at)
        return int(data[at+1:end]), end + 1
    if data[at:at+1] in (b'd', b'l'):
        dictionary = data[at:at+1] == b'd'
        vals, at = [], at + 1
        while data[at:at+1] != b'e':
            value, at = dec(data, at)
            vals.append(value)
        return (dict(zip(vals[::2], vals[1::2])) if dictionary else vals), at + 1
    end = data.index(b':', at)
    size = int(data[at:end])
    return data[end+1:end+1+size], end+1+size


def fixture(args):
    root = Path(args.root)
    seed = root / 'seed'
    seed.mkdir(parents=True, exist_ok=True)
    payload = Path(args.mp4).read_bytes()
    if args.pad_bytes:
        # ISO-BMFF free atom: playable video remains byte-for-byte unchanged.
        payload += struct.pack('>I4s', args.pad_bytes + 8, b'free')
        payload += (hashlib.sha256(b'PVX private swarm').digest() * ((args.pad_bytes + 31)//32))[:args.pad_bytes]
    piece = 16384
    if args.multi:
        bundle=seed/'pvx-multifile'
        entries=[(('previews','trailer.mp4'),Path(args.mp4).read_bytes()),
                 (('videos','main.mp4'),payload),
                 (('notes','readme.txt'),b'Non-video fixture file\n'*800)]
        all_bytes=b''; files=[]
        for components,content in entries:
            item=bundle.joinpath(*components); item.parent.mkdir(parents=True,exist_ok=True)
            item.write_bytes(content); all_bytes+=content
            files.append({b'length':len(content),b'path':list(components)})
        info={b'name':'pvx-multifile',b'files':files,b'piece length':piece,
              b'pieces':b''.join(hashlib.sha1(all_bytes[i:i+piece]).digest() for i in range(0,len(all_bytes),piece))}
    else:
        target = seed / 'tiny-test.mp4'
        target.write_bytes(payload)
        info = {b'name': target.name, b'length': len(payload), b'piece length': piece,
                b'pieces': b''.join(hashlib.sha1(payload[i:i+piece]).digest() for i in range(0,len(payload),piece))}
    infohash = hashlib.sha1(enc(info)).hexdigest()
    metainfo = {b'announce': args.announce, b'info': info}
    (root / 'fixture.torrent').write_bytes(enc(metainfo))
    magnet = 'magnet:?xt=urn:btih:' + infohash + '&dn=' + ('pvx-multifile' if args.multi else 'tiny-test.mp4') + '&tr=' + quote(args.announce, safe='')
    manifest = {'infoHash': infohash, 'magnet': magnet, 'bytes': len(payload),
                'sha256': hashlib.sha256(payload).hexdigest(), 'pieceCount': len(info[b'pieces'])//20,
                'multiFile':bool(args.multi),'selectedPath':'pvx-multifile/videos/main.mp4' if args.multi else 'tiny-test.mp4',
                'scope': 'private loopback tracker/peer; original video plus ISO BMFF free atom'}
    (root / 'fixture.json').write_text(json.dumps(manifest, indent=2)+'\n')
    print(json.dumps(manifest))


def tracker(args):
    peers, lock = {}, threading.Lock()
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            url = urlsplit(self.path)
            if url.path == '/status':
                with lock:
                    body = json.dumps({k.hex():len(v) for k,v in peers.items()}).encode()
            elif url.path == '/announce':
                # Latin-1 round trip preserves percent-encoded binary info_hash.
                q = parse_qs(url.query, encoding='latin-1', keep_blank_values=True)
                try:
                    ih = q['info_hash'][0].encode('latin-1')
                    port = int(q['port'][0]); left = int(q.get('left',['0'])[0])
                    assert len(ih)==20 and 0<port<65536
                except (KeyError, ValueError, AssertionError):
                    self.send_error(400); return
                addr = self.client_address[0]
                with lock:
                    swarm = peers.setdefault(ih,{})
                    if q.get('event',[''])[0]=='stopped':
                        swarm.pop((addr,port),None)
                    else:
                        swarm[(addr,port)] = (time.monotonic(),left)
                    now = time.monotonic()
                    live = {k:v for k,v in swarm.items() if now-v[0]<180}
                    peers[ih] = live
                    compact = b''.join(socket.inet_aton(ip)+struct.pack('>H',p)
                                       for (ip,p) in live if (ip,p)!=(addr,port))
                    complete = sum(v[1]==0 for v in live.values())
                    body = enc({b'interval':2,b'min interval':1,b'complete':complete,
                                b'incomplete':len(live)-complete,b'peers':compact})
                print(json.dumps({'infoHash':ih.hex(),'port':port,'left':left,
                                  'event':q.get('event',[''])[0],'peerCount':len(compact)//6}), flush=True)
            else:
                self.send_error(404); return
            self.send_response(200)
            self.send_header('Content-Type','application/octet-stream')
            self.send_header('Content-Length',str(len(body)))
            self.end_headers(); self.wfile.write(body)
        def log_message(self,*_): pass
    server = ThreadingHTTPServer(('127.0.0.1',args.port),Handler)
    print('tracker ready on loopback '+str(args.port),flush=True)
    server.serve_forever()


if __name__ == '__main__':
    p=argparse.ArgumentParser()
    s=p.add_subparsers(dest='command',required=True)
    f=s.add_parser('fixture'); f.add_argument('--root',required=True); f.add_argument('--mp4',required=True)
    f.add_argument('--announce',default='http://127.0.0.1:19099/announce')
    f.add_argument('--pad-bytes',type=int,default=0); f.add_argument('--multi',action='store_true'); f.set_defaults(fn=fixture)
    t=s.add_parser('tracker'); t.add_argument('--port',type=int,default=19099); t.set_defaults(fn=tracker)
    args=p.parse_args(); args.fn(args)
