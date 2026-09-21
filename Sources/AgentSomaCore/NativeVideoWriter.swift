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

// Compressed HEVC passthrough. No encoder, pixel rotation or synthetic frames.
// Used on the recording queue, never the socket's RTP/RTCP queue.
final class NativeVideoWriter {
    private let url: URL
    let timescale: Int32
    private let orientation: NativeVideoOrientation
    private var parameterSets: [Int: Data] = [:]
    private var format: CMVideoFormatDescription?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var lastTimestamp: UInt32?
    private var ticks: Int64 = 0
    private var pending: (nals: [Data], time: CMTime, keyframe: Bool)?
    private(set) var frames = 0
    var hasFrame: Bool { pending != nil }

    init(url: URL, timescale: Int32, orientation: NativeVideoOrientation = .portrait) {
        self.url = url; self.timescale = timescale; self.orientation = orientation
    }

    func append(_ unit: NativeVideoAccessUnit) throws {
        for nal in unit.nals {
            let type = Int((nal[0] >> 1) & 63)
            if (32...34).contains(type) {
                if writer != nil, parameterSets[type] != nal {
                    throw SomaError("recording_format_changed", "HEVC parameter sets changed; this segment ended")
                }
                parameterSets[type] = nal
            }
        }
        let nals = unit.nals.filter { ![32,33,34].contains(Int(($0[0] >> 1) & 63)) }
        guard nals.contains(where: { ($0[0] >> 1) & 63 <= 31 }) else { return }
        if writer == nil {
            guard unit.keyframe, let vps = parameterSets[32], let sps = parameterSets[33], let pps = parameterSets[34] else { return }
            var description: CMVideoFormatDescription?
            let status = vps.withUnsafeBytes { v in sps.withUnsafeBytes { s in pps.withUnsafeBytes { p in
                let pointers = [v.baseAddress!.assumingMemoryBound(to: UInt8.self), s.baseAddress!.assumingMemoryBound(to: UInt8.self), p.baseAddress!.assumingMemoryBound(to: UInt8.self)]
                let sizes = [vps.count, sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 3,
                    parameterSetPointers: pointers, parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description)
            } } }
            guard status == noErr, let description else { throw SomaError("recording_format_invalid", "Cannot create HEVC format (\(status))") }
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: description)
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            input.transform = orientation.transform(width: CGFloat(dimensions.width), height: CGFloat(dimensions.height))
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw SomaError("recording_writer_failed", "Cannot add HEVC track") }
            writer.add(input)
            guard writer.startWriting() else { throw writer.error ?? SomaError("recording_writer_failed", "Cannot start MP4") }
            writer.startSession(atSourceTime: .zero)
            self.writer = writer; self.input = input; format = description
        }
        if let lastTimestamp {
            let delta = Int32(bitPattern: unit.timestamp &- lastTimestamp)
            guard delta > 0, delta < timescale * 30 else { throw SomaError("recording_timestamp_invalid", "Non-monotonic or discontinuous video timestamp") }
            ticks += Int64(delta)
        }
        let time = CMTime(value: ticks, timescale: timescale)
        if let pending { try write(pending, duration: CMTimeSubtract(time, pending.time)) }
        pending = (nals, time, unit.keyframe); lastTimestamp = unit.timestamp
    }

    private func write(_ frame: (nals: [Data], time: CMTime, keyframe: Bool), duration: CMTime) throws {
        guard let input, let writer, let format else { return }
        guard input.isReadyForMoreMediaData else { throw SomaError("recording_backpressure", "MP4 writer cannot keep up; no RTP queue was blocked") }
        var avcc = Data()
        for nal in frame.nals {
            var size = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &size) { avcc.append(contentsOf: $0) }; avcc.append(nal)
        }
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &block)
        guard status == noErr, let block else { throw SomaError("recording_sample_failed", "Cannot allocate video sample") }
        status = avcc.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count) }
        guard status == noErr else { throw SomaError("recording_sample_failed", "Cannot copy video sample") }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: frame.time, decodeTimeStamp: frame.time)
        var size = avcc.count, sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw SomaError("recording_sample_failed", "Cannot create video sample") }
        // Keep dictionary identity explicit when attaching dependency flags to
        // the sample; ordinary frames must never become random-access entries.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
              CFArrayGetCount(attachments) == 1 else { throw SomaError("recording_sample_failed", "Missing sample attachments") }
        let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        for key in [kCMSampleAttachmentKey_NotSync, kCMSampleAttachmentKey_DependsOnOthers] {
            CFDictionarySetValue(attachment, Unmanaged.passUnretained(key).toOpaque(),
                Unmanaged.passUnretained(frame.keyframe ? kCFBooleanFalse : kCFBooleanTrue).toOpaque())
        }
        guard input.append(sample) else { throw writer.error ?? SomaError("recording_writer_failed", "Cannot append compressed video") }
        frames += 1
    }

    func finish() throws {
        guard let writer, let input, let pending else { throw SomaError("recording_no_keyframe", "No complete HEVC IDR with VPS/SPS/PPS was received") }
        try write(pending, duration: CMTime(value: 1, timescale: 60)); self.pending = nil
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        guard done.wait(timeout: .now() + 10) == .success else { writer.cancelWriting(); throw SomaError("recording_finalize_timeout", "MP4 finalization timed out") }
        guard writer.status == .completed else { throw writer.error ?? SomaError("recording_writer_failed", "MP4 finalization failed") }
    }
    func cancel() { writer?.cancelWriting() }
}
