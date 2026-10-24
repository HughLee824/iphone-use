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
    final class Job {
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
        init(
            root: URL, duration: Double, receiver: NativeRecordingSource, mediaID: String,
            orientation: NativeVideoOrientation, configuration: [String: Any], clock: Int32, started: Double,
            makeWriter: (URL, Int32, NativeVideoOrientation) -> NativeVideoWriter
        ) {
            self.duration = duration; self.receiver = receiver; self.mediaID = mediaID
            self.started = started
            self.configuration = configuration; self.rotation = orientation.rawValue
            directory = root.appendingPathComponent(id)
            writer = makeWriter(directory.appendingPathComponent("screen.mp4"), clock, orientation)
        }
    }
    let queue = DispatchQueue(label: "iphone-use.native.recording.stream")
    let pendingLock = NSLock()
    var pendingBytes = 0
    var overflow = false
    var timer: DispatchSourceTimer?
    private let root: URL
    let now: () -> Double
    let onFinish: (_ recordingID: String, _ mediaID: String) -> Void
    var current: Job?
    private var jobs: [String: Job] = [:]
    var closed = false
    private let makeWriter: (URL, Int32, NativeVideoOrientation) -> NativeVideoWriter
    init(
        root: URL, now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
        onFinish: @escaping (String, String) -> Void = { _, _ in },
        makeWriter: @escaping (URL, Int32, NativeVideoOrientation) -> NativeVideoWriter = {
            NativeVideoWriter(url: $0, timescale: $1, orientation: $2)
        }
    ) {
        self.root = root; self.now = now; self.makeWriter = makeWriter; self.onFinish = onFinish
    }

    static func supports(_ config: [String: Any]) -> Bool {
        config["RxPayloadType"] as? Int == 100 && config["TilesPerFrame"] as? Int == 1
            && config["SRTPCipherSuite"] as? Int == 0
    }
    var isActive: Bool { queue.sync { current != nil && current?.result == nil } }
    func status() -> [String: Any] {
        queue.sync { current.map(facts) ?? ["state": "idle", "method": "native_rtp"] }
    }

    func start(
        duration: Double, receiver: NativeRecordingSource, mediaID: String, rotation: String,
        snapshots: NativeVideoSnapshot? = nil
    ) throws -> [String: Any] {
        try queue.sync {
            guard !closed else { throw IPhoneUseError("recording_closed", "Recording owner closed") }
            guard current == nil || current?.result != nil else {
                throw IPhoneUseError("recording_busy", "A recording is already active")
            }
            _ = try NativeRecordingOptions.duration(["duration": duration])
            guard let orientation = NativeVideoOrientation(rawValue: rotation) else {
                throw IPhoneUseError(
                    "native_recording_orientation_unsupported", "Unverified video orientation")
            }
            let config = receiver.recordingConfiguration()
            guard Self.supports(config), let clock = config["RTPClockRate"] as? Int32 else {
                throw IPhoneUseError(
                    "native_recording_format_unavailable",
                    "Need the observed single-layer HEVC payload and a clock confirmed by sender reports")
            }
            let job = Job(
                root: root, duration: duration, receiver: receiver, mediaID: mediaID,
                orientation: orientation,
                configuration: config, clock: clock, started: now(), makeWriter: makeWriter)
            try SessionPaths.secureDirectory(root); try SessionPaths.secureDirectory(job.directory)
            if let seed = snapshots?.previewFrame() {
                do { try job.writer.prepare(seed.pixels) } catch { job.writer.cancel(); throw error }
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
            } else {
                receiver.setVideoHandler { [weak self, weak job] data in
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

    func stop(id: String, reason: String = "requested") throws -> [String: Any] {
        try queue.sync {
            guard let job = jobs[id] else {
                throw IPhoneUseError("recording_not_found", "Unknown recording ID in this session")
            }
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
            return [
                "recordingProcessExited": true, "recordingSinkDetached": true,
                "recording": current.map(facts) ?? ["state": "idle", "method": "native_rtp"]
            ]
        }
    }
}
