import XCTest
@testable import IPhoneUseCore

final class DynamicTargetGuardTests: XCTestCase {
    private let target = ScreenRect(CGRect(x: 12, y: 50, width: 32, height: 32))
    private let anchor = ScreenRect(CGRect(x: 80, y: 700, width: 100, height: 30))
    private func frame(background: [UInt8] = [80, 130, 170], moved: Bool = false,
                       changedAnchor: Bool = false, covered: Bool = false) throws -> Data {
        var patches: [(CGRect, [UInt8])] = [(CGRect(x: 0, y: 0, width: 390, height: 844), background)]
        let offset = moved ? 4.0 : 0.0
        // A bounded L-shaped control and a distinct two-stroke page label.
        patches += [(CGRect(x: 22 + offset, y: 56, width: 4, height: 20), [255, 255, 255]),
                    (CGRect(x: 22 + offset, y: 72, width: 14, height: 4), [255, 255, 255]),
                    (CGRect(x: 90, y: 705, width: 4, height: 20), [255, 255, 255]),
                    (CGRect(x: changedAnchor ? 130 : 110, y: 705, width: 4, height: 20), [255, 255, 255])]
        if covered { patches += [(target.cgRect, [180, 180, 180])] }
        return try screenPNG(patches: patches)
    }
    private func makeGuard() throws -> ScreenGuard {
        try ScreenGuard(png: frame(), context: screenTestContext(),
                        rects: CoordinateGesture.actionRegions(start: CGPoint(x: 28, y: 66), end: nil,
                                                               screen: screenTestContext().screen.cgRect),
                        policy: .init(), dynamicRects: [target, anchor])
    }
    func testBackgroundChangesButBothExplicitForegroundShapesMustMatch() throws {
        let guardValue = try makeGuard()
        let decoded = try JSONDecoder().decode(ScreenGuard.self, from: JSONEncoder().encode(guardValue))
        let changedVideo = try frame(background: [180, 60, 110])
        let check = try decoded.check(png: changedVideo, context: screenTestContext())
        XCTAssertTrue(check.accepted)
        XCTAssertGreaterThan(check.screenChange, 0.9)
        let strict = try ScreenGuard(png: frame(), context: screenTestContext(), rects: guardValue.regions.map(\.rect), policy: .init())
        XCTAssertFalse(try strict.check(png: changedVideo, context: screenTestContext()).accepted)
        for png in [try frame(moved: true), try frame(changedAnchor: true), try frame(covered: true), try screenPNG()] {
            XCTAssertFalse(try decoded.check(png: png, context: screenTestContext()).accepted)
        }
        XCTAssertThrowsError(try decoded.check(png: changedVideo, context: screenTestContext(orientation: 3)))
    }
    func testOnlyTapInsideSelectedTargetAndNoBlankOrOverlappingProofs() throws {
        let guardValue = try makeGuard()
        let tap = CoordinateGesture(start: CGPoint(x: 28, y: 66), end: nil, screenGuard: guardValue)
        XCTAssertNoThrow(try tap.validate(kind: "tap"))
        XCTAssertThrowsError(try tap.validate(kind: "double-tap"))
        XCTAssertThrowsError(try CoordinateGesture(start: CGPoint(x: 200, y: 400), end: nil, screenGuard: guardValue).validate(kind: "tap"))
        XCTAssertThrowsError(try ScreenGuard(png: screenPNG(), context: screenTestContext(), rects: [target], policy: .init(), dynamicRects: [target, anchor]))
        XCTAssertThrowsError(try ScreenGuard(png: frame(), context: screenTestContext(), rects: [target], policy: .init(), dynamicRects: [target, target]))
        XCTAssertThrowsError(try ScreenGuard(png: frame(), context: screenTestContext(), rects: [target], policy: .init(maxScreenChange: 1), dynamicRects: [target, anchor]))
    }
    func testRunnerRequiresBothLocalProofsWhileReportingActualGlobalChange() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dynamic-proof-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let expected = try makeGuard(), png = try frame(background: [180, 60, 110])
        let fingerprint = try FrameFingerprint(png: png)
        let proof = try expected.check(png: png, context: screenTestContext()).result
        var response: [String: Any] = ["ok": true, "screenGuard": proof,
            "execution": ["started": true, "inputCompleted": true, "completed": true],
            "stability": ["stable": false, "hash": fingerprint.hash, "samples": 3,
                "algorithm": FrameComparison.algorithm, "reason": "dynamic_or_transitioning",
                "automaticReplayAllowed": false, "observedForMs": 1600.0, "elapsedMs": 1600.0],
            "frame": ["hash": fingerprint.hash, "width": fingerprint.width, "height": fingerprint.height,
                "capturedAt": 100.0, "screenshotBase64": png.base64EncodedString()]]
        XCTAssertNoThrow(try ActionReply.decode(XCTestCapture.actionResponse(response, directory: directory, expectedGuard: expected)))
        for (key, value): (String, Any) in [("dynamicMatches", [true, false]), ("dynamicMatches", [true]),
            ("validationScope", "whole_screen"), ("algorithm", ScreenGuard.algorithm),
            ("screenChange", -0.1), ("screenChange", 1.1), ("regionChanges", [0.0])] {
            var evidence = proof; evidence[key] = value; response["screenGuard"] = evidence
            XCTAssertThrowsError(try XCTestCapture.actionResponse(response, directory: directory, expectedGuard: expected)) {
                XCTAssertEqual(($0 as? ActionFailure)?.code, "missing_screen_guard_facts")
                XCTAssertEqual(($0 as? ActionFailure)?.possiblyExecuted, true)
            }
        }
    }
    func testTranslucentControlsMatchAcrossBrightnessWithoutAcceptingDifferentShapes() throws {
        func translucent(_ background: UInt8, moved: Bool = false) throws -> Data {
            let foreground = UInt8((Int(background) + 255) / 2)
            let offset = moved ? 4.0 : 0
            return try screenPNG(patches: [
                (CGRect(x: 0, y: 0, width: 390, height: 844), [background, background, background]),
                (CGRect(x: 22 + offset, y: 56, width: 4, height: 20), [foreground, foreground, foreground]),
                (CGRect(x: 22 + offset, y: 72, width: 14, height: 4), [foreground, foreground, foreground]),
                (CGRect(x: 90, y: 705, width: 4, height: 20), [foreground, foreground, foreground]),
                (CGRect(x: 110, y: 705, width: 4, height: 20), [foreground, foreground, foreground])])
        }
        let guardValue = try ScreenGuard(png: translucent(20), context: screenTestContext(),
                                        rects: [target], policy: .init(), dynamicRects: [target, anchor])
        XCTAssertTrue(try guardValue.check(png: translucent(150), context: screenTestContext()).accepted)
        XCTAssertFalse(try guardValue.check(png: translucent(150, moved: true), context: screenTestContext()).accepted)
        XCTAssertFalse(try guardValue.check(png: screenPNG(), context: screenTestContext()).accepted)
    }
    func testRequestRequiresBothRegionsAndRejectsMixedBypassesInBothModes() throws {
        let base: [String: Any] = ["reference": "o1", "x": 28, "y": 66,
                                  "dynamicTarget": "12,50,32,32", "dynamicAnchor": "80,700,100,30"]
        for native in [false, true] {
            XCTAssertEqual(try DeviceAction(operation: "tap", request: base, allowScreenText: native).dynamicRects?.count, 2)
            for (key, value): (String, Any) in [("dynamicAnchor", "bad"), ("maxScreenChange", 1), ("ignoreRect", "0,100,100,100")] {
                var invalid = base; invalid[key] = value
                XCTAssertThrowsError(try DeviceAction(operation: "tap", request: invalid, allowScreenText: native))
            }
            var incomplete = base; incomplete.removeValue(forKey: "dynamicAnchor")
            XCTAssertThrowsError(try DeviceAction(operation: "tap", request: incomplete, allowScreenText: native))
            XCTAssertThrowsError(try DeviceAction(operation: "double-tap", request: base, allowScreenText: native))
        }
    }
    func testUnusableBaselineIdentifiesComponentAndRecoversOnlyWithCorrectedGeometry() throws {
        for native in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try SessionPaths.secureDirectory(directory)
            defer { try? FileManager.default.removeItem(at: directory) }
            let cache = ObservationCache(directory: directory)
            let fixture = try observationFixture()
            var metadata = fixture.metadata
            if native { metadata["backend"] = "apple-native" }
            let capture = CapturedObservation(nodes: fixture.nodes, metadata: metadata, screenshot: try frame())
            for component in ["target", "anchor"] {
                // Both bad rectangles are valid geometry but contain only background.
                let targetString = component == "target" ? "12,100,32,32" : "12,50,32,32"
                let anchorString = component == "anchor" ? "80,740,100,30" : "80,700,100,30"
                for _ in 0..<2 {
                    let stored = try cache.store(capture)
                    let ref = try XCTUnwrap(stored["observation"] as? String)
                    let action = try DeviceAction(operation: "tap", request: ["reference": ref, "x": 28,
                        "y": component == "target" ? 116 : 66,
                        "dynamicTarget": targetString, "dynamicAnchor": anchorString], allowScreenText: native)
                    XCTAssertThrowsError(try cache.resolveTarget(for: action)) { error in
                        guard let failure = error as? ActionFailure else { return XCTFail("Unexpected: \(error)") }
                        XCTAssertEqual(failure.code, "dynamic_\(component)_unusable")
                        XCTAssertFalse(failure.possiblyExecuted)
                        let diagnostic = failure.result?["screenGuardPreparation"] as? [String: Any]
                        XCTAssertEqual(diagnostic?["component"] as? String, component)
                        XCTAssertEqual(diagnostic?["stage"] as? String, "baseline_preparation")
                        XCTAssertEqual(diagnostic?["reason"] as? String, "insufficient_shape_features")
                        XCTAssertEqual(diagnostic?["coordinateSpace"] as? String, "screen_points")
                        XCTAssertNotNil(diagnostic?["rect"])
                    }
                }
            }
            let stored = try cache.store(capture)
            let corrected = try DeviceAction(operation: "tap", request: ["reference": stored["observation"]!,
                "x": 28, "y": 66, "dynamicTarget": "12,50,32,32", "dynamicAnchor": "80,700,100,30"], allowScreenText: native)
            let guardValue = try XCTUnwrap(cache.resolveTarget(for: corrected).gesture?.screenGuard)
            XCTAssertTrue(try guardValue.check(png: frame(background: [160, 80, 40]), context: screenTestContext()).accepted)
        }
    }

    func testMalformedGeometryAndImageAreNotMisdiagnosedAsWeakFeatures() throws {
        for rects in [[target], [target, target], [target, ScreenRect(CGRect(x: 80, y: 840, width: 100, height: 30))]] {
            XCTAssertThrowsError(try ScreenGuard(png: screenPNG(), context: screenTestContext(), rects: [target],
                                                policy: .init(), dynamicRects: rects)) { error in
                XCTAssertEqual(error as? ScreenGuard.Failure, .invalidGuard)
            }
        }
        XCTAssertThrowsError(try ScreenGuard(png: Data(), context: screenTestContext(), rects: [target],
                                            policy: .init(), dynamicRects: [target, anchor])) { error in
            XCTAssertFalse(error is ScreenGuard.DynamicBaselineFailure)
        }
    }

    func testSerializedGuardCannotExpandScopeOrRemoveOneLandmark() throws {
        let expected = try makeGuard()
        let encoded = try JSONEncoder().encode(expected)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let regions = try XCTUnwrap(original["dynamicOverlay"] as? [[String: Any]])
        for (index, key, value): (Int, String, Double) in [(0, "width", 97), (1, "width", 257),
            (0, "height", 97), (1, "height", 97), (0, "x", -1), (1, "y", 840)] {
            var raw = original, altered = regions
            var rect = try XCTUnwrap(altered[index]["rect"] as? [String: Any])
            rect[key] = value; altered[index]["rect"] = rect; raw["dynamicOverlay"] = altered
            let guardValue = try JSONDecoder().decode(ScreenGuard.self, from: jsonData(raw))
            XCTAssertThrowsError(try guardValue.validate())
        }
        var missing = original; missing["dynamicOverlay"] = [regions[0]]
        XCTAssertThrowsError(try JSONDecoder().decode(ScreenGuard.self, from: jsonData(missing)).validate())
        missing.removeValue(forKey: "dynamicOverlay")
        XCTAssertThrowsError(try JSONDecoder().decode(ScreenGuard.self, from: jsonData(missing)).validate())

        // Existing non-dynamic guards remain decodable without the new optional field.
        let strict = try ScreenGuard(png: frame(), context: screenTestContext(), rects: expected.regions.map(\.rect), policy: .init())
        let legacy = try JSONEncoder().encode(strict)
        XCTAssertNoThrow(try JSONDecoder().decode(ScreenGuard.self, from: legacy).validate())
    }
}
