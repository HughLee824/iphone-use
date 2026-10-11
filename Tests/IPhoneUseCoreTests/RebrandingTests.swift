import XCTest
@testable import IPhoneUseCore

final class RebrandingTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rebrand-\(UUID().uuidString)")
        try SessionPaths.secureDirectory(root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testOldModeMigratesOnlyOnceWithoutChangingOldFile() throws {
        let root = try root()
        let old = root.appendingPathComponent(".agentsoma")
        let current = root.appendingPathComponent(".iphone-use")
        let oldStore = ModeConfiguration(directory: old, legacyRunner: { false })
        _ = try oldStore.set(mode: "runner")
        let oldBytes = try Data(contentsOf: old.appendingPathComponent("config.json"))
        let store = ModeConfiguration(directory: current, legacyDirectory: old, legacyRunner: {
            XCTFail("Mode preference takes priority over Runner discovery"); return false
        })
        XCTAssertEqual(try store.get()["modeSource"] as? String, "legacy_configuration_migration")
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.path))
        let selected = try store.select(mode: nil, backend: nil, xctestrun: nil, nativeEndpointInventory: nil)
        XCTAssertEqual(selected.mode, .runner)
        XCTAssertEqual(selected.source, "legacy_configuration_migration")
        XCTAssertEqual(try Data(contentsOf: old.appendingPathComponent("config.json")), oldBytes)
        _ = try oldStore.set(mode: "standard")
        XCTAssertEqual(try store.get()["mode"] as? String, "runner")
        XCTAssertEqual(try store.get()["modeSource"] as? String, "configuration")
    }

    func testMalformedOldModeDoesNotResetUserToStandard() throws {
        let root = try root()
        let old = root.appendingPathComponent(".agentsoma")
        try SessionPaths.secureDirectory(old)
        try Data("invalid".utf8).write(to: old.appendingPathComponent("config.json"))
        let store = ModeConfiguration(directory: root.appendingPathComponent(".iphone-use"), legacyDirectory: old,
                                      legacyRunner: { XCTFail("No fallback from malformed preference"); return false })
        XCTAssertThrowsError(try store.get())
        XCTAssertEqual(try store.select(mode: "runner", backend: nil, xctestrun: nil, nativeEndpointInventory: nil).mode, .runner)
        _ = try store.set(mode: "standard")
        XCTAssertEqual(try store.get()["mode"] as? String, "standard")
    }

    func testStateDirectoryAliasesKeepLegacyDefaultAndRejectConflicts() throws {
        XCTAssertEqual(try SessionPaths.stateRoot(environment: [:]), SessionPaths.legacyRoot)
        for key in ["IPHONE_USE_STATE_DIR", "AGENTSOMA_STATE_DIR"] {
            XCTAssertEqual(try SessionPaths.stateRoot(environment: [key: "/private/tmp/fixture"]).path, "/private/tmp/fixture")
        }
        XCTAssertNoThrow(try SessionPaths.stateRoot(environment: ["IPHONE_USE_STATE_DIR": "/private/tmp/a", "AGENTSOMA_STATE_DIR": "/private/tmp/a"]))
        XCTAssertThrowsError(try SessionPaths.stateRoot(environment: ["IPHONE_USE_STATE_DIR": "/private/tmp/a", "AGENTSOMA_STATE_DIR": "/private/tmp/b"])) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "state_directory_conflict")
        }
    }

    func testNewSessionWithCustomRootCannotBypassOldDefaultDeviceLock() throws {
        let root = try root()
        let device = "fixture-\(UUID().uuidString)"
        try SessionPaths.secureDirectory(SessionPaths.legacyRoot)
        let oldLock = try DeviceLock(root: SessionPaths.legacyRoot, device: device)
        XCTAssertThrowsError(try SessionDeviceLock(root: root, device: device)) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "device_busy")
        }
        withExtendedLifetime(oldLock) {}
    }

    func testNewLockProtectsBothLegacyAndSelectedRootsAndReleasesBoth() throws {
        let root = try root()
        let device = "fixture-\(UUID().uuidString)"
        var lock: SessionDeviceLock? = try SessionDeviceLock(root: root, device: device)
        XCTAssertThrowsError(try DeviceLock(root: root, device: device))
        XCTAssertThrowsError(try DeviceLock(root: SessionPaths.legacyRoot, device: device))
        withExtendedLifetime(lock) {}
        lock = nil
        XCTAssertNoThrow(try DeviceLock(root: root, device: device))
        XCTAssertNoThrow(try DeviceLock(root: SessionPaths.legacyRoot, device: device))
    }
}
