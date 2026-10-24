#!/usr/bin/env python3
"""Rebuild brand outputs from inputs only and compare with tracked baselines."""
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
BRAND = Path('assets/brand')
DESIGN = BRAND / 'iphone-use-final'
RUNNER_ICON = 'Runner/Assets.xcassets/AppIcon.appiconset/AppIcon.png'
TOOLS = ('build.py', 'render.cjs', 'verify.py', 'export-brand-assets.cjs')
INPUTS = {str(DESIGN / name) for name in (
    'geometry.json', 'reference/approved-mark.svg', 'reference/approved-wordmark.svg',
    'reference/geist-OFL.txt')}
LOCAL_OUTPUTS = {str(DESIGN / name) for name in (
    'mark.png', 'inverse.png', 'wordmark.png', 'wordmark-inverse.png', 'preview.png',
    'construction.png', 'mark-16.png', 'mark-24.png', 'mark-32.png', 'mark-48.png',
    'mark-64.png', 'size-check.png', 'validation.json')}


def relative_name(name):
    path = PurePosixPath(name)
    if not name or path.is_absolute() or '..' in path.parts or path.as_posix() != name or name == '.':
        raise ValueError(f'Invalid manifest path: {name}')
    return name


def declared_outputs(root):
    production = json.loads((root / BRAND / 'manifest.json').read_text())
    design = json.loads((root / DESIGN / 'manifest.json').read_text())
    if production['app_icon']['path'] != RUNNER_ICON:
        raise ValueError('Unexpected Runner icon path')
    names = [str(BRAND / relative_name(item['path'])) for item in production['files']]
    names += [str(DESIGN / relative_name(name)) for name in design['svg_sha256']]
    names += [str(BRAND / 'manifest.json'), str(DESIGN / 'manifest.json'),
              str(DESIGN / 'resolved-geometry.json'), RUNNER_ICON]
    outputs = set(names)
    if len(outputs) != len(names) or outputs & (INPUTS | LOCAL_OUTPUTS):
        raise ValueError('Duplicate or overlapping manifest outputs')
    return outputs


def check(root=ROOT):
    names = subprocess.check_output(
        ['git', 'ls-files', '-z', '--', str(BRAND), RUNNER_ICON], cwd=root
    ).decode().split('\0')
    tracked = {name for name in names if name}
    outputs = declared_outputs(root)
    required = INPUTS | outputs
    missing = required - tracked
    unexpected = tracked - required - {name for name in tracked if name.endswith('.md')}
    if missing or unexpected:
        raise ValueError(f'Brand inventory differs from Git tracking: missing={sorted(missing)}, '
                         f'undeclared={sorted(unexpected)}')
    # Keep baselines outside the generation workspace. Never seed it with old outputs.
    baseline = {name: (root / name).read_bytes() for name in required}
    with tempfile.TemporaryDirectory(prefix='iphone-use-brand-check-') as temporary:
        staging = Path(temporary)
        for name in INPUTS:
            target = staging / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(baseline[name])
        for name in outputs:
            (staging / name).parent.mkdir(parents=True, exist_ok=True)
        tools = staging / 'scripts/brand'
        tools.mkdir(parents=True)
        for name in TOOLS:
            shutil.copyfile(root / 'scripts/brand' / name, tools / name)
        environment = {**os.environ, 'NODE_PATH': str(root / 'scripts/brand/node_modules')}
        for executable, name in ((sys.executable, 'build.py'), ('node', 'render.cjs'),
                                 (sys.executable, 'verify.py'), ('node', 'export-brand-assets.cjs')):
            subprocess.run([executable, str(tools / name)], cwd=staging, env=environment, check=True)
        actual = {path.relative_to(staging).as_posix() for path in staging.rglob('*') if path.is_file()}
        expected = required | LOCAL_OUTPUTS | {f'scripts/brand/{name}' for name in TOOLS}
        if actual != expected:
            raise ValueError(f'Generated file inventory differs: missing={sorted(expected - actual)}, '
                             f'undeclared={sorted(actual - expected)}')
        report = json.loads((staging / DESIGN / 'validation.json').read_text())
        if report['visual_review'] != 'not performed':
            raise ValueError('Automated verification must not claim a manual visual review')
        changed = [name for name, data in baseline.items() if (staging / name).read_bytes() != data]
        if changed:
            raise ValueError('Brand rebuild differs from tracked assets:\n' + '\n'.join(sorted(changed)))
    print(f'Brand rebuild passed ({len(outputs)} outputs regenerated; {len(INPUTS)} inputs unchanged; '
          'manual review not performed).')


if __name__ == '__main__':
    check()
