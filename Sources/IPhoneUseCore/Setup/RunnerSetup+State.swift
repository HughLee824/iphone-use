import Foundation

extension RunnerSetup {

    static func validate(_ record: PreparedRunner, package: RunnerPackage, root: URL, now: Date = Date())
        throws {
        guard record.formatVersion == 1, UUID(uuidString: record.directory) != nil else {
            throw IPhoneUseError("setup_state_invalid", "Invalid prepared Runner state; run setup again")
        }
        guard record.packageDigest == package.digest, record.runnerVersion == package.manifest.runnerVersion
        else {
            throw IPhoneUseError(
                "setup_update_required",
                "This release requires a different Runner package; run iphone-use setup --device \(record.device)"
            )
        }
        guard record.profileExpires > now else {
            throw IPhoneUseError(
                "profile_expired",
                "Runner provisioning expired; renew the profile in Xcode and run setup again")
        }
        guard record.files["Runner.xctestrun"] != nil,
            (try? RunnerPackage.inventory(root.appendingPathComponent("prepared/\(record.directory)")))
                == record.files
        else {
            throw IPhoneUseError(
                "setup_state_invalid", "Prepared Runner files are missing or changed; run setup again")
        }
    }

    /// Local-only migration: certificates or Xcode alone never select Runner.
    static func hasValidLegacyConfiguration(
        root: URL = stateDirectory,
        package: () throws -> RunnerPackage = { try RunnerPackage.installed() }
    ) throws -> Bool {
        let devices = root.appendingPathComponent("devices")
        let records =
            FileManager.default.fileExists(atPath: devices.path)
            ? try FileManager.default.contentsOfDirectory(at: devices, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" } : []
        guard !records.isEmpty else { return false }
        do {
            let package = try package()
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            for path in records {
                guard let data = try? Data(contentsOf: path),
                    let record = try? decoder.decode(PreparedRunner.self, from: data),
                    path.lastPathComponent == "\(RunnerPackage.hash(Data(record.device.utf8))).json",
                    (try? validate(record, package: package, root: root)) != nil
                else { continue }
                return true
            }
        } catch {
            throw IPhoneUseError(
                "mode_selection_required",
                """
                Existing Runner setup cannot be validated: \(error). Choose with config set mode runner or\
                 config set mode standard
                """
            )
        }
        throw IPhoneUseError(
            "mode_selection_required",
            """
            Existing Runner records are expired, incomplete or incompatible. Choose with config set mode\
             runner or config set mode standard; no automatic switch
            """
        )
    }

    static func readRecord(device: String, root: URL) throws -> PreparedRunner {
        let path = root.appendingPathComponent("devices/\(RunnerPackage.hash(Data(device.utf8))).json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: path),
            let record = try? decoder.decode(PreparedRunner.self, from: data),
            record.device == device, UUID(uuidString: record.directory) != nil
        else {
            throw IPhoneUseError(
                "setup_required",
                """
                Run iphone-use setup --device \(device) before connecting; release usage does not require\
                 an .xctestrun path
                """
            )
        }
        return record
    }

    static func writeRecord(_ record: PreparedRunner, root: URL) throws {
        let devices = root.appendingPathComponent("devices")
        try SessionPaths.secureDirectory(devices)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let url = devices.appendingPathComponent("\(RunnerPackage.hash(Data(record.device.utf8))).json")
        try encoder.encode(record).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
