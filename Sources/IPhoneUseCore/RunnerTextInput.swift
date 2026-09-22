import Foundation

// Shared by the host and Runner. Append uses a validated readable value rather
// than assuming a keyboard shortcut moved the caret. Never reconstruct secrets.
enum RunnerTextInput {
    enum Failure: String, Error {
        case valueUnavailable = "append_value_unavailable"
        case invalidResult = "append_result_unsupported"

        var message: String {
            switch self {
            case .valueUnavailable: return "Runner append requires readable non-secure text, distinct from any placeholder"
            case .invalidResult: return "Appended result must fit 4096 UTF-8 bytes and contain no unsupported control keys"
            }
        }
    }

    static func append(_ text: String, to value: Any?, secure: Bool, placeholder: String? = nil) throws -> String {
        guard !secure, let source = value as? String,
              placeholder.map({ $0.isEmpty || $0 != source }) ?? true else { throw Failure.valueUnavailable }
        // Preserve Unicode bytes, whitespace and line endings. Validate the whole
        // replacement before any focus/select-all/input operation can run.
        let result = source + text
        guard result.utf8.count <= 4096, result.unicodeScalars.allSatisfy({ scalar in
            let v = scalar.value
            return v == 10 || (v >= 32 && v != 127 && v != 133 && v != 0x2028 && v != 0x2029 && !(0xF700...0xF8FF).contains(v))
        }) else { throw Failure.invalidResult }
        return result
    }
}

// Public command names shared by host validation and Runner execution. The
// XCTest key constants themselves stay in the iPhone target.
enum RunnerPressKey: String, CaseIterable {
    case `return`, backspace, left, right, up, down, tab, shiftTab = "shift-tab"
    var modifiers: [String] { self == .shiftTab ? ["shift"] : [] }
}
