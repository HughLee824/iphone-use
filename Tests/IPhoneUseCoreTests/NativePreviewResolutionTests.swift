import XCTest
import CoreImage
@testable import IPhoneUseCore

final class NativePreviewResolutionTests: XCTestCase {
    func pixels(activeWidth: Int, activeHeight: Int) throws -> CVPixelBuffer {
        var value: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                nil, 64, 128, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                nil, &value), kCVReturnSuccess)
        let buffer = try XCTUnwrap(value)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let width = activeWidth * 48 / 64, height = activeHeight * 96 / 128
        let values: [UInt8] = [32, 80, 144, 208]
        for row in 0..<128 {
            for column in 0..<64 {
                luma[row * stride + column] =
                    column < width && row < height
                    ? values[(row < height / 2 ? 0 : 2) + (column < width / 2 ? 0 : 1)] : 235
            }
        }
        memset(
            CVPixelBufferGetBaseAddressOfPlane(buffer, 1), 128,
            CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * CVPixelBufferGetHeightOfPlane(buffer, 1))
        CVBufferSetAttachment(
            buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return buffer
    }

    func display(_ rotation: String = "rot0") throws -> NativeDisplay {
        try NativeDisplay([
            "backlightState": "activeOn",
            "displays": [
                [
                    "primary": true, "displayId": 1,
                    "bounds": [[0, 0], [48, 96]], "pointScale": 1, "currentOrientation": rotation,
                    "nativeOrientation": "rot0"
                ]
            ]
        ])
    }

    func geometryPacket(_ sequence: UInt8, timestamp: UInt8? = nil, profile: UInt8 = 0x90) -> Data {
        Data([
            0x90, 0xe4, 0, sequence, 0, 0, 0, timestamp ?? sequence, 0, 0, 0, 123,
            profile, 1, 0, 1, 0, 0, 0, 0, 40, 1, 1
        ])
    }
}
