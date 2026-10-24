import XCTest
import AVFoundation
import CoreVideo
import Darwin
@testable import IPhoneUseCore

extension NativeRecordingTests {
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
        XCTAssertEqual((try XCTUnwrap(result["durationSeconds"] as? Double)), 1.916666, accuracy: 0.001)
        let cold = FixtureHEVCDecoder()
        XCTAssertNil(try cold.decode(units[1]))
    }
    func testWithheldPresentationKeepsTimelineAndRejectsDuplicateDecodedTimestamp() throws {
        let dir = try root(), units = try fixture(dir), decoder = FixtureHEVCDecoder()
        let url = dir.appendingPathComponent("withheld.mp4")
        let writer = NativeVideoWriter(
            url: url, timescale: 24000,
            decode: { unit in
                let pixels = try decoder.decode(unit)
                return unit.timestamp == 24000 ? nil : pixels
            })
        for unit in units { try writer.append(unit) }
        try writer.finish()
        let facts = try NativeRecordingValidation.inspect(url)
        XCTAssertEqual(facts["decodedFrames"] as? Int, 19)
        XCTAssertEqual((try XCTUnwrap(facts["durationSeconds"] as? Double)), 1.916666, accuracy: 0.001)
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: asset.tracks(withMediaType: .video)[0], outputSettings: nil)
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
        let withheld = NativeVideoWriter(
            url: dir.appendingPathComponent("not-created.mp4"), timescale: 24000, decode: { _ in nil })
        try withheld.append(units[0])
        XCTAssertThrowsError(try withheld.append(units[0]))
    }

    func testCapabilityAndDurationFailClosed() throws {
        XCTAssertFalse(NativeRecordingOptions.supported(by: [:]))
        XCTAssertTrue(
            NativeRecordingOptions.supported(by: [
                "capabilities": [["featureIdentifier": "com.apple.coredevice.feature.screenrecording"]]
            ]))
        for value: Any in [true, 0, -1, 301, Double.infinity, "5"] {
            XCTAssertThrowsError(try NativeRecordingOptions.duration(["duration": value]))
        }
        XCTAssertEqual(try NativeRecordingOptions.duration(["duration": 5]), 5)
        let source = RecordingSource()
        XCTAssertTrue(NativeStreamRecording.supports(source.configuration))
        source.configuration["TilesPerFrame"] = 2
        XCTAssertFalse(NativeStreamRecording.supports(source.configuration))
    }
    func testFinalHoldPreservesRTPGapsWrapAndAllOriginalSamples() throws {
        let dir = try root(), units = try fixture(dir), url = dir.appendingPathComponent("held.mp4")
        let writer = fixtureWriter(url: url, timescale: 24000, orientation: .right)
        var expected: [Double] = []
        for (index, unit) in units.enumerated() {
            let ticks = unit.timestamp + (index >= 10 ? 120000 : 0)
            expected.append(Double(ticks) / 24000)
            try writer.append(
                NativeVideoAccessUnit(
                    timestamp: (UInt32.max - 12000) &+ ticks,
                    nals: unit.nals, keyframe: unit.keyframe, firstPacketAt: 101 + Double(ticks) / 24000))
        }
        XCTAssertEqual(writer.mediaSpanSeconds, 6.9, accuracy: 0.0001)
        XCTAssertEqual(writer.firstFrameReceivedAt, 101)
        XCTAssertEqual(writer.lastFrameReceivedAt!, 107.9, accuracy: 0.0001)
        try writer.finish(lastFrameDurationSeconds: 3.1)
        let facts = try NativeRecordingValidation.inspect(url)
        XCTAssertEqual(facts["decodedFrames"] as? Int, 20, "Holding must not invent extra frames")
        XCTAssertEqual((try XCTUnwrap(facts["durationSeconds"] as? Double)), 10, accuracy: 0.001)
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
        let image = try generator.copyCGImage(
            at: CMTime(seconds: 9.5, preferredTimescale: 24000), actualTime: nil)
        XCTAssertEqual(image.width, 96); XCTAssertEqual(image.height, 64)
    }

    func testNormalStopKeepsStaticTailAndInitialKeyframeDelayExplicit() throws {
        let dir = try root(), units = try fixture(dir)
        for automatic in [false, true] {
            let source = RecordingSource(), clock = RecordingTestClock()
            let recorder = fixtureRecorder(
                root: dir.appendingPathComponent("normal-\(automatic)"), now: clock.now)
            defer { _ = recorder.close() }
            // Manual stop must precede the deadline; at exactly 6 seconds the
            // timer is legitimately allowed to win the race with stop().
            let start = try recorder.start(
                duration: automatic ? 6 : 30, receiver: source, mediaID: "owned", rotation: "rot0")
            packets(units, to: source) { clock.set(101 + Double($0.timestamp) / 24000) }
            _ = recorder.status() // Drain all admitted packets before stopping the test clock.
            clock.set(106)
            if automatic {
                let deadline = Date().addingTimeInterval(3)
                while recorder.isActive, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
                XCTAssertFalse(recorder.isActive)
            }
            let result = try recorder.stop(id: (try XCTUnwrap(start["recordingID"] as? String)))
            XCTAssertEqual(result["state"] as? String, "completed")
            XCTAssertEqual(result["stopReason"] as? String, automatic ? "duration" : "requested")
            XCTAssertEqual((try XCTUnwrap(result["elapsedSeconds"] as? Double)), 6, accuracy: 0.0001)
            XCTAssertEqual((try XCTUnwrap(result["firstFrameDelaySeconds"] as? Double)), 1, accuracy: 0.0001)
            XCTAssertEqual(
                (try XCTUnwrap(result["frameReceiveSpanSeconds"] as? Double)), 1.9, accuracy: 0.0001)
            XCTAssertEqual((try XCTUnwrap(result["mediaSpanSeconds"] as? Double)), 1.9, accuracy: 0.0001)
            XCTAssertEqual(
                (try XCTUnwrap(result["lastFrameDurationSeconds"] as? Double)), 3.1, accuracy: 0.0001)
            XCTAssertEqual(result["tailTimingSource"] as? String, "host_monotonic_receive")
            let video = try XCTUnwrap(result["video"] as? [String: Any])
            XCTAssertEqual((try XCTUnwrap(video["durationSeconds"] as? Double)), 5, accuracy: 0.001)
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
            let result = try recorder.stop(id: (try XCTUnwrap(start["recordingID"] as? String)))
            XCTAssertEqual(result["tailTimingSource"] as? String, "nominal_frame_duration")
            XCTAssertEqual(
                (try XCTUnwrap(result["lastFrameDurationSeconds"] as? Double)), 1.0 / 60, accuracy: 0.0001)
            XCTAssertEqual(
                (try XCTUnwrap((result["video"] as? [String: Any])?["durationSeconds"] as? Double)), 1.916666,
                accuracy: 0.001)
            if ["media_lost", "packet_loss", "queue_overflow"].contains(cause) {
                XCTAssertEqual(result["state"] as? String, "failed")
                XCTAssertEqual(result["fileValidated"] as? Bool, false)
            }
            XCTAssertFalse(source.attached)
        }
    }
}
