import Foundation
import AppleNativeBridge

// Raw XCTest screenshot axes plus EXIF orientation. Only conflict evidence:
// CoreDevice remains the authority after stopping the owned stream.
struct RunnerPreviewGeometry {
    let width: Int, height: Int, orientation: Int

    func conflicts(with display: NativeDisplay) -> Bool {
        let sideways = orientation == 6 || orientation == 8
        if (sideways ? height : width) != Int(display.pixelWidth)
            || (sideways ? width : height) != Int(display.pixelHeight) {
            return true
        }
        let displaySideways = display.rotation == "rot90" || display.rotation == "rot270"
        let nativeWidth = Int(displaySideways ? display.pixelHeight : display.pixelWidth)
        let nativeHeight = Int(displaySideways ? display.pixelWidth : display.pixelHeight)
        // A provider may bake the rotation into its pixels. Do not interpret
        // an upright tag as portrait unless the raw pixels use native axes.
        guard display.nativeRotation == "rot0", width == nativeWidth, height == nativeHeight else {
            return false
        }
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

// Calls are serialized on SessionHost's work queue. The shared recording sink
// owns its timer/packet queue; signal cancellation only flips a thread-safe flag.
final class RunnerNativeRecording {
    private let recording: NativeStreamRecording
    private let cancellation: NativeCancellation
    private let connect: () throws -> RunnerRecordingConnection
    private let previewGeometry: (() throws -> RunnerPreviewGeometry)?
    private let previewDevice: NativePreviewDevice
    private var connection: RunnerRecordingConnection?
    private var failure: String?
    private var cleanup: [String: Any] = [:]
    private var cleanupByRecordingID: [String: [String: Any]] = [:]
    private var currentRecordingID: String?
    private var closed = false
    private var preview: NativePreview?
    var connectionStatus: () -> [String: Any]? = { nil }
    private var independentOrientationConflicts = 0
    private let previewContinuity = NativePreviewContinuity()
    private let previewEventsURL: URL
    var previewStatus: [String: Any] {
        var result =
            preview?.status() ?? [
                "state": failure == nil ? "stopped" : "failed", "error": failure as Any? ?? NSNull()
            ]
        result["independentOrientationConflicts"] = independentOrientationConflicts
        return result
    }

    init(
        root: URL, cancellation: NativeCancellation,
        previewDevice: NativePreviewDevice = .unknown,
        previewGeometry: (() throws -> RunnerPreviewGeometry)? = nil,
        connect: @escaping () throws -> RunnerRecordingConnection
    ) {
        previewEventsURL = root.deletingLastPathComponent().appendingPathComponent("preview-events.jsonl")
        recording = NativeStreamRecording(root: root); self.cancellation = cancellation
        self.connect = connect
        self.previewGeometry = previewGeometry
        self.previewDevice = previewDevice
    }
    convenience init(
        device: String, root: URL, cancellation: NativeCancellation,
        previewDevice: NativePreviewDevice,
        previewGeometry: @escaping () throws -> RunnerPreviewGeometry
    ) {
        self.init(
            root: root, cancellation: cancellation, previewDevice: previewDevice,
            previewGeometry: previewGeometry,
            connect: { try RunnerMediaConnection.open(device: device, cancellation: cancellation) })
    }

    func start(duration: Double) throws -> [String: Any] {
        _ = try NativeRecordingOptions.duration(["duration": duration])
        try cancellation.check()
        guard !closed, failure == nil else {
            throw IPhoneUseError("recording_reconnect_required", failure ?? "Recorder closed")
        }
        guard !recording.isActive else {
            throw IPhoneUseError("recording_busy", "A recording is already active")
        }
        if preview == nil { releaseMedia() }
        guard failure == nil else { throw IPhoneUseError("recording_reconnect_required", failure!) }
        currentRecordingID = nil
        do {
            let media = try connection ?? connect(); connection = media
            try media.verifyDisplay()
            try cancellation.check()
            let result = try recording.start(
                duration: duration, receiver: media.source, mediaID: media.sessionID,
                rotation: media.rotation,
                snapshots: preview == nil ? nil : media.previewReceiver?.snapshots)
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
            if let facts = (error as? ActionFailure)?.result?["recordingCleanup"] as? [String: Any] {
                cleanup = facts
            }
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
            ownedCleanup["mediaStopAcknowledged"] as? Bool != true
                || ownedCleanup["tunnelReleaseAcknowledged"] as? Bool != true {
            throw ActionFailure(
                code: "recording_cleanup_unconfirmed",
                description: "File stopped, but owned media cleanup was not confirmed",
                possiblyExecuted: true, requiresObservation: true, result: result)
        }
        return result
    }

    func checkDisplay() {
        if preview != nil { _ = previewTick(); return }
        if recording.isActive, let connection {
            do { try connection.verifyDisplay() } catch {
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
        if cleanup["mediaStopAcknowledged"] as? Bool != true
            || cleanup["tunnelReleaseAcknowledged"] as? Bool != true {
            failure = "Owned recording media cleanup was not confirmed; reconnect explicitly"
        }
    }

    func showPreviewGesture(_ gesture: NativePreviewGesture) { preview?.showGesture(gesture) }
    var previewGestureRotation: String? { preview?.gestureRotation }
    func reservePreview(options: NativePreviewOptions) throws -> [String: Any] {
        if let preview { return try preview.status(for: options) }
        let preview = try NativePreview(
            port: options.port, device: connection?.previewDevice ?? previewDevice,
            connectionStatus: connectionStatus)
        self.preview = preview
        return preview.status()
    }
    func startPreview(options: NativePreviewOptions = NativePreviewOptions(), duringStartup: Bool = false)
        throws
        -> [String: Any] {
        try cancellation.check()
        guard !closed, failure == nil else {
            throw IPhoneUseError("preview_unavailable", failure ?? "Connection closed")
        }
        if let preview, connection != nil { return try preview.status(for: options) }
        // Reserve the HTTP port before touching media. A collision must not
        // poison this owner or interrupt an existing recording.
        _ = try reservePreview(options: options)
        do {
            if connection == nil { connection = try connect() }
            try attachPreview()
            return preview!.status()
        } catch {
            // Video readiness and Runner authorization are independent. Keep
            // the startup page and its diagnostics when media is unavailable.
            if duringStartup {
                self.preview?.suspend(String(describing: error))
            } else {
                self.preview?.close(); self.preview = nil
            }
            if !recording.isActive { releaseMedia() }
            failure = String(describing: error)
            if duringStartup {
                try cancellation.check()
                return preview!.status()
            }
            throw error
        }
    }
    private func attachPreview() throws {
        guard let receiver = connection?.previewReceiver, let display = connection?.previewDisplay else {
            throw IPhoneUseError("preview_unavailable", "No decoded media source")
        }
        preview?.attach(receiver, display: display, device: connection?.previewDevice)
    }
    func stopPreview() throws -> [String: Any] {
        preview?.close(); preview = nil
        if !recording.isActive { releaseMedia() }
        guard failure == nil else { throw IPhoneUseError("preview_cleanup_failed", failure!) }
        return ["state": "stopped", "mediaRetainedForRecording": recording.isActive]
    }
    func previewTick() -> Bool {
        guard let preview, let connection, !closed, !cancellation.isCancelled else { return false }
        var checkingDisplay = true
        do {
            let recovery = previewContinuity.needsRecovery(
                connection.previewReceiver?.snapshots?.status() ?? [:])
            var changed = recovery
            var reason = recovery ? "decoder_continuity_lost" : "none"
            if !changed {
                changed = try connection.previewNeedsRefresh()
                if changed { reason = connection.previewRefreshReason }
            }
            checkingDisplay = false
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
                try validateRefreshedPreview(connection)
            }
            try attachPreview()
            if changed { previewEvent("refresh_completed", reason: reason, connection: connection) }
            return changed
        } catch {
            if checkingDisplay, !cancellation.isCancelled,
                NativePreviewPoll.canDefer(error, health: connection.source.health()) {
                previewEvent("poll_deferred", reason: String(describing: error), connection: connection)
                return false // A status timeout is not evidence that the independent video stopped.
            }
            failure = String(describing: error)
            preview.suspend(failure!); preview.close(); self.preview = nil
            recording.endSegment(reason: "preview_display_unavailable")
            releaseMedia()
            return true
        }
    }
    private func validateRefreshedPreview(_ connection: RunnerRecordingConnection) throws {
        if let previewGeometry, let display = connection.previewDisplay {
            guard try !previewGeometry().conflicts(with: display) else {
                throw IPhoneUseError(
                    "preview_geometry_unavailable",
                    "Display still conflicts with XCTest after owned-media resynchronization")
            }
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
        result["recordingCleanupAcknowledged"] =
            cleanup.isEmpty
            || (cleanup["mediaStopAcknowledged"] as? Bool == true
                && cleanup["tunnelReleaseAcknowledged"] as? Bool == true)
        return result
    }
}
