#!/usr/bin/env python3
"""Real WebKit/UIKit + production image worker integration, simulator only.
Run on macOS: python3 tests/webkit-beta3-simulator.py
Artifacts: tests/webkit-beta3-output/<unique run>/ (screenshots, hashes, logs).
No original app/worker installed and no physical-device operations are performed.
"""
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import hashlib
import json
import os
import platform
import plistlib
import shutil
import struct
import subprocess
import threading
import time
import uuid
import zlib

P = Path(__file__).resolve().parents[1]
BUNDLE = 'org.pyvideo.WebKitBeta3Integration'

def png_fixture():
    # Valid 96x96 RGB PNG, not a too-small filtered tracking pixel.
    def chunk(kind, data):
        return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data) & 0xffffffff)
    raw = (b'\0' + bytes([24, 155, 170]) * 96) * 96
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!IIBBBBB', 96, 96, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


def main():
    if platform.system() != 'Darwin':
        raise SystemExit('Requires macOS + Xcode iOS simulator; NOT a source-only PASS.')
    out = P / 'tests/webkit-beta3-output' / (time.strftime('%Y%m%d-%H%M%S-') + uuid.uuid4().hex[:8])
    out.mkdir(parents=True)
    log = out / 'commands.log'

    def run(args, env=None, timeout=150):
        args = list(map(str, args))
        result = subprocess.run(args, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
        with log.open('a') as stream:
            stream.write('$ ' + ' '.join(args) + '\n' + result.stdout + '\n')
        print(result.stdout, end='', flush=True)
        if result.returncode:
            raise RuntimeError('Command failed: ' + ' '.join(args))
        return result.stdout.strip()

    requests = []
    requests_lock = threading.Lock()
    png = png_fixture()

    class Fixture(BaseHTTPRequestHandler):
        def do_GET(self):
            with requests_lock:
                requests.append({'method': 'GET', 'path': self.path})
            if self.path == '/real.png':
                data, mime, status = png, 'image/png', 200
            elif self.path in ('/real.mp4','/network.mp4'):
                # Detection fixture: network.mp4 is fetched dynamically by page JS.
                data, mime, status = b'PVX-video-URL-detection-only', 'video/mp4', 200
            else:
                data, mime, status = b'not found', 'text/plain', 404
            self.send_response(status)
            self.send_header('Content-Type', mime)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            try:
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def log_message(self, *_args):
            pass

    server = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    url = f'http://127.0.0.1:{server.server_port}/'
    app = out / 'WebKitBeta3.app'
    app.mkdir()
    plist = {'CFBundleIdentifier': BUNDLE, 'CFBundleExecutable': 'WebKitBeta3',
             'CFBundleName': 'WebKitBeta3', 'CFBundlePackageType': 'APPL',
             'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0',
             'MinimumOSVersion': '16.0', 'UIDeviceFamily': [1, 2],
             'NSAppTransportSecurity': {'NSAllowsArbitraryLoads': True, 'NSAllowsLocalNetworking': True},
             'NSPhotoLibraryAddUsageDescription': 'User initiated system export integration test.'}
    (app / 'Info.plist').write_bytes(plistlib.dumps(plist))
    shutil.copy2(P / 'resources/MediaCollector.js', app / 'MediaCollector.js')
    (out / 'fixture.png').write_bytes(png)
    sources = ['src/Images.m', 'src/Collection.m', 'src/TaskSupport.m', 'src/DownloadsUI.m',
               'src/PVXCommon.h', 'src/MediaMetadata.m', 'worker/main.m', 'resources/MediaCollector.js', 'tests/webkit-beta3-ui.m',
               'tests/webkit-beta3-simulator.py']
    hashes = {name: hashlib.sha256((P / name).read_bytes()).hexdigest() for name in sources}
    (out / 'source-sha256.json').write_text(json.dumps(hashes, indent=2))
    # Generated build artifact only: compile the unchanged worker in its own TU.
    wrapper = out / 'webkit-beta3-worker.m'
    wrapper.write_text('#define main PVXFixtureWorkerEntry\n#import "' + str(P / 'worker/main.m') + '"\n#undef main\nid PVXStartFixtureWorker(NSString *root) { PVXPhotoWorker *w=[PVXPhotoWorker new]; w.root=root; return [w start] ? w : nil; }\n')
    sdk = run(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'])
    arch = platform.machine()
    run(['xcrun', '--sdk', 'iphonesimulator', 'clang', '-arch', arch,
         '-mios-simulator-version-min=16.0', '-isysroot', sdk, '-DPVX_TEST=1',
         '-fobjc-arc', '-fblocks', '-Wall', '-Wextra', '-Werror',
         '-Wno-unused-parameter', '-Wno-deprecated-declarations', '-I', P / 'src',
         P / 'tests/webkit-beta3-ui.m', P / 'src/Images.m', P / 'src/MediaPreview.m', P / 'src/MediaQuality.m', P / 'src/MediaMetadata.m', wrapper, '-o', app / 'WebKitBeta3',
         '-framework', 'Foundation', '-framework', 'UIKit', '-framework', 'WebKit',
         '-framework', 'ImageIO', '-framework', 'UniformTypeIdentifiers', '-framework', 'AVFoundation', '-framework', 'CoreMedia', '-framework', 'CoreGraphics', '-framework', 'AVKit', '-framework', 'Photos', '-framework', 'AVFAudio', '-framework', 'QuartzCore', '-framework', 'CoreVideo'])
    run(['codesign', '--force', '--sign', '-', app])
    devices = json.loads(run(['xcrun', 'simctl', 'list', 'devices', 'available', '--json']))['devices']
    phones = [dict(d, runtime=runtime) for runtime, group in devices.items() for d in group
              if d.get('isAvailable') and d['name'].startswith('iPhone')]
    if not phones:
        raise RuntimeError('No available iPhone simulator')
    selected = next((d for d in phones if d['state'] == 'Booted'), phones[0])
    udid = selected['udid']
    (out / 'simulator.json').write_text(json.dumps(selected, indent=2))
    if selected['state'] != 'Booted':
        run(['xcrun', 'simctl', 'boot', udid])
    run(['xcrun', 'simctl', 'bootstatus', udid, '-b'], timeout=240)
    run(['xcrun', 'simctl', 'install', udid, app])
    container = Path(run(['xcrun', 'simctl', 'get_app_container', udid, BUNDLE, 'data']))
    docs = container / 'Documents'
    docs.mkdir(exist_ok=True)
    # Dedicated test bundle only. Clear stale PASS/markers and fixture state.
    for item in docs.iterdir():
        if item.is_dir():
            shutil.rmtree(item)
        else:
            item.unlink()
    env = dict(os.environ, SIMCTL_CHILD_PVX_FIXTURE_URL=url)
    try:
        run(['xcrun', 'simctl', 'launch', '--terminate-running-process', udid, BUNDLE], env=env)
        deadline = time.monotonic() + 150
        result = docs / 'webkit-beta3-result.txt'
        captured = set()
        while time.monotonic() < deadline:
            for name in ('collection', 'menu', 'activity', 'native-player'):
                if name not in captured and (docs / (name + '.capture')).exists():
                    # Actual simulator framebuffer (UIKit + real WK/system share sheet).
                    run(['xcrun', 'simctl', 'io', udid, 'screenshot', out / (name + '.png')])
                    (docs / (name + '.captured')).write_text('simctl framebuffer captured\n')
                    captured.add(name)
            if result.exists():
                break
            time.sleep(.1)
        if not result.exists():
            raise RuntimeError('No UIKit result before deadline; assertion/crash is NOT a PASS; inspect simulator logs')
        text = result.read_text()
        (out / 'result.txt').write_text(text)
        if not text.startswith('PASS '):
            raise RuntimeError(text)
        if captured != {'collection', 'menu', 'activity', 'native-player'}:
            raise RuntimeError('Missing real simulator screenshot')
        artifact = json.loads((docs / 'webkit-beta3-artifacts.json').read_text())
        source, staged = Path(artifact['source']), Path(artifact['staged'])
        a, b = source.read_bytes(), staged.read_bytes()
        if not a or a != b or a != png or not b.startswith(b'\x89PNG\r\n\x1a\n'):
            raise RuntimeError('Worker original / staged PNG differ from actual HTTP fixture')
        shutil.copy2(source, out / 'source.png')
        shutil.copy2(staged, out / 'staged.png')
        artifact['sourceSHA256'] = hashlib.sha256(a).hexdigest()
        artifact['stagedSHA256'] = hashlib.sha256(b).hexdigest()
        artifact['fixtureSHA256'] = hashlib.sha256(png).hexdigest()
        with requests_lock:
            artifact['httpRequests'] = list(requests)
        if sum(r['path'] == '/real.png' for r in artifact['httpRequests']) < 2:
            raise RuntimeError('Expected separate WebKit image and real worker HTTP GETs')
        (out / 'artifacts.json').write_text(json.dumps(artifact, indent=2, ensure_ascii=False))
        print(text)
        print('Artifacts:', out)
    except Exception:
        for evidence in docs.glob('webkit-beta3-*'):
            if evidence.is_file():
                shutil.copy2(evidence, out / evidence.name)
        diagnostic = subprocess.run(['xcrun', 'simctl', 'spawn', udid, 'log', 'show', '--last', '3m', '--style', 'compact', '--predicate', 'process == "WebKitBeta3"'], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
        (out / 'failure-console.log').write_text(diagnostic.stdout)
        print(diagnostic.stdout[-18000:], flush=True)
        subprocess.run(['xcrun', 'simctl', 'io', udid, 'screenshot', str(out / 'failure.png')], timeout=20)
        raise
    finally:
        server.shutdown()
        # Simulator test bundle only; leave framebuffer/evidence intact on disk.
        subprocess.run(['xcrun', 'simctl', 'terminate', udid, BUNDLE], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == '__main__':
    main()
