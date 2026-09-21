import Foundation

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
        let startedAt = Date().timeIntervalSince1970
        let started = ProcessInfo.processInfo.systemUptime
        let mediaID: String
        let configuration: [String: Any]
        let rotation: String
        weak var receiver: NativeRecordingSource?
        var parser = NativeHEVCDepacketizer()
        let writer: NativeVideoWriter
        var result: [String: Any]?
        var packets = 0
        var lastPLI = 0.0
        var firstFrameAt: Double?
        var startupDroppedUnits = 0
        var failure: Error?
        init(root: URL, duration: Double, receiver: NativeRecordingSource, mediaID: String, rotation: String, configuration: [String: Any], clock: Int32) {
            self.duration = duration; self.receiver = receiver; self.mediaID = mediaID
            self.configuration = configuration; self.rotation = rotation
            directory = root.appendingPathComponent(id)
            writer = NativeVideoWriter(url: directory.appendingPathComponent("screen.mp4"), timescale: clock)
        }
    }
    private let queue = DispatchQueue(label: "agentsoma.native.recording.stream")
    private let pendingLock = NSLock()
    private var pendingBytes = 0
    private var overflow = false
    private var timer: DispatchSourceTimer?
    private let root: URL
    private var current: Job?
    private var jobs: [String: Job] = [:]
    private var closed = false
    init(root: URL) { self.root = root }

    static func supports(_ config: [String: Any]) -> Bool {
        config["RxPayloadType"] as? Int == 100 && config["TilesPerFrame"] as? Int == 1
            && config["SRTPCipherSuite"] as? Int == 0
    }
    var isActive: Bool { queue.sync { current != nil && current?.result == nil } }
    func status() -> [String: Any] { queue.sync { current.map(facts) ?? ["state": "idle", "method": "native_rtp"] } }

    func start(duration: Double, receiver: NativeRecordingSource, mediaID: String, rotation: String) throws -> [String: Any] {
        try queue.sync {
            guard !closed else { throw SomaError("recording_closed", "Recording owner closed") }
            guard current == nil || current?.result != nil else { throw SomaError("recording_busy", "A recording is already active") }
            _ = try NativeRecordingOptions.duration(["duration": duration])
            let config = receiver.recordingConfiguration()
            guard Self.supports(config), let clock = config["RTPClockRate"] as? Int32 else {
                throw SomaError("native_recording_format_unavailable", "Need the observed single-layer HEVC payload and a clock confirmed by sender reports")
            }
            let job = Job(root: root, duration: duration, receiver: receiver, mediaID: mediaID, rotation: rotation, configuration: config, clock: clock)
            try SessionPaths.secureDirectory(root); try SessionPaths.secureDirectory(job.directory)
            jobs[job.id] = job; current = job
            pendingLock.lock(); overflow = false; pendingLock.unlock()
            receiver.setVideoHandler { [weak self, weak job] data in
                guard let self, let job else { return }
                self.enqueue(data, job: job)
            }
            receiver.requestKeyframe(); job.lastPLI = job.started
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer; timer.resume()
            return facts(job)
        }
    }

    private func enqueue(_ data: Data, job: Job) {
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
                if let unit = job.parser.receive(packet) {
                    let before = job.writer.frames
                    try job.writer.append(unit)
                    if job.writer.hasFrame, job.firstFrameAt == nil {
                        job.firstFrameAt = ProcessInfo.processInfo.systemUptime
                        job.startupDroppedUnits = job.parser.droppedUnits
                    }
                    if job.writer.frames > before { job.lastPLI = ProcessInfo.processInfo.systemUptime }
                }
            } catch { job.failure = error; finish(job, reason: "video_error") }
        }
    }

    private func tick() {
        guard let job = current, job.result == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        pendingLock.lock(); let overflowed = overflow; pendingLock.unlock()
        if overflowed { job.failure = SomaError("recording_backpressure", "Bounded video queue overflowed"); finish(job, reason: "video_error"); return }
        guard job.receiver?.health()["healthy"] as? Bool == true else {
            job.failure = SomaError("recording_media_lost", "Owned media lost health during recording")
            finish(job, reason: "media_lost"); return
        }
        if now - job.started >= job.duration { finish(job, reason: "duration"); return }
        if !job.writer.hasFrame || job.parser.waitingForKeyframe, now - job.lastPLI >= 1 {
            job.receiver?.requestKeyframe(); job.lastPLI = now
        }
        if job.firstFrameAt == nil, now - job.started >= min(8, job.duration) {
            job.failure = SomaError("recording_no_keyframe", "No complete decodable keyframe received within the start budget")
            finish(job, reason: "no_keyframe")
        }
    }

    func stop(id: String, reason: String = "requested") throws -> [String: Any] {
        try queue.sync {
            guard let job = jobs[id] else { throw SomaError("recording_not_found", "Unknown recording ID in this session") }
            if job.result == nil { finish(job, reason: reason) }
            return facts(job)
        }
    }
    func endSegment(reason: String) {
        queue.sync { if let current, current.result == nil { finish(current, reason: reason) } }
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
        return ["recordingID": job.id, "state": job.firstFrameAt == nil ? "waiting_for_keyframe" : "recording",
                "method": "native_rtp", "codec": "hevc", "path": job.directory.appendingPathComponent("screen.mp4").path,
                "requestedDurationSeconds": job.duration, "startedAt": job.startedAt, "mediaSessionID": job.mediaID,
                "displayRotation": job.rotation, "rtpClockRate": job.writer.timescale, "clockSource": "rtcp_sender_reports",
                "rtpPackets": job.packets, "writtenFrames": job.writer.frames, "droppedAccessUnits": job.parser.droppedUnits,
                "discontinuities": job.parser.discontinuities, "malformedPackets": job.parser.malformedPackets,
                "startupDroppedAccessUnits": job.startupDroppedUnits,
                "fileValidated": false, "processStarted": false]
    }
    private func finish(_ job: Job, reason: String) {
        job.receiver?.setVideoHandler(nil); timer?.cancel(); timer = nil
        var result = facts(job)
        result["stopReason"] = reason; result["sinkDetached"] = true
        result["stoppedAt"] = Date().timeIntervalSince1970
        result["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - job.started
        result["firstFrameDelaySeconds"] = job.firstFrameAt.map { $0 - job.started } as Any? ?? NSNull()
        do {
            try job.writer.finish()
            result["writtenFrames"] = job.writer.frames
            let video = try NativeRecordingValidation.inspect(job.directory.appendingPathComponent("screen.mp4"))
            result["video"] = video
            if let failure = job.failure { throw failure }
            guard job.parser.malformedPackets == 0, job.parser.discontinuities == 0,
                  job.parser.droppedUnits == job.startupDroppedUnits else {
                throw SomaError("recording_incomplete", "Video contains a recovered RTP interruption; preserved segment is not a complete recording")
            }
            result["state"] = "completed"; result["fileValidated"] = true
            result["verification"] = "Inspect the video to verify the intended app and action; file completion is not action confirmation."
        } catch {
            let error = job.failure ?? error
            job.writer.cancel(); result["state"] = "failed"; result["fileValidated"] = false
            result["error"] = ["code": (error as? SomaError)?.code ?? "recording_invalid", "message": String(describing: error)]
        }
        job.result = result
        try? saveJSON(result, to: job.directory.appendingPathComponent("result.json"))
    }
}
