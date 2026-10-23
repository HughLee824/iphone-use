import Foundation

// Keep the payload until explicit verified finish, the next text action or close:
// a HID queue barrier does not establish that the foreground app consumed Paste.
final class NativeTextPasteboard {
    struct Snapshot: Equatable {
        let changeCount: Int
        let nonce: String
    }
    struct Item: Equatable {
        let types: [String]
        let flavors: [String: Data]
        init(flavors: [String: Data], types: [String]? = nil) {
            self.types = types ?? flavors.keys.sorted(); self.flavors = flavors
        }
    }
    protocol PasteboardAccess: AnyObject {
        func snapshot() throws -> Snapshot
        func read() throws -> [Item]
        func write(_ items: [Item], cleanup: Bool) throws
    }
    private let pasteboardIO: PasteboardAccess
    private var original: [Item]?
    private var payload: [Item]?
    private var owned: Snapshot?
    private var writeUncertain = false
    private(set) var hasAttemptedWrite = false
    private var closed: [String: Any]?
    private var transactionID: String?
    private var sourceObservationID: String?
    private var confirmationAfter: TimeInterval = 0
    private var preparationPhase = "idle"

    init(pasteboardIO: PasteboardAccess) { self.pasteboardIO = pasteboardIO }
    var available: Bool { restored || (closed == nil && !writeUncertain) }
    var restored: Bool { closed?["pasteboardRestoreAcknowledged"] as? Bool == true }

    var status: [String: Any] {
        var result: [String: Any] = [
            "method": "apple-pasteboard-hid-paste", "restorePending": original != nil,
            "writeUncertain": writeUncertain, "ownershipConfirmed": owned != nil,
            "atomicRestore": false, "preparationPhase": preparationPhase
        ]
        result["transactionID"] = transactionID
        result["sourceObservationID"] = sourceObservationID
        return result
    }

    func stage(_ text: String, sourceObservationID: String? = nil) throws {
        guard closed == nil, !writeUncertain else {
            throw IPhoneUseError(
                "native_pasteboard_uncertain",
                "Close this session and inspect the device clipboard before another text action")
        }
        let data = Data(text.utf8)
        let next = [
            Item(flavors: ["public.utf8-plain-text": data, "public.plain-text": data, "public.text": data])
        ]
        preparationPhase = "snapshot_before_backup"
        let before = try pasteboardIO.snapshot()
        preparationPhase = owned == nil ? "read_original" : "read_owned_payload"
        let current = try pasteboardIO.read()
        preparationPhase = "verify_backup_identity"
        guard try pasteboardIO.snapshot() == before else {
            throw IPhoneUseError(
                "native_pasteboard_changed", "Clipboard changed while being read; no write or paste was sent")
        }
        if let owned {
            guard before == owned, current == payload else {
                throw IPhoneUseError(
                    "native_pasteboard_changed",
                    "Another client changed the clipboard; close this session without restoring over their content"
                )
            }
        } else {
            original = current
        }
        // Every explicit text action gets a new identity, even for identical bytes.
        transactionID = UUID().uuidString
        self.sourceObservationID = sourceObservationID
        confirmationAfter = ProcessInfo.processInfo.systemUptime
        if owned != nil, current == next { preparationPhase = "ready"; return }
        // Mark before submission: a failed service reply may follow a device-side write.
        hasAttemptedWrite = true
        writeUncertain = true; owned = nil; payload = next
        preparationPhase = "write_payload"
        try pasteboardIO.write(next, cleanup: false)
        preparationPhase = "verify_payload"
        let after = try pasteboardIO.snapshot()
        guard after.nonce == before.nonce, after.changeCount > before.changeCount,
            try pasteboardIO.read() == next, try pasteboardIO.snapshot() == after
        else {
            throw IPhoneUseError(
                "native_pasteboard_uncertain",
                "Cannot confirm clipboard write ownership; no paste shortcut was sent")
        }
        owned = after; writeUncertain = false
        preparationPhase = "ready"
    }

    func endInputAttempt() { confirmationAfter = ProcessInfo.processInfo.systemUptime }

    func finish(transaction: String, observedAt: TimeInterval) throws -> [String: Any] {
        guard transactionID == transaction else {
            throw IPhoneUseError(
                "stale_text_transaction", "Use the pending pasteboard transaction ID from this session")
        }
        guard observedAt.isFinite, observedAt >= confirmationAfter else {
            throw IPhoneUseError(
                "stale_reference",
                "Inspect a current screenshot captured after this text action before finishing it")
        }
        // close is terminal and cached: an uncertain restorative write is never replayed.
        var result = close()
        result["transactionID"] = transaction
        result["textVerification"] = "caller_confirmed"
        result["automaticReplayAllowed"] = false
        return result
    }

    func checkOwnership() throws {
        guard let owned, !writeUncertain, try pasteboardIO.snapshot() == owned,
            try pasteboardIO.read() == payload, try pasteboardIO.snapshot() == owned
        else {
            throw IPhoneUseError(
                "native_pasteboard_changed", "Clipboard changed before Paste; no shortcut was sent")
        }
    }

    func close() -> [String: Any] {
        if let closed { return closed }
        var result: [String: Any] = [
            "pasteboardRestoreAcknowledged": original == nil, "pasteboardRestoreAtomic": false
        ]
        defer { original = nil; payload = nil; owned = nil; closed = result }
        guard let original else { return result }
        guard !writeUncertain, let owned else {
            result["pasteboardRestoreError"] = "Write ownership is uncertain; no restorative write attempted"
            return result
        }
        do {
            let current = try pasteboardIO.snapshot()
            guard current == owned else {
                result["pasteboardRestoreSkipped"] = "changed_by_another_client"
                return result
            }
            guard try pasteboardIO.read() == payload, try pasteboardIO.snapshot() == owned else {
                result["pasteboardRestoreSkipped"] = "changed_by_another_client"
                return result
            }
            // This protocol exposes no compare-and-set. Do not claim atomic exclusion
            // of a clipboard writer racing this final check and the restore call.
            try pasteboardIO.write(original, cleanup: true)
            let restored = try pasteboardIO.snapshot()
            result["pasteboardRestoreAcknowledged"] =
                try pasteboardIO.read() == original && pasteboardIO.snapshot() == restored
        } catch { result["pasteboardRestoreError"] = String(describing: error) }
        return result
    }
}

final class AppleTextPasteboardIO: NativeTextPasteboard.PasteboardAccess {
    private let transport: NativeTransport
    private let cancellation: NativeCancellation
    init(transport: NativeTransport, cancellation: NativeCancellation) {
        self.transport = transport; self.cancellation = cancellation
    }

    private func pull(policy: String) throws -> [String: Any] {
        try Self.snapshotReply(
            transport.request(
                [
                    "command": "PULL", "pasteboardName": "general",
                    "dataPolicy": [policy: [:]]
                ], timeout: 8), command: "PULL_REPLY")
    }
    static func snapshotReply(_ reply: [String: Any], command: String) throws -> [String: Any] {
        if let error = reply["error"] as? [String: Any],
            error["domain"] as? String == "com.apple.dt.CoreDeviceError", let code = error["code"] as? Int {
            // Only known domain/code pairs get a fixed explanation. Remote userInfo,
            // localized messages and archived errors may include clipboard contents.
            let reason =
                code == 26006
                ? """
                Apple refused clipboard synchronization because its contents are marked transient,\
                 confidential, or already synchronized by another mechanism.
                """
                : "Apple clipboard service rejected the operation; remote error details were omitted."
            throw IPhoneUseError(
                "native_pasteboard_failed", "\(reason) (com.apple.dt.CoreDeviceError \(code))",
                diagnostics: [
                    "applePasteboardError": [
                        "domain": "com.apple.dt.CoreDeviceError", "code": code, "reason": reason
                    ]
                ])
        }
        guard reply["error"] == nil, reply["command"] as? String == command,
            let snapshot = reply["pasteboard"] as? [String: Any],
            let metadata = snapshot["metadata"] as? [String: Any],
            metadata["pasteboardName"] as? String == "general"
        else {
            // Do not interpolate replies: they can contain private clipboard data.
            throw IPhoneUseError(
                "native_pasteboard_failed",
                "Apple clipboard service did not acknowledge the requested operation")
        }
        return snapshot
    }
    func snapshot() throws -> NativeTextPasteboard.Snapshot {
        // Identity checks must not force resolution of every flavor. Full reads
        // below still require all bytes before any backup can be overwritten.
        guard let info = try pull(policy: "allPromised")["metadata"] as? [String: Any],
            let count = info["changeCount"] as? Int, count >= 0,
            let nonce = info["nonce"] as? String, !nonce.isEmpty
        else {
            throw IPhoneUseError("native_pasteboard_unsupported", "Apple clipboard identity is unavailable")
        }
        return .init(changeCount: count, nonce: nonce)
    }
    func read() throws -> [NativeTextPasteboard.Item] { try Self.items(pull(policy: "allResolved")) }

    static func items(_ snapshot: [String: Any]) throws -> [NativeTextPasteboard.Item] {
        guard let items = snapshot["items"] as? [[String: Any]], items.count <= 64 else {
            throw IPhoneUseError("native_pasteboard_unsupported", "Cannot preserve all clipboard items")
        }
        var total = 0
        return try items.map { item in
            guard let types = item["types"] as? [String], !types.isEmpty, types.count <= 64,
                Set(types).count == types.count, let values = item["data"] as? [String: Any],
                Set(values.keys) == Set(types)
            else {
                throw IPhoneUseError(
                    "native_pasteboard_unsupported", "Cannot preserve clipboard flavor metadata")
            }
            var flavors: [String: Data] = [:]
            for type in types {
                guard let value = values[type] as? [String: Any], let data = value["data"] as? Data else {
                    throw IPhoneUseError(
                        "native_pasteboard_unsupported",
                        "Clipboard contains unresolved data; cannot preserve or verify the payload")
                }
                total += data.count
                guard total <= 16 * 1024 * 1024 else {
                    throw IPhoneUseError("native_pasteboard_unsupported", "Clipboard backup exceeds 16 MiB")
                }
                flavors[type] = data
            }
            return .init(flavors: flavors, types: types)
        }
    }
    func write(_ items: [NativeTextPasteboard.Item], cleanup: Bool) throws {
        if !cleanup { try cancellation.check() }
        let values: [[String: Any]] = items.map { item in
            ["types": item.types, "data": item.flavors.mapValues { ["data": $0] }]
        }
        let reply = try transport.request(
            ["command": "SET", "pasteboardName": "general", "items": values], timeout: 8)
        // SET_REPLY describes flavors but may omit their data. Only a subsequent
        // allResolved PULL establishes content/ownership (stage and close do this).
        _ = try Self.snapshotReply(reply, command: "SET_REPLY")
    }
}
