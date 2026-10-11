import Foundation

/// An opt-in presentation of a completed CLI reply. Never performs device work.
public enum AgentOutput {
    public static func render(_ response: [String: Any]) -> [String: Any] {
        render(response, directory: FileManager.default.temporaryDirectory)
    }

    static func render(_ response: [String: Any], directory: URL) -> [String: Any] {
        do {
            // A unique private directory avoids sharing receipts across users or
            // following an existing path. Receipts outlive session disconnect.
            let folder = directory.appendingPathComponent("iphone-use-receipt-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let path = folder.appendingPathComponent("response.json")
            do {
                let data = try jsonData(response)
                guard FileManager.default.createFile(atPath: path.path, contents: data,
                                                      attributes: [.posixPermissions: 0o600]) else {
                    throw IPhoneUseError("receipt_write_failed", "Could not save the complete response")
                }
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
            var result = summarize(response)
            result["receipt"] = path.path
            return result
        } catch {
            // Output failure cannot replace an action's known or unknown outcome.
            var fallback = response
            fallback["agentOutputError"] = "Full response retained because receipt storage failed: \(error)"
            return fallback
        }
    }

    static func summarize(_ response: [String: Any]) -> [String: Any] {
        var result = response
        var action = response["action"] as? [String: Any] ?? response
        var details = action["result"] as? [String: Any] ?? [:]
        let checks = details["preInputChecks"] as? [[String: Any]] ?? []
        // Keep one final result per stage, rather than repeating media samples
        // and transport timings. Full diagnostics remain in the receipt.
        var stages: [[String: Any]] = []
        for check in checks {
            let stage = check["stage"] as? String ?? "unspecified"
            stages.removeAll { $0["stage"] as? String == stage }
            var entry = check.filter { ["stage", "attempt", "inTime", "elapsedMs", "preparationMs", "validationAndCheckMs", "captureError", "captureDiagnostics", "phase"].contains($0.key) }
            if let guardValue = check["screenGuard"] as? [String: Any] {
                entry["comparison"] = comparison(guardValue)
            }
            entry["recoveryTrigger"] = (check["orientationRecovery"] as? [String: Any])?["trigger"]
            stages.append(entry)
        }
        details.removeValue(forKey: "preInputChecks")
        action["result"] = details
        let observation = response["observation"] as? [String: Any] ?? action["observation"] as? [String: Any]
        if response["action"] != nil {
            action.removeValue(forKey: "observation") // It is already in the envelope.
            result["action"] = action
        } else {
            result["result"] = details
        }
        var summary: [String: Any] = ["automaticReplayAllowed": false]
        summary["outcome"] = action["outcome"]
        summary["transportStatus"] = details["transportStatus"]
        summary["preflightStages"] = stages.isEmpty ? nil : stages
        if let guardValue = details["screenGuard"] as? [String: Any] {
            summary["comparison"] = comparison(guardValue)
        }
        let errorCode = (action["error"] as? [String: Any])?["code"] as? String
        let mismatches = (summary["comparison"] as? [String: Any])?["mismatches"] as? [String] ?? []
        if action["outcome"] as? String == "not_dispatched" {
            if details["preInputDeadlineExceeded"] as? Bool == true || errorCode == "input_preflight_timeout" {
                summary["recoveryHint"] = "Input was not sent because execution-time validation exceeded its budget, not because the Agent took too long to think. Inspect the current observation and timing diagnostics; do not loop on an unchanged timeout."
            } else if ["stale_observation", "screen_changed"].contains(errorCode ?? ""), !mismatches.isEmpty {
                summary["recoveryHint"] = "Input was not sent because the screen comparison failed. Inspect what changed; a new observation ID alone does not fix continuous motion. Only for a visually identified video outside the target, select --ignore-rect and a gesture path whose protected neighborhoods do not overlap it. Otherwise re-plan from the changed UI or report the blocker; do not repeat the same failing strategy."
            }
        }
        summary["preInputDeadlineExceeded"] = details["preInputDeadlineExceeded"]
        summary["pasteboard"] = details["pasteboard"]
        summary["pasteboardRestoreAcknowledged"] = details["pasteboardRestoreAcknowledged"]
        let stability = observation?["stability"] as? [String: Any]
        summary["postActionStability"] = stability
        if stability?["stable"] as? Bool == false {
            summary["nextStep"] = "inspect_unstable_observation_do_not_replay"
            if summary["recoveryHint"] == nil {
                summary["recoveryHint"] = "The returned image did not settle; this does not mean input failed. Inspect it for the actual result, a dialog or continuous motion before choosing the next action. Do not resend input or keep capturing in the hope that a playing video becomes static."
            }
        } else if observation?["ok"] as? Bool == true {
            summary["nextStep"] = "inspect_attached_observation"
        } else if action["requiresObservation"] as? Bool == true || ["unknown", "completed"].contains(action["outcome"] as? String ?? "") {
            summary["nextStep"] = "observe_before_next_input"
        } else {
            summary["nextStep"] = "follow_error_and_reference_validity"
        }
        result["agentSummary"] = summary
        return result
    }

    private static func comparison(_ check: [String: Any]) -> [String: Any] {
        var result = check.filter { ["accepted", "screenChange", "maxScreenChange", "regionChanges",
                                    "maxRegionChange", "ignoredRect", "caretRect", "caretExclusionRect", "caretObservationID"].contains($0.key) }
        let caret = check["fieldCaretMatch"] as? Bool == true
        let temporal = check["fieldTemporalMatch"] as? Bool == true
        let appearance = check["fieldAppearanceMatch"] as? Bool == true
        if let pixels = check["fieldPixelsMatch"] as? Bool {
            result["fieldMatch"] = caret ? "caret" : temporal ? "temporal" : (appearance ? "appearance" : (pixels ? "pixels" : "different"))
        }
        var reasons: [String] = []
        if let change = check["screenChange"] as? Double, let limit = check["maxScreenChange"] as? Double, change > limit {
            reasons.append("screen_changed")
        }
        if !caret && !temporal && !appearance {
            if check["fieldPixelsMatch"] as? Bool == false { reasons.append("field_changed") }
            if let regions = check["regionChanges"] as? [Double], let limit = check["maxRegionChange"] as? Double,
               regions.contains(where: { $0 > limit }) { reasons.append("protected_region_changed") }
        }
        result["mismatches"] = reasons
        return result
    }
}
