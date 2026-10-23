import XCTest
import Foundation
import Network
@testable import IPhoneUseCore

final class ControlledBackend: SessionBackend {
    let opened = DispatchSemaphore(value: 0)
    let releaseOpen = DispatchSemaphore(value: 0)
    let stopped = DispatchSemaphore(value: 0)
    var lifecycleFailure: ActionFailure?
    private(set) var appLifecycleCount = 0
    var blockOpen = false
    var loseOpenResponse = false
    var rejectOpenBeforeSend = false
    private(set) var openCount = 0
    private(set) var stopCount = 0
    private(set) var observeCount = 0
    private(set) var appsCount = 0
    private(set) var actionCount = 0
    private(set) var inputCount = 0
    private(set) var previewGestures: [NativePreviewGesture] = []
    func showPreviewGesture(_ gesture: NativePreviewGesture) { previewGestures.append(gesture) }
    var liveScreen: Data?
    var actionFailure: ActionFailure?
    var blockAction = false
    var blockAfterInput = false
    let inputStarted = DispatchSemaphore(value: 0)
    var failObservation = false
    var observationFailure: IPhoneUseError?
    var nativeSend = false
    var nativeTextFixture = false
    var nativeCaretFixture = false
    var finishAcknowledged = true
    private(set) var finishCount = 0
    private(set) var prepareCount = 0
    private(set) var recordingStarts = 0
    private(set) var recordingStops = 0
    private(set) var lastTextMethod: String?
    private(set) var lastTextMode: String?
    let actionStarted = DispatchSemaphore(value: 0)
    let releaseAction = DispatchSemaphore(value: 0)
    var blockStart = false
    let startEntered = DispatchSemaphore(value: 0)
    let releaseStart = DispatchSemaphore(value: 0)
    func cancelCurrent() { releaseStart.signal() }

    func start() throws -> [String: Any] {
        if blockStart { startEntered.signal(); _ = releaseStart.wait(timeout: .now() + 5) }
        return ["runnerSession": "controlled-runner", "runnerPid": 123]
    }
    var statusInfo: [String: Any]?
    func status() throws -> [String: Any] { try statusInfo ?? start() }
    func apps() throws -> AppCatalog {
        appsCount += 1
        return try AppCatalog(["apps": [["bundleIdentifier": "com.example.fixture", "name": "Fixture"]]])
    }
    func open(bundle: String) throws -> [String: Any] {
        if rejectOpenBeforeSend { throw TransportError(description: "Not connected", possiblySent: false) }
        openCount += 1
        opened.signal()
        if blockOpen { _ = releaseOpen.wait(timeout: .now() + 5) }
        if loseOpenResponse { throw TransportError(description: "Lost response", possiblySent: true) }
        return ["bundleId": bundle]
    }
    func appLifecycle(bundle: String, relaunch: Bool) throws -> [String: Any] {
        appLifecycleCount += 1
        if let lifecycleFailure { throw lifecycleFailure }
        return [
            "oldProcessAbsentConfirmed": true, "newProcessObserved": relaunch, "foregroundConfirmed": false
        ]
    }
    func stop() -> [String: Any] {
        stopCount += 1
        stopped.signal()
        return ["shutdownAcknowledged": true, "backendStopped": true, "runnerProcessExited": true]
    }
    func observe() throws -> CapturedObservation {
        observeCount += 1
        if let observationFailure { throw observationFailure }
        if failObservation { throw IPhoneUseError("capture_failed", "Fixture capture failure") }
        if nativeTextFixture {
            return CapturedObservation(
                nodes: [],
                metadata: [
                    "backend": "apple-native",
                    "screenContext": try jsonObject(JSONEncoder().encode(screenTestContext()))
                ],
                screenshot: try screenPNG(
                    patches: nativeCaretFixture
                        ? [(CGRect(x: 50, y: 150, width: 2, height: 20), [7, 193, 96])] : []))
        }
        return try observationFixture()
    }
    private(set) var textObservationCount = 0
    var postActionStable = true
    private(set) var postActionObserveCount = 0
    func observeAfterAction(
        textOptions: NativeTextObservationOptions?, ignoring: ScreenRect?, sourceContext: ScreenContext?
    ) throws -> CapturedObservation {
        postActionObserveCount += 1
        let frame = try textOptions.map { try observeText($0) } ?? observe()
        var metadata = frame.metadata
        metadata["postActionStability"] = [
            "stable": postActionStable, "reason": postActionStable ? "stable" : "frame_stability_timeout"
        ]
        return CapturedObservation(nodes: frame.nodes, metadata: metadata, screenshot: frame.screenshot)
    }
    func observeText(_ options: NativeTextObservationOptions) throws -> CapturedObservation {
        textObservationCount += 1
        let captured = try observe()
        var metadata = captured.metadata
        metadata["textObservationOptions"] = try options.result
        return CapturedObservation(nodes: captured.nodes, metadata: metadata, screenshot: captured.screenshot)
    }
    func finishText(transaction: String, observation: [String: Any]) throws -> [String: Any] {
        finishCount += 1
        return ["pasteboardRestoreAcknowledged": finishAcknowledged, "transactionID": transaction]
    }
    private(set) var previewStarts: [NativePreviewOptions] = []
    func startPreview(options: NativePreviewOptions = NativePreviewOptions()) throws -> [String: Any] {
        previewStarts.append(options)
        return ["state": "waiting", "url": "http://127.0.0.1:\(options.port)/token/"]
    }
    func stopPreview() throws -> [String: Any] { ["state": "stopped"] }
    func startRecording(duration: Double) throws -> [String: Any] {
        recordingStarts += 1
        return ["state": "starting_or_recording", "recordingID": "00000000-0000-0000-0000-000000000001"]
    }
    func stopRecording(id: String) throws -> [String: Any] {
        recordingStops += 1
        return ["state": "completed", "recordingID": id, "fileValidated": true]
    }
    func prepareText() throws -> [String: Any] {
        prepareCount += 1
        return ["keyboardPrepared": true, "inputReportsSent": 0]
    }
    func perform(_ action: DeviceAction, target: ObservedTarget, onInputStarted: @escaping () -> Void) throws
        -> [String: Any] {
        lastTextMethod = action.fields["textMethod"] as? String
        lastTextMode = action.fields["mode"] as? String
        actionCount += 1
        actionStarted.signal()
        if blockAction { _ = releaseAction.wait(timeout: .now() + 5) }
        if let actionFailure { throw actionFailure }
        if let liveScreen, let gesture = target.gesture {
            let check = try gesture.screenGuard.check(png: liveScreen, context: gesture.screenGuard.context)
            if !check.accepted {
                throw ActionFailure(
                    code: "screen_changed", description: "Screen changed", possiblyExecuted: false,
                    requiresObservation: true, result: ["screenGuard": check.result])
            }
        }
        inputCount += 1
        onInputStarted()
        inputStarted.signal()
        if blockAfterInput { _ = releaseAction.wait(timeout: .now() + 5) }
        return nativeSend
            ? ["kind": action.kind, "transportStatus": "sent", "verificationStatus": "not_checked"]
            : ["kind": action.kind]
    }
}

final class HostTests: XCTestCase {

    struct RunningHost {
        let paths: SessionPaths
        let session: String
        let finished: XCTestExpectation
    }

    func host(
        timeout: Double, backend: ControlledBackend, native: Bool = false,
        touchPaste: TouchPasteSession? = nil
    ) throws -> RunningHost {
        let directory = URL(fileURLWithPath: "/private/tmp/as-test-\(UUID().uuidString.prefix(8))")
        try SessionPaths.secureDirectory(directory)
        let paths = SessionPaths(directory: directory)
        let session = "test-session"
        let config = HostConfiguration(
            session: session, device: "test", xctestrun: "/unused", idleTimeoutSeconds: timeout,
            backend: native ? "apple-native" : nil)
        let host = SessionHost(config: config, paths: paths, backend: backend, touchPaste: touchPaste)
        let finished = expectation(description: "host exited")
        DispatchQueue.global().async {
            do { try host.run() } catch { XCTFail("Host failed: \(error)") }
            finished.fulfill()
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        if backend.blockStart {
            XCTAssertEqual(backend.startEntered.wait(timeout: .now() + 2), .success)
            return RunningHost(paths: paths, session: session, finished: finished)
        }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let response = try? call(paths, session: session, op: "status"),
                response["ok"] as? Bool == true {
                return RunningHost(paths: paths, session: session, finished: finished)
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw IPhoneUseError("test_start_timeout", "Test host never became ready")
    }

    func call(_ paths: SessionPaths, session: String, op operation: String, fields: [String: Any] = [:])
        throws
        -> [String: Any] {
        var request = fields
        request["version"] = 1
        request["id"] = UUID().uuidString
        request["session"] = session
        request["op"] = operation
        return try JSONTransport.exchange(endpoint: .unix(path: paths.socket), request: request, timeout: 5)
    }
}
