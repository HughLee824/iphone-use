#!/usr/bin/env python3
"""Run the shared, device-free checks used locally, in CI, and before release.

Requires full Xcode, SwiftLint, Python 3 and Node.js. Builds finish before CLI
integration tests start; no check is silently skipped because the CLI is absent.
"""
import argparse
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jobs", type=int, default=2, help="Swift/Xcode build concurrency (default: 2)")
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    run(["xcodebuild", "-version"])
    run(["swift", "--version"])
    run(["swiftlint", "version"])
    run(["swiftlint", "lint", "--strict", "--no-cache"])
    run(["swift", "build", "--jobs", str(args.jobs), "--product", "iphone-use"])
    binary_directory = Path(run(["swift", "build", "--show-bin-path"], capture=True))
    environment = require_cli(binary_directory / "iphone-use")
    run(["swift", "test", "--jobs", str(args.jobs)])
    runtime_checks()
    run([sys.executable, "-m", "unittest", "discover", "-s", "scripts/tests", "-v"],
        environment=environment)
    node_tests = sorted(str(path.relative_to(ROOT)) for path in (ROOT / "scripts/tests").glob("test_*.mjs"))
    run(["node", "--test", *node_tests])
    run(["xcodebuild", "build-for-testing", "-project", "Runner/IPhoneUseRunner.xcodeproj",
         "-scheme", "IPhoneUseRunner", "-configuration", "Debug", "-sdk", "iphoneos",
         "-destination", "generic/platform=iOS", "-derivedDataPath", ".build/check-runner",
         "-jobs", str(args.jobs), "CODE_SIGNING_ALLOWED=NO", "IPHONEOS_DEPLOYMENT_TARGET=17.0"])
    run([sys.executable, "scripts/sync-plugin.py", "--check"])
    run([sys.executable, "scripts/sync-plugin.py", "--archive", ".build/plugins"])
    print("All device-free checks passed. Physical-device acceptance is separate.", flush=True)


if __name__ == "__main__":
    main()
