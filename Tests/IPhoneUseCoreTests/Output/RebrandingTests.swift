import XCTest
@testable import IPhoneUseCore

final class RebrandingTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rebrand-\(UUID().uuidString)")
        try SessionPaths.secureDirectory(root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testStateDirectoryUsesDefaultAndOnlyRecognizedOverride() {
        XCTAssertEqual(SessionPaths.stateRoot(environment: [:]).path, "/private/tmp/iphone-use-\(getuid())")
        XCTAssertEqual(
            SessionPaths.stateRoot(environment: ["IPHONE_USE_STATE_DIR": "/private/tmp/fixture"]).path,
            "/private/tmp/fixture")
        XCTAssertEqual(
            SessionPaths.stateRoot(environment: ["OTHER_TOOL_STATE_DIR": "/private/tmp/old"]),
            SessionPaths.defaultRoot)
        XCTAssertEqual(
            SessionPaths.stateRoot(environment: [
                "IPHONE_USE_STATE_DIR": "/private/tmp/new",
                "OTHER_TOOL_STATE_DIR": "/private/tmp/old"
            ]).path,
            "/private/tmp/new")
    }

    func testDefaultRootLockDoesNotAcquireSameLockTwice() throws {
        let lock = try SessionDeviceLock(
            root: SessionPaths.defaultRoot, device: "fixture-\(UUID().uuidString)")
        withExtendedLifetime(lock) {}
    }

    func testDifferentCustomRootsCannotControlSameDevice() throws {
        let first = try root()
        let second = try root()
        let device = "fixture-\(UUID().uuidString)"
        let lock = try SessionDeviceLock(root: first, device: device)
        XCTAssertThrowsError(try SessionDeviceLock(root: second, device: device)) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "device_busy")
        }
        withExtendedLifetime(lock) {}
    }

    func testCustomRootCannotBypassDefaultDeviceLock() throws {
        let root = try root()
        let device = "fixture-\(UUID().uuidString)"
        try SessionPaths.secureDirectory(SessionPaths.defaultRoot)
        let defaultLock = try DeviceLock(root: SessionPaths.defaultRoot, device: device)
        XCTAssertThrowsError(try SessionDeviceLock(root: root, device: device)) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "device_busy")
        }
        withExtendedLifetime(defaultLock) {}
    }

    func testLockProtectsBothDefaultAndSelectedRootsAndReleasesBoth() throws {
        let root = try root()
        let device = "fixture-\(UUID().uuidString)"
        var lock: SessionDeviceLock? = try SessionDeviceLock(root: root, device: device)
        XCTAssertThrowsError(try DeviceLock(root: root, device: device))
        XCTAssertThrowsError(try DeviceLock(root: SessionPaths.defaultRoot, device: device))
        withExtendedLifetime(lock) {}
        lock = nil
        XCTAssertNoThrow(try DeviceLock(root: root, device: device))
        XCTAssertNoThrow(try DeviceLock(root: SessionPaths.defaultRoot, device: device))
    }
}
