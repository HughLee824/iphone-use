import Foundation
import Darwin
import AppleNativeBridge

protocol NativeMediaReceiver: AnyObject {
    var address: String { get }
    var port: UInt16 { get }
    func configure(_ configuration: [String: Any]) throws
    func health() -> [String: Any]
    func close()
}

final class NativeMediaSession {
    let sessionID = UUID()
    private let client: NativeFeatureClient
    private let receiver: NativeMediaReceiver
    private var mayOwnStream = false
    private var streamIdentifier: UInt32?
    private var closed = false
    private var cleanup: [String: Any]?
    init(client: NativeFeatureClient, receiver: NativeMediaReceiver) {
        self.client = client; self.receiver = receiver
    }

    func start(displayID: UInt64, deviceAddress: String, offer: Data, acceptAnswer: (Data) throws -> Void)
        throws {
        guard !closed, !mayOwnStream else {
            throw IPhoneUseError("native_media_state", "Media session cannot restart")
        }
        let status = try client.invoke("getmediastreamserverstatus", action: "mediastreamstatus")
        guard let sessions = status["sessions"] as? [Any] else {
            throw IPhoneUseError("native_media_unsupported", "Media ownership inventory is unavailable")
        }
        // Coexistence has not been verified. Do not disturb another client's media session.
        guard sessions.isEmpty else {
            throw IPhoneUseError(
                "native_media_busy",
                """
                Another media session exists. End the other client's control or recording session (for example\
                , Device Hub), disconnect this iPhone-use session if one was returned, then explicitly\
                 reconnect. iPhone-use will not stop another client's media session.
                """
            )
        }
        mayOwnStream = true // Even a lost start reply may have created our session.
        do {
            let output = try client.invoke(
                "startmediastream", action: "mediastreamstart",
                input: [
                    "clientSupportedFeatures": nativeUInt(140), "direction": "output", "type": "video",
                    "receiverIP": receiver.address, "receiverPort": nativeUInt(UInt64(receiver.port)),
                    "senderIP": deviceAddress,
                    "timeout": nativeUInt(8), "negotiatorOffer": offer,
                    "options": [
                        "AVCMediaStreamNegotiatorAccessNetworkType": ["int": Int64(1)],
                        "AVCMediaStreamNegotiatorTransportProtocolType": ["int": Int64(2)],
                        "CoreDeviceVideoDisplayMode": ["string": "DisplayByID"],
                        "VideoStreamForDisplayID": ["int": Int64(displayID)],
                        "avcMediaStreamOptionClientSessionID": ["uuid": sessionID as NSUUID]
                    ]
                ])
            guard let connection = output["connection"] as? [String: Any],
                let options = connection["options"] as? [String: Any],
                let identity = options["avcMediaStreamOptionClientSessionID"] as? [String: Any],
                let uuid = identity["uuid"] as? UUID, uuid == sessionID,
                let config = connection["streamConfig"] as? [String: Any],
                let answer = output["negotiatorAnswer"] as? Data
            else {
                throw IPhoneUseError(
                    "native_media_ownership_unknown", "Media reply did not confirm this client's session")
            }
            streamIdentifier = try Self.identifier(config)
            try acceptAnswer(answer)
            try receiver.configure(config)
        } catch { _ = close(); throw error }
    }
    var recordingReceiver: NativeRTPReceiver? { receiver as? NativeRTPReceiver }
    func health() -> [String: Any] {
        var result = receiver.health()
        result["displayConnection"] = client.transport.diagnostics
        return result
    }
    private static func identifier(_ configuration: [String: Any]) throws -> UInt32 {
        guard let value = configuration["RemoteSSRC"] as? NSNumber,
            value.doubleValue >= 1, value.doubleValue <= Double(UInt32.max),
            value.doubleValue.rounded() == value.doubleValue
        else {
            throw IPhoneUseError(
                "native_media_ownership_unknown", "Media stream identifier is missing or invalid")
        }
        return value.uint32Value
    }
    private func ownedIdentifier(in status: [String: Any]) throws -> UInt32? {
        guard let sessions = status["sessions"] as? [[String: Any]] else {
            throw IPhoneUseError("native_media_ownership_unknown", "Media ownership inventory is unavailable")
        }
        var owned: [UInt32] = []
        for session in sessions {
            guard let connection = session["connection"] as? [String: Any],
                let options = connection["options"] as? [String: Any],
                let identity = options["avcMediaStreamOptionClientSessionID"] as? [String: Any],
                let uuid = identity["uuid"] as? UUID
            else {
                throw IPhoneUseError(
                    "native_media_ownership_unknown", "Cannot establish ownership of a media inventory entry")
            }
            if uuid == sessionID {
                owned.append(try Self.identifier(connection["streamConfig"] as? [String: Any] ?? [:]))
            }
        }
        guard owned.count <= 1 else {
            throw IPhoneUseError("native_media_ownership_unknown", "Ambiguous owned media streams")
        }
        return owned.first
    }
    func close() -> [String: Any] {
        if let cleanup { return cleanup }
        closed = true
        var acknowledged = !mayOwnStream
        var error: String?
        if mayOwnStream {
            do {
                let before = try client.invoke("getmediastreamserverstatus", action: "mediastreamstatus")
                if let identifier = try ownedIdentifier(in: before) {
                    guard streamIdentifier == nil || streamIdentifier == identifier else {
                        throw IPhoneUseError(
                            "native_media_ownership_unknown",
                            "Owned stream identifier changed; refusing to stop")
                    }
                    // Apple StopRequest takes UInt32 stream identifiers, not the client UUID.
                    // Bind the reported RemoteSSRC to our UUID before sending an explicit scoped stop.
                    streamIdentifier = identifier
                    _ = try client.invoke(
                        "stopmediastream", action: "mediastreamstop",
                        input: [
                            "stopAll": false, "identifiers": [nativeUInt(UInt64(identifier))]
                        ])
                    let after = try client.invoke("getmediastreamserverstatus", action: "mediastreamstatus")
                    acknowledged = try ownedIdentifier(in: after) == nil
                } else {
                    acknowledged = true // A successful inventory query confirms our UUID is absent.
                }
            } catch let failure { error = String(describing: failure) }
        }
        receiver.close()
        let result: [String: Any] = [
            "mediaSessionID": sessionID.uuidString, "mediaStopAcknowledged": acknowledged,
            "mediaStreamIdentifier": streamIdentifier as Any? ?? NSNull(),
            "mediaStopError": error as Any? ?? NSNull(), "receiverClosed": true
        ]
        cleanup = result
        return result
    }
}
