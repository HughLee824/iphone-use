import Foundation
import Darwin

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
