import Foundation
import CoreGraphics
import ImageIO
import AppleNativeBridge

extension AppleDeviceBackend {
    func releaseRecordingMediaIfFinished(force: Bool = false) {
        guard recording?.isActive != true, preview == nil || force, media?.isActive == true else { return }
        preview?.suspend("Synchronizing display")
        recordingMediaCleanup = media?.close() ?? ["mediaStopAcknowledged": true]
        if let currentRecordingID { recordingCleanupByID[currentRecordingID] = recordingMediaCleanup }
        media = nil
        if recordingMediaCleanup["mediaStopAcknowledged"] as? Bool != true {
            controlErrorCode = "native_media_cleanup_unconfirmed"
            controlError =
                """
                Owned recording media stop was not confirmed; close this session and inspect cleanup before\
                 reconnecting
                """
        }
    }
    func startRecording(duration: Double) throws -> [String: Any] {
        guard let cli, let recording, !stopped else {
            throw IPhoneUseError("backend_unavailable", "Native backend not started")
        }
        try cancellation.check()
        guard eventDeliveryQueue != nil else {
            throw IPhoneUseError(
                "native_recording_unavailable", "Recording requires serialized completion delivery")
        }
        _ = try NativeRecordingOptions.duration(["duration": duration])
        guard !recording.isActive else {
            throw IPhoneUseError("recording_busy", "A recording is already active")
        }
        releaseRecordingMediaIfFinished()
        let control = controlStatus(mediaHealth: mediaStatus)
        guard control.available else {
            throw IPhoneUseError(
                control.code ?? "native_recording_unavailable",
                control.message ?? "Native control unavailable")
        }
        currentRecordingID = nil
        guard hid?.state == .ready else {
            throw IPhoneUseError("native_recording_unavailable", "Need ready HID before recording")
        }
        guard try cli.read(["device", "info", "lockState"])["passcodeRequired"] as? Bool == false else {
            throw IPhoneUseError("device_locked", "Unlock the device before recording")
        }
        let display = try cli.display()
        guard display.backlightOn else {
            throw IPhoneUseError("capture_unavailable", "Wake the display before recording")
        }
        guard display.nativeRotation == "rot0", NativeVideoOrientation(rawValue: display.rotation) != nil
        else {
            throw IPhoneUseError(
                "native_recording_orientation_unsupported",
                "Recording requires verified native portrait display axes")
        }
        // SessionHost invalidates observations before this explicit command.
        // Start a stream only for this explicit recording. NativeMediaSession
        // checks the ownership inventory and refuses to replace another client.
        if media == nil { media = try makeMediaSession() }
        do {
            return try beginRecording(duration: duration, cli: cli, recording: recording, display: display)
        } catch {
            releaseRecordingMediaIfFinished()
            throw error
        }
    }
    private func beginRecording(
        duration: Double, cli: AppleDeviceCLI, recording: NativeStreamRecording,
        display: NativeDisplay
    ) throws -> [String: Any] {
        guard let media else {
            throw IPhoneUseError("native_recording_unavailable", "Native media session unavailable")
        }
        if preview != nil {
            // Reuse the already decoded stream; no keyframe refresh is needed.
            try media.ensureDisplay(display, mayReplace: hid?.state == .ready)
        } else {
            try media.refreshForRecording(display, mayReplace: hid?.state == .ready)
        }
        attachPreview()
        guard let receiver = media.recordingReceiver,
            let mediaID = media.health()["mediaSessionID"] as? String
        else {
            throw IPhoneUseError("native_recording_unavailable", "Fresh owned recording stream unavailable")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while receiver.recordingConfiguration()["RTPClockRate"] == nil,
            ProcessInfo.processInfo.systemUptime < deadline {
            try cancellation.check(); Thread.sleep(forTimeInterval: 0.05)
        }
        try cancellation.check()
        guard try cli.display() == display else {
            throw IPhoneUseError(
                "capture_context_changed", "Display changed while preparing recording; observe again")
        }
        let result = try recording.start(
            duration: duration, receiver: receiver, mediaID: mediaID, rotation: display.rotation,
            snapshots: receiver.snapshots)
        currentRecordingID = result["recordingID"] as? String
        return result
    }

    func stopRecording(id: String) throws -> [String: Any] {
        guard let recording else { throw IPhoneUseError("backend_unavailable", "Native backend not started") }
        var result = try recording.stop(id: id)
        releaseRecordingMediaIfFinished()
        let cleanup = recordingCleanupByID[id] ?? [:]
        result["mediaCleanup"] = cleanup
        result["mediaRetainedForPreview"] = preview != nil && media?.isActive == true
        if cleanup["mediaStopAcknowledged"] as? Bool == false {
            throw ActionFailure(
                code: "recording_cleanup_unconfirmed",
                description: "Recording stopped but media cleanup was not confirmed",
                possiblyExecuted: true, requiresObservation: true, result: result)
        }
        return result
    }
}
