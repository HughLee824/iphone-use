import Foundation
import CoreVideo

protocol NativeRecordingSource: AnyObject {
    func recordingConfiguration() -> [String: Any]
    func setVideoHandler(_ handler: ((Data) -> Void)?)
    func requestKeyframe()
    func health() -> [String: Any]
}

extension NativeRTPReceiver: NativeRecordingSource {}

// An optional bounded branch of our existing media receiver. The network queue
// only enqueues packets; file I/O/HEVC assembly/finalization happen here.
final class NativeStreamRecording {
    private final class Job {
        let id = UUID().uuidString
        let directory: URL
        let duration: Double
        var startedAt = Date().timeIntervalSince1970
        var started: Double
        var mediaID: String
        let configuration: [String: Any]
        let rotation: String
        weak var receiver: NativeRecordingSource?
        var parser = NativeHEVCDepacketizer()
        let writer: NativeVideoWriter
        weak var snapshots: NativeVideoSnapshot?
        var usesSharedFrames = false
        var snapshotBaseline: [String: Any] = [:]
        var decodedSeedAge: Double?
        var sharedTimestamp: UInt32?
        var sharedTicks: Int64 = 0
        var result: [String: Any]?
        var packets = 0
        var lastPLI = 0.0
        var firstFrameAt: Double?
        var startupDroppedUnits = 0
        var failure: Error?
        var sourceGeneration = 0
        var refreshStarted: Double?
        var sourceRefreshes: [[String: Any]] = []
        init(root: URL, duration: Double, receiver: NativeRecordingSource, mediaID: String, orientation: NativeVideoOrientation, configuration: [String: Any], clock: Int32, started: Double,
             makeWriter: (URL, Int32, NativeVideoOrientation) -> NativeVideoWriter) {
            self.duration = duration; self.receiver = receiver; self.mediaID = mediaID
            self.started = started
            self.configuration = configuration; self.rotation = orientation.rawValue
            directory = root.appendingPathComponent(id)
            writer = makeWriter(directory.appendingPathComponent("screen.mp4"), clock, orientation)
        }
    }
    private let queue = DispatchQueue(label: "iphone-use.native.recording.stream")
    private let pendingLock = NSLock()
    private var pendingBytes = 0
    private var overflow = false
    private var timer: DispatchSourceTimer?
    private let root: URL
    private let now: () -> Double
    private let onFinish: (_ recordingID: String, _ mediaID: String) -> Void
    private var current: Job?
    private var jobs: [String: Job] = [:]
    private var closed = false
    private let makeWriter: (URL, Int32, NativeVideoOrientation) -> NativeVideoWriter
    init(root: URL, now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
         onFinish: @escaping (String, String) -> Void = { _, _ in },
         makeWriter: @escaping (URL, Int32, NativeVideoOrientation) -> NativeVideoWriter = { NativeVideoWriter(url: $0, timescale: $1, orientation: $2) }) {
        self.root = root; self.now = now; self.makeWriter = makeWriter; self.onFinish = onFinish
    }

    static func supports(_ config: [String: Any]) -> Bool {
        config["RxPayloadType"] as? Int == 100 && config["TilesPerFrame"] as? Int == 1
            && config["SRTPCipherSuite"] as? Int == 0
    }
    var isActive: Bool { queue.sync { current != nil && current?.result == nil } }
    func status() -> [String: Any] { queue.sync { current.map(facts) ?? ["state": "idle", "method": "native_rtp"] } }

    func start(duration: Double, receiver: NativeRecordingSource, mediaID: String, rotation: String, snapshots: NativeVideoSnapshot? = nil) throws -> [String: Any] {
        try queue.sync {
            guard !closed else { throw IPhoneUseError("recording_closed", "Recording owner closed") }
            guard current == nil || current?.result != nil else { throw IPhoneUseError("recording_busy", "A recording is already active") }
            _ = try NativeRecordingOptions.duration(["duration": duration])
            guard let orientation = NativeVideoOrientation(rawValue: rotation) else {
                throw IPhoneUseError("native_recording_orientation_unsupported", "Unverified video orientation")
            }
            let config = receiver.recordingConfiguration()
            guard Self.supports(config), let clock = config["RTPClockRate"] as? Int32 else {
                throw IPhoneUseError("native_recording_format_unavailable", "Need the observed single-layer HEVC payload and a clock confirmed by sender reports")
            }
            let job = Job(root: root, duration: duration, receiver: receiver, mediaID: mediaID, orientation: orientation, configuration: config, clock: clock, started: now(), makeWriter: makeWriter)
            try SessionPaths.secureDirectory(root); try SessionPaths.secureDirectory(job.directory)
            if let seed = snapshots?.previewFrame() {
                do { try job.writer.prepare(seed.pixels) }
                catch { job.writer.cancel(); throw error }
                // Preparation is not recording time. Subscribe atomically to the
                // latest frame only after the encoder is ready, preserving every
                // subsequently admitted frame and the existing backlog limit.
                job.started = now(); job.startedAt = Date().timeIntervalSince1970
            }
            jobs[job.id] = job; current = job
            pendingLock.lock(); overflow = false; pendingLock.unlock()
            job.snapshots = snapshots; job.snapshotBaseline = snapshots?.status() ?? [:]
            job.usesSharedFrames = snapshots != nil
            if let snapshots {
                snapshots.setRecordingHandler { [weak self, weak job] frame in
                    guard let self, let job else { return }
                    self.enqueue(frame, job: job)
                }
            } else { receiver.setVideoHandler { [weak self, weak job] data in
                guard let self, let job else { return }
                self.enqueue(data, job: job)
            }
            }
            if snapshots == nil { receiver.requestKeyframe() }; job.lastPLI = job.started
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer; timer.resume()
            return facts(job)
        }
    }

    private func enqueue(_ frame: NativeVideoSnapshot.Frame, job: Job, generation: Int = 0) {
        // Retained full-resolution pixel buffers are expensive. Fail explicitly
        // at a bounded backlog instead of blocking the shared decoder/preview.
        let bytes = CVPixelBufferGetDataSize(frame.pixels)
        pendingLock.lock()
        guard pendingBytes + bytes <= 64 * 1024 * 1024 else { overflow = true; pendingLock.unlock(); return }
        pendingBytes += bytes; pendingLock.unlock()
        queue.async { [self] in
            defer { pendingLock.lock(); pendingBytes -= bytes; pendingLock.unlock() }
            guard job.result == nil, job === current, job.refreshStarted == nil,
                  job.sourceGeneration == generation else { return }
            do {
                if job.firstFrameAt == nil {
                    job.decodedSeedAge = max(0, job.started - frame.firstPacketAt)
                    try job.writer.appendDecoded(frame.pixels, seconds: max(0, frame.firstPacketAt - job.started), receivedAt: max(job.started, frame.firstPacketAt))
                    job.firstFrameAt = max(job.started, frame.firstPacketAt)
                    if frame.firstPacketAt > job.started {
                        job.sharedTimestamp = frame.timestamp
                        job.sharedTicks = Int64(((frame.firstPacketAt - job.started) * Double(job.writer.timescale)).rounded())
                    }
                } else if frame.firstPacketAt > job.started {
                    // Burst delivery can assign multiple frames the same host
                    // tick. Keep the source RTP spacing after the start anchor.
                    if let previous = job.sharedTimestamp {
                        let delta = Int32(bitPattern: frame.timestamp &- previous)
                        guard delta > 0, Int64(delta) < Int64(job.writer.timescale) * 330 else {
                            throw IPhoneUseError("recording_timestamp_invalid", "Shared RTP timestamp is discontinuous")
                        }
                        job.sharedTicks += Int64(delta)
                    } else {
                        job.sharedTicks = max(1, Int64(((frame.firstPacketAt - job.started) * Double(job.writer.timescale)).rounded()))
                    }
                    job.sharedTimestamp = frame.timestamp
                    try job.writer.appendDecoded(frame.pixels, seconds: Double(job.sharedTicks) / Double(job.writer.timescale), receivedAt: frame.firstPacketAt)
                }
            } catch { job.failure = error; finish(job, reason: "video_error") }
        }
    }

    private func sharedDecoderIntact(_ job: Job) -> Bool {
        guard let snapshots = job.snapshots else { return true }
        let status = snapshots.status()
        return status["closed"] as? Bool != true &&
            ["decodeErrors", "queueOverflows", "droppedUnits", "discontinuities", "malformedPackets", "timestampRejections"].allSatisfy {
                status[$0] as? Int == job.snapshotBaseline[$0] as? Int
            }
    }

    private func enqueue(_ data: Data, job: Job) {
        // Stamp on admission, before waiting behind disk/codec work. Carry the
        // first packet's receive time through access-unit assembly.
        let receivedAt = now()
        pendingLock.lock()
        guard pendingBytes + data.count <= 4 * 1024 * 1024 else { overflow = true; pendingLock.unlock(); return }
        pendingBytes += data.count; pendingLock.unlock()
        queue.async { [self] in
            defer { pendingLock.lock(); pendingBytes -= data.count; pendingLock.unlock() }
            guard job.result == nil, job === current else { return }
            do {
                let packet = try NativeRTPPacket(data)
                guard packet.payloadType == 100, packet.ssrc == (job.configuration["LocalSSRC"] as? NSNumber)?.uint32Value else { return }
                job.packets += 1
                if let unit = job.parser.receive(packet, receivedAt: receivedAt) {
                    let before = job.writer.frames
                    try job.writer.append(unit)
                    if job.writer.hasFrame, job.firstFrameAt == nil {
                        job.firstFrameAt = job.writer.firstFrameReceivedAt
                        job.startupDroppedUnits = job.parser.droppedUnits
                    }
                    if job.writer.frames > before { job.lastPLI = now() }
                }
            } catch { job.failure = error; finish(job, reason: "video_error") }
        }
    }

    private func tick() {
        guard let job = current, job.result == nil else { return }
        let now = now()
        pendingLock.lock(); let overflowed = overflow; pendingLock.unlock()
        if overflowed { job.failure = IPhoneUseError("recording_backpressure", "Bounded video queue overflowed"); finish(job, reason: "video_error"); return }
        if let started = job.refreshStarted {
            if now - started >= 30 || now - job.started >= job.duration {
                job.failure = IPhoneUseError("recording_refresh_timeout", "Media refresh exceeded the recording deadline")
                finish(job, reason: "media_refresh_failed")
            }
            return
        }
        guard job.receiver?.health()["healthy"] as? Bool == true else {
            job.failure = IPhoneUseError("recording_media_lost", "Owned media lost health during recording")
            finish(job, reason: "media_lost"); return
        }
        if !sharedDecoderIntact(job) {
            job.failure = IPhoneUseError("recording_incomplete", "Shared decoder lost continuity during recording")
            finish(job, reason: "video_error"); return
        }
        if now - job.started >= job.duration { finish(job, reason: "duration"); return }
        if job.snapshots == nil, !job.writer.hasFrame || job.parser.waitingForKeyframe, now - job.lastPLI >= 1 {
            job.receiver?.requestKeyframe(); job.lastPLI = now
        }
        if job.firstFrameAt == nil, now - job.started >= min(8, job.duration) {
            job.failure = IPhoneUseError("recording_no_keyframe", "No complete decodable keyframe received within the start budget")
            finish(job, reason: "no_keyframe")
        }
    }

    func stop(id: String, reason: String = "requested") throws -> [String: Any] {
        try queue.sync {
            guard let job = jobs[id] else { throw IPhoneUseError("recording_not_found", "Unknown recording ID in this session") }
            if job.result == nil { finish(job, reason: reason) }
            return facts(job)
        }
    }
    func endSegment(reason: String) {
        queue.sync { if let current, current.result == nil { finish(current, reason: reason) } }
    }

    struct SharedSource {
        let receiver: NativeRecordingSource
        let snapshots: NativeVideoSnapshot
        let mediaID: String
        let rotation: String
        let geometryChanged: Bool
    }

    // Keep the writer, recording ID and original deadline while replacing only
    // our quiescent media source. The previous image holds across the measured
    // capture gap; no synthetic frame or old RTP clock crosses the boundary.
    func refreshSharedSource(_ replace: () throws -> SharedSource) throws -> Bool {
        let job: Job = try queue.sync {
            guard let job = current, job.result == nil, let snapshots = job.snapshots,
                  job.refreshStarted == nil, job.writer.hasFrame,
                  job.receiver?.health()["healthy"] as? Bool == true, sharedDecoderIntact(job) else {
                throw IPhoneUseError("recording_refresh_unavailable", "Recording source is not healthy and ready for refresh")
            }
            snapshots.setRecordingHandler(nil)
            job.sourceGeneration += 1
            job.refreshStarted = now()
            // Continuity was checked before releasing this decoder. Its close
            // is intentional; faults in the replacement are checked separately.
            job.snapshots = nil
            return job
        }
        do {
            let replacement = try replace()
            return try queue.sync {
                guard job.result == nil, let started = job.refreshStarted else {
                    throw IPhoneUseError("recording_refresh_timeout", "Recording ended during media refresh")
                }
                let resumed = now()
                guard resumed - started < 30, resumed - job.started < job.duration else {
                    throw IPhoneUseError("recording_refresh_timeout", "Media refresh exceeded the recording deadline")
                }
                job.sourceRefreshes.append(["fromMediaSessionID": job.mediaID, "toMediaSessionID": replacement.mediaID,
                    "startedSeconds": started - job.started, "resumedSeconds": resumed - job.started,
                    "durationSeconds": resumed - started, "geometryChanged": replacement.geometryChanged])
                job.mediaID = replacement.mediaID
                job.receiver = replacement.receiver
                if replacement.geometryChanged || replacement.rotation != job.rotation {
                    job.refreshStarted = nil
                    finish(job, reason: "display_changed")
                    return true
                }
                let config = replacement.receiver.recordingConfiguration()
                guard Self.supports(config), config["RTPClockRate"] as? Int32 == job.writer.timescale,
                      replacement.receiver.health()["healthy"] as? Bool == true,
                      let seed = replacement.snapshots.previewFrame(), seed.firstPacketAt >= started else {
                    throw IPhoneUseError("recording_refresh_unverified", "Replacement source has no verified new image or compatible clock")
                }
                try job.writer.prepare(seed.pixels) // Reject dimensions changing within this MP4.
                job.snapshots = replacement.snapshots
                job.snapshotBaseline = replacement.snapshots.status()
                job.sharedTimestamp = nil // New SSRC/timestamp epoch; anchor to monotonic recording time.
                job.refreshStarted = nil
                let generation = job.sourceGeneration
                replacement.snapshots.setRecordingHandler { [weak self, weak job] frame in
                    guard let self, let job else { return }
                    self.enqueue(frame, job: job, generation: generation)
                }
                return false
            }
        } catch {
            queue.sync {
                if job.result == nil {
                    job.failure = error
                    finish(job, reason: "media_refresh_failed")
                }
            }
            throw error
        }
    }
    func close() -> [String: Any] {
        queue.sync {
            closed = true
            if let current, current.result == nil { finish(current, reason: "session_closed") }
            return ["recordingProcessExited": true, "recordingSinkDetached": true,
                    "recording": current.map(facts) ?? ["state": "idle", "method": "native_rtp"]]
        }
    }
    private func facts(_ job: Job) -> [String: Any] {
        if let result = job.result { return result }
        return ["recordingID": job.id, "state": job.firstFrameAt == nil ? (job.snapshots == nil ? "waiting_for_keyframe" : "waiting_for_frame") : "recording",
                "method": "native_rtp", "codec": "hevc", "path": job.directory.appendingPathComponent("screen.mp4").path,
                "requestedDurationSeconds": job.duration, "startedAt": job.startedAt, "mediaSessionID": job.mediaID,
                "displayRotation": job.rotation, "rtpClockRate": job.writer.timescale, "clockSource": job.usesSharedFrames ? "rtcp_sender_reports_with_host_start_anchor" : "rtcp_sender_reports",
                "rtpPackets": job.packets, "writtenFrames": job.writer.frames,
                "encoding": job.usesSharedFrames ? "shared_decoded_pixels_then_hevc_encode" : "apple_vra_decode_then_hevc_encode",
                "initialCachedFrameAgeSeconds": job.decodedSeedAge as Any? ?? NSNull(),
                "sourceRefreshes": job.sourceRefreshes,
                "withheldResolutionFrames": job.writer.withheldResolutionFrames,
                "reducedResolutionPolicy": "decode_references_hold_previous_presented_frame",
                "droppedAccessUnits": job.parser.droppedUnits,
                "discontinuities": job.parser.discontinuities, "malformedPackets": job.parser.malformedPackets,
                "startupDroppedAccessUnits": job.startupDroppedUnits,
                "fileValidated": false, "processStarted": false]
    }
    private func finish(_ job: Job, reason: String) {
        if let snapshots = job.snapshots { snapshots.setRecordingHandler(nil) } else { job.receiver?.setVideoHandler(nil) }; timer?.cancel(); timer = nil
        let stopped = now()
        let health = job.receiver?.health() ?? [:]
        var result = facts(job)
        result["stopReason"] = reason; result["sinkDetached"] = true
        result["stoppedAt"] = Date().timeIntervalSince1970
        result["elapsedSeconds"] = stopped - job.started
        result["firstFrameDelaySeconds"] = job.firstFrameAt.map { $0 - job.started } as Any? ?? NSNull()
        result["mediaSpanSeconds"] = job.writer.mediaSpanSeconds
        result["lastFrameAgeSeconds"] = job.writer.lastFrameReceivedAt.map { stopped - $0 } as Any? ?? NSNull()
        if let first = job.writer.firstFrameReceivedAt, let last = job.writer.lastFrameReceivedAt {
            result["frameReceiveSpanSeconds"] = last - first
        }
        result["receiverHealthAtStop"] = health
        result["rtpClockRateAtStop"] = job.receiver?.recordingConfiguration()["RTPClockRate"]
        // Explicit stop can beat the next timer tick that checks overflow.
        pendingLock.lock(); let overflowed = overflow; pendingLock.unlock()
        if overflowed, job.failure == nil {
            job.failure = IPhoneUseError("recording_backpressure", "Bounded video queue overflowed")
        }
        let normalStop = reason == "requested" || reason == "duration"
        if normalStop, health["healthy"] as? Bool != true, job.failure == nil {
            job.failure = IPhoneUseError("recording_media_lost", "Owned media lost health before recording stopped")
        }
        let intact = sharedDecoderIntact(job) && job.parser.malformedPackets == 0 && job.parser.discontinuities == 0
            && job.parser.droppedUnits == job.startupDroppedUnits
        var lastFrameDuration = 1.0 / 60
        var tailTimingSource = "nominal_frame_duration"
        if normalStop, job.failure == nil, intact, let last = job.writer.lastFrameReceivedAt {
            // A live static stream can send RTCP but no video. Preserve that
            // terminal hold, not a rescaled movie. Liveness does not prove the
            // screen was unchanged; report its last-frame age explicitly.
            lastFrameDuration = max(lastFrameDuration, stopped - last)
            tailTimingSource = "host_monotonic_receive"
        }
        result["lastFrameDurationSeconds"] = lastFrameDuration
        result["tailTimingSource"] = tailTimingSource
        do {
            result["finalizationStartedAt"] = Date().timeIntervalSince1970
            try job.writer.finish(lastFrameDurationSeconds: lastFrameDuration)
            result["finalizationFinishedAt"] = Date().timeIntervalSince1970
            result["writtenFrames"] = job.writer.frames
            result["encoderSetupMilliseconds"] = job.writer.encoderSetupMilliseconds
            result["maximumAppendMilliseconds"] = job.writer.maximumAppendMilliseconds
            result["validationStartedAt"] = Date().timeIntervalSince1970
            let video = try NativeRecordingValidation.inspect(job.directory.appendingPathComponent("screen.mp4"))
            result["video"] = video
            guard video["decodedFrames"] as? Int == job.writer.frames else {
                throw IPhoneUseError("recording_incomplete", "Encoded frame count differs from admitted images")
            }
            if let failure = job.failure { throw failure }
            guard intact else {
                throw IPhoneUseError("recording_incomplete", "Video contains a recovered RTP interruption; preserved segment is not a complete recording")
            }
            result["state"] = "completed"; result["fileValidated"] = true
            result["verification"] = "Inspect the video to verify the intended app and action; file completion is not action confirmation."
            if job.writer.withheldResolutionFrames > 0 {
                result["verification"] = "Reduced-resolution pictures were decoded for reference continuity but omitted from presentation; inspect withheldResolutionFrames and the video. File completion is not action confirmation."
            }
        } catch {
            let error = job.failure ?? error
            job.writer.cancel(); result["state"] = "failed"; result["fileValidated"] = false
            result["error"] = ["code": (error as? IPhoneUseError)?.code ?? "recording_invalid", "message": String(describing: error)]
        }
        if result["validationStartedAt"] != nil { result["validationFinishedAt"] = Date().timeIntervalSince1970 }
        job.result = result
        try? saveJSON(result, to: job.directory.appendingPathComponent("result.json"))
        // Delivery must enqueue onto the owner's serial queue, never reenter
        // this recorder synchronously while finish holds its queue.
        onFinish(job.id, job.mediaID)
    }
}
