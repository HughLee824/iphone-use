import Foundation
import Network
import Darwin

// One daemon per configured port. Its private IPC admits sources; HTTP is strictly read-only.
final class PreviewService {
    let queue = DispatchQueue(label: "iphone-use.preview.service")
    let registry: PreviewRegistry
    private let requestedPort: UInt16
    var port: UInt16 { listener.port?.rawValue ?? requestedPort }
    let directory: URL
    let listener: NWListener
    var connections: [ObjectIdentifier: NWConnection] = [:]
    let session: URLSession
    var lastActivity = ProcessInfo.processInfo.systemUptime
    private(set) var isStopping = false // Access only on queue, including idle/signal shutdown.
    private var server: JSONServer?
    var onStop: (() -> Void)?

    init(directory: URL, port: UInt16) throws {
        self.directory = directory; self.requestedPort = port
        registry = try PreviewRegistry(directory: directory)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: parameters)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false; configuration.timeoutIntervalForRequest = 2
        configuration.connectionProxyDictionary = [:]
        session = URLSession(configuration: configuration, delegate: PreviewNoRedirect(), delegateQueue: nil)
    }

    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        var failure: NWError?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error), .waiting(let error): failure = error; ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 4) == .success, failure == nil else {
            listener.cancel()
            if let failure, case .posix(.EADDRINUSE) = failure {
                throw IPhoneUseError("preview_port_in_use", "Preview port \(port) is occupied; no process was stopped")
            }
            throw IPhoneUseError(
                "preview_listen_failed", "Cannot open preview listener: \(String(describing: failure))")
        }
        let socket = directory.appendingPathComponent("ipc.sock").path
        try? FileManager.default.removeItem(atPath: socket)
        let server = try JSONServer(path: socket); self.server = server
        server.onRequest = { [weak self] request, reply in
            guard let self else { return }
            self.queue.async {
                let response = self.control(request)
                reply(response) {
                    if request["op"] as? String == "stop", response["ok"] as? Bool == true { self.onStop?() }
                }
            }
        }
        server.start { ready.signal() }
        guard ready.wait(timeout: .now() + 4) == .success else {
            stop(); throw IPhoneUseError("preview_service_unavailable", "Preview IPC did not start")
        }
    }

    func stop() {
        queue.sync { beginStopping() }
        listener.cancel(); server?.stopAccepting(); session.invalidateAndCancel()
        queue.sync { connections.values.forEach { $0.cancel() }; connections.removeAll() }
    }

    func beginStopping() { isStopping = true }

    func stopIfIdle(now: Double) {
        guard !isStopping, now - lastActivity > 600 else { return }
        beginStopping()
        onStop?()
    }

    private func admit(_ request: [String: Any]) throws {
        guard request["authorization"] as? String == registry.authorization,
            request["version"] as? Int == 1 else {
            throw IPhoneUseError("preview_service_unauthorized", "Invalid preview service credential or version")
        }
        guard !isStopping else {
            throw IPhoneUseError("preview_service_stopping", "Preview service is stopping; wait for it to exit")
        }
        lastActivity = ProcessInfo.processInfo.systemUptime
    }

    func control(_ request: [String: Any]) -> [String: Any] {
        var response: [String: Any] = ["id": request["id"] ?? NSNull(), "ok": false]
        do {
            try admit(request)
            if ["ping", "stop"].contains(request["op"] as? String ?? "") {
                if request["op"] as? String == "stop" {
                    beginStopping()
                    response["state"] = "stop_requested"; response["pid"] = Int(getpid())
                }
                response["ok"] = true; return response
            }
            guard let device = request["device"] as? String else {
                throw IPhoneUseError("invalid_device_id", "Expected hardware UDID")
            }
            let owner = request["owner"] as? String ?? ""
            switch request["op"] as? String {
            case "attach":
                let entry = try registry.attach(
                    device: device, owner: owner, url: request["url"] as? String ?? "", now: lastActivity)
                response["url"] = "http://127.0.0.1:\(port)/v/\(entry.token)/"
            case "renew": try registry.renew(device: device, owner: owner, now: lastActivity)
            case "detach": registry.detach(device: device, owner: owner)
            case "revoke": try registry.revoke(device: device)
            default: throw IPhoneUseError("invalid_request", "Unknown preview service operation")
            }
            response["ok"] = true
        } catch {
            response["error"] = ["code": (error as? IPhoneUseError)?.code ?? "preview_service_failed",
                                 "message": String(describing: error)]
        }
        return response
    }
}

private final class PreviewNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) { completionHandler(nil) }
}

public func runPreviewService(directory: URL, port: Int) throws {
    do { try servePreview(directory: directory, port: port) } catch {
        try? saveJSON(["code": (error as? IPhoneUseError)?.code ?? "preview_service_failed",
                       "message": String(describing: error)],
                      to: directory.appendingPathComponent("startup-error.json"))
        throw error
    }
}

private func servePreview(directory: URL, port: Int) throws {
    umask(0o077)
    try SessionPaths.secureDirectory(directory)
    let lock = try DeviceLock(root: directory, device: "service")
    let service = try PreviewService(directory: directory, port: PreviewConfiguration.validate(port: port))
    let done = DispatchSemaphore(value: 0)
    service.onStop = { done.signal() }
    try service.start()
    defer { service.stop(); withExtendedLifetime(lock) {} }
    let signalQueue = DispatchQueue(label: "iphone-use.preview.signals")
    let signals = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: signalQueue)
        source.setEventHandler {
            service.queue.async { service.beginStopping(); done.signal() }
        }
        source.resume(); return source
    }
    let timer = DispatchSource.makeTimerSource(queue: service.queue)
    timer.schedule(deadline: .now() + 60, repeating: 60)
    timer.setEventHandler {
        service.stopIfIdle(now: ProcessInfo.processInfo.systemUptime)
    }
    timer.resume(); done.wait(); timer.cancel(); signals.forEach { $0.cancel() }
}
