import Foundation
import CoreVideo

extension NativeStreamRecording {

    func enqueue(_ frame: NativeVideoSnapshot.Frame, job: Job, generation: Int = 0) {
        // Retained full-resolution pixel buffers are expensive. Fail explicitly
        // at a bounded backlog instead of blocking the shared decoder/preview.
        let bytes = CVPixelBufferGetDataSize(frame.pixels)
        pendingLock.lock()
        guard pendingBytes + bytes <= 64 * 1024 * 1024 else { overflow = true; pendingLock.unlock(); return }
        pendingBytes += bytes; pendingLock.unlock()
        queue.async { [self] in
            defer { pendingLock.lock(); pendingBytes -= bytes; pendingLock.unlock() }
            guard job.result == nil, job === current, job.refreshStarted == nil,
                job.sourceGeneration == generation
            else { return }
            do {
                if job.firstFrameAt == nil {
                    job.decodedSeedAge = max(0, job.started - frame.firstPacketAt)
                    try job.writer.appendDecoded(
                        frame.pixels, seconds: max(0, frame.firstPacketAt - job.started),
                        receivedAt: max(job.started, frame.firstPacketAt))
                    job.firstFrameAt = max(job.started, frame.firstPacketAt)
                    if frame.firstPacketAt > job.started {
                        job.sharedTimestamp = frame.timestamp
                        job.sharedTicks = Int64(
                            ((frame.firstPacketAt - job.started) * Double(job.writer.timescale)).rounded())
                    }
                } else if frame.firstPacketAt > job.started {
                    // Burst delivery can assign multiple frames the same host
                    // tick. Keep the source RTP spacing after the start anchor.
                    if let previous = job.sharedTimestamp {
                        let delta = Int32(bitPattern: frame.timestamp &- previous)
                        guard delta > 0, Int64(delta) < Int64(job.writer.timescale) * 330 else {
                            throw IPhoneUseError(
                                "recording_timestamp_invalid", "Shared RTP timestamp is discontinuous")
                        }
                        job.sharedTicks += Int64(delta)
                    } else {
                        job.sharedTicks = max(
                            1,
                            Int64(
                                ((frame.firstPacketAt - job.started) * Double(job.writer.timescale)).rounded()
                            ))
                    }
                    job.sharedTimestamp = frame.timestamp
                    try job.writer.appendDecoded(
                        frame.pixels, seconds: Double(job.sharedTicks) / Double(job.writer.timescale),
                        receivedAt: frame.firstPacketAt)
                }
            } catch { job.failure = error; finish(job, reason: "video_error") }
        }
    }

    func sharedDecoderIntact(_ job: Job) -> Bool {
        guard let snapshots = job.snapshots else { return true }
        let status = snapshots.status()
        return status["closed"] as? Bool != true
            && [
                "decodeErrors", "queueOverflows", "droppedUnits", "discontinuities", "malformedPackets",
                "timestampRejections"
            ].allSatisfy {
                status[$0] as? Int == job.snapshotBaseline[$0] as? Int
            }
    }

    func enqueue(_ data: Data, job: Job) {
        // Stamp on admission, before waiting behind disk/codec work. Carry the
        // first packet's receive time through access-unit assembly.
        let receivedAt = now()
        pendingLock.lock()
        guard pendingBytes + data.count <= 4 * 1024 * 1024 else {
            overflow = true; pendingLock.unlock(); return
        }
        pendingBytes += data.count; pendingLock.unlock()
        queue.async { [self] in
            defer { pendingLock.lock(); pendingBytes -= data.count; pendingLock.unlock() }
            guard job.result == nil, job === current else { return }
            do {
                let packet = try NativeRTPPacket(data)
                guard packet.payloadType == 100,
                    packet.ssrc == (job.configuration["LocalSSRC"] as? NSNumber)?.uint32Value
                else { return }
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

    func tick() {
        guard let job = current, job.result == nil else { return }
        let now = now()
        pendingLock.lock(); let overflowed = overflow; pendingLock.unlock()
        if overflowed {
            job.failure = IPhoneUseError("recording_backpressure", "Bounded video queue overflowed")
            finish(job, reason: "video_error"); return
        }
        if let started = job.refreshStarted {
            if now - started >= 30 || now - job.started >= job.duration {
                job.failure = IPhoneUseError(
                    "recording_refresh_timeout", "Media refresh exceeded the recording deadline")
                finish(job, reason: "media_refresh_failed")
            }
            return
        }
        guard job.receiver?.health()["healthy"] as? Bool == true else {
            job.failure = IPhoneUseError("recording_media_lost", "Owned media lost health during recording")
            finish(job, reason: "media_lost"); return
        }
        if !sharedDecoderIntact(job) {
            job.failure = IPhoneUseError(
                "recording_incomplete", "Shared decoder lost continuity during recording")
            finish(job, reason: "video_error"); return
        }
        if now - job.started >= job.duration { finish(job, reason: "duration"); return }
        if job.snapshots == nil, !job.writer.hasFrame || job.parser.waitingForKeyframe, now - job.lastPLI >= 1 {
            job.receiver?.requestKeyframe(); job.lastPLI = now
        }
        if job.firstFrameAt == nil, now - job.started >= min(8, job.duration) {
            job.failure = IPhoneUseError(
                "recording_no_keyframe", "No complete decodable keyframe received within the start budget")
            finish(job, reason: "no_keyframe")
        }
    }
}
