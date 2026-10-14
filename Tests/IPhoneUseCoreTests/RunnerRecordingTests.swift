import XCTest
@testable import IPhoneUseCore

private final class RunnerRecordingSourceStub: NativeRecordingSource {
    var attached = false
    var clockConfirmed = true
    var healthy = true
    func recordingConfiguration() -> [String: Any] {
        var config: [String: Any] = ["RxPayloadType": 100, "TilesPerFrame": 1, "SRTPCipherSuite": 0]
        if clockConfirmed { config["RTPClockRate"] = Int32(24000) }
        return config
    }
    func setVideoHandler(_ handler: ((Data) -> Void)?) { attached = handler != nil }
    func requestKeyframe() {}
    func health() -> [String: Any] { ["healthy": healthy] }
}

private final class RunnerRecordingConnectionStub: RunnerRecordingConnection {
    let receiver = RunnerRecordingSourceStub()
    var source: NativeRecordingSource { receiver }
    let sessionID = UUID().uuidString
    var rotation = "rot0"
    var refreshedRotation: String?
    var closed = 0
    var changed = false
    var acknowledged = true
    var previewDevice = NativePreviewDevice(productType: "iPhone13,3", name: "iPhone 12 Pro")
    var previewRefreshes = 0
    var failRefresh = false
    func previewNeedsRefresh() throws -> Bool { changed }
    func refreshPreview() throws {
        previewRefreshes += 1
        if failRefresh { throw TransportError(description: "Lost scoped refresh reply", possiblySent: true) }
        if let refreshedRotation { rotation = refreshedRotation }
        changed = false
    }
    private lazy var previewVideo = try? NativeRTPReceiver(deviceAddress: "::1", captureSnapshots: true)
    var previewReceiver: NativeRTPReceiver? { previewVideo }
    var previewDisplay: NativeDisplay? {
        try? NativeDisplay(["backlightState": "activeOn", "displays": [["primary": true, "displayId": 1,
            "bounds": [[0,0],[32,48]], "pointScale": 1, "currentOrientation": rotation, "nativeOrientation": "rot0"]]])
    }
    func verifyDisplay() throws { if changed { throw IPhoneUseError("display_changed", "Fixture rotated") } }
    func close() -> [String: Any] {
        closed += 1
        return ["mediaStopAcknowledged": acknowledged, "tunnelReleaseAcknowledged": true, "mediaSessionID": sessionID]
    }
}

final class RunnerRecordingTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runner-recording-\(UUID().uuidString)")
        try SessionPaths.secureDirectory(root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testInvalidBusyForeignAndOldIDsCannotCreateOrCloseAnotherStream() throws {
        var connections: [RunnerRecordingConnectionStub] = []
        let owner = RunnerNativeRecording(root: try root(), cancellation: NativeCancellation()) {
            let connection = RunnerRecordingConnectionStub(); connections.append(connection); return connection
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
        XCTAssertEqual((old["mediaCleanup"] as? [String: Any])?["mediaSessionID"] as? String, connections[0].sessionID)
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
        XCTAssertThrowsError(try owner.stop(id: started["recordingID"] as! String)) {
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
            let owner = RunnerNativeRecording(root: try root(), cancellation: NativeCancellation()) { starts += 1; return connection }
            defer { _ = owner.close() }
            let preview = try owner.startPreview()
            XCTAssertNotNil(preview["url"])
            XCTAssertEqual((preview["device"] as? [String: Any])?["productType"] as? String, "iPhone13,3")
            XCTAssertEqual((preview["bezel"] as? [String: Any])?["name"] as? String, "iPhone 12 Pro")
            let recording = try owner.start(duration: 30)
            XCTAssertEqual(starts, 1)
            XCTAssertEqual(connection.previewRefreshes, 0)
            if stopPreviewFirst {
                _ = try owner.stopPreview()
                XCTAssertEqual(connection.closed, 0)
                XCTAssertFalse(connection.receiver.attached, "Preview recordings subscribe to decoded frames, not a new packet decoder")
                _ = try owner.stop(id: recording["recordingID"] as! String)
            } else {
                _ = try owner.stop(id: recording["recordingID"] as! String)
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
            let preview = withPreview ? try owner.startPreview() : nil
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
            let owner = RunnerNativeRecording(root: try root(), cancellation: NativeCancellation()) { connection }
            defer { _ = owner.close() }
            _ = try owner.startPreview()
            _ = try owner.start(duration: 30)
            connection.changed = true; connection.failRefresh = fail
            XCTAssertTrue(owner.previewTick())
            XCTAssertEqual(connection.previewRefreshes, 1)
            XCTAssertFalse(connection.receiver.attached)
            XCTAssertEqual(connection.closed, fail ? 1 : 0)
            _ = owner.previewTick()
            XCTAssertEqual(connection.previewRefreshes, 1)
            if fail { XCTAssertThrowsError(try owner.startPreview()) }
        }
    }

    func testRunnerUnknownProductTypeDoesNotBorrowMatchingNameOrGeometry() throws {
        let connection = RunnerRecordingConnectionStub()
        connection.previewDevice = NativePreviewDevice(productType: "iPhone99,1", name: "iPhone 12 Pro")
        let owner = RunnerNativeRecording(root: try root(), cancellation: NativeCancellation()) { connection }
        defer { _ = owner.close() }
        let preview = try owner.startPreview()
        XCTAssertTrue(preview["bezel"] is NSNull)
        XCTAssertEqual((preview["device"] as? [String: Any])?["productType"] as? String, "iPhone99,1")
    }

    func testIndependentGeometryRecoversStaleCoreDeviceAxesAndPreservesQuietRecording() throws {
        for (initial, next, orientation) in [("rot0", "rot270", 8), ("rot270", "rot0", 1), ("rot90", "rot270", 8), ("rot270", "rot90", 6)] {
            let connection = RunnerRecordingConnectionStub()
            connection.rotation = initial
            var geometry = RunnerPreviewGeometry(width: 32, height: 48, orientation: ["rot0": 1, "rot90": 6, "rot270": 8][initial]!)
            let owner = RunnerNativeRecording(root: try root(), cancellation: NativeCancellation(),
                previewGeometry: { geometry }, connect: { connection })
            defer { _ = owner.close() }
            let preview = try owner.startPreview()
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
        let owner = RunnerNativeRecording(root: try root(), cancellation: NativeCancellation(),
            previewGeometry: { RunnerPreviewGeometry(width: 32, height: 48, orientation: 8) }, connect: { connection })
        defer { _ = owner.close() }
        _ = try owner.startPreview()
        XCTAssertTrue(owner.previewTick())
        XCTAssertEqual(connection.previewRefreshes, 1)
        XCTAssertEqual(connection.closed, 1)
        XCTAssertFalse(owner.previewTick())
        XCTAssertThrowsError(try owner.startPreview())
        XCTAssertEqual(connection.previewRefreshes, 1)
    }

    func testIndependentGeometryRejectsMissingFailedOrInvalidReplies() throws {
        for response: [String: Any] in [[:], ["ok": false, "result": ["width": 32, "height": 48, "orientation": 1]],
            ["ok": true, "result": ["width": 0, "height": 48, "orientation": 1]],
            ["ok": true, "result": ["width": 32, "height": 16385, "orientation": 1]],
            ["ok": true, "result": ["width": 32, "height": 48]],
            ["ok": true, "result": ["width": 32, "height": 48, "orientation": 2]]] {
            XCTAssertThrowsError(try XCTestBackend.decodePreviewGeometry(response))
        }
        let size = try XCTestBackend.decodePreviewGeometry(["ok": true, "result": ["width": 1170, "height": 2532, "orientation": 1]])
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

    func testManifestCopiesBothLayoutsWithoutMutatingSignedProducts() throws {
        let directory = try root(), source = directory.appendingPathComponent("original.xctestrun")
        let destination = directory.appendingPathComponent("session.xctestrun")
        let target: [String: Any] = ["BlueprintName": "IPhoneUseTests", "PreferredScreenCaptureFormat": "screenRecording",
                                    "TestHostPath": "__TESTROOT__/Runner.app", "TestBundlePath": "__TESTHOST__/Tests.xctest"]
        for original: [String: Any] in [["IPhoneUseTests": target], ["TestConfigurations": [["TestTargets": [target, ["BlueprintName": "Unrelated", "PreferredScreenCaptureFormat": "screenRecording"]]]]]] {
            let data = try PropertyListSerialization.data(fromPropertyList: original, format: .xml, options: 0)
            try data.write(to: source)
            try RunnerSessionManifest.prepare(source: source, destination: destination)
            XCTAssertEqual(try Data(contentsOf: source), data)
            let decoded = try XCTUnwrap(try PropertyListSerialization.propertyList(from: Data(contentsOf: destination), format: nil) as? [String: Any])
            let targets = (decoded["TestConfigurations"] as? [[String: Any]])?.first?["TestTargets"] as? [[String: Any]]
            let patched = try XCTUnwrap(decoded["IPhoneUseTests"] as? [String: Any] ?? targets?.first)
            XCTAssertEqual(patched["PreferredScreenCaptureFormat"] as? String, "screenshots")
            XCTAssertEqual(patched["TestHostPath"] as? String, directory.appendingPathComponent("Runner.app").path)
            XCTAssertEqual(patched["TestBundlePath"] as? String, "__TESTHOST__/Tests.xctest")
            if let targets { XCTAssertEqual(targets[1]["PreferredScreenCaptureFormat"] as? String, "screenRecording") }
        }
        try PropertyListSerialization.data(fromPropertyList: ["Unknown": [:]], format: .xml, options: 0).write(to: source)
        XCTAssertThrowsError(try RunnerSessionManifest.prepare(source: source, destination: destination))
    }
}
