@testable import IPhoneUseRunnerSupport
import XCTest
import CoreVideo
import ImageIO
@testable import IPhoneUseCore

extension NativeCaptureTests {

    func testApplePreflightRejectsRealChangesAndForeignSource() throws {
        let baseline = try screenPNG(width: 12, height: 18)
        var applePNG = baseline
        let cli = AppleDeviceCLI(
            device: "fixture", cancellation: NativeCancellation(),
            reader: { arguments in
                if arguments.last == "lockState" { return ["passcodeRequired": false] }
                if arguments.last == "displays" { return self.display() }
                try applePNG.write(to: URL(fileURLWithPath: try XCTUnwrap(arguments.last)))
                return [:]
            })
        let display = try NativeDisplay(display())
        let guardValue = try ScreenGuard(
            png: baseline, context: display.context, rects: [display.screen], policy: .init())
        func preflight(_ source: String) throws -> ScreenGuard.Check {
            try NativeInputPreflight.check(
                guard: guardValue, displayID: display.id, captureSource: source,
                deadline: 8, maximumCaptures: 1, now: { 0 },
                capture: {
                    try cli.capture(generation: "fixture", validateDisplay: { _, _ in [:] })
                }
            ).0
        }
        XCTAssertTrue(try preflight("coredevice_screenshot").accepted)
        XCTAssertThrowsError(try preflight("native_media")) {
            let failure = $0 as? ActionFailure
            XCTAssertEqual(failure?.possiblyExecuted, false)
            XCTAssertEqual(failure?.result?["captureSourceChanged"] as? Bool, true)
            XCTAssertEqual(failure?.rejectedCapture?.screenshot, applePNG)
        }
        applePNG = try screenPNG(
            width: 12, height: 18, patches: [(CGRect(x: 0, y: 0, width: 6, height: 9), [0, 0, 0])])
        XCTAssertThrowsError(try preflight("coredevice_screenshot")) {
            XCTAssertEqual(($0 as? ActionFailure)?.possiblyExecuted, false)
            XCTAssertEqual(($0 as? ActionFailure)?.rejectedCapture?.screenshot, applePNG)
        }
    }

    func testInvalidApplePixelsCannotBecomeObservations() throws {
        let black = try screenPNG(
            width: 12, height: 18, patches: [(CGRect(x: 0, y: 0, width: 12, height: 18), [0, 0, 0])])
        for png in [Data("broken PNG".utf8), black, try screenPNG(width: 18, height: 12)] {
            var screenshots = 0
            let cli = AppleDeviceCLI(
                device: "fixture", cancellation: NativeCancellation(),
                reader: { arguments in
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
        let cli = AppleDeviceCLI(
            device: "fixture", cancellation: NativeCancellation(),
            reader: { arguments in
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
        XCTAssertThrowsError(
            try cli.capture(
                generation: "fixture",
                validateDisplay: { _, _ in
                    XCTFail("Locked capture must stop before acquiring pixels"); return [:]
                }))
        XCTAssertEqual(screenshots, 3)
    }
    func testFreshnessRejectsCacheQueueDelayAndFutureTimestamps() throws {
        let pixels = try pixels()
        func fresh(_ start: Double, _ end: Double, now: Double = 10.2) -> Bool {
            NativeVideoSnapshot.isFresh(
                .init(
                    image: NativeDecodedVideoFrame(pixels: pixels, nativeWidth: 12, nativeHeight: 18),
                    firstPacketAt: start, completedAt: end, timestamp: 1), after: 10, now: now)
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
        let frame = NativeVideoSnapshot.Frame(
            image: NativeDecodedVideoFrame(pixels: try pixels(), nativeWidth: 12, nativeHeight: 18),
            firstPacketAt: 1, completedAt: 1.1, timestamp: 1)
        for rotation in ["rot0", "rot90", "rot270"] {
            let size = try NativeSnapshotImage.validateGeometry(
                frame, display: NativeDisplay(display(rotation)))
            XCTAssertEqual(size.width, 12)
            XCTAssertEqual(size.height, 18)
        }
    }

    func testGeometryAcceptsDecoderYUVWithoutAcceptingWrongNativeDimensions() throws {
        for format in [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_OneComponent8] {
            var buffer: CVPixelBuffer?
            XCTAssertEqual(
                CVPixelBufferCreate(kCFAllocatorDefault, 16, 24, format, nil, &buffer), kCVReturnSuccess)
            let pixels = try XCTUnwrap(buffer)
            let image = NativeDecodedVideoFrame(pixels: pixels, nativeWidth: 12, nativeHeight: 18)
            if format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
                XCTAssertNoThrow(
                    try NativeSnapshotImage.validateNativeRectangle(image, width: 12, height: 18))
            } else {
                XCTAssertThrowsError(
                    try NativeSnapshotImage.validateNativeRectangle(image, width: 12, height: 18))
            }
            XCTAssertThrowsError(
                try NativeSnapshotImage.validateNativeRectangle(image, width: 18, height: 12))
        }
    }

    func testGeometryAcceptsFourRowHeightAlignmentWithoutAcceptingOtherMismatches() throws {
        let buffer = try pixels(width: 1216, height: 2656)
        let padded = NativeDecodedVideoFrame(pixels: buffer, nativeWidth: 1206, nativeHeight: 2624)
        XCTAssertNoThrow(try NativeSnapshotImage.validateNativeRectangle(padded, width: 1206, height: 2622))
        for (width, height) in [(1204, 2622), (1206, 2620), (1206, 2623), (1206, 2626)] {
            XCTAssertThrowsError(
                try NativeSnapshotImage.validateNativeRectangle(padded, width: width, height: height))
        }
        for height in [2620, 2623, 2626] {
            let wrong = NativeDecodedVideoFrame(pixels: buffer, nativeWidth: 1206, nativeHeight: height)
            XCTAssertThrowsError(
                try NativeSnapshotImage.validateNativeRectangle(wrong, width: 1206, height: 2622))
        }
        let undersized = NativeDecodedVideoFrame(
            pixels: try pixels(width: 1216, height: 2622), nativeWidth: 1206, nativeHeight: 2624)
        XCTAssertThrowsError(
            try NativeSnapshotImage.validateNativeRectangle(undersized, width: 1206, height: 2622))
    }
}
