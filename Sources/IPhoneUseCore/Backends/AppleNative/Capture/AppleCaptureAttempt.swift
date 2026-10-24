import Foundation

// Confined to the caller's capture operation; parallel CoreDevice results join
// before the next phase reads or updates this attempt's diagnostics.
final class AppleCaptureAttempt {
    let cli: AppleDeviceCLI
    let generation: String
    let budget: NativeCaptureBudget?
    let started = Date().timeIntervalSince1970
    let monotonic = ProcessInfo.processInfo.systemUptime
    var timings: [String: Double] = [:]
    let diagnostics = NativeCaptureDiagnostics()
    var phase = "checksBefore"

    init(cli: AppleDeviceCLI, generation: String, budget: NativeCaptureBudget?) {
        self.cli = cli
        self.generation = generation
        self.budget = budget
    }
    func timed<T>(_ name: String, _ operation: () throws -> T) rethrows -> T {
        phase = name
        let start = ProcessInfo.processInfo.systemUptime
        defer { timings[name, default: 0] += (ProcessInfo.processInfo.systemUptime - start) * 1000 }
        return try operation()
    }
    func read(_ arguments: [String], phase: String) throws -> [String: Any] {
        try diagnostics.read(arguments, phase: phase) { try self.cli.read(arguments, budget: budget) }
    }

    func run(
        prepareDisplay: (NativeDisplay) throws -> Void, validateDisplay: (NativeDisplay, Double) throws -> [String: Any]
    ) throws -> CapturedObservation {
        do {
            let initial = try timed("checksBefore") {
                try NativeCaptureChecks.read { try self.read($0, phase: "checksBefore") }
            }
            let before = initial.display
            for (key, value) in initial.timings { timings[key + "Before"] = value }
            try timed("prepareDisplay") { try prepareDisplay(before) }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "iphone-use-screen-\(UUID().uuidString)")
            try SessionPaths.secureDirectory(directory)
            defer { try? FileManager.default.removeItem(at: directory) }
            let destination = directory.appendingPathComponent("screen.png")
            let requestedAt = ProcessInfo.processInfo.systemUptime
            // Geometry evidence never supplies observation pixels. Apple PNG is
            // the only source, including after media recovery or screenshot failure.
            let geometry = try timed("displayGeometry") { try validateDisplay(before, requestedAt) }
            try budget?.beginValidation()
            _ = try timed("screenshot") {
                try read(["device", "capture", "screenshot", "--destination", destination.path], phase: "screenshot")
            }
            let png = try timed("readPNG") { try Data(contentsOf: destination) }
            let fingerprint = try timed("appleImageValidation") { try validate(png, display: before) }
            let final = try timed("checksAfter") {
                try NativeCaptureChecks.read { try self.read($0, phase: "checksAfter") }
            }
            let after = final.display
            for (key, value) in final.timings { timings[key + "After"] = value }
            try cli.cancellation.check()
            try budget?.check()
            phase = "displayConsistency"
            guard before == after, after.backlightOn else {
                throw IPhoneUseError("capture_context_changed", "Display changed during screenshot acquisition")
            }
            timings["total"] = (ProcessInfo.processInfo.systemUptime - monotonic) * 1000
            return try captured(png: png, fingerprint: fingerprint, display: after, geometry: geometry)

        } catch {
            timings["total"] = (ProcessInfo.processInfo.systemUptime - monotonic) * 1000
            var facts: [String: Any] = ["failedStage": phase, "timingsMs": timings, "commands": diagnostics.commands]
            if let budget {
                facts["budgetPurpose"] = budget.purpose == .input ? "input" : "observation"
                facts["deadlineUptime"] = budget.deadline
                facts["requestDeadlineUptime"] = budget.requestDeadline
                facts["validationStartedUptime"] = budget.validationStartedAt
            }
            throw IPhoneUseError(
                (error as? IPhoneUseError)?.code ?? "capture_failed", String(describing: error),
                diagnostics: ["capture": facts])
        }
    }
    func validate(_ png: Data, display before: NativeDisplay) throws -> FrameFingerprint {
        let fingerprint = try FrameFingerprint(png: png)
        guard fingerprint.width == Int(before.pixelWidth), fingerprint.height == Int(before.pixelHeight) else {
            throw IPhoneUseError(
                "native_screenshot_geometry_conflict", "Screenshot dimensions disagree with the current display")
        }
        let image = try ScreenImage(png: png)
        let samples = try image.rgb(rect: before.screen, screen: before.screen, columns: 32, rows: 64)
        guard samples.contains(where: { $0 > 8 }) else {
            throw IPhoneUseError("capture_unavailable", "Screenshot is black or unavailable")
        }
        return fingerprint
    }

    private func captured(
        png: Data, fingerprint: FrameFingerprint, display after: NativeDisplay, geometry: [String: Any]
    ) throws -> CapturedObservation {
        return CapturedObservation(
            nodes: [],
            metadata: [
                "captureSource": "coredevice_screenshot", "captureSourcePolicy": cli.captureSourcePolicy,
                "captureTimingsMs": timings, "captureCommands": diagnostics.commands, "displayGeometry": geometry,
                "backend": "apple-native", "deviceID": cli.device, "sessionGeneration": generation,
                "captureID": UUID().uuidString, "captureStartedAt": started,
                "captureCompletedAt": Date().timeIntervalSince1970, "captureStartedUptime": monotonic,
                "screenshotCapturedAt": Date().timeIntervalSince1970, "screenshotWidth": fingerprint.width,
                "screenshotHeight": fingerprint.height, "frameHash": fingerprint.hash, "displayID": after.id,
                "displayRotation": after.rotation, "nativeRotation": after.nativeRotation,
                "coordinateSpace": "screen_points", "pointScale": after.scale,
                "imageTransform": ["cropOriginPixels": [0, 0], "resizeScale": 1, "pixelsPerPoint": after.scale],
                "screenFrame": try jsonObject(JSONEncoder().encode(after.screen)),
                "screenContext": try jsonObject(JSONEncoder().encode(after.context)), "scope": "screen",
                "foregroundBundleId": NSNull(), "keyboardState": "unknown", "axStatus": "unavailable",
                "axError": "Native backend uses screenshots; AX is not collected", "sourceTruncated": false,
                "validity": "valid"
            ], screenshot: png)
    }
}
