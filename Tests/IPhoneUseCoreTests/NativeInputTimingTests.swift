import XCTest
import CoreGraphics
@testable import IPhoneUseCore

final class NativeInputTimingTests: XCTestCase {
    func testElapsedTimeDoesNotReviveSupersededOrConsumedReferences() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ObservationCache(directory: directory)
        let context = screenTestContext()
        let capture = CapturedObservation(nodes: [], metadata: ["backend": "apple-native",
            "screenContext": try jsonObject(JSONEncoder().encode(context)), "captureStartedUptime": 100.0],
            screenshot: try screenPNG())
        _ = try cache.store(capture)
        let action = try DeviceAction(operation: "tap", request: ["reference": "o1", "x": 200, "y": 600])
        XCTAssertNoThrow(try cache.resolveTarget(for: action))
        _ = try NativeInputTiming(captured: 100, now: 145, coordinateGesture: true)
        _ = try cache.store(capture)
        XCTAssertThrowsError(try cache.resolveTarget(for: action))
        let current = try DeviceAction(operation: "tap", request: ["reference": "o2", "x": 200, "y": 600])
        XCTAssertNoThrow(try cache.resolveTarget(for: current))
        let previous = cache.beginAction()
        cache.finishAction(previous: previous, dispatched: true)
        XCTAssertThrowsError(try cache.resolveTarget(for: current))
    }

    func testOldCurrentCoordinateBaselineStillRequiresFreshMatchingPixels() throws {
        let context = screenTestContext()
        let original = try screenPNG()
        let guardValue = try ScreenGuard(png: original, context: context,
            rects: [ScreenRect(CGRect(x: 168, y: 568, width: 64, height: 64))], policy: .init())
        for changed in [false, true] {
            let timing = try NativeInputTiming(captured: 100, now: 145, coordinateGesture: true)
            var clock = 145.0, captures = 0
            let compare = {
                try NativeInputPreflight.check(guard: guardValue, displayID: 1,
                    displayRotation: "rot0", captureSource: "native_media",
                    deadline: timing.preflightDeadline(now: clock), maximumCaptures: 1, now: { clock }) {
                        captures += 1; clock += 1
                        return CapturedObservation(nodes: [], metadata: ["displayID": UInt64(1),
                            "displayRotation": "rot0", "nativeRotation": "rot0", "captureSource": "native_media",
                            "screenContext": try jsonObject(JSONEncoder().encode(context))],
                            screenshot: changed ? try screenPNG(patches: [(CGRect(x: 190, y: 590, width: 20, height: 20), [0,0,0])]) : original)
                    }
            }
            if changed {
                XCTAssertThrowsError(try compare()) {
                    XCTAssertEqual(($0 as? ActionFailure)?.possiblyExecuted, false)
                    XCTAssertNotNil(($0 as? ActionFailure)?.rejectedCapture)
                }
            } else {
                XCTAssertTrue(try compare().0.accepted)
                XCTAssertNoThrow(try timing.checkBeforeDispatch(now: clock))
            }
            XCTAssertEqual(captures, 1)
        }
    }

    func testCoordinateBudgetDoesNotShrinkAtThirtySecondBoundaryOrRestart() throws {
        let timing = try NativeInputTiming(captured: 100, now: 129.9, coordinateGesture: true)
        XCTAssertEqual(timing.preflightDeadline(now: 129.9), 137.9, accuracy: 0.0001)
        XCTAssertEqual(timing.preflightDeadline(now: 136), 137.9, accuracy: 0.0001)
        XCTAssertNoThrow(try timing.checkBeforeDispatch(now: 135))
        XCTAssertThrowsError(try timing.checkBeforeDispatch(now: 137.9))
    }

    func testSlowFreshCaptureStillRejectsOldBaselineWithoutInput() throws {
        let context = screenTestContext(), png = try screenPNG()
        let baseline = try ScreenGuard(png: png, context: context, rects: [context.screen], policy: .init())
        let timing = try NativeInputTiming(captured: 0, now: 90, coordinateGesture: true)
        var clock = 90.0
        XCTAssertThrowsError(try NativeInputPreflight.check(guard: baseline, displayID: 1,
            deadline: timing.preflightDeadline(now: clock), maximumCaptures: 1, now: { clock }) {
                clock = 98
                return CapturedObservation(nodes: [], metadata: ["displayID": UInt64(1),
                    "screenContext": try jsonObject(JSONEncoder().encode(context))], screenshot: png)
            }) {
                XCTAssertEqual(($0 as? ActionFailure)?.result?["preInputDeadlineExceeded"] as? Bool, true)
                XCTAssertEqual(($0 as? ActionFailure)?.possiblyExecuted, false)
            }
    }

    func testFocusAndSystemActionsRetainSourceExpiry() throws {
        XCTAssertThrowsError(try NativeInputTiming(captured: 100, now: 131, coordinateGesture: false))
        let timing = try NativeInputTiming(captured: 100, now: 129, coordinateGesture: false)
        XCTAssertEqual(timing.preflightDeadline(now: 129), 130)
        XCTAssertThrowsError(try timing.checkBeforeDispatch(now: 130))
    }

    func testInvalidOrFutureCaptureTimeRejectedForBothPolicies() {
        for coordinate in [false, true] {
            for captured in [-1, Double.nan, .infinity, 101] {
                XCTAssertThrowsError(try NativeInputTiming(captured: captured, now: 100, coordinateGesture: coordinate))
            }
            XCTAssertThrowsError(try NativeInputTiming(captured: 0, now: .nan, coordinateGesture: coordinate))
        }
    }
}
