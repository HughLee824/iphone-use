import XCTest
import CoreVideo
@testable import IPhoneUseCore

final class NativePaddingTests: XCTestCase {
    private func pixels(width: Int = 1184, height: Int = 2576) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault, width, height,
                kCVPixelFormatType_32BGRA, nil, &result), kCVReturnSuccess)
        let buffer = try XCTUnwrap(result)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer)!, 0, CVPixelBufferGetBytesPerRow(buffer) * height)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private func rejected(
        _ image: NativeDecodedVideoFrame, width: Int, height: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try NativeSnapshotImage.validateNativeRectangle(image, width: width, height: height),
            file: file, line: line
        ) {
            XCTAssertEqual(
                ($0 as? IPhoneUseError)?.code, "native_snapshot_geometry_unavailable", file: file, line: line)
        }
    }

    func testRecordedDenseEdgeShapeDoesNotInvalidateMatchingNativeRectangle() throws {
        // Synthetic analogue of the WeChat rejection: >202 right-edge pixels,
        // six pixels of extent and bottom amplitude >32. No private image data.
        let buffer = try pixels()
        CVPixelBufferLockBaseAddress(buffer, [])
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        for row in 0..<753 { base[row * stride + 1170 * 4] = 22 }
        base[100 * stride + 1175 * 4] = 10
        base[2532 * stride + 217 * 4] = 42
        let before = Data(bytes: base, count: stride * 2576)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let image = NativeDecodedVideoFrame(pixels: buffer, nativeWidth: 1170, nativeHeight: 2532)
        XCTAssertNoThrow(try NativeSnapshotImage.validateNativeRectangle(image, width: 1170, height: 2532))
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        XCTAssertEqual(Data(bytes: base, count: stride * 2576), before, "Validation must not repair pixels")
    }

    func testAllBlackPixelsCannotAuthorizeAWrongCropOrRotation() throws {
        let image = NativeDecodedVideoFrame(pixels: try pixels(), nativeWidth: 1170, nativeHeight: 2532)
        for (width, height) in [(1169, 2532), (1171, 2532), (1170, 2531), (1170, 2533), (2532, 1170)] {
            rejected(image, width: width, height: height)
        }
    }

    func testMetadataCannotAuthorizeInvalidOrExcessiveCanvasPadding() throws {
        let buffer = try pixels()
        for (width, height) in [(0, 2532), (1185, 2532), (1170, 2577), (1120, 2532), (1170, 2512)] {
            rejected(
                NativeDecodedVideoFrame(pixels: buffer, nativeWidth: width, nativeHeight: height),
                width: width, height: height)
        }
    }

    func testPaddingColorDoesNotSupplyGeometryEvenForThinPadding() throws {
        let buffer = try pixels(width: 1172, height: 2534)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer)!, 255, CVPixelBufferGetBytesPerRow(buffer) * 2534)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let image = NativeDecodedVideoFrame(pixels: buffer, nativeWidth: 1170, nativeHeight: 2532)
        XCTAssertNoThrow(try NativeSnapshotImage.validateNativeRectangle(image, width: 1170, height: 2532))
        rejected(image, width: 1171, height: 2532)
    }
}
