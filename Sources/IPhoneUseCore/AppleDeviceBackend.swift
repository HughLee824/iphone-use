import Foundation
import CoreGraphics
import ImageIO
import AppleNativeBridge

final class AppleDeviceBackend: SessionBackend {
    private let config: HostConfiguration
    let paths: SessionPaths
    let cancellation = NativeCancellation()
    let generation = UUID().uuidString
    var cli: AppleDeviceCLI?
    private var deviceLock: SessionDeviceLock?
    var pasteboardTransport: NativeTransport?
    var pasteboard: NativeTextPasteboard?
    var pasteboardError: String?
    var buttonTransport: NativeTransport?
    var buttonError: String?
    private var hidTransport: NativeTransport?
    var mediaTransport: NativeTransport?
    var mediaClient: NativeFeatureClient?
    var connectedDeviceIdentifier: String?
    var connectedDeviceAddress: String?
    var hid: NativeHIDAdapter?
    var media: NativeDisplayMediaSession?
    var tunnel: ASPairedTunnel?
    var controlError: String?
    var controlErrorCode: String?
    private var cleanupFacts: [String: Any] = [:]
    var recordingMediaCleanup: [String: Any] = [:]
    var recordingCleanupByID: [String: [String: Any]] = [:]
    var currentRecordingID: String?
    var eventDeliveryQueue: DispatchQueue?
    var stopped = false
    var recording: NativeStreamRecording?
    let previewOrientation = NativePreviewOrientation()
    let previewContinuity = NativePreviewContinuity()
    var preview: NativePreview?
    var previewDevice = NativePreviewDevice.unknown
    var previewFailure: String?
    private var recordingSupported = false

    private let makeHID: (NativeTransport, NativeCancellation) -> NativeHIDAdapter

    init(
        config: HostConfiguration, paths: SessionPaths,
        makeHID: @escaping (NativeTransport, NativeCancellation) -> NativeHIDAdapter = {
            NativeHIDAdapter(transport: $0, cancellation: $1)
        }
    ) {
        self.config = config
        self.paths = paths
        self.makeHID = makeHID
    }
    func setEventDeliveryQueue(_ queue: DispatchQueue) { eventDeliveryQueue = queue }
    func start() throws -> [String: Any] {
        let details = try CoreDevice.read(["device", "info", "details", "--device", config.device])
        recordingSupported = NativeRecordingOptions.supported(by: details)
        previewDevice = NativePreviewDevice(details: details)
        guard let hardware = details["hardwareProperties"] as? [String: Any],
            hardware["reality"] as? String == "physical", let udid = hardware["udid"] as? String,
            let properties = details["deviceProperties"] as? [String: Any],
            properties["developerModeStatus"] as? String == "enabled",
            let connection = details["connectionProperties"] as? [String: Any],
            connection["pairingState"] as? String == "paired", let address = connection["tunnelIPAddress"] as? String,
            let identifier = details["identifier"] as? String
        else { throw CoreDevice.nativeDeviceUnavailable(details) }
        deviceLock = try SessionDeviceLock(root: paths.directory.deletingLastPathComponent(), device: udid)
        cli = AppleDeviceCLI(device: udid, cancellation: cancellation)
        prepareRecorder()
        do {
            guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27,
                (properties["osVersionNumber"] as? String)?.hasPrefix("27.") == true
            else {
                throw IPhoneUseError(
                    "native_protocol_unsupported", "The experimental control adapter targets macOS 27 and iOS 27 only")
            }
            let inventory = try NativeEndpointInventory.read(path: config.nativeEndpointInventory)
            let paired = try ASPairedTunnel(udid: udid, deviceIdentifier: identifier, endpointInventory: inventory)
            tunnel = paired
            connectedDeviceIdentifier = identifier
            connectedDeviceAddress = address
            try cancellation.check()
            guard paired.deviceAddress == address else {
                throw IPhoneUseError(
                    "native_device_mismatch", "Paired tunnel changed since device discovery; connect again explicitly")
            }
            let displayTransport = try AppleServiceTransport(
                tunnel: paired, service: "com.apple.coredevice.displayservice")
            mediaTransport = displayTransport
            mediaClient = NativeFeatureClient(
                transport: displayTransport, deviceIdentifier: identifier,
                version: try NativeMediaFactory.coreDeviceVersion())
            let inputTransport = try AppleServiceTransport(
                tunnel: paired, service: "com.apple.coredevice.hid.universalhidservice")
            hidTransport = inputTransport
            let input = makeHID(inputTransport, cancellation)
            try input.prepare()
            hid = input
        } catch { try recordStartupFailure(error) }
        return try status()
    }
    private func prepareRecorder() {
        let deliveryQueue = eventDeliveryQueue
        recording = NativeStreamRecording(
            root: paths.directory.appendingPathComponent("recordings"),
            onFinish: { [weak self] recordingID, mediaID in
                deliveryQueue?.async { [weak self] in
                    guard let self, !self.stopped, self.currentRecordingID == recordingID,
                        self.media?.health()["mediaSessionID"] as? String == mediaID
                    else { return }
                    self.releaseRecordingMediaIfFinished()
                }
            })
    }

    private func recordStartupFailure(_ error: Error) throws {
        controlError = (error as NSError).userInfo[NSLocalizedDescriptionKey] as? String ?? String(describing: error)
        controlErrorCode =
            (error as? IPhoneUseError)?.code ?? (error as NSError).userInfo["somaCode"] as? String
            ?? "native_control_unavailable"
        cleanupFacts = media?.close() ?? ["mediaStopAcknowledged": true]
        mediaTransport?.cancel()
        hidTransport?.cancel()
        hid = nil
        cleanupFacts["tunnelReleaseAcknowledged"] =
            tunnel?.close() ?? ((error as NSError).userInfo["tunnelReleaseAcknowledged"] as? Bool ?? true)
        tunnel = nil
        // Explicit observation-only readiness, no Runner fallback or silent input support claim.
        try saveJSON(
            [
                "controlAvailable": false, "error": controlError!, "errorCode": controlErrorCode!,
                "cleanup": cleanupFacts
            ], to: paths.directory.appendingPathComponent("native-control.json"))
    }

    func status() throws -> [String: Any] {
        guard !stopped else { throw IPhoneUseError("backend_unavailable", "Native session closed") }
        releaseRecordingMediaIfFinished()
        let health = mediaStatus
        let streamRecordingSupported =
            media?.recordingReceiver.map { NativeStreamRecording.supports($0.recordingConfiguration()) } ?? false
        let hidState = hid?.state
        let closing = cancellation.isCancelled
        let control = NativeControlStatus.resolve(
            hid: hidState, media: health, closing: closing, startupCode: controlErrorCode, startupError: controlError,
            requiresMedia: media?.isActive == true)
        var result: [String: Any] = [
            "backend": "apple-native", "sessionGeneration": generation, "deviceID": cli?.device ?? config.device,
            "captureSourcePolicy": cli?.captureSourcePolicy ?? [:],
            "recording": recording?.status() ?? ["state": "idle"],
            "preview": preview?.status() ?? [
                "state": previewFailure == nil ? "stopped" : "failed", "error": previewFailure as Any? ?? NSNull()
            ],
            "recordingSupport": [
                "supported": control.available, "formatVerified": streamRecordingSupported,
                "source": "owned_native_rtp", "appleCLIAvailable": recordingSupported, "codec": "hevc",
                "method": "native_rtp"
            ], "capabilities": capabilities(control: control, closing: closing),
            "systemButtons": ["servicePrepared": buttonTransport != nil, "error": buttonError as Any? ?? NSNull()],
            "keyboard": hid?.keyboardStatus ?? [:],
            "textInputMethods": [
                "asciiHID": control.available && hid?.canType == true,
                "unicodePasteboard": control.available && hid?.canType == true && pasteboardError == nil
                    && (pasteboard?.available ?? true)
            ], "textMethodSelection": ["auto", "keys", "paste"], "textModes": ["insert", "replace", "append"],
            "textFinishSupported": true, "textPrepareSupported": true, "textCaretConfirmationSupported": true,
            "pressKeys": NativePressKey.allCases.map(\.rawValue),
            "pasteboard": pasteboard?.status ?? ["restorePending": false], "sessionClosing": closing,
            "hidState": hidState?.rawValue ?? "unprepared", "media": health, "runnerStarted": false,
            "serviceTransport": config.nativeEndpointInventory == nil
                ? "apple-coredevice-service-socket" : "apple-paired-tunnel",
            "mediaOwnershipPolicy": "read_only_inventory_before_input_dispatch",
            "recordingMediaCleanup": recordingMediaCleanup,
            "endpointDiscovery": config.nativeEndpointInventory == nil
                ? "apple-coredevice-service-socket" : "supplied-apple-netstat-inventory",
            "validation": "experimental; inspect the after-observation to verify each input"
        ]
        result.merge(control.result) { _, new in new }
        return result
    }
    private func capabilities(control: NativeControlStatus, closing: Bool) -> [String: Bool] {
        [
            "terminate": !closing, "relaunch": !closing, "recording": control.available, "screenshot": true,
            "tap": control.available, "ax": false, "swipe": control.available, "pinch": control.available,
            "doubleTap": control.available, "longPress": control.available,
            "home": control.available && buttonError == nil, "text": control.available && hid?.canType == true,
            "press": control.available && hid?.canType == true
        ]
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
            return [
                "bundleId": bundle, "transportStatus": "acknowledged", "verificationStatus": "not_checked",
                "foregroundConfirmed": false, "launch": result
            ]
        } catch {
            throw ActionFailure(
                code: "native_launch_uncertain", description: "Launch result is uncertain: \(error)",
                possiblyExecuted: true, requiresObservation: true)
        }
    }
    func appLifecycle(bundle: String, relaunch: Bool) throws -> [String: Any] {
        guard let cli else { throw IPhoneUseError("backend_unavailable", "Native backend not started") }
        guard pasteboard?.status["restorePending"] as? Bool != true else {
            throw IPhoneUseError(
                "native_pasteboard_pending",
                "Inspect the paste result and text-finish before closing or relaunching its app")
        }
        return try NativeAppLifecycle(
            read: { arguments, tail, timeout in
                try cli.read(arguments, trailingArguments: tail, timeout: max(1, Int(ceil(timeout))))
            }, checkCancellation: { try self.cancellation.check() }
        ).run(bundle: bundle, relaunch: relaunch)
    }
    func cancelCurrent() { cancellation.cancel() }
    func stop() -> [String: Any] {
        if stopped { return cleanupFacts }
        stopped = true
        cancellation.cancel()
        preview?.close()
        preview = nil
        var result = hid?.release() ?? ["releaseRequired": false, "releaseUncertain": false]
        result.merge(recording?.close() ?? ["recordingProcessExited": true]) { _, new in new }
        result.merge(hid?.closeKeyboard() ?? ["keyboardRemoveAcknowledged": true]) { _, new in new }
        result.merge(pasteboard?.close() ?? ["pasteboardRestoreAcknowledged": true]) { _, new in new }
        pasteboardTransport?.cancel()
        pasteboardTransport = nil
        let mediaCleanup =
            media?.close() ?? (recordingMediaCleanup.isEmpty ? ["mediaStopAcknowledged": true] : recordingMediaCleanup)
        result.merge(cleanupFacts) { _, new in new }
        result.merge(mediaCleanup) { _, new in new }
        mediaTransport?.cancel()
        hidTransport?.cancel()
        buttonTransport?.cancel()
        buttonTransport = nil
        hid = nil
        media = nil
        mediaClient = nil
        result["tunnelReleaseAcknowledged"] =
            tunnel?.close() ?? (cleanupFacts["tunnelReleaseAcknowledged"] as? Bool ?? true)
        tunnel = nil
        deviceLock = nil
        result["connectionsClosed"] = true
        result["shutdownAcknowledged"] =
            result["mediaStopAcknowledged"] as? Bool != false && result["releaseUncertain"] as? Bool != true
            && result["tunnelReleaseAcknowledged"] as? Bool == true
            && result["keyboardRemoveAcknowledged"] as? Bool == true
            && result["pasteboardRestoreAcknowledged"] as? Bool == true
            && result["recordingProcessExited"] as? Bool == true
        result["backendStopped"] = true
        cleanupFacts = result
        return result
    }
}
