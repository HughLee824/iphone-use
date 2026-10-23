import XCTest
@testable import IPhoneUseCore

final class ActionObservationTests: XCTestCase {
    private let session = "fixture-session"
    private func action(_ outcome: String) -> [String: Any] {
        [
            "session": session, "id": "action-request", "ok": outcome == "completed", "outcome": outcome,
            "result": ["frame": ["screenshot": "/action.png"]]
        ]
    }

    func testCompletedAndUnknownPreserveBothResponsesAndObserveOnce() throws {
        for outcome in ["completed", "unknown"] {
            let input = action(outcome)
            let observation: [String: Any] = [
                "session": session, "id": "capture-request", "ok": true,
                "result": ["text": "observation=o2 refs=current"]
            ]
            var captures = 0
            let response = SessionClient.observing(session: session, action: input) {
                captures += 1
                return observation
            }
            XCTAssertEqual(captures, 1)
            XCTAssertEqual(response["ok"] as? Bool, outcome == "completed")
            XCTAssertEqual(
                try jsonData((try XCTUnwrap(response["action"] as? [String: Any]))), try jsonData(input))
            XCTAssertEqual(
                try jsonData((try XCTUnwrap(response["observation"] as? [String: Any]))),
                try jsonData(observation))
        }
    }

    func testOnlyConfirmedRejectionsWithoutRefreshRequirementSkipCapture() {
        for requirement: Bool? in [nil, false, true] {
            var input = action("not_dispatched")
            input["requiresObservation"] = requirement
            var captures = 0
            let response = SessionClient.observing(session: session, action: input) {
                captures += 1
                return ["ok": true]
            }
            XCTAssertEqual(captures, requirement == true ? 1 : 0)
            XCTAssertEqual(response["ok"] as? Bool, false)
            if requirement != true {
                XCTAssertEqual((response["observation"] as? [String: String])?["skipped"], "not_dispatched")
            }
        }
        for fields: [String: Any] in [
            ["session": "wrong"], ["requiresObservation": "invalid"], ["outcome": "unrecognized"],
            ["ok": true]
        ] {
            let input = action("not_dispatched").merging(fields) { _, new in new }
            var captures = 0
            _ = SessionClient.observing(session: session, action: input) {
                captures += 1
                return ["ok": true]
            }
            XCTAssertEqual(captures, 1)
        }
    }

    func testObservationFailureNeverOverwritesActionFacts() throws {
        for outcome in ["completed", "unknown"] {
            for shouldThrow in [false, true] {
                let input = action(outcome)
                let response = SessionClient.observing(session: session, action: input) {
                    if shouldThrow { throw IPhoneUseError("capture_failed", "Fixture capture failure") }
                    return ["ok": false, "error": ["code": "session_unavailable"]]
                }
                XCTAssertEqual(response["ok"] as? Bool, false)
                XCTAssertEqual(
                    try jsonData((try XCTUnwrap(response["action"] as? [String: Any]))), try jsonData(input))
                let observation = (try XCTUnwrap(response["observation"] as? [String: Any]))
                XCTAssertEqual(observation["ok"] as? Bool, false)
                XCTAssertEqual(
                    (observation["error"] as? [String: String])?["code"],
                    shouldThrow ? "capture_failed" : "session_unavailable")
            }
        }
    }
}
