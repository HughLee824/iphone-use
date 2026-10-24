import IPhoneUseRunnerSupport
import Foundation
import CoreGraphics
import ImageIO
import AppleNativeBridge

extension AppleDeviceBackend {
    func observe() throws -> CapturedObservation {
        try capture(
            budget: NativeCaptureBudget(
                requestDeadline: ProcessInfo.processInfo.systemUptime + 30, purpose: .observation))
    }
    func observeText(_ options: NativeTextObservationOptions) throws -> CapturedObservation {
        try capture(
            textOptions: options,
            budget: NativeCaptureBudget(
                requestDeadline: ProcessInfo.processInfo.systemUptime + 30, purpose: .observation))
    }
    func observeAfterAction(
        textOptions: NativeTextObservationOptions?, ignoring: ScreenRect?, sourceContext: ScreenContext?
    ) throws -> CapturedObservation {
        try NativePostActionStability.capture(
            ignoring: ignoring, sourceContext: sourceContext,
            checkCancellation: { try self.cancellation.check() },
            sample: { deadline in
                // All samples and owned recovery share one bounded post-action
                // deadline. No sampling can extend the original input lease.
                try self.capture(
                    textOptions: textOptions,
                    budget: NativeCaptureBudget(requestDeadline: deadline, purpose: .observation))
            })
    }
    func capture(textOptions: NativeTextObservationOptions? = nil, budget: NativeCaptureBudget? = nil) throws
        -> CapturedObservation {
        releaseRecordingMediaIfFinished()
        defer { attachPreview() }
        guard recordingMediaCleanup["mediaStopAcknowledged"] as? Bool != false else {
            throw IPhoneUseError(
                "native_media_cleanup_unconfirmed",
                "Owned media may still be active; screenshot orientation cannot be verified")
        }
        guard controlErrorCode != "native_orientation_unverified" else {
            throw IPhoneUseError("native_orientation_unverified", controlError!)
        }
        do {
            let observation = try NativeCaptureChecks.withOrientationRecovery(
                capture: { afterRefresh in
                    try budget?.check()
                    return try self.captureOnce(
                        mediaTimeout: afterRefresh ? 1 : 0.15, textOptions: textOptions, budget: budget)
                },
                resynchronize: {
                    try self.resynchronizeCapture(budget: budget)
                }, recordingActive: { self.recording?.isActive == true },
                resynchronizeRecording: {
                    try self.resynchronizeRecordingCapture(budget: budget)
                }, diagnostics: { self.media?.health() ?? [:] })
            releaseRecordingMediaIfFinished()
            return observation
        } catch let error as IPhoneUseError where error.code == "native_orientation_unverified" {
            recording?.endSegment(reason: "orientation_unverified")
            controlErrorCode = error.code
            controlError = String(describing: error)
            throw error
        }
    }
    private func captureOnce(
        mediaTimeout: Double, textOptions: NativeTextObservationOptions?, budget: NativeCaptureBudget?
    ) throws -> CapturedObservation {
        guard let cli else { throw IPhoneUseError("backend_unavailable", "Native backend not started") }
        let captured = try cli.capture(
            generation: generation, budget: budget,
            prepareDisplay: { display in try self.prepareCaptureDisplay(display)
            },
            validateDisplay: { display, requestedAt in
                try self.validateCaptureDisplay(display, requestedAt: requestedAt, mediaTimeout: mediaTimeout)
            })
        var metadata = captured.metadata
        if let textOptions {
            guard let rawContext = captured.metadata["screenContext"] as? [String: Any] else {
                throw ScreenGuard.Failure.invalidGuard
            }
            let context = try JSONDecoder().decode(ScreenContext.self, from: jsonData(rawContext))
            _ = try ScreenGuard(
                png: captured.screenshot, context: context,
                rects: [textOptions.field], policy: .init(), ignoring: textOptions.ignoring)
            metadata["textObservationOptions"] = try textOptions.result
        }
        if controlError == nil, media?.isActive == true, let health = media?.health() {
            metadata["mediaSessionID"] = health["mediaSessionID"]
            metadata["mediaDisplayRefreshCount"] = health["displayRefreshCount"]
        }
        return CapturedObservation(nodes: captured.nodes, metadata: metadata, screenshot: captured.screenshot)
    }
    private func resynchronizeCapture(budget: NativeCaptureBudget?) throws -> Bool {
        try self.cancellation.check()
        try budget?.check()
        guard let cli = self.cli, let media = self.media else {
            throw IPhoneUseError("native_orientation_unverified", "Owned media is unavailable")
        }
        if self.recording?.isActive == true {
            // End this recording segment before rebinding orientation.
            // Only an explicitly enabled preview may retain a new stream.
            self.recording?.endSegment(reason: "orientation_unverified")
            self.releaseRecordingMediaIfFinished(force: true)
            guard self.recordingMediaCleanup["mediaStopAcknowledged"] as? Bool == true else {
                throw IPhoneUseError("native_orientation_unverified", "Owned media stop was not confirmed")
            }
            try self.cancellation.check()
            try budget?.check()
            let first = try NativeCaptureChecks.read { try cli.read($0, budget: budget) }.display
            let second = try NativeCaptureChecks.read { try cli.read($0, budget: budget) }.display
            guard first == second else {
                throw IPhoneUseError(
                    "capture_context_changed", "Display changed while verifying orientation")
            }
            return true
        }
        return try media.resynchronizeOrientation(
            mayReplace: self.hid?.state == .ready,
            check: {
                try self.cancellation.check()
                try budget?.check()
            },
            readDisplay: {
                let first = try NativeCaptureChecks.read { try cli.read($0, budget: budget) }.display
                let second = try NativeCaptureChecks.read { try cli.read($0, budget: budget) }.display
                guard first == second else {
                    throw IPhoneUseError(
                        "capture_context_changed", "Display changed while resynchronizing orientation")
                }
                return second
            })
    }

    private func resynchronizeRecordingCapture(budget: NativeCaptureBudget?) throws -> Bool {
        guard let cli = self.cli, let media = self.media, let recording = self.recording else {
            throw IPhoneUseError("native_orientation_unverified", "Owned recording media is unavailable")
        }
        self.preview?.suspend("Refreshing static display")
        return try recording.refreshSharedSource {
            let changed = try media.resynchronizeOrientation(
                mayReplace: self.hid?.state == .ready,
                check: {
                    try self.cancellation.check()
                    try budget?.check()
                },
                readDisplay: {
                    let first = try NativeCaptureChecks.read { try cli.read($0, budget: budget) }.display
                    let second = try NativeCaptureChecks.read { try cli.read($0, budget: budget) }.display
                    guard first == second else {
                        throw IPhoneUseError(
                            "capture_context_changed", "Display changed during recording source refresh")
                    }
                    return second
                })
            guard let display = media.boundDisplay, let receiver = media.recordingReceiver,
                let snapshots = receiver.snapshots,
                let mediaID = media.health()["mediaSessionID"] as? String
            else {
                throw IPhoneUseError(
                    "native_orientation_unverified", "Replacement recording media is unavailable")
            }
            // A newly received image must certify geometry before
            // the replacement can feed the existing recording.
            let clockDeadline = ProcessInfo.processInfo.systemUptime + 3
            while receiver.recordingConfiguration()["RTPClockRate"] == nil,
                ProcessInfo.processInfo.systemUptime < clockDeadline {
                try self.cancellation.check()
                try budget?.check()
                Thread.sleep(forTimeInterval: 0.05)
            }
            let frame = try receiver.snapshot(
                after: ProcessInfo.processInfo.systemUptime,
                timeout: 1, cancellation: self.cancellation)
            _ = try NativeSnapshotImage.validateGeometry(frame, display: display)
            try budget?.check()
            return NativeStreamRecording.SharedSource(
                receiver: receiver, snapshots: snapshots,
                mediaID: mediaID, rotation: display.rotation, geometryChanged: changed)
        }
    }

    private func prepareCaptureDisplay(_ display: NativeDisplay) throws {
        try self.cancellation.check()
        if self.preview != nil, self.media == nil, self.controlError == nil {
            try self.ensurePreviewMedia(display)
        }
        // Startup failure remains observation-only. Once control is started,
        // a failed display rebind cannot silently return an unsafe image.
        if self.controlError == nil, self.media?.isActive == true {
            if self.recording?.isActive == true, self.media?.matchesDisplay(display) == false {
                self.recording?.endSegment(reason: "display_changed")
                self.releaseRecordingMediaIfFinished(force: true)
                guard self.recordingMediaCleanup["mediaStopAcknowledged"] as? Bool == true else {
                    throw IPhoneUseError(
                        "native_orientation_unverified", "Owned media stop was not confirmed")
                }
                // The pre-stop topology may be Apple's stale transform.
                // Discard this capture attempt and read the display again.
                throw IPhoneUseError(
                    "capture_context_changed",
                    "Recording ended after a display change; recapture after media cleanup")
            }
            if self.media?.isActive == true {
                try self.media?.ensureDisplay(display, mayReplace: self.hid?.state == .ready)
            }
        }
    }

    private func validateCaptureDisplay(_ display: NativeDisplay, requestedAt: Double, mediaTimeout: Double)
        throws -> [String: Any] {
        try self.cancellation.check()
        guard self.controlError == nil else {
            return ["verification": "observation_only"]
        }
        guard let media = self.media, media.isActive else {
            return ["verification": "apple_png_and_stable_display_metadata"]
        }
        try NativeCaptureChecks.requireHealthyMedia(media.health())
        guard media.matchesDisplay(display),
            let receiver = media.recordingReceiver, receiver.snapshots != nil
        else {
            throw IPhoneUseError(
                "native_orientation_unverified",
                "Owned media cannot verify display geometry; reconnect explicitly")
        }
        // Apple can cache its old transform while a media stream survives
        // rotation. Retain independent geometry verification, without using
        // any decoded pixel as an observation or input-comparison baseline.
        // VRA changes the active pixel rectangle, not the native screen
        // axes or per-frame direction. Waiting only for full-resolution
        // pixels during a transition incorrectly looks like a quiet stream.
        let frame = try receiver.snapshot(
            after: requestedAt, timeout: mediaTimeout,
            includeReducedResolution: true, cancellation: self.cancellation)
        if frame == nil { try receiver.snapshots?.rejectConflictingGeometry(display) }
        _ = try NativeSnapshotImage.validateGeometry(frame, display: display, allowReducedResolution: true)
        return [
            "verification": "owned_media_geometry", "geometryValidated": true,
            "displayRotation": display.rotation,
            "reducedResolution": frame?.image.isReducedResolution ?? false
        ]
    }
}
