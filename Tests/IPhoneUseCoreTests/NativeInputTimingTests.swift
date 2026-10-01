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
        _ = try NativeInputTiming(captured: 100, now: 145, policy: .coordinateGesture)
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
            var timing = try NativeInputTiming(captured: 100, now: 145, policy: .coordinateGesture)
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
        var timing = try NativeInputTiming(captured: 100, now: 129.9, policy: .coordinateGesture)
        XCTAssertEqual(timing.preflightDeadline(now: 129.9), 137.9, accuracy: 0.0001)
        XCTAssertEqual(timing.preflightDeadline(now: 136), 137.9, accuracy: 0.0001)
        XCTAssertNoThrow(try timing.checkBeforeDispatch(now: 135))
        XCTAssertThrowsError(try timing.checkBeforeDispatch(now: 137.9))
    }

    func testSlowFreshCaptureStillRejectsOldBaselineWithoutInput() throws {
        let context = screenTestContext(), png = try screenPNG()
        let baseline = try ScreenGuard(png: png, context: context, rects: [context.screen], policy: .init())
        var timing = try NativeInputTiming(captured: 0, now: 90, policy: .coordinateGesture)
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

    func testKeyboardUsesRequestBudgetAndFreshFinalPhaseAfterSlowClipboard() throws {
        // Reproduce the trial: the agent spends two minutes reading a screenshot.
        var timing = try NativeInputTiming(captured: 100, now: 220, policy: .keyboard)
        XCTAssertEqual(timing.observationAgeSeconds, 120)
        XCTAssertEqual(timing.preflightDeadline(now: 220), 228)
        XCTAssertNoThrow(try timing.checkBeforeDispatch(now: 222))
        // Clipboard preparation may exceed the first phase's eight seconds.
        // It must be followed by another capture of the SAME original field.
        XCTAssertThrowsError(try timing.checkBeforeDispatch(now: 240))
        XCTAssertEqual(timing.preflightDeadline(now: 240), 248)
        XCTAssertNoThrow(try timing.checkBeforeDispatch(now: 242))
        // Slow ownership reads after that capture cannot extend its freshness.
        XCTAssertThrowsError(try timing.checkBeforeDispatch(now: 248))
        XCTAssertEqual(timing.preflightDeadline(now: 249), 250)
        XCTAssertThrowsError(try timing.checkBeforeDispatch(now: 250))
    }

    func testOldKeyboardFieldMustStillMatchAfterClipboardPreparation() throws {
        let context = screenTestContext(), original = try screenPNG()
        let field = ScreenRect(CGRect(x: 18, y: 150, width: 354, height: 160))
        let baseline = try ScreenGuard(png: original, context: context, rects: [field], policy: .init())
        for changed in [false, true] {
            var timing = try NativeInputTiming(captured: 100, now: 220, policy: .keyboard)
            var clock = 220.0
            func check(_ png: Data) throws {
                let deadline = timing.preflightDeadline(now: clock)
                _ = try NativeInputPreflight.check(guard: baseline, displayID: 1,
                    displayRotation: "rot0", captureSource: "native_media", deadline: deadline,
                    maximumCaptures: 3, now: { clock }) {
                        clock += 0.5
                        return CapturedObservation(nodes: [], metadata: ["displayID": UInt64(1),
                            "displayRotation": "rot0", "nativeRotation": "rot0", "captureSource": "native_media",
                            "screenContext": try jsonObject(JSONEncoder().encode(context))], screenshot: png)
                    }
            }
            try check(original)
            clock += 12 // Backup, stage and verify the clipboard.
            let final = changed ? try screenPNG(patches: [(CGRect(x: 50, y: 180, width: 30, height: 20), [0,0,0])]) : original
            var inputs = 0
            do {
                try check(final)
                try timing.checkBeforeDispatch(now: clock)
                inputs += 1
            } catch {
                XCTAssertTrue(changed)
                XCTAssertEqual((error as? ActionFailure)?.possiblyExecuted, false)
            }
            XCTAssertEqual(inputs, changed ? 0 : 1)
        }
    }

    func testKeyboardCannotDispatchWithoutPreflight() throws {
        let timing = try NativeInputTiming(captured: 0, now: 120, policy: .keyboard)
        XCTAssertThrowsError(try timing.checkBeforeDispatch(now: 121))
    }

    func testSystemActionsRetainSourceExpiry() throws {
        XCTAssertThrowsError(try NativeInputTiming(captured: 100, now: 131, policy: .system))
        var timing = try NativeInputTiming(captured: 100, now: 129, policy: .system)
        XCTAssertEqual(timing.preflightDeadline(now: 129), 130)
        XCTAssertThrowsError(try timing.checkBeforeDispatch(now: 130))
    }

    func testInvalidOrFutureCaptureTimeRejectedForBothPolicies() {
        for policy in [NativeInputTiming.Policy.coordinateGesture, .keyboard, .system] {
            for captured in [-1, Double.nan, .infinity, 101] {
                XCTAssertThrowsError(try NativeInputTiming(captured: captured, now: 100, policy: policy))
            }
            XCTAssertThrowsError(try NativeInputTiming(captured: 0, now: .nan, policy: policy))
        }
    }
}
