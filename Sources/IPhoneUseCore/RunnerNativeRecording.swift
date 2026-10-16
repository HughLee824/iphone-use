import Foundation
import AppleNativeBridge

// Raw XCTest screenshot axes plus EXIF orientation. Only conflict evidence:
// CoreDevice remains the authority after stopping the owned stream.
struct RunnerPreviewGeometry {
    let width: Int, height: Int, orientation: Int

    func conflicts(with display: NativeDisplay) -> Bool {
        let sideways = orientation == 6 || orientation == 8
        if (sideways ? height : width) != Int(display.pixelWidth) ||
            (sideways ? width : height) != Int(display.pixelHeight) { return true }
        let displaySideways = display.rotation == "rot90" || display.rotation == "rot270"
        let nativeWidth = Int(displaySideways ? display.pixelHeight : display.pixelWidth)
        let nativeHeight = Int(displaySideways ? display.pixelWidth : display.pixelHeight)
        // A provider may bake the rotation into its pixels. Do not interpret
        // an upright tag as portrait unless the raw pixels use native axes.
        guard display.nativeRotation == "rot0", width == nativeWidth, height == nativeHeight else { return false }
        return [1: "rot0", 3: "rot180", 6: "rot90", 8: "rot270"][orientation] != display.rotation
    }
}

protocol RunnerRecordingConnection: AnyObject {
    var source: NativeRecordingSource { get }
    var sessionID: String { get }
    var rotation: String { get }
    func verifyDisplay() throws
    var previewReceiver: NativeRTPReceiver? { get }
    var previewDisplay: NativeDisplay? { get }
    var previewDevice: NativePreviewDevice { get }
    var previewRefreshReason: String { get }
    func previewNeedsRefresh() throws -> Bool
    func refreshPreview() throws
    func close() -> [String: Any]
}

extension RunnerRecordingConnection {
    var previewRefreshReason: String { "display_changed" }
    var previewReceiver: NativeRTPReceiver? { nil }
    var previewDisplay: NativeDisplay? { nil }
    var previewDevice: NativePreviewDevice { .unknown }
    func previewNeedsRefresh() throws -> Bool { try verifyDisplay(); return false }
    func refreshPreview() throws { try verifyDisplay() }
}

// A display-only connection inside the existing device-lock owner. No
// AppleDeviceBackend, second control session, HID preparation or XCTest input.
private final class RunnerMediaConnection: RunnerRecordingConnection {
    private let previewOrientation = NativePreviewOrientation()
    private let cli: AppleDeviceCLI
    private let cancellation: NativeCancellation
    private var tunnel: ASPairedTunnel?
    private var transport: NativeTransport?
    private var media: NativeDisplayMediaSession?
    private var display: NativeDisplay?
    private(set) var previewDevice = NativePreviewDevice.unknown
    private var receiver: NativeRTPReceiver?
    private var cleanup: [String: Any]?
    private(set) var previewRefreshReason = "none"
    var source: NativeRecordingSource { receiver! } // Only returned after prepare succeeds.
    var sessionID: String { media!.health()["mediaSessionID"] as! String }
    var rotation: String { display!.rotation }
    var previewReceiver: NativeRTPReceiver? { media?.recordingReceiver }
    var previewDisplay: NativeDisplay? { display }

    private init(device: String, cancellation: NativeCancellation) {
        self.cancellation = cancellation
        cli = AppleDeviceCLI(device: device, cancellation: cancellation)
    }

    static func open(device: String, cancellation: NativeCancellation) throws -> RunnerRecordingConnection {
        let connection = RunnerMediaConnection(device: device, cancellation: cancellation)
        do { try connection.prepare(); return connection }
        catch {
            var cleanup = connection.close()
            if (error as NSError).userInfo["tunnelReleaseAcknowledged"] as? Bool == false {
                cleanup["tunnelReleaseAcknowledged"] = false
            }
            // A possibly-created stream is never restarted automatically. Retain
            // cleanup evidence even when the recording writer was never started.
            throw ActionFailure(code: (error as? IPhoneUseError)?.code ?? "native_recording_unavailable",
                description: String(describing: error),
                possiblyExecuted: cleanup["mediaStopAcknowledged"] as? Bool != true ||
                    cleanup["tunnelReleaseAcknowledged"] as? Bool != true || (error as? TransportError)?.possiblySent == true,
                requiresObservation: true, result: ["recordingCleanup": cleanup])
        }
    }

    private func prepare() throws {
        let details = try cli.read(["device", "info", "details"])
        previewDevice = NativePreviewDevice(details: details)
        guard let hardware = details["hardwareProperties"] as? [String: Any], hardware["reality"] as? String == "physical",
              let udid = hardware["udid"] as? String, udid == cli.device,
              let properties = details["deviceProperties"] as? [String: Any], properties["developerModeStatus"] as? String == "enabled",
              ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27,
              (properties["osVersionNumber"] as? String)?.hasPrefix("27.") == true,
              let connection = details["connectionProperties"] as? [String: Any], connection["pairingState"] as? String == "paired",
              let address = connection["tunnelIPAddress"] as? String, let identifier = details["identifier"] as? String else {
            throw IPhoneUseError("native_recording_unavailable", "Recording requires a paired physical iPhone with Developer Mode on macOS/iOS 27")
        }
        guard try cli.read(["device", "info", "lockState"])["passcodeRequired"] as? Bool == false else {
            throw IPhoneUseError("device_locked", "Unlock the iPhone before recording")
        }
        let display = try cli.display()
        guard display.backlightOn, display.nativeRotation == "rot0", NativeVideoOrientation(rawValue: display.rotation) != nil else {
            throw IPhoneUseError("native_recording_orientation_unsupported", "Need a lit display with a verified native portrait axis")
        }
        self.display = display
        let paired = try ASPairedTunnel(udid: udid, deviceIdentifier: identifier, endpointInventory: nil)
        tunnel = paired
        guard paired.deviceAddress == address else { throw IPhoneUseError("native_device_mismatch", "Paired tunnel changed; reconnect explicitly") }
        let transport = try AppleServiceTransport(tunnel: paired, service: "com.apple.coredevice.displayservice")
        self.transport = transport
        let media = try NativeMediaFactory.make(transport: transport, identifier: identifier, address: address, cancellation: cancellation, captureSnapshots: true)
        self.media = media
        // This connection is created only for an explicit media request, so
        // its first stream is already fresh; no initial replacement is necessary.
        try media.ensureDisplay(display, mayReplace: true)
        guard let receiver = media.recordingReceiver else { throw IPhoneUseError("native_recording_unavailable", "No owned receiver") }
        self.receiver = receiver
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while receiver.recordingConfiguration()["RTPClockRate"] == nil, ProcessInfo.processInfo.systemUptime < deadline {
            try cancellation.check(); Thread.sleep(forTimeInterval: 0.05)
        }
        try verifyDisplay()
    }

    func verifyDisplay() throws {
        try cancellation.check()
        guard try cli.read(["device", "info", "lockState"])["passcodeRequired"] as? Bool == false else {
            throw IPhoneUseError("device_locked", "Device locked during recording")
        }
        guard try cli.display() == display else { throw IPhoneUseError("display_changed", "Display changed during recording") }
    }

    func previewNeedsRefresh() throws -> Bool {
        let current = try NativeCaptureChecks.read { try self.cli.read($0, timeout: 3) }.display
        guard current.backlightOn else { throw IPhoneUseError("device_locked", "Display is not awake") }
        guard media?.health()["healthy"] as? Bool == true else {
            throw IPhoneUseError("native_media_unhealthy", "Preview media connection lost")
        }
        if current != display { previewRefreshReason = "display_metadata_changed"; return true }
        do { try media?.recordingReceiver?.snapshots?.rejectConflictingGeometry(current) }
        catch { previewRefreshReason = "frame_geometry_conflict: \(error)"; return true }
        let changed = try previewOrientation.needsRefresh(cli: cli, snapshots: media?.recordingReceiver?.snapshots, display: current)
        previewRefreshReason = changed ? "frame_rotation_conflict" : "none"
        return changed
    }
    func refreshPreview() throws {
        guard let media else { throw IPhoneUseError("preview_unavailable", "Media is unavailable") }
        try media.resynchronizeOrientation(mayReplace: true, check: { try self.cancellation.check() }) {
            try NativeCaptureChecks.read { try self.cli.read($0, timeout: 3) }.display
        }
        display = media.boundDisplay; receiver = media.recordingReceiver
    }

    func close() -> [String: Any] {
        if let cleanup { return cleanup }
        var result = media?.close() ?? ["mediaStopAcknowledged": true, "receiverClosed": true]
        transport?.cancel(); transport = nil
        result["tunnelReleaseAcknowledged"] = tunnel?.close() ?? true
        tunnel = nil
        cleanup = result
        return result
    }
}

// Calls are serialized on SessionHost's work queue. The shared recording sink
// owns its timer/packet queue; signal cancellation only flips a thread-safe flag.
final class RunnerNativeRecording {
    private let recording: NativeStreamRecording
    private let cancellation: NativeCancellation
    private let connect: () throws -> RunnerRecordingConnection
    private let previewGeometry: (() throws -> RunnerPreviewGeometry)?
    private var connection: RunnerRecordingConnection?
    private var failure: String?
    private var cleanup: [String: Any] = [:]
    private var cleanupByRecordingID: [String: [String: Any]] = [:]
    private var currentRecordingID: String?
    private var closed = false
    private var preview: NativePreview?
    private var independentOrientationConflicts = 0
    private let previewContinuity = NativePreviewContinuity()
    private let previewEventsURL: URL
    var previewStatus: [String: Any] {
        var result = preview?.status() ?? ["state": failure == nil ? "stopped" : "failed", "error": failure as Any? ?? NSNull()]
        result["independentOrientationConflicts"] = independentOrientationConflicts
        return result
    }

    init(root: URL, cancellation: NativeCancellation,
         previewGeometry: (() throws -> RunnerPreviewGeometry)? = nil,
         connect: @escaping () throws -> RunnerRecordingConnection) {
        previewEventsURL = root.deletingLastPathComponent().appendingPathComponent("preview-events.jsonl")
        recording = NativeStreamRecording(root: root); self.cancellation = cancellation; self.connect = connect
        self.previewGeometry = previewGeometry
    }
    convenience init(device: String, root: URL, cancellation: NativeCancellation,
                     previewGeometry: @escaping () throws -> RunnerPreviewGeometry) {
        self.init(root: root, cancellation: cancellation, previewGeometry: previewGeometry,
                  connect: { try RunnerMediaConnection.open(device: device, cancellation: cancellation) })
    }

    func start(duration: Double) throws -> [String: Any] {
        _ = try NativeRecordingOptions.duration(["duration": duration])
        try cancellation.check()
        guard !closed, failure == nil else { throw IPhoneUseError("recording_reconnect_required", failure ?? "Recorder closed") }
        guard !recording.isActive else { throw IPhoneUseError("recording_busy", "A recording is already active") }
        if preview == nil { releaseMedia() }
        guard failure == nil else { throw IPhoneUseError("recording_reconnect_required", failure!) }
        currentRecordingID = nil
        do {
            let media = try connection ?? connect(); connection = media
            try media.verifyDisplay()
            try cancellation.check()
            let result = try recording.start(duration: duration, receiver: media.source, mediaID: media.sessionID, rotation: media.rotation, snapshots: preview == nil ? nil : media.previewReceiver?.snapshots)
            currentRecordingID = result["recordingID"] as? String
            return result
        } catch {
            // A rebound preview can decode before RTCP has confirmed the
            // recording clock. This pre-writer rejection must not tear down a
            // healthy shared preview or poison its next explicit recording.
            if (error as? IPhoneUseError)?.code == "native_recording_format_unavailable",
               preview != nil, !recording.isActive,
               connection?.source.health()["healthy"] as? Bool == true {
                throw error
            }
            failure = String(describing: error)
            preview?.suspend(failure!); preview?.close(); preview = nil
            releaseMedia()
            if let facts = (error as? ActionFailure)?.result?["recordingCleanup"] as? [String: Any] { cleanup = facts }
            throw error
        }
    }

    func stop(id: String) throws -> [String: Any] {
        var result = try recording.stop(id: id)
        // An old ID is idempotent and must not close a newer active stream.
        if !recording.isActive, preview == nil { releaseMedia() }
        let ownedCleanup = cleanupByRecordingID[id] ?? [:]
        result["mediaCleanup"] = ownedCleanup
        result["mediaRetainedForPreview"] = preview != nil && connection != nil
        if !ownedCleanup.isEmpty,
           ownedCleanup["mediaStopAcknowledged"] as? Bool != true || ownedCleanup["tunnelReleaseAcknowledged"] as? Bool != true {
            throw ActionFailure(code: "recording_cleanup_unconfirmed", description: "File stopped, but owned media cleanup was not confirmed",
                                possiblyExecuted: true, requiresObservation: true, result: result)
        }
        return result
    }

    func checkDisplay() {
        if preview != nil { _ = previewTick(); return }
        if recording.isActive, let connection {
            do { try connection.verifyDisplay() }
            catch {
                let reason = (error as? IPhoneUseError)?.code ?? "display_unavailable"
                recording.endSegment(reason: reason)
            }
        }
        if !recording.isActive, preview == nil { releaseMedia() }
    }

    func status() -> [String: Any] {
        checkDisplay()
        var result = recording.status()
        result["mediaConnectionOpen"] = connection != nil
        result["mediaCleanup"] = cleanup
        if let failure { result["connectionError"] = failure; result["reconnectRequired"] = true }
        return result
    }

    private func releaseMedia() {
        guard let connection else { return }
        cleanup = connection.close(); self.connection = nil
        if let currentRecordingID { cleanupByRecordingID[currentRecordingID] = cleanup }
        if cleanup["mediaStopAcknowledged"] as? Bool != true || cleanup["tunnelReleaseAcknowledged"] as? Bool != true {
            failure = "Owned recording media cleanup was not confirmed; reconnect explicitly"
        }
    }

    func startPreview() throws -> [String: Any] {
        try cancellation.check()
        guard !closed, failure == nil else { throw IPhoneUseError("preview_unavailable", failure ?? "Connection closed") }
        if let preview { return preview.status() }
        do {
            if connection == nil { connection = try connect() }
            let preview = try NativePreview(device: connection?.previewDevice ?? .unknown); self.preview = preview
            try attachPreview()
            return preview.status()
        } catch {
            self.preview?.close(); self.preview = nil
            if !recording.isActive { releaseMedia() }
            failure = String(describing: error)
            throw error
        }
    }
    private func attachPreview() throws {
        guard let receiver = connection?.previewReceiver, let display = connection?.previewDisplay else {
            throw IPhoneUseError("preview_unavailable", "No decoded media source")
        }
        preview?.attach(receiver, display: display)
    }
    func stopPreview() throws -> [String: Any] {
        preview?.close(); preview = nil
        if !recording.isActive { releaseMedia() }
        guard failure == nil else { throw IPhoneUseError("preview_cleanup_failed", failure!) }
        return ["state": "stopped", "mediaRetainedForRecording": recording.isActive]
    }
    func previewTick() -> Bool {
        guard let preview, let connection, !closed, !cancellation.isCancelled else { return false }
        do {
            let recovery = previewContinuity.needsRecovery(connection.previewReceiver?.snapshots?.status() ?? [:])
            var changed = recovery
            var reason = recovery ? "decoder_continuity_lost" : "none"
            if !changed {
                changed = try connection.previewNeedsRefresh()
                if changed { reason = connection.previewRefreshReason }
            }
            if !changed, let previewGeometry, let display = connection.previewDisplay {
                // CoreDevice can report the SAME stale axes for both its PNG
                // and display metadata. XCTest supplies only negative evidence;
                // never derive an input transform or render pixels from this probe.
                changed = try previewGeometry().conflicts(with: display)
                if changed { independentOrientationConflicts += 1; reason = "xctest_geometry_conflict" }
            }
            if changed {
                previewEvent("refresh_started", reason: reason, connection: connection)
                preview.suspend(recovery ? "Recovering video continuity" : "Synchronizing rotation")
                recording.endSegment(reason: recovery ? "media_discontinuity" : "display_changed")
                try connection.refreshPreview()
                if let previewGeometry, let display = connection.previewDisplay {
                    guard try !previewGeometry().conflicts(with: display) else {
                        throw IPhoneUseError("preview_geometry_unavailable", "Display still conflicts with XCTest after owned-media resynchronization")
                    }
                }
            }
            try attachPreview()
            if changed { previewEvent("refresh_completed", reason: reason, connection: connection) }
            return changed
        } catch {
            failure = String(describing: error)
            preview.suspend(failure!); preview.close(); self.preview = nil
            recording.endSegment(reason: "preview_display_unavailable")
            releaseMedia()
            return true
        }
    }
    private func previewEvent(_ event: String, reason: String, connection: RunnerRecordingConnection) {
        var facts = connection.source.health()
        facts["mediaSessionID"] = connection.sessionID; facts["displayRotation"] = connection.rotation
        NativePreviewEvents.append(to: previewEventsURL, event: event, reason: reason, source: facts)
    }

    func close() -> [String: Any] {
        closed = true
        preview?.close(); preview = nil
        var result = recording.close()
        releaseMedia()
        result["mediaCleanup"] = cleanup
        result["recordingCleanupAcknowledged"] = cleanup.isEmpty ||
            (cleanup["mediaStopAcknowledged"] as? Bool == true && cleanup["tunnelReleaseAcknowledged"] as? Bool == true)
        return result
    }
}
