import XCTest
@testable import IPhoneUseCore

final class RunnerRecordingSourceStub: NativeRecordingSource {
    var attached = false
    var clockConfirmed = true
    var healthy = true
    func recordingConfiguration() -> [String: Any] {
        var config: [String: Any] = ["RxPayloadType": 100, "TilesPerFrame": 1, "SRTPCipherSuite": 0]
        if clockConfirmed { config["RTPClockRate"] = Int32(24000) }
        return config
    }
    func setVideoHandler(_ handler: ((Data) -> Void)?) { attached = handler != nil }
    func requestKeyframe() {}
    func health() -> [String: Any] { ["healthy": healthy] }
}

final class RunnerRecordingConnectionStub: RunnerRecordingConnection {
    let receiver = RunnerRecordingSourceStub()
    var source: NativeRecordingSource { receiver }
    let sessionID = UUID().uuidString
    var rotation = "rot0"
    var refreshedRotation: String?
    var closed = 0
    var changed = false
    var acknowledged = true
    var previewDevice = NativePreviewDevice(productType: "iPhone13,3", name: "iPhone 12 Pro")
    var previewRefreshes = 0
    var failRefresh = false
    var pollError: Error?
    var refreshError: Error?
    var onPoll: (() -> Void)?
    func previewNeedsRefresh() throws -> Bool {
        onPoll?()
        if let pollError { throw pollError }
        return changed
    }
    func refreshPreview() throws {
        previewRefreshes += 1
        if let refreshError { throw refreshError }
        if failRefresh { throw TransportError(description: "Lost scoped refresh reply", possiblySent: true) }
        if let refreshedRotation { rotation = refreshedRotation }
        changed = false
    }
    lazy var previewVideo = try? NativeRTPReceiver(deviceAddress: "::1", captureSnapshots: true)
    var previewReceiver: NativeRTPReceiver? { previewVideo }
    var previewDisplay: NativeDisplay? {
        try? NativeDisplay([
            "backlightState": "activeOn",
            "displays": [
                [
                    "primary": true, "displayId": 1,
                    "bounds": [[0, 0], [32, 48]], "pointScale": 1,
                    "currentOrientation": rotation, "nativeOrientation": "rot0"
                ]
            ]
        ])
    }
    func verifyDisplay() throws { if changed { throw IPhoneUseError("display_changed", "Fixture rotated") } }
    func close() -> [String: Any] {
        closed += 1
        return [
            "mediaStopAcknowledged": acknowledged, "tunnelReleaseAcknowledged": true,
            "mediaSessionID": sessionID
        ]
    }
}

final class RunnerRecordingTests: XCTestCase {

    func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "runner-recording-\(UUID().uuidString)")
        try SessionPaths.secureDirectory(root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

}
