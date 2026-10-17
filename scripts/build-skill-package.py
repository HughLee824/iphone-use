#!/usr/bin/env python3
"""Stage the npx installer and the canonical skill as a self-contained npm package."""
import argparse
import json
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def build(output):
    # Never clean a caller-supplied directory. A fresh destination is required.
    output.mkdir(parents=True, exist_ok=False)
    source = ROOT / 'packages/iphone-use-skill'
    manifest = json.loads((source / 'package.json').read_text())
    skill = ROOT / 'skills/iphone-use'
    if f'Workflow version: **{manifest["version"]}**' not in (skill / 'SKILL.md').read_text():
        raise ValueError('Installer and canonical skill versions differ')
    for path in [*source.rglob('*'), *skill.rglob('*')]:
        if path.is_symlink():
            raise ValueError(f'Refusing symlink in package: {path}')
    for name in ['package.json', 'README.md']:
        shutil.copy2(source / name, output / name)
    shutil.copytree(source / 'bin', output / 'bin')
    shutil.copytree(skill, output / 'skills/iphone-use')
    shutil.copy2(ROOT / 'LICENSE', output / 'LICENSE')
    print(output.resolve())


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path, help='New staging directory')
    build(parser.parse_args().output)
