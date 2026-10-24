import XCTest
@testable import IPhoneUseCore

final class RunnerAXReferenceTests: XCTestCase {
    func testOnlySelectedLeafContentMayChangeAfterAnEdit() {
        let step: [String: Any] = ["identityToken": "leaf", "label": "First name", "value": "old",
                                   "identifier": "First name", "childIndex": 1, "type": 49]
        func attributes(_ token: String?, _ allow: Bool) -> [String: Any] {
            RunnerAXTree.validationAttributes(
                step, leafToken: token, allowingContentChange: allow, value: nil, label: "")
        }
        XCTAssertTrue(NSDictionary(dictionary: attributes("leaf", false)).isEqual(to: step))
        XCTAssertTrue(NSDictionary(dictionary: attributes("other", true)).isEqual(to: step))
        XCTAssertTrue(NSDictionary(dictionary: attributes(nil, true)).isEqual(to: step))
        let edited = attributes("leaf", true)
        XCTAssertEqual(edited["label"] as? String, "")
        XCTAssertTrue(edited["value"] is NSNull)
        for key in ["identityToken", "identifier", "childIndex", "type"] {
            XCTAssertTrue(NSDictionary(dictionary: [key: edited[key]!]).isEqual(to: [key: step[key]!]))
        }
    }

    private final class Node {
        var children: [Node] = []
    }

    func testSameAttributesAtSamePathCannotReplaceObservedIdentity() throws {
        let root = Node(), first = Node(), second = Node()
        root.children = [first, second]
        var references = RunnerAXReferences<Node>()
        let path: [[String: Any]] = [
            ["childIndex": 0, "identityToken": references.register(root)],
            ["childIndex": 0, "identityToken": references.register(first)]
        ]
        func resolve() throws -> Node {
            try RunnerAXTree.resolve(
                root: root, path: path, access: .init(snapshot: { $0 }, children: { $0.children },
                bind: { _, selected in selected }), sameIdentity: { $0 === $1 }, matches: { node, step in
                    try references.identity(for: step["identityToken"] as? String) === node
                }).0
        }
        XCTAssertTrue(try resolve() === first)
        root.children.swapAt(0, 1)
        XCTAssertThrowsError(try resolve()) {
            XCTAssertEqual($0 as? RunnerAXTree.Failure, .targetChanged)
        }
        root.children[0] = Node()
        XCTAssertThrowsError(try resolve())
    }

    func testTakingObservationAllowsInternalValidationButRejectsCommandReplay() throws {
        var observed = RunnerAXReferences<Node>()
        let node = Node(), token = observed.register(Node())
        let selected = observed.register(node)
        let command = observed.take()
        XCTAssertTrue(try command.identity(for: selected) === node)
        XCTAssertTrue(try command.identity(for: selected) === node)
        XCTAssertThrowsError(try observed.identity(for: selected))
        XCTAssertThrowsError(try observed.take().identity(for: token))
        XCTAssertThrowsError(try command.identity(for: nil))
        XCTAssertThrowsError(try RunnerAXReferences<Node>().identity(for: selected))
    }

    func testNewObservationInvalidatesAllOldNodeReferences() throws {
        var observed = RunnerAXReferences<Node>()
        let node = Node(), old = observed.register(Node())
        observed = RunnerAXReferences()
        let current = observed.register(node)
        XCTAssertNotEqual(current, old)
        XCTAssertThrowsError(try observed.identity(for: old))
        XCTAssertTrue(try observed.identity(for: current) === node)
    }

    func testExecutionUsesNewSnapshotsRatherThanRetainedObservationTree() throws {
        let observedRoot = Node(), liveRoot = Node(), field = Node()
        observedRoot.children = [field]
        liveRoot.children = []
        var calls = 0
        XCTAssertThrowsError(try RunnerAXTree.resolve(
            root: observedRoot, path: [["childIndex": 0], ["childIndex": 0]],
            access: .init(snapshot: { _ in calls += 1; return liveRoot }, children: { $0.children },
            bind: { _, selected in selected }), sameIdentity: { $0 === $1 }, matches: { _, _ in true })) {
                XCTAssertEqual($0 as? RunnerAXTree.Failure, .pathChanged)
            }
        XCTAssertEqual(calls, 1)
    }
}
