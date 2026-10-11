import Foundation
import AppleNativeBridge

protocol RunnerRecordingConnection: AnyObject {
    var source: NativeRecordingSource { get }
    var sessionID: String { get }
    var rotation: String { get }
    func verifyDisplay() throws
    func close() -> [String: Any]
}

// A recording-only connection inside the existing device-lock owner. No
// AppleDeviceBackend, second control session, HID preparation or XCTest input.
private final class RunnerMediaConnection: RunnerRecordingConnection {
    private let cli: AppleDeviceCLI
    private let cancellation: NativeCancellation
    private var tunnel: ASPairedTunnel?
    private var transport: NativeTransport?
    private var media: NativeDisplayMediaSession?
    private var display: NativeDisplay?
    private var receiver: NativeRTPReceiver?
    private var cleanup: [String: Any]?
    var source: NativeRecordingSource { receiver! } // Only returned after prepare succeeds.
    var sessionID: String { media!.health()["mediaSessionID"] as! String }
    var rotation: String { display!.rotation }

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
        let media = try NativeMediaFactory.make(transport: transport, identifier: identifier, address: address, cancellation: cancellation)
        self.media = media
        // This connection is created only for an explicit recording request, so
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
    private var connection: RunnerRecordingConnection?
    private var failure: String?
    private var cleanup: [String: Any] = [:]
    private var cleanupByRecordingID: [String: [String: Any]] = [:]
    private var currentRecordingID: String?
    private var closed = false

    init(root: URL, cancellation: NativeCancellation, connect: @escaping () throws -> RunnerRecordingConnection) {
        recording = NativeStreamRecording(root: root); self.cancellation = cancellation; self.connect = connect
    }
    convenience init(device: String, root: URL, cancellation: NativeCancellation) {
        self.init(root: root, cancellation: cancellation, connect: { try RunnerMediaConnection.open(device: device, cancellation: cancellation) })
    }

    func start(duration: Double) throws -> [String: Any] {
        _ = try NativeRecordingOptions.duration(["duration": duration])
        try cancellation.check()
        guard !closed, failure == nil else { throw IPhoneUseError("recording_reconnect_required", failure ?? "Recorder closed") }
        guard !recording.isActive else { throw IPhoneUseError("recording_busy", "A recording is already active") }
        releaseMedia()
        guard failure == nil else { throw IPhoneUseError("recording_reconnect_required", failure!) }
        currentRecordingID = nil
        do {
            let media = try connect(); connection = media
            try cancellation.check()
            let result = try recording.start(duration: duration, receiver: media.source, mediaID: media.sessionID, rotation: media.rotation)
            currentRecordingID = result["recordingID"] as? String
            return result
        } catch {
            failure = String(describing: error)
            releaseMedia()
            if let facts = (error as? ActionFailure)?.result?["recordingCleanup"] as? [String: Any] { cleanup = facts }
            throw error
        }
    }

    func stop(id: String) throws -> [String: Any] {
        var result = try recording.stop(id: id)
        // An old ID is idempotent and must not close a newer active stream.
        if !recording.isActive { releaseMedia() }
        let ownedCleanup = cleanupByRecordingID[id] ?? [:]
        result["mediaCleanup"] = ownedCleanup
        if !ownedCleanup.isEmpty,
           ownedCleanup["mediaStopAcknowledged"] as? Bool != true || ownedCleanup["tunnelReleaseAcknowledged"] as? Bool != true {
            throw ActionFailure(code: "recording_cleanup_unconfirmed", description: "File stopped, but owned media cleanup was not confirmed",
                                possiblyExecuted: true, requiresObservation: true, result: result)
        }
        return result
    }

    func checkDisplay() {
        if recording.isActive, let connection {
            do { try connection.verifyDisplay() }
            catch {
                let reason = (error as? IPhoneUseError)?.code ?? "display_unavailable"
                recording.endSegment(reason: reason)
            }
        }
        if !recording.isActive { releaseMedia() }
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

    func close() -> [String: Any] {
        closed = true
        var result = recording.close()
        releaseMedia()
        result["mediaCleanup"] = cleanup
        result["recordingCleanupAcknowledged"] = cleanup.isEmpty ||
            (cleanup["mediaStopAcknowledged"] as? Bool == true && cleanup["tunnelReleaseAcknowledged"] as? Bool == true)
        return result
    }
}
