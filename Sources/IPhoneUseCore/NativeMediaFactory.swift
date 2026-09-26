import Foundation
import AppleNativeBridge

// Both control modes use the same Apple display negotiation and owned RTP
// implementation. This factory never opens a HID or pasteboard service.
enum NativeMediaFactory {
    static func make(transport: NativeTransport, identifier: String, address: String,
                     cancellation: NativeCancellation) throws -> NativeDisplayMediaSession {
        let infoURL = URL(fileURLWithPath: "/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Resources/Info.plist")
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as? [String: Any]
        guard let version = info?["CFBundleVersion"] as? String else {
            throw IPhoneUseError("native_version_unsupported", "Installed CoreDevice version unavailable")
        }
        return NativeDisplayMediaSession(makeSession: {
            try cancellation.check()
            let receiver = try NativeRTPReceiver(deviceAddress: address)
            return NativeMediaSession(client: NativeFeatureClient(transport: transport, deviceIdentifier: identifier, version: version), receiver: receiver)
        }, startSession: { stream, display in
            try cancellation.check()
            let negotiator = try ASMediaNegotiator(error: ())
            try stream.start(displayID: display.id, deviceAddress: address, offer: negotiator.offer) { try negotiator.acceptAnswer($0) }
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while stream.health()["healthy"] as? Bool != true, ProcessInfo.processInfo.systemUptime < deadline {
                try cancellation.check(); Thread.sleep(forTimeInterval: 0.05)
            }
            try cancellation.check()
        })
    }
}
