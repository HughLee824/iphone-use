#!/usr/bin/env python3
"""Rebuild and compare tracked brand assets in isolation, without changing the checkout."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
BRAND = Path('assets/brand')
RUNNER_ICON = 'Runner/Assets.xcassets/AppIcon.appiconset/AppIcon.png'
TOOLS = ('build.py', 'render.cjs', 'verify.py', 'export-brand-assets.cjs')


def check(root=ROOT):
    names = subprocess.check_output(
        ['git', 'ls-files', '-z', '--', str(BRAND), RUNNER_ICON], cwd=root
    ).decode().split('\0')
    expected = {name: (root / name).read_bytes() for name in names if name}
    if RUNNER_ICON not in expected or str(BRAND / 'manifest.json') not in expected:
        raise ValueError('Tracked brand assets and Runner icon are required')
    with tempfile.TemporaryDirectory(prefix='iphone-use-brand-check-') as temporary:
        staging = Path(temporary)
        # Only public inputs and these tools are copied; no local renders, caches or Apple artwork.
        for name, data in expected.items():
            target = staging / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        tools = staging / 'scripts/brand'
        tools.mkdir(parents=True)
        for name in TOOLS:
            shutil.copyfile(root / 'scripts/brand' / name, tools / name)
        environment = {**os.environ, 'NODE_PATH': str(root / 'scripts/brand/node_modules')}
        for executable, name in ((sys.executable, 'build.py'), ('node', 'render.cjs'),
                                 (sys.executable, 'verify.py'), ('node', 'export-brand-assets.cjs')):
            subprocess.run([executable, str(tools / name)], cwd=staging, env=environment, check=True)
        report = json.loads((staging / BRAND / 'iphone-use-final/validation.json').read_text())
        if report['visual_review'] != 'not performed':
            raise ValueError('Automated verification must not claim a manual visual review')
        changed = [name for name, data in expected.items()
                   if not (staging / name).is_file() or (staging / name).read_bytes() != data]
        if changed:
            raise ValueError('Brand rebuild differs from tracked assets:\n' + '\n'.join(changed))
    print(f'Brand rebuild passed ({len(expected)} tracked files unchanged; manual review not performed).')


if __name__ == '__main__':
    check()
