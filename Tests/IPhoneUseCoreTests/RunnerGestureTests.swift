import XCTest
@testable import IPhoneUseCore

final class RunnerGestureTests: XCTestCase {
    func testScreenshotPointsMapToNativePortraitInEveryInterfaceOrientation() throws {
        let portrait = ScreenRect(CGRect(x: 0, y: 0, width: 390, height: 844))
        let landscape = ScreenRect(CGRect(x: 0, y: 0, width: 844, height: 390))
        let point = CGPoint(x: 300, y: 235)
        XCTAssertEqual(try RunnerCoordinateMapping.point(point, screen: portrait, interfaceOrientation: 1), point)
        XCTAssertEqual(try RunnerCoordinateMapping.point(point, screen: portrait, interfaceOrientation: 2), CGPoint(x: 90, y: 609))
        XCTAssertEqual(try RunnerCoordinateMapping.point(point, screen: landscape, interfaceOrientation: 3), CGPoint(x: 155, y: 300))
        XCTAssertEqual(try RunnerCoordinateMapping.point(point, screen: landscape, interfaceOrientation: 4), CGPoint(x: 235, y: 544))
        XCTAssertThrowsError(try RunnerCoordinateMapping.point(point, screen: landscape, interfaceOrientation: 5))
        XCTAssertThrowsError(try RunnerCoordinateMapping.point(CGPoint(x: -1, y: 0), screen: landscape, interfaceOrientation: 4))
    }

    func testGuardedGesturesSerializeWithoutLosingMotionOrDuration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ObservationCache(directory: directory)
        _ = try cache.store(observationFixture())
        for kind in ["double-tap", "long-press", "pinch"] {
            var request: [String: Any] = ["reference": "o1", "x": 195.0, "y": 300.0]
            if kind == "long-press" { request["duration"] = 1.25 }
            if kind == "pinch" { request["fromDistance"] = 80.0; request["toDistance"] = 200.0; request["duration"] = 0.7 }
            let action = try DeviceAction(operation: kind, request: request)
            let target = try cache.resolveTarget(for: action)
            let fields = try XCTestBackend.actionFields(action, target: target)
            let gesture = try JSONDecoder().decode(CoordinateGesture.self, from: jsonData(fields["gesture"] as! [String: Any]))
            try gesture.validate(kind: kind)
            XCTAssertEqual(gesture.start, CGPoint(x: 195, y: 300))
            XCTAssertNil((fields["target"] as? [String: Any])?["path"])
            if kind == "long-press" { XCTAssertEqual(fields["duration"] as? Double, 1.25) }
            if kind == "pinch" {
                XCTAssertEqual(gesture.pinch, PinchMotion(fromDistance: 80, toDistance: 200, duration: 0.7))
                XCTAssertEqual(gesture.screenGuard.regions.count, 2)
            }
            let changed = try screenPNG(patches: [(CGRect(x: kind == "pinch" ? 151 : 190, y: 295, width: 8, height: 8), [0,0,0])])
            XCTAssertFalse(try gesture.screenGuard.check(png: changed, context: gesture.screenGuard.context).accepted)
        }
    }

    func testSuccessWithMissingOrChangedGestureFactsIsUnknown() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pinch = PinchMotion(fromDistance: 80, toDistance: 200, duration: 0.7)
        // Motion facts are checked before stability. Even claimed input success
        // cannot erase uncertainty when the requested gesture is unconfirmed.
        for result: [String: Any] in [[:], ["pinch": PinchMotion(fromDistance: 80, toDistance: 220, duration: 0.7).result]] {
            let response: [String: Any] = ["ok": true, "execution": ["started": true, "inputCompleted": true, "completed": true], "result": result]
            XCTAssertThrowsError(try XCTestCapture.actionResponse(response, directory: directory, expectedPinch: pinch)) {
                XCTAssertEqual(($0 as? ActionFailure)?.code, "missing_pinch_motion_facts")
                XCTAssertEqual(($0 as? ActionFailure)?.possiblyExecuted, true)
            }
        }
        let response: [String: Any] = ["ok": true, "execution": ["started": true], "result": ["duration": 0.8]]
        XCTAssertThrowsError(try XCTestCapture.actionResponse(response, directory: directory, expectedPressDuration: 1.25)) {
            XCTAssertEqual(($0 as? ActionFailure)?.code, "missing_press_duration_facts")
            XCTAssertEqual(($0 as? ActionFailure)?.possiblyExecuted, true)
        }
    }
}
