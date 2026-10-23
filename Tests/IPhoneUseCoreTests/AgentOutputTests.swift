import XCTest
@testable import IPhoneUseCore

final class AgentOutputTests: XCTestCase {
    let observation: [String: Any] = [
        "ok": true, "phase": "pre_input_rejection",
        "result": [
            "observation": "o3", "refs": "current", "screenshot": "/fixture/screen.png",
            "text": "screen_points=390x844"
        ]
    ]

    func response(outcome: String = "not_dispatched") -> [String: Any] {
        let check: [String: Any] = [
            "accepted": false, "screenChange": 0.0149, "maxScreenChange": 0.01,
            "regionChanges": [0.0], "maxRegionChange": 0.0, "fieldPixelsMatch": true,
            "fieldTemporalMatch": false
        ]
        let samples: [[String: Any]] = (1...6).map {
            [
                "stage": "before_clipboard", "attempt": $0,
                "inTime": true, "screenGuard": check,
                "mediaPhaseSamples": String(repeating: "diagnostic", count: 200)
            ]
        }
        return [
            "session": "test", "ok": false,
            "action": [
                "ok": false, "outcome": outcome,
                "requiresObservation": true,
                "error": ["code": "stale_observation", "message": "Inspect rejection"],
                "observation": observation,
                "result": [
                    "screenGuard": check, "preInputChecks": samples,
                    "pasteboard": ["transactionID": "t1", "restorePending": true, "writeUncertain": false],
                    "recovery": ["automaticReplayAllowed": false]
                ]
            ], "observation": observation
        ]
    }
}
