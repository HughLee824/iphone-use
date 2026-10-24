import IPhoneUseRunnerSupport
import Foundation

extension ActionRequest {
    func textFields(reference: ObservationReference, touchPaste: Bool, fields: inout [String: Any]) throws {
        if operation == "type" {
            let modes = ["insert", "replace", "append"]
            guard let mode = request["mode"] as? String, modes.contains(mode) else {
                throw IPhoneUseError("invalid_input_mode", "Choose --mode insert, replace or append")
            }
            let allowNewlines =
                touchPaste || !allowScreenText
                || (reference.node == nil && request["textMethod"] as? String != "keys")
            guard let text = request["text"] as? String, text.utf8.count <= TextInput.maximumBytes,
                mode == "replace" || !text.isEmpty,
                text.unicodeScalars.allSatisfy({ scalar in
                    let value = scalar.value
                    if allowNewlines && (value == 10 || ((allowScreenText || touchPaste) && value == 13)) {
                        return true
                    }
                    return value >= 32 && value != 127 && value != 133 && value != 0x2028 && value != 0x2029
                        && !(0xF700...0xF8FF).contains(value)
                })
            else {
                throw IPhoneUseError(
                    "invalid_text",
                    """
                    Use up to 4096 UTF-8 bytes without control keys; LF requires a Runner text_view or\
                     clipboard method; CR/CRLF require native auto/paste or touch-paste, and only replace\
                     accepts empty text
                    """
                )
            }
            fields["mode"] = mode; fields["text"] = text
            fields["textMethod"] = request["textMethod"]
        }
    }

    func pressFields(reference: ObservationReference, fields: inout [String: Any]) throws {
        if operation == "press" {
            if !allowScreenText, request["key"] as? String == "escape" {
                throw IPhoneUseError(
                    "unsupported_key", "Runner Escape has not passed device validation; no input was sent")
            }
            let supported =
                allowScreenText
                ? (reference.node == nil ? NativePressKey.allCases.map(\.rawValue) : ["return"])
                : RunnerPressKey.allCases.map(\.rawValue)
            guard let key = request["key"] as? String, supported.contains(key) else {
                throw IPhoneUseError("invalid_key", "Use --key " + supported.joined(separator: ", "))
            }
            fields["key"] = key
        }
    }

    func textRegion(reference: ObservationReference) throws -> ScreenRect? {
        if let raw = request["fieldRect"] {
            guard allowScreenText, ["type", "press"].contains(operation), reference.node == nil,
                let value = raw as? String
            else {
                throw IPhoneUseError(
                    "invalid_text_region", "--field-rect applies only to native type or press oN")
            }
            let parts = value.split(separator: ",", omittingEmptySubsequences: false)
            let numbers = parts.compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 4, numbers.count == 4, numbers.allSatisfy(\.isFinite) else {
                throw IPhoneUseError(
                    "invalid_text_region", "Use --field-rect x,y,width,height in screenshot screen points")
            }
            let rect = ScreenRect(CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]))
            guard numbers[2] > 0, numbers[3] > 0, rect.valid else {
                throw IPhoneUseError("invalid_text_region", "Text field width and height must be positive")
            }
            return rect
        } else {
            return nil
        }
    }

    func caretRegion(reference: ObservationReference, textRegion: ScreenRect?) throws -> ScreenRect? {
        if let raw = request["caretRect"] {
            guard allowScreenText, ["type", "press"].contains(operation), reference.node == nil,
                let field = textRegion, let value = raw as? String
            else {
                throw IPhoneUseError(
                    "invalid_caret_region", "--caret-rect requires native type/press oN with --field-rect")
            }
            let parts = value.split(separator: ",", omittingEmptySubsequences: false)
            let coordinates = parts.compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 4, coordinates.count == 4, coordinates.allSatisfy(\.isFinite),
                coordinates[2] > 0,
                coordinates[2] <= 4,
                (8...80).contains(coordinates[3]), coordinates[3] >= coordinates[2] * 3
            else {
                throw IPhoneUseError(
                    "invalid_caret_region",
                    "Use one narrow caret x,y,width,height (width <=4, height 8...80 screen points)")
            }
            let rect = ScreenRect(
                CGRect(x: coordinates[0], y: coordinates[1], width: coordinates[2], height: coordinates[3]))
            guard rect.valid, field.cgRect.contains(rect.cgRect) else {
                throw IPhoneUseError("invalid_caret_region", "Caret must be inside the complete input field")
            }
            return rect
        } else {
            return nil
        }
    }

    func ignoredRegion(reference: ObservationReference, coordinate: Bool, textRegion: ScreenRect?) throws
        -> ScreenRect? {
        if let raw = request["ignoreRect"] {
            let gesture =
                coordinate && ["tap", "double-tap", "long-press", "pinch", "swipe"].contains(operation)
            let nativeText =
                allowScreenText && reference.node == nil && ["type", "press"].contains(operation)
                && textRegion != nil
            guard gesture || nativeText, let value = raw as? String else {
                throw IPhoneUseError(
                    "invalid_ignored_region",
                    "--ignore-rect requires a screenshot coordinate gesture or native type/press with --field-rect"
                )
            }
            let parts = value.split(separator: ",", omittingEmptySubsequences: false)
            let values = parts.compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 4, values.count == 4, values.allSatisfy(\.isFinite), values[2] > 0,
                values[3] > 0
            else {
                throw IPhoneUseError(
                    "invalid_ignored_region", "Use --ignore-rect x,y,width,height in screenshot screen points"
                )
            }
            return ScreenRect(CGRect(x: values[0], y: values[1], width: values[2], height: values[3]))
        } else {
            return nil
        }
    }
}
