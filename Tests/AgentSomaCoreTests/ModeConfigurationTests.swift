import XCTest
@testable import AgentSomaCore

final class ModeConfigurationTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mode-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func select(_ store: ModeConfiguration, mode: String? = nil, backend: String? = nil,
                        runner: String? = nil, inventory: String? = nil) throws -> ModeSelection {
        try store.select(mode: mode, backend: backend, xctestrun: runner, nativeEndpointInventory: inventory)
    }

    func testFreshDefaultIsStandardAndGetDoesNotWrite() throws {
        let root = try directory()
        let store = ModeConfiguration(directory: root, legacyRunner: { false })
        XCTAssertEqual(try store.get()["mode"] as? String, "standard")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let selection = try select(store)
        XCTAssertEqual(selection.mode, .standard)
        XCTAssertEqual(selection.source, "default")
        XCTAssertEqual(try select(store).source, "configuration")
        let object = try jsonObject(Data(contentsOf: root.appendingPathComponent("config.json")))
        XCTAssertEqual(object["mode"] as? String, "standard")
        XCTAssertEqual(object["version"] as? Int, 1)
        let permissions = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("config.json").path)
        XCTAssertEqual((permissions[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testLegacyMigrationOnlyRunsOnceAndPersistsRunner() throws {
        var probes = 0
        let root = try directory()
        let store = ModeConfiguration(directory: root, legacyRunner: { probes += 1; return true })
        let selection = try select(store)
        XCTAssertEqual(selection.mode, .runner)
        XCTAssertEqual(selection.source, "legacy_runner_migration")
        XCTAssertEqual(try select(store).source, "configuration")
        XCTAssertEqual(probes, 1)
        _ = try store.set(mode: "standard")
        XCTAssertEqual(try select(store).mode, .standard)
        XCTAssertEqual(probes, 1)
    }

    func testSavedDefaultIsNotAffectedByLaterRunnerSetup() throws {
        var hasRunner = false
        let store = ModeConfiguration(directory: try directory(), legacyRunner: { hasRunner })
        XCTAssertEqual(try select(store).mode, .standard)
        hasRunner = true
        XCTAssertEqual(try select(store).mode, .standard)
    }

    func testExplicitOptionsBypassMigrationAndNeverSavePreferences() throws {
        let root = try directory()
        let store = ModeConfiguration(directory: root, legacyRunner: { XCTFail("Explicit selection must not inspect Runner"); return true })
        XCTAssertEqual(try select(store, mode: "standard").source, "command_line_mode")
        XCTAssertEqual(try select(store, backend: "xctest").mode, .runner)
        XCTAssertEqual(try select(store, backend: "apple-native").mode, .standard)
        XCTAssertEqual(try select(store, runner: "/signed.xctestrun").source, "command_line_xctestrun")
        XCTAssertEqual(try select(store, inventory: "/inventory").mode, .standard)
        XCTAssertEqual(try select(store, mode: "runner", backend: "xctest", runner: "/signed").mode, .runner)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testConflictsAndInvalidOptionsFailBeforeReadingAnyConfiguration() throws {
        let store = ModeConfiguration(directory: try directory(), legacyRunner: { XCTFail("No default lookup"); return false })
        for (mode, backend, runner, inventory): (String?, String?, String?, String?) in [
            ("standard", "xctest", nil, nil), ("runner", "apple-native", nil, nil),
            ("standard", nil, "/runner", nil), ("runner", nil, nil, "/inventory"),
            (nil, nil, "/runner", "/inventory")
        ] {
            XCTAssertThrowsError(try select(store, mode: mode, backend: backend, runner: runner, inventory: inventory)) {
                XCTAssertEqual(($0 as? SomaError)?.code, "mode_conflict")
            }
        }
        XCTAssertThrowsError(try select(store, mode: "auto"))
        XCTAssertThrowsError(try select(store, backend: "other"))
    }

    func testConfigurationOverridesMigrationAndExplicitModeOverridesConfiguration() throws {
        let store = ModeConfiguration(directory: try directory(), legacyRunner: { XCTFail("Saved default wins"); return false })
        _ = try store.set(mode: "runner")
        XCTAssertEqual(try select(store).mode, .runner)
        XCTAssertEqual(try select(store, mode: "standard").mode, .standard)
        XCTAssertEqual(try select(store).mode, .runner)
    }

    func testInvalidConfigurationNeverFallsBackOrGetsOverwritten() throws {
        for contents in ["{", "{}", "{\"version\":2,\"mode\":\"runner\"}",
                         "{\"version\":true,\"mode\":\"runner\"}",
                         "{\"version\":1,\"mode\":\"auto\"}",
                         "{\"version\":1,\"mode\":\"runner\",\"extra\":true}"] {
            let root = try directory()
            try SessionPaths.secureDirectory(root)
            let file = root.appendingPathComponent("config.json")
            try Data(contents.utf8).write(to: file)
            let store = ModeConfiguration(directory: root, legacyRunner: { XCTFail("No fallback"); return false })
            XCTAssertThrowsError(try select(store))
            XCTAssertThrowsError(try store.set(mode: "standard"))
            XCTAssertEqual(try String(contentsOf: file), contents)
            XCTAssertEqual(try select(store, mode: "standard").mode, .standard)
        }
    }

    func testInvalidLegacyStateRequiresExplicitChoiceAndDoesNotPersistDefault() throws {
        let root = try directory()
        let store = ModeConfiguration(directory: root, legacyRunner: { throw SomaError("mode_selection_required", "Fixture stale setup") })
        XCTAssertThrowsError(try select(store))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("config.json").path))
        _ = try store.set(mode: "runner")
        XCTAssertEqual(try select(store).mode, .runner)
    }

    func testOldHostConfigurationRemainsRunnerAndSelectionIsImmutable() throws {
        let data = Data("{\"session\":\"old\",\"device\":\"fixture\",\"xctestrun\":\"/unused\",\"idleTimeoutSeconds\":30}".utf8)
        let old = try JSONDecoder().decode(HostConfiguration.self, from: data)
        XCTAssertEqual(old.modeSelection.mode, .runner)
        XCTAssertEqual(old.modeSelection.source, "legacy_session")
        let store = ModeConfiguration(directory: try directory(), legacyRunner: { false })
        let selection = try select(store)
        let host = HostConfiguration(session: "new", device: "fixture", xctestrun: "", idleTimeoutSeconds: 30,
                                     backend: selection.mode.backend, modeSource: selection.source)
        _ = try store.set(mode: "runner")
        let restored = try JSONDecoder().decode(HostConfiguration.self, from: JSONEncoder().encode(host))
        XCTAssertEqual(restored.modeSelection.mode, .standard)
        XCTAssertEqual(restored.modeSelection.source, "default")
        XCTAssertEqual(try select(store).mode, .runner)
    }

    func testConfigurationSymlinksAreRejected() throws {
        let root = try directory()
        try SessionPaths.secureDirectory(root)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("config.json"),
                                                   withDestinationURL: root.appendingPathComponent("missing"))
        let store = ModeConfiguration(directory: root, legacyRunner: { false })
        XCTAssertThrowsError(try select(store))
    }
}
