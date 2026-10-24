import Foundation

// Only used while producing a NEW observation, never to replace an action's source.
struct NativeTextObservationOptions: Codable {
    let field: ScreenRect
    let ignoring: ScreenRect?

    init(field: ScreenRect, ignoring: ScreenRect?) { self.field = field; self.ignoring = ignoring }
    init(request: [String: Any]) throws {
        func rect(_ value: Any?, code: String) throws -> ScreenRect {
            guard let value = value as? String else {
                throw IPhoneUseError(code, "Use x,y,width,height in screen points")
            }
            let parts = value.split(separator: ",", omittingEmptySubsequences: false)
            let values = parts.compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 4, values.count == 4, values.allSatisfy(\.isFinite), values[2] > 0,
                values[3] > 0
            else {
                throw IPhoneUseError(code, "Use a finite positive rectangle x,y,width,height")
            }
            let result = ScreenRect(CGRect(x: values[0], y: values[1], width: values[2], height: values[3]))
            guard result.valid else { throw IPhoneUseError(code, "Invalid rectangle") }
            return result
        }
        field = try rect(request["fieldRect"], code: "invalid_text_region")
        ignoring = try request["ignoreRect"].map { try rect($0, code: "invalid_ignored_region") }
    }
    var result: [String: Any] { get throws { try jsonObject(JSONEncoder().encode(self)) } }
}
