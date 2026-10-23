import XCTest
@testable import IPhoneUseCore

extension RunnerRecordingTests {
    func testHealthyPreviewAndRecordingSurvivePollTimeoutsThenResumeChecks() throws {
        let connection = RunnerRecordingConnectionStub()
        let directory = try root()
        let owner = RunnerNativeRecording(
            root: directory.appendingPathComponent("recordings"), cancellation: NativeCancellation()
        ) { connection }
        defer { _ = owner.close() }
        let preview = try owner.startPreview(options: .init(port: 0))
        _ = try owner.start(duration: 30)
        for code in ["coredevice_timeout", "coredevice_initialization_timeout", "coredevice_timeout"] {
            connection.pollError = IPhoneUseError(code, "Fixture read timed out")
            XCTAssertFalse(owner.previewTick())
            XCTAssertEqual(connection.closed, 0)
            XCTAssertEqual(connection.previewRefreshes, 0)
            XCTAssertEqual(owner.previewStatus["url"] as? String, preview["url"] as? String)
        }
        let events = try String(
            contentsOf: directory.appendingPathComponent("preview-events.jsonl"), encoding: .utf8)
        XCTAssertEqual(events.components(separatedBy: "poll_deferred").count - 1, 3)
        connection.pollError = nil
        XCTAssertFalse(owner.previewTick())
        XCTAssertEqual(owner.status()["state"] as? String, "waiting_for_frame")
        connection.changed = true
        XCTAssertTrue(owner.previewTick(), "A later confirmed rotation still refreshes normally")
        XCTAssertEqual(connection.previewRefreshes, 1)
        XCTAssertEqual(connection.closed, 0)
        XCTAssertEqual(owner.previewStatus["url"] as? String, preview["url"] as? String)
    }

    func testTimeoutDoesNotHideUnhealthyMediaOrCancellationAndOtherErrorsRemainTerminal() throws {
        for (code, healthy, cancelled) in [
            ("coredevice_timeout", false, false), ("coredevice_timeout", true, true),
            ("device_locked", true, false), ("capture_unavailable", true, false),
            ("coredevice_failed", true, false), ("coredevice_cancelled", true, false)
        ] {
            let connection = RunnerRecordingConnectionStub(), cancellation = NativeCancellation()
            let owner = RunnerNativeRecording(root: try root(), cancellation: cancellation) { connection }
            defer { _ = owner.close() }
            _ = try owner.startPreview(options: .init(port: 0))
            connection.receiver.healthy = healthy
            connection.pollError = IPhoneUseError(code, "Fixture failure")
            if cancelled { connection.onPoll = { cancellation.cancel() } }
            XCTAssertTrue(owner.previewTick())
            XCTAssertEqual(connection.closed, 1)
            XCTAssertNil(owner.previewStatus["url"])
        }
    }

    func testTimeoutAfterRefreshBeginsCannotBeDeferredOrReplayed() throws {
        let connection = RunnerRecordingConnectionStub()
        let owner = RunnerNativeRecording(root: try root(), cancellation: NativeCancellation()) { connection }
        defer { _ = owner.close() }
        _ = try owner.startPreview(options: .init(port: 0))
        connection.changed = true
        connection.refreshError = IPhoneUseError("coredevice_timeout", "Read after media stop timed out")
        XCTAssertTrue(owner.previewTick())
        XCTAssertEqual(connection.closed, 1)
        XCTAssertEqual(connection.previewRefreshes, 1)
        XCTAssertFalse(owner.previewTick())
        XCTAssertThrowsError(try owner.startPreview(options: .init(port: 0)))
    }

    func testEarlyPreviewStartsMediaBeforeAuthorizationAndReusesItAfterward() throws {
        var starts = 0
        let connection = RunnerRecordingConnectionStub()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = RunnerNativeRecording(
            root: root, cancellation: NativeCancellation(),
            previewDevice: connection.previewDevice
        ) {
            starts += 1; return connection
        }
        defer { _ = owner.close() }
        var authorized = false
        owner.connectionStatus = { ["requiresUserAction": !authorized] }
        let early = try owner.reservePreview(options: NativePreviewOptions(port: 0))
        XCTAssertEqual(starts, 0)
        XCTAssertEqual((early["device"] as? [String: Any])?["productType"] as? String, "iPhone13,3")
        let bezel = try XCTUnwrap(early["bezel"] as? [String: Any])
        XCTAssertEqual(bezel["name"] as? String, "iPhone 12 Pro")
        XCTAssertEqual((early["connection"] as? [String: Any])?["requiresUserAction"] as? Bool, true)
        let waiting = try owner.startPreview(options: NativePreviewOptions(port: 0), duringStartup: true)
        XCTAssertEqual(starts, 1, "Video must start while Runner authorization is still pending")
        XCTAssertEqual((waiting["connection"] as? [String: Any])?["requiresUserAction"] as? Bool, true)
        XCTAssertEqual(waiting["url"] as? String, early["url"] as? String)
        authorized = true
        let live = try owner.startPreview(options: NativePreviewOptions(port: 0))
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(live["url"] as? String, early["url"] as? String)
        XCTAssertEqual(live["device"] as? NSDictionary, early["device"] as? NSDictionary)
        XCTAssertEqual(live["bezel"] as? NSDictionary, bezel as NSDictionary)
        XCTAssertEqual(connection.closed, 0, "Authorization completion must not replace the media connection")
        XCTAssertEqual((live["connection"] as? [String: Any])?["requiresUserAction"] as? Bool, false)
        _ = try owner.stopPreview()
        XCTAssertEqual(connection.closed, 1)
    }

    func testStartupMediaFailureKeepsAuthorizationPageAndDoesNotRetry() throws {
        var starts = 0
        let owner = RunnerNativeRecording(
            root: try root(), cancellation: NativeCancellation(),
            previewDevice: .init(productType: "iPhone13,3", name: "iPhone 12 Pro")
        ) {
            starts += 1
            throw IPhoneUseError("native_media_busy", "Media unavailable")
        }
        defer { _ = owner.close() }
        var phase = "starting"
        owner.connectionStatus = { ["phase": phase, "requiresUserAction": phase == "starting"] }
        let early = try owner.reservePreview(options: .init(port: 0))
        let failed = try owner.startPreview(options: .init(port: 0), duringStartup: true)
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(failed["url"] as? String, early["url"] as? String)
        XCTAssertNotNil(failed["error"] as? String)
        XCTAssertEqual((failed["bezel"] as? [String: Any])?["name"] as? String, "iPhone 12 Pro")
        phase = "ready"
        XCTAssertEqual((owner.previewStatus["connection"] as? [String: Any])?["phase"] as? String, "ready")
        XCTAssertThrowsError(try owner.startPreview())
        XCTAssertEqual(starts, 1)
    }

    func testPortCollisionDoesNotStartMediaOrPoisonRetryOrInterruptRecording() throws {
        for recordingActive in [false, true] {
            let occupied = try NativePreview(port: 0)
            defer { occupied.close() }
            let port = UInt16(try XCTUnwrap(occupied.status()["port"] as? Int))
            var starts = 0
            let connection = RunnerRecordingConnectionStub()
            let owner = RunnerNativeRecording(root: try root(), cancellation: NativeCancellation()) {
                starts += 1; return connection
            }
            defer { _ = owner.close() }
            if recordingActive { _ = try owner.start(duration: 30) }
            XCTAssertThrowsError(try owner.startPreview(options: .init(port: port, explicitPort: true))) {
                XCTAssertEqual(($0 as? IPhoneUseError)?.code, "preview_port_in_use")
            }
            XCTAssertEqual(starts, recordingActive ? 1 : 0)
            XCTAssertEqual(connection.closed, 0)
            let recovered = try owner.startPreview(options: .init(port: 0))
            XCTAssertNotNil(recovered["url"])
            XCTAssertEqual(starts, 1)
            XCTAssertEqual((recovered["device"] as? [String: Any])?["productType"] as? String, "iPhone13,3")
            XCTAssertEqual(connection.closed, 0)
            XCTAssertEqual(try owner.startPreview()["url"] as? String, recovered["url"] as? String)
            XCTAssertThrowsError(try owner.startPreview(options: .init(port: port, explicitPort: true))) {
                XCTAssertEqual(($0 as? IPhoneUseError)?.code, "preview_already_running")
            }
            XCTAssertEqual(owner.previewStatus["url"] as? String, recovered["url"] as? String)
        }
    }

    func testInvalidBusyForeignAndOldIDsCannotCreateOrCloseAnotherStream() throws {
        var connections: [RunnerRecordingConnectionStub] = []
        let owner = RunnerNativeRecording(root: try root(), cancellation: NativeCancellation()) {
            let connection = RunnerRecordingConnectionStub(); connections.append(connection)
            return connection
        }
        defer { _ = owner.close() }
        XCTAssertEqual(owner.status()["state"] as? String, "idle")
        XCTAssertThrowsError(try owner.start(duration: 0))
        XCTAssertTrue(connections.isEmpty)
        let first = try owner.start(duration: 30), id = try XCTUnwrap(first["recordingID"] as? String)
        XCTAssertThrowsError(try owner.start(duration: 30))
        XCTAssertThrowsError(try owner.stop(id: UUID().uuidString))
        XCTAssertEqual(connections.count, 1); XCTAssertEqual(connections[0].closed, 0)
        let stopped = try owner.stop(id: id)
        XCTAssertEqual(stopped["state"] as? String, "failed") // No fake frames, never claim a movie.
        XCTAssertEqual(connections[0].closed, 1); XCTAssertFalse(connections[0].receiver.attached)
        _ = try owner.start(duration: 30)
        _ = try owner.stop(id: id)
        XCTAssertEqual(connections[1].closed, 0); XCTAssertTrue(connections[1].receiver.attached)
        _ = owner.close(); _ = owner.close()
        XCTAssertEqual(connections[1].closed, 1)
        let old = try owner.stop(id: id)
        XCTAssertEqual(
            (old["mediaCleanup"] as? [String: Any])?["mediaSessionID"] as? String, connections[0].sessionID)
    }

    func testFailedSetupIsNeverReplayedAndCancellationCannotOpenMedia() throws {
        var starts = 0
        let owner = RunnerNativeRecording(root: try root(), cancellation: NativeCancellation()) {
            starts += 1; throw TransportError(description: "Lost start reply", possiblySent: true)
        }
        XCTAssertThrowsError(try owner.start(duration: 10))
        XCTAssertThrowsError(try owner.start(duration: 10))
        XCTAssertEqual(starts, 1); XCTAssertEqual(owner.status()["reconnectRequired"] as? Bool, true)
        _ = owner.close()
        let cancellation = NativeCancellation(); cancellation.cancel()
        let cancelled = RunnerNativeRecording(root: try root(), cancellation: cancellation) {
            XCTFail("Cancelled start must not open a connection"); return RunnerRecordingConnectionStub()
        }
        XCTAssertThrowsError(try cancelled.start(duration: 10)); _ = cancelled.close()
    }
}
