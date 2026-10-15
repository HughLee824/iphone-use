import XCTest
import CoreVideo
import ImageIO
@testable import IPhoneUseCore

final class NativeCaptureTests: XCTestCase {
    func testRecordingRefreshRevalidatesWithoutEndingSegmentAndStillRejectsChangedGeometry() throws {
        let png = try screenPNG()
        for changed in [false, true] {
            var attempts = 0, refreshes = 0
            let result = try NativeCaptureChecks.withOrientationRecovery(capture: { refreshed in
                attempts += 1
                if !refreshed { throw IPhoneUseError("native_snapshot_freshness_unavailable", "quiet recording") }
                return CapturedObservation(nodes: [], metadata: [:], screenshot: png)
            }, resynchronize: { XCTFail("Ordinary recovery would end this recording"); return true },
            recordingActive: { true }, resynchronizeRecording: { refreshes += 1; return changed })
            XCTAssertEqual(attempts, 2)
            XCTAssertEqual(refreshes, 1)
            XCTAssertEqual(result.metadata[changed ? "orientationResynchronized" : "orientationRevalidated"] as? Bool, true)
        }
    }

    func testRecordingDefersOnlyMissingFrameRecoveryAndAllowsLaterFreshCapture() throws {
        var captures = 0, refreshes = 0
        let png = try screenPNG()
        for code in ["native_snapshot_freshness_unavailable", "native_snapshot_geometry_unavailable", "native_screenshot_geometry_conflict"] {
            captures = 0; refreshes = 0
            let capture = {
                try NativeCaptureChecks.withOrientationRecovery(capture: { refreshed in
                    captures += 1
                    if !refreshed { throw IPhoneUseError(code, "fixture") }
                    return CapturedObservation(nodes: [], metadata: [:], screenshot: png)
                }, resynchronize: { refreshes += 1; return true }, recordingActive: { true })
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
        let fresh = try NativeCaptureChecks.withOrientationRecovery(capture: { refreshed in
            XCTAssertFalse(refreshed)
            return CapturedObservation(nodes: [], metadata: [:], screenshot: png)
        }, resynchronize: { XCTFail("Fresh capture must retain recording"); return false }, recordingActive: { true })
        XCTAssertEqual(fresh.screenshot, png)
    }

    func testCaptureFailureRetainsBothParallelReadsAndFailedCommand() throws {
        let png = try screenPNG(width: 12, height: 18)
        for stage in ["checksBefore", "screenshot", "checksAfter"] {
            var screenshotRequested = false
            let cli = AppleDeviceCLI(device: "fixture", cancellation: NativeCancellation(), reader: { args in
                let command = args.prefix { !$0.hasPrefix("--") }.joined(separator: " ")
                if command == "device capture screenshot" {
                    screenshotRequested = true
                    if stage != "screenshot" {
                        try png.write(to: URL(fileURLWithPath: try XCTUnwrap(args.last)))
                        return [:]
                    }
                } else if command == "device info lockState" { return ["passcodeRequired": false] }
                else if (stage == "checksAfter") != screenshotRequested || stage == "screenshot" { return self.display() }
                throw IPhoneUseError("coredevice_timeout", "fixture deadline", diagnostics: ["process": [
                    "processExited": true, "terminationRequested": true, "forcedKill": false]])
            })
            XCTAssertThrowsError(try cli.capture(generation: "fixture")) { error in
                guard let failure = error as? IPhoneUseError,
                      let capture = failure.diagnostics["capture"] as? [String: Any],
                      let commands = capture["commands"] as? [[String: Any]] else { return XCTFail("Missing diagnostics") }
                XCTAssertEqual(failure.code, "coredevice_timeout")
                XCTAssertEqual(capture["failedStage"] as? String, stage)
                let failed = commands.filter { $0["ok"] as? Bool == false }
                XCTAssertEqual(failed.count, 1)
                XCTAssertEqual(failed.first?["command"] as? String, stage == "screenshot" ? "device capture screenshot" : "device info displays")
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
        let result = try NativeCaptureChecks.withOrientationRecovery(capture: { retry in
            if !retry {
                clock += 1
                throw IPhoneUseError("native_snapshot_freshness_unavailable", "quiet stream")
            }
            clock += 3
            return CapturedObservation(nodes: [], metadata: ["captureTimingsMs": ["total": 3000.0]], screenshot: png)
        }, resynchronize: {
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
        let cli = AppleDeviceCLI(device: "fixture", cancellation: NativeCancellation(), reader: { arguments in
            if arguments.last == "lockState" { return ["passcodeRequired": false] }
            if arguments.last == "displays" { return self.display() }
            XCTFail("Unverified geometry must stop before Apple screenshot acquisition")
            return [:]
        })
        var attempts = [Bool](), refreshes = 0
        XCTAssertThrowsError(try NativeCaptureChecks.withOrientationRecovery(capture: { refreshed in
            attempts.append(refreshed)
            return try cli.capture(generation: "fixture", validateDisplay: { display, _ in
                _ = try NativeSnapshotImage.validateGeometry(nil, display: display)
                return [:]
            })
        }, resynchronize: { refreshes += 1; return false })) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "native_orientation_unverified")
        }
        XCTAssertEqual(attempts, [false, true])
        XCTAssertEqual(refreshes, 1)
    }

    func testFreshnessRecoveryAttachesNewObservationAndRejectsOldInput() throws {
        let context = screenTestContext(), png = try screenPNG()
        let guardValue = try ScreenGuard(png: png, context: context, rects: [context.screen], policy: .init())
        let original = CapturedObservation(nodes: [], metadata: ["displayID": UInt64(1),
            "screenContext": try jsonObject(JSONEncoder().encode(context))], screenshot: png)
        var captures = 0, refreshes = 0
        XCTAssertThrowsError(try NativeInputPreflight.check(guard: guardValue, displayID: 1,
            deadline: 8, maximumCaptures: 3, now: { 0 }) {
                try NativeCaptureChecks.withOrientationRecovery(capture: { refreshed in
                    captures += 1
                    if !refreshed { throw IPhoneUseError("native_snapshot_freshness_unavailable", "quiet stream") }
                    return original // Even identical pixels and direction need a new decision.
                }, resynchronize: { refreshes += 1; return true })
            }) {
                let failure = $0 as? ActionFailure
                XCTAssertEqual(failure?.possiblyExecuted, false)
                XCTAssertEqual(failure?.rejectedCapture?.screenshot, png)
                XCTAssertEqual(failure?.rejectedCapture?.metadata["orientationResynchronizationReason"] as? String,
                               "native_snapshot_freshness_unavailable")
            }
        XCTAssertEqual(captures, 2)
        XCTAssertEqual(refreshes, 1)
    }

    func testOrientationRecoveryIsBoundedAndDoesNotRetryUnrelatedErrors() throws {
        for code in ["device_locked", "native_cancelled", "capture_context_changed", "invalid_image"] {
            var captures = 0
            XCTAssertThrowsError(try NativeCaptureChecks.withOrientationRecovery(capture: { _ in
                captures += 1; throw IPhoneUseError(code, "fixture")
            }, resynchronize: { XCTFail("Do not replace media for unrelated errors"); return false })) {
                XCTAssertEqual(($0 as? IPhoneUseError)?.code, code)
            }
            XCTAssertEqual(captures, 1)
        }
        for code in ["native_snapshot_geometry_unavailable", "native_snapshot_freshness_unavailable"] {
            var captures = 0, refreshes = 0
            XCTAssertThrowsError(try NativeCaptureChecks.withOrientationRecovery(capture: { _ in
                captures += 1; throw IPhoneUseError(code, "fixture")
            }, resynchronize: {
                refreshes += 1
                throw IPhoneUseError("native_cancelled", "cancelled after owned stop")
            })) {
                XCTAssertEqual(($0 as? IPhoneUseError)?.code, "native_cancelled")
            }
            XCTAssertEqual(captures, 1)
            XCTAssertEqual(refreshes, 1)
        }
        let frame = CapturedObservation(nodes: [], metadata: [:], screenshot: try screenPNG())
        let result = try NativeCaptureChecks.withOrientationRecovery(capture: { refreshed in
            XCTAssertFalse(refreshed); return frame
        }, resynchronize: { XCTFail("Fresh capture must not restart media"); return false })
        XCTAssertNil(result.metadata["orientationResynchronized"])
    }

    func testQuietStreamRevalidationStillChecksOriginalSourceGeometryPixelsAndDeadline() throws {
        let context = screenTestContext(), png = try screenPNG()
        let guardValue = try ScreenGuard(png: png, context: context, rects: [context.screen], policy: .init())
        for changed in ["none", "source", "rotation", "pixels", "deadline", "conflict"] {
            var clock = 0.0, captures = 0, refreshes = 0
            let check = {
                try NativeInputPreflight.check(guard: guardValue, displayID: 1, displayRotation: "rot0",
                    captureSource: "coredevice_screenshot", deadline: 8, maximumCaptures: 1, now: { clock }) {
                        try NativeCaptureChecks.withOrientationRecovery(capture: { refreshed in
                            captures += 1
                            if !refreshed {
                                throw IPhoneUseError(changed == "conflict" ? "native_snapshot_geometry_unavailable" : "native_snapshot_freshness_unavailable", "fixture")
                            }
                            if changed == "deadline" { clock = 9 }
                            return CapturedObservation(nodes: [], metadata: ["displayID": UInt64(1),
                                "captureSource": changed == "source" ? "native_media" : "coredevice_screenshot",
                                "displayRotation": changed == "rotation" ? "rot270" : "rot0", "nativeRotation": "rot0",
                                "screenContext": try jsonObject(JSONEncoder().encode(context))],
                                screenshot: changed == "pixels" ? try screenPNG(patches: [(CGRect(x: 0, y: 0, width: 100, height: 100), [0, 0, 0])]) : png)
                        }, resynchronize: { refreshes += 1; return false })
                    }
            }
            if changed == "none" { XCTAssertTrue(try check().0.accepted) }
            else {
                XCTAssertThrowsError(try check(), changed) {
                    let failure = $0 as? ActionFailure
                    XCTAssertEqual(failure?.possiblyExecuted, false)
                    XCTAssertNotNil(failure?.rejectedCapture)
                    XCTAssertEqual(failure?.rejectedCapture?.metadata["orientationResynchronized"] as? Bool,
                                   changed == "conflict" ? true : nil)
                }
            }
            XCTAssertEqual(captures, 2)
            XCTAssertEqual(refreshes, 1)
        }
    }

    func testRecoveryClassificationDoesNotTreatQuietPeerAsFreshGeometry() {
        func state(_ age: Double, pending: Int = 0, frameAge: Double = 10) -> [String: Any] {
            ["healthy": true, "lastRTPAgeSeconds": age,
             "snapshots": ["pendingBytes": pending, "waitingForKeyframe": false, "lastFrameAgeSeconds": frameAge]]
        }
        XCTAssertEqual(NativeCaptureChecks.recoveryTrigger(error: "native_snapshot_freshness_unavailable", state: state(36)), "stream_quiescent")
        XCTAssertEqual(NativeCaptureChecks.recoveryTrigger(error: "native_snapshot_freshness_unavailable", state: state(0.006, pending: 159235, frameAge: 1.68)), "frame_delivery_delayed")
        XCTAssertEqual(NativeCaptureChecks.recoveryTrigger(error: "native_snapshot_geometry_unavailable", state: state(36)), "geometry_conflict")
        XCTAssertEqual(NativeCaptureChecks.recoveryTrigger(error: "native_snapshot_freshness_unavailable", state: ["healthy": false]), "connection_unavailable")
        XCTAssertEqual(NativeCaptureChecks.recoveryTrigger(error: "native_snapshot_freshness_unavailable", state: [:]), "fresh_frame_unavailable")
    }

    func testRecoveryTimeoutDoesNotBecomeOrientationFailureOrRetryCapture() throws {
        for code in ["input_preflight_timeout", "native_cancelled", "coredevice_cancelled"] {
            var captures = 0, refreshes = 0
            XCTAssertThrowsError(try NativeCaptureChecks.withOrientationRecovery(capture: { _ in
                captures += 1; throw IPhoneUseError("native_snapshot_freshness_unavailable", "quiet stream")
            }, resynchronize: {
                refreshes += 1; throw IPhoneUseError(code, "stop")
            })) { XCTAssertEqual(($0 as? IPhoneUseError)?.code, code) }
            XCTAssertEqual(captures, 1)
            XCTAssertEqual(refreshes, 1)
        }
    }

    func testAppleStartsValidationOnlyAfterGeometryAndStopsExpiredReads() throws {
        let now = ProcessInfo.processInfo.systemUptime
        let budget = NativeCaptureBudget(requestDeadline: now + 30)
        let png = try screenPNG(width: 12, height: 18)
        var screenshots = 0
        let cli = AppleDeviceCLI(device: "fixture", cancellation: NativeCancellation(), reader: { arguments in
            if arguments.last == "lockState" { return ["passcodeRequired": false] }
            if arguments.last == "displays" { return self.display() }
            XCTAssertNotNil(budget.validationStartedAt)
            screenshots += 1
            try png.write(to: URL(fileURLWithPath: try XCTUnwrap(arguments.last)))
            return [:]
        })
        _ = try cli.capture(generation: "fixture", budget: budget, prepareDisplay: { _ in
            XCTAssertNil(budget.validationStartedAt)
        }, validateDisplay: { _, _ in
            XCTAssertNil(budget.validationStartedAt)
            return [:]
        })
        XCTAssertEqual(screenshots, 1)
        let expired = NativeCaptureBudget(requestDeadline: now - 1)
        XCTAssertThrowsError(try cli.capture(generation: "fixture", budget: expired)) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "input_preflight_timeout")
        }
        XCTAssertEqual(screenshots, 1)
    }

    private func display(_ rotation: String = "rot0", backlight: String = "activeOn") -> [String: Any] {
        ["backlightState": backlight, "displays": [["primary": true, "displayId": 1,
            "bounds": [[0, 0], [12, 18]], "pointScale": 3,
            "currentOrientation": rotation, "nativeOrientation": "rot0"]]]
    }
    func testIndependentChecksOverlapButJoinBeforeReturning() throws {
        let lockEntered = DispatchSemaphore(value: 0), displayEntered = DispatchSemaphore(value: 0)
        let result = try NativeCaptureChecks.read { arguments in
            if arguments.last == "lockState" {
                lockEntered.signal()
                XCTAssertEqual(displayEntered.wait(timeout: .now() + 1), .success)
                return ["passcodeRequired": false]
            }
            displayEntered.signal()
            XCTAssertEqual(lockEntered.wait(timeout: .now() + 1), .success)
            return self.display()
        }
        XCTAssertEqual(result.display.pixelWidth, 12)
        XCTAssertEqual(Set(result.timings.keys), ["lock", "display"])
    }
    func testMissingLockedOrInactiveChecksCannotYieldObservation() throws {
        for state: [String: Any] in [[:], ["passcodeRequired": true]] {
            XCTAssertThrowsError(try NativeCaptureChecks.read { $0.last == "lockState" ? state : self.display() })
        }
        XCTAssertThrowsError(try NativeCaptureChecks.read {
            $0.last == "lockState" ? ["passcodeRequired": false] : self.display(backlight: "off")
        })
        XCTAssertThrowsError(try NativeCaptureChecks.read { arguments in
            if arguments.last == "displays" { throw IPhoneUseError("test", "display read failed") }
            return ["passcodeRequired": false]
        })
    }
    private final class State {
        let lock = NSLock()
        var screenshots = 0
        var finalPhase = false
    }
    func testAppleRetainsPostCaptureLockGeometryAndCancellationGuards() throws {
        let png = try screenPNG(width: 12, height: 18)
        for changed in ["locked", "rotated", "off", "cancelled", "none"] {
            let state = State(), cancellation = NativeCancellation()
            let cli = AppleDeviceCLI(device: "fixture", cancellation: cancellation, reader: { arguments in
                state.lock.lock(); defer { state.lock.unlock() }
                if arguments.last == "lockState" { return ["passcodeRequired": state.finalPhase && changed == "locked"] }
                if arguments.last == "displays" {
                    return self.display(state.finalPhase && changed == "rotated" ? "rot90" : "rot0",
                        backlight: state.finalPhase && changed == "off" ? "off" : "activeOn")
                }
                state.screenshots += 1
                try png.write(to: URL(fileURLWithPath: try XCTUnwrap(arguments.last)))
                state.finalPhase = true
                if changed == "cancelled" { cancellation.cancel() }
                return [:]
            })
            let capture = { try cli.capture(generation: "fixture", validateDisplay: { _, _ in
                return [:]
            }) }
            if changed == "none" {
                let result = try capture()
                XCTAssertEqual(result.metadata["captureSource"] as? String, "coredevice_screenshot")
                XCTAssertEqual(result.screenshot, png)
            } else { XCTAssertThrowsError(try capture(), changed) }
            XCTAssertEqual(state.screenshots, 1)
        }
    }

    func testAppleOnlyIgnoresMediaPixelsAndRetainsGeometryGuard() throws {
        let png = try screenPNG(width: 12, height: 18), state = State()
        let cli = AppleDeviceCLI(device: "fixture", cancellation: NativeCancellation(), reader: { arguments in
            if arguments.last == "lockState" { return ["passcodeRequired": false] }
            if arguments.last == "displays" { return self.display() }
            state.screenshots += 1
            try png.write(to: URL(fileURLWithPath: try XCTUnwrap(arguments.last)))
            return [:]
        })
        var geometryChecks = 0
        for verification in ["owned_media_geometry", "observation_only"] {
            let capture = try cli.capture(generation: "fixture", validateDisplay: { _, _ in
                geometryChecks += 1
                return ["verification": verification]
            })
            XCTAssertEqual(capture.screenshot, png)
            XCTAssertEqual(capture.metadata["captureSource"] as? String, "coredevice_screenshot")
            XCTAssertEqual((capture.metadata["captureSourcePolicy"] as? [String: Any])?["strategy"] as? String, "coredevice_only")
            XCTAssertNil(capture.metadata["mediaSnapshot"])
        }
        XCTAssertEqual(geometryChecks, 2)
        for code in ["native_snapshot_geometry_unavailable", "native_snapshot_freshness_unavailable"] {
            XCTAssertThrowsError(try cli.capture(generation: "fixture", validateDisplay: { _, _ in
                throw IPhoneUseError(code, "Unverified orientation")
            }))
        }
        XCTAssertEqual(state.screenshots, 2, "Geometry must be verified before PNG acquisition")
    }

    func testApplePreflightRejectsRealChangesAndForeignSource() throws {
        let baseline = try screenPNG(width: 12, height: 18)
        var applePNG = baseline
        let cli = AppleDeviceCLI(device: "fixture", cancellation: NativeCancellation(), reader: { arguments in
            if arguments.last == "lockState" { return ["passcodeRequired": false] }
            if arguments.last == "displays" { return self.display() }
            try applePNG.write(to: URL(fileURLWithPath: try XCTUnwrap(arguments.last)))
            return [:]
        })
        let display = try NativeDisplay(display())
        let guardValue = try ScreenGuard(png: baseline, context: display.context, rects: [display.screen], policy: .init())
        func preflight(_ source: String) throws -> ScreenGuard.Check {
            try NativeInputPreflight.check(guard: guardValue, displayID: display.id, captureSource: source,
                deadline: 8, maximumCaptures: 1, now: { 0 }) {
                    try cli.capture(generation: "fixture", validateDisplay: { _, _ in [:] })
                }.0
        }
        XCTAssertTrue(try preflight("coredevice_screenshot").accepted)
        XCTAssertThrowsError(try preflight("native_media")) {
            let failure = $0 as? ActionFailure
            XCTAssertEqual(failure?.possiblyExecuted, false)
            XCTAssertEqual(failure?.result?["captureSourceChanged"] as? Bool, true)
            XCTAssertEqual(failure?.rejectedCapture?.screenshot, applePNG)
        }
        applePNG = try screenPNG(width: 12, height: 18, patches: [(CGRect(x: 0, y: 0, width: 6, height: 9), [0,0,0])])
        XCTAssertThrowsError(try preflight("coredevice_screenshot")) {
            XCTAssertEqual(($0 as? ActionFailure)?.possiblyExecuted, false)
            XCTAssertEqual(($0 as? ActionFailure)?.rejectedCapture?.screenshot, applePNG)
        }
    }

    func testInvalidApplePixelsCannotBecomeObservations() throws {
        let black = try screenPNG(width: 12, height: 18, patches: [(CGRect(x: 0, y: 0, width: 12, height: 18), [0,0,0])])
        for png in [Data("broken PNG".utf8), black, try screenPNG(width: 18, height: 12)] {
            var screenshots = 0
            let cli = AppleDeviceCLI(device: "fixture", cancellation: NativeCancellation(), reader: { arguments in
                if arguments.last == "lockState" { return ["passcodeRequired": false] }
                if arguments.last == "displays" { return self.display() }
                screenshots += 1
                try png.write(to: URL(fileURLWithPath: try XCTUnwrap(arguments.last)))
                return [:]
            })
            XCTAssertThrowsError(try cli.capture(generation: "fixture"))
            XCTAssertEqual(screenshots, 1)
        }
    }

    func testAppleFailureDoesNotSwitchPinnedSourceAndLockStopsAllPixelAcquisition() throws {
        var locked = false, screenshots = 0
        let cli = AppleDeviceCLI(device: "fixture", cancellation: NativeCancellation(), reader: { arguments in
            if arguments.last == "lockState" { return ["passcodeRequired": locked] }
            if arguments.last == "displays" { return self.display() }
            screenshots += 1
            throw IPhoneUseError("fixture", "Apple screenshot failed")
        })
        XCTAssertEqual(cli.captureSourcePolicy["strategy"] as? String, "coredevice_only")
        XCTAssertThrowsError(try cli.capture(generation: "fixture", validateDisplay: { _, _ in [:] }))
        XCTAssertEqual(screenshots, 1)
        XCTAssertThrowsError(try cli.capture(generation: "fixture", validateDisplay: { _, _ in [:] }))
        XCTAssertThrowsError(try cli.capture(generation: "fixture", validateDisplay: { _, _ in [:] }))
        locked = true
        XCTAssertThrowsError(try cli.capture(generation: "fixture", validateDisplay: { _, _ in
            XCTFail("Locked capture must stop before acquiring pixels"); return [:]
        }))
        XCTAssertEqual(screenshots, 3)
    }

    private func pixels(width: Int = 16, height: Int = 24) throws -> CVPixelBuffer {
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pixels), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixels)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 0, CVPixelBufferGetBytesPerRow(buffer) * height)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
    func testFreshnessRejectsCacheQueueDelayAndFutureTimestamps() throws {
        let pixels = try pixels()
        func fresh(_ start: Double, _ end: Double, now: Double = 10.2) -> Bool {
            NativeVideoSnapshot.isFresh(.init(image: NativeDecodedVideoFrame(pixels: pixels, nativeWidth: 12, nativeHeight: 18), firstPacketAt: start, completedAt: end, timestamp: 1), after: 10, now: now)
        }
        XCTAssertTrue(fresh(10.01, 10.1))
        XCTAssertFalse(fresh(9.99, 10.1)) // old partial unit, newly completed
        XCTAssertFalse(fresh(10.01, 10.1, now: 10.6)) // decoder/consumer backlog
        XCTAssertFalse(fresh(10.1, 10.01))
        XCTAssertFalse(fresh(10.1, 10.3))
        let stream = NativeVideoSnapshot(), cancellation = NativeCancellation()
        XCTAssertNil(try stream.frame(after: 0, timeout: 0, cancellation: cancellation))
        cancellation.cancel()
        XCTAssertThrowsError(try stream.frame(after: 0, cancellation: cancellation))
        stream.close()
        XCTAssertNil(try stream.frame(after: 0, cancellation: NativeCancellation()))
    }
    func testIndependentGeometrySupportsBothLandscapeAxes() throws {
        let frame = NativeVideoSnapshot.Frame(image: NativeDecodedVideoFrame(pixels: try pixels(), nativeWidth: 12, nativeHeight: 18),
                                             firstPacketAt: 1, completedAt: 1.1, timestamp: 1)
        for rotation in ["rot0", "rot90", "rot270"] {
            let size = try NativeSnapshotImage.validateGeometry(frame, display: NativeDisplay(display(rotation)))
            XCTAssertEqual(size.width, 12)
            XCTAssertEqual(size.height, 18)
        }
    }

    func testGeometryAcceptsDecoderYUVWithoutAcceptingWrongNativeDimensions() throws {
        for format in [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_OneComponent8] {
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 16, 24, format, nil, &buffer), kCVReturnSuccess)
            let pixels = try XCTUnwrap(buffer)
            let image = NativeDecodedVideoFrame(pixels: pixels, nativeWidth: 12, nativeHeight: 18)
            if format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
                XCTAssertNoThrow(try NativeSnapshotImage.validateNativeRectangle(image, width: 12, height: 18))
            } else {
                XCTAssertThrowsError(try NativeSnapshotImage.validateNativeRectangle(image, width: 12, height: 18))
            }
            XCTAssertThrowsError(try NativeSnapshotImage.validateNativeRectangle(image, width: 18, height: 12))
        }
    }
}
