import Foundation

/// Independent of mode defaults so configuring preview never migrates or changes a backend.
public struct PreviewConfiguration {
    public static let defaultPort = 8765
    private struct Document: Codable {
        let version: Int
        let port: Int
    }
    private let directory: URL
    private var file: URL { directory.appendingPathComponent("preview.json") }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        if let path = environment["IPHONE_USE_CONFIG_DIR"] {
            guard path.hasPrefix("/"), !path.utf8.contains(0) else {
                throw IPhoneUseError("invalid_configuration_directory", "IPHONE_USE_CONFIG_DIR must be an absolute directory path")
            }
            directory = URL(fileURLWithPath: path).standardizedFileURL
        } else {
            directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".iphone-use")
        }
    }

    public static func validate(port: Int) throws -> UInt16 {
        guard (1024...65535).contains(port) else {
            throw IPhoneUseError("invalid_preview_port", "Preview port must be an integer from 1024 through 65535; port 0 (random allocation) is not supported")
        }
        return UInt16(port)
    }

    public func get() throws -> [String: Any] {
        let saved = try read()
        return ["port": saved ?? Self.defaultPort, "portSource": saved == nil ? "default" : "configuration",
                "configPath": file.path, "saved": saved != nil]
    }

    public func set(port: Int) throws -> [String: Any] {
        _ = try Self.validate(port: port)
        try SessionPaths.secureDirectory(directory)
        let lock = try DeviceLock(root: directory, device: "preview-configuration")
        defer { withExtendedLifetime(lock) {} }
        _ = try read() // Never overwrite malformed or newer configuration.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Document(version: 1, port: port)).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return ["port": port, "portSource": "configuration", "configPath": file.path,
                "saved": true, "appliesTo": "next_preview_start"]
    }

    /// Resolve at the calling CLI, rather than using the long-lived host's environment.
    public func startFields(port: Int?) throws -> [String: Any] {
        if let port { return ["port": Int(try Self.validate(port: port)), "portExplicit": true] }
        return ["port": try read() ?? Self.defaultPort, "portExplicit": false]
    }

    private func read() throws -> Int? {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: file.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return nil }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 65536 else {
            throw IPhoneUseError("invalid_configuration", "Preview configuration must be a regular JSON file of at most 64 KiB: \(file.path)")
        }
        do {
            let data = try Data(contentsOf: file)
            guard Set(try jsonObject(data).keys) == Set(["version", "port"]) else {
                throw IPhoneUseError("invalid_configuration", "Expected only version and port fields")
            }
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.version == 1 else { throw IPhoneUseError("invalid_configuration", "Unsupported preview configuration version") }
            _ = try Self.validate(port: document.port)
            return document.port
        } catch {
            throw IPhoneUseError("invalid_configuration", "Cannot read \(file.path): \(error). Repair the file or use preview --port PORT")
        }
    }
}

struct NativePreviewOptions {
    var port: UInt16 = UInt16(PreviewConfiguration.defaultPort)
    var explicitPort = false

    init(port: UInt16 = UInt16(PreviewConfiguration.defaultPort), explicitPort: Bool = false) {
        self.port = port; self.explicitPort = explicitPort
    }

    init(request: [String: Any]) throws {
        if let value = request["port"] {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let integer = value as? Int, number.doubleValue == Double(integer) else {
                throw IPhoneUseError("invalid_preview_port", "Preview port must be an integer from 1024 through 65535")
            }
            port = try PreviewConfiguration.validate(port: integer)
        }
        if let value = request["portExplicit"] {
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID(), request["port"] != nil else {
                throw IPhoneUseError("invalid_preview_port", "portExplicit must be a boolean accompanying port")
            }
            explicitPort = number.boolValue
        } else {
            explicitPort = request["port"] != nil
        }
    }
}
