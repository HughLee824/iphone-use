import Foundation

enum NativeKeyboard {
    static let maximumCharacters = 64
    // These are editing requests, not proof of focus, selection or caret position.
    static func editingKeys(mode: String) throws -> [[UInt8]] {
        switch mode {
        case "insert": return []
        case "replace": return [[0xe3, 0x04]] // Command-A: select all in the focused editor.
        case "append": return [[0xe3, 0x51]] // Command-Down: end of document, not end of line.
        default: throw SomaError("invalid_input_mode", "Choose insert, replace or append")
        }
    }
    static func keys(for text: String, mode: String) throws -> [[UInt8]] {
        guard mode == "insert" else { throw SomaError("native_text_unsupported", "Native typing supports insert only; replace is not implemented") }
        guard !text.isEmpty, text.utf8.count <= maximumCharacters else { throw SomaError("native_text_unsupported", "Native typing accepts 1...64 printable ASCII characters") }
        let plain = Array("1234567890-=[]\\;'`,./".utf8)
        let shifted = Array("!@#$%^&*()_+{}|:\"~<>?".utf8)
        let usages: [UInt8] = Array(0x1e...0x27) + [0x2d, 0x2e, 0x2f, 0x30, 0x31, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38]
        return try text.utf8.map { byte in
            if (97...122).contains(byte) { return [byte - 97 + 4] }
            if (65...90).contains(byte) { return [0xe1, byte - 65 + 4] }
            if byte == 32 { return [0x2c] }
            if let index = plain.firstIndex(of: byte) { return [usages[index]] }
            if let index = shifted.firstIndex(of: byte) { return [0xe1, usages[index]] }
            throw SomaError("native_text_unsupported", "Native typing accepts printable ASCII only, interpreted by the device's current keyboard layout; no layout switching")
        }
    }
    static func report(_ keys: [UInt8], timestamp: UInt64) -> Data {
        var bytes = [UInt8](repeating: 0, count: 39)
        bytes[0] = 1
        for key in keys where key < 240 { bytes[1 + Int(key) / 8] |= 1 << (key % 8) }
        for index in 0..<6 { bytes[31 + index] = UInt8(truncatingIfNeeded: timestamp >> (8 * index)) }
        return Data(bytes)
    }
    // Standard keyboard descriptor: modifiers, reserved byte, six usage slots.
    // Remote UniversalHID's 39-byte usage-set envelope is separate from this descriptor.
    static let descriptor = Data([
        0x05,0x01, 0x09,0x06, 0xa1,0x01,
        0x05,0x07, 0x19,0xe0, 0x29,0xe7, 0x15,0x00, 0x25,0x01, 0x75,0x01, 0x95,0x08, 0x81,0x02,
        0x75,0x08, 0x95,0x01, 0x81,0x01,
        0x19,0x00, 0x2a,0xff,0x00, 0x15,0x00, 0x26,0xff,0x00, 0x75,0x08, 0x95,0x06, 0x81,0x00, 0xc0
    ])
    static func properties(id: UInt64, product: String) -> [String: Any] {
        let pair: [String: Any] = ["DeviceUsagePage": 1, "DeviceUsage": 6]
        let storage: [String: Any] = [
            "Manufacturer": ["string": "AgentSoma"], "Product": ["string": product],
            "VendorID": ["int": 0], "ProductID": ["int": 0],
            "PrimaryUsagePage": ["int": 1], "PrimaryUsage": ["int": 6],
            "DeviceUsagePairs": ["array": [["dictionary": ["DeviceUsagePage": ["int": 1], "DeviceUsage": ["int": 6]]]]],
            "Transport": ["string": "Virtual"], "ReportDescriptor": ["data": descriptor],
            "UniversalControlVirtualService": ["bool": true], "_ServiceID": ["uint": nativeUInt(id)]
        ]
        return ["PrimaryUsagePage": nativeUInt(1), "PrimaryUsage": nativeUInt(6), "DeviceUsagePairs": [pair],
                "VendorID": 0, "ProductID": 0, "Product": product, "_ServiceID": nativeUInt(id),
                "_CoreDevice_codablePropertyStorage": storage]
    }
}
