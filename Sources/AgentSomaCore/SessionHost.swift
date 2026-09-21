import Foundation
import Darwin

final class SessionHost {
    private let paths: SessionPaths
    private let config: HostConfiguration
    private let backend: SessionBackend
    private let observations: ObservationCache
    private let control = DispatchQueue(label: "agentsoma.host.control")
    private let work = DispatchQueue(label: "agentsoma.host.device")
    private let done = DispatchSemaphore(value: 0)
    private var lifecycle: SessionLifecycle
    private var server: JSONServer?
    private var timer: DispatchSourceTimer?
    private var signals: [DispatchSourceSignal] = []
    private var backendInfo: [String: Any] = [:]

    init(config: HostConfiguration, paths: SessionPaths, backend: SessionBackend) {
        self.config = config
        self.paths = paths
        self.backend = backend
        observations = ObservationCache(directory: paths.directory)
        lifecycle = SessionLifecycle(timeout: config.idleTimeoutSeconds)
    }

    func run() throws {
        do {
            let server = try JSONServer(path: paths.socket)
            self.server = server
            server.onRequest = { [self] request, reply in control.async { self.receive(request, reply: reply) } }
            server.onFailure = { [self] error in
                control.async { self.close(reason: "ipc_failed: \(error)") }
            }
            for number in [SIGTERM, SIGINT] {
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: control)
                source.setEventHandler { [self] in close(reason: "signal") }
                source.resume()
                signals.append(source)
            }
            server.start { [self] in
                control.async {
                    guard self.lifecycle.phase == .starting else { return }
                    self.work.async {
                        do {
                            let info = try self.backend.start()
                            self.control.async {
                                self.backendInfo = info
                                guard self.lifecycle.phase == .starting else { return }
                                self.lifecycle.ready(at: ProcessInfo.processInfo.systemUptime)
                                let timer = DispatchSource.makeTimerSource(queue: self.control)
                                timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
                                timer.setEventHandler { [self] in
                                    if lifecycle.isExpired(at: ProcessInfo.processInfo.systemUptime) { close(reason: "idle_timeout") }
                                }
                                timer.resume()
                                self.timer = timer
                            }
                        } catch {
                            try? saveJSON(["code": (error as? SomaError)?.code ?? "host_start_failed",
                                           "message": String(describing: error)],
                                          to: self.paths.directory.appendingPathComponent("startup-error.json"))
                            self.control.async { self.close(reason: "startup_failed") }
                        }
                    }
                }
            }
            done.wait()
            timer?.cancel()
            signals.forEach { $0.cancel() }
            try? FileManager.default.removeItem(atPath: paths.socket)
        } catch { _ = backend.stop(); throw error }
    }

    private func receive(_ request: [String: Any], reply: @escaping JSONServer.Reply) {
        let id = request["id"] as? String ?? ""
        let requestedOperation = request["op"] as? String ?? ""
        let operation = requestedOperation == "type-with-method" ? "type" : requestedOperation
        func reject(_ code: String, _ message: String) {
            var response: [String: Any] = ["id": id, "session": config.session, "ok": false,
                   "outcome": "not_dispatched", "error": ["code": code, "message": message]]
            if config.backend == "apple-native", code == "session_closed" { NativeRecovery.enrich(&response, control: nil) }
            reply(response, {})
        }
        guard request["version"] as? Int == 1, request["session"] as? String == config.session,
              !id.isEmpty, (["status", "apps", "open", "observe", "inspect", "disconnect", "text-finish", "text-prepare", "record-start", "record-stop"] + DeviceAction.operations).contains(operation) else {
            reject("invalid_request", "Invalid session request")
            return
        }
        if operation == "open" {
            guard let bundle = request["bundleId"] as? String,
                  bundle.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]{0,254}\\z", options: .regularExpression) != nil else {
                reject("invalid_bundle_id", "A bundle identifier is required")
                return
            }
        }
        if operation == "apps" {
            guard let offset = request["offset"] as? Int, offset >= 0,
                  request["query"] == nil || request["query"] is String else {
                reject("invalid_app_query", "Use a text query and a nonnegative offset")
                return
            }
        }
        if operation == "record-start" || operation == "record-stop" {
            do {
                guard config.backend == "apple-native" else { throw SomaError("native_action_unsupported", "Recording applies only to apple-native") }
                if operation == "record-start" { _ = try NativeRecordingOptions.duration(request) }
                else if UUID(uuidString: request["recordingID"] as? String ?? "") == nil {
                    throw SomaError("invalid_recording_id", "Use the recording ID returned by record-start or status")
                }
            } catch { reject((error as? SomaError)?.code ?? "invalid_request", String(describing: error)); return }
        }
        var reference: ObservationReference?
        var action: DeviceAction?
        if operation == "text-prepare", config.backend != "apple-native" {
            reject("native_action_unsupported", "text-prepare applies only to apple-native")
            return
        }
        if requestedOperation == "type-with-method", request["textMethod"] == nil {
            reject("invalid_text_method", "Explicit native text requests require a method")
            return
        }
        if operation == "text-finish" {
            do {
                guard config.backend == "apple-native", let transaction = request["transaction"] as? String,
                      UUID(uuidString: transaction) != nil else {
                    throw SomaError("invalid_text_transaction", "text-finish requires apple-native and a pasteboard transaction ID")
                }
                reference = try ObservationReference(request["reference"] as? String ?? "")
                guard reference?.node == nil else { throw SomaError("invalid_reference", "Use the current screenshot oN") }
            } catch { reject((error as? SomaError)?.code ?? "invalid_request", String(describing: error)); return }
        }
        if DeviceAction.operations.contains(operation) {
            do { action = try DeviceAction(operation: operation, request: request, allowScreenText: config.backend == "apple-native") }
            catch { reject((error as? SomaError)?.code ?? "invalid_action", String(describing: error)); return }
        }
        if operation == "inspect" {
            do {
                reference = try ObservationReference(request["reference"] as? String ?? "")
                guard let offset = request["offset"] as? Int, offset >= 0 else {
                    throw SomaError("invalid_offset", "A nonnegative offset is required")
                }
                guard request["query"] == nil || request["query"] is String else {
                    throw SomaError("invalid_inspect_query", "Query must be text")
                }
            } catch {
                reject((error as? SomaError)?.code ?? "invalid_reference", String(describing: error))
                return
            }
        }
        guard lifecycle.accept(at: ProcessInfo.processInfo.systemUptime) else {
            reject("session_closed", "Session has expired or is closing; connect again")
            if lifecycle.isExpired(at: ProcessInfo.processInfo.systemUptime) { close(reason: "idle_timeout") }
            return
        }
        if operation == "disconnect" {
            close(reason: "disconnect", requestID: id, reply: reply)
            return
        }
        work.async { [self] in
            var response: [String: Any] = ["id": id, "session": config.session, "ok": true]
            var previousObservation: String?
            var effective = operation == "open"
            do {
                switch operation {
                case "status": response["result"] = try backend.status()
                case "apps":
                    response["result"] = try backend.apps().page(query: request["query"] as? String, offset: request["offset"] as! Int)
                    effective = true
                case "open":
                    previousObservation = observations.beginAction()
                    response["result"] = try backend.open(bundle: request["bundleId"] as! String)
                    observations.finishAction(previous: previousObservation, dispatched: true)
                    response["outcome"] = "completed"
                case "observe":
                    observations.invalidate("superseded")
                    response["result"] = try observations.store(backend.observe())
                    effective = true
                case "inspect":
                    response["result"] = try observations.inspect(reference!, offset: request["offset"] as! Int,
                                                                  query: request["query"] as? String)
                    effective = true
                case "record-start":
                    observations.invalidate("recording_started")
                    response["requiresObservation"] = true
                    response["result"] = try backend.startRecording(duration: NativeRecordingOptions.duration(request))
                    effective = true
                case "record-stop":
                    observations.invalidate("recording_stopped")
                    response["requiresObservation"] = true
                    let result = try backend.stopRecording(id: request["recordingID"] as! String)
                    response["result"] = result
                    response["ok"] = result["state"] as? String == "completed"
                    if response["ok"] as? Bool != true {
                        response["error"] = result["error"] ?? ["code": "recording_incomplete", "message": "Recording has not completed; inspect status. Do not restart automatically."]
                    }
                    effective = true
                case "text-prepare":
                    // Registration can change keyboard visibility. Consume old references
                    // and capture afterward even when the owned keyboard already exists.
                    previousObservation = observations.beginAction()
                    effective = true
                    response["result"] = try backend.prepareText()
                    observations.finishAction(previous: previousObservation, dispatched: true)
                    response["outcome"] = "completed"
                    response["requiresObservation"] = true
                case "text-finish":
                    let metadata = try observations.resolveTextConfirmation(reference!)
                    let result = try backend.finishText(transaction: request["transaction"] as! String, observation: metadata)
                    response["result"] = result
                    effective = true
                    let restored = result["pasteboardRestoreAcknowledged"] as? Bool == true
                    response["ok"] = restored
                    response["outcome"] = restored ? "completed" : "unknown"
                    response["requiresObservation"] = true
                    if !restored {
                        response["error"] = ["code": "native_pasteboard_restore_unconfirmed",
                            "message": "Clipboard restoration was not confirmed; no restorative write will be replayed. Inspect clipboard status and close the session."]
                    }
                case "tap", "double-tap", "long-press", "pinch", "swipe", "home", "type", "press":
                    let target = try observations.resolveTarget(for: action!)
                    previousObservation = observations.beginAction()
                    effective = true
                    response["result"] = try backend.perform(action!, target: target)
                    observations.finishAction(previous: previousObservation, dispatched: true)
                    response["outcome"] = "completed"
                    if config.backend == "apple-native",
                       (response["result"] as? [String: Any])?["transportStatus"] as? String == "sent" {
                        // RemoteXPC's send barrier is not a device execution acknowledgement.
                        response["outcome"] = "unknown"
                        response["ok"] = false
                        response["requiresObservation"] = true
                        response["error"] = ["code": "native_input_unacknowledged",
                            "message": "Input reports were queued; inspect the new screenshot to judge the result. Input was not replayed."]
                    }
                default: break
                }
            } catch {
                response["ok"] = false
                let failure = error as? ActionFailure
                if let result = failure?.result { response["result"] = result }
                let uncertain = failure?.possiblyExecuted ?? (error as? TransportError)?.possiblySent ?? false
                if operation == "record-start" || operation == "record-stop" {
                    response["outcome"] = uncertain ? "unknown" : "not_dispatched"
                }
                if operation == "open" || action != nil || operation == "text-finish" || operation == "text-prepare" {
                    observations.finishAction(previous: previousObservation, dispatched: uncertain)
                    if failure?.requiresObservation == true { observations.invalidate("target_changed") }
                    response["outcome"] = uncertain ? "unknown" : "not_dispatched"
                    response["requiresObservation"] = uncertain || failure?.requiresObservation == true || (error as? SomaError)?.code == "stale_reference"
                }
                if config.backend == "apple-native", !uncertain, let capture = failure?.rejectedCapture {
                    // Keep the exact valid frame that rejected input, not a later recapture.
                    // It is a new observation, never evidence of a dispatched action.
                    do {
                        let rejected = try observations.store(capture)
                        response["observation"] = ["ok": true, "phase": "pre_input_rejection", "result": rejected]
                        var result = response["result"] as? [String: Any] ?? [:]
                        result["rejectedObservationID"] = rejected["observation"]
                        response["result"] = result
                    } catch {
                        response["observation"] = ["ok": false, "phase": "pre_input_rejection", "error": String(describing: error)]
                    }
                }
                if operation == "status" { observations.invalidate("backend_unavailable") }
                response["error"] = ["code": failure?.code ?? (error as? SomaError)?.code ?? "backend_error", "message": String(describing: error)]
            }
            // Native actions always return a new observation while still holding the device
            // work queue. Capture failure preserves the action's execution facts.
            if config.backend == "apple-native", operation == "open" || action != nil || operation == "text-finish" || operation == "text-prepare",
               response["outcome"] as? String != "not_dispatched" {
                observations.invalidate("post_action_capture")
                do {
                    let after = try observations.store(backend.observe())
                    response["observation"] = ["ok": true, "result": after]
                    var result = response["result"] as? [String: Any] ?? [:]
                    result["afterObservationID"] = after["observation"]
                    response["result"] = result
                } catch {
                    response["observation"] = ["ok": false, "error": String(describing: error)]
                    if operation == "text-prepare" {
                        // Preparation completed, but there is no usable input baseline.
                        response["ok"] = false
                        response["error"] = ["code": "native_prepare_observation_failed",
                            "message": "Keyboard preparation completed but screenshot capture failed; observe before input: \(error)"]
                    }
                }
            }
            if config.backend == "apple-native", operation == "open" || action != nil || operation == "text-prepare" || (operation == "observe" && response["ok"] as? Bool == false) {
                NativeRecovery.enrich(&response, control: try? backend.status())
            }
            if config.backend == "apple-native", operation == "open" || action != nil || operation == "text-finish" || operation == "text-prepare" {
                var result = response["result"] as? [String: Any] ?? [:]
                result["actionID"] = id
                result["sourceObservationID"] = action?.reference.observation ?? reference?.observation
                response["result"] = result
                do {
                    let eventURL = paths.directory.appendingPathComponent("native-events.jsonl")
                    if !FileManager.default.fileExists(atPath: eventURL.path) {
                        FileManager.default.createFile(atPath: eventURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
                    }
                    let file = try FileHandle(forWritingTo: eventURL)
                    defer { try? file.close() }
                    try file.seekToEnd()
                    var data = try jsonData(["request": request, "response": response, "hostRecordedAt": Date().timeIntervalSince1970])
                    data.append(10)
                    try file.write(contentsOf: data)
                } catch { response["eventRecordingError"] = String(describing: error) }
            }
            // The control queue serializes command admission against expiry and completion.
            control.sync {
                lifecycle.finish(effective: effective, at: ProcessInfo.processInfo.systemUptime)
                if operation == "status" {
                    response["hostPid"] = ProcessInfo.processInfo.processIdentifier
                    response["idleTimeoutSeconds"] = config.idleTimeoutSeconds
                    response["idleRemainingSeconds"] = max(0, config.idleTimeoutSeconds - (ProcessInfo.processInfo.systemUptime - lifecycle.lastActivity))
                }
                reply(response, {})
            }
        }
    }

    private func close(reason: String, requestID: String? = nil, reply: JSONServer.Reply? = nil) {
        guard lifecycle.phase != .closing else { return }
        lifecycle.close()
        if reason == "signal" || reason.hasPrefix("ipc_failed") { backend.cancelCurrent() }
        timer?.cancel()
        server?.stopAccepting()
        // Already admitted work finishes first on this same serial queue.
        work.async { [self] in
            // Native health and HID availability may have changed since startup.
            // Its status is local; do not add a Runner request to XCTest teardown.
            let finalBackendInfo = config.backend == "apple-native" ? (try? backend.status()) ?? backendInfo : backendInfo
            var cleanup = backend.stop()
            do { try observations.clear(); cleanup["observationCacheRemoved"] = true }
            catch { cleanup["observationCacheRemoved"] = false; cleanup["cacheError"] = String(describing: error) }
            let stopped = config.backend == "apple-native" ? cleanup["backendStopped"] as? Bool == true
                : cleanup["xcodebuildExited"] as? Bool == true && cleanup["forced"] as? Bool != true && cleanup["xcodebuildExitCode"] as? Int == 0
            let clean = stopped && cleanup["shutdownAcknowledged"] as? Bool == true && cleanup["observationCacheRemoved"] as? Bool == true
            let result: [String: Any] = ["session": config.session, "reason": reason,
                "hostPid": ProcessInfo.processInfo.processIdentifier, "backend": finalBackendInfo,
                "cleanup": cleanup, "endedAt": Date().timeIntervalSince1970]
            try? saveJSON(result, to: paths.exit)
            if let reply, let requestID {
                reply(["id": requestID, "session": config.session, "ok": clean, "result": result], { self.done.signal() })
            } else { done.signal() }
        }
    }
}

public func runHost(directory: URL) throws {
    umask(0o077)
    setsid()
    let paths = SessionPaths(directory: directory)
    do {
        try SessionPaths.secureDirectory(directory)
        let config = try JSONDecoder().decode(HostConfiguration.self, from: Data(contentsOf: paths.config))
        let backend: SessionBackend
        switch config.backend ?? "xctest" {
        case "xctest": backend = XCTestBackend(config: config, paths: paths)
        case "apple-native": backend = AppleDeviceBackend(config: config, paths: paths)
        default: throw SomaError("unsupported_backend", "Unknown session backend")
        }
        let host = SessionHost(config: config, paths: paths, backend: backend)
        try host.run()
    } catch {
        try? saveJSON(["code": (error as? SomaError)?.code ?? "host_start_failed", "message": String(describing: error)],
                      to: directory.appendingPathComponent("startup-error.json"))
        throw error
    }
}
