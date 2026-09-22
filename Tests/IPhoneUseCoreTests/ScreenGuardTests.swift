import XCTest
import CoreGraphics
import ImageIO
@testable import IPhoneUseCore

// Top-left pixel coordinates, like AX screen points. No ignored device artifacts are required.
func screenPNG(width: Int = 390, height: Int = 844, patches: [(CGRect, [UInt8])] = [], dpi: Int = 72) throws -> Data {
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for (rect, rgb) in patches {
        for y in max(0, Int(rect.minY))..<min(height, Int(rect.maxY)) {
            for x in max(0, Int(rect.minX))..<min(width, Int(rect.maxX)) {
                for channel in 0..<3 { pixels[(y * width + x) * 4 + channel] = rgb[channel] }
            }
        }
    }
    let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
    let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
        decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let data = NSMutableData()
    let output = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(output, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(output))
    return data as Data
}

func screenTestContext(scope: CGRect? = nil, orientation: Int = 1, keyboardCount: Int = 0) -> ScreenContext {
    let screen = CGRect(x: 0, y: 0, width: 390, height: 844)
    return ScreenContext(screen: ScreenRect(screen), scope: ScreenRect(scope ?? screen), orientation: orientation, keyboardCount: keyboardCount)
}

final class ScreenGuardTests: XCTestCase {
    private let target = CGPoint(x: 200, y: 600)

    private func guardValue(policy: ScreenGuard.Policy = .init(), extra: [ScreenRect] = []) throws -> ScreenGuard {
        let context = screenTestContext()
        let rects = CoordinateGesture.actionRegions(start: target, end: nil, screen: context.screen.cgRect) + extra
        return try ScreenGuard(png: screenPNG(), context: context, rects: rects, policy: policy)
    }

    func testIdenticalPixelsAndDifferentEncodingMetadataPass() throws {
        let baseline = try guardValue()
        let checked = try baseline.check(png: screenPNG(dpi: 144), context: screenTestContext())
        XCTAssertTrue(checked.accepted)
        XCTAssertEqual(checked.screenChange, 0)
        XCTAssertEqual(checked.regionChanges, [0])
        let decoded = try JSONDecoder().decode(ScreenGuard.self, from: JSONEncoder().encode(baseline))
        XCTAssertEqual(decoded.globalRGB, baseline.globalRGB)
        XCTAssertTrue(try decoded.check(png: screenPNG(), context: screenTestContext()).accepted)
    }

    func testSmallUnrelatedRefreshPassesButSmallTargetChangeIsRejected() throws {
        let baseline = try guardValue()
        let clock = try screenPNG(patches: [(CGRect(x: 20, y: 10, width: 6, height: 8), [0, 0, 0])])
        let refresh = try baseline.check(png: clock, context: screenTestContext())
        XCTAssertGreaterThan(refresh.screenChange, 0)
        XCTAssertLessThanOrEqual(refresh.screenChange, baseline.policy.maxScreenChange)
        XCTAssertTrue(refresh.accepted)
        let targetChange = try screenPNG(patches: [(CGRect(x: 198, y: 595, width: 4, height: 10), [0, 0, 0])])
        let moved = try baseline.check(png: targetChange, context: screenTestContext())
        XCTAssertLessThanOrEqual(moved.screenChange, baseline.policy.maxScreenChange)
        XCTAssertGreaterThan(moved.regionChanges[0], 0)
        XCTAssertFalse(moved.accepted)
    }

    func testLargeScreenChangeIsRejectedEvenWithAnUnchangedTarget() throws {
        let image = try screenPNG(patches: [(CGRect(x: 0, y: 0, width: 390, height: 300), [0, 0, 0])])
        let checked = try guardValue().check(png: image, context: screenTestContext())
        XCTAssertEqual(checked.regionChanges, [0])
        XCTAssertGreaterThan(checked.screenChange, 0.01)
        XCTAssertFalse(checked.accepted)
    }

    func testExplicitContextRegionRejectsChangedDateWithUnchangedSaveButton() throws {
        let date = ScreenRect(CGRect(x: 40, y: 300, width: 100, height: 50))
        let image = try screenPNG(patches: [(CGRect(x: 45, y: 315, width: 3, height: 12), [0, 0, 0])])
        XCTAssertTrue(try guardValue().check(png: image, context: screenTestContext()).accepted)
        let protected = try guardValue(extra: [date]).check(png: image, context: screenTestContext())
        XCTAssertEqual(protected.regionChanges[0], 0)
        XCTAssertGreaterThan(protected.regionChanges[1], 0)
        XCTAssertFalse(protected.accepted)
    }

    func testRegionsUseTopLeftCoordinatesAndPreserveColor() throws {
        let top = ScreenRect(CGRect(x: 20, y: 20, width: 40, height: 40))
        let patch = CGRect(x: 30, y: 30, width: 8, height: 8)
        let baseline = try ScreenGuard(png: screenPNG(patches: [(patch, [255, 0, 0])]), context: screenTestContext(),
                                      rects: [top], policy: .init())
        let changed = try baseline.check(png: screenPNG(patches: [(patch, [0, 130, 0])]), context: screenTestContext())
        XCTAssertGreaterThan(changed.regionChanges[0], 0)
        XCTAssertFalse(changed.accepted)
    }

    func testThresholdBoundaryIsInclusiveAndNoiseFloorIsSeparate() throws {
        let changed = try screenPNG(patches: [(CGRect(x: 20, y: 10, width: 10, height: 15), [0, 0, 0])])
        let score = try guardValue().check(png: changed, context: screenTestContext()).screenChange
        XCTAssertGreaterThan(score, 0)
        XCTAssertTrue(try guardValue(policy: .init(maxScreenChange: score, maxRegionChange: 0)).check(png: changed, context: screenTestContext()).accepted)
        XCTAssertFalse(try guardValue(policy: .init(maxScreenChange: score.nextDown, maxRegionChange: 0)).check(png: changed, context: screenTestContext()).accepted)
        let full = CGRect(x: 0, y: 0, width: 390, height: 844)
        let baseline = try guardValue(policy: .init(maxScreenChange: 0, maxRegionChange: 0))
        XCTAssertTrue(try baseline.check(png: screenPNG(patches: [(full, [247, 255, 255])]), context: screenTestContext()).accepted)
        XCTAssertFalse(try baseline.check(png: screenPNG(patches: [(full, [246, 255, 255])]), context: screenTestContext()).accepted)
    }

    func testContextChangesDimensionsAndUnreadableImagesFailClosed() throws {
        let baseline = try guardValue()
        for context in [screenTestContext(orientation: 2), screenTestContext(keyboardCount: 1),
                        screenTestContext(scope: CGRect(x: 10, y: 10, width: 370, height: 824))] {
            XCTAssertThrowsError(try baseline.check(png: screenPNG(), context: context)) {
                XCTAssertEqual($0 as? ScreenGuard.Failure, .contextChanged)
            }
        }
        XCTAssertThrowsError(try baseline.check(png: screenPNG(width: 780, height: 1688), context: screenTestContext()))
        XCTAssertThrowsError(try baseline.check(png: Data(), context: screenTestContext()))
        XCTAssertThrowsError(try ScreenGuard(png: screenPNG(width: 844, height: 390), context: screenTestContext(),
                                           rects: [ScreenRect(CGRect(x: 10, y: 10, width: 20, height: 20))], policy: .init()))
    }

    func testMalformedAndIncompleteFingerprintsCannotPass() throws {
        let original = try jsonObject(JSONEncoder().encode(guardValue()))
        for (key, value): (String, Any) in [("algorithm", "unknown"), ("globalRGB", ""), ("regions", []),
            ("policy", ["maxScreenChange": 0.01, "maxRegionChange": 0.02])] {
            var raw = original
            raw[key] = value
            let invalid = try JSONDecoder().decode(ScreenGuard.self, from: jsonData(raw))
            XCTAssertThrowsError(try invalid.check(png: screenPNG(), context: screenTestContext()))
        }
    }

    func testSwipeMustProtectTouchDownAndCorridorAndHaveValidEndpoints() throws {
        let context = screenTestContext(), start = CGPoint(x: 100, y: 600), end = CGPoint(x: 100, y: 200)
        let rects = CoordinateGesture.actionRegions(start: start, end: end, screen: context.screen.cgRect)
        let baseline = try ScreenGuard(png: screenPNG(), context: context, rects: rects, policy: .init())
        let gesture = CoordinateGesture(start: start, end: end, screenGuard: baseline, motion: .init())
        XCTAssertNoThrow(try gesture.validate(kind: "swipe"))
        XCTAssertThrowsError(try gesture.validate(kind: "tap"))
        let changed = try screenPNG(patches: [(CGRect(x: 98, y: 390, width: 4, height: 20), [0, 0, 0])])
        let checked = try baseline.check(png: changed, context: context)
        XCTAssertEqual(checked.regionChanges[0], 0)
        XCTAssertGreaterThan(checked.regionChanges[1], 0)
        XCTAssertFalse(checked.accepted)
        XCTAssertThrowsError(try CoordinateGesture(start: start, end: start, screenGuard: baseline, motion: .init()).validate(kind: "swipe"))
        XCTAssertThrowsError(try CoordinateGesture(start: start, end: CGPoint(x: 400, y: 200), screenGuard: baseline, motion: .init()).validate(kind: "swipe"))
        let incomplete = try ScreenGuard(png: screenPNG(), context: context, rects: [rects[0]], policy: .init())
        XCTAssertThrowsError(try CoordinateGesture(start: start, end: end, screenGuard: incomplete, motion: .init()).validate(kind: "swipe"))
    }

    func testSwipeMotionSurvivesBothTargetModesAndWireEncoding() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("swipe-motion-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ObservationCache(directory: directory)
        _ = try cache.store(observationFixture())
        let expected = SwipeMotion(velocity: 100.5, pressDuration: 0.25, holdDuration: 0.2)
        for target: [String: Any] in [["reference": "o1:e1", "direction": "up"],
            ["reference": "o1", "fromX": 98, "fromY": 385, "toX": 98, "toY": 337]] {
            var request = target
            request.merge(expected.result) { _, new in new }
            let action = try DeviceAction(operation: "swipe", request: request)
            let fields = try XCTestBackend.actionFields(action, target: cache.resolveTarget(for: action))
            let raw = try XCTUnwrap(fields["gesture"] as? [String: Any])
            let decoded = try JSONDecoder().decode(CoordinateGesture.self, from: jsonData(raw))
            XCTAssertEqual(decoded.motion, expected)
            XCTAssertNoThrow(try decoded.validate(kind: "swipe"))
            XCTAssertThrowsError(try decoded.validate(kind: "tap"))
            for invalid: Any in [NSNull(), ["velocity": 0, "pressDuration": 0, "holdDuration": 0],
                                  ["velocity": 100, "pressDuration": 0, "holdDuration": 6]] {
                var altered = raw
                altered["motion"] = invalid
                XCTAssertThrowsError(try JSONDecoder().decode(CoordinateGesture.self, from: jsonData(altered)).validate(kind: "swipe"))
            }
        }
    }

    func testSwipeBudgetIncludesHoldsAndScreenshotScale() throws {
        let context = screenTestContext(), start = CGPoint(x: 98, y: 385), end = CGPoint(x: 98, y: 337)
        let baseline = try ScreenGuard(png: screenPNG(width: 1170, height: 2532), context: context,
            rects: CoordinateGesture.actionRegions(start: start, end: end, screen: context.screen.cgRect), policy: .init())
        var gesture = CoordinateGesture(start: start, end: end, screenGuard: baseline,
            motion: SwipeMotion(velocity: 18, pressDuration: 1, holdDuration: 1))
        XCTAssertNoThrow(try gesture.validate(kind: "swipe")) // 48 * 3 / 18 + 1 + 1 = 10.
        gesture.motion?.holdDuration = 1.01
        XCTAssertThrowsError(try gesture.validate(kind: "swipe"))
        gesture.motion = SwipeMotion(velocity: 10)
        XCTAssertThrowsError(try gesture.validate(kind: "swipe"))
    }

    func testUnnamedSiblingControlsResolveToCoordinatesWithoutSendingAXPaths() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("guard-targets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ObservationCache(directory: directory), fixture = try observationFixture()
        var nodes = [fixture.nodes[0]]
        for index in 1...2 {
            let attributes: [String: Any] = ["index": index, "parent": 0, "type": 46, "identifier": "", "label": "", "enabled": true,
                "value": NSNull(), "frame": ["x": Double(index - 1) * 195, "y": 265.0, "width": 195.0, "height": 240.0]]
            nodes.append(AXNode(index: index, parent: 0, role: "scroll_view", attributes: attributes))
        }
        _ = try cache.store(CapturedObservation(nodes: nodes, metadata: fixture.metadata, screenshot: fixture.screenshot))
        for index in 1...2 {
            let action = try DeviceAction(operation: "swipe", request: ["reference": "o1:e\(index + 1)", "direction": "up"])
            let target = try cache.resolveTarget(for: action)
            let gesture = try XCTUnwrap(target.gesture)
            XCTAssertEqual(gesture.start.x, Double(index - 1) * 195 + 97.5)
            XCTAssertEqual(gesture.start.y, 457)
            XCTAssertEqual(gesture.end?.y, 313)
            XCTAssertTrue(target.path.isEmpty)
            let fields = try XCTestBackend.actionFields(action, target: target)
            XCTAssertNil((fields["target"] as? [String: Any])?["path"])
            XCTAssertFalse(String(decoding: try jsonData(fields), as: UTF8.self).contains("o1:e"))
        }
    }

    func testExplicitSwipeAndMaximumProtectionFitWireBudget() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("guard-budget-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ObservationCache(directory: directory)
        _ = try cache.store(observationFixture())
        let action = try DeviceAction(operation: "swipe", request: ["reference": "o1", "fromX": 100, "fromY": 600,
            "toX": 100, "toY": 200, "protect": ["o1:e1", "o1:e1", "o1:e1"]])
        let target = try cache.resolveTarget(for: action)
        XCTAssertEqual(target.gesture?.screenGuard.regions.count, 5)
        XCTAssertLessThan(try jsonData(XCTestBackend.actionFields(action, target: target)).count, 60_000)
        let point = try DeviceAction(operation: "tap", request: ["reference": "o1", "x": 500, "y": 30])
        XCTAssertThrowsError(try cache.resolveTarget(for: point))
        XCTAssertNoThrow(try cache.resolveCurrent(ObservationReference("o1:e1")))
    }

    func testGuardRejectionPreservesNoInputFactsAndScoresInActionReply() throws {
        let response: [String: Any] = ["ok": false, "errorCode": "screen_changed", "requiresObservation": true,
            "execution": ["started": false, "inputCompleted": false, "completed": false],
            "screenGuard": ["accepted": false, "screenChange": 0.001, "regionChanges": [0.2]]]
        let decoded = try XCTestCapture.actionResponse(response, directory: FileManager.default.temporaryDirectory)
        XCTAssertThrowsError(try ActionReply.decode(decoded)) { error in
            let failure = error as? ActionFailure
            XCTAssertEqual(failure?.possiblyExecuted, false)
            XCTAssertEqual(failure?.requiresObservation, true)
            XCTAssertEqual((failure?.result?["screenGuard"] as? [String: Any])?["screenChange"] as? Double, 0.001)
        }
    }

    func testOlderRunnerCannotSilentlySkipScreenGuards() throws {
        let supported: [String: Any] = ["lifecycleOwner": "host", "observationVersion": 2, "actionVersion": 6,
            "launchVersion": 1, "frameStabilityVersion": 2, "screenGuardVersion": 1]
        XCTAssertNoThrow(try XCTestBackend.validateCapabilities(supported))
        for key in ["observationVersion", "actionVersion", "screenGuardVersion", "frameStabilityVersion"] {
            var older = supported
            older[key] = 0
            XCTAssertThrowsError(try XCTestBackend.validateCapabilities(older))
        }
        var withoutMotion = supported
        withoutMotion["actionVersion"] = 4
        XCTAssertThrowsError(try XCTestBackend.validateCapabilities(withoutMotion)) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "runner_needs_rebuild")
        }
    }

    func testSwipeSuccessMustConfirmRequestedMotion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("swipe-receipt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try screenPNG(), frame = try FrameFingerprint(png: png)
        let motion = SwipeMotion(velocity: 100, pressDuration: 0.5, holdDuration: 0.2)
        var response: [String: Any] = ["ok": true, "result": ["kind": "swipe", "motion": motion.result],
            "execution": ["started": true, "inputCompleted": true, "completed": true],
            "stability": ["stable": true, "hash": frame.hash, "consecutiveFrames": 3, "stableForMs": 400.0, "elapsedMs": 1600.0, "algorithm": FrameComparison.algorithm, "minimumObservationMs": 1500.0, "observedForMs": 1500.0, "comparison": ["equivalent": true, "dimensionsMatch": true, "changedPixels": 0, "colorTolerance": 2.5, "maxChannelDelta": 4]],
            "frame": ["hash": frame.hash, "width": frame.width, "height": frame.height, "capturedAt": 100.0,
                      "screenshotBase64": png.base64EncodedString()]]
        let result = try ActionReply.decode(XCTestCapture.actionResponse(response, directory: directory, expectedMotion: motion))
        XCTAssertEqual((result["motion"] as? [String: Any])?["velocity"] as? Double, 100)
        for value: Any in [NSNull(), SwipeMotion().result, ["velocity": 100, "pressDuration": 0.5],
                          ["velocity": 100, "pressDuration": 0.5, "holdDuration": 0]] {
            response["result"] = ["kind": "swipe", "motion": value]
            XCTAssertThrowsError(try XCTestCapture.actionResponse(response, directory: directory, expectedMotion: motion)) {
                let failure = $0 as? ActionFailure
                XCTAssertEqual(failure?.code, "missing_swipe_motion_facts")
                XCTAssertEqual(failure?.possiblyExecuted, true)
                XCTAssertEqual(failure?.requiresObservation, true)
                XCTAssertNotNil(failure?.result?["frame"])
            }
        }
    }

    func testClaimedSuccessRequiresConsistentGuardEvidence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("guard-evidence-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try screenPNG(), expected = try guardValue(), frame = try FrameFingerprint(png: png)
        let proof = try expected.check(png: png, context: screenTestContext()).result
        var response: [String: Any] = ["ok": true, "screenGuard": proof,
            "execution": ["started": true, "inputCompleted": true, "completed": true],
            "stability": ["stable": true, "hash": frame.hash, "consecutiveFrames": 3, "stableForMs": 400.0, "elapsedMs": 1600.0, "algorithm": FrameComparison.algorithm, "minimumObservationMs": 1500.0, "observedForMs": 1500.0, "comparison": ["equivalent": true, "dimensionsMatch": true, "changedPixels": 0, "colorTolerance": 2.5, "maxChannelDelta": 4]],
            "frame": ["hash": frame.hash, "width": frame.width, "height": frame.height, "capturedAt": 100.0,
                      "screenshotBase64": png.base64EncodedString()]]
        XCTAssertNoThrow(try ActionReply.decode(XCTestCapture.actionResponse(response, directory: directory, expectedGuard: expected)))
        for (key, value): (String, Any) in [("accepted", false), ("algorithm", "other"), ("maxScreenChange", 1.0),
            ("screenChange", 0.2), ("regionChanges", []), ("regionChanges", [0.1])] {
            var evidence = proof
            evidence[key] = value
            response["screenGuard"] = evidence
            XCTAssertThrowsError(try XCTestCapture.actionResponse(response, directory: directory, expectedGuard: expected)) {
                XCTAssertEqual(($0 as? ActionFailure)?.code, "missing_screen_guard_facts")
                XCTAssertEqual(($0 as? ActionFailure)?.possiblyExecuted, true)
                XCTAssertNotNil(($0 as? ActionFailure)?.result?["frame"])
            }
        }
        response.removeValue(forKey: "screenGuard")
        XCTAssertThrowsError(try XCTestCapture.actionResponse(response, directory: directory, expectedGuard: expected))
    }
}
