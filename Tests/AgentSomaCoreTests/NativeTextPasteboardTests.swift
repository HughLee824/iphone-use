import XCTest
@testable import AgentSomaCore

private final class PasteboardIO: NativeTextPasteboard.IO {
    var items: [NativeTextPasteboard.Item] = []
    var count = 1
    var nonce = "device"
    var writes = 0
    var failWrite = false
    var ignoreCleanup = false
    var onRead: (() -> Void)?
    var cleanupWrites = 0
    func snapshot() throws -> NativeTextPasteboard.Snapshot { .init(changeCount: count, nonce: nonce) }
    func read() throws -> [NativeTextPasteboard.Item] { let value = items; onRead?(); return value }
    func write(_ value: [NativeTextPasteboard.Item], cleanup: Bool) throws {
        if cleanup && ignoreCleanup { cleanupWrites += 1; return }
        writes += 1; items = value; count += 1
        if cleanup { cleanupWrites += 1 }
        if failWrite { throw SomaError("lost_reply", "Write may have reached device") }
    }
}

private final class PasteboardTransport: NativeTransport {
    var items: [[String: Any]] = []
    var count = 1
    var setCount = 0
    var policies: [String] = []
    var failResolvedRead = false
    func request(_ message: [String: Any], timeout: TimeInterval) throws -> [String: Any] {
        XCTAssertEqual(message["pasteboardName"] as? String, "general")
        let setting = message["command"] as? String == "SET"
        let policy = (message["dataPolicy"] as? [String: Any])?.keys.first
        if let policy { policies.append(policy) }
        if policy == "allResolved", failResolvedRead {
            throw TransportError(description: "Fixture data resolution timed out", possiblySent: true)
        }
        if setting { items = message["items"] as! [[String: Any]]; count += 1; setCount += 1 }
        let returnedItems = setting || policy == "allPromised" ? items.map { ["types": $0["types"]!, "data": [:]] } : items
        return ["command": setting ? "SET_REPLY" : "PULL_REPLY", "pasteboard": ["items": returnedItems,
            "metadata": ["pasteboardName": "general", "changeCount": count, "nonce": "device"]]]
    }
    func send(_ message: [String: Any], timeout: TimeInterval) throws { XCTFail("Clipboard mutations need correlated replies") }
    func cancel() {}
}

final class NativeTextPasteboardTests: XCTestCase {
    func testIdentityQueriesDoNotResolveDataAndBackupStillRequiresAllFlavors() throws {
        let transport = PasteboardTransport()
        let board = NativeTextPasteboard(io: AppleTextPasteboardIO(transport: transport, cancellation: NativeCancellation()))
        try board.stage("test")
        XCTAssertEqual(transport.policies, ["allPromised", "allResolved", "allPromised", "allPromised", "allResolved", "allPromised"])
        XCTAssertEqual(board.status["preparationPhase"] as? String, "ready")
        XCTAssertEqual(board.close()["pasteboardRestoreAcknowledged"] as? Bool, true)
    }

    func testMetadataSuccessButUnresolvedOriginalNeverWritesOrClaimsBackup() throws {
        let transport = PasteboardTransport()
        transport.items = [["types": ["public.text", "public.html"], "data": [:]]]
        transport.failResolvedRead = true
        let board = NativeTextPasteboard(io: AppleTextPasteboardIO(transport: transport, cancellation: NativeCancellation()))
        XCTAssertThrowsError(try board.stage("test"))
        XCTAssertEqual(transport.policies, ["allPromised", "allResolved"])
        XCTAssertEqual(board.status["preparationPhase"] as? String, "read_original")
        XCTAssertEqual(board.status["restorePending"] as? Bool, false)
        XCTAssertEqual(board.status["writeUncertain"] as? Bool, false)
        XCTAssertNil(board.status["transactionID"])
        XCTAssertEqual(board.close()["pasteboardRestoreAcknowledged"] as? Bool, true)
        XCTAssertEqual(transport.setCount, 0)
        XCTAssertEqual(transport.items.count, 1)
    }

    func testExplicitFinishIsBoundToLatestTransactionAndPostInputCapture() throws {
        let io = PasteboardIO(), board = NativeTextPasteboard(io: io)
        let before = ProcessInfo.processInfo.systemUptime
        try board.stage("ASCII", sourceObservationID: "o1")
        let first = board.status["transactionID"] as! String
        try board.stage("ASCII", sourceObservationID: "o3")
        let latest = board.status["transactionID"] as! String
        XCTAssertNotEqual(first, latest)
        XCTAssertEqual(io.writes, 1)
        XCTAssertEqual(board.status["sourceObservationID"] as? String, "o3")
        board.endInputAttempt()
        let after = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try board.finish(transaction: first, observedAt: after))
        XCTAssertThrowsError(try board.finish(transaction: latest, observedAt: before))
        XCTAssertThrowsError(try board.finish(transaction: latest, observedAt: .nan))
        XCTAssertEqual(io.cleanupWrites, 0)
        XCTAssertEqual(try board.finish(transaction: latest, observedAt: after)["pasteboardRestoreAcknowledged"] as? Bool, true)
        _ = try board.finish(transaction: latest, observedAt: after)
        _ = board.close()
        XCTAssertEqual(io.cleanupWrites, 1)
        XCTAssertTrue(board.restored)
        XCTAssertEqual(board.status["restorePending"] as? Bool, false)
        // The next backend transaction uses a fresh manager and fresh backup.
        io.items = [.init(flavors: ["public.text": Data("new original".utf8)])]
        let original = io.items, next = NativeTextPasteboard(io: io)
        try next.stage("next")
        XCTAssertThrowsError(try next.finish(transaction: latest, observedAt: ProcessInfo.processInfo.systemUptime))
        _ = next.close()
        XCTAssertEqual(io.items, original)
    }

    func testExplicitFinishNeverRetriesFailedRestoreOrOverwritesForeignOwner() throws {
        for foreignWriter in [false, true] {
            let io = PasteboardIO(), board = NativeTextPasteboard(io: io)
            try board.stage("中文")
            let token = board.status["transactionID"] as! String
            if foreignWriter { io.count += 1 } else { io.failWrite = true }
            let now = ProcessInfo.processInfo.systemUptime
            XCTAssertEqual(try board.finish(transaction: token, observedAt: now)["pasteboardRestoreAcknowledged"] as? Bool, false)
            _ = try board.finish(transaction: token, observedAt: now)
            _ = board.close()
            XCTAssertEqual(io.cleanupWrites, foreignWriter ? 0 : 1)
            XCTAssertFalse(board.available)
        }
    }

    func testSETReplyWithoutPayloadUsesPullForVerificationAndClearsExactly() throws {
        let transport = PasteboardTransport(), cancellation = NativeCancellation()
        let io = AppleTextPasteboardIO(transport: transport, cancellation: cancellation)
        let board = NativeTextPasteboard(io: io)
        try board.stage("中文，🙂")
        try board.checkOwnership()
        XCTAssertEqual(transport.setCount, 1)
        cancellation.cancel()
        XCTAssertThrowsError(try io.write([], cleanup: false))
        XCTAssertEqual(transport.setCount, 1)
        XCTAssertEqual(board.close()["pasteboardRestoreAcknowledged"] as? Bool, true)
        XCTAssertTrue(transport.items.isEmpty)
        XCTAssertEqual(transport.setCount, 2)
    }
    func testAcknowledgedEmptyWriteWithoutEffectIsNotSuccessfulCleanup() throws {
        let io = PasteboardIO(), board = NativeTextPasteboard(io: io)
        try board.stage("中文")
        io.ignoreCleanup = true
        XCTAssertEqual(board.close()["pasteboardRestoreAcknowledged"] as? Bool, false)
        XCTAssertFalse(io.items.isEmpty)
        XCTAssertEqual(io.cleanupWrites, 1)
    }

    func testRemoteSnapshotPreservesTypesOrderRejectsPromisesAndRedactsErrors() throws {
        let items: [[String: Any]] = [["types": ["public.text", "public.utf8-plain-text"],
            "data": ["public.text": ["data": Data("中文".utf8)], "public.utf8-plain-text": ["data": Data("中文".utf8)]]]]
        let decoded = try AppleTextPasteboardIO.items(["items": items])
        XCTAssertEqual(decoded[0].types, ["public.text", "public.utf8-plain-text"])
        XCTAssertEqual(decoded[0].flavors["public.text"], Data("中文".utf8))
        XCTAssertTrue(try AppleTextPasteboardIO.items(["items": []]).isEmpty)
        XCTAssertThrowsError(try AppleTextPasteboardIO.items(["items": [["types": ["public.text"], "data": ["public.text": ["size": 6]]]]]))
        XCTAssertThrowsError(try AppleTextPasteboardIO.snapshotReply(["error": "private clipboard text"], command: "PULL_REPLY")) {
            XCTAssertFalse(String(describing: $0).contains("private clipboard text"))
        }
    }
    func testUnicodeRoundTripKeepsPayloadUntilCloseAndRestoresEveryOriginalFlavor() throws {
        let io = PasteboardIO()
        let original = [NativeTextPasteboard.Item(flavors: ["public.png": Data([0, 1, 2]), "private.test": Data([255])]),
                        NativeTextPasteboard.Item(flavors: ["public.utf8-plain-text": Data("original".utf8)])]
        io.items = original
        let board = NativeTextPasteboard(io: io)
        try board.stage("中文 A，🙂")
        XCTAssertEqual(io.items.first?.flavors["public.utf8-plain-text"], Data("中文 A，🙂".utf8))
        try board.checkOwnership()
        try board.stage("中文 A，🙂")
        XCTAssertEqual(io.writes, 1) // Checking a staged payload does not write or paste again.
        try board.stage("下一段")
        XCTAssertEqual(io.writes, 2)
        XCTAssertEqual(board.close()["pasteboardRestoreAcknowledged"] as? Bool, true)
        XCTAssertEqual(io.items, original)
        XCTAssertEqual(io.cleanupWrites, 1)
        _ = board.close()
        XCTAssertEqual(io.writes, 3)
        XCTAssertThrowsError(try board.stage("closed"))
    }

    func testConcurrentWriterIsNotRestoredOverEvenWithIdenticalText() throws {
        let io = PasteboardIO(), board = NativeTextPasteboard(io: io)
        try board.stage("中文")
        io.count += 1 // A foreign writer may publish exactly the same bytes.
        XCTAssertThrowsError(try board.checkOwnership())
        XCTAssertThrowsError(try board.stage("中文"))
        let result = board.close()
        XCTAssertEqual(result["pasteboardRestoreAcknowledged"] as? Bool, false)
        XCTAssertEqual(result["pasteboardRestoreSkipped"] as? String, "changed_by_another_client")
        XCTAssertEqual(io.cleanupWrites, 0)
    }

    func testLostWriteReplyDoesNotReplayOrAssumeCleanupOwnership() throws {
        let io = PasteboardIO(), board = NativeTextPasteboard(io: io)
        io.failWrite = true
        XCTAssertThrowsError(try board.stage("中文"))
        XCTAssertThrowsError(try board.stage("中文"))
        XCTAssertThrowsError(try board.checkOwnership())
        XCTAssertEqual(io.writes, 1)
        XCTAssertEqual(board.close()["pasteboardRestoreAcknowledged"] as? Bool, false)
        XCTAssertEqual(io.cleanupWrites, 0)
    }

    func testChangedBackupAndChangedPostWriteReadbackRefuseOwnership() throws {
        let io = PasteboardIO(), board = NativeTextPasteboard(io: io)
        io.onRead = { io.count += 1 }
        XCTAssertThrowsError(try board.stage("中文"))
        XCTAssertEqual(io.writes, 0)
        XCTAssertEqual(board.close()["pasteboardRestoreAcknowledged"] as? Bool, true)

        let second = PasteboardIO(), secondBoard = NativeTextPasteboard(io: second)
        second.onRead = { if second.writes > 0 { second.count += 1 } }
        XCTAssertThrowsError(try secondBoard.stage("中文"))
        XCTAssertEqual(secondBoard.status["writeUncertain"] as? Bool, true)
        XCTAssertEqual(secondBoard.close()["pasteboardRestoreAcknowledged"] as? Bool, false)
        XCTAssertEqual(second.cleanupWrites, 0)
    }

    func testRestoreFailureIsReportedAndNeverRetried() throws {
        let io = PasteboardIO(), board = NativeTextPasteboard(io: io)
        try board.stage("中文")
        io.failWrite = true
        XCTAssertEqual(board.close()["pasteboardRestoreAcknowledged"] as? Bool, false)
        _ = board.close()
        XCTAssertEqual(io.cleanupWrites, 1)
    }
}
