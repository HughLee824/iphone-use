import Foundation
import VideoToolbox
import CoreImage

// Keep the validated DisplayService rectangle bound to the decoded pixels.
// Lossy decoded padding is not a reliable source of crop geometry.
struct NativeDecodedVideoFrame {
    let pixels: CVPixelBuffer
    let nativeWidth: Int
    let nativeHeight: Int
    let activeWidth: Int
    let activeHeight: Int

    init(
        pixels: CVPixelBuffer, nativeWidth: Int, nativeHeight: Int, activeWidth: Int? = nil,
        activeHeight: Int? = nil
    ) {
        self.pixels = pixels; self.nativeWidth = nativeWidth; self.nativeHeight = nativeHeight
        self.activeWidth = activeWidth ?? CVPixelBufferGetWidth(pixels)
        self.activeHeight = activeHeight ?? CVPixelBufferGetHeight(pixels)
    }

    var isReducedResolution: Bool {
        activeWidth != CVPixelBufferGetWidth(pixels) || activeHeight != CVPixelBufferGetHeight(pixels)
    }
}

// Decoder work never runs on the media socket queue. A preview recording can
// subscribe to these decoded frames; snapshots never start or stop a stream.
final class NativeVideoSnapshot {
    struct Frame {
        let image: NativeDecodedVideoFrame
        var pixels: CVPixelBuffer { image.pixels }
        let firstPacketAt: Double
        let completedAt: Double
        let timestamp: UInt32
        var displayRotation: String?
    }
    // This feeds interactive preview and observations. It must not sit below
    // JPEG/HTTP work in scheduling priority while that work waits for pixels.
    private let queue = DispatchQueue(label: "iphone-use.native.snapshot.decode", qos: .userInitiated)
    private let condition = NSCondition()
    private var pendingBytes = 0
    private var generation = 0
    private var closed = false
    private var latest: Frame?
    private var latestPreview: Frame?
    private var previewDecodedFrames = 0
    private var reducedResolutionFrames = 0
    private var resolutionChanges: [[String: Double]] = []
    private var recordingHandler: ((Frame) -> Void)?
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
    private var unitQueueWaitMs = 0.0
    private var lastQueueWaitMs = 0.0
    private var lastDecodeMs = 0.0
    private var maxQueueWaitMs = 0.0
    private var maxDecodeMs = 0.0
    private var slowFrames: [[String: Double]] = []

    convenience init() {
        // Standard observations are Apple PNG. This stream verifies geometry;
        // converting every decoded frame into RGB wastes GPU work.
        let decoder = NativeSnapshotDecoder(convertToBGRA: false, includeReducedResolution: true)
        self.init(decode: { try decoder.decode($0) }, resetDecoder: { decoder.resetReferences() })
    }

    // Also used by deterministic transport/decoder-boundary regression tests.
    init(
        decode: @escaping (NativeVideoAccessUnit) throws -> NativeDecodedVideoFrame?,
        resetDecoder: @escaping () -> Void
    ) {
        self.decode = decode; self.resetDecoder = resetDecoder
    }

    func receive(_ data: Data, at receivedAt: Double) {
        let admittedAt = ProcessInfo.processInfo.systemUptime
        condition.lock()
        guard !closed else { condition.unlock(); return }
        guard pendingBytes + data.count <= 4 * 1024 * 1024 else {
            generation += 1; queueOverflows += 1; latest = nil; latestPreview = nil; waitingForKeyframe = true
            condition.broadcast(); condition.unlock(); return
        }
        let admittedGeneration = generation
        pendingBytes += data.count
        condition.unlock()
        queue.async { [self] in
            let queueWaitMs = (ProcessInfo.processInfo.systemUptime - admittedAt) * 1000
            defer { condition.lock(); pendingBytes -= data.count; condition.unlock() }
            condition.lock(); let admitted = !closed && generation == admittedGeneration; condition.unlock()
            guard admitted else { return }
            unitQueueWaitMs = max(unitQueueWaitMs, queueWaitMs)
            if decoderGeneration != admittedGeneration {
                parser = NativeHEVCDepacketizer(); resetDecoder()
                unitQueueWaitMs = queueWaitMs
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
                if dropped > 0 || gaps > 0 || malformed > 0 {
                    latest = nil; latestPreview = nil; condition.broadcast()
                }
                condition.unlock()
                if dropped > 0 || gaps > 0 || malformed > 0 {
                    resetDecoder(); lastTimestamp = nil
                    condition.lock(); referenceResets += 1; condition.unlock()
                }
                try decodeCandidate(candidate, admittedGeneration: admittedGeneration)
            } catch {
                // A broken dependency chain is never reused for observation.
                unitQueueWaitMs = 0
                condition.lock(); generation += 1; decodeErrors += 1; lastError = String(describing: error)
                latest = nil; latestPreview = nil; waitingForKeyframe = true; condition.broadcast()
                condition.unlock()
            }
        }
    }

    // Runs only on the decoder queue, after packet admission and loss handling.
    private func decodeCandidate(_ candidate: NativeVideoAccessUnit?, admittedGeneration: Int) throws {
        guard let unit = candidate, let unitStarted = unit.firstPacketAt else { return }
        let packetWaitMs = unitQueueWaitMs
        unitQueueWaitMs = 0
        // Parameter-set-only units are allowed to share a timestamp.
        if let lastTimestamp, unit.nals.contains(where: { ($0[0] >> 1) & 63 <= 31 }),
            Int32(bitPattern: unit.timestamp &- lastTimestamp) <= 0 {
            condition.lock(); timestampRejections += 1; condition.unlock()
            // Skipping a reference picture and continuing the same decoder
            // can silently corrupt later output even when VT returns noErr.
            throw IPhoneUseError(
                "native_snapshot_timestamp_invalid",
                "Non-increasing video timestamp; require a fresh keyframe")
        }
        let video = unit.nals.contains(where: { ($0[0] >> 1) & 63 <= 31 })
        let decodeStarted = ProcessInfo.processInfo.systemUptime
        let image = try decode(unit)
        let completed = ProcessInfo.processInfo.systemUptime
        if video {
            recordDecodeTiming(
                unit, packetWaitMs: packetWaitMs, decodeStarted: decodeStarted, completed: completed)
        }
        if video { lastTimestamp = unit.timestamp }
        guard let image else {
            // A decoded reduced-resolution picture updates references,
            // but must also invalidate a previously cached observation.
            if video {
                condition.lock(); framesWithoutImage += 1; latest = nil; latestPreview = nil
                condition.broadcast(); condition.unlock()
            }
            return
        }
        let frame = Frame(
            image: image, firstPacketAt: unitStarted,
            completedAt: completed, timestamp: unit.timestamp, displayRotation: unit.displayRotation)
        cache(frame, admittedGeneration: admittedGeneration)
    }

    private func recordDecodeTiming(
        _ unit: NativeVideoAccessUnit, packetWaitMs: Double,
        decodeStarted: Double, completed: Double
    ) {
        let unitStarted = unit.firstPacketAt!
        let decodeMs = (completed - decodeStarted) * 1000
        condition.lock()
        lastQueueWaitMs = packetWaitMs; lastDecodeMs = decodeMs
        maxQueueWaitMs = max(maxQueueWaitMs, packetWaitMs); maxDecodeMs = max(maxDecodeMs, decodeMs)
        if packetWaitMs > 50 || decodeMs > 50 || completed - unitStarted > 0.1 {
            slowFrames.append([
                "wallTime": Date().timeIntervalSince1970, "timestamp": Double(unit.timestamp),
                "queueWaitMs": packetWaitMs,
                "decodeMs": decodeMs, "inputToDecodeMs": (decodeStarted - unitStarted) * 1000,
                "sourceLagMs": (completed - unitStarted) * 1000
            ])
            if slowFrames.count > 120 { slowFrames.removeFirst() }
        }
        condition.unlock()
    }

    private func cache(_ frame: Frame, admittedGeneration: Int) {
        let image = frame.image
        condition.lock()
        if !closed, generation == admittedGeneration {
            if latestPreview?.image.activeWidth != image.activeWidth
                || latestPreview?.image.activeHeight != image.activeHeight {
                resolutionChanges.append([
                    "wallTime": Date().timeIntervalSince1970, "timestamp": Double(frame.timestamp),
                    "activeWidth": Double(image.activeWidth), "activeHeight": Double(image.activeHeight)
                ])
                if resolutionChanges.count > 120 { resolutionChanges.removeFirst() }
            }
            latestPreview = frame; previewDecodedFrames += 1; lastError = nil
            // Reduced pixels never become observation or recording
            // pixels. Their native geometry can still verify Apple PNGs.
            if image.isReducedResolution {
                latest = nil; reducedResolutionFrames += 1
            } else {
                latest = frame; decodedFrames += 1; recordingHandler?(frame)
            }
            condition.broadcast()
        }
        condition.unlock()
    }

    // A cached last frame, peer heartbeat or a newly decoded OLD queued frame is
    // not a fresh observation. Require the entire unit to arrive after this
    // request, and bound the time from its first packet to consumption.
    func frame(
        after notBefore: Double, timeout: Double = 0.15, includeReducedResolution: Bool = false,
        cancellation: NativeCancellation
    ) throws -> Frame? {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        condition.lock(); defer { condition.unlock() }
        while !closed {
            try cancellation.check()
            let now = ProcessInfo.processInfo.systemUptime
            let candidate = includeReducedResolution ? latestPreview : latest
            if let candidate, Self.isFresh(candidate, after: notBefore, now: now) { return candidate }
            guard now < deadline else { return nil }
            _ = condition.wait(until: Date().addingTimeInterval(min(0.02, deadline - now)))
        }
        return nil
    }
    // Cached access never establishes observation freshness. Existing consumers
    // (including recording preparation) require full resolution; only the browser
    // display opts into reduced pictures and normalizes their active rectangle.
    func previewFrame(includeReducedResolution: Bool = false) -> Frame? {
        condition.lock(); defer { condition.unlock() }
        return closed ? nil : (includeReducedResolution ? latestPreview : latest)
    }
    // Callback runs under the cache lock and must only enqueue bounded work.
    // Priming and subscription are atomic, so no newer frame can overtake the seed.
    func setRecordingHandler(_ handler: ((Frame) -> Void)?) {
        condition.lock(); defer { condition.unlock() }
        recordingHandler = closed ? nil : handler
        if let latest, !closed { handler?(latest) }
    }

    // Negative evidence only: an old frame may reveal conflicting axes, but
    // can never become a screenshot or establish that the screen is current.
    func rejectConflictingGeometry(_ display: NativeDisplay) throws {
        condition.lock(); let candidate = latestPreview; condition.unlock()
        if let candidate {
            _ = try NativeSnapshotImage.validateGeometry(
                candidate, display: display, allowReducedResolution: true)
        }
    }
    static func isFresh(_ frame: Frame, after notBefore: Double, now: Double) -> Bool {
        frame.firstPacketAt >= notBefore && frame.firstPacketAt <= frame.completedAt
            && frame.completedAt <= now && now - frame.firstPacketAt <= 0.5
    }
    func status() -> [String: Any] {
        condition.lock(); defer { condition.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        return [
            "decodedFrames": decodedFrames, "framesWithoutImage": framesWithoutImage,
            "previewDecodedFrames": previewDecodedFrames, "reducedResolutionFrames": reducedResolutionFrames,
            "resolutionChanges": resolutionChanges,
            "decodeErrors": decodeErrors, "queueOverflows": queueOverflows,
            "droppedUnits": droppedUnits, "discontinuities": discontinuities,
            "malformedPackets": malformedPackets,
            "timestampRejections": timestampRejections, "referenceResets": referenceResets,
            "waitingForKeyframe": waitingForKeyframe,
            "lastFrameDisplayRotation": latest?.displayRotation as Any? ?? NSNull(),
            "pendingBytes": pendingBytes, "closed": closed, "lastError": lastError as Any? ?? NSNull(),
            "timing": [
                "lastQueueWaitMs": lastQueueWaitMs, "lastDecodeMs": lastDecodeMs,
                "maxQueueWaitMs": maxQueueWaitMs, "maxDecodeMs": maxDecodeMs, "slowFrames": slowFrames
            ],
            "lastFrameAgeSeconds": latest.map { now - $0.firstPacketAt } as Any? ?? NSNull(),
            "lastFrameCompletedAgeSeconds": latest.map { now - $0.completedAt } as Any? ?? NSNull(),
            "lastFrameDecodeLagSeconds": latest.map { $0.completedAt - $0.firstPacketAt } as Any? ?? NSNull()
        ]
    }
    func close() {
        condition.lock(); closed = true; latest = nil; latestPreview = nil; recordingHandler = nil
        condition.broadcast(); condition.unlock()
        queue.sync {
            resetDecoder(); parser = NativeHEVCDepacketizer()
        }
    }
}
