import Foundation
import Darwin

// Use only for internal values whose type was established by an earlier validation
// step. A violation is a programming error, rather than a recoverable device error.
func validatedValue<Value>(_ value: Any?, as type: Value.Type) -> Value {
    guard let value = value as? Value else {
        preconditionFailure("Previously validated value must have type \(type)")
    }
    return value
}

public struct IPhoneUseError: Error, CustomStringConvertible {
    public let code: String
    public let description: String
    public let diagnostics: [String: Any]

    public init(_ code: String, _ description: String, diagnostics: [String: Any] = [:]) {
        self.code = code
        self.description = description
        self.diagnostics = diagnostics
    }
}

public func jsonData(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
}

func jsonObject(_ data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw IPhoneUseError("invalid_message", "Expected a JSON object")
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
        default:
            throw IPhoneUseError("invalid_idle_timeout", "Use a positive duration such as 30m, 60m or 10s")
        }
        guard let number = Double(value.dropLast()), number.isFinite, number > 0,
            (number * multiplier).isFinite
        else {
            throw IPhoneUseError("invalid_idle_timeout", "Idle timeout must be positive and finite")
        }
        seconds = number * multiplier
    }
}

struct HostConfiguration: Codable {
    let session: String
    let device: String
    let xctestrun: String
    let idleTimeoutSeconds: TimeInterval
    var backend: String?
    var nativeEndpointInventory: String?
    var modeSource: String?
    var startupPreviewPort: Int?

    var modeSelection: ModeSelection {
        ModeSelection(
            mode: backend == "apple-native" ? .standard : .runner,
            source: modeSource ?? "legacy_session")
    }
}

public struct SessionPaths {
    public let directory: URL
    var socket: String { directory.appendingPathComponent("ipc.sock").path }
    var config: URL { directory.appendingPathComponent("config.json") }
    var log: URL { directory.appendingPathComponent("host.log") }
    var exit: URL { directory.appendingPathComponent("exit.json") }

    public init(session: String) throws {
        guard session.range(of: "^s[0-9a-f]{32}$", options: .regularExpression) != nil else {
            throw IPhoneUseError("invalid_session", "Use the session identifier returned by connect")
        }
        let root = Self.stateRoot(environment: ProcessInfo.processInfo.environment)
        try Self.secureDirectory(root)
        directory = root.appendingPathComponent(session, isDirectory: true)
        guard socket.utf8.count < 104 else {
            throw IPhoneUseError("state_path_too_long", "IPHONE_USE_STATE_DIR is too long for a Unix socket")
        }
    }

    static var defaultRoot: URL {
        URL(fileURLWithPath: "/private/tmp/iphone-use-\(getuid())", isDirectory: true)
    }

    static func stateRoot(environment: [String: String]) -> URL {
        environment["IPHONE_USE_STATE_DIR"].map { URL(fileURLWithPath: $0).standardizedFileURL }
            ?? defaultRoot
    }

    init(directory: URL) { self.directory = directory }

    static func secureDirectory(_ url: URL) throws {
        let files = FileManager.default
        if !files.fileExists(atPath: url.path) {
            try files.createDirectory(
                at: url, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        let attributes = try files.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
            (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
            (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700
        else {
            throw IPhoneUseError(
                "unsafe_state_directory",
                "Session directory must be owned by this user with mode 0700: \(url.path)")
        }
    }
}

// One host owns one device. The kernel releases this lock even if the host crashes.
// Keep the inode: unlinking a lock file can let two hosts lock different inodes.
final class DeviceLock {
    private let descriptor: Int32

    init(root: URL, device: String) throws {
        guard device.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil else {
            throw IPhoneUseError("invalid_device_id", "CoreDevice returned an invalid UDID")
        }
        let path = root.appendingPathComponent("device-\(device).lock").path
        descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw IPhoneUseError("device_lock_failed", "Cannot open device lock") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw IPhoneUseError("device_busy", "This device already has an iPhone-use session")
        }
    }

    deinit { Darwin.close(descriptor) }
}

// Hold the default-root lock as well as any selected-root lock so environment
// overrides cannot let separate sessions control the same device.
final class SessionDeviceLock {
    private let locks: [DeviceLock]

    init(root: URL, device: String) throws {
        let defaultRoot = SessionPaths.defaultRoot
        try SessionPaths.secureDirectory(defaultRoot)
        var held = [try DeviceLock(root: defaultRoot, device: device)]
        if root.resolvingSymlinksInPath() != defaultRoot.resolvingSymlinksInPath() {
            held.append(try DeviceLock(root: root, device: device))
        }
        locks = held
    }
}
