import XCTest
import CoreVideo
import ImageIO
@testable import IPhoneUseCore

extension NativeCaptureTests {
    func testUnhealthyMediaIsNotLatchedAsAnOrientationFailure() throws {
        for ended in [false, true] {
            let health: [String: Any] = [
                "healthy": false, "displayConnection": ended ? ["errorCode": "native_connection_lost"] : [:]
            ]
            XCTAssertThrowsError(
                try NativeCaptureChecks.withOrientationRecovery(
                    capture: { _ in
                        try NativeCaptureChecks.requireHealthyMedia(health)
                        XCTFail("Unhealthy media cannot certify geometry")
                        return CapturedObservation(nodes: [], metadata: [:], screenshot: Data())
                    },
                    resynchronize: {
                        XCTFail("Do not restart media for a connection failure"); return true
                    })
            ) {
                let failure = $0 as? IPhoneUseError
                XCTAssertEqual(failure?.code, ended ? "native_connection_lost" : "native_media_unhealthy")
                XCTAssertNotNil(failure?.diagnostics["media"])
            }
        }
        XCTAssertNoThrow(try NativeCaptureChecks.requireHealthyMedia(["healthy": true]))
    }
    func testRecordingRefreshRevalidatesWithoutEndingSegmentAndStillRejectsChangedGeometry() throws {
        let png = try screenPNG()
        for changed in [false, true] {
            var attempts = 0, refreshes = 0
            let result = try NativeCaptureChecks.withOrientationRecovery(
                capture: { refreshed in
                    attempts += 1
                    if !refreshed {
                        throw IPhoneUseError("native_snapshot_freshness_unavailable", "quiet recording")
                    }
                    return CapturedObservation(nodes: [], metadata: [:], screenshot: png)
                },
                resynchronize: {
                    XCTFail("Ordinary recovery would end this recording"); return true
                },
                recordingActive: { true },
                resynchronizeRecording: {
                    refreshes += 1; return changed
                })
            XCTAssertEqual(attempts, 2)
            XCTAssertEqual(refreshes, 1)
            XCTAssertEqual(
                result.metadata[changed ? "orientationResynchronized" : "orientationRevalidated"] as? Bool,
                true)
        }
    }

    func testRecordingDefersOnlyMissingFrameRecoveryAndAllowsLaterFreshCapture() throws {
        var captures = 0, refreshes = 0
        let png = try screenPNG()
        for code in [
            "native_snapshot_freshness_unavailable", "native_snapshot_geometry_unavailable",
            "native_screenshot_geometry_conflict"
        ] {
            captures = 0; refreshes = 0
            let capture = {
                try NativeCaptureChecks.withOrientationRecovery(
                    capture: { refreshed in
                        captures += 1
                        if !refreshed { throw IPhoneUseError(code, "fixture") }
                        return CapturedObservation(nodes: [], metadata: [:], screenshot: png)
                    },
                    resynchronize: {
                        refreshes += 1; return true
                    }, recordingActive: { true })
            }
            if code == "native_snapshot_freshness_unavailable" {
                XCTAssertThrowsError(try capture()) {
                    let failure = $0 as? IPhoneUseError
                    XCTAssertEqual(failure?.code, code)
                    XCTAssertEqual(failure?.diagnostics["recordingPreserved"] as? Bool, true)
                }
                XCTAssertEqual(captures, 1)
                XCTAssertEqual(refreshes, 0)
            } else {
                XCTAssertEqual(try capture().metadata["orientationResynchronized"] as? Bool, true)
                XCTAssertEqual(captures, 2)
                XCTAssertEqual(refreshes, 1)
            }
        }
        let fresh = try NativeCaptureChecks.withOrientationRecovery(
            capture: { refreshed in
                XCTAssertFalse(refreshed)
                return CapturedObservation(nodes: [], metadata: [:], screenshot: png)
            },
            resynchronize: {
                XCTFail("Fresh capture must retain recording"); return false
            }, recordingActive: { true })
        XCTAssertEqual(fresh.screenshot, png)
    }

    func testCaptureFailureRetainsBothParallelReadsAndFailedCommand() throws {
        let png = try screenPNG(width: 12, height: 18)
        for stage in ["checksBefore", "screenshot", "checksAfter"] {
            var screenshotRequested = false
            let cli = AppleDeviceCLI(
                device: "fixture", cancellation: NativeCancellation(),
                reader: { args in
                    let command = args.prefix { !$0.hasPrefix("--") }.joined(separator: " ")
                    if command == "device capture screenshot" {
                        screenshotRequested = true
                        if stage != "screenshot" {
                            try png.write(to: URL(fileURLWithPath: try XCTUnwrap(args.last)))
                            return [:]
                        }
                    } else if command == "device info lockState" {
                        return ["passcodeRequired": false]
                    } else if (stage == "checksAfter") != screenshotRequested || stage == "screenshot" {
                        return self.display()
                    }
                    throw IPhoneUseError(
                        "coredevice_timeout", "fixture deadline",
                        diagnostics: [
                            "process": [
                                "processExited": true, "terminationRequested": true, "forcedKill": false
                            ]
                        ])
                })
            XCTAssertThrowsError(try cli.capture(generation: "fixture")) { error in
                guard let failure = error as? IPhoneUseError,
                    let capture = failure.diagnostics["capture"] as? [String: Any],
                    let commands = capture["commands"] as? [[String: Any]]
                else { return XCTFail("Missing diagnostics") }
                XCTAssertEqual(failure.code, "coredevice_timeout")
                XCTAssertEqual(capture["failedStage"] as? String, stage)
                let failed = commands.filter { $0["ok"] as? Bool == false }
                XCTAssertEqual(failed.count, 1)
                XCTAssertEqual(
                    failed.first?["command"] as? String,
                    stage == "screenshot" ? "device capture screenshot" : "device info displays")
                XCTAssertEqual((failed.first?["process"] as? [String: Any])?["processExited"] as? Bool, true)
                XCTAssertEqual(commands.filter { $0["phase"] as? String == "checksBefore" }.count, 2)
                XCTAssertNotNil((capture["timingsMs"] as? [String: Double])?[stage])
                XCTAssertNotNil(try? jsonData(failure.diagnostics))
            }
        }
    }
    func testRecoveryTimingIncludesFailedAttemptAndOwnedRefresh() throws {
        var clock = 0.0, refreshed = false
        let png = try screenPNG()
        let result = try NativeCaptureChecks.withOrientationRecovery(
            capture: { retry in
                if !retry {
                    clock += 1
                    throw IPhoneUseError("native_snapshot_freshness_unavailable", "quiet stream")
                }
                clock += 3
                return CapturedObservation(
                    nodes: [], metadata: ["captureTimingsMs": ["total": 3000.0]], screenshot: png)
            },
            resynchronize: {
                clock += 2; refreshed = true; return false
            }, diagnostics: { ["refreshed": refreshed] }, now: { clock })
        let recovery = try XCTUnwrap(result.metadata["orientationRecovery"] as? [String: Any])
        XCTAssertEqual(recovery["firstAttemptMs"] as? Double, 1000)
        XCTAssertEqual(recovery["resynchronizeMs"] as? Double, 2000)
        XCTAssertEqual(recovery["retryMs"] as? Double, 3000)
        XCTAssertEqual(recovery["totalMs"] as? Double, 6000)
        XCTAssertEqual((recovery["triggerState"] as? [String: Any])?["refreshed"] as? Bool, false)
        XCTAssertEqual((recovery["recoveredState"] as? [String: Any])?["refreshed"] as? Bool, true)
        let timings = try XCTUnwrap(result.metadata["captureTimingsMs"] as? [String: Double])
        XCTAssertEqual(timings["successfulAttemptTotal"], 3000)
        XCTAssertEqual(timings["total"], 6000)
        XCTAssertEqual(result.metadata["orientationRevalidated"] as? Bool, true)
        XCTAssertEqual(result.screenshot, png)
    }

    func testMissingFreshGeometryCannotFallBackToAppleOrAnUnchangedDisplay() throws {
        let cli = AppleDeviceCLI(
            device: "fixture", cancellation: NativeCancellation(),
            reader: { arguments in
                if arguments.last == "lockState" { return ["passcodeRequired": false] }
                if arguments.last == "displays" { return self.display() }
                XCTFail("Unverified geometry must stop before Apple screenshot acquisition")
                return [:]
            })
        var attempts = [Bool](), refreshes = 0
        XCTAssertThrowsError(
            try NativeCaptureChecks.withOrientationRecovery(
                capture: { refreshed in
                    attempts.append(refreshed)
                    return try cli.capture(
                        generation: "fixture",
                        validateDisplay: { display, _ in
                            _ = try NativeSnapshotImage.validateGeometry(nil, display: display)
                            return [:]
                        })
                },
                resynchronize: {
                    refreshes += 1; return false
                })
        ) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "native_orientation_unverified")
        }
        XCTAssertEqual(attempts, [false, true])
        XCTAssertEqual(refreshes, 1)
    }
}
