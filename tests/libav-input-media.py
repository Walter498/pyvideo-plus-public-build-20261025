#!/usr/bin/env python3
"""Offline synthetic AAC/H264 fixtures; execute actual production Foundation binary.

A host decode is not evidence of original iOS Agent success. All cases execute
in separate processes: the production implementation has process-global DTS.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--cli', type=Path, required=True)
    parser.add_argument('--work-dir', type=Path, required=True)
    args = parser.parse_args()
    work = args.work_dir.resolve()
    work.mkdir(parents=True, exist_ok=True)
    serial = 0

    def run(argv, required=True):
        nonlocal serial
        serial += 1
        stem = work / f'command-{serial:03d}'
        stem.with_suffix('.json').write_text(json.dumps([str(x) for x in argv], indent=2))
        result = subprocess.run([str(x) for x in argv], capture_output=True, timeout=120)
        stem.with_suffix('.stdout').write_bytes(result.stdout)
        stem.with_suffix('.stderr').write_bytes(result.stderr)
        if required and result.returncode:
            raise RuntimeError(f'{argv[0]} exit {result.returncode}: {result.stderr.decode(errors="replace")}')
        return result

    def ff(*argv):
        return run(['ffmpeg', '-nostdin', '-hide_banner', '-loglevel', 'error', '-y', *argv])

    def probe(path):
        return json.loads(run(['ffprobe', '-v', 'error', '-show_streams', '-show_format', '-of', 'json', path]).stdout)

    fixture = work / 'real AAC fixtures'
    fixture.mkdir(exist_ok=True)
    ff('-f', 'lavfi', '-i', 'testsrc2=size=160x96:rate=12', '-f', 'lavfi', '-i',
       'sine=frequency=440:sample_rate=44100', '-t', '2', '-c:v', 'libx264',
       '-threads', '1', '-g', '12', '-keyint_min', '12', '-sc_threshold', '0',
       '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-b:a', '64k', '-f', 'segment',
       '-segment_time', '1', '-reset_timestamps', '0', fixture / 'part-%02d.ts')
    for index, name in enumerate(('a', 'b')):
        path = fixture / f'{name}.ts'
        path.write_bytes((fixture / f'part-{index:02d}.ts').read_bytes())
        streams = probe(path)['streams']
        assert any(s['codec_name'] == 'aac' for s in streams), 'real AAC required in each TS'
        assert any(s['codec_name'] == 'h264' for s in streams), 'real H264 required'
        run(['openssl', 'enc', '-aes-128-cbc', '-nosalt', '-K', '30313233343536373839616263646566',
             '-iv', '00000000000000000000000000000001', '-in', path, '-out', fixture / f'{name}.enc'])
    reference = work / 'reference.ts'
    reference.write_bytes((fixture / 'a.ts').read_bytes() + (fixture / 'b.ts').read_bytes())

    def decoded(path):
        # Compare all decoded video AND PCM audio, not just existence/duration.
        values = []
        for mapping in ('0:v:0', '0:a:0'):
            fmt = 'rawvideo' if ':v:' in mapping else 's16le'
            result = ff('-xerror', '-err_detect', 'explode', '-i', path, '-map', mapping,
                        '-threads', '1', '-f', fmt, '-')
            assert result.stdout, 'decoded stream must be nonempty'
            values.append(hashlib.sha256(result.stdout).hexdigest())
        return values

    reference_hashes = decoded(reference)
    results = []
    for case in ('plain', 'encrypted', 'map', 'range', 'discontinuity', 'cleanup',
                 'missing', 'retry-missing', 'retry-corrupt', 'cancel-before', 'cancel-during'):
        output = work / f'{case}-production.ts'
        result = run([args.cli.resolve(), fixture, case, output], required=False)
        entry = {'case': case, 'returncode': result.returncode, 'pass': result.returncode == 0}
        if output.exists():
            try:
                info = probe(output)
                assert any(s['codec_name'] == 'aac' for s in info['streams'])
                assert decoded(output) == reference_hashes, 'production concat dropped/changed decoded media'
                entry['media_decode'] = 'PASS H264 frames + AAC PCM equal reference'
            except Exception as error:
                entry['pass'] = False
                entry['media_decode'] = str(error)
        results.append(entry)
        print(json.dumps(entry), flush=True)
    (work / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    raise SystemExit(0 if all(r['pass'] for r in results) else 1)


if __name__ == '__main__':
    main()
