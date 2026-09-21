import Foundation
import AVFoundation
import CoreVideo
import Darwin

// One owned Apple CLI process per recording. This queue is independent of the
// device work queue so recording never prevents a subsequent stop or HID action.
final class NativeScreenRecording {
    private final class Job {
        let id = UUID().uuidString
        let process = Process()
        let directory: URL
        let duration: Double
        let started = Date().timeIntervalSince1970
        let startedUptime = ProcessInfo.processInfo.systemUptime
        var stopAt: Double?
        var stopReason: String?
        var forced = false
        var log: FileHandle?
        var result: [String: Any]?
        init(root: URL, duration: Double) {
            self.duration = duration
            directory = root.appendingPathComponent(id, isDirectory: true)
        }
        var movie: URL { directory.appendingPathComponent("screen.mp4") }
    }
    private let queue = DispatchQueue(label: "agentsoma.native.recording")
    private let root: URL
    private let configure: (Process, URL, Double, URL) -> Void
    private let validate: (URL) throws -> [String: Any]
    private let grace: Double
    private var jobs: [String: Job] = [:]
    private var current: Job?
    private var timer: DispatchSourceTimer?
    private var closed = false

    init(root: URL, device: String, grace: Double = 12,
         configure: ((Process, URL, Double, URL) -> Void)? = nil,
         validate: @escaping (URL) throws -> [String: Any] = NativeRecordingValidation.inspect) {
        self.root = root; self.grace = grace; self.validate = validate
        self.configure = configure ?? { process, movie, duration, report in
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["devicectl", "device", "capture", "screen-record", "--device", device,
                "--destination", movie.path, "--codec", "h264", "--duration", String(duration),
                "--json-output", report.path]
        }
    }

    static func supported(by details: [String: Any]) -> Bool {
        (details["capabilities"] as? [[String: Any]])?.contains {
            $0["featureIdentifier"] as? String == "com.apple.coredevice.feature.screenrecording"
        } == true
    }

    static func duration(_ request: [String: Any]) throws -> Double {
        guard let value = request["duration"] as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
              (1...300).contains(value.doubleValue) else {
            throw SomaError("invalid_recording_duration", "Recording duration must be 1–300 seconds")
        }
        return value.doubleValue
    }

    var isActive: Bool { queue.sync { current?.result == nil && current != nil } }

    func start(duration: Double) throws -> [String: Any] {
        try queue.sync {
            guard !closed else { throw SomaError("recording_closed", "Recording owner is closed") }
            if let current, current.result == nil { throw SomaError("recording_busy", "A recording is already active; inspect status or stop its recording ID") }
            _ = try Self.duration(["duration": duration])
            try SessionPaths.secureDirectory(root)
            let job = Job(root: root, duration: duration)
            try SessionPaths.secureDirectory(job.directory)
            let logURL = job.directory.appendingPathComponent("command.log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            job.log = try FileHandle(forWritingTo: logURL)
            configure(job.process, job.movie, duration, job.directory.appendingPathComponent("apple-result.json"))
            job.process.standardInput = FileHandle.nullDevice
            job.process.standardOutput = job.log
            job.process.standardError = job.log
            do { try job.process.run() }
            catch { try? job.log?.close(); throw error }
            jobs[job.id] = job; current = job
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 0.1)
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer; timer.resume()
            return facts(job)
        }
    }

    func status() -> [String: Any] {
        queue.sync { current.map(facts) ?? ["state": "idle"] }
    }

    // Stop is keyed by recording ID, so an old or repeated request cannot stop
    // a newer recording. SIGINT is Apple's documented save-and-stop path.
    func stop(id: String, reason: String = "requested") throws -> [String: Any] {
        try queue.sync {
            guard let job = jobs[id] else { throw SomaError("recording_not_found", "Unknown recording ID in this session") }
            requestStop(job, reason: reason)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + grace + 5
        while ProcessInfo.processInfo.systemUptime < deadline {
            let result = queue.sync { jobs[id].map(facts) ?? [:] }
            if result["state"] as? String == "completed" || result["state"] as? String == "failed" { return result }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return queue.sync { facts(jobs[id]!) }
    }

    func close() -> [String: Any] {
        let id: String? = queue.sync { closed = true; return current?.id }
        guard let id else { return ["recordingProcessExited": true] }
        let result = (try? stop(id: id, reason: "session_closed")) ?? [:]
        return ["recordingProcessExited": result["processExited"] as? Bool == true,
                "recording": result]
    }

    private func requestStop(_ job: Job, reason: String) {
        guard job.result == nil, job.stopAt == nil else { return }
        job.stopReason = reason; job.stopAt = ProcessInfo.processInfo.systemUptime
        if job.process.isRunning { job.process.interrupt() }
    }

    private func tick() {
        guard let job = current, job.result == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if job.process.isRunning {
            if job.stopAt == nil, now - job.startedUptime > job.duration + 20 { requestStop(job, reason: "deadline") }
            if let stop = job.stopAt, now - stop > grace {
                job.forced = true
                if now - stop > grace + 2 { kill(job.process.processIdentifier, SIGKILL) }
                else { job.process.terminate() }
            }
            return
        }
        job.process.waitUntilExit()
        timer?.cancel(); timer = nil
        try? job.log?.close(); job.log = nil
        var result = baseFacts(job)
        result["processExited"] = true
        result["exitCode"] = job.process.terminationStatus
        result["terminationReason"] = job.process.terminationReason == .exit ? "exit" : "signal"
        result["forced"] = job.forced
        result["stoppedAt"] = Date().timeIntervalSince1970
        do {
            // A successful process status is insufficient. Decode the complete
            // video and require finite positive duration and ordered timestamps.
            if job.process.terminationStatus != 0 {
                let report = try? jsonObject(Data(contentsOf: job.directory.appendingPathComponent("apple-result.json")))
                let error = report?["error"] as? [String: Any]
                let info = error?["userInfo"] as? [String: Any]
                let feature = (info?["CapabilityFeatureIdentifier"] as? [String: Any])?["string"] as? String
                if error?["domain"] as? String == "com.apple.dt.CoreDeviceError", error?["code"] as? Int == 1001,
                   feature == "com.apple.coredevice.feature.screenrecording" {
                    throw SomaError("native_recording_unsupported", "Apple reports that this device does not support Screen Recording")
                }
                throw SomaError("recording_process_failed", "Apple recording process failed; inspect command.log and apple-result.json in the recording directory")
            }
            let video = try validate(job.movie)
            result["video"] = video
            if let seconds = video["durationSeconds"] as? Double {
                guard seconds <= job.duration + 5,
                      job.stopReason != nil || seconds >= max(0.1, job.duration - 2) else {
                    throw SomaError("recording_duration_mismatch", "Decoded duration does not match the requested recording interval")
                }
            }
            guard !job.forced, job.stopReason != "deadline", job.process.terminationStatus == 0 else {
                throw SomaError("recording_process_failed", "Recording did not stop normally; a partial artifact may remain")
            }
            result["state"] = "completed"; result["fileValidated"] = true
        } catch {
            result["state"] = "failed"; result["fileValidated"] = false
            result["error"] = ["code": (error as? SomaError)?.code ?? "recording_invalid", "message": String(describing: error)]
        }
        job.result = result
        try? saveJSON(result, to: job.directory.appendingPathComponent("result.json"))
    }

    private func baseFacts(_ job: Job) -> [String: Any] {
        ["recordingID": job.id, "path": job.movie.path, "requestedDurationSeconds": job.duration,
         "startedAt": job.started, "processID": job.process.processIdentifier,
         "stopReason": job.stopReason as Any? ?? NSNull(), "codec": "h264",
         "verification": "File validation does not verify the intended app or action; inspect the video."]
    }
    private func facts(_ job: Job) -> [String: Any] {
        if let result = job.result { return result }
        var result = baseFacts(job)
        result["state"] = job.stopAt == nil ? "starting_or_recording" : "stopping"
        result["processExited"] = false; result["fileValidated"] = false
        return result
    }
}

enum NativeRecordingValidation {
    static func inspect(_ url: URL) throws -> [String: Any] {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let bytes = attributes[.size] as? NSNumber, bytes.int64Value > 0 else {
            throw SomaError("recording_invalid", "Recording is not a nonempty regular file")
        }
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(asset.duration)
        guard seconds.isFinite, seconds > 0, seconds <= 330,
              let track = asset.tracks(withMediaType: .video).first else {
            throw SomaError("recording_invalid", "Recording has no finite video duration/track")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw SomaError("recording_invalid", "Video track cannot be decoded") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? SomaError("recording_invalid", "Cannot start video decoder") }
        defer { reader.cancelReading() }
        var count = 0, first = 0.0, last = -Double.infinity, width = 0, height = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while let sample = output.copyNextSampleBuffer() {
            guard ProcessInfo.processInfo.systemUptime < deadline,
                  let pixels = CMSampleBufferGetImageBuffer(sample) else {
                throw SomaError("recording_validation_timeout", "Video validation exceeded its budget or returned no decoded image")
            }
            let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            guard time.isFinite, time >= last else { throw SomaError("recording_invalid", "Video timestamps are invalid") }
            if count == 0 { first = time; width = CVPixelBufferGetWidth(pixels); height = CVPixelBufferGetHeight(pixels) }
            last = time; count += 1
        }
        guard reader.status == .completed, count > 0, width > 0, height > 0 else {
            throw reader.error ?? SomaError("recording_invalid", "Video did not decode completely")
        }
        return ["durationSeconds": seconds, "decodedFrames": count, "firstFrameSeconds": first,
                "lastFrameSeconds": last, "width": width, "height": height, "bytes": bytes]
    }
}
