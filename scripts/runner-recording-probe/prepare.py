#!/usr/bin/env python3
"""Create a separate buildable probe workspace; never modify the source Runner."""
import argparse
from pathlib import Path
import shutil


def prepare(output: Path) -> None:
    source = Path(__file__).resolve().parents[2]
    fixture = Path(__file__).resolve().parent
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    shutil.copytree(source / "Runner", output / "Runner")
    shared = output / "Sources/IPhoneUseCore"
    shared.mkdir(parents=True)
    for name in ("FrameStability", "ScreenGuard", "NativeCaretGuard", "RunnerTextInput", "XCTestDiagnostics"):
        shutil.copy2(source / f"Sources/IPhoneUseCore/{name}.swift", shared)
    runner = output / "Runner"
    # Append only in the fresh experimental copy. No production target/test or
    # protocol version changes, and no build-system dependency is introduced.
    shutil.copy2(fixture / "RecordingProbe.h", runner)
    with (runner / "RunnerPinchEvent.h").open("a") as stream:
        stream.write('\n#import "RecordingProbe.h"\n')
    with (runner / "RunnerPinchEvent.m").open("a") as stream:
        stream.write("\n" + (fixture / "RecordingProbe.m").read_text())
    with (runner / "LiveSessionTests.swift").open("a") as stream:
        stream.write("\n" + (fixture / "RecordingProbeTests.swift").read_text())


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="New, unused workspace directory")
    args = parser.parse_args()
    prepare(args.output.resolve())
    print(args.output.resolve())
