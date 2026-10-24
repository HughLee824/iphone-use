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
    private var server: JSONServer?

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
            if case .ready = state { ready.signal() }
            if case .failed(let error) = state { failure = error; ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 4) == .success, failure == nil else {
            listener.cancel()
            throw IPhoneUseError("preview_port_in_use", "Cannot bind preview port \(port); no process was stopped")
        }
        let socket = directory.appendingPathComponent("ipc.sock").path
        try? FileManager.default.removeItem(atPath: socket)
        let server = try JSONServer(path: socket); self.server = server
        server.onRequest = { [weak self] request, reply in
            guard let self else { return }
            self.queue.async { reply(self.control(request), {}) }
        }
        server.start { ready.signal() }
        guard ready.wait(timeout: .now() + 4) == .success else {
            stop(); throw IPhoneUseError("preview_service_unavailable", "Preview IPC did not start")
        }
    }

    func stop() {
        listener.cancel(); server?.stopAccepting(); session.invalidateAndCancel()
        queue.sync { connections.values.forEach { $0.cancel() }; connections.removeAll() }
    }

    func control(_ request: [String: Any]) -> [String: Any] {
        var response: [String: Any] = ["id": request["id"] ?? NSNull(), "ok": false]
        do {
            guard request["authorization"] as? String == registry.authorization,
                request["version"] as? Int == 1 else {
                throw IPhoneUseError("preview_service_unauthorized", "Invalid preview service credential or version")
            }
            let now = ProcessInfo.processInfo.systemUptime
            lastActivity = now
            if request["op"] as? String == "ping" { response["ok"] = true; return response }
            guard let device = request["device"] as? String else {
                throw IPhoneUseError("invalid_device_id", "Expected hardware UDID")
            }
            let owner = request["owner"] as? String ?? ""
            switch request["op"] as? String {
            case "attach":
                let entry = try registry.attach(
                    device: device, owner: owner, url: request["url"] as? String ?? "", now: now)
                response["url"] = "http://127.0.0.1:\(port)/v/\(entry.token)/"
            case "renew": try registry.renew(device: device, owner: owner, now: now)
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
    try service.start()
    defer { service.stop(); withExtendedLifetime(lock) {} }
    let done = DispatchSemaphore(value: 0)
    let signalQueue = DispatchQueue(label: "iphone-use.preview.signals")
    let signals = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: signalQueue)
        source.setEventHandler { done.signal() }; source.resume(); return source
    }
    let timer = DispatchSource.makeTimerSource(queue: service.queue)
    timer.schedule(deadline: .now() + 60, repeating: 60)
    timer.setEventHandler {
        if ProcessInfo.processInfo.systemUptime - service.lastActivity > 600 { done.signal() }
    }
    timer.resume(); done.wait(); timer.cancel(); signals.forEach { $0.cancel() }
}
