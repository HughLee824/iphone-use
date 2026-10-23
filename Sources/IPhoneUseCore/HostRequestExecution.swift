import Foundation

// Accessed only while holding SessionHost's serial device work queue.
final class HostRequestExecution {
    let host: SessionHost
    let admission: HostRequest
    var response: [String: Any]
    var previousObservation: String?
    var effective: Bool
    var textObservationOptions: NativeTextObservationOptions?
    var postActionSourceContext: ScreenContext?

    var request: [String: Any] { admission.request }
    var id: String { admission.id }
    var operation: String { admission.operation }
    var appAction: Bool { admission.appAction }
    var reference: ObservationReference? { admission.reference }
    var action: DeviceAction? { admission.action }
    var previewOptions: NativePreviewOptions { admission.previewOptions }
    var config: HostConfiguration { host.config }
    var backend: SessionBackend { host.backend }
    var observations: ObservationCache { host.observations }
    var touchPaste: TouchPasteSession { host.touchPaste }
    var paths: SessionPaths { host.paths }

    init(host: SessionHost, admission: HostRequest) {
        self.host = host
        self.admission = admission
        response = ["id": admission.id, "session": host.config.session, "ok": true]
        effective = admission.appAction
        textObservationOptions = admission.textObservationOptions
    }

    func run() {
        do {
            try checkPendingPaste()
            try dispatch()
        } catch {
            recordFailure(error)
        }
        captureAfterAction()
        enrichRecovery()
        recordEvent()
    }

    func checkPendingPaste() throws {
        if touchPaste.pending,
            appAction || operation == "text-prepare" || operation == "type" || operation == "press" {
            throw IPhoneUseError(
                "touch_paste_pending",
                "Inspect the pending touch-paste transaction and text-finish before another text or app action"
            )
        }
        if touchPaste.pending, ["tap", "double-tap", "long-press"].contains(operation) {
            try touchPaste.checkOwnership()
        }
    }
    private func dispatch() throws {
        let handlers: [String: () throws -> Void] = [
            "status": status,
            "apps": apps,
            "open": open,
            "terminate": appLifecycle,
            "relaunch": appLifecycle,
            "observe": observe,
            "inspect": inspect,
            "preview-start": preview,
            "preview-stop": preview,
            "record-start": startRecording,
            "record-stop": stopRecording,
            "text-prepare": prepareText,
            "text-finish": finishText,
            "tap": performAction,
            "double-tap": performAction,
            "long-press": performAction,
            "pinch": performAction,
            "swipe": performAction,
            "home": performAction,
            "type": performAction,
            "press": performAction
        ]
        try handlers[operation]?()
    }
}
