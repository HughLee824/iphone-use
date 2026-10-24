import Foundation

public struct IPhoneUseError: Error, CustomStringConvertible {
    public let code: String
    public let description: String
    public let diagnostics: [String: Any]

    public init(_ code: String, _ description: String, diagnostics: [String: Any] = [:]) {
        self.code = code
        self.description = description
        self.diagnostics = diagnostics
    }
}
