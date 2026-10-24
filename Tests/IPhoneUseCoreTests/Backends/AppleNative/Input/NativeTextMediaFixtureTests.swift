@testable import IPhoneUseRunnerSupport
import XCTest
import CoreGraphics
import ImageIO
@testable import IPhoneUseCore

final class NativeTextMediaFixtureTests: XCTestCase {
    private let rect = ScreenRect(CGRect(x: 0, y: 0, width: 356, height: 161))
    private var context: ScreenContext {
        ScreenContext(screen: rect, scope: rect, orientation: 1, keyboardCount: 0)
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Fixtures/NativeText"))
        return try Data(contentsOf: url)
    }

    private func matches(_ name: String, frames: [Data]) throws -> [NativeTextFieldGuard.Match] {
        let guardValue = try NativeTextFieldGuard(png: fixture(name), context: context, field: rect)
        return try frames.map {
            guardValue.compare(try guardValue.pixels(png: $0, context: context), caret: nil)
        }
    }

    func testRecordedNoiseRetainsAppearanceRulesWithoutImplicitCaretMask() throws {
        let encoded = try (0..<6).map { try fixture("encoded-\($0)") }
        XCTAssertTrue(try matches("encoded-source", frames: encoded).contains(.appearance))
        // Old media fixtures cannot authorize an implicit caret exception.
        let caret = try (1...6).map { try fixture("caret-\($0)") }
        XCTAssertFalse(try matches("caret-source", frames: caret).contains(.caret))
    }

    func testMutationHelperPreservesUneditedPixelGeometry() throws {
        let source = try fixture("encoded-source")
        let guardValue = try NativeTextFieldGuard(png: source, context: context, field: rect)
        XCTAssertTrue(try guardValue.matches(png: changing(source, patch: .zero, color: 0), context: context))
    }

    private func changing(_ png: Data, patch: CGRect, color: UInt8) throws -> Data {
        let image = try ScreenImage(png: png)
        let width = image.image.width, height = image.image.height
        var rgb = try image.rgb(rect: rect, screen: rect, columns: width, rows: height)
        for row in Int(patch.minY)..<Int(patch.maxY) {
            for column in Int(patch.minX)..<Int(patch.maxX) {
                for channel in 0..<3 { rgb[(row * width + column) * 3 + channel] = color }
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: rgb as CFData))
        let edited = try XCTUnwrap(
            CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24,
                bytesPerRow: width * 3, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: [],
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let result = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(result, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, edited, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return result as Data
    }

    func testRecordedNoiseDoesNotHideAddedOrRemovedText() throws {
        for prefix in ["encoded", "caret"] {
            let indices = prefix == "encoded" ? Array(0..<6) : Array(1...6)
            let frames = try indices.map { try fixture("\(prefix)-\($0)") }
            // New thin dark glyph, low-contrast stroke, deleted existing text,
            // and a selection-like block. Keep the real blink/noise underneath.
            let patches: [(CGRect, UInt8)] = [
                (CGRect(x: 450, y: 35, width: 3, height: 45), 0),
                (CGRect(x: 450, y: 35, width: 1, height: 30), 230),
                (CGRect(x: 12, y: 20, width: 90, height: 60), 245),
                (CGRect(x: 450, y: 35, width: 120, height: 45), 150)
            ]
            for (patch, color) in patches {
                let changed = try frames.map { try changing($0, patch: patch, color: color) }
                XCTAssertTrue(try matches("\(prefix)-source", frames: changed).allSatisfy { $0 == .none })
            }
        }
    }
}
