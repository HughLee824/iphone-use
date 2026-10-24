import XCTest
import Foundation
import Network
@testable import IPhoneUseCore

extension HostTests {
    func testPreviewPortIsValidatedBeforeBackendAndPassedInBothModes() throws {
        for native in [false, true] {
            let backend = ControlledBackend()
            let running = try host(timeout: 5, backend: backend, native: native)
            let paths = running.paths, session = running.session, finished = running.finished
            defer {
                _ = try? call(paths, session: session, op: "disconnect"); wait(for: [finished], timeout: 3)
            }
            for value: Any in [0, 1023, 65536, true, 8765.5, "8765"] {
                let rejected = try call(paths, session: session, op: "preview-start", fields: ["port": value])
                XCTAssertEqual(
                    (rejected["error"] as? [String: Any])?["code"] as? String, "invalid_preview_port")
            }
            XCTAssertTrue(backend.previewStarts.isEmpty)
            _ = try call(
                paths, session: session, op: "preview-start", fields: ["port": 9876, "portExplicit": true])
            XCTAssertEqual(backend.previewStarts.last?.port, 9876)
            XCTAssertEqual(backend.previewStarts.last?.explicitPort, true)
            _ = try call(paths, session: session, op: "preview-start")
            XCTAssertEqual(backend.previewStarts.last?.port, 8765)
            XCTAssertEqual(backend.previewStarts.last?.explicitPort, false)
        }
    }

    func testPreviewGestureIsPublishedBeforeBackendCompletionInBothModes() throws {
        for native in [false, true] {
            let backend = ControlledBackend()
            backend.blockAfterInput = true
            let running = try host(timeout: 5, backend: backend, native: native)
            let paths = running.paths, session = running.session, finished = running.finished
            defer {
                _ = try? call(paths, session: session, op: "disconnect"); wait(for: [finished], timeout: 3)
            }
            _ = try call(paths, session: session, op: "observe")
            let returned = expectation(description: "action returns after release")
            DispatchQueue.global().async {
                defer { returned.fulfill() }
                do {
                    _ = try self.call(
                        paths, session: session, op: "tap", fields: ["reference": "o1", "x": 100, "y": 200])
                } catch { XCTFail("Action failed: \(error)") }
            }
            XCTAssertEqual(backend.inputStarted.wait(timeout: .now() + 2), .success)
            XCTAssertEqual(
                backend.previewGestures.count, 1, "Must publish during input, before backend completion")
            backend.releaseAction.signal()
            wait(for: [returned], timeout: 3)
            XCTAssertEqual(backend.previewGestures.count, 1, "Completion must not replay the gesture")
        }
    }

    func testAppLifecycleAdmissionObservationAndUnknownFacts() throws {
        for native in [false, true] {
            let backend = ControlledBackend()
            let running = try host(timeout: 5, backend: backend, native: native)
            let paths = running.paths, session = running.session, finished = running.finished
            defer {
                _ = try? call(paths, session: session, op: "disconnect"); wait(for: [finished], timeout: 3)
            }
            _ = try call(paths, session: session, op: "observe")
            let invalid = try call(paths, session: session, op: "terminate", fields: ["bundleId": "--pid 1"])
            XCTAssertEqual(invalid["outcome"] as? String, "not_dispatched")
            let result = try call(
                paths, session: session, op: "relaunch", fields: ["bundleId": "com.example.fixture"])
            XCTAssertEqual(result["ok"] as? Bool, true)
            XCTAssertEqual(backend.appLifecycleCount, 1)
            if native {
                XCTAssertEqual((result["observation"] as? [String: Any])?["ok"] as? Bool, true)
                XCTAssertEqual((result["result"] as? [String: Any])?["afterObservationID"] as? String, "o2")
            } else {
                _ = try call(paths, session: session, op: "observe")
            }
            let stale = try call(paths, session: session, op: "tap", fields: ["reference": "o1:e11"])
            XCTAssertEqual(stale["outcome"] as? String, "not_dispatched")
            backend.lifecycleFailure = ActionFailure(
                code: "native_app_process_changed", description: "Changed externally",
                possiblyExecuted: false, requiresObservation: true)
            let changed = try call(
                paths, session: session, op: "relaunch", fields: ["bundleId": "com.example.fixture"])
            XCTAssertEqual(changed["outcome"] as? String, "not_dispatched")
            XCTAssertEqual(changed["requiresObservation"] as? Bool, true)
            let invalidated = try call(paths, session: session, op: "tap", fields: ["reference": "o2:e11"])
            XCTAssertEqual(invalidated["outcome"] as? String, "not_dispatched")
            backend.lifecycleFailure = ActionFailure(
                code: "lost_reply", description: "Lost", possiblyExecuted: true,
                requiresObservation: true, result: ["terminationAcknowledged": true, "launchRequested": false]
            )
            backend.failObservation = true
            let uncertain = try call(
                paths, session: session, op: "terminate", fields: ["bundleId": "com.example.fixture"])
            XCTAssertEqual(uncertain["outcome"] as? String, "unknown")
            XCTAssertEqual((uncertain["result"] as? [String: Any])?["terminationAcknowledged"] as? Bool, true)
            if native { XCTAssertEqual((uncertain["observation"] as? [String: Any])?["ok"] as? Bool, false) }
            XCTAssertEqual(backend.appLifecycleCount, 3)
        }
    }

    func testPreviewChangesInvalidateReferencesButDoNotCaptureOrSendInput() throws {
        for native in [false, true] {
            let backend = ControlledBackend()
            let running = try host(timeout: 5, backend: backend, native: native)
            let paths = running.paths, session = running.session, finished = running.finished
            defer {
                _ = try? call(paths, session: session, op: "disconnect"); wait(for: [finished], timeout: 3)
            }
            for operation in ["preview-start", "preview-stop"] {
                let observed = try call(paths, session: session, op: "observe")
                let ref =
                    (try XCTUnwrap(
                        ((try XCTUnwrap(observed["result"] as? [String: Any])))["observation"] as? String))
                let count = backend.observeCount
                let result = try call(paths, session: session, op: operation)
                XCTAssertEqual(result["ok"] as? Bool, true)
                XCTAssertEqual(result["requiresObservation"] as? Bool, true)
                XCTAssertEqual(backend.observeCount, count)
                let stale = try call(paths, session: session, op: "tap", fields: ["reference": ref + ":e11"])
                XCTAssertEqual(stale["outcome"] as? String, "not_dispatched")
                XCTAssertEqual(backend.inputCount, 0)
            }
        }
    }

    func testRecordingAdmissionAndObservationInvalidation() throws {
        for native in [false, true] {
            let backend = ControlledBackend()
            let running = try host(timeout: 5, backend: backend, native: native)
            let paths = running.paths, session = running.session, finished = running.finished
            defer {
                _ = try? call(paths, session: session, op: "disconnect"); wait(for: [finished], timeout: 3)
            }
            _ = try call(paths, session: session, op: "observe")
            let invalid = try call(paths, session: session, op: "record-start", fields: ["duration": 0])
            XCTAssertEqual(invalid["ok"] as? Bool, false)
            XCTAssertEqual(backend.recordingStarts, 0)
            let started = try call(paths, session: session, op: "record-start", fields: ["duration": 5])
            XCTAssertEqual(started["ok"] as? Bool, true)
            XCTAssertEqual(backend.recordingStarts, 1)
            do {
                let stale = try call(paths, session: session, op: "tap", fields: ["reference": "o1:e11"])
                XCTAssertEqual(stale["outcome"] as? String, "not_dispatched")
                XCTAssertEqual(backend.inputCount, 0)
            }
            let invalidStop = try call(
                paths, session: session, op: "record-stop", fields: ["recordingID": "bad"])
            XCTAssertEqual(invalidStop["ok"] as? Bool, false)
            let stopped = try call(
                paths, session: session, op: "record-stop",
                fields: ["recordingID": "00000000-0000-0000-0000-000000000001"])
            XCTAssertEqual(stopped["ok"] as? Bool, true)
            XCTAssertEqual(backend.recordingStops, 1)
        }
    }

    func testCaretWireOperationsRequireExplicitConfirmationAndConsumeObservation() throws {
        let backend = ControlledBackend(); backend.nativeTextFixture = true; backend.nativeCaretFixture = true
        let running = try host(timeout: 5, backend: backend, native: true)
        let paths = running.paths, session = running.session, finished = running.finished
        defer { _ = try? call(paths, session: session, op: "disconnect"); wait(for: [finished], timeout: 3) }
        for operation in ["type-with-caret", "press-with-caret"] {
            let observed = try call(paths, session: session, op: "observe")
            let reference =
                (try XCTUnwrap(
                    ((try XCTUnwrap(observed["result"] as? [String: Any])))["observation"] as? String))
            var fields: [String: Any] = [
                "reference": reference, "mode": "insert", "text": "a", "key": "left",
                "fieldRect": "18,139,354,160"
            ]
            let missing = try call(paths, session: session, op: operation, fields: fields)
            XCTAssertEqual((missing["error"] as? [String: Any])?["code"] as? String, "invalid_caret_region")
            fields["caretRect"] = "49,149,4,22"
            let accepted = try call(paths, session: session, op: operation, fields: fields)
            XCTAssertEqual(accepted["ok"] as? Bool, true)
            let stale = try call(paths, session: session, op: operation, fields: fields)
            XCTAssertEqual(stale["outcome"] as? String, "not_dispatched")
        }
        XCTAssertEqual(backend.actionCount, 2)
    }

    func testScopedPreparationSelectsTextObservationAndRejectsMalformedRequestBeforeRegistration() throws {
        let backend = ControlledBackend(); backend.nativeTextFixture = true
        let running = try host(timeout: 5, backend: backend, native: true)
        let paths = running.paths, session = running.session, finished = running.finished
        defer { _ = try? call(paths, session: session, op: "disconnect"); wait(for: [finished], timeout: 3) }
        let invalid = try call(
            paths, session: session, op: "text-prepare-scoped", fields: ["fieldRect": "0,0,-1,10"])
        XCTAssertEqual(invalid["outcome"] as? String, "not_dispatched")
        XCTAssertEqual(backend.prepareCount, 0)
        let prepared = try call(
            paths, session: session, op: "text-prepare-scoped", fields: ["fieldRect": "18,139,354,160"])
        XCTAssertEqual(prepared["ok"] as? Bool, true)
        XCTAssertEqual(backend.prepareCount, 1)
        XCTAssertEqual(backend.textObservationCount, 1)
        XCTAssertEqual(backend.inputCount, 0)
    }

    func testScopedTextFlowKeepsNewBaselineThroughUnknownInputAndClipboardFinish() throws {
        let backend = ControlledBackend(); backend.nativeTextFixture = true; backend.nativeSend = true
        let running = try host(timeout: 5, backend: backend, native: true)
        let paths = running.paths, session = running.session, finished = running.finished
        defer { _ = try? call(paths, session: session, op: "disconnect"); wait(for: [finished], timeout: 3) }
        _ = try call(
            paths, session: session, op: "text-prepare-scoped", fields: ["fieldRect": "18,139,354,160"])
        let action = try call(
            paths, session: session, op: "type",
            fields: ["reference": "o1", "text": "a", "mode": "append", "fieldRect": "18,139,354,160"])
        XCTAssertEqual(action["outcome"] as? String, "unknown")
        XCTAssertEqual(backend.textObservationCount, 2)
        XCTAssertEqual(backend.inputCount, 1)
        let completion = try call(
            paths, session: session, op: "text-finish",
            fields: ["reference": "o2", "transaction": "00000000-0000-0000-0000-000000000001"])
        XCTAssertEqual(completion["ok"] as? Bool, true)
        XCTAssertEqual(backend.textObservationCount, 3)
        XCTAssertEqual(backend.finishCount, 1)
        XCTAssertEqual(backend.inputCount, 1)
        let stale = try call(
            paths, session: session, op: "type",
            fields: ["reference": "o1", "text": "a", "mode": "append", "fieldRect": "18,139,354,160"])
        XCTAssertEqual(stale["outcome"] as? String, "not_dispatched")
        XCTAssertEqual(backend.inputCount, 1)
    }
}
