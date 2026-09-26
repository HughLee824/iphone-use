import XCTest
import CoreVideo
import ImageIO
@testable import IPhoneUseCore

final class NativeCaptureTests: XCTestCase {
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
    func testMediaObservationRetainsPostCaptureLockAndGeometryGuards() throws {
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
                XCTFail("Fresh media must not run the CLI screenshot command")
                return [:]
            })
            let capture = {
                try cli.capture(generation: "fixture", mediaCapture: { _, _ in
                    state.lock.lock(); state.finalPhase = true; state.lock.unlock()
                    if changed == "cancelled" { cancellation.cancel() }
                    return (png, ["freshness": "fixture"])
                })
            }
            if changed == "none" {
                let result = try capture()
                XCTAssertEqual(result.metadata["captureSource"] as? String, "native_media")
                XCTAssertEqual(result.screenshot, png)
            } else { XCTAssertThrowsError(try capture()) }
            XCTAssertEqual(state.screenshots, 0)
        }
    }
    func testUnavailableMediaUsesFreshAppleScreenshotAndKeepsReason() throws {
        let png = try screenPNG(width: 12, height: 18), state = State()
        let cli = AppleDeviceCLI(device: "fixture", cancellation: NativeCancellation(), reader: { arguments in
            state.lock.lock(); defer { state.lock.unlock() }
            if arguments.last == "lockState" { return ["passcodeRequired": false] }
            if arguments.last == "displays" { return self.display() }
            state.screenshots += 1
            try png.write(to: URL(fileURLWithPath: try XCTUnwrap(arguments.last)))
            return [:]
        })
        let capture = try cli.capture(generation: "fixture", mediaCapture: { _, _ in (nil, ["fallbackReason": "no_fresh_complete_frame"]) })
        XCTAssertEqual(state.screenshots, 1)
        XCTAssertEqual(capture.metadata["captureSource"] as? String, "coredevice_screenshot")
        XCTAssertEqual((capture.metadata["mediaSnapshot"] as? [String: String])?["fallbackReason"], "no_fresh_complete_frame")
        XCTAssertEqual(capture.screenshot, png)
        var geometryChecked = false
        let preferred = try cli.capture(generation: "fixture", preferredSource: "coredevice_screenshot", mediaCapture: { _, _ in
            geometryChecked = true
            return (png, [:])
        })
        XCTAssertTrue(geometryChecked)
        XCTAssertEqual(state.screenshots, 2)
        for source: String? in [nil, "coredevice_screenshot"] {
            XCTAssertThrowsError(try cli.capture(generation: "fixture", preferredSource: source, mediaCapture: { _, _ in
                throw IPhoneUseError("native_snapshot_geometry_unavailable", "Conflicting axes")
            }))
        }
        XCTAssertEqual(state.screenshots, 2, "Conflicting media geometry must never fall back to a possibly inverted Apple PNG")
        XCTAssertEqual(preferred.metadata["captureSource"] as? String, "coredevice_screenshot")
    }
    func testSessionDowngradePersistsAcrossFreshMediaAndPreflightWithoutWeakeningGuard() throws {
        let baseline = try screenPNG(width: 12, height: 18)
        var applePNG = baseline, screenshots = 0, mediaChecks = 0
        let cli = AppleDeviceCLI(device: "fixture", cancellation: NativeCancellation(), reader: { arguments in
            if arguments.last == "lockState" { return ["passcodeRequired": false] }
            if arguments.last == "displays" { return self.display() }
            screenshots += 1
            try applePNG.write(to: URL(fileURLWithPath: try XCTUnwrap(arguments.last)))
            return [:]
        })
        func capture(_ fresh: Bool, preferred: String? = nil) throws -> CapturedObservation {
            try cli.capture(generation: "fixture", preferredSource: preferred, mediaCapture: { _, _ in
                mediaChecks += 1
                return (fresh ? baseline : nil, fresh ? [:] : ["fallbackReason": "no_fresh_complete_frame"])
            })
        }
        let first = try capture(true), display = try NativeDisplay(display())
        let guardValue = try ScreenGuard(png: first.screenshot, context: display.context, rects: [display.screen], policy: .init())
        XCTAssertEqual(first.metadata["captureSource"] as? String, "native_media")
        XCTAssertEqual(cli.captureSourcePolicy["strategy"] as? String, "prefer_media")
        XCTAssertThrowsError(try NativeInputPreflight.check(guard: guardValue, displayID: display.id,
            captureSource: "native_media", deadline: 8, maximumCaptures: 3, now: { 0 }) { try capture(false) }) {
            let failure = $0 as? ActionFailure
            XCTAssertEqual(failure?.possiblyExecuted, false)
            XCTAssertEqual(failure?.result?["captureSourceChanged"] as? Bool, true)
            XCTAssertEqual(failure?.rejectedCapture?.metadata["captureSource"] as? String, "coredevice_screenshot")
        }
        // The agent's next observation, action preflight and post-action
        // observation all keep Apple pixels even when video resumes.
        for preferred: String? in [nil, "coredevice_screenshot", "native_media", nil] {
            let frame = try capture(true, preferred: preferred)
            XCTAssertEqual(frame.metadata["captureSource"] as? String, "coredevice_screenshot")
            XCTAssertEqual((frame.metadata["captureSourcePolicy"] as? [String: Any])?["strategy"] as? String, "coredevice_only")
        }
        XCTAssertTrue(try NativeInputPreflight.check(guard: guardValue, displayID: display.id,
            captureSource: "coredevice_screenshot", deadline: 8, maximumCaptures: 1, now: { 0 }) { try capture(true) }.0.accepted)
        applePNG = try screenPNG(width: 12, height: 18, patches: [(CGRect(x: 0, y: 0, width: 6, height: 9), [0, 0, 0])])
        XCTAssertThrowsError(try NativeInputPreflight.check(guard: guardValue, displayID: display.id,
            captureSource: "coredevice_screenshot", deadline: 8, maximumCaptures: 1, now: { 0 }) { try capture(true) }) {
            let failure = $0 as? ActionFailure
            XCTAssertEqual(failure?.possiblyExecuted, false)
            XCTAssertEqual(failure?.rejectedCapture?.screenshot, applePNG)
            XCTAssertEqual((failure?.result?["screenGuard"] as? [String: Any])?["accepted"] as? Bool, false)
        }
        XCTAssertEqual(mediaChecks, 8, "Pinned Apple capture must still validate media geometry")
        XCTAssertEqual(screenshots, 7)
        XCTAssertEqual(cli.captureSourcePolicy["fallbackReason"] as? String, "no_fresh_complete_frame")
        let nextSession = AppleDeviceCLI(device: "fixture", cancellation: NativeCancellation(), reader: { arguments in
            arguments.last == "lockState" ? ["passcodeRequired": false] : self.display()
        })
        XCTAssertEqual(try nextSession.capture(generation: "new", mediaCapture: { _, _ in (baseline, [:]) }).metadata["captureSource"] as? String, "native_media")
    }

    func testFailedFallbackDoesNotPinSessionAndPinnedCaptureStillChecksLock() throws {
        let png = try screenPNG(width: 12, height: 18)
        var locked = false, screenshots = 0
        let cli = AppleDeviceCLI(device: "fixture", cancellation: NativeCancellation(), reader: { arguments in
            if arguments.last == "lockState" { return ["passcodeRequired": locked] }
            if arguments.last == "displays" { return self.display() }
            screenshots += 1
            if screenshots == 1 { throw IPhoneUseError("fixture", "Apple screenshot failed") }
            try png.write(to: URL(fileURLWithPath: try XCTUnwrap(arguments.last)))
            return [:]
        })
        XCTAssertThrowsError(try cli.capture(generation: "fixture"))
        XCTAssertEqual(cli.captureSourcePolicy["strategy"] as? String, "prefer_media")
        _ = try cli.capture(generation: "fixture")
        XCTAssertEqual(cli.captureSourcePolicy["strategy"] as? String, "coredevice_only")
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
