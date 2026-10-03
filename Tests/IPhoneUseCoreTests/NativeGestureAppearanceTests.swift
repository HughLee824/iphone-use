import XCTest
@testable import IPhoneUseCore

final class NativeGestureAppearanceTests: XCTestCase {
    private let context = screenTestContext()
    private let edge = CGRect(x: 40, y: 694, width: 16, height: 24)
    private var regions: [ScreenRect] {
        CoordinateGesture.actionRegions(start: CGPoint(x: 50, y: 720), end: CGPoint(x: 50, y: 300), screen: context.screen.cgRect)
    }
    private func source() throws -> Data { try screenPNG(patches: [(edge, [60,80,100])]) }
    private func noise() throws -> Data {
        try screenPNG(patches: [(edge, [60,80,100]), (CGRect(x: 40, y: 696, width: 1, height: 20), [72,88,108])])
    }
    private func run(_ a: Data, _ b: Data, actualSource: String = "native_media", expectedSource: String = "native_media",
                     deadline: Double = 8, sampledAt: Double = 1, current: ScreenContext? = nil) throws -> ScreenGuard.Check {
        let guardValue = try ScreenGuard(png: a, context: context, rects: regions, policy: .init())
        let appearance = try NativeGestureAppearanceGuard(png: a, guardValue: guardValue)
        var clock = 0.0
        return try NativeInputPreflight.check(guard: guardValue, displayID: 1, captureSource: expectedSource,
            deadline: deadline, maximumCaptures: 1, gestureAppearanceGuard: appearance, now: { clock }) {
                clock = sampledAt
                return CapturedObservation(nodes: [], metadata: ["displayID": UInt64(1), "captureSource": actualSource,
                    "screenContext": try jsonObject(JSONEncoder().encode(current ?? self.context))], screenshot: b)
            }.0
    }

    func testSamePositionEdgeNoisePassesWithoutChangingPolicy() throws {
        let a = try source(), b = try noise()
        let raw = try ScreenGuard(png: a, context: context, rects: regions, policy: .init()).check(png: b, context: context)
        XCTAssertFalse(raw.accepted)
        let check = try run(a, b)
        XCTAssertTrue(check.accepted)
        XCTAssertEqual(check.policy.maxRegionChange, 0)
        XCTAssertEqual(check.regionAppearanceMatches, raw.regionChanges.map { $0 > raw.policy.maxRegionChange })
        XCTAssertNil(check.fieldPixelsMatch)
        XCTAssertFalse(check.fieldTemporalMatch)
    }

    func testMatchingGridKeepsFastPath() throws {
        let a = try source(), check = try run(a, a)
        XCTAssertTrue(check.accepted)
        XCTAssertNil(check.regionAppearanceMatches)
    }

    func testObservationEnablesAppearanceOnlyForNativeMediaGestures() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gesture-appearance-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try observationFixture()
        for (backend, source, enabled) in [("apple-native", "native_media", true),
                                           ("apple-native", "coredevice_screenshot", false),
                                           ("xctest", "native_media", false)] {
            let cache = ObservationCache(directory: directory)
            var metadata = fixture.metadata
            metadata["backend"] = backend; metadata["captureSource"] = source
            _ = try cache.store(CapturedObservation(nodes: fixture.nodes, metadata: metadata, screenshot: fixture.screenshot))
            let action = try DeviceAction(operation: "swipe", request: ["reference": "o1", "fromX": 50, "fromY": 720,
                "toX": 50, "toY": 300])
            let target = try cache.resolveTarget(for: action)
            XCTAssertEqual(target.gestureAppearanceGuard != nil, enabled)
            XCTAssertEqual(target.gesture?.screenGuard.policy.maxRegionChange, 0)
            try cache.clear()
        }
    }

    func testMovementTextMenuAndVideoChangesRemainRejected() throws {
        let a = try source()
        let changes = [
            try screenPNG(patches: [(edge.offsetBy(dx: 1, dy: 0), [60,80,100])]),
            try screenPNG(patches: [(edge, [60,80,100]), (CGRect(x: 70, y: 715, width: 1, height: 14), [0,0,0])]),
            try screenPNG(patches: [(edge, [60,80,100]), (CGRect(x: 70, y: 715, width: 1, height: 14), [240,240,240])]),
            try screenPNG(patches: [(CGRect(x: 30, y: 696, width: 45, height: 30), [180,180,180])]),
            try screenPNG(patches: [(edge, [160,30,150])]),
            try screenPNG() // disappearance, no caret exception for gestures
        ]
        for b in changes {
            XCTAssertThrowsError(try run(a, b)) { XCTAssertEqual(($0 as? ActionFailure)?.possiblyExecuted, false) }
        }
    }

    func testPassingTouchRegionCannotHideChangedCorridorOrGlobalScreen() throws {
        let a = try source()
        for rect in [CGRect(x: 42, y: 450, width: 6, height: 20), CGRect(x: 150, y: 200, width: 200, height: 400)] {
            let b = try screenPNG(patches: [(edge, [60,80,100]), (CGRect(x: 40, y: 696, width: 1, height: 20), [72,88,108]), (rect, [0,0,0])])
            XCTAssertThrowsError(try run(a, b)) { XCTAssertEqual(($0 as? ActionFailure)?.possiblyExecuted, false) }
        }
    }

    func testBroadSmallRecolorAndStrongSinglePixelRemainRejected() throws {
        let a = try source()
        for b in [try screenPNG(patches: [(edge, [72,92,112])]),
                  try screenPNG(patches: [(edge, [60,80,100]), (CGRect(x: 70, y: 720, width: 2, height: 2), [180,180,180])])] {
            XCTAssertThrowsError(try run(a, b))
        }
    }

    func testSourceOrientationAndDeadlineAreNotBypassed() throws {
        let a = try source(), b = try noise()
        XCTAssertThrowsError(try run(a, b, actualSource: "coredevice_screenshot"))
        XCTAssertThrowsError(try run(a, b, actualSource: "coredevice_screenshot", expectedSource: "coredevice_screenshot"))
        XCTAssertThrowsError(try run(a, b, current: screenTestContext(orientation: 3)))
        XCTAssertThrowsError(try run(a, b, sampledAt: 9)) { error in
            let failure = error as? ActionFailure
            XCTAssertEqual(failure?.possiblyExecuted, false)
            XCTAssertEqual(failure?.result?["preInputDeadlineExceeded"] as? Bool, true)
        }
    }

    func testGuardBindsOriginalRegionsAndDimensions() throws {
        let a = try source(), g = try ScreenGuard(png: a, context: context, rects: regions, policy: .init())
        let matcher = try NativeGestureAppearanceGuard(png: a, guardValue: g)
        let other = try ScreenGuard(png: a, context: context, rects: [ScreenRect(CGRect(x: 100,y: 100,width: 64,height: 64))], policy: .init())
        XCTAssertThrowsError(try matcher.matches(png: a, context: context, guardValue: other, check: other.check(png: a, context: context)))
        XCTAssertThrowsError(try matcher.matches(png: screenPNG(width: 780,height: 1688), context: context,
            guardValue: g, check: g.check(png: a, context: context)))
    }

    func testSummaryReportsAppearancePassAndRemainingRegionFailure() throws {
        let check = try run(source(), noise())
        var result = AgentOutput.summarize(["result": ["screenGuard": check.result]])
        var comparison = (result["agentSummary"] as? [String: Any])?["comparison"] as? [String: Any]
        XCTAssertEqual(comparison?["mismatches"] as? [String], [])
        XCTAssertNotNil(comparison?["regionAppearanceMatches"])
        let mixed = ScreenGuard.Check(screenChange: 0, regionChanges: [0.1, 0.1], policy: .init(), regionAppearanceMatches: [true, false])
        XCTAssertFalse(mixed.accepted)
        result = AgentOutput.summarize(["result": ["screenGuard": mixed.result]])
        comparison = (result["agentSummary"] as? [String: Any])?["comparison"] as? [String: Any]
        XCTAssertEqual(comparison?["mismatches"] as? [String], ["protected_region_changed"])
    }
}
