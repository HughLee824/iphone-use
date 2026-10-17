import Foundation
import CoreFoundation

struct DeviceAction {
    static let operations = ["tap", "double-tap", "long-press", "pinch", "swipe", "home", "type", "press"]
    let kind: String
    var touchPaste: Bool { kind == "type" && fields["textMethod"] as? String == "touch-paste" }
    let reference: ObservationReference
    let fields: [String: Any]
    let coordinate: Bool
    let guardPolicy: ScreenGuard.Policy
    let protectedReferences: [ObservationReference]
    let swipeMotion: SwipeMotion?
    let textRegion: ScreenRect?
    let caretRegion: ScreenRect?
    let pinchMotion: PinchMotion?
    let ignoredScreenRect: ScreenRect?
    let dynamicRects: [ScreenRect]?

    init(operation: String, request: [String: Any], allowScreenText: Bool = false) throws {
        guard Self.operations.contains(operation) else { throw IPhoneUseError("invalid_action", "Unknown device action") }
        kind = operation
        if let method = request["textMethod"] {
            guard operation == "type", let method = method as? String,
                  method == "touch-paste" || (allowScreenText && ["auto", "keys", "paste"].contains(method)) else {
                throw IPhoneUseError("invalid_text_method", "Use --method touch-paste in either mode, or auto, keys, paste in standard mode")
            }
        }
        let touchPaste = request["textMethod"] as? String == "touch-paste"
        if touchPaste {
            guard request["mode"] as? String == "insert",
                  ["fieldRect", "caretRect", "ignoreRect"].allSatisfy({ request[$0] == nil }) else {
                throw IPhoneUseError("invalid_touch_paste", "touch-paste only stages text: use --mode insert without field/caret/ignore rectangles; select the destination through subsequent touch actions")
            }
        }
        reference = try ObservationReference(request["reference"] as? String ?? "")
        if touchPaste, reference.node != nil {
            throw IPhoneUseError("invalid_reference", "touch-paste requires the current screenshot oN in either mode; it does not focus an element")
        }
        let coordinateKeys = ["x", "y", "fromX", "fromY", "toX", "toY"]
        coordinate = coordinateKeys.contains { request[$0] != nil }
        var fields: [String: Any] = ["kind": operation]
        if coordinate {
            let required = ["tap", "double-tap", "long-press", "pinch"].contains(operation) ? ["x", "y"] : (operation == "swipe" ? ["fromX", "fromY", "toX", "toY"] : [])
            if !required.isEmpty, let node = reference.node {
                let element = "\(reference.observation):e\(node + 1)"
                let coordinates = ["tap", "double-tap", "long-press", "pinch"].contains(operation) ? "--x X --y Y" : "--from-x X --from-y Y --to-x X --to-y Y"
                throw IPhoneUseError("invalid_coordinates", "Element reference \(element) cannot be combined with coordinates. Use \(operation) \(reference.observation) \(coordinates); optionally add --protect \(element) to protect the captured element")
            }
            guard !required.isEmpty,
                  coordinateKeys.filter({ request[$0] != nil }).count == required.count else {
                throw IPhoneUseError("invalid_coordinates", "Use tap oN --x --y, or swipe oN --from-x --from-y --to-x --to-y")
            }
            for key in required {
                guard let value = Self.number(request[key]) else { throw IPhoneUseError("invalid_coordinates", "Supply every coordinate as a finite number of screen points") }
                fields[key] = value
            }
        } else if reference.node == nil && !(operation == "home" || touchPaste || (allowScreenText && ["type", "press"].contains(operation))) {
            throw IPhoneUseError("element_required", "Use an element reference such as o1:e2")
        }
        if operation == "swipe", coordinate {
            guard request["direction"] == nil else { throw IPhoneUseError("invalid_direction", "Coordinate swipes use endpoints, not --direction") }
        } else if operation == "swipe" {
            guard let direction = request["direction"] as? String, ["up", "down", "left", "right"].contains(direction) else {
                throw IPhoneUseError("invalid_direction", "Direction must be up, down, left or right")
            }
            fields["direction"] = direction
        }
        if operation == "swipe" {
            func control(_ key: String, fallback: Double) throws -> Double {
                guard let raw = request[key] else { return fallback }
                guard let value = Self.number(raw) else { throw IPhoneUseError("invalid_swipe_motion", "Swipe motion controls must be finite numbers") }
                return value
            }
            let defaults = SwipeMotion()
            let motion = try SwipeMotion(velocity: control("velocity", fallback: defaults.velocity),
                pressDuration: control("pressDuration", fallback: defaults.pressDuration),
                holdDuration: control("holdDuration", fallback: defaults.holdDuration))
            guard motion.valid else {
                throw IPhoneUseError("invalid_swipe_motion", "Require 0 < velocity <= 10000 and press/hold durations in 0...5 seconds")
            }
            swipeMotion = motion
        } else {
            guard ["velocity", "pressDuration", "holdDuration"].allSatisfy({ request[$0] == nil }) else {
                throw IPhoneUseError("invalid_swipe_motion", "Motion controls apply only to swipe")
            }
            swipeMotion = nil
        }
        if operation == "home", reference.node != nil {
            throw IPhoneUseError("invalid_reference", "Home requires the current screenshot oN")
        }
        if operation == "double-tap", !coordinate {
            throw IPhoneUseError("invalid_coordinates", "Double tap requires a screenshot reference and --x --y")
        }
        if operation == "long-press" {
            guard coordinate, let duration = Self.number(request["duration"] ?? 0.8), (0.5...5).contains(duration) else {
                throw IPhoneUseError("invalid_press_duration", "Long press requires coordinates and duration in 0.5...5 seconds")
            }
            fields["duration"] = duration
        } else if operation != "pinch", request["duration"] != nil {
            throw IPhoneUseError("invalid_press_duration", "--duration applies only to long-press or pinch")
        }
        if operation == "pinch" {
            guard coordinate, request["direction"] == nil,
                  let from = Self.number(request["fromDistance"]), let to = Self.number(request["toDistance"]),
                  let duration = Self.number(request["duration"] ?? 0.5) else {
                throw IPhoneUseError("invalid_pinch_motion", "Pinch requires --x --y --from-distance --to-distance and optional --duration")
            }
            let motion = PinchMotion(fromDistance: from, toDistance: to, duration: duration)
            guard motion.valid else {
                throw IPhoneUseError("invalid_pinch_motion", "Pinch separations must be >=20 points and differ by >=1; duration must be 0.1...5 seconds")
            }
            pinchMotion = motion
        } else {
            guard request["fromDistance"] == nil, request["toDistance"] == nil else {
                throw IPhoneUseError("invalid_pinch_motion", "Distance controls apply only to pinch")
            }
            pinchMotion = nil
        }
        if operation == "type" {
            let modes = ["insert", "replace", "append"]
            guard let mode = request["mode"] as? String, modes.contains(mode) else {
                throw IPhoneUseError("invalid_input_mode", "Choose --mode insert, replace or append")
            }
            let allowNewlines = touchPaste || !allowScreenText || (reference.node == nil && request["textMethod"] as? String != "keys")
            guard let text = request["text"] as? String, text.utf8.count <= TextInput.maximumBytes,
                  mode == "replace" || !text.isEmpty,
                  text.unicodeScalars.allSatisfy({ scalar in
                      let v = scalar.value
                      if allowNewlines && (v == 10 || ((allowScreenText || touchPaste) && v == 13)) { return true }
                      return v >= 32 && v != 127 && v != 133 && v != 0x2028 && v != 0x2029 && !(0xF700...0xF8FF).contains(v)
                  }) else {
                throw IPhoneUseError("invalid_text", "Use up to 4096 UTF-8 bytes without control keys; LF requires a Runner text_view or clipboard method; CR/CRLF require native auto/paste or touch-paste, and only replace accepts empty text")
            }
            fields["mode"] = mode; fields["text"] = text
            fields["textMethod"] = request["textMethod"]
        }
        if operation == "press" {
            if !allowScreenText, request["key"] as? String == "escape" {
                throw IPhoneUseError("unsupported_key", "Runner Escape has not passed device validation; no input was sent")
            }
            let supported = allowScreenText
                ? (reference.node == nil ? NativePressKey.allCases.map(\.rawValue) : ["return"])
                : RunnerPressKey.allCases.map(\.rawValue)
            guard let key = request["key"] as? String, supported.contains(key) else {
                throw IPhoneUseError("invalid_key", "Use --key " + supported.joined(separator: ", "))
            }
            fields["key"] = key
        }
        if let raw = request["fieldRect"] {
            guard allowScreenText, ["type", "press"].contains(operation), reference.node == nil,
                  let value = raw as? String else {
                throw IPhoneUseError("invalid_text_region", "--field-rect applies only to native type or press oN")
            }
            let parts = value.split(separator: ",", omittingEmptySubsequences: false)
            let numbers = parts.compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 4, numbers.count == 4, numbers.allSatisfy(\.isFinite) else {
                throw IPhoneUseError("invalid_text_region", "Use --field-rect x,y,width,height in screenshot screen points")
            }
            let rect = ScreenRect(CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]))
            guard numbers[2] > 0, numbers[3] > 0, rect.valid else {
                throw IPhoneUseError("invalid_text_region", "Text field width and height must be positive")
            }
            textRegion = rect
        } else { textRegion = nil }
        if let raw = request["caretRect"] {
            guard allowScreenText, ["type", "press"].contains(operation), reference.node == nil,
                  let field = textRegion, let value = raw as? String else {
                throw IPhoneUseError("invalid_caret_region", "--caret-rect requires native type/press oN with --field-rect")
            }
            let parts = value.split(separator: ",", omittingEmptySubsequences: false)
            let v = parts.compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 4, v.count == 4, v.allSatisfy(\.isFinite), v[2] > 0, v[2] <= 4,
                  (8...80).contains(v[3]), v[3] >= v[2] * 3 else {
                throw IPhoneUseError("invalid_caret_region", "Use one narrow caret x,y,width,height (width <=4, height 8...80 screen points)")
            }
            let rect = ScreenRect(CGRect(x: v[0], y: v[1], width: v[2], height: v[3]))
            guard rect.valid, field.cgRect.contains(rect.cgRect) else {
                throw IPhoneUseError("invalid_caret_region", "Caret must be inside the complete input field")
            }
            caretRegion = rect
        } else { caretRegion = nil }
        if let raw = request["ignoreRect"] {
            let gesture = coordinate && ["tap", "double-tap", "long-press", "pinch", "swipe"].contains(operation)
            let nativeText = allowScreenText && reference.node == nil && ["type", "press"].contains(operation) && textRegion != nil
            guard gesture || nativeText, let value = raw as? String else {
                throw IPhoneUseError("invalid_ignored_region", "--ignore-rect requires a screenshot coordinate gesture or native type/press with --field-rect")
            }
            let parts = value.split(separator: ",", omittingEmptySubsequences: false)
            let values = parts.compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 4, values.count == 4, values.allSatisfy(\.isFinite), values[2] > 0, values[3] > 0 else {
                throw IPhoneUseError("invalid_ignored_region", "Use --ignore-rect x,y,width,height in screenshot screen points")
            }
            ignoredScreenRect = ScreenRect(CGRect(x: values[0], y: values[1], width: values[2], height: values[3]))
        } else { ignoredScreenRect = nil }
        var policy = ScreenGuard.Policy()
        var protected: [ObservationReference] = []
        if ["tap", "double-tap", "long-press", "pinch", "swipe"].contains(operation) {
            if request["maxScreenChange"] != nil {
                guard let value = Self.number(request["maxScreenChange"]) else { throw IPhoneUseError("invalid_screen_guard_policy", "Screen change limit must be finite") }
                policy.maxScreenChange = value
            }
            if request["maxRegionChange"] != nil {
                guard let value = Self.number(request["maxRegionChange"]) else { throw IPhoneUseError("invalid_screen_guard_policy", "Region change limit must be finite") }
                policy.maxRegionChange = value
            }
            guard policy.valid else { throw IPhoneUseError("invalid_screen_guard_policy", "Require 0 <= max-region-change <= max-screen-change <= 1") }
            if let value = request["protect"] {
                guard let refs = value as? [String], refs.count <= 3 else { throw IPhoneUseError("invalid_protected_regions", "Protect up to three element references from the same observation") }
                let observation = reference.observation
                protected = try refs.map { value in
                    let ref = try ObservationReference(value)
                    guard ref.observation == observation, ref.node != nil else {
                        throw IPhoneUseError("invalid_protected_regions", "Protected elements must belong to the action's observation")
                    }
                    return ref
                }
            }
        }
        if request["dynamicTarget"] != nil || request["dynamicAnchor"] != nil {
            guard operation == "tap", coordinate, ignoredScreenRect == nil, protected.isEmpty,
                  policy.maxScreenChange == 0.01, policy.maxRegionChange == 0 else {
                throw IPhoneUseError("invalid_dynamic_target", "Dynamic overlay validation requires a coordinate tap with default guard policy and no ignore/protect options")
            }
            dynamicRects = try ["dynamicTarget", "dynamicAnchor"].map { key in
                guard let raw = request[key] as? String else { throw IPhoneUseError("invalid_dynamic_target", "Supply both --dynamic-target and --dynamic-anchor") }
                let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
                let v = parts.compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                guard parts.count == 4, v.count == 4, v.allSatisfy(\.isFinite), v[2] > 0, v[3] > 0 else {
                    throw IPhoneUseError("invalid_dynamic_target", "Use x,y,width,height in screenshot points")
                }
                return ScreenRect(CGRect(x: v[0], y: v[1], width: v[2], height: v[3]))
            }
        } else { dynamicRects = nil }
        guardPolicy = policy
        protectedReferences = protected
        self.fields = fields
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
}

struct ObservedTarget {
    let context: [String: Any]
    // Root through target, with each child's position within its captured parent.
    let path: [[String: Any]]
    var gesture: CoordinateGesture? = nil
    var textGuard: ScreenGuard? = nil
    var textFieldGuard: NativeTextFieldGuard? = nil
    var textCaretGuard: NativeBoundCaretGuard? = nil
}

struct ActionFailure: Error, CustomStringConvertible {
    let code: String
    let description: String
    let possiblyExecuted: Bool
    let requiresObservation: Bool
    let result: [String: Any]?
    let rejectedCapture: CapturedObservation?

    init(code: String, description: String, possiblyExecuted: Bool, requiresObservation: Bool, result: [String: Any]? = nil, rejectedCapture: CapturedObservation? = nil) {
        self.rejectedCapture = rejectedCapture
        self.code = code
        self.description = description
        self.possiblyExecuted = possiblyExecuted
        self.requiresObservation = requiresObservation
        self.result = result
    }
}

enum ActionReply {
    static func decode(_ response: [String: Any]) throws -> [String: Any] {
        guard let execution = response["execution"] as? [String: Any],
              let started = execution["started"] as? Bool, let completed = execution["completed"] as? Bool else {
            throw ActionFailure(code: "missing_execution_facts", description: "Runner omitted execution facts; observe before deciding what to do next",
                                possiblyExecuted: true, requiresObservation: true, result: response["result"] as? [String: Any])
        }
        if response["ok"] as? Bool == true, completed, started { return response["result"] as? [String: Any] ?? [:] }
        let invalidFacts = completed || response["ok"] as? Bool == true || execution["inputCompleted"] as? Bool == true
        throw ActionFailure(code: response["errorCode"] as? String ?? "action_failed",
            description: response["error"] as? String ?? "Device action did not complete",
            possiblyExecuted: started || invalidFacts,
            requiresObservation: response["requiresObservation"] as? Bool == true || started || invalidFacts,
            result: response["result"] as? [String: Any])
    }
}
