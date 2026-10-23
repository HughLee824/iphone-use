import Foundation
import CoreGraphics
import ImageIO
import AppleNativeBridge

struct NativeDisplay: Equatable {
    let id: UInt64
    let pixelWidth: Double
    let pixelHeight: Double
    let scale: Double
    let rotation: String
    let nativeRotation: String
    let backlightOn: Bool
    var screen: ScreenRect { ScreenRect(CGRect(x: 0, y: 0, width: pixelWidth / scale, height: pixelHeight / scale)) }
    var context: ScreenContext {
        let orientation = ["rot0": 1, "rot90": 4, "rot180": 2, "rot270": 3][rotation] ?? 0
        // Native screenshots have no keyboard/AX count; this placeholder is only for grid
        // comparison. keyboardState is explicitly unknown in the observation metadata.
        return ScreenContext(screen: screen, scope: screen, orientation: orientation, keyboardCount: 0)
    }
    init(_ result: [String: Any]) throws {
        guard let displays = result["displays"] as? [[String: Any]] else { throw IPhoneUseError("native_display_unavailable", "Display list missing") }
        let primary = displays.filter { $0["primary"] as? Bool == true }
        guard primary.count == 1, let value = primary.first,
              let id = value["displayId"] as? NSNumber, id.uint64Value > 0,
              let bounds = value["bounds"] as? [[NSNumber]], bounds.count == 2, bounds.allSatisfy({ $0.count == 2 }),
              bounds[0].map(\.doubleValue) == [0, 0], bounds[1].allSatisfy({ $0.doubleValue.isFinite && $0.doubleValue > 0 && $0.doubleValue <= 16384 }),
              let scale = value["pointScale"] as? NSNumber, scale.doubleValue.isFinite, scale.doubleValue >= 1,
              let rotation = value["currentOrientation"] as? String, ["rot0", "rot90", "rot180", "rot270"].contains(rotation),
              let native = value["nativeOrientation"] as? String, ["rot0", "rot90", "rot180", "rot270"].contains(native) else { throw IPhoneUseError("native_display_unavailable", "Unknown primary display geometry") }
        // CoreDevice bounds remain in native display axes when the scene rotates;
        // devicectl's PNG is already oriented. Do not rotate or resample that PNG.
        let quarterTurn = ["rot90", "rot270"].contains(rotation) != ["rot90", "rot270"].contains(native)
        self.id = id.uint64Value
        pixelWidth = bounds[1][quarterTurn ? 1 : 0].doubleValue
        pixelHeight = bounds[1][quarterTurn ? 0 : 1].doubleValue
        self.scale = scale.doubleValue
        self.rotation = rotation; nativeRotation = native
        // XCTest can leave an unlocked, visible display dimmed. Both active
        // states are lit; inactive and unknown states still fail closed.
        backlightOn = ["activeOn", "activeDimmed"].contains(result["backlightState"] as? String ?? "")
    }
}

final class AppleDeviceCLI {
    let device: String
    let cancellation: NativeCancellation
    private let reader: (([String]) throws -> [String: Any])?
    var captureSourcePolicy: [String: Any] {
        ["strategy": "coredevice_only"]
    }
    init(device: String, cancellation: NativeCancellation, reader: (([String]) throws -> [String: Any])? = nil) {
        self.device = device; self.cancellation = cancellation; self.reader = reader
    }
    func read(_ arguments: [String], trailingArguments: [String] = [], timeout: Int = 20,
              budget: NativeCaptureBudget? = nil) throws -> [String: Any] {
        try cancellation.check()
        try budget?.check()
        do {
            let result: [String: Any]
            if let reader { result = try reader(arguments) }
            else {
                result = try CoreDevice.read(arguments + ["--device", device], cancelled: {
                    self.cancellation.isCancelled || budget.map { ProcessInfo.processInfo.systemUptime >= $0.deadline } == true
                }, trailingArguments: trailingArguments, timeout: timeout)
            }
            try cancellation.check()
            try budget?.check()
            return result
        } catch {
            do {
                try cancellation.check()
                try budget?.check()
            } catch let deadlineError as IPhoneUseError {
                throw IPhoneUseError(deadlineError.code, deadlineError.description,
                                     diagnostics: (error as? IPhoneUseError)?.diagnostics ?? [:])
            }
            throw error
        }
    }
    func display() throws -> NativeDisplay { try NativeDisplay(read(["device", "info", "displays"])) }
    func capture(generation: String, budget: NativeCaptureBudget? = nil,
                 prepareDisplay: (NativeDisplay) throws -> Void = { _ in },
                 validateDisplay: (NativeDisplay, Double) throws -> [String: Any] = { _, _ in [:] }) throws -> CapturedObservation {
        let started = Date().timeIntervalSince1970
        let monotonic = ProcessInfo.processInfo.systemUptime
        var timings: [String: Double] = [:]
        let diagnostics = NativeCaptureDiagnostics()
        var phase = "checksBefore"
        func timed<T>(_ name: String, _ operation: () throws -> T) rethrows -> T {
            phase = name
            let start = ProcessInfo.processInfo.systemUptime
            defer { timings[name, default: 0] += (ProcessInfo.processInfo.systemUptime - start) * 1000 }
            return try operation()
        }
        func read(_ arguments: [String], phase: String) throws -> [String: Any] {
            try diagnostics.read(arguments, phase: phase) { try self.read(arguments, budget: budget) }
        }
        do {
            let initial = try timed("checksBefore") { try NativeCaptureChecks.read { try read($0, phase: "checksBefore") } }
            let before = initial.display
            for (key, value) in initial.timings { timings[key + "Before"] = value }
            try timed("prepareDisplay") { try prepareDisplay(before) }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("iphone-use-screen-\(UUID().uuidString)")
            try SessionPaths.secureDirectory(directory)
            defer { try? FileManager.default.removeItem(at: directory) }
            let destination = directory.appendingPathComponent("screen.png")
            let requestedAt = ProcessInfo.processInfo.systemUptime
            // Geometry evidence never supplies observation pixels. Apple PNG is
            // the only source, including after media recovery or screenshot failure.
            let geometry = try timed("displayGeometry") { try validateDisplay(before, requestedAt) }
            func validate(_ png: Data) throws -> FrameFingerprint {
                let fingerprint = try FrameFingerprint(png: png)
                guard fingerprint.width == Int(before.pixelWidth), fingerprint.height == Int(before.pixelHeight) else {
                    throw IPhoneUseError("native_screenshot_geometry_conflict", "Screenshot dimensions disagree with the current display")
                }
                let image = try ScreenImage(png: png)
                let samples = try image.rgb(rect: before.screen, screen: before.screen, columns: 32, rows: 64)
                guard samples.contains(where: { $0 > 8 }) else { throw IPhoneUseError("capture_unavailable", "Screenshot is black or unavailable") }
                return fingerprint
            }
            try budget?.beginValidation()
            _ = try timed("screenshot") { try read(["device", "capture", "screenshot", "--destination", destination.path], phase: "screenshot") }
            let png = try timed("readPNG") { try Data(contentsOf: destination) }
            let fingerprint = try timed("appleImageValidation") { try validate(png) }
            let final = try timed("checksAfter") { try NativeCaptureChecks.read { try read($0, phase: "checksAfter") } }
            let after = final.display
            for (key, value) in final.timings { timings[key + "After"] = value }
            try cancellation.check()
            try budget?.check()
            phase = "displayConsistency"
            guard before == after, after.backlightOn else { throw IPhoneUseError("capture_context_changed", "Display changed during screenshot acquisition") }
            timings["total"] = (ProcessInfo.processInfo.systemUptime - monotonic) * 1000
            return CapturedObservation(nodes: [], metadata: [
                "captureSource": "coredevice_screenshot",
                "captureSourcePolicy": captureSourcePolicy,
                "captureTimingsMs": timings, "captureCommands": diagnostics.commands, "displayGeometry": geometry,
                "backend": "apple-native", "deviceID": device, "sessionGeneration": generation,
                "captureID": UUID().uuidString, "captureStartedAt": started, "captureCompletedAt": Date().timeIntervalSince1970,
                "captureStartedUptime": monotonic, "screenshotCapturedAt": Date().timeIntervalSince1970,
                "screenshotWidth": fingerprint.width, "screenshotHeight": fingerprint.height, "frameHash": fingerprint.hash,
                "displayID": after.id, "displayRotation": after.rotation, "nativeRotation": after.nativeRotation,
                "coordinateSpace": "screen_points", "pointScale": after.scale,
                "imageTransform": ["cropOriginPixels": [0, 0], "resizeScale": 1, "pixelsPerPoint": after.scale],
                "screenFrame": try jsonObject(JSONEncoder().encode(after.screen)),
                "screenContext": try jsonObject(JSONEncoder().encode(after.context)),
                "scope": "screen", "foregroundBundleId": NSNull(), "keyboardState": "unknown",
                "axStatus": "unavailable", "axError": "Native backend uses screenshots; AX is not collected",
                "sourceTruncated": false, "validity": "valid"
            ], screenshot: png)
        } catch {
            timings["total"] = (ProcessInfo.processInfo.systemUptime - monotonic) * 1000
            var facts: [String: Any] = ["failedStage": phase, "timingsMs": timings, "commands": diagnostics.commands]
            if let budget {
                facts["budgetPurpose"] = budget.purpose == .input ? "input" : "observation"
                facts["deadlineUptime"] = budget.deadline
                facts["requestDeadlineUptime"] = budget.requestDeadline
                facts["validationStartedUptime"] = budget.validationStartedAt
            }
            throw IPhoneUseError((error as? IPhoneUseError)?.code ?? "capture_failed", String(describing: error),
                                 diagnostics: ["capture": facts])
        }
    }
}

final class AppleDeviceBackend: SessionBackend {
    private let config: HostConfiguration
    private let paths: SessionPaths
    private let cancellation = NativeCancellation()
    private let generation = UUID().uuidString
    private var cli: AppleDeviceCLI?
    private var deviceLock: SessionDeviceLock?
    private var pasteboardTransport: NativeTransport?
    private var pasteboard: NativeTextPasteboard?
    private var pasteboardError: String?
    private var buttonTransport: NativeTransport?
    private var buttonError: String?
    private var hidTransport: NativeTransport?
    private var mediaTransport: NativeTransport?
    private var mediaClient: NativeFeatureClient?
    private var connectedDeviceIdentifier: String?
    private var connectedDeviceAddress: String?
    private var hid: NativeHIDAdapter?
    private var media: NativeDisplayMediaSession?
    private var tunnel: ASPairedTunnel?
    private var controlError: String?
    private var controlErrorCode: String?
    private var cleanupFacts: [String: Any] = [:]
    private var recordingMediaCleanup: [String: Any] = [:]
    private var recordingCleanupByID: [String: [String: Any]] = [:]
    private var currentRecordingID: String?
    private var eventDeliveryQueue: DispatchQueue?
    private var stopped = false
    private var recording: NativeStreamRecording?
    private let previewOrientation = NativePreviewOrientation()
    private let previewContinuity = NativePreviewContinuity()
    private var preview: NativePreview?
    private var previewDevice = NativePreviewDevice.unknown
    private var previewFailure: String?
    private var recordingSupported = false

    private let makeHID: (NativeTransport, NativeCancellation) -> NativeHIDAdapter

    init(config: HostConfiguration, paths: SessionPaths,
         makeHID: @escaping (NativeTransport, NativeCancellation) -> NativeHIDAdapter = {
             NativeHIDAdapter(transport: $0, cancellation: $1)
         }) {
        self.config = config; self.paths = paths; self.makeHID = makeHID
    }
    func setEventDeliveryQueue(_ queue: DispatchQueue) { eventDeliveryQueue = queue }
    func start() throws -> [String: Any] {
        let details = try CoreDevice.read(["device", "info", "details", "--device", config.device])
        recordingSupported = NativeRecordingOptions.supported(by: details)
        previewDevice = NativePreviewDevice(details: details)
        guard let hardware = details["hardwareProperties"] as? [String: Any], hardware["reality"] as? String == "physical",
              let udid = hardware["udid"] as? String,
              let properties = details["deviceProperties"] as? [String: Any], properties["developerModeStatus"] as? String == "enabled",
              let connection = details["connectionProperties"] as? [String: Any], connection["pairingState"] as? String == "paired",
              let address = connection["tunnelIPAddress"] as? String,
              let identifier = details["identifier"] as? String else {
            throw CoreDevice.nativeDeviceUnavailable(details)
        }
        deviceLock = try SessionDeviceLock(root: paths.directory.deletingLastPathComponent(), device: udid)
        cli = AppleDeviceCLI(device: udid, cancellation: cancellation)
        let deliveryQueue = eventDeliveryQueue
        recording = NativeStreamRecording(root: paths.directory.appendingPathComponent("recordings"), onFinish: { [weak self] recordingID, mediaID in
            deliveryQueue?.async { [weak self] in
                guard let self, !self.stopped,
                      self.currentRecordingID == recordingID,
                      self.media?.health()["mediaSessionID"] as? String == mediaID else { return }
                self.releaseRecordingMediaIfFinished()
            }
        })
        do {
            guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27,
                  (properties["osVersionNumber"] as? String)?.hasPrefix("27.") == true else {
                throw IPhoneUseError("native_protocol_unsupported", "The experimental control adapter targets macOS 27 and iOS 27 only")
            }
            let inventory = try NativeEndpointInventory.read(path: config.nativeEndpointInventory)
            let paired = try ASPairedTunnel(udid: udid, deviceIdentifier: identifier, endpointInventory: inventory)
            tunnel = paired
            connectedDeviceIdentifier = identifier
            connectedDeviceAddress = address
            try cancellation.check()
            guard paired.deviceAddress == address else { throw IPhoneUseError("native_device_mismatch", "Paired tunnel changed since device discovery; connect again explicitly") }
            let displayTransport = try AppleServiceTransport(tunnel: paired, service: "com.apple.coredevice.displayservice")
            mediaTransport = displayTransport
            mediaClient = NativeFeatureClient(transport: displayTransport, deviceIdentifier: identifier,
                                              version: try NativeMediaFactory.coreDeviceVersion())
            let inputTransport = try AppleServiceTransport(tunnel: paired, service: "com.apple.coredevice.hid.universalhidservice")
            hidTransport = inputTransport
            let input = makeHID(inputTransport, cancellation)
            try input.prepare(); hid = input
        } catch {
            controlError = (error as NSError).userInfo[NSLocalizedDescriptionKey] as? String ?? String(describing: error)
            controlErrorCode = (error as? IPhoneUseError)?.code ?? (error as NSError).userInfo["somaCode"] as? String ?? "native_control_unavailable"
            cleanupFacts = media?.close() ?? ["mediaStopAcknowledged": true]
            mediaTransport?.cancel(); hidTransport?.cancel(); hid = nil
            cleanupFacts["tunnelReleaseAcknowledged"] = tunnel?.close() ?? ((error as NSError).userInfo["tunnelReleaseAcknowledged"] as? Bool ?? true)
            tunnel = nil
            // Explicit observation-only readiness, no Runner fallback or silent input support claim.
            try saveJSON(["controlAvailable": false, "error": controlError!, "errorCode": controlErrorCode!,
                          "cleanup": cleanupFacts],
                         to: paths.directory.appendingPathComponent("native-control.json"))
        }
        return try status()
    }
    func status() throws -> [String: Any] {
        guard !stopped else { throw IPhoneUseError("backend_unavailable", "Native session closed") }
        releaseRecordingMediaIfFinished()
        let health = mediaStatus
        let streamRecordingSupported = media?.recordingReceiver.map { NativeStreamRecording.supports($0.recordingConfiguration()) } ?? false
        let hidState = hid?.state
        let closing = cancellation.isCancelled
        let control = NativeControlStatus.resolve(hid: hidState, media: health, closing: closing,
                                                   startupCode: controlErrorCode, startupError: controlError,
                                                   requiresMedia: media?.isActive == true)
        var result: [String: Any] = ["backend": "apple-native", "sessionGeneration": generation, "deviceID": cli?.device ?? config.device,
                "captureSourcePolicy": cli?.captureSourcePolicy ?? [:],
                "recording": recording?.status() ?? ["state": "idle"],
                "preview": preview?.status() ?? ["state": previewFailure == nil ? "stopped" : "failed", "error": previewFailure as Any? ?? NSNull()],
                "recordingSupport": ["supported": control.available, "formatVerified": streamRecordingSupported, "source": "owned_native_rtp",
                    "appleCLIAvailable": recordingSupported, "codec": "hevc", "method": "native_rtp"],
                "capabilities": ["terminate": !closing, "relaunch": !closing, "recording": control.available, "screenshot": true, "tap": control.available, "ax": false, "swipe": control.available,
                    "pinch": control.available, "doubleTap": control.available, "longPress": control.available, "home": control.available && buttonError == nil,
                    "text": control.available && hid?.canType == true, "press": control.available && hid?.canType == true],
                "systemButtons": ["servicePrepared": buttonTransport != nil, "error": buttonError as Any? ?? NSNull()],
                "keyboard": hid?.keyboardStatus ?? [:],
                "textInputMethods": ["asciiHID": control.available && hid?.canType == true,
                    "unicodePasteboard": control.available && hid?.canType == true && pasteboardError == nil && (pasteboard?.available ?? true)],
                "textMethodSelection": ["auto", "keys", "paste"], "textModes": ["insert", "replace", "append"], "textFinishSupported": true,
                "textPrepareSupported": true, "textCaretConfirmationSupported": true, "pressKeys": NativePressKey.allCases.map(\.rawValue),
                "pasteboard": pasteboard?.status ?? ["restorePending": false],
                "sessionClosing": closing, "hidState": hidState?.rawValue ?? "unprepared",
                "media": health, "runnerStarted": false, "serviceTransport": config.nativeEndpointInventory == nil ? "apple-coredevice-service-socket" : "apple-paired-tunnel",
                "mediaOwnershipPolicy": "read_only_inventory_before_input_dispatch", "recordingMediaCleanup": recordingMediaCleanup,
                "endpointDiscovery": config.nativeEndpointInventory == nil ? "apple-coredevice-service-socket" : "supplied-apple-netstat-inventory",
                "validation": "experimental; inspect the after-observation to verify each input"]
        result.merge(control.result) { _, new in new }
        return result
    }
    private var mediaStatus: [String: Any] {
        guard let media, media.isActive else { return ["state": "inactive", "healthy": false] }
        return media.health()
    }
    private func controlStatus(mediaHealth: [String: Any]) -> NativeControlStatus {
        NativeControlStatus.resolve(hid: hid?.state, media: mediaHealth, closing: cancellation.isCancelled,
                                    startupCode: controlErrorCode, startupError: controlError,
                                    requiresMedia: media?.isActive == true)
    }
    private func makeMediaSession() throws -> NativeDisplayMediaSession {
        guard let mediaTransport, let identifier = connectedDeviceIdentifier,
              let address = connectedDeviceAddress, let tunnel else {
            throw IPhoneUseError("native_recording_unavailable", "Native display transport is unavailable")
        }
        guard tunnel.deviceAddress == address else { throw IPhoneUseError("native_device_mismatch", "Paired tunnel changed before recording") }
        return try NativeMediaFactory.make(transport: mediaTransport, identifier: identifier, address: address,
                                           cancellation: cancellation, captureSnapshots: true)
    }
    private func assertNoForeignMediaSessions(budget: NativeCaptureBudget? = nil) throws {
        try checkMediaInventory(expectedOwnedID: nil, budget: budget)
    }
    private func checkMediaInventory(expectedOwnedID: String?, budget: NativeCaptureBudget? = nil) throws {
        guard let mediaClient else { throw IPhoneUseError("native_media_ownership_unknown", "CoreDevice media inventory is unavailable") }
        try budget?.check()
        let timeout = budget.map { min(10, $0.deadline - ProcessInfo.processInfo.systemUptime) } ?? 10
        guard timeout > 0 else { throw IPhoneUseError("input_preflight_timeout", "No input budget remains for media ownership validation") }
        let result = try mediaClient.invoke("getmediastreamserverstatus", action: "mediastreamstatus", timeout: timeout)
        try budget?.check()
        guard let sessions = result["sessions"] as? [[String: Any]] else {
            throw IPhoneUseError("native_media_ownership_unknown", "CoreDevice media ownership inventory is unavailable")
        }
        guard let expectedOwnedID else {
            guard sessions.isEmpty else {
                throw IPhoneUseError("native_media_busy", "Another client's media session exists. End that control or recording session before input; iPhone-use will not stop another client's media session.")
            }
            return
        }
        guard sessions.count == 1,
              let connection = sessions[0]["connection"] as? [String: Any],
              let options = connection["options"] as? [String: Any],
              let identity = options["avcMediaStreamOptionClientSessionID"] as? [String: Any],
              let uuid = identity["uuid"] as? UUID, uuid.uuidString == expectedOwnedID else {
            throw IPhoneUseError("native_media_busy", "Another client's media session exists. End that control or recording session before input; iPhone-use will not stop another client's media session.")
        }
    }
    private func checkInputAvailability(budget: NativeCaptureBudget? = nil) throws {
        try cancellation.check()
        if media?.isActive == true {
            guard media?.health()["healthy"] as? Bool == true else {
                throw IPhoneUseError("native_media_unhealthy", "Owned recording media stopped before input")
            }
            guard let mediaID = media?.health()["mediaSessionID"] as? String else {
                throw IPhoneUseError("native_media_ownership_unknown", "Owned media session ID is unavailable")
            }
            try checkMediaInventory(expectedOwnedID: mediaID, budget: budget)
        } else {
            try assertNoForeignMediaSessions(budget: budget)
        }
    }
    private func checkInputCanContinue() throws {
        try cancellation.check()
        if media?.isActive == true, media?.health()["healthy"] as? Bool != true {
            throw IPhoneUseError("native_media_unhealthy", "Owned recording media stopped during input")
        }
    }
    private func releaseRecordingMediaIfFinished(force: Bool = false) {
        guard recording?.isActive != true, (preview == nil || force), media?.isActive == true else { return }
        preview?.suspend("Synchronizing display")
        recordingMediaCleanup = media?.close() ?? ["mediaStopAcknowledged": true]
        if let currentRecordingID { recordingCleanupByID[currentRecordingID] = recordingMediaCleanup }
        media = nil
        if recordingMediaCleanup["mediaStopAcknowledged"] as? Bool != true {
            controlErrorCode = "native_media_cleanup_unconfirmed"
            controlError = "Owned recording media stop was not confirmed; close this session and inspect cleanup before reconnecting"
        }
    }
    func apps() throws -> AppCatalog {
        guard let cli else { throw IPhoneUseError("backend_unavailable", "Native backend not started") }
        return try AppCatalog(cli.read(["device", "info", "apps", "--include-all-apps"]))
    }
    func open(bundle: String) throws -> [String: Any] {
        try apps().requireInstalled(bundle)
        guard let cli else { throw IPhoneUseError("backend_unavailable", "Native backend not started") }
        do {
            let result = try cli.read(["device", "process", "launch", "--activate"], trailingArguments: [bundle])
            return ["bundleId": bundle, "transportStatus": "acknowledged", "verificationStatus": "not_checked",
                    "foregroundConfirmed": false, "launch": result]
        } catch {
            throw ActionFailure(code: "native_launch_uncertain", description: "Launch result is uncertain: \(error)",
                                possiblyExecuted: true, requiresObservation: true)
        }
    }
    func appLifecycle(bundle: String, relaunch: Bool) throws -> [String: Any] {
        guard let cli else { throw IPhoneUseError("backend_unavailable", "Native backend not started") }
        guard pasteboard?.status["restorePending"] as? Bool != true else {
            throw IPhoneUseError("native_pasteboard_pending", "Inspect the paste result and text-finish before closing or relaunching its app")
        }
        return try NativeAppLifecycle(read: { arguments, tail, timeout in
            try cli.read(arguments, trailingArguments: tail, timeout: max(1, Int(ceil(timeout))))
        }, checkCancellation: { try self.cancellation.check() }).run(bundle: bundle, relaunch: relaunch)
    }
    func observe() throws -> CapturedObservation {
        try capture(budget: NativeCaptureBudget(requestDeadline: ProcessInfo.processInfo.systemUptime + 30, purpose: .observation))
    }
    func observeText(_ options: NativeTextObservationOptions) throws -> CapturedObservation {
        try capture(textOptions: options, budget: NativeCaptureBudget(requestDeadline: ProcessInfo.processInfo.systemUptime + 30, purpose: .observation))
    }
    func observeAfterAction(textOptions: NativeTextObservationOptions?, ignoring: ScreenRect?, sourceContext: ScreenContext?) throws -> CapturedObservation {
        try NativePostActionStability.capture(ignoring: ignoring, sourceContext: sourceContext,
            checkCancellation: { try self.cancellation.check() }) { deadline in
                // All samples and owned recovery share one bounded post-action
                // deadline. No sampling can extend the original input lease.
                try self.capture(textOptions: textOptions, budget: NativeCaptureBudget(requestDeadline: deadline, purpose: .observation))
            }
    }
    private func capture(textOptions: NativeTextObservationOptions? = nil, budget: NativeCaptureBudget? = nil) throws -> CapturedObservation {
        releaseRecordingMediaIfFinished()
        defer { attachPreview() }
        guard recordingMediaCleanup["mediaStopAcknowledged"] as? Bool != false else {
            throw IPhoneUseError("native_media_cleanup_unconfirmed", "Owned media may still be active; screenshot orientation cannot be verified")
        }
        guard controlErrorCode != "native_orientation_unverified" else {
            throw IPhoneUseError("native_orientation_unverified", controlError!)
        }
        do {
            let observation = try NativeCaptureChecks.withOrientationRecovery(capture: { afterRefresh in
                try budget?.check()
                return try self.captureOnce(mediaTimeout: afterRefresh ? 1 : 0.15, textOptions: textOptions, budget: budget)
            }, resynchronize: {
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
                    guard first == second else { throw IPhoneUseError("capture_context_changed", "Display changed while verifying orientation") }
                    return true
                }
                return try media.resynchronizeOrientation(mayReplace: self.hid?.state == .ready, check: {
                    try self.cancellation.check()
                    try budget?.check()
                }) {
                    let first = try NativeCaptureChecks.read { try cli.read($0, budget: budget) }.display
                    let second = try NativeCaptureChecks.read { try cli.read($0, budget: budget) }.display
                    guard first == second else { throw IPhoneUseError("capture_context_changed", "Display changed while resynchronizing orientation") }
                    return second
                }
                }, recordingActive: { self.recording?.isActive == true }, resynchronizeRecording: {
                    guard let cli = self.cli, let media = self.media, let recording = self.recording else {
                        throw IPhoneUseError("native_orientation_unverified", "Owned recording media is unavailable")
                    }
                    self.preview?.suspend("Refreshing static display")
                    return try recording.refreshSharedSource {
                        let changed = try media.resynchronizeOrientation(mayReplace: self.hid?.state == .ready, check: {
                            try self.cancellation.check()
                            try budget?.check()
                        }) {
                            let first = try NativeCaptureChecks.read { try cli.read($0, budget: budget) }.display
                            let second = try NativeCaptureChecks.read { try cli.read($0, budget: budget) }.display
                            guard first == second else { throw IPhoneUseError("capture_context_changed", "Display changed during recording source refresh") }
                            return second
                        }
                        guard let display = media.boundDisplay, let receiver = media.recordingReceiver,
                              let snapshots = receiver.snapshots,
                              let mediaID = media.health()["mediaSessionID"] as? String else {
                            throw IPhoneUseError("native_orientation_unverified", "Replacement recording media is unavailable")
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
                        let frame = try receiver.snapshot(after: ProcessInfo.processInfo.systemUptime,
                            timeout: 1, cancellation: self.cancellation)
                        _ = try NativeSnapshotImage.validateGeometry(frame, display: display)
                        try budget?.check()
                        return NativeStreamRecording.SharedSource(receiver: receiver, snapshots: snapshots,
                            mediaID: mediaID, rotation: display.rotation, geometryChanged: changed)
                    }
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
    private func captureOnce(mediaTimeout: Double, textOptions: NativeTextObservationOptions?, budget: NativeCaptureBudget?) throws -> CapturedObservation {
        guard let cli else { throw IPhoneUseError("backend_unavailable", "Native backend not started") }
        let captured = try cli.capture(generation: generation, budget: budget, prepareDisplay: { display in
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
                        throw IPhoneUseError("native_orientation_unverified", "Owned media stop was not confirmed")
                    }
                    // The pre-stop topology may be Apple's stale transform.
                    // Discard this capture attempt and read the display again.
                    throw IPhoneUseError("capture_context_changed", "Recording ended after a display change; recapture after media cleanup")
                }
                if self.media?.isActive == true {
                    try self.media?.ensureDisplay(display, mayReplace: self.hid?.state == .ready)
                }
            }
        }, validateDisplay: { display, requestedAt in
            try self.cancellation.check()
            guard self.controlError == nil else {
                return ["verification": "observation_only"]
            }
            guard let media = self.media, media.isActive else {
                return ["verification": "apple_png_and_stable_display_metadata"]
            }
            try NativeCaptureChecks.requireHealthyMedia(media.health())
            guard media.matchesDisplay(display),
                  let receiver = media.recordingReceiver, receiver.snapshots != nil else {
                throw IPhoneUseError("native_orientation_unverified", "Owned media cannot verify display geometry; reconnect explicitly")
            }
            // Apple can cache its old transform while a media stream survives
            // rotation. Retain independent geometry verification, without using
            // any decoded pixel as an observation or input-comparison baseline.
            // VRA changes the active pixel rectangle, not the native screen
            // axes or per-frame direction. Waiting only for full-resolution
            // pixels during a transition incorrectly looks like a quiet stream.
            let frame = try receiver.snapshot(after: requestedAt, timeout: mediaTimeout,
                includeReducedResolution: true, cancellation: self.cancellation)
            if frame == nil { try receiver.snapshots?.rejectConflictingGeometry(display) }
            _ = try NativeSnapshotImage.validateGeometry(frame, display: display, allowReducedResolution: true)
            return ["verification": "owned_media_geometry", "geometryValidated": true,
                    "displayRotation": display.rotation, "reducedResolution": frame?.image.isReducedResolution ?? false]
        })
        var metadata = captured.metadata
        if let textOptions {
            guard let rawContext = captured.metadata["screenContext"] as? [String: Any] else { throw ScreenGuard.Failure.invalidGuard }
            let context = try JSONDecoder().decode(ScreenContext.self, from: jsonData(rawContext))
            _ = try ScreenGuard(png: captured.screenshot, context: context,
                                rects: [textOptions.field], policy: .init(), ignoring: textOptions.ignoring)
            metadata["textObservationOptions"] = try textOptions.result
        }
        if controlError == nil, media?.isActive == true, let health = media?.health() {
            metadata["mediaSessionID"] = health["mediaSessionID"]
            metadata["mediaDisplayRefreshCount"] = health["displayRefreshCount"]
        }
        return CapturedObservation(nodes: captured.nodes, metadata: metadata, screenshot: captured.screenshot)
    }
    func perform(_ action: DeviceAction, target: ObservedTarget, onInputStarted: @escaping () -> Void) throws -> [String: Any] {
        releaseRecordingMediaIfFinished()
        let typing = action.kind == "type" && action.reference.node == nil
        let pressing = action.kind == "press" && action.reference.node == nil
        let keyboardAction = typing || pressing
        let homeAction = action.kind == "home"
        guard keyboardAction || homeAction || (["tap", "double-tap", "long-press", "pinch", "swipe"].contains(action.kind) && action.coordinate) else {
            throw IPhoneUseError("native_action_unsupported", "Use coordinate tap/double-tap/long-press/pinch/swipe, home oN, or type/press oN after visually confirming focus")
        }
        let textInput = typing ? try NativeTextInput(text: action.fields["text"] as! String, mode: action.fields["mode"] as! String, method: action.fields["textMethod"] as? String ?? "auto") : nil
        defer { if textInput?.usesPasteboard == true { pasteboard?.endInputAttempt() } }
        let control = controlStatus(mediaHealth: mediaStatus)
        guard control.available, let hid else {
            throw ActionFailure(code: "native_control_unavailable", description: control.message ?? "Native control is unavailable",
                                possiblyExecuted: false, requiresObservation: false, result: control.result)
        }
        guard target.context["deviceID"] as? String == cli?.device,
              target.context["sessionGeneration"] as? String == generation,
              let captured = target.context["captureStartedUptime"] as? Double,
              let screenGuard = (keyboardAction || homeAction) ? target.textGuard : target.gesture?.screenGuard else {
            throw ActionFailure(code: "stale_observation", description: "Observe this device/session again before input", possiblyExecuted: false, requiresObservation: true)
        }
        var timing = try NativeInputTiming(captured: captured, now: ProcessInfo.processInfo.systemUptime,
                                           policy: keyboardAction ? .keyboard : (homeAction ? .system : .coordinateGesture))
        guard let rotation = target.context["displayRotation"] as? String,
              ["rot0", "rot90", "rot270"].contains(rotation), target.context["nativeRotation"] as? String == "rot0" else {
            throw IPhoneUseError("native_orientation_unsupported", "Native HID requires portrait or landscape on a native-portrait display")
        }
        if let gesture = target.gesture { try gesture.validate(kind: action.kind) }
        let swipe = action.kind == "swipe" ? try NativeSwipePlan(gesture: target.gesture!, rotation: rotation) : nil
        let pinch = action.kind == "pinch" ? try NativePinchPlan(gesture: target.gesture!, rotation: rotation) : nil
        if keyboardAction {
            try screenGuard.validate()
            guard screenGuard.regions.map(\.rect) == [action.textRegion ?? screenGuard.context.screen] else { throw ScreenGuard.Failure.invalidGuard }
            // Discover the built-in keyboard, then capture/guard before any key.
            try hid.prepareKeyboard()
        }
        if homeAction {
            try screenGuard.validate()
            guard screenGuard.regions.map(\.rect) == [screenGuard.context.screen] else { throw ScreenGuard.Failure.invalidGuard }
            if let buttonError { throw IPhoneUseError("native_home_unavailable", buttonError) }
            if buttonTransport == nil {
                guard let tunnel else { throw IPhoneUseError("native_hid_unavailable", "Native tunnel unavailable") }
                do { buttonTransport = try AppleServiceTransport(tunnel: tunnel, service: "com.apple.coredevice.hid.indigo") }
                catch {
                    buttonError = String(describing: error)
                    throw error // Preserve the denial; never retry service creation in this session.
                }
            }
        }
        var check: ScreenGuard.Check
        var captures = 0
        var preInputChecks: [[String: Any]] = []
        var inputBudget: NativeCaptureBudget?
        func preflight(stage: String) throws -> ScreenGuard.Check {
            let budget = try timing.captureBudget(now: ProcessInfo.processInfo.systemUptime)
            inputBudget = budget
            let deadline = budget.requestDeadline
            let (value, count) = try NativeInputPreflight.check(guard: screenGuard,
                displayID: target.context["displayID"] as? UInt64, displayRotation: rotation,
                captureSource: target.context["captureSource"] as? String,
                deadline: deadline,
                maximumCaptures: 1, fieldGuard: keyboardAction ? target.textFieldGuard : nil,
                caretGuard: keyboardAction ? target.textCaretGuard : nil, budget: budget,
                record: { sample in
                    var sample = sample; sample["stage"] = stage
                    preInputChecks.append(sample)
                }) {
                    try checkInputAvailability(budget: budget)
                    return try self.capture(budget: budget)
                }
            captures += count
            return value
        }
        do {
            check = try preflight(stage: textInput?.usesPasteboard == true ? "before_clipboard" : "before_input")
            if case .pasteboard(let text) = textInput {
                do {
                    if let pasteboardError { throw IPhoneUseError("native_pasteboard_unavailable", pasteboardError) }
                    if pasteboard == nil {
                        guard let tunnel else { throw IPhoneUseError("native_pasteboard_unavailable", "Native tunnel is unavailable") }
                        let transport = try AppleServiceTransport(tunnel: tunnel, service: "com.apple.coredevice.pasteboardservice")
                        pasteboardTransport = transport
                        pasteboard = NativeTextPasteboard(io: AppleTextPasteboardIO(transport: transport, cancellation: cancellation))
                    }
                    if pasteboard?.restored == true, let transport = pasteboardTransport {
                        pasteboard = NativeTextPasteboard(io: AppleTextPasteboardIO(transport: transport, cancellation: cancellation))
                    }
                    try cancellation.check()
                    try pasteboard!.stage(text, sourceObservationID: action.reference.observation)
                } catch {
                    pasteboardError = String(describing: error)
                    throw ActionFailure(code: "native_pasteboard_unavailable", description: "Clipboard preparation failed; no paste shortcut was sent: \(error)",
                        possiblyExecuted: false, requiresObservation: true,
                        result: ["pasteboard": pasteboard?.status ?? [:], "recovery": NativeRecovery.resolveError.result])
                }
                // A clipboard operation can trigger UI. Recheck against the same
                // source observation after staging; never replace the guard baseline.
                check = try preflight(stage: "after_clipboard")
                try pasteboard!.checkOwnership()
            }
            try cancellation.check()
            try checkInputAvailability(budget: inputBudget)
            try timing.checkBeforeDispatch(now: ProcessInfo.processInfo.systemUptime)
        } catch let failure as ActionFailure {
            var result = failure.result ?? [:]
            result["inputTiming"] = timing.result
            result["preInputChecks"] = preInputChecks
            result["preInputCaptures"] = captures + (result["preInputCaptures"] as? Int ?? 0)
            if let pasteboard { result["pasteboard"] = pasteboard.status }
            throw ActionFailure(code: failure.code, description: failure.description, possiblyExecuted: failure.possiblyExecuted,
                requiresObservation: failure.requiresObservation, result: result, rejectedCapture: failure.rejectedCapture)
        } catch {
            if let failure = error as? IPhoneUseError,
               ["native_media_busy", "native_media_ownership_unknown", "native_media_unhealthy"].contains(failure.code) {
                throw ActionFailure(code: failure.code, description: failure.description,
                                    possiblyExecuted: false, requiresObservation: false,
                                    result: ["controlAvailable": false, "controlErrorCode": failure.code,
                                             "controlError": failure.description, "recovery": NativeRecovery.resolveError.result])
            }
            let code = (error as? IPhoneUseError)?.code == "input_preflight_timeout" ? "input_preflight_timeout" : "stale_observation"
            throw ActionFailure(code: code, description: "Pre-input capture/guard/clipboard check failed: \(error)",
                possiblyExecuted: false, requiresObservation: true, result: ["pasteboard": pasteboard?.status ?? [:], "preInputChecks": preInputChecks, "inputTiming": timing.result])
        }
        var result: [String: Any]
        if let textInput {
            func health() throws { try checkInputCanContinue() }
            do {
                switch textInput {
                case .keyboard(let keys): result = try hid.type(keys, mode: action.fields["mode"] as! String, checkHealth: health)
                case .pasteboard: result = try hid.paste(mode: action.fields["mode"] as! String, checkHealth: health)
                case .clear: result = try hid.clearText(checkHealth: health)
                }
                result["textInputMethod"] = textInput.usesPasteboard ? "apple-pasteboard-hid-paste" : "ascii-hid"
                if case .clear = textInput { result["textInputMethod"] = "hid-select-all-delete" }
                if textInput.usesPasteboard { result["pasteboard"] = pasteboard!.status }
            } catch let failure as ActionFailure {
                var facts = failure.result ?? [:]
                if textInput.usesPasteboard { facts["pasteboard"] = pasteboard!.status }
                throw ActionFailure(code: failure.code, description: failure.description, possiblyExecuted: failure.possiblyExecuted,
                    requiresObservation: failure.requiresObservation, result: facts)
            }
        } else if homeAction {
            result = try hid.home(using: buttonTransport!) {
                try checkInputCanContinue()
            }
        } else if pressing {
            guard let name = action.fields["key"] as? String, let key = NativePressKey(rawValue: name) else {
                throw IPhoneUseError("invalid_key", "Unknown native keyboard key")
            }
            result = try hid.press(key) { try checkInputCanContinue() }
        } else if action.kind == "double-tap" {
            let point = try NativeCoordinateMapper.map(target.gesture!.start, screen: screenGuard.context.screen, rotation: rotation)
            result = try hid.doubleTap(point, onContact: onInputStarted) { try checkInputCanContinue() }
        } else if let pinch {
            result = try hid.pinch(pinch, onContact: onInputStarted) { try checkInputCanContinue() }
        } else if let swipe {
            result = try hid.swipe(swipe, onContact: onInputStarted) { try checkInputCanContinue() }
        } else {
            let point = try NativeCoordinateMapper.map(target.gesture!.start, screen: screenGuard.context.screen, rotation: rotation)
            result = try hid.tap(point, hold: action.fields["duration"] as? Double ?? 0.06, onContact: onInputStarted) { try checkInputCanContinue() }
        }
        result["sourceObservationID"] = action.reference.observation
        result["inputTiming"] = timing.result
        result["displayRotation"] = rotation
        result["nativeRotation"] = target.context["nativeRotation"]
        result["screenGuard"] = check.result
        result["preInputCaptures"] = captures
        result["preInputChecks"] = preInputChecks
        if keyboardAction {
            let rect = screenGuard.regions[0].rect
            result["textFieldRect"] = ["x": rect.x, "y": rect.y, "width": rect.width, "height": rect.height]
        }
        return result
    }
    func showPreviewGesture(_ gesture: NativePreviewGesture) { preview?.showGesture(gesture) }
    var previewGestureRotation: String? { preview?.gestureRotation }
    func cancelCurrent() { cancellation.cancel() }
    func prepareText() throws -> [String: Any] {
        try cancellation.check()
        releaseRecordingMediaIfFinished()
        let control = controlStatus(mediaHealth: mediaStatus)
        guard control.available, let hid else {
            throw ActionFailure(code: "native_control_unavailable", description: control.message ?? "Native control is unavailable",
                                possiblyExecuted: false, requiresObservation: false, result: control.result)
        }
        let alreadyPrepared = hid.keyboardStatus["prepared"] as? Bool == true
        do { try hid.prepareKeyboard() }
        catch {
            // Discovery is read-only: failure cannot have sent input or created a service.
            throw ActionFailure(code: (error as? ActionFailure)?.code ?? (error as? IPhoneUseError)?.code ?? "native_keyboard_unavailable",
                description: String(describing: error), possiblyExecuted: false,
                requiresObservation: true, result: ["keyboardPrepared": false, "keyboard": hid.keyboardStatus,
                    "inputReportsSent": 0, "clipboardAccessed": false, "recovery": NativeRecovery.resolveError.result])
        }
        return ["keyboardPrepared": true, "alreadyPrepared": alreadyPrepared, "keyboard": hid.keyboardStatus,
                "inputReportsSent": 0, "focusConfirmed": false, "clipboardAccessed": false]
    }
    func finishText(transaction: String, observation: [String: Any]) throws -> [String: Any] {
        try cancellation.check()
        let now = ProcessInfo.processInfo.systemUptime
        // SessionHost requires the current observation; the transaction requires a
        // post-attempt capture. Reviewing that result need not finish in 30 seconds.
        // Restoration still checks live clipboard ownership, without sending input.
        guard observation["deviceID"] as? String == cli?.device,
              observation["sessionGeneration"] as? String == generation,
              let captured = observation["captureStartedUptime"] as? Double,
              captured.isFinite, captured >= 0, captured <= now else {
            throw IPhoneUseError("stale_reference", "Observe this device/session again before confirming text completion")
        }
        guard let pasteboard else { throw IPhoneUseError("no_text_transaction", "No clipboard text transaction exists in this session") }
        return try pasteboard.finish(transaction: transaction, observedAt: captured)
    }
    func startRecording(duration: Double) throws -> [String: Any] {
        guard let cli, let recording, !stopped else { throw IPhoneUseError("backend_unavailable", "Native backend not started") }
        try cancellation.check()
        guard eventDeliveryQueue != nil else { throw IPhoneUseError("native_recording_unavailable", "Recording requires serialized completion delivery") }
        _ = try NativeRecordingOptions.duration(["duration": duration])
        guard !recording.isActive else { throw IPhoneUseError("recording_busy", "A recording is already active") }
        releaseRecordingMediaIfFinished()
        let control = controlStatus(mediaHealth: mediaStatus)
        guard control.available else { throw IPhoneUseError(control.code ?? "native_recording_unavailable", control.message ?? "Native control unavailable") }
        currentRecordingID = nil
        guard hid?.state == .ready else { throw IPhoneUseError("native_recording_unavailable", "Need ready HID before recording") }
        guard try cli.read(["device", "info", "lockState"])["passcodeRequired"] as? Bool == false else {
            throw IPhoneUseError("device_locked", "Unlock the device before recording")
        }
        let display = try cli.display()
        guard display.backlightOn else { throw IPhoneUseError("capture_unavailable", "Wake the display before recording") }
        guard display.nativeRotation == "rot0", NativeVideoOrientation(rawValue: display.rotation) != nil else {
            throw IPhoneUseError("native_recording_orientation_unsupported", "Recording requires verified native portrait display axes")
        }
        // SessionHost invalidates observations before this explicit command.
        // Start a stream only for this explicit recording. NativeMediaSession
        // checks the ownership inventory and refuses to replace another client.
        if media == nil { media = try makeMediaSession() }
        do {
            guard let media else { throw IPhoneUseError("native_recording_unavailable", "Native media session unavailable") }
            if preview != nil {
                // Reuse the already decoded stream; no keyframe refresh is needed.
                try media.ensureDisplay(display, mayReplace: hid?.state == .ready)
            } else { try media.refreshForRecording(display, mayReplace: hid?.state == .ready) }
            attachPreview()
            guard let receiver = media.recordingReceiver, let mediaID = media.health()["mediaSessionID"] as? String else {
                throw IPhoneUseError("native_recording_unavailable", "Fresh owned recording stream unavailable")
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while receiver.recordingConfiguration()["RTPClockRate"] == nil, ProcessInfo.processInfo.systemUptime < deadline {
                try cancellation.check(); Thread.sleep(forTimeInterval: 0.05)
            }
            try cancellation.check()
            guard try cli.display() == display else { throw IPhoneUseError("capture_context_changed", "Display changed while preparing recording; observe again") }
            let result = try recording.start(duration: duration, receiver: receiver, mediaID: mediaID, rotation: display.rotation, snapshots: receiver.snapshots)
            currentRecordingID = result["recordingID"] as? String
            return result
        } catch {
            releaseRecordingMediaIfFinished()
            throw error
        }
    }
    func stopRecording(id: String) throws -> [String: Any] {
        guard let recording else { throw IPhoneUseError("backend_unavailable", "Native backend not started") }
        var result = try recording.stop(id: id)
        releaseRecordingMediaIfFinished()
        let cleanup = recordingCleanupByID[id] ?? [:]
        result["mediaCleanup"] = cleanup
        result["mediaRetainedForPreview"] = preview != nil && media?.isActive == true
        if cleanup["mediaStopAcknowledged"] as? Bool == false {
            throw ActionFailure(code: "recording_cleanup_unconfirmed", description: "Recording stopped but media cleanup was not confirmed",
                                possiblyExecuted: true, requiresObservation: true, result: result)
        }
        return result
    }
    private func attachPreview() {
        if let receiver = media?.recordingReceiver, let display = media?.boundDisplay {
            preview?.attach(receiver, display: display)
        }
    }
    private func ensurePreviewMedia(_ display: NativeDisplay) throws {
        guard display.backlightOn, display.nativeRotation == "rot0", NativeVideoOrientation(rawValue: display.rotation) != nil else {
            throw IPhoneUseError("preview_display_unavailable", "Preview needs a lit display with supported orientation")
        }
        if media == nil { media = try makeMediaSession() }
        try media?.ensureDisplay(display, mayReplace: hid?.state == .ready)
        attachPreview()
    }
    func startPreview(options: NativePreviewOptions = NativePreviewOptions()) throws -> [String: Any] {
        try cancellation.check()
        if let preview { return try preview.status(for: options) }
        guard controlError == nil, hid?.state == .ready, let cli,
              recordingMediaCleanup["mediaStopAcknowledged"] as? Bool != false else {
            throw IPhoneUseError("preview_unavailable", "Native control or media cleanup is not ready")
        }
        let preview = try NativePreview(port: options.port, device: previewDevice); self.preview = preview; previewFailure = nil
        do {
            let facts = try NativeCaptureChecks.read { try cli.read($0) }
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
            throw IPhoneUseError("native_media_cleanup_unconfirmed", "Preview closed but media stop is unconfirmed")
        }
        return ["state": "stopped", "mediaRetainedForRecording": recording?.isActive == true]
    }
    func previewTick() -> Bool {
        guard let preview, !stopped, !cancellation.isCancelled, let cli, controlError == nil else { return false }
        var checkingDisplay = true
        do {
            let display = try NativeCaptureChecks.read { try cli.read($0, timeout: 3) }.display
            guard display.backlightOn else { throw IPhoneUseError("device_locked", "Display is not awake") }
            let recovery = previewContinuity.needsRecovery(media?.recordingReceiver?.snapshots?.status() ?? [:])
            var changed = recovery || media?.matchesDisplay(display) != true
            var reason = recovery ? "decoder_continuity_lost" : "display_metadata_changed"
            do { try media?.recordingReceiver?.snapshots?.rejectConflictingGeometry(display) }
            catch { changed = true; reason = "frame_geometry_conflict: \(error)" }
            if !changed {
                changed = try previewOrientation.needsRefresh(cli: cli, snapshots: media?.recordingReceiver?.snapshots, display: display)
                if changed { reason = "frame_rotation_conflict" }
            }
            if changed {
                checkingDisplay = false
                NativePreviewEvents.append(to: paths.directory.appendingPathComponent("preview-events.jsonl"),
                    event: "refresh_started", reason: reason, source: media?.health() ?? [:])
                preview.suspend(recovery ? "Recovering video continuity" : "Synchronizing rotation")
                recording?.endSegment(reason: recovery ? "media_discontinuity" : "display_changed")
                releaseRecordingMediaIfFinished(force: true)
                guard recordingMediaCleanup["mediaStopAcknowledged"] as? Bool != false else {
                    throw IPhoneUseError("native_media_cleanup_unconfirmed", "Media stop unconfirmed")
                }
                let refreshed = try NativeCaptureChecks.read { try cli.read($0, timeout: 3) }.display
                try ensurePreviewMedia(refreshed)
                NativePreviewEvents.append(to: paths.directory.appendingPathComponent("preview-events.jsonl"),
                    event: "refresh_completed", reason: reason, source: media?.health() ?? [:])
            } else { attachPreview() }
            return changed
        } catch {
            let health = media?.health() ?? [:]
            if checkingDisplay, !cancellation.isCancelled, NativePreviewPoll.canDefer(error, health: health) {
                NativePreviewEvents.append(to: paths.directory.appendingPathComponent("preview-events.jsonl"),
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
    func stop() -> [String: Any] {
        if stopped { return cleanupFacts }
        stopped = true; cancellation.cancel()
        preview?.close(); preview = nil
        var result = hid?.release() ?? ["releaseRequired": false, "releaseUncertain": false]
        result.merge(recording?.close() ?? ["recordingProcessExited": true]) { _, new in new }
        result.merge(hid?.closeKeyboard() ?? ["keyboardRemoveAcknowledged": true]) { _, new in new }
        result.merge(pasteboard?.close() ?? ["pasteboardRestoreAcknowledged": true]) { _, new in new }
        pasteboardTransport?.cancel(); pasteboardTransport = nil
        let mediaCleanup = media?.close() ?? (recordingMediaCleanup.isEmpty ? ["mediaStopAcknowledged": true] : recordingMediaCleanup)
        result.merge(cleanupFacts) { _, new in new }
        result.merge(mediaCleanup) { _, new in new }
        mediaTransport?.cancel(); hidTransport?.cancel(); buttonTransport?.cancel(); buttonTransport = nil; hid = nil; media = nil; mediaClient = nil
        result["tunnelReleaseAcknowledged"] = tunnel?.close() ?? (cleanupFacts["tunnelReleaseAcknowledged"] as? Bool ?? true)
        tunnel = nil
        deviceLock = nil
        result["connectionsClosed"] = true
        result["shutdownAcknowledged"] = result["mediaStopAcknowledged"] as? Bool != false && result["releaseUncertain"] as? Bool != true
            && result["tunnelReleaseAcknowledged"] as? Bool == true
            && result["keyboardRemoveAcknowledged"] as? Bool == true
            && result["pasteboardRestoreAcknowledged"] as? Bool == true
            && result["recordingProcessExited"] as? Bool == true
        result["backendStopped"] = true
        cleanupFacts = result
        return result
    }
}

enum NativeEndpointInventory {
    static func read(path: String?, now: Date = Date()) throws -> String? {
        guard let path else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let modified = attributes[.modificationDate] as? Date,
              (0...30).contains(now.timeIntervalSince(modified)),
              let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= 16 * 1024 * 1024 else {
            throw IPhoneUseError("native_endpoint_inventory_invalid", "Provide a nonempty, regular Apple netstat -anvl -p tcp output file captured within 30 seconds")
        }
        return try String(contentsOfFile: path, encoding: .utf8)
    }
}
