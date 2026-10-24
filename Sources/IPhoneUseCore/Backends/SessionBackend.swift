import IPhoneUseRunnerSupport
import Foundation

// The host depends on these few operations, not XCTest objects or an agent-facing Runner protocol.
protocol SessionBackend: AnyObject {
    func setEventDeliveryQueue(_ queue: DispatchQueue)
    func start() throws -> [String: Any]
    func status() throws -> [String: Any]
    func apps() throws -> AppCatalog
    func open(bundle: String) throws -> [String: Any]
    func appLifecycle(bundle: String, relaunch: Bool) throws -> [String: Any]
    func observe() throws -> CapturedObservation
    func observeText(_ options: NativeTextObservationOptions) throws -> CapturedObservation
    func observeAfterAction(
        textOptions: NativeTextObservationOptions?, ignoring: ScreenRect?, sourceContext: ScreenContext?
    ) throws -> CapturedObservation
    func perform(_ action: DeviceAction, target: ObservedTarget, onInputStarted: @escaping () -> Void) throws
        -> [String: Any]
    func stop() -> [String: Any]
    func cancelCurrent()
    func finishText(transaction: String, observation: [String: Any]) throws -> [String: Any]
    func prepareText() throws -> [String: Any]
    func startRecording(duration: Double) throws -> [String: Any]
    func stopRecording(id: String) throws -> [String: Any]
    func startPreview(options: NativePreviewOptions) throws -> [String: Any]
    func stopPreview() throws -> [String: Any]
    func previewTick() -> Bool
    func showPreviewGesture(_ gesture: NativePreviewGesture)
    var previewGestureRotation: String? { get }
}

extension SessionBackend {
    func showPreviewGesture(_ gesture: NativePreviewGesture) {}
    var previewGestureRotation: String? { nil }
    func startPreview(options: NativePreviewOptions = NativePreviewOptions()) throws -> [String: Any] {
        throw IPhoneUseError("preview_unsupported", "Preview is unavailable")
    }
    func stopPreview() throws -> [String: Any] { ["state": "stopped"] }
    func previewTick() -> Bool { false }
    func setEventDeliveryQueue(_ queue: DispatchQueue) {}
    func observeAfterAction(
        textOptions: NativeTextObservationOptions?, ignoring: ScreenRect?, sourceContext: ScreenContext?
    ) throws -> CapturedObservation {
        throw IPhoneUseError(
            "native_action_unsupported", "Post-action native stability is unavailable in this backend")
    }
    func observeText(_ options: NativeTextObservationOptions) throws -> CapturedObservation {
        throw IPhoneUseError(
            "native_action_unsupported", "Scoped text observations are unavailable in this backend")
    }
    func appLifecycle(bundle: String, relaunch: Bool) throws -> [String: Any] {
        throw IPhoneUseError(
            "native_action_unsupported", "This backend does not implement terminate/relaunch")
    }
    func cancelCurrent() {}
    func startRecording(duration: Double) throws -> [String: Any] {
        throw IPhoneUseError("native_action_unsupported", "This backend does not implement recording")
    }
    func stopRecording(id: String) throws -> [String: Any] {
        throw IPhoneUseError("native_action_unsupported", "This backend does not implement recording")
    }
    func prepareText() throws -> [String: Any] {
        throw IPhoneUseError("native_action_unsupported", "text-prepare applies only to apple-native")
    }
    func finishText(transaction: String, observation: [String: Any]) throws -> [String: Any] {
        throw IPhoneUseError("native_action_unsupported", "text-finish applies only to apple-native")
    }
}
