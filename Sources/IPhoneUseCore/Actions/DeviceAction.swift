import IPhoneUseRunnerSupport
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
        let validation = ActionRequest(
            operation: operation, request: request, allowScreenText: allowScreenText)
        let touchPaste = try validation.validateMethod()
        kind = operation
        reference = try ObservationReference(request["reference"] as? String ?? "")
        if touchPaste, reference.node != nil {
            throw IPhoneUseError(
                "invalid_reference",
                "touch-paste requires the current screenshot oN in either mode; it does not focus an element")
        }
        coordinate = ["x", "y", "fromX", "fromY", "toX", "toY"].contains { request[$0] != nil }
        var fields = try validation.coordinateFields(reference: reference, touchPaste: touchPaste)
        try validation.validateDirection(coordinate: coordinate, fields: &fields)
        swipeMotion = try validation.swipeMotion()
        try validation.validateDuration(reference: reference, coordinate: coordinate, fields: &fields)
        pinchMotion = try validation.pinchMotion(coordinate: coordinate)
        try validation.textFields(reference: reference, touchPaste: touchPaste, fields: &fields)
        try validation.pressFields(reference: reference, fields: &fields)
        textRegion = try validation.textRegion(reference: reference)
        caretRegion = try validation.caretRegion(reference: reference, textRegion: textRegion)
        ignoredScreenRect = try validation.ignoredRegion(
            reference: reference, coordinate: coordinate, textRegion: textRegion)
        let (policy, protected) = try validation.guardPolicy(reference: reference)
        dynamicRects = try validation.dynamicRects(
            coordinate: coordinate, ignoredScreenRect: ignoredScreenRect, protected: protected, policy: policy
        )
        guardPolicy = policy
        protectedReferences = protected
        self.fields = fields
    }

}

struct ObservedTarget {
    let context: [String: Any]
    // Root through target, with each child's position within its captured parent.
    let path: [[String: Any]]
    var gesture: CoordinateGesture?
    var textGuard: ScreenGuard?
    var textFieldGuard: NativeTextFieldGuard?
    var textCaretGuard: NativeBoundCaretGuard?
}

struct ActionFailure: Error, CustomStringConvertible {
    let code: String
    let description: String
    let possiblyExecuted: Bool
    let requiresObservation: Bool
    let result: [String: Any]?
    let rejectedCapture: CapturedObservation?

    init(
        code: String, description: String, possiblyExecuted: Bool, requiresObservation: Bool,
        result: [String: Any]? = nil, rejectedCapture: CapturedObservation? = nil
    ) {
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
            let started = execution["started"] as? Bool, let completed = execution["completed"] as? Bool
        else {
            throw ActionFailure(
                code: "missing_execution_facts",
                description: "Runner omitted execution facts; observe before deciding what to do next",
                possiblyExecuted: true, requiresObservation: true,
                result: response["result"] as? [String: Any])
        }
        if response["ok"] as? Bool == true, completed, started {
            return response["result"] as? [String: Any] ?? [:]
        }
        let invalidFacts =
            completed || response["ok"] as? Bool == true || execution["inputCompleted"] as? Bool == true
        throw ActionFailure(
            code: response["errorCode"] as? String ?? "action_failed",
            description: response["error"] as? String ?? "Device action did not complete",
            possiblyExecuted: started || invalidFacts,
            requiresObservation: response["requiresObservation"] as? Bool == true || started || invalidFacts,
            result: response["result"] as? [String: Any])
    }
}
