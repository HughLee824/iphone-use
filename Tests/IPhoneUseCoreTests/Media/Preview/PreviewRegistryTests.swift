import XCTest
@testable import IPhoneUseCore

final class PreviewRegistryTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try SessionPaths.secureDirectory(url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func sourceURL() -> String { "http://127.0.0.1:12345/\(UUID().uuidString)/" }

    func testStableCredentialsAndDeviceIsolationAcrossRestart() throws {
        let root = try directory(), first = try PreviewRegistry(directory: root)
        let entry = try first.entry(device: "phone-A")
        let owner = UUID().uuidString
        _ = try first.attach(device: entry.device, owner: owner, url: sourceURL(), now: 0)
        XCTAssertNotEqual(try first.entry(device: "phone-B").token, entry.token)
        let restarted = try PreviewRegistry(directory: root)
        XCTAssertEqual(try restarted.entry(device: entry.device).token, entry.token)
        XCTAssertEqual(restarted.authorization, first.authorization)
        XCTAssertNil(restarted.source(device: entry.device, now: 1), "Sources must never persist")
    }

    func testLeaseCannotBeStolenAndOldOwnerCannotDetachReplacement() throws {
        let registry = try PreviewRegistry(directory: directory())
        let first = UUID().uuidString, second = UUID().uuidString
        _ = try registry.attach(device: "phone", owner: first, url: sourceURL(), now: 0)
        XCTAssertThrowsError(try registry.attach(device: "phone", owner: second, url: sourceURL(), now: 1))
        try registry.renew(device: "phone", owner: first, now: 5)
        XCTAssertNotNil(registry.source(device: "phone", now: 10))
        XCTAssertNil(registry.source(device: "phone", now: 11))
        _ = try registry.attach(device: "phone", owner: second, url: sourceURL(), now: 12)
        registry.detach(device: "phone", owner: first)
        XCTAssertEqual(registry.source(device: "phone", now: 12)?.owner, second)
        XCTAssertThrowsError(try registry.renew(device: "phone", owner: first, now: 12))
    }

    func testRevocationInvalidatesOldTokenAndLeaseButNotOtherDevice() throws {
        let root = try directory(), registry = try PreviewRegistry(directory: root)
        XCTAssertThrowsError(try registry.revoke(device: "unknown-phone")) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "preview_not_found")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("entries.json").path))
        let old = try registry.entry(device: "phone"), other = try registry.entry(device: "other")
        let owner = UUID().uuidString
        _ = try registry.attach(device: "phone", owner: owner, url: sourceURL(), now: 0)
        try registry.revoke(device: "phone")
        XCTAssertNil(registry.entry(token: old.token))
        XCTAssertNil(registry.source(device: "phone", now: 1))
        XCTAssertThrowsError(try registry.renew(device: "phone", owner: owner, now: 1))
        XCTAssertEqual(registry.entry(token: other.token)?.device, "other")
        XCTAssertNil(try PreviewRegistry(directory: root).entry(token: old.token))
    }

    func testRejectUnsafeCredentialsAndNonlocalSource() throws {
        let root = try directory(), registry = try PreviewRegistry(directory: root)
        for url in ["https://example.com/", "http://localhost:1234/", "http://127.0.0.1:1234/no-token/"] {
            XCTAssertThrowsError(try registry.attach(device: "phone", owner: UUID().uuidString, url: url, now: 0))
        }
        XCTAssertThrowsError(try registry.entry(device: "../phone"))
        try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                              ofItemAtPath: root.appendingPathComponent("authorization").path)
        XCTAssertThrowsError(try PreviewRegistry(directory: root))
    }
}
