import Foundation
import VideoToolbox
import CoreImage
import ImageIO
import UniformTypeIdentifiers

// Decoder work never runs on the media socket queue. Recording retains its own
// handler and compressed passthrough; snapshots do not start or stop a stream.
final class NativeVideoSnapshot {
    struct Frame {
        let pixels: CVPixelBuffer
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
    private var decodeErrors = 0
    private var queueOverflows = 0
    private var lastError: String?
    private var parser = NativeHEVCDepacketizer()
    private var decoder = NativeSnapshotDecoder()
    private var decoderGeneration = 0
    private var lastTimestamp: UInt32?

    func receive(_ data: Data, at receivedAt: Double) {
        condition.lock()
        guard !closed else { condition.unlock(); return }
        guard pendingBytes + data.count <= 4 * 1024 * 1024 else {
            generation += 1; queueOverflows += 1; latest = nil; condition.broadcast(); condition.unlock(); return
        }
        let admittedGeneration = generation
        pendingBytes += data.count
        condition.unlock()
        queue.async { [self] in
            defer { condition.lock(); pendingBytes -= data.count; condition.unlock() }
            condition.lock(); let admitted = !closed && generation == admittedGeneration; condition.unlock()
            guard admitted else { return }
            if decoderGeneration != admittedGeneration {
                parser = NativeHEVCDepacketizer(); decoder = NativeSnapshotDecoder()
                lastTimestamp = nil; decoderGeneration = admittedGeneration
            }
            do {
                let packet = try NativeRTPPacket(data)
                guard packet.payloadType == 100 else { return }
                guard let unit = parser.receive(packet, receivedAt: receivedAt), let unitStarted = unit.firstPacketAt else { return }
                // Parameter-set-only units are allowed to share a timestamp.
                if let lastTimestamp, unit.nals.contains(where: { ($0[0] >> 1) & 63 <= 31 }),
                   Int32(bitPattern: unit.timestamp &- lastTimestamp) <= 0 { return }
                guard let pixels = try decoder.decode(unit) else { return }
                lastTimestamp = unit.timestamp
                let frame = Frame(pixels: pixels, firstPacketAt: unitStarted,
                                  completedAt: ProcessInfo.processInfo.systemUptime, timestamp: unit.timestamp)
                condition.lock()
                if !closed, generation == admittedGeneration { latest = frame; decodedFrames += 1; lastError = nil; condition.broadcast() }
                condition.unlock()
            } catch {
                // A broken dependency chain is never reused for observation.
                condition.lock(); generation += 1; decodeErrors += 1; lastError = String(describing: error)
                latest = nil; condition.broadcast(); condition.unlock()
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
        return ["decodedFrames": decodedFrames, "decodeErrors": decodeErrors, "queueOverflows": queueOverflows,
                "pendingBytes": pendingBytes, "closed": closed, "lastError": lastError as Any? ?? NSNull(),
                "lastFrameAgeSeconds": latest.map { ProcessInfo.processInfo.systemUptime - $0.firstPacketAt } as Any? ?? NSNull()]
    }
    func close() {
        condition.lock(); closed = true; latest = nil; condition.broadcast(); condition.unlock()
        queue.sync { decoder = NativeSnapshotDecoder(); parser = NativeHEVCDepacketizer() }
    }
}

// Apple VideoToolbox owns HEVC decoding. Only complete dependency-checked units
// from the existing RFC 7798 parser reach this decoder.
final class NativeSnapshotDecoder {
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
        status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { code, _, image, _, _ in
            result.lock.lock(); result.status = code; result.pixels = image; result.lock.unlock()
        }
        guard status == noErr else { throw invalid("Frame decode", status) }
        status = VTDecompressionSessionWaitForAsynchronousFrames(session)
        guard status == noErr else { throw invalid("Frame completion", status) }
        result.lock.lock(); defer { result.lock.unlock() }
        guard result.status == noErr, let pixels = result.pixels else { throw invalid("Decoded frame unavailable", result.status) }
        return pixels
    }
    private final class Output {
        let lock = NSLock()
        var status: OSStatus = -1
        var pixels: CVPixelBuffer?
    }
    private func invalid(_ operation: String, _ status: OSStatus) -> IPhoneUseError {
        IPhoneUseError("native_snapshot_decode_failed", "\(operation) failed (\(status))")
    }
    private func invalidate() { if let session { VTDecompressionSessionInvalidate(session) }; session = nil; format = nil }
    deinit { invalidate() }
}

enum NativeSnapshotImage {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func validateGeometry(_ frame: NativeVideoSnapshot.Frame, display: NativeDisplay) throws -> (width: Int, height: Int) {
        guard display.nativeRotation == "rot0", NativeVideoOrientation(rawValue: display.rotation) != nil else {
            throw IPhoneUseError("native_snapshot_geometry_unavailable", "Unverified media orientation")
        }
        let width = Int(display.rotation == "rot0" ? display.pixelWidth : display.pixelHeight)
        let height = Int(display.rotation == "rot0" ? display.pixelHeight : display.pixelWidth)
        let pixels = frame.pixels
        let encodedWidth = CVPixelBufferGetWidth(pixels), encodedHeight = CVPixelBufferGetHeight(pixels)
        guard encodedWidth >= width, encodedHeight >= height, encodedWidth - width < 64, encodedHeight - height < 64,
              CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA else {
            throw IPhoneUseError("native_snapshot_geometry_unavailable", "Media dimensions do not match native screen axes")
        }
        // macOS/iOS 27 media retains native axes and pads right/bottom. Check
        // every excluded pixel; never scale or infer a crop from visible text.
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { throw IPhoneUseError("invalid_image", "No decoded pixels") }
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        for y in 0..<encodedHeight {
            let start = y < height ? width : 0
            for x in start..<encodedWidth {
                let pixel = base.advanced(by: y * stride + x * 4).assumingMemoryBound(to: UInt8.self)
                guard pixel[0] <= 8, pixel[1] <= 8, pixel[2] <= 8 else {
                    throw IPhoneUseError("native_snapshot_geometry_unavailable", "Media padding contains image content")
                }
            }
        }
        return (width, height)
    }

    static func png(_ frame: NativeVideoSnapshot.Frame, display: NativeDisplay) throws -> (Data, [String: Any]) {
        let (width, height) = try validateGeometry(frame, display: display)
        let pixels = frame.pixels
        let encodedWidth = CVPixelBufferGetWidth(pixels), encodedHeight = CVPixelBufferGetHeight(pixels)
        let orientation = NativeVideoOrientation(rawValue: display.rotation)!
        var cgImage: CGImage?
        guard VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &cgImage) == noErr,
              let crop = cgImage?.cropping(to: CGRect(x: 0, y: 0, width: width, height: height)) else {
            throw IPhoneUseError("invalid_image", "Cannot crop decoded media")
        }
        let image = CIImage(cgImage: crop).oriented(orientation == .portrait ? .up : orientation == .left ? .right : .left)
        guard let rendered = context.createCGImage(image, from: image.extent) else { throw IPhoneUseError("invalid_image", "Cannot orient decoded media") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw IPhoneUseError("invalid_image", "Cannot create snapshot PNG")
        }
        CGImageDestinationAddImage(destination, rendered, nil)
        guard CGImageDestinationFinalize(destination) else { throw IPhoneUseError("invalid_image", "Cannot encode snapshot PNG") }
        return (data as Data, ["encodedWidth": encodedWidth, "encodedHeight": encodedHeight,
            "cropNativePixels": ["x": 0, "y": 0, "width": width, "height": height],
            "displayRotation": display.rotation, "firstPacketUptime": frame.firstPacketAt,
            "decodeCompletedUptime": frame.completedAt, "rtpTimestamp": frame.timestamp,
            "freshness": "complete_unit_received_after_request", "deviceCaptureTimeKnown": false])
    }
}
