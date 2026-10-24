#!/usr/bin/env python3
"""Validate a PR title without executing or interpolating user-supplied text."""
import argparse
import json
from pathlib import Path
import re

PATTERN = re.compile(r"(?:feat|fix|refactor|perf|docs|test|build|ci|chore|style)(?:\([a-z][a-z0-9-]*\))?!?: [A-Za-z][^\r\n]*")


def validate(title):
    if len(title) > 72 or not PATTERN.fullmatch(title) or title != title.rstrip() or title.endswith('.'):
        raise ValueError('Use type(scope)!: English summary, at most 72 characters, with no trailing period. Scope and ! are optional.')
    summary = title.split(': ', 1)[1]
    if summary.lower() in {'update', 'fix', 'fix bug', 'changes', 'wip'}:
        raise ValueError('Describe the specific behavior changed, not a generic update.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('title', nargs='?')
    source.add_argument('--event', type=Path, help='GitHub event JSON; non-PR events are skipped')
    args = parser.parse_args()
    title = args.title
    if args.event:
        event = json.loads(args.event.read_text())
        if 'pull_request' not in event:
            print('No pull request in this event; title check skipped.')
            return
        title = event['pull_request']['title']
    try:
        validate(title)
    except ValueError as error:
        parser.exit(1, f'{error}\n')
    print('PR title passed.')


if __name__ == '__main__':
    main()
