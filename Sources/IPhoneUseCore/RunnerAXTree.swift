import Foundation

// Shared by the Runner and host tests. Capture is independent of presentation budgets.
enum RunnerAXTree {
    // Text edits may change both AX value and the text-derived label. Only the
    // selected leaf's content may change, after identity has been checked.
    static func validationAttributes(
        _ step: [String: Any], leafToken: String?, allowingContentChange: Bool,
        value: Any?, label: String
    ) -> [String: Any] {
        guard allowingContentChange, let leafToken, step["identityToken"] as? String == leafToken else {
            return step
        }
        var attributes = step
        attributes["value"] = value ?? NSNull()
        attributes["label"] = label
        return attributes
    }

    static func flatten<Node>(_ root: Node, children: (Node) -> [Node]) -> [(node: Node, parent: Int?)] {
        var result: [(node: Node, parent: Int?)] = []
        var pending: [(node: Node, parent: Int?)] = [(root, nil)]
        while let entry = pending.popLast() {
            let index = result.count
            result.append(entry)
            for child in children(entry.node).reversed() {
                pending.append((child, index))
            }
        }
        return result
    }

    enum Failure: String, Error {
        case invalidPath = "invalid_action"
        case pathChanged = "target_path_changed"
        case targetChanged = "target_changed"
        case geometryChanged = "target_geometry_changed"
    }

    // Walk the live snapshot, then bind that exact AX identity. Query child order
    // is not assumed to match snapshot child order (including across windows).
    static func resolve<Element, Snapshot>(
        root: Element, path: [[String: Any]], snapshot: (Element) throws -> Snapshot,
        children: (Snapshot) -> [Snapshot], bind: (Element, Snapshot) throws -> Element,
        sameIdentity: (Snapshot, Snapshot) throws -> Bool,
        matches: (Snapshot, [String: Any]) throws -> Bool,
        geometryMatches: ((Snapshot, [String: Any]) -> Bool)? = nil
    ) throws -> (Element, Snapshot) {
        var geometryChanged = false
        // Never short-circuit at a moving ancestor: a changed identity or path
        // farther down must win over the retryable geometry classification.
        func check(_ node: Snapshot, _ step: [String: Any]) throws -> Bool {
            guard try matches(node, step) else { return false }
            if geometryMatches?(node, step) == false { geometryChanged = true }
            return true
        }
        let selected = try walk(snapshot(root), path: path, children: children, matches: check)
        let element = try bind(root, selected)
        let resolved = try snapshot(element)
        guard try sameIdentity(selected, resolved), try check(resolved, path[path.count - 1]) else {
            throw Failure.targetChanged
        }
        // Revalidate the complete path after binding, not just the leaf's attributes.
        let latest = try walk(snapshot(root), path: path, children: children, matches: check)
        guard try sameIdentity(latest, resolved) else { throw Failure.targetChanged }
        guard !geometryChanged else { throw Failure.geometryChanged }
        return (element, latest)
    }

    private static func walk<Snapshot>(
        _ root: Snapshot, path: [[String: Any]], children: (Snapshot) -> [Snapshot],
        matches: (Snapshot, [String: Any]) throws -> Bool
    ) throws -> Snapshot {
        guard let first = path.first else { throw Failure.invalidPath }
        var current = root
        guard try matches(current, first) else { throw Failure.targetChanged }
        for step in path.dropFirst() {
            let descendants = children(current)
            guard let index = step["childIndex"] as? Int, descendants.indices.contains(index) else {
                throw Failure.pathChanged
            }
            current = descendants[index]
            guard try matches(current, step) else { throw Failure.targetChanged }
        }
        return current
    }
}

// Observation-local opaque references. Retain identities only for comparison;
// callers must still capture a fresh tree. Taking consumes the whole observation.
struct RunnerAXReferences<Identity> {
    enum Failure: String, Error { case stale = "stale_target_reference" }
    private var identities: [String: Identity] = [:]

    mutating func register(_ identity: Identity) -> String {
        let token = UUID().uuidString
        identities[token] = identity
        return token
    }

    func identity(for token: String?) throws -> Identity {
        guard let token, let identity = identities[token] else { throw Failure.stale }
        return identity
    }

    mutating func take() -> Self {
        let previous = self
        self = Self()
        return previous
    }
}
