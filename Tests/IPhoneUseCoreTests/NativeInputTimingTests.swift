import XCTest
import CoreGraphics
@testable import IPhoneUseCore

final class NativeInputTimingTests: XCTestCase {
    func testObservationBudgetDoesNotInheritInputFreshnessButKeepsTotalDeadline() throws {
        let input = NativeCaptureBudget(requestDeadline: 115)
        let observation = NativeCaptureBudget(requestDeadline: 115, purpose: .observation)
        XCTAssertEqual(try input.beginValidation(now: 101), 109)
        XCTAssertEqual(try observation.beginValidation(now: 101), 115)
        XCTAssertThrowsError(try input.check(now: 110)) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "input_preflight_timeout")
        }
        XCTAssertNoThrow(try observation.check(now: 110))
        XCTAssertEqual(try observation.beginValidation(now: 114), 115)
        XCTAssertThrowsError(try observation.check(now: 115)) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "capture_timeout")
        }
    }
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
                    deadline: try timing.captureBudget(now: clock).beginValidation(now: clock), maximumCaptures: 1, now: { clock }) {
                        captures += 1; clock += 1
                        return CapturedObservation(nodes: [], metadata: ["displayID": UInt64(1),
                            "displayRotation": "rot0", "nativeRotation": "rot0", "captureSource": "native_media",
                            "screenContext": try jsonObject(JSONEncoder().encode(context))],
                            screenshot: changed ? try screenPNG(patches: [(CGRect(x: 190, y: 590, width: 20, height: 20), [0, 0, 0])]) : original)
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

    func testCoordinatePreparationDoesNotConsumeFinalPNGWindowOrRestartRequest() throws {
        var timing = try NativeInputTiming(captured: 100, now: 145, policy: .coordinateGesture)
        let budget = try timing.captureBudget(now: 145)
        XCTAssertEqual(budget.deadline, 175)
        XCTAssertThrowsError(try timing.checkBeforeDispatch(now: 155))
        XCTAssertEqual(try budget.beginValidation(now: 157), 165)
        XCTAssertEqual(try budget.beginValidation(now: 160), 165)
        XCTAssertNoThrow(try timing.checkBeforeDispatch(now: 164))
        XCTAssertThrowsError(try timing.checkBeforeDispatch(now: 165))
        XCTAssertThrowsError(try timing.captureBudget(now: 166))
    }

    func testSlowFreshCaptureStillRejectsOldBaselineWithoutInput() throws {
        let context = screenTestContext(), png = try screenPNG()
        let baseline = try ScreenGuard(png: png, context: context, rects: [context.screen], policy: .init())
        var timing = try NativeInputTiming(captured: 0, now: 90, policy: .coordinateGesture)
        var clock = 90.0
        XCTAssertThrowsError(try NativeInputPreflight.check(guard: baseline, displayID: 1,
            deadline: try timing.captureBudget(now: clock).beginValidation(now: clock), maximumCaptures: 1, now: { clock }) {
                clock = 98
                return CapturedObservation(nodes: [], metadata: ["displayID": UInt64(1),
                    "screenContext": try jsonObject(JSONEncoder().encode(context))], screenshot: png)
            }) {
                XCTAssertEqual(($0 as? ActionFailure)?.result?["preInputDeadlineExceeded"] as? Bool, true)
                XCTAssertEqual(($0 as? ActionFailure)?.code, "input_preflight_timeout")
                XCTAssertEqual(($0 as? ActionFailure)?.possiblyExecuted, false)
            }
    }

    func testKeyboardUsesRequestBudgetAndFreshFinalPhaseAfterSlowClipboard() throws {
        // Reproduce the trial: the agent spends two minutes reading a screenshot.
        var timing = try NativeInputTiming(captured: 100, now: 220, policy: .keyboard)
        XCTAssertEqual(timing.observationAgeSeconds, 120)
        XCTAssertEqual(try timing.captureBudget(now: 220).beginValidation(now: 220), 228)
        XCTAssertNoThrow(try timing.checkBeforeDispatch(now: 222))
        // Clipboard preparation may exceed the first phase's eight seconds.
        // It must be followed by another capture of the SAME original field.
        XCTAssertThrowsError(try timing.checkBeforeDispatch(now: 240))
        XCTAssertEqual(try timing.captureBudget(now: 240).beginValidation(now: 240), 248)
        XCTAssertNoThrow(try timing.checkBeforeDispatch(now: 242))
        // Slow ownership reads after that capture cannot extend its freshness.
        XCTAssertThrowsError(try timing.checkBeforeDispatch(now: 248))
        XCTAssertThrowsError(try timing.captureBudget(now: 249))
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
                let deadline = try timing.captureBudget(now: clock).beginValidation(now: clock)
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
            let final = changed ? try screenPNG(patches: [(CGRect(x: 50, y: 180, width: 30, height: 20), [0, 0, 0])]) : original
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
        XCTAssertEqual(try timing.captureBudget(now: 129).beginValidation(now: 129), 130)
        XCTAssertThrowsError(try timing.checkBeforeDispatch(now: 130))
    }

    func testRecoveredCaptureHasIndependentWindowButStillChecksOriginalPixelsAndTotalDeadline() throws {
        let context = screenTestContext(), png = try screenPNG()
        let guardValue = try ScreenGuard(png: png, context: context, rects: [context.screen], policy: .init())
        for scenario in ["recovered", "changed", "slow_png", "total_expired", "orientation_changed", "no_png_start"] {
            var timing = try NativeInputTiming(captured: 0, now: 100, policy: .coordinateGesture)
            let budget = try timing.captureBudget(now: 100)
            var clock = 100.0, refreshes = 0, captures = 0, dispatched = 0
            do {
                _ = try NativeInputPreflight.check(guard: guardValue, displayID: 1,
                    deadline: budget.requestDeadline, maximumCaptures: 1, budget: budget, now: { clock }) {
                        try NativeCaptureChecks.withOrientationRecovery(capture: { refreshed in
                            captures += 1
                            if !refreshed {
                                clock += 2
                                throw IPhoneUseError("native_snapshot_freshness_unavailable", "quiet stream")
                            }
                            clock += 1 // Display and lock checked after owned recovery.
                            if scenario != "no_png_start" { try budget.beginValidation(now: clock) }
                            clock += scenario == "slow_png" ? 8 : 2
                            return CapturedObservation(nodes: [], metadata: ["displayID": UInt64(1),
                                "screenContext": try jsonObject(JSONEncoder().encode(context))],
                                screenshot: scenario == "changed" ? try screenPNG(patches: [(CGRect(x: 0, y: 0, width: 100, height: 100), [0, 0, 0])]) : png)
                        }, resynchronize: {
                            refreshes += 1; clock += scenario == "total_expired" ? 28 : 9
                            return scenario == "orientation_changed"
                        }, now: { clock })
                    }
                try timing.checkBeforeDispatch(now: clock)
                dispatched += 1
            } catch {
                XCTAssertNotEqual(scenario, "recovered", "\(error)")
            }
            XCTAssertEqual(dispatched, scenario == "recovered" ? 1 : 0)
            XCTAssertEqual(refreshes, 1)
            XCTAssertEqual(captures, 2)
        }
    }

    func testPreparationAndOwnershipCannotEscapeRequestOrFinalDeadline() throws {
        var timing = try NativeInputTiming(captured: 0, now: 100, policy: .keyboard)
        let first = try timing.captureBudget(now: 100)
        XCTAssertThrowsError(try first.check(now: 130))
        XCTAssertEqual(try first.beginValidation(now: 125), 130)
        XCTAssertThrowsError(try first.beginValidation(now: 131))
        XCTAssertThrowsError(try timing.checkBeforeDispatch(now: 130))
        XCTAssertThrowsError(try timing.captureBudget(now: 130))
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
