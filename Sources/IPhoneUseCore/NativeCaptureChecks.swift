import Foundation

// These two reads are independent. Both must finish successfully before the
// screenshot (and both run again after it); neither result is cached.
enum NativeCaptureChecks {
    // A quiet owned stream cannot certify Apple's cached display transform.
    // One UUID-scoped refresh is permitted; a second failure must not recurse.
    static func withOrientationRecovery(capture: (_ afterRefresh: Bool) throws -> CapturedObservation,
                                        resynchronize: () throws -> Bool) throws -> CapturedObservation {
        do { return try capture(false) }
        catch let error as IPhoneUseError where needsOrientationRecovery(error) {
            do {
                let geometryChanged = try resynchronize()
                let frame = try capture(true)
                var metadata = frame.metadata
                // Quiet frames alone do not invalidate an otherwise identical
                // reference. Input still compares source, geometry, pixels and
                // deadline against its ORIGINAL observation after this capture.
                let revalidated = error.code == "native_snapshot_freshness_unavailable" && !geometryChanged
                metadata[revalidated ? "orientationRevalidated" : "orientationResynchronized"] = true
                metadata["orientationResynchronizationReason"] = error.code
                return CapturedObservation(nodes: frame.nodes, metadata: metadata, screenshot: frame.screenshot)
            } catch {
                throw IPhoneUseError("native_orientation_unverified",
                    "Display could not be verified after one owned-media resynchronization; reconnect explicitly: \(error)")
            }
        }
    }
    static func needsOrientationRecovery(_ error: IPhoneUseError) -> Bool {
        ["native_snapshot_geometry_unavailable", "native_snapshot_freshness_unavailable"].contains(error.code)
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
