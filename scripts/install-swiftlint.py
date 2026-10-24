#!/usr/bin/env python3
"""Install the checksum-pinned official SwiftLint binary into the checkout."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def extract(archive, destination, checksum):
    if hashlib.sha256(archive.read_bytes()).hexdigest() != checksum:
        raise ValueError('SwiftLint archive checksum mismatch')
    with zipfile.ZipFile(archive) as bundle:
        if sorted(bundle.namelist()) != ['LICENSE', 'swiftlint']:
            raise ValueError('Unexpected SwiftLint archive layout')
        # Fixed destinations; no archive-controlled paths or symlinks.
        for name in ['swiftlint', 'LICENSE']:
            (destination / name).write_bytes(bundle.read(name))
    (destination / 'swiftlint').chmod(0o755)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, help='Use an already downloaded archive; still verify its checksum')
    args = parser.parse_args()
    pin = json.loads((ROOT / 'scripts/swiftlint.json').read_text())
    version = pin['version']
    directory = ROOT / '.build/tools' / f'swiftlint-{version}'
    if args.archive and hashlib.sha256(args.archive.read_bytes()).hexdigest() != pin['sha256']:
        raise ValueError('SwiftLint archive checksum mismatch')
    if directory.exists():
        installed = subprocess.check_output([str(directory / 'swiftlint'), 'version'], text=True).strip()
        if installed != version:
            raise ValueError(f'Invalid cached SwiftLint at {directory}; remove it explicitly and install again')
        print(directory / 'swiftlint')
        return
    directory.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='swiftlint-', dir=directory.parent) as temporary:
        staging = Path(temporary)
        archive = args.archive
        if archive is None:
            archive = staging / 'download.zip'
            url = f'https://github.com/realm/SwiftLint/releases/download/{version}/portable_swiftlint.zip'
            # Use macOS's system trust store, independent of Python's CA setup.
            subprocess.run([
                "/usr/bin/curl", "--fail", "--location", "--proto", "=https",
                "--proto-redir", "=https", "--connect-timeout", "15", "--max-time", "120",
                "--retry", "2", "--output", str(archive), url,
            ], check=True)
        payload = staging / 'payload'
        payload.mkdir()
        extract(archive, payload, pin['sha256'])
        actual = subprocess.check_output([str(payload / 'swiftlint'), 'version'], text=True).strip()
        if actual != version:
            raise ValueError(f'Expected SwiftLint {version}, got {actual}')
        payload.rename(directory)
    print(directory / 'swiftlint')


if __name__ == '__main__':
    main()
