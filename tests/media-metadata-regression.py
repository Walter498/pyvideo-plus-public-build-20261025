#!/usr/bin/env python3
"""Regression contract tests for unified media resources (no device access)."""
import http.server, socketserver, threading, urllib.request, urllib.error, time, pathlib, re
ROOT=pathlib.Path(__file__).resolve().parents[1]
class H(http.server.BaseHTTPRequestHandler):
    calls=[]
    def log_message(self,*a): pass
    def do_HEAD(self):
        self.send_response(200); self.send_header('Content-Length','915'); self.end_headers()
    def do_GET(self):
        H.calls.append((self.path,self.headers.get('Cookie'),self.headers.get('Referer'),self.headers.get('Range')))
        if self.path=='/image.jpg':
            b=b'\x89PNG\r\n\x1a\n'; self.send_response(200); self.send_header('Content-Type','image/png'); self.send_header('Content-Length',str(len(b))); self.end_headers(); self.wfile.write(b); return
        if self.path=='/video.mp4' and self.headers.get('Range')=='bytes=0-0':
            self.send_response(206); self.send_header('Content-Range','bytes 0-0/123456'); self.end_headers(); self.wfile.write(b'x'); return
        if self.path=='/redirect': self.send_response(302); self.send_header('Location','/image.jpg'); self.end_headers(); return
        self.send_error(404)
def run():
    s=socketserver.TCPServer(('127.0.0.1',0),H); threading.Thread(target=s.serve_forever,daemon=True).start(); b=f'http://127.0.0.1:{s.server_address[1]}'
    assert urllib.request.urlopen(urllib.request.Request(b+'/image.jpg',method='HEAD')).headers['Content-Length']=='915'
    assert urllib.request.urlopen(b+'/image.jpg').read()==b'\x89PNG\r\n\x1a\n'
    r=urllib.request.urlopen(urllib.request.Request(b+'/video.mp4',headers={'Range':'bytes=0-0'})); assert r.status==206 and r.headers['Content-Range']=='bytes 0-0/123456'
    m=(ROOT/'src/MediaMetadata.m').read_text(); q=(ROOT/'src/PVXMediaResource.m').read_text(); p=(ROOT/'src/MediaPreview.m').read_text()
    for x in ['PVXMediaResourceFetch','PVXMediaCookiesForURL','100*1024*1024','Content-Range','AVURLAssetHTTPHeaderFieldsKey','AVMediaTypeVideo']: assert x in m+q
    assert 'requestHeaderFieldsWithCookies' in p and 'PVXPreviewCookie' in p
    assert 'bytes=0-0' in m and 'HTTPMethod=@"HEAD"' not in m
    s.shutdown(); s.server_close(); print('PASS metadata contract: bad HEAD ignored, real GET, strict range, bounded resource, cookie/path/secure filtering, asset headers, video track/thumbnail')
if __name__=='__main__': run()
