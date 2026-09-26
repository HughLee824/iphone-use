"""Release archive checks shared by the maintainer tools; no device or account access."""

import hashlib
import json
import plistlib
import re
import tarfile
from pathlib import Path, PurePosixPath


NUMBER = r"(?:0|[1-9][0-9]*)"
PRERELEASE = rf"(?:{NUMBER}|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"
VERSION_PATTERN = rf"{NUMBER}\.{NUMBER}\.{NUMBER}(?:-{PRERELEASE}(?:\.{PRERELEASE})*)?"
RUNNER = "libexec/iphone-use/runner/"


def check_linked_libraries(otool_output):
    """Reject dependencies on a build checkout, Homebrew or unbundled dylibs.

    This checks Mach-O load commands, not frameworks opened later with dlopen;
    those still need device acceptance on the supported Apple toolchain.
    """
    libraries = []
    for line in otool_output.splitlines()[1:]:
        library, separator, _ = line.strip().partition(" (compatibility version ")
        if not separator or not library.startswith(("/System/Library/", "/usr/lib/")) or ".." in PurePosixPath(library).parts:
            raise ValueError(f"CLI has an unsupported external dependency: {library}")
        libraries.append(library)
    if not libraries:
        raise ValueError("No CLI linked libraries found")
    return libraries


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def inspect_archive(archive, *, require_clean=False):
    archive = Path(archive)
    match = re.fullmatch(rf"iphone-use-({VERSION_PATTERN})-macos-(arm64|x86_64)\.tar\.gz", archive.name)
    if not match:
        raise ValueError("Expected a versioned iPhone-use macOS release archive")
    version, architecture = match.groups()
    root = archive.name.removesuffix(".tar.gz")
    files = {}
    with tarfile.open(archive, "r:gz") as tar:
        seen = set()
        for member in tar.getmembers():
            path = PurePosixPath(member.name)
            if (not path.parts or path.is_absolute() or ".." in path.parts or path.parts[0] != root
                    or path.as_posix() != member.name.rstrip("/")):
                raise ValueError("Release archive contains a path outside its versioned directory")
            if not (member.isfile() or member.isdir()) or path in seen:
                raise ValueError("Release archive contains a link, special file, or duplicate path")
            seen.add(path)
            if member.isfile():
                files[path.relative_to(root).as_posix()] = tar.extractfile(member).read()
    required = ["bin/iphone-use", "bin/agentsoma", "README.md", "LICENSE", "licenses/SwiftArgumentParser.txt",
                "build-info.json", RUNNER + "manifest.json"]
    if any(name not in files for name in required):
        raise ValueError("Release archive is missing its binary, instructions, licences or metadata")
    if any(name not in required and not name.startswith(RUNNER) for name in files):
        raise ValueError("Release archive contains an unexpected file outside the Runner payload")
    if files["bin/agentsoma"] != files["bin/iphone-use"]:
        raise ValueError("Legacy command must be an exact copy of iphone-use")
    manifest = json.loads(files[RUNNER + "manifest.json"])
    build = json.loads(files["build-info.json"])
    if manifest.get("formatVersion") != 1 or manifest.get("releaseVersion") != version:
        raise ValueError("Archive name and Runner manifest version do not match")
    if build.get("version") != version or build.get("architecture") != architecture or build.get("license") != "MIT":
        raise ValueError("Archive name and build metadata do not match")
    if not re.fullmatch(r"[0-9a-f]{40}", build.get("sourceCommit", "")):
        raise ValueError("Build metadata must identify the source commit")
    if type(build.get("sourceDirty")) is not bool:
        raise ValueError("Build metadata must record whether its source was dirty")
    if require_clean and build.get("sourceDirty") is not False:
        raise ValueError("Only an archive built from a clean checkout may become a GitHub release")
    if sha256(files["bin/iphone-use"]) != manifest.get("cliSHA256"):
        raise ValueError("CLI digest does not match the packaged Runner manifest")
    actual = {name.removeprefix(RUNNER): sha256(data) for name, data in files.items()
              if name.startswith(RUNNER) and name != RUNNER + "manifest.json"}
    if actual != manifest.get("files"):
        raise ValueError("Runner payload differs from its file manifest")
    required_runner = ["Runner.xctestrun", "IPhoneUseRunner.app/Info.plist",
                       "IPhoneUseRunner.app/IPhoneUseTests-Runner",
                       "IPhoneUseRunner.app/PlugIns/IPhoneUseTests.xctest/IPhoneUseTests"]
    if any(name not in actual for name in required_runner):
        raise ValueError("Runner payload is incomplete")
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", manifest.get("minimumOSVersion", "")):
        raise ValueError("Runner minimum iOS version is invalid")
    for name in actual:
        if name.endswith((".mobileprovision", ".swift")) or "/Frameworks/" in name or ".dSYM/" in name:
            raise ValueError("Runner package contains signing profiles, source, or embedded test frameworks/symbols")
    runner_version = sha256(json.dumps(actual, sort_keys=True, separators=(",", ":")).encode())
    if runner_version != manifest.get("runnerVersion"):
        raise ValueError("Runner content version does not match its payload")
    plan = plistlib.loads(files[RUNNER + "Runner.xctestrun"])
    target = plan.get("IPhoneUseTests", {})
    if (set(plan) - {"IPhoneUseTests", "__xctestrun_metadata__"}
            or target.get("TestHostPath") != "__TESTROOT__/IPhoneUseRunner.app"
            or target.get("TestBundlePath") != "__TESTHOST__/PlugIns/IPhoneUseTests.xctest"
            or target.get("UseUITargetAppProvidedByTests") is not True
            or "UITargetAppPath" in target
            or target.get("DependentProductPaths") != ["__TESTROOT__/IPhoneUseRunner.app",
                "__TESTROOT__/IPhoneUseRunner.app/PlugIns/IPhoneUseTests.xctest"]):
        raise ValueError("Runner test manifest must reference only the packaged app and test bundle")
    return {"version": version, "architecture": architecture, "sha256": sha256(archive.read_bytes()),
            "root": root, "manifest": manifest, "build": build, "files": files}


def check_checksum(archive):
    archive = Path(archive)
    expected = Path(str(archive) + ".sha256").read_text().strip().split()
    if expected != [sha256(archive.read_bytes()), archive.name]:
        raise ValueError("Release SHA-256 file does not match its archive")
