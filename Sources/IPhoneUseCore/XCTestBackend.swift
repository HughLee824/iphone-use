import Foundation
import Network
import Darwin

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
    func observeAfterAction(textOptions: NativeTextObservationOptions?, ignoring: ScreenRect?, sourceContext: ScreenContext?) throws -> CapturedObservation
    func perform(_ action: DeviceAction, target: ObservedTarget, onInputStarted: @escaping () -> Void) throws -> [String: Any]
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
    func startPreview(options: NativePreviewOptions = NativePreviewOptions()) throws -> [String: Any] { throw IPhoneUseError("preview_unsupported", "Preview is unavailable") }
    func stopPreview() throws -> [String: Any] { ["state": "stopped"] }
    func previewTick() -> Bool { false }
    func setEventDeliveryQueue(_ queue: DispatchQueue) {}
    func observeAfterAction(textOptions: NativeTextObservationOptions?, ignoring: ScreenRect?, sourceContext: ScreenContext?) throws -> CapturedObservation {
        throw IPhoneUseError("native_action_unsupported", "Post-action native stability is unavailable in this backend")
    }
    func observeText(_ options: NativeTextObservationOptions) throws -> CapturedObservation {
        throw IPhoneUseError("native_action_unsupported", "Scoped text observations are unavailable in this backend")
    }
    func appLifecycle(bundle: String, relaunch: Bool) throws -> [String: Any] {
        throw IPhoneUseError("native_action_unsupported", "This backend does not implement terminate/relaunch")
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

final class XCTestBackend: SessionBackend {
    private let config: HostConfiguration
    private let paths: SessionPaths
    private var runner: StandaloneRunner?
    private var transport: RunnerUSBTransport?
    private var deviceLock: SessionDeviceLock?
    private let token = UUID().uuidString + UUID().uuidString
    private var identity: String?
    private var runnerPID: Int?
    private var deviceUDID: String?
    private let recordingCancellation = NativeCancellation()
    private var recording: RunnerNativeRecording?
    private var recordingPlatformSupported = false
    private let authorization: RunnerAuthorization

    init(config: HostConfiguration, paths: SessionPaths) {
        self.config = config
        self.paths = paths
        authorization = RunnerAuthorization(directory: paths.directory)
    }

    func start() throws -> [String: Any] {
        do { return try startRunner() }
        catch { authorization.failed(String(describing: error)); throw error }
    }

    private func startRunner() throws -> [String: Any] {
        let details = try deviceInfo("details")
        guard let hardware = details["hardwareProperties"] as? [String: Any],
              let udid = hardware["udid"] as? String else {
            throw IPhoneUseError("coredevice_unavailable", "CoreDevice did not identify the selected iPhone")
        }
        deviceLock = try SessionDeviceLock(root: paths.directory.deletingLastPathComponent(), device: udid)
        deviceUDID = udid
        let lockState = try deviceInfo("lockState")
        if lockState["passcodeRequired"] as? Bool == true {
            throw IPhoneUseError("device_locked", "Unlock the iPhone and connect again")
        }
        recordingPlatformSupported = ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27 &&
            ((details["deviceProperties"] as? [String: Any])?["osVersionNumber"] as? String)?.hasPrefix("27.") == true
        recording = RunnerNativeRecording(device: udid, root: paths.directory.appendingPathComponent("recordings"),
                                          cancellation: recordingCancellation, previewDevice: NativePreviewDevice(details: details),
                                          previewGeometry: { [weak self] in
            guard let self else { throw IPhoneUseError("backend_unavailable", "Runner is not connected") }
            return try Self.decodePreviewGeometry(self.request("preview-geometry", timeout: 3))
        })
        let transport = RunnerUSBTransport(device: udid)
        _ = try transport.requireUSB(deadline: ProcessInfo.processInfo.systemUptime + 5)
        self.transport = transport
        let bundle = try StandaloneRunner.bundleID(manifest: URL(fileURLWithPath: config.xctestrun))
        let runner = StandaloneRunner { arguments, tail, environment in
            try CoreDevice.read(arguments + ["--device", udid], trailingArguments: tail, timeout: 10,
                                launchEnvironment: environment)
        }
        self.runner = runner
        recording?.connectionStatus = { [authorization] in authorization.snapshot() }
        if let port = config.startupPreviewPort {
            let options = NativePreviewOptions(port: try PreviewConfiguration.validate(port: port), explicitPort: true)
            let preview = try recording?.reservePreview(options: options)
            if let url = preview?["url"] as? String { authorization.setPreviewURL(url) }
            // CoreDevice video does not need XCTest authorization. Start it
            // before launching Runner and keep this stream throughout startup.
            _ = try recording?.startPreview(options: options, duringStartup: true)
        }
        authorization.start(device: udid)
        try recordingCancellation.check()
        let launched = try runner.start(bundle: bundle, token: token)
        authorization.bind(runnerPID: launched.pid)
        try saveJSON(["device": udid, "bundleId": bundle, "runnerPid": launched.pid,
                      "executable": launched.executable.absoluteString, "transport": "usb-loopback",
                      "launch": "standalone-background", "installationPerformed": false],
                     to: paths.directory.appendingPathComponent("backend.json"))
        let deadline = ProcessInfo.processInfo.systemUptime + 90
        var nextProcessCheck = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime < deadline {
            try recordingCancellation.check()
            // Only startup health checks retry; launching and UI input never do.
            if let response = try? request("ping", timeout: 1), response["ok"] as? Bool == true,
               let result = response["result"] as? [String: Any] {
                guard let sessionID = response["sessionId"] as? String, UUID(uuidString: sessionID) != nil,
                      response["runnerPid"] as? Int == launched.pid else {
                    throw IPhoneUseError("invalid_runner_identity", "USB peer did not match the launched Runner")
                }
                identity = sessionID
                runnerPID = launched.pid
                try Self.validateCapabilities(result)
                guard result["applicationStateTimeoutSupported"] as? Bool == true else {
                    throw IPhoneUseError("unsupported_xctest_runtime", "This XCTest runtime cannot bound application-state waits")
                }
                authorization.ready()
                return metadata()
            }
            if ProcessInfo.processInfo.systemUptime >= nextProcessCheck {
                guard try runner.isRunning() else {
                    throw RunnerStartupDiagnostics.failure(processExited: true, authorization: authorization.snapshot())
                }
                nextProcessCheck = ProcessInfo.processInfo.systemUptime + 3
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw RunnerStartupDiagnostics.failure(processExited: false, authorization: authorization.snapshot())
    }

    private func deviceInfo(_ kind: String) throws -> [String: Any] {
        try CoreDevice.read(["device", "info", kind, "--device", config.device],
                            savingTo: paths.directory.appendingPathComponent("device-\(kind).json"))
    }

    private func metadata() -> [String: Any] {
        ["runnerSession": identity ?? "", "runnerPid": runnerPID ?? 0,
         "launch": "standalone-background", "transport": "usb-loopback", "installationPerformed": false]
    }

    private func request(_ operation: String, fields: [String: Any] = [:], timeout: TimeInterval = 45, onInputStarted: (() -> Void)? = nil) throws -> [String: Any] {
        guard let transport else { throw IPhoneUseError("backend_unavailable", "Runner is not connected") }
        var request = fields
        request["id"] = UUID().uuidString
        request["token"] = token
        request["op"] = operation
        if onInputStarted != nil { request["inputProgress"] = true }
        let response = try transport.exchange(request, timeout: timeout, onProgress: onInputStarted.map { callback in
            { [identity] progress in
                guard progress["sessionId"] as? String == identity else {
                    throw IPhoneUseError("runner_session_changed", "Runner session changed during input dispatch")
                }
                callback()
            }
        })
        if let identity, response["sessionId"] as? String != identity {
            throw TransportError(description: "Runner session changed; reconnect and observe", possiblySent: true)
        }
        return response
    }

    func status() throws -> [String: Any] {
        let response = try request("ping", timeout: 3)
        guard response["ok"] as? Bool == true else {
            throw IPhoneUseError("runner_unavailable", "Runner health check failed")
        }
        var result = metadata()
        result["sequence"] = response["sequence"]
        let recordingStatus = recording?.status() ?? ["state": "idle"]
        result["recording"] = recordingStatus
        result["preview"] = recording?.previewStatus ?? ["state": "stopped"]
        result["connection"] = authorization.snapshot()
        result["recordingSupport"] = ["supported": recordingPlatformSupported, "method": "native_rtp", "source": "owned_native_rtp", "codec": "hevc",
                                      "connectionPolicy": "on_explicit_record_or_preview_start", "hidServiceOpened": false,
                                      "availability": !recordingPlatformSupported ? "unsupported_platform" :
                                        (recordingStatus["reconnectRequired"] as? Bool == true ? "reconnect_required" :
                                         (recordingStatus["mediaConnectionOpen"] as? Bool == true ? "prepared" : "not_checked"))]
        return result
    }

    func open(bundle: String) throws -> [String: Any] {
        defer { recording?.checkDisplay() }
        try apps().requireInstalled(bundle)
        let response = try request("launch", fields: ["bundleId": bundle])
        return try ActionReply.decode(response)
    }

    func appLifecycle(bundle: String, relaunch: Bool) throws -> [String: Any] {
        defer { recording?.checkDisplay() }
        try apps().requireInstalled(bundle)
        let response = try request("app-lifecycle", fields: ["bundleId": bundle, "relaunch": relaunch])
        return try Self.lifecycleResponse(response, bundle: bundle, relaunch: relaunch)
    }

    static func lifecycleResponse(_ response: [String: Any], bundle: String, relaunch: Bool) throws -> [String: Any] {
        let facts = response["result"] as? [String: Any] ?? [:]
        let execution = response["execution"] as? [String: Any] ?? [:]
        guard response["ok"] as? Bool == true else {
            var failure = response; var result = facts; result["execution"] = execution; failure["result"] = result
            return try ActionReply.decode(failure)
        }
        // An already-stopped terminate is a verified no-op, with started=false.
        // Do not manufacture an input event merely to satisfy ActionReply.
        let alreadyStopped = facts["alreadyStopped"] as? Bool
        let expectedMutation = relaunch || alreadyStopped == false
        guard execution["started"] as? Bool == expectedMutation, execution["completed"] as? Bool == true,
              alreadyStopped != nil, facts["bundleId"] as? String == bundle,
              facts["operation"] as? String == (relaunch ? "relaunch" : "terminate"),
              facts["stoppedConfirmed"] as? Bool == true,
              facts["terminationRequested"] as? Bool == (alreadyStopped == false),
              facts["terminationAcknowledged"] as? Bool == (alreadyStopped == false),
              facts["launchRequested"] as? Bool == relaunch, facts["launchAcknowledged"] as? Bool == relaunch,
              facts["foregroundConfirmed"] as? Bool == relaunch,
              facts["appState"] as? Int == (relaunch ? 4 : 1) else {
            throw ActionFailure(code: "missing_app_lifecycle_facts", description: "Runner did not confirm the requested lifecycle transition; observe without replay",
                                possiblyExecuted: true, requiresObservation: true, result: facts)
        }
        var result = facts; result["execution"] = execution
        return result
    }

    func apps() throws -> AppCatalog {
        guard let deviceUDID else { throw IPhoneUseError("backend_unavailable", "Device is not connected") }
        return try AppCatalog(CoreDevice.read(["device", "info", "apps", "--device", deviceUDID, "--include-all-apps"]))
    }

    func perform(_ action: DeviceAction, target: ObservedTarget, onInputStarted: @escaping () -> Void) throws -> [String: Any] {
        recording?.checkDisplay()
        defer { recording?.checkDisplay() }
        let response = try request("act", fields: Self.actionFields(action, target: target),
                                   onInputStarted: target.gesture == nil ? nil : onInputStarted)
        return try ActionReply.decode(XCTestCapture.actionResponse(response, directory: paths.directory,
            expectedGuard: target.gesture?.screenGuard ?? target.textGuard, expectedMotion: target.gesture?.motion,
            expectedPinch: target.gesture?.pinch, expectedPressDuration: action.fields["duration"] as? Double, expectedHome: action.kind == "home",
            expectedKey: action.kind == "press" ? RunnerPressKey(rawValue: action.fields["key"] as? String ?? "") : nil))
    }

    static func validateCapabilities(_ result: [String: Any]) throws {
        let expected = ["observationVersion": 2, "actionVersion": 9, "launchVersion": 2, "frameStabilityVersion": 2, "screenGuardVersion": 1, "previewGeometryVersion": 2, "inputProgressVersion": 1]
        var differences = expected.keys.sorted().compactMap { key -> String? in
            let actual = result[key] as? Int
            return actual == expected[key] ? nil : "\(key): expected \(expected[key]!), received \(actual.map(String.init) ?? "missing")"
        }
        if result["lifecycleOwner"] as? String != "host" { differences.append("lifecycleOwner: expected host") }
        if !differences.isEmpty {
            throw IPhoneUseError("runner_needs_rebuild", "Runner is incompatible (\(differences.joined(separator: "; "))). Release users: install matching CLI/Runner resources and run setup. Source developers: run build-runner and use its new .xctestrun")
        }
    }

    static func decodePreviewGeometry(_ response: [String: Any]) throws -> RunnerPreviewGeometry {
        guard response["ok"] as? Bool == true, let result = response["result"] as? [String: Any],
              let width = result["width"] as? Int, let height = result["height"] as? Int,
              let orientation = result["orientation"] as? Int, [1, 3, 6, 8].contains(orientation),
              (1...16384).contains(width), (1...16384).contains(height) else {
            throw IPhoneUseError("preview_geometry_unavailable", "Runner did not return valid screenshot dimensions")
        }
        return RunnerPreviewGeometry(width: width, height: height, orientation: orientation)
    }

    static func actionFields(_ action: DeviceAction, target: ObservedTarget) throws -> [String: Any] {
        var fields: [String: Any]
        if action.kind == "home" {
            guard let screenGuard = target.textGuard else { throw IPhoneUseError("missing_screen_guard", "Home requires the current screenshot") }
            fields = ["kind": "home", "screenGuard": try jsonObject(JSONEncoder().encode(screenGuard))]
        } else if ["tap", "double-tap", "long-press", "pinch", "swipe"].contains(action.kind) {
            guard let gesture = target.gesture else { throw IPhoneUseError("missing_screen_guard", "Guarded coordinates are required") }
            try gesture.validate(kind: action.kind)
            fields = ["kind": action.kind, "gesture": try jsonObject(JSONEncoder().encode(gesture))]
            if action.kind == "long-press" { fields["duration"] = action.fields["duration"] }
        } else { fields = action.fields }
        fields["target"] = ["scope": target.context["scope"] ?? NSNull(),
            "bundleId": target.context["targetBundleId"] ?? NSNull()]
        if target.gesture == nil && action.kind != "home" {
            var expected = fields["target"] as! [String: Any]
            expected["path"] = target.path
            fields["target"] = expected
        }
        guard try jsonData(fields).count <= 60_000 else {
            throw IPhoneUseError("target_too_large", "Target or screen guard exceeds the Runner request budget")
        }
        return fields
    }

    func observe() throws -> CapturedObservation {
        recording?.checkDisplay()
        defer { recording?.checkDisplay() }
        let response = try request("observe")
        guard let result = response["result"] as? [String: Any],
              response["ok"] as? Bool == true || result["axStatus"] as? String == "unavailable" else {
            throw IPhoneUseError("observe_failed", response["error"] as? String ?? "Runner did not return an observation")
        }
        return try XCTestCapture.decode(result)
    }

    func startRecording(duration: Double) throws -> [String: Any] {
        guard let recording, identity != nil, try runner?.isRunning() == true else { throw IPhoneUseError("backend_unavailable", "Runner is not connected") }
        return try recording.start(duration: duration)
    }

    func stopRecording(id: String) throws -> [String: Any] {
        guard let recording else { throw IPhoneUseError("backend_unavailable", "Runner is not connected") }
        return try recording.stop(id: id)
    }

    func startPreview(options: NativePreviewOptions = NativePreviewOptions()) throws -> [String: Any] {
        guard let recording else { throw IPhoneUseError("backend_unavailable", "Runner is not connected") }
        return try recording.startPreview(options: options)
    }
    func stopPreview() throws -> [String: Any] { try recording?.stopPreview() ?? ["state": "stopped"] }
    func previewTick() -> Bool { recording?.previewTick() ?? false }
    func showPreviewGesture(_ gesture: NativePreviewGesture) { recording?.showPreviewGesture(gesture) }
    var previewGestureRotation: String? { recording?.previewGestureRotation }
    func cancelCurrent() { recordingCancellation.cancel() }

    func stop() -> [String: Any] {
        let monitorExited = authorization.stop()
        recordingCancellation.cancel()
        let recordingCleanup = recording?.close() ?? ["recordingCleanupAcknowledged": true]
        var acknowledged = false
        if identity != nil {
            acknowledged = (try? request("shutdown", timeout: 5)["ok"] as? Bool) == true
        }
        let cleanup = runner?.stop() ?? ["runnerProcessExited": true]
        transport = nil
        identity = nil
        runnerPID = nil
        deviceLock = nil
        return ["shutdownAcknowledged": acknowledged && cleanup["runnerProcessExited"] as? Bool == true
                    && recordingCleanup["recordingCleanupAcknowledged"] as? Bool == true,
                "runnerShutdownAcknowledged": acknowledged, "recordingCleanup": recordingCleanup,
                "authorizationMonitorExited": monitorExited,
                "runnerProcessExited": cleanup["runnerProcessExited"] ?? false, "runnerCleanup": cleanup]
    }
}
