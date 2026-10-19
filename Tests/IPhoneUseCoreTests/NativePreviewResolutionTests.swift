import XCTest
import CoreImage
@testable import IPhoneUseCore

final class NativePreviewResolutionTests: XCTestCase {
    private func pixels(activeWidth: Int, activeHeight: Int) throws -> CVPixelBuffer {
        var value: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 64, 128, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                          nil, &value), kCVReturnSuccess)
        let buffer = try XCTUnwrap(value)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let width = activeWidth * 48 / 64, height = activeHeight * 96 / 128
        let values: [UInt8] = [32, 80, 144, 208]
        for y in 0..<128 { for x in 0..<64 {
            luma[y * stride + x] = x < width && y < height ? values[(y < height / 2 ? 0 : 2) + (x < width / 2 ? 0 : 1)] : 235
        } }
        memset(CVPixelBufferGetBaseAddressOfPlane(buffer, 1), 128,
               CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * CVPixelBufferGetHeightOfPlane(buffer, 1))
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return buffer
    }

    private func display(_ rotation: String = "rot0") throws -> NativeDisplay {
        try NativeDisplay(["backlightState": "activeOn", "displays": [["primary": true, "displayId": 1,
            "bounds": [[0, 0], [48, 96]], "pointScale": 1, "currentOrientation": rotation, "nativeOrientation": "rot0"]]])
    }

    func testReducedNV12RestoresNativeAxesAndExcludesScaledPaddingInEveryOrientation() throws {
        let context = CIContext(options: [.useSoftwareRenderer: true])
        for (width, height) in [(64, 128), (32, 48), (48, 64)] {
            let buffer = try pixels(activeWidth: width, activeHeight: height)
            let frame = NativeVideoSnapshot.Frame(image: .init(pixels: buffer, nativeWidth: 48, nativeHeight: 96,
                activeWidth: width, activeHeight: height), firstPacketAt: 1, completedAt: 2, timestamp: 1)
            for (rotation, quadrants) in [("rot0", [0, 1, 2, 3]), ("rot90", [2, 0, 3, 1]), ("rot270", [1, 3, 0, 2])] {
                let data = try NativePreview.encode(frame, display: display(rotation), context: context)
                let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
                let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
                XCTAssertEqual(image.width, rotation == "rot0" ? 48 : 96)
                XCTAssertEqual(image.height, rotation == "rot0" ? 96 : 48)
                var rgb = [UInt8](repeating: 0, count: image.width * image.height * 4)
                try rgb.withUnsafeMutableBytes { bytes in
                    let output = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                        bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    output.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                }
                let expected = [19, 75, 149, 224]
                // Near-edge points catch scaled padding; interior points catch
                // incorrect stretching of the whole active rectangle.
                for (insetX, insetY) in [(3, 3), (image.width / 4, image.height / 4)] {
                    for (index, point) in [(insetX, insetY), (image.width - 1 - insetX, insetY),
                        (insetX, image.height - 1 - insetY), (image.width - 1 - insetX, image.height - 1 - insetY)].enumerated() {
                        let offset = (point.1 * image.width + point.0) * 4
                        XCTAssertEqual(Double(rgb[offset]), Double(expected[quadrants[index]]), accuracy: 25,
                                       "\(width)x\(height) \(rotation) corner \(index)")
                    }
                }
                if frame.image.isReducedResolution {
                    XCTAssertThrowsError(try NativeSnapshotImage.validateGeometry(frame, display: display(rotation)))
                }
            }
        }
    }

    func testInvalidActiveRectangleAndConflictingOrientationAreRejected() throws {
        let buffer = try pixels(activeWidth: 64, activeHeight: 128)
        for (width, height) in [(0, 48), (32, -16), (80, 128), (64, 144), (31, 48)] {
            let frame = NativeVideoSnapshot.Frame(image: .init(pixels: buffer, nativeWidth: 48, nativeHeight: 96,
                activeWidth: width, activeHeight: height), firstPacketAt: 1, completedAt: 2, timestamp: 1)
            XCTAssertThrowsError(try NativePreview.encode(frame, display: display()))
        }
        let frame = NativeVideoSnapshot.Frame(image: .init(pixels: buffer, nativeWidth: 48, nativeHeight: 96,
            activeWidth: 32, activeHeight: 48), firstPacketAt: 1, completedAt: 2, timestamp: 1, displayRotation: "rot90")
        XCTAssertThrowsError(try NativePreview.encode(frame, display: display()))
    }

    func testReducedFramesUpdatePreviewButNeverPrimeObservationOrRecording() throws {
        let buffer = try pixels(activeWidth: 64, activeHeight: 128)
        let full = NativeDecodedVideoFrame(pixels: buffer, nativeWidth: 48, nativeHeight: 96)
        let reduced = NativeDecodedVideoFrame(pixels: buffer, nativeWidth: 48, nativeHeight: 96, activeWidth: 32, activeHeight: 48)
        let stream = NativeVideoSnapshot(decode: { $0.timestamp == 2 ? reduced : full }, resetDecoder: {})
        defer { stream.close() }
        var recorded: [UInt32] = []
        stream.setRecordingHandler { recorded.append($0.timestamp) }
        let start = ProcessInfo.processInfo.systemUptime
        for sequence: UInt8 in [1, 2, 3] {
            stream.receive(Data([0x80, 0xe4, 0, sequence, 0, 0, 0, sequence, 0, 0, 0, 123,
                                 sequence == 1 ? 40 : 2, 1, 1]), at: ProcessInfo.processInfo.systemUptime)
            let done = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                stream.status()["pendingBytes"] as? Int == 0
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 2), .completed)
            XCTAssertEqual(stream.previewFrame(includeReducedResolution: true)?.timestamp, UInt32(sequence))
            if sequence == 2 {
                XCTAssertNil(stream.previewFrame(), "Recording preparation still requires full resolution")
                XCTAssertNil(try stream.frame(after: start, timeout: 0, cancellation: NativeCancellation()))
                stream.setRecordingHandler { recorded.append($0.timestamp) }
                XCTAssertEqual(recorded, [1], "Reduced seed must never enter the recording")
            }
        }
        XCTAssertEqual(recorded, [1, 3])
        XCTAssertEqual(stream.status()["decodedFrames"] as? Int, 2)
        XCTAssertEqual(stream.status()["previewDecodedFrames"] as? Int, 3)
        XCTAssertEqual(stream.status()["reducedResolutionFrames"] as? Int, 1)
        XCTAssertEqual(stream.status()["framesWithoutImage"] as? Int, 0)
        XCTAssertEqual((stream.status()["resolutionChanges"] as? [[String: Double]])?.count, 3)
        stream.close()
        XCTAssertNil(stream.previewFrame())
    }

    func testFreshReducedGeometryDoesNotRestartMediaOrSupplyObservationPixels() throws {
        let buffer = try pixels(activeWidth: 32, activeHeight: 48)
        let reduced = NativeDecodedVideoFrame(pixels: buffer, nativeWidth: 48, nativeHeight: 96,
                                             activeWidth: 32, activeHeight: 48)
        let stream = NativeVideoSnapshot(decode: { _ in reduced }, resetDecoder: {})
        defer { stream.close() }
        let png = try screenPNG(width: 48, height: 96)
        let cli = AppleDeviceCLI(device: "fixture", cancellation: NativeCancellation(), reader: { args in
            if args.contains("screenshot") {
                try png.write(to: URL(fileURLWithPath: try XCTUnwrap(args.last)))
                return [:]
            }
            if args.last == "lockState" { return ["passcodeRequired": false] }
            return ["backlightState": "activeOn", "displays": [["primary": true, "displayId": 1,
                "bounds": [[0, 0], [48, 96]], "pointScale": 1, "currentOrientation": "rot0", "nativeOrientation": "rot0"]]]
        })
        let observation = try NativeCaptureChecks.withOrientationRecovery(capture: { refreshed in
            XCTAssertFalse(refreshed)
            return try cli.capture(generation: "fixture", validateDisplay: { display, requestedAt in
                stream.receive(self.geometryPacket(1), at: ProcessInfo.processInfo.systemUptime)
                let frame = try stream.frame(after: requestedAt, timeout: 0.4,
                    includeReducedResolution: true, cancellation: NativeCancellation())
                XCTAssertTrue(try XCTUnwrap(frame).image.isReducedResolution)
                _ = try NativeSnapshotImage.validateGeometry(frame, display: display, allowReducedResolution: true)
                return ["geometryValidated": true]
            })
        }, resynchronize: { XCTFail("Valid fresh reduced geometry must not restart media"); return false })
        XCTAssertEqual(observation.screenshot, png, "Apple PNG remains the only observation pixel source")
        XCTAssertNil(observation.metadata["orientationRevalidated"])
        XCTAssertNil(stream.previewFrame(), "Recording preparation must still exclude reduced pixels")
    }

    func testReducedGeometryPreservesFreshnessBarrierAndRejectsConflicts() throws {
        let buffer = try pixels(activeWidth: 32, activeHeight: 48)
        let reduced = NativeDecodedVideoFrame(pixels: buffer, nativeWidth: 48, nativeHeight: 96,
                                             activeWidth: 32, activeHeight: 48)
        let stream = NativeVideoSnapshot(decode: { _ in reduced }, resetDecoder: {})
        let receiver = try NativeRTPReceiver(deviceAddress: "::1", captureSnapshots: true, makeSnapshots: { stream })
        defer { receiver.close() }
        let start = ProcessInfo.processInfo.systemUptime
        stream.receive(geometryPacket(1, profile: 0x92), at: start)
        let frame = try XCTUnwrap(stream.frame(after: start, timeout: 0.4,
            includeReducedResolution: true, cancellation: NativeCancellation()))
        XCTAssertNoThrow(try NativeSnapshotImage.validateGeometry(frame, display: display("rot270"), allowReducedResolution: true))
        XCTAssertThrowsError(try NativeSnapshotImage.validateGeometry(frame, display: display("rot90"), allowReducedResolution: true))
        XCTAssertThrowsError(try stream.rejectConflictingGeometry(display("rot90")), "Reduced frames retain half-turn conflict evidence")
        XCTAssertNil(try receiver.snapshot(after: start, timeout: 0, includeReducedResolution: true,
            cancellation: NativeCancellation()), "The socket barrier must exclude already decoded reduced frames")
        XCTAssertNil(try stream.frame(after: frame.completedAt + 1, timeout: 0,
            includeReducedResolution: true, cancellation: NativeCancellation()))
        XCTAssertNil(try stream.frame(after: start, timeout: 0, cancellation: NativeCancellation()))
        // Broken references cannot leave geometry usable, even when the last
        // valid reduced frame was very recent.
        stream.receive(geometryPacket(2, timestamp: 1), at: ProcessInfo.processInfo.systemUptime)
        let done = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            stream.status()["pendingBytes"] as? Int == 0
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 2), .completed)
        XCTAssertEqual(stream.status()["timestampRejections"] as? Int, 1)
        XCTAssertNil(try stream.frame(after: start, timeout: 0, includeReducedResolution: true, cancellation: NativeCancellation()))
        stream.close()
        XCTAssertNil(try stream.frame(after: start, timeout: 0, includeReducedResolution: true, cancellation: NativeCancellation()))
    }

    private func geometryPacket(_ sequence: UInt8, timestamp: UInt8? = nil, profile: UInt8 = 0x90) -> Data {
        Data([0x90, 0xe4, 0, sequence, 0, 0, 0, timestamp ?? sequence, 0, 0, 0, 123,
              profile, 1, 0, 1, 0, 0, 0, 0, 40, 1, 1])
    }
}
