import XCTest
import CoreGraphics
import ImageIO
@testable import IPhoneUseCore

extension ScreenGuardTests {

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
        let baseline = try ScreenGuard(
            png: screenPNG(patches: [(patch, [255, 0, 0])]), context: screenTestContext(),
            rects: [top], policy: .init())
        let changed = try baseline.check(
            png: screenPNG(patches: [(patch, [0, 130, 0])]), context: screenTestContext())
        XCTAssertGreaterThan(changed.regionChanges[0], 0)
        XCTAssertFalse(changed.accepted)
    }

    func testThresholdBoundaryIsInclusiveAndNoiseFloorIsSeparate() throws {
        let changed = try screenPNG(patches: [(CGRect(x: 20, y: 10, width: 10, height: 15), [0, 0, 0])])
        let score = try guardValue().check(png: changed, context: screenTestContext()).screenChange
        XCTAssertGreaterThan(score, 0)
        XCTAssertTrue(
            try guardValue(policy: .init(maxScreenChange: score, maxRegionChange: 0)).check(
                png: changed, context: screenTestContext()
            ).accepted)
        XCTAssertFalse(
            try guardValue(policy: .init(maxScreenChange: score.nextDown, maxRegionChange: 0)).check(
                png: changed, context: screenTestContext()
            ).accepted)
        let full = CGRect(x: 0, y: 0, width: 390, height: 844)
        let baseline = try guardValue(policy: .init(maxScreenChange: 0, maxRegionChange: 0))
        XCTAssertTrue(
            try baseline.check(
                png: screenPNG(patches: [(full, [247, 255, 255])]), context: screenTestContext()
            )
            .accepted)
        XCTAssertFalse(
            try baseline.check(
                png: screenPNG(patches: [(full, [246, 255, 255])]), context: screenTestContext()
            )
            .accepted)
    }

    func testContextChangesDimensionsAndUnreadableImagesFailClosed() throws {
        let baseline = try guardValue()
        for context in [
            screenTestContext(orientation: 2), screenTestContext(keyboardCount: 1),
            screenTestContext(scope: CGRect(x: 10, y: 10, width: 370, height: 824))
        ] {
            XCTAssertThrowsError(try baseline.check(png: screenPNG(), context: context)) {
                XCTAssertEqual($0 as? ScreenGuard.Failure, .contextChanged)
            }
        }
        XCTAssertThrowsError(
            try baseline.check(png: screenPNG(width: 780, height: 1688), context: screenTestContext()))
        XCTAssertThrowsError(try baseline.check(png: Data(), context: screenTestContext()))
        XCTAssertThrowsError(
            try ScreenGuard(
                png: screenPNG(width: 844, height: 390), context: screenTestContext(),
                rects: [ScreenRect(CGRect(x: 10, y: 10, width: 20, height: 20))], policy: .init()))
    }

    func testMalformedAndIncompleteFingerprintsCannotPass() throws {
        let original = try jsonObject(JSONEncoder().encode(guardValue()))
        for (key, value): (String, Any) in [
            ("algorithm", "unknown"), ("globalRGB", ""), ("regions", []),
            ("policy", ["maxScreenChange": 0.01, "maxRegionChange": 0.02])
        ] {
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
        XCTAssertThrowsError(
            try CoordinateGesture(start: start, end: start, screenGuard: baseline, motion: .init()).validate(
                kind: "swipe"))
        XCTAssertThrowsError(
            try CoordinateGesture(
                start: start, end: CGPoint(x: 400, y: 200), screenGuard: baseline, motion: .init()
            )
            .validate(kind: "swipe"))
        let incomplete = try ScreenGuard(
            png: screenPNG(), context: context, rects: [rects[0]], policy: .init())
        XCTAssertThrowsError(
            try CoordinateGesture(start: start, end: end, screenGuard: incomplete, motion: .init()).validate(
                kind: "swipe"))
    }

    func testSwipeMotionSurvivesBothTargetModesAndWireEncoding() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "swipe-motion-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ObservationCache(directory: directory)
        _ = try cache.store(observationFixture())
        let expected = SwipeMotion(velocity: 100.5, pressDuration: 0.25, holdDuration: 0.2)
        for target: [String: Any] in [
            ["reference": "o1:e1", "direction": "up"],
            ["reference": "o1", "fromX": 98, "fromY": 385, "toX": 98, "toY": 337]
        ] {
            var request = target
            request.merge(expected.result) { _, new in new }
            let action = try DeviceAction(operation: "swipe", request: request)
            let fields = try XCTestBackend.actionFields(action, target: cache.resolveTarget(for: action))
            let raw = try XCTUnwrap(fields["gesture"] as? [String: Any])
            let decoded = try JSONDecoder().decode(CoordinateGesture.self, from: jsonData(raw))
            XCTAssertEqual(decoded.motion, expected)
            XCTAssertNoThrow(try decoded.validate(kind: "swipe"))
            XCTAssertThrowsError(try decoded.validate(kind: "tap"))
            for invalid: Any in [
                NSNull(), ["velocity": 0, "pressDuration": 0, "holdDuration": 0],
                ["velocity": 100, "pressDuration": 0, "holdDuration": 6]
            ] {
                var altered = raw
                altered["motion"] = invalid
                XCTAssertThrowsError(
                    try JSONDecoder().decode(CoordinateGesture.self, from: jsonData(altered)).validate(
                        kind: "swipe"))
            }
        }
    }

    func testSwipeBudgetIncludesHoldsAndScreenshotScale() throws {
        let context = screenTestContext(), start = CGPoint(x: 98, y: 385), end = CGPoint(x: 98, y: 337)
        let baseline = try ScreenGuard(
            png: screenPNG(width: 1170, height: 2532), context: context,
            rects: CoordinateGesture.actionRegions(start: start, end: end, screen: context.screen.cgRect),
            policy: .init())
        var gesture = CoordinateGesture(
            start: start, end: end, screenGuard: baseline,
            motion: SwipeMotion(velocity: 18, pressDuration: 1, holdDuration: 1))
        XCTAssertNoThrow(try gesture.validate(kind: "swipe")) // 48 * 3 / 18 + 1 + 1 = 10.
        gesture.motion?.holdDuration = 1.01
        XCTAssertThrowsError(try gesture.validate(kind: "swipe"))
        gesture.motion = SwipeMotion(velocity: 10)
        XCTAssertThrowsError(try gesture.validate(kind: "swipe"))
    }
}
