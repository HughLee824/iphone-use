import Foundation
import Darwin

final class SessionHost {
    let paths: SessionPaths
    let config: HostConfiguration
    let backend: SessionBackend
    let touchPaste: TouchPasteSession
    let observations: ObservationCache
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

    init(
        config: HostConfiguration, paths: SessionPaths, backend: SessionBackend,
        touchPaste: TouchPasteSession? = nil
    ) {
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
            server.onRequest = { [self] request, reply in
                control.async { self.receive(request, reply: reply) }
            }
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
                                self.startTimer()
                            }
                        } catch {
                            try? saveJSON(
                                [
                                    "code": (error as? IPhoneUseError)?.code ?? "host_start_failed",
                                    "message": String(describing: error)
                                ],
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

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: self.control)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [self] in
            let now = ProcessInfo.processInfo.systemUptime
            if lifecycle.isExpired(at: now) { close(reason: "idle_timeout") }
            if lifecycle.phase == .ready, !previewCheckPending, now - lastPreviewCheck >= 2 {
                previewCheckPending = true; lastPreviewCheck = now
                work.async {
                    if self.backend.previewTick() {
                        self.observations.invalidate("preview_display_changed")
                    }
                    self.control.async { self.previewCheckPending = false }
                }
            }
        }
        timer.resume()
        self.timer = timer
    }

    private func receive(_ request: [String: Any], reply originalReply: @escaping JSONServer.Reply) {
        let admission = HostRequest(request, config: config, reply: originalReply)
        guard admission.validate() else { return }
        let operation = admission.operation
        let id = admission.id
        let reply = admission.reply
        if operation == "disconnect", lifecycle.phase == .starting {
            backend.cancelCurrent()
            close(reason: "disconnect", requestID: id, reply: reply)
            return
        }
        let pendingAtAdmission = lifecycle.pending
        guard lifecycle.accept(at: ProcessInfo.processInfo.systemUptime) else {
            admission.reject("session_closed", "Session has expired or is closing; connect again")
            if lifecycle.isExpired(at: ProcessInfo.processInfo.systemUptime) { close(reason: "idle_timeout") }
            return
        }
        if operation == "disconnect" {
            close(reason: "disconnect", requestID: id, reply: reply)
            return
        }
        work.async { [self] in
            let execution = HostRequestExecution(host: self, admission: admission)
            execution.run()
            control.sync {
                lifecycle.finish(effective: execution.effective, at: ProcessInfo.processInfo.systemUptime)
                var response = execution.response
                if operation == "status" {
                    response["pendingOperationsAtRequest"] = pendingAtAdmission
                    response["hostPid"] = ProcessInfo.processInfo.processIdentifier
                    response["idleTimeoutSeconds"] = config.idleTimeoutSeconds
                    response["idleRemainingSeconds"] = max(
                        0,
                        config.idleTimeoutSeconds
                            - (ProcessInfo.processInfo.systemUptime - lifecycle.lastActivity))
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
            let finalBackendInfo =
                config.backend == "apple-native" ? (try? backend.status()) ?? backendInfo : backendInfo
            let touchPasteCleanup = touchPaste.close()
            var cleanup = backend.stop()
            cleanup["touchPaste"] = touchPasteCleanup
            do { try observations.clear(); cleanup["observationCacheRemoved"] = true } catch {
                cleanup["observationCacheRemoved"] = false; cleanup["cacheError"] = String(describing: error)
            }
            let stopped =
                config.backend == "apple-native"
                ? cleanup["backendStopped"] as? Bool == true
                : cleanup["runnerProcessExited"] as? Bool == true
            let clean =
                stopped && touchPasteCleanup["pasteboardRestoreAcknowledged"] as? Bool == true
                && touchPasteCleanup["connectionsClosed"] as? Bool == true
                && cleanup["shutdownAcknowledged"] as? Bool == true
                && cleanup["observationCacheRemoved"] as? Bool == true
            let result: [String: Any] = [
                "session": config.session, "reason": reason,
                "hostPid": ProcessInfo.processInfo.processIdentifier, "backend": finalBackendInfo,
                "cleanup": cleanup, "endedAt": Date().timeIntervalSince1970
            ]
            try? saveJSON(result, to: paths.exit)
            if let reply, let requestID {
                reply(
                    ["id": requestID, "session": config.session, "ok": clean, "result": result],
                    { self.done.signal() })
            } else {
                done.signal()
            }
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
        try? saveJSON(
            [
                "code": (error as? IPhoneUseError)?.code ?? "host_start_failed",
                "message": String(describing: error)
            ],
            to: directory.appendingPathComponent("startup-error.json"))
        throw error
    }
}
