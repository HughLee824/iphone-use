import Foundation
import CoreGraphics
import ImageIO
import AppleNativeBridge

extension AppleDeviceBackend {
    func showPreviewGesture(_ gesture: NativePreviewGesture) { preview?.showGesture(gesture) }
    var previewGestureRotation: String? { preview?.gestureRotation }
    func attachPreview() {
        if let receiver = media?.recordingReceiver, let display = media?.boundDisplay {
            preview?.attach(receiver, display: display)
        }
    }
    func ensurePreviewMedia(_ display: NativeDisplay) throws {
        guard display.nativeRotation == "rot0", NativeVideoOrientation(rawValue: display.rotation) != nil
        else {
            throw IPhoneUseError("preview_display_unavailable", "Preview needs supported display orientation")
        }
        if media == nil { media = try makeMediaSession() }
        try media?.ensureDisplay(display, mayReplace: hid?.state == .ready)
        attachPreview()
    }
    func startPreview(options: NativePreviewOptions = NativePreviewOptions()) throws -> [String: Any] {
        try cancellation.check()
        if let preview { return try preview.status(for: options) }
        guard controlError == nil, hid?.state == .ready, let cli,
            recordingMediaCleanup["mediaStopAcknowledged"] as? Bool != false
        else {
            throw IPhoneUseError("preview_unavailable", "Native control or media cleanup is not ready")
        }
        let preview = try NativePreview(
            port: options.port, device: previewDevice, owner: PreviewOwner(device: cli.device))
        self.preview = preview
        previewFailure = nil
        do {
            let facts = try NativeCaptureChecks.read(requireBacklight: false) { try cli.read($0) }
            try ensurePreviewMedia(facts.display)
            return preview.status()
        } catch {
            preview.close(); self.preview = nil; releaseRecordingMediaIfFinished(); throw error
        }
    }
    func stopPreview() throws -> [String: Any] {
        preview?.close(); preview = nil
        releaseRecordingMediaIfFinished()
        guard recordingMediaCleanup["mediaStopAcknowledged"] as? Bool != false else {
            throw IPhoneUseError(
                "native_media_cleanup_unconfirmed", "Preview closed but media stop is unconfirmed")
        }
        return ["state": "stopped", "mediaRetainedForRecording": recording?.isActive == true]
    }
    func previewTick() -> Bool {
        guard let preview, !stopped, !cancellation.isCancelled, let cli, controlError == nil else {
            return false
        }
        var checkingDisplay = true
        do {
            let display = try NativeCaptureChecks.read(requireBacklight: false) {
                try cli.read($0, timeout: 3)
            }.display
            let recovery = previewContinuity.needsRecovery(
                media?.recordingReceiver?.snapshots?.status() ?? [:])
            var changed = recovery || media?.matchesDisplay(display) != true
            var reason = recovery ? "decoder_continuity_lost" : "display_metadata_changed"
            do { try media?.recordingReceiver?.snapshots?.rejectConflictingGeometry(display) } catch {
                changed = true; reason = "frame_geometry_conflict: \(error)"
            }
            if !changed {
                changed = try previewOrientation.needsRefresh(
                    cli: cli, snapshots: media?.recordingReceiver?.snapshots, display: display)
                if changed { reason = "frame_rotation_conflict" }
            }
            if changed {
                checkingDisplay = false
                try refreshPreview(preview, recovery: recovery, reason: reason, cli: cli)
            } else {
                attachPreview()
            }
            return changed
        } catch {
            let health = media?.health() ?? [:]
            if checkingDisplay, !cancellation.isCancelled, NativePreviewPoll.canDefer(error, health: health) {
                NativePreviewEvents.append(
                    to: paths.directory.appendingPathComponent("preview-events.jsonl"),
                    event: "poll_deferred", reason: String(describing: error), source: health)
                return false // Keep the same media and URL; the next scheduled poll checks again.
            }
            previewFailure = String(describing: error)
            preview.suspend(String(describing: error))
            recording?.endSegment(reason: "preview_display_unavailable")
            releaseRecordingMediaIfFinished(force: true)
            // Terminal until explicit stop/start; never retry an uncertain start.
            preview.close(); self.preview = nil
            return true
        }
    }
    private func refreshPreview(_ preview: NativePreview, recovery: Bool, reason: String, cli: AppleDeviceCLI)
        throws {
        NativePreviewEvents.append(
            to: paths.directory.appendingPathComponent("preview-events.jsonl"),
            event: "refresh_started", reason: reason, source: media?.health() ?? [:])
        preview.suspend(recovery ? "Recovering video continuity" : "Synchronizing rotation")
        recording?.endSegment(reason: recovery ? "media_discontinuity" : "display_changed")
        releaseRecordingMediaIfFinished(force: true)
        guard recordingMediaCleanup["mediaStopAcknowledged"] as? Bool != false else {
            throw IPhoneUseError("native_media_cleanup_unconfirmed", "Media stop unconfirmed")
        }
        let refreshed = try NativeCaptureChecks.read(requireBacklight: false) { try cli.read($0, timeout: 3) }
            .display
        try ensurePreviewMedia(refreshed)
        NativePreviewEvents.append(
            to: paths.directory.appendingPathComponent("preview-events.jsonl"),
            event: "refresh_completed", reason: reason, source: media?.health() ?? [:])
    }

}
