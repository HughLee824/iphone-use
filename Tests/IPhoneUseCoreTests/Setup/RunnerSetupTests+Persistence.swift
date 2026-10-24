import XCTest
@testable import IPhoneUseCore

extension RunnerSetupTests {

    func testPreparedStateRoundTripAndValidationFailures() throws {
        let root = try temporaryDirectory()
        let payload = root.appendingPathComponent("release")
        try makePackage(at: payload)
        let package = try RunnerPackage(directory: payload)
        let directory = UUID().uuidString
        let prepared = root.appendingPathComponent("prepared/\(directory)")
        try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: true)
        try Data("signed manifest".utf8).write(to: prepared.appendingPathComponent("Runner.xctestrun"))
        let record = PreparedRunner(
            formatVersion: 1, device: "device-1", directory: directory, packageDigest: package.digest,
            runnerVersion: package.manifest.runnerVersion, bundleID: "com.example.runner", team: "TEAM000001",
            identity: "identity",
            profileDigest: "profile", profileExpires: Date(timeIntervalSince1970: 2_000_000_000),
            files: try RunnerPackage.inventory(prepared))
        try RunnerSetup.writeRecord(record, root: root)
        let loaded = try RunnerSetup.readRecord(device: "device-1", root: root)
        try RunnerSetup.validate(loaded, package: package, root: root)
        let recordPath = root.appendingPathComponent(
            "devices/\(RunnerPackage.hash(Data("device-1".utf8))).json")
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: recordPath.path)[.posixPermissions] as? Int,
            0o600)
        assertError("setup_required") { _ = try RunnerSetup.readRecord(device: "device-2", root: root) }
        assertError("profile_expired") {
            try RunnerSetup.validate(loaded, package: package, root: root, now: loaded.profileExpires)
        }
        try Data("tampered".utf8).write(to: prepared.appendingPathComponent("Runner.xctestrun"))
        assertError("setup_state_invalid") { try RunnerSetup.validate(loaded, package: package, root: root) }
        try Data("upgraded".utf8).write(
            to: payload.appendingPathComponent("IPhoneUseRunner.app/IPhoneUseTests-Runner"))
        try seal(payload)
        assertError("setup_update_required") {
            try RunnerSetup.validate(loaded, package: RunnerPackage(directory: payload), root: root)
        }
        var stored = try
            (try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: recordPath)) as? [String: Any]))
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
        XCTAssertFalse(
            try RunnerSetup.hasValidLegacyConfiguration(
                root: root,
                package: {
                    XCTFail("Fresh users do not need a Runner package")
                    throw IPhoneUseError("unexpected", "No package")
                }))
        let packageRoot = root.appendingPathComponent("package")
        try makePackage(at: packageRoot)
        let package = try RunnerPackage(directory: packageRoot)
        let id = UUID().uuidString
        let prepared = root.appendingPathComponent("prepared/\(id)")
        try FileManager.default.createDirectory(
            at: prepared.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: packageRoot, to: prepared)
        let files = try RunnerPackage.inventory(prepared)
        func record(expires: Date) -> PreparedRunner {
            PreparedRunner(
                formatVersion: 1, device: "fixture-device", directory: id, packageDigest: package.digest,
                runnerVersion: package.manifest.runnerVersion, bundleID: "com.example.runner",
                team: "fixture",
                identity: "fixture", profileDigest: "fixture", profileExpires: expires, files: files)
        }
        try RunnerSetup.writeRecord(record(expires: Date().addingTimeInterval(86400)), root: root)
        XCTAssertTrue(try RunnerSetup.hasValidLegacyConfiguration(root: root, package: { package }))
        try RunnerSetup.writeRecord(record(expires: .distantPast), root: root)
        assertError("mode_selection_required") {
            _ = try RunnerSetup.hasValidLegacyConfiguration(root: root, package: { package })
        }
        try RunnerSetup.writeRecord(record(expires: Date().addingTimeInterval(86400)), root: root)
        try Data("changed".utf8).write(to: prepared.appendingPathComponent("Runner.xctestrun"))
        assertError("mode_selection_required") {
            _ = try RunnerSetup.hasValidLegacyConfiguration(root: root, package: { package })
        }
        assertError("mode_selection_required") {
            _ = try RunnerSetup.hasValidLegacyConfiguration(
                root: root, package: { throw IPhoneUseError("runner_package_missing", "Fixture") })
        }
    }
}
