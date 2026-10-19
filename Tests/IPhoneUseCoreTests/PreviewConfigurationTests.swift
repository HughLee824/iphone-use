import XCTest
@testable import IPhoneUseCore

final class PreviewConfigurationTests: XCTestCase {
    private func store() throws -> (URL, PreviewConfiguration) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("preview-config-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, try PreviewConfiguration(environment: ["IPHONE_USE_CONFIG_DIR": root.path]))
    }

    func testDefaultReadDoesNotWriteAndSavedPortDoesNotChangeMode() throws {
        let (root, config) = try store()
        XCTAssertEqual(try config.get()["port"] as? Int, 8765)
        XCTAssertEqual(try config.get()["portSource"] as? String, "default")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let mode = try ModeConfiguration(environment: ["IPHONE_USE_CONFIG_DIR": root.path])
        _ = try mode.set(mode: "runner")
        let original = try Data(contentsOf: root.appendingPathComponent("config.json"))
        _ = try config.set(port: 9876)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("config.json")), original)
        XCTAssertEqual(try config.get()["port"] as? Int, 9876)
        XCTAssertEqual(try config.startFields(port: nil)["port"] as? Int, 9876)
        XCTAssertEqual(try config.startFields(port: 9877)["port"] as? Int, 9877)
        XCTAssertEqual(try config.get()["port"] as? Int, 9876, "A one-time override must not save preferences")
        let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("preview.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testPortOnlySettingNeverCreatesOrInfersMode() throws {
        let (root, config) = try store()
        _ = try config.set(port: 1024)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("config.json").path))
        _ = try config.set(port: 65535)
        XCTAssertEqual(try config.get()["port"] as? Int, 65535)
        for port in [-1, 0, 1023, 65536, Int.max] {
            XCTAssertThrowsError(try config.set(port: port))
            XCTAssertThrowsError(try config.startFields(port: port))
        }
        XCTAssertEqual(try config.get()["port"] as? Int, 65535)
    }

    func testMalformedConfigurationIsPreservedAndExplicitPortBypassesIt() throws {
        for data in ["{", "{}", "{\"version\":2,\"port\":8765}", "{\"version\":true,\"port\":8765}",
                     "{\"version\":1,\"port\":true}", "{\"version\":1,\"port\":8765.5}",
                     "{\"version\":1,\"port\":0}", "{\"version\":1,\"port\":8765,\"extra\":1}"] {
            let (root, config) = try store()
            try SessionPaths.secureDirectory(root)
            let file = root.appendingPathComponent("preview.json")
            try Data(data.utf8).write(to: file)
            XCTAssertThrowsError(try config.get())
            XCTAssertThrowsError(try config.set(port: 9876))
            XCTAssertEqual(try String(contentsOf: file), data)
            XCTAssertEqual(try config.startFields(port: 9876)["port"] as? Int, 9876)
        }
    }

    func testInvalidDirectoryAndSymlinkAreRejected() throws {
        for path in ["", "relative", "~/config", "/tmp/bad\0path"] {
            XCTAssertThrowsError(try PreviewConfiguration(environment: ["IPHONE_USE_CONFIG_DIR": path]))
        }
        let (root, config) = try store()
        try SessionPaths.secureDirectory(root)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("preview.json"), withDestinationURL: root.appendingPathComponent("missing"))
        XCTAssertThrowsError(try config.get())
        XCTAssertThrowsError(try config.set(port: 9876))
    }

    func testIPCRejectsInvalidPortsAndExplicitFlag() throws {
        for value: Any in [0, -1, 1023, 65536, true, 8765.5, "8765", NSNull()] {
            XCTAssertThrowsError(try NativePreviewOptions(request: ["port": value]))
        }
        for value: Any in [1, "true", NSNull()] {
            XCTAssertThrowsError(try NativePreviewOptions(request: ["port": 8765, "portExplicit": value]))
        }
        XCTAssertThrowsError(try NativePreviewOptions(request: ["portExplicit": true]))
        XCTAssertEqual(try NativePreviewOptions(request: [:]).port, 8765)
        XCTAssertTrue(try NativePreviewOptions(request: ["port": 9876]).explicitPort)
        XCTAssertFalse(try NativePreviewOptions(request: ["port": 9876, "portExplicit": false]).explicitPort)
    }
}
