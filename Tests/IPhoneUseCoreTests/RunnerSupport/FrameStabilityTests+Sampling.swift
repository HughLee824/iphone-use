@testable import IPhoneUseRunnerSupport
import XCTest
import CoreGraphics
import ImageIO
@testable import IPhoneUseCore

extension FrameStabilityTests {

    func testStaticFramesRequireMinimumObservationAndStableSpan() throws {
        let image = try png()
        var value = FrameStability(startedAt: 0)
        for time in [0.0, 0.2, 0.4, 1.4] {
            try record(&value, image, time)
            XCTAssertFalse(value.stable)
        }
        try record(&value, image, 1.5)
        XCTAssertTrue(value.stable)
    }

    func testDelayedKeyboardTransitionResetsWindow() throws {
        let first = try png(), keyboard = try png(changed: true)
        var value = FrameStability(startedAt: 0)
        for time in [0.0, 0.2, 0.4, 0.8] { try record(&value, first, time); XCTAssertFalse(value.stable) }
        for time in [1.0, 1.2] { try record(&value, keyboard, time); XCTAssertFalse(value.stable) }
        try record(&value, first, 1.4)
        try record(&value, first, 1.6)
        XCTAssertFalse(value.stable)
        try record(&value, first, 1.81)
        XCTAssertTrue(value.stable)
    }

    func testNoiseIsToleratedButSinglePixelAndDimensionsRemainSignificant() throws {
        let first = try FrameFingerprint(
            png: screenPNG(patches: [(CGRect(x: 0, y: 0, width: 390, height: 844), [100, 100, 100])]))
        let noise = try FrameFingerprint(
            png: screenPNG(patches: [(CGRect(x: 0, y: 0, width: 390, height: 844), [102, 101, 99])]))
        XCTAssertTrue(FrameComparison(reference: first, current: noise).equivalent)
        let text = try FrameFingerprint(
            png: screenPNG(patches: [(CGRect(x: 10, y: 10, width: 1, height: 1), [0, 0, 0])])
        )
        XCTAssertEqual(
            FrameComparison(reference: try FrameFingerprint(png: screenPNG()), current: text).changedPixels, 1
        )
        XCTAssertFalse(
            FrameComparison(reference: first, current: try FrameFingerprint(png: png())).equivalent)
    }

    func testCandidateAnchorPreventsSlowAccumulatedDrift() throws {
        var value = FrameStability(startedAt: 0)
        for index in 0...10 {
            let color = UInt8(100 + index * 2)
            let image = try screenPNG(patches: [
                (CGRect(x: 0, y: 0, width: 390, height: 844), [color, color, color])
            ])
            try record(&value, image, Double(index) * 0.2)
            XCTAssertFalse(value.stable)
        }
    }

    func testCaretFadeOnlyWithinExplicitTextTargetAndNotTextOrMovement() throws {
        let field = ScreenRect(CGRect(x: 18, y: 139, width: 354, height: 160))
        let stroke = CGRect(x: 50, y: 150, width: 2, height: 20)
        let source = try screenPNG(patches: [(stroke, [30, 110, 240])])
        let hidden = try screenPNG()
        var value = FrameStability(startedAt: 0, context: screenTestContext(), textFields: [field])
        try record(&value, source, 0)
        try record(&value, hidden, 0.2)
        XCTAssertNotNil((value.result["comparison"] as? [String: Any])?["ignoredCaret"])
        try record(&value, source, 1.5)
        XCTAssertTrue(value.stable)
        XCTAssertNil((value.result["comparison"] as? [String: Any])?["ignoredCaret"])
        for patch in [
            (stroke.offsetBy(dx: 1, dy: 0), [30, 110, 240]),
            (CGRect(x: 70, y: 150, width: 1, height: 10), [0, 0, 0]),
            (stroke, [0, 0, 0])
        ] as [(CGRect, [UInt8])] {
            var test = value
            try record(&test, screenPNG(patches: [patch]), 1.7)
            XCTAssertFalse(test.stable)
        }
        var unscoped = FrameStability(startedAt: 0)
        try record(&unscoped, source, 0)
        try record(&unscoped, hidden, 0.2)
        XCTAssertEqual(unscoped.consecutiveFrames, 1)
    }

    func testTabDestinationCaretRequiresOneCandidateAndKeepsOtherFieldsVisible() throws {
        let first = ScreenRect(CGRect(x: 18, y: 139, width: 354, height: 60))
        let second = ScreenRect(CGRect(x: 18, y: 219, width: 354, height: 60))
        let stroke = CGRect(x: 50, y: 230, width: 2, height: 20)
        let source = try screenPNG(patches: [(stroke, [30, 110, 240])])
        let hidden = try screenPNG()
        var value = FrameStability(startedAt: 0, context: screenTestContext(), textFields: [first, second])
        try record(&value, source, 0)
        try record(&value, hidden, 0.2)
        try record(&value, source, 1.5)
        XCTAssertTrue(value.stable)
        try record(
            &value, screenPNG(patches: [(CGRect(x: 70, y: 150, width: 1, height: 10), [0, 0, 0])]), 1.7)
        XCTAssertFalse(value.stable)

        for fields in [[first], [second, second], Array(repeating: second, count: 9)] {
            var rejected = FrameStability(startedAt: 0, context: screenTestContext(), textFields: fields)
            try record(&rejected, source, 0)
            try record(&rejected, hidden, 0.2)
            XCTAssertEqual(rejected.consecutiveFrames, 1)
        }
        var ambiguous = FrameStability(
            startedAt: 0, context: screenTestContext(), textFields: [first, second])
        let two = try screenPNG(patches: [
            (stroke, [30, 110, 240]), (stroke.offsetBy(dx: 0, dy: -80), [30, 110, 240])
        ])
        try record(&ambiguous, two, 0)
        try record(&ambiguous, hidden, 0.2)
        XCTAssertEqual(ambiguous.consecutiveFrames, 1)
    }

    func testCaretNextToGlyphDoesNotMaskTheGlyph() throws {
        let field = ScreenRect(CGRect(x: 18, y: 139, width: 354, height: 160))
        let caret = CGRect(x: 50, y: 150, width: 2, height: 20)
        let glyph = CGRect(x: 48, y: 155, width: 1, height: 10)
        let source = try screenPNG(patches: [(caret, [30, 110, 240]), (glyph, [0, 0, 0])])
        XCTAssertNil(try NativeCaretGuard(png: source, context: screenTestContext(), field: field))
        var value = FrameStability(startedAt: 0, context: screenTestContext(), textFields: [field])
        try record(&value, source, 0)
        try record(&value, screenPNG(patches: [(glyph, [0, 0, 0])]), 0.2)
        try record(&value, source, 1.5)
        XCTAssertTrue(value.stable)
        try record(&value, screenPNG(patches: [(glyph, [20, 20, 20])]), 1.7)
        XCTAssertFalse(value.stable)
    }

    func testCaretAntialiasOverlapPreservesTextAndRejectsWrongPhase() throws {
        let field = ScreenRect(CGRect(x: 18, y: 139, width: 354, height: 160))
        let background = CGRect(x: 0, y: 0, width: 390, height: 844)
        let stroke = CGRect(x: 50, y: 150, width: 2, height: 20)
        let glyph = CGRect(x: 48, y: 155, width: 2, height: 10)
        let overlap = CGRect(x: 50, y: 160, width: 1, height: 1)
        func image(_ caret: [UInt8], _ edge: [UInt8], text: UInt8 = 255) throws -> Data {
            try screenPNG(patches: [
                (background, [28, 28, 30]), (stroke, caret),
                (glyph, [text, text, text]), (overlap, edge)
            ])
        }
        let source = try image([47, 68, 137], [65, 75, 110])
        let bright = try image([66, 107, 242], [65, 86, 154])
        let hidden = try image([28, 28, 30], [65, 65, 65])
        XCTAssertNil(try NativeCaretGuard(png: source, context: screenTestContext(), field: field))
        var value = FrameStability(startedAt: 0, context: screenTestContext(), textFields: [field])
        try record(&value, source, 0)
        try record(&value, bright, 0.2)
        try record(&value, hidden, 1.5)
        XCTAssertTrue(value.stable)
        XCTAssertNotNil((value.result["comparison"] as? [String: Any])?["ignoredCaret"])
        for invalid in [
            try image([66, 107, 242], [65, 86, 154], text: 230),
            try image([66, 107, 242], [65, 75, 250]),
            try image([47, 68, 137], [85, 95, 130])
        ] {
            var test = value
            try record(&test, invalid, 1.7)
            XCTAssertFalse(test.stable)
        }
    }

    func testCaptureAndComparisonDeadlineAndSmallSampleSpanFailClosed() throws {
        let image = try png()
        var value = FrameStability(startedAt: 0)
        for time in [1.5, 1.51, 1.52] { try record(&value, image, time) }
        XCTAssertFalse(value.stable)
        try record(&value, image, 1.6, processed: 2)
        XCTAssertFalse(value.stable)
        try record(&value, image, 4.9, processed: 5.1)
        XCTAssertFalse(value.stable)
        XCTAssertEqual(value.remaining(at: 5.1), 0)
    }

    func testPixelHashIgnoresEncodingMetadataButDetectsSmallChangesAndDimensions() throws {
        let first = try png()
        let metadata = try png(dpi: 144)
        XCTAssertNotEqual(first, metadata)
        let hash = try FrameFingerprint(png: first).hash
        XCTAssertEqual(hash, try FrameFingerprint(png: metadata).hash)
        XCTAssertNotEqual(hash, try FrameFingerprint(png: png(changed: true)).hash)
        XCTAssertNotEqual(
            try FrameFingerprint(png: png(width: 1, height: 4)).hash,
            try FrameFingerprint(png: png(width: 4, height: 1)).hash)
        XCTAssertThrowsError(try FrameFingerprint(png: Data("not an image".utf8)))
    }
}
