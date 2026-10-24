import XCTest
@testable import IPhoneUseCore

final class ValidationOrderTests: XCTestCase {
    func testActionReportsFirstInvalidFieldWhenSeveralInputsAreInvalid() {
        struct RejectedAction {
            let operation: String
            let fields: [String: Any]
            let code: String
        }
        let cases: [RejectedAction] = [
            .init(operation: "unknown", fields: ["textMethod": "invalid"], code: "invalid_action"),
            .init(operation: "type", fields: ["textMethod": "invalid"], code: "invalid_text_method"),
            .init(
                operation: "type", fields: ["textMethod": "touch-paste", "mode": "replace"],
                code: "invalid_touch_paste"),
            .init(operation: "tap", fields: ["reference": "bad", "x": true], code: "invalid_reference"),
            .init(
                operation: "swipe", fields: ["reference": "o1:e1", "direction": "bad", "velocity": -1],
                code: "invalid_direction"),
            .init(
                operation: "type", fields: ["reference": "o1", "mode": "bad", "text": "\u{0}", "fieldRect": "bad"],
                code: "invalid_input_mode"),
            .init(
                operation: "type",
                fields: ["reference": "o1", "mode": "insert", "text": "text", "fieldRect": "bad", "caretRect": "bad"],
                code: "invalid_text_region")
        ]
        for sample in cases {
            XCTAssertThrowsError(
                try DeviceAction(operation: sample.operation, request: sample.fields, allowScreenText: true)
            ) {
                XCTAssertEqual(($0 as? IPhoneUseError)?.code, sample.code)
            }
        }
    }
}

extension HostTests {
    func testInvalidRequestsRetainRejectionOrderWithoutBackendDispatch() throws {
        let backend = ControlledBackend()
        let running = try host(timeout: 5, backend: backend)
        defer {
            _ = try? call(running.paths, session: running.session, op: "disconnect")
            wait(for: [running.finished], timeout: 3)
        }
        for (operation, code) in [
            ("unknown", "invalid_request"), ("open", "invalid_bundle_id"),
            ("type-with-method", "invalid_text_method"), ("type-with-caret", "invalid_caret_region"),
            ("text-finish", "invalid_text_transaction")
        ] {
            let response = try call(
                running.paths, session: running.session, op: operation, fields: ["reference": "bad"])
            XCTAssertEqual(response["outcome"] as? String, "not_dispatched")
            XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? String, code)
        }
        XCTAssertEqual(backend.actionCount, 0)
        XCTAssertEqual(backend.inputCount, 0)
    }
}
