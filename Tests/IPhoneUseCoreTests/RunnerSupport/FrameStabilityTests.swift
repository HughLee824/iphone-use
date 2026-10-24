@testable import IPhoneUseRunnerSupport
import XCTest
import CoreGraphics
import ImageIO
@testable import IPhoneUseCore

final class FrameStabilityTests: XCTestCase {
    func record(_ value: inout FrameStability, _ png: Data, _ time: Double, processed: Double? = nil) throws {
        value.record(
            frame: try FrameFingerprint(png: png), png: png, capturedAt: time, processedAt: processed ?? time)
    }

    func png(width: Int = 2, height: Int = 2, changed: Bool = false, dpi: Int = 72) throws -> Data {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        if changed { pixels[0] = 0 }
        let data = Data(pixels)
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let image = try XCTUnwrap(
            CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let encoded = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(
            destination, image,
            [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return encoded as Data
    }
}
