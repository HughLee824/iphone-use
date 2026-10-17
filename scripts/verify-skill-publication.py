#!/usr/bin/env python3
"""Verify an accepted npm publication without publishing or changing dist-tags."""
import argparse
import json
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path


def verify_metadata(expected, actual):
    if actual.get('name') != 'iphone-use-skill' or actual.get('version') != expected['version']:
        raise ValueError('Registry package identity differs from the publication archive.')
    if actual.get('dist', {}).get('integrity') != expected['integrity']:
        raise ValueError('Registry integrity differs from the publication archive.')


def verify(pack_metadata, attempts=31, fetch=urllib.request.urlopen, sleep=time.sleep):
    expected = json.loads(Path(pack_metadata).read_text())[0]
    if expected['name'] != 'iphone-use-skill':
        raise ValueError('Expected the portable skill package, not a client plugin.')
    for attempt in range(attempts):
        try:
            with fetch(f'https://registry.npmjs.org/iphone-use-skill/{expected["version"]}', timeout=30) as response:
                actual = json.load(response)
            break
        except urllib.error.HTTPError as error:
            if error.code != 404 or attempt == attempts - 1:
                raise
            print('npm is still processing the accepted package; waiting before verification.', flush=True)
            sleep(20)
    verify_metadata(expected, actual)
    # Isolated cache proves these commands fetch the public version, not the
    # archive used in pre-publication tests. Do not alter the user's home.
    with tempfile.TemporaryDirectory(prefix='iu-public-') as temporary:
        root = Path(temporary)
        prefix = ['npx', '--yes', '--ignore-scripts', '--registry=https://registry.npmjs.org',
                  '--cache', str(root / 'npm-cache'), f'iphone-use-skill@{expected["version"]}']
        for agent in ['cursor', 'opencode']:
            project = root / agent
            project.mkdir()
            for command, field, value in [('install', 'result', 'installed'),
                                           ('install', 'result', 'already-installed'),
                                           ('check', 'state', 'managed'),
                                           ('uninstall', 'result', 'uninstalled'),
                                           ('check', 'state', 'absent')]:
                result = subprocess.run(prefix + [command, '--agent', agent, '--project', str(project)],
                                        check=True, capture_output=True, text=True, timeout=120)
                report = json.loads(result.stdout)
                if report.get(field) != value or report.get('conflicts', []):
                    raise ValueError(f'Unexpected public {agent} {command} result: {report}')
                print(f'{agent} {command}: {value}', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('pack_metadata', type=Path)
    verify(parser.parse_args().pack_metadata)
