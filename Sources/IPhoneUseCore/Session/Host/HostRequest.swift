import Foundation

final class HostRequest {
    let request: [String: Any]
    let config: HostConfiguration
    let reply: JSONServer.Reply
    let id: String
    let requestedOperation: String
    let operation: String
    let appLifecycle: Bool
    let appAction: Bool
    var previewOptions = NativePreviewOptions()
    var reference: ObservationReference?
    var action: DeviceAction?
    var textObservationOptions: NativeTextObservationOptions?

    init(_ request: [String: Any], config: HostConfiguration, reply originalReply: @escaping JSONServer.Reply) {
        self.request = request
        self.config = config
        // Session identity comes from the immutable host configuration, never current user defaults.
        reply = { [config] response, completion in
            var response = response
            response.merge(config.modeSelection.result) { _, selected in selected }
            originalReply(response, completion)
        }
        id = request["id"] as? String ?? ""
        requestedOperation = request["op"] as? String ?? ""
        operation =
            ["type-with-method", "type-with-caret"].contains(requestedOperation)
            ? "type"
            : requestedOperation == "press-with-caret"
                ? "press" : requestedOperation == "text-prepare-scoped" ? "text-prepare" : requestedOperation
        appLifecycle = operation == "terminate" || operation == "relaunch"
        appAction = operation == "open" || appLifecycle
    }

    func validate() -> Bool {
        validateIdentity() && validateApp() && validateAppQuery() && validateRecording()
            && validatePreview() && validateTextBackend() && validateTextScope() && validateTextMethod()
            && validateTextFinish() && validateAction() && validateInspection()
    }

    func reject(_ code: String, _ message: String) {
        var response: [String: Any] = [
            "id": id, "session": config.session, "ok": false,
            "outcome": "not_dispatched", "error": ["code": code, "message": message]
        ]
        if config.backend == "apple-native", code == "session_closed" {
            NativeRecovery.enrich(&response, control: nil)
        }
        reply(response, {})
    }

    func validateIdentity() -> Bool {
        guard request["version"] as? Int == 1, request["session"] as? String == config.session,
            !id.isEmpty,
            ([
                "status", "apps", "open", "terminate", "relaunch", "observe", "inspect", "disconnect",
                "text-finish",
                "text-prepare", "record-start", "record-stop", "preview-start", "preview-stop"
            ] + DeviceAction.operations).contains(operation)
        else {
            reject("invalid_request", "Invalid session request")
            return false
        }
        return true
    }
    func validateApp() -> Bool {
        if appAction {
            guard let bundle = request["bundleId"] as? String,
                bundle.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]{0,254}\\z", options: .regularExpression) != nil
            else {
                reject("invalid_bundle_id", "A bundle identifier is required")
                return false
            }
        }
        return true
    }
    func validateAppQuery() -> Bool {
        if operation == "apps" {
            guard let offset = request["offset"] as? Int, offset >= 0,
                request["query"] == nil || request["query"] is String
            else {
                reject("invalid_app_query", "Use a text query and a nonnegative offset")
                return false
            }
        }
        return true
    }
    func validateRecording() -> Bool {
        if operation == "record-start" || operation == "record-stop" {
            do {
                if operation == "record-start" {
                    _ = try NativeRecordingOptions.duration(request)
                } else if UUID(uuidString: request["recordingID"] as? String ?? "") == nil {
                    throw IPhoneUseError(
                        "invalid_recording_id", "Use the recording ID returned by record-start or status")
                }
            } catch {
                reject((error as? IPhoneUseError)?.code ?? "invalid_request", String(describing: error))
                return false
            }
        }
        return true
    }
    func validatePreview() -> Bool {
        if operation == "preview-start" {
            do { previewOptions = try NativePreviewOptions(request: request) } catch {
                reject((error as? IPhoneUseError)?.code ?? "invalid_request", String(describing: error))
                return false
            }
        }
        return true
    }
}
