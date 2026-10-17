import Foundation
import Darwin

final class SessionHost {
    private let paths: SessionPaths
    private let config: HostConfiguration
    private let backend: SessionBackend
    private let touchPaste: TouchPasteSession
    private let observations: ObservationCache
    private let control = DispatchQueue(label: "iphone-use.host.control")
    private let work = DispatchQueue(label: "iphone-use.host.device")
    private let done = DispatchSemaphore(value: 0)
    private var lifecycle: SessionLifecycle
    private var server: JSONServer?
    private var timer: DispatchSourceTimer?
    private var previewCheckPending = false
    private var lastPreviewCheck = 0.0
    private var signals: [DispatchSourceSignal] = []
    private var backendInfo: [String: Any] = [:]

    init(config: HostConfiguration, paths: SessionPaths, backend: SessionBackend, touchPaste: TouchPasteSession? = nil) {
        self.config = config
        self.paths = paths
        self.backend = backend
        self.touchPaste = touchPaste ?? TouchPasteSession(config: config)
        observations = ObservationCache(directory: paths.directory)
        lifecycle = SessionLifecycle(timeout: config.idleTimeoutSeconds)
        backend.setEventDeliveryQueue(work)
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
                                    let now = ProcessInfo.processInfo.systemUptime
                                    if lifecycle.isExpired(at: now) { close(reason: "idle_timeout") }
                                    if lifecycle.phase == .ready, !previewCheckPending, now - lastPreviewCheck >= 2 {
                                        previewCheckPending = true; lastPreviewCheck = now
                                        work.async {
                                            if self.backend.previewTick() { self.observations.invalidate("preview_display_changed") }
                                            self.control.async { self.previewCheckPending = false }
                                        }
                                    }
                                }
                                timer.resume()
                                self.timer = timer
                            }
                        } catch {
                            try? saveJSON(["code": (error as? IPhoneUseError)?.code ?? "host_start_failed",
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
        } catch {
            let cleanup = backend.stop()
            try? saveJSON(cleanup, to: paths.directory.appendingPathComponent("startup-cleanup.json"))
            throw error
        }
    }

    private func receive(_ request: [String: Any], reply originalReply: @escaping JSONServer.Reply) {
        // Session identity comes from the immutable host configuration, never current user defaults.
        let reply: JSONServer.Reply = { [config] response, completion in
            var response = response
            response.merge(config.modeSelection.result) { _, selected in selected }
            originalReply(response, completion)
        }
        let id = request["id"] as? String ?? ""
        let requestedOperation = request["op"] as? String ?? ""
        let operation = ["type-with-method", "type-with-caret"].contains(requestedOperation) ? "type" :
            requestedOperation == "press-with-caret" ? "press" : requestedOperation == "text-prepare-scoped" ? "text-prepare" : requestedOperation
        let appLifecycle = operation == "terminate" || operation == "relaunch"
        let appAction = operation == "open" || appLifecycle
        func reject(_ code: String, _ message: String) {
            var response: [String: Any] = ["id": id, "session": config.session, "ok": false,
                   "outcome": "not_dispatched", "error": ["code": code, "message": message]]
            if config.backend == "apple-native", code == "session_closed" { NativeRecovery.enrich(&response, control: nil) }
            reply(response, {})
        }
        guard request["version"] as? Int == 1, request["session"] as? String == config.session,
              !id.isEmpty, (["status", "apps", "open", "terminate", "relaunch", "observe", "inspect", "disconnect", "text-finish", "text-prepare", "record-start", "record-stop", "preview-start", "preview-stop"] + DeviceAction.operations).contains(operation) else {
            reject("invalid_request", "Invalid session request")
            return
        }
        if appAction {
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
                if operation == "record-start" { _ = try NativeRecordingOptions.duration(request) }
                else if UUID(uuidString: request["recordingID"] as? String ?? "") == nil {
                    throw IPhoneUseError("invalid_recording_id", "Use the recording ID returned by record-start or status")
                }
            } catch { reject((error as? IPhoneUseError)?.code ?? "invalid_request", String(describing: error)); return }
        }
        var reference: ObservationReference?
        var action: DeviceAction?
        var textObservationOptions: NativeTextObservationOptions?
        var postActionSourceContext: ScreenContext?
        if operation == "text-prepare", config.backend != "apple-native" {
            reject("native_action_unsupported", "text-prepare applies only to apple-native")
            return
        }
        if requestedOperation == "text-prepare-scoped" || (operation == "text-prepare" && (request["fieldRect"] != nil || request["ignoreRect"] != nil)) {
            do { textObservationOptions = try NativeTextObservationOptions(request: request) }
            catch { reject((error as? IPhoneUseError)?.code ?? "invalid_text_region", String(describing: error)); return }
        }
        if ["type-with-caret", "press-with-caret"].contains(requestedOperation), request["caretRect"] == nil {
            reject("invalid_caret_region", "Explicit caret requests require --caret-rect")
            return
        }
        if requestedOperation == "type-with-method", request["textMethod"] == nil {
            reject("invalid_text_method", "Explicit text requests require a method")
            return
        }
        if operation == "text-finish" {
            do {
                guard let transaction = request["transaction"] as? String,
                      UUID(uuidString: transaction) != nil else {
                    throw IPhoneUseError("invalid_text_transaction", "text-finish requires a pasteboard transaction ID")
                }
                reference = try ObservationReference(request["reference"] as? String ?? "")
                guard reference?.node == nil else { throw IPhoneUseError("invalid_reference", "Use the current screenshot oN") }
            } catch { reject((error as? IPhoneUseError)?.code ?? "invalid_request", String(describing: error)); return }
        }
        if DeviceAction.operations.contains(operation) {
            do { action = try DeviceAction(operation: operation, request: request, allowScreenText: config.backend == "apple-native") }
            catch { reject((error as? IPhoneUseError)?.code ?? "invalid_action", String(describing: error)); return }
        }
        if operation == "inspect" {
            do {
                reference = try ObservationReference(request["reference"] as? String ?? "")
                guard let offset = request["offset"] as? Int, offset >= 0 else {
                    throw IPhoneUseError("invalid_offset", "A nonnegative offset is required")
                }
                guard request["query"] == nil || request["query"] is String else {
                    throw IPhoneUseError("invalid_inspect_query", "Query must be text")
                }
            } catch {
                reject((error as? IPhoneUseError)?.code ?? "invalid_reference", String(describing: error))
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
            var effective = appAction
            do {
                if touchPaste.pending, appAction || operation == "text-prepare" || operation == "type" || operation == "press" {
                    throw IPhoneUseError("touch_paste_pending", "Inspect the pending touch-paste transaction and text-finish before another text or app action")
                }
                if touchPaste.pending, ["tap", "double-tap", "long-press"].contains(operation) {
                    try touchPaste.checkOwnership()
                }
                switch operation {
                case "status":
                    var status = try backend.status()
                    status.merge(config.modeSelection.result) { _, selected in selected }
                    status["support"] = config.modeSelection.mode.support
                    status["touchPaste"] = touchPaste.status
                    status["textMethodSelection"] = config.modeSelection.mode.support["textMethods"]
                    status["textFinishSupported"] = true
                    response["result"] = status
                case "apps":
                    response["result"] = try backend.apps().page(query: request["query"] as? String, offset: request["offset"] as! Int)
                    effective = true
                case "open":
                    previousObservation = observations.beginAction()
                    response["result"] = try backend.open(bundle: request["bundleId"] as! String)
                    observations.finishAction(previous: previousObservation, dispatched: true)
                    response["outcome"] = "completed"
                case "terminate", "relaunch":
                    previousObservation = observations.beginAction()
                    response["result"] = try backend.appLifecycle(bundle: request["bundleId"] as! String, relaunch: operation == "relaunch")
                    observations.finishAction(previous: previousObservation, dispatched: true)
                    response["outcome"] = "completed"
                    response["requiresObservation"] = true
                case "observe":
                    observations.invalidate("superseded")
                    response["result"] = try observations.store(backend.observe())
                    effective = true
                case "inspect":
                    response["result"] = try observations.inspect(reference!, offset: request["offset"] as! Int,
                                                                  query: request["query"] as? String)
                    effective = true
                case "preview-start", "preview-stop":
                    observations.invalidate("preview_changed")
                    response["requiresObservation"] = true
                    response["result"] = try operation == "preview-start" ? backend.startPreview() : backend.stopPreview()
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
                    // Bind preparation to a fresh observation, even when the borrowed
                    // CoreDevice keyboard is already ready. Preparation does not focus a field.
                    previousObservation = observations.beginAction()
                    effective = true
                    response["result"] = try backend.prepareText()
                    observations.finishAction(previous: previousObservation, dispatched: true)
                    response["outcome"] = "completed"
                    response["requiresObservation"] = true
                case "text-finish":
                    let metadata = try observations.resolveTextConfirmation(reference!, nativeOnly: config.backend == "apple-native")
                    if let raw = metadata["textObservationOptions"] as? [String: Any] {
                        textObservationOptions = try JSONDecoder().decode(NativeTextObservationOptions.self, from: jsonData(raw))
                    }
                    let transaction = request["transaction"] as! String
                    let result: [String: Any]
                    if touchPaste.pending || touchPaste.owns(transaction) {
                        result = try touchPaste.finish(transaction: transaction, observedAt: metadata["hostStoredAtUptime"] as! Double)
                    } else {
                        guard config.backend == "apple-native" else {
                            throw IPhoneUseError("invalid_text_transaction", "No matching touch-paste transaction exists in this Runner session")
                        }
                        result = try backend.finishText(transaction: transaction, observation: metadata)
                    }
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
                    if action!.touchPaste {
                        _ = try observations.resolveTextConfirmation(action!.reference, nativeOnly: false)
                        if config.backend == "apple-native",
                           let pasteboard = try backend.status()["pasteboard"] as? [String: Any],
                           pasteboard["restorePending"] as? Bool == true || pasteboard["writeUncertain"] as? Bool == true {
                            throw IPhoneUseError("native_pasteboard_pending", "Finish the existing native clipboard transaction before touch-paste")
                        }
                        previousObservation = observations.beginAction()
                        effective = true
                        response["result"] = try touchPaste.stage(action!.fields["text"] as! String, observation: action!.reference.observation)
                        observations.finishAction(previous: previousObservation, dispatched: true)
                        response["outcome"] = "prepared"
                        response["requiresObservation"] = true
                        break
                    }
                    let target = try observations.resolveTarget(for: action!)
                    if config.backend == "apple-native", let raw = target.context["screenContext"] as? [String: Any] {
                        postActionSourceContext = try JSONDecoder().decode(ScreenContext.self, from: jsonData(raw))
                    }
                    if ["type", "press"].contains(action!.kind), let field = action!.textRegion {
                        textObservationOptions = NativeTextObservationOptions(field: field, ignoring: action!.ignoredScreenRect)
                    }
                    previousObservation = observations.beginAction()
                    effective = true
                    let previewGesture = NativePreviewGesture(action: action!, target: target,
                        previewRotation: backend.previewGestureRotation)
                    response["result"] = try backend.perform(action!, target: target) { [backend] in
                        // The backend signals only after validation, at input dispatch.
                        // A later failure must not delay or replay this visual receipt.
                        if let gesture = previewGesture { backend.showPreviewGesture(gesture) }
                    }
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
                if ["record-start", "record-stop", "preview-start", "preview-stop"].contains(operation) {
                    response["outcome"] = uncertain ? "unknown" : "not_dispatched"
                }
                if appAction || action != nil || operation == "text-finish" || operation == "text-prepare" {
                    observations.finishAction(previous: previousObservation, dispatched: uncertain)
                    if failure?.requiresObservation == true { observations.invalidate("target_changed") }
                    response["outcome"] = uncertain ? "unknown" : "not_dispatched"
                    response["requiresObservation"] = uncertain || failure?.requiresObservation == true || (error as? IPhoneUseError)?.code == "stale_reference"
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
                response["error"] = ["code": failure?.code ?? (error as? IPhoneUseError)?.code ?? "backend_error", "message": String(describing: error)]
                if let diagnostics = (error as? IPhoneUseError)?.diagnostics, !diagnostics.isEmpty {
                    response["diagnostics"] = diagnostics
                }
            }
            // Native actions always return a new observation while still holding the device
            // work queue. Capture failure preserves the action's execution facts.
            if config.backend == "apple-native" || action?.touchPaste == true, appAction || action != nil || operation == "text-finish" || operation == "text-prepare",
               response["outcome"] as? String != "not_dispatched" {
                observations.invalidate("post_action_capture")
                do {
                    let capture: CapturedObservation
                    if operation == "text-finish" || action?.touchPaste == true {
                        capture = try textObservationOptions.map { try backend.observeText($0) } ?? backend.observe()
                    } else {
                        capture = try backend.observeAfterAction(textOptions: textObservationOptions,
                            ignoring: action?.ignoredScreenRect ?? textObservationOptions?.ignoring,
                            sourceContext: postActionSourceContext)
                    }
                    let after = try observations.store(capture)
                    var observation: [String: Any] = ["ok": true, "result": after]
                    if let stability = capture.metadata["postActionStability"] as? [String: Any] {
                        observation["stability"] = stability
                        if stability["stable"] as? Bool != true {
                            let reason = stability["reason"] as? String ?? "frame_stability_timeout"
                            observation["warning"] = "\(reason): inspect the latest screenshot and capture diagnostics; do not replay input"
                        }
                    }
                    response["observation"] = observation
                    var result = response["result"] as? [String: Any] ?? [:]
                    result["afterObservationID"] = after["observation"]
                    response["result"] = result
                } catch {
                    response["observation"] = ["ok": false, "error": String(describing: error)]
                    if let failure = error as? IPhoneUseError {
                        response["observation"] = ["ok": false, "error": failure.description,
                            "errorCode": failure.code, "diagnostics": failure.diagnostics]
                    }
                    if action?.touchPaste == true, response["outcome"] as? String == "prepared" {
                        response["ok"] = false
                        response["error"] = ["code": "touch_paste_observation_failed",
                            "message": "Clipboard staging completed but capture failed; observe before touching Paste. Do not stage again."]
                    }
                    if operation == "text-prepare" {
                        // Preparation completed, but there is no usable input baseline.
                        response["ok"] = false
                        response["error"] = ["code": "native_prepare_observation_failed",
                            "message": "Keyboard preparation completed but screenshot capture failed; observe before input: \(error)"]
                    }
                }
            }
            if config.backend == "apple-native", appAction || action != nil || operation == "text-prepare" || (operation == "observe" && response["ok"] as? Bool == false) {
                NativeRecovery.enrich(&response, control: try? backend.status())
            }
            if config.backend == "apple-native", appAction || action != nil || operation == "text-finish" || operation == "text-prepare" {
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
            let touchPasteCleanup = touchPaste.close()
            var cleanup = backend.stop()
            cleanup["touchPaste"] = touchPasteCleanup
            do { try observations.clear(); cleanup["observationCacheRemoved"] = true }
            catch { cleanup["observationCacheRemoved"] = false; cleanup["cacheError"] = String(describing: error) }
            let stopped = config.backend == "apple-native" ? cleanup["backendStopped"] as? Bool == true
                : cleanup["runnerProcessExited"] as? Bool == true
            let clean = stopped && touchPasteCleanup["pasteboardRestoreAcknowledged"] as? Bool == true && touchPasteCleanup["connectionsClosed"] as? Bool == true && cleanup["shutdownAcknowledged"] as? Bool == true && cleanup["observationCacheRemoved"] as? Bool == true
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
        default: throw IPhoneUseError("unsupported_backend", "Unknown session backend")
        }
        let host = SessionHost(config: config, paths: paths, backend: backend)
        try host.run()
    } catch {
        try? saveJSON(["code": (error as? IPhoneUseError)?.code ?? "host_start_failed", "message": String(describing: error)],
                      to: directory.appendingPathComponent("startup-error.json"))
        throw error
    }
}
