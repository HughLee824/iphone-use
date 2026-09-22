import XCTest
@testable import IPhoneUseCore

final class DeviceActionTests: XCTestCase {
    func testNativeHomeAndLongPressAdmission() throws {
        XCTAssertNoThrow(try DeviceAction(operation: "home", request: ["reference": "o1"], allowScreenText: true))
        XCTAssertThrowsError(try DeviceAction(operation: "home", request: ["reference": "o1"]))
        for request: [String: Any] in [["reference": "o1:e1"], ["reference": "o1", "x": 1, "y": 2], ["reference": "o1", "fieldRect": "0,0,10,10"]] {
            XCTAssertThrowsError(try DeviceAction(operation: "home", request: request, allowScreenText: true))
        }
        let request: [String: Any] = ["reference": "o1", "x": 40, "y": 80]
        XCTAssertEqual(try DeviceAction(operation: "long-press", request: request, allowScreenText: true).fields["duration"] as? Double, 0.8)
        XCTAssertNoThrow(try DeviceAction(operation: "long-press", request: request))
        for value: Any in [0.49, 5.01, true, "1", Double.nan] {
            var invalid = request; invalid["duration"] = value
            XCTAssertThrowsError(try DeviceAction(operation: "long-press", request: invalid, allowScreenText: true))
        }
        XCTAssertThrowsError(try DeviceAction(operation: "tap", request: request.merging(["duration": 1]) { _, new in new }))
    }

    func testDoubleTapRequiresNativeFiniteScreenshotCoordinates() throws {
        let request: [String: Any] = ["reference": "o1", "x": 40, "y": 80]
        XCTAssertNoThrow(try DeviceAction(operation: "double-tap", request: request, allowScreenText: true))
        XCTAssertNoThrow(try DeviceAction(operation: "double-tap", request: request))
        for invalid: [String: Any] in [["reference": "o1:e1"], ["reference": "o1:e1", "x": 40, "y": 80],
            ["reference": "o1", "x": 40], ["reference": "o1", "x": Double.nan, "y": 80],
            request.merging(["duration": 1]) { _, new in new }, request.merging(["velocity": 100]) { _, new in new }] {
            XCTAssertThrowsError(try DeviceAction(operation: "double-tap", request: invalid, allowScreenText: true))
        }
    }

    func testInputModesUnicodeAndControlKeys() throws {
        for mode in ["insert", "replace", "append"] {
            let action = try DeviceAction(operation: "type", request: ["reference": "o1:e27", "mode": mode, "text": "北京👩‍💻e\u{301}"])
            XCTAssertEqual(action.fields["text"] as? String, "北京👩‍💻e\u{301}")
        }
        XCTAssertNoThrow(try DeviceAction(operation: "type", request: ["reference": "o1:e27", "mode": "replace", "text": ""]))
        for text in ["", "\r", "a\r\nb", "\t", "\u{7f}", "\u{F700}", String(repeating: "北", count: 1366)] {
            XCTAssertThrowsError(try DeviceAction(operation: "type", request: ["reference": "o1:e27", "mode": "insert", "text": text]))
        }
        XCTAssertThrowsError(try DeviceAction(operation: "type", request: ["reference": "o1:e27", "text": "hello"]))
    }

    func testRunnerMultilinePreservesBytesAndRequiresTextViewBeforeDispatch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("runner-lines-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ObservationCache(directory: directory)
        let fixture = try observationFixture()
        for role in ["text_field", "secure_text_field", "search_field", "text_view"] {
            let nodes = fixture.nodes.map { node in
                AXNode(index: node.index, parent: node.parent, role: node.index == 26 ? role : node.role, attributes: node.attributes)
            }
            _ = try cache.store(CapturedObservation(nodes: nodes, metadata: fixture.metadata, screenshot: fixture.screenshot))
            let observationID = try XCTUnwrap(cache.currentID)
            for text in [" 首🙂行\n\n尾e\u{301} \n", "首\n尾\n"] {
                let action = try DeviceAction(operation: "type", request: ["reference": "\(observationID):e27", "mode": "replace", "text": text])
                XCTAssertEqual(Array((action.fields["text"] as! String).utf8), Array(text.utf8))
                if role == "text_view" { XCTAssertNoThrow(try cache.resolveTarget(for: action)) }
                else {
                    XCTAssertThrowsError(try cache.resolveTarget(for: action)) {
                        XCTAssertEqual(($0 as? IPhoneUseError)?.code, "multiline_requires_text_view")
                    }
                }
                XCTAssertEqual(cache.currentID, observationID)
            }
        }
    }

    func testCoordinateAndSwipeTargetsAreExplicit() throws {
        XCTAssertNoThrow(try DeviceAction(operation: "tap", request: ["reference": "o1", "x": 10, "y": 20]))
        for request: [String: Any] in [["reference": "o1"], ["reference": "o1:e2", "x": 1, "y": 2],
                                      ["reference": "o1", "x": 1], ["reference": "o1", "x": Double.infinity, "y": 1]] {
            XCTAssertThrowsError(try DeviceAction(operation: "tap", request: request))
        }
        for direction in ["up", "down", "left", "right"] {
            XCTAssertNoThrow(try DeviceAction(operation: "swipe", request: ["reference": "o1:e2", "direction": direction]))
        }
        XCTAssertThrowsError(try DeviceAction(operation: "swipe", request: ["reference": "o1:e2", "direction": "forward"]))
    }

    func testInvalidSwipeMotionIsRejectedBeforeDispatch() throws {
        let swipe: [String: Any] = ["reference": "o1:e2", "direction": "up"]
        for (key, value): (String, Any) in [("velocity", 0), ("velocity", -1), ("velocity", 10_001),
            ("velocity", true), ("velocity", "100"), ("velocity", Double.nan),
            ("pressDuration", -0.1), ("pressDuration", 5.1), ("pressDuration", NSNull()),
            ("holdDuration", -0.1), ("holdDuration", 5.1), ("holdDuration", Double.infinity)] {
            var request = swipe
            request[key] = value
            XCTAssertThrowsError(try DeviceAction(operation: "swipe", request: request)) {
                XCTAssertEqual(($0 as? IPhoneUseError)?.code, "invalid_swipe_motion")
            }
        }
        for key in ["velocity", "pressDuration", "holdDuration"] {
            XCTAssertThrowsError(try DeviceAction(operation: "tap", request: ["reference": "o1:e2", key: 1]))
        }
    }

    func testSwipeDefaultsAndPartialOverrides() throws {
        let request: [String: Any] = ["reference": "o1:e2", "direction": "up"]
        let defaults = try XCTUnwrap(DeviceAction(operation: "swipe", request: request).swipeMotion)
        XCTAssertEqual(defaults.velocity, 500)
        XCTAssertEqual(defaults.pressDuration, 0)
        XCTAssertEqual(defaults.holdDuration, 0)
        var held = request
        held["holdDuration"] = 0.2
        let motion = try XCTUnwrap(DeviceAction(operation: "swipe", request: held).swipeMotion)
        XCTAssertEqual(motion.velocity, 500)
        XCTAssertEqual(motion.pressDuration, 0)
        XCTAssertEqual(motion.holdDuration, 0.2)
        XCTAssertNil(try DeviceAction(operation: "tap", request: ["reference": "o1:e2"]).swipeMotion)
    }

    func testReturnRequiresAnExplicitKeyAndElement() throws {
        let action = try DeviceAction(operation: "press", request: ["reference": "o1:e27", "key": "return"])
        XCTAssertEqual(action.fields["key"] as? String, "return")
        for request: [String: Any] in [["reference": "o1:e27"], ["reference": "o1:e27", "key": "enter"],
                                      ["reference": "o1:e27", "key": "\n"], ["reference": "o1", "key": "return"],
                                      ["reference": "o1", "key": "return", "x": 1, "y": 2]] {
            XCTAssertThrowsError(try DeviceAction(operation: "press", request: request))
        }
    }

    func testGuardPoliciesAndCoordinateSwipesRejectInvalidOrMixedArguments() throws {
        let swipe: [String: Any] = ["reference": "o1", "fromX": 1, "fromY": 100, "toX": 1, "toY": 20]
        XCTAssertNoThrow(try DeviceAction(operation: "swipe", request: swipe))
        for (key, value): (String, Any) in [("direction", "up"), ("fromX", true), ("toY", Double.nan),
            ("x", 2), ("reference", "o1:e1"), ("fromY", "100")] {
            var invalid = swipe
            invalid[key] = value
            XCTAssertThrowsError(try DeviceAction(operation: "swipe", request: invalid))
        }
        var missing = swipe
        missing.removeValue(forKey: "toX")
        XCTAssertThrowsError(try DeviceAction(operation: "swipe", request: missing))
        for options: [String: Any] in [["maxScreenChange": -1], ["maxScreenChange": 2], ["maxRegionChange": 0.1],
            ["maxScreenChange": true], ["maxRegionChange": Double.infinity], ["protect": ["o2:e1"]],
            ["protect": ["o1"]], ["protect": ["o1:e1", "o1:e1", "o1:e1", "o1:e1"]], ["protect": "o1:e1"]] {
            var request: [String: Any] = ["reference": "o1:e1"]
            request.merge(options) { _, new in new }
            XCTAssertThrowsError(try DeviceAction(operation: "tap", request: request))
        }
    }

    func testExecutionFactsDistinguishRejectionUnknownAndMalformedSuccess() throws {
        let done: [String: Any] = ["ok": true, "execution": ["started": true, "completed": true], "result": ["kind": "tap"]]
        XCTAssertEqual(try ActionReply.decode(done)["kind"] as? String, "tap")
        let cases: [([String: Any], Bool)] = [
            (["ok": false, "execution": ["started": false, "completed": false]], false),
            (["ok": false, "execution": ["started": true, "completed": false]], true),
            (["ok": false, "execution": ["started": false, "inputCompleted": true, "completed": false]], true),
            (["ok": true], true),
            (["ok": true, "execution": ["started": false, "completed": true]], true),
            (["ok": true, "execution": ["started": true, "completed": false]], true)
        ]
        for (response, uncertain) in cases {
            XCTAssertThrowsError(try ActionReply.decode(response)) { error in
                XCTAssertEqual((error as? ActionFailure)?.possiblyExecuted, uncertain)
            }
        }
    }

    func testTargetPathPreservesSourceAncestryWithoutAgentReferences() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/as-action-\(UUID().uuidString.prefix(8))")
        let cache = ObservationCache(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try observationFixture()
        _ = try cache.store(fixture)
        let action = try DeviceAction(operation: "type", request: ["reference": "o1:e27", "mode": "insert", "text": "hi"])
        let target = try cache.resolveTarget(for: action)
        XCTAssertEqual(target.path.first?["type"] as? Int, 2)
        XCTAssertEqual(target.path.last?["type"] as? Int, 49)
        XCTAssertEqual(target.path.last?["label"] as? String, "Web input")
        XCTAssertTrue(target.path.allSatisfy { $0["ref"] == nil && $0["index"] == nil && $0["parent"] == nil })
        XCTAssertGreaterThan(target.path.count, 3)
        let wrong = try DeviceAction(operation: "type", request: ["reference": "o1:e11", "mode": "insert", "text": "hi"])
        XCTAssertThrowsError(try cache.resolveTarget(for: wrong))
        let press = try DeviceAction(operation: "press", request: ["reference": "o1:e27", "key": "return"])
        XCTAssertNoThrow(try cache.resolveTarget(for: press))
        let wrongPress = try DeviceAction(operation: "press", request: ["reference": "o1:e11", "key": "return"])
        XCTAssertThrowsError(try cache.resolveTarget(for: wrongPress))
        _ = try cache.store(fixture)
        XCTAssertThrowsError(try cache.resolveTarget(for: action))
    }
}
