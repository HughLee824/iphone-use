#!/usr/bin/env python3
"""Copy the canonical skill into the self-contained client plugin bundle."""

import argparse
import hashlib
import json
import re
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLUGIN = ROOT / "plugins/iphone-use"


def repository_manifest():
    """Expose the same bundle at the Git repository/npm package root."""
    manifest = json.loads((PLUGIN / "package.json").read_text())
    prefix = "./plugins/iphone-use/"
    manifest["main"] = prefix + manifest["main"].removeprefix("./")
    manifest["exports"] = {key: prefix + value.removeprefix("./")
                           for key, value in manifest["exports"].items()}
    manifest["dsh"]["bundle"]["patch"] = prefix + manifest["dsh"]["bundle"]["patch"].removeprefix("./")
    manifest["files"] = ["plugins/iphone-use/" + path for path in manifest["files"] if path != "LICENSE"] + ["LICENSE"]
    manifest["repository"].pop("directory", None)
    return manifest


def sync_repository_manifest(check=False):
    target = ROOT / "package.json"
    expected = json.dumps(repository_manifest(), ensure_ascii=False, indent=2) + "\n"
    if not target.is_file() or target.read_text() != expected:
        if check:
            raise ValueError("Repository package.json is stale. Run python3 scripts/sync-plugin.py.")
        target.write_text(expected)


def expected_files():
    files = {Path("LICENSE"): (ROOT / "LICENSE").read_bytes()}
    source = ROOT / "skills/iphone-use"
    for path in sorted(source.rglob("*")):
        if path.is_symlink():
            raise ValueError(f"Skill files must be self-contained, not symlinks: {path}")
        if path.is_file():
            files[Path("skills/iphone-use") / path.relative_to(source)] = path.read_bytes()
    return files


def sync(check=False):
    expected = expected_files()
    actual = {path.relative_to(PLUGIN) for path in (PLUGIN / "skills").rglob("*") if path.is_file()}
    actual.add(Path("LICENSE"))
    stale = actual - expected.keys()
    changed = [path for path, content in expected.items()
               if not (PLUGIN / path).is_file() or (PLUGIN / path).read_bytes() != content]
    if check and (changed or stale):
        raise ValueError("Plugin bundle is stale. Run python3 scripts/sync-plugin.py. Files: "
                         + ", ".join(str(path) for path in sorted(set(changed) | stale)))
    if not check:
        for path in stale:
            (PLUGIN / path).unlink()
        for path in changed:
            target = PLUGIN / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(expected[path])


def archive(output):
    codex = json.loads((PLUGIN / ".codex-plugin/plugin.json").read_text())
    claude = json.loads((PLUGIN / ".claude-plugin/plugin.json").read_text())
    deepseek = json.loads((PLUGIN / "package.json").read_text())
    version = codex["version"]
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) or any(
            manifest["version"] != version for manifest in (claude, deepseek)):
        raise ValueError("All plugin manifests must have the same stable semantic version")
    output.mkdir(parents=True, exist_ok=True)
    target = output / f"iphone-use-plugin-{version}.zip"
    # Explicit public package roots. Never archive the source checkout or local evidence.
    files = [PLUGIN / path for path in (".codex-plugin/plugin.json", ".claude-plugin/plugin.json",
                                       "package.json", "deepseek.js", "cordis.patch.yml", "README.md", "LICENSE")]
    files.extend(sorted((PLUGIN / "locale").glob("*.json")))
    files.extend(sorted(path for path in (PLUGIN / "skills").rglob("*") if path.is_file()))
    with zipfile.ZipFile(target, "w", compression=zipfile.ZIP_DEFLATED) as bundle:
        for path in files:
            if path.is_symlink():
                raise ValueError(f"Refusing symlink in plugin: {path}")
            info = zipfile.ZipInfo("iphone-use/" + path.relative_to(PLUGIN).as_posix(), (2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            bundle.writestr(info, path.read_bytes())
    digest = hashlib.sha256(target.read_bytes()).hexdigest()
    target.with_suffix(".zip.sha256").write_text(f"{digest}  {target.name}\n")
    print(target)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Fail on drift without modifying files")
    parser.add_argument("--archive", type=Path, help="Write a reproducible ZIP and SHA-256 file after checking the bundle")
    args = parser.parse_args()
    sync(check=args.check or args.archive is not None)
    sync_repository_manifest(check=args.check or args.archive is not None)
    if args.archive:
        archive(args.archive)
    else:
        print("Plugin bundle is current." if args.check else "Plugin bundle synchronized.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
