import Foundation
import VideoToolbox
@testable import IPhoneUseCore

// Ordinary Apple-encoded host fixtures, intentionally separate from the
// production DisplayService VRA decoder. Never linked into the CLI.
final class FixtureHEVCDecoder {
    private var parameterSets: [Int: Data] = [:]
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?

    func decode(_ unit: NativeVideoAccessUnit) throws -> CVPixelBuffer? {
        var changed = false
        for nal in unit.nals {
            let type = Int((nal[0] >> 1) & 63)
            if (32...34).contains(type) {
                if parameterSets[type] != nal { changed = true }
                parameterSets[type] = nal
            }
        }
        if changed { invalidate() }
        let nals = unit.nals.filter { ![32, 33, 34].contains(Int(($0[0] >> 1) & 63)) }
        guard nals.contains(where: { ($0[0] >> 1) & 63 <= 31 }) else { return nil }
        if session == nil {
            guard unit.keyframe, let vps = parameterSets[32], let sps = parameterSets[33], let pps = parameterSets[34] else { return nil }
            let status = vps.withUnsafeBytes { v in sps.withUnsafeBytes { s in pps.withUnsafeBytes { p in
                let pointers = [v.baseAddress!.assumingMemoryBound(to: UInt8.self), s.baseAddress!.assumingMemoryBound(to: UInt8.self), p.baseAddress!.assumingMemoryBound(to: UInt8.self)]
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 3,
                    parameterSetPointers: pointers, parameterSetSizes: [vps.count, sps.count, pps.count],
                    nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
            } } }
            guard status == noErr, let format else { throw invalid("HEVC format", status) }
            let size = CMVideoFormatDescriptionGetDimensions(format)
            guard size.width > 0, size.height > 0, size.width <= 4096, size.height <= 4096 else {
                throw invalid("Unsupported decoded dimensions", -1)
            }
            let statusCreate = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format,
                decoderSpecification: nil,
                imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary,
                outputCallback: nil, decompressionSessionOut: &session)
            guard statusCreate == noErr else { throw invalid("HEVC decoder", statusCreate) }
        }
        guard let session, let format else { return nil }
        var bytes = Data()
        for nal in nals {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }; bytes.append(nal)
        }
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &block)
        guard status == noErr, let block else { throw invalid("Sample allocation", status) }
        status = bytes.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count) }
        guard status == noErr else { throw invalid("Sample copy", status) }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: Int64(unit.timestamp), timescale: 90000), decodeTimeStamp: .invalid)
        var size = bytes.count, sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw invalid("Video sample", status) }
        let result = Output()
        status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { code, flags, image, _, _ in
            result.lock.lock(); result.status = code; result.flags = flags; result.pixels = image; result.lock.unlock()
        }
        guard status == noErr else { throw invalid("Frame decode", status) }
        status = VTDecompressionSessionWaitForAsynchronousFrames(session)
        guard status == noErr else { throw invalid("Frame completion", status) }
        result.lock.lock(); defer { result.lock.unlock() }
        guard result.status == noErr, !result.flags.contains(.frameDropped), let pixels = result.pixels else {
            throw invalid("Decoded frame unavailable (flags \(result.flags.rawValue))", result.status)
        }
        return pixels
    }
    private final class Output {
        let lock = NSLock()
        var status: OSStatus = -1
        var pixels: CVPixelBuffer?
        var flags: VTDecodeInfoFlags = []
    }
    func resetReferences() { invalidate() }
    private func invalid(_ operation: String, _ status: OSStatus) -> IPhoneUseError {
        IPhoneUseError("native_snapshot_decode_failed", "\(operation) failed (\(status))")
    }
    private func invalidate() { if let session { VTDecompressionSessionInvalidate(session) }; session = nil; format = nil }
    deinit { invalidate() }
}
