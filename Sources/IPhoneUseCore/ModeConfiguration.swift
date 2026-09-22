import Foundation

public enum ControlMode: String, Codable {
    case standard, runner

    public var backend: String { self == .standard ? "apple-native" : "xctest" }

    /// Implemented command forms, independent of transient device/service readiness.
    var support: [String: Any] {
        let common = ["status", "apps", "open", "observe", "inspect", "tap", "swipe", "type", "press", "disconnect"]
        if self == .standard {
            return ["operations": common + ["double-tap", "long-press", "pinch", "home", "terminate", "relaunch",
                                            "text-prepare", "text-finish", "record-start", "record-stop"],
                    "observationSources": ["screenshot"],
                    "actionTargets": ["tap": ["screen_point"], "swipe": ["screen_path"],
                                      "type": ["visually_focused_input"], "press": ["visually_focused_input"]],
                    "textModes": ["insert", "replace", "append"], "textMethods": ["auto", "keys", "paste"],
                    "pressKeys": NativePressKey.allCases.map(\.rawValue)]
        }
        return ["operations": common, "observationSources": ["screenshot", "available_elements"],
                "actionTargets": ["tap": ["screen_point", "element"], "swipe": ["screen_path", "element"],
                                  "type": ["element"], "press": ["element"]],
                "textModes": ["insert", "replace", "append"], "textMethods": [String](), "pressKeys": ["return"]]
    }

    static func parse(_ value: String) throws -> ControlMode {
        guard let mode = ControlMode(rawValue: value) else {
            throw IPhoneUseError("invalid_mode", "Use mode standard or runner")
        }
        return mode
    }
}

public struct ModeSelection {
    public let mode: ControlMode
    public let source: String

    public var result: [String: Any] {
        ["mode": mode.rawValue, "backend": mode.backend, "modeSource": source]
    }
}

/// User preference is resolved once, before starting a host. Running hosts never read it.
public struct ModeConfiguration {
    private struct Document: Codable {
        let version: Int
        let mode: ControlMode
    }
    private let directory: URL
    private let legacyRunner: () throws -> Bool
    private let legacyDirectory: URL?
    private var file: URL { directory.appendingPathComponent("config.json") }

    public init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.init(directory: home.appendingPathComponent(".iphone-use"),
                  legacyDirectory: home.appendingPathComponent(".agentsoma"),
                  legacyRunner: { try RunnerSetup.hasValidLegacyConfiguration() })
    }

    init(directory: URL, legacyDirectory: URL? = nil, legacyRunner: @escaping () throws -> Bool) {
        self.directory = directory
        self.legacyDirectory = legacyDirectory
        self.legacyRunner = legacyRunner
    }

    /// Explicit options neither read nor modify defaults, including during migration.
    public func select(mode: String?, backend: String?, xctestrun: String?, nativeEndpointInventory: String?) throws -> ModeSelection {
        var choices: [(ControlMode, String)] = []
        if let mode { choices.append((try ControlMode.parse(mode), "command_line_mode")) }
        if let backend {
            guard ["apple-native", "xctest"].contains(backend) else {
                throw IPhoneUseError("unsupported_backend", "Use --backend apple-native or xctest, or --mode standard or runner")
            }
            choices.append((backend == "apple-native" ? .standard : .runner, "command_line_backend"))
        }
        if xctestrun != nil { choices.append((.runner, "command_line_xctestrun")) }
        if nativeEndpointInventory != nil { choices.append((.standard, "command_line_native_endpoint_inventory")) }
        if let first = choices.first {
            guard choices.allSatisfy({ $0.0 == first.0 }) else {
                throw IPhoneUseError("mode_conflict", "Conflicting mode/backend options: standard uses apple-native; runner uses xctest and --xctestrun")
            }
            return ModeSelection(mode: first.0, source: first.1)
        }
        return try defaults(persist: true)
    }

    public func get() throws -> [String: Any] {
        var result = try defaults(persist: false).result
        result["configPath"] = file.path
        result["saved"] = FileManager.default.fileExists(atPath: file.path)
        return result
    }

    public func set(mode: String) throws -> [String: Any] {
        let mode = try ControlMode.parse(mode)
        try SessionPaths.secureDirectory(directory)
        let lock = try configurationLock()
        defer { withExtendedLifetime(lock) {} }
        _ = try read() // Do not overwrite malformed or newer configuration formats.
        try write(mode)
        return ["mode": mode.rawValue, "backend": mode.backend, "configPath": file.path,
                "saved": true, "appliesTo": "new_sessions"]
    }

    private func defaults(persist: Bool) throws -> ModeSelection {
        if persist {
            try SessionPaths.secureDirectory(directory)
            let lock = try configurationLock()
            defer { withExtendedLifetime(lock) {} }
            if let mode = try read() { return ModeSelection(mode: mode, source: "configuration") }
            let selection = try initialSelection()
            try write(selection.mode)
            return selection
        }
        if let mode = try read() { return ModeSelection(mode: mode, source: "configuration") }
        return try initialSelection()
    }

    private func initialSelection() throws -> ModeSelection {
        if let legacyDirectory,
           let mode = try ModeConfiguration(directory: legacyDirectory, legacyRunner: { false }).read() {
            return ModeSelection(mode: mode, source: "legacy_configuration_migration")
        }
        let legacy = try legacyRunner()
        return ModeSelection(mode: legacy ? .runner : .standard,
                             source: legacy ? "legacy_runner_migration" : "default")
    }

    private func read() throws -> ControlMode? {
        let files = FileManager.default
        // attributesOfItem also detects dangling symlinks; missing is distinct from unreadable.
        let attributes: [FileAttributeKey: Any]
        do { attributes = try files.attributesOfItem(atPath: file.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return nil }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 65536 else {
            throw IPhoneUseError("invalid_configuration", "Configuration must be a regular JSON file of at most 64 KiB: \(file.path)")
        }
        do {
            let data = try Data(contentsOf: file)
            let object = try jsonObject(data)
            guard Set(object.keys) == Set(["version", "mode"]) else {
                throw IPhoneUseError("invalid_configuration", "Expected configuration version 1 with only version and mode fields")
            }
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.version == 1 else { throw IPhoneUseError("invalid_configuration", "Unsupported configuration version") }
            return document.mode
        } catch {
            throw IPhoneUseError("invalid_configuration", "Cannot read \(file.path): \(error). Repair the file; no backend was selected")
        }
    }

    private func write(_ mode: ControlMode) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Document(version: 1, mode: mode)).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func configurationLock() throws -> DeviceLock {
        do { return try DeviceLock(root: directory, device: "configuration") }
        catch { throw IPhoneUseError("configuration_busy", "Cannot lock mode configuration; another configuration operation may be active: \(error)") }
    }
}
