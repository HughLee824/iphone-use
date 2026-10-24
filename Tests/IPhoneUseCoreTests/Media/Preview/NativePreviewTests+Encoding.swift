import XCTest
import CoreImage
@testable import IPhoneUseCore

extension NativePreviewTests {

    func testFractionalPreviewResizeDoesNotIntroduceBrightEdgesOrDecoderPadding() throws {
        var pixels: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(nil, 1184, 2544, kCVPixelFormatType_32BGRA, nil, &pixels), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixels)
        let frame = NativeVideoSnapshot.Frame(
            image: NativeDecodedVideoFrame(
                pixels: buffer, nativeWidth: 1170,
                nativeHeight: 2532), firstPacketAt: 1, completedAt: 2, timestamp: 1)
        let context = CIContext(options: [.useSoftwareRenderer: true])
        for green: UInt8 in [0, 200] {
            fillPaddedBuffer(buffer, green: green)
            for rotation in ["rot0", "rot90", "rot270"] {
                let display = try NativeDisplay([
                    "backlightState": "activeOn",
                    "displays": [
                        [
                            "primary": true,
                            "displayId": 1, "bounds": [[0, 0], [1170, 2532]], "pointScale": 1,
                            "currentOrientation": rotation, "nativeOrientation": "rot0"
                        ]
                    ]
                ])
                let data = try NativePreview.encode(frame, display: display, context: context)
                let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
                let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
                XCTAssertEqual(image.width, rotation == "rot0" ? 444 : 960)
                XCTAssertEqual(image.height, rotation == "rot0" ? 960 : 444)
                let rgba = try rgbaPixels(image)
                // Every border pixel: detects fractional alpha, resampling halo,
                // or padding leaking into any edge after either rotation.
                for row in 0..<image.height {
                    for column in 0..<image.width
                    where column == 0 || row == 0 || column == image.width - 1 || row == image.height - 1 {
                        let offset = (row * image.width + column) * 4
                        XCTAssertLessThan(rgba[offset], 15, "red edge: \(rotation), \(column),\(row)")
                        XCTAssertLessThan(
                            abs(Int(rgba[offset + 1]) - Int(green)), 15,
                            "green edge: \(rotation), \(column),\(row)")
                        XCTAssertLessThan(rgba[offset + 2], 15, "blue edge: \(rotation), \(column),\(row)")
                    }
                }
            }
        }
    }

    func testPreviewJPEGFromVideoRangePlanesPreservesQuadrantsAndPadding() throws {
        var pixels: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                nil, 1184, 2576, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixels)
        fillQuadrantPlanes(buffer)
        let frame = NativeVideoSnapshot.Frame(
            image: .init(pixels: buffer, nativeWidth: 1170, nativeHeight: 2532),
            firstPacketAt: 1, completedAt: 2, timestamp: 1)
        let context = CIContext(options: [.useSoftwareRenderer: true])
        for (rotation, quadrants) in [
            ("rot0", [0, 1, 2, 3]), ("rot90", [2, 0, 3, 1]), ("rot270", [1, 3, 0, 2])
        ] {
            let display = try NativeDisplay([
                "backlightState": "activeOn",
                "displays": [
                    [
                        "primary": true,
                        "displayId": 1, "bounds": [[0, 0], [1170, 2532]], "pointScale": 1,
                        "currentOrientation": rotation, "nativeOrientation": "rot0"
                    ]
                ]
            ])
            let data = try NativePreview.encode(frame, display: display, context: context)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.width, rotation == "rot0" ? 444 : 960)
            XCTAssertEqual(image.height, rotation == "rot0" ? 960 : 444)
            let rgb = try rgbaPixels(image)
            let expected = [19, 75, 149, 224]
            for (index, point) in [
                (2, 2), (image.width - 3, 2), (2, image.height - 3), (image.width - 3, image.height - 3)
            ].enumerated() {
                let offset = (point.1 * image.width + point.0) * 4
                for channel in 0..<3 {
                    XCTAssertEqual(
                        Double(rgb[offset + channel]), Double(expected[quadrants[index]]), accuracy: 25,
                        "\(rotation) corner \(index) must retain native pixels, not white decoder padding")
                }
            }
        }
        XCTAssertEqual(frame.timestamp, 1)
        XCTAssertEqual(CVPixelBufferGetWidth(buffer), 1184)
    }

    func testHalfTurnNeedsDistinctAgreementAndDoesNotGuessOnSymmetricFrames() {
        let upright = Data([255, 0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0])
        let inverted = Data([0, 0, 0, 0, 0, 255, 0, 255, 0, 255, 0, 0])
        XCTAssertTrue(NativePreviewOrientation.halfTurnConflict(reference: upright, preview: inverted))
        XCTAssertFalse(NativePreviewOrientation.halfTurnConflict(reference: upright, preview: upright))
        XCTAssertFalse(
            NativePreviewOrientation.halfTurnConflict(
                reference: Data(repeating: 0, count: 12), preview: Data(repeating: 0, count: 12)))
        XCTAssertFalse(
            NativePreviewOrientation.halfTurnConflict(
                reference: upright, preview: Data(repeating: 127, count: 12)))
        XCTAssertTrue(
            NativeCaptureChecks.needsOrientationRecovery(
                IPhoneUseError("native_screenshot_geometry_conflict", "fixture")))
        XCTAssertFalse(
            NativeCaptureChecks.needsOrientationRecovery(IPhoneUseError("invalid_image", "corrupt PNG")))
    }

    func testWaitingForNextFrameHasBoundedTimeout() throws {
        let preview = try NativePreview(port: 0); defer { preview.close() }
        let url = try XCTUnwrap(URL(string: preview.url + "frame?after=0"))
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(try get(url).0, 503)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertGreaterThanOrEqual(elapsed, 0.9)
        XCTAssertLessThan(elapsed, 2.5)
        XCTAssertEqual(preview.status()["maxFPS"] as? Int, 30)
    }

    func testVideoFramesDrivePreviewRegardlessOfBacklightAndQuietFramesAreRetained() throws {
        try withPreviewReceiver { receiver, send in
            let preview = try NativePreview(port: 0)
            defer { preview.close() }
            preview.attach(receiver, display: try previewDisplay(backlight: nil))
            XCTAssertEqual(preview.status()["state"] as? String, "waiting")
            send(1)
            let encoded = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    preview.status()["encodedFrames"] as? Int == 1
                }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [encoded], timeout: 2), .completed)
            let url = try XCTUnwrap(URL(string: preview.url + "frame"))
            let jpeg = try get(url)
            XCTAssertEqual(jpeg.0, 200)
            for state: String? in ["activeOn", "activeDimmed", "off", "inactive", "futureState", nil] {
                preview.attach(receiver, display: try previewDisplay(backlight: state))
                XCTAssertEqual(preview.status()["state"] as? String, "streaming")
                XCTAssertEqual(try get(url).1, jpeg.1, "Metadata alone must not clear a usable frame")
            }
            // Cross the initial-frame deadline without sending another frame.
            let quiet = expectation(description: "Quiet screen remains usable")
            DispatchQueue.global().asyncAfter(deadline: .now() + 3.2) { quiet.fulfill() }
            wait(for: [quiet], timeout: 4)
            XCTAssertEqual(preview.status()["state"] as? String, "streaming")
            XCTAssertEqual(preview.status()["encodedFrames"] as? Int, 1)
            XCTAssertEqual(try get(url).1, jpeg.1)
        }
    }
    func rgbaPixels(_ image: CGImage) throws -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try rgba.withUnsafeMutableBytes { bytes in
            let rgb = try XCTUnwrap(
                CGContext(
                    data: bytes.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            rgb.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return rgba
    }

    private func fillPaddedBuffer(_ buffer: CVPixelBuffer, green: UInt8) {
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<2544 {
            for column in 0..<1184 {
                let pixelIndex = base + row * stride + column * 4
                let native = column < 1170 && row < 2532
                pixelIndex[0] = native ? 0 : 255; pixelIndex[1] = native ? green : 0
                pixelIndex[2] = native ? 0 : 255; pixelIndex[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
    }

    private func fillQuadrantPlanes(_ buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let values: [UInt8] = [32, 80, 144, 208]
        for row in 0..<2576 {
            for column in 0..<1184 {
                luma[row * stride + column] =
                    column < 1170 && row < 2532 ? values[(row < 1266 ? 0 : 2) + (column < 585 ? 0 : 1)] : 235
            }
        }
        memset(
            CVPixelBufferGetBaseAddressOfPlane(buffer, 1), 128,
            CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * CVPixelBufferGetHeightOfPlane(buffer, 1))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        CVBufferSetAttachment(
            buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }

}
