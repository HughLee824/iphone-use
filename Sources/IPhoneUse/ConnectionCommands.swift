import ArgumentParser
import IPhoneUseCore
import Foundation

struct BuildRunner: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build-runner",
        abstract: "Build and verify the signed Runner using Xcode; return its .xctestrun path.")
    @Option(help: "iPhone-use source checkout; defaults to the current directory.") var sourceRoot = "."
    @Option(help: "Apple development team ID; omit to use the Runner project's signing settings.") var team: String?
    @Option(help: "Runner test bundle ID; omit to use the Runner project's signing settings.") var bundleID: String?

    mutating func run() throws {
        try output {
            [
                "ok": true,
                "result": try RunnerBuild.build(
                    sourceRoot: URL(fileURLWithPath: sourceRoot), team: team, bundleID: bundleID)
            ]
        }
    }
}

struct Connect: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start a device session; standard needs no Runner setup or signing.",
        discussion:
            """
            Use devices to select a paired, unlocked iPhone with Developer Mode enabled. Both modes require\
             full Xcode. Standard currently targets macOS/iOS 27. Check result.controlAvailable before\
             standard-mode input; ok:true may describe an observation-only session. Use --mode runner\
             explicitly for XCTest; modes never switch automatically.
            """
    )
    @Option(help: "Connected iPhone UDID or CoreDevice identifier.") var device: String
    @Option(
        help:
            """
            Runner source workflow: explicit signed .xctestrun. Packaged Runner users run setup once, then\
             omit this option.
            """
    ) var xctestrun: String?
    @Option(help: "Idle duration, such as 30m, 60m or 10s.") var idleTimeout = "30m"
    @Flag(
        help:
            """
            Reuse an existing healthy session for this device and mode, or connect if none exists. Preserves\
             its preview and timeout; reused sessions must not be disconnected automatically at task completion.
            """
    ) var reuse = false
    @Option(
        help:
            """
            standard (screenshot/HID, no Runner setup) or runner (XCTest). Omit to use saved preferences;\
             fresh users default to standard.
            """
    ) var mode: String?
    @Option(
        help:
            "Compatibility option: apple-native = standard; xctest = runner. Conflicting options are rejected."
    )
    var backend: String?
    @Option(
        help:
            """
            Diagnostic override: a recent Apple netstat -anvl -p tcp file selects direct RSD discovery. Native\
             connections normally use CoreDevice service sockets.
            """
    ) var nativeEndpointInventory: String?

    @Flag(
        help:
            """
            Emit connection_progress JSON lines immediately, followed by the final JSON result. Agents should\
             relay requiresUserAction messages while the command is pending.
            """
    ) var progress = false
    @Flag(
        help:
            """
            Runner only: start the local preview and independent CoreDevice video before Runner authorization.\
             Requires --progress; never opens a browser automatically.
            """
    ) var preview = false
    @Option(help: "Port for --preview; otherwise use the saved preview port (default 8765).") var port: Int?

    mutating func run() throws {
        try output {
            let timeout = try IdleTimeout(idleTimeout)
            let selection = try ModeConfiguration().select(
                mode: mode, backend: backend, xctestrun: xctestrun,
                nativeEndpointInventory: nativeEndpointInventory)
            guard !preview || (progress && selection.mode == .runner) else {
                throw ValidationError("connect --preview requires --progress and Runner mode")
            }
            guard port == nil || preview else { throw ValidationError("connect --port requires --preview") }
            let previewPort =
                preview ? try PreviewConfiguration().startFields(port: port)["port"] as? Int : nil
            let report: (([String: Any]) -> Void)? =
                progress
                ? { value in
                    if var data = try? jsonData(value) {
                        data.append(10); FileHandle.standardOutput.write(data)
                    }
                } : nil
            if reuse,
                let existing = try SessionDiscovery.reuse(
                    device: device, mode: selection.mode,
                    xctestrun: xctestrun, endpointInventory: nativeEndpointInventory, previewPort: port) {
                return existing
            }
            if selection.mode == .standard {
                return try SessionClient.connectNative(
                    device: device, idleTimeout: timeout, endpointInventory: nativeEndpointInventory,
                    modeSource: selection.source)
            }
            if let xctestrun {
                return try SessionClient.connect(
                    device: device,
                    xctestrun: URL(fileURLWithPath: xctestrun).standardizedFileURL,
                    idleTimeout: timeout, modeSource: selection.source, previewPort: previewPort,
                    onProgress: report)
            }
            return try RunnerSetup.connect(
                device: device, idleTimeout: timeout, modeSource: selection.source, previewPort: previewPort,
                onProgress: report)
        }
    }
}

struct Configuration: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract:
            """
            Read or set defaults in ~/.iphone-use/ (IPHONE_USE_CONFIG_DIR overrides the directory without\
             Runner mode inference).
            """,
        subcommands: [Get.self, Set.self])
    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Read an effective default without creating configuration or connecting a device.")
        @Argument(help: "Configuration key: mode or preview-port.") var key: String
        mutating func run() throws {
            try output {
                switch key {
                case "mode": return ["ok": true, "result": try ModeConfiguration().get()]
                case "preview-port": return ["ok": true, "result": try PreviewConfiguration().get()]
                default: throw ValidationError("Supported configuration keys: mode, preview-port")
                }
            }
        }
    }
    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract:
                "Save a default; existing sessions keep their backend and running previews keep their port.")
        @Argument(help: "Configuration key: mode or preview-port.") var key: String
        @Argument(help: "standard/runner for mode; 1024...65535 for preview-port (default 8765).") var value: String
        mutating func run() throws {
            try output {
                switch key {
                case "mode": return ["ok": true, "result": try ModeConfiguration().set(mode: value)]
                case "preview-port":
                    guard let port = Int(value) else {
                        throw IPhoneUseError(
                            "invalid_preview_port", "Preview port must be an integer from 1024 through 65535")
                    }
                    return ["ok": true, "result": try PreviewConfiguration().set(port: port)]
                default: throw ValidationError("Supported configuration keys: mode, preview-port")
                }
            }
        }
    }
}

struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract:
            """
            Runner mode only: re-sign and verify this release's precompiled Runner. Standard mode does not\
             need setup. Does not change the default mode.
            """
    )
    @Option(help: "Connected iPhone UDID or CoreDevice identifier.") var device: String
    @Option(help: "iOS development .mobileprovision file; otherwise use saved or matching Xcode profiles.")
    var profile: String?
    @Option(help: "Apple Development signing certificate SHA-1; required only when selection is ambiguous.")
    var identity: String?
    @Option(help: "Apple development team ID to select.") var team: String?
    @Option(help: "Runner app's bundle ID on iPhone; saved for subsequent setup and connections.")
    var bundleID: String?

    mutating func run() throws {
        try output {
            [
                "ok": true,
                "result": try RunnerSetup.setup(
                    device: device, profile: profile, identity: identity, team: team, bundleID: bundleID)
            ]
        }
    }
}

struct Devices: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List devices known to CoreDevice; connect checks session readiness.")
    mutating func run() throws {
        try output { ["ok": true, "result": ["devices": try DeviceDiscovery.devices()]] }
    }
}

struct Sessions: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract:
            """
            Discover existing sessions in the current user's state directory without changing device UI or preview.
            """)
    @Option(help: "Filter by the device ID used to connect.") var device: String?
    mutating func run() throws {
        try output { try SessionDiscovery.list(device: device) }
    }
}
