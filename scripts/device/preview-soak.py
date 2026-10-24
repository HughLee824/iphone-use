#!/usr/bin/env python3
"""Read-only preview soak probe; does not renew or control the device session."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url', required=True)
    parser.add_argument('--pid', type=int, required=True, help='Session host PID returned by connect')
    parser.add_argument('--seconds', type=float, default=1800)
    parser.add_argument('--interval', type=float, default=2)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    url = urllib.parse.urlparse(args.url)
    if (url.scheme != 'http' or url.hostname != '127.0.0.1' or not url.port
            or url.username or url.password or url.query or url.fragment or not url.path.endswith('/')):
        parser.error('Use the exact loopback URL returned by preview --no-open')
    if args.pid <= 0 or args.seconds <= 0 or args.interval < 0.1:
        parser.error('Use a positive PID/duration and interval >= 0.1s')
    args.output.mkdir(parents=True, exist_ok=True, mode=0o700)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    start = time.monotonic()
    count = 0
    failures = 0
    latest = None
    with (args.output / 'samples.jsonl').open('w') as log:
        while time.monotonic() - start < args.seconds:
            tick = time.monotonic()
            row = {'elapsedSeconds': tick - start, 'wallTime': time.time()}
            try:
                with opener.open(args.url + 'state', timeout=3) as response:
                    row['preview'] = json.load(response)
                with opener.open(args.url + 'frame', timeout=3) as response:
                    data = response.read(4 * 1024 * 1024)
                    if response.headers.get_content_type() != 'image/jpeg' or not data.startswith(b'\xff\xd8'):
                        raise ValueError('Expected a JPEG frame')
                row['frameSHA256'] = hashlib.sha256(data).hexdigest()
                row['frameBytes'] = len(data)
                if count == 0:
                    (args.output / 'first.jpg').write_bytes(data)
                latest = data
                row['hostProcess'] = subprocess.check_output(
                    ['ps', '-p', str(args.pid), '-o', 'pid=,rss=,%cpu=,etime='], text=True).strip()
            except (OSError, ValueError, subprocess.SubprocessError) as error:
                failures += 1
                row['error'] = str(error)
            row['probeSeconds'] = time.monotonic() - tick
            log.write(json.dumps(row) + '\n')
            log.flush()
            count += 1
            time.sleep(max(0, min(args.interval - (time.monotonic() - tick), args.seconds - (time.monotonic() - start))))
    if latest is not None:
        (args.output / 'last.jpg').write_bytes(latest)
    summary = {'elapsedSeconds': time.monotonic() - start, 'samples': count, 'failedSamples': failures,
               'note': 'Frame age is host decode age, not glass-to-glass latency. Static frames are valid display holds.'}
    (args.output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary))


if __name__ == '__main__':
    main()
