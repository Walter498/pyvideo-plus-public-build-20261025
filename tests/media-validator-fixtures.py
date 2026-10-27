#!/usr/bin/env python3
"""Generate original, public synthetic H.264/AAC samples (CC0, no downloads)."""
import argparse
from pathlib import Path
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="fixture directory (created if absent)")
    parser.add_argument("--ffmpeg", default="ffmpeg", help="FFmpeg with lavfi, libx264, AAC")
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)

    def ffmpeg(*options):
        subprocess.run([args.ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
                        *options], check=True)

    video = ["-f", "lavfi", "-i", "testsrc2=size=160x96:rate=12:duration=4"]
    audio = ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=4"]
    vcodec = ["-c:v", "libx264", "-threads", "1", "-pix_fmt", "yuv420p", "-g", "12"]
    ffmpeg(*video, *audio, *vcodec, "-c:a", "aac", "-b:a", "64k", "-movflags", "+faststart",
           str(out / "valid.mp4"))
    ffmpeg(*video, *vcodec, "-an", "-movflags", "+faststart", str(out / "video-only.mp4"))
    ffmpeg(*audio, "-c:a", "aac", "-b:a", "64k", str(out / "audio-only.mp4"))
    # Delayed AAC demonstrates that readability must not require a sample at PTS 0.
    ffmpeg(*video, "-itsoffset", "0.25", *audio, *vcodec, "-c:a", "aac", "-b:a", "64k",
           "-movflags", "+faststart", str(out / "delayed-audio.mp4"))
    data = (out / "valid.mp4").read_bytes()
    (out / "truncated.mp4").write_bytes(data[:512])
    # Keep the faststart moov and initial mdat; metadata alone must not suffice.
    (out / "truncated-tail.mp4").write_bytes(data[:len(data) // 2])
    (out / "empty.mp4").write_bytes(b"")
    (out / "not-media.mp4").write_text("not an MP4\n")
    link = out / "symlink.mp4"
    if link.is_symlink() or link.exists():
        link.unlink()
    link.symlink_to("valid.mp4")
    print(f"Generated CC0 fixtures at {out}; ffmpeg={shutil.which(args.ffmpeg)}")


if __name__ == "__main__":
    main()
