import XCTest
import Foundation
@testable import IPhoneUseCore

extension ObservationTests {

    func testOutputBudgetPaginationAndMissingSourceAreSeparate() throws {
        let original = try observationFixture()
        var nodes: [AXNode] = []
        for index in 0..<200 {
            var attributes = original.nodes[26].attributes
            attributes["index"] = index
            attributes["parent"] = index == 0 ? NSNull() : 0
            attributes["label"] = "field \(index)\n\"quoted\""
            attributes["value"] = String(repeating: "北京", count: 2000)
            nodes.append(
                AXNode(index: index, parent: index == 0 ? nil : 0, role: "text_field", attributes: attributes)
            )
        }
        var metadata = original.metadata
        metadata["sourceTruncated"] = true
        let (cache, _) = try cache()
        let response = try cache.store(
            CapturedObservation(nodes: nodes, metadata: metadata, screenshot: original.screenshot))
        let text = (try XCTUnwrap(response["text"] as? String))
        XCTAssertLessThanOrEqual(text.utf8.count, 8192)
        XCTAssertLessThanOrEqual(text.split(separator: "\n").count, 60)
        XCTAssertTrue(text.contains("unexpanded="))
        XCTAssertTrue(text.contains("source_missing=true"))
        XCTAssertTrue(text.contains("detail_clipped=true"))
        XCTAssertTrue(text.contains("\\n\\\"quoted\\\""))
        var offset = 0
        var visited = 0
        repeat {
            let page = try (try XCTUnwrap(cache.inspect(ObservationReference("o1"), offset: offset)["text"] as? String))
            XCTAssertLessThanOrEqual(page.utf8.count, 8192)
            visited += page.split(separator: "\n").filter { $0.hasPrefix("[e") }.count
            if let line = page.split(separator: "\n").first(where: { $0.hasPrefix("more:") }),
                let range = line.range(of: "--offset ") {
                offset = Int(line[range.upperBound...].split(separator: " ")[0])!
            } else {
                break
            }
        } while offset < 200
        XCTAssertEqual(visited, 200)
        XCTAssertThrowsError(try cache.inspect(ObservationReference("o1:e201"), offset: 0))
        XCTAssertThrowsError(try cache.inspect(ObservationReference("o1"), offset: 200))
    }

    func testInvalidReferencesAndMalformedCapturedParentsAreRejected() throws {
        for invalid in ["o0", "o1:e0", "o1:e9999999999999999999999", "o1/../o2", "e1", "o1:e2:extra"] {
            XCTAssertThrowsError(try ObservationReference(invalid))
        }
        let capture = try observationFixture()
        var result = capture.metadata
        result["screenshotBase64"] = capture.screenshot.base64EncodedString()
        result["truncated"] = false
        var nodes = capture.nodes.map(\.attributes)
        nodes[1]["parent"] = 1
        result["nodes"] = nodes
        XCTAssertThrowsError(try XCTestCapture.decode(result))
    }

    func testScreenshotStillReturnedWhenAXIsUnavailable() throws {
        let original = try observationFixture()
        let capture = try XCTestCapture.decode([
            "screenshotBase64": original.screenshot.base64EncodedString(),
            "axStatus": "unavailable", "axError": "foreground_app_unknown", "scope": "unknown"
        ])
        XCTAssertTrue(capture.nodes.isEmpty)
        let (cache, _) = try cache()
        let response = try cache.store(capture)
        XCTAssertTrue(((try XCTUnwrap(response["text"] as? String))).contains("ax=unavailable"))
        XCTAssertTrue(((try XCTUnwrap(response["text"] as? String))).contains("foreground=null"))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: (try XCTUnwrap(response["screenshot"] as? String))))
        let query = try
            (try XCTUnwrap(
                cache.inspect(ObservationReference("o1"), offset: 0, query: "Calendar")["text"] as? String))
        XCTAssertTrue(query.contains("ax=unavailable"))
        XCTAssertTrue(query.contains("matched_nodes=0 searched_nodes=0"))
        XCTAssertThrowsError(try cache.resolveCurrent(ObservationReference("o1:e1")))
    }
}
