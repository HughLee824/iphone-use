@testable import IPhoneUseRunnerSupport
import XCTest
@testable import IPhoneUseCore

extension NativeTextInputTests {

    func testLateMatchingFrameAndCancellationCannotAuthorizeInput() throws {
        let context = screenTestContext(), png = try screenPNG()
        let guardValue = try ScreenGuard(png: png, context: context, rects: [context.screen], policy: .init())
        let frame = CapturedObservation(
            nodes: [],
            metadata: [
                "displayID": UInt64(1), "screenContext": try jsonObject(JSONEncoder().encode(context))
            ],
            screenshot: png)
        var time = 0.0, captures = 0
        XCTAssertThrowsError(
            try NativeInputPreflight.check(
                guard: guardValue, displayID: 1, deadline: 8, maximumCaptures: 3, now: { time },
                capture: {
                    captures += 1; time = 9; return frame
                })
        ) { XCTAssertEqual(($0 as? ActionFailure)?.result?["preInputDeadlineExceeded"] as? Bool, true) }
        XCTAssertEqual(captures, 1)
        let cancellation = NativeCancellation(); cancellation.cancel()
        XCTAssertThrowsError(
            try NativeInputPreflight.check(
                guard: guardValue, displayID: 1, deadline: 8, maximumCaptures: 3, now: { 0 },
                capture: {
                    try cancellation.check(); captures += 1; return frame
                }))
        XCTAssertEqual(captures, 1)
    }
}
