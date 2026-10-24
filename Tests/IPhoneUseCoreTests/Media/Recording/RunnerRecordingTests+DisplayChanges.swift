import XCTest
@testable import IPhoneUseCore

extension RunnerRecordingTests {

    func testDisplayChangeEndsOnlyOwnRecordingAndReleasesMedia() throws {
        let connection = RunnerRecordingConnectionStub()
        let owner = RunnerNativeRecording(root: try root(), cancellation: NativeCancellation()) { connection }
        defer { _ = owner.close() }
        _ = try owner.start(duration: 30)
        connection.changed = true
        owner.checkDisplay()
        XCTAssertEqual(connection.closed, 1); XCTAssertFalse(connection.receiver.attached)
        XCTAssertEqual(owner.status()["mediaConnectionOpen"] as? Bool, false)
    }

    func testUnconfirmedCleanupPreservesFactsAndBlocksNewStart() throws {
        let connection = RunnerRecordingConnectionStub(); connection.acknowledged = false
        let owner = RunnerNativeRecording(root: try root(), cancellation: NativeCancellation()) { connection }
        let started = try owner.start(duration: 30)
        XCTAssertThrowsError(try owner.stop(id: (try XCTUnwrap(started["recordingID"] as? String)))) {
            XCTAssertEqual(($0 as? ActionFailure)?.possiblyExecuted, true)
            XCTAssertNotNil(($0 as? ActionFailure)?.result?["mediaCleanup"])
        }
        XCTAssertThrowsError(try owner.start(duration: 30))
        XCTAssertEqual(owner.close()["recordingCleanupAcknowledged"] as? Bool, false)
        XCTAssertEqual(connection.closed, 1)
    }

    func testPreviewAndRecordingRetainOneConnectionInEitherStopOrder() throws {
        for stopPreviewFirst in [false, true] {
            var starts = 0
            let connection = RunnerRecordingConnectionStub()
            let owner = RunnerNativeRecording(root: try root(), cancellation: NativeCancellation()) {
                starts += 1; return connection
            }
            defer { _ = owner.close() }
            let preview = try owner.startPreview(options: .init(port: 0))
            XCTAssertNotNil(preview["url"])
            XCTAssertEqual((preview["device"] as? [String: Any])?["productType"] as? String, "iPhone13,3")
            XCTAssertEqual((preview["bezel"] as? [String: Any])?["name"] as? String, "iPhone 12 Pro")
            let recording = try owner.start(duration: 30)
            XCTAssertEqual(starts, 1)
            XCTAssertEqual(connection.previewRefreshes, 0)
            if stopPreviewFirst {
                _ = try owner.stopPreview()
                XCTAssertEqual(connection.closed, 0)
                XCTAssertFalse(
                    connection.receiver.attached,
                    "Preview recordings subscribe to decoded frames, not a new packet decoder")
                _ = try owner.stop(id: (try XCTUnwrap(recording["recordingID"] as? String)))
            } else {
                _ = try owner.stop(id: (try XCTUnwrap(recording["recordingID"] as? String)))
                XCTAssertEqual(connection.closed, 0)
                XCTAssertEqual(owner.previewStatus["url"] as? String, preview["url"] as? String)
                _ = try owner.stopPreview()
            }
            XCTAssertEqual(connection.closed, 1)
        }
    }

    func testUnconfirmedRecordingClockPreservesOnlyHealthyExistingPreview() throws {
        for (withPreview, healthy) in [(true, true), (true, false), (false, true)] {
            let connection = RunnerRecordingConnectionStub()
            var opens = 0
            let owner = RunnerNativeRecording(root: try root(), cancellation: NativeCancellation()) {
                opens += 1; return connection
            }
            defer { _ = owner.close() }
            let preview = withPreview ? try owner.startPreview(options: .init(port: 0)) : nil
            connection.receiver.clockConfirmed = false
            connection.receiver.healthy = healthy
            XCTAssertThrowsError(try owner.start(duration: 30)) {
                XCTAssertEqual(($0 as? IPhoneUseError)?.code, "native_recording_format_unavailable")
            }
            XCTAssertFalse(connection.receiver.attached, "No writer or packet subscription was started")
            XCTAssertEqual(opens, 1, "Rejected starts never reconnect automatically")
            if withPreview && healthy {
                XCTAssertEqual(connection.closed, 0)
                XCTAssertEqual(owner.previewStatus["url"] as? String, preview?["url"] as? String)
                XCTAssertNil(owner.status()["reconnectRequired"])
                XCTAssertEqual(owner.status()["state"] as? String, "idle")
                connection.receiver.clockConfirmed = true
                let started = try owner.start(duration: 30)
                XCTAssertEqual(opens, 1)
                _ = try owner.stop(id: XCTUnwrap(started["recordingID"] as? String))
                XCTAssertEqual(connection.closed, 0)
            } else {
                XCTAssertEqual(connection.closed, 1)
                XCTAssertEqual(owner.status()["reconnectRequired"] as? Bool, true)
                XCTAssertThrowsError(try owner.start(duration: 30))
                XCTAssertEqual(opens, 1)
            }
        }
    }

    func testPreviewRotationEndsRecordingAndDoesNotReplayFailedRefresh() throws {
        for fail in [false, true] {
            let connection = RunnerRecordingConnectionStub()
            let owner = RunnerNativeRecording(root: try root(), cancellation: NativeCancellation()) {
                connection
            }
            defer { _ = owner.close() }
            _ = try owner.startPreview(options: .init(port: 0))
            _ = try owner.start(duration: 30)
            connection.changed = true; connection.failRefresh = fail
            XCTAssertTrue(owner.previewTick())
            XCTAssertEqual(connection.previewRefreshes, 1)
            XCTAssertFalse(connection.receiver.attached)
            XCTAssertEqual(connection.closed, fail ? 1 : 0)
            _ = owner.previewTick()
            XCTAssertEqual(connection.previewRefreshes, 1)
            if fail { XCTAssertThrowsError(try owner.startPreview(options: .init(port: 0))) }
        }
    }

    func testRunnerUnknownProductTypeDoesNotBorrowMatchingNameOrGeometry() throws {
        let connection = RunnerRecordingConnectionStub()
        connection.previewDevice = NativePreviewDevice(productType: "iPhone99,1", name: "iPhone 12 Pro")
        let owner = RunnerNativeRecording(root: try root(), cancellation: NativeCancellation()) { connection }
        defer { _ = owner.close() }
        let preview = try owner.startPreview(options: .init(port: 0))
        XCTAssertTrue(preview["bezel"] is NSNull)
        XCTAssertEqual((preview["device"] as? [String: Any])?["productType"] as? String, "iPhone99,1")
    }

    func testIndependentGeometryRecoversStaleCoreDeviceAxesAndPreservesQuietRecording() throws {
        for (initial, next, orientation) in [
            ("rot0", "rot270", 8), ("rot270", "rot0", 1), ("rot90", "rot270", 8), ("rot270", "rot90", 6)
        ] {
            let connection = RunnerRecordingConnectionStub()
            connection.rotation = initial
            var geometry = RunnerPreviewGeometry(
                width: 32, height: 48, orientation: ["rot0": 1, "rot90": 6, "rot270": 8][initial]!)
            let owner = RunnerNativeRecording(
                root: try root(), cancellation: NativeCancellation(),
                previewGeometry: { geometry }, connect: { connection })
            defer { _ = owner.close() }
            let preview = try owner.startPreview(options: .init(port: 0))
            _ = try owner.start(duration: 30)
            for _ in 0..<3 { XCTAssertFalse(owner.previewTick()) }
            XCTAssertEqual(connection.previewRefreshes, 0, "A quiet stream is not a rotation conflict")
            XCTAssertEqual(owner.status()["state"] as? String, "waiting_for_frame")
            // Both CoreDevice checks still agree with the OLD rotation.
            XCTAssertFalse(connection.changed)
            geometry = RunnerPreviewGeometry(width: 32, height: 48, orientation: orientation)
            connection.refreshedRotation = next
            XCTAssertTrue(owner.previewTick())
            XCTAssertEqual(connection.previewRefreshes, 1)
            XCTAssertEqual(connection.closed, 0)
            XCTAssertEqual(owner.previewStatus["independentOrientationConflicts"] as? Int, 1)
            XCTAssertEqual(owner.status()["stopReason"] as? String, "display_changed")
            XCTAssertEqual(owner.previewStatus["url"] as? String, preview["url"] as? String)
            XCTAssertFalse(owner.previewTick())
            XCTAssertEqual(connection.previewRefreshes, 1)
        }
    }

    func testUnresolvedIndependentConflictStopsInsteadOfLoopingRefresh() throws {
        let connection = RunnerRecordingConnectionStub()
        let owner = RunnerNativeRecording(
            root: try root(), cancellation: NativeCancellation(),
            previewGeometry: { RunnerPreviewGeometry(width: 32, height: 48, orientation: 8) },
            connect: { connection })
        defer { _ = owner.close() }
        _ = try owner.startPreview(options: .init(port: 0))
        XCTAssertTrue(owner.previewTick())
        XCTAssertEqual(connection.previewRefreshes, 1)
        XCTAssertEqual(connection.closed, 1)
        XCTAssertFalse(owner.previewTick())
        XCTAssertThrowsError(try owner.startPreview(options: .init(port: 0)))
        XCTAssertEqual(connection.previewRefreshes, 1)
    }

    func testIndependentGeometryRejectsMissingFailedOrInvalidReplies() throws {
        for response: [String: Any] in [
            [:], ["ok": false, "result": ["width": 32, "height": 48, "orientation": 1]],
            ["ok": true, "result": ["width": 0, "height": 48, "orientation": 1]],
            ["ok": true, "result": ["width": 32, "height": 16385, "orientation": 1]],
            ["ok": true, "result": ["width": 32, "height": 48]],
            ["ok": true, "result": ["width": 32, "height": 48, "orientation": 2]]
        ] {
            XCTAssertThrowsError(try XCTestBackend.decodePreviewGeometry(response))
        }
        let size = try XCTestBackend.decodePreviewGeometry([
            "ok": true, "result": ["width": 1170, "height": 2532, "orientation": 1]
        ])
        XCTAssertEqual(size.width, 1170); XCTAssertEqual(size.height, 2532)
    }

    func testBakedLandscapePixelsDoNotImplyPortraitFromUprightTag() throws {
        let connection = RunnerRecordingConnectionStub()
        connection.rotation = "rot270"
        let display = try XCTUnwrap(connection.previewDisplay)
        XCTAssertFalse(RunnerPreviewGeometry(width: 48, height: 32, orientation: 1).conflicts(with: display))
        XCTAssertFalse(RunnerPreviewGeometry(width: 32, height: 48, orientation: 8).conflicts(with: display))
        XCTAssertTrue(RunnerPreviewGeometry(width: 32, height: 48, orientation: 6).conflicts(with: display))
    }
}
