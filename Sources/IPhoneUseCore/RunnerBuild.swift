import Foundation

public enum RunnerBuild {
    public static func build(sourceRoot: URL, team: String?, bundleID: String?) throws -> [String: Any] {
        try validateSigning(team: team, bundleID: bundleID)
        let root = sourceRoot.standardizedFileURL
        let project = root.appendingPathComponent("Runner/IPhoneUseRunner.xcodeproj")
        guard FileManager.default.isReadableFile(atPath: project.appendingPathComponent("project.pbxproj").path) else {
            throw IPhoneUseError("runner_source_missing", "Use --source-root to select an iPhone-use checkout containing Runner/IPhoneUseRunner.xcodeproj")
        }
        // Never rebuild in a directory whose products may be held by an active session.
        let directory = root.appendingPathComponent(".build/runner/\(UUID().uuidString.lowercased())")
        try SessionPaths.secureDirectory(directory)
        let logURL = directory.appendingPathComponent("build.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        var arguments = ["xcodebuild", "build-for-testing", "-project", project.path,
            "-scheme", "IPhoneUseRunner", "-configuration", "Debug", "-sdk", "iphoneos",
            "-destination", "generic/platform=iOS", "-derivedDataPath", directory.path, "-quiet"]
        if let team { arguments.append("DEVELOPMENT_TEAM=\(team)") }
        if let bundleID { arguments.append("PRODUCT_BUNDLE_IDENTIFIER=\(bundleID)") }
        build.arguments = arguments
        build.standardInput = FileHandle.nullDevice
        build.standardOutput = log
        build.standardError = log
        try build.run()
        build.waitUntilExit()
        guard build.terminationStatus == 0 else {
            let detail = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            throw IPhoneUseError("runner_build_failed", "xcodebuild exited \(build.terminationStatus). Use full Xcode and configure this Runner target's team, bundle ID and signing in \(project.path). See \(logURL.path)\n\(detail.suffix(4000))")
        }
        let products = try products(in: directory.appendingPathComponent("Build/Products"))
        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verify.arguments = ["--verify", "--deep", "--strict", products.runnerApp.path]
        verify.standardInput = FileHandle.nullDevice
        verify.standardOutput = log
        verify.standardError = log
        try verify.run()
        verify.waitUntilExit()
        guard verify.terminationStatus == 0 else {
            throw IPhoneUseError("runner_signature_invalid", "Runner signature verification failed; see \(logURL.path)")
        }
        let result: [String: Any] = ["xctestrun": products.xctestrun.path, "runnerApp": products.runnerApp.path,
                                   "buildDirectory": directory.path, "log": logURL.path]
        try saveJSON(result, to: directory.appendingPathComponent("build.json"))
        return result
    }

    static func validateSigning(team: String?, bundleID: String?) throws {
        if let team, team.range(of: "^[A-Z0-9]{10}\\z", options: .regularExpression) == nil {
            throw IPhoneUseError("invalid_team", "--team must be a 10-character Apple development team ID")
        }
        if let bundleID, bundleID.utf8.count > 255 ||
            bundleID.range(of: "^[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+\\z", options: .regularExpression) == nil {
            throw IPhoneUseError("invalid_bundle_id", "--bundle-id must be a dot-separated bundle identifier")
        }
    }

    static func products(in directory: URL) throws -> (xctestrun: URL, runnerApp: URL) {
        let files = FileManager.default
        let manifests = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "xctestrun" }
        guard manifests.count == 1 else {
            throw IPhoneUseError("runner_products_invalid", "Expected one .xctestrun in \(directory.path); found \(manifests.count)")
        }
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: manifests[0]), format: nil) as? [String: Any]
        let configurations = plist?["TestConfigurations"] as? [[String: Any]] ?? []
        let targets = configurations.flatMap { $0["TestTargets"] as? [[String: Any]] ?? [] }
        let target = plist?["IPhoneUseTests"] as? [String: Any] ?? targets.first { $0["BlueprintName"] as? String == "IPhoneUseTests" }
        guard let target, target["IsUITestBundle"] as? Bool == true,
              let host = target["TestHostPath"] as? String, host.hasPrefix("__TESTROOT__/"),
              let bundle = target["TestBundlePath"] as? String, bundle.hasPrefix("__TESTHOST__/") else {
            throw IPhoneUseError("runner_products_invalid", "No IPhoneUseTests UI Runner in \(manifests[0].path)")
        }
        let runner = directory.appendingPathComponent(String(host.dropFirst("__TESTROOT__/".count)))
        let testBundle = runner.appendingPathComponent(String(bundle.dropFirst("__TESTHOST__/".count)))
        guard files.isReadableFile(atPath: runner.path), files.isReadableFile(atPath: testBundle.path) else {
            throw IPhoneUseError("runner_products_invalid", "Runner products referenced by \(manifests[0].path) are missing")
        }
        return (manifests[0], runner)
    }
}
