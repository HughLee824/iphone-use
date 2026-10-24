import Foundation

// Shared by the host and Runner. Append uses a validated readable value rather
// than assuming a keyboard shortcut moved the caret. Never reconstruct secrets.
public enum RunnerTextInput {
    public enum Failure: String, Error {
        case valueUnavailable = "append_value_unavailable"
        case invalidResult = "append_result_unsupported"
        case clearValueUnavailable = "replace_value_unavailable"

        public var message: String {
            switch self {
            case .valueUnavailable:
                return "Runner append requires readable non-secure text, distinct from any placeholder"
            case .invalidResult:
                return "Appended result must fit 4096 UTF-8 bytes and contain no unsupported control keys"
            case .clearValueUnavailable:
                return
                    """
                    Runner replace requires readable non-secure text of at most 4096 UTF-8 bytes, distinct\
                     from any placeholder
                    """
            }
        }
    }

    public static func replacementInput(
        _ text: String, value: Any?, secure: Bool, placeholder: String?, deleteKey: String
    )
        throws -> String {
        guard !secure, let source = value as? String, source.utf8.count <= 4096,
            source.isEmpty || placeholder.map({ $0.isEmpty || $0 != source }) ?? true
        else {
            throw Failure.clearValueUnavailable
        }
        // The caller first moves to the document end using XCTest editing keys.
        // Only backward Delete is supported by iOS typeText; Forward Delete's
        // raw value is inserted as a character. UTF-16 bounds deletion even for
        // combining marks and emoji. Never repeat input after a failure.
        return String(repeating: deleteKey, count: source.utf16.count) + text
    }

    // UIKit text views omit AX value after the last character is removed.
    // Only use this after a validated readable field has been cleared.
    public static func isCleared(_ value: Any?) -> Bool {
        value == nil || (value as? String)?.isEmpty == true
    }

    public static func append(_ text: String, to value: Any?, secure: Bool, placeholder: String? = nil) throws
        -> String {
        guard !secure, let source = value as? String,
            placeholder.map({ $0.isEmpty || $0 != source }) ?? true
        else { throw Failure.valueUnavailable }
        // Preserve Unicode bytes, whitespace and line endings. Validate the whole
        // replacement before any focus/delete/input operation can run.
        let result = source + text
        guard result.utf8.count <= 4096,
            result.unicodeScalars.allSatisfy({ scalar in
                let scalarValue = scalar.value
                return scalarValue == 10
                    || (scalarValue >= 32 && scalarValue != 127 && scalarValue != 133 && scalarValue != 0x2028
                        && scalarValue != 0x2029 && !(0xF700...0xF8FF).contains(scalarValue))
            })
        else { throw Failure.invalidResult }
        return result
    }
}

// Public command names shared by host validation and Runner execution. The
// XCTest key constants themselves stay in the iPhone target.
public enum RunnerPressKey: String, CaseIterable {
    case `return`, backspace, left, right, upArrow = "up", down, tab, shiftTab = "shift-tab"
    public var modifiers: [String] { self == .shiftTab ? ["shift"] : [] }
}
