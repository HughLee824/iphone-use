import Foundation
import Network
import Darwin

public enum SessionClient {
    /// Compose existing host operations without replaying input or requiring a newer host protocol.
    public static func observing(session: String, action: [String: Any]) -> [String: Any] {
        observing(session: session, action: action) {
            try call(session: session, operation: "observe")
        }
    }

    static func observing(session: String, action: [String: Any], capture: () throws -> [String: Any]) -> [String: Any] {
        if action["session"] as? String == session, let observation = action["observation"] as? [String: Any] {
            return ["session": session, "ok": action["ok"] as? Bool == true && observation["ok"] as? Bool == true,
                    "action": action, "observation": observation]
        }
        let rejected = action["session"] as? String == session && action["ok"] as? Bool == false
            && action["outcome"] as? String == "not_dispatched"
            && (action["requiresObservation"] == nil || action["requiresObservation"] as? Bool == false)
        if rejected {
            return ["session": session, "ok": false, "action": action,
                    "observation": ["skipped": "not_dispatched"]]
        }
        let observation: [String: Any]
        do { observation = try capture() }
        catch {
            observation = ["session": session, "ok": false,
                "error": ["code": (error as? SomaError)?.code ?? "observation_failed", "message": String(describing: error)]]
        }
        return ["session": session, "ok": action["ok"] as? Bool == true && observation["ok"] as? Bool == true,
                "action": action, "observation": observation]
    }

    public static func connect(device: String, xctestrun: URL, idleTimeout: IdleTimeout) throws -> [String: Any] {
        guard FileManager.default.isReadableFile(atPath: xctestrun.path), xctestrun.pathExtension == "xctestrun" else {
            throw SomaError("runner_not_built", "Run build-runner, then provide its readable .xctestrun path using --xctestrun")
        }
        return try connect(device: device, runnerPath: xctestrun.path, backend: "xctest", idleTimeout: idleTimeout)
    }

    public static func connectNative(device: String, idleTimeout: IdleTimeout, endpointInventory: String? = nil) throws -> [String: Any] {
        try connect(device: device, runnerPath: "", backend: "apple-native", idleTimeout: idleTimeout,
                    endpointInventory: endpointInventory.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
    }

    private static func connect(device: String, runnerPath: String, backend: String, idleTimeout: IdleTimeout, endpointInventory: String? = nil) throws -> [String: Any] {
        umask(0o077)
        let session = "s" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let paths = try SessionPaths(session: session)
        try SessionPaths.secureDirectory(paths.directory)
        let config = HostConfiguration(session: session, device: device, xctestrun: runnerPath,
                                       idleTimeoutSeconds: idleTimeout.seconds, backend: backend, nativeEndpointInventory: endpointInventory)
        try JSONEncoder().encode(config).write(to: paths.config, options: .atomic)
        FileManager.default.createFile(atPath: paths.log.path, contents: nil)
        let log = try FileHandle(forWritingTo: paths.log)
        defer { try? log.close() }
        let host = Process()
        host.executableURL = Bundle.main.executableURL
        host.arguments = ["_host", "--directory", paths.directory.path]
        host.standardInput = FileHandle.nullDevice
        host.standardOutput = log
        host.standardError = log
        try host.run()
        let deadline = ProcessInfo.processInfo.systemUptime + 150
        while ProcessInfo.processInfo.systemUptime < deadline {
            let errorURL = paths.directory.appendingPathComponent("startup-error.json")
            if let data = try? Data(contentsOf: errorURL), let error = try? jsonObject(data) {
                host.waitUntilExit()
                throw SomaError(error["code"] as? String ?? "host_start_failed", error["message"] as? String ?? "Host startup failed")
            }
            guard host.isRunning else {
                throw SomaError("host_start_failed", "Session host exited; see \(paths.log.path)")
            }
            if let response = try? call(session: session, operation: "status", timeout: 4), response["ok"] as? Bool == true {
                var response = response
                response["directory"] = paths.directory.path
                return response
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        host.terminate()
        throw SomaError("connect_timeout", "Host did not become ready; cleanup requested. See \(paths.log.path)")
    }

    public static func call(session: String, operation: String, fields: [String: Any] = [:], timeout: TimeInterval = 75) throws -> [String: Any] {
        let paths = try SessionPaths(session: session)
        let id = UUID().uuidString
        var request = fields
        request["id"] = id
        request["version"] = 1
        request["session"] = session
        request["op"] = operation
        do {
            let response = try JSONTransport.exchange(endpoint: .unix(path: paths.socket), request: request, timeout: timeout)
            guard response["session"] as? String == session else {
                throw TransportError(description: "Response session does not match", possiblySent: true)
            }
            return response
        } catch {
            let uncertain = (error as? TransportError)?.possiblySent ?? false
            var response: [String: Any] = ["id": id, "session": session, "ok": false,
                "error": ["code": "session_unavailable", "message": String(describing: error)]]
            if ["open", "text-finish", "text-prepare", "type-with-method"].contains(operation) || DeviceAction.operations.contains(operation) {
                response["outcome"] = uncertain ? "unknown" : "not_dispatched"
            }
            if let data = try? Data(contentsOf: paths.config),
               let config = try? JSONDecoder().decode(HostConfiguration.self, from: data), config.backend == "apple-native" {
                NativeRecovery.enrich(&response, control: nil)
            }
            return response
        }
    }
}
