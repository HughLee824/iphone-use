import XCTest
@testable import IPhoneUseCore

final class AgentOutputTests: XCTestCase {
    private let observation: [String: Any] = ["ok": true, "phase": "pre_input_rejection",
        "result": ["observation": "o3", "refs": "current", "screenshot": "/fixture/screen.png", "text": "screen_points=390x844"]]

    private func response(outcome: String = "not_dispatched") -> [String: Any] {
        let check: [String: Any] = ["accepted": false, "screenChange": 0.0149, "maxScreenChange": 0.01,
            "regionChanges": [0.0], "maxRegionChange": 0.0, "fieldPixelsMatch": true, "fieldTemporalMatch": false]
        let samples: [[String: Any]] = (1...6).map { ["stage": "before_clipboard", "attempt": $0,
            "inTime": true, "screenGuard": check, "mediaPhaseSamples": String(repeating: "diagnostic", count: 200)] }
        return ["session": "test", "ok": false, "action": ["ok": false, "outcome": outcome,
            "requiresObservation": true, "error": ["code": "stale_observation", "message": "Inspect rejection"],
            "observation": observation, "result": ["screenGuard": check, "preInputChecks": samples,
                "pasteboard": ["transactionID": "t1", "restorePending": true, "writeUncertain": false],
                "recovery": ["automaticReplayAllowed": false]]], "observation": observation]
    }

    func testGlobalRejectionDoesNotTreatUnusedTemporalMatchingAsFailure() throws {
        let source = response()
        let compact = AgentOutput.summarize(source)
        let summary = try XCTUnwrap(compact["agentSummary"] as? [String: Any])
        let comparison = try XCTUnwrap(summary["comparison"] as? [String: Any])
        XCTAssertEqual(comparison["fieldMatch"] as? String, "pixels")
        XCTAssertEqual(comparison["mismatches"] as? [String], ["screen_changed"])
        XCTAssertEqual(summary["nextStep"] as? String, "inspect_attached_observation")
        let stages = try XCTUnwrap(summary["preflightStages"] as? [[String: Any]])
        XCTAssertEqual(stages.count, 1)
        XCTAssertEqual(stages.first?["attempt"] as? Int, 6)
        XCTAssertEqual(try jsonData(compact["observation"] as! [String: Any]), try jsonData(observation))
        XCTAssertLessThan(try jsonData(compact).count, try jsonData(source).count / 2)
    }

    func testUnknownIsNeverConvertedToSuccessAndClipboardIsRetained() throws {
        let compact = AgentOutput.summarize(response(outcome: "unknown"))
        let action = try XCTUnwrap(compact["action"] as? [String: Any])
        XCTAssertEqual(action["outcome"] as? String, "unknown")
        XCTAssertEqual(compact["ok"] as? Bool, false)
        let details = try XCTUnwrap(action["result"] as? [String: Any])
        XCTAssertEqual((details["pasteboard"] as? [String: Any])?["transactionID"] as? String, "t1")
        XCTAssertNotNil(action["error"])
        XCTAssertNotNil(details["recovery"])
    }

    func testPreparationAndFinishReuseAttachedObservation() throws {
        for details: [String: Any] in [["keyboardPrepared": true], ["pasteboardRestoreAcknowledged": true, "transactionID": "t1"]] {
            let reply: [String: Any] = ["ok": true, "outcome": "completed", "requiresObservation": true,
                                       "result": details, "observation": observation]
            let compact = AgentOutput.summarize(reply)
            XCTAssertEqual(try jsonData(compact["result"] as! [String: Any]), try jsonData(details))
            XCTAssertEqual((compact["agentSummary"] as? [String: Any])?["nextStep"] as? String, "inspect_attached_observation")
        }
    }

    func testFailedObservationPreservesErrorAndRequiresObservationWithoutReplay() throws {
        var reply = response(outcome: "unknown")
        reply["observation"] = ["ok": false, "error": "capture_failed"]
        let compact = AgentOutput.summarize(reply)
        let summary = try XCTUnwrap(compact["agentSummary"] as? [String: Any])
        XCTAssertEqual(summary["automaticReplayAllowed"] as? Bool, false)
        XCTAssertEqual(summary["nextStep"] as? String, "observe_before_next_input")
        XCTAssertEqual((compact["observation"] as? [String: Any])?["error"] as? String, "capture_failed")
    }

    func testFieldChangeAndTemporalMatchRemainDistinct() {
        for temporal in [false, true] {
            let check: [String: Any] = ["accepted": temporal, "screenChange": 0.0, "maxScreenChange": 0.01,
                "regionChanges": [0.2], "maxRegionChange": 0.0, "fieldPixelsMatch": false, "fieldTemporalMatch": temporal]
            let compact = AgentOutput.summarize(["result": ["screenGuard": check]])
            let summary = compact["agentSummary"] as! [String: Any]
            let comparison = summary["comparison"] as! [String: Any]
            XCTAssertEqual(comparison["fieldMatch"] as? String, temporal ? "temporal" : "different")
            XCTAssertEqual(comparison["mismatches"] as? [String], temporal ? [] : ["field_changed", "protected_region_changed"])
        }
    }

    func testPrivateReceiptRoundTripsFullReplyAndSurvivesPresentation() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = response(outcome: "unknown")
        let compact = AgentOutput.render(source, directory: base)
        let path = try XCTUnwrap(compact["receipt"] as? String)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), try jsonData(source))
        for (url, expected) in [(URL(fileURLWithPath: path), 0o600), (URL(fileURLWithPath: path).deletingLastPathComponent(), 0o700)] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, expected)
        }
    }

    func testReceiptFailureReturnsFullFactsInsteadOfOverwritingOutcome() throws {
        let source = response(outcome: "unknown")
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var fallback = AgentOutput.render(source, directory: missing)
        XCTAssertNotNil(fallback.removeValue(forKey: "agentOutputError"))
        XCTAssertEqual(try jsonData(fallback), try jsonData(source))
    }
}
