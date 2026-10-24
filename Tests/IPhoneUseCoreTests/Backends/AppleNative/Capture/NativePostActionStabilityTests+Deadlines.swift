import XCTest
@testable import IPhoneUseCore

extension NativePostActionStabilityTests {

    func testDeadlineDuringCapturePreservesLatestButNotStableAndNoFrameThrows() throws {
        let firstSample = try frame()
        for hasFrame in [false, true] {
            var time = 0.0, count = 0
            func capture() throws -> CapturedObservation {
                try NativePostActionStability.capture(
                    now: { time }, pause: { time += $0 }, checkCancellation: {},
                    sample: { _ in
                        count += 1; time += 1
                        if !hasFrame || count > 1 { throw IPhoneUseError("input_preflight_timeout", "test") }
                        return firstSample
                    })
            }
            if hasFrame {
                let result = try capture()
                XCTAssertEqual(result.screenshot, firstSample.screenshot)
                XCTAssertEqual(facts(result)["stable"] as? Bool, false)
            } else {
                XCTAssertThrowsError(try capture()) {
                    XCTAssertEqual(($0 as? IPhoneUseError)?.code, "post_action_capture_timeout")
                }
            }
        }
    }

    func testContextChangeDuringCaptureResetsEvidenceWithoutReplayingInput() throws {
        let firstSample = try frame()
        var time = 0.0, count = 0
        let result = try NativePostActionStability.capture(
            now: { time }, pause: { time += $0 }, checkCancellation: {},
            sample: { _ in
                count += 1; time += 0.6
                if count == 3 { throw IPhoneUseError("capture_context_changed", "transition") }
                return firstSample
            })
        XCTAssertEqual(count, 6)
        XCTAssertEqual(facts(result)["stable"] as? Bool, true)
    }

    func testSlowDriftComparedAgainstAnchorRatherThanAdjacentFrames() throws {
        var time = 0.0, count = 0
        let frames = try (0..<15).map { try frame(UInt8(100 + $0 * 2)) }
        let result = try NativePostActionStability.capture(
            now: { time }, pause: { time += $0 }, checkCancellation: {},
            sample: { _ in
                time += 1; defer { count += 1 }; return frames[count]
            })
        XCTAssertEqual(facts(result)["stable"] as? Bool, false)
    }
}
