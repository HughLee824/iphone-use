import Foundation
import CoreVideo

extension NativeStreamRecording {
    func facts(_ job: Job) -> [String: Any] {
        if let result = job.result { return result }
        return [
            "recordingID": job.id,
            "state": job.firstFrameAt == nil
                ? (job.snapshots == nil ? "waiting_for_keyframe" : "waiting_for_frame") : "recording",
            "method": "native_rtp", "codec": "hevc",
            "path": job.directory.appendingPathComponent("screen.mp4").path,
            "requestedDurationSeconds": job.duration, "startedAt": job.startedAt,
            "mediaSessionID": job.mediaID,
            "displayRotation": job.rotation, "rtpClockRate": job.writer.timescale,
            "clockSource": job.usesSharedFrames
                ? "rtcp_sender_reports_with_host_start_anchor" : "rtcp_sender_reports",
            "rtpPackets": job.packets, "writtenFrames": job.writer.frames,
            "encoding": job.usesSharedFrames
                ? "shared_decoded_pixels_then_hevc_encode" : "apple_vra_decode_then_hevc_encode",
            "initialCachedFrameAgeSeconds": job.decodedSeedAge as Any? ?? NSNull(),
            "sourceRefreshes": job.sourceRefreshes,
            "withheldResolutionFrames": job.writer.withheldResolutionFrames,
            "reducedResolutionPolicy": "decode_references_hold_previous_presented_frame",
            "droppedAccessUnits": job.parser.droppedUnits,
            "discontinuities": job.parser.discontinuities, "malformedPackets": job.parser.malformedPackets,
            "startupDroppedAccessUnits": job.startupDroppedUnits,
            "fileValidated": false, "processStarted": false
        ]
    }
    func finish(_ job: Job, reason: String) {
        if let snapshots = job.snapshots {
            snapshots.setRecordingHandler(nil)
        } else {
            job.receiver?.setVideoHandler(nil)
        }; timer?.cancel(); timer = nil
        let stopped = now()
        let health = job.receiver?.health() ?? [:]
        var result = facts(job)
        result["stopReason"] = reason; result["sinkDetached"] = true
        result["stoppedAt"] = Date().timeIntervalSince1970
        result["elapsedSeconds"] = stopped - job.started
        result["firstFrameDelaySeconds"] = job.firstFrameAt.map { $0 - job.started } as Any? ?? NSNull()
        result["mediaSpanSeconds"] = job.writer.mediaSpanSeconds
        result["lastFrameAgeSeconds"] =
            job.writer.lastFrameReceivedAt.map { stopped - $0 } as Any? ?? NSNull()
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
            job.failure = IPhoneUseError(
                "recording_media_lost", "Owned media lost health before recording stopped")
        }
        let intact =
            sharedDecoderIntact(job) && job.parser.malformedPackets == 0 && job.parser.discontinuities == 0
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
        finalize(job, lastFrameDuration: lastFrameDuration, intact: intact, result: &result)
        if result["validationStartedAt"] != nil {
            result["validationFinishedAt"] = Date().timeIntervalSince1970
        }
        job.result = result
        try? saveJSON(result, to: job.directory.appendingPathComponent("result.json"))
        // Delivery must enqueue onto the owner's serial queue, never reenter
        // this recorder synchronously while finish holds its queue.
        onFinish(job.id, job.mediaID)
    }
    private func finalize(_ job: Job, lastFrameDuration: Double, intact: Bool, result: inout [String: Any]) {
        do {
            result["finalizationStartedAt"] = Date().timeIntervalSince1970
            try job.writer.finish(lastFrameDurationSeconds: lastFrameDuration)
            result["finalizationFinishedAt"] = Date().timeIntervalSince1970
            result["writtenFrames"] = job.writer.frames
            result["encoderSetupMilliseconds"] = job.writer.encoderSetupMilliseconds
            result["maximumAppendMilliseconds"] = job.writer.maximumAppendMilliseconds
            result["validationStartedAt"] = Date().timeIntervalSince1970
            let video = try NativeRecordingValidation.inspect(
                job.directory.appendingPathComponent("screen.mp4"))
            result["video"] = video
            guard video["decodedFrames"] as? Int == job.writer.frames else {
                throw IPhoneUseError(
                    "recording_incomplete", "Encoded frame count differs from admitted images")
            }
            if let failure = job.failure { throw failure }
            guard intact else {
                throw IPhoneUseError(
                    "recording_incomplete",
                    "Video contains a recovered RTP interruption; preserved segment is not a complete recording"
                )
            }
            result["state"] = "completed"; result["fileValidated"] = true
            result["verification"] =
                """
                Inspect the video to verify the intended app and action; file completion is not action\
                 confirmation.
                """
            if job.writer.withheldResolutionFrames > 0 {
                result["verification"] =
                    """
                    Reduced-resolution pictures were decoded for reference continuity but omitted from\
                     presentation; inspect withheldResolutionFrames and the video. File completion is not\
                     action confirmation.
                    """
            }
        } catch {
            let error = job.failure ?? error
            job.writer.cancel(); result["state"] = "failed"; result["fileValidated"] = false
            result["error"] = [
                "code": (error as? IPhoneUseError)?.code ?? "recording_invalid",
                "message": String(describing: error)
            ]
        }
    }
}
