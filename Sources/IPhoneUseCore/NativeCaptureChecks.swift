import Foundation

// These two reads are independent. Both must finish successfully before the
// screenshot (and both run again after it); neither result is cached.
enum NativeCaptureChecks {
    // A quiet owned stream cannot certify Apple's cached display transform.
    // One UUID-scoped refresh is permitted; a second failure must not recurse.
    static func withOrientationRecovery(capture: (_ afterRefresh: Bool) throws -> CapturedObservation,
                                        resynchronize: () throws -> Bool,
                                        diagnostics: () -> [String: Any] = { [:] },
                                        now: () -> Double = { ProcessInfo.processInfo.systemUptime }) throws -> CapturedObservation {
        let started = now()
        do { return try capture(false) }
        catch let error as IPhoneUseError where needsOrientationRecovery(error) {
            let firstFinished = now()
            let triggerState = diagnostics()
            do {
                let recoveryStarted = now()
                let geometryChanged = try resynchronize()
                let recoveryFinished = now()
                let recoveredState = diagnostics()
                let retryStarted = now()
                let frame = try capture(true)
                let finished = now()
                var metadata = frame.metadata
                metadata["orientationRecovery"] = [
                    "reason": error.code, "trigger": recoveryTrigger(error: error.code, state: triggerState),
                    "geometryChanged": geometryChanged,
                    "firstAttemptMs": (firstFinished - started) * 1000,
                    "resynchronizeMs": (recoveryFinished - recoveryStarted) * 1000,
                    "retryMs": (finished - retryStarted) * 1000,
                    "totalMs": (finished - started) * 1000,
                    "triggerState": triggerState, "recoveredState": recoveredState
                ]
                // The inner capture measures only its successful retry. Account
                // for the failed attempt and owned recovery in the outer total.
                var timings = metadata["captureTimingsMs"] as? [String: Double] ?? [:]
                timings["successfulAttemptTotal"] = timings["total"] ?? (finished - retryStarted) * 1000
                timings["total"] = (finished - started) * 1000
                metadata["captureTimingsMs"] = timings
                // Quiet frames alone do not invalidate an otherwise identical
                // reference. Input still compares source, geometry, pixels and
                // deadline against its ORIGINAL observation after this capture.
                let revalidated = error.code == "native_snapshot_freshness_unavailable" && !geometryChanged
                metadata[revalidated ? "orientationRevalidated" : "orientationResynchronized"] = true
                metadata["orientationResynchronizationReason"] = error.code
                return CapturedObservation(nodes: frame.nodes, metadata: metadata, screenshot: frame.screenshot)
            } catch let failure as IPhoneUseError where ["input_preflight_timeout", "capture_timeout", "native_cancelled", "coredevice_cancelled"].contains(failure.code) {
                throw failure
            } catch {
                throw IPhoneUseError("native_orientation_unverified",
                    "Display could not be verified after one owned-media resynchronization; reconnect explicitly: \(error)")
            }
        }
    }
    static func needsOrientationRecovery(_ error: IPhoneUseError) -> Bool {
        ["native_snapshot_geometry_unavailable", "native_snapshot_freshness_unavailable", "native_screenshot_geometry_conflict"].contains(error.code)
    }

    // Classification is diagnostic, never positive proof of current orientation.
    // In particular, a quiet stream and a live peer heartbeat cannot replace a frame.
    static func recoveryTrigger(error: String, state: [String: Any]) -> String {
        if ["native_snapshot_geometry_unavailable", "native_screenshot_geometry_conflict"].contains(error) { return "geometry_conflict" }
        if state["healthy"] as? Bool == false || state["peerEnded"] as? Bool == true {
            return "connection_unavailable"
        }
        guard let snapshots = state["snapshots"] as? [String: Any],
              let rtpAge = state["lastRTPAgeSeconds"] as? Double, rtpAge.isFinite, rtpAge >= 0 else {
            return "fresh_frame_unavailable"
        }
        if (snapshots["pendingBytes"] as? Int ?? 0) > 0 { return "frame_delivery_delayed" }
        if rtpAge >= 0.5, snapshots["waitingForKeyframe"] as? Bool == false,
           snapshots["pendingBytes"] as? Int == 0 { return "stream_quiescent" }
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
    static func read(_ operation: @escaping ([String]) throws -> [String: Any]) throws -> (display: NativeDisplay, timings: [String: Double]) {
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
        let lock = try results.replies["lock"]!.get()
        guard lock["passcodeRequired"] as? Bool == false else { throw IPhoneUseError("device_locked", "Unlock the iPhone before observing") }
        let display = try NativeDisplay(results.replies["display"]!.get())
        guard display.backlightOn else { throw IPhoneUseError("capture_unavailable", "The display backlight is off; wake the iPhone before observing") }
        return (display, results.timings)
    }
}
