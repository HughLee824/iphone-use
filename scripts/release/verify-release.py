#!/usr/bin/env python3
"""Verify an archive, including a relocated CLI smoke test on its native macOS host."""

import argparse
import json
import os
import platform
import subprocess
import tarfile
import tempfile
from pathlib import Path

from release_artifact import check_checksum, check_linked_libraries, inspect_archive


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--require-clean", action="store_true", help="Reject a build with uncommitted source changes")
    parser.add_argument("--no-execute", action="store_true", help="Check bytes only, without executing the CLI")
    args = parser.parse_args()
    check_checksum(args.archive)
    result = inspect_archive(args.archive, require_clean=args.require_clean)
    libraries = None
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
            environment = {**os.environ, "IPHONE_USE_CONFIG_DIR": str(root / "isolated preferences")}
            for arguments in [["--version"], ["setup", "--help"], ["connect", "--help"], ["config", "--help"]]:
                output = subprocess.check_output([str(link), *arguments], cwd=root, env=environment, text=True, timeout=15)
                if arguments == ["--version"] and output.strip() != result["version"]:
                    raise ValueError("Relocated CLI does not identify this release")
            def config(*arguments):
                response = json.loads(subprocess.check_output([str(link), "config", *arguments],
                    cwd=root, env=environment, text=True, timeout=15))
                if response.get("ok") is not True:
                    raise ValueError("Relocated CLI configuration command failed")
                return response["result"]
            fresh = config("get", "mode")
            if (fresh.get("mode") != "standard" or fresh.get("modeSource") != "default"
                    or Path(fresh.get("configPath", "")).resolve() != (Path(environment["IPHONE_USE_CONFIG_DIR"]) / "config.json").resolve()
                    or fresh.get("saved") is not False or Path(environment["IPHONE_USE_CONFIG_DIR"]).exists()):
                raise ValueError("Fresh isolated preferences must default to standard without writing state")
            for mode in ["runner", "standard"]:
                config("set", "mode", mode)
                saved = config("get", "mode")
                if saved.get("mode") != mode or saved.get("modeSource") != "configuration" or saved.get("saved") is not True:
                    raise ValueError("Relocated CLI did not retain the selected mode")
            libraries = check_linked_libraries(subprocess.check_output(
                ["/usr/bin/otool", "-L", str(moved / "bin/iphone-use")], text=True, timeout=15))
            subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(moved / "bin/iphone-use")],
                           check=True, capture_output=True, timeout=15)
    print(json.dumps({"version": result["version"], "architecture": result["architecture"],
                      "sha256": result["sha256"], "sourceCommit": result["build"]["sourceCommit"],
                      "sourceDirty": result["build"]["sourceDirty"], "executed": not args.no_execute,
                      "isolatedModesVerified": not args.no_execute, "linkedLibraries": libraries,
                      "deviceVerified": False}))


if __name__ == "__main__":
    main()
