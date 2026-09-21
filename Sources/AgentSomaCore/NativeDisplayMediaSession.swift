import Foundation

// The device's screenshot provider can retain the old landscape transform while
// a media stream survives a 180-degree scene rotation. Rebind only our stream
// before capture; do not rotate pixels, reconnect HID, or replay an input.
// Calls are serialized by SessionHost, including capture and shutdown.
final class NativeDisplayMediaSession {
    private struct Geometry: Equatable {
        let id: UInt64
        let width: Double, height: Double, scale: Double
        let rotation: String, nativeRotation: String
        init(_ display: NativeDisplay) {
            id = display.id; width = display.pixelWidth; height = display.pixelHeight
            scale = display.scale; rotation = display.rotation; nativeRotation = display.nativeRotation
        }
    }
    private let makeSession: () throws -> NativeMediaSession
    private let startSession: (NativeMediaSession, NativeDisplay) throws -> Void
    private var session: NativeMediaSession?
    private var geometry: Geometry?
    private var failure: String?
    private var closed = false
    private var refreshCount = 0
    private var lastRefreshCleanup: [String: Any]?
    private var recordingRefreshCount = 0
    private var lastRecordingRefreshCleanup: [String: Any]?

    init(makeSession: @escaping () throws -> NativeMediaSession,
         startSession: @escaping (NativeMediaSession, NativeDisplay) throws -> Void) {
        self.makeSession = makeSession; self.startSession = startSession
    }

    var recordingReceiver: NativeRTPReceiver? { session?.recordingReceiver }

    func matchesDisplay(_ display: NativeDisplay) -> Bool { geometry == Geometry(display) }

    func ensureDisplay(_ display: NativeDisplay, mayReplace: Bool) throws {
        try bind(display, mayReplace: mayReplace, forRecording: false)
    }

    // An explicit recording start needs fresh video even when the source has
    // gone quiescent and PLI cannot wake it. Never retry a failed replacement.
    func refreshForRecording(_ display: NativeDisplay, mayReplace: Bool) throws {
        guard matchesDisplay(display) else {
            throw SomaError("stale_observation", "Observe the changed display before starting recording")
        }
        try bind(display, mayReplace: mayReplace, forRecording: true)
    }

    private func bind(_ display: NativeDisplay, mayReplace: Bool, forRecording: Bool) throws {
        guard !closed, failure == nil else {
            throw SomaError("native_media_display_refresh_failed", failure ?? "Media binding is closed; reconnect explicitly")
        }
        let next = Geometry(display)
        guard forRecording || geometry != next else { return }
        let replacing = session != nil
        if let session, !mayReplace || session.health()["healthy"] as? Bool != true {
            failure = "Media replacement requested while input or media was not ready; close and reconnect explicitly"
            throw SomaError("native_media_display_refresh_failed", failure!)
        }
        do {
            if let session {
                let cleanup = session.close()
                if forRecording { lastRecordingRefreshCleanup = cleanup }
                else { lastRefreshCleanup = cleanup }
                guard cleanup["mediaStopAcknowledged"] as? Bool == true else {
                    throw SomaError("native_media_display_refresh_failed", "Owned media stop was not confirmed; no replacement stream was started")
                }
                self.session = nil
            }
            let fresh = try makeSession()
            session = fresh // Retain ownership even when start/negotiation fails.
            try startSession(fresh, display)
            guard fresh.health()["healthy"] as? Bool == true else {
                throw SomaError("native_media_unhealthy", "Replacement media has no healthy RTP/RTCP flow")
            }
            geometry = next
            if replacing {
                if forRecording { recordingRefreshCount += 1 }
                else { refreshCount += 1 }
            }
        } catch {
            failure = String(describing: error)
            // No retry after a lost start/stop reply. NativeMediaSession.close is
            // idempotent and verifies the UUID before a scoped stop.
            _ = session?.close()
            throw error
        }
    }

    func health() -> [String: Any] {
        var result = session?.health() ?? ["healthy": false]
        result["mediaSessionID"] = session?.sessionID.uuidString as Any? ?? NSNull()
        result["boundDisplayRotation"] = geometry?.rotation as Any? ?? NSNull()
        result["displayRefreshCount"] = refreshCount
        result["recordingRefreshCount"] = recordingRefreshCount
        if let lastRecordingRefreshCleanup { result["lastRecordingRefreshCleanup"] = lastRecordingRefreshCleanup }
        if let lastRefreshCleanup { result["lastDisplayRefreshCleanup"] = lastRefreshCleanup }
        if let failure {
            result["healthy"] = false; result["error"] = failure
            result["healthReason"] = "display_refresh_failed"
        }
        return result
    }

    func close() -> [String: Any] {
        closed = true
        var result = session?.close() ?? lastRefreshCleanup ?? ["mediaStopAcknowledged": true]
        result["displayRefreshCount"] = refreshCount
        result["recordingRefreshCount"] = recordingRefreshCount
        if let lastRecordingRefreshCleanup { result["lastRecordingRefreshCleanup"] = lastRecordingRefreshCleanup }
        if let lastRefreshCleanup { result["lastDisplayRefreshCleanup"] = lastRefreshCleanup }
        return result
    }
}
