import XCTest
@testable import IPhoneUseCore

final class RunnerSetupTests: XCTestCase {

    func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "runner setup \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    func makePackage(at directory: URL) throws {
        let app = directory.appendingPathComponent("IPhoneUseRunner.app")
        let test = app.appendingPathComponent("PlugIns/IPhoneUseTests.xctest")
        try FileManager.default.createDirectory(at: test, withIntermediateDirectories: true)
        for (bundle, executable) in [(app, "IPhoneUseTests-Runner"), (test, "IPhoneUseTests")] {
            try writePlist(
                ["CFBundleExecutable": executable], to: bundle.appendingPathComponent("Info.plist"))
            try Data("precompiled fixture".utf8).write(to: bundle.appendingPathComponent(executable))
        }
        try writePlist(
            [
                "IPhoneUseTests": [
                    "BlueprintName": "IPhoneUseTests", "IsUITestBundle": true,
                    "TestHostPath": "__TESTROOT__/IPhoneUseRunner.app",
                    "TestBundlePath": "__TESTHOST__/PlugIns/IPhoneUseTests.xctest",
                    "UseUITargetAppProvidedByTests": true,
                    "DependentProductPaths": [
                        "__TESTROOT__/IPhoneUseRunner.app",
                        "__TESTROOT__/IPhoneUseRunner.app/PlugIns/IPhoneUseTests.xctest"
                    ]
                ]
            ],
            to: directory.appendingPathComponent("Runner.xctestrun"))
        try seal(directory)
    }

    func seal(_ directory: URL, release: String = "0.1.0") throws {
        let manifest = RunnerPackageManifest(
            formatVersion: 1, releaseVersion: release, cliSHA256: RunnerPackage.hash(Data()),
            runnerVersion: "fixture-v1", minimumOSVersion: "17.0",
            files: try RunnerPackage.inventory(directory, excluding: ["manifest.json"]))
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))
    }

    func makeProfile(overrides: [String: Any] = [:]) throws -> SigningProfile {
        let plist: [String: Any] = [
            "UUID": "profile-1", "Name": "Test Development", "TeamIdentifier": ["TEAM000001"],
            "ApplicationIdentifierPrefix": ["PREFIX0001"],
            "ExpirationDate": Date(timeIntervalSince1970: 2_000_000_000),
            "ProvisionedDevices": ["device-1"], "Platform": ["iOS"],
            "DeveloperCertificates": [Data("certificate fixture".utf8)],
            "Entitlements": [
                "get-task-allow": true, "com.apple.developer.team-identifier": "TEAM000001",
                "application-identifier": "PREFIX0001.com.example.*"
            ]
        ]
        return try SigningProfile(
            url: URL(fileURLWithPath: "/test.mobileprovision"), data: Data("fixture".utf8),
            plist: plist.merging(overrides) { _, new in new })
    }

    func writePlist(_ value: [String: Any], to url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: url)
    }

    func assertError(
        _ code: String, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, code, file: file, line: line)
        }
    }
}
