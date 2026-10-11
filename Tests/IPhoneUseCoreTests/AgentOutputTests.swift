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

    func testCaptureBudgetDiagnosticsRemainVisibleWithoutRawMediaState() throws {
        let checks: [[String: Any]] = [["stage": "before_input", "attempt": 1,
            "preparationMs": 9000.0, "validationAndCheckMs": 2000.0,
            "orientationRecovery": ["trigger": "stream_quiescent", "triggerState": ["private": true]]],
            ["stage": "after_clipboard", "captureError": "input_preflight_timeout", "phase": "preparation"]]
        let compact = AgentOutput.summarize(["result": ["preInputChecks": checks]])
        let summary = try XCTUnwrap(compact["agentSummary"] as? [String: Any])
        let stages = try XCTUnwrap(summary["preflightStages"] as? [[String: Any]])
        XCTAssertEqual(stages[0]["recoveryTrigger"] as? String, "stream_quiescent")
        XCTAssertEqual(stages[0]["preparationMs"] as? Double, 9000)
        XCTAssertEqual(stages[0]["validationAndCheckMs"] as? Double, 2000)
        XCTAssertNil(stages[0]["orientationRecovery"])
        XCTAssertEqual(stages[1]["captureError"] as? String, "input_preflight_timeout")
        XCTAssertEqual(stages[1]["phase"] as? String, "preparation")
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
        XCTAssertNil((compact["agentSummary"] as? [String: Any])?["recoveryHint"])
    }

    func testChangedScreenRecoveryKeepsNonDispatchAndDoesNotDiagnoseVideo() throws {
        let compact = AgentOutput.summarize(response())
        let summary = try XCTUnwrap(compact["agentSummary"] as? [String: Any])
        let hint = try XCTUnwrap(summary["recoveryHint"] as? String)
        XCTAssertTrue(hint.contains("screen comparison failed"))
        XCTAssertTrue(hint.contains("Only for a visually identified video"))
        XCTAssertTrue(hint.contains("protected neighborhoods"))
        XCTAssertEqual(summary["outcome"] as? String, "not_dispatched")
        XCTAssertEqual(summary["automaticReplayAllowed"] as? Bool, false)
        XCTAssertEqual(summary["nextStep"] as? String, "inspect_attached_observation")
    }

    func testTimeoutTakesPrecedenceOverSimultaneousPixelMismatch() throws {
        for explicitDeadline in [false, true] {
            var source = response()
            var action = source["action"] as! [String: Any]
            if explicitDeadline {
                var details = action["result"] as! [String: Any]
                details["preInputDeadlineExceeded"] = true
                action["result"] = details
            } else {
                action["error"] = ["code": "input_preflight_timeout"]
            }
            source["action"] = action
            let summary = AgentOutput.summarize(source)["agentSummary"] as! [String: Any]
            let hint = try XCTUnwrap(summary["recoveryHint"] as? String)
            XCTAssertTrue(hint.contains("execution-time validation exceeded its budget"))
            XCTAssertFalse(hint.contains("--ignore-rect"))
            XCTAssertEqual((summary["comparison"] as? [String: Any])?["mismatches"] as? [String], ["screen_changed"])
        }
    }

    func testSpecificCaretRecoveryIsNotReplacedWithVideoAdvice() {
        var source = response()
        var action = source["action"] as! [String: Any]
        action["error"] = ["code": "caret_confirmation_required", "message": "Confirm visible caret"]
        source["action"] = action
        let compact = AgentOutput.summarize(source)
        XCTAssertNil((compact["agentSummary"] as? [String: Any])?["recoveryHint"])
        XCTAssertEqual(((compact["action"] as? [String: Any])?["error"] as? [String: Any])?["code"] as? String,
                       "caret_confirmation_required")
    }

    func testUnstableObservationDoesNotRecommendCaptureLoopOrReplay() throws {
        var source = response(outcome: "unknown")
        var frame = observation
        frame["stability"] = ["stable": false, "reason": "timeout"]
        source["observation"] = frame
        let compact = AgentOutput.summarize(source)
        let summary = compact["agentSummary"] as! [String: Any]
        XCTAssertEqual(summary["nextStep"] as? String, "inspect_unstable_observation_do_not_replay")
        XCTAssertTrue(try XCTUnwrap(summary["recoveryHint"] as? String).contains("does not mean input failed"))
        XCTAssertEqual(summary["outcome"] as? String, "unknown")
        XCTAssertEqual(try jsonData(compact["observation"] as! [String: Any]), try jsonData(frame))
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

    func testBoundCaretMatchPreservesOriginalObservationIdentity() {
        let check: [String:Any] = ["accepted":true,"screenChange":0.0,"maxScreenChange":0.01,
            "regionChanges":[0.2],"maxRegionChange":0.0,"fieldPixelsMatch":false,"fieldCaretMatch":true,
            "caretObservationID":"o9", "caretRect":["x":19.0,"y":479.0,"width":2.0,"height":20.0],
            "caretExclusionRect":["x":19.0,"y":478.6666667,"width":2.0,"height":20.6666667]]
        let compact = AgentOutput.summarize(["result":["screenGuard":check]])
        let comparison = (compact["agentSummary"] as! [String:Any])["comparison"] as! [String:Any]
        XCTAssertEqual(comparison["fieldMatch"] as? String,"caret")
        XCTAssertEqual(comparison["caretObservationID"] as? String,"o9")
        XCTAssertEqual((comparison["caretExclusionRect"] as? [String:Double])?["y"],478.6666667)
        XCTAssertEqual((comparison["caretRect"] as? [String:Double])?["y"],479)
        XCTAssertEqual(comparison["mismatches"] as? [String],[])
    }

    func testAppearanceMatchDoesNotReportProtectedFieldFailure() {
        let check: [String: Any] = ["accepted": true, "screenChange": 0.0, "maxScreenChange": 0.01,
            "regionChanges": [0.01], "maxRegionChange": 0.0, "fieldPixelsMatch": false,
            "fieldTemporalMatch": false, "fieldAppearanceMatch": true]
        let compact = AgentOutput.summarize(["result": ["screenGuard": check]])
        let summary = compact["agentSummary"] as! [String: Any]
        let comparison = summary["comparison"] as! [String: Any]
        XCTAssertEqual(comparison["fieldMatch"] as? String, "appearance")
        XCTAssertEqual(comparison["mismatches"] as? [String], [])
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
