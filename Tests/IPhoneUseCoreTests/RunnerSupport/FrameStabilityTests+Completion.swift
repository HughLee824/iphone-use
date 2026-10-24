import XCTest
import CoreGraphics
import ImageIO
@testable import IPhoneUseCore

extension FrameStabilityTests {

    func testCompletedAndTimedOutFramesRetainEvidenceWithoutBase64InCLIResults() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/as-frame-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try png()
        let fingerprint = try FrameFingerprint(png: image)
        for stable in [true, false] {
            let response: [String: Any] = [
                "ok": stable,
                "execution": ["started": true, "inputCompleted": true, "completed": stable],
                "errorCode": "frame_stability_timeout", "requiresObservation": true,
                "stability": [
                    "stable": stable, "hash": fingerprint.hash, "consecutiveFrames": stable ? 3 : 1,
                    "stableForMs": stable ? 400.0 : 0.0, "elapsedMs": stable ? 1600.0 : 5000.0,
                    "algorithm": FrameComparison.algorithm, "minimumObservationMs": 1500.0,
                    "observedForMs": 1500.0,
                    "comparison": [
                        "equivalent": true, "dimensionsMatch": true, "changedPixels": 0,
                        "colorTolerance": 2.5,
                        "maxChannelDelta": 4
                    ]
                ],
                "frame": [
                    "screenshotBase64": image.base64EncodedString(), "hash": fingerprint.hash,
                    "width": 2, "height": 2, "capturedAt": 100.0
                ]
            ]
            let decoded = try XCTestCapture.actionResponse(response, directory: directory)
            let result = try XCTUnwrap(decoded["result"] as? [String: Any])
            let frame = try XCTUnwrap(result["frame"] as? [String: Any])
            let path = try XCTUnwrap(frame["screenshot"] as? String)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), image)
            XCTAssertNil(frame["screenshotBase64"])
            if stable {
                XCTAssertNoThrow(try ActionReply.decode(decoded))
            } else {
                XCTAssertThrowsError(try ActionReply.decode(decoded)) { error in
                    let failure = error as? ActionFailure
                    XCTAssertTrue(failure?.possiblyExecuted == true)
                    XCTAssertEqual(
                        (failure?.result?["execution"] as? [String: Bool])?["inputCompleted"], true)
                }
            }
        }
        try ObservationCache(directory: directory).clear()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("observations").path))
    }

    func testTimeoutExportsOriginalReferenceAndDifferenceAndRejectsWrongHash() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "stability-diagnostic-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try png(), current = try png(changed: true)
        let firstSample = try FrameFingerprint(png: source), secondSample = try FrameFingerprint(png: current)
        var response: [String: Any] = [
            "ok": false, "errorCode": "frame_stability_timeout",
            "execution": ["started": true, "inputCompleted": true, "completed": false],
            "stability": ["stable": false, "hash": secondSample.hash, "referenceHash": firstSample.hash],
            "stabilityReferenceBase64": source.base64EncodedString(),
            "frame": [
                "screenshotBase64": current.base64EncodedString(), "hash": secondSample.hash,
                "width": secondSample.width, "height": secondSample.height, "capturedAt": 100.0
            ]
        ]
        let decoded = try XCTestCapture.actionResponse(response, directory: directory)
        let result = try XCTUnwrap(decoded["result"] as? [String: Any])
        let diagnostic = try XCTUnwrap(result["stabilityDiagnostic"] as? [String: Any])
        let refURL = URL(fileURLWithPath: try XCTUnwrap(diagnostic["reference"] as? String))
        XCTAssertEqual(try Data(contentsOf: refURL), source)
        let diff = try FrameFingerprint(
            png: Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(diagnostic["difference"] as? String))))
        XCTAssertEqual(diff.pixels[0], 255)
        XCTAssertEqual(diff.pixels[4], 0)
        XCTAssertNil(decoded["stabilityReferenceBase64"])
        response["stability"] = ["stable": false, "hash": secondSample.hash, "referenceHash": "incorrect"]
        XCTAssertThrowsError(try XCTestCapture.actionResponse(response, directory: directory))
    }

    func testHostRejectsOldOrPrematureStabilityProof() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "stability-proof-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try png(), frame = try FrameFingerprint(png: image)
        var value = FrameStability(startedAt: 0)
        for threshold in [0.0, 0.2, 1.6] { try record(&value, image, threshold) }
        let proof = value.result
        var response: [String: Any] = [
            "ok": true, "execution": ["started": true, "inputCompleted": true, "completed": true],
            "stability": proof,
            "frame": [
                "screenshotBase64": image.base64EncodedString(), "hash": frame.hash,
                "width": frame.width, "height": frame.height, "capturedAt": 100.0
            ]
        ]
        XCTAssertNoThrow(try XCTestCapture.actionResponse(response, directory: directory))
        for (key, changed): (String, Any) in [
            ("algorithm", "sha256-rgba8-srgb"), ("observedForMs", 800.0),
            ("observedForMs", Double.infinity), ("minimumObservationMs", 0.0), ("comparison", NSNull())
        ] {
            var invalid = proof; invalid[key] = changed; response["stability"] = invalid
            XCTAssertThrowsError(try XCTestCapture.actionResponse(response, directory: directory))
        }
    }

    func testMovingPageReturnsCompletedInputWithFreshButUnstableFrame() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dynamic-proof-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstSample = try screenPNG(),
            secondSample = try screenPNG(patches: [
                (CGRect(x: 0, y: 0, width: 390, height: 400), [30, 80, 120])
            ])
        let fingerprint = try FrameFingerprint(png: secondSample)
        var stability = FrameStability(startedAt: 0)
        for (time, image) in [(0.0, firstSample), (0.8, firstSample), (1.6, secondSample)] {
            try record(&stability, image, time)
        }
        XCTAssertTrue(stability.observationReady); XCTAssertFalse(stability.stable)
        var response: [String: Any] = [
            "ok": true, "execution": ["started": true, "inputCompleted": true, "completed": true],
            "stability": stability.result,
            "frame": [
                "screenshotBase64": secondSample.base64EncodedString(), "hash": fingerprint.hash,
                "width": fingerprint.width, "height": fingerprint.height, "capturedAt": 100.0
            ]
        ]
        XCTAssertNoThrow(try XCTestCapture.actionResponse(response, directory: directory))
        for (key, value): (String, Any) in [
            ("samples", 1), ("observedForMs", 200.0), ("reason", "stable"), ("automaticReplayAllowed", true)
        ] {
            var invalid = stability.result; invalid[key] = value; response["stability"] = invalid
            XCTAssertThrowsError(try XCTestCapture.actionResponse(response, directory: directory))
        }
    }

    func testSuccessWithoutStableFrameEvidenceIsRejected() {
        let directory = URL(fileURLWithPath: "/private/tmp/as-missing-frame-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: directory) }
        let response: [String: Any] = [
            "ok": true, "execution": ["started": true, "inputCompleted": true, "completed": true]
        ]
        XCTAssertThrowsError(try XCTestCapture.actionResponse(response, directory: directory)) { error in
            XCTAssertEqual((error as? ActionFailure)?.code, "missing_stability_facts")
        }
    }
}
