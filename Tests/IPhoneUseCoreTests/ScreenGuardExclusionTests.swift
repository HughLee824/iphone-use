import XCTest
import CoreGraphics
@testable import IPhoneUseCore

final class ScreenGuardExclusionTests: XCTestCase {
    private let video = ScreenRect(CGRect(x: 60, y: 150, width: 180, height: 200))
    private let target = CGPoint(x: 315, y: 685)

    private func makeGuard(png: Data? = nil, end: CGPoint? = nil, extra: [ScreenRect] = []) throws -> ScreenGuard {
        let context = screenTestContext()
        return try ScreenGuard(png: png ?? screenPNG(), context: context,
            rects: CoordinateGesture.actionRegions(start: target, end: end, screen: context.screen.cgRect) + extra,
            policy: .init(), ignoring: video)
    }

    func testVideoChangesPassOnlyWithExplicitExclusionAndRetainRawEvidence() throws {
        let baseline = try makeGuard()
        let frame = try screenPNG(patches: [(video.cgRect, [20, 80, 180])])
        let check = try baseline.check(png: frame, context: screenTestContext())
        XCTAssertTrue(check.accepted)
        XCTAssertEqual(check.screenChange, 0)
        XCTAssertEqual(check.regionChanges, [0])
        XCTAssertGreaterThan(try XCTUnwrap(check.rawScreenChange), 0.01)
        XCTAssertEqual(check.ignoredRect, video)
        XCTAssertEqual(check.result["algorithm"] as? String, ScreenGuard.maskedAlgorithm)
        let strict = try ScreenGuard(png: screenPNG(), context: screenTestContext(),
            rects: baseline.regions.map(\.rect), policy: .init())
        XCTAssertFalse(try strict.check(png: frame, context: screenTestContext()).accepted)
        let roundTrip = try JSONDecoder().decode(ScreenGuard.self, from: JSONEncoder().encode(baseline))
        XCTAssertTrue(try roundTrip.check(png: frame, context: screenTestContext()).accepted)
    }

    func testOnePixelVideoRimDoesNotBecomeWholeGridCells() throws {
        let context = screenTestContext()
        let ignored = ScreenRect(CGRect(x: 18, y: 89, width: 177, height: 60))
        let field = ScreenRect(CGRect(x: 17, y: 209, width: 356, height: 161))
        // The agent selected the visible point rectangle; the rasterized edge
        // extends one native pixel beyond it. Never enlarge that rectangle.
        let rim = CGRect(x: 53, y: 266, width: 533, height: 182)
        let before = try screenPNG(width: 1170, height: 2532, patches: [(rim, [255, 145, 30])])
        let after = try screenPNG(width: 1170, height: 2532, patches: [(rim, [0, 183, 211])])
        let guardValue = try ScreenGuard(png: before, context: context, rects: [field], policy: .init(), ignoring: ignored)
        let check = try guardValue.check(png: after, context: context)
        XCTAssertLessThan(check.screenChange, 0.01)
        XCTAssertTrue(check.accepted)
        XCTAssertEqual(check.ignoredRect, ignored)
        XCTAssertGreaterThan(try XCTUnwrap(check.rawScreenChange), 0.01)
        // Material motion outside the exact selected rectangle still fails.
        let moved = try screenPNG(width: 1170, height: 2532,
            patches: [(CGRect(x: 54, y: 267, width: 891, height: 180), [0, 183, 211])])
        XCTAssertFalse(try guardValue.check(png: moved, context: context).accepted)
        // Native field comparison must still see even a thin character edit.
        let edited = try screenPNG(width: 1170, height: 2532,
            patches: [(rim, [0, 183, 211]), (CGRect(x: 100, y: 690, width: 3, height: 30), [0, 0, 0])])
        let nativeField = try NativeTextFieldGuard(png: before, context: context, field: field)
        XCTAssertFalse(try nativeField.matches(png: edited, context: context))
    }

    func testAreaCellsAverageAllPixelsAndKeepUnevenEdgeCells() throws {
        let rect = ScreenRect(CGRect(x: 0, y: 0, width: 5, height: 1))
        let png = try screenPNG(width: 5, height: 1, patches: [(CGRect(x: 0, y: 0, width: 1, height: 1), [0, 0, 0])])
        let image = try ScreenImage(png: png)
        XCTAssertEqual(Array(try image.areaRGB(rect: rect, screen: rect, columns: 2, rows: 1)), [128, 128, 128, 255, 255, 255])
        XCTAssertThrowsError(try image.areaRGB(rect: rect, screen: rect, columns: 6, rows: 1))
        XCTAssertThrowsError(try image.areaRGB(rect: rect, screen: rect, columns: 0, rows: 1))
    }

    func testImmediatelyAdjacentProtectedControlStillRejectsChanges() throws {
        let context = screenTestContext()
        let ignored = ScreenRect(CGRect(x: 18, y: 89, width: 177, height: 60))
        let adjacent = ScreenRect(CGRect(x: 195, y: 89, width: 30, height: 60))
        let value = try ScreenGuard(png: screenPNG(), context: context, rects: [adjacent], policy: .init(), ignoring: ignored)
        let frame = try screenPNG(patches: [(ignored.cgRect, [0, 0, 0]), (CGRect(x: 196, y: 110, width: 2, height: 10), [0, 0, 0])])
        let check = try value.check(png: frame, context: context)
        XCTAssertEqual(check.ignoredRect, ignored)
        XCTAssertGreaterThan(check.regionChanges[0], 0)
        XCTAssertFalse(check.accepted)
    }

    func testVideoCannotHideTargetOrOtherPageChanges() throws {
        let baseline = try makeGuard()
        for patch in [CGRect(x: 313, y: 680, width: 4, height: 10), // touch target
                      CGRect(x: 0, y: 0, width: 390, height: 100), // navigation/page change
                      CGRect(x: 245, y: 150, width: 80, height: 200), // video moved outside its box
                      CGRect(x: 0, y: 500, width: 390, height: 200)] { // overlay elsewhere
            let check = try baseline.check(png: screenPNG(patches: [(video.cgRect, [0, 0, 0]), (patch, [0, 0, 0])]),
                                           context: screenTestContext())
            XCTAssertFalse(check.accepted)
        }
        XCTAssertThrowsError(try baseline.check(png: screenPNG(), context: screenTestContext(orientation: 3)))
    }

    func testSwipeCorridorAndExplicitContextRemainProtected() throws {
        let end = CGPoint(x: 315, y: 280)
        let baseline = try makeGuard(end: end)
        XCTAssertTrue(try baseline.check(png: screenPNG(patches: [(video.cgRect, [0, 0, 0])]), context: screenTestContext()).accepted)
        XCTAssertFalse(try baseline.check(png: screenPNG(patches: [(CGRect(x: 310, y: 450, width: 8, height: 10), [0, 0, 0])]), context: screenTestContext()).accepted)
        XCTAssertThrowsError(try makeGuard(end: CGPoint(x: 180, y: 280)))
        XCTAssertThrowsError(try makeGuard(extra: [video]))
    }

    func testInvalidExclusionsAndTamperedWireFailClosed() throws {
        let context = screenTestContext(), regions = CoordinateGesture.actionRegions(start: target, end: nil, screen: context.screen.cgRect)
        for rect in [CGRect(x: -1, y: 150, width: 100, height: 100), CGRect(x: 0, y: 0, width: 390, height: 300),
                     CGRect(x: 300, y: 650, width: 40, height: 40), CGRect(x: 20, y: 10, width: 0, height: 10)] {
            XCTAssertThrowsError(try ScreenGuard(png: screenPNG(), context: context, rects: regions, policy: .init(), ignoring: ScreenRect(rect)))
        }
        let encoded = try jsonObject(JSONEncoder().encode(makeGuard()))
        for (key, value): (String, Any) in [("algorithm", ScreenGuard.algorithm), ("algorithm", "srgb-grid-excluded-rect-v1"), ("unmaskedRGB", []),
            ("ignoredRect", ["x": 0, "y": 0, "width": 390, "height": 600])] {
            var raw = encoded; raw[key] = value
            let decoded = try JSONDecoder().decode(ScreenGuard.self, from: jsonData(raw))
            XCTAssertThrowsError(try decoded.validate())
        }
    }

    func testEdgeAlignedVideoAndScaleUseScreenshotCoordinates() throws {
        let rect = ScreenRect(CGRect(x: 0, y: 0, width: 190, height: 200)), context = screenTestContext()
        let regions = CoordinateGesture.actionRegions(start: target, end: nil, screen: context.screen.cgRect)
        let baseline = try ScreenGuard(png: screenPNG(width: 780, height: 1688), context: context, rects: regions,
                                       policy: .init(), ignoring: rect)
        let frame = try screenPNG(width: 780, height: 1688, patches: [(CGRect(x: 0, y: 0, width: 380, height: 400), [0, 0, 0])])
        XCTAssertTrue(try baseline.check(png: frame, context: context).accepted)
    }

    func testExcludedSwipeFitsRunnerBudgetAndCannotUseOldAlgorithm() throws {
        let baseline = try makeGuard(end: CGPoint(x: 315, y: 280))
        let gesture = CoordinateGesture(start: target, end: CGPoint(x: 315, y: 280), screenGuard: baseline, motion: .init())
        XCTAssertNoThrow(try gesture.validate(kind: "swipe"))
        let action = try DeviceAction(operation: "swipe", request: ["reference": "o1", "fromX": target.x, "fromY": target.y,
            "toX": 315, "toY": 280, "ignoreRect": "60,150,180,200"])
        let fields = try XCTestBackend.actionFields(action, target: ObservedTarget(context: [:], path: [], gesture: gesture))
        XCTAssertLessThan(try jsonData(fields).count, 60_000)
        // Old Runner's validator accepts only srgb-grid-v1, so it must reject
        // this distinct algorithm before input, even if it ignores new fields.
        XCTAssertNotEqual(baseline.algorithm, ScreenGuard.algorithm)
    }

    func testNativeTextExclusionProtectsEntireFieldAndCurrentReference() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ObservationCache(directory: directory), context = screenTestContext()
        let field = CGRect(x: 18, y: 139, width: 354, height: 160)
        let video = CGRect(x: 20, y: 400, width: 180, height: 80)
        let capture = CapturedObservation(nodes: [], metadata: ["backend": "apple-native",
            "screenContext": try jsonObject(JSONEncoder().encode(context))], screenshot: try screenPNG())
        _ = try cache.store(capture)
        for kind in ["type", "press"] {
            let request: [String: Any] = ["reference": "o1", "text": "中文", "mode": "insert", "key": "backspace",
                "fieldRect": "18,139,354,160", "ignoreRect": "20,400,180,80"]
            let action = try DeviceAction(operation: kind, request: request, allowScreenText: true)
            let guardValue = try XCTUnwrap(cache.resolveTarget(for: action).textGuard)
            XCTAssertEqual(guardValue.regions.map(\.rect), [ScreenRect(field)])
            XCTAssertTrue(
                try guardValue.check(png: screenPNG(patches: [(video, [0, 0, 0])]), context: context).accepted
            )
            XCTAssertFalse(try guardValue.check(png: screenPNG(patches: [(video, [0, 0, 0]),
                (CGRect(x: 50, y: 155, width: 10, height: 15), [0, 0, 0])]), context: context).accepted)
            for value in ["20,150,100,20", "0,0,390,400", "-1,400,180,80"] {
                var invalid = request; invalid["ignoreRect"] = value
                XCTAssertThrowsError(try cache.resolveTarget(for: DeviceAction(operation: kind, request: invalid, allowScreenText: true)))
            }
            var noField = request; noField.removeValue(forKey: "fieldRect")
            XCTAssertThrowsError(try DeviceAction(operation: kind, request: noField, allowScreenText: true))
            XCTAssertThrowsError(try DeviceAction(operation: kind, request: request, allowScreenText: false))
        }
        let old = try DeviceAction(operation: "type", request: ["reference": "o1", "text": "中文", "mode": "insert",
            "fieldRect": "18,139,354,160", "ignoreRect": "20,400,180,80"], allowScreenText: true)
        _ = try cache.store(capture)
        XCTAssertThrowsError(try cache.resolveTarget(for: old))
    }

    func testActionParsingAndObservationBinding() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("excluded-guard-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ObservationCache(directory: directory)
        _ = try cache.store(observationFixture())
        let request: [String: Any] = ["reference": "o1", "x": 98, "y": 360, "ignoreRect": "10,10,30,30"]
        let action = try DeviceAction(operation: "tap", request: request)
        let resolved = try cache.resolveTarget(for: action)
        XCTAssertEqual(resolved.gesture?.screenGuard.ignoredRect, action.ignoredScreenRect)
        for value: Any in [true, "1,2,3", "nan,0,10,10", "0,0,-1,20", "0,0,inf,10"] {
            var invalid = request; invalid["ignoreRect"] = value
            XCTAssertThrowsError(try DeviceAction(operation: "tap", request: invalid))
        }
        XCTAssertThrowsError(try DeviceAction(operation: "tap", request: ["reference": "o1:e1", "ignoreRect": "10,10,30,30"]))
        var overlaps = request; overlaps["ignoreRect"] = "90,350,20,20"
        XCTAssertThrowsError(try cache.resolveTarget(for: DeviceAction(operation: "tap", request: overlaps)))
        _ = try cache.store(observationFixture())
        XCTAssertThrowsError(try cache.resolveTarget(for: action)) // Old observation cannot carry a mask forward.
    }
}
