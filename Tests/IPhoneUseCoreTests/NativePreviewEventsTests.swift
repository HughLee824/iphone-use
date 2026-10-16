import XCTest
@testable import IPhoneUseCore

final class NativePreviewEventsTests: XCTestCase {
    func testTransitionFactsKeepCountersWithoutTimingSamplesAndUsePrivateFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("preview-events.jsonl")
        let health: [String: Any] = ["healthy": true, "mediaSessionID": "test-media",
            "snapshots": ["decodeErrors": 1, "referenceResets": 1,
                          "timing": ["slowFrames": [["decodeMs": 400]]]]]
        for event in ["refresh_started", "refresh_completed"] {
            NativePreviewEvents.append(to: url, event: event, reason: "decoder_continuity_lost", source: health)
        }
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let facts = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertEqual(facts["reason"] as? String, "decoder_continuity_lost")
        let media = try XCTUnwrap(facts["media"] as? [String: Any])
        let snapshots = try XCTUnwrap(media["snapshots"] as? [String: Any])
        XCTAssertEqual(snapshots["decodeErrors"] as? Int, 1)
        XCTAssertNil(snapshots["timing"])
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testOversizedLogIsTruncatedAndUnavailableDestinationDoesNotInterruptCaller() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("preview-events.jsonl")
        try Data(repeating: 32, count: 1_048_577).write(to: url)
        NativePreviewEvents.append(to: url, event: "refresh_started", reason: "display_metadata_changed", source: [:])
        let data = try Data(contentsOf: url)
        XCTAssertLessThan(data.count, 1024)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
        NativePreviewEvents.append(to: root.appendingPathComponent("missing/events.jsonl"),
                                   event: "refresh_started", reason: "display_metadata_changed", source: [:])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("missing").path))
    }
}
