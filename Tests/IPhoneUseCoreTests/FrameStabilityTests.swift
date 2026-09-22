import XCTest
import CoreGraphics
import ImageIO
@testable import IPhoneUseCore

final class FrameStabilityTests: XCTestCase {
    private func record(_ value: inout FrameStability, _ png: Data, _ time: Double, processed: Double? = nil) throws {
        value.record(frame: try FrameFingerprint(png: png), png: png, capturedAt: time, processedAt: processed ?? time)
    }

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
        let first = try FrameFingerprint(png: screenPNG(patches: [(CGRect(x: 0, y: 0, width: 390, height: 844), [100,100,100])]))
        let noise = try FrameFingerprint(png: screenPNG(patches: [(CGRect(x: 0, y: 0, width: 390, height: 844), [102,101,99])]))
        XCTAssertTrue(FrameComparison(reference: first, current: noise).equivalent)
        let text = try FrameFingerprint(png: screenPNG(patches: [(CGRect(x: 10, y: 10, width: 1, height: 1), [0,0,0])]))
        XCTAssertEqual(FrameComparison(reference: try FrameFingerprint(png: screenPNG()), current: text).changedPixels, 1)
        XCTAssertFalse(FrameComparison(reference: first, current: try FrameFingerprint(png: png())).equivalent)
    }

    func testCandidateAnchorPreventsSlowAccumulatedDrift() throws {
        var value = FrameStability(startedAt: 0)
        for index in 0...10 {
            let color = UInt8(100 + index * 2)
            let image = try screenPNG(patches: [(CGRect(x: 0, y: 0, width: 390, height: 844), [color,color,color])])
            try record(&value, image, Double(index) * 0.2)
            XCTAssertFalse(value.stable)
        }
    }

    func testCaretFadeOnlyWithinExplicitTextTargetAndNotTextOrMovement() throws {
        let field = ScreenRect(CGRect(x: 18, y: 139, width: 354, height: 160))
        let stroke = CGRect(x: 50, y: 150, width: 2, height: 20)
        let source = try screenPNG(patches: [(stroke, [30,110,240])])
        let hidden = try screenPNG()
        var value = FrameStability(startedAt: 0, context: screenTestContext(), textField: field)
        try record(&value, source, 0)
        try record(&value, hidden, 0.2)
        XCTAssertNotNil((value.result["comparison"] as? [String: Any])?["ignoredCaret"])
        try record(&value, source, 1.5)
        XCTAssertTrue(value.stable)
        XCTAssertNil((value.result["comparison"] as? [String: Any])?["ignoredCaret"])
        for patch in [(stroke.offsetBy(dx: 1, dy: 0), [30,110,240]),
                      (CGRect(x: 70, y: 150, width: 1, height: 10), [0,0,0]),
                      (stroke, [0,0,0])] as [(CGRect,[UInt8])] {
            var test = value
            try record(&test, screenPNG(patches: [patch]), 1.7)
            XCTAssertFalse(test.stable)
        }
        var unscoped = FrameStability(startedAt: 0)
        try record(&unscoped, source, 0)
        try record(&unscoped, hidden, 0.2)
        XCTAssertEqual(unscoped.consecutiveFrames, 1)
    }

    func testCaretNextToGlyphDoesNotMaskTheGlyph() throws {
        let field = ScreenRect(CGRect(x: 18, y: 139, width: 354, height: 160))
        let caret = CGRect(x: 50, y: 150, width: 2, height: 20)
        let glyph = CGRect(x: 48, y: 155, width: 1, height: 10)
        let source = try screenPNG(patches: [(caret, [30,110,240]), (glyph, [0,0,0])])
        XCTAssertNil(try NativeCaretGuard(png: source, context: screenTestContext(), field: field))
        var value = FrameStability(startedAt: 0, context: screenTestContext(), textField: field)
        try record(&value, source, 0)
        try record(&value, screenPNG(patches: [(glyph, [0,0,0])]), 0.2)
        try record(&value, source, 1.5)
        XCTAssertTrue(value.stable)
        try record(&value, screenPNG(patches: [(glyph, [20,20,20])]), 1.7)
        XCTAssertFalse(value.stable)
    }

    func testCaretAntialiasOverlapPreservesTextAndRejectsWrongPhase() throws {
        let field = ScreenRect(CGRect(x: 18, y: 139, width: 354, height: 160))
        let background = CGRect(x: 0, y: 0, width: 390, height: 844)
        let stroke = CGRect(x: 50, y: 150, width: 2, height: 20)
        let glyph = CGRect(x: 48, y: 155, width: 2, height: 10)
        let overlap = CGRect(x: 50, y: 160, width: 1, height: 1)
        func image(_ caret: [UInt8], _ edge: [UInt8], text: UInt8 = 255) throws -> Data {
            try screenPNG(patches: [(background, [28,28,30]), (stroke, caret),
                (glyph, [text,text,text]), (overlap, edge)])
        }
        let source = try image([47,68,137], [65,75,110])
        let bright = try image([66,107,242], [65,86,154])
        let hidden = try image([28,28,30], [65,65,65])
        XCTAssertNil(try NativeCaretGuard(png: source, context: screenTestContext(), field: field))
        var value = FrameStability(startedAt: 0, context: screenTestContext(), textField: field)
        try record(&value, source, 0)
        try record(&value, bright, 0.2)
        try record(&value, hidden, 1.5)
        XCTAssertTrue(value.stable)
        XCTAssertNotNil((value.result["comparison"] as? [String: Any])?["ignoredCaret"])
        for invalid in [try image([66,107,242], [65,86,154], text: 230),
                        try image([66,107,242], [65,75,250]),
                        try image([47,68,137], [85,95,130])] {
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

    private func png(width: Int = 2, height: Int = 2, changed: Bool = false, dpi: Int = 72) throws -> Data {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        if changed { pixels[0] = 0 }
        let data = Data(pixels)
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let encoded = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return encoded as Data
    }

    func testPixelHashIgnoresEncodingMetadataButDetectsSmallChangesAndDimensions() throws {
        let first = try png()
        let metadata = try png(dpi: 144)
        XCTAssertNotEqual(first, metadata)
        let hash = try FrameFingerprint(png: first).hash
        XCTAssertEqual(hash, try FrameFingerprint(png: metadata).hash)
        XCTAssertNotEqual(hash, try FrameFingerprint(png: png(changed: true)).hash)
        XCTAssertNotEqual(try FrameFingerprint(png: png(width: 1, height: 4)).hash,
                          try FrameFingerprint(png: png(width: 4, height: 1)).hash)
        XCTAssertThrowsError(try FrameFingerprint(png: Data("not an image".utf8)))
    }

    func testCompletedAndTimedOutFramesRetainEvidenceWithoutBase64InCLIResults() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/as-frame-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try png()
        let fingerprint = try FrameFingerprint(png: image)
        for stable in [true, false] {
            let response: [String: Any] = ["ok": stable,
                "execution": ["started": true, "inputCompleted": true, "completed": stable],
                "errorCode": "frame_stability_timeout", "requiresObservation": true,
                "stability": ["stable": stable, "hash": fingerprint.hash, "consecutiveFrames": stable ? 3 : 1,
                              "stableForMs": stable ? 400.0 : 0.0, "elapsedMs": stable ? 1600.0 : 5000.0,
                              "algorithm": FrameComparison.algorithm, "minimumObservationMs": 1500.0, "observedForMs": 1500.0,
                              "comparison": ["equivalent": true, "dimensionsMatch": true, "changedPixels": 0, "colorTolerance": 2.5, "maxChannelDelta": 4]],
                "frame": ["screenshotBase64": image.base64EncodedString(), "hash": fingerprint.hash,
                          "width": 2, "height": 2, "capturedAt": 100.0]]
            let decoded = try XCTestCapture.actionResponse(response, directory: directory)
            let result = try XCTUnwrap(decoded["result"] as? [String: Any])
            let frame = try XCTUnwrap(result["frame"] as? [String: Any])
            let path = try XCTUnwrap(frame["screenshot"] as? String)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), image)
            XCTAssertNil(frame["screenshotBase64"])
            if stable { XCTAssertNoThrow(try ActionReply.decode(decoded)) }
            else {
                XCTAssertThrowsError(try ActionReply.decode(decoded)) { error in
                    let failure = error as? ActionFailure
                    XCTAssertTrue(failure?.possiblyExecuted == true)
                    XCTAssertEqual((failure?.result?["execution"] as? [String: Bool])?["inputCompleted"], true)
                }
            }
        }
        try ObservationCache(directory: directory).clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("observations").path))
    }

    func testTimeoutExportsOriginalReferenceAndDifferenceAndRejectsWrongHash() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stability-diagnostic-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try png(), current = try png(changed: true)
        let a = try FrameFingerprint(png: source), b = try FrameFingerprint(png: current)
        var response: [String: Any] = ["ok": false, "errorCode": "frame_stability_timeout",
            "execution": ["started": true, "inputCompleted": true, "completed": false],
            "stability": ["stable": false, "hash": b.hash, "referenceHash": a.hash],
            "stabilityReferenceBase64": source.base64EncodedString(),
            "frame": ["screenshotBase64": current.base64EncodedString(), "hash": b.hash,
                      "width": b.width, "height": b.height, "capturedAt": 100.0]]
        let decoded = try XCTestCapture.actionResponse(response, directory: directory)
        let result = try XCTUnwrap(decoded["result"] as? [String: Any])
        let diagnostic = try XCTUnwrap(result["stabilityDiagnostic"] as? [String: Any])
        let refURL = URL(fileURLWithPath: try XCTUnwrap(diagnostic["reference"] as? String))
        XCTAssertEqual(try Data(contentsOf: refURL), source)
        let diff = try FrameFingerprint(png: Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(diagnostic["difference"] as? String))))
        XCTAssertEqual(diff.pixels[0], 255)
        XCTAssertEqual(diff.pixels[4], 0)
        XCTAssertNil(decoded["stabilityReferenceBase64"])
        response["stability"] = ["stable": false, "hash": b.hash, "referenceHash": "incorrect"]
        XCTAssertThrowsError(try XCTestCapture.actionResponse(response, directory: directory))
    }

    func testHostRejectsOldOrPrematureStabilityProof() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stability-proof-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try png(), frame = try FrameFingerprint(png: image)
        var value = FrameStability(startedAt: 0)
        for t in [0.0, 0.2, 1.6] { try record(&value, image, t) }
        let proof = value.result
        var response: [String: Any] = ["ok": true, "execution": ["started": true, "inputCompleted": true, "completed": true],
            "stability": proof, "frame": ["screenshotBase64": image.base64EncodedString(), "hash": frame.hash,
                "width": frame.width, "height": frame.height, "capturedAt": 100.0]]
        XCTAssertNoThrow(try XCTestCapture.actionResponse(response, directory: directory))
        for (key, changed): (String, Any) in [("algorithm", "sha256-rgba8-srgb"), ("observedForMs", 800.0),
                ("observedForMs", Double.infinity), ("minimumObservationMs", 0.0), ("comparison", NSNull())] {
            var invalid = proof; invalid[key] = changed; response["stability"] = invalid
            XCTAssertThrowsError(try XCTestCapture.actionResponse(response, directory: directory))
        }
    }

    func testSuccessWithoutStableFrameEvidenceIsRejected() {
        let directory = URL(fileURLWithPath: "/private/tmp/as-missing-frame-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: directory) }
        let response: [String: Any] = ["ok": true, "execution": ["started": true, "inputCompleted": true, "completed": true]]
        XCTAssertThrowsError(try XCTestCapture.actionResponse(response, directory: directory)) { error in
            XCTAssertEqual((error as? ActionFailure)?.code, "missing_stability_facts")
        }
    }
}
