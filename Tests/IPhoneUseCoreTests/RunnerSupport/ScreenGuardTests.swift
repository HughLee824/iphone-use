import XCTest
import CoreGraphics
import ImageIO
@testable import IPhoneUseCore

// Top-left pixel coordinates, like AX screen points. No ignored device artifacts are required.
func screenPNG(width: Int = 390, height: Int = 844, patches: [(CGRect, [UInt8])] = [], dpi: Int = 72) throws
    -> Data {
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for (rect, rgb) in patches {
        for row in max(0, Int(rect.minY))..<min(height, Int(rect.maxY)) {
            for column in max(0, Int(rect.minX))..<min(width, Int(rect.maxX)) {
                for channel in 0..<3 { pixels[(row * width + column) * 4 + channel] = rgb[channel] }
            }
        }
    }
    let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
    let image = try XCTUnwrap(
        CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let data = NSMutableData()
    let output = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(
        output, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(output))
    return data as Data
}

func screenTestContext(scope: CGRect? = nil, orientation: Int = 1, keyboardCount: Int = 0) -> ScreenContext {
    let screen = CGRect(x: 0, y: 0, width: 390, height: 844)
    return ScreenContext(
        screen: ScreenRect(screen), scope: ScreenRect(scope ?? screen), orientation: orientation,
        keyboardCount: keyboardCount)
}

final class ScreenGuardTests: XCTestCase {
    let target = CGPoint(x: 200, y: 600)

    func guardValue(policy: ScreenGuard.Policy = .init(), extra: [ScreenRect] = []) throws -> ScreenGuard {
        let context = screenTestContext()
        let rects =
            CoordinateGesture.actionRegions(start: target, end: nil, screen: context.screen.cgRect) + extra
        return try ScreenGuard(png: screenPNG(), context: context, rects: rects, policy: policy)
    }
}
