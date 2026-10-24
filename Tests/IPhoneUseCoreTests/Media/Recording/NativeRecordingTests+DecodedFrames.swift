import XCTest
import AVFoundation
import CoreVideo
import Darwin
@testable import IPhoneUseCore

extension NativeRecordingTests {

    func testSharedDecodedRecordingStartsOnStaticCacheWithoutKeyframeAndDetectsDamage() throws {
        for damage in [false, true] {
            let dir = try root(), units = try fixture(dir), source = RecordingSource(), clock = RecordingTestClock()
            let snapshots = fixtureSnapshots()
            defer { snapshots.close() }
            source.setVideoHandler { snapshots.receive($0, at: 98) }
            packets([units[0]], to: source)
            let deadline = Date().addingTimeInterval(2)
            while snapshots.previewFrame() == nil, Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
            XCTAssertNotNil(snapshots.previewFrame())
            let recorder = NativeStreamRecording(root: dir, now: clock.now)
            defer { _ = recorder.close() }
            let started = try recorder.start(
                duration: 30, receiver: source, mediaID: "unchanged", rotation: "rot0", snapshots: snapshots)
            XCTAssertEqual(source.keyframeRequests, 0)
            XCTAssertTrue(source.attached, "Decoded subscription must not overwrite the existing packet handler")
            XCTAssertEqual(recorder.status()["state"] as? String, "recording")
            // An observation of a quiet shared stream must fail closed without
            // invoking the backend's destructive orientation recovery callback.
            XCTAssertThrowsError(
                try NativeCaptureChecks.withOrientationRecovery(
                    capture: { _ in throw IPhoneUseError("native_snapshot_freshness_unavailable", "quiet shared stream")
                    },
                    resynchronize: {
                        recorder.endSegment(reason: "orientation_unverified")
                        XCTFail("Missing frames must not end the recording")
                        return true
                    }, recordingActive: { recorder.isActive })
            ) { XCTAssertEqual(($0 as? IPhoneUseError)?.code, "native_snapshot_freshness_unavailable") }
            XCTAssertTrue(recorder.isActive)
            if damage {
                snapshots.receive(Data([0]), at: 101)
                let deadline = Date().addingTimeInterval(2)
                while snapshots.status()["decodeErrors"] as? Int == 0, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.005)
                }
            }
            clock.set(102)
            let result = try recorder.stop(id: (try XCTUnwrap(started["recordingID"] as? String)))
            XCTAssertEqual(result["fileValidated"] as? Bool, !damage)
            XCTAssertEqual(result["initialCachedFrameAgeSeconds"] as? Double, 2)
            XCTAssertEqual(result["clockSource"] as? String, "rtcp_sender_reports_with_host_start_anchor")
            XCTAssertTrue(source.attached)
            if !damage {
                XCTAssertEqual(result["writtenFrames"] as? Int, 1)
                let video = try XCTUnwrap(result["video"] as? [String: Any])
                XCTAssertEqual((try XCTUnwrap(video["durationSeconds"] as? Double)), 2, accuracy: 0.01)
                XCTAssertNotNil(snapshots.previewFrame(), "Stopping recording must retain the preview decoder/cache")
            }
        }
    }

    func testTimerDeliversOwnedCompletionWithoutStatusOrStopPolling() throws {
        for reason in ["duration", "media_lost"] {
            let source = RecordingSource(), clock = RecordingTestClock()
            let delivery = DispatchQueue(label: "recording-test.owner")
            let finished = expectation(description: reason)
            var delivered: [(String, String)] = []
            var recorder: NativeStreamRecording!
            recorder = fixtureRecorder(
                root: try root(), now: clock.now,
                onFinish: { id, mediaID in
                    delivery.async {
                        // Like SessionHost, serialized delivery can inspect the
                        // recorder without reentering its private finish queue.
                        XCTAssertFalse(recorder.isActive)
                        XCTAssertFalse(source.attached)
                        delivered.append((id, mediaID))
                        finished.fulfill()
                    }
                })
            let start = try recorder.start(duration: 2, receiver: source, mediaID: "owned-\(reason)", rotation: "rot0")
            let id = try XCTUnwrap(start["recordingID"] as? String)
            if reason == "duration" { clock.set(103) } else { source.setHealthy(false) }
            wait(for: [finished], timeout: 3)
            let result = try recorder.stop(id: id)
            XCTAssertEqual(result["stopReason"] as? String, reason)
            _ = recorder.close()
            delivery.sync {
                XCTAssertEqual(delivered.count, 1, "Idempotent stop and close cannot deliver another completion")
                XCTAssertEqual(delivered.first?.0, id)
                XCTAssertEqual(delivered.first?.1, "owned-\(reason)")
            }
        }
    }

    func testReceiverFeedsSnapshotAndRecordingIndependently() throws {
        let units = try fixture(root())
        let socket = try FixtureUDPSocket()
        let sender = socket.descriptor
        var endpoint = socket.endpoint
        defer { socket.close() }
        let receiver = try decodedReceiver()
        defer { receiver.close() }
        try receiver.configure([
            "SourcePort": UInt16(bigEndian: endpoint.sin6_port), "LocalSSRC": 123, "RemoteSSRC": 456,
            "RTCPEnabled": true, "RTCPSendInterval": 1.0, "SRTPCipherSuite": 0, "RxPayloadType": 100, "TilesPerFrame": 1
        ])
        endpoint.sin6_port = receiver.port.bigEndian
        let source = RecordingSource(), recordingPacket = DispatchSemaphore(value: 0)
        receiver.setVideoHandler { _ in recordingPacket.signal() }
        source.setVideoHandler { data in
            let sent = data.withUnsafeBytes { bytes in
                withUnsafePointer(to: &endpoint) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(
                            sender, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                    }
                }
            }
            XCTAssertEqual(sent, data.count)
        }
        let start = ProcessInfo.processInfo.systemUptime
        packets(units, to: source)
        for _ in 0..<units.reduce(0, { $0 + $1.nals.count }) {
            XCTAssertEqual(recordingPacket.wait(timeout: .now() + 1), .success)
        }
        let snapshots = try XCTUnwrap(receiver.snapshots)
        XCTAssertNotNil(try snapshots.frame(after: start, timeout: 1, cancellation: NativeCancellation()))
        XCTAssertNil(
            try snapshots.frame(
                after: ProcessInfo.processInfo.systemUptime, timeout: 0, cancellation: NativeCancellation()))
        XCTAssertNil(
            try receiver.snapshot(after: start, cancellation: NativeCancellation()),
            "A receiver barrier must exclude already received/decoded data")
        // Quiescence must not erase negative geometry evidence or make old
        // pixels eligible for a new observation.
        XCTAssertNoThrow(try snapshots.rejectConflictingGeometry(display(width: 64, height: 96)))
        XCTAssertThrowsError(try snapshots.rejectConflictingGeometry(display(width: 128, height: 192)))
        XCTAssertNil(
            try snapshots.frame(
                after: ProcessInfo.processInfo.systemUptime, timeout: 0, cancellation: NativeCancellation()))
        snapshots.close()
        // Closing only snapshots must not remove the recording subscription.
        packets([units[0]], to: source)
        for _ in units[0].nals { XCTAssertEqual(recordingPacket.wait(timeout: .now() + 1), .success) }
        XCTAssertEqual(snapshots.status()["closed"] as? Bool, true)
        receiver.setVideoHandler(nil)
    }
    private func display(width: Int, height: Int) throws -> NativeDisplay {
        try NativeDisplay([
            "backlightState": "activeOn",
            "displays": [
                [
                    "primary": true, "displayId": 1, "bounds": [[0, 0], [width, height]], "pointScale": 1,
                    "currentOrientation": "rot0", "nativeOrientation": "rot0"
                ]
            ]
        ])
    }

    private func decodedReceiver() throws -> NativeRTPReceiver {
        let receiverDecoder = FixtureHEVCDecoder()
        return try NativeRTPReceiver(
            deviceAddress: "::1", captureSnapshots: true,
            makeSnapshots: {
                NativeVideoSnapshot(
                    decode: { unit in
                        try receiverDecoder.decode(unit).map {
                            NativeDecodedVideoFrame(
                                pixels: $0, nativeWidth: CVPixelBufferGetWidth($0),
                                nativeHeight: CVPixelBufferGetHeight($0))
                        }
                    }, resetDecoder: { receiverDecoder.resetReferences() })
            })
    }

}
