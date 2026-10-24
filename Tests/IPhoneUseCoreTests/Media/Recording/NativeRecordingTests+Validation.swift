import XCTest
import AVFoundation
import CoreVideo
import Darwin
@testable import IPhoneUseCore

extension NativeRecordingTests {
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
        XCTAssertEqual((try XCTUnwrap(result["durationSeconds"] as? Double)), 1.916666, accuracy: 0.001)
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: asset.tracks(withMediaType: .video)[0], outputSettings: nil)
        reader.add(output); XCTAssertTrue(reader.startReading())
        var index = 0
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) == 0 { continue }
            let attachments = try XCTUnwrap(
                CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]])
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
            throw XCTSkip(
                "Set IPHONE_USE_LONG_RECORDING_FIXTURE to a 1–5 minute screen.mp4 with its result.json")
        }
        let url = URL(fileURLWithPath: path)
        let recorded = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent("result.json")))
                as? [String: Any])
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
                try writer.appendDecoded(
                    pixels, seconds: delay + Double(index) / 30, receivedAt: 100 + delay + Double(index) / 30)
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
            XCTAssertEqual(
                CGPoint(x: 64, y: 96).applying(transform),
                orientation == .left ? CGPoint(x: 0, y: 64) : CGPoint(x: 96, y: 0))
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            let image = try generator.copyCGImage(at: CMTime(value: 1, timescale: 1), actualTime: nil)
            XCTAssertEqual(image.width, 96); XCTAssertEqual(image.height, 64)
        }
        let source = RecordingSource(),
            recorder = fixtureRecorder(root: dir.appendingPathComponent("unsupported"))
        defer { _ = recorder.close() }
        XCTAssertThrowsError(
            try recorder.start(duration: 3, receiver: source, mediaID: "owned", rotation: "rot180"))
        XCTAssertFalse(source.attached)
    }

    func testOwnedStopCannotStopNewRecordingAndCloseDetachesSink() throws {
        let dir = try root(), units = try fixture(dir), source = RecordingSource()
        let recorder = fixtureRecorder(root: dir.appendingPathComponent("owned"))
        defer { _ = recorder.close() }
        let first = try recorder.start(duration: 30, receiver: source, mediaID: "owned", rotation: "rot0")
        XCTAssertTrue(source.attached); XCTAssertGreaterThan(source.keyframeRequests, 0)
        XCTAssertThrowsError(
            try recorder.start(duration: 30, receiver: source, mediaID: "owned", rotation: "rot0"))
        XCTAssertThrowsError(try recorder.stop(id: "foreign"))
        packets(units, to: source)
        let stopped = try recorder.stop(id: (try XCTUnwrap(first["recordingID"] as? String)))
        XCTAssertEqual(stopped["state"] as? String, "completed")
        XCTAssertEqual(stopped["writtenFrames"] as? Int, 20)
        XCTAssertFalse(source.attached)
        let second = try recorder.start(duration: 30, receiver: source, mediaID: "owned", rotation: "rot0")
        _ = try recorder.stop(id: (try XCTUnwrap(first["recordingID"] as? String)))
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
        XCTAssertThrowsError(
            try recorder.start(duration: 1, receiver: source, mediaID: "owned", rotation: "rot0"))
    }
    func testMissingEndOfFramePreservesPartialFileButCannotClaimCompletion() throws {
        let dir = try root(), units = try fixture(dir), source = RecordingSource()
        let recorder = fixtureRecorder(root: dir.appendingPathComponent("loss"))
        defer { _ = recorder.close() }
        let start = try recorder.start(duration: 30, receiver: source, mediaID: "owned", rotation: "rot0")
        packets(units, to: source, omitMarkerAt: units[1].timestamp)
        let result = try recorder.stop(id: (try XCTUnwrap(start["recordingID"] as? String)))
        XCTAssertEqual(result["state"] as? String, "failed")
        XCTAssertEqual((result["error"] as? [String: Any])?["code"] as? String, "recording_incomplete")
        XCTAssertNotNil(result["video"])
        XCTAssertFalse(source.attached)
    }
    func testNoKeyframeNeverClaimsCompletedMovieAndClockIsRequired() throws {
        let source = RecordingSource(), recorder = fixtureRecorder(root: try root())
        defer { _ = recorder.close() }
        source.configuration["RTPClockRate"] = nil
        XCTAssertThrowsError(
            try recorder.start(duration: 1, receiver: source, mediaID: "owned", rotation: "rot0"))
        XCTAssertFalse(source.attached)
        source.configuration["RTPClockRate"] = Int32(24000)
        let start = try recorder.start(duration: 1, receiver: source, mediaID: "owned", rotation: "rot0")
        let deadline = Date().addingTimeInterval(3)
        while recorder.isActive, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        let result = try recorder.stop(id: (try XCTUnwrap(start["recordingID"] as? String)))
        XCTAssertEqual(result["state"] as? String, "failed"); XCTAssertFalse(source.attached)
        XCTAssertEqual(result["fileValidated"] as? Bool, false)
    }
}
