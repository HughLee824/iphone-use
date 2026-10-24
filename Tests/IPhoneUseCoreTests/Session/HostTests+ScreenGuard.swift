import XCTest
import Foundation
import Network
@testable import IPhoneUseCore

extension HostTests {

    func testScreenGuardRejectionInvalidatesRefsBeforeAnyInputAndDoesNotRetry() throws {
        let backend = ControlledBackend()
        backend.liveScreen = try screenPNG(patches: [(CGRect(x: 0, y: 0, width: 390, height: 844), [0, 0, 0])]
        )
        let running = try host(timeout: 5, backend: backend)
        let paths = running.paths, session = running.session, finished = running.finished
        _ = try call(paths, session: session, op: "observe")
        let fields: [String: Any] = ["reference": "o1", "x": 200, "y": 600]
        let rejected = try call(paths, session: session, op: "tap", fields: fields)
        XCTAssertEqual(rejected["outcome"] as? String, "not_dispatched")
        XCTAssertEqual(rejected["requiresObservation"] as? Bool, true)
        XCTAssertEqual((rejected["error"] as? [String: Any])?["code"] as? String, "screen_changed")
        XCTAssertEqual(backend.inputCount, 0)
        XCTAssertTrue(backend.previewGestures.isEmpty)
        let again = try call(paths, session: session, op: "tap", fields: fields)
        XCTAssertEqual((again["error"] as? [String: Any])?["code"] as? String, "stale_reference")
        XCTAssertEqual(backend.actionCount, 1)
        backend.liveScreen = try screenPNG()
        _ = try call(paths, session: session, op: "observe")
        XCTAssertEqual(
            try call(paths, session: session, op: "tap", fields: ["reference": "o2", "x": 200, "y": 600])[
                "outcome"]
                as? String, "completed")
        XCTAssertEqual(backend.inputCount, 1)
        XCTAssertEqual(backend.previewGestures.count, 1)
        _ = try call(paths, session: session, op: "disconnect")
        wait(for: [finished], timeout: 3)
    }
}
