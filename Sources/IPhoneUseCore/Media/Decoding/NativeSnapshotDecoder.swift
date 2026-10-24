import Foundation
import VideoToolbox
import CoreImage

// Apple VideoToolbox owns HEVC decoding. Only complete dependency-checked units
// from the existing RFC 7798 parser reach this decoder.
final class NativeSnapshotDecoder {
    private var parameterSets: [Int: Data] = [:]
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var nativeDimensions: (Int, Int)?
    private(set) var withheldResolutionFrames = 0
    private let convertToBGRA: Bool
    private let includeReducedResolution: Bool
    private static let context = CIContext(options: [.cacheIntermediates: false])

    // Recording retains the existing presentation path by default. Geometry
    // consumers opt out of color conversion, not decoding or frame validation.
    init(convertToBGRA: Bool = true, includeReducedResolution: Bool = false) {
        self.convertToBGRA = convertToBGRA; self.includeReducedResolution = includeReducedResolution
    }

    func decode(_ unit: NativeVideoAccessUnit) throws -> NativeDecodedVideoFrame? {
        // No reference chain survives a failed metadata/configuration/decode step.
        do { return try decodeFrame(unit) } catch { invalidate(); throw error }
    }

    private func decodeFrame(_ unit: NativeVideoAccessUnit) throws -> NativeDecodedVideoFrame? {
        guard #available(macOS 15.0, *) else { throw invalid("VRA decoding requires macOS 15 or later", -1) }
        guard unit.nals.allSatisfy({ $0.count >= 2 }) else { throw invalid("Truncated NAL", -1) }
        updateParameterSets(unit.nals)
        let nals = unit.nals.filter { ![32, 33, 34].contains(Int(($0[0] >> 1) & 63)) }
        guard nals.contains(where: { ($0[0] >> 1) & 63 <= 31 }) else { return nil }
        let metadata = try NativeVideoFrameMetadata(nals: nals)
        if session == nil, try !createSession(keyframe: unit.keyframe) { return nil }
        guard let session, let format else { return nil }
        let canvas = CMVideoFormatDescriptionGetDimensions(format)
        try metadata.validate(canvas: canvas)
        if let nativeDimensions, nativeDimensions != (metadata.nativeWidth, metadata.nativeHeight) {
            throw invalid("Native rectangle changed within a reference chain", -1)
        }
        nativeDimensions = (metadata.nativeWidth, metadata.nativeHeight)
        let sample = try makeSample(nals, timestamp: unit.timestamp, format: format)
        let result = Output()
        var status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [],
            frameOptions: [
                "ActiveVideoResolution": ["Width": metadata.activeWidth, "Height": metadata.activeHeight]
            ]
                as CFDictionary,
            infoFlagsOut: nil
        ) { code, flags, image, _, _ in
            result.lock.lock(); result.status = code; result.flags = flags; result.pixels = image
            result.lock.unlock()
        }
        guard status == noErr else { throw invalid("Frame decode", status) }
        status = VTDecompressionSessionWaitForAsynchronousFrames(session)
        guard status == noErr else { throw invalid("Frame completion", status) }
        result.lock.lock(); defer { result.lock.unlock() }
        guard result.status == noErr, !result.flags.contains(.frameDropped), let pixels = result.pixels else {
            throw invalid("Decoded frame unavailable (flags \(result.flags.rawValue))", result.status)
        }
        guard CVPixelBufferGetWidth(pixels) == Int(canvas.width),
            CVPixelBufferGetHeight(pixels) == Int(canvas.height)
        else {
            throw invalid("Unexpected decoder output geometry", -1)
        }
        return try presentedFrame(pixels, metadata: metadata, canvas: canvas)
    }

    private func updateParameterSets(_ nals: [Data]) {
        var changed = false
        for nal in nals {
            let type = Int((nal[0] >> 1) & 63)
            if (32...34).contains(type) {
                if parameterSets[type] != nal { changed = true }
                parameterSets[type] = nal
            }
        }
        if changed { invalidate() }
    }

    private func presentedFrame(
        _ pixels: CVPixelBuffer, metadata: NativeVideoFrameMetadata,
        canvas: CMVideoDimensions
    ) throws -> NativeDecodedVideoFrame? {
        // Always decode reference pictures. Only the browser preview opts into
        // raw reduced pictures and normalizes their active rectangle for display.
        if !metadata.hasFullResolution(canvas: canvas), !includeReducedResolution {
            withheldResolutionFrames += 1; return nil
        }
        guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        else {
            throw invalid("Unexpected decoder output pixel format", -1)
        }
        if !convertToBGRA {
            return NativeDecodedVideoFrame(
                pixels: pixels, nativeWidth: metadata.nativeWidth, nativeHeight: metadata.nativeHeight,
                activeWidth: metadata.activeWidth, activeHeight: metadata.activeHeight)
        }
        var bgra: CVPixelBuffer?
        let created = CVPixelBufferCreate(
            kCFAllocatorDefault, Int(canvas.width), Int(canvas.height), kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &bgra)
        guard created == kCVReturnSuccess, let bgra else { throw invalid("BGRA allocation", created) }
        Self.context.render(CIImage(cvPixelBuffer: pixels), to: bgra)
        // Metadata syntax, canvas bounds and reference-chain consistency were
        // validated above. Decoded padding may contain lossy edge data; it must
        // not invalidate otherwise complete reference pictures. Observation
        // additionally checks this exact rectangle against Apple display facts.
        return NativeDecodedVideoFrame(
            pixels: bgra, nativeWidth: metadata.nativeWidth, nativeHeight: metadata.nativeHeight,
            activeWidth: metadata.activeWidth, activeHeight: metadata.activeHeight)
    }
    private func createSession(keyframe: Bool) throws -> Bool {
        guard keyframe, let vps = parameterSets[32], let sps = parameterSets[33], let pps = parameterSets[34]
        else { return false }
        let format = try makeFormat(vps: vps, sps: sps, pps: pps)
        let size = CMVideoFormatDescriptionGetDimensions(format)
        guard size.width > 0, size.height > 0, size.width <= 4096, size.height <= 4096 else {
            throw invalid("Unsupported decoded dimensions", -1)
        }
        let statusCreate = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: format,
            decoderSpecification: [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true]
                as CFDictionary,
            imageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ] as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &session)
        guard statusCreate == noErr, let session else { throw invalid("HEVC decoder", statusCreate) }
        // Private Apple values verified by same-stream positive/negative
        // controls. Never fall back to ordinary HEVC on unsupported hosts.
        for (key, value): (String, CFTypeRef) in [
            ("DecoderUsage", NSNumber(value: 1)),
            ("VideoResolutionAdaptationType", NSNumber(value: 3)),
            ("NegotiationDetails", "RVRA1:0" as CFString)
        ] {
            let status = VTSessionSetProperty(session, key: key as CFString, value: value)
            guard status == noErr else { throw invalid(key, status) }
        }
        var hardware: CFTypeRef?
        let statusHardware = VTSessionCopyProperty(
            session, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
            allocator: nil, valueOut: &hardware)
        guard statusHardware == noErr, hardware as? Bool == true else {
            throw invalid("Hardware decoder unavailable", statusHardware)
        }
        return true
    }

    private func makeFormat(vps: Data, sps: Data, pps: Data) throws -> CMVideoFormatDescription {
        let status = vps.withUnsafeBytes { value in
            sps.withUnsafeBytes { status in
                pps.withUnsafeBytes { pointer in
                    let pointers = [
                        value.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        status.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        pointer.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    ]
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault, parameterSetCount: 3,
                        parameterSetPointers: pointers, parameterSetSizes: [vps.count, sps.count, pps.count],
                        nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
                }
            }
        }
        guard status == noErr, let format else { throw invalid("HEVC format", status) }
        return format
    }

    private func makeSample(_ nals: [Data], timestamp: UInt32, format: CMVideoFormatDescription) throws
        -> CMSampleBuffer {
        var bytes = Data()
        for nal in nals {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }; bytes.append(nal)
        }
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: bytes.count,
            flags: 0, blockBufferOut: &block)
        guard status == noErr, let block else { throw invalid("Sample allocation", status) }
        status = bytes.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count)
        }
        guard status == noErr else { throw invalid("Sample copy", status) }
        var timing = CMSampleTimingInfo(
            duration: .invalid, presentationTimeStamp: CMTime(value: Int64(timestamp), timescale: 90000),
            decodeTimeStamp: .invalid)
        var size = bytes.count, sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw invalid("Video sample", status) }
        return sample
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
    private func invalidate() {
        if let session { VTDecompressionSessionInvalidate(session) }; session = nil; format = nil
        nativeDimensions = nil
    }
    deinit { invalidate() }
}
