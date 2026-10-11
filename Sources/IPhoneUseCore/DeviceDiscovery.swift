import Foundation

// devicectl's JSON file is its supported programmatic interface. Never parse its display table.
enum CoreDevice {
    static func read(_ arguments: [String], savingTo output: URL? = nil,
                     cancelled: () -> Bool = { false }, trailingArguments: [String] = [], timeout: Int = 20) throws -> [String: Any] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("iphone-use-discovery-\(UUID().uuidString)")
        try SessionPaths.secureDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resultURL = output ?? directory.appendingPathComponent("result.json")
        let logURL = directory.appendingPathComponent("command.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = commandArguments(arguments, output: resultURL, trailingArguments: trailingArguments, timeout: timeout)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        let started = ProcessInfo.processInfo.systemUptime
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + Double(timeout) + 5
        while process.isRunning, !cancelled(), ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            let wasCancelled = cancelled()
            process.terminate()
            let stopDeadline = ProcessInfo.processInfo.systemUptime + 2
            while process.isRunning, ProcessInfo.processInfo.systemUptime < stopDeadline { Thread.sleep(forTimeInterval: 0.02) }
            let forcedKill = process.isRunning
            if forcedKill { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw IPhoneUseError(wasCancelled ? "coredevice_cancelled" : "coredevice_timeout", "CoreDevice process was cancelled or exceeded the host deadline",
                diagnostics: ["process": ["elapsedMs": (ProcessInfo.processInfo.systemUptime - started) * 1000,
                    "hostDeadlineUptime": deadline, "cancelledByCaller": wasCancelled,
                    "terminationRequested": true, "forcedKill": forcedKill, "processExited": true,
                    "exitStatus": process.terminationStatus]])
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            let failure = commandFailure(arguments, exitCode: process.terminationStatus, output: detail)
            throw IPhoneUseError(failure.code, failure.description, diagnostics: ["process": [
                "elapsedMs": (ProcessInfo.processInfo.systemUptime - started) * 1000,
                "terminationRequested": false, "forcedKill": false, "processExited": true,
                "exitStatus": process.terminationStatus]])
        }
        guard let result = try jsonObject(Data(contentsOf: resultURL))["result"] as? [String: Any] else {
            throw IPhoneUseError("invalid_discovery", "CoreDevice did not return a result object")
        }
        return result
    }

    // Launch treats everything after the bundle as application arguments. All tool options,
    // including JSON output and device selection, must precede that positional tail.
    static func commandArguments(_ arguments: [String], output: URL, trailingArguments: [String] = [], timeout: Int = 20) -> [String] {
        // Apple rejects tool timeouts below five seconds. The independent host
        // deadline and action preflight deadline still enforce the caller's budget.
        ["devicectl"] + arguments + ["--timeout", String(max(5, timeout)), "--quiet", "--json-output", output.path] + trailingArguments
    }

    static func commandFailure(_ arguments: [String], exitCode: Int32, output: String) -> IPhoneUseError {
        let operation = arguments.prefix { !$0.hasPrefix("--") }.joined(separator: " ")
        let detail = output.lowercased()
        let code: String
        let guidance: String
        if detail.contains("invalid active developer path") || detail.contains("invalid developer directory")
            || detail.contains("missing developer_dir path") || detail.contains("invalid developer_dir path")
            || detail.contains("unable to find utility \"devicectl\"")
            || detail.contains("requires xcode, but active developer directory") {
            code = "xcode_unavailable"
            guidance = "Install full Xcode with devicectl, finish its first-launch installation, and select it in Xcode Settings > Locations. "
                + "Command Line Tools alone are insufficient. Check xcode-select -p and any DEVELOPER_DIR override in this process. "
                + "Then retry read-only 'iphone-use devices'; standard mode does not require Runner setup or signing. "
        } else if detail.contains("license") && (detail.contains("have not agreed") || detail.contains("has not been accepted")) {
            code = "xcode_license_required"
            guidance = "Open Xcode and review its license and first-launch prompts yourself, then retry 'iphone-use devices'. "
        } else if detail.contains("operation not permitted") || detail.contains("permission denied") {
            code = "coredevice_access_denied"
            guidance = "Access was denied; check host execution permissions. If running in a restricted context, "
                + "retry read-only 'iphone-use devices' once with approved host permissions before retrying this operation. "
        } else if detail.contains("timed out waiting for coredeviceservice to fully initialize") {
            code = "coredevice_initialization_timeout"
            guidance = "This timeout does not establish that the device is disconnected or the service is broken. "
                + "A restricted host execution context can also cause it. If running in a sandbox, compare read-only "
                + "'iphone-use devices' once with approved host permissions before repeating failed commands or restarting services. "
        } else {
            code = "coredevice_failed"
            guidance = ""
        }
        return IPhoneUseError(code, "CoreDevice failed during '\(operation)' (exit \(exitCode)). \(guidance)Original error: \(output.suffix(4000))")
    }

    // Explain a failed native startup guard using reported facts only. Missing fields
    // must not be presented as proof that trust or Developer Mode is disabled.
    static func nativeDeviceUnavailable(_ details: [String: Any]) -> IPhoneUseError {
        let connection = details["connectionProperties"] as? [String: Any] ?? [:]
        let properties = details["deviceProperties"] as? [String: Any] ?? [:]
        if connection["pairingState"] as? String == "unpaired" {
            return IPhoneUseError("device_not_paired", "The selected device is unpaired. Connect it by USB, unlock it and complete the Trust This Computer prompt on the iPhone; then run 'iphone-use devices' and connect again. Standard mode does not need Runner setup.")
        }
        if properties["developerModeStatus"] as? String == "disabled" {
            return IPhoneUseError("developer_mode_disabled", "Apple reports Developer Mode disabled. Enable it on the iPhone in Settings > Privacy & Security > Developer Mode, complete the system prompts, unlock and connect again. Standard mode does not need Runner signing.")
        }
        return IPhoneUseError("native_device_unavailable", "Apple did not report all required physical-device, pairing, Developer Mode and CoreDevice tunnel facts. Check 'iphone-use devices', the selected device ID, USB connection and device authorization prompts, then connect again. Missing facts do not prove a permission denial; no Runner setup is required for standard mode.")
    }
}

public enum DeviceDiscovery {
    public static func devices() throws -> [[String: Any]] {
        try devices(from: CoreDevice.read(["list", "devices"]))
    }

    static func devices(from result: [String: Any]) throws -> [[String: Any]] {
        guard let devices = result["devices"] as? [[String: Any]] else {
            throw IPhoneUseError("invalid_discovery", "CoreDevice did not return a device list")
        }
        var rows: [[String: Any]] = []
        for device in devices {
            let hardware = device["hardwareProperties"] as? [String: Any] ?? [:]
            let properties = device["deviceProperties"] as? [String: Any] ?? [:]
            let connection = device["connectionProperties"] as? [String: Any] ?? [:]
            guard let id = (hardware["udid"] as? String) ?? (device["identifier"] as? String), !id.isEmpty else {
                throw IPhoneUseError("invalid_discovery", "CoreDevice returned a device without an identifier")
            }
            var row: [String: Any] = ["id": id]
            row["name"] = properties["name"] as? String ?? NSNull()
            row["osVersion"] = properties["osVersionNumber"] as? String ?? NSNull()
            row["platform"] = hardware["platform"] as? String ?? NSNull()
            row["deviceType"] = hardware["deviceType"] as? String ?? NSNull()
            let facts: [String: Any] = ["transport": connection["transportType"] as? String ?? NSNull(),
                "tunnelState": connection["tunnelState"] as? String ?? NSNull(),
                "pairingState": connection["pairingState"] as? String ?? NSNull()]
            row["connection"] = facts
            rows.append(row)
        }
        return rows.sorted { ($0["id"] as! String) < ($1["id"] as! String) }
    }
}

struct AppCatalog {
    private let apps: [[String: Any]]

    init(_ result: [String: Any]) throws {
        guard let source = result["apps"] as? [[String: Any]] else {
            throw IPhoneUseError("invalid_discovery", "CoreDevice did not return an installed app list")
        }
        apps = try source.map { app in
            guard let bundle = app["bundleIdentifier"] as? String, !bundle.isEmpty else {
                throw IPhoneUseError("invalid_discovery", "CoreDevice returned an app without a bundle identifier")
            }
            return ["bundleId": bundle, "name": app["name"] as? String ?? NSNull()] as [String: Any]
        }.sorted { ($0["bundleId"] as! String) < ($1["bundleId"] as! String) }
    }

    func requireInstalled(_ bundle: String) throws {
        guard apps.contains(where: { $0["bundleId"] as? String == bundle }) else {
            throw IPhoneUseError("app_not_installed", "CoreDevice did not list \(bundle) as installed; use apps to choose a bundle ID")
        }
    }

    func page(query: String?, offset: Int) throws -> [String: Any] {
        let matches = apps.filter { app in
            guard let query, !query.isEmpty else { return true }
            return [app["name"], app["bundleId"]].contains {
                ($0 as? String)?.range(of: query, options: .caseInsensitive) != nil
            }
        }
        guard offset >= 0, offset <= matches.count else {
            throw IPhoneUseError("invalid_offset", "App offset must be between 0 and \(matches.count)")
        }
        let end = min(matches.count, offset + 50)
        return ["apps": Array(matches[offset..<end]), "total": matches.count, "offset": offset,
                "nextOffset": end < matches.count ? end : NSNull()]
    }
}
