#!/usr/bin/env python3
"""Run the shared, device-free checks used locally, in CI, and before release.

Requires full Xcode, SwiftLint, Python 3 and Node.js. Builds finish before CLI
integration tests start; no check is silently skipped because the CLI is absent.
"""
import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def run(arguments, *, environment=None, capture=False):
    print("+ " + shlex.join(map(str, arguments)), flush=True)
    result = subprocess.run(arguments, cwd=ROOT, env=environment, check=True,
                            stdout=subprocess.PIPE if capture else None, text=True)
    return result.stdout.strip() if capture else None


def require_cli(path):
    if not path.is_file() or not os.access(path, os.X_OK):
        raise RuntimeError(f"Built CLI missing or not executable: {path}")
    return {**os.environ, "IPHONE_USE_TEST_CLI": str(path)}


def runtime_checks():
    directory = ROOT / ".build/runtime-checks"
    directory.mkdir(parents=True, exist_ok=True)
    for name, source, test, frameworks, defines in [
        ("ax", "RunnerAXBinding", "AXBindingTests", [], []),
        ("pinch", "RunnerPinchEvent", "PinchEventTests", ["-framework", "CoreGraphics"], []),
        ("startup", "RunnerStartupGuard", "StartupGuardTests", [], []),
        ("startup-unsupported", "RunnerStartupGuard", "StartupGuardTests", [], ["-DSTARTUP_TEST_UNSUPPORTED"]),
    ]:
        binary = directory / name
        run(["xcrun", "clang", "-fobjc-arc", "-framework", "Foundation", *frameworks, *defines,
             f"Runner/{source}.m", f"Tests/RunnerRuntime/{test}.m", "-o", str(binary)])
        environment = {key: value for key, value in os.environ.items()
                       if key not in ("IPHONE_USE_HOST_MANAGED", "IPHONE_USE_SESSION_TOKEN")}
        authorized = {**environment, "IPHONE_USE_HOST_MANAGED": "1",
                      "IPHONE_USE_SESSION_TOKEN": "0" * 32}
        if name == "startup":
            run([binary, "disabled"], environment=environment)
            run([binary, "disabled"], environment={**authorized, "IPHONE_USE_SESSION_TOKEN": "short"})
            for scenario in ("active", "inactive", "flapping", "background", "enter_background",
                             "timeout", "nonhome", "offmain", "finish"):
                run([binary, scenario], environment=authorized)
        elif name == "startup-unsupported":
            run([binary, "unsupported"], environment=authorized)
        else:
            run([binary], environment=environment)


def swiftlint_command():
    pin = json.loads((ROOT / "scripts/tools/swiftlint.json").read_text())
    version = pin["version"]
    local = ROOT / ".build/tools" / f"swiftlint-{version}" / "swiftlint"
    command = str(local) if local.is_file() else "swiftlint"
    actual = run([command, "version"], capture=True)
    if actual != version:
        raise RuntimeError(f"Expected SwiftLint {version}, got {actual}. Run python3 scripts/tools/install-swiftlint.py.")
    return command


def quick_checks():
    pin = json.loads((ROOT / "scripts/tools/actionlint.json").read_text())
    actionlint = ROOT / ".build/tools" / f"actionlint-{pin['version']}" / "actionlint"
    if not actionlint.is_file():
        raise RuntimeError("Run python3 scripts/tools/install-actionlint.py before checks.")
    if run([actionlint, "-version"], capture=True).splitlines()[0] != pin['version']:
        raise RuntimeError("Actionlint version does not match scripts/tools/actionlint.json")
    workflows = sorted((ROOT / ".github/workflows").glob("*.yml"))
    workflows += sorted((ROOT / "packaging").glob("*/.github/workflows/*.yml"))
    run([actionlint, "-shellcheck=", "-pyflakes=", *workflows])
    run([sys.executable, "scripts/checks/check-docs.py"])
    for pattern in ("test_docs.py", "test_governance.py", "test_engineering_checks.py"):
        run([sys.executable, "-m", "unittest", "discover", "-s", "scripts/tests", "-p", pattern, "-v"])
    node_tests = sorted(str(path.relative_to(ROOT)) for path in (ROOT / "scripts/tests").glob("test_*.mjs"))
    run(["node", "--test", *node_tests])
    run([sys.executable, "scripts/plugin/sync-plugin.py", "--check"])
    run([sys.executable, "scripts/plugin/sync-plugin.py", "--archive", ".build/plugins"])


def acceptance_checks(binary_directory, jobs):
    run(["xcodebuild", "build", "-project", "scripts/device/text-probe/NativeTextProbe.xcodeproj",
         "-target", "NativeTextProbe", "-configuration", "Debug", "-sdk", "iphoneos",
         "-jobs", str(jobs), "CODE_SIGNING_ALLOWED=NO",
         f"SYMROOT={ROOT / '.build/check-probe/products'}",
         f"OBJROOT={ROOT / '.build/check-probe/intermediates'}"])
    directory = ROOT / ".build/acceptance-tools"
    directory.mkdir(parents=True, exist_ok=True)
    modulemap = directory / "module.modulemap"
    header = ROOT / "Sources/AppleNativeBridge/include/AppleNativeBridge.h"
    modulemap.write_text(f'module AppleNativeBridge {{ header "{header}" export * }}\n')
    objects = []
    for target in ("IPhoneUseCore", "IPhoneUseRunnerSupport", "AppleNativeBridge"):
        combined = binary_directory / f"{target}.o"
        inputs = [combined] if combined.is_file() else sorted((binary_directory / f"{target}.build").rglob("*.o"))
        if not inputs:
            raise RuntimeError(f"Missing debug objects for {target} in {binary_directory}")
        objects.extend(inputs)
    modules = binary_directory / "Modules"
    binary = directory / "ContactFaultHost"
    run(["xcrun", "swiftc", "-parse-as-library", "-I", modules if modules.is_dir() else binary_directory,
         "-Xcc", f"-fmodule-map-file={modulemap}", "scripts/device/native-contact-fault-host.swift",
         *objects, "-o", binary])
    run([binary, "--help"])
    run([binary, "--self-test"])


def native_checks(jobs):
    run(["xcodebuild", "-version"])
    run(["swift", "--version"])
    run([swiftlint_command(), "lint", "--strict", "--no-cache"])
    run(["swift", "build", "--jobs", str(jobs), "--product", "iphone-use"])
    binary_directory = Path(run(["swift", "build", "--show-bin-path"], capture=True))
    environment = require_cli(binary_directory / "iphone-use")
    acceptance_checks(binary_directory, jobs)
    run(["swift", "test", "--package-path", "packages/runner-support", "--jobs", str(jobs)])
    run(["swift", "test", "--jobs", str(jobs)])
    runtime_checks()
    run([sys.executable, "-m", "unittest", "discover", "-s", "scripts/tests", "-v"],
        environment=environment)
    run(["xcodebuild", "build-for-testing", "-project", "Runner/IPhoneUseRunner.xcodeproj",
         "-scheme", "IPhoneUseRunner", "-configuration", "Debug", "-sdk", "iphoneos",
         "-destination", "generic/platform=iOS", "-derivedDataPath", ".build/check-runner",
         "-jobs", str(jobs), "CODE_SIGNING_ALLOWED=NO", "IPHONEOS_DEPLOYMENT_TARGET=17.0"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jobs", type=int, default=2, help="Swift/Xcode build concurrency (default: 2)")
    parser.add_argument("--suite", choices=("all", "quick", "native"), default="all")
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    if args.suite in ("all", "quick"):
        quick_checks()
    if args.suite in ("all", "native"):
        native_checks(args.jobs)
    print(f"Device-free checks passed: {args.suite}. Physical-device acceptance is separate.", flush=True)


if __name__ == "__main__":
    main()
