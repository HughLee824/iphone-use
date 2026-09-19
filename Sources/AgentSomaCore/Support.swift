import Foundation
import Darwin

public struct SomaError: Error, CustomStringConvertible {
    public let code: String
    public let description: String

    public init(_ code: String, _ description: String) {
        self.code = code
        self.description = description
    }
}

public func jsonData(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
}

func jsonObject(_ data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw SomaError("invalid_message", "Expected a JSON object")
    }
    return object
}

func saveJSON(_ object: [String: Any], to url: URL) throws {
    try jsonData(object).write(to: url, options: .atomic)
}

public struct IdleTimeout: Equatable {
    public let seconds: TimeInterval

    public init(_ value: String) throws {
        let multiplier: Double
        switch value.last {
        case "s": multiplier = 1
        case "m": multiplier = 60
        case "h": multiplier = 3600
        default: throw SomaError("invalid_idle_timeout", "Use a positive duration such as 30m, 60m or 10s")
        }
        guard let number = Double(value.dropLast()), number.isFinite, number > 0,
              (number * multiplier).isFinite else {
            throw SomaError("invalid_idle_timeout", "Idle timeout must be positive and finite")
        }
        seconds = number * multiplier
    }
}

struct HostConfiguration: Codable {
    let session: String
    let device: String
    let xctestrun: String
    let idleTimeoutSeconds: TimeInterval
    var backend: String? = nil
    var nativeEndpointInventory: String? = nil
}

public struct SessionPaths {
    public let directory: URL
    var socket: String { directory.appendingPathComponent("ipc.sock").path }
    var config: URL { directory.appendingPathComponent("config.json") }
    var log: URL { directory.appendingPathComponent("host.log") }
    var exit: URL { directory.appendingPathComponent("exit.json") }

    public init(session: String) throws {
        guard session.range(of: "^s[0-9a-f]{32}$", options: .regularExpression) != nil else {
            throw SomaError("invalid_session", "Use the session identifier returned by connect")
        }
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["AGENTSOMA_STATE_DIR"]
                       ?? "/private/tmp/agentsoma-\(getuid())", isDirectory: true).standardizedFileURL
        try Self.secureDirectory(root)
        directory = root.appendingPathComponent(session, isDirectory: true)
        guard socket.utf8.count < 104 else {
            throw SomaError("state_path_too_long", "AGENTSOMA_STATE_DIR is too long for a Unix socket")
        }
    }

    init(directory: URL) { self.directory = directory }

    static func secureDirectory(_ url: URL) throws {
        let files = FileManager.default
        if !files.fileExists(atPath: url.path) {
            try files.createDirectory(at: url, withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
        }
        let attributes = try files.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else {
            throw SomaError("unsafe_state_directory", "Session directory must be owned by this user with mode 0700: \(url.path)")
        }
    }
}

// One host owns one device. The kernel releases this lock even if the host crashes.
// Keep the inode: unlinking a lock file can let two hosts lock different inodes.
final class DeviceLock {
    private let descriptor: Int32

    init(root: URL, device: String) throws {
        guard device.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil else {
            throw SomaError("invalid_device_id", "CoreDevice returned an invalid UDID")
        }
        let path = root.appendingPathComponent("device-\(device).lock").path
        descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw SomaError("device_lock_failed", "Cannot open device lock") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw SomaError("device_busy", "This device already has an AgentSoma session")
        }
    }

    deinit { Darwin.close(descriptor) }
}
