import IPhoneUseRunnerSupport
import Foundation
import CoreFoundation

struct ActionRequest {
    let operation: String
    let request: [String: Any]
    let allowScreenText: Bool

    func validateMethod() throws -> Bool {
        guard DeviceAction.operations.contains(operation) else {
            throw IPhoneUseError("invalid_action", "Unknown device action")
        }
        if let method = request["textMethod"] {
            guard operation == "type", let method = method as? String,
                method == "touch-paste" || (allowScreenText && ["auto", "keys", "paste"].contains(method))
            else {
                throw IPhoneUseError(
                    "invalid_text_method",
                    "Use --method touch-paste in either mode, or auto, keys, paste in standard mode")
            }
        }
        let touchPaste = request["textMethod"] as? String == "touch-paste"
        if touchPaste {
            guard request["mode"] as? String == "insert",
                ["fieldRect", "caretRect", "ignoreRect"].allSatisfy({ request[$0] == nil })
            else {
                throw IPhoneUseError(
                    "invalid_touch_paste",
                    """
                    touch-paste only stages text: use --mode insert without field/caret/ignore rectangles;\
                     select the destination through subsequent touch actions
                    """
                )
            }
        }
        return touchPaste
    }

    func coordinateFields(reference: ObservationReference, touchPaste: Bool) throws -> [String: Any] {
        let coordinateKeys = ["x", "y", "fromX", "fromY", "toX", "toY"]
        let coordinate = coordinateKeys.contains { request[$0] != nil }
        var fields: [String: Any] = ["kind": operation]
        if coordinate {
            let required =
                ["tap", "double-tap", "long-press", "pinch"].contains(operation)
                ? ["x", "y"] : (operation == "swipe" ? ["fromX", "fromY", "toX", "toY"] : [])
            if !required.isEmpty, let node = reference.node {
                let element = "\(reference.observation):e\(node + 1)"
                let coordinates =
                    ["tap", "double-tap", "long-press", "pinch"].contains(operation)
                    ? "--x X --y Y" : "--from-x X --from-y Y --to-x X --to-y Y"
                throw IPhoneUseError(
                    "invalid_coordinates",
                    """
                    Element reference \(element) cannot be combined with coordinates. Use \(operation)\
                     \(reference.observation) \(coordinates); optionally add --protect \(element) to protect\
                     the captured element
                    """
                )
            }
            guard !required.isEmpty,
                coordinateKeys.filter({ request[$0] != nil }).count == required.count
            else {
                throw IPhoneUseError(
                    "invalid_coordinates", "Use tap oN --x --y, or swipe oN --from-x --from-y --to-x --to-y")
            }
            for key in required {
                guard let value = Self.number(request[key]) else {
                    throw IPhoneUseError(
                        "invalid_coordinates", "Supply every coordinate as a finite number of screen points")
                }
                fields[key] = value
            }
        } else if reference.node == nil
            && !(operation == "home" || touchPaste
                || (allowScreenText && ["type", "press"].contains(operation))) {
            throw IPhoneUseError("element_required", "Use an element reference such as o1:e2")
        }
        return fields
    }

    func validateDirection(coordinate: Bool, fields: inout [String: Any]) throws {
        if operation == "swipe", coordinate {
            guard request["direction"] == nil else {
                throw IPhoneUseError("invalid_direction", "Coordinate swipes use endpoints, not --direction")
            }
        } else if operation == "swipe" {
            guard let direction = request["direction"] as? String,
                ["up", "down", "left", "right"].contains(direction)
            else {
                throw IPhoneUseError("invalid_direction", "Direction must be up, down, left or right")
            }
            fields["direction"] = direction
        }
    }

    func swipeMotion() throws -> SwipeMotion? {
        if operation == "swipe" {
            func control(_ key: String, fallback: Double) throws -> Double {
                guard let raw = request[key] else { return fallback }
                guard let value = Self.number(raw) else {
                    throw IPhoneUseError(
                        "invalid_swipe_motion", "Swipe motion controls must be finite numbers")
                }
                return value
            }
            let defaults = SwipeMotion()
            let motion = try SwipeMotion(
                velocity: control("velocity", fallback: defaults.velocity),
                pressDuration: control("pressDuration", fallback: defaults.pressDuration),
                holdDuration: control("holdDuration", fallback: defaults.holdDuration))
            guard motion.valid else {
                throw IPhoneUseError(
                    "invalid_swipe_motion",
                    "Require 0 < velocity <= 10000 and press/hold durations in 0...5 seconds")
            }
            return motion
        } else {
            guard ["velocity", "pressDuration", "holdDuration"].allSatisfy({ request[$0] == nil }) else {
                throw IPhoneUseError("invalid_swipe_motion", "Motion controls apply only to swipe")
            }
            return nil
        }
    }

    func validateDuration(reference: ObservationReference, coordinate: Bool, fields: inout [String: Any])
        throws {
        if operation == "home", reference.node != nil {
            throw IPhoneUseError("invalid_reference", "Home requires the current screenshot oN")
        }
        if operation == "double-tap", !coordinate {
            throw IPhoneUseError(
                "invalid_coordinates", "Double tap requires a screenshot reference and --x --y")
        }
        if operation == "long-press" {
            guard coordinate, let duration = Self.number(request["duration"] ?? 0.8),
                (0.5...5).contains(duration)
            else {
                throw IPhoneUseError(
                    "invalid_press_duration",
                    "Long press requires coordinates and duration in 0.5...5 seconds")
            }
            fields["duration"] = duration
        } else if operation != "pinch", request["duration"] != nil {
            throw IPhoneUseError("invalid_press_duration", "--duration applies only to long-press or pinch")
        }
    }

    func pinchMotion(coordinate: Bool) throws -> PinchMotion? {
        if operation == "pinch" {
            guard coordinate, request["direction"] == nil,
                let from = Self.number(request["fromDistance"]),
                let destination = Self.number(request["toDistance"]),
                let duration = Self.number(request["duration"] ?? 0.5)
            else {
                throw IPhoneUseError(
                    "invalid_pinch_motion",
                    "Pinch requires --x --y --from-distance --to-distance and optional --duration")
            }
            let motion = PinchMotion(fromDistance: from, toDistance: destination, duration: duration)
            guard motion.valid else {
                throw IPhoneUseError(
                    "invalid_pinch_motion",
                    "Pinch separations must be >=20 points and differ by >=1; duration must be 0.1...5 seconds"
                )
            }
            return motion
        } else {
            guard request["fromDistance"] == nil, request["toDistance"] == nil else {
                throw IPhoneUseError("invalid_pinch_motion", "Distance controls apply only to pinch")
            }
            return nil
        }
    }

    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            number.doubleValue.isFinite
        else { return nil }
        return number.doubleValue
    }
}
