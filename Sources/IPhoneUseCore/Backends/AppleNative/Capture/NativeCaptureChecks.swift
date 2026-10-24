import Foundation

// These two reads are independent. Both must finish successfully before the
// screenshot (and both run again after it); neither result is cached.
enum NativeCaptureChecks {
    static func requireHealthyMedia(_ health: [String: Any]) throws {
        let connection = health["displayConnection"] as? [String: Any]
        if connection?["errorCode"] as? String == "native_connection_lost" {
            throw IPhoneUseError(
                "native_connection_lost",
                "Native display connection ended; close competing device clients, then explicitly reconnect.",
                diagnostics: ["media": health])
        }
        guard health["healthy"] as? Bool == true else {
            throw IPhoneUseError(
                "native_media_unhealthy",
                """
                Owned media has no healthy RTP/RTCP flow; check other device clients and session status before\
                 reconnecting.
                """,
                diagnostics: ["media": health])
        }
    }
    // A quiet owned stream cannot certify Apple's cached display transform.
    // One UUID-scoped refresh is permitted; a second failure must not recurse.
    static func withOrientationRecovery(
        capture: (_ afterRefresh: Bool) throws -> CapturedObservation,
        resynchronize: () throws -> Bool,
        recordingActive: () -> Bool = { false },
        resynchronizeRecording: (() throws -> Bool)? = nil,
        diagnostics: () -> [String: Any] = { [:] },
        now: () -> Double = { ProcessInfo.processInfo.systemUptime }
    ) throws -> CapturedObservation {
        let started = now()
        do { return try capture(false) } catch let error as IPhoneUseError
            where needsOrientationRecovery(error) {
            let firstFinished = now()
            let triggerState = diagnostics()
            // Missing positive evidence is not an orientation conflict. Preserve
            // recording only through its explicit source-refresh path; callers
            // without that capability must still reject rather than use a cache.
            let recordingRecovery = error.code == "native_snapshot_freshness_unavailable" && recordingActive()
            try requireRecordingRecovery(
                recordingRecovery, available: resynchronizeRecording != nil,
                error: error, triggerState: triggerState)
            do {
                let recoveryStarted = now()
                let geometryChanged: Bool
                if recordingRecovery, let resynchronizeRecording {
                    geometryChanged = try resynchronizeRecording()
                } else {
                    geometryChanged = try resynchronize()
                }
                let recoveryFinished = now()
                let recoveredState = diagnostics()
                let retryStarted = now()
                let frame = try capture(true)
                let finished = now()
                return recoveredFrame(
                    frame, error: error, geometryChanged: geometryChanged,
                    states: (triggerState, recoveredState),
                    timing: RecoveryTiming(
                        started: started, firstFinished: firstFinished,
                        recoveryStarted: recoveryStarted, recoveryFinished: recoveryFinished,
                        retryStarted: retryStarted, finished: finished))
            } catch let failure as IPhoneUseError
                where [
                    "input_preflight_timeout", "capture_timeout", "native_cancelled", "coredevice_cancelled"
                ]
                .contains(failure.code) {
                throw failure
            } catch {
                throw IPhoneUseError(
                    "native_orientation_unverified",
                    """
                    Display could not be verified after one owned-media resynchronization; reconnect\
                     explicitly: \(error)
                    """
                )
            }
        }
    }
    private static func requireRecordingRecovery(
        _ recordingRecovery: Bool, available: Bool,
        error: IPhoneUseError, triggerState: [String: Any]
    ) throws {
        if recordingRecovery, !available {
            var details = error.diagnostics
            details["orientationRecoveryDeferred"] = true
            details["recordingPreserved"] = true
            details["triggerState"] = triggerState
            throw IPhoneUseError(
                error.code,
                """
                No fresh media frame to verify orientation; recording continues. Wait for the screen to\
                 change or stop recording before observing again.
                """,
                diagnostics: details)
        }
    }

    private struct RecoveryTiming {
        let started: Double
        let firstFinished: Double
        let recoveryStarted: Double
        let recoveryFinished: Double
        let retryStarted: Double
        let finished: Double
    }

    private static func recoveredFrame(
        _ frame: CapturedObservation, error: IPhoneUseError, geometryChanged: Bool,
        states: ([String: Any], [String: Any]), timing: RecoveryTiming
    ) -> CapturedObservation {
        let triggerState = states.0, recoveredState = states.1
        var metadata = frame.metadata
        metadata["orientationRecovery"] = [
            "reason": error.code, "trigger": recoveryTrigger(error: error.code, state: triggerState),
            "geometryChanged": geometryChanged,
            "firstAttemptMs": (timing.firstFinished - timing.started) * 1000,
            "resynchronizeMs": (timing.recoveryFinished - timing.recoveryStarted) * 1000,
            "retryMs": (timing.finished - timing.retryStarted) * 1000,
            "totalMs": (timing.finished - timing.started) * 1000,
            "triggerState": triggerState, "recoveredState": recoveredState
        ]
        // The inner capture measures only its successful retry. Account
        // for the failed attempt and owned recovery in the outer total.
        var timings = metadata["captureTimingsMs"] as? [String: Double] ?? [:]
        timings["successfulAttemptTotal"] = timings["total"] ?? (timing.finished - timing.retryStarted) * 1000
        timings["total"] = (timing.finished - timing.started) * 1000
        metadata["captureTimingsMs"] = timings
        // Quiet frames alone do not invalidate an otherwise identical
        // reference. Input still compares source, geometry, pixels and
        // deadline against its ORIGINAL observation after this capture.
        let revalidated = error.code == "native_snapshot_freshness_unavailable" && !geometryChanged
        metadata[revalidated ? "orientationRevalidated" : "orientationResynchronized"] = true
        metadata["orientationResynchronizationReason"] = error.code
        return CapturedObservation(nodes: frame.nodes, metadata: metadata, screenshot: frame.screenshot)
    }

    static func needsOrientationRecovery(_ error: IPhoneUseError) -> Bool {
        [
            "native_snapshot_geometry_unavailable", "native_snapshot_freshness_unavailable",
            "native_screenshot_geometry_conflict"
        ].contains(error.code)
    }

    // Classification is diagnostic, never positive proof of current orientation.
    // In particular, a quiet stream and a live peer heartbeat cannot replace a frame.
    static func recoveryTrigger(error: String, state: [String: Any]) -> String {
        if ["native_snapshot_geometry_unavailable", "native_screenshot_geometry_conflict"].contains(error) {
            return "geometry_conflict"
        }
        if state["healthy"] as? Bool == false || state["peerEnded"] as? Bool == true {
            return "connection_unavailable"
        }
        guard let snapshots = state["snapshots"] as? [String: Any],
            let rtpAge = state["lastRTPAgeSeconds"] as? Double, rtpAge.isFinite, rtpAge >= 0
        else {
            return "fresh_frame_unavailable"
        }
        if (snapshots["pendingBytes"] as? Int ?? 0) > 0 { return "frame_delivery_delayed" }
        if rtpAge >= 0.5, snapshots["waitingForKeyframe"] as? Bool == false,
            snapshots["pendingBytes"] as? Int == 0 {
            return "stream_quiescent"
        }
        if let frameAge = snapshots["lastFrameAgeSeconds"] as? Double, frameAge > 0.5, rtpAge < 0.5 {
            return "frame_delivery_delayed"
        }
        return "fresh_frame_unavailable"
    }

    private final class Results {
        let lock = NSLock()
        var replies: [String: Result<[String: Any], Error>] = [:]
        var timings: [String: Double] = [:]
    }
    // Preview validates video separately; screenshot/input callers keep the strict default.
    static func read(requireBacklight: Bool = true, _ operation: @escaping ([String]) throws -> [String: Any])
        throws
        -> (display: NativeDisplay, timings: [String: Double]) {
        let results = Results(), group = DispatchGroup()
        for (name, argument) in [("lock", "lockState"), ("display", "displays")] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                let start = ProcessInfo.processInfo.systemUptime
                let reply = Result { try operation(["device", "info", argument]) }
                let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
                results.lock.lock(); defer { results.lock.unlock() }
                results.replies[name] = reply; results.timings[name] = elapsed
            }
        }
        // CoreDevice.read has cancellation and a process deadline. Always join
        // both children before returning, including when either read fails.
        group.wait()
        // A timed-out sibling must not hide confirmed lock/backlight evidence.
        if case .success(let lock) = results.replies["lock"]! {
            guard lock["passcodeRequired"] as? Bool == false else {
                throw IPhoneUseError("device_locked", "Unlock the iPhone before observing")
            }
        }
        if requireBacklight, case .success(let facts) = results.replies["display"]! {
            guard try NativeDisplay(facts).backlightOn else {
                throw IPhoneUseError(
                    "capture_unavailable", "The display backlight is off; wake the iPhone before observing")
            }
        }
        let lock = try results.replies["lock"]!.get()
        guard lock["passcodeRequired"] as? Bool == false else {
            throw IPhoneUseError("device_locked", "Unlock the iPhone before observing")
        }
        let display = try NativeDisplay(results.replies["display"]!.get())
        guard !requireBacklight || display.backlightOn else {
            throw IPhoneUseError(
                "capture_unavailable", "The display backlight is off; wake the iPhone before observing")
        }
        return (display, results.timings)
    }
}
