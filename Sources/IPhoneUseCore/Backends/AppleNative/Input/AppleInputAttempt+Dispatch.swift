import Foundation
import CoreGraphics
import AppleNativeBridge

extension AppleInputAttempt {

    func dispatch(onInputStarted: @escaping () -> Void) throws -> [String: Any] {
        var result: [String: Any]
        if let textInput {
            result = try dispatchText(textInput)
        } else if homeAction {
            result = try hid.home(using: backend.buttonTransport!) {
                try backend.checkInputCanContinue()
            }
        } else if pressing {
            guard let name = action.fields["key"] as? String, let key = NativePressKey(rawValue: name) else {
                throw IPhoneUseError("invalid_key", "Unknown native keyboard key")
            }
            result = try hid.press(key) { try backend.checkInputCanContinue() }
        } else if action.kind == "double-tap" {
            let point = try NativeCoordinateMapper.map(
                target.gesture!.start, screen: screenGuard.context.screen, rotation: rotation)
            result = try hid.doubleTap(point, onContact: onInputStarted) {
                try backend.checkInputCanContinue()
            }
        } else if let pinch {
            result = try hid.pinch(pinch, onContact: onInputStarted) { try backend.checkInputCanContinue() }
        } else if let swipe {
            result = try hid.swipe(swipe, onContact: onInputStarted) { try backend.checkInputCanContinue() }
        } else {
            let point = try NativeCoordinateMapper.map(
                target.gesture!.start, screen: screenGuard.context.screen, rotation: rotation)
            result = try hid.tap(
                point, hold: action.fields["duration"] as? Double ?? 0.06, onContact: onInputStarted
            ) {
                try backend.checkInputCanContinue()
            }
        }
        return result
    }

    private func dispatchText(_ textInput: NativeTextInput) throws -> [String: Any] {
        var result: [String: Any]
        func health() throws { try backend.checkInputCanContinue() }
        do {
            switch textInput {
            case .keyboard(let keys):
                result = try hid.type(
                    keys, mode: validatedValue(action.fields["mode"], as: String.self), checkHealth: health)
            case .pasteboard:
                result = try hid.paste(
                    mode: validatedValue(action.fields["mode"], as: String.self), checkHealth: health)
            case .clear: result = try hid.clearText(checkHealth: health)
            }
            result["textInputMethod"] = textInput.usesPasteboard ? "apple-pasteboard-hid-paste" : "ascii-hid"
            if case .clear = textInput { result["textInputMethod"] = "hid-select-all-delete" }
            if textInput.usesPasteboard { result["pasteboard"] = backend.pasteboard!.status }
        } catch let failure as ActionFailure {
            var facts = failure.result ?? [:]
            if textInput.usesPasteboard { facts["pasteboard"] = backend.pasteboard!.status }
            throw ActionFailure(
                code: failure.code, description: failure.description,
                possiblyExecuted: failure.possiblyExecuted,
                requiresObservation: failure.requiresObservation, result: facts)
        }
        return result
    }
}
