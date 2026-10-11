import XCTest
@testable import IPhoneUseCore

private final class RunnerRecordingSourceStub: NativeRecordingSource {
    var attached = false
    func recordingConfiguration() -> [String: Any] {
        ["RxPayloadType": 100, "TilesPerFrame": 1, "SRTPCipherSuite": 0, "RTPClockRate": Int32(24000)]
    }
    func setVideoHandler(_ handler: ((Data) -> Void)?) { attached = handler != nil }
    func requestKeyframe() {}
    func health() -> [String: Any] { ["healthy": true] }
}

private final class RunnerRecordingConnectionStub: RunnerRecordingConnection {
    let receiver = RunnerRecordingSourceStub()
    var source: NativeRecordingSource { receiver }
    let sessionID = UUID().uuidString
    let rotation = "rot0"
    var closed = 0
    var changed = false
    var acknowledged = true
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
