import XCTest
import CoreVideo
@testable import IPhoneUseCore

final class NativePaddingTests: XCTestCase {
    private func pixels(width: Int = 208, height: Int = 312) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, nil, &result), kCVReturnSuccess)
        let buffer = try XCTUnwrap(result)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer)!, 0, CVPixelBufferGetBytesPerRow(buffer) * height)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private func paint(_ buffer: CVPixelBuffer, _ x: Int, _ y: Int, _ value: UInt8) {
        CVPixelBufferLockBaseAddress(buffer, [])
        let pixel = CVPixelBufferGetBaseAddress(buffer)!.advanced(by:
            y * CVPixelBufferGetBytesPerRow(buffer) + x * 4).assumingMemoryBound(to: UInt8.self)
        pixel[0] = value; pixel[1] = value; pixel[2] = value; pixel[3] = 255
        CVPixelBufferUnlockBaseAddress(buffer, [])
    }

    private func rejected(_ buffer: CVPixelBuffer, width: Int = 200, height: Int = 300,
                          file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try NativeSnapshotImage.validatePadding(buffer, width: width, height: height),
                             file: file, line: line) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "native_snapshot_geometry_unavailable", file: file, line: line)
        }
    }

    func testSparseRingingAtBothNativeEdgesIsAllowedWithoutChangingPixels() throws {
        let buffer = try pixels()
        for depth in 0..<4 {
            paint(buffer, 200 + depth, 100, 32)
            paint(buffer, 100, 300 + depth, 32)
        }
        XCTAssertNoThrow(try NativeSnapshotImage.validatePadding(buffer, width: 200, height: 300))
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(base[303 * CVPixelBufferGetBytesPerRow(buffer) + 100 * 4], 32)
    }

    func testRecordedFailureShapeAtNativeScaleFitsBoundedException() throws {
        // Synthetic analogue of 70 sparse pixels in the first four bottom rows.
        // No device screenshot or private text is embedded in the fixture.
        let buffer = try pixels(width: 1184, height: 2576)
        for i in 0..<70 { paint(buffer, 84 + i * 7, 2532 + i % 4, UInt8(9 + i % 22)) }
        XCTAssertNoThrow(try NativeSnapshotImage.validatePadding(buffer, width: 1170, height: 2532))
    }

    func testBrightDistantAndCornerPixelsRemainRejected() throws {
        for (x, y, value): (Int, Int, UInt8) in [
            (200, 100, 33), (100, 300, 33), (204, 100, 9), (100, 304, 9),
            (200, 300, 9), (207, 311, 9)] {
            let buffer = try pixels(); paint(buffer, x, y, value); rejected(buffer)
        }
    }

    func testEachEdgeHasItsOwnTwoPercentBudget() throws {
        // A large quiet edge must not subsidize content in the other edge.
        for right in [false, true] {
            let buffer = try pixels(), budget = (right ? 300 : 200) * 4 / 50
            for i in 0..<budget { paint(buffer, right ? 200 : i, right ? i : 300, 9) }
            XCTAssertNoThrow(try NativeSnapshotImage.validatePadding(buffer, width: 200, height: 300))
            paint(buffer, right ? 200 : budget, right ? budget : 300, 9)
            rejected(buffer)
        }
    }

    func testThinPaddingCannotUseAnExceptionWithoutOuterBlackBand() throws {
        for right in [false, true] {
            let buffer = try pixels(width: right ? 207 : 208, height: right ? 312 : 307)
            paint(buffer, right ? 200 : 100, right ? 100 : 300, 9)
            rejected(buffer)
        }
    }

    func testWrongCropAndInvalidDimensionsRemainRejected() throws {
        let buffer = try pixels()
        paint(buffer, 199, 100, 255); paint(buffer, 100, 299, 255)
        XCTAssertNoThrow(try NativeSnapshotImage.validatePadding(buffer, width: 200, height: 300))
        for (width, height) in [(199, 300), (200, 299), (300, 200), (0, 300), (209, 300), (100, 300)] {
            rejected(buffer, width: width, height: height)
        }
    }
}
