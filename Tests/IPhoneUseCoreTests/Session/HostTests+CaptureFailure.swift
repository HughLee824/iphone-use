import XCTest
import Foundation
import Network
@testable import IPhoneUseCore

extension HostTests {

    func testNativeAfterCaptureFailurePreservesInputFacts() throws {
        let backend = ControlledBackend(); backend.nativeSend = true
        let running = try host(timeout: 5, backend: backend, native: true)
        let paths = running.paths, session = running.session, finished = running.finished
        defer {
            _ = try? call(paths, session: session, op: "disconnect")
            wait(for: [finished], timeout: 3)
        }
        _ = try call(paths, session: session, op: "observe")
        backend.observationFailure = IPhoneUseError(
            "post_action_capture_timeout", "No valid frame",
            diagnostics: [
                "capture": [
                    "failedStage": "checksAfter",
                    "commands": [["command": "device info lockState", "ok": false]]
                ]
            ])
        let response = try call(paths, session: session, op: "tap", fields: ["reference": "o1:e11"])
        XCTAssertEqual(response["outcome"] as? String, "unknown")
        XCTAssertEqual((response["result"] as? [String: Any])?["transportStatus"] as? String, "sent")
        XCTAssertEqual((response["observation"] as? [String: Any])?["ok"] as? Bool, false)
        let observation = try XCTUnwrap(response["observation"] as? [String: Any])
        XCTAssertEqual(observation["errorCode"] as? String, "post_action_capture_timeout")
        let diagnostics = observation["diagnostics"] as? [String: Any]
        XCTAssertEqual((diagnostics?["capture"] as? [String: Any])?["failedStage"] as? String, "checksAfter")
        XCTAssertEqual(
            ((response["result"] as? [String: Any])?["recovery"] as? [String: Any])?["nextAction"] as? String,
            "observe"
        )
        XCTAssertEqual(backend.actionCount, 1)
    }

    func testNativeUnstableObservationPreservesUnknownInputAndNeverReplays() throws {
        let backend = ControlledBackend(); backend.nativeSend = true; backend.postActionStable = false
        let running = try host(timeout: 5, backend: backend, native: true)
        let paths = running.paths, session = running.session, finished = running.finished
        defer { _ = try? call(paths, session: session, op: "disconnect"); wait(for: [finished], timeout: 3) }
        _ = try call(paths, session: session, op: "observe")
        let response = try call(paths, session: session, op: "tap", fields: ["reference": "o1:e11"])
        XCTAssertEqual(response["outcome"] as? String, "unknown")
        XCTAssertEqual((response["result"] as? [String: Any])?["transportStatus"] as? String, "sent")
        let observation = try XCTUnwrap(response["observation"] as? [String: Any])
        XCTAssertEqual(observation["ok"] as? Bool, true)
        XCTAssertEqual((observation["stability"] as? [String: Any])?["stable"] as? Bool, false)
        XCTAssertNotNil(observation["warning"])
        let after = try XCTUnwrap(observation["result"] as? [String: Any])
        XCTAssertEqual(after["observation"] as? String, "o2")
        let snapshot = try jsonObject(
            Data(contentsOf: URL(fileURLWithPath: (try XCTUnwrap(after["snapshot"] as? String)))))
        XCTAssertEqual(
            ((snapshot["metadata"] as? [String: Any])?["postActionStability"] as? [String: Any])?["stable"]
                as? Bool,
            false)
        let summary = AgentOutput.summarize(response)["agentSummary"] as? [String: Any]
        XCTAssertEqual(summary?["nextStep"] as? String, "inspect_unstable_observation_do_not_replay")
        XCTAssertEqual(backend.inputCount, 1)
        XCTAssertEqual(backend.postActionObserveCount, 1)
    }

    func testNativePreDispatchFailureDoesNotCaptureOrInvalidateCurrentReference() throws {
        let backend = ControlledBackend()
        backend.actionFailure = ActionFailure(
            code: "native_control_unavailable", description: "No authorized HID service",
            possiblyExecuted: false, requiresObservation: false)
        let running = try host(timeout: 5, backend: backend, native: true)
        let paths = running.paths, session = running.session, finished = running.finished
        defer {
            _ = try? call(paths, session: session, op: "disconnect")
            wait(for: [finished], timeout: 3)
        }
        _ = try call(paths, session: session, op: "observe")
        let response = try call(paths, session: session, op: "tap", fields: ["reference": "o1:e11"])
        XCTAssertEqual(response["outcome"] as? String, "not_dispatched")
        XCTAssertNil(response["observation"])
        XCTAssertEqual(backend.inputCount, 0); XCTAssertEqual(backend.observeCount, 1)
        let snapshot = try call(
            paths, session: session, op: "inspect", fields: ["reference": "o1", "offset": 0])
        XCTAssertEqual((snapshot["result"] as? [String: Any])?["refs"] as? String, "current")
    }

    func testNativeGuardRejectionAttachesExactFrameWithoutInputOrRecapture() throws {
        let backend = ControlledBackend()
        let capture = try observationFixture()
        backend.actionFailure = ActionFailure(
            code: "stale_observation", description: "Changed pixels",
            possiblyExecuted: false, requiresObservation: true,
            result: ["screenGuard": ["accepted": false, "regionChanges": [0.125]]], rejectedCapture: capture)
        let running = try host(timeout: 5, backend: backend, native: true)
        let paths = running.paths, session = running.session, finished = running.finished
        defer { _ = try? call(paths, session: session, op: "disconnect"); wait(for: [finished], timeout: 3) }
        _ = try call(paths, session: session, op: "observe")
        backend.failObservation = true // Attaching the already captured frame must not recapture.
        let response = try call(paths, session: session, op: "tap", fields: ["reference": "o1:e11"])
        XCTAssertEqual(response["outcome"] as? String, "not_dispatched")
        let observation = try XCTUnwrap(response["observation"] as? [String: Any])
        XCTAssertEqual(observation["phase"] as? String, "pre_input_rejection")
        XCTAssertEqual(observation["ok"] as? Bool, true)
        let stored = try XCTUnwrap(observation["result"] as? [String: Any])
        let path = try XCTUnwrap(stored["screenshot"] as? String)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), capture.screenshot)
        let facts = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(facts["rejectedObservationID"] as? String, "o2")
        XCTAssertNil(facts["afterObservationID"])
        XCTAssertEqual((facts["screenGuard"] as? [String: Any])?["regionChanges"] as? [Double], [0.125])
        XCTAssertEqual((facts["recovery"] as? [String: Any])?["nextAction"] as? String, "inspect_observation")
        XCTAssertEqual(backend.inputCount, 0); XCTAssertEqual(backend.observeCount, 1)
        let old = try call(paths, session: session, op: "tap", fields: ["reference": "o1:e11"])
        XCTAssertEqual(old["outcome"] as? String, "not_dispatched")
        XCTAssertEqual(backend.actionCount, 1)
    }

    func testNativeUncertainControlRecoverySurvivesAssociatedCaptureAndNextRejection() throws {
        let backend = ControlledBackend()
        backend.statusInfo =
            NativeControlStatus.resolve(
                hid: .releaseUncertain, media: ["healthy": true], closing: false,
                startupCode: nil, startupError: nil
            ).result
        backend.actionFailure = ActionFailure(
            code: "native_input_uncertain", description: "Lost release",
            possiblyExecuted: true, requiresObservation: true, result: ["cleanup": ["releaseUncertain": true]]
        )
        let running = try host(timeout: 5, backend: backend, native: true)
        let paths = running.paths, session = running.session, finished = running.finished
        defer { _ = try? call(paths, session: session, op: "disconnect"); wait(for: [finished], timeout: 3) }
        _ = try call(paths, session: session, op: "observe")
        let failed = try call(paths, session: session, op: "tap", fields: ["reference": "o1:e11"])
        let facts = try XCTUnwrap(failed["result"] as? [String: Any])
        XCTAssertEqual(failed["outcome"] as? String, "unknown")
        XCTAssertEqual(facts["controlErrorCode"] as? String, "native_release_uncertain")
        XCTAssertEqual((facts["recovery"] as? [String: Any])?["requiresReconnect"] as? Bool, true)
        XCTAssertEqual(facts["afterObservationID"] as? String, "o2")
        backend.actionFailure = ActionFailure(
            code: "native_control_unavailable", description: "Release uncertain",
            possiblyExecuted: false, requiresObservation: false, result: backend.statusInfo)
        let rejected = try call(paths, session: session, op: "tap", fields: ["reference": "o2:e11"])
        XCTAssertEqual(rejected["outcome"] as? String, "not_dispatched")
        XCTAssertEqual(
            ((rejected["result"] as? [String: Any])?["recovery"] as? [String: Any])?["nextAction"] as? String,
            "reconnect_and_observe")
        XCTAssertEqual(backend.observeCount, 2)
        XCTAssertEqual(backend.inputCount, 0)
    }

    func testTouchPasteStagesAndFinishesInBothModesWithoutBackendKeyboardInput() throws {
        for native in [true, false] {
            let backend = ControlledBackend(); backend.nativeTextFixture = native
            let pasteboardIO = TouchPasteTestIO(), original = pasteboardIO.items
            var closed = false
            let clipboard = TouchPasteSession {
                .init(
                    pasteboardIO: pasteboardIO,
                    close: {
                        closed = true; return true
                    })
            }
            let running = try host(
                timeout: 5, backend: backend, native: native, touchPaste: clipboard)
            let paths = running.paths, session = running.session, finished = running.finished
            defer {
                _ = try? call(paths, session: session, op: "disconnect"); wait(for: [finished], timeout: 3)
                XCTAssertTrue(closed)
            }
            _ = try call(paths, session: session, op: "observe")
            let stage = try call(
                paths, session: session, op: "type-with-method",
                fields: [
                    "reference": "o1", "mode": "insert", "textMethod": "touch-paste", "text": "中文\nEnglish"
                ])
            let token = try stagedTransaction(stage, backend: backend)
            let stale = try call(
                paths, session: session, op: "text-finish", fields: ["reference": "o1", "transaction": token])
            XCTAssertEqual(stale["outcome"] as? String, "not_dispatched")
            let blocked = try call(
                paths, session: session, op: "type",
                fields: ["reference": native ? "o2" : "o2:e27", "mode": "insert", "text": "duplicate"])
            XCTAssertEqual((blocked["error"] as? [String: Any])?["code"] as? String, "touch_paste_pending")
            XCTAssertEqual(pasteboardIO.writes, 1)
            // The explicit UI step still goes through the selected backend's guard.
            _ = try call(
                paths, session: session, op: "long-press", fields: ["reference": "o2", "x": 100, "y": 200])
            XCTAssertEqual(backend.inputCount, 1)
            let observed = try call(paths, session: session, op: "observe")
            let current =
                (try XCTUnwrap(
                    ((try XCTUnwrap(observed["result"] as? [String: Any])))["observation"] as? String))
            let finish = try call(
                paths, session: session, op: "text-finish",
                fields: ["reference": current, "transaction": token])
            XCTAssertEqual(finish["ok"] as? Bool, true)
            XCTAssertEqual(backend.finishCount, 0)
            XCTAssertEqual(pasteboardIO.items, original)
            XCTAssertEqual(backend.inputCount, 1)
        }
    }
    private func stagedTransaction(_ stage: [String: Any], backend: ControlledBackend) throws -> String {
        XCTAssertEqual(stage["ok"] as? Bool, true)
        XCTAssertEqual(stage["outcome"] as? String, "prepared")
        let result = (try XCTUnwrap(stage["result"] as? [String: Any]))
        XCTAssertEqual(result["textInserted"] as? Bool, false)
        XCTAssertEqual(result["afterObservationID"] as? String, "o2")
        XCTAssertEqual(backend.actionCount, 0)
        XCTAssertEqual(backend.prepareCount, 0)
        let token =
            (try XCTUnwrap(
                ((try XCTUnwrap(result["pasteboard"] as? [String: Any])))["transactionID"] as? String))
        return token
    }

}
