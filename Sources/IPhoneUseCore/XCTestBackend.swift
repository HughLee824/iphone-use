import Foundation
import Network
import Darwin

// The host depends on these few operations, not XCTest objects or an agent-facing Runner protocol.
protocol SessionBackend: AnyObject {
    func start() throws -> [String: Any]
    func status() throws -> [String: Any]
    func apps() throws -> AppCatalog
    func open(bundle: String) throws -> [String: Any]
    func appLifecycle(bundle: String, relaunch: Bool) throws -> [String: Any]
    func observe() throws -> CapturedObservation
    func perform(_ action: DeviceAction, target: ObservedTarget) throws -> [String: Any]
    func stop() -> [String: Any]
    func cancelCurrent()
    func finishText(transaction: String, observation: [String: Any]) throws -> [String: Any]
    func prepareText() throws -> [String: Any]
    func startRecording(duration: Double) throws -> [String: Any]
    func stopRecording(id: String) throws -> [String: Any]
}

extension SessionBackend {
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
    private var process: Process?
    private var log: FileHandle?
    private var deviceLock: SessionDeviceLock?
    private var endpoint: NWEndpoint?
    private let token = UUID().uuidString + UUID().uuidString
    private var identity: String?
    private var runnerPID: Int?
    private var deviceUDID: String?
    private let recordingCancellation = NativeCancellation()
    private var recording: RunnerNativeRecording?
    private var recordingPlatformSupported = false

    init(config: HostConfiguration, paths: SessionPaths) {
        self.config = config
        self.paths = paths
    }

    func start() throws -> [String: Any] {
        let logURL = paths.directory.appendingPathComponent("xcodebuild.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        log = try FileHandle(forWritingTo: logURL)
        let details = try deviceInfo("details")
        guard let hardware = details["hardwareProperties"] as? [String: Any],
              let udid = hardware["udid"] as? String,
              let connection = details["connectionProperties"] as? [String: Any],
              let address = connection["tunnelIPAddress"] as? String,
              IPv6Address(address) != nil, address != "::" else {
            throw IPhoneUseError("coredevice_unavailable", "No native CoreDevice IPv6 address; see \(logURL.path)")
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
                                          cancellation: recordingCancellation)
        let manifest = paths.directory.appendingPathComponent("runner.xctestrun")
        try RunnerSessionManifest.prepare(source: URL(fileURLWithPath: config.xctestrun), destination: manifest)
        endpoint = .hostPort(host: .init(address), port: 47821)
        let runner = Process()
        runner.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        runner.arguments = ["xcodebuild", "test-without-building", "-xctestrun", manifest.path,
            "-destination", "platform=iOS,id=\(udid)", "-parallel-testing-enabled", "NO",
            "-only-testing:IPhoneUseTests/LiveSessionTests/testCommandSession",
            "-resultBundlePath", paths.directory.appendingPathComponent("run.xcresult").path]
        var environment = ProcessInfo.processInfo.environment
        environment["TEST_RUNNER_IPHONE_USE_SESSION_TOKEN"] = token
        environment["TEST_RUNNER_IPHONE_USE_LISTEN_HOST"] = address
        environment["TEST_RUNNER_IPHONE_USE_HOST_MANAGED"] = "1"
        runner.environment = environment
        runner.standardInput = FileHandle.nullDevice
        runner.standardOutput = log
        runner.standardError = log
        try runner.run()
        process = runner
        try saveJSON(["device": udid, "address": address, "xcodebuildPid": runner.processIdentifier],
                     to: paths.directory.appendingPathComponent("backend.json"))
        let deadline = ProcessInfo.processInfo.systemUptime + 90
        while runner.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
            // Only startup health checks retry. No UI command is sent until readiness succeeds.
            if let response = try? request("ping", timeout: 1), response["ok"] as? Bool == true,
               let result = response["result"] as? [String: Any] {
                try Self.validateCapabilities(result)
                guard result["applicationStateTimeoutSupported"] as? Bool == true else {
                    throw IPhoneUseError("unsupported_xctest_runtime", "This XCTest runtime cannot bound application-state waits; see \(logURL.path)")
                }
                identity = response["sessionId"] as? String
                runnerPID = response["runnerPid"] as? Int
                guard identity != nil, runnerPID != nil else {
                    throw IPhoneUseError("invalid_runner_identity", "Runner did not report its session identity")
                }
                return metadata()
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw IPhoneUseError("runner_start_failed", "XCTest did not become ready; see \(logURL.path)")
    }

    private func deviceInfo(_ kind: String) throws -> [String: Any] {
        try CoreDevice.read(["device", "info", kind, "--device", config.device],
                            savingTo: paths.directory.appendingPathComponent("device-\(kind).json"))
    }

    private func metadata() -> [String: Any] {
        ["runnerSession": identity ?? "", "runnerPid": runnerPID ?? 0,
         "xcodebuildPid": process?.processIdentifier ?? 0, "transport": "native-coredevice"]
    }

    private func request(_ operation: String, fields: [String: Any] = [:], timeout: TimeInterval = 45) throws -> [String: Any] {
        guard let endpoint else { throw IPhoneUseError("backend_unavailable", "Runner is not connected") }
        var request = fields
        request["id"] = UUID().uuidString
        request["token"] = token
        request["op"] = operation
        let response = try JSONTransport.exchange(endpoint: endpoint, request: request, timeout: timeout)
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
        result["recordingSupport"] = ["supported": recordingPlatformSupported, "method": "native_rtp", "source": "owned_native_rtp", "codec": "hevc",
                                      "connectionPolicy": "on_explicit_record_start", "hidServiceOpened": false,
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

    func perform(_ action: DeviceAction, target: ObservedTarget) throws -> [String: Any] {
        recording?.checkDisplay()
        defer { recording?.checkDisplay() }
        let response = try request("act", fields: Self.actionFields(action, target: target))
        return try ActionReply.decode(XCTestCapture.actionResponse(response, directory: paths.directory,
            expectedGuard: target.gesture?.screenGuard ?? target.textGuard, expectedMotion: target.gesture?.motion,
            expectedPinch: target.gesture?.pinch, expectedPressDuration: action.fields["duration"] as? Double, expectedHome: action.kind == "home",
            expectedKey: action.kind == "press" ? RunnerPressKey(rawValue: action.fields["key"] as? String ?? "") : nil))
    }

    static func validateCapabilities(_ result: [String: Any]) throws {
        let expected = ["observationVersion": 2, "actionVersion": 9, "launchVersion": 2, "frameStabilityVersion": 2, "screenGuardVersion": 1]
        var differences = expected.keys.sorted().compactMap { key -> String? in
            let actual = result[key] as? Int
            return actual == expected[key] ? nil : "\(key): expected \(expected[key]!), received \(actual.map(String.init) ?? "missing")"
        }
        if result["lifecycleOwner"] as? String != "host" { differences.append("lifecycleOwner: expected host") }
        if !differences.isEmpty {
            throw IPhoneUseError("runner_needs_rebuild", "Runner is incompatible (\(differences.joined(separator: "; "))). Release users: install matching CLI/Runner resources and run setup. Source developers: run build-runner and use its new .xctestrun")
        }
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
        guard let recording, process?.isRunning == true else { throw IPhoneUseError("backend_unavailable", "Runner is not connected") }
        return try recording.start(duration: duration)
    }

    func stopRecording(id: String) throws -> [String: Any] {
        guard let recording else { throw IPhoneUseError("backend_unavailable", "Runner is not connected") }
        return try recording.stop(id: id)
    }

    func cancelCurrent() { recordingCancellation.cancel() }

    func stop() -> [String: Any] {
        recordingCancellation.cancel()
        let recordingCleanup = recording?.close() ?? ["recordingCleanupAcknowledged": true]
        guard let runner = process else {
            deviceLock = nil
            return ["xcodebuildExited": true, "recordingCleanup": recordingCleanup]
        }
        var acknowledged = false
        if identity != nil, runner.isRunning {
            acknowledged = (try? request("shutdown", timeout: 5)["ok"] as? Bool) == true
        }
        var deadline = ProcessInfo.processInfo.systemUptime + 15
        while runner.isRunning, ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.05) }
        var forced = false
        if runner.isRunning {
            forced = true
            runner.terminate()
            deadline = ProcessInfo.processInfo.systemUptime + 3
            while runner.isRunning, ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if runner.isRunning { kill(runner.processIdentifier, SIGKILL) }
        }
        runner.waitUntilExit()
        process = nil
        deviceLock = nil
        try? log?.close()
        log = nil
        return ["shutdownAcknowledged": acknowledged && recordingCleanup["recordingCleanupAcknowledged"] as? Bool == true,
                "runnerShutdownAcknowledged": acknowledged, "recordingCleanup": recordingCleanup, "xcodebuildExited": true,
                "xcodebuildExitCode": Int(runner.terminationStatus), "forced": forced]
    }
}
