import XCTest
import Foundation
import Network
@testable import IPhoneUseCore

private final class ControlledBackend: SessionBackend {
    let opened = DispatchSemaphore(value: 0)
    let releaseOpen = DispatchSemaphore(value: 0)
    let stopped = DispatchSemaphore(value: 0)
    var lifecycleFailure: ActionFailure?
    private(set) var appLifecycleCount = 0
    var blockOpen = false
    var loseOpenResponse = false
    var rejectOpenBeforeSend = false
    private(set) var openCount = 0
    private(set) var stopCount = 0
    private(set) var observeCount = 0
    private(set) var appsCount = 0
    private(set) var actionCount = 0
    private(set) var inputCount = 0
    var liveScreen: Data?
    var actionFailure: ActionFailure?
    var blockAction = false
    var failObservation = false
    var observationFailure: IPhoneUseError?
    var nativeSend = false
    var nativeTextFixture = false
    var nativeCaretFixture = false
    var finishAcknowledged = true
    private(set) var finishCount = 0
    private(set) var prepareCount = 0
    private(set) var recordingStarts = 0
    private(set) var recordingStops = 0
    private(set) var lastTextMethod: String?
    private(set) var lastTextMode: String?
    let actionStarted = DispatchSemaphore(value: 0)
    let releaseAction = DispatchSemaphore(value: 0)

    func start() throws -> [String: Any] { ["runnerSession": "controlled-runner", "runnerPid": 123] }
    var statusInfo: [String: Any]?
    func status() throws -> [String: Any] { try statusInfo ?? start() }
    func apps() throws -> AppCatalog {
        appsCount += 1
        return try AppCatalog(["apps": [["bundleIdentifier": "com.example.fixture", "name": "Fixture"]]])
    }
    func open(bundle: String) throws -> [String: Any] {
        if rejectOpenBeforeSend { throw TransportError(description: "Not connected", possiblySent: false) }
        openCount += 1
        opened.signal()
        if blockOpen { _ = releaseOpen.wait(timeout: .now() + 5) }
        if loseOpenResponse { throw TransportError(description: "Lost response", possiblySent: true) }
        return ["bundleId": bundle]
    }
    func appLifecycle(bundle: String, relaunch: Bool) throws -> [String: Any] {
        appLifecycleCount += 1
        if let lifecycleFailure { throw lifecycleFailure }
        return ["oldProcessAbsentConfirmed": true, "newProcessObserved": relaunch, "foregroundConfirmed": false]
    }
    func stop() -> [String: Any] {
        stopCount += 1
        stopped.signal()
        return ["shutdownAcknowledged": true, "backendStopped": true, "xcodebuildExited": true, "xcodebuildExitCode": 0, "forced": false]
    }
    func observe() throws -> CapturedObservation {
        observeCount += 1
        if let observationFailure { throw observationFailure }
        if failObservation { throw IPhoneUseError("capture_failed", "Fixture capture failure") }
        if nativeTextFixture {
            return CapturedObservation(nodes: [], metadata: ["backend": "apple-native",
                "screenContext": try jsonObject(JSONEncoder().encode(screenTestContext()))], screenshot: try screenPNG(patches: nativeCaretFixture ? [(CGRect(x:50,y:150,width:2,height:20),[7,193,96])] : []))
        }
        return try observationFixture()
    }
    private(set) var textObservationCount = 0
    var postActionStable = true
    private(set) var postActionObserveCount = 0
    func observeAfterAction(textOptions: NativeTextObservationOptions?, ignoring: ScreenRect?, sourceContext: ScreenContext?) throws -> CapturedObservation {
        postActionObserveCount += 1
        let frame = try textOptions.map { try observeText($0) } ?? observe()
        var metadata = frame.metadata
        metadata["postActionStability"] = ["stable": postActionStable, "reason": postActionStable ? "stable" : "frame_stability_timeout"]
        return CapturedObservation(nodes: frame.nodes, metadata: metadata, screenshot: frame.screenshot)
    }
    func observeText(_ options: NativeTextObservationOptions) throws -> CapturedObservation {
        textObservationCount += 1
        let captured = try observe()
        var metadata = captured.metadata
        metadata["textObservationOptions"] = try options.result
        return CapturedObservation(nodes: captured.nodes, metadata: metadata, screenshot: captured.screenshot)
    }
    func finishText(transaction: String, observation: [String: Any]) throws -> [String: Any] {
        finishCount += 1
        return ["pasteboardRestoreAcknowledged": finishAcknowledged, "transactionID": transaction]
    }
    func startPreview() throws -> [String: Any] { ["state": "waiting", "url": "http://127.0.0.1:1234/token/"] }
    func stopPreview() throws -> [String: Any] { ["state": "stopped"] }
    func startRecording(duration: Double) throws -> [String: Any] {
        recordingStarts += 1
        return ["state": "starting_or_recording", "recordingID": "00000000-0000-0000-0000-000000000001"]
    }
    func stopRecording(id: String) throws -> [String: Any] {
        recordingStops += 1
        return ["state": "completed", "recordingID": id, "fileValidated": true]
    }
    func prepareText() throws -> [String: Any] {
        prepareCount += 1
        return ["keyboardPrepared": true, "inputReportsSent": 0]
    }
    func perform(_ action: DeviceAction, target: ObservedTarget) throws -> [String: Any] {
        lastTextMethod = action.fields["textMethod"] as? String
        lastTextMode = action.fields["mode"] as? String
        actionCount += 1
        actionStarted.signal()
        if blockAction { _ = releaseAction.wait(timeout: .now() + 5) }
        if let actionFailure { throw actionFailure }
        if let liveScreen, let gesture = target.gesture {
            let check = try gesture.screenGuard.check(png: liveScreen, context: gesture.screenGuard.context)
            if !check.accepted {
                throw ActionFailure(code: "screen_changed", description: "Screen changed", possiblyExecuted: false,
                                    requiresObservation: true, result: ["screenGuard": check.result])
            }
        }
        inputCount += 1
        return nativeSend ? ["kind": action.kind, "transportStatus": "sent", "verificationStatus": "not_checked"] : ["kind": action.kind]
    }
}

final class HostTests: XCTestCase {
    func testAppLifecycleAdmissionObservationAndUnknownFacts() throws {
        for native in [false, true] {
            let backend = ControlledBackend()
            let (paths, session, finished) = try host(timeout: 5, backend: backend, native: native)
            defer { _ = try? call(paths, session: session, op: "disconnect"); wait(for: [finished], timeout: 3) }
            _ = try call(paths, session: session, op: "observe")
            let invalid = try call(paths, session: session, op: "terminate", fields: ["bundleId": "--pid 1"])
            XCTAssertEqual(invalid["outcome"] as? String, "not_dispatched")
            let result = try call(paths, session: session, op: "relaunch", fields: ["bundleId": "com.example.fixture"])
            XCTAssertEqual(result["ok"] as? Bool, true)
            XCTAssertEqual(backend.appLifecycleCount, 1)
            if native {
                XCTAssertEqual((result["observation"] as? [String: Any])?["ok"] as? Bool, true)
                XCTAssertEqual((result["result"] as? [String: Any])?["afterObservationID"] as? String, "o2")
            } else { _ = try call(paths, session: session, op: "observe") }
            let stale = try call(paths, session: session, op: "tap", fields: ["reference": "o1:e11"])
            XCTAssertEqual(stale["outcome"] as? String, "not_dispatched")
            backend.lifecycleFailure = ActionFailure(code: "native_app_process_changed", description: "Changed externally",
                possiblyExecuted: false, requiresObservation: true)
            let changed = try call(paths, session: session, op: "relaunch", fields: ["bundleId": "com.example.fixture"])
            XCTAssertEqual(changed["outcome"] as? String, "not_dispatched")
            XCTAssertEqual(changed["requiresObservation"] as? Bool, true)
            let invalidated = try call(paths, session: session, op: "tap", fields: ["reference": "o2:e11"])
            XCTAssertEqual(invalidated["outcome"] as? String, "not_dispatched")
            backend.lifecycleFailure = ActionFailure(code: "lost_reply", description: "Lost", possiblyExecuted: true,
                requiresObservation: true, result: ["terminationAcknowledged": true, "launchRequested": false])
            backend.failObservation = true
            let uncertain = try call(paths, session: session, op: "terminate", fields: ["bundleId": "com.example.fixture"])
            XCTAssertEqual(uncertain["outcome"] as? String, "unknown")
            XCTAssertEqual((uncertain["result"] as? [String: Any])?["terminationAcknowledged"] as? Bool, true)
            if native { XCTAssertEqual((uncertain["observation"] as? [String: Any])?["ok"] as? Bool, false) }
            XCTAssertEqual(backend.appLifecycleCount, 3)
        }
    }

    func testPreviewChangesInvalidateReferencesButDoNotCaptureOrSendInput() throws {
        for native in [false, true] {
            let backend = ControlledBackend()
            let (paths, session, finished) = try host(timeout: 5, backend: backend, native: native)
            defer { _ = try? call(paths, session: session, op: "disconnect"); wait(for: [finished], timeout: 3) }
            for operation in ["preview-start", "preview-stop"] {
                let observed = try call(paths, session: session, op: "observe")
                let ref = (observed["result"] as! [String: Any])["observation"] as! String
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
            let (paths, session, finished) = try host(timeout: 5, backend: backend, native: native)
            defer { _ = try? call(paths, session: session, op: "disconnect"); wait(for: [finished], timeout: 3) }
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
            let invalidStop = try call(paths, session: session, op: "record-stop", fields: ["recordingID": "bad"])
            XCTAssertEqual(invalidStop["ok"] as? Bool, false)
            let stopped = try call(paths, session: session, op: "record-stop", fields: ["recordingID": "00000000-0000-0000-0000-000000000001"])
            XCTAssertEqual(stopped["ok"] as? Bool, true)
            XCTAssertEqual(backend.recordingStops, 1)
        }
    }

    func testCaretWireOperationsRequireExplicitConfirmationAndConsumeObservation() throws {
        let backend = ControlledBackend(); backend.nativeTextFixture = true; backend.nativeCaretFixture = true
        let (paths, session, finished) = try host(timeout:5,backend:backend,native:true)
        defer { _ = try? call(paths,session:session,op:"disconnect"); wait(for:[finished],timeout:3) }
        for op in ["type-with-caret", "press-with-caret"] {
            let observed = try call(paths,session:session,op:"observe")
            let reference = (observed["result"] as! [String:Any])["observation"] as! String
            var fields: [String:Any] = ["reference":reference,"mode":"insert","text":"a","key":"left","fieldRect":"18,139,354,160"]
            let missing = try call(paths,session:session,op:op,fields:fields)
            XCTAssertEqual((missing["error"] as? [String:Any])?["code"] as? String,"invalid_caret_region")
            fields["caretRect"] = "49,149,4,22"
            let accepted = try call(paths,session:session,op:op,fields:fields)
            XCTAssertEqual(accepted["ok"] as? Bool,true)
            let stale = try call(paths,session:session,op:op,fields:fields)
            XCTAssertEqual(stale["outcome"] as? String,"not_dispatched")
        }
        XCTAssertEqual(backend.actionCount,2)
    }

    func testScopedPreparationSelectsTextObservationAndRejectsMalformedRequestBeforeRegistration() throws {
        let backend = ControlledBackend(); backend.nativeTextFixture = true
        let (paths, session, finished) = try host(timeout: 5, backend: backend, native: true)
        defer { _ = try? call(paths, session: session, op: "disconnect"); wait(for: [finished], timeout: 3) }
        let invalid = try call(paths, session: session, op: "text-prepare-scoped", fields: ["fieldRect": "0,0,-1,10"])
        XCTAssertEqual(invalid["outcome"] as? String, "not_dispatched")
        XCTAssertEqual(backend.prepareCount, 0)
        let prepared = try call(paths, session: session, op: "text-prepare-scoped", fields: ["fieldRect": "18,139,354,160"])
        XCTAssertEqual(prepared["ok"] as? Bool, true)
        XCTAssertEqual(backend.prepareCount, 1)
        XCTAssertEqual(backend.textObservationCount, 1)
        XCTAssertEqual(backend.inputCount, 0)
    }

    func testScopedTextFlowKeepsNewBaselineThroughUnknownInputAndClipboardFinish() throws {
        let backend = ControlledBackend(); backend.nativeTextFixture = true; backend.nativeSend = true
        let (paths, session, finished) = try host(timeout: 5, backend: backend, native: true)
        defer { _ = try? call(paths, session: session, op: "disconnect"); wait(for: [finished], timeout: 3) }
        _ = try call(paths, session: session, op: "text-prepare-scoped", fields: ["fieldRect": "18,139,354,160"])
        let action = try call(paths, session: session, op: "type", fields: ["reference": "o1", "text": "a", "mode": "append", "fieldRect": "18,139,354,160"])
        XCTAssertEqual(action["outcome"] as? String, "unknown")
        XCTAssertEqual(backend.textObservationCount, 2)
        XCTAssertEqual(backend.inputCount, 1)
        let completion = try call(paths, session: session, op: "text-finish", fields: ["reference": "o2", "transaction": "00000000-0000-0000-0000-000000000001"])
        XCTAssertEqual(completion["ok"] as? Bool, true)
        XCTAssertEqual(backend.textObservationCount, 3)
        XCTAssertEqual(backend.finishCount, 1)
        XCTAssertEqual(backend.inputCount, 1)
        let stale = try call(paths, session: session, op: "type", fields: ["reference": "o1", "text": "a", "mode": "append", "fieldRect": "18,139,354,160"])
        XCTAssertEqual(stale["outcome"] as? String, "not_dispatched")
        XCTAssertEqual(backend.inputCount, 1)
    }

    func testNativePreparationCapturesNewSourceThenReturnRemainsUnknownWithoutReplay() throws {
        let backend = ControlledBackend(); backend.nativeSend = true; backend.nativeTextFixture = true
        let (paths, session, finished) = try host(timeout: 5, backend: backend, native: true)
        defer { _ = try? call(paths, session: session, op: "disconnect"); wait(for: [finished], timeout: 3) }
        _ = try call(paths, session: session, op: "observe")
        let prepared = try call(paths, session: session, op: "text-prepare")
        XCTAssertEqual(prepared["outcome"] as? String, "completed")
        XCTAssertEqual((prepared["result"] as? [String: Any])?["afterObservationID"] as? String, "o2")
        XCTAssertEqual(backend.prepareCount, 1)
        XCTAssertEqual(backend.inputCount, 0)
        let stale = try call(paths, session: session, op: "press", fields: ["reference": "o1", "key": "return"])
        XCTAssertEqual(stale["outcome"] as? String, "not_dispatched")
        XCTAssertEqual(backend.inputCount, 0)
        let pressed = try call(paths, session: session, op: "press", fields: ["reference": "o2", "key": "return"])
        XCTAssertEqual(pressed["outcome"] as? String, "unknown")
        XCTAssertEqual((pressed["result"] as? [String: Any])?["afterObservationID"] as? String, "o3")
        XCTAssertEqual(backend.inputCount, 1)
        _ = try call(paths, session: session, op: "press", fields: ["reference": "o2", "key": "return"])
        XCTAssertEqual(backend.inputCount, 1)
    }

    func testPreparationPreservesFactsOnCaptureFailureAndIsNativeOnly() throws {
        for native in [true, false] {
            let backend = ControlledBackend(); backend.nativeTextFixture = native
            let (paths, session, finished) = try host(timeout: 5, backend: backend, native: native)
            defer { _ = try? call(paths, session: session, op: "disconnect"); wait(for: [finished], timeout: 3) }
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
                let stale = try call(paths, session: session, op: "press", fields: ["reference": "o1", "key": "return"])
                XCTAssertEqual(stale["outcome"] as? String, "not_dispatched")
            } else {
                XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? String, "native_action_unsupported")
            }
        }
    }
    func testNativeEditingModesReachBackendOnceAndInvalidateSource() throws {
        let backend = ControlledBackend(); backend.nativeSend = true; backend.nativeTextFixture = true
        let (paths, session, finished) = try host(timeout: 5, backend: backend, native: true)
        defer { _ = try? call(paths, session: session, op: "disconnect"); wait(for: [finished], timeout: 3) }
        _ = try call(paths, session: session, op: "observe")
        for (index, mode) in ["replace", "append", "insert"].enumerated() {
            let fields: [String: Any] = ["reference": "o\(index + 1)", "mode": mode, "text": "中文", "textMethod": "paste"]
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
        let (paths, session, finished) = try host(timeout: 5, backend: backend, native: true)
        defer { _ = try? call(paths, session: session, op: "disconnect"); wait(for: [finished], timeout: 3) }
        let token = UUID().uuidString
        _ = try call(paths, session: session, op: "observe")
        let typed = try call(paths, session: session, op: "type-with-method", fields: ["reference": "o1", "mode": "insert", "text": String(repeating: "A", count: 100), "textMethod": "paste"])
        XCTAssertEqual(typed["outcome"] as? String, "unknown")
        XCTAssertEqual(backend.lastTextMethod, "paste")
        XCTAssertEqual(backend.inputCount, 1)
        let stale = try call(paths, session: session, op: "text-finish", fields: ["reference": "o1", "transaction": token])
        XCTAssertEqual(stale["outcome"] as? String, "not_dispatched")
        XCTAssertEqual(backend.finishCount, 0)
        let response = try call(paths, session: session, op: "text-finish", fields: ["reference": "o2", "transaction": token])
        XCTAssertEqual(response["outcome"] as? String, "completed")
        XCTAssertEqual((response["result"] as? [String: Any])?["sourceObservationID"] as? String, "o2")
        XCTAssertEqual((response["result"] as? [String: Any])?["afterObservationID"] as? String, "o3")
        XCTAssertEqual(backend.finishCount, 1)
        XCTAssertEqual(backend.inputCount, 1)
        XCTAssertEqual(backend.stopCount, 0)
        XCTAssertEqual(try call(paths, session: session, op: "status")["ok"] as? Bool, true)
        let reused = try call(paths, session: session, op: "text-finish", fields: ["reference": "o2", "transaction": token])
        XCTAssertEqual(reused["outcome"] as? String, "not_dispatched")
        XCTAssertEqual(backend.finishCount, 1)
    }

    func testUnconfirmedFinishPreservesCleanupFactsWhenCaptureFailsAndRunnerRejectsOptions() throws {
        for native in [true, false] {
            let backend = ControlledBackend(); backend.nativeTextFixture = native; backend.finishAcknowledged = false
            let (paths, session, finished) = try host(timeout: 5, backend: backend, native: native)
            defer { _ = try? call(paths, session: session, op: "disconnect"); wait(for: [finished], timeout: 3) }
            _ = try call(paths, session: session, op: "observe")
            backend.failObservation = true
            let response = try call(paths, session: session, op: "text-finish", fields: ["reference": "o1", "transaction": UUID().uuidString])
            XCTAssertEqual(response["outcome"] as? String, native ? "unknown" : "not_dispatched")
            XCTAssertEqual(backend.finishCount, native ? 1 : 0)
            XCTAssertEqual(backend.inputCount, 0)
            if native {
                XCTAssertEqual((response["result"] as? [String: Any])?["pasteboardRestoreAcknowledged"] as? Bool, false)
                XCTAssertEqual((response["observation"] as? [String: Any])?["ok"] as? Bool, false)
            } else {
                let typed = try call(paths, session: session, op: "type-with-method", fields: ["reference": "o1:e27", "mode": "insert", "text": "abc", "textMethod": "paste"])
                XCTAssertEqual((typed["error"] as? [String: Any])?["code"] as? String, "invalid_text_method")
                XCTAssertEqual(backend.actionCount, 0)
            }
        }
    }

    func testClientFollowupUsesExistingProtocolAndPreservesReferenceRules() throws {
        let backend = ControlledBackend()
        let (paths, session, finished) = try host(timeout: 5, backend: backend)
        defer {
            _ = try? call(paths, session: session, op: "disconnect")
            wait(for: [finished], timeout: 3)
        }
        _ = try call(paths, session: session, op: "observe")
        let rejected = try call(paths, session: session, op: "tap", fields: ["reference": "o1:e11", "x": 1, "y": 1])
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
        backend.actionFailure = ActionFailure(code: "lost_result", description: "Unknown", possiblyExecuted: true, requiresObservation: true)
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
        let (paths, session, finished) = try host(timeout: 5, backend: backend, native: true)
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
        let stale = try call(paths, session: session, op: "tap", fields: ["reference": "o1:e11"])
        XCTAssertEqual(stale["outcome"] as? String, "not_dispatched")
        XCTAssertEqual(backend.actionCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.directory.appendingPathComponent("native-events.jsonl").path))
    }

    func testNativeAfterCaptureFailurePreservesInputFacts() throws {
        let backend = ControlledBackend(); backend.nativeSend = true
        let (paths, session, finished) = try host(timeout: 5, backend: backend, native: true)
        defer {
            _ = try? call(paths, session: session, op: "disconnect")
            wait(for: [finished], timeout: 3)
        }
        _ = try call(paths, session: session, op: "observe")
        backend.observationFailure = IPhoneUseError("post_action_capture_timeout", "No valid frame",
            diagnostics: ["capture": ["failedStage": "checksAfter", "commands": [["command": "device info lockState", "ok": false]]]])
        let response = try call(paths, session: session, op: "tap", fields: ["reference": "o1:e11"])
        XCTAssertEqual(response["outcome"] as? String, "unknown")
        XCTAssertEqual((response["result"] as? [String: Any])?["transportStatus"] as? String, "sent")
        XCTAssertEqual((response["observation"] as? [String: Any])?["ok"] as? Bool, false)
        let observation = try XCTUnwrap(response["observation"] as? [String: Any])
        XCTAssertEqual(observation["errorCode"] as? String, "post_action_capture_timeout")
        let diagnostics = observation["diagnostics"] as? [String: Any]
        XCTAssertEqual((diagnostics?["capture"] as? [String: Any])?["failedStage"] as? String, "checksAfter")
        XCTAssertEqual(((response["result"] as? [String: Any])?["recovery"] as? [String: Any])?["nextAction"] as? String, "observe")
        XCTAssertEqual(backend.actionCount, 1)
    }

    func testNativeUnstableObservationPreservesUnknownInputAndNeverReplays() throws {
        let backend = ControlledBackend(); backend.nativeSend = true; backend.postActionStable = false
        let (paths, session, finished) = try host(timeout: 5, backend: backend, native: true)
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
        let snapshot = try jsonObject(Data(contentsOf: URL(fileURLWithPath: after["snapshot"] as! String)))
        XCTAssertEqual(((snapshot["metadata"] as? [String: Any])?["postActionStability"] as? [String: Any])?["stable"] as? Bool, false)
        let summary = AgentOutput.summarize(response)["agentSummary"] as? [String: Any]
        XCTAssertEqual(summary?["nextStep"] as? String, "inspect_unstable_observation_do_not_replay")
        XCTAssertEqual(backend.inputCount, 1)
        XCTAssertEqual(backend.postActionObserveCount, 1)
    }

    func testNativePreDispatchFailureDoesNotCaptureOrInvalidateCurrentReference() throws {
        let backend = ControlledBackend()
        backend.actionFailure = ActionFailure(code: "native_control_unavailable", description: "No authorized HID service",
            possiblyExecuted: false, requiresObservation: false)
        let (paths, session, finished) = try host(timeout: 5, backend: backend, native: true)
        defer {
            _ = try? call(paths, session: session, op: "disconnect")
            wait(for: [finished], timeout: 3)
        }
        _ = try call(paths, session: session, op: "observe")
        let response = try call(paths, session: session, op: "tap", fields: ["reference": "o1:e11"])
        XCTAssertEqual(response["outcome"] as? String, "not_dispatched")
        XCTAssertNil(response["observation"])
        XCTAssertEqual(backend.inputCount, 0); XCTAssertEqual(backend.observeCount, 1)
        let snapshot = try call(paths, session: session, op: "inspect", fields: ["reference": "o1", "offset": 0])
        XCTAssertEqual((snapshot["result"] as? [String: Any])?["refs"] as? String, "current")
    }

    func testNativeGuardRejectionAttachesExactFrameWithoutInputOrRecapture() throws {
        let backend = ControlledBackend()
        let capture = try observationFixture()
        backend.actionFailure = ActionFailure(code: "stale_observation", description: "Changed pixels",
            possiblyExecuted: false, requiresObservation: true,
            result: ["screenGuard": ["accepted": false, "regionChanges": [0.125]]], rejectedCapture: capture)
        let (paths, session, finished) = try host(timeout: 5, backend: backend, native: true)
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
        backend.statusInfo = NativeControlStatus.resolve(hid: .releaseUncertain, media: ["healthy": true], closing: false,
                                                         startupCode: nil, startupError: nil).result
        backend.actionFailure = ActionFailure(code: "native_input_uncertain", description: "Lost release",
            possiblyExecuted: true, requiresObservation: true, result: ["cleanup": ["releaseUncertain": true]])
        let (paths, session, finished) = try host(timeout: 5, backend: backend, native: true)
        defer { _ = try? call(paths, session: session, op: "disconnect"); wait(for: [finished], timeout: 3) }
        _ = try call(paths, session: session, op: "observe")
        let failed = try call(paths, session: session, op: "tap", fields: ["reference": "o1:e11"])
        let facts = try XCTUnwrap(failed["result"] as? [String: Any])
        XCTAssertEqual(failed["outcome"] as? String, "unknown")
        XCTAssertEqual(facts["controlErrorCode"] as? String, "native_release_uncertain")
        XCTAssertEqual((facts["recovery"] as? [String: Any])?["requiresReconnect"] as? Bool, true)
        XCTAssertEqual(facts["afterObservationID"] as? String, "o2")
        backend.actionFailure = ActionFailure(code: "native_control_unavailable", description: "Release uncertain",
            possiblyExecuted: false, requiresObservation: false, result: backend.statusInfo)
        let rejected = try call(paths, session: session, op: "tap", fields: ["reference": "o2:e11"])
        XCTAssertEqual(rejected["outcome"] as? String, "not_dispatched")
        XCTAssertEqual(((rejected["result"] as? [String: Any])?["recovery"] as? [String: Any])?["nextAction"] as? String, "reconnect_and_observe")
        XCTAssertEqual(backend.observeCount, 2)
        XCTAssertEqual(backend.inputCount, 0)
    }

    private func host(timeout: Double, backend: ControlledBackend, native: Bool = false) throws -> (SessionPaths, String, XCTestExpectation) {
        let directory = URL(fileURLWithPath: "/private/tmp/as-test-\(UUID().uuidString.prefix(8))")
        try SessionPaths.secureDirectory(directory)
        let paths = SessionPaths(directory: directory)
        let session = "test-session"
        let config = HostConfiguration(session: session, device: "test", xctestrun: "/unused", idleTimeoutSeconds: timeout,
                                       backend: native ? "apple-native" : nil)
        let host = SessionHost(config: config, paths: paths, backend: backend)
        let finished = expectation(description: "host exited")
        DispatchQueue.global().async {
            do { try host.run() } catch { XCTFail("Host failed: \(error)") }
            finished.fulfill()
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let response = try? call(paths, session: session, op: "status"), response["ok"] as? Bool == true {
                return (paths, session, finished)
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw IPhoneUseError("test_start_timeout", "Test host never became ready")
    }

    private func call(_ paths: SessionPaths, session: String, op: String, fields: [String: Any] = [:]) throws -> [String: Any] {
        var request = fields
        request["version"] = 1
        request["id"] = UUID().uuidString
        request["session"] = session
        request["op"] = op
        return try JSONTransport.exchange(endpoint: .unix(path: paths.socket), request: request, timeout: 5)
    }

    func testHostReportsFixedModeForStatusActionsRejectionsAndDisconnect() throws {
        for native in [true, false] {
            let backend = ControlledBackend()
            let (paths, session, finished) = try host(timeout: 5, backend: backend, native: native)
            let expectedMode = native ? "standard" : "runner"
            let expectedBackend = native ? "apple-native" : "xctest"
            let status = try call(paths, session: session, op: "status")
            XCTAssertEqual((status["result"] as? [String: Any])?["mode"] as? String, expectedMode)
            let support = (status["result"] as? [String: Any])?["support"] as? [String: Any]
            XCTAssertEqual((support?["operations"] as? [String])?.contains("record-start"), true)
            XCTAssertEqual(support?["textModes"] as? [String], ["insert", "replace", "append"])
            let observed = try call(paths, session: session, op: "observe")
            let rejected = try call(paths, session: session, op: "not-an-operation")
            let disconnected = try call(paths, session: session, op: "disconnect")
            for response in [status, observed, rejected, disconnected] {
                XCTAssertEqual(response["mode"] as? String, expectedMode)
                XCTAssertEqual(response["backend"] as? String, expectedBackend)
                XCTAssertEqual(response["modeSource"] as? String, "legacy_session")
            }
            wait(for: [finished], timeout: 3)
        }
    }

    func testUnixIPCReuseDisconnectAndSocketRemoval() throws {
        let backend = ControlledBackend()
        let (paths, session, finished) = try host(timeout: 5, backend: backend)
        for _ in 0..<3 {
            let response = try call(paths, session: session, op: "status")
            XCTAssertEqual((response["result"] as? [String: Any])?["runnerSession"] as? String, "controlled-runner")
        }
        XCTAssertEqual(try call(paths, session: session, op: "disconnect")["ok"] as? Bool, true)
        wait(for: [finished], timeout: 3)
        XCTAssertEqual(backend.stopCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.socket))
        XCTAssertThrowsError(try call(paths, session: session, op: "status"))
    }

    func testNativeExitUsesFinalAvailabilityInsteadOfStartupSnapshot() throws {
        let backend = ControlledBackend()
        backend.statusInfo = ["controlAvailable": false, "capabilities": ["tap": false], "media": ["rtpPackets": 37]]
        let (paths, session, finished) = try host(timeout: 5, backend: backend, native: true)
        let response = try call(paths, session: session, op: "disconnect")
        wait(for: [finished], timeout: 3)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let final = try XCTUnwrap(result["backend"] as? [String: Any])
        XCTAssertEqual(final["controlAvailable"] as? Bool, false)
        XCTAssertEqual((final["capabilities"] as? [String: Any])?["tap"] as? Bool, false)
        XCTAssertEqual((final["media"] as? [String: Any])?["rtpPackets"] as? Int, 37)
        let saved = try jsonObject(Data(contentsOf: paths.exit))
        XCTAssertEqual((saved["backend"] as? [String: Any])?["controlAvailable"] as? Bool, false)
        XCTAssertEqual(backend.stopCount, 1)
    }

    func testOverlongSwipeNeverReachesBackendOrInvalidatesObservation() throws {
        let backend = ControlledBackend()
        let (paths, session, finished) = try host(timeout: 5, backend: backend)
        _ = try call(paths, session: session, op: "observe")
        let response = try call(paths, session: session, op: "swipe", fields: ["reference": "o1",
            "fromX": 100, "fromY": 600, "toX": 100, "toY": 200, "velocity": 1])
        XCTAssertEqual(response["outcome"] as? String, "not_dispatched")
        XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? String, "swipe_duration_exceeded")
        XCTAssertEqual(backend.actionCount, 0)
        XCTAssertEqual(backend.inputCount, 0)
        let tap = try call(paths, session: session, op: "tap", fields: ["reference": "o1", "x": 100, "y": 600])
        XCTAssertEqual(tap["outcome"] as? String, "completed")
        XCTAssertEqual(backend.inputCount, 1)
        _ = try call(paths, session: session, op: "disconnect")
        wait(for: [finished], timeout: 3)
    }

    func testCoordinateReferenceConflictCanBeCorrectedWithoutRecapturing() throws {
        let backend = ControlledBackend()
        let (paths, session, finished) = try host(timeout: 5, backend: backend)
        for (index, operation) in ["tap", "swipe"].enumerated() {
            _ = try call(paths, session: session, op: "observe")
            let observation = "o\(index + 1)"
            let reference = "\(observation):e1"
            var fields: [String: Any] = operation == "tap" ? ["x": 100, "y": 600]
                : ["fromX": 100, "fromY": 600, "toX": 100, "toY": 550]
            fields["reference"] = reference
            let rejected = try call(paths, session: session, op: operation, fields: fields)
            XCTAssertEqual(rejected["outcome"] as? String, "not_dispatched")
            let error = try XCTUnwrap(rejected["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? String, "invalid_coordinates")
            let message = try XCTUnwrap(error["message"] as? String)
            XCTAssertTrue(message.contains("Element reference \(reference)"))
            XCTAssertTrue(message.contains("Use \(operation) \(observation) "))
            XCTAssertTrue(message.contains("--protect \(reference)"))
            XCTAssertEqual(backend.actionCount, index)
            XCTAssertEqual(backend.inputCount, index)

            fields["reference"] = observation
            fields["protect"] = [reference]
            let corrected = try call(paths, session: session, op: operation, fields: fields)
            XCTAssertEqual(corrected["outcome"] as? String, "completed")
            XCTAssertEqual(backend.inputCount, index + 1)
            XCTAssertEqual(backend.observeCount, index + 1)
        }
        _ = try call(paths, session: session, op: "disconnect")
        wait(for: [finished], timeout: 3)
    }

    func testHealthTrafficCannotPreventIdleCleanup() throws {
        let backend = ControlledBackend()
        let (paths, session, finished) = try host(timeout: 0.4, backend: backend)
        let observed = try call(paths, session: session, op: "observe")["result"] as! [String: Any]
        let deadline = Date().addingTimeInterval(1.2)
        var checks = 0
        while Date() < deadline {
            if let reply = try? call(paths, session: session, op: "status"), reply["ok"] as? Bool == true { checks += 1 }
            else { break }
            Thread.sleep(forTimeInterval: 0.04)
        }
        wait(for: [finished], timeout: 2)
        XCTAssertGreaterThan(checks, 2)
        XCTAssertEqual(try jsonObject(Data(contentsOf: paths.exit))["reason"] as? String, "idle_timeout")
        XCTAssertFalse(FileManager.default.fileExists(atPath: observed["screenshot"] as! String))
        XCTAssertThrowsError(try call(paths, session: session, op: "inspect", fields: ["reference": "o1", "offset": 0]))
    }

    func testInFlightCommandSurvivesTimeoutAndRenewsAtCompletion() throws {
        let backend = ControlledBackend()
        backend.blockOpen = true
        let (paths, session, finished) = try host(timeout: 0.4, backend: backend)
        let responseReceived = expectation(description: "open completed")
        DispatchQueue.global().async {
            do {
                let response = try self.call(paths, session: session, op: "open", fields: ["bundleId": "fixture"])
                XCTAssertEqual(response["outcome"] as? String, "completed")
            } catch { XCTFail("\(error)") }
            responseReceived.fulfill()
        }
        XCTAssertEqual(backend.opened.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(backend.stopped.wait(timeout: .now() + 0.65), .timedOut)
        backend.releaseOpen.signal()
        wait(for: [responseReceived], timeout: 2)
        let status = try call(paths, session: session, op: "status")
        XCTAssertGreaterThan(status["idleRemainingSeconds"] as? Double ?? 0, 0.2)
        wait(for: [finished], timeout: 2)
    }

    func testDisconnectWaitsForAdmittedCommand() throws {
        let backend = ControlledBackend()
        backend.blockOpen = true
        let (paths, session, finished) = try host(timeout: 5, backend: backend)
        let action = expectation(description: "action returned")
        let disconnect = expectation(description: "disconnect returned")
        DispatchQueue.global().async {
            _ = try? self.call(paths, session: session, op: "open", fields: ["bundleId": "fixture"])
            action.fulfill()
        }
        XCTAssertEqual(backend.opened.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().async {
            do {
                let response = try self.call(paths, session: session, op: "disconnect")
                XCTAssertEqual(response["ok"] as? Bool, true)
            }
            catch { XCTFail("\(error)") }
            disconnect.fulfill()
        }
        XCTAssertEqual(backend.stopped.wait(timeout: .now() + 0.2), .timedOut)
        backend.releaseOpen.signal()
        wait(for: [action, disconnect, finished], timeout: 3)
        XCTAssertEqual(backend.openCount, 1)
        XCTAssertEqual(backend.stopCount, 1)
    }

    func testInvalidRequestsDoNotDispatchAndUnknownIsNotReplayed() throws {
        let backend = ControlledBackend()
        backend.loseOpenResponse = true
        let (paths, session, finished) = try host(timeout: 5, backend: backend)
        XCTAssertEqual(try call(paths, session: session, op: "open")["outcome"] as? String, "not_dispatched")
        XCTAssertEqual(backend.openCount, 0)
        XCTAssertEqual(try call(paths, session: session, op: "open", fields: ["bundleId": "fixture"])["outcome"] as? String, "unknown")
        _ = try call(paths, session: session, op: "status")
        XCTAssertEqual(backend.openCount, 1)
        _ = try call(paths, session: session, op: "disconnect")
        wait(for: [finished], timeout: 3)
    }

    func testDeviceLockExclusionAndRelease() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/as-lock-\(UUID().uuidString.prefix(8))")
        try SessionPaths.secureDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        var first: DeviceLock? = try DeviceLock(root: directory, device: "device-1")
        XCTAssertNotNil(first)
        XCTAssertThrowsError(try DeviceLock(root: directory, device: "device-1"))
        first = nil
        XCTAssertNoThrow(try DeviceLock(root: directory, device: "device-1"))
    }

    func testInspectDoesNotCallDeviceAndDispatchedOpenInvalidatesCachedRefs() throws {
        let backend = ControlledBackend()
        let (paths, session, finished) = try host(timeout: 5, backend: backend)
        let observed = try call(paths, session: session, op: "observe")["result"] as! [String: Any]
        let image = observed["screenshot"] as! String
        let inspect: [String: Any] = ["reference": "o1:e27", "offset": 0]
        func validity() throws -> String? {
            (try call(paths, session: session, op: "inspect", fields: inspect)["result"] as? [String: Any])?["refs"] as? String
        }
        XCTAssertEqual(try validity(), "current")
        _ = try call(paths, session: session, op: "open") // Invalid parameter, never admitted.
        XCTAssertEqual(try validity(), "current")
        backend.rejectOpenBeforeSend = true
        XCTAssertEqual(try call(paths, session: session, op: "open", fields: ["bundleId": "fixture"])["outcome"] as? String, "not_dispatched")
        XCTAssertEqual(try validity(), "current")
        backend.rejectOpenBeforeSend = false
        backend.loseOpenResponse = true
        XCTAssertEqual(try call(paths, session: session, op: "open", fields: ["bundleId": "fixture"])["outcome"] as? String, "unknown")
        XCTAssertEqual(try validity(), "invalidated")
        XCTAssertEqual(backend.observeCount, 1)
        XCTAssertEqual(backend.openCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: image))
        _ = try call(paths, session: session, op: "observe")
        backend.loseOpenResponse = false
        _ = try call(paths, session: session, op: "open", fields: ["bundleId": "fixture"])
        let latest = try call(paths, session: session, op: "inspect", fields: ["reference": "o2:e27", "offset": 0])
        XCTAssertEqual((latest["result"] as? [String: Any])?["refs"] as? String, "invalidated")
        _ = try call(paths, session: session, op: "disconnect")
        wait(for: [finished], timeout: 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: image))
    }

    func testInspectQueryFindsLaterNodesWithoutRecapturingOrRevivingReferences() throws {
        let backend = ControlledBackend()
        let (paths, session, finished) = try host(timeout: 5, backend: backend)
        _ = try call(paths, session: session, op: "observe")
        let fields: [String: Any] = ["reference": "o1", "offset": 0, "query": "wEb iNpUt"]
        let reply = try call(paths, session: session, op: "inspect", fields: fields)
        XCTAssertEqual(reply["ok"] as? Bool, true)
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        let text = try XCTUnwrap(result["text"] as? String)
        XCTAssertEqual(result["query"] as? String, "wEb iNpUt")
        // The recorded source contains a group, its text child and the separate input.
        XCTAssertTrue(text.contains("matched_nodes=3"))
        XCTAssertTrue(text.contains("\"ref\":\"o1:e25\""))
        XCTAssertTrue(text.contains("\"ref\":\"o1:e26\""))
        XCTAssertTrue(text.contains("\"ref\":\"o1:e27\""))
        XCTAssertTrue(text.contains("\"parentRef\":"))
        XCTAssertEqual(result["refs"] as? String, "current")
        _ = try call(paths, session: session, op: "tap", fields: ["reference": "o1:e27"])
        let stale = try call(paths, session: session, op: "inspect", fields: fields)
        XCTAssertEqual((stale["result"] as? [String: Any])?["refs"] as? String, "invalidated")
        XCTAssertEqual(backend.observeCount, 1)
        XCTAssertEqual(backend.inputCount, 1)
        _ = try call(paths, session: session, op: "disconnect")
        wait(for: [finished], timeout: 3)
    }

    func testInvalidInspectQueryDoesNotRenewOrChangeReferences() throws {
        let backend = ControlledBackend()
        let (paths, session, finished) = try host(timeout: 5, backend: backend)
        _ = try call(paths, session: session, op: "observe")
        let first = try call(paths, session: session, op: "status")["idleRemainingSeconds"] as! Double
        Thread.sleep(forTimeInterval: 0.1)
        for query: Any in [42, NSNull(), "", "  ", "one\ntwo", String(repeating: "a", count: 257)] {
            let reply = try call(paths, session: session, op: "inspect", fields: ["reference": "o1", "offset": 0, "query": query])
            XCTAssertEqual((reply["error"] as? [String: Any])?["code"] as? String, "invalid_inspect_query")
        }
        let afterInvalid = try call(paths, session: session, op: "status")["idleRemainingSeconds"] as! Double
        XCTAssertLessThan(afterInvalid, first - 0.08)
        let result = try call(paths, session: session, op: "inspect", fields: ["reference": "o1", "offset": 0, "query": "absent"])
        XCTAssertEqual((result["result"] as? [String: Any])?["refs"] as? String, "current")
        let renewed = try call(paths, session: session, op: "status")["idleRemainingSeconds"] as! Double
        XCTAssertGreaterThan(renewed, afterInvalid + 0.08)
        XCTAssertEqual(backend.observeCount, 1)
        XCTAssertEqual(backend.actionCount, 0)
        _ = try call(paths, session: session, op: "disconnect")
        wait(for: [finished], timeout: 3)
    }

    func testObservationAndInspectRenewIdleButInvalidInspectDoesNot() throws {
        let backend = ControlledBackend()
        let (paths, session, finished) = try host(timeout: 5, backend: backend)
        _ = try call(paths, session: session, op: "observe")
        let first = try call(paths, session: session, op: "status")["idleRemainingSeconds"] as! Double
        Thread.sleep(forTimeInterval: 0.1)
        let invalid = try call(paths, session: session, op: "inspect", fields: ["reference": "o99", "offset": 0])
        XCTAssertEqual(invalid["ok"] as? Bool, false)
        let afterInvalid = try call(paths, session: session, op: "status")["idleRemainingSeconds"] as! Double
        XCTAssertLessThan(afterInvalid, first - 0.08)
        _ = try call(paths, session: session, op: "inspect", fields: ["reference": "o1", "offset": 0])
        let renewed = try call(paths, session: session, op: "status")["idleRemainingSeconds"] as! Double
        XCTAssertGreaterThan(renewed, afterInvalid + 0.08)
        XCTAssertEqual(backend.observeCount, 1)
        _ = try call(paths, session: session, op: "disconnect")
        wait(for: [finished], timeout: 3)
    }

    func testAppDiscoveryRenewsOnlyOnSuccessAndPreservesObservationReferences() throws {
        let backend = ControlledBackend()
        let (paths, session, finished) = try host(timeout: 5, backend: backend)
        _ = try call(paths, session: session, op: "observe")
        let first = try call(paths, session: session, op: "status")["idleRemainingSeconds"] as! Double
        Thread.sleep(forTimeInterval: 0.1)
        let invalid = try call(paths, session: session, op: "apps", fields: ["offset": -1])
        XCTAssertEqual(invalid["ok"] as? Bool, false)
        XCTAssertEqual(backend.appsCount, 0)
        let pastEnd = try call(paths, session: session, op: "apps", fields: ["offset": 2])
        XCTAssertEqual(pastEnd["ok"] as? Bool, false)
        let afterInvalid = try call(paths, session: session, op: "status")["idleRemainingSeconds"] as! Double
        XCTAssertLessThan(afterInvalid, first - 0.08)
        let listed = try call(paths, session: session, op: "apps", fields: ["offset": 0, "query": "Fixture"])
        XCTAssertEqual((listed["result"] as? [String: Any])?["total"] as? Int, 1)
        let renewed = try call(paths, session: session, op: "status")["idleRemainingSeconds"] as! Double
        XCTAssertGreaterThan(renewed, afterInvalid + 0.08)
        let inspected = try call(paths, session: session, op: "inspect", fields: ["reference": "o1:e11", "offset": 0])
        XCTAssertEqual((inspected["result"] as? [String: Any])?["refs"] as? String, "current")
        XCTAssertEqual(backend.observeCount, 1)
        XCTAssertEqual(backend.actionCount, 0)
        for bundle in ["invalid bundle", "com.example.fixture\n"] {
            XCTAssertEqual(try call(paths, session: session, op: "open", fields: ["bundleId": bundle])["outcome"] as? String, "not_dispatched")
        }
        XCTAssertEqual(backend.openCount, 0)
        _ = try call(paths, session: session, op: "disconnect")
        wait(for: [finished], timeout: 3)
    }

    func testActionFactsPreserveRejectedReferencesAndInvalidateChangedOrUnknownTargets() throws {
        let backend = ControlledBackend()
        let (paths, session, finished) = try host(timeout: 5, backend: backend)
        for (index, failure) in [
            ActionFailure(code: "ambiguous_target", description: "Ambiguous", possiblyExecuted: false, requiresObservation: false),
            ActionFailure(code: "target_changed", description: "Changed", possiblyExecuted: false, requiresObservation: true),
            ActionFailure(code: "lost_result", description: "Unknown", possiblyExecuted: true, requiresObservation: true)
        ].enumerated() {
            _ = try call(paths, session: session, op: "observe")
            backend.actionFailure = failure
            let reference = "o\(index + 1):e11"
            let result = try call(paths, session: session, op: "tap", fields: ["reference": reference])
            XCTAssertEqual(result["outcome"] as? String, failure.possiblyExecuted ? "unknown" : "not_dispatched")
            let detail = try call(paths, session: session, op: "inspect", fields: ["reference": reference, "offset": 0])
            XCTAssertEqual((detail["result"] as? [String: Any])?["refs"] as? String,
                           index == 0 ? "current" : (index == 1 ? "target_changed" : "invalidated"))
        }
        XCTAssertEqual(backend.actionCount, 3)
        let stale = try call(paths, session: session, op: "tap", fields: ["reference": "o3:e11"])
        XCTAssertEqual(stale["outcome"] as? String, "not_dispatched")
        XCTAssertEqual(backend.actionCount, 3)
        _ = try call(paths, session: session, op: "disconnect")
        wait(for: [finished], timeout: 3)
    }

    func testReturnRejectsInvalidTargetsAndInvalidatesWithoutReplay() throws {
        let backend = ControlledBackend()
        let (paths, session, finished) = try host(timeout: 5, backend: backend)
        _ = try call(paths, session: session, op: "observe")
        for fields in [["reference": "o1:e27", "key": "enter"], ["reference": "o1:e11", "key": "return"]] {
            XCTAssertEqual(try call(paths, session: session, op: "press", fields: fields)["outcome"] as? String, "not_dispatched")
        }
        XCTAssertEqual(backend.actionCount, 0)
        let detail = try call(paths, session: session, op: "inspect", fields: ["reference": "o1", "offset": 0])
        XCTAssertEqual((detail["result"] as? [String: Any])?["refs"] as? String, "current")
        let fields = ["reference": "o1:e27", "key": "return"]
        XCTAssertEqual(try call(paths, session: session, op: "press", fields: fields)["outcome"] as? String, "completed")
        XCTAssertEqual(try call(paths, session: session, op: "press", fields: fields)["outcome"] as? String, "not_dispatched")
        XCTAssertEqual(backend.actionCount, 1)
        _ = try call(paths, session: session, op: "observe")
        backend.actionFailure = ActionFailure(code: "lost_result", description: "Unknown", possiblyExecuted: true, requiresObservation: true)
        XCTAssertEqual(try call(paths, session: session, op: "press", fields: ["reference": "o2:e27", "key": "return"])["outcome"] as? String, "unknown")
        let afterUnknown = try call(paths, session: session, op: "inspect", fields: ["reference": "o2", "offset": 0])
        XCTAssertEqual((afterUnknown["result"] as? [String: Any])?["refs"] as? String, "invalidated")
        _ = try call(paths, session: session, op: "status")
        XCTAssertEqual(backend.actionCount, 2)
        _ = try call(paths, session: session, op: "disconnect")
        wait(for: [finished], timeout: 3)
    }

    func testQueuedActionsCannotReuseAReferenceAfterTheFirstAction() throws {
        let backend = ControlledBackend()
        backend.blockAction = true
        let (paths, session, finished) = try host(timeout: 5, backend: backend)
        _ = try call(paths, session: session, op: "observe")
        let first = expectation(description: "first action")
        let second = expectation(description: "second action rejected")
        DispatchQueue.global().async {
            do {
                let result = try self.call(paths, session: session, op: "tap", fields: ["reference": "o1:e11"])
                XCTAssertEqual(result["outcome"] as? String, "completed")
            } catch { XCTFail("\(error)") }
            first.fulfill()
        }
        XCTAssertEqual(backend.actionStarted.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().async {
            do {
                let result = try self.call(paths, session: session, op: "tap", fields: ["reference": "o1:e11"])
                XCTAssertEqual(result["outcome"] as? String, "not_dispatched")
            } catch { XCTFail("\(error)") }
            second.fulfill()
        }
        backend.releaseAction.signal()
        wait(for: [first, second], timeout: 3)
        XCTAssertEqual(backend.actionCount, 1)
        _ = try call(paths, session: session, op: "disconnect")
        wait(for: [finished], timeout: 3)
    }

    func testUnstableFramePreservesCompletedInputAndCannotReplayAnOldReference() throws {
        let backend = ControlledBackend()
        backend.actionFailure = ActionFailure(code: "frame_stability_timeout", description: "Screen still changing",
            possiblyExecuted: true, requiresObservation: true,
            result: ["execution": ["started": true, "inputCompleted": true, "completed": false],
                     "stability": ["stable": false], "frame": ["screenshot": "/last-action.png"]])
        let (paths, session, finished) = try host(timeout: 5, backend: backend)
        _ = try call(paths, session: session, op: "observe")
        let result = try call(paths, session: session, op: "tap", fields: ["reference": "o1:e11"])
        XCTAssertEqual(result["outcome"] as? String, "unknown")
        let details = result["result"] as? [String: Any]
        XCTAssertEqual((details?["execution"] as? [String: Bool])?["inputCompleted"], true)
        XCTAssertEqual((details?["stability"] as? [String: Bool])?["stable"], false)
        let retry = try call(paths, session: session, op: "tap", fields: ["reference": "o1:e11"])
        XCTAssertEqual(retry["outcome"] as? String, "not_dispatched")
        XCTAssertEqual(backend.actionCount, 1)
        _ = try call(paths, session: session, op: "disconnect")
        wait(for: [finished], timeout: 3)
    }

    func testScreenGuardRejectionInvalidatesRefsBeforeAnyInputAndDoesNotRetry() throws {
        let backend = ControlledBackend()
        backend.liveScreen = try screenPNG(patches: [(CGRect(x: 0, y: 0, width: 390, height: 844), [0, 0, 0])])
        let (paths, session, finished) = try host(timeout: 5, backend: backend)
        _ = try call(paths, session: session, op: "observe")
        let fields: [String: Any] = ["reference": "o1", "x": 200, "y": 600]
        let rejected = try call(paths, session: session, op: "tap", fields: fields)
        XCTAssertEqual(rejected["outcome"] as? String, "not_dispatched")
        XCTAssertEqual(rejected["requiresObservation"] as? Bool, true)
        XCTAssertEqual((rejected["error"] as? [String: Any])?["code"] as? String, "screen_changed")
        XCTAssertEqual(backend.inputCount, 0)
        let again = try call(paths, session: session, op: "tap", fields: fields)
        XCTAssertEqual((again["error"] as? [String: Any])?["code"] as? String, "stale_reference")
        XCTAssertEqual(backend.actionCount, 1)
        backend.liveScreen = try screenPNG()
        _ = try call(paths, session: session, op: "observe")
        XCTAssertEqual(try call(paths, session: session, op: "tap", fields: ["reference": "o2", "x": 200, "y": 600])["outcome"] as? String, "completed")
        XCTAssertEqual(backend.inputCount, 1)
        _ = try call(paths, session: session, op: "disconnect")
        wait(for: [finished], timeout: 3)
    }
}
