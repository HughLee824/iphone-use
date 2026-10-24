import XCTest
@testable import IPhoneUseCore

extension ObservationTests {
    func testLargeCaptureDecodesStoresAndResolvesNodesOmittedFromPresentation() throws {
        let original = try observationFixture()
        var wire = original.metadata
        wire["screenshotBase64"] = original.screenshot.base64EncodedString()
        wire["truncated"] = false
        wire["snapshotSource"] = "explicit_nonmodal_standard_attributes_v1"
        let nodes: [[String: Any]] = (0..<1201).map { index in
            var node = original.nodes[26].attributes
            node["index"] = index
            node["identityToken"] = "observation-local-token-\(index)"
            node["parent"] = index == 0 ? NSNull() : 0
            node["label"] = index == 1200 ? "LateSearchField" : "field \(index)"
            return node
        }
        wire["nodes"] = nodes
        let capture = try XCTestCapture.decode(wire)
        XCTAssertEqual(capture.nodes.count, 1201)
        let (cache, _) = try cache()
        let stored = try cache.store(capture)
        let text = try XCTUnwrap(stored["text"] as? String)
        XCTAssertLessThanOrEqual(text.utf8.count, 8192)
        XCTAssertLessThanOrEqual(text.split(separator: "\n").count, 60)
        XCTAssertFalse(text.contains("LateSearchField"))
        XCTAssertFalse(text.contains("source_missing=true"))
        let found = try queryNodes(cache.inspect(ObservationReference("o1"), offset: 0, query: "LateSearchField"))
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0]["ref"] as? String, "o1:e1201")
        let saved = try jsonObject(Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(stored["snapshot"] as? String))))
        XCTAssertEqual((saved["nodes"] as? [[String: Any]])?.count, 1201)
        let action = try DeviceAction(
            operation: "type", request: ["reference": "o1:e1201", "mode": "insert", "text": "test"])
        let target = try cache.resolveTarget(for: action)
        XCTAssertEqual(target.path.count, 2)
        XCTAssertEqual(target.path.last?["childIndex"] as? Int, 1199)
        XCTAssertEqual(target.path.last?["label"] as? String, "LateSearchField")
        let fields = try XCTestBackend.actionFields(action, target: target)
        let expected = try XCTUnwrap(fields["target"] as? [String: Any])
        let path = try XCTUnwrap(expected["path"] as? [[String: Any]])
        XCTAssertEqual(path.first?["identityToken"] as? String, "observation-local-token-0")
        XCTAssertEqual(path.last?["identityToken"] as? String, "observation-local-token-1200")
        XCTAssertEqual(capture.metadata["snapshotSource"] as? String, "explicit_nonmodal_standard_attributes_v1")
    }
}
