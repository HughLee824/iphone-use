import XCTest
@testable import IPhoneUseCore

final class RunnerBuildTests: XCTestCase {
    func testSigningOverridesCannotInjectBuildSettings() throws {
        try RunnerBuild.validateSigning(team: nil, bundleID: nil)
        try RunnerBuild.validateSigning(team: "AB12CD34EF", bundleID: "com.example.runner-tests")
        for team in ["", "AB12CD34EF\n", "TEAM CODE_SIGNING_ALLOWED=NO", "$(whoami)"] {
            XCTAssertThrowsError(try RunnerBuild.validateSigning(team: team, bundleID: nil))
        }
        for bundle in ["com..runner", "com.runner\n", "com.runner CODE_SIGNING_ALLOWED=NO", "$(TARGET_NAME)"] {
            XCTAssertThrowsError(try RunnerBuild.validateSigning(team: nil, bundleID: bundle))
        }
    }

    func testMissingCheckoutIsRejectedBeforeBuilding() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try RunnerBuild.build(sourceRoot: root, team: nil, bundleID: nil)) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "runner_source_missing")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testFindsActualSDKFilenameAndBothManifestLayouts() throws {
        let directory = try temporaryProducts()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = directory.appendingPathComponent("Debug-iphoneos/IPhoneUseTests-Runner.app")
        try FileManager.default.createDirectory(at: host.appendingPathComponent("PlugIns/IPhoneUseTests.xctest"), withIntermediateDirectories: true)
        let target: [String: Any] = ["BlueprintName": "IPhoneUseTests", "IsUITestBundle": true,
            "TestHostPath": "__TESTROOT__/Debug-iphoneos/IPhoneUseTests-Runner.app",
            "TestBundlePath": "__TESTHOST__/PlugIns/IPhoneUseTests.xctest"]
        let manifest = directory.appendingPathComponent("IPhoneUseRunner_iphoneos99.0-arm64.xctestrun")
        for plist: [String: Any] in [["IPhoneUseTests": target], ["TestConfigurations": [["TestTargets": [target]]]]] {
            try write(plist, to: manifest)
            let products = try RunnerBuild.products(in: directory)
            XCTAssertEqual(products.xctestrun.resolvingSymlinksInPath().path, manifest.resolvingSymlinksInPath().path)
            XCTAssertEqual(products.runnerApp.resolvingSymlinksInPath().path, host.resolvingSymlinksInPath().path)
        }
        try FileManager.default.removeItem(at: host)
        XCTAssertThrowsError(try RunnerBuild.products(in: directory))
    }

    func testMissingAmbiguousOrWrongProductsAreNotSuccess() throws {
        let directory = try temporaryProducts()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(try RunnerBuild.products(in: directory))
        try write(["OtherTests": [:]], to: directory.appendingPathComponent("one.xctestrun"))
        XCTAssertThrowsError(try RunnerBuild.products(in: directory))
        try write([:], to: directory.appendingPathComponent("two.xctestrun"))
        XCTAssertThrowsError(try RunnerBuild.products(in: directory))
    }

    private func temporaryProducts() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("runner-products-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write(_ plist: [String: Any], to url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
    }
}
