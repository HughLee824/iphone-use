import XCTest
@testable import IPhoneUseCore

extension AgentOutputTests {

    func testUnstableObservationDoesNotRecommendCaptureLoopOrReplay() throws {
        var source = response(outcome: "unknown")
        var frame = observation
        frame["stability"] = ["stable": false, "reason": "timeout"]
        source["observation"] = frame
        let compact = AgentOutput.summarize(source)
        let summary = (try XCTUnwrap(compact["agentSummary"] as? [String: Any]))
        XCTAssertEqual(summary["nextStep"] as? String, "inspect_unstable_observation_do_not_replay")
        XCTAssertTrue(
            try XCTUnwrap(summary["recoveryHint"] as? String).contains("does not mean input failed"))
        XCTAssertEqual(summary["outcome"] as? String, "unknown")
        XCTAssertEqual(
            try jsonData((try XCTUnwrap(compact["observation"] as? [String: Any]))), try jsonData(frame))
    }

    func testPreparationAndFinishReuseAttachedObservation() throws {
        for details: [String: Any] in [
            ["keyboardPrepared": true], ["pasteboardRestoreAcknowledged": true, "transactionID": "t1"]
        ] {
            let reply: [String: Any] = [
                "ok": true, "outcome": "completed", "requiresObservation": true,
                "result": details, "observation": observation
            ]
            let compact = AgentOutput.summarize(reply)
            XCTAssertEqual(
                try jsonData((try XCTUnwrap(compact["result"] as? [String: Any]))), try jsonData(details))
            XCTAssertEqual(
                (compact["agentSummary"] as? [String: Any])?["nextStep"] as? String,
                "inspect_attached_observation")
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

    func testFieldChangeAndTemporalMatchRemainDistinct() throws {
        for temporal in [false, true] {
            let check: [String: Any] = [
                "accepted": temporal, "screenChange": 0.0, "maxScreenChange": 0.01,
                "regionChanges": [0.2], "maxRegionChange": 0.0, "fieldPixelsMatch": false,
                "fieldTemporalMatch": temporal
            ]
            let compact = AgentOutput.summarize(["result": ["screenGuard": check]])
            let summary = (try XCTUnwrap(compact["agentSummary"] as? [String: Any]))
            let comparison = (try XCTUnwrap(summary["comparison"] as? [String: Any]))
            XCTAssertEqual(comparison["fieldMatch"] as? String, temporal ? "temporal" : "different")
            XCTAssertEqual(
                comparison["mismatches"] as? [String],
                temporal ? [] : ["field_changed", "protected_region_changed"])
        }
    }

    func testBoundCaretMatchPreservesOriginalObservationIdentity() throws {
        let check: [String: Any] = [
            "accepted": true, "screenChange": 0.0, "maxScreenChange": 0.01,
            "regionChanges": [0.2], "maxRegionChange": 0.0, "fieldPixelsMatch": false,
            "fieldCaretMatch": true,
            "caretObservationID": "o9", "caretRect": ["x": 19.0, "y": 479.0, "width": 2.0, "height": 20.0],
            "caretExclusionRect": ["x": 19.0, "y": 478.6666667, "width": 2.0, "height": 20.6666667]
        ]
        let compact = AgentOutput.summarize(["result": ["screenGuard": check]])
        let comparison =
            (try XCTUnwrap(
                ((try XCTUnwrap(compact["agentSummary"] as? [String: Any])))["comparison"] as? [String: Any]))
        XCTAssertEqual(comparison["fieldMatch"] as? String, "caret")
        XCTAssertEqual(comparison["caretObservationID"] as? String, "o9")
        XCTAssertEqual((comparison["caretExclusionRect"] as? [String: Double])?["y"], 478.6666667)
        XCTAssertEqual((comparison["caretRect"] as? [String: Double])?["y"], 479)
        XCTAssertEqual(comparison["mismatches"] as? [String], [])
    }

    func testAppearanceMatchDoesNotReportProtectedFieldFailure() throws {
        let check: [String: Any] = [
            "accepted": true, "screenChange": 0.0, "maxScreenChange": 0.01,
            "regionChanges": [0.01], "maxRegionChange": 0.0, "fieldPixelsMatch": false,
            "fieldTemporalMatch": false, "fieldAppearanceMatch": true
        ]
        let compact = AgentOutput.summarize(["result": ["screenGuard": check]])
        let summary = (try XCTUnwrap(compact["agentSummary"] as? [String: Any]))
        let comparison = (try XCTUnwrap(summary["comparison"] as? [String: Any]))
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
        for (url, expected) in [
            (URL(fileURLWithPath: path), 0o600),
            (URL(fileURLWithPath: path).deletingLastPathComponent(), 0o700)
        ] {
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
