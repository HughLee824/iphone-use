import XCTest
@testable import IPhoneUseCore

final class NativePreviewGestureTests: XCTestCase {
    func testFaceUpRunnerUsesPreviewOrientationRatherThanPhysicalOrientation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try observationFixture()
        var metadata = original.metadata
        var context = try XCTUnwrap(metadata["screenContext"] as? [String: Any])
        context["orientation"] = 5
        metadata["screenContext"] = context
        let cache = ObservationCache(directory: directory)
        _ = try cache.store(
            CapturedObservation(nodes: original.nodes, metadata: metadata, screenshot: original.screenshot))
        let action = try DeviceAction(operation: "tap", request: ["reference": "o1", "x": 100, "y": 200])
        let target = try cache.resolveTarget(for: action)
        XCTAssertNil(NativePreviewGesture(action: action, target: target))
        XCTAssertEqual(
            NativePreviewGesture(action: action, target: target, previewRotation: "rot0")?.rotation, "rot0")
        XCTAssertNil(NativePreviewGesture(action: action, target: target, previewRotation: "unknown"))
    }

    func testNormalizedGeometryAndBoundedCursorLifetime() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ObservationCache(directory: directory)
        _ = try cache.store(observationFixture())
        let action = try DeviceAction(
            operation: "swipe",
            request: ["reference": "o1", "fromX": 100, "fromY": 600, "toX": 100, "toY": 200])
        let target = try cache.resolveTarget(for: action)
        let gesture = try XCTUnwrap(NativePreviewGesture(action: action, target: target))
        XCTAssertEqual(gesture.paths[0][0][0], 100.0 / 390, accuracy: 0.0001)
        XCTAssertEqual(gesture.paths[0][1][1], 200.0 / 844, accuracy: 0.0001)
        XCTAssertEqual(gesture.rotation, "rot0")
        var buffer = NativePreviewGestures()
        for _ in 0..<100 { buffer.append(gesture, now: 10) }
        XCTAssertEqual((buffer.response(after: nil, now: 10)["events"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual((buffer.response(after: 0, now: 10)["events"] as? [[String: Any]])?.count, 16)
        XCTAssertEqual((buffer.response(after: 100, now: 10)["events"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual((buffer.response(after: 0, now: 12)["events"] as? [[String: Any]])?.count, 0)
        buffer.clear()
        XCTAssertEqual(buffer.sequence, 100)
        XCTAssertEqual((buffer.response(after: 0, now: 10)["events"] as? [[String: Any]])?.count, 0)
    }

    func testHeldSwipesRenderAsDragsWithoutChangingInputKind() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ObservationCache(directory: directory)
        _ = try cache.store(observationFixture())
        for (press, hold, expected) in [(0.0, 0.0, "swipe"), (0.4, 0.0, "drag"), (0.0, 0.3, "drag")] {
            let action = try DeviceAction(
                operation: "swipe",
                request: [
                    "reference": "o1", "fromX": 100, "fromY": 600,
                    "toX": 100, "toY": 200, "pressDuration": press, "holdDuration": hold
                ])
            let gesture = try XCTUnwrap(
                NativePreviewGesture(action: action, target: cache.resolveTarget(for: action)))
            XCTAssertEqual(gesture.kind, expected)
            XCTAssertEqual(action.kind, "swipe")
            XCTAssertEqual(gesture.paths[0][0][1], 600.0 / 844, accuracy: 0.0001)
        }
    }

    func testPinchCarriesTwoFingerPathsWithoutElementOrTextContent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ObservationCache(directory: directory)
        _ = try cache.store(observationFixture())
        let action = try DeviceAction(
            operation: "pinch",
            request: ["reference": "o1", "x": 195, "y": 300, "fromDistance": 80, "toDistance": 200])
        let gesture = try XCTUnwrap(
            NativePreviewGesture(action: action, target: cache.resolveTarget(for: action)))
        XCTAssertEqual(gesture.paths.count, 2)
        XCTAssertLessThan(gesture.paths[0][1][0], gesture.paths[0][0][0])
        XCTAssertGreaterThan(gesture.paths[1][1][0], gesture.paths[1][0][0])
        XCTAssertEqual(Set(gesture.facts.keys), Set(["kind", "rotation", "aspect", "paths"]))
    }
}
