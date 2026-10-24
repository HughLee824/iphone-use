#!/usr/bin/env python3
"""Update the shared plugin/portable-skill version and regenerate distribution files."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
MANIFESTS = (
    'plugins/iphone-use/.codex-plugin/plugin.json',
    'plugins/iphone-use/.claude-plugin/plugin.json',
    'plugins/iphone-use/package.json',
    'packages/iphone-use-skill/package.json',
)
WORKFLOW = re.compile(r'Workflow version: \*\*((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))\*\*')
VERSION = re.compile(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)')


def planned_updates(root, version):
    if not VERSION.fullmatch(version):
        raise ValueError('Use a stable X.Y.Z version without v or leading zeroes')
    updates = {}
    current = set()
    for name in MANIFESTS:
        path = root / name
        text = path.read_text()
        old = json.loads(text)['version']
        if not VERSION.fullmatch(old):
            raise ValueError(f'Invalid existing version in {name}')
        current.add(old)
        # Preserve each manifest's established formatting.
        replacement, count = re.subn(r'("version"\s*:\s*")[^"]+(")',
                                    lambda match: match[1] + version + match[2], text, count=1)
        if count != 1:
            raise ValueError(f'Missing version in {name}')
        updates[path] = replacement
    skill = root / 'skills/iphone-use/SKILL.md'
    text = skill.read_text()
    matches = WORKFLOW.findall(text)
    if len(matches) != 1:
        raise ValueError('Expected one canonical workflow version')
    current.add(matches[0])
    if len(current) != 1:
        raise ValueError('Existing versions differ; resolve the drift before updating')
    old = current.pop()
    if tuple(map(int, version.split('.'))) < tuple(map(int, old.split('.'))):
        raise ValueError('Version must not decrease')
    updates[skill] = WORKFLOW.sub(f'Workflow version: **{version}**', text)
    return updates


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('version')
    args = parser.parse_args()
    try:
        updates = planned_updates(ROOT, args.version)
    except ValueError as error:
        parser.exit(1, f'{error}\n')
    # Validate every source before writing any file; changes remain reviewable in Git.
    for path, content in updates.items():
        path.write_text(content)
    subprocess.run([sys.executable, str(ROOT / 'scripts/sync-plugin.py')], check=True, cwd=ROOT)
    print(f'Updated plugin/skill source to {args.version}; nothing was published.')


if __name__ == '__main__':
    main()
