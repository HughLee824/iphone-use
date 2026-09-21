import XCTest
import CoreGraphics
import ImageIO
@testable import IPhoneUseCore

final class FrameStabilityTests: XCTestCase {
    func testUnchangedScreenCanCompleteWithoutFirstChanging() {
        var stability = FrameStability(startedAt: 0)
        stability.record(hash: "same", capturedAt: 0, processedAt: 0)
        stability.record(hash: "same", capturedAt: 0.2, processedAt: 0.2)
        XCTAssertFalse(stability.stable)
        stability.record(hash: "same", capturedAt: 0.4, processedAt: 0.4)
        XCTAssertTrue(stability.stable)
    }

    func testTransitionResetsTheEntireStableWindow() {
        var stability = FrameStability(startedAt: 0)
        for (hash, time) in [("old", 0.0), ("old", 0.2), ("transition", 0.3), ("new", 0.4), ("new", 0.6)] {
            stability.record(hash: hash, capturedAt: time, processedAt: time)
            XCTAssertFalse(stability.stable)
        }
        stability.record(hash: "new", capturedAt: 0.81, processedAt: 0.81)
        XCTAssertTrue(stability.stable)
        XCTAssertEqual(stability.consecutiveFrames, 3)
    }

    func testFrameCountAloneCannotSkipTheTimeWindow() {
        var stability = FrameStability(startedAt: 0)
        for time in [0.0, 0.01, 0.02] { stability.record(hash: "same", capturedAt: time, processedAt: time) }
        XCTAssertFalse(stability.stable)
        stability.record(hash: "same", capturedAt: 0.4, processedAt: 0.4)
        XCTAssertTrue(stability.stable)
    }

    func testContinuousChangesAndLateCaptureCannotReportSuccess() {
        var changing = FrameStability(startedAt: 0)
        for index in 0...25 {
            let time = Double(index) * 0.2
            changing.record(hash: "\(index)", capturedAt: time, processedAt: time)
            XCTAssertFalse(changing.stable)
        }
        XCTAssertEqual(changing.remaining(at: 5), 0)
        var late = FrameStability(startedAt: 0)
        for time in [0.0, 0.2, 5.1] { late.record(hash: "same", capturedAt: time, processedAt: time) }
        XCTAssertFalse(late.stable)
    }

    func testHashProcessingCannotExtendTheStableWindowOrExceedTheDeadline() {
        var stability = FrameStability(startedAt: 0)
        stability.record(hash: "same", capturedAt: 0, processedAt: 0.1)
        stability.record(hash: "same", capturedAt: 0.15, processedAt: 0.2)
        stability.record(hash: "same", capturedAt: 0.3, processedAt: 0.8)
        XCTAssertFalse(stability.stable)
        XCTAssertEqual(stability.result["stableForMs"] as? Double, 300)
        stability.record(hash: "same", capturedAt: 4.9, processedAt: 5.1)
        XCTAssertFalse(stability.stable)
        XCTAssertEqual(stability.remaining(at: 5.1), 0)
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
                              "stableForMs": stable ? 400.0 : 0.0, "elapsedMs": stable ? 500.0 : 5000.0],
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

    func testSuccessWithoutStableFrameEvidenceIsRejected() {
        let directory = URL(fileURLWithPath: "/private/tmp/as-missing-frame-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: directory) }
        let response: [String: Any] = ["ok": true, "execution": ["started": true, "inputCompleted": true, "completed": true]]
        XCTAssertThrowsError(try XCTestCapture.actionResponse(response, directory: directory)) { error in
            XCTAssertEqual((error as? ActionFailure)?.code, "missing_stability_facts")
        }
    }
}
