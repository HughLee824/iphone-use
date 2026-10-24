import Foundation

extension HostRequestExecution {
    func recordFailure(_ error: Error) {
        response["ok"] = false
        let failure = error as? ActionFailure
        if let result = failure?.result { response["result"] = result }
        let uncertain = failure?.possiblyExecuted ?? (error as? TransportError)?.possiblySent ?? false
        if ["record-start", "record-stop", "preview-start", "preview-stop"].contains(operation) {
            response["outcome"] = uncertain ? "unknown" : "not_dispatched"
        }
        if appAction || action != nil || operation == "text-finish" || operation == "text-prepare" {
            observations.finishAction(previous: previousObservation, dispatched: uncertain)
            if failure?.requiresObservation == true { observations.invalidate("target_changed") }
            response["outcome"] = uncertain ? "unknown" : "not_dispatched"
            response["requiresObservation"] =
                uncertain || failure?.requiresObservation == true
                || (error as? IPhoneUseError)?.code == "stale_reference"
        }
        if config.backend == "apple-native", !uncertain, let capture = failure?.rejectedCapture {
            // Keep the exact valid frame that rejected input, not a later recapture.
            // It is a new observation, never evidence of a dispatched action.
            do {
                let rejected = try observations.store(capture)
                response["observation"] = ["ok": true, "phase": "pre_input_rejection", "result": rejected]
                var result = response["result"] as? [String: Any] ?? [:]
                result["rejectedObservationID"] = rejected["observation"]
                response["result"] = result
            } catch {
                response["observation"] = [
                    "ok": false, "phase": "pre_input_rejection", "error": String(describing: error)
                ]
            }
        }
        if operation == "status" { observations.invalidate("backend_unavailable") }
        response["error"] = [
            "code": failure?.code ?? (error as? IPhoneUseError)?.code ?? "backend_error",
            "message": String(describing: error)
        ]
        if let diagnostics = (error as? IPhoneUseError)?.diagnostics, !diagnostics.isEmpty {
            response["diagnostics"] = diagnostics
        }
    }

    func enrichRecovery() {
        if config.backend == "apple-native",
            appAction || action != nil || operation == "text-prepare"
                || (operation == "observe" && response["ok"] as? Bool == false) {
            NativeRecovery.enrich(&response, control: try? backend.status())
        }
    }

    func recordEvent() {
        if config.backend == "apple-native",
            appAction || action != nil || operation == "text-finish" || operation == "text-prepare" {
            var result = response["result"] as? [String: Any] ?? [:]
            result["actionID"] = id
            result["sourceObservationID"] = action?.reference.observation ?? reference?.observation
            response["result"] = result
            do {
                let eventURL = paths.directory.appendingPathComponent("native-events.jsonl")
                if !FileManager.default.fileExists(atPath: eventURL.path) {
                    FileManager.default.createFile(
                        atPath: eventURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
                }
                let file = try FileHandle(forWritingTo: eventURL)
                defer { try? file.close() }
                try file.seekToEnd()
                var data = try jsonData([
                    "request": request, "response": response, "hostRecordedAt": Date().timeIntervalSince1970
                ])
                data.append(10)
                try file.write(contentsOf: data)
            } catch { response["eventRecordingError"] = String(describing: error) }
        }
    }
}
