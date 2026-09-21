#!/usr/bin/env python3
"""Verify an archive, including a relocated CLI smoke test on its native macOS host."""

import argparse
import json
import platform
import subprocess
import tarfile
import tempfile
from pathlib import Path

from release_artifact import check_checksum, inspect_archive


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--require-clean", action="store_true", help="Reject a build with uncommitted source changes")
    parser.add_argument("--no-execute", action="store_true", help="Check bytes only, without executing the CLI")
    args = parser.parse_args()
    check_checksum(args.archive)
    result = inspect_archive(args.archive, require_clean=args.require_clean)
    if not args.no_execute:
        if platform.system() != "Darwin" or platform.machine() != result["architecture"]:
            parser.error("The executable smoke test needs a matching macOS host; use --no-execute elsewhere")
        with tempfile.TemporaryDirectory(prefix="iphone-use release check ") as temporary:
            root = Path(temporary)
            # inspect_archive has rejected all links and paths outside the versioned directory.
            with tarfile.open(args.archive) as tar:
                tar.extractall(root, **({"filter": "data"} if hasattr(tarfile, "data_filter") else {}))
            moved = root / "relocated package"
            (root / result["root"]).rename(moved)
            link = root / "iphone-use"
            link.symlink_to(moved / "bin/iphone-use")
            for arguments in [["--version"], ["setup", "--help"], ["connect", "--help"]]:
                output = subprocess.check_output([str(link), *arguments], cwd=root, text=True, timeout=15)
                if arguments == ["--version"] and output.strip() != result["version"]:
                    raise ValueError("Relocated CLI does not identify this release")
            alias_version = subprocess.check_output([str(moved / "bin/agentsoma"), "--version"], text=True, timeout=15)
            if alias_version.strip() != result["version"]:
                raise ValueError("Legacy command does not identify this release")
            subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(moved / "bin/iphone-use")],
                           check=True, capture_output=True, timeout=15)
    print(json.dumps({"version": result["version"], "architecture": result["architecture"],
                      "sha256": result["sha256"], "sourceCommit": result["build"]["sourceCommit"],
                      "sourceDirty": result["build"]["sourceDirty"], "executed": not args.no_execute}))


if __name__ == "__main__":
    main()
