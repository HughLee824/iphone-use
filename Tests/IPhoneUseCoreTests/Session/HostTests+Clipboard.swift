import XCTest
import Foundation
import Network
@testable import IPhoneUseCore

extension HostTests {

    func testTouchPastePrewriteFailureDoesNotBlockHostActionsInEitherMode() throws {
        for native in [true, false] {
            let backend = ControlledBackend(); backend.nativeTextFixture = native
            let pasteboardIO = TouchPasteTestIO(); pasteboardIO.failSnapshotAt = 1
            let clipboard = TouchPasteSession { .init(pasteboardIO: pasteboardIO, close: { true }) }
            let running = try host(
                timeout: 5, backend: backend, native: native, touchPaste: clipboard)
            let paths = running.paths, session = running.session, finished = running.finished
            defer {
                _ = try? call(paths, session: session, op: "disconnect"); wait(for: [finished], timeout: 3)
            }
            _ = try call(paths, session: session, op: "observe")
            let stage = try call(
                paths, session: session, op: "type-with-method",
                fields: ["reference": "o1", "mode": "insert", "textMethod": "touch-paste", "text": "中文"])
            XCTAssertEqual(stage["outcome"] as? String, "not_dispatched")
            let result = try XCTUnwrap(stage["result"] as? [String: Any])
            let appleError = result["applePasteboardError"] as? [String: Any]
            XCTAssertEqual(appleError?["code"] as? Int, 26006)
            XCTAssertFalse(String(describing: stage).contains("private clipboard text"))
            XCTAssertEqual(pasteboardIO.writes, 0)
            XCTAssertEqual(backend.inputCount, 0)
            let refreshed = try call(paths, session: session, op: "observe")
            let reference =
                (try XCTUnwrap(
                    ((try XCTUnwrap(refreshed["result"] as? [String: Any])))["observation"] as? String))
            let tap = try call(
                paths, session: session, op: "tap", fields: ["reference": reference, "x": 100, "y": 200])
            XCTAssertEqual(tap["ok"] as? Bool, true)
            let observed = try call(paths, session: session, op: "observe")
            let current =
                (try XCTUnwrap(
                    ((try XCTUnwrap(observed["result"] as? [String: Any])))["observation"] as? String))
            let typed = try call(
                paths, session: session, op: "type",
                fields: ["reference": native ? current : "\(current):e27", "mode": "insert", "text": "test"])
            XCTAssertEqual(typed["ok"] as? Bool, true)
            let opened = try call(
                paths, session: session, op: "open", fields: ["bundleId": "com.example.fixture"])
            XCTAssertEqual(opened["ok"] as? Bool, true)
            XCTAssertEqual(pasteboardIO.writes, 0)
        }
    }

    func testTouchPasteCaptureFailureRetainsTransactionAndDisconnectRestores() throws {
        for native in [true, false] {
            let backend = ControlledBackend(); backend.nativeTextFixture = native
            let pasteboardIO = TouchPasteTestIO(), original = pasteboardIO.items
            let clipboard = TouchPasteSession { .init(pasteboardIO: pasteboardIO, close: { true }) }
            let running = try host(
                timeout: 5, backend: backend, native: native, touchPaste: clipboard)
            let paths = running.paths, session = running.session, finished = running.finished
            _ = try call(paths, session: session, op: "observe")
            backend.failObservation = true
            let stage = try call(
                paths, session: session, op: "type-with-method",
                fields: ["reference": "o1", "mode": "insert", "textMethod": "touch-paste", "text": "中文"])
            XCTAssertEqual(stage["ok"] as? Bool, false)
            XCTAssertEqual(stage["outcome"] as? String, "prepared")
            XCTAssertEqual(
                (stage["error"] as? [String: Any])?["code"] as? String, "touch_paste_observation_failed")
            XCTAssertEqual(pasteboardIO.writes, 1)
            XCTAssertEqual(backend.inputCount, 0)
            let stop = try call(paths, session: session, op: "disconnect")
            wait(for: [finished], timeout: 3)
            XCTAssertEqual(stop["ok"] as? Bool, true)
            XCTAssertEqual(pasteboardIO.items, original)
        }
    }

    func testTouchPasteUncertainWriteAndCaptureFailurePreserveOriginalError() throws {
        for native in [true, false] {
            let backend = ControlledBackend(); backend.nativeTextFixture = native
            let pasteboardIO = TouchPasteTestIO(); pasteboardIO.failWrite = true
            let clipboard = TouchPasteSession { .init(pasteboardIO: pasteboardIO, close: { true }) }
            let running = try host(
                timeout: 5, backend: backend, native: native, touchPaste: clipboard)
            let paths = running.paths, session = running.session, finished = running.finished
            defer {
                _ = try? call(paths, session: session, op: "disconnect"); wait(for: [finished], timeout: 3)
            }
            _ = try call(paths, session: session, op: "observe")
            backend.failObservation = true
            let stage = try call(
                paths, session: session, op: "type-with-method",
                fields: ["reference": "o1", "mode": "insert", "textMethod": "touch-paste", "text": "中文"])
            XCTAssertEqual(stage["ok"] as? Bool, false)
            XCTAssertEqual(stage["outcome"] as? String, "unknown")
            XCTAssertEqual((stage["error"] as? [String: Any])?["code"] as? String, "touch_paste_stage_failed")
            XCTAssertEqual((stage["observation"] as? [String: Any])?["ok"] as? Bool, false)
            XCTAssertEqual(pasteboardIO.writes, 1)
            XCTAssertEqual(backend.inputCount, 0)
        }
    }

    func testTouchPasteDoesNotMixWithNativeClipboardOrPasteForeignContent() throws {
        let backend = ControlledBackend(); backend.nativeTextFixture = true
        let pasteboardIO = TouchPasteTestIO()
        let clipboard = TouchPasteSession { .init(pasteboardIO: pasteboardIO, close: { true }) }
        let running = try host(timeout: 5, backend: backend, native: true, touchPaste: clipboard)
        let paths = running.paths, session = running.session, finished = running.finished
        defer { _ = try? call(paths, session: session, op: "disconnect"); wait(for: [finished], timeout: 3) }
        _ = try call(paths, session: session, op: "observe")
        let fields: [String: Any] = [
            "reference": "o1", "mode": "insert", "textMethod": "touch-paste", "text": "中文"
        ]
        backend.statusInfo = ["pasteboard": ["restorePending": true]]
        let rejected = try call(paths, session: session, op: "type-with-method", fields: fields)
        XCTAssertEqual((rejected["error"] as? [String: Any])?["code"] as? String, "native_pasteboard_pending")
        XCTAssertEqual(pasteboardIO.writes, 0)
        backend.statusInfo = nil
        _ = try call(paths, session: session, op: "type-with-method", fields: fields)
        pasteboardIO.count += 1
        let tap = try call(
            paths, session: session, op: "tap", fields: ["reference": "o2", "x": 100, "y": 200])
        XCTAssertEqual((tap["error"] as? [String: Any])?["code"] as? String, "native_pasteboard_changed")
        XCTAssertEqual(backend.inputCount, 0)
    }

    func testHostReportsFixedModeForStatusActionsRejectionsAndDisconnect() throws {
        for native in [true, false] {
            let backend = ControlledBackend()
            let running = try host(timeout: 5, backend: backend, native: native)
            let paths = running.paths, session = running.session, finished = running.finished
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
        let running = try host(timeout: 5, backend: backend)
        let paths = running.paths, session = running.session, finished = running.finished
        for _ in 0..<3 {
            let response = try call(paths, session: session, op: "status")
            XCTAssertEqual(
                (response["result"] as? [String: Any])?["runnerSession"] as? String, "controlled-runner")
        }
        XCTAssertEqual(try call(paths, session: session, op: "disconnect")["ok"] as? Bool, true)
        wait(for: [finished], timeout: 3)
        XCTAssertEqual(backend.stopCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.socket))
        XCTAssertThrowsError(try call(paths, session: session, op: "status"))
    }

    func testDisconnectCancelsPendingStartupAndCleansOwnedHost() throws {
        let backend = ControlledBackend(); backend.blockStart = true
        let running = try host(timeout: 5, backend: backend)
        let paths = running.paths, session = running.session, finished = running.finished
        let response = try call(paths, session: session, op: "disconnect")
        XCTAssertEqual(response["ok"] as? Bool, true)
        wait(for: [finished], timeout: 3)
        XCTAssertEqual(backend.stopCount, 1)
        XCTAssertEqual(backend.inputCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.socket))
    }

    func testNativeExitUsesFinalAvailabilityInsteadOfStartupSnapshot() throws {
        let backend = ControlledBackend()
        backend.statusInfo = [
            "controlAvailable": false, "capabilities": ["tap": false], "media": ["rtpPackets": 37]
        ]
        let running = try host(timeout: 5, backend: backend, native: true)
        let paths = running.paths, session = running.session, finished = running.finished
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
        let running = try host(timeout: 5, backend: backend)
        let paths = running.paths, session = running.session, finished = running.finished
        _ = try call(paths, session: session, op: "observe")
        let response = try call(
            paths, session: session, op: "swipe",
            fields: [
                "reference": "o1",
                "fromX": 100, "fromY": 600, "toX": 100, "toY": 200, "velocity": 1
            ])
        XCTAssertEqual(response["outcome"] as? String, "not_dispatched")
        XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? String, "swipe_duration_exceeded")
        XCTAssertEqual(backend.actionCount, 0)
        XCTAssertEqual(backend.inputCount, 0)
        let tap = try call(
            paths, session: session, op: "tap", fields: ["reference": "o1", "x": 100, "y": 600])
        XCTAssertEqual(tap["outcome"] as? String, "completed")
        XCTAssertEqual(backend.inputCount, 1)
        _ = try call(paths, session: session, op: "disconnect")
        wait(for: [finished], timeout: 3)
    }
}
