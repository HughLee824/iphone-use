import Foundation

extension HostRequestExecution {
    func captureAfterAction() {
        // Native actions always return a new observation while still holding the device
        // work queue. Capture failure preserves the action's execution facts.
        if config.backend == "apple-native" || action?.touchPaste == true,
            appAction || action != nil || operation == "text-finish" || operation == "text-prepare",
            response["outcome"] as? String != "not_dispatched" {
            observations.invalidate("post_action_capture")
            do {
                let capture: CapturedObservation
                if operation == "text-finish" || action?.touchPaste == true {
                    capture =
                        try textObservationOptions.map { try backend.observeText($0) } ?? backend.observe()
                } else {
                    capture = try backend.observeAfterAction(
                        textOptions: textObservationOptions,
                        ignoring: action?.ignoredScreenRect ?? textObservationOptions?.ignoring,
                        sourceContext: postActionSourceContext)
                }
                let after = try observations.store(capture)
                var observation: [String: Any] = ["ok": true, "result": after]
                if let stability = capture.metadata["postActionStability"] as? [String: Any] {
                    observation["stability"] = stability
                    if stability["stable"] as? Bool != true {
                        let reason = stability["reason"] as? String ?? "frame_stability_timeout"
                        observation["warning"] =
                            "\(reason): inspect the latest screenshot and capture diagnostics; do not replay input"
                    }
                }
                response["observation"] = observation
                var result = response["result"] as? [String: Any] ?? [:]
                result["afterObservationID"] = after["observation"]
                response["result"] = result
            } catch {
                recordCaptureFailure(error)
            }
        }
    }

    private func recordCaptureFailure(_ error: Error) {
        response["observation"] = ["ok": false, "error": String(describing: error)]
        if let failure = error as? IPhoneUseError {
            response["observation"] = [
                "ok": false, "error": failure.description,
                "errorCode": failure.code, "diagnostics": failure.diagnostics
            ]
        }
        if action?.touchPaste == true, response["outcome"] as? String == "prepared" {
            response["ok"] = false
            response["error"] = [
                "code": "touch_paste_observation_failed",
                "message":
                    "Clipboard staging completed but capture failed; observe before touching Paste. Do not stage again."
            ]
        }
        if operation == "text-prepare" {
            // Preparation completed, but there is no usable input baseline.
            response["ok"] = false
            response["error"] = [
                "code": "native_prepare_observation_failed",
                "message":
                    "Keyboard preparation completed but screenshot capture failed; observe before input: \(error)"
            ]
        }
    }
}
