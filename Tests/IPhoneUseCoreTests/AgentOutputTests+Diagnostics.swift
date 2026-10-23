import XCTest
@testable import IPhoneUseCore

extension AgentOutputTests {

    func testBaselineDiagnosticsSurviveSummaryAndReceiptWithoutInventingComparison() throws {
        for component in ["target", "anchor"] {
            let failure = ScreenGuard.DynamicBaselineFailure(
                component: component,
                rect: ScreenRect(CGRect(x: 12, y: 100, width: 32, height: 32)))
            for outcome in ["not_dispatched", "unknown"] {
                let raw: [String: Any] = [
                    "ok": false,
                    "action": [
                        "ok": false, "outcome": outcome,
                        "error": ["code": failure.code, "message": failure.message],
                        "result": ["screenGuardPreparation": failure.diagnostics]
                    ], "observation": observation
                ]
                let compact = AgentOutput.render(raw)
                let receipt = URL(fileURLWithPath: try XCTUnwrap(compact["receipt"] as? String))
                defer { try? FileManager.default.removeItem(at: receipt.deletingLastPathComponent()) }
                let saved = try jsonObject(Data(contentsOf: receipt))
                XCTAssertEqual(try jsonData(saved), try jsonData(raw))
                let summary = try XCTUnwrap(compact["agentSummary"] as? [String: Any])
                XCTAssertEqual(summary["outcome"] as? String, outcome)
                XCTAssertEqual(summary["automaticReplayAllowed"] as? Bool, false)
                XCTAssertEqual(
                    try jsonData((try XCTUnwrap(summary["screenGuardPreparation"] as? [String: Any]))),
                    try jsonData(failure.diagnostics)
                )
                XCTAssertNil(summary["comparison"])
                XCTAssertNil(summary["preflightStages"])
                if outcome == "not_dispatched" {
                    XCTAssertNotNil(summary["recoveryHint"])
                } else {
                    XCTAssertNil(summary["recoveryHint"])
                }
            }
        }
    }

    func testCaptureBudgetDiagnosticsRemainVisibleWithoutRawMediaState() throws {
        let checks: [[String: Any]] = [
            [
                "stage": "before_input", "attempt": 1,
                "preparationMs": 9000.0, "validationAndCheckMs": 2000.0,
                "orientationRecovery": ["trigger": "stream_quiescent", "triggerState": ["private": true]]
            ],
            ["stage": "after_clipboard", "captureError": "input_preflight_timeout", "phase": "preparation"]
        ]
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
        XCTAssertEqual(
            try jsonData((try XCTUnwrap(compact["observation"] as? [String: Any]))), try jsonData(observation)
        )
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
        XCTAssertTrue(hint.contains("--dynamic-target"))
        XCTAssertTrue(hint.contains("--dynamic-anchor"))
        XCTAssertTrue(hint.contains("25%"))
        XCTAssertTrue(hint.contains("not submissions, purchases or destructive actions"))
        XCTAssertEqual(summary["outcome"] as? String, "not_dispatched")
        XCTAssertEqual(summary["automaticReplayAllowed"] as? Bool, false)
        XCTAssertEqual(summary["nextStep"] as? String, "inspect_attached_observation")
    }

    func testTimeoutTakesPrecedenceOverSimultaneousPixelMismatch() throws {
        for explicitDeadline in [false, true] {
            var source = response()
            var action = (try XCTUnwrap(source["action"] as? [String: Any]))
            if explicitDeadline {
                var details = (try XCTUnwrap(action["result"] as? [String: Any]))
                details["preInputDeadlineExceeded"] = true
                action["result"] = details
            } else {
                action["error"] = ["code": "input_preflight_timeout"]
            }
            source["action"] = action
            let summary = (try XCTUnwrap(AgentOutput.summarize(source)["agentSummary"] as? [String: Any]))
            let hint = try XCTUnwrap(summary["recoveryHint"] as? String)
            XCTAssertTrue(hint.contains("execution-time validation exceeded its budget"))
            XCTAssertFalse(hint.contains("--ignore-rect"))
            XCTAssertEqual(
                (summary["comparison"] as? [String: Any])?["mismatches"] as? [String], ["screen_changed"])
        }
    }

    func testDynamicComparisonUsesTargetAndAnchorInsteadOfWholeScreenMotion() throws {
        for matches in [[true, true], [false, true], [true, false], [false, false]] {
            let check = ScreenGuard.Check(
                screenChange: 0.265625, regionChanges: [],
                policy: .init(), dynamicMatches: matches
            ).result
            for outcome in ["completed", "unknown", "not_dispatched"] {
                let source: [String: Any] = [
                    "action": [
                        "outcome": outcome,
                        "error": ["code": "screen_changed"],
                        "result": [
                            "screenGuard": check,
                            "preInputChecks": [["stage": "before_input", "screenGuard": check]]
                        ]
                    ],
                    "observation": observation
                ]
                let compact = AgentOutput.summarize(source)
                let summary = try XCTUnwrap(compact["agentSummary"] as? [String: Any])
                let comparison = try XCTUnwrap(summary["comparison"] as? [String: Any])
                let expected = zip(matches, ["dynamic_target_changed", "dynamic_anchor_changed"]).compactMap {
                    $0 ? nil : $1
                }
                XCTAssertEqual(comparison["mismatches"] as? [String], expected)
                XCTAssertEqual(comparison["accepted"] as? Bool, matches.allSatisfy { $0 })
                XCTAssertEqual(comparison["algorithm"] as? String, ScreenGuard.dynamicAlgorithm)
                XCTAssertEqual(comparison["validationScope"] as? String, "explicit_target_and_anchor")
                XCTAssertEqual(comparison["dynamicMatches"] as? [Bool], matches)
                XCTAssertEqual(comparison["screenChange"] as? Double, 0.265625)
                let stages = try XCTUnwrap(summary["preflightStages"] as? [[String: Any]])
                XCTAssertEqual(
                    try jsonData((try XCTUnwrap(stages[0]["comparison"] as? [String: Any]))),
                    try jsonData(comparison))
                XCTAssertEqual(summary["outcome"] as? String, outcome)
                XCTAssertEqual(summary["automaticReplayAllowed"] as? Bool, false)
                XCTAssertEqual(
                    try jsonData((try XCTUnwrap(compact["observation"] as? [String: Any]))),
                    try jsonData(observation))
                if outcome == "not_dispatched" && !expected.isEmpty {
                    let hint = try XCTUnwrap(summary["recoveryHint"] as? String)
                    XCTAssertTrue(hint.contains("target or page anchor did not match"))
                    XCTAssertFalse(hint.contains("--ignore-rect"))
                } else {
                    XCTAssertNil(summary["recoveryHint"])
                }
            }
        }
    }

    func testDynamicScopeWithoutBothMatchesDoesNotImplySuccess() throws {
        for matches: Any in [[true], [], "invalid"] {
            let check: [String: Any] = [
                "accepted": false, "validationScope": "explicit_target_and_anchor",
                "dynamicMatches": matches, "screenChange": 0.3, "maxScreenChange": 0.01
            ]
            let summary =
                (try XCTUnwrap(
                    AgentOutput.summarize(["result": ["screenGuard": check]])["agentSummary"]
                        as? [String: Any]))
            let comparison = (try XCTUnwrap(summary["comparison"] as? [String: Any]))
            XCTAssertEqual(comparison["accepted"] as? Bool, false)
            XCTAssertEqual(comparison["mismatches"] as? [String], ["dynamic_match_evidence_unavailable"])
        }
    }

    func testSpecificCaretRecoveryIsNotReplacedWithVideoAdvice() throws {
        var source = response()
        var action = (try XCTUnwrap(source["action"] as? [String: Any]))
        action["error"] = ["code": "caret_confirmation_required", "message": "Confirm visible caret"]
        source["action"] = action
        let compact = AgentOutput.summarize(source)
        XCTAssertNil((compact["agentSummary"] as? [String: Any])?["recoveryHint"])
        XCTAssertEqual(
            ((compact["action"] as? [String: Any])?["error"] as? [String: Any])?["code"] as? String,
            "caret_confirmation_required")
    }
}
