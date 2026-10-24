import Foundation

struct PreparedRunner: Codable {
    let formatVersion: Int
    let device: String
    let directory: String
    let packageDigest: String
    let runnerVersion: String
    let bundleID: String
    let team: String
    let identity: String
    let profileDigest: String
    let profileExpires: Date
    let files: [String: String]
}

public enum RunnerSetup {
    static var stateDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/iphone-use")
    }

    public static var releaseVersion: String {
        guard
            let data = try? Data(
                contentsOf: RunnerPackage.installedDirectory().appendingPathComponent("manifest.json")),
            let manifest = try? JSONDecoder().decode(RunnerPackageManifest.self, from: data),
            let executable = Bundle.main.executableURL, let binary = try? Data(contentsOf: executable),
            RunnerPackage.hash(binary) == manifest.cliSHA256
        else { return "development" }
        return manifest.releaseVersion
    }

    public static func setup(device: String, profile: String?, identity: String?, team: String?, bundleID: String?)
        throws -> [String: Any] {
        let package = try RunnerPackage.installed()
        _ = try SigningTool.require("/usr/bin/xcrun", ["--find", "xcodebuild"], code: "xcode_unavailable")
        let details = try CoreDevice.read(["device", "info", "details", "--device", device])
        try package.validateOSVersion(
            (details["deviceProperties"] as? [String: Any])?["osVersionNumber"] as? String ?? "")
        guard let hardware = details["hardwareProperties"] as? [String: Any], let udid = hardware["udid"] as? String
        else { throw IPhoneUseError("invalid_discovery", "CoreDevice did not identify the selected iPhone") }
        let root = stateDirectory
        try SessionPaths.secureDirectory(root)
        let lock = try DeviceLock(root: root, device: "setup-" + udid)
        defer { withExtendedLifetime(lock) {} }
        let old = try? readRecord(device: udid, root: root)
        let bundleID = bundleID ?? old?.bundleID ?? "com.iphone-use.runner.xctrunner"
        try RunnerBuild.validateSigning(team: team, bundleID: bundleID)
        let explicitProfile = profile.map { URL(fileURLWithPath: $0).standardizedFileURL }
        let savedProfile = old.map {
            root.appendingPathComponent("prepared/\($0.directory)/IPhoneUseRunner.app/embedded.mobileprovision")
        }
        // Include the saved profile alongside Xcode's profiles so renewal and key rotation can be discovered.
        let (signing, selectedIdentity) = try SigningProfile.select(
            device: udid, bundleID: bundleID, profileURL: explicitProfile, identity: identity,
            team: team ?? (profile == nil ? old?.team : nil), savedProfileURL: savedProfile,
            preferredIdentity: profile == nil && team == nil ? old?.identity : nil)
        let reusable = reusableRecord(
            old, package: package, target: Target(device: udid, bundleID: bundleID),
            signing: (signing, selectedIdentity), root: root)
        let prepared: PreparedRunner
        if let reusable {
            prepared = reusable
        } else {
            prepared = try prepare(
                package: package, profile: signing, identity: selectedIdentity,
                target: Target(device: udid, bundleID: bundleID), root: root)
        }
        let session = try deployAndVerify(
            device: udid, products: root.appendingPathComponent("prepared/\(prepared.directory)"))
        try writeRecord(prepared, root: root)
        return [
            "device": udid, "releaseVersion": package.manifest.releaseVersion, "runnerVersion": prepared.runnerVersion,
            "bundleId": bundleID, "team": signing.team,
            "profileExpires": ISO8601DateFormatter().string(from: signing.expires), "reused": reusable != nil,
            "compiled": false, "verificationSession": session,
            "verified": ["connection", "observation-capture", "disconnect"]
        ]
    }

    private static func reusableRecord(
        _ old: PreparedRunner?, package: RunnerPackage, target: Target, signing: (SigningProfile, String), root: URL
    ) -> PreparedRunner? {
        let bundleID = target.bundleID, selectedIdentity = signing.1
        let profileDigest = RunnerPackage.hash(signing.0.data)
        let reusable = old.flatMap { record -> PreparedRunner? in
            guard record.packageDigest == package.digest, record.bundleID == bundleID,
                record.identity == selectedIdentity, record.profileDigest == profileDigest,
                (try? validate(record, package: package, root: root)) != nil
            else { return nil }
            return record
        }
        return reusable
    }

    private static func deployAndVerify(device udid: String, products: URL) throws -> String {
        // Only explicit setup deploys the signed app. Ordinary connect reuses it
        // and verifies the live protocol without resetting per-app permissions.
        do {
            let sessionRoot = SessionPaths.stateRoot(environment: ProcessInfo.processInfo.environment)
            try SessionPaths.secureDirectory(sessionRoot)
            let deploymentLock = try SessionDeviceLock(root: sessionRoot, device: udid)
            defer { withExtendedLifetime(deploymentLock) {} }
            _ = try RunnerUSBTransport(device: udid).requireUSB(deadline: ProcessInfo.processInfo.systemUptime + 5)
            _ = try CoreDevice.read(
                ["device", "install", "app", "--device", udid],
                trailingArguments: [products.appendingPathComponent("IPhoneUseRunner.app").path], timeout: 60)
        }
        // Keep a prepared directory after an uncertain connection/cleanup failure: a host may still own it.
        let connection = try SessionClient.connect(
            device: udid, xctestrun: products.appendingPathComponent("Runner.xctestrun"), idleTimeout: IdleTimeout("3m")
        )
        guard let session = connection["session"] as? String else {
            throw IPhoneUseError("setup_verification_failed", "Connection did not return a session")
        }
        var closed = false
        defer { if !closed { _ = try? SessionClient.call(session: session, operation: "disconnect") } }
        let observation = try SessionClient.call(session: session, operation: "observe")
        guard observation["ok"] as? Bool == true else {
            throw IPhoneUseError(
                "setup_verification_failed",
                """
                Runner observation failed in session \(session):\
                 \(observation["error"] ?? "no diagnostic returned")
                """)
        }
        let cleanup = try SessionClient.call(session: session, operation: "disconnect")
        guard cleanup["ok"] as? Bool == true else {
            throw IPhoneUseError(
                "setup_cleanup_failed",
                "Runner verification did not close cleanly; inspect session \(session) before retrying")
        }
        closed = true
        return session
    }

    public static func connect(
        device: String, idleTimeout: IdleTimeout, modeSource: String = "explicit_runner", previewPort: Int? = nil,
        onProgress: (([String: Any]) -> Void)? = nil
    ) throws -> [String: Any] {
        let package = try RunnerPackage.installed()
        let root = stateDirectory
        // Resolve CoreDevice aliases to the same durable device identity used by setup.
        let details = try CoreDevice.read(["device", "info", "details", "--device", device])
        try package.validateOSVersion(
            (details["deviceProperties"] as? [String: Any])?["osVersionNumber"] as? String ?? "")
        guard let hardware = details["hardwareProperties"] as? [String: Any], let udid = hardware["udid"] as? String
        else { throw IPhoneUseError("invalid_discovery", "CoreDevice did not identify the selected iPhone") }
        let record = try readRecord(device: udid, root: root)
        try validate(record, package: package, root: root)
        var response = try SessionClient.connect(
            device: udid, xctestrun: root.appendingPathComponent("prepared/\(record.directory)/Runner.xctestrun"),
            idleTimeout: idleTimeout, modeSource: modeSource, previewPort: previewPort, onProgress: onProgress)
        response["runner"] = [
            "releaseVersion": package.manifest.releaseVersion, "runnerVersion": record.runnerVersion,
            "bundleId": record.bundleID
        ]
        return response
    }

    struct Target {
        let device: String
        let bundleID: String
    }

    static func prepare(package: RunnerPackage, profile: SigningProfile, identity: String, target: Target, root: URL)
        throws -> PreparedRunner {
        let device = target.device, bundleID = target.bundleID
        try profile.validate(device: device, bundleID: bundleID, identity: identity)
        let directory = UUID().uuidString.lowercased()
        let preparedRoot = root.appendingPathComponent("prepared")
        try SessionPaths.secureDirectory(preparedRoot)
        let destination = preparedRoot.appendingPathComponent(directory)
        try FileManager.default.copyItem(at: package.directory, to: destination)
        var accepted = false
        defer { if !accepted { try? FileManager.default.removeItem(at: destination) } }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
        try makeWritable(destination)
        try FileManager.default.removeItem(at: destination.appendingPathComponent("manifest.json"))
        let app = destination.appendingPathComponent("IPhoneUseRunner.app")
        let test = app.appendingPathComponent("PlugIns/IPhoneUseTests.xctest")
        try updatePlist(app.appendingPathComponent("Info.plist")) { $0["CFBundleIdentifier"] = bundleID }
        let testID = bundleID + ".tests"
        try updatePlist(test.appendingPathComponent("Info.plist")) { $0["CFBundleIdentifier"] = testID }
        try updatePlist(destination.appendingPathComponent("Runner.xctestrun")) { plist in
            guard var target = plist["IPhoneUseTests"] as? [String: Any] else {
                throw IPhoneUseError("runner_products_invalid", "No IPhoneUseTests UI Runner in manifest")
            }
            target["TestHostBundleIdentifier"] = bundleID
            target["BundleIdentifiersForCrashReportEmphasis"] = [testID]
            plist["IPhoneUseTests"] = target
        }
        try profile.data.write(to: app.appendingPathComponent("embedded.mobileprovision"), options: .atomic)
        let entitlements = destination.appendingPathComponent("entitlements.plist")
        try PropertyListSerialization.data(
            fromPropertyList: profile.entitlements(bundleID: bundleID), format: .xml, options: 0
        ).write(to: entitlements)
        _ = try SigningTool.require(
            "/usr/bin/codesign", ["--force", "--sign", identity, "--timestamp=none", test.path],
            code: "runner_signing_failed")
        _ = try SigningTool.require(
            "/usr/bin/codesign",
            ["--force", "--sign", identity, "--timestamp=none", "--entitlements", entitlements.path, app.path],
            code: "runner_signing_failed")
        _ = try SigningTool.require(
            "/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], code: "runner_signature_invalid")
        try FileManager.default.removeItem(at: entitlements)
        let record = PreparedRunner(
            formatVersion: 1, device: device, directory: directory, packageDigest: package.digest,
            runnerVersion: package.manifest.runnerVersion, bundleID: bundleID, team: profile.team, identity: identity,
            profileDigest: RunnerPackage.hash(profile.data), profileExpires: profile.expires,
            files: try RunnerPackage.inventory(destination))
        accepted = true
        return record
    }

    private static func makeWritable(_ destination: URL) throws {
        // Installed releases can be read-only. Only the private copy must be writable for re-signing.
        if let items = FileManager.default.enumerator(atPath: destination.path) {
            for case let relative as String in items {
                let path = destination.appendingPathComponent(relative).path
                let attributes = try FileManager.default.attributesOfItem(atPath: path)
                let executable = (attributes[.posixPermissions] as? Int ?? 0) & 0o111 != 0
                let directory = attributes[.type] as? FileAttributeType == .typeDirectory
                try FileManager.default.setAttributes(
                    [.posixPermissions: directory || executable ? 0o700 : 0o600], ofItemAtPath: path)
            }
        }
    }

    static func updatePlist(_ url: URL, body: (inout [String: Any]) throws -> Void) throws {
        guard
            var plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
                as? [String: Any]
        else { throw IPhoneUseError("runner_package_invalid", "Invalid property list in Runner payload") }
        try body(&plist)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(
            to: url, options: .atomic)
    }
}
