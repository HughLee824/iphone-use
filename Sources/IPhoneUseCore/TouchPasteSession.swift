import Foundation
import AppleNativeBridge

// Host-owned, shared by both control modes. This connection exposes only the
// clipboard service: staging cannot register a keyboard or synthesize key events.
final class TouchPasteSession {
    struct Connection {
        let io: NativeTextPasteboard.IO
        let close: () -> Bool
    }
    private let connect: () throws -> Connection
    private var connection: Connection?
    private var board: NativeTextPasteboard?

    init(connect: @escaping () throws -> Connection) { self.connect = connect }

    convenience init(config: HostConfiguration) {
        self.init {
            let details = try CoreDevice.read(["device", "info", "details", "--device", config.device])
            guard let hardware = details["hardwareProperties"] as? [String: Any],
                  hardware["reality"] as? String == "physical",
                  let udid = hardware["udid"] as? String, udid == config.device,
                  let identifier = details["identifier"] as? String else {
                throw IPhoneUseError("touch_paste_unavailable", "A paired physical iPhone is required for clipboard staging")
            }
            let inventory = try NativeEndpointInventory.read(path: config.nativeEndpointInventory)
            let tunnel = try ASPairedTunnel(udid: udid, deviceIdentifier: identifier, endpointInventory: inventory)
            do {
                let transport = try AppleServiceTransport(tunnel: tunnel, service: "com.apple.coredevice.pasteboardservice")
                let io = AppleTextPasteboardIO(transport: transport, cancellation: NativeCancellation())
                return Connection(io: io, close: { transport.cancel(); return tunnel.close() })
            } catch {
                let closed = tunnel.close()
                throw ActionFailure(code: "touch_paste_unavailable", description: String(describing: error),
                    possiblyExecuted: false, requiresObservation: false,
                    result: ["inputReportsSent": 0, "touchPasteTunnelClosed": closed])
            }
        }
    }

    var pending: Bool { board != nil && board?.restored != true }
    func owns(_ transaction: String) -> Bool { board?.status["transactionID"] as? String == transaction }
    var status: [String: Any] {
        var value = board?.status ?? ["restorePending": false]
        value["method"] = "touch-paste"
        value["inputReportsSent"] = 0
        return value
    }

    func stage(_ text: String, observation: String) throws -> [String: Any] {
        guard !pending else {
            throw IPhoneUseError("touch_paste_pending", "Finish the current clipboard transaction before staging more text; input was not replayed")
        }
        if connection == nil { connection = try connect() }
        let next = NativeTextPasteboard(io: connection!.io)
        board = next // Preserve backup/uncertainty even if staging fails after a write.
        do {
            try next.stage(text, sourceObservationID: observation)
            try next.checkOwnership()
            next.endInputAttempt()
        } catch {
            throw ActionFailure(code: "touch_paste_stage_failed", description: "Clipboard staging failed; no input was sent: \(error)",
                possiblyExecuted: next.status["writeUncertain"] as? Bool == true, requiresObservation: true,
                result: ["pasteboard": status, "inputReportsSent": 0, "textInserted": false])
        }
        return ["textInputMethod": "touch-paste", "phase": "awaiting_touch_paste", "textInserted": false,
                "inputReportsSent": 0, "automaticReplayAllowed": false, "pasteboard": status,
                "nextStep": "Inspect the fresh screenshot, long-press the intended input, then observe and tap its visible Paste menu. Verify the text before text-finish; no keyboard shortcuts were sent."]
    }

    func checkOwnership() throws { if pending { try board?.checkOwnership() } }

    func finish(transaction: String, observedAt: TimeInterval) throws -> [String: Any] {
        guard let board else { throw IPhoneUseError("invalid_text_transaction", "No touch-paste transaction exists") }
        return try board.finish(transaction: transaction, observedAt: observedAt)
    }

    func close() -> [String: Any] {
        var result = board?.close() ?? ["pasteboardRestoreAcknowledged": true]
        result["connectionsClosed"] = connection?.close() ?? true
        connection = nil
        return result
    }
}
