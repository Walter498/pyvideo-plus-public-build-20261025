#!/usr/bin/env python3
"""CC0 synthetic media regression of production PVXHLSLocalizer, macOS host only.

Requires ffmpeg (lavfi testsrc2/sine, libx264, AAC), ffprobe, openssl; no downloads.
Host ffmpeg success is NOT evidence that the original iOS libav remuxer succeeds.
Every subprocess has a 120-second limit and retained command/stdout/stderr files.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import random
import re
import shutil
import subprocess
import sys
from urllib.parse import unquote, urljoin, urlsplit


class Regression:
    def __init__(self, args):
        self.root = args.work_dir.resolve()
        self.root.mkdir(parents=True, exist_ok=True)
        if " " not in str(self.root):
            raise ValueError("--work-dir must contain a space to exercise path handling")
        self.cli = args.cli.resolve()
        self.ffmpeg, self.ffprobe, self.openssl = args.ffmpeg, args.ffprobe, args.openssl
        self.logs = self.root / "subprocess logs"
        self.logs.mkdir(exist_ok=True)
        self.serial = 0
        self.results = []

    def run(self, argv, cwd=None, expected=0):
        self.serial += 1
        stem = self.logs / f"{self.serial:03d}"
        argv = [str(x) for x in argv]
        stem.with_suffix(".command.json").write_text(json.dumps(
            {"argv": argv, "cwd": str(cwd or self.root), "timeout": 120}, indent=2))
        with stem.with_suffix(".stdout").open("wb") as out, stem.with_suffix(".stderr").open("wb") as err:
            try:
                proc = subprocess.run(argv, cwd=cwd or self.root, stdout=out, stderr=err,
                                      timeout=120, check=False)
            except subprocess.TimeoutExpired as exc:
                raise RuntimeError(f"120s timeout; stderr: {stem}.stderr") from exc
        stdout = stem.with_suffix(".stdout").read_text(errors="replace")
        stderr = stem.with_suffix(".stderr").read_text(errors="replace")
        if (expected == 0 and proc.returncode != 0) or (expected != 0 and proc.returncode == 0):
            raise RuntimeError(f"Unexpected exit {proc.returncode}: {argv!r}\n"
                               f"stderr retained: {stem}.stderr\n{stderr[-6000:]}")
        return stdout, stderr

    def ff(self, *argv, cwd=None):
        return self.run([self.ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-y", *argv], cwd)

    def generate(self, folder, kind="ts", tracks="av"):
        folder.mkdir(parents=True)
        inputs = []
        if "v" in tracks:
            inputs += ["-f", "lavfi", "-i", "testsrc2=size=160x96:rate=12:duration=3.4"]
        if "a" in tracks:
            inputs += ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=3.4"]
        codecs = []
        if "v" in tracks:
            codecs += ["-c:v", "libx264", "-threads", "1", "-pix_fmt", "yuv420p",
                       "-g", "12", "-keyint_min", "12", "-sc_threshold", "0"]
        if "a" in tracks:
            codecs += ["-c:a", "aac", "-b:a", "64k"]
        container = ["-hls_segment_type", "fmp4", "-hls_fmp4_init_filename", "init.mp4"] if kind == "fmp4" else []
        extension = "m4s" if kind == "fmp4" else "ts"
        self.ff(*inputs, *codecs, "-f", "hls", "-hls_time", "1", "-hls_list_size", "0",
                "-hls_playlist_type", "vod", *container, "-hls_segment_filename",
                f"segment-%03d.{extension}", "index.m3u8", cwd=folder)
        text = (folder / "index.m3u8").read_text()
        if len(extinf(text)) < 3 or len(set(extinf(text))) < 2:
            raise AssertionError("Fixture must have multiple segments and unequal final EXTINF")
        return folder / "index.m3u8"

    def encrypt(self, folder, mode):
        # Encrypt every original TS independently with PKCS#7 (openssl default).
        # Keep EXTINF untouched; sequence numbers, never shuffled cache indexes, choose IVs.
        path = folder / "index.m3u8"
        text = path.read_text()
        sequence = {"implicit": 37, "explicit": 73, "rotation": 251}[mode]
        text = re.sub(r"#EXT-X-MEDIA-SEQUENCE:\d+", f"#EXT-X-MEDIA-SEQUENCE:{sequence}", text)
        keys = [bytes(range(16)), bytes(range(16, 32))]
        (folder / "key-a.bin").write_bytes(keys[0])
        if mode == "rotation":
            (folder / "key-b.bin").write_bytes(keys[1])
        lines, number = [], 0
        for line in text.splitlines():
            if line and not line.startswith("#"):
                key_index = number % 2 if mode == "rotation" else 0
                # Explicit IV is intentionally unrelated to MEDIA-SEQUENCE.
                iv = (0x123456789ABCDEF + number).to_bytes(16, "big") if mode == "explicit" else (sequence + number).to_bytes(16, "big")
                if mode != "implicit" or number == 0:
                    tag = f'#EXT-X-KEY:METHOD=AES-128,URI="key-{"b" if key_index else "a"}.bin"'
                    if mode == "explicit":
                        tag += f",IV=0x{iv.hex()}"
                    # Insert before its EXTINF, not between EXTINF and URI.
                    position = len(lines) - 1
                    if position < 0 or not lines[position].startswith("#EXTINF:"):
                        raise AssertionError("unexpected generated playlist layout")
                    lines.insert(position, tag)
                original = folder / line
                encrypted = original.with_suffix(".encrypted")
                self.run([self.openssl, "enc", "-aes-128-cbc", "-e", "-nosalt",
                          "-K", keys[key_index].hex(), "-iv", iv.hex(), "-in", original,
                          "-out", encrypted])
                plaintext = original.read_bytes()
                if encrypted.stat().st_size != (len(plaintext) // 16 + 1) * 16:
                    raise AssertionError("AES fixture is not PKCS#7 padded")
                original.write_bytes(encrypted.read_bytes())
                encrypted.unlink()
                number += 1
            lines.append(line)
        path.write_text("\n".join(lines) + "\n")
        return sequence

    def cache(self, folder, cache, source):
        cache.mkdir()
        files = sorted(p for p in folder.rglob("*") if p.is_file())
        # Names and insertion order both disagree with source segment order.
        numbers = list(range(100, 100 + len(files)))
        random.Random(731).shuffle(numbers)
        entries = list(zip(files, numbers))
        random.Random(229).shuffle(entries)
        for original, number in entries:
            relative = original.relative_to(folder).as_posix()
            remote = urljoin(source, relative)
            if original.suffix==".m3u8":
                digest=hashlib.sha256((remote+"|0|-1").encode()).hexdigest()
                name=f"playlist-{digest}.txt"
            else:
                name=f"resource-{number}.ts"
            target = cache / name
            target.write_bytes(original.read_bytes())
            # Original Agent's playlist cache may have no URL sidecar.
            if original.suffix==".m3u8":continue
            # Binary Apple plist, not JSON or OpenStep text. Even keys/MAP/audio use exact URLs.
            metadata = {"responseURL": remote, "source": remote}
            with Path(str(target) + ".plist").open("wb") as stream:
                plistlib.dump(metadata, stream, fmt=plistlib.FMT_BINARY)
        return (folder / "index.m3u8").read_text()

    def closure(self, root, cache):
        """Audit the production result only; never construct a replacement playlist."""
        seen, leaves = set(), []

        def visit(path):
            path = path.resolve()
            path.relative_to(cache.resolve())
            if path in seen:
                return
            seen.add(path)
            text = path.read_text()
            if not text.startswith("#EXTM3U"):
                raise AssertionError(f"not a playlist: {path}")
            if "#EXTINF:" in text:
                leaves.append(text)
            for line in text.splitlines():
                uris = re.findall(r'URI="([^"\n]+)"', line) if line.startswith("#") else ([line] if line else [])
                for uri in uris:
                    parsed = urlsplit(uri)
                    if parsed.scheme or parsed.netloc or not re.fullmatch(r"[A-Za-z0-9_.-]+",uri):
                        raise AssertionError(f"Native resource must be an ASCII relative leaf: {uri}")
                    target = (path.parent / uri).resolve(strict=True)
                    target.relative_to(cache.resolve())
                    if target.suffix == ".m3u8":
                        visit(target)
                    if line.startswith("#EXT-X-KEY:") and target.stat().st_size != 16:
                        raise AssertionError("localized AES key is not exactly 16 bytes")
        visit(root)
        return leaves

    def remux(self, playlist, destination):
        # Explicit offline protocols: a missed HTTP rewrite cannot accidentally pass.
        self.ff("-protocol_whitelist", "file,crypto,data", "-allowed_extensions", "ALL",
                "-i", playlist, "-map", "0:v:0", "-map", "0:a:0", "-c", "copy",
                "-movflags", "+faststart", destination)

    def probe(self, movie, expected_duration):
        stdout, _ = self.run([self.ffprobe, "-v", "error", "-show_streams", "-show_format",
                              "-of", "json", movie])
        info = json.loads(stdout)
        video = [s for s in info["streams"] if s["codec_type"] == "video"]
        audio = [s for s in info["streams"] if s["codec_type"] == "audio"]
        if len(video) != 1 or len(audio) != 1:
            raise AssertionError(f"required exactly H264 + AAC tracks: {info}")
        if (video[0]["codec_name"], video[0]["width"], video[0]["height"]) != ("h264", 160, 96):
            raise AssertionError(f"wrong video codec/geometry: {video[0]}")
        if audio[0]["codec_name"] != "aac" or int(audio[0]["sample_rate"]) != 44100:
            raise AssertionError(f"wrong audio codec/sample rate: {audio[0]}")
        durations = [float(info["format"]["duration"])]
        durations.extend(float(s["duration"]) for s in video + audio)
        if any(not math.isfinite(d) or abs(d - expected_duration) > 0.35 for d in durations):
            raise AssertionError(f"duration mismatch: {durations}, expected {expected_duration}")
        # -xerror and err_detect explode make corrupt frames fatal instead of warnings.
        self.ff("-xerror", "-err_detect", "explode", "-i", movie, "-map", "0:v:0",
                "-map", "0:a:0", "-f", "null", "-")
        return info

    def video_hashes(self, movie):
        stdout, _ = self.ff("-xerror", "-i", movie, "-map", "0:v:0", "-an", "-threads", "1",
                            "-f", "framemd5", "-")
        hashes = [line.rsplit(",", 1)[-1].strip() for line in stdout.splitlines()
                  if line and not line.startswith("#")]
        if len(hashes) < 36:
            raise AssertionError(f"too few decoded video frames: {len(hashes)}")
        return hashes

    def case(self, name, mode=None, kind="ts", master=False, embedded=False):
        folder = self.root / f"{name} source"
        if master:
            folder.mkdir()
            self.generate(folder / "video", tracks="v")
            self.generate(folder / "audio", tracks="a")
            (folder / "index.m3u8").write_text(
                '#EXTM3U\n#EXT-X-VERSION:3\n'
                '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="sound",NAME="synthetic",DEFAULT=YES,'
                'AUTOSELECT=YES,URI="audio/index.m3u8"\n'
                '#EXT-X-STREAM-INF:BANDWIDTH=400000,RESOLUTION=160x96,'
                'CODECS="avc1.64000a,mp4a.40.2",AUDIO="sound"\nvideo/index.m3u8\n')
        else:
            self.generate(folder, kind=kind)
        original_leaves = [(p, p.read_text()) for p in sorted(folder.rglob("*.m3u8"))
                           if "#EXTINF:" in p.read_text()]
        video_leaf = folder / ("video/index.m3u8" if master else "index.m3u8")
        expected_duration = sum(extinf(video_leaf.read_text()))
        reference = self.root / f"{name} reference.mp4"
        self.remux(folder / "index.m3u8", reference)
        self.probe(reference, expected_duration)
        hashes = self.video_hashes(reference)
        audio_hash, _ = self.ff("-xerror", "-i", reference, "-map", "0:a:0", "-vn",
                                "-c:a", "pcm_s16le", "-f", "hash", "-hash", "sha256", "-")
        sequence = self.encrypt(folder, mode) if mode else 0
        # Match the cached source syntax seen on the device, not just colon tags.
        for leaf, _ in original_leaves:
            leaf.write_text(leaf.read_text().replace("#EXTM3U\n", "#EXTM3U\n#EXT-X-TOKEN=synthetic-cache-token\n", 1))
        # Refresh leaves after encryption so explicit IVs and KEY rotation are audited too.
        original_leaves = [p.read_text() for p, _ in original_leaves]
        cache = self.root / f"{name} scrambled cache"
        source = f"https://fixtures.invalid/hls/{name}/index.m3u8"
        root_text = self.cache(folder, cache, source)
        task = {"hlsSourceURL": source}
        if embedded:
            task["hlsPlaylistText"] = root_text
        # Cached-source cases force production's responseURL source-manifest lookup.
        task_path = self.root / f"{name} task.json"
        task_path.write_text(json.dumps(task, indent=2))
        output, stderr = self.run([self.cli, task_path, cache])
        report = json.loads(stderr.splitlines()[-1])
        if report["networkAttempts"] != 0:
            raise AssertionError("positive case attempted key networking")
        summary = report["summary"]
        expected_keys = 2 if mode == "rotation" else (1 if mode else 0)
        if (summary["trackCount"] != (2 if master else 1) or summary["keyCount"] != expected_keys
                or summary["segmentCount"] != sum(len(extinf(t)) for t in original_leaves)
                or abs(summary["expectedDuration"] - expected_duration) > 0.00001
                or (master and not summary["requireAudio"])):
            raise AssertionError(f"incorrect production summary: {summary}")
        localized = Path(output.strip()).resolve(strict=True)
        leaves = self.closure(localized, cache)
        # Compare real ordered EXTINF + sequence + key IVs, ignoring only rewritten URI values.
        def signature(text):
            return [re.sub(r'URI="[^"]+"', 'URI="<localized>"', line)
                    for line in text.splitlines()
                    if line.startswith(("#EXTINF:", "#EXT-X-MEDIA-SEQUENCE:", "#EXT-X-KEY:", "#EXT-X-MAP:"))]
        if sorted(signature(t) for t in leaves) != sorted(signature(t) for t in original_leaves):
            raise AssertionError("production changed EXTINF order, MEDIA-SEQUENCE, KEY/IV or MAP semantics")
        destination = self.root / f"{name} localized.mp4"
        self.remux(localized, destination)
        info = self.probe(destination, expected_duration)
        actual_hashes = self.video_hashes(destination)
        if actual_hashes != hashes:
            raise AssertionError("decoded video differs from plaintext reference (order/loss/decryption)")
        actual_audio_hash, _ = self.ff("-xerror", "-i", destination, "-map", "0:a:0", "-vn",
                                       "-c:a", "pcm_s16le", "-f", "hash", "-hash", "sha256", "-")
        if not audio_hash.startswith("SHA256=") or actual_audio_hash != audio_hash:
            raise AssertionError("decoded audio differs from plaintext reference (selection/order/loss)")
        result = {"case": name, "status": "PASS", "summary": summary,
                  "mediaSequence": sequence, "videoFrames": len(hashes),
                  "mp4Duration": float(info["format"]["duration"]), "audioRequired": True,
                  "inputMode": "embedded-source-text" if embedded else "cached-responseURL-source"}
        self.results.append(result)
        print(f"PASS {name}: H264/AAC 160x96, {len(hashes)} frames, full decode", flush=True)


def extinf(text):
    return [float(value) for value in re.findall(r"^#EXTINF:([^,\n]+)", text, re.MULTILINE)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", type=Path, required=True)
    parser.add_argument("--work-dir", type=Path, required=True, help="retained artifacts; must contain a space")
    parser.add_argument("--ffmpeg", default=os.environ.get("FFMPEG", "ffmpeg"))
    parser.add_argument("--ffprobe", default=os.environ.get("FFPROBE", "ffprobe"))
    parser.add_argument("--openssl", default=os.environ.get("OPENSSL", "openssl"))
    args = parser.parse_args()
    for binary in (args.ffmpeg, args.ffprobe, args.openssl):
        if not shutil.which(binary):
            parser.error(f"required executable missing: {binary}")
    regression = Regression(args)
    try:
        regression.run([args.ffmpeg, "-version"])
        regression.run([args.ffprobe, "-version"])
        regression.run([args.openssl, "version"])
        regression.case("plain-ts")
        regression.case("aes-implicit-nonzero-sequence", mode="implicit")
        regression.case("aes-explicit-iv", mode="explicit", embedded=True)
        regression.case("aes-key-rotation", mode="rotation")
        regression.case("fmp4-map", kind="fmp4", embedded=True)
        regression.case("master-independent-audio", master=True)
    except Exception as exc:
        (regression.root / "result.json").write_text(json.dumps(
            {"status": "FAIL", "error": str(exc), "completed": regression.results}, indent=2))
        print(f"FAIL: {exc}\nArtifacts retained: {regression.root}", file=sys.stderr)
        return 1
    (regression.root / "result.json").write_text(json.dumps(
        {"status": "PASS", "scope": "production localizer + host ffmpeg; NOT iOS libav", "cases": regression.results}, indent=2))
    print(f"PASS 6 production-localizer host-media cases; artifacts: {regression.root}")
    print("NOT evidence of original iOS libav remux success.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
