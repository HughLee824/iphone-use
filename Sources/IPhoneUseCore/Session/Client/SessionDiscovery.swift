import Foundation

/// Discover only the current user's selected state root. Never probe other users,
/// remove stale directories, restart hosts, or change an existing preview.
public enum SessionDiscovery {
    struct Candidate {
        let config: HostConfiguration
        let paths: SessionPaths
    }

    static func candidates(root: URL, device: String?) throws -> [Candidate] {
        let files = FileManager.default
        guard files.fileExists(atPath: root.path) else { return [] }
        try SessionPaths.secureDirectory(root)
        return try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).sorted {
            $0.path < $1.path
        }
        .compactMap { directory in
            let name = directory.lastPathComponent
            guard name.range(of: "^s[0-9a-f]{32}$", options: .regularExpression) != nil else { return nil }
            // secureDirectory also rejects symlinks, wrong owners and loose permissions.
            guard (try? SessionPaths.secureDirectory(directory)) != nil else { return nil }
            let paths = SessionPaths(directory: directory)
            guard let attributes = try? files.attributesOfItem(atPath: paths.config.path),
                attributes[.type] as? FileAttributeType == .typeRegular,
                let socket = try? files.attributesOfItem(atPath: paths.socket),
                socket[.type] as? FileAttributeType == .typeSocket,
                let data = try? Data(contentsOf: paths.config),
                let config = try? JSONDecoder().decode(HostConfiguration.self, from: data),
                config.session == name, device == nil || device == config.device
            else { return nil }
            return Candidate(config: config, paths: paths)
        }
    }

    public static func list(device: String? = nil) throws -> [String: Any] {
        let root = SessionPaths.stateRoot(environment: ProcessInfo.processInfo.environment)
        let sessions = try candidates(root: root, device: device).map { candidate -> [String: Any] in
            let response =
                (try? SessionClient.call(session: candidate.config.session, operation: "status", timeout: 3))
                ?? [:]
            let result = response["result"] as? [String: Any] ?? [:]
            var entry: [String: Any] = [
                "session": candidate.config.session, "device": candidate.config.device,
                "mode": candidate.config.modeSelection.mode.rawValue,
                "available": response["ok"] as? Bool == true,
                "directory": candidate.paths.directory.path
            ]
            entry["preview"] = result["preview"]
            entry["idleRemainingSeconds"] = response["idleRemainingSeconds"]
            entry["error"] = response["error"]
            return entry
        }
        return ["ok": true, "result": ["sessions": sessions, "stateDirectory": root.path]]
    }

    public static func reuse(
        device: String, mode: ControlMode, xctestrun: String? = nil,
        endpointInventory: String? = nil, previewPort: Int? = nil
    ) throws -> [String: Any]? {
        let root = SessionPaths.stateRoot(environment: ProcessInfo.processInfo.environment)
        let candidates = try candidates(root: root, device: device)
        return try reuse(
            candidates: candidates, mode: mode, xctestrun: xctestrun,
            endpointInventory: endpointInventory, previewPort: previewPort
        ) {
            try SessionClient.call(session: $0, operation: "status", timeout: 5)
        }
    }

    static func reuse(
        candidates: [Candidate], mode: ControlMode, xctestrun: String? = nil,
        endpointInventory: String? = nil, previewPort: Int? = nil,
        status: (String) throws -> [String: Any]
    ) throws -> [String: Any]? {
        guard !candidates.isEmpty else { return nil }
        guard candidates.count == 1 else {
            throw IPhoneUseError(
                "session_ambiguous",
                "Multiple session endpoints exist for this device; inspect sessions before continuing")
        }
        let candidate = candidates[0], config = candidate.config
        let requestedRunner = xctestrun.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        let requestedInventory = endpointInventory.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        guard config.modeSelection.mode == mode,
            requestedRunner == nil || requestedRunner == config.xctestrun,
            requestedInventory == nil || requestedInventory == config.nativeEndpointInventory
        else {
            throw IPhoneUseError(
                "session_configuration_conflict",
                """
                Existing session \(config.session) has different connection settings; reuse does not switch\
                 modes or restart it
                """
            )
        }
        var response = try status(config.session)
        guard response["ok"] as? Bool == true, response["session"] as? String == config.session,
            let result = response["result"] as? [String: Any]
        else {
            throw IPhoneUseError(
                "session_not_ready",
                "Existing session \(config.session) is unavailable; inspect its status before reconnecting")
        }
        guard (response["pendingOperationsAtRequest"] as? Int ?? 0) == 0 else {
            throw IPhoneUseError(
                "session_busy",
                """
                Existing session \(config.session) has work in progress; wait for that task to finish before\
                 continuing
                """
            )
        }
        try validateReuse(result, config: config, mode: mode, previewPort: previewPort)
        return reusedResponse(response, candidate: candidate)
    }

    private static func reusedResponse(_ original: [String: Any], candidate: Candidate) -> [String: Any] {
        var response = original
        let config = candidate.config
        response["reused"] = true
        response["device"] = config.device
        response["directory"] = candidate.paths.directory.path
        response["lifecycle"] = [
            "ownership": "borrowed", "disconnectOnFinish": false,
            "note":
                """
            Keep the existing connection and preview running unless the user explicitly requests disconnect.\
             Idle timeout is unchanged.
            """
        ]
        return response
    }
    private static func validateReuse(
        _ result: [String: Any], config: HostConfiguration,
        mode: ControlMode, previewPort: Int?
    ) throws {
        guard result["controlAvailable"] as? Bool != false,
            result["sessionClosing"] as? Bool != true,
            (result["connection"] as? [String: Any])?["requiresUserAction"] as? Bool != true,
            mode != .standard || result["controlAvailable"] as? Bool == true,
            mode != .runner || !(result["runnerSession"] as? String ?? "").isEmpty,
            (result["connection"] as? [String: Any])?["phase"] as? String == nil
                || (result["connection"] as? [String: Any])?["phase"] as? String == "ready"
        else {
            throw IPhoneUseError(
                "session_not_ready", "Existing session \(config.session) is not ready for control")
        }
        for key in ["touchPaste", "pasteboard"] {
            let transaction = result[key] as? [String: Any] ?? [:]
            guard transaction["restorePending"] as? Bool != true,
                transaction["writeUncertain"] as? Bool != true
            else {
                throw IPhoneUseError(
                    "session_transaction_pending",
                    "Finish the existing clipboard transaction in \(config.session) before reusing it")
            }
        }
        if let previewPort, let preview = result["preview"] as? [String: Any],
            let url = preview["url"] as? String, !url.isEmpty, preview["state"] as? String != "stopped",
            URL(string: url)?.port != previewPort {
            throw IPhoneUseError(
                "preview_already_running", "Existing preview keeps its URL; omit --port to reuse it")
        }
    }
}
