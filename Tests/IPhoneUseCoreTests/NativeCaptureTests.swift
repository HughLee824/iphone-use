import XCTest
import CoreVideo
import ImageIO
@testable import IPhoneUseCore

final class NativeCaptureTests: XCTestCase {
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
            return try cli.capture(generation: "fixture", mediaCapture: { display, _ in
                _ = try NativeSnapshotImage.validateGeometry(nil, display: display)
                return (nil, [:])
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
                XCTAssertEqual(($0 as? IPhoneUseError)?.code, "native_orientation_unverified")
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
    func testBothSourcesRetainPostCaptureLockGeometryAndCancellationGuards() throws {
        let png = try screenPNG(width: 12, height: 18)
        for source in ["native_media", "coredevice_screenshot"] {
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
                let capture = { try cli.capture(generation: "fixture", preferredSource: source, mediaCapture: { _, _ in
                    if source == "native_media" {
                        state.lock.lock(); state.finalPhase = true; state.lock.unlock()
                        if changed == "cancelled" { cancellation.cancel() }
                    }
                    return (png, [:])
                }) }
                if changed == "none" {
                    let result = try capture()
                    XCTAssertEqual(result.metadata["captureSource"] as? String, source)
                    XCTAssertEqual(result.screenshot, png)
                } else { XCTAssertThrowsError(try capture(), "\(source) \(changed)") }
                XCTAssertEqual(state.screenshots, source == "native_media" ? 0 : 1)
            }
        }
    }

    func testMediaFirstHonorsPinnedSourceAndGeometryStillGatesAppleFallback() throws {
        let png = try screenPNG(width: 12, height: 18), state = State()
        let cli = AppleDeviceCLI(device: "fixture", cancellation: NativeCancellation(), reader: { arguments in
            if arguments.last == "lockState" { return ["passcodeRequired": false] }
            if arguments.last == "displays" { return self.display() }
            state.screenshots += 1
            try png.write(to: URL(fileURLWithPath: try XCTUnwrap(arguments.last)))
            return [:]
        })
        let mediaPNG = try screenPNG(width: 12, height: 18, patches: [(CGRect(x: 0, y: 0, width: 6, height: 9), [0,0,0])])
        var geometryChecks = 0
        for preferred: String? in [nil, "native_media", "coredevice_screenshot"] {
            for available in [true, false] {
                let capture = try cli.capture(generation: "fixture", preferredSource: preferred, mediaCapture: { _, _ in
                    geometryChecks += 1
                    return (available ? mediaPNG : nil, ["geometryValidated": true])
                })
                let usesMedia = available && preferred != "coredevice_screenshot"
                XCTAssertEqual(capture.screenshot, usesMedia ? mediaPNG : png)
                XCTAssertEqual(capture.metadata["captureSource"] as? String, usesMedia ? "native_media" : "coredevice_screenshot")
                XCTAssertEqual((capture.metadata["captureSourcePolicy"] as? [String: Any])?["strategy"] as? String, "media_first")
                if preferred == "coredevice_screenshot" {
                    XCTAssertEqual((capture.metadata["mediaSnapshot"] as? [String: Any])?["fallbackReason"] as? String, "source_pinned")
                }
            }
        }
        XCTAssertEqual(geometryChecks, 6)
        XCTAssertEqual(state.screenshots, 4)
        for preferred: String? in [nil, "coredevice_screenshot"] {
            for code in ["native_snapshot_geometry_unavailable", "native_snapshot_freshness_unavailable"] {
                XCTAssertThrowsError(try cli.capture(generation: "fixture", preferredSource: preferred, mediaCapture: { _, _ in
                    throw IPhoneUseError(code, "Unverified orientation")
                }))
            }
        }
        XCTAssertEqual(state.screenshots, 4, "Unverified geometry cannot fall back to a possibly inverted PNG")
    }

    func testPinnedPreflightRejectsRealChangesAndMediaToAppleFallback() throws {
        let baseline = try screenPNG(width: 12, height: 18)
        var applePNG = baseline, mediaPNG: Data? = baseline
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
                    try cli.capture(generation: "fixture", preferredSource: source, mediaCapture: { _, _ in (mediaPNG, [:]) })
                }.0
        }
        XCTAssertTrue(try preflight("native_media").accepted)
        XCTAssertTrue(try preflight("coredevice_screenshot").accepted)
        mediaPNG = nil
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

    func testInvalidMediaPixelsFallbackButDimensionsDoNot() throws {
        let png = try screenPNG(width: 12, height: 18)
        var screenshots = 0
        let cli = AppleDeviceCLI(device: "fixture", cancellation: NativeCancellation(), reader: { arguments in
            if arguments.last == "lockState" { return ["passcodeRequired": false] }
            if arguments.last == "displays" { return self.display() }
            screenshots += 1
            try png.write(to: URL(fileURLWithPath: try XCTUnwrap(arguments.last)))
            return [:]
        })
        let black = try screenPNG(width: 12, height: 18, patches: [(CGRect(x: 0, y: 0, width: 12, height: 18), [0,0,0])])
        for candidate in [Data("broken PNG".utf8), black] {
            let result = try cli.capture(generation: "fixture", mediaCapture: { _, _ in (candidate, ["geometryValidated": true]) })
            XCTAssertEqual(result.screenshot, png)
            XCTAssertEqual(result.metadata["captureSource"] as? String, "coredevice_screenshot")
            XCTAssertEqual((result.metadata["mediaSnapshot"] as? [String: Any])?["fallbackReason"] as? String, "media_image_invalid")
        }
        let wrongSize = try screenPNG(width: 18, height: 12)
        XCTAssertThrowsError(try cli.capture(generation: "fixture", mediaCapture: { _, _ in (wrongSize, [:]) })) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "native_snapshot_geometry_unavailable")
        }
        XCTAssertEqual(screenshots, 2)
    }

    func testAppleFailureDoesNotSwitchPinnedSourceAndLockStopsAllPixelAcquisition() throws {
        let png = try screenPNG(width: 12, height: 18)
        var locked = false, screenshots = 0
        let cli = AppleDeviceCLI(device: "fixture", cancellation: NativeCancellation(), reader: { arguments in
            if arguments.last == "lockState" { return ["passcodeRequired": locked] }
            if arguments.last == "displays" { return self.display() }
            screenshots += 1
            throw IPhoneUseError("fixture", "Apple screenshot failed")
        })
        XCTAssertEqual(cli.captureSourcePolicy["strategy"] as? String, "media_first")
        XCTAssertNoThrow(try cli.capture(generation: "fixture", mediaCapture: { _, _ in (png, [:]) }))
        XCTAssertEqual(screenshots, 0)
        XCTAssertThrowsError(try cli.capture(generation: "fixture", preferredSource: "coredevice_screenshot", mediaCapture: { _, _ in (png, [:]) }))
        XCTAssertThrowsError(try cli.capture(generation: "fixture", mediaCapture: { _, _ in (nil, [:]) }))
        locked = true
        XCTAssertThrowsError(try cli.capture(generation: "fixture", mediaCapture: { _, _ in
            XCTFail("Locked capture must stop before acquiring pixels"); return (png, [:])
        }))
        XCTAssertEqual(screenshots, 2)
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
            NativeVideoSnapshot.isFresh(.init(pixels: pixels, firstPacketAt: start, completedAt: end, timestamp: 1), after: 10, now: now)
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
    func testPaddingCropAndBothRotationsKeepCornerCoordinates() throws {
        let pixels = try pixels()
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        for y in 0..<18 { for x in 0..<12 {
            let i = y * stride + x * 4
            // Unique corner colors in BGRA: red/green/blue/white.
            base[i] = y >= 9 ? 255 : 0
            base[i + 1] = x >= 6 ? 255 : 0
            base[i + 2] = y < 9 && x < 6 || y >= 9 && x >= 6 ? 255 : 0
            base[i + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        let frame = NativeVideoSnapshot.Frame(pixels: pixels, firstPacketAt: 1, completedAt: 1.1, timestamp: 1)
        for (rotation, expected): (String, [[UInt8]]) in [
            ("rot0", [[255,0,0], [0,255,0], [0,0,255], [255,255,255]]),
            ("rot90", [[0,0,255], [255,0,0], [255,255,255], [0,255,0]]),
            ("rot270", [[0,255,0], [255,255,255], [255,0,0], [0,0,255]])] {
            let geometry = try NativeDisplay(display(rotation))
            let (png, _) = try NativeSnapshotImage.png(frame, display: geometry)
            let image = try ScreenImage(png: png)
            XCTAssertEqual(image.image.width, Int(geometry.pixelWidth))
            XCTAssertEqual(image.image.height, Int(geometry.pixelHeight))
            for (index, point) in [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)].enumerated() {
                let rect = ScreenRect(CGRect(x: geometry.screen.width * point.0, y: geometry.screen.height * point.1,
                                            width: 1.0 / 3, height: 1.0 / 3))
                let color = try image.rgb(rect: rect, screen: geometry.screen, columns: 1, rows: 1)
                XCTAssertEqual(Array(color), expected[index], "\(rotation) corner \(index)")
            }
        }
        CVPixelBufferLockBaseAddress(pixels, [])
        base[12 * 4] = 255 // content in the excluded right edge
        CVPixelBufferUnlockBaseAddress(pixels, [])
        XCTAssertThrowsError(try NativeSnapshotImage.png(frame, display: NativeDisplay(display())))
    }
}
