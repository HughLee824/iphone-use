import Foundation
import CoreGraphics
import ImageIO
import AppleNativeBridge

extension AppleDeviceBackend {
    var mediaStatus: [String: Any] {
        guard let media, media.isActive else { return ["state": "inactive", "healthy": false] }
        return media.health()
    }
    func controlStatus(mediaHealth: [String: Any]) -> NativeControlStatus {
        NativeControlStatus.resolve(
            hid: hid?.state, media: mediaHealth, closing: cancellation.isCancelled,
            startupCode: controlErrorCode, startupError: controlError,
            requiresMedia: media?.isActive == true)
    }
    func makeMediaSession() throws -> NativeDisplayMediaSession {
        guard let mediaTransport, let identifier = connectedDeviceIdentifier,
            let address = connectedDeviceAddress, let tunnel
        else {
            throw IPhoneUseError("native_recording_unavailable", "Native display transport is unavailable")
        }
        guard tunnel.deviceAddress == address else {
            throw IPhoneUseError("native_device_mismatch", "Paired tunnel changed before recording")
        }
        return try NativeMediaFactory.make(
            transport: mediaTransport, identifier: identifier, address: address,
            cancellation: cancellation, captureSnapshots: true)
    }
    private func assertNoForeignMediaSessions(budget: NativeCaptureBudget? = nil) throws {
        try checkMediaInventory(expectedOwnedID: nil, budget: budget)
    }
    private func checkMediaInventory(expectedOwnedID: String?, budget: NativeCaptureBudget? = nil) throws {
        guard let mediaClient else {
            throw IPhoneUseError(
                "native_media_ownership_unknown", "CoreDevice media inventory is unavailable")
        }
        try budget?.check()
        let timeout = budget.map { min(10, $0.deadline - ProcessInfo.processInfo.systemUptime) } ?? 10
        guard timeout > 0 else {
            throw IPhoneUseError(
                "input_preflight_timeout", "No input budget remains for media ownership validation")
        }
        let result = try mediaClient.invoke(
            "getmediastreamserverstatus", action: "mediastreamstatus", timeout: timeout)
        try budget?.check()
        guard let sessions = result["sessions"] as? [[String: Any]] else {
            throw IPhoneUseError(
                "native_media_ownership_unknown", "CoreDevice media ownership inventory is unavailable")
        }
        guard let expectedOwnedID else {
            guard sessions.isEmpty else {
                throw IPhoneUseError(
                    "native_media_busy",
                    """
                    Another client's media session exists. End that control or recording session before input;\
                     iPhone-use will not stop another client's media session.
                    """
                )
            }
            return
        }
        guard sessions.count == 1,
            let connection = sessions[0]["connection"] as? [String: Any],
            let options = connection["options"] as? [String: Any],
            let identity = options["avcMediaStreamOptionClientSessionID"] as? [String: Any],
            let uuid = identity["uuid"] as? UUID, uuid.uuidString == expectedOwnedID
        else {
            throw IPhoneUseError(
                "native_media_busy",
                """
                Another client's media session exists. End that control or recording session before input;\
                 iPhone-use will not stop another client's media session.
                """
            )
        }
    }
    func checkInputAvailability(budget: NativeCaptureBudget? = nil) throws {
        try cancellation.check()
        if media?.isActive == true {
            guard media?.health()["healthy"] as? Bool == true else {
                throw IPhoneUseError("native_media_unhealthy", "Owned recording media stopped before input")
            }
            guard let mediaID = media?.health()["mediaSessionID"] as? String else {
                throw IPhoneUseError(
                    "native_media_ownership_unknown", "Owned media session ID is unavailable")
            }
            try checkMediaInventory(expectedOwnedID: mediaID, budget: budget)
        } else {
            try assertNoForeignMediaSessions(budget: budget)
        }
    }
    func checkInputCanContinue() throws {
        try cancellation.check()
        if media?.isActive == true, media?.health()["healthy"] as? Bool != true {
            throw IPhoneUseError("native_media_unhealthy", "Owned recording media stopped during input")
        }
    }
}
