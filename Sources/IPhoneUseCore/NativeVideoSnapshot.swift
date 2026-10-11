import Foundation
import VideoToolbox
import CoreImage

// Keep the validated DisplayService rectangle bound to the decoded pixels.
// Lossy decoded padding is not a reliable source of crop geometry.
struct NativeDecodedVideoFrame {
    let pixels: CVPixelBuffer
    let nativeWidth: Int
    let nativeHeight: Int
}

// Decoder work never runs on the media socket queue. Recording retains its own
// handler and decoder; snapshots do not start or stop a stream.
final class NativeVideoSnapshot {
    struct Frame {
        let image: NativeDecodedVideoFrame
        var pixels: CVPixelBuffer { image.pixels }
        let firstPacketAt: Double
        let completedAt: Double
        let timestamp: UInt32
    }
    private let queue = DispatchQueue(label: "iphone-use.native.snapshot.decode")
    private let condition = NSCondition()
    private var pendingBytes = 0
    private var generation = 0
    private var closed = false
    private var latest: Frame?
    private var decodedFrames = 0
    private var framesWithoutImage = 0
    private var decodeErrors = 0
    private var queueOverflows = 0
    private var lastError: String?
    private var parser = NativeHEVCDepacketizer()
    private let decode: (NativeVideoAccessUnit) throws -> NativeDecodedVideoFrame?
    private let resetDecoder: () -> Void
    private var droppedUnits = 0
    private var discontinuities = 0
    private var malformedPackets = 0
    private var timestampRejections = 0
    private var referenceResets = 0
    private var waitingForKeyframe = true
    private var decoderGeneration = 0
    private var lastTimestamp: UInt32?

    convenience init() {
        // Standard observations are Apple PNG. This stream only verifies
        // dimensions; converting every decoded frame into RGB wastes GPU work.
        let decoder = NativeSnapshotDecoder(convertToBGRA: false)
        self.init(decode: { try decoder.decode($0) }, resetDecoder: { decoder.resetReferences() })
    }

    // Also used by deterministic transport/decoder-boundary regression tests.
    init(decode: @escaping (NativeVideoAccessUnit) throws -> NativeDecodedVideoFrame?, resetDecoder: @escaping () -> Void) {
        self.decode = decode; self.resetDecoder = resetDecoder
    }

    func receive(_ data: Data, at receivedAt: Double) {
        condition.lock()
        guard !closed else { condition.unlock(); return }
        guard pendingBytes + data.count <= 4 * 1024 * 1024 else {
            generation += 1; queueOverflows += 1; latest = nil; waitingForKeyframe = true; condition.broadcast(); condition.unlock(); return
        }
        let admittedGeneration = generation
        pendingBytes += data.count
        condition.unlock()
        queue.async { [self] in
            defer { condition.lock(); pendingBytes -= data.count; condition.unlock() }
            condition.lock(); let admitted = !closed && generation == admittedGeneration; condition.unlock()
            guard admitted else { return }
            if decoderGeneration != admittedGeneration {
                parser = NativeHEVCDepacketizer(); resetDecoder()
                lastTimestamp = nil; decoderGeneration = admittedGeneration
                condition.lock(); referenceResets += 1; waitingForKeyframe = true; condition.unlock()
            }
            do {
                let packet = try NativeRTPPacket(data)
                guard packet.payloadType == 100 else { return }
                let previous = (parser.droppedUnits, parser.discontinuities, parser.malformedPackets)
                let candidate = parser.receive(packet, receivedAt: receivedAt)
                let dropped = parser.droppedUnits - previous.0
                let gaps = parser.discontinuities - previous.1
                let malformed = parser.malformedPackets - previous.2
                condition.lock()
                droppedUnits += dropped; discontinuities += gaps; malformedPackets += malformed
                waitingForKeyframe = parser.waitingForKeyframe
                if dropped > 0 || gaps > 0 || malformed > 0 { latest = nil; condition.broadcast() }
                condition.unlock()
                if dropped > 0 || gaps > 0 || malformed > 0 {
                    resetDecoder(); lastTimestamp = nil
                    condition.lock(); referenceResets += 1; condition.unlock()
                }
                guard let unit = candidate, let unitStarted = unit.firstPacketAt else { return }
                // Parameter-set-only units are allowed to share a timestamp.
                if let lastTimestamp, unit.nals.contains(where: { ($0[0] >> 1) & 63 <= 31 }),
                   Int32(bitPattern: unit.timestamp &- lastTimestamp) <= 0 {
                    condition.lock(); timestampRejections += 1; condition.unlock()
                    // Skipping a reference picture and continuing the same decoder
                    // can silently corrupt later output even when VT returns noErr.
                    throw IPhoneUseError("native_snapshot_timestamp_invalid", "Non-increasing video timestamp; require a fresh keyframe")
                }
                let video = unit.nals.contains(where: { ($0[0] >> 1) & 63 <= 31 })
                let image = try decode(unit)
                if video { lastTimestamp = unit.timestamp }
                guard let image else {
                    // A decoded reduced-resolution picture updates references,
                    // but must also invalidate a previously cached observation.
                    if video { condition.lock(); framesWithoutImage += 1; latest = nil; condition.broadcast(); condition.unlock() }
                    return
                }
                let frame = Frame(image: image, firstPacketAt: unitStarted,
                                  completedAt: ProcessInfo.processInfo.systemUptime, timestamp: unit.timestamp)
                condition.lock()
                if !closed, generation == admittedGeneration { latest = frame; decodedFrames += 1; lastError = nil; condition.broadcast() }
                condition.unlock()
            } catch {
                // A broken dependency chain is never reused for observation.
                condition.lock(); generation += 1; decodeErrors += 1; lastError = String(describing: error)
                latest = nil; waitingForKeyframe = true; condition.broadcast(); condition.unlock()
            }
        }
    }

    // A cached last frame, peer heartbeat or a newly decoded OLD queued frame is
    // not a fresh observation. Require the entire unit to arrive after this
    // request, and bound the time from its first packet to consumption.
    func frame(after notBefore: Double, timeout: Double = 0.15,
               cancellation: NativeCancellation) throws -> Frame? {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        condition.lock(); defer { condition.unlock() }
        while !closed {
            try cancellation.check()
            let now = ProcessInfo.processInfo.systemUptime
            if let latest, Self.isFresh(latest, after: notBefore, now: now) { return latest }
            guard now < deadline else { return nil }
            _ = condition.wait(until: Date().addingTimeInterval(min(0.02, deadline - now)))
        }
        return nil
    }
    // Negative evidence only: an old frame may reveal conflicting axes, but
    // can never become a screenshot or establish that the screen is current.
    func rejectConflictingGeometry(_ display: NativeDisplay) throws {
        condition.lock(); let candidate = latest; condition.unlock()
        if let candidate { _ = try NativeSnapshotImage.validateGeometry(candidate, display: display) }
    }
    static func isFresh(_ frame: Frame, after notBefore: Double, now: Double) -> Bool {
        frame.firstPacketAt >= notBefore && frame.firstPacketAt <= frame.completedAt
            && frame.completedAt <= now && now - frame.firstPacketAt <= 0.5
    }
    func status() -> [String: Any] {
        condition.lock(); defer { condition.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        return ["decodedFrames": decodedFrames, "framesWithoutImage": framesWithoutImage,
                "decodeErrors": decodeErrors, "queueOverflows": queueOverflows,
                "droppedUnits": droppedUnits, "discontinuities": discontinuities, "malformedPackets": malformedPackets,
                "timestampRejections": timestampRejections, "referenceResets": referenceResets,
                "waitingForKeyframe": waitingForKeyframe,
                "pendingBytes": pendingBytes, "closed": closed, "lastError": lastError as Any? ?? NSNull(),
                "lastFrameAgeSeconds": latest.map { now - $0.firstPacketAt } as Any? ?? NSNull(),
                "lastFrameCompletedAgeSeconds": latest.map { now - $0.completedAt } as Any? ?? NSNull(),
                "lastFrameDecodeLagSeconds": latest.map { $0.completedAt - $0.firstPacketAt } as Any? ?? NSNull()]
    }
    func close() {
        condition.lock(); closed = true; latest = nil; condition.broadcast(); condition.unlock()
        queue.sync { resetDecoder(); parser = NativeHEVCDepacketizer() }
    }
}

// Apple VideoToolbox owns HEVC decoding. Only complete dependency-checked units
// from the existing RFC 7798 parser reach this decoder.
final class NativeSnapshotDecoder {
    private var parameterSets: [Int: Data] = [:]
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var nativeDimensions: (Int, Int)?
    private(set) var withheldResolutionFrames = 0
    private let convertToBGRA: Bool
    private static let context = CIContext(options: [.cacheIntermediates: false])

    // Recording retains the existing presentation path by default. Geometry
    // consumers opt out of color conversion, not decoding or frame validation.
    init(convertToBGRA: Bool = true) { self.convertToBGRA = convertToBGRA }

    func decode(_ unit: NativeVideoAccessUnit) throws -> NativeDecodedVideoFrame? {
        // No reference chain survives a failed metadata/configuration/decode step.
        do { return try decodeFrame(unit) }
        catch { invalidate(); throw error }
    }

    private func decodeFrame(_ unit: NativeVideoAccessUnit) throws -> NativeDecodedVideoFrame? {
        guard #available(macOS 15.0, *) else { throw invalid("VRA decoding requires macOS 15 or later", -1) }
        guard unit.nals.allSatisfy({ $0.count >= 2 }) else { throw invalid("Truncated NAL", -1) }
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
        let metadata = try NativeVideoFrameMetadata(nals: nals)
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
                decoderSpecification: [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary,
                imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] as CFDictionary,
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
            let statusHardware = VTSessionCopyProperty(session, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                allocator: nil, valueOut: &hardware)
            guard statusHardware == noErr, hardware as? Bool == true else { throw invalid("Hardware decoder unavailable", statusHardware) }
        }
        guard let session, let format else { return nil }
        let canvas = CMVideoFormatDescriptionGetDimensions(format)
        try metadata.validate(canvas: canvas)
        if let nativeDimensions, nativeDimensions != (metadata.nativeWidth, metadata.nativeHeight) {
            throw invalid("Native rectangle changed within a reference chain", -1)
        }
        nativeDimensions = (metadata.nativeWidth, metadata.nativeHeight)
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
        status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [],
            frameOptions: ["ActiveVideoResolution": ["Width": metadata.activeWidth, "Height": metadata.activeHeight]] as CFDictionary,
            infoFlagsOut: nil) { code, flags, image, _, _ in
            result.lock.lock(); result.status = code; result.flags = flags; result.pixels = image; result.lock.unlock()
        }
        guard status == noErr else { throw invalid("Frame decode", status) }
        status = VTDecompressionSessionWaitForAsynchronousFrames(session)
        guard status == noErr else { throw invalid("Frame completion", status) }
        result.lock.lock(); defer { result.lock.unlock() }
        guard result.status == noErr, !result.flags.contains(.frameDropped), let pixels = result.pixels else {
            throw invalid("Decoded frame unavailable (flags \(result.flags.rawValue))", result.status)
        }
        guard CVPixelBufferGetWidth(pixels) == Int(canvas.width), CVPixelBufferGetHeight(pixels) == Int(canvas.height) else {
            throw invalid("Unexpected decoder output geometry", -1)
        }
        // Reduced pictures must still be decoded, otherwise later references
        // corrupt. Until their output scaling contract is verified, withhold
        // them instead of guessing a coordinate transform or recording gray fill.
        guard metadata.hasFullResolution(canvas: canvas) else { withheldResolutionFrames += 1; return nil }
        guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else {
            throw invalid("Unexpected decoder output pixel format", -1)
        }
        if !convertToBGRA {
            return NativeDecodedVideoFrame(pixels: pixels, nativeWidth: metadata.nativeWidth, nativeHeight: metadata.nativeHeight)
        }
        var bgra: CVPixelBuffer?
        let created = CVPixelBufferCreate(kCFAllocatorDefault, Int(canvas.width), Int(canvas.height), kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &bgra)
        guard created == kCVReturnSuccess, let bgra else { throw invalid("BGRA allocation", created) }
        Self.context.render(CIImage(cvPixelBuffer: pixels), to: bgra)
        // Metadata syntax, canvas bounds and reference-chain consistency were
        // validated above. Decoded padding may contain lossy edge data; it must
        // not invalidate otherwise complete reference pictures. Observation
        // additionally checks this exact rectangle against Apple display facts.
        return NativeDecodedVideoFrame(pixels: bgra, nativeWidth: metadata.nativeWidth, nativeHeight: metadata.nativeHeight)
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
    private func invalidate() { if let session { VTDecompressionSessionInvalidate(session) }; session = nil; format = nil; nativeDimensions = nil }
    deinit { invalidate() }
}

enum NativeSnapshotImage {
    static func validateGeometry(_ frame: NativeVideoSnapshot.Frame?, display: NativeDisplay) throws -> (width: Int, height: Int) {
        guard let frame else {
            throw IPhoneUseError("native_snapshot_freshness_unavailable", "No fresh complete media frame to verify display geometry")
        }
        guard display.nativeRotation == "rot0", NativeVideoOrientation(rawValue: display.rotation) != nil else {
            throw IPhoneUseError("native_snapshot_geometry_unavailable", "Unverified media orientation")
        }
        let width = Int(display.rotation == "rot0" ? display.pixelWidth : display.pixelHeight)
        let height = Int(display.rotation == "rot0" ? display.pixelHeight : display.pixelWidth)
        try validateNativeRectangle(frame.image, width: width, height: height)
        return (width, height)
    }

    static func validateNativeRectangle(_ image: NativeDecodedVideoFrame, width: Int, height: Int) throws {
        let pixels = image.pixels
        let encodedWidth = CVPixelBufferGetWidth(pixels), encodedHeight = CVPixelBufferGetHeight(pixels)
        guard image.nativeWidth == width, image.nativeHeight == height,
              width > 0, height > 0, encodedWidth >= width, encodedHeight >= height, encodedWidth - width < 64, encodedHeight - height < 64,
              [kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange].contains(CVPixelBufferGetPixelFormatType(pixels)) else {
            throw IPhoneUseError("native_snapshot_geometry_unavailable", "Media dimensions do not match native screen axes")
        }
    }

}
