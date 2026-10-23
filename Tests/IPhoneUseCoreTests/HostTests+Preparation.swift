import XCTest
import Foundation
import Network
@testable import IPhoneUseCore

extension HostTests {

    func testNativePreparationCapturesNewSourceThenReturnRemainsUnknownWithoutReplay() throws {
        let backend = ControlledBackend(); backend.nativeSend = true; backend.nativeTextFixture = true
        let running = try host(timeout: 5, backend: backend, native: true)
        let paths = running.paths, session = running.session, finished = running.finished
        defer { _ = try? call(paths, session: session, op: "disconnect"); wait(for: [finished], timeout: 3) }
        _ = try call(paths, session: session, op: "observe")
        let prepared = try call(paths, session: session, op: "text-prepare")
        XCTAssertEqual(prepared["outcome"] as? String, "completed")
        XCTAssertEqual((prepared["result"] as? [String: Any])?["afterObservationID"] as? String, "o2")
        XCTAssertEqual(backend.prepareCount, 1)
        XCTAssertEqual(backend.inputCount, 0)
        let stale = try call(
            paths, session: session, op: "press", fields: ["reference": "o1", "key": "return"])
        XCTAssertEqual(stale["outcome"] as? String, "not_dispatched")
        XCTAssertEqual(backend.inputCount, 0)
        let pressed = try call(
            paths, session: session, op: "press", fields: ["reference": "o2", "key": "return"])
        XCTAssertEqual(pressed["outcome"] as? String, "unknown")
        XCTAssertEqual((pressed["result"] as? [String: Any])?["afterObservationID"] as? String, "o3")
        XCTAssertEqual(backend.inputCount, 1)
        _ = try call(paths, session: session, op: "press", fields: ["reference": "o2", "key": "return"])
        XCTAssertEqual(backend.inputCount, 1)
    }

    func testPreparationPreservesFactsOnCaptureFailureAndIsNativeOnly() throws {
        for native in [true, false] {
            let backend = ControlledBackend(); backend.nativeTextFixture = native
            let running = try host(timeout: 5, backend: backend, native: native)
            let paths = running.paths, session = running.session, finished = running.finished
            defer {
                _ = try? call(paths, session: session, op: "disconnect"); wait(for: [finished], timeout: 3)
            }
            _ = try call(paths, session: session, op: "observe")
            backend.failObservation = true
            let response = try call(paths, session: session, op: "text-prepare")
            XCTAssertEqual(backend.prepareCount, native ? 1 : 0)
            XCTAssertEqual(backend.inputCount, 0)
            if native {
                XCTAssertEqual((response["result"] as? [String: Any])?["keyboardPrepared"] as? Bool, true)
                XCTAssertEqual(response["ok"] as? Bool, false)
                XCTAssertEqual(response["outcome"] as? String, "completed")
                XCTAssertEqual((response["observation"] as? [String: Any])?["ok"] as? Bool, false)
                let stale = try call(
                    paths, session: session, op: "press", fields: ["reference": "o1", "key": "return"])
                XCTAssertEqual(stale["outcome"] as? String, "not_dispatched")
            } else {
                XCTAssertEqual(
                    (response["error"] as? [String: Any])?["code"] as? String, "native_action_unsupported")
            }
        }
    }
    func testNativeEditingModesReachBackendOnceAndInvalidateSource() throws {
        let backend = ControlledBackend(); backend.nativeSend = true; backend.nativeTextFixture = true
        let running = try host(timeout: 5, backend: backend, native: true)
        let paths = running.paths, session = running.session, finished = running.finished
        defer { _ = try? call(paths, session: session, op: "disconnect"); wait(for: [finished], timeout: 3) }
        _ = try call(paths, session: session, op: "observe")
        for (index, mode) in ["replace", "append", "insert"].enumerated() {
            let fields: [String: Any] = [
                "reference": "o\(index + 1)", "mode": mode, "text": "中文", "textMethod": "paste"
            ]
            let response = try call(paths, session: session, op: "type-with-method", fields: fields)
            XCTAssertEqual(response["outcome"] as? String, "unknown")
            XCTAssertEqual(backend.lastTextMode, mode)
            XCTAssertEqual(backend.inputCount, index + 1)
            let stale = try call(paths, session: session, op: "type-with-method", fields: fields)
            XCTAssertEqual(stale["outcome"] as? String, "not_dispatched")
            XCTAssertEqual(backend.inputCount, index + 1)
        }
    }

    func testExplicitTextMethodAndCompletionUseCurrentNativeObservationWithoutStoppingHost() throws {
        let backend = ControlledBackend(); backend.nativeSend = true; backend.nativeTextFixture = true
        let running = try host(timeout: 5, backend: backend, native: true)
        let paths = running.paths, session = running.session, finished = running.finished
        defer { _ = try? call(paths, session: session, op: "disconnect"); wait(for: [finished], timeout: 3) }
        let token = UUID().uuidString
        _ = try call(paths, session: session, op: "observe")
        let typed = try call(
            paths, session: session, op: "type-with-method",
            fields: [
                "reference": "o1", "mode": "insert", "text": String(repeating: "A", count: 100),
                "textMethod": "paste"
            ])
        XCTAssertEqual(typed["outcome"] as? String, "unknown")
        XCTAssertEqual(backend.lastTextMethod, "paste")
        XCTAssertEqual(backend.inputCount, 1)
        let stale = try call(
            paths, session: session, op: "text-finish", fields: ["reference": "o1", "transaction": token])
        XCTAssertEqual(stale["outcome"] as? String, "not_dispatched")
        XCTAssertEqual(backend.finishCount, 0)
        let response = try call(
            paths, session: session, op: "text-finish", fields: ["reference": "o2", "transaction": token])
        XCTAssertEqual(response["outcome"] as? String, "completed")
        XCTAssertEqual((response["result"] as? [String: Any])?["sourceObservationID"] as? String, "o2")
        XCTAssertEqual((response["result"] as? [String: Any])?["afterObservationID"] as? String, "o3")
        XCTAssertEqual(backend.finishCount, 1)
        XCTAssertEqual(backend.inputCount, 1)
        XCTAssertEqual(backend.stopCount, 0)
        XCTAssertEqual(try call(paths, session: session, op: "status")["ok"] as? Bool, true)
        let reused = try call(
            paths, session: session, op: "text-finish", fields: ["reference": "o2", "transaction": token])
        XCTAssertEqual(reused["outcome"] as? String, "not_dispatched")
        XCTAssertEqual(backend.finishCount, 1)
    }

    func testUnconfirmedFinishPreservesCleanupFactsWhenCaptureFailsAndRunnerRejectsOptions() throws {
        for native in [true, false] {
            let backend = ControlledBackend(); backend.nativeTextFixture = native
            backend.finishAcknowledged = false
            let running = try host(timeout: 5, backend: backend, native: native)
            let paths = running.paths, session = running.session, finished = running.finished
            defer {
                _ = try? call(paths, session: session, op: "disconnect"); wait(for: [finished], timeout: 3)
            }
            _ = try call(paths, session: session, op: "observe")
            backend.failObservation = true
            let response = try call(
                paths, session: session, op: "text-finish",
                fields: ["reference": "o1", "transaction": UUID().uuidString])
            XCTAssertEqual(response["outcome"] as? String, native ? "unknown" : "not_dispatched")
            XCTAssertEqual(backend.finishCount, native ? 1 : 0)
            XCTAssertEqual(backend.inputCount, 0)
            if native {
                XCTAssertEqual(
                    (response["result"] as? [String: Any])?["pasteboardRestoreAcknowledged"] as? Bool, false)
                XCTAssertEqual((response["observation"] as? [String: Any])?["ok"] as? Bool, false)
            } else {
                let typed = try call(
                    paths, session: session, op: "type-with-method",
                    fields: ["reference": "o1:e27", "mode": "insert", "text": "abc", "textMethod": "paste"])
                XCTAssertEqual((typed["error"] as? [String: Any])?["code"] as? String, "invalid_text_method")
                XCTAssertEqual(backend.actionCount, 0)
            }
        }
    }

    func testClientFollowupUsesExistingProtocolAndPreservesReferenceRules() throws {
        let backend = ControlledBackend()
        let running = try host(timeout: 5, backend: backend)
        let paths = running.paths, session = running.session, finished = running.finished
        defer {
            _ = try? call(paths, session: session, op: "disconnect")
            wait(for: [finished], timeout: 3)
        }
        _ = try call(paths, session: session, op: "observe")
        let rejected = try call(
            paths, session: session, op: "tap", fields: ["reference": "o1:e11", "x": 1, "y": 1])
        _ = SessionClient.observing(session: session, action: rejected) {
            XCTFail("Rejected arguments must preserve the observation")
            return [:]
        }
        XCTAssertEqual(backend.observeCount, 1)
        let completed = try call(paths, session: session, op: "tap", fields: ["reference": "o1:e11"])
        let paired = SessionClient.observing(session: session, action: completed) {
            try self.call(paths, session: session, op: "observe")
        }
        XCTAssertEqual(paired["ok"] as? Bool, true)
        XCTAssertEqual(backend.actionCount, 1)
        XCTAssertEqual(backend.observeCount, 2)
        let old = try call(paths, session: session, op: "tap", fields: ["reference": "o1:e11"])
        XCTAssertEqual(old["outcome"] as? String, "not_dispatched")
        backend.actionFailure = ActionFailure(
            code: "lost_result", description: "Unknown", possiblyExecuted: true, requiresObservation: true)
        let unknown = try call(paths, session: session, op: "tap", fields: ["reference": "o2:e11"])
        backend.failObservation = true
        let failed = SessionClient.observing(session: session, action: unknown) {
            try self.call(paths, session: session, op: "observe")
        }
        XCTAssertEqual(failed["ok"] as? Bool, false)
        XCTAssertEqual((failed["action"] as? [String: Any])?["outcome"] as? String, "unknown")
        XCTAssertEqual(backend.actionCount, 2)
        XCTAssertEqual(backend.observeCount, 3)
        let stale = try call(paths, session: session, op: "tap", fields: ["reference": "o2:e11"])
        XCTAssertEqual(stale["outcome"] as? String, "not_dispatched")
        XCTAssertEqual(backend.actionCount, 2)
        backend.actionFailure = nil
        backend.failObservation = false
        _ = try call(paths, session: session, op: "observe")
        let recovery = try call(paths, session: session, op: "tap", fields: ["reference": "o3:e11"])
        XCTAssertEqual(recovery["outcome"] as? String, "completed")
    }

    func testNativeSendStaysUnknownAndGetsNewObservationWithoutReplay() throws {
        let backend = ControlledBackend(); backend.nativeSend = true
        let running = try host(timeout: 5, backend: backend, native: true)
        let paths = running.paths, session = running.session, finished = running.finished
        defer {
            _ = try? call(paths, session: session, op: "disconnect")
            wait(for: [finished], timeout: 3)
        }
        _ = try call(paths, session: session, op: "observe")
        let response = try call(paths, session: session, op: "tap", fields: ["reference": "o1:e11"])
        XCTAssertEqual(response["outcome"] as? String, "unknown")
        XCTAssertEqual(response["ok"] as? Bool, false)
        let facts = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(facts["sourceObservationID"] as? String, "o1")
        XCTAssertEqual(facts["afterObservationID"] as? String, "o2")
        XCTAssertEqual(facts["actionID"] as? String, response["id"] as? String)
        XCTAssertEqual(facts["transportStatus"] as? String, "sent")
        XCTAssertEqual((facts["recovery"] as? [String: Any])?["nextAction"] as? String, "inspect_observation")
        XCTAssertEqual(backend.actionCount, 1); XCTAssertEqual(backend.observeCount, 2)
        XCTAssertEqual(
            backend.previewGestures.count, 1,
            "A queued native input is visualized without claiming acknowledgement")
        let stale = try call(paths, session: session, op: "tap", fields: ["reference": "o1:e11"])
        XCTAssertEqual(stale["outcome"] as? String, "not_dispatched")
        XCTAssertEqual(backend.actionCount, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: paths.directory.appendingPathComponent("native-events.jsonl").path))
    }
}
