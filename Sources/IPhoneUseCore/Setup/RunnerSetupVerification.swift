import Foundation

struct RunnerSetupProgress {
    let onProgress: (([String: Any]) -> Void)?

    func emit(_ phase: String, _ message: String, session: String? = nil) {
        var event: [String: Any] = [
            "event": "setup_progress", "phase": phase, "message": message, "requiresUserAction": false
        ]
        if let session { event["session"] = session }
        onProgress?(event)
    }
}

// Uses the ordinary session path, including authorization, early video and
// owned-session teardown. Dependencies permit testing without signing or a phone.
struct RunnerSetupVerification {
    typealias Connect = (String, URL, Int?, (([String: Any]) -> Void)?) throws -> [String: Any]
    var connect: Connect = { device, manifest, port, progress in
        try SessionClient.connect(
            device: device, xctestrun: manifest, idleTimeout: IdleTimeout("3m"),
            previewPort: port, previewOptional: true, onProgress: progress)
    }
    var call: (String, String) throws -> [String: Any] = { session, operation in
        try SessionClient.call(session: session, operation: operation)
    }

    func run(device: String, products: URL, previewPort: Int?, progress: RunnerSetupProgress) throws -> [String: Any] {
        progress.emit("verifying", "Starting verification; complete any Enable UI Automation prompt on the iPhone.")
        var previewURL: String?
        var previewError: String?
        let connection = try connect(
            device, products.appendingPathComponent("Runner.xctestrun"), previewPort
        ) { event in
            if let url = event["previewURL"] as? String { previewURL = url }
            if let error = event["previewError"] as? String { previewError = error }
            progress.onProgress?(event)
        }
        guard let session = connection["session"] as? String else {
            throw IPhoneUseError("setup_verification_failed", "Connection did not return a session")
        }
        // A fast startup may reach ready between progress-file polls. Preserve
        // the actual preview facts from the final connection status as well.
        if let result = connection["result"] as? [String: Any], let preview = result["preview"] as? [String: Any] {
            previewURL = preview["url"] as? String ?? previewURL
            previewError = preview["error"] as? String ?? previewError
        }
        progress.emit("observing", "Verifying a fresh Runner observation.", session: session)
        var observationError: Error?
        do {
            let observation = try call(session, "observe")
            if observation["ok"] as? Bool != true {
                throw IPhoneUseError(
                    "setup_verification_failed",
                    "Runner observation failed in session \(session): "
                        + String(describing: observation["error"] ?? "no diagnostic returned"))
            }
        } catch { observationError = error }
        progress.emit("disconnecting", "Closing the verification session and its video source.", session: session)
        // Send cleanup once, even after observation failure. An uncertain
        // disconnect must not be replayed or reported as successful setup.
        let cleanup: [String: Any]
        do { cleanup = try call(session, "disconnect") } catch {
            throw cleanupError(session: session, detail: String(describing: error), observationError: observationError)
        }
        guard cleanup["ok"] as? Bool == true else {
            throw cleanupError(session: session, detail: String(describing: cleanup["error"] ?? "unconfirmed cleanup"),
                               observationError: observationError)
        }
        if let observationError { throw observationError }
        return [
            "verificationSession": session, "verified": ["connection", "observation-capture", "disconnect"],
            "preview": [
                "state": previewPort == nil ? "disabled" : "stopped",
                "url": previewURL as Any? ?? NSNull(), "error": previewError as Any? ?? NSNull()
            ],
            "cleanup": cleanup["result"] as Any? ?? NSNull()
        ]
    }

    private func cleanupError(session: String, detail: String, observationError: Error?) -> IPhoneUseError {
        IPhoneUseError(
            "setup_cleanup_failed",
            "Verification session \(session) did not close cleanly: \(detail)."
                + (observationError.map { " Observation also failed: \($0)" } ?? ""))
    }
}
