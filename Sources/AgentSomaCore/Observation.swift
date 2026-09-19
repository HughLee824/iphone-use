import Foundation
import CoreGraphics

struct AXNode {
    let index: Int
    let parent: Int?
    let role: String
    let attributes: [String: Any]

    var label: String { attributes["label"] as? String ?? "" }
    var identifier: String { attributes["identifier"] as? String ?? "" }
    var enabled: Bool { attributes["enabled"] as? Bool ?? true }
    var value: Any? {
        guard let value = attributes["value"], !(value is NSNull), (value as? String) != "" else { return nil }
        return value
    }
    var ref: String { "e\(index + 1)" }
}

// Device facts only. Backend-specific element types are translated by the adapter.
struct CapturedObservation {
    let nodes: [AXNode]
    let metadata: [String: Any]
    let screenshot: Data
}

struct ObservationReference {
    let observation: String
    let node: Int?

    init(_ value: String) throws {
        guard value.range(of: "^o[1-9][0-9]*(?::e[1-9][0-9]*)?$", options: .regularExpression) != nil else {
            throw SomaError("invalid_reference", "Use an observation or element reference, such as o1 or o1:e2")
        }
        let parts = value.split(separator: ":")
        observation = String(parts[0])
        if parts.count == 2 {
            guard let number = Int(parts[1].dropFirst()) else { throw SomaError("invalid_reference", "Element number is too large") }
            node = number - 1
        } else { node = nil }
    }
}

// Accessed only on the host's serial work queue. No device calls are made by inspect.
final class ObservationCache {
    private struct Entry {
        let id: String
        let capture: CapturedObservation
        let directory: URL
        var validity: String
    }
    private let directory: URL
    private var entries: [Entry] = []
    private var nextID = 1
    private(set) var currentID: String?

    init(directory: URL) { self.directory = directory.appendingPathComponent("observations") }

    func invalidate(_ reason: String) {
        if let index = entries.firstIndex(where: { $0.id == currentID }) { entries[index].validity = reason }
        currentID = nil
    }

    func beginAction() -> String? {
        let previous = currentID
        invalidate("action_pending")
        return previous
    }

    func finishAction(previous: String?, dispatched: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == previous }) else { return }
        entries[index].validity = dispatched ? "invalidated" : "current"
        if !dispatched { currentID = previous }
    }

    func store(_ capture: CapturedObservation) throws -> [String: Any] {
        let id = "o\(nextID)"
        nextID += 1
        let location = directory.appendingPathComponent(id)
        try SessionPaths.secureDirectory(directory)
        try SessionPaths.secureDirectory(location)
        do {
            try capture.screenshot.write(to: location.appendingPathComponent("screen.png"), options: .atomic)
            let nodes = capture.nodes.map { node -> [String: Any] in
                var attributes = node.attributes
                attributes["ref"] = "\(id):\(node.ref)"
                attributes["role"] = node.role
                return attributes
            }
            try saveJSON(["observation": id, "metadata": capture.metadata, "nodes": nodes],
                         to: location.appendingPathComponent("snapshot.json"))
            for file in ["screen.png", "snapshot.json"] {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: location.appendingPathComponent(file).path)
            }
        } catch {
            try? FileManager.default.removeItem(at: location)
            throw error
        }
        invalidate("superseded")
        entries.append(Entry(id: id, capture: capture, directory: location, validity: "current"))
        currentID = id
        if entries.count > 2 {
            try FileManager.default.removeItem(at: entries[0].directory)
            entries.removeFirst()
        }
        return result(entries.last!, detail: nil)
    }

    func inspect(_ reference: ObservationReference, offset: Int, query: String? = nil) throws -> [String: Any] {
        if let query {
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, query.utf8.count <= 256,
                  query.rangeOfCharacter(from: .controlCharacters) == nil else {
                throw SomaError("invalid_inspect_query", "Query must be 1–256 UTF-8 bytes without control characters or blank-only text")
            }
        }
        guard let entry = entries.first(where: { $0.id == reference.observation }) else {
            throw SomaError("observation_unavailable", "Snapshot is no longer cached; observe again for new data")
        }
        if let node = reference.node, !entry.capture.nodes.indices.contains(node) {
            throw SomaError("node_not_captured", "This node was not captured; inspect cannot fetch missing source data")
        }
        var indices = subtree(entry.capture.nodes, root: reference.node)
        if let query {
            indices = indices.filter { index in
                let node = entry.capture.nodes[index]
                let value = node.value.map { ($0 as? String) ?? quoted($0) } ?? ""
                return [node.label, node.identifier, value, node.role].contains {
                    $0.range(of: query, options: .caseInsensitive) != nil
                }
            }
        }
        guard offset >= 0, offset < indices.count || (offset == 0 && indices.isEmpty) else {
            throw SomaError("invalid_offset", "Offset must address a \(query == nil ? "node" : "match") in this cached subtree")
        }
        return result(entry, detail: (reference, indices, offset, query))
    }

    // A current reference is only a candidate: the backend must validate it on the live device.
    func resolveCurrent(_ reference: ObservationReference) throws -> AXNode {
        guard let entry = entries.first(where: { $0.id == reference.observation }), currentID == entry.id else {
            throw SomaError("stale_reference", "Observe again before using this reference for an action")
        }
        guard let index = reference.node, entry.capture.nodes.indices.contains(index) else {
            throw SomaError("node_not_captured", "An element captured in this observation is required")
        }
        return entry.capture.nodes[index]
    }

    func resolveTarget(for action: DeviceAction) throws -> ObservedTarget {
        let reference = action.reference
        guard let entry = entries.first(where: { $0.id == reference.observation }), currentID == entry.id else {
            throw SomaError("stale_reference", "Observe again before using this reference for an action")
        }
        if entry.capture.metadata["backend"] as? String == "apple-native" {
            if action.kind == "type", action.reference.node == nil {
                _ = try NativeKeyboard.keys(for: action.fields["text"] as! String, mode: action.fields["mode"] as! String)
                guard let raw = entry.capture.metadata["screenContext"] as? [String: Any] else { throw ScreenGuard.Failure.invalidGuard }
                let context = try JSONDecoder().decode(ScreenContext.self, from: jsonData(raw))
                let guardValue = try ScreenGuard(png: entry.capture.screenshot, context: context, rects: [action.textRegion ?? context.screen], policy: .init())
                return ObservedTarget(context: entry.capture.metadata, path: [], textGuard: guardValue)
            }
            guard ["tap", "swipe"].contains(action.kind), action.coordinate else {
                throw SomaError("native_action_unsupported", "Use tap or swipe oN with native screenshot screen-point coordinates")
            }
            return try coordinateTarget(for: action, capture: entry.capture)
        }
        guard let scope = entry.capture.metadata["scope"] as? String, ["app", "appAlert", "systemAlert"].contains(scope),
              !entry.capture.nodes.isEmpty else { throw SomaError("target_context_unknown", "Observe a known app or alert before acting") }
        if ["tap", "swipe"].contains(action.kind) { return try coordinateTarget(for: action, capture: entry.capture) }
        var index = 0
        if !action.coordinate {
            let node = try resolveCurrent(reference)
            if ["type", "press"].contains(action.kind), !["text_field", "secure_text_field", "text_view", "search_field"].contains(node.role) {
                throw SomaError("not_text_input", "The reference must identify a text input")
            }
            index = node.index
        }
        var path: [[String: Any]] = []
        while true {
            let node = entry.capture.nodes[index]
            var step = node.attributes
            step.removeValue(forKey: "index"); step.removeValue(forKey: "parent")
            step["childIndex"] = node.parent.map { parent in entry.capture.nodes[..<index].filter { $0.parent == parent }.count } ?? 0
            path.insert(step, at: 0)
            guard let parent = node.parent else { break }
            index = parent
        }
        return ObservedTarget(context: entry.capture.metadata, path: path)
    }

    private func coordinateTarget(for action: DeviceAction, capture: CapturedObservation) throws -> ObservedTarget {
        guard let rawContext = capture.metadata["screenContext"] as? [String: Any],
              let context = try? JSONDecoder().decode(ScreenContext.self, from: jsonData(rawContext)), context.valid else {
            throw ActionFailure(code: "target_context_unknown", description: "Observe again with a current Runner before using guarded coordinates",
                                possiblyExecuted: false, requiresObservation: true)
        }
        func visibleRect(_ reference: ObservationReference) throws -> CGRect {
            let node = try resolveCurrent(reference)
            guard let raw = node.attributes["frame"] as? [String: Any],
                  let rect = try? JSONDecoder().decode(ScreenRect.self, from: jsonData(raw)), rect.valid else {
                throw SomaError("invalid_target_frame", "The captured element has no usable bounds")
            }
            let visible = rect.cgRect.intersection(context.scope.cgRect)
            guard !visible.isNull, visible.width >= 1, visible.height >= 1 else {
                throw SomaError("target_not_visible", "The captured element is outside the observed scope; no automatic scrolling")
            }
            return visible
        }
        let start: CGPoint
        var end: CGPoint?
        if action.coordinate {
            if action.kind == "tap" { start = CGPoint(x: action.fields["x"] as! Double, y: action.fields["y"] as! Double) }
            else {
                start = CGPoint(x: action.fields["fromX"] as! Double, y: action.fields["fromY"] as! Double)
                end = CGPoint(x: action.fields["toX"] as! Double, y: action.fields["toY"] as! Double)
            }
        } else {
            guard try resolveCurrent(action.reference).enabled else { throw SomaError("target_disabled", "The observed element is disabled") }
            let rect = try visibleRect(action.reference)
            if action.kind == "tap" { start = CGPoint(x: rect.midX, y: rect.midY) }
            else {
                let direction = action.fields["direction"] as! String
                let vertical = ["up", "down"].contains(direction)
                let low = CGPoint(x: vertical ? rect.midX : rect.minX + rect.width * 0.2,
                                  y: vertical ? rect.minY + rect.height * 0.2 : rect.midY)
                let high = CGPoint(x: vertical ? rect.midX : rect.minX + rect.width * 0.8,
                                   y: vertical ? rect.minY + rect.height * 0.8 : rect.midY)
                start = ["up", "left"].contains(direction) ? high : low
                end = ["up", "left"].contains(direction) ? low : high
            }
        }
        guard context.scope.cgRect.contains(start), end.map({ context.scope.cgRect.contains($0) }) ?? true else {
            throw SomaError("invalid_screen_point", "Gesture coordinates must stay inside the observed app or alert")
        }
        var rects = CoordinateGesture.actionRegions(start: start, end: end, screen: context.screen.cgRect)
        rects += try action.protectedReferences.map { ScreenRect(try visibleRect($0)) }
        let guardValue: ScreenGuard
        do { guardValue = try ScreenGuard(png: capture.screenshot, context: context, rects: rects, policy: action.guardPolicy) }
        catch {
            throw ActionFailure(code: (error as? ScreenGuard.Failure)?.rawValue ?? "screen_guard_unavailable",
                                description: "Cannot prepare a screen guard from this observation; observe again",
                                possiblyExecuted: false, requiresObservation: true)
        }
        let gesture = CoordinateGesture(start: start, end: end, screenGuard: guardValue, motion: action.swipeMotion)
        guard gesture.withinMotionBudget else {
            throw SomaError("swipe_duration_exceeded", "Estimated swipe motion exceeds 10 seconds; use a shorter distance, faster velocity or shorter holds")
        }
        try gesture.validate(kind: action.kind)
        return ObservedTarget(context: capture.metadata, path: [], gesture: gesture)
    }

    func clear() throws {
        invalidate("session_closed")
        entries.removeAll()
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    private func subtree(_ nodes: [AXNode], root: Int?) -> [Int] {
        guard let root else { return Array(nodes.indices) }
        var included: Set<Int> = [root]
        for node in nodes where node.parent.map({ included.contains($0) }) == true { included.insert(node.index) }
        return nodes.indices.filter { included.contains($0) }
    }

    private func result(_ entry: Entry, detail: (ObservationReference, [Int], Int, String?)?) -> [String: Any] {
        let capture = entry.capture
        let metadata = capture.metadata
        let screenshot = entry.directory.appendingPathComponent("screen.png").path
        let snapshot = entry.directory.appendingPathComponent("snapshot.json").path
        var lines = ["observation=\(entry.id) refs=\(entry.validity) scope=\(metadata["scope"] ?? "unknown") target=\(quoted(metadata["targetBundleId"] ?? NSNull())) foreground=\(quoted(metadata["foregroundBundleId"] ?? NSNull()))",
            "screenshot=\(quoted(screenshot)) pixels=\(metadata["screenshotWidth"] ?? "?")x\(metadata["screenshotHeight"] ?? "?") screen_points=\(quoted(metadata["screenFrame"] ?? NSNull()))",
            "ax=\(metadata["axStatus"] ?? "unavailable") source_truncated=\(metadata["sourceTruncated"] ?? "unknown") ax_started=\(metadata["snapshotStartedAt"] ?? "unknown") ax_finished=\(metadata["snapshotFinishedAt"] ?? "unknown") screenshot_at=\(metadata["screenshotCapturedAt"] ?? "unknown")"]
        if let error = metadata["axError"] as? String {
            lines.append("ax_error=\(quoted(String(error.prefix(256))))\(error.count > 256 ? " detail_clipped=true" : "")")
        }
        let footer = "snapshot=\(quoted(snapshot)) (cached source; inspect \(entry.id) for details)"
        if metadata["backend"] as? String == "apple-native" {
            lines.append("backend=apple-native coordinate_space=screen_points pixels_per_point=\(metadata["pointScale"] ?? "unknown") rotation=\(metadata["displayRotation"] ?? "unknown")")
            lines.append("device=\(quoted(metadata["deviceID"] ?? NSNull())) generation=\(quoted(metadata["sessionGeneration"] ?? NSNull())) capture_started=\(metadata["captureStartedAt"] ?? "unknown") capture_completed=\(metadata["captureCompletedAt"] ?? "unknown")")
            lines.append("foreground=unverified keyboard_state=unknown; locate targets visually in the original screenshot")
        }
        var body: [String] = []
        var nextOffset: Int?
        if let (reference, indices, offset, query) = detail {
            let target = reference.node.map { "\(entry.id):e\($0 + 1)" } ?? entry.id
            // A continuation is shell text, not JSON: preserve literal quotes, $, and backticks.
            let queryOption = query.map { " --query '" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" } ?? ""
            if let query {
                lines.append("inspect=\(target) query=\(quoted(query)) offset=\(offset) matched_nodes=\(indices.count) searched_nodes=\(subtree(capture.nodes, root: reference.node).count)")
                if indices.isEmpty { lines.append("no_matches_in_capture=true; this does not prove absence from the UI") }
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
                var line = String(decoding: (try? jsonData(attributes)) ?? Data(), as: UTF8.self)
                if line.utf8.count > 4096 { line = "[\(node.ref)] detail_exceeds_budget; full attributes in snapshot file" }
                if body.count == 20 || !fits(lines + body + [line, footer], reserve: 400 + queryOption.utf8.count) { nextOffset = position; break }
                body.append(line)
            }
            lines += body
            if let nextOffset { lines.append("more: inspect \(target)\(queryOption) --offset \(nextOffset) (same cached snapshot)") }
        } else {
            let compact = CompactAX.render(capture.nodes)
            var shown = 0
            for line in compact {
                if lines.count + body.count + 3 >= 60 || !fits(lines + body + [line, footer], reserve: 400) { break }
                body.append(line)
                shown += 1
            }
            lines += body
            if shown < compact.count {
                lines.append("unexpanded=\(compact.count - shown) lines; inspect \(entry.id) --query TEXT searches all captured nodes; inspect an element reference for its subtree")
            }
        }
        if metadata["sourceTruncated"] as? Bool == true { lines.append("source_missing=true; uncaptured nodes cannot be expanded from this snapshot") }
        lines.append(footer)
        var response: [String: Any] = ["observation": entry.id, "refs": entry.validity, "screenshot": screenshot, "snapshot": snapshot,
                                      "text": lines.joined(separator: "\n")]
        if let query = detail?.3 { response["query"] = query }
        return response
    }

    private func fits(_ lines: [String], reserve: Int) -> Bool { lines.joined(separator: "\n").utf8.count + reserve <= 8192 }
}

private func quoted(_ value: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]) else { return "null" }
    return String(decoding: data, as: UTF8.self)
}

enum CompactAX {
    static func render(_ nodes: [AXNode]) -> [String] {
        var children = Array(repeating: [Int](), count: nodes.count)
        for node in nodes { if let parent = node.parent { children[parent].append(node.index) } }
        var kept: [Int] = []
        var ancestor: [Int: Int] = [:]
        var depths: [Int: Int] = [:]
        var signatures: [Int: Set<String>] = [:]
        for node in nodes {
            let nearest = node.parent.flatMap { ancestor[$0] }
            let generic = ["group", "application", "window"].contains(node.role)
            var keep = !generic || !node.label.isEmpty || !node.identifier.isEmpty || node.value != nil || !node.enabled
            if node.role == "application" { keep = false }
            if generic, !children[node.index].isEmpty, node.enabled, node.value == nil, node.identifier.isEmpty,
               children[node.index].contains(where: { nodes[$0].label == node.label }) { keep = false }
            if let nearest, node.role == "text", node.enabled, node.label == nodes[nearest].label,
               node.value == nil || (node.value as? String) == node.label { keep = false }
            if let nearest, node.role == "web_view", nodes[nearest].role == "web_view",
               node.label.isEmpty, node.identifier.isEmpty, node.value == nil, node.enabled { keep = false }
            // Only fold identical generic container siblings, never equally named controls.
            if node.role == "group", node.identifier.isEmpty, let parent = node.parent {
                var signature = node.attributes
                signature.removeValue(forKey: "index")
                signature.removeValue(forKey: "parent")
                let key = quoted(signature)
                if signatures[parent, default: []].contains(key), children[node.index].allSatisfy({
                    nodes[$0].role == "group" && nodes[$0].label.isEmpty && nodes[$0].value == nil && nodes[$0].enabled
                }) { keep = false }
                signatures[parent, default: []].insert(key)
            }
            if keep {
                depths[node.index] = nearest.map { (depths[$0] ?? 0) + 1 } ?? 0
                ancestor[node.index] = node.index
                kept.append(node.index)
            } else { ancestor[node.index] = nearest }
        }
        let names = Dictionary(grouping: kept, by: { "\(nodes[$0].role):\(nodes[$0].label)" })
        return kept.map { index in
            let node = nodes[index]
            var clipped = false
            func brief(_ value: Any) -> String {
                let string = (value as? String) ?? quoted(value)
                if string.count > 160 { clipped = true; return quoted(String(string.prefix(160)) + "…") }
                return quoted(value)
            }
            var line = String(repeating: "  ", count: depths[index] ?? 0) + "[\(node.ref)] \(node.role)"
            if !node.label.isEmpty { line += " \(brief(node.label))" }
            let input = ["text_field", "secure_text_field", "text_view", "search_field"].contains(node.role)
            let value = input ? node.attributes["value"] : node.value
            if let value, !(value is NSNull), input || (value as? String) != node.label { line += " ax_value=\(brief(value))" }
            if !node.identifier.isEmpty, node.label.isEmpty || names["\(node.role):\(node.label)", default: []].count > 1 {
                line += " id=\(brief(node.identifier))"
            }
            if !node.enabled { line += " disabled" }
            if clipped { line += " detail_clipped=true" }
            return line
        }
    }
}
