import Foundation

// Keep the payload available until the next explicit text action or session close:
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
    protocol IO: AnyObject {
        func snapshot() throws -> Snapshot
        func read() throws -> [Item]
        func write(_ items: [Item], cleanup: Bool) throws
    }
    private let io: IO
    private var original: [Item]?
    private var payload: [Item]?
    private var owned: Snapshot?
    private var writeUncertain = false
    private var closed: [String: Any]?

    init(io: IO) { self.io = io }
    var available: Bool { closed == nil && !writeUncertain }

    var status: [String: Any] {
        ["method": "apple-pasteboard-hid-paste", "restorePending": original != nil,
         "writeUncertain": writeUncertain, "ownershipConfirmed": owned != nil,
         "atomicRestore": false]
    }

    func stage(_ text: String) throws {
        guard closed == nil, !writeUncertain else {
            throw SomaError("native_pasteboard_uncertain", "Close this session and inspect the device clipboard before another text action")
        }
        let data = Data(text.utf8)
        let next = [Item(flavors: ["public.utf8-plain-text": data, "public.plain-text": data, "public.text": data])]
        let before = try io.snapshot()
        let current = try io.read()
        guard try io.snapshot() == before else {
            throw SomaError("native_pasteboard_changed", "Clipboard changed while being read; no write or paste was sent")
        }
        if let owned {
            guard before == owned, current == payload else {
                throw SomaError("native_pasteboard_changed", "Another client changed the clipboard; close this session without restoring over their content")
            }
            if current == next { return }
        } else {
            original = current
        }
        // Mark before submission: a failed service reply may follow a device-side write.
        writeUncertain = true; owned = nil; payload = next
        try io.write(next, cleanup: false)
        let after = try io.snapshot()
        guard after.nonce == before.nonce, after.changeCount > before.changeCount,
              try io.read() == next, try io.snapshot() == after else {
            throw SomaError("native_pasteboard_uncertain", "Cannot confirm clipboard write ownership; no paste shortcut was sent")
        }
        owned = after; writeUncertain = false
    }

    func checkOwnership() throws {
        guard let owned, !writeUncertain, try io.snapshot() == owned,
              try io.read() == payload, try io.snapshot() == owned else {
            throw SomaError("native_pasteboard_changed", "Clipboard changed before Paste; no shortcut was sent")
        }
    }

    func close() -> [String: Any] {
        if let closed { return closed }
        var result: [String: Any] = ["pasteboardRestoreAcknowledged": original == nil, "pasteboardRestoreAtomic": false]
        defer { original = nil; payload = nil; owned = nil; closed = result }
        guard let original else { return result }
        guard !writeUncertain, let owned else {
            result["pasteboardRestoreError"] = "Write ownership is uncertain; no restorative write attempted"
            return result
        }
        do {
            let current = try io.snapshot()
            guard current == owned else {
                result["pasteboardRestoreSkipped"] = "changed_by_another_client"
                return result
            }
            guard try io.read() == payload, try io.snapshot() == owned else {
                result["pasteboardRestoreSkipped"] = "changed_by_another_client"
                return result
            }
            // This protocol exposes no compare-and-set. Do not claim atomic exclusion
            // of a clipboard writer racing this final check and the restore call.
            try io.write(original, cleanup: true)
            let restored = try io.snapshot()
            result["pasteboardRestoreAcknowledged"] = try io.read() == original && io.snapshot() == restored
        } catch { result["pasteboardRestoreError"] = String(describing: error) }
        return result
    }
}

final class AppleTextPasteboardIO: NativeTextPasteboard.IO {
    private let transport: NativeTransport
    private let cancellation: NativeCancellation
    init(transport: NativeTransport, cancellation: NativeCancellation) {
        self.transport = transport; self.cancellation = cancellation
    }

    private func pull() throws -> [String: Any] {
        try Self.snapshotReply(transport.request(["command": "PULL", "pasteboardName": "general",
            "dataPolicy": ["allResolved": [:]]], timeout: 8), command: "PULL_REPLY")
    }
    static func snapshotReply(_ reply: [String: Any], command: String) throws -> [String: Any] {
        guard reply["error"] == nil, reply["command"] as? String == command,
              let snapshot = reply["pasteboard"] as? [String: Any],
              let metadata = snapshot["metadata"] as? [String: Any],
              metadata["pasteboardName"] as? String == "general" else {
            // Do not interpolate replies: they can contain private clipboard data.
            throw SomaError("native_pasteboard_failed", "Apple clipboard service did not acknowledge the requested operation")
        }
        return snapshot
    }
    func snapshot() throws -> NativeTextPasteboard.Snapshot {
        let info = try pull()["metadata"] as! [String: Any]
        guard let count = info["changeCount"] as? Int, count >= 0,
              let nonce = info["nonce"] as? String, !nonce.isEmpty else {
            throw SomaError("native_pasteboard_unsupported", "Apple clipboard identity is unavailable")
        }
        return .init(changeCount: count, nonce: nonce)
    }
    func read() throws -> [NativeTextPasteboard.Item] { try Self.items(pull()) }

    static func items(_ snapshot: [String: Any]) throws -> [NativeTextPasteboard.Item] {
        guard let items = snapshot["items"] as? [[String: Any]], items.count <= 64 else {
            throw SomaError("native_pasteboard_unsupported", "Cannot preserve all clipboard items")
        }
        var total = 0
        return try items.map { item in
            guard let types = item["types"] as? [String], !types.isEmpty, types.count <= 64,
                  Set(types).count == types.count, let values = item["data"] as? [String: Any],
                  Set(values.keys) == Set(types) else {
                throw SomaError("native_pasteboard_unsupported", "Cannot preserve clipboard flavor metadata")
            }
            var flavors: [String: Data] = [:]
            for type in types {
                guard let value = values[type] as? [String: Any], let data = value["data"] as? Data else {
                    throw SomaError("native_pasteboard_unsupported", "Clipboard contains unresolved data; cannot preserve or verify the payload")
                }
                total += data.count
                guard total <= 16 * 1024 * 1024 else { throw SomaError("native_pasteboard_unsupported", "Clipboard backup exceeds 16 MiB") }
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
        let reply = try transport.request(["command": "SET", "pasteboardName": "general", "items": values], timeout: 8)
        // SET_REPLY describes flavors but may omit their data. Only a subsequent
        // allResolved PULL establishes content/ownership (stage and close do this).
        _ = try Self.snapshotReply(reply, command: "SET_REPLY")
    }
}
