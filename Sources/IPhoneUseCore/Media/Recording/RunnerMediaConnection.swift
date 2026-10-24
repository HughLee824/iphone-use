import Foundation
import AppleNativeBridge

// A display-only connection inside the existing device-lock owner. No
// AppleDeviceBackend, second control session, HID preparation or XCTest input.
final class RunnerMediaConnection: RunnerRecordingConnection {
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
    var sessionID: String { media!.sessionID!.uuidString }
    var rotation: String { display!.rotation }
    var previewReceiver: NativeRTPReceiver? { media?.recordingReceiver }
    var previewDisplay: NativeDisplay? { display }

    private init(device: String, cancellation: NativeCancellation) {
        self.cancellation = cancellation
        cli = AppleDeviceCLI(device: device, cancellation: cancellation)
    }

    static func open(device: String, cancellation: NativeCancellation) throws -> RunnerRecordingConnection {
        let connection = RunnerMediaConnection(device: device, cancellation: cancellation)
        do {
            try connection.prepare()
            return connection
        } catch {
            var cleanup = connection.close()
            if (error as NSError).userInfo["tunnelReleaseAcknowledged"] as? Bool == false {
                cleanup["tunnelReleaseAcknowledged"] = false
            }
            // A possibly-created stream is never restarted automatically. Retain
            // cleanup evidence even when the recording writer was never started.
            throw ActionFailure(
                code: (error as? IPhoneUseError)?.code ?? "native_recording_unavailable",
                description: String(describing: error),
                possiblyExecuted: cleanup["mediaStopAcknowledged"] as? Bool != true
                    || cleanup["tunnelReleaseAcknowledged"] as? Bool != true
                    || (error as? TransportError)?.possiblySent == true, requiresObservation: true,
                result: ["recordingCleanup": cleanup])
        }
    }

    private func prepare() throws {
        let details = try cli.read(["device", "info", "details"])
        previewDevice = NativePreviewDevice(details: details)
        guard let hardware = details["hardwareProperties"] as? [String: Any],
            hardware["reality"] as? String == "physical", let udid = hardware["udid"] as? String, udid == cli.device,
            let properties = details["deviceProperties"] as? [String: Any],
            properties["developerModeStatus"] as? String == "enabled",
            ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27,
            (properties["osVersionNumber"] as? String)?.hasPrefix("27.") == true,
            let connection = details["connectionProperties"] as? [String: Any],
            connection["pairingState"] as? String == "paired", let address = connection["tunnelIPAddress"] as? String,
            let identifier = details["identifier"] as? String
        else {
            throw IPhoneUseError(
                "native_recording_unavailable",
                "Recording requires a paired physical iPhone with Developer Mode on macOS/iOS 27")
        }
        guard try cli.read(["device", "info", "lockState"])["passcodeRequired"] as? Bool == false else {
            throw IPhoneUseError("device_locked", "Unlock the iPhone before recording")
        }
        let display = try cli.display()
        guard display.nativeRotation == "rot0", NativeVideoOrientation(rawValue: display.rotation) != nil else {
            throw IPhoneUseError(
                "native_recording_orientation_unsupported", "Need a verified native portrait display axis")
        }
        self.display = display
        let paired = try ASPairedTunnel(udid: udid, deviceIdentifier: identifier, endpointInventory: nil)
        tunnel = paired
        guard paired.deviceAddress == address else {
            throw IPhoneUseError("native_device_mismatch", "Paired tunnel changed; reconnect explicitly")
        }
        let transport = try AppleServiceTransport(tunnel: paired, service: "com.apple.coredevice.displayservice")
        self.transport = transport
        let media = try NativeMediaFactory.make(
            transport: transport, identifier: identifier, address: address, cancellation: cancellation,
            captureSnapshots: true)
        self.media = media
        // This connection is created only for an explicit media request, so
        // its first stream is already fresh; no initial replacement is necessary.
        try media.ensureDisplay(display, mayReplace: true)
        guard let receiver = media.recordingReceiver else {
            throw IPhoneUseError("native_recording_unavailable", "No owned receiver")
        }
        self.receiver = receiver
        try awaitClockRate(receiver)
        let current = try NativeCaptureChecks.read(requireBacklight: false) { try self.cli.read($0) }.display
        guard current.geometry == display.geometry else {
            throw IPhoneUseError("display_changed", "Display geometry changed while preparing video")
        }
    }

    func verifyDisplay() throws {
        try cancellation.check()
        guard try cli.read(["device", "info", "lockState"])["passcodeRequired"] as? Bool == false else {
            throw IPhoneUseError("device_locked", "Device locked during recording")
        }
        let current = try cli.display()
        guard current.backlightOn else {
            throw IPhoneUseError("capture_unavailable", "Wake the display before recording")
        }
        guard current == display else { throw IPhoneUseError("display_changed", "Display changed during recording") }
    }

    func previewNeedsRefresh() throws -> Bool {
        let current = try NativeCaptureChecks.read(requireBacklight: false) { try self.cli.read($0, timeout: 3) }
            .display
        guard media?.health()["healthy"] as? Bool == true else {
            throw IPhoneUseError("native_media_unhealthy", "Preview media connection lost")
        }
        if current.geometry != display?.geometry {
            previewRefreshReason = "display_metadata_changed"
            return true
        }
        do { try media?.recordingReceiver?.snapshots?.rejectConflictingGeometry(current) } catch {
            previewRefreshReason = "frame_geometry_conflict: \(error)"
            return true
        }
        let changed = try previewOrientation.needsRefresh(
            cli: cli, snapshots: media?.recordingReceiver?.snapshots, display: current)
        previewRefreshReason = changed ? "frame_rotation_conflict" : "none"
        return changed
    }
    func refreshPreview() throws {
        guard let media else { throw IPhoneUseError("preview_unavailable", "Media is unavailable") }
        try media.resynchronizeOrientation(
            mayReplace: true, check: { try self.cancellation.check() },
            readDisplay: {
                try NativeCaptureChecks.read(requireBacklight: false) { try self.cli.read($0, timeout: 3) }.display
            })
        display = media.boundDisplay
        receiver = media.recordingReceiver
    }

    func close() -> [String: Any] {
        if let cleanup { return cleanup }
        var result = media?.close() ?? ["mediaStopAcknowledged": true, "receiverClosed": true]
        transport?.cancel()
        transport = nil
        result["tunnelReleaseAcknowledged"] = tunnel?.close() ?? true
        tunnel = nil
        cleanup = result
        return result
    }
    private func awaitClockRate(_ receiver: NativeRTPReceiver) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while receiver.recordingConfiguration()["RTPClockRate"] == nil,
            ProcessInfo.processInfo.systemUptime < deadline {
            try cancellation.check()
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

}
