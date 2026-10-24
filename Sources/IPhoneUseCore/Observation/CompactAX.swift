import Foundation
import CoreGraphics

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
            var keep = shouldKeep(
                node, nearest: nearest.map { nodes[$0] }, children: children[node.index].map { nodes[$0] })
            // Only fold identical generic container siblings, never equally named controls.
            if node.role == "group", node.identifier.isEmpty, let parent = node.parent {
                var signature = node.attributes
                signature.removeValue(forKey: "index")
                signature.removeValue(forKey: "parent")
                let key = quoted(signature)
                if signatures[parent, default: []].contains(key),
                    children[node.index].allSatisfy({
                        nodes[$0].role == "group" && nodes[$0].label.isEmpty && nodes[$0].value == nil
                            && nodes[$0].enabled
                    }) {
                    keep = false
                }
                signatures[parent, default: []].insert(key)
            }
            if keep {
                depths[node.index] = nearest.map { (depths[$0] ?? 0) + 1 } ?? 0
                ancestor[node.index] = node.index
                kept.append(node.index)
            } else {
                ancestor[node.index] = nearest
            }
        }
        let names = Dictionary(grouping: kept, by: { "\(nodes[$0].role):\(nodes[$0].label)" })
        return kept.map { renderNode(nodes[$0], depth: depths[$0] ?? 0, names: names) }
    }

    private static func shouldKeep(_ node: AXNode, nearest: AXNode?, children: [AXNode]) -> Bool {
        let generic = ["group", "application", "window"].contains(node.role)
        var keep =
            !generic || !node.label.isEmpty || !node.identifier.isEmpty || node.value != nil || !node.enabled
        if node.role == "application" { keep = false }
        if generic, !children.isEmpty, node.enabled, node.value == nil, node.identifier.isEmpty,
            children.contains(where: { $0.label == node.label }) {
            keep = false
        }
        if let nearest, node.role == "text", node.enabled, node.label == nearest.label,
            node.value == nil || (node.value as? String) == node.label {
            keep = false
        }
        if let nearest, node.role == "web_view", nearest.role == "web_view",
            node.label.isEmpty, node.identifier.isEmpty, node.value == nil, node.enabled {
            keep = false
        }
        return keep
    }

    private static func renderNode(_ node: AXNode, depth: Int, names: [String: [Int]]) -> String {
        var clipped = false
        func brief(_ value: Any) -> String {
            let string = (value as? String) ?? quoted(value)
            if string.count > 160 { clipped = true; return quoted(String(string.prefix(160)) + "…") }
            return quoted(value)
        }
        var line = String(repeating: "  ", count: depth) + "[\(node.ref)] \(node.role)"
        if !node.label.isEmpty { line += " \(brief(node.label))" }
        let input = ["text_field", "secure_text_field", "text_view", "search_field"].contains(node.role)
        let value = input ? node.attributes["value"] : node.value
        if let value, !(value is NSNull), input || (value as? String) != node.label {
            line += " ax_value=\(brief(value))"
        }
        if !node.identifier.isEmpty,
            node.label.isEmpty || names["\(node.role):\(node.label)", default: []].count > 1 {
            line += " id=\(brief(node.identifier))"
        }
        if !node.enabled { line += " disabled" }
        if clipped { line += " detail_clipped=true" }
        return line
    }
}
