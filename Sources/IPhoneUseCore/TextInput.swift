import Foundation

public enum TextInput {
    static let maximumBytes = 4096

    public static func read(from input: FileHandle) throws -> String {
        var data = Data()
        // Read one byte beyond the limit so oversized streams fail without waiting for EOF.
        while let chunk = try input.read(upToCount: maximumBytes + 1 - data.count), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximumBytes else { throw IPhoneUseError("invalid_text", "Text exceeds 4096 UTF-8 bytes") }
        }
        guard let text = String(data: data, encoding: .utf8) else { throw IPhoneUseError("invalid_text", "stdin must contain valid UTF-8 text") }
        return text
    }
}
