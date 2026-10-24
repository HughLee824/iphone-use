#!/usr/bin/env python3
"""Check local links in public repository Markdown; no network or dependencies."""
import html
from pathlib import Path
import re
import subprocess
import sys
import unicodedata
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]


def prose(text):
    """Ignore fenced examples and inline code, retaining line numbers."""
    output = []
    fence = None
    for line in text.splitlines():
        match = re.match(r"^ {0,3}(`{3,}|~{3,})", line)
        if match:
            marker = match.group(1)
            if fence is None:
                fence = marker
            elif marker[0] == fence[0] and len(marker) >= len(fence):
                fence = None
            output.append("")
        elif fence:
            output.append("")
        else:
            output.append(re.sub(r"(`+)(.*?)\1", lambda m: " " * len(m[0]), line))
    return "\n".join(output)


def anchors(text):
    # Keep inline-code contents in headings (GitHub includes them in slugs).
    text = re.sub(r"`([^`\n]+)`", r"\1", text)
    text = prose(text)
    result = set(re.findall(r'\b(?:id|name)=["\']([^"\']+)["\']', text))
    for match in re.finditer(r"^ {0,3}#{1,6}\s+(.+?)\s*#*\s*$", text, re.M):
        heading = html.unescape(re.sub(r"<[^>]+>", "", match[1])).lower()
        slug = "".join(c for c in heading if c in "-_ " or not unicodedata.category(c).startswith(("P", "S"))).replace(" ", "-")
        candidate = slug
        suffix = 0
        while candidate in result:
            suffix += 1
            candidate = f"{slug}-{suffix}"
        result.add(candidate)
    return result


def links(text):
    text = prose(text)
    # Inline links/images, reference definitions, and HTML resources used by READMEs.
    patterns = [
        r'!?\[[^\]\n]*\]\(\s*(<[^>\n]+>|[^\s()]+(?:\([^()\s]*\)[^\s()]*)*)\s*(?:["\'][^\n]*?["\']\s*)?\)',
        r'^ {0,3}\[[^\]\n]+\]:\s*(<[^>\n]+>|\S+)',
        r'\b(?:src|href|srcset)=["\']([^"\']+)["\']',
    ]
    for pattern in patterns:
        for match in re.finditer(pattern, text, re.M):
            yield text.count("\n", 0, match.start()) + 1, html.unescape(match[1].strip("<>"))


def public_files(root):
    output = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=root)
    return {root / name for name in output.decode().split("\0")
            if name and (root / name).is_file()}


def check(root, files):
    root = root.resolve()
    files = {path.resolve() for path in files}
    errors = []
    headings = {}
    for source in sorted(path for path in files if path.suffix.lower() == ".md"):
        for line, destination in links(source.read_text(encoding="utf-8")):
            url = urlsplit(destination)
            if url.scheme or url.netloc:
                continue
            target = (source.parent / unquote(url.path)).resolve() if url.path else source
            location = f"{source.relative_to(root)}:{line}"
            if target != root and root not in target.parents:
                errors.append(f"{location}: target outside repository: {destination}")
                continue
            if target not in files:
                # Repository directory links are valid when they contain public files.
                if not url.fragment and any(target in path.parents for path in files):
                    continue
                errors.append(f"{location}: missing or non-public target: {destination}")
                continue
            if url.fragment and target.suffix.lower() == ".md":
                if target not in headings:
                    headings[target] = anchors(target.read_text(encoding="utf-8"))
                if unquote(url.fragment) not in headings[target]:
                    errors.append(f"{location}: missing heading: {destination}")
    return errors


def main():
    files = public_files(ROOT)
    errors = check(ROOT, files)
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    count = sum(path.suffix.lower() == ".md" for path in files)
    print(f"Documentation links passed ({count} Markdown files).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
