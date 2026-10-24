@testable import IPhoneUseRunnerSupport
import XCTest
import CoreGraphics
@testable import IPhoneUseCore

extension NativeInputTimingTests {

    func testRecoveredCaptureHasIndependentWindowButStillChecksOriginalPixelsAndTotalDeadline() throws {
        let context = screenTestContext(), png = try screenPNG()
        let guardValue = try ScreenGuard(png: png, context: context, rects: [context.screen], policy: .init())
        for scenario in [
            "recovered", "changed", "slow_png", "total_expired", "orientation_changed", "no_png_start"
        ] {
            var timing = try NativeInputTiming(captured: 0, now: 100, policy: .coordinateGesture)
            let budget = try timing.captureBudget(now: 100)
            var clock = 100.0, refreshes = 0, captures = 0, dispatched = 0
            do {
                _ = try NativeInputPreflight.check(
                    guard: guardValue, displayID: 1,
                    deadline: budget.requestDeadline, maximumCaptures: 1, budget: budget, now: { clock },
                    capture: {
                        try NativeCaptureChecks.withOrientationRecovery(
                            capture: { refreshed in
                                captures += 1
                                if !refreshed {
                                    clock += 2
                                    throw IPhoneUseError(
                                        "native_snapshot_freshness_unavailable", "quiet stream")
                                }
                                clock += 1 // Display and lock checked after owned recovery.
                                if scenario != "no_png_start" { try budget.beginValidation(now: clock) }
                                clock += scenario == "slow_png" ? 8 : 2
                                return CapturedObservation(
                                    nodes: [],
                                    metadata: [
                                        "displayID": UInt64(1),
                                        "screenContext": try jsonObject(JSONEncoder().encode(context))
                                    ],
                                    screenshot: scenario == "changed"
                                        ? try screenPNG(patches: [
                                            (CGRect(x: 0, y: 0, width: 100, height: 100), [0, 0, 0])
                                        ])
                                        : png)
                            },
                            resynchronize: {
                                refreshes += 1; clock += scenario == "total_expired" ? 28 : 9
                                return scenario == "orientation_changed"
                            }, now: { clock })
                    })
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
