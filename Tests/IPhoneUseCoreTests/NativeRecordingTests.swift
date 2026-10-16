import XCTest
import AVFoundation
import CoreVideo
import Darwin
@testable import IPhoneUseCore

private final class RecordingSource: NativeRecordingSource {
    private let lock = NSLock()
    private var handler: ((Data) -> Void)?
    private var healthy = true
    var configuration: [String: Any] = ["RxPayloadType": 100, "TilesPerFrame": 1, "SRTPCipherSuite": 0, "RTPClockRate": Int32(24000), "LocalSSRC": 123]
    private(set) var keyframeRequests = 0
    func recordingConfiguration() -> [String: Any] { configuration }
    func setVideoHandler(_ handler: ((Data) -> Void)?) { lock.lock(); self.handler = handler; lock.unlock() }
    func requestKeyframe() { keyframeRequests += 1 }
    func health() -> [String: Any] { lock.lock(); defer { lock.unlock() }; return ["healthy": healthy] }
    func setHealthy(_ value: Bool) { lock.lock(); healthy = value; lock.unlock() }
    var attached: Bool { lock.lock(); defer { lock.unlock() }; return handler != nil }
    func send(_ data: Data) { lock.lock(); let callback = handler; lock.unlock(); callback?(data) }
}

private final class RecordingTestClock {
    private let lock = NSLock()
    private var value = 100.0
    func now() -> Double { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: Double) { lock.lock(); self.value = value; lock.unlock() }
}

final class NativeRecordingTests: XCTestCase {
    func testStaticSourceRefreshKeepsOneFileAndDeadlineWithNewTimestampEpoch() throws {
        for scenario in ["same", "rotation", "cancelled", "deadline", "clock"] {
            let dir = try root(), units = try fixture(dir), clock = RecordingTestClock()
            let old = RecordingSource(), replacement = RecordingSource()
            func cache(_ source: RecordingSource, at time: Double) throws -> NativeVideoSnapshot {
                let decoder = FixtureHEVCDecoder()
                let snapshots = NativeVideoSnapshot(decode: { unit in
                    try decoder.decode(unit).map { NativeDecodedVideoFrame(pixels: $0, nativeWidth: 64, nativeHeight: 96) }
                }, resetDecoder: { decoder.resetReferences() })
                source.setVideoHandler { snapshots.receive($0, at: time) }
                self.packets([units[0]], to: source)
                let deadline = Date().addingTimeInterval(2)
                while snapshots.previewFrame() == nil, Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
                XCTAssertNotNil(snapshots.previewFrame())
                return snapshots
            }
            let first = try cache(old, at: 98)
            let next = try cache(replacement, at: 104)
            defer { first.close(); next.close() }
            let recorder = NativeStreamRecording(root: dir, now: clock.now)
            defer { _ = recorder.close() }
            let start = try recorder.start(duration: 20, receiver: old, mediaID: "old", rotation: "rot0", snapshots: first)
            let id = try XCTUnwrap(start["recordingID"] as? String)
            XCTAssertEqual(recorder.status()["state"] as? String, "recording")
            clock.set(102)
            let refresh = {
                try recorder.refreshSharedSource {
                    // The old stream really closes; the recorder must not treat
                    // that scoped teardown as an unexpected source failure.
                    old.setHealthy(false); first.close()
                    clock.set(scenario == "deadline" ? 121 : 104)
                    if scenario == "cancelled" { throw IPhoneUseError("native_cancelled", "cancelled") }
                    if scenario == "clock" { replacement.configuration["RTPClockRate"] = Int32(90000) }
                    return NativeStreamRecording.SharedSource(receiver: replacement, snapshots: next,
                        mediaID: "replacement", rotation: scenario == "rotation" ? "rot90" : "rot0",
                        geometryChanged: scenario == "rotation")
                }
            }
            if ["cancelled", "deadline", "clock"].contains(scenario) { XCTAssertThrowsError(try refresh()) }
            else { XCTAssertEqual(try refresh(), scenario == "rotation") }
            clock.set(108)
            let result = try recorder.stop(id: id)
            XCTAssertEqual(result["recordingID"] as? String, id)
            XCTAssertEqual(result["path"] as? String, start["path"] as? String)
            XCTAssertEqual(result["fileValidated"] as? Bool, ["same", "rotation"].contains(scenario))
            if scenario == "same" {
                XCTAssertEqual(result["elapsedSeconds"] as? Double, 8)
                XCTAssertEqual(result["writtenFrames"] as? Int, 2)
                let video = try XCTUnwrap(result["video"] as? [String: Any])
                XCTAssertEqual(video["durationSeconds"] as! Double, 8, accuracy: 0.01)
                let refreshes = try XCTUnwrap(result["sourceRefreshes"] as? [[String: Any]])
                XCTAssertEqual(refreshes.count, 1)
                XCTAssertEqual(refreshes[0]["durationSeconds"] as? Double, 2)
                XCTAssertEqual(result["mediaSessionID"] as? String, "replacement")
            } else if scenario == "rotation" {
                XCTAssertEqual(result["stopReason"] as? String, "display_changed")
                XCTAssertEqual(result["writtenFrames"] as? Int, 1, "Never append a differently oriented source")
            } else { XCTAssertEqual(result["stopReason"] as? String, "media_refresh_failed") }
        }
    }

    func testColdEncoderPreparationDoesNotSubscribeOrConsumeRecordingDuration() throws {
        let dir = try root(), units = try fixture(dir), source = RecordingSource(), clock = RecordingTestClock()
        let decoder = FixtureHEVCDecoder()
        let snapshots = NativeVideoSnapshot(decode: { unit in
            try decoder.decode(unit).map { NativeDecodedVideoFrame(pixels: $0, nativeWidth: 64, nativeHeight: 96) }
        }, resetDecoder: { decoder.resetReferences() })
        defer { snapshots.close() }
        let preparation = DispatchSemaphore(value: 0), delivered = expectation(description: "preview continues during preparation")
        source.setVideoHandler { snapshots.receive($0, at: clock.now()) }
        clock.set(98)
        DispatchQueue.global().async {
            self.packets(units, to: source, beforeUnit: { unit in
                if unit.timestamp == units[1].timestamp {
                    XCTAssertEqual(preparation.wait(timeout: .now() + 3), .success)
                }
            })
            delivered.fulfill()
        }
        let deadline = Date().addingTimeInterval(2)
        while snapshots.previewFrame() == nil, Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        XCTAssertNotNil(snapshots.previewFrame())
        clock.set(100)
        let recorder = NativeStreamRecording(root: dir, now: clock.now, makeWriter: { url, scale, orientation in
            NativeVideoWriter(url: url, timescale: scale, orientation: orientation, beforeEncoderSetup: {
                clock.set(101); preparation.signal()
                let deadline = Date().addingTimeInterval(2)
                while snapshots.status()["decodedFrames"] as? Int != units.count, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.005)
                }
                XCTAssertEqual(snapshots.status()["decodedFrames"] as? Int, units.count)
                clock.set(102)
            })
        })
        defer { _ = recorder.close() }
        let started = try recorder.start(duration: 30, receiver: source, mediaID: "cold", rotation: "rot0", snapshots: snapshots)
        wait(for: [delivered], timeout: 3)
        XCTAssertEqual(recorder.status()["state"] as? String, "recording")
        clock.set(104)
        let result = try recorder.stop(id: XCTUnwrap(started["recordingID"] as? String))
        XCTAssertEqual(result["state"] as? String, "completed")
        XCTAssertEqual(result["writtenFrames"] as? Int, 1, "Only the current seed is admitted after preparation")
        XCTAssertEqual(result["elapsedSeconds"] as? Double, 2)
        XCTAssertEqual(result["initialCachedFrameAgeSeconds"] as? Double, 1)
        XCTAssertEqual(source.keyframeRequests, 0)
    }

    func testMissingSharedFrameStillWaitsWithoutTakingOverPacketHandler() throws {
        let source = RecordingSource(), snapshots = NativeVideoSnapshot()
        defer { snapshots.close() }
        source.setVideoHandler { _ in }
        let recorder = NativeStreamRecording(root: try root())
        defer { _ = recorder.close() }
        let result = try recorder.start(duration: 2, receiver: source, mediaID: "empty", rotation: "rot0", snapshots: snapshots)
        XCTAssertEqual(result["state"] as? String, "waiting_for_frame")
        XCTAssertTrue(recorder.isActive)
        XCTAssertTrue(source.attached)
    }

    func testSharedDecodedBurstKeepsRTPSpacingWhenReceiveTimesQuantizeTogether() throws {
        let dir = try root(), units = try fixture(dir), source = RecordingSource(), clock = RecordingTestClock()
        let decoder = FixtureHEVCDecoder()
        let snapshots = NativeVideoSnapshot(decode: { unit in
            try decoder.decode(unit).map { NativeDecodedVideoFrame(pixels: $0, nativeWidth: 64, nativeHeight: 96) }
        }, resetDecoder: { decoder.resetReferences() })
        defer { snapshots.close() }
        let recorder = NativeStreamRecording(root: dir, now: clock.now)
        defer { _ = recorder.close() }
        var id: String?, receivedAt = 98.0
        source.setVideoHandler { snapshots.receive($0, at: receivedAt) }
        packets(units, to: source, beforeUnit: { unit in
            if unit.timestamp == units[1].timestamp {
                let deadline = Date().addingTimeInterval(2)
                while snapshots.previewFrame() == nil, Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
                XCTAssertNotNil(snapshots.previewFrame())
                id = try? recorder.start(duration: 30, receiver: source, mediaID: "burst", rotation: "rot0", snapshots: snapshots)["recordingID"] as? String
                receivedAt = 101
            }
        })
        let deadline = Date().addingTimeInterval(2)
        while snapshots.status()["decodedFrames"] as? Int != units.count, Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        XCTAssertEqual(snapshots.status()["decodedFrames"] as? Int, units.count)
        clock.set(104)
        let result = try recorder.stop(id: XCTUnwrap(id))
        XCTAssertEqual(result["state"] as? String, "completed")
        XCTAssertEqual(result["writtenFrames"] as? Int, units.count)
        XCTAssertEqual(result["mediaSpanSeconds"] as! Double, 2.8, accuracy: 0.001)
        XCTAssertEqual(source.keyframeRequests, 0)
    }

    func testSharedDecodedRecordingStartsOnStaticCacheWithoutKeyframeAndDetectsDamage() throws {
        for damage in [false, true] {
            let dir = try root(), units = try fixture(dir), source = RecordingSource(), clock = RecordingTestClock()
            let decoder = FixtureHEVCDecoder()
            let snapshots = NativeVideoSnapshot(decode: { unit in
                try decoder.decode(unit).map { NativeDecodedVideoFrame(pixels: $0, nativeWidth: 64, nativeHeight: 96) }
            }, resetDecoder: { decoder.resetReferences() })
            defer { snapshots.close() }
            source.setVideoHandler { snapshots.receive($0, at: 98) }
            packets([units[0]], to: source)
            let deadline = Date().addingTimeInterval(2)
            while snapshots.previewFrame() == nil, Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
            XCTAssertNotNil(snapshots.previewFrame())
            let recorder = NativeStreamRecording(root: dir, now: clock.now)
            defer { _ = recorder.close() }
            let started = try recorder.start(duration: 30, receiver: source, mediaID: "unchanged", rotation: "rot0", snapshots: snapshots)
            XCTAssertEqual(source.keyframeRequests, 0)
            XCTAssertTrue(source.attached, "Decoded subscription must not overwrite the existing packet handler")
            XCTAssertEqual(recorder.status()["state"] as? String, "recording")
            // An observation of a quiet shared stream must fail closed without
            // invoking the backend's destructive orientation recovery callback.
            XCTAssertThrowsError(try NativeCaptureChecks.withOrientationRecovery(capture: { _ in
                throw IPhoneUseError("native_snapshot_freshness_unavailable", "quiet shared stream")
            }, resynchronize: {
                recorder.endSegment(reason: "orientation_unverified")
                XCTFail("Missing frames must not end the recording")
                return true
            }, recordingActive: { recorder.isActive })) {
                XCTAssertEqual(($0 as? IPhoneUseError)?.code, "native_snapshot_freshness_unavailable")
            }
            XCTAssertTrue(recorder.isActive)
            if damage {
                snapshots.receive(Data([0]), at: 101)
                let deadline = Date().addingTimeInterval(2)
                while snapshots.status()["decodeErrors"] as? Int == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
            }
            clock.set(102)
            let result = try recorder.stop(id: started["recordingID"] as! String)
            XCTAssertEqual(result["fileValidated"] as? Bool, !damage)
            XCTAssertEqual(result["initialCachedFrameAgeSeconds"] as? Double, 2)
            XCTAssertEqual(result["clockSource"] as? String, "rtcp_sender_reports_with_host_start_anchor")
            XCTAssertTrue(source.attached)
            if !damage {
                XCTAssertEqual(result["writtenFrames"] as? Int, 1)
                let video = try XCTUnwrap(result["video"] as? [String: Any])
                XCTAssertEqual(video["durationSeconds"] as! Double, 2, accuracy: 0.01)
                XCTAssertNotNil(snapshots.previewFrame(), "Stopping recording must retain the preview decoder/cache")
            }
        }
    }

    // Generic HEVC fixtures test recording timing/ownership and transport. They
    // do not pretend to exercise Apple's private VRA codec profile. The actual
    // VRA decoder is separately verified using the private recorded fault stream.
    private func fixtureWriter(url: URL, timescale: Int32, orientation: NativeVideoOrientation = .portrait) -> NativeVideoWriter {
        let decoder = FixtureHEVCDecoder()
        return NativeVideoWriter(url: url, timescale: timescale, orientation: orientation, decode: { try decoder.decode($0) })
    }
    private func fixtureRecorder(root: URL, now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
                                 onFinish: @escaping (String, String) -> Void = { _, _ in }) -> NativeStreamRecording {
        NativeStreamRecording(root: root, now: now, onFinish: onFinish, makeWriter: { self.fixtureWriter(url: $0, timescale: $1, orientation: $2) })
    }

    func testTimerDeliversOwnedCompletionWithoutStatusOrStopPolling() throws {
        for reason in ["duration", "media_lost"] {
            let source = RecordingSource(), clock = RecordingTestClock()
            let delivery = DispatchQueue(label: "recording-test.owner")
            let finished = expectation(description: reason)
            var delivered: [(String, String)] = []
            var recorder: NativeStreamRecording!
            recorder = fixtureRecorder(root: try root(), now: clock.now, onFinish: { id, mediaID in
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
        let units = try fixture(root()), sender = socket(AF_INET6, SOCK_DGRAM, 0)
        XCTAssertGreaterThanOrEqual(sender, 0)
        defer { Darwin.close(sender) }
        var endpoint = sockaddr_in6()
        endpoint.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        endpoint.sin6_family = sa_family_t(AF_INET6)
        XCTAssertEqual(inet_pton(AF_INET6, "::1", &endpoint.sin6_addr), 1)
        XCTAssertEqual(withUnsafePointer(to: &endpoint) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(sender, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
        } }, 0)
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        XCTAssertEqual(withUnsafeMutablePointer(to: &endpoint) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(sender, $0, &length)
        } }, 0)
        let receiverDecoder = FixtureHEVCDecoder()
        let receiver = try NativeRTPReceiver(deviceAddress: "::1", captureSnapshots: true, makeSnapshots: {
            NativeVideoSnapshot(decode: { unit in
                try receiverDecoder.decode(unit).map {
                    NativeDecodedVideoFrame(pixels: $0, nativeWidth: CVPixelBufferGetWidth($0), nativeHeight: CVPixelBufferGetHeight($0))
                }
            }, resetDecoder: { receiverDecoder.resetReferences() })
        })
        defer { receiver.close() }
        try receiver.configure(["SourcePort": UInt16(bigEndian: endpoint.sin6_port), "LocalSSRC": 123, "RemoteSSRC": 456,
            "RTCPEnabled": true, "RTCPSendInterval": 1.0, "SRTPCipherSuite": 0, "RxPayloadType": 100, "TilesPerFrame": 1])
        endpoint.sin6_port = receiver.port.bigEndian
        let source = RecordingSource(), recordingPacket = DispatchSemaphore(value: 0)
        receiver.setVideoHandler { _ in recordingPacket.signal() }
        source.setVideoHandler { data in
            let sent = data.withUnsafeBytes { bytes in withUnsafePointer(to: &endpoint) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(sender, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            } }
            XCTAssertEqual(sent, data.count)
        }
        let start = ProcessInfo.processInfo.systemUptime
        packets(units, to: source)
        for _ in 0..<units.reduce(0, { $0 + $1.nals.count }) {
            XCTAssertEqual(recordingPacket.wait(timeout: .now() + 1), .success)
        }
        let snapshots = try XCTUnwrap(receiver.snapshots)
        XCTAssertNotNil(try snapshots.frame(after: start, timeout: 1, cancellation: NativeCancellation()))
        XCTAssertNil(try snapshots.frame(after: ProcessInfo.processInfo.systemUptime, timeout: 0, cancellation: NativeCancellation()))
        XCTAssertNil(try receiver.snapshot(after: start, cancellation: NativeCancellation()), "A receiver barrier must exclude already received/decoded data")
        func display(width: Int, height: Int) throws -> NativeDisplay {
            try NativeDisplay(["backlightState": "activeOn", "displays": [["primary": true, "displayId": 1,
                "bounds": [[0, 0], [width, height]], "pointScale": 1,
                "currentOrientation": "rot0", "nativeOrientation": "rot0"]]])
        }
        // Quiescence must not erase negative geometry evidence or make old
        // pixels eligible for a new observation.
        XCTAssertNoThrow(try snapshots.rejectConflictingGeometry(display(width: 64, height: 96)))
        XCTAssertThrowsError(try snapshots.rejectConflictingGeometry(display(width: 128, height: 192)))
        XCTAssertNil(try snapshots.frame(after: ProcessInfo.processInfo.systemUptime, timeout: 0, cancellation: NativeCancellation()))
        snapshots.close()
        // Closing only snapshots must not remove the recording subscription.
        packets([units[0]], to: source)
        for _ in units[0].nals { XCTAssertEqual(recordingPacket.wait(timeout: .now() + 1), .success) }
        XCTAssertEqual(snapshots.status()["closed"] as? Bool, true)
        receiver.setVideoHandler(nil)
    }
    func testGenericHEVCFixtureAndPortableRecording() throws {
        let dir = try root(), units = try fixture(dir)
        let writer = fixtureWriter(url: dir.appendingPathComponent("with-snapshots.mp4"), timescale: 24000)
        let decoder = FixtureHEVCDecoder()
        for unit in units {
            let pixels = try XCTUnwrap(decoder.decode(unit))
            XCTAssertEqual(CVPixelBufferGetWidth(pixels), 64)
            XCTAssertEqual(CVPixelBufferGetHeight(pixels), 96)
            try writer.append(unit)
        }
        try writer.finish()
        let result = try NativeRecordingValidation.inspect(dir.appendingPathComponent("with-snapshots.mp4"))
        XCTAssertEqual(result["decodedFrames"] as? Int, units.count)
        XCTAssertEqual(result["durationSeconds"] as! Double, 1.916666, accuracy: 0.001)
        let cold = FixtureHEVCDecoder()
        XCTAssertNil(try cold.decode(units[1]))
    }
    func testWithheldPresentationKeepsTimelineAndRejectsDuplicateDecodedTimestamp() throws {
        let dir = try root(), units = try fixture(dir), decoder = FixtureHEVCDecoder()
        let url = dir.appendingPathComponent("withheld.mp4")
        let writer = NativeVideoWriter(url: url, timescale: 24000, decode: { unit in
            let pixels = try decoder.decode(unit)
            return unit.timestamp == 24000 ? nil : pixels
        })
        for unit in units { try writer.append(unit) }
        try writer.finish()
        let facts = try NativeRecordingValidation.inspect(url)
        XCTAssertEqual(facts["decodedFrames"] as? Int, 19)
        XCTAssertEqual(facts["durationSeconds"] as! Double, 1.916666, accuracy: 0.001)
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: asset.tracks(withMediaType: .video)[0], outputSettings: nil)
        reader.add(output); XCTAssertTrue(reader.startReading())
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) == 0 { continue }
            times.append(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)))
            if abs(times.last! - 0.9) < 0.001 {
                XCTAssertEqual(CMTimeGetSeconds(CMSampleBufferGetDuration(sample)), 0.2, accuracy: 0.001)
            }
        }
        XCTAssertEqual(times.count, 19); XCTAssertFalse(times.contains { abs($0 - 1) < 0.001 })
        XCTAssertTrue(times.contains { abs($0 - 1.1) < 0.001 })
        let withheld = NativeVideoWriter(url: dir.appendingPathComponent("not-created.mp4"), timescale: 24000, decode: { _ in nil })
        try withheld.append(units[0])
        XCTAssertThrowsError(try withheld.append(units[0]))
    }

    func testCapabilityAndDurationFailClosed() throws {
        XCTAssertFalse(NativeRecordingOptions.supported(by: [:]))
        XCTAssertTrue(NativeRecordingOptions.supported(by: ["capabilities": [["featureIdentifier": "com.apple.coredevice.feature.screenrecording"]]]))
        for value: Any in [true, 0, -1, 301, Double.infinity, "5"] {
            XCTAssertThrowsError(try NativeRecordingOptions.duration(["duration": value]))
        }
        XCTAssertEqual(try NativeRecordingOptions.duration(["duration": 5]), 5)
        let source = RecordingSource()
        XCTAssertTrue(NativeStreamRecording.supports(source.configuration))
        source.configuration["TilesPerFrame"] = 2
        XCTAssertFalse(NativeStreamRecording.supports(source.configuration))
    }
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recording-test-\(UUID().uuidString)")
        try SessionPaths.secureDirectory(root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    // Generate actual HEVC with Apple's encoder, including inter-frame samples.
    // No captured device data or third-party codec fixture is needed.
    private func fixture(_ root: URL) throws -> [NativeVideoAccessUnit] {
        let url = root.appendingPathComponent("fixture.mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: 64, AVVideoHeightKey: 96,
            AVVideoCompressionPropertiesKey: [AVVideoAllowFrameReorderingKey: false, AVVideoMaxKeyFrameIntervalKey: 10]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 96])
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for frame in 0..<20 {
            let deadline = Date().addingTimeInterval(2)
            while !input.isReadyForMoreMediaData, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            XCTAssertTrue(input.isReadyForMoreMediaData)
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 96, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame * 10), CVPixelBufferGetBytesPerRow(pixels) * 96)
            CVPixelBufferUnlockBaseAddress(pixels, [])
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)))
        }
        input.markAsFinished()
        let finished = expectation(description: "movie finished")
        writer.finishWriting { finished.fulfill() }; wait(for: [finished], timeout: 5)
        XCTAssertEqual(writer.status, .completed)
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: asset.tracks(withMediaType: .video)[0], outputSettings: nil)
        reader.add(output); XCTAssertTrue(reader.startReading())
        var units: [NativeVideoAccessUnit] = []
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) == 0 { continue }
            let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
            var nals: [Data] = []
            for index in 0..<3 {
                var pointer: UnsafePointer<UInt8>?, size = 0
                XCTAssertEqual(CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index,
                    parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil), noErr)
                nals.append(Data(bytes: try XCTUnwrap(pointer), count: size))
            }
            let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
            var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
            XCTAssertEqual(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: &bytes), noErr)
            var offset = 0
            while offset < bytes.count {
                let length = bytes[offset..<offset+4].reduce(0) { $0 << 8 | Int($1) }; offset += 4
                nals.append(Data(bytes[offset..<offset+length])); offset += length
            }
            let sync = nals.contains { [19,20].contains(Int(($0[0] >> 1) & 63)) }
            units.append(NativeVideoAccessUnit(timestamp: UInt32(units.count * 2400), nals: nals, keyframe: sync))
        }
        XCTAssertEqual(reader.status, .completed); XCTAssertEqual(units.count, 20)
        XCTAssertTrue(units[0].keyframe); XCTAssertFalse(units[1].keyframe)
        return units
    }
    private func packets(_ units: [NativeVideoAccessUnit], to source: RecordingSource, omitMarkerAt: UInt32? = nil,
                         beforeUnit: ((NativeVideoAccessUnit) -> Void)? = nil) {
        var sequence: UInt16 = 1
        for unit in units {
            beforeUnit?(unit)
            for (index, nal) in unit.nals.enumerated() {
                var packet = Data([0x80, index == unit.nals.count - 1 && unit.timestamp != omitMarkerAt ? 0xe4 : 0x64, UInt8(sequence >> 8), UInt8(sequence & 255)])
                for value in [unit.timestamp, UInt32(123)] { var big = value.bigEndian; withUnsafeBytes(of: &big) { packet.append(contentsOf: $0) } }
                packet.append(nal); source.send(packet); sequence &+= 1
            }
        }
    }
    func testFinalHoldPreservesRTPGapsWrapAndAllOriginalSamples() throws {
        let dir = try root(), units = try fixture(dir), url = dir.appendingPathComponent("held.mp4")
        let writer = fixtureWriter(url: url, timescale: 24000, orientation: .right)
        var expected: [Double] = []
        for (index, unit) in units.enumerated() {
            let ticks = unit.timestamp + (index >= 10 ? 120000 : 0)
            expected.append(Double(ticks) / 24000)
            try writer.append(NativeVideoAccessUnit(timestamp: (UInt32.max - 12000) &+ ticks,
                nals: unit.nals, keyframe: unit.keyframe, firstPacketAt: 101 + Double(ticks) / 24000))
        }
        XCTAssertEqual(writer.mediaSpanSeconds, 6.9, accuracy: 0.0001)
        XCTAssertEqual(writer.firstFrameReceivedAt, 101)
        XCTAssertEqual(writer.lastFrameReceivedAt!, 107.9, accuracy: 0.0001)
        try writer.finish(lastFrameDurationSeconds: 3.1)
        let facts = try NativeRecordingValidation.inspect(url)
        XCTAssertEqual(facts["decodedFrames"] as? Int, 20, "Holding must not invent extra frames")
        XCTAssertEqual(facts["durationSeconds"] as! Double, 10, accuracy: 0.001)
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        let track = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output); XCTAssertTrue(reader.startReading())
        var times: [Double] = [], durations: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) == 0 { continue }
            times.append(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)))
            durations.append(CMTimeGetSeconds(CMSampleBufferGetDuration(sample)))
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertEqual(times.count, expected.count)
        for (actual, expected) in zip(times, expected) { XCTAssertEqual(actual, expected, accuracy: 0.001) }
        XCTAssertEqual(durations.last!, 3.1, accuracy: 0.001)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Seek into the terminal hold, allowing the decoder to select the last
        // real sample. No new sample is asserted to exist at this time.
        let image = try generator.copyCGImage(at: CMTime(seconds: 9.5, preferredTimescale: 24000), actualTime: nil)
        XCTAssertEqual(image.width, 96); XCTAssertEqual(image.height, 64)
    }

    func testNormalStopKeepsStaticTailAndInitialKeyframeDelayExplicit() throws {
        let dir = try root(), units = try fixture(dir)
        for automatic in [false, true] {
            let source = RecordingSource(), clock = RecordingTestClock()
            let recorder = fixtureRecorder(root: dir.appendingPathComponent("normal-\(automatic)"), now: clock.now)
            defer { _ = recorder.close() }
            // Manual stop must precede the deadline; at exactly 6 seconds the
            // timer is legitimately allowed to win the race with stop().
            let start = try recorder.start(duration: automatic ? 6 : 30, receiver: source, mediaID: "owned", rotation: "rot0")
            packets(units, to: source) { clock.set(101 + Double($0.timestamp) / 24000) }
            _ = recorder.status() // Drain all admitted packets before stopping the test clock.
            clock.set(106)
            if automatic {
                let deadline = Date().addingTimeInterval(3)
                while recorder.isActive, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
                XCTAssertFalse(recorder.isActive)
            }
            let result = try recorder.stop(id: start["recordingID"] as! String)
            XCTAssertEqual(result["state"] as? String, "completed")
            XCTAssertEqual(result["stopReason"] as? String, automatic ? "duration" : "requested")
            XCTAssertEqual(result["elapsedSeconds"] as! Double, 6, accuracy: 0.0001)
            XCTAssertEqual(result["firstFrameDelaySeconds"] as! Double, 1, accuracy: 0.0001)
            XCTAssertEqual(result["frameReceiveSpanSeconds"] as! Double, 1.9, accuracy: 0.0001)
            XCTAssertEqual(result["mediaSpanSeconds"] as! Double, 1.9, accuracy: 0.0001)
            XCTAssertEqual(result["lastFrameDurationSeconds"] as! Double, 3.1, accuracy: 0.0001)
            XCTAssertEqual(result["tailTimingSource"] as? String, "host_monotonic_receive")
            let video = try XCTUnwrap(result["video"] as? [String: Any])
            XCTAssertEqual(video["durationSeconds"] as! Double, 5, accuracy: 0.001)
            XCTAssertEqual(video["decodedFrames"] as? Int, 20)
            XCTAssertFalse(source.attached)
        }
    }

    func testUnhealthyDamagedAndInterruptedSegmentsNeverExtendTail() throws {
        let dir = try root(), units = try fixture(dir)
        for cause in ["media_lost", "packet_loss", "queue_overflow", "display_changed", "session_closed"] {
            let source = RecordingSource(), clock = RecordingTestClock()
            let recorder = fixtureRecorder(root: dir.appendingPathComponent(cause), now: clock.now)
            defer { _ = recorder.close() }
            let start = try recorder.start(duration: 30, receiver: source, mediaID: "owned", rotation: "rot0")
            packets(units, to: source, omitMarkerAt: cause == "packet_loss" ? units[1].timestamp : nil) {
                clock.set(101 + Double($0.timestamp) / 24000)
            }
            _ = recorder.status(); clock.set(106)
            if cause == "media_lost" { source.setHealthy(false) }
            if cause == "queue_overflow" { source.send(Data(repeating: 0, count: 4 * 1024 * 1024 + 1)) }
            if cause == "display_changed" { recorder.endSegment(reason: cause) }
            if cause == "session_closed" { _ = recorder.close() }
            let result = try recorder.stop(id: start["recordingID"] as! String)
            XCTAssertEqual(result["tailTimingSource"] as? String, "nominal_frame_duration")
            XCTAssertEqual(result["lastFrameDurationSeconds"] as! Double, 1.0 / 60, accuracy: 0.0001)
            XCTAssertEqual((result["video"] as? [String: Any])?["durationSeconds"] as! Double, 1.916666, accuracy: 0.001)
            if ["media_lost", "packet_loss", "queue_overflow"].contains(cause) {
                XCTAssertEqual(result["state"] as? String, "failed")
                XCTAssertEqual(result["fileValidated"] as? Bool, false)
            }
            XCTAssertFalse(source.attached)
        }
    }
    func testReencodedHEVCHasSyncIndexAndSupportsRandomSeek() throws {
        let dir = try root(), units = try fixture(dir), url = dir.appendingPathComponent("remux.mp4")
        let writer = fixtureWriter(url: url, timescale: 24000)
        for unit in units { try writer.append(unit) }
        try writer.finish()
        XCTAssertThrowsError(try writer.append(units[0])) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "recording_writer_closed")
        }
        writer.cancel() // Idempotent after releasing the encoder; the file survives.
        let result = try NativeRecordingValidation.inspect(url)
        XCTAssertEqual(result["decodedFrames"] as? Int, units.count)
        XCTAssertEqual(result["durationSeconds"] as! Double, 1.916666, accuracy: 0.001)
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: asset.tracks(withMediaType: .video)[0], outputSettings: nil)
        reader.add(output); XCTAssertTrue(reader.startReading())
        var index = 0
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) == 0 { continue }
            let attachments = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]])
            let notSync = attachments.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool ?? false
            if index == 0 { XCTAssertFalse(notSync, "First encoded frame must be independently decodable") }
            index += 1
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let image = try generator.copyCGImage(at: CMTime(value: 18, timescale: 10), actualTime: nil)
        XCTAssertEqual(image.width, 64)
        let broken = dir.appendingPathComponent("truncated.mp4")
        try Data(contentsOf: url).prefix(100).write(to: broken)
        XCTAssertThrowsError(try NativeRecordingValidation.inspect(broken))
    }
    func testLongDeviceRecordingDecodesEveryWrittenFrame() throws {
        guard let path = ProcessInfo.processInfo.environment["IPHONE_USE_LONG_RECORDING_FIXTURE"] else {
            throw XCTSkip("Set IPHONE_USE_LONG_RECORDING_FIXTURE to a 1–5 minute screen.mp4 with its result.json")
        }
        let url = URL(fileURLWithPath: path)
        let recorded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent("result.json"))) as? [String: Any])
        let expected = try XCTUnwrap(recorded["writtenFrames"] as? Int)
        XCTAssertGreaterThan(expected, 1000)
        let facts = try NativeRecordingValidation.inspect(url)
        XCTAssertGreaterThan(try XCTUnwrap(facts["durationSeconds"] as? Double), 60)
        XCTAssertEqual(facts["decodedFrames"] as? Int, expected)
    }
    func testLeadingEmptyEditDoesNotCountAsAnEncodedFrame() throws {
        let dir = try root(), units = try fixture(dir)
        let decoder = FixtureHEVCDecoder()
        let pixels = try XCTUnwrap(decoder.decode(units[0]))
        for delay in [0.0, 109.0 / 600.0] {
            let url = dir.appendingPathComponent("delayed-\(delay).mp4")
            let writer = NativeVideoWriter(url: url, timescale: 24000)
            for index in 0..<3 {
                try writer.appendDecoded(pixels, seconds: delay + Double(index) / 30, receivedAt: 100 + delay + Double(index) / 30)
            }
            try writer.finish(lastFrameDurationSeconds: 1.0 / 30)
            let facts = try NativeRecordingValidation.inspect(url)
            XCTAssertEqual(writer.frames, 3)
            XCTAssertEqual(facts["decodedFrames"] as? Int, writer.frames)
            XCTAssertEqual(try XCTUnwrap(facts["firstFrameSeconds"] as? Double), delay, accuracy: 0.002)
            XCTAssertEqual(try XCTUnwrap(facts["durationSeconds"] as? Double), delay + 0.1, accuracy: 0.002)
        }
    }
    func testLandscapeTrackTransformSurvivesMuxAndExactFrameExtraction() throws {
        let dir = try root(), units = try fixture(dir)
        for orientation in [NativeVideoOrientation.left, .right] {
            let url = dir.appendingPathComponent("\(orientation.rawValue).mp4")
            let writer = fixtureWriter(url: url, timescale: 24000, orientation: orientation)
            for unit in units { try writer.append(unit) }
            try writer.finish()
            let facts = try NativeRecordingValidation.inspect(url)
            XCTAssertEqual(facts["decodedFrames"] as? Int, 20)
            XCTAssertEqual(facts["width"] as? Int, 64)
            XCTAssertEqual(facts["height"] as? Int, 96)
            XCTAssertEqual(facts["displayWidth"] as? Int, 96)
            XCTAssertEqual(facts["displayHeight"] as? Int, 64)
            let asset = AVURLAsset(url: url)
            let transform = try XCTUnwrap(asset.tracks(withMediaType: .video).first).preferredTransform
            let corner = CGPoint(x: 0, y: 0).applying(transform)
            XCTAssertEqual(corner, orientation == .left ? CGPoint(x: 96, y: 0) : CGPoint(x: 0, y: 64))
            XCTAssertEqual(CGPoint(x: 64, y: 96).applying(transform),
                           orientation == .left ? CGPoint(x: 0, y: 64) : CGPoint(x: 96, y: 0))
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            let image = try generator.copyCGImage(at: CMTime(value: 1, timescale: 1), actualTime: nil)
            XCTAssertEqual(image.width, 96); XCTAssertEqual(image.height, 64)
        }
        let source = RecordingSource(), recorder = fixtureRecorder(root: dir.appendingPathComponent("unsupported"))
        defer { _ = recorder.close() }
        XCTAssertThrowsError(try recorder.start(duration: 3, receiver: source, mediaID: "owned", rotation: "rot180"))
        XCTAssertFalse(source.attached)
    }

    func testOwnedStopCannotStopNewRecordingAndCloseDetachesSink() throws {
        let dir = try root(), units = try fixture(dir), source = RecordingSource()
        let recorder = fixtureRecorder(root: dir.appendingPathComponent("owned"))
        defer { _ = recorder.close() }
        let first = try recorder.start(duration: 30, receiver: source, mediaID: "owned", rotation: "rot0")
        XCTAssertTrue(source.attached); XCTAssertGreaterThan(source.keyframeRequests, 0)
        XCTAssertThrowsError(try recorder.start(duration: 30, receiver: source, mediaID: "owned", rotation: "rot0"))
        XCTAssertThrowsError(try recorder.stop(id: "foreign"))
        packets(units, to: source)
        let stopped = try recorder.stop(id: first["recordingID"] as! String)
        XCTAssertEqual(stopped["state"] as? String, "completed")
        XCTAssertEqual(stopped["writtenFrames"] as? Int, 20)
        XCTAssertFalse(source.attached)
        let second = try recorder.start(duration: 30, receiver: source, mediaID: "owned", rotation: "rot0")
        _ = try recorder.stop(id: first["recordingID"] as! String)
        XCTAssertTrue(source.attached); XCTAssertTrue(recorder.isActive)
        packets(units, to: source)
        recorder.endSegment(reason: "display_changed")
        XCTAssertEqual(recorder.status()["state"] as? String, "completed")
        XCTAssertEqual(recorder.status()["stopReason"] as? String, "display_changed")
        XCTAssertEqual(recorder.status()["recordingID"] as? String, second["recordingID"] as? String)
        _ = try recorder.start(duration: 30, receiver: source, mediaID: "owned", rotation: "rot90")
        packets(units, to: source)
        let cleanup = recorder.close()
        XCTAssertFalse(source.attached)
        XCTAssertEqual((cleanup["recording"] as? [String: Any])?["state"] as? String, "completed")
        XCTAssertEqual((cleanup["recording"] as? [String: Any])?["stopReason"] as? String, "session_closed")
        XCTAssertThrowsError(try recorder.start(duration: 1, receiver: source, mediaID: "owned", rotation: "rot0"))
    }
    func testMissingEndOfFramePreservesPartialFileButCannotClaimCompletion() throws {
        let dir = try root(), units = try fixture(dir), source = RecordingSource()
        let recorder = fixtureRecorder(root: dir.appendingPathComponent("loss"))
        defer { _ = recorder.close() }
        let start = try recorder.start(duration: 30, receiver: source, mediaID: "owned", rotation: "rot0")
        packets(units, to: source, omitMarkerAt: units[1].timestamp)
        let result = try recorder.stop(id: start["recordingID"] as! String)
        XCTAssertEqual(result["state"] as? String, "failed")
        XCTAssertEqual((result["error"] as? [String: Any])?["code"] as? String, "recording_incomplete")
        XCTAssertNotNil(result["video"])
        XCTAssertFalse(source.attached)
    }
    func testNoKeyframeNeverClaimsCompletedMovieAndClockIsRequired() throws {
        let source = RecordingSource(), recorder = fixtureRecorder(root: try root())
        defer { _ = recorder.close() }
        source.configuration["RTPClockRate"] = nil
        XCTAssertThrowsError(try recorder.start(duration: 1, receiver: source, mediaID: "owned", rotation: "rot0"))
        XCTAssertFalse(source.attached)
        source.configuration["RTPClockRate"] = Int32(24000)
        let start = try recorder.start(duration: 1, receiver: source, mediaID: "owned", rotation: "rot0")
        let deadline = Date().addingTimeInterval(3)
        while recorder.isActive, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        let result = try recorder.stop(id: start["recordingID"] as! String)
        XCTAssertEqual(result["state"] as? String, "failed"); XCTAssertFalse(source.attached)
        XCTAssertEqual(result["fileValidated"] as? Bool, false)
    }
}
