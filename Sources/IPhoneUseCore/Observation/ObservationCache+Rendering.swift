import Foundation
import CoreGraphics

extension ObservationCache {

    struct Detail {
        let reference: ObservationReference
        let indices: [Int]
        let offset: Int
        let query: String?
    }

    func subtree(_ nodes: [AXNode], root: Int?) -> [Int] {
        guard let root else { return Array(nodes.indices) }
        var included: Set<Int> = [root]
        for node in nodes where node.parent.map({ included.contains($0) }) == true {
            included.insert(node.index)
        }
        return nodes.indices.filter { included.contains($0) }
    }

    func result(_ entry: Entry, detail: Detail?) -> [String: Any] {
        let capture = entry.capture
        let metadata = capture.metadata
        let screenshot = entry.directory.appendingPathComponent("screen.png").path
        let snapshot = entry.directory.appendingPathComponent("snapshot.json").path
        var lines = [
            """
            observation=\(entry.id) refs=\(entry.validity) scope=\(metadata["scope"] ?? "unknown")\
             target=\(quoted(metadata["targetBundleId"] ?? NSNull()))\
             foreground=\(quoted(metadata["foregroundBundleId"] ?? NSNull()))
            """,
            """
            screenshot=\(quoted(screenshot))\
             pixels=\(metadata["screenshotWidth"] ?? "?")x\(metadata["screenshotHeight"] ?? "?")\
             screen_points=\(quoted(metadata["screenFrame"] ?? NSNull()))
            """,
            """
            ax=\(metadata["axStatus"] ?? "unavailable")\
             source_truncated=\(metadata["sourceTruncated"] ?? "unknown")\
             ax_started=\(metadata["snapshotStartedAt"] ?? "unknown")\
             ax_finished=\(metadata["snapshotFinishedAt"] ?? "unknown")\
             screenshot_at=\(metadata["screenshotCapturedAt"] ?? "unknown")
            """
        ]
        if let error = metadata["axError"] as? String {
            lines.append(
                "ax_error=\(quoted(String(error.prefix(256))))\(error.count > 256 ? " detail_clipped=true" : "")"
            )
        }
        let footer = "snapshot=\(quoted(snapshot)) (cached source; inspect \(entry.id) for details)"
        appendNativeMetadata(metadata, to: &lines)
        appendContent(entry, detail: detail, footer: footer, lines: &lines)
        if metadata["sourceTruncated"] as? Bool == true {
            lines.append("source_missing=true; uncaptured nodes cannot be expanded from this snapshot")
        }
        lines.append(footer)
        var response: [String: Any] = [
            "observation": entry.id, "refs": entry.validity, "screenshot": screenshot, "snapshot": snapshot,
            "text": lines.joined(separator: "\n")
        ]
        if let query = detail?.query { response["query"] = query }
        return response
    }

    private func appendNativeMetadata(_ metadata: [String: Any], to lines: inout [String]) {
        if metadata["backend"] as? String == "apple-native" {
            lines.append(
                """
                backend=apple-native coordinate_space=screen_points\
                 pixels_per_point=\(metadata["pointScale"] ?? "unknown")\
                 rotation=\(metadata["displayRotation"] ?? "unknown")
                """
            )
            lines.append(
                """
                device=\(quoted(metadata["deviceID"] ?? NSNull()))\
                 generation=\(quoted(metadata["sessionGeneration"] ?? NSNull()))\
                 capture_started=\(metadata["captureStartedAt"] ?? "unknown")\
                 capture_completed=\(metadata["captureCompletedAt"] ?? "unknown")
                """
            )
            lines.append(
                "foreground=unverified keyboard_state=unknown; locate targets visually in the original screenshot"
            )
            if let stability = metadata["postActionStability"] as? [String: Any] {
                lines.append(
                    """
                    post_action_stable=\(stability["stable"] ?? false)\
                     reason=\(stability["reason"] ?? "unknown"); visual stability does not confirm action success
                    """
                )
            }
        }
    }

    private func appendContent(_ entry: Entry, detail: Detail?, footer: String, lines: inout [String]) {
        if let detail {
            appendDetail(entry, detail: detail, footer: footer, lines: &lines)
        } else {
            appendCompact(entry, footer: footer, lines: &lines)
        }
    }

    private func appendDetail(_ entry: Entry, detail: Detail, footer: String, lines: inout [String]) {
        let capture = entry.capture
        var body: [String] = []
        var nextOffset: Int?
        let reference = detail.reference, indices = detail.indices, offset = detail.offset,
            query = detail.query
        let target = reference.node.map { "\(entry.id):e\($0 + 1)" } ?? entry.id
        // A continuation is shell text, not JSON: preserve literal quotes, $, and backticks.
        let queryOption =
            query.map { " --query '" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" } ?? ""
        if let query {
            lines.append(
                """
                inspect=\(target) query=\(quoted(query)) offset=\(offset) matched_nodes=\(indices.count)\
                 searched_nodes=\(subtree(capture.nodes, root: reference.node).count)
                """
            )
            if indices.isEmpty {
                lines.append("no_matches_in_capture=true; this does not prove absence from the UI")
            }
        } else {
            lines.append("inspect=\(target) offset=\(offset) captured_nodes=\(indices.count)")
        }
        for (position, index) in indices.enumerated().dropFirst(offset) {
            let node = capture.nodes[index]
            var attributes = node.attributes
            attributes["ref"] = "\(entry.id):\(node.ref)"
            attributes["role"] = node.role
            if query != nil {
                attributes["parentRef"] = node.parent.map { "\(entry.id):e\($0 + 1)" } as Any? ?? NSNull()
                attributes.removeValue(forKey: "index"); attributes.removeValue(forKey: "parent")
                for key in ["label", "identifier", "value"] {
                    if let value = attributes[key] as? String, value.count > 160 {
                        attributes[key] = String(value.prefix(160)) + "…"
                        attributes["detail_clipped"] = true
                    }
                }
            }
            var line = String(data: (try? jsonData(attributes)) ?? Data(), encoding: .utf8)!
            if line.utf8.count > 4096 {
                line = "[\(node.ref)] detail_exceeds_budget; full attributes in snapshot file"
            }
            if body.count == 20 || !fits(lines + body + [line, footer], reserve: 400 + queryOption.utf8.count) {
                nextOffset = position; break
            }
            body.append(line)
        }
        lines += body
        if let nextOffset {
            lines.append(
                "more: inspect \(target)\(queryOption) --offset \(nextOffset) (same cached snapshot)")
        }
    }

    private func appendCompact(_ entry: Entry, footer: String, lines: inout [String]) {
        let capture = entry.capture
        var body: [String] = []
        let compact = CompactAX.render(capture.nodes)
        var shown = 0
        for line in compact {
            if lines.count + body.count + 3 >= 60 || !fits(lines + body + [line, footer], reserve: 400) {
                break
            }
            body.append(line)
            shown += 1
        }
        lines += body
        if shown < compact.count {
            lines.append(
                """
                unexpanded=\(compact.count - shown) lines; inspect \(entry.id) --query TEXT searches all\
                 captured nodes; inspect an element reference for its subtree
                """
            )
        }
    }

    private func fits(_ lines: [String], reserve: Int) -> Bool {
        lines.joined(separator: "\n").utf8.count + reserve <= 8192
    }
}
