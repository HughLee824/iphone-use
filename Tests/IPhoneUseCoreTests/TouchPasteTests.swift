import XCTest
@testable import IPhoneUseCore

final class TouchPasteTestIO: NativeTextPasteboard.PasteboardAccess {
    var items = [NativeTextPasteboard.Item(flavors: ["public.text": Data("original".utf8)])]
    var count = 1
    var writes = 0
    var failWrite = false
    var failSnapshotAt: Int?
    var snapshots = 0
    var failRead = false
    var changeOnRead = false
    func snapshot() throws -> NativeTextPasteboard.Snapshot {
        snapshots += 1
        if snapshots == failSnapshotAt {
            _ = try AppleTextPasteboardIO.snapshotReply(
                [
                    "error": [
                        "domain": "com.apple.dt.CoreDeviceError", "code": 26006,
                        "userInfo": ["NSLocalizedDescription": "private clipboard text"]
                    ]
                ], command: "PULL_REPLY")
        }
        return .init(changeCount: count, nonce: "test")
    }
    func read() throws -> [NativeTextPasteboard.Item] {
        if failRead { throw TransportError(description: "Read timed out", possiblySent: true) }
        if changeOnRead { count += 1 }
        return items
    }
    func write(_ items: [NativeTextPasteboard.Item], cleanup: Bool) throws {
        self.items = items; count += 1; writes += 1
        if failWrite { throw TransportError(description: "Lost reply", possiblySent: true) }
    }
}

final class TouchPasteTests: XCTestCase {
    func testPrewriteFailuresReleasePendingAndConnectionWithoutReplay() throws {
        for failure in ["snapshot", "read", "verify", "changed"] {
            let pasteboardIO = TouchPasteTestIO(), original = pasteboardIO.items
            pasteboardIO.failSnapshotAt = failure == "snapshot" ? 1 : failure == "verify" ? 2 : nil
            pasteboardIO.failRead = failure == "read"
            pasteboardIO.changeOnRead = failure == "changed"
            var opens = 0, closes = 0
            let session = TouchPasteSession {
                opens += 1
                return .init(
                    pasteboardIO: pasteboardIO,
                    close: {
                        closes += 1; return true
                    })
            }
            XCTAssertThrowsError(try session.stage("payload", observation: "o1")) {
                let error = $0 as? ActionFailure
                XCTAssertEqual(error?.possiblyExecuted, false)
                let status = error?.result?["pasteboard"] as? [String: Any]
                XCTAssertEqual(status?["restorePending"] as? Bool, false)
                XCTAssertEqual(status?["writeUncertain"] as? Bool, false)
                XCTAssertNotNil(status?["preparationPhase"])
                XCTAssertNil(status?["transactionID"])
            }
            XCTAssertFalse(session.pending, failure)
            XCTAssertEqual(closes, 1)
            XCTAssertEqual(opens, 1)
            XCTAssertEqual(pasteboardIO.writes, 0)
            XCTAssertEqual(pasteboardIO.items, original)
            XCTAssertNoThrow(try session.checkOwnership())
            pasteboardIO.failSnapshotAt = nil; pasteboardIO.failRead = false
            pasteboardIO.changeOnRead = false
            _ = try session.stage("explicit next request", observation: "o2")
            XCTAssertEqual(opens, 2)
            XCTAssertTrue(session.pending)
            XCTAssertEqual(pasteboardIO.writes, 1)
            XCTAssertEqual(session.close()["pasteboardRestoreAcknowledged"] as? Bool, true)
            XCTAssertEqual(pasteboardIO.items, original)
            XCTAssertEqual(closes, 2)
        }
    }

    func testPostwriteVerificationAndOwnershipFailuresKeepPending() throws {
        for failAt in [3, 5] {
            let pasteboardIO = TouchPasteTestIO()
            pasteboardIO.failSnapshotAt = failAt
            var closes = 0
            let session = TouchPasteSession {
                .init(
                    pasteboardIO: pasteboardIO,
                    close: {
                        closes += 1; return true
                    })
            }
            XCTAssertThrowsError(try session.stage("payload", observation: "o1"))
            XCTAssertTrue(session.pending)
            XCTAssertNotNil(session.status["transactionID"])
            XCTAssertEqual(pasteboardIO.writes, 1)
            XCTAssertEqual(closes, 0)
            XCTAssertThrowsError(try session.stage("again", observation: "o2"))
            XCTAssertEqual(pasteboardIO.writes, 1)
            let result = session.close()
            XCTAssertEqual(result["pasteboardRestoreAcknowledged"] as? Bool, failAt == 5)
            XCTAssertEqual(pasteboardIO.writes, failAt == 5 ? 2 : 1)
        }
    }

    func testBothModesAcceptOnlyExplicitStagingWithScreenshotAndLiteralText() throws {
        for native in [true, false] {
            let request: [String: Any] = [
                "reference": "o1", "mode": "insert", "textMethod": "touch-paste", "text": "中文\r\nEnglish 🙂"
            ]
            XCTAssertTrue(
                try DeviceAction(operation: "type", request: request, allowScreenText: native).touchPaste)
            for change: [String: Any] in [
                ["mode": "replace"], ["mode": "append"], ["text": ""], ["text": "\t"],
                ["text": String(repeating: "a", count: 4097)], ["reference": "o1:e1"],
                ["fieldRect": "1,2,100,40"], ["caretRect": "1,2,2,20"], ["x": 1, "y": 2]
            ] {
                XCTAssertThrowsError(
                    try DeviceAction(
                        operation: "type", request: request.merging(change) { _, new in new },
                        allowScreenText: native))
            }
        }
    }

    func testStageIsLazyDoesNotClaimInputAndRestoresOnlyAfterNewObservation() throws {
        let pasteboardIO = TouchPasteTestIO(), original = pasteboardIO.items
        var opens = 0, closes = 0
        let session = TouchPasteSession {
            opens += 1
            return .init(
                pasteboardIO: pasteboardIO,
                close: {
                    closes += 1; return true
                })
        }
        XCTAssertEqual(opens, 0)
        let before = ProcessInfo.processInfo.systemUptime
        let result = try session.stage("中英\nEnglish", observation: "o1")
        XCTAssertEqual(result["phase"] as? String, "awaiting_touch_paste")
        XCTAssertEqual(result["textInserted"] as? Bool, false)
        XCTAssertEqual(result["inputReportsSent"] as? Int, 0)
        XCTAssertTrue(session.pending)
        XCTAssertEqual(pasteboardIO.writes, 1)
        XCTAssertThrowsError(try session.stage("duplicate", observation: "o2"))
        let token = (try XCTUnwrap(session.status["transactionID"] as? String))
        XCTAssertThrowsError(try session.finish(transaction: token, observedAt: before))
        XCTAssertThrowsError(
            try session.finish(
                transaction: UUID().uuidString, observedAt: ProcessInfo.processInfo.systemUptime))
        XCTAssertEqual(pasteboardIO.writes, 1)
        XCTAssertEqual(
            try session.finish(transaction: token, observedAt: ProcessInfo.processInfo.systemUptime)[
                "pasteboardRestoreAcknowledged"] as? Bool, true)
        XCTAssertEqual(pasteboardIO.items, original)
        _ = try session.stage("second", observation: "o3")
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(session.close()["pasteboardRestoreAcknowledged"] as? Bool, true)
        XCTAssertEqual(pasteboardIO.items, original)
        XCTAssertEqual(closes, 1)
    }

    func testForeignClipboardAndUncertainWritesAreNeverOverwrittenOrReplayed() throws {
        for uncertain in [true, false] {
            let pasteboardIO = TouchPasteTestIO()
            let session = TouchPasteSession { .init(pasteboardIO: pasteboardIO, close: { true }) }
            if uncertain {
                pasteboardIO.failWrite = true
                XCTAssertThrowsError(try session.stage("payload", observation: "o1")) {
                    XCTAssertTrue(($0 as? ActionFailure)?.possiblyExecuted == true)
                }
            } else {
                _ = try session.stage("payload", observation: "o1")
                pasteboardIO.items = [.init(flavors: ["public.text": Data("external writer".utf8)])]
                pasteboardIO.count += 1
            }
            let current = pasteboardIO.items, writes = pasteboardIO.writes
            XCTAssertThrowsError(try session.checkOwnership())
            XCTAssertThrowsError(try session.stage("again", observation: "o2"))
            XCTAssertEqual(session.close()["pasteboardRestoreAcknowledged"] as? Bool, false)
            _ = session.close()
            XCTAssertEqual(pasteboardIO.items, current)
            XCTAssertEqual(pasteboardIO.writes, writes)
        }
    }
}
