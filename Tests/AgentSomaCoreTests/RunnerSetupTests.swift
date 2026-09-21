import XCTest
@testable import AgentSomaCore

final class RunnerSetupTests: XCTestCase {
    func testPackageCanMoveAndBeFoundThroughExecutableSymlink() throws {
        let root = try temporaryDirectory()
        let original = root.appendingPathComponent("original/libexec/agentsoma/runner")
        try makePackage(at: original)
        let digest = try RunnerPackage(directory: original).digest
        let moved = root.appendingPathComponent("moved release")
        try FileManager.default.moveItem(at: root.appendingPathComponent("original"), to: moved)
        let executable = moved.appendingPathComponent("bin/agentsoma")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: executable)
        let link = root.appendingPathComponent("agentsoma")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
        XCTAssertEqual(try RunnerPackage.installed(executable: link).digest, digest)
        try Data("another CLI".utf8).write(to: executable)
        assertError("runner_package_mismatch") { _ = try RunnerPackage.installed(executable: link) }
    }

    func testMissingModifiedAndExtraFilesFailPackageValidation() throws {
        for change in ["remove", "modify", "add"] {
            let directory = try temporaryDirectory()
            try makePackage(at: directory)
            let executable = directory.appendingPathComponent("AgentSomaRunner.app/AgentSomaTests-Runner")
            switch change {
            case "remove": try FileManager.default.removeItem(at: executable)
            case "modify": try Data("modified".utf8).write(to: executable)
            default: try Data("extra".utf8).write(to: directory.appendingPathComponent("extra"))
            }
            assertError("runner_package_invalid") { _ = try RunnerPackage(directory: directory) }
        }
        assertError("runner_package_missing") { _ = try RunnerPackage(directory: self.temporaryDirectory()) }
    }

    func testReleaseRejectsProfilesFrameworksAndSymlinksEvenWithUpdatedManifest() throws {
        for path in ["AgentSomaRunner.app/embedded.mobileprovision", "AgentSomaRunner.app/Frameworks/XCTest", "external"] {
            let directory = try temporaryDirectory()
            try makePackage(at: directory)
            let file = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if path == "external" {
                try FileManager.default.createSymbolicLink(at: file, withDestinationURL: directory.appendingPathComponent("manifest.json"))
            } else {
                try Data("private payload".utf8).write(to: file)
                try seal(directory)
            }
            assertError("runner_package_invalid") { _ = try RunnerPackage(directory: directory) }
        }
    }

    func testReleaseManifestCannotSelectExternalTestProducts() throws {
        for key in ["TestHostPath", "TestBundlePath", "UITargetAppPath", "DependentProductPaths"] {
            let directory = try temporaryDirectory()
            try makePackage(at: directory)
            try RunnerSetup.updatePlist(directory.appendingPathComponent("Runner.xctestrun")) { plist in
                var target = plist["AgentSomaTests"] as! [String: Any]
                target[key] = key == "DependentProductPaths" ? ["__TESTROOT__/../outside.app"] : "/private/tmp/outside.app" as Any
                plist["AgentSomaTests"] = target
            }
            try seal(directory)
            assertError("runner_package_invalid") { _ = try RunnerPackage(directory: directory) }
        }
    }

    func testCLIOnlyVersionChangeDoesNotInvalidateIdenticalRunner() throws {
        let directory = try temporaryDirectory()
        try makePackage(at: directory)
        let original = try RunnerPackage(directory: directory)
        try seal(directory, release: "0.1.1")
        XCTAssertEqual(try RunnerPackage(directory: directory).digest, original.digest)
        try Data("new Runner".utf8).write(to: directory.appendingPathComponent("AgentSomaRunner.app/AgentSomaTests-Runner"))
        try seal(directory, release: "0.1.1")
        XCTAssertNotEqual(try RunnerPackage(directory: directory).digest, original.digest)
    }

    func testMinimumOSIsCheckedNumericallyBeforeDeviceInstallation() throws {
        let directory = try temporaryDirectory()
        try makePackage(at: directory)
        let package = try RunnerPackage(directory: directory)
        for version in ["17", "17.0", "17.0.1", "26.6"] { try package.validateOSVersion(version) }
        assertError("ios_version_unsupported") { try package.validateOSVersion("16.9.9") }
        for version in ["", "17beta", "17..0", "-17", "17.0.0.0"] {
            assertError("invalid_discovery") { try package.validateOSVersion(version) }
        }
    }

    func testDevelopmentProfileChecksDeviceBundleCertificateAndExpiry() throws {
        let profile = try makeProfile()
        let identity = try XCTUnwrap(profile.identities.first)
        try profile.validate(device: "device-1", bundleID: "com.example.runner", identity: identity, now: Date(timeIntervalSince1970: 1))
        assertError("profile_device_mismatch") { try profile.validate(device: "device-2", bundleID: "com.example.runner") }
        assertError("profile_bundle_mismatch") { try profile.validate(device: "device-1", bundleID: "com.other.runner") }
        assertError("profile_identity_mismatch") { try profile.validate(device: "device-1", bundleID: "com.example.runner", identity: "unknown") }
        assertError("profile_expired") { try profile.validate(device: "device-1", bundleID: "com.example.runner", now: profile.expires) }
        let exact = try makeProfile(overrides: ["Entitlements": ["get-task-allow": true,
            "com.apple.developer.team-identifier": "TEAM000001", "application-identifier": "PREFIX0001.com.example.runner"]])
        try exact.validate(device: "device-1", bundleID: "com.example.runner")
        assertError("profile_bundle_mismatch") { try exact.validate(device: "device-1", bundleID: "com.example.runner.tests") }
        // Legacy app prefixes need not equal TeamIdentifier; use each for its own entitlement.
        let entitlements = exact.entitlements(bundleID: "com.example.runner")
        XCTAssertEqual(entitlements["application-identifier"] as? String, "PREFIX0001.com.example.runner")
        XCTAssertEqual(entitlements["com.apple.developer.team-identifier"] as? String, "TEAM000001")
        XCTAssertEqual(entitlements["keychain-access-groups"] as? [String], ["PREFIX0001.com.example.runner"])
    }

    func testDistributionOrIncompleteProfilesAreRejected() throws {
        for overrides: [String: Any] in [
            ["Platform": ["OSX"]], ["DeveloperCertificates": [Data]()], ["ProvisionedDevices": "wrong type"],
            ["Entitlements": ["get-task-allow": false]],
            ["Entitlements": ["get-task-allow": true, "com.apple.developer.team-identifier": "OTHER", "application-identifier": "OTHER.*"]]
        ] {
            assertError("profile_invalid") { _ = try self.makeProfile(overrides: overrides) }
        }
    }

    func testIdentityDiscoveryOnlyAcceptsDevelopmentCertificates() throws {
        let first = String(repeating: "a", count: 40), second = String(repeating: "B", count: 40)
        let ignored = String(repeating: "C", count: 40)
        let text = """
          1) \(first) "Apple Development: A Person (ID)"
          2) \(second) "iPhone Developer: A Person (ID)"
          3) \(ignored) "Developer ID Application: A Person (ID)"
          4) \(ignored) "Apple Distribution: A Person (ID)"
             4 valid identities found
        """
        XCTAssertEqual(try SigningProfile.parseIdentities(text), [first.uppercased(), second])
        XCTAssertTrue(try SigningProfile.parseIdentities("0 valid identities found").isEmpty)
    }

    func testProfileSelectionUsesRenewalAndSavedIdentityWithoutGuessingAcrossTeams() throws {
        let old = try makeProfile()
        let renewed = try makeProfile(overrides: ["UUID": "renewed", "ExpirationDate": old.expires.addingTimeInterval(86400)])
        let choice = try SigningProfile.choose([(old, "identity-a"), (renewed, "identity-a")], bundleID: "com.example.runner", preferredIdentity: nil)
        XCTAssertEqual(choice.0.identifier, "renewed")
        assertError("signing_identity_ambiguous") {
            _ = try SigningProfile.choose([(old, "identity-a"), (renewed, "identity-b")], bundleID: "com.example.runner", preferredIdentity: nil)
        }
        XCTAssertEqual(try SigningProfile.choose([(old, "identity-a"), (renewed, "identity-b")], bundleID: "com.example.runner", preferredIdentity: "identity-b").1, "identity-b")
        // A removed identity does not prevent selecting the replacement certificate.
        XCTAssertEqual(try SigningProfile.choose([(renewed, "identity-b")], bundleID: "com.example.runner", preferredIdentity: "identity-a").1, "identity-b")
        assertError("profile_not_found") { _ = try SigningProfile.choose([], bundleID: "com.example.runner", preferredIdentity: nil) }
    }

    func testPreparedStateRoundTripAndValidationFailures() throws {
        let root = try temporaryDirectory()
        let payload = root.appendingPathComponent("release")
        try makePackage(at: payload)
        let package = try RunnerPackage(directory: payload)
        let directory = UUID().uuidString
        let prepared = root.appendingPathComponent("prepared/\(directory)")
        try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: true)
        try Data("signed manifest".utf8).write(to: prepared.appendingPathComponent("Runner.xctestrun"))
        let record = PreparedRunner(formatVersion: 1, device: "device-1", directory: directory, packageDigest: package.digest,
            runnerVersion: package.manifest.runnerVersion, bundleID: "com.example.runner", team: "TEAM000001", identity: "identity",
            profileDigest: "profile", profileExpires: Date(timeIntervalSince1970: 2_000_000_000), files: try RunnerPackage.inventory(prepared))
        try RunnerSetup.writeRecord(record, root: root)
        let loaded = try RunnerSetup.readRecord(device: "device-1", root: root)
        try RunnerSetup.validate(loaded, package: package, root: root)
        let recordPath = root.appendingPathComponent("devices/\(RunnerPackage.hash(Data("device-1".utf8))).json")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: recordPath.path)[.posixPermissions] as? Int, 0o600)
        assertError("setup_required") { _ = try RunnerSetup.readRecord(device: "device-2", root: root) }
        assertError("profile_expired") { try RunnerSetup.validate(loaded, package: package, root: root, now: loaded.profileExpires) }
        try Data("tampered".utf8).write(to: prepared.appendingPathComponent("Runner.xctestrun"))
        assertError("setup_state_invalid") { try RunnerSetup.validate(loaded, package: package, root: root) }
        try Data("upgraded".utf8).write(to: payload.appendingPathComponent("AgentSomaRunner.app/AgentSomaTests-Runner"))
        try seal(payload)
        assertError("setup_update_required") { try RunnerSetup.validate(loaded, package: RunnerPackage(directory: payload), root: root) }
        var stored = try JSONSerialization.jsonObject(with: Data(contentsOf: recordPath)) as! [String: Any]
        for invalid: [String: Any] in [["directory": "../escape"], ["device": "device-2"]] {
            let changed = stored.merging(invalid) { _, new in new }
            try JSONSerialization.data(withJSONObject: changed).write(to: recordPath)
            assertError("setup_required") { _ = try RunnerSetup.readRecord(device: "device-1", root: root) }
        }
        stored["directory"] = UUID().uuidString
        try JSONSerialization.data(withJSONObject: stored).write(to: recordPath)
        let missing = try RunnerSetup.readRecord(device: "device-1", root: root)
        assertError("setup_state_invalid") { try RunnerSetup.validate(missing, package: package, root: root) }
    }

    func testModeMigrationRequiresAnIntactUnexpiredMatchingRunner() throws {
        let root = try temporaryDirectory()
        XCTAssertFalse(try RunnerSetup.hasValidLegacyConfiguration(root: root, package: {
            XCTFail("Fresh users do not need a Runner package")
            throw SomaError("unexpected", "No package")
        }))
        let packageRoot = root.appendingPathComponent("package")
        try makePackage(at: packageRoot)
        let package = try RunnerPackage(directory: packageRoot)
        let id = UUID().uuidString
        let prepared = root.appendingPathComponent("prepared/\(id)")
        try FileManager.default.createDirectory(at: prepared.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: packageRoot, to: prepared)
        let files = try RunnerPackage.inventory(prepared)
        func record(expires: Date) -> PreparedRunner {
            PreparedRunner(formatVersion: 1, device: "fixture-device", directory: id, packageDigest: package.digest,
                runnerVersion: package.manifest.runnerVersion, bundleID: "com.example.runner", team: "fixture",
                identity: "fixture", profileDigest: "fixture", profileExpires: expires, files: files)
        }
        try RunnerSetup.writeRecord(record(expires: Date().addingTimeInterval(86400)), root: root)
        XCTAssertTrue(try RunnerSetup.hasValidLegacyConfiguration(root: root, package: { package }))
        try RunnerSetup.writeRecord(record(expires: .distantPast), root: root)
        assertError("mode_selection_required") { _ = try RunnerSetup.hasValidLegacyConfiguration(root: root, package: { package }) }
        try RunnerSetup.writeRecord(record(expires: Date().addingTimeInterval(86400)), root: root)
        try Data("changed".utf8).write(to: prepared.appendingPathComponent("Runner.xctestrun"))
        assertError("mode_selection_required") { _ = try RunnerSetup.hasValidLegacyConfiguration(root: root, package: { package }) }
        assertError("mode_selection_required") {
            _ = try RunnerSetup.hasValidLegacyConfiguration(root: root, package: { throw SomaError("runner_package_missing", "Fixture") })
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("runner setup \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makePackage(at directory: URL) throws {
        let app = directory.appendingPathComponent("AgentSomaRunner.app")
        let test = app.appendingPathComponent("PlugIns/AgentSomaTests.xctest")
        try FileManager.default.createDirectory(at: test, withIntermediateDirectories: true)
        for (bundle, executable) in [(app, "AgentSomaTests-Runner"), (test, "AgentSomaTests")] {
            try writePlist(["CFBundleExecutable": executable], to: bundle.appendingPathComponent("Info.plist"))
            try Data("precompiled fixture".utf8).write(to: bundle.appendingPathComponent(executable))
        }
        try writePlist(["AgentSomaTests": ["BlueprintName": "AgentSomaTests", "IsUITestBundle": true,
            "TestHostPath": "__TESTROOT__/AgentSomaRunner.app", "TestBundlePath": "__TESTHOST__/PlugIns/AgentSomaTests.xctest",
            "UseUITargetAppProvidedByTests": true,
            "DependentProductPaths": ["__TESTROOT__/AgentSomaRunner.app", "__TESTROOT__/AgentSomaRunner.app/PlugIns/AgentSomaTests.xctest"]]],
            to: directory.appendingPathComponent("Runner.xctestrun"))
        try seal(directory)
    }

    private func seal(_ directory: URL, release: String = "0.1.0") throws {
        let manifest = RunnerPackageManifest(formatVersion: 1, releaseVersion: release, cliSHA256: RunnerPackage.hash(Data()), runnerVersion: "fixture-v1", minimumOSVersion: "17.0",
            files: try RunnerPackage.inventory(directory, excluding: ["manifest.json"]))
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))
    }

    private func makeProfile(overrides: [String: Any] = [:]) throws -> SigningProfile {
        let plist: [String: Any] = ["UUID": "profile-1", "Name": "Test Development", "TeamIdentifier": ["TEAM000001"],
            "ApplicationIdentifierPrefix": ["PREFIX0001"], "ExpirationDate": Date(timeIntervalSince1970: 2_000_000_000),
            "ProvisionedDevices": ["device-1"], "Platform": ["iOS"], "DeveloperCertificates": [Data("certificate fixture".utf8)],
            "Entitlements": ["get-task-allow": true, "com.apple.developer.team-identifier": "TEAM000001", "application-identifier": "PREFIX0001.com.example.*"]]
        return try SigningProfile(url: URL(fileURLWithPath: "/test.mobileprovision"), data: Data("fixture".utf8),
                                  plist: plist.merging(overrides) { _, new in new })
    }

    private func writePlist(_ value: [String: Any], to url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: url)
    }

    private func assertError(_ code: String, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body(), file: file, line: line) { XCTAssertEqual(($0 as? SomaError)?.code, code, file: file, line: line) }
    }
}
