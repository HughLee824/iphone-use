#!/usr/bin/env python3
"""Maintainer-only: build a relocatable CLI and unsigned iOS Runner. Never publishes."""

import argparse
import hashlib
import json
import platform
import plistlib
import re
import shutil
import subprocess
import tarfile
import tempfile
from pathlib import Path

from release_artifact import VERSION_PATTERN, inspect_archive


def run(arguments, *, cwd, log=None):
    if log:
        with log.open("wb") as output:
            result = subprocess.run(arguments, cwd=cwd, stdout=output, stderr=subprocess.STDOUT)
        if result.returncode:
            raise RuntimeError(f"{arguments[0]} failed; see {log}")
        return None
    return subprocess.check_output(arguments, cwd=cwd, text=True).strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_plist(path, value):
    path.write_bytes(plistlib.dumps(value, sort_keys=True))


def package_runner(products, destination):
    manifests = list(products.glob("*.xctestrun"))
    if len(manifests) != 1:
        raise RuntimeError("Expected exactly one generated Runner .xctestrun")
    generated = plistlib.loads(manifests[0].read_bytes())
    target = generated["IPhoneUseTests"]
    host = target["TestHostPath"]
    if not host.startswith("__TESTROOT__/"):
        raise RuntimeError("Unexpected generated Runner host path")
    source = (products / host.removeprefix("__TESTROOT__/")).resolve()
    if not source.is_relative_to(products.resolve()):
        raise RuntimeError("Runner host escapes build products")
    app = destination / "IPhoneUseRunner.app"
    shutil.copytree(source, app, symlinks=True)
    # iOS 17+ uses XCTest from the device. Do not redistribute Apple's test frameworks.
    shutil.rmtree(app / "Frameworks", ignore_errors=True)
    for path in list(app.rglob("*.dSYM")):
        shutil.rmtree(path)
    for path in list(app.rglob("*.mobileprovision")):
        path.unlink()
    for path in list(app.rglob("_CodeSignature")):
        shutil.rmtree(path)
    test = app / "PlugIns/IPhoneUseTests.xctest"
    for bundle, executable in [(test, "IPhoneUseTests"), (app, "IPhoneUseTests-Runner")]:
        if subprocess.run(["/usr/bin/codesign", "-d", str(bundle)], capture_output=True).returncode == 0:
            run(["/usr/bin/codesign", "--remove-signature", str(bundle / executable)], cwd=destination)
        run(["/usr/bin/strip", "-S", str(bundle / executable)], cwd=destination)
    info = plistlib.loads((app / "Info.plist").read_bytes())
    info["CFBundleDisplayName"] = "iPhone-use"
    write_plist(app / "Info.plist", info)
    # Generate a closed, portable test manifest instead of shipping local build settings.
    write_plist(destination / "Runner.xctestrun", {
        "__xctestrun_metadata__": {"FormatVersion": 1},
        "IPhoneUseTests": {
            "BlueprintName": "IPhoneUseTests", "ProductModuleName": "IPhoneUseTests",
            "IsUITestBundle": True, "IsXCTRunnerHostedTestBundle": True,
            "UseUITargetAppProvidedByTests": True, "TestTimeoutsEnabled": False,
            "TestHostBundleIdentifier": info["CFBundleIdentifier"],
            "TestHostPath": "__TESTROOT__/IPhoneUseRunner.app",
            "TestBundlePath": "__TESTHOST__/PlugIns/IPhoneUseTests.xctest",
            "DependentProductPaths": ["__TESTROOT__/IPhoneUseRunner.app",
                                      "__TESTROOT__/IPhoneUseRunner.app/PlugIns/IPhoneUseTests.xctest"],
            "SystemAttachmentLifetime": "deleteOnSuccess", "UserAttachmentLifetime": "deleteOnSuccess",
        },
    })
    files = {}
    for path in sorted(destination.rglob("*")):
        if path.is_symlink():
            raise RuntimeError(f"Unexpected symbolic link in Runner payload: {path.name}")
        if path.is_file():
            files[path.relative_to(destination).as_posix()] = digest(path)
    return files, info["MinimumOSVersion"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True, help="Explicit release version, e.g. 0.1.0-dev.1")
    parser.add_argument("--output-dir", type=Path, help="Default: .build/releases")
    parser.add_argument("--require-clean", action="store_true", help="Require a clean committed source checkout")
    args = parser.parse_args()
    if not re.fullmatch(VERSION_PATTERN, args.version):
        parser.error("Use a semantic version without a leading v")
    architecture = platform.machine()
    if platform.system() != "Darwin" or architecture not in ("arm64", "x86_64"):
        parser.error("Build on macOS using an arm64 or x86_64 host")
    root = Path(__file__).resolve().parents[1]
    commit = run(["git", "rev-parse", "HEAD"], cwd=root)
    dirty = bool(run(["git", "status", "--porcelain"], cwd=root))
    if args.require_clean and dirty:
        parser.error("Commit source changes before building a public release")
    if not (root / "LICENSE").is_file():
        parser.error("The project LICENSE is required in every release")
    output = (args.output_dir or root / ".build/releases").resolve()
    output.mkdir(parents=True, exist_ok=True)
    name = f"iphone-use-{args.version}-macos-{architecture}"
    destination = output / name
    archive = output / f"{name}.tar.gz"
    checksum = output / f"{archive.name}.sha256"
    if destination.exists() or archive.exists() or checksum.exists():
        parser.error("Output already exists; use another version or output directory")
    log = output / f"{name}-build.log"
    run(["swift", "build", "-c", "release"], cwd=root, log=log)
    bin_path = Path(run(["swift", "build", "-c", "release", "--show-bin-path"], cwd=root))
    # Isolated builds keep development Runner products and active sessions untouched.
    with tempfile.TemporaryDirectory(prefix=".release-", dir=output) as staging, \
            tempfile.TemporaryDirectory(prefix="release-runner-", dir=root / ".build") as temporary:
        staged = Path(staging) / name
        runner_log = output / f"{name}-runner-build.log"
        run(["xcrun", "xcodebuild", "build-for-testing", "-project", "Runner/IPhoneUseRunner.xcodeproj",
             "-scheme", "IPhoneUseRunner", "-configuration", "Debug", "-sdk", "iphoneos",
             "-destination", "generic/platform=iOS", "-derivedDataPath", temporary,
             "CODE_SIGNING_ALLOWED=NO", "IPHONEOS_DEPLOYMENT_TARGET=17.0",
             "SWIFT_OPTIMIZATION_LEVEL=-O", "SWIFT_ACTIVE_COMPILATION_CONDITIONS=",
             "DEBUG_INFORMATION_FORMAT=dwarf-with-dsym", "SWIFT_SERIALIZE_DEBUGGING_OPTIONS=NO"],
            cwd=root, log=runner_log)
        (staged / "bin").mkdir(parents=True)
        shutil.copy2(bin_path / "iphone-use", staged / "bin/iphone-use")
        run(["/usr/bin/strip", "-S", str(staged / "bin/iphone-use")], cwd=root)
        # Ad-hoc signing keeps the local arm64 binary executable; this is not Developer ID signing.
        run(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", str(staged / "bin/iphone-use")], cwd=root)
        # Archive links are forbidden; ship an exact byte copy for the legacy command.
        shutil.copy2(staged / "bin/iphone-use", staged / "bin/agentsoma")
        runner = staged / "libexec/iphone-use/runner"
        runner.mkdir(parents=True)
        files, minimum_os = package_runner(Path(temporary) / "Build/Products", runner)
        for path in [staged / "bin/iphone-use", *(runner / name for name in files)]:
            if str(root).encode() in path.read_bytes():
                raise RuntimeError(f"Local source path leaked into release payload: {path.relative_to(staged)}")
        runner_version = hashlib.sha256(json.dumps(files, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        (runner / "manifest.json").write_text(json.dumps({
            "formatVersion": 1, "releaseVersion": args.version, "cliSHA256": digest(staged / "bin/iphone-use"), "runnerVersion": runner_version,
            "minimumOSVersion": minimum_os, "files": files,
        }, indent=2, sort_keys=True) + "\n")
        shutil.copy2(root / "docs/install.md", staged / "README.md")
        shutil.copy2(root / "LICENSE", staged / "LICENSE")
        (staged / "licenses").mkdir()
        shutil.copy2(root / ".build/checkouts/swift-argument-parser/LICENSE.txt", staged / "licenses/SwiftArgumentParser.txt")
        (staged / "build-info.json").write_text(json.dumps({
            "version": args.version, "architecture": architecture, "license": "MIT",
            "sourceCommit": commit, "sourceDirty": dirty,
            "xcode": run(["xcodebuild", "-version"], cwd=root),
            "swift": run(["swift", "--version"], cwd=root),
        }, indent=2, sort_keys=True) + "\n")
        if args.require_clean and (run(["git", "rev-parse", "HEAD"], cwd=root) != commit
                                   or run(["git", "status", "--porcelain"], cwd=root)):
            raise RuntimeError("Source checkout changed while building the release")
        staged_archive = Path(staging) / archive.name
        with tarfile.open(staged_archive, "w:gz") as tar:
            tar.add(staged, arcname=name)
        inspect_archive(staged_archive, require_clean=args.require_clean)
        staged.rename(destination)
        staged_archive.rename(archive)
        checksum.write_text(f"{digest(archive)}  {archive.name}\n")
    print(json.dumps({"directory": str(destination), "archive": str(archive), "checksum": str(checksum),
                      "runnerVersion": runner_version, "macSigning": "ad-hoc", "notarized": False, "published": False}))


if __name__ == "__main__":
    main()
