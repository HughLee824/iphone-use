#!/usr/bin/env python3
"""Read-only release preflight; publication itself belongs to GitHub Actions."""
import argparse
import json
import re
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
REGISTRY = 'https://registry.npmjs.org'


def validate(version, manifest):
    if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', version):
        raise ValueError('Choose a stable numeric version without a v prefix.')
    if manifest['name'] != 'iphone-use-skill' or manifest['version'] != version:
        raise ValueError('Requested version must match the portable package on this commit.')


def require_unpublished(version, fetch=urllib.request.urlopen):
    try:
        with fetch(f'{REGISTRY}/iphone-use-skill/{version}', timeout=30):
            pass
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return
        raise
    raise ValueError('Version already exists. Verify that release separately; never overwrite or republish it.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('version')
    parser.add_argument('--verify-only', action='store_true', help='Validate an existing version for read-only publication recovery')
    args = parser.parse_args()
    version = args.version
    validate(version, json.loads((ROOT / 'packages/iphone-use-skill/package.json').read_text()))
    if not args.verify_only:
        require_unpublished(version)
