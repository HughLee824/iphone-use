import XCTest
@testable import IPhoneUseCore

final class RunnerAXTreeTests: XCTestCase {
    private final class Node {
        var attributes: [String: Any]
        var children: [Node]

        init(_ value: String, children: [Node] = [], type: Int = 52) {
            attributes = ["type": type, "identifier": "", "label": "", "value": value]
            self.children = children
        }
    }

    private func step(_ node: Node, index: Int) -> [String: Any] {
        node.attributes.merging(["childIndex": index]) { _, new in new }
    }

    private func matches(_ node: Node, _ expected: [String: Any]) -> Bool {
        var attributes = expected
        attributes.removeValue(forKey: "childIndex")
        return NSDictionary(dictionary: node.attributes).isEqual(to: attributes)
    }

    private func resolve(_ root: Node, path: [[String: Any]]) throws -> Node {
        try RunnerAXTree.resolve(
            root: root, path: path, access: .init(snapshot: { $0 }, children: { $0.children },
            bind: { _, selected in selected }), sameIdentity: { $0 === $1 }, matches: matches).0
    }

    func testDuplicateUnlabelledTextViewsResolveWithinTheirOwnBranches() throws {
        let search = Node("Shanghai weekend")
        let summary = Node("Places to visit this weekend")
        let header = Node("", children: [search], type: 1)
        let body = Node("", children: [summary], type: 1)
        let root = Node("rednote", children: [header, body], type: 2)
        // Both leaves match the old global type + identifier + label selector.
        XCTAssertEqual(search.attributes["type"] as? Int, summary.attributes["type"] as? Int)
        let path = [step(root, index: 0), step(header, index: 0), step(search, index: 0)]
        XCTAssertTrue(try resolve(root, path: path) === search)
        XCTAssertTrue(try resolve(root, path: [step(root, index: 0), step(body, index: 1),
                                             step(summary, index: 0)]) === summary)
        root.children.swapAt(0, 1)
        XCTAssertThrowsError(try resolve(root, path: path)) {
            XCTAssertEqual($0 as? RunnerAXTree.Failure, .targetChanged)
        }
    }

    func testMissingChildAndChangedAttributesRejectBeforeReturningTarget() throws {
        let field = Node("old")
        let root = Node("app", children: [field], type: 2)
        let path = [step(root, index: 0), step(field, index: 0)]
        XCTAssertTrue(try resolve(root, path: path) === field)
        field.attributes["value"] = "new"
        XCTAssertThrowsError(try resolve(root, path: path)) {
            XCTAssertEqual($0 as? RunnerAXTree.Failure, .targetChanged)
        }
        root.children = []
        XCTAssertThrowsError(try resolve(root, path: path)) {
            XCTAssertEqual($0 as? RunnerAXTree.Failure, .pathChanged)
        }
        XCTAssertThrowsError(try resolve(root, path: []))
        XCTAssertThrowsError(try resolve(root, path: [step(root, index: 0), step(field, index: -1)]))
    }

    func testBindingCannotReturnAnotherElementEvenWithIdenticalAttributes() throws {
        let field = Node("search")
        let other = Node("search")
        let root = Node("app", children: [field, other], type: 2)
        XCTAssertThrowsError(try RunnerAXTree.resolve(
            root: root, path: [step(root, index: 0), step(field, index: 0)],
            access: .init(snapshot: { $0 }, children: { $0.children }, bind: { _, _ in other }),
            sameIdentity: { $0 === $1 }, matches: matches)) {
                XCTAssertEqual($0 as? RunnerAXTree.Failure, .targetChanged)
            }
    }

    func testBindingUsesPathSelectedSnapshotRegardlessOfQueryOrder() throws {
        let search = Node("search")
        let summary = Node("summary")
        let firstWindow = Node("", children: [search], type: 4)
        let secondWindow = Node("", children: [summary], type: 4)
        let root = Node("app", children: [firstWindow, secondWindow], type: 2)
        // XCTest child queries can include both windows' descendants, in a
        // different order. The binding must receive the path-selected object.
        let queryResults = [summary, search]
        let result = try RunnerAXTree.resolve(
            root: root, path: [step(root, index: 0), step(firstWindow, index: 0), step(search, index: 0)],
            access: .init(snapshot: { $0 }, children: { $0.children }, bind: { _, selected in
                XCTAssertTrue(selected === search)
                return try XCTUnwrap(queryResults.first { $0 === selected })
            }), sameIdentity: { $0 === $1 }, matches: matches)
        XCTAssertTrue(result.0 === search)
    }

    func testCompletePathAndIdentityAreRevalidatedAfterBinding() throws {
        let field = Node("search")
        let replacement = Node("search")
        let branch = Node("", children: [field], type: 1)
        let root = Node("app", children: [branch], type: 2)
        let path = [step(root, index: 0), step(branch, index: 0), step(field, index: 0)]
        XCTAssertThrowsError(try RunnerAXTree.resolve(
            root: root, path: path, access: .init(snapshot: { $0 }, children: { $0.children },
            bind: { _, selected in
                branch.children[0] = replacement
                return selected
            }), sameIdentity: { $0 === $1 }, matches: matches)) {
                XCTAssertEqual($0 as? RunnerAXTree.Failure, .targetChanged)
            }
        branch.children = [field]
        XCTAssertThrowsError(try RunnerAXTree.resolve(
            root: root, path: path, access: .init(snapshot: { $0 }, children: { $0.children },
            bind: { _, selected in
                branch.attributes["value"] = "changed ancestor"
                return selected
            }), sameIdentity: { $0 === $1 }, matches: matches)) {
                XCTAssertEqual($0 as? RunnerAXTree.Failure, .targetChanged)
            }
    }

    func testUnavailableBindingFailsWithoutSelectingAnotherCandidate() {
        let field = Node("search")
        let root = Node("app", children: [field], type: 2)
        enum Unavailable: Error { case runtime }
        XCTAssertThrowsError(try RunnerAXTree.resolve(
            root: root, path: [step(root, index: 0), step(field, index: 0)],
            access: .init(snapshot: { $0 }, children: { $0.children },
                          bind: { _, _ -> Node in throw Unavailable.runtime }),
            sameIdentity: { $0 === $1 }, matches: matches)) {
                XCTAssertTrue($0 is Unavailable)
            }
    }

    func testIdenticalLeavesUsePathButCannotProvePersistentObjectIdentity() throws {
        let first = Node("")
        let second = Node("")
        let root = Node("app", children: [first, second], type: 2)
        let path = [step(root, index: 0), step(first, index: 0)]
        XCTAssertTrue(try resolve(root, path: path) === first)
        // Attribute-only matching cannot detect replacement. Production also
        // checks observation-local identities (see RunnerAXReferenceTests).
        root.children[0] = second
        XCTAssertTrue(try resolve(root, path: path) === second)
    }

    func testCaptureRetainsWideAndDeepTreesBeyondTwoHundredNodes() {
        let root = Node("root", children: (0..<1200).map { Node("field \($0)") })
        let flat = RunnerAXTree.flatten(root, children: { $0.children })
        XCTAssertEqual(flat.count, 1201)
        XCTAssertNil(flat[0].parent)
        XCTAssertEqual(flat[1200].parent, 0)
        XCTAssertEqual(flat[1200].node.attributes["value"] as? String, "field 1199")
        var deep = Node("leaf")
        for _ in 0..<500 { deep = Node("container", children: [deep]) }
        let chain = RunnerAXTree.flatten(deep, children: { $0.children })
        XCTAssertEqual(chain.count, 501)
        XCTAssertEqual(chain[500].parent, 499)
    }

    func testMovingAncestorDoesNotHideReplacedLeafOrChangedPath() {
        let field = Node("search")
        let other = Node("search")
        let root = Node("app", children: [other], type: 2)
        let path = [step(root, index: 0), step(field, index: 0)]
        var bound = false
        XCTAssertThrowsError(try RunnerAXTree.resolve(
            root: root, path: path, access: .init(snapshot: { $0 }, children: { $0.children },
            bind: { _, selected in bound = true; return selected }), sameIdentity: { $0 === $1 },
            matches: { node, _ in node === root || node === field },
            geometryMatches: { node, _ in node !== root })) {
                XCTAssertEqual($0 as? RunnerAXTree.Failure, .targetChanged)
            }
        XCTAssertFalse(bound)
        root.children = []
        XCTAssertThrowsError(try RunnerAXTree.resolve(
            root: root, path: path, access: .init(snapshot: { $0 }, children: { $0.children },
            bind: { _, selected in selected }), sameIdentity: { $0 === $1 }, matches: matches,
            geometryMatches: { _, _ in false })) {
                XCTAssertEqual($0 as? RunnerAXTree.Failure, .pathChanged)
            }
    }

    func testGeometryClassificationStillChecksBindingAndLatestFullPath() {
        let field = Node("search")
        let other = Node("search")
        let root = Node("app", children: [field], type: 2)
        let path = [step(root, index: 0), step(field, index: 0)]
        for replaceOnBind in [false, true] {
            root.children = [field]
            XCTAssertThrowsError(try RunnerAXTree.resolve(
                root: root, path: path, access: .init(snapshot: { $0 }, children: { $0.children },
                bind: { _, selected in
                    if replaceOnBind { root.children = [other]; return selected }
                    return other
                }), sameIdentity: { $0 === $1 },
                matches: { node, _ in node === root || node === field },
                geometryMatches: { _, _ in false })) {
                    XCTAssertEqual($0 as? RunnerAXTree.Failure, .targetChanged)
                }
        }
    }

    func testGeometryOnlyFailureRequiresCompleteFreshResolution() {
        let field = Node("search")
        let root = Node("app", children: [field], type: 2)
        let path = [step(root, index: 0), step(field, index: 0)]
        var captures = 0
        XCTAssertThrowsError(try RunnerAXTree.resolve(
            root: root, path: path, access: .init(snapshot: { captures += 1; return $0 }, children: { $0.children },
            bind: { _, selected in selected }), sameIdentity: { $0 === $1 }, matches: matches,
            geometryMatches: { _, _ in false })) {
                XCTAssertEqual($0 as? RunnerAXTree.Failure, .geometryChanged)
            }
        XCTAssertEqual(captures, 3)
    }

    func testResultUsesLatestPathSnapshotInsteadOfEarlierBoundSnapshot() throws {
        let field = Node("before")
        let latestField = Node("after")
        let root = Node("app", children: [field], type: 2)
        let latestRoot = Node("app", children: [latestField], type: 2)
        var captures = 0
        let result = try RunnerAXTree.resolve(
            root: root, path: [step(root, index: 0), step(field, index: 0)],
            access: .init(snapshot: { element in
                captures += 1
                return captures == 3 ? latestRoot : element
            }, children: { $0.children }, bind: { _, selected in selected }),
            sameIdentity: { first, second in
                // Two immutable snapshots of the same platform identity.
                (first === field || first === latestField) && (second === field || second === latestField)
            }, matches: { node, _ in node === root || node === latestRoot || node === field || node === latestField },
            geometryMatches: { _, _ in true })
        XCTAssertTrue(result.0 === field)
        XCTAssertTrue(result.1 === latestField)
        XCTAssertEqual(result.1.attributes["value"] as? String, "after")
    }
}
