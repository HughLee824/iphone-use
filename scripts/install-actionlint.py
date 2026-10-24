#!/usr/bin/env python3
"""Install the checksum-pinned official Actionlint release into this checkout."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def platform_key():
    machine = {'aarch64': 'arm64', 'x86_64': 'amd64'}.get(platform.machine(), platform.machine())
    return f'{platform.system().lower()}_{machine}'


def extract(archive, destination, checksum):
    if hashlib.sha256(archive.read_bytes()).hexdigest() != checksum:
        raise ValueError('Actionlint archive checksum mismatch')
    with tarfile.open(archive, 'r:gz') as bundle:
        for name in ('actionlint', 'LICENSE.txt'):
            entries = [member for member in bundle.getmembers() if member.name == name]
            if len(entries) != 1 or not entries[0].isfile():
                raise ValueError(f'Expected one regular {name} file')
            # Never use archive-controlled output paths, links or permissions.
            (destination / name).write_bytes(bundle.extractfile(entries[0]).read())
    (destination / 'actionlint').chmod(0o755)


def version_of(binary):
    return subprocess.check_output([str(binary), '-version'], text=True).splitlines()[0].strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, help='Use a downloaded archive; checksum verification is still required')
    args = parser.parse_args()
    pin = json.loads((ROOT / 'scripts/actionlint.json').read_text())
    key = platform_key()
    if key not in pin['sha256']:
        raise ValueError(f'Unsupported Actionlint platform: {key}')
    version, checksum = pin['version'], pin['sha256'][key]
    directory = ROOT / '.build/tools' / f'actionlint-{version}'
    if args.archive and hashlib.sha256(args.archive.read_bytes()).hexdigest() != checksum:
        raise ValueError('Actionlint archive checksum mismatch')
    if directory.exists():
        if version_of(directory / 'actionlint') != version:
            raise ValueError(f'Invalid cached Actionlint at {directory}; remove it explicitly and install again')
        print(directory / 'actionlint')
        return
    directory.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='actionlint-', dir=directory.parent) as temporary:
        staging = Path(temporary)
        archive = args.archive
        if archive is None:
            archive = staging / 'download.tar.gz'
            url = f'https://github.com/rhysd/actionlint/releases/download/v{version}/actionlint_{version}_{key}.tar.gz'
            subprocess.run([
                '/usr/bin/curl', '--fail', '--location', '--proto', '=https', '--proto-redir', '=https',
                '--connect-timeout', '15', '--max-time', '120', '--retry', '2', '--output', str(archive), url,
            ], check=True)
        payload = staging / 'payload'
        payload.mkdir()
        extract(archive, payload, checksum)
        if version_of(payload / 'actionlint') != version:
            raise ValueError('Actionlint binary version does not match the pin')
        payload.rename(directory)
    print(directory / 'actionlint')


if __name__ == '__main__':
    main()
