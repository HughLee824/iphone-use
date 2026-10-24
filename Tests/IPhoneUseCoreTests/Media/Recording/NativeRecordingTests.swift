import XCTest
import AVFoundation
import CoreVideo
import Darwin
@testable import IPhoneUseCore

final class RecordingSource: NativeRecordingSource {
    let lock = NSLock()
    var handler: ((Data) -> Void)?
    var healthy = true
    var configuration: [String: Any] = [
        "RxPayloadType": 100, "TilesPerFrame": 1, "SRTPCipherSuite": 0, "RTPClockRate": Int32(24000),
        "LocalSSRC": 123
    ]
    private(set) var keyframeRequests = 0
    func recordingConfiguration() -> [String: Any] { configuration }
    func setVideoHandler(_ handler: ((Data) -> Void)?) { lock.lock(); self.handler = handler; lock.unlock() }
    func requestKeyframe() { keyframeRequests += 1 }
    func health() -> [String: Any] { lock.lock(); defer { lock.unlock() }; return ["healthy": healthy] }
    func setHealthy(_ value: Bool) { lock.lock(); healthy = value; lock.unlock() }
    var attached: Bool { lock.lock(); defer { lock.unlock() }; return handler != nil }
    func send(_ data: Data) { lock.lock(); let callback = handler; lock.unlock(); callback?(data) }
}

final class RecordingTestClock {
    let lock = NSLock()
    var value = 100.0
    func now() -> Double { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: Double) { lock.lock(); self.value = value; lock.unlock() }
}

final class NativeRecordingTests: XCTestCase {

    // Generic HEVC fixtures test recording timing/ownership and transport. They
    // do not pretend to exercise Apple's VRA codec profile. The actual
    // VRA decoder is separately verified using the recorded fault stream.
    func fixtureWriter(url: URL, timescale: Int32, orientation: NativeVideoOrientation = .portrait)
        -> NativeVideoWriter {
        let decoder = FixtureHEVCDecoder()
        return NativeVideoWriter(
            url: url, timescale: timescale, orientation: orientation, decode: { try decoder.decode($0) })
    }
    func fixtureRecorder(
        root: URL, now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
        onFinish: @escaping (String, String) -> Void = { _, _ in }
    ) -> NativeStreamRecording {
        NativeStreamRecording(
            root: root, now: now, onFinish: onFinish,
            makeWriter: { self.fixtureWriter(url: $0, timescale: $1, orientation: $2) })
    }
    func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "recording-test-\(UUID().uuidString)")
        try SessionPaths.secureDirectory(root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    // Generate actual HEVC with Apple's encoder, including inter-frame samples.
    // No captured device data or third-party codec fixture is needed.
    func fixture(_ root: URL) throws -> [NativeVideoAccessUnit] {
        let url = root.appendingPathComponent("fixture.mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: 64, AVVideoHeightKey: 96,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAllowFrameReorderingKey: false, AVVideoMaxKeyFrameIntervalKey: 10
                ]
            ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 96
            ])
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for frame in 0..<20 {
            let deadline = Date().addingTimeInterval(2)
            while !input.isReadyForMoreMediaData, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            XCTAssertTrue(input.isReadyForMoreMediaData)
            var buffer: CVPixelBuffer?
            XCTAssertEqual(
                CVPixelBufferCreate(kCFAllocatorDefault, 64, 96, kCVPixelFormatType_32BGRA, nil, &buffer),
                kCVReturnSuccess)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(
                CVPixelBufferGetBaseAddress(pixels), Int32(frame * 10),
                CVPixelBufferGetBytesPerRow(pixels) * 96)
            CVPixelBufferUnlockBaseAddress(pixels, [])
            XCTAssertTrue(
                adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)))
        }
        input.markAsFinished()
        let finished = expectation(description: "movie finished")
        writer.finishWriting { finished.fulfill() }; wait(for: [finished], timeout: 5)
        XCTAssertEqual(writer.status, .completed)
        return try readFixture(url)
    }
    func packets(
        _ units: [NativeVideoAccessUnit], to source: RecordingSource, omitMarkerAt: UInt32? = nil,
        beforeUnit: ((NativeVideoAccessUnit) -> Void)? = nil
    ) {
        var sequence: UInt16 = 1
        for unit in units {
            beforeUnit?(unit)
            for (index, nal) in unit.nals.enumerated() {
                var packet = Data([
                    0x80, index == unit.nals.count - 1 && unit.timestamp != omitMarkerAt ? 0xe4 : 0x64,
                    UInt8(sequence >> 8), UInt8(sequence & 255)
                ])
                for value in [unit.timestamp, UInt32(123)] {
                    var big = value.bigEndian; withUnsafeBytes(of: &big) { packet.append(contentsOf: $0) }
                }
                packet.append(nal); source.send(packet); sequence &+= 1
            }
        }
    }
    private func readFixture(_ url: URL) throws -> [NativeVideoAccessUnit] {
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: asset.tracks(withMediaType: .video)[0], outputSettings: nil)
        reader.add(output); XCTAssertTrue(reader.startReading())
        var units: [NativeVideoAccessUnit] = []
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) == 0 { continue }
            let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
            var nals: [Data] = []
            for index in 0..<3 {
                var pointer: UnsafePointer<UInt8>?, size = 0
                XCTAssertEqual(
                    CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                        format, parameterSetIndex: index,
                        parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                        parameterSetCountOut: nil,
                        nalUnitHeaderLengthOut: nil), noErr)
                nals.append(Data(bytes: try XCTUnwrap(pointer), count: size))
            }
            let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
            var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
            XCTAssertEqual(
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: &bytes),
                noErr)
            var offset = 0
            while offset < bytes.count {
                let length = bytes[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }; offset += 4
                nals.append(Data(bytes[offset..<offset + length])); offset += length
            }
            let sync = nals.contains { [19, 20].contains(Int(($0[0] >> 1) & 63)) }
            units.append(
                NativeVideoAccessUnit(timestamp: UInt32(units.count * 2400), nals: nals, keyframe: sync))
        }
        XCTAssertEqual(reader.status, .completed); XCTAssertEqual(units.count, 20)
        XCTAssertTrue(units[0].keyframe); XCTAssertFalse(units[1].keyframe)
        return units
    }

    func fixtureSnapshots() -> NativeVideoSnapshot {
        let decoder = FixtureHEVCDecoder()
        return NativeVideoSnapshot(
            decode: { unit in
                try decoder.decode(unit).map {
                    NativeDecodedVideoFrame(pixels: $0, nativeWidth: 64, nativeHeight: 96)
                }
            }, resetDecoder: { decoder.resetReferences() })
    }

}
