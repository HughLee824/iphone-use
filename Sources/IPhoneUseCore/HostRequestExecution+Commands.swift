import Foundation

extension HostRequestExecution {
    func status() throws {
        var status = try backend.status()
        status.merge(config.modeSelection.result) { _, selected in selected }
        status["support"] = config.modeSelection.mode.support
        status["touchPaste"] = touchPaste.status
        status["textMethodSelection"] = config.modeSelection.mode.support["textMethods"]
        status["textFinishSupported"] = true
        response["result"] = status
    }

    func apps() throws {
        response["result"] = try backend.apps().page(
            query: request["query"] as? String, offset: validatedValue(request["offset"], as: Int.self))
        effective = true
    }

    func open() throws {
        previousObservation = observations.beginAction()
        response["result"] = try backend.open(bundle: validatedValue(request["bundleId"], as: String.self))
        observations.finishAction(previous: previousObservation, dispatched: true)
        response["outcome"] = "completed"
    }

    func appLifecycle() throws {
        previousObservation = observations.beginAction()
        response["result"] = try backend.appLifecycle(
            bundle: validatedValue(request["bundleId"], as: String.self), relaunch: operation == "relaunch")
        observations.finishAction(previous: previousObservation, dispatched: true)
        response["outcome"] = "completed"
        response["requiresObservation"] = true
    }

    func observe() throws {
        observations.invalidate("superseded")
        response["result"] = try observations.store(backend.observe())
        effective = true
    }

    func inspect() throws {
        response["result"] = try observations.inspect(
            reference!, offset: validatedValue(request["offset"], as: Int.self),
            query: request["query"] as? String)
        effective = true
    }

    func preview() throws {
        observations.invalidate("preview_changed")
        response["requiresObservation"] = true
        response["result"] =
            try operation == "preview-start"
            ? backend.startPreview(options: previewOptions) : backend.stopPreview()
        effective = true
    }

    func startRecording() throws {
        observations.invalidate("recording_started")
        response["requiresObservation"] = true
        response["result"] = try backend.startRecording(duration: NativeRecordingOptions.duration(request))
        effective = true
    }

    func stopRecording() throws {
        observations.invalidate("recording_stopped")
        response["requiresObservation"] = true
        let result = try backend.stopRecording(id: validatedValue(request["recordingID"], as: String.self))
        response["result"] = result
        response["ok"] = result["state"] as? String == "completed"
        if response["ok"] as? Bool != true {
            response["error"] =
                result["error"] ?? [
                    "code": "recording_incomplete",
                    "message": "Recording has not completed; inspect status. Do not restart automatically."
                ]
        }
        effective = true
    }
}
