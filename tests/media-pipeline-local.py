#!/usr/bin/env python3
"""Local media pipeline smoke test; no iOS runtime is required."""
from __future__ import annotations
import base64, http.server, json, os, plistlib, random, shutil, socketserver, subprocess, tempfile, threading
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_HEAD(self):
        # Deliberately wrong metadata: this reproduces the 915-byte symptom.
        if self.path == "/image.jpg":
            self.send_response(200); self.send_header("Content-Length", "915"); self.end_headers(); return
        if self.path == "/video.mp4":
            self.send_response(405); self.end_headers(); return
        self.send_error(404)
    def do_GET(self):
        if self.path == "/image.jpg":
            self.send_response(200); self.send_header("Content-Type", "image/png"); self.send_header("Content-Length", str(len(PNG))); self.end_headers(); self.wfile.write(PNG); return
        if self.path == "/video.mp4":
            total = 123456
            if self.headers.get("Range") == "bytes=0-0":
                self.send_response(206); self.send_header("Content-Range", f"bytes 0-0/{total}"); self.send_header("Content-Length", "1"); self.end_headers(); self.wfile.write(b"x"); return
        self.send_error(404)

def run(*args):
    p = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if p.returncode:
        raise AssertionError(f"command failed: {' '.join(args)}\n{p.stderr}")
    return p

def test_http_contract():
    server = socketserver.TCPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    import urllib.request
    base = f"http://127.0.0.1:{server.server_address[1]}"
    head = urllib.request.urlopen(urllib.request.Request(base+"/image.jpg", method="HEAD"))
    body = urllib.request.urlopen(base+"/image.jpg").read()
    assert head.headers["Content-Length"] == "915"
    assert len(body) == len(PNG) and len(body) != 915
    assert body[:8] == b"\x89PNG\r\n\x1a\n"
    range_req = urllib.request.Request(base+"/video.mp4", headers={"Range":"bytes=0-0"})
    ranged = urllib.request.urlopen(range_req)
    assert ranged.status == 206 and ranged.headers["Content-Range"].endswith("/123456")
    server.shutdown(); server.server_close()
    print("PASS HTTP: ignore bad HEAD length; GET image bytes and Range total")

def test_hls_reorder():
    with tempfile.TemporaryDirectory(prefix="pvx-media-") as td:
        d = Path(td); source = d/"source"; source.mkdir()
        input_image=d/"source.png";input_image.write_bytes(PNG)
        run("ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-loop", "1", "-i", str(input_image), "-t", "6", "-c:v", "mpeg2video", "-g", "25", "-b:v", "900k", "-f", "segment", "-segment_time", "1", "-reset_timestamps", "1", "-segment_format", "mpegts", str(source/"orig-%03d.ts"))
        originals = sorted(source.glob("orig-*.ts"))
        assert len(originals) >= 5
        cache = d/"uuid.hls"; cache.mkdir()
        indices = list(range(42, 42+len(originals))); order = indices[:]; random.Random(19).shuffle(order)
        for i, original in zip(order, originals):
            leaf = f"cache-{i:04d}.ts"; shutil.copyfile(original, cache/leaf)
            meta = {"responseURL": f"https://cdn.example/video{i}.jpeg", "source": f"video{i}.jpeg", "size": original.stat().st_size}
            (cache/(leaf+".plist")).write_bytes(plistlib.dumps(meta, fmt=plistlib.FMT_BINARY))
        rows = []
        for meta_path in cache.glob("*.ts.plist"):
            meta = plistlib.loads(meta_path.read_bytes()); rows.append((int(meta["responseURL"].split("video")[1].split(".")[0]), meta_path.with_suffix("")))
        rows.sort()
        playlist = cache/"recovery.m3u8"
        with playlist.open("w") as f:
            f.write("#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:10\n#EXT-X-MEDIA-SEQUENCE:42\n")
            for _, path in rows: f.write(f"#EXTINF:10.000,\n{path.name}\n")
            f.write("#EXT-X-ENDLIST\n")
        text = playlist.read_text(); assert text.index("cache-0042.ts") < text.index("cache-0043.ts")
        out = d/"recovered.mp4"
        expected_probe = json.loads(run("ffprobe", "-v", "error", "-show_entries", "stream=width,height", "-of", "json", str(originals[0])).stdout)
        expected_video = expected_probe["streams"][0]
        run("ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-protocol_whitelist", "file,crypto,data", "-allowed_extensions", "ALL", "-i", str(playlist), "-map", "0:v:0", "-c", "copy", "-movflags", "+faststart", str(out))
        probe = json.loads(run("ffprobe", "-v", "error", "-show_entries", "stream=codec_type,width,height", "-show_entries", "format=duration", "-of", "json", str(out)).stdout)
        streams = probe.get("streams", []); fmt = probe.get("format", {})
        video = next((x for x in streams if x.get("codec_type") == "video"), None)
        assert video and video.get("width") == expected_video["width"] and video.get("height") == expected_video["height"]
        assert float(fmt.get("duration", 0)) > 0
        print(f"PASS HLS: {len(rows)} shuffled TS -> ordered MEDIA-SEQUENCE 42 -> {out.stat().st_size} bytes MP4")

def test_source_guards():
    metadata = (ROOT/"src/MediaMetadata.m").read_text()
    storage = (ROOT/"storage/Storage.m").read_text()
    ui = (ROOT/"src/DownloadsUI.m").read_text()
    main = (ROOT/"src/Main.m").read_text()
    assert 'if(!declaredManifest)[r setValue:@"bytes=0-65535"' in main
    assert '&&http.statusCode<300&&!errorBody&&(manifest||video)' in main
    assert 'request.HTTPMethod=@"HEAD"' not in metadata
    assert 'PVXImageData' in metadata and 'bytes=0-0' in metadata
    assert 'PVXHLSLocalizer' in storage
    recovery=(ROOT/'storage/PVXRecovery.inc').read_text()
    assert 'PVRemuxHLSWithCancel' in (ROOT/'storage/PVXNativeRemux.m').read_text()
    assert 'recovery-started' in recovery
    assert 'pvxRecoveryActive' in recovery and 'PVXRecoveryHeartbeat' in recovery
    assert 'live[@"state"]=@"paused";' in recovery
    assert 'if(job&&[action isEqual:@"resume"])return YES;' in recovery
    libav_input=(ROOT/'storage/PVXLibavInput.m').read_text()
    assert 'PVXADTS' in libav_input
    assert 'resourceReport' in libav_input
    assert 'PVXRepairRepeatedAudioPESFile' in libav_input
    assert 'Native input resource escapes task cache' in libav_input
    assert 'sharedLockVerified' in (ROOT/'storage/PVXNativeRemux.m').read_text()
    assert 'PVXFetchTaskThumbnail(linked?r[@"linkedTask"]:r,' in ui
    assert 'if(collect&&!self.metadataRequested&&NSDate.date.timeIntervalSince1970>=self.metadataRetryAfter)' in ui
    assert 'PVXFetchMediaMetadata(r,' in ui
    assert 'PVXMetadataTakeDelivery(&state,timeout)' in metadata and 'if(manifest)return' not in metadata
    print("PASS source: GET/ImageIO metadata, no-playlist recovery, collection thumbnail trigger")

if __name__ == "__main__":
    test_source_guards(); test_http_contract(); test_hls_reorder(); print("PASS local media pipeline smoke suite")
