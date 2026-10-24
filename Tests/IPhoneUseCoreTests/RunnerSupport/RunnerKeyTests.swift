@testable import IPhoneUseRunnerSupport
import XCTest
@testable import IPhoneUseCore

final class RunnerKeyTests: XCTestCase {
    func testKeysKeepElementValidationAndModifierIntent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ObservationCache(directory: directory)
        _ = try cache.store(observationFixture())
        for key in RunnerPressKey.allCases {
            let action = try DeviceAction(
                operation: "press", request: ["reference": "o1:e27", "key": key.rawValue])
            let target = try cache.resolveTarget(for: action)
            let fields = try XCTestBackend.actionFields(action, target: target)
            XCTAssertEqual(fields["key"] as? String, key.rawValue)
            XCTAssertFalse(target.path.isEmpty)
            XCTAssertEqual(key.modifiers, key == .shiftTab ? ["shift"] : [])
            XCTAssertThrowsError(
                try DeviceAction(operation: "press", request: ["reference": "o1", "key": key.rawValue]))
            let wrong = try DeviceAction(
                operation: "press", request: ["reference": "o1:e11", "key": key.rawValue])
            XCTAssertThrowsError(try cache.resolveTarget(for: wrong))
        }
        XCTAssertThrowsError(
            try DeviceAction(operation: "press", request: ["reference": "o1:e27", "key": "escape"])
        ) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "unsupported_key")
        }
        for key in ["delete", "command-a", "Shift-Tab", "LEFT", "", "ab"] {
            XCTAssertThrowsError(
                try DeviceAction(operation: "press", request: ["reference": "o1:e27", "key": key]))
        }
    }

    func testMissingWrongOrModifiedKeyReplyRemainsUnknown() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for result: [String: Any] in [
            [:], ["key": "tab", "keyModifiers": []], ["key": "shift-tab", "keyModifiers": ["command"]]
        ] {
            let response: [String: Any] = [
                "ok": true, "execution": ["started": true, "inputCompleted": true, "completed": true],
                "result": result
            ]
            XCTAssertThrowsError(
                try XCTestCapture.actionResponse(response, directory: directory, expectedKey: .shiftTab)
            ) {
                XCTAssertEqual(($0 as? ActionFailure)?.code, "missing_key_facts")
                XCTAssertEqual(($0 as? ActionFailure)?.possiblyExecuted, true)
            }
        }
    }
}
