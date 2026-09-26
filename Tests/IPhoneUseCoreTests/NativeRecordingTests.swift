import XCTest
import AVFoundation
import CoreVideo
import Darwin
@testable import IPhoneUseCore

private final class RecordingSource: NativeRecordingSource {
    private let lock = NSLock()
    private var handler: ((Data) -> Void)?
    var configuration: [String: Any] = ["RxPayloadType": 100, "TilesPerFrame": 1, "SRTPCipherSuite": 0, "RTPClockRate": Int32(24000), "LocalSSRC": 123]
    private(set) var keyframeRequests = 0
    func recordingConfiguration() -> [String: Any] { configuration }
    func setVideoHandler(_ handler: ((Data) -> Void)?) { lock.lock(); self.handler = handler; lock.unlock() }
    func requestKeyframe() { keyframeRequests += 1 }
    func health() -> [String: Any] { ["healthy": true] }
    var attached: Bool { lock.lock(); defer { lock.unlock() }; return handler != nil }
    func send(_ data: Data) { lock.lock(); let callback = handler; lock.unlock(); callback?(data) }
}

final class NativeRecordingTests: XCTestCase {
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
        let receiver = try NativeRTPReceiver(deviceAddress: "::1", captureSnapshots: true)
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
    func testSnapshotDecoderReadsRealHEVCWithoutChangingRecordingOutput() throws {
        let dir = try root(), units = try fixture(dir)
        let writer = NativeVideoWriter(url: dir.appendingPathComponent("with-snapshots.mp4"), timescale: 24000)
        let decoder = NativeSnapshotDecoder()
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
        let cold = NativeSnapshotDecoder()
        XCTAssertNil(try cold.decode(units[1]))
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
    private func packets(_ units: [NativeVideoAccessUnit], to source: RecordingSource, omitMarkerAt: UInt32? = nil) {
        var sequence: UInt16 = 1
        for unit in units {
            for (index, nal) in unit.nals.enumerated() {
                var packet = Data([0x80, index == unit.nals.count - 1 && unit.timestamp != omitMarkerAt ? 0xe4 : 0x64, UInt8(sequence >> 8), UInt8(sequence & 255)])
                for value in [unit.timestamp, UInt32(123)] { var big = value.bigEndian; withUnsafeBytes(of: &big) { packet.append(contentsOf: $0) } }
                packet.append(nal); source.send(packet); sequence &+= 1
            }
        }
    }
    func testHEVCMuxKeepsSyncIndexAndSupportsRandomSeek() throws {
        let dir = try root(), units = try fixture(dir), url = dir.appendingPathComponent("remux.mp4")
        let writer = NativeVideoWriter(url: url, timescale: 24000)
        for unit in units { try writer.append(unit) }
        try writer.finish()
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
            XCTAssertEqual(notSync, !units[index].keyframe, "sample \(index)")
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
    func testLandscapeTrackTransformSurvivesMuxAndExactFrameExtraction() throws {
        let dir = try root(), units = try fixture(dir)
        for orientation in [NativeVideoOrientation.left, .right] {
            let url = dir.appendingPathComponent("\(orientation.rawValue).mp4")
            let writer = NativeVideoWriter(url: url, timescale: 24000, orientation: orientation)
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
        let source = RecordingSource(), recorder = NativeStreamRecording(root: dir.appendingPathComponent("unsupported"))
        defer { _ = recorder.close() }
        XCTAssertThrowsError(try recorder.start(duration: 3, receiver: source, mediaID: "owned", rotation: "rot180"))
        XCTAssertFalse(source.attached)
    }

    func testOwnedStopCannotStopNewRecordingAndCloseDetachesSink() throws {
        let dir = try root(), units = try fixture(dir), source = RecordingSource()
        let recorder = NativeStreamRecording(root: dir.appendingPathComponent("owned"))
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
        let recorder = NativeStreamRecording(root: dir.appendingPathComponent("loss"))
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
        let source = RecordingSource(), recorder = NativeStreamRecording(root: try root())
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
