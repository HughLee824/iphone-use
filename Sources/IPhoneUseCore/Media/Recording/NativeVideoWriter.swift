import Foundation
import AVFoundation

enum NativeVideoOrientation: String {
    case portrait = "rot0", left = "rot90", right = "rot270"

    func transform(width: CGFloat, height: CGFloat) -> CGAffineTransform {
        switch self {
        case .portrait: return .identity
        case .left: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: height, ty: 0)
        case .right: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: width)
        }
    }
}

// Decode Apple VRA before encoding portable HEVC. No pixel rotation or synthetic frames.
// Used on the recording queue, never the socket's RTP/RTCP queue.
final class NativeVideoWriter {
    private let url: URL
    let timescale: Int32
    private let orientation: NativeVideoOrientation
    private var parameterSets: [Int: Data] = [:]
    private let decoder = NativeSnapshotDecoder()
    private let injectedDecode: ((NativeVideoAccessUnit) throws -> CVPixelBuffer?)?
    private let beforeEncoderSetup: () -> Void
    private var format: CMVideoFormatDescription?
    var withheldResolutionFrames: Int { decoder.withheldResolutionFrames }
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var lastDecodedTimestamp: UInt32?
    private var lastTimestamp: UInt32?
    private var ticks: Int64 = 0
    private var pending: (pixels: CVPixelBuffer, time: CMTime)?
    private var closed = false
    private(set) var frames = 0
    private(set) var firstFrameReceivedAt: Double?
    private(set) var lastFrameReceivedAt: Double?
    private(set) var encoderSetupMilliseconds = 0.0
    private(set) var maximumAppendMilliseconds = 0.0
    var mediaSpanSeconds: Double { Double(ticks) / Double(timescale) }
    var hasFrame: Bool { pending != nil }

    init(
        url: URL, timescale: Int32, orientation: NativeVideoOrientation = .portrait,
        decode: ((NativeVideoAccessUnit) throws -> CVPixelBuffer?)? = nil,
        beforeEncoderSetup: @escaping () -> Void = {}
    ) {
        self.url = url; self.timescale = timescale; self.orientation = orientation; injectedDecode = decode
        self.beforeEncoderSetup = beforeEncoderSetup
    }

    func append(_ unit: NativeVideoAccessUnit) throws {
        guard !closed else {
            throw IPhoneUseError("recording_writer_closed", "Recording encoder has been released")
        }
        guard unit.nals.allSatisfy({ $0.count >= 2 }) else {
            throw IPhoneUseError("recording_format_invalid", "Truncated video NAL")
        }
        try updateParameterSets(unit.nals)
        let video = unit.nals.contains(where: { ($0[0] >> 1) & 63 <= 31 })
        if video, let lastDecodedTimestamp {
            let delta = Int32(bitPattern: unit.timestamp &- lastDecodedTimestamp)
            guard delta > 0, delta < timescale * 30 else {
                throw IPhoneUseError(
                    "recording_timestamp_invalid", "Non-monotonic or discontinuous decoder timestamp")
            }
        }
        let pixels: CVPixelBuffer?
        if let injectedDecode {
            pixels = try injectedDecode(unit)
        } else {
            pixels = try decoder.decode(unit)?.pixels
        }
        if video { lastDecodedTimestamp = unit.timestamp }
        guard let pixels else { return }
        if let lastTimestamp {
            let delta = Int32(bitPattern: unit.timestamp &- lastTimestamp)
            guard delta > 0, delta < timescale * 30 else {
                throw IPhoneUseError(
                    "recording_timestamp_invalid", "Non-monotonic or discontinuous video timestamp")
            }
            ticks += Int64(delta)
        }
        try appendPixels(
            pixels, time: CMTime(value: ticks, timescale: timescale), receivedAt: unit.firstPacketAt)
        lastTimestamp = unit.timestamp
    }

    private func updateParameterSets(_ nals: [Data]) throws {
        for nal in nals {
            let type = Int((nal[0] >> 1) & 63)
            if (32...34).contains(type) {
                if writer != nil, parameterSets[type] != nal {
                    throw IPhoneUseError(
                        "recording_format_changed", "HEVC parameter sets changed; this segment ended")
                }
                parameterSets[type] = nal
            }
        }
    }

    // The existing stream has already decoded these reference-dependent pictures.
    // Starting a writer from pixels needs no new device keyframe or stream restart.
    func appendDecoded(_ pixels: CVPixelBuffer, seconds: Double, receivedAt: Double) throws {
        guard seconds.isFinite, seconds >= 0 else {
            throw IPhoneUseError("recording_timestamp_invalid", "Invalid decoded frame time")
        }
        let time = CMTime(seconds: seconds, preferredTimescale: timescale)
        try appendPixels(pixels, time: time, receivedAt: receivedAt)
        ticks = time.value
    }

    // Prepare before subscribing to shared pixels: cold encoder startup must not
    // accumulate full-resolution buffers behind a blocked recording queue.
    func prepare(_ pixels: CVPixelBuffer) throws {
        guard !closed else {
            throw IPhoneUseError("recording_writer_closed", "Recording encoder has been released")
        }
        if writer == nil {
            let started = ProcessInfo.processInfo.systemUptime
            beforeEncoderSetup()
            var description: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: pixels,
                formatDescriptionOut: &description)
            guard status == noErr, let description else {
                throw IPhoneUseError("recording_format_invalid", "Cannot describe decoded video (\(status))")
            }
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
            let input = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height,
                    AVVideoCompressionPropertiesKey: [
                        AVVideoAllowFrameReorderingKey: false, AVVideoMaxKeyFrameIntervalKey: 60
                    ]
                ], sourceFormatHint: description)
            input.transform = orientation.transform(width: CGFloat(width), height: CGFloat(height))
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                throw IPhoneUseError("recording_writer_failed", "Cannot add encoded video track")
            }
            writer.add(input)
            guard writer.startWriting() else {
                throw writer.error ?? IPhoneUseError("recording_writer_failed", "Cannot start MP4")
            }
            writer.startSession(atSourceTime: .zero)
            self.writer = writer; self.input = input; format = description
            encoderSetupMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
        }
        if let format {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            guard Int(dimensions.width) == CVPixelBufferGetWidth(pixels),
                Int(dimensions.height) == CVPixelBufferGetHeight(pixels)
            else {
                throw IPhoneUseError(
                    "recording_format_changed", "Decoded dimensions changed; this segment ended")
            }
        }
    }

    private func appendPixels(_ pixels: CVPixelBuffer, time: CMTime, receivedAt: Double?) throws {
        try prepare(pixels)
        if let pending {
            guard CMTimeCompare(time, pending.time) > 0 else {
                throw IPhoneUseError("recording_timestamp_invalid", "Non-monotonic decoded frame time")
            }
            try write(pending, duration: CMTimeSubtract(time, pending.time))
        }
        pending = (pixels, time)
        if firstFrameReceivedAt == nil { firstFrameReceivedAt = receivedAt }
        lastFrameReceivedAt = receivedAt
    }

    private func write(_ frame: (pixels: CVPixelBuffer, time: CMTime), duration: CMTime) throws {
        guard let input, let writer, let format else { return }
        let started = ProcessInfo.processInfo.systemUptime
        defer {
            maximumAppendMilliseconds = max(
                maximumAppendMilliseconds, (ProcessInfo.processInfo.systemUptime - started) * 1000)
        }
        // Encoder readiness is bounded on the recording queue, never the RTP
        // socket queue. Overload fails explicitly instead of silently losing frames.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        while !input.isReadyForMoreMediaData, writer.status == .writing,
            ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.002) }
        guard input.isReadyForMoreMediaData else {
            throw IPhoneUseError("recording_backpressure", "Video encoder cannot keep up")
        }
        var timing = CMSampleTimingInfo(
            duration: duration, presentationTimeStamp: frame.time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: frame.pixels,
            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        guard status == noErr, let sample else {
            throw IPhoneUseError("recording_sample_failed", "Cannot create decoded video sample")
        }
        guard input.append(sample) else {
            throw writer.error ?? IPhoneUseError("recording_writer_failed", "Cannot encode video frame")
        }
        frames += 1
    }

    func finish(lastFrameDurationSeconds: Double = 1.0 / 60) throws {
        guard let writer, let input, let pending else {
            throw IPhoneUseError(
                "recording_no_keyframe", "No complete HEVC IDR with VPS/SPS/PPS was received")
        }
        guard lastFrameDurationSeconds.isFinite, lastFrameDurationSeconds > 0, lastFrameDurationSeconds <= 330
        else {
            throw IPhoneUseError("recording_timestamp_invalid", "Invalid final video sample duration")
        }
        // Variable frame rate: keep admitted RTP presentation times intact and hold
        // only the final admitted image. Reduced-resolution pictures are decoded
        // for reference continuity but omitted from presentation, with explicit facts.
        try write(pending, duration: CMTime(seconds: lastFrameDurationSeconds, preferredTimescale: timescale))
        self.pending = nil
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        guard done.wait(timeout: .now() + 10) == .success else {
            writer.cancelWriting()
            throw IPhoneUseError("recording_finalize_timeout", "MP4 finalization timed out")
        }
        guard writer.status == .completed else {
            throw writer.error ?? IPhoneUseError("recording_writer_failed", "MP4 finalization failed")
        }
        releaseEncoder()
    }
    private func releaseEncoder() {
        // Jobs retain their result for idempotent record-stop. They must not
        // retain an encoder/pixel pool while validating or starting a new job.
        closed = true; input = nil; writer = nil; format = nil; pending = nil
        decoder.resetReferences()
    }
    func cancel() { writer?.cancelWriting(); releaseEncoder() }
}
