import Foundation
import CoreVideo

extension NativeStreamRecording {

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
                job.receiver?.health()["healthy"] as? Bool == true, sharedDecoderIntact(job)
            else {
                throw IPhoneUseError(
                    "recording_refresh_unavailable", "Recording source is not healthy and ready for refresh")
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
                try resumeSource(replacement, job: job)
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
    // Runs on the recording queue after the external replacement operation joins.
    private func resumeSource(_ replacement: SharedSource, job: Job) throws -> Bool {
        guard job.result == nil, let started = job.refreshStarted else {
            throw IPhoneUseError("recording_refresh_timeout", "Recording ended during media refresh")
        }
        let resumed = now()
        guard resumed - started < 30, resumed - job.started < job.duration else {
            throw IPhoneUseError("recording_refresh_timeout", "Media refresh exceeded the recording deadline")
        }
        job.sourceRefreshes.append([
            "fromMediaSessionID": job.mediaID, "toMediaSessionID": replacement.mediaID,
            "startedSeconds": started - job.started, "resumedSeconds": resumed - job.started,
            "durationSeconds": resumed - started, "geometryChanged": replacement.geometryChanged
        ])
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
            let seed = replacement.snapshots.previewFrame(), seed.firstPacketAt >= started
        else {
            throw IPhoneUseError(
                "recording_refresh_unverified",
                "Replacement source has no verified new image or compatible clock")
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
}
