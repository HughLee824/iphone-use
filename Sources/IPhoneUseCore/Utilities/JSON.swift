import Foundation

public func jsonData(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
}

func jsonObject(_ data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw IPhoneUseError("invalid_message", "Expected a JSON object")
    }
    return object
}

func saveJSON(_ object: [String: Any], to url: URL) throws {
    try jsonData(object).write(to: url, options: .atomic)
}
