import XCTest
import AppleNativeBridge
@testable import IPhoneUseCore

extension NativeKeyboardTests {
    func testExplicitNativeFieldRegionKeepsStrictLocalAndGlobalProtection() throws {
        let request: [String: Any] = [
            "reference": "o1", "mode": "insert", "text": "zhongwen", "fieldRect": "18,146,354,36"
        ]
        XCTAssertThrowsError(try DeviceAction(operation: "type", request: request))
        for rect in ["", "1,2,3", "1,2,3,4,5", "nan,2,3,4", "0,0,-1,2", "0,0,2,0"] {
            var invalid = request; invalid["fieldRect"] = rect
            XCTAssertThrowsError(try DeviceAction(operation: "type", request: invalid, allowScreenText: true))
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ObservationCache(directory: directory), context = screenTestContext()
        _ = try cache.store(
            CapturedObservation(
                nodes: [],
                metadata: [
                    "backend": "apple-native",
                    "screenContext": try jsonObject(JSONEncoder().encode(context))
                ], screenshot: try screenPNG()))
        let action = try DeviceAction(operation: "type", request: request, allowScreenText: true)
        let guardValue = try XCTUnwrap(cache.resolveTarget(for: action).textGuard)
        XCTAssertEqual(guardValue.policy.maxRegionChange, 0)
        XCTAssertEqual(guardValue.policy.maxScreenChange, 0.01)
        let statusChange = try screenPNG(patches: [(CGRect(x: 20, y: 10, width: 6, height: 8), [0, 0, 0])])
        XCTAssertTrue(try guardValue.check(png: statusChange, context: context).accepted)
        let fieldChange = try screenPNG(patches: [(CGRect(x: 50, y: 160, width: 4, height: 10), [0, 0, 0])])
        XCTAssertFalse(try guardValue.check(png: fieldChange, context: context).accepted)
        let largeChange = try screenPNG(patches: [(CGRect(x: 0, y: 600, width: 390, height: 200), [0, 0, 0])])
        XCTAssertFalse(try guardValue.check(png: largeChange, context: context).accepted)
        var outside = request; outside["fieldRect"] = "380,146,354,36"
        XCTAssertThrowsError(
            try cache.resolveTarget(
                for: DeviceAction(operation: "type", request: outside, allowScreenText: true)))
    }

    func testNativeScreenTypingRequiresCurrentObservationAndProtectsWholeScreen() throws {
        let request: [String: Any] = ["reference": "o1", "mode": "insert", "text": "hello"]
        XCTAssertThrowsError(try DeviceAction(operation: "type", request: request))
        let action = try DeviceAction(operation: "type", request: request, allowScreenText: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ObservationCache(directory: directory), context = screenTestContext()
        let capture = CapturedObservation(
            nodes: [],
            metadata: [
                "backend": "apple-native",
                "screenContext": try jsonObject(JSONEncoder().encode(context))
            ], screenshot: try screenPNG())
        _ = try cache.store(capture)
        let target = try cache.resolveTarget(for: action)
        XCTAssertEqual(target.textGuard?.regions.map(\.rect), [context.screen])
        _ = try cache.store(capture)
        XCTAssertThrowsError(try cache.resolveTarget(for: action))
    }
}
