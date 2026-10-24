import XCTest
@testable import IPhoneUseCore

extension RunnerSetupTests {
    func testPackageCanMoveAndBeFoundThroughExecutableSymlink() throws {
        let root = try temporaryDirectory()
        let original = root.appendingPathComponent("original/libexec/iphone-use/runner")
        try makePackage(at: original)
        let digest = try RunnerPackage(directory: original).digest
        let moved = root.appendingPathComponent("moved release")
        try FileManager.default.moveItem(at: root.appendingPathComponent("original"), to: moved)
        let executable = moved.appendingPathComponent("bin/iphone-use")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: executable)
        let link = root.appendingPathComponent("iphone-use")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
        XCTAssertEqual(try RunnerPackage.installed(executable: link).digest, digest)
        try Data("another CLI".utf8).write(to: executable)
        assertError("runner_package_mismatch") { _ = try RunnerPackage.installed(executable: link) }
    }

    func testMissingModifiedAndExtraFilesFailPackageValidation() throws {
        for change in ["remove", "modify", "add"] {
            let directory = try temporaryDirectory()
            try makePackage(at: directory)
            let executable = directory.appendingPathComponent("IPhoneUseRunner.app/IPhoneUseTests-Runner")
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
        for path in [
            "IPhoneUseRunner.app/embedded.mobileprovision", "IPhoneUseRunner.app/Frameworks/XCTest",
            "external"
        ] {
            let directory = try temporaryDirectory()
            try makePackage(at: directory)
            let file = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if path == "external" {
                try FileManager.default.createSymbolicLink(
                    at: file, withDestinationURL: directory.appendingPathComponent("manifest.json"))
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
                var target = (try XCTUnwrap(plist["IPhoneUseTests"] as? [String: Any]))
                target[key] =
                    key == "DependentProductPaths"
                    ? ["__TESTROOT__/../outside.app"] : "/private/tmp/outside.app" as Any
                plist["IPhoneUseTests"] = target
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
        try Data("new Runner".utf8).write(
            to: directory.appendingPathComponent("IPhoneUseRunner.app/IPhoneUseTests-Runner"))
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
        try profile.validate(
            device: "device-1", bundleID: "com.example.runner", identity: identity,
            now: Date(timeIntervalSince1970: 1))
        assertError("profile_device_mismatch") {
            try profile.validate(device: "device-2", bundleID: "com.example.runner")
        }
        assertError("profile_bundle_mismatch") {
            try profile.validate(device: "device-1", bundleID: "com.other.runner")
        }
        assertError("profile_identity_mismatch") {
            try profile.validate(device: "device-1", bundleID: "com.example.runner", identity: "unknown")
        }
        assertError("profile_expired") {
            try profile.validate(device: "device-1", bundleID: "com.example.runner", now: profile.expires)
        }
        let exact = try makeProfile(overrides: [
            "Entitlements": [
                "get-task-allow": true,
                "com.apple.developer.team-identifier": "TEAM000001",
                "application-identifier": "PREFIX0001.com.example.runner"
            ]
        ])
        try exact.validate(device: "device-1", bundleID: "com.example.runner")
        assertError("profile_bundle_mismatch") {
            try exact.validate(device: "device-1", bundleID: "com.example.runner.tests")
        }
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
            [
                "Entitlements": [
                    "get-task-allow": true, "com.apple.developer.team-identifier": "OTHER",
                    "application-identifier": "OTHER.*"
                ]
            ]
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
        let renewed = try makeProfile(overrides: [
            "UUID": "renewed", "ExpirationDate": old.expires.addingTimeInterval(86400)
        ])
        let choice = try SigningProfile.choose(
            [(old, "identity-a"), (renewed, "identity-a")], bundleID: "com.example.runner",
            preferredIdentity: nil)
        XCTAssertEqual(choice.0.identifier, "renewed")
        assertError("signing_identity_ambiguous") {
            _ = try SigningProfile.choose(
                [(old, "identity-a"), (renewed, "identity-b")], bundleID: "com.example.runner",
                preferredIdentity: nil)
        }
        XCTAssertEqual(
            try SigningProfile.choose(
                [(old, "identity-a"), (renewed, "identity-b")], bundleID: "com.example.runner",
                preferredIdentity: "identity-b"
            ).1, "identity-b")
        // A removed identity does not prevent selecting the replacement certificate.
        XCTAssertEqual(
            try SigningProfile.choose(
                [(renewed, "identity-b")], bundleID: "com.example.runner", preferredIdentity: "identity-a"
            ).1, "identity-b")
        assertError("profile_not_found") {
            _ = try SigningProfile.choose([], bundleID: "com.example.runner", preferredIdentity: nil)
        }
    }
}
