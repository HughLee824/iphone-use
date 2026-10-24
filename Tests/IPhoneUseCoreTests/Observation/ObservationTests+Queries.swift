import XCTest
import Foundation
@testable import IPhoneUseCore

extension ObservationTests {

    func testQuerySearchesFullAttributesBeyondDefaultOutputAndKeepsGeometry() throws {
        let original = try observationFixture()
        let nodes = (0..<200).map { index -> AXNode in
            var attributes = original.nodes[26].attributes
            attributes["index"] = index; attributes["parent"] = index == 0 ? NSNull() : 0
            attributes["label"] = index == 185 ? "Calendar" : "Background \(index)"
            attributes["identifier"] = index == 185 ? "calendar.entry" : ""
            attributes["value"] = index == 185 ? String(repeating: "北京", count: 2000) + "TailNeedle" : ""
            attributes["enabled"] = index != 185
            return AXNode(
                index: index, parent: index == 0 ? nil : 0,
                role: index == 185 ? "button" : "text", attributes: attributes)
        }
        let (cache, _) = try cache()
        let stored = try cache.store(
            CapturedObservation(nodes: nodes, metadata: original.metadata, screenshot: original.screenshot))
        XCTAssertFalse(((try XCTUnwrap(stored["text"] as? String))).contains("Calendar"))
        XCTAssertTrue(((try XCTUnwrap(stored["text"] as? String))).contains("--query TEXT"))
        for query in ["cAlEnDaR", "calendar.entry", "tailneedle", "button"] {
            let result = try cache.inspect(ObservationReference("o1"), offset: 0, query: query)
            let matches = try queryNodes(result)
            XCTAssertEqual(matches.count, 1, query)
            let match = try XCTUnwrap(matches.first)
            XCTAssertEqual(match["ref"] as? String, "o1:e186")
            XCTAssertEqual(match["parentRef"] as? String, "o1:e1")
            XCTAssertEqual(match["enabled"] as? Bool, false)
            XCTAssertEqual(match["detail_clipped"] as? Bool, true)
            XCTAssertTrue(
                NSDictionary(dictionary: (try XCTUnwrap(match["frame"] as? [String: Any]))).isEqual(
                    to: (try XCTUnwrap(nodes[185].attributes["frame"] as? [String: Any]))))
            XCTAssertLessThanOrEqual(((try XCTUnwrap(result["text"] as? String))).utf8.count, 8192)
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
        _ = try cache.store(
            CapturedObservation(nodes: nodes, metadata: original.metadata, screenshot: original.screenshot))
        var offset = 0
        var refs: [String] = []
        repeat {
            let result = try cache.inspect(ObservationReference("o1"), offset: offset, query: query)
            let text = (try XCTUnwrap(result["text"] as? String))
            let matches = try queryNodes(result)
            XCTAssertTrue(text.contains("matched_nodes=30 searched_nodes=60"))
            XCTAssertLessThanOrEqual(matches.count, 20)
            XCTAssertLessThanOrEqual(text.utf8.count, 8192)
            refs += try matches.map { (try XCTUnwrap($0["ref"] as? String)) }
            guard let continuation = text.split(separator: "\n").first(where: { $0.hasPrefix("more:") })
            else { break }
            let command = String(continuation.dropFirst("more: ".count)).replacingOccurrences(
                of: " (same cached snapshot)", with: "")
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-f", "-c", "inspect() { printf '%s\\n' \"$@\"; }\n" + command]
            process.standardOutput = pipe
            try process.run()
            let arguments =
                (try XCTUnwrap(String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)))
                .split(
                    separator: "\n"
                ).map(String.init)
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
        XCTAssertEqual(try queryNodes(subtree).map { (try XCTUnwrap($0["ref"] as? String)) }, ["o1:e27"])
        let absent = try cache.inspect(ObservationReference("o1:e27"), offset: 0, query: "Done")
        XCTAssertTrue(
            ((try XCTUnwrap(absent["text"] as? String))).contains("matched_nodes=0 searched_nodes=1"))
        XCTAssertTrue(((try XCTUnwrap(absent["text"] as? String))).contains("no_matches_in_capture=true"))
        XCTAssertFalse(((try XCTUnwrap(absent["text"] as? String))).contains("source_missing=true"))
        var metadata = original.metadata
        metadata["sourceTruncated"] = true
        _ = try cache.store(
            CapturedObservation(nodes: original.nodes, metadata: metadata, screenshot: original.screenshot))
        let incomplete = try cache.inspect(ObservationReference("o2"), offset: 0, query: "Calendar")
        XCTAssertTrue(((try XCTUnwrap(incomplete["text"] as? String))).contains("no_matches_in_capture=true"))
        XCTAssertTrue(((try XCTUnwrap(incomplete["text"] as? String))).contains("source_missing=true"))
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
        for content in [
            "button \"Done\"", "button \"Show dialog\"", "Request notification permission",
            "Notifications: notDetermined", "text_field \"Web input\" ax_value=\"Web text\"", "Web increment",
            "Web count: 0"
        ] {
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
            AXNode(index: 1, parent: 0, role: "button", attributes: second)
        ])
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
        let snapshot = try jsonObject(
            Data(contentsOf: URL(fileURLWithPath: (try XCTUnwrap(stored["snapshot"] as? String)))))
        let nodes = (try XCTUnwrap(snapshot["nodes"] as? [[String: Any]]))
        for (index, node) in capture.nodes.enumerated() {
            var saved = nodes[index]
            saved.removeValue(forKey: "ref"); saved.removeValue(forKey: "role")
            XCTAssertEqual(try jsonData(saved), try jsonData(node.attributes))
        }
        _ = try cache.store(capture)
        XCTAssertEqual(try cache.inspect(reference, offset: 0)["observation"] as? String, "o1")
        _ = try cache.store(capture)
        XCTAssertThrowsError(try cache.inspect(reference, offset: 0))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: (try XCTUnwrap(stored["screenshot"] as? String))))
        try cache.clear()
        XCTAssertThrowsError(try cache.resolveCurrent(ObservationReference("o3:e27")))
    }
}
