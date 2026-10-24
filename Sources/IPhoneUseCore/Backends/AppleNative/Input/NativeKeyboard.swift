import Foundation
import CoreFoundation

enum NativePressKey: String, CaseIterable {
    case returnKey = "return", backspace, left, right, upArrow = "up", down, tab
    case shiftTab = "shift-tab", escape

    // USB HID Keyboard/Keypad usage page (0x07). Modifier goes first on wire.
    var usages: [UInt8] {
        switch self {
        case .returnKey: return [0x28]
        case .backspace: return [0x2a]
        case .left: return [0x50]
        case .right: return [0x4f]
        case .upArrow: return [0x52]
        case .down: return [0x51]
        case .tab: return [0x2b]
        case .shiftTab: return [0xe1, 0x2b]
        case .escape: return [0x29]
        }
    }
}

enum NativeKeyboard {
    static let maximumCharacters = 64
    // These are editing requests, not proof of focus, selection or caret position.
    static func editingKeys(mode: String) throws -> [[UInt8]] {
        switch mode {
        case "insert": return []
        case "replace": return [[0xe3, 0x04]] // Command-A: select all in the focused editor.
        case "append": return [[0xe3, 0x51]] // Command-Down: end of document, not end of line.
        default: throw IPhoneUseError("invalid_input_mode", "Choose insert, replace or append")
        }
    }
    static func keys(for text: String, mode: String) throws -> [[UInt8]] {
        guard mode == "insert" else {
            throw IPhoneUseError(
                "native_text_unsupported", "Native typing supports insert only; replace is not implemented")
        }
        guard !text.isEmpty, text.utf8.count <= maximumCharacters else {
            throw IPhoneUseError(
                "native_text_unsupported", "Native typing accepts 1...64 printable ASCII characters")
        }
        let plain = Array("1234567890-=[]\\;'`,./".utf8)
        let shifted = Array("!@#$%^&*()_+{}|:\"~<>?".utf8)
        let usages: [UInt8] =
            Array(0x1e...0x27) + [0x2d, 0x2e, 0x2f, 0x30, 0x31, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38]
        return try text.utf8.map { byte in
            if (97...122).contains(byte) { return [byte - 97 + 4] }
            if (65...90).contains(byte) { return [0xe1, byte - 65 + 4] }
            if byte == 32 { return [0x2c] }
            if let index = plain.firstIndex(of: byte) { return [usages[index]] }
            if let index = shifted.firstIndex(of: byte) { return [0xe1, usages[index]] }
            throw IPhoneUseError(
                "native_text_unsupported",
                """
                Native typing accepts printable ASCII only, interpreted by the device's current keyboard\
                 layout; no layout switching
                """
            )
        }
    }
    static func report(_ keys: [UInt8], timestamp: UInt64) -> Data {
        var bytes = [UInt8](repeating: 0, count: 39)
        bytes[0] = 1
        for key in keys where key < 240 { bytes[1 + Int(key) / 8] |= 1 << (key % 8) }
        for index in 0..<6 { bytes[31 + index] = UInt8(truncatingIfNeeded: timestamp >> (8 * index)) }
        return Data(bytes)
    }
    static func builtInService(in services: [[String: Any]]) throws -> UInt64 {
        func identifier(_ value: Any?) -> UInt64? {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                let id = UInt64(number.stringValue), id > 0
            else { return nil }
            return id
        }
        let matches = services.filter { service in
            guard service["DeviceTypeHint"] as? String == "Keyboard",
                service["Product"] as? String == "CoreDevice keyboard",
                (service["PrimaryUsagePage"] as? NSNumber)?.intValue == 0,
                (service["PrimaryUsage"] as? NSNumber)?.intValue == 0,
                let storage = service["_CoreDevice_codablePropertyStorage"] as? [String: Any],
                (storage["Transport"] as? [String: String])?["string"] == "CoreDevice",
                let usages = (storage["_CoreDevice_originalUsages"] as? [String: Any])?["array"]
                    as? [[String: Any]]
            else { return false }
            return usages.contains { usage in
                guard let pair = usage["dictionary"] as? [String: Any] else { return false }
                return (pair["DeviceUsagePage"] as? [String: Int])?["int"] == 1
                    && (pair["DeviceUsage"] as? [String: Int])?["int"] == 6
            }
        }
        guard matches.count == 1, let id = identifier(matches[0]["_ServiceID"]),
            services.filter({ identifier($0["_ServiceID"]) == id }).count == 1
        else {
            throw IPhoneUseError(
                "native_keyboard_unavailable",
                "No unique built-in CoreDevice keyboard; no hardware keyboard will be registered")
        }
        return id
    }
}
