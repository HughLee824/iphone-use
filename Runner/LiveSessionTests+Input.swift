import Network
import XCTest
import Darwin

extension LiveSessionTests {

    @MainActor
    func perform(_ command: [String: Any]) throws -> [String: Any] {
        guard !inputSessionUncertain else {
            throw CommandError(
                "input_session_uncertain",
                message: "Close this session after unconfirmed event synthesis; do not replay")
        }
        guard let kind = command["kind"] as? String,
            ["tap", "double-tap", "long-press", "pinch", "swipe", "type", "press", "home"].contains(kind),
            let expected = command["target"] as? [String: Any],
            let scope = expected["scope"] as? String
        else {
            throw CommandError("invalid_action")
        }
        let mode = command["mode"] as? String
        var text = command["text"] as? String
        let pressKey = (command["key"] as? String).flatMap(RunnerPressKey.init(rawValue:))
        try validateInput(kind: kind, pressKey: pressKey, text: text, mode: mode)
        guard expected["bundleId"] as? String == currentBundleID else {
            throw CommandError("app_changed", requiresObservation: true)
        }
        let (app, root) = try actionRoot(scope: scope)
        if kind == "home" { return try performHome(command, app: app, root: root) }
        if ["tap", "double-tap", "long-press", "pinch", "swipe"].contains(kind) {
            return try performGesture(command, kind: kind, app: app, root: root)
        }
        let (target, liveSnapshot) = try actionTarget(expected, root: root)
        try validateTextTarget(target, kind: kind)
        text = try preparedText(text, mode: mode, kind: kind, target: target, snapshot: liveSnapshot)
        if ["type", "press"].contains(kind) {
            postInputContext = screenContext(app: app, root: root)
        }
        switch kind {
        case "type": try typeText(text, mode: mode, target: target, snapshot: liveSnapshot)
        case "press": return try press(pressKey, target: target, app: app, root: root)
        default: break
        }
        if kind == "type" { postInputTextFields = [ScreenRect(target.frame)] }
        return ["kind": kind]
    }

    private func validateInput(kind: String, pressKey: RunnerPressKey?, text: String?, mode: String?) throws {
        if kind == "press", pressKey == nil { throw CommandError("invalid_key") }
        if kind == "type" { try validateText(text, mode: mode) }
    }

    @MainActor
    private func validateTextTarget(_ target: XCUIElement, kind: String) throws {
        if ["type", "press"].contains(kind),
            ![XCUIElement.ElementType.textField, .secureTextField, .textView, .searchField].contains(
                target.elementType) {
            throw CommandError("not_text_input")
        }
    }

    private func validateText(_ text: String?, mode: String?) throws {
        guard ["insert", "replace", "append"].contains(mode ?? ""), let text, text.utf8.count <= 4096,
            mode == "replace" || !text.isEmpty,
            text.unicodeScalars.allSatisfy({
                let value = $0.value
                return value == 10
                    || (value >= 32 && value != 127 && value != 133 && value != 0x2028 && value != 0x2029
                        && !(0xF700...0xF8FF).contains(value))
            })
        else { throw CommandError("invalid_text") }
    }

    @MainActor
    private func actionRoot(scope: String) throws -> (XCUIApplication, XCUIElement) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let systemAlerts = springboard.alerts
        let app: XCUIApplication
        let root: XCUIElement
        if scope == "systemAlert" {
            guard systemAlerts.count == 1 else {
                throw CommandError("system_alert_changed", requiresObservation: true)
            }
            app = springboard; root = systemAlerts.firstMatch
        } else {
            guard let currentApp, currentApp.state == .runningForeground, systemAlerts.count == 0 else {
                throw CommandError("app_context_changed", requiresObservation: true)
            }
            app = currentApp
            let alerts = app.alerts
            if scope == "appAlert", alerts.count == 1 {
                root = alerts.firstMatch
            } else if scope == "app", alerts.count == 0 {
                root = app
            } else {
                throw CommandError("app_alert_changed", requiresObservation: true)
            }
        }
        return (app, root)
    }

    @MainActor
    private func performHome(_ command: [String: Any], app: XCUIApplication, root: XCUIElement) throws
        -> [String: Any] {
        guard let raw = command["screenGuard"] as? [String: Any],
            let screenGuard = try? JSONDecoder().decode(
                ScreenGuard.self, from: JSONSerialization.data(withJSONObject: raw))
        else {
            throw CommandError("invalid_screen_guard")
        }
        let context = screenContext(app: app, root: root)
        guard screenGuard.context.matches(context) else {
            throw CommandError("screen_context_changed", requiresObservation: true)
        }
        let screenshot = XCUIScreen.main.screenshot()
        let check = try screenGuard.check(png: screenshot.pngRepresentation, context: context)
        screenGuardResult = check.result
        screenGuardResult?["capturedAt"] = Date().timeIntervalSince1970
        guard check.accepted else { throw CommandError("screen_changed", requiresObservation: true) }
        try event { XCUIDevice.shared.press(.home) }
        // The next observation can be screenshot-only; never invent an App
        // or SpringBoard element target from a Home press acknowledgement.
        currentApp = nil; currentBundleID = nil
        return ["kind": "home", "homePressCompleted": true, "homeScreenConfirmed": false]
    }

    @MainActor
    private func actionTarget(_ expected: [String: Any], root: XCUIElement) throws -> (
        XCUIElement, XCUIElementSnapshot
    ) {
        guard let path = expected["path"] as? [[String: Any]], !path.isEmpty, path.count <= 200 else {
            throw CommandError("invalid_action")
        }
        var snapshot = try root.snapshot()
        for (index, expectedNode) in path.enumerated() {
            if index > 0 {
                guard let child = expectedNode["childIndex"] as? Int,
                    snapshot.children.indices.contains(child)
                else {
                    throw CommandError("target_path_changed", requiresObservation: true)
                }
                snapshot = snapshot.children[child]
            }
            guard matches(snapshot, expected: expectedNode) else {
                throw CommandError("target_changed", requiresObservation: true)
            }
        }
        let target: XCUIElement
        if path.count == 1 {
            target = root
        } else {
            let predicate = NSPredicate(
                format: "identifier == %@ AND label == %@", snapshot.identifier, snapshot.label)
            let matches = root.descendants(matching: snapshot.elementType).matching(predicate)
            let count = matches.count
            guard count == 1 else {
                throw CommandError(
                    count == 0 ? "target_missing" : "ambiguous_target", requiresObservation: count == 0)
            }
            target = matches.firstMatch
        }
        let liveSnapshot = try target.snapshot()
        guard matches(liveSnapshot, expected: path.last!) else {
            throw CommandError("target_changed", requiresObservation: true)
        }
        guard target.isEnabled else { throw CommandError("target_disabled") }
        guard target.isHittable else { throw CommandError("target_not_hittable") }
        return (target, liveSnapshot)
    }

    @MainActor
    private func preparedText(
        _ input: String?, mode: String?, kind: String,
        target: XCUIElement, snapshot: XCUIElementSnapshot
    ) throws -> String? {
        var text = input
        if kind == "type", mode == "append", let suffix = text {
            do {
                text = try RunnerTextInput.append(
                    suffix, to: snapshot.value,
                    secure: snapshot.elementType == .secureTextField, placeholder: snapshot.placeholderValue)
            } catch let failure as RunnerTextInput.Failure {
                throw CommandError(failure.rawValue, message: failure.message)
            }
        }
        if kind == "type", let text,
            text.unicodeScalars.contains(where: { $0.value == 10 || $0.value == 13 }),
            target.elementType != .textView {
            throw CommandError(
                "multiline_requires_text_view",
                message: "Runner multiline text requires a text_view; use a separate press for Return")
        }
        return text
    }

    @MainActor
    private func typeText(_ text: String?, mode: String?, target: XCUIElement, snapshot: XCUIElementSnapshot)
        throws {
        if mode == "replace" || mode == "append" {
            do {
                let input = try RunnerTextInput.replacementInput(
                    "", value: snapshot.value,
                    secure: snapshot.elementType == .secureTextField,
                    placeholder: snapshot.placeholderValue,
                    deleteKey: XCUIKeyboardKey.delete.rawValue)
                try event { target.tap() }
                try event { target.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: .command) }
                if !input.isEmpty { try event { target.typeText(input) } }
                guard RunnerTextInput.isCleared(try target.snapshot().value) else {
                    throw CommandError(
                        "replace_clear_unconfirmed", requiresObservation: true,
                        message:
                            """
                            The field did not report empty after clearing; inspect the observation.\
                             Replacement was not inserted and input was not replayed.
                            """
                    )
                }
                if let text, !text.isEmpty { try event { target.typeText(text) } }
            } catch let failure as RunnerTextInput.Failure {
                throw CommandError(
                    failure.rawValue, requiresObservation: executionStarted, message: failure.message)
            }
        } else if let text, !text.isEmpty {
            try event { target.typeText(text) }
        }
    }

    @MainActor
    private func press(
        _ pressKey: RunnerPressKey?, target: XCUIElement, app: XCUIApplication,
        root: XCUIElement
    ) throws -> [String: Any] {
        guard let pressKey else { throw CommandError("invalid_key") }
        let key = keyboardKey(pressKey)
        if pressKey == .return || pressKey == .backspace {
            // typeKey(Delete) can return without deleting on iOS. Use the
            // existing text-input path for Delete/Return; no focus tap.
            try event { target.typeText(key.rawValue) }
        } else {
            try event { target.typeKey(key.rawValue, modifierFlags: pressKey == .shiftTab ? .shift : []) }
        }
        postInputTextFields = [ScreenRect(target.frame)]
        if pressKey == .tab || pressKey == .shiftTab {
            let after = screenContext(app: app, root: root)
            postInputContext = after
            postInputTextFields = visibleTextFields(root: root, context: after)
        }
        return ["kind": "press", "key": pressKey.rawValue, "keyModifiers": pressKey.modifiers]
    }

    private func keyboardKey(_ pressKey: RunnerPressKey) -> XCUIKeyboardKey {
        let key: XCUIKeyboardKey
        switch pressKey {
        case .return: key = .return
        case .backspace: key = .delete
        case .left: key = .leftArrow
        case .right: key = .rightArrow
        case .upArrow: key = .upArrow
        case .down: key = .downArrow
        case .tab, .shiftTab: key = .tab
        }
        return key
    }

    func matches(_ node: XCUIElementSnapshot, expected: [String: Any]) -> Bool {
        guard expected["type"] as? UInt == node.elementType.rawValue,
            expected["identifier"] as? String == node.identifier, expected["label"] as? String == node.label,
            expected["enabled"] as? Bool == node.isEnabled,
            let frame = expected["frame"] as? [String: Any]
        else { return false }
        let actual: [String: Double] = [
            "x": node.frame.minX, "y": node.frame.minY, "width": node.frame.width, "height": node.frame.height
        ]
        guard
            actual.allSatisfy({ key, value in
                (frame[key] as? Double).map { $0.isFinite && abs($0 - value) <= 0.5 } == true
            })
        else { return false }
        return NSDictionary(dictionary: ["value": node.value ?? NSNull()]).isEqual(to: [
            "value": expected["value"] ?? NSNull()
        ])
    }
}
