import Foundation
import CryptoKit

// This describes a released payload, not a developer's DerivedData directory.
struct RunnerPackageManifest: Codable {
    let formatVersion: Int
    let releaseVersion: String
    let cliSHA256: String
    let runnerVersion: String
    let minimumOSVersion: String
    let files: [String: String]
}

struct RunnerPackage {
    let directory: URL
    let manifest: RunnerPackageManifest
    let digest: String

    static func installedDirectory(executable: URL = Bundle.main.executableURL!) -> URL {
        executable.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("libexec/iphone-use/runner")
    }

    static func installed(executable: URL = Bundle.main.executableURL!) throws -> RunnerPackage {
        let package = try RunnerPackage(directory: installedDirectory(executable: executable))
        guard try hash(Data(contentsOf: executable)) == package.manifest.cliSHA256 else {
            throw IPhoneUseError("runner_package_mismatch", "CLI and Runner resources are from different release packages; reinstall the complete release")
        }
        return package
    }

    init(directory: URL) throws {
        self.directory = directory.standardizedFileURL
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(RunnerPackageManifest.self, from: data),
              manifest.formatVersion == 1, !manifest.releaseVersion.isEmpty,
              !manifest.runnerVersion.isEmpty, !manifest.files.isEmpty,
              Self.versionComponents(manifest.minimumOSVersion) != nil else {
            throw IPhoneUseError("runner_package_missing", "Install an iPhone-use release containing its precompiled Runner; setup does not build source. Missing or invalid package: \(manifestURL.path)")
        }
        self.manifest = manifest
        // A CLI-only release can carry the identical Runner payload under a new release version.
        digest = Self.hash(try JSONSerialization.data(withJSONObject: ["formatVersion": manifest.formatVersion,
            "runnerVersion": manifest.runnerVersion, "minimumOSVersion": manifest.minimumOSVersion, "files": manifest.files], options: .sortedKeys))
        let actual = try Self.inventory(directory, excluding: ["manifest.json"])
        guard actual == manifest.files,
              actual["IPhoneUseRunner.app/Info.plist"] != nil,
              actual["IPhoneUseRunner.app/IPhoneUseTests-Runner"] != nil,
              actual["IPhoneUseRunner.app/PlugIns/IPhoneUseTests.xctest/IPhoneUseTests"] != nil,
              actual["Runner.xctestrun"] != nil,
              !actual.keys.contains(where: { $0.hasSuffix(".mobileprovision") || $0.hasPrefix("IPhoneUseRunner.app/Frameworks/") }) else {
            throw IPhoneUseError("runner_package_invalid", "Runner release payload is incomplete, modified, or contains signing profiles/embedded frameworks; reinstall this release")
        }
        guard let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: directory.appendingPathComponent("Runner.xctestrun")), format: nil) as? [String: Any],
              let target = plist["IPhoneUseTests"] as? [String: Any],
              Set(plist.keys).isSubset(of: ["IPhoneUseTests", "__xctestrun_metadata__"]),
              target["TestHostPath"] as? String == "__TESTROOT__/IPhoneUseRunner.app",
              target["TestBundlePath"] as? String == "__TESTHOST__/PlugIns/IPhoneUseTests.xctest",
              target["UseUITargetAppProvidedByTests"] as? Bool == true,
              target["UITargetAppPath"] == nil,
              target["DependentProductPaths"] as? [String] == ["__TESTROOT__/IPhoneUseRunner.app", "__TESTROOT__/IPhoneUseRunner.app/PlugIns/IPhoneUseTests.xctest"] else {
            throw IPhoneUseError("runner_package_invalid", "Runner test manifest must use the release-local app and test bundle")
        }
        let products = try RunnerBuild.products(in: directory)
        guard products.runnerApp.standardizedFileURL == directory.appendingPathComponent("IPhoneUseRunner.app").standardizedFileURL else {
            throw IPhoneUseError("runner_package_invalid", "Runner manifest must reference the package's IPhoneUseRunner.app")
        }
    }

    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    func validateOSVersion(_ version: String) throws {
        guard let actual = Self.versionComponents(version), let minimum = Self.versionComponents(manifest.minimumOSVersion) else {
            throw IPhoneUseError("invalid_discovery", "CoreDevice did not return a valid iOS version")
        }
        guard !actual.lexicographicallyPrecedes(minimum) else {
            throw IPhoneUseError("ios_version_unsupported", "This Runner package requires iOS \(manifest.minimumOSVersion) or later; device reports \(version)")
        }
    }

    private static func versionComponents(_ value: String) -> [Int]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return Int(part)
        }
        guard (1...3).contains(parts.count), parts.count == numbers.count else { return nil }
        return numbers + Array(repeating: 0, count: 3 - numbers.count)
    }

    static func inventory(_ directory: URL, excluding: Set<String> = []) throws -> [String: String] {
        let files = FileManager.default
        guard let iterator = files.enumerator(atPath: directory.path) else {
            throw IPhoneUseError("runner_package_invalid", "Cannot read Runner payload")
        }
        var result: [String: String] = [:]
        for case let relative as String in iterator {
            let file = directory.appendingPathComponent(relative)
            let properties = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard properties.isSymbolicLink != true else { throw IPhoneUseError("runner_package_invalid", "Runner payload must not contain symbolic links") }
            guard properties.isRegularFile == true else { continue }
            if !excluding.contains(relative) { result[relative] = hash(try Data(contentsOf: file)) }
        }
        return result
    }
}

// Small host-tool adapter shared by setup's signing operations. No shell expansion.
enum SigningTool {
    struct Result { let output: Data; let error: String; let status: Int32 }

    static func run(_ executable: String, _ arguments: [String]) throws -> Result {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("iphone-use-signing-\(UUID().uuidString)")
        try SessionPaths.secureDirectory(temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let stdout = temporary.appendingPathComponent("stdout")
        let stderr = temporary.appendingPathComponent("stderr")
        for url in [stdout, stderr] { FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let out = try FileHandle(forWritingTo: stdout), err = try FileHandle(forWritingTo: stderr)
        defer { try? out.close(); try? err.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out; process.standardError = err
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + 60
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            let grace = ProcessInfo.processInfo.systemUptime + 2
            while process.isRunning, ProcessInfo.processInfo.systemUptime < grace { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw IPhoneUseError("signing_tool_timeout", "\(URL(fileURLWithPath: executable).lastPathComponent) did not finish; check Xcode/Keychain prompts, then retry setup")
        }
        process.waitUntilExit()
        return Result(output: try Data(contentsOf: stdout), error: String(decoding: try Data(contentsOf: stderr), as: UTF8.self), status: process.terminationStatus)
    }

    static func require(_ executable: String, _ arguments: [String], code: String) throws -> Data {
        let result = try run(executable, arguments)
        guard result.status == 0 else {
            throw IPhoneUseError(code, "\(URL(fileURLWithPath: executable).lastPathComponent) exited \(result.status): \(result.error.suffix(2000))")
        }
        return result.output
    }
}
