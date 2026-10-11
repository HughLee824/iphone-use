#!/usr/bin/env python3
"""Run one three-second recording on an unlocked, foreground iPhone-use Probe.

Build the isolated workspace with build-runner first. Disconnect other control
sessions and visually confirm the Probe before invoking this explicit device test.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import time


def run(args):
    out = args.output.resolve()
    out.mkdir(mode=0o700, parents=True, exist_ok=False)
    fixture = Path(__file__).resolve().parent
    root = fixture.parents[1]

    def command(argv, name, timeout=30):
        with (out / name).open("w") as log:
            return subprocess.run(argv, stdout=log, stderr=subprocess.STDOUT, timeout=timeout).returncode

    def require_command(argv, name, timeout=30):
        code = command(argv, name, timeout)
        if code != 0:
            raise RuntimeError(f"Command failed ({code}); see {name}")

    # Compile host validation before starting the device test/export window.
    shutil.copy2(fixture / "validate.swift", out / "main.swift")
    require_command(["xcrun", "swiftc", str(root / "Sources/IPhoneUseCore/NativeRecordingValidation.swift"),
                    str(out / "main.swift"), "-o", str(out / "validate-video")], "validator-build.log", 90)
    require_command(["xcrun", "devicectl", "device", "info", "details", "--device", args.device,
                    "--json-output", str(out / "device.json")], "device.log")
    details = json.loads((out / "device.json").read_text())["result"]
    udid = details["hardwareProperties"]["udid"]
    require_command(["xcrun", "devicectl", "device", "info", "lockState", "--device", args.device,
                    "--json-output", str(out / "lock.json")], "lock.log")
    if json.loads((out / "lock.json").read_text())["result"].get("passcodeRequired") is not False:
        raise RuntimeError("Device is locked/unknown; no test or recording started")

    original = args.xctestrun.resolve()
    manifest = plistlib.loads(original.read_bytes())
    # Relocate the manifest without mutating the caller's products or resolving
    # __TESTHOST__ prematurely. Only this probe's test is selected below.
    def relocate(value):
        if isinstance(value, str):
            return value.replace("__TESTROOT__", str(original.parent))
        if isinstance(value, list):
            return [relocate(item) for item in value]
        if isinstance(value, dict):
            return {key: relocate(item) for key, item in value.items()}
        return value
    manifest = relocate(manifest)
    target = manifest["IPhoneUseTests"]  # Isolated build currently emits format 1.
    target["PreferredScreenCaptureFormat"] = "screenshots"
    target["UserAttachmentLifetime"] = "keepAlways"
    (out / "probe.xctestrun").write_bytes(plistlib.dumps(manifest))
    environment = dict(os.environ, TEST_RUNNER_IPHONE_USE_RECORDING_PROBE="1")
    result = out / "run.xcresult"
    export = ["xcrun", "xcresulttool", "export", "attachments", "--path", str(result), "--output-path"]
    (out / "events.jsonl").touch()
    with (out / "run.log").open("w") as log:
        process = subprocess.Popen(["xcrun", "xcodebuild", "test-without-building",
            "-xctestrun", str(out / "probe.xctestrun"), "-destination", "platform=iOS,id=" + udid,
            "-parallel-testing-enabled", "NO", "-only-testing:IPhoneUseTests/RecordingProbeTests/testOwnedRecordingExport",
            "-resultBundlePath", str(result), "-resultStreamPath", str(out / "events.jsonl")],
            stdout=log, stderr=subprocess.STDOUT, env=environment)
        live_exit = None
        deadline = time.monotonic() + 150
        try:
            while process.poll() is None:
                if time.monotonic() > deadline:
                    raise TimeoutError("Test deadline exceeded; outcome unknown, do not replay")
                text = (out / "run.log").read_text()
                if live_exit is None and "IPHONE_USE_RECORDING_EXPORT_WINDOW" in text:
                    time.sleep(2)
                    live_exit = command(export + [str(out / "live-export")], "live-export.log", 15)
                    (out / "live-files.json").write_text(json.dumps(
                        [str(path.relative_to(result)) for path in result.rglob("*")], indent=2))
                    print(json.dumps({"liveExportExit": live_exit, "testStillRunning": process.poll() is None}), flush=True)
                time.sleep(0.2)
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
    if process.returncode != 0:
        raise RuntimeError("Probe test failed; inspect run.log; no automatic retry")
    facts = [json.loads(line.split("IPHONE_USE_RECORDING_PROBE ", 1)[1])
             for line in (out / "run.log").read_text().splitlines() if line.startswith("IPHONE_USE_RECORDING_PROBE ")]
    if len(facts) != 1 or facts[0].get("stopAcknowledged") is not True or "error" in facts[0]:
        raise RuntimeError("Missing owned-stop proof; xcodebuild status alone is insufficient")
    require_command(export + [str(out / "final-export")], "final-export.log")
    attachments = [attachment for test in json.loads((out / "final-export/manifest.json").read_text())
                   for attachment in test["attachments"]
                   if attachment["suggestedHumanReadableName"].startswith("iphone-use-owned-recording_")]
    if len(attachments) != 1:
        raise RuntimeError("Expected exactly one owned recording attachment")
    filename = attachments[0]["exportedFileName"]
    if Path(filename).name != filename or not filename.endswith(".mp4"):
        raise RuntimeError("Invalid recording export filename")
    video = out / "final-export" / filename
    require_command([str(out / "validate-video"), str(video), str(out / "frame.png")], "validation.json")
    validation = json.loads((out / "validation.json").read_text())
    report = {"probe": facts[0], "liveExportExit": live_exit, "postSessionValidation": validation,
              "video": str(video), "productionRecordingImplemented": False}
    (out / "report.json").write_text(json.dumps(report, indent=2))
    print(json.dumps(report))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True, help="Identifier from iphone-use devices")
    parser.add_argument("--xctestrun", type=Path, required=True, help="Signed isolated probe build")
    parser.add_argument("--output", type=Path, required=True, help="New, unused evidence directory")
    run(parser.parse_args())
