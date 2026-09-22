import Foundation
import CoreFoundation

struct DeviceAction {
    static let operations = ["tap", "double-tap", "long-press", "pinch", "swipe", "home", "type", "press"]
    let kind: String
    let reference: ObservationReference
    let fields: [String: Any]
    let coordinate: Bool
    let guardPolicy: ScreenGuard.Policy
    let protectedReferences: [ObservationReference]
    let swipeMotion: SwipeMotion?
    let textRegion: ScreenRect?
    let pinchMotion: PinchMotion?

    init(operation: String, request: [String: Any], allowScreenText: Bool = false) throws {
        guard Self.operations.contains(operation) else { throw IPhoneUseError("invalid_action", "Unknown device action") }
        kind = operation
        if let method = request["textMethod"] {
            guard allowScreenText, operation == "type", let method = method as? String,
                  ["auto", "keys", "paste"].contains(method) else {
                throw IPhoneUseError("invalid_text_method", "--method auto, keys or paste applies only to apple-native type")
            }
        }
        reference = try ObservationReference(request["reference"] as? String ?? "")
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
        } else if reference.node == nil && !(operation == "home" || (allowScreenText && ["type", "press"].contains(operation))) {
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
            let allowNewlines = !allowScreenText || (reference.node == nil && request["textMethod"] as? String != "keys")
            guard let text = request["text"] as? String, text.utf8.count <= TextInput.maximumBytes,
                  mode == "replace" || !text.isEmpty,
                  text.unicodeScalars.allSatisfy({ scalar in
                      let v = scalar.value
                      if allowNewlines && (v == 10 || (allowScreenText && v == 13)) { return true }
                      return v >= 32 && v != 127 && v != 133 && v != 0x2028 && v != 0x2029 && !(0xF700...0xF8FF).contains(v)
                  }) else {
                throw IPhoneUseError("invalid_text", "Use up to 4096 UTF-8 bytes without control keys; LF requires a Runner text_view; CR/CRLF require native auto/paste, and only replace accepts empty text")
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
    var textCaretGuard: NativeCaretGuard? = nil
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
