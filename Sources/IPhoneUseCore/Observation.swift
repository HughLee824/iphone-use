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
        guard let value = attributes["value"], !(value is NSNull), (value as? String) != "" else {
            return nil
        }
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
            throw IPhoneUseError(
                "invalid_reference", "Use an observation or element reference, such as o1 or o1:e2")
        }
        let parts = value.split(separator: ":")
        observation = String(parts[0])
        if parts.count == 2 {
            guard let number = Int(parts[1].dropFirst()) else {
                throw IPhoneUseError("invalid_reference", "Element number is too large")
            }
            node = number - 1
        } else {
            node = nil
        }
    }
}

// Accessed only on the host's serial work queue. No device calls are made by inspect.
final class ObservationCache {
    struct Entry {
        let id: String
        let capture: CapturedObservation
        let directory: URL
        var validity: String
        let storedAtUptime: TimeInterval
    }
    let directory: URL
    var entries: [Entry] = []
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
            try saveJSON(
                ["observation": id, "metadata": capture.metadata, "nodes": nodes],
                to: location.appendingPathComponent("snapshot.json"))
            for file in ["screen.png", "snapshot.json"] {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: location.appendingPathComponent(file).path)
            }
        } catch {
            try? FileManager.default.removeItem(at: location)
            throw error
        }
        invalidate("superseded")
        entries.append(
            Entry(
                id: id, capture: capture, directory: location, validity: "current",
                storedAtUptime: ProcessInfo.processInfo.systemUptime))
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
                query.rangeOfCharacter(from: .controlCharacters) == nil
            else {
                throw IPhoneUseError(
                    "invalid_inspect_query",
                    "Query must be 1–256 UTF-8 bytes without control characters or blank-only text")
            }
        }
        guard let entry = entries.first(where: { $0.id == reference.observation }) else {
            throw IPhoneUseError(
                "observation_unavailable", "Snapshot is no longer cached; observe again for new data")
        }
        if let node = reference.node, !entry.capture.nodes.indices.contains(node) {
            throw IPhoneUseError(
                "node_not_captured", "This node was not captured; inspect cannot fetch missing source data")
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
            throw IPhoneUseError(
                "invalid_offset",
                "Offset must address a \(query == nil ? "node" : "match") in this cached subtree")
        }
        return result(
            entry, detail: Detail(reference: reference, indices: indices, offset: offset, query: query))
    }

    // A current reference is only a candidate: the backend must validate it on the live device.
    func resolveCurrent(_ reference: ObservationReference) throws -> AXNode {
        guard let entry = entries.first(where: { $0.id == reference.observation }), currentID == entry.id
        else {
            throw IPhoneUseError("stale_reference", "Observe again before using this reference for an action")
        }
        guard let index = reference.node, entry.capture.nodes.indices.contains(index) else {
            throw IPhoneUseError("node_not_captured", "An element captured in this observation is required")
        }
        return entry.capture.nodes[index]
    }

    func resolveTextConfirmation(_ reference: ObservationReference, nativeOnly: Bool = true) throws
        -> [String: Any] {
        guard reference.node == nil,
            let entry = entries.first(where: { $0.id == reference.observation }), currentID == entry.id,
            !nativeOnly || entry.capture.metadata["backend"] as? String == "apple-native"
        else {
            throw IPhoneUseError(
                "stale_reference", "Use the current screenshot oN after visually checking the text result")
        }
        var metadata = entry.capture.metadata
        metadata["hostStoredAtUptime"] = entry.storedAtUptime
        return metadata
    }

    func clear() throws {
        invalidate("session_closed")
        entries.removeAll()
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }
}

func quoted(_ value: Any) -> String {
    guard
        let data = try? JSONSerialization.data(
            withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
    else { return "null" }
    return String(data: data, encoding: .utf8)!
}
