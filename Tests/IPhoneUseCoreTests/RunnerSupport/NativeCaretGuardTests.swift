@testable import IPhoneUseRunnerSupport
import XCTest
@testable import IPhoneUseCore

final class NativeCaretGuardTests: XCTestCase {
    private let field = ScreenRect(CGRect(x: 18, y: 139, width: 354, height: 160))
    private let stroke = CGRect(x: 50, y: 150, width: 2, height: 20)
    private let blue: [UInt8] = [30, 110, 240]

    func testSourceAnchoredCaretAllowsDisappearAndUniformFadeAtMultipleScales() throws {
        for scale in [1, 2, 3] {
            let rect = CGRect(
                x: stroke.minX * Double(scale), y: stroke.minY * Double(scale),
                width: stroke.width * Double(scale), height: stroke.height * Double(scale))
            let baseline = try screenPNG(width: 390 * scale, height: 844 * scale, patches: [(rect, blue)])
            let caret = try XCTUnwrap(
                NativeCaretGuard(png: baseline, context: screenTestContext(), field: field))
            XCTAssertEqual(caret.caret, ScreenRect(stroke))
            for color in [[255, 255, 255], [142, 182, 247], [30, 110, 240]] as [[UInt8]] {
                let changed = try screenPNG(width: 390 * scale, height: 844 * scale, patches: [(rect, color)])
                XCTAssertTrue(try caret.acceptsBlink(png: changed, context: screenTestContext()))
            }
        }
    }

    func testYellowCaretUsesSameBoundedFadeAndRejectsOtherChanges() throws {
        let yellow: [UInt8] = [230, 185, 0]
        for scale in [1, 2, 3] {
            let rect = CGRect(
                x: stroke.minX * Double(scale), y: stroke.minY * Double(scale),
                width: stroke.width * Double(scale), height: stroke.height * Double(scale))
            func image(_ color: [UInt8], extra: [(CGRect, [UInt8])] = []) throws -> Data {
                try screenPNG(width: 390 * scale, height: 844 * scale, patches: [(rect, color)] + extra)
            }
            let baseline = try image(yellow)
            let caret = try XCTUnwrap(
                NativeCaretGuard(png: baseline, context: screenTestContext(), field: field))
            XCTAssertEqual(caret.caret, ScreenRect(stroke))
            for color: [UInt8] in [[255, 255, 255], [242, 220, 128], yellow] {
                XCTAssertTrue(try caret.acceptsBlink(png: image(color), context: screenTestContext()))
            }
            for color: [UInt8] in [[0, 0, 0], blue, [255, 0, 0]] {
                XCTAssertFalse(try caret.acceptsBlink(png: image(color), context: screenTestContext()))
            }
            let text = CGRect(x: 75 * scale, y: 160 * scale, width: scale, height: 10 * scale)
            XCTAssertFalse(
                try caret.acceptsBlink(
                    png: image([255, 255, 255], extra: [(text, [0, 0, 0])]), context: screenTestContext()))
            for changed in [rect.offsetBy(dx: 1, dy: 0), rect.insetBy(dx: -2, dy: 0)] {
                XCTAssertFalse(
                    try caret.acceptsBlink(
                        png: screenPNG(
                            width: 390 * scale, height: 844 * scale,
                            patches: [(changed, yellow)]), context: screenTestContext()))
            }
            XCTAssertNil(
                try NativeCaretGuard(
                    png: image(yellow, extra: [(rect.offsetBy(dx: 20 * Double(scale), dy: 0), blue)]),
                    context: screenTestContext(), field: field))
        }
        let baseline = try screenPNG(patches: [(stroke, yellow)])
        XCTAssertNil(
            try NativeCaretGuard(
                png: baseline, context: screenTestContext(), field: field,
                allowsAdjacentText: true, allowsColoredCarets: false))

    }

    func testGreenCaretFadesButDoesNotPermitTextMovementOrSelection() throws {
        let green: [UInt8] = [7, 193, 96]
        let context = screenTestContext()
        let source = try screenPNG(patches: [(stroke, green)])
        let caret = try XCTUnwrap(NativeCaretGuard(png: source, context: context, field: field))
        for color: [UInt8] in [green, [131, 224, 176], [255, 255, 255]] {
            XCTAssertTrue(
                try caret.acceptsBlink(png: screenPNG(patches: [(stroke, color)]), context: context))
        }
        for patches: [(CGRect, [UInt8])] in [
            [(stroke.offsetBy(dx: 1, dy: 0), green)],
            [(stroke, blue)],
            [(stroke, green), (CGRect(x: 80, y: 155, width: 8, height: 10), [0, 0, 0])],
            [(stroke.insetBy(dx: -5, dy: 0), green)]
        ] {
            XCTAssertFalse(try caret.acceptsBlink(png: screenPNG(patches: patches), context: context))
        }
        XCTAssertNil(
            try NativeCaretGuard(
                png: source, context: context, field: field,
                allowsAdjacentText: true, allowsColoredCarets: false)) // Runner unchanged.
        XCTAssertNil(
            try NativeCaretGuard(
                png: screenPNG(patches: [
                    (stroke, green),
                    (stroke.offsetBy(dx: 20, dy: 0), green)
                ]), context: context, field: field))
    }

    func testColoredContentDoesNotHideUniqueCaretButRemainsProtected() throws {
        for scale in [1, 2, 3] {
            func scaled(_ rect: CGRect) -> CGRect {
                CGRect(
                    x: rect.minX * Double(scale), y: rect.minY * Double(scale),
                    width: rect.width * Double(scale), height: rect.height * Double(scale))
            }
            let yellow: [UInt8] = [230, 185, 0]
            let emoji = scaled(CGRect(x: 100, y: 150, width: 16, height: 18))
            let coloredText = scaled(CGRect(x: 130, y: 150, width: 14, height: 12))
            let content = [(emoji, yellow), (coloredText, blue)]
            func image(_ patches: [(CGRect, [UInt8])]) throws -> Data {
                try screenPNG(width: 390 * scale, height: 844 * scale, patches: patches)
            }
            let baseline = try image(content + [(scaled(stroke), yellow)])
            let caret = try XCTUnwrap(
                NativeCaretGuard(png: baseline, context: screenTestContext(), field: field))
            XCTAssertEqual(caret.caret, ScreenRect(stroke))
            XCTAssertTrue(try caret.acceptsBlink(png: image(content), context: screenTestContext()))
            XCTAssertFalse(
                try caret.acceptsBlink(
                    png: image([(emoji, blue), (coloredText, blue)]), context: screenTestContext()))
            XCTAssertFalse(
                try caret.acceptsBlink(
                    png: image([(emoji.offsetBy(dx: 1, dy: 0), yellow), (coloredText, blue)]),
                    context: screenTestContext()))
            XCTAssertNil(
                try NativeCaretGuard(png: image(content), context: screenTestContext(), field: field))
            XCTAssertNil(
                try NativeCaretGuard(
                    png: image(
                        content + [
                            (scaled(stroke), yellow),
                            (scaled(stroke.offsetBy(dx: 20, dy: 0)), blue)
                        ]), context: screenTestContext(), field: field))
            // A selection handle remains connected to the stroke and disqualifies it.
            XCTAssertNil(
                try NativeCaretGuard(
                    png: image(
                        content + [
                            (scaled(stroke), yellow),
                            (scaled(CGRect(x: 46, y: 146, width: 10, height: 4)), yellow)
                        ]), context: screenTestContext(), field: field))
            let runnerSource = try image(content + [(scaled(stroke), blue)])
            XCTAssertNil(
                try NativeCaretGuard(
                    png: runnerSource, context: screenTestContext(), field: field,
                    allowsAdjacentText: true, allowsColoredCarets: false))
        }
    }

    func testCaretExceptionRejectsTextPositionShapeSelectionAndBackgroundChanges() throws {
        let baseline = try screenPNG(patches: [(stroke, blue)])
        let caret = try XCTUnwrap(NativeCaretGuard(png: baseline, context: screenTestContext(), field: field))
        let variants: [[(CGRect, [UInt8])]] = [
            [(stroke.offsetBy(dx: 1, dy: 0), blue)], // Even a one-pixel position change.
            [(stroke.offsetBy(dx: 0, dy: 1), blue)],
            [(CGRect(x: 50, y: 150, width: 2, height: 12), blue)],
            [(stroke, [0, 0, 0])], // A same-size black text stroke must not be masked.
            [(CGRect(x: 50, y: 150, width: 15, height: 20), blue)], // Selection highlight.
            [(CGRect(x: 70, y: 150, width: 1, height: 10), [0, 0, 0])], // Text change while caret is off.
            [(stroke, blue), (CGRect(x: 70, y: 150, width: 1, height: 10), [0, 0, 0])],
            [(stroke, blue), (CGRect(x: 18, y: 139, width: 2, height: 100), [0, 0, 0])], // Field edge moves.
            [(field.cgRect, [240, 240, 240])]
        ]
        for patches in variants {
            XCTAssertFalse(
                try caret.acceptsBlink(png: screenPNG(patches: patches), context: screenTestContext()))
        }
        XCTAssertFalse(try caret.acceptsBlink(png: baseline, context: screenTestContext(orientation: 2)))
        XCTAssertFalse(
            try caret.acceptsBlink(png: screenPNG(width: 780, height: 1688), context: screenTestContext()))
    }

    func testDarkBackgroundSupportsFadingAndBrighteningFromVisibleSource() throws {
        let background: [UInt8] = [30, 30, 30]
        let source = try screenPNG(patches: [(field.cgRect, background), (stroke, [40, 70, 135])])
        let caret = try XCTUnwrap(NativeCaretGuard(png: source, context: screenTestContext(), field: field))
        for color in [background, [35, 50, 82], [50, 110, 240]] as [[UInt8]] {
            XCTAssertTrue(
                try caret.acceptsBlink(
                    png: screenPNG(patches: [(field.cgRect, background), (stroke, color)]),
                    context: screenTestContext()))
        }
        XCTAssertFalse(
            try caret.acceptsBlink(
                png: screenPNG(patches: [(field.cgRect, background), (stroke, [240, 70, 135])]),
                context: screenTestContext()))
    }

    func testHiddenAmbiguousOrUnsupportedSourceHasNoException() throws {
        let variants: [[(CGRect, [UInt8])]] = [
            [], [(stroke, [0, 0, 0])], [(stroke, [240, 30, 30])],
            [(stroke, blue), (stroke.offsetBy(dx: 40, dy: 0), blue)],
            [(CGRect(x: 50, y: 150, width: 15, height: 20), blue)],
            [(CGRect(x: 50, y: 150, width: 2, height: 50), blue)],
            [(stroke, blue), (CGRect(x: 48, y: 150, width: 1, height: 20), [0, 0, 0])],
            [(stroke, blue), (CGRect(x: 46, y: 146, width: 10, height: 4), blue)] // Selection handle.
        ]
        for patches in variants {
            XCTAssertNil(
                try NativeCaretGuard(
                    png: screenPNG(patches: patches), context: screenTestContext(), field: field))
        }
    }

    func testNativeTextGetsAnObservationBoundFullPixelGuard() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ObservationCache(directory: directory), context = screenTestContext()
        let capture = CapturedObservation(
            nodes: [],
            metadata: [
                "backend": "apple-native",
                "screenContext": try jsonObject(JSONEncoder().encode(context))
            ], screenshot: try screenPNG(patches: [(stroke, blue)]))
        _ = try cache.store(capture)
        let request: [String: Any] = [
            "reference": "o1", "text": "中文", "mode": "insert", "fieldRect": "18,139,354,160"
        ]
        let action = try DeviceAction(operation: "type", request: request, allowScreenText: true)
        XCTAssertNotNil(try cache.resolveTarget(for: action).textFieldGuard)
        var noField = request; noField.removeValue(forKey: "fieldRect")
        XCTAssertNotNil(
            try cache.resolveTarget(
                for: DeviceAction(operation: "type", request: noField, allowScreenText: true)
            )
            .textFieldGuard)
        let tap = try DeviceAction(operation: "tap", request: ["reference": "o1", "x": 50, "y": 150])
        XCTAssertNil(try cache.resolveTarget(for: tap).textFieldGuard)
        _ = try cache.store(capture)
        XCTAssertThrowsError(try cache.resolveTarget(for: action))
    }
}
