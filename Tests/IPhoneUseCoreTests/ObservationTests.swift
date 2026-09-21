import XCTest
import Foundation
@testable import IPhoneUseCore

// Sanitized AX with a synthetic full-screen PNG, independent of local device artifacts.
func observationFixture(_ name: String = "app.json") throws -> CapturedObservation {
    let fixture = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/Observations"))
    var result = try jsonObject(Data(contentsOf: fixture))
    result["screenshotBase64"] = try screenPNG().base64EncodedString()
    result["axStatus"] = "available"
    result["snapshotFinishedAt"] = result["screenshotCapturedAt"]
    result["screenFrame"] = ["x": 0, "y": 0, "width": 390, "height": 844]
    result["screenContext"] = try jsonObject(JSONEncoder().encode(screenTestContext()))
    if result["scope"] as? String == "app" { result["foregroundBundleId"] = result["bundleId"] }
    return try XCTestCapture.decode(result)
}

final class ObservationTests: XCTestCase {
    private func cache() throws -> (ObservationCache, URL) {
        let directory = URL(fileURLWithPath: "/private/tmp/as-observe-\(UUID().uuidString.prefix(8))")
        try SessionPaths.secureDirectory(directory)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (ObservationCache(directory: directory), directory)
    }

    private func queryNodes(_ result: [String: Any]) throws -> [[String: Any]] {
        try (result["text"] as! String).split(separator: "\n").filter { $0.hasPrefix("{") }.map {
            try jsonObject(Data($0.utf8))
        }
    }

    func testQuerySearchesFullAttributesBeyondDefaultOutputAndKeepsGeometry() throws {
        let original = try observationFixture()
        let nodes = (0..<200).map { index -> AXNode in
            var attributes = original.nodes[26].attributes
            attributes["index"] = index; attributes["parent"] = index == 0 ? NSNull() : 0
            attributes["label"] = index == 185 ? "Calendar" : "Background \(index)"
            attributes["identifier"] = index == 185 ? "calendar.entry" : ""
            attributes["value"] = index == 185 ? String(repeating: "北京", count: 2000) + "TailNeedle" : ""
            attributes["enabled"] = index != 185
            return AXNode(index: index, parent: index == 0 ? nil : 0,
                          role: index == 185 ? "button" : "text", attributes: attributes)
        }
        let (cache, _) = try cache()
        let stored = try cache.store(CapturedObservation(nodes: nodes, metadata: original.metadata, screenshot: original.screenshot))
        XCTAssertFalse((stored["text"] as! String).contains("Calendar"))
        XCTAssertTrue((stored["text"] as! String).contains("--query TEXT"))
        for query in ["cAlEnDaR", "calendar.entry", "tailneedle", "button"] {
            let result = try cache.inspect(ObservationReference("o1"), offset: 0, query: query)
            let matches = try queryNodes(result)
            XCTAssertEqual(matches.count, 1, query)
            let match = try XCTUnwrap(matches.first)
            XCTAssertEqual(match["ref"] as? String, "o1:e186")
            XCTAssertEqual(match["parentRef"] as? String, "o1:e1")
            XCTAssertEqual(match["enabled"] as? Bool, false)
            XCTAssertEqual(match["detail_clipped"] as? Bool, true)
            XCTAssertTrue(NSDictionary(dictionary: match["frame"] as! [String: Any]).isEqual(to: nodes[185].attributes["frame"] as! [String: Any]))
            XCTAssertLessThanOrEqual((result["text"] as! String).utf8.count, 8192)
        }
        XCTAssertThrowsError(try cache.inspect(ObservationReference("o1"), offset: 1, query: "Calendar"))
        XCTAssertThrowsError(try cache.inspect(ObservationReference("o1"), offset: -1, query: "Calendar"))
    }

    func testQueryPaginationUsesMatchOffsetsAndLiteralShellContinuation() throws {
        let original = try observationFixture()
        let query = "Calendar's $(printf injected) `printf more`"
        let nodes = (0..<60).map { index -> AXNode in
            var attributes = original.nodes[26].attributes
            attributes["index"] = index; attributes["parent"] = index == 0 ? NSNull() : 0
            attributes["label"] = index % 2 == 0 ? query : "Background"
            attributes["value"] = ""
            return AXNode(index: index, parent: index == 0 ? nil : 0, role: "text", attributes: attributes)
        }
        let (cache, _) = try cache()
        _ = try cache.store(CapturedObservation(nodes: nodes, metadata: original.metadata, screenshot: original.screenshot))
        var offset = 0
        var refs: [String] = []
        repeat {
            let result = try cache.inspect(ObservationReference("o1"), offset: offset, query: query)
            let text = result["text"] as! String
            let matches = try queryNodes(result)
            XCTAssertTrue(text.contains("matched_nodes=30 searched_nodes=60"))
            XCTAssertLessThanOrEqual(matches.count, 20)
            XCTAssertLessThanOrEqual(text.utf8.count, 8192)
            refs += matches.map { $0["ref"] as! String }
            guard let continuation = text.split(separator: "\n").first(where: { $0.hasPrefix("more:") }) else { break }
            let command = String(continuation.dropFirst("more: ".count)).replacingOccurrences(of: " (same cached snapshot)", with: "")
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-f", "-c", "inspect() { printf '%s\\n' \"$@\"; }\n" + command]
            process.standardOutput = pipe
            try process.run()
            let arguments = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").map(String.init)
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertEqual(arguments, ["o1", "--query", query, "--offset", String(refs.count)])
            offset = try XCTUnwrap(Int(arguments.last ?? ""))
        } while offset < 30
        XCTAssertEqual(refs, stride(from: 0, to: 60, by: 2).map { "o1:e\($0 + 1)" })
    }

    func testQueryRespectsSubtreeAndDistinguishesIncompleteNoMatch() throws {
        let original = try observationFixture()
        let (cache, _) = try cache()
        _ = try cache.store(original)
        let subtree = try cache.inspect(ObservationReference("o1:e27"), offset: 0, query: "Web")
        XCTAssertEqual(try queryNodes(subtree).map { $0["ref"] as! String }, ["o1:e27"])
        let absent = try cache.inspect(ObservationReference("o1:e27"), offset: 0, query: "Done")
        XCTAssertTrue((absent["text"] as! String).contains("matched_nodes=0 searched_nodes=1"))
        XCTAssertTrue((absent["text"] as! String).contains("no_matches_in_capture=true"))
        XCTAssertFalse((absent["text"] as! String).contains("source_missing=true"))
        var metadata = original.metadata
        metadata["sourceTruncated"] = true
        _ = try cache.store(CapturedObservation(nodes: original.nodes, metadata: metadata, screenshot: original.screenshot))
        let incomplete = try cache.inspect(ObservationReference("o2"), offset: 0, query: "Calendar")
        XCTAssertTrue((incomplete["text"] as! String).contains("no_matches_in_capture=true"))
        XCTAssertTrue((incomplete["text"] as! String).contains("source_missing=true"))
        XCTAssertEqual(incomplete["refs"] as? String, "current")
        let stale = try cache.inspect(ObservationReference("o1:e27"), offset: 0, query: "Web")
        XCTAssertEqual(stale["refs"] as? String, "superseded")
        XCTAssertThrowsError(try cache.resolveCurrent(ObservationReference("o1:e27")))
        _ = try cache.store(original)
        XCTAssertThrowsError(try cache.inspect(ObservationReference("o1"), offset: 0, query: "Web"))
    }

    func testRecordedWebViewPreservesControlsValuesAndDistinctTargets() throws {
        let capture = try observationFixture()
        let lines = CompactAX.render(capture.nodes)
        XCTAssertEqual(lines, CompactAX.render(capture.nodes))
        let text = lines.joined(separator: "\n")
        for content in ["button \"Done\"", "button \"Show dialog\"", "Request notification permission",
                        "Notifications: notDetermined", "text_field \"Web input\" ax_value=\"Web text\"", "Web increment", "Web count: 0"] {
            XCTAssertTrue(text.contains(content), content)
        }
        XCTAssertEqual(lines.filter { $0.contains("web_view") }.count, 1)
        XCTAssertLessThan(lines.count, capture.nodes.count / 2)
        var first = capture.nodes[10].attributes
        first["index"] = 0; first["parent"] = NSNull(); first["enabled"] = false
        var second = first
        second["index"] = 1; second["parent"] = 0; second["identifier"] = "another-done"
        let duplicates = CompactAX.render([
            AXNode(index: 0, parent: nil, role: "button", attributes: first),
            AXNode(index: 1, parent: 0, role: "button", attributes: second)])
        XCTAssertEqual(duplicates.count, 2)
        XCTAssertTrue(duplicates.allSatisfy { $0.contains("disabled") && $0.contains("id=") })
    }

    func testSystemAlertScopeIsDistinctFromTargetAndKeepsBothChoices() throws {
        let capture = try observationFixture("system-alert.json")
        let (cache, _) = try cache()
        let response = try cache.store(capture)
        let text = try XCTUnwrap(response["text"] as? String)
        XCTAssertTrue(text.contains("scope=systemAlert"))
        XCTAssertTrue(text.contains("foreground=null"))
        XCTAssertTrue(text.contains("Would Like to Send You Notifications"))
        XCTAssertTrue(text.contains("Don’t Allow"))
        XCTAssertTrue(text.contains("button \"Allow\""))
        XCTAssertEqual(capture.metadata["sourceBundleId"] as? String, "com.apple.springboard")
    }

    func testInspectUsesOriginalAttributesAndDoesNotReviveStaleReferences() throws {
        let (cache, _) = try cache()
        let capture = try observationFixture()
        let stored = try cache.store(capture)
        let reference = try ObservationReference("o1:e27")
        XCTAssertEqual(try cache.resolveCurrent(reference).label, "Web input")
        let before = cache.beginAction()
        XCTAssertThrowsError(try cache.resolveCurrent(reference))
        cache.finishAction(previous: before, dispatched: false)
        XCTAssertNoThrow(try cache.resolveCurrent(reference))
        cache.finishAction(previous: cache.beginAction(), dispatched: true)
        XCTAssertThrowsError(try cache.resolveCurrent(reference))
        let details = try cache.inspect(reference, offset: 0)
        XCTAssertEqual(details["refs"] as? String, "invalidated")
        XCTAssertTrue((details["text"] as? String ?? "").contains("\"identifier\":\"\""))
        XCTAssertThrowsError(try cache.resolveCurrent(reference))
        let snapshot = try jsonObject(Data(contentsOf: URL(fileURLWithPath: stored["snapshot"] as! String)))
        let nodes = snapshot["nodes"] as! [[String: Any]]
        for (index, node) in capture.nodes.enumerated() {
            var saved = nodes[index]
            saved.removeValue(forKey: "ref"); saved.removeValue(forKey: "role")
            XCTAssertEqual(try jsonData(saved), try jsonData(node.attributes))
        }
        _ = try cache.store(capture)
        XCTAssertEqual(try cache.inspect(reference, offset: 0)["observation"] as? String, "o1")
        _ = try cache.store(capture)
        XCTAssertThrowsError(try cache.inspect(reference, offset: 0))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stored["screenshot"] as! String))
        try cache.clear()
        XCTAssertThrowsError(try cache.resolveCurrent(ObservationReference("o3:e27")))
    }

    func testOutputBudgetPaginationAndMissingSourceAreSeparate() throws {
        let original = try observationFixture()
        var nodes: [AXNode] = []
        for index in 0..<200 {
            var attributes = original.nodes[26].attributes
            attributes["index"] = index
            attributes["parent"] = index == 0 ? NSNull() : 0
            attributes["label"] = "field \(index)\n\"quoted\""
            attributes["value"] = String(repeating: "北京", count: 2000)
            nodes.append(AXNode(index: index, parent: index == 0 ? nil : 0, role: "text_field", attributes: attributes))
        }
        var metadata = original.metadata
        metadata["sourceTruncated"] = true
        let (cache, _) = try cache()
        let response = try cache.store(CapturedObservation(nodes: nodes, metadata: metadata, screenshot: original.screenshot))
        let text = response["text"] as! String
        XCTAssertLessThanOrEqual(text.utf8.count, 8192)
        XCTAssertLessThanOrEqual(text.split(separator: "\n").count, 60)
        XCTAssertTrue(text.contains("unexpanded="))
        XCTAssertTrue(text.contains("source_missing=true"))
        XCTAssertTrue(text.contains("detail_clipped=true"))
        XCTAssertTrue(text.contains("\\n\\\"quoted\\\""))
        var offset = 0
        var visited = 0
        repeat {
            let page = try cache.inspect(ObservationReference("o1"), offset: offset)["text"] as! String
            XCTAssertLessThanOrEqual(page.utf8.count, 8192)
            visited += page.split(separator: "\n").filter { $0.hasPrefix("[e") }.count
            if let line = page.split(separator: "\n").first(where: { $0.hasPrefix("more:") }),
               let range = line.range(of: "--offset ") {
                offset = Int(line[range.upperBound...].split(separator: " ")[0])!
            } else { break }
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
        let capture = try XCTestCapture.decode(["screenshotBase64": original.screenshot.base64EncodedString(),
            "axStatus": "unavailable", "axError": "foreground_app_unknown", "scope": "unknown"])
        XCTAssertTrue(capture.nodes.isEmpty)
        let (cache, _) = try cache()
        let response = try cache.store(capture)
        XCTAssertTrue((response["text"] as! String).contains("ax=unavailable"))
        XCTAssertTrue((response["text"] as! String).contains("foreground=null"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: response["screenshot"] as! String))
        let query = try cache.inspect(ObservationReference("o1"), offset: 0, query: "Calendar")["text"] as! String
        XCTAssertTrue(query.contains("ax=unavailable"))
        XCTAssertTrue(query.contains("matched_nodes=0 searched_nodes=0"))
        XCTAssertThrowsError(try cache.resolveCurrent(ObservationReference("o1:e1")))
    }
}
