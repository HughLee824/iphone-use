import XCTest
@testable import IPhoneUseCore

final class NativePostActionStabilityTests: XCTestCase {
    func testSlowFirstObservationCanUseRemainingTotalBudget() throws {
        let a = try frame()
        var time = 0.0, count = 0
        let result = try NativePostActionStability.capture(now: { time }, pause: { time += $0 }, checkCancellation: {}) { deadline in
            let budget = NativeCaptureBudget(requestDeadline: deadline, purpose: .observation)
            try budget.beginValidation(now: time)
            count += 1; time += count == 1 ? 9 : 1
            try budget.check(now: time)
            return a
        }
        XCTAssertEqual(count, 3)
        XCTAssertEqual(facts(result)["stable"] as? Bool, true)
    }

    func testMatchingPairThenTimeoutReportsInsufficientSamplesWithDiagnostics() throws {
        let a = try frame()
        var time = 0.0, count = 0
        let result = try NativePostActionStability.capture(now: { time }, pause: { time += $0 }, checkCancellation: {}) { deadline in
            count += 1
            if count == 3 {
                time = deadline
                throw IPhoneUseError("capture_timeout", "deadline", diagnostics: ["capture": ["failedStage": "checksAfter"]])
            }
            time += 6; return a
        }
        let status = facts(result)
        XCTAssertEqual(status["stable"] as? Bool, false)
        XCTAssertEqual(status["reason"] as? String, "insufficient_stable_samples")
        XCTAssertEqual(status["samples"] as? Int, 2)
        XCTAssertEqual((status["comparison"] as? [String: Any])?["changedPixels"] as? Int, 0)
        let diagnostic = status["lastCaptureDiagnostics"] as? [String: Any]
        XCTAssertEqual((diagnostic?["capture"] as? [String: Any])?["failedStage"] as? String, "checksAfter")
        XCTAssertEqual((status["captureSamples"] as? [[String: Any]])?.count, 3)
    }

    func testNoFrameTimeoutPreservesCaptureFailureInsteadOfGenericMessageOnly() throws {
        var time = 0.0
        XCTAssertThrowsError(try NativePostActionStability.capture(now: { time }, pause: { time += $0 }, checkCancellation: {}) { deadline in
            time = deadline
            throw IPhoneUseError("capture_timeout", "deadline", diagnostics: ["capture": ["failedStage": "screenshot"]])
        }) { error in
            let failure = error as? IPhoneUseError
            XCTAssertEqual(failure?.code, "post_action_capture_timeout")
            XCTAssertEqual(failure?.diagnostics["reason"] as? String, "no_valid_sample")
            let last = failure?.diagnostics["lastCaptureDiagnostics"] as? [String: Any]
            XCTAssertEqual((last?["capture"] as? [String: Any])?["failedStage"] as? String, "screenshot")
        }
    }
    private func frame(_ color: UInt8 = 100, rotation: String = "rot0", patch: Bool = false) throws -> CapturedObservation {
        let png = try screenPNG(width: 40, height: 80, patches:
            [(CGRect(x: 0, y: 0, width: 40, height: 80), [color, color, color])] +
            (patch ? [(CGRect(x: 5, y: 5, width: 5, height: 5), [0, 0, 0])] : []))
        let rect = ScreenRect(CGRect(x: 0, y: 0, width: 40, height: 80))
        let context = ScreenContext(screen: rect, scope: rect, orientation: rotation == "rot0" ? 1 : 3, keyboardCount: 0)
        return CapturedObservation(nodes: [], metadata: ["captureSource": "coredevice_screenshot",
            "displayRotation": rotation, "displayID": 1, "nativeRotation": "rot0",
            "screenContext": try jsonObject(JSONEncoder().encode(context))], screenshot: png)
    }

    private func facts(_ frame: CapturedObservation) -> [String: Any] { frame.metadata["postActionStability"] as! [String: Any] }

    private func phoneFrame(scale: Int = 1, patches: [(CGRect, [UInt8])] = []) throws -> CapturedObservation {
        let png = try screenPNG(width: 390 * scale, height: 844 * scale, patches: patches.map {
            (CGRect(x: $0.0.minX * Double(scale), y: $0.0.minY * Double(scale),
                    width: $0.0.width * Double(scale), height: $0.0.height * Double(scale)), $0.1)
        })
        return CapturedObservation(nodes: [], metadata: ["captureSource": "coredevice_screenshot",
            "displayRotation": "rot0", "displayID": 1, "nativeRotation": "rot0",
            "screenContext": try jsonObject(JSONEncoder().encode(screenTestContext()))], screenshot: png)
    }

    private func alternate(_ a: CapturedObservation, _ b: CapturedObservation) throws -> CapturedObservation {
        var time = 0.0, count = 0
        return try NativePostActionStability.capture(now: { time }, pause: { time += $0 }, checkCancellation: {}) { _ in
            time += 0.6; defer { count += 1 }
            return count.isMultiple(of: 2) ? a : b
        }
    }

    func testBlinkReadinessIsColorIndependentAndDoesNotChangeStrictComparison() throws {
        for scale in [1, 3] {
            let empty = try phoneFrame(scale: scale)
            for color: [UInt8] in [[0, 0, 0], [255, 0, 0], [0, 120, 255]] {
                let caret = try phoneFrame(scale: scale, patches: [(CGRect(x: 22, y: 146, width: 2, height: 19), color)])
                let result = try alternate(empty, caret)
                XCTAssertEqual(facts(result)["stable"] as? Bool, true)
                XCTAssertEqual(facts(result)["samples"] as? Int, 3)
                XCTAssertEqual((facts(result)["localizedChange"] as? [String: Any])?["comparisons"] as? Int, 1)
                XCTAssertEqual(result.screenshot, empty.screenshot)
                XCTAssertFalse(FrameComparison(reference: try FrameFingerprint(png: empty.screenshot),
                                                current: try FrameFingerprint(png: caret.screenshot)).equivalent)
            }
        }
    }

    func testAreaDimensionAndSpatialBoundsRejectLargerOrDistributedChanges() throws {
        let empty = try phoneFrame()
        let cases: [[CGRect]] = [
            [CGRect(x: 20, y: 100, width: 18, height: 19)], // area > 320
            [CGRect(x: 20, y: 100, width: 1, height: 81)], // long thin motion
            [CGRect(x: 20, y: 100, width: 2, height: 19), CGRect(x: 80, y: 100, width: 2, height: 19)],
            [CGRect(x: 20, y: 100, width: 100, height: 100)] // video/transition
        ]
        for patches in cases {
            let animated = try phoneFrame(patches: patches.map { ($0, [0, 0, 0]) })
            XCTAssertEqual(facts(try alternate(empty, animated))["stable"] as? Bool, false)
        }
        // A small-screen patch fits the point envelope but exceeds 0.1%.
        XCTAssertEqual(facts(try alternate(frame(), frame(patch: true)))["stable"] as? Bool, false)
    }

    func testTinyChangesCannotMoveTheirEnvelopeAcrossSuccessiveFrames() throws {
        let empty = try phoneFrame()
        let left = try phoneFrame(patches: [(CGRect(x: 20, y: 100, width: 2, height: 19), [0, 0, 0])])
        let right = try phoneFrame(patches: [(CGRect(x: 80, y: 100, width: 2, height: 19), [0, 0, 0])])
        var time = 0.0, count = 0
        let result = try NativePostActionStability.capture(now: { time }, pause: { time += $0 }, checkCancellation: {}) { _ in
            time += 0.6; defer { count += 1 }
            return [empty, left, right, right, right][min(count, 4)]
        }
        XCTAssertEqual(count, 5)
        XCTAssertEqual(facts(result)["stable"] as? Bool, true)
        XCTAssertEqual(result.screenshot, right.screenshot)
        XCTAssertEqual((facts(result)["localizedChange"] as? [String: Any])?["comparisons"] as? Int, 0)
    }

    func testTransitionReturnsLastStableFrameAndNeverFirstFrame() throws {
        let old = try frame(), animated = try frame(120), final = try frame(200)
        var time = 0.0, index = 0
        let result = try NativePostActionStability.capture(now: { time }, pause: { time += $0 }, checkCancellation: {}) { deadline in
            XCTAssertEqual(deadline, 15)
            time += 0.6; defer { index += 1 }
            return [old, animated, final, final, final][min(index, 4)]
        }
        XCTAssertEqual(index, 5)
        XCTAssertEqual(result.screenshot, final.screenshot)
        XCTAssertEqual(facts(result)["stable"] as? Bool, true)
        XCTAssertEqual(facts(result)["frameHash"] as? String, try FrameFingerprint(png: final.screenshot).hash)
    }

    func testMinimumDurationAndGeometryChangeResetConsecutiveFrames() throws {
        let a = try frame(), rotated = try frame(rotation: "rot270")
        var time = 0.0, index = 0
        let result = try NativePostActionStability.capture(now: { time }, pause: { time += $0 }, checkCancellation: {}) { _ in
            time += 0.4; defer { index += 1 }
            return index < 2 ? a : rotated
        }
        XCTAssertEqual(index, 5)
        XCTAssertEqual(facts(result)["consecutiveFrames"] as? Int, 3)
        XCTAssertEqual(facts(result)["stable"] as? Bool, true)
    }

    func testContinuousAnimationReturnsLatestWithExplicitTimeout() throws {
        var time = 0.0, count = 0
        let a = try frame(), b = try frame(200)
        let result = try NativePostActionStability.capture(now: { time }, pause: { time += $0 }, checkCancellation: {}) { _ in
            time += 1; count += 1
            return count.isMultiple(of: 2) ? b : a
        }
        XCTAssertEqual(count, 15)
        XCTAssertEqual(result.screenshot, a.screenshot)
        XCTAssertEqual(facts(result)["stable"] as? Bool, false)
        XCTAssertEqual(facts(result)["reason"] as? String, "frame_stability_timeout")
        XCTAssertEqual(facts(result)["automaticReplayAllowed"] as? Bool, false)
    }

    func testExplicitVideoMaskDoesNotHideOutsideChangeOrSurviveRotation() throws {
        let rect = ScreenRect(CGRect(x: 4, y: 4, width: 7, height: 7))
        let a = try frame(), b = try frame(patch: true), rotated = try frame(rotation: "rot270", patch: true)
        for rotate in [false, true] {
            var time = 0.0, count = 0
            let result = try NativePostActionStability.capture(ignoring: rect, now: { time }, pause: { time += $0 }, checkCancellation: {}) { _ in
                time += 0.6; defer { count += 1 }
                if rotate && count >= 2 { return rotated }
                return count.isMultiple(of: 2) ? a : b
            }
            XCTAssertEqual(count, rotate ? 5 : 3)
            XCTAssertEqual(facts(result)["stable"] as? Bool, true)
            XCTAssertEqual(facts(result)["exclusionInvalidated"] as? Bool, rotate)
        }
        var time = 0.0, count = 0
        let outside = try frame(180)
        let result = try NativePostActionStability.capture(ignoring: rect, now: { time }, pause: { time += $0 }, checkCancellation: {}) { _ in
            time += 1; count += 1
            return count.isMultiple(of: 2) ? a : outside
        }
        XCTAssertEqual(facts(result)["stable"] as? Bool, false)
    }

    func testCancellationAndLockFailureNeverReturnCachedSuccess() throws {
        let a = try frame()
        for code in ["native_cancelled", "device_locked", "native_orientation_unverified"] {
            var time = 0.0, count = 0
            XCTAssertThrowsError(try NativePostActionStability.capture(now: { time }, pause: { time += $0 }, checkCancellation: {}) { _ in
                count += 1; time += 1
                if count > 1 { throw IPhoneUseError(code, "test") }
                return a
            }) { XCTAssertEqual(($0 as? IPhoneUseError)?.code, code) }
            XCTAssertEqual(count, 2)
        }
    }

    func testDeadlineDuringCapturePreservesLatestButNotStableAndNoFrameThrows() throws {
        let a = try frame()
        for hasFrame in [false, true] {
            var time = 0.0, count = 0
            func capture() throws -> CapturedObservation {
                try NativePostActionStability.capture(now: { time }, pause: { time += $0 }, checkCancellation: {}) { _ in
                    count += 1; time += 1
                    if !hasFrame || count > 1 { throw IPhoneUseError("input_preflight_timeout", "test") }
                    return a
                }
            }
            if hasFrame {
                let result = try capture()
                XCTAssertEqual(result.screenshot, a.screenshot)
                XCTAssertEqual(facts(result)["stable"] as? Bool, false)
            } else {
                XCTAssertThrowsError(try capture()) { XCTAssertEqual(($0 as? IPhoneUseError)?.code, "post_action_capture_timeout") }
            }
        }
    }

    func testContextChangeDuringCaptureResetsEvidenceWithoutReplayingInput() throws {
        let a = try frame()
        var time = 0.0, count = 0
        let result = try NativePostActionStability.capture(now: { time }, pause: { time += $0 }, checkCancellation: {}) { _ in
            count += 1; time += 0.6
            if count == 3 { throw IPhoneUseError("capture_context_changed", "transition") }
            return a
        }
        XCTAssertEqual(count, 6)
        XCTAssertEqual(facts(result)["stable"] as? Bool, true)
    }

    func testSlowDriftComparedAgainstAnchorRatherThanAdjacentFrames() throws {
        var time = 0.0, count = 0
        let frames = try (0..<15).map { try frame(UInt8(100 + $0 * 2)) }
        let result = try NativePostActionStability.capture(now: { time }, pause: { time += $0 }, checkCancellation: {}) { _ in
            time += 1; defer { count += 1 }; return frames[count]
        }
        XCTAssertEqual(facts(result)["stable"] as? Bool, false)
    }
}
