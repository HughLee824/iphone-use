#!/usr/bin/env python3
"""Preflight and verify dsh-iphone-use; publication belongs to GitHub Actions."""
import argparse
import json
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = 'dsh-iphone-use'
REGISTRY = 'https://registry.npmjs.org'


def validate(version, manifest):
    if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', version):
        raise ValueError('Choose a stable numeric version without a v prefix.')
    if manifest['name'] != PACKAGE or manifest['version'] != version:
        raise ValueError('Requested version must match the repository Harness package.')


def require_unpublished(version, fetch=urllib.request.urlopen):
    try:
        with fetch(f'{REGISTRY}/{PACKAGE}/{version}', timeout=30):
            pass
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return
        raise
    raise ValueError('Version already exists. Use verify-only; never republish it.')


def verify_metadata(expected, actual):
    if expected['name'] != PACKAGE or actual.get('name') != PACKAGE or actual.get('version') != expected['version']:
        raise ValueError('Registry package identity differs from the publication archive.')
    if actual.get('dist', {}).get('integrity') != expected['integrity']:
        raise ValueError('Registry integrity differs from the publication archive.')


def install(command, attempts=16, run=subprocess.run, sleep=time.sleep):
    for attempt in range(attempts):
        result = run(command, capture_output=True, text=True, timeout=120)
        if result.returncode == 0:
            return
        diagnostic = result.stderr or result.stdout
        print(diagnostic, file=sys.stderr, flush=True)
        if attempt == attempts - 1 or not re.search(r'^npm (?:error|ERR!) code (?:ETARGET|E404)\s*$', diagnostic, re.MULTILINE):
            result.check_returncode()
        sleep(20)


def verify(pack_metadata):
    expected = json.loads(Path(pack_metadata).read_text())[0]
    validate(expected['version'], expected)
    for attempt in range(31):
        try:
            with urllib.request.urlopen(f'{REGISTRY}/{PACKAGE}/{expected["version"]}', timeout=30) as response:
                actual = json.load(response)
            break
        except urllib.error.HTTPError as error:
            if error.code != 404 or attempt == 30:
                raise
            print('npm is still processing the package; waiting 20 seconds.', flush=True)
            time.sleep(20)
    verify_metadata(expected, actual)
    with tempfile.TemporaryDirectory(prefix='iu-dsh-public-') as temporary:
        root = Path(temporary)
        prefix = ['npm', '--registry=' + REGISTRY, '--cache', str(root / 'cache'),
                  '--prefix', str(root / 'install'), '--ignore-scripts', '--no-audit',
                  '--no-fund', '--no-package-lock', '--prefer-online']
        install(prefix + ['install', f'{PACKAGE}@{expected["version"]}'])
        installed = root / 'install/node_modules' / PACKAGE
        subprocess.run(['node', str(ROOT / 'scripts/check-dsh-package.mjs'), str(installed)], check=True)
        subprocess.run(prefix + ['uninstall', PACKAGE], check=True)
        if installed.exists():
            raise ValueError('Package remained after npm uninstall.')
        print('Public archive integrity, fresh-cache npm installation and removal passed.', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    check = commands.add_parser('check')
    check.add_argument('version')
    check.add_argument('--verify-only', action='store_true')
    verification = commands.add_parser('verify')
    verification.add_argument('pack_metadata', type=Path)
    args = parser.parse_args()
    if args.command == 'check':
        validate(args.version, json.loads((ROOT / 'package.json').read_text()))
        if not args.verify_only:
            require_unpublished(args.version)
    else:
        verify(args.pack_metadata)
