import Foundation

struct PreviewOwner {
    let device: String
}

final class PreviewServiceClient {
    let directory: URL
    let port: UInt16
    private let authorization: String

    init(port: UInt16, directory: URL? = nil) throws {
        self.port = port
        let environment = ProcessInfo.processInfo.environment
        let config = environment["IPHONE_USE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".iphone-use")
        self.directory = directory ?? config.appendingPathComponent("previews/\(port)")
        guard self.directory.appendingPathComponent("ipc.sock").path.utf8.count < 104 else {
            throw IPhoneUseError("state_path_too_long", "Preview configuration path is too long for IPC")
        }
        try SessionPaths.secureDirectory(self.directory)
        // Serialize credential creation with service startup and other clients.
        let lock = try Self.startupLock(directory: self.directory)
        defer { withExtendedLifetime(lock) {} }
        authorization = try PreviewRegistry(directory: self.directory).authorization
    }

    func ensureRunning() throws {
        if (try? call("ping")) != nil { return }
        let lock = try Self.startupLock(directory: directory)
        defer { withExtendedLifetime(lock) {} }
        if try waitForService() { return }
        try launchService()
    }

    static func startupLock(directory: URL, timeout: TimeInterval = 15) throws -> DeviceLock {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            do { return try DeviceLock(root: directory, device: "startup") } catch {
                guard (error as? IPhoneUseError)?.code == "device_busy" else { throw error }
            }
            if ProcessInfo.processInfo.systemUptime >= deadline { break }
            Thread.sleep(forTimeInterval: 0.05)
        } while true
        throw IPhoneUseError("preview_service_busy", "Timed out waiting for another preview service startup")
    }

    // A failed ping does not prove the old daemon has exited. Its ownership lock
    // fences shutdown (including the stop response drain) before we spawn a replacement.
    private func waitForService() throws -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 6
        repeat {
            if (try? call("ping")) != nil { return true }
            do {
                let lock = try DeviceLock(root: directory, device: "service")
                withExtendedLifetime(lock) {}
                return false
            } catch {
                guard (error as? IPhoneUseError)?.code == "device_busy" else { throw error }
            }
            if ProcessInfo.processInfo.systemUptime >= deadline { break }
            Thread.sleep(forTimeInterval: 0.05)
        } while true
        throw IPhoneUseError("preview_service_busy", "Preview service is stopping or unresponsive; try again later")
    }

    private func launchService() throws {
        let errorURL = directory.appendingPathComponent("startup-error.json")
        try? FileManager.default.removeItem(at: errorURL)
        let logURL = directory.appendingPathComponent("service.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        let process = Process()
        process.executableURL = Bundle.main.executableURL
        process.arguments = ["_preview-service", "--directory", directory.path, "--port", String(port)]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = log; process.standardError = log
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + 6
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
            if (try? call("ping")) != nil { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning { process.terminate() } // Only the child launched by this attempt.
        if let data = try? Data(contentsOf: errorURL), let error = try? jsonObject(data) {
            throw IPhoneUseError(error["code"] as? String ?? "preview_service_failed",
                                 error["message"] as? String ?? "Preview service failed to start")
        }
        throw IPhoneUseError("preview_service_unavailable", "Cannot start preview service; see \(logURL.path)")
    }

    @discardableResult
    func call(_ operation: String, fields: [String: Any] = [:]) throws -> [String: Any] {
        var request = fields
        request["id"] = UUID().uuidString; request["version"] = 1
        request["authorization"] = authorization; request["op"] = operation
        let response = try JSONTransport.exchange(
            endpoint: .unix(path: directory.appendingPathComponent("ipc.sock").path), request: request, timeout: 2)
        guard response["ok"] as? Bool == true else {
            let error = response["error"] as? [String: Any] ?? [:]
            throw IPhoneUseError(error["code"] as? String ?? "preview_service_failed",
                                 error["message"] as? String ?? "Preview service rejected request")
        }
        return response
    }
}

public func revokePreview(device: String, port: Int?) throws -> [String: Any] {
    let fields = try PreviewConfiguration().startFields(port: port)
    let selectedPort = fields["port"] as? Int ?? PreviewConfiguration.defaultPort
    let client = try PreviewServiceClient(port: PreviewConfiguration.validate(port: selectedPort))
    try client.ensureRunning()
    try client.call("revoke", fields: ["device": device])
    return ["ok": true, "result": ["state": "revoked", "requiresPreviewRestart": true]]
}

public func stopPreviewService(port: Int?) throws -> [String: Any] {
    let fields = try PreviewConfiguration().startFields(port: port)
    let selectedPort = fields["port"] as? Int ?? PreviewConfiguration.defaultPort
    let client = try PreviewServiceClient(port: PreviewConfiguration.validate(port: selectedPort))
    try client.call("stop") // Never start a service merely to stop it.
    return ["ok": true, "result": ["state": "stop_requested", "port": selectedPort]]
}
